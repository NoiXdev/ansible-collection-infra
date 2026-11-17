#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted $ is intended: stub scripts, sh -c
# Self-test of the attestation: tests/attest.sh, tests/all.sh --summary,
# .github/scripts/verify-tests-attestation.sh and their shared helper
# .github/scripts/attest_carry.py (its unit tests, check-map on this
# repository's HEAD, the run-or-carry plan). No Docker, no network: it works
# in a throwaway git repository with throwaway ed25519 keys, a copy of the
# scripts and stub suites behind the real tests/all.sh. Most cases use
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
cp "$src/.github/scripts/verify-tests-attestation.sh" "$src/.github/scripts/attest_carry.py" "$repo/.github/scripts/"
echo "maintainer@example.com namespaces=\"noixdev-infra-tests\" $(cat "$tmp/key.pub")" >"$repo/.github/tests-allowed-signers"
printf 'tests/output/\n' >"$repo/.gitignore"
printf 'namespace: noixdev\nname: infra\nversion: 0.1.0\ndescription: selftest\n' >"$repo/galaxy.yml"
printf '# Changelog\n\n## Unreleased\n' >"$repo/CHANGELOG.md"
read -r -a suites <<<"$(sed -nE 's/^all_suites=\(([^)]*)\)$/\1/p' "$repo/tests/all.sh")"
read -r -a releases <<<"$(sed -nE 's/^host_releases=\(([^)]*)\)$/\1/p' "$repo/tests/all.sh")"
read -r -a sreleases <<<"$(sed -nE 's/^services_releases=\(([^)]*)\)$/\1/p' "$repo/tests/all.sh")"
if [ "${#suites[@]}" -eq 0 ] || [ "${#releases[@]}" -lt 2 ] || [ "${#sreleases[@]}" -lt 2 ]; then
  echo "selftest: tests/all.sh needs all_suites=(...), host_releases=(...) and services_releases=(...) with two releases or more each" >&2
  exit 1
fi
last_suite="${suites[${#suites[@]} - 1]}"
last_host="host-${releases[${#releases[@]} - 1]}"
# A stub per suite: fails when its label is in STUB_FAIL.
stub() { # stub PATH LABEL-EXPRESSION
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\nlabel="%s"\ncase " ${STUB_FAIL:-} " in *" $label "*) echo "$label failed"; exit 1 ;; esac\n[ -z "${STUB_NOTE:-}" ] || echo "noix-attest-note: $STUB_NOTE"\necho "$label passed"\n' "$2" >"$1"
  chmod +x "$1"
}
for suite in "${suites[@]}"; do
  case "$suite" in
    e2e) stub "$repo/tests/run.sh" e2e ;;
    host) stub "$repo/tests/host/run.sh" 'host-$UBUNTU' ;;
    services) stub "$repo/tests/services/run.sh" 'services-$UBUNTU' ;;
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
  elif [ "$s" = services ]; then
    for r in "${sreleases[@]}"; do echo "services-$r pass 3"; done
  else
    echo "$s pass 2"
  fi
done)"

# Dry run with the real tests/all.sh of the repo (stub suites) by default.
export ATTEST_DRY_RUN=1 ATTEST_RUNNER="$repo/tests/all.sh"

# --- tests/all.sh --summary -------------------------------------------------
expect "all.sh: --summary without a file is rejected" 2 "usage:" -- tests/all.sh --summary
expect "all.sh: an unknown suite is rejected" 2 "unknown suite or entry: bogus" -- tests/all.sh --summary "$tmp/s" bogus
check "all.sh: rejected runs write no summary" test ! -e "$tmp/s"
expect "all.sh: all stub suites pass" 0 "summary" -- tests/all.sh --keep-going --summary "$tmp/s"
check "all.sh: one summary line per run entry, host once per host_releases entry" \
  test "$(cut -d' ' -f1,2 "$tmp/s")" = "$(printf '%s\n' "$all_pass" | cut -d' ' -f1,2)"
expect "all.sh: a failing suite without --keep-going stops the run" 1 "stopped after the first failure" -- \
  env STUB_FAIL=e2e tests/all.sh --summary "$tmp/s"
check "all.sh: the summary marks the failure and the skipped rest" \
  test "$(head -2 "$tmp/s" | cut -d' ' -f1,2)" = "$(printf 'e2e fail\nhost-%s skipped' "${releases[0]}")"
