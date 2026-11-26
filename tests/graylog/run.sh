#!/usr/bin/env bash
# End-to-end test of the graylog role on a throwaway systemd host per Ubuntu
# release, with Docker inside (the docker role) and the traefik role in front
# (plain HTTP, HTTPS with Traefik's own certificate and a TCP entrypoint for
# the inputs on 127.0.0.1, and a "deny" middleware; vars.yml):
#   refusals  settings the role must refuse: each run fails with its message
#             and leaves no /opt/graylog (a missing or null host name, root
#             password or password secret, a short password secret, bad
#             Graylog and MongoDB versions, a bad heap, bad inputs: an
#             unknown type, a bad or a duplicate name, two inputs on one port
#             and transport, also spelled "012201" and 12201, traefik on a
#             UDP input or without entrypoints, a token on a syslog input or
#             a null one, options with a list, 514 and 10514 (one port in the
#             container), a TCP input on the server's API port 9000; bad
#             graylog_env keys and a null value)
#   install   a fresh install (verify.yml: MongoDB, the Data Node and the
#             server healthy with the pinned images, the local log driver
#             and no published port, the secrets only as *__FILE, the heaps,
#             the compose file without a secret, the secrets 0600 in a 0700
#             directory, the versions file, vm.max_map_count from the
#             drop-in); the Data Node set up without the web interface (the
#             server answers its normal API, not the preflight); through
#             Traefik a login with the root password ($, a quote and a
#             space), a wrong one refused
#   self_logging
#             a fresh install while the daemon's default log driver is gelf
#             to udp://127.0.0.1:12201 (the docker role): Graylog's
#             containers log with local all the same and turn healthy; the
#             daemon set back to local afterwards
#   missing_data
#             <data>/mongodb moved away (an unmounted volume): the run
#             refuses and creates nothing, and compose does not start
#             MongoDB either; with the data back it runs as before
#   mountpoint
#             graylog_data_dir_mountpoint on a plain directory refused,
#             nothing changed (installed) or created (a fresh directory)
#   noop_down the server stopped: a run without changes fails naming the
#             service and starts nothing
#   reconfigure
#             a new root password and server heap: the old password no
#             longer logs in, the new one does, the heap is in the server's
#             environment; then back to the first ones; a changed
#             graylog_health_timeout alone changes nothing
#   secret_changed
#             another graylog_password_secret on the installation refused
#             before any change
#   inputs    the default inputs bound to the test host's address, a gelf_tcp
#             input on the same port as the gelf_udp one, a gelf_http input
#             with a token behind Traefik's HTTPS entrypoint and a syslog_tcp
#             input behind Traefik's TCP entrypoint with TLS (logs-tls): every
#             role input RUNNING with the title prefix, only the bound ports
#             published; a container logging with the GELF driver to the
#             bound address found through the search API with its container
#             name; through Traefik the right token accepted and found, a
#             wrong and a missing one refused and not stored; a syslog
#             message over TLS with SNI found, and one without SNI through
#             a syslog_tcp input with sni '*' on an entrypoint of its own
#             (logs-any); the default index set rotated daily and deleting
#             after 30 indices
#   reconcile the gelf_tcp input moved to 12203 (the same input, RUNNING on
#             the new port), the syslog_tcp entry removed (the input
#             deleted), the syslog_udp input on 514 (published from 10514 in
#             the container), a new token (the old one refused), a retention
#             of 7 days; a GELF TCP input made through the API without the
#             prefix survives two runs; the gelf_tcp input moved onto the
#             port of the server's API (9000) refused, nothing published;
#             the gelf_tcp input moved onto the other input's port: the run
#             waits for the restarted input, not the state from before the
#             change, and fails naming it FAILED; then back to the default
#             inputs
#   update    an installation of the previous release (7.2.1, MongoDB
#             7.0.48) with inputs of its own and a message, a jump to
#             MongoDB 9 and an update with a new root password refused
#             before any change; updated to the defaults
#             (7.2.2, MongoDB 8.0.38) in one run: the backup (root's 0700,
#             the compose file and versions of 7.2.1, the secrets,
#             inputs.json, a dump that mongorestore --dryRun reads, the Data
#             Node's data), the message and the inputs (the same ids) still
#             there, featureCompatibilityVersion 8.0, no marker, idempotent;
#             without inputs.json each input updated in place once;
#             a downgrade of Graylog and of MongoDB refused before any
#             change; a backup directory with 1 MiB free refused before any
#             change, naming the size and graylog_update_backup_logs; a
#             second update (the defaults' images tagged 7.2.3) with
#             graylog_backups_keep 1 and graylog_update_backup_logs false:
#             only its backup kept, without a copy of the Data Node's data
#   failed_update
#             that installation updated to a server image that exits (tagged
#             7.2.2) and MongoDB 8.0.38: rolled back to 7.2.1 and MongoDB
#             7.0.48 with the message and the inputs, healthy,
#             featureCompatibilityVersion 7.0, the data of the failed attempt
#             set aside, update-failed naming the versions; a run with them
#             refused before any change; a run with the installed versions
#             removes the marker; then an update whose new input cannot
#             start (GELF over TCP on the port of a TCP input without the
#             prefix) rolled back the same way
#   interrupted
#             an install stopped before it completed refused; on an
#             installation of the previous release, graylog_restore_interrupted
#             without an interrupted update and a marker the role did not
#             write refused, a marker beside update-failed of the same backup
#             removed; an update stopped during its backup: the variable
#             refused, the next run removes the partial backup and updates;
#             an update (the defaults' images tagged 7.2.3) stopped once the
#             compose file names the new version: the next run refuses naming
#             both versions and the backup, graylog_restore_interrupted brings
#             back 7.2.2 healthy with its messages and inputs, the database
#             changed after the backup undone, no update tried, update-failed
#             of another version kept; the variable then refused, and the next
#             run updates
#   secrets   the processes of the test host sampled while an update dumps
#             the database and while a failed one restores it: no test
#             secret, and no SHA-256 of one, in a command line
#   forward   on a second test host (sender, the same image without rsyslog;
#             sender.yml, forward.yml): the syslog_forward role refuses a
#             protocol sctp, tls over udp, a target without host, queue_size
#             and queue_max_disk on udp, a bad queue_max_disk and a ca_file
#             that does not exist, changing nothing; a queue_max_disk of its
#             own; then UDP to 1514, TCP to 1515 and TCP with TLS through
#             Traefik to syslog.test:6514 (a certificate from a test CA, which
#             the sender trusts): a logger line found through each of the three
#             inputs; idempotent; with syslog_forward_filter auth.* a user.info
#             line not forwarded and an auth.info line forwarded
#   forward_queue
#             the TCP queues limited to 512m on disk; the Graylog server
#             stopped while the sender logs 50 lines: all 50 arrive through
#             the TCP target once it is back
#   forward_invalid
#             a filter rsyslog refuses (an unknown facility): the run fails
#             with rsyslog's error, the previous drop-in is in place and
#             rsyslog runs; a play that fails after the role still restarts
#             rsyslog for the new drop-in
#   forward_remove
#             no targets: the drop-in removed, rsyslog restarted
#   forward_down
#             Graylog stopped: on the sender (with Docker) a container with
#             the GELF driver to udp://<address>:12201 starts, one to
#             udp://nowhere.invalid:12201 does not
# Every converge runs at least at -v, and its output must hold neither a test
# secret nor the SHA-256 of one; every successful converge of a scenario is
# repeated and must change nothing.
#
# GRAYLOG_UBUNTU selects the releases (default "24.04 26.04");
# NOIXDEV_INFRA_GRAYLOG_TESTS selects scenarios (see the end of the file);
# KEEP=1 leaves the test hosts running.
# The single-quoted scripts expand inside the test host, not here.
# shellcheck disable=SC2016,SC2119,SC2120
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
# Each release writes to tests/output/graylog-<release> (set in the loop at the end), so
# tests/all.sh can run the entries graylog-24.04 and graylog-26.04 at the same time.
out="$tests/output/graylog"
releases="${GRAYLOG_UBUNTU:-24.04 26.04}"
host=
host_ip=

app_dir=/opt/graylog
data_dir="$app_dir/data"
secrets_dir="$app_dir/secrets"
# The web interface through Traefik's HTTPS entrypoint: graylog.test resolves
# to 127.0.0.1 on the test host (start_host).
base=https://graylog.test

# Generated for this run, so that no test secret lives in the repository. The
# root password holds $, a quote and a space, so that the tests prove it
# reaches the SHA-256 and the API as written.
root_password="$(openssl rand -hex 12)"' ro$t"pw ok'
password_secret="$(openssl rand -hex 24)"
# One character short of the 16 the role requires.
short_secret="$(openssl rand -hex 7)x"
# The reconfigure scenario's root password, and a password secret of another
# installation (secret_changed).
new_root_password="$(openssl rand -hex 12)"' ne$w"pw ok'
other_secret="$(openssl rand -hex 24)"
# The tokens of the gelf_http input (inputs, then reconcile).
gelf_token="$(openssl rand -hex 16)"
new_gelf_token="$(openssl rand -hex 16)"
# No converge's output may hold one of these.
secrets=("$root_password" "$password_secret" "$short_secret" "$new_root_password" "$other_secret"
  "$gelf_token" "$new_gelf_token")
# Nor their SHA-256 (the host keeps the root password's, inputs.json the
# tokens', the versions file the password secret's).
sha256() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
for secret in "${secrets[@]}"; do secrets+=("$(sha256 "$secret")"); done

cleanup() {
  [ "${KEEP:-0}" = 1 ] || [ -z "$host" ] || docker rm -f -v "$host" >/dev/null 2>&1 || true
  [ "${KEEP:-0}" = 1 ] || [ -z "${sender:-}" ] || docker rm -f -v "$sender" >/dev/null 2>&1 || true
  sender=
}
# shellcheck source=/dev/null
. "$here/../lib/suite.sh"
noix_exit_guard

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
noix_link_collection "$root" "$tests/output"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"

fail() { echo "$*" >&2; exit 1; }

# h <cmd...>: run in the test host.
h() { docker exec "$host" "$@"; }

# Fails when the file holds a test secret, as it is or up to its first quote
# or backslash (a quoted or escaped copy): expect_no_secrets <file> <what>.
expect_no_secrets() {
  local secret part
  for secret in "${secrets[@]}"; do
    for part in "$secret" "${secret%%[\'\"\\\`]*}"; do
      if [ "${#part}" -ge 8 ] && grep -qF -- "$part" "$1"; then
        fail "$2 holds a test secret (${part:0:4}...): $(grep -nF -- "$part" "$1" | head -n 3 | cut -c1-200)"
      fi
    done
  done
}

