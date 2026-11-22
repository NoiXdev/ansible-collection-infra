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
  body="$(request 443 postal.test /api/v1/send/message -X POST -H 'Content-Type: application/json' -H "X-Server-API-Key: $key" \
    --data '{"to": ["someone@example.test"], "from": "test@mail.example.test", "subject": "'"$subject"'", "plain_body": "A message of the postal suite."}')"
  [[ "$body" == *'"status":"success"'* ]] || fail "the API did not take the message: $(printf '%s' "$body" | head -c 300)"
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

# All scenarios by default; NOIXDEV_INFRA_POSTAL_TESTS="install" runs only
# these. A new scenario is a test_<name> function and one line in the case
# below.
all_scenarios="refusals install noop_down reconfigure takeover ipv6_off routers mail track_domains missing_data mountpoint"
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
      routers) test_routers "$ubuntu" ;;
      mail) test_mail "$ubuntu" ;;
      track_domains) test_track_domains "$ubuntu" ;;
      missing_data) test_missing_data "$ubuntu" ;;
      mountpoint) test_mountpoint "$ubuntu" ;;
      *) fail "unknown scenario $scenario ($all_scenarios)" ;;
    esac
  done
  cleanup
done

noix_done
echo "== all postal tests passed"
