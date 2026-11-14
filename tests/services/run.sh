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

# no_secret LOG SECRET...: LOG exists and contains none of the SECRETs. A
# missing log fails instead of passing.
no_secret() {
  local log="$1" secret rc; shift
  [ -s "$log" ] || fail "the log $log is missing or empty"
  for secret in "$@"; do
    rc=0
    grep -qF -- "$secret" "$log" || rc=$?
    [ "$rc" = 1 ] || fail "$(basename "$log") contains a password ($secret), or grep failed (exit $rc)"
  done
}

# sql ROLE STATEMENT: run a statement as root over the socket, without
# column names.
sql() { hx "$1" mariadb -N -e "$2"; }

suite_mariadb() {
  local dir="$here/mariadb" version bound log grants
  # Parts of the test passwords that their raw and JSON-escaped forms share.
  local secrets=("a'b" '$e%f g' 'rep0rt-pass' "pa ss'%\$")
  local rotated='{"mariadb_test_app_password": "n3w\"pa ss'"'"'%$\\x"}'
  start mariadb

  echo "== mariadb: invalid lists and settings are refused before any change"
  refused mariadb unknown-key "mariadb: mariadb_users entry x has unknown keys (priv); its keys are name, password, host and privileges" \
    "$dir/converge.yml" -e '{"mariadb_users": [{"name": "x", "password": "p", "priv": "x.*:ALL"}]}'
  refused mariadb no-privileges "mariadb: mariadb_users entry orphan has no privileges, and mariadb_databases lists no database orphan; set privileges" \
    "$dir/converge.yml" -e '{"mariadb_users": [{"name": "orphan", "password": "p"}]}'
  refused mariadb root-user "mariadb: mariadb_users entry root is one of the server's own accounts (root, mysql, mariadb.sys), which the role leaves as they are; root logs in through the socket only" \
    "$dir/converge.yml" -e '{"mariadb_users": [{"name": "root", "password": "p", "privileges": ["*.*:ALL"]}]}'
  refused mariadb database-key "mariadb: mariadb_databases entry d has unknown keys (charset); its keys are name, encoding and collation" \
    "$dir/converge.yml" -e '{"mariadb_test_extra_databases": [{"name": "d", "charset": "utf8mb4"}]}'
  refused mariadb collation "mariadb: mariadb_databases entry d has encoding latin1 and collation utf8mb4_unicode_ci; the collation must belong to the encoding" \
    "$dir/converge.yml" -e '{"mariadb_test_extra_databases": [{"name": "d", "encoding": "latin1"}]}'
  for key in bind-address bind_address port socket; do
    refused mariadb "settings-$key" "mariadb: mariadb_settings sets $key; bind-address, port and socket belong to the role (mariadb_bind_address sets the address)" \
      "$dir/converge.yml" -e "{\"mariadb_settings\": {\"$key\": \"0.0.0.0\"}}"
  done
  hx mariadb sh -c 'test ! -e /usr/sbin/mariadbd && test ! -e /etc/apt/sources.list.d/mariadb.sources' \
    || fail "mariadb: a refused run installed something"

  echo "== mariadb: converge (the first run with --diff -v) and idempotence"
  converge mariadb install "$dir/converge.yml" --diff -v
  play mariadb "$dir/verify.yml"
  sql mariadb 'SELECT 1' >/dev/null || fail "mariadb: root cannot log in over the socket"
  bound="$(hx mariadb ss -Hltn 'sport = :3306' | awk '{print $4}' | sort -u | paste -sd' ' -)"
  [ "$bound" = "127.0.0.1:3306" ] || fail "mariadb: the server listens on '$bound', not 127.0.0.1:3306 only"

  echo "== mariadb: an unknown setting fails before the restart, the server keeps running"
  refused mariadb unknown-setting "failed to validate" "$dir/converge.yml" -e '{"mariadb_settings": {"max_conections": 200}}'
  hx mariadb sh -c 'test -s /etc/mysql/mariadb.conf.d/90-noixdev.cnf && ! grep -q max_conections /etc/mysql/mariadb.conf.d/90-noixdev.cnf' \
    || fail "mariadb: the unknown setting reached the config"
  [ "$(hx mariadb systemctl is-active mariadb || true)" = active ] || fail "mariadb: the server stopped after the unknown setting"

  echo "== mariadb: a new password in the vars replaces the old one (with --diff -v)"
  converge mariadb rotate "$dir/converge.yml" --diff -v -e "$rotated"
  play mariadb "$dir/verify.yml" -e "$rotated" -e '{"mariadb_test_old_password": "a'"'"'b\"c\\d$e%f g"}'

  echo "== mariadb: the --diff -v logs have no password"
  for log in install install-idempotence rotate rotate-idempotence; do
    no_secret "$out/mariadb-$log.log" "${secrets[@]}"
  done

  echo "== mariadb: a grant added by hand is revoked"
  sql mariadb "GRANT SELECT ON mysql.* TO 'report'@'localhost'"
  sql mariadb "SHOW GRANTS FOR 'report'@'localhost'" | grep -qF '`mysql`.*' || fail "mariadb: the hand grant did not apply"
  converge mariadb hand-grant "$dir/converge.yml" -e "$rotated"
  grants="$(sql mariadb "SHOW GRANTS FOR 'report'@'localhost'")"
  ! grep -qF '`mysql`' <<<"$grants" || fail "mariadb: the hand grant on mysql.* is still there: $grants"
  grep -qF 'GRANT SELECT ON `app_production`.*' <<<"$grants" || fail "mariadb: report lost its listed grant: $grants"

  echo "== mariadb: a user that leaves the list stays"
  converge mariadb no-report "$dir/converge.yml" -e "$rotated" -e mariadb_test_report=false
  [ "$(sql mariadb "SELECT COUNT(*) FROM mysql.user WHERE User = 'report' AND Host = 'localhost'")" = 1 ] \
    || fail "mariadb: report is gone after it left the list"

  echo "== mariadb: a database that exists keeps its charset"
  sql mariadb 'CREATE DATABASE legacy CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci'
  converge mariadb legacy "$dir/converge.yml" -e "$rotated" -e '{"mariadb_test_extra_databases": [{"name": "legacy"}]}'
  sql mariadb 'SHOW CREATE DATABASE legacy' | grep -qF 'CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci' \
    || fail "mariadb: legacy lost its charset: $(sql mariadb 'SHOW CREATE DATABASE legacy')"

  echo "== mariadb: another series is refused"
  version="$(hx mariadb dpkg-query -W -f='${Version}' mariadb-server)"
  echo "   mariadb-server on $ubuntu: $version"
  refused mariadb other-series "mariadb: installed mariadb-server $version is series 11.8, mariadb_version is 11.4; a series change is a separate, deliberate step" \
    "$dir/converge.yml" -e "$rotated" -e mariadb_version=11.4
  hx mariadb grep -qF '/11.8/' /etc/apt/sources.list.d/mariadb.sources || fail "mariadb: the refused run changed the repository"
  [ "$(hx mariadb dpkg-query -W -f='${Version}' mariadb-server)" = "$version" ] || fail "mariadb: mariadb-server changed after a refused run"
}

docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null

for role in $services; do
  declare -F "suite_$role" >/dev/null || fail "no suite for the role $role"
  "suite_$role"
done
echo "== services ($services) passed on ubuntu $ubuntu"