expect "all.sh: services expands to one entry per services release" 0 "summary" -- tests/all.sh --summary "$tmp/s" services
check "all.sh: the services entries pass" \
  test "$(cut -d' ' -f1,2 "$tmp/s")" = "$(printf 'services-%s pass\n' "${sreleases[@]}")"
expect "all.sh: entry labels run in all_suites order, whatever the argument order" 0 "summary" -- \
  tests/all.sh --summary "$tmp/s" "services-${sreleases[1]}" "host-${releases[0]}"
check "all.sh: host-<release> runs before services-<release>" \
  test "$(cut -d' ' -f1,2 "$tmp/s")" = "$(printf 'host-%s pass\nservices-%s pass' "${releases[0]}" "${sreleases[1]}")"
expect "all.sh: an entry of a release that is not listed is rejected" 2 "unknown suite or entry" -- tests/all.sh host-22.04
expect "all.sh: a note of a suite lands in the summary line" 0 "summary" -- \
  env STUB_NOTE="mysql via systemctl shim" tests/all.sh --summary "$tmp/s" "services-${sreleases[0]}"
check "all.sh: the note has its spaces replaced by underscores" \
  test "$(cut -d' ' -f1,2,4 "$tmp/s")" = "services-${sreleases[0]} pass mysql_via_systemctl_shim"

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
# version answers the Docker version, run the amd64 check (uname -m).
printf '#!/usr/bin/env bash\ncase "$1" in run) echo x86_64 ;; *) echo 29.0.0-fake ;; esac\n' >"$tmp/bin/docker"
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
mkdir -p "$tmp/bin-noamd64"
cp "$tmp/bin/gh" "$tmp/bin-noamd64/gh"
printf '#!/usr/bin/env bash\ncase "$1" in run) echo "exec /bin/uname: exec format error" ;; *) echo 29.0.0-fake ;; esac\n' >"$tmp/bin-noamd64/docker"
chmod +x "$tmp/bin-noamd64/docker"
expect "13. real: Docker without amd64 emulation refuses to start" 2 "cannot run linux/amd64 images" -- \
  env -u ATTEST_DRY_RUN -u ATTEST_RUNNER PATH="$tmp/bin-noamd64:$PATH" "$A"
