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
# untouched: the role changed nothing on the host before it refused: no
# waf_dir, no container and no Traefik objects.
untouched() {
  h test ! -e /opt/waf || fail "waf touched the host before checking its settings"
  h test ! -e /opt/traefik/dynamic/waf.yml || fail "waf wrote waf.yml before checking its settings"
  [ -z "$(h docker ps -aq --filter name=^noixdev-waf)" ] || fail "waf started a container before checking its settings"
}
# refused <name> <text> [-e ...]: role_fails, then expect_in_log and untouched.
refused() {
  local name="$1" text="$2"
  shift 2
  role_fails "$name" "$@"
  expect_in_log "$name" "$text"
  untouched
}

# probe <host header> <path> [curl args...]: the HTTP status of a request
# from inside the test host to its port 80 (000 when nothing answers). A path
# that starts with :<port> goes to that port instead (another entrypoint).
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
  refused fallback-traefik 'waf: waf_sites entry a has a backend_fallback, which only host mode uses' \
    -e "$(one_site '"backend_fallback": "http://127.0.0.1:8931"')"
  # The same address as the backend's, which names its port, the
  # fallback's from its scheme.
  refused fallback-same 'waf: waf_sites entry a has the backend http://127.0.0.1:80 and the backend_fallback http://127.0.0.1; the fallback is another address' \
    -e waf_mode=host -e "$(one_site '"backend": "http://127.0.0.1:80", "backend_fallback": "http://127.0.0.1"')"
  refused fallback-scheme 'waf: waf_sites entry a has the backend http://127.0.0.1:8939 and the backend_fallback https://127.0.0.1:8931' \
    -e waf_mode=host -e "$(one_site '"backend": "http://127.0.0.1:8939", "backend_fallback": "https://127.0.0.1:8931"')"
  refused fallback-loopback 'waf: waf_sites entry a has the backend_fallback http://10.0.0.1:8931; a backend_fallback is' \
    -e waf_mode=host -e "$(one_site '"backend": "http://127.0.0.1:8939", "backend_fallback": "http://10.0.0.1:8931"')"
  refused fallback-own-port 'waf: waf_sites entry a has the backend_fallback http://127.0.0.1:8930; a backend_fallback is' \
    -e waf_mode=host -e "$(one_site '"backend": "http://127.0.0.1:8939", "backend_fallback": "http://127.0.0.1:8930"')"
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
  refused router-key 'waf: waf_sites entry a has routers with unknown keys (colour)' \
    -e "$(one_site '"routers": [{"entrypoints": ["web"], "colour": "red"}]')"
  refused router-entrypoint 'waf: waf_sites entry a has an invalid router waf-a-1' \
    -e "$(one_site '"routers": [{"entrypoints": ["alt"]}]')" -e '{"traefik_entrypoints": [{"name": "web", "port": 80}]}'
  refused bypass-slashes 'waf: waf_sites entry a has invalid bypass_paths (/a//b)' \
    -e "$(one_site '"bypass_paths": ["/a//b"]')"
  # This host has no Traefik: its directory and network are missing.
  refused no-dynamic-dir 'waf: /opt/traefik/dynamic (waf_traefik_dynamic_dir) is not a directory' \
    -e "$(one_site '')"
  refused no-network 'waf: the Docker network proxy (waf_traefik_network) does not exist' \
    -e "$(one_site '')" -e waf_traefik_dynamic_dir=/tmp
  # /usr/bin holds the docker CLI of the docker role's packages.
  refused no-docker 'The docker CLI was not found' \
    -e '{"test_environment": {"PATH": "/usr/sbin:/sbin"}}'
  expect_in_log no-docker 'Docker is not installed or not running'
}

# The traefik scenario: the converge arguments, the WAF's container and its
# address on the proxy network.
traefik_args=(-e "@$here/traefik.yml" -e test_traefik=true -e test_waf=true)
waf=noixdev-waf
waf_url=http://172.31.255.253:8080
browser='Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0'

