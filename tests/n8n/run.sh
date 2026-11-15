#!/usr/bin/env bash
# End-to-end test of the n8n role on throwaway Docker-in-Docker hosts (a
# fresh one per scenario), with the traefik role in front:
#   refusals  invalid settings refused before any change (each required
#             secret and owner setting missing, role-owned keys in n8n_env,
#             a key without a value or a bad name in it, a version that is
#             not 2.X.Y or older than 2.17.0, PostgreSQL older than 18, no
#             host name); nothing under /opt/n8n afterwards
#   install   a failed install (n8n does not start) that stops the stack
#             and that every later run refuses until it is removed as its
#             message says; then a fresh install (verify.yml: containers,
#             environment and mounts, the owner's login through Traefik, the
#             owner locked against changes through the API, a workflow with a
#             Webhook node created and activated through the API that answers
#             its production webhook, a $ reaching the container verbatim,
#             the compose file 0600, the key's fingerprint, no published
#             port); a new owner password as a reconfigure (the old one no
#             longer logs in, the new one does); a run without changes that
#             fails on a stopped container; a changed n8n_db_password refused
#             before any change, a compose file that is not YAML refused
#             without a line of it in the output, and the new password taken
#             once the database has it (ALTER USER, as the refusal says)
#   router    the UI and the public endpoints on their own routers: with a
#             middleware that denies everything on the UI, /, /rest/ and
#             /api/v1/ are denied by Traefik while /webhook/ and /form/ still
#             reach n8n; with n8n_traefik_public_api /api/v1/ reaches n8n too
#             (401 without a key); with the middleware on the public router
#             only, the reverse
#   queue     an install in queue mode with one worker (verify.yml: Valkey
#             without a volume or bind, the workers with the main instance's
#             image and environment, all healthy); the production webhook
#             answers through the main instance and its execution runs on the
#             worker (the main instance's log enqueues it, the worker's log
#             starts it); a run without changes that fails on a stopped
#             worker; two workers, then back to normal mode (no Valkey,
#             no workers), then queue mode again, each a reconfigure that
#             keeps the workflow active and its webhook answering
# The failed install runs at -v, the install and the refusals on an
# installation at -vvv, every other converge at -v; their output must not
# hold a test secret (nor the owner's password hash). Every successful
# converge is repeated and must change nothing (the owner's password hash
# among it).
# NOIXDEV_INFRA_N8N_TESTS selects scenarios (see the end of the file);
# NOIXDEV_INFRA_N8N_TEST_HOST and NOIXDEV_INFRA_N8N_TEST_OUT (the directory
# of the logs and image tarballs) let two runs go side by side.
# The single-quoted scripts expand inside the container, not here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
host="${NOIXDEV_INFRA_N8N_TEST_HOST:-noixdev-infra-n8n-test}"
out="${NOIXDEV_INFRA_N8N_TEST_OUT:-$tests/output/n8n}"
dir=/opt/n8n
defaults="$root/roles/n8n/defaults/main.yml"
traefik_defaults="$root/roles/traefik/defaults/main.yml"

