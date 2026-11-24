#!/usr/bin/env bash
# Runs the Docker test suites on this machine, one after the other or, with
# -j, several at the same time. CI runs only ansible-lint and shellcheck; run
# this before you push.
#
#   tests/all.sh [-j N] [--keep-going] [--summary FILE] [suite|entry...]
#
# Without suites it runs all of them. A release suite (one with a
# <suite>_releases line below) runs once per Ubuntu release, as the entry
# <suite>-<release>; <SUITE>_UBUNTU (the suite in capitals: HOST_UBUNTU,
# POSTAL_UBUNTU, PULSIX_AGENT_UBUNTU, ...) selects the releases, default all
# of the line, and the suite gets its one release in its own variable
# (release_vars, else <SUITE>_UBUNTU).
#   e2e          tests/run.sh (container roles, Docker-in-Docker)
#   host         tests/host/run.sh, per release
#   services     tests/services/run.sh (nodejs, redis, mariadb, mysql, ...), per release
#   harbor       tests/harbor/run.sh
#   listmonk     tests/listmonk/run.sh
#   paperless    tests/paperless/run.sh (Paperless-ngx, Traefik and Samba; about 4 GB of images)
#   tandoor      tests/tandoor/run.sh (Tandoor Recipes, Traefik and Mailpit; about 2 GB of images)
#   n8n          tests/n8n/run.sh (n8n, PostgreSQL and Traefik; about 3 GB of images)
#   anubis       tests/anubis/run.sh
#   mailcow      tests/mailcow/run.sh (real mailcow: network, about 5 GB of images)
#   cloudpanel   tests/cloudpanel/run.sh (CloudPanel's real installer)
#   pulsix_agent tests/pulsix_agent/run.sh, per release
#   backrest     tests/backrest/run.sh (Backrest, MinIO and PostgreSQL), one entry
#                that runs each release in BACKREST_UBUNTU (default "24.04 26.04")
#                and compares them
#   vaultwarden  tests/vaultwarden/run.sh (Vaultwarden, Traefik and PostgreSQL), per release
#   postal       tests/postal/run.sh (Postal, Traefik and Mailpit; its image is
#                linux/amd64 only and runs under emulation on other machines), per release
#   waf          tests/waf/run.sh (the WAF with Traefik and nginx), per release
#   varnish      tests/varnish/run.sh (the varnish role), per release
#   graylog      tests/graylog/run.sh (Graylog with Traefik), per release
#
# -j N runs up to N entries at the same time (default 1). The suites keep
# their containers, ports and output directories apart, so any of them can
# run beside any other. The entries of long_first's suites start first; an
# entry starts only while the RAM its suite needs (ram_gb, 1 GB when not
# listed) and that of the running entries fit in ram_budget (alone, when it
# needs more). Each entry's output goes to tests/output/all/<label>.log, with
# -j 1 also to the terminal; with more, the terminal gets a line when an
# entry starts and when it ends. INT or TERM stop the running entries (TERM,
# so their cleanup runs) and exit 130 or 143 without a summary.
#
# An entry that fails and whose log names a network error upstream (a
# mirror's or registry's 5xx, a DNS failure, a timeout on the way to a host on
# the internet: tests/lib/network_error.py) runs once more from scratch; its
# first log is kept as <label>.try1.log. Only the second run's result counts,
# and the entry gets the note "retried after a network error". A second
# failure is final. No python3, no retry.
#
# It stops starting entries at the first one that fails, unless --keep-going
# is given (the running ones finish), and ends with a summary: each entry's
# result and runtime. The exit code is 0 only when every entry that was asked
# for passed.
#
# An argument is a suite name or an entry label (host-24.04, postal-26.04).
# With -j 1 the entries run in the order of all_suites and then of the
# releases, whatever the order of the arguments; the summary always has that
# order.
#
# --summary FILE writes a machine-readable summary after the run, one line
# per entry:
#   <label> <pass|fail|skipped> <seconds>[ <note>...]
# "skipped" is an entry that did not run because an earlier one failed
# (seconds 0); the seconds of a retried entry are those of both runs.
# tests/attest.sh reads it.
#
# A note is a line "noix-attest-note: <text>" that a suite prints (text:
# lowercase letters, digits, spaces, "." and "-"). The summary line carries
# each note of the entry's log with its spaces replaced by "_".
#
# ALL_POLL (self-test only): seconds between two looks at the running
# entries with -j above 1 (default 1).
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
# The required suites and the default releases of the release suites (a
# suite with a <suite>_releases line runs once per release, as the entry
# <suite>-<release>). tests/attest.sh and
# .github/scripts/verify-tests-attestation.sh read these lines (keep each on
# one line): an attestation needs every entry.
all_suites=(e2e host services harbor listmonk paperless tandoor n8n anubis mailcow cloudpanel pulsix_agent backrest vaultwarden postal waf varnish graylog)
# shellcheck disable=SC2034 # read by releases_of (eval) and attest_carry.py
{
host_releases=(24.04 26.04)
services_releases=(24.04 26.04)
pulsix_agent_releases=(24.04 26.04)
vaultwarden_releases=(24.04 26.04)
postal_releases=(24.04 26.04)
waf_releases=(24.04 26.04)
varnish_releases=(24.04 26.04)
graylog_releases=(24.04 26.04)
}
# The variable that gives a release suite its one release, when it is not
# <SUITE>_UBUNTU (the suite name in capitals); <SUITE>_UBUNTU always selects
# the releases all.sh runs.
release_vars=(host:UBUNTU services:UBUNTU pulsix_agent:UBUNTU)
# With -j above 1: the suites whose entries start first, longest first (the
# rest follow in entry order), the Docker VM's RAM in GB each entry of a suite
# needs (1 when not listed) and how much of it running entries may need
# together (an entry that needs more runs alone). One line each.
long_first=(postal services graylog mailcow paperless tandoor n8n cloudpanel backrest vaultwarden waf varnish)
ram_gb=(mailcow:6 graylog:4 harbor:3 paperless:2 postal:2 tandoor:2 n8n:2)
ram_budget=16