expect "13. real: a first run (no notes on origin yet) is green" 0 "pushed, status tests/local set" -- real "$A"
check "13. real: origin has the note of the run" git --git-dir="$origin" notes --ref="$REAL" show "$c13"
check "13. real: the stale local note was not pushed" sh -c '! git --git-dir="$1" notes --ref=refs/notes/tests show "$2" >/dev/null 2>&1' _ "$origin" "$c1"
entries=$((${#releases[@]} + ${#sreleases[@]} + ${#suites[@]} - 1)) # host and services per release, newsuite from case 8
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

# --- 14. the shared helper (.github/scripts/attest_carry.py) -----------------------------------
H="$src/.github/scripts/attest_carry.py"
check "14. helper: the unit tests pass" python3 -I -m unittest discover -s "$src/tests/attest" -p test_attest_carry.py
expect "14. helper: check-map passes on this repository's HEAD" 0 "tests/suites.conf OK at" -- \
  python3 -I "$H" check-map --repo "$src" --commit HEAD

# plan in a repository of its own: one roles/<suite>/ per suite in its map,
# dry-run notes in its refs/notes/tests, signed with the selftest's keys.
selftest_repo="$repo"
repo="$tmp/plan"
NOW=1800000000
echo "maintainer@example.com namespaces=\"noixdev-infra-tests\" $(cat "$tmp/key.pub")" >"$tmp/plan-signers"
mkdir -p "$repo/tests"
git init -q -b main "$repo"
cp "$src/tests/all.sh" "$repo/tests/"
{
  printf '[ignore]\nCHANGELOG.md\n[shared]\ntests/all.sh\ntests/suites.conf\nshared/\n'
  for s in "${suites[@]}"; do printf '[suite %s]\nroles/%s/\n' "$s" "$s"; done
} >"$repo/tests/suites.conf"
for s in "${suites[@]}"; do
  mkdir -p "$repo/roles/$s"
  echo "$s" >"$repo/roles/$s/main.yml"
done
printf '# Changelog\n' >"$repo/CHANGELOG.md"
g add -A && g commit -q -m "chore: plan repo"
b0="$(head_sha)"
change() { # change FILE: a commit that changes FILE
  mkdir -p "$repo/$(dirname "$1")"
  echo change >>"$repo/$1"
  g add -A && g commit -q -m "change $1"
}
iso_ago() { # iso_ago DAYS: the UTC time DAYS before $NOW
  python3 -I -c 'import sys, time
print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]) - int(float(sys.argv[2]) * 86400))))' "$NOW" "$1"
}
# plan_note COMMIT DAYS-AGO [FAILING-LABEL] [KEY]: a dry-run note of a full
# run of COMMIT (plan --all, build-payload), finished DAYS-AGO before $NOW.
plan_note() {
  local finished
  finished="$(iso_ago "$2")"
  python3 -I "$H" plan --repo "$repo" --head "$1" --notes-ref "$REAL" --signers "$tmp/plan-signers" \
    --now "$NOW" --all >"$tmp/note-plan.json"
  printf '%s\n' "$all_pass" | sed "s/^${3:-none} pass /${3:-none} fail /" >"$tmp/note-summary"
  python3 -I "$H" build-payload --plan "$tmp/note-plan.json" --summary "$tmp/note-summary" \
    --out "$tmp/note-payload.json" --commit "$1" --tree "$(g rev-parse "$1^{tree}")" \
    --signer maintainer@example.com --arch x86_64 --os Linux --docker unknown \
    --started "$finished" --finished "$finished" --dry-run >/dev/null
  sign_note "$1" "$tmp/note-payload.json" "${4:-$tmp/key}"
}
# plan_case DESCRIPTION [ARGS...]: the plan of HEAD (dry-run notes allowed)
# into $tmp/plan.json.
plan_case() {
  local desc="$1"
  shift
  expect "$desc" 0 '"action"' -- python3 -I "$H" plan --repo "$repo" --head HEAD --notes-ref "$REAL" \
    --signers "$tmp/plan-signers" --now "$NOW" --allow-dry-run "$@"
  cp "$tmp/out" "$tmp/plan.json"
}
# plan_is LABEL ACTION REASON [CARRIED-FROM]: the entry LABEL of the plan, or
# every entry for LABEL "*", has ACTION, a reason with REASON and that source.
plan_is() {
  python3 -I -c 'import json, sys
path, label, action, reason, source = sys.argv[1:]
entries = [e for e in json.load(open(path)) if label in ("*", e["label"])]
bad = [e for e in entries if (e["action"], reason in e["reason"], e.get("carriedFrom", "")) != (action, True, source)]
print("\n".join(json.dumps(e) for e in bad))
sys.exit(1 if bad or not entries else 0)' "$tmp/plan.json" "$1" "$2" "$3" "${4:-}"
}
plan_count() { # plan_count ACTION N: N entries of the plan have ACTION
  test "$(grep -c "\"action\": \"$1\"" "$tmp/plan.json")" = "$2"
}
entry_count="$(printf '%s\n' "$all_pass" | wc -l | tr -d ' ')"

change CHANGELOG.md
p0="$(head_sha)"
plan_note "$p0" 1

g checkout -q -b role "$p0"
change roles/harbor/main.yml
plan_case "14. plan: a change in one suite's role"
check "14. plan: that entry runs, naming the file" plan_is harbor run "roles/harbor/main.yml changed since ${p0:0:7}"
check "14. plan: the others are carried from the previous note" plan_is e2e carry "no file of e2e changed" "$p0"
check "14. plan: only that entry runs" plan_count run 1
plan_case "14. plan: --all" --all
check "14. plan: --all runs every entry" plan_is "*" run "--all"

g checkout -q -b shared "$p0"
change shared/x
plan_case "14. plan: a shared path"
check "14. plan: a shared path runs every entry" plan_is "*" run "shared/x changed since ${p0:0:7} (a shared path)"

g checkout -q -b unmatched "$p0"
change foo/bar
plan_case "14. plan: an unmatched path"
check "14. plan: an unmatched path runs every entry" plan_is "*" run "foo/bar changed since ${p0:0:7} (in no section"

