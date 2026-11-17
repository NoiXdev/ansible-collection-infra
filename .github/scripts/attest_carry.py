#!/usr/bin/env python3
"""Shared logic of tests/attest.sh and .github/scripts/verify-tests-attestation.sh:
the path map (tests/suites.conf), the expected entries (tests/all.sh), the note
and payload checks, the run-or-carry plan and the schema 2 payload. Standard
library only, Python 3.9 or later, run as `python3 -I`.

  attest_carry.py check-map --repo DIR --commit C
  attest_carry.py plan --repo DIR --head C --notes-ref REF --signers FILE --now EPOCH
                       [--all] [--allow-dry-run]
  attest_carry.py build-payload --plan FILE --summary FILE --out FILE --commit C --tree T
                       --signer S --arch A --os O --docker D --started TIME --finished TIME
                       [--dry-run]
  attest_carry.py verify --repo DIR --tested C --release R --notes-ref REF --now EPOCH

Errors print "::error::<message>" on stdout and exit 1; verify prints one
such line per problem (every carried entry that cannot be proven), or its
OK line.

The map, tests/suites.conf, is line based: "#" starts a comment, sections are
[ignore], [shared] and [suite <name>], every other line is a pattern. A
pattern ending in "/" matches the paths below it, any other pattern is an
fnmatch pattern ("*" also matches "/", except in [ignore], where each "/"-
separated segment is matched on its own). Per changed file: [ignore] touches
no suite, [shared] every suite, a suite pattern that suite (a file may touch
several), and a file no pattern matches every suite.

check-map also checks that each suite lists, as roles/<r>/, every role that
its listed roles (their tasks/, handlers/ and meta/ files) and its own test
files reference as noixdev.infra.<r>, so the suite holds the transitive
closure of its roles.
"""
import argparse
import base64
import binascii
import fnmatch
import json
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from typing import Optional

MAX_AGE_DAYS = 30
CARRY_MARGIN_DAYS = 2
FUTURE_TOLERANCE_SECONDS = 86400
NAMESPACE = "noixdev-infra-tests"

MAP_PATH = "tests/suites.conf"
ALLSH_PATH = "tests/all.sh"
SIGNERS_PATH = ".github/tests-allowed-signers"
TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
LABEL_RE = re.compile(r"[A-Za-z0-9._-]+")
SHA_RE = re.compile(r"[0-9a-f]{40}")
# Top-level files outside any suite that [ignore] may name besides *.md.
IGNORABLE_TOP_LEVEL = ("LICENSE", ".ansible-lint", ".yamllint", ".gitignore")
RELEASE_SUITES = ("host", "services")  # one entry per release: <suite>-<release>
ROLE_REF_RE = re.compile(r"noixdev\.infra\.([a-z0-9_]+)")
ROLE_REF_DIRS = ("tasks", "handlers", "meta")  # where a role references other roles


class NoteError(Exception):
    """A note or payload that cannot be trusted; message says why."""

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


class SignatureError(NoteError):
    """A note whose SSH signature does not verify for its signer."""

    def __init__(self, message: str, signer: str):
        super().__init__(message)
        self.signer = signer


class GitError(Exception):
    pass


# --- the map ---------------------------------------------------------------

def parse_map(text: str) -> dict:
    m = {"ignore": [], "shared": [], "suites": {}}
    current = None
    seen = set()
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("["):
            header = re.fullmatch(r"\[(ignore|shared|suite ([A-Za-z0-9._-]+))\]", line)
            if not header:
                raise ValueError(f"tests/suites.conf line {n}: unknown section header {line}")
            if header.group(1) in seen:
                raise ValueError(f"tests/suites.conf line {n}: duplicate section {line}")
            seen.add(header.group(1))
            if header.group(2):
                current = m["suites"].setdefault(header.group(2), [])
            else:
                current = m[header.group(1)]
            continue
        if current is None:
            raise ValueError(f"tests/suites.conf line {n}: pattern {line} outside a section")
        current.append(line)
    return m


def matches(path: str, pattern: str) -> bool:
    if pattern.endswith("/"):
        return path.startswith(pattern)
    return fnmatch.fnmatchcase(path, pattern)


def ignore_matches(path: str, pattern: str) -> bool:
    """matches() for [ignore]: a glob matches segment by segment, so "*" stops
    at "/" (roles/*/README.md is not roles/x/templates/README.md)."""
    if pattern.endswith("/"):
        return path.startswith(pattern)
    parts, globs = path.split("/"), pattern.split("/")
    return len(parts) == len(globs) and all(fnmatch.fnmatchcase(a, b) for a, b in zip(parts, globs))