usage() {
  echo "usage: tests/all.sh [-j N] [--keep-going] [--summary FILE] [suite|entry...]; suites: ${all_suites[*]}; entries: <suite>-<release> of a release suite" >&2
  exit 2
}

# releases_of SUITE: the default releases of a release suite (its
# <suite>_releases line), nothing for another suite.
releases_of() {
  eval "[ -n \"\${${1}_releases+set}\" ]" || return 0
  eval "printf '%s\n' \"\${${1}_releases[*]}\""
}
# release_var SUITE: the variable that gives the suite its one release.
release_var() {
  local pair
  for pair in "${release_vars[@]}"; do
    [ "${pair%%:*}" != "$1" ] || {
      echo "${pair#*:}"
      return
    }
  done
  selector_var "$1"
}
# selector_var SUITE: <SUITE>_UBUNTU, the releases all.sh runs of the suite.
selector_var() { printf '%s_UBUNTU\n' "$1" | tr '[:lower:]' '[:upper:]'; }

# valid_arg ARG: a suite name, or an entry label of a release of a release suite.
valid_arg() {
  local arg="$1" suite r
  case " ${all_suites[*]} " in *" $arg "*) return 0 ;; esac
  for suite in "${all_suites[@]}"; do
    for r in $(releases_of "$suite"); do [ "$arg" != "$suite-$r" ] || return 0; done
  done
  return 1
}

keep_going=0
summary=
jobs=1
wanted=" "
while [ "$#" -gt 0 ]; do
  arg="$1"
  shift
  case "$arg" in
    --keep-going) keep_going=1 ;;
    -j)
      case "${1:-}" in
        "" | *[!0-9]* | 0*) usage ;;
      esac
      jobs="$1"
      shift
      ;;
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

# One run per entry: "<label>|<script>|<VAR=value ...>|<suite>", in the order of
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
      *" $label "*) runs+=("$label|$script|$var=$r|$suite"); continue ;;
      *" $suite "*) ;;
      *) continue ;;
    esac
    case " $effective " in *" $r "*) runs+=("$label|$script|$var=$r|$suite") ;; esac
  done
}
runs=()
for suite in "${all_suites[@]}"; do
  script="$here/$suite/run.sh"
  [ "$suite" != e2e ] || script="$here/run.sh"
  defaults="$(releases_of "$suite" | tr '\n' ' ')"
  if [ -n "$defaults" ]; then
    selector="$(selector_var "$suite")"
    add_runs "$suite" "$script" "$(release_var "$suite")" "${!selector:-$defaults}" "$defaults"
  else
    case "$wanted" in
      " " | *" $suite "*) runs+=("$suite|$script||$suite") ;;
    esac
  fi
done

mkdir -p "$out"
poll="${ALL_POLL:-1}" # with -j above 1: seconds between two looks at the running entries
classifier="$here/lib/network_error.py"
retry_note="retried after a network error"
can_retry=1
if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$classifier" ]; then
  can_retry=0
  echo "tests/all.sh: warning: no python3 or no $classifier, so a network error upstream is not retried" >&2
