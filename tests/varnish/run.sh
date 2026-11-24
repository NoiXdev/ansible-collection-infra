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
# request with it reaches the backend; a second run changes nothing, a
# malformed key is refused before any change, a deleted key is created anew,
# and without any site the VCL still compiles.
#
# The scenario "badvcl" runs a copy of the collection whose VCL does not
# compile and checks that the run fails before the running VCL is touched,
# with --check too (which compiles the new VCL and changes nothing).
#
# The scenario "cache" checks the cache rules of the generic and typo3
# profiles and the microcache (what is cached, what passes, the cookies and
# query parameters that do not count, HEAD, gzip and Range, the headers
# clients get), and "grace" that stale pages are served while the backend
# fails: 30 s for a site without a health probe, well beyond for a site whose
# probe says sick.
#
# The scenario "purge" checks the invalidation requests (PURGE of a URL or of
# xkey tags, BAN of a URL regex or of X-Cache-Tags): only with the site's
# token and never with the front key, only on that site's objects, never
# with input that could change the ban, and no longer for a site taken out
# of varnish_sites.
#
# The scenario "shopware" checks the shopware profile (Shopware 6.7's VCL):
# the variants by sw-cache-hash and sw-currency (not by the session), the
# pass on a hit for logged-in or cart-filled visitors, the paths that always
# pass, shared media, the cart widget answered by Varnish, ESI, the app's
# bypass header, the Cache-Control clients get, and PURGE of xkey tags and of
# a URL on that site only.
#
# The scenario "nginx" runs php, varnish and nginx on one host
# (tests/varnish/nginx.yml): two PHP sites with varnish: true and one
# without. It checks hits through nginx (in its access log, never at the
# client), the client's address and scheme in PHP, that the front key never
# reaches PHP, 405 for PURGE and BAN through nginx, stale pages while the
# site's pool is stopped, uncached pages while Varnish is stopped, the site
# without varnish as before, 403 after a new front key until nginx runs, and
# the refusals while Varnish does not answer or its key is missing.
#
# The scenario "waf" (it needs the waf role) adds a site with waf and
# varnish: the WAF in front of Varnish, nginx's inner block its fallback.
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
# Each release writes to tests/output/varnish-<release> (set in the loop at the end), so
# tests/all.sh can run the entries varnish-24.04 and varnish-26.04 at the same time.
out="$tests/output/varnish"
releases="${VARNISH_UBUNTU:-24.04 26.04}"
host=
# What the test host has: clean (nothing of the role), varnish (runs of the
# role), nginx (the nginx scenario's php, varnish and nginx) or foreign (a
# varnish the role refuses).
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
  # The anonymous volumes give Docker inside (the nginx scenario's error
  # pages, the WAF) a file system it can mount overlays on; "docker rm -v"
  # removes them with the host.
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd \
    --name "$host" "noixdev-infra-host:$ubuntu" >/dev/null
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

# start_backend [<unit> <port>]: tests/varnish/backend.py on 127.0.0.1:8931
# of the test host (a transient unit noixdev-test-backend, or the unit and
# port given), curl for the probes and tests/varnish/wsclient.py.
start_backend() {
  local tries=0 unit="${1:-noixdev-test-backend}" port="${2:-8931}"
  h sh -c 'command -v curl >/dev/null' || apt_install curl
  docker cp -q "$here/backend.py" "$host:/usr/local/bin/noixdev-test-backend"
  docker cp -q "$here/wsclient.py" "$host:/usr/local/bin/noixdev-test-wsclient"
  h systemctl is-active -q "$unit" \
    || h systemd-run -q --unit "$unit" python3 /usr/local/bin/noixdev-test-backend serve 127.0.0.1 "$port"
  until h curl -fsS -o /dev/null "http://127.0.0.1:$port/health" 2>/dev/null; do
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

# role_files: the checksums of the role's files on the test host.
role_files() {
  h sha256sum "$key" "$vcl" /etc/systemd/system/varnish.service.d/noixdev.conf /etc/apt/sources.list.d/varnish.sources \
    /etc/apt/preferences.d/varnish /etc/apt/keyrings/varnish.asc /etc/apt/apt.conf.d/52noixdev-varnish
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
  local before after answer target files pid
  echo "== install: Varnish Software's 9.1 on the loopback address, behind the front key (ubuntu $1)"
  use_host "$1" varnish
  start_backend
  sites_vars install-vars.json a b
  host_state=varnish
  run_ok install converge.yml -e "@$out/install-vars.json"
  run_ok install-verify verify.yml
  # For the record: the modes in Varnish's working directory.
  h sh -c 'ls -la /var/lib/varnish /var/lib/varnish/varnishd /var/lib/varnish/varnishd/vcl_*' >"$out/install-workdir-$1.txt"

  echo "== install: the nginx role's probe of a front hop is answered without the key, nothing else is"
  # GET or HEAD of /.noix-front-probe exactly: 204 from Varnish itself, never
  # the backend's, without the WAF's header.
  answer="$(h curl -sS -i --max-time 10 -H 'Host: a.test' http://127.0.0.1:6081/.noix-front-probe | tr -d '\r')"
  case "$answer" in "HTTP/1.1 204 "*) ;; *) fail "install: GET of the probe got: $answer" ;; esac
  ! printf '%s\n' "$answer" | grep -qi '^X-Noix-Waf:' || fail "install: the probe's answer has X-Noix-Waf"
  answer="$(h curl -sS -I -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:6081/.noix-front-probe)"
  [ "$answer" = 204 ] || fail "install: HEAD of the probe got $answer, not 204"
  for target in '/.noix-front-probe?x=1' /.noix-front-probe/ /other; do
    answer="$(h curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: a.test' "http://127.0.0.1:6081$target")"
    [ "$answer" = 403 ] || fail "install: GET $target without the key got $answer, not 403"
  done
  answer="$(h curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST http://127.0.0.1:6081/.noix-front-probe)"
  [ "$answer" = 403 ] || fail "install: POST of the probe without the key got $answer, not 403"
  [ -z "$(h varnishlog -d -g request -q 'BereqURL ~ "noix-front-probe"')" ] || fail "install: the probe reached the backend"

  echo "== install: a second run changes nothing and keeps the key"
  before="$(h sha256sum "$key")"
  run_ok install-again converge.yml -e "@$out/install-vars.json"
  unchanged install-again
  [ "$(h sha256sum "$key")" = "$before" ] || fail "install: the second run changed the front key"

  echo "== install: a malformed key is refused before any change"
  # A new cache size would change the drop-in (and restart Varnish): the
  # refusal comes first, and the role's files and the running Varnish stay.
  h cp -p "$key" /root/good-front.key
  h sh -c "printf 'not-a-front-key\\n' >$key"
  files="$(role_files)"
  pid="$(h systemctl show -P MainPID varnish)"
  run_fails install-bad-key "varnish: $key is not 64 hex digits; remove it, and the next run creates a new one" \
    converge.yml -e "@$out/install-vars.json" -e varnish_memory=1g
  unchanged_refused install-bad-key
  [ "$(role_files)" = "$files" ] || fail "install: the refused run changed the role's files"
  [ "$(h systemctl show -P MainPID varnish)" = "$pid" ] || fail "install: the refused run restarted Varnish"
  h mv /root/good-front.key "$key"
  run_ok install-good-key converge.yml -e "@$out/install-vars.json"
  unchanged install-good-key

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

  echo "== install: without sites the VCL compiles, and every request passes"
  printf '%s\n' '{"test_varnish": true, "varnish_sites": []}' >"$out/install-nosites-vars.json"
  run_ok install-nosites converge.yml -e "@$out/install-nosites-vars.json"
  h sh -c "! grep -q 'X-Noix-Site ==' $vcl" || fail "install: the VCL without sites still has site blocks"
  run_ok install-nosites-verify verify.yml
}

# loaded_vcls: each loaded VCL's status (active or available) and name. The
# other columns of vcl.list change on their own: the busy count is the number
# of requests and connections that still hold a VCL, and an unused VCL cools
# down after a while.
loaded_vcls() { h varnishadm vcl.list | awk '{print $1, $NF}'; }

