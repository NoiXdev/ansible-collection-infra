#!/usr/bin/env bash
# Host roles (base, docker, fail2ban, crowdsec, tailscale) on a systemd Ubuntu container:
# converge twice (the second run must change nothing), then verify.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
ubuntu="${UBUNTU:-26.04}"
host="${NOIXDEV_INFRA_TEST_HOST:-noixdev-infra-host-$ubuntu}"
out="$tests/output/host-$ubuntu"

cleanup() { [ "${KEEP:-0}" = 1 ] || docker rm -f "$host" >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
ln -sfn "$root" "$tests/output/ansible_collections/noixdev/infra"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"

docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$here" >/dev/null
docker rm -f "$host" >/dev/null 2>&1 || true
docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock --name "$host" "noixdev-infra-host:$ubuntu" >/dev/null
until (docker exec "$host" systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done

play() { ansible-playbook -i "$tests/inventory.yml" -e "test_host=$host" "$@"; }

echo "== converge (ubuntu $ubuntu)"
play "$here/converge.yml"

echo "== idempotence"
play "$here/converge.yml" | tee "$out/idempotence.log"
grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/idempotence.log" \
  || { echo "second converge changed something" >&2; exit 1; }

echo "== verify"
play "$here/verify.yml"

echo "== host roles passed on ubuntu $ubuntu"
