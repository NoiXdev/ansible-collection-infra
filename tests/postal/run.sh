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
#             default brings everything back; a postal_signing_key or
#             postal_rails_secret_key that differs from the installation's
#             refused without a change, its own keys given change nothing
#   takeover_refusals
#             an install over Postal's data without its keys, refused before
#             any change: the MariaDB data of an installation without its
#             compose file, configuration and database target, run without
#             postal_signing_key, without postal_rails_secret_key and without
#             both (no file written, no container, the data unchanged), and
#             the same with postal_import_dump on a host without the
#             installation (nothing created); a dump that is no file, a path
#             that is no .sql or .sql.gz, postal_import_dump with
#             mariadb_external, and a dump to load into MariaDB data that
#             holds Postal's databases, refused before any change too; with
#             the keys but a root that has a password: refused once MariaDB
#             runs, the files and containers the run made gone again, root
#             and the password of Postal's user (the run had another)
#             unchanged; then that data with the keys taken over (postal
#             upgrade, not initialize, the signing key unchanged, the admin
#             alone)
#   takeover  an installation with the fixture and a message through the
#             API, dumped (mariadb-dump --databases, .sql.gz) and its keys
#             noted, then postal_dir wiped: an install with
#             postal_import_dump and the keys loads it and runs postal
#             upgrade, not initialize, and makes no second user (other
#             postal_admin_*); it prints the old rp. DKIM record, has the
#             organization, the credential and the message, the old admin
#             logs in and the API sends; the next run, the dump still set,
#             loads nothing and changes nothing
#   row_format
#             a table of the main and of a message database set to
#             ROW_FORMAT=COMPACT before the dump (.sql): the takeover converts
#             both, names them, and leaves no table of either that is not
#             Dynamic
#   custom_names
#             postal_db_name and postal_message_db_prefix mailer: an install
#             makes the databases mailer and mailer-server-1 (Postal names a
#             message database <prefix>-server-<id>) and no postal one, the
#             API sends; their dump taken over with the names has the message
#             and sends
#   ipv6_off  IPv6 switched off on the test host: the SMTP servers listen on
#             0.0.0.0 (postal.yml, the sockets) and answer EHLO; back on, on ::
#   routers   the Traefik routers of web (verify.yml: every traefik.* label):
#             on the default entrypoints the API (Postal's JSON error without
#             a key), the JWKS, the login page and tracking on
#             track.mail.test (Postal's "Hello."), and a client's
#             X-Postal-Track-Host, in any of the eight spellings Puma reads
#             as it, alone or next to the all-dash one, never reaches Postal
#             on the web host name (the login page and the API on websecure,
#             and on ui once the UI is there); postal_traefik_ui_middlewares denying
#             everyone denies the UI while the API and tracking answer; the
#             API and tracking on websecure with the UI on ui: on websecure
#             Traefik's 404 for the UI's paths, on ui the login page (the
#             admin logs in there) and no API, tracking on one more host name
#             of postal_track_hostnames, and the tracking router sets the
#             header whatever the client sends
#   mail      postal_fixture (an organization, a mail server, the verified
#             domain mail.example.test, an API credential and a route to the
#             echo endpoint, echo.py, on the test host's loopback): a message
#             through the API router and one submitted on 587 with an SMTP
#             credential reach Mailpit (postal_smtp_relays) with a
#             DKIM-Signature of the signing key (postal._domainkey.rp.mail.test:
#             the domain's own key needs its DNS checked); a message to
#             in@routes.mail.test on port 25
#             reaches the echo endpoint (postal_allowed_request_destinations)
#   track_domains
#             customer tracking domains of Postal's track_domains table: one
#             whose DNS Postal has not verified gets no router (Traefik's
#             404); once its dns_status is OK the next run routes it on
#             postal-track-customers with the resolver http, recreating web
#             alone, and the run after that changes nothing; without SSL it is
#             routed too; a name in the table that is no host name is skipped
#             and named, never written into a rule; a table that cannot be
#             read (MariaDB stopped, a new postal_db_password) keeps the
#             routed domains; postal_track_hostnames go on postal-track (a
#             verified domain listed there too on postal-track alone); a
#             domain removed in Postal loses its router on the next run
#   smtp_tls  STARTTLS with Traefik's certificate (postal_smtp_tls traefik,
#             Traefik on Pebble, the test ACME server): a fresh install for
#             smtp.example.test waits for the certificate Traefik obtains
#             through the router postal-smtp, both SMTP ports offer STARTTLS
#             and show it (Pebble's, the one acme.json stores), smtp.cert and
#             smtp.key are 0440 root:999, the timer runs twice a day and its
#             service changes nothing; with the web host name as the SMTP
#             host name the API router's certificate and no router of its
#             own; no certificate within postal_health_timeout fails naming
#             the host and acme.json; off removes STARTTLS, the files, the
#             script and the timer; switched on again each SMTP service
#             starts once
#   cert_rotation
#             certificates written into acme.json beside Pebble's that
#             expire later (a wildcard of another resolver, a SAN of a third
#             one): one run of the timer's service prints updated and starts
#             smtp and submission once each (start times, Docker's events),
#             the next prints unchanged and starts nothing; a new
#             certificate and a new setting in one run of the role start each
#             SMTP service once; a pending restart (its marker) restarts them
#             on the next run of the role or of the script; without the
#             submission service the script restarts smtp alone
#   smtp_files
#             postal_smtp_tls files with a self-signed pair: copied 0440
#             root:999 and shown on both ports; a new pair at the same paths
#             starts smtp and submission once and nothing else; a missing
#             file and a key of another certificate refused before any change
#   smtp_off  postal_smtp_tls off (the suite's default): no STARTTLS on
#             either port, no certificate files, script or timer, and no
#             router for another SMTP host name
#   missing_data
#             the MariaDB data moved away (an unmounted volume): the run
#             refuses and creates nothing, and compose does not start MariaDB
#             either; with the data back it runs as before
#   mountpoint
#             postal_data_dir_mountpoint on a plain directory refused, nothing
#             changed (installed) or created (a fresh directory)
#   spam      rspamd and ClamAV (verify.yml: on the project network, published
#             on 127.0.0.1 alone, healthy; nothing else listens on their
#             ports): a message through the API, which the fixture's mail
#             server inspects (an outbound spam threshold), gets rspamd's
#             checks and ClamAV's clean verdict in its message record; a
#             message with the EICAR test file as an attachment to the route
#             on port 25 is flagged as a threat (Eicar in its record); with
#             postal_rspamd_password the controller refuses a client without
#             it and Postal's checks still pass; off again removes both
#             services. ClamAV starts from signatures this script downloads
#             once into tests/output/postal/clamav-db (freshclam in the pinned
#             image on this machine, updated on every run) and copies into the
#             data directory first, so that no test host downloads the full
#             database
#   oidc_gelf postal_oidc (the login page offers the provider, local logins
#             stay), postal_gelf to a UDP listener on the test host's
#             loopback, postal_use_ip_pools, postal_worker_replicas 2 and
#             relays with an ssl_mode: rendered into postal.yml and compose,
#             both workers run, a message through the API reaches Mailpit and
#             a GELF message with the facility reaches the listener
#   install_external
#             postal_database mariadb_external against a mariadb:11.4
#             container on the Traefik network (db.example.test, published on
#             the test host's 127.0.0.1:3306) with the two GRANTs of the
#             docs: refused before any change with a wrong password, against
#             a mysql:8.4 server, a user without the grant of the message
#             databases and a mariadb:10.5 server; an install without a
#             mariadb service, the fixture and a message through the API;
#             then refused without a change: a wrong password, that user, the
#             own MariaDB (naming both modes), another postal_db_host (naming
#             both servers); then a fresh install on that server, a
#             takeover: without the keys refused before any change, with the
#             keys of the installation postal upgrade, the old rp. DKIM
#             record, the admin, the fixture's credential and message, and a
#             message through the API
#   postal_dump
#             postal-dump (0700 root) by hand twice: two complete
#             directories (a complete dump of the main and of the message
#             database, postal.yml and signing.key); killed with SIGKILL
#             once it made <dir>.tmp, only that is left, and the next run
#             replaces it; without an argument, as backrest runs it, the
#             backup directory's latest; two arguments refused; an existing
#             directory without its mark, a file and / refused (exit 2) and
#             left as they are
#   update    from 3.4.0 with the fixture and a message to the default
#             3.5.0: postal upgrade, web on the new image, a backup with the
#             compose file, the configuration and the databases (one complete
#             dump each, root's, mode 0700), the data still there, the API
#             sends; a downgrade refused without a change; a further update
#             with postal_backups_keep 1 prunes the older backup
#   failed_update
#             to an image that exits (busybox tagged as the new version):
#             rolled back, 3.4.0 healthy with the data, update-failed names
#             the version, which a run with it is refused for without a
#             change; a run with another version removes the marker
#   broken_db to a release whose migration drops the servers table (Postal's
#             image with an entrypoint of the test): the database check
#             fails, rolled back, the servers table and the data back; then
#             one that drops the messages table of the fixture's message
#             database: the same
#   interrupted
#             postal_restore_interrupted without an interrupted update
#             refused; a converge killed once the compose file names the new
#             version: refused naming both versions without a change, then
#             postal_restore_interrupted puts 3.4.0 back with the data; a
#             converge killed during the backup: the next run removes the
#             partial backup and updates
#   no_space  a backup directory (a tmpfs of 64 KB) with less space than the
#             databases: the update refused before any change, no service
#             restarted
#   failed_update_external
#             on an external MariaDB (mariadb:11.4) that also holds a
#             database other: 3.4.0 with the fixture and a message, an update
#             to an image that exits rolled back (the data back, other
#             untouched), then the update to 3.5.0 with its backup, the data
#             and other as they were, the API sends
#   secrets   the install of 3.4.0, a reconfigure (rspamd with its password,
#             OIDC) and the update to 3.5.0 at -vvv, the process list sampled
#             during the update; an install on an external MariaDB at -vvv
#             and postal-dump with the process list sampled (dump.cnf 0600
#             root): no test secret in an output, the process list, the
#             compose file or docker inspect
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
# rspamd's controller password (no white space, $, double quote or
# backslash, which the role refuses there) and the OIDC client secret.
rspamd_password="$(openssl rand -hex 10)"\''rs'
oidc_secret="$(openssl rand -hex 16)"
secrets=("$db_password" "$admin_password" "$rspamd_password" "$oidc_secret")

