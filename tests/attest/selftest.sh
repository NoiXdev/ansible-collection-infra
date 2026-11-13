#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted $ is intended: stub scripts, sh -c
# Self-test of the attestation: tests/attest.sh, tests/all.sh --summary and
# .github/scripts/verify-tests-attestation.sh. No Docker, no network: it works
# in a throwaway git repository with throwaway ed25519 keys, a copy of the
# three scripts and stub suites behind the real tests/all.sh. Most cases use
# ATTEST_DRY_RUN=1; the "real mode" cases push to local bare repositories
# with fake docker and gh commands. CI runs it (ci.yml).
#
#   tests/attest/selftest.sh
set -uo pipefail

src="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Isolate git from the user's and the system's configuration (signing
# commits, hooks, default branch) and from the user's keys, without
# changing any of them.
mkdir -p "$tmp/home"
export HOME="$tmp/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@example.com
export GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@example.com
read -r -a knobs <<<"$(sed -nE 's/^coverage_knobs=\(([^)]*)\)$/\1/p' "$src/tests/attest.sh")"
[ "${#knobs[@]}" -gt 0 ] || {
  echo "selftest: no coverage_knobs=(...) line in tests/attest.sh" >&2
  exit 1
}
unset SSH_AUTH_SOCK TESTS_SIGNING_KEY TESTS_SIGNER ATTEST_RUNNER STUB_FAIL "${knobs[@]}"

failures=0
count=0
ok() {
  count=$((count + 1))
  echo "ok $count - $1"
}
not_ok() {
  count=$((count + 1))
  failures=$((failures + 1))
  echo "not ok $count - $1"
  sed 's/^/    | /' "$tmp/out"
}

# expect DESCRIPTION RC TEXT -- COMMAND...: runs COMMAND in the repo and
# checks its exit code and that its output (stdout and stderr) has TEXT.
expect() {
  local desc="$1" want_rc="$2" want_text="$3" rc=0
  shift 4
  (cd "$repo" && "$@") >"$tmp/out" 2>&1 || rc=$?
  if [ "$rc" != "$want_rc" ]; then
    echo "    expected exit $want_rc, got $rc" >>"$tmp/out"
    not_ok "$desc"
  elif ! grep -qF -- "$want_text" "$tmp/out"; then
    echo "    expected output with: $want_text" >>"$tmp/out"
    not_ok "$desc"
  else
    ok "$desc"
  fi
}
check() { # check DESCRIPTION COMMAND...: passes when COMMAND succeeds
  local desc="$1"     # (it may read $tmp/out of the previous expect)
  shift
  if (cd "$repo" && "$@") >"$tmp/out.check" 2>&1; then
    ok "$desc"
  else
    mv "$tmp/out.check" "$tmp/out"
    not_ok "$desc"
  fi
}

g() { git -C "$repo" "$@"; }
head_sha() { g rev-parse HEAD; }
REAL=refs/notes/tests
DRY=refs/notes/tests-dry-run
note_of() { g notes --ref="$1" show "$2" 2>/dev/null; } # note_of REF COMMIT
decode() { sed -n 's/^payload: //p' | python3 -I -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read().strip()))'; }
payload_of() { note_of "$1" "$2" | decode; } # payload_of REF COMMIT
commit_change() { # commit_change MESSAGE: a commit that changes code
  echo "$1" >>"$repo/roles.txt"
  g add -A && g commit -q -m "$1"
}
# json_edit FILE PYTHON: runs PYTHON on the payload p, writes it back as
# tests/attest.sh writes it (one compact line).
json_edit() {
  python3 -I -c 'import json,sys
p = json.load(open(sys.argv[1]))
exec(sys.argv[2])
open(sys.argv[1], "w").write(json.dumps(p, separators=(",", ":")) + "\n")' "$1" "$2"
}

# Relative to the repo, where expect and check run their commands.
A=tests/attest.sh
V=.github/scripts/verify-tests-attestation.sh