test_badvcl() {
  local before_vcl before_list copy template
  echo "== badvcl: a VCL that does not compile fails the run, and the running one stays (ubuntu $1)"
  use_host "$1" varnish
  start_backend
  sites_vars badvcl-vars.json a b
  host_state=varnish
  run_ok badvcl converge.yml -e "@$out/badvcl-vars.json"
  before_vcl="$(h sha256sum "$vcl")"
  before_list="$(loaded_vcls)"

  # A copy of the collection whose VCL has an unknown word on the line with
  # the purge tokens (the compiler's message shows that line), run with a
  # third site so that the VCL would change. Every role: converge.yml names
  # the nginx scenario's too.
  copy="$out/badvcl-collection"
  rm -rf "$copy"
  mkdir -p "$copy/ansible_collections/noixdev/infra"
  cp -R "$root/galaxy.yml" "$root/meta" "$root/plugins" "$root/roles" "$copy/ansible_collections/noixdev/infra/"
  template="$copy/ansible_collections/noixdev/infra/roles/varnish/templates/noixdev.vcl.j2"
  sed 's/\(req.http.X-Purge-Token == "{{ site.purge_token }}"\)/\1 \&\& noixdev_unknown_keyword/' "$template" >"$template.new"
  mv "$template.new" "$template"
  grep -q noixdev_unknown_keyword "$template" || fail "badvcl: the copy's VCL template was not broken"
  sites_vars badvcl-c-vars.json a b c
  ANSIBLE_COLLECTIONS_PATH="$copy:$ANSIBLE_COLLECTIONS_PATH" run_fails badvcl-broken \
    "varnish: the new VCL does not compile" converge.yml -e "@$out/badvcl-c-vars.json"
  grep -qF "Symbol not found: 'noixdev_unknown_keyword'" "$out/badvcl-broken.log" \
    || fail "badvcl: the message does not show the compiler's error"

  echo "== badvcl: --check compiles the new VCL too, and changes nothing"
  ANSIBLE_COLLECTIONS_PATH="$copy:$ANSIBLE_COLLECTIONS_PATH" run_fails badvcl-broken-check \
    "varnish: the new VCL does not compile" converge.yml --check -e "@$out/badvcl-c-vars.json"
  grep -qF "Symbol not found: 'noixdev_unknown_keyword'" "$out/badvcl-broken-check.log" \
    || fail "badvcl: --check did not compile the new VCL"
  run_ok badvcl-check converge.yml --check -e "@$out/badvcl-c-vars.json"
  grep -q 'TASK \[noixdev.infra.varnish : Move the new VCL into place\]' "$out/badvcl-check.log" \
    || fail "badvcl: --check with a changed VCL did not get to the move"

  [ "$(h sha256sum "$vcl")" = "$before_vcl" ] || fail "badvcl: the failed and the --check runs changed $vcl"
  [ "$(loaded_vcls)" = "$before_list" ] || fail "badvcl: the failed and the --check runs changed the loaded VCLs"
  h test ! -e "$vcl.new" || fail "badvcl: the failed or the --check runs left $vcl.new"
  run_ok badvcl-verify verify.yml
  no_key_in_logs
  grep -qF '<purge token>' "$out/badvcl-broken.log" || fail "badvcl: the message does not show the line of the tokens"
  no_token_in_logs 0123456789abcdef0123456789abcdef fedcba9876543210fedcba9876543210 cccccccccccccccccccccccccccccccc \
    "$(printf 'a:%s' 0123456789abcdef0123456789abcdef | base64)"
}

