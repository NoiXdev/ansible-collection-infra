#!/usr/bin/env bash
# End-to-end test of the tandoor role on throwaway Docker-in-Docker hosts
# (a fresh one per scenario), with the traefik role in front and Mailpit as
# the SMTP catcher:
#   settings  invalid settings refused before any change (missing secrets,
#             role-owned keys in tandoor_env, a bad e-mail setting, a version
#             that is not 2.X.Y, PostgreSQL older than 18, no admin on
#             install); nothing under /opt/tandoor afterwards
#   install   a failed install (a web image that exits at once) that stops
#             the stack and that every later run refuses until it is removed
#             as its message says; then a fresh install (verify.yml: login
#             through Traefik with CSRF, an API token, the admin's space and a
#             recipe, no open registration, an invite that lets a new user
#             sign up, a password reset mail from the configured sender, a $
#             reaching the container verbatim, no published port), and a run
#             without changes that fails on a stopped container
#   router    the pages and the API on their own routers: with a middleware
#             that denies everything on the pages, / is denied by Traefik
#             while /api/, /_allauth/ and /media/ still reach Tandoor (its own
#             JSON 403 without credentials, 200 with an app session); with it
#             on the API router only, the reverse
# The failed install runs at -v, the install and a reconfigure at -vvv, every
# repeated converge at -v; their output must not hold a test secret. Every
# successful converge is repeated and must change nothing.
# NOIXDEV_INFRA_TANDOOR_TESTS selects scenarios (see the end of the file);
# NOIXDEV_INFRA_TANDOOR_TEST_HOST and NOIXDEV_INFRA_TANDOOR_TEST_OUT (the
# directory of the logs and image tarballs) let two runs go side by side.
# The single-quoted scripts expand inside the container, not here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
host="${NOIXDEV_INFRA_TANDOOR_TEST_HOST:-noixdev-infra-tandoor-test}"
out="${NOIXDEV_INFRA_TANDOOR_TEST_OUT:-$tests/output/tandoor}"
dir=/opt/tandoor
defaults="$root/roles/tandoor/defaults/main.yml"
traefik_defaults="$root/roles/traefik/defaults/main.yml"