# sign_note COMMIT PAYLOAD KEY [NAMESPACE]: writes PAYLOAD signed by KEY as
# the note of COMMIT in refs/notes/tests, as a real run of tests/attest.sh
# would.
sign_note() {
  local commit="$1" payload="$2" key="$3" ns="${4:-noixdev-infra-tests}"
  rm -f "$payload.sig"
  ssh-keygen -Y sign -q -f "$key" -n "$ns" "$payload"
  {
    printf 'payload: %s\n' "$(base64 <"$payload" | tr -d '\n')"
    cat "$payload.sig"
  } >"$tmp/note"
  g notes --ref="$REAL" add -f -F "$tmp/note" "$commit" 2>/dev/null
}
# promote COMMIT [KEY]: turns the dry run's payload of COMMIT into a real
# run's (no dryRun, a Docker version), signed by KEY into refs/notes/tests.
# Everything else is what tests/attest.sh produced.
promote() {
  payload_of "$DRY" "$1" >"$tmp/promoted.json"
  json_edit "$tmp/promoted.json" 'del p["dryRun"]; p["docker"] = "29.0.0-selftest"'
  sign_note "$1" "$tmp/promoted.json" "${2:-$tmp/key}"
}

# --- setup -----------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -C selftest -f "$tmp/key"
ssh-keygen -q -t ed25519 -N '' -C other -f "$tmp/other"
export TESTS_SIGNING_KEY="$tmp/key" TESTS_SIGNER=maintainer@example.com

repo="$tmp/repo"
mkdir -p "$repo/tests" "$repo/.github/scripts"
git init -q -b main "$repo"
cp "$src/tests/all.sh" "$src/tests/attest.sh" "$repo/tests/"
cp "$src/.github/scripts/verify-tests-attestation.sh" "$repo/.github/scripts/"
echo "maintainer@example.com namespaces=\"noixdev-infra-tests\" $(cat "$tmp/key.pub")" >"$repo/.github/tests-allowed-signers"
printf 'tests/output/\n' >"$repo/.gitignore"
printf 'namespace: noixdev\nname: infra\nversion: 0.1.0\ndescription: selftest\n' >"$repo/galaxy.yml"
printf '# Changelog\n\n## Unreleased\n' >"$repo/CHANGELOG.md"
read -r -a suites <<<"$(sed -nE 's/^all_suites=\(([^)]*)\)$/\1/p' "$repo/tests/all.sh")"
read -r -a releases <<<"$(sed -nE 's/^host_releases=\(([^)]*)\)$/\1/p' "$repo/tests/all.sh")"
if [ "${#suites[@]}" -eq 0 ] || [ "${#releases[@]}" -lt 2 ]; then
  echo "selftest: tests/all.sh needs all_suites=(...) and host_releases=(...) with two releases or more" >&2
  exit 1
fi
last_suite="${suites[${#suites[@]} - 1]}"
last_host="host-${releases[${#releases[@]} - 1]}"
# A stub per suite: fails when its label is in STUB_FAIL.
stub() { # stub PATH LABEL-EXPRESSION
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\nlabel="%s"\ncase " ${STUB_FAIL:-} " in *" $label "*) echo "$label failed"; exit 1 ;; esac\necho "$label passed"\n' "$2" >"$1"
  chmod +x "$1"
}
for suite in "${suites[@]}"; do
  case "$suite" in
    e2e) stub "$repo/tests/run.sh" e2e ;;
    host) stub "$repo/tests/host/run.sh" 'host-$UBUNTU' ;;
    *) stub "$repo/tests/$suite/run.sh" "$suite" ;;
  esac
done
g add -A && g commit -q -m "chore: selftest repo"

# A fake runner outside the repo: writes $FAKE_SUMMARY as the summary,
# commits during the run with FAKE_COMMIT=1, marks that it ran.
cat >"$tmp/runner" <<EOF
#!/usr/bin/env bash
touch "$tmp/runner-ran"
[ "\$1" = --keep-going ] && [ "\$2" = --summary ] || exit 9
printf '%s\n' "\${FAKE_SUMMARY:-}" >"\$3"
if [ "\${FAKE_COMMIT:-0}" = 1 ]; then
  echo during >>"$repo/roles.txt"
  git -C "$repo" add roles.txt && git -C "$repo" commit -q -m during
