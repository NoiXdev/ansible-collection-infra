#!/usr/bin/env bash
# End-to-end test of the vaultwarden role on a throwaway systemd host per
# Ubuntu release, with Docker inside (the docker role), the traefik role in
# front (plain HTTP and HTTPS with Traefik's own certificate on 127.0.0.1, and
# a "deny" middleware; vars.yml) and Mailpit catching the mail (converge.yml;
# it takes only the SMTP login with the password the role wrote last):
#   refusals  settings the role must refuse: each run fails with its message
#             and leaves no /opt/vaultwarden
#   install   a fresh install with SQLite, the admin page, SMTP to Mailpit
#             (with a login), push of the eu region (a dummy pair) and
#             vaultwarden_env (verify.yml: the container healthy with no
#             published port, its environment and mounts, the compose file
#             without a secret, the secrets 0600 in a 0700 directory, the
#             database target); through Traefik a prelogin, signups refused,
#             a wrong admin token refused, an admin login and an invite whose
#             mail arrives in Mailpit, the invited address registered with
#             client.py, and the official Bitwarden CLI logging in, creating
#             a login item and reading it back; then the admin router with a
#             middleware that denies everything (/admin denied by Traefik,
#             /alive and /api/ still answering), the admin router on the
#             plain HTTP entrypoint (on HTTPS /admin and its other spellings
#             match no router, Traefik's own 404; on HTTP the middleware
#             denies it) and the admin page switched off (Vaultwarden's own
#             disabled page, no admin router, no admin_token file)
#   config_json
#             a config.json saved on the admin page refused before any
#             change, naming its keys and showing none of its values (at
#             -vvv), one that is not JSON too; without it the run changes
#             nothing
#   missing_data
#             the data subdirectory moved away (an unmounted volume): the run
#             refuses and creates nothing, and compose does not start
#             Vaultwarden either; with the data back it runs as before
#   mountpoint
#             vaultwarden_data_dir_mountpoint on a plain directory refused,
#             nothing changed (installed) or created (a fresh directory)
#   noop_down a stopped container: a run without changes fails naming the
#             service and starts nothing
#   reconfigure
#             a new SMTP password alone (the compose file stays as it is)
#             restarts Vaultwarden, which reads the new secrets file; the
#             push servers of the region us; a new
#             vaultwarden_invitation_org_name restarts it too, and an invite
#             mail (sent with the new SMTP password) names it; the item is
#             still readable; a run stopped after it wrote a new admin token
#             and before the restart (its docker compose up fails): the next
#             run restarts Vaultwarden, which takes the new token; the same
#             with a change of the compose file alone (the organization
#             name): the next run recreates Vaultwarden with it
#   interrupted
#             from the release of the defaults with SQLite, updates to it
#             tagged as newer releases: vaultwarden_restore_interrupted
#             without an interrupted update and a marker the role did not
#             write refused; beside update-failed of the same backup the
#             marker of the update in progress removed; a run killed during
#             its backup: the variable refused, the next run removes the
#             partial backup and updates; a run killed once the compose file
#             names the new version: refused naming both versions and the
#             backup, with the variable restored (the previous version
#             healthy with the item, a change after the backup undone, no
#             marker, no update, update-failed of another version kept),
#             then the next run without it updates
#   install_postgres
#             a fresh install with the own PostgreSQL (the cluster in
#             <data>/postgres, a password with $, quotes, @, / and a space,
#             percent-encoded in database_url, which and the password file
#             of the db service are the only places it is written): verify.yml
#             with both containers, the database target, tables in PostgreSQL
#             and no SQLite file, an idempotent second run, a registration
#             and the CLI reading an item back
#   mode_switch
#             the same host with another database mode refused before any
#             change, naming both modes (also where the data of the new mode
#             is missing); the PostgreSQL data missing refused as an
#             unmounted volume
#   db_password
#             a new vaultwarden_db_password the database does not have refused
#             before any change, also while the db service is down; taken
#             once ALTER USER set it, with Vaultwarden restarted on it and
#             the item still readable
#   external_refusals
#             a fresh install against a PostgreSQL server of the test host
#             refused before anything is created: a wrong password, a
#             server without TLS with sslmode require, a user who does not own
#             the database, a PostgreSQL 14 server, a database that holds a
#             table, a vaultwarden_postgres_image the host cannot pull
#   install_external
#             a fresh install with a PostgreSQL 16 server (a container of the
#             test host, published on its own address) as the external
#             database: verify.yml with the one container, database_url
#             (percent-encoded, with ?sslmode) as the only database secret,
#             a database-target of host, port and database without
#             credentials, the version-matched client image pulled, no
#             password in the process list during a run, an idempotent second
#             run, a registration and the CLI reading an item back
#   target_changed
#             on that installation another database name, host or port
#             refused before any change, naming both targets and the file; a
#             wrong password and a user who does not own the database refused
#             too; the item is still readable
#   failed_update_sqlite, failed_update_postgres, failed_update_external
#             an installation of the previous release (1.37.4) with the item
#             and an attachment (made with the official CLI), updated (a) to
#             an image that exits at once: rolled back with the item and the
#             attachment, update-failed naming the version, a run with it
#             refused before any change, a run with another version removing
#             the marker; (b) to the release of the defaults with the database
#             broken right after the backup (a docker wrapper on the test host
#             renames the users table, or for the external server revokes the
#             right to read it and adds a table): Vaultwarden turns healthy,
#             the database check fails, rolled back (the process list sampled
#             during the dump and the restore); for the external server the
#             added table is gone and the next update succeeds; with SQLite
#             a marker of a failed rollback refuses every version; with the
#             own PostgreSQL a dump that fails: the partial backup and the
#             markers removed, the installed version started again, no
#             update-failed
#   update_sqlite, update_postgres, update_external
#             that installation updated to the release of the defaults: the
#             backup (root's 0700, the compose file, the secrets, the data
#             without icon_cache, the SQLite database or a dump pg_restore
#             reads), the item and the attachment read back, no marker,
#             idempotent, the process list sampled during the dump; a
#             downgrade refused before any change; with SQLite
#             vaultwarden_backups_keep 1 over a second update (the release of
#             the defaults tagged 1.37.6) keeps only the newest backup
#   secrets   with the external PostgreSQL a reconfigure (a new push key) at
#             -vvv with the process list sampled; what it adds to the scans
#             of every other scenario (below)
# Every converge runs at least at -v, and its output must not hold a test
# secret (nor the process lists sampled during the external checks, the
# dumps and the restores); every successful converge of a scenario is
# repeated and must change nothing.
#
# VAULTWARDEN_UBUNTU selects the releases (default "24.04 26.04");
# NOIXDEV_INFRA_VAULTWARDEN_TESTS selects scenarios (see the end of the file;
# a scenario that needs an installation installs one when the host has none);
# KEEP=1 leaves the test hosts running.
# The single-quoted scripts expand inside the test host, not here.
# shellcheck disable=SC2016,SC2119,SC2120
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
# Each release writes to tests/output/vaultwarden-<release> (set in the loop at the end), so
# tests/all.sh can run the entries vaultwarden-24.04 and vaultwarden-26.04 at the same time.
out="$tests/output/vaultwarden"
releases="${VAULTWARDEN_UBUNTU:-24.04 26.04}"
host=

app_dir=/opt/vaultwarden
data_dir="$app_dir/data"
secrets_dir="$app_dir/secrets"
defaults="$root/roles/vaultwarden/defaults/main.yml"

# The value of a top-level key in a YAML file: value_of <file> <key>.
value_of() { sed -n "s/^$2: *//p" "$1" 2>/dev/null || true; }
image="$(value_of "$defaults" vaultwarden_image):$(value_of "$defaults" vaultwarden_version)"
# The official Bitwarden CLI: the release of the web vault Vaultwarden 1.37.5
# ships (2026.10.1), on Node 22 (it needs 22 or newer), built once per host.
bw_cli_version=2026.10.1
node_image=node:22.23.5-bookworm-slim
bw_image="noixdev-vaultwarden-bw:$bw_cli_version"

# The vault through Traefik's HTTPS entrypoint: vaultwarden.test resolves to
# 127.0.0.1 on the test host (start_host).
base=https://vaultwarden.test
user_email=user@example.test

# Generated for this run, so that no test secret lives in the repository. The
# secrets hold $, a quote and a space, so that the tests prove they reach the
# database, the files and the URL as written.
# The database password holds every character a URL must encode (and $, quotes).
db_password="$(openssl rand -hex 12)"" pa\$s\"w'o@r/d:x#y%z"
new_db_password="$(openssl rand -hex 12)"" ne\$w\"p'a@s/s:w#d%"
# The db_password scenario changes db_password; start_host sets it back.
initial_db_password="$db_password"
initial_admin_token="$(openssl rand -hex 12)"' ad$m"in tok'
rotated_admin_token="$(openssl rand -hex 12)"' ro$t"ated adm'
smtp_password="$(openssl rand -hex 12)"' sm$t"p pw'
rotated_smtp_password="$(openssl rand -hex 12)"' ro$t"ated pw'
push_key="$(openssl rand -hex 16)"
rotated_push_key="$(openssl rand -hex 16)"
push_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
user_password="$(openssl rand -hex 12)"' us$e"r pw'
item_password="$(openssl rand -hex 12)"
# The Argon2id hashes of the two admin tokens, made once per run
# (make_admin_hash, rotate_admin_token).
initial_admin_hash=
rotated_admin_hash=
# What install-vars.json holds; the reconfigure and secrets scenarios change
# them, start_host sets them back for each test host.
admin_token="$initial_admin_token"
admin_hash=
org_name='Noix Test Org'
current_smtp_password="$smtp_password"
current_push_key="$push_key"
# No converge's output and no process list may hold one of these; the hashes
# of the admin tokens are added once made.
pg_admin_password="$(openssl rand -hex 12)"
secrets=("$db_password" "$new_db_password" "$initial_admin_token" "$rotated_admin_token" "$smtp_password"
  "$rotated_smtp_password" "$push_key" "$rotated_push_key" "$user_password" "$pg_admin_password")

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