# The TLS scenarios: Pebble, Let's Encrypt's test ACME server, on the
# Traefik network as pebble (its listener certificate names that host),
# passing every challenge (PEBBLE_VA_ALWAYS_VALID: no name has to resolve).
# Traefik asks it through LEGO_CA_CERTIFICATES, the CA of that listener in
# Traefik's acme directory, through the env file of the traefik role
# (traefik_dns_env), and the role takes Traefik's certificate for
# smtp.example.test.
pebble_image=ghcr.io/letsencrypt/pebble:2.10.1
acme_file=/opt/traefik/acme/acme.json
tls='{"traefik_acme_ca_server": "https://pebble:14000/dir", "traefik_dns_env": {"LEGO_CA_CERTIFICATES": "/acme/pebble.minica.pem"}, "postal_smtp_tls": "traefik", "postal_smtp_hostname": "smtp.example.test"}'

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
  # rspamd's controller password, and an OIDC provider whose endpoints are
  # given (no discovery: nothing answers at id.example.test).
  (
    umask 077
    env "OUT=$out" "RSPAMD_PASSWORD=$rspamd_password" "OIDC_SECRET=$oidc_secret" python3 -c '
import json, os
out = os.environ["OUT"]
json.dump({"postal_rspamd_password": os.environ["RSPAMD_PASSWORD"]}, open(os.path.join(out, "rspamd-vars.json"), "w"))
json.dump({"postal_oidc": {"enabled": True, "name": "Noix ID", "issuer": "https://id.example.test",
                           "identifier": "postal", "secret": os.environ["OIDC_SECRET"], "discovery": False,
                           "authorization_endpoint": "https://id.example.test/authorize",
                           "token_endpoint": "https://id.example.test/token",
                           "userinfo_endpoint": "https://id.example.test/userinfo",
                           "jwks_uri": "https://id.example.test/jwks"}}, open(os.path.join(out, "oidc-vars.json"), "w"))'
  )
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
# where postal.test is 127.0.0.1 and web.sh and echo.py are in /root. IPv6 is
# on, as on a server: Postal's SMTP server listens on ::.
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
  docker cp "$here/echo.py" "$host:/root/echo.py" >/dev/null
  secrets=("$db_password" "$admin_password" "$rspamd_password" "$oidc_secret")

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
# The start time of the service's container, none without one.
started_at() {
  local at
  at="$(h docker inspect --format '{{.State.StartedAt}}' "$(container "$1")" 2>/dev/null | tr -d '[:space:]' || true)"
  printf '%s\n' "${at:-none}"
}
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
    sh "$action" "http://$(web_ip):5000" "$@" 2>>"$out/web.log"
}
# admin_login <email> <password>: logs in through the login form and prints
# the status of POST /login, then the page / and its status.
admin_login() { printf '%s\n%s' "$1" "$2" | web login; }
# ui_login <email> <password>: the same through Traefik's ui entrypoint, from
# the test host.
ui_login() { printf '%s\n%s' "$1" "$2" | hi sh /root/web.sh login https://postal.test:8443 2>>"$out/web.log"; }

# A request through Traefik from the test host (HTTPS, Traefik's own
# certificate), to <name> resolved to 127.0.0.1: prints the body, then the
# status on a line of its own. request <port> <name> <path> [curl options...];
# port 443 is websecure, 8443 ui.
request() {
  local port="$1" name="$2" path="$3"
  shift 3
  h curl -sk --max-time 60 --resolve "$name:$port:127.0.0.1" -w '\n%{http_code}' "$@" "https://$name:$port$path" || true
}
# expect_answer <status> <body text> <port> <name> <path> [curl options...]:
# the status and a body that holds the text.
expect_answer() {
  local status="$1" text="$2" answer
  shift 2
  answer="$(request "$@")"
  { [ "${answer##*$'\n'}" = "$status" ] && [[ "${answer%$'\n'*}" == *"$text"* ]]; } \
    || fail "https://$2:$1$3 answered ${answer##*$'\n'} ($(printf '%s' "${answer%$'\n'*}" | head -c 200)), not $status with: $text"
}
# The same, retried while Traefik picks up new labels.
wait_answer() {
  local answer
  for _ in $(seq 60); do
    answer="$(request "${@:3}")"
    { [ "${answer##*$'\n'}" = "$1" ] && [[ "${answer%$'\n'*}" == *"$2"* ]]; } && return 0
    sleep 2
  done
  expect_answer "$@"
}
# Traefik's own 403 of the ipAllowList middleware (deny@file): the body is
# Forbidden. expect_denied <port> <name> <path> [curl options...].
expect_denied() {
  local answer
  answer="$(request "$@")"
  [ "$answer" = $'Forbidden\n403' ] || fail "https://$2:$1$3 was not denied by Traefik: ${answer##*$'\n'} $(printf '%s' "${answer%$'\n'*}" | head -c 200)"
}
wait_denied() {
  for _ in $(seq 60); do
    [ "$(request "$@")" = $'Forbidden\n403' ] && return 0
    sleep 2
  done
  expect_denied "$@"
}
# The answers of the routers: the sending API without a key (Postal's JSON
# error, which it sends with 200), the login page of the UI, and Postal's
# tracking server, which answers Hello. on every path it does not know.
api_refused() { expect_answer 200 '"code":"AccessDenied"' 443 postal.test /api/v1/send/message -X POST -H 'Content-Type: application/json' --data '{}' "$@"; }
login_page() { expect_answer 200 'name="email_address"' "$@"; }
tracking() { expect_answer 200 'Hello.' "$@"; }
# The eight spellings of X-Postal-Track-Host that Puma reads as that header:
# each of its three separators a dash or an underscore.
track_spellings() {
  local a b c
  for a in - _; do for b in - _; do for c in - _; do
    printf 'X%sPostal%sTrack%sHost\n' "$a" "$b" "$c"
  done; done; done
}
# expect_no_client_track <UI port>: no spelling of the tracking header, alone
# or next to the all-dash one, makes Postal answer as its tracking server on
# the login page (on the UI port) or the API (on websecure).
expect_no_client_track() {
  local name
  while IFS= read -r name; do
    login_page "$1" postal.test /login -H "$name: 1"
    login_page "$1" postal.test /login -H 'X-Postal-Track-Host: 1' -H "$name: 1"
    api_refused -H "$name: 1"
    api_refused -H 'X-Postal-Track-Host: 1' -H "$name: 1"
  done < <(track_spellings)
}

# postal_fixture: an organization (noix) with a mail server (test), the
# verified domain mail.example.test (Postal makes its DKIM key), an HTTP
# endpoint at the echo endpoint (start_echo) and a route to it that takes
# in@routes.mail.test (a route's token at the route domain; in@mail.example.test
# too), and an API credential; prints the credential's key. Made once,
# afterwards found again.
postal_fixture() {
  postal_rails '
user = User.order(:id).first or raise "Postal has no user"
org = Organization.find_by(permalink: "noix") || Organization.create!(name: "Noix", permalink: "noix", owner: user)
server = org.servers.find_by(permalink: "test") || org.servers.create!(name: "Test", permalink: "test", mode: "Live")
domain = server.domains.find_by(name: "mail.example.test") ||
         server.domains.create!(name: "mail.example.test", verification_method: "DNS")
domain.update!(verified_at: Time.now) unless domain.verified?
endpoint = server.http_endpoints.find_by(name: "echo") ||
           server.http_endpoints.create!(name: "echo", url: "http://127.0.0.1:8090/", encoding: "BodyAsJSON", format: "Hash")
server.routes.find_by(token: "in") ||
  server.routes.create!(name: "in", domain: domain, token: "in", mode: "Endpoint", endpoint: endpoint, spam_mode: "Mark")
credential = server.credentials.find_by(type: "API", name: "fixture") || server.credentials.create!(type: "API", name: "fixture")
puts credential.key' | tail -n 1
}
# postal_smtp_key: an SMTP credential of the fixture's mail server; prints its
# key (the password of SMTP AUTH).
postal_smtp_key() {
  postal_rails '
server = Organization.find_by!(permalink: "noix").servers.find_by!(permalink: "test")
credential = server.credentials.find_by(type: "SMTP", name: "fixture") || server.credentials.create!(type: "SMTP", name: "fixture")
puts credential.key' | tail -n 1
}
# track_domain <domain> <name> <ruby attributes>: the customer tracking
# domain <name>.<domain> of the fixture's mail server (made with the domain,
# marked verified, when missing), then its columns set as given (no callback
# or validation runs, so a test can mark the DNS check or write a name Postal
# would refuse; dns_checked_at now keeps Postal's own hourly check away);
# prints its full name. untrack_domain <domain>: removes the tracking domains
# of the domain.
track_domain() {
  postal_rails '
server = Organization.find_by!(permalink: "noix").servers.find_by!(permalink: "test")
domain = server.domains.find_by(name: "'"$1"'") || server.domains.create!(name: "'"$1"'", verification_method: "DNS")
domain.update!(verified_at: Time.now) unless domain.verified?
track = server.track_domains.find_by(domain: domain) || server.track_domains.create!(name: "'"$2"'", domain: domain)
track.update_columns('"$3"', dns_checked_at: Time.now)
track.reload
puts "#{track.name}.#{domain.name}"' | tail -n 1
}
untrack_domain() {
  postal_rails '
server = Organization.find_by!(permalink: "noix").servers.find_by!(permalink: "test")
domain = server.domains.find_by!(name: "'"$1"'")
puts TrackDomain.where(server: server, domain: domain).delete_all' | tail -n 1
}
# expect_compose_lacks <text>: the compose file does not hold the text.
expect_compose_lacks() {
  if h grep -qF -- "$1" "$app_dir/compose.yaml"; then fail "the compose file holds $1: $(h grep -nF -- "$1" "$app_dir/compose.yaml" | head -n 3)"; fi
}

# The echo endpoint (echo.py) on the test host's 127.0.0.1:8090, storing each
# POST body in /root/echo.
start_echo() {
  h systemctl is-active -q postal-echo && return 0
  h systemd-run --quiet --unit=postal-echo python3 /root/echo.py --dir /root/echo
}
# wait_echo <text>: waits for a body that holds the text and prints it.
wait_echo() {
  local file
  for _ in $(seq 90); do
    file="$(h sh -c 'grep -lF -- "$1" /root/echo/*.body 2>/dev/null | head -n 1' sh "$1" || true)"
    [ -n "$file" ] && { h cat "$file"; return 0; }
    sleep 2
  done
  fail "no request with $1 reached the echo endpoint; Postal's newest message: $(last_deliveries)"
}
# wait_mail <subject>: waits for a message with the subject in Mailpit and
# prints its raw text.
wait_mail() {
  local id
  for _ in $(seq 90); do
    id="$(h curl -s --max-time 30 --get --data-urlencode "query=subject:$1" http://127.0.0.1:8025/api/v1/search \
      | python3 -c 'import json, sys; found = json.load(sys.stdin)["messages"]; print(found[0]["ID"] if found else "")')"
    [ -n "$id" ] && { h curl -s --max-time 30 "http://127.0.0.1:8025/api/v1/message/$id/raw"; return 0; }
    sleep 2
  done
  fail "no message with the subject $1 reached Mailpit; Postal's newest message: $(last_deliveries)"
}
# The status and the delivery attempts of the newest message of the fixture's
# mail server.
last_deliveries() {
  postal_rails '
message = Organization.find_by!(permalink: "noix").servers.find_by!(permalink: "test")
  .message_db.messages(order: "id", direction: "desc", limit: 1).first
puts message ? "#{message.subject}: #{message.status}" : "none"
message&.deliveries&.each { |delivery| puts "#{delivery.status}: #{delivery.details} #{delivery.output}" }' || true
}
# The DNS name of the key of the message's DKIM-Signature,
# <s>._domainkey.<d> (empty without one): dkim_key_name <raw message on
# stdin>.
dkim_key_name() {
  python3 -c '
import email, re, sys
signature = " ".join(email.message_from_string(sys.stdin.read()).get("DKIM-Signature", "").split())
tags = dict(re.findall(r"(?:^|;)\s*([a-z]+)=([^;]*)", signature))
print(tags["s"].strip() + "._domainkey." + tags["d"].strip() if "s" in tags and "d" in tags else "")'
}
# smtp_send <port> <from> <to> <subject>: a message over SMTP from the test
# host; a key on stdin logs in first (AUTH PLAIN; Postal takes the key as the
# password and ignores the user name).
smtp_send() {
  hi python3 -c '
import smtplib, sys
from email.message import EmailMessage
port, sender, rcpt, subject = sys.argv[1:]
key = sys.stdin.read()
message = EmailMessage()
message["From"], message["To"], message["Subject"] = sender, rcpt, subject
message.set_content("A message of the postal suite.\n")
with smtplib.SMTP("127.0.0.1", int(port), timeout=120) as smtp:
    smtp.ehlo("client.example.test")
    if key:
        smtp.user, smtp.password = "noix", key
        smtp.auth("PLAIN", smtp.auth_plain)
    smtp.send_message(message)' "$@"
}

# Adds what the install generated, the Rails secret and a line of the private
# part of the signing key, to the secrets no output may hold.
note_generated() {
  local rails_secret key_line
  rails_secret="$(h sed -n 's/^  secret_key: *//p' "$app_dir/config/postal.yml" | tr -d "'\"")"
  key_line="$(h sed -n '12p' "$app_dir/config/signing.key")"
  [ "${#rails_secret}" = 128 ] || fail "postal.yml holds no generated Rails secret of 128 characters"
  [ "${#key_line}" -ge 32 ] || fail "signing.key has no line 12"
  secrets=("$db_password" "$admin_password" "$rspamd_password" "$oidc_secret" "$rails_secret" "$key_line")
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
    starts_before="$starts_before $service=$(started_at "$service")"
  done
}
# expect_restarted <services...>: these services started again since
# note_starts, and the others of web, smtp, submission, worker and mariadb did
# not.
expect_restarted() {
  local service before now
  for service in web smtp submission worker mariadb; do
    before="$(printf '%s\n' "$starts_before" | tr ' ' '\n' | sed -n "s/^$service=//p")"
    now="$(started_at "$service")"
    case " $* " in
      *" $service "*) [ "$now" != "$before" ] || fail "$service was not restarted" ;;
      *) [ "$now" = "$before" ] || fail "$service was restarted ($before, now $now)" ;;
    esac
  done
}