fi
exit "\${FAKE_RC:-0}"
EOF
chmod +x "$tmp/runner"
all_pass="$(for s in "${suites[@]}"; do
  if [ "$s" = host ]; then
    for r in "${releases[@]}"; do echo "host-$r pass 3"; done
  else
    echo "$s pass 2"
  fi
done)"

# Dry run with the real tests/all.sh of the repo (stub suites) by default.
export ATTEST_DRY_RUN=1 ATTEST_RUNNER="$repo/tests/all.sh"

# --- tests/all.sh --summary -------------------------------------------------
expect "all.sh: --summary without a file is rejected" 2 "usage:" -- tests/all.sh --summary
expect "all.sh: an unknown suite is rejected" 2 "unknown suite: bogus" -- tests/all.sh --summary "$tmp/s" bogus
check "all.sh: rejected runs write no summary" test ! -e "$tmp/s"
expect "all.sh: all stub suites pass" 0 "summary" -- tests/all.sh --keep-going --summary "$tmp/s"
check "all.sh: one summary line per run entry, host once per host_releases entry" \
  test "$(cut -d' ' -f1,2 "$tmp/s")" = "$(printf '%s\n' "$all_pass" | cut -d' ' -f1,2)"
expect "all.sh: a failing suite without --keep-going stops the run" 1 "stopped after the first failure" -- \
  env STUB_FAIL=e2e tests/all.sh --summary "$tmp/s"
check "all.sh: the summary marks the failure and the skipped rest" \
  test "$(head -2 "$tmp/s" | cut -d' ' -f1,2)" = "$(printf 'e2e fail\nhost-%s skipped' "${releases[0]}")"

# --- 1. green run -------------------------------------------------------------
c1="$(head_sha)"
expect "1. green run: attest exits 0" 0 "green: " -- "$A"
check "1. green run: the dry run publishes nothing remote" grep -qF "dry run: would push refs/notes/tests" "$tmp/out"
check "1. green run: the note goes to refs/notes/tests-dry-run" grep -qF "note written to the local $DRY" "$tmp/out"
check "1. green run: the dry run leaves refs/notes/tests alone" sh -c '! git rev-parse --verify --quiet refs/notes/tests'
check "1. green run: the note has the payload and the signature" \
  sh -c 'git notes --ref="$1" show HEAD | grep -q "^payload: " && git notes --ref="$1" show HEAD | grep -qx -- "-----BEGIN SSH SIGNATURE-----"' _ "$DRY"
payload_of "$DRY" "$c1" >"$tmp/green.json"
check "1. green run: the payload keys are in order, dry run marked" \
  python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1])); assert list(p)==["schema","commit","tree","signer","suites","passed","failed","arch","os","docker","startedAt","finishedAt","dryRun"], list(p); assert p["dryRun"] is True and p["docker"]=="unknown"; assert p["failed"]==0 and p["passed"]==len(p["suites"])' "$tmp/green.json"
check "1. green run: the payload has no path, user or host name" \
  sh -c '! grep -q / "$1" && ! grep -qiF "\"$2\"" "$1" && ! grep -qiF "\"$3\"" "$1"' _ "$tmp/green.json" "${USER:-nobody}" "$(hostname -s 2>/dev/null || echo nohostname)"
g notes --ref="$REAL" add -f -m "$(note_of "$DRY" "$c1")" "$c1"
expect "1. green run: verifier refuses the dry-run note as it is" 1 "is from a dry run" -- "$V" HEAD
cp "$tmp/green.json" "$tmp/nodocker.json"
json_edit "$tmp/nodocker.json" 'del p["dryRun"]'
sign_note "$c1" "$tmp/nodocker.json" "$tmp/key"
expect "1. green run: verifier refuses docker \"unknown\" (a fake runner)" 1 "records no Docker version" -- "$V" HEAD
promote "$c1"
expect "1. green run: as a real run's payload the verifier allows it" 0 "Tests attestation OK for ${c1:0:7}" -- "$V" HEAD

