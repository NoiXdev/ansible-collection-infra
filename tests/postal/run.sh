#!/usr/bin/env bash
# End-to-end test of the postal role on a throwaway systemd host per Ubuntu
# release, with Docker inside (the docker role), the traefik role in front
# (plain HTTP, HTTPS with Traefik's own certificate and "ui", a second HTTPS
# entrypoint standing in for a tailnet one, on 127.0.0.1, and a "deny"
# middleware; vars.yml) and Mailpit catching the mail (converge.yml; SMTP on
# the host's 127.0.0.1:1025, its API on 127.0.0.1:8025):
#   refusals  settings the role must refuse: each run fails with its message
#             and leaves no /opt/postal
# Postal's image is linux/amd64 only, so on a machine that is not amd64 (an
# arm64 Mac, for example) it runs under emulation (Docker Desktop's Rosetta or
# QEMU) inside the test host; every scenario but the arch refusal sets
# postal_skip_arch_check (vars.yml).
# Every converge runs at least at -v, and its output must not hold a test
# secret; every successful converge of a scenario is repeated and must change
# nothing.
#
# POSTAL_UBUNTU selects the releases (default "24.04 26.04");
# NOIXDEV_INFRA_POSTAL_TESTS selects scenarios (see the end of the file; a
# scenario that needs an installation installs one when the host has none);
# KEEP=1 leaves the test hosts running.
# The single-quoted scripts expand inside the test host, not here.
# shellcheck disable=SC2016,SC2119,SC2120
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
out="$tests/output/postal"
releases="${POSTAL_UBUNTU:-24.04 26.04}"
host=

app_dir=/opt/postal

# Generated for this run, so that no test secret lives in the repository. The
# password holds $, a quote and a space, so that the tests prove it reaches
# the database, the files and the commands as written.
db_password="$(openssl rand -hex 12)"' pa$s"w'"'"'o rd'
secrets=("$db_password")

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

# Fails when the file holds a test secret, as it is or up to its first quote
# (a quoted or escaped copy): expect_no_secrets <file> <what>.
expect_no_secrets() {
  local secret part
  for secret in "${secrets[@]}"; do
    for part in "$secret" "${secret%%[\'\"\\\`]*}"; do
      if [ "${#part}" -ge 8 ] && grep -qF -- "$part" "$1"; then
        fail "$2 holds a test secret (${part:0:4}...): $(grep -nF -- "$part" "$1" | head -n 3 | cut -c1-200)"
      fi
    done
  done
}