# start_pebble: Pebble running (see tls), its listener's CA where Traefik
# reads it. Its configuration is the image's with the one profile of 90 days:
# the image's also offers a short-lived one, and Traefik renews a certificate
# of 6 days whenever it restarts, which would race the role's copy.
start_pebble() {
  if [ -z "$(h docker ps -q --filter name=^pebble$)" ]; then
    h docker rm -f pebble >/dev/null 2>&1 || true
    hi sh -c 'cat >/root/pebble.json' <<'JSON'
{"pebble": {"listenAddress": "0.0.0.0:14000", "managementListenAddress": "0.0.0.0:15000",
            "certificate": "test/certs/localhost/cert.pem", "privateKey": "test/certs/localhost/key.pem",
            "httpPort": 5002, "tlsPort": 5001, "ocspResponderURL": "", "externalAccountBindingRequired": false,
            "retryAfter": {"authz": 1, "order": 1}, "keyAlgorithm": "ecdsa",
            "profiles": {"default": {"description": "90 days", "validityPeriod": 7776000}}}}
JSON
    h docker run -d --name pebble --network proxy --restart unless-stopped \
      -e PEBBLE_VA_ALWAYS_VALID=1 -e PEBBLE_VA_NOSLEEP=1 -e PEBBLE_WFE_NONCEREJECT=0 \
      -v /root/pebble.json:/pebble.json:ro "$pebble_image" -config /pebble.json >/dev/null
  fi
  h sh -c 'docker cp pebble:/test/certs/pebble.minica.pem /opt/traefik/acme/pebble.minica.pem && chmod 0644 /opt/traefik/acme/pebble.minica.pem'
}
# acme_has <name>: whether acme.json stores a certificate whose main domain
# is the name (yes or no). acme_cert <file> <name>: writes that certificate
# to the file on the test host.
acme_has() {
  h python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    data = {}
print("yes" if any(entry["domain"]["main"] == sys.argv[2] for body in data.values() if isinstance(body, dict)
                   for entry in body.get("Certificates") or []) else "no")' "$acme_file" "$1"
}
acme_cert() {
  h python3 -c '
import base64, json, sys
data = json.load(open(sys.argv[1]))
for body in data.values():
    for entry in (body or {}).get("Certificates") or []:
        if entry["domain"]["main"] == sys.argv[3]:
            open(sys.argv[2], "wb").write(base64.b64decode(entry["certificate"]))
            sys.exit(0)
sys.exit("acme.json has no certificate for " + sys.argv[3])' "$acme_file" "$1" "$2" || fail "acme.json has no certificate for $2"
}
# acme_add <resolver> <main> <sans, comma-separated> <dir>: stores the pair of
# the directory (make_pair) in acme.json as Traefik does, under the
# resolver. acme_drop <dir>: removes it again.
acme_add() {
  h python3 -c '
import base64, json, os, sys
path, resolver, main, sans, folder = sys.argv[1:]
data = json.load(open(path))
body = data.setdefault(resolver, {})
body["Certificates"] = body.get("Certificates") or []
read = lambda name: base64.b64encode(open(os.path.join(folder, name), "rb").read()).decode()
body["Certificates"].append({"domain": {"main": main, "sans": [name for name in sans.split(",") if name]},
                             "certificate": read("cert.pem"), "key": read("key.pem"), "Store": "default"})
with open(path + ".new", "w") as out:
    json.dump(data, out)
os.chmod(path + ".new", 0o600)
os.replace(path + ".new", path)' "$acme_file" "$@"
}
acme_drop() {
  h python3 -c '
import base64, json, os, sys
path, folder = sys.argv[1:]
cert = base64.b64encode(open(os.path.join(folder, "cert.pem"), "rb").read()).decode()
data = json.load(open(path))
for body in data.values():
    if isinstance(body, dict) and body.get("Certificates"):
        body["Certificates"] = [entry for entry in body["Certificates"] if entry.get("certificate") != cert]
with open(path + ".new", "w") as out:
    json.dump(data, out)
os.chmod(path + ".new", 0o600)
os.replace(path + ".new", path)' "$acme_file" "$1"
}
# make_pair <dir> <days> <name> [more names]: a self-signed certificate
# (P-256) for the names in <dir>/cert.pem and its key in <dir>/key.pem on the
# test host; a line of the key joins the secrets no output may hold.
make_pair() {
  h sh -c 'dir="$1" days="$2" name="$3"; shift 3; san="DNS:$name"; for more in "$@"; do san="$san,DNS:$more"; done
    rm -rf "$dir" && mkdir -p "$dir" && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -days "$days" -subj "/CN=$name" -addext "subjectAltName=$san" -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null' sh "$@"
  secrets+=("$(h sed -n 2p "$1/key.pem")")
}
# note_tls_key: a line of the key the role copied joins the secrets.
note_tls_key() {
  local line
  line="$(h sed -n 2p "$app_dir/config/smtp.key" 2>/dev/null)" || fail "the role wrote no $app_dir/config/smtp.key"
  secrets+=("$line")
}
# The SHA-256 fingerprint of a PEM certificate on the test host (the first of
# a chain), and of the one the SMTP service on a port shows after STARTTLS
# (empty while it does not answer): fingerprint <file>, served <port>.
fingerprint() { h openssl x509 -in "$1" -noout -fingerprint -sha256; }
served() {
  h sh -c 'openssl s_client -starttls smtp -connect "127.0.0.1:$1" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null' sh "$1" || true
}
# expect_served <file> <ports...>: STARTTLS on each port shows the
# certificate of the file (waiting while a restarted service starts).
expect_served() {
  local want port got
  want="$(fingerprint "$1")"
  for port in "${@:2}"; do
    for _ in $(seq 60); do
      got="$(served "$port")"
      [ "$got" = "$want" ] && break
      sleep 3
    done
    [ "$got" = "$want" ] || fail "STARTTLS on $port shows ${got:-no certificate}, not $1 ($want)"
  done
}
# expect_acme_served <name> <ports...>: STARTTLS on each port shows the
# certificate acme.json stores for the name now (Traefik renews Pebble's
# short-lived ones whenever it restarts).
expect_acme_served() {
  acme_cert "/root/acme-$1.pem" "$1"
  expect_served "/root/acme-$1.pem" "${@:2}"
}
# starttls <port>: yes or no, whether the SMTP service on the port offers
# STARTTLS after EHLO (waiting while it starts). expect_starttls <yes|no>
# <ports...>.
starttls() {
  h python3 -c '
import smtplib, sys, time
for _ in range(60):
    try:
        with smtplib.SMTP("127.0.0.1", int(sys.argv[1]), local_hostname="client.example.test", timeout=30) as smtp:
            smtp.ehlo()
            print("yes" if smtp.has_extn("starttls") else "no")
            break
    except OSError:
        time.sleep(3)
else:
    print("no answer")' "$1"
}
expect_starttls() {
  local port answer
  for port in "${@:2}"; do
    answer="$(starttls "$port")"
    [ "$answer" = "$1" ] || fail "port $port answers $answer to whether it offers STARTTLS, not $1"
  done
}
# note_events: from now on count_starts <service> counts how often the
# service's container started (Docker's start events);
# expect_started_once <services...>.
note_events() { events_since="$(h date +%s)"; }
count_starts() {
  h docker events --since "$events_since" --until "$(($(h date +%s) + 1))" --filter "container=$(container "$1")" \
    --filter event=start --format '{{.Action}}' | wc -l | tr -d ' '
}
expect_started_once() {
  local service count
  for service in "$@"; do
    count="$(count_starts "$service")"
    [ "$count" = 1 ] || fail "$service started $count times since note_events, not once"
  done
}
# timer_run: one run of the service the timer starts; prints what the
# script printed (updated or unchanged). Its journal must hold no secret.
timer_run() {
  local id answer
  h systemctl start postal-smtp-cert.service \
    || fail "postal-smtp-cert.service failed: $(h journalctl -u postal-smtp-cert.service -n 20 --no-pager -o cat)"
  id="$(h systemctl show --property=InvocationID --value postal-smtp-cert.service)"
  for _ in $(seq 10); do
    answer="$(h journalctl "_SYSTEMD_INVOCATION_ID=$id" -o cat --no-pager | grep -Ex 'updated|unchanged' | tail -n 1 || true)"
    [ -n "$answer" ] && break
    sleep 1
  done
  h journalctl -u postal-smtp-cert.service -o cat --no-pager >"$out/timer.log"
  expect_no_secrets "$out/timer.log" "the journal of postal-smtp-cert.service"
  printf '%s\n' "$answer"
}
# Removes the installation (its containers, files and data), for a scenario
# that installs afresh.
remove_installation() {
  h sh -c "cd $app_dir 2>/dev/null && docker compose down --remove-orphans" >/dev/null 2>&1 || true
  h rm -rf "$app_dir"
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
  # No such server: the check of the external MariaDB refuses it.
  refused 'could not log in to the external MariaDB db.example.test:3306' -e postal_database=mariadb_external -e postal_db_host=db.example.test
  refused 'postal_smtp_tls must be traefik, files or off' -e postal_smtp_tls=files
  refused 'value of postal_spam must be one of' -e postal_spam=spamd
  refused 'postal_rspamd_password must not hold' -e '{"postal_rspamd_password": "a$b"}'
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
  local key other_key other_secret threshold='{"postal_settings": {"default_spam_threshold": 7}}'
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

  # Keys that differ from the installation's are refused, never written; its
  # own keys given change nothing.
  echo "== reconfigure: other keys refused (ubuntu $1)"
  other_key="$(openssl genrsa 2048 2>/dev/null)"
  other_secret="$(openssl rand -hex 64)"
  secrets+=("$(printf '%s\n' "$other_key" | sed -n 12p)" "$other_secret")
  (
    umask 077
    env "KEY=$other_key" "SECRET=$other_secret" "OUT=$out" python3 -c '
import json, os
out = os.environ["OUT"]
json.dump({"postal_signing_key": os.environ["KEY"]}, open(os.path.join(out, "other-key-vars.json"), "w"))
json.dump({"postal_rails_secret_key": os.environ["SECRET"]}, open(os.path.join(out, "other-secret-vars.json"), "w"))'
  )
  note_untouched
  install_converge_fails -e "@$out/other-key-vars.json"
  expect_in_log "postal_signing_key differs from $app_dir/config/signing.key"
  expect_untouched
  install_converge_fails -e "@$out/other-secret-vars.json"
  expect_in_log "postal_rails_secret_key differs from rails.secret_key in $app_dir/config/postal.yml"
  expect_untouched
  write_takeover_vars
  install_converge_unchanged -e "@$out/takeover-vars.json"
}

# db_login <password>: whether Postal's user logs in to the own MariaDB with
# it, over TCP as Postal does; the password goes through stdin.
db_login() {
  printf '%s' "$1" | hi sh -c 'cd '"$app_dir"' && exec docker compose exec -T mariadb sh -c '"'"'MYSQL_PWD="$(cat; echo x)"; MYSQL_PWD="${MYSQL_PWD%x}"; export MYSQL_PWD; exec mariadb --host=127.0.0.1 --port=3307 --user=postal --execute="SELECT 1"'"'" >/dev/null 2>&1
}
root_user() { compose exec -T mariadb mariadb --user=root --batch --skip-column-names --execute="'SHOW CREATE USER root@localhost'"; }
# root_sql <sql>: runs the SQL as root in the own MariaDB and prints the
# result (batch, no column names).
root_sql() {
  h sh -c 'cd '"$app_dir"' && exec docker compose exec -T mariadb mariadb --user=root --batch --skip-column-names --execute="$1"' sh "$1"
}
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
# What is in app_dir and every file of the MariaDB data with its checksum
# (MariaDB is down), for expect_data_untouched.
data_state() { h sh -c "cd $app_dir && ls -A && find data/mariadb -type f -exec sha256sum {} + | sort"; }
note_data() { data_before="$(data_state)"; }
# Fails unless the refused run wrote nothing beside the data, started no
# container and left the data as it was.
expect_data_untouched() {
  grep -Eq 'changed=0 ' "$out/converge.log" || { cat "$out/converge.log" >&2; fail "the refused run changed something"; }
  [ -z "$(h docker ps -aq --filter label=com.docker.compose.project=postal)" ] || fail "the refused run made containers"
  [ "$(data_state)" = "$data_before" ] || fail "the refused run changed $app_dir or the MariaDB data"
}
# task_result <task name>: how the postal role's task of that name ended in
# the converge output (ok, changed, skipping, fatal; none when it did not
# show). expect_task <task name> <result>.
task_result() {
  python3 - "$out/converge.log" "$1" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
banner = "TASK [noixdev.infra.postal : " + sys.argv[2] + "]"
result = "none"
for i, line in enumerate(lines):
    if line.startswith(banner):
        for later in lines[i + 1:]:
            found = re.match(r"(ok|changed|skipping|fatal|failed):", later)
            if found or later.startswith("TASK ["):
                result = found.group(1) if found else result
                break
print(result)
PY
}
expect_task() {
  local got
  got="$(task_result "$1")"
  [ "$got" = "$2" ] || fail "the task \"$1\" ended $got, not $2"
}
# The public key of the installation's signing key, as its DKIM record has
# it (p=).
signing_pub() { h sh -c "openssl pkey -in $app_dir/config/signing.key -pubout | grep -v -- ----- | tr -d '\n'"; }
# write_takeover_vars: the keys of the installation in files of mode 0600
# (takeover-vars.json both, takeover-key-vars.json the signing key alone,
# takeover-secret-vars.json the Rails secret alone), for a takeover of its
# databases. note_generated made them secrets.
write_takeover_vars() {
  local key secret
  key="$(h cat "$app_dir/config/signing.key")"
  secret="$(h sed -n 's/^  secret_key: *//p' "$app_dir/config/postal.yml" | tr -d "'\"")"
  (
    umask 077
    env "KEY=$key" "SECRET=$secret" "OUT=$out" python3 -c '
import json, os
key, secret, out = os.environ["KEY"], os.environ["SECRET"], os.environ["OUT"]
for name, data in (("takeover-vars.json", {"postal_signing_key": key, "postal_rails_secret_key": secret}),
                   ("takeover-key-vars.json", {"postal_signing_key": key}),
                   ("takeover-secret-vars.json", {"postal_rails_secret_key": secret})):
    json.dump(data, open(os.path.join(out, name), "w"))'
  )
}
# make_dump <file> [main database] [prefix]: mariadb-dump --single-transaction
# --databases of the main database and every message database of the
# running own MariaDB, as root, into the file on the test host (gzip for
# .gz); never printed.
make_dump() {
  h sh -c 'set -e; cd '"$app_dir"'
    dbs="$(docker compose exec -T mariadb mariadb --user=root --batch --skip-column-names --execute="SHOW DATABASES LIKE '"'"'$3-%'"'"'")"
    docker compose exec -T mariadb mariadb-dump --user=root --single-transaction --databases "$2" $dbs >/root/dump.sql
    case "$1" in *.gz) gzip -c /root/dump.sql >"$1" && rm /root/dump.sql ;; *) mv /root/dump.sql "$1" ;; esac' \
    sh "$1" "${2:-postal}" "${3:-postal}" || fail "the dump $1 could not be made"
}
# The number of the fixture's messages with the subject.
messages_with() {
  postal_rails "puts $fixture_server.message_db.messages(where: { subject: \"$1\" }).size" | tail -n 1
}

test_takeover_refusals() {
  local key_sum vars
  echo "== takeover_refusals (ubuntu $1)"
  ensure_installed takeover_refusals
  write_takeover_vars
  make_dump /root/refusals.sql.gz
  key_sum="$(h sha256sum "$app_dir/config/signing.key" | cut -d' ' -f1)"

  # The MariaDB data of an installation without its files, without one key
  # or both: refused before any change, MariaDB not even started.
  set_files_aside
  note_data
  for vars in takeover-secret-vars.json takeover-key-vars.json db-vars.json; do
    echo "== takeover_refusals: the data without the keys ($vars, ubuntu $1)"
    install_converge_fails -e "@$out/$vars"
    expect_in_log "The own MariaDB in $app_dir/data/mariadb holds Postal's data"
    case "$vars" in
      takeover-secret-vars.json) expect_in_log 'and postal_signing_key is empty' ;;
      takeover-key-vars.json) expect_in_log 'and postal_rails_secret_key is empty' ;;
      *) expect_in_log 'and postal_signing_key and postal_rails_secret_key are empty' ;;
    esac
    expect_data_untouched
  done

  # A root with a password does not log in through the socket: with the keys
  # the install starts MariaDB, asks it and is refused, the files and
  # containers it made go again, and neither root nor the password of
  # Postal's user (the run had another) changed.
  echo "== takeover_refusals: a root with a password (ubuntu $1)"
  put_files_back
  root_sql "ALTER USER root@localhost IDENTIFIED BY 'noix-root-test'"
  set_files_aside
  install_converge_fails -e "@$out/takeover-vars.json" -e "@$out/new-db-vars.json"
  expect_in_log 'its root does not log in through the socket'
  expect_task "Create Postal's database user and its grants" none
  expect_task 'Initialize the database' none
  expect_task 'Upgrade the database' none
  local file
  for file in compose.yaml mariadb.cnf database-target install-incomplete; do
    h test ! -e "$app_dir/$file" || fail "the refused takeover left $app_dir/$file"
  done
  [ -z "$(h docker ps -aq --filter label=com.docker.compose.project=postal)" ] || fail "the refused takeover left containers"
  put_files_back
  [[ "$(compose exec -T -e MYSQL_PWD=noix-root-test mariadb mariadb --user=root --batch --skip-column-names \
        --execute="'SHOW CREATE USER root@localhost'")" == *PASSWORD* ]] || fail "the refused takeover changed root"
  db_login "$db_password" || fail "the refused takeover changed the password of Postal's database user"
  if db_login "${db_password}-new"; then fail "the refused takeover gave Postal's database user the new password"; fi
  compose exec -T -e MYSQL_PWD=noix-root-test mariadb mariadb --user=root \
    --execute="\"ALTER USER root@localhost IDENTIFIED VIA unix_socket\""
  [[ "$(root_user)" == *'IDENTIFIED VIA unix_socket'* ]] || fail "root is not back on the socket: $(root_user)"

  # A dump to load: without a key refused before any change, on a host
  # without the installation (nothing is created); and the dump that is no
  # file, a path that is no dump, and an external MariaDB.
  echo "== takeover_refusals: a dump without the keys (ubuntu $1)"
  compose down >/dev/null 2>&1
  h sh -c "rm -rf /root/postal-a && mv $app_dir /root/postal-a"
  refused 'and postal_signing_key is empty' -e "@$out/takeover-secret-vars.json" -e postal_import_dump=/root/refusals.sql.gz
  expect_in_log "The dump /root/refusals.sql.gz holds Postal's data"
  refused 'and postal_rails_secret_key is empty' -e "@$out/takeover-key-vars.json" -e postal_import_dump=/root/refusals.sql.gz
  refused 'postal_import_dump /root/missing.sql.gz is no file' -e "@$out/takeover-vars.json" -e postal_import_dump=/root/missing.sql.gz
  refused 'postal_import_dump must be an absolute path on the host ending in .sql or .sql.gz' -e postal_import_dump=/root/refusals.tar
  refused 'postal_import_dump must be an absolute path on the host ending in .sql or .sql.gz' -e postal_import_dump=refusals.sql
  refused 'postal_import_dump is set, but postal_database is mariadb_external' \
    -e "$ext_vars" -e "@$out/takeover-vars.json" -e postal_import_dump=/root/refusals.sql.gz

  # A dump to load into MariaDB data that holds Postal's databases: refused
  # before any change.
  echo "== takeover_refusals: a dump over Postal's databases (ubuntu $1)"
  h mv /root/postal-a "$app_dir"
  set_files_aside
  note_data
  install_converge_fails -e "@$out/takeover-vars.json" -e postal_import_dump=/root/refusals.sql.gz
  expect_in_log "postal_import_dump is set, but the own MariaDB in $app_dir/data/mariadb already holds postal"
  expect_data_untouched

  # With the keys the same data is taken over: postal upgrade, not
  # initialize, the signing key the one given, the admin alone.
  echo "== takeover_refusals: the data with the keys (ubuntu $1)"
  h rm -rf /root/aside
  install_converge -e "@$out/takeover-vars.json"
  expect_task 'Upgrade the database' changed
  expect_task 'Initialize the database' skipping
  expect_in_log 'The role took over the Postal databases there'
  install_converge_unchanged -e "@$out/takeover-vars.json"
  [ "$(h sha256sum "$app_dir/config/signing.key" | cut -d' ' -f1)" = "$key_sum" ] || fail "the takeover of the data changed signing.key"
  [ "$(postal_rails 'puts User.count')" = 1 ] || fail "the takeover of the data has not exactly the old admin"
}

