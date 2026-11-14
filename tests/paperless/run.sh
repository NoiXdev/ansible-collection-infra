#!/usr/bin/env bash
# End-to-end test of the paperless role on throwaway Docker-in-Docker hosts
# (a fresh one per scenario): the refusals of invalid settings before any
# change; a fresh install behind Traefik (API and login form through Traefik,
# no published HTTP port, Samba on 127.0.0.1 only, a $ reaching the container
# verbatim), a scan written over the Samba share that Paperless consumes, SMB1
# refused, a reconfigure of the share, and a run without changes that fails on
# a stopped container. Every successful converge is repeated and must change
# nothing.
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

echo "== install"
new_host
load_images
converge
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

echo "== all paperless tests passed"
