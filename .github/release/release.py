#!/usr/bin/env python3
"""The release tool of noixdev.infra. .github/workflows/release.yml calls it to
check that a release can be cut, to edit galaxy.yml, CHANGELOG.md and README.md,
and to build the GitHub release body. Standard library only, Python 3.9 or
later, run as `python3 -I`.

  release.py preflight --bump {patch,minor,major} [--repo DIR]
  release.py apply --version X.Y.Z --date YYYY-MM-DD [--repo DIR]
  release.py notes --version X.Y.Z --repo-slug OWNER/NAME [--repo DIR]
  release.py readme --version X.Y.Z [--repo DIR]

preflight prints the next version. Errors print "::error::<message>" on stderr
and exit 1; a usage error exits 2. Files are read and written as UTF-8 and keep
their line endings. Tests: test_release.py next to this file.
"""
import argparse
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True

BODY_LIMIT = 60000
GALAXY_RE = re.compile(r"^version: (\d+)\.(\d+)\.(\d+)$")
README_RE = re.compile(r"^\s+version: v\d+\.\d+\.\d+$")
COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)


class ReleaseError(Exception):
    pass


def _lines(text):
    """Split into lines without their "\\n" or "\\r\\n"; the end of a line is kept
    by the callers that rewrite text (see _eol)."""
    return text.split("\n")


def _strip(line):
    return line[:-1] if line.endswith("\r") else line


def _eol(line):
    return "\r" if line.endswith("\r") else ""


def next_version(current, bump):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", current)
    if not m:
        raise ReleaseError("version %r is not X.Y.Z" % current)
    major, minor, patch = (int(g) for g in m.groups())
    if bump == "patch":
        return "%d.%d.%d" % (major, minor, patch + 1)
    if bump == "minor":
        return "%d.%d.0" % (major, minor + 1)
    if bump == "major":
        return "%d.0.0" % (major + 1)
    raise ReleaseError("unknown bump %r (patch, minor or major)" % bump)


def _galaxy_index(text):
    hits = [i for i, l in enumerate(_lines(text)) if _strip(l).startswith("version:")]
    if len(hits) != 1 or not GALAXY_RE.match(_strip(_lines(text)[hits[0]])):
        raise ReleaseError(
            "galaxy.yml must have exactly one line 'version: X.Y.Z' (unquoted, no suffix)")
    return hits[0]


def galaxy_version(text):
    i = _galaxy_index(text)
    return _strip(_lines(text)[i])[len("version: "):]


def set_galaxy_version(text, version):
    i = _galaxy_index(text)
    lines = _lines(text)
    lines[i] = "version: %s%s" % (version, _eol(lines[i]))
    return "\n".join(lines)


def _readme_index(text):
    hits = [i for i, l in enumerate(_lines(text)) if README_RE.match(_strip(l))]
    if len(hits) != 1:
        raise ReleaseError(
            "README.md must have exactly one install line '    version: vX.Y.Z', found %d" % len(hits))
    return hits[0]


def set_readme_version(text, version):
    i = _readme_index(text)
    lines = _lines(text)
    old = lines[i]
    indent = old[:len(old) - len(old.lstrip())]
    lines[i] = "%sversion: v%s%s" % (indent, version, _eol(old))
    return "\n".join(lines)


def _changelog_unreleased(text, version):
    """Index of the '## Unreleased' line after checking every changelog shape."""
    lines = [_strip(l) for l in _lines(text)]
    unreleased = [i for i, l in enumerate(lines) if l.rstrip() == "## Unreleased"]
    if len(unreleased) != 1:
        raise ReleaseError(
            "CHANGELOG.md must have exactly one '## Unreleased' heading, found %d" % len(unreleased))
    headings = [i for i, l in enumerate(lines) if l.startswith("## ")]
    if headings[0] != unreleased[0]:
        raise ReleaseError("'## Unreleased' must be the first '## ' heading of CHANGELOG.md")
    start = unreleased[0]
    nxt = [i for i in headings if i > start]
    end = nxt[0] if nxt else len(lines)
    body = COMMENT_RE.sub("", "\n".join(lines[start + 1:end]))
    if not any(l.strip() for l in body.split("\n")):
        raise ReleaseError(
            "the '## Unreleased' section of CHANGELOG.md is empty (blank lines or comments only)")
    if any(l.startswith("## %s " % version) or l.rstrip() == "## %s" % version for l in lines):
        raise ReleaseError("CHANGELOG.md already has a '## %s' heading" % version)
    return start