# play [-e ...]: the test host's playbook, always at least at -v (task
# results shown), so that every run of the suite shows that no task prints a
# secret; its output goes to converge.log, which must hold no test secret,
# whether the run failed or not.
play() {
  local rc=0
  local noix_cache_play=() && noix_cache_array noix_cache_play noix_cache_play_args
  ansible-playbook -v -i "$here/inventory.yml" -e "test_host=$host" ${noix_cache_play[@]+"${noix_cache_play[@]}"} "$here/converge.yml" "$@" >"$out/converge.log" 2>&1 || rc=$?
  expect_no_secrets "$out/converge.log" "the converge output"
  return "$rc"
}
# converge <scenario> [extra vars file]: play, which must succeed. The first
# argument names what the run is for (it shows in the failure); the second,
# when given, is a JSON or YAML file of extra variables.
converge() {
  local what="$1" vars_file="${2:-}" args=()
  [ -z "$vars_file" ] || args=(-e "@$vars_file")
  play "${args[@]+"${args[@]}"}" || { cat "$out/converge.log" >&2; fail "converge failed ($what)"; }
}
# converge_fails [-e ...]: play, which must fail.
converge_fails() {
  if play "$@"; then cat "$out/converge.log" >&2; fail "converge succeeded, but must fail"; fi
}
expect_in_log() {
  grep -qF -- "$1" "$out/converge.log" || { cat "$out/converge.log" >&2; fail "the converge output lacks: $1"; }
}

# The variables the graylog role needs in every scenario; the secrets of this
# run in files of mode 0600: write_secret_vars <file> <root password>
# <password secret>. role-vars.json holds the first pair, new-root-vars.json
# the reconfigure scenario's root password, other-secret-vars.json another
# password secret.
write_secret_vars() {
  (
    umask 077
    env "ROOT_PASSWORD=$2" "PASSWORD_SECRET=$3" python3 -c '
import json, os
print(json.dumps({"test_graylog": True,
                  "graylog_root_password": os.environ["ROOT_PASSWORD"],
                  "graylog_password_secret": os.environ["PASSWORD_SECRET"]}))' >"$out/$1"
  )
}
write_role_vars() {
  write_secret_vars role-vars.json "$root_password" "$password_secret"
  write_secret_vars new-root-vars.json "$new_root_password" "$password_secret"
  write_secret_vars other-secret-vars.json "$root_password" "$other_secret"
}
# role_converge <what> [-e ...]: the host's playbook with the role, which must
# succeed; role_converge_unchanged: the same again, which must change
# nothing; role_converge_fails [-e ...]: which must fail.
role_converge() {
  local what="$1"
  shift
  play -e "@$out/role-vars.json" "$@" || { cat "$out/converge.log" >&2; fail "converge failed ($what)"; }
}
role_converge_unchanged() {
  role_converge "$@"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/converge.log" \
    || { cat "$out/converge.log" >&2; fail "the repeated converge changed something ($1)"; }
}
role_converge_fails() { converge_fails -e "@$out/role-vars.json" "$@"; }

# verify [-e ...]: verify.yml on the installation.
verify() {
  ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$here/verify.yml" "$@" >"$out/verify.log" 2>&1 \
    || { cat "$out/verify.log" >&2; fail "verify.yml failed"; }
}

# A request through Traefik (HTTPS, Traefik's own certificate): prints the
# body, then the status on a line of its own. request <path> [curl options...].
request() {
  local path="$1"
  shift
  h curl -sk --max-time 30 -w '\n%{http_code}' "$@" "$base$path"
}
# expect_answer <status> <body text> <path> [curl options...]: the status
# and a body that holds the text.
expect_answer() {
  local status="$1" text="$2" path="$3" answer
  shift 3
  answer="$(request "$path" "$@")"
  { [ "${answer##*$'\n'}" = "$status" ] && [[ "${answer%$'\n'*}" == *"$text"* ]]; } \
    || fail "$path answered ${answer##*$'\n'} ($(printf '%s' "${answer%$'\n'*}" | head -c 200)), not $status with: $text"
}
# The same, retried while Traefik picks up new labels or the server starts:
# wait_answer <status> <body text> <path> [curl options...].
wait_answer() {
  local answer
  for _ in $(seq 60); do
    answer="$(request "$3" "${@:4}")"
    { [ "${answer##*$'\n'}" = "$1" ] && [[ "${answer%$'\n'*}" == *"$2"* ]]; } && return 0
    sleep 2
  done
  expect_answer "$@"
}
# The login of the root user through Traefik: GET /api/system with basic
# auth, which only the normal API answers (the preflight has no such
# resource). expect_login <password>, expect_no_login <password>.
expect_login() {
  wait_answer 200 '"lifecycle":"running"' /api/system -u "admin:$1" -H 'Accept: application/json'
}
expect_no_login() {
  expect_answer 401 '' /api/system -u "admin:$1" -H 'Accept: application/json'
}

# The root user's request to Graylog's API through Traefik: prints the body;
# fails unless the status is 2xx. api <path> [curl options...].
api() {
  local path="$1" answer
  shift
  answer="$(request "/api$path" -u "admin:$root_password" -H 'Accept: application/json' -H 'X-Requested-By: tests' "$@")"
  [[ "${answer##*$'\n'}" == 2?? ]] \
    || fail "/api$path answered ${answer##*$'\n'} ($(printf '%s' "${answer%$'\n'*}" | head -c 300))"
  printf '%s' "${answer%$'\n'*}"
}
# py <expression>: evaluates a Python expression on the JSON document on stdin
# (d), here, and prints it.
py() { python3 -I -c "import json, sys; d = json.load(sys.stdin); print($1)"; }

# The inputs of the inputs scenario, as extra variables in a file of mode
# 0600 (it holds the token): write_inputs_vars <file> <JSON of the inputs>
# <token>; "TOKEN" in the JSON is replaced by the token.
write_inputs_vars() {
  (
    umask 077
    env "INPUTS=$2" "TOKEN=$3" python3 -I -c '
import json, os
inputs = json.loads(os.environ["INPUTS"])
for entry in inputs:
    if entry.get("token") == "TOKEN":
        entry["token"] = os.environ["TOKEN"]
print(json.dumps({"graylog_inputs": inputs}))' >"$out/$1"
  )
}
# The inputs of the inputs scenario: the defaults bound to the test host,
# GELF over TCP on the port of the GELF UDP input, GELF over HTTP with a
# token behind the HTTPS entrypoint, syslog over TCP behind logs-tls, and
# syslog over TCP for any SNI behind logs-any.
# inputs_json [gelf_tcp port] [with syslog_tcp: 1 or 0] [syslog_udp port].
inputs_json() {
  local gelf_tcp_port="${1:-12201}" with_syslog_tcp="${2:-1}" syslog_udp_port="${3:-1514}" syslog_tcp=
  [ "$with_syslog_tcp" = 0 ] \
    || syslog_tcp=', {"name": "syslog-tcp", "type": "syslog_tcp", "port": 1515, "traefik": {"hostname": "syslog.test", "entrypoints": ["logs-tls"]}}'
  printf '%s' '[{"name": "gelf-udp", "type": "gelf_udp", "port": 12201, "bind": ["'"$host_ip"'"]},
    {"name": "syslog-udp", "type": "syslog_udp", "port": '"$syslog_udp_port"', "bind": ["'"$host_ip"'"]},
    {"name": "gelf-tcp", "type": "gelf_tcp", "port": '"$gelf_tcp_port"', "bind": ["'"$host_ip"'"]},
    {"name": "gelf-http", "type": "gelf_http", "port": 12202, "token": "TOKEN",
     "traefik": {"hostname": "gelf.test", "entrypoints": ["websecure"]}},
    {"name": "syslog-any", "type": "syslog_tcp", "port": 1516,
     "traefik": {"hostname": "syslog-any.test", "entrypoints": ["logs-any"], "sni": "*"}}'"$syslog_tcp"']'
}
# verify.yml's verify_published: the graylog container's published ports,
# as <address>:<host port>:<container port>/<protocol>, in a file:
# write_published <file> <port specs...>.
write_published() {
  local file="$1"
  shift
  python3 -I -c 'import json, sys; print(json.dumps({"verify_published": sys.argv[1:]}))' "$@" >"$out/$file"
}

# The inputs Graylog has, as lines "<id> <title>|<state>|<port>" (state from
# /api/system/inputstates, "-" when it has none).
inputs_lines() {
  local inputs states
  inputs="$(api /system/inputs)"
  states="$(api /system/inputstates)"
  printf '%s\n%s' "$inputs" "$states" | python3 -I -c '
import json, sys
inputs, states = (json.loads(part) for part in sys.stdin.read().split("\n", 1))
state = {s["id"]: s["state"] for s in states["states"]}
for i in inputs["inputs"]:
    print("%s %s|%s|%s" % (i["id"], i["title"], state.get(i["id"], "-"), i["attributes"].get("port")))'
}
# Waits until the role's input <name> is RUNNING on <container port>, with the
# title prefix, and prints its id: expect_input <name> <container port>.
expect_input() {
  local lines line
  for _ in $(seq 30); do
    lines="$(inputs_lines)"
    line="$(printf '%s\n' "$lines" | grep -F " ansible: $1|" || true)"
    if [ "$(printf '%s\n' "$line" | grep -c .)" = 1 ] && [ "${line#* ansible: "$1"|}" = "RUNNING|$2" ]; then
      printf '%s' "${line%% *}"
      return 0
    fi
    sleep 2
  done
  fail "the input \"ansible: $1\" is not RUNNING once on $2: $(printf '%s' "$lines" | tr '\n' ';')"
}
expect_no_input() {
  local lines
  lines="$(inputs_lines)"
  if printf '%s\n' "$lines" | grep -qF " ansible: $1|"; then fail "the input \"ansible: $1\" is still there"; fi
}

# The messages of the last 2 hours (an update scenario looks for one sent
# before its install and updates) that hold <text>, one per line, as
# "<container_name>|<message>": search <text>.
search() {
  api "/search/messages?query=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote("\"%s\"" % sys.argv[1]))' "$1")&fields=container_name,message&timerange=7200s&size=500" \
    | py '"\n".join("%s|%s" % (row[0], row[1]) for row in d["datarows"])'
}
# Waits up to 60 seconds until a message with <text> is found, and checks
# its container name when given: expect_found <text> [container name].
expect_found() {
  local found
  for _ in $(seq 30); do
    found="$(search "$1")"
    if [ -n "$found" ]; then
      [ -z "${2:-}" ] || [ "${found%%|*}" = "$2" ] || fail "the message $1 has the container name ${found%%|*}, not $2"
      return 0
    fi
    sleep 2
  done
  fail "no message with $1 within 60 seconds"
}
expect_not_found() {
  local found
  found="$(search "$1")"
  [ -z "$found" ] || fail "the message $1 was stored: $found"
}

# A GELF message through Traefik to the gelf_http input: prints the status.
# gelf_http <text> [curl options...].
gelf_http() {
  local text="$1"
  shift
  h curl -sk --max-time 30 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' "$@" \
    -d '{"version": "1.1", "host": "gelf-http-probe", "short_message": "'"$text"'"}' https://gelf.test/gelf
}
# Sends until Traefik routes it and Graylog takes it (202).
gelf_http_accepted() {
  local status
  for _ in $(seq 30); do
    status="$(gelf_http "$@")"
    [ "$status" = 202 ] && return 0
    sleep 2
  done
  fail "the gelf_http input answered $status, not 202"
}
expect_gelf_http_refused() {
  local status
  status="$(gelf_http "$@")"
  [ "$status" = 401 ] || fail "the gelf_http input answered $status, not 401, to a wrong or missing token"
}