# Fails when the file holds a test secret, as it is, with its $ doubled (as a
# compose file would hold it), or either up to its first quote or backslash (a
# quoted or escaped copy): expect_no_secrets <file> <what>.
expect_no_secrets() {
  local secret doubled part
  for secret in "${secrets[@]}"; do
    doubled="${secret//\$/\$\$}"
    for part in "$secret" "${secret%%[\'\"\\\`]*}" "$doubled" "${doubled%%[\'\"\\\`]*}"; do
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
  local noix_cache_play=() && noix_cache_array noix_cache_play noix_cache_play_args
  ansible-playbook -v -i "$here/inventory.yml" -e "test_host=$host" ${noix_cache_play[@]+"${noix_cache_play[@]}"} "$here/converge.yml" "$@" >"$out/converge.log" 2>&1 || rc=$?
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

# The variables the vaultwarden role needs in every scenario; the secrets of
# this run in files of mode 0600. db-vars.json holds the database password, so
# that a scenario can run with or without it (new-db-vars.json: the new one;
# wrong-db-vars.json: one no database has).
write_db_vars() {
  (
    umask 077
    env "DB_PASSWORD=$2" python3 -c '
import json, os
print(json.dumps({"vaultwarden_db_password": os.environ["DB_PASSWORD"]}))' >"$out/$1"
  )
}
write_role_vars() {
  (
    umask 077
    printf '{"test_vaultwarden": true}\n' >"$out/role-vars.json"
  )
  write_db_vars db-vars.json "$db_password"
  write_db_vars new-db-vars.json "$new_db_password"
  write_db_vars wrong-db-vars.json "${db_password}-wrong"
}
# The settings of an installation: the admin page (the hash of admin_token),
# SMTP to Mailpit with a login, push of the eu region with a dummy pair, and
# vaultwarden_env with a $ that compose must not interpolate and a boolean.
write_install_vars() {
  (
    umask 077
    env "ADMIN_HASH=$admin_hash" "SMTP_PASSWORD=$current_smtp_password" "ORG=$org_name" \
      "PUSH_ID=$push_id" "PUSH_KEY=$current_push_key" python3 -c '
import json, os
print(json.dumps({
    "vaultwarden_admin_token_hash": os.environ["ADMIN_HASH"],
    "vaultwarden_invitation_org_name": os.environ["ORG"],
    "vaultwarden_smtp": {"host": "mailpit", "port": 1025, "security": "off", "username": "noix",
                         "password": os.environ["SMTP_PASSWORD"], "from": "vault@example.test",
                         "from_name": "Noix Vault"},
    "vaultwarden_push_installation_id": os.environ["PUSH_ID"],
    "vaultwarden_push_installation_key": os.environ["PUSH_KEY"],
    "vaultwarden_push_region": "eu",
    "vaultwarden_env": {"TZ": "Etc/UTC", "NOIX_TEST": "a$b", "SENDS_ALLOWED": True},
}))' >"$out/install-vars.json"
  )
}
# role_converge [-e ...]: the host's playbook with the role. The *_unchanged
# and *_fails variants are as above; db_vars adds the database password.
role_converge() { converge -e "@$out/role-vars.json" "$@"; }
role_converge_unchanged() { converge_unchanged -e "@$out/role-vars.json" "$@"; }
role_converge_fails() { converge_fails -e "@$out/role-vars.json" "$@"; }
db_vars() { printf '%s\n' "@$out/db-vars.json"; }
# vw_converge [-e ...]: the role with the settings of an installation
# (install-vars.json); the variants as above.
vw_converge() { role_converge -e "@$out/install-vars.json" "$@"; }
vw_converge_unchanged() { role_converge_unchanged -e "@$out/install-vars.json" "$@"; }
vw_converge_fails() { role_converge_fails -e "@$out/install-vars.json" "$@"; }
# The same with the own PostgreSQL and the database password of the run.
pg_converge() { vw_converge -e vaultwarden_database=postgres -e "$(db_vars)" "$@"; }
pg_converge_unchanged() { vw_converge_unchanged -e vaultwarden_database=postgres -e "$(db_vars)" "$@"; }
pg_converge_fails() { vw_converge_fails -e vaultwarden_database=postgres -e "$(db_vars)" "$@"; }

# verify [-e ...]: verify.yml with the settings of an installation.
verify() {
  ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$here/verify.yml" \
    -e "{\"verify_org_name\": \"$org_name\", \"verify_push_id\": \"$push_id\"}" "$@" >"$out/verify.log" 2>&1 \
    || { cat "$out/verify.log" >&2; fail "verify.yml failed"; }
}

# Mailpit takes the SMTP login noix with current_smtp_password only (an
# htpasswd {SHA} line: a plain one cannot hold the space), so that a mail
# proves Vaultwarden logs in with the password the role wrote last. Restarts
# Mailpit, which reads the file on start, when it runs already.
set_mailpit_login() {
  env "SMTP_PASSWORD=$current_smtp_password" python3 -c '
import base64, hashlib, os
print("noix:{SHA}" + base64.b64encode(hashlib.sha1(os.environ["SMTP_PASSWORD"].encode()).digest()).decode())' \
    | hi sh -c 'mkdir -p /root/mailpit && cat >/root/mailpit/smtp-auth'
  if h docker inspect mailpit >/dev/null 2>&1; then h docker restart mailpit >/dev/null; fi
}

# start_host <ubuntu>: a fresh systemd host with Docker, Traefik and Mailpit,
# where vaultwarden.test is 127.0.0.1 and client.py is /root/client.py.
start_host() {
  local ubuntu="$1"
  host="noixdev-vaultwarden-$ubuntu"
  docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  # The anonymous volumes give the inner Docker a file system it can mount
  # overlays on; "docker rm -v" removes them with the host.
  noix_cache_run=() && noix_cache_array noix_cache_run noix_cache_run_args
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd \
    --name "$host" ${noix_cache_run[@]+"${noix_cache_run[@]}"} "noixdev-infra-host:$ubuntu" >/dev/null
  noix_cache_host_setup "$host"
  until (h systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
  # The image's policy-rc.d (exit 101) keeps package scripts from starting
  # services; servers have none.
  h rm -f /usr/sbin/policy-rc.d
  h sh -c 'echo "127.0.0.1 vaultwarden.test" >>/etc/hosts'
  docker cp "$here/client.py" "$host:/root/client.py" >/dev/null
  attachment_sum=
  admin_token="$initial_admin_token"
  admin_hash="$initial_admin_hash"
  org_name='Noix Test Org'
  current_smtp_password="$smtp_password"
  current_push_key="$push_key"
  db_password="$initial_db_password"
  # The PostgreSQL test servers of this host publish on its own address.
  pg_ip=
  set_mailpit_login

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

# Prints the Argon2id hash of a token, made with Vaultwarden's own command as
# the docs give it (docker run -it ... /vaultwarden hash). It reads the token
# twice from a terminal, which script provides; the token goes through stdin.
# hash_token <token>.
hash_token() {
  h docker image inspect "$image" >/dev/null 2>&1 || h docker pull -q "$image" >/dev/null
  printf '%s\n%s\n' "$1" "$1" \
    | hi docker run --rm -i --network=none --entrypoint sh "$image" -c 'script -qec "/vaultwarden hash" /dev/null' \
    | grep -o "[\$]argon2id[^']*" || true
}
# Makes the hash of the first admin token once per run, for admin_hash unless
# a scenario rotated it; then writes install-vars.json.
make_admin_hash() {
  if [ -z "$initial_admin_hash" ]; then
    initial_admin_hash="$(hash_token "$initial_admin_token")"
    [[ "$initial_admin_hash" == '$argon2id$v=19$'* ]] || fail "/vaultwarden hash made no Argon2id hash"
    secrets+=("$initial_admin_hash")
  fi
  [ -n "$admin_hash" ] || admin_hash="$initial_admin_hash"
  write_install_vars
}
# The admin page's token rotated: admin_token and admin_hash the second pair
# (its hash made once per run), install-vars.json written.
rotate_admin_token() {
  if [ -z "$rotated_admin_hash" ]; then
    rotated_admin_hash="$(hash_token "$rotated_admin_token")"
    [[ "$rotated_admin_hash" == '$argon2id$v=19$'* ]] || fail "/vaultwarden hash made no Argon2id hash"
    secrets+=("$rotated_admin_hash")
  fi
  admin_token="$rotated_admin_token"
  admin_hash="$rotated_admin_hash"
  write_install_vars
}

# A request through Traefik (HTTPS, Traefik's own certificate): prints the
# body, then the status on a line of its own. request <path> [curl options...].
request() {
  local path="$1"
  shift
  h curl -sk --max-time 30 -w '\n%{http_code}' "$@" "$base$path"
}
# expect_answer <status> <body text> <path> [curl options...]: the status
# and a body that holds the text.
expect_answer() {
  local status="$1" text="$2" path="$3" answer
  shift 3
  answer="$(request "$path" "$@")"
  { [ "${answer##*$'\n'}" = "$status" ] && [[ "${answer%$'\n'*}" == *"$text"* ]]; } \
    || fail "$path answered ${answer##*$'\n'} ($(printf '%s' "${answer%$'\n'*}" | head -c 200)), not $status with: $text"
}
# The same, retried while Traefik picks up new labels: wait_answer <status>
# <body text> <path> [curl options...].
wait_answer() {
  local answer
  for _ in $(seq 30); do
    answer="$(request "$3" "${@:4}")"
    { [ "${answer##*$'\n'}" = "$1" ] && [[ "${answer%$'\n'*}" == *"$2"* ]]; } && return 0
    sleep 1
  done
  expect_answer "$@"
}
# Traefik's own 403 of the ipAllowList middleware: the body is Forbidden.
expect_denied() {
  local answer
  answer="$(request "$@")"
  [ "$answer" = $'Forbidden\n403' ] || fail "$1 was not denied by Traefik: ${answer##*$'\n'} $(printf '%s' "${answer%$'\n'*}" | head -c 200)"
}
# Waits until Traefik denies the path (it reads new labels within seconds).
wait_denied() {
  for _ in $(seq 30); do
    [ "$(request "$1")" = $'Forbidden\n403' ] && return 0
    sleep 1
  done
  expect_denied "$1"
}
# A JSON POST through Traefik: post_json <path> <json> [curl options...].
post_json() {
  local path="$1" body="$2"
  shift 2
  request "$path" -X POST -H 'Content-Type: application/json' --data "$body" "$@"
}

# The admin page's login through Traefik with a token from stdin, the session
# cookie in /root/admin.jar on the test host; prints the status:
# admin_login <token>.
admin_login() {
  printf '%s' "$1" | hi curl -sk --max-time 30 -o /dev/null -w '%{http_code}' -c /root/admin.jar \
    --data-urlencode 'token@-' "$base/admin"
}
# Invites an address on the admin page (after admin_login): invite <address>.
invite() {
  local answer
  answer="$(post_json /admin/invite "{\"email\": \"$1\"}" -b /root/admin.jar)"
  [ "${answer##*$'\n'}" = 200 ] || fail "the invite of $1 answered ${answer##*$'\n'}: $(printf '%s' "${answer%$'\n'*}" | head -c 200)"
}
# Waits for the invitation mail to the address that names the organization
# in its subject (Join <name>) and prints its link: invite_link <address>
# <organization name>.
invite_link() {
  local id link
  for _ in $(seq 30); do
    id="$(h curl -s "http://127.0.0.1:8025/api/v1/search?query=to%3A$1" \
      | env "SUBJECT=Join $2" python3 -c '
import json, os, sys
for message in json.load(sys.stdin).get("messages") or []:
    if message["Subject"] == os.environ["SUBJECT"]:
        print(message["ID"])
        break')"
    if [ -n "$id" ]; then
      link="$(h curl -s "http://127.0.0.1:8025/api/v1/message/$id" \
        | python3 -c 'import json, sys; print(json.load(sys.stdin)["Text"])' \
        | grep -oE "$base/#/accept-organization/\?[^[:space:]]+" | head -n 1 || true)"
      [ -n "$link" ] || fail "the invitation mail to $1 has no link"
      printf '%s\n' "$link"
      return 0
    fi
    sleep 2
  done
  fail "no mail \"Join $2\" to $1 in Mailpit"
}
# Registers an account with client.py through Traefik, with the user's master
# password: register <address> [<invite link>].
register() {
  h env CLIENT_INSECURE_TLS=1 python3 /root/client.py register "$base" "$1" "$user_password" "${@:2}"
}

# The official CLI in a container on the test host's network: it logs in as
# user_email, creates the login item noix-test with item_password ("create"),
# syncs and prints the item's password ("read" only reads); "attach" adds the
# file /root/bw-files/noix-attachment.bin of the test host to the item, and
# "attachment" (or "attach", after it) downloads that attachment and prints
# its sha256. The passwords go through an env file of mode 0600 on the test
# host, not a command line.
bw_script='
set -eu
export BITWARDENCLI_APPDATA_DIR=/tmp/bw
bw config server "$BW_SERVER" >/dev/null
BW_SESSION="$(bw login "$BW_EMAIL" --passwordenv BW_PASSWORD --raw --nointeraction)"
export BW_SESSION
if [ "$1" = create ]; then
  printf "{\"type\": 1, \"name\": \"noix-test\", \"notes\": null, \"favorite\": false, \"fields\": [], \"login\": {\"username\": \"noix\", \"password\": \"%s\", \"uris\": []}, \"secureNote\": null, \"card\": null, \"identity\": null, \"reprompt\": 0, \"folderId\": null, \"organizationId\": null}" "$BW_ITEM" \
    | bw encode | xargs bw create item --nointeraction >/dev/null
fi
bw sync --nointeraction >/dev/null
case "$1" in
  attach | attachment)
    id="$(bw get item noix-test --nointeraction | node -p "JSON.parse(require(\"fs\").readFileSync(0, \"utf8\")).id")"
    if [ "$1" = attach ]; then
      bw create attachment --file /files/noix-attachment.bin --itemid "$id" --nointeraction >/dev/null
      bw sync --nointeraction >/dev/null
    fi
    bw get attachment noix-attachment.bin --itemid "$id" --output /tmp/attachment.bin --nointeraction >/dev/null
    sha256sum /tmp/attachment.bin | cut -d " " -f 1
    ;;
  *) bw get password noix-test --nointeraction ;;
esac
'
bw_cli() {
  if ! h docker image inspect "$bw_image" >/dev/null 2>&1; then
    printf 'FROM %s\nRUN npm install --global --no-audit --no-fund @bitwarden/cli@%s\n' "$node_image" "$bw_cli_version" \
      | hi docker build -q -t "$bw_image" - >/dev/null
  fi
  printf 'BW_PASSWORD=%s\nBW_ITEM=%s\n' "$user_password" "$item_password" | hi sh -c 'umask 077; cat >/root/bw.env'
  h mkdir -p /root/bw-files
  printf '%s' "$bw_script" | hi docker run --rm -i --network host --add-host vaultwarden.test:127.0.0.1 \
    --env NODE_TLS_REJECT_UNAUTHORIZED=0 --env "BW_SERVER=$base" --env "BW_EMAIL=$user_email" \
    --env-file /root/bw.env --volume /root/bw-files:/files:ro "$bw_image" sh -s "$1" 2>"$out/bw.log"
}
# Fails unless the CLI reads the item's password back: expect_item create|read.
expect_item() {
  local got
  got="$(bw_cli "$1")" || { cat "$out/bw.log" >&2; fail "the Bitwarden CLI failed ($1)"; }
  [ "$got" = "$item_password" ] || { cat "$out/bw.log" >&2; fail "the Bitwarden CLI read another item password ($1): ${got:0:40}"; }
}
# The attachment's bytes (random, once per test host) and their sha256.
attachment_sum=
# Fails unless the CLI downloads the attachment of the item with the bytes it
# uploaded: expect_attachment attach|read (attach uploads it first).
expect_attachment() {
  local got
  if [ -z "$attachment_sum" ]; then
    h sh -c 'mkdir -p /root/bw-files && head -c 3000 /dev/urandom >/root/bw-files/noix-attachment.bin'
    attachment_sum="$(h sha256sum /root/bw-files/noix-attachment.bin | cut -d ' ' -f 1)"
  fi
  got="$(bw_cli "$([ "$1" = attach ] && echo attach || echo attachment)")" \
    || { cat "$out/bw.log" >&2; fail "the Bitwarden CLI failed on the attachment ($1)"; }
  [ "$got" = "$attachment_sum" ] || { cat "$out/bw.log" >&2; fail "the attachment came back with other bytes ($1): ${got:0:64}"; }
}

# docker compose in app_dir on the test host: compose <args...>.
compose() { h sh -c "cd $app_dir && docker compose $*"; }
container_id() { compose ps --all --quiet vaultwarden; }
# Waits until the container is healthy again.
wait_healthy() {
  for _ in $(seq 60); do
    [ "$(compose ps --format "'{{.Health}}'" vaultwarden)" = healthy ] && return 0
    sleep 3
  done
  fail "the vaultwarden container did not become healthy: $(compose ps --all)"
}
# Notes the compose file, the secrets and the containers, for expect_untouched.
note_untouched() {
  untouched_before="$(h sh -c "sha256sum $app_dir/compose.yaml $secrets_dir/*; docker ps -aq --filter label=com.docker.compose.project=vaultwarden")"
}
# Fails unless the refused run changed nothing: its recap, the compose file,
# the secrets and the containers since note_untouched.
expect_untouched() {
  grep -Eq 'changed=0 ' "$out/converge.log" || { cat "$out/converge.log" >&2; fail "the refused run changed something"; }
  [ "$(h sh -c "sha256sum $app_dir/compose.yaml $secrets_dir/*; docker ps -aq --filter label=com.docker.compose.project=vaultwarden")" = "$untouched_before" ] \
    || fail "the refused run changed the compose file, a secret or the containers"
}
# Fails unless the image's check of the compose file waits <seconds> while
# Vaultwarden starts: expect_start_period <seconds>.
expect_start_period() {
  h grep -qx "      start_period: $1s" "$app_dir/compose.yaml" \
    || fail "the compose file has no start_period of $1s: $(h grep -n start_period "$app_dir/compose.yaml")"
}
# Fails when the compose file holds a test secret.
expect_compose_clean() {
  h cat "$app_dir/compose.yaml" >"$out/compose.yaml"
  expect_no_secrets "$out/compose.yaml" "$app_dir/compose.yaml"
}

# An installation with the user and the item, as the install scenario makes
# it, for a scenario that runs on a host without one.
ensure_installed() {
  h test -e "$app_dir/compose.yaml" && return 0
  echo "== install for $1"
  make_admin_hash
  vw_converge
  [ "$(admin_login "$admin_token")" = 200 ] || fail "the admin login failed"
  invite "$user_email"
  register "$user_email" "$(invite_link "$user_email" "$org_name")" || fail "the invited address could not register"
  expect_item create
}

test_refusals() {
  echo "== refusals (ubuntu $1)"
  refused 'vaultwarden_hostname is required' -e vaultwarden_hostname=
  refused 'is not a release the role runs' -e vaultwarden_version=latest
  refused 'is not a release the role runs' -e vaultwarden_version=1.36.0
  refused 'is not a release the role runs' -e vaultwarden_version=1.37.5-alpine
  refused 'value of vaultwarden_database must be one of' -e vaultwarden_database=mysql
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
  refused 'value of vaultwarden_push_region must be one of' -e vaultwarden_push_region=asia
  refused 'vaultwarden_smtp takes' -e '{"vaultwarden_smtp": {"security": "tls"}}'
  refused 'vaultwarden_smtp takes' -e '{"vaultwarden_smtp": {"host": "mail.test"}}'
  refused 'vaultwarden_smtp takes' -e '{"vaultwarden_smtp": {"username": "u"}}'
  refused 'PostgreSQL 18 or newer' -e vaultwarden_database=postgres -e "$(db_vars)" -e vaultwarden_postgres_image=postgres:17
  refused 'value of vaultwarden_db_sslmode must be one of' -e vaultwarden_db_sslmode=verify-full
  refused 'holds a comma' -e vaultwarden_data_dir=/opt/vaultwarden/da,ta
}

test_install() {
  local answer
  echo "== install (ubuntu $1)"
  make_admin_hash
  vw_converge
  expect_compose_clean
  expect_start_period 300
  verify -e verify_admin=true
  [ "$(h cat "$app_dir/database-target" | sed -n 's/^database: *//p')" = sqlite ] \
    || fail "database-target does not say sqlite: $(h cat "$app_dir/database-target")"
  # Vaultwarden reads the secrets as written (the SMTP password with its $,
  # quote and space).
  [ "$(compose exec -T vaultwarden cat /run/secrets-vw/smtp_password)" = "$smtp_password" ] \
    || fail "the container does not read the SMTP password as written"
  vw_converge_unchanged

  # Through Traefik: the API, and no signups (no registration token for an
  # address nobody invited, so neither client.py registers it).
  expect_answer 200 '"kdfIterations"' /identity/accounts/prelogin -X POST \
    -H 'Content-Type: application/json' --data '{"email": "nobody@example.test"}'
  answer="$(post_json /identity/accounts/register/send-verification-email '{"email": "stranger@example.test", "name": null}')"
  { [ "${answer##*$'\n'}" = 400 ] && [[ "$answer" == *'Registration not allowed'* ]]; } \
    || fail "signups are not refused: ${answer##*$'\n'} $(printf '%s' "${answer%$'\n'*}" | head -c 200)"
  if register stranger@example.test 2>"$out/register.log"; then fail "client.py registered an address nobody invited"; fi
  grep -qF 'Registration not allowed' "$out/register.log" || fail "client.py failed otherwise: $(cat "$out/register.log")"

  # The admin page takes the token of the hash, not another one; its invite
  # arrives by mail, and its link registers the address.
  [ "$(admin_login 'not-the-admin-token')" = 401 ] || fail "the admin page took a wrong token"
  [ "$(admin_login "$admin_token")" = 200 ] || fail "the admin login failed"
  invite "$user_email"
  register "$user_email" "$(invite_link "$user_email" "$org_name")" || fail "the invited address could not register"
  # The official CLI logs in, stores an item and reads it back.
  expect_item create

  # With another vaultwarden_health_timeout, which the image's start_period
  # follows.
  echo "== install: the admin router (ubuntu $1)"
  vw_converge -e '{"vaultwarden_traefik_admin_middlewares": ["deny@file"], "vaultwarden_health_timeout": 240}'
  expect_start_period 240
  wait_denied /admin
  expect_denied /admin/users/overview
  expect_answer 200 '' /alive
  expect_answer 200 '"version"' /api/config
  vw_converge_unchanged -e '{"vaultwarden_traefik_admin_middlewares": ["deny@file"], "vaultwarden_health_timeout": 240}'

  # The admin router on another entrypoint (plain HTTP, web): on the vault's
  # entrypoint no router takes /admin, so Traefik answers with its own 404
  # (the test Traefik has no error-page catch-all), also for the spellings
  # that Traefik and Vaultwarden could read differently; on web the admin
  # router answers, with its middleware.
  echo "== install: the admin router on another entrypoint (ubuntu $1)"
  local admin_web='{"vaultwarden_traefik_admin_entrypoints": ["web"], "vaultwarden_traefik_admin_middlewares": ["deny@file"]}'
  vw_converge -e "$admin_web"
  wait_answer 404 '404 page not found' /admin
  expect_answer 404 '404 page not found' /admin/users/overview
  expect_answer 404 '404 page not found' //admin
  expect_answer 404 '404 page not found' /admin/
  answer="$(h curl -s --max-time 30 -w '\n%{http_code}' http://vaultwarden.test/admin)"
  [ "$answer" = $'Forbidden\n403' ] \
    || fail "the admin router on web did not deny /admin: ${answer##*$'\n'} $(printf '%s' "${answer%$'\n'*}" | head -c 200)"
  expect_answer 200 '' /alive
  expect_answer 200 '"version"' /api/config
  vw_converge_unchanged -e "$admin_web"

  echo "== install: the admin page off (ubuntu $1)"
  vw_converge -e vaultwarden_admin_token_hash=
  wait_answer 200 'The admin panel is disabled' /admin
  if h grep -qF 'vaultwarden-admin' "$app_dir/compose.yaml"; then fail "the compose file has an admin router without the admin page"; fi
  h test ! -e "$secrets_dir/admin_token" || fail "$secrets_dir/admin_token is left without the admin page"
  verify -e verify_admin=false
  vw_converge_unchanged -e vaultwarden_admin_token_hash=

  # Back to the admin page on, for the next scenarios.
  vw_converge
  expect_item read
}

test_config_json() {
  echo "== config_json (ubuntu $1)"
  ensure_installed config_json
  note_untouched
  h sh -c "printf '%s\n' '{\"smtp_host\": \"sentinel-smtp-host-value\", \"admin_token\": \"sentinel-admin-token-value\"}' >$data_dir/vaultwarden/config.json"
  vw_converge_fails -vvv
  expect_in_log 'It holds admin_token, smtp_host (the values are not shown)'
  expect_not_in_log sentinel-smtp-host-value
  expect_not_in_log sentinel-admin-token-value
  expect_untouched

  h sh -c "printf '%s\n' 'sentinel-broken-value {' >$data_dir/vaultwarden/config.json"
  vw_converge_fails -vvv
  expect_in_log 'is not a JSON object'
  expect_not_in_log sentinel-broken-value
  expect_untouched

  h rm "$data_dir/vaultwarden/config.json"
  vw_converge_unchanged
}

test_missing_data() {
  echo "== missing_data (ubuntu $1)"
  ensure_installed missing_data
  compose stop >/dev/null 2>&1
  h mv "$data_dir/vaultwarden" "$data_dir/vaultwarden.aside"
  note_untouched
  vw_converge_fails
  expect_in_log "lacks vaultwarden: is the volume mounted?"
  h test ! -e "$data_dir/vaultwarden" || fail "the refused run created $data_dir/vaultwarden"
  expect_untouched
  # compose does not create the bind's source either.
  if compose start >/dev/null 2>&1; then fail "docker compose started Vaultwarden without its data"; fi
  h test ! -e "$data_dir/vaultwarden" || fail "docker compose created $data_dir/vaultwarden"

  h mv "$data_dir/vaultwarden.aside" "$data_dir/vaultwarden"
  compose start >/dev/null 2>&1
  wait_healthy
  vw_converge_unchanged
  expect_item read
}

test_mountpoint() {
  echo "== mountpoint (ubuntu $1)"
  ensure_installed mountpoint
  note_untouched
  vw_converge_fails -e vaultwarden_data_dir_mountpoint=true
  expect_in_log "is not a mountpoint: is the volume mounted?"
  expect_untouched
  vw_converge_fails -e vaultwarden_data_dir_mountpoint=true -e vaultwarden_dir=/opt/vw-mountpoint
  expect_in_log "/opt/vw-mountpoint/data is not a mountpoint"
  h test ! -e /opt/vw-mountpoint || fail "the refused run created /opt/vw-mountpoint"
}

test_noop_down() {
  echo "== noop_down (ubuntu $1)"
  ensure_installed noop_down
  compose stop vaultwarden >/dev/null 2>&1
  note_untouched
  vw_converge_fails
  expect_in_log "the services vaultwarden are not running"
  [ "$(compose ps --all --format "'{{.State}}'" vaultwarden)" = exited ] || fail "the run without changes started Vaultwarden"
  expect_untouched
  compose start vaultwarden >/dev/null 2>&1
  wait_healthy
  vw_converge_unchanged
}

test_reconfigure() {
  local id secret
  echo "== reconfigure (ubuntu $1)"
  ensure_installed reconfigure
  make_admin_hash

  # A secret alone: the compose file stays, Vaultwarden restarts and reads it.
  # Mailpit takes the new password only, so the invite below proves it.
  id="$(container_id)"
  secret="$(h sha256sum "$secrets_dir/smtp_password")"
  current_smtp_password="$rotated_smtp_password"
  write_install_vars
  set_mailpit_login
  vw_converge
  grep -Eq 'changed=[1-9]' "$out/converge.log" || fail "the new SMTP password changed nothing"
  [ "$(h sha256sum "$secrets_dir/smtp_password")" != "$secret" ] || fail "the secrets file of the SMTP password did not change"
  [ "$(container_id)" != "$id" ] || fail "Vaultwarden was not restarted for the new SMTP password"
  [ "$(compose exec -T vaultwarden cat /run/secrets-vw/smtp_password)" = "$rotated_smtp_password" ] \
    || fail "the container does not read the new SMTP password"
  vw_converge_unchanged

  # The relay and identity server of the region us.
  vw_converge -e vaultwarden_push_region=us
  h grep -qF '"https://push.bitwarden.com"' "$app_dir/compose.yaml" || fail "the compose file lacks the relay of the region us"
  [ "$(compose exec -T vaultwarden printenv PUSH_RELAY_URI PUSH_IDENTITY_URI | tr '\n' ' ')" \
    = 'https://push.bitwarden.com https://identity.bitwarden.com ' ] || fail "Vaultwarden does not use the servers of the region us"

  # Another organization name (and the region eu again): in the compose
  # file, and in the next invite, which Mailpit takes with the new SMTP
  # password only.
  id="$(container_id)"
  org_name='Noix Rotated Org'
  write_install_vars
  vw_converge
  [ "$(container_id)" != "$id" ] || fail "Vaultwarden was not restarted for the new organization name"
  verify -e verify_admin=true
  expect_compose_clean
  vw_converge_unchanged
  [ "$(admin_login "$admin_token")" = 200 ] || fail "the admin login failed"
  invite second@example.test
  invite_link second@example.test "$org_name" >/dev/null
  expect_item read

  # A run stopped after it wrote a new secret and before Vaultwarden was
  # restarted on it (the docker compose up fails): the next run, whose
  # settings equal the files, still restarts Vaultwarden, which then takes
  # the new admin token.
  echo "== reconfigure: a restart stopped after the secrets (ubuntu $1)"
  rotate_admin_token
  # Vaultwarden's docker compose up only (the converge starts Traefik first).
  install_fault 'touch /root/fault.fail' "*\" --project-directory $app_dir \"*\"up \"*" 'services:'
  vw_converge_fails
  remove_fault
  expect_in_log 'Start Vaultwarden with the new configuration'
  h test -e "$app_dir/restart-pending" || fail "the stopped reconfigure left no $app_dir/restart-pending"
  [ "$(h cat "$secrets_dir/admin_token")" = "$admin_hash" ] || fail "the stopped reconfigure did not write the new admin token"
  [ "$(admin_login "$admin_token")" = 401 ] || fail "Vaultwarden took the new admin token before it was restarted"
  id="$(container_id)"
  vw_converge
  [ "$(container_id)" != "$id" ] || fail "the run after the stopped reconfigure did not restart Vaultwarden"
  [ "$(admin_login "$admin_token")" = 200 ] || fail "Vaultwarden does not take the new admin token after the restart"
  h test ! -e "$app_dir/restart-pending" || fail "the healthy run kept $app_dir/restart-pending"
  vw_converge_unchanged

  # A run stopped after it wrote a change of the compose file alone (another
  # organization name, no secret) and before Vaultwarden was recreated on it:
  # the next run, whose settings equal the compose file, still recreates
  # Vaultwarden, which then runs with the new value.
  echo "== reconfigure: a restart stopped after the compose file (ubuntu $1)"
  org_name='Noix Stopped Org'
  write_install_vars
  install_fault 'touch /root/fault.fail' "*\" --project-directory $app_dir \"*\"up \"*" 'services:'
  vw_converge_fails
  remove_fault
  expect_in_log 'Start Vaultwarden with the new configuration'
  h test -e "$app_dir/restart-pending" || fail "the stopped reconfigure left no $app_dir/restart-pending"
  h grep -qF "$org_name" "$app_dir/compose.yaml" || fail "the stopped reconfigure did not write the compose file"
  [ "$(compose exec -T vaultwarden printenv INVITATION_ORG_NAME)" != "$org_name" ] \
    || fail "Vaultwarden runs with the new organization name before it was recreated"
  id="$(container_id)"
  vw_converge
  [ "$(container_id)" != "$id" ] || fail "the run after the stopped reconfigure did not recreate Vaultwarden"
  [ "$(compose exec -T vaultwarden printenv INVITATION_ORG_NAME)" = "$org_name" ] \
    || fail "Vaultwarden does not run with the new organization name after the recreate"
  h test ! -e "$app_dir/restart-pending" || fail "the healthy run kept $app_dir/restart-pending"
  vw_converge_unchanged
}

# The own PostgreSQL scenarios share one installation, made afresh over
# whatever the host holds (the SQLite one of the scenarios above), so they
# come last.
# Removes the installation and its data: reset_installation.
reset_installation() {
  h test -e "$app_dir/compose.yaml" || return 0
  compose down --volumes >/dev/null 2>&1
  h rm -rf "$app_dir"
}
# Whether the database takes a password: db_login <password>. It connects over
# the network as Vaultwarden does (the local socket needs no password); the
# password goes through stdin into the environment of psql.
pg_login_script='PGPASSWORD="$(cat; echo x)"; PGPASSWORD="${PGPASSWORD%x}"; export PGPASSWORD;
PGCONNECT_TIMEOUT=10 exec psql --host=db --username=vaultwarden --dbname=vaultwarden --no-psqlrc --tuples-only --command="SELECT 1"'
db_login() {
  printf '%s' "$1" | hi docker compose --project-directory "$app_dir" exec -T db sh -c "$pg_login_script" >/dev/null 2>&1
}
# A statement of the vaultwarden database as its owner over the local socket:
# db_sql <statement>.
db_sql() {
  compose exec -T db psql --username=vaultwarden --dbname=vaultwarden --no-psqlrc --tuples-only --no-align --command="'$1'"
}
# An installation with the own PostgreSQL, the user and the item.
ensure_postgres_installed() {
  [ "$(h cat "$app_dir/database-target" 2>/dev/null | sed -n 's/^database: *//p')" = postgres ] && return 0
  echo "== install with PostgreSQL for $1"
  reset_installation
  make_admin_hash
  pg_converge
  [ "$(admin_login "$admin_token")" = 200 ] || fail "the admin login failed"
  invite "$user_email"
  register "$user_email" "$(invite_link "$user_email" "$org_name")" || fail "the invited address could not register"
  expect_item create
}

test_install_postgres() {
  local expected_url
  echo "== install_postgres (ubuntu $1)"
  reset_installation
  make_admin_hash
  pg_converge
  expect_compose_clean
  verify -e verify_admin=true -e verify_database=postgres
  [ "$(h cat "$app_dir/database-target" | sed -n 's/^database: *//p')" = postgres ] \
    || fail "database-target does not say postgres: $(h cat "$app_dir/database-target")"
  # The cluster lives below the bind in the data directory, and Vaultwarden
  # keeps nothing in SQLite.
  h test -s "$data_dir/postgres/18/docker/PG_VERSION" || fail "no PostgreSQL 18 cluster in $data_dir/postgres"
  h test ! -e "$data_dir/vaultwarden/db.sqlite3" || fail "Vaultwarden made a SQLite database beside PostgreSQL"
  # The password reaches the database and the URL as written: encoded in the
  # URL (every character a URL must encode), verbatim in the password file.
  expected_url="$(env "DB_PASSWORD=$db_password" python3 -c '
import os, urllib.parse
print("postgresql://vaultwarden:" + urllib.parse.quote(os.environ["DB_PASSWORD"], safe="") + "@db:5432/vaultwarden", end="")')"
  [ "$(h cat "$secrets_dir/database_url")" = "$expected_url" ] || fail "database_url is not the percent-encoded URL"
  case "$expected_url" in *'$'* | *"'"* | *'"'* | *' '* | *@*@*) fail "the test's expected URL is not encoded" ;; esac
  [ "$(h cat "$secrets_dir/db_password")" = "$db_password" ] || fail "the password file of the database is not the password as written"
  [ "$(compose exec -T db cat /run/secrets-vw/db_password)" = "$db_password" ] \
    || fail "the db container does not read the password as written"
  [ "$(compose exec -T vaultwarden cat /run/secrets-vw/database_url)" = "$expected_url" ] \
    || fail "the Vaultwarden container does not read the database URL as written"
  db_login "$db_password" || fail "the database does not take the password"
  ! db_login "${db_password}-other" || fail "the database takes another password"
  pg_converge_unchanged

  [ "$(admin_login "$admin_token")" = 200 ] || fail "the admin login failed"
  invite "$user_email"
  register "$user_email" "$(invite_link "$user_email" "$org_name")" || fail "the invited address could not register"
  expect_item create
  # The user is a row of PostgreSQL.
  [ "$(db_sql 'SELECT count(*) FROM users')" -ge 1 ] || fail "PostgreSQL holds no user"
  expect_answer 200 '"kdfIterations"' /identity/accounts/prelogin -X POST \
    -H 'Content-Type: application/json' --data '{"email": "nobody@example.test"}'
}

test_mode_switch() {
  echo "== mode_switch (ubuntu $1)"
  ensure_postgres_installed mode_switch
  note_untouched
  vw_converge_fails -e vaultwarden_database=sqlite
  expect_in_log 'vaultwarden_database sqlite'
  expect_in_log 'with the database postgres'
  expect_untouched

  # The other way round, as an installation with SQLite would be: the PostgreSQL
  # data is missing, which the mode must be refused for, not an unmounted volume.
  h mv "$data_dir/postgres" "$data_dir/postgres.aside"
  h sed -i 's/^database: postgres/database: sqlite/' "$app_dir/database-target"
  note_untouched
  pg_converge_fails
  expect_in_log 'vaultwarden_database postgres'
  expect_in_log 'with the database sqlite'
  expect_untouched
  h sed -i 's/^database: sqlite/database: postgres/' "$app_dir/database-target"
  # The same mode without its PostgreSQL data: an unmounted volume.
  note_untouched
  pg_converge_fails
  expect_in_log 'lacks postgres: is the volume mounted?'
  h test ! -e "$data_dir/postgres" || fail "the refused run created $data_dir/postgres"
  expect_untouched
  h mv "$data_dir/postgres.aside" "$data_dir/postgres"
  pg_converge_unchanged
  # A removed target file comes back with the next run.
  h rm "$app_dir/database-target"
  pg_converge
  grep -Eq 'changed=[1-9]' "$out/converge.log" || fail "the run did not record the database target"
  [ "$(h cat "$app_dir/database-target" | sed -n 's/^database: *//p')" = postgres ] || fail "the database target was not recorded"
  pg_converge_unchanged
  expect_item read
}

test_db_password() {
  local id
  echo "== db_password (ubuntu $1)"
  ensure_postgres_installed db_password
  note_untouched
  # A password the database does not have: refused, nothing touched.
  role_converge_fails -e "@$out/install-vars.json" -e vaultwarden_database=postgres -e "@$out/new-db-vars.json"
  expect_in_log 'does not take it'
  expect_in_log 'ALTER USER vaultwarden PASSWORD'
  expect_untouched
  db_login "$db_password" || fail "the refused run changed the password of the database"
  # With the db service down the role cannot ask: refused as well.
  compose stop db >/dev/null 2>&1
  note_untouched
  role_converge_fails -e "@$out/install-vars.json" -e vaultwarden_database=postgres -e "@$out/new-db-vars.json"
  expect_in_log 'the db service is not running, so the role cannot ask'
  expect_untouched
  compose start db >/dev/null 2>&1
  for _ in $(seq 60); do
    [ "$(compose ps --format "'{{.Health}}'" db)" = healthy ] && break
    sleep 2
  done
  [ "$(compose ps --format "'{{.Health}}'" db)" = healthy ] || fail "the db container did not become healthy again: $(compose ps --all)"
  wait_healthy

  # Set in the database as the message says (the statement through stdin,
  # with ' doubled), then taken: the secrets change, Vaultwarden restarts on
  # the new URL and still reads its data.
  id="$(container_id)"
  env "DB_PASSWORD=$new_db_password" python3 -c '
import os
print("ALTER USER vaultwarden PASSWORD \x27" + os.environ["DB_PASSWORD"].replace("\x27", "\x27\x27") + "\x27;")' \
    | hi docker compose --project-directory "$app_dir" exec -T db psql --username=vaultwarden --dbname=postgres --no-psqlrc >/dev/null
  db_login "$new_db_password" || fail "ALTER USER did not set the new password"
  role_converge -e "@$out/install-vars.json" -e vaultwarden_database=postgres -e "@$out/new-db-vars.json"
  [ "$(container_id)" != "$id" ] || fail "Vaultwarden was not restarted for the new database password"
  wait_healthy
  [ "$(h cat "$secrets_dir/db_password")" = "$new_db_password" ] || fail "the password file of the database was not updated"
  db_password="$new_db_password"
  write_role_vars
  verify -e verify_admin=true -e verify_database=postgres
  expect_compose_clean
  pg_converge_unchanged
  ! db_login "${db_password}x" || fail "the database takes another password"
  expect_item read
}

# The external PostgreSQL scenarios: servers of the test host's own Docker,
# published on the test host's primary address (not 127.0.0.1), which both the
# one-off client container on Docker's default bridge and Vaultwarden on its
# project network reach as an external server. They run after the scenarios
# above and reset the installation like install_postgres.
pg_ip=
pg_port=55432
old_pg_port=55414
# A PostgreSQL server container on the test host, once: pg_server <name>
# <major> <port>. The user vaultwarden (the password of the run) owns the
# databases vaultwarden (empty), vwtables (holds a table) and vwmoved (empty);
# vwother, with the same password, owns none.
# One that exists is kept when it runs, is ready and was set up to the end
# (vwtables holds its table, the last step); any other is made afresh.
pg_server() {
  local name="$1" major="$2" port="$3"
  if h docker inspect "$name" >/dev/null 2>&1; then
    if [ "$(h docker inspect --format '{{.State.Running}}' "$name")" = true ] && pg_ready "$name" 60 \
      && [ "$(h docker exec "$name" psql --username=postgres --dbname=vwtables --no-psqlrc --tuples-only --no-align \
        --command="SELECT to_regclass('public.leftover') IS NOT NULL" 2>/dev/null)" = t ]; then
      return 0
    fi
    h docker rm -f -v "$name" >/dev/null
  fi
  printf 'POSTGRES_PASSWORD=%s\n' "$pg_admin_password" | hi sh -c 'umask 077; cat >/root/pg.env'
  h docker run --detach --name "$name" --env-file /root/pg.env --publish "$pg_ip:$port:5432" "docker.io/library/postgres:$major-bookworm" >/dev/null
  pg_ready "$name" 120 || fail "the PostgreSQL server $name is not ready after 120 seconds: $(h docker logs --tail 20 "$name" 2>&1)"
  env "DB_PASSWORD=$db_password" python3 -c '
import os
pw = os.environ["DB_PASSWORD"].replace("\x27", "\x27\x27")
print("CREATE ROLE vaultwarden LOGIN PASSWORD \x27" + pw + "\x27;")
print("CREATE ROLE vwother LOGIN PASSWORD \x27" + pw + "\x27;")
for name in ("vaultwarden", "vwtables", "vwmoved"):
    print("CREATE DATABASE " + name + " OWNER vaultwarden;")' \
    | hi docker exec -i "$name" psql --username=postgres --no-psqlrc --set=ON_ERROR_STOP=1 >/dev/null
  h docker exec "$name" psql --username=vaultwarden --dbname=vwtables --no-psqlrc --set=ON_ERROR_STOP=1 \
    --command='CREATE TABLE leftover (id integer)' >/dev/null
}
# Whether the server answers within <seconds>: pg_ready <name> <seconds>. Over
# TCP: the init server of the image listens on its socket only.
pg_ready() {
  local name="$1" wait="$2"
  for _ in $(seq "$wait"); do
    h docker exec "$name" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
ensure_pg_servers() {
  [ -n "$pg_ip" ] || pg_ip="$(h hostname -I | awk '{print $1}')"
  [ -n "$pg_ip" ] || fail "the test host has no address"
  pg_server noixdev-vaultwarden-pg 16 "$pg_port"
  pg_server noixdev-vaultwarden-pg14 14 "$old_pg_port"
}
# The same as the settings of an installation with PostgreSQL 16 as the
# external database.
ext_converge() {
  vw_converge -e vaultwarden_database=postgres_external -e "vaultwarden_db_host=$pg_ip" \
    -e "vaultwarden_db_port=$pg_port" -e "$(db_vars)" "$@"
}
ext_converge_unchanged() {
  vw_converge_unchanged -e vaultwarden_database=postgres_external -e "vaultwarden_db_host=$pg_ip" \
    -e "vaultwarden_db_port=$pg_port" -e "$(db_vars)" "$@"
}
ext_converge_fails() {
  vw_converge_fails -e vaultwarden_database=postgres_external -e "vaultwarden_db_host=$pg_ip" \
    -e "vaultwarden_db_port=$pg_port" -e "$(db_vars)" "$@"
}
# A statement of the vaultwarden database on the PostgreSQL 16 server as its
# owner over the local socket: ext_sql <statement>.
ext_sql() {
  h docker exec noixdev-vaultwarden-pg psql --username=vaultwarden --dbname=vaultwarden --no-psqlrc \
    --tuples-only --no-align --command="$1"
}
# An installation with the external PostgreSQL, the user and the item.
ensure_external_installed() {
  ensure_pg_servers
  [ "$(h cat "$app_dir/database-target" 2>/dev/null | sed -n 's/^database: *//p')" = postgres_external ] && return 0
  echo "== install with an external PostgreSQL for $1"
  reset_installation
  make_admin_hash
  ext_converge
  [ "$(admin_login "$admin_token")" = 200 ] || fail "the admin login failed"
  invite "$user_email"
  register "$user_email" "$(invite_link "$user_email" "$org_name")" || fail "the invited address could not register"
  expect_item create
}

test_external_refusals() {
  echo "== external_refusals (ubuntu $1)"
  ensure_pg_servers
  reset_installation
  # Each leaves no /opt/vaultwarden (refused checks that).
  refused 'cannot log in' -e vaultwarden_database=postgres_external -e "vaultwarden_db_host=$pg_ip" \
    -e "vaultwarden_db_port=$pg_port" -e "@$out/wrong-db-vars.json"
  # The server speaks no TLS.
  refused 'cannot log in' -e vaultwarden_database=postgres_external -e "vaultwarden_db_host=$pg_ip" \
    -e "vaultwarden_db_port=$pg_port" -e "$(db_vars)" -e vaultwarden_db_sslmode=require
  refused 'cannot log in' -e vaultwarden_database=postgres_external -e "vaultwarden_db_host=$pg_ip" \
    -e "vaultwarden_db_port=$pg_port" -e "$(db_vars)" -e vaultwarden_db_name=nonexistent
  refused 'does not own the database vaultwarden' -e vaultwarden_database=postgres_external \
    -e "vaultwarden_db_host=$pg_ip" -e "vaultwarden_db_port=$pg_port" -e "$(db_vars)" -e vaultwarden_db_user=vwother
  refused 'PostgreSQL 14, older than 15' -e vaultwarden_database=postgres_external -e "vaultwarden_db_host=$pg_ip" \
    -e "vaultwarden_db_port=$old_pg_port" -e "$(db_vars)"
  refused 'already holds 1 table' -e vaultwarden_database=postgres_external -e "vaultwarden_db_host=$pg_ip" \
    -e "vaultwarden_db_port=$pg_port" -e "$(db_vars)" -e vaultwarden_db_name=vwtables
  # An image the host cannot pull: refused as such, not as a login.
  refused 'cannot run psql in vaultwarden_postgres_image test.invalid/postgres:18' -e vaultwarden_database=postgres_external \
    -e "vaultwarden_db_host=$pg_ip" -e "vaultwarden_db_port=$pg_port" -e "$(db_vars)" -e vaultwarden_postgres_image=test.invalid/postgres:18
  # The 14 server was refused before its client image was needed.
  if h docker image inspect docker.io/library/postgres:14 >/dev/null 2>&1; then fail "the client image of a refused server was pulled"; fi
  # No refused run made a table: the database vaultwarden of the 16 server
  # is still empty, and vwtables holds its one table only.
  [ "$(h docker exec noixdev-vaultwarden-pg psql --username=vaultwarden --dbname=vaultwarden --no-psqlrc \
    --tuples-only --no-align --command='SELECT count(*) FROM pg_tables WHERE schemaname = $$public$$')" = 0 ] \
    || fail "a refused run made tables in the external database"
  [ "$(h docker exec noixdev-vaultwarden-pg psql --username=vaultwarden --dbname=vwtables --no-psqlrc \
    --tuples-only --no-align --command='SELECT count(*) FROM pg_tables WHERE schemaname = $$public$$')" = 1 ] \
    || fail "a refused run changed the tables of vwtables"
}

test_install_external() {
  local expected_url
  echo "== install_external (ubuntu $1)"
  ensure_pg_servers
  reset_installation
  make_admin_hash
  ext_converge
  expect_compose_clean
  verify -e verify_admin=true -e verify_database=postgres_external -e "verify_db_host=$pg_ip" -e "verify_db_port=$pg_port"
  # The target names host, port and database and no credentials.
  h cat "$app_dir/database-target" >"$out/database-target"
  expect_no_secrets "$out/database-target" "$app_dir/database-target"
  grep -qxF "host: $pg_ip" "$out/database-target" || fail "database-target lacks the host: $(cat "$out/database-target")"
  grep -qxF "port: $pg_port" "$out/database-target" || fail "database-target lacks the port: $(cat "$out/database-target")"
  grep -qxF "name: vaultwarden" "$out/database-target" || fail "database-target lacks the database: $(cat "$out/database-target")"
  if grep -qiE 'user|password' "$out/database-target"; then fail "database-target names a credential: $(cat "$out/database-target")"; fi
  # database_url: the percent-encoded URL with the TLS mode; no password file
  # and no db service, since the database is not the role's.
  expected_url="$(env "DB_PASSWORD=$db_password" "HOST=$pg_ip" "PORT=$pg_port" python3 -c '
import os, urllib.parse
print("postgresql://vaultwarden:" + urllib.parse.quote(os.environ["DB_PASSWORD"], safe="") + "@" + os.environ["HOST"]
      + ":" + os.environ["PORT"] + "/vaultwarden?sslmode=prefer", end="")')"
  [ "$(h cat "$secrets_dir/database_url")" = "$expected_url" ] || fail "database_url is not the percent-encoded URL"
  [ "$(compose exec -T vaultwarden cat /run/secrets-vw/database_url)" = "$expected_url" ] \
    || fail "the Vaultwarden container does not read the database URL as written"
  h test ! -e "$secrets_dir/db_password" || fail "$secrets_dir/db_password exists with an external database"
  if h grep -q '^  db:' "$app_dir/compose.yaml"; then fail "the compose file has a db service with an external database"; fi
  # The version-matched client (the repository of the PostgreSQL image, the
  # server's major) ran the checks: the servers run from -bookworm tags, so
  # postgres:16 is there only because the role pulled it.
  h docker image inspect docker.io/library/postgres:16 >/dev/null 2>&1 || fail "the client image of the server's major was not used"
  ext_sql 'SELECT count(*) FROM users' >/dev/null || fail "no users table in the external database"

  # A run without changes, while the process list is sampled: no password in
  # any command line, with the one-off client containers started.
  ps_start
  ext_converge_unchanged
  ps_check "a run without changes with the external PostgreSQL" psql
  # At -vvv too.
  ext_converge -vvv

  [ "$(admin_login "$admin_token")" = 200 ] || fail "the admin login failed"
  invite "$user_email"
  register "$user_email" "$(invite_link "$user_email" "$org_name")" || fail "the invited address could not register"
  expect_item create
  [ "$(ext_sql 'SELECT count(*) FROM users')" -ge 1 ] || fail "the external PostgreSQL holds no user"
  expect_answer 200 '"kdfIterations"' /identity/accounts/prelogin -X POST \
    -H 'Content-Type: application/json' --data '{"email": "nobody@example.test"}'
}

test_target_changed() {
  echo "== target_changed (ubuntu $1)"
  ensure_external_installed target_changed
  note_untouched
  # Another database name: an empty one on the same server, which Vaultwarden
  # would fill with an empty vault.
  ext_converge_fails -e vaultwarden_db_name=vwmoved
  expect_in_log "$pg_ip:$pg_port/vwmoved"
  expect_in_log "$pg_ip:$pg_port/vaultwarden"
  expect_in_log 'remove'
  expect_in_log "$app_dir/database-target"
  expect_untouched
  # Another host and another port.
  ext_converge_fails -e vaultwarden_db_host=db.example.test
  expect_in_log 'db.example.test'
  expect_untouched
  ext_converge_fails -e "vaultwarden_db_port=$old_pg_port"
  expect_in_log "$pg_ip:$old_pg_port/vaultwarden"
  expect_untouched
  # The target of a SQLite or PostgreSQL install is another mode, refused by
  # its own message.
  ext_converge_fails -e vaultwarden_database=postgres
  expect_in_log 'with the database postgres_external'
  expect_untouched

  # The same target with a wrong password, and with a user who does not own
  # the database: refused in a state that reconfigures, before any change.
  role_converge_fails -e "@$out/install-vars.json" -e vaultwarden_database=postgres_external \
    -e "vaultwarden_db_host=$pg_ip" -e "vaultwarden_db_port=$pg_port" -e "@$out/wrong-db-vars.json"
  expect_in_log 'cannot log in'
  expect_untouched
  ext_converge_fails -e vaultwarden_db_user=vwother
  expect_in_log 'does not own the database vaultwarden'
  expect_untouched
  # A database that is not empty is refused on install only: this is not one.
  ext_converge_unchanged
  # A file that names no database: refused with words of its own.
  h cp -p "$app_dir/database-target" /root/database-target.keep
  h sed -i '/^name: /d' "$app_dir/database-target"
  ext_converge_fails
  expect_in_log "was made with a database that $app_dir/database-target does not name in full"
  expect_in_log 'Set the three back to those of the database the installation was made with.'
  expect_not_in_log 'the database a database'
  expect_untouched
  h mv /root/database-target.keep "$app_dir/database-target"
  ext_converge_unchanged
  # The file removed, as the refusal says when the database really moved: the
  # run records the target the settings name (a change), the next one changes
  # nothing, and the guard is back.
  h rm "$app_dir/database-target"
  ext_converge
  grep -Eq 'changed=[1-9]' "$out/converge.log" || fail "the run did not record the database target"
  h cat "$app_dir/database-target" >"$out/database-target"
  grep -qxF "name: vaultwarden" "$out/database-target" || fail "the target was not recorded: $(cat "$out/database-target")"
  ext_converge_unchanged
  ext_converge_fails -e vaultwarden_db_name=vwmoved
  expect_in_log "$pg_ip:$pg_port/vaultwarden"
  expect_item read
}

# The update scenarios: an installation of the previous release
# (old_version) with the user, the item and an attachment, updated to the
# release of the defaults (new_version). An image that exits at once
# (busybox), tagged as new_version of a test repository, fails an update; the
# release of the defaults tagged as next_version of it is a newer release that
# works.
old_version=1.37.4
new_version="$(value_of "$defaults" vaultwarden_version)"
next_version=1.37.6
old_image="$(value_of "$defaults" vaultwarden_image):$old_version"
test_repo=test.invalid/vaultwarden
busybox=busybox:1.37.0
backups="$data_dir/backups"
marker="$app_dir/update-failed"
progress="$app_dir/update-in-progress"

# set_mode <mode>: the options of the role (mode_args) and of verify.yml
# (verify_args) for the database mode.
mode_args=()
verify_args=()
set_mode() {
  case "$1" in
    sqlite) mode_args=() verify_args=() ;;
    postgres)
      mode_args=(-e vaultwarden_database=postgres -e "@$out/db-vars.json")
      verify_args=(-e verify_database=postgres)
      ;;
    postgres_external)
      ensure_pg_servers
      mode_args=(-e vaultwarden_database=postgres_external -e "vaultwarden_db_host=$pg_ip" -e "vaultwarden_db_port=$pg_port" -e "@$out/db-vars.json")
      verify_args=(-e verify_database=postgres_external -e "verify_db_host=$pg_ip" -e "verify_db_port=$pg_port")
      ;;
  esac
}
# vw_converge and its variants with the options of set_mode (bash 3.2 has no
# empty "${a[@]}" under set -u).
m_converge() { vw_converge ${mode_args[@]+"${mode_args[@]}"} "$@"; }
m_converge_unchanged() { vw_converge_unchanged ${mode_args[@]+"${mode_args[@]}"} "$@"; }
m_converge_fails() { vw_converge_fails ${mode_args[@]+"${mode_args[@]}"} "$@"; }
m_verify() { verify -e verify_admin=true ${verify_args[@]+"${verify_args[@]}"} "$@"; }

