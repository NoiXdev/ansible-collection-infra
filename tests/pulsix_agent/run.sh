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

# failure_text MODE: what the role says when the connection check fails in MODE.
failure_text() {
  case "$1" in
    no_connection) echo "holds no connection" ;;
    drop) echo "did not hold for 30 seconds" ;;
    *) echo "logged a failure" ;;
  esac
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

# --- removal fixtures -------------------------------------------------------
# The spec's table, one path per line; a trailing slash marks a directory.
# Units are listed apart, because they are checked through systemd.

netdata_spec() {
  printf '%s\n' /opt/netdata/ /usr/libexec/netdata/ /usr/lib/netdata/ /usr/share/netdata/ \
    /usr/sbin/netdata /usr/sbin/netdatacli /etc/cron.daily/netdata-updater /etc/logrotate.d/netdata \
    /etc/default/netdata /etc/netdata/ /var/lib/netdata/ /var/cache/netdata/ /var/log/netdata/ \
    /etc/apt/sources.list.d/netdata-repo.list /usr/share/keyrings/netdata-archive-keyring.gpg \
    /etc/systemd/system/netdata-extra.service /usr/lib/systemd/system/netdata.service \
    /usr/lib/systemd/system/netdata-updater.service /usr/lib/systemd/system/netdata-updater.timer
}
netdata_units() { printf '%s\n' netdata netdata-updater.timer netdata-updater.service netdata-extra.service; }
# What a netdata package owns.
netdata_files() {
  printf '%s\n' /usr/sbin/netdata /usr/sbin/netdatacli /usr/libexec/netdata/plugin /usr/lib/netdata/lib \
    /usr/share/netdata/web/index.html /etc/default/netdata /etc/logrotate.d/netdata \
    /etc/cron.daily/netdata-updater /etc/netdata/netdata.conf /usr/lib/systemd/system/netdata.service \
    /usr/lib/systemd/system/netdata-updater.service /usr/lib/systemd/system/netdata-updater.timer
}

zabbix_agent_spec() {
  printf '%s\n' /etc/zabbix/zabbix_agentd.conf /etc/zabbix/zabbix_agentd.d/ /etc/zabbix/zabbix_agent2.conf \
    /etc/zabbix/zabbix_agent2.d/ /var/log/zabbix-agent/ /var/log/zabbix-agent2/ \
    /usr/lib/systemd/system/zabbix-agent.service /usr/lib/systemd/system/zabbix-agent2.service
}
zabbix_shared_spec() { printf '%s\n' /etc/zabbix/ /run/zabbix/ /etc/apt/sources.list.d/zabbix.list; }
zabbix_units() { printf '%s\n' zabbix-agent zabbix-agent2; }

checkmk_spec() {
  printf '%s\n' /usr/lib/check_mk_agent/ /usr/bin/check_mk_agent /usr/bin/check_mk_caching_agent /usr/bin/mk-job \
    /usr/bin/waitmax /usr/bin/cmk-agent-ctl /usr/bin/cmk-update-agent /etc/xinetd.d/check-mk-agent \
    /etc/check_mk/ /var/lib/check_mk_agent/ /var/lib/cmk-agent/ \
    /usr/lib/systemd/system/check-mk-agent.socket /usr/lib/systemd/system/check-mk-agent@.service \
    /usr/lib/systemd/system/check-mk-agent-async.service /usr/lib/systemd/system/cmk-agent-ctl-daemon.service \
    /etc/systemd/system/check-mk-agent-extra.service
}
checkmk_units() { printf '%s\n' check-mk-agent.socket check-mk-agent-async cmk-agent-ctl-daemon; }

# clean_tools: no trace of any of the three tools.
clean_tools() { host_sh 'sh /opt/fixtures/clean.sh'; }

# deb NAME VERSION PATH...: build and install a fixture package.
deb() {
  local name="$1" version="$2"
  shift 2
  printf '%s\n' "$@" | docker exec -i "$host" sh -c "cat >/tmp/$name.list"
  host_sh "sh /opt/fixtures/make-deb.sh $name $version /tmp/$name.list && dpkg -i /tmp/${name}_${version}_all.deb >/dev/null 2>&1" \
    || fail "could not install the fixture package $name"
}

