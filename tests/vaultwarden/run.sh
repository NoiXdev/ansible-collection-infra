#!/usr/bin/env bash
# End-to-end test of the vaultwarden role on a throwaway systemd host per
# Ubuntu release, with Docker inside (the docker role), the traefik role in
# front (plain HTTP and HTTPS with Traefik's own certificate on 127.0.0.1, and
# a "deny" middleware; vars.yml) and Mailpit catching the mail (converge.yml):
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
#             /alive and /api/ still answering) and the admin page switched
#             off (Vaultwarden's own disabled page, no admin router, no
#             admin_token file)
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
#             restarts Vaultwarden, which reads the new secrets file; a new
#             vaultwarden_invitation_org_name restarts it too, and an invite
#             mail names it; the item is still readable
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
#             is missing)
#   db_password
#             a new vaultwarden_db_password the database does not have refused
#             before any change; taken once ALTER USER set it, with Vaultwarden
#             restarted on it and the item still readable
#   external_refusals
#             a fresh install against a PostgreSQL server of the test host
#             refused before anything is created: a wrong password, a
#             server without TLS with sslmode require, a user who does not own
#             the database, a PostgreSQL 14 server, a database that holds a
#             table
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
# Every converge's output must not hold a test secret, and every successful
# converge of a scenario is repeated and must change nothing.
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
admin_token="$(openssl rand -hex 12)"' ad$m"in tok'
smtp_password="$(openssl rand -hex 12)"' sm$t"p pw'
rotated_smtp_password="$(openssl rand -hex 12)"' ro$t"ated pw'
push_key="$(openssl rand -hex 16)"
push_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
user_password="$(openssl rand -hex 12)"' us$e"r pw'
item_password="$(openssl rand -hex 12)"
# The Argon2id hash of admin_token, made once per run (make_admin_hash).
admin_hash=
# What install-vars.json holds; the reconfigure scenario changes them.
org_name='Noix Test Org'
current_smtp_password="$smtp_password"
# No converge's output may hold one of these; make_admin_hash adds the hash.
pg_admin_password="$(openssl rand -hex 12)"
secrets=("$db_password" "$new_db_password" "$admin_token" "$smtp_password" "$rotated_smtp_password" "$push_key" "$user_password" "$pg_admin_password")

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