def classify(m: dict, path: str) -> tuple:
    """("ignored"|"shared"|"unmatched", set()) or ("suites", {names})."""
    if any(ignore_matches(path, p) for p in m["ignore"]):
        return "ignored", set()
    if any(matches(path, p) for p in m["shared"]):
        return "shared", set()
    hit = {name for name, patterns in m["suites"].items() if any(matches(path, p) for p in patterns)}
    return ("suites", hit) if hit else ("unmatched", set())


def affected_suites(m: dict, changed: list):
    """The suite names the changed files touch, or "ALL"."""
    hit = set()
    for path in changed:
        kind, suites = classify(m, path)
        if kind in ("shared", "unmatched"):
            return "ALL"
        hit |= suites
    return hit


def _array(allsh: str, name: str) -> list:
    lines = re.findall(r"^" + name + r"=\(([^)]*)\)[ \t]*$", allsh, re.M)
    if len(lines) != 1:
        raise ValueError(f"tests/all.sh has no single {name}=(...) line")
    values = lines[0].split()
    if not values or not all(LABEL_RE.fullmatch(v) for v in values):
        raise ValueError(f"{name} in tests/all.sh is empty or malformed")
    return values


def expected_entries(allsh: str) -> list:
    entries = []
    for suite in _array(allsh, "all_suites"):
        if suite in RELEASE_SUITES:
            entries += [(f"{suite}-{r}", suite) for r in _array(allsh, suite + "_releases")]
        else:
            entries.append((suite, suite))
    labels = [label for label, _ in entries]
    if len(set(labels)) != len(labels):
        raise ValueError("tests/all.sh lists an entry twice")
    return entries


def _ignore_allowed(pattern: str) -> bool:
    if any(c in pattern for c in "*?["):
        return pattern == "roles/*/README.md"
    if "/" not in pattern:
        return pattern.endswith(".md") or pattern in IGNORABLE_TOP_LEVEL
    if pattern.startswith(".github/"):
        # Nothing at or below .github/scripts/, and no prefix of it.
        return not (pattern.startswith(".github/scripts/") or ".github/scripts/".startswith(pattern))
    return False


def _dependency_errors(m: dict, roles: set, files: dict) -> list:
    """Each suite must list, as roles/<x>/, every role x that its listed
    roles or its own test files reference as noixdev.infra.<x>."""
    refs = {}  # role -> [(referenced role, file)]
    for path in sorted(files):
        parts = path.split("/")
        if len(parts) >= 4 and parts[0] == "roles" and parts[1] in roles and parts[2] in ROLE_REF_DIRS:
            refs.setdefault(parts[1], []).extend(
                (x, path) for x in ROLE_REF_RE.findall(files[path]) if x in roles and x != parts[1])
    errors = []
    for suite, patterns in m["suites"].items():
        listed = {p[len("roles/"):-1] for p in patterns if re.fullmatch(r"roles/[^/*?\[]+/", p)}
        sources = [ref for role in sorted(listed) for ref in refs.get(role, [])]
        for path in sorted(files):
            if path.startswith("tests/") and any(matches(path, p) for p in patterns):
                sources += [(x, path) for x in ROLE_REF_RE.findall(files[path]) if x in roles]
        missing = {}
        for x, path in sources:
            if x not in listed:
                missing.setdefault(x, []).append(path)
        for x, paths in sorted(missing.items()):
            errors.append(f"[suite {suite}] lacks roles/{x}/, which {', '.join(dict.fromkeys(paths))} "
                          f"reference(s) as noixdev.infra.{x}; add roles/{x}/ to that section")
    return errors


