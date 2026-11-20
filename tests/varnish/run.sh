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
# The scenario "install" installs Varnish Software's 9.1 with two sites in
# front of tests/varnish/backend.py (in place of nginx's inner server) and
# checks the packages, the loopback listeners, the front key and that only a
# request with it reaches the backend; a second run changes nothing, and a
# deleted key is created anew.
#
# The scenario "badvcl" runs a copy of the collection whose VCL does not
# compile and checks that the run fails before the running VCL is touched.
#
# The scenario "foreign" installs Ubuntu's varnish, and on a second host
# Varnish Software's 9.0, and checks that the role refuses both before any
# change.
#
# VARNISH_UBUNTU selects the releases (default "24.04 26.04"); a scenario name
# as an argument selects scenarios (the default is all of them); KEEP=1 leaves
# the test hosts running. Probes run inside the test host; no port is
# published on this machine.
# The single-quoted scripts and formats expand inside the test host, not here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
out="$tests/output/varnish"
releases="${VARNISH_UBUNTU:-24.04 26.04}"
host=
# What the test host has: clean (nothing of the role), varnish (runs of the
# role) or foreign (a varnish the role refuses).
host_state=

key=/etc/varnish/noixdev-front.key
vcl=/etc/varnish/noixdev.vcl

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

# play <log> <playbook> [-e ...]: a playbook of this suite on the test host;
# its output goes to <log>.log.
play() {
  local log="$1" book="$2"
  shift 2
  ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$here/$book" "$@" >"$out/$log.log" 2>&1
}
# run_ok <log> <playbook> [-e ...]: the playbook must succeed.
run_ok() {
  play "$@" || { cat "$out/$1.log" >&2; fail "$1 failed"; }
}
# run_fails <log> <message> <playbook> [-e ...]: the playbook must fail with
# the message.
run_fails() {
  local log="$1" message="$2"
  shift 2
  if play "$log" "$@"; then
    cat "$out/$log.log" >&2
    fail "$log: the run did not fail"
  fi
  grep -qF -- "$message" "$out/$log.log" || { cat "$out/$log.log" >&2; fail "$log: expected the message: $message"; }
}
# unchanged <log>: the run of the log changed nothing.
unchanged() {
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/$1.log" || { cat "$out/$1.log" >&2; fail "$1: the run changed something"; }
}
# unchanged_refused <log>: the refused run of the log changed nothing.
unchanged_refused() {
  grep -Eq 'changed=0 +unreachable=0 +failed=1' "$out/$1.log" || { cat "$out/$1.log" >&2; fail "$1: the refused run changed something"; }
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
  run_ok converge converge.yml
  host_state=clean
}

# use_host <ubuntu> <clean|varnish>: the host, or a new one when it has more
# than the scenario allows (clean: nothing of the role; varnish: runs of the
# role, never a varnish the role refuses).
use_host() {
  case "$2:$host_state" in
    clean:clean | varnish:clean | varnish:varnish) ;;
    *) start_host "$1" ;;
  esac
}

# apt_install <package...>: from the host's package sources.
apt_install() {
  h apt-get update -q >/dev/null
  h env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >/dev/null
}

# start_backend: tests/varnish/backend.py on 127.0.0.1:8931 of the test host
# (a transient unit), and curl for the probes.
start_backend() {
  local tries=0
  h sh -c 'command -v curl >/dev/null' || apt_install curl
  docker cp -q "$here/backend.py" "$host:/usr/local/bin/noixdev-test-backend"
  h systemctl is-active -q noixdev-test-backend \
    || h systemd-run -q --unit noixdev-test-backend python3 /usr/local/bin/noixdev-test-backend serve 127.0.0.1 8931
  until h curl -fsS -o /dev/null http://127.0.0.1:8931/health 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || fail "the backend does not answer"
    sleep 1
  done
}

# sites_vars <file> <site...>: the role's settings with the named sites of
# a (generic), b (typo3) and c (generic).
sites_vars() {
  local file="$1" site sites=
  shift
  for site in "$@"; do
    case "$site" in
      a) site='{"name": "a", "purge_token": "0123456789abcdef0123456789abcdef"}' ;;
      b) site='{"name": "b", "profile": "typo3", "purge_token": "fedcba9876543210fedcba9876543210"}' ;;
      c) site='{"name": "c", "purge_token": "cccccccccccccccccccccccccccccccc"}' ;;
      *) fail "unknown test site $site" ;;
    esac
    sites="${sites:+$sites, }$site"
  done
  printf '{"test_varnish": true, "varnish_sites": [%s]}\n' "$sites" >"$out/$file"
}