# expect <want> <probe arguments...>: one probe must answer want.
expect() {
  local want="$1" got
  shift
  got="$(probe "$@")"
  [ "$got" = "$want" ] || fail "probe $*: got $got, expected $want"
}
# await <want> <probe arguments...>: the same, retried for up to 30 s, for a
# change that Traefik (its file provider) or Docker's DNS learns late.
await() {
  local want="$1" got=
  shift
  for _ in $(seq 30); do
    got="$(probe "$@")"
    [ "$got" = "$want" ] && return 0
    sleep 1
  done
  fail "probe $*: got $got, expected $want (for 30 s)"
}
# direct <host header> <path> [curl args...]: the HTTP status of a request
# straight to the WAF's address on the proxy network, past Traefik (curl in
# the WAF's own container).
direct() {
  local host_header="$1" path="$2"
  shift 2
  h docker exec "$waf" curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H "Host: $host_header" "$@" "$waf_url$path" || true
}
# padded <args...>: the query string of a thousand empty arguments
# (SecArgumentsLimit), then the given ones (a=b&c=d).
padded() {
  local i query=
  for i in $(seq 0 999); do query="${query}a$i=&"; done
  printf '%s%s' "$query" "$1"
}
# multipart <name> <body>: a multipart/form-data POST (boundary NOIX) of the
# printf-escaped body from inside the test host to block.test; prints the
# status.
multipart() {
  # shellcheck disable=SC2059
  printf -- "$2" | hi curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H 'Host: block.test' -H 'Expect:' \
    -H 'Content-Type: multipart/form-data; boundary=NOIX' --data-binary @- "http://127.0.0.1/$1" || true
}
# audit: the WAF's stdout (its audit log, one JSON line per event).
audit() { h docker logs "$waf" 2>/dev/null; }
audit_lines() { audit | wc -l | tr -d ' '; }
# recorded: the recording backend's lines,
# "<request line> | <UA> | <body sha256> | <body bytes>".
recorded() { h docker logs waf-fixtures-recorder-1 2>/dev/null; }
# arrived_whole <method> <path> <file>: the recorder got one request
# "<method> <path>" whose body is the test host's file, byte for byte.
arrived_whole() {
  local sum size
  sum="$(h sha256sum "$3" | cut -d' ' -f1)"
  size="$(h stat -c %s "$3")"
  recorded | grep -qF "$1 $2 HTTP/1.1 | " || { recorded >&2; fail "the backend did not get $1 $2"; }
  recorded | grep -qF -- "$1 $2 HTTP/1.1 | curl" || fail "the backend got $1 $2 from another client"
  recorded | grep -F "$1 $2 HTTP/1.1 | " | grep -qE " \| $sum \| $size\$" \
    || { recorded >&2; fail "the body of $1 $2 did not arrive whole ($size bytes, sha256 $sum)"; }
}
recorder_ip() { h docker inspect -f '{{(index .NetworkSettings.Networks "proxy").IPAddress}}' waf-fixtures-recorder-1; }
# websocket <host header> <path> <idle seconds>: through the web entrypoint, a
# WebSocket upgrade, a text message, the given idle time and a second message;
# prints both echoes.
websocket() {
  hi python3 - "$@" <<'PY'
import base64, os, socket, sys, time

host, path, idle = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = socket.create_connection(("127.0.0.1", 80), timeout=idle + 30)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
head = b""
while b"\r\n\r\n" not in head:
    chunk = s.recv(1)
    if not chunk:
        sys.exit(f"closed during the handshake: {head!r}")
    head += chunk
status = head.split(b"\r\n", 1)[0].decode()
if status.split()[1:2] != ["101"]:
    sys.exit(f"no upgrade: {status}")


def exactly(n):
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            sys.exit("the connection was closed")
        data += chunk
    return data


def send(text):
    payload, mask = text.encode(), os.urandom(4)
    s.sendall(bytes([0x81, 0x80 | len(payload)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def receive():
    length = exactly(2)[1] & 0x7F
    if length == 126:
        length = int.from_bytes(exactly(2), "big")
    elif length == 127:
        length = int.from_bytes(exactly(8), "big")
    return exactly(length).decode()


send("noix-ws-1")
print(receive())
time.sleep(idle)
send("noix-ws-2")
print(receive())
PY
}

# The traefik scenario, on the host of the refusals (which must run first:
# they need a host without the WAF and without Traefik).
test_traefik() {
  local before got sum ip
  echo "== traefik (ubuntu $1)"
  converge "${traefik_args[@]}"
  converge_unchanged "${traefik_args[@]}"

  echo "-- the container and the Traefik objects"
  got="$(h docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.Config.User}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{len .HostConfig.PortBindings}}' "$waf" || true)"
  [ "$got" = "true 101:101 [ALL] [no-new-privileges:true] 0" ] || fail "the WAF container runs as: $got"
  got="$(h docker inspect -f '{{(index .NetworkSettings.Networks "proxy").IPAMConfig.IPv4Address}}' "$waf")"
  [ "$got" = 172.31.255.253 ] || fail "the WAF's address is $got"
  for name in waf-block-1 waf-detect-1 waf-paused-1 'url: http://172.31.255.253:8080'; do
    h grep -qF -- "$name" /opt/traefik/dynamic/waf.yml || fail "waf.yml lacks $name"
  done
  [ -z "$(h docker ps -aq --filter name=noixdev-waf-check)" ] || fail "the check container was left behind"
  [ "$(direct unknown.test /)" = 421 ] || fail "an unknown host did not answer 421"

  echo "-- a block site: attacks answer 403 and never reach the backend"
  await 200 block.test /
  expect 403 block.test '/?exec=/bin/bash'
  expect 403 block.test / -A Nikto
  expect 403 block.test '/?file=../../etc/passwd'
  recorded | grep -q '^GET / HTTP/1.1 | ' || fail "the backend of block.test saw no request"
  if recorded | grep -Eq 'exec=|etc/passwd|Nikto'; then
    recorded >&2
    fail "the backend of block.test saw an attack"
  fi
  for id in 932160 913100 930120; do
    audit | grep -qF "\"$id\"" || { audit >&2; fail "the audit log lacks rule $id"; }
  done
  # Traefik replaces a client's X-Forwarded-For; the WAF believes only Traefik's.
  expect 403 block.test '/?exec=/bin/bash' -H 'X-Forwarded-For: 203.0.113.9'
  [ "$(direct block.test '/?exec=/bin/bash' -H 'X-Forwarded-For: 203.0.113.9')" = 403 ] \
    || fail "a direct attack was not refused"
  if audit | grep -qF 203.0.113.9; then fail "the WAF believed a client's X-Forwarded-For"; fi

  echo "-- an attack after a thousand arguments, malformed multipart bodies"
  # ModSecurity inspects no argument past SecArgumentsLimit (1000): so many
  # are refused, in the query string and in a form body.
  expect 400 block.test "/padded?$(padded exec=/bin/bash)"
  expect 400 block.test /padded-form -X POST -H 'Content-Type: application/x-www-form-urlencoded' -H 'Expect:' \
    --data-binary "$(padded exec=/bin/bash)"
  [ "$(multipart multipart-ok '--NOIX\r\nContent-Disposition: form-data; name="a"\r\n\r\nb\r\n--NOIX--\r\n')" = 200 ] \
    || fail "a well-formed multipart body was refused"
  # Data before the first boundary, LF line ends, a part after the final
  # boundary: refused (strict multipart), as an unclosed quote is.
  for body in 'x\r\n--NOIX\r\nContent-Disposition: form-data; name="a"\r\n\r\nb\r\n--NOIX--\r\n' \
    '--NOIX\nContent-Disposition: form-data; name="a"\n\nb\n--NOIX--\n' \
    '--NOIX\r\nContent-Disposition: form-data; name="a"\r\n\r\nb\r\n--NOIX--\r\n--NOIX\r\nContent-Disposition: form-data; name="exec"\r\n\r\n/bin/bash\r\n--NOIX--\r\n' \
    '--NOIX\r\nContent-Disposition: form-data; name="a\r\n\r\nb\r\n--NOIX--\r\n'; do
    [ "$(multipart multipart-bad "$body")" = 400 ] || fail "a malformed multipart body was not refused: $body"
  done
  if recorded | grep -Eq '/padded|multipart-bad'; then
    recorded >&2
    fail "a padded request or a malformed multipart body reached the backend"
  fi
  recorded | grep -qF 'POST /multipart-ok HTTP/1.1' || fail "the well-formed multipart body did not arrive"
  for id in 9599907 9599908; do
    audit | grep -qF "\"$id\"" || { audit >&2; fail "the audit log lacks rule $id"; }
  done

  echo "-- inspected bodies reach the backend whole: small, 3 MiB, chunked"
  # Below the inspection limit, in a type the Core Rule Set allows at
  # paranoia 1; no Expect header (CRS refuses it, 920450).
  h sh -c 'printf "{\"a\": \"b\"}" >/tmp/small.json'
  # 200 items of prose: about 3 MiB, 400 arguments (SecArgumentsLimit is 1000).
  h python3 -c 'import json; open("/tmp/big.json", "w").write(json.dumps({"items": [{"id": i, "text": "lorem ipsum dolor sit amet " * 580} for i in range(200)]}))'
  expect 200 block.test /small -X POST -H 'Content-Type: application/json' -H 'Expect:' --data-binary @/tmp/small.json
  arrived_whole POST /small /tmp/small.json
  expect 200 block.test /big -X POST -H 'Content-Type: application/json' -H 'Expect:' --data-binary @/tmp/big.json
  arrived_whole POST /big /tmp/big.json
  expect 200 block.test /chunked -X POST -H 'Content-Type: application/json' -H 'Expect:' \
    -H 'Transfer-Encoding: chunked' --data-binary @/tmp/big.json
  arrived_whole POST /chunked /tmp/big.json
  # The same bodies are inspected: an attack in JSON, with a length or
  # chunked, never arrives; JSON that cannot be parsed is refused.
  expect 403 block.test /json-attack -X POST -H 'Content-Type: application/json' -H 'Expect:' \
    --data-binary '{"exec": "/bin/bash"}'
  expect 403 block.test /chunked-attack -X POST -H 'Content-Type: application/json' -H 'Expect:' \
    -H 'Transfer-Encoding: chunked' --data-binary '{"exec": "/bin/bash"}'
  expect 400 block.test /broken-json -X POST -H 'Content-Type: application/json' -H 'Expect:' \
    --data-binary '{"a": '
  if recorded | grep -Eq '/json-attack|/chunked-attack|/broken-json'; then
    recorded >&2
    fail "an attack or a broken body in JSON reached the backend"
  fi
  # A JSON or XML content type without a body (API clients send them) has
  # nothing to parse and passes.
  h sh -c ': >/tmp/empty'
  expect 200 block.test /empty-json -X POST -H 'Content-Type: application/json' -H 'Expect:' -d ''
  arrived_whole POST /empty-json /tmp/empty
  expect 200 block.test /empty-xml -X POST -H 'Content-Type: application/xml' -H 'Expect:' -d ''
  arrived_whole POST /empty-xml /tmp/empty

  echo "-- the site's settings with a port, in upper case and with a trailing dot"
  # A path starting with :8443 goes to the alt entrypoint.
  await 200 block.test:8443 :8443/
  expect 403 block.test:8443 ':8443/?exec=/bin/bash'
  expect 403 BLOCK.test '/?exec=/bin/bash'
  # tuned.test's paranoia 2 comes from its Host-keyed rule.
  expect 403 TUNED.test '/?q=a%27b%27c%28%29'
  [ "$(direct tuned.test. '/?q=a%27b%27c%28%29')" = 403 ] || fail "tuned.test. lost its settings"
  [ "$(direct TUNED.test:8080 '/?q=a%27b%27c%28%29')" = 403 ] || fail "TUNED.test:8080 lost its settings"

  echo "-- a detect site: attacks pass and are logged"
  before="$(audit_lines)"
  expect 200 detect.test '/?exec=/bin/bash'
  expect 200 detect.test / -A Nikto
  expect 200 detect.test '/?file=../../etc/passwd'
  [ "$(audit_lines)" -ge $((before + 3)) ] || { audit >&2; fail "detect.test's attacks were not logged"; }
  expect 200 detect.test "/padded?$(padded exec=/bin/bash)"
  audit | grep -F '"/padded?' | grep -qF '"9599907"' || { audit >&2; fail "detect.test's padded request was not logged"; }

  echo "-- a registry: an uninspected upload path, the rest inspected"
  h sh -c 'head -c 20971520 /dev/zero >/tmp/blob'
  expect 200 registry.test /v2/x/blobs/uploads/1 -X PATCH -H 'Content-Type: application/octet-stream' --data-binary @/tmp/blob
  recorded | grep -q '^PATCH /v2/x/blobs/uploads/1 HTTP/1.1 | .* | 20971520$' \
    || { recorded >&2; fail "the backend did not get the whole upload"; }
  expect 403 registry.test '/v2/../?exec=/bin/bash' --path-as-is
  [ "$(direct registry.test '/v2/../?exec=/bin/bash' --path-as-is)" = 403 ] || fail "/v2/../ carried the bypass"
  expect 403 registry.test /api/x -X PUT

  echo "-- an exclusion for one path"
  expect 200 hooks.test '/webhook/a?exec=/bin/bash'
  expect 403 hooks.test '/a?exec=/bin/bash'
  expect 403 hooks.test '/webhook/../a?exec=/bin/bash' --path-as-is
  [ "$(direct hooks.test '/webhook/../a?exec=/bin/bash' --path-as-is)" = 403 ] || fail "/webhook/../ carried the exclusion"

  echo "-- Anubis before the WAF"
  got="$(h curl -s --max-time 30 -H 'Host: guarded.test' -A "$browser" -w '\n%{http_code}' 'http://127.0.0.1/?exec=/bin/bash' || true)"
  [ "${got##*$'\n'}" = 401 ] || fail "guarded.test answered ${got##*$'\n'}, expected Anubis's 401"
  case "$got" in *anubis_challenge*) ;; *) fail "guarded.test did not answer the challenge page" ;; esac

  echo "-- a WebSocket, idle for longer than a minute"
  got="$(websocket ws.test /echo 65 || true)"
  [ "$got" = "$(printf 'noix-ws-1\nnoix-ws-2')" ] || fail "the WebSocket echoed: $got"

  echo "-- paranoia 2 and an extra method for one site only"
  expect 403 tuned.test '/?q=a%27b%27c%28%29'
  expect 200 block.test '/?q=a%27b%27c%28%29'
  expect 200 tuned.test /x -X PUT -d a=b
  expect 403 block.test /x -X PUT -d a=b

  echo "-- mode off: no inspection, nothing logged"
  before="$(audit_lines)"
  expect 200 paused.test '/?exec=/bin/bash'
  [ "$(audit_lines)" = "$before" ] || { audit >&2; fail "paused.test's request was logged"; }

  echo "-- an absolute-form request line cannot pick a site"
  [ "$(direct detect.test / --request-target 'http://block.test/')" = 400 ] || fail "absolute form was not refused"
  [ "$(direct block.test / --request-target 'http://block.test/')" = 400 ] || fail "absolute form was not refused"

  echo "-- a recreated backend with a new address, without a reload"
  ip="$(recorder_ip)"
  h sh -c 'cd /opt/waf-fixtures && docker compose -p waf-fixtures rm -s -f recorder' >/dev/null 2>&1
  # It takes the freed address, so the new recorder gets another one.
  h docker run -d --name waf-test-placeholder --network proxy "$(sed -n 's/^fixtures_python_image: *//p' "$here/traefik.yml")" sleep 600 >/dev/null
  h sh -c 'cd /opt/waf-fixtures && docker compose -p waf-fixtures up -d recorder' >/dev/null 2>&1
  [ "$(recorder_ip)" != "$ip" ] || fail "the recreated recorder kept its address $ip"
  h docker rm -f waf-test-placeholder >/dev/null
  await 200 block.test /

  echo "-- the WAF stopped: 504, never the backend; the next converge brings it back"
  h docker stop "$waf" >/dev/null
  # Nothing answers on the stopped WAF's fixed address: Traefik gives up at
  # waf.yml's dial timeout (5 s) with 504.
  expect 504 block.test / --max-time 15
  expect 504 paused.test / --max-time 15
  converge "${traefik_args[@]}"
  expect 200 block.test /
  converge_unchanged "${traefik_args[@]}"

  echo "-- broken rules fail the run and leave the running WAF alone"
  sum="$(h sha256sum /opt/waf/modsecurity.conf /opt/waf/nginx.conf)"
  if play broken "${traefik_args[@]}" -e '{"waf_rules_before": "SecRule BROKEN"}'; then
    cat "$out/broken.log" >&2
    fail "the run with broken rules succeeded"
  fi
  expect_in_log broken 'nginx: [emerg]'
  expect_in_log broken 'nginx: configuration file /etc/nginx/nginx.conf test failed'
  [ "$(h sha256sum /opt/waf/modsecurity.conf /opt/waf/nginx.conf)" = "$sum" ] || fail "the broken rules reached waf_dir"
  [ -z "$(h docker ps -aq --filter name=noixdev-waf-check)" ] || fail "the check container was left behind"
  expect 200 block.test /
  expect 403 block.test '/?exec=/bin/bash'

  echo "-- detect switched to block changes that site only"
  converge "${traefik_args[@]}" -e test_detect_mode=block
  expect 403 detect.test '/?exec=/bin/bash'
  expect 200 detect.test /
  expect 200 paused.test '/?exec=/bin/bash'
  expect 200 hooks.test '/webhook/a?exec=/bin/bash'
  expect 200 block.test '/?q=a%27b%27c%28%29'
  converge_unchanged "${traefik_args[@]}" -e test_detect_mode=block

  echo "-- a removed site answers 421 and loses its routers"
  converge "${traefik_args[@]}" -e test_detect_mode=block -e '{"test_without": ["hooks"]}'
  [ "$(direct hooks.test /)" = 421 ] || fail "the removed hooks.test did not answer 421"
  if h grep -qF waf-hooks- /opt/traefik/dynamic/waf.yml; then fail "waf.yml kept the routers of hooks"; fi
  await 404 hooks.test /
  expect 200 block.test /
  converge_unchanged "${traefik_args[@]}" -e test_detect_mode=block -e '{"test_without": ["hooks"]}'

  h docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' "$waf" | tee "$out/memory-$1.txt"
}

# report [args...]: the report helper on the test host.
report() { h /usr/local/sbin/noix-waf-report "$@"; }
# report_site <site> [args...]: the report's section of one site, from its
# "site <name>" line up to the next site's.
report_site() {
  local site="$1"
  shift
  report "$@" | awk -v head="site $site " 'index($0, "site ") == 1 { on = index($0, head) == 1 } on'
}
# reported <site> <rule id> [args...]: the site's section lists the rule.
reported() {
  local site="$1" id="$2"
  shift 2
  report_site "$site" "$@" | grep -Eq "^  $id [0-9]+ " || { report "$@" >&2; fail "the report lacks rule $id for site $site"; }
}

# The report scenario: the traefik scenario's sites (detect in mode detect
# again), attacks and bodies over the inspection limit sent with
# credentials, then the report and the log. Runs after traefik or alone.
test_report() {
  local creds rc
  echo "== report (ubuntu $1)"
  converge "${traefik_args[@]}"
  await 200 detect.test /
  await 200 block.test /
  await 200 hooks.test /
  creds=(-H 'Authorization: Basic c2VjcmV0OnNlY3JldA==' -H 'Cookie: session=topsecret' -H 'X-N8N-API-KEY: apikeyvalue')

  echo "-- attacks with credentials"
  expect 200 detect.test '/?exec=/bin/bash' "${creds[@]}"
  expect 200 detect.test '/search?exec=/bin/bash' "${creds[@]}"
  expect 403 block.test '/?exec=/bin/bash' "${creds[@]}"
  # Credential headers and cookies are never inspected, so no rule copies
  # their values into the log; other headers still are.
  expect 200 block.test /in-credentials -H 'Authorization: Basic c2VjcmV0OnNlY3JldA==() { :; };' \
    -H 'Cookie: session=topsecret/bin/bash' -H 'X-N8N-API-KEY: apikeyvalue() { :; };'
  expect 403 block.test /in-header -H 'X-Probe: () { :; }; echo'

  echo "-- bodies over the inspection limit: logged in detect, 413 in block"
  # 14 MiB (the limit is 12.5 MiB) in a form type the Core Rule Set allows,
  # without Expect (CRS refuses it, 920450).
  h sh -c 'head -c 14680064 /dev/zero | tr "\0" a >/tmp/heavy'
  expect 200 detect.test /upload -X POST -H 'Content-Type: application/x-www-form-urlencoded' -H 'Expect:' \
    --data-binary @/tmp/heavy "${creds[@]}"
  expect 413 block.test /upload -X POST -H 'Content-Type: application/x-www-form-urlencoded' -H 'Expect:' \
    --data-binary @/tmp/heavy "${creds[@]}"
  expect 413 block.test /upload-chunked -X POST -H 'Content-Type: application/x-www-form-urlencoded' -H 'Expect:' \
    -H 'Transfer-Encoding: chunked' --data-binary @/tmp/heavy "${creds[@]}"
  # An exclusion's path keeps the site's limit; a bypassed path has none.
  expect 413 hooks.test /webhook/upload -X POST -H 'Content-Type: application/x-www-form-urlencoded' -H 'Expect:' \
    --data-binary @/tmp/heavy
  expect 200 registry.test /v2/x/blobs/uploads/2 -X PATCH -H 'Content-Type: application/octet-stream' \
    --data-binary @/tmp/heavy
  if recorded | grep -Eq '^POST /upload|/in-header'; then
    recorded >&2
    fail "the backend of block.test got a refused request"
  fi

  echo "-- the report per site"
  reported detect 932160 --since 10m detect
  reported detect 9599903 --since 10m detect
  if report --since 10m detect | grep -q '^site block '; then
    report --since 10m detect >&2
    fail "the report for site detect lists site block"
  fi
  report_site detect --since 10m detect | grep -qF 'GET /search?exec=/bin/bash' \
    || { report --since 10m detect >&2; fail "the report lacks an example URI"; }
  reported detect 932160 --since 10m
  reported block 949110 --since 10m
  reported block 932170 --since 10m
  [ "$(report --since 10m nothing)" = 'no events' ] || fail "the report of a site without events is not: no events"
  reported detect 932160
  rc=0
  report --bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "the report exited $rc on --bogus, expected 2"
  rc=0
  report --since soon >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "the report exited $rc on --since soon, expected 2"

  echo "-- the log: JSON audit lines, no credentials"
  audit | python3 -c 'import json, sys; [json.loads(line) for line in sys.stdin]' \
    || { audit >&2; fail "an audit line is not JSON"; }
  if h docker logs "$waf" 2>&1 | grep -E 'c2VjcmV0|topsecret|apikeyvalue'; then
    fail "the WAF's log holds a credential"
  fi

  h docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' "$waf" | tee "$out/memory-report-$1.txt"
}

# The host scenario: the WAF for the host's nginx on 127.0.0.1:8930, with
# recorders on the test host's loopback in nginx's place. static uses the
# default backend, nginx's inner listener 127.0.0.1:8931; cached has a
# backend (a cache, say) on 8939 and the inner listener as its fallback.
host_args=(-e test_waf=true -e '{"waf_mode": "host", "waf_sites": [
  {"name": "static", "domains": ["static.test"], "mode": "block"},
  {"name": "cached", "domains": ["cached.test"], "mode": "block",
   "backend": "http://127.0.0.1:8939", "backend_fallback": "http://127.0.0.1:8931"}]}')
