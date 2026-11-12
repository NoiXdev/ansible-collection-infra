#!/usr/bin/env bash
# End-to-end test of the cloudpanel role on a systemd Ubuntu 24.04 container
# (tests/host/Dockerfile): CloudPanel's real installer, converge twice (the
# second run must change nothing), the error pages and the maintenance switch
# on sites created with clpctl and edited in CloudPanel's vhost editor, the
# health check against stubs on the controller (also after a failed step),
# the refusal of package removals and downgrades, fail2ban and CrowdSec next
# to CloudPanel (CrowdSec's Local API off CloudPanel's port 8080), and a
# Docker restart and a reboot that bring the compose projects back.
# The single-quoted scripts expand inside the container, not here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
host="${NOIXDEV_INFRA_CLOUDPANEL_TEST_HOST:-noixdev-infra-cloudpanel-test}"
jammy="$host-jammy"
out="$tests/output/cloudpanel"
stub_port="${CLOUDPANEL_STUB_PORT:-18080}"
stub="http://127.0.0.1:$stub_port/status"
stub_pid=""

cleanup() {
  [ -z "$stub_pid" ] || { kill "$stub_pid" 2>/dev/null; wait "$stub_pid" 2>/dev/null; } || true
  [ "${KEEP:-0}" = 1 ] || docker rm -f -v "$host" "$jammy" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
ln -sfn "$root" "$tests/output/ansible_collections/noixdev/infra"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"

fail() { echo "$*" >&2; exit 1; }

# Starts a systemd Ubuntu container: start_host <name> <ubuntu release> [docker run args].
start_host() {
  local name="$1" release="$2"
  shift 2
  docker build -q --build-arg "UBUNTU=$release" -t "noixdev-infra-host:$release" "$tests/host" >/dev/null
  docker rm -f -v "$name" >/dev/null 2>&1 || true
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock --name "$name" "$@" "noixdev-infra-host:$release" >/dev/null
  wait_running "$name"
}
wait_running() {
  until (docker exec "$1" systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
}

play() { ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$@"; }
hx() { docker exec "$host" "$@"; }
# A converge that must fail; its output goes to $out/<name>.log.
play_fails() {
  local name="$1"
  shift
  if play "$@" >"$out/$name.log" 2>&1; then
    fail "converge $name succeeded but must fail"
  fi
}
expect_in_log() {
  grep -qF -- "$2" "$out/$1.log" || { cat "$out/$1.log" >&2; fail "$1.log lacks: $2"; }
}
expect_idempotent() {
  play "$here/converge.yml" "$@" | tee "$out/rerun.log"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/rerun.log" || fail "a repeated converge changed something"
}
pid1_started() { hx awk '{print $22}' /proc/1/stat; }

# Saves a vhost through CloudPanel's vhost editor as the admin from vars.yml:
# editor <domain> insert-after <anchor line> <line> | editor <domain> remove <line>.
# CloudPanel reloads nginx; the second lets the new workers take over.
editor() { hx python3 -I /root/vhost_editor.py admin Test-admin-password-0 "$@" && sleep 1; }
# A PHP site from CloudPanel's Generic template: php_site <domain> <user> <PHP version>.
php_site() {
  hx clpctl site:add:php --domainName="$1" --phpVersion="$3" --vhostTemplate=Generic \
    --siteUser="$2" --siteUserPassword=Test-site-password-0 >/dev/null
}
static_site() {
  hx clpctl site:add:static --domainName="$1" --siteUser="$2" --siteUserPassword=Test-site-password-0 >/dev/null
}
# site_file <user> <domain> <file> <content>: a file in the site's document root.
site_file() {
  printf '%s' "$4" | docker exec -i "$host" install -o "$1" -g "$1" -m 0644 /dev/stdin "/home/$1/htdocs/$2/$3"
}
# expect_page <status> <domain> <path> <text>...: requests https://<domain><path>
# on the test host (extra curl arguments in $curl_args) and checks the status
# and that the body contains every text.
expect_page() {
  local status="$1" domain="$2" path="$3" got text
  shift 3
  # shellcheck disable=SC2086
  got="$(hx curl -sk --resolve "$domain:443:127.0.0.1" -o /tmp/body -w '%{http_code}' ${curl_args:-} "https://$domain$path")"
  for text in "$@"; do
    if [ "$got" != "$status" ] || ! hx grep -qF -- "$text" /tmp/body; then
      hx head -c 400 /tmp/body >&2
      fail "https://$domain$path answered $got, expected $status with: $text"
    fi
  done
}
# The include line CloudPanel's vhosts get, in the vhost file and in the
# vhost editor's storage (the site's vhost_template in CloudPanel's database).
include_line="include /etc/nginx/noix-error-pages.conf;"
vhost_has_include() {
  hx grep -qF -- "$include_line" "/etc/nginx/sites-enabled/$1.conf" \
    && hx sqlite3 /home/clp/htdocs/app/data/db.sq3 "SELECT vhost_template FROM site WHERE domain_name = '$1'" \
    | grep -qF -- "$include_line"
}
vhost_lacks_include() {
  ! hx grep -qF -- "$include_line" "/etc/nginx/sites-enabled/$1.conf" \
    && ! hx sqlite3 /home/clp/htdocs/app/data/db.sq3 "SELECT vhost_template FROM site WHERE domain_name = '$1'" \
    | grep -qF -- "$include_line"
}

# A CloudPanel server's nginx holds 8080 (the PHP sites' backend), so
# CrowdSec's Local API is moved to 8081 (vars.yml). Both must stay up.
expect_security() {
  local unit
  for unit in nginx crowdsec crowdsec-firewall-bouncer fail2ban; do
    hx systemctl is-active --quiet "$unit" || { hx systemctl --no-pager status "$unit" | tail -20 >&2; fail "$unit is not active"; }
  done
  hx ss -ltnH 'sport = :8081' | grep -q '127.0.0.1:8081' || fail "CrowdSec's Local API does not listen on 127.0.0.1:8081"
  hx ss -ltnpH 'sport = :8080' | grep -q nginx || fail "nginx does not hold port 8080"
}

# Shell functions for a local apt repository of stub packages, for bash -euc.
stub_repo='
repo=/opt/noixdev-stub-repo
mkdir -p "$repo"
mkdeb() {
  local d
  d="$(mktemp -d)"
  mkdir "$d/DEBIAN"
  printf "Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: Test <test@cloudpanel.test>\nDescription: test stub\n" \
    "$1" "$2" >"$d/DEBIAN/control"
  [ -z "${3:-}" ] || echo "$3" >>"$d/DEBIAN/control"
  dpkg-deb -b "$d" "$repo/$1_$2_all.deb" >/dev/null
  rm -rf "$d"
}
index() {
  (
    cd "$repo"
    for f in *.deb; do
      dpkg-deb -f "$f"
      printf "Filename: ./%s\nSize: %s\nSHA256: %s\n\n" "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d" " -f1)"
    done >Packages
  )
  echo "deb [trusted=yes] file:$repo ./" >/etc/apt/sources.list.d/noixdev-stub.list
  apt-get update -qq
}
'
remove_stub_repo() {
  hx bash -euc 'DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "$@" >/dev/null
rm -rf /etc/apt/sources.list.d/noixdev-stub.list /etc/apt/preferences.d/noixdev-stub /opt/noixdev-stub-repo
apt-get update -qq' sh "$@"
}

echo "== unit test of the vhost script"
python3 -I "$here/vhosts_unit.py" "$root/roles/cloudpanel/files/error_pages_vhosts.py"

python3 -I "$here/health_stub.py" "$stub_port" &
stub_pid=$!
for _ in $(seq 20); do curl -fs "$stub/200" >/dev/null && break; sleep 0.5; done
curl -fs "$stub/200" >/dev/null || fail "the health stub does not answer on port $stub_port"

echo "== Ubuntu 22.04 is refused before any change"
start_host "$jammy" 22.04
if ansible-playbook -i "$here/inventory.yml" -e "test_host=$jammy" "$here/role.yml" >"$out/jammy.log" 2>&1; then
  fail "the cloudpanel role accepted Ubuntu 22.04"
fi
expect_in_log jammy "supports Ubuntu 24.04 only"
expect_in_log jammy "changed=0"
docker exec "$jammy" sh -c 'test ! -e /root/cloudpanel-install.sh && test ! -e /etc/apt/sources.list.d/packages.cloudpanel.io.list' \
  || fail "the cloudpanel role touched the Ubuntu 22.04 host"
docker rm -f -v "$jammy" >/dev/null

# --restart always: a reboot inside the container ends PID 1, and Docker
# starts the container again, as a server comes back after a reboot. The
# volumes give the inner Docker a file system it can mount overlays on.
start_host "$host" 24.04 --hostname cloudpanel.test --restart always -p 127.0.0.1:8443:8443 \
  -v /var/lib/docker -v /var/lib/containerd
# The image's policy-rc.d (exit 101) keeps package scripts from starting
# services, which CloudPanel's postinst needs (its database). Servers have none.
hx rm -f /usr/sbin/policy-rc.d
docker cp "$here/vhost_editor.py" "$host:/root/vhost_editor.py"

echo "== a wrong installer checksum is refused before the installer runs"
play_fails checksum "$here/role.yml" -e cloudpanel_installer_sha256="$(printf '0%.0s' $(seq 64))"
expect_in_log checksum "CloudPanel step failed: Download the CloudPanel installer"
expect_in_log checksum "did not match"
hx test ! -e /usr/bin/clpctl || fail "CloudPanel was installed despite the wrong checksum"
hx test ! -e /root/cloudpanel-install.sh || fail "the installer with the wrong checksum was kept"

echo "== an SSH port other than 22 is refused before the installer runs"
play_fails sshport "$here/role.yml" -e base_sshd_port=2222
expect_in_log sshport "CloudPanel step failed: Check the SSH port"
hx test ! -e /usr/bin/clpctl || fail "CloudPanel was installed with SSH on port 2222"

echo "== traces of CloudPanel without clpctl are refused"
hx mkdir /home/clp
play_fails traces "$here/role.yml"
expect_in_log traces "CloudPanel step failed: Refuse to install where CloudPanel has left traces"
expect_in_log traces "/home/clp exists"
hx test ! -e /root/cloudpanel-install.sh || fail "the installer was downloaded despite the traces"
hx rmdir /home/clp

# Without the error pages, fail2ban and CrowdSec first, so that the sites
# below exist before the role adds the error pages and before CrowdSec is
# installed (nginx then already holds 8080), as on a server that runs the
# playbook for the first time.
echo "== converge (installs CloudPanel, without the error pages, fail2ban and CrowdSec)"
start="$(date +%s)"
play "$here/converge.yml" -e cloudpanel_error_pages_enabled=false -e cloudpanel_test_security=false \
  | tee "$out/converge.log"
echo "first converge took $(($(date +%s) - start)) s"

echo "== verify"
play "$here/verify.yml"

echo "== sites that exist before the error pages"
# ok.test answers 200, and 404 and 422 from the application. down.test and
# own.test run on PHP 8.2, which is stopped below; own.test has its own
# error_page 502, saved in the vhost editor.
php_site ok.test okuser 8.3
php_site down.test downuser 8.2
php_site own.test ownuser 8.2
static_site static.test staticuser
static_site optout.test optoutuser
# optphp.test runs on PHP 8.2 too and opts out below.
php_site optphp.test optphpuser 8.2
# dup.test serves /noix-error-pages/ itself: with the include nginx rejects it.
static_site dup.test dupuser
# crlf.test was saved from a browser: CRLF line breaks in CloudPanel's database.
static_site crlf.test crlfuser
site_file okuser ok.test index.php '<?php
switch (parse_url($_SERVER["REQUEST_URI"], PHP_URL_PATH)) {
case "/app-404": http_response_code(404); echo "app 404 page"; break;
case "/app-422": http_response_code(422); header("Content-Type: application/json"); echo "{\"error\":\"invalid\"}"; break;
default: echo "ok";
}'
site_file ownuser own.test own-502.html 'own 502 page'
editor own.test insert-after "include /etc/nginx/global_settings;" "error_page 502 /own-502.html;"
editor dup.test insert-after "include /etc/nginx/global_settings;" "location ^~ /noix-error-pages/ { return 404; }"
editor crlf.test insert-after "include /etc/nginx/global_settings;" "# saved from a browser" --crlf
[ "$(hx sqlite3 /home/clp/htdocs/app/data/db.sq3 "SELECT instr(vhost_template, char(13)) > 0 FROM site WHERE domain_name = 'crlf.test'")" = 1 ] \
  || fail "CloudPanel did not keep the CRLF line breaks of crlf.test"

echo "== a vhost nginx rejects with the include fails the run, changes nothing, and the health check still runs"
vhost_state() {
  hx sh -c "md5sum /etc/nginx/sites-enabled/$1.conf; sqlite3 /home/clp/htdocs/app/data/db.sq3 \"SELECT vhost_template FROM site WHERE domain_name = '$1'\" | md5sum"
}
dup_before="$(vhost_state dup.test)"
ok_before="$(vhost_state ok.test)"
# fail2ban and CrowdSec are installed by this converge, with nginx on 8080.
play_fails duplicate "$here/converge.yml" -e "{\"cloudpanel_health_urls\": [\"$stub/500\"]}"
expect_in_log duplicate "CloudPanel step failed: Check the vhost changes"
expect_in_log duplicate "nginx -t failed after adding the include"
expect_in_log duplicate "dup.test"
expect_in_log duplicate "Health check after the failure: Health check failed: $stub/500 answered 500"
[ "$(vhost_state dup.test)" = "$dup_before" ] || fail "the failed run changed the vhost of dup.test"
[ "$(vhost_state ok.test)" = "$ok_before" ] || fail "the failed run changed the vhost of ok.test"
hx nginx -t -q 2>/dev/null || fail "nginx -t fails after the failed run"
editor dup.test remove "location ^~ /noix-error-pages/ { return 404; }"
expect_security

echo "== converge (adds the error pages)"
play "$here/converge.yml" | tee "$out/error-pages.log"
for site in ok.test down.test own.test static.test optout.test optphp.test dup.test crlf.test; do
  vhost_has_include "$site" || fail "the vhost of $site lacks the error pages include"
done
# crlf.test's include line has the CRLF ending of its vhost, in the file and in the database.
crlf_file=/etc/nginx/sites-enabled/crlf.test.conf
[ "$(hx grep -cF -- "$include_line"$'\r' "$crlf_file")" = "$(hx grep -cF -- "$include_line" "$crlf_file")" ] \
  || fail "an include line in $crlf_file lacks the CRLF ending"
[ "$(hx sqlite3 /home/clp/htdocs/app/data/db.sq3 \
  "SELECT instr(vhost_template, '$include_line' || char(13) || char(10)) > 0 FROM site WHERE domain_name = 'crlf.test'")" = 1 ] \
  || fail "the include line in CloudPanel's database lacks the CRLF ending of crlf.test"
# The record of the sites carries CloudPanel's creation time of each site.
hx python3 -c 'import json, sys; d = json.load(open("/var/lib/noix-error-pages/vhosts.json")); sys.exit(not d or not all(e["created"] for e in d))' \
  || { hx cat /var/lib/noix-error-pages/vhosts.json >&2; fail "the record of the sites lacks their creation time"; }

echo "== idempotence"
play "$here/converge.yml" | tee "$out/idempotence.log"
grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/idempotence.log" \
  || fail "second converge changed something"
if grep -A1 'Reboot the host' "$out/idempotence.log" | grep -q '^changed'; then
  fail "second converge rebooted"
fi

echo "== error pages"
hx systemctl stop php8.2-fpm
expect_page 502 down.test / 'data-page="502"' 'ep-theme-classic' '<html lang="en"'
curl_args="-H Accept-Language:de-DE,de;q=0.9" expect_page 502 down.test / '<html lang="de"'
expect_page 200 ok.test / ok
# The application's own 4xx answers pass unchanged.
expect_page 404 ok.test /app-404 'app 404 page'
expect_page 422 ok.test /app-422 '{"error":"invalid"}'
# A body over client_max_body_size: nginx answers 413 before it reads it.
curl_args="-X POST -H Content-Length:104857600 --data x" expect_page 413 ok.test / 'data-page="413"'
# The vhost's own error_page wins over the default.
expect_page 502 own.test / 'own 502 page'
# The full set, added in the vhost editor: a 404 from nginx shows the page
# (without it, nginx's own 404 page).
expect_page 404 static.test /missing nginx
hx grep -q ep-theme /tmp/body && fail "static.test shows the 404 page without the full set"
editor static.test insert-after "include /etc/nginx/global_settings;" "include /etc/nginx/noix-error-pages-all.conf;"
expect_page 404 static.test /missing 'data-page="404"' 'ep-theme-classic'

echo "== a site created after the run has the include"
static_site new.test newuser
vhost_has_include new.test || fail "the new site new.test lacks the error pages include"

echo "== an include removed in the vhost editor is reported, not added again"
editor optout.test remove "$include_line"
editor optphp.test remove "$include_line"
vhost_lacks_include optout.test || fail "the include is still in the vhost of optout.test"
expect_idempotent
grep -qF "without the error pages include: optout.test, optphp.test" "$out/rerun.log" \
  || fail "the converge did not report optout.test and optphp.test"
vhost_lacks_include optout.test || fail "the converge added the include to optout.test again"
# Without the include, nginx's own page.
curl_args="-X POST -H Content-Length:104857600 --data x" expect_page 413 optout.test / nginx
hx grep -q ep-theme /tmp/body && fail "optout.test shows the error page without the include"
# A PHP site without the include: nginx's own pages for 413 and 502 (its
# PHP-FPM is stopped).
curl_args="-X POST -H Content-Length:104857600 --data x" expect_page 413 optphp.test / nginx
hx grep -q ep-theme /tmp/body && fail "optphp.test shows the 413 error page without the include"
expect_page 502 optphp.test / nginx
hx grep -q ep-theme /tmp/body && fail "optphp.test shows the 502 error page without the include"

echo "== the maintenance switch"
hx noix-maintenance on
[ "$(hx noix-maintenance status)" = on ] || fail "noix-maintenance status does not say on"
expect_page 502 down.test / 'data-page="maintenance"'
expect_page 200 ok.test / ok
hx noix-maintenance off
[ "$(hx noix-maintenance status)" = off ] || fail "noix-maintenance status does not say off"
expect_page 502 down.test / 'data-page="502"'
play "$here/converge.yml" -e cloudpanel_maintenance=true | tee "$out/maintenance.log"
grep -Eq 'changed=[1-9]' "$out/maintenance.log" || fail "cloudpanel_maintenance=true changed nothing"
expect_page 502 down.test / 'data-page="maintenance"'
expect_page 200 ok.test / ok
expect_idempotent -e cloudpanel_maintenance=true
play "$here/converge.yml" >"$out/maintenance-off.log" || { cat "$out/maintenance-off.log" >&2; fail "the converge failed"; }
[ "$(hx noix-maintenance status)" = off ] || fail "cloudpanel_maintenance=false did not switch it off"
expect_page 502 down.test / 'data-page="502"'
hx systemctl start php8.2-fpm

echo "== an nginx configuration that is broken before the run is reported as such"
http_conf=/etc/nginx/sites-enabled/noix-error-pages-http.conf
http_before="$(hx md5sum "$http_conf")"
# A broken file of someone else's: nginx -t fails before the role changes anything.
hx sh -c 'echo "broken_directive;" >/etc/nginx/sites-enabled/zz-broken.conf'
play_fails broken "$here/converge.yml" -e '{"cloudpanel_error_pages_default_codes": [502]}'
expect_in_log broken "CloudPanel step failed: Check the nginx configuration before the error pages"
expect_in_log broken "nginx config already invalid before error pages"
expect_in_log broken "zz-broken.conf"
expect_in_log broken "Health check after the failure: every URL answered below 500"
[ "$(hx md5sum "$http_conf")" = "$http_before" ] || fail "the role changed the http-level file although nginx -t failed before"
hx rm /etc/nginx/sites-enabled/zz-broken.conf

echo "== an nginx configuration nginx rejects is put back"
# A test double in front of nginx that rejects the http-level file without
# 504: nginx -t passes before the role's change and fails after it.
hx sh -c 'printf "%s\n" "#!/bin/sh" \
  "grep -q \"error_page 504 \" /etc/nginx/sites-enabled/noix-error-pages-http.conf || { echo \"nginx: [emerg] test double rejects it\" >&2; exit 1; }" \
  "exec /usr/sbin/nginx \"\$@\"" >/usr/local/sbin/nginx && chmod 0755 /usr/local/sbin/nginx'
play_fails rejected "$here/converge.yml" -e '{"cloudpanel_error_pages_default_codes": [502]}'
hx rm /usr/local/sbin/nginx
expect_in_log rejected "CloudPanel step failed: Check the nginx test"
expect_in_log rejected "test double rejects it"
[ "$(hx md5sum "$http_conf")" = "$http_before" ] || fail "the rejected http-level file was not put back"
[ -z "$(hx find /etc/nginx -name '*~')" ] || fail "backups of the nginx configuration were left behind"
expect_idempotent

echo "== clp-update that reports neither result fails the run"
hx sh -c 'printf "#!/bin/sh\necho unexpected\n" >/usr/local/sbin/clp-update && chmod 0755 /usr/local/sbin/clp-update'
play_fails clp-update "$here/converge.yml"
hx rm /usr/local/sbin/clp-update
expect_in_log clp-update "CloudPanel step failed: Check the result of clp-update"
expect_in_log clp-update 'clp-update reported neither "up to date" nor an update'
expect_in_log clp-update "Health check after the failure: every URL answered below 500"

echo "== a health URL answering 500 fails the run and names the step"
play_fails health-500 "$here/converge.yml" -e "{\"cloudpanel_health_urls\": [\"$stub/200\", \"$stub/500\"]}"
expect_in_log health-500 "CloudPanel step failed: Check the health check results: Health check failed: $stub/500 answered 500"

echo "== a health URL that does not answer fails the run"
play_fails health-none "$here/converge.yml" -e '{"cloudpanel_health_urls": ["http://127.0.0.1:9/"]}' -e cloudpanel_health_timeout=3
expect_in_log health-none "Health check failed: http://127.0.0.1:9/ gave no answer"

echo "== a health URL answering 404 passes"
expect_idempotent -e "{\"cloudpanel_health_urls\": [\"$stub/404\"]}"

echo "== an upgrade that would remove a package is refused"
# A local repository: noixdev-stub-lib 2.0 conflicts with the installed
# noixdev-stub-old, so a dist-upgrade would remove noixdev-stub-old.
hx bash -euc "$stub_repo"'
mkdeb noixdev-stub-old 1.0
mkdeb noixdev-stub-lib 1.0
index
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq noixdev-stub-old noixdev-stub-lib >/dev/null
mkdeb noixdev-stub-lib 2.0 "Conflicts: noixdev-stub-old"
index
apt-get -s dist-upgrade | grep -q "^Remv noixdev-stub-old"
'
play_fails removal "$here/converge.yml"
expect_in_log removal "would remove packages: noixdev-stub-old"
[ "$(hx dpkg-query -W -f='${Status} ${Version}' noixdev-stub-old noixdev-stub-lib)" \
  = "install ok installed 1.0install ok installed 1.0" ] || fail "the refused upgrade changed the stub packages"
remove_stub_repo noixdev-stub-old noixdev-stub-lib
expect_idempotent

echo "== an upgrade that would downgrade a package is refused"
# noixdev-stub-down 2.0 is installed; the repository has 1.0, pinned at 1000
# as CloudPanel pins its own source.
hx bash -euc "$stub_repo"'
mkdeb noixdev-stub-down 2.0
dpkg -i "$repo/noixdev-stub-down_2.0_all.deb" >/dev/null
rm "$repo/noixdev-stub-down_2.0_all.deb"
mkdeb noixdev-stub-down 1.0
printf "Package: noixdev-stub-down\nPin: version 1.0\nPin-Priority: 1000\n" >/etc/apt/preferences.d/noixdev-stub
index
apt-get -s dist-upgrade | grep -q "^Inst noixdev-stub-down \[2.0\] (1.0"
'
play_fails downgrade "$here/converge.yml"
expect_in_log downgrade "CloudPanel step failed: Refuse an upgrade that would downgrade packages"
expect_in_log downgrade "would downgrade packages: noixdev-stub-down"
[ "$(hx dpkg-query -W -f='${Version}' noixdev-stub-down)" = 2.0 ] || fail "the refused upgrade downgraded the stub package"
remove_stub_repo noixdev-stub-down
expect_idempotent

echo "== a restart of Docker by the docker role brings the compose projects back"
hx bash -euc '
for p in stubapp stoppedapp goneapp; do
  mkdir -p "/opt/$p"
  printf "services:\n  app:\n    image: busybox:1.37\n    command: [sleep, infinity]\n    restart: \"no\"\n" >"/opt/$p/compose.yml"
  docker compose -f "/opt/$p/compose.yml" up -d --quiet-pull
done
docker compose -f /opt/stoppedapp/compose.yml stop
'
# Live restore off: the docker role changes daemon.json and its handler
# restarts Docker; the running daemon still has live restore, so the
# containers survive this one.
play "$here/converge.yml" -e '{"docker_live_restore": false}' >"$out/live-restore-off.log" \
  || { cat "$out/live-restore-off.log" >&2; fail "the converge with docker_live_restore=false failed"; }
# goneapp's files disappear (as for a stack Portainer deployed).
hx rm -rf /opt/goneapp
# Back to live restore: the restart now stops every container.
# Ansible writes warnings to stderr.
play "$here/converge.yml" 2>&1 | tee "$out/docker-restart.log"
grep -Eq "RUNNING HANDLER \[.*Restart docker\]" "$out/docker-restart.log" \
  || fail "the converge did not restart Docker"
[ "$(hx docker compose -p stubapp ps --status running -q | grep -c .)" = 1 ] \
  || fail "the compose project stubapp is not running after the restart of Docker"
[ -z "$(hx docker compose -p stoppedapp ps --status running -q)" ] \
  || fail "the stopped compose project stoppedapp was started"
expect_in_log docker-restart "Not started again, their compose files are missing on the host: goneapp"
hx sh -c 'docker rm -f $(docker ps -aq --filter label=com.docker.compose.project=goneapp)' >/dev/null
expect_idempotent

echo "== a required reboot with cloudpanel_reboot false is a warning"
hx touch /var/run/reboot-required
before="$(pid1_started)"
play "$here/converge.yml" -e cloudpanel_reboot=false 2>&1 | tee "$out/no-reboot.log"
expect_in_log no-reboot "[WARNING]: cloudpanelhost: A reboot is required (/var/run/reboot-required), but the host was not rebooted because cloudpanel_reboot is false"
[ "$(pid1_started)" = "$before" ] || fail "the host was rebooted with cloudpanel_reboot=false"
hx test -e /var/run/reboot-required || fail "reboot-required is gone without a reboot"

echo "== a required reboot reboots and brings the compose projects back"
# stubapp runs and stoppedapp is stopped (above); reboot-required is still there.
before="$(pid1_started)"
play "$here/converge.yml" | tee "$out/reboot.log"
wait_running "$host"
[ "$(pid1_started)" != "$before" ] || fail "the host was not rebooted"
hx test ! -e /var/run/reboot-required || fail "reboot-required is still there"
[ "$(hx docker compose -p stubapp ps --status running -q | grep -c .)" = 1 ] \
  || fail "the compose project stubapp is not running after the reboot"
[ -z "$(hx docker compose -p stoppedapp ps --status running -q)" ] \
  || fail "the stopped compose project stoppedapp was started"
play "$here/verify.yml"
expect_security
expect_idempotent

echo "== all cloudpanel tests passed"
