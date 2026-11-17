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

Errors print "::error::<message>" on stdout and exit 1.

The map, tests/suites.conf, is line based: "#" starts a comment, sections are
[ignore], [shared] and [suite <name>], every other line is a pattern. A
pattern ending in "/" matches the paths below it, any other pattern is an
fnmatch pattern ("*" also matches "/"). Per changed file: [ignore] touches no
suite, [shared] every suite, a suite pattern that suite (a file may touch
several), and a file no pattern matches every suite.
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
TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
LABEL_RE = re.compile(r"[A-Za-z0-9._-]+")
SHA_RE = re.compile(r"[0-9a-f]{40}")
# Top-level files outside any suite that [ignore] may name besides *.md.
IGNORABLE_TOP_LEVEL = ("LICENSE", ".ansible-lint", ".yamllint", ".gitignore")
RELEASE_SUITES = ("host", "services")  # one entry per release: <suite>-<release>


class NoteError(Exception):
    """A note or payload that cannot be trusted; message says why."""

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


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


def classify(m: dict, path: str) -> tuple:
    """("ignored"|"shared"|"unmatched", set()) or ("suites", {names})."""
    if any(matches(path, p) for p in m["ignore"]):
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


def check_map(m: dict, allsh: str, role_dirs: list) -> list:
    """Errors of the map against all_suites and the roles (role names, or
    roles/<name>/ paths)."""
    try:
        suites = list(dict.fromkeys(suite for _, suite in expected_entries(allsh)))
    except ValueError as e:
        return [str(e)]
    errors = [f"suite {s} of all_suites has no [suite {s}] section in tests/suites.conf"
              for s in suites if s not in m["suites"]]
    errors += [f"[suite {s}] in tests/suites.conf is not a suite of all_suites in tests/all.sh"
               for s in m["suites"] if s not in suites]
    claimed = {p for patterns in m["suites"].values() for p in patterns}
    for role in role_dirs:
        name = role[len("roles/"):] if role.startswith("roles/") else role
        prefix = "roles/" + name.strip("/") + "/"
        if prefix not in claimed:
            errors.append(f"{prefix} is in no [suite] section of tests/suites.conf; "
                          f"add the exact pattern {prefix} to each suite that uses the role")
    errors += [f"[ignore] pattern {p} in tests/suites.conf is too broad: [ignore] may only name "
               f"top-level *.md files, {', '.join(IGNORABLE_TOP_LEVEL)}, roles/*/README.md and "
               f"paths under .github/ outside .github/scripts/"
               for p in m["ignore"] if not _ignore_allowed(p)]
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
        raise NoteError(f"The tests attestation signature does not verify for {signer} (namespace {NAMESPACE}).")
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

def _runs(repo: str, head: str, notes_ref: str, signers_path: str, allow_dry_run: bool) -> dict:
    """label -> [(commit, payload, entry)] of the valid notes of head's
    ancestors (head itself excluded: its note is the one to be replaced),
    descendants before their ancestors."""
    noted = _noted_commits(repo, notes_ref)
    runs = {}
    if not noted:
        return runs
    order = _git(repo, "rev-list", "--topo-order", head).stdout.split()
    with tempfile.TemporaryDirectory() as tmp:
        for commit in order:
            if commit == head or commit not in noted:
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
            for label, entry in ran_entries(p).items():
                runs.setdefault(label, []).append((commit, p, entry))
    return runs


def _decide(repo, m, head, label, suite, candidates, now, cache) -> dict:
    run = {"label": label, "suite": suite, "action": "run"}
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
    runs = _runs(repo, head, notes_ref, signers_path, allow_dry_run)
    cache = {}
    return [_decide(repo, m, head, label, suite, runs.get(label, []), now, cache) for label, suite in entries]


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


def verify_release(repo, tested, release, notes_ref, now) -> str:
    raise NotImplementedError("verify_release is Task 4")


# --- CLI --------------------------------------------------------------------

def _cmd_check_map(a) -> int:
    commit = _commit(a.repo, a.commit)
    m = parse_map(_show(a.repo, commit, MAP_PATH))
    tree = _git(a.repo, "ls-tree", commit, "roles/").stdout
    roles = [line.split("\t", 1)[1] for line in tree.splitlines() if line.split()[1:2] == ["tree"]]
    errors = check_map(m, _show(a.repo, commit, ALLSH_PATH), roles)
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
    print("::error::not implemented")
    return 1


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