def check_map(m: dict, allsh: str, role_dirs: list, files: Optional[dict] = None) -> list:
    """Errors of the map against all_suites and the roles (role names, or
    roles/<name>/ paths). With files (path -> text: the roles' tasks/,
    handlers/ and meta/ files and the files under tests/), also every role a
    suite's roles or test files reference is checked to be in that suite."""
    try:
        suites = list(dict.fromkeys(suite for _, suite in expected_entries(allsh)))
    except ValueError as e:
        return [str(e)]
    errors = [f"suite {s} of all_suites has no [suite {s}] section in tests/suites.conf"
              for s in suites if s not in m["suites"]]
    errors += [f"[suite {s}] in tests/suites.conf is not a suite of all_suites in tests/all.sh"
               for s in m["suites"] if s not in suites]
    claimed = {p for patterns in m["suites"].values() for p in patterns}
    roles = set()
    for role in role_dirs:
        name = (role[len("roles/"):] if role.startswith("roles/") else role).strip("/")
        roles.add(name)
        prefix = "roles/" + name + "/"
        if prefix not in claimed:
            errors.append(f"{prefix} is in no [suite] section of tests/suites.conf; "
                          f"add the exact pattern {prefix} to each suite that uses the role")
    errors += [f"[ignore] pattern {p} in tests/suites.conf is too broad: [ignore] may only name "
               f"top-level *.md files, {', '.join(IGNORABLE_TOP_LEVEL)}, roles/*/README.md and "
               f"paths under .github/ outside .github/scripts/"
               for p in m["ignore"] if not _ignore_allowed(p)]
    if files is not None:
        errors += _dependency_errors(m, roles, files)
    return errors


# --- git --------------------------------------------------------------------

def _git(repo: str, *args: str, ok=(0,)) -> subprocess.CompletedProcess:
    try:
        r = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, encoding="utf-8", errors="surrogateescape")
    except OSError as e:
        raise GitError(f"cannot run git: {e}")
    if r.returncode not in ok:
        detail = (r.stderr.strip().splitlines() or ["exit %d" % r.returncode])[0]
        raise GitError(f"git {' '.join(args[:2])} failed: {detail}")
    return r


def _commit(repo: str, rev: str) -> str:
    r = _git(repo, "rev-parse", "--verify", "--quiet", rev + "^{commit}", ok=(0, 1))
    if r.returncode != 0:
        raise GitError(f"{rev} is not a commit in this repository")
    return r.stdout.strip()


def _show(repo: str, commit: str, path: str) -> str:
    r = _git(repo, "show", f"{commit}:{path}", ok=(0, 128))
    if r.returncode != 0:
        raise GitError(f"{path} is missing at {commit[:7]}")
    return r.stdout


def _ancestors(repo: str, commit: str) -> set:
    return set(_git(repo, "rev-list", commit).stdout.split())