# A syslog message over TLS through one of Traefik's TCP entrypoints:
# syslog_tls <text> [port [openssl option...]], by default to logs-tls with
# SNI syslog.test.
syslog_tls() {
  local text="$1" port="${2:-6514}" options="${*:3}"
  h sh -c "printf '<14>1 %s syslog-probe probe - - - %s\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" '$text' \
    | timeout 10 openssl s_client -quiet -no_ign_eof -connect 127.0.0.1:$port ${options:--servername syslog.test} >/dev/null 2>&1" || true
}
# Sends until the message is found (Traefik picks up a new router after a
# moment): expect_syslog_tls <text> [port [openssl option...]].
expect_syslog_tls() {
  local found
  for _ in $(seq 15); do
    syslog_tls "$@"
    sleep 4
    found="$(search "$1")"
    [ -z "$found" ] || return 0
  done
  fail "no syslog message $1 over TLS (port ${2:-6514}, ${*:3}) within 60 seconds"
}

# The default index set's rotation and retention, as
# "<rotation class> <period> <retention class> <indices>".
retention_line() {
  api /system/indices/index_sets \
    | py '" ".join(str(x) for s in d["index_sets"] if s["default"] for x in (s["rotation_strategy_class"].rsplit(".", 1)[-1], s["rotation_strategy"].get("rotation_period"), s["retention_strategy_class"].rsplit(".", 1)[-1], s["retention_strategy"].get("max_number_of_indices")))'
}
expect_retention() {
  [ "$(retention_line)" = "TimeBasedRotationStrategy P1D DeletionRetentionStrategy $1" ] \
    || fail "the default index set is not rotated daily and deleted after $1 indices: $(retention_line)"
}

# docker compose in app_dir on the test host: compose <args...>.
compose() { h sh -c "cd $app_dir && docker compose $*"; }
# Waits until every container of the project is healthy again.
wait_healthy() {
  for _ in $(seq 120); do
    [ "$(compose ps --all --format "'{{.Service}} {{.Health}}'" | sort | tr '\n' ' ')" = 'datanode healthy graylog healthy mongodb healthy ' ] \
      && return 0
    sleep 5
  done
  fail "the containers did not become healthy: $(compose ps --all)"
}
# Notes the compose file, the secrets, the versions file and the containers,
# for expect_untouched.
note_untouched() {
  untouched_before="$(h sh -c "sha256sum $app_dir/compose.yaml $app_dir/versions $secrets_dir/*; docker ps -aq --filter label=com.docker.compose.project=graylog")"
}
# Fails unless the refused run changed nothing: its recap, the files and the
# containers since note_untouched.
expect_untouched() {
  grep -Eq 'changed=0 ' "$out/converge.log" || { cat "$out/converge.log" >&2; fail "the refused run changed something"; }
  [ "$(h sh -c "sha256sum $app_dir/compose.yaml $app_dir/versions $secrets_dir/*; docker ps -aq --filter label=com.docker.compose.project=graylog")" = "$untouched_before" ] \
    || fail "the refused run changed the compose file, the versions, a secret or the containers"
}
# Fails when the compose file holds a test secret or its SHA-256.
expect_compose_clean() {
  h cat "$app_dir/compose.yaml" >"$out/compose.yaml"
  expect_no_secrets "$out/compose.yaml" "$app_dir/compose.yaml"
  local hash
  for hash in "$(printf '%s' "$root_password" | shasum -a 256 | cut -d' ' -f1)" \
    "$(printf '%s' "$password_secret" | shasum -a 256 | cut -d' ' -f1)"; do
    if grep -qF -- "$hash" "$out/compose.yaml"; then fail "$app_dir/compose.yaml holds the SHA-256 of a test secret"; fi
  done
}
# Removes the installation, for a scenario that needs a fresh one.
remove_installation() {
  h sh -c "if [ -e $app_dir/compose.yaml ]; then cd $app_dir && docker compose down --volumes >/dev/null 2>&1; fi; rm -rf $app_dir"
}
# An installation, for a scenario that runs on a host without one.
ensure_installed() {
  h test -e "$app_dir/compose.yaml" && return 0
  echo "== install for $1"
  role_converge "install for $1"
}

start_host() {
  local ubuntu="$1"
  host="noixdev-graylog-$ubuntu"
  docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  # The anonymous volumes give the inner Docker a file system it can mount
  # overlays on; "docker rm -v" removes them with the host.
  noix_cache_run=() && noix_cache_array noix_cache_run noix_cache_run_args
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd \
    --name "$host" ${noix_cache_run[@]+"${noix_cache_run[@]}"} "noixdev-infra-host:$ubuntu" >/dev/null
  noix_cache_host_setup "$host"
  until (h systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
  # The image's policy-rc.d (exit 101) keeps package scripts from starting
  # services; servers have none.
  h rm -f /usr/sbin/policy-rc.d
  h sh -c 'echo "127.0.0.1 graylog.test gelf.test syslog.test" >>/etc/hosts'
  # The test host's address on Docker's network, where the inputs are bound.
  host_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$host" | cut -d' ' -f1)"
  [[ "$host_ip" =~ ^[0-9.]+$ ]] || fail "the test host has no address: $host_ip"

  echo "== test host (ubuntu $ubuntu)"
  converge "the test host"
  write_role_vars
}

# refused <message> [-e ...]: the role stops before any change, with a message.
refused() {
  local message="$1"
  shift
  role_converge_fails "$@"
  grep -qF -- "$message" "$out/converge.log" \
    || { cat "$out/converge.log" >&2; fail "the refusal lacks \"$message\""; }
  h test ! -e "$app_dir" || fail "$message: $app_dir was created"
}

test_refusals() {
  echo "== refusals (ubuntu $1)"
  refused 'graylog_hostname is required' -e graylog_hostname=
  refused 'graylog_root_password is required' -e graylog_root_password=
  refused 'graylog_password_secret is required' -e graylog_password_secret=
  # A key left empty in YAML is null, which must not pass as the text None.
  refused 'graylog_hostname is required' -e '{"graylog_hostname": null}'
  refused 'graylog_root_password is required' -e '{"graylog_root_password": null}'
  refused 'graylog_password_secret is required' -e '{"graylog_password_secret": null}'
  refused 'at least 16 characters' -e "graylog_password_secret=$short_secret"
  refused 'is not a release the role runs' -e graylog_version=latest
  refused 'is not a release the role runs' -e graylog_version=6.3.15
  refused 'is not a release the role runs' -e graylog_version=7.2
  refused 'is not a release the role runs' -e graylog_mongodb_version=6.0.20
  refused 'is not a release the role runs' -e graylog_mongodb_version=8.0
  refused 'must be a whole number and m or g' -e graylog_server_heap=1GB

  refused 'Input number 1 of graylog_inputs is not valid' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_ftp", "port": 12201}]}'
  refused 'Input number 1 of graylog_inputs is not valid' \
    -e '{"graylog_inputs": [{"name": "Bad_Name", "type": "gelf_udp", "port": 12201}]}'
  refused 'names an input more than once' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_udp", "port": 12201}, {"name": "a", "type": "gelf_udp", "port": 12202}]}'
  refused 'uses a port twice for the same transport' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_udp", "port": 12201}, {"name": "b", "type": "gelf_udp", "port": 12201}]}'
  # The same port spelled another way.
  refused 'uses a port twice for the same transport' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_udp", "port": "012201"}, {"name": "b", "type": "gelf_udp", "port": 12201}]}'
  # A port below 1024 is the port plus 10000 in the container: 514 and 10514
  # are one port there.
  refused 'uses a port twice for the same transport' \
    -e '{"graylog_inputs": [{"name": "a", "type": "syslog_udp", "port": 514}, {"name": "b", "type": "gelf_udp", "port": 10514}]}'
  # A TCP input on the server's API port would publish the API.
  refused 'port 9000 is the server' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_tcp", "port": 9000}]}'
  refused 'is a UDP input and has a traefik block' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_udp", "port": 12201, "traefik": {"hostname": "a.test", "entrypoints": ["websecure"]}}]}'
  refused 'only gelf_http inputs take a token' \
    -e '{"graylog_inputs": [{"name": "a", "type": "syslog_tcp", "port": 1514, "token": "x"}]}'
  refused 'only gelf_http inputs take a token' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_http", "port": 12202, "token": null}]}'
  refused 'traefik takes hostname and entrypoints' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_http", "port": 12202, "traefik": {"hostname": "a.test"}}]}'
  # A route that takes any SNI catches every connection of its entrypoint.
  refused 'an entrypoint with a catch-all route serves one input only' \
    -e '{"graylog_inputs": [{"name": "a", "type": "syslog_tcp", "port": 1515, "traefik": {"hostname": "a.test", "entrypoints": ["logs-tls"], "sni": "*"}}, {"name": "b", "type": "gelf_tcp", "port": 12201, "traefik": {"hostname": "b.test", "entrypoints": ["logs-tls"]}}]}'
  refused 'sni is * or a host name' \
    -e '{"graylog_inputs": [{"name": "a", "type": "syslog_tcp", "port": 1515, "traefik": {"hostname": "a.test", "entrypoints": ["logs-tls"], "sni": "a b"}}]}'
  refused 'for the TCP routes of gelf_tcp and syslog_tcp inputs only' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_http", "port": 12202, "traefik": {"hostname": "a.test", "entrypoints": ["websecure"], "sni": "a.test"}}]}'
  # The web interface's entrypoint is not one for a catch-all route either.
  refused 'logs-tls: a, the web interface' -e '{"graylog_traefik_entrypoints": ["logs-tls"]}' \
    -e '{"graylog_inputs": [{"name": "a", "type": "syslog_tcp", "port": 1515, "traefik": {"hostname": "a.test", "entrypoints": ["logs-tls"], "sni": "*"}}]}'
  refused 'options must be a mapping' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_udp", "port": 12201, "options": {"x": [1]}}]}'

  refused 'sets these itself' -e '{"graylog_env": {"GRAYLOG_MONGODB_URI": "x"}}'
  refused 'sets these itself' -e '{"graylog_env": {"GRAYLOG_SELFSIGNED_STARTUP": false}}'
  refused 'sets these itself' -e '{"graylog_env": {"GRAYLOG_DATANODE_X": "x"}}'
  refused 'sets these itself' -e '{"graylog_env": {"GRAYLOG_FOO__FILE": "x"}}'
  refused 'must be environment variable names' -e '{"graylog_env": {"lower": "x"}}'
  refused 'no value for GRAYLOG_EMPTY' -e '{"graylog_env": {"GRAYLOG_EMPTY": null}}'
}

test_install() {
  echo "== install (ubuntu $1)"
  remove_installation
  role_converge install
  verify
  expect_compose_clean
  # The secrets reach the server as written: the SHA-256 of the root password
  # with its $, quote and space.
  [ "$(h cat "$secrets_dir/root_password_sha2")" = "$(printf '%s' "$root_password" | shasum -a 256 | cut -d' ' -f1)" ] \
    || fail "root_password_sha2 is not the SHA-256 of the root password"
  # Set up without the web interface: the server runs its normal API (the
  # preflight answers neither /api/system nor a login).
  expect_login "$root_password"
  expect_no_login 'not-the-root-password'
  expect_answer 200 'ALIVE' /api/system/lbstatus
  # The versions of the installation.
  [ "$(h sed -n 's/^graylog: *//p' "$app_dir/versions")" = 7.2.2 ] \
    || fail "the versions file does not name Graylog 7.2.2: $(h cat "$app_dir/versions")"
  [ "$(h sed -n 's/^mongodb: *//p' "$app_dir/versions")" = 8.0.38 ] \
    || fail "the versions file does not name MongoDB 8.0.38: $(h cat "$app_dir/versions")"
  role_converge_unchanged install
}