test_takeover() {
  local key subject pub answer
  echo "== takeover (ubuntu $1)"
  ensure_installed takeover
  key="$(postal_fixture)" || fail "the fixture failed: $(tail -n 20 "$out/rails.log")"
  [ "${#key}" = 24 ] || fail "the fixture printed no API key: $(tail -n 20 "$out/rails.log")"
  secrets+=("$key")
  subject="noixold$(openssl rand -hex 4)"
  api_send "$key" "$subject"
  wait_mail "$subject" >/dev/null
  pub="$(signing_pub)"
  write_takeover_vars
  make_dump /root/takeover.sql.gz
  remove_installation

  # postal_dir wiped: the install loads the dump and takes it over, with
  # other postal_admin_* values, which make no second user.
  echo "== takeover: the dump (ubuntu $1)"
  postal_converge -e "@$out/takeover-vars.json" -e postal_import_dump=/root/takeover.sql.gz -e "@$out/other-admin-vars.json"
  expect_task 'Load the dump into the own MariaDB' changed
  expect_task 'Upgrade the database' changed
  expect_task 'Initialize the database' skipping
  expect_in_log 'The role took over the Postal databases there'
  expect_not_in_log 'The role generated'
  expect_in_log "v=DKIM1; t=s; h=sha256; p=$pub;"
  [ "$(signing_pub)" = "$pub" ] || fail "the takeover has another signing key"
  note_generated
  verify
  expect_clean
  # Loaded once: the next run, the dump still set, changes nothing.
  postal_converge_unchanged -e "@$out/takeover-vars.json" -e postal_import_dump=/root/takeover.sql.gz -e "@$out/other-admin-vars.json"
  expect_task 'Load the dump into the own MariaDB' none

  # The data of the old installation: its admin (alone), the organization,
  # the message; the admin logs in and the API sends.
  [ "$(postal_rails 'puts User.count')" = 1 ] || fail "the takeover has not exactly the old admin"
  [ "$(postal_rails 'puts Organization.where(permalink: "noix").count')" = 1 ] || fail "the takeover lacks the organization"
  [ "$(messages_with "$subject")" = 1 ] || fail "the takeover lacks the message $subject"
  [ "$(postal_fixture)" = "$key" ] || fail "the takeover lacks the fixture's API credential"
  answer="$(admin_login "$admin_email" "$admin_password")"
  [ "$(printf '%s\n' "$answer" | head -n 1)" = 302 ] || fail "the old admin's login was not redirected: $(printf '%s' "$answer" | head -c 300)"
  [[ "$answer" == *'Welcome to Postal, Noix'* ]] || fail "/ after the old admin's login is not Postal's: $(printf '%s' "$answer" | head -c 300)"
  subject="noixnew$(openssl rand -hex 4)"
  api_send "$key" "$subject"
  wait_mail "$subject" >/dev/null
  install_converge_unchanged
}

test_row_format() {
  local mdb tables
  echo "== row_format (ubuntu $1)"
  ensure_installed row_format
  postal_fixture >/dev/null || fail "the fixture failed: $(tail -n 20 "$out/rails.log")"
  mdb="$(root_sql "SHOW DATABASES LIKE 'postal-%'" | head -n 1)"
  [ -n "$mdb" ] || fail "the installation has no message database"
  # Small tables: the wide ones exceed COMPACT's row size, which is why
  # Postal v3 needs DYNAMIC.
  root_sql "ALTER TABLE postal.ip_pools ROW_FORMAT=COMPACT; ALTER TABLE \`$mdb\`.migrations ROW_FORMAT=COMPACT"
  write_takeover_vars
  make_dump /root/row-format.sql
  [ "$(h grep -c 'ROW_FORMAT=COMPACT' /root/row-format.sql)" = 2 ] || fail "the dump does not hold the two COMPACT tables"
  remove_installation

  # A plain .sql dump; the takeover converts both tables and names them.
  install_converge -e "@$out/takeover-vars.json" -e postal_import_dump=/root/row-format.sql
  expect_task 'Convert the tables to ROW_FORMAT=DYNAMIC' changed
  expect_in_log "Converted to ROW_FORMAT=DYNAMIC: postal.ip_pools, $mdb.migrations"
  tables="$(root_sql "SELECT CONCAT(table_schema, '.', table_name, ' ', row_format) FROM information_schema.tables
    WHERE (table_schema = 'postal' OR table_schema LIKE 'postal-%') AND table_type = 'BASE TABLE' AND row_format <> 'Dynamic'")"
  [ -z "$tables" ] || fail "tables are not Dynamic after the takeover: $tables"
  [ "$(root_sql "SELECT row_format FROM information_schema.tables WHERE table_schema = '$mdb' AND table_name = 'migrations'")" = Dynamic ] \
    || fail "$mdb.migrations is not Dynamic"
  note_generated
  verify
  install_converge_unchanged -e "@$out/takeover-vars.json" -e postal_import_dump=/root/row-format.sql
}

