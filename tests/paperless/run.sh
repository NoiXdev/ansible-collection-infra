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
# the import with a passphrase and the failed update run at -vvv, and their
# output must not hold a test secret.
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
trap cleanup EXIT

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
ln -sfn "$root" "$tests/output/ansible_collections/noixdev/infra"
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
  docker run -d --privileged --name "$host" docker:29-dind >/dev/null
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
  if grep -qF -- "rolled back" "$out/update-samba.log"; then fail "a Samba that did not start rolled the update back"; fi
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

# All scenarios by default; NOIXDEV_INFRA_PAPERLESS_TESTS="update failed_update"
# runs only these (import needs install in the same run).
for scenario in ${NOIXDEV_INFRA_PAPERLESS_TESTS:-settings install import update failed_update refusals missing_data mountpoint}; do
  case "$scenario" in
    settings | install | import | update | failed_update | refusals | missing_data | mountpoint) "test_$scenario" ;;
    *) fail "unknown scenario $scenario (settings, install, import, update, failed_update, refusals, missing_data, mountpoint)" ;;
  esac
done

echo "== all paperless tests passed"