# The daemon-wide GELF driver of the docker role, pointing at the input on the
# host itself (nothing listens there yet: UDP drops the messages).
gelf_daemon='{"docker_log_driver": "gelf", "docker_log_opts": {"gelf-address": "udp://127.0.0.1:12201", "mode": "non-blocking"}}'

test_self_logging() {
  echo "== self_logging (ubuntu $1)"
  remove_installation
  play -e "$gelf_daemon" || { cat "$out/converge.log" >&2; fail "converge failed (the gelf daemon)"; }
  [ "$(h docker info --format '{{.LoggingDriver}}')" = gelf ] || fail "the daemon's default log driver is not gelf"
  role_converge self_logging -e "$gelf_daemon"
  verify
  role_converge_unchanged self_logging -e "$gelf_daemon"
  # Back to the docker role's defaults for the next scenarios; the containers
  # run on (live restore).
  play || { cat "$out/converge.log" >&2; fail "converge failed (the local daemon)"; }
  [ "$(h docker info --format '{{.LoggingDriver}}')" = local ] || fail "the daemon's default log driver is not local again"
  wait_healthy
  role_converge_unchanged "self_logging, the local daemon"
}

test_missing_data() {
  echo "== missing_data (ubuntu $1)"
  ensure_installed missing_data
  compose stop >/dev/null 2>&1
  h mv "$data_dir/mongodb" "$data_dir/mongodb.aside"
  note_untouched
  role_converge_fails
  expect_in_log "lacks mongodb: is the volume mounted?"
  h test ! -e "$data_dir/mongodb" || fail "the refused run created $data_dir/mongodb"
  expect_untouched
  # compose does not create the bind's source either.
  if compose start mongodb >/dev/null 2>&1; then fail "docker compose started MongoDB without its data"; fi
  h test ! -e "$data_dir/mongodb" || fail "docker compose created $data_dir/mongodb"

  h mv "$data_dir/mongodb.aside" "$data_dir/mongodb"
  compose start >/dev/null 2>&1
  wait_healthy
  role_converge_unchanged missing_data
  expect_login "$root_password"
}

test_mountpoint() {
  echo "== mountpoint (ubuntu $1)"
  ensure_installed mountpoint
  note_untouched
  role_converge_fails -e '{"graylog_data_dir_mountpoint": true}'
  expect_in_log "$data_dir is not a mountpoint: is the volume mounted?"
  expect_untouched
  role_converge_fails -e '{"graylog_data_dir_mountpoint": true}' -e graylog_dir=/opt/gl-mountpoint
  expect_in_log "/opt/gl-mountpoint/data is not a mountpoint"
  h test ! -e /opt/gl-mountpoint || fail "the refused run created /opt/gl-mountpoint"
}

test_noop_down() {
  echo "== noop_down (ubuntu $1)"
  ensure_installed noop_down
  compose stop graylog >/dev/null 2>&1
  note_untouched
  role_converge_fails
  expect_in_log "the services graylog are not running"
  [ "$(compose ps --all --format "'{{.State}}'" graylog)" = exited ] || fail "the run without changes started the server"
  expect_untouched
  compose start graylog >/dev/null 2>&1
  wait_healthy
  role_converge_unchanged noop_down
}

test_reconfigure() {
  echo "== reconfigure (ubuntu $1)"
  ensure_installed reconfigure
  role_converge reconfigure -e "@$out/new-root-vars.json" -e graylog_server_heap=768m
  expect_login "$new_root_password"
  expect_no_login "$root_password"
  verify -e verify_server_heap=768m
  role_converge_unchanged reconfigure -e "@$out/new-root-vars.json" -e graylog_server_heap=768m

  # Back to the first password and heap, for the next scenarios.
  role_converge "reconfigure back"
  expect_login "$root_password"
  expect_no_login "$new_root_password"
  verify

  # How long the role waits is not Graylog's configuration.
  role_converge_unchanged "a changed health timeout" -e graylog_health_timeout=900
}

test_secret_changed() {
  echo "== secret_changed (ubuntu $1)"
  ensure_installed secret_changed
  note_untouched
  role_converge_fails -e "@$out/other-secret-vars.json"
  expect_in_log "graylog_password_secret is not the one the installation in $app_dir was made with"
  expect_untouched
  role_converge_unchanged secret_changed
}

# The image of a container that logs one line: MongoDB's, which the host has.
probe_image=docker.io/library/mongo:8.0.38

test_inputs() {
  echo "== inputs (ubuntu $1)"
  ensure_installed inputs
  write_inputs_vars inputs-vars.json "$(inputs_json)" "$gelf_token"
  role_converge inputs -e "@$out/inputs-vars.json"
  write_published inputs-published.json \
    "$host_ip:12201:12201/udp" "$host_ip:1514:1514/udp" "$host_ip:12201:12201/tcp"
  verify -e "@$out/inputs-published.json"
  expect_input gelf-udp 12201 >/dev/null
  expect_input syslog-udp 1514 >/dev/null
  expect_input gelf-tcp 12201 >/dev/null
  expect_input gelf-http 12202 >/dev/null
  expect_input syslog-tcp 1515 >/dev/null
  expect_input syslog-any 1516 >/dev/null

  # A container with the GELF driver to the bound address.
  local marker
  marker="gelf-udp-$(openssl rand -hex 6)"
  h docker run --rm --name gelf-probe --log-driver gelf --log-opt "gelf-address=udp://$host_ip:12201" \
    --entrypoint echo "$probe_image" "$marker" >/dev/null
  expect_found "$marker" gelf-probe

  # GELF over HTTPS through Traefik: the right token only. The refused
  # messages are looked for once the accepted one is found and 30 seconds
  # have passed.
  local accepted wrong missing since
  accepted="gelf-http-$(openssl rand -hex 6)"
  wrong="gelf-http-wrong-$(openssl rand -hex 6)"
  missing="gelf-http-missing-$(openssl rand -hex 6)"
  gelf_http_accepted "$accepted" -H "Authorization: Bearer $gelf_token"
  expect_gelf_http_refused "$wrong" -H "Authorization: Bearer not-the-$gelf_token"
  expect_gelf_http_refused "$missing"
  since="$(date +%s)"
  expect_found "$accepted"
  sleep "$((30 - ($(date +%s) - since) > 0 ? 30 - ($(date +%s) - since) : 0))"
  expect_not_found "$wrong"
  expect_not_found "$missing"

  # Syslog over TLS through Traefik's TCP routers: with SNI, and without
  # any (as a sender that connects to an IP address) through the input that
  # takes any SNI.
  expect_syslog_tls "syslog-tls-$(openssl rand -hex 6)"
  expect_syslog_tls "syslog-any-$(openssl rand -hex 6)" 6515 -noservername

  expect_retention 30
  role_converge_unchanged inputs -e "@$out/inputs-vars.json"
}

test_reconcile() {
  echo "== reconcile (ubuntu $1)"
  ensure_installed reconcile
  write_inputs_vars inputs-vars.json "$(inputs_json)" "$gelf_token"
  role_converge "reconcile, the inputs" -e "@$out/inputs-vars.json"
  local gelf_tcp_id gelf_http_id manual_id
  gelf_tcp_id="$(expect_input gelf-tcp 12201)"
  gelf_http_id="$(expect_input gelf-http 12202)"
  expect_input syslog-tcp 1515 >/dev/null
  # An input of someone else: no prefix.
  api /system/inputs -X POST -H 'Content-Type: application/json' \
    -d '{"title": "manual gelf", "type": "org.graylog2.inputs.gelf.tcp.GELFTCPInput", "global": true,
         "configuration": {"bind_address": "0.0.0.0", "port": 12299, "recv_buffer_size": 262144}}' >/dev/null
  local lines
  lines="$(inputs_lines)"
  manual_id="$(printf '%s\n' "$lines" | grep -F ' manual gelf|' | cut -d' ' -f1 || true)"
  [ -n "$manual_id" ] || fail "the input without the prefix was not created"

  write_inputs_vars reconcile-vars.json "$(inputs_json 12203 0 514)" "$new_gelf_token"
  role_converge reconcile -e "@$out/reconcile-vars.json" -e graylog_retention_days=7
  local moved_id
  moved_id="$(expect_input gelf-tcp 12203)"
  [ "$moved_id" = "$gelf_tcp_id" ] || fail "the gelf_tcp input was replaced ($moved_id), not updated ($gelf_tcp_id)"
  expect_no_input syslog-tcp
  expect_input syslog-udp 10514 >/dev/null
  [ "$(expect_input gelf-http 12202)" = "$gelf_http_id" ] || fail "the gelf_http input was replaced for its new token, not updated"
  write_published reconcile-published.json \
    "$host_ip:12201:12201/udp" "$host_ip:514:10514/udp" "$host_ip:12203:12203/tcp"
  verify -e "@$out/reconcile-published.json"
  local marker
  marker="gelf-http-new-$(openssl rand -hex 6)"
  gelf_http_accepted "$marker" -H "Authorization: Bearer $new_gelf_token"
  expect_gelf_http_refused "gelf-http-old" -H "Authorization: Bearer $gelf_token"
  expect_found "$marker"
  expect_retention 7
  role_converge_unchanged reconcile -e "@$out/reconcile-vars.json" -e graylog_retention_days=7
  lines="$(inputs_lines)"
  printf '%s\n' "$lines" | grep -qF "$manual_id manual gelf|" || fail "the input without the prefix was removed"

  # The gelf_tcp input moved onto the port of the server's API, published on
  # the host's address: refused before any change, so the API is not
  # published past Traefik.
  write_inputs_vars api-port-vars.json "$(inputs_json 9000 0 514)" "$new_gelf_token"
  role_converge_fails -e "@$out/api-port-vars.json" -e graylog_retention_days=7
  expect_in_log "port 9000 is the server"
  verify -e "@$out/reconcile-published.json"

  # The gelf_tcp input moved onto the port of the TCP input without the
  # prefix: Graylog restarts it after the change, and the new one cannot
  # open its port (a clash over UDP would not fail: Graylog binds UDP
  # inputs with SO_REUSEPORT). The first answer after the change can still
  # be the RUNNING input from before it, which must not count. Graylog
  # 7.2.2 restarts the input at once, so this does not force that race; it
  # pins the failure being reported.
  write_inputs_vars clash-vars.json "$(inputs_json 12299 0 514)" "$new_gelf_token"
  role_converge_fails -e "@$out/clash-vars.json" -e graylog_retention_days=7
  expect_in_log "The inputs gelf-tcp (FAILED) of graylog_inputs are not RUNNING"
  role_converge "reconcile after the port clash" -e "@$out/reconcile-vars.json" -e graylog_retention_days=7
  moved_id="$(expect_input gelf-tcp 12203)"
  [ "$moved_id" = "$gelf_tcp_id" ] || fail "the gelf_tcp input was replaced ($moved_id) after the port clash"

  # Back to the default inputs and retention.
  api "/system/inputs/$manual_id" -X DELETE >/dev/null
  role_converge "reconcile back"
  expect_no_input gelf-tcp
  expect_no_input gelf-http
  expect_no_input syslog-any
  expect_input gelf-udp 12201 >/dev/null
  expect_input syslog-udp 1514 >/dev/null
  expect_retention 30
  verify
}