# The value of a top-level key in a YAML file: value_of <file> <key>.
value_of() { sed -n "s/^$2: *//p" "$1" 2>/dev/null || true; }
version="$(value_of "$defaults" n8n_version)"
images=(
  "$(value_of "$defaults" n8n_image):$version"
  "$(value_of "$defaults" n8n_postgres_image)"
  "$(value_of "$defaults" n8n_redis_image)"
  "$(value_of "$traefik_defaults" traefik_image)"
  "$(value_of "$traefik_defaults" traefik_socket_proxy_image)"
)
owner_email="$(value_of "$here/vars.yml" n8n_owner_email)"
owner_password="$(value_of "$here/vars.yml" n8n_owner_password)"
# The owner password and the database password the install scenario rotates
# to; a $ that compose and a shell must not expand.
rotated_owner_password='Test-owner-ro$tated-0'
rotated_db_password='test-db-ro$tated-pass-0'
# The test secrets, which no run's output may hold; the install adds the
# owner's password hash.
secrets=(
  "$(value_of "$here/vars.yml" n8n_encryption_key)"
  "$(value_of "$here/vars.yml" n8n_db_password)"
  "$owner_password"
  "$rotated_owner_password"
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
# The n8n role alone (no Traefik) that must fail: role_fails <name> [extra
# vars...]; its output goes to $out/<name>.log.
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
  play "$here/converge.yml" -v "$@" >"$out/rerun.log" 2>&1 || { cat "$out/rerun.log" >&2; fail "a repeated converge failed"; }
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/rerun.log" || { cat "$out/rerun.log" >&2; fail "a repeated converge changed something"; }
  expect_no_secrets rerun
}
converge() {
  play "$here/converge.yml" "$@" >"$out/converge.log" 2>&1 || { tail -n 60 "$out/converge.log" >&2; fail "the converge failed"; }
}
# The containers of the compose project, running or not.
containers() { hx docker ps -aq --filter label=com.docker.compose.project=n8n; }
# The image, state and health of a service: service <name>.
service() { hx sh -c "cd $dir && docker compose ps --all --format '{{.Image}} {{.State}} {{.Health}}' $1"; }
# Waits until the n8n container is healthy again: Traefik routes to it only
# then.
wait_healthy() {
  for _ in $(seq 60); do
    [ "$(hx sh -c "cd $dir && docker compose ps --format '{{.Health}}' n8n")" = healthy ] && return 0
    sleep 3
  done
  fail "the n8n container did not become healthy: $(hx sh -c "cd $dir && docker compose ps --all")"
}
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

