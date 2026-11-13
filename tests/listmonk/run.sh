#!/usr/bin/env bash
# End-to-end test of the listmonk role on throwaway Docker-in-Docker hosts
# (a fresh one per scenario): a fresh install; a run without changes on a
# stopped listmonk and on a database that is still starting; takeovers of
# installations laid out like the role's defaults by an earlier role
# (old-compose.yml, with a pinned and with a `latest` image); a failed
# reconfigure that restores the installation; a restore onto a schema a newer
# listmonk migrated; the refusals before any change (missing password, other
# layout, unknown database password); updates from an older release (fresh,
# and of an old-role installation whose password changes on the way), a
# refused downgrade, a failed pull, a failed dump, a failed update that rolls
# back (and the marker that then blocks it), a rollback that fails too, and
# updates postponed while a campaign is sending. Every successful converge is
# repeated and must change nothing.
# The single-quoted scripts expand inside the container, not here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
host="${NOIXDEV_INFRA_LISTMONK_TEST_HOST:-noixdev-infra-listmonk-test}"
out="$tests/output/listmonk"
dir=/opt/listmonk/listmonk-app
defaults="$root/roles/listmonk/defaults/main.yml"
version="$(sed -n 's/^listmonk_version: *//p' "$defaults" 2>/dev/null)" || true
postgres="$(sed -n 's/^listmonk_postgres_image: *//p' "$defaults" 2>/dev/null)" || true
# The release updates start from: the last one of the previous minor (it
# serves /health as the default does). Must stay lower than the default.
older=v6.1.0

