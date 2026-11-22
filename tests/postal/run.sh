#!/usr/bin/env bash
# End-to-end test of the postal role on a throwaway systemd host per Ubuntu
# release, with Docker inside (the docker role), the traefik role in front
# (plain HTTP, HTTPS with Traefik's own certificate and "ui", a second HTTPS
# entrypoint standing in for a tailnet one, on 127.0.0.1, and a "deny"
# middleware; vars.yml) and Mailpit catching the mail (converge.yml; SMTP on
# the host's 127.0.0.1:1025 and on the Traefik network as mailpit:1025, its
# API on 127.0.0.1:8025):
#   refusals  settings the role must refuse: each run fails with its message
#             and leaves no /opt/postal
#   install   a fresh install with the own MariaDB and the first admin
#             (verify.yml: web on the Traefik network without a published
#             port, smtp, submission and worker on the host's network,
#             MariaDB on 127.0.0.1:3307 only, no secret in an environment,
#             the modes of postal.yml and signing.key, a 2048-bit signing
#             key, the values the role owns in postal.yml and no smtp host);
#             the DNS records in the install's output with the rp. DKIM
#             record of the signing key; no secret in the compose file or
#             docker inspect; the admin logs in through the login form from a
#             container on the Traefik network and sees the organization
#             list; other postal_admin_* values on the next run change nothing
#             and make no second user; postal_mail to Mailpit: the smtp section
#             in postal.yml and a password reset mail arriving in Mailpit
#   noop_down a stopped smtp service: a run without changes fails naming it
#             and starts nothing
#   reconfigure
#             a new postal_settings.default_spam_threshold rewrites postal.yml
#             and restarts web, smtp, submission and worker, not MariaDB; the
#             signing key stays byte-identical; a pending restart (its
#             marker, as a stopped reconfigure leaves it) restarts them on the
#             next run; postal_smtp_submission_port 0 removes the submission
#             service and the health check asks smtp only; a larger
#             postal_max_message_size recreates MariaDB with the larger redo
#             log (mariadb.cnf) and restarts the Postal services; the
#             default brings everything back
#   takeover  the MariaDB data of an installation without its compose file,
#             configuration and database target (a takeover): refused as not
#             supported yet, with another postal_db_password that the
#             database then still refuses and root still on the socket; with
#             a root that has a password the same; the files and containers
#             the refused run made are gone again, and with the old files back
#             Postal runs as before
#   ipv6_off  IPv6 switched off on the test host: the SMTP servers listen on
#             0.0.0.0 (postal.yml, the sockets) and answer EHLO; back on, on ::
#   missing_data
#             the MariaDB data moved away (an unmounted volume): the run
#             refuses and creates nothing, and compose does not start MariaDB
#             either; with the data back it runs as before
#   mountpoint
#             postal_data_dir_mountpoint on a plain directory refused, nothing
#             changed (installed) or created (a fresh directory)
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
# passwords hold $, a quote and a space, so that the tests prove they reach
# the database, the files and the commands as written. (Postal puts the
# database password into a double-quoted YAML string, so the role refuses a
# double quote or a backslash in it.) The signing key and the Rails secret the
# role generates join the list once an install made them (note_generated).
db_password="$(openssl rand -hex 12)"' pa$s w'"'"'o rd'
admin_password="$(openssl rand -hex 10)"' ad$m '"'"'in'
admin_email=admin@example.test
secrets=("$db_password" "$admin_password")

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
  write_db_vars new-db-vars.json "${db_password}-new"
  # Postal puts the password into a double-quoted YAML string.
  write_db_vars quote-db-vars.json 'a"b'"$db_password"
  write_db_vars backslash-db-vars.json 'a\b'"$db_password"
  write_admin_vars admin-vars.json "$admin_email" "$admin_password" Noix Admin
  write_admin_vars other-admin-vars.json other@example.test "${admin_password}-other" Other Person
}
# write_admin_vars <file> <email> <password> <first name> <last name>: the
# first admin, in a file of mode 0600.
write_admin_vars() {
  (
    umask 077
    env "EMAIL=$2" "PASSWORD=$3" "FIRST=$4" "LAST=$5" python3 -c '
import json, os
print(json.dumps({"postal_admin_email": os.environ["EMAIL"], "postal_admin_password": os.environ["PASSWORD"],
                  "postal_admin_first_name": os.environ["FIRST"], "postal_admin_last_name": os.environ["LAST"]}))' >"$out/$1"
  )
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
# install_converge [-e ...]: the same with the first admin of the run.
install_converge() { postal_converge -e "@$out/admin-vars.json" "$@"; }
install_converge_unchanged() { postal_converge_unchanged -e "@$out/admin-vars.json" "$@"; }
install_converge_fails() { postal_converge_fails -e "@$out/admin-vars.json" "$@"; }

# verify [-e ...]: verify.yml; its output must hold no test secret either.
verify() {
  ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$here/verify.yml" "$@" >"$out/verify.log" 2>&1 \
    || { cat "$out/verify.log" >&2; fail "verify.yml failed"; }
  expect_no_secrets "$out/verify.log" "the output of verify.yml"
}

# start_host <ubuntu>: a fresh systemd host with Docker, Traefik and Mailpit,
# where postal.test is 127.0.0.1 and web.sh is /root/web.sh. IPv6 is on, as on
# a server: Postal's SMTP server listens on ::.
start_host() {
  local ubuntu="$1"
  host="noixdev-postal-$ubuntu"
  docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  # The anonymous volumes give the inner Docker a file system it can mount
  # overlays on; "docker rm -v" removes them with the host.
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --name "$host" "noixdev-infra-host:$ubuntu" >/dev/null
  until (h systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
  # The image's policy-rc.d (exit 101) keeps package scripts from starting
  # services; servers have none.
  h rm -f /usr/sbin/policy-rc.d
  h sh -c 'echo "127.0.0.1 postal.test" >>/etc/hosts'
  docker cp "$here/web.sh" "$host:/root/web.sh" >/dev/null
  secrets=("$db_password" "$admin_password")

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

# docker compose in app_dir on the test host: compose <args...>.
compose() { h sh -c "cd $app_dir && docker compose $*"; }
# The container of a service (the first replica): container <service>.
container() { printf '%s\n' "postal-$1-1"; }
started_at() { h docker inspect --format '{{.State.StartedAt}}' "$(container "$1")"; }
# postal_rails '<ruby>': runs the Ruby code in Postal's Rails environment (as
# postal console does) through rails runner in the runner service, and prints
# what it prints. The code goes through stdin into the argument of rails
# runner inside the test host.
postal_rails() {
  printf '%s' "$1" | hi sh -c 'cd '"$app_dir"' && exec docker compose run --rm -T runner bundle exec rails runner "$(cat)"' \
    2>>"$out/rails.log"
}
# Mailpit's API on the test host: the number of messages, and the newest one
# as JSON.
mailpit_count() {
  h curl -s --max-time 30 http://127.0.0.1:8025/api/v1/messages \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["total"])'
}
mailpit_last_json() { h curl -s --max-time 30 http://127.0.0.1:8025/api/v1/message/latest; }
# The address of web on the Traefik network.
web_ip() { h docker inspect --format '{{(index .NetworkSettings.Networks "proxy").IPAddress}}' "$(container web)"; }
# web <action> [args...]: web.sh in the runner (on the Traefik network, not
# started with its dependencies) against web's address there; stdin goes to
# web.sh.
web() {
  local action="$1"
  shift
  hi sh -c 'cd '"$app_dir"' && exec docker compose run --rm --no-deps -T --entrypoint sh runner -c "$(cat /root/web.sh)" web.sh "$@"' \
    sh "$action" "$(web_ip)" "$@" 2>>"$out/web.log"
}
# admin_login <email> <password>: logs in through the login form and prints
# the status of POST /login, then the page / and its status.
admin_login() { printf '%s\n%s' "$1" "$2" | web login; }

# Adds what the install generated, the Rails secret and a line of the private
# part of the signing key, to the secrets no output may hold.
note_generated() {
  local rails_secret key_line
  rails_secret="$(h sed -n 's/^  secret_key: *//p' "$app_dir/config/postal.yml" | tr -d "'\"")"
  key_line="$(h sed -n '12p' "$app_dir/config/signing.key")"
  [ "${#rails_secret}" = 128 ] || fail "postal.yml holds no generated Rails secret of 128 characters"
  [ "${#key_line}" -ge 32 ] || fail "signing.key has no line 12"
  secrets=("$db_password" "$admin_password" "$rails_secret" "$key_line")
}
# Fails when the compose file or docker inspect of the project holds a test
# secret.
expect_clean() {
  h cat "$app_dir/compose.yaml" >"$out/compose.yaml"
  expect_no_secrets "$out/compose.yaml" "$app_dir/compose.yaml"
  h sh -c 'docker inspect $(docker ps -aq --filter label=com.docker.compose.project=postal)' >"$out/inspect.json"
  expect_no_secrets "$out/inspect.json" "docker inspect of the project"
}
# Notes the compose file, the configuration and the containers, for
# expect_untouched.
note_untouched() {
  untouched_before="$(h sh -c "sha256sum $app_dir/compose.yaml $app_dir/config/*; docker ps -aq --filter label=com.docker.compose.project=postal")"
}
# Fails unless the refused run changed nothing: its recap, the files and the
# containers since note_untouched.
expect_untouched() {
  grep -Eq 'changed=0 ' "$out/converge.log" || { cat "$out/converge.log" >&2; fail "the refused run changed something"; }
  [ "$(h sh -c "sha256sum $app_dir/compose.yaml $app_dir/config/*; docker ps -aq --filter label=com.docker.compose.project=postal")" = "$untouched_before" ] \
    || fail "the refused run changed the compose file, the configuration or the containers"
}
# Notes when each Postal service started, for expect_restarted.
note_starts() {
  local service
  starts_before=
  for service in web smtp submission worker mariadb; do
    starts_before="$starts_before $service=$(started_at "$service" 2>/dev/null || echo none)"
  done
}
# expect_restarted <services...>: these services started again since
# note_starts, and the others of web, smtp, submission, worker and mariadb did
# not.
expect_restarted() {
  local service before now
  for service in web smtp submission worker mariadb; do
    before="$(printf '%s\n' "$starts_before" | tr ' ' '\n' | sed -n "s/^$service=//p")"
    now="$(started_at "$service" 2>/dev/null || echo none)"
    case " $* " in
      *" $service "*) [ "$now" != "$before" ] || fail "$service was not restarted" ;;
      *) [ "$now" = "$before" ] || fail "$service was restarted ($before, now $now)" ;;
    esac
  done
}

# An installation with the first admin, as the install scenario makes it,
# for a scenario that runs on a host without one.
ensure_installed() {
  h test -e "$app_dir/compose.yaml" && return 0
  echo "== install for $1"
  install_converge
  note_generated
}

test_refusals() {
  echo "== refusals (ubuntu $1)"
  refused 'postal_web_hostname is required' -e postal_web_hostname=
  refused 'postal_dns_domain is required' -e postal_dns_domain=
  refused 'postal_db_password is required' -e postal_db_password=
  refused 'postal_db_password must not hold' -e "@$out/quote-db-vars.json"
  refused 'postal_db_password must not hold' -e "@$out/backslash-db-vars.json"
  refused 'is not a release the role runs' -e postal_version=latest
  refused 'is not a release the role runs' -e postal_version=2.3.0
  refused 'is not a release the role runs' -e postal_version=3.5
  refused 'value of postal_database must be one of' -e postal_database=mysql
  refused 'postal_db_host is required' -e postal_database=mariadb_external
  refused 'an external MariaDB is not supported yet' -e postal_database=mariadb_external -e postal_db_host=db.example.test
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
  # postal_smtp_submission_port 0 is accepted: the reconfigure scenario runs
  # it.

  # An arm64 test host is not x86_64: without postal_skip_arch_check the role
  # refuses it. (On an x86_64 machine the host is x86_64 and there is nothing
  # to refuse.)
  if [ "$(h uname -m)" != x86_64 ]; then
    refused "exists for linux/amd64 only" -e postal_skip_arch_check=false
  else
    echo "== refusals: the test host is x86_64, the arch refusal is skipped"
  fi
}

test_install() {
  local answer pub users
  echo "== install (ubuntu $1)"
  install_converge
  h test ! -e "$app_dir/install-incomplete" || fail "the install left $app_dir/install-incomplete"
  # The DNS records, with the return-path DKIM record of the signing key.
  pub="$(h sh -c "openssl pkey -in $app_dir/config/signing.key -pubout | grep -v -- ----- | tr -d '\n'")"
  expect_in_log 'postal._domainkey.rp.mail.test'
  expect_in_log "v=DKIM1; t=s; h=sha256; p=$pub;"
  expect_in_log 'mx.mail.test'
  expect_in_log 'spf.mail.test'
  expect_in_log 'routes.mail.test'
  expect_in_log 'track.mail.test'
  note_generated
  verify
  expect_clean
  install_converge_unchanged

  # The admin logs in from a container on the Traefik network and sees the
  # organization list (none yet).
  answer="$(admin_login "$admin_email" "$admin_password")"
  [ "$(printf '%s\n' "$answer" | head -n 1)" = 302 ] || fail "the login was not redirected: $(printf '%s' "$answer" | head -c 300)"
  [ "${answer##*$'\n'}" = 200 ] || fail "/ after the login answered ${answer##*$'\n'}"
  [[ "$answer" == *'Welcome to Postal, Noix'* && "$answer" == *'There are no organizations.'* ]] \
    || fail "/ after the login is not the organization list: $(printf '%s' "$answer" | head -c 300)"
  # A wrong password: the form again (200, no redirect), and / sends to the
  # login.
  answer="$(admin_login "$admin_email" "${admin_password}-wrong")"
  { [ "$(printf '%s\n' "$answer" | head -n 1)" = 200 ] && [ "${answer##*$'\n'}" = 302 ]; } \
    || fail "a wrong password was not refused: $(printf '%s\n' "$answer" | head -n 1) ${answer##*$'\n'}"

  # Other postal_admin_* values change nothing and make no second user.
  postal_converge_unchanged -e "@$out/other-admin-vars.json"
  users="$(postal_rails 'puts User.count')"
  [ "$users" = 1 ] || fail "Postal has $users users after a run with another admin, not 1"

  # Postal's own mail to Mailpit: the smtp section, and a password reset mail.
  echo "== install: postal_mail (ubuntu $1)"
  local mail='{"postal_mail": {"host": "mailpit", "port": 1025}}' count
  install_converge -e "$mail"
  verify -e verify_mail_host=mailpit -e verify_mail_port=1025
  install_converge_unchanged -e "$mail"
  count="$(mailpit_count)"
  answer="$(printf '%s\n' "$admin_email" | web reset)"
  [ "$answer" = 302 ] || fail "the password reset was not redirected: $answer"
  for _ in $(seq 30); do
    [ "$(mailpit_count)" -gt "$count" ] && break
    sleep 2
  done
  mailpit_last_json >"$out/mail.json"
  python3 - "$out/mail.json" "$admin_email" <<'PY' || fail "no password reset mail from postal@mail.test reached $admin_email: $(head -c 300 "$out/mail.json")"
import json, sys
mail = json.load(open(sys.argv[1]))
assert [to["Address"] for to in mail["To"]] == [sys.argv[2]], mail["To"]
assert mail["From"]["Address"] == "postal@mail.test", mail["From"]
PY

  # Back to the settings of the other scenarios.
  install_converge
  verify
  install_converge_unchanged
}

test_noop_down() {
  echo "== noop_down (ubuntu $1)"
  ensure_installed noop_down
  compose stop smtp >/dev/null 2>&1
  note_untouched
  install_converge_fails
  expect_in_log "the services smtp are not running"
  [ "$(compose ps --all --format "'{{.State}}'" smtp)" = exited ] || fail "the run without changes started smtp"
  expect_untouched
  compose start smtp >/dev/null 2>&1
  install_converge_unchanged
}

test_reconfigure() {
  local key threshold='{"postal_settings": {"default_spam_threshold": 7}}'
  echo "== reconfigure (ubuntu $1)"
  ensure_installed reconfigure

  # A setting of postal.yml: rewritten, the Postal services restarted, MariaDB
  # and the signing key left as they are.
  key="$(h sha256sum "$app_dir/config/signing.key")"
  note_starts
  install_converge -e "$threshold"
  grep -Eq 'changed=[1-9]' "$out/converge.log" || fail "the new spam threshold changed nothing"
  expect_restarted web smtp submission worker
  [ "$(h sha256sum "$app_dir/config/signing.key")" = "$key" ] || fail "the reconfigure changed signing.key"
  verify -e verify_spam_threshold=7
  install_converge_unchanged -e "$threshold"

  # A restart a stopped reconfigure left pending: the next run restarts the
  # Postal services, though the files equal the settings, and removes it.
  echo "== reconfigure: a pending restart (ubuntu $1)"
  h touch "$app_dir/restart-pending"
  note_starts
  install_converge -e "$threshold"
  expect_restarted web smtp submission worker
  h test ! -e "$app_dir/restart-pending" || fail "the healthy run kept $app_dir/restart-pending"
  install_converge_unchanged -e "$threshold"

  # Without the submission service: removed, and the health check asks smtp
  # alone; the default brings it back (and the spam threshold goes).
  echo "== reconfigure: no submission service (ubuntu $1)"
  install_converge -e '{"postal_smtp_submission_port": 0}'
  [ -z "$(compose ps --all --quiet submission)" ] || fail "the submission service is left with postal_smtp_submission_port 0"
  expect_in_log '(item=smtp on 25)'
  expect_not_in_log '(item=submission on 587)'
  verify -e verify_submission=false
  install_converge_unchanged -e '{"postal_smtp_submission_port": 0}'
  install_converge

  # MariaDB's settings: a new mariadb.cnf recreates it, and the run waits for
  # it before it sets up the user; postal.yml changes too (the message size).
  echo "== reconfigure: MariaDB's settings (ubuntu $1)"
  note_starts
  install_converge -e '{"postal_max_message_size": 20}'
  expect_restarted web smtp submission worker mariadb
  h grep -qx 'innodb_log_file_size = 200M' "$app_dir/mariadb.cnf" || fail "mariadb.cnf lacks the redo log of 200M"
  [ "$(compose exec -T mariadb mariadb --user=root --batch --skip-column-names --execute="'SELECT @@innodb_log_file_size'")" = 209715200 ] \
    || fail "MariaDB does not run with the redo log of 200M"
  install_converge_unchanged -e '{"postal_max_message_size": 20}'
  install_converge
  verify
  expect_clean
  install_converge_unchanged
}

# db_login <password>: whether Postal's user logs in to the own MariaDB with
# it, over TCP as Postal does; the password goes through stdin.
db_login() {
  printf '%s' "$1" | hi sh -c 'cd '"$app_dir"' && exec docker compose exec -T mariadb sh -c '"'"'MYSQL_PWD="$(cat; echo x)"; MYSQL_PWD="${MYSQL_PWD%x}"; export MYSQL_PWD; exec mariadb --host=127.0.0.1 --port=3307 --user=postal --execute="SELECT 1"'"'" >/dev/null 2>&1
}
root_user() { compose exec -T mariadb mariadb --user=root --batch --skip-column-names --execute="'SHOW CREATE USER root@localhost'"; }
# Moves the compose file, the configuration, mariadb.cnf and the database
# target aside, with Postal down: the data of an installation without it.
set_files_aside() {
  compose down >/dev/null 2>&1
  h sh -c "rm -rf /root/aside && mkdir /root/aside && cd $app_dir && mv compose.yaml config mariadb.cnf database-target /root/aside/"
}
# Puts them back over what a run wrote, and MariaDB up.
put_files_back() {
  h sh -c "cd $app_dir && rm -rf compose.yaml config mariadb.cnf database-target && mv /root/aside/* . && docker compose up -d --wait mariadb" >/dev/null 2>&1 \
    || fail "MariaDB does not start with the files put back"
}
# expect_refused_takeover <reason>: the refused run left nothing but the
# configuration directory, and the database user still takes the old
# password only.
expect_refused_takeover() {
  expect_in_log 'taking over an existing Postal database is not supported yet'
  expect_in_log "$1"
  expect_not_in_log "Create Postal's database user and its grants"
  expect_not_in_log 'Initialize the database'
  local file
  for file in compose.yaml mariadb.cnf database-target install-incomplete; do
    h test ! -e "$app_dir/$file" || fail "the refused takeover left $app_dir/$file"
  done
  [ -z "$(h docker ps -aq --filter label=com.docker.compose.project=postal)" ] || fail "the refused takeover left containers"
}

test_takeover() {
  echo "== takeover (ubuntu $1)"
  ensure_installed takeover
  set_files_aside
  install_converge_fails -e "@$out/new-db-vars.json"
  expect_refused_takeover "postal holds Postal's schema"
  put_files_back
  db_login "$db_password" || fail "the refused takeover changed the password of Postal's database user"
  if db_login "${db_password}-new"; then fail "the refused takeover gave Postal's database user the new password"; fi
  [[ "$(root_user)" == *'IDENTIFIED VIA unix_socket'* ]] || fail "root is no longer on the socket: $(root_user)"

  # A root with a password: it does not log in through the socket, which is
  # refused as well, and the password stays.
  echo "== takeover: a root with a password (ubuntu $1)"
  compose exec -T mariadb mariadb --user=root --execute="\"ALTER USER root@localhost IDENTIFIED BY 'noix-root-test'\""
  set_files_aside
  install_converge_fails -e "@$out/new-db-vars.json"
  expect_refused_takeover 'its root does not log in through the socket'
  put_files_back
  [[ "$(compose exec -T -e MYSQL_PWD=noix-root-test mariadb mariadb --user=root --batch --skip-column-names \
        --execute="'SHOW CREATE USER root@localhost'")" == *PASSWORD* ]] || fail "the refused takeover changed root"
  db_login "$db_password" || fail "the refused takeover changed the password of Postal's database user"
  compose exec -T -e MYSQL_PWD=noix-root-test mariadb mariadb --user=root \
    --execute="\"ALTER USER root@localhost IDENTIFIED VIA unix_socket\""

  compose up -d >/dev/null 2>&1
  install_converge_unchanged
  [ "$(postal_rails 'puts User.count')" = 1 ] || fail "the admin is gone after the refused takeovers"
}

test_ipv6_off() {
  echo "== ipv6_off (ubuntu $1)"
  ensure_installed ipv6_off
  h sysctl -q -w net.ipv6.conf.all.disable_ipv6=1
  note_starts
  install_converge
  expect_restarted web smtp submission worker
  verify -e verify_smtp_bind=0.0.0.0
  for port in 25 587; do
    h ss -ltnH "sport = :$port" | grep -q "0.0.0.0:$port " || fail "nothing listens on 0.0.0.0:$port: $(h ss -ltnH "sport = :$port")"
  done
  expect_in_log '(item=smtp on 25)'
  expect_in_log '(item=submission on 587)'
  install_converge_unchanged
  h sysctl -q -w net.ipv6.conf.all.disable_ipv6=0
  install_converge
  verify
  install_converge_unchanged
}

test_missing_data() {
  echo "== missing_data (ubuntu $1)"
  ensure_installed missing_data
  compose stop >/dev/null 2>&1
  h mv "$app_dir/data/mariadb" "$app_dir/data/mariadb.aside"
  note_untouched
  install_converge_fails
  expect_in_log "lacks mariadb: is the volume mounted?"
  h test ! -e "$app_dir/data/mariadb" || fail "the refused run created $app_dir/data/mariadb"
  expect_untouched
  # compose does not create the bind's source either.
  if compose start mariadb >/dev/null 2>&1; then fail "docker compose started MariaDB without its data"; fi
  h test ! -e "$app_dir/data/mariadb" || fail "docker compose created $app_dir/data/mariadb"

  h mv "$app_dir/data/mariadb.aside" "$app_dir/data/mariadb"
  compose start >/dev/null 2>&1
  install_converge_unchanged
  [ "$(postal_rails 'puts User.count')" = 1 ] || fail "the admin is gone after the data came back"
}

test_mountpoint() {
  echo "== mountpoint (ubuntu $1)"
  ensure_installed mountpoint
  note_untouched
  install_converge_fails -e postal_data_dir_mountpoint=true
  expect_in_log "is not a mountpoint: is the volume mounted?"
  expect_untouched
  install_converge_fails -e postal_data_dir_mountpoint=true -e postal_dir=/opt/postal-mountpoint
  expect_in_log "/opt/postal-mountpoint/data is not a mountpoint"
  h test ! -e /opt/postal-mountpoint || fail "the refused run created /opt/postal-mountpoint"
}

# All scenarios by default; NOIXDEV_INFRA_POSTAL_TESTS="install" runs only
# these. A new scenario is a test_<name> function and one line in the case
# below.
all_scenarios="refusals install noop_down reconfigure takeover ipv6_off missing_data mountpoint"
scenarios="${NOIXDEV_INFRA_POSTAL_TESTS:-$all_scenarios}"
for ubuntu in $releases; do
  start_host "$ubuntu"
  for scenario in $scenarios; do
    case "$scenario" in
      refusals) test_refusals "$ubuntu" ;;
      install) test_install "$ubuntu" ;;
      noop_down) test_noop_down "$ubuntu" ;;
      reconfigure) test_reconfigure "$ubuntu" ;;
      takeover) test_takeover "$ubuntu" ;;
      ipv6_off) test_ipv6_off "$ubuntu" ;;
      missing_data) test_missing_data "$ubuntu" ;;
      mountpoint) test_mountpoint "$ubuntu" ;;
      *) fail "unknown scenario $scenario ($all_scenarios)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all postal tests passed"
