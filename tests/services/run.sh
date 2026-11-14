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
  local tries=0
  until (docker exec "$name" systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do
    tries=$((tries + 1))
    [ "$tries" -lt 120 ] || fail "$1: the container $name did not boot within 120 seconds"
    sleep 1
  done
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
# change nothing. The logs are $out/ROLE-NAME.log and
# $out/ROLE-NAME-idempotence.log.
converge() {
  local role="$1" name="$2"; shift 2
  play "$role" "$@" | tee "$out/$role-$name.log"
  play "$role" "$@" | tee "$out/$role-$name-idempotence.log"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/$role-$name-idempotence.log" \
    || fail "$role/$name: the second converge changed something"
}

# refused ROLE NAME MESSAGE PLAYBOOK [args]: the run must fail with MESSAGE
# (in $out/ROLE-NAME.log) and report changed=0.
refused() {
  local role="$1" name="$2" message="$3" log="$out/$1-$2.log"; shift 3
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
  grep -qF "is series 24, nodejs_version is 22; a series change is a separate, deliberate step" "$out/nodejs-other-series.log" \
    || fail "nodejs: the refusal does not name both series"
  [ "$(hx nodejs node --version)" = "$before" ] || fail "nodejs: node changed after a refused run"

  echo "== nodejs: invalid npm package entries"
  refused nodejs no-version "missing required arguments: version" "$dir/converge.yml" \
    -e '{"nodejs_npm_packages": [{"name": "semver"}]}'
  refused nodejs latest-version "nodejs: nodejs_npm_packages entry semver has version latest" "$dir/converge.yml" \
    -e '{"nodejs_npm_packages": [{"name": "semver", "version": "latest"}]}'
}

# pid ROLE UNIT: the main PID of a unit (0 when it does not run).
pid() { hx "$1" systemctl show -p MainPID --value "$2"; }

# default_active NAME: the package's redis-server still runs after a refusal.
default_active() {
  [ "$(hx redis systemctl is-active redis-server || true)" = active ] \
    || fail "redis/$1: the default instance stopped after the refused run"
}

suite_redis() {
  local dir="$here/redis" version prod staging bound rotate
  start redis

  echo "== redis: the default instance, converge and idempotence"
  converge redis default "$dir/converge.yml"
  [ "$(hx redis redis-cli -h 127.0.0.1 PING)" = PONG ] || fail "redis: the default instance does not answer PING"
  [ "$(hx redis grep -E '^bind ' /etc/redis/redis.conf)" = "bind 127.0.0.1" ] \
    || fail "redis: the default config does not bind 127.0.0.1 only"
  bound="$(hx redis ss -Hltn 'sport = :6379' | awk '{print $4}' | sort -u | paste -sd' ' -)"
  [ "$bound" = "127.0.0.1:6379" ] || fail "redis: the default instance listens on '$bound', not 127.0.0.1:6379 only"

  echo "== redis: lists no instance can run on are refused, the default instance keeps running"
  refused redis long-name "redis: redis_instances entry 'abcdefghijklmnopqrstuvwxyz0' has an invalid name; it must match ^[a-z0-9_-]+$ and be at most 26 characters long" \
    "$dir/converge.yml" -e '{"redis_instances": [{"name": "abcdefghijklmnopqrstuvwxyz0", "unixsocket": true}]}'
  default_active long-name
  refused redis port-high "redis: redis_instances entry h has port 70000; use a port from 1 to 65535" \
    "$dir/converge.yml" -e '{"redis_instances": [{"name": "h", "port": 70000}]}'
  default_active port-high
  refused redis port-zero "redis: redis_instances entry i has port 0; use a port from 1 to 65535" \
    "$dir/converge.yml" -e '{"redis_instances": [{"name": "i", "port": 0}]}'
  default_active port-zero

  echo "== redis: two instances (the first run with --diff -v), idempotence"
  converge redis instances "$dir/instances.yml" --diff -v
  for secret in 's-pass' 'o d$%'; do
    ! grep -qF -- "$secret" "$out/redis-instances.log" "$out/redis-instances-idempotence.log" \
      || fail "redis: a converge log with --diff -v contains a password ($secret)"
  done
  play redis "$dir/verify.yml"

  echo "== redis: the instances log where the package's logrotate rule rotates"
  hx redis grep -qF '/var/log/redis/redis-server*.log' /etc/logrotate.d/redis-server \
    || fail "redis: the package's logrotate rule does not cover /var/log/redis/redis-server*.log"
  rotate="$(hx redis logrotate -d /etc/logrotate.d/redis-server 2>&1)"
  for name in production staging; do
    hx redis test -s "/var/log/redis/redis-server-$name.log" || fail "redis: $name does not write /var/log/redis/redis-server-$name.log"
    grep -qF "/var/log/redis/redis-server-$name.log" <<<"$rotate" || fail "redis: logrotate does not consider $name's log"
  done

  echo "== redis: a changed maxmemory restarts staging only"
  prod="$(pid redis redis-server@production)"
  staging="$(pid redis redis-server@staging)"
  converge redis maxmemory "$dir/instances.yml" -e redis_test_staging_maxmemory=32mb
  [ "$(pid redis redis-server@production)" = "$prod" ] || fail "redis: production restarted on staging's change"
  [ "$(pid redis redis-server@staging)" != "$staging" ] || fail "redis: staging did not restart on its change"
  [ "$(hx redis redis-cli -s /run/redis-staging/redis.sock -a s-pass --no-auth-warning CONFIG GET maxmemory | tail -1)" = 33554432 ] \
    || fail "redis: staging's maxmemory is not 32mb"

  echo "== redis: an instance that leaves the list stops, its data stays"
  converge redis no-staging "$dir/instances.yml" -e redis_test_staging=false
  [ "$(hx redis systemctl is-active redis-server@staging || true)" = inactive ] || fail "redis: staging still runs"
  [ "$(hx redis systemctl is-enabled redis-server@staging || true)" = disabled ] || fail "redis: staging is still enabled"
  hx redis test -d /var/lib/redis/staging || fail "redis: staging's data dir is gone"
  [ "$(pid redis redis-server@production)" = "$prod" ] || fail "redis: production restarted when staging left"

  echo "== redis: invalid instance lists are refused"
  refused redis unknown-client "redis: redis_instances entry staging lists the user nosuchuser in clients, which does not exist" \
    "$dir/instances.yml" -e '{"redis_test_staging_clients": ["nosuchuser"]}'
  hx redis sh -c '! getent passwd nosuchuser' || fail "redis: the refused run created nosuchuser"
  [ "$(hx redis systemctl is-active redis-server@staging || true)" = inactive ] || fail "redis: the refused run started staging"
  refused redis duplicate-name "redis: redis_instances has more than one entry named a" "$dir/instances.yml" \
    -e '{"redis_instances": [{"name": "a", "port": 6390}, {"name": "a", "port": 6391}]}'
  refused redis duplicate-port "redis: redis_instances entries b and c use the same port 6390" "$dir/instances.yml" \
    -e '{"redis_instances": [{"name": "b", "port": 6390}, {"name": "c", "port": 6390}]}'
  refused redis port-and-socket "redis: redis_instances entry d has both port and unixsocket; set exactly one of them" \
    "$dir/instances.yml" -e '{"redis_instances": [{"name": "d", "port": 6390, "unixsocket": true}]}'
  refused redis no-listener "redis: redis_instances entry e has neither port nor unixsocket; set exactly one of them" \
    "$dir/instances.yml" -e '{"redis_instances": [{"name": "e"}]}'
  refused redis socket-false "redis: redis_instances entry g has unixsocket false; leave it out and set port instead" \
    "$dir/instances.yml" -e '{"redis_instances": [{"name": "g", "port": 6390, "unixsocket": false}]}'
  refused redis port-clients "redis: redis_instances entry f has clients, but only a socket instance takes clients" \
    "$dir/instances.yml" -e '{"redis_instances": [{"name": "f", "port": 6390, "clients": ["app_prod"]}]}'

  echo "== redis: another series is refused"
  version="$(hx redis dpkg-query -W -f='${Version}' redis-server)"
  echo "   redis-server on $ubuntu: $version"
  refused redis other-series "redis: installed redis-server $version is series 8, redis_version is 7; a series change is a separate, deliberate step" \
    "$dir/instances.yml" -e redis_version=7
  [ "$(hx redis dpkg-query -W -f='${Version}' redis-server)" = "$version" ] || fail "redis: redis-server changed after a refused run"
}

docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null

for role in $services; do
  declare -F "suite_$role" >/dev/null || fail "no suite for the role $role"
  "suite_$role"
done
echo "== services ($services) passed on ubuntu $ubuntu"