# A fresh Docker-in-Docker host.
new_host() {
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  docker run -d --privileged --name "$host" docker:29-dind >/dev/null
  until hx docker info >/dev/null 2>&1; do sleep 1; done
  # Retried: the host's first DNS lookups fail now and then.
  for _ in 1 2 3; do hx apk add --no-cache python3 curl >/dev/null && return 0; sleep 3; done
  fail "cannot install python3 and curl on the test host"
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
# Loads the role's and Traefik's images into the host.
load_images() {
  local image
  for image in "${images[@]}"; do
    case "$image" in
      "" | :* | *:) fail "an image is missing in $defaults or $traefik_defaults" ;;
    esac
  done
  load_set "${images[@]}"
}
# A request through Traefik: prints the body, then the status on a line of
# its own. request <path> [curl options...].
request() {
  local path="$1"
  shift
  hx curl -s -H 'Host: n8n.test' -w '\n%{http_code}' "$@" "http://127.0.0.1$path"
}
# expect_answer <status> <body text> <path> [curl options...]: the status
# and a body that holds the text.
expect_answer() {
  local status="$1" text="$2" path="$3" answer
  shift 3
  answer="$(request "$path" "$@")"
  [ "${answer##*$'\n'}" = "$status" ] && [[ "${answer%$'\n'*}" == *"$text"* ]] \
    || fail "$path answered ${answer##*$'\n'} ($(printf '%s' "${answer%$'\n'*}" | head -c 200)), not $status with: $text"
}
# Traefik's own 403 of the ipAllowList middleware: the body is Forbidden.
expect_denied() {
  local answer
  answer="$(request "$@")"
  [ "$answer" = $'Forbidden\n403' ] || fail "$1 was not denied by Traefik: ${answer##*$'\n'} $(printf '%s' "${answer%$'\n'*}" | head -c 200)"
}
# Fails when Traefik denies the path: n8n answered it, whatever it said.
expect_reaches_n8n() {
  local answer
  answer="$(request "$@")"
  [ "${answer##*$'\n'}" != 403 ] && [ "${answer##*$'\n'}" != 000 ] \
    || fail "$1 did not reach n8n: ${answer##*$'\n'} $(printf '%s' "${answer%$'\n'*}" | head -c 200)"
}
# Waits until Traefik denies the path (it reads new labels within seconds).
wait_denied() {
  for _ in $(seq 30); do
    [ "$(request "$@")" = $'Forbidden\n403' ] && return 0
    sleep 1
  done
  expect_denied "$@"
}
# The status of the owner's login through Traefik with a password; the
# password goes through stdin, not a command line. login_status <password>.
login_status() {
  printf '{"emailOrLdapLoginId": "%s", "password": "%s"}' "$owner_email" "$1" \
    | docker exec -i "$host" curl -s -o /dev/null -w '%{http_code}' -H 'Host: n8n.test' \
      -H 'Content-Type: application/json' -H 'browser-id: noix-test' --data-binary @- http://127.0.0.1/rest/login
}
# Waits until Traefik routes the login to n8n (a new container after a
# reconfigure) and fails unless it answers the status: expect_login <status>
# <password>.
expect_login() {
  local status
  for _ in $(seq 30); do
    status="$(login_status "$2")"
    [ "$status" = "$1" ] && return 0
    case "$status" in 401 | 200) break ;; esac
    sleep 2
  done
  fail "the owner's login answered $status, not $1"
}
# Adds the owner's password hash of the installation to the secrets: no log
# may hold it either.
note_owner_hash() {
  local owner_hash
  owner_hash="$(hx sh -c "cd $dir && docker compose exec -T n8n printenv N8N_INSTANCE_OWNER_PASSWORD_HASH")"
  [[ "$owner_hash" == '$2b$10$'* ]] || fail "the n8n container has no bcrypt owner hash"
  secrets+=("$owner_hash")
}
# Sets the password of the database user n8n, as the refusal of a changed
# n8n_db_password says, over the local socket and through stdin:
# set_db_password <password>.
set_db_password() {
  local quote="'"
  printf "ALTER USER n8n PASSWORD '%s';\n" "${1//$quote/$quote$quote}" \
    | docker exec -i "$host" sh -c "cd $dir && docker compose exec -T db psql -q -U n8n -d postgres -v ON_ERROR_STOP=1" \
    || fail "cannot set the password of the database user"
}
# The id of the database container.
db_id() { hx sh -c "cd $dir && docker compose ps --quiet db"; }
# Runs SQL from the argument in n8n's database (the local socket needs no
# password) and prints the rows unaligned: sql <statement>.
sql() {
  printf '%s\n' "$1" \
    | docker exec -i "$host" sh -c "cd $dir && docker compose exec -T db psql -q -U n8n -d n8n -tA -v ON_ERROR_STOP=1"
}
# The log of a compose service: logs <service>.
logs() { hx sh -c "cd $dir && docker compose logs --no-color --no-log-prefix $1"; }
# Fails unless the services of the compose project are exactly these:
# expect_services <service...>.
expect_services() {
  local found
  found="$(hx sh -c "cd $dir && docker compose ps --all --format '{{.Service}}'" | sort | tr '\n' ' ')"
  [ "$found" = "$(printf '%s\n' "$@" | sort | tr '\n' ' ')" ] || fail "the services are $found, not $*"
}
# Fails unless the webhook workflow is active, as the database records it
# (no login: n8n allows five a minute).
expect_workflow_active() {
  local active
  active="$(sql "SELECT active FROM workflow_entity WHERE name = 'noix-test'")"
  [ "$active" = t ] || fail "the webhook workflow is not active: '$active'"
}
# Calls the production webhook and fails unless it answers and its
# execution ran on one of the workers: the main instance's log enqueues it
# and a worker's log starts it. expect_ran_on_worker <worker service...>.
expect_ran_on_worker() {
  local id worker
  expect_answer 200 '"ok":true' /webhook/noix-test -X POST
  id="$(sql 'SELECT max(id) FROM execution_entity')"
  [ -n "$id" ] || fail "the webhook left no execution in the database"
  logs n8n | grep -qF "Enqueued execution $id (job" || fail "the main instance did not enqueue execution $id"
  for _ in $(seq 10); do
    for worker in "$@"; do
      logs "$worker" | grep -qF "Worker started execution $id (job" && return 0
    done
    sleep 1
  done
  fail "no worker of $* started execution $id"
}
# Fails unless the Valkey container has no mount at all (no volume, no
# bind): it keeps the queue in memory only.
expect_redis_without_mounts() {
  local mounts
  mounts="$(hx sh -c "docker inspect --format '{{json .Mounts}}' \$(cd $dir && docker compose ps --quiet redis)")"
  [ "$mounts" = '[]' ] || fail "the redis service has mounts: $mounts"
}