# A marker of a rollback that failed (rolled_back_to null) planted beside the
# installation: the run is refused, changes nothing, and its message gives
# the manual restore of the mode of set_mode, which must hold each text
# (as Ansible prints it, " escaped): failed_rollback_refused <text>...
failed_rollback_refused() {
  local text
  h sh -c "printf 'failed_version: $new_version\nrolled_back_to: null\nbackup: $backups/20260101T000000Z-$old_version-to-$new_version\ntime: \"2026-01-01T00:00:00Z\"\nrestore_error: noix test\n' >$marker"
  note_untouched
  m_converge_fails
  expect_in_log "and rolling back failed too (noix test)"
  for text in "$@"; do expect_in_log "$text"; done
  expect_untouched
  h rm "$marker"
}
# The image and state of the vaultwarden container.
vw_service() { compose ps --all --format "'{{.Image}} {{.State}} {{.Health}}'" vaultwarden; }
# The complete backups (not partial, not -failed), oldest first.
complete_backups() { h sh -c "ls $backups 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z-[0-9.]+-to-[0-9.]+\$' || true"; }
# The newest backup of an update from <from> to <to>: newest_backup <from> <to>.
newest_backup() {
  local name
  name="$(complete_backups | grep -F -- "-$1-to-$2" | tail -n 1)"
  [ -n "$name" ] || fail "no backup of the update from $1 to $2 in $backups: $(h ls -A "$backups" 2>&1)"
  printf '%s\n' "$backups/$name"
}
# Fails when the marker of an update in progress or one of its copies is left.
expect_no_progress() {
  h sh -c "test ! -e $progress && test ! -e $progress.compose.yaml && test ! -e $progress.secrets" \
    || fail "an update left $progress or a copy of it ($1): $(h sh -c "ls -d $progress*")"
}
# A file in icon_cache, which a backup leaves out and a rollback leaves in place.
put_icon() { h sh -c "mkdir -p $data_dir/vaultwarden/icon_cache && echo noix >$data_dir/vaultwarden/icon_cache/noix.test.png"; }
expect_icon() { h test -s "$data_dir/vaultwarden/icon_cache/noix.test.png" || fail "icon_cache lost its file ($1)"; }
# The external database emptied, as a fresh one for an install.
reset_external_db() {
  h docker exec noixdev-vaultwarden-pg psql --username=postgres --no-psqlrc --set=ON_ERROR_STOP=1 \
    --command='DROP DATABASE IF EXISTS vaultwarden WITH (FORCE)' --command='CREATE DATABASE vaultwarden OWNER vaultwarden' >/dev/null
}
# An installation of old_version in the mode of set_mode <mode> with the user,
# the item and the attachment, kept when the host has one without a marker:
# ensure_old_installed <mode> <scenario>.
ensure_old_installed() {
  set_mode "$1"
  if [ "$(h cat "$app_dir/database-target" 2>/dev/null | sed -n 's/^database: *//p')" = "$1" ] \
    && h grep -qF "server:$old_version\"" "$app_dir/compose.yaml" 2>/dev/null && ! h test -e "$marker"; then
    return 0
  fi
  echo "== install $old_version with $1 for $2"
  reset_installation
  [ "$1" != postgres_external ] || reset_external_db
  make_admin_hash
  m_converge -e "vaultwarden_version=$old_version"
  [ "$(admin_login "$admin_token")" = 200 ] || fail "the admin login failed"
  invite "$user_email"
  register "$user_email" "$(invite_link "$user_email" "$org_name")" || fail "the invited address could not register"
  expect_item create
  expect_attachment attach
}
# Fails unless the backup <dir> of mode <mode> holds what snapshot.yml makes:
# root's 0700, compose.yaml (0600) of version <from>, the secrets (0700, files
# 0600, those in use), the data subdirectory without icon_cache and with the
# attachment, with SQLite the database with the user, with PostgreSQL a dump
# that pg_restore reads: expect_backup <dir> <mode> <from>.
expect_backup() {
  local dir="$1" mode="$2" from="$3"
  [ "$(h stat -c '%U %a' "$backups" "$dir" | sort -u)" = "root 700" ] || fail "$backups or $dir is not root's 0700"
  [ "$(h stat -c '%U %a' "$dir/compose.yaml")" = "root 600" ] || fail "$dir/compose.yaml is not root's 0600"
  h grep -qF "server:$from\"" "$dir/compose.yaml" || fail "$dir/compose.yaml is not the one of $from"
  [ "$(h stat -c '%U %a' "$dir/secrets")" = "root 700" ] || fail "$dir/secrets is not root's 0700"
  [ "$(h sh -c "stat -c '%U %a' $dir/secrets/* | sort -u")" = "root 600" ] || fail "the files of $dir/secrets are not root's 0600"
  [ "$(h ls "$dir/secrets")" = "$(h ls "$secrets_dir")" ] || fail "$dir/secrets does not hold the secrets in use: $(h ls "$dir/secrets")"
  h test -d "$dir/vaultwarden" || fail "$dir has no copy of the data"
  h test ! -e "$dir/vaultwarden/icon_cache" || fail "the backup $dir holds icon_cache"
  h sh -c "ls $dir/vaultwarden/attachments/*/* >/dev/null 2>&1" || fail "the backup $dir holds no attachment"
  h test -s "$dir/vaultwarden/rsa_key.pem" || fail "the backup $dir lacks the key that signs the logins"
  if [ "$mode" = sqlite ]; then
    [ "$(h python3 -c 'import sqlite3, sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT count(*) FROM users").fetchone()[0])' \
      "$dir/vaultwarden/db.sqlite3")" -ge 1 ] || fail "the SQLite copy in $dir holds no user"
  else
    h test ! -e "$dir/vaultwarden/db.sqlite3" || fail "the backup $dir has a SQLite database with $mode"
    [ "$(h head -c 5 "$dir/vaultwarden.dump")" = PGDMP ] || fail "the backup $dir has no dump in pg_dump's custom format"
    h sh -c "docker run --rm -i --entrypoint pg_restore docker.io/library/postgres:18 --list <$dir/vaultwarden.dump" >"$out/dump.list" \
      || fail "pg_restore cannot read the dump in $dir"
    grep -q 'TABLE public users ' "$out/dump.list" || fail "the dump in $dir has no users table"
  fi
}
# Fails unless the run <what> rolled back to old_version: its message, the
# container of old_version healthy, the marker naming the failed version, the
# rollback and the backup (with the data of the failed attempt beside it), no
# marker of an update in progress, icon_cache as it was, verify.yml with the
# old image, and the item and the attachment read back.
expect_rolled_back() {
  local backup
  expect_in_log "update from $old_version to $new_version in $app_dir failed"
  expect_in_log "was rolled back: Vaultwarden $old_version runs again"
  [ "$(vw_service)" = "$old_image running healthy" ] || fail "Vaultwarden after the rollback ($1): $(vw_service)"
  h grep -qx "failed_version: $new_version" "$marker" || fail "the marker does not name $new_version ($1): $(h cat "$marker")"
  h grep -qx "rolled_back_to: $old_version" "$marker" || fail "the marker does not name $old_version ($1): $(h cat "$marker")"
  h grep -q '^time: ' "$marker" || fail "the marker has no time ($1): $(h cat "$marker")"
  backup="$(h sed -n 's/^backup: //p' "$marker")"
  h test -d "$backup/vaultwarden" || fail "the marker's backup $backup has no data ($1)"
  h test -d "$backup-failed/vaultwarden" || fail "the data of the failed update was not set aside to $backup-failed ($1)"
  expect_in_log "$backup"
  expect_no_progress "$1"
  expect_icon "$1"
  m_verify -e "verify_image=$old_image"
  expect_compose_clean
  expect_item read
  expect_attachment read
}

