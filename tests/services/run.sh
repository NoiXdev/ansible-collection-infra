#!/usr/bin/env bash
# Host service roles (nodejs, redis, mariadb, mysql) on a systemd Ubuntu
# container, one fresh container per role:
#
#   NOIXDEV_INFRA_SERVICES="nodejs redis" UBUNTU=26.04 tests/services/run.sh
#
# NOIXDEV_INFRA_SERVICES selects the roles (default: all of them). Containers
# are named ${NOIXDEV_INFRA_TEST_HOST:-noixdev-infra-services-$UBUNTU}-<role>
# and removed at the end (KEEP=1 keeps them). Only those names are touched:
# other suites may share this Docker.
# The single-quoted scripts expand inside the container, not here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
ubuntu="${UBUNTU:-26.04}"
prefix="${NOIXDEV_INFRA_TEST_HOST:-noixdev-infra-services-$ubuntu}"
out="$tests/output/services-$ubuntu"
services="${NOIXDEV_INFRA_SERVICES:-nodejs redis mariadb mysql}"

started=()
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return
  for name in ${started[@]+"${started[@]}"}; do docker rm -f -v "$name" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
ln -sfn "$root" "$tests/output/ansible_collections/noixdev/infra"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"

fail() { echo "$*" >&2; exit 1; }

# start ROLE: a fresh systemd container for the role's suite.
start() {
  local name="$prefix-$1"
  docker rm -f -v "$name" >/dev/null 2>&1 || true
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock --name "$name" "noixdev-infra-host:$ubuntu" >/dev/null
  started+=("$name")
  until (docker exec "$name" systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
}

# hx ROLE CMD...: run a command in the role's container.
hx() { local role="$1"; shift; docker exec "$prefix-$role" "$@"; }

# play ROLE PLAYBOOK [ansible-playbook args]: run a playbook against the
# role's container.
play() {
  local role="$1"; shift
  ansible-playbook -i "$tests/inventory.yml" -e "test_host=$prefix-$role" "$@"
}

# converge ROLE NAME PLAYBOOK [args]: the run must pass, and a second one must
# change nothing. The log of the second run is $out/NAME-idempotence.log.
converge() {
  local role="$1" name="$2"; shift 2
  play "$role" "$@"
  play "$role" "$@" | tee "$out/$name-idempotence.log"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/$name-idempotence.log" \
    || fail "$role/$name: the second converge changed something"
}

# refused ROLE LOG MESSAGE PLAYBOOK [args]: the run must fail with MESSAGE
# (in $out/LOG.log) and report changed=0.
refused() {
  local role="$1" name="$2" message="$3" log="$out/$2.log"; shift 3
  if play "$role" "$@" >"$log" 2>&1; then
    fail "$role/$name: the run did not fail"
  fi
  grep -qF -- "$message" "$log" || { cat "$log" >&2; fail "$role/$name: expected the message: $message"; }
  grep -Eq 'changed=0 +unreachable=0 ' "$log" || { cat "$log" >&2; fail "$role/$name: the refused run changed something"; }
  echo "   $name: refused"
}

suite_nodejs() {
  local dir="$here/nodejs" distro before pkgs='{"nodejs_npm_packages": [{"name": "semver", "version": "7.7.2"}]}'
  start nodejs
  hx nodejs apt-get update -q >/dev/null

  echo "== nodejs: the distro's nodejs is refused (another series)"
  hx nodejs env DEBIAN_FRONTEND=noninteractive apt-get install -y -q nodejs >/dev/null
  distro="$(hx nodejs dpkg-query -W -f='${Version}' nodejs)"
  echo "   distro nodejs on $ubuntu: $distro"
  case "$distro" in
    24.*)
      # The distro already ships the pinned series, so the role adopts it.
      # The refusal is shown with a pinned other major instead.
      refused nodejs distro-series "installed nodejs $distro is series 24, nodejs_version is 22" \
        "$dir/converge.yml" -e nodejs_version=22 ;;
    *)
      refused nodejs distro-series "nodejs: installed nodejs $distro is series ${distro%%.*}, nodejs_version is 24; a series change is a separate, deliberate step" \
        "$dir/converge.yml" ;;
  esac
  hx nodejs sh -c '! ls /etc/apt/sources.list.d/ | grep -qi nodesource' || fail "nodejs: the refused run left a NodeSource file"
  hx nodejs sh -c 'test ! -e /etc/apt/keyrings/nodesource.asc' || fail "nodejs: the refused run left the key"

  echo "== nodejs: converge and idempotence"
  hx nodejs env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q nodejs >/dev/null
  converge nodejs install "$dir/converge.yml" -e "$pkgs"
  play nodejs "$dir/verify.yml" -e "$pkgs"

  echo "== nodejs: another series is refused, node stays as it is"
  before="$(hx nodejs node --version)"
  refused nodejs other-series "nodejs: installed nodejs ${before#v}" "$dir/converge.yml" -e nodejs_version=22 -e "$pkgs"
  grep -qF "is series 24, nodejs_version is 22; a series change is a separate, deliberate step" "$out/other-series.log" \
    || fail "nodejs: the refusal does not name both series"
  [ "$(hx nodejs node --version)" = "$before" ] || fail "nodejs: node changed after a refused run"

  echo "== nodejs: invalid npm package entries"
  refused nodejs no-version "missing required arguments: version" "$dir/converge.yml" \
    -e '{"nodejs_npm_packages": [{"name": "semver"}]}'
  refused nodejs latest-version "nodejs: nodejs_npm_packages entry semver has version latest" "$dir/converge.yml" \
    -e '{"nodejs_npm_packages": [{"name": "semver", "version": "latest"}]}'
}

docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null

for role in $services; do
  declare -F "suite_$role" >/dev/null || fail "no suite for the role $role"
  "suite_$role"
done
echo "== services ($services) passed on ubuntu $ubuntu"