fi

# Per entry i, in entry order: label, script, variables, suite, and while it
# runs or after: state (pending, running, finished), pid, start, seconds, tries,
# result (passed, failed (exit N), not run) and notes.
e_label=() e_script=() e_vars=() e_suite=() e_state=() e_pid=() e_start=() e_seconds=() e_tries=() e_result=() e_notes=() e_rc=()
n=0
for run in "${runs[@]}"; do
  IFS='|' read -r label script vars suite <<<"$run"
  e_label[n]="$label" e_script[n]="$script" e_vars[n]="$vars" e_suite[n]="$suite"
  e_state[n]=pending e_pid[n]='' e_start[n]=0 e_seconds[n]=0 e_tries[n]=0 e_result[n]="not run" e_notes[n]='' e_rc[n]=
  n=$((n + 1))
done

# ram_of SUITE: the RAM in GB an entry of SUITE needs.
ram_of() {
  local pair
  for pair in "${ram_gb[@]}"; do
    [ "${pair%%:*}" != "$1" ] || {
      echo "${pair#*:}"
      return
    }
  done
  echo 1
}

# The queue of entries to start, front first: entry order with -j 1, else the
# entries of long_first's suites first, in its order, then the rest.
queue=()
if [ "$jobs" = 1 ]; then
  for ((i = 0; i < n; i++)); do queue+=("$i"); done
else
  for suite in "${long_first[@]}"; do
    for ((i = 0; i < n; i++)); do [ "${e_suite[i]}" != "$suite" ] || queue+=("$i"); done
  done
  for ((i = 0; i < n; i++)); do
    case " ${long_first[*]} " in *" ${e_suite[i]} "*) ;; *) queue+=("$i") ;; esac
  done
fi

running=0
ram_used=0
failed=0
stopped=0

# start_entry I: starts entry I in the background; its output goes to its log
# (with -j 1 also to the terminal). With -j above 1 the pid is the suite's
# own process (exec), with -j 1 the one of the subshell that tees.
start_entry() {
  local i="$1" log="$out/${e_label[$1]}.log" vars
  read -r -a vars <<<"${e_vars[i]}"
  e_tries[i]=$((e_tries[i] + 1))
  e_state[i]=running
  e_start[i]="$(date +%s)"
  running=$((running + 1))
  ram_used=$((ram_used + $(ram_of "${e_suite[i]}")))
  if [ "$jobs" = 1 ]; then
    echo "==== ${e_label[i]}: ${vars[*]+${vars[*]} }${e_script[i]}"
    (
      env ${vars[@]+"${vars[@]}"} "${e_script[i]}" 2>&1 | tee "$log"
      exit "${PIPESTATUS[0]}"
    ) &
  else
    echo "==== ${e_label[i]} started: ${vars[*]+${vars[*]} }${e_script[i]}"
    (exec env ${vars[@]+"${vars[@]}"} "${e_script[i]}" >"$log" 2>&1) &
  fi
  e_pid[i]=$!
}

