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
#             a null one, options with a list; bad graylog_env keys and a
#             null value)
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
#             message over TLS with SNI found; the default index set rotated
#             daily and deleting after 30 indices
#   reconcile the gelf_tcp input moved to 12203 (the same input, RUNNING on
#             the new port), the syslog_tcp entry removed (the input
#             deleted), the syslog_udp input on 514 (published from 10514 in
#             the container), a new token (the old one refused), a retention
#             of 7 days; an input made through the API without the prefix
#             survives two runs; then back to the default inputs
# Every converge runs at least at -v, and its output must not hold a test
# secret; every successful converge of a scenario is repeated and must change
# nothing.
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

cleanup() {
  [ "${KEEP:-0}" = 1 ] || [ -z "$host" ] || docker rm -f -v "$host" >/dev/null 2>&1 || true
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
  ansible-playbook -v -i "$here/inventory.yml" -e "test_host=$host" "$here/converge.yml" "$@" >"$out/converge.log" 2>&1 || rc=$?
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
# token behind the HTTPS entrypoint, syslog over TCP behind logs-tls.
# inputs_json [gelf_tcp port] [with syslog_tcp: 1 or 0] [syslog_udp port].
inputs_json() {
  local gelf_tcp_port="${1:-12201}" with_syslog_tcp="${2:-1}" syslog_udp_port="${3:-1514}" syslog_tcp=
  [ "$with_syslog_tcp" = 0 ] \
    || syslog_tcp=', {"name": "syslog-tcp", "type": "syslog_tcp", "port": 1515, "traefik": {"hostname": "syslog.test", "entrypoints": ["logs-tls"]}}'
  printf '%s' '[{"name": "gelf-udp", "type": "gelf_udp", "port": 12201, "bind": ["'"$host_ip"'"]},
    {"name": "syslog-udp", "type": "syslog_udp", "port": '"$syslog_udp_port"', "bind": ["'"$host_ip"'"]},
    {"name": "gelf-tcp", "type": "gelf_tcp", "port": '"$gelf_tcp_port"', "bind": ["'"$host_ip"'"]},
    {"name": "gelf-http", "type": "gelf_http", "port": 12202, "token": "TOKEN",
     "traefik": {"hostname": "gelf.test", "entrypoints": ["websecure"]}}'"$syslog_tcp"']'
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

# The messages of the last 10 minutes that hold <text>, one per line, as
# "<container_name>|<message>": search <text>.
search() {
  api "/search/messages?query=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote("\"%s\"" % sys.argv[1]))' "$1")&fields=container_name,message&timerange=600s" \
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

# A syslog message over TLS through Traefik's logs-tls entrypoint, with SNI
# syslog.test: syslog_tls <text>.
syslog_tls() {
  h sh -c "printf '<14>1 %s syslog-probe probe - - - %s\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" '$1' \
    | timeout 10 openssl s_client -quiet -no_ign_eof -connect 127.0.0.1:6514 -servername syslog.test >/dev/null 2>&1" || true
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
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd \
    --name "$host" "noixdev-infra-host:$ubuntu" >/dev/null
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
  refused 'is a UDP input and has a traefik block' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_udp", "port": 12201, "traefik": {"hostname": "a.test", "entrypoints": ["websecure"]}}]}'
  refused 'only gelf_http inputs take a token' \
    -e '{"graylog_inputs": [{"name": "a", "type": "syslog_tcp", "port": 1514, "token": "x"}]}'
  refused 'only gelf_http inputs take a token' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_http", "port": 12202, "token": null}]}'
  refused 'traefik takes hostname and entrypoints' \
    -e '{"graylog_inputs": [{"name": "a", "type": "gelf_http", "port": 12202, "traefik": {"hostname": "a.test"}}]}'
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
  since="$(date +%s)"
  expect_gelf_http_refused "$wrong" -H "Authorization: Bearer not-the-$gelf_token"
  expect_gelf_http_refused "$missing"
  expect_found "$accepted"
  sleep "$((30 - ($(date +%s) - since) > 0 ? 30 - ($(date +%s) - since) : 0))"
  expect_not_found "$wrong"
  expect_not_found "$missing"

  # Syslog over TLS through Traefik's TCP router, sent until it is routed.
  marker="syslog-tls-$(openssl rand -hex 6)"
  local found
  for _ in $(seq 15); do
    syslog_tls "$marker"
    sleep 4
    found="$(search "$marker")"
    [ -z "$found" ] || break
  done
  expect_found "$marker"

  expect_retention 30
  role_converge_unchanged inputs -e "@$out/inputs-vars.json"
}

test_reconcile() {
  echo "== reconcile (ubuntu $1)"
  ensure_installed reconcile
  write_inputs_vars inputs-vars.json "$(inputs_json)" "$gelf_token"
  role_converge "reconcile, the inputs" -e "@$out/inputs-vars.json"
  local gelf_tcp_id manual_id
  gelf_tcp_id="$(expect_input gelf-tcp 12201)"
  expect_input syslog-tcp 1515 >/dev/null
  # An input of someone else: no prefix.
  api /system/inputs -X POST -H 'Content-Type: application/json' \
    -d '{"title": "manual gelf", "type": "org.graylog2.inputs.gelf.udp.GELFUDPInput", "global": true,
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

  # Back to the default inputs and retention.
  api "/system/inputs/$manual_id" -X DELETE >/dev/null
  role_converge "reconcile back"
  expect_no_input gelf-tcp
  expect_no_input gelf-http
  expect_input gelf-udp 12201 >/dev/null
  expect_input syslog-udp 1514 >/dev/null
  expect_retention 30
  verify
}

# All scenarios by default; NOIXDEV_INFRA_GRAYLOG_TESTS="refusals" runs only
# these. A new scenario is a test_<name> function and one line in the case
# below.
all_scenarios="refusals install self_logging missing_data mountpoint noop_down reconfigure secret_changed inputs reconcile"
scenarios="${NOIXDEV_INFRA_GRAYLOG_TESTS:-$all_scenarios}"
for ubuntu in $releases; do
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
      *) fail "unknown scenario $scenario ($all_scenarios)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all graylog tests passed"