# --- 2. a suite failing ---------------------------------------------------------
commit_change "feat: two"
c2="$(head_sha)"
expect "2. failing suite: attest exits 1 and still publishes" 1 "red: " -- env STUB_FAIL=mailcow "$A"
check "2. failing suite: a note is written" note_of "$DRY" "$c2"
promote "$c2"
expect "2. failing suite: verifier refuses" 1 "is red: " -- "$V" HEAD
check "2. failing suite: verifier names the failed entry" grep -qF "not passed: mailcow" "$tmp/out"

# --- 3. a suite missing from the summary -----------------------------------------
commit_change "feat: three"
c3="$(head_sha)"
expect "3. missing suite: attest exits 1" 1 "red: " -- \
  env ATTEST_RUNNER="$tmp/runner" FAKE_SUMMARY="$(printf '%s\n' "$all_pass" | grep -v "^$last_suite ")" "$A"
check "3. missing suite: attest names it" grep -qF "missing from the summary: $last_suite" "$tmp/out"
promote "$c3"
expect "3. missing suite: verifier refuses" 1 "is red: " -- "$V" HEAD
commit_change "feat: three b"
c3b="$(head_sha)"
expect "3. missing host release: attest exits 1" 1 "red: " -- \
  env ATTEST_RUNNER="$tmp/runner" FAKE_SUMMARY="$(printf '%s\n' "$all_pass" | grep -v "^$last_host ")" "$A"
check "3. missing host release: attest names it" grep -qF "missing from the summary: $last_host" "$tmp/out"
payload_of "$REAL" "$c1" >"$tmp/p3.json"
json_edit "$tmp/p3.json" "p['commit'] = '$c3b'; p['tree'] = '$(g rev-parse "$c3b^{tree}")'
p['suites'] = [e for e in p['suites'] if e['label'] != '$last_host']; p['passed'] = len(p['suites'])"
sign_note "$c3b" "$tmp/p3.json" "$tmp/key"
expect "3. missing host release: a green-looking payload is refused" 1 "missing or not passed: $last_host" -- "$V" HEAD
payload_of "$REAL" "$c1" >"$tmp/p3.json"
json_edit "$tmp/p3.json" "p['commit'] = '$c3b'; p['tree'] = '$(g rev-parse "$c3b^{tree}")'
for e in p['suites']:
    if e['label'] == 'e2e': e['label'] = 'e2e-extra'"
sign_note "$c3b" "$tmp/p3.json" "$tmp/key"
expect "3. exact labels: e2e-extra does not count as e2e" 1 "missing or not passed: e2e" -- "$V" HEAD

# --- 4. payload tampered after signing ---------------------------------------------
commit_change "feat: four"
c4="$(head_sha)"
expect "4. tampering: a red run to start from" 1 "red: " -- env STUB_FAIL=harbor "$A"
promote "$c4"
note_of "$REAL" "$c4" | sed -n '/-----BEGIN/,$p' >"$tmp/sig4"
payload_of "$REAL" "$c4" >"$tmp/tampered.json"
json_edit "$tmp/tampered.json" 'p["failed"] = 0
for e in p["suites"]: e["result"] = "pass"
p["passed"] = len(p["suites"])'
{
  printf 'payload: %s\n' "$(base64 <"$tmp/tampered.json" | tr -d '\n')"
  cat "$tmp/sig4"
} >"$tmp/note"
g notes --ref="$REAL" add -f -F "$tmp/note" "$c4" 2>/dev/null
check "4. tampering: the payload now claims green" grep -qF '"failed":0' "$tmp/tampered.json"
expect "4. tampering: verifier refuses the signature" 1 "signature for ${c4:0:7} does not verify" -- "$V" HEAD