# finish_entry I RC [FINAL]: entry I ended with RC. A failure whose log
# names an upstream network error runs once more from scratch (the first log
# is kept as <label>.try1.log); otherwise, or with FINAL, its result is final.
finish_entry() {
  local i="$1" rc="$2" log="$out/${e_label[$1]}.log" line note notes=
  if [ -z "${3:-}" ]; then
    running=$((running - 1))
    ram_used=$((ram_used - $(ram_of "${e_suite[i]}")))
    e_seconds[i]=$((e_seconds[i] + $(date +%s) - e_start[i]))
  fi
  e_rc[i]="$rc"
  if [ -z "${3:-}" ] && [ "$rc" != 0 ] && [ "${e_tries[i]}" = 1 ] && [ "$can_retry" = 1 ] && [ "$stopped" = 0 ] &&
    line="$(python3 -I "$classifier" "$log")"; then
    mv -f "$log" "$out/${e_label[i]}.try1.log"
    echo "==== ${e_label[i]} failed (exit $rc) after ${e_seconds[i]} s on a network error upstream, running it once more: $line"
    e_state[i]=pending
    queue=("$i" ${queue[@]+"${queue[@]}"})
    return
  fi
  e_state[i]=finished
  # The notes of the log: each with its spaces replaced by "_", space-joined.
  while IFS= read -r note; do
    [ -z "$note" ] || notes="$notes${notes:+ }$(printf '%s' "${note// /_}")"
  done < <(sed -nE 's/^noix-attest-note: ([a-z0-9. -]+)$/\1/p' "$log")
  [ "${e_tries[i]}" = 1 ] || [ -n "${3:-}" ] || notes="$notes${notes:+ }${retry_note// /_}"
  e_notes[i]="$notes"
  if [ "$rc" = 0 ]; then
    e_result[i]=passed
  else
    e_result[i]="failed (exit $rc)"
    failed=1
    [ "$keep_going" = 1 ] || stopped=1
  fi
  echo "==== ${e_label[i]} ${e_result[i]} after ${e_seconds[i]} s"
}

# start_fitting: starts entries from the queue while a job slot is free, the
# first that fits the RAM budget each time (any entry when none runs).
start_fitting() {
  local rest=() i
  for i in ${queue[@]+"${queue[@]}"}; do
    if [ "$stopped" = 0 ] && [ "$running" -lt "$jobs" ] &&
      { [ "$running" = 0 ] || [ $((ram_used + $(ram_of "${e_suite[i]}"))) -le "$ram_budget" ]; }; then
      start_entry "$i"
    else
      rest+=("$i")
    fi
  done
  queue=(${rest[@]+"${rest[@]}"})
}

# reap: finishes every entry whose process ended.
reap() {
  local i rc
  for ((i = 0; i < n; i++)); do
    [ "${e_state[i]}" = running ] || continue
    kill -0 "${e_pid[i]}" 2>/dev/null && continue
    rc=0
    wait "${e_pid[i]}" || rc=$?
    finish_entry "$i" "$rc"
  done
}

# shellcheck disable=SC2317 # run by the INT and TERM traps
# On INT or TERM: TERM to every running suite (its EXIT trap cleans up), wait
# for them and exit without a summary, so no run claims a result it has not
# finished.
interrupted() {
  local i c
  trap '' INT TERM
  echo "tests/all.sh: interrupted, stopping the running entries" >&2
  for ((i = 0; i < n; i++)); do
    [ "${e_state[i]}" = running ] || continue
    if [ "$jobs" = 1 ] && command -v pgrep >/dev/null 2>&1; then
      # The subshell runs the suite and tee; stop the suite, let tee drain.
      for c in $(pgrep -P "${e_pid[i]}"); do
        [ "$(basename "$(ps -o comm= -p "$c" 2>/dev/null)")" = tee ] || kill -TERM "$c" 2>/dev/null
      done
    else
      kill -TERM "${e_pid[i]}" 2>/dev/null
    fi
  done
  wait
  exit "$1"
}
trap 'interrupted 130' INT
trap 'interrupted 143' TERM

# bash 3.2 has no "wait -n": with -j 1 wait for the one running entry, else
# look at the running entries every $poll seconds.
while :; do
  start_fitting
  [ "$running" -gt 0 ] || break
  if [ "$jobs" = 1 ]; then
    for ((i = 0; i < n; i++)); do
      [ "${e_state[i]}" = running ] || continue
      rc=0
      wait "${e_pid[i]}" || rc=$?
      finish_entry "$i" "$rc"
    done
  else
    sleep "$poll"
    reap
  fi
done
# An entry that failed on a network error and was to run once more when the
# run stopped: its first result is final.
for ((i = 0; i < n; i++)); do
  if [ "${e_state[i]}" = pending ] && [ "${e_tries[i]}" -gt 0 ]; then
    mv -f "$out/${e_label[i]}.try1.log" "$out/${e_label[i]}.log"
    finish_entry "$i" "${e_rc[i]}" final
  fi
done

echo
echo "==== summary"
for ((i = 0; i < n; i++)); do
  seconds="${e_seconds[i]}"
  [ "${e_result[i]}" != "not run" ] || seconds=
  retried=
  case " ${e_notes[i]} " in *" ${retry_note// /_} "*) retried=" ($retry_note)" ;; esac
  printf '%-16s %-16s %s%s\n' "${e_label[i]}" "${e_result[i]}" "${seconds:+$seconds s}" "$retried"
done
[ "$stopped" = 0 ] || echo "stopped after the first failure (--keep-going runs the rest)"

if [ -n "$summary" ]; then
  for ((i = 0; i < n; i++)); do
    case "${e_result[i]}" in
      passed) status=pass seconds="${e_seconds[i]}" ;;
      "not run") status=skipped seconds=0 ;;
      *) status=fail seconds="${e_seconds[i]}" ;;
    esac
    echo "${e_label[i]} $status $seconds${e_notes[i]:+ ${e_notes[i]}}"
  done >"$summary" || {
    echo "tests/all.sh: cannot write the summary to $summary" >&2
    exit 2
  }
fi
exit "$failed"