# no_key_in_logs [<key file>...]: the front key (and the keys in the files
# named) is in no log of this suite and not in the test host's journal. The
# keys are read into a variable here, never printed.
no_key_in_logs() {
  local file secret logs
  for file in "$key" "$@"; do
    secret="$(h cat "$file")"
    [ -n "$secret" ] || fail "the front key in $file is empty"
    logs="$(grep -lF -- "$secret" "$out"/*.log || true)"
    [ -z "$logs" ] || fail "the front key in $file is in the logs: $logs"
    if h sh -c "journalctl --no-pager -o verbose | grep -qF -f $file"; then
      fail "the front key in $file is in the journal of the test host"
    fi
  done
}

# no_role_files <scenario>: the role wrote none of its files.
no_role_files() {
  h sh -c 'test ! -e /etc/apt/keyrings/varnish.asc && test ! -e /etc/apt/sources.list.d/varnish.sources \
    && test ! -e /etc/apt/preferences.d/varnish && test ! -e /etc/apt/apt.conf.d/52noixdev-varnish \
    && test ! -e /etc/systemd/system/varnish.service.d/noixdev.conf' \
    || fail "$1: the refused run left files of the role"
}

# Every refusal stops the run before any change, naming the field and the site
# (invalid.yml asserts that, play by play).
test_invalid() {
  echo "== invalid settings are refused (ubuntu $1)"
  use_host "$1" clean
  run_ok invalid invalid.yml
  grep -Eq 'failed=0' "$out/invalid.log" || fail "invalid.yml did not run to the end"
}

# The settings of two sites that the role must accept.
test_valid() {
  echo "== valid settings are accepted (ubuntu $1)"
  use_host "$1" varnish
  printf '%s\n' '{"test_varnish": true, "varnish_memory": "1g", "varnish_sites": [
    {"name": "a", "purge_token": "0123456789abcdef0123456789abcdef", "microcache": 30, "health_path": "/health", "health_host": "a.test", "debug_header": true, "strip_cookies": ["tracker_*"]},
    {"name": "b_2-x", "profile": "shopware", "purge_token": "fedcba9876543210fedcba9876543210"}]}' >"$out/valid-vars.json"
  host_state=varnish
  run_ok valid converge.yml -e "@$out/valid-vars.json"
}

test_install() {
  local before after answer
  echo "== install: Varnish Software's 9.1 on the loopback address, behind the front key (ubuntu $1)"
  use_host "$1" varnish
  start_backend
  sites_vars install-vars.json a b
  host_state=varnish
  run_ok install converge.yml -e "@$out/install-vars.json"
  run_ok install-verify verify.yml

  echo "== install: a second run changes nothing and keeps the key"
  before="$(h sha256sum "$key")"
  run_ok install-again converge.yml -e "@$out/install-vars.json"
  unchanged install-again
  [ "$(h sha256sum "$key")" = "$before" ] || fail "install: the second run changed the front key"

  echo "== install: a deleted key is created anew, and the old one is refused"
  h cp -p "$key" /root/old-front.key
  h rm "$key"
  run_ok install-new-key converge.yml -e "@$out/install-vars.json"
  after="$(h sha256sum "$key")"
  [ "$after" != "$before" ] || fail "install: the run after deleting the key did not create a new one"
  run_ok install-new-key-verify verify.yml
  answer="$(h sh -c 'curl -sS -o /dev/null -w "%{http_code}" -H "Host: a.test" -H "X-Noix-Site: a" \
    -H "X-Noix-Front: $(cat /root/old-front.key)" http://127.0.0.1:6081/')"
  [ "$answer" = 403 ] || fail "install: the old key got $answer, not 403"
  no_key_in_logs /root/old-front.key
  h rm /root/old-front.key
}