# play [-e ...]: the test host's playbook, always at least at -v (task
# results shown), so that every run of the suite shows that no task prints a
# secret; its output goes to converge.log, which must hold no test secret,
# whether the run failed or not.
play() {
  local rc=0
  ansible-playbook -v -i "$here/inventory.yml" -e "test_host=$host" "$here/converge.yml" "$@" >"$out/converge.log" 2>&1 || rc=$?
  expect_no_secrets "$out/converge.log" "the converge output"
  return "$rc"
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
expect_in_log() {
  grep -qF -- "$1" "$out/converge.log" || { cat "$out/converge.log" >&2; fail "the converge output lacks: $1"; }
}
expect_not_in_log() {
  if grep -qF -- "$1" "$out/converge.log"; then
    fail "the converge output holds $1: $(grep -nF -- "$1" "$out/converge.log" | head -n 3 | cut -c1-200)"
  fi
}

# The variables the postal role needs in every scenario: the database password
# of this run in a file of mode 0600 (db-vars.json), so that a scenario can run
# with or without it.
write_db_vars() {
  (
    umask 077
    env "DB_PASSWORD=$2" python3 -c '
import json, os
print(json.dumps({"postal_db_password": os.environ["DB_PASSWORD"]}))' >"$out/$1"
  )
}
write_role_vars() {
  (
    umask 077
    printf '{"test_postal": true}\n' >"$out/role-vars.json"
  )
  write_db_vars db-vars.json "$db_password"
}
# role_converge [-e ...]: the host's playbook with the role. The *_unchanged
# and *_fails variants are as above; db_vars adds the database password.
role_converge() { converge -e "@$out/role-vars.json" "$@"; }
role_converge_unchanged() { converge_unchanged -e "@$out/role-vars.json" "$@"; }
role_converge_fails() { converge_fails -e "@$out/role-vars.json" "$@"; }
db_vars() { printf '%s\n' "@$out/db-vars.json"; }
# postal_converge [-e ...]: the role with the database password of the run;
# the variants as above.
postal_converge() { role_converge -e "$(db_vars)" "$@"; }
postal_converge_unchanged() { role_converge_unchanged -e "$(db_vars)" "$@"; }
postal_converge_fails() { role_converge_fails -e "$(db_vars)" "$@"; }

# start_host <ubuntu>: a fresh systemd host with Docker, Traefik and Mailpit,
# where postal.test is 127.0.0.1.
start_host() {
  local ubuntu="$1"
  host="noixdev-postal-$ubuntu"
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
  h sh -c 'echo "127.0.0.1 postal.test" >>/etc/hosts'

  echo "== test host (ubuntu $ubuntu)"
  converge
  converge_unchanged
  write_role_vars
}

# refused <message> [-e ...]: the role stops before any change, with a message.
# The database password is set, so a refusal never stems from its absence
# unless the scenario takes it away.
refused() {
  local message="$1"
  shift
  postal_converge_fails "$@"
  grep -qF -- "$message" "$out/converge.log" \
    || { cat "$out/converge.log" >&2; fail "the refusal lacks \"$message\""; }
  h test ! -e "$app_dir" || fail "$message: $app_dir was created"
}

test_refusals() {
  echo "== refusals (ubuntu $1)"
  refused 'postal_web_hostname is required' -e postal_web_hostname=
  refused 'postal_dns_domain is required' -e postal_dns_domain=
  refused 'postal_db_password is required' -e postal_db_password=
  refused 'is not a release the role runs' -e postal_version=latest
  refused 'is not a release the role runs' -e postal_version=2.3.0
  refused 'is not a release the role runs' -e postal_version=3.5
  refused 'value of postal_database must be one of' -e postal_database=mysql
  refused 'postal_db_host is required' -e postal_database=mariadb_external
  refused 'postal_smtp_tls must be traefik, files or off' -e postal_smtp_tls=files
  refused 'value of postal_spam must be one of' -e postal_spam=spamd
  refused 'postal_config_extra must be a mapping' -e '{"postal_config_extra": {"main_db": {}}}'
  refused 'postal_config_extra must be a mapping' -e '{"postal_config_extra": {"postal": {"trusted_proxies": []}}}'
  refused 'postal_config_extra must be a mapping' -e '{"postal_config_extra": {"web_server": {"default_port": 1}}}'
  refused 'postal_admin_email must be an e-mail address' -e postal_admin_email=admin@example.test
  refused 'must all differ' -e '{"postal_smtp_submission_port": 25}'
  refused 'must be ports (1 to 65535)' -e '{"postal_smtp_port": 70000}'
  refused 'must be ports (1 to 65535)' -e '{"postal_smtp_submission_port": -1}'
  refused 'must be absolute paths' -e '{"postal_track_hostnames": ["not a host"]}'

  # 0 switches the submission service off; it is not refused.
  postal_converge -e '{"postal_smtp_submission_port": 0}'

  # An arm64 test host is not x86_64: without postal_skip_arch_check the role
  # refuses it. (On an x86_64 machine the host is x86_64 and there is nothing
  # to refuse.)
  if [ "$(h uname -m)" != x86_64 ]; then
    refused "exists for linux/amd64 only" -e postal_skip_arch_check=false
  else
    echo "== refusals: the test host is x86_64, the arch refusal is skipped"
  fi
}

# All scenarios by default; NOIXDEV_INFRA_POSTAL_TESTS="refusals" runs only
# these. A new scenario is a test_<name> function and one line in the case
# below.
all_scenarios="refusals"
scenarios="${NOIXDEV_INFRA_POSTAL_TESTS:-$all_scenarios}"
for ubuntu in $releases; do
  start_host "$ubuntu"
  for scenario in $scenarios; do
    case "$scenario" in
      refusals) test_refusals "$ubuntu" ;;
      *) fail "unknown scenario $scenario ($all_scenarios)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all postal tests passed"