# The scenarios, run by the loop at the end.
test_refusals() {
  echo "== invalid settings must be refused before any change"
  new_host
  local name
  for name in n8n_encryption_key n8n_db_password n8n_owner_email n8n_owner_first_name n8n_owner_last_name n8n_owner_password; do
    role_fails "missing-$name" -e "$name="
    expect_in_log "missing-$name" "$name is required"
  done
  role_fails bad-email -e n8n_owner_email=owner
  expect_in_log bad-email "n8n_owner_email is required"
  role_fails no-hostname -e n8n_hostname=
  expect_in_log no-hostname n8n_hostname
  role_fails owned-env -e '{"n8n_env": {"EXECUTIONS_MODE": "queue"}}'
  expect_in_log owned-env n8n_env
  expect_in_log owned-env "the role sets these itself: EXECUTIONS_MODE"
  role_fails owned-env-prefix -e '{"n8n_env": {"DB_POSTGRESDB_HOST": "x", "QUEUE_BULL_REDIS_HOST": "y"}}'
  expect_in_log owned-env-prefix "DB_POSTGRESDB_HOST, QUEUE_BULL_REDIS_HOST"
  role_fails owned-env-owner -e '{"n8n_env": {"N8N_INSTANCE_OWNER_PASSWORD_HASH": "x", "N8N_ENCRYPTION_KEY": "y"}}'
  expect_in_log owned-env-owner "N8N_ENCRYPTION_KEY, N8N_INSTANCE_OWNER_PASSWORD_HASH"
  role_fails owned-env-url -e '{"n8n_env": {"WEBHOOK_URL": "http://x.test/", "N8N_USER_FOLDER": "/tmp"}}'
  expect_in_log owned-env-url "N8N_USER_FOLDER, WEBHOOK_URL"
  role_fails env-key -e '{"n8n_env": {"lower": "x"}}'
  expect_in_log env-key n8n_env
  # A key left empty in YAML would reach n8n as the text None.
  role_fails env-null -e '{"n8n_env": {"NOIX_EMPTY": null}}'
  expect_in_log env-null "n8n_env has no value for NOIX_EMPTY"
  # Before 2.17.0 n8n does not take the owner from the environment.
  role_fails v2-16 -e n8n_version=2.16.0
  expect_in_log v2-16 "n8n_version 2.16.0"
  role_fails v1 -e n8n_version=1.123.96
  expect_in_log v1 "n8n_version 1.123.96"
  role_fails v-prefix -e n8n_version=v2.47.7
  expect_in_log v-prefix "n8n_version v2.47.7"
  role_fails postgres-17 -e n8n_postgres_image=docker.io/library/postgres:17
  expect_in_log postgres-17 "PostgreSQL 18 or newer"
  expect_in_log postgres-17 "n8n_postgres_image docker.io/library/postgres:17 is PostgreSQL 17"
  expect_unchanged postgres-17
  hx test ! -e "$dir" || fail "n8n touched the host before refusing its settings: $(hx find "$dir" | head)"
}