test_badvcl() {
  local before_vcl before_list copy template
  echo "== badvcl: a VCL that does not compile fails the run, and the running one stays (ubuntu $1)"
  use_host "$1" varnish
  start_backend
  sites_vars badvcl-vars.json a b
  host_state=varnish
  run_ok badvcl converge.yml -e "@$out/badvcl-vars.json"
  before_vcl="$(h sha256sum "$vcl")"
  before_list="$(h varnishadm vcl.list)"

  # A copy of the collection whose VCL has an unknown word, run with a third
  # site so that the VCL would change.
  copy="$out/badvcl-collection"
  rm -rf "$copy"
  mkdir -p "$copy/ansible_collections/noixdev/infra/roles"
  cp -R "$root/galaxy.yml" "$root/meta" "$root/plugins" "$copy/ansible_collections/noixdev/infra/"
  cp -R "$root/roles/varnish" "$copy/ansible_collections/noixdev/infra/roles/"
  template="$copy/ansible_collections/noixdev/infra/roles/varnish/templates/noixdev.vcl.j2"
  sed 's/^\(sub vcl_recv {\)$/\1 noixdev_unknown_keyword;/' "$template" >"$template.new"
  mv "$template.new" "$template"
  grep -q noixdev_unknown_keyword "$template" || fail "badvcl: the copy's VCL template was not broken"
  sites_vars badvcl-c-vars.json a b c
  ANSIBLE_COLLECTIONS_PATH="$copy:$ANSIBLE_COLLECTIONS_PATH" run_fails badvcl-broken \
    "varnish: the new VCL does not compile" converge.yml -e "@$out/badvcl-c-vars.json"
  grep -qF "Symbol not found: 'noixdev_unknown_keyword'" "$out/badvcl-broken.log" \
    || fail "badvcl: the message does not show the compiler's error"

  [ "$(h sha256sum "$vcl")" = "$before_vcl" ] || fail "badvcl: the failed run changed $vcl"
  [ "$(h varnishadm vcl.list)" = "$before_list" ] || fail "badvcl: the failed run changed the loaded VCLs"
  h test ! -e "$vcl.new" || fail "badvcl: the failed run left $vcl.new"
  run_ok badvcl-verify verify.yml
  no_key_in_logs
}

test_foreign() {
  local version
  echo "== foreign: Ubuntu's varnish is refused before any change (ubuntu $1)"
  use_host "$1" clean
  host_state=foreign
  apt_install varnish
  version="$(h dpkg-query -W -f='${Version}' varnish)"
  echo "   Ubuntu's varnish: $version"
  sites_vars foreign-vars.json a b
  run_fails foreign-ubuntu \
    "varnish: installed varnish $version is not from packages.varnish-software.com; the role manages Varnish Software's packages only" \
    converge.yml -e "@$out/foreign-vars.json"
  unchanged_refused foreign-ubuntu
  [ "$(h dpkg-query -W -f='${Version}' varnish)" = "$version" ] || fail "foreign: the refused run changed Ubuntu's varnish"
  no_role_files foreign

  echo "== foreign: Varnish Software's 9.0 is refused before any change (ubuntu $1)"
  start_host "$1"
  host_state=foreign
  apt_install ca-certificates curl
  # Not the role's file names: apt's user reads the key, so it is not in /root.
  h mkdir -p /etc/apt/keyrings
  h curl -fsS -o /etc/apt/keyrings/varnish-test.asc https://packages.varnish-software.com/varnish/varnish.pub.asc
  h sh -c 'printf "Types: deb\nURIs: https://packages.varnish-software.com/varnish/ubuntu\nSuites: %s\nComponents: main\nSigned-By: /etc/apt/keyrings/varnish-test.asc\n" \
    "$(. /etc/os-release && echo "$VERSION_CODENAME")" >/etc/apt/sources.list.d/varnish-test.sources'
  h apt-get update -q >/dev/null
  version="$(h apt-cache madison varnish | awk -F' *[|] *' '!found && $2 ~ /^9[.]0[.]/ && $3 ~ /varnish-software/ {print $2; found = 1}')"
  [ -n "$version" ] || fail "foreign: the repository has no varnish 9.0"
  h env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "varnish=$version" >/dev/null
  echo "   Varnish Software's varnish: $version"
  run_fails foreign-series \
    "varnish: installed varnish $version is series 9.0, varnish_version is 9.1; a series change is a separate, deliberate step" \
    converge.yml -e "@$out/foreign-vars.json"
  unchanged_refused foreign-series
  [ "$(h dpkg-query -W -f='${Version}' varnish)" = "$version" ] || fail "foreign: the refused run changed varnish $version"
  no_role_files foreign
}

# All scenarios by default; "tests/varnish/run.sh invalid" runs only these.
scenarios="${*:-invalid valid install badvcl foreign}"
for ubuntu in $releases; do
  host_state=
  for scenario in $scenarios; do
    case "$scenario" in
      invalid) test_invalid "$ubuntu" ;;
      valid) test_valid "$ubuntu" ;;
      install) test_install "$ubuntu" ;;
      badvcl) test_badvcl "$ubuntu" ;;
      foreign) test_foreign "$ubuntu" ;;
      *) fail "unknown scenario $scenario (invalid, valid, install, badvcl, foreign)" ;;
    esac
  done
  cleanup
  host=
done

noix_done
echo "== all varnish tests passed"
