#!/usr/bin/env bash
# End-to-end test of the paperless role on throwaway Docker-in-Docker hosts
# (a fresh one per scenario): the refusals of invalid settings before any
# change (a PostgreSQL image older than 18 among them); a failed install (a
# webserver that never becomes healthy) that stops the stack, Samba included,
# and that every later run refuses until it is removed; a fresh install
# behind Traefik (API and login form
# through Traefik, no published HTTP port, Samba on 127.0.0.1 only, a $
# reaching the container verbatim), a scan written over the Samba share that
# Paperless consumes, SMB1 refused, a reconfigure of the share, and a run
# without changes that fails on a stopped container. Then the import of that
# host's export: refused into the host itself (not empty); on a fresh host
# refused for an export of another version, without a manifest, without its
# passphrase and for a path outside the export directory, an export that
# Paperless' user cannot read refused, a half-failed import (a truncated
# manifest) refused until it is removed as the message says, then imported
# once (documents, title and admin of the source, the record), a marker left
# beside the record refused with a message to remove only the marker, and
# after another removal an export made with a passphrase imported with it,
# with port 445 taken: the import recorded, only Samba failed. Then an
# update from an older release with a document, with port 445 taken: the
# update kept (no rollback, no marker), only Samba failed; a backup (dump,
# data, media) taken and the oldest pruned, the document unchanged, a
# downgrade and another PostgreSQL major refused; and an update to an image
# that exits at once: rolled back with the document, the marker that blocks
# the failed version, and the update once the marker is removed; a marker of
# a rollback that failed too refuses every version. The install,
# the import with a passphrase, the failed update and the interrupted ones
# with their refusals and restores run at -vvv, and their output must not
# hold a test secret.
# Then the database check: an update to a test image that starts healthy with
# a migration its web server start does not apply is rolled back with
# update-failed naming the check, and a run without changes while the
# database does not answer (its postmaster stopped, the container still
# healthy) fails with the check within the health timeout. Then the updates
# that did not finish, with converges killed (SIGKILL to their process group)
# at a point of an update: paperless_restore_interrupted without an
# interrupted update refused; a marker that is not YAML, lacks its keys or
# cannot be read (a directory) refused, its copies kept; one beside
# update-failed of the same backup removed, update-failed deciding (with
# paperless_restore_interrupted its refusal says the variable does not
# apply), but kept by a run that another refusal stops; one beside an install
# marker refused naming both files; killed once the compose file names the
# new release and the Samba files changed: the marker (step update, both
# versions, the backup, mode 0600) with its copies refuses every run, beside
# update-failed of another update too, a copy of the compose file that cannot
# be read fails the restore with a message of its own, and
# paperless_restore_interrupted restores the previous release with its
# document and Samba files after a restore stopped while it put the data and
# media back, removing that update-failed; killed during the rollback of a
# failed update: refused and restored the same way; copies that cannot be
# written fail the update before the backup with a message of their own;
# killed during the backup: the next run cleans up and updates, removing the
# marker before its copies; a restore that fails (the previous image cannot
# be started) records a failed rollback and refuses every version.
# Then the refusals on an installation: a changed paperless_db_password
# refused before any change (-vvv), a compose file that is not YAML refused
# without a line of it in the output (-vvv), and the new password taken once
# the database has it (ALTER USER, as the refusal says).
# Then the data: left-over data without a compose file refused, and an
# installation whose data directories are gone (an unmounted volume) refused
# in every state without creating anything; with
# paperless_data_dir_mountpoint a data directory that is not a mountpoint
# refused, and an install onto one (a tmpfs) without Samba and Tika.
# Every successful converge is repeated and must change nothing.
# NOIXDEV_INFRA_PAPERLESS_TESTS selects scenarios (see the end of the file);
# NOIXDEV_INFRA_PAPERLESS_TEST_HOST and NOIXDEV_INFRA_PAPERLESS_TEST_OUT (the
# directory of the logs and image tarballs) let two runs go side by side.
# The single-quoted scripts expand inside the container, not here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
host="${NOIXDEV_INFRA_PAPERLESS_TEST_HOST:-noixdev-infra-paperless-test}"
out="${NOIXDEV_INFRA_PAPERLESS_TEST_OUT:-$tests/output/paperless}"
dir=/opt/paperless
defaults="$root/roles/paperless/defaults/main.yml"
traefik_defaults="$root/roles/traefik/defaults/main.yml"

# The value of a top-level key in a YAML file: value_of <file> <key>.
value_of() { sed -n "s/^$2: *//p" "$1" 2>/dev/null || true; }
version="$(value_of "$defaults" paperless_version)"
images=(
  "$(value_of "$defaults" paperless_image):$version"
  "$(value_of "$defaults" paperless_postgres_image)"
  "$(value_of "$defaults" paperless_redis_image)"
  "$(value_of "$defaults" paperless_tika_image)"
  "$(value_of "$defaults" paperless_gotenberg_image)"
  "$(value_of "$defaults" paperless_samba_image)"
  "$(value_of "$traefik_defaults" traefik_image)"
  "$(value_of "$traefik_defaults" traefik_socket_proxy_image)"
)
admin_password="$(value_of "$here/vars.yml" paperless_admin_password)"
# The export directory on the host and the export the import tests use.
export_dir="$dir/data/export"
import="$export_dir/t1"
# The second export is made with a passphrase that the command module and a
# shell would expand if it were not passed verbatim.
encrypted="$export_dir/t2"
passphrase="pass \$HOME 'q' \`id\`"
samba_password="$(value_of "$here/vars.yml" paperless_samba_password)"
# The update tests: the older release they install first, and an image that
# exits at once, tagged as the new release of a test image for an update that
# fails.
old_version=3.3.4
old_images=("$(value_of "$defaults" paperless_image):$old_version" busybox:1.37)
backups="$dir/data/backups"
marker="$dir/update-failed"
# The marker of an update in progress and its copies of the files the update
# replaces.
progress="$dir/update-in-progress"
progress_compose="$dir/update-in-progress.compose.yaml"
progress_smb_conf="$dir/update-in-progress.smb.conf"
progress_samba_pass="$dir/update-in-progress.samba-pass"
sample_sum="$(shasum -a 256 <"$here/sample.pdf" | cut -d' ' -f1)"
# The database password the refusals scenario rotates to; a $ that compose and
# a shell must not expand.
rotated_db_password='test-db-ro$tated-pass-0'
# The test secrets, which no run's output may hold.
secrets=(
  "$(value_of "$here/vars.yml" paperless_secret_key)"
  "$(value_of "$here/vars.yml" paperless_db_password)"
  "$admin_password"
  "$samba_password"
  "$passphrase"
  "$rotated_db_password"
)

cleanup() { [ "${KEEP:-0}" = 1 ] || docker rm -f -v "$host" >/dev/null 2>&1 || true; }
# shellcheck source=/dev/null
. "$here/../lib/suite.sh"
noix_exit_guard

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
noix_link_collection "$root" "$tests/output"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"
export ANSIBLE_HOST_KEY_CHECKING=False