test_custom_names() {
  local names='{"postal_db_name": "mailer", "postal_message_db_prefix": "mailer"}' key databases subject
  echo "== custom_names (ubuntu $1)"
  remove_installation
  install_converge -e "$names"
  note_generated
  verify -e verify_db_name=mailer -e verify_db_prefix=mailer
  install_converge_unchanged -e "$names"
  key="$(postal_fixture)" || fail "the fixture failed: $(tail -n 20 "$out/rails.log")"
  [ "${#key}" = 24 ] || fail "the fixture printed no API key: $(tail -n 20 "$out/rails.log")"
  secrets+=("$key")
  databases="$(root_sql 'SHOW DATABASES' | grep -E '^(mailer|postal)' | sort | paste -sd' ' -)"
  [ "$databases" = 'mailer mailer-server-1' ] || fail "the installation has the databases $databases, not mailer and mailer-server-1"
  subject="noixmailer$(openssl rand -hex 4)"
  api_send "$key" "$subject"
  wait_mail "$subject" >/dev/null

  # Their dump, taken over with the names.
  echo "== custom_names: a takeover (ubuntu $1)"
  write_takeover_vars
  make_dump /root/mailer.sql.gz mailer mailer
  remove_installation
  install_converge -e "$names" -e "@$out/takeover-vars.json" -e postal_import_dump=/root/mailer.sql.gz
  expect_task 'Upgrade the database' changed
  verify -e verify_db_name=mailer -e verify_db_prefix=mailer
  install_converge_unchanged -e "$names" -e "@$out/takeover-vars.json" -e postal_import_dump=/root/mailer.sql.gz
  databases="$(root_sql 'SHOW DATABASES' | grep -E '^(mailer|postal)' | sort | paste -sd' ' -)"
  [ "$databases" = 'mailer mailer-server-1' ] || fail "the takeover has the databases $databases, not mailer and mailer-server-1"
  [ "$(messages_with "$subject")" = 1 ] || fail "the takeover lacks the message $subject"
  subject="noixmailernew$(openssl rand -hex 4)"
  api_send "$key" "$subject"
  wait_mail "$subject" >/dev/null
  # The other scenarios run on the default names.
  remove_installation
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

test_routers() {
  local answer
  echo "== routers (ubuntu $1)"
  ensure_installed routers

  # The defaults: every router on Traefik's default entrypoints (websecure),
  # without an entrypoints label.
  install_converge_unchanged
  if h grep -qF '.entrypoints=' "$app_dir/compose.yaml"; then fail "the compose file names entrypoints without postal_traefik_*entrypoints"; fi
  verify
  wait_answer 200 'name="email_address"' 443 postal.test /login
  api_refused
  expect_answer 200 '"keys"' 443 postal.test /.well-known/jwks.json
  tracking 443 track.mail.test /
  expect_no_client_track 443

  # The UI behind a middleware that denies everyone: on the same entrypoint
  # the API and tracking still answer.
  echo "== routers: the UI denied (ubuntu $1)"
  local deny='{"postal_traefik_ui_middlewares": ["deny@file"]}'
  install_converge -e "$deny"
  verify -e verify_ui_middlewares=deny@file
  wait_denied 443 postal.test /login
  expect_denied 443 postal.test /
  api_refused
  expect_answer 200 '"keys"' 443 postal.test /.well-known/jwks.json
  tracking 443 track.mail.test /
  install_converge_unchanged -e "$deny"

  # The split of the playbook: the API and tracking on websecure, the UI on
  # its own entrypoint (ui stands in for one on the tailnet), and one more
  # tracking host name. On websecure no router takes the UI's paths, so
  # Traefik answers with its own 404; on ui the login page answers, and the
  # admin logs in there.
  echo "== routers: the UI on its own entrypoint (ubuntu $1)"
  local split='{"postal_traefik_entrypoints": ["websecure"], "postal_traefik_ui_entrypoints": ["ui"], "postal_track_hostnames": ["click.example.test"]}'
  install_converge -e "$split"
  verify -e verify_entrypoints=websecure -e verify_ui_entrypoints=ui -e verify_track_hostnames=click.example.test
  wait_answer 200 'name="email_address"' 8443 postal.test /login
  expect_answer 404 '404 page not found' 443 postal.test /login
  expect_answer 404 '404 page not found' 443 postal.test /
  api_refused
  expect_answer 200 '"keys"' 443 postal.test /.well-known/jwks.json
  expect_answer 404 '404 page not found' 8443 postal.test /api/v1/send/message
  expect_no_client_track 8443
  expect_answer 404 '404 page not found' 8443 postal.test /api/v1/send/message -H 'X-Postal_Track-Host: 1'
  tracking 443 track.mail.test /
  tracking 443 click.example.test /
  # The tracking router sets the header whatever the client sends.
  tracking 443 track.mail.test / -H 'X-Postal-Track-Host: 0'
  expect_answer 404 '404 page not found' 8443 track.mail.test /
  answer="$(ui_login "$admin_email" "$admin_password")"
  [ "$(printf '%s\n' "$answer" | head -n 1)" = 302 ] || fail "the login on ui was not redirected: $(printf '%s' "$answer" | head -c 300)"
  [ "${answer##*$'\n'}" = 200 ] || fail "/ on ui after the login answered ${answer##*$'\n'}"
  [[ "$answer" == *'Welcome to Postal, Noix'* ]] || fail "/ on ui after the login is not Postal's start page: $(printf '%s' "$answer" | head -c 300)"
  install_converge_unchanged -e "$split"

  # Back to the defaults.
  install_converge
  verify
  wait_answer 200 'name="email_address"' 443 postal.test /login
  install_converge_unchanged
}

test_track_domains() {
  local key name
  local new_db="@$out/new-db-vars.json"
  local extra='{"postal_track_hostnames": ["extra.customer.test"]}'
  local listed='{"postal_track_hostnames": ["click.customer.test"]}'
  echo "== track_domains (ubuntu $1)"
  ensure_installed track_domains
  key="$(postal_fixture)" || fail "the fixture failed: $(tail -n 20 "$out/rails.log")"
  secrets+=("$key")

  # A customer tracking domain whose CNAME Postal has not verified
  # (dns_status NULL): no router names it, so Traefik asks no certificate for
  # it and answers it with its own 404.
  name="$(track_domain customer.test click 'dns_status: nil, ssl_enabled: true')" \
    || fail "the tracking domain failed: $(tail -n 20 "$out/rails.log")"
  [ "$name" = click.customer.test ] || fail "the tracking domain is $name, not click.customer.test"
  install_converge_unchanged
  expect_compose_lacks click.customer.test
  expect_compose_lacks postal-track-customers
  verify
  expect_answer 404 '404 page not found' 443 click.customer.test /

  # Postal marks its DNS OK: the next run routes it on a router of its own
  # with the HTTP-01 resolver, which recreates web alone, and the run after
  # that changes nothing.
  echo "== track_domains: a verified domain (ubuntu $1)"
  track_domain customer.test click 'dns_status: "OK"' >/dev/null
  note_starts
  install_converge
  grep -Eq 'changed=[1-9]' "$out/converge.log" || fail "the verified tracking domain changed nothing"
  expect_restarted web
  verify -e verify_track_customers=click.customer.test
  wait_answer 200 'Hello.' 443 click.customer.test /
  tracking 443 track.mail.test /
  install_converge_unchanged

  # Without SSL (Postal writes http:// links, which the web entrypoint of a
  # server redirects): routed all the same.
  track_domain customer.test click 'dns_status: "OK", ssl_enabled: false' >/dev/null
  install_converge_unchanged
  tracking 443 click.customer.test /

  # A name in the table that is no host name (Postal would refuse it; here it
  # is written past its validation) never reaches a rule: the run skips and
  # names it, and changes nothing.
  echo "== track_domains: a name that is no host name (ubuntu $1)"
  track_domain inject.customer.test x 'name: "x`) || Host(`evil.test", dns_status: "OK"' >/dev/null
  install_converge_unchanged
  expect_in_log 'are no host names, so no router names them'
  expect_compose_lacks evil.test
  verify -e verify_track_customers=click.customer.test
  [ "$(untrack_domain inject.customer.test)" = 1 ] || fail "the injected tracking domain was not removed"

  # The table cannot be read: the run keeps the domains the compose file
  # routes instead of dropping them. With MariaDB stopped, a run without
  # changes refuses and touches nothing (no reconfigure without them);
  # with a new postal_db_password (state.yml reads with it before the role
  # gives it to Postal's user) the reconfigure keeps them.
  echo "== track_domains: the database cannot be read (ubuntu $1)"
  compose stop mariadb >/dev/null 2>&1
  note_untouched
  install_converge_fails
  expect_in_log "the services mariadb are not running"
  expect_untouched
  compose up -d --wait mariadb >/dev/null 2>&1
  install_converge_unchanged
  role_converge -e "$new_db" -e "@$out/admin-vars.json"
  expect_in_log 'keeps the customer tracking domains of the compose file'
  verify -e verify_track_customers=click.customer.test
  wait_answer 200 'Hello.' 443 click.customer.test /
  role_converge_unchanged -e "$new_db" -e "@$out/admin-vars.json"
  install_converge
  install_converge_unchanged

  # postal_track_hostnames: on the tracking router with the entrypoint's
  # resolver, beside the customers' router; a verified domain listed there too
  # is on the tracking router alone.
  echo "== track_domains: postal_track_hostnames (ubuntu $1)"
  install_converge -e "$extra"
  verify -e verify_track_hostnames=extra.customer.test -e verify_track_customers=click.customer.test
  wait_answer 200 'Hello.' 443 extra.customer.test /
  tracking 443 click.customer.test /
  install_converge_unchanged -e "$extra"
  install_converge -e "$listed"
  verify -e verify_track_hostnames=click.customer.test
  wait_answer 200 'Hello.' 443 click.customer.test /
  install_converge_unchanged -e "$listed"

  # The domain removed in Postal: the next run drops its router.
  echo "== track_domains: a removed domain (ubuntu $1)"
  [ "$(untrack_domain customer.test)" = 1 ] || fail "the tracking domain was not removed"
  install_converge
  verify
  expect_compose_lacks click.customer.test
  for _ in $(seq 30); do
    [ "$(request 443 click.customer.test / | tail -n 1)" = 404 ] && break
    sleep 2
  done
  expect_answer 404 '404 page not found' 443 click.customer.test /
  install_converge_unchanged
  expect_clean
}

# verify with postal_smtp_tls traefik for smtp.example.test.
verify_tls() { verify -e verify_smtp_tls=traefik -e verify_smtp_hostname=smtp.example.test "$@"; }

test_smtp_tls() {
  local fresh same='{"postal_smtp_hostname": "postal.test"}'
  local nocert='{"postal_smtp_hostname": "nocert.example.test", "postal_health_timeout": 60}'
  echo "== smtp_tls (ubuntu $1)"
  start_pebble

  # A fresh install: unless an earlier run of the suite on this host got it,
  # Traefik has no certificate for smtp.example.test yet, so the run starts
  # web, whose router postal-smtp makes Traefik ask Pebble, and waits for it.
  remove_installation
  fresh="$(acme_has smtp.example.test)"
  install_converge -e "$tls"
  note_generated
  if [ "$fresh" = no ]; then
    [ "$(acme_has smtp.example.test)" = yes ] || fail "the install ended without Traefik's certificate for smtp.example.test"
  else
    echo "== smtp_tls: Traefik had the certificate before the install, which did not wait for it"
  fi
  note_tls_key
  verify_tls
  acme_cert /root/acme-smtp.example.test.pem smtp.example.test
  h cmp -s /root/acme-smtp.example.test.pem "$app_dir/config/smtp.cert" || fail "smtp.cert is not the certificate acme.json stores for smtp.example.test"
  h openssl x509 -in /root/acme-smtp.example.test.pem -noout -issuer | grep -q 'Pebble Intermediate' || fail "the certificate for smtp.example.test is not Pebble's"
  h openssl x509 -in /root/acme-smtp.example.test.pem -noout -text | grep -q 'DNS:smtp.example.test' || fail "the certificate does not name smtp.example.test"
  expect_starttls yes 25 587
  expect_served /root/acme-smtp.example.test.pem 25 587
  # The timer: twice a day at a random minute of the hour after; its service
  # with nothing new restarts nothing.
  h systemctl show --property=TimersCalendar --value postal-smtp-cert.timer | grep -qF 'OnCalendar=*-*-* 00,12:00:00' \
    || fail "the timer does not run at 00:00 and 12:00: $(h systemctl show --property=TimersCalendar --value postal-smtp-cert.timer)"
  [ "$(h systemctl show --property=RandomizedDelayUSec --value postal-smtp-cert.timer)" = 1h ] || fail "the timer has no random delay of 1h"
  note_starts
  [ "$(timer_run)" = unchanged ] || fail "the timer's service did not print unchanged"
  expect_restarted
  install_converge_unchanged -e "$tls"
  expect_clean

  # The SMTP host name is the web host name: no router of its own, the
  # certificate of the API's router.
  echo "== smtp_tls: the web host name (ubuntu $1)"
  install_converge -e "$tls" -e "$same"
  note_tls_key
  verify -e verify_smtp_tls=traefik
  expect_acme_served postal.test 25 587
  install_converge_unchanged -e "$tls" -e "$same"

  # Traefik cannot reach Pebble: no certificate for the new host name within
  # postal_health_timeout, and the run fails naming the host and acme.json.
  echo "== smtp_tls: no certificate (ubuntu $1)"
  h docker network disconnect proxy pebble
  install_converge_fails -e "$tls" -e "$nocert"
  h docker network connect proxy pebble
  expect_in_log 'Traefik stored no certificate for nocert.example.test in /opt/traefik/acme/acme.json within 60 seconds'
  install_converge -e "$tls"
  verify_tls
  expect_acme_served smtp.example.test 25 587
  install_converge_unchanged -e "$tls"

  # Off: no STARTTLS; the files, the script and the timer go.
  echo "== smtp_tls: off (ubuntu $1)"
  install_converge
  verify
  expect_starttls no 25 587
  install_converge_unchanged

  # On again: the certificate is there, postal.yml changes, and every Postal
  # service restarts, each SMTP service starting once.
  echo "== smtp_tls: on again (ubuntu $1)"
  note_starts
  note_events
  install_converge -e "$tls"
  expect_restarted web smtp submission worker
  expect_started_once smtp submission
  verify_tls
  expect_acme_served smtp.example.test 25 587
  install_converge_unchanged -e "$tls"

  install_converge
  verify
  install_converge_unchanged
  expect_clean
}

test_cert_rotation() {
  local threshold='{"postal_settings": {"default_spam_threshold": 7}}' nosub='{"postal_smtp_submission_port": 0}'
  echo "== cert_rotation (ubuntu $1)"
  start_pebble
  ensure_installed cert_rotation
  install_converge -e "$tls"
  note_tls_key
  install_converge_unchanged -e "$tls"
  expect_acme_served smtp.example.test 25 587

  # A certificate that expires after Pebble's, a wildcard under another
  # resolver: one run of the timer's service copies it and starts smtp and
  # submission once each; the next run changes nothing.
  make_pair /root/rotate1 400 '*.example.test'
  acme_add dns '*.example.test' '' /root/rotate1
  note_starts
  note_events
  [ "$(timer_run)" = updated ] || fail "the timer's service did not print updated for the new certificate"
  expect_restarted smtp submission
  expect_started_once smtp submission
  h cmp -s /root/rotate1/cert.pem "$app_dir/config/smtp.cert" || fail "smtp.cert is not the new certificate"
  h cmp -s /root/rotate1/key.pem "$app_dir/config/smtp.key" || fail "smtp.key is not the new key"
  verify_tls
  expect_served /root/rotate1/cert.pem 25 587
  h test ! -e "$app_dir/smtp-restart-pending" || fail "the timer's service left $app_dir/smtp-restart-pending"
  note_starts
  [ "$(timer_run)" = unchanged ] || fail "the second run of the timer's service did not print unchanged"
  expect_restarted
  install_converge_unchanged -e "$tls"

  # A newer certificate (a SAN of a certificate of a third resolver) and a
  # new setting in one run of the role: every Postal service restarts, each
  # SMTP service starting once, with the new certificate.
  echo "== cert_rotation: a new certificate and a new setting (ubuntu $1)"
  make_pair /root/rotate2 500 mx.example.test smtp.example.test
  acme_add tailnet mx.example.test smtp.example.test /root/rotate2
  note_starts
  note_events
  install_converge -e "$tls" -e "$threshold"
  expect_restarted web smtp submission worker
  expect_started_once smtp submission
  expect_served /root/rotate2/cert.pem 25 587
  install_converge_unchanged -e "$tls" -e "$threshold"

  # A restart the script could not do (its marker): the next run of the role
  # restarts the SMTP services alone, the next run of the script too.
  echo "== cert_rotation: a pending restart (ubuntu $1)"
  h touch "$app_dir/smtp-restart-pending"
  note_starts
  note_events
  install_converge -e "$tls" -e "$threshold"
  expect_restarted smtp submission
  expect_started_once smtp submission
  h test ! -e "$app_dir/smtp-restart-pending" || fail "the healthy run kept $app_dir/smtp-restart-pending"
  install_converge_unchanged -e "$tls" -e "$threshold"
  h touch "$app_dir/smtp-restart-pending"
  note_starts
  [ "$(timer_run)" = updated ] || fail "the timer's service did not print updated for a pending restart"
  expect_restarted smtp submission
  h test ! -e "$app_dir/smtp-restart-pending" || fail "the timer's service kept $app_dir/smtp-restart-pending"

  # Without the submission service the script restarts smtp alone.
  echo "== cert_rotation: no submission service (ubuntu $1)"
  install_converge -e "$tls" -e "$nosub"
  install_converge_unchanged -e "$tls" -e "$nosub"
  make_pair /root/rotate3 600 smtp.example.test
  acme_add http smtp.example.test '' /root/rotate3
  note_starts
  note_events
  [ "$(timer_run)" = updated ] || fail "the timer's service did not print updated without the submission service"
  expect_restarted smtp
  expect_started_once smtp
  expect_served /root/rotate3/cert.pem 25

  # Back to the defaults; the certificates written here go again.
  acme_drop /root/rotate1
  acme_drop /root/rotate2
  acme_drop /root/rotate3
  install_converge
  verify
  install_converge_unchanged
  expect_clean
}

test_smtp_files() {
  local files='{"postal_smtp_tls": "files", "postal_smtp_tls_cert": "/root/tls/cert.pem", "postal_smtp_tls_key": "/root/tls/key.pem"}'
  echo "== smtp_files (ubuntu $1)"
  ensure_installed smtp_files

  # A self-signed pair: copied, and every Postal service restarts for the
  # new postal.yml, each SMTP service starting once.
  make_pair /root/tls 30 smtp.example.test
  note_starts
  note_events
  install_converge -e "$files"
  expect_restarted web smtp submission worker
  expect_started_once smtp submission
  verify -e verify_smtp_tls=files
  h cmp -s /root/tls/cert.pem "$app_dir/config/smtp.cert" || fail "smtp.cert is not postal_smtp_tls_cert"
  h cmp -s /root/tls/key.pem "$app_dir/config/smtp.key" || fail "smtp.key is not postal_smtp_tls_key"
  expect_starttls yes 25 587
  expect_served /root/tls/cert.pem 25 587
  install_converge_unchanged -e "$files"

  # A new pair at the same paths: copied, smtp and submission start once,
  # nothing else restarts.
  echo "== smtp_files: a new pair (ubuntu $1)"
  make_pair /root/tls 60 smtp.example.test
  note_starts
  note_events
  install_converge -e "$files"
  expect_restarted smtp submission
  expect_started_once smtp submission
  expect_served /root/tls/cert.pem 25 587
  install_converge_unchanged -e "$files"

  # Refused before any change: a missing file, a key of another certificate.
  echo "== smtp_files: refusals (ubuntu $1)"
  make_pair /root/tls-other 30 smtp.example.test
  note_untouched
  install_converge_fails -e "$files" -e postal_smtp_tls_key=/root/tls/missing.pem
  expect_in_log 'postal_smtp_tls is files, but /root/tls/missing.pem is no file'
  expect_untouched
  install_converge_fails -e "$files" -e postal_smtp_tls_key=/root/tls-other/key.pem
  expect_in_log 'do not load as a certificate with its key'
  expect_untouched

  install_converge
  verify
  expect_starttls no 25 587
  install_converge_unchanged
  expect_clean
}

test_smtp_off() {
  local other='{"postal_smtp_hostname": "smtp.example.test"}'
  echo "== smtp_off (ubuntu $1)"
  ensure_installed smtp_off
  install_converge_unchanged
  verify
  expect_starttls no 25 587
  [ -z "$(served 25)" ] || fail "port 25 shows a certificate with postal_smtp_tls off"
  # Another SMTP host name: no router for it, so Traefik asks no certificate.
  install_converge -e "$other"
  verify -e verify_smtp_hostname=smtp.example.test
  expect_starttls no 25 587
  install_converge_unchanged -e "$other"
  install_converge
  install_converge_unchanged
}

test_mail() {
  local key smtp_key subject raw body
  echo "== mail (ubuntu $1)"
  ensure_installed mail
  start_echo
  key="$(postal_fixture)" || fail "the fixture failed: $(tail -n 20 "$out/rails.log")"
  [ "${#key}" = 24 ] || fail "the fixture printed no API key: $(tail -n 20 "$out/rails.log")"
  smtp_key="$(postal_smtp_key)" || fail "the SMTP credential failed: $(tail -n 20 "$out/rails.log")"
  [ "${#smtp_key}" = 24 ] || fail "no SMTP key: $(tail -n 20 "$out/rails.log")"
  secrets+=("$key" "$smtp_key")
  # Made once: a second call finds the same.
  [ "$(postal_fixture)" = "$key" ] || fail "a second postal_fixture made another API credential"

  # Through the API router with the key: relayed to Mailpit
  # (postal_smtp_relays, vars.yml) and signed. The domain's DNS is not
  # checked, so Postal signs with the signing key of the role, whose record
  # the install prints (postal._domainkey.rp.mail.test).
  echo "== mail: the API (ubuntu $1)"
  subject="noixapi$(openssl rand -hex 4)"
  api_send "$key" "$subject"
  raw="$(wait_mail "$subject")"
  [ "$(dkim_key_name <<<"$raw")" = postal._domainkey.rp.mail.test ] \
    || fail "the message from the API is not signed with postal._domainkey.rp.mail.test: $(printf '%s' "$raw" | head -c 600)"

  # Submitted on 587 with the SMTP credential.
  echo "== mail: submission (ubuntu $1)"
  subject="noixsub$(openssl rand -hex 4)"
  printf '%s' "$smtp_key" | smtp_send 587 test@mail.example.test someone@example.test "$subject" \
    || fail "the submission on 587 was refused"
  raw="$(wait_mail "$subject")"
  [ "$(dkim_key_name <<<"$raw")" = postal._domainkey.rp.mail.test ] \
    || fail "the submitted message is not signed with postal._domainkey.rp.mail.test: $(printf '%s' "$raw" | head -c 600)"

  # To the route on port 25, without a login: the worker posts it to the echo
  # endpoint on the test host's loopback, which
  # postal_allowed_request_destinations (vars.yml) lets it reach.
  echo "== mail: a route (ubuntu $1)"
  subject="noixroute$(openssl rand -hex 4)"
  smtp_send 25 sender@example.test in@routes.mail.test "$subject" </dev/null || fail "port 25 refused the message to in@routes.mail.test"
  body="$(wait_echo "$subject")"
  [[ "$body" == *'"rcpt_to":"in@mail.example.test"'* ]] || fail "the echo endpoint got no message for the route: $(printf '%s' "$body" | head -c 300)"
  expect_clean
}

# api_send <key> <subject>: a message from test@mail.example.test to
# someone@example.test through the API router with the key; fails unless the
# API takes it.
api_send() {
  local body
  body="$(request 443 postal.test /api/v1/send/message -X POST -H 'Content-Type: application/json' -H "X-Server-API-Key: $1" \
    --data '{"to": ["someone@example.test"], "from": "test@mail.example.test", "subject": "'"$2"'", "plain_body": "A message of the postal suite."}')"
  [[ "$body" == *'"status":"success"'* ]] || fail "the API did not take the message $2: $(printf '%s' "$body" | head -c 300)"
}
# The fixture's mail server, in Ruby (postal_rails).
fixture_server='Organization.find_by!(permalink: "noix").servers.find_by!(permalink: "test")'
# inspection <subject>: how Postal inspected the fixture's newest message with
# the subject: "inspected=<true|false> threat=<true|false> details=<ClamAV's
# verdict> checks=<the codes of its spam checks, comma-separated>", or none.
inspection() {
  postal_rails '
message = '"$fixture_server"'.message_db.messages(where: { subject: "'"$1"'" }, order: "id", direction: "desc", limit: 1).first
if message
  flag = ->(value) { [true, 1].include?(value) }
  codes = message.spam_checks.map { |check| check["code"] || check[:code] }.join(",")
  puts "inspected=#{flag.(message.inspected)} threat=#{flag.(message.threat)} details=#{message.threat_details} checks=#{codes}"
else
  puts "none"
end' | tail -n 1
}
# expect_inspection <subject> <threat: true|false> <text of ClamAV's
# verdict>: the message was inspected, ClamAV gave that verdict (any case), and
# rspamd gave it checks (not Postal's ERROR of a failed request).
expect_inspection() {
  local answer checks
  answer="$(inspection "$1")"
  checks="${answer##*checks=}"
  { [[ "$answer" == "inspected=true threat=$2 details="* ]] && printf '%s\n' "${answer%% checks=*}" | grep -qiF -- "$3"; } \
    || fail "$1 was not inspected with the threat $2 and ClamAV's \"$3\": $answer"
  { [ -n "$checks" ] && [[ ",$checks," != *,ERROR,* ]]; } || fail "rspamd did not check $1 (its checks: ${checks:-none})"
}
# smtp_send_eicar <subject>: a message with the EICAR test file as an
# attachment to the route on port 25 (the test string is put together here,
# so that no file of the repository holds it).
smtp_send_eicar() {
  h python3 -c '
import smtplib, sys
from email.message import EmailMessage
eicar = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$" + "EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
message = EmailMessage()
message["From"], message["To"], message["Subject"] = "sender@example.test", "in@routes.mail.test", sys.argv[1]
message.set_content("A message of the postal suite with a test file.\n")
message.add_attachment(eicar.encode(), maintype="application", subtype="octet-stream", filename="eicar.com")
with smtplib.SMTP("127.0.0.1", 25, timeout=120) as smtp:
    smtp.ehlo("client.example.test")
    smtp.send_message(message)' "$1"
}
# The containers of a service of the project (all replicas), running or not.
service_containers() {
  h docker ps -aq --filter label=com.docker.compose.project=postal --filter "label=com.docker.compose.service=$1"
}
# expect_loopback_only <port>: something listens on 127.0.0.1:<port> of the
# test host, and on no other address of it.
expect_loopback_only() {
  local listening
  listening="$(h ss -ltnH "sport = :$1" | awk '{ print $4 }' | sort -u | paste -sd' ' -)"
  [ "$listening" = "127.0.0.1:$1" ] || fail "port $1 listens on ${listening:-nothing}, not on 127.0.0.1 alone"
}

# ClamAV's signatures, downloaded once into this directory on this machine by
# freshclam in the pinned image (brought up to date on every call: a small
# download) and copied into the data directory of the test host before
# ClamAV first starts there, so that no test host downloads the full
# database. Its first start sees main.cvd and skips its own download.
clamav_db="$out/clamav-db"
clamav_signatures() {
  local image
  image="$(sed -n 's/^postal_clamav_image: *//p' "$root/roles/postal/defaults/main.yml")"
  mkdir -p "$clamav_db"
  docker run --rm -v "$clamav_db:/var/lib/clamav" --entrypoint sh "$image" -c '
chown -R clamav:clamav /var/lib/clamav
sed -e "s|^\(TestDatabases \)|#\1|" -e "\$a TestDatabases no" -e "s|^\(NotifyClamd \)|#\1|" \
  /etc/clamav/freshclam.conf >/tmp/freshclam.conf
freshclam --foreground --stdout --config-file=/tmp/freshclam.conf' >"$out/freshclam.log" 2>&1 || true
  [ -s "$clamav_db/main.cvd" ] || fail "freshclam downloaded no main.cvd: $(tail -n 5 "$out/freshclam.log")"
  h mkdir -p "$app_dir/data/clamav"
  docker cp "$clamav_db/." "$host:$app_dir/data/clamav/" >/dev/null
}
# clamav_ping: what ClamAV answers on 127.0.0.1:3310 to zPING.
clamav_ping() {
  h python3 -c '
import socket
with socket.create_connection(("127.0.0.1", 3310), timeout=30) as sock:
    sock.sendall(b"zPING\0")
    print(sock.recv(64).rstrip(b"\0\n").decode())'
}

test_spam() {
  local key subject answer spam='{"postal_spam": "rspamd", "postal_clamav": true}'
  echo "== spam (ubuntu $1)"
  ensure_installed spam
  start_echo
  key="$(postal_fixture)" || fail "the fixture failed: $(tail -n 20 "$out/rails.log")"
  [ "${#key}" = 24 ] || fail "the fixture printed no API key: $(tail -n 20 "$out/rails.log")"
  secrets+=("$key")
  # Postal inspects outgoing mail only for a mail server with an outbound spam
  # threshold (high, so that nothing is held).
  postal_rails "$fixture_server"'.update_column(:outbound_spam_threshold, 50)' >/dev/null

  # rspamd without a password and ClamAV: both on 127.0.0.1 alone, ClamAV
  # answers, and so does rspamd's controller to a client of the host.
  clamav_signatures
  install_converge -e "$spam"
  verify -e verify_spam=rspamd -e verify_clamav=true
  install_converge_unchanged -e "$spam"
  expect_clean
  expect_loopback_only 11334
  expect_loopback_only 3310
  [ "$(clamav_ping)" = PONG ] || fail "ClamAV does not answer PING with PONG"
  answer="$(h curl -s -o /dev/null -w '%{http_code}' --max-time 30 --data-binary 'Subject: noix' http://127.0.0.1:11334/checkv2)"
  [ "$answer" = 200 ] || fail "rspamd's controller without a password answered $answer to a client of the host, not 200"

  # Through the API: rspamd's checks and ClamAV's clean verdict.
  echo "== spam: a message through the API (ubuntu $1)"
  subject="noixspam$(openssl rand -hex 4)"
  api_send "$key" "$subject"
  wait_mail "$subject" >/dev/null
  expect_inspection "$subject" false 'No threats found'

  # The EICAR test file to the route on port 25: a threat.
  echo "== spam: the EICAR test file (ubuntu $1)"
  subject="noixeicar$(openssl rand -hex 4)"
  smtp_send_eicar "$subject" || fail "port 25 refused the message with the EICAR test file"
  wait_echo "$subject" >/dev/null
  expect_inspection "$subject" true eicar

  # With a password: the controller refuses a client without it, and Postal,
  # which sends it, still gets its checks.
  echo "== spam: rspamd's password (ubuntu $1)"
  install_converge -e "$spam" -e "@$out/rspamd-vars.json"
  verify -e verify_spam=rspamd -e verify_clamav=true -e verify_rspamd_password=true
  install_converge_unchanged -e "$spam" -e "@$out/rspamd-vars.json"
  expect_clean
  answer="$(h curl -s -o /dev/null -w '%{http_code}' --max-time 30 --data-binary 'Subject: noix' http://127.0.0.1:11334/checkv2)"
  [ "$answer" = 401 ] || fail "rspamd's controller with a password answered $answer to a client without it, not 401"
  subject="noixspampw$(openssl rand -hex 4)"
  api_send "$key" "$subject"
  wait_mail "$subject" >/dev/null
  expect_inspection "$subject" false 'No threats found'

  # Off again: both services go.
  echo "== spam: off again (ubuntu $1)"
  install_converge
  [ -z "$(service_containers rspamd)$(service_containers clamav)" ] || fail "rspamd or ClamAV is left with postal_spam none and postal_clamav false"
  verify
  install_converge_unchanged
  postal_rails "$fixture_server"'.update_column(:outbound_spam_threshold, nil)' >/dev/null
}

# start_gelf: a UDP listener on the test host's 127.0.0.1:12201 that writes
# every GELF message it gets (zlib, gzip or plain JSON; chunks are skipped)
# as a line into /root/gelf.log. stop_gelf stops it.
start_gelf() {
  h rm -f /root/gelf.log
  h systemctl is-active -q postal-gelf && return 0
  h systemd-run --quiet --unit=postal-gelf python3 -c '
import gzip, socket, zlib
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 12201))
while True:
    data = sock.recv(65535)
    for decode in (zlib.decompress, gzip.decompress, lambda raw: raw):
        try:
            text = decode(data).decode()
            break
        except Exception:
            continue
    else:
        continue
    with open("/root/gelf.log", "a") as log:
        log.write(" ".join(text.split()) + "\n")'
}
stop_gelf() { h systemctl stop postal-gelf >/dev/null 2>&1 || true; }
# wait_gelf <text>: waits for a GELF message that holds the text.
wait_gelf() {
  for _ in $(seq 90); do
    h grep -qF -- "$1" /root/gelf.log 2>/dev/null && return 0
    sleep 2
  done
  fail "no GELF message with $1 reached the listener: $(h tail -n 3 /root/gelf.log 2>/dev/null | cut -c1-200)"
}