# real_candidate PKG: true when the release offers PKG.
real_candidate() {
  host_sh "apt-cache policy $1 2>/dev/null | grep -q 'Candidate: [0-9]'"
}

# seed_missing: create whatever of the listed paths is missing (stdin).
seed_missing() {
  local path
  while IFS= read -r path; do
    case "$path" in
      */)
        host_sh "mkdir -p $path && touch ${path}marker"
        ;;
      *-extra.service) host_sh "mkdir -p $(dirname "$path") && echo fixture >$path" ;;
      *.service) host_sh "mkdir -p $(dirname "$path"); test -e $path || printf '[Unit]\\nDescription=fixture\\n[Service]\\nExecStart=/bin/sleep infinity\\n' >$path" ;;
      *.timer) host_sh "test -e $path || printf '[Unit]\\nDescription=fixture\\n[Timer]\\nOnCalendar=daily\\n' >$path" ;;
      *.socket) host_sh "test -e $path || printf '[Unit]\\nDescription=fixture\\n[Socket]\\nListenStream=127.0.0.1:16556\\nAccept=yes\\n' >$path" ;;
      *.list) host_sh "test -e $path || { mkdir -p $(dirname "$path"); echo '# fixture' >$path; }" ;;
      *) host_sh "test -e $path || test -L $path || { mkdir -p $(dirname "$path"); echo fixture >$path; }" ;;
    esac
  done
}

# add_user NAME: a system user and group, unless a package made them.
add_user() { host_sh "getent passwd $1 >/dev/null || useradd -r -s /usr/sbin/nologin $1"; }

# pkg_state PKG: dpkg's state, "none" when the package is unknown.
pkg_state() { host_sh "dpkg-query -W -f='\${db:Status-Status}' $1 2>/dev/null || echo none"; }

# assert_pkg_gone PKG...: neither installed nor with configuration left.
assert_pkg_gone() {
  local pkg state
  for pkg in "$@"; do
    state="$(pkg_state "$pkg")"
    case "$state" in none | not-installed) ;; *) fail "package $pkg is still there (state $state)" ;; esac
  done
}

# assert_paths_gone / assert_paths_there: the listed paths (stdin).
assert_paths_gone() {
  local path
  while IFS= read -r path; do
    path="${path%/}"
    host_sh "test ! -e $path && test ! -L $path" || fail "$path is still there"
  done
}
assert_paths_there() {
  local path
  while IFS= read -r path; do
    path="${path%/}"
    host_sh "test -e $path" || fail "$path is gone"
  done
}

# assert_units_gone: systemd no longer knows the units (stdin).
assert_units_gone() {
  local unit
  while IFS= read -r unit; do
    [ "$(host_sh "systemctl show -p LoadState --value $unit")" = not-found ] || fail "unit $unit is still known"
  done
}

# assert_pkgs_installed PKG...: all are installed.
assert_pkgs_installed() {
  local pkg
  for pkg in "$@"; do
    [ "$(pkg_state "$pkg")" = installed ] || fail "package $pkg is not installed"
  done
}

# assert_user_gone NAME: neither user nor group.
assert_user_gone() {
  host_sh "! getent passwd $1 >/dev/null && ! getent group $1 >/dev/null" || fail "user or group $1 is still there"
}

# remove_args TOOL...: sets rm to the -e argument that asks for these tools.
rm_args=()
remove_args() {
  local list="" tool
  for tool in "$@"; do list="$list${list:+,}\"$tool\""; done
  rm_args=(-e "{\"pulsix_agent_remove\": [$list]}")
}

# fake_unit PATH: a running unit with no package, as a script installer leaves it.
fake_unit() {
  host_sh "printf '[Unit]\nDescription=fixture\n[Service]\nExecStart=/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n' >$1"
}

# install_netdata_package: the real package where the release offers one,
# otherwise a fixture; the files the table names that a package does not own
# are added by hand.
install_netdata_package() {
  if real_candidate netdata; then
    host_sh 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq netdata >/dev/null 2>&1' || fail "could not install the netdata package"
  else
    # shellcheck disable=SC2046
    deb netdata 1.0 $(netdata_files)
  fi
  deb netdata-plugin-fixture 1.0 /usr/lib/netdata/plugin-fixture
  add_user netdata
  netdata_spec | seed_missing
}