# The value of a top-level key in a YAML file: value_of <file> <key>.
value_of() { sed -n "s/^$2: *//p" "$1" 2>/dev/null || true; }
version="$(value_of "$defaults" tandoor_version)"
images=(
  "$(value_of "$defaults" tandoor_image):$version"
  "$(value_of "$defaults" tandoor_postgres_image)"
  "$(value_of "$traefik_defaults" traefik_image)"
  "$(value_of "$traefik_defaults" traefik_socket_proxy_image)"
  "$(sed -n 's/^ *converge_mailpit_image: *//p' "$here/converge.yml")"
)
admin_password="$(value_of "$here/vars.yml" tandoor_admin_password)"
# The test secrets, which no run's output may hold.
secrets=(
  "$(value_of "$here/vars.yml" tandoor_secret_key)"
  "$(value_of "$here/vars.yml" tandoor_db_password)"
  "$admin_password"
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
# The tandoor role alone (no Traefik) that must fail: role_fails <name>
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
# test secret, as it is or up to its first quote or backslash (a quoted or
# escaped copy): expect_no_secrets <name>.
expect_no_secrets() {
  local log="$out/$1.log" secret part
  [ -s "$log" ] || fail "$1.log is missing or empty, so it cannot show that no secret is in it"
  for secret in "${secrets[@]}"; do
    [ "${#secret}" -ge 8 ] || fail "a test secret is shorter than 8 characters: check vars.yml"
    for part in "$secret" "${secret%%[\'\"\\\`]*}"; do
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
containers() { hx docker ps -aq --filter label=com.docker.compose.project=tandoor; }
# Waits until the web container is healthy again: Traefik routes to it only
# then.
wait_healthy() {
  for _ in $(seq 60); do
    [ "$(hx sh -c "cd $dir && docker compose ps --format '{{.Health}}' web")" = healthy ] && return 0
    sleep 3
  done
  fail "the web container did not become healthy: $(hx sh -c "cd $dir && docker compose ps --all")"
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
# Loads the role's, Traefik's and Mailpit's images into the host.
load_images() {
  local image
  for image in "${images[@]}"; do
    case "$image" in
      "" | :* | *:) fail "an image is missing in $defaults, $traefik_defaults or converge.yml" ;;
    esac
  done
  load_set "${images[@]}"
}
# A request through Traefik: prints the body, then the status on a line of
# its own. request <path> [curl options...].
request() {
  local path="$1"
  shift
  hx curl -s -H 'Host: tandoor.test' -w '\n%{http_code}' "$@" "http://127.0.0.1$path"
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
# Waits until Traefik denies the path (it reads new labels within seconds).
wait_denied() {
  for _ in $(seq 30); do
    [ "$(request "$1")" = $'Forbidden\n403' ] && return 0
    sleep 1
  done
  expect_denied "$1"
}
# An allauth app session of the admin, as Tandoor 2.x apps log in; prints its
# token. The password goes through stdin, not a command line.
app_token() {
  printf '%s' "$admin_password" | docker exec -i "$host" python3 -c '
import json, sys, urllib.request
body = json.dumps({"username": sys.argv[1], "password": sys.stdin.read()}).encode()
req = urllib.request.Request("http://127.0.0.1/_allauth/app/v1/auth/login", data=body,
                             headers={"Host": "tandoor.test", "Content-Type": "application/json"})
print(json.load(urllib.request.urlopen(req))["meta"]["session_token"])
' admin
}

# The scenarios, run by the loop at the end.
test_settings() {
  echo "== invalid settings must be refused before any change"
  new_host
  role_fails no-secret -e tandoor_secret_key=
  expect_in_log no-secret tandoor_secret_key
  role_fails short-secret -e tandoor_secret_key=too-short
  expect_in_log short-secret tandoor_secret_key
  role_fails no-db-password -e tandoor_db_password=
  expect_in_log no-db-password tandoor_db_password
  role_fails no-hostname -e tandoor_hostname=
  expect_in_log no-hostname tandoor_hostname
  role_fails owned-env -e '{"tandoor_env": {"ENABLE_SIGNUP": "1"}}'
  expect_in_log owned-env tandoor_env
  expect_in_log owned-env ENABLE_SIGNUP
  role_fails owned-env-db -e '{"tandoor_env": {"DATABASE_URL": "sqlite:///x"}}'
  expect_in_log owned-env-db DATABASE_URL
  role_fails owned-env-prefix -e '{"tandoor_env": {"EMAIL_HOST": "x"}}'
  expect_in_log owned-env-prefix EMAIL_HOST
  role_fails env-key -e '{"tandoor_env": {"lower": "x"}}'
  expect_in_log env-key tandoor_env
  role_fails tls-ssl -e '{"tandoor_email": {"host": "mailpit", "from": "a@example.test", "tls": true, "ssl": true}}'
  expect_in_log tls-ssl tandoor_email
  expect_in_log tls-ssl "tls and ssl"
  role_fails no-from -e '{"tandoor_email": {"host": "mailpit"}}'
  expect_in_log no-from tandoor_email
  expect_in_log no-from from
  role_fails v1 -e tandoor_version=1.5.0
  expect_in_log v1 tandoor_version
  role_fails v-prefix -e tandoor_version=v2.7.2
  expect_in_log v-prefix tandoor_version
  # Before 18 the image's volume is /var/lib/postgresql/data, which would put
  # the database on an anonymous volume beside tandoor_data_dir.
  role_fails postgres-17 -e tandoor_postgres_image=docker.io/library/postgres:17
  expect_in_log postgres-17 "PostgreSQL 18 or newer"
  expect_in_log postgres-17 "docker.io/library/postgres:17 is PostgreSQL 17"
  expect_unchanged postgres-17
  role_fails no-admin -e tandoor_admin_user= -e tandoor_admin_password= -e tandoor_admin_email=
  expect_in_log no-admin tandoor_admin_user
  expect_in_log no-admin tandoor_admin_email
  hx test ! -e "$dir" || fail "tandoor touched the host before refusing its settings: $(hx find "$dir" | head)"
}

test_install() {
  echo "== a failed install must stop the stack and be refused until it is removed"
  new_host
  load_images
  load_set busybox:1.37
  # A web image that exits at once: the database runs, Tandoor never becomes
  # healthy.
  hx docker tag busybox:1.37 "test.invalid/recipes:$version"
  play_fails install-failed "$here/converge.yml" -v -e tandoor_image=test.invalid/recipes -e tandoor_health_timeout=20
  expect_in_log install-failed "The install of Tandoor $version in $dir failed (Fail when Tandoor is not healthy:"
  expect_in_log install-failed "check that nothing in it is worth keeping"
  expect_in_log install-failed "docker compose down in $dir"
  expect_in_log install-failed "remove $dir/compose.yaml, $dir/install-incomplete"
  expect_in_log install-failed "the subdirectories postgres and mediafiles of $dir/data"
  expect_no_secrets install-failed
  hx test -e "$dir/install-incomplete" || fail "the failed install left no marker"
  [ -z "$(hx docker ps -q --filter label=com.docker.compose.project=tandoor)" ] \
    || fail "the failed install left containers running: $(hx docker ps --format '{{.Names}}' --filter label=com.docker.compose.project=tandoor)"
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  containers_before="$(containers)"
  play_fails install-incomplete "$here/converge.yml"
  expect_in_log install-incomplete "$dir/install-incomplete exists"
  expect_in_log install-incomplete "docker compose down in $dir"
  expect_unchanged install-incomplete
  [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused run changed the compose file"
  [ "$(containers)" = "$containers_before" ] || fail "the refused run created or removed containers"
  # As the message says; the install then starts afresh.
  hx sh -c "cd $dir && docker compose down" >/dev/null 2>&1
  hx rm -rf "$dir"

  echo "== install"
  converge -vvv
  expect_no_secrets converge
  hx test ! -e "$dir/install-incomplete" || fail "the install kept its marker"
  expect_idempotent
  play "$here/verify.yml"

  echo "== a run without changes must fail on a stopped container and start nothing"
  hx sh -c "cd $dir && docker compose stop web" >/dev/null 2>&1
  play_fails stopped "$here/converge.yml"
  expect_in_log stopped "web"
  expect_in_log stopped "not running"
  expect_unchanged stopped
  [ -z "$(hx sh -c "cd $dir && docker compose ps --quiet web")" ] || fail "the run started web"
  hx sh -c "cd $dir && docker compose start web" >/dev/null 2>&1
  wait_healthy
}

test_router() {
  if ! hx test -e "$dir/compose.yaml" 2>/dev/null; then
    echo "== install for the router tests"
    new_host
    load_images
    converge
  fi
  wait_healthy
  # One login; Tandoor allows three a minute per client address.
  token="$(app_token)" || fail "the app login through /_allauth/ failed"
  [ -n "$token" ] || fail "the app login gave no session token"
  hx sh -c "echo noix-media >$dir/data/mediafiles/noix-test.txt"

  echo "== a middleware on the pages must leave the API, allauth and the media to Tandoor"
  converge -vvv -e '{"tandoor_traefik_middlewares": ["deny@file"]}'
  expect_no_secrets converge
  grep -q "reconfigure.yml" "$out/converge.log" || fail "the changed middlewares were not a reconfigure"
  expect_idempotent -e '{"tandoor_traefik_middlewares": ["deny@file"]}'
  wait_denied /
  expect_denied /account/login/
  # Tandoor's own 403 for the API without credentials, not Traefik's.
  expect_answer 403 '"detail"' /api/recipe/
  expect_answer 200 '"results"' /api/recipe/ -H "X-Session-Token: $token"
  expect_answer 401 '"status": 401' /_allauth/browser/v1/auth/session
  expect_answer 200 noix-media /media/noix-test.txt

  echo "== a middleware on the API router must leave the pages alone"
  converge -e '{"tandoor_traefik_api_middlewares": ["deny@file"]}'
  wait_denied /api/recipe/
  expect_denied /api/recipe/ -H "X-Session-Token: $token"
  expect_denied /_allauth/browser/v1/auth/session
  expect_denied /media/noix-test.txt
  expect_answer 200 '<title>Tandoor</title>' /account/login/

  echo "== without middlewares everything must reach Tandoor again"
  converge
  for _ in $(seq 30); do
    [ "$(request /api/recipe/ -o /dev/null -H "X-Session-Token: $token")" = $'\n200' ] && break
    sleep 1
  done
  expect_answer 200 '"results"' /api/recipe/ -H "X-Session-Token: $token"
  expect_answer 200 '<title>Tandoor</title>' /account/login/
  expect_idempotent
}

# All scenarios by default; NOIXDEV_INFRA_TANDOOR_TESTS="settings router"
# runs only these (router installs a host when install did not run before).
for scenario in ${NOIXDEV_INFRA_TANDOOR_TESTS:-settings install router}; do
  case "$scenario" in
    settings | install | router) "test_$scenario" ;;
    *) fail "unknown scenario $scenario (settings, install, router)" ;;
  esac
done

echo "== all tandoor tests passed"
