#!/usr/bin/env bash
# End-to-end test of the vaultwarden role on a throwaway systemd host per
# Ubuntu release, with Docker inside (the docker role) and the traefik role in
# front: one plain-HTTP entrypoint "web" and a "deny" middleware (vars.yml).
#
# The scenario "refusals" runs the role with settings it must refuse: each run
# fails with its message and leaves no /opt/vaultwarden.
#
# VAULTWARDEN_UBUNTU selects the releases (default "24.04 26.04");
# NOIXDEV_INFRA_VAULTWARDEN_TESTS selects scenarios (see the end of the file);
# KEEP=1 leaves the test hosts running.
# The single-quoted scripts expand inside the test host, not here.
# shellcheck disable=SC2016,SC2119,SC2120
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
out="$tests/output/vaultwarden"
releases="${VAULTWARDEN_UBUNTU:-24.04 26.04}"
host=

app_dir=/opt/vaultwarden

# Generated for this run, so that no test secret lives in the repository. The
# database password holds $, a quote and a space, so that the tests prove it
# reaches the database and the URL as written.
db_password="$(openssl rand -hex 12)"' pa$s"w ord'

cleanup() {
  [ "${KEEP:-0}" = 1 ] || [ -z "$host" ] || docker rm -f -v "$host" >/dev/null 2>&1 || true
}
# shellcheck source=/dev/null
. "$here/../lib/suite.sh"
noix_exit_guard

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
noix_link_collection "$root" "$tests/output"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"

fail() { echo "$*" >&2; exit 1; }

# h <cmd...>: run in the test host; hi: the same with this script's stdin.
h() { docker exec "$host" "$@"; }
hi() { docker exec -i "$host" "$@"; }

# play [-e ...]: the test host's playbook; its output goes to converge.log.
play() {
  ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$here/converge.yml" "$@" >"$out/converge.log" 2>&1
}
# converge [-e ...]: play, which must succeed.
converge() {
  play "$@" || { cat "$out/converge.log" >&2; fail "converge failed"; }
}
# converge_fails [-e ...]: play, which must fail.
converge_fails() {
  if play "$@"; then cat "$out/converge.log" >&2; fail "converge succeeded, but must fail"; fi
}
# converge_unchanged [-e ...]: the same again, which must change nothing.
converge_unchanged() {
  converge "$@"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/converge.log" \
    || { cat "$out/converge.log" >&2; fail "the repeated converge changed something"; }
}

# The variables the vaultwarden role needs in every scenario; the secrets of
# this run in files of mode 0600. db-vars.json holds the database password, so
# that a scenario can run with or without it.
write_role_vars() {
  (
    umask 077
    printf '{"test_vaultwarden": true}\n' >"$out/role-vars.json"
    env "DB_PASSWORD=$db_password" python3 -c '
import json, os
print(json.dumps({"vaultwarden_db_password": os.environ["DB_PASSWORD"]}))' >"$out/db-vars.json"
  )
}
# role_converge [-e ...]: the host's playbook with the role. The *_unchanged
# and *_fails variants are as above; db_vars adds the database password.
role_converge() { converge -e "@$out/role-vars.json" "$@"; }
role_converge_unchanged() { converge_unchanged -e "@$out/role-vars.json" "$@"; }
role_converge_fails() { converge_fails -e "@$out/role-vars.json" "$@"; }
db_vars() { printf '%s\n' "@$out/db-vars.json"; }

# start_host <ubuntu>: a fresh systemd host with Docker and Traefik.
start_host() {
  local ubuntu="$1"
  host="noixdev-vaultwarden-$ubuntu"
  docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  # The anonymous volumes give the inner Docker a file system it can mount
  # overlays on; "docker rm -v" removes them with the host.
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd \
    --name "$host" "noixdev-infra-host:$ubuntu" >/dev/null
  until (h systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
  # The image's policy-rc.d (exit 101) keeps package scripts from starting
  # services; servers have none.
  h rm -f /usr/sbin/policy-rc.d

  echo "== test host (ubuntu $ubuntu)"
  converge
  converge_unchanged
  write_role_vars
}

# refused <message> [-e ...]: the role stops before any change, with a message.
refused() {
  local message="$1"
  shift
  role_converge_fails "$@"
  grep -qF -- "$message" "$out/converge.log" \
    || { cat "$out/converge.log" >&2; fail "the refusal lacks \"$message\""; }
  h test ! -e "$app_dir" || fail "$message: $app_dir was created"
}

test_refusals() {
  echo "== refusals (ubuntu $1)"
  refused 'vaultwarden_hostname is required' -e vaultwarden_hostname=
  refused 'is not a release the role runs' -e vaultwarden_version=latest
  refused 'is not a release the role runs' -e vaultwarden_version=1.36.0
  refused 'is not a release the role runs' -e vaultwarden_version=1.37.5-alpine
  refused 'vaultwarden_database' -e vaultwarden_database=mysql
  refused 'vaultwarden_db_password is required' -e vaultwarden_database=postgres
  refused 'vaultwarden_db_host is required' -e vaultwarden_database=postgres_external -e "$(db_vars)"
  refused 'Argon2id hash' -e vaultwarden_admin_token_hash=plain-token
  refused 'sets these itself' -e '{"vaultwarden_env": {"DOMAIN": "x"}}'
  refused 'sets these itself' -e '{"vaultwarden_env": {"SMTP_HOST": "x"}}'
  refused 'sets these itself' -e '{"vaultwarden_env": {"ADMIN_TOKEN_FILE": "x"}}'
  refused 'must be environment variable names' -e '{"vaultwarden_env": {"lower": "x"}}'
  refused 'no value for EMPTY' -e '{"vaultwarden_env": {"EMPTY": null}}'
  refused 'must be set both' -e vaultwarden_push_installation_id=0123
  refused 'must be set both' -e vaultwarden_push_installation_key=0123
  refused 'vaultwarden_push_region' -e vaultwarden_push_region=asia
  refused 'vaultwarden_smtp takes' -e '{"vaultwarden_smtp": {"security": "tls"}}'
  refused 'vaultwarden_smtp takes' -e '{"vaultwarden_smtp": {"host": "mail.test"}}'
  refused 'vaultwarden_smtp takes' -e '{"vaultwarden_smtp": {"username": "u"}}'
  refused 'PostgreSQL 18 or newer' -e vaultwarden_database=postgres -e "$(db_vars)" -e vaultwarden_postgres_image=postgres:17
  refused 'vaultwarden_db_sslmode' -e vaultwarden_db_sslmode=verify-full
}

# All scenarios by default; NOIXDEV_INFRA_VAULTWARDEN_TESTS="refusals" runs only these.
# A new scenario is a test_<name> function and one line in the case below.
scenarios="${NOIXDEV_INFRA_VAULTWARDEN_TESTS:-refusals}"
for ubuntu in $releases; do
  start_host "$ubuntu"
  for scenario in $scenarios; do
    case "$scenario" in
      refusals) test_refusals "$ubuntu" ;;
      *) fail "unknown scenario $scenario (refusals)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all vaultwarden tests passed"
