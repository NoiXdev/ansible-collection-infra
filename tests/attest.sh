#!/usr/bin/env bash
# Runs the Docker test suites that need running on this machine, carries the
# others forward by reference, and publishes a SIGNED result for the exact
# commit it ran against. The tag workflow release-gate.yml checks it with
# .github/scripts/verify-tests-attestation.sh and flags a release tag that
# has no valid, green attestation (it cannot stop the tag itself).
#
#   tests/attest.sh [--all | --plan]
#
#   (none)  runs the entries that need running, carries the rest;
#   --all   runs every entry and carries nothing;
#   --plan  prints the plan, one line per entry, and exits 0 without running
#           or publishing anything:
#             <label>  run  <reason>
#             <label>  carry from <sha7> (<N> days)[, <note>...]
# Any other argument exits 2 with the usage.
#
# The entries are those of tests/all.sh at HEAD: each suite in all_suites,
# host and services once per release in host_releases and services_releases
# (host-<release>, services-<release>). The decision per entry is the `plan`
# of .github/scripts/attest_carry.py, which the release check shares: an
# entry is carried from the newest ancestor of HEAD whose valid, signed note
# ran it, when it passed there, finished less than 30 days minus a margin
# ago, and no file changed since then is shared, unmatched or of the entry's
# suite in tests/suites.conf; every other entry runs. HEAD's own note is no
# carry source, but an entry red there runs again. The map is checked first
# (check-map at HEAD); a map error refuses to start (exit 2), so no carry is
# published that the release check would refuse for the map.
#
# The entries to run go to tests/all.sh --keep-going --summary FILE -j N
# <label>..., N from ATTEST_JOBS (default 4: entries that run at the same time,
# within all.sh's RAM budget; it does not change what runs, so it is no
# coverage knob);
# when nothing runs (a docs-only commit), no runner is called and no Docker
# is needed. It refuses to start while a variable that narrows or changes
# what the suites run is set (coverage_knobs below; add a suite's new knob
# there).
#
# What it publishes, for HEAD:
#   - a git note under refs/notes/tests: "payload: <base64 JSON>" and an SSH
#     signature over the payload (ssh-keygen -Y sign, namespace
#     noixdev-infra-tests), pushed to origin;
#   - a commit status "tests/local" on GitHub (gh api), success or failure:
#     "<ran> ran, <passed> passed, <failed> failed, <carried> carried
#     (<min> min, <arch>, signed)", plus "; notes: <label> <note>, ..." when
#     an entry has notes, cut at 140 characters.
# A red run is published too; the exit code is then 1 (0 when green, 2 when a
# precondition fails or nothing was published).
#
# The payload (schema 2, built by attest_carry.py build-payload) is public:
# commit, tree, signer, each entry that ran with its label, result, seconds
# and notes ("suites"), each carried entry with its label and carriedFrom,
# the commit where it ran ("carried"), the counts (passed, failed,
# carriedCount), the machine's architecture and OS, the Docker server
# version ("none" when nothing ran) and the start and end time (UTC). No
# host name, no user name, no paths. "failed" counts the entries that ran
# and did not pass plus the entries to run without a summary line; green
# means failed 0 and every expected entry present, ran or carried.
#
# Preconditions, checked before any suite runs: no coverage knob set, a clean
# working tree (untracked files included), HEAD on a branch of origin (after
# git fetch --prune origin), a signing key, a signer identity, ssh-keygen,
# python3, an authenticated gh, a tests/suites.conf that check-map accepts,
# and Docker when an entry runs (that it runs linux/amd64 images too when
# harbor runs). --plan skips the signing key, signer, gh and Docker checks.
# After the run it refuses to publish when HEAD moved or the working tree is
# not clean; that compares the end state only (a file changed and restored
# during the run goes unnoticed).
#
# Before planning, the local refs/notes/tests is replaced by origin's (or
# removed when origin has none), also for --plan, so the plan sees exactly
# origin's notes. After the run it is replaced by origin's once more, then
# this run's note is added (replacing one on this commit) and pushed, so
# notes pushed during the run do not make the push fail, and only origin's
# notes plus this run's note are pushed. A note that exists only in the
# local ref is dropped. The plan verifies the notes against
# .github/tests-allowed-signers at the tested commit.
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
#                      prints what it would do. It plans from the local
#                      refs/notes/tests-dry-run (dry-run notes allowed), and
#                      the note goes there, never to refs/notes/tests; its
#                      payload carries "dryRun":true, which the release check
#                      refuses.
#   ATTEST_RUNNER=FILE (only with ATTEST_DRY_RUN=1) runs FILE (one
#                      executable, no arguments of its own) instead of
#                      tests/all.sh, with the same arguments (--keep-going
#                      --summary FILE -j N <label>...); Docker is then not
#                      required and the payload's docker field is "unknown"
#                      when anything ran, which the release check refuses too.
set -euo pipefail

