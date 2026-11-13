#!/usr/bin/env bash
# Runs the Docker test suites one after the other on this machine. CI runs
# only ansible-lint and shellcheck; run this before you push.
#
#   tests/all.sh [--keep-going] [--summary FILE] [suite...]
#
# Without suites it runs all of them, in this order:
#   e2e         tests/run.sh (container roles, Docker-in-Docker)
#   host        tests/host/run.sh, once per Ubuntu release in HOST_UBUNTU
#               (default: host_releases below, "24.04 26.04")
#   harbor      tests/harbor/run.sh
#   listmonk    tests/listmonk/run.sh
#   anubis      tests/anubis/run.sh
#   mailcow     tests/mailcow/run.sh (real mailcow: network, about 5 GB of images)
#   cloudpanel  tests/cloudpanel/run.sh (CloudPanel's real installer)
#
# It stops at the first suite that fails, unless --keep-going is given, and
# ends with a summary: each suite's result and runtime. Each suite's output
# also goes to tests/output/all/<suite>.log. The exit code is 0 only when
# every suite that was asked for passed.
#
# --summary FILE writes a machine-readable summary after the run, one line
# per run entry (the host suite has one entry per Ubuntu release):
#   <label> <pass|fail|skipped> <seconds>
# "skipped" is an entry that did not run because an earlier one failed
# (seconds 0). tests/attest.sh reads it.
#
# harbor: Harbor before v2.16 publishes amd64 images only. The test host
# (Docker-in-Docker) runs natively; the suite's inventory runs the Harbor
# images inside it as linux/amd64, so on a machine that is not amd64 (an
# arm64 Mac, for example) they run under emulation (Docker Desktop's Rosetta
# or QEMU). Expect it to be slow there.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/output/all"
# The required suites and the host suite's default releases. tests/attest.sh
# and .github/scripts/verify-tests-attestation.sh read both lines (keep each
# on one line): an attestation needs every suite, host once per release.
all_suites=(e2e host harbor listmonk anubis mailcow cloudpanel)
host_releases=(24.04 26.04)

usage() {
  echo "usage: tests/all.sh [--keep-going] [--summary FILE] [suite...]; suites: ${all_suites[*]}" >&2
  exit 2
}

keep_going=0
summary=
suites=()
while [ "$#" -gt 0 ]; do
  arg="$1"
  shift
  case "$arg" in
    --keep-going) keep_going=1 ;;
    --summary)
      [ "$#" -gt 0 ] && [ -n "$1" ] || usage
      summary="$1"
      shift
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      case " ${all_suites[*]} " in
        *" $arg "*) suites+=("$arg") ;;
        *)
          echo "tests/all.sh: unknown suite: $arg" >&2
          usage
          ;;
      esac
      ;;
  esac
done
[ "${#suites[@]}" -gt 0 ] || suites=("${all_suites[@]}")

# One run per entry: "<label>|<script>|<VAR=value ...>".
runs=()
for suite in "${suites[@]}"; do
  case "$suite" in
    e2e) runs+=("e2e|$here/run.sh|") ;;
    host)
      for ubuntu in ${HOST_UBUNTU:-${host_releases[*]}}; do
        runs+=("host-$ubuntu|$here/host/run.sh|UBUNTU=$ubuntu")
      done
      ;;
    *) runs+=("$suite|$here/$suite/run.sh|") ;;
  esac
done

mkdir -p "$out"
results=()
failed=0
stopped=0
for run in "${runs[@]}"; do
  IFS='|' read -r label script vars <<<"$run"
  read -r -a vars <<<"$vars"
  if [ "$stopped" = 1 ]; then
    results+=("$label|not run|")
    continue
  fi
  echo "==== $label: ${vars[*]+${vars[*]} }$script"
  start="$(date +%s)"
  env ${vars[@]+"${vars[@]}"} "$script" 2>&1 | tee "$out/$label.log"
  rc="${PIPESTATUS[0]}"
  seconds=$(($(date +%s) - start))
  if [ "$rc" = 0 ]; then
    results+=("$label|passed|$seconds")
  else
    results+=("$label|failed (exit $rc)|$seconds")
    failed=1
    [ "$keep_going" = 1 ] || stopped=1
  fi
done

echo
echo "==== summary"
for result in "${results[@]}"; do
  IFS='|' read -r label status seconds <<<"$result"
  printf '%-12s %-16s %s\n' "$label" "$status" "${seconds:+$seconds s}"
done
[ "$stopped" = 0 ] || echo "stopped after the first failure (--keep-going runs the rest)"

if [ -n "$summary" ]; then
  for result in "${results[@]}"; do
    IFS='|' read -r label status seconds <<<"$result"
    case "$status" in
      passed) status=pass ;;
      "not run") status=skipped seconds=0 ;;
      *) status=fail ;;
    esac
    echo "$label $status $seconds"
  done >"$summary" || {
    echo "tests/all.sh: cannot write the summary to $summary" >&2
    exit 2
  }
fi
exit "$failed"
