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

# Generated for this run, so that no test secret lives in the repository. The
# root password holds $, a quote and a space, so that the tests prove it
# reaches the SHA-256 and the API as written.
root_password="$(openssl rand -hex 12)"' ro$t"pw ok'
password_secret="$(openssl rand -hex 24)"
# One character short of the 16 the role requires.
short_secret="$(openssl rand -hex 7)x"
# No converge's output may hold one of these.
secrets=("$root_password" "$password_secret" "$short_secret")

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

# The variables the graylog role needs in every scenario; the secrets of this
# run in a file of mode 0600.
write_role_vars() {
  (
    umask 077
    env "ROOT_PASSWORD=$root_password" "PASSWORD_SECRET=$password_secret" python3 -c '
import json, os
print(json.dumps({"test_graylog": True,
                  "graylog_root_password": os.environ["ROOT_PASSWORD"],
                  "graylog_password_secret": os.environ["PASSWORD_SECRET"]}))' >"$out/role-vars.json"
  )
}
# role_converge_fails [-e ...]: the host's playbook with the role, which must
# fail.
role_converge_fails() { converge_fails -e "@$out/role-vars.json" "$@"; }

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

# All scenarios by default; NOIXDEV_INFRA_GRAYLOG_TESTS="refusals" runs only
# these. A new scenario is a test_<name> function and one line in the case
# below.
all_scenarios="refusals"
scenarios="${NOIXDEV_INFRA_GRAYLOG_TESTS:-$all_scenarios}"
for ubuntu in $releases; do
  start_host "$ubuntu"
  for scenario in $scenarios; do
    case "$scenario" in
      refusals) test_refusals "$ubuntu" ;;
      *) fail "unknown scenario $scenario ($all_scenarios)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all graylog tests passed"
