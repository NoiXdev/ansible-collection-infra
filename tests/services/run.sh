#!/usr/bin/env bash
# Host service roles (nodejs, redis, mariadb, mysql, php, composer, nginx) on a systemd Ubuntu
# container, one fresh container per role; php_switch (24.04 only) moves a
# host from the released v0.6.0 php role's PPA to packages.sury.org:
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
services="${NOIXDEV_INFRA_SERVICES:-nodejs redis mariadb mysql php php_switch composer nginx}"

started=()
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return
  for name in ${started[@]+"${started[@]}"}; do docker rm -f -v "$name" >/dev/null 2>&1 || true; done
}
# shellcheck source=/dev/null
. "$here/../lib/suite.sh"
noix_exit_guard

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
noix_link_collection "$root" "$tests/output"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"

fail() { echo "$*" >&2; exit 1; }

# start ROLE [docker run args]: a fresh systemd container for the role's
# suite. Anonymous volumes (-v /var/lib/docker) go with the container (rm -v).
start() {
  local role="$1" name="$prefix-$1"
  shift
  docker rm -f -v "$name" >/dev/null 2>&1 || true
  local image="noixdev-infra-host:$ubuntu" platform=()
  # MySQL's apt repository carries amd64 packages only: the role's container
  # runs linux/amd64 (emulated on another architecture, with its own image).
  if [ "$role" = mysql ]; then
    image="$image-amd64"
    platform=(--platform linux/amd64)
    docker build -q "${platform[@]}" --build-arg "UBUNTU=$ubuntu" -t "$image" "$tests/host" >/dev/null
  fi
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock ${platform[@]+"${platform[@]}"} "$@" --name "$name" "$image" >/dev/null
  started+=("$name")
  local tries=0
  until (docker exec "$name" systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do
    tries=$((tries + 1))
    [ "$tries" -lt 120 ] || fail "$role: the container $name did not boot within 120 seconds"
    sleep 1
  done
  if [ "$role" = mysql ]; then systemd_fallback "$name"; fi
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
  local dir="$here/nodejs" distro before version policy pkgs='{"nodejs_npm_packages": [{"name": "semver", "version": "7.7.2"}]}'
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
  hx nodejs sh -c 'test ! -e /etc/apt/preferences.d/nodesource' || fail "nodejs: the refused run left the pin"
  hx nodejs env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q nodejs >/dev/null

  echo "== nodejs: a run whose repository refresh failed is not followed by the distro's nodejs"
  # The first run adds the source and the pin, then its refresh fails: the
  # package lists stay without NodeSource's packages. The key comes from the
  # same host as the packages, so apt alone is cut off.
  hx nodejs sh -c 'echo "Acquire::https::Proxy::deb.nodesource.com \"http://127.0.0.1:9\";" > /etc/apt/apt.conf.d/99-block-nodesource'
  if play nodejs "$dir/converge.yml" >"$out/nodejs-blocked.log" 2>&1; then
    fail "nodejs: the run with deb.nodesource.com unreachable did not fail"
  fi
  hx nodejs rm -f /etc/apt/apt.conf.d/99-block-nodesource
  hx nodejs test -e /etc/apt/sources.list.d/nodesource.sources || fail "nodejs: the blocked run did not add the source"
  hx nodejs sh -c '! dpkg-query -W -f "\${db:Status-Abbrev}" nodejs 2>/dev/null | grep -q "^.i"' \
    || fail "nodejs: the blocked run installed nodejs"
  converge nodejs stale-lists "$dir/converge.yml"
  version="$(hx nodejs dpkg-query -W -f='${Version}' nodejs)"
  case "$version" in
    24.*nodesource*) echo "   installed NodeSource's $version" ;;
    *) fail "nodejs: after a failed refresh the role installed $version, not NodeSource's" ;;
  esac
  # NodeSource's versions win by origin; the distro's nodejs is never installed.
  policy="$(hx nodejs apt-cache policy nodejs)"
  awk '$NF ~ /^-?[0-9]+$/ && NF <= 3 { v = $(NF-1); p = $NF
         if ((v ~ /nodesource/ && p != 990) || (v !~ /nodesource/ && p != -1)) { print v, p; bad = 1 } }
       END { exit bad }' <<<"$policy" || fail "nodejs: the pin gives the wrong priorities: $policy"

  echo "== nodejs: converge with npm packages and idempotence"
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
  local dir="$here/redis" version series policy prod staging bound rotate
  start redis

  echo "== redis: the distro's redis-server is refused (another series, or the pinned one from another origin)"
  hx redis apt-get update -q >/dev/null
  hx redis env DEBIAN_FRONTEND=noninteractive apt-get install -y -q redis-server >/dev/null
  version="$(hx redis dpkg-query -W -f='${Version}' redis-server)"
  echo "   distro redis-server on $ubuntu: $version"
  series="${version#*:}"
  series="${series%%.*}"
  if [ "$series" = 8 ]; then
    # The series matches the pin, so only the origin tells it from the vendor's.
    refused redis distro-origin "redis: installed redis-server $version is not from packages.redis.io; the role manages Redis's own packages only" \
      "$dir/converge.yml"
  else
    refused redis distro-series "redis: installed redis-server $version is series $series, redis_version is 8; a series change is a separate, deliberate step" \
      "$dir/converge.yml"
  fi
  hx redis sh -c 'test ! -e /etc/apt/sources.list.d/redis.sources && test ! -e /etc/apt/keyrings/redis.asc && test ! -e /etc/apt/preferences.d/redis' \
    || fail "redis: the refused run left repository files"
  [ "$(hx redis dpkg-query -W -f='${Version}' redis-server)" = "$version" ] || fail "redis: the distro package changed after the refused run"
  hx redis env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q redis-server redis-tools >/dev/null
  hx redis env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q --purge >/dev/null
  hx redis rm -rf /etc/redis /var/lib/redis /var/log/redis

  echo "== redis: a run whose repository refresh failed is not followed by the distro's redis-server"
  # The first run adds the source and the pin, then its refresh fails: the
  # package lists stay without the vendor's packages. The key comes from the
  # same host as the packages, so apt alone is cut off.
  hx redis sh -c 'echo "Acquire::https::Proxy::packages.redis.io \"http://127.0.0.1:9\";" > /etc/apt/apt.conf.d/99-block-redis'
  if play redis "$dir/converge.yml" >"$out/redis-blocked.log" 2>&1; then
    fail "redis: the run with packages.redis.io unreachable did not fail"
  fi
  hx redis rm -f /etc/apt/apt.conf.d/99-block-redis
  hx redis test -e /etc/apt/sources.list.d/redis.sources || fail "redis: the blocked run did not add the source"
  hx redis sh -c '! dpkg-query -W -f "\${db:Status-Abbrev}" redis-server 2>/dev/null | grep -q "^.i"' \
    || fail "redis: the blocked run installed redis-server"
  converge redis stale-lists "$dir/converge.yml"
  version="$(hx redis dpkg-query -W -f='${Version}' redis-server)"
  case "$version" in
    *rl[0-9]*~*) echo "   installed the vendor's $version" ;;
    *) fail "redis: after a failed refresh the role installed $version, not the vendor's" ;;
  esac
  # The vendor's versions of the series win by origin; every other version of
  # the Redis packages (the distro's 7 on 24.04, its 8 on 26.04, the vendor's
  # 6.2 and 7 on 24.04) is never installed.
  policy="$(hx redis apt-cache policy redis redis-server redis-tools redis-sentinel)"
  awk '$NF ~ /^-?[0-9]+$/ && NF <= 3 { v = $(NF-1); p = $NF
         if ((v ~ /^([0-9]+:)?8[.].*rl[0-9]+~/ && p != 990) || (v !~ /^([0-9]+:)?8[.].*rl[0-9]+~/ && p != -1)) { print v, p; bad = 1 } }
       END { exit bad }' <<<"$policy" || fail "redis: the pin gives the wrong priorities: $policy"

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
  for log in instances instances-idempotence; do
    no_secret "$out/redis-$log.log" 's-pass' 'o d$%'
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

  echo "== mariadb: a privilege the server does not know is refused, naming the user and the reason"
  refused mariadb bad-privilege "invalid priv string: SELEKT" "$dir/converge.yml" -v -e "$rotated" \
    -e '{"mariadb_test_report_user": {"name": "report", "password": "rep0rt-pass", "privileges": ["app_production.*:SELECT", "report.*:SELEKT"]}}'
  # The task's own failure line, not only ansible's error summary, names the
  # user and the reason (a no_log task prints it censored).
  grep -qE '^failed: \[testhost\] \(item=report\) => .*invalid priv string: SELEKT' "$out/mariadb-bad-privilege.log" \
    || fail "mariadb: the failure line does not name the user report and the reason"
  no_secret "$out/mariadb-bad-privilege.log" "${secrets[@]}"
  [ "$(sql mariadb "SHOW GRANTS FOR 'report'@'localhost'")" = "$grants" ] || fail "mariadb: the refused run changed report's grants"

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

  echo "== mysql: a first run that stops at an unknown setting leaves the server on the bind address only"
  # The run after the blocked one is the first install: the package's own
  # config sets no address (the server would listen on every interface), and
  # the unknown setting stops the run before the role's config is written.
  log="$out/mysql-first-run-typo.log"
  if play mysql "$dir/converge.yml" -e "$empty" -e '{"mysql_settings": {"max_conections": 200}}' >"$log" 2>&1; then
    fail "mysql: the first run with an unknown setting did not fail"
  fi
  grep -qF "failed to validate" "$log" || { cat "$log" >&2; fail "mysql: the first run did not stop at the config check"; }
  hx mysql sh -c 'dpkg-query -W -f "\${db:Status-Abbrev}" mysql-community-server | grep -q "^ii"' \
    || fail "mysql: the first run with an unknown setting did not install the server"
  if [ "$(hx mysql systemctl is-active mysql || true)" != active ]; then
    echo "   the package left the server stopped; starting it with the package's config"
    hx mysql systemctl start mysql || fail "mysql: the server installed by the stopped first run does not start"
  fi
  bound="$(hx mysql ss -Hltn | awk '$4 ~ /:(3306|33060)$/ {print $4}' | sort -u | paste -sd' ' -)"
  [ "$bound" = "127.0.0.1:3306 127.0.0.1:33060" ] \
    || fail "mysql: after a first run stopped at an unknown setting the server listens on '$bound', not 127.0.0.1:3306 and :33060 only"
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

  echo "== mysql: a privilege the server does not know is refused, naming the user and the reason"
  refused mysql bad-privilege "invalid priv string: SELEKT" "$dir/converge.yml" -v -e "$rotated" \
    -e '{"mysql_test_report_user": {"name": "report", "password": "rep0rt-pass", "privileges": ["app_production.*:SELECT", "report.*:SELEKT"]}}'
  # The task's own failure line, not only ansible's error summary, names the
  # user and the reason (a no_log task prints it censored).
  grep -qE '^failed: \[testhost\] \(item=report\) => .*invalid priv string: SELEKT' "$out/mysql-bad-privilege.log" \
    || fail "mysql: the failure line does not name the user report and the reason"
  no_secret "$out/mysql-bad-privilege.log" "${secrets[@]}"
  [ "$(sql mysql "SHOW GRANTS FOR 'report'@'localhost'")" = "$grants" ] || fail "mysql: the refused run changed report's grants"

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

# ask POOL ROOT [ROLE]: what ROOT/app.php reports through the pool's socket
# in ROLE's container (php by default; nothing when the pool does not answer).
ask() {
  hx "${3:-php}" env SCRIPT_FILENAME="$2/app.php" REQUEST_METHOD=GET cgi-fcgi -bind -connect "/run/php/$1.sock" 2>/dev/null || true
}

# php_running: production and staging still run as PROD and STAGING after a
# failed or refused run ($1 names it).
php_running() {
  [ "$(pid php php-fpm@production)" = "$prod" ] || fail "php/$1: production restarted"
  [ "$(pid php php-fpm@staging)" = "$staging" ] || fail "php/$1: staging restarted"
}

# fpm_rejected NAME: the refused run NAME stopped at the role's up-front test of
# the new pool configs (tasks/pools.yml), before any master stopped. The line
# is the template module's own message, which Ansible prints in the error
# header although the task is no_log; the next line names the task's file.
fpm_rejected() {
  local log="$out/php-$1.log" origin
  origin="$(grep -A1 -F '[ERROR]: Task failed: Module failed: failed to validate' "$log" || true)"
  grep -q 'roles/php/tasks/pools.yml:' <<<"$origin" \
    || { cat "$log" >&2; fail "php/$1: the run did not stop at the test of the new pool configs"; }
}

# php_planted_links: links staging's user plants in and above its tmp_dir
# stop the run, naming the link, and nothing outside tmp_dir changes. The
# target is a root-owned directory: a run that followed the link would hand it
# to the pool user.
php_planted_links() {
  local dir="$here/php" victim=/etc/noixdev-victim before
  local owners=(stat -c '%n %U:%G %a' /etc "$victim" "$victim/tmp")
  hx php sh -c 'mkdir -p "$1/tmp" && chown root:root "$1" "$1/tmp" && chmod 0755 "$1" "$1/tmp"' sh "$victim"
  before="$(hx php "${owners[@]}")"

  echo "== php: a link staging's user plants as tmp_dir/session stops the run, the target stays root's"
  hx php runuser -u app_staging -- sh -c 'rm -r /srv/staging/tmp/session && ln -s "$1" /srv/staging/tmp/session' sh "$victim"
  refused php link-session "php: php_pools entry staging: /srv/staging/tmp/session is a link or not a directory" \
    "$dir/converge.yml"
  # A failed loop item is printed whole.
  no_secret "$out/php-link-session.log" "${secrets[@]}"
  [ "$(hx php "${owners[@]}")" = "$before" ] || fail "php: the run followed the session link: $(hx php "${owners[@]}")"
  hx php runuser -u app_staging -- rm /srv/staging/tmp/session

  echo "== php: tmp_dir itself as a link stops the run"
  hx php runuser -u app_staging -- sh -c 'mv /srv/staging/tmp /srv/staging/tmp.real && ln -s "$1" /srv/staging/tmp' sh "$victim"
  refused php link-tmp-dir "php: php_pools entry staging: /srv/staging/tmp is a link or not a directory" \
    "$dir/converge.yml"
  [ "$(hx php "${owners[@]}")" = "$before" ] || fail "php: the run followed the tmp_dir link: $(hx php "${owners[@]}")"
  hx php runuser -u app_staging -- sh -c 'rm /srv/staging/tmp && mv /srv/staging/tmp.real /srv/staging/tmp'

  echo "== php: a link in the path above tmp_dir stops the run"
  hx php runuser -u app_staging -- ln -s "$victim" /srv/staging/var
  refused php link-parent "php: php_pools entry staging: /srv/staging/var is a link or not a directory" \
    "$dir/converge.yml" -e php_test_staging_tmp_dir=/srv/staging/var/tmp
  [ "$(hx php "${owners[@]}")" = "$before" ] || fail "php: the run followed the link above tmp_dir: $(hx php "${owners[@]}")"
  hx php runuser -u app_staging -- rm /srv/staging/var
  php_running planted-links

  echo "== php: without the links the next run recreates session"
  converge php after-links "$dir/converge.yml"
  play php "$dir/verify.yml"
  hx php sh -c '[ "$(stat -c "%U:%G %a" /srv/staging/tmp/session)" = "app_staging:app_staging 770" ]' \
    || fail "php: session was not recreated: $(hx php stat -c '%U:%G %a' /srv/staging/tmp/session)"
}

# loads POOL ROOT EXTENSION: the pool has EXTENSION loaded within 10
# seconds (a reload is a signal).
loads() {
  local tries=0
  until ask "$1" "$2" | grep -qF "\"$3\""; do
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || return 1
    sleep 1
  done
}

# php_failed_run_reloads: a run that fails after it installed a new extension
# for 8.3 (a typo in 8.4's list) still reloads the 8.3 pools, so the fixed
# run, which changes nothing for 8.3, does not leave them without it. The
# pools reload (USR2): their MainPIDs stay.
php_failed_run_reloads() {
  local dir="$here/php"
  local fixed='{"php_versions": [{"version": "8.3", "extensions": ["intl", "mbstring", "bcmath"]}, {"version": "8.4", "extensions": ["intl", "mbstring"]}]}'
  local typo='{"php_versions": [{"version": "8.3", "extensions": ["intl", "mbstring", "bcmath"]}, {"version": "8.4", "extensions": ["intll"]}]}'
  echo "== php: a new 8.3 extension and a typo in 8.4's list: the run fails, the 8.3 pools load the extension"
  ! loads production /srv/prod bcmath || fail "php: production has bcmath before the test"
  if play php "$dir/converge.yml" "${upgraded[@]}" -e "$typo" >"$out/php-typo-new-extension.log" 2>&1; then
    fail "php: the run with php8.4-intll did not fail"
  fi
  grep -qF "php8.4-intll" "$out/php-typo-new-extension.log" || { cat "$out/php-typo-new-extension.log" >&2; fail "php: the failure does not name php8.4-intll"; }
  loads production /srv/prod bcmath || fail "php: production did not load bcmath after the failed run"
  loads staging /srv/staging bcmath || fail "php: staging did not load bcmath after the failed run"
  php_running typo-new-extension
  converge php typo-fixed "$dir/converge.yml" "${upgraded[@]}" -e "$fixed"
  loads production /srv/prod bcmath || fail "php: production does not have bcmath after the fixed run"
  loads staging /srv/staging bcmath || fail "php: staging does not have bcmath after the fixed run"
  php_running typo-fixed
}

# php_failed_switch_keeps_updates: a switch run that fails after the switch
# (an extension that does not exist) leaves packages.sury.org's pattern in
# unattended-upgrades: without the PPA, PHP keeps getting its updates. The
# PPA's source is a stand-in (a comment), so the switch check finds nothing
# from it; the run removes it and refreshes. The next run removes the PPA's
# pattern too.
php_failed_switch_keeps_updates() {
  local dir="$here/php" log="$out/php-switch-typo.log"
  echo "== php: a switch run that fails later (an extension typo) leaves packages.sury.org's pattern in unattended-upgrades"
  hx php sh -c 'rm /etc/apt/apt.conf.d/52noixdev-php-sury && echo "# stand-in" > /etc/apt/sources.list.d/ondrej-php.sources \
    && echo "// stand-in" > /etc/apt/apt.conf.d/52noixdev-php-ppa'
  if play php "$dir/converge.yml" "${upgraded[@]}" \
      -e '{"php_versions": [{"version": "8.3", "extensions": ["intll"]}, {"version": "8.4", "extensions": ["intl", "mbstring"]}]}' >"$log" 2>&1; then
    fail "php: the switch run with php8.3-intll did not fail"
  fi
  grep -qF "php8.3-intll" "$log" || { cat "$log" >&2; fail "php: the failure does not name php8.3-intll"; }
  hx php test ! -e /etc/apt/sources.list.d/ondrej-php.sources || fail "php: the switch run did not remove the PPA's source"
  hx php test -e /etc/apt/apt.conf.d/52noixdev-php-sury || fail "php: the failed switch run left no 52noixdev-php-sury"
  php_running switch-typo
  play php "$dir/converge.yml" "${upgraded[@]}" >"$out/php-switch-typo-fixed.log" 2>&1 \
    || { cat "$out/php-switch-typo-fixed.log" >&2; fail "php: the fixed run after the failed switch failed"; }
  play php "$dir/verify.yml" "${upgraded[@]}"
  php_running switch-typo-fixed
}

