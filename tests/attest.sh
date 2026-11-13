#!/usr/bin/env bash
# Runs every Docker test suite (tests/all.sh --keep-going) on this machine and
# publishes a SIGNED result for the exact commit it ran against. The tag
# workflow release-gate.yml checks it with
# .github/scripts/verify-tests-attestation.sh and flags a release tag that
# has no valid, green attestation (it cannot stop the tag itself).
#
#   tests/attest.sh
#
# It takes no suite arguments: an attestation always covers every suite in
# all_suites of tests/all.sh, the host suite once per release in its
# host_releases. It refuses to start while a variable that narrows or
# changes what the suites run is set (coverage_knobs below; add a suite's
# new knob there).
#
# What it publishes, for HEAD:
#   - a git note under refs/notes/tests: "payload: <base64 JSON>" and an SSH
#     signature over the payload (ssh-keygen -Y sign, namespace
#     noixdev-infra-tests), pushed to origin;
#   - a commit status "tests/local" on GitHub (gh api), success or failure.
# A red run is published too; the exit code is then 1 (0 when green, 2 when a
# precondition fails or nothing was published).
#
# The payload is public: commit, tree, signer, each run entry's label, result
# and seconds, the counts, the machine's architecture and OS, the Docker
# server version and the start and end time (UTC). No host name, no user
# name, no paths. "failed" counts the entries that did not pass plus the
# expected entries (each suite; host-<release> per host release) without
# one; green means failed 0, passed > 0.
#
# Preconditions, checked before any suite runs: no coverage knob set, a clean
# working tree (untracked files included), HEAD on a branch of origin (after
# git fetch --prune origin), a signing key, a signer identity, ssh-keygen,
# python3, Docker and an authenticated gh. After the run it refuses to
# publish when HEAD moved or the working tree is not clean; that compares
# the end state only (a file changed and restored during the run goes
# unnoticed).
#
# Before the push, the local refs/notes/tests is replaced by origin's (or
# removed when origin has none), so only origin's notes plus this run's note
# are pushed. A note that exists only in the local ref is dropped.
#
# Signing key: $TESTS_SIGNING_KEY, else `git config user.signingkey`, else
# ~/.ssh/id_ed25519.pub. A public key path signs through the SSH agent. A
# "key::" literal in user.signingkey is not supported; set TESTS_SIGNING_KEY
# to a key file instead. Signer: $TESTS_SIGNER, else `git config user.email`;
# it has to be listed with that key in .github/tests-allowed-signers.
#
# For the self-test only (tests/attest/selftest.sh):
#   ATTEST_DRY_RUN=1   skips the remote checks (git fetch, HEAD on origin),
#                      gh, the notes fetch and push and the status call, and
#                      prints what it would do. The note goes to the local
#                      refs/notes/tests-dry-run, never to refs/notes/tests,
#                      and its payload carries "dryRun":true, which the
#                      release check refuses.
#   ATTEST_RUNNER=FILE (only with ATTEST_DRY_RUN=1) runs FILE (one
#                      executable, no arguments of its own) instead of
#                      tests/all.sh, with the same arguments (--keep-going
#                      --summary FILE); Docker is then not required and the
#                      payload's docker field is "unknown", which the
#                      release check refuses too.
set -euo pipefail

NAMESPACE=noixdev-infra-tests
NOTES_REF=refs/notes/tests
DRY_RUN_NOTES_REF=refs/notes/tests-dry-run
STATUS_CONTEXT=tests/local
# Variables of tests/all.sh and the suites that narrow or change what runs.
coverage_knobs=(HOST_UBUNTU UBUNTU KEEP STUB_ONLY RC_STUB_ONLY RC_REAL_ONLY ANUBIS_REAL_ONLY ROUNDCUBE_OLD ROUNDCUBE_NEW MAILCOW_TAKEOVER_TAG ANSIBLE_RUN_TAGS ANSIBLE_SKIP_TAGS)

fail() {
  echo "tests/attest.sh: $*" >&2
  exit 2
}

[ "$#" -eq 0 ] || fail "takes no arguments; an attestation always covers every suite of tests/all.sh"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)" || fail "not inside a git repository"
cd "$root"

case "${ATTEST_DRY_RUN:-0}" in
  0 | 1) dry_run="${ATTEST_DRY_RUN:-0}" ;;
  *) fail "ATTEST_DRY_RUN must be 1 or unset" ;;
esac
if [ -n "${ATTEST_RUNNER+set}" ] && [ "$dry_run" != 1 ]; then
  fail "ATTEST_RUNNER is for the self-test only and needs ATTEST_DRY_RUN=1; unset it"
fi
runner="${ATTEST_RUNNER:-$root/tests/all.sh}"
notes_ref="$NOTES_REF"
[ "$dry_run" != 1 ] || notes_ref="$DRY_RUN_NOTES_REF"

set_knobs=()
for knob in "${coverage_knobs[@]}"; do
  [ -z "${!knob+set}" ] || set_knobs+=("$knob")