NAMESPACE=noixdev-infra-tests
NOTES_REF=refs/notes/tests
DRY_RUN_NOTES_REF=refs/notes/tests-dry-run
STATUS_CONTEXT=tests/local
USAGE="usage: tests/attest.sh [--all | --plan]"
# Variables of tests/all.sh and the suites that narrow or change what runs
# (NOIXDEV_INFRA_TEST_HOST: e2e, host and services would share one container
# name, which entries running at the same time cannot). The selftest checks
# that every ${NAME:- a suite reads is here or harmless.
coverage_knobs=(HOST_UBUNTU SERVICES_UBUNTU UBUNTU KEEP STUB_ONLY RC_STUB_ONLY RC_REAL_ONLY ANUBIS_REAL_ONLY ROUNDCUBE_OLD ROUNDCUBE_NEW MAILCOW_TAKEOVER_TAG ANSIBLE_RUN_TAGS ANSIBLE_SKIP_TAGS NOIXDEV_INFRA_MAILCOW_DOCKER_VOLUME NOIXDEV_INFRA_SERVICES NOIXDEV_INFRA_N8N_TESTS NOIXDEV_INFRA_PAPERLESS_TESTS NOIXDEV_INFRA_TANDOOR_TESTS BACKREST_UBUNTU VAULTWARDEN_UBUNTU POSTAL_UBUNTU WAF_UBUNTU VARNISH_UBUNTU GRAYLOG_UBUNTU PULSIX_AGENT_UBUNTU NOIXDEV_INFRA_BACKREST_TESTS NOIXDEV_INFRA_GRAYLOG_TESTS NOIXDEV_INFRA_POSTAL_TESTS NOIXDEV_INFRA_PULSIX_AGENT_TESTS NOIXDEV_INFRA_VAULTWARDEN_TESTS NOIXDEV_INFRA_WAF_TESTS NOIXDEV_INFRA_WATCHTOWER_TESTS ANUBIS_SUITE_PART MOUNTS_SURVEY DEPENDS NOIXDEV_INFRA_TEST_HOST)

fail() {
  echo "tests/attest.sh: $*" >&2
  exit 2
}

mode=run
case "$#:${1:-}" in
  0:) ;;
  1:--all) mode=all ;;
  1:--plan) mode=plan ;;
  *)
    echo "$USAGE" >&2
    exit 2
    ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)" || fail "not inside a git repository"
cd "$root"
helper="$root/.github/scripts/attest_carry.py"

case "${ATTEST_DRY_RUN:-0}" in
  0 | 1) dry_run="${ATTEST_DRY_RUN:-0}" ;;
  *) fail "ATTEST_DRY_RUN must be 1 or unset" ;;
esac
if [ -n "${ATTEST_RUNNER+set}" ] && [ "$dry_run" != 1 ]; then
  fail "ATTEST_RUNNER is for the self-test only and needs ATTEST_DRY_RUN=1; unset it"
fi
runner="${ATTEST_RUNNER:-$root/tests/all.sh}"
jobs="${ATTEST_JOBS:-4}"
case "$jobs" in
  "" | *[!0-9]* | 0* | ????*) fail "ATTEST_JOBS must be a number from 1 to 999 (entries that run at the same time), not \"$jobs\"" ;;