# req <site> <host> <path> [<curl option>...]: a request through Varnish with
# the front key, X-Noix-Site <site> and Host <host> (GET unless the options
# say otherwise). Sets status, cache (X-Noix-Cache), headers and body, and
# checks what every answer must hold: X-Cache equals X-Noix-Cache on the
# debug site (debug_site) and is absent elsewhere, and no internal header
# (X-Noix-* but X-Noix-Cache, xkey, X-Cache-Tags, sw-invalidation-states)
# reaches the client.
debug_site=
req() {
  local site="$1" vhost="$2" path="$3" answer xcache
  shift 3
  answer="$(h sh -c 'site="$1" vhost="$2" path="$3"; shift 3
    exec curl -sS -i --max-time 10 -H "X-Noix-Front: $(cat '"$key"')" -H "X-Noix-Site: $site" -H "Host: $vhost" \
      "$@" "http://127.0.0.1:6081$path"' sh "$site" "$vhost" "$path" "$@" | tr -d '\r')"
  headers="${answer%%$'\n\n'*}"
  body=
  case "$answer" in *$'\n\n'*) body="${answer#*$'\n\n'}" ;; esac
  status="$(printf '%s\n' "$headers" | sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p')"
  cache="$(printf '%s\n' "$headers" | sed -n 's/^[Xx]-[Nn]oix-[Cc]ache: //p')"
  xcache="$(printf '%s\n' "$headers" | sed -n 's/^[Xx]-[Cc]ache: //p')"
  if [ "$site" = "$debug_site" ]; then
    [ "$xcache" = "$cache" ] || fail "$site $vhost$path: X-Cache is '$xcache', X-Noix-Cache '$cache'"
  else
    [ -z "$xcache" ] || fail "$site $vhost$path: X-Cache '$xcache' on a site without debug_header"
  fi
  if printf '%s\n' "$headers" | grep -Eiq '^(X-Noix-(Site|Url|Host|Front)|xkey|X-Cache-Tags|sw-invalidation-states):'; then
    fail "$site $vhost$path: an internal header reached the client: $(printf '%s\n' "$headers" | grep -Ei '^(X-Noix|xkey|X-Cache-Tags|sw-invalidation-states)' | grep -vi '^X-Noix-Cache:' | cut -d: -f1 | tr '\n' ' ')"
  fi
}
# expect <what> <status> <cache> [<body>]: the last answer of req.
expect() {
  [ "$status" = "$2" ] || fail "$1: status $status, expected $2"
  [ "$cache" = "$3" ] || fail "$1: X-Noix-Cache '$cache', expected '$3'"
  [ $# -lt 4 ] || [ "$body" = "$4" ] || fail "$1: body '$body', expected '$4'"
}

# The cache rules of the generic and typo3 profiles and of the microcache (and
# the shopware profile's tracking parameters), in
# front of tests/varnish/backend.py: its count=<n> shows how often a request
# reached it.
test_cache() {
  local p c q site gz plain answer
  echo "== cache: what the app allows is cached, per site (ubuntu $1)"
  use_host "$1" varnish
  start_backend
  printf '%s\n' '{"test_varnish": true, "varnish_sites": [
    {"name": "a", "purge_token": "0123456789abcdef0123456789abcdef", "debug_header": true, "strip_cookies": ["consent"]},
    {"name": "b", "profile": "typo3", "purge_token": "fedcba9876543210fedcba9876543210"},
    {"name": "m", "purge_token": "mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm", "microcache": 5},
    {"name": "s", "profile": "shopware", "purge_token": "ssssssssssssssssssssssssssssssss"}]}' >"$out/cache-vars.json"
  host_state=varnish
  run_ok cache converge.yml -e "@$out/cache-vars.json"
  debug_site=a

  # Varnish sorts the query before the backend sees it; the paths here are
  # sorted already, so the backend's path= is the path asked for.
  p='/c/page?cc=public,max-age=60&tags=;p1;&xkey=t1'
  req a a.test "$p"
  expect "a page the app made cacheable" 200 MISS "count=1 host=a.test path=$p"
  req a a.test "$p"
  expect "the page again" 200 HIT "count=1 host=a.test path=$p"
  req a A.TEST "$p"
  expect "the page with the host in capitals" 200 HIT "count=1 host=a.test path=$p"
  req a a.test:443 "$p"
  expect "the page with a port in the host" 200 HIT "count=1 host=a.test path=$p"

  echo "== cache: Shopware's invalidation states stay inside on every profile"
  for site in a b; do
    p='/c/inv?cc=public,max-age=60&inv=logged-in'
    req "$site" "$site.test" "$p"
    expect "a page with sw-invalidation-states on $site" 200 MISS "count=1 host=$site.test path=$p"
    req "$site" "$site.test" "$p"
    expect "that page again on $site" 200 HIT "count=1 host=$site.test path=$p"
  done

  echo "== cache: HEAD, gzip and Range on cached objects"
  p='/c/head?cc=public,max-age=60'
  req a a.test "$p" -I
  expect "HEAD of a new page" 200 MISS ""
  req a a.test "$p"
  expect "GET after HEAD" 200 HIT "count=1 host=a.test path=$p"
  p='/c/gz?cc=public,max-age=60&gzip=1'
  gz="$(h sh -c 'curl -sS --max-time 10 -H "X-Noix-Front: $(cat '"$key"')" -H "X-Noix-Site: a" -H "Host: a.test" \
    -H "Accept-Encoding: gzip" "http://127.0.0.1:6081$1" | gunzip' sh "$p")" || fail "the gzip client did not get gzip"
  plain="$(h sh -c 'curl -sS --max-time 10 -H "X-Noix-Front: $(cat '"$key"')" -H "X-Noix-Site: a" -H "Host: a.test" \
    "http://127.0.0.1:6081$1"' sh "$p")"
  case "$gz" in "count="[0-9]*" host=a.test path=$p") ;; *) fail "the gzip client got '$gz'" ;; esac
  case "$plain" in "count="[0-9]*" host=a.test path=$p") ;; *) fail "the plain client got '$plain'" ;; esac
  p='/c/range?cc=public,max-age=60&size=1000'
  req a a.test "$p"
  expect "a page of 1000 bytes" 200 MISS
  [ "${#body}" = 1000 ] || fail "the page of 1000 bytes has ${#body}"
  req a a.test "$p" -H 'Range: bytes=0-9'
  expect "bytes 0-9 of the cached page" 206 HIT "count=1 ho"
  printf '%s\n' "$headers" | grep -qix 'Content-Range: bytes 0-9/1000' || fail "the range answer has no Content-Range bytes 0-9/1000"

  echo "== cache: the backend never sees the front key"
  req a a.test '/c/echo?cc=public,max-age=60&echo=X-Noix-Front'
  expect "a cacheable page" 200 MISS
  ! printf '%s\n' "$headers" | grep -qi '^X-Echo:' || fail "the backend got X-Noix-Front on a fetch"
  req a a.test '/c/echo?echo=X-Noix-Front' -H 'Cookie: session=1'
  expect "a page with a session cookie" 200 PASS
  ! printf '%s\n' "$headers" | grep -qi '^X-Echo:' || fail "the backend got X-Noix-Front on a pass"
  req a a.test '/c/echo?echo=X-Noix-Site' -H 'Cookie: session=1'
  printf '%s\n' "$headers" | grep -qix 'X-Echo: a' || fail "the backend's echo does not work"

  echo "== cache: a WebSocket upgrade with the front key is piped to the backend, without the key"
  answer="$(h sh -c 'exec python3 /usr/local/bin/noixdev-test-wsclient 127.0.0.1 6081 "/ws?echo=X-Noix-Front" \
    "Host: a.test" "X-Noix-Site: a" "X-Noix-Front: $(cat '"$key"')"' | tr -d '\r')" || fail "the WebSocket through Varnish failed: $answer"
  case "$answer" in "HTTP/1.1 101 "*) ;; *) fail "the WebSocket through Varnish got: $answer" ;; esac
  printf '%s\n' "$answer" | grep -qx 'echo: noix-ping' || fail "the WebSocket through Varnish echoed nothing: $answer"
  ! printf '%s\n' "$answer" | grep -qi '^X-Echo:' || fail "the backend got X-Noix-Front on the pipe"
  answer="$(h python3 /usr/local/bin/noixdev-test-wsclient 127.0.0.1 6081 /ws "Host: a.test" "X-Noix-Site: a" | tr -d '\r' || true)"
  case "$answer" in "HTTP/1.1 403 "*) ;; *) fail "a WebSocket upgrade without the front key got: $answer" ;; esac

  echo "== cache: cookies"
  p='/c/cookie?cc=public,max-age=60'
  req a a.test "$p"
  expect "a cacheable page" 200 MISS "count=1 host=a.test path=$p"
  req a a.test "$p" -H 'Cookie: session=1'
  expect "with a session cookie" 200 PASS "count=2 host=a.test path=$p"
  req a a.test "$p" -H 'Cookie: _ga=1; _pk_id.1=2'
  expect "with tracking cookies" 200 HIT "count=1 host=a.test path=$p"
  req a a.test "$p" -H 'Cookie: techaro.lol-anubis-auth-0a1b2c3d=x; techaro.lol-anubis-cookie-verification-0a1b2c3d=y'
  expect "with Anubis's cookies" 200 HIT "count=1 host=a.test path=$p"
  req a a.test "$p" -H 'Cookie: techaroXlol-anubis-auth=x'
  expect "with a cookie that only looks like Anubis's" 200 PASS "count=3 host=a.test path=$p"
  req a a.test "$p" -H 'Cookie: consent=yes'
  expect "with the consent cookie the site strips" 200 HIT "count=1 host=a.test path=$p"
  req a a.test "$p" -H 'Cookie: _ga=1; session=1'
  expect "with a tracking and a session cookie" 200 PASS "count=4 host=a.test path=$p"
  req b b.test "$p"
  expect "a cacheable page of the typo3 site" 200 MISS "count=1 host=b.test path=$p"
  req b b.test "$p" -H 'Cookie: _ga=1'
  expect "typo3 with a tracking cookie" 200 HIT "count=1 host=b.test path=$p"
  req b b.test "$p" -H 'Cookie: fe_typo_user=1'
  expect "typo3 with fe_typo_user" 200 PASS "count=2 host=b.test path=$p"
  req b b.test "$p" -H 'Cookie: be_typo_user=1; _ga=1'
  expect "typo3 with be_typo_user" 200 PASS "count=3 host=b.test path=$p"
  req b b.test "$p" -H 'Cookie: consent=yes'
  expect "typo3 with a consent cookie it does not strip" 200 PASS "count=4 host=b.test path=$p"

  echo "== cache: private, no cache headers, Set-Cookie, Authorization, POST, 5xx and other sites pass"
  for p in '/c/private?cc=private' '/c/nocc' '/c/nocc-cookie?sc=s%3D1' '/c/vary?cc=public,max-age=60&vary=%2A' \
    '/c/500?cc=public,max-age=60&status=500' '/c/sc?cc=public,max-age=60&sc=s%3D1'; do
    req a a.test "$p"
    [ "$cache" != HIT ] || fail "$p was a HIT on the first request"
    req a a.test "$p"
    [ "$cache" != HIT ] || fail "$p was a HIT"
    case "$body" in "count=2 host=a.test path=$p") ;; *) fail "$p did not reach the backend twice: '$body'" ;; esac
  done
  p='/c/auth?cc=public,max-age=60'
  req a a.test "$p" -H 'Authorization: Basic dXNlcjpwYXNz'
  expect "with Authorization" 200 PASS "count=1 host=a.test path=$p"
  req a a.test "$p" -H 'Authorization: Basic dXNlcjpwYXNz'
  expect "with Authorization again" 200 PASS "count=2 host=a.test path=$p"
  p='/c/post?cc=public,max-age=60'
  req a a.test "$p" -X POST -d x=1
  expect "a POST" 200 PASS "count=1 host=a.test path=$p"
  req a a.test "$p" -X POST -d x=1
  expect "a POST again" 200 PASS "count=2 host=a.test path=$p"
  p='/c/zzz?cc=public,max-age=60'
  req zzz a.test "$p"
  expect "a site that is not in varnish_sites" 200 PASS "count=1 host=a.test path=$p"
  req zzz a.test "$p"
  expect "that site again" 200 PASS "count=2 host=a.test path=$p"

  echo "== cache: tracking parameters and the order of the query do not count"
  c='cc=public,max-age=60'
  req a a.test "/c/q?a=1&b=2&$c"
  expect "a query" 200 MISS "count=1 host=a.test path=/c/q?a=1&b=2&$c"
  req a a.test "/c/q?utm_source=x&b=2&$c&a=1&gclid=y"
  expect "the query reordered, with tracking parameters" 200 HIT "count=1 host=a.test path=/c/q?a=1&b=2&$c"
  req a a.test "/c/q?xutm_source=x&a=1&b=2&$c"
  expect "a parameter that only ends like a tracking one" 200 MISS "count=1 host=a.test path=/c/q?a=1&b=2&$c&xutm_source=x"
  # Shopware's short names (kw, pa, pp ...) may be content elsewhere: only the
  # shopware profile removes them.
  req a a.test "/c/kw?$c&kw=x"
  expect "a search for x" 200 MISS "count=1 host=a.test path=/c/kw?$c&kw=x"
  req a a.test "/c/kw?$c&kw=y"
  expect "a search for y" 200 MISS "count=1 host=a.test path=/c/kw?$c&kw=y"
  req a a.test "/c/kw?$c&kw=x"
  expect "the search for x again" 200 HIT "count=1 host=a.test path=/c/kw?$c&kw=x"
  req s s.test "/c/kw?a=1&$c"
  expect "a page of the shopware site" 200 MISS "count=1 host=s.test path=/c/kw?a=1&$c"
  req s s.test "/c/kw?kw=x&a=1&pa=2&$c"
  expect "the page with Shopware-only tracking parameters" 200 HIT "count=1 host=s.test path=/c/kw?a=1&$c"

  echo "== cache: the microcache keeps private and header-less pages for 5 s, and the app's TTL otherwise"
  p='/c/micro?cc=private'
  req m m.test "$p"
  expect "a private page of the microcache site" 200 MISS "count=1 host=m.test path=$p"
  req m m.test "$p"
  expect "the private page within 5 s" 200 HIT "count=1 host=m.test path=$p"
  req m m.test '/c/micro-long?cc=public,max-age=60'
  expect "a page the app made cacheable" 200 MISS
  req m m.test '/c/micro-cookie?cc=private&sc=s%3D1'
  expect "a private page with Set-Cookie" 200 PASS "count=1 host=m.test path=/c/micro-cookie?cc=private&sc=s%3D1"
  req m m.test '/c/micro-cookie?cc=private&sc=s%3D1'
  expect "that page again" 200 PASS "count=2 host=m.test path=/c/micro-cookie?cc=private&sc=s%3D1"
  req m m.test '/c/micro-500?cc=private&status=500'
  req m m.test '/c/micro-500?cc=private&status=500'
  expect "a private 500" 500 PASS "count=2 host=m.test path=/c/micro-500?cc=private&status=500"
  req m m.test "$p" -H 'Cookie: session=1'
  expect "the private page with a session cookie" 200 PASS "count=2 host=m.test path=$p"
  req m m.test /c/micro-nocc
  expect "a page without cache headers" 200 MISS "count=1 host=m.test path=/c/micro-nocc"
  req m m.test /c/micro-nocc
  expect "the page without cache headers within 5 s" 200 HIT "count=1 host=m.test path=/c/micro-nocc"
  # Surrogate-Control is meant for the cache: its no-store outranks the
  # microcache. The app's Cache-Control does not.
  for q in 'cc=private&surrogate=no-store' 'surrogate=no-store'; do
    req m m.test "/c/micro-sc?$q"
    expect "a page with Surrogate-Control no-store ($q)" 200 PASS "count=1 host=m.test path=/c/micro-sc?$q"
    req m m.test "/c/micro-sc?$q"
    expect "that page again ($q)" 200 PASS "count=2 host=m.test path=/c/micro-sc?$q"
  done
  req m m.test /c/micro-nostore?cc=no-store
  expect "a no-store page of the microcache site" 200 MISS "count=1 host=m.test path=/c/micro-nostore?cc=no-store"
  req m m.test /c/micro-nostore?cc=no-store
  expect "the no-store page within 5 s" 200 HIT "count=1 host=m.test path=/c/micro-nostore?cc=no-store"
  sleep 6
  req m m.test "$p"
  expect "the private page after 6 s" 200 MISS "count=3 host=m.test path=$p"
  req m m.test /c/micro-nocc
  expect "the page without cache headers after 6 s" 200 MISS "count=2 host=m.test path=/c/micro-nocc"
  req m m.test '/c/micro-long?cc=public,max-age=60'
  expect "the cacheable page after 6 s" 200 HIT "count=1 host=m.test path=/c/micro-long?cc=public,max-age=60"
  no_key_in_logs
  debug_site=
}

