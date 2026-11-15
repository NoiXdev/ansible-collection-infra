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
  local image="noixdev-infra-host:$ubuntu" platform=()
  # MySQL's apt repository carries amd64 packages only: the role's container
  # runs linux/amd64 (emulated on another architecture, with its own image).
  if [ "$1" = mysql ]; then
    image="$image-amd64"
    platform=(--platform linux/amd64)
    docker build -q "${platform[@]}" --build-arg "UBUNTU=$ubuntu" -t "$image" "$tests/host" >/dev/null
  fi
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock ${platform[@]+"${platform[@]}"} --name "$name" "$image" >/dev/null
  started+=("$name")
  local tries=0
  until (docker exec "$name" systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do
    tries=$((tries + 1))
    [ "$tries" -lt 120 ] || fail "$1: the container $name did not boot within 120 seconds"
    sleep 1
  done
  if [ "$1" = mysql ]; then systemd_fallback "$name"; fi
  return 0
}

# systemd_fallback NAME: systemd in an emulated amd64 container (Docker Desktop
# on Apple silicon) boots to degraded but cannot start any service. A probe
# unit tells; when it fails on a Docker host that is not x86_64, a stand-in
# systemctl that runs mysqld directly is installed, and the log says so (the
# final summary repeats it). On an x86_64 Docker host a failing probe fails the
# suite, and when it passes the real systemd and mysql.service run unchanged.
shim_used=0
systemd_fallback() {
  local name="$1" host_arch
  if docker exec "$name" sh -c 'printf "[Service]\nType=oneshot\nExecStart=/bin/true\n" > /etc/systemd/system/noixdev-probe.service \
      && systemctl daemon-reload && systemctl start noixdev-probe.service; rc=$?; rm -f /etc/systemd/system/noixdev-probe.service; exit $rc' >/dev/null 2>&1; then
    return 0
  fi
  host_arch="$(docker info --format '{{.Architecture}}')"
  [ "$host_arch" != x86_64 ] || fail "$name: systemd cannot start a service on an x86_64 Docker host"
  docker cp "$here/systemctl-shim" "$name:/usr/local/bin/systemctl" || fail "$name: the systemctl shim could not be installed"
  shim_used=1
  echo "== WARNING: emulated amd64: mysql.service not exercised, systemctl shim in use"
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
# $out/ROLE-NAME-idempotence.log, with stdout and stderr (warnings and errors
# go to stderr, and the secrets checks read these logs).
converge() {
  local role="$1" name="$2"; shift 2
  play "$role" "$@" 2>&1 | tee "$out/$role-$name.log"
  play "$role" "$@" 2>&1 | tee "$out/$role-$name-idempotence.log"
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

# sql ROLE STATEMENT: run a statement as root over the socket (ROLE is also
# the client's name, mariadb or mysql), without
# column names and raw (batch output would print \ as \\).
sql() { hx "$1" "$1" -N -r -e "$2"; }

suite_mariadb() {
  local dir="$here/mariadb" version bound log grants policy rc denied before
  local empty='{"mariadb_users": [], "mariadb_databases": []}'
  local app_password=$'a\'b"c\\d$e%f g'
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
  refused mariadb password-typo "mariadb: mariadb_users entry x has unknown keys (pasword); its keys are name, password, host and privileges" \
    "$dir/converge.yml" -v -e '{"mariadb_users": [{"name": "x", "password": "p", "pasword": "s3cr3t-typo", "privileges": []}]}'
  no_secret "$out/mariadb-password-typo.log" s3cr3t-typo
  for key in bind-address bind_address port socket; do
    refused mariadb "settings-$key" "mariadb: mariadb_settings sets $key; bind-address, port and socket belong to the role (mariadb_bind_address sets the address)" \
      "$dir/converge.yml" -e "{\"mariadb_settings\": {\"$key\": \"0.0.0.0\"}}"
  done
  hx mariadb sh -c 'test ! -e /usr/sbin/mariadbd && test ! -e /etc/apt/sources.list.d/mariadb.sources' \
    || fail "mariadb: a refused run installed something"

  echo "== mariadb: the distro's MariaDB is refused (another series, or the pinned one from another origin)"
  hx mariadb apt-get update -q >/dev/null
  hx mariadb env DEBIAN_FRONTEND=noninteractive apt-get install -y -q mariadb-server >/dev/null
  version="$(hx mariadb dpkg-query -W -f='${Version}' mariadb-server)"
  echo "   distro mariadb-server on $ubuntu: $version"
  case "$version" in
    1:11.8.*)
      refused mariadb distro-origin "mariadb: installed mariadb-server $version is not from deb.mariadb.org; the role manages MariaDB's own packages only" \
        "$dir/converge.yml" -e "$empty" ;;
    *)
      refused mariadb distro-series "mariadb: installed mariadb-server $version is series 10.11, mariadb_version is 11.8; a series change is a separate, deliberate step" \
        "$dir/converge.yml" -e "$empty" ;;
  esac
  hx mariadb sh -c 'test ! -e /etc/apt/sources.list.d/mariadb.sources && test ! -e /etc/apt/keyrings/mariadb.asc && test ! -e /etc/apt/preferences.d/mariadb' \
    || fail "mariadb: the refused run left repository files"
  [ "$(hx mariadb dpkg-query -W -f='${Version}' mariadb-server)" = "$version" ] || fail "mariadb: the distro package changed after the refused run"
  hx mariadb env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q 'mariadb-*' 'mysql-common' >/dev/null
  hx mariadb env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q --purge >/dev/null
  hx mariadb rm -rf /var/lib/mysql /etc/mysql

  echo "== mariadb: a run whose repository refresh failed is not followed by another series"
  # The first run adds the source and the pin, then its refresh fails: the
  # package lists stay without the vendor's packages.
  hx mariadb sh -c 'echo "127.0.0.1 deb.mariadb.org" >> /etc/hosts'
  if play mariadb "$dir/converge.yml" -e "$empty" >"$out/mariadb-blocked.log" 2>&1; then
    fail "mariadb: the run with deb.mariadb.org unreachable did not fail"
  fi
  hx mariadb sh -c 'grep -v deb.mariadb.org /etc/hosts > /tmp/hosts && cat /tmp/hosts > /etc/hosts'
  hx mariadb test -e /etc/apt/sources.list.d/mariadb.sources || fail "mariadb: the blocked run did not add the source"
  hx mariadb sh -c '! dpkg-query -W -f "\${db:Status-Abbrev}" mariadb-server 2>/dev/null | grep -q "^.i"' \
    || fail "mariadb: the blocked run installed mariadb-server"
  converge mariadb stale-lists "$dir/converge.yml" -e "$empty"
  version="$(hx mariadb dpkg-query -W -f='${Version}' mariadb-server)"
  case "$version" in
    *+maria~*) echo "   installed the vendor's $version" ;;
    *) fail "mariadb: after a failed refresh the role installed $version, not the vendor's" ;;
  esac
  # The vendor's versions win by origin; every other version of the MariaDB
  # packages (the distro's 11.8 on 26.04 too) is never installed.
  policy="$(hx mariadb apt-cache policy mariadb-server mysql-common)"
  awk '$NF ~ /^-?[0-9]+$/ && NF <= 3 { v = $(NF-1); p = $NF
         if ((v ~ /\+maria~/ && p != 990) || (v !~ /\+maria~/ && p != -1)) { print v, p; bad = 1 } }
       END { exit bad }' <<<"$policy" || fail "mariadb: the pin gives the wrong priorities: $policy"

  echo "== mariadb: converge (the first run with --diff -v) and idempotence"
  converge mariadb install "$dir/converge.yml" --diff -v
  play mariadb "$dir/verify.yml"
  sql mariadb 'SELECT 1' >/dev/null || fail "mariadb: root cannot log in over the socket"
  bound="$(hx mariadb ss -Hltn 'sport = :3306' | awk '{print $4}' | sort -u | paste -sd' ' -)"
  [ "$bound" = "127.0.0.1:3306" ] || fail "mariadb: the server listens on '$bound', not 127.0.0.1:3306 only"

  echo "== mariadb: the default grant covers the user's own database only, not one that _ matches"
  sql mariadb 'CREATE DATABASE appXproduction'
  rc=0
  denied="$(hx mariadb mariadb -u app_production "--password=$app_password" -e 'CREATE TABLE appXproduction.t (id INT)' 2>&1)" || rc=$?
  { [ "$rc" != 0 ] && grep -q 'denied' <<<"$denied"; } || fail "mariadb: app_production can use appXproduction (rc $rc): $denied"
  hx mariadb mariadb -u app_production "--password=$app_password" -e 'CREATE TABLE IF NOT EXISTS app_production.own (id INT)' \
    || fail "mariadb: app_production cannot use its own database"

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

  echo "== mariadb: grants added by hand are revoked, on other targets and on the listed one"
  # report lists app_production.*:SELECT; the role grants it on the escaped
  # target, so the hand grants go on both spellings.
  sql mariadb "GRANT SELECT ON mysql.* TO 'report'@'localhost'"
  for target in '`app_production`.*' '`app\_production`.*'; do
    sql mariadb "GRANT INSERT ON $target TO 'report'@'localhost'"
    sql mariadb "GRANT SELECT ON $target TO 'report'@'localhost' WITH GRANT OPTION"
  done
  grants="$(sql mariadb "SHOW GRANTS FOR 'report'@'localhost'")"
  { grep -qF '`mysql`.*' <<<"$grants" && grep -qF 'WITH GRANT OPTION' <<<"$grants"; } \
    || fail "mariadb: the hand grants did not apply: $grants"
  converge mariadb hand-grant "$dir/converge.yml" -e "$rotated"
  grants="$(sql mariadb "SHOW GRANTS FOR 'report'@'localhost'")"
  { [ "$(wc -l <<<"$grants" | tr -d ' ')" = 2 ] && grep -q '^GRANT USAGE ON \*\.\* TO `report`@`localhost`' <<<"$grants" \
      && [ "$(sed -n 2p <<<"$grants")" = 'GRANT SELECT ON `app\_production`.* TO `report`@`localhost`' ]; } \
    || fail "mariadb: report's grants are not exactly the listed one: $grants"

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

  echo "== mariadb: MySQL is refused on a host with MariaDB, before any change"
  before="$(hx mariadb dpkg -l | md5sum)"
  refused mariadb mysql-role "mysql: MariaDB is installed (mariadb-server); MariaDB and MySQL cannot share a host" \
    "$here/mysql/converge.yml" -e '{"mysql_users": [], "mysql_databases": []}'
  [ "$(hx mariadb dpkg -l | md5sum)" = "$before" ] || fail "mariadb: the refused mysql run changed the packages"
  hx mariadb sh -c 'test ! -e /etc/apt/sources.list.d/mysql.sources' || fail "mariadb: the refused mysql run added its repository"
  [ "$(hx mariadb systemctl is-active mariadb || true)" = active ] || fail "mariadb: the server stopped after the refused mysql run"
}