# A docker on the test host, ahead of the real one in the PATH, that runs the
# script /root/fault.sh once, right before the first docker call whose
# arguments match a case pattern (default: a docker compose up) while the
# compose file holds a text (default: the image of new_version): by default
# the database broken after the backup, as a new release could break it,
# while Vaultwarden starts and turns healthy. A script that creates
# /root/fault.fail makes that docker call fail instead.
# install_fault <script> [<case pattern> [<text of the compose file>]].
install_fault() {
  local real pattern="${2:-*\" compose \"*\" up \"*}" text="${3:-server:$new_version\"}"
  real="$(h sh -c 'command -v docker')"
  [ "$real" != /usr/local/sbin/docker ] || fail "a docker wrapper is left in /usr/local/sbin"
  printf '%s\n' "$1" | hi sh -c 'cat >/root/fault.sh'
  h rm -f /root/fault.log /root/fault.fail
  hi sh -c 'cat >/usr/local/sbin/docker && chmod 755 /usr/local/sbin/docker' <<WRAPPER
#!/bin/sh
case " \$* " in
  $pattern)
    if [ -e /root/fault.sh ] && grep -qF '$text' $app_dir/compose.yaml; then
      sh /root/fault.sh >>/root/fault.log 2>&1 && rm /root/fault.sh
      if [ -e /root/fault.fail ]; then
        rm -f /root/fault.fail
        echo "Error: the fault of the test" >&2
        exit 1
      fi
    fi
    ;;