suite_php() {
  local dir="$here/php" codename version policy prod staging tries rotate name conf stanza key fpr mirror
  local pool='{"name": "production", "version": "8.3", "user": "app_prod"}'
  # staging after its upgrade.
  local upgraded=(-e php_test_staging_memory_limit=160M -e php_test_staging_version=8.3)
  # A part of staging's NOTE that its raw, JSON-escaped and pool.conf forms
  # (c=\$d e) share, the key (no log prints the env at all), and staging's
  # ini value user_agent.
  local secrets=('$d e' 'APP_ENV' 's3cr3t-ini')
  start php

  echo "== php: a release without packages and a PPA override are refused before any change"
  codename="$(hx php sh -c '. /etc/os-release && echo "$VERSION_CODENAME"')"
  refused php release "php: Ubuntu $ubuntu is not supported yet: packages.sury.org has no packages for $codename" \
    "$dir/converge.yml" -e php_test_prepare=false -e '{"php_supported_releases": ["jammy"]}'
  hx php sh -c 'cd /etc/apt && test ! -e sources.list.d/sury-php.sources && test ! -e keyrings/sury-php.gpg && test ! -e preferences.d/sury-php && test ! -e apt.conf.d/52noixdev-php-sury \
    && test ! -e sources.list.d/ondrej-php.sources && test ! -e keyrings/ondrej-php.asc && test ! -e preferences.d/ondrej-php && test ! -e apt.conf.d/52noixdev-php-ppa' \
    || fail "php: the refused run left repository files"
  refused php ppa-url "php: php_apt_url points at the ondrej/php PPA (https://ppa.launchpadcontent.net/ondrej/php/ubuntu)" \
    "$dir/converge.yml" -e php_test_prepare=false -e php_apt_url=https://ppa.launchpadcontent.net/ondrej/php/ubuntu
  refused php ppa-fingerprint "php: php_apt_key_fingerprint points at the ondrej/php PPA (B8DC7E53946656EFBCE4C1DD71DAEAAB4AD4CAB6)" \
    "$dir/converge.yml" -e php_test_prepare=false -e php_apt_key_fingerprint=B8DC7E53946656EFBCE4C1DD71DAEAAB4AD4CAB6
  refused php ppa-key-url "php: php_apt_key_url points at the ondrej/php PPA (https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xB8DC7E53946656EFBCE4C1DD71DAEAAB4AD4CAB6)" \
    "$dir/converge.yml" -e php_test_prepare=false -e 'php_apt_key_url=https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xB8DC7E53946656EFBCE4C1DD71DAEAAB4AD4CAB6'

  echo "== php: Ubuntu's own php of a listed version is refused before any change"
  hx php apt-get update -q >/dev/null
  # The version Ubuntu's php-cli stands for (8.3 on 24.04).
  version="$(hx php apt-cache depends php-cli | sed -n 's/^ *Depends: php\([0-9][0-9]*\.[0-9][0-9]*\)-cli$/\1/p' | head -n 1)"
  [ -n "$version" ] || fail "php: found no version behind Ubuntu's php-cli"
  hx php env DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-apt "php$version-cli" >/dev/null
  refused php ubuntu-php "are Ubuntu's own packages of a version php_versions lists" \
    "$dir/converge.yml" -e php_test_prepare=false -e "{\"php_versions\": [{\"version\": \"$version\"}], \"php_pools\": []}"
  grep -qF "php$version-cli" "$out/php-ubuntu-php.log" || fail "php: the refusal does not name php$version-cli"
  hx php env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q --autoremove "php$version-*" php-common >/dev/null
  hx php sh -c '! dpkg-query -W -f "\${db:Status-Abbrev}\n" "php$1-*" 2>/dev/null | grep -q "^.i"' sh "$version" \
    || fail "php: Ubuntu's php$version is still installed"

  echo "== php: a run whose packages.sury.org refresh failed is not followed by Ubuntu's php"
  # The first run adds the key, the source and the pin, then its refresh
  # fails: the package lists stay without packages.sury.org's packages. The
  # key comes through get_url, not apt, so only apt is cut off.
  hx php sh -c 'echo "Acquire::https::Proxy::packages.sury.org \"http://127.0.0.1:9\";" > /etc/apt/apt.conf.d/99-block-sury'
  if play php "$dir/converge.yml" >"$out/php-blocked.log" 2>&1; then
    fail "php: the run with packages.sury.org unreachable did not fail"
  fi
  hx php test -e /etc/apt/sources.list.d/sury-php.sources || fail "php: the blocked run did not add the source"
  hx php sh -c '! dpkg-query -W -f "\${db:Status-Abbrev}\n" php8.3-cli php8.3-fpm 2>/dev/null | grep -q "^.i"' \
    || fail "php: the blocked run installed php"
  # Ubuntu's own php (8.3 on 24.04) has no candidate: the pin leaves it none.
  # 26.04 ships 8.5, which the suite does not list; the pin check below
  # covers php8.3-* and php8.4-* there.
  case "$version" in
    8.3 | 8.4)
      policy="$(hx php apt-cache policy "php$version-cli")"
      grep -qF 'Candidate: (none)' <<<"$policy" \
        || fail "php: without packages.sury.org's lists Ubuntu's php$version-cli is a candidate: $policy" ;;
    *) echo "   Ubuntu's php is $version, which the suite does not list: no candidate check" ;;
  esac
  hx php rm -f /etc/apt/apt.conf.d/99-block-sury

  echo "== php: converge (the first run with --diff -v, on the stale lists) and idempotence"
  converge php install "$dir/converge.yml" --diff -v
  # By the origin of the installed version, not its string: packages.sury.org
  # uses several version schemes (on arm64 a gbp snapshot, for instance).
  version="$(hx php python3 -c 'import apt, sys
v = apt.Cache()[sys.argv[1]].installed
print(v.version, " ".join(sorted({o.origin for o in v.origins})))' php8.3-fpm)"
  case " $version " in
    *" deb.sury.org "*) echo "   installed packages.sury.org's php8.3-fpm ${version%% *}" ;;
    *) fail "php: after a failed refresh the role installed php8.3-fpm $version, not packages.sury.org's" ;;
  esac
  # packages.sury.org's versions win by origin; Ubuntu's php8.3 is never
  # installed. Each version line is judged by the first source under it.
  policy="$(hx php apt-cache policy php8.3-cli php8.3-fpm php8.3-common php8.3-intl php8.3-mbstring php8.4-cli php8.4-fpm php8.4-intl php8.4-mbstring)"
  awk '$NF ~ /^-?[0-9]+$/ && NF <= 3 { v = $(NF-1); p = $NF; next }
       v != "" && $2 ~ /^[a-z]+:\/\// { sury = ($2 ~ /:\/\/packages\.sury\.org\//)
         if ((sury && p != 990) || (!sury && p != -1)) { print v, p, $2; bad = 1 }
         v = "" }
       END { exit bad }' <<<"$policy" || fail "php: the pin gives the wrong priorities: $policy"
  play php "$dir/verify.yml"
  rotate="$(hx php logrotate -d /etc/logrotate.d/php-pools 2>&1)"
  for name in production staging; do
    grep -qF "/var/log/php/$name.log" <<<"$rotate" || fail "php: logrotate does not consider $name's log: $rotate"
  done

  echo "== php: a damaged key in place is replaced, the lists refreshed"
  prod="$(pid php php-fpm@production)"
  staging="$(pid php php-fpm@staging)"
  # The key packages.sury.org serves now, fetched afresh (the image has no curl).
  key="$(hx php python3 -c 'import hashlib, sys, urllib.request
print(hashlib.sha256(urllib.request.urlopen(sys.argv[1]).read()).hexdigest())' https://packages.sury.org/php/apt.gpg)"
  [ "$(hx php sha256sum /etc/apt/keyrings/sury-php.gpg | cut -d ' ' -f 1)" = "$key" ] \
    || fail "php: the key in place is not the one packages.sury.org serves"
  # Lists older than the role's cache_valid_time, as on a host between runs:
  # a refresh before the key is replaced would fail on the damaged key.
  hx php sh -c 'truncate -s 5 /etc/apt/keyrings/sury-php.gpg && touch -d "3 hours ago" /var/lib/apt/lists \
    && if [ -e /var/lib/apt/periodic/update-success-stamp ]; then touch -d "3 hours ago" /var/lib/apt/periodic/update-success-stamp; fi'
  converge php key-restored "$dir/converge.yml"
  [ "$(hx php sha256sum /etc/apt/keyrings/sury-php.gpg | cut -d ' ' -f 1)" = "$key" ] || fail "php: the damaged key was not replaced"
  # The first line after the refresh's task header is its result: it ran.
  # (The apt module reports a refresh that brought no new lists as ok.)
  awk '/^TASK \[.*Refresh the package lists for packages\.sury\.org\]/ { t = 1; next }
       t && /^(ok|changed|skipping|fatal):/ { r = $1; t = 0 }
       END { exit !(r == "ok:" || r == "changed:") }' "$out/php-key-restored.log" \
    || fail "php: the run that replaced the key did not refresh the lists"
  php_running key-restored

  echo "== php: a key with another fingerprint or an expired key is refused, the key in place stays"
  refused php wrong-key "does not carry the key 0123456789ABCDEF0123456789ABCDEF01234567; the key in place stays" \
    "$dir/converge.yml" -e php_apt_key_fingerprint=0123456789ABCDEF0123456789ABCDEF01234567
  [ "$(hx php sha256sum /etc/apt/keyrings/sury-php.gpg | cut -d ' ' -f 1)" = "$key" ] || fail "php: the refused key replaced the one in place"
  # A key that expired on 2020-01-02, made with a faked clock.
  hx php sh -c 'rm -rf /root/expired && mkdir -m 700 /root/expired \
    && gpg --batch --homedir /root/expired --faked-system-time "20200101T000000!" --passphrase "" \
      --quick-gen-key "Expired <expired@example.test>" rsa2048 sign 1d \
    && gpg --batch --homedir /root/expired --export > /root/expired.gpg' >/dev/null 2>&1 \
    || fail "php: the expired key could not be made"
  fpr="$(hx php gpg --batch --show-keys --with-colons /root/expired.gpg | awk -F: '$1 == "fpr" { print $10; exit }')"
  [ -n "$fpr" ] || fail "php: the expired key has no fingerprint"
  refused php expired-key "php: the key $fpr from file:///root/expired.gpg expired on 2020-01-02" \
    "$dir/converge.yml" -e php_apt_key_url=file:///root/expired.gpg -e "php_apt_key_fingerprint=$fpr"
  [ "$(hx php sha256sum /etc/apt/keyrings/sury-php.gpg | cut -d ' ' -f 1)" = "$key" ] || fail "php: the expired key replaced the one in place"
  hx php rm -rf /root/expired /root/expired.gpg
  # The pinned key (the one in place is packages.sury.org's, checked above)
  # and a second one in the same file: apt would trust both.
  hx php sh -c 'rm -rf /root/other && mkdir -m 700 /root/other \
    && gpg --batch --homedir /root/other --passphrase "" --quick-gen-key "Other <other@example.test>" rsa2048 sign 1y \
    && gpg --batch --homedir /root/other --export > /root/other.gpg \
    && cat /etc/apt/keyrings/sury-php.gpg /root/other.gpg > /root/two-keys.gpg' >/dev/null 2>&1 \
    || fail "php: the two-key file could not be made"
  [ "$(hx php gpg --batch --show-keys --with-colons /root/two-keys.gpg | grep -c '^pub:')" = 2 ] \
    || fail "php: the two-key file does not hold two keys"
  refused php two-keys "php: file:///root/two-keys.gpg does not carry the key 15058500A0235D97F5D10063B188E2B695BD4743; the key in place stays" \
    "$dir/converge.yml" -e php_apt_key_url=file:///root/two-keys.gpg
  [ "$(hx php sha256sum /etc/apt/keyrings/sury-php.gpg | cut -d ' ' -f 1)" = "$key" ] || fail "php: the two-key file replaced the key in place"
  hx php rm -rf /root/other /root/other.gpg /root/two-keys.gpg
  php_running key-refusals

  echo "== php: another source of packages.sury.org/php is refused before any change"
  prod="$(pid php php-fpm@production)"
  staging="$(pid php php-fpm@staging)"
  stanza='Types: deb\nURIs: https://packages.sury.org/php/\nSuites: %s\nComponents: main\nSigned-By: /usr/share/keyrings/debsuryorg-archive-keyring.gpg\n'
  hx php sh -c 'echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $1 main" > /etc/apt/sources.list.d/php.list' sh "$codename"
  refused php foreign-list "/etc/apt/sources.list.d/php.list already enable packages.sury.org/php" "$dir/converge.yml"
  php_running foreign-list
  hx php rm /etc/apt/sources.list.d/php.list
  # The same source as a deb822 stanza.
  hx php sh -c 'printf "$1" "$2" > /etc/apt/sources.list.d/php.sources' sh "$stanza" "$codename"
  refused php foreign-sources "/etc/apt/sources.list.d/php.sources already enable" "$dir/converge.yml"
  php_running foreign-sources
  hx php rm /etc/apt/sources.list.d/php.sources
  # A mirror in php_apt_url that the PPA's old source names already (a v0.6.0
  # inventory with a mirror of the PPA): the role's source next to it would
  # stop apt.
  mirror=https://mirror.example.test/ondrej-php/ubuntu
  hx php sh -c 'printf "Types: deb\nURIs: %s/\nSuites: %s\nComponents: main\nSigned-By: /etc/apt/keyrings/ondrej-php.asc\n" "$1" "$2" \
    > /etc/apt/sources.list.d/ondrej-php.sources' sh "$mirror" "$codename"
  refused php foreign-ppa-mirror "php: /etc/apt/sources.list.d/ondrej-php.sources already enable $mirror; remove them, the role adds its own source (two entries with different keys stop apt for every source); /etc/apt/sources.list.d/ondrej-php.sources is the ondrej/php PPA's source from before the switch, so php_apt_url names the PPA: it must point at packages.sury.org or a mirror of it" \
    "$dir/converge.yml" -e "php_apt_url=$mirror"
  php_running foreign-ppa-mirror
  hx php rm /etc/apt/sources.list.d/ondrej-php.sources
  # A source of the host's own for a mirror in php_apt_url, in other case
  # and with a trailing slash.
  mirror=https://mirror.example.test/sury/php
  hx php sh -c 'echo "deb [signed-by=/usr/share/keyrings/mirror.gpg] HTTPS://Mirror.Example.TEST/sury/php/ $1 main" > /etc/apt/sources.list.d/mirror.list' sh "$codename"
  refused php foreign-mirror "php: /etc/apt/sources.list.d/mirror.list already enable $mirror; remove them, the role adds its own source (two entries with different keys stop apt for every source)" \
    "$dir/converge.yml" -e "php_apt_url=$mirror"
  ! grep -qF "PPA's source from before the switch" "$out/php-foreign-mirror.log" || fail "php: the refusal of mirror.list calls it the PPA's source"
  php_running foreign-mirror
  hx php rm /etc/apt/sources.list.d/mirror.list
  # A commented entry and a disabled stanza do not count.
  hx php sh -c 'echo "# deb https://packages.sury.org/php/ $2 main" > /etc/apt/sources.list.d/php-commented.list \
    && printf "${1}Enabled: no\n" "$2" > /etc/apt/sources.list.d/php-disabled.sources' sh "$stanza" "$codename"
  converge php foreign-inactive "$dir/converge.yml"
  php_running foreign-inactive
  hx php rm /etc/apt/sources.list.d/php-commented.list /etc/apt/sources.list.d/php-disabled.sources

  echo "== php: kill -9 of staging's master leaves production serving, systemd restarts staging"
  prod="$(pid php php-fpm@production)"
  staging="$(pid php php-fpm@staging)"
  hx php kill -9 "$staging"
  ask production /srv/prod | grep -qF '"user":"app_prod"' || fail "php: production does not answer after staging's kill"
  tries=0
  until [ "$(hx php systemctl is-active php-fpm@staging || true)" = active ] \
      && [ "$(pid php php-fpm@staging)" != "$staging" ] && [ "$(pid php php-fpm@staging)" != 0 ] \
      && ask staging /srv/staging | grep -qF '"user":"app_staging"'; do
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || fail "php: staging was not active again within 10 seconds of the kill"
    sleep 1
  done
  [ "$(pid php php-fpm@production)" = "$prod" ] || fail "php: production restarted on staging's kill"

  prod="$(pid php php-fpm@production)"
  staging="$(pid php php-fpm@staging)"
  php_planted_links

  echo "== php: a changed ini of staging reloads staging only (with --diff -vvv)"
  staging="$(pid php php-fpm@staging)"
  converge php memory "$dir/converge.yml" --diff -vvv -e php_test_staging_memory_limit=160M
  play php "$dir/verify.yml" -e php_test_staging_memory_limit=160M
  [ "$(pid php php-fpm@production)" = "$prod" ] || fail "php: production restarted on staging's change"
  # A reload re-executes the master in its process.
  [ "$(pid php php-fpm@staging)" = "$staging" ] || fail "php: staging restarted instead of a reload"

  echo "== php: the --diff logs have no env or ini value"
  for log in install install-idempotence memory memory-idempotence; do
    no_secret "$out/php-$log.log" "${secrets[@]}"
  done

  echo "== php: staging moves to 8.3 on the same socket, production keeps running"
  converge php upgrade "$dir/converge.yml" "${upgraded[@]}"
  play php "$dir/verify.yml" "${upgraded[@]}"
  [ "$(pid php php-fpm@production)" = "$prod" ] || fail "php: production restarted on staging's upgrade"
  [ "$(pid php php-fpm@staging)" != "$staging" ] || fail "php: staging did not restart on its version change"
  staging="$(pid php php-fpm@staging)"

  echo "== php: an extension with a typo fails naming the package, the pools keep running"
  refused php typo "php8.3-intll" "$dir/converge.yml" "${upgraded[@]}" \
    -e '{"php_versions": [{"version": "8.3", "extensions": ["intll"]}, {"version": "8.4", "extensions": ["intl", "mbstring"]}]}'
  php_running typo
  php_failed_run_reloads
  php_failed_switch_keeps_updates

  echo "== php: invalid pools are refused before any change"
  refused php unknown-user "php: php_pools entry production runs as nosuchuser, which does not exist; the role does not create users" \
    "$dir/converge.yml" -e '{"php_pools": [{"name": "production", "version": "8.3", "user": "nosuchuser"}]}'
  refused php root-user "php: php_pools entry production runs as root; a pool runs as an unprivileged user" \
    "$dir/converge.yml" -e '{"php_pools": [{"name": "production", "version": "8.3", "user": "root"}]}'
  refused php unlisted-version "php: php_pools entry production uses PHP 8.2, which php_versions does not list (8.3, 8.4)" \
    "$dir/converge.yml" -e '{"php_pools": [{"name": "production", "version": "8.2", "user": "app_prod"}]}'
  refused php role-owned-ini "php: php_pools entry production sets open_basedir in ini; open_basedir, error_log, session.save_path, upload_tmp_dir and sys_temp_dir belong to the role (it sets them from open_basedir and tmp_dir)" \
    "$dir/converge.yml" -v -e '{"php_pools": [{"name": "production", "version": "8.3", "user": "app_prod", "ini": {"open_basedir": "/s3cr3t-ini"}}]}'
  no_secret "$out/php-role-owned-ini.log" s3cr3t-ini
  refused php restart-timeout "php: php_fpm_restart_timeout must be a positive number of seconds, not 0" \
    "$dir/converge.yml" -e php_fpm_restart_timeout=0
  refused php duplicate-name "php: php_pools has more than one entry named production" \
    "$dir/converge.yml" -e "{\"php_pools\": [$pool, $pool]}"
  refused php www-name "php: php_pools entry 'www' has an invalid name; it must match ^[a-z0-9_-]+$ and must not be www, the packages' own pool" \
    "$dir/converge.yml" -e '{"php_pools": [{"name": "www", "version": "8.3", "user": "app_prod"}]}'
  refused php start-servers "php: php_pools entry production has pm.start_servers 10 above pm.max_children 5" \
    "$dir/converge.yml" -e '{"php_pools": [{"name": "production", "version": "8.3", "user": "app_prod", "pm": {"start_servers": 10, "max_children": 5}}]}'
  refused php spare-servers "php: php_pools entry production has pm.min_spare_servers 4 above pm.max_spare_servers 3" \
    "$dir/converge.yml" -e '{"php_pools": [{"name": "production", "version": "8.3", "user": "app_prod", "pm": {"min_spare_servers": 4, "max_spare_servers": 3}}]}'
  refused php tmp-dir-root "php: php_pools entry production has an invalid open_basedir or tmp_dir; each must be an absolute path without a colon, and tmp_dir not / and without . or .. in it" \
    "$dir/converge.yml" -e '{"php_pools": [{"name": "production", "version": "8.3", "user": "app_prod", "tmp_dir": "//"}]}'
  refused php tmp-dir-dots "php: php_pools entry production has an invalid open_basedir or tmp_dir" \
    "$dir/converge.yml" -e '{"php_pools": [{"name": "production", "version": "8.3", "user": "app_prod", "tmp_dir": "/srv/prod/../../etc"}]}'
  # Each env value is refused without being printed.
  refused php env-values "php: php_pools entry production has env DOLLAR, LINE that FPM cannot pass on as given" \
    "$dir/converge.yml" -v \
    -e '{"php_pools": [{"name": "production", "version": "8.3", "user": "app_prod", "env": {"LINE": "s3cr3t-line\nnext", "DOLLAR": "$s3cr3t-dollar", "FINE": "s3cr3t-fine"}}]}'
  no_secret "$out/php-env-values.log" s3cr3t-line s3cr3t-dollar s3cr3t-fine
  # A primary group without a group entry (the user is edited by hand).
  hx php useradd -M -N -s /usr/sbin/nologin lostgroup
  hx php sed -i 's/^\(lostgroup:[^:]*:[0-9]*:\)[0-9]*:/\14242:/' /etc/passwd
  refused php lost-group "php: php_pools entry production runs as lostgroup, whose primary group (gid 4242) has no group entry; set group" \
    "$dir/converge.yml" -e '{"php_pools": [{"name": "production", "version": "8.3", "user": "lostgroup"}]}'
  hx php userdel lostgroup
  refused php root-group "php: php_pools entry production runs with the group root (gid 0); a pool runs with an unprivileged group" \
    "$dir/converge.yml" -e '{"php_pools": [{"name": "production", "version": "8.3", "user": "app_prod", "group": "root"}]}'
  # A user whose primary group is root, without group.
  hx php useradd -M -N -g root -s /usr/sbin/nologin rootgroup
  refused php root-primary-group "php: php_pools entry production runs with the group root (gid 0); a pool runs with an unprivileged group" \
    "$dir/converge.yml" -e '{"php_pools": [{"name": "production", "version": "8.3", "user": "rootgroup"}]}'
  hx php userdel rootgroup
  # 64 characters fit the socket path (108 bytes) and the unit name.
  name="$(printf 'a%.0s' {1..65})"
  refused php long-name "php: php_pools entry $name has a name of 65 characters; at most 64 fit its socket path /run/php/<name>.sock and its unit php-fpm@<name>" \
    "$dir/converge.yml" -e "{\"php_pools\": [{\"name\": \"$name\", \"version\": \"8.3\", \"user\": \"app_prod\"}]}"
  php_running refusals

  echo "== php: a pool config FPM rejects never replaces the running one"
  # The role's checks let this number through; FPM's test refuses it.
  conf="$(hx php md5sum /etc/php-fpm/staging/pool.conf)"
  refused php fpm-rejects "failed to validate" "$dir/converge.yml" -v "${upgraded[@]}" \
    -e '{"php_test_staging_pm": {"mode": "static", "max_children": 2147483648}}'
  fpm_rejected fpm-rejects
  no_secret "$out/php-fpm-rejects.log" "${secrets[@]}"
  [ "$(hx php md5sum /etc/php-fpm/staging/pool.conf)" = "$conf" ] || fail "php: the rejected config replaced staging's"
  php_running fpm-rejects
  ask staging /srv/staging | grep -qF '"user":"app_staging"' || fail "php: staging does not answer after the rejected config"

  echo "== php: a new socket owner restarts staging, production keeps running"
  converge php owner "$dir/converge.yml" "${upgraded[@]}" -e php_test_staging_user=app_staging2
  play php "$dir/verify.yml" "${upgraded[@]}" -e php_test_staging_user=app_staging2
  [ "$(pid php php-fpm@production)" = "$prod" ] || fail "php: production restarted on staging's new socket owner"
  [ "$(pid php php-fpm@staging)" != "$staging" ] || fail "php: staging did not restart on its new socket owner"

  echo "== php: a pool that leaves the list stops, its tmp_dir stays"
  converge php no-staging "$dir/converge.yml" -e php_test_staging=false
  play php "$dir/verify.yml" -e php_test_staging=false
  [ "$(hx php systemctl is-active php-fpm@staging || true)" = inactive ] || fail "php: staging still runs"
  [ "$(hx php systemctl is-enabled php-fpm@staging || true)" = disabled ] || fail "php: staging is still enabled"
  hx php test ! -e /etc/php-fpm/staging || fail "php: staging's config is still there"
  hx php test -d /srv/staging/tmp/session || fail "php: staging's tmp_dir is gone"
  [ "$(pid php php-fpm@production)" = "$prod" ] || fail "php: production restarted when staging left"

  suite_php_classic
  suite_php_updates
}