# inv <method> <path> [<curl option>...]: an invalidation request straight to
# Varnish, as an app on the host sends it (no front key; the option --front
# adds it, read inside the test host). Sets status and answer (headers and
# body), and checks that the answer holds none of the secrets in inv_secrets
# (the tokens, their Basic credentials, the front key).
inv_secrets=()
inv() {
  local method="$1" path="$2" secret
  shift 2
  answer="$(h sh -c 'method="$1" path="$2"; shift 2
    for a do
      shift
      if [ "$a" = --front ]; then set -- "$@" -H "X-Noix-Front: $(cat '"$key"')"; else set -- "$@" "$a"; fi
    done
    exec curl -sS -i --max-time 10 -X "$method" "$@" "http://127.0.0.1:6081$path"' sh "$method" "$path" "$@" | tr -d '\r')"
  status="$(printf '%s\n' "$answer" | sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p')"
  for secret in ${inv_secrets[@]+"${inv_secrets[@]}"}; do
    case "$answer" in *"$secret"*) fail "$method $path: the answer holds a secret" ;; esac
  done
}
# inv_expect <what> <status>: the last answer of inv.
inv_expect() {
  [ "$status" = "$2" ] || fail "$1: status $status, expected $2"
}
# seen <cache> <site> <host> <path>...: each path of the site is a 200 with
# X-Noix-Cache <cache>.
seen() {
  local want="$1" site="$2" vhost="$3" p
  shift 3
  for p in "$@"; do
    req "$site" "$vhost" "$p"
    expect "$site $vhost$p" 200 "$want"
  done
}

# no_token_in_logs <secret...>: no purge token (nor a Basic credential made of
# one) is in the logs of this suite, the test host's journal (varnishd's
# messages included) or Varnish's ban list. Never printed.
no_token_in_logs() {
  local secret logs
  for secret in "$@"; do
    logs="$(grep -lF -- "$secret" "$out"/*.log || true)"
    [ -z "$logs" ] || fail "a purge token is in the logs: $logs"
    if h sh -c 'journalctl --no-pager -o verbose | grep -qF -- "$1"' sh "$secret"; then
      fail "a purge token is in the journal of the test host"
    fi
    if h varnishadm ban.list | grep -qF -- "$secret"; then
      fail "a purge token is in Varnish's ban list"
    fi
  done
}

# Invalidation: PURGE of a URL or of xkey tags, BAN of a URL regex or of
# X-Cache-Tags, each with the site's token (Basic auth, or X-Noix-Site and
# X-Purge-Token), straight to Varnish and never with the front key; each acts
# on the objects of that site only, also where both sites use the same paths
# and tags.
test_purge() {
  local ta=0123456789abcdef0123456789abcdef tb=fedcba9876543210fedcba9876543210 c='cc=public,max-age=300'
  local s vhost p1 x1 x2 x3 cat other t1 t2 t3 all
  echo "== purge: invalidation needs the site's token and acts on that site only (ubuntu $1)"
  use_host "$1" varnish
  start_backend
  sites_vars purge-vars.json a b
  host_state=varnish
  run_ok purge converge.yml -e "@$out/purge-vars.json"
  inv_secrets=("$ta" "$tb" "$(printf 'a:%s' "$ta" | base64)" "$(printf 'b:%s' "$tb" | base64)" "$(h cat "$key")")

  # The same paths and tags on both sites (sorted queries, see test_cache).
  p1="/pu/p1?$c"
  x1="/pu/x1?$c&xkey=t1"
  x2="/pu/x2?$c&xkey=t2%20t9"
  x3="/pu/x3?$c&xkey=t3"
  cat="/pu/cat/x?$c"
  other="/pu/other?$c"
  t1="/pu/t1?$c&tags=;pages_12;"
  t2="/pu/t2?$c&tags=;pages_13;"
  t3="/pu/t3?$c&tags=;pages_12;pages_14;"
  all=("$p1" "$x1" "$x2" "$x3" "$cat" "$other" "$t1" "$t2" "$t3")
  for s in a b; do
    seen MISS "$s" "$s.test" "${all[@]}"
    seen HIT "$s" "$s.test" "${all[@]}"
  done
  seen MISS a www.a.test "$p1"
  seen HIT a www.a.test "$p1"

  echo "== purge: without the site's token 401, with the front key 403"
  inv PURGE "$p1"
  inv_expect "PURGE without credentials" 401
  printf '%s\n' "$answer" | grep -qi '^WWW-Authenticate: Basic ' || fail "the 401 has no WWW-Authenticate: Basic"
  inv BAN /
  inv_expect "BAN without credentials" 401
  inv PURGE "$p1" -u "b:$ta"
  inv_expect "PURGE with a's token as user b" 401
  inv BAN / -u "b:$ta"
  inv_expect "BAN with a's token as user b" 401
  inv PURGE "$p1" -u "zzz:$ta"
  inv_expect "PURGE as a site that is not in varnish_sites" 401
  inv PURGE "$p1" -u "a:${ta%?}"
  inv_expect "PURGE with a's token one character short" 401
  inv PURGE "$p1" -H 'X-Noix-Site: b' -H "X-Purge-Token: $ta"
  inv_expect "PURGE with X-Noix-Site b and a's token" 401
  inv BAN / -H 'X-Noix-Site: a' -H 'X-Purge-Token;'
  inv_expect "BAN with an empty X-Purge-Token" 401
  inv BAN / -H "X-Purge-Token: $ta"
  inv_expect "BAN with a's token and no site" 401
  # The front key: the request came through nginx (or the WAF).
  inv PURGE "$p1" -u "a:$ta" --front
  inv_expect "PURGE with a's token and the front key" 403
  inv BAN / -H 'X-Noix-Site: a' -H "X-Purge-Token: $ta" --front
  inv_expect "BAN with a's token and the front key" 403
  inv BAN / -u "a:$ta" -H 'X-Noix-Front: x'
  inv_expect "BAN with a's token and some X-Noix-Front" 403
  inv PURGE "$p1" --front
  inv_expect "PURGE with the front key and no credentials" 403
  seen HIT a a.test "${all[@]}"
  seen HIT b b.test "${all[@]}"

  echo "== purge: PURGE of a URL takes it out for every host of the site"
  # The URL is normalized as the stored one: tracking parameters out, sorted.
  inv PURGE "/pu/p1?utm_source=x&$c" -u "a:$ta"
  inv_expect "PURGE of p1 as a" 200
  seen MISS a A.TEST:443 "$p1"
  seen HIT a a.test "$p1"
  seen MISS a www.a.test "$p1"
  seen HIT b b.test "$p1"
  inv PURGE "$p1" -H 'Host: A.TEST:443' -H 'X-Noix-Site: a' -H "X-Purge-Token: $ta"
  inv_expect "PURGE of p1 as a, by header" 200
  seen MISS a a.test "$p1"
  seen HIT a A.TEST:443 "$p1"
  seen HIT a a.test "$x1" "$cat"
  seen HIT b b.test "$p1"
  inv PURGE / -u "a:$ta" --request-target '/pu/p1"x'
  inv_expect "PURGE of a URL with a quote" 400

  echo "== purge: PURGE of xkey tags takes out the site's objects with them"
  inv PURGE / -u "a:$ta" -H 'xkey: t1 t2'
  inv_expect "PURGE of t1 t2 as a" 200
  seen MISS a a.test "$x1" "$x2"
  seen HIT a a.test "$x3" "$p1"
  seen HIT b b.test "$x1" "$x2" "$x3"
  # a cannot name b's tags.
  inv PURGE / -u "a:$ta" -H 'xkey: b:t3'
  inv_expect "PURGE of b:t3 as a" 200
  seen HIT b b.test "$x3"
  seen HIT a a.test "$x3"
  for s in 'xkey: t1  t2' 'xkey: t1,t2' 'xkey: t1"' 'xkey;'; do
    inv PURGE / -u "a:$ta" -H "$s"
    inv_expect "PURGE with '$s'" 400
  done
  seen HIT a a.test "$x1" "$x2"

  echo "== purge: BAN of a URL regex"
  inv BAN /cat/ -u "a:$ta"
  inv_expect "BAN /cat/ as a" 200
  seen MISS a a.test "$cat"
  seen HIT a a.test "$other"
  seen HIT b b.test "$cat"
  inv BAN / -u "a:$ta"
  inv_expect "BAN / as a" 200
  seen MISS a a.test "${all[@]}"
  seen MISS a www.a.test "$p1"
  seen HIT b b.test "${all[@]}"

  echo "== purge: BAN of X-Cache-Tags"
  inv BAN / -H 'X-Noix-Site: b' -H "X-Purge-Token: $tb" -H 'X-Cache-Tags: ;pages_12;'
  inv_expect "BAN of ;pages_12; as b" 200
  seen MISS b b.test "$t1" "$t3"
  seen HIT b b.test "$t2" "$p1"
  seen HIT a a.test "$t1" "$t3"

  echo "== purge: invalid ban input is refused with 400, and bans nothing"
  inv BAN / -H 'X-Noix-Site: b' -H "X-Purge-Token: $tb" -H 'X-Cache-Tags: x" || true'
  inv_expect "BAN with a quote in X-Cache-Tags" 400
  inv BAN / -u "b:$tb" -H 'X-Cache-Tags;'
  inv_expect "BAN with an empty X-Cache-Tags" 400
  inv BAN '/pu/(' -u "b:$tb"
  inv_expect "BAN of a regex that does not compile" 400
  inv BAN '/pu/a%20b' -u "b:$tb"
  inv_expect "BAN of a URL regex with %" 400
  ! h varnishadm ban.list | grep -Eq '[|][|] true|/pu/[(]|a%20b' || fail "a refused ban is in the ban list"
  seen HIT b b.test "${all[@]}"
  seen HIT a a.test "${all[@]}"
  # A backslash is the regular expression's own.
  inv BAN / -u "b:$tb" -H "X-Cache-Tags: x\\"
  inv_expect "BAN of the tags x\\ (a regex that does not compile)" 400
  inv BAN / -u "b:$tb" -H 'X-Cache-Tags: ;pages_1\d;'
  inv_expect "BAN of the tags ;pages_1\\d; as b" 200
  seen MISS b b.test "$t1" "$t2" "$t3"
  seen HIT b b.test "$p1"
  seen HIT a a.test "$t1" "$t2" "$t3"
  # .* is every object of the site, with tags or without.
  inv BAN / -u "b:$tb" -H 'X-Cache-Tags: .*'
  inv_expect "BAN of the tags .* as b" 200
  seen MISS b b.test "${all[@]}"
  seen HIT a a.test "${all[@]}"
  no_key_in_logs
  no_token_in_logs "${inv_secrets[@]:0:4}"

  echo "== purge: a site taken out of varnish_sites loses its token, and its requests pass"
  sites_vars purge-a-vars.json a
  run_ok purge-a converge.yml -e "@$out/purge-a-vars.json"
  # The run reloaded the new VCL, and a reload of the service compiles one
  # more: each compiled VCL (with the tokens) stays closed to other users.
  h systemctl reload varnish
  run_ok purge-verify verify.yml
  inv PURGE "$p1" -u "b:$tb"
  inv_expect "PURGE as the removed site b" 401
  inv BAN / -H 'X-Noix-Site: b' -H "X-Purge-Token: $tb"
  inv_expect "BAN as the removed site b, by header" 401
  for vhost in b.test B.TEST; do
    req b "$vhost" "$p1"
    expect "the removed site's cached page ($vhost)" 200 PASS
  done
  inv PURGE "$p1" -u "a:$ta"
  inv_expect "PURGE of p1 as a, the site that stays" 200
  seen MISS a a.test "$p1"
  no_key_in_logs
  no_token_in_logs "${inv_secrets[@]:0:4}"
  inv_secrets=()
}

