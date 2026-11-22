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
#             environment; then back to the first ones
#   secret_changed
#             another graylog_password_secret on the installation refused
#             before any change
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
# No converge's output may hold one of these.
secrets=("$root_password" "$password_secret" "$short_secret" "$new_root_password" "$other_secret")

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
  h sh -c 'echo "127.0.0.1 graylog.test" >>/etc/hosts'

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

# All scenarios by default; NOIXDEV_INFRA_GRAYLOG_TESTS="refusals" runs only
# these. A new scenario is a test_<name> function and one line in the case
# below.
all_scenarios="refusals install self_logging missing_data mountpoint noop_down reconfigure secret_changed"
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
      *) fail "unknown scenario $scenario ($all_scenarios)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all graylog tests passed"