# --- 5. note of another commit copied onto HEAD --------------------------------------
commit_change "feat: five"
c5="$(head_sha)"
g notes --ref="$REAL" add -f -m "$(note_of "$REAL" "$c1")" "$c5"
expect "5. copied note: verifier refuses" 1 "is for ${c1:0:7}, not ${c5:0:7}" -- "$V" HEAD

# --- 6. signer, key or namespace not allowed ------------------------------------------
commit_change "feat: six"
c6="$(head_sha)"
expect "6. unknown signer: attest warns and still signs" 0 "not in .github/tests-allowed-signers" -- \
  env TESTS_SIGNER=intruder@example.com "$A"
promote "$c6"
expect "6. unknown signer: verifier refuses" 1 "does not verify for intruder@example.com" -- "$V" HEAD
expect "6. unlisted key: attest warns" 0 "not in .github/tests-allowed-signers" -- env TESTS_SIGNING_KEY="$tmp/other" "$A"
promote "$c6" "$tmp/other"
expect "6. unlisted key: verifier refuses" 1 "does not verify for maintainer@example.com" -- "$V" HEAD
payload_of "$REAL" "$c1" >"$tmp/p6.json"
json_edit "$tmp/p6.json" "p['commit'] = '$c6'; p['tree'] = '$(g rev-parse "$c6^{tree}")'"
sign_note "$c6" "$tmp/p6.json" "$tmp/key" other-namespace
expect "6. wrong namespace: verifier refuses" 1 "(namespace noixdev-infra-tests)" -- "$V" HEAD
sign_note "$c6" "$tmp/p6.json" "$tmp/key"
expect "6. control: the same payload in the right namespace passes" 0 "Tests attestation OK for ${c6:0:7}" -- "$V" HEAD

# --- 7. release = version bump on top of the attested commit -------------------------------
bump() { # bump [EXTRA-FILE]: CHANGELOG.md and galaxy.yml version on top of HEAD
  sed -i.bak 's/^version: .*/version: 0.2.0/' "$repo/galaxy.yml" && rm "$repo/galaxy.yml.bak"
  printf '\n## 0.2.0\n' >>"$repo/CHANGELOG.md"
  [ -z "${1:-}" ] || echo extra >>"$repo/$1"
  g add -A && g commit -q -m "chore: bump the collection to 0.2.0"
}
reset_version() { # back to 0.1.0, as a normal commit, then attest it green
  sed -i.bak 's/^version: .*/version: 0.1.0/' "$repo/galaxy.yml" && rm "$repo/galaxy.yml.bak"
  commit_change "feat: seven $1"
  if "$repo/$A" >"$tmp/out" 2>&1; then
    promote "$(head_sha)"
  else
    not_ok "7. attest the base commit ($1)"
  fi
}
reset_version a
c7="$(head_sha)"
bump
expect "7. bump only: verifier allows it with the parent's attestation" 0 "Tests attestation OK for ${c7:0:7}" -- "$V" HEAD
check "7. bump only: verifier says it checks the parent" grep -qF "version bump only" "$tmp/out"
reset_version b
bump README.md
expect "7. bump plus another file: verifier refuses naming it" 1 "beyond CHANGELOG.md and the version: line of galaxy.yml: README.md" -- "$V" HEAD
reset_version c
sed -i.bak 's/^description: .*/description: changed/' "$repo/galaxy.yml" && rm "$repo/galaxy.yml.bak"
bump
expect "7. galaxy.yml changed beyond version: verifier refuses" 1 "galaxy.yml changed beyond its version: line" -- "$V" HEAD
commit_change "feat: seven d"
bump
expect "7. bump on an unattested commit: verifier refuses" 1 "No tests attestation for" -- "$V" HEAD