suite_composer() {
  local dir="$here/composer" before sha
  start composer
  hx composer apt-get update -q >/dev/null

  echo "== composer: a host without php is refused before any change"
  refused composer no-php "composer: no php on this host; install PHP first" \
    "$dir/converge.yml" -e composer_test_prepare=false
  hx composer sh -c 'test ! -e /usr/local/bin/composer && test ! -e /usr/local/bin/composer1' \
    || fail "composer: the refused run left a binary"

  hx composer env DEBIAN_FRONTEND=noninteractive apt-get install -y -q php-cli >/dev/null

  echo "== composer: converge (with --diff -v) and idempotence"
  converge composer install "$dir/converge.yml" --diff -v
  play composer "$dir/verify.yml"
  echo "== composer: the --diff -vvv log has no auth value"
  converge composer install-vvv "$dir/converge.yml" --diff -vvv
  for log in install install-idempotence install-vvv install-vvv-idempotence; do
    no_secret "$out/composer-$log.log" s3cr3t
  done

  echo "== composer: a drifted auth.json is rewritten, nothing else changes"
  hx composer sh -c 'chmod 0644 /home/deploy/.config/composer/auth.json'
  converge composer drift "$dir/converge.yml"
  play composer "$dir/verify.yml"

  echo "== composer: a wrong checksum fails and leaves the binaries alone"
  before="$(hx composer sha256sum /usr/local/bin/composer /usr/local/bin/composer1)"
  sha="$(printf '0%.0s' {1..64})"
  refused composer bad-sha "did not match" "$dir/converge.yml" -e "composer_sha256=$sha"
  refused composer bad-sha1 "did not match" "$dir/converge.yml" -e "composer1_sha256=$sha"
  [ "$(hx composer sha256sum /usr/local/bin/composer /usr/local/bin/composer1)" = "$before" ] \
    || fail "composer: a failed download replaced a binary"
  hx composer sh -c '! ls /usr/local/bin | grep -qv "^composer1\?$"' || fail "composer: a failed download left a file in /usr/local/bin"
  play composer "$dir/verify.yml"

  echo "== composer: an unknown user is refused, without the secret in the log"
  refused composer unknown-user "composer: composer_auth names the user nosuchuser, who does not exist" \
    "$dir/converge.yml" -v -e '{"composer_auth": [{"user": "nosuchuser", "auth": {"http-basic": {"repo.example.test": {"username": "u", "password": "s3cr3t-$x"}}}}]}'
  no_secret "$out/composer-unknown-user.log" s3cr3t

  echo "== composer: a symlink planted in the user's home does not redirect root"
  hx composer sh -c 'rm -rf /home/deploy/.config/composer && ln -s /etc /home/deploy/.config/composer'
  play composer "$dir/converge.yml" >"$out/composer-symlink.log" 2>&1 || true
  hx composer sh -c 'test ! -e /etc/auth.json' || fail "composer: a file was written through the user's symlink"
  no_secret "$out/composer-symlink.log" s3cr3t
  hx composer sh -c 'rm /home/deploy/.config/composer'
  converge composer after-symlink "$dir/converge.yml"
  play composer "$dir/verify.yml"

  echo "== composer: two users, a duplicate user, present without auth, a changed content"
  hx composer useradd -m -s /bin/bash second
  converge composer two-users "$dir/converge.yml" --diff -v \
    -e '{"composer_auth": [{"user": "deploy", "auth": {"http-basic": {"a.example.test": {"username": "u", "password": "s3cr3t-1"}}}}, {"user": "second", "auth": {"http-basic": {"b.example.test": {"username": "v", "password": "s3cr3t-2"}}}}]}'
  no_secret "$out/composer-two-users.log" s3cr3t
  hx composer sh -c '[ "$(stat -c "%U %a" /home/deploy/.config/composer/auth.json)" = "deploy 600" ] \
    && [ "$(stat -c "%U %a" /home/second/.config/composer/auth.json)" = "second 600" ] \
    && grep -q a.example.test /home/deploy/.config/composer/auth.json \
    && grep -q b.example.test /home/second/.config/composer/auth.json \
    && ! grep -q b.example.test /home/deploy/.config/composer/auth.json' || fail "composer: the two users' files are wrong"
  refused composer duplicate-user "composer: composer_auth names the user deploy more than once" \
    "$dir/converge.yml" -v \
    -e '{"composer_auth": [{"user": "deploy", "auth": {"k": "s3cr3t-1"}}, {"user": "deploy", "auth": {"k": "s3cr3t-2"}}]}'
  no_secret "$out/composer-duplicate-user.log" s3cr3t
  refused composer no-auth "faulty entries: deploy" "$dir/converge.yml" -v \
    -e '{"composer_auth": [{"user": "deploy"}]}'
  # The same mode, other content: rewritten once, then stable.
  before="$(hx composer sha256sum /home/second/.config/composer/auth.json)"
  play composer "$dir/converge.yml" >"$out/composer-content.log" 2>&1 \
    -e '{"composer_auth": [{"user": "second", "auth": {"http-basic": {"b.example.test": {"username": "v", "password": "s3cr3t-3"}}}}]}' \
    || fail "composer: the content change failed"
  grep -Eq 'changed=1 +unreachable=0 +failed=0' "$out/composer-content.log" || { cat "$out/composer-content.log" >&2; fail "composer: the content change did not change exactly one task"; }
  [ "$(hx composer sha256sum /home/second/.config/composer/auth.json)" != "$before" ] || fail "composer: the content change did not rewrite the file"
  hx composer grep -q s3cr3t-3 /home/second/.config/composer/auth.json || fail "composer: the new content is not there"
  hx composer sh -c '[ "$(stat -c "%a" /home/second/.config/composer/auth.json)" = 600 ]' || fail "composer: the rewritten file's mode drifted"
  converge composer content "$dir/converge.yml" \
    -e '{"composer_auth": [{"user": "second", "auth": {"http-basic": {"b.example.test": {"username": "v", "password": "s3cr3t-3"}}}}]}'
  no_secret "$out/composer-content.log" s3cr3t

  echo "== composer: Composer 1 off removes it, state absent removes the auth file"
  converge composer absent "$dir/converge.yml" -e composer1_enabled=false \
    -e '{"composer_auth": [{"user": "deploy", "state": "absent"}]}'
  hx composer test ! -e /usr/local/bin/composer1 || fail "composer: composer1 is still there"
  hx composer test ! -e /home/deploy/.config/composer/auth.json || fail "composer: the auth file is still there"
  hx composer test -x /usr/local/bin/composer || fail "composer: composer is gone"
}

# php_classic_running: php8.3-fpm and php8.4-fpm still run as PROD and STAGING
# after a failed or refused run ($1 names it).
php_classic_running() {
  [ "$(pid php php8.3-fpm)" = "$prod" ] || fail "php/$1: php8.3-fpm restarted"
  [ "$(pid php php8.4-fpm)" = "$staging" ] || fail "php/$1: php8.4-fpm restarted"
}

# Classic mode (the pools in the packages' php<v>-fpm services) and the switch
# in both directions, after suite_php's steps.
suite_php_classic() {
  local dir="$here/php" prod staging conf files
  local classic=(-e php_fpm_per_pool_service=false)
  local memory=(-e php_test_staging_memory_limit=160M)
  local secrets=('$d e' 'APP_ENV' 's3cr3t-ini')
  # The role's checks let this number through; FPM's test refuses it.
  local bad_pm=(-e '{"php_test_staging_pm": {"mode": "static", "max_children": 2147483648}}')

  echo "== php: a switch to classic mode with a config FPM rejects leaves the instances running"
  prod="$(pid php php-fpm@production)"
  conf="$(hx php md5sum /etc/php-fpm/production/pool.conf)"
  refused php classic-switch-rejects "failed to validate" "$dir/converge.yml" -v "${classic[@]}" "${bad_pm[@]}"
  fpm_rejected classic-switch-rejects
  [ "$(pid php php-fpm@production)" = "$prod" ] || fail "php: production stopped on the rejected switch"
  [ "$(hx php md5sum /etc/php-fpm/production/pool.conf)" = "$conf" ] || fail "php: the rejected switch changed production's config"
  ask production /srv/prod | grep -qF '"user":"app_prod"' || fail "php: production does not answer after the rejected switch"

  echo "== php: classic mode moves the pools into the package services (with --diff -v)"
  # A pool the role does not manage, and one with its header that is not listed.
  hx php sh -c 'printf "; a pool of its own\n[custom]\nuser = www-data\ngroup = www-data\nlisten = /run/php/custom.sock\npm = ondemand\npm.max_children = 1\n" > /etc/php/8.3/fpm/pool.d/custom.conf'
  hx php sh -c 'printf "; Managed by noixdev.infra (php role). Changes here are overwritten.\n[old]\nuser = www-data\ngroup = www-data\nlisten = /run/php/old.sock\npm = ondemand\npm.max_children = 1\n" > /etc/php/8.4/fpm/pool.d/old.conf'
  converge php classic "$dir/converge.yml" --diff -v "${classic[@]}"
  play php "$dir/verify.yml" "${classic[@]}"
  hx php test -S /run/php/custom.sock || fail "php: php8.3-fpm does not run the pool the role does not manage"

  echo "== php: classic mode: a changed ini of staging reloads php8.4-fpm only (with --diff -vvv)"
  prod="$(pid php php8.3-fpm)"
  staging="$(pid php php8.4-fpm)"
  converge php classic-memory "$dir/converge.yml" --diff -vvv "${classic[@]}" "${memory[@]}"
  play php "$dir/verify.yml" "${classic[@]}" "${memory[@]}"
  [ "$(pid php php8.3-fpm)" = "$prod" ] || fail "php: php8.3-fpm restarted on staging's change"
  [ "$(pid php php8.4-fpm)" = "$staging" ] || fail "php: php8.4-fpm restarted instead of a reload"

  echo "== php: classic mode: a pool config FPM rejects never replaces the running one"
  conf="$(hx php md5sum /etc/php/8.4/fpm/pool.d/staging.conf)"
  refused php classic-fpm-rejects "failed to validate" "$dir/converge.yml" -v "${classic[@]}" "${memory[@]}" "${bad_pm[@]}"
  fpm_rejected classic-fpm-rejects
  [ "$(hx php md5sum /etc/php/8.4/fpm/pool.d/staging.conf)" = "$conf" ] || fail "php: the rejected config replaced staging's"
  php_classic_running classic-fpm-rejects
  ask staging /srv/staging | grep -qF '"user":"app_staging"' || fail "php: staging does not answer after the rejected config"

  echo "== php: classic mode: the --diff logs have no env or ini value"
  for log in classic-switch-rejects classic classic-idempotence classic-memory classic-memory-idempotence classic-fpm-rejects; do
    no_secret "$out/php-$log.log" "${secrets[@]}"
  done

  echo "== php: classic mode: a new socket owner restarts php8.4-fpm, php8.3-fpm keeps running"
  converge php classic-owner "$dir/converge.yml" "${classic[@]}" "${memory[@]}" -e php_test_staging_user=app_staging2
  play php "$dir/verify.yml" "${classic[@]}" "${memory[@]}" -e php_test_staging_user=app_staging2
  [ "$(pid php php8.3-fpm)" = "$prod" ] || fail "php: php8.3-fpm restarted on staging's new socket owner"
  [ "$(pid php php8.4-fpm)" != "$staging" ] || fail "php: php8.4-fpm did not restart on staging's new socket owner"

  echo "== php: classic mode: a socket whose owner has no name restarts php8.4-fpm on the next change"
  hx php chown 4243:4243 /run/php/staging.sock
  staging="$(pid php php8.4-fpm)"
  converge php classic-nameless "$dir/converge.yml" "${classic[@]}" -e php_test_staging_user=app_staging2
  play php "$dir/verify.yml" "${classic[@]}" -e php_test_staging_user=app_staging2
  [ "$(pid php php8.3-fpm)" = "$prod" ] || fail "php: php8.3-fpm restarted on staging's nameless socket owner"
  [ "$(pid php php8.4-fpm)" != "$staging" ] || fail "php: php8.4-fpm did not restart on staging's nameless socket owner"

  echo "== php: classic mode: a version move with a config FPM rejects leaves php8.4-fpm serving staging"
  staging="$(pid php php8.4-fpm)"
  conf="$(hx php md5sum /etc/php/8.4/fpm/pool.d/staging.conf)"
  refused php classic-move-rejects "failed to validate" "$dir/converge.yml" -v "${classic[@]}" \
    -e php_test_staging_user=app_staging2 -e php_test_staging_version=8.3 "${bad_pm[@]}"
  fpm_rejected classic-move-rejects
  no_secret "$out/php-classic-move-rejects.log" "${secrets[@]}"
  php_classic_running classic-move-rejects
  [ "$(hx php md5sum /etc/php/8.4/fpm/pool.d/staging.conf)" = "$conf" ] || fail "php: the rejected move changed staging's config"
  hx php test ! -e /etc/php/8.3/fpm/pool.d/staging.conf || fail "php: the rejected move wrote staging's config for 8.3"
  ask staging /srv/staging | grep -qF '"user":"app_staging2"' || fail "php: staging does not answer after the rejected move"

  echo "== php: classic mode: staging moves to 8.3 while extra keeps php8.4-fpm"
  # php8.4-fpm stops before php8.3-fpm takes over staging's socket.
  local owner=("${classic[@]}" "${memory[@]}" -e php_test_staging_user=app_staging2)
  converge php classic-extra "$dir/converge.yml" "${owner[@]}" -e php_test_extra=true
  play php "$dir/verify.yml" "${owner[@]}" -e php_test_extra=true
  prod="$(pid php php8.3-fpm)"
  staging="$(pid php php8.4-fpm)"
  converge php classic-move "$dir/converge.yml" "${owner[@]}" -e php_test_extra=true -e php_test_staging_version=8.3
  play php "$dir/verify.yml" "${owner[@]}" -e php_test_extra=true -e php_test_staging_version=8.3
  [ "$(pid php php8.3-fpm)" = "$prod" ] || fail "php: php8.3-fpm restarted instead of a reload when staging moved in"
  [ "$(pid php php8.4-fpm)" != "$staging" ] || fail "php: php8.4-fpm kept running while staging moved away"
  hx php env SCRIPT_NAME=/php-fpm-ping SCRIPT_FILENAME=/php-fpm-ping REQUEST_METHOD=GET cgi-fcgi -bind -connect /run/php/extra.sock \
    | grep -qx pong || fail "php: extra does not answer on php8.4-fpm"

  echo "== php: classic mode: extra leaves, php8.4-fpm has no pool left and stops"
  converge php classic-no-extra "$dir/converge.yml" "${owner[@]}" -e php_test_staging_version=8.3
  play php "$dir/verify.yml" "${owner[@]}" -e php_test_staging_version=8.3
  [ "$(pid php php8.3-fpm)" = "$prod" ] || fail "php: php8.3-fpm restarted when extra left php8.4-fpm"

  echo "== php: a switch back with a config FPM rejects leaves php8.3-fpm serving both pools"
  prod="$(pid php php8.3-fpm)"
  conf="$(hx php sh -c 'md5sum /etc/php/8.3/fpm/pool.d/*.conf')"
  refused php per-pool-rejects "failed to validate" "$dir/converge.yml" -v "${bad_pm[@]}"
  fpm_rejected per-pool-rejects
  no_secret "$out/php-per-pool-rejects.log" "${secrets[@]}"
  [ "$(pid php php8.3-fpm)" = "$prod" ] || fail "php: php8.3-fpm stopped on the rejected switch back"
  [ "$(hx php sh -c 'md5sum /etc/php/8.3/fpm/pool.d/*.conf')" = "$conf" ] || fail "php: the rejected switch back changed pool.d"
  ask production /srv/prod | grep -qF '"user":"app_prod"' || fail "php: production does not answer after the rejected switch back"
  ask staging /srv/staging | grep -qF '"user":"app_staging2"' || fail "php: staging does not answer after the rejected switch back"

  echo "== php: back to one master per pool, the package services stop"
  converge php per-pool-again "$dir/converge.yml"
  play php "$dir/verify.yml"
  files="$(hx php sh -c 'cd /etc/php && ls -1 8.3/fpm/pool.d 8.4/fpm/pool.d')"
  [ "$files" = "$(printf '8.3/fpm/pool.d:\ncustom.conf\n\n8.4/fpm/pool.d:')" ] \
    || fail "php: pool.d should keep only the file the role does not manage: $files"
}