test_oidc_gelf() {
  local key subject settings
  settings='{"postal_gelf": {"host": "127.0.0.1", "port": 12201, "facility": "noixtest"}, "postal_use_ip_pools": true,
    "postal_worker_replicas": 2, "postal_smtp_relays": ["smtp://localhost:1025?ssl_mode=None"]}'
  echo "== oidc_gelf (ubuntu $1)"
  ensure_installed oidc_gelf
  key="$(postal_fixture)" || fail "the fixture failed: $(tail -n 20 "$out/rails.log")"
  [ "${#key}" = 24 ] || fail "the fixture printed no API key: $(tail -n 20 "$out/rails.log")"
  secrets+=("$key")
  start_gelf

  install_converge -e "$settings" -e "@$out/oidc-vars.json"
  verify -e '{"verify_workers": 2, "verify_ip_pools": true, "verify_relays": "smtp://localhost:1025?ssl_mode=None",
    "verify_oidc_name": "Noix ID", "verify_gelf_host": "127.0.0.1", "verify_gelf_facility": "noixtest"}'
  install_converge_unchanged -e "$settings" -e "@$out/oidc-vars.json"
  expect_clean
  [ "$(service_containers worker | wc -l | tr -d ' ')" = 2 ] || fail "the project does not have two workers"
  # The login page offers the provider, and the local login stays.
  expect_answer 200 'Login with Noix ID' 443 postal.test /login
  login_page 443 postal.test /login

  # A message through the API reaches Mailpit over the relay with its
  # ssl_mode, and the worker's log reaches the GELF listener.
  subject="noixgelf$(openssl rand -hex 4)"
  api_send "$key" "$subject"
  wait_mail "$subject" >/dev/null
  wait_gelf noixtest
  h cat /root/gelf.log >"$out/gelf.log"
  expect_no_secrets "$out/gelf.log" "the GELF messages"
  stop_gelf

  install_converge
  verify
  install_converge_unchanged
}

# The external MariaDB servers of install_external, on the Traefik network
# of the test host: start_db <name> <image> <alias> [docker run options...]
# (root logs in through the socket only); db_sql <name> runs the SQL of stdin
# as root there, the password of the run SQL-quoted in sql_password.
ext_vars='{"postal_database": "mariadb_external", "postal_db_host": "db.example.test", "postal_db_port": 3306}'
start_db() {
  local name="$1" image="$2" alias="$3" env
  case "$image" in
    mysql:*) env=(-e MYSQL_ALLOW_EMPTY_PASSWORD=yes -e MYSQL_ROOT_HOST=localhost) ;;
    *) env=(-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_ROOT_HOST=localhost) ;;
  esac
  h docker rm -f -v "$name" >/dev/null 2>&1 || true
  h docker run -d --name "$name" --network proxy --network-alias "$alias" "${env[@]}" "${@:4}" "$image" >/dev/null
  # The server the entrypoint starts last (its first one has no port).
  for _ in $(seq 150); do
    h sh -c 'docker logs "$1" 2>&1 | grep -q "socket: .* port: 3306"' sh "$name" && return 0
    sleep 2
  done
  fail "$image ($name) did not start: $(h docker logs --tail 20 "$name" 2>&1)"
}
db_sql() {
  local client=mariadb
  case "$(h docker inspect --format '{{.Config.Image}}' "$1")" in mysql:*) client=mysql ;; esac
  hi docker exec -i "$1" "$client" --user=root --batch --skip-column-names
}
# db_postal_user <name> <user> <database patterns...>: the user with the
# password of the run and all privileges on each pattern (the GRANTs of the
# docs).
db_postal_user() {
  local name="$1" user="$2" sql_password pattern
  sql_password="$(printf '%s' "$db_password" | sed "s/'/''/g")"
  {
    printf "CREATE USER '%s'@'%%' IDENTIFIED BY '%s';\n" "$user" "$sql_password"
    for pattern in "${@:3}"; do
      printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\n" "$pattern" "$user"
    done
  } | db_sql "$name" >/dev/null || fail "the user $user could not be made on $name"
}