test_install() {
  echo "== a failed install must stop the stack and be refused until it is removed"
  new_host
  load_images
  # Node refuses to start with an unknown option in NODE_OPTIONS: the
  # database runs, n8n never becomes healthy.
  play_fails install-failed "$here/converge.yml" -v -e n8n_health_timeout=20 \
    -e '{"n8n_env": {"NODE_OPTIONS": "--noix-unknown-option"}}'
  expect_in_log install-failed "The install of n8n $version in $dir failed (Fail when n8n is not healthy:"
  expect_in_log install-failed "check that nothing in it is worth keeping"
  expect_in_log install-failed "docker compose down in $dir"
  expect_in_log install-failed "remove $dir/compose.yaml, $dir/encryption-key.sha256, $dir/install-incomplete"
  expect_in_log install-failed "the subdirectories postgres, home and files of $dir/data"
  expect_no_secrets install-failed
  hx test -e "$dir/install-incomplete" || fail "the failed install left no marker"
  [ -z "$(hx docker ps -q --filter label=com.docker.compose.project=n8n)" ] \
    || fail "the failed install left containers running: $(hx docker ps --format '{{.Names}}' --filter label=com.docker.compose.project=n8n)"
  note_untouched
  play_fails install-incomplete "$here/converge.yml"
  expect_in_log install-incomplete "$dir/install-incomplete exists"
  expect_in_log install-incomplete "docker compose down in $dir"
  expect_untouched install-incomplete
  # As the message says; the install then starts afresh.
  hx sh -c "cd $dir && docker compose down" >/dev/null 2>&1
  hx rm -rf "$dir"

  echo "== install"
  converge -vvv
  expect_no_secrets converge
  hx test ! -e "$dir/install-incomplete" || fail "the install kept its marker"
  note_owner_hash
  expect_no_secrets converge
  expect_idempotent
  play "$here/verify.yml"

  echo "== a new owner password must be a reconfigure that n8n applies"
  converge -v -e "n8n_owner_password=$rotated_owner_password"
  expect_no_secrets converge
  grep -q "reconfigure.yml" "$out/converge.log" || fail "the new owner password was not a reconfigure"
  note_owner_hash
  expect_no_secrets converge
  wait_healthy
  expect_login 401 "$owner_password"
  expect_login 200 "$rotated_owner_password"
  expect_idempotent -e "n8n_owner_password=$rotated_owner_password"

  echo "== a run without changes must fail on a stopped container and start nothing"
  hx sh -c "cd $dir && docker compose stop n8n" >/dev/null 2>&1
  play_fails stopped "$here/converge.yml" -e "n8n_owner_password=$rotated_owner_password"
  expect_in_log stopped "the services n8n are not running"
  expect_unchanged stopped
  [ -z "$(hx sh -c "cd $dir && docker compose ps --quiet n8n")" ] || fail "the run started n8n"
  hx sh -c "cd $dir && docker compose start n8n" >/dev/null 2>&1
  wait_healthy

  echo "== a changed database password must be refused before any change"
  note_untouched
  play_fails db-password "$here/converge.yml" -vvv -e "n8n_owner_password=$rotated_owner_password" \
    -e "n8n_db_password=$rotated_db_password"
  expect_in_log db-password "n8n_db_password differs from the password in $dir/compose.yaml, and the database does not take it"
  expect_in_log db-password "ALTER USER"
  expect_no_secrets db-password
  expect_untouched db-password
  [ "$(service n8n)" = "${images[0]} running healthy" ] || fail "n8n after the refused run: $(service n8n)"

  echo "== a compose file that is not YAML must be refused without showing a line of it"
  hx cp -p "$dir/compose.yaml" /root/compose.yaml
  # The line of the database password, as a hand edit could break it.
  hx sed -i 's/^\( *POSTGRES_PASSWORD: .*\)$/\1 broken/' "$dir/compose.yaml"
  note_untouched
  play_fails compose-not-yaml "$here/converge.yml" -vvv -e "n8n_owner_password=$rotated_owner_password"
  expect_in_log compose-not-yaml "$dir/compose.yaml is not YAML"
  expect_no_secrets compose-not-yaml
  expect_untouched compose-not-yaml
  if grep -qF -- "broken" "$out/compose-not-yaml.log"; then
    fail "the refusal shows a line of the compose file: $(grep -nF -- broken "$out/compose-not-yaml.log" | head -n 3 | cut -c1-80)"
  fi
  hx cp -p /root/compose.yaml "$dir/compose.yaml"
  expect_idempotent -e "n8n_owner_password=$rotated_owner_password"

  echo "== a password changed in the database as the refusal says must be taken"
  set_db_password "$rotated_db_password"
  db_before="$(db_id)"
  converge -v -e "n8n_owner_password=$rotated_owner_password" -e "n8n_db_password=$rotated_db_password"
  expect_no_secrets converge
  grep -q "reconfigure.yml" "$out/converge.log" || fail "the new database password was not a reconfigure"
  [ "$(service n8n)" = "${images[0]} running healthy" ] || fail "n8n after the new password: $(service n8n)"
  [ "$(db_id)" != "$db_before" ] || fail "the database container still has the old password in its environment"
  expect_login 200 "$rotated_owner_password"
  expect_idempotent -e "n8n_owner_password=$rotated_owner_password" -e "n8n_db_password=$rotated_db_password"
}