# mysql_architecture: the role refuses a host that is not x86_64 (MySQL's apt
# repository has amd64 packages only), before any change. Needs a container of
# the machine's own architecture, so it is skipped on an amd64 machine.
mysql_architecture() {
  start mysqlnative
  local arch; arch="$(hx mysqlnative uname -m)"
  if [ "$arch" = x86_64 ]; then
    echo "== mysql: the architecture refusal needs a host that is not amd64; skipped"
    return 0
  fi
  echo "== mysql: a host that is not amd64 is refused before any change"
  refused mysqlnative architecture "mysql: this host is $arch; MySQL's apt repository has amd64 packages only" \
    "$here/mysql/converge.yml" -e '{"mysql_users": [], "mysql_databases": []}'
  hx mysqlnative sh -c 'test ! -e /etc/apt/sources.list.d/mysql.sources && test ! -e /etc/apt/keyrings/mysql.asc && test ! -e /etc/apt/preferences.d/mysql' \
    || fail "mysql: the refused run on $arch left repository files"
  hx mysqlnative sh -c '! dpkg-query -W -f "\${db:Status-Abbrev}\n" mysql-community-server mysql-client mysql-common 2>/dev/null | grep -q "^.i"' \
    || fail "mysql: the refused run on $arch installed a package"
}