# header <line>: the last answer of req has the header line (case-insensitive
# name); no_header <name>: it has no such header.
header() {
  printf '%s\n' "$headers" | grep -qiFx -- "$1" || fail "no header '$1' in: $(printf '%s\n' "$headers" | tr '\n' '|')"
}
no_header() {
  ! printf '%s\n' "$headers" | grep -qi "^$1:" || fail "the header $1 reached the client"
}

# The shopware profile: Shopware 6.7's VCL (shopware/varnish-shopware) inside
# the role's frame, next to a generic site with the same paths.
test_shopware() {
  local ta=0123456789abcdef0123456789abcdef ts=ssssssssssssssssssssssssssssssss c='cc=public,s-maxage=60'
  local p x1 x2 never='Cache-Control: no-store, no-cache, must-revalidate, max-age=0'
  echo "== shopware: Shopware's cookies choose the variant, not the session (ubuntu $1)"
  use_host "$1" varnish
  start_backend
  printf '%s\n' '{"test_varnish": true, "varnish_sites": [
    {"name": "a", "purge_token": "0123456789abcdef0123456789abcdef"},
    {"name": "s", "profile": "shopware", "purge_token": "ssssssssssssssssssssssssssssssss"}]}' >"$out/shopware-vars.json"
  host_state=varnish
  run_ok shopware converge.yml -e "@$out/shopware-vars.json"
  inv_secrets=("$ta" "$ts" "$(printf 'a:%s' "$ta" | base64)" "$(printf 's:%s' "$ts" | base64)" "$(h cat "$key")")

  p="/sw/page?$c"
  req s s.test "$p" -H 'Cookie: session-=x; sw-cache-hash=h1'
  expect "a page with sw-cache-hash h1" 200 MISS "count=1 host=s.test path=$p"
  header "$never"
  header 'Pragma: no-cache'
  header 'Expires: -1'
  req s s.test "$p" -H 'Cookie: session-=x; sw-cache-hash=h1'
  expect "the page with h1 again" 200 HIT "count=1 host=s.test path=$p"
  req s s.test "$p" -H 'Cookie: session-=y; sw-cache-hash=h1; _ga=1'
  expect "the page with h1 and another session" 200 HIT "count=1 host=s.test path=$p"
  req s s.test "$p" -H 'Cookie: session-=x; sw-cache-hash=h2'
  expect "the page with sw-cache-hash h2" 200 MISS "count=2 host=s.test path=$p"
  req s s.test "$p" -H 'Cookie: sw-currency=c1'
  expect "the page with sw-currency c1 and no hash" 200 MISS "count=3 host=s.test path=$p"
  req s s.test "$p" -H 'Cookie: sw-currency=c1'
  expect "the page with c1 again" 200 HIT "count=3 host=s.test path=$p"
  req s s.test "$p" -H 'Cookie: sw-currency=c1; sw-cache-hash=h1'
  expect "the page with c1 and h1 (the hash wins)" 200 HIT "count=1 host=s.test path=$p"
  req s s.test "$p" -H 'Cookie: sw-cache-hash=h1' -H 'sw-cache-hash: h2'
  expect "the page with the header sw-cache-hash h2 (it wins over the cookie)" 200 HIT "count=2 host=s.test path=$p"
  req s s.test "$p"
  expect "the page without cookies" 200 MISS "count=4 host=s.test path=$p"
  # Generic sites are unchanged: any cookie passes, the app's header stays.
  req a a.test "$p"
  expect "the generic site's page" 200 MISS "count=1 host=a.test path=$p"
  header "Cache-Control: public,s-maxage=60"
  req a a.test "$p" -H 'Cookie: sw-cache-hash=h1'
  expect "the generic site's page with sw-cache-hash" 200 PASS "count=2 host=a.test path=$p"

  echo "== shopware: what reaches the backend"
  p="/sw/echo?$c&echo=Cookie"
  req s s.test "$p" -H 'Cookie: session-=x; sw-cache-hash=h1; _ga=1'
  expect "a page that echoes the cookies" 200 MISS
  header 'X-Echo: session-=x; sw-cache-hash=h1'
  p="/sw/echo?$c&echo=Surrogate-Capability"
  req s s.test "$p"
  expect "a page that echoes Surrogate-Capability" 200 MISS
  header 'X-Echo: shopware=ESI/1.0'
  req a a.test "$p"
  expect "the generic site's page that echoes Surrogate-Capability" 200 MISS
  no_header X-Echo
  p="/media/echo.jpg?cc=public,max-age=60&echo=Cookie"
  req s s.test "$p" -H 'Cookie: session-=x; sw-cache-hash=h1'
  expect "media that echoes the cookies" 200 MISS
  no_header X-Echo

  echo "== shopware: a hit passes when the visitor's sw-states meet the object's"
  p="/sw/inv?$c&inv=logged-in"
  req s s.test "$p"
  expect "a page invalidated by logged-in" 200 MISS "count=1 host=s.test path=$p"
  no_header sw-invalidation-states
  req s s.test "$p"
  expect "that page again" 200 HIT "count=1 host=s.test path=$p"
  no_header sw-invalidation-states
  req s s.test "$p" -H 'Cookie: sw-states=logged-in'
  expect "that page, logged in" 200 PASS "count=2 host=s.test path=$p"
  req s s.test "$p" -H 'Cookie: sw-states=cart-filled'
  expect "that page with a filled cart" 200 HIT "count=1 host=s.test path=$p"
  p="/sw/inv?$c&inv=cart-filled"
  req s s.test "$p"
  expect "a page invalidated by cart-filled" 200 MISS "count=1 host=s.test path=$p"
  req s s.test "$p" -H 'Cookie: sw-states=logged-in,cart-filled'
  expect "that page, logged in with a filled cart" 200 PASS "count=2 host=s.test path=$p"

  echo "== shopware: checkout, account, admin and api pass"
  for p in "/checkout/cart?$c" "/account?$c" "/admin?$c" "/api/x?$c"; do
    req s s.test "$p"
    expect "$p" 200 PASS "count=1 host=s.test path=$p"
    req s s.test "$p"
    expect "$p again" 200 PASS "count=2 host=s.test path=$p"
  done

  echo "== shopware: media is one object for every visitor, with the app's Cache-Control"
  p='/media/a.jpg?cc=public,max-age=60'
  req s s.test "$p" -H 'Cookie: session-=x; sw-cache-hash=h1'
  expect "media with h1" 200 MISS "count=1 host=s.test path=$p"
  header 'Cache-Control: public,max-age=60'
  req s s.test "$p" -H 'Cookie: session-=y; sw-cache-hash=h2; sw-currency=c1'
  expect "media with h2" 200 HIT "count=1 host=s.test path=$p"
  header 'Cache-Control: public,max-age=60'
  req s s.test "$p"
  expect "media without cookies" 200 HIT "count=1 host=s.test path=$p"
  p='/sw/private?cc=private'
  req s s.test "$p"
  expect "a private page" 200 PASS "count=1 host=s.test path=$p"
  header 'Cache-Control: private'

  echo "== shopware: /widgets/checkout/info without a hash or a filled cart is answered by Varnish"
  req s s.test /widgets/checkout/info
  expect "the cart widget without cookies" 204 SYNTH ""
  req s s.test /widgets/checkout/info -H 'Cookie: session-=x'
  expect "the cart widget without sw-cache-hash" 204 SYNTH ""
  req s s.test /widgets/checkout/info -H 'Cookie: sw-cache-hash=h1; sw-states=logged-in'
  expect "the cart widget with an empty cart" 204 SYNTH ""
  req s s.test /widgets/checkout/info -H 'Cookie: sw-cache-hash=h1'
  expect "the cart widget with a hash" 200 PASS "count=1 host=s.test path=/widgets/checkout/info"
  req s s.test /widgets/checkout/info -H 'Cookie: sw-cache-hash=h1; sw-states=cart-filled'
  expect "the cart widget with a filled cart" 200 PASS "count=2 host=s.test path=/widgets/checkout/info"
  req a a.test /widgets/checkout/info
  expect "the generic site's /widgets/checkout/info" 200 PASS "count=1 host=a.test path=/widgets/checkout/info"

  echo "== shopware: ESI fragments are included, on the shopware site only"
  p="/sw/esi?$c&esi=1"
  req s s.test "$p"
  expect "a page with an ESI include" 200 MISS "<p>count=1 host=s.test path=$p</p>"$'\n'"count=1 host=s.test path=/frag"
  no_header Surrogate-Control
  req s s.test "$p"
  expect "the page again (the fragment is not cached)" 200 HIT "<p>count=1 host=s.test path=$p</p>"$'\n'"count=2 host=s.test path=/frag"
  req a a.test "$p"
  expect "the generic site's page with an ESI include" 200 MISS "<p>count=1 host=a.test path=$p</p>"$'\n''<esi:include src="/frag"/>'

  echo "== shopware: sw-dynamic-cache-bypass is never stored"
  p="/sw/bypass?bypass=1&$c"
  req s s.test "$p"
  [ "$cache" != HIT ] || fail "$p was a HIT on the first request"
  no_header sw-dynamic-cache-bypass
  req s s.test "$p"
  expect "the bypassed page again" 200 PASS "count=2 host=s.test path=$p"
  sleep 2
  req s s.test "$p"
  [ "$cache" != HIT ] || fail "$p was a HIT after 2 s"
  case "$body" in "count=3 host=s.test path=$p") ;; *) fail "$p did not reach the backend a third time: '$body'" ;; esac

  echo "== shopware: PURGE of xkey tags and of a URL acts on the shopware site only"
  x1="/sw/x1?$c&xkey=product-1"
  x2="/sw/x2?$c&xkey=product-2"
  seen MISS s s.test "$x1" "$x2"
  seen HIT s s.test "$x1" "$x2"
  seen MISS a a.test "$x1"
  seen HIT a a.test "$x1"
  req s s.test "$x1" -H 'Cookie: sw-cache-hash=h1'
  expect "the h1 variant of x1" 200 MISS
  inv PURGE / -u "s:$ts" -H 'xkey: product-1'
  inv_expect "PURGE of product-1 as s" 200
  seen MISS s s.test "$x1"
  seen HIT s s.test "$x2"
  seen HIT a a.test "$x1"
  req s s.test "$x1" -H 'Cookie: sw-cache-hash=h1'
  expect "the h1 variant of x1 after the purge" 200 MISS
  # kw and pa are Shopware-only tracking parameters: the purge drops them as
  # the shopware site's requests do.
  p="/sw/kw?a=1&$c"
  seen MISS s s.test "$p"
  seen HIT s s.test "$p"
  req s s.test "$p" -H 'Cookie: sw-cache-hash=h1'
  expect "the h1 variant of the page" 200 MISS
  seen MISS a a.test "$p"
  inv PURGE "/sw/kw?kw=x&a=1&pa=2&$c" -u "s:$ts"
  inv_expect "PURGE of the page with kw and pa as s" 200
  seen MISS s s.test "$p"
  req s s.test "$p" -H 'Cookie: sw-cache-hash=h1'
  expect "the h1 variant of the page after the purge" 200 MISS
  seen HIT a a.test "$p"

  echo "== shopware: with shopware sites only the VCL compiles"
  printf '%s\n' '{"test_varnish": true, "varnish_sites": [
    {"name": "s", "profile": "shopware", "purge_token": "ssssssssssssssssssssssssssssssss"}]}' >"$out/shopware-only-vars.json"
  run_ok shopware-only converge.yml -e "@$out/shopware-only-vars.json"
  req s s.test "/sw/page?$c" -H 'Cookie: session-=z; sw-cache-hash=h1'
  expect "the page with h1 on the shopware-only VCL" 200 HIT "count=1 host=s.test path=/sw/page?$c"
  req a a.test "/sw/page?$c"
  expect "the page of the removed generic site" 200 PASS
  no_key_in_logs
  no_token_in_logs "${inv_secrets[@]:0:4}"
  inv_secrets=()
}

