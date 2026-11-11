#!/usr/bin/env bash
# End-to-end test of the container roles inside a throwaway Docker-in-Docker
# host: converge twice (the second run must change nothing), then verify.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
host="${NOIXDEV_INFRA_TEST_HOST:-noixdev-infra-test}"
out="$here/output"

cleanup() { [ "${KEEP:-0}" = 1 ] || docker rm -f "$host" >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p "$out/ansible_collections/noixdev"
ln -sfn "$root" "$out/ansible_collections/noixdev/infra"
export ANSIBLE_COLLECTIONS_PATH="$out:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"
export ANSIBLE_HOST_KEY_CHECKING=False

docker rm -f "$host" >/dev/null 2>&1 || true
docker run -d --privileged --name "$host" docker:29-dind >/dev/null
until docker exec "$host" docker info >/dev/null 2>&1; do sleep 1; done
docker exec "$host" apk add --no-cache python3 bind-tools >/dev/null
# A second local address: queries to it come from outside dns_allow.
docker exec "$host" ip addr add 192.0.2.53/32 dev lo
# An /etc/hosts entry on the host must never be served by the dns role.
docker exec "$host" sh -c 'echo "203.0.113.7 leak.internal.test" >> /etc/hosts'

play() { ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$@"; }

echo "== converge"
play "$here/converge.yml"

echo "== idempotence"
play "$here/converge.yml" | tee "$out/idempotence.log"
grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/idempotence.log" \
  || { echo "second converge changed something" >&2; exit 1; }

echo "== verify"
play "$here/verify.yml"

echo "== remote worker without token must fail"
if play "$here/worker_without_token.yml" >"$out/no-token.log" 2>&1; then
  echo "pulsix_worker started a worker that has neither identity nor token" >&2
  exit 1
fi
grep -q "No enrollment token for: edge-1" "$out/no-token.log" \
  || { cat "$out/no-token.log" >&2; exit 1; }

echo "== invalid error pages settings must fail"
if play "$here/error_pages_invalid.yml" >"$out/error-pages-invalid.log" 2>&1; then
  echo "traefik accepted error pages on a redirect or unknown entrypoint" >&2
  exit 1
fi
grep -q "Error pages entrypoints must exist" "$out/error-pages-invalid.log" \
  || { cat "$out/error-pages-invalid.log" >&2; exit 1; }
docker exec "$host" test ! -e /opt/traefik-invalid \
  || { echo "traefik touched the host before checking its settings" >&2; exit 1; }

echo "== invalid dns settings must fail"
if play "$here/dns_invalid.yml" >"$out/dns-invalid.log" 2>&1; then
  echo "dns accepted a wildcard bind address" >&2
  exit 1
fi
grep -q "dns_bind needs specific addresses" "$out/dns-invalid.log" \
  || { cat "$out/dns-invalid.log" >&2; exit 1; }
docker exec "$host" test ! -e /opt/dns-invalid \
  || { echo "dns touched the host before checking its settings" >&2; exit 1; }

echo "== wildcard dns_allow must fail"
if play "$here/dns_invalid_allow.yml" >"$out/dns-invalid-allow.log" 2>&1; then
  echo "dns accepted 0.0.0.0/0 in dns_allow" >&2
  exit 1
fi
grep -q "dns needs a non-empty dns_allow without 0.0.0.0/0" "$out/dns-invalid-allow.log" \
  || { cat "$out/dns-invalid-allow.log" >&2; exit 1; }
docker exec "$host" test ! -e /opt/dns-invalid-allow \
  || { echo "dns touched the host before checking dns_allow" >&2; exit 1; }

# CoreDNS re-reads the records file every few seconds; its cache keeps the old
# answer for up to dns_ttl (60 s), so allow for both.
echo "== changed dns record is served"
play "$here/converge.yml" -e '{"dns_records": [{"name": "app.internal.test", "addresses": ["192.0.2.20"]}]}' >"$out/dns-changed.log"
for _ in $(seq 90); do
  answer="$(docker exec "$host" dig +short @127.0.0.1 app.internal.test A || true)"
  [ "$answer" = "192.0.2.20" ] && break
  sleep 1
done
[ "$answer" = "192.0.2.20" ] \
  || { echo "changed record not served, got: $answer" >&2; exit 1; }
play "$here/converge.yml" >"$out/dns-restored.log"
for _ in $(seq 90); do
  answer="$(docker exec "$host" dig +short @127.0.0.1 app.internal.test A || true)"
  [ "$answer" = "192.0.2.10" ] && break
  sleep 1
done
[ "$answer" = "192.0.2.10" ] \
  || { echo "restored record not served, got: $answer" >&2; exit 1; }

echo "== turning error pages off cleans up"
play "$here/converge.yml" -e '{"traefik_error_pages_enabled": false}' >"$out/error-pages-off.log"
play "$here/error_pages_disabled.yml"

echo "== all tests passed"