# rr_count [ROLE]: how many messages the rolling restart has in the journal
# of ROLE's container (php by default).
rr_count() { hx "${1:-php}" sh -c 'journalctl --sync && journalctl -q -t php-fpm-rolling-restart -o cat | wc -l'; }

# rr_since COUNT [ROLE]: the rolling restart's messages after the first COUNT
# (in ROLE's container, php by default), with the PIDs taken out.
rr_since() {
  hx "${2:-php}" sh -c 'journalctl --sync && journalctl -q -t php-fpm-rolling-restart -o cat' \
    | tail -n +"$(($1 + 1))" | sed -E 's/ \(pid [0-9]+\)$//'
}

# reinstall NAME [PACKAGE]: apt reinstalls PACKAGE (php8.3-fpm by default;
# the same version, from packages.sury.org). dpkg logs it as an upgrade, and
# apt runs it with the apt hooks, as unattended-upgrades does (a bare dpkg -i
# runs none). The package's own scripts run unchecked: no policy-rc.d. The log
# is $out/php-NAME.log.
reinstall() {
  hx php sh -c 'mv /usr/sbin/policy-rc.d /usr/sbin/policy-rc.d.off \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall "$1"; rc=$?; \
    mv /usr/sbin/policy-rc.d.off /usr/sbin/policy-rc.d; exit $rc' sh "${2:-php8.3-fpm}" >"$out/php-$1.log" 2>&1 \
    || { cat "$out/php-$1.log" >&2; fail "php/$1: apt failed"; }
}

# package_services_stay NAME: php8.3-fpm and php8.4-fpm are still inactive and
# disabled after the package's own scripts ran.
package_services_stay() {
  local v
  for v in 8.3 8.4; do
    [ "$(hx php systemctl is-active "php$v-fpm" || true)" = inactive ] || fail "php/$1: php$v-fpm runs"
    [ "$(hx php systemctl is-enabled "php$v-fpm" || true)" = disabled ] || fail "php/$1: php$v-fpm is enabled"
  done
}

# needrestart_deferred NAME: needrestart ran in apt's run NAME (or in
# `needrestart -r l`, its output $out/php-NAME.log), restarted no php-fpm@
# pool and listed production as deferred instead.
needrestart_deferred() {
  local log="$out/php-$1.log"
  [ -z "$(awk '/^(Restarting services|Services to be restarted)/ { r = 1; next } /^$/ { r = 0 } r && /php-fpm@/' "$log")" ] \
    || { cat "$log" >&2; fail "php/$1: needrestart restarted php-fpm@ pools"; }
  awk '/^Service restarts being deferred/ { d = 1; next } /^$/ { d = 0 } d && /systemctl restart php-fpm@production[.]service/ { found = 1 }
       END { exit !found }' "$log" || { cat "$log" >&2; fail "php/$1: needrestart did not list production as deferred"; }
}

# The rolling restart after a PHP update (one master per pool), after the
# classic suite: production and staging on 8.3, extra on 8.4. needrestart is
# installed, as on a stock Ubuntu server: its apt hook runs before the role's.
suite_php_updates() {
  local dir="$here/php" prod staging extra count expected log rc started took codename
  local knobs=(-e php_test_staging_version=8.3 -e php_test_extra=true -e php_fpm_restart_timeout=5)
  local script=/usr/local/sbin/php-fpm-rolling-restart conf=/etc/php-fpm/production/pool.conf

  hx php sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -q needrestart >/dev/null' || fail "php: needrestart could not be installed"
  hx php test -e /etc/apt/apt.conf.d/99needrestart || fail "php: needrestart's apt hook is missing"

  echo "== php: updates: production and staging on 8.3, extra on 8.4"
  converge php updates "$dir/converge.yml" "${knobs[@]}"
  play php "$dir/verify.yml" "${knobs[@]}"
  hx php cat "$script" >"$out/php-fpm-rolling-restart"
  shellcheck "$out/php-fpm-rolling-restart" || fail "php: shellcheck finds problems in the rendered $script"
  # The pattern names packages.sury.org's own origin and codename.
  codename="$(hx php sh -c '. /etc/os-release && echo "$VERSION_CODENAME"')"
  hx php apt-cache policy | grep -E "o=deb\.sury\.org,(.*,)?n=$codename(,|$)" >/dev/null \
    || fail "php: apt-cache policy shows no release o=deb.sury.org, n=$codename"

  echo "== php: updates: php-fpm-rolling-restart 8.3 restarts production, then staging"
  prod="$(pid php php-fpm@production)"
  staging="$(pid php php-fpm@staging)"
  extra="$(pid php php-fpm@extra)"
  count="$(rr_count)"
  hx php "$script" 8.3 || fail "php: php-fpm-rolling-restart 8.3 failed"
  [ "$(pid php php-fpm@production)" != "$prod" ] || fail "php: production did not restart"
  [ "$(pid php php-fpm@staging)" != "$staging" ] || fail "php: staging did not restart"
  [ "$(pid php php-fpm@extra)" = "$extra" ] || fail "php: extra (8.4) restarted"
  expected="$(printf '%s\n' 'restarting production (PHP 8.3)' 'production answers' 'restarting staging (PHP 8.3)' 'staging answers')"
  [ "$(rr_since "$count")" = "$expected" ] || fail "php: the journal does not show production, then staging: $(rr_since "$count")"
  hx php sh -c 'journalctl --sync && journalctl -q -t php-fpm-rolling-restart -o cat' \
    | grep -qxF "staging answers (pid $(pid php php-fpm@staging))" || fail "php: the journal does not name staging's new PID"
  ask production /srv/prod | grep -qF '"user":"app_prod"' || fail "php: production does not answer after its restart"
  ask staging /srv/staging | grep -qF '"user":"app_staging"' || fail "php: staging does not answer after its restart"

  echo "== php: updates: apt reinstalls php8.3-fpm, the hook restarts its pools, extra keeps running"
  prod="$(pid php php-fpm@production)"
  staging="$(pid php php-fpm@staging)"
  count="$(rr_count)"
  reinstall hook
  [ "$(pid php php-fpm@production)" != "$prod" ] || fail "php: the hook did not restart production"
  [ "$(pid php php-fpm@staging)" != "$staging" ] || fail "php: the hook did not restart staging"
  [ "$(pid php php-fpm@extra)" = "$extra" ] || fail "php: the hook restarted extra (8.4)"
  expected="$(printf '%s\n' 'PHP 8.3 packages were upgraded: restarting the pools one at a time' \
    'restarting production (PHP 8.3)' 'production answers' 'restarting staging (PHP 8.3)' 'staging answers')"
  [ "$(rr_since "$count")" = "$expected" ] || fail "php: the hook's journal: $(rr_since "$count")"
  needrestart_deferred hook
  package_services_stay hook
  play php "$dir/verify.yml" "${knobs[@]}"

  echo "== php: updates: without the script the hook does nothing and apt passes"
  prod="$(pid php php-fpm@production)"
  staging="$(pid php php-fpm@staging)"
  count="$(rr_count)"
  hx php mv "$script" "$script.off"
  reinstall no-script
  hx php mv "$script.off" "$script"
  [ "$(pid php php-fpm@production)" = "$prod" ] || fail "php: production restarted without the script"
  [ "$(pid php php-fpm@staging)" = "$staging" ] || fail "php: staging restarted without the script"
  [ -z "$(rr_since "$count")" ] || fail "php: the hook ran without the script: $(rr_since "$count")"
  needrestart_deferred no-script
  # The pools still run the replaced binary: needrestart's list mode names
  # them as deferred, not as restarts.
  hx php needrestart -r l >"$out/php-needrestart-list.log" 2>&1 || fail "php: needrestart -r l failed"
  needrestart_deferred needrestart-list

  echo "== php: updates: apt reinstalls php8.4-intl alone, the hook restarts extra (8.4) only"
  prod="$(pid php php-fpm@production)"
  staging="$(pid php php-fpm@staging)"
  extra="$(pid php php-fpm@extra)"
  count="$(rr_count)"
  reinstall extension php8.4-intl
  [ "$(pid php php-fpm@extra)" != "$extra" ] || fail "php: the hook did not restart extra on php8.4-intl"
  [ "$(pid php php-fpm@production)" = "$prod" ] || fail "php: production (8.3) restarted on php8.4-intl"
  [ "$(pid php php-fpm@staging)" = "$staging" ] || fail "php: staging (8.3) restarted on php8.4-intl"
  expected="$(printf '%s\n' 'PHP 8.4 packages were upgraded: restarting the pools one at a time' \
    'restarting extra (PHP 8.4)' 'extra answers')"
  [ "$(rr_since "$count")" = "$expected" ] || fail "php: the hook's journal: $(rr_since "$count")"
  package_services_stay extension

  echo "== php: updates: extra moves to 8.3"
  converge php updates-extra "$dir/converge.yml" "${knobs[@]}" -e php_test_extra_version=8.3
  play php "$dir/verify.yml" "${knobs[@]}" -e php_test_extra_version=8.3

  echo "== php: updates: production does not come back, extra restarted before it, staging keeps running"
  # extra, production, staging: the order of their names.
  hx php cp "$conf" /root/production-pool.conf
  hx php sh -c "echo 'no_such_entry = 1' >> $conf"
  extra="$(pid php php-fpm@extra)"
  staging="$(pid php php-fpm@staging)"
  count="$(rr_count)"
  rc=0
  hx php "$script" 8.3 >"$out/php-rr-fails.log" 2>&1 || rc=$?
  [ "$rc" = 1 ] || { cat "$out/php-rr-fails.log" >&2; fail "php: php-fpm-rolling-restart exited $rc, not 1"; }
  grep -qxF 'php-fpm-rolling-restart: production did not come back; stopping' "$out/php-rr-fails.log" \
    || { cat "$out/php-rr-fails.log" >&2; fail "php: the failure was not reported"; }
  expected="$(printf '%s\n' 'restarting extra (PHP 8.3)' 'extra answers' 'restarting production (PHP 8.3)' 'production did not come back; stopping')"
  [ "$(rr_since "$count")" = "$expected" ] || fail "php: the journal: $(rr_since "$count")"
  [ "$(pid php php-fpm@extra)" != "$extra" ] || fail "php: extra did not restart before production"
  [ "$(pid php php-fpm@staging)" = "$staging" ] || fail "php: staging restarted after production failed"
  hx php env SCRIPT_NAME=/php-fpm-ping SCRIPT_FILENAME=/php-fpm-ping REQUEST_METHOD=GET cgi-fcgi -bind -connect /run/php/extra.sock \
    | grep -qx pong || fail "php: extra does not answer after its restart"
  ask staging /srv/staging | grep -qF '"user":"app_staging"' || fail "php: staging does not answer after production failed"
  [ "$(hx php systemctl is-active php-fpm@production || true)" != active ] || fail "php: production runs with the broken config"

  echo "== php: updates: a pool that restarts but does not answer its ping stops the run after the timeout"
  hx php cp /root/production-pool.conf "$conf"
  hx php sh -c 'systemctl reset-failed php-fpm@production; systemctl restart php-fpm@production'
  hx php sed -i 's/^ping.response = pong$/ping.response = nope/' "$conf"
  hx php grep -qx 'ping.response = nope' "$conf" || fail "php: the test could not change production's ping response"
  staging="$(pid php php-fpm@staging)"
  count="$(rr_count)"
  started="$(date +%s)"
  rc=0
  hx php "$script" 8.3 >"$out/php-rr-silent.log" 2>&1 || rc=$?
  took=$(($(date +%s) - started))
  [ "$rc" = 1 ] || { cat "$out/php-rr-silent.log" >&2; fail "php: php-fpm-rolling-restart exited $rc, not 1"; }
  [ "$took" -ge 5 ] || fail "php: the run gave up after $took seconds, before php_fpm_restart_timeout (5)"
  [ "$(rr_since "$count" | tail -n 1)" = 'production did not come back; stopping' ] || fail "php: the journal: $(rr_since "$count")"
  [ "$(pid php php-fpm@staging)" = "$staging" ] || fail "php: staging restarted after production failed"

  echo "== php: updates: a restart that hangs stops the run after the timeout"
  # The start waits in ExecStartPre far beyond php_fpm_restart_timeout (5).
  hx php sh -c 'mkdir -p /run/systemd/system/php-fpm@production.service.d \
    && printf "[Service]\nExecStartPre=/bin/sleep 120\n" > /run/systemd/system/php-fpm@production.service.d/hang.conf \
    && systemctl daemon-reload'
  extra="$(pid php php-fpm@extra)"
  staging="$(pid php php-fpm@staging)"
  count="$(rr_count)"
  started="$(date +%s)"
  rc=0
  hx php "$script" 8.3 >"$out/php-rr-hangs.log" 2>&1 || rc=$?
  took=$(($(date +%s) - started))
  [ "$rc" = 1 ] || { cat "$out/php-rr-hangs.log" >&2; fail "php: php-fpm-rolling-restart exited $rc, not 1"; }
  [ "$took" -lt 30 ] || fail "php: the run waited $took seconds for the hung restart"
  [ "$(rr_since "$count" | tail -n 1)" = 'production did not come back; stopping' ] || fail "php: the journal: $(rr_since "$count")"
  [ "$(pid php php-fpm@extra)" != "$extra" ] || fail "php: extra did not restart before production"
  [ "$(pid php php-fpm@staging)" = "$staging" ] || fail "php: staging restarted after production hung"
  hx php sh -c 'rm -r /run/systemd/system/php-fpm@production.service.d && systemctl daemon-reload \
    && systemctl restart php-fpm@production'

  echo "== php: updates: a failing restart in the hook is logged and apt passes"
  hx php sh -c "echo 'no_such_entry = 1' >> $conf"
  extra="$(pid php php-fpm@extra)"
  count="$(rr_count)"
  reinstall hook-fails
  grep -qxF 'php-fpm-rolling-restart: production did not come back; stopping' "$out/php-hook-fails.log" \
    || { cat "$out/php-hook-fails.log" >&2; fail "php: apt's output does not report the failure"; }
  [ "$(rr_since "$count" | tail -n 1)" = 'PHP 8.3: the rolling restart stopped; the pools not restarted yet keep running' ] \
    || fail "php: the hook's journal: $(rr_since "$count")"
  [ "$(pid php php-fpm@extra)" != "$extra" ] || fail "php: the hook did not restart extra"
  [ "$(pid php php-fpm@staging)" = "$staging" ] || fail "php: the hook restarted staging after production failed"
  package_services_stay hook-fails

  echo "== php: updates: production comes back with its config"
  hx php cp /root/production-pool.conf "$conf"
  hx php sh -c 'systemctl reset-failed php-fpm@production; systemctl restart php-fpm@production'
  play php "$dir/verify.yml" "${knobs[@]}" -e php_test_extra_version=8.3

  # Last: the run stops every pool.
  echo "== php: updates: the PPA's pattern stays while the PPA's source does (php_versions empty)"
  hx php sh -c 'echo "# stand-in" > /etc/apt/sources.list.d/ondrej-php.sources \
    && echo "// stand-in" > /etc/apt/apt.conf.d/52noixdev-php-ppa'
  play php "$dir/converge.yml" -e '{"php_versions": [], "php_pools": []}' >"$out/php-ppa-pattern.log" 2>&1 \
    || { cat "$out/php-ppa-pattern.log" >&2; fail "php: the run with php_versions empty failed"; }
  hx php test -e /etc/apt/apt.conf.d/52noixdev-php-ppa || fail "php: the PPA's pattern went while its source is there"
  hx php rm /etc/apt/sources.list.d/ondrej-php.sources /etc/apt/apt.conf.d/52noixdev-php-ppa
}

# switch_state: the files of sources.list.d, keyrings, preferences.d and
# apt.conf.d (listing with times, and checksums) and every package's version
# in the php_switch container, to compare before and after a run.
switch_state() {
  hx php_switch sh -c 'cd /etc/apt && for d in sources.list.d keyrings preferences.d apt.conf.d; do
      ls -l --full-time "$d" && find "$d" -maxdepth 1 -type f -exec md5sum {} + | sort; done && dpkg-query -W'
}

# switch_php_versions: every php* package's version in the php_switch container.
switch_php_versions() { hx php_switch dpkg-query -W -f '${Package} ${Version}\n' 'php*'; }

# switch_pools_answer NAME: production and staging answer in the php_switch
# container.
switch_pools_answer() {
  ask production /srv/prod php_switch | grep -qF '"user":"app_prod"' || fail "php_switch/$1: production does not answer"
  ask staging /srv/staging php_switch | grep -qF '"user":"app_staging"' || fail "php_switch/$1: staging does not answer"
}

# switch_no_downgrade NAME BEFORE: no package of BEFORE (switch_php_versions'
# output) has a lower version now, or is gone.
switch_no_downgrade() {
  local down
  down="$(hx php_switch sh -c 'echo "$1" | while read -r p v; do
      [ -n "$v" ] || continue
      n="$(dpkg-query -W -f "\${Version}" "$p" 2>/dev/null || true)"
      if [ -z "$n" ] || dpkg --compare-versions "$n" lt "$v"; then echo "$p $v -> ${n:-gone}"; fi
    done' sh "$2")"
  [ -z "$down" ] || fail "php_switch/$1: PHP packages went down: $down"
}

# switch_sury_version PACKAGE: the highest version packages.sury.org has of
# PACKAGE in the lists (empty when it has none).
switch_sury_version() {
  local v best=''
  for v in $(hx php_switch apt-cache madison "$1" | awk -F '|' '$3 ~ /:\/\/packages\.sury\.org\// { gsub(/ /, "", $2); print $2 }'); do
    if [ -z "$best" ] || hx php_switch dpkg --compare-versions "$v" gt "$best"; then best="$v"; fi
  done
  echo "$best"
}

