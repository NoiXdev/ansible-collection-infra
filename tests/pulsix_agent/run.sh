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

# Tokens the stub agent knows: the first enrolls, the second is refused.
token_valid=pxa1.NOIXTESTVALID.secret.pin
token_refused=pxa1.NOIXTESTREFUSED.secret.pin

log=""
common=(-e noixdev_infra_unused=1)

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
  if play "${common[@]}" "$@"; then
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

bin=/usr/local/bin/pulsix-agent
out=""

# converge ARGS: a run that must succeed; $out holds its output.
converge() {
  local before
  before="$(wc -l <"$log")"
  play "${common[@]}" "$@" || { tail -n +$((before + 1)) "$log" >&2; fail "the run failed: $*"; }
  out="$(tail -n +$((before + 1)) "$log")"
}

# changed_zero: the last run changed nothing.
changed_zero() { printf '%s\n' "$out" | grep -E '^testhost +:' | grep -q 'changed=0 ' || fail "the run was not idempotent"; }

main_pid() { host_sh 'systemctl show -p MainPID --value pulsix-agent'; }
agent_sha() { host_sh "sha256sum $bin" | cut -d' ' -f1; }
sha_file() { echo "/srv/pulsix-stub-web/$1/pulsix-agent-linux-$(host_sh 'dpkg --print-architecture').sha256"; }