# The update scenarios: the previous release with the latest MongoDB 7.0
# patch, updated to the defaults; the defaults' images tagged as next_version
# under test_repo are a newer release that works.
defaults="$root/roles/graylog/defaults/main.yml"
# The value of a top-level key in a YAML file: value_of <file> <key>.
value_of() { sed -n "s/^$2: *//p" "$1" 2>/dev/null || true; }
old_version=7.2.1
old_mongodb=7.0.48
new_version="$(value_of "$defaults" graylog_version)"
new_mongodb="$(value_of "$defaults" graylog_mongodb_version)"
next_version=7.2.3
test_repo=test.invalid
busybox=busybox:1.37.0
backups="$data_dir/backups"
failed_marker="$app_dir/update-failed"
progress="$app_dir/update-in-progress"
old_args=(-e "graylog_version=$old_version" -e "graylog_mongodb_version=$old_mongodb")
next_args=(-e "graylog_image=$test_repo/graylog" -e "graylog_datanode_image=$test_repo/graylog-datanode"
  -e "graylog_version=$next_version")

# The inputs of the update scenarios, their own: GELF over UDP bound to the
# test host (a container sends its message there) and syslog over UDP.
update_inputs_json() {
  printf '%s' '[{"name": "gelf-udp", "type": "gelf_udp", "port": 12201, "bind": ["'"$host_ip"'"]},
    {"name": "syslog-udp", "type": "syslog_udp", "port": 1514}]'
}
# role_converge and its variants with those inputs: up_converge <what> [-e ...].
up_converge() { role_converge "$1" -e "@$out/update-inputs.json" "${@:2}"; }
up_converge_unchanged() { role_converge_unchanged "$1" -e "@$out/update-inputs.json" "${@:2}"; }
up_converge_fails() { role_converge_fails -e "@$out/update-inputs.json" "$@"; }
up_verify() { verify -e "@$out/update-published.json" "$@"; }

# A message through the bound GELF input: send_gelf <text>.
send_gelf() {
  h docker run --rm --log-driver gelf --log-opt "gelf-address=udp://$host_ip:12201" --entrypoint echo "$probe_image" "$1" >/dev/null
}
# The featureCompatibilityVersion of MongoDB.
fcv() {
  compose "exec -T mongodb mongosh --quiet --eval 'db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1}).featureCompatibilityVersion.version'"
}
# The image, state and health of a service: service_line <service>.
service_line() { compose ps --all --format "'{{.Image}} {{.State}} {{.Health}}'" "$1"; }
# The complete backups (not partial, not -failed), oldest first.
complete_backups() { h sh -c "ls $backups 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z-[0-9.]+-to-[0-9.]+\$' || true"; }
# The newest backup of an update from <from> to <to>: newest_backup <from> <to>.
newest_backup() {
  local name
  name="$(complete_backups | grep -F -- "-$1-to-$2" | tail -n 1)"
  [ -n "$name" ] || fail "no backup of the update from $1 to $2 in $backups: $(h ls -A "$backups" 2>&1)"
  printf '%s\n' "$backups/$name"
}
# Fails when the marker of an update in progress or one of its copies is left.
expect_no_progress() {
  h sh -c "test ! -e $progress && test ! -e $progress.compose.yaml && test ! -e $progress.secrets" \
    || fail "an update left $progress or a copy of it ($1): $(h sh -c "ls -d $progress*")"
}

