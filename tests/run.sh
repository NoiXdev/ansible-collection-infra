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
docker exec "$host" apk add --no-cache python3 >/dev/null

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

echo "== turning error pages off cleans up"
play "$here/converge.yml" -e '{"traefik_error_pages_enabled": false}' >"$out/error-pages-off.log"
play "$here/error_pages_disabled.yml"

echo "== all tests passed"