waf_marker='# Written by the noixdev.infra.waf role (traefik mode).'

# start_recorder <name> <port> [status] [headers]: recorder.py on the test
# host's loopback, answering status (200) and printing the headers (a comma
# list); its lines go to /tmp/recorder-<name>.log.
start_recorder() {
  docker exec -d "$host" sh -c "echo \$\$ >/tmp/recorder-$1.pid
    exec python3 -u /opt/waf-host/recorder.py --bind 127.0.0.1 --port $2 --status ${3:-200} --headers '${4:-}' >>/tmp/recorder-$1.log 2>&1"
  for _ in $(seq 30); do
    [ -n "$(h ss -Hltn "sport = :$2")" ] && return 0
    sleep 1
  done
  fail "the recorder $1 does not listen on port $2"
}
# stop_recorder <name> <port>
stop_recorder() {
  h sh -c "kill \$(cat /tmp/recorder-$1.pid)"
  for _ in $(seq 30); do
    [ -z "$(h ss -Hltn "sport = :$2")" ] && return 0
    sleep 1
  done
  fail "the recorder $1 still listens on port $2"
}
# host_recorded <name>: the recorder's lines, as recorded.
host_recorded() { h cat "/tmp/recorder-$1.log"; }
# got_request <name> <path>: the recorder got GET <path>.
got_request() {
  host_recorded "$1" | grep -qF "GET $2 HTTP/1.1 | " || { host_recorded "$1" >&2; fail "the recorder $1 did not get $2"; }
}
# no_request <name> <text>: no request line the recorder got holds the text.
no_request() {
  if host_recorded "$1" | cut -d'|' -f1 | grep -qF -- "$2"; then
    host_recorded "$1" >&2
    fail "the recorder $1 got a request with $2"
  fi
}

