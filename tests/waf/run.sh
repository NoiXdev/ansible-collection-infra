#!/usr/bin/env bash
# End-to-end test of the waf role on a throwaway systemd host per Ubuntu
# release, with Docker inside (the docker role). Attack payloads go only to
# the suite's own containers, and no port is published on this machine: every
# probe runs inside the test host.
#
# The scenario "refusals" runs the role with one wrong setting per class of
# the role's refusals (and once without the docker CLI): each run must fail
# with a message naming the variable and the site, before the role changes
# anything (no /opt/waf).
#
# WAF_UBUNTU selects the releases (default "24.04 26.04");
# NOIXDEV_INFRA_WAF_TESTS selects scenarios (see the end of the file);
# KEEP=1 leaves the test hosts running.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
out="$tests/output/waf"
releases="${WAF_UBUNTU:-24.04 26.04}"
# The test host the helpers act on, and every host this run started (cleanup
# removes them all).
host=
started=

cleanup() {
  local name
  [ "${KEEP:-0}" = 1 ] && return 0
  for name in $started; do docker rm -f -v "$name" >/dev/null 2>&1 || true; done
  started=
}
# shellcheck source=/dev/null
. "$here/../lib/suite.sh"
noix_exit_guard

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
noix_link_collection "$root" "$tests/output"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"

fail() { echo "$*" >&2; exit 1; }

# h <cmd...>: run in the test host; hi: the same with this script's stdin.
h() { docker exec "$host" "$@"; }
hi() { docker exec -i "$host" "$@"; }

# play <log name> [-e ...]: the test host's playbook; its output goes to
# $out/<log name>.log.
play() {
  local name="$1"
  shift
  ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$here/converge.yml" "$@" >"$out/$name.log" 2>&1
}
# converge [-e ...]: play, which must succeed.
converge() {
  play converge "$@" || { cat "$out/converge.log" >&2; fail "converge failed"; }
}
# converge_unchanged [-e ...]: the same again, which must change nothing.
# shellcheck disable=SC2120
converge_unchanged() {
  converge "$@"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/converge.log" \
    || { cat "$out/converge.log" >&2; fail "the repeated converge changed something"; }
}
# role_fails <name> [-e ...]: the waf role alone (no setup), which must fail;
# its output goes to $out/<name>.log.
role_fails() {
  local name="$1"
  shift
  if play "$name" -e test_setup=false -e test_waf=true "$@"; then
    cat "$out/$name.log" >&2
    fail "run $name succeeded but must fail"
  fi
}
# expect_in_log <name> <text>: $out/<name>.log holds the text.
expect_in_log() {
  grep -qF -- "$2" "$out/$1.log" || { cat "$out/$1.log" >&2; fail "$1.log lacks: $2"; }
}
# untouched: the role changed nothing on the host before it refused.
untouched() { h test ! -e /opt/waf || fail "waf touched the host before checking its settings"; }
# refused <name> <text> [-e ...]: role_fails, then expect_in_log and untouched.
refused() {
  local name="$1" text="$2"
  shift 2
  role_fails "$name" "$@"
  expect_in_log "$name" "$text"
  untouched
}

# probe <host header> <path> [curl args...]: the HTTP status of a request
# from inside the test host to its port 80 (000 when nothing answers).
probe() {
  local host_header="$1" path="$2"
  shift 2
  h curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H "Host: $host_header" "$@" "http://127.0.0.1$path" || true
}