# Grace: a stale object is served for 30 s while the site counts as healthy,
# and for 6 h while its health probe says sick; a refresh that fails never
# replaces it.
test_grace() {
  local t0 tries=0 p='/g/page?cc=public,max-age=2'
  echo "== grace: stale pages while the backend fails (ubuntu $1)"
  use_host "$1" varnish
  start_backend
  h rm -f /tmp/backend-sick
  printf '%s\n' '{"test_varnish": true, "varnish_sites": [
    {"name": "a", "purge_token": "0123456789abcdef0123456789abcdef"},
    {"name": "g", "purge_token": "gggggggggggggggggggggggggggggggg", "health_path": "/health", "health_host": "g.test"}]}' >"$out/grace-vars.json"
  host_state=varnish
  run_ok grace converge.yml -e "@$out/grace-vars.json"
  until h varnishadm backend.list site_g | grep -q healthy; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || fail "grace: the backend site_g is not healthy: $(h varnishadm backend.list site_g)"
    sleep 1
  done
  tries=0

  t0="$(date +%s)"
  req a a.test "$p"
  expect "a's page, max-age 2" 200 MISS "count=1 host=a.test path=$p"
  req g g.test "$p"
  expect "g's page, max-age 2" 200 MISS "count=1 host=g.test path=$p"
  sleep 3
  h touch /tmp/backend-sick

  echo "== grace: a site without a probe gets its stale page within 30 s"
  req a a.test "$p"
  expect "a's expired page, backend failing" 200 HIT+grace "count=1 host=a.test path=$p"
  sleep 2
  req a a.test "$p"
  expect "a's page after the failed refresh" 200 HIT+grace "count=1 host=a.test path=$p"

  echo "== grace: a site whose probe says sick gets its stale page well beyond 30 s"
  until h varnishadm backend.list site_g | grep -q 'sick'; do
    tries=$((tries + 1))
    [ "$tries" -lt 40 ] || fail "grace: the probe of g does not turn sick: $(h varnishadm backend.list site_g)"
    sleep 1
  done
  while [ "$(date +%s)" -lt $((t0 + 62)) ]; do sleep 1; done
  req g g.test "$p"
  expect "g's page 60 s after it expired, probe sick" 200 HIT+grace "count=1 host=g.test path=$p"
  req a a.test "$p"
  [ "$cache" != HIT+grace ] || fail "a's page was served stale 60 s after it expired"
  [ "$status" = 500 ] || fail "a's page 60 s after it expired: status $status, expected the backend's 500"

  echo "== grace: with the backend stopped, a site without a probe gets its stale page within 30 s"
  h rm -f /tmp/backend-sick
  p='/g/stopped?cc=public,max-age=2'
  req a a.test "$p"
  expect "a's page, max-age 2" 200 MISS "count=1 host=a.test path=$p"
  sleep 3
  h systemctl stop noixdev-test-backend
  req a a.test "$p"
  expect "a's expired page, backend stopped" 200 HIT+grace "count=1 host=a.test path=$p"
  sleep 2
  req a a.test "$p"
  expect "a's page after the failed refresh" 200 HIT+grace "count=1 host=a.test path=$p"
  start_backend
  no_key_in_logs
}

