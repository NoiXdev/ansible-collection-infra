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

echo "== all tests passed"