# play [-e ...]: the test host's playbook; its output goes to converge.log,
# which must hold no test secret, whether the run failed or not.
play() {
  local rc=0
  ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$here/converge.yml" "$@" >"$out/converge.log" 2>&1 || rc=$?
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
      "PUSH_ID=$push_id" "PUSH_KEY=$push_key" python3 -c '
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

# start_host <ubuntu>: a fresh systemd host with Docker, Traefik and Mailpit,
# where vaultwarden.test is 127.0.0.1 and client.py is /root/client.py.
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
  h sh -c 'echo "127.0.0.1 vaultwarden.test" >>/etc/hosts'
  docker cp "$here/client.py" "$host:/root/client.py" >/dev/null

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

# Makes the Argon2id hash of admin_token once per run, with Vaultwarden's own
# command as the docs give it (docker run -it ... /vaultwarden hash). It reads
# the token twice from a terminal, which script provides; the token goes
# through stdin. Then writes install-vars.json.
make_admin_hash() {
  if [ -z "$admin_hash" ]; then
    h docker pull -q "$image" >/dev/null
    admin_hash="$(printf '%s\n%s\n' "$admin_token" "$admin_token" \
      | hi docker run --rm -i --network=none --entrypoint sh "$image" -c 'script -qec "/vaultwarden hash" /dev/null' \
      | grep -o "[\$]argon2id[^']*" || true)"
    [[ "$admin_hash" == '$argon2id$v=19$'* ]] || fail "/vaultwarden hash made no Argon2id hash"
    secrets+=("$admin_hash")
  fi
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
# syncs and prints the item's password ("read" only reads). The passwords go
# through an env file of mode 0600 on the test host, not a command line.
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
bw get password noix-test --nointeraction
'
bw_cli() {
  if ! h docker image inspect "$bw_image" >/dev/null 2>&1; then
    printf 'FROM %s\nRUN npm install --global --no-audit --no-fund @bitwarden/cli@%s\n' "$node_image" "$bw_cli_version" \
      | hi docker build -q -t "$bw_image" - >/dev/null
  fi
  printf 'BW_PASSWORD=%s\nBW_ITEM=%s\n' "$user_password" "$item_password" | hi sh -c 'umask 077; cat >/root/bw.env'
  printf '%s' "$bw_script" | hi docker run --rm -i --network host --add-host vaultwarden.test:127.0.0.1 \
    --env NODE_TLS_REJECT_UNAUTHORIZED=0 --env "BW_SERVER=$base" --env "BW_EMAIL=$user_email" \
    --env-file /root/bw.env "$bw_image" sh -s "$1" 2>"$out/bw.log"
}
# Fails unless the CLI reads the item's password back: expect_item create|read.
expect_item() {
  local got
  got="$(bw_cli "$1")" || { cat "$out/bw.log" >&2; fail "the Bitwarden CLI failed ($1)"; }
  [ "$got" = "$item_password" ] || { cat "$out/bw.log" >&2; fail "the Bitwarden CLI read another item password ($1): ${got:0:40}"; }
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
}

test_install() {
  local answer
  echo "== install (ubuntu $1)"
  make_admin_hash
  vw_converge
  expect_compose_clean
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

  echo "== install: the admin router (ubuntu $1)"
  vw_converge -e '{"vaultwarden_traefik_admin_middlewares": ["deny@file"]}'
  wait_denied /admin
  expect_denied /admin/users/overview
  expect_answer 200 '' /alive
  expect_answer 200 '"version"' /api/config
  vw_converge_unchanged -e '{"vaultwarden_traefik_admin_middlewares": ["deny@file"]}'

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
  id="$(container_id)"
  secret="$(h sha256sum "$secrets_dir/smtp_password")"
  current_smtp_password="$rotated_smtp_password"
  write_install_vars
  vw_converge
  grep -Eq 'changed=[1-9]' "$out/converge.log" || fail "the new SMTP password changed nothing"
  [ "$(h sha256sum "$secrets_dir/smtp_password")" != "$secret" ] || fail "the secrets file of the SMTP password did not change"
  [ "$(container_id)" != "$id" ] || fail "Vaultwarden was not restarted for the new SMTP password"
  [ "$(compose exec -T vaultwarden cat /run/secrets-vw/smtp_password)" = "$rotated_smtp_password" ] \
    || fail "the container does not read the new SMTP password"
  vw_converge_unchanged

  # Another organization name: in the compose file, and in the next invite.
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
  h mv "$data_dir/postgres.aside" "$data_dir/postgres"
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
pg_server() {
  local name="$1" major="$2" port="$3"
  h docker inspect "$name" >/dev/null 2>&1 && return 0
  printf 'POSTGRES_PASSWORD=%s\n' "$pg_admin_password" | hi sh -c 'umask 077; cat >/root/pg.env'
  h docker run --detach --name "$name" --env-file /root/pg.env --publish "$pg_ip:$port:5432" "docker.io/library/postgres:$major" >/dev/null
  # Over TCP: the init server of the image listens on its socket only.
  until h docker exec "$name" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do sleep 1; done
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
  # The 14 server and the table are what the messages say, and no refusal
  # touched them.
  [ "$(h docker exec noixdev-vaultwarden-pg psql --username=vaultwarden --dbname=vaultwarden --no-psqlrc \
    --tuples-only --no-align --command='SELECT count(*) FROM pg_tables WHERE schemaname = $$public$$')" = 0 ] \
    || fail "a refused run made tables in the external database"
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
  # server's major) ran the checks.
  h docker image inspect docker.io/library/postgres:16 >/dev/null 2>&1 || fail "the client image of the server's major was not used"
  ext_sql 'SELECT count(*) FROM users' >/dev/null || fail "no users table in the external database"

  # A run without changes, while the process list is sampled: no password in
  # any command line, with the one-off client containers started.
  h rm -f /root/ps.log /root/ps.stop
  docker exec -d "$host" sh -c 'while [ ! -e /root/ps.stop ]; do ps -eo args >>/root/ps.log; sleep 0.1; done'
  ext_converge_unchanged
  h touch /root/ps.stop
  sleep 1
  h cat /root/ps.log >"$out/ps.log"
  [ -s "$out/ps.log" ] || fail "the process list was not sampled"
  expect_no_secrets "$out/ps.log" "the process list"
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
  expect_item read
}

# All scenarios by default; NOIXDEV_INFRA_VAULTWARDEN_TESTS="install" runs only
# these. A new scenario is a test_<name> function and one line in the case
# below.
all_scenarios="refusals install config_json missing_data mountpoint noop_down reconfigure install_postgres mode_switch db_password external_refusals install_external target_changed"
scenarios="${NOIXDEV_INFRA_VAULTWARDEN_TESTS:-$all_scenarios}"
for ubuntu in $releases; do
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
      *) fail "unknown scenario $scenario ($all_scenarios)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all vaultwarden tests passed"