# The switch from the ondrej/php PPA: a host set up by the released v0.6.0
# role (one master per pool, production on 8.3, staging on 8.4) moves on its
# next run without touching a PHP package or a pool, unless it has a package
# packages.sury.org lacks, and then gets packages.sury.org's updates through
# unattended-upgrades and the rolling restart. Classic mode is not covered:
# the repository steps do not depend on the mode.
suite_php_switch() {
  local dir="$here/php" old="$out/v0.6.0" tree="$out/v0.6.0/ansible_collections/noixdev/infra"
  local old_files='sources.list.d/ondrej-php.sources keyrings/ondrej-php.asc preferences.d/ondrej-php apt.conf.d/52noixdev-php-ppa'
  local new_files='sources.list.d/sury-php.sources keyrings/sury-php.gpg preferences.d/sury-php apt.conf.d/52noixdev-php-sury'
  local message log rc before after prod staging pkg='' candidate versions down count line p v pool was installed sury now ahead=''
  if [ "$ubuntu" != 24.04 ]; then
    echo "== php_switch: skipped on $ubuntu: the ondrej/php PPA has packages for 24.04 only"
    return 0
  fi
  git -C "$root" rev-parse -q --verify 'v0.6.0^{commit}' >/dev/null || fail "php_switch: the tag v0.6.0 is missing (git fetch --tags)"
  start php_switch

  echo "== php_switch: the released v0.6.0 role sets the host up from the PPA"
  hx php_switch sh -c 'apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q needrestart unattended-upgrades >/dev/null' \
    || fail "php_switch: needrestart and unattended-upgrades could not be installed"
  # unattended-upgrades runs below when the test says so, not from its timers.
  hx php_switch systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  rm -rf "$old"
  mkdir -p "$tree"
  git -C "$root" archive v0.6.0 | tar -x -C "$tree"
  # The old role from the tag: its tree comes first, so no other
  # noixdev.infra is found. The rest of the path brings community.docker.
  ANSIBLE_COLLECTIONS_PATH="$old:${ANSIBLE_COLLECTIONS_PATH#"$tests/output:"}" \
    play php_switch "$tree/tests/services/php/converge.yml" >"$out/php_switch-v0.6.0.log" 2>&1 \
    || { cat "$out/php_switch-v0.6.0.log" >&2; fail "php_switch: the v0.6.0 role failed"; }
  ANSIBLE_COLLECTIONS_PATH="$old:${ANSIBLE_COLLECTIONS_PATH#"$tests/output:"}" \
    play php_switch "$tree/tests/services/php/verify.yml" >"$out/php_switch-v0.6.0-verify.log" 2>&1 \
    || { cat "$out/php_switch-v0.6.0-verify.log" >&2; fail "php_switch: the v0.6.0 host does not verify"; }
  hx php_switch sh -c 'cd /etc/apt && for f in $1; do test -e "$f" || exit 1; done' sh "$old_files" \
    || fail "php_switch: the v0.6.0 role did not write the PPA's four files"
  [ -z "$(hx php_switch find /etc/apt -name '*sury*')" ] || fail "php_switch: the v0.6.0 run wrote packages.sury.org's files"
  switch_pools_answer v0.6.0

  echo "== php_switch: --check before the switch changes nothing and does not fail in the repository tasks"
  before="$(switch_state)"
  prod="$(pid php_switch php-fpm@production)"
  staging="$(pid php_switch php-fpm@staging)"
  log="$out/php_switch-check.log"
  rc=0
  play php_switch "$dir/converge.yml" --check >"$log" 2>&1 || rc=$?
  # A failed task names its file in the error's Origin line.
  if grep -E '^Origin: .*/roles/php/tasks/(checks|repository|origins)\.yml:' "$log"; then
    cat "$log" >&2
    fail "php_switch: --check failed in checks.yml, repository.yml or origins.yml"
  fi
  grep -qF "noixdev.infra.php : Remove the PPA's source, key and pin]" "$log" \
    || { cat "$log" >&2; fail "php_switch: --check did not get past the switch check"; }
  echo "   --check exited $rc$(grep -m 1 '^Origin: ' "$log" | sed 's/^/; first failure: /' || true)"
  after="$(switch_state)"
  [ "$after" = "$before" ] || fail "php_switch: --check changed the host: $(diff <(echo "$before") <(echo "$after") || true)"
  [ "$(pid php_switch php-fpm@production)" = "$prod" ] || fail "php_switch: production restarted in --check"
  [ "$(pid php_switch php-fpm@staging)" = "$staging" ] || fail "php_switch: staging restarted in --check"

  echo "== php_switch: a package only the PPA has keeps the host on the PPA, as found"
  # sqlsrv is built for amd64 only, libvirt-php for arm64 too; neither is on
  # packages.sury.org for noble. The first the PPA offers here is the one.
  for candidate in php8.3-sqlsrv php8.3-libvirt-php; do
    if hx php_switch apt-cache policy "$candidate" | awk '/^ *Candidate:/ { c = $2; next }
        $NF ~ /^-?[0-9]+$/ && NF <= 3 { v = $(NF-1); next }
        v == c && $2 ~ /^https?:\/\/ppa\.launchpadcontent\.net\// { found = 1 }
        END { exit !found }'; then
      pkg="$candidate"
      break
    fi
  done
  [ -n "$pkg" ] || fail "php_switch: the PPA offers neither php8.3-sqlsrv nor php8.3-libvirt-php on $(hx php_switch dpkg --print-architecture)"
  echo "   the PPA-only package on $(hx php_switch dpkg --print-architecture): $pkg"
  hx php_switch env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" >/dev/null || fail "php_switch: $pkg could not be installed"
  before="$(switch_state)"
  prod="$(pid php_switch php-fpm@production)"
  staging="$(pid php_switch php-fpm@staging)"
  # The switch check undoes its own files and refreshes the lists, so the run
  # reports changes: not the refused helper.
  message="php: packages.sury.org has no $pkg, which this host has from the ondrej/php PPA; the host stays on the PPA"
  log="$out/php_switch-ppa-only.log"
  if play php_switch "$dir/converge.yml" >"$log" 2>&1; then
    fail "php_switch: the run with $pkg from the PPA did not fail"
  fi
  grep -qF -- "$message" "$log" || { cat "$log" >&2; fail "php_switch: expected the message: $message"; }
  after="$(switch_state)"
  [ "$after" = "$before" ] || fail "php_switch: the refused switch changed the host: $(diff <(echo "$before") <(echo "$after") || true)"
  [ -z "$(hx php_switch find /etc/apt -name '*sury*')" ] || fail "php_switch: the refused switch left packages.sury.org's files"
  [ "$(pid php_switch php-fpm@production)" = "$prod" ] || fail "php_switch: production restarted on the refused switch"
  [ "$(pid php_switch php-fpm@staging)" = "$staging" ] || fail "php_switch: staging restarted on the refused switch"
  switch_pools_answer ppa-only
  hx php_switch env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "$pkg" >/dev/null || fail "php_switch: $pkg could not be purged"

  echo "== php_switch: the switch (and idempotence) keeps every PHP package and pool as it is"
  versions="$(switch_php_versions)"
  prod="$(pid php_switch php-fpm@production)"
  staging="$(pid php_switch php-fpm@staging)"
  converge php_switch switch "$dir/converge.yml"
  play php_switch "$dir/verify.yml"
  hx php_switch sh -c 'cd /etc/apt && for f in $1; do test -e "$f" || exit 1; done && for f in $2; do test ! -e "$f" || exit 1; done' \
    sh "$new_files" "$old_files" || fail "php_switch: after the switch: $(hx php_switch sh -c 'cd /etc/apt && ls -d $1 $2 2>&1' sh "$new_files" "$old_files")"
  after="$(switch_php_versions)"
  [ "$after" = "$versions" ] || fail "php_switch: the switch changed PHP packages: $(diff <(echo "$versions") <(echo "$after") || true)"
  [ "$(pid php_switch php-fpm@production)" = "$prod" ] || fail "php_switch: production restarted on the switch"
  [ "$(pid php_switch php-fpm@staging)" = "$staging" ] || fail "php_switch: staging restarted on the switch"
  switch_pools_answer switch
  # The pin (990, below 1000) never takes a newer version from the PPA back
  # to packages.sury.org's older one.
  down=''
  while read -r p installed now; do
    [ -n "$p" ] || continue
    if hx php_switch dpkg --compare-versions "$now" lt "$installed"; then down="$down $p $installed -> $now;"; fi
  done <<<"$(hx php_switch apt-get -s dist-upgrade | awk '$1 == "Inst" && $2 ~ /^php/ && $3 ~ /^\[/ {
      gsub(/[][]/, "", $3); gsub(/[()]/, "", $4); print $2, $3, $4 }')"
  [ -z "$down" ] || fail "php_switch: apt-get dist-upgrade would downgrade:$down"

  echo "== php_switch: unattended-upgrades brings packages.sury.org's versions, the hook restarts the pools one at a time"
  # Decided per package before the run: on arm64 packages.sury.org builds
  # snapshots that sort below the PPA's version of the same release.
  for p in php8.3-fpm php8.4-fpm; do
    installed="$(hx php_switch dpkg-query -W -f '${Version}' "$p")"
    sury="$(switch_sury_version "$p")"
    [ -n "$sury" ] || fail "php_switch: packages.sury.org has no $p"
    if hx php_switch dpkg --compare-versions "$sury" gt "$installed"; then
      ahead+="$p $sury"$'\n'
      echo "   $p: packages.sury.org's $sury is ahead of the installed $installed"
    else
      echo "   $p: packages.sury.org's $sury is not ahead of the installed $installed: it stays (no downgrade)"
    fi
  done
  versions="$(switch_php_versions)"
  prod="$(pid php_switch php-fpm@production)"
  staging="$(pid php_switch php-fpm@staging)"
  count="$(rr_count php_switch)"
  # The image's policy-rc.d stays: the hook restarts the pools with systemctl.
  hx php_switch unattended-upgrade -v >"$out/php_switch-uu.log" 2>&1 \
    || { cat "$out/php_switch-uu.log" >&2; fail "php_switch: unattended-upgrade failed"; }
  switch_no_downgrade unattended-upgrade "$versions"
  while read -r p sury; do
    [ -n "$p" ] || continue
    now="$(hx php_switch dpkg-query -W -f '${Version}' "$p")"
    [ "$now" = "$sury" ] || { cat "$out/php_switch-uu.log" >&2; fail "php_switch: $p is $now, not packages.sury.org's $sury"; }
    v="${p#php}"
    v="${v%-fpm}"
    if [ "$v" = 8.3 ]; then pool=production was="$prod"; else pool=staging was="$staging"; fi
    [ "$(pid php_switch "php-fpm@$pool")" != "$was" ] || fail "php_switch: $pool did not restart on PHP $v's upgrade"
    for line in "PHP $v packages were upgraded: restarting the pools one at a time" "restarting $pool (PHP $v)" "$pool answers"; do
      [ "$(rr_since "$count" php_switch | grep -cxF "$line" || true)" = 1 ] \
        || fail "php_switch: the journal does not have '$line' once: $(rr_since "$count" php_switch)"
    done
  done <<<"$ahead"
  [ -n "$ahead" ] || echo "   packages.sury.org is not ahead of the PPA here: nothing went down"
  switch_pools_answer unattended-upgrade
  play php_switch "$dir/verify.yml"
}

# ncurl URL [curl args]: the headers and body of URL, asked in the nginx
# container over HTTP/1.1 with the URL's host name resolved to 127.0.0.1.
ncurl() {
  local url="$1" host; shift
  host="${url#*://}"
  host="${host%%/*}"
  hx nginx curl --http1.1 -sS -k -D - --max-time 10 --resolve "$host:80:127.0.0.1" --resolve "$host:443:127.0.0.1" "$@" "$url"
}

# ncurl_rc URL: curl's exit code for URL (52: an empty reply, 35: the TLS
# handshake failed).
ncurl_rc() {
  local rc=0
  ncurl "$1" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

# prod_answers NAME: the prod site answers from its pool after NAME.
prod_answers() {
  local answer
  answer="$(ncurl https://prod.example.test/ || true)"
  grep -qF '"user":"app_prod"' <<<"$answer" || fail "nginx/$1: prod does not answer from its pool: $answer"
}

# has_headers URL WANT...: URL's answer has each header line of WANT ("Name:
# value") and none of the names prefixed with "-" ("-Name").
has_headers() {
  local url="$1" answer want; shift
  answer="$(ncurl "$url" | tr -d '\r')"
  for want in "$@"; do
    case "$want" in
      -*) if grep -qi "^${want#-}:" <<<"$answer"; then fail "nginx: $url has ${want#-}: $answer"; fi ;;
      *) grep -qxF "$want" <<<"$answer" || fail "nginx: $url lacks $want: $answer" ;;
    esac
  done
}

# nginx_state: the role's files and the apt sources, to show that a refused
# run changed nothing.
nginx_state() {
  hx nginx sh -c 'find /etc/nginx /etc/apt/sources.list.d /etc/apt/preferences.d /etc/apt/apt.conf.d -type f -exec md5sum {} + | sort; id -nG www-data'
}

# nginx_links: a link a site user plants below its root is followed only to
# a file of the same owner; prod's group-readable files (www-data reads them
# through app_prod's group) never show under static's name.
nginx_links() {
  local answer
  echo "== nginx: a link to another owner's file is not followed, a link to the user's own file is"
  hx nginx runuser -u app_static -- ln -sfn /srv/prod/public/.well-known/x.txt /srv/static/foreign.txt
  hx nginx runuser -u app_static -- ln -sfn /srv/static/index.html /srv/static/own.txt
  hx nginx ln -sfn /srv/static/index.html /srv/static/root-owned.txt
  answer="$(ncurl https://static.example.test/foreign.txt)"
  grep -qE '^HTTP/1.1 (403|404) ' <<<"$answer" || fail "nginx: static served app_prod's file through a link: $answer"
  if grep -qF well-known <<<"$answer"; then fail "nginx: static showed app_prod's file through a link: $answer"; fi
  answer="$(ncurl https://static.example.test/root-owned.txt)"
  grep -qE '^HTTP/1.1 (403|404) ' <<<"$answer" || fail "nginx: static followed a link of another owner (root): $answer"
  answer="$(ncurl https://static.example.test/own.txt)"
  grep -qxF 'static index' <<<"$answer" || fail "nginx: static did not follow app_static's link to its own file: $answer"
  hx nginx rm -f /srv/static/foreign.txt /srv/static/own.txt /srv/static/root-owned.txt

  # rel's root goes through a deploy's link current (app_static's): to its
  # own release it is followed; re-pointed at prod's tree it is not.
  echo "== nginx: a link in a site's root path is followed to the user's own release, not to another owner's tree"
  local dir="$here/nginx" fast=(-e nginx_test_prepare=false)
  local rel='{"name": "rel", "domains": ["rel.example.test"], "user": "app_static", "root": "/srv/rel/current/public", "tls": "off"}'
  hx nginx install -d -o app_static -g app_static -m 0750 /srv/rel /srv/rel/releases /srv/rel/releases/1 /srv/rel/releases/1/public
  hx nginx runuser -u app_static -- sh -c 'echo "rel release 1" > /srv/rel/releases/1/public/index.html && ln -sfn releases/1 /srv/rel/current'
  converge nginx links-release "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_test_extra_sites\": [$rel]}"
  answer="$(ncurl http://rel.example.test/)"
  grep -qxF 'rel release 1' <<<"$answer" || fail "nginx: rel did not follow app_static's link current to its own release: $answer"
  hx nginx runuser -u app_static -- ln -sfn /srv/prod /srv/rel/current
  answer="$(ncurl http://rel.example.test/.well-known/x.txt)"
  grep -qE '^HTTP/1.1 (403|404) ' <<<"$answer" || fail "nginx: rel served app_prod's tree through its link current: $answer"
  if grep -qF well-known <<<"$answer"; then fail "nginx: rel showed app_prod's file through its link current: $answer"; fi
  play nginx "$dir/converge.yml" "${fast[@]}" >"$out/nginx-links-gone.log" 2>&1 || { cat "$out/nginx-links-gone.log" >&2; fail "nginx: the run without rel failed"; }
  hx nginx rm -rf /srv/rel
}

# nginx_code [curl args]: the status of prod's front page over HTTPS from
# 127.0.0.1 (curl's --interface and -H, -u go in the args).
nginx_code() {
  hx nginx curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve prod.example.test:443:127.0.0.1 "$@" https://prod.example.test/ || true
}

# expect_code WANT NAME [curl args]: prod answers WANT.
expect_code() {
  local want="$1" name="$2" got; shift 2
  got="$(nginx_code "$@")"
  [ "$got" = "$want" ] || fail "nginx/auth: $name answered $got, not $want"
}