# The nginx and waf scenarios: tests/varnish/nginx.yml with the setup, and
# the nginx role alone (no setup, no docker, php or varnish role) for the
# refusals.
nginx_args=(-e "@$here/nginx.yml" -e test_nginx=true)
nginx_alone=(-e test_nginx_prepare=false -e test_varnish=false)
front_conf=/etc/nginx/noixdev/varnish-front.conf
# A client address of the test host's own (RFC 5737): requests from it are
# not from the loopback, which the inner block trusts.
client=192.0.2.10

# site <host> <path> [<curl option>...]: a request to nginx on the test host
# from the client address (HTTPS for b.test). Sets status, headers and body.
site() {
  local name="$1" path="$2" url answer
  shift 2
  case "$name" in
    b.test) url="https://$name$path" ;;
    *) url="http://$name$path" ;;
  esac
  answer="$(h curl -sSk -i --max-time 30 --interface "$client" --resolve "$name:80:127.0.0.1" \
    --resolve "$name:443:127.0.0.1" "$@" "$url" | tr -d '\r')" || fail "$name$path: no answer from nginx"
  headers="${answer%%$'\n\n'*}"
  body=
  case "$answer" in *$'\n\n'*) body="${answer#*$'\n\n'}" ;; esac
  status="$(printf '%s\n' "$headers" | sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p')"
}
# site_expect <what> <status> [<body>]: the last answer of site, which never
# shows the cache status or another internal header.
site_expect() {
  [ "$status" = "$2" ] || fail "$1: status $status, expected $2"
  [ $# -lt 3 ] || [ "$body" = "$3" ] || fail "$1: body '$body', expected '$3'"
  if printf '%s\n' "$headers" | grep -Eiq '^(X-Noix-[A-Za-z-]+|X-Cache|xkey|X-Cache-Tags|X-Varnish|Via):'; then
    fail "$1: an internal header reached the client: $(printf '%s\n' "$headers" | grep -Ei '^(X-Noix|X-Cache|xkey|X-Varnish|Via)' | cut -d: -f1 | tr '\n' ' ')"
  fi
}
# php_answer <count> [<https>]: the body tests/varnish/index.php gives the
# client (front=unset: the front key never reached PHP).
php_answer() { printf 'count=%s remote_addr=%s https=%s front=unset' "$1" "$client" "${2:-}"; }
# logged <site> <cache>: the last line of the site's access log ends with
# cache=<cache> (- when Varnish did not answer).
logged() {
  local line
  line="$(h tail -n 1 "/var/log/nginx/$1.access.log")"
  case "$line" in *" cache=$2") ;; *) fail "$1's last access log line is not cache=$2: $line" ;; esac
}
# nginx_state: nginx's files and www-data's groups, to show that a refused
# run changed nothing.
nginx_state() { h sh -c 'find /etc/nginx -type f -exec md5sum {} + | sort; id -nG www-data'; }
# nginx_refused <log> <message> [-e ...]: the nginx role alone must fail with
# the message, and change nothing.
nginx_refused() {
  local log="$1" message="$2" state
  shift 2
  state="$(nginx_state)"
  run_fails "$log" "$message" converge.yml "${nginx_args[@]}" "${nginx_alone[@]}" "$@"
  unchanged_refused "$log"
  [ "$(nginx_state)" = "$state" ] || fail "$log: the refused run changed nginx's files"
}
# nginx_host <ubuntu>: the nginx scenario's host, converged (a new one unless
# the host has it already).
nginx_host() {
  [ "$host_state" != nginx ] || return 0
  start_host "$1"
  host_state=nginx
  h ip addr replace "$client/32" dev lo
  run_ok nginx converge.yml "${nginx_args[@]}"
  run_ok nginx-again converge.yml "${nginx_args[@]}"
  unchanged nginx-again
  # The app of ws and of a's inner_extra location.
  start_backend noixdev-test-app 8945
}
# varnish_back: Varnish started again, and nginx sends to it again (after
# the 5 s an upstream that did not answer is left alone).
varnish_back() {
  h systemctl start varnish
  sleep 6
}