esac
exec $real "\$@"
WRAPPER
}
remove_fault() {
  h test ! -e /root/fault.sh || fail "the fault was not injected: $(h cat /root/fault.log 2>&1)"
  h rm -f /usr/local/sbin/docker /root/fault.fail
}

# Samples the process list of the test host every 0.1 seconds (as the docker
# containers' processes show there too) until ps_check: ps_start.
ps_start() {
  h rm -f /root/ps.log /root/ps.stop
  docker exec -d "$host" sh -c 'while [ ! -e /root/ps.stop ]; do ps -eo args >>/root/ps.log; sleep 0.1; done'
}
# Stops the sampling; fails when no command line was sampled, when one holds
# a test secret, or when none holds <text> (what had to run meanwhile):
# ps_check <what> [<text>].
ps_check() {
  h touch /root/ps.stop
  sleep 1
  h cat /root/ps.log >"$out/ps.log"
  [ -s "$out/ps.log" ] || fail "the process list was not sampled ($1)"
  expect_no_secrets "$out/ps.log" "the process list ($1)"
  [ -z "${2:-}" ] || grep -qF -- "$2" "$out/ps.log" || fail "no process ran $2 while the process list was sampled ($1)"
}

# update_scenario <mode> <ubuntu>: from old_version with the item and the
# attachment to new_version: the backup, the item and the attachment, no
# marker; idempotent; a downgrade to old_version refused before any change.
# With SQLite also vaultwarden_backups_keep 1 over two updates (the second to
# next_version): only the newest backup is kept.
update_scenario() {
  local backup
  echo "== update_$1 (ubuntu $2)"
  ensure_old_installed "$1" "update_$1"
  put_icon
  # The process list while the update and its dump run.
  ps_start
  m_converge -e vaultwarden_backups_keep=1
  ps_check "the update with $1" "$([ "$1" = sqlite ] || echo pg_dump)"
  grep -qF 'update.yml' "$out/converge.log" || fail "the new version was not an update"
  [ "$(vw_service)" = "$image running healthy" ] || fail "Vaultwarden after the update: $(vw_service)"
  expect_no_progress "after the update"
  h test ! -e "$marker" || fail "the update left $marker"
  backup="$(newest_backup "$old_version" "$new_version")"
  expect_backup "$backup" "$1" "$old_version"
  [ "$(complete_backups | wc -l | tr -d ' ')" = 1 ] || fail "vaultwarden_backups_keep 1 kept more: $(complete_backups)"
  m_verify
  expect_compose_clean
  expect_icon "after the update"
  expect_item read
  expect_attachment read
  m_converge_unchanged -e vaultwarden_backups_keep=1

  # Vaultwarden cannot migrate its database down.
  note_untouched
  m_converge_fails -e "vaultwarden_version=$old_version"
  expect_in_log "vaultwarden_version $old_version is lower than the installed version $new_version"
  expect_untouched
  [ "$(complete_backups | wc -l | tr -d ' ')" = 1 ] || fail "the refused downgrade made a backup: $(complete_backups)"

  [ "$1" = sqlite ] || return 0
  echo "== update_$1: pruning (ubuntu $2)"
  h docker tag "$image" "$test_repo:$next_version"
  m_converge -e vaultwarden_backups_keep=1 -e "vaultwarden_image=$test_repo" -e "vaultwarden_version=$next_version"
  [ "$(vw_service)" = "$test_repo:$next_version running healthy" ] || fail "Vaultwarden after the second update: $(vw_service)"
  h test ! -e "$backup" || fail "the older backup $backup was not pruned"
  complete_backups | grep -qx "[0-9TZ]*-$new_version-to-$next_version" || fail "the newest backup is not the only one: $(complete_backups)"
  [ "$(complete_backups | wc -l | tr -d ' ')" = 1 ] || fail "vaultwarden_backups_keep 1 kept more: $(complete_backups)"
  expect_item read
  expect_attachment read
}
test_update_sqlite() { update_scenario sqlite "$1"; }
test_update_postgres() { update_scenario postgres "$1"; }
test_update_external() { update_scenario postgres_external "$1"; }