# --- 8. new suite at the tested commit, absent from the payload -------------------------------
commit_change "feat: eight base"
c8a="$(head_sha)"
"$repo/$A" >/dev/null 2>&1
promote "$c8a"
sed -i.bak 's/^all_suites=(\(.*\))$/all_suites=(\1 newsuite)/' "$repo/tests/all.sh" && rm "$repo/tests/all.sh.bak"
stub "$repo/tests/newsuite/run.sh" newsuite
g add -A && g commit -q -m "test: add newsuite"
c8="$(head_sha)"
payload_of "$REAL" "$c8a" >"$tmp/p8.json"
json_edit "$tmp/p8.json" "p['commit'] = '$c8'; p['tree'] = '$(g rev-parse "$c8^{tree}")'"
sign_note "$c8" "$tmp/p8.json" "$tmp/key"
expect "8. new suite: an old-style green payload is refused" 1 "missing or not passed: newsuite" -- "$V" HEAD
expect "8. new suite: attest itself runs it" 0 "green: " -- "$A"
check "8. new suite: the payload has its entry" sh -c 'git notes --ref="$1" show HEAD | sed -n "s/^payload: //p" | base64 -d | grep -qF "\"label\":\"newsuite\""' _ "$DRY"
promote "$c8"
expect "8. new suite: verifier then allows" 0 "Tests attestation OK" -- "$V" HEAD

# --- 9. dirty tree ---------------------------------------------------------------------
rm -f "$tmp/runner-ran"
echo dirty >"$repo/untracked.txt"
expect "9. dirty tree: attest exits 2" 2 "working tree is not clean" -- env ATTEST_RUNNER="$tmp/runner" "$A"
check "9. dirty tree: the runner never ran" test ! -e "$tmp/runner-ran"
rm "$repo/untracked.txt"

# --- 10. HEAD changed during the run -----------------------------------------------------
commit_change "feat: ten"
c10="$(head_sha)"
expect "10. HEAD moved: attest exits 2" 2 "changed during the run. Nothing published." -- \
  env ATTEST_RUNNER="$tmp/runner" FAKE_SUMMARY="$all_pass" FAKE_COMMIT=1 "$A"
check "10. HEAD moved: no note on the tested commit" sh -c '! git notes --ref="$1" show "$2" >/dev/null 2>&1' _ "$DRY" "$c10"
check "10. HEAD moved: no note on the new HEAD" sh -c '! git notes --ref="$1" show HEAD >/dev/null 2>&1' _ "$DRY"

# --- 11. the test hooks only work in a dry run --------------------------------------------
rm -f "$tmp/runner-ran"
expect "11. ATTEST_RUNNER without ATTEST_DRY_RUN=1 is refused" 2 "needs ATTEST_DRY_RUN=1" -- \
  env -u ATTEST_DRY_RUN ATTEST_RUNNER="$tmp/runner" FAKE_SUMMARY="$all_pass" "$A"
expect "11. ATTEST_RUNNER with ATTEST_DRY_RUN=0 is refused" 2 "needs ATTEST_DRY_RUN=1" -- \
  env ATTEST_DRY_RUN=0 ATTEST_RUNNER="$tmp/runner" FAKE_SUMMARY="$all_pass" "$A"
check "11. the runner never ran" test ! -e "$tmp/runner-ran"
expect "11. ATTEST_DRY_RUN other than 1 is refused" 2 "ATTEST_DRY_RUN must be 1 or unset" -- env ATTEST_DRY_RUN=yes "$A"

# --- 12. coverage knobs ------------------------------------------------------------------
for knob in "${knobs[@]}"; do
  expect "12. $knob set refuses to start" 2 "unset $knob first" -- env "$knob=1" ATTEST_RUNNER="$tmp/runner" "$A"
done
expect "12. a knob set to empty refuses too" 2 "unset HOST_UBUNTU first" -- env HOST_UBUNTU= "$A"
check "12. the runner never ran" test ! -e "$tmp/runner-ran"