fail() { echo "$*" >&2; exit 1; }
hx() { docker exec "$host" "$@"; }
play() { ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$@"; }
# A converge that must fail; its output goes to $out/<name>.log.
play_fails() {
  local name="$1"
  shift
  if play "$@" >"$out/$name.log" 2>&1; then
    fail "converge $name succeeded but must fail"
  fi
}
# The paperless role alone (no Traefik) that must fail: role_fails <name>
# [extra vars...]; its output goes to $out/<name>.log.
role_fails() {
  local name="$1"
  shift
  play_fails "$name" "$here/converge.yml" -e converge_traefik=false "$@"
}
expect_in_log() {
  grep -qF -- "$2" "$out/$1.log" || { cat "$out/$1.log" >&2; fail "$1.log lacks: $2"; }
}
# Fails when the log is missing or empty (it would prove nothing) or holds a
# test secret, as it is, with its $ doubled (as the compose file holds it),
# or either of them up to its first quote or backslash (a quoted or escaped
# copy): expect_no_secrets <name>.
expect_no_secrets() {
  local log="$out/$1.log" secret doubled part
  [ -s "$log" ] || fail "$1.log is missing or empty, so it cannot show that no secret is in it"
  for secret in "${secrets[@]}"; do
    [ "${#secret}" -ge 8 ] || fail "a test secret is shorter than 8 characters: check vars.yml"
    doubled="${secret//\$/\$\$}"
    for part in "$secret" "${secret%%[\'\"\\\`]*}" "$doubled" "${doubled%%[\'\"\\\`]*}"; do
      if [ "${#part}" -ge 8 ] && grep -qF -- "$part" "$log"; then
        fail "$1.log holds a test secret (${part:0:4}...): $(grep -nF -- "$part" "$log" | head -n 3 | cut -c1-200)"
      fi
    done
  done
}
expect_unchanged() {
  grep -Eq 'changed=0 ' "$out/$1.log" || { cat "$out/$1.log" >&2; fail "converge $1 changed something"; }
}
expect_idempotent() {
  play "$here/converge.yml" "$@" >"$out/rerun.log" 2>&1 || { cat "$out/rerun.log" >&2; fail "a repeated converge failed"; }
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/rerun.log" || { cat "$out/rerun.log" >&2; fail "a repeated converge changed something"; }
}
converge() {
  play "$here/converge.yml" "$@" >"$out/converge.log" 2>&1 || { tail -n 60 "$out/converge.log" >&2; fail "the converge failed"; }
}

# A fresh Docker-in-Docker host.
new_host() {
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  noix_cache_run=() && noix_cache_array noix_cache_run noix_cache_run_args
  noix_cache_dind=() && noix_cache_array noix_cache_dind noix_cache_dind_args
  docker run -d --privileged --name "$host" ${noix_cache_run[@]+"${noix_cache_run[@]}"} docker:29-dind ${noix_cache_dind[@]+"${noix_cache_dind[@]}"} >/dev/null
  until hx docker info >/dev/null 2>&1; do sleep 1; done
  # Retried: the host's first DNS lookups fail now and then.
  for _ in 1 2 3; do hx apk add --no-cache python3 curl samba-client >/dev/null && return 0; sleep 3; done
  fail "cannot install python3, curl and samba-client on the test host"
}
# Loads images into the host, pulled and saved once per set of images:
# load_set <image...>.
load_set() {
  local image key tarball
  key="$(printf '%s\n' "$@" | cksum | cut -d' ' -f1)"
  tarball="$out/images-$key.tar"
  if [ ! -s "$tarball" ]; then
    for image in "$@"; do docker pull -q "$image" >/dev/null; done
    docker save -o "$tarball" "$@"
  fi
  docker exec -i "$host" docker load <"$tarball" >/dev/null
}
# Loads the role's and Traefik's default images into the host.
load_images() {
  local image
  for image in "${images[@]}"; do
    case "$image" in
      "" | :* | *:) fail "an image is missing in $defaults or $traefik_defaults" ;;
    esac
  done
  load_set "${images[@]}"
}
# The API through Traefik as the admin: api <path>.
api() {
  hx curl -fsS -H 'Host: paperless.test' -u "admin:$admin_password" "http://127.0.0.1$1"
}
doc_count() { api /api/documents/ | python3 -c 'import json, sys; print(json.load(sys.stdin)["count"])'; }
consume_empty() { [ -z "$(hx ls -A "$dir/data/consume")" ]; }
# The SHA-256 of the one document's original as Paperless serves it.
original_sum() {
  local id
  id="$(api /api/documents/ | python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["id"])')"
  api "/api/documents/$id/download/?original=true" | shasum -a 256 | cut -d' ' -f1
}
# Image, state and health of the webserver container.
webserver() { hx sh -c "cd $dir && docker compose ps --all --format '{{.Image}} {{.State}} {{.Health}}' webserver"; }
# smbclient on the share as the scanner user: smb <protocol> <command> [options...].
smb() {
  local protocol="$1" command="$2"
  shift 2
  hx smbclient //127.0.0.1/consume -U "scanner%$samba_password" -m "$protocol" "$@" -c "$command"
}
# Takes 127.0.0.1:445 on the host, so the Samba container cannot publish its
# port and fails to start; free_smb_port gives it back.
take_smb_port() {
  docker exec -d "$host" python3 -c 'import socket, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 445)); s.listen(); open("/run/smb-port-taken", "w").close(); time.sleep(3600)'
  for _ in $(seq 20); do hx test -e /run/smb-port-taken && return 0; sleep 0.5; done
  fail "cannot take port 445 on the test host"
}
free_smb_port() {
  hx pkill -f smb-port-taken || true
  hx rm -f /run/smb-port-taken
}
# Writes sample.pdf over the share and waits until it is the one document.
consume_sample() {
  # Through stdin: docker cp cannot write into the host's /tmp, a tmpfs.
  docker exec -i "$host" sh -c 'cat >/root/sample.pdf' <"$here/sample.pdf"
  smb SMB3 'put /root/sample.pdf sample.pdf' >"$out/smb-put.log" 2>&1 || { cat "$out/smb-put.log" >&2; fail "the scan could not be written over SMB3"; }
  for _ in $(seq 90); do
    [ "$(doc_count)" = 1 ] && consume_empty && break
    sleep 2
  done
  [ "$(doc_count)" = 1 ] || fail "the scan was not consumed: $(doc_count) documents"
  consume_empty || fail "the consume directory still holds: $(hx ls -A "$dir/data/consume")"
}

# The scenarios, run by the loop at the end.
test_settings() {
  echo "== invalid settings must be refused before any change"
  new_host
  role_fails no-secret -e paperless_secret_key=
  expect_in_log no-secret paperless_secret_key
  role_fails short-secret -e paperless_secret_key=too-short
  expect_in_log short-secret paperless_secret_key
  role_fails no-samba-bind -e paperless_samba_bind=
  expect_in_log no-samba-bind paperless_samba_bind
  role_fails owned-env -e '{"paperless_env": {"PAPERLESS_DBHOST": "x"}}'
  expect_in_log owned-env paperless_env
  expect_in_log owned-env PAPERLESS_DBHOST
  role_fails nt1 -e paperless_samba_min_protocol=NT1
  expect_in_log nt1 paperless_samba_min_protocol
  role_fails v2 -e paperless_version=2.20.15
  expect_in_log v2 paperless_version
  role_fails v-prefix -e paperless_version=v3.4.2
  expect_in_log v-prefix paperless_version
  role_fails postgres-tag -e paperless_postgres_image=docker.io/library/postgres:latest
  expect_in_log postgres-tag paperless_postgres_image
  # Before 18 the image's volume is /var/lib/postgresql/data, which would put
  # the database on an anonymous volume beside paperless_data_dir.
  role_fails postgres-17 -e paperless_postgres_image=docker.io/library/postgres:17
  expect_in_log postgres-17 "PostgreSQL 18 or newer"
  expect_in_log postgres-17 "docker.io/library/postgres:17 is PostgreSQL 17"
  expect_unchanged postgres-17
  role_fails no-admin -e paperless_admin_user= -e paperless_admin_password=
  expect_in_log no-admin paperless_admin_user
  hx test ! -e "$dir" || fail "paperless touched the host before refusing its settings"
}