test_router() {
  if ! hx test -e "$dir/compose.yaml" 2>/dev/null; then
    echo "== install for the router tests"
    new_host
    load_images
    converge
    play "$here/verify.yml"
  fi
  # The settings the install scenario left, when it ran before.
  local settings=()
  [ "$(hx sh -c "cd $dir && docker compose exec -T n8n printenv DB_POSTGRESDB_PASSWORD")" != "$rotated_db_password" ] \
    || settings=(-e "n8n_owner_password=$rotated_owner_password" -e "n8n_db_password=$rotated_db_password")
  converge -v ${settings[@]+"${settings[@]}"}
  wait_healthy
  expect_answer 200 '"ok":true' /webhook/noix-test -X POST

  echo "== a middleware on the UI must leave the public endpoints to n8n"
  converge -vvv ${settings[@]+"${settings[@]}"} -e '{"n8n_traefik_middlewares": ["deny@file"]}'
  expect_no_secrets converge
  grep -q "reconfigure.yml" "$out/converge.log" || fail "the changed middlewares were not a reconfigure"
  expect_idempotent ${settings[@]+"${settings[@]}"} -e '{"n8n_traefik_middlewares": ["deny@file"]}'
  wait_healthy
  wait_denied /
  expect_denied /rest/login -X POST
  expect_denied /api/v1/workflows
  expect_answer 200 '"ok":true' /webhook/noix-test -X POST
  expect_reaches_n8n /webhook-test/noix-test -X POST
  expect_reaches_n8n /form/x
  expect_reaches_n8n /form-test/x
  expect_reaches_n8n /mcp/x

  echo "== n8n_traefik_public_api must put /api/v1/ on the public router"
  converge -v ${settings[@]+"${settings[@]}"} -e '{"n8n_traefik_middlewares": ["deny@file"], "n8n_traefik_public_api": true}'
  expect_no_secrets converge
  for _ in $(seq 30); do
    [ "$(request /api/v1/workflows -o /dev/null)" = $'\n401' ] && break
    sleep 1
  done
  # n8n's own 401 without an API key.
  expect_answer 401 '"message":"Unauthorized"' /api/v1/workflows
  expect_denied /
  expect_answer 200 '"ok":true' /webhook/noix-test -X POST
  expect_idempotent ${settings[@]+"${settings[@]}"} -e '{"n8n_traefik_middlewares": ["deny@file"], "n8n_traefik_public_api": true}'

  echo "== a middleware on the public router must leave the UI alone"
  converge -v ${settings[@]+"${settings[@]}"} -e '{"n8n_traefik_webhook_middlewares": ["deny@file"]}'
  wait_healthy
  wait_denied /webhook/noix-test -X POST
  expect_denied /form/x
  expect_answer 401 '"message":"Unauthorized"' /api/v1/workflows
  expect_reaches_n8n /
  expect_reaches_n8n /rest/login -X POST

  echo "== without middlewares everything must reach n8n again"
  converge -v ${settings[@]+"${settings[@]}"}
  wait_healthy
  for _ in $(seq 30); do
    [ "$(request /webhook/noix-test -o /dev/null -X POST)" = $'\n200' ] && break
    sleep 1
  done
  expect_answer 200 '"ok":true' /webhook/noix-test -X POST
  expect_reaches_n8n /
  expect_idempotent ${settings[@]+"${settings[@]}"}
}