done
if [ "${#set_knobs[@]}" -gt 0 ]; then
  fail "unset ${set_knobs[*]} first: an attestation runs every suite in full"
fi

for tool in git ssh-keygen python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  fail "the working tree is not clean (untracked files included). Commit first: the result has to match a commit."
fi

commit="$(git rev-parse HEAD)"
tree="$(git rev-parse 'HEAD^{tree}')"

repo=
if [ "$dry_run" = 1 ]; then
  echo "dry run: skipping git fetch origin and the check that ${commit:0:7} is on a branch of origin"
else
  git fetch --quiet --prune origin || fail "git fetch origin failed"
  if [ -z "$(git branch -r --contains "$commit" --list 'origin/*')" ]; then
    fail "HEAD ${commit:0:7} is not on a branch of origin yet. Push it first."
  fi
  url="$(git remote get-url origin)"
  repo="$(printf '%s\n' "$url" | sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p')"
  repo="${repo%.git}"
  [ -n "$repo" ] || fail "cannot read the GitHub repository from the origin URL"
fi

key="${TESTS_SIGNING_KEY:-}"
if [ -z "$key" ]; then
  key="$(git config user.signingkey || true)"
fi
[ -n "$key" ] || key="$HOME/.ssh/id_ed25519.pub"
case "$key" in
  key::*) fail "the signing key is a \"key::\" literal (as git config user.signingkey allows), which is not supported. Set TESTS_SIGNING_KEY to the key file (a .pub file signs through the SSH agent)." ;;
  [~]/*) key="$HOME/${key#?/}" ;; # a literal ~/ from git config
esac
[ -f "$key" ] || fail "signing key $key not found. Set TESTS_SIGNING_KEY (a .pub file signs through the SSH agent)."

signer="${TESTS_SIGNER:-}"
if [ -z "$signer" ]; then
  signer="$(git config user.email || true)"
fi
[ -n "$signer" ] || fail "no signer identity. Set TESTS_SIGNER or git config user.email."
case "$signer" in
  *[[:space:]]*) fail "the signer identity \"$signer\" contains white space" ;;
esac

if [ "$dry_run" != 1 ]; then
  command -v gh >/dev/null 2>&1 || fail "gh is required (it sets the commit status)"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in. Run gh auth login."
fi

docker=unknown
if [ -z "${ATTEST_RUNNER:-}" ]; then
  docker="$(docker version --format '{{.Server.Version}}' 2>/dev/null)" || fail "the Docker daemon is not reachable"
  [ -n "$docker" ] || fail "the Docker daemon is not reachable"
fi
[ -x "$runner" ] || fail "test runner $runner is not executable"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Sign once before the run, so a key the agent does not hold fails now and
# not after the suites. A signer the release check would not accept only
# warns here; the check decides.
printf 'noixdev-infra-tests key check\n' >"$work/check"
ssh-keygen -Y sign -q -f "$key" -n "$NAMESPACE" "$work/check" || fail "cannot sign with $key"
if ! git show "HEAD:.github/tests-allowed-signers" >"$work/allowed_signers" 2>/dev/null ||
  ! ssh-keygen -Y verify -f "$work/allowed_signers" -I "$signer" -n "$NAMESPACE" \
    -s "$work/check.sig" <"$work/check" >/dev/null 2>&1; then
  echo "tests/attest.sh: warning: $signer with this key is not in .github/tests-allowed-signers; the release check will refuse this attestation" >&2
fi

# Builds the payload from the summary and all_suites/host_releases of
# tests/all.sh at HEAD. Prints "<passed> <failed>"; exits non-zero with a
# message on bad input.
read -r -d '' payload_py <<'PY' || true
import json, re, sys

(out, summary_path, allsh_path, commit, tree, signer, arch, osname,
 docker, started, finished, dry_run) = sys.argv[1:]

allsh = open(allsh_path, encoding="utf-8").read()

def array(name):
    lines = re.findall(r"^" + name + r"=\(([^)]*)\)[ \t]*$", allsh, re.M)
    if len(lines) != 1:
        sys.exit(f"tests/all.sh must have exactly one {name}=(...) line")
    values = lines[0].split()
    if not values or not all(re.fullmatch(r"[A-Za-z0-9._-]+", v) for v in values):
        sys.exit(f"{name} in tests/all.sh is empty or malformed")
    return values

expected = []
for suite in array("all_suites"):
    if suite == "host":
        expected += ["host-" + r for r in array("host_releases")]
    else:
        expected.append(suite)

suites = []
for n, line in enumerate(open(summary_path, encoding="utf-8"), 1):
    if not line.strip():
        continue
    fields = line.split()
    if (len(fields) != 3 or not re.fullmatch(r"[A-Za-z0-9._-]+", fields[0])
            or fields[1] not in ("pass", "fail", "skipped")
            or not re.fullmatch(r"[0-9]+", fields[2])):
        sys.exit(f"summary line {n} is malformed: {line.strip()!r}")
    suites.append({"label": fields[0], "result": fields[1], "seconds": int(fields[2])})

labels = {e["label"] for e in suites}
passed = sum(1 for e in suites if e["result"] == "pass")
not_passed = sum(1 for e in suites if e["result"] != "pass")
missing = [l for l in expected if l not in labels]
failed = not_passed + len(missing)

payload = {
    "schema": 1,
    "commit": commit,
    "tree": tree,
    "signer": signer,
    "suites": suites,
    "passed": passed,
    "failed": failed,
    "arch": arch,
    "os": osname,
    "docker": docker,
    "startedAt": started,
    "finishedAt": finished,
}
if dry_run == "1":
    payload["dryRun"] = True
with open(out, "w", encoding="utf-8") as f:
    f.write(json.dumps(payload, separators=(",", ":")) + "\n")
if missing:
    print("missing from the summary: " + " ".join(missing), file=sys.stderr)
print(passed, failed)
PY

echo "==== attesting ${commit:0:7}: $runner --keep-going --summary <file>"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
start_epoch="$(date +%s)"
rc=0
"$runner" --keep-going --summary "$work/summary" || rc=$?
finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
minutes=$((($(date +%s) - start_epoch + 30) / 60))

if [ "$(git rev-parse HEAD)" != "$commit" ] || [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  fail "HEAD or the working tree changed during the run. Nothing published."
fi
[ -f "$work/summary" ] || fail "the test runner wrote no summary (exit $rc). Nothing published."

git show "$commit:tests/all.sh" >"$work/all.sh" || fail "tests/all.sh is missing at ${commit:0:7}. Nothing published."
arch="$(uname -m)"
counts="$(python3 -I -c "$payload_py" "$work/payload.json" "$work/summary" "$work/all.sh" \
  "$commit" "$tree" "$signer" "$arch" "$(uname -s)" "$docker" "$started" "$finished" "$dry_run")" ||
  fail "cannot build the payload. Nothing published."
read -r passed failed <<<"$counts"
green=0
if [ "$failed" = 0 ] && [ "$passed" -gt 0 ]; then
  green=1
fi
if [ "$green" = 1 ] && [ "$rc" != 0 ]; then
  fail "the test runner exited $rc although every entry passed. Nothing published."
fi

ssh-keygen -Y sign -q -f "$key" -n "$NAMESPACE" "$work/payload.json" || fail "signing failed. Nothing published."
{
  printf 'payload: %s\n' "$(base64 <"$work/payload.json" | tr -d '\n')"
  cat "$work/payload.json.sig"
} >"$work/note"

# Notes are a shared ref. Start from exactly origin's, so the push
# fast-forwards and carries nothing but origin's notes and this one.
if [ "$dry_run" = 1 ]; then
  echo "dry run: would replace the local $NOTES_REF by origin's"
else
  remote_rc=0
  git ls-remote --exit-code origin "$NOTES_REF" >/dev/null || remote_rc=$?
  case "$remote_rc" in
    0 | 2) ;;
    *) fail "cannot read $NOTES_REF from origin. Nothing published." ;;
  esac
  if git rev-parse --verify --quiet "$NOTES_REF" >/dev/null; then
    git update-ref -d "$NOTES_REF" || fail "cannot reset the local $NOTES_REF. Nothing published."
  fi
  if [ "$remote_rc" = 0 ]; then
    git fetch --quiet origin "+$NOTES_REF:$NOTES_REF" ||
      fail "fetching $NOTES_REF from origin failed. Nothing published."
  fi
fi
git notes --ref="$notes_ref" add -f -F "$work/note" "$commit" || fail "cannot write the note"

state=failure
[ "$green" = 1 ] && state=success
description="$passed passed, $failed failed ($minutes min, $arch, signed)"
description="${description:0:140}"

if [ "$dry_run" = 1 ]; then
  echo "dry run: note written to the local $notes_ref"
  echo "dry run: would push $NOTES_REF to origin"
  echo "dry run: would set the commit status $STATUS_CONTEXT=$state on $commit: $description"
else
  git push --quiet origin "$NOTES_REF" || {
    echo "tests/attest.sh: pushing $NOTES_REF failed; the note is written locally only" >&2
    exit 2
  }
  gh api --method POST "repos/$repo/statuses/$commit" \
    -f "state=$state" -f "context=$STATUS_CONTEXT" -f "description=$description" >/dev/null || {
    echo "tests/attest.sh: setting the commit status failed; the note is pushed" >&2
    exit 2
  }
fi

echo
if [ "$green" = 1 ]; then
  echo "green: $description"
else
  echo "red: $description"
fi
if [ "$dry_run" = 1 ]; then
  echo "attestation: $notes_ref on ${commit:0:7}, local only (dry run)"
else
  echo "attestation: $NOTES_REF on ${commit:0:7} pushed, status $STATUS_CONTEXT set"
fi
[ "$green" = 1 ] || exit 1