test_install() {
  echo "== a failed install must be refused until it is removed"
  new_host
  load_images
  load_set busybox:1.37
  # A webserver that exits at once: the stack, Samba included, runs, but
  # Paperless never becomes healthy.
  hx docker tag busybox:1.37 "test.invalid/paperless-ngx:$version"
  play_fails install-failed "$here/converge.yml" -e paperless_image=test.invalid/paperless-ngx -e paperless_health_timeout=20
  expect_in_log install-failed "The install of Paperless $version in $dir failed (Fail when Paperless is not healthy:"
  expect_in_log install-failed "check that nothing in it is worth keeping"
  expect_in_log install-failed "docker compose down in $dir"
  expect_in_log install-failed "remove $dir/compose.yaml"
  expect_in_log install-failed "the subdirectories media, data, consume, postgres and redis of $dir/data"
  expect_in_log install-failed "keep $export_dir"
  # An export staged under the data directory must survive the hint.
  if grep -qF -- "remove $dir/data," "$out/install-failed.log" || grep -qF -- "remove $dir/data (" "$out/install-failed.log"; then
    fail "the install hint says to remove the data directory as a whole"
  fi
  hx test -e "$dir/install-incomplete" || fail "the failed install left no marker"
  # Samba would accept scans that the hint's removal then deletes.
  [ -z "$(hx docker ps -q --filter label=com.docker.compose.project=paperless)" ] \
    || fail "the failed install left containers running: $(hx docker ps --format '{{.Names}}' --filter label=com.docker.compose.project=paperless)"
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  containers_before="$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)"
  play_fails install-incomplete "$here/converge.yml"
  expect_in_log install-incomplete "$dir/install-incomplete exists"
  expect_in_log install-incomplete "docker compose down in $dir"
  expect_unchanged install-incomplete
  [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused run changed the compose file"
  [ "$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)" = "$containers_before" ] \
    || fail "the refused run created or removed containers"
  # As the message says; the install then starts afresh.
  hx sh -c "cd $dir && docker compose down" >/dev/null 2>&1
  hx rm -rf "$dir"

  echo "== install"
  converge -vvv
  hx test ! -e "$dir/install-incomplete" || fail "the install kept its marker"
  expect_no_secrets converge
  expect_idempotent
  play "$here/verify.yml"

  echo "== a scan written over Samba must be consumed"
  consume_sample
  api /api/documents/ | grep -q "noixdev paperless test" || fail "the document lacks the scan's text"

  echo "== SMB1 must be refused"
  if smb NT1 ls --option='client min protocol=NT1' >"$out/smb-nt1.log" 2>&1; then
    fail "the share answered over NT1"
  fi

  echo "== a changed share setting must reach Samba"
  converge -e paperless_samba_min_protocol=SMB3
  grep -q "reconfigure.yml" "$out/converge.log" || fail "the changed setting was not a reconfigure"
  hx grep -qx '   server min protocol = SMB3' "$dir/smb.conf" || fail "smb.conf does not say SMB3"
  for _ in $(seq 30); do smb SMB3 ls >/dev/null 2>&1 && break; sleep 2; done
  smb SMB3 ls >"$out/smb-smb3.log" 2>&1 || { cat "$out/smb-smb3.log" >&2; fail "the share does not answer over SMB3"; }
  if smb SMB2 ls >"$out/smb-smb2.log" 2>&1; then
    fail "the share still answers over SMB2 after the change to SMB3"
  fi
  expect_idempotent -e paperless_samba_min_protocol=SMB3
  converge
  expect_idempotent

  echo "== a run without changes must fail on a stopped container and start nothing"
  hx sh -c "cd $dir && docker compose stop samba" >/dev/null 2>&1
  play_fails stopped "$here/converge.yml"
  expect_in_log stopped "samba"
  expect_in_log stopped "not running"
  expect_unchanged stopped
  [ -z "$(hx sh -c "cd $dir && docker compose ps --quiet samba")" ] || fail "the run started samba"
  hx sh -c "cd $dir && docker compose start samba" >/dev/null 2>&1

  echo "== an import into an installed Paperless must be refused"
  # The source of the import tests: this host's export, with its one document.
  source_title="$(api /api/documents/ | python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["title"])')"
  hx install -d -o 1000 -g 1000 "$import"
  hx sh -c "cd $dir && docker compose exec -T webserver document_exporter /usr/src/paperless/export/t1 --no-progress-bar" \
    >"$out/export.log" 2>&1 || { cat "$out/export.log" >&2; fail "the export failed"; }
  hx test -s "$import/manifest.json" || fail "the export has no manifest.json"
  hx install -d -o 1000 -g 1000 "$encrypted"
  docker exec -w "$dir" "$host" docker compose exec -T webserver document_exporter /usr/src/paperless/export/t2 \
    --no-progress-bar --passphrase "$passphrase" >"$out/export-t2.log" 2>&1 || { cat "$out/export-t2.log" >&2; fail "the export with a passphrase failed"; }
  hx grep -q __crypto__ "$encrypted/metadata.json" || fail "the export with a passphrase is not encrypted"
  rm -rf "$out/export-t1" "$out/export-t2"
  docker cp "$host:$import" "$out/export-t1"
  docker cp "$host:$encrypted" "$out/export-t2"
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  play_fails import-installed "$here/converge.yml" -e "paperless_import_dir=$import"
  expect_in_log import-installed "not empty; the import needs a fresh installation"
  expect_unchanged import-installed
  [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused import changed the compose file"
  [ "$(doc_count)" = 1 ] || fail "the refused import changed the documents: $(doc_count)"
  hx test ! -e "$dir/imported.yml" || fail "the refused import wrote a record"
}

# Needs test_install in the same run: it makes the exports.
test_import() {
  [ -n "${source_title:-}" ] || fail "the import tests need the install tests in the same run (they make the exports)"
  echo "== an import of another version, from outside the export directory or without its passphrase must be refused before any change"
  new_host
  hx mkdir -p "$export_dir"
  docker cp "$out/export-t1" "$host:$import"
  docker cp "$out/export-t2" "$host:$encrypted"
  # Everything under $dir (the export only) and the containers.
  snapshot() { hx sh -c "find $dir -exec stat -c '%n %a %u %g %s %Y' {} + | sort; docker ps -aq"; }
  before="$(snapshot)"
  role_fails import-outside -e paperless_import_dir=/tmp/x
  expect_in_log import-outside "outside the export directory"
  role_fails import-dotdot -e "paperless_import_dir=$export_dir/../export/t1"
  expect_in_log import-dotdot "outside the export directory"
  [ "$(snapshot)" = "$before" ] || fail "a refused import changed the host"
  hx python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["version"] = "3.3.4"; json.dump(d, open(p, "w"))' "$import/metadata.json"
  before="$(snapshot)"
  role_fails import-version -e "paperless_import_dir=$import"
  expect_in_log import-version "3.3.4"
  expect_in_log import-version "$version"
  [ "$(snapshot)" = "$before" ] || fail "the refused import of another version changed the host"
  docker cp "$out/export-t1/metadata.json" "$host:$import/metadata.json"
  before="$(snapshot)"
  role_fails import-no-passphrase -e "paperless_import_dir=$encrypted"
  expect_in_log import-no-passphrase "was made with a passphrase"
  [ "$(snapshot)" = "$before" ] || fail "the refused import without a passphrase changed the host"
  hx rm "$import/manifest.json"
  before="$(snapshot)"
  role_fails import-no-manifest -e "paperless_import_dir=$import"
  expect_in_log import-no-manifest "manifest.json"
  [ "$(snapshot)" = "$before" ] || fail "the refused import without a manifest changed the host"
  docker cp "$out/export-t1/manifest.json" "$host:$import/manifest.json"

  load_images
  echo "== an export that Paperless' user cannot read must be refused before any change"
  # Copied as root (docker cp), as an export copied by hand often is.
  hx chmod 0600 "$import/manifest.json"
  before="$(snapshot)"
  role_fails import-unreadable -e "paperless_import_dir=$import"
  expect_in_log import-unreadable "cannot read: $import/manifest.json"
  expect_in_log import-unreadable "chown -R 1000:1000 $import"
  [ "$(snapshot)" = "$before" ] || fail "the refused import of an unreadable export changed the host"
  hx chmod 0644 "$import/manifest.json"

  echo "== a half-failed import must be refused until it is removed"
  # A manifest cut short: the importer fails after the stack started and the
  # database was made.
  hx sh -c "head -c 300 $import/manifest.json >$import/m && mv $import/m $import/manifest.json"
  import_vars=(-e "paperless_import_dir=$import" -e paperless_admin_user= -e paperless_admin_password=)
  # Removes the installation as the import's message says (and the record);
  # the exports stay.
  reset_import() {
    hx sh -c "cd $dir && docker compose down" >/dev/null 2>&1
    hx rm -rf "$dir/compose.yaml" "$dir/install-incomplete" "$dir/imported.yml" "$dir/data/media" "$dir/data/data" \
      "$dir/data/consume" "$dir/data/postgres" "$dir/data/redis"
  }
  play_fails import-failed "$here/converge.yml" "${import_vars[@]}"
  expect_in_log import-failed "The import of $import into Paperless $version in $dir failed (Fail when the import failed:"
  expect_in_log import-failed "Failed to parse manifest file"
  expect_in_log import-failed "docker compose down in $dir"
  expect_in_log import-failed "remove $dir/compose.yaml"
  expect_in_log import-failed "the subdirectories media, data, consume, postgres and redis of $dir/data"
  expect_in_log import-failed "keep $export_dir"
  expect_in_log import-failed "check that nothing in it is worth keeping"
  [ -z "$(hx sh -c "cd $dir && docker compose ps --quiet")" ] || fail "the failed import left containers running"
  containers_before="$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)"
  [ -n "$containers_before" ] || fail "the failed import removed its containers"
  play_fails import-incomplete "$here/converge.yml" "${import_vars[@]}"
  expect_in_log import-incomplete "not empty"
  expect_in_log import-incomplete "keep $export_dir"
  expect_unchanged import-incomplete
  hx sh -c "find $dir/data/postgres -name PG_VERSION | grep -q ." || fail "the refused run removed the database"
  [ "$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)" = "$containers_before" ] \
    || fail "the refused run created or removed containers"
  hx test ! -e "$dir/imported.yml" || fail "the failed import wrote a record"
  # As the message says, with the manifest made whole again; the export stays.
  reset_import
  docker cp "$out/export-t1/manifest.json" "$host:$import/manifest.json"

  echo "== import"
  converge "${import_vars[@]}"
  grep -q "import.yml" "$out/converge.log" || fail "the converge was not an import"
  expect_idempotent "${import_vars[@]}"
  play "$here/verify.yml" -e "verify_import_dir=$import" -e "verify_version=$version"
  [ "$(doc_count)" = 1 ] || fail "the import brought $(doc_count) documents, not 1"
  title="$(api /api/documents/ | python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["title"])')"
  [ "$title" = "$source_title" ] || fail "the imported document is titled $title, not $source_title"

  echo "== a marker left beside the import record must be refused, naming only the marker"
  # As a run that stopped between the record and the marker's removal leaves it.
  hx sh -c "printf 'version: %s\nsource: \"%s\"\n' '$version' '$import' >$dir/install-incomplete"
  play_fails import-done "$here/converge.yml" "${import_vars[@]}"
  expect_in_log import-done "$dir/imported.yml records that the import of $import completed"
  expect_in_log import-done "remove only the marker (rm $dir/install-incomplete)"
  if grep -qF -- "the subdirectories media" "$out/import-done.log"; then
    fail "the refusal of a recorded import says to remove the data"
  fi
  expect_unchanged import-done
  [ "$(doc_count)" = 1 ] || fail "the refused run changed the documents: $(doc_count)"
  hx rm "$dir/install-incomplete"

  echo "== an export made with a passphrase must be imported with it; a Samba that cannot start must not undo it"
  reset_import
  take_smb_port
  play_fails import-samba "$here/converge.yml" -vvv -e "paperless_import_dir=$encrypted" -e paperless_admin_user= \
    -e paperless_admin_password= -e "{\"paperless_import_passphrase\": \"$passphrase\"}"
  expect_in_log import-samba "is complete, but Samba did not start"
  expect_no_secrets import-samba
  hx test -e "$dir/imported.yml" || fail "the import with a failed Samba wrote no record"
  hx test ! -e "$dir/install-incomplete" || fail "the import with a failed Samba kept its marker"
  [ "$(webserver)" = "${images[0]} running healthy" ] || fail "the webserver after the failed Samba: $(webserver)"
  free_smb_port
  hx sh -c "cd $dir && docker compose up -d" >/dev/null 2>&1
  expect_idempotent -e "paperless_import_dir=$encrypted" -e paperless_admin_user= -e paperless_admin_password=
  [ "$(doc_count)" = 1 ] || fail "the import with a passphrase brought $(doc_count) documents, not 1"
  if hx grep -qF "$passphrase" "$dir/compose.yaml"; then fail "the passphrase is in the compose file"; fi
}


test_update() {
  echo "== an update must take a dump and a file snapshot and prune the oldest backups"
  new_host
  load_images
  load_set "${old_images[@]}"
  converge -e "paperless_version=$old_version"
  consume_sample
  [ "$(original_sum)" = "$sample_sum" ] || fail "the original of the document differs from sample.pdf"
  # Older backups; with the new one there are four, and three are kept.
  hx mkdir -p "$backups/20200101T000000Z-3.3.0" "$backups/20200101T000001Z-3.3.0" "$backups/20200101T000002Z-3.3.0"
  # With port 445 taken Samba cannot start after the update; that must not
  # roll back the healthy new version.
  hx sh -c "cd $dir && docker compose stop samba" >/dev/null 2>&1
  take_smb_port
  play_fails update-samba "$here/converge.yml"
  grep -q "update.yml" "$out/update-samba.log" || fail "the new version was not an update"
  expect_in_log update-samba "is updated and healthy, but Samba did not start"
  # The rollback's own message; a task name may hold the words too.
  if grep -qF -- "failed, rolled back to" "$out/update-samba.log"; then fail "a Samba that did not start rolled the update back"; fi
  hx test ! -e "$marker" || fail "a Samba that did not start wrote the marker: $(hx cat "$marker")"
  [ "$(webserver)" = "${images[0]} running healthy" ] || fail "the webserver after the update: $(webserver)"
  free_smb_port
  hx sh -c "cd $dir && docker compose up -d" >/dev/null 2>&1
  backup="$(hx sh -c "ls -d $backups/*-$old_version")"
  [ "$(printf '%s\n' "$backup" | wc -l | tr -d ' ')" = 1 ] || fail "not one backup of $old_version: $backup"
  hx test -s "$backup/paperless.dump" || fail "the backup $backup has no dump"
  hx test -d "$backup/data" || fail "the backup $backup has no data"
  hx sh -c "find $backup/media -name '*.pdf' | grep -q ." || fail "the backup $backup has no documents in media"
  hx test ! -e "$backups/20200101T000000Z-3.3.0" || fail "the oldest backup was not pruned"
  [ "$(hx ls "$backups" | wc -l | tr -d ' ')" = 3 ] || fail "the backups are not the newest three: $(hx ls "$backups")"
  [ "$(doc_count)" = 1 ] || fail "the update left $(doc_count) documents, not 1"
  [ "$(original_sum)" = "$sample_sum" ] || fail "the original of the document changed in the update"
  expect_idempotent
  play "$here/verify.yml"

  echo "== a downgrade, another PostgreSQL major and a second cluster must be refused before any change"
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  containers_before="$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)"
  unchanged() {
    expect_unchanged "$1"
    [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused run $1 changed the compose file"
    [ "$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)" = "$containers_before" ] \
      || fail "the refused run $1 created or removed containers"
  }
  play_fails downgrade "$here/converge.yml" -e "paperless_version=$old_version"
  expect_in_log downgrade "paperless_version $old_version is lower than the installed version $version"
  unchanged downgrade
  play_fails postgres-major "$here/converge.yml" -e paperless_postgres_image=docker.io/library/postgres:19
  expect_in_log postgres-major "is PostgreSQL 19, but the database"
  expect_in_log postgres-major "is PostgreSQL 18"
  unchanged postgres-major
  # An old cluster next to the current one, as a copy-mode pg_upgrade leaves it.
  hx sh -c "mkdir -p $dir/data/postgres/17/docker && echo 17 >$dir/data/postgres/17/docker/PG_VERSION"
  play_fails postgres-clusters "$here/converge.yml"
  expect_in_log postgres-clusters "more than one PostgreSQL cluster"
  expect_in_log postgres-clusters "$dir/data/postgres/17/docker/PG_VERSION (PostgreSQL 17)"
  expect_in_log postgres-clusters "$dir/data/postgres/18/docker/PG_VERSION (PostgreSQL 18)"
  unchanged postgres-clusters
  hx rm -r "$dir/data/postgres/17"
  [ "$(webserver)" = "${images[0]} running healthy" ] || fail "the webserver after the refusals: $(webserver)"
}

test_failed_update() {
  echo "== a failed update must roll back and block the failed version"
  new_host
  load_images
  load_set "${old_images[@]}"
  converge -e "paperless_version=$old_version"
  consume_sample
  # The new release of a test image is busybox, which exits at once.
  hx docker tag busybox:1.37 "test.invalid/paperless-ngx:$version"
  play_fails update-failed "$here/converge.yml" -vvv -e paperless_image=test.invalid/paperless-ngx -e paperless_health_timeout=30
  expect_in_log update-failed "update from $old_version to $version in $dir failed, rolled back to $old_version"
  expect_no_secrets update-failed
  # The health of the new version, in the message: Samba was still stopped.
  expect_in_log update-failed "samba exited"
  [ "$(hx sh -c "cd $dir && docker compose ps --format '{{.State}}' samba")" = running ] || fail "Samba does not run after the rollback"
  [ "$(webserver)" = "${old_images[0]} running healthy" ] || fail "the webserver after the rollback: $(webserver)"
  [ "$(doc_count)" = 1 ] || fail "the rollback left $(doc_count) documents, not 1"
  [ "$(original_sum)" = "$sample_sum" ] || fail "the original of the document changed in the rollback"
  hx grep -qx "failed_version: $version" "$marker" || fail "the marker does not name $version: $(hx cat "$marker")"
  hx grep -qx "rolled_back_to: $old_version" "$marker" || fail "the marker does not name $old_version: $(hx cat "$marker")"
  backup="$(hx sed -n 's/^backup: //p' "$marker")"
  hx test -s "$backup/paperless.dump" || fail "the marker's backup $backup has no dump"
  hx test -d "$backup-failed/media" || fail "the failed media was not moved to $backup-failed"

  echo "== a run with the failed version must change nothing"
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  containers_before="$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)"
  play_fails update-blocked "$here/converge.yml"
  expect_in_log update-blocked "$marker exists"
  expect_unchanged update-blocked
  [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused run changed the compose file"
  [ "$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)" = "$containers_before" ] \
    || fail "the refused run created or removed containers"

  echo "== the update must succeed once the marker is removed"
  hx rm "$marker"
  converge
  grep -q "update.yml" "$out/converge.log" || fail "the new version was not an update"
  [ "$(webserver)" = "${images[0]} running healthy" ] || fail "the webserver after the update: $(webserver)"
  [ "$(doc_count)" = 1 ] || fail "the update left $(doc_count) documents, not 1"
  [ "$(original_sum)" = "$sample_sum" ] || fail "the original of the document changed in the update"
  hx test ! -e "$marker" || fail "the update wrote a marker"
  expect_idempotent

  echo "== the marker of a failed rollback must refuse every version"
  # As update.yml writes it when the rollback failed too.
  hx sh -c "printf 'failed_version: 3.98.0\nrolled_back_to: null\nbackup: $backups/20200101T000000Z-$version\ntime: 2020-01-01T00:00:00Z\nrestore_error: test\n' >$marker"
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  containers_before="$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)"
  # A newer release than the failed one: it would back up what the failed
  # rollback left and remove the marker.
  play_fails rollback-blocked "$here/converge.yml" -e paperless_version=3.99.0
  expect_in_log rollback-blocked "$marker exists: the Paperless update to 3.98.0 failed"
  expect_in_log rollback-blocked "the data is in the backup $backups/20200101T000000Z-$version"
  expect_in_log rollback-blocked "The role refuses every version"
  if grep -qF -- "set paperless_version to another version" "$out/rollback-blocked.log"; then
    fail "the refusal after a failed rollback suggests another version"
  fi
  expect_unchanged rollback-blocked
  [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused run changed the compose file"
  [ "$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)" = "$containers_before" ] \
    || fail "the refused run created or removed containers"
  hx test -e "$marker" || fail "the refused run removed the marker"
}

# Sets the password of the database user paperless, as the refusal of a
# changed paperless_db_password says, over the local socket and through stdin:
# set_db_password <password>.
set_db_password() {
  local quote="'"
  printf "ALTER USER paperless PASSWORD '%s';\n" "${1//$quote/$quote$quote}" \
    | docker exec -i "$host" sh -c "cd $dir && docker compose exec -T db psql -q -U paperless -d postgres -v ON_ERROR_STOP=1" \
    || fail "cannot set the password of the database user"
}

# The containers of the compose project.
containers() { hx docker ps -aq --filter label=com.docker.compose.project=paperless; }
# Notes the compose file and the containers, for expect_untouched.
note_untouched() {
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  containers_before="$(containers)"
}
# Fails unless the refused run <name> changed nothing: its recap, the compose
# file and the containers since note_untouched.
expect_untouched() {
  expect_unchanged "$1"
  [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused run $1 changed the compose file"
  [ "$(containers)" = "$containers_before" ] || fail "the refused run $1 created or removed containers"
}
# Fails unless the one document is there with the original it was added with:
# expect_document <when>.
expect_document() {
  [ "$(doc_count)" = 1 ] || fail "$(doc_count) documents, not 1, $1"
  [ "$(original_sum)" = "$sample_sum" ] || fail "the original of the document changed $1"
}
# Fails when the marker of an update in progress or a copy of it is left:
# expect_no_progress <when>.
expect_no_progress() {
  local file
  for file in "$progress" "$progress_compose" "$progress_smb_conf" "$progress_samba_pass"; do
    hx test ! -e "$file" || fail "$file is left $1"
  done
}
# A converge that must fail within <seconds>: killed (and the test failed)
# when it is still running then. play_fails_within <seconds> <name>
# [ansible-playbook args...]; its output goes to $out/<name>.log.
play_fails_within() {
  local limit="$1" name="$2" pid rc=0
  shift 2
  set -m
  play "$@" >"$out/$name.log" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq "$limit"); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 -- "-$pid" 2>/dev/null || true
    wait "$pid" || true
    fail "converge $name still ran after $limit seconds: $(tail -n 5 "$out/$name.log")"
  fi
  wait "$pid" || rc=$?
  [ "$rc" != 0 ] || fail "converge $name succeeded but must fail"
}
# Waits until no Ansible module runs on the test host: one that a killed
# converge started finishes there, as on a host whose SSH session dropped.
# Five quiet seconds in a row: a docker exec sent just before the kill can
# start its module a moment later.
wait_modules() {
  local quiet=0
  for _ in $(seq 300); do
    if hx pgrep -f '[A]nsiballZ_' >/dev/null; then quiet=0; else quiet=$((quiet + 1)); fi
    [ "$quiet" -lt 5 ] || return 0
    sleep 1
  done
  fail "an Ansible module still runs on the test host after 300 seconds"
}
# A converge stopped as a dropped SSH session or a reboot stops it: run in the
# background in a process group of its own and killed with SIGKILL, the whole
# group, once the shell condition holds on the test host. play_killed <name>
# <condition> [converge options...]; its output goes to $out/<name>.log.
play_killed() {
  local name="$1" condition="$2" pid
  shift 2
  set -m
  play "$here/converge.yml" "$@" >"$out/$name.log" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 900); do
    if hx sh -c "$condition" >/dev/null 2>&1; then
      kill -9 -- "-$pid"
      wait "$pid" || true
      wait_modules
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      tail -n 40 "$out/$name.log" >&2
      fail "converge $name ended before it was killed at: $condition"
    fi
    sleep 0.5
  done
  kill -9 -- "-$pid" 2>/dev/null || true
  wait "$pid" || true
  fail "converge $name did not reach within the wait: $condition"
}

test_refusals() {
  echo "== a changed database password must be refused before any change"
  new_host
  load_images
  # Without Samba and Tika: the refusals do not need them.
  small_vars=(-e '{"paperless_samba": false, "paperless_tika": false}')
  converge "${small_vars[@]}"
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  containers_before="$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)"
  unchanged() {
    expect_unchanged "$1"
    [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused run $1 changed the compose file"
    [ "$(hx docker ps -aq --filter label=com.docker.compose.project=paperless)" = "$containers_before" ] \
      || fail "the refused run $1 created or removed containers"
  }
  play_fails db-password "$here/converge.yml" -vvv "${small_vars[@]}" -e "paperless_db_password=$rotated_db_password" \
    -e paperless_health_timeout=60
  expect_in_log db-password "paperless_db_password differs from the password in $dir/compose.yaml, and the database does not take it"
  expect_in_log db-password "ALTER USER"
  expect_no_secrets db-password
  unchanged db-password
  [ "$(webserver)" = "${images[0]} running healthy" ] || fail "the webserver after the refused run: $(webserver)"

  echo "== a compose file that is not YAML must be refused without showing a line of it"
  hx cp -p "$dir/compose.yaml" /root/compose.yaml
  # The line of the database password, as a hand edit could break it.
  hx sed -i 's/^\( *POSTGRES_PASSWORD: .*\)$/\1 broken/' "$dir/compose.yaml"
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  play_fails compose-not-yaml "$here/converge.yml" -vvv "${small_vars[@]}"
  expect_in_log compose-not-yaml "$dir/compose.yaml is not YAML"
  expect_no_secrets compose-not-yaml
  unchanged compose-not-yaml
  if grep -qF -- "broken" "$out/compose-not-yaml.log"; then
    fail "the refusal shows a line of the compose file: $(grep -nF -- broken "$out/compose-not-yaml.log" | head -n 3 | cut -c1-80)"
  fi
  hx cp -p /root/compose.yaml "$dir/compose.yaml"
  expect_idempotent "${small_vars[@]}"

  echo "== a password changed in the database as the refusal says must be taken"
  set_db_password "$rotated_db_password"
  converge -v "${small_vars[@]}" -e "paperless_db_password=$rotated_db_password"
  expect_no_secrets converge
  grep -q "reconfigure.yml" "$out/converge.log" || fail "the new password was not a reconfigure"
  [ "$(webserver)" = "${images[0]} running healthy" ] || fail "the webserver after the new password: $(webserver)"
  api /api/documents/ >/dev/null || fail "the API does not answer after the new password"
  expect_idempotent "${small_vars[@]}" -e "paperless_db_password=$rotated_db_password"
}

test_missing_data() {
  echo "== left-over data without a compose file must be refused before any change"
  new_host
  hx mkdir -p "$dir/data/postgres"
  tree() { hx sh -c "find $dir -exec stat -c '%n %a %u %g %s %Y' {} + | sort"; }
  before="$(tree)"
  role_fails leftover
  expect_in_log leftover "left-over data"
  expect_in_log leftover "$dir/data (postgres)"
  expect_unchanged leftover
  [ "$(tree)" = "$before" ] || fail "the refused run changed $dir"
  hx rm -rf "$dir"

  echo "== a missing data volume must be refused in every state and nothing created"
  load_images
  converge
  hx sh -c "cd $dir && docker compose stop" >/dev/null 2>&1
  # As an unmounted volume leaves it: its mountpoint, empty.
  hx mv "$dir/data" "$dir/data.away"
  hx mkdir "$dir/data"
  if hx sh -c "cd $dir && docker compose start" >"$out/start-missing.log" 2>&1; then
    fail "docker compose start succeeded without the data directories"
  fi
  [ -z "$(hx sh -c "cd $dir && docker compose ps --quiet")" ] || fail "a container runs without the data directories"
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  # missing_refused <name> [extra vars...]
  missing_refused() {
    local name="$1"
    shift
    play_fails "$name" "$here/converge.yml" "$@"
    expect_in_log "$name" "$dir/data lacks media, data, consume, postgres, redis"
    expect_in_log "$name" "is the volume mounted?"
    expect_unchanged "$name"
    [ -z "$(hx ls -A "$dir/data")" ] || fail "the refused run $name created in $dir/data: $(hx ls -A "$dir/data")"
    [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused run $name changed the compose file"
    [ -z "$(hx sh -c "cd $dir && docker compose ps --quiet")" ] || fail "the refused run $name started a container"
  }
  # A run without changes, a reconfigure (another share setting), an update
  # (a newer version) and an import.
  missing_refused missing-data
  missing_refused missing-data-reconfigure -e paperless_samba_min_protocol=SMB3
  missing_refused missing-data-update -e paperless_version=3.99.0
  missing_refused missing-data-import -e "paperless_import_dir=$import"

  echo "== with the data back the installation must run as before"
  hx rmdir "$dir/data"
  hx mv "$dir/data.away" "$dir/data"
  hx sh -c "cd $dir && docker compose start" >/dev/null 2>&1
  expect_idempotent
}

test_mountpoint() {
  echo "== paperless_data_dir_mountpoint must refuse a data directory that is not a mountpoint"
  new_host
  mountpoint_vars=(-e '{"paperless_data_dir_mountpoint": true, "paperless_samba": false, "paperless_tika": false}')
  role_fails not-mountpoint "${mountpoint_vars[@]}"
  expect_in_log not-mountpoint "$dir/data is not a mountpoint"
  expect_in_log not-mountpoint "is the volume mounted?"
  hx test ! -e "$dir" || fail "the refused run created $dir"
  hx mkdir -p "$dir/data"
  role_fails not-mountpoint-dir "${mountpoint_vars[@]}"
  expect_in_log not-mountpoint-dir "$dir/data is not a mountpoint"
  [ -z "$(hx ls -A "$dir/data")" ] || fail "the refused run created in $dir/data: $(hx ls -A "$dir/data")"
  [ "$(hx ls -A "$dir")" = data ] || fail "the refused run created in $dir: $(hx ls -A "$dir")"

  echo "== install onto a mountpoint, without Samba and Tika"
  hx mount -t tmpfs tmpfs "$dir/data"
  load_images
  converge "${mountpoint_vars[@]}"
  hx mountpoint -q "$dir/data" || fail "$dir/data is no longer a mountpoint"
  hx sh -c "find $dir/data/postgres -name PG_VERSION | grep -q ." || fail "the database is not on the mountpoint"
  services="$(hx sh -c "cd $dir && docker compose ps --all --format '{{.Service}}'" | sort | tr '\n' ' ')"
  [ "$services" = "broker db webserver " ] || fail "the services without Samba and Tika: $services"
  if hx docker ps --format '{{.Ports}}' | grep -q ':445'; then fail "port 445 is published without Samba"; fi
  hx test ! -e "$dir/smb.conf" || fail "smb.conf was written without Samba"
  expect_idempotent "${mountpoint_vars[@]}"
}

# The new release as test.invalid/paperless-ngx with a migration that its web
# server start does not apply: copied into place by the start of the web
# server, after the migrations of the start, so Paperless answers and its
# container turns healthy while the database lacks the migration, as a
# migration that failed unnoticed leaves it.
build_unmigrated() {
  if ! docker exec -i "$host" docker build -q --build-arg "base=${images[0]}" -t "test.invalid/paperless-ngx:$version" - >/dev/null <<'EOF'; then
ARG base
FROM $base
RUN set -eu; \
    leaf="$(ls documents/migrations | sed -n 's/^\([0-9][0-9]*_.*\)\.py$/\1/p' | sort | tail -n 1)"; \
    printf 'from django.db import migrations\n\n\nclass Migration(migrations.Migration):\n    dependencies = [("documents", "%s")]\n    operations = []\n' "$leaf" >/opt/test-unapplied.py; \
    run=/etc/s6-overlay/s6-rc.d/svc-webserver/run; \
    grep -qx 'cd ${PAPERLESS_SRC_DIR}' "$run"; \
    sed -i 's|^cd ${PAPERLESS_SRC_DIR}$|&\ncp /opt/test-unapplied.py documents/migrations/9999_test_unapplied.py|' "$run"; \
    grep -qx 'cp /opt/test-unapplied.py documents/migrations/9999_test_unapplied.py' "$run"
EOF
    fail "cannot build the test image with a migration that is not applied"
  fi
}

test_db_check() {
  echo "== an update that leaves the database unusable for Paperless must be rolled back"
  new_host
  load_images
  load_set "${old_images[@]}"
  converge -e "paperless_version=$old_version"
  consume_sample
  build_unmigrated
  play_fails db-check "$here/converge.yml" -v -e paperless_image=test.invalid/paperless-ngx -e paperless_health_timeout=300
  expect_in_log db-check "update from $old_version to $version in $dir failed, rolled back to $old_version"
  expect_in_log db-check "database check failed: manage.py migrate --check found a migration that is not applied"
  expect_no_secrets db-check
  [ "$(webserver)" = "${old_images[0]} running healthy" ] || fail "the webserver after the rollback: $(webserver)"
  hx grep -qx "failed_version: $version" "$marker" || fail "the marker does not name $version: $(hx cat "$marker")"
  hx grep -qx "rolled_back_to: $old_version" "$marker" || fail "the marker does not name $old_version: $(hx cat "$marker")"
  expect_no_progress "after the rollback"
  expect_document "after the rollback of an update with a migration that is not applied"

  echo "== a run without changes must fail within the health timeout while the database does not answer"
  # A successful run with another version removes the marker.
  converge -e "paperless_version=$old_version"
  expect_idempotent -e "paperless_version=$old_version"
  # The postmaster stopped from the test host, as a database that hangs: the
  # container runs and stays healthy for a minute (until its check has timed
  # out six times), while no new connection gets an answer.
  db_pid="$(hx docker inspect --format '{{.State.Pid}}' "$(hx sh -c "cd $dir && docker compose ps --quiet db")")"
  hx kill -STOP "$db_pid"
  play_fails_within 180 noop-db-down "$here/converge.yml" -v -e "paperless_version=$old_version" -e paperless_health_timeout=30
  hx kill -CONT "$db_pid"
  expect_in_log noop-db-down "Paperless in $dir is unhealthy"
  # The message says what bounds the check: the health timeout, and at least
  # 10 seconds for each database check.
  expect_in_log noop-db-down "within 30 seconds, at least 10 for each database check"
  expect_in_log noop-db-down "database check failed: manage.py migrate --check did not finish within"
  expect_no_secrets noop-db-down
  expect_unchanged noop-db-down
  # The bound the check had: the rest of paperless_health_timeout.
  seconds="$(sed -n 's/.*migrate --check did not finish within \([0-9]*\) seconds.*/\1/p' "$out/noop-db-down.log" | head -n 1)"
  { [ -n "$seconds" ] && [ "$seconds" -le 30 ]; } || fail "the database check was not bounded by paperless_health_timeout=30: ${seconds:-no time} seconds"
  expect_idempotent -e "paperless_version=$old_version"
}

# Fails unless the refusal <name> of an interrupted update from $old_version
# to $version names the backup <backup> and both ways out.
expect_interrupted_refusal() {
  expect_in_log "$1" "$progress exists: the Paperless update from $old_version to $version did not finish"
  expect_in_log "$1" "the backup from before it is $2"
  expect_in_log "$1" "set paperless_restore_interrupted: true for one run to restore it"
  expect_in_log "$1" "or remove $progress to keep Paperless as it is now"
}
# The restore of an interrupted update with paperless_restore_interrupted:
# $old_version healthy again with the document, the marker and its copies
# gone, the compose file back at $old_version. expect_restored <name>
# [converge options...].
expect_restored() {
  local name="$1"
  shift
  play "$here/converge.yml" -vvv -e paperless_restore_interrupted=true "$@" >"$out/$name.log" 2>&1 \
    || { tail -n 60 "$out/$name.log" >&2; fail "the restore $name failed"; }
  expect_no_secrets "$name"
  expect_in_log "$name" "Paperless in $dir runs $old_version again"
  # The first change of an update to the running Paperless.
  if grep -qF "Stop the webserver and Samba for the update" "$out/$name.log"; then fail "the restore $name tried the update again"; fi
  [ "$(webserver)" = "${old_images[0]} running healthy" ] || fail "the webserver after the restore $name: $(webserver)"
  expect_document "after the restore $name"
  expect_no_progress "after the restore $name"
  hx grep -qF "paperless-ngx:$old_version" "$dir/compose.yaml" || fail "the compose file does not name $old_version after the restore $name"
}

# The marker of an update in progress beside update-failed of the same
# backup, as a rescue leaves them that wrote update-failed and was killed
# before it removed the marker of the update in progress: both_markers
# <failed version>.
both_markers() {
  hx sh -c "printf 'from_version: $old_version\nto_version: $version\nstep: update\nbackup: $backups/20260101T000000Z-$old_version\ntime: 2026-01-01T00:00:00Z\n' >$progress"
  hx cp -p "$dir/compose.yaml" "$progress_compose"
  hx sh -c "printf 'failed_version: $1\nrolled_back_to: $old_version\nbackup: $backups/20260101T000000Z-$old_version\ntime: 2026-01-01T00:00:00Z\n' >$marker"
}
# Fails unless the healthy update <name> removed the marker of the update in
# progress before its copies, so that a run stopped in between leaves no
# marker of an update that finished.
expect_marker_removed_first() {
  local first
  first="$(awk '/^TASK \[.*: Remove the marker of the update in progress\]/ { on = 1; next } /^TASK \[/ { on = 0 } on && /item=/' "$out/$1.log" | head -n 1)"
  [[ "$first" == *"(item=$progress)"* ]] || fail "the update $1 did not remove $progress first: ${first:-no removal}"
}

# Fails unless the restored directory <dir> has the owner and mode of the
# backup's <backup dir>: expect_same_owner <dir> <backup dir>.
expect_same_owner() {
  [ "$(hx stat -c '%u:%g %a' "$1")" = "$(hx stat -c '%u:%g %a' "$2")" ] \
    || fail "$1 is $(hx stat -c '%u:%g %a' "$1"), not $(hx stat -c '%u:%g %a' "$2") as $2"
}
# Fails unless every entry of the list <entries> (one per line) is in the
# directory <dir>: expect_entries_in <dir> <entries>.
expect_entries_in() {
  local entry
  [ -n "$2" ] || fail "no entries to look for in $1"
  while IFS= read -r entry; do
    hx test -e "$1/$entry" || fail "$1 lacks $entry: $(hx ls -A "$1")"
  done <<<"$2"
}
# Makes an entry of the failed attempt that cannot be renamed in the
# directory <dir>: a mountpoint (EBUSY), as a full disk or an immutable file
# would stop a move. Sets busy (its path) and busy_before (the other
# entries, which sort before it and so are set aside first): busy_entry <dir>.
busy_entry() {
  busy="$1/zz-noix-busy"
  hx sh -c "mkdir $busy && echo failed-attempt >$busy/file && mount --bind $busy $busy"
  busy_before="$(hx sh -c "cd $1 && for e in *; do [ \"\$e\" = zz-noix-busy ] || echo \"\$e\"; done")"
}

test_interrupted() {
  echo "== paperless_restore_interrupted without an interrupted update must be refused"
  new_host
  load_images
  load_set "${old_images[@]}"
  converge -e "paperless_version=$old_version"
  consume_sample
  note_untouched
  play_fails restore-no-marker "$here/converge.yml" -e paperless_restore_interrupted=true
  expect_in_log restore-no-marker "paperless_restore_interrupted is set, but there is no interrupted update in $dir; remove the variable"
  expect_untouched restore-no-marker

  echo "== a marker of an update in progress that the role did not write must be refused"
  hx sh -c "echo 'not: [yaml' >$progress"
  play_fails bad-marker "$here/converge.yml"
  expect_in_log bad-marker "$progress exists, but it is not YAML or lacks step or to_version"
  expect_untouched bad-marker
  hx sh -c "printf 'from_version: $old_version\n' >$progress"
  play_fails bad-marker-keys "$here/converge.yml"
  expect_in_log bad-marker-keys "$progress exists, but it is not YAML or lacks step or to_version"
  expect_untouched bad-marker-keys
  hx sh -c "printf 'from_version: $old_version\nto_version: $version\nstep: update\ntime: 2026-01-01T00:00:00Z\n' >$progress"
  play_fails bad-marker-backup "$here/converge.yml"
  expect_in_log bad-marker-backup "$progress exists, but it is not YAML or lacks step or to_version"
  expect_untouched bad-marker-backup
  hx rm "$progress"
  # One that cannot be read: refused as well, and its copy stays.
  hx mkdir "$progress"
  hx sh -c "umask 077; echo stale >$progress_compose"
  play_fails unreadable-marker "$here/converge.yml"
  expect_in_log unreadable-marker "$progress exists, but it is not YAML or lacks step or to_version"
  expect_untouched unreadable-marker
  hx test -e "$progress_compose" || fail "the refused run unreadable-marker removed $progress_compose"
  hx rm -r "$progress" "$progress_compose"

  echo "== beside update-failed, the marker of an update in progress must be removed and update-failed decide"
  both_markers "$version"
  # With paperless_restore_interrupted, the variable is refused first (the
  # rollback ran, so there is nothing to restore), and as a refusal of
  # state.yml it leaves both markers.
  markers_before="$(hx sha256sum "$marker" "$progress" "$progress_compose")"
  play_fails both-markers-restore "$here/converge.yml" -e paperless_restore_interrupted=true
  expect_in_log both-markers-restore "paperless_restore_interrupted is set, but there is no interrupted update in $dir; remove the variable"
  expect_untouched both-markers-restore
  [ "$(hx sha256sum "$marker" "$progress" "$progress_compose")" = "$markers_before" ] \
    || fail "the refused run both-markers-restore changed $marker, $progress or $progress_compose"
  play_fails both-markers "$here/converge.yml"
  expect_in_log both-markers "$marker exists: the Paperless update to $version failed"
  expect_in_log both-markers "rolled back to $old_version"
  if grep -qF "paperless_restore_interrupted does not apply" "$out/both-markers.log"; then
    fail "the refusal both-markers names paperless_restore_interrupted, which is not set"
  fi
  expect_no_progress "beside update-failed"
  hx test -e "$marker" || fail "the run removed $marker"
  [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused run both-markers changed the compose file"
  [ "$(containers)" = "$containers_before" ] || fail "the refused run both-markers created or removed containers"
  # A run that another refusal stops (here: another PostgreSQL major) keeps
  # both markers; one that gets past every refusal removes the marker of the
  # update in progress, and, as it succeeds, update-failed of another version.
  both_markers 99.0.0
  markers_before="$(hx sha256sum "$marker" "$progress" "$progress_compose")"
  play_fails both-markers-refused "$here/converge.yml" -e "paperless_version=$old_version" \
    -e paperless_postgres_image=docker.io/library/postgres:19
  expect_in_log both-markers-refused "is PostgreSQL 19, but the database"
  expect_untouched both-markers-refused
  [ "$(hx sha256sum "$marker" "$progress" "$progress_compose")" = "$markers_before" ] \
    || fail "the refused run both-markers-refused changed $marker, $progress or $progress_compose"
  converge -v -e "paperless_version=$old_version"
  expect_no_progress "after a run beside update-failed of the same backup"
  hx test ! -e "$marker" || fail "the successful run kept $marker of another version"
  expect_idempotent -e "paperless_version=$old_version"

  echo "== an update in progress beside an install or import in progress must be refused, naming both files"
  hx sh -c "printf 'from_version: $old_version\nto_version: $version\nstep: update\nbackup: $backups/20260101T000000Z-$old_version\ntime: 2026-01-01T00:00:00Z\n' >$progress"
  hx cp -p "$dir/compose.yaml" "$progress_compose"
  hx sh -c "printf 'version: %s\nsource: \"%s\"\n' '$old_version' '$import' >$dir/install-incomplete"
  progress_sum="$(hx sha256sum "$progress" "$progress_compose" "$dir/install-incomplete")"
  play_fails both-install "$here/converge.yml"
  expect_in_log both-install "$progress and $dir/install-incomplete both exist"
  expect_untouched both-install
  [ "$(hx sha256sum "$progress" "$progress_compose" "$dir/install-incomplete")" = "$progress_sum" ] \
    || fail "the refused run both-install changed the markers or the copy"
  # With the variable: the same refusal.
  play_fails both-install-restore "$here/converge.yml" -e paperless_restore_interrupted=true
  expect_in_log both-install-restore "$progress and $dir/install-incomplete both exist"
  expect_untouched both-install-restore
  hx rm "$progress" "$progress_compose" "$dir/install-incomplete"

  echo "== an update killed once its compose file names $version must be refused until it is restored"
  # With the Samba files changed as well, which the restore puts back.
  play_killed interrupted "grep -qF 'paperless-ngx:$version' $dir/compose.yaml && grep -qx '   server min protocol = SMB3' $dir/smb.conf" \
    -vvv -e paperless_samba_min_protocol=SMB3
  expect_no_secrets interrupted
  hx grep -qx "step: update" "$progress" || fail "the marker does not record the step update: $(hx cat "$progress")"
  hx grep -qx "from_version: $old_version" "$progress" || fail "the marker does not name $old_version: $(hx cat "$progress")"
  hx grep -qx "to_version: $version" "$progress" || fail "the marker does not name $version: $(hx cat "$progress")"
  backup="$(hx sed -n 's/^backup: //p' "$progress")"
  [ "$(hx head -c 5 "$backup/paperless.dump")" = PGDMP ] || fail "the marker's backup $backup has no dump"
  for file in "$progress" "$progress_compose" "$progress_smb_conf" "$progress_samba_pass"; do
    [ "$(hx stat -c '%a %U' "$file" 2>&1)" = "600 root" ] || fail "$file is not root's with mode 0600: $(hx stat -c '%a %U' "$file" 2>&1)"
  done
  hx cmp -s "$progress_compose" "$backup/compose.yaml" || fail "$progress_compose is not the compose file from before the update"
  hx grep -qx '   server min protocol = SMB2' "$progress_smb_conf" || fail "$progress_smb_conf is not the Samba configuration from before the update"
  hx grep -qx '   server min protocol = SMB3' "$dir/smb.conf" || fail "the killed update did not write the new Samba configuration"
  note_untouched
  play_fails interrupted-refused "$here/converge.yml" -vvv
  expect_interrupted_refusal interrupted-refused "$backup"
  expect_no_secrets interrupted-refused
  expect_untouched interrupted-refused

  echo "== beside update-failed of another update, the marker of an update in progress must still be refused"
  # As an earlier update to another version leaves it that was rolled back:
  # it stays through updates to other versions.
  hx sh -c "printf 'failed_version: 99.0.0\nrolled_back_to: $old_version\nbackup: $backups/20200101T000000Z-$old_version\ntime: 2020-01-01T00:00:00Z\n' >$marker"
  markers_before="$(hx sha256sum "$marker" "$progress" "$progress_compose" "$progress_smb_conf" "$progress_samba_pass")"
  play_fails other-update-failed "$here/converge.yml" -vvv
  expect_interrupted_refusal other-update-failed "$backup"
  expect_no_secrets other-update-failed
  expect_untouched other-update-failed
  [ "$(hx sha256sum "$marker" "$progress" "$progress_compose" "$progress_smb_conf" "$progress_samba_pass")" = "$markers_before" ] \
    || fail "the refused run other-update-failed changed $marker, $progress or its copies"
  # One of another backup that refuses this version: with
  # paperless_restore_interrupted, it comes first and says to deal with it,
  # then restore the interrupted update with the variable.
  hx sh -c "printf 'failed_version: $version\nrolled_back_to: $old_version\nbackup: $backups/20200101T000000Z-$old_version\ntime: 2020-01-01T00:00:00Z\n' >$marker"
  markers_before="$(hx sha256sum "$marker" "$progress" "$progress_compose")"
  play_fails other-update-failed-restore "$here/converge.yml" -e paperless_restore_interrupted=true
  expect_in_log other-update-failed-restore "paperless_restore_interrupted does not apply while $marker exists: deal with it first as said, then run the role again with the variable"
  expect_untouched other-update-failed-restore
  [ "$(hx sha256sum "$marker" "$progress" "$progress_compose")" = "$markers_before" ] \
    || fail "the refused run other-update-failed-restore changed $marker, $progress or $progress_compose"
  hx sh -c "printf 'failed_version: 99.0.0\nrolled_back_to: $old_version\nbackup: $backups/20200101T000000Z-$old_version\ntime: 2020-01-01T00:00:00Z\n' >$marker"
  # A copy of the compose file that cannot be read (here: a directory) fails
  # the restore with a message of its own, before any change.
  hx mkdir "$dir/copy-dir"
  play_fails unreadable-copy "$here/converge.yml" -vvv -e paperless_restore_interrupted=true \
    -e "paperless_update_marker_compose=$dir/copy-dir"
  expect_in_log unreadable-copy "Reading $dir/copy-dir, the copy of a file from before the interrupted update, failed"
  expect_no_secrets unreadable-copy
  expect_untouched unreadable-copy
  # So does a copy of a Samba file that exists but cannot be read: it is not
  # taken for one the previous version did not have.
  play_fails unreadable-smb-copy "$here/converge.yml" -vvv -e paperless_restore_interrupted=true \
    -e "paperless_update_marker_smb_conf=$dir/copy-dir"
  expect_in_log unreadable-smb-copy "Reading $dir/copy-dir, the copy of a file from before the interrupted update, failed"
  expect_no_secrets unreadable-smb-copy
  expect_untouched unreadable-smb-copy
  hx test -e "$dir/smb.conf" || fail "the refused run unreadable-smb-copy removed $dir/smb.conf"
  hx rmdir "$dir/copy-dir"
  # As a restore leaves it that was stopped while it put the data and media
  # back: the webserver stopped, the copies of the backup's made, what was
  # there set aside, nothing put back yet. The next restore puts them back
  # all the same.
  hx sh -c "cd $dir && docker compose stop webserver" >/dev/null 2>&1
  set_aside_data="$(hx ls -A "$dir/data/data")"
  set_aside_media="$(hx ls -A "$dir/data/media")"
  hx sh -c "cp -a $backup/data $dir/data/.data.restore && cp -al $backup/media $dir/data/.media.restore \
    && mkdir -m 0700 $backup-failed $backup-failed/data $backup-failed/media \
    && find $dir/data/data -mindepth 1 -maxdepth 1 -exec mv {} $backup-failed/data/ \; \
    && find $dir/data/media -mindepth 1 -maxdepth 1 -exec mv {} $backup-failed/media/ \;"
  # Beside update-failed of another version, which the healthy restore
  # removes as any run that succeeds.
  expect_restored interrupted-restore
  hx test ! -e "$marker" || fail "the restore kept $marker of another version"
  for d in data media; do
    hx test ! -e "$dir/data/.$d.restore" || fail "the restore left $dir/data/.$d.restore"
    expect_same_owner "$dir/data/$d" "$backup/$d"
  done
  # What the stopped restore set aside stays there.
  expect_entries_in "$backup-failed/data" "$set_aside_data"
  expect_entries_in "$backup-failed/media" "$set_aside_media"
  hx grep -qx '   server min protocol = SMB2' "$dir/smb.conf" || fail "the restore did not put the Samba configuration back"

  echo "== an update killed during its rollback must be refused until it is restored"
  hx docker tag busybox:1.37 "test.invalid/paperless-ngx:$version"
  play_killed interrupted-rollback \
    "backup=\$(sed -n 's/^backup: //p' $progress) && [ -n \"\$backup\" ] && [ -e \"\$backup-failed\" ]" \
    -vvv -e paperless_image=test.invalid/paperless-ngx -e paperless_health_timeout=30
  expect_no_secrets interrupted-rollback
  # The killed run was the first one without the variable after the
  # restore, so it tried the update to $version again (into the failed
  # start and its rollback).
  grep -qF "Stop the webserver and Samba for the update" "$out/interrupted-rollback.log" \
    || fail "the run after the restore of $old_version did not update to $version"
  hx test ! -e "$marker" || fail "the killed rollback wrote $marker: $(hx cat "$marker")"
  hx grep -qx "step: update" "$progress" || fail "the marker does not record the step update: $(hx cat "$progress")"
  backup="$(hx sed -n 's/^backup: //p' "$progress")"
  note_untouched
  play_fails rollback-refused "$here/converge.yml" -vvv
  expect_interrupted_refusal rollback-refused "$backup"
  expect_no_secrets rollback-refused
  expect_untouched rollback-refused
  expect_restored rollback-restore
  hx test -d "$backup-failed" || fail "the data of the failed attempt in $backup-failed are gone"
  # The rollback that was stopped had set them aside already, so the ones
  # found by the restore went to a directory of their own.
  [ -n "$(hx sh -c "ls -d $backup-failed-*")" ] || fail "the restore after the stopped rollback kept no $backup-failed-<time>"

  echo "== an update whose copies cannot be written must fail before the backup with a message of its own"
  play_fails copy-fails "$here/converge.yml" -vvv -e paperless_update_marker_compose=/nonexistent/compose.yaml
  expect_in_log copy-fails "failed before anything changed"
  expect_in_log copy-fails "Writing /nonexistent/compose.yaml, $progress_smb_conf, $progress_samba_pass, the copies of the files from before the update, failed"
  expect_no_secrets copy-fails
  expect_no_progress "after the update whose copies failed"
  [ "$(webserver)" = "${old_images[0]} running healthy" ] || fail "the webserver after the update whose copies failed: $(webserver)"

  echo "== an update killed during its backup must be cleaned up and done by the next run"
  play_killed interrupted-backup "ls -d $backups/*.partial" -v
  expect_no_secrets interrupted-backup
  hx grep -qx "step: backup" "$progress" || fail "the marker does not record the step backup: $(hx cat "$progress")"
  converge -v
  expect_no_secrets converge
  grep -q "update.yml" "$out/converge.log" || fail "the run after the interrupted backup was not an update"
  expect_marker_removed_first converge
  [ "$(webserver)" = "${images[0]} running healthy" ] || fail "the webserver after the update: $(webserver)"
  if hx sh -c "ls -d $backups/*.partial" >/dev/null 2>&1; then
    fail "the update left a partial backup: $(hx ls "$backups")"
  fi
  expect_no_progress "after the update"
  expect_document "after the update that followed the interrupted backup"
  expect_idempotent

  echo "== a restore of an interrupted update that fails must record a failed rollback"
  # The installed release under a name that is then untagged: the restore
  # cannot start it again (no such registry), after the database was
  # recreated and loaded. The newer release is busybox under that name.
  new_pin=3.4.3
  hx docker tag "${images[0]}" "test.invalid/paperless-ngx:$version"
  hx docker tag busybox:1.37 "test.invalid/paperless-ngx:$new_pin"
  converge -e "paperless_version=$version" -e paperless_image=test.invalid/paperless-ngx
  play_killed interrupted-failing "grep -qF 'test.invalid/paperless-ngx:$new_pin' $dir/compose.yaml" -v \
    -e "paperless_version=$new_pin" -e paperless_image=test.invalid/paperless-ngx
  expect_no_secrets interrupted-failing
  backup="$(hx sed -n 's/^backup: //p' "$progress")"
  [ -n "$backup" ] || fail "the killed update left no marker with a backup: $(hx cat "$progress" 2>&1)"
  hx docker rmi "test.invalid/paperless-ngx:$version" >/dev/null
  play_fails restore-failed "$here/converge.yml" -vvv -e "paperless_version=$new_pin" -e paperless_image=test.invalid/paperless-ngx \
    -e paperless_restore_interrupted=true -e paperless_health_timeout=60
  expect_in_log restore-failed "Restoring Paperless $version in $dir from the backup $backup after the interrupted update to $new_pin failed"
  expect_in_log restore-failed "Roll back by hand in $dir"
  expect_no_secrets restore-failed
  hx grep -qx "failed_version: $new_pin" "$marker" || fail "the marker does not name $new_pin: $(hx cat "$marker" 2>&1)"
  hx grep -qx "rolled_back_to: null" "$marker" || fail "the marker does not record a failed rollback: $(hx cat "$marker")"
  hx grep -qx "backup: $backup" "$marker" || fail "the marker does not name the backup $backup: $(hx cat "$marker")"
  hx grep -q "^restore_error: ." "$marker" || fail "the marker records no restore error: $(hx cat "$marker")"
  expect_no_progress "after the failed restore"
  note_untouched
  play_fails restore-failed-blocked "$here/converge.yml" -e "paperless_version=$new_pin" -e paperless_image=test.invalid/paperless-ngx
  expect_in_log restore-failed-blocked "$marker exists: the Paperless update to $new_pin failed"
  expect_in_log restore-failed-blocked "The role refuses every version"
  expect_untouched restore-failed-blocked

  echo "== a restore that cannot set an entry of media aside must fail and keep what the failed attempt left"
  # An interrupted update to $version from a backup of $old_version, beside
  # no update-failed.
  hx rm "$marker"
  backup="$(hx sh -c "ls -d $backups/*-$old_version | tail -n 1")"
  hx sh -c "printf 'from_version: $old_version\nto_version: $version\nstep: update\nbackup: $backup\ntime: 2026-01-01T00:00:00Z\n' >$progress \
    && cp -p $backup/compose.yaml $progress_compose && cp -p $dir/smb.conf $progress_smb_conf && cp -p $dir/samba-pass $progress_samba_pass"
  busy_entry "$dir/data/media"
  play_fails restore-busy "$here/converge.yml" -e "paperless_version=$new_pin" -e paperless_image=test.invalid/paperless-ngx \
    -e paperless_restore_interrupted=true
  expect_in_log restore-busy "Restoring Paperless $old_version in $dir from the backup $backup after the interrupted update to $version failed (Put the data and media directories back:"
  [ "$(hx cat "$busy/file")" = failed-attempt ] || fail "the entry that could not be set aside lost its content"
  expect_entries_in "$backup-failed/media" "$busy_before"
  hx test -d "$dir/data/.media.restore" || fail "the copy was put in place although an entry was not set aside"
}

# All scenarios by default; NOIXDEV_INFRA_PAPERLESS_TESTS="update failed_update"
# runs only these (import needs install in the same run).
for scenario in ${NOIXDEV_INFRA_PAPERLESS_TESTS:-settings install import update failed_update refusals missing_data mountpoint db_check interrupted}; do
  case "$scenario" in
    settings | install | import | update | failed_update | refusals | missing_data | mountpoint | db_check | interrupted) "test_$scenario" ;;
    *) fail "unknown scenario $scenario (settings, install, import, update, failed_update, refusals, missing_data, mountpoint, db_check, interrupted)" ;;
  esac
done

noix_done
echo "== all paperless tests passed"