# --- 13. real mode against local bare repositories ------------------------------------------
# Fake docker and gh on PATH; origin's path contains github.com/<owner>/<repo>
# so attest.sh reads the repository from it.
mkdir -p "$tmp/bin" "$tmp/github.com/example"
printf '#!/usr/bin/env bash\necho 29.0.0-fake\n' >"$tmp/bin/docker"
printf '#!/usr/bin/env bash\ncase "$1" in auth) exit 0 ;; api) printf "%%s\\n" "$@" >"%s/gh-call"; exit 0 ;; esac\nexit 1\n' "$tmp" >"$tmp/bin/gh"
chmod +x "$tmp/bin/docker" "$tmp/bin/gh"
origin="$tmp/github.com/example/selftest.git"
git init -q --bare "$origin"
git init -q --bare "$tmp/fork.git"
g remote add origin "$origin"
g remote add fork "$tmp/fork.git"
real() { env -u ATTEST_DRY_RUN -u ATTEST_RUNNER PATH="$tmp/bin:$PATH" "$@"; }
g push -q origin main
commit_change "feat: thirteen fork only"
g push -q fork main
expect "13. real: a commit only on another remote is refused" 2 "not on a branch of origin" -- real "$A"
g push -q origin HEAD:refs/heads/gone
git -C "$origin" update-ref -d refs/heads/gone
expect "13. real: a stale origin/* branch is pruned, not trusted" 2 "not on a branch of origin" -- real "$A"
g push -q origin main
c13="$(head_sha)"
# A leftover note in the local ref that origin never had.
g notes --ref="$REAL" add -f -m "payload: stale" "$c1" 2>/dev/null
expect "13. real: a first run (no notes on origin yet) is green" 0 "pushed, status tests/local set" -- real "$A"
check "13. real: origin has the note of the run" git --git-dir="$origin" notes --ref="$REAL" show "$c13"
check "13. real: the stale local note was not pushed" sh -c '! git --git-dir="$1" notes --ref=refs/notes/tests show "$2" >/dev/null 2>&1' _ "$origin" "$c1"
entries=$((${#releases[@]} + ${#suites[@]})) # host per release, newsuite from case 8
check "13. real: the status call" sh -c 'a="$(tr "\n" " " <"$1")"; [ "$a" = "$2" ] || { echo "got: $a"; exit 1; }' _ "$tmp/gh-call" \
  "api --method POST repos/example/selftest/statuses/$c13 -f state=success -f context=tests/local -f description=$entries passed, 0 failed (0 min, $(uname -m), signed) "
commit_change "feat: thirteen b"
g push -q origin main
c13b="$(head_sha)"
g notes --ref="$REAL" add -f -m "payload: stale" "$c1" 2>/dev/null
expect "13. real: a run on top of origin's notes is red when a suite fails" 1 "red: " -- real env STUB_FAIL=listmonk "$A"
check "13. real: origin keeps the earlier note and has the new one" \
  sh -c 'git --git-dir="$1" notes --ref=refs/notes/tests show "$2" >/dev/null && git --git-dir="$1" notes --ref=refs/notes/tests show "$3" >/dev/null' _ "$origin" "$c13" "$c13b"
check "13. real: still no stale note on origin" sh -c '! git --git-dir="$1" notes --ref=refs/notes/tests show "$2" >/dev/null 2>&1' _ "$origin" "$c1"
check "13. real: the red status call" grep -qx "state=failure" "$tmp/gh-call"
g fetch -q origin "+$REAL:$REAL"
expect "13. real: verifier allows the real green note" 0 "Tests attestation OK for ${c13:0:7}" -- "$V" "$c13"
expect "13. real: verifier refuses the real red note" 1 "is red: " -- "$V" "$c13b"

# --- preconditions -----------------------------------------------------------------------
expect "precondition: no arguments" 2 "takes no arguments" -- tests/attest.sh e2e
expect "precondition: missing signing key" 2 "signing key $tmp/missing.pub not found" -- \
  env TESTS_SIGNING_KEY="$tmp/missing.pub" "$A"
expect "precondition: key:: literal is not supported" 2 "not supported" -- \
  env TESTS_SIGNING_KEY="key::$(cat "$tmp/key.pub")" "$A"
expect "precondition: no summary means nothing published" 2 "wrote no summary" -- \
  env ATTEST_RUNNER=/usr/bin/true "$A"

echo
if [ "$failures" = 0 ]; then
  echo "selftest: all $count checks passed"
else
  echo "selftest: $failures of $count checks failed"
  exit 1
fi
