#!/usr/bin/env bash
# End-to-end test of the paperless role on throwaway Docker-in-Docker hosts
# (a fresh one per scenario): the refusals of invalid settings before any
# change; a failed install (a pull that fails) that every later run refuses
# until it is removed; a fresh install behind Traefik (API and login form
# through Traefik, no published HTTP port, Samba on 127.0.0.1 only, a $
# reaching the container verbatim), a scan written over the Samba share that Paperless consumes, SMB1
# refused, a reconfigure of the share, and a run without changes that fails on
# a stopped container. Then the import of that host's export: refused into
# the host itself (not empty); on a fresh host refused for an export of
# another version, without a manifest, without its passphrase and for a path
# outside the export directory, a half-failed import (a truncated manifest)
# refused until it is removed as the message says, then imported once
# (documents, title and admin of the source, the record), and after another
# removal an export made with a passphrase imported with it. Every
# successful converge is repeated and must change nothing.
# The single-quoted scripts expand inside the container, not here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
host="${NOIXDEV_INFRA_PAPERLESS_TEST_HOST:-noixdev-infra-paperless-test}"
out="$tests/output/paperless"
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
# Loads the role's and Traefik's default images into the host, pulled once
# per set of images.
load_images() {
  local image key tarball
  for image in "${images[@]}"; do
    case "$image" in
      "" | :* | *:) fail "an image is missing in $defaults or $traefik_defaults" ;;
    esac
  done
  key="$(printf '%s\n' "${images[@]}" | cksum | cut -d' ' -f1)"
  tarball="$out/images-$key.tar"
  if [ ! -s "$tarball" ]; then
    for image in "${images[@]}"; do docker pull -q "$image" >/dev/null; done
    docker save -o "$tarball" "${images[@]}"
  fi
  docker exec -i "$host" docker load <"$tarball" >/dev/null
}
# The API through Traefik as the admin: api <path>.
api() {
  hx curl -fsS -H 'Host: paperless.test' -u "admin:$admin_password" "http://127.0.0.1$1"
}
doc_count() { api /api/documents/ | python3 -c 'import json, sys; print(json.load(sys.stdin)["count"])'; }
consume_empty() { [ -z "$(hx ls -A "$dir/data/consume")" ]; }
# smbclient on the share as the scanner user: smb <protocol> <command> [options...].
smb() {
  local protocol="$1" command="$2"
  shift 2
  hx smbclient //127.0.0.1/consume -U "scanner%$samba_password" -m "$protocol" "$@" -c "$command"
}

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
role_fails no-admin -e paperless_admin_user= -e paperless_admin_password=
expect_in_log no-admin paperless_admin_user
hx test ! -e "$dir" || fail "paperless touched the host before refusing its settings"

echo "== a failed install must be refused until it is removed"
new_host
load_images
# A release that does not exist: the pull fails after the compose file is written.
play_fails install-failed "$here/converge.yml" -e paperless_version=3.99.0
expect_in_log install-failed "The install of Paperless 3.99.0 in $dir failed (Start Paperless:"
expect_in_log install-failed "docker compose down in $dir"
hx test -e "$dir/install-incomplete" || fail "the failed install left no marker"
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
converge
hx test ! -e "$dir/install-incomplete" || fail "the install kept its marker"
expect_idempotent
play "$here/verify.yml"

echo "== a scan written over Samba must be consumed"
# Through stdin: docker cp cannot write into the host's /tmp, a tmpfs.
docker exec -i "$host" sh -c 'cat >/root/sample.pdf' <"$here/sample.pdf"
smb SMB3 'put /root/sample.pdf sample.pdf' >"$out/smb-put.log" 2>&1 || { cat "$out/smb-put.log" >&2; fail "the scan could not be written over SMB3"; }
for _ in $(seq 90); do
  [ "$(doc_count)" = 1 ] && consume_empty && break
  sleep 2
done
[ "$(doc_count)" = 1 ] || fail "the scan was not consumed: $(doc_count) documents"
consume_empty || fail "the consume directory still holds: $(hx ls -A "$dir/data/consume")"
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

echo "== a half-failed import must be refused until it is removed"
load_images
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
expect_in_log import-failed "The import of $import into Paperless $version in $dir failed (Import the export:"
expect_in_log import-failed "Failed to parse manifest file"
expect_in_log import-failed "docker compose down in $dir"
expect_in_log import-failed "remove $dir/compose.yaml"
expect_in_log import-failed "the subdirectories media, data, consume, postgres and redis of $dir/data"
expect_in_log import-failed "keep $export_dir"
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

echo "== an export made with a passphrase must be imported with it"
reset_import
converge -e "paperless_import_dir=$encrypted" -e paperless_admin_user= -e paperless_admin_password= \
  -e "{\"paperless_import_passphrase\": \"$passphrase\"}"
expect_idempotent -e "paperless_import_dir=$encrypted" -e paperless_admin_user= -e paperless_admin_password=
[ "$(doc_count)" = 1 ] || fail "the import with a passphrase brought $(doc_count) documents, not 1"
if hx grep -qF "$passphrase" "$dir/compose.yaml"; then fail "the passphrase is in the compose file"; fi

echo "== all paperless tests passed"