# The host scenario's nginx half: the php and nginx roles after the WAF
# (nginx.yml). app (PHP, block), secure (PHP with TLS, block) and proxied (a
# recorder on 8940 with TLS, detect) go through the WAF to nginx's inner
# block on 127.0.0.1:8931; plain does not.
nginx_args=(-e test_waf=true -e test_nginx=true -e "@$here/nginx.yml")
# The nginx role alone, for the refusals: no setup, no WAF, no php role.
nginx_alone=(-e test_setup=false -e test_waf=false -e test_nginx_prepare=false)
# The headers the proxied recorder prints, in this order.
proxied_headers=X-Forwarded-Proto,X-Forwarded-Port,X-Forwarded-Host,X-Forwarded-For,X-Real-IP,X-Noix-Inner-Extra,X-Noix-Site,X-Noix-Front
# Test-only values of the headers the Varnish work will add in front of the
# WAF: a host-wide key (64 hex digits) and a purge token.
front_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
purge_token=noix-test-purge-token-4711
# A client address of the test host's own (RFC 5737): requests from it are
# not from the loopback, which the inner block trusts.
client=192.0.2.10

# site <host> <path> [curl args...]: the body, an empty line and the
# status of a request to nginx on the test host from the client address,
# over HTTPS for secure.test and proxied.test.
site() {
  local name="$1" path="$2" url
  shift 2
  case "$name" in
    secure.test | proxied.test) url="https://$name$path" ;;
    *) url="http://$name$path" ;;
  esac
  h curl -sk --max-time 30 --interface "$client" --resolve "$name:80:127.0.0.1" --resolve "$name:443:127.0.0.1" \
    -w '\n%{http_code}' "$@" "$url" || true
}
# site_expect <want> <host> <path> [curl args...]: site's status must be want.
site_expect() {
  local want="$1" got
  shift
  got="$(site "$@" | tail -n 1)"
  [ "$got" = "$want" ] || fail "nginx site $*: got $got, expected $want"
}
# php_log: the PHP pool's log of app and secure (one noix-app line per
# request that reached PHP).
php_log() { h cat /var/log/php/app.log 2>/dev/null || true; }
# log_lines <file>: the number of lines of a log on the test host.
log_lines() { h sh -c "wc -l <$1" | tr -d ' '; }
# nginx_state: the nginx role's files and www-data's groups, to show that a
# refused run changed nothing.
nginx_state() { h sh -c 'find /etc/nginx -type f -exec md5sum {} + | sort; id -nG www-data'; }
# nginx_refused <log name> <text> [-e ...]: the nginx role alone must fail
# with the text in its log.
nginx_refused() {
  local name="$1" text="$2"
  shift 2
  if play "$name" "${nginx_args[@]}" "${nginx_alone[@]}" "$@"; then
    cat "$out/$name.log" >&2
    fail "the nginx run $name succeeded but must fail"
  fi
  expect_in_log "$name" "$text"
}
# proxied_line <path>: the proxied recorder's line of GET <path>.
proxied_line() { host_recorded proxied | grep -F "GET $1 HTTP/1.1 | " || { host_recorded proxied >&2; fail "the proxied recorder did not get $1"; }; }