# start_host <ubuntu> <name>: a fresh systemd host noixdev-infra-<name>-<ubuntu>
# with Docker, which the helpers then act on.
start_host() {
  local ubuntu="$1"
  host="noixdev-infra-$2-$ubuntu"
  docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  started="$started $host"
  # The anonymous volumes give the inner Docker a file system it can mount
  # overlays on; "docker rm -v" removes them with the host. No port is
  # published: the probes run inside the host.
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd \
    --name "$host" "noixdev-infra-host:$ubuntu" >/dev/null
  until (h systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
  # The image's policy-rc.d (exit 101) keeps package scripts from starting
  # services; servers have none.
  h rm -f /usr/sbin/policy-rc.d

  echo "== test host $host"
  converge
  # shellcheck disable=SC2119
  converge_unchanged
}

# one_site [json members]: waf_sites with one valid traefik mode site "a",
# plus the given members (which may override its own).
one_site() {
  printf '{"waf_sites": [{"name": "a", "domains": ["a.test"], "backend": "http://b:80"%s}]}' "${1:+, $1}"
}
# exclusion <json members>: one_site with one exclusion for /x/.
exclusion() { one_site "\"exclusions\": [{\"path\": \"/x/\", $1}]"; }

test_refusals() {
  echo "== refusals (ubuntu $1)"
  refused dup-name 'waf: waf_sites has more than one entry named a' \
    -e '{"waf_sites": [{"name": "a", "domains": ["a.test"], "backend": "http://b:80"},
                       {"name": "a", "domains": ["b.test"], "backend": "http://b:80"}]}'
  refused dup-domain 'waf: waf_sites entry b lists the domain a.test, which entry a lists too' \
    -e '{"waf_sites": [{"name": "a", "domains": ["a.test"], "backend": "http://b:80"},
                       {"name": "b", "domains": ["b.test", "a.test"], "backend": "http://b:80"}]}'
  refused upper-domain 'waf: waf_sites entry a has invalid domains (Shop.example.test)' \
    -e "$(one_site '"domains": ["Shop.example.test"]')"
  refused no-backend 'waf: waf_sites entry a has no backend' \
    -e '{"waf_sites": [{"name": "a", "domains": ["a.test"]}]}'
  refused ftp-backend 'waf: waf_sites entry a has the backend ftp://x; a backend is' \
    -e "$(one_site '"backend": "ftp://x"')"
  refused host-backend 'waf: waf_sites entry a has the backend http://10.0.0.1:80; in host mode' \
    -e waf_mode=host -e "$(one_site '"backend": "http://10.0.0.1:80"')"
  refused host-own-port "waf: waf_sites entry a has the backend http://127.0.0.1:8930, the WAF's own waf_host_port" \
    -e waf_mode=host -e "$(one_site '"backend": "http://127.0.0.1:8930"')"
  refused host-routers 'waf: waf_sites entry a has routers, which host mode does not use' \
    -e waf_mode=host -e "$(one_site '"backend": "http://127.0.0.1:8931", "routers": [{"entrypoints": ["web"]}]')"
  refused detection-paranoia 'waf: waf_sites entry a has detection_paranoia 1 below its paranoia 2' \
    -e "$(one_site '"paranoia": 2, "detection_paranoia": 1')"
  refused paranoia 'waf: waf_sites entry a has paranoia 5' \
    -e "$(one_site '"paranoia": 5')"
  refused mode 'waf: waf_sites entry a has the mode learn' \
    -e "$(one_site '"mode": "learn"')"
  refused bypass-relative 'waf: waf_sites entry a has invalid bypass_paths (v2/)' \
    -e "$(one_site '"bypass_paths": ["v2/"]')"
  refused bypass-dots 'waf: waf_sites entry a has invalid bypass_paths (/a/../b)' \
    -e "$(one_site '"bypass_paths": ["/a/../b"]')"
  refused method 'waf: waf_sites entry a has invalid allowed_methods (GE T)' \
    -e "$(one_site '"allowed_methods": ["GE T"]')"
  refused content-type 'waf: waf_sites entry a has invalid allowed_content_types (octet)' \
    -e "$(one_site '"allowed_content_types": ["octet"]')"
  refused rule-id 'waf: waf_sites entry a has invalid remove_ids (abc) in the exclusion for /x/' \
    -e "$(exclusion '"remove_ids": ["abc"]')"
  refused target 'waf: waf_sites entry a has invalid remove_targets (932160) in the exclusion for /x/' \
    -e "$(exclusion '"remove_targets": [{"id": 932160, "target": "ARGS:\"x"}]')"
  refused tag 'waf: waf_sites entry a has invalid remove_tags (attack rce) in the exclusion for /x/' \
    -e "$(exclusion '"remove_tags": ["attack rce"]')"
  refused image 'waf: waf_image owasp/modsecurity-crs:4.25.2-nginx-lts needs both a tag and a digest' \
    -e waf_image=owasp/modsecurity-crs:4.25.2-nginx-lts
  refused address-range 'waf: waf_traefik_address 172.31.255.10 lies inside traefik_network_range 172.31.255.0/25' \
    -e waf_traefik_address=172.31.255.10 -e traefik_network_range=172.31.255.0/25
  refused address-subnet 'waf: waf_traefik_address 10.0.0.5 lies outside traefik_network_subnet 172.31.255.0/24' \
    -e waf_traefik_address=10.0.0.5 -e traefik_network_subnet=172.31.255.0/24
  refused include 'waf: waf_rules_before contains an Include' \
    -e '{"waf_rules_before": "Include /etc/passwd"}'
  refused unknown-key 'waf: waf_sites entry a has unknown keys (colour)' \
    -e "$(one_site '"colour": "red"')"
  # /usr/bin holds the docker CLI of the docker role's packages.
  refused no-docker 'The docker CLI was not found' \
    -e '{"test_environment": {"PATH": "/usr/sbin:/sbin"}}'
  expect_in_log no-docker 'Docker is not installed or not running'
}

# All scenarios by default; NOIXDEV_INFRA_WAF_TESTS="refusals" runs only these.
scenarios="${NOIXDEV_INFRA_WAF_TESTS:-refusals traefik report host}"
for ubuntu in $releases; do
  start_host "$ubuntu" waf
  for scenario in $scenarios; do
    case "$scenario" in
      refusals) test_refusals "$ubuntu" ;;
      *) fail "unknown scenario $scenario (refusals)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all waf tests passed"