test_nginx() {
  local fixture line answer
  echo "== nginx: sites with varnish: true are served through Varnish (ubuntu $1)"
  nginx_host "$1"

  echo "== nginx: a cacheable page is a MISS, then a HIT, in the access log only"
  site a.test /page
  site_expect "a.test/page" 200 "$(php_answer 1)"
  logged a MISS
  site a.test /page
  site_expect "a.test/page again" 200 "$(php_answer 1)"
  logged a HIT
  # The client's own X-Noix-Site and X-Noix-Front are replaced by nginx's.
  site a.test /page -H 'X-Noix-Site: b' -H 'X-Noix-Front: forged'
  site_expect "a.test/page with the client's X-Noix-Site and X-Noix-Front" 200 "$(php_answer 1)"
  logged a HIT
  site b.test /page
  site_expect "b.test/page (another tenant, HTTPS)" 200 "$(php_answer 1 on)"
  logged b MISS
  site b.test /page
  site_expect "b.test/page again" 200 "$(php_answer 1 on)"
  logged b HIT
  site a.test '/private?private=1'
  site_expect "a private page" 200 "$(php_answer 1)"
  site a.test '/private?private=1'
  site_expect "the private page again" 200 "$(php_answer 2)"
  logged a PASS
  # nginx passes the client's Authorization on, so Varnish passes the request.
  site a.test /auth -H 'Authorization: Basic dXNlcjpwYXNz'
  site_expect "a page with Authorization" 200 "$(php_answer 1)"
  site a.test /auth -H 'Authorization: Basic dXNlcjpwYXNz'
  site_expect "the page with Authorization again" 200 "$(php_answer 2)"
  logged a PASS

  echo "== nginx: PURGE and BAN through nginx answer 405"
  for line in a.test b.test; do
    site "$line" /page -X PURGE
    site_expect "PURGE $line/page" 405
    site "$line" / -X BAN
    site_expect "BAN $line/" 405
  done
  site a.test /page
  site_expect "a.test/page after them" 200 "$(php_answer 1)"
  logged a HIT

  echo "== nginx: a WebSocket upgrade on ws goes through Varnish (a pipe) to the app, without the front key"
  answer="$(h python3 /usr/local/bin/noixdev-test-wsclient 127.0.0.1 80 '/ws?echo=X-Noix-Front' 'Host: ws.test' \
    | tr -d '\r')" || fail "the WebSocket through nginx failed: $answer"
  case "$answer" in "HTTP/1.1 101 "*) ;; *) fail "the WebSocket through nginx got: $answer" ;; esac
  printf '%s\n' "$answer" | grep -qx 'echo: noix-ping' || fail "the WebSocket through nginx echoed nothing: $answer"
  ! printf '%s\n' "$answer" | grep -qi '^X-Echo:' || fail "the app got X-Noix-Front on the WebSocket"
  h varnishlog -d -g request -q 'ReqURL ~ "^/ws"' | grep -Eq 'VCL_return +pipe' \
    || fail "the WebSocket did not go through Varnish's pipe"

  echo "== nginx: a page slower than Varnish waits for gets Varnish's 503, and reaches PHP once"
  site a.test '/slow?sleep=6'
  site_expect "a page slower than varnish_first_byte_timeout" 503
  sleep 5
  [ "$(h grep -c 'noix-varnish /slow?sleep=6' /var/log/php/a.log)" = 1 ] \
    || fail "the slow page reached PHP $(h grep -c 'noix-varnish /slow?sleep=6' /var/log/php/a.log) times, not once"

  echo "== nginx: with a's pool stopped, its stale page is still served"
  site a.test '/grace?max_age=2'
  site_expect "a page for 2 s" 200 "$(php_answer 1)"
  sleep 3
  h systemctl stop php-fpm@a
  site a.test '/grace?max_age=2'
  site_expect "the expired page, the pool stopped" 200 "$(php_answer 1)"
  logged a HIT+grace
  site a.test /uncached
  site_expect "a page that is not in the cache, the pool stopped" 502
  h systemctl start php-fpm@a

  echo "== nginx: with Varnish stopped, the sites are served uncached by nginx"
  h systemctl stop varnish
  site a.test /page
  site_expect "a.test/page, Varnish stopped" 200 "$(php_answer 2)"
  logged a -
  site a.test /page
  site_expect "a.test/page again, Varnish stopped" 200 "$(php_answer 3)"
  site b.test /page
  site_expect "b.test/page, Varnish stopped" 200 "$(php_answer 2 on)"
  logged b -
  site a.test / -X PURGE
  site_expect "PURGE a.test/, Varnish stopped" 405
  # a's inner_extra location gets the request with the front key here (the
  # backup), and its app never sees it; X-Noix-Site shows the path.
  site a.test '/inner-extra?echo=X-Noix-Site'
  site_expect "a's inner_extra location, Varnish stopped" 200
  header 'X-Echo: a'
  site a.test '/inner-extra?echo=X-Noix-Front'
  site_expect "a's inner_extra location with the front key's echo, Varnish stopped" 200
  no_header X-Echo
  varnish_back
  site a.test /page
  site_expect "a.test/page, Varnish started again" 200 "$(php_answer 4)"
  logged a MISS
  site a.test /page
  site_expect "a.test/page again" 200 "$(php_answer 4)"
  logged a HIT

  echo "== nginx: p, without varnish, as before"
  fixture=p.conf
  [ -z "$(h ip -6 addr show scope global)" ] || fixture="p-ipv6.conf"
  h cat /etc/nginx/sites/p.conf | diff "$here/fixtures/nginx-before/$fixture" - || fail "p.conf is not as before"
  site p.test /page
  site_expect "p.test/page" 200 "$(php_answer 1)"
  site p.test /page
  site_expect "p.test/page again (never cached)" 200 "$(php_answer 2)"
  line="$(h tail -n 1 /var/log/nginx/p.access.log)"
  case "$line" in *cache=*) fail "p's access log has a cache field: $line" ;; esac
  # p's PURGE goes to its app, as before.
  site p.test /purge -X PURGE
  site_expect "PURGE p.test/purge (a site without varnish)" 200 "$(php_answer 1)"

  echo "== nginx: the front key is root's alone and in no output"
  [ "$(h stat -c '%a %U %G' "$front_conf")" = "600 root root" ] \
    || fail "$front_conf is $(h stat -c '%a %U %G' "$front_conf"), not 600 root root"
  h grep -qF -f "$key" "$front_conf" || fail "$front_conf does not hold the front key"
  no_key_in_logs

  echo "== nginx: after a new front key, the varnish sites answer 403 until nginx runs"
  h cp -p "$key" /root/old-front.key
  h rm "$key"
  run_ok nginx-new-key converge.yml -e "@$here/nginx.yml"
  site a.test /page
  site_expect "a.test/page with the old key" 403
  site p.test /page
  site_expect "p.test/page with the old key" 200 "$(php_answer 3)"
  run_ok nginx-new-key-nginx converge.yml "${nginx_args[@]}" "${nginx_alone[@]}"
  site a.test /page
  site_expect "a.test/page after the nginx run" 200 "$(php_answer 4)"
  no_key_in_logs /root/old-front.key
  h rm /root/old-front.key

  echo "== nginx: varnish: true without Varnish or its key is refused before any change"
  h systemctl stop varnish
  nginx_refused nginx-stopped \
    'nginx: nginx_sites entries a, b, ws set varnish, but Varnish does not answer on http://127.0.0.1:6081/; run the varnish role (varnish_port 6081) first'
  h mv "$key" /root/front.key
  nginx_refused nginx-stopped-no-key \
    'nginx: nginx_sites entries a, b, ws set varnish, but Varnish does not answer on http://127.0.0.1:6081/ and the front key /etc/varnish/noixdev-front.key is missing; run the varnish role (varnish_port 6081) first'
  varnish_back
  nginx_refused nginx-no-key \
    'nginx: nginx_sites entries a, b, ws set varnish, but the front key /etc/varnish/noixdev-front.key is missing; run the varnish role (varnish_port 6081) first'
  h mv /root/front.key "$key"
  h cp -p "$key" /root/front.key
  h sh -c "printf 'not-a-front-key\\n' >$key"
  nginx_refused nginx-bad-key \
    'nginx: the front key in /etc/varnish/noixdev-front.key is not 64 hexadecimal digits; delete the file and run the varnish role'
  h mv /root/front.key "$key"
  nginx_refused nginx-varnish-string 'nginx: nginx_sites entry a has an invalid hardening, hsts, user_includes, anubis, waf, varnish,' \
    -e '{"test_nginx_sites": [{"name": "a", "domains": ["a.test"], "user": "app_a", "php_pool": "a", "root": "/srv/a", "tls": "off", "varnish": "yes"}]}'
  nginx_refused nginx-varnish-port 'nginx: nginx_varnish_port (8931) must be a port number other than' \
    -e nginx_varnish_port=8931
  run_ok nginx-last converge.yml "${nginx_args[@]}"
  unchanged nginx-last
  site a.test /page
  site_expect "a.test/page at the end (Varnish restarted, the cache empty)" 200 "$(php_answer 5)"
  # For the record: the cache status in the access logs.
  h cat /var/log/nginx/a.access.log >"$out/nginx-a-access-$1.txt"
  h cat /var/log/nginx/p.access.log >"$out/nginx-p-access-$1.txt"
  no_key_in_logs
}

# The WAF in front of Varnish: w goes nginx -> WAF -> Varnish -> nginx's inner
# block, the inner block the WAF's fallback.
test_waf() {
  local secret
  echo "== waf: a site with waf and varnish, the WAF in front of Varnish (ubuntu $1)"
  nginx_host "$1"
  run_ok waf converge.yml "${nginx_args[@]}" -e test_waf=true
  run_ok waf-again converge.yml "${nginx_args[@]}" -e test_waf=true
  unchanged waf-again
  # The nginx role's probe of the WAF (/.noix-front-probe, without the front
  # key) is answered by Varnish: it passes, reaches no app and leaves nothing
  # in the WAF's log or report.
  ! h grep -qF noix-front-probe /var/log/php/w.log || fail "the WAF probe reached PHP"
  ! h sh -c 'docker logs noixdev-waf 2>&1 | grep -qF noix-front-probe' || fail "the WAF logged its probe"
  ! h sh -c '/usr/local/sbin/noix-waf-report --since 1h | grep -qF noix-front-probe' || fail "the WAF report lists its probe"

  echo "== waf: a HIT through the WAF"
  site w.test /page
  site_expect "w.test/page" 200 "$(php_answer 1)"
  logged w MISS
  site w.test /page
  site_expect "w.test/page again" 200 "$(php_answer 1)"
  logged w HIT

  echo "== waf: a blocked request reaches neither Varnish nor PHP"
  site w.test '/page?exec=/bin/bash'
  site_expect "an attack on w.test" 403
  logged w -
  ! h grep -qF 'exec=' /var/log/php/w.log || fail "the attack reached PHP"
  [ -z "$(h varnishlog -d -g request -q 'ReqURL ~ "exec="')" ] || fail "the attack reached Varnish"

  echo "== waf: with Varnish stopped, the WAF falls back to nginx's inner block"
  h systemctl stop varnish
  site w.test /page
  site_expect "w.test/page, Varnish stopped" 200 "$(php_answer 2)"
  logged w -
  varnish_back
  site w.test /page
  site_expect "w.test/page, Varnish started again" 200 "$(php_answer 3)"
  logged w MISS
  site w.test /page
  site_expect "w.test/page again" 200 "$(php_answer 3)"
  logged w HIT

  h cat /var/log/nginx/w.access.log >"$out/waf-w-access-$1.txt"

  echo "== waf: the front key is not in the WAF's log"
  secret="$(h cat "$key")"
  ! h docker logs noixdev-waf 2>&1 | grep -qF -- "$secret" || fail "the WAF's log holds the front key"
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
scenarios="${*:-invalid valid install badvcl cache purge shopware grace nginx waf foreign}"
for ubuntu in $releases; do
  out="$tests/output/varnish-$ubuntu"
  mkdir -p "$out"
  host_state=
  for scenario in $scenarios; do
    case "$scenario" in
      invalid) test_invalid "$ubuntu" ;;
      valid) test_valid "$ubuntu" ;;
      install) test_install "$ubuntu" ;;
      badvcl) test_badvcl "$ubuntu" ;;
      cache) test_cache "$ubuntu" ;;
      purge) test_purge "$ubuntu" ;;
      shopware) test_shopware "$ubuntu" ;;
      grace) test_grace "$ubuntu" ;;
      nginx) test_nginx "$ubuntu" ;;
      waf) test_waf "$ubuntu" ;;
      foreign) test_foreign "$ubuntu" ;;
      *) fail "unknown scenario $scenario (invalid, valid, install, badvcl, cache, purge, shopware, grace, nginx, waf, foreign)" ;;
    esac
  done
  cleanup
  host=
done

noix_done
echo "== all varnish tests passed"
