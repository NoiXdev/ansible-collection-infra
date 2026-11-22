#!/usr/bin/env bash
# Runs the Docker test suites one after the other on this machine. CI runs
# only ansible-lint and shellcheck; run this before you push.
#
#   tests/all.sh [--keep-going] [--summary FILE] [suite|entry...]
#
# Without suites it runs all of them, in this order:
#   e2e         tests/run.sh (container roles, Docker-in-Docker)
#   host        tests/host/run.sh, once per Ubuntu release in HOST_UBUNTU
#               (default: host_releases below, "24.04 26.04")
#   services    tests/services/run.sh (nodejs, redis, mariadb, mysql), once per
#               Ubuntu release in SERVICES_UBUNTU (default: services_releases
#               below, "24.04 26.04")
#   harbor      tests/harbor/run.sh
#   listmonk    tests/listmonk/run.sh
#   paperless   tests/paperless/run.sh (Paperless-ngx, Traefik and Samba; about 4 GB of images)
#   tandoor     tests/tandoor/run.sh (Tandoor Recipes, Traefik and Mailpit; about 2 GB of images)
#   n8n         tests/n8n/run.sh (n8n, PostgreSQL and Traefik; about 3 GB of images)
#   anubis      tests/anubis/run.sh
#   mailcow     tests/mailcow/run.sh (real mailcow: network, about 5 GB of images)
#   cloudpanel  tests/cloudpanel/run.sh (CloudPanel's real installer)
#   backrest    tests/backrest/run.sh (Backrest, MinIO and PostgreSQL), once per
#               Ubuntu release in BACKREST_UBUNTU (default "24.04 26.04")
#   vaultwarden tests/vaultwarden/run.sh (Vaultwarden, Traefik and PostgreSQL), once
#               per Ubuntu release in VAULTWARDEN_UBUNTU (default "24.04 26.04")
#   waf         tests/waf/run.sh (the WAF with Traefik and nginx), once per
#               Ubuntu release in WAF_UBUNTU (default "24.04 26.04")
#   varnish     tests/varnish/run.sh (the varnish role), once per Ubuntu
#               release in VARNISH_UBUNTU (default "24.04 26.04")
#   graylog     tests/graylog/run.sh (Graylog with Traefik), once per Ubuntu
#               release in GRAYLOG_UBUNTU (default "24.04 26.04")
#
# It stops at the first suite that fails, unless --keep-going is given, and
# ends with a summary: each entry's result and runtime. Each suite's output
# also goes to tests/output/all/<suite>.log. The exit code is 0 only when
# every suite that was asked for passed.
#
# An argument is a suite name or an entry label of a release in the matching
# array (host-24.04, services-26.04). The entries always run in the order of
# all_suites and then of the releases, whatever the order of the arguments.
#
# --summary FILE writes a machine-readable summary after the run, one line
# per run entry (the host and services suites have one entry per Ubuntu
# release):
#   <label> <pass|fail|skipped> <seconds>[ <note>...]
# "skipped" is an entry that did not run because an earlier one failed
# (seconds 0). tests/attest.sh reads it.
#
# A note is a line "noix-attest-note: <text>" that a suite prints (text:
# lowercase letters, digits, spaces, "." and "-"). The summary line carries
# each note of the entry's log with its spaces replaced by "_".
#
# harbor: Harbor before v2.16 publishes amd64 images only. The test host
# (Docker-in-Docker) runs natively; the suite's inventory runs the Harbor
# images inside it as linux/amd64, so on a machine that is not amd64 (an
# arm64 Mac, for example) they run under emulation (Docker Desktop's Rosetta
# or QEMU). Expect it to be slow there. The suite checks first that the test
# host runs linux/amd64 images and says how to turn the emulation on.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/output/all"
# The required suites and the default releases of the host and services
# suites. tests/attest.sh and .github/scripts/verify-tests-attestation.sh read
# these lines (keep each on one line): an attestation needs every suite, host
# and services once per release.
all_suites=(e2e host services harbor listmonk paperless tandoor n8n anubis mailcow cloudpanel pulsix_agent backrest vaultwarden waf varnish graylog)
host_releases=(24.04 26.04)
services_releases=(24.04 26.04)

usage() {
  echo "usage: tests/all.sh [--keep-going] [--summary FILE] [suite|entry...]; suites: ${all_suites[*]}; entries: host-<release>, services-<release>" >&2
  exit 2
}