g checkout -q -b docs "$p0"
change CHANGELOG.md
plan_case "14. plan: CHANGELOG.md only"
check "14. plan: an ignored path carries every entry" plan_is "*" carry "" "$p0"
check "14. plan: every entry is carried" plan_count carry "$entry_count"

g checkout -q -b old29 "$p0"
change CHANGELOG.md
a29="$(head_sha)"
plan_note "$a29" 29
change CHANGELOG.md
plan_case "14. plan: a source finished 29 days ago"
check "14. plan: a source past the 28-day margin runs" plan_is "*" run "the run at ${a29:0:7} is 29 days old"

g checkout -q -b old27 "$p0"
change CHANGELOG.md
a27="$(head_sha)"
plan_note "$a27" 27
change CHANGELOG.md
plan_case "14. plan: a source finished 27 days ago"
check "14. plan: a source within the margin is carried" plan_is "*" carry "" "$a27"

g checkout -q -b red "$p0"
change CHANGELOG.md
r1="$(head_sha)"
plan_note "$r1" 0.5 harbor
change CHANGELOG.md
plan_case "14. plan: a newer red run after an older green one"
check "14. plan: the red entry runs, the older green run is not carried" plan_is harbor run "red at ${r1:0:7} (fail)"
check "14. plan: the green entries are carried from the newer run" plan_is e2e carry "" "$r1"

g checkout -q -b other "$b0"
change CHANGELOG.md
plan_case "14. plan: a source only on another branch"
check "14. plan: a source that is not an ancestor is not used" plan_is "*" run "no signed run of"

g checkout -q -b badsig "$p0"
change CHANGELOG.md
x1="$(head_sha)"
plan_note "$x1" 0.5 "" "$tmp/other"
change CHANGELOG.md
plan_case "14. plan: a newer note with a bad signature"
check "14. plan: the bad note is skipped, the older valid one is used" plan_is "*" carry "" "$p0"

g checkout -q -b self "$p0"
change CHANGELOG.md
plan_note "$(head_sha)" 0.5
plan_case "14. plan: a note on HEAD itself"
check "14. plan: HEAD's own note is no source (the new note replaces it)" plan_is "*" carry "" "$p0"

g checkout -q -b headred "$p0"
change CHANGELOG.md
h1="$(head_sha)"
plan_note "$h1" 0.5 harbor
plan_case "14. plan: a red run in HEAD's own note (tests/attest.sh --all left it red)"
check "14. plan: the entry red at HEAD runs, not carried from an older green run" plan_is harbor run "red at ${h1:0:7} (fail)"
check "14. plan: the entries green at HEAD are carried from the older run, not from HEAD" plan_is e2e carry "" "$p0"

g checkout -q -b future "$p0"
change CHANGELOG.md
f1="$(head_sha)"
plan_note "$f1" -2
change CHANGELOG.md
plan_case "14. plan: a source finished 2 days in the future"
check "14. plan: a source in the future runs, not read as 0 days old" plan_is "*" run "the run at ${f1:0:7} cannot be carried"
check "14. plan: the reason says it is in the future" grep -qF "in the future" "$tmp/plan.json"

g checkout -q -b left "$p0"
change CHANGELOG.md
l1="$(head_sha)"
plan_note "$l1" 0.5
g checkout -q -b right "$p0"
g commit -q --allow-empty -m "chore: right"
plan_note "$(head_sha)" 0.5
g merge -q --no-edit left
plan_case "14. plan: runs of the entry on two merged branches"
check "14. plan: runs on parallel branches are not carried" plan_is "*" run "on parallel branches"

g checkout -q -b realonly "$p0"
change CHANGELOG.md
expect "14. plan: without --allow-dry-run" 0 '"action"' -- python3 -I "$H" plan --repo "$repo" --head HEAD \
  --notes-ref "$REAL" --signers "$tmp/plan-signers" --now "$NOW"
cp "$tmp/out" "$tmp/plan.json"
check "14. plan: dry-run notes are no source of a real run" plan_is "*" run "no signed run of"

mkdir -p "$repo/roles/zzz"
echo zzz >"$repo/roles/zzz/main.yml"
g add -A && g commit -q -m "feat: an unmapped role"
expect "14. check-map: a role in no suite fails" 1 "::error::roles/zzz/ is in no [suite] section" -- \
  python3 -I "$H" check-map --repo "$repo" --commit HEAD