def bump_changelog(text, version, date):
    i = _changelog_unreleased(text, version)
    lines = _lines(text)
    eol = _eol(lines[i])
    lines[i] = "## Unreleased%s\n%s\n## %s — %s%s" % (eol, eol, version, date, eol)
    return "\n".join(lines)


def release_notes(changelog, version, repo_slug):
    lines = [_strip(l) for l in _lines(changelog)]
    heads = [i for i, l in enumerate(lines) if l.startswith("## %s " % version)]
    if len(heads) != 1:
        raise ReleaseError("CHANGELOG.md must have exactly one '## %s ' heading, found %d"
                           % (version, len(heads)))
    nxt = [i for i, l in enumerate(lines) if l.startswith("## ") and i > heads[0]]
    section = lines[heads[0] + 1:nxt[0] if nxt else len(lines)]
    while section and not section[0].strip():
        section.pop(0)
    while section and not section[-1].strip():
        section.pop()
    body = "\n".join(section)
    if len(body.encode("utf-8")) <= BODY_LIMIT:
        return body
    pointer = ("\n\n… cut at 60 000 bytes; the full entry is in "
               "[CHANGELOG.md](https://github.com/%s/blob/v%s/CHANGELOG.md)." % (repo_slug, version))
    budget = BODY_LIMIT - len(pointer.encode("utf-8"))
    kept, used = [], 0
    for line in section:
        cost = len(line.encode("utf-8")) + (1 if kept else 0)
        if used + cost > budget:
            break
        kept.append(line)
        used += cost
    while kept and not kept[-1].strip():
        kept.pop()
    return "\n".join(kept) + pointer


def _read(repo, name):
    try:
        with open(os.path.join(repo, name), encoding="utf-8", newline="") as f:
            return f.read()
    except OSError as e:
        raise ReleaseError("cannot read %s: %s" % (name, e.strerror))


def _write(repo, name, text):
    with open(os.path.join(repo, name), "w", encoding="utf-8", newline="") as f:
        f.write(text)


def _tag_exists(repo, tag):
    r = subprocess.run(["git", "-C", repo, "rev-parse", "-q", "--verify", "refs/tags/" + tag],
                       capture_output=True)
    return r.returncode == 0


def preflight(repo, bump):
    current = galaxy_version(_read(repo, "galaxy.yml"))
    nxt = next_version(current, bump)
    if not _tag_exists(repo, "v" + current):
        raise ReleaseError(
            "galaxy.yml is at %s but the tag v%s does not exist: an earlier release was not "
            "finished. Finish the tag and the GitHub release for v%s by hand, then run again."
            % (current, current, current))
    if _tag_exists(repo, "v" + nxt):
        raise ReleaseError("the tag v%s already exists" % nxt)
    _changelog_unreleased(_read(repo, "CHANGELOG.md"), nxt)
    _readme_index(_read(repo, "README.md"))
    return nxt


def apply(repo, version, date):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        raise ReleaseError("--version must be X.Y.Z and --date YYYY-MM-DD")
    galaxy = set_galaxy_version(_read(repo, "galaxy.yml"), version)
    changelog = bump_changelog(_read(repo, "CHANGELOG.md"), version, date)
    _readme_index(_read(repo, "README.md"))
    _write(repo, "galaxy.yml", galaxy)
    _write(repo, "CHANGELOG.md", changelog)


def main(argv=None):
    p = argparse.ArgumentParser(prog="release.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    def add(name, *args):
        s = sub.add_parser(name)
        s.add_argument("--repo", default=".")
        for a in args:
            s.add_argument(a, required=True)
        return s

    s = add("preflight")
    s.add_argument("--bump", required=True, choices=["patch", "minor", "major"])
    add("apply", "--version", "--date")
    add("notes", "--version", "--repo-slug")
    add("readme", "--version")
    a = p.parse_args(argv)
    try:
        if a.cmd == "preflight":
            print(preflight(a.repo, a.bump))
        elif a.cmd == "apply":
            apply(a.repo, a.version, a.date)
        elif a.cmd == "notes":
            body = release_notes(_read(a.repo, "CHANGELOG.md"), a.version, a.repo_slug)
            sys.stdout.buffer.write(body.encode("utf-8"))  # no newline: the body is capped at 60 000 bytes
        else:
            _write(a.repo, "README.md", set_readme_version(_read(a.repo, "README.md"), a.version))
    except ReleaseError as e:
        print("::error::%s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