cleanup() { [ "${KEEP:-0}" = 1 ] || docker rm -f -v "$host" >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
ln -sfn "$root" "$tests/output/ansible_collections/noixdev/infra"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"
export ANSIBLE_HOST_KEY_CHECKING=False

fail() { echo "$*" >&2; exit 1; }
hx() { docker exec "$host" "$@"; }
hxi() { docker exec -i "$host" "$@"; }
play() { ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$@"; }
# A converge that must fail; its output goes to $out/<name>.log.
play_fails() {
  local name="$1"
  shift
  if play "$@" >"$out/$name.log" 2>&1; then
    fail "converge $name succeeded but must fail"
  fi
}
expect_in_log() {
  grep -qF -- "$2" "$out/$1.log" || { cat "$out/$1.log" >&2; fail "$1.log lacks: $2"; }
}
expect_idempotent() {
  play "$here/converge.yml" | tee "$out/rerun.log"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/rerun.log" || fail "a repeated converge changed something"
}
verify() { play "$here/verify.yml" -e "verify_version=$version"; }

# A fresh Docker-in-Docker host.
new_host() {
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  docker run -d --privileged --name "$host" docker:29-dind >/dev/null
  until hx docker info >/dev/null 2>&1; do sleep 1; done
  # Retried: the host's first DNS lookups fail now and then.
  for _ in 1 2 3; do hx apk add --no-cache python3 curl >/dev/null && return 0; sleep 3; done
  fail "cannot install python3 and curl on the test host"
}
# Loads the role's default images and the older listmonk into the host,
# pulled once per version.
load_images() {
  [ -n "$version" ] && [ -n "$postgres" ] || fail "no listmonk_version or listmonk_postgres_image in $defaults"
  local images="$out/images-$version-$older.tar"
  if [ ! -s "$images" ]; then
    docker pull -q "$postgres" >/dev/null
    docker pull -q "listmonk/listmonk:$version" >/dev/null
    docker pull -q "listmonk/listmonk:$older" >/dev/null
    docker save -o "$images" "$postgres" "listmonk/listmonk:$version" "listmonk/listmonk:$older"
  fi
  hxi docker load <"$images" >/dev/null
}
# A release that never answers: the default image, sleeping instead of serving.
build_broken() {
  hxi docker build -q -t listmonk/listmonk:v99.0.0 - >/dev/null <<EOF
FROM listmonk/listmonk:$version
ENTRYPOINT ["sh", "-c", "exec sleep infinity", "sleep"]
EOF
}
# A release that never answers and whose --upgrade closes the postgres
# database to new connections, so the role's restore cannot recreate the
# listmonk database: the rollback fails too.
build_unrestorable() {
  hxi docker build -q -t listmonk/listmonk:v98.0.0 - >/dev/null <<EOF
FROM $postgres
RUN mkdir /listmonk && printf '%s\\n' \\
  '#!/bin/sh' \\
  'if [ "\$1" = --upgrade ]; then' \\
  '  PGPASSWORD="\$LISTMONK_db__password" exec psql -h "\$LISTMONK_db__host" -U "\$LISTMONK_db__user" -d "\$LISTMONK_db__database" -c "ALTER DATABASE postgres ALLOW_CONNECTIONS false"' \\
  'fi' \\
  'exec sleep infinity' >/listmonk/listmonk && chmod 0755 /listmonk/listmonk
WORKDIR /listmonk
ENTRYPOINT []
EOF
}
# Waits until listmonk answers its health check: wait_healthy [port].
wait_healthy() {
  for _ in $(seq 60); do
    [ "$(hx curl -fsS "http://127.0.0.1:${1:-9000}/health" 2>/dev/null)" = '{"data":true}' ] && return 0
    sleep 2
  done
  fail "listmonk does not answer on port ${1:-9000}"
}
# SQL as listmonk in the project's database service, whatever its container is called.
sql() { hx sh -c "cd $dir && docker compose exec -T db psql -U listmonk -d listmonk -tAc \"\$0\"" "$1"; }
compose_sum() { hx sha256sum "$dir/docker-compose.yaml"; }
dumps() { hx sh -c "ls $dir/backups/*.dump 2>/dev/null | wc -l"; }
started_at() { hx docker inspect -f '{{.State.StartedAt}}' listmonk_app_app; }
app_image() { hx docker inspect -f '{{.Config.Image}}' listmonk_app_app; }
# The version the running listmonk binary reports.
app_version() { hx docker exec listmonk_app_app /listmonk/listmonk --version | cut -d' ' -f1; }
marker() { hx cat "$dir/update-failed"; }
add_subscriber() {
  sql "INSERT INTO subscribers (uuid, email, name, status) VALUES (gen_random_uuid(), 'old@example.test', 'Old', 'enabled')" >/dev/null
}
expect_subscriber() {
  [ "$(sql "SELECT count(*) FROM subscribers WHERE email = 'old@example.test'")" = 1 ] || fail "the subscriber is gone"
}
# An installation as the old role left it: old_install <image tag> [sed script],
# old-compose.yml with __TAG__ replaced and the sed script applied, mode 0444,
# with a subscriber and an upload.
old_install() {
  hx mkdir -p "$dir"
  sed -e "s|__TAG__|$1|" -e "${2:-}" "$here/old-compose.yml" \
    | hxi sh -c "cat >$dir/docker-compose.yaml && chmod 0444 $dir/docker-compose.yaml"
  hx sh -c "cd $dir && docker compose up -d" >"$out/old-install.log" 2>&1 \
    || { cat "$out/old-install.log" >&2; fail "the old installation did not start"; }
  wait_healthy
  sql "INSERT INTO subscribers (uuid, email, name, status) VALUES (gen_random_uuid(), 'old@example.test', 'Old', 'enabled')" >/dev/null
  hx sh -c "echo old upload >$dir/data/listmonk/uploads/old.txt"
}
expect_old_data() {
  [ "$(sql "SELECT count(*) FROM subscribers WHERE email = 'old@example.test'")" = 1 ] || fail "the subscriber is gone"
  [ "$(hx cat "$dir/data/listmonk/uploads/old.txt")" = "old upload" ] || fail "the upload is gone"
}

echo "== a missing listmonk_db_password must be refused"
new_host
# Ad hoc, without vars.yml: listmonk_db_password is undefined.
if ansible all -i "$here/inventory.yml" -e "test_host=$host" \
  -m ansible.builtin.include_role -a name=noixdev.infra.listmonk >"$out/invalid.log" 2>&1; then
  fail "listmonk ran without listmonk_db_password"
fi
expect_in_log invalid "listmonk_db_password is required"
play_fails invalid-empty "$here/converge.yml" -e listmonk_db_password=
expect_in_log invalid-empty "listmonk_db_password is required"
hx test ! -e /opt/listmonk || fail "listmonk touched the host before checking its settings"

echo "== install"
load_images
play "$here/converge.yml"
[ "$(hx curl -fsS http://127.0.0.1:9000/health)" = '{"data":true}' ] || fail "listmonk is not healthy"
[ "$(sql "SELECT string_agg(username, ',') FROM users")" = test-admin ] || fail "the admin is not the only user"
verify
expect_idempotent

echo "== a run without changes must fail on a stopped listmonk and start nothing"
hx docker stop listmonk_app_app >/dev/null
play_fails stopped "$here/converge.yml"
expect_in_log stopped "listmonk_app_app is not running"
grep -Eq 'changed=0 ' "$out/stopped.log" || fail "the run on a stopped listmonk changed something"
[ "$(hx docker inspect -f '{{.State.Running}}' listmonk_app_app)" = false ] || fail "the run started listmonk"
hx docker start listmonk_app_app >/dev/null
wait_healthy

echo "== a starting database must be waited for"
# As after a reboot: the database comes up only while the converge runs.
hx docker stop listmonk_app_db >/dev/null
(sleep 15 && hx docker start listmonk_app_db >/dev/null) &
starter=$!
play "$here/converge.yml" | tee "$out/db-starting.log"
wait "$starter"
grep -q "RETRYING.*Wait for the database" "$out/db-starting.log" || fail "the converge did not wait for the database"
# listmonk_db_password worked once the database was up: the old one was never tried.
grep -A1 "Try listmonk_db_password_old" "$out/db-starting.log" | grep -q skipping \
  || fail "a starting database was taken for a wrong password"
grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/db-starting.log" || fail "the converge after the database start changed something"

echo "== takeover of an installation of the old role"
new_host
load_images
old_install "$version"
play "$here/converge.yml"
expect_old_data
verify
[ "$(dumps)" = 1 ] || fail "the takeover did not leave exactly one dump"
expect_idempotent

echo "== a failed reconfigure must restore the installation"
before="$(compose_sum)"
# Port 9001 is taken, so the new app container cannot start.
docker exec -d "$host" python3 -m http.server 9001 --bind 127.0.0.1
for _ in $(seq 20); do hx curl -s -o /dev/null http://127.0.0.1:9001/ && break; sleep 0.5; done
hx curl -s -o /dev/null http://127.0.0.1:9001/ || fail "port 9001 is not taken"
play_fails port "$here/converge.yml" -e listmonk_port=9001
expect_in_log port "restored"
[ "$(compose_sum)" = "$before" ] || fail "the compose file was not put back"
wait_healthy 9000
expect_old_data
hx pkill -f http.server
verify
expect_idempotent

echo "== a restore onto a schema a newer listmonk migrated"
play "$here/restore.yml" -e "verify_version=$version"
expect_old_data
verify
expect_idempotent

echo "== takeover of a latest installation"
new_host
load_images
hx docker tag "listmonk/listmonk:$version" listmonk/listmonk:latest
old_install latest
play "$here/converge.yml" | tee "$out/takeover-latest.log"
grep -q "reconfigure.yml" "$out/takeover-latest.log" || fail "the takeover of latest was not a reconfigure"
hx sh -c "ls $dir/backups/*-$version.dump" >/dev/null || fail "the dump does not name the running version $version"
expect_old_data
verify
expect_idempotent

echo "== an installation laid out differently must be refused"
new_host
load_images
old_install "$version" 's|container_name: "listmonk_app_db"|container_name: "other_db"|'
before="$(compose_sum)"
play_fails layout "$here/converge.yml"
expect_in_log layout "other_db"
expect_in_log layout "listmonk_app_db"
[ "$(compose_sum)" = "$before" ] || fail "the refused takeover changed the compose file"
hx test ! -e "$dir/backups" || fail "the refused takeover took a dump"

echo "== an unknown database password must be refused"
new_host
load_images
old_install "$version" 's/POSTGRES_PASSWORD=listmonk/POSTGRES_PASSWORD=elsewise/; s/LISTMONK_db__password: listmonk/LISTMONK_db__password: elsewise/'
before="$(compose_sum)"
play_fails password "$here/converge.yml"
expect_in_log password "listmonk_db_password_old"
[ "$(compose_sum)" = "$before" ] || fail "the refused takeover changed the compose file"
hx test ! -e "$dir/backups" || fail "the refused takeover took a dump"

echo "== an update from an older release"
new_host
load_images
play "$here/converge.yml" -e "listmonk_version=$older"
[ "$(app_version)" = "$older" ] || fail "the install did not run $older"
add_subscriber
# Older dumps than the update's: only the newest listmonk_dumps_keep (3) stay.
hx sh -c "mkdir -m 0700 $dir/backups && for d in 20200101 20200102 20200103; do echo old >$dir/backups/\${d}T000000Z-$older.dump; done"
play "$here/converge.yml" | tee "$out/update.log"
grep -q "update.yml" "$out/update.log" || fail "the run was not an update"
[ "$(app_version)" = "$version" ] || fail "listmonk does not run $version after the update"
[[ "$(sql "SELECT value FROM settings WHERE key = 'migrations'")" == *"\"$version\""* ]] || fail "the schema was not upgraded to $version"
expect_subscriber
[ "$(dumps)" = 3 ] || fail "the update did not keep exactly 3 dumps"
[ "$(hx sh -c "ls $dir/backups/*Z-$older.dump" | grep -vc '/2020')" = 1 ] || fail "the update's dump does not name $older"
hx test ! -e "$dir/backups/20200101T000000Z-$older.dump" || fail "the oldest dump was kept"
hx test -e "$dir/backups/20200102T000000Z-$older.dump" || fail "a newer dump was removed"
verify
expect_idempotent

echo "== a downgrade must be refused"
before="$(started_at)"
dumps_before="$(hx sh -c "ls $dir/backups")"
play_fails downgrade "$here/converge.yml" -e "listmonk_version=$older"
expect_in_log downgrade "lower than the running version"
[ "$(hx sh -c "ls $dir/backups")" = "$dumps_before" ] || fail "the refused downgrade took a dump"
[ "$(started_at)" = "$before" ] || fail "the refused downgrade restarted listmonk"

echo "== a failed pull must stop the update"
play_fails pull "$here/converge.yml" -e listmonk_version=v97.0.0
expect_in_log pull "before anything changed"
[ "$(hx sh -c "ls $dir/backups")" = "$dumps_before" ] || fail "the failed pull took a dump"
[ "$(started_at)" = "$before" ] || fail "the failed pull restarted listmonk"
[ "$(app_image)" = "listmonk/listmonk:$version" ] || fail "the failed pull changed the version"

echo "== a failed dump must stop the update"
new_host
load_images
play "$here/converge.yml"
add_subscriber
build_broken
before="$(started_at)"
compose_before="$(compose_sum)"
# As a full disk: the backup directory holds 4 KiB.
hx sh -c "mkdir -p $dir/backups && mount -t tmpfs -o size=4k tmpfs $dir/backups"
play_fails dump "$here/converge.yml" -e listmonk_version=v99.0.0
expect_in_log dump "Dump the database"
expect_in_log dump "before anything changed"
[ "$(started_at)" = "$before" ] || fail "the failed dump restarted listmonk"
[ "$(app_image)" = "listmonk/listmonk:$version" ] || fail "the failed dump changed the version"
[ "$(compose_sum)" = "$compose_before" ] || fail "the failed dump changed the compose file"
hx test ! -e "$dir/update-failed" || fail "the failed dump wrote the marker"
[ "$(dumps)" = 0 ] || fail "the failed dump left a dump"
hx umount "$dir/backups"

echo "== a failed update must roll back"
play_fails rollback "$here/converge.yml" -e listmonk_version=v99.0.0 -e listmonk_health_timeout=30
expect_in_log rollback "update to v99.0.0 failed, rolled back to $version"
wait_healthy
[ "$(app_version)" = "$version" ] || fail "listmonk does not run $version after the rollback"
expect_subscriber
grep -qx "failed_version: v99.0.0" <<<"$(marker)" || fail "the marker does not name v99.0.0: $(marker)"
grep -qx "rolled_back_to: $version" <<<"$(marker)" || fail "the marker does not name $version: $(marker)"
grep -q "^dump: $dir/backups/.*-$version.dump$" <<<"$(marker)" || fail "the marker does not name the dump: $(marker)"
hx grep -qF "\"listmonk/listmonk:$version\"" "$dir/docker-compose.yaml" || fail "the compose file does not name $version"
verify

echo "== the compose file must name the good version after a rollback"
# As the compose reconcile after a reboot.
hx sh -c "cd $dir && docker compose up -d --no-recreate" >/dev/null 2>&1
wait_healthy
[ "$(app_image)" = "listmonk/listmonk:$version" ] || fail "compose up started $(app_image)"

echo "== the marker must block the failed version"
before="$(started_at)"
dumps_before="$(hx sh -c "ls $dir/backups")"
play_fails marker "$here/converge.yml" -e listmonk_version=v99.0.0
expect_in_log marker "$dir/update-failed"
expect_in_log marker "remove it"
[ "$(hx sh -c "ls $dir/backups")" = "$dumps_before" ] || fail "the blocked update took a dump"
[ "$(started_at)" = "$before" ] || fail "the blocked update restarted listmonk"
# A marker that is not YAML blocks with its own message.
hx cp "$dir/update-failed" "$dir/update-failed.saved"
echo 'failed_version: [v99' | hxi sh -c "cat >$dir/update-failed"
play_fails marker-invalid "$here/converge.yml"
expect_in_log marker-invalid "is not YAML"
[ "$(started_at)" = "$before" ] || fail "the run with an invalid marker restarted listmonk"
hx mv "$dir/update-failed.saved" "$dir/update-failed"
play "$here/converge.yml"
hx test ! -e "$dir/update-failed" || fail "a run with another version kept the marker"
expect_idempotent

echo "== a failed rollback must name the dump"
build_unrestorable
play_fails unrestorable "$here/converge.yml" -e listmonk_version=v98.0.0 -e listmonk_health_timeout=30
expect_in_log unrestorable "failed too"
expect_in_log unrestorable "by hand"
grep -Eq "$dir/backups/[0-9TZ]+-$version\.dump" "$out/unrestorable.log" || fail "the failed rollback does not name the dump"
grep -qx "failed_version: v98.0.0" <<<"$(marker)" || fail "the marker does not name v98.0.0: $(marker)"

echo "== an update must be postponed while a campaign is sending"
new_host
load_images
old_install "$older"
# listmonk must keep answering without sending the campaign (which would
# finish it): paused while the campaign is set running and a session takes
# its row lock, listmonk's campaign scan then waits on that lock, and /health
# (which does not touch the database) still answers.
hx docker pause listmonk_app_app >/dev/null
sql "UPDATE campaigns SET status = 'running' WHERE id = (SELECT min(id) FROM campaigns)" >/dev/null
[ "$(sql "SELECT count(*) FROM campaigns WHERE status = 'running'")" = 1 ] || fail "there is no campaign to send"
hx docker exec -d listmonk_app_db psql -U listmonk -d listmonk \
  -c "BEGIN; SELECT id FROM campaigns WHERE status = 'running' FOR UPDATE; SELECT pg_sleep(3600);"
locked() {
  [ "$(sql "SELECT count(*) FROM pg_stat_activity WHERE query LIKE '%pg_sleep(3600)%' AND state = 'active' AND pid <> pg_backend_pid()")" = 1 ]
}
for _ in $(seq 20); do locked && break; sleep 0.5; done
locked || fail "the campaign is not locked"
hx docker unpause listmonk_app_app >/dev/null
wait_healthy
for run in 1 2; do
  # The warning goes to stderr.
  play "$here/converge.yml" 2>&1 | tee "$out/postpone-$run.log"
  grep -q "WARNING.*postponed" "$out/postpone-$run.log" || fail "run $run did not warn about the postponed update"
  [ "$(app_image)" = "listmonk/listmonk:$older" ] || fail "run $run changed the version"
  hx grep -qx "count: $run" "$dir/update-postponed" || fail "the postpone counter is not $run"
done
hx test ! -e "$dir/backups" || fail "a postponed update took a dump"
# A stopped listmonk with a sending campaign: red at once, nothing started or counted.
hx docker stop listmonk_app_app >/dev/null
play_fails postpone-down "$here/converge.yml"
expect_in_log postpone-down "listmonk_app_app is not running"
grep -Eq 'changed=0 ' "$out/postpone-down.log" || fail "the postponed run on a stopped listmonk changed something"
[ "$(hx docker inspect -f '{{.State.Running}}' listmonk_app_app)" = false ] || fail "the postponed run started listmonk"
hx grep -qx "count: 2" "$dir/update-postponed" || fail "the run on a stopped listmonk counted a postponed run"
hx docker start listmonk_app_app >/dev/null
wait_healthy
play_fails postpone-3 "$here/converge.yml"
expect_in_log postpone-3 "postponed 3 runs"
[ "$(app_image)" = "listmonk/listmonk:$older" ] || fail "the third postponed run changed the version"
hx test ! -e "$dir/backups" || fail "the third postponed run took a dump"

echo "== an update of an old-role installation must set the database password"
# listmonk stopped first, so it does not send the campaign once the lock is gone.
hx docker stop listmonk_app_app >/dev/null
sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep(3600)%' AND pid <> pg_backend_pid()" >/dev/null
sql "UPDATE campaigns SET status = 'finished' WHERE status = 'running'" >/dev/null
play "$here/converge.yml" | tee "$out/takeover-update.log"
grep -q "update.yml" "$out/takeover-update.log" || fail "the run was not an update"
hx test ! -e "$dir/update-postponed" || fail "the update kept the postpone counter"
[ "$(app_version)" = "$version" ] || fail "listmonk does not run $version after the update"
hx sh -c "ls $dir/backups/*-$older.dump" >/dev/null || fail "the dump does not name $older"
expect_old_data
verify
expect_idempotent

echo "== a failed update of an old-role installation must put the old password back"
new_host
load_images
old_install "$older"
build_broken
before="$(compose_sum)"
play_fails takeover-rollback "$here/converge.yml" -e listmonk_version=v99.0.0 -e listmonk_health_timeout=30
expect_in_log takeover-rollback "update to v99.0.0 failed, rolled back to $older"
wait_healthy
[ "$(app_version)" = "$older" ] || fail "listmonk does not run $older after the rollback"
[ "$(compose_sum)" = "$before" ] || fail "the old compose file was not put back"
expect_old_data
play "$here/verify.yml" -e "verify_version=$older" -e verify_old_password=true

echo "== all listmonk tests passed"