esac
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

key=
signer=
if [ "$mode" != plan ]; then
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
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The release check proves every carry against the map at the tested commit
# and refuses all of them when check-map fails there; so refuse to start.
if ! python3 -I "$helper" check-map --repo "$root" --commit "$commit" >"$work/check-map" 2>&1; then
  sed 's/^::error::/  /' "$work/check-map" >&2
  fail "tests/suites.conf at ${commit:0:7} has the errors above; the release check would refuse every carry under it. Fix it in a new commit first."
fi
cat "$work/check-map"

# Notes are a shared ref. sync_notes replaces the local one by exactly
# origin's (or removes it when origin has none). It runs before the plan, so
# the plan sees what the release check will see, and again just before this
# run's note is added, so the push fast-forwards over notes pushed during
# the run and carries nothing but origin's notes and this one.
sync_notes() {
  local remote_rc=0
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
}
if [ "$dry_run" = 1 ]; then
  echo "dry run: would replace the local $NOTES_REF by origin's"
else
  sync_notes
fi

# The plan (attest_carry.py plan): per expected entry, "run" with a reason,
# or "carry" with carriedFrom.
git show "$commit:.github/tests-allowed-signers" >"$work/allowed_signers" 2>/dev/null || : >"$work/allowed_signers"
plan_args=(plan --repo "$root" --head "$commit" --notes-ref "$notes_ref" --signers "$work/allowed_signers"
  --now "$(date +%s)")
[ "$mode" != all ] || plan_args+=(--all)
[ "$dry_run" != 1 ] || plan_args+=(--allow-dry-run)
python3 -I "$helper" "${plan_args[@]}" >"$work/plan.json" 2>"$work/plan.err" || {
  cat "$work/plan.json" "$work/plan.err" | sed 's/^::error::/  /' >&2
  fail "cannot plan the run of ${commit:0:7}. Nothing published."
}

# view MODE [ARG]: reads the plan. "lines NOW" prints the --plan lines, "run"
# the labels to run, "count" the number of entries, "notes PAYLOAD" the notes
# of the status ("<label> <note>, ...") of the entries that ran (from
# PAYLOAD) and of the carried ones (from the plan), in the plan's order.
read -r -d '' view_py <<'PY' || true
import json, sys
from datetime import datetime, timezone