# no_token_left PID: the token is neither in agent.env nor in the environment of PID.
no_token_left() {
  if host_sh 'grep -q PULSIX_ENROLL_TOKEN /etc/pulsix/agent.env'; then fail "agent.env still has the token"; fi
  if host_sh "grep -aq NOIXTESTVALID /proc/$1/environ"; then fail "the agent still holds the token"; fi
}

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
    local token="$token_valid" addr=manager.test:18444
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

  # Settings every run shares: the manager stub and the stub's web server.
  common=(-e pulsix_agent_manager_addr=127.0.0.1:18444
    -e 'pulsix_agent_download_url=http://127.0.0.1:18080/{{ pulsix_agent_version }}/pulsix-agent-linux-{{ pulsix_agent_arch }}')
  local tok=(-e "pulsix_agent_enroll_token=$token_valid") pid v=0.1.0-rc.4

  if scenario install || scenario idempotence; then
    echo "-- install, idempotence"
    fresh_host
    publish_stub "$v"
    converge -v --diff "${tok[@]}"
    [ "$(host_sh 'stat -c "%a %U %G" /etc/pulsix/agent.env')" = "600 root root" ] || fail "agent.env is not 600 root root"
    [ "$(host_sh 'stat -c "%a" /etc/pulsix')" = 700 ] || fail "/etc/pulsix is not 700"
    [ "$(host_sh "stat -c %a $bin")" = 755 ] || fail "the binary is not 755"
    host_sh 'systemctl is-active --quiet pulsix-agent && systemctl is-enabled --quiet pulsix-agent' || fail "the service is not active and enabled"
    host_sh 'test -e /etc/pulsix/agent.crt' || fail "agent.crt is missing"
    pid="$(main_pid)"
    no_token_left "$pid"
    if printf '%s\n' "$out" | grep -q NOIXTESTVALID; then fail "the Ansible log shows the token"; fi
    converge "${tok[@]}"
    changed_zero
    [ "$(main_pid)" = "$pid" ] || fail "a second run restarted the agent"
  fi

  if scenario whitespace_token; then
    echo "-- whitespace_token"
    fresh_host
    publish_stub "$v"
    converge -e "{\"pulsix_agent_enroll_token\": \"$token_valid\\n\"}"
    host_sh 'test -e /etc/pulsix/agent.crt' || fail "a token with a trailing newline did not enroll"
    fresh_host
    converge "${tok[@]}" -e '{"pulsix_agent_enroll_tokens": {"testhost": ""}}'
    host_sh 'test -e /etc/pulsix/agent.crt' || fail "an empty per-host token did not fall back to the shared one"
  fi

  if scenario checksum_forms; then
    echo "-- checksum_forms"
    fresh_host
    publish_stub "$v"
    host_sh "sed -i 's/^\\([0-9a-f]*\\)/\\U\\1/;s/\$/\\r/' $(sha_file "$v")"
    host_sh "head -c 64 $(sha_file "$v") | grep -q '^[0-9A-F]*$' && grep -q \"\$(printf '\\r')\" $(sha_file "$v")" || fail "the test checksum file is not uppercase with CRLF"
    converge "${tok[@]}"
    [ "$(agent_sha)" = "$(host_sh "sha256sum /srv/pulsix-stub-web/$v/pulsix-agent-linux-\$(dpkg --print-architecture)" | cut -d' ' -f1)" ] \
      || fail "the binary was not installed"
  fi

  if scenario upgrade; then
    echo "-- upgrade"
    fresh_host
    publish_stub "$v"
    converge "${tok[@]}"
    pid="$(main_pid)"
    crt="$(host_sh 'stat -c "%i %Y" /etc/pulsix/agent.crt')"
    publish_stub 0.1.0-rc.5
    converge -e pulsix_agent_version=0.1.0-rc.5
    [ "$(agent_sha)" = "$(host_sh "cut -d' ' -f1 $(sha_file 0.1.0-rc.5)")" ] || fail "the binary was not upgraded"
    [ "$(main_pid)" != "$pid" ] || fail "the agent was not restarted"
    [ "$(host_sh 'stat -c "%i %Y" /etc/pulsix/agent.crt')" = "$crt" ] || fail "the upgrade touched agent.crt"
  fi

  if scenario takeover; then
    echo "-- takeover"
    fresh_host
    publish_stub "$v"
    docker cp "$root/roles/pulsix_agent/files/pulsix-agent.service" "$host:/etc/systemd/system/pulsix-agent.service"
    host_sh "cp /srv/pulsix-stub-web/$v/pulsix-agent-linux-\$(dpkg --print-architecture) $bin
      mkdir -p /etc/pulsix && chmod 700 /etc/pulsix && echo stub >/etc/pulsix/agent.crt
      printf 'PULSIX_MANAGER_ADDR=127.0.0.1:18444\nPULSIX_ENROLL_TOKEN=$token_valid\n' >/etc/pulsix/agent.env && chmod 600 /etc/pulsix/agent.env
      systemctl daemon-reload && systemctl enable --now pulsix-agent"
    sleep 3
    converge
    no_token_left "$(main_pid)"
    converge
    changed_zero
  fi

  if scenario bad_download; then
    echo "-- bad_download"
    fresh_host
    publish_stub "$v"
    converge "${tok[@]}"
    sha="$(agent_sha)"
    publish_stub 0.1.0-rc.6 "$(printf '0%.0s' $(seq 64))"
    expect_fail -e pulsix_agent_version=0.1.0-rc.6
    [ "$(agent_sha)" = "$sha" ] || fail "a wrong checksum replaced the binary"
    publish_stub 0.1.0-rc.7
    host_sh "echo 'not-a-hash  file' >$(sha_file 0.1.0-rc.7)"
    expect_fail -e pulsix_agent_version=0.1.0-rc.7
    [ "$(agent_sha)" = "$sha" ] || fail "a bad checksum file replaced the binary"
  fi

  if scenario failed_enrollment; then
    echo "-- failed_enrollment"
    fresh_host
    publish_stub "$v"
    before="$(wc -l <"$log")"
    expect_fail -e "pulsix_agent_enroll_token=$token_refused" -e pulsix_agent_enroll_timeout=10
    tail -n +$((before + 1)) "$log" | grep -q 'journalctl -u pulsix-agent' || fail "the failure does not name journalctl"
    if tail -n +$((before + 1)) "$log" | grep -q NOIXTESTREFUSED; then fail "the Ansible log shows the token"; fi
    if host_sh 'grep -q NOIXTESTREFUSED /etc/pulsix/agent.env'; then fail "the refused token stayed in agent.env"; fi
    [ "$(host_sh 'systemctl is-active pulsix-agent || true')" = inactive ] || fail "the service is not inactive"
    converge "${tok[@]}"
    host_sh 'test -e /etc/pulsix/agent.crt' || fail "enrolling again with a valid token failed"
  fi

  if scenario crash; then
    echo "-- crash"
    fresh_host
    publish_stub "$v"
    converge "${tok[@]}"
    set_mode crash
    expect_fail
    set_mode ok
  fi

  # A requested removal needs a proven connection. The marker stands in for the
  # tool's files; every failure keeps it.
  local rm=(-e '{"pulsix_agent_remove": ["netdata"]}')
  local before mode
  for mode in no_connection stream_failed refused drop; do
    if scenario "$mode"; then
      echo "-- $mode"
      fresh_host
      publish_stub "$v"
      host_sh 'mkdir -p /etc/netdata && touch /etc/netdata/marker'
      set_mode "${mode//_/-}"
      before="$(wc -l <"$log")"
      expect_fail "${tok[@]}" "${rm[@]}"
      tail -n +$((before + 1)) "$log" | grep -q 'journalctl -u pulsix-agent' || fail "the failure does not name journalctl ($mode)"
      host_sh 'test -e /etc/netdata/marker' || fail "the marker is gone after $mode"
    fi
  done

  if scenario connected; then
    echo "-- connected"
    fresh_host
    publish_stub "$v"
    host_sh 'mkdir -p /etc/netdata && touch /etc/netdata/marker'
    converge "${tok[@]}" "${rm[@]}"
  fi

  if scenario no_removal_no_proof; then
    echo "-- no_removal_no_proof"
    fresh_host
    publish_stub "$v"
    set_mode no-connection
    converge "${tok[@]}"
  fi

  if scenario ipv6_port; then
    echo "-- ipv6_port"
    fresh_host
    publish_stub "$v"
    converge "${tok[@]}" -e 'pulsix_agent_manager_addr=[::1]:18444' "${rm[@]}"
  fi

  if scenario check_mode; then
    echo "-- check_mode"
    fresh_host
    publish_stub "$v"
    converge --check "${tok[@]}"
    host_sh "test ! -e $bin && test ! -e /etc/pulsix" || fail "a check run changed the host"
  fi
}

for ubuntu in $releases; do
  run_release "$ubuntu"
  cleanup
done

noix_done