# nginx_auth: Basic auth with an allowlist on prod, the real client address
# behind a proxy, and the rate limit of static. 192.0.2.10 is RFC 5737.
nginx_auth() {
  local dir="$here/nginx" fast=(-e nginx_test_prepare=false) auth=(-e nginx_test_auth=true)
  local alice='alice:p$a:s"s\ w' log answer before after
  local secrets=('p$a:s' 'b0b-s3cret' '$6$')
  local changed='n3w pa$$ w0rd'
  local acme=/var/lib/noixdev/acme/.well-known/acme-challenge
  local htpasswd=/etc/nginx/noixdev/htpasswd/prod

  echo "== nginx: Basic auth on prod, the first run with --diff -v, no password in the logs"
  converge nginx auth "$dir/converge.yml" "${fast[@]}" "${auth[@]}" --diff -v
  for log in auth auth-idempotence; do no_secret "$out/nginx-$log.log" "${secrets[@]}"; done
  answer="$(hx nginx stat -c '%U:%G %a' "$htpasswd")"
  [ "$answer" = "root:www-data 640" ] || fail "nginx/auth: the htpasswd file is $answer, not root:www-data 640"
  answer="$(hx nginx cat "$htpasswd")"
  [ "$(grep -c '^\(alice\|bob\):\$6\$' <<<"$answer")" = 2 ] || fail "nginx/auth: the htpasswd file has no SHA-512 hashes for alice and bob"
  if grep -qF 's3cret' <<<"$answer"; then fail "nginx/auth: the htpasswd file has a clear password"; fi
  answer="$(hx nginx grep -c 'auth_basic_user_file /etc/nginx/noixdev/htpasswd/prod;' /etc/nginx/sites/prod.conf)"
  [ "$answer" = 1 ] || fail "nginx/auth: prod.conf names the htpasswd file $answer times, not once"
  hx nginx grep -qx '    satisfy any;' /etc/nginx/sites/prod.conf || fail "nginx/auth: prod.conf lacks satisfy any"
  answer="$( (hx nginx grep -c 'auth_basic' /etc/nginx/sites/node.conf /etc/nginx/sites/static.conf || true) | tr '\n' ' ')"
  [ "$answer" = "/etc/nginx/sites/node.conf:0 /etc/nginx/sites/static.conf:0 " ] || fail "nginx/auth: another site has auth_basic: $answer"

  echo "== nginx: credentials, the allowlist and the challenge path"
  expect_code 401 "prod without credentials"
  expect_code 200 "alice with her password" -u "$alice"
  expect_code 401 "alice with a wrong password" -u 'alice:p$a:s"s\ x'
  expect_code 401 "alice with a prefix of her password" -u 'alice:p$a'
  expect_code 401 "an unknown user" -u 'carol:b0b-s3cret'
  expect_code 200 "bob with his password" -u 'bob:b0b-s3cret'
  expect_code 401 "bob with alice's password" -u 'bob:p$a:s"s\ w'
  answer="$(ncurl https://node.example.test/app | head -n 1 | tr -d '\r')"
  [ "$answer" = 'HTTP/1.1 200 OK' ] || fail "nginx/auth: node answered $answer without credentials"
  hx nginx ip addr replace 192.0.2.10/32 dev lo
  expect_code 200 "the allowlisted address without credentials" --interface 192.0.2.10
  hx nginx ip addr replace 192.0.2.11/32 dev lo
  expect_code 401 "another local address without credentials" --interface 192.0.2.11
  hx nginx sh -c "mkdir -p $acme && echo 'noixdev challenge' > $acme/noixdev-auth"
  for answer in prod.example.test www.prod.example.test; do
    log="$(ncurl "http://$answer/.well-known/acme-challenge/noixdev-auth" | tr -d '\r')"
    if ! grep -qx 'HTTP/1.1 200 OK' <<<"$log" || ! grep -qx 'noixdev challenge' <<<"$log"; then
      fail "nginx/auth: the challenge on $answer is not served without credentials: $log"
    fi
    log="$(ncurl "http://$answer/.well-known/acme-challenge/missing" | head -n 1)"
    case "$log" in *" 404 "*) ;; *) fail "nginx/auth: a missing challenge on $answer answered $log, not 404" ;; esac
  done
  hx nginx rm -f "$acme/noixdev-auth"

  echo "== nginx: the real client address behind a proxy"
  expect_code 401 "a forwarded allowlisted address without nginx_real_ip_from" -H 'X-Forwarded-For: 192.0.2.10'
  converge nginx auth-real-ip "$dir/converge.yml" "${fast[@]}" "${auth[@]}" -e '{"nginx_real_ip_from": ["127.0.0.1"]}'
  hx nginx grep -qx '    set_real_ip_from 127.0.0.1;' /etc/nginx/nginx.conf || fail "nginx/auth: nginx.conf lacks set_real_ip_from"
  expect_code 200 "a forwarded allowlisted address from a trusted proxy" -H 'X-Forwarded-For: 192.0.2.10'
  # The client is the last address the trusted proxy did not add: the right-most.
  expect_code 200 "an allowlisted client behind an earlier hop" -H 'X-Forwarded-For: 192.0.2.99, 192.0.2.10'
  expect_code 401 "a forged allowlisted address ahead of the real client" -H 'X-Forwarded-For: 192.0.2.10, 192.0.2.99'
  expect_code 401 "a forwarded address that is not listed" -H 'X-Forwarded-For: 192.0.2.99'
  expect_code 401 "no forwarded address"
  expect_code 200 "alice behind the proxy" -u "$alice"

  echo "== nginx: a changed password, with --diff -vvv"
  hx nginx cp "$htpasswd" /root/htpasswd-before
  converge nginx auth-changed "$dir/converge.yml" "${fast[@]}" "${auth[@]}" -e "{\"nginx_test_auth_alice\": \"$changed\"}" --diff -vvv
  for log in auth-changed auth-changed-idempotence; do no_secret "$out/nginx-$log.log" "${secrets[@]}" 'n3w pa' 'w0rd'; done
  expect_code 401 "alice with her old password" -u "$alice"
  expect_code 200 "alice with her new password" -u "alice:$changed"
  expect_code 200 "bob after alice's change" -u 'bob:b0b-s3cret'
  # The salt comes from the site and the user: bob's line stays as it was.
  [ "$(hx nginx grep '^bob:' /root/htpasswd-before)" = "$(hx nginx grep '^bob:' "$htpasswd")" ] || fail "nginx/auth: bob's hash changed with alice's password"
  [ "$(hx nginx grep '^alice:' /root/htpasswd-before)" != "$(hx nginx grep '^alice:' "$htpasswd")" ] || fail "nginx/auth: alice's hash did not change with her password"
  hx nginx rm -f /root/htpasswd-before

  echo "== nginx: a failed htpasswd write fails without the task's output, and names no password"
  # A read-only bind mount: the write fails, whatever its message says.
  hx nginx mount --bind /etc/nginx/noixdev/htpasswd /etc/nginx/noixdev/htpasswd
  hx nginx mount -o remount,bind,ro /etc/nginx/noixdev/htpasswd
  if play nginx "$dir/converge.yml" "${fast[@]}" "${auth[@]}" -e '{"nginx_test_auth_alice": "pw-ro-secret"}' -v >"$out/nginx-auth-ro.log" 2>&1; then
    hx nginx umount /etc/nginx/noixdev/htpasswd
    fail "nginx/auth: the run with a read-only htpasswd directory did not fail"
  fi
  hx nginx umount /etc/nginx/noixdev/htpasswd
  grep -qF 'the output of the task is hidden, it has no_log' "$out/nginx-auth-ro.log" \
    || { cat "$out/nginx-auth-ro.log" >&2; fail "nginx/auth: the failure does not say the task's output is hidden"; }
  no_secret "$out/nginx-auth-ro.log" pw-ro-secret '$6$'
  expect_code 200 "alice after the failed write" -u "alice:$changed"

  echo "== nginx: bob leaves the list, his login fails"
  converge nginx auth-no-bob "$dir/converge.yml" "${fast[@]}" "${auth[@]}" -e nginx_test_auth_bob=false
  expect_code 401 "bob after he left" -u 'bob:b0b-s3cret'
  expect_code 200 "alice after bob left" -u "$alice"
  [ "$(hx nginx grep -c '^bob:' "$htpasswd" || true)" = 0 ] || fail "nginx/auth: bob is still in the htpasswd file"

  echo "== nginx: an empty allowlist means a password for every address"
  converge nginx auth-no-allow "$dir/converge.yml" "${fast[@]}" "${auth[@]}" -e '{"nginx_test_auth_allow": []}'
  expect_code 401 "the formerly allowlisted address without an allowlist" --interface 192.0.2.10
  expect_code 200 "alice without an allowlist" -u "$alice"
  hx nginx sh -c '! grep -q "satisfy any" /etc/nginx/sites/prod.conf' || fail "nginx/auth: prod.conf has satisfy any without an allowlist"

  echo "== nginx: a site without basic_auth loses its htpasswd file"
  converge nginx auth-off "$dir/converge.yml" "${fast[@]}"
  hx nginx test ! -e "$htpasswd" || fail "nginx/auth: the htpasswd file is still there"
  [ -z "$(hx nginx sh -c 'ls -A /etc/nginx/noixdev/htpasswd')" ] || fail "nginx/auth: the htpasswd directory still has files"
  expect_code 200 "prod after basic_auth went"
  hx nginx ip addr del 192.0.2.10/32 dev lo
  hx nginx ip addr del 192.0.2.11/32 dev lo

  echo "== nginx: rate limit: a burst gets 429, the challenge is never limited, the zone cools down"
  converge nginx rate "$dir/converge.yml" "${fast[@]}" -e nginx_test_static_rate_limit=default
  hx nginx grep -qx '    limit_req zone=default burst=20 nodelay;' /etc/nginx/sites/static.conf || fail "nginx/auth: static.conf lacks limit_req"
  [ "$(hx nginx grep -c 'limit_req ' /etc/nginx/sites/static.conf)" = 1 ] || fail "nginx/auth: static.conf has limit_req outside its server block"
  hx nginx grep -qx '    limit_req_zone $binary_remote_addr zone=default:10m rate=10r/s;' /etc/nginx/nginx.conf || fail "nginx/auth: nginx.conf lacks the zone"
  hx nginx sh -c "mkdir -p $acme && echo 'noixdev challenge' > $acme/noixdev-rate"
  answer="$(hx nginx bash -c 'for i in $(seq 50); do curl -sk -o /tmp/noixdev-rate.$i -w "%{http_code}\n" --max-time 20 --resolve static.example.test:443:127.0.0.1 https://static.example.test/ & done; wait')"
  echo "   50 parallel requests: $(sort <<<"$answer" | uniq -c | tr -s ' ' | paste -sd, -)"
  grep -qx 429 <<<"$answer" || fail "nginx/auth: 50 parallel requests gave no 429"
  if grep -qx 503 <<<"$answer"; then fail "nginx/auth: a rate limited request answered 503, not 429"; fi
  grep -qx 200 <<<"$answer" || fail "nginx/auth: 50 parallel requests gave no 200"
  # A limited request gets the noix 429 page.
  answer="$(hx nginx sh -c 'grep -lF "data-code=\"429\"" /tmp/noixdev-rate.* || true')"
  [ -n "$answer" ] || fail "nginx/auth: no rate limited request got the noix 429 page"
  hx nginx sh -c 'rm -f /tmp/noixdev-rate.*'
  answer="$(ncurl http://static.example.test/.well-known/acme-challenge/noixdev-rate | head -n 1 | tr -d '\r')"
  [ "$answer" = 'HTTP/1.1 200 OK' ] || fail "nginx/auth: the challenge on a rate limited site answered $answer"
  hx nginx rm -f "$acme/noixdev-rate"
  sleep 4
  answer="$(ncurl https://static.example.test/ | head -n 1 | tr -d '\r')"
  [ "$answer" = 'HTTP/1.1 200 OK' ] || fail "nginx/auth: static still answers $answer after the zone cooled down"
  converge nginx rate-off "$dir/converge.yml" "${fast[@]}"
  hx nginx sh -c '! grep -q limit_req /etc/nginx/sites/static.conf' || fail "nginx/auth: static.conf still has limit_req"

  echo "== nginx: invalid basic_auth is refused before any change, with no password in the log"
  local site='"name": "ba", "domains": ["ba.example.test"], "user": "app_prod", "root": "/srv/prod/public", "tls": "off"'
  before="$(nginx_state)"
  refused nginx auth-colon "nginx: nginx_sites entry ba has an invalid basic_auth: user #1 has no name, or a name with" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"basic_auth\": {\"users\": [{\"name\": \"a:b\", \"password\": \"pw-colon-secret\"}]}}]}"
  refused nginx auth-newline-name "nginx: nginx_sites entry ba has an invalid basic_auth: user #1 has no name, or a name with" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"basic_auth\": {\"users\": [{\"name\": \"a\\nb\", \"password\": \"pw-nlname-secret\"}]}}]}"
  refused nginx auth-duplicate "nginx: nginx_sites entry ba has an invalid basic_auth: user ann is listed twice" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"basic_auth\": {\"users\": [{\"name\": \"ann\", \"password\": \"pw-dup-secret1\"}, {\"name\": \"ann\", \"password\": \"pw-dup-secret2\"}]}}]}"
  refused nginx auth-newline-password "nginx: nginx_sites entry ba has an invalid basic_auth: user ann has no password, or a password that is not a one-line string" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"basic_auth\": {\"users\": [{\"name\": \"ann\", \"password\": \"pw-nlpass-secret\\nline2\"}]}}]}"
  refused nginx auth-number-password "nginx: nginx_sites entry ba has an invalid basic_auth: user ann has no password, or a password that is not a one-line string" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"basic_auth\": {\"users\": [{\"name\": \"ann\", \"password\": 123456}]}}]}"
  refused nginx auth-no-users "nginx: nginx_sites entry ba has an invalid basic_auth: users is a list of at least one" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"basic_auth\": {\"allow\": [\"192.0.2.10\"]}}]}"
  refused nginx auth-bad-allow "nginx: nginx_sites entry ba has an invalid basic_auth: allow has an entry that is not an address or CIDR" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"basic_auth\": {\"users\": [{\"name\": \"ann\", \"password\": \"pw-allow-secret\"}], \"allow\": [\"192.0.2.4; deny all\"]}}]}"
  refused nginx auth-unknown-key "nginx: nginx_sites entry ba has an invalid basic_auth: user #1 has unknown keys (pasword)" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"basic_auth\": {\"users\": [{\"name\": \"ann\", \"pasword\": \"pw-typo-secret\"}]}}]}"
  refused nginx auth-leading-hash "nginx: nginx_sites entry ba has an invalid basic_auth: user #1 has no name, or a name with" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"basic_auth\": {\"users\": [{\"name\": \"#bob\", \"password\": \"pw-hash-secret\"}]}}]}"
  refused nginx auth-leading-space "nginx: nginx_sites entry ba has an invalid basic_auth: user #1 has no name, or a name with" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"basic_auth\": {\"users\": [{\"name\": \" bob\", \"password\": \"pw-space-secret\"}]}}]}"
  PYTHONPATH="$dir/nopasslib" refused nginx auth-no-passlib "nginx: basic_auth needs passlib on the controller" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"basic_auth\": {\"users\": [{\"name\": \"ann\", \"password\": \"pw-nopasslib-secret\"}]}}]}"
  refused nginx real-ip-v4-zero "nginx: nginx_real_ip_from has 0.0.0.0/0, a range of every address" \
    "$dir/converge.yml" "${fast[@]}" -e '{"nginx_real_ip_from": ["127.0.0.1", "0.0.0.0/0"]}'
  refused nginx real-ip-v6-zero "nginx: nginx_real_ip_from has ::/0, a range of every address" \
    "$dir/converge.yml" "${fast[@]}" -e '{"nginx_real_ip_from": ["::/0"]}'
  # Anubis's error_page 401 would turn Basic auth's 401 into its challenge.
  refused nginx auth-anubis "nginx: nginx_sites entry ba has basic_auth and anubis; Anubis would answer Basic auth's 401 with its challenge, so a site has one of them at most" \
    "$dir/converge.yml" "${fast[@]}" -v -e "{\"nginx_sites\": [{$site, \"anubis\": true, \"basic_auth\": {\"users\": [{\"name\": \"ann\", \"password\": \"pw-anubis-secret\"}]}}]}"
  for log in colon newline-name duplicate newline-password number-password no-users bad-allow unknown-key leading-hash leading-space no-passlib anubis; do
    no_secret "$out/nginx-auth-$log.log" pw-colon-secret pw-nlname-secret pw-dup-secret pw-nlpass-secret 123456 pw-allow-secret pw-typo-secret pw-hash-secret pw-space-secret pw-nopasslib-secret pw-anubis-secret
  done
  after="$(nginx_state)"
  [ "$after" = "$before" ] || fail "nginx/auth: a refused run changed the host: $(diff <(echo "$before") <(echo "$after") || true)"
  prod_answers auth
}

# nginx_failed_join: a run that fails after www-data joined a new site's
# group still records it, so www-data leaves the group when the site goes.
nginx_failed_join() {
  local dir="$here/nginx" fast=(-e nginx_test_prepare=false) answer
  local site='{"name": "new", "domains": ["new.example.test"], "user": "app_new", "root": "/srv/static", "tls": "off"'
  echo "== nginx: a group www-data joined in a failed run is left when its site goes"
  hx nginx useradd -m -s /bin/bash app_new
  if play nginx "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_test_extra_sites\": [$site, \"extra\": \"this is not nginx;\"}]}" \
      >"$out/nginx-failed-join.log" 2>&1; then
    fail "nginx: the run with the new site's broken extra did not fail"
  fi
  answer=" $(hx nginx id -nG www-data) "
  case "$answer" in *" app_new "*) ;; *) fail "nginx: the failed run did not let www-data join app_new:$answer" ;; esac
  hx nginx test ! -e /etc/nginx/sites/new.conf || fail "nginx: the failed run left new.conf"
  converge nginx new-site "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_test_extra_sites\": [$site}]}"
  converge nginx no-new-site "$dir/converge.yml" "${fast[@]}"
  answer=" $(hx nginx id -nG www-data) "
  case "$answer" in *" app_new "*) fail "nginx: www-data is still in app_new's group after its site went:$answer" ;; esac
  answer="$(hx nginx cat /etc/nginx/noixdev/site-groups)"
  if grep -qx app_new <<<"$answer"; then fail "nginx: the state still records app_new: $answer"; fi
}

# nginx_distro_refused: Ubuntu's nginx-common in a fresh container is refused
# before any change.
nginx_distro_refused() {
  local dir="$here/nginx" version
  echo "== nginx: Ubuntu's nginx-common is refused before any change"
  start nginxdistro
  hx nginxdistro apt-get update -q >/dev/null
  hx nginxdistro env DEBIAN_FRONTEND=noninteractive apt-get install -y -q nginx-common >/dev/null
  version="$(hx nginxdistro dpkg-query -W -f='${Version}' nginx-common)"
  echo "   Ubuntu's nginx-common on $ubuntu: $version"
  refused nginxdistro distro "nginx: installed nginx-common $version is not from nginx.org; the role manages nginx.org's packages only" \
    "$dir/converge.yml" -e nginx_test_prepare=false -e '{"nginx_sites": []}'
  hx nginxdistro sh -c 'test ! -e /etc/apt/sources.list.d/nginx.sources && test ! -e /etc/apt/keyrings/nginx.asc && test ! -e /etc/apt/preferences.d/nginx' \
    || fail "nginx: the refused run left repository files"
  [ "$(hx nginxdistro dpkg-query -W -f='${Version}' nginx-common)" = "$version" ] || fail "nginx: nginx-common changed after the refused run"
  docker rm -f -v "$prefix-nginxdistro" >/dev/null
}

# nginx_serial NAME: the serial of the certificate nginx presents for NAME.
nginx_serial() {
  hx nginx sh -c "openssl s_client -connect 127.0.0.1:443 -servername $1 </dev/null 2>/dev/null | openssl x509 -noout -serial"
}

# nginx_issued: how many certificates certbot has issued for prod.
nginx_issued() {
  hx nginx sh -c 'find /etc/letsencrypt/archive/prod -name "cert*.pem" | wc -l'
}

# nginx_workers MASTER: the PIDs of MASTER's workers, sorted.
nginx_workers() {
  hx nginx pgrep -P "$1" | sort
}

# nginx_trusted URL: the status and the redirect of URL, asked with the
# system's trust store (Pebble's root, not -k).
nginx_trusted() {
  local host="${1#*://}"
  host="${host%%/*}"
  hx nginx curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 --resolve "$host:443:127.0.0.1" "$1"
}