repo="$selftest_repo"
unset selftest_repo b0 p0 a29 a27 r1 x1 h1 f1 l1 entry_count

# --- 15. the release check with carried entries ----------------------------------------------
# A repository of its own like the plan's, with real (not dry-run) notes made
# by plan and build-payload and signed with the selftest's keys. The release
# check runs as on a tag: at the current time, from the source tree.
VS="$src/.github/scripts/verify-tests-attestation.sh"
selftest_repo="$repo"
repo="$tmp/gate"
NOW="$(date +%s)"
mkdir -p "$repo/tests" "$repo/.github"
git init -q -b main "$repo"
cp "$src/tests/all.sh" "$repo/tests/"
cp "$tmp/plan-signers" "$repo/.github/tests-allowed-signers"
{
  printf '[ignore]\nCHANGELOG.md\n[shared]\ntests/all.sh\ntests/suites.conf\nshared/\n'
  for s in "${suites[@]}"; do printf '[suite %s]\nroles/%s/\n' "$s" "$s"; done
} >"$repo/tests/suites.conf"
for s in "${suites[@]}"; do
  mkdir -p "$repo/roles/$s"
  echo "$s" >"$repo/roles/$s/main.yml"
done
printf '# Changelog\n' >"$repo/CHANGELOG.md"
g add -A && g commit -q -m "chore: gate repo"
gb0="$(head_sha)"
: >"$tmp/gate-empty"
printf 'harbor pass 2\n' >"$tmp/gate-harbor"
# gate_note COMMIT DAYS-AGO PLAN SUMMARY [KEY] [--dry-run]: the payload that
# build-payload makes of PLAN and SUMMARY for COMMIT, finished DAYS-AGO
# before $NOW, signed by KEY as COMMIT's note in refs/notes/tests.
gate_note() {
  local finished docker=29.0.0-selftest
  finished="$(iso_ago "$2")"
  [ -z "${6:-}" ] || docker=unknown
  python3 -I "$H" build-payload --plan "$3" --summary "$4" --out "$tmp/gate-payload.json" \
    --commit "$1" --tree "$(g rev-parse "$1^{tree}")" --signer maintainer@example.com --arch x86_64 \
    --os Linux --docker "$docker" --started "$finished" --finished "$finished" ${6:+"$6"} >/dev/null
  sign_note "$1" "$tmp/gate-payload.json" "${5:-$tmp/key}"
}
gate_all() { # gate_all COMMIT: the plan --all of COMMIT into $tmp/gate-all.json
  python3 -I "$H" plan --repo "$repo" --head "$1" --notes-ref "$REAL" --signers "$tmp/plan-signers" \
    --now "$NOW" --all >"$tmp/gate-all.json"
}
# gate_full COMMIT DAYS-AGO [FAILING-LABEL] [KEY] [--dry-run]: the note of a
# full run of COMMIT; services-<first release> records the mysql shim note.
gate_full() {
  gate_all "$1"
  printf '%s\n' "$all_pass" | sed -e "s/^${3:-none} pass /${3:-none} fail /" \
    -e "s/^services-${sreleases[0]} pass [0-9]*\$/& mysql_via_systemctl_shim/" >"$tmp/gate-summary"
  gate_note "$1" "$2" "$tmp/gate-all.json" "$tmp/gate-summary" "${4:-$tmp/key}" "${5:-}"
}
# gate_carry COMMIT FROM [PYTHON] [SUMMARY]: the note of COMMIT that carries
# every entry from FROM; PYTHON may edit that plan p first, SUMMARY is what ran.
gate_carry() {
  gate_all "$1"
  json_edit "$tmp/gate-all.json" "for e in p: e.update(action='carry', carriedFrom='$2')
${3:-}"
  gate_note "$1" 0.1 "$tmp/gate-all.json" "${4:-$tmp/gate-empty}"
}
# gate_plan: the plan of HEAD from the real notes into $tmp/plan.json.
gate_plan() {
  python3 -I "$H" plan --repo "$repo" --head HEAD --notes-ref "$REAL" --signers "$tmp/plan-signers" \
    --now "$NOW" >"$tmp/plan.json"
}
entry_count="$(printf '%s\n' "$all_pass" | wc -l | tr -d ' ')"