# valid_arg ARG: a suite name, or an entry label of a release of the matching array.
valid_arg() {
  local arg="$1" r
  case " ${all_suites[*]} " in *" $arg "*) return 0 ;; esac
  for r in "${host_releases[@]}"; do [ "$arg" != "host-$r" ] || return 0; done
  for r in "${services_releases[@]}"; do [ "$arg" != "services-$r" ] || return 0; done
  return 1
}

keep_going=0
summary=
wanted=" "
while [ "$#" -gt 0 ]; do
  arg="$1"
  shift
  case "$arg" in
    --keep-going) keep_going=1 ;;
    --summary)
      if [ "$#" -eq 0 ] || [ -z "$1" ]; then usage; fi
      summary="$1"
      shift
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      if ! valid_arg "$arg"; then
        echo "tests/all.sh: unknown suite or entry: $arg" >&2
        usage
      fi
      wanted="$wanted$arg "
      ;;
  esac
done

# One run per entry: "<label>|<script>|<VAR=value ...>", in the order of
# all_suites and then of the releases.
# add_runs SUITE SCRIPT VAR EFFECTIVE DEFAULTS: the entries of a suite that has
# one run per release; the suite's argument selects the EFFECTIVE releases, an
# entry label selects its release from the effective and the default ones.
add_runs() {
  local suite="$1" script="$2" var="$3" effective="$4" defaults="$5" r label seen=" "
  for r in $effective $defaults; do
    label="$suite-$r"
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "
    case "$wanted" in
      " ") ;;
      *" $label "*) runs+=("$label|$script|$var=$r"); continue ;;
      *" $suite "*) ;;
      *) continue ;;
    esac
    case " $effective " in *" $r "*) runs+=("$label|$script|$var=$r") ;; esac
  done
}
runs=()
for suite in "${all_suites[@]}"; do
  case "$suite" in
    host) add_runs host "$here/host/run.sh" UBUNTU "${HOST_UBUNTU:-${host_releases[*]}}" "${host_releases[*]}" ;;
    services) add_runs services "$here/services/run.sh" UBUNTU "${SERVICES_UBUNTU:-${services_releases[*]}}" "${services_releases[*]}" ;;
    *)
      case "$wanted" in
        " " | *" $suite "*)
          if [ "$suite" = e2e ]; then runs+=("e2e|$here/run.sh|"); else runs+=("$suite|$here/$suite/run.sh|"); fi
          ;;
      esac
      ;;
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
    results+=("$label|not run||")
    continue
  fi
  echo "==== $label: ${vars[*]+${vars[*]} }$script"
  start="$(date +%s)"
  env ${vars[@]+"${vars[@]}"} "$script" 2>&1 | tee "$out/$label.log"
  rc="${PIPESTATUS[0]}"
  seconds=$(($(date +%s) - start))
  # The notes of the log: each with its spaces replaced by "_", space-joined.
  notes=
  while IFS= read -r note; do
    [ -z "$note" ] || notes="$notes${notes:+ }$(printf '%s' "${note// /_}")"
  done < <(sed -nE 's/^noix-attest-note: ([a-z0-9. -]+)$/\1/p' "$out/$label.log")
  if [ "$rc" = 0 ]; then
    results+=("$label|passed|$seconds|$notes")
  else
    results+=("$label|failed (exit $rc)|$seconds|$notes")
    failed=1
    [ "$keep_going" = 1 ] || stopped=1
  fi
done

echo
echo "==== summary"
for result in "${results[@]}"; do
  IFS='|' read -r label status seconds _ <<<"$result"
  printf '%-12s %-16s %s\n' "$label" "$status" "${seconds:+$seconds s}"
done
[ "$stopped" = 0 ] || echo "stopped after the first failure (--keep-going runs the rest)"

if [ -n "$summary" ]; then
  for result in "${results[@]}"; do
    IFS='|' read -r label status seconds notes <<<"$result"
    case "$status" in
      passed) status=pass ;;
      "not run") status=skipped seconds=0 ;;
      *) status=fail ;;
    esac
    echo "$label $status $seconds${notes:+ $notes}"
  done >"$summary" || {
    echo "tests/all.sh: cannot write the summary to $summary" >&2
    exit 2
  }
fi
exit "$failed"