test_queue() {
  echo "== queue mode: the webhook's execution must run on the worker"
  new_host
  load_images
  converge -vvv -e n8n_workers=1
  expect_no_secrets converge
  note_owner_hash
  expect_no_secrets converge
  expect_idempotent -e n8n_workers=1
  expect_services db n8n redis worker-1
  expect_redis_without_mounts
  # Creates and activates the webhook workflow, which answers through the
  # main instance.
  play "$here/verify.yml" -e n8n_workers=1
  expect_ran_on_worker worker-1

  echo "== a run without changes must fail on a stopped worker and start nothing"
  hx sh -c "cd $dir && docker compose stop worker-1" >/dev/null 2>&1
  play_fails worker-stopped "$here/converge.yml" -e n8n_workers=1
  expect_in_log worker-stopped "the services worker-1 are not running"
  expect_unchanged worker-stopped
  [ -z "$(hx sh -c "cd $dir && docker compose ps --quiet worker-1")" ] || fail "the run started the worker"
  hx sh -c "cd $dir && docker compose start worker-1" >/dev/null 2>&1

  echo "== a second worker must be a reconfigure"
  converge -v -e n8n_workers=2
  expect_no_secrets converge
  grep -q "reconfigure.yml" "$out/converge.log" || fail "the second worker was not a reconfigure"
  expect_idempotent -e n8n_workers=2
  expect_services db n8n redis worker-1 worker-2
  expect_redis_without_mounts
  wait_healthy
  play "$here/verify.yml" -e n8n_workers=2
  expect_workflow_active
  expect_ran_on_worker worker-1 worker-2

  echo "== back to normal mode: no Valkey, no workers, the workflow still active"
  converge -v -e n8n_workers=0
  expect_no_secrets converge
  grep -q "reconfigure.yml" "$out/converge.log" || fail "normal mode was not a reconfigure"
  expect_idempotent -e n8n_workers=0
  expect_services db n8n
  wait_healthy
  expect_workflow_active
  play "$here/verify.yml" -e n8n_workers=0

  echo "== queue mode again: the workflow still active, its execution on the worker"
  converge -v -e n8n_workers=1
  expect_no_secrets converge
  grep -q "reconfigure.yml" "$out/converge.log" || fail "queue mode was not a reconfigure"
  expect_idempotent -e n8n_workers=1
  expect_services db n8n redis worker-1
  wait_healthy
  expect_workflow_active
  expect_ran_on_worker worker-1
}

# All scenarios by default; NOIXDEV_INFRA_N8N_TESTS="refusals router" runs
# only these (router installs a host when install did not run before).
for scenario in ${NOIXDEV_INFRA_N8N_TESTS:-refusals install router queue}; do
  case "$scenario" in
    refusals | install | router | queue) "test_$scenario" ;;
    *) fail "unknown scenario $scenario (refusals, install, router, queue)" ;;
  esac
done

echo "== all n8n tests passed"