def _read_files(repo: str, commit: str, paths: list) -> dict:
    """path -> text (undecodable bytes replaced) of the blobs at commit."""
    paths = [p for p in paths if "\n" not in p]
    if not paths:
        return {}
    try:
        r = subprocess.run(["git", "-C", repo, "cat-file", "--batch"],
                           input="".join(f"{commit}:{p}\n" for p in paths).encode("utf-8", "surrogateescape"),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise GitError(f"cannot run git: {e}")
    if r.returncode != 0:
        raise GitError(f"git cat-file failed at {commit[:7]}")
    out, pos, files = r.stdout, 0, {}
    for path in paths:
        nl = out.find(b"\n", pos)
        header = out[pos:nl].split()
        if nl < 0 or len(header) != 3 or header[1] != b"blob":
            raise GitError(f"cannot read {path} at {commit[:7]}")
        size = int(header[2])
        files[path] = out[nl + 1:nl + 1 + size].decode("utf-8", "replace")
        pos = nl + 1 + size + 1
    return files


def changed_files(repo: str, a: str, b: str) -> list:
    """Paths that differ between the trees of a and b; a rename counts as both paths."""
    out = _git(repo, "diff", "--name-only", "--no-renames", "-z", a, b).stdout
    return [p for p in out.split("\0") if p]


# --- notes ------------------------------------------------------------------

def read_note(repo: str, notes_ref: str, commit: str) -> Optional[str]:
    r = _git(repo, "notes", f"--ref={notes_ref}", "show", commit, ok=(0, 1, 128))
    return r.stdout if r.returncode == 0 else None


def _noted_commits(repo: str, notes_ref: str) -> set:
    if _git(repo, "rev-parse", "--verify", "--quiet", notes_ref, ok=(0, 1)).returncode != 0:
        return set()
    out = _git(repo, "notes", f"--ref={notes_ref}", "list").stdout
    return {line.split()[1] for line in out.splitlines() if len(line.split()) == 2}


def _load(data: bytes) -> dict:
    try:
        p = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise NoteError("The tests attestation payload is not valid JSON.")
    if not isinstance(p, dict):
        raise NoteError("The tests attestation payload is not a JSON object.")
    return p


def verify_note(note_text: str, signers_path: str, tmpdir: str) -> dict:
    """The payload of a note whose SSH signature verifies for its signer."""
    lines = note_text.splitlines()
    payloads = [line[len("payload: "):] for line in lines if line.startswith("payload: ")]
    if len(payloads) != 1:
        raise NoteError("The tests attestation note has no single payload line.")
    try:
        payload = base64.b64decode(payloads[0].strip(), validate=True)
    except (binascii.Error, ValueError):
        raise NoteError("The tests attestation payload is not valid base64.")
    begin, end = "-----BEGIN SSH SIGNATURE-----", "-----END SSH SIGNATURE-----"
    if lines.count(begin) != 1 or lines.count(end) != 1 or lines.index(begin) > lines.index(end):
        raise NoteError("The tests attestation note has no single SSH signature.")
    p = _load(payload)
    signer = p.get("signer")
    if not isinstance(signer, str) or not re.fullmatch(r"[^\s]+", signer):
        raise NoteError("The tests attestation payload names no signer.")
    payload_path, sig_path = tmpdir + "/payload.json", tmpdir + "/payload.json.sig"
    with open(payload_path, "wb") as f:
        f.write(payload)
    with open(sig_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines[lines.index(begin):lines.index(end) + 1]) + "\n")
    try:
        with open(payload_path, "rb") as stdin:
            rc = subprocess.run(["ssh-keygen", "-Y", "verify", "-f", signers_path, "-I", signer,
                                 "-n", NAMESPACE, "-s", sig_path], stdin=stdin,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    except OSError:
        raise NoteError("ssh-keygen is required to verify the tests attestation.")
    if rc != 0:
        raise SignatureError(f"The tests attestation signature does not verify for {signer} "
                             f"(namespace {NAMESPACE}).", signer)
    return p


def _entry_ok(e, keys: tuple) -> bool:
    if not isinstance(e, dict) or not all(isinstance(e.get(k), str) for k in keys):
        return False
    notes = e.get("notes", [])
    return (LABEL_RE.fullmatch(e["label"]) is not None and isinstance(notes, list)
            and all(isinstance(n, str) for n in notes))


def check_payload(p: dict, commit: str, tree: str, allow_dry_run: bool) -> None:
    schema = p.get("schema")
    if type(schema) is not int or schema not in (1, 2):
        raise NoteError(f"Unknown tests attestation schema {schema!r}.")
    if "dryRun" in p and not allow_dry_run:
        raise NoteError("The tests attestation is from a dry run (tests/attest.sh self-test mode), not a real run.")
    if p.get("commit") != commit:
        raise NoteError(f"The tests attestation is for {str(p.get('commit'))[:7]}, not {commit[:7]}.")
    if p.get("tree") != tree:
        raise NoteError(f"The tests attestation's tree does not match {commit[:7]}.")
    suites = p.get("suites")
    if (not isinstance(suites, list) or not all(_entry_ok(e, ("label", "result")) for e in suites)
            or type(p.get("passed")) is not int or type(p.get("failed")) is not int):
        raise NoteError("The tests attestation payload is malformed (suites, passed, failed).")
    carried = p.get("carried", [])
    if schema == 1 and "carried" in p:
        raise NoteError("The tests attestation payload is malformed (carried in schema 1).")
    if (not isinstance(carried, list) or not all(_entry_ok(c, ("label", "carriedFrom")) for c in carried)
            or not all(SHA_RE.fullmatch(c["carriedFrom"]) for c in carried)):
        raise NoteError("The tests attestation payload is malformed (carried).")
    seen = set()
    for label in [e["label"] for e in suites] + [c["label"] for c in carried]:
        if label in seen:
            raise NoteError(f"The tests attestation lists {label} more than once.")
        seen.add(label)
    docker = p.get("docker")
    if suites and not allow_dry_run and (not isinstance(docker, str) or docker.strip() in ("", "unknown")):
        raise NoteError("The tests attestation records no Docker version, so the suites did not run on Docker.")


def ran_entries(p: dict) -> dict:
    """label -> entry of the entries that ran (schema 1: all of them)."""
    return {e["label"]: e for e in p["suites"]}


def age_seconds(p: dict, now: int) -> int:
    value = p.get("finishedAt")
    try:
        finished = datetime.strptime(value, TIME_FORMAT).replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        raise NoteError(f"The tests attestation has no valid finishedAt ({value!r}).")
    age = int(now) - int(finished.timestamp())
    if age < -FUTURE_TOLERANCE_SECONDS:
        raise NoteError(f"The tests attestation finished at {value}, more than a day in the future.")
    return age


# --- plan -------------------------------------------------------------------

def _runs(repo: str, head: str, notes_ref: str, signers_path: str, allow_dry_run: bool) -> tuple:
    """(runs, at_head): runs is label -> [(commit, payload, entry)] of the
    valid notes of head's ancestors, descendants before their ancestors;
    head itself is no carry source, since its note is the one to be
    replaced. at_head is label -> entry of what ran in head's own valid note,
    so a red run there is not replaced by a carry."""
    noted = _noted_commits(repo, notes_ref)
    runs, at_head = {}, {}
    if not noted:
        return runs, at_head
    order = _git(repo, "rev-list", "--topo-order", head).stdout.split()
    with tempfile.TemporaryDirectory() as tmp:
        for commit in order:
            if commit not in noted:
                continue
            text = read_note(repo, notes_ref, commit)
            if text is None:
                continue
            try:
                p = verify_note(text, signers_path, tmp)
                tree = _git(repo, "rev-parse", commit + "^{tree}").stdout.strip()
                check_payload(p, commit, tree, allow_dry_run)
            except NoteError:
                continue
            if commit == head:
                at_head = ran_entries(p)
                continue
            for label, entry in ran_entries(p).items():
                runs.setdefault(label, []).append((commit, p, entry))
    return runs, at_head


def _decide(repo, m, head, label, suite, candidates, at_head, now, cache) -> dict:
    run = {"label": label, "suite": suite, "action": "run"}
    if label in at_head and at_head[label]["result"] != "pass":
        return dict(run, reason=f"red at {head[:7]} ({at_head[label]['result']})")
    if not candidates:
        return dict(run, reason=f"no signed run of {label} before {head[:7]}")
    c, p, entry = candidates[0]
    if ("ancestors", c) not in cache:
        cache[("ancestors", c)] = _ancestors(repo, c)
    for other, _, _ in candidates[1:]:
        if other not in cache[("ancestors", c)]:
            return dict(run, reason=f"{label} ran at {c[:7]} and at {other[:7]} on parallel branches")
    if entry["result"] != "pass":
        return dict(run, reason=f"red at {c[:7]} ({entry['result']})")
    try:
        age = age_seconds(p, now)
    except NoteError as e:
        return dict(run, reason=f"the run at {c[:7]} cannot be carried: {e.message}")
    limit = MAX_AGE_DAYS - CARRY_MARGIN_DAYS
    if age > limit * 86400:
        days = -(-age // 86400)  # rounded up, so always more than the limit
        return dict(run, reason=f"the run at {c[:7]} is {days} days old (a run is carried for up to {limit} days)")
    if ("changed", c) not in cache:
        cache[("changed", c)] = changed_files(repo, c, head)
    kinds = [(path,) + classify(m, path) for path in cache[("changed", c)]]
    for path, kind, _ in kinds:
        if kind == "shared":
            return dict(run, reason=f"{path} changed since {c[:7]} (a shared path)")
        if kind == "unmatched":
            return dict(run, reason=f"{path} changed since {c[:7]} (in no section of {MAP_PATH})")
    for path, _, suites in kinds:
        if suite in suites:
            return dict(run, reason=f"{path} changed since {c[:7]}")
    carry = {"label": label, "suite": suite, "action": "carry", "carriedFrom": c,
             "finishedAt": p["finishedAt"]}
    if entry.get("notes"):
        carry["notes"] = entry["notes"]
    carry["reason"] = f"no file of {suite} changed since {c[:7]}"
    return carry


def plan(repo, head, notes_ref, signers_path, now, force_all, allow_dry_run) -> list:
    head = _commit(repo, head)
    entries = expected_entries(_show(repo, head, ALLSH_PATH))
    m = parse_map(_show(repo, head, MAP_PATH))
    if force_all:
        return [{"label": label, "suite": suite, "action": "run", "reason": "--all"} for label, suite in entries]
    runs, at_head = _runs(repo, head, notes_ref, signers_path, allow_dry_run)
    cache = {}
    return [_decide(repo, m, head, label, suite, runs.get(label, []), at_head, now, cache)
            for label, suite in entries]


# --- payload ----------------------------------------------------------------

def build_payload(plan_entries, summary_text, commit, tree, signer, arch, os_name, docker,
                  started, finished, dry_run) -> dict:
    """The schema 2 payload of a run: the summary's entries ran, the plan's
    carried entries are referenced."""
    to_run, carried = [], []
    for e in plan_entries:
        if not isinstance(e, dict) or not isinstance(e.get("label"), str) or e.get("action") not in ("run", "carry"):
            raise ValueError("the plan is malformed")
        if e["action"] == "run":
            to_run.append(e["label"])
        elif not SHA_RE.fullmatch(str(e.get("carriedFrom"))):
            raise ValueError(f"the plan carries {e['label']} without a commit")
        else:
            carried.append({"label": e["label"], "carriedFrom": e["carriedFrom"]})
    suites = []
    for n, line in enumerate(summary_text.splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split()
        if (len(fields) < 3 or not LABEL_RE.fullmatch(fields[0])
                or fields[1] not in ("pass", "fail", "skipped") or not re.fullmatch(r"[0-9]+", fields[2])):
            raise ValueError(f"summary line {n} is malformed: {line.strip()!r}")
        if fields[0] not in to_run:
            raise ValueError(f"summary line {n}: {fields[0]} is not an entry the plan runs")
        if any(e["label"] == fields[0] for e in suites):
            raise ValueError(f"summary line {n}: {fields[0]} appears twice")
        entry = {"label": fields[0], "result": fields[1], "seconds": int(fields[2])}
        if fields[3:]:
            entry["notes"] = [note.replace("_", " ") for note in fields[3:]]
        suites.append(entry)
    ran = {e["label"] for e in suites}
    passed = sum(1 for e in suites if e["result"] == "pass")
    missing = [label for label in to_run if label not in ran]
    payload = {
        "schema": 2,
        "commit": commit,
        "tree": tree,
        "signer": signer,
        "suites": suites,
        "carried": carried,
        "passed": passed,
        "failed": len(suites) - passed + len(missing),
        "carriedCount": len(carried),
        "arch": arch,
        "os": os_name,
        "docker": docker if suites else "none",
        "startedAt": started,
        "finishedAt": finished,
    }
    if dry_run:
        payload["dryRun"] = True
    return payload


# --- release check ----------------------------------------------------------

def _days(age: int) -> int:
    return -(-age // 86400)  # rounded up, so past the limit always reads as more than it


def _carry_error(repo, notes_ref, m, tested, label, suite, c, signers_path, tmp, runs, cache,
                 now) -> Optional[str]:
    """Why the entry label of suite, carried from c into tested, cannot be
    trusted, or None. Everything is proven from git and c's own note."""
    c7, t7 = c[:7], tested[:7]
    if _git(repo, "rev-parse", "--verify", "--quiet", c + "^{commit}", ok=(0, 1)).returncode != 0:
        return f"carriedFrom {c} of {label} is not a commit in this repository"
    if _git(repo, "merge-base", "--is-ancestor", c, tested, ok=(0, 1)).returncode != 0:
        return f"{label} is carried from {c7}, which is not an ancestor of {t7}"
    if ("payload", c) not in cache:
        text = read_note(repo, notes_ref, c)
        if text is None:
            cache[("payload", c)] = "which has no tests attestation"
        else:
            try:
                p = verify_note(text, signers_path, tmp)
                check_payload(p, c, _git(repo, "rev-parse", c + "^{tree}").stdout.strip(), False)
                cache[("payload", c)] = p
            except SignatureError as e:
                cache[("payload", c)] = (f"whose tests attestation signature does not verify for {e.signer} "
                                         f"(namespace {NAMESPACE}) against {SIGNERS_PATH}")
            except NoteError as e:
                cache[("payload", c)] = f"whose tests attestation is not valid: {e.message.rstrip('.')}"
    p = cache[("payload", c)]
    if isinstance(p, str):
        return f"{label} is carried from {c7}, {p}"
    entry = ran_entries(p).get(label)
    if entry is None:
        source = next((e["carriedFrom"] for e in p.get("carried", []) if e["label"] == label), None)
        if source is not None:
            return (f"{label} is carried from {c7}, but {label} was carried at {c7} (from {source[:7]}) and "
                    f"did not run there; a carry must name the commit where the entry ran")
        return f"{label} is carried from {c7}, but {label} did not run at {c7}"
    if entry["result"] != "pass":
        return f"{label} is carried from {c7}, but {label} failed at {c7} ({entry['result']})"
    try:
        age = age_seconds(p, now)
    except NoteError as e:
        return f"{label} is carried from {c7}, whose run cannot be used: {e.message.rstrip('.')}"
    if age > MAX_AGE_DAYS * 86400:
        return (f"{label} is carried from {c7}, whose run finished {p['finishedAt']}, {_days(age)} days old "
                f"(a release accepts runs up to {MAX_AGE_DAYS} days old)")
    if ("between", c) not in cache:
        cache[("between", c)] = set(_git(repo, "rev-list", f"{c}..{tested}").stdout.split()) - {tested}
    newer = [(x, e) for x, _, e in runs.get(label, []) if x in cache[("between", c)]]
    if newer:
        x, e = newer[0]
        return f"{label} is carried from {c7}, but {label} ran again at {x[:7]} ({e['result']}), after {c7}"
    if ("changed", c) not in cache:
        cache[("changed", c)] = changed_files(repo, c, tested)
    changed = cache[("changed", c)]
    hit = affected_suites(m, changed)
    if hit == "ALL":
        for path in changed:
            kind, _ = classify(m, path)
            if kind in ("shared", "unmatched"):
                where = "a shared path" if kind == "shared" else f"in no section of {MAP_PATH}"
                return f"{label} is carried from {c7}, but {path} changed since then ({where})"
    if suite in hit:
        path = next(path for path in changed if suite in classify(m, path)[1])
        return f"{label} is carried from {c7}, but {path} changed since then (in [suite {suite}] of {MAP_PATH})"
    return None


def verify_release(repo, tested, release, notes_ref, now) -> str:
    """The OK line of the release check of release, whose tests ran at
    tested (release itself, or its parent for a version bump). Raises
    NoteError (one line per problem) or GitError when the release is not
    allowed. A carried entry is proven from its source note, never from
    what the tested note claims about it."""
    tested, release = _commit(repo, tested), _commit(repo, release)
    t7 = tested[:7]
    fix = f" - run tests/attest.sh on {t7} (see CONTRIBUTING.md), then re-run this check."
    text = read_note(repo, notes_ref, tested)
    if text is None:
        raise NoteError(f"No tests attestation for {t7}." + fix)
    with tempfile.TemporaryDirectory() as tmp:
        signers_path = tmp + "/allowed_signers"
        with open(signers_path, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(_show(repo, release, SIGNERS_PATH))
        entries = expected_entries(_show(repo, tested, ALLSH_PATH))
        try:
            p = verify_note(text, signers_path, tmp)
            check_payload(p, tested, _git(repo, "rev-parse", tested + "^{tree}").stdout.strip(), False)
        except SignatureError as e:
            raise NoteError(f"The tests attestation signature for {t7} does not verify for {e.signer} "
                            f"(namespace {NAMESPACE}) against {SIGNERS_PATH} of {release[:7]}." + fix)
        except NoteError as e:
            raise NoteError(e.message + fix)
        ran = ran_entries(p)
        carried = {e["label"]: e["carriedFrom"] for e in p.get("carried", [])}
        not_passed = [label for label, e in ran.items() if e["result"] != "pass"]
        if p["failed"] != 0 or not_passed:
            detail = f" (not passed: {' '.join(not_passed)})" if not_passed else ""
            raise NoteError(f"The tests attestation for {t7} is red: {p['passed']} passed, "
                            f"{p['failed']} failed{detail}." + fix)
        missing = [label for label, _ in entries if label not in ran and label not in carried]
        if missing:
            raise NoteError(f"The tests attestation for {t7} does not cover every entry of {ALLSH_PATH}; "
                            f"missing or not passed: {' '.join(missing)}." + fix)
        try:
            age = age_seconds(p, now)
        except NoteError as e:
            raise NoteError(e.message + fix)
        if age > MAX_AGE_DAYS * 86400:
            raise NoteError(f"The tests attestation for {t7} finished at {p['finishedAt']}, {_days(age)} days "
                            f"old (a release accepts runs up to {MAX_AGE_DAYS} days old)." + fix)
        to_prove = [(label, suite) for label, suite in entries if label in carried]
        errors, notes = [], [f"{label}: {n}" for label, e in ran.items() for n in e.get("notes", [])]
        if to_prove:
            m = parse_map(_show(repo, tested, MAP_PATH))
            runs, _ = _runs(repo, tested, notes_ref, signers_path, False)
            cache = {}
            for label, suite in to_prove:
                error = _carry_error(repo, notes_ref, m, tested, label, suite, carried[label], signers_path,
                                     tmp, runs, cache, now)
                if error:
                    errors.append(error + "." + fix)
                else:
                    source = ran_entries(cache[("payload", carried[label])])[label]
                    notes += [f"{label}: {n}" for n in source.get("notes", [])]
        if errors:
            raise NoteError("\n".join(errors))
    sources = [f"{label} from {carried[label][:7]}" for label, _ in to_prove]
    detail = (" ".join(ran) or "nothing ran") + (f"; carried: {', '.join(sources)}" if sources else "")
    notes_part = f"; notes: {', '.join(notes)}" if notes else ""
    return (f"Tests attestation OK for {t7}, signed by {p['signer']}: {len(ran)} ran, {p['passed']} passed, "
            f"{p['failed']} failed, {len(sources)} carried ({detail}; {p.get('arch')}, {p.get('os')}, "
            f"finished {p.get('finishedAt')}{notes_part})")


# --- CLI --------------------------------------------------------------------

def _cmd_check_map(a) -> int:
    commit = _commit(a.repo, a.commit)
    m = parse_map(_show(a.repo, commit, MAP_PATH))
    tree = _git(a.repo, "ls-tree", commit, "roles/").stdout
    roles = [line.split("\t", 1)[1] for line in tree.splitlines() if line.split()[1:2] == ["tree"]]
    paths = [p for p in _git(a.repo, "ls-tree", "-r", "-z", "--name-only", commit, "--", "roles", "tests").stdout.split("\0")
             if p.startswith("tests/") or (len(p.split("/")) >= 4 and p.split("/")[2] in ROLE_REF_DIRS)]
    errors = check_map(m, _show(a.repo, commit, ALLSH_PATH), roles, _read_files(a.repo, commit, paths))
    for e in errors:
        print("::error::" + e)
    if errors:
        return 1
    print(f"{MAP_PATH} OK at {commit[:7]}: {len(m['suites'])} suites, {len(roles)} roles mapped")
    return 0


def _cmd_plan(a) -> int:
    result = plan(a.repo, a.head, a.notes_ref, a.signers, a.now, a.all, a.allow_dry_run)
    print(json.dumps(result, indent=2))
    return 0


def _cmd_build_payload(a) -> int:
    with open(a.plan, encoding="utf-8") as f:
        plan_entries = json.load(f)
    with open(a.summary, encoding="utf-8") as f:
        summary = f.read()
    if not isinstance(plan_entries, list):
        raise ValueError("the plan is malformed")
    p = build_payload(plan_entries, summary, a.commit, a.tree, a.signer, a.arch, a.os, a.docker,
                      a.started, a.finished, a.dry_run)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(json.dumps(p, separators=(",", ":")) + "\n")
    ran = {e["label"] for e in p["suites"]}
    missing = [e["label"] for e in plan_entries if e["action"] == "run" and e["label"] not in ran]
    if missing:
        print("missing from the summary: " + " ".join(missing), file=sys.stderr)
    print(len(p["suites"]), p["passed"], p["failed"], p["carriedCount"])
    return 0


def _cmd_verify(a) -> int:
    try:
        print(verify_release(a.repo, a.tested, a.release, a.notes_ref, a.now))
    except NoteError as e:
        for line in e.message.splitlines():
            print("::error::" + line)
        return 1
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="attest_carry.py")
    sub = parser.add_subparsers(dest="cmd")
    sub.required = True
    c = sub.add_parser("check-map")
    c.add_argument("--repo", required=True)
    c.add_argument("--commit", required=True)
    c.set_defaults(func=_cmd_check_map)
    c = sub.add_parser("plan")
    for name in ("--repo", "--head", "--notes-ref", "--signers"):
        c.add_argument(name, required=True)
    c.add_argument("--now", required=True, type=int)
    c.add_argument("--all", action="store_true")
    c.add_argument("--allow-dry-run", action="store_true")
    c.set_defaults(func=_cmd_plan)
    c = sub.add_parser("build-payload")
    for name in ("--plan", "--summary", "--out", "--commit", "--tree", "--signer", "--arch", "--os",
                 "--docker", "--started", "--finished"):
        c.add_argument(name, required=True)
    c.add_argument("--dry-run", action="store_true")
    c.set_defaults(func=_cmd_build_payload)
    c = sub.add_parser("verify")
    for name in ("--repo", "--tested", "--release", "--notes-ref"):
        c.add_argument(name, required=True)
    c.add_argument("--now", required=True, type=int)
    c.set_defaults(func=_cmd_verify)
    a = parser.parse_args(argv)
    try:
        return a.func(a)
    except NoteError as e:
        print("::error::" + e.message)
    except (ValueError, GitError, OSError) as e:
        print("::error::" + str(e))
    return 1


if __name__ == "__main__":
    sys.exit(main())