# nginx_acme: prod's certificate from Pebble: issued once, renewed through
# the deploy hook, reissued for a new name; a site whose certificate fails
# keeps its HTTP block and leaves every other site alone.
nginx_acme() {
  local dir="$here/nginx" fast=(-e nginx_test_prepare=false) answer master workers serial before tries attempt
  local prod_old='{"nginx_test_prod_redirects": ["www.prod.example.test", "old.prod.example.test"]}'
  local broken='{"name": "broken", "domains": ["unresolvable.example.test"], "user": "app_static", "root": "/srv/static"}'
  local late='{"name": "late", "domains": ["late.example.test"], "user": "app_static", "root": "/srv/static"}'

  echo "== nginx: the role reads certbot's results: a masked error is a failure, a skipped request is not"
  play nginx "$dir/acme-results.yml"

  echo "== nginx: prod's certificate came with the first run, the second asked for none"
  answer="$(nginx_issued)"
  [ "$answer" = 1 ] || fail "nginx: certbot issued $answer certificates for prod in two runs, not 1"

  echo "== nginx: certbot's timer is active"
  answer="$(hx nginx systemctl list-timers --all certbot.timer)"
  case "$answer" in *certbot.timer*) ;; *) fail "nginx: list-timers does not show certbot.timer: $answer" ;; esac
  answer="$(hx nginx systemctl is-active certbot.timer || true)"
  [ "$answer" = active ] || fail "nginx: certbot.timer is $answer"

  echo "== nginx: a forced renewal reloads nginx through the deploy hook: new workers, the same master"
  master="$(hx nginx systemctl show -p MainPID --value nginx)"
  workers="$(nginx_workers "$master")"
  serial="$(nginx_serial prod.example.test)"
  # Only this renewal's lines: the log is kept across runs of a container.
  hx nginx truncate -s 0 /var/log/letsencrypt/letsencrypt.log
  hx nginx certbot renew --force-renewal --no-random-sleep-on-renew >"$out/nginx-renew.log" 2>&1 \
    || { cat "$out/nginx-renew.log" >&2; fail "nginx: certbot renew failed"; }
  # certbot logs the hooks it runs in its log of this run, not on stdout.
  hx nginx grep -qF 'Running deploy-hook command: /etc/letsencrypt/renewal-hooks/deploy/noixdev-nginx' /var/log/letsencrypt/letsencrypt.log \
    || { cat "$out/nginx-renew.log" >&2; fail "nginx: the renewal did not run the deploy hook"; }
  # The old workers finish their requests and exit.
  tries=0
  while [ -n "$(comm -12 <(echo "$workers") <(nginx_workers "$master"))" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || fail "nginx: the workers $workers are still there after the renewal"
    sleep 1
  done
  [ -n "$(nginx_workers "$master")" ] || fail "nginx: the master $master has no workers after the renewal"
  answer="$(hx nginx systemctl show -p MainPID --value nginx)"
  [ "$answer" = "$master" ] || fail "nginx: the renewal restarted nginx (MainPID $master, now $answer)"
  answer="$(nginx_serial prod.example.test)"
  [ "$answer" != "$serial" ] || fail "nginx: prod still presents the certificate from before the renewal ($serial)"
  answer="$(nginx_issued)"
  [ "$answer" = 2 ] || fail "nginx: certbot issued $answer certificates for prod after the renewal, not 2"

  echo "== nginx: a new redirect domain on prod reissues its certificate with it"
  converge nginx acme-redirect "$dir/converge.yml" "${fast[@]}" -e "$prod_old"
  answer="$(nginx_issued)"
  [ "$answer" = 3 ] || fail "nginx: certbot issued $answer certificates for prod after the new name, not 3"
  answer="$(nginx_trusted https://old.prod.example.test/x)"
  [ "$answer" = "301 https://prod.example.test/x" ] || fail "nginx: old.prod.example.test over HTTPS answered $answer"
  answer="$(nginx_trusted https://prod.example.test/)"
  [ "$answer" = "200 " ] || fail "nginx: prod.example.test over HTTPS answered $answer"

  echo "== nginx: a certificate that fails leaves its site on HTTP and the other sites alone, and the run names it"
  master="$(hx nginx systemctl show -p MainPID --value nginx)"
  before="$(hx nginx md5sum /etc/nginx/sites/prod.conf /etc/nginx/sites/node.conf /etc/nginx/sites/static.conf)"
  # broken comes before late: late still gets its certificate. The second
  # run asks again.
  for attempt in first retry; do
    if play nginx "$dir/converge.yml" "${fast[@]}" -e "$prod_old" -e "{\"nginx_test_extra_sites\": [$broken, $late]}" \
        >"$out/nginx-acme-$attempt.log" 2>&1; then
      fail "nginx: the $attempt run with an unresolvable domain did not fail"
    fi
    grep -qF 'nginx: certbot got no certificate for site broken (unresolvable.example.test: ' "$out/nginx-acme-$attempt.log" \
      || { cat "$out/nginx-acme-$attempt.log" >&2; fail "nginx: the $attempt failed run does not name unresolvable.example.test"; }
    # What broken serves until then: its HTTP block, none of its content.
    grep -qF 'a site without one (new, or switched to letsencrypt) serves only its HTTP block, the ACME challenges and a redirect to HTTPS, none of its content' "$out/nginx-acme-$attempt.log" \
      || { cat "$out/nginx-acme-$attempt.log" >&2; fail "nginx: the $attempt failed run does not say what a site without a certificate serves"; }
    answer="$(hx nginx systemctl show -p MainPID --value nginx)"
    [ "$answer" = "$master" ] || fail "nginx: the $attempt failed run restarted nginx (MainPID $master, now $answer)"
    answer="$(hx nginx md5sum /etc/nginx/sites/prod.conf /etc/nginx/sites/node.conf /etc/nginx/sites/static.conf)"
    [ "$answer" = "$before" ] || fail "nginx: the $attempt failed run changed the other sites: $answer"
    hx nginx sh -c '! grep -q "listen 443" /etc/nginx/sites/broken.conf' || fail "nginx: broken has a TLS block: $(hx nginx cat /etc/nginx/sites/broken.conf)"
    answer="$(ncurl http://unresolvable.example.test/x | tr -d '\r')"
    grep -qxF 'Location: https://unresolvable.example.test/x' <<<"$answer" || fail "nginx: broken's HTTP block does not answer: $answer"
    answer="$(nginx_trusted https://late.example.test/)"
    [ "$answer" = "200 " ] || fail "nginx: late over HTTPS answered $answer after the $attempt failed run"
    prod_answers "acme-$attempt"
  done
  hx nginx test ! -e /etc/letsencrypt/live/broken || fail "nginx: broken has a certificate"

  echo "== nginx: a TLS block nginx rejects after a failed request: the run names both, the other sites stay"
  # tlsfail gets its certificate, but its extra (only in its TLS block) fails
  # nginx -t: its HTTP block is put back.
  local tlsfail='{"name": "tlsfail", "domains": ["tlsfail.example.test"], "user": "app_static", "root": "/srv/static", "extra": "this is not nginx;"}'
  if play nginx "$dir/converge.yml" "${fast[@]}" -e "$prod_old" -e "{\"nginx_test_extra_sites\": [$broken, $late, $tlsfail]}" \
      >"$out/nginx-acme-tlsfail.log" 2>&1; then
    fail "nginx: the run with tlsfail's broken extra did not fail"
  fi
  for want in 'nginx: certbot got no certificate for site broken (unresolvable.example.test: ' \
      'unknown directive "this" in /etc/nginx/sites/tlsfail.conf'; do
    grep -qF "$want" "$out/nginx-acme-tlsfail.log" || { cat "$out/nginx-acme-tlsfail.log" >&2; fail "nginx: the failed run does not say: $want"; }
  done
  answer="$(hx nginx systemctl show -p MainPID --value nginx)"
  [ "$answer" = "$master" ] || fail "nginx: the tlsfail run restarted nginx (MainPID $master, now $answer)"
  answer="$(hx nginx md5sum /etc/nginx/sites/prod.conf /etc/nginx/sites/node.conf /etc/nginx/sites/static.conf)"
  [ "$answer" = "$before" ] || fail "nginx: the tlsfail run changed the other sites: $answer"
  hx nginx sh -c '! grep -q "listen 443" /etc/nginx/sites/tlsfail.conf' || fail "nginx: tlsfail kept the TLS block nginx rejected"
  answer="$(nginx_trusted https://late.example.test/)"
  [ "$answer" = "200 " ] || fail "nginx: late over HTTPS answered $answer after the tlsfail run"
  prod_answers acme-tlsfail

  echo "== nginx: back to prod's own names: the certificate follows, the extra sites go"
  converge nginx acme-defaults "$dir/converge.yml" "${fast[@]}"
  answer="$(nginx_issued)"
  [ "$answer" = 4 ] || fail "nginx: certbot issued $answer certificates for prod after the name went, not 4"
  answer="$(hx nginx certbot certificates --cert-name prod 2>/dev/null)"
  grep -qE '^ +Domains: prod[.]example[.]test www[.]prod[.]example[.]test$' <<<"$answer" || fail "nginx: prod's certificate has other names: $answer"
  hx nginx sh -c 'test ! -e /etc/nginx/sites/broken.conf && test ! -e /etc/nginx/sites/late.conf' || fail "nginx: the extra sites are still there"

  # The same Pebble under another directory URL: another ACME server to
  # certbot (an account and a renewal server of its own).
  echo "== nginx: a new nginx_acme_server reissues prod's certificate from it, once, and back"
  local server
  for server in https://127.0.0.1:14000/dir https://localhost:14000/dir; do
    serial="$(nginx_serial prod.example.test)"
    before="$(nginx_issued)"
    converge nginx "acme-server-${server//[^a-z0-9]/}" "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_acme_server\": \"$server\"}"
    answer="$(nginx_issued)"
    [ "$answer" = $((before + 1)) ] || fail "nginx: certbot issued $answer certificates for prod after the server became $server, not $((before + 1))"
    answer="$(hx nginx sh -c 'grep "^server *=" /etc/letsencrypt/renewal/prod.conf || true')"
    [ "$answer" = "server = $server" ] || fail "nginx: prod's renewal conf names '$answer', not the server $server"
    answer="$(nginx_serial prod.example.test)"
    [ "$answer" != "$serial" ] || fail "nginx: prod still presents the certificate from before the server became $server ($serial)"
    answer="$(nginx_trusted https://prod.example.test/)"
    [ "$answer" = "200 " ] || fail "nginx: prod.example.test over HTTPS answered $answer after the server became $server"
  done
}

# nginx_no_docker: error pages (on by default) on a fresh container without
# Docker (not privileged, no systemd) are refused before any change.
nginx_no_docker() {
  local dir="$here/nginx" name="$prefix-nginxnodocker"
  echo "== nginx: the error pages without Docker are refused before any change"
  docker rm -f -v "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --entrypoint sleep "noixdev-infra-host:$ubuntu" infinity >/dev/null
  started+=("$name")
  refused nginxnodocker no-docker "Docker is not installed or not running on" \
    "$dir/converge.yml" -e nginx_test_prepare=false -e '{"nginx_sites": []}'
  hx nginxnodocker sh -c 'test ! -e /etc/apt/sources.list.d/nginx.sources && test ! -e /etc/apt/keyrings/nginx.asc && test ! -e /etc/nginx' \
    || fail "nginx: the run refused for Docker left files"
  docker rm -f -v "$name" >/dev/null
}

# nginx_images: the images of the role defaults (the error pages, Anubis),
# pulled once here and loaded into the nginx container's Docker.
nginx_images() {
  local images=() tar image
  images+=("$(sed -n 's/^nginx_error_pages_image: *//p' "$root/roles/nginx/defaults/main.yml")")
  images+=("$(sed -n 's/^anubis_image: *//p' "$root/roles/anubis/defaults/main.yml")")
  for image in "${images[@]}"; do [ -n "$image" ] || fail "nginx: an image name is missing in the defaults"; done
  tar="$out/nginx-images-$(printf '%s\n' "${images[@]}" | shasum | cut -c1-12).tar"
  if [ ! -s "$tar" ]; then
    for image in "${images[@]}"; do docker pull -q "$image" >/dev/null; done
    docker save -o "$tar" "${images[@]}"
  fi
  docker exec -i "$prefix-nginx" docker load <"$tar" >/dev/null
}

# nginx_error_pages: the noix pages for nginx's own errors (verify.yml has
# the 404s and the 413), the 502 of a stopped pool, and nginx_error_pages
# false.
nginx_error_pages() {
  local dir="$here/nginx" fast=(-e nginx_test_prepare=false) answer unit=php-fpm@production
  echo "== nginx: the error pages come through the export's link"
  # error_pages_export publishes a release through the link current; root
  # owns the link and its target, so disable_symlinks if_not_owner follows it.
  answer="$(hx nginx stat -c '%U %F' /var/www/noix-error-pages/current)"
  [ "$answer" = "root symbolic link" ] || fail "nginx: /var/www/noix-error-pages/current is '$answer', not root's link"

  echo "== nginx: a stopped pool gives the noix 502 page"
  hx nginx systemctl stop "$unit"
  answer="$(ncurl https://prod.example.test/ | tr -d '\r')"
  hx nginx systemctl start "$unit"
  grep -q '^HTTP/1.1 502 ' <<<"$answer" || fail "nginx: prod with $unit stopped answered: $answer"
  grep -qF 'data-code="502"' <<<"$answer" || fail "nginx: prod's 502 is not the noix page: $answer"
  prod_answers pool-back

  echo "== nginx: nginx_error_pages false drops the error_page lines"
  converge nginx no-error-pages "$dir/converge.yml" "${fast[@]}" -e '{"nginx_error_pages": false}'
  answer="$(hx nginx sh -c 'grep -l "error_page\|noix-error" /etc/nginx/sites/*.conf || true')"
  [ -z "$answer" ] || fail "nginx: error pages off, these sites still have them: $answer"
  answer="$(ncurl https://prod.example.test/.env)"
  grep -q '^HTTP/1.1 404 ' <<<"$answer" || fail "nginx: error pages off, prod's /.env answered: $answer"
  if grep -qF 'data-code=' <<<"$answer"; then fail "nginx: error pages off, prod's 404 is still the noix page"; fi
  converge nginx error-pages-back "$dir/converge.yml" "${fast[@]}"
  answer="$(ncurl https://prod.example.test/.env)"
  grep -qF 'data-code="404"' <<<"$answer" || fail "nginx: error pages back on, prod's 404 is not the noix page: $answer"
}

# nsolve COMMAND URL [solve.py args]: the anubis suite's browser stand-in
# (tests/anubis/solve.py) in the nginx container, the URL's host on
# 127.0.0.1.
nsolve() {
  local command="$1" url="$2" host
  shift 2
  host="${url#*://}"
  host="${host%%/*}"
  docker exec -i "$prefix-nginx" python3 - "$command" "$url" --resolve "$host=127.0.0.1" "$@" <"$tests/anubis/solve.py"
}

# nexpect WANT URL [solve.py args]: the probe's "<status> <kind>" is WANT.
nexpect() {
  local want="$1" got
  shift
  got="$(nsolve probe "$@")"
  [ "$got" = "$want" ] || fail "nginx/anubis: probe $*: got '$got', expected '$want'"
}