change CHANGELOG.md
g1="$(head_sha)"
gate_full "$g1" 1
expect "15. gate: a full schema 2 run passes" 0 "Tests attestation OK for ${g1:0:7}" -- "$VS" "$g1"

g checkout -q -b g-role "$g1"
change roles/harbor/main.yml
t1="$(head_sha)"
gate_plan
check "15. gate: after a change in harbor's role the plan runs only harbor" plan_count run 1
gate_note "$t1" 0.1 "$tmp/plan.json" "$tmp/gate-harbor"
expect "15. gate: a schema 2 note that carries from an older schema 2 note passes" 0 \
  "Tests attestation OK for ${t1:0:7}" -- "$VS" "$t1"
check "15. gate: the OK line counts what ran and what is carried" \
  grep -qF "1 ran, 1 passed, 0 failed, $((entry_count - 1)) carried" "$tmp/out"
check "15. gate: the OK line has the note of a carried entry" \
  grep -qF "services-${sreleases[0]}: mysql via systemctl shim" "$tmp/out"

g checkout -q -b g-chain "$t1"
change CHANGELOG.md
t="$(head_sha)"
gate_plan
check "15. gate: the plan carries harbor from its newer run" plan_is harbor carry "" "$t1"
gate_note "$t" 0.1 "$tmp/plan.json" "$tmp/gate-empty"
expect "15. gate: a note that carries from two older notes, nothing ran, passes" 0 \
  "Tests attestation OK for ${t:0:7}" -- "$VS" "$t"
json_edit "$tmp/plan.json" "for e in p:
    if e['label'] == 'e2e': e['carriedFrom'] = '$t1'"
gate_note "$t" 0.1 "$tmp/plan.json" "$tmp/gate-empty"
expect "15. gate: an entry that was itself carried at its source is refused" 1 \
  "e2e was carried at ${t1:0:7}" -- "$VS" "$t"
check "15. gate: the message names the source and the fix" \
  grep -qF "e2e is carried from ${t1:0:7}, but" "$tmp/out"
check "15. gate: the message says to run tests/attest.sh" grep -qF "run tests/attest.sh" "$tmp/out"

g checkout -q -b g-schema1 "$g1"
change CHANGELOG.md
s1="$(head_sha)"
gate_full "$s1" 1
payload_of "$REAL" "$s1" >"$tmp/gate-s1.json"
json_edit "$tmp/gate-s1.json" 'p["schema"] = 1; del p["carried"], p["carriedCount"]'
sign_note "$s1" "$tmp/gate-s1.json" "$tmp/key"
expect "15. gate: a schema 1 tested note passes, as today" 0 "Tests attestation OK for ${s1:0:7}" -- "$VS" "$s1"
change roles/harbor/main.yml
t="$(head_sha)"
gate_plan
check "15. gate: the plan carries from the schema 1 note" plan_is e2e carry "" "$s1"
gate_note "$t" 0.1 "$tmp/plan.json" "$tmp/gate-harbor"
expect "15. gate: a schema 2 note that carries from a schema 1 note passes" 0 \
  "Tests attestation OK for ${t:0:7}" -- "$VS" "$t"

g checkout -q -b g-changed "$g1"
change roles/harbor/main.yml
t="$(head_sha)"
gate_carry "$t" "$g1"
expect "15. gate: a carried entry whose suite file changed is refused" 1 \
  "harbor is carried from ${g1:0:7}, but roles/harbor/main.yml changed" -- "$VS" "$t"
check "15. gate: the entries of unchanged suites are not named" sh -c '! grep -qF "e2e is carried" "$1"' _ "$tmp/out"

g checkout -q -b g-shared "$g1"
change shared/x
t="$(head_sha)"
gate_carry "$t" "$g1"
expect "15. gate: a carry past a change of a shared path is refused" 1 \
  "e2e is carried from ${g1:0:7}, but shared/x changed since then (a shared path)" -- "$VS" "$t"

g checkout -q -b g-old "$g1"
change CHANGELOG.md
o="$(head_sha)"
gate_full "$o" 31
change CHANGELOG.md
t="$(head_sha)"
gate_carry "$t" "$o"
expect "15. gate: a source older than 30 days is refused" 1 "days old" -- "$VS" "$t"
check "15. gate: the age message names the entry and the source" \
  grep -qF "e2e is carried from ${o:0:7}, whose run finished $(iso_ago 31)" "$tmp/out"