test_install_external() {
  local key subject databases pub
  echo "== install_external (ubuntu $1)"
  remove_installation
  start_db noix-db mariadb:11.4 db.example.test -p 127.0.0.1:3306:3306
  start_db noix-mysql mysql:8.4 mysql.example.test
  start_db noix-old mariadb:10.5 old.example.test
  db_postal_user noix-db postal postal 'postal-%'
  db_postal_user noix-db nomsg postal
  db_postal_user noix-mysql postal postal 'postal-%'
  db_postal_user noix-old postal postal 'postal-%'
  # Postal's services on the host's network reach the server at its port on
  # the test host's loopback, web and the role's client on the Traefik
  # network.
  h sh -c 'grep -q " db.example.test$" /etc/hosts || echo "127.0.0.1 db.example.test" >>/etc/hosts'

  # Refused before any change: nothing on the host afterwards.
  echo "== install_external: refusals (ubuntu $1)"
  refused 'could not log in to the external MariaDB db.example.test:3306 as postal' -e "$ext_vars" -e "@$out/new-db-vars.json"
  expect_in_log 'Access denied for user'
  refused 'mysql.example.test:3306 is not MariaDB' -e "$ext_vars" -e postal_db_host=mysql.example.test
  refused 'lacks ALL PRIVILEGES on postal-noixcheck' -e "$ext_vars" -e postal_db_user=nomsg
  refused 'old.example.test:3306 is MariaDB 10.5' -e "$ext_vars" -e postal_db_host=old.example.test

  # The install: no mariadb service, no data of it, Postal's databases on the
  # external server.
  echo "== install_external: install (ubuntu $1)"
  install_converge -e "$ext_vars"
  [ -z "$(service_containers mariadb)" ] || fail "the external install has a mariadb service"
  h test ! -e "$app_dir/data/mariadb" || fail "the external install made $app_dir/data/mariadb"
  note_generated
  verify -e verify_database=mariadb_external -e verify_db_host=db.example.test -e verify_db_port=3306
  expect_clean
  install_converge_unchanged -e "$ext_vars"
  [ "$(postal_rails 'puts User.count')" = 1 ] || fail "the external install has no admin"

  # The fixture and a message through the API.
  echo "== install_external: a message through the API (ubuntu $1)"
  key="$(postal_fixture)" || fail "the fixture failed: $(tail -n 20 "$out/rails.log")"
  [ "${#key}" = 24 ] || fail "the fixture printed no API key: $(tail -n 20 "$out/rails.log")"
  secrets+=("$key")
  subject="noixext$(openssl rand -hex 4)"
  api_send "$key" "$subject"
  wait_mail "$subject" >/dev/null
  databases="$(printf "SHOW DATABASES LIKE 'postal%%';\n" | db_sql noix-db | sort | paste -sd' ' -)"
  [[ "$databases" == 'postal postal-'* ]] || fail "the external server holds the databases $databases, not postal and a message database"
  install_converge_unchanged -e "$ext_vars"

  # Refused without a change on the installation.
  echo "== install_external: refusals of the installation (ubuntu $1)"
  note_untouched
  install_converge_fails -e "$ext_vars" -e "@$out/new-db-vars.json"
  expect_in_log 'could not log in to the external MariaDB db.example.test:3306 as postal'
  expect_untouched
  install_converge_fails -e "$ext_vars" -e postal_db_user=nomsg
  expect_in_log 'lacks ALL PRIVILEGES on postal-noixcheck'
  expect_untouched
  install_converge_fails
  expect_in_log 'postal_database mariadb was set, but the installation in /opt/postal was made with the database mariadb_external'
  expect_untouched
  install_converge_fails -e "$ext_vars" -e postal_db_host=other.example.test
  expect_in_log 'The settings name the external database server other.example.test:3306'
  expect_in_log 'was made with the server db.example.test:3306'
  expect_untouched
  install_converge_unchanged -e "$ext_vars"

  # A fresh install on the server that holds Postal's schema is a takeover:
  # without the keys refused before any change, with those of the
  # installation it runs postal upgrade and keeps the data.
  echo "== install_external: a takeover (ubuntu $1)"
  pub="$(signing_pub)"
  write_takeover_vars
  remove_installation
  refused "The external MariaDB db.example.test:3306 holds Postal's data" -e "$ext_vars"
  expect_in_log 'and postal_signing_key and postal_rails_secret_key are empty'
  refused 'and postal_rails_secret_key is empty' -e "$ext_vars" -e "@$out/takeover-key-vars.json"
  install_converge -e "$ext_vars" -e "@$out/takeover-vars.json"
  expect_task 'Upgrade the database' changed
  expect_task 'Initialize the database' skipping
  expect_in_log "v=DKIM1; t=s; h=sha256; p=$pub;"
  note_generated
  verify -e verify_database=mariadb_external -e verify_db_host=db.example.test -e verify_db_port=3306
  install_converge_unchanged -e "$ext_vars" -e "@$out/takeover-vars.json"
  [ "$(postal_rails 'puts User.count')" = 1 ] || fail "the external takeover has not exactly the old admin"
  [ "$(postal_fixture)" = "$key" ] || fail "the external takeover lacks the fixture's API credential"
  [ "$(messages_with "$subject")" = 1 ] || fail "the external takeover lacks the message $subject"
  subject="noixexttakeover$(openssl rand -hex 4)"
  api_send "$key" "$subject"
  wait_mail "$subject" >/dev/null
  remove_installation

  h docker rm -f -v noix-db noix-mysql noix-old >/dev/null
  # /etc/hosts is a bind mount of the test host: rewritten in place.
  h sh -c 'grep -v " db.example.test$" /etc/hosts >/root/hosts.new; cat /root/hosts.new >/etc/hosts; rm /root/hosts.new'
}

# The update scenarios: from old_version, installed with the fixture and a
# message, to new_version (the role's default) and to versions of test_repo
# tagged on the test host. Each ends without an installation, as the others
# would take it for theirs.
old_version=3.4.0
new_version=3.5.0
next_version=3.5.1
postal_repo=ghcr.io/postalserver/postal
test_repo=test.invalid/postal
backups="$app_dir/data/backups"
marker="$app_dir/update-failed"
progress="$app_dir/update-in-progress"
busybox=busybox:1.37.0

# The names of the complete backups, oldest first.
complete_backups() {
  h sh -c "ls -1 $backups 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z-[0-9.]+-to-[0-9.]+\$' || true"
}
# The image web runs.
web_image() { h docker inspect --format '{{.Config.Image}}' "$(container web)"; }
# ensure_old_installed <scenario>: a fresh installation of old_version with
# the fixture (fixture_key) and a message through the API (old_subject).
ensure_old_installed() {
  remove_installation
  echo "== install of $old_version for $1"
  install_converge -e "postal_version=$old_version"
  note_generated
  fixture_key="$(postal_fixture)" || fail "the fixture failed: $(tail -n 20 "$out/rails.log")"
  secrets+=("$fixture_key")
  old_subject="noixupd$(openssl rand -hex 4)"
  api_send "$fixture_key" "$old_subject"
  wait_mail "$old_subject" >/dev/null
}
# expect_data <what>: the admin, the fixture's server and the message are
# there.
expect_data() {
  [ "$(postal_rails 'puts User.count')" = 1 ] || fail "$1: Postal has not exactly the admin"
  [ "$(postal_rails 'puts Server.count')" = 1 ] || fail "$1: the fixture's server is gone"
  [ "$(messages_with "$old_subject")" = 1 ] || fail "$1: the message $old_subject is gone"
}
# expect_backup <dir>: the compose file, the configuration and the databases
# (one complete dump of the main and of the message database, with
# postal.yml and signing.key) of a backup, all root's.
expect_backup() {
  local file
  [ "$(h stat -c '%a %U' "$1")" = '700 root' ] || fail "the backup $1 is not root's with mode 0700"
  for file in compose.yaml config/postal.yml config/signing.key databases/postal.yml databases/signing.key; do
    h test -s "$1/$file" || fail "the backup $1 lacks $file"
  done
  [ "$(h sh -c "cd $1/databases && ls *.sql")" = "$(printf 'postal-server-1.sql\npostal.sql')" ] \
    || fail "the backup $1 has not one dump per database: $(h ls "$1/databases")"
  for file in postal.sql postal-server-1.sql; do
    h sh -c "tail -n 1 $1/databases/$file | grep -q '^-- Dump completed'" || fail "the dump $file of $1 is not complete"
  done
}

test_update() {
  local backup
  echo "== update (ubuntu $1)"
  ensure_old_installed update
  install_converge
  expect_task "Migrate the databases to Postal $new_version" changed
  [ "$(web_image)" = "$postal_repo:$new_version" ] || fail "web runs $(web_image) after the update"
  backup="$backups/$(complete_backups | tail -n 1)"
  [[ "$backup" == *"-$old_version-to-$new_version" ]] || fail "no backup of the update: $(complete_backups)"
  expect_backup "$backup"
  h test ! -e "$progress" || fail "the update left $progress"
  expect_data "after the update"
  api_send "$fixture_key" "noixnew$(openssl rand -hex 4)"
  install_converge_unchanged

  # Postal cannot migrate its databases down.
  echo "== update: a downgrade (ubuntu $1)"
  note_untouched
  install_converge_fails -e "postal_version=$old_version"
  expect_in_log "postal_version $old_version is lower than the installed version $new_version"
  expect_untouched

  # The newest postal_backups_keep stay.
  echo "== update: pruning (ubuntu $1)"
  h docker tag "$postal_repo:$new_version" "$test_repo:$next_version"
  install_converge -e "postal_image=$test_repo" -e "postal_version=$next_version" -e postal_backups_keep=1
  h test ! -e "$backup" || fail "the older backup $backup was not pruned"
  [ "$(complete_backups | wc -l | tr -d ' ')" = 1 ] || fail "postal_backups_keep 1 kept more: $(complete_backups)"
  complete_backups | grep -q -- "-$new_version-to-$next_version\$" || fail "the newest backup is not the one kept: $(complete_backups)"
  expect_data "after the second update"
  remove_installation
  h docker rmi "$test_repo:$next_version" >/dev/null
}

# expect_rolled_back <what>: the run failed with the rollback, old_version
# runs healthy with the data, update-failed names the version.
expect_rolled_back() {
  expect_in_log "and was rolled back: Postal $old_version runs again, healthy"
  [ "$(web_image)" = "$postal_repo:$old_version" ] || fail "$1: web runs $(web_image) after the rollback"
  h grep -q "^failed_version: $2\$" "$marker" || fail "$1: $marker does not name $2: $(h cat "$marker" 2>&1)"
  h grep -q "^rolled_back_to: $old_version\$" "$marker" || fail "$1: $marker does not record the rollback"
  h test ! -e "$progress" || fail "$1: the rollback left $progress"
  expect_data "$1"
}

test_failed_update() {
  echo "== failed_update (ubuntu $1): an image that exits"
  ensure_old_installed failed_update
  h docker pull -q --platform linux/amd64 "$busybox" >/dev/null
  h docker tag "$busybox" "$test_repo:$new_version"
  install_converge_fails -e "postal_image=$test_repo" -e postal_health_timeout=60
  expect_rolled_back "an image that exits" "$new_version"

  # The failed version is refused until another is pinned, which removes
  # the marker.
  echo "== failed_update: the failed version refused (ubuntu $1)"
  note_untouched
  install_converge_fails -e "postal_image=$test_repo"
  expect_in_log "$marker exists: the Postal update to $new_version failed"
  expect_in_log "rolled back to $old_version"
  expect_untouched
  install_converge -e "postal_version=$old_version"
  h test ! -e "$marker" || fail "a successful run with $old_version kept the marker"
  install_converge_unchanged -e "postal_version=$old_version"
  remove_installation
  h docker rmi "$test_repo:$new_version" >/dev/null
}

# A release whose migration breaks a table: Postal's image of new_version
# with an entrypoint that, for postal upgrade, migrates and then drops the
# servers table (the test's fault), tagged as test_repo's new_version.
# make_breaking_image <SQL>: the new version tagged in test_repo, whose
# postal upgrade runs the SQL afterwards (the fault of the suite).
make_breaking_image() {
  local entry
  h docker pull -q --platform linux/amd64 "$postal_repo:$new_version" >/dev/null
  entry="$(h docker image inspect --format '{{join .Config.Entrypoint " "}}' "$postal_repo:$new_version")"
  h sh -c 'rm -rf /root/breaking && mkdir /root/breaking'
  printf 'ActiveRecord::Base.connection.execute(%s)\n' "$(printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))')" \
    | hi sh -c 'cat >/root/breaking/break.rb'
  hi sh -c 'cat >/root/breaking/entry.sh' <<EOF
#!/bin/sh
# The fault of the postal suite: postal upgrade, then break.rb.
if [ "\$1 \$2" = "postal upgrade" ]; then
  $entry "\$@" || exit
  exec $entry bundle exec rails runner /noix-break.rb
fi
exec $entry "\$@"
EOF
  printf 'FROM %s:%s\nCOPY --chmod=0755 entry.sh /noix-entry.sh\nCOPY --chmod=0644 break.rb /noix-break.rb\nENTRYPOINT ["/noix-entry.sh"]\n' \
    "$postal_repo" "$new_version" | hi sh -c 'cat >/root/breaking/Dockerfile'
  h docker build -q --platform linux/amd64 -t "$test_repo:$new_version" /root/breaking >/dev/null
}

test_broken_db() {
  echo "== broken_db (ubuntu $1)"
  ensure_old_installed broken_db
  make_breaking_image 'DROP TABLE servers'
  install_converge_fails -e "postal_image=$test_repo"
  expect_in_log 'the users and servers tables'
  expect_rolled_back "a broken database" "$new_version"
  h rm "$marker"

  # The message database of the fixture's server, which postal upgrade
  # migrates too.
  echo "== broken_db: a broken message database (ubuntu $1)"
  h docker rmi "$test_repo:$new_version" >/dev/null
  make_breaking_image 'DROP TABLE `postal-server-1`.messages'
  install_converge_fails -e "postal_image=$test_repo"
  expect_in_log 'the messages table of postal-server-1 cannot be read'
  expect_rolled_back "a broken message database" "$new_version"
  h rm "$marker"
  remove_installation
  h docker rmi "$test_repo:$new_version" >/dev/null
}