host_nginx() {
  local got before fixture state app proxied global
  echo "-- the nginx sites without waf render as before"
  rm -rf "$out/nginx-after"
  mkdir -p "$out/nginx-after"
  ansible-playbook "$here/nginx-render.yml" -e "render_dir=$out/nginx-after" >"$out/nginx-render.log" 2>&1 \
    || { cat "$out/nginx-render.log" >&2; fail "the nginx site variants did not render"; }
  diff -r "$here/fixtures/nginx-before" "$out/nginx-after" || fail "a site without waf renders otherwise than before"

  echo "-- nginx in front of the WAF"
  # The traefik scenario's Traefik holds 127.0.0.1:80.
  if h test -e /opt/traefik/compose.yaml; then
    h docker compose -f /opt/traefik/compose.yaml rm -s -f traefik >/dev/null 2>&1
  fi
  [ -z "$(h ss -Hltn 'sport = :80')" ] || fail "port 80 is taken before nginx: $(h ss -Hltn 'sport = :80')"
  h ip addr replace "$client/32" dev lo
  start_recorder proxied 8940 200 "$proxied_headers"
  # app and secure first; proxied joins the running setup, where the WAF
  # sends its probe to the inner listener before proxied has a block there.
  converge "${nginx_args[@]}" -e '{"test_without": ["proxied"], "test_nginx_without": ["proxied"]}'
  site_expect 200 app.test /
  converge "${nginx_args[@]}"
  converge_unchanged "${nginx_args[@]}"
  # The probe (/.noix-front-probe) is answered on the inner side: it reaches
  # no app, and no rule of the WAF matches it (the first run's probe, before
  # the inner listener exists, is logged with its 502 and the site rule
  # 9599906 alone).
  if php_log | grep -qF noix-front-probe; then fail "the WAF probe reached PHP"; fi
  got="$(audit | grep -F noix-front-probe | grep -o '"ruleId":"[0-9]*"' | grep -v '"9599906"' || true)"
  [ -z "$got" ] || { audit >&2; fail "a WAF rule matched its probe: $got"; }
  if audit | grep -F noix-front-probe | grep -qF '"http_code":403'; then audit >&2; fail "the WAF refused its probe"; fi

  echo "-- app: PHP behind the WAF sees the client, not the loopback, and an attack never reaches it"
  got="$(site app.test / -H 'X-Forwarded-For: 203.0.113.9')"
  [ "$got" = "$(printf '{"remote_addr":"%s","https":"","server_port":"80"}\n\n200' "$client")" ] || fail "app answered: $got"
  got="$(site secure.test /)"
  [ "$got" = "$(printf '{"remote_addr":"%s","https":"on","server_port":"443"}\n\n200' "$client")" ] || fail "secure answered: $got"
  site_expect 403 app.test '/?exec=/bin/bash'
  site_expect 403 secure.test '/?exec=/bin/bash'
  php_log | grep -qF 'noix-app /' || { php_log >&2; fail "the PHP log lacks app's requests"; }
  if php_log | grep -qF 'exec='; then php_log >&2; fail "an attack reached PHP"; fi
  reported app 932160 --since 10m

  echo "-- a streamed answer passes the front hop unbuffered"
  # The first line within 2 s, the second only after 4 s: curl stops at 2 s.
  got="$(h curl -sN --max-time 2 --interface "$client" -H 'Host: app.test' http://127.0.0.1/stream || true)"
  [ "$got" = first ] || fail "app's stream gave within 2 s: $got"

  echo "-- plain: served by nginx without the WAF, its config as before"
  before="$(audit_lines)"
  got="$(site plain.test '/?exec=/bin/bash')"
  [ "$got" = "$(printf 'plain index\n\n200')" ] || fail "plain answered: $got"
  [ "$(audit_lines)" = "$before" ] || { audit >&2; fail "plain's request went through the WAF"; }
  fixture=plain.conf
  [ -z "$(h ip -6 addr show scope global)" ] || fixture=plain-ipv6.conf
  h cat /etc/nginx/sites/plain.conf | diff "$here/fixtures/nginx-before/$fixture" - || fail "plain.conf is not as before"

  echo "-- proxied: detect lets an attack pass and logs it; the backend gets the public block's X-Forwarded-*"
  site_expect 200 proxied.test '/?exec=/bin/bash'
  reported proxied 932160 --since 10m
  site_expect 200 proxied.test /forwarded -H 'X-Forwarded-For: 203.0.113.9'
  got="$(proxied_line /forwarded)"
  case "$got" in
    *" | X-Forwarded-Proto: https | X-Forwarded-Port: 443 | X-Forwarded-Host: proxied.test | X-Forwarded-For: 203.0.113.9, $client | X-Real-IP: $client | "*) ;;
    *) fail "the proxied backend got: $got" ;;
  esac
  site_expect 200 proxied.test /inner-extra
  case "$(proxied_line /inner-extra)" in
    *" | X-Noix-Inner-Extra: seen | "*) ;;
    *) fail "inner_extra did not set its header: $(proxied_line /inner-extra)" ;;
  esac

  echo "-- the Varnish headers pass the WAF unchanged and never reach its log"
  site_expect 200 proxied.test /varnish -H 'X-Noix-Site: proxied' -H "X-Noix-Front: $front_key" -H "X-Purge-Token: $purge_token"
  # A header value that starts with a function definition matches a CRS
  # rule (932170) for any header the WAF inspects, and the log would then
  # hold the value.
  site_expect 200 proxied.test /varnish-attack -H 'X-Noix-Site: proxied' -H "X-Noix-Front: () { :; }; echo $front_key" \
    -H "X-Purge-Token: () { :; }; echo $purge_token"
  case "$(proxied_line /varnish)" in
    *" | X-Noix-Site: proxied | X-Noix-Front: $front_key") ;;
    *) fail "the Varnish headers did not arrive unchanged: $(proxied_line /varnish)" ;;
  esac
  case "$(proxied_line /varnish-attack)" in
    *" | X-Noix-Site: proxied | X-Noix-Front: () { :; }; echo $front_key") ;;
    *) fail "the Varnish headers did not arrive unchanged: $(proxied_line /varnish-attack)" ;;
  esac
  if h docker logs "$waf" 2>&1 | grep -F -e "$front_key" -e "$purge_token"; then
    fail "the WAF's log holds the front key or the purge token"
  fi

  echo "-- redirects name no inner port, and each request is logged once"
  got="$(site app.test /sub -o /dev/null -D - | tr -d '\r')"
  grep -q '^HTTP/1.1 301 ' <<<"$got" || fail "app.test/sub did not redirect: $got"
  grep -qi '^Location: ' <<<"$got" || fail "app.test/sub has no Location: $got"
  if grep -i '^Location: ' <<<"$got" | grep -qF 8931; then fail "the redirect names the inner port: $got"; fi
  before="$(log_lines /var/log/nginx/app.access.log) $(log_lines /var/log/nginx/proxied.access.log) $(log_lines /var/log/nginx/access.log)"
  site_expect 200 app.test /once
  site_expect 403 app.test '/once?exec=/bin/bash'
  site_expect 301 app.test /sub
  site_expect 200 proxied.test /once
  read -r app proxied global <<<"$before"
  got="$(log_lines /var/log/nginx/app.access.log) $(log_lines /var/log/nginx/proxied.access.log) $(log_lines /var/log/nginx/access.log)"
  [ "$got" = "$((app + 3)) $((proxied + 1)) $global" ] || fail "the access logs grew from $before to $got, expected 3 and 1 lines"

  echo "-- invalid waf settings of nginx are refused before any change"
  state="$(nginx_state)"
  nginx_refused nginx-inner-extra 'nginx: nginx_sites entry plain sets inner_extra, but has no inner server block (only a site with waf has one)' \
    -e '{"nginx_sites": [{"name": "plain", "domains": ["plain.test"], "user": "app_plain", "root": "/srv/plain", "tls": "off", "inner_extra": "return 204;"}]}'
  nginx_refused nginx-waf-string 'nginx: nginx_sites entry plain has an invalid hardening, hsts, user_includes, anubis, waf,' \
    -e '{"nginx_sites": [{"name": "plain", "domains": ["plain.test"], "user": "app_plain", "root": "/srv/plain", "tls": "off", "waf": "yes"}]}'
  nginx_refused nginx-inner-port 'nginx: nginx_anubis_port (8923), nginx_waf_port (8930) and nginx_inner_port (443) must be three different ports' \
    -e nginx_inner_port=443
  [ "$(nginx_state)" = "$state" ] || fail "a refused nginx run changed nginx's files"

  echo "-- the WAF stopped: 502 from nginx, never PHP, and nginx runs are refused before any change"
  h docker stop "$waf" >/dev/null
  site_expect 502 app.test /while-down
  if php_log | grep -qF /while-down; then fail "app reached PHP without the WAF"; fi
  nginx_refused nginx-no-waf 'nginx: nginx_sites entries app, secure, proxied set waf, but the WAF does not answer on http://127.0.0.1:8930/'
  [ "$(nginx_state)" = "$state" ] || fail "the refused nginx run changed nginx's files"
  converge "${nginx_args[@]}"
  site_expect 200 app.test /

  echo "-- a waf site the WAF does not know is refused, naming it"
  state="$(nginx_state)"
  if play nginx-421 "${nginx_args[@]}" -e test_setup=false -e test_nginx_prepare=false -e '{"test_without": ["app"]}'; then
    cat "$out/nginx-421.log" >&2
    fail "the nginx run with app missing from waf_sites succeeded"
  fi
  expect_in_log nginx-421 'nginx: nginx_sites entry app sets waf, but the WAF on http://127.0.0.1:8930/ answers 421 for app.test'
  [ "$(nginx_state)" = "$state" ] || fail "the refused nginx run changed nginx's files"
  converge "${nginx_args[@]}"
  site_expect 200 app.test /
  converge_unchanged "${nginx_args[@]}"
  stop_recorder proxied 8940
}