suite_mysql() {
  local dir="$here/mysql" version bound log grants policy rc denied before distro
  local empty='{"mysql_users": [], "mysql_databases": []}'
  local app_password=$'a\'b"c\\d$e%f g'
  # Parts of the test passwords that their raw and JSON-escaped forms share.
  local secrets=("a'b" '$e%f g' 'rep0rt-pass' "pa ss'%\$")
  local rotated='{"mysql_test_app_password": "n3w\"pa ss'"'"'%$\\x"}'
  mysql_architecture
  start mysql

  echo "== mysql: invalid lists and settings are refused before any change"
  refused mysql unknown-key "mysql: mysql_users entry x has unknown keys (priv); its keys are name, password, host and privileges" \
    "$dir/converge.yml" -e '{"mysql_users": [{"name": "x", "password": "p", "priv": "x.*:ALL"}]}'
  refused mysql no-privileges "mysql: mysql_users entry orphan has no privileges, and mysql_databases lists no database orphan; set privileges" \
    "$dir/converge.yml" -e '{"mysql_users": [{"name": "orphan", "password": "p"}]}'
  refused mysql root-user "mysql: mysql_users entry root is one of the server's own accounts (root, mysql.sys, mysql.session, mysql.infoschema, debian-sys-maint), which the role leaves as they are; root logs in through the socket only" \
    "$dir/converge.yml" -e '{"mysql_users": [{"name": "root", "password": "p", "privileges": ["*.*:ALL"]}]}'
  refused mysql session-user "mysql: mysql_users entry mysql.session is one of the server's own accounts" \
    "$dir/converge.yml" -e '{"mysql_users": [{"name": "mysql.session", "password": "p", "privileges": []}]}'
  refused mysql database-key "mysql: mysql_databases entry d has unknown keys (charset); its keys are name, encoding and collation" \
    "$dir/converge.yml" -e '{"mysql_test_extra_databases": [{"name": "d", "charset": "utf8mb4"}]}'
  refused mysql collation "mysql: mysql_databases entry d has encoding latin1 and collation utf8mb4_unicode_ci; the collation must belong to the encoding" \
    "$dir/converge.yml" -e '{"mysql_test_extra_databases": [{"name": "d", "encoding": "latin1"}]}'
  refused mysql password-typo "mysql: mysql_users entry x has unknown keys (pasword); its keys are name, password, host and privileges" \
    "$dir/converge.yml" -v -e '{"mysql_users": [{"name": "x", "password": "p", "pasword": "s3cr3t-typo", "privileges": []}]}'
  no_secret "$out/mysql-password-typo.log" s3cr3t-typo
  for key in bind-address bind_address mysqlx-bind-address port socket; do
    refused mysql "settings-$key" "mysql: mysql_settings sets $key; bind-address, mysqlx-bind-address, port and socket belong to the role (mysql_bind_address sets the address)" \
      "$dir/converge.yml" -e "{\"mysql_settings\": {\"$key\": \"0.0.0.0\"}}"
  done
  hx mysql sh -c 'test ! -e /usr/sbin/mysqld && test ! -e /etc/apt/sources.list.d/mysql.sources' \
    || fail "mysql: a refused run installed something"

  echo "== mysql: the distro's MySQL is refused (another series, or the pinned one from another origin)"
  hx mysql apt-get update -q >/dev/null
  hx mysql env DEBIAN_FRONTEND=noninteractive apt-get install -y -q mysql-server >/dev/null
  distro="$(hx mysql dpkg-query -W -f='${Version}' mysql-server)"
  echo "   distro mysql-server on $ubuntu: $distro"
  case "$distro" in
    8.4.*)
      # The series matches the pin, so only the origin tells it from the vendor's.
      refused mysql distro-origin "mysql: installed mysql-server $distro is not from repo.mysql.com; the role manages MySQL's own packages only" \
        "$dir/converge.yml" -e "$empty" ;;
    *)
      refused mysql distro-series "mysql: installed mysql-server $distro is series 8.0, mysql_version is 8.4; a series change is a separate, deliberate step" \
        "$dir/converge.yml" -e "$empty" ;;
  esac
  hx mysql sh -c 'test ! -e /etc/apt/sources.list.d/mysql.sources && test ! -e /etc/apt/keyrings/mysql.asc && test ! -e /etc/apt/preferences.d/mysql' \
    || fail "mysql: the refused run left repository files"
  [ "$(hx mysql dpkg-query -W -f='${Version}' mysql-server)" = "$distro" ] || fail "mysql: the distro package changed after the refused run"
  hx mysql sh -c '! dpkg-query -W -f "\${db:Status-Abbrev}\n" mysql-community-server 2>/dev/null | grep -q "^.i"' \
    || fail "mysql: the refused run installed the vendor's server"
  hx mysql env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q 'mysql-*' >/dev/null
  hx mysql env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q --purge >/dev/null
  hx mysql rm -rf /var/lib/mysql /etc/mysql

  echo "== mysql: a run whose repository refresh failed is not followed by another series"
  # The first run adds the source and the pin, then its refresh fails: the
  # package lists stay without the vendor's packages.
  # The key comes from the same host as the packages, so apt alone is cut off.
  hx mysql sh -c 'echo "Acquire::https::Proxy::repo.mysql.com \"http://127.0.0.1:9\";" > /etc/apt/apt.conf.d/99-block-mysql'
  if play mysql "$dir/converge.yml" -e "$empty" >"$out/mysql-blocked.log" 2>&1; then
    fail "mysql: the run with repo.mysql.com unreachable did not fail"
  fi
  hx mysql rm -f /etc/apt/apt.conf.d/99-block-mysql
  hx mysql test -e /etc/apt/sources.list.d/mysql.sources || fail "mysql: the blocked run did not add the source"
  hx mysql sh -c '! dpkg-query -W -f "\${db:Status-Abbrev}" mysql-community-server 2>/dev/null | grep -q "^.i"' \
    || fail "mysql: the blocked run installed mysql-community-server"
  converge mysql stale-lists "$dir/converge.yml" -e "$empty"
  version="$(hx mysql dpkg-query -W -f='${Version}' mysql-community-server)"
  case "$version" in
    8.4.*-1ubuntu"$ubuntu") echo "   installed the vendor's $version" ;;
    *) fail "mysql: after a failed refresh the role installed $version, not the vendor's" ;;
  esac
  # The vendor's versions win by origin; every other version of the MySQL
  # packages (the distro's 8.0 on 24.04, its 8.4 on 26.04) is never installed.
  policy="$(hx mysql apt-cache policy mysql-community-server mysql-common mysql-client)"
  awk '$NF ~ /^-?[0-9]+$/ && NF <= 3 { v = $(NF-1); p = $NF
         if ((v ~ /^8\.4\.[0-9]+-1ubuntu2[46]\.04$/ && p != 990) || (v !~ /^8\.4\.[0-9]+-1ubuntu2[46]\.04$/ && p != -1)) { print v, p; bad = 1 } }
       END { exit bad }' <<<"$policy" || fail "mysql: the pin gives the wrong priorities: $policy"

  echo "== mysql: converge (the first run with --diff -v) and idempotence"
  converge mysql install "$dir/converge.yml" --diff -v
  play mysql "$dir/verify.yml"
  sql mysql 'SELECT 1' >/dev/null || fail "mysql: root cannot log in over the socket"
  bound="$(hx mysql ss -Hltn | awk '$4 ~ /:(3306|33060)$/ {print $4}' | sort -u | paste -sd' ' -)"
  [ "$bound" = "127.0.0.1:3306 127.0.0.1:33060" ] || fail "mysql: the server listens on '$bound', not 127.0.0.1:3306 and :33060 only"
  [ "$(sql mysql "SELECT plugin FROM mysql.user WHERE user = 'root'")" = auth_socket ] \
    || fail "mysql: root does not use auth_socket: $(sql mysql "SELECT user, host, plugin FROM mysql.user")"

  echo "== mysql: the default grant covers the user's own database only, not one that _ matches"
  sql mysql 'CREATE DATABASE appXproduction'
  rc=0
  denied="$(hx mysql mysql -u app_production "--password=$app_password" -e 'CREATE TABLE appXproduction.t (id INT)' 2>&1)" || rc=$?
  { [ "$rc" != 0 ] && grep -q 'denied' <<<"$denied"; } || fail "mysql: app_production can use appXproduction (rc $rc): $denied"
  hx mysql mysql -u app_production "--password=$app_password" -e 'CREATE TABLE IF NOT EXISTS app_production.own (id INT)' \
    || fail "mysql: app_production cannot use its own database"

  echo "== mysql: an unknown setting fails before the restart, the server keeps running"
  refused mysql unknown-setting "failed to validate" "$dir/converge.yml" -e '{"mysql_settings": {"max_conections": 200}}'
  hx mysql sh -c 'test -s /etc/mysql/mysql.conf.d/zz-noixdev.cnf && ! grep -q max_conections /etc/mysql/mysql.conf.d/zz-noixdev.cnf' \
    || fail "mysql: the unknown setting reached the config"
  [ "$(hx mysql systemctl is-active mysql || true)" = active ] || fail "mysql: the server stopped after the unknown setting"

  echo "== mysql: a new password in the vars replaces the old one (with --diff -v)"
  converge mysql rotate "$dir/converge.yml" --diff -v -e "$rotated"
  play mysql "$dir/verify.yml" -e "$rotated" -e '{"mysql_test_old_password": "a'"'"'b\"c\\d$e%f g"}'

  echo "== mysql: the --diff -v logs have no password"
  for log in install install-idempotence rotate rotate-idempotence; do
    no_secret "$out/mysql-$log.log" "${secrets[@]}"
  done

  echo "== mysql: grants added by hand are revoked, on other targets and on the listed one"
  # report lists app_production.*:SELECT; the role grants it on the escaped
  # target, so the hand grants go on both spellings.
  sql mysql "GRANT SELECT ON mysql.* TO 'report'@'localhost'"
  for target in '`app_production`.*' '`app\_production`.*'; do
    sql mysql "GRANT INSERT ON $target TO 'report'@'localhost'"
    sql mysql "GRANT SELECT ON $target TO 'report'@'localhost' WITH GRANT OPTION"
  done
  grants="$(sql mysql "SHOW GRANTS FOR 'report'@'localhost'")"
  { grep -qF '`mysql`.*' <<<"$grants" && grep -qF 'WITH GRANT OPTION' <<<"$grants"; } \
    || fail "mysql: the hand grants did not apply: $grants"
  converge mysql hand-grant "$dir/converge.yml" -e "$rotated"
  grants="$(sql mysql "SHOW GRANTS FOR 'report'@'localhost'")"
  { [ "$(wc -l <<<"$grants" | tr -d ' ')" = 2 ] && grep -q '^GRANT USAGE ON \*\.\* TO `report`@`localhost`' <<<"$grants" \
      && [ "$(sed -n 2p <<<"$grants")" = 'GRANT SELECT ON `app\_production`.* TO `report`@`localhost`' ]; } \
    || fail "mysql: report's grants are not exactly the listed one: $grants"

  echo "== mysql: a user that leaves the list stays"
  converge mysql no-report "$dir/converge.yml" -e "$rotated" -e mysql_test_report=false
  [ "$(sql mysql "SELECT COUNT(*) FROM mysql.user WHERE User = 'report' AND Host = 'localhost'")" = 1 ] \
    || fail "mysql: report is gone after it left the list"

  echo "== mysql: a database that exists keeps its charset"
  sql mysql 'CREATE DATABASE legacy CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci'
  converge mysql legacy "$dir/converge.yml" -e "$rotated" -e '{"mysql_test_extra_databases": [{"name": "legacy"}]}'
  # SHOW CREATE leaves the collation out when it is the charset's default.
  sql mysql 'SHOW CREATE DATABASE legacy' | grep -qF 'CHARACTER SET utf8mb3 ' \
    || fail "mysql: legacy lost its charset: $(sql mysql 'SHOW CREATE DATABASE legacy')"

  echo "== mysql: another series is refused"
  version="$(hx mysql dpkg-query -W -f='${Version}' mysql-community-server)"
  echo "   mysql-community-server on $ubuntu: $version"
  refused mysql other-series "mysql: installed mysql-community-server $version is series 8.4, mysql_version is 8.0; a series change is a separate, deliberate step" \
    "$dir/converge.yml" -e "$rotated" -e mysql_version=8.0
  hx mysql grep -qF 'mysql-8.4-lts' /etc/apt/sources.list.d/mysql.sources || fail "mysql: the refused run changed the repository"
  [ "$(hx mysql dpkg-query -W -f='${Version}' mysql-community-server)" = "$version" ] || fail "mysql: mysql-community-server changed after a refused run"

  echo "== mysql: MariaDB is refused on a host with MySQL, before any change"
  before="$(hx mysql dpkg -l | md5sum)"
  refused mysql mariadb-role "mariadb: MySQL is installed (mysql-community-server); MariaDB and MySQL cannot share a host" \
    "$here/mariadb/converge.yml" -e '{"mariadb_users": [], "mariadb_databases": []}'
  [ "$(hx mysql dpkg -l | md5sum)" = "$before" ] || fail "mysql: the refused mariadb run changed the packages"
  hx mysql sh -c 'test ! -e /etc/apt/sources.list.d/mariadb.sources' || fail "mysql: the refused mariadb run added its repository"
  [ "$(hx mysql systemctl is-active mysql || true)" = active ] || fail "mysql: the server stopped after the refused mariadb run"
}


docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null

for role in $services; do
  declare -F "suite_$role" >/dev/null || fail "no suite for the role $role"
  "suite_$role"
done
echo "== services ($services) passed on ubuntu $ubuntu"
if [ "$shim_used" = 1 ]; then
  echo "== WARNING: emulated amd64: mysql.service not exercised, systemctl shim in use"
fi