# install_zabbix_agent [fixture]: the real package where the release offers
# one, unless "fixture" asks for the test package (the real package's own
# postrm removes /run/zabbix, which would hide what the role does with it).
install_zabbix_agent() {
  if [ "${1:-}" != fixture ] && real_candidate zabbix-agent; then
    host_sh 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zabbix-agent >/dev/null 2>&1' || fail "could not install zabbix-agent"
  else
    deb zabbix-agent 1.0 /etc/zabbix/zabbix_agentd.conf /usr/lib/systemd/system/zabbix-agent.service
  fi
  deb zabbix-agent2 1.0 /etc/zabbix/zabbix_agent2.conf /usr/lib/systemd/system/zabbix-agent2.service
  deb zabbix-agent2-plugin-fixture 1.0 /usr/lib/zabbix/plugins/fixture
  deb zabbix-release 1.0 /etc/apt/sources.list.d/zabbix.list
  add_user zabbix
  { zabbix_agent_spec; zabbix_shared_spec; } | seed_missing
}

install_checkmk() {
  deb check-mk-agent 1.0 /usr/bin/check_mk_agent /usr/bin/cmk-agent-ctl /usr/lib/check_mk_agent/plugins/ \
    /etc/check_mk/main.cfg /usr/lib/systemd/system/check-mk-agent.socket /usr/lib/systemd/system/check-mk-agent@.service \
    /usr/lib/systemd/system/check-mk-agent-async.service /usr/lib/systemd/system/cmk-agent-ctl-daemon.service
  add_user cmk-agent
  checkmk_spec | seed_missing
}