plan = json.load(open(sys.argv[1], encoding="utf-8"))
mode = sys.argv[2]
if mode == "lines":
    now = int(sys.argv[3])
    for e in plan:
        if e["action"] == "run":
            print(f"{e['label']}  run  {e['reason']}")
        else:
            finished = datetime.strptime(e["finishedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            days = max(0, (now - int(finished.timestamp())) // 86400)
            notes = "".join(", " + n for n in e.get("notes", []))
            print(f"{e['label']}  carry from {e['carriedFrom'][:7]} ({days} days){notes}")
elif mode == "run":
    print(" ".join(e["label"] for e in plan if e["action"] == "run"))
elif mode == "count":
    print(len(plan))
elif mode == "notes":
    ran = {e["label"]: e.get("notes", []) for e in json.load(open(sys.argv[3], encoding="utf-8"))["suites"]}
    print(", ".join(f"{e['label']} {n}" for e in plan
                    for n in (ran.get(e["label"], []) if e["action"] == "run" else e.get("notes", []))))
PY
view() { python3 -I -c "$view_py" "$work/plan.json" "$@"; }

plan_lines="$(view lines "$(date +%s)")" || fail "cannot read the plan. Nothing published."
if [ "$mode" = plan ]; then
  printf '%s\n' "$plan_lines"
  exit 0
fi
labels="$(view run)" || fail "cannot read the plan. Nothing published."
entries="$(view count)" || fail "cannot read the plan. Nothing published."
to_run=()
[ -z "$labels" ] || read -r -a to_run <<<"$labels"

docker=unknown
if [ "${#to_run[@]}" -gt 0 ] && [ -z "${ATTEST_RUNNER:-}" ]; then
  docker="$(docker version --format '{{.Server.Version}}' 2>/dev/null)" || fail "the Docker daemon is not reachable"
  [ -n "$docker" ] || fail "the Docker daemon is not reachable"
  case " ${to_run[*]} " in
    *" harbor "*)
      # The harbor suite runs amd64-only images; without emulation it fails
      # and the run would be published red for a reason outside the code.
      amd64="$(docker run --rm --platform linux/amd64 alpine:3 uname -m 2>/dev/null | tail -n 1)" || true
      [ "$amd64" = x86_64 ] ||
        fail "Docker cannot run linux/amd64 images, which the harbor suite needs. Docker Desktop on Apple silicon: install Rosetta 2 (softwareupdate --install-rosetta), turn on its Rosetta emulation and restart Docker Desktop; Linux: register QEMU for amd64 (tonistiigi/binfmt)."
      ;;
  esac
fi
[ "${#to_run[@]}" -eq 0 ] || [ -x "$runner" ] || fail "test runner $runner is not executable"

# Sign once before the run, so a key the agent does not hold fails now and
# not after the suites. A signer the release check would not accept only
# warns here; the check decides.
printf 'noixdev-infra-tests key check\n' >"$work/check"
ssh-keygen -Y sign -q -f "$key" -n "$NAMESPACE" "$work/check" || fail "cannot sign with $key"
if ! ssh-keygen -Y verify -f "$work/allowed_signers" -I "$signer" -n "$NAMESPACE" \
  -s "$work/check.sig" <"$work/check" >/dev/null 2>&1; then
  echo "tests/attest.sh: warning: $signer with this key is not in .github/tests-allowed-signers; the release check will refuse this attestation" >&2
fi

echo "==== plan of ${commit:0:7}"
printf '%s\n' "$plan_lines"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
start_epoch="$(date +%s)"
rc=0
if [ "${#to_run[@]}" -gt 0 ]; then
  echo "==== attesting ${commit:0:7}: $runner --keep-going --summary <file> -j $jobs ${to_run[*]}"
  "$runner" --keep-going --summary "$work/summary" -j "$jobs" "${to_run[@]}" || rc=$?
else
  echo "==== attesting ${commit:0:7}: nothing to run, every entry is carried"
  : >"$work/summary"
fi
finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
minutes=$((($(date +%s) - start_epoch + 30) / 60))

if [ "$(git rev-parse HEAD)" != "$commit" ] || [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  fail "HEAD or the working tree changed during the run. Nothing published."
fi
[ -f "$work/summary" ] || fail "the test runner wrote no summary (exit $rc). Nothing published."

arch="$(uname -m)"
payload_args=(build-payload --plan "$work/plan.json" --summary "$work/summary" --out "$work/payload.json"
  --commit "$commit" --tree "$tree" --signer "$signer" --arch "$arch" --os "$(uname -s)" --docker "$docker"
  --started "$started" --finished "$finished")
[ "$dry_run" != 1 ] || payload_args+=(--dry-run)
# Prints "<ran> <passed> <failed> <carried>".
counts="$(python3 -I "$helper" "${payload_args[@]}")" ||
  fail "cannot build the payload (${counts#::error::}). Nothing published."
read -r ran passed failed carried <<<"$counts"
green=0
if [ "$failed" = 0 ] && [ "$((ran + carried))" = "$entries" ]; then
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
# Origin's notes may have moved during the run: start from them again. The
# plan keeps the earlier snapshot; a note on this commit is replaced.
if [ "$dry_run" = 1 ]; then
  echo "dry run: would replace the local $NOTES_REF by origin's again"
else
  sync_notes
fi
git notes --ref="$notes_ref" add -f -F "$work/note" "$commit" || fail "cannot write the note"

state=failure
[ "$green" = 1 ] && state=success
notes="$(view notes "$work/payload.json")" || notes=
description="$ran ran, $passed passed, $failed failed, $carried carried ($minutes min, $arch, signed)${notes:+; notes: $notes}"
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