# anubis_healthy: Anubis in the nginx container is healthy within 60 seconds.
anubis_healthy() {
  local tries=0
  until [ "$(hx nginx docker inspect -f '{{.State.Health.Status}}' noixdev-anubis 2>/dev/null || true)" = healthy ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || fail "nginx/anubis: Anubis is not healthy"
    sleep 1
  done
}

# nginx_anubis: prod behind Anubis (the anubis role in host mode), node not.
nginx_anubis() {
  local dir="$here/nginx" fast=(-e nginx_test_prepare=false) on=(-e nginx_test_prod_anubis=true)
  local front='"script":"index.php"' jar=/tmp/noixdev-anubis-jar.json acme=/var/lib/noixdev/acme/.well-known/acme-challenge
  local answer before after header
  echo "== nginx: anubis on a site without Anubis on the host is refused before any change"
  before="$(nginx_state)"
  refused nginx anubis-missing "nginx: nginx_sites entry prod sets anubis, but Anubis does not answer on http://127.0.0.1:8923/; run the anubis role with anubis_mode host (anubis_host_port 8923) first" \
    "$dir/converge.yml" "${fast[@]}" "${on[@]}"
  after="$(nginx_state)"
  [ "$after" = "$before" ] || fail "nginx/anubis: the refused run changed the host: $(diff <(echo "$before") <(echo "$after") || true)"

  echo "== nginx: Anubis in host mode listens on 127.0.0.1 only"
  play nginx "$dir/anubis.yml" >"$out/nginx-anubis-role.log" 2>&1 || { cat "$out/nginx-anubis-role.log" >&2; fail "nginx/anubis: the anubis role failed"; }
  anubis_healthy
  answer="$(hx nginx ss -ltnH 'sport = :8923' | awk '{ print $4 }' | sort -u | paste -sd' ' -)"
  [ "$answer" = "127.0.0.1:8923" ] || fail "nginx/anubis: 8923 listens on '$answer', not on 127.0.0.1 only"

  echo "== nginx: a browser on prod gets the challenge, and the front controller once solved; node is not checked"
  converge nginx anubis "$dir/converge.yml" "${fast[@]}" "${on[@]}"
  nexpect "401 challenge" "https://prod.example.test/page?x=1"
  nsolve solve "https://prod.example.test/page?x=1" --jar "$jar" --expect "$front"
  nexpect "200 backend" https://prod.example.test/other --jar "$jar" --expect "$front"
  nexpect "200 backend" https://node.example.test/app --expect 'node upstream'
  answer="$( (hx nginx grep -c auth_request /etc/nginx/sites/node.conf /etc/nginx/sites/static.conf || true) | tr '\n' ' ')"
  [ "$answer" = "/etc/nginx/sites/node.conf:0 /etc/nginx/sites/static.conf:0 " ] || fail "nginx/anubis: another site has auth_request: $answer"
  # Anubis checks the request's own path (test-api, anubis.yml) and its own
  # assets pass; its check path is nginx's internal one.
  nexpect "200 backend" https://prod.example.test/api/x --expect "$front"
  nexpect "200 other" https://prod.example.test/.within.website/x/xess/xess.min.css
  nexpect "404 backend" https://prod.example.test/.within.website/x/cmd/anubis/api/check --expect 'data-code="404"'

  echo "== nginx: client-sent X-Original-Uri, X-Real-Ip and X-Forwarded-For change nothing Anubis sees"
  for header in X-Original-Uri:/api/x X-Forwarded-Uri:/api/x X-Real-Ip:203.0.113.9 X-Forwarded-For:203.0.113.9; do
    nexpect "401 challenge" https://prod.example.test/secret --header "$header"
  done
  # The control: from 203.0.113.9 itself (test-forged-address), Anubis
  # lets it through: X-Real-Ip is nginx's $remote_addr.
  hx nginx ip addr replace 203.0.113.9/32 dev lo
  answer="$(nsolve probe https://prod.example.test/secret --source 203.0.113.9 --expect "$front")"
  hx nginx ip addr del 203.0.113.9/32 dev lo
  [ "$answer" = "200 backend" ] || fail "nginx/anubis: a request from 203.0.113.9 answered '$answer', not the front controller"

  echo "== nginx: the ACME challenge on prod is never checked"
  hx nginx sh -c "mkdir -p $acme && echo 'noixdev challenge' > $acme/noixdev-anubis"
  nexpect "200 backend" http://prod.example.test/.well-known/acme-challenge/noixdev-anubis --expect 'noixdev challenge'
  nexpect "200 backend" https://prod.example.test/.well-known/acme-challenge/noixdev-anubis --expect 'noixdev challenge'
  nexpect "404 backend" https://prod.example.test/.well-known/acme-challenge/missing --expect 'data-code="404"'
  hx nginx rm -f "$acme/noixdev-anubis"

  echo "== nginx: a stopped Anubis fails closed (the noix 500 page), and passes again once it runs"
  hx nginx docker stop noixdev-anubis >/dev/null
  answer="$(nsolve probe https://prod.example.test/other --jar "$jar" --expect 'data-code="500"')"
  hx nginx docker start noixdev-anubis >/dev/null
  anubis_healthy
  [ "$answer" = "500 backend" ] || fail "nginx/anubis: prod with Anubis stopped answered '$answer', not the noix 500 page"
  nexpect "200 backend" https://prod.example.test/other --jar "$jar" --expect "$front"

  echo "== nginx: anubis off again: no auth_request on prod"
  converge nginx anubis-off "$dir/converge.yml" "${fast[@]}"
  answer="$(hx nginx grep -c 'auth_request\|within.website' /etc/nginx/sites/prod.conf || true)"
  [ "$answer" = 0 ] || fail "nginx/anubis: prod.conf still names Anubis ($answer lines)"
  nexpect "200 backend" https://prod.example.test/page --expect "$front"
}

# nginx_together: a rate limit zone, and a map of nginx_http_extra, leave
# nginx.conf in the same run as the site config that stops using them: one
# run converges, as it does when they come in together.
nginx_together() {
  local dir="$here/nginx" fast=(-e nginx_test_prepare=false) answer
  local zones='{"nginx_rate_limit_zones": [{"name": "default", "rate": "10r/s", "burst": 20}, {"name": "strict", "rate": "1r/s", "burst": 5}]}'
  local map='{"nginx_http_extra": "map $host $noix_test_host {\n    default \"together\";\n}\n", "nginx_test_prod_extra": "add_header X-Noix-Test $noix_test_host always;"}'
  echo "== nginx: a zone and an http-level map come in with the sites that use them"
  converge nginx together "$dir/converge.yml" "${fast[@]}" -e "$zones" -e nginx_test_static_rate_limit=strict -e "$map"
  hx nginx grep -qx '    limit_req zone=strict burst=5 nodelay;' /etc/nginx/sites/static.conf || fail "nginx: static.conf lacks the zone strict"
  has_headers https://prod.example.test/ 'X-Noix-Test: together'

  echo "== nginx: a zone leaves in the same run as the site that stops using it"
  converge nginx together-no-zone "$dir/converge.yml" "${fast[@]}" -e "$map"
  hx nginx sh -c '! grep -q "zone=strict" /etc/nginx/nginx.conf /etc/nginx/sites/static.conf' || fail "nginx: the zone strict is still there"
  answer="$(ncurl https://static.example.test/)"
  grep -qxF 'static index' <<<"$answer" || fail "nginx: static does not answer after its zone went: $answer"

  echo "== nginx: an nginx_http_extra map leaves in the same run as the site that stops using it"
  converge nginx together-no-map "$dir/converge.yml" "${fast[@]}"
  hx nginx sh -c '! grep -q noix_test_host /etc/nginx/nginx.conf /etc/nginx/sites/prod.conf' || fail "nginx: the map is still there"
  has_headers https://prod.example.test/ -X-Noix-Test
  prod_answers together
}

suite_nginx() {
  local dir="$here/nginx" codename series version policy before after rc answer
  local fast=(-e nginx_test_prepare=false)
  # Docker runs inside (the error pages export and Anubis): its data on
  # volumes of the container's own, not on the overlay root.
  start nginx -v /var/lib/docker -v /var/lib/containerd
  codename="$(hx nginx sh -c '. /etc/os-release && echo "$VERSION_CODENAME"')"

  case "$ubuntu" in
    24.04 | 26.04) ;;
    *)
      echo "== nginx: Ubuntu $ubuntu is refused before any change"
      refused nginx release "nginx: Ubuntu $ubuntu is not supported yet: nginx.org has no packages for $codename" \
        "$dir/converge.yml" "${fast[@]}"
      hx nginx sh -c 'test ! -e /etc/apt/sources.list.d/nginx.sources && test ! -e /etc/apt/keyrings/nginx.asc' \
        || fail "nginx: the refused run left repository files"
      return 0 ;;
  esac

  nginx_distro_refused
  nginx_no_docker

  echo "== nginx: Docker, for the error pages and Anubis"
  play nginx "$dir/docker.yml" >"$out/nginx-docker.log" 2>&1 || { cat "$out/nginx-docker.log" >&2; fail "nginx: Docker did not install"; }
  nginx_images

  echo "== nginx: Pebble, the ACME server prod's certificate comes from"
  play nginx "$dir/pebble.yml" >"$out/nginx-pebble.log" 2>&1 || { cat "$out/nginx-pebble.log" >&2; fail "nginx: Pebble did not start"; }

  echo "== nginx: a run whose repository refresh failed is not followed by Ubuntu's nginx"
  # The first run adds the source and the pin, then its refresh fails: the
  # package lists stay without nginx.org's packages. The key comes from the
  # same host as the packages, so apt alone is cut off.
  hx nginx sh -c 'echo "Acquire::https::Proxy::nginx.org \"http://127.0.0.1:9\";" > /etc/apt/apt.conf.d/99-block-nginx'
  if play nginx "$dir/converge.yml" >"$out/nginx-blocked.log" 2>&1; then
    fail "nginx: the run with nginx.org unreachable did not fail"
  fi
  hx nginx rm -f /etc/apt/apt.conf.d/99-block-nginx
  hx nginx test -e /etc/apt/sources.list.d/nginx.sources || { cat "$out/nginx-blocked.log" >&2; fail "nginx: the blocked run did not add the source"; }
  hx nginx sh -c '! dpkg-query -W -f "\${db:Status-Abbrev}\n" nginx nginx-common 2>/dev/null | grep -q "^.i"' \
    || fail "nginx: the blocked run installed nginx"
  policy="$(hx nginx apt-cache policy nginx)"
  grep -qF 'Candidate: (none)' <<<"$policy" || fail "nginx: without nginx.org's lists Ubuntu's nginx is a candidate: $policy"

  echo "== nginx: converge (on the stale lists) and idempotence"
  converge nginx install "$dir/converge.yml"
  series="$(sed -n 's/^nginx_version: "\(.*\)"$/\1/p' "$root/roles/nginx/defaults/main.yml")"
  [ -n "$series" ] || fail "nginx: no nginx_version in the role's defaults"
  version="$(hx nginx dpkg-query -W -f='${Version}' nginx)"
  case "$version" in
    "$series".*"~$codename") echo "   installed nginx.org's $version" ;;
    *) fail "nginx: the role installed nginx $version, not nginx.org's $series for $codename" ;;
  esac
  answer="$(hx nginx nginx -v 2>&1)"
  grep -qF "nginx/$series." <<<"$answer" || fail "nginx: nginx -v does not show the series $series: $answer"
  # nginx.org's versions of the series win; every other one (Ubuntu's and
  # nginx.org's other series) is never installed.
  policy="$(hx nginx apt-cache policy nginx)"
  awk -v series="$series" -v codename="$codename" '$NF ~ /^-?[0-9]+$/ && NF <= 3 { v = $(NF-1); p = $NF
         ours = index(v, series ".") == 1 && v ~ ("~" codename "$")
         if ((ours && p != 990) || (!ours && p != -1)) { print v, p; bad = 1 } }
       END { exit bad }' <<<"$policy" || fail "nginx: the pin gives the wrong priorities: $policy"
  play nginx "$dir/verify.yml"
  # OCSP stapling (a {cert, key} site) resolves its responder at run time;
  # a Let's Encrypt site has no stapling.
  answer="$(hx nginx grep -c '^    resolver 127.0.0.53 valid=300s;$' /etc/nginx/sites/node.conf)"
  [ "$answer" = 1 ] || fail "nginx: node's TLS server does not have the resolver ($answer)"
  answer="$(hx nginx grep -c 'resolver' /etc/nginx/sites/prod.conf || true)"
  [ "$answer" = 0 ] || fail "nginx: prod (Let's Encrypt) has a resolver ($answer)"
  nginx_links
  nginx_acme
  nginx_auth
  nginx_error_pages
  nginx_anubis

  echo "== nginx: hardening false on static: no security headers, /.env is served"
  converge nginx no-hardening "$dir/converge.yml" "${fast[@]}" -e '{"nginx_test_static_hardening": false}'
  has_headers https://static.example.test/ -X-Content-Type-Options -Referrer-Policy -X-Frame-Options -Strict-Transport-Security
  answer="$(ncurl https://static.example.test/.env)"
  grep -qxF 'STATIC_ENV=visible' <<<"$answer" || fail "nginx: static does not serve /.env without hardening: $answer"
  has_headers https://prod.example.test/ 'X-Frame-Options: SAMEORIGIN' 'Strict-Transport-Security: max-age=31536000'

  echo "== nginx: hsts false on static drops HSTS only"
  converge nginx no-hsts "$dir/converge.yml" "${fast[@]}" -e '{"nginx_test_static_hsts": false}'
  has_headers https://static.example.test/ -Strict-Transport-Security 'X-Content-Type-Options: nosniff' \
    'Referrer-Policy: strict-origin-when-cross-origin' 'X-Frame-Options: SAMEORIGIN'
  answer="$(ncurl https://static.example.test/.env)"
  [ "$(sed -n '1s/\r$//p' <<<"$answer")" = 'HTTP/1.1 404 Not Found' ] || fail "nginx: static serves /.env with hardening on: $answer"

  echo "== nginx: an empty header value on static drops that header only"
  converge nginx no-frame-options "$dir/converge.yml" "${fast[@]}" -e '{"nginx_test_static_headers": {"X-Frame-Options": ""}}'
  has_headers https://static.example.test/ -X-Frame-Options 'X-Content-Type-Options: nosniff' \
    'Referrer-Policy: strict-origin-when-cross-origin' 'Strict-Transport-Security: max-age=31536000'

  echo "== nginx: back to the defaults"
  converge nginx defaults "$dir/converge.yml" "${fast[@]}"
  play nginx "$dir/verify.yml"

  nginx_together

  # The run changes nginx.conf too (a comment in nginx_http_extra): the
  # global config and the sites are tested together, and put back together.
  echo "== nginx: a site config nginx rejects fails naming nginx's error, the previous one stays, nginx.conf too"
  before="$(hx nginx md5sum /etc/nginx/sites/prod.conf /etc/nginx/nginx.conf)"
  if play nginx "$dir/converge.yml" "${fast[@]}" -e '{"nginx_test_prod_extra": "this is not nginx;", "nginx_http_extra": "# noixdev rollback test\n"}' \
      >"$out/nginx-rollback.log" 2>&1; then
    fail "nginx: the run with a broken extra did not fail"
  fi
  grep -qF 'unknown directive "this" in /etc/nginx/sites/prod.conf' "$out/nginx-rollback.log" \
    || { cat "$out/nginx-rollback.log" >&2; fail "nginx: the failure does not name nginx's error"; }
  [ "$(hx nginx md5sum /etc/nginx/sites/prod.conf /etc/nginx/nginx.conf)" = "$before" ] || fail "nginx: prod.conf or nginx.conf changed after the rejected run"
  [ "$(hx nginx sh -c 'ls -A /etc/nginx/sites' | paste -sd' ' -)" = "node.conf prod.conf static.conf" ] \
    || fail "nginx: the rejected run left files in /etc/nginx/sites: $(hx nginx ls -A /etc/nginx/sites)"
  prod_answers rollback
  play nginx "$dir/converge.yml" "${fast[@]}" >"$out/nginx-after-rollback.log" 2>&1 || { cat "$out/nginx-after-rollback.log" >&2; fail "nginx: the run after the rollback failed"; }
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/nginx-after-rollback.log" \
    || { cat "$out/nginx-after-rollback.log" >&2; fail "nginx: the run after the rollback changed something"; }

  echo "== nginx: on a config broken before the run, the run fails and nginx does not reload"
  hx nginx sh -c 'echo "this is broken;" > /etc/nginx/conf.d/zz-broken.conf'
  before="$(hx nginx md5sum /etc/nginx/sites/static.conf)"
  if play nginx "$dir/converge.yml" "${fast[@]}" -e '{"nginx_test_static_hsts": false}' >"$out/nginx-broken-before.log" 2>&1; then
    fail "nginx: the run on a broken config did not fail"
  fi
  grep -qF "nginx -t fails on them too: the config was broken before this run, so nginx was not reloaded" "$out/nginx-broken-before.log" \
    || { cat "$out/nginx-broken-before.log" >&2; fail "nginx: the failure does not say the config was broken before"; }
  grep -qF 'unknown directive "this" in /etc/nginx/conf.d/zz-broken.conf' "$out/nginx-broken-before.log" \
    || fail "nginx: the failure does not name nginx's error"
  # Every flush of the reload handler skipped it.
  awk '/^RUNNING HANDLER \[noixdev.infra.nginx : Reload nginx\]/ { h = 1; n++; next }
       h && NF { if ($1 != "skipping:") bad = 1; h = 0 }
       END { exit (n == 0 || bad) }' "$out/nginx-broken-before.log" \
    || { cat "$out/nginx-broken-before.log" >&2; fail "nginx: the run reloaded nginx on a broken config"; }
  [ "$(hx nginx md5sum /etc/nginx/sites/static.conf)" = "$before" ] || fail "nginx: static.conf changed after the failed run"
  hx nginx rm /etc/nginx/conf.d/zz-broken.conf
  prod_answers broken-before
  has_headers https://static.example.test/ 'Strict-Transport-Security: max-age=31536000'

  echo "== nginx: a change of static's group alone reaches the workers"
  hx nginx groupadd static_readers
  hx nginx chgrp -R static_readers /srv/static
  answer="$(ncurl https://static.example.test/)"
  grep -qE '^HTTP/1.1 (403|404) ' <<<"$answer" || fail "nginx: static answers without www-data in static_readers: $answer"
  converge nginx static-group "$dir/converge.yml" "${fast[@]}" -e '{"nginx_test_static_group": "static_readers"}'
  answer="$(ncurl https://static.example.test/)"
  grep -qxF 'static index' <<<"$answer" || fail "nginx: static does not answer after its group changed: $answer"
  answer=" $(hx nginx id -nG www-data) "
  case "$answer" in *" app_static "*) fail "nginx: www-data is still in app_static's group:$answer" ;; esac
  case "$answer" in *" static_readers "*) ;; *) fail "nginx: www-data did not join static_readers:$answer" ;; esac

  echo "== nginx: a site that leaves the list hits the default server, its root stays"
  converge nginx no-static "$dir/converge.yml" "${fast[@]}" -e '{"nginx_test_static": false}'
  rc="$(ncurl_rc https://static.example.test/)"
  [ "$rc" = 35 ] || fail "nginx: static's name on 443 did not get the handshake rejected (curl exit $rc)"
  rc="$(ncurl_rc http://static.example.test/)"
  [ "$rc" = 52 ] || fail "nginx: static's name on 80 did not get an empty reply (curl exit $rc)"
  hx nginx test ! -e /etc/nginx/sites/static.conf || fail "nginx: static.conf is still there"
  hx nginx test -s /srv/static/index.html || fail "nginx: static's root is gone"
  answer=" $(hx nginx id -nG www-data) "
  case "$answer" in *" app_static "* | *" static_readers "*) fail "nginx: www-data is still in static's group:$answer" ;; esac
  case "$answer" in *" app_prod "*) ;; *) fail "nginx: www-data left app_prod's group:$answer" ;; esac
  prod_answers removal
  hx nginx chgrp -R app_static /srv/static
  nginx_failed_join

  echo "== nginx: invalid sites are refused before any change"
  local tls_off='"user": "app_prod", "root": "/srv/prod/public", "tls": "off"'
  before="$(nginx_state)"
  refused nginx duplicate-domain "nginx: nginx_sites entry b lists the domain dup.example.test, which entry a lists too; a domain belongs to one site" \
    "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_sites\": [{\"name\": \"a\", \"domains\": [\"dup.example.test\"], $tls_off},
      {\"name\": \"b\", \"domains\": [\"b.example.test\"], \"redirect_domains\": [\"dup.example.test\"], $tls_off}]}"
  refused nginx both-backends "nginx: nginx_sites entry both has php_pool and proxy; a site has one backend at most" \
    "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_sites\": [{\"name\": \"both\", \"domains\": [\"both.example.test\"], $tls_off,
      \"php_pool\": \"production\", \"proxy\": \"http://127.0.0.1:3000\"}]}"
  refused nginx php-without-root "nginx: nginx_sites entry noroot has php_pool production but no root" \
    "$dir/converge.yml" "${fast[@]}" -e '{"nginx_sites": [{"name": "noroot", "domains": ["noroot.example.test"], "user": "app_prod", "tls": "off", "php_pool": "production"}]}'
  refused nginx unknown-user "nginx: nginx_sites entry x has the user nosuchuser, which does not exist; the role does not create users" \
    "$dir/converge.yml" "${fast[@]}" -e '{"nginx_sites": [{"name": "x", "domains": ["x.example.test"], "user": "nosuchuser", "root": "/srv/x", "tls": "off"}]}'
  refused nginx root-user "nginx: nginx_sites entry x has the user root; a site belongs to an unprivileged user" \
    "$dir/converge.yml" "${fast[@]}" -e '{"nginx_sites": [{"name": "x", "domains": ["x.example.test"], "user": "root", "root": "/srv/x", "tls": "off"}]}'
  refused nginx root-group "nginx: nginx_sites entry x has the group root (gid 0); www-data joins a site's group, which must not be root" \
    "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_sites\": [{\"name\": \"x\", \"domains\": [\"x.example.test\"], $tls_off, \"group\": \"root\"}]}"
  refused nginx www-data-user "nginx: nginx_sites entry x has the user www-data; the nginx workers run as www-data and read every site, so a site belongs to another user" \
    "$dir/converge.yml" "${fast[@]}" -e '{"nginx_sites": [{"name": "x", "domains": ["x.example.test"], "user": "www-data", "root": "/srv/x", "tls": "off"}]}'
  refused nginx www-data-group "nginx: nginx_sites entry x has the group www-data; www-data joins a site's group, which must not be www-data or a privileged group (" \
    "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_sites\": [{\"name\": \"x\", \"domains\": [\"x.example.test\"], $tls_off, \"group\": \"www-data\"}]}"
  # docker.yml installed Docker, so the group docker exists.
  refused nginx docker-group "nginx: nginx_sites entry x has the group docker; www-data joins a site's group, which must not be www-data or a privileged group (" \
    "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_sites\": [{\"name\": \"x\", \"domains\": [\"x.example.test\"], $tls_off, \"group\": \"docker\"}]}"
  refused nginx bad-name "nginx: nginx_sites entry 'Bad Name' has an invalid name; it must match ^[a-z0-9_-]+$" \
    "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_sites\": [{\"name\": \"Bad Name\", \"domains\": [\"x.example.test\"], $tls_off}]}"
  refused nginx no-acme-email "nginx: nginx_sites entry le uses tls letsencrypt, and nginx_acme_email is empty" \
    "$dir/converge.yml" "${fast[@]}" -e '{"nginx_acme_email": ""}' -e '{"nginx_sites": [{"name": "le", "domains": ["le.example.test"], "user": "app_prod", "root": "/srv/prod/public", "tls": "letsencrypt"}]}'
  refused nginx unknown-zone "nginx: nginx_sites entry rl has rate_limit nosuchzone, which nginx_rate_limit_zones does not define (default)" \
    "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_sites\": [{\"name\": \"rl\", \"domains\": [\"rl.example.test\"], $tls_off, \"rate_limit\": \"nosuchzone\"}]}"
  refused nginx unknown-key "nginx: nginx_sites entry x has unknown keys (priv); its keys are" \
    "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_sites\": [{\"name\": \"x\", \"domains\": [\"x.example.test\"], $tls_off, \"priv\": true}]}"
  refused nginx root-over-error-pages "nginx: nginx_sites entry x has the root /var/www, which overlaps nginx_error_pages_dir /var/www/noix-error-pages; the error pages are root's" \
    "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_sites\": [{\"name\": \"x\", \"domains\": [\"x.example.test\"], \"user\": \"app_prod\", \"root\": \"/var/www\", \"tls\": \"off\"}]}"
  # Deploy snippets are not supported yet (defaults false).
  refused nginx user-includes "nginx: nginx_user_includes is true; deploy snippets are not supported yet by this version of the role" \
    "$dir/converge.yml" "${fast[@]}" -e '{"nginx_user_includes": true}'
  refused nginx include-user "nginx: nginx_include_user is set; deploy snippets are not supported yet by this version of the role" \
    "$dir/converge.yml" "${fast[@]}" -e nginx_include_user=app_prod
  refused nginx site-user-includes "nginx: nginx_sites entry x sets user_includes; deploy snippets are not supported yet by this version of the role" \
    "$dir/converge.yml" "${fast[@]}" -e "{\"nginx_sites\": [{\"name\": \"x\", \"domains\": [\"x.example.test\"], $tls_off, \"user_includes\": true}]}"
  version="$(hx nginx dpkg-query -W -f='${Version}' nginx)"
  refused nginx other-series "nginx: installed nginx $version is series $series, nginx_version is 1.26; a series change is a separate, deliberate step" \
    "$dir/converge.yml" "${fast[@]}" -e nginx_version=1.26
  after="$(nginx_state)"
  [ "$after" = "$before" ] || fail "nginx: a refused run changed the host: $(diff <(echo "$before") <(echo "$after") || true)"
  [ "$(hx nginx dpkg-query -W -f='${Version}' nginx)" = "$version" ] || fail "nginx: nginx changed after a refused run"
  prod_answers refusals
}


docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null

for role in $services; do
  declare -F "suite_$role" >/dev/null || fail "no suite for the role $role"
  "suite_$role"
done
echo "== services ($services) passed on ubuntu $ubuntu"
if [ "$shim_used" = 1 ]; then
  echo "noix-attest-note: mysql via systemctl shim"
  echo "== WARNING: emulated amd64: mysql.service not exercised, systemctl shim in use"
fi
noix_done
