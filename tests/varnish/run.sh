#!/usr/bin/env bash
# End-to-end test of the varnish role on a throwaway systemd host per Ubuntu
# release (the same host image as the host suite).
#
# The scenario "invalid" runs the role with settings it must refuse (a bad or
# repeated site name, token, profile, microcache, health probe, cache size and
# an unsupported release) and checks that each run stops before any change,
# with a message that names the field and the site.
#
# The scenario "valid" runs it with settings it must accept.
#
# VARNISH_UBUNTU selects the releases (default "24.04 26.04"); a scenario name
# as an argument selects scenarios (the default is all of them); KEEP=1 leaves
# the test hosts running. Probes run inside the test host; no port is
# published on this machine.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
out="$tests/output/varnish"
releases="${VARNISH_UBUNTU:-24.04 26.04}"
host=

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

# play <playbook> [-e ...]: a playbook of this suite on the test host; its
# output goes to <playbook>.log.
play() {
  local book="$1"
  shift
  ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$here/$book" "$@" >"$out/${book%.yml}.log" 2>&1
}
# run_ok <playbook> [-e ...]: the playbook must succeed.
run_ok() {
  play "$@" || { cat "$out/${1%.yml}.log" >&2; fail "$1 failed"; }
}

start_host() {
  local ubuntu="$1"
  host="noixdev-infra-varnish-$ubuntu"
  docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock --name "$host" "noixdev-infra-host:$ubuntu" >/dev/null
  until (h systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
  # The image's policy-rc.d (exit 101) keeps package scripts from starting
  # services; servers have none.
  h rm -f /usr/sbin/policy-rc.d

  echo "== test host (ubuntu $ubuntu)"
  run_ok converge.yml
}

# Every refusal stops the run before any change, naming the field and the site
# (invalid.yml asserts that, play by play).
test_invalid() {
  echo "== invalid settings are refused (ubuntu $1)"
  run_ok invalid.yml
  grep -Eq 'failed=0' "$out/invalid.log" || fail "invalid.yml did not run to the end"
}

# The settings of two sites that the role must accept (the role installs
# nothing yet; this proves that the checks do not refuse valid settings).
test_valid() {
  echo "== valid settings are accepted (ubuntu $1)"
  printf '%s\n' '{"test_varnish": true, "varnish_memory": "1g", "varnish_sites": [
    {"name": "a", "purge_token": "0123456789abcdef0123456789abcdef", "microcache": 30, "health_path": "/health", "health_host": "a.test", "debug_header": true, "strip_cookies": ["tracker_*"]},
    {"name": "b_2-x", "profile": "shopware", "purge_token": "fedcba9876543210fedcba9876543210"}]}' >"$out/valid-vars.json"
  run_ok converge.yml -e "@$out/valid-vars.json"
}

# All scenarios by default; "tests/varnish/run.sh invalid" runs only these.
scenarios="${*:-invalid valid}"
for ubuntu in $releases; do
  start_host "$ubuntu"
  for scenario in $scenarios; do
    case "$scenario" in
      invalid) test_invalid "$ubuntu" ;;
      valid) test_valid "$ubuntu" ;;
      *) fail "unknown scenario $scenario (invalid, valid)" ;;
    esac
  done
  cleanup
  host=
done

noix_done
echo "== all varnish tests passed"
