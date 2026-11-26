#!/usr/bin/env bash
# End-to-end test of the tandoor role on throwaway Docker-in-Docker hosts
# (a fresh one per scenario), with the traefik role in front and Mailpit as
# the SMTP catcher:
#   settings  invalid settings refused before any change (missing secrets,
#             role-owned keys in tandoor_env, a key without a value in it, a
#             bad e-mail setting, a version that is not 2.X.Y, PostgreSQL
#             older than 18, no admin on install); nothing under /opt/tandoor
#             afterwards
#   install   a failed install (a web image that exits at once) that stops
#             the stack and that every later run refuses until it is removed
#             as its message says; then a fresh install (verify.yml: login
#             through Traefik with CSRF, an API token, the admin's space and a
#             recipe, no open registration, an invite that lets a new user
#             sign up, a password reset mail from the configured sender, a $
#             reaching the container verbatim, no published port), a run with
#             tandoor_s3 on this local installation that is refused, and a run
#             without changes that fails on a stopped container
#   router    the pages and the API on their own routers: with a middleware
#             that denies everything on the pages, / is denied by Traefik
#             while /api/, /_allauth/ and /media/ still reach Tandoor (its own
#             JSON 403 without credentials, 200 with an app session); with it
#             on the API router only, the reverse
#   s3        media in S3 (RustFS as s3.test, a bucket made with the AWS CLI,
#             s3.yml): an image uploaded through the API is an object in the
#             bucket and not on the host, its signed URL downloads it, the
#             secret key is in a 0600 file and in neither the compose file nor
#             docker inspect, /media/ is not on the API router; a new secret
#             key recreates web and leaves the database running, a web
#             container left with the old key (a failed docker compose up) is
#             recreated on the next run, and so is one whose secret file was
#             changed by hand; a run without tandoor_s3 is refused
#   update    an update from an older release with a recipe and its image: a
#             new tandoor_db_password with it refused before any change; a
#             backup (a dump read back in full, a hard-link copy of the
#             media) taken and the oldest pruned, the recipe and the image
#             unchanged, verify.yml on the new release; a downgrade, another
#             PostgreSQL major and a second cluster refused before any change
#   failed_update
#             an update to an image that exits at once, with local media and
#             with media in S3: rolled back with the recipe and its image, the
#             marker that names the failed version and blocks it, and a run
#             with another version that removes the marker; then a rollback
#             that fails too (the previous image cannot be started), whose
#             marker refuses every version, an older one before the downgrade
#             refusal
#   refusals  on an installation, a changed tandoor_db_password refused
#             before any change, with Tandoor still healthy;
#             a compose file that is not YAML refused without a line of it in
#             the output; then the new password taken once the database
#             has it (ALTER USER, as the refusal says)
#   missing_data
#             left-over data without a compose file refused; an installation
#             whose data directories are gone (an unmounted volume) refused in
#             every state (no change, an update, a reconfigure, a failed-update
#             marker) without creating anything or starting a container, and,
#             with media in S3 (in the s3 scenario), without expecting a media
#             subdirectory
#   mountpoint
#             tandoor_data_dir_mountpoint on a plain directory refused,
#             nothing created; an install onto a tmpfs
#   db_check  an update to a test image that starts healthy with a migration
#             its boot script does not apply: the database check fails and
#             the update is rolled back with update-failed naming it; a run
#             without changes while the database does not answer (its
#             postmaster stopped, the container still healthy) fails with the
#             database check within the health timeout
#   interrupted
#             converges killed (SIGKILL to their process group) at a point of
#             an update: tandoor_restore_interrupted without an interrupted
#             update refused; a marker that is not YAML, lacks its keys or
#             cannot be read (a directory) refused, its copies kept; a marker
#             beside update-failed of the same backup removed, update-failed
#             deciding (with tandoor_restore_interrupted its refusal says the
#             variable does not apply), but kept by a run that another
#             refusal stops; killed once the compose file names the new
#             release: the marker (step update, both versions, the backup,
#             mode 0600) refuses every run, beside update-failed of another
#             update too, a copy of the compose file that cannot be read
#             fails the restore with a message of its own, and
#             tandoor_restore_interrupted restores the previous release after
#             a restore stopped while it put the media back, removing that
#             update-failed; killed during the rollback of a failed update:
#             refused and restored the same way; a copy that cannot be written
#             fails the update before the backup with a message of its own;
#             killed during the backup: the next run cleans up and updates,
#             removing the marker before its copies
#   interrupted_s3
#             with media in S3, an update that rotates the S3 secret key killed
#             once the compose file names the new release: the copy of the
#             secret file (mode 0600) beside the marker, the refusal, a restore
#             without that copy refused, and the restore that puts the
#             previous key back into the web container;
#             then a restore that fails (the previous image cannot be started):
#             update-failed records a failed rollback and refuses every
#             version, and the marker and its copies are gone
# The failed install and the update run at -v, the install, a reconfigure,
# the failed update and the interrupted ones with their refusals and restores
# at -vvv, every repeated converge at -v; their output must not hold a test
# secret. Every successful converge is repeated and must change nothing.
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
# RustFS and the AWS CLI, for the s3 scenario only.
s3_images=(
  "$(value_of "$here/s3.yml" s3_rustfs_image)"
  "$(value_of "$here/s3.yml" s3_aws_cli_image)"
)
s3_secret="$(value_of "$here/s3.yml" s3_secret_key)"
s3_rotated_secret="$(value_of "$here/s3.yml" s3_rotated_secret_key)"
admin_password="$(value_of "$here/vars.yml" tandoor_admin_password)"
# The database password the refusals scenario rotates to; a $ that compose and
# a shell must not expand.
rotated_db_password='test-db-ro$tated-pass-0'
# A web image that exits at once, tagged as a Tandoor release of a test image.
busybox=busybox:1.37.0
# The update tests: the older release they install first.
old_version=2.6.15
old_images=("$(value_of "$defaults" tandoor_image):$old_version" "$busybox")
backups="$dir/data/backups"
marker="$dir/update-failed"
# The marker of an update in progress and its copies of the compose file and,
# with S3, the secret file.
progress="$dir/update-in-progress"
progress_compose="$dir/update-in-progress.compose.yaml"
progress_s3_secret="$dir/update-in-progress.s3-secret"
# The test secrets, which no run's output may hold.
secrets=(
  "$(value_of "$here/vars.yml" tandoor_secret_key)"
  "$(value_of "$here/vars.yml" tandoor_db_password)"
  "$admin_password"
  "$s3_secret"
  "$s3_rotated_secret"
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
  noix_cache_run=() && noix_cache_array noix_cache_run noix_cache_run_args
  noix_cache_dind=() && noix_cache_array noix_cache_dind noix_cache_dind_args
  docker run -d --privileged --name "$host" ${noix_cache_run[@]+"${noix_cache_run[@]}"} docker:29-dind ${noix_cache_dind[@]+"${noix_cache_dind[@]}"} >/dev/null
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
# Fails unless the web container reads the S3 secret key from its file
# (without printing it): expect_container_secret <key> <what>.
expect_container_secret() {
  [ "$(hx sh -c "cd $dir && docker compose exec -T web cat /run/secrets/s3-secret")" = "$1" ] \
    || fail "the web container does not see $2 in /run/secrets/s3-secret"
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
  { [ "${answer##*$'\n'}" = "$status" ] && [[ "${answer%$'\n'*}" == *"$text"* ]]; } \
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
# recipe.py on the test host: recipe <command> [args...]; see recipe.py. The
# admin password of the token command goes through stdin.
recipe() {
  hx test -e /tmp/recipe.py || docker exec -i "$host" sh -c 'cat >/tmp/recipe.py' <"$here/recipe.py"
  docker exec -i "$host" python3 /tmp/recipe.py "$@"
}
# Logs the admin in (once per installation: Tandoor allows three logins a
# minute) and creates a recipe with an image; sets token, recipe_id and
# image_sum (the image as Tandoor serves it).
add_recipe() {
  wait_healthy
  token="$(printf '%s' "$admin_password" | recipe token admin)" || fail "the login of the admin failed"
  recipe_id="$(recipe add "$token" </dev/null)" || fail "the recipe was not created"
  image_sum="$(recipe check "$token" "$recipe_id" </dev/null)" || fail "the new recipe or its image is missing"
}
# Fails unless the recipe of add_recipe is there with the same image:
# expect_recipe <when>.
expect_recipe() {
  local sum
  sum="$(recipe check "$token" "$recipe_id" </dev/null)" || fail "the recipe or its image is missing $1"
  [ "$sum" = "$image_sum" ] || fail "the image of the recipe changed $1"
}
# Sets the password of the database user tandoor, as the refusal of a
# changed tandoor_db_password says, over the local socket and through stdin:
# set_db_password <password>.
set_db_password() {
  local quote="'"
  printf "ALTER USER tandoor PASSWORD '%s';\n" "${1//$quote/$quote$quote}" \
    | docker exec -i "$host" sh -c "cd $dir && docker compose exec -T db psql -q -U tandoor -d postgres -v ON_ERROR_STOP=1" \
    || fail "cannot set the password of the database user"
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
# The id of the database container.
db_id() { hx sh -c "cd $dir && docker compose ps --quiet db"; }
# The image, state and health of the web container.
web() { hx sh -c "cd $dir && docker compose ps --all --format '{{.Image}} {{.State}} {{.Health}}' web"; }

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
  # A key left empty in YAML would reach Tandoor as the text None.
  role_fails env-null -e '{"tandoor_env": {"NOIX_EMPTY": null}}'
  expect_in_log env-null "tandoor_env has no value for NOIX_EMPTY"
  role_fails tls-ssl -e '{"tandoor_email": {"host": "mailpit", "from": "a@example.test", "tls": true, "ssl": true}}'
  expect_in_log tls-ssl tandoor_email
  expect_in_log tls-ssl "tls and ssl"
  role_fails no-from -e '{"tandoor_email": {"host": "mailpit"}}'
  expect_in_log no-from tandoor_email
  expect_in_log no-from from
  role_fails s3-no-bucket -e '{"tandoor_s3": {"access_key": "test-access", "secret_key": "test-secret"}}'
  expect_in_log s3-no-bucket tandoor_s3
  expect_in_log s3-no-bucket bucket
  role_fails s3-no-secret -e '{"tandoor_s3": {"access_key": "test-access", "bucket": "recipes"}}'
  expect_in_log s3-no-secret tandoor_s3
  expect_in_log s3-no-secret secret_key
  role_fails s3-no-access-key -e '{"tandoor_s3": {"bucket": "recipes", "region": "us-east-1"}}'
  expect_in_log s3-no-access-key "tandoor_s3 sets bucket, region without access_key"
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
  load_set "$busybox"
  # A web image that exits at once: the database runs, Tandoor never becomes
  # healthy.
  hx docker tag "$busybox" "test.invalid/recipes:$version"
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

  echo "== a run with tandoor_s3 on a local installation must be refused before any change"
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  play_fails to-s3 "$here/converge.yml" -e '{"tandoor_s3": {"access_key": "test-access", "secret_key": "test-secret", "bucket": "recipes"}}'
  expect_in_log to-s3 "records the media of Tandoor as local, but this run sets them to S3"
  expect_unchanged to-s3
  [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused run changed the compose file"
  hx test ! -e "$dir/s3-secret" || fail "the refused run wrote $dir/s3-secret"

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

test_s3() {
  echo "== media in S3"
  new_host
  load_images
  load_set "${s3_images[@]}"
  # Signed URLs name the endpoint; the test host reaches RustFS's published
  # port by the name Tandoor uses on the Traefik network.
  hx sh -c 'echo "127.0.0.1 s3.test" >>/etc/hosts'
  converge -vvv -e "@$here/s3.yml"
  expect_no_secrets converge
  expect_idempotent -e "@$here/s3.yml"
  hx test ! -e "$dir/data/mediafiles" || fail "an S3 installation has $dir/data/mediafiles"
  play "$here/verify.yml" -e "@$here/s3.yml"

  echo "== a new S3 secret key must recreate web and leave the database running"
  expect_container_secret "$s3_secret" "the secret key"
  web_before="$(hx sh -c "cd $dir && docker compose ps --quiet web")"
  db_before="$(db_id)"
  # The files of the installation with the first key, for the stale web
  # container below.
  hx cp -p "$dir/compose.yaml" /root/compose.yaml.first
  hx cp -p "$dir/s3-secret" /root/s3-secret.first
  # s3.yml's tandoor_s3 with the rotated key; RustFS keeps its own.
  converge -v -e "@$here/s3.yml" -e "s3_secret_key=$s3_rotated_secret"
  expect_no_secrets converge
  grep -q "reconfigure.yml" "$out/converge.log" || fail "the new secret key was not a reconfigure"
  [ "$(hx cat "$dir/s3-secret")" = "$s3_rotated_secret" ] || fail "$dir/s3-secret does not hold the new secret key"
  [ "$(hx sh -c "cd $dir && docker compose ps --quiet web")" != "$web_before" ] || fail "the new secret key did not recreate web"
  [ "$(db_id)" = "$db_before" ] || fail "the new secret key recreated the database"
  expect_container_secret "$s3_rotated_secret" "the new secret key"
  expect_idempotent -e "@$here/s3.yml" -e "s3_secret_key=$s3_rotated_secret"

  echo "== a web container left with the old key (a failed docker compose up) must be recreated on the next run"
  # The files with the rotated key, and web as a docker compose up that
  # failed after the role wrote them leaves it: with the first key.
  hx cp -p "$dir/compose.yaml" /root/compose.yaml.rotated
  hx cp -p "$dir/s3-secret" /root/s3-secret.rotated
  hx cp -p /root/compose.yaml.first "$dir/compose.yaml"
  hx cp -p /root/s3-secret.first "$dir/s3-secret"
  hx sh -c "cd $dir && docker compose up -d" >/dev/null 2>&1
  wait_healthy
  hx cp -p /root/compose.yaml.rotated "$dir/compose.yaml"
  hx cp -p /root/s3-secret.rotated "$dir/s3-secret"
  expect_container_secret "$s3_secret" "the first key in the stale container"
  db_before="$(db_id)"
  converge -v -e "@$here/s3.yml" -e "s3_secret_key=$s3_rotated_secret"
  expect_no_secrets converge
  grep -q "reconfigure.yml" "$out/converge.log" || fail "a web container with the old key was not a reconfigure"
  expect_container_secret "$s3_rotated_secret" "the new secret key after the retry"
  [ "$(db_id)" = "$db_before" ] || fail "the retry recreated the database"
  expect_idempotent -e "@$here/s3.yml" -e "s3_secret_key=$s3_rotated_secret"

  echo "== a secret file changed by hand must be put back and web recreated"
  # Rewritten in place, so the container sees it; the role's copy is a new file.
  hx sh -c "printf hand-edited >$dir/s3-secret"
  db_before="$(db_id)"
  converge -v -e "@$here/s3.yml" -e "s3_secret_key=$s3_rotated_secret"
  expect_no_secrets converge
  expect_container_secret "$s3_rotated_secret" "the new secret key after the hand edit"
  [ "$(db_id)" = "$db_before" ] || fail "putting the secret file back recreated the database"

  echo "== the first S3 secret key again"
  converge -v -e "@$here/s3.yml"
  expect_no_secrets converge
  expect_container_secret "$s3_secret" "the secret key again"
  expect_idempotent -e "@$here/s3.yml"

  echo "== a run without tandoor_s3 on an S3 installation must be refused before any change"
  compose_before="$(hx sha256sum "$dir/compose.yaml")"
  containers_before="$(containers)"
  play_fails from-s3 "$here/converge.yml" -v
  expect_in_log from-s3 "records the media of Tandoor as S3, but this run sets them to local"
  expect_unchanged from-s3
  expect_no_secrets from-s3
  [ "$(hx sha256sum "$dir/compose.yaml")" = "$compose_before" ] || fail "the refused run changed the compose file"
  [ "$(containers)" = "$containers_before" ] || fail "the refused run created or removed containers"
  hx test ! -e "$dir/data/mediafiles" || fail "the refused run created $dir/data/mediafiles"

  echo "== an S3 installation without its data directory must be refused, expecting no media subdirectory"
  hx sh -c "cd $dir && docker compose stop" >/dev/null 2>&1
  hx mv "$dir/data" "$dir/data.away"
  hx mkdir "$dir/data"
  note_untouched
  play_fails missing-data-s3 "$here/converge.yml" -v -e "@$here/s3.yml"
  expect_in_log missing-data-s3 "$dir/data lacks postgres: is the volume mounted?"
  expect_no_secrets missing-data-s3
  expect_untouched missing-data-s3
  # The recorded media decide, not this run's tandoor_s3: the missing data
  # come before the change from S3 to local media.
  play_fails missing-data-s3-local "$here/converge.yml"
  expect_in_log missing-data-s3-local "$dir/data lacks postgres: is the volume mounted?"
  expect_untouched missing-data-s3-local
  [ -z "$(hx ls -A "$dir/data")" ] || fail "a refused run created in $dir/data: $(hx ls -A "$dir/data")"
  hx rmdir "$dir/data"
  hx mv "$dir/data.away" "$dir/data"
  hx sh -c "cd $dir && docker compose start" >/dev/null 2>&1
  wait_healthy
  expect_idempotent -e "@$here/s3.yml"
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

test_update() {
  echo "== an update must take a dump and a copy of the media and prune the oldest backups"
  new_host
  load_images
  load_set "${old_images[@]}"
  converge -e "tandoor_version=$old_version"
  add_recipe
  # Older backups; with the new one there are four, and three are kept.
  hx mkdir -p "$backups/20200101T000000Z-2.6.0" "$backups/20200101T000001Z-2.6.0" "$backups/20200101T000002Z-2.6.0"
  # A new password with a new version: refused before the update, which would
  # fail on it and roll back.
  note_untouched
  play_fails update-db-password "$here/converge.yml" -v -e "tandoor_db_password=$rotated_db_password"
  expect_in_log update-db-password "tandoor_db_password differs from the password in $dir/compose.yaml, and the database does not take it"
  expect_no_secrets update-db-password
  expect_untouched update-db-password
  [ "$(web)" = "${old_images[0]} running healthy" ] || fail "web after the refused update: $(web)"
  hx test ! -e "$marker" || fail "the refused update wrote the marker"
  converge -v
  expect_no_secrets converge
  grep -q "update.yml" "$out/converge.log" || fail "the new version was not an update"
  [ "$(web)" = "${images[0]} running healthy" ] || fail "web after the update: $(web)"
  expect_no_progress "after the update"
  backup="$(hx sh -c "ls -d $backups/*-$old_version")"
  [ "$(printf '%s\n' "$backup" | wc -l | tr -d ' ')" = 1 ] || fail "not one backup of $old_version: $backup"
  [ "$(hx head -c 5 "$backup/tandoor.dump")" = PGDMP ] || fail "the backup $backup has no dump in pg_dump's custom format"
  # A hard-link copy: the image in the backup is the one in the media.
  hx sh -c "find $backup/mediafiles -name '*.png' -links +1 | grep -q ." \
    || fail "the backup $backup has no hard-linked image in mediafiles: $(hx find "$backup/mediafiles")"
  hx test ! -e "$backups/20200101T000000Z-2.6.0" || fail "the oldest backup was not pruned"
  [ "$(hx ls "$backups" | wc -l | tr -d ' ')" = 3 ] || fail "the backups are not the newest three: $(hx ls "$backups")"
  expect_recipe "after the update"
  expect_idempotent
  play "$here/verify.yml"

  echo "== a downgrade, another PostgreSQL major and a second cluster must be refused before any change"
  note_untouched
  play_fails downgrade "$here/converge.yml" -e "tandoor_version=$old_version"
  expect_in_log downgrade "tandoor_version $old_version is lower than the installed version $version"
  expect_untouched downgrade
  play_fails postgres-major "$here/converge.yml" -e tandoor_postgres_image=docker.io/library/postgres:19
  expect_in_log postgres-major "docker.io/library/postgres:19 is PostgreSQL 19, but the database"
  expect_in_log postgres-major "is PostgreSQL 18"
  expect_untouched postgres-major
  # An old cluster next to the current one, as a copy-mode pg_upgrade leaves it.
  hx sh -c "mkdir -p $dir/data/postgres/17/docker && echo 17 >$dir/data/postgres/17/docker/PG_VERSION"
  play_fails postgres-clusters "$here/converge.yml"
  expect_in_log postgres-clusters "more than one PostgreSQL cluster"
  expect_in_log postgres-clusters "$dir/data/postgres/17/docker/PG_VERSION (PostgreSQL 17)"
  expect_in_log postgres-clusters "$dir/data/postgres/18/docker/PG_VERSION (PostgreSQL 18)"
  expect_untouched postgres-clusters
  hx rm -r "$dir/data/postgres/17"
  [ "$(web)" = "${images[0]} running healthy" ] || fail "web after the refusals: $(web)"
}

# A failed update of the installation on the test host: to the new release of
# a test image that exits at once, which fails fast (30 seconds), while the
# rollback has the time a slow start of the previous release may need.
# failed_update <log> [converge options...].
failed_update() {
  local name="$1"
  shift
  hx docker tag "$busybox" "test.invalid/recipes:$version"
  play_fails "$name" "$here/converge.yml" "$@" -e tandoor_image=test.invalid/recipes -e tandoor_health_timeout=30 \
    -e tandoor_rollback_timeout=300
  expect_in_log "$name" "update from $old_version to $version in $dir failed, rolled back to $old_version"
  expect_no_secrets "$name"
  [ "$(web)" = "${old_images[0]} running healthy" ] || fail "web after the rollback: $(web)"
  hx grep -qx "failed_version: $version" "$marker" || fail "the marker does not name $version: $(hx cat "$marker")"
  hx grep -qx "rolled_back_to: $old_version" "$marker" || fail "the marker does not name $old_version: $(hx cat "$marker")"
  backup="$(hx sed -n 's/^backup: //p' "$marker")"
  [ "$(hx head -c 5 "$backup/tandoor.dump")" = PGDMP ] || fail "the marker's backup $backup has no dump"
  expect_no_progress "after the rollback"
}
# Fails when the marker of an update in progress or a copy of it is left:
# expect_no_progress <when>.
expect_no_progress() {
  local file
  for file in "$progress" "$progress_compose" "$progress_s3_secret"; do
    hx test ! -e "$file" || fail "$file is left $1"
  done
}

test_failed_update() {
  echo "== a failed update must roll back and block the failed version"
  new_host
  load_images
  load_set "${old_images[@]}"
  converge -e "tandoor_version=$old_version"
  add_recipe
  failed_update update-failed -vvv
  expect_recipe "after the rollback"
  hx test -d "$backup-failed/mediafiles" || fail "the media of the failed update were not moved to $backup-failed"
  expect_in_log update-failed "the media of the failed attempt are in $backup-failed. It does not try $version again"

  echo "== a run with the failed version must change nothing"
  note_untouched
  play_fails update-blocked "$here/converge.yml"
  expect_in_log update-blocked "$marker exists: the Tandoor update to $version failed"
  expect_in_log update-blocked "rolled back to $old_version"
  expect_untouched update-blocked

  echo "== a run with another version must remove the marker"
  converge -e "tandoor_version=$old_version"
  hx test ! -e "$marker" || fail "a successful run with $old_version kept the marker"
  expect_idempotent -e "tandoor_version=$old_version"

  echo "== a failed rollback must refuse every version until Tandoor is restored by hand"
  # The installed release under a name that is then untagged: the rollback
  # cannot start it again (no such registry), after the database was
  # recreated and loaded.
  hx docker tag "${old_images[0]}" "test.invalid/recipes:$old_version"
  converge -e "tandoor_version=$old_version" -e tandoor_image=test.invalid/recipes
  hx docker rmi "test.invalid/recipes:$old_version" >/dev/null
  play_fails rollback-failed "$here/converge.yml" -v -e tandoor_image=test.invalid/recipes -e tandoor_health_timeout=30
  expect_in_log rollback-failed "update from $old_version to $version in $dir failed"
  expect_in_log rollback-failed "and rolling back to $old_version failed too"
  expect_in_log rollback-failed "Roll back by hand in $dir"
  expect_no_secrets rollback-failed
  hx grep -qx "failed_version: $version" "$marker" || fail "the marker does not name $version: $(hx cat "$marker")"
  hx grep -qx "rolled_back_to: null" "$marker" || fail "the marker records a rollback: $(hx cat "$marker")"
  backup="$(hx sed -n 's/^backup: //p' "$marker")"
  note_untouched
  # A newer release than the failed one: it would back up the database the
  # failed rollback left and remove the marker.
  play_fails rollback-blocked "$here/converge.yml" -e tandoor_version=2.99.0
  expect_in_log rollback-blocked "$marker exists: the Tandoor update to $version failed"
  expect_in_log rollback-blocked "rolling back failed too"
  expect_in_log rollback-blocked "the data is in the backup $backup"
  expect_in_log rollback-blocked "The role refuses every version"
  if grep -qF -- "set tandoor_version to another version" "$out/rollback-blocked.log"; then
    fail "the refusal after a failed rollback suggests another version"
  fi
  expect_untouched rollback-blocked
  hx test -e "$marker" || fail "the refused run removed the marker"
  # An older release than the compose file names: the failed rollback comes
  # before the downgrade.
  play_fails rollback-blocked-older "$here/converge.yml" -e tandoor_version=2.6.0
  expect_in_log rollback-blocked-older "rolling back failed too"
  expect_in_log rollback-blocked-older "The role refuses every version"
  if grep -qF -- "is lower than the installed version" "$out/rollback-blocked-older.log"; then
    fail "the refusal after a failed rollback is the downgrade refusal"
  fi
  expect_untouched rollback-blocked-older
  hx test -e "$marker" || fail "the refused run removed the marker"

  echo "== a failed update with media in S3 must roll back the database and keep the images"
  new_host
  load_images
  load_set "${old_images[@]}"
  load_set "${s3_images[@]}"
  hx sh -c 'echo "127.0.0.1 s3.test" >>/etc/hosts'
  converge -e "@$here/s3.yml" -e "tandoor_version=$old_version"
  add_recipe
  failed_update update-failed-s3 -v -e "@$here/s3.yml"
  expect_recipe "after the rollback with media in S3"
  expect_in_log update-failed-s3 "the media in S3 stay as they are. It does not try $version again"
  note_untouched
  play_fails update-blocked-s3 "$here/converge.yml" -v -e "@$here/s3.yml"
  expect_in_log update-blocked-s3 "$marker exists: the Tandoor update to $version failed"
  expect_in_log update-blocked-s3 "rolled back to $old_version"
  expect_no_secrets update-blocked-s3
  expect_untouched update-blocked-s3
  hx test ! -e "$backup/mediafiles" || fail "the backup of an S3 installation has mediafiles"
  hx test ! -e "$backup-failed" || fail "the rollback of an S3 installation made $backup-failed"
  hx test ! -e "$dir/data/mediafiles" || fail "the rollback of an S3 installation made $dir/data/mediafiles"
}

test_refusals() {
  echo "== a changed database password must be refused before any change"
  new_host
  load_images
  converge
  wait_healthy
  note_untouched
  play_fails db-password "$here/converge.yml" -vvv -e "tandoor_db_password=$rotated_db_password"
  expect_in_log db-password "tandoor_db_password differs from the password in $dir/compose.yaml, and the database does not take it"
  expect_in_log db-password "ALTER USER"
  expect_no_secrets db-password
  expect_untouched db-password
  [ "$(web)" = "${images[0]} running healthy" ] || fail "web after the refused run: $(web)"

  echo "== a compose file that is not YAML must be refused without showing a line of it"
  hx cp -p "$dir/compose.yaml" /root/compose.yaml
  # The line of the database password, as a hand edit could break it.
  hx sed -i 's/^\( *POSTGRES_PASSWORD: .*\)$/\1 broken/' "$dir/compose.yaml"
  note_untouched
  play_fails compose-not-yaml "$here/converge.yml" -vvv
  expect_in_log compose-not-yaml "$dir/compose.yaml is not YAML"
  expect_no_secrets compose-not-yaml
  expect_untouched compose-not-yaml
  if grep -qF -- "broken" "$out/compose-not-yaml.log"; then
    fail "the refusal shows a line of the compose file: $(grep -nF -- broken "$out/compose-not-yaml.log" | head -n 3 | cut -c1-80)"
  fi
  hx cp -p /root/compose.yaml "$dir/compose.yaml"
  expect_idempotent

  echo "== a password changed in the database as the refusal says must be taken"
  set_db_password "$rotated_db_password"
  db_before="$(db_id)"
  converge -v -e "tandoor_db_password=$rotated_db_password"
  expect_no_secrets converge
  grep -q "reconfigure.yml" "$out/converge.log" || fail "the new password was not a reconfigure"
  [ "$(web)" = "${images[0]} running healthy" ] || fail "web after the new password: $(web)"
  [ "$(db_id)" != "$db_before" ] || fail "the database container still has the old password in its environment"
  # Tandoor's health check does not need the database; a login does. Once
  # Traefik routes to the new container (Tandoor's own 403).
  for _ in $(seq 30); do
    [ "$(request /api/recipe/ -o /dev/null)" = $'\n403' ] && break
    sleep 1
  done
  token="$(app_token)" || fail "the app login failed after the new password"
  expect_answer 200 '"results"' /api/recipe/ -H "X-Session-Token: $token"
  expect_idempotent -e "tandoor_db_password=$rotated_db_password"
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
  load_set "${old_images[@]}"
  converge -e "tandoor_version=$old_version"
  hx sh -c "cd $dir && docker compose stop" >/dev/null 2>&1
  # As an unmounted volume leaves it: its mountpoint, empty.
  hx mv "$dir/data" "$dir/data.away"
  hx mkdir "$dir/data"
  if hx sh -c "cd $dir && docker compose start" >"$out/start-missing.log" 2>&1; then
    fail "docker compose start succeeded without the data directories"
  fi
  [ -z "$(hx sh -c "cd $dir && docker compose ps --quiet")" ] || fail "a container runs without the data directories"
  note_untouched
  # missing_refused <name> [extra vars...]
  missing_refused() {
    local name="$1"
    shift
    play_fails "$name" "$here/converge.yml" "$@"
    expect_in_log "$name" "$dir/data lacks postgres, mediafiles"
    expect_in_log "$name" "is the volume mounted?"
    expect_untouched "$name"
    [ -z "$(hx ls -A "$dir/data")" ] || fail "the refused run $name created in $dir/data: $(hx ls -A "$dir/data")"
    [ -z "$(hx sh -c "cd $dir && docker compose ps --quiet")" ] || fail "the refused run $name started a container"
  }
  # A run without changes, a reconfigure (another environment variable), an
  # update (the newer version) and a run after a failed update (its marker).
  missing_refused missing-data -e "tandoor_version=$old_version"
  missing_refused missing-data-reconfigure -e "tandoor_version=$old_version" -e '{"tandoor_env": {"TEST_SETTING": "1"}}'
  missing_refused missing-data-update
  printf 'failed_version: %s\nrolled_back_to: %s\nbackup: /nonexistent\n' "$version" "$old_version" \
    | hx sh -c "cat >$marker"
  missing_refused missing-data-marker
  hx rm "$marker"

  echo "== with the data back the installation must run as before"
  hx rmdir "$dir/data"
  hx mv "$dir/data.away" "$dir/data"
  hx sh -c "cd $dir && docker compose start" >/dev/null 2>&1
  wait_healthy
  expect_idempotent -e "tandoor_version=$old_version"
}

test_mountpoint() {
  echo "== tandoor_data_dir_mountpoint must refuse a data directory that is not a mountpoint"
  new_host
  mountpoint_vars=(-e '{"tandoor_data_dir_mountpoint": true}')
  role_fails not-mountpoint "${mountpoint_vars[@]}"
  expect_in_log not-mountpoint "$dir/data is not a mountpoint"
  expect_in_log not-mountpoint "is the volume mounted?"
  hx test ! -e "$dir" || fail "the refused run created $dir"
  hx mkdir -p "$dir/data"
  role_fails not-mountpoint-dir "${mountpoint_vars[@]}"
  expect_in_log not-mountpoint-dir "$dir/data is not a mountpoint"
  [ -z "$(hx ls -A "$dir/data")" ] || fail "the refused run created in $dir/data: $(hx ls -A "$dir/data")"
  [ "$(hx ls -A "$dir")" = data ] || fail "the refused run created in $dir: $(hx ls -A "$dir")"

  echo "== install onto a mountpoint"
  hx mount -t tmpfs tmpfs "$dir/data"
  load_images
  converge "${mountpoint_vars[@]}"
  hx mountpoint -q "$dir/data" || fail "$dir/data is no longer a mountpoint"
  hx sh -c "find $dir/data/postgres -name PG_VERSION | grep -q ." || fail "the database is not on the mountpoint"
  hx test -d "$dir/data/mediafiles" || fail "the media are not on the mountpoint"
  expect_idempotent "${mountpoint_vars[@]}"
}

# The new release as test.invalid/recipes with a migration that its boot
# script does not apply: copied into place after the boot's migrate, so
# Tandoor starts and its container turns healthy while the database lacks
# the migration, as a migration that failed unnoticed leaves it.
build_unmigrated() {
  if ! docker exec -i "$host" docker build -q --build-arg "base=${images[0]}" -t "test.invalid/recipes:$version" - >/dev/null <<'EOF'; then
ARG base
FROM $base
RUN set -eu; \
    leaf="$(ls cookbook/migrations | sed -n 's/^\([0-9][0-9]*_.*\)\.py$/\1/p' | sort | tail -n 1)"; \
    printf 'from django.db import migrations\n\n\nclass Migration(migrations.Migration):\n    dependencies = [("cookbook", "%s")]\n    operations = []\n' "$leaf" >/opt/test-unapplied.py; \
    grep -qx 'python manage.py migrate' boot.sh; \
    sed -i 's|^python manage.py migrate$|&\ncp /opt/test-unapplied.py cookbook/migrations/9999_test_unapplied.py|' boot.sh; \
    grep -qx 'cp /opt/test-unapplied.py cookbook/migrations/9999_test_unapplied.py' boot.sh
EOF
    fail "cannot build the test image with a migration that is not applied"
  fi
}

test_db_check() {
  echo "== an update that leaves the database unusable for Tandoor must be rolled back"
  new_host
  load_images
  load_set "${old_images[@]}"
  converge -e "tandoor_version=$old_version"
  add_recipe
  build_unmigrated
  play_fails db-check "$here/converge.yml" -v -e tandoor_image=test.invalid/recipes -e tandoor_rollback_timeout=300
  expect_in_log db-check "update from $old_version to $version in $dir failed, rolled back to $old_version"
  expect_in_log db-check "database check failed: manage.py migrate --check found a migration that is not applied"
  expect_no_secrets db-check
  [ "$(web)" = "${old_images[0]} running healthy" ] || fail "web after the rollback: $(web)"
  hx grep -qx "failed_version: $version" "$marker" || fail "the marker does not name $version: $(hx cat "$marker")"
  hx grep -qx "rolled_back_to: $old_version" "$marker" || fail "the marker does not name $old_version: $(hx cat "$marker")"
  expect_no_progress "after the rollback"
  expect_recipe "after the rollback of an update with a migration that is not applied"

  echo "== a run without changes must fail within the health timeout while the database does not answer"
  # A successful run with another version removes the marker.
  converge -e "tandoor_version=$old_version"
  expect_idempotent -e "tandoor_version=$old_version"
  # The postmaster stopped from the test host, as a database that hangs: the
  # container runs and stays healthy for a minute (until its check has timed
  # out six times), while no new connection gets an answer. It is stopped
  # once the run reaches the health check, not before the run: a run that
  # takes longer than that minute to get there would find the container
  # unhealthy and never start the database check this case is about.
  db_pid="$(hx docker inspect --format '{{.State.Pid}}' "$(db_id)")"
  rm -f "$out/noop-db-down.log"
  (
    for _ in $(seq 1800); do
      if grep -qF 'TASK [noixdev.infra.tandoor : Note when the health check starts]' "$out/noop-db-down.log" 2>/dev/null; then
        hx kill -STOP "$db_pid"
        exit 0
      fi
      sleep 0.1
    done
    exit 1
  ) &
  stopper=$!
  play_fails_within 180 noop-db-down "$here/converge.yml" -v -e "tandoor_version=$old_version" -e tandoor_health_timeout=30
  # A run that ended without reaching the health check leaves the stopper
  # waiting: it stops nothing any more.
  stopped=0
  kill "$stopper" 2>/dev/null || true
  wait "$stopper" || stopped=$?
  hx kill -CONT "$db_pid"
  [ "$stopped" = 0 ] || fail "noop-db-down did not reach the health check: $(tail -n 5 "$out/noop-db-down.log")"
  expect_in_log noop-db-down "Tandoor in $dir is unhealthy"
  # The message says what bounds the check: the health timeout, and at least
  # 10 seconds for each database check.
  expect_in_log noop-db-down "within 30 seconds, at least 10 for each database check"
  expect_in_log noop-db-down "database check failed: manage.py migrate --check did not finish within"
  expect_no_secrets noop-db-down
  expect_unchanged noop-db-down
  # The bound the check had: the rest of tandoor_health_timeout.
  seconds="$(sed -n 's/.*migrate --check did not finish within \([0-9]*\) seconds.*/\1/p' "$out/noop-db-down.log" | head -n 1)"
  { [ -n "$seconds" ] && [ "$seconds" -le 30 ]; } || fail "the database check was not bounded by tandoor_health_timeout=30: ${seconds:-no time} seconds"
  expect_idempotent -e "tandoor_version=$old_version"
}

# Fails unless the refusal <name> of an interrupted update from $old_version
# to $version names the backup <backup> and both ways out.
expect_interrupted_refusal() {
  expect_in_log "$1" "$progress exists: the Tandoor update from $old_version to $version did not finish"
  expect_in_log "$1" "the backup from before it is $2"
  expect_in_log "$1" "set tandoor_restore_interrupted: true for one run to restore it"
  expect_in_log "$1" "or remove $progress to keep Tandoor as it is now"
}
# The restore of an interrupted update with tandoor_restore_interrupted:
# $old_version healthy again with the recipe, the marker and its copy gone,
# the compose file back at $old_version. expect_restored <when> [converge
# options...].
expect_restored() {
  local name="$1"
  shift
  play "$here/converge.yml" -vvv -e tandoor_restore_interrupted=true "$@" >"$out/$name.log" 2>&1 \
    || { tail -n 60 "$out/$name.log" >&2; fail "the restore $name failed"; }
  set -- "$name"
  expect_no_secrets "$1"
  expect_in_log "$1" "Tandoor in $dir runs $old_version again"
  # The first change of an update to the running Tandoor.
  if grep -qF "Stop Tandoor for the update" "$out/$1.log"; then fail "the restore $1 tried the update again"; fi
  [ "$(web)" = "${old_images[0]} running healthy" ] || fail "web after the restore $1: $(web)"
  expect_recipe "after the restore $1"
  expect_no_progress "after the restore $1"
  hx grep -qF "recipes:$old_version" "$dir/compose.yaml" || fail "the compose file does not name $old_version after the restore $1"
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
  echo "== tandoor_restore_interrupted without an interrupted update must be refused"
  new_host
  load_images
  load_set "${old_images[@]}"
  converge -e "tandoor_version=$old_version"
  add_recipe
  note_untouched
  play_fails restore-no-marker "$here/converge.yml" -e tandoor_restore_interrupted=true
  expect_in_log restore-no-marker "tandoor_restore_interrupted is set, but there is no interrupted update in $dir; remove the variable"
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
  # With tandoor_restore_interrupted, update-failed refuses first and says
  # that the variable does not apply.
  play_fails both-markers-restore "$here/converge.yml" -e tandoor_restore_interrupted=true
  expect_in_log both-markers-restore "$marker exists: the Tandoor update to $version failed"
  expect_in_log both-markers-restore "tandoor_restore_interrupted does not apply while $marker exists: no interrupted update is left to restore"
  expect_no_progress "beside update-failed"
  both_markers "$version"
  play_fails both-markers "$here/converge.yml"
  expect_in_log both-markers "$marker exists: the Tandoor update to $version failed"
  expect_in_log both-markers "rolled back to $old_version"
  if grep -qF "tandoor_restore_interrupted does not apply" "$out/both-markers.log"; then
    fail "the refusal both-markers names tandoor_restore_interrupted, which is not set"
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
  play_fails both-markers-refused "$here/converge.yml" -e "tandoor_version=$old_version" \
    -e tandoor_postgres_image=docker.io/library/postgres:19
  expect_in_log both-markers-refused "docker.io/library/postgres:19 is PostgreSQL 19, but the database"
  expect_untouched both-markers-refused
  [ "$(hx sha256sum "$marker" "$progress" "$progress_compose")" = "$markers_before" ] \
    || fail "the refused run both-markers-refused changed $marker, $progress or $progress_compose"
  converge -v -e "tandoor_version=$old_version"
  expect_no_progress "after a run beside update-failed of the same backup"
  hx test ! -e "$marker" || fail "the successful run kept $marker of another version"
  expect_idempotent -e "tandoor_version=$old_version"

  echo "== an update killed once its compose file names $version must be refused until it is restored"
  play_killed interrupted "grep -qF 'recipes:$version' $dir/compose.yaml" -vvv
  expect_no_secrets interrupted
  hx grep -qx "step: update" "$progress" || fail "the marker does not record the step update: $(hx cat "$progress")"
  hx grep -qx "from_version: $old_version" "$progress" || fail "the marker does not name $old_version: $(hx cat "$progress")"
  hx grep -qx "to_version: $version" "$progress" || fail "the marker does not name $version: $(hx cat "$progress")"
  backup="$(hx sed -n 's/^backup: //p' "$progress")"
  [ "$(hx head -c 5 "$backup/tandoor.dump")" = PGDMP ] || fail "the marker's backup $backup has no dump"
  for file in "$progress" "$progress_compose"; do
    [ "$(hx stat -c '%a %U' "$file")" = "600 root" ] || fail "$file is not root's with mode 0600: $(hx stat -c '%a %U' "$file")"
  done
  hx cmp -s "$progress_compose" "$backup/compose.yaml" || fail "$progress_compose is not the compose file from before the update"
  note_untouched
  play_fails interrupted-refused "$here/converge.yml" -vvv
  expect_interrupted_refusal interrupted-refused "$backup"
  expect_no_secrets interrupted-refused
  expect_untouched interrupted-refused

  echo "== beside update-failed of another update, the marker of an update in progress must still be refused"
  # As an earlier update to another version leaves it that was rolled back:
  # it stays through updates to other versions.
  hx sh -c "printf 'failed_version: 99.0.0\nrolled_back_to: $old_version\nbackup: $backups/20200101T000000Z-$old_version\ntime: 2020-01-01T00:00:00Z\n' >$marker"
  markers_before="$(hx sha256sum "$marker" "$progress" "$progress_compose")"
  play_fails other-update-failed "$here/converge.yml" -vvv
  expect_interrupted_refusal other-update-failed "$backup"
  expect_no_secrets other-update-failed
  expect_untouched other-update-failed
  [ "$(hx sha256sum "$marker" "$progress" "$progress_compose")" = "$markers_before" ] \
    || fail "the refused run other-update-failed changed $marker, $progress or $progress_compose"
  # One of another backup that refuses this version: with
  # tandoor_restore_interrupted, it comes first and says to deal with it,
  # then restore the interrupted update with the variable.
  hx sh -c "printf 'failed_version: $version\nrolled_back_to: $old_version\nbackup: $backups/20200101T000000Z-$old_version\ntime: 2020-01-01T00:00:00Z\n' >$marker"
  markers_before="$(hx sha256sum "$marker" "$progress" "$progress_compose")"
  play_fails other-update-failed-restore "$here/converge.yml" -e tandoor_restore_interrupted=true
  expect_in_log other-update-failed-restore "tandoor_restore_interrupted does not apply while $marker exists: deal with it first as said, then run the role again with the variable"
  expect_untouched other-update-failed-restore
  [ "$(hx sha256sum "$marker" "$progress" "$progress_compose")" = "$markers_before" ] \
    || fail "the refused run other-update-failed-restore changed $marker, $progress or $progress_compose"
  hx sh -c "printf 'failed_version: 99.0.0\nrolled_back_to: $old_version\nbackup: $backups/20200101T000000Z-$old_version\ntime: 2020-01-01T00:00:00Z\n' >$marker"
  # A copy of the compose file that cannot be read (here: a directory) fails
  # the restore with a message of its own, before any change.
  hx mkdir "$dir/copy-dir"
  play_fails unreadable-copy "$here/converge.yml" -vvv -e tandoor_restore_interrupted=true \
    -e "tandoor_update_marker_compose=$dir/copy-dir"
  expect_in_log unreadable-copy "Reading $dir/copy-dir, the copy of the compose file from before the interrupted update, failed"
  expect_no_secrets unreadable-copy
  expect_untouched unreadable-copy
  hx rmdir "$dir/copy-dir"
  # As a restore leaves it that was stopped while it put the media back: web
  # stopped, the copy of the backup's media made, the media found set aside,
  # none put back yet. The next restore puts them back all the same.
  hx sh -c "cd $dir && docker compose stop web" >/dev/null 2>&1
  set_aside="$(hx ls -A "$dir/data/mediafiles")"
  hx sh -c "cp -al $backup/mediafiles $dir/data/.mediafiles.restore && mkdir -m 0700 $backup-failed $backup-failed/mediafiles \
    && find $dir/data/mediafiles -mindepth 1 -maxdepth 1 -exec mv {} $backup-failed/mediafiles/ \;"
  # Beside update-failed of another version, which the healthy restore
  # removes as any run that succeeds.
  expect_restored interrupted-restore
  hx test ! -e "$marker" || fail "the restore kept $marker of another version"
  hx test ! -e "$dir/data/.mediafiles.restore" || fail "the restore left $dir/data/.mediafiles.restore"
  expect_same_owner "$dir/data/mediafiles" "$backup/mediafiles"
  # What the stopped restore set aside stays there.
  expect_entries_in "$backup-failed/mediafiles" "$set_aside"

  echo "== an update killed during its rollback must be refused until it is restored"
  hx docker tag "$busybox" "test.invalid/recipes:$version"
  play_killed interrupted-rollback \
    "backup=\$(sed -n 's/^backup: //p' $progress) && [ -n \"\$backup\" ] && [ -e \"\$backup-failed\" ]" \
    -vvv -e tandoor_image=test.invalid/recipes -e tandoor_health_timeout=30 -e tandoor_rollback_timeout=300
  expect_no_secrets interrupted-rollback
  # The killed run was the first one without the variable after the
  # restore, so it tried the update to $version again (into the failed
  # start and its rollback).
  grep -qF "Stop Tandoor for the update" "$out/interrupted-rollback.log" \
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
  hx test -d "$backup-failed" || fail "the media of the failed attempt in $backup-failed are gone"

  echo "== an update whose copies cannot be written must fail before the backup with a message of its own"
  play_fails copy-fails "$here/converge.yml" -vvv -e tandoor_update_marker_compose=/nonexistent/compose.yaml
  expect_in_log copy-fails "failed before anything changed"
  expect_in_log copy-fails "Writing /nonexistent/compose.yaml, the copy of the files from before the update, failed"
  expect_no_secrets copy-fails
  expect_no_progress "after the update whose copies failed"
  [ "$(web)" = "${old_images[0]} running healthy" ] || fail "web after the update whose copies failed: $(web)"

  echo "== an update killed during its backup must be cleaned up and done by the next run"
  play_killed interrupted-backup "ls -d $backups/*.partial" -v
  expect_no_secrets interrupted-backup
  hx grep -qx "step: backup" "$progress" || fail "the marker does not record the step backup: $(hx cat "$progress")"
  converge -v
  expect_no_secrets converge
  grep -q "update.yml" "$out/converge.log" || fail "the run after the interrupted backup was not an update"
  expect_marker_removed_first converge
  [ "$(web)" = "${images[0]} running healthy" ] || fail "web after the update: $(web)"
  if hx sh -c "ls -d $backups/*.partial" >/dev/null 2>&1; then
    fail "the update left a partial backup: $(hx ls "$backups")"
  fi
  expect_no_progress "after the update"
  expect_recipe "after the update that followed the interrupted backup"
  expect_idempotent

  echo "== a restore that cannot set an entry of the media aside must fail and keep what the failed attempt left"
  # An interrupted update to $version from the backup of the update above.
  backup="$(hx sh -c "ls -d $backups/*-$old_version | tail -n 1")"
  hx sh -c "printf 'from_version: $old_version\nto_version: $version\nstep: update\nbackup: $backup\ntime: 2026-01-01T00:00:00Z\n' >$progress \
    && cp -p $backup/compose.yaml $progress_compose"
  busy_entry "$dir/data/mediafiles"
  play_fails restore-busy "$here/converge.yml" -e tandoor_restore_interrupted=true -e tandoor_rollback_timeout=60
  expect_in_log restore-busy "Restoring Tandoor $old_version in $dir from the backup $backup after the interrupted update to $version failed (Put the media back:"
  [ "$(hx cat "$busy/file")" = failed-attempt ] || fail "the entry that could not be set aside lost its content"
  expect_entries_in "$backup-failed/mediafiles" "$busy_before"
  hx test -d "$dir/data/.mediafiles.restore" || fail "the copy was put in place although an entry was not set aside"
}

test_interrupted_s3() {
  echo "== with media in S3, an interrupted update that rotated the secret key must be restored with the previous key"
  new_host
  load_images
  load_set "${old_images[@]}"
  load_set "${s3_images[@]}"
  hx sh -c 'echo "127.0.0.1 s3.test" >>/etc/hosts'
  converge -e "@$here/s3.yml" -e "tandoor_version=$old_version"
  add_recipe
  # The update also writes the rotated key into the secret file (RustFS
  # keeps its own), before its compose file.
  play_killed interrupted-s3 "grep -qF 'recipes:$version' $dir/compose.yaml" -vvv \
    -e "@$here/s3.yml" -e "s3_secret_key=$s3_rotated_secret"
  expect_no_secrets interrupted-s3
  hx grep -qx "step: update" "$progress" || fail "the marker does not record the step update: $(hx cat "$progress")"
  backup="$(hx sed -n 's/^backup: //p' "$progress")"
  for file in "$progress" "$progress_compose" "$progress_s3_secret"; do
    [ "$(hx stat -c '%a %U' "$file")" = "600 root" ] || fail "$file is not root's with mode 0600: $(hx stat -c '%a %U' "$file" 2>&1)"
  done
  [ "$(hx cat "$progress_s3_secret")" = "$s3_secret" ] || fail "$progress_s3_secret does not hold the secret key from before the update"
  [ "$(hx cat "$dir/s3-secret")" = "$s3_rotated_secret" ] || fail "the killed update did not write the rotated key into $dir/s3-secret"
  note_untouched
  play_fails interrupted-s3-refused "$here/converge.yml" -vvv -e "@$here/s3.yml" -e "s3_secret_key=$s3_rotated_secret"
  expect_interrupted_refusal interrupted-s3-refused "$backup"
  expect_no_secrets interrupted-s3-refused
  expect_untouched interrupted-s3-refused
  # Without the copy of the secret file the restore would keep the rotated key.
  hx mv "$progress_s3_secret" "$progress_s3_secret.away"
  play_fails restore-no-s3-copy "$here/converge.yml" -e "@$here/s3.yml" -e "s3_secret_key=$s3_rotated_secret" \
    -e tandoor_restore_interrupted=true
  expect_in_log restore-no-s3-copy "but $progress_s3_secret is missing, so the role cannot restore it"
  expect_untouched restore-no-s3-copy
  hx mv "$progress_s3_secret.away" "$progress_s3_secret"
  # One that cannot be read (here: a directory) is not taken for a missing
  # one: the restore fails with a message of its own, before any change.
  hx mkdir "$dir/copy-dir"
  play_fails unreadable-s3-copy "$here/converge.yml" -vvv -e "@$here/s3.yml" -e "s3_secret_key=$s3_rotated_secret" \
    -e tandoor_restore_interrupted=true -e "tandoor_update_marker_s3_secret=$dir/copy-dir"
  expect_in_log unreadable-s3-copy "Reading $dir/copy-dir, the copy of the S3 secret file from before the interrupted update, failed"
  expect_no_secrets unreadable-s3-copy
  expect_untouched unreadable-s3-copy
  hx rmdir "$dir/copy-dir"
  expect_restored interrupted-s3-restore -e "@$here/s3.yml"
  [ "$(hx cat "$dir/s3-secret")" = "$s3_secret" ] || fail "the restore did not put the previous key back into $dir/s3-secret"
  expect_container_secret "$s3_secret" "the previous key after the restore"

  echo "== a restore of an interrupted update that fails must record a failed rollback"
  # The installed release under a name that is then untagged: the restore
  # cannot start it again (no such registry), after the database was
  # recreated and loaded. The new release under that name as well.
  hx docker tag "${old_images[0]}" "test.invalid/recipes:$old_version"
  hx docker tag "${images[0]}" "test.invalid/recipes:$version"
  converge -e "@$here/s3.yml" -e "tandoor_version=$old_version" -e tandoor_image=test.invalid/recipes
  play_killed interrupted-s3-failing "grep -qF 'test.invalid/recipes:$version' $dir/compose.yaml" -v \
    -e "@$here/s3.yml" -e tandoor_image=test.invalid/recipes
  expect_no_secrets interrupted-s3-failing
  backup="$(hx sed -n 's/^backup: //p' "$progress")"
  [ -n "$backup" ] || fail "the killed update left no marker with a backup: $(hx cat "$progress" 2>&1)"
  hx docker rmi "test.invalid/recipes:$old_version" >/dev/null
  play_fails restore-failed "$here/converge.yml" -vvv -e "@$here/s3.yml" -e tandoor_image=test.invalid/recipes \
    -e tandoor_restore_interrupted=true -e tandoor_rollback_timeout=60
  expect_in_log restore-failed "Restoring Tandoor $old_version in $dir from the backup $backup after the interrupted update to $version failed"
  expect_in_log restore-failed "Roll back by hand in $dir"
  expect_no_secrets restore-failed
  hx grep -qx "failed_version: $version" "$marker" || fail "the marker does not name $version: $(hx cat "$marker" 2>&1)"
  hx grep -qx "rolled_back_to: null" "$marker" || fail "the marker does not record a failed rollback: $(hx cat "$marker")"
  hx grep -qx "backup: $backup" "$marker" || fail "the marker does not name the backup $backup: $(hx cat "$marker")"
  hx grep -q "^restore_error: ." "$marker" || fail "the marker records no restore error: $(hx cat "$marker")"
  expect_no_progress "after the failed restore"
  note_untouched
  play_fails restore-failed-blocked "$here/converge.yml" -e "@$here/s3.yml" -e tandoor_image=test.invalid/recipes
  expect_in_log restore-failed-blocked "$marker exists: the Tandoor update to $version failed"
  expect_in_log restore-failed-blocked "The role refuses every version"
  expect_untouched restore-failed-blocked
}

# All scenarios by default; NOIXDEV_INFRA_TANDOOR_TESTS="settings router"
# runs only these (router installs a host when install did not run before).
for scenario in ${NOIXDEV_INFRA_TANDOOR_TESTS:-settings install router s3 update failed_update refusals missing_data mountpoint db_check interrupted interrupted_s3}; do
  case "$scenario" in
    settings | install | router | s3 | update | failed_update | refusals | missing_data | mountpoint | db_check | interrupted | interrupted_s3) "test_$scenario" ;;
    *) fail "unknown scenario $scenario (settings, install, router, s3, update, failed_update, refusals, missing_data, mountpoint, db_check, interrupted, interrupted_s3)" ;;
  esac
done

noix_done
echo "== all tandoor tests passed"