# A fresh installation of old_version with the update inputs and a message
# (old_message), whose GELF input's id is old_input: install_old <scenario>.
install_old() {
  echo "== install $old_version with MongoDB $old_mongodb for $1"
  write_inputs_vars update-inputs.json "$(update_inputs_json)" ''
  write_published update-published.json "$host_ip:12201:12201/udp"
  remove_installation
  up_converge "install $old_version for $1" "${old_args[@]}"
  up_verify -e "verify_version=$old_version" -e "verify_mongodb_version=$old_mongodb"
  old_input="$(expect_input gelf-udp 12201)"
  old_message="before-the-update-$(openssl rand -hex 6)"
  send_gelf "$old_message"
  expect_found "$old_message"
}
# Fails unless the message and the inputs of install_old are still there and
# a new message is found: expect_data_kept <what>.
expect_data_kept() {
  expect_found "$old_message"
  [ "$(expect_input gelf-udp 12201)" = "$old_input" ] || fail "the GELF input is not the one from before ($1)"
  expect_input syslog-udp 1514 >/dev/null
  local message
  message="after-$(openssl rand -hex 6)"
  send_gelf "$message"
  expect_found "$message"
}
# Fails unless <dir> holds the backup of an update from Graylog <from> with
# MongoDB <from mongodb>: root's 0700, compose.yaml (0600) and versions of
# that release, the secrets in use (0700, files 0600), inputs.json (0600), a
# dump that mongorestore --dryRun reads with the inputs' collection, and
# with <copy> 1 the Data Node's data, with 0 none:
# expect_backup <dir> <from> <from mongodb> <copy>.
expect_backup() {
  local dir="$1" from="$2" from_mongodb="$3" copy="$4"
  [ "$(h stat -c '%U %a' "$backups" "$dir" | sort -u)" = "root 700" ] || fail "$backups or $dir is not root's 0700"
  [ "$(h stat -c '%U %a' "$dir/compose.yaml")" = "root 600" ] || fail "$dir/compose.yaml is not root's 0600"
  h grep -qF "graylog:$from\"" "$dir/compose.yaml" || fail "$dir/compose.yaml is not the one of $from"
  [ "$(h sed -n 's/^graylog: *//p' "$dir/versions") $(h sed -n 's/^mongodb: *//p' "$dir/versions")" = "$from $from_mongodb" ] \
    || fail "$dir/versions does not name $from and $from_mongodb: $(h sed -n '/^[gm]/p' "$dir/versions" | grep -v sha256)"
  [ "$(h stat -c '%a' "$dir/secrets")" = 700 ] || fail "$dir/secrets is not 0700"
  [ "$(h sh -c "stat -c '%a' $dir/secrets/* $dir/versions $dir/inputs.json | sort -u")" = 600 ] \
    || fail "the secrets, the versions or inputs.json in $dir are not 0600"
  [ "$(h ls "$dir/secrets")" = "$(h ls "$secrets_dir")" ] || fail "$dir/secrets does not hold the secrets in use: $(h ls "$dir/secrets")"
  h sh -c "cd $app_dir && docker compose exec -T mongodb mongorestore --archive --gzip --dryRun --verbose <$dir/mongodb.archive" \
    >"$out/dryrun.log" 2>&1 || { cat "$out/dryrun.log" >&2; fail "mongorestore --dryRun cannot read $dir/mongodb.archive"; }
  grep -qF 'graylog.inputs' "$out/dryrun.log" || { cat "$out/dryrun.log" >&2; fail "the dump in $dir has no inputs"; }
  if [ "$copy" = 1 ]; then
    [ -n "$(h ls -A "$dir/datanode")" ] || fail "the backup $dir has no copy of the Data Node's data"
  else
    h test ! -e "$dir/datanode" || fail "the backup $dir has a copy of the Data Node's data"
  fi
}

test_update() {
  local backup next_backup
  echo "== update (ubuntu $1)"
  install_old update

  # Task 1's check of the version: MongoDB 9 is no release the role runs.
  note_untouched
  up_converge_fails "${old_args[@]}" -e graylog_mongodb_version=9.0.0
  expect_in_log "graylog_mongodb_version 9.0.0 is not a release the role runs"
  expect_untouched
  # The versions and the root password at once: a rollback would check the
  # restored Graylog with the new password.
  up_converge_fails -e "@$out/new-root-vars.json"
  expect_in_log "Change the versions or the root password, one per run"
  expect_untouched

  echo "== update: to $new_version with MongoDB $new_mongodb (ubuntu $1)"
  up_converge update
  grep -qF 'update.yml' "$out/converge.log" || fail "the new versions were not an update"
  up_verify
  expect_no_progress "after the update"
  h test ! -e "$failed_marker" || fail "the update left $failed_marker"
  backup="$(newest_backup "$old_version" "$new_version")"
  expect_backup "$backup" "$old_version" "$old_mongodb" 1
  [ "$(fcv)" = 8.0 ] || fail "featureCompatibilityVersion is $(fcv), not 8.0"
  expect_data_kept "after the update"
  expect_compose_clean
  up_converge_unchanged update
  # Without the state of the inputs (as after a rollback to a backup without
  # one) every input is updated once with the configuration it has: Graylog
  # restarts it, and the run waits for the restarted one.
  h rm "$app_dir/inputs.json"
  up_converge "the inputs without their state"
  [ "$(expect_input gelf-udp 12201)" = "$old_input" ] || fail "the GELF input was replaced without the state of the inputs"
  up_converge_unchanged "the inputs without their state"

  # Neither Graylog nor MongoDB migrates its data down.
  note_untouched
  up_converge_fails -e "graylog_version=$old_version"
  expect_in_log "graylog_version $old_version is lower than the installed version $new_version"
  expect_untouched
  up_converge_fails -e "graylog_mongodb_version=$old_mongodb"
  expect_in_log "graylog_mongodb_version $old_mongodb is lower than the installed version $new_mongodb"
  expect_untouched

  # The backup directory on a file system with 1 MiB free.
  echo "== update: no space for the backup (ubuntu $1)"
  h docker tag "docker.io/graylog/graylog:$new_version" "$test_repo/graylog:$next_version"
  h docker tag "docker.io/graylog/graylog-datanode:$new_version" "$test_repo/graylog-datanode:$next_version"
  h mount -t tmpfs -o size=1m tmpfs "$backups"
  note_untouched
  # Unmounted before any check can end the script.
  local refused=0
  play -e "@$out/role-vars.json" -e "@$out/update-inputs.json" "${next_args[@]}" || refused=1
  h umount "$backups"
  [ "$refused" = 1 ] || { cat "$out/converge.log" >&2; fail "the update without space for its backup succeeded"; }
  expect_in_log "MiB free"
  expect_in_log "graylog_update_backup_logs: false"
  expect_untouched

  echo "== update: to $next_version, one backup kept, no copy of the logs (ubuntu $1)"
  up_converge "second update" "${next_args[@]}" -e graylog_backups_keep=1 -e '{"graylog_update_backup_logs": false}'
  [ "$(service_line graylog)" = "$test_repo/graylog:$next_version running healthy" ] \
    || fail "the server after the second update: $(service_line graylog)"
  h test ! -e "$backup" || fail "the older backup $backup was not pruned"
  [ "$(complete_backups | wc -l | tr -d ' ')" = 1 ] || fail "graylog_backups_keep 1 kept more: $(complete_backups)"
  next_backup="$(newest_backup "$new_version" "$next_version")"
  expect_backup "$next_backup" "$new_version" "$new_mongodb" 0
  expect_data_kept "after the second update"
  up_converge_unchanged "second update" "${next_args[@]}" -e graylog_backups_keep=1 -e '{"graylog_update_backup_logs": false}'
  remove_installation
}

test_failed_update() {
  local backup
  echo "== failed_update (ubuntu $1)"
  install_old failed_update

  echo "== failed_update: a server image that exits (ubuntu $1)"
  h docker pull -q "$busybox" >/dev/null
  h docker tag "$busybox" "$test_repo/graylog:$new_version"
  up_converge_fails -e "graylog_image=$test_repo/graylog" -e graylog_health_timeout=60 -e graylog_rollback_timeout=600
  expect_in_log "update from $old_version to $new_version in $app_dir failed"
  expect_in_log "was rolled back: Graylog $old_version with MongoDB $old_mongodb runs again"
  [ "$(service_line graylog)" = "docker.io/graylog/graylog:$old_version running healthy" ] \
    || fail "the server after the rollback: $(service_line graylog)"
  [ "$(service_line mongodb)" = "docker.io/library/mongo:$old_mongodb running healthy" ] \
    || fail "MongoDB after the rollback: $(service_line mongodb)"
  h grep -qx "failed_version: $new_version" "$failed_marker" || fail "the marker does not name $new_version: $(h cat "$failed_marker")"
  h grep -qx "failed_mongodb_version: $new_mongodb" "$failed_marker" || fail "the marker does not name MongoDB $new_mongodb: $(h cat "$failed_marker")"
  h grep -qx "rolled_back_to: $old_version" "$failed_marker" || fail "the marker does not name $old_version: $(h cat "$failed_marker")"
  backup="$(h sed -n 's/^backup: //p' "$failed_marker")"
  expect_backup "$backup" "$old_version" "$old_mongodb" 1
  [ -n "$(h ls -A "$backup-failed/datanode")" ] || fail "the Data Node's data of the failed update was not set aside to $backup-failed"
  expect_in_log "$backup"
  expect_no_progress "after the rollback"
  up_verify -e "verify_version=$old_version" -e "verify_mongodb_version=$old_mongodb"
  [ "$(fcv)" = 7.0 ] || fail "featureCompatibilityVersion is $(fcv), not 7.0"
  expect_data_kept "after the rollback"
  expect_compose_clean
  h docker rmi "$test_repo/graylog:$new_version" >/dev/null

  echo "== failed_update: the failed versions refused (ubuntu $1)"
  note_untouched
  up_converge_fails
  expect_in_log "$failed_marker exists: the Graylog update to $new_version with MongoDB $new_mongodb failed"
  expect_in_log "rolled back to $old_version"
  expect_untouched
  # Another version (the installed one) succeeds and removes the marker.
  up_converge "another version" "${old_args[@]}"
  h test ! -e "$failed_marker" || fail "a successful run with $old_version kept the marker"
  up_converge_unchanged "another version" "${old_args[@]}"

  # An input that cannot start after the new versions are healthy (GELF over
  # TCP on the port of a TCP input without the prefix) fails the update too.
  echo "== failed_update: an input that fails after the update (ubuntu $1)"
  api /system/inputs -X POST -H 'Content-Type: application/json' \
    -d '{"title": "manual gelf", "type": "org.graylog2.inputs.gelf.tcp.GELFTCPInput", "global": true,
         "configuration": {"bind_address": "0.0.0.0", "port": 12299, "recv_buffer_size": 262144}}' >/dev/null
  write_inputs_vars clash-inputs.json "$(update_inputs_json | sed 's/}]$/}, {"name": "gelf-clash", "type": "gelf_tcp", "port": 12299}]/')" ''
  up_converge_fails -e "@$out/clash-inputs.json"
  expect_in_log "update from $old_version to $new_version in $app_dir failed"
  expect_in_log "gelf-clash (FAILED)"
  expect_in_log "was rolled back: Graylog $old_version with MongoDB $old_mongodb runs again"
  [ "$(service_line graylog)" = "docker.io/graylog/graylog:$old_version running healthy" ] \
    || fail "the server after the rollback of the failed input: $(service_line graylog)"
  h grep -qx "failed_version: $new_version" "$failed_marker" || fail "the marker does not name $new_version: $(h cat "$failed_marker")"
  expect_no_progress "after the rollback of the failed input"
  expect_no_input gelf-clash
  expect_data_kept "after the rollback of the failed input"
  remove_installation
}

# Waits until no Ansible module runs on the test host (one a killed converge
# left, which would still change things).
wait_modules() {
  local quiet=0
  for _ in $(seq 300); do
    if h pgrep -f '[A]nsiballZ_' >/dev/null; then quiet=0; else quiet=$((quiet + 1)); fi
    [ "$quiet" -lt 5 ] || return 0
    sleep 1
  done
  fail "an Ansible module still runs on the test host after 300 seconds"
}
# The role's converge at -v in the background, killed with its process group
# once <condition> holds on the test host; its output must hold no test
# secret: play_killed <condition> [-e ...].
play_killed() {
  local condition="$1" pid
  shift
  set -m
  ansible-playbook -v -i "$here/inventory.yml" -e "test_host=$host" "$here/converge.yml" \
    -e "@$out/role-vars.json" "$@" >"$out/converge.log" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 1800); do
    if h sh -c "$condition" >/dev/null 2>&1; then
      kill -9 -- "-$pid"
      { wait "$pid"; } 2>/dev/null || true
      expect_no_secrets "$out/converge.log" "the output of the killed converge"
      wait_modules
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      tail -n 40 "$out/converge.log" >&2
      fail "the converge ended before it was killed at: $condition"
    fi
    sleep 0.5
  done
  kill -9 -- "-$pid" 2>/dev/null || true
  wait "$pid" || true
  fail "the converge did not reach within the wait: $condition"
}
# Whether Graylog's database holds the collection noix_sentinel.
has_sentinel() {
  [ "$(compose "exec -T mongodb mongosh --quiet graylog --eval 'db.getCollectionNames().includes(\"noix_sentinel\")'")" = true ]
}

test_interrupted() {
  local backup failed_other
  echo "== interrupted: an install stopped before it completed (ubuntu $1)"
  remove_installation
  write_inputs_vars update-inputs.json "$(update_inputs_json)" ''
  play_killed "test -e $app_dir/install-incomplete && test -e $app_dir/compose.yaml" \
    -e "@$out/update-inputs.json" "${old_args[@]}"
  up_converge_fails "${old_args[@]}"
  expect_in_log "$app_dir/install-incomplete exists: an install of Graylog in $app_dir did not complete"
  h test -e "$app_dir/install-incomplete" || fail "the refused run removed $app_dir/install-incomplete"

  install_old interrupted

  # The variable without a marker, and a marker the role did not write.
  note_untouched
  up_converge_fails "${old_args[@]}" -e '{"graylog_restore_interrupted": true}'
  expect_in_log "graylog_restore_interrupted is set, but there is no interrupted update in $app_dir; remove the variable"
  expect_untouched
  h sh -c "echo 'not: [yaml' >$progress"
  up_converge_fails "${old_args[@]}"
  expect_in_log "$progress exists, but it is not YAML or lacks step or to_version"
  expect_untouched
  h rm "$progress"

  # Beside update-failed of the same backup (a rescue stopped after it wrote
  # update-failed): the marker of the update in progress goes, update-failed
  # refuses.
  h sh -c "printf 'from_version: $old_version\nfrom_mongodb_version: $old_mongodb\nto_version: $new_version\nto_mongodb_version: $new_mongodb\nstep: update\nbackup: $backups/20260101T000000Z-$old_version-to-$new_version\ntime: \"2026-01-01T00:00:00Z\"\n' >$progress"
  h sh -c "printf 'failed_version: $new_version\nfailed_mongodb_version: $new_mongodb\nrolled_back_to: $old_version\nrolled_back_to_mongodb: $old_mongodb\nbackup: $backups/20260101T000000Z-$old_version-to-$new_version\ntime: \"2026-01-01T00:00:00Z\"\n' >$failed_marker"
  up_converge_fails
  expect_in_log "$failed_marker exists: the Graylog update to $new_version with MongoDB $new_mongodb failed"
  expect_no_progress "beside update-failed of the same backup"
  h test -e "$failed_marker" || fail "the run removed $failed_marker"
  h rm "$failed_marker"

  echo "== interrupted: stopped during its backup (ubuntu $1)"
  play_killed "ls -d $backups/*.partial" -e "@$out/update-inputs.json"
  h grep -qx 'step: backup' "$progress" || fail "the marker does not record the step backup: $(h cat "$progress")"
  # The variable is refused: nothing had changed to restore.
  note_untouched
  up_converge_fails -e '{"graylog_restore_interrupted": true}'
  expect_in_log "records an update that stopped during its backup, before anything changed"
  expect_untouched
  h sh -c "ls -d $backups/*.partial" >/dev/null || fail "the refused run removed the partial backup"
  # The next run removes the partial backup and the marker and updates.
  up_converge "the update after the stopped backup"
  [ "$(service_line graylog)" = "docker.io/graylog/graylog:$new_version running healthy" ] \
    || fail "the server after the update: $(service_line graylog)"
  [ -z "$(h sh -c "ls -d $backups/*.partial 2>/dev/null || true")" ] || fail "the partial backup is left: $(h ls -A "$backups")"
  newest_backup "$old_version" "$new_version" >/dev/null
  expect_no_progress "after the update that followed the stopped backup"
  expect_data_kept "after the update that followed the stopped backup"
  up_converge_unchanged "the update after the stopped backup"

  echo "== interrupted: stopped once the compose file names the new version (ubuntu $1)"
  h docker tag "docker.io/graylog/graylog:$new_version" "$test_repo/graylog:$next_version"
  h docker tag "docker.io/graylog/graylog-datanode:$new_version" "$test_repo/graylog-datanode:$next_version"
  play_killed "grep -qF 'graylog:$next_version\"' $app_dir/compose.yaml" -e "@$out/update-inputs.json" "${next_args[@]}"
  h grep -qx 'step: update' "$progress" || fail "the marker does not record the step update: $(h cat "$progress")"
  h grep -qx "from_version: $new_version" "$progress" || fail "the marker does not name $new_version: $(h cat "$progress")"
  h grep -qx "to_version: $next_version" "$progress" || fail "the marker does not name $next_version: $(h cat "$progress")"
  backup="$(h sed -n 's/^backup: //p' "$progress")"
  h grep -qF "graylog:$new_version\"" "$backup/compose.yaml" || fail "the backup $backup is not the one of $new_version"
  for file in "$progress" "$progress.compose.yaml" "$progress.secrets"; do
    [ "$(h stat -c '%a %U' "$file")" = "$([ "$file" = "$progress.secrets" ] && echo 700 || echo 600) root" ] \
      || fail "$file is not root's only: $(h stat -c '%a %U' "$file")"
  done
  # A change after the backup, which the restore must undo.
  compose "exec -T mongodb mongosh --quiet graylog --eval 'db.noix_sentinel.insertOne({})'" >/dev/null
  has_sentinel || fail "the collection noix_sentinel was not created"
  note_untouched
  up_converge_fails "${next_args[@]}"
  expect_in_log "$progress exists: the Graylog update from $new_version with MongoDB $new_mongodb to $next_version with MongoDB $new_mongodb did not finish"
  expect_in_log "the backup from before it is $backup"
  expect_in_log "set graylog_restore_interrupted: true for one run to restore it"
  expect_in_log "or remove $progress with its copies"
  expect_untouched

  # Restored with the variable: the previous versions with their data, and
  # no update. update-failed of an earlier update to another version, rolled
  # back, stays: the restore ran no version but the one it had.
  failed_other="$(printf 'failed_version: 7.2.9\nfailed_mongodb_version: %s\nrolled_back_to: %s\nrolled_back_to_mongodb: %s\nbackup: %s\ntime: "2026-01-01T00:00:00Z"' \
    "$new_mongodb" "$new_version" "$new_mongodb" "$backups/20260101T000000Z-$new_version-to-7.2.9")"
  printf '%s\n' "$failed_other" | docker exec -i "$host" sh -c "cat >$failed_marker"
  up_converge "the restore of the interrupted update" "${next_args[@]}" -e '{"graylog_restore_interrupted": true}'
  expect_in_log "Graylog in $app_dir runs $new_version with MongoDB $new_mongodb again"
  if grep -qF 'Stop the server and the Data Node for the update' "$out/converge.log"; then fail "the restore tried the update again"; fi
  [ "$(service_line graylog)" = "docker.io/graylog/graylog:$new_version running healthy" ] \
    || fail "the server after the restore: $(service_line graylog)"
  expect_no_progress "after the restore"
  [ "$(h cat "$failed_marker" 2>&1)" = "$failed_other" ] || fail "the restore did not keep $failed_marker of 7.2.9 as it was: $(h cat "$failed_marker" 2>&1)"
  h rm "$failed_marker"
  ! has_sentinel || fail "the restore kept the database changed after the backup"
  h test -d "$backup-failed/datanode" || fail "the restore did not set the Data Node's data it found aside to $backup-failed"
  expect_compose_clean
  expect_data_kept "after the restore"
  # The variable is refused once the update is restored.
  note_untouched
  up_converge_fails "${next_args[@]}" -e '{"graylog_restore_interrupted": true}'
  expect_in_log "graylog_restore_interrupted is set, but there is no interrupted update"
  expect_untouched

  # Without the variable the next run updates.
  up_converge "the update after the restore" "${next_args[@]}"
  [ "$(service_line graylog)" = "$test_repo/graylog:$next_version running healthy" ] \
    || fail "the server after the update that followed the restore: $(service_line graylog)"
  expect_no_progress "after the update that followed the restore"
  expect_data_kept "after the update that followed the restore"
  up_converge_unchanged "the update after the restore" "${next_args[@]}"
  remove_installation
}

# The command lines of every process of the test host (the containers' among
# them), sampled until stop_processes: sample_processes.
sample_processes() {
  h rm -f /tmp/processes.log /tmp/processes.stop
  docker exec -d "$host" sh -c 'until [ -e /tmp/processes.stop ]; do ps -eo args >>/tmp/processes.log; done'
}
# Stops the sampling and fails when a sampled command line holds a test
# secret or its SHA-256, or <command> was never seen: stop_processes
# <command...>.
stop_processes() {
  local command
  h touch /tmp/processes.stop
  sleep 1
  h cat /tmp/processes.log >"$out/processes.log"
  expect_no_secrets "$out/processes.log" "a command line on the test host"
  for command in "$@"; do
    grep -qF -- "$command" "$out/processes.log" || fail "the sampling never saw $command"
  done
}

test_secrets() {
  echo "== secrets (ubuntu $1)"
  install_old secrets
  echo "== secrets: a failed update, rolled back (ubuntu $1)"
  h docker pull -q "$busybox" >/dev/null
  h docker tag "$busybox" "$test_repo/graylog:$new_version"
  sample_processes
  up_converge_fails -e "graylog_image=$test_repo/graylog" -e graylog_health_timeout=60 -e graylog_rollback_timeout=600
  stop_processes mongodump mongorestore
  expect_in_log "was rolled back: Graylog $old_version with MongoDB $old_mongodb runs again"
  h docker rmi "$test_repo/graylog:$new_version" >/dev/null
  h rm "$failed_marker"
  echo "== secrets: an update (ubuntu $1)"
  sample_processes
  up_converge "the update with the processes sampled"
  stop_processes mongodump
  remove_installation
}

# The forward scenarios: a second test host (sender, the same image, without
# rsyslog) on the test host's Docker network forwards with the
# syslog_forward role to Graylog's inputs on the test host: syslog over UDP
# on 1514 and over TCP on 1515, bound to the test host's address, and syslog
# over TCP with TLS through Traefik's logs-tls (bound to that address too, in
# forward-traefik.json) with a certificate for syslog.test from a test CA.
sender=
# s <cmd...>: run in the sender host.
s() { docker exec "$sender" "$@"; }
dropin=/etc/rsyslog.d/60-noixdev-forward.conf
test_ca=/etc/ssl/noixdev-test-ca.pem

# The inputs of the forward scenarios, their own.
forward_inputs_json() {
  printf '%s' '[{"name": "gelf-udp", "type": "gelf_udp", "port": 12201, "bind": ["'"$host_ip"'"]},
    {"name": "syslog-udp", "type": "syslog_udp", "port": 1514, "bind": ["'"$host_ip"'"]},
    {"name": "syslog-tcp", "type": "syslog_tcp", "port": 1515, "bind": ["'"$host_ip"'"]},
    {"name": "syslog-tls", "type": "syslog_tcp", "port": 1517,
     "traefik": {"hostname": "syslog.test", "entrypoints": ["logs-tls"]}}]'
}
# vars.yml's entrypoints with logs-tls also on the test host's address, for
# the sender.
write_forward_traefik() {
  python3 -I -c '
import json, sys
print(json.dumps({"traefik_entrypoints": [
    {"name": "web", "port": 80, "bind": ["127.0.0.1"]},
    {"name": "websecure", "port": 443, "bind": ["127.0.0.1"], "tls": True, "as_default": True},
    {"name": "logs-tls", "port": 6514, "protocol": "tcp", "bind": ["127.0.0.1", sys.argv[1]]},
    {"name": "logs-any", "port": 6515, "protocol": "tcp", "bind": ["127.0.0.1"]}]}))' "$host_ip" >"$out/forward-traefik.json"
}
# The Graylog test host with the forward inputs: fw_converge <what> [-e ...].
fw_converge() { role_converge "$1" -e "@$out/forward-inputs.json" -e "@$out/forward-traefik.json" "${@:2}"; }

# A test CA and a certificate for syslog.test it signs, made on the test
# host; Traefik serves the certificate from a dynamic file (the traefik role
# leaves files it does not write), the sender trusts the CA.
install_test_certificate() {
  h sh -c 'set -e; d=$(mktemp -d); cd $d
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=noixdev test CA" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout tls.key -out tls.csr -subj "/CN=syslog.test" 2>/dev/null
    printf "subjectAltName=DNS:syslog.test\n" >ext.cnf
    openssl x509 -req -in tls.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out tls.pem -days 2 -extfile ext.cnf 2>/dev/null
    { echo "tls:"; echo "  certificates:"; echo "    - certFile: |"; sed "s/^/        /" tls.pem
      echo "      keyFile: |"; sed "s/^/        /" tls.key; } >/opt/traefik/dynamic/noixdev-test-tls.yml
    cp ca.pem /tmp/noixdev-test-ca.pem; rm -rf $d'
  h cat /tmp/noixdev-test-ca.pem | docker exec -i "$sender" sh -c "mkdir -p ${test_ca%/*} && cat >$test_ca && chmod 0644 $test_ca"
}

start_sender() {
  local ubuntu="$1"
  sender="noixdev-graylog-sender-$ubuntu"
  docker rm -f -v "$sender" >/dev/null 2>&1 || true
  noix_cache_run=() && noix_cache_array noix_cache_run noix_cache_run_args
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd \
    --name "$sender" ${noix_cache_run[@]+"${noix_cache_run[@]}"} "noixdev-infra-host:$ubuntu" >/dev/null
  noix_cache_host_setup "$sender"
  until (s systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
  s rm -f /usr/sbin/policy-rc.d
  s sh -c "echo '$host_ip graylog.test syslog.test' >>/etc/hosts"
  ! s sh -c 'command -v rsyslogd' >/dev/null || fail "the sender image has rsyslog already"
}
# The sender's playbook at -v: sender_play [-e ...]; its output goes to
# converge.log.
sender_play() {
  local noix_cache_play=() && noix_cache_array noix_cache_play noix_cache_play_args
  ansible-playbook -v -i "$here/sender.yml" -e "sender_host=$sender" ${noix_cache_play[@]+"${noix_cache_play[@]}"} "$here/forward.yml" "$@" >"$out/converge.log" 2>&1
}
sender_converge() {
  sender_play "$@" || { cat "$out/converge.log" >&2; fail "the sender's converge failed"; }
}
sender_converge_unchanged() {
  sender_converge "$@"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/converge.log" \
    || { cat "$out/converge.log" >&2; fail "the repeated sender converge changed something"; }
}
sender_converge_fails() {
  if sender_play "$@"; then cat "$out/converge.log" >&2; fail "the sender's converge succeeded, but must fail"; fi
}
# A sender converge refused before any change: sender_refused [-e ...].
sender_refused() {
  sender_converge_fails "$@"
  grep -Eq 'changed=0 +unreachable=0 +failed=1' "$out/converge.log" \
    || { cat "$out/converge.log" >&2; fail "a refused sender converge changed something"; }
}
# The sender's targets: the three inputs, by the names in its /etc/hosts.
write_forward_targets() {
  python3 -I -c '
import json, sys
print(json.dumps({"syslog_forward_targets": [
    {"host": "graylog.test", "port": 1514, "protocol": "udp"},
    {"host": "graylog.test", "port": 1515},
    {"host": "syslog.test", "port": 6514, "tls": True, "ca_file": sys.argv[1]}]}))' "$test_ca" >"$out/forward-targets.json"
}
# The inputs that stored a message with <text>, by title (the search API
# names gl2_source_input so), sorted and unique, one per line:
# source_inputs <text>.
source_inputs() {
  api "/search/messages?query=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote("\"%s\"" % sys.argv[1]))' "$1")&fields=gl2_source_input,message&timerange=7200s&size=500" \
    | py '"\n".join(sorted({row[0] for row in d["datarows"]}))' | LC_ALL=C sort -u
}
# Waits up to 90 seconds until messages with <text> came through every input
# named: expect_through <text> <input name...>.
expect_through() {
  local text="$1" name wanted found
  shift
  wanted="$(for name in "$@"; do expect_input "$name" "$(input_port "$name")" >/dev/null; echo "ansible: $name"; done | LC_ALL=C sort -u)"
  for _ in $(seq 45); do
    found="$(source_inputs "$text")"
    [ "$found" = "$wanted" ] && return 0
    sleep 2
  done
  fail "the message $text came through the inputs $(printf '%s' "$found" | tr '\n' ' '), not those of $*"
}
input_port() { case "$1" in syslog-udp) echo 1514 ;; syslog-tcp) echo 1515 ;; syslog-tls) echo 1517 ;; *) echo 12201 ;; esac; }

# The sender with the forward inputs: Graylog installed (and converged with
# them), the sender started; ensure_forward <scenario>.
ensure_forward() {
  ensure_installed "$1"
  write_inputs_vars forward-inputs.json "$(forward_inputs_json)" ''
  write_forward_traefik
  fw_converge "the forward inputs for $1"
  if [ -z "$sender" ] || ! s true 2>/dev/null; then
    start_sender "$2"
    install_test_certificate
  fi
  write_forward_targets
}

test_forward() {
  local marker
  echo "== forward (ubuntu $1)"
  ensure_forward forward "$1"
  # Refused before any change: nothing changed, no package installed, the
  # drop-in as it was. An earlier scenario on this sender may have left both.
  local had_rsyslog=no dropin_before
  s sh -c 'command -v rsyslogd' >/dev/null && had_rsyslog=yes
  dropin_before="$(s sh -c "sha256sum $dropin 2>/dev/null || echo none")"
  sender_refused -e '{"syslog_forward_targets": [{"host": "graylog.test", "protocol": "sctp"}]}'
  expect_in_log "value of protocol must be one of: udp, tcp"
  sender_refused -e '{"syslog_forward_targets": [{"host": "graylog.test", "protocol": "udp", "tls": true}]}'
  expect_in_log "Target number 1 of syslog_forward_targets is not valid"
  sender_refused -e '{"syslog_forward_targets": [{"port": 1514}]}'
  expect_in_log "missing required arguments: host"
  sender_refused -e '{"syslog_forward_targets": [{"host": "graylog.test", "protocol": "udp", "queue_size": 5}]}'
  expect_in_log "Target number 1 of syslog_forward_targets is not valid"
  sender_refused -e '{"syslog_forward_targets": [{"host": "graylog.test", "protocol": "udp", "queue_max_disk": "1g"}]}'
  expect_in_log "Target number 1 of syslog_forward_targets is not valid"
  sender_refused -e '{"syslog_forward_targets": [{"host": "graylog.test", "queue_max_disk": "lots"}]}'
  expect_in_log "Target number 1 of syslog_forward_targets is not valid"
  sender_refused -e '{"syslog_forward_targets": [{"host": "syslog.test", "tls": true, "ca_file": "/etc/ssl/none.pem"}]}'
  expect_in_log "/etc/ssl/none.pem of syslog_forward_targets do not exist on the host"
  [ "$had_rsyslog" = yes ] || ! s sh -c 'command -v rsyslogd' >/dev/null || fail "a refused run installed rsyslog"
  [ "$(s sh -c "sha256sum $dropin 2>/dev/null || echo none")" = "$dropin_before" ] || fail "a refused run changed $dropin"

  echo "== forward: to UDP, TCP and TCP with TLS (ubuntu $1)"
  sender_converge -e "@$out/forward-targets.json"
  # A disk limit of its own for one target.
  sender_converge -e '{"syslog_forward_targets": [{"host": "graylog.test", "port": 1515, "queue_max_disk": "64m"}]}'
  s grep -qF 'queue.maxDiskSpace="64m"' "$dropin" || { s cat "$dropin" >&2; fail "queue_max_disk 64m is not the target's disk limit"; }
  sender_converge -e "@$out/forward-targets.json"
  [ "$(s systemctl is-active rsyslog)" = active ] || fail "rsyslog does not run on the sender"
  s dpkg -s rsyslog-gnutls >/dev/null 2>&1 || fail "rsyslog-gnutls is not installed for the TLS target"
  marker="forward-$(openssl rand -hex 6)"
  s logger -t noixdev-test "$marker"
  expect_through "$marker" syslog-udp syslog-tcp syslog-tls
  sender_converge_unchanged -e "@$out/forward-targets.json"

  echo "== forward: only auth.* (ubuntu $1)"
  sender_converge -e "@$out/forward-targets.json" -e 'syslog_forward_filter=auth.*'
  local user_line auth_line since
  user_line="forward-user-$(openssl rand -hex 6)"
  auth_line="forward-auth-$(openssl rand -hex 6)"
  s logger -p user.info -t noixdev-test "$user_line"
  s logger -p auth.info -t noixdev-test "$auth_line"
  since="$(date +%s)"
  expect_through "$auth_line" syslog-udp syslog-tcp syslog-tls
  sleep "$((20 - ($(date +%s) - since) > 0 ? 20 - ($(date +%s) - since) : 0))"
  [ -z "$(source_inputs "$user_line")" ] || fail "the user.info line was forwarded with the filter auth.*"
  sender_converge -e "@$out/forward-targets.json"
}

# The Graylog server stopped: the TCP target's queue on disk keeps what
# rsyslog cannot send, and sends it once the server is back.
test_forward_queue() {
  local tag i count
  echo "== forward_queue (ubuntu $1)"
  ensure_forward forward_queue "$1"
  sender_converge -e "@$out/forward-targets.json"
  expect_input syslog-tcp 1515 >/dev/null
  # Each TCP target's queue is bounded on disk too (512m by default).
  [ "$(s grep -c 'queue.maxDiskSpace="512m"' "$dropin")" = 2 ] \
    || { s cat "$dropin" >&2; fail "the TCP targets' queues have no disk limit of 512m"; }
  tag="forward-queue-$(openssl rand -hex 6)"
  compose stop graylog >/dev/null 2>&1
  # rsyslog finds a closed connection only on a send, which plain TCP can
  # lose: one line first that the test does not count.
  s logger -t noixdev-test "forward-queue-warm-up"
  sleep 5
  for i in $(seq 50); do s logger -t noixdev-test "$tag-$i"; done
  sleep 10
  compose start graylog >/dev/null 2>&1
  wait_healthy
  for _ in $(seq 60); do
    count="$(api "/search/messages?query=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote("\"%s\"" % sys.argv[1]))' "$tag")&fields=gl2_source_input,message&timerange=7200s&size=500" \
      | py 'len({row[1] for row in d["datarows"] if row[0] == "ansible: syslog-tcp"})')"
    [ "$count" = 50 ] && return 0
    sleep 3
  done
  fail "$count of the 50 lines sent while the server was stopped came through the TCP target"
}

# A setting rsyslog refuses (an unknown facility): the run fails with its
# error, the previous drop-in is back, and rsyslog runs on.
test_forward_invalid() {
  local before
  echo "== forward_invalid (ubuntu $1)"
  ensure_forward forward_invalid "$1"
  sender_converge -e "@$out/forward-targets.json"
  before="$(s sha256sum "$dropin")"
  sender_converge_fails -e "@$out/forward-targets.json" -e 'syslog_forward_filter=nonsense.info'
  expect_in_log 'unknown facility name "nonsense"'
  expect_in_log "The previous drop-in is back in place"
  [ "$(s sha256sum "$dropin")" = "$before" ] || fail "the refused drop-in was left in place"
  [ "$(s systemctl is-active rsyslog)" = active ] || fail "rsyslog does not run after the refused drop-in"

  # A play that fails after the role (a later role): rsyslog runs on the
  # new drop-in all the same.
  sender_converge_fails -e "@$out/forward-targets.json" -e 'syslog_forward_filter=*.info' -e sender_fail_after=true
  expect_in_log "The task after the role failed"
  s grep -qF '*.info action(' "$dropin" || fail "the play that failed after the role did not write the drop-in"
  local started written
  started="$(s date -d "$(s systemctl show rsyslog -p ActiveEnterTimestamp --value)" +%s)"
  written="$(s stat -c %Y "$dropin")"
  [ "$started" -ge "$written" ] \
    || fail "rsyslog was not restarted for the drop-in of a play that failed after the role (started $started, written $written)"
}

# No targets: the drop-in goes, and rsyslog restarts without it.
test_forward_remove() {
  local started
  echo "== forward_remove (ubuntu $1)"
  ensure_forward forward_remove "$1"
  sender_converge -e "@$out/forward-targets.json"
  started="$(s systemctl show -p ActiveEnterTimestampMonotonic --value rsyslog)"
  sender_converge -e '{"syslog_forward_targets": []}'
  s test ! -e "$dropin" || fail "$dropin is left without targets"
  [ "$(s systemctl is-active rsyslog)" = active ] || fail "rsyslog does not run after the drop-in was removed"
  [ "$(s systemctl show -p ActiveEnterTimestampMonotonic --value rsyslog)" != "$started" ] || fail "rsyslog was not restarted"
  sender_converge_unchanged -e '{"syslog_forward_targets": []}'
}

# The GELF log driver while Graylog is down: a container with an address
# starts (UDP needs no receiver), one with a name that does not resolve does
# not (the docs warn of it).
test_forward_down() {
  echo "== forward_down (ubuntu $1)"
  ensure_forward forward_down "$1"
  sender_converge -e '{"syslog_forward_targets": []}' -e sender_docker=true
  s docker pull -q "$busybox" >/dev/null
  compose stop >/dev/null 2>&1
  s docker run --rm --log-driver gelf --log-opt "gelf-address=udp://$host_ip:12201" --entrypoint echo "$busybox" up >/dev/null \
    || fail "a container logging to GELF over UDP on an address did not start while Graylog was down"
  if s docker run --rm --log-driver gelf --log-opt gelf-address=udp://nowhere.invalid:12201 --entrypoint echo "$busybox" up \
    >"$out/gelf-unresolved.log" 2>&1; then
    fail "a container logging to GELF on a name that does not resolve started"
  fi
  compose start >/dev/null 2>&1
  wait_healthy
}

# All scenarios by default; NOIXDEV_INFRA_GRAYLOG_TESTS="refusals" runs only
# these. A new scenario is a test_<name> function and one line in the case
# below.
# update, failed_update, interrupted and secrets install the previous release
# afresh and remove their installation at the end.
all_scenarios="refusals install self_logging missing_data mountpoint noop_down reconfigure secret_changed inputs reconcile
  update failed_update interrupted secrets forward forward_queue forward_invalid forward_remove forward_down"
scenarios="${NOIXDEV_INFRA_GRAYLOG_TESTS:-$all_scenarios}"
for ubuntu in $releases; do
  out="$tests/output/graylog-$ubuntu"
  mkdir -p "$out"
  start_host "$ubuntu"
  for scenario in $scenarios; do
    case "$scenario" in
      refusals) test_refusals "$ubuntu" ;;
      install) test_install "$ubuntu" ;;
      self_logging) test_self_logging "$ubuntu" ;;
      missing_data) test_missing_data "$ubuntu" ;;
      mountpoint) test_mountpoint "$ubuntu" ;;
      noop_down) test_noop_down "$ubuntu" ;;
      reconfigure) test_reconfigure "$ubuntu" ;;
      secret_changed) test_secret_changed "$ubuntu" ;;
      inputs) test_inputs "$ubuntu" ;;
      reconcile) test_reconcile "$ubuntu" ;;
      update) test_update "$ubuntu" ;;
      failed_update) test_failed_update "$ubuntu" ;;
      interrupted) test_interrupted "$ubuntu" ;;
      secrets) test_secrets "$ubuntu" ;;
      forward) test_forward "$ubuntu" ;;
      forward_queue) test_forward_queue "$ubuntu" ;;
      forward_invalid) test_forward_invalid "$ubuntu" ;;
      forward_remove) test_forward_remove "$ubuntu" ;;
      forward_down) test_forward_down "$ubuntu" ;;
      *) fail "unknown scenario $scenario ($all_scenarios)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all graylog tests passed"