# failed_update_scenario <mode> <ubuntu> <fault script>: from old_version with
# the item and the attachment, (a) to an image that exits at once: rolled
# back, update-failed naming the version, which a run with it is refused
# for, and removed by a run with another version; (b) to new_version with a
# database broken after the backup (the fault script, by install_fault):
# Vaultwarden healthy, the database check fails, rolled back.
failed_update_scenario() {
  echo "== failed_update_$1 (ubuntu $2): an image that exits"
  ensure_old_installed "$1" "failed_update_$1"
  put_icon
  h docker pull -q "$busybox" >/dev/null
  h docker tag "$busybox" "$test_repo:$new_version"
  m_converge_fails -e "vaultwarden_image=$test_repo" -e vaultwarden_health_timeout=30 -e vaultwarden_rollback_timeout=300
  expect_rolled_back "an image that exits"
  h docker rmi "$test_repo:$new_version" >/dev/null

  echo "== failed_update_$1: the failed version refused (ubuntu $2)"
  note_untouched
  m_converge_fails
  expect_in_log "$marker exists: the Vaultwarden update to $new_version failed"
  expect_in_log "rolled back to $old_version"
  expect_untouched
  # Another version (the installed one) succeeds and removes the marker.
  m_converge -e "vaultwarden_version=$old_version"
  h test ! -e "$marker" || fail "a successful run with $old_version kept the marker"
  m_converge_unchanged -e "vaultwarden_version=$old_version"

  echo "== failed_update_$1: a broken database (ubuntu $2)"
  install_fault "$3"
  # The process list while the dump and its restore run.
  ps_start
  m_converge_fails -e vaultwarden_health_timeout=120 -e vaultwarden_rollback_timeout=300
  ps_check "the rollback with $1" "$([ "$1" = sqlite ] || echo pg_restore)"
  remove_fault
  expect_in_log "vaultwarden running healthy"
  expect_in_log "the users and ciphers tables cannot be read"
  expect_rolled_back "a broken database"
  h rm "$marker"
}
test_failed_update_sqlite() {
  failed_update_scenario sqlite "$1" \
    "python3 -c 'import sqlite3; db = sqlite3.connect(\"$data_dir/vaultwarden/db.sqlite3\"); db.execute(\"ALTER TABLE users RENAME TO users_broken\"); db.commit()'"
  # A marker of a rollback that failed (rolled_back_to null): every version
  # is refused, the installed one and the failed one alike.
  echo "== failed_update_sqlite: after a failed rollback (ubuntu $1)"
  h sh -c "printf 'failed_version: $new_version\nrolled_back_to: null\nbackup: $backups/20260101T000000Z-$old_version-to-$new_version\ntime: \"2026-01-01T00:00:00Z\"\nrestore_error: noix test\n' >$marker"
  note_untouched
  m_converge_fails
  expect_in_log "the Vaultwarden update to $new_version failed on 2026-01-01T00:00:00Z, and rolling back failed too (noix test)"
  expect_in_log "$backups/20260101T000000Z-$old_version-to-$new_version/compose.yaml"
  expect_untouched
  m_converge_fails -e "vaultwarden_version=$old_version"
  expect_in_log "and rolling back failed too (noix test)"
  expect_untouched
  h rm "$marker"
}
test_failed_update_postgres() {
  local before
  failed_update_scenario postgres "$1" \
    "cd $app_dir && docker compose exec -T db psql --username=vaultwarden --dbname=vaultwarden --set=ON_ERROR_STOP=1 --command='ALTER TABLE users RENAME TO users_broken'"
  # A dump that fails: nothing had changed, so the partial backup and the
  # markers go, the installed version starts again and no update-failed
  # keeps the version from the next run.
  echo "== failed_update_postgres: a failed dump (ubuntu $1)"
  before="$(complete_backups)"
  install_fault 'touch /root/fault.fail' '*" compose exec "*" pg_dump "*' "server:$old_version\""
  m_converge_fails
  remove_fault
  expect_in_log "update from $old_version to $new_version in $app_dir failed before anything changed"
  expect_in_log 'Error: the fault of the test'
  expect_in_log "Vaultwarden $old_version was started again"
  wait_healthy
  [ "$(vw_service)" = "$old_image running healthy" ] || fail "Vaultwarden after the failed dump: $(vw_service)"
  [ -z "$(h sh -c "ls -d $backups/*.partial 2>/dev/null || true")" ] || fail "the failed dump left a partial backup: $(h ls -A "$backups")"
  [ "$(complete_backups)" = "$before" ] || fail "the failed dump changed the complete backups: $(complete_backups)"
  expect_no_progress "after the failed dump"
  h test ! -e "$marker" || fail "the failed dump wrote $marker: $(h cat "$marker")"
  expect_item read
  # After a failed rollback: the manual restore of the own PostgreSQL, the
  # identifiers quoted.
  echo "== failed_update_postgres: after a failed rollback (ubuntu $1)"
  failed_rollback_refused \
    "-c 'DROP DATABASE IF EXISTS \\\"vaultwarden\\\" WITH (FORCE)' -c 'CREATE DATABASE \\\"vaultwarden\\\" OWNER \\\"vaultwarden\\\"'" \
    'pg_restore --single-transaction --exit-on-error -U vaultwarden -d vaultwarden' \
    "$backups/20260101T000000Z-$old_version-to-$new_version/vaultwarden.dump"
}
# With the external server the fault is a right revoked and a table the failed
# release's migration made, which the rollback drops with the schema; then
# the next update succeeds.
test_failed_update_external() {
  failed_update_scenario postgres_external "$1" \
    "docker exec noixdev-vaultwarden-pg psql --username=postgres --dbname=vaultwarden --set=ON_ERROR_STOP=1 --command='REVOKE SELECT ON users FROM vaultwarden' && docker exec noixdev-vaultwarden-pg psql --username=vaultwarden --dbname=vaultwarden --set=ON_ERROR_STOP=1 --command='CREATE TABLE noix_failed_migration (id integer)'"
  [ "$(ext_sql "SELECT count(*) FROM pg_tables WHERE tablename = 'noix_failed_migration'")" = 0 ] \
    || fail "the table the failed update made is left after the rollback"
  echo "== failed_update_postgres_external: the next update (ubuntu $1)"
  m_converge
  [ "$(vw_service)" = "$image running healthy" ] || fail "Vaultwarden after the next update: $(vw_service)"
  h test ! -e "$marker" || fail "the next update left $marker"
  expect_item read
  expect_attachment read
  # After a failed rollback: the manual restore of the external server, the
  # SQL written to a file first and loaded in one transaction.
  echo "== failed_update_postgres_external: after a failed rollback (ubuntu $1)"
  failed_rollback_refused \
    "pg_restore --no-owner --no-privileges --file=vaultwarden.sql $backups/20260101T000000Z-$old_version-to-$new_version/vaultwarden.dump" \
    "load it into the database $pg_ip:$pg_port/vaultwarden as vaultwarden" \
    "psql --single-transaction --set=ON_ERROR_STOP=1 --command='DROP SCHEMA public CASCADE' --command='CREATE SCHEMA public' --file=vaultwarden.sql"
}

# A converge stopped as a dropped SSH session or a reboot stops it: the role
# with the settings of an installation, in the background in a process group
# of its own, killed with SIGKILL (the whole group) once the shell condition
# holds on the test host; then waits until no module of it runs there any
# more. Its output (at -v) goes to converge.log, which must hold no test
# secret: play_killed <condition> [-e ...].
play_killed() {
  local condition="$1" pid
  shift
  local noix_cache_play=() && noix_cache_array noix_cache_play noix_cache_play_args
  set -m
  ansible-playbook -v -i "$here/inventory.yml" -e "test_host=$host" ${noix_cache_play[@]+"${noix_cache_play[@]}"} "$here/converge.yml" \
    -e "@$out/role-vars.json" -e "@$out/install-vars.json" "$@" >"$out/converge.log" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 900); do
    if h sh -c "$condition" >/dev/null 2>&1; then
      kill -9 -- "-$pid"
      wait "$pid" || true
      expect_no_secrets "$out/converge.log" "the output of the killed converge"
      wait_modules
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      tail -n 40 "$out/converge.log" >&2
      fail "the converge ended before it was killed at: $condition"
    fi
    sleep 0.5
  done
  kill -9 -- "-$pid" 2>/dev/null || true
  wait "$pid" || true
  fail "the converge did not reach within the wait: $condition"
}
# Waits until no Ansible module runs on the test host for five seconds.
wait_modules() {
  local quiet=0
  for _ in $(seq 300); do
    if h pgrep -f '[A]nsiballZ_' >/dev/null; then quiet=0; else quiet=$((quiet + 1)); fi
    [ "$quiet" -lt 5 ] || return 0
    sleep 1
  done
  fail "an Ansible module still runs on the test host after 300 seconds"
}

# The interrupted update, with SQLite from an installation of the release of
# the defaults with the item: updates to that release tagged as newer ones
# (next_version, then after_version, of test_repo). iv_converge <version>
# [-e ...] and its variants: the role with that image and version.
after_version=1.37.7
iv_converge() { vw_converge -e "vaultwarden_image=$test_repo" -e "vaultwarden_version=$1" "${@:2}"; }
iv_converge_unchanged() { vw_converge_unchanged -e "vaultwarden_image=$test_repo" -e "vaultwarden_version=$1" "${@:2}"; }
iv_converge_fails() { vw_converge_fails -e "vaultwarden_image=$test_repo" -e "vaultwarden_version=$1" "${@:2}"; }
# Whether the SQLite database holds the table noix_sentinel.
sentinel_sql='import sqlite3, sys; db = sqlite3.connect(sys.argv[1])'
has_sentinel() {
  [ "$(h python3 -c "$sentinel_sql"'; print(db.execute("SELECT count(*) FROM sqlite_master WHERE name = ?", ("noix_sentinel",)).fetchone()[0])' \
    "$data_dir/vaultwarden/db.sqlite3")" = 1 ]
}
test_interrupted() {
  local backup failed_other
  echo "== interrupted (ubuntu $1)"
  if [ "$(h cat "$app_dir/database-target" 2>/dev/null | sed -n 's/^database: *//p')" != sqlite ] \
    || ! h grep -qF "\"$image\"" "$app_dir/compose.yaml" 2>/dev/null \
    || h sh -c "test -e $marker || test -e $progress || test -e $app_dir/restart-pending"; then
    reset_installation
  fi
  ensure_installed interrupted
  h docker tag "$image" "$test_repo:$next_version"
  h docker tag "$image" "$test_repo:$after_version"

  # The variable without a marker, and a marker the role did not write.
  note_untouched
  vw_converge_fails -e vaultwarden_restore_interrupted=true
  expect_in_log "vaultwarden_restore_interrupted is set, but there is no interrupted update in $app_dir; remove the variable"
  expect_untouched
  h sh -c "echo 'not: [yaml' >$progress"
  vw_converge_fails
  expect_in_log "$progress exists, but it is not YAML or lacks step or to_version"
  expect_untouched
  h rm "$progress"

  # Beside update-failed of the same backup (a rescue stopped after it wrote
  # update-failed): the marker of the update in progress goes, update-failed
  # refuses.
  h sh -c "printf 'from_version: $new_version\nto_version: $next_version\nstep: update\nbackup: $backups/20260101T000000Z-$new_version-to-$next_version\ntime: \"2026-01-01T00:00:00Z\"\n' >$progress"
  h sh -c "printf 'failed_version: $next_version\nrolled_back_to: $new_version\nbackup: $backups/20260101T000000Z-$new_version-to-$next_version\ntime: \"2026-01-01T00:00:00Z\"\n' >$marker"
  iv_converge_fails "$next_version"
  expect_in_log "$marker exists: the Vaultwarden update to $next_version failed"
  expect_no_progress "beside update-failed of the same backup"
  h test -e "$marker" || fail "the run removed $marker"
  h rm "$marker"

  echo "== interrupted: stopped during its backup (ubuntu $1)"
  play_killed "ls -d $backups/*.partial" -e "vaultwarden_image=$test_repo" -e "vaultwarden_version=$next_version"
  h grep -qx 'step: backup' "$progress" || fail "the marker does not record the step backup: $(h cat "$progress")"
  # The variable is refused: nothing had changed to restore.
  note_untouched
  iv_converge_fails "$next_version" -e vaultwarden_restore_interrupted=true
  expect_in_log "records an update that stopped during its backup, before anything changed"
  expect_untouched
  h sh -c "ls -d $backups/*.partial" >/dev/null || fail "the refused run removed the partial backup"
  # The next run removes the partial backup and the marker and updates.
  iv_converge "$next_version"
  [ "$(vw_service)" = "$test_repo:$next_version running healthy" ] || fail "Vaultwarden after the update: $(vw_service)"
  [ -z "$(h sh -c "ls -d $backups/*.partial 2>/dev/null || true")" ] || fail "the partial backup is left: $(h ls -A "$backups")"
  newest_backup "$new_version" "$next_version" >/dev/null
  expect_no_progress "after the update that followed the stopped backup"
  iv_converge_unchanged "$next_version"
  expect_item read

  echo "== interrupted: stopped once the compose file names the new version (ubuntu $1)"
  play_killed "grep -qF 'vaultwarden:$after_version\"' $app_dir/compose.yaml" \
    -e "vaultwarden_image=$test_repo" -e "vaultwarden_version=$after_version"
  h grep -qx 'step: update' "$progress" || fail "the marker does not record the step update: $(h cat "$progress")"
  h grep -qx "from_version: $next_version" "$progress" || fail "the marker does not name $next_version: $(h cat "$progress")"
  h grep -qx "to_version: $after_version" "$progress" || fail "the marker does not name $after_version: $(h cat "$progress")"
  backup="$(h sed -n 's/^backup: //p' "$progress")"
  h grep -qF "vaultwarden:$next_version\"" "$backup/compose.yaml" || fail "the backup $backup is not the one of $next_version"
  for file in "$progress" "$progress.compose.yaml" "$progress.secrets"; do
    [ "$(h stat -c '%a %U' "$file")" = "$([ "$file" = "$progress.secrets" ] && echo 700 || echo 600) root" ] \
      || fail "$file is not root's only: $(h stat -c '%a %U' "$file")"
  done
  # A change after the backup, which the restore must undo.
  h python3 -c "$sentinel_sql"'; db.execute("CREATE TABLE noix_sentinel (id integer)"); db.commit()' "$data_dir/vaultwarden/db.sqlite3"
  note_untouched
  iv_converge_fails "$after_version"
  expect_in_log "$progress exists: the Vaultwarden update from $next_version to $after_version did not finish"
  expect_in_log "the backup from before it is $backup"
  expect_in_log "set vaultwarden_restore_interrupted: true for one run to restore it"
  expect_in_log "or remove $progress to keep Vaultwarden as it is now"
  expect_untouched

  # Restored with the variable: the previous version with its data, and no
  # update. update-failed of an earlier update to another version, rolled
  # back, stays: the restore ran no version but the one it had.
  failed_other="$(printf 'failed_version: 1.37.9\nrolled_back_to: %s\nbackup: %s\ntime: "2026-01-01T00:00:00Z"' \
    "$next_version" "$backups/20260101T000000Z-$next_version-to-1.37.9")"
  printf '%s\n' "$failed_other" | hi sh -c "cat >$marker"
  iv_converge "$after_version" -vvv -e vaultwarden_restore_interrupted=true
  expect_in_log "Vaultwarden in $app_dir runs $next_version again"
  if grep -qF 'Stop Vaultwarden for the update' "$out/converge.log"; then fail "the restore tried the update again"; fi
  [ "$(vw_service)" = "$test_repo:$next_version running healthy" ] || fail "Vaultwarden after the restore: $(vw_service)"
  expect_no_progress "after the restore"
  [ "$(h cat "$marker" 2>&1)" = "$failed_other" ] || fail "the restore did not keep $marker of 1.37.9 as it was: $(h cat "$marker" 2>&1)"
  h rm "$marker"
  ! has_sentinel || fail "the restore kept the database changed after the backup"
  h test -d "$backup-failed/vaultwarden" || fail "the restore did not set the data it found aside to $backup-failed"
  expect_compose_clean
  expect_item read
  # The variable is refused once the update is restored.
  note_untouched
  iv_converge_fails "$after_version" -e vaultwarden_restore_interrupted=true
  expect_in_log "vaultwarden_restore_interrupted is set, but there is no interrupted update"
  expect_untouched

  # Without the variable the next run updates.
  iv_converge "$after_version"
  [ "$(vw_service)" = "$test_repo:$after_version running healthy" ] || fail "Vaultwarden after the update: $(vw_service)"
  expect_no_progress "after the update that followed the restore"
  iv_converge_unchanged "$after_version"
  expect_item read
}

# What the other scenarios leave out: every converge of the suite runs at -v
# and is scanned (play), each install, reconfigure, update and rollback of
# the three modes among them, and the process list is sampled during the
# updates (the dumps) and the rollbacks (the restores); here a reconfigure
# with the external PostgreSQL (a new push key) at -vvv while the process
# list is sampled.
test_secrets() {
  echo "== secrets (ubuntu $1)"
  ensure_external_installed secrets
  current_push_key="$rotated_push_key"
  write_install_vars
  ps_start
  ext_converge -vvv
  ps_check "a reconfigure with the external PostgreSQL" psql
  grep -qF 'as config file' "$out/converge.log" || grep -qF 'No config file found' "$out/converge.log" \
    || fail "the converge did not run verbosely"
  grep -qF 'reconfigure.yml' "$out/converge.log" || fail "the new push key was not a reconfigure"
  [ "$(h cat "$secrets_dir/push_installation_key")" = "$rotated_push_key" ] || fail "the new push key was not written"
  ext_converge_unchanged
  expect_item read
}

# All scenarios by default; NOIXDEV_INFRA_VAULTWARDEN_TESTS="install" runs only
# these. A new scenario is a test_<name> function and one line in the case
# below.
all_scenarios="refusals install config_json missing_data mountpoint noop_down reconfigure interrupted failed_update_sqlite update_sqlite install_postgres mode_switch db_password failed_update_postgres update_postgres external_refusals install_external target_changed failed_update_external update_external secrets"
scenarios="${NOIXDEV_INFRA_VAULTWARDEN_TESTS:-$all_scenarios}"
for ubuntu in $releases; do
  out="$tests/output/vaultwarden-$ubuntu"
  mkdir -p "$out"
  start_host "$ubuntu"
  for scenario in $scenarios; do
    case "$scenario" in
      refusals) test_refusals "$ubuntu" ;;
      install) test_install "$ubuntu" ;;
      config_json) test_config_json "$ubuntu" ;;
      missing_data) test_missing_data "$ubuntu" ;;
      mountpoint) test_mountpoint "$ubuntu" ;;
      noop_down) test_noop_down "$ubuntu" ;;
      reconfigure) test_reconfigure "$ubuntu" ;;
      install_postgres) test_install_postgres "$ubuntu" ;;
      mode_switch) test_mode_switch "$ubuntu" ;;
      db_password) test_db_password "$ubuntu" ;;
      external_refusals) test_external_refusals "$ubuntu" ;;
      install_external) test_install_external "$ubuntu" ;;
      target_changed) test_target_changed "$ubuntu" ;;
      failed_update_sqlite) test_failed_update_sqlite "$ubuntu" ;;
      update_sqlite) test_update_sqlite "$ubuntu" ;;
      failed_update_postgres) test_failed_update_postgres "$ubuntu" ;;
      update_postgres) test_update_postgres "$ubuntu" ;;
      failed_update_external) test_failed_update_external "$ubuntu" ;;
      update_external) test_update_external "$ubuntu" ;;
      interrupted) test_interrupted "$ubuntu" ;;
      secrets) test_secrets "$ubuntu" ;;
      *) fail "unknown scenario $scenario ($all_scenarios)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all vaultwarden tests passed"
