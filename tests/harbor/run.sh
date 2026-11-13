#!/usr/bin/env bash
# End-to-end test of the harbor role inside a throwaway Docker-in-Docker host:
# Traefik plus Harbor, converge twice (the second run must change nothing),
# then log in and push an image through Traefik.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$(dirname "$here")")"
host="${NOIXDEV_INFRA_HARBOR_TEST_HOST:-noixdev-infra-harbor-test}"
out="$root/tests/output"

cleanup() { [ "${KEEP:-0}" = 1 ] || docker rm -f -v "$host" >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p "$out/ansible_collections/noixdev"
ln -sfn "$root" "$out/ansible_collections/noixdev/infra"
export ANSIBLE_COLLECTIONS_PATH="$out:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"
export ANSIBLE_HOST_KEY_CHECKING=False

docker rm -f -v "$host" >/dev/null 2>&1 || true
# Traefik serves Harbor on plain HTTP at harbor.test (127.0.0.1:80 inside).
docker run -d --privileged --name "$host" --add-host harbor.test:127.0.0.1 \
  docker:29-dind --insecure-registry harbor.test >/dev/null
until docker exec "$host" docker info >/dev/null 2>&1; do sleep 1; done
# GNU tar for the unarchive module, bash for the installer's prepare script.
docker exec "$host" apk add --no-cache python3 tar bash >/dev/null

echo "== the test host runs linux/amd64 images"
# Harbor v2.14.6 has amd64 images only. Without emulation they fail later in
# prepare with "exec format error"; say so now and how to fix it.
arch="$(docker exec "$host" docker run --rm --platform linux/amd64 alpine:3 uname -m 2>&1 | tail -n 1)" || true
if [ "$arch" != x86_64 ]; then
  echo "the test host cannot run linux/amd64 images (got: $arch)." >&2
  echo "Docker Desktop on Apple silicon: install Rosetta 2 (softwareupdate --install-rosetta)," >&2
  echo "turn on its Rosetta emulation in Settings > General and restart Docker Desktop." >&2
  echo "Linux: register QEMU for amd64 (docker run --privileged --rm tonistiigi/binfmt --install amd64)." >&2
  exit 1
fi

play() { ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$@"; }

echo "== converge"
play "$here/converge.yml"

echo "== idempotence"
play "$here/converge.yml" | tee "$out/harbor-idempotence.log"
grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/harbor-idempotence.log" \
  || { echo "second converge changed something" >&2; exit 1; }

echo "== verify"
play "$here/verify.yml"

echo "== invalid harbor settings must fail"
if play "$here/converge.yml" -e harbor_dir=/opt/harbor-invalid -e harbor_admin_password=short \
  >"$out/harbor-invalid.log" 2>&1; then
  echo "harbor accepted an admin password shorter than 8 characters" >&2
  exit 1
fi
grep -q "harbor_admin_password of at least 8 characters" "$out/harbor-invalid.log" \
  || { cat "$out/harbor-invalid.log" >&2; exit 1; }
docker exec "$host" test ! -e /opt/harbor-invalid \
  || { echo "harbor touched the host before checking its settings" >&2; exit 1; }

hx() { docker exec "$host" "$@"; }
fail() { echo "$*" >&2; exit 1; }
# A converge that must fail; its output goes to $out/harbor-<name>.log.
play_fails() {
  local name="$1"
  shift
  if play "$@" >"$out/harbor-$name.log" 2>&1; then
    fail "converge $name succeeded but must fail"
  fi
}
expect_in_log() {
  grep -qF -- "$2" "$out/harbor-$1.log" || { cat "$out/harbor-$1.log" >&2; fail "harbor-$1.log lacks: $2"; }
}
expect_unchanged() {
  grep -Eq 'changed=0 ' "$out/harbor-$1.log" || { cat "$out/harbor-$1.log" >&2; fail "converge $1 changed something"; }
}
expect_idempotent() {
  play "$here/converge.yml" "$@" | tee "$out/harbor-rerun.log"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/harbor-rerun.log" || fail "a repeated converge changed something"
}
expect_installed() { [ "$(hx cat /opt/harbor/installed-version)" = "$1" ] || fail "installed-version is not $1"; }
no_harbor_running() { [ -z "$(hx docker ps -q --filter label=com.docker.compose.project=harbor)" ]; }
latest=/opt/harbor/backups/latest

echo "== harbor-backup writes latest"
hx /usr/local/sbin/harbor-backup
hx sh -c "test -s $latest/registry.dump && test -d $latest/secret/keys \
  && test \"\$(stat -c %a $latest)\" = 700 && test \"\$(stat -c %a $latest/registry.dump)\" = 600 \
  && test \"\$(stat -c %a $latest/harbor.yml)\" = 600 && test \"\$(cat $latest/version)\" = v2.14.6 \
  && test \"\$(stat -c %a $latest/secret $latest/secret/keys $latest/secret/keys/secretkey | tr '\n' ' ')\" = '700 700 600 ' \
  && grep -qx '755 ./keys' $latest/secret.modes" \
  || fail "the latest backup is incomplete or has wrong modes"
[ "$(hx stat -c %a /usr/local/sbin/harbor-backup /usr/local/sbin/harbor-restore)" = "$(printf '750\n750')" ] \
  || fail "the backup scripts are not mode 0750"

echo "== harbor-backup without the database must fail"
before="$(hx stat -c '%i %Y' "$latest")"
hx docker stop harbor-db >/dev/null
if hx /usr/local/sbin/harbor-backup >"$out/harbor-backup-nodb.log" 2>&1; then
  fail "harbor-backup succeeded without harbor-db"
fi
grep -q "harbor-db is not running" "$out/harbor-backup-nodb.log" || fail "$(cat "$out/harbor-backup-nodb.log")"
[ "$(hx stat -c '%i %Y' "$latest")" = "$before" ] || fail "a failed harbor-backup changed latest"
hx docker start harbor-db >/dev/null

echo "== a downgrade must be refused"
play_fails downgrade "$here/converge.yml" -e harbor_version=v2.14.5
expect_in_log downgrade "refuses to downgrade"
expect_unchanged downgrade
expect_installed v2.14.6

echo "== a database without installed-version must be refused"
hx sh -c 'mkdir -p /opt/harbor-orphan/data/database/pg15 && echo 15 >/opt/harbor-orphan/data/database/pg15/PG_VERSION'
play_fails orphan "$here/converge.yml" -e harbor_dir=/opt/harbor-orphan
expect_in_log orphan "installed-version is missing"
expect_unchanged orphan
hx test ! -e /opt/harbor-orphan/installer || fail "harbor touched the orphan directory"

echo "== a platform without Harbor images must be refused"
# Harbor v2.14.6 has amd64 images only; the containers would run as arm64.
# Only the harbor role (ad hoc), so the traefik role does not see the platform.
if ansible all -i "$here/inventory.yml" -e "test_host=$host" -e "@$here/vars.yml" \
  -e harbor_dir=/opt/harbor-arch -e '{"ansible_docker_extra_env": {"DOCKER_DEFAULT_PLATFORM": "linux/arm64"}}' \
  -m ansible.builtin.include_role -a name=noixdev.infra.harbor >"$out/harbor-arch.log" 2>&1; then
  fail "harbor accepted arm64 containers for v2.14.6"
fi
expect_in_log arch "publishes amd64 images only"
hx test ! -e /opt/harbor-arch || fail "harbor touched the host before checking the platform"

echo "== upgrade to v2.15.4"
# Older pre-upgrade backups: with the new one, the oldest must be pruned (keep 3).
for i in 0 1 2; do hx mkdir -p "/opt/harbor/backups/20200101T00000${i}Z-v2.14.0"; done
play "$here/converge.yml" -e harbor_version=v2.15.4
expect_idempotent -e harbor_version=v2.15.4
play "$here/verify.yml" -e harbor_version=v2.15.4 -e verify_push=false
pre_upgrade="$(hx sh -c 'ls -d /opt/harbor/backups/*-v2.14.6')"
[ "$(hx cat "$pre_upgrade/version")" = v2.14.6 ] || fail "no pre-upgrade backup of v2.14.6"
hx test -s "$pre_upgrade/registry.dump" || fail "the pre-upgrade dump is empty"
hx test ! -e /opt/harbor/upgrade-failed || fail "the upgrade left its marker"
[ "$(hx sh -c 'cd /opt/harbor/backups && ls -d 2*' | tr '\n' ' ')" \
  = "20200101T000001Z-v2.14.0 20200101T000002Z-v2.14.0 $(basename "$pre_upgrade") " ] \
  || fail "the upgrade did not keep exactly the newest 3 backups: $(hx ls /opt/harbor/backups)"
hx test -d "$latest" || fail "the upgrade pruned latest"
hx test -d /opt/harbor/data/database/pg18 || fail "the upgrade did not move PostgreSQL to 18"

echo "== a failed download must leave Harbor running"
play_fails fetch-failed "$here/converge.yml" -e harbor_version=v2.15.99 \
  -e harbor_installer_url=http://127.0.0.1/missing/harbor-online-installer-v2.15.99.tgz
hx test ! -e /opt/harbor/upgrade-failed || fail "a failed download wrote the upgrade marker"
expect_installed v2.15.4
play "$here/verify.yml" -e harbor_version=v2.15.4 -e verify_push=false

echo "== a failed upgrade must stop Harbor and keep its marker"
# An installer of v2.15.99 whose prepare fails: a failure after the backup.
hx sh -c 'mkdir -p /opt/harbor/installer/v2.15.99 \
  && cp /opt/harbor/installer/v2.15.4/harbor.yml.tmpl /opt/harbor/installer/v2.15.99/ \
  && printf "#!/bin/sh\necho simulated prepare failure >&2\nexit 1\n" >/opt/harbor/installer/v2.15.99/prepare \
  && chmod 0755 /opt/harbor/installer/v2.15.99/prepare'
play_fails upgrade-failed "$here/converge.yml" -e harbor_version=v2.15.99
hx test -e /opt/harbor/upgrade-failed || fail "the failed upgrade left no marker"
failed_backup="$(hx sed -n 's/^backup: *//p' /opt/harbor/upgrade-failed)"
[ -n "$failed_backup" ] || fail "the marker names no backup"
hx sh -c 'grep -qx "from: v2.15.4" /opt/harbor/upgrade-failed && grep -qx "to: v2.15.99" /opt/harbor/upgrade-failed \
  && grep -qx "backup_complete: true" /opt/harbor/upgrade-failed && grep -q "^time: " /opt/harbor/upgrade-failed' \
  || fail "the marker lacks from, to, backup_complete or time"
expect_in_log upgrade-failed "$failed_backup"
expect_in_log upgrade-failed "harbor-restore"
no_harbor_running || fail "Harbor still runs after the failed upgrade"
expect_installed v2.15.4

echo "== a run with the marker must fail at once"
play_fails marker "$here/converge.yml" -e harbor_version=v2.15.4
expect_in_log marker "upgrade-failed"
expect_in_log marker "from: v2.15.4; to: v2.15.99; backup: $failed_backup"
expect_unchanged marker
no_harbor_running || fail "a run with the marker started Harbor"
# A marker whose backup never completed must not point to a restore.
hx sh -c 'cp -p /opt/harbor/upgrade-failed /opt/harbor/upgrade-failed.saved \
  && sed -i "s/^backup_complete: true$/backup_complete: false/" /opt/harbor/upgrade-failed'
play_fails marker-nobackup "$here/converge.yml" -e harbor_version=v2.15.4
expect_in_log marker-nobackup "nothing to restore"
expect_in_log marker-nobackup "Remove the marker first"
expect_unchanged marker-nobackup
if grep -q "Restore the backup it names" "$out/harbor-marker-nobackup.log"; then
  fail "the marker refusal offers a restore without a backup"
fi
hx mv /opt/harbor/upgrade-failed.saved /opt/harbor/upgrade-failed

echo "== harbor-backup without a directory must refuse while the marker exists"
before="$(hx stat -c '%i %Y' "$latest")"
if hx /usr/local/sbin/harbor-backup >"$out/harbor-backup-marker.log" 2>&1; then
  fail "harbor-backup wrote latest while the upgrade marker exists"
fi
expect_in_log backup-marker "upgrade-failed exists"
[ "$(hx stat -c '%i %Y' "$latest")" = "$before" ] || fail "a refused harbor-backup changed latest"

echo "== harbor-restore"
# A stale cluster as a failed upgrade's new database leaves it; restore moves it away.
hx sh -c 'mkdir -p /opt/harbor/data/database/pg99 && echo 99 >/opt/harbor/data/database/pg99/PG_VERSION'
hx /usr/local/sbin/harbor-restore "$failed_backup"
hx test ! -e /opt/harbor/upgrade-failed || fail "harbor-restore left the marker"
hx test ! -e /opt/harbor/data/database/pg99 || fail "harbor-restore left the stale cluster"
[ "$(hx stat -c %a /opt/harbor/data/secret/keys)" = 755 ] || fail "harbor-restore did not restore the secret modes"
play "$here/verify.yml" -e harbor_version=v2.15.4 -e verify_push=false
expect_idempotent -e harbor_version=v2.15.4

echo "== harbor-restore of the v2.14.6 backup after the PostgreSQL 15 to 18 upgrade"
# As after an upgrade that failed once the new database had run: the owner
# records the old version and restores the pre-upgrade backup.
hx test ! -e /opt/harbor/data/database/pg15 || fail "pg15 still exists after the upgrade"
hx sh -c 'echo v2.14.6 >/opt/harbor/installed-version'
hx /usr/local/sbin/harbor-restore "$pre_upgrade" | tee "$out/harbor-restore-pg.log"
grep -q "moved the unused cluster pg18" "$out/harbor-restore-pg.log" || fail "harbor-restore did not move pg18 away"
hx test -d /opt/harbor/data/database/pg15 || fail "harbor-restore did not run on a pg15 cluster"
hx test ! -e /opt/harbor/data/database/pg18 || fail "harbor-restore left pg18 in place"
# v2.15's Redis writes a format v2.14's cannot load.
grep -q "moved Harbor's Redis data" "$out/harbor-restore-pg.log" || fail "harbor-restore kept the Redis data"
play "$here/verify.yml" -e harbor_version=v2.14.6 -e verify_push=false
expect_idempotent -e harbor_version=v2.14.6

echo "== all harbor tests passed"