g checkout -q -b g-side "$gb0"
change CHANGELOG.md
x="$(head_sha)"
gate_full "$x" 1
g checkout -q -b g-notancestor "$g1"
change CHANGELOG.md
t="$(head_sha)"
gate_carry "$t" "$g1" "p[0]['carriedFrom'] = '$x'"
expect "15. gate: a source that is not an ancestor is refused" 1 \
  "${suites[0]} is carried from ${x:0:7}, which is not an ancestor of ${t:0:7}" -- "$VS" "$t"

g checkout -q -b g-badkey "$g1"
change CHANGELOG.md
k="$(head_sha)"
gate_full "$k" 0.5 harbor "$tmp/other"
change CHANGELOG.md
t="$(head_sha)"
gate_carry "$t" "$k"
expect "15. gate: a source signed by an unlisted key is refused" 1 "does not verify" -- "$VS" "$t"
check "15. gate: the signature message names the entry and the source" \
  grep -qF "e2e is carried from ${k:0:7}, whose tests attestation" "$tmp/out"
gate_carry "$t" "$g1"
expect "15. gate: a newer red note that does not verify neither blocks nor counts" 0 \
  "Tests attestation OK for ${t:0:7}" -- "$VS" "$t"

g checkout -q -b g-red "$g1"
change CHANGELOG.md
r="$(head_sha)"
gate_full "$r" 0.5 harbor
change CHANGELOG.md
t="$(head_sha)"
gate_carry "$t" "$r"
expect "15. gate: an entry that failed at its source is refused" 1 "harbor failed at ${r:0:7}" -- "$VS" "$t"
gate_carry "$t" "$g1"
expect "15. gate: a carry past a newer red run is refused" 1 \
  "harbor is carried from ${g1:0:7}, but harbor ran again at ${r:0:7} (fail)" -- "$VS" "$t"

g checkout -q -b g-stale "$g1"
change CHANGELOG.md
t="$(head_sha)"
gate_full "$t" 31
expect "15. gate: a tested note whose own run is 31 days old is refused" 1 "days old" -- "$VS" "$t"
check "15. gate: the message names the tested commit" \
  grep -qF "The tests attestation for ${t:0:7} finished at $(iso_ago 31)" "$tmp/out"

g checkout -q -b g-forged "$g1"
change CHANGELOG.md
t="$(head_sha)"
gate_carry "$t" "$gb0"
expect "15. gate: carriedFrom a commit without a note is refused" 1 \
  "e2e is carried from ${gb0:0:7}, which has no tests attestation" -- "$VS" "$t"
gate_carry "$t" "$g1" "p[0]['carriedFrom'] = '0123456789abcdef0123456789abcdef01234567'"
expect "15. gate: carriedFrom an unknown commit is refused" 1 \
  "carriedFrom 0123456789abcdef0123456789abcdef01234567 of ${suites[0]} is not a commit in this repository" -- "$VS" "$t"
gate_carry "$t" "$g1" "p[:] = [e for e in p if e['label'] != 'harbor']"
expect "15. gate: an entry neither run nor carried is refused" 1 "missing or not passed: harbor" -- "$VS" "$t"
gate_carry "$t" "$g1" "p.append({'label': 'harbor', 'action': 'run'})" "$tmp/gate-harbor"
expect "15. gate: an entry both run and carried is refused" 1 "lists harbor more than once" -- "$VS" "$t"

g checkout -q -b g-dry "$g1"
change CHANGELOG.md
d="$(head_sha)"
gate_full "$d" 0.5 "" "$tmp/key" --dry-run
change CHANGELOG.md
t="$(head_sha)"
gate_carry "$t" "$d"
expect "15. gate: a dry-run source is refused" 1 "dry run" -- "$VS" "$t"
check "15. gate: the dry-run message names the entry and the source" \
  grep -qF "e2e is carried from ${d:0:7}, whose tests attestation" "$tmp/out"

g checkout -q -b g-future "$g1"
change CHANGELOG.md
f="$(head_sha)"
gate_full "$f" -2
change CHANGELOG.md
t="$(head_sha)"
gate_carry "$t" "$f"
expect "15. gate: a source finished 2 days in the future is refused" 1 "in the future" -- "$VS" "$t"
repo="$selftest_repo"
unset selftest_repo gb0 g1 t1 t s1 o x k r d f entry_count