# A host with the agent not yet installed and no monitoring tool on it.
removal_host() {
  fresh_host
  publish_stub "$v"
  clean_tools
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

  host_sh 'mkdir -p /opt/stub /opt/fixtures /srv/pulsix-stub-web /var/lib/pulsix-stub'
  docker cp "$here/stub/." "$host:/opt/stub/"
  docker cp "$here/fixtures/." "$host:/opt/fixtures/"
  # Package lists, to see which real packages this release offers.
  host_sh 'apt-get update -qq >/dev/null 2>&1; true'
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
  # Each mode fails in its own check; the drop closes after 30 s, inside the
  # 30-second window that follows the first sighting of the connection.
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
      tail -n +$((before + 1)) "$log" | grep -q "$(failure_text "$mode")" || fail "$mode did not fail with: $(failure_text "$mode")"
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


  # --- removal ---------------------------------------------------------------
  # Each scenario removes a tool completely and then converges again: the
  # second run must change nothing.
  if scenario remove_netdata_package; then
    echo "-- remove_netdata_package"
    removal_host
    install_netdata_package
    remove_args netdata
    converge "${tok[@]}" "${rm_args[@]}"
    netdata_spec | assert_paths_gone
    netdata_units | assert_units_gone
    assert_pkg_gone netdata netdata-plugin-fixture
    assert_user_gone netdata
    converge "${tok[@]}" "${rm_args[@]}"
    changed_zero
  fi

  if scenario remove_netdata_script; then
    echo "-- remove_netdata_script"
    removal_host
    netdata_spec | seed_missing
    fake_unit /etc/systemd/system/netdata.service
    host_sh 'systemctl daemon-reload && systemctl enable --now netdata.service'
    add_user netdata
    remove_args netdata
    converge "${tok[@]}" "${rm_args[@]}"
    netdata_spec | assert_paths_gone
    host_sh 'test ! -e /etc/systemd/system/netdata.service' || fail "the unit file of the script layout is still there"
    netdata_units | assert_units_gone
    assert_user_gone netdata
    converge "${tok[@]}" "${rm_args[@]}"
    changed_zero
  fi

  if scenario remove_zabbix; then
    echo "-- remove_zabbix"
    removal_host
    install_zabbix_agent
    remove_args zabbix_agent
    # The helper the agent pulls in (zabbix-sender on some releases, a fixture
    # elsewhere) is auto-installed and goes with it.
    if [ "$(pkg_state zabbix-sender)" != installed ]; then
      deb zabbix-sender 1.0 /usr/bin/zabbix_sender
    fi
    host_sh 'apt-mark auto zabbix-sender >/dev/null'
    converge "${tok[@]}" "${rm_args[@]}"
    { zabbix_agent_spec; zabbix_shared_spec; } | assert_paths_gone
    zabbix_units | assert_units_gone
    assert_pkg_gone zabbix-agent zabbix-agent2 zabbix-agent2-plugin-fixture zabbix-release zabbix-sender
    assert_user_gone zabbix
    converge "${tok[@]}" "${rm_args[@]}"
    changed_zero
  fi

  if scenario remove_checkmk; then
    echo "-- remove_checkmk"
    removal_host
    install_checkmk
    host_sh 'systemctl is-active check-mk-agent.socket >/dev/null' || fail "the fixture socket does not run"
    remove_args checkmk_agent
    converge "${tok[@]}" "${rm_args[@]}"
    checkmk_spec | assert_paths_gone
    checkmk_units | assert_units_gone
    assert_pkg_gone check-mk-agent
    assert_user_gone cmk-agent
    converge "${tok[@]}" "${rm_args[@]}"
    changed_zero
  fi

  if scenario remove_rc_state; then
    echo "-- remove_rc_state"
    removal_host
    deb netdata 1.0 /usr/sbin/netdata /etc/netdata/netdata.conf
    host_sh 'dpkg -r netdata >/dev/null 2>&1'
    [ "$(pkg_state netdata)" = config-files ] || fail "the test package is not in state rc"
    remove_args netdata
    converge "${tok[@]}" "${rm_args[@]}"
    assert_pkg_gone netdata
    converge "${tok[@]}" "${rm_args[@]}"
    changed_zero
  fi

  if scenario checkmk_xinetd; then
    echo "-- checkmk_xinetd"
    removal_host
    host_sh 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xinetd >/dev/null 2>&1' || fail "could not install xinetd"
    deb check-mk-agent 1.0 /usr/bin/check_mk_agent
    # A second service, so that xinetd has something left to serve afterwards.
    host_sh 'printf "#!/bin/sh\necho check_mk\n" >/usr/bin/check_mk_agent
      printf "service check_mk\n{\n type = UNLISTED\n port = 6556\n socket_type = stream\n protocol = tcp\n wait = no\n user = root\n server = /usr/bin/check_mk_agent\n}\n" >/etc/xinetd.d/check-mk-agent
      printf "service other_fixture\n{\n type = UNLISTED\n port = 6557\n socket_type = stream\n protocol = tcp\n wait = no\n user = root\n server = /bin/echo\n}\n" >/etc/xinetd.d/other-fixture
      systemctl enable xinetd >/dev/null 2>&1; systemctl restart xinetd; sleep 2'
    port_open() { host_sh "python3 -c 'import socket; socket.create_connection((\"127.0.0.1\", $1), timeout=2)'" 2>/dev/null; }
    port_open 6556 || { host_sh 'systemctl status xinetd --no-pager; journalctl -u xinetd --no-pager | tail -20; ss -ltn' >&2 || true; fail "xinetd does not serve port 6556 before the removal"; }
    port_open 6557 || fail "xinetd does not serve port 6557 before the removal"
    remove_args checkmk_agent
    converge "${tok[@]}" "${rm_args[@]}"
    if port_open 6556; then fail "port 6556 still answers after the removal"; fi
    port_open 6557 || fail "xinetd stopped serving its other services"
    converge "${tok[@]}" "${rm_args[@]}"
    changed_zero
  fi

  if scenario opt_in; then
    echo "-- opt_in"
    removal_host
    install_netdata_package
    install_zabbix_agent
    install_checkmk
    converge "${tok[@]}"
    netdata_spec | assert_paths_there
    { zabbix_agent_spec; zabbix_shared_spec; } | assert_paths_there
    checkmk_spec | assert_paths_there
    assert_pkgs_installed netdata zabbix-agent check-mk-agent
    host_sh 'getent passwd netdata zabbix cmk-agent >/dev/null' || fail "a user went away without a request"
  fi

  if scenario only_requested; then
    echo "-- only_requested"
    removal_host
    install_netdata_package
    install_zabbix_agent
    install_checkmk
    remove_args zabbix_agent
    converge "${tok[@]}" "${rm_args[@]}"
    zabbix_agent_spec | assert_paths_gone
    netdata_spec | assert_paths_there
    checkmk_spec | assert_paths_there
    assert_pkgs_installed netdata check-mk-agent
    host_sh 'getent passwd netdata cmk-agent >/dev/null' || fail "an unrequested tool lost its user"
  fi

  if scenario zabbix_shared; then
    echo "-- zabbix_shared"
    removal_host
    install_zabbix_agent fixture
    deb zabbix-server-pgsql 1.0 /usr/sbin/zabbix_server
    remove_args zabbix_agent
    converge "${tok[@]}" "${rm_args[@]}"
    zabbix_agent_spec | assert_paths_gone
    zabbix_units | assert_units_gone
    assert_pkg_gone zabbix-agent zabbix-agent2 zabbix-agent2-plugin-fixture
    zabbix_shared_spec | assert_paths_there
    assert_pkgs_installed zabbix-release zabbix-server-pgsql
    host_sh 'getent passwd zabbix >/dev/null' || fail "the zabbix user was removed"
    converge "${tok[@]}" "${rm_args[@]}"
    changed_zero
  fi

  if scenario zabbix_manual_tool; then
    echo "-- zabbix_manual_tool"
    removal_host
    install_zabbix_agent fixture
    deb zabbix-sender 1.0 /usr/bin/zabbix_sender
    host_sh 'apt-mark manual zabbix-sender >/dev/null'
    deb noixdev-unrelated 1.0 /usr/share/noixdev-unrelated/data
    host_sh 'apt-mark auto noixdev-unrelated >/dev/null'
    remove_args zabbix_agent
    converge "${tok[@]}" "${rm_args[@]}"
    zabbix_agent_spec | assert_paths_gone
    assert_pkg_gone zabbix-agent zabbix-agent2 zabbix-agent2-plugin-fixture
    zabbix_shared_spec | assert_paths_there
    assert_pkgs_installed zabbix-sender zabbix-release noixdev-unrelated
    host_sh 'getent passwd zabbix >/dev/null' || fail "the zabbix user was removed"
    converge "${tok[@]}" "${rm_args[@]}"
    changed_zero
  fi

  if scenario zabbix_half_configured; then
    echo "-- zabbix_half_configured"
    removal_host
    install_zabbix_agent fixture
    host_sh 'echo /usr/sbin/zabbix_server >/tmp/zabbix-server.list
      FAIL_POSTINST=1 sh /opt/fixtures/make-deb.sh zabbix-server-pgsql 1.0 /tmp/zabbix-server.list
      dpkg -i /tmp/zabbix-server-pgsql_1.0_all.deb >/dev/null 2>&1; true'
    [ "$(pkg_state zabbix-server-pgsql)" = half-configured ] || fail "the test server package is not half-configured"
    remove_args zabbix_agent
    # apt tries to finish the broken package while it purges the agent and
    # fails; the run stops there and the shared items stay. (The selection of
    # the other zabbix packages by state is checked in the report with the
    # same expression.)
    expect_fail "${tok[@]}" "${rm_args[@]}"
    zabbix_shared_spec | assert_paths_there
    assert_pkgs_installed zabbix-release
    host_sh 'getent passwd zabbix >/dev/null' || fail "the zabbix user was removed"
    [ "$(pkg_state zabbix-server-pgsql)" = half-configured ] || fail "the half-configured server package changed state"
  fi

  if scenario zabbix_orphan_server; then
    echo "-- zabbix_orphan_server"
    removal_host
    install_zabbix_agent fixture
    deb zabbix-server-pgsql 1.0 /usr/sbin/zabbix_server
    host_sh 'apt-mark auto zabbix-server-pgsql >/dev/null'
    remove_args zabbix_agent
    converge "${tok[@]}" "${rm_args[@]}"
    zabbix_agent_spec | assert_paths_gone
    assert_pkgs_installed zabbix-server-pgsql zabbix-release
    zabbix_shared_spec | assert_paths_there
    host_sh 'getent passwd zabbix >/dev/null' || fail "the zabbix user was removed"
  fi

  if scenario unit_bad_setting; then
    echo "-- unit_bad_setting"
    removal_host
    netdata_spec | seed_missing
    host_sh "printf '[Unit]\nDescription=fixture\n[Service]\nExecStart=/bin/sleep 7777\n[Install]\nWantedBy=multi-user.target\n' >/etc/systemd/system/netdata.service
      systemctl daemon-reload && systemctl enable --now netdata.service
      echo fixture >/etc/systemd/system/netdata.service
      systemctl daemon-reload"
    host_sh 'pgrep -f "[s]leep 7777" >/dev/null' || fail "the unit does not run"
    [ "$(host_sh 'systemctl show -p LoadState --value netdata')" != loaded ] || fail "the unit file is not bad"
    remove_args netdata
    converge "${tok[@]}" "${rm_args[@]}"
    if host_sh 'pgrep -f "[s]leep 7777" >/dev/null'; then fail "the unit is still running"; fi
    netdata_spec | assert_paths_gone
    host_sh 'test ! -e /etc/systemd/system/multi-user.target.wants/netdata.service && test ! -L /etc/systemd/system/multi-user.target.wants/netdata.service' \
      || fail "the enable link is still there"
    netdata_units | assert_units_gone
    converge "${tok[@]}" "${rm_args[@]}"
    changed_zero
  fi

  if scenario unit_masked; then
    echo "-- unit_masked"
    removal_host
    netdata_spec | seed_missing
    host_sh "printf '[Unit]\nDescription=fixture\n[Service]\nExecStart=/bin/sleep 7778\n' >/usr/lib/systemd/system/netdata.service
      rm -f /etc/systemd/system/netdata.service
      systemctl daemon-reload && systemctl start netdata.service && systemctl mask netdata.service"
    [ "$(host_sh 'systemctl show -p LoadState --value netdata')" = masked ] || fail "the unit is not masked"
    host_sh 'pgrep -f "[s]leep 7778" >/dev/null' || fail "the masked unit does not run"
    remove_args netdata
    converge "${tok[@]}" "${rm_args[@]}"
    if host_sh 'pgrep -f "[s]leep 7778" >/dev/null'; then fail "the masked unit is still running"; fi
    netdata_spec | assert_paths_gone
    netdata_units | assert_units_gone
    converge "${tok[@]}" "${rm_args[@]}"
    changed_zero
  fi

  if scenario package_anchors; then
    echo "-- package_anchors"
    removal_host
    install_netdata_package
    install_zabbix_agent fixture
    install_checkmk
    deb netdataish 1.0 /usr/share/netdataish/data
    deb zabbix-agent-extras 1.0 /usr/share/zabbix-agent-extras/data
    deb check-mk-agent-extra 1.0 /usr/share/check-mk-agent-extra/data
    remove_args netdata zabbix_agent checkmk_agent
    converge "${tok[@]}" "${rm_args[@]}"
    assert_pkg_gone netdata zabbix-agent zabbix-agent2 check-mk-agent
    assert_pkgs_installed netdataish zabbix-agent-extras check-mk-agent-extra
    # zabbix-agent-extras is another zabbix package: the shared parts stay.
    zabbix_shared_spec | assert_paths_there
  fi

  if scenario check_mode_removal; then
    echo "-- check_mode_removal"
    removal_host
    install_netdata_package
    install_zabbix_agent fixture
    install_checkmk
    converge "${tok[@]}"
    remove_args netdata zabbix_agent checkmk_agent
    converge --check "${tok[@]}" "${rm_args[@]}"
    local word
    for word in 'would remove netdata' 'would remove zabbix_agent' 'would remove checkmk_agent' \
      'netdata-archive-keyring.gpg' '/etc/apt/sources.list.d/netdata*' '/etc/systemd/system/netdata*' '/lib/systemd/system/netdata*' \
      '/etc/zabbix, /run/zabbix]' 'zabbix-release' '/etc/apt/sources.list.d/zabbix*' 'user [zabbix]' 'zabbix-sender' \
      '/lib/systemd/system/check-mk-agent*' '/etc/systemd/system/cmk-agent-ctl*' 'user [cmk-agent]' 'user [netdata]'; do
      printf '%s\n' "$out" | grep -qF -- "$word" || fail "the check run does not name: $word"
    done
    netdata_spec | assert_paths_there
    zabbix_agent_spec | assert_paths_there
    zabbix_shared_spec | assert_paths_there
    checkmk_spec | assert_paths_there
    assert_pkgs_installed netdata zabbix-agent zabbix-release check-mk-agent
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