# A converge stopped as a dropped SSH session or a reboot stops it: the role
# with the settings of an installation, in the background in a process group
# of its own, killed with SIGKILL (the whole group) once the shell condition
# holds on the test host; then waits until no module of it runs there any
# more. Its output goes to converge.log, which must hold no test secret:
# play_killed <condition> [-e ...].
play_killed() {
  local condition="$1" pid
  shift
  set -m
  ansible-playbook -v -i "$here/inventory.yml" -e "test_host=$host" "$here/converge.yml" \
    -e "@$out/role-vars.json" -e "$(db_vars)" -e "@$out/admin-vars.json" "$@" >"$out/converge.log" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 1800); do
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

test_interrupted() {
  echo "== interrupted (ubuntu $1)"
  ensure_old_installed interrupted

  # The variable without an interrupted update.
  note_untouched
  install_converge_fails -e "postal_version=$old_version" -e postal_restore_interrupted=true
  expect_in_log "postal_restore_interrupted is set, but there is no interrupted update in $app_dir"
  expect_untouched

  # Killed once the compose file names the new version: refused naming both
  # versions; postal_restore_interrupted puts the backup back.
  echo "== interrupted: after the backup (ubuntu $1)"
  play_killed "grep -qF ':$new_version\"' $app_dir/compose.yaml && test -e $progress"
  note_untouched
  install_converge_fails
  expect_in_log "the Postal update from $old_version to $new_version did not finish"
  expect_untouched
  install_converge -e postal_restore_interrupted=true
  expect_in_log "runs $old_version again"
  [ "$(web_image)" = "$postal_repo:$old_version" ] || fail "web runs $(web_image) after the restore"
  h test ! -e "$progress" || fail "the restore left $progress"
  expect_data "after the restore"
  install_converge_unchanged -e "postal_version=$old_version"

  # Killed during the backup: the next run removes the partial backup and
  # updates.
  echo "== interrupted: during the backup (ubuntu $1)"
  play_killed "ls -d $backups/*.partial"
  install_converge
  [ "$(web_image)" = "$postal_repo:$new_version" ] || fail "web runs $(web_image) after the update"
  [ -z "$(h sh -c "ls -d $backups/*.partial 2>/dev/null || true")" ] || fail "a partial backup is left: $(h ls -A "$backups")"
  h test ! -e "$progress" || fail "the update left $progress"
  expect_data "after the interrupted backup"
  remove_installation
}

# A backup directory with less space than the databases: refused before
# Postal stops.
test_no_space() {
  echo "== no_space (ubuntu $1)"
  ensure_old_installed no_space
  h mkdir -p "$backups"
  h mount -t tmpfs -o size=64k tmpfs "$backups"
  note_starts
  note_untouched
  install_converge_fails
  h umount "$backups"
  expect_in_log 'MB free. The role changes nothing; Postal keeps running.'
  expect_untouched
  expect_restarted
  remove_installation
}

# postal-dump by hand: two complete directories; killed with SIGKILL in the
# middle only <dir>.tmp is left, which the next run replaces.
test_postal_dump() {
  local dir rc
  echo "== postal_dump (ubuntu $1)"
  ensure_installed postal_dump
  postal_fixture >/dev/null
  [ "$(h stat -c '%a %U' /usr/local/sbin/postal-dump)" = '700 root' ] || fail "postal-dump is not root's with mode 0700"
  for dir in /root/dump-a /root/dump-b; do
    h rm -rf "$dir" "$dir.tmp"
    h /usr/local/sbin/postal-dump "$dir" || fail "postal-dump $dir failed"
    [ "$(h sh -c "cd $dir && ls")" = "$(printf 'postal-server-1.sql\npostal.sql\npostal.yml\nsigning.key')" ] \
      || fail "postal-dump $dir wrote: $(h ls "$dir")"
    h sh -c "tail -n 1 $dir/postal.sql | grep -q '^-- Dump completed'" || fail "the dump in $dir is not complete"
  done
  # Its own earlier backup is replaced.
  h /usr/local/sbin/postal-dump /root/dump-a || fail "postal-dump over its own backup /root/dump-a failed"
  h test -f /root/dump-a/.postal-dump || fail "postal-dump wrote no mark into /root/dump-a"
  h test ! -e /root/dump-a.old || fail "postal-dump left /root/dump-a.old"
  h rm -rf /root/dump-c /root/dump-c.tmp
  # In a process group of its own, killed as a whole once it made <dir>.tmp
  # (each dump runs through docker compose exec, which takes a while).
  h bash -c 'setsid /usr/local/sbin/postal-dump /root/dump-c & pid=$!
    for _ in $(seq 300); do [ -d /root/dump-c.tmp ] && break; sleep 0.1; done
    kill -9 -- "-$pid"; wait "$pid" || true'
  h test ! -e /root/dump-c || fail "the killed postal-dump left /root/dump-c"
  h test -d /root/dump-c.tmp || fail "the killed postal-dump left no /root/dump-c.tmp"
  h /usr/local/sbin/postal-dump /root/dump-c || fail "postal-dump after the killed one failed"
  h test ! -e /root/dump-c.tmp || fail "postal-dump left /root/dump-c.tmp"
  h test -s /root/dump-c/postal.sql || fail "postal-dump after the killed one wrote no dump"
  h rm -rf /root/dump-a /root/dump-b /root/dump-c
  # Without an argument, as backrest runs it: the backup directory's latest,
  # which the pruning of the update backups leaves alone.
  h rm -rf "$backups/latest" "$backups/latest.tmp"
  h /usr/local/sbin/postal-dump </dev/null || fail "postal-dump without an argument failed"
  h sh -c "tail -n 1 $backups/latest/postal.sql | grep -q '^-- Dump completed'" \
    || fail "postal-dump without an argument wrote no complete dump to $backups/latest"
  [ "$(h stat -c '%a %U' "$backups/latest")" = '700 root' ] || fail "$backups/latest is not root's with mode 0700"
  h sh -c 'postal-dump a b' >/dev/null 2>&1 && fail "postal-dump took two arguments"
  # A directory it did not write stays as it is: refused with exit 2.
  h sh -c 'rm -rf /root/other && mkdir /root/other && echo keep >/root/other/file && echo keep >/root/plain'
  for dir in /root/other /root/plain /; do
    rc=0; h /usr/local/sbin/postal-dump "$dir" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || fail "postal-dump $dir ended $rc, not 2"
  done
  [ "$(h cat /root/other/file)" = keep ] || fail "postal-dump replaced /root/other"
  [ "$(h cat /root/plain)" = keep ] || fail "postal-dump replaced /root/plain"
  h test ! -e /root/other.tmp || fail "the refused postal-dump left /root/other.tmp"
  h rm -rf /root/other /root/plain
  h rm -rf "$backups/latest"
}

# The rollback and an update on an external MariaDB, which hold a database
# of someone else (other): it stays as it is.
expect_other() {
  [ "$(printf 'SELECT v FROM other.keep;\n' | db_sql noix-db)" = 7 ] || fail "$1: the database other was touched"
}
test_failed_update_external() {
  echo "== failed_update_external (ubuntu $1)"
  remove_installation
  start_db noix-db mariadb:11.4 db.example.test -p 127.0.0.1:3306:3306
  db_postal_user noix-db postal postal 'postal-%'
  printf 'CREATE DATABASE other;\nCREATE TABLE other.keep (v INT);\nINSERT INTO other.keep VALUES (7);\n' \
    | db_sql noix-db >/dev/null || fail "the database other could not be made"
  h sh -c 'grep -q " db.example.test$" /etc/hosts || echo "127.0.0.1 db.example.test" >>/etc/hosts'
  echo "== install of $old_version on the external MariaDB for failed_update_external"
  install_converge -e "$ext_vars" -e "postal_version=$old_version"
  note_generated
  fixture_key="$(postal_fixture)" || fail "the fixture failed: $(tail -n 20 "$out/rails.log")"
  secrets+=("$fixture_key")
  old_subject="noixext$(openssl rand -hex 4)"
  api_send "$fixture_key" "$old_subject"
  wait_mail "$old_subject" >/dev/null

  # The rollback drops and loads Postal's databases on that server.
  h docker pull -q --platform linux/amd64 "$busybox" >/dev/null
  h docker tag "$busybox" "$test_repo:$new_version"
  install_converge_fails -e "$ext_vars" -e "postal_image=$test_repo" -e postal_health_timeout=60
  expect_rolled_back "a rollback on an external MariaDB" "$new_version"
  expect_other "the rollback"
  h rm "$marker"
  h docker rmi "$test_repo:$new_version" >/dev/null

  echo "== failed_update_external: the update (ubuntu $1)"
  install_converge -e "$ext_vars"
  expect_task "Migrate the databases to Postal $new_version" changed
  expect_backup "$backups/$(complete_backups | tail -n 1)"
  expect_data "the update on an external MariaDB"
  expect_other "the update"
  api_send "$fixture_key" "noixextnew$(openssl rand -hex 4)"
  install_converge_unchanged -e "$ext_vars"
  remove_installation
  h docker rm -f -v noix-db >/dev/null
}

# ps_start, then ps_check <what> [<command>]: the process list of the test
# host (with the processes of its containers), sampled every 0.1 s in
# between, holds no test secret; with a command, a process that ran it was
# sampled.
ps_start() {
  h rm -f /root/ps.log /root/ps.stop
  docker exec -d "$host" sh -c 'while [ ! -e /root/ps.stop ]; do ps -eo args >>/root/ps.log; sleep 0.1; done'
}
ps_check() {
  h touch /root/ps.stop
  sleep 1
  h cat /root/ps.log >"$out/ps.log"
  [ -s "$out/ps.log" ] || fail "the process list was not sampled ($1)"
  expect_no_secrets "$out/ps.log" "the process list ($1)"
  [ -z "${2:-}" ] || grep -qF -- "$2" "$out/ps.log" || fail "no process ran $2 while the process list was sampled ($1)"
}
# The last converge ran at -vvv (the connection plugin's lines).
expect_verbose() {
  grep -qF 'ESTABLISH DOCKER CONNECTION' "$out/converge.log" || fail "the converge did not run at -vvv"
}

test_secrets() {
  local spam='{"postal_spam": "rspamd"}'
  echo "== secrets (ubuntu $1)"
  remove_installation
  install_converge -vvv -e "postal_version=$old_version"
  expect_verbose
  note_generated

  echo "== secrets: a reconfigure (ubuntu $1)"
  install_converge -vvv -e "postal_version=$old_version" -e "$spam" -e "@$out/rspamd-vars.json" -e "@$out/oidc-vars.json"
  expect_in_log 'reconfigure.yml for postalhost'
  expect_clean

  # The backup's dumps (postal-dump, mariadb-dump) and postal upgrade.
  echo "== secrets: an update (ubuntu $1)"
  ps_start
  install_converge -vvv -e "$spam" -e "@$out/rspamd-vars.json" -e "@$out/oidc-vars.json"
  ps_check "the update" mariadb-dump
  expect_task "Migrate the databases to Postal $new_version" changed
  expect_clean

  # The external server's password reaches the client container in
  # dump.cnf only.
  echo "== secrets: postal-dump against an external MariaDB (ubuntu $1)"
  remove_installation
  start_db noix-db mariadb:11.4 db.example.test -p 127.0.0.1:3306:3306
  db_postal_user noix-db postal postal 'postal-%'
  h sh -c 'grep -q " db.example.test$" /etc/hosts || echo "127.0.0.1 db.example.test" >>/etc/hosts'
  install_converge -vvv -e "$ext_vars"
  expect_verbose
  note_generated
  [ "$(h stat -c '%a %U' "$app_dir/dump.cnf")" = '600 root' ] || fail "$app_dir/dump.cnf is not root's with mode 0600"
  h rm -rf /root/dump-ext /root/dump-ext.tmp
  ps_start
  h /usr/local/sbin/postal-dump /root/dump-ext || fail "postal-dump against the external MariaDB failed"
  ps_check "postal-dump against an external MariaDB" mariadb-dump
  h test -s /root/dump-ext/postal.sql || fail "postal-dump against the external MariaDB wrote no dump"
  h rm -rf /root/dump-ext
  remove_installation
  h docker rm -f -v noix-db >/dev/null
}

# All scenarios by default; NOIXDEV_INFRA_POSTAL_TESTS="install" runs only
# these. A new scenario is a test_<name> function and one line in the case
# below.
all_scenarios="refusals install noop_down reconfigure takeover_refusals takeover row_format custom_names ipv6_off routers mail track_domains smtp_tls cert_rotation smtp_files smtp_off missing_data mountpoint spam oidc_gelf install_external postal_dump update failed_update broken_db interrupted no_space failed_update_external secrets"
scenarios="${NOIXDEV_INFRA_POSTAL_TESTS:-$all_scenarios}"
for ubuntu in $releases; do
  start_host "$ubuntu"
  for scenario in $scenarios; do
    case "$scenario" in
      refusals) test_refusals "$ubuntu" ;;
      install) test_install "$ubuntu" ;;
      noop_down) test_noop_down "$ubuntu" ;;
      reconfigure) test_reconfigure "$ubuntu" ;;
      takeover_refusals) test_takeover_refusals "$ubuntu" ;;
      takeover) test_takeover "$ubuntu" ;;
      row_format) test_row_format "$ubuntu" ;;
      custom_names) test_custom_names "$ubuntu" ;;
      ipv6_off) test_ipv6_off "$ubuntu" ;;
      routers) test_routers "$ubuntu" ;;
      mail) test_mail "$ubuntu" ;;
      track_domains) test_track_domains "$ubuntu" ;;
      smtp_tls) test_smtp_tls "$ubuntu" ;;
      cert_rotation) test_cert_rotation "$ubuntu" ;;
      smtp_files) test_smtp_files "$ubuntu" ;;
      smtp_off) test_smtp_off "$ubuntu" ;;
      missing_data) test_missing_data "$ubuntu" ;;
      mountpoint) test_mountpoint "$ubuntu" ;;
      spam) test_spam "$ubuntu" ;;
      oidc_gelf) test_oidc_gelf "$ubuntu" ;;
      install_external) test_install_external "$ubuntu" ;;
      postal_dump) test_postal_dump "$ubuntu" ;;
      update) test_update "$ubuntu" ;;
      failed_update) test_failed_update "$ubuntu" ;;
      broken_db) test_broken_db "$ubuntu" ;;
      interrupted) test_interrupted "$ubuntu" ;;
      no_space) test_no_space "$ubuntu" ;;
      failed_update_external) test_failed_update_external "$ubuntu" ;;
      secrets) test_secrets "$ubuntu" ;;
      *) fail "unknown scenario $scenario ($all_scenarios)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all postal tests passed"