# The host scenario, on the host of the others (it removes the waf.yml of
# the traefik scenario) or alone.
test_host() {
  local got
  echo "== host (ubuntu $1)"
  h mkdir -p /opt/waf-host
  hi sh -c 'cat >/opt/waf-host/recorder.py' <"$here/recorder.py"
  start_recorder inner 8931
  # Alone, a waf.yml as traefik mode leaves it.
  if ! h test -e /opt/traefik/dynamic/waf.yml; then
    h mkdir -p /opt/traefik/dynamic
    printf '%s\n' "$waf_marker" | hi sh -c 'cat >/opt/traefik/dynamic/waf.yml'
  fi
  h grep -qxF -- "$waf_marker" /opt/traefik/dynamic/waf.yml || fail "the waf.yml before host mode is not the role's"
  converge "${host_args[@]}"
  converge_unchanged "${host_args[@]}"

  echo "-- the container on the host's loopback, no Traefik objects"
  got="$(h docker inspect -f '{{.HostConfig.NetworkMode}} {{.HostConfig.ReadonlyRootfs}} {{.Config.User}} {{.HostConfig.CapDrop}} {{len .HostConfig.PortBindings}}' "$waf" || true)"
  [ "$got" = "host true 101:101 [ALL] 0" ] || fail "the WAF container runs as: $got"
  got="$(h ss -Hltn 'sport = :8930' | awk '{print $4}' | sort -u)"
  [ "$got" = 127.0.0.1:8930 ] || fail "port 8930 listens on: $got"
  h test ! -e /opt/traefik/dynamic/waf.yml || fail "host mode left waf.yml"
  [ -z "$(h docker ps -aq --filter name=noixdev-waf-check)" ] || fail "the check container was left behind"
  expect 421 unknown.test :8930/

  echo "-- a site on nginx's inner listener: attacks answer 403 and never reach it"
  expect 200 static.test :8930/
  expect 403 static.test ':8930/?exec=/bin/bash'
  expect 403 static.test :8930/ -A Nikto
  got_request inner /
  no_request inner exec=
  reported static 932160 --since 10m

  echo "-- the client's address from the X-Forwarded-For of 127.0.0.1"
  # Recursive: the loopback's own entries are skipped.
  expect 403 static.test ':8930/?exec=/bin/bash&xff=1' -H 'X-Forwarded-For: 198.51.100.7, 127.0.0.1'
  audit | grep -F 'xff=1' | grep -qF '"client_ip":"198.51.100.7"' \
    || { audit >&2; fail "ModSecurity did not see the client's address"; }

  echo "-- a fallback while the backend does not answer, never on a status it answers"
  # Nothing listens on the backend's port 8939.
  expect 200 cached.test :8930/fallback
  got_request inner /fallback
  expect 403 cached.test ':8930/fallback?exec=/bin/bash'
  no_request inner exec=
  start_recorder primary 8939
  # The WAF tries a backend that did not answer again after 5 s
  # (waf_fallback_retry).
  sleep 6
  expect 200 cached.test :8930/primary
  got_request primary /primary
  no_request inner /primary
  stop_recorder primary 8939
  start_recorder unavailable 8939 503
  expect 503 cached.test :8930/unavailable
  got_request unavailable /unavailable
  no_request inner /unavailable
  stop_recorder unavailable 8939
  stop_recorder inner 8931
  host_nginx

  h docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' "$waf" | tee "$out/memory-host-$1.txt"
}

# All scenarios by default; NOIXDEV_INFRA_WAF_TESTS="refusals" runs only these.
scenarios="${NOIXDEV_INFRA_WAF_TESTS:-refusals traefik report host}"
for ubuntu in $releases; do
  start_host "$ubuntu" waf
  for scenario in $scenarios; do
    case "$scenario" in
      refusals) test_refusals "$ubuntu" ;;
      traefik) test_traefik "$ubuntu" ;;
      report) test_report "$ubuntu" ;;
      host) test_host "$ubuntu" ;;
      *) fail "unknown scenario $scenario (refusals traefik report host)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all waf tests passed"
