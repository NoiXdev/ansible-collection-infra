#!/usr/bin/env bash
# pulsix_agent role on systemd Ubuntu containers, one scenario after the other.
# The Pulsix agent is a stub (stub/agent.py) served with its checksum by a
# local web server; stub/manager.py stands in for the manager's agent port.
#
#   UBUNTU="24.04 26.04"                        releases to run (default: both)
#   NOIXDEV_INFRA_PULSIX_AGENT_TESTS=a,b        only these scenarios (default: all)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
releases="${UBUNTU:-24.04 26.04}"
host=""

cleanup() {
  [ "${KEEP:-0}" = 1 ] && return
  [ -z "$host" ] || docker rm -f "$host" >/dev/null 2>&1 || true
}
# shellcheck source=/dev/null
. "$here/../lib/suite.sh"
noix_exit_guard

mkdir -p "$tests/output/ansible_collections/noixdev"
noix_link_collection "$root" "$tests/output"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"
export ANSIBLE_NOCOLOR=1

log=""

# host_sh CMD: run a shell command in the container.
host_sh() { docker exec "$host" sh -c "$*"; }

# play ARGS: converge.yml with ARGS; the output is appended to $log.
play() {
  ansible-playbook -i "$tests/inventory.yml" -e "test_host=$host" "$here/converge.yml" "$@" >>"$log" 2>&1
}

# expect_fail ARGS: the run must fail in a task of the role (not before it, for
# example because the role is missing).
expect_fail() {
  local before
  before="$(wc -l <"$log")"
  if play "$@"; then
    echo "expected the run to fail: $*" >&2
    exit 1
  fi
  tail -n +$((before + 1)) "$log" | grep -q 'TASK \[noixdev.infra.pulsix_agent : ' || {
    tail -n +$((before + 1)) "$log" >&2
    echo "the run failed before it reached the role: $*" >&2
    exit 1
  }
}

# fresh_host: a host the role has never touched; the stub runs in mode ok.
fresh_host() {
  host_sh 'systemctl disable --now pulsix-agent 2>/dev/null; systemctl reset-failed pulsix-agent 2>/dev/null
    rm -rf /etc/pulsix /usr/local/bin/pulsix-agent /etc/systemd/system/pulsix-agent.service
    systemctl daemon-reload; true'
  set_mode ok
}

# set_mode MODE: the mode a running stub follows (it polls the file).
set_mode() { host_sh "printf '%s\n' '$1' >/var/lib/pulsix-stub/mode.new && mv /var/lib/pulsix-stub/mode.new /var/lib/pulsix-stub/mode"; }

# publish_stub VERSION [SHA]: serve the stub as VERSION's agent binary with its
# checksum (SHA instead, to serve a wrong one). The version is part of the
# file, so every version has a checksum of its own.
publish_stub() {
  local version="$1" sha="${2:-}" arch dir name
  arch="$(host_sh 'dpkg --print-architecture')"
  dir="/srv/pulsix-stub-web/$version"
  name="pulsix-agent-linux-$arch"
  host_sh "mkdir -p $dir && { cat /opt/stub/agent.py; echo '# stub $version'; } >$dir/$name && chmod 0755 $dir/$name"
  if [ -z "$sha" ]; then
    sha="$(host_sh "sha256sum $dir/$name" | cut -d' ' -f1)"
  fi
  host_sh "printf '%s  %s\n' '$sha' '$name' >$dir/$name.sha256"
}

# scenario NAME: true when the run includes it.
scenario() {
  local only
  only="$(printf '%s' "${NOIXDEV_INFRA_PULSIX_AGENT_TESTS:-}" | tr ',' ' ')"
  [ -z "$only" ] && return 0
  case " $only " in *" $1 "*) return 0 ;; esac
  return 1
}

fail() { echo "$*" >&2; exit 1; }

start_host() {
  local ubuntu="$1"
  host="noixdev-infra-pulsix-agent-$ubuntu"
  docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null
  docker rm -f "$host" >/dev/null 2>&1 || true
  # IPv6 on loopback: the manager stub listens on [::1] too.
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --tmpfs /run --tmpfs /run/lock --name "$host" "noixdev-infra-host:$ubuntu" >/dev/null
  until (docker exec "$host" systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done

  host_sh 'mkdir -p /opt/stub /srv/pulsix-stub-web /var/lib/pulsix-stub'
  docker cp "$here/stub/." "$host:/opt/stub/"
  host_sh 'systemd-run --quiet --unit=pulsix-stub-web python3 -u -m http.server --bind 127.0.0.1 --directory /srv/pulsix-stub-web 18080
    systemd-run --quiet --unit=pulsix-stub-manager python3 -u /opt/stub/manager.py'
  local port
  for port in 18080 18444; do
    until host_sh "python3 -c 'import socket; socket.create_connection((\"127.0.0.1\", $port), timeout=1)'" 2>/dev/null; do sleep 1; done
  done
  host_sh "python3 -c 'import socket; socket.create_connection((\"::1\", 18444), timeout=1)'" \
    || fail "the manager stub does not listen on [::1]:18444"
  set_mode ok
}


run_release() {
  local ubuntu="$1" out
  out="$tests/output/pulsix_agent-$ubuntu"
  mkdir -p "$out"
  log="$out/run.log"
  : >"$log"
  echo "== ubuntu $ubuntu"
  start_host "$ubuntu"

  if scenario refusals; then
    echo "-- refusals"
    fresh_host
    local token=pxa1.test-valid addr=manager.test:18444
    expect_fail -e "pulsix_agent_manager_addr=" -e "pulsix_agent_enroll_token=$token"
    expect_fail -e "pulsix_agent_manager_addr=no-port.test" -e "pulsix_agent_enroll_token=$token"
    expect_fail -e "pulsix_agent_manager_addr=$addr" -e "pulsix_agent_enroll_token=$token" -e pulsix_agent_version=v1.2.3
    expect_fail -e "pulsix_agent_manager_addr=$addr" -e "pulsix_agent_enroll_token=$token" -e pulsix_agent_version=latest
    expect_fail -e "pulsix_agent_manager_addr=$addr" -e "pulsix_agent_enroll_token=$token" -e '{"pulsix_agent_remove": ["nagios"]}'
    expect_fail -e "pulsix_agent_manager_addr=$addr" -e pulsix_agent_enroll_token=abc.def
    expect_fail -e "pulsix_agent_manager_addr=$addr"
    host_sh 'test ! -e /usr/local/bin/pulsix-agent && test ! -e /etc/pulsix' \
      || fail "a refused run left /usr/local/bin/pulsix-agent or /etc/pulsix behind"

    # A bracketed IPv6 address passes the settings check.
    local before
    before="$(wc -l <"$log")"
    play --tags pulsix_agent_check -e '{"pulsix_agent_manager_addr": "[2001:db8::1]:8444"}' -e "pulsix_agent_enroll_token=$token" \
      || { tail -n +$((before + 1)) "$log" >&2; fail "an IPv6 manager address was refused"; }
    tail -n +$((before + 1)) "$log" | grep -q 'TASK \[noixdev.infra.pulsix_agent : Check the settings\]' \
      || fail "the settings check did not run for an IPv6 manager address"
    ! tail -n +$((before + 1)) "$log" | grep -q 'fatal:' || fail "an IPv6 manager address failed a check"
  fi
}

for ubuntu in $releases; do
  run_release "$ubuntu"
  cleanup
done

noix_done