# --- suite helpers (tests/lib/suite.sh) ---------------------------------------------------------
# A suite that stops on an unbound variable must not exit 0: bash 3.2 (macOS)
# runs the EXIT trap with $?=0 there, so only a finished flag catches it.
mkdir -p "$tmp/suite"
cat >"$tmp/suite/stub.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
. "$src/tests/lib/suite.sh"
cleanup() { touch "$tmp/suite/cleaned"; }
noix_exit_guard
boom() { echo "\$not_set_anywhere"; }
if [ "\${1:-}" = ok ]; then noix_done; echo stub-ok; exit 0; fi
boom
noix_done
STUB
bashes=(bash)
# bash 4+ exits 1 on an unbound variable by itself, so the guard's message
# only appears under bash 3; there only the exit status and cleanup count.
bash_major() { "$1" -c 'echo ${BASH_VERSINFO[0]}'; }
if [ -x /bin/bash ] && [ "$(bash_major /bin/bash)" = 3 ]; then
  bashes+=(/bin/bash)
else
  echo "# skipped: /bin/bash is not bash 3, the 3.2 variants do not run"
fi
for b in "${bashes[@]}"; do
  rm -f "$tmp/suite/cleaned"
  if [ "$(bash_major "$b")" = 3 ]; then
    expect "suite helpers: unbound variable exits non-zero under $b" 1 "stopped before the end" -- \
      "$b" "$tmp/suite/stub.sh"
  else
    expect "suite helpers: unbound variable exits non-zero under $b" 1 "unbound variable" -- "$b" "$tmp/suite/stub.sh"
  fi
  check "suite helpers: cleanup ran on the error exit under $b" test -e "$tmp/suite/cleaned"
  rm -f "$tmp/suite/cleaned"
  expect "suite helpers: noix_done keeps exit 0 under $b" 0 "stub-ok" -- "$b" "$tmp/suite/stub.sh" ok
  check "suite helpers: cleanup ran on the ok exit under $b" test -e "$tmp/suite/cleaned"
done
unset b bashes

suite_scripts=("$src"/tests/run.sh "$src"/tests/*/run.sh)
for s in "${suite_scripts[@]}"; do
  n="${s#"$src"/}"
  check "suite helpers: $n sources lib/suite.sh" grep -q 'lib/suite\.sh' "$s"
  check "suite helpers: $n calls noix_exit_guard" grep -q '^noix_exit_guard$' "$s"
  check "suite helpers: $n calls noix_done" grep -q 'noix_done' "$s"
  check "suite helpers: $n has no trap cleanup EXIT" sh -c '! grep -q "trap cleanup EXIT" "$1"' _ "$s"
  check "suite helpers: $n has no ln -sfn of the collection" sh -c '! grep -qF "ln -sfn \"\$root\"" "$1"' _ "$s"
done
unset s n suite_scripts

link_root="$tmp/suite/root"
mkdir -p "$link_root"
cat >"$tmp/suite/link.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
. "$src/tests/lib/suite.sh"
for _ in \$(seq 20); do noix_link_collection "$link_root" "\$1"; done
STUB
mkdir -p "$tmp/suite/out1"
bash "$tmp/suite/link.sh" "$tmp/suite/out1" &
p1=$!
bash "$tmp/suite/link.sh" "$tmp/suite/out1" &
p2=$!
rc1=0
rc2=0
wait "$p1" || rc1=$?
wait "$p2" || rc2=$?
check "suite helpers: 20 parallel link calls all succeed" test "$rc1$rc2" = 00
check "suite helpers: the link resolves to the root" \
  test "$(readlink "$tmp/suite/out1/ansible_collections/noixdev/infra")" = "$link_root"
mkdir -p "$tmp/suite/out2/ansible_collections/noixdev"
ln -s /nonexistent "$tmp/suite/out2/ansible_collections/noixdev/infra"
check "suite helpers: a wrong link is replaced" bash "$tmp/suite/link.sh" "$tmp/suite/out2"
check "suite helpers: the replaced link resolves to the root" \
  test "$(readlink "$tmp/suite/out2/ansible_collections/noixdev/infra")" = "$link_root"
unset p1 p2 rc1 rc2 link_root

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
