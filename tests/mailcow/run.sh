#!/usr/bin/env bash
# End-to-end test of the mailcow role on one systemd Ubuntu 24.04 container
# (tests/host/Dockerfile) with Docker inside (the docker role, prepare.yml)
# and a tmpfs at /mnt/mailcow-backups (a file system of its own).
#
# First the refusals before any change: no mailcow_backup_dir, backups on
# the file system of /, backups and clone nested (also through a symbolic
# link), an admin allowlist with mailcow's own network or every address.
#
# Real mailcow (from GitHub, with ClamAV and full-text search off): a fresh
# install, repeated without changes, with the admin restriction and the
# error pages checked from test clients (network namespaces on the host,
# reaching mailcow as tailnet and internet clients do, over IPv4 and IPv6),
# a 502 with PHP-FPM stopped, an nginx-mailcow restart, an nginx
# configuration nginx rejects (its copies kept outside the clone) and
# mailcow_admin_allow [] (no restriction);
# a clone on another branch than master; the takeover of an installation of
# the previous release with the backup cron script from mailcow's
# documentation, updated by the real update.sh (the role's nginx files in
# place before it, still working after it). Anubis (anubis.yml: the anubis
# role in nginx mode, then mailcow with anubis-vars.yml): its refusals, a
# browser challenged on /, /SOGo, /rc and /domainadmin and passing once
# solved, the mail, API and ACME paths passing in every case mailcow serves,
# the admin restriction first, client-sent headers and path tricks, a stopped
# Anubis (fails closed), switching it off, and the takeover with Anubis
# through update.sh. Only scenarios that do not
# depend on whether upstream's master moves meanwhile (the repeated
# converges follow within seconds).
#
# A stub mailcow (tests/mailcow/stub: update.sh, backup_and_restore.sh and a
# compose file of nginx containers answering HTTPS, SMTP and IMAPS, cloned
# from a local "upstream" repository; stub-vars.yml turns the admin
# restriction and the error pages off there): update.sh asking to be started again,
# a restart of nginx-mailcow left pending by a stopped run, a backup
# directory that is a symbolic link, a backup target without space, a
# failing health check after the update (the marker of the failed update,
# its refusal and its kept backup), an update.sh that runs out of time, a
# run stopped while update.sh runs (the marker written before it), a marker
# that cannot be written, a local change the update's merge replaced, a
# merge conflict left unmerged, a failing backup with old folders and no
# backup on record, a failing update check (held until the health and
# backup checks ran), a failing SMTP check, a backup older than
# mailcow_backup_max_age_hours, a foreign cron script, a backup stopped
# midway, and the daily backup running while a run backs up before its
# update.
#
# Every successful converge is repeated and must change nothing. KEEP=1
# keeps the host; NOIXDEV_INFRA_MAILCOW_DOCKER_VOLUME names a volume for the
# host's /var/lib/docker and /var/lib/containerd (two volumes with -docker
# and -containerd appended), so images survive between runs; STUB_ONLY=1 runs
# the stub scenarios only (while working on them).
# The single-quoted scripts expand inside the container, not here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
host="${NOIXDEV_INFRA_MAILCOW_TEST_HOST:-noixdev-infra-mailcow-test}"
out="$tests/output/mailcow"
dir=/opt/mailcow-dockerized
backups=/mnt/mailcow-backups
last=/var/lib/noix-mailcow/last-backup
flags=/etc/mailcow-stub
started="$(date +%s)"
# RC_STUB_ONLY=1 / RC_REAL_ONLY=1 run only the Roundcube scenarios of the stub /
# of the real mailcow (after the install), while working on them.
# ANUBIS_REAL_ONLY=1 runs only the Anubis scenarios of the real mailcow (after
# the install) and the takeover, which runs with Anubis.
[ "${RC_STUB_ONLY:-0}" != 1 ] || STUB_ONLY=1

cleanup() { [ "${KEEP:-0}" = 1 ] || docker rm -f -v "$host" >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
ln -sfn "$root" "$tests/output/ansible_collections/noixdev/infra"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"

fail() { echo "$*" >&2; exit 1; }
hx() { docker exec "$host" "$@"; }
hxi() { docker exec -i "$host" "$@"; }
# Extra variables of every play (stub-vars.yml for the stub).
extra_vars=()
play() { ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" ${extra_vars[@]+"${extra_vars[@]}"} "$@"; }
# A converge that must fail; its output goes to $out/<name>.log.
play_fails() {
  local name="$1"
  shift
  if play "$@" >"$out/$name.log" 2>&1; then
    fail "converge $name succeeded but must fail"
  fi
}
# A converge that must succeed; its output (warnings included) goes to
# $out/<name>.log too.
play_ok() {
  local name="$1"
  shift
  play "$@" 2>&1 | tee "$out/$name.log"
}
expect_in_log() {
  grep -qF -- "$2" "$out/$1.log" || { cat "$out/$1.log" >&2; fail "$1.log lacks: $2"; }
}
expect_unchanged() {
  grep -Eq 'changed=0 ' "$out/$1.log" || { cat "$out/$1.log" >&2; fail "$1 changed something"; }
}
# expect_idempotent [playbook]: converge.yml unless named.
expect_idempotent() {
  play "${1:-$here/converge.yml}" | tee "$out/rerun.log"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/rerun.log" || fail "a repeated converge changed something"
}
verify() { play "$here/verify.yml"; }
# The facts the converge showed: fact <log> updated|last_backup.
fact() { sed -n "s/.*mailcow facts: .*$2=\([^ \"]*\).*/\1/p" "$out/$1.log" | tail -n 1; }
https_status() {
  hx curl -sk -o /dev/null -w '%{http_code}' -H 'Host: mail.example.test' https://127.0.0.1/ || true
}
wait_https() {
  for _ in $(seq 120); do
    [ "$(https_status)" = 200 ] && return 0
    sleep 5
  done
  fail "mailcow does not answer over HTTPS"
}
backup_folders() { hx sh -c "ls -d $backups/mailcow-* 2>/dev/null | wc -l"; }
last_folder() { hx sed -n 's/^folder: //p' "$last"; }
# set_last_backup_age <hours>: the last backup as made that many hours ago.
set_last_backup_age() {
  hx sh -c "sed -i \"s/^time: .*/time: \$(date -u -d '$1 hours ago' +%Y-%m-%dT%H:%M:%SZ)/\" $last"
}

start_host() {
  local docker_volume=(-v /var/lib/docker -v /var/lib/containerd)
  [ -z "${NOIXDEV_INFRA_MAILCOW_DOCKER_VOLUME:-}" ] \
    || docker_volume=(-v "$NOIXDEV_INFRA_MAILCOW_DOCKER_VOLUME-docker:/var/lib/docker"
      -v "$NOIXDEV_INFRA_MAILCOW_DOCKER_VOLUME-containerd:/var/lib/containerd")
  docker build -q --build-arg UBUNTU=24.04 -t noixdev-infra-host:24.04 "$tests/host" >/dev/null
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  # The volumes give the inner Docker a file system it can mount overlays on;
  # the tmpfs gives the backups a file system of their own (a volume would
  # share its device with the one of /var/lib/docker). IPv6 on, for mailcow's
  # network and the test clients (add_clients), also where the outer Docker
  # turns it off in containers.
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv6.conf.default.disable_ipv6=0 \
    --tmpfs /run --tmpfs /run/lock --hostname mail.example.test --name "$host" \
    "${docker_volume[@]}" --tmpfs "$backups:rw,size=1g,mode=0755" \
    noixdev-infra-host:24.04 >/dev/null
  until (hx systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
  # The image's policy-rc.d (exit 101) keeps package scripts from starting
  # services; servers have none.
  hx rm -f /usr/sbin/policy-rc.d
}

# Removes mailcow (containers, volumes, the clone), its backups and the
# role's script, units and state, so the next scenario starts from a host
# with Docker only.
reset_host() {
  hx bash -c "if [ -f $dir/docker-compose.yml ]; then cd $dir && docker compose down -v --remove-orphans >/dev/null 2>&1; fi; true"
  hx bash -c "systemctl disable --now mailcow-backup.timer >/dev/null 2>&1; true"
  hx rm -rf "$dir" /srv/mailcow-upstream.git /srv/mailcow-work /var/lib/noix-mailcow "$flags" /var/log/mailcow-stub \
    /usr/local/sbin/mailcow-backup /etc/systemd/system/mailcow-backup.service /etc/systemd/system/mailcow-backup.timer \
    /etc/cron.daily/mailcow-backup
  hx sh -c "rm -rf $backups/* $backups/.[!.]*"
  hx systemctl daemon-reload
}

# mailcow's generate_config.sh as a fresh install by hand runs it, with the
# test settings of vars.yml.
generate_config() {
  hx bash -euc "cd $dir && MAILCOW_HOSTNAME=mail.example.test MAILCOW_TZ=Etc/UTC MAILCOW_BRANCH=master SKIP_CLAMD=y ./generate_config.sh </dev/null >/dev/null
    sed -i 's/^SKIP_FTS=.*/SKIP_FTS=y/; s/^SKIP_LETS_ENCRYPT=.*/SKIP_LETS_ENCRYPT=y/; s/^SKIP_UNBOUND_HEALTHCHECK=.*/SKIP_UNBOUND_HEALTHCHECK=y/' mailcow.conf"
}

# The backup script from mailcow's documentation (Backup page, the
# cron.daily example), as installed on a server by hand.
docs_cron_script() {
  hx mkdir -p /etc/cron.daily
  hxi sh -c 'cat >/etc/cron.daily/mailcow-backup && chmod 0755 /etc/cron.daily/mailcow-backup' <<'EOF'
#!/bin/sh

# Backup mailcow data
# https://docs.mailcow.email/backup_restore/b_n_r-backup/

set -e

OUT="$(mktemp)"
export MAILCOW_BACKUP_LOCATION="/mnt/mailcow-backups"
SCRIPT="/opt/mailcow-dockerized/helper-scripts/backup_and_restore.sh"
PARAMETERS="backup all"
OPTIONS="--delete-days 3"

# run command
set +e
"${SCRIPT}" ${PARAMETERS} ${OPTIONS} 2>&1 > "$OUT"
RESULT=$?

if [ $RESULT -ne 0 ]
    then
            echo "${SCRIPT} ${PARAMETERS} ${OPTIONS} encounters an error:"
            echo "RESULT=$RESULT"
            echo "STDOUT / STDERR:"
            cat "$OUT"
fi
EOF
}

# The stub: release 1 in a local upstream repository, cloned to $dir, with
# mailcow.conf, a snake-oil certificate and its containers started.
stub_install() {
  reset_host
  hx mkdir -p "$flags" /srv/mailcow-work
  docker cp "$here/stub/." "$host:/srv/mailcow-work/"
  hx bash -euc "
    git config --global user.name test && git config --global user.email test@example.test
    git init -q --bare -b master /srv/mailcow-upstream.git
    cd /srv/mailcow-work
    git init -q -b master
    ln -s mailcow.conf .env
    printf 'mailcow.conf\ndata/assets/ssl/\ndata/conf/nginx/*.conf\ndata/conf/nginx/*.custom\n' >.gitignore
    echo 1 >VERSION
    git add -A && git commit -qm 'Release 1'
    git remote add origin /srv/mailcow-upstream.git && git push -q origin master
    git clone -q /srv/mailcow-upstream.git $dir
    cd $dir
    # mailcow's nginx directory (it holds tracked templates there).
    mkdir -p data/conf/nginx
    printf 'MAILCOW_HOSTNAME=mail.example.test\nCOMPOSE_PROJECT_NAME=mailcowdockerized\nHTTPS_PORT=443\nHTTPS_BIND=\n' >mailcow.conf
    chmod 0600 mailcow.conf
    mkdir -p data/assets/ssl
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=mail.example.test \
      -keyout data/assets/ssl/key.pem -out data/assets/ssl/cert.pem 2>/dev/null
    docker compose up -d --quiet-pull" >"$out/stub-install.log" 2>&1 \
    || { cat "$out/stub-install.log" >&2; fail "the stub did not start"; }
}
# release <n>: a new release upstream (VERSION n).
release() {
  hx bash -euc "cd /srv/mailcow-work && echo $1 >VERSION && git commit -qam 'Release $1' && git push -q origin master"
}
stub_version() { hx cat "$dir/VERSION"; }
update_calls() { hx sh -c 'cat /var/log/mailcow-stub/update.calls 2>/dev/null | tr "\n" " "'; }

# Roundcube. fake-github.py serves a fake release list (and the tarballs it
# names) on the host, which vars.yml's mailcow_roundcube_api_url points at.
rc_dir=/srv/rc-fake
rc_cache=/srv/rc-cache
rc_calls=$flags/rc.calls
# A 1.6 release for the real mailcow: Roundcube 1.7.6 needs PHP 8.4 for its
# MySQL driver, which mailcow's php-fpm (8.2) lacks.
rc_old="${ROUNDCUBE_OLD:-1.6.20}"
rc_new="${ROUNDCUBE_NEW:-1.6.21}"
# rc_fake <stub|real> <tag[:flags]>...: writes the release list, newest first
# (stub: tiny tarballs; real: Roundcube's own, from github.com), and serves it.
rc_fake() {
  local mode="$1"
  shift
  docker cp "$here/fake-github.py" "$host:/usr/local/bin/fake-github.py"
  hx systemctl stop rc-fake.service >/dev/null 2>&1 || true
  hx systemctl reset-failed rc-fake.service >/dev/null 2>&1 || true
  hx rm -rf "$rc_dir"
  hx python3 /usr/local/bin/fake-github.py releases "$rc_dir" http://127.0.0.1:8099 "$mode" "$rc_cache" "$@"
  hx systemd-run -q --unit=rc-fake python3 /usr/local/bin/fake-github.py serve "$rc_dir" 8099
  for _ in $(seq 20); do
    hx python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8099/releases")' >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  fail "the fake release list does not answer"
}
rc_version() { hx sed -nE "s/.*RCMAIL_VERSION'?, *'([^']+)'.*/\1/p" "$dir/data/web/rc/program/include/iniset.php"; }
rc_config_sum() { hx sha256sum "$dir/data/web/rc/config/config.inc.php"; }
rc_status() { hx curl -sk -o /tmp/noix-rc -w '%{http_code}' -H 'Host: mail.example.test' https://127.0.0.1/rc/ || true; }
rc_php_started() { hx bash -c "docker inspect -f '{{.State.StartedAt}}' \$(cd $dir && docker compose ps -q php-fpm-mailcow)"; }
rc_call_count() { hx sh -c "wc -l <$rc_calls"; }
rc_leftovers() { hx find "$dir/data/web" -maxdepth 1 -name '.noix-roundcube-*'; }
# The iniset.php of the Roundcube in the last backup.
rc_backed_up_version() {
  hx bash -c "tar -xzOf '$(last_folder)/extra-files.tar.gz' data/web/rc/program/include/iniset.php" | sed -nE "s/.*RCMAIL_VERSION'?, *'([^']+)'.*/\1/p"
}
# A Roundcube of the stub, as installed by hand: the version file, an index
# and a config the role must leave as it is.
stub_roundcube() {
  hxi bash -eu -s "$dir/data/web/rc" "$1" <<'EOF'
rc="$1"
mkdir -p "$rc/program/include" "$rc/config"
printf "<?php\ndefine('RCMAIL_VERSION', '%s');\n" "$2" >"$rc/program/include/iniset.php"
echo '<?php // stub Roundcube' >"$rc/index.php"
printf "<?php\n\$config['db_dsnw'] = 'mysql://roundcube:secret@mysql-mailcow/roundcubemail';\n" >"$rc/config/config.inc.php"
EOF
}
# Roundcube $rc_old in mailcow's guide for the integrated method: the
# complete release in data/web/rc, composer install in php-fpm-mailcow, a
# database in mailcow's MySQL, a config.
real_roundcube() {
  hxi bash -eu -s "$dir" "$rc_dir/dl/roundcubemail-$rc_old-complete.tar.gz" "$rc_old" <<'EOF'
dir="$1"
cd "$dir/data/web"
tar -xzf "$2"
mv "roundcubemail-$3" rc
chown -R root: rc
cd "$dir"
docker compose exec -T -w /web/rc php-fpm-mailcow composer install --no-dev -o </dev/null
chown -R 82:82 data/web/rc/temp data/web/rc/logs
echo "DBROUNDCUBE=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 28)" >>mailcow.conf
set -a
. ./mailcow.conf
set +a
sql="CREATE DATABASE roundcubemail CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE USER 'roundcube'@'%' IDENTIFIED BY '$DBROUNDCUBE';
GRANT ALL PRIVILEGES ON roundcubemail.* TO 'roundcube'@'%'; FLUSH PRIVILEGES;"
docker compose exec -T mysql-mailcow mariadb -uroot -p"$DBROOT" -e "$sql" </dev/null \
  || docker compose exec -T mysql-mailcow mysql -uroot -p"$DBROOT" -e "$sql" </dev/null
cat >data/web/rc/config/config.inc.php <<PHP
<?php
\$config['db_dsnw'] = 'mysql://roundcube:$DBROUNDCUBE@mysql-mailcow/roundcubemail';
\$config['imap_host'] = 'tls://dovecot:143';
\$config['smtp_host'] = 'tls://postfix:587';
\$config['imap_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
\$config['smtp_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
\$config['des_key'] = '$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 24)';
\$config['plugins'] = [];
PHP
docker compose exec -T -w /web/rc php-fpm-mailcow php bin/initdb.sh --dir=SQL </dev/null
EOF
}

# The real mailcow with Roundcube one patch release behind in its series: the
# role installs the newest one of the series (the real tarball, its digest in
# the fake list), keeps the config, and /rc/ answers; a newer series is only
# reported.
rc_real() {
  echo "== Roundcube $rc_old (mailcow's guide) is updated to $rc_new"
  rc_fake real 1.7.6:noasset "$rc_new" "$rc_old"
  real_roundcube
  [ "$(rc_version)" = "$rc_old" ] || fail "Roundcube $rc_old was not installed: $(rc_version)"
  [ "$(rc_status)" = 200 ] || fail "/rc/ of the guide's Roundcube answers $(rc_status), not 200"
  config_sum="$(rc_config_sum)"
  folders="$(backup_folders)"
  php_started="$(rc_php_started)"
  play_ok roundcube "$here/converge.yml"
  [ "$(rc_version)" = "$rc_new" ] || fail "Roundcube was not updated to $rc_new: $(rc_version)"
  [ "$(fact roundcube roundcube_new)" = True ] || fail "mailcow_roundcube_updated is not true"
  [ "$(fact roundcube updated)" = False ] || fail "mailcow reported an update"
  expect_in_log roundcube "Roundcube 1.7.6 is out, a newer series than the 1.6"
  [ "$(rc_status)" = 200 ] || fail "/rc/ answers $(rc_status) after the update"
  hx grep -qi roundcube /tmp/noix-rc || fail "/rc/ does not show Roundcube after the update"
  [ "$(rc_config_sum)" = "$config_sum" ] || fail "config/config.inc.php changed"
  [ "$(backup_folders)" = $((folders + 1)) ] || fail "the update did not make exactly one backup"
  hx grep -qx 'reason: update' "$last" || fail "the backup before the update is not recorded as one"
  [ "$(rc_backed_up_version)" = "$rc_old" ] || fail "the backup does not hold Roundcube $rc_old: $(rc_backed_up_version)"
  [ "$(rc_php_started)" != "$php_started" ] || fail "php-fpm-mailcow was not restarted"
  [ -z "$(rc_leftovers)" ] || fail "the update left its work directory: $(rc_leftovers)"
  hx test ! -e /var/lib/noix-mailcow/update-failed || fail "a successful update wrote the marker"
  verify
  expect_idempotent
  [ "$(backup_folders)" = $((folders + 1)) ] || fail "the repeated converge made a backup"
  [ "$(rc_version)" = "$rc_new" ] || fail "the repeated converge changed Roundcube"
}

# The stub with a Roundcube: the checksum, the rate limit, the switch, the
# update with its backup, one backup for both updates, the marker after a
# failed install step and after a /rc/ that does not answer.
rc_stub() {
  echo "== Roundcube (stub): checksum, rate limit, switch, update, marker"
  stub_install
  stub_roundcube 1.7.5
  rc_fake stub 1.7.5
  play_ok rc-setup "$here/converge.yml"
  [ "$(rc_version)" = 1.7.5 ] || fail "the first run changed Roundcube"
  [ "$(fact rc-setup roundcube_new)" = False ] || fail "nothing was due but mailcow_roundcube_updated is not false"
  hx test ! -e "$rc_calls" || fail "nothing was due but Roundcube's tools ran"
  expect_idempotent
  config_sum="$(rc_config_sum)"
  folders="$(backup_folders)"

  echo "   a download that does not match its checksum fails before anything is installed"
  # 1.7.7 is a prerelease and must not count.
  rc_fake stub 1.8.0 1.7.7:pre 1.7.6:bad 1.7.5
  play_fails rc-bad-checksum "$here/converge.yml"
  expect_in_log rc-bad-checksum "Roundcube 1.7.6: roundcubemail-1.7.6-complete.tar.gz does not match the SHA-256 digest GitHub publishes"
  expect_in_log rc-bad-checksum "Nothing was installed"
  echo "   a release without a published checksum fails the same way"
  rc_fake stub 1.7.6:nodigest 1.7.5
  play_fails rc-no-checksum "$here/converge.yml"
  expect_in_log rc-no-checksum "no SHA-256 checksum published for roundcubemail-1.7.6-complete.tar.gz"
  echo "   a release without the complete tarball, and a download that 404s, fail clearly"
  rc_fake stub 1.7.6:noasset 1.7.5
  play_fails rc-no-asset "$here/converge.yml"
  expect_in_log rc-no-asset "has no roundcubemail-1.7.6-complete.tar.gz"
  # The installed 1.7.5 is not in this list: reported.
  rc_fake stub 1.7.6:nodl
  play_fails rc-404 "$here/converge.yml"
  expect_in_log rc-404 "could not be downloaded from http://127.0.0.1:8099/dl/missing-roundcubemail-1.7.6-complete.tar.gz"
  expect_in_log rc-404 "404"
  ! grep -qF "SHA-256 digest GitHub publishes" "$out/rc-404.log" || fail "a 404 was reported as a digest mismatch"
  expect_in_log rc-404 "is not in the 1 releases read"
  [ "$(rc_version)" = 1.7.5 ] || fail "a failed check changed Roundcube"
  [ "$(backup_folders)" = "$folders" ] || fail "a failed check made a backup"
  hx test ! -e "$rc_calls" || fail "Roundcube's tools ran after a failed check"
  hx test ! -e /var/lib/noix-mailcow/update-failed || fail "a failed check wrote the marker"
  [ -z "$(rc_leftovers)" ] || fail "a failed check left its work directory: $(rc_leftovers)"

  echo "   http for the release list is refused without the test-only flag"
  play_fails rc-http "$here/converge.yml" -e '{"mailcow_roundcube_allow_insecure_mirror": false}'
  expect_in_log rc-http "an https URL (http only with mailcow_roundcube_allow_insecure_mirror"
  expect_unchanged rc-http

  echo "   the API's rate limit is a clear error"
  rc_fake stub 1.7.6 1.7.5
  hx touch "$rc_dir/rate-limit"
  play_fails rc-rate-limit "$here/converge.yml"
  expect_in_log rc-rate-limit "refused the request for Roundcube's releases (HTTP 403) because the rate limit of this address is used up"
  expect_in_log rc-rate-limit "it resets in about 30 minutes"
  hx rm "$rc_dir/rate-limit"
  echo "   so is an API that does not answer; the first backup is still made, an old work directory goes"
  hx mkdir "$dir/data/web/.noix-roundcube-old" "$dir/data/web/.noix-roundcube-fresh"
  hx touch -d '3 hours ago' "$dir/data/web/.noix-roundcube-old"
  hx cp "$last" /root/last-backup.saved
  hx rm "$last"
  play_fails rc-unreachable "$here/converge.yml" -e mailcow_roundcube_api_url=http://127.0.0.1:9
  expect_in_log rc-unreachable "Could not read Roundcube's releases from http://127.0.0.1:9/releases"
  [ "$(backup_folders)" = $((folders + 1)) ] || fail "the first backup was not made despite the failed release list"
  hx test -s "$last" || fail "the first backup was not recorded"
  hx test ! -e "$dir/data/web/.noix-roundcube-old" || fail "the old work directory was not removed"
  hx test -d "$dir/data/web/.noix-roundcube-fresh" || fail "a recent work directory was removed"
  hx rmdir "$dir/data/web/.noix-roundcube-fresh"
  folders="$(backup_folders)"

  echo "   mailcow_roundcube_update: false leaves Roundcube alone"
  play_ok rc-disabled "$here/converge.yml" -e '{"mailcow_roundcube_update": false}'
  expect_unchanged rc-disabled
  [ "$(fact rc-disabled roundcube_new)" = False ] || fail "mailcow_roundcube_updated is not false when the update is off"
  [ "$(rc_version)" = 1.7.5 ] || fail "Roundcube was updated although mailcow_roundcube_update is false"
  [ "$(backup_folders)" = "$folders" ] || fail "a disabled update made a backup"
  hx test ! -e "$rc_calls" || fail "Roundcube's tools ran although the update is off"

  echo "   a release that needs a newer PHP than php-fpm-mailcow has is only reported"
  rc_fake stub 1.7.6:php8.9 1.7.5
  play_ok rc-php "$here/converge.yml"
  expect_in_log rc-php "Roundcube 1.7.6 (newest release of the 1.7 series) needs PHP >=8.9, but php-fpm-mailcow runs PHP 8.2.35"
  expect_unchanged rc-php
  [ "$(rc_version)" = 1.7.5 ] || fail "Roundcube was updated despite its PHP requirement"
  [ "$(fact rc-php roundcube_new)" = False ] || fail "mailcow_roundcube_updated is not false"
  [ "$(backup_folders)" = "$folders" ] || fail "an unsatisfied PHP requirement made a backup"
  hx test ! -e "$rc_calls" || fail "Roundcube's tools ran despite the PHP requirement"
  hx test ! -e /var/lib/noix-mailcow/update-failed || fail "an unsatisfied PHP requirement wrote the marker"
  [ -z "$(rc_leftovers)" ] || fail "the check left its work directory: $(rc_leftovers)"
  play_ok rc-php-again "$here/converge.yml"
  expect_unchanged rc-php-again

  echo "   the newest release of the series is installed after a backup, a newer series is reported"
  # A constraint the role cannot read does not block, but is reported.
  rc_fake stub 1.8.0 "1.7.6:php=>=8.1 !=8.4" 1.7.5
  php_started="$(rc_php_started)"
  play_ok rc-update "$here/converge.yml"
  expect_in_log rc-update "not read: !=8.4"
  expect_in_log rc-update "Roundcube 1.8.0 is out, a newer series than the 1.7"
  [ "$(rc_version)" = 1.7.6 ] || fail "Roundcube was not updated: $(rc_version)"
  [ "$(fact rc-update roundcube_new)" = True ] || fail "mailcow_roundcube_updated is not true"
  [ "$(fact rc-update updated)" = False ] || fail "mailcow reported an update"
  [ "$(rc_config_sum)" = "$config_sum" ] || fail "config/config.inc.php changed"
  [ "$(backup_folders)" = $((folders + 1)) ] || fail "the update did not make exactly one backup"
  hx grep -qx 'reason: update' "$last" || fail "the backup before the update is not recorded as one"
  [ "$(rc_backed_up_version)" = 1.7.5 ] || fail "the backup does not hold Roundcube 1.7.5: $(rc_backed_up_version)"
  hx grep -qx 'apk add --no-cache rsync' "$rc_calls" || fail "rsync was not added: $(hx cat "$rc_calls")"
  hx grep -qx 'php bin/installto.sh -y /web/rc' "$rc_calls" || fail "installto.sh did not run as the guide says: $(hx cat "$rc_calls")"
  hx grep -qx 'composer update --no-dev -o --no-interaction' "$rc_calls" || fail "composer did not run: $(hx cat "$rc_calls")"
  [ "$(rc_php_started)" != "$php_started" ] || fail "php-fpm-mailcow was not restarted"
  [ -z "$(rc_leftovers)" ] || fail "the update left its work directory: $(rc_leftovers)"
  verify
  expect_idempotent
  [ "$(backup_folders)" = $((folders + 1)) ] || fail "the repeated converge made a backup"

  echo "   one backup covers a mailcow and a Roundcube update in one run"
  folders="$(backup_folders)"
  rc_fake stub "1.7.7:php=8.1 - 8.4" 1.7.6
  release 2
  play_ok rc-both "$here/converge.yml"
  expect_in_log rc-both "not read: 8.1 - 8.4"
  [ "$(stub_version)" = 2 ] || fail "the stub was not updated"
  [ "$(rc_version)" = 1.7.7 ] || fail "Roundcube was not updated: $(rc_version)"
  [ "$(fact rc-both updated)" = True ] || fail "mailcow_updated is not true"
  [ "$(fact rc-both roundcube_new)" = True ] || fail "mailcow_roundcube_updated is not true"
  [ "$(backup_folders)" = $((folders + 1)) ] || fail "two updates in one run did not share one backup"
  [ "$(rc_backed_up_version)" = 1.7.6 ] || fail "the backup does not hold Roundcube 1.7.6: $(rc_backed_up_version)"
  [ "$(fact rc-both last_backup)" = "$(last_folder)" ] || fail "mailcow_last_backup is not the shared backup"
  hx test ! -e "$marker" || fail "two successful updates left the marker"
  expect_idempotent

  echo "   a failing install step names the step and the backup, writes the marker and stops the next run"
  rc_fake stub 1.7.8 1.7.7
  hx touch "$flags/rc-composer-fails"
  folders="$(backup_folders)"
  calls="$(rc_call_count)"
  play_fails rc-composer "$here/converge.yml"
  expect_in_log rc-composer "The Roundcube update from 1.7.7 to 1.7.8 in $dir/data/web/rc failed at the step"
  expect_in_log rc-composer "Run composer update --no-dev -o in php-fpm-mailcow"
  expect_in_log rc-composer "The backup taken before the update is $(last_folder)"
  expect_in_log rc-composer "does not run again until /var/lib/noix-mailcow/update-failed is removed"
  [ "$(backup_folders)" = $((folders + 1)) ] || fail "the failed update did not make exactly one backup"
  hx grep -qx "backup: $(last_folder)" /var/lib/noix-mailcow/update-failed || fail "the marker does not name the backup"
  hx grep -q '^failed_step: "Roundcube 1.7.7 to 1.7.8, step ' /var/lib/noix-mailcow/update-failed \
    || fail "the marker does not name the Roundcube step: $(hx cat /var/lib/noix-mailcow/update-failed)"
  hx grep -q 'Run composer update --no-dev -o in php-fpm-mailcow' /var/lib/noix-mailcow/update-failed || fail "the marker does not name the failed step"
  [ -z "$(rc_leftovers)" ] || fail "the failed update left its work directory: $(rc_leftovers)"
  calls_after="$(rc_call_count)"
  play_fails rc-composer-again "$here/converge.yml"
  expect_in_log rc-composer-again "update-failed exists"
  expect_in_log rc-composer-again "Roundcube 1.7.7 to 1.7.8"
  expect_unchanged rc-composer-again
  [ "$(rc_call_count)" = "$calls_after" ] || fail "Roundcube's tools ran despite the marker"
  [ "$calls_after" -gt "$calls" ] || fail "the failed update ran no tools"
  hx rm /var/lib/noix-mailcow/update-failed "$flags/rc-composer-fails"

  echo "   a failing installto.sh names the step and the backup and writes the marker"
  rc_fake stub 1.7.9 1.7.8
  hx touch "$flags/rc-install-fails"
  folders="$(backup_folders)"
  play_fails rc-installto "$here/converge.yml"
  expect_in_log rc-installto "The Roundcube update from 1.7.8 to 1.7.9 in $dir/data/web/rc failed at the step"
  expect_in_log rc-installto "Run bin/installto.sh of the release in php-fpm-mailcow"
  expect_in_log rc-installto "rsync -aC program/"
  expect_in_log rc-installto "The backup taken before the update is $(last_folder)"
  [ "$(backup_folders)" = $((folders + 1)) ] || fail "the failed installto.sh did not make exactly one backup"
  [ "$(rc_version)" = 1.7.8 ] || fail "a failing installto.sh changed the version: $(rc_version)"
  hx grep -q '^failed_step: "Roundcube 1.7.8 to 1.7.9, step ' /var/lib/noix-mailcow/update-failed \
    || fail "the marker does not name the Roundcube step: $(hx cat /var/lib/noix-mailcow/update-failed)"
  [ -z "$(rc_leftovers)" ] || fail "the failed update left its work directory: $(rc_leftovers)"
  hx rm /var/lib/noix-mailcow/update-failed "$flags/rc-install-fails"

  echo "   a /rc/ that does not answer after the update fails the run and writes the marker"
  rc_fake stub 1.7.9 1.7.8
  hx touch "$flags/rc-breaks"
  play_fails rc-broken "$here/converge.yml" -e mailcow_health_timeout=20
  expect_in_log rc-broken "Roundcube: https://127.0.0.1:443/rc/ (Host mail.example.test) answered 500, not 200"
  expect_in_log rc-broken "Fail when mailcow or Roundcube is unhealthy after the update"
  expect_in_log rc-broken "The backup taken before the update is $(last_folder)"
  hx grep -q '^failed_step: "Roundcube 1.7.8 to 1.7.9, step ' /var/lib/noix-mailcow/update-failed \
    || fail "the marker does not name the Roundcube step: $(hx cat /var/lib/noix-mailcow/update-failed)"
  [ -z "$(rc_leftovers)" ] || fail "the failed update left its work directory: $(rc_leftovers)"
  hx rm /var/lib/noix-mailcow/update-failed "$flags/rc-breaks"
}

# Test clients outside Docker: network namespaces on the host, each behind a
# veth pair, so their requests reach mailcow as a tailnet or internet
# client's do: to an address of the host, through Docker's DNAT of the
# published port, from their own address.
#   allowed  10.99.0.5, fd00:99::5 (mailcow_admin_allow in vars.yml)
#   outside  192.0.2.10, 2001:db8::10 (public) and 192.168.77.10,
#            fd00:77::10 (private, so mailcow's nginx believes their
#            X-Forwarded-For)
add_clients() {
  hx bash -euc '
    ip netns add allowed
    ip link add noix-allowed type veth peer name eth0 netns allowed
    ip addr add 10.99.0.1/16 dev noix-allowed
    ip addr add fd00:99::1/64 dev noix-allowed nodad
    ip -n allowed addr add 10.99.0.5/16 dev eth0
    ip -n allowed addr add fd00:99::5/64 dev eth0 nodad
    ip netns add outside
    ip link add noix-outside type veth peer name eth0 netns outside
    ip addr add 192.0.2.1/24 dev noix-outside
    ip addr add 192.168.77.1/24 dev noix-outside
    ip addr add 2001:db8::1/64 dev noix-outside nodad
    ip addr add fd00:77::1/64 dev noix-outside nodad
    ip -n outside addr add 192.0.2.10/24 dev eth0
    ip -n outside addr add 192.168.77.10/24 dev eth0
    ip -n outside addr add 2001:db8::10/64 dev eth0 nodad
    ip -n outside addr add fd00:77::10/64 dev eth0 nodad
    for ns in allowed outside; do
      ip link set "noix-$ns" up
      ip -n "$ns" link set lo up
      ip -n "$ns" link set eth0 up
    done
    ip -n allowed route add default via 10.99.0.1
    ip -n allowed -6 route add default via fd00:99::1
    ip -n outside route add default via 192.0.2.1
    ip -n outside -6 route add default via 2001:db8::1'
}
# request <client> <source address> <path> [curl options]: the status of an
# HTTPS request from that test client to the host; the body goes to
# /tmp/noix-body on the host.
request() {
  local client="$1" source="$2" path="$3" target
  shift 3
  case "$client:$source" in
    allowed:*:*) target='[fd00:99::1]' ;;
    allowed:*) target=10.99.0.1 ;;
    outside:*:*) target='[2001:db8::1]' ;;
    *) target=192.0.2.1 ;;
  esac
  hx ip netns exec "$client" curl -sk -m 120 --interface "$source" -o /tmp/noix-body -w '%{http_code}' \
    -H 'Host: mail.example.test' "$@" "https://$target$path" || true
}
# expect_status <status> <client> <source address> <path> [curl options]
expect_status() {
  local want="$1" got
  shift
  got="$(request "$@")"
  [ "$got" = "$want" ] || fail "$*: answered $got, not $want"
}
# expect_page <status> <client> <source address> <path> [curl options]:
# that status with the noix page for it.
expect_page() {
  expect_status "$@"
  hx grep -qF "data-code=\"$1\"" /tmp/noix-body || fail "${*:2}: the $1 answer is not the noix page"
}
# expect_own <status> <client> <source address> <path> [curl options]: that
# status with mailcow's own answer, not a noix page.
expect_own() {
  expect_status "$@"
  no_match "${*:2}: the $1 answer is a noix page, not mailcow's own" -qF 'ep-theme-' /tmp/noix-body
}
# expect_open <path> [curl options]: an outside client gets the same answer
# as an allowed one, over IPv4 and IPv6 (whatever mailcow itself answers
# without a login), so the restriction leaves the path alone.
expect_open() {
  local path="$1" pair inside outside got_in got_out
  shift
  for pair in "10.99.0.5 192.0.2.10" "fd00:99::5 2001:db8::10"; do
    read -r inside outside <<<"$pair"
    got_in="$(request allowed "$inside" "$path" "$@")"
    got_out="$(request outside "$outside" "$path" "$@")"
    [ "$got_out" != 000 ] || fail "$outside $path: no answer"
    [ "$got_out" = "$got_in" ] || fail "$path: $outside got $got_out, the allowed $inside $got_in"
  done
}
nginx_test() { hx bash -c "cd $dir && docker compose exec -T nginx-mailcow nginx -t" >"$out/nginx-t.log" 2>&1 || { cat "$out/nginx-t.log" >&2; fail "nginx -t fails in nginx-mailcow"; }; }
nginx_started() { hx bash -c "docker inspect -f '{{.State.StartedAt}}' \$(cd $dir && docker compose ps -q nginx-mailcow)"; }
marker=/var/lib/noix-mailcow/update-failed
nginx_previous=/var/lib/noix-mailcow/nginx-previous
nginx_pending=/var/lib/noix-mailcow/nginx-restart-pending
ipv6_enabled() { hx grep -qx 'ENABLE_IPV6=true' "$dir/mailcow.conf"; }
# The role's nginx files in place, accepted by nginx and invisible to Git,
# and the restriction working from both sides.
check_nginx() {
  hx test -s "$dir/data/conf/nginx/noix.conf" || fail "$1: data/conf/nginx/noix.conf is missing"
  hx test -s "$dir/data/conf/nginx/site.noix.custom" || fail "$1: data/conf/nginx/site.noix.custom is missing"
  hx test -s "$dir/data/conf/nginx/noix-error-pages/current/pages/en/403.html" || fail "$1: the error pages are missing"
  nginx_test
  [ -z "$(hx git -C "$dir" status --porcelain --untracked-files=all -- data/conf/nginx)" ] \
    || fail "$1: git status shows the role's files: $(hx git -C "$dir" status --porcelain --untracked-files=all -- data/conf/nginx)"
  expect_page 403 outside 192.0.2.10 /admin/
  expect_page 403 outside 2001:db8::10 /rspamd/ -H 'X-Forwarded-For: 10.99.0.5'
  expect_status 200 allowed 10.99.0.5 /admin/
  if ipv6_enabled; then
    expect_status 200 allowed fd00:99::5 /rspamd/
  else
    # Without IPv6 in mailcow, Docker's userland proxy carries IPv6
    # connections and nginx sees the bridge's address: refused, even from
    # the allowed network.
    expect_page 403 allowed fd00:99::5 /admin/
  fi
}

# Anubis (anubis.yml: the anubis role in nginx mode, then mailcow with
# anubis-vars.yml). The browser stand-in of the anubis suite (solve.py) runs
# in a test client's network namespace.
browser_ua='Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0'
anubis=noixdev-anubis
override_marker='# Written by the noixdev.infra.mailcow role (mailcow_anubis_url).'
# browser <client> <source address> <command> <path> [solve.py options]:
# solve.py from that test client to the host, as request() connects.
browser() {
  local client="$1" source="$2" command="$3" path="$4" target
  shift 4
  case "$client:$source" in
    allowed:*:*) target=fd00:99::1 ;;
    allowed:*) target=10.99.0.1 ;;
    outside:*:*) target=2001:db8::1 ;;
    *) target=192.0.2.1 ;;
  esac
  docker exec -i "$host" ip netns exec "$client" python3 - "$command" "https://mail.example.test$path" \
    --resolve "mail.example.test=$target" --source "$source" "$@" <"$tests/anubis/solve.py"
}
# expect_browser <want> <client> <source address> <path> [solve.py options]:
# the probe's "<status> <kind>" (kind challenge: Anubis's page, with 401).
expect_browser() {
  local want="$1" got
  shift
  got="$(browser "$1" "$2" probe "${@:3}")"
  [ "$got" = "$want" ] || fail "browser probe $*: got '$got', expected '$want'"
}
# no_match <message> <grep options and arguments...>: grep on the host must
# find nothing (exit 1); a match (0), a missing file (2) or a failed docker
# exec (no exit status at all) fails with the message.
no_match() {
  local msg="$1" got
  shift
  got="$(hx sh -c 'grep "$@"; echo "grep-exit-$?"' sh "$@" 2>&1 | tail -n 1)" || true
  [ "$got" = grep-exit-1 ] || fail "$msg ($got)"
}
# not_challenged <label>: the last request()'s answer (/tmp/noix-body,
# headers in /tmp/noix-headers) is neither Anubis's challenge page nor marked
# as a challenge.
not_challenged() {
  no_match "$1: the answer is Anubis's challenge page" -q anubis_challenge /tmp/noix-body
  no_match "$1: the answer carries the challenge mark" -qi noix-anubis /tmp/noix-headers
}
# expect_unchallenged <path> [curl options]: with a browser's User-Agent an
# outside client gets mailcow's own answer over IPv4 and IPv6: the status
# curl gets (Anubis lets curl through), no challenge page, no challenge mark,
# and on a 401 mailcow's own: WWW-Authenticate: Basic, or the API's JSON
# error. (A challenge is a 401 too, so the status alone would not tell.)
expect_unchallenged() {
  local path="$1" source got_browser got_curl
  shift
  for source in 192.0.2.10 2001:db8::10; do
    got_curl="$(request outside "$source" "$path" "$@")"
    got_browser="$(request outside "$source" "$path" -A "$browser_ua" -D /tmp/noix-headers "$@")"
    case "$got_browser" in 500 | 000) fail "$source $path with a browser's User-Agent: $got_browser" ;; esac
    [ "$got_browser" = "$got_curl" ] || fail "$source $path: a browser got $got_browser, curl $got_curl"
    not_challenged "$source $path"
    if [ "$got_browser" = 401 ] && [[ "$path" == /api/* ]]; then
      hx grep -qF '"msg":"authentication failed"' /tmp/noix-body || fail "$source $path: the 401 is not the API's own"
    elif [ "$got_browser" = 401 ]; then
      hx grep -qi '^WWW-Authenticate: Basic' /tmp/noix-headers \
        || fail "$source $path: the 401 is not mailcow's own (no WWW-Authenticate: Basic): $(hx cat /tmp/noix-headers | tr -d '\r' | tr '\n' '|')"
    fi
  done
}
# expect_unreached <path>: a browser without the cookie gets no 2xx answer.
expect_unreached() {
  local got
  got="$(browser outside 192.0.2.10 probe "$1")"
  [[ "$got" != 2* ]] || fail "browser probe $1 reached mailcow: $got"
}
nginx_on_anubis() {
  hx bash -c "docker inspect -f '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' \$(cd $dir && docker compose ps -q nginx-mailcow)" \
    | grep -qw noixdev-anubis
}
# The role's Anubis wiring in place, accepted by nginx, invisible to Git, and
# challenging a browser on /, /SOGo/ (solved there, then passing elsewhere)
# while the mail paths pass.
check_anubis() {
  hx grep -qxF "$override_marker" "$dir/docker-compose.override.yml" || fail "$1: the compose override is not the role's"
  hx grep -q noix-anubis-check "$dir/data/conf/nginx/site.noix.custom" || fail "$1: site.noix.custom has no Anubis check"
  [ -z "$(hx git -C "$dir" status --porcelain --untracked-files=all -- docker-compose.override.yml data/conf/nginx)" ] \
    || fail "$1: git status shows the role's files"
  nginx_on_anubis || fail "$1: nginx-mailcow is not on Anubis's network"
  nginx_test
  expect_browser "401 challenge" outside 192.0.2.10 /
  expect_browser "401 challenge" outside 192.0.2.10 /SOGo/
  local jar
  jar="/tmp/jar-$1-$RANDOM.json"
  browser outside 192.0.2.10 solve /SOGo/ --jar "$jar" --expect SOGo
  expect_browser "200 backend" outside 192.0.2.10 / --jar "$jar" --expect mailcow
  expect_unchallenged /SOGo/dav/
  expect_unchallenged /Autodiscover/Autodiscover.xml
  expect_unchallenged /Microsoft-Server-ActiveSync
}

start_host
echo "== prepare the host (Docker)"
play "$here/prepare.yml" >"$out/prepare.log" 2>&1 || { cat "$out/prepare.log" >&2; fail "prepare failed"; }
add_clients
# Containers and volumes of an earlier run on cached volumes (they start
# with Docker and create their bind mounts' directories).
hx bash -c 'docker rm -f $(docker ps -aq) >/dev/null 2>&1; docker volume prune -af >/dev/null 2>&1; docker network prune -f >/dev/null 2>&1; true'
# An Anubis container of an earlier run started with Docker and made its
# missing bind-mount sources into directories.
hx rm -rf /opt/anubis
reset_host

echo "== a missing mailcow_backup_dir must be refused before any change"
# Ad hoc, without vars.yml: mailcow_backup_dir is undefined.
if ansible all -i "$here/inventory.yml" -e "test_host=$host" \
  -m ansible.builtin.include_role -a name=noixdev.infra.mailcow >"$out/invalid.log" 2>&1; then
  fail "mailcow ran without mailcow_backup_dir"
fi
expect_in_log invalid "missing required arguments: mailcow_backup_dir"
hx test ! -e "$dir" || fail "the role touched $dir before checking its settings"

echo "== backups on the file system of / must be refused before any change"
hx mkdir -p /srv/mailcow-backups
play_fails on-root "$here/converge.yml" -e mailcow_backup_dir=/srv/mailcow-backups
expect_in_log on-root "mailcow_backup_dir /srv/mailcow-backups is on the same file system as /, /opt"
expect_unchanged on-root
hx test ! -e "$dir" || fail "the refused run cloned mailcow"
hx test ! -e /usr/local/sbin/mailcow-backup || fail "the refused run wrote the backup script"

echo "== backups inside the clone must be refused before any change"
play_fails nested "$here/converge.yml" -e mailcow_backup_dir=$dir/backups -e mailcow_backup_require_mount=false
expect_in_log nested "must not be the same directory or one inside the other"
expect_unchanged nested
hx test ! -e "$dir" || fail "the refused run cloned mailcow"
echo "   also through a symbolic link into the clone"
hx ln -sfn "$dir/backups" /srv/nested-link
play_fails nested-link "$here/converge.yml" -e mailcow_backup_dir=/srv/nested-link -e mailcow_backup_require_mount=false
expect_in_log nested-link "must not be the same directory or one inside the other"
expect_in_log nested-link "$dir/backups"
expect_unchanged nested-link
hx test ! -e "$dir" || fail "the refused run cloned mailcow"
hx rm /srv/nested-link

echo "== an admin allowlist with mailcow's own network or every address must be refused before any change"
play_fails admin-bridge "$here/converge.yml" -e '{"mailcow_admin_allow": ["100.64.0.0/10", "172.16.0.0/12", "::/0", "fd4d:6169:6c63:6f77::1", "000.0.0.0/0", "172.22.01.0/24", "10.99.0.0/33"]}'
expect_in_log admin-bridge "172.16.0.0/12 (overlaps mailcow's network 172.22.1.0/24)"
# Leading zeros: nginx's geo reads 000.0.0.0/0 as every address; such entries
# fail closed, as does a prefix length the address does not allow.
expect_in_log admin-bridge "000.0.0.0/0 (does not parse as a network; write it without leading zeros"
expect_in_log admin-bridge "172.22.01.0/24 (does not parse as a network"
expect_in_log admin-bridge "10.99.0.0/33 (does not parse as a network"
expect_in_log admin-bridge "::/0 (every address)"
expect_in_log admin-bridge "fd4d:6169:6c63:6f77::1 (overlaps mailcow's network fd4d:6169:6c63:6f77::/64)"
! grep -qF "100.64.0.0/10 (" "$out/admin-bridge.log" || fail "the tailnet range was refused"
expect_unchanged admin-bridge
hx test ! -e "$dir" || fail "the refused run cloned mailcow"

echo "== Anubis without its network, with a bad URL or with 401 among the error pages must be refused before any change"
play_fails anubis-no-network "$here/converge.yml" -e "@$here/anubis-vars.yml"
expect_in_log anubis-no-network "The Docker network noixdev-anubis (mailcow_anubis_network) does not exist"
expect_in_log anubis-no-network "Run the anubis role in nginx mode first"
expect_unchanged anubis-no-network
play_fails anubis-bad-url "$here/converge.yml" -e mailcow_anubis_url=https://noixdev-anubis:8923/x
expect_in_log anubis-bad-url "mailcow_anubis_url is empty or Anubis's address on its network"
play_fails anubis-401 "$here/converge.yml" -e "@$here/anubis-vars.yml" -e '{"mailcow_error_pages_codes": [401, 502]}'
expect_in_log anubis-401 "mailcow_error_pages_codes contains 401, which Anubis needs"
expect_unchanged anubis-401
play_fails anubis-proxy-protocol "$here/converge.yml" -e "@$here/anubis-vars.yml" \
  -e '{"mailcow_install_settings": {"SKIP_CLAMD": "y", "NGINX_USE_PROXY_PROTOCOL": "y"}}'
expect_in_log anubis-proxy-protocol "mailcow_anubis_url does not work behind a reverse proxy"
expect_in_log anubis-proxy-protocol "NGINX_USE_PROXY_PROTOCOL=y"
expect_unchanged anubis-proxy-protocol
hx test ! -e "$dir" || fail "the refused run cloned mailcow"

if [ "${STUB_ONLY:-0}" != 1 ]; then
echo "== install"
play_ok install "$here/converge.yml"
expect_in_log install "default admin login (admin / moohoo)"
[ "$(https_status)" = 200 ] || fail "mailcow does not answer over HTTPS after the install"
[ "$(hx git -C "$dir" rev-parse --abbrev-ref HEAD)" = master ] || fail "the install is not on master"
[ "$(fact install updated)" = False ] || fail "a fresh install reported an update"
[ "$(fact install last_backup)" = "$(last_folder)" ] || fail "mailcow_last_backup is not the first backup"
[ "$(backup_folders)" = 1 ] || fail "the install did not make exactly one first backup"
verify
ipv6_enabled || fail "the install has no IPv6 (ENABLE_IPV6 in vars.yml)"
check_nginx install
no_match "the nginx files have Anubis lines without mailcow_anubis_url" \
  -qi anubis "$dir/data/conf/nginx/noix.conf" "$dir/data/conf/nginx/site.noix.custom"
hx test ! -e "$dir/docker-compose.override.yml" || fail "the install wrote a compose override without mailcow_anubis_url"
[ "${RC_REAL_ONLY:-0}" != 1 ] || { rc_real; echo "== the Roundcube scenario of the real mailcow passed"; exit 0; }
if [ "${ANUBIS_REAL_ONLY:-0}" != 1 ]; then

echo "== /admin and /rspamd/ only from the allowed networks, over IPv4 and IPv6"
for path in /admin/ /admin /admin/dashboard /%61dmin/ //admin/ /admin\;x /Admin/ /ADMIN /rspamd/ /rspamd /RSPAMD/ /Rspamd/x; do
  expect_page 403 outside 192.0.2.10 "$path"
done
# Dot segments as sent, not as curl would resolve them.
for path in /x/../admin/ /rspamd/../admin/ /./admin/ /x/%2e%2e/admin/; do
  expect_page 403 outside 192.0.2.10 "$path" --path-as-is
done
for source in 192.0.2.10 192.168.77.10 2001:db8::10 fd00:77::10; do
  for path in /admin/ /rspamd/; do
    expect_page 403 outside "$source" "$path"
    # mailcow's nginx takes the header from private addresses: $remote_addr
    # becomes 10.99.0.5, the address that connected does not.
    expect_page 403 outside "$source" "$path" -H 'X-Forwarded-For: 10.99.0.5'
  done
done
# Over the loopback Docker's userland proxy connects, from the bridge's
# (private) address: the header is believed, the connection is refused.
[ "$(hx curl -sk -o /dev/null -w '%{http_code}' -H 'Host: mail.example.test' -H 'X-Forwarded-For: 10.99.0.5' https://127.0.0.1/admin/)" = 403 ] \
  || fail "a forged X-Forwarded-For over the loopback reached /admin/"
for source in 10.99.0.5 fd00:99::5; do
  expect_status 200 allowed "$source" /admin/
  expect_status 200 allowed "$source" /rspamd/
done
# nginx logs the client's own address, so it reached nginx unchanged. A
# request of its own, looked for until it is in the log: nginx writes the
# line after the answer and Docker's log driver passes it on later still.
# The log goes to a file first: "| grep -q" under pipefail fails when grep
# stops reading before docker has written the whole log (SIGPIPE).
probe="noix-probe-$RANDOM$RANDOM"
expect_status 200 allowed fd00:99::5 "/rspamd/?$probe"
seen=0
for _ in $(seq 30); do
  hx bash -c "cd $dir && docker compose logs --no-log-prefix nginx-mailcow" >"$out/nginx-access.log" 2>/dev/null || true
  if grep -q "^fd00:99::5 .*\"GET /rspamd/?$probe " "$out/nginx-access.log"; then
    seen=1
    break
  fi
  sleep 1
done
[ "$seen" = 1 ] || fail "nginx did not see the allowed IPv6 client's own address (no line for $probe in $out/nginx-access.log)"

echo "== everything else stays open, mailcow's own answers pass unchanged"
for source in 192.0.2.10 2001:db8::10; do
  expect_own 200 outside "$source" /
  expect_own 200 outside "$source" /domainadmin/
  expect_own 200 outside "$source" /SOGo/
done
expect_own 401 outside 192.0.2.10 /SOGo/dav/
expect_own 200 outside 192.0.2.10 /Autodiscover/Autodiscover.xml
# mailcow answers an unauthenticated ActiveSync request itself (403 from its
# auth check, which nginx then shows as a noix page), so these only show that
# the path stays reachable and gets the allowed client's answer; that the
# restriction does not match it rests on its anchored rule (/admin, /rspamd).
expect_open /Microsoft-Server-ActiveSync
expect_open /Microsoft-Server-ActiveSync -X OPTIONS
expect_own 401 outside 192.0.2.10 /api/v1/get/status/version -H 'X-API-Key: not-a-key'
hx grep -qF '"msg":"authentication failed"' /tmp/noix-body || fail "the API did not answer with its own JSON"
hx sh -c "mkdir -p $dir/data/web/.well-known/acme-challenge && echo noix-acme-test >$dir/data/web/.well-known/acme-challenge/noix-test"
expect_own 200 outside 2001:db8::10 /.well-known/acme-challenge/noix-test
hx grep -qx noix-acme-test /tmp/noix-body || fail "the ACME challenge file was not served"
hx rm "$dir/data/web/.well-known/acme-challenge/noix-test"

echo "== nginx's own errors get the noix pages"
expect_page 414 outside 192.0.2.10 "/$(printf '%010000d' 0)" --http1.1
hx bash -c "cd $dir && docker compose stop php-fpm-mailcow" >/dev/null 2>&1
expect_page 502 outside 192.0.2.10 /
expect_page 502 outside 2001:db8::10 / -H 'Accept-Language: de-DE,de;q=0.9'
hx grep -qF '<html lang="de"' /tmp/noix-body || fail "the 502 page is not in the browser's language"
hx bash -c "cd $dir && docker compose start php-fpm-mailcow" >/dev/null 2>&1

echo "== the role's nginx files survive an nginx-mailcow restart"
hx bash -c "cd $dir && docker compose restart nginx-mailcow" >/dev/null 2>&1
wait_https
check_nginx nginx-restart

echo "== an nginx configuration nginx rejects is put back, nginx-mailcow is not restarted"
hx sha256sum "$dir/data/conf/nginx/noix.conf" "$dir/data/conf/nginx/site.noix.custom" >"$out/nginx-files.sha256"
nginx_before="$(nginx_started)"
# An own file that uses the role's variable: fine with the current files,
# rejected by nginx -t once the role's new files (no restriction) drop it.
hx sh -c "echo 'add_header X-Noix-Test \$noix_admin_allowed;' >$dir/data/conf/nginx/site.zz-noix-test.custom"
nginx_test
play_fails nginx-rejected "$here/converge.yml" -e '{"mailcow_admin_allow": []}'
hx rm "$dir/data/conf/nginx/site.zz-noix-test.custom"
expect_in_log nginx-rejected "nginx -t in nginx-mailcow failed with the role's new configuration"
expect_in_log nginx-rejected "noix_admin_allowed"
expect_in_log nginx-rejected "the previous files are back in place"
hx sha256sum "$dir/data/conf/nginx/noix.conf" "$dir/data/conf/nginx/site.noix.custom" | cmp -s - "$out/nginx-files.sha256" \
  || fail "the rejected nginx configuration was left in place"
[ -z "$(hx find "$dir/data/conf/nginx" -maxdepth 1 -name '*~')" ] || fail "backups of the nginx files were left behind"
hx test ! -e "$nginx_pending" || fail "the rejected run left the flag of a pending restart"
hx test ! -e "$nginx_previous" || fail "the rejected run left its copies of the nginx files"
[ "$(nginx_started)" = "$nginx_before" ] \
  || fail "nginx-mailcow was restarted with a rejected configuration"
check_nginx nginx-rejected

echo "== mailcow_admin_allow [] switches the restriction off"
play_ok admin-open "$here/converge.yml" -e '{"mailcow_admin_allow": []}' >/dev/null
nginx_test
no_match "mailcow_admin_allow [] left the restriction in the nginx files" \
  -q 'noix_admin' "$dir/data/conf/nginx/noix.conf" "$dir/data/conf/nginx/site.noix.custom"
for source in 192.0.2.10 2001:db8::10; do
  expect_own 200 outside "$source" /admin/
  expect_own 200 outside "$source" /rspamd/
done
# Back to vars.yml's networks: restricted again.
play_ok admin-restricted "$here/converge.yml" >/dev/null
check_nginx admin-restricted
expect_idempotent

echo "== a clone on another branch than master must be refused before any change"
hx git -C "$dir" checkout -q -b nightly
play_fails nightly "$here/converge.yml"
expect_in_log nightly "is not on mailcow's stable branch master (found nightly)"
expect_unchanged nightly
hx git -C "$dir" checkout -q master
hx git -C "$dir" branch -q -D nightly

rc_real
fi

echo "== Anubis: TRUSTED_PROXIES in mailcow.conf (a reverse proxy) must be refused"
hx cp -p "$dir/mailcow.conf" /root/mailcow.conf.saved
hx bash -euc "if grep -q '^TRUSTED_PROXIES=' $dir/mailcow.conf; then sed -i 's/^TRUSTED_PROXIES=.*/TRUSTED_PROXIES=192.168.1.1/' $dir/mailcow.conf; else echo TRUSTED_PROXIES=192.168.1.1 >>$dir/mailcow.conf; fi"
play_fails anubis-trusted-proxies "$here/converge.yml" -e "@$here/anubis-vars.yml"
expect_in_log anubis-trusted-proxies "mailcow.conf sets TRUSTED_PROXIES=192.168.1.1"
expect_unchanged anubis-trusted-proxies
hx cp -p /root/mailcow.conf.saved "$dir/mailcow.conf"

echo "== Anubis: a compose override that is not the role's must be refused"
hx sh -c "printf 'services: {}\n' >$dir/docker-compose.override.yml"
hx sha256sum "$dir/data/conf/nginx/site.noix.custom" >"$out/anubis-site.sha256"
play_fails anubis-foreign "$here/anubis.yml"
expect_in_log anubis-foreign "docker-compose.override.yml exists and was not written by this role"
hx sha256sum "$dir/data/conf/nginx/site.noix.custom" | cmp -s - "$out/anubis-site.sha256" \
  || fail "the refused run changed site.noix.custom"
[ "$(hx cat "$dir/docker-compose.override.yml")" = 'services: {}' ] || fail "the refused run changed the foreign override"
hx rm "$dir/docker-compose.override.yml"

echo "== Anubis in front of mailcow: the anubis role first, then mailcow"
# An installed mailcow is judged by mailcow.conf alone: TRUSTED_PROXIES in
# mailcow_install_settings (used for an install only) must not refuse the run
# when mailcow.conf has no such line.
stale=()
if ! hx grep -q '^TRUSTED_PROXIES=' "$dir/mailcow.conf"; then
  stale=(-e '{"mailcow_install_settings": {"SKIP_CLAMD": "y", "SKIP_FTS": "y", "SKIP_LETS_ENCRYPT": "y",
    "SKIP_UNBOUND_HEALTHCHECK": "y", "ENABLE_IPV6": "true", "TRUSTED_PROXIES": "192.168.1.1"}}')
else
  echo "   mailcow.conf sets TRUSTED_PROXIES: the stale install setting is not tried"
fi
anubis_started=$(date +%s)
play_ok anubis "$here/anubis.yml" ${stale[@]+"${stale[@]}"}
echo "   converge with Anubis: $(($(date +%s) - anubis_started)) seconds"
check_anubis anubis
check_nginx anubis
hx docker network inspect -f '{{.Internal}}' noixdev-anubis | grep -qx true || fail "Anubis's network is not internal"
expect_idempotent "$here/anubis.yml"

echo "== Anubis: nginx-mailcow off Anubis's network with the override in place is put back by the next run"
# As a recreate that failed or a run that stopped after writing the override
# would leave it.
hx bash -c "docker network disconnect noixdev-anubis \$(cd $dir && docker compose ps -q nginx-mailcow)"
! nginx_on_anubis || fail "nginx-mailcow is still on Anubis's network"
play_ok anubis-heal "$here/anubis.yml"
grep -A1 'Recreate nginx-mailcow with the compose override' "$out/anubis-heal.log" | grep -q '^changed:' \
  || fail "the run did not recreate nginx-mailcow"
nginx_on_anubis || fail "the run did not put nginx-mailcow back on Anubis's network"
expect_browser "401 challenge" outside 192.0.2.10 /SOGo/
expect_idempotent "$here/anubis.yml"

echo "== Anubis: browsers are challenged on /, /SOGo, /rc, /domainadmin, over IPv4 and IPv6"
for source in 192.0.2.10 2001:db8::10; do
  for path in / /SOGo/ /SOGo/so/ /SOGo/so/noix.html /domainadmin/ /rc/ /user /SOGo; do
    expect_browser "401 challenge" outside "$source" "$path"
  done
done
# The page comes at the URL asked for (no redirect), so once solved it leads
# back there with the whole query.
location="$(hx ip netns exec outside curl -sk -o /dev/null -D - -A "$browser_ua" -H 'Host: mail.example.test' \
  'https://192.0.2.1/SOGo/so/?x=1&y=2' | tr -d '\r' | sed -n 's/^[Ll]ocation: //p')"
[ -z "$location" ] || fail "the challenge redirects ($location) instead of answering at the original URL"
expect_browser "401 challenge" outside 192.0.2.10 '/SOGo/so/?x=1&y=2'
[ "$(browser outside 192.0.2.10 redirect '/SOGo/so/?x=1&y=2' --jar /tmp/jar-anubis-query.json)" \
  = '302 https://mail.example.test/SOGo/so/?x=1&y=2' ] || fail "the solved challenge does not lead back with the whole query"
# The challenge carries mailcow's security headers.
[ "$(request outside 192.0.2.10 / -A "$browser_ua" -D /tmp/noix-headers)" = 401 ] || fail "/ did not answer the challenge with 401"
hx grep -q anubis_challenge /tmp/noix-body || fail "the 401 of / is not Anubis's challenge page"
for header in Strict-Transport-Security X-Frame-Options X-Content-Type-Options Referrer-Policy; do
  hx grep -qi "^$header:" /tmp/noix-headers || fail "the challenge lacks $header"
done
jar4=/tmp/jar-anubis-v4.json
jar6=/tmp/jar-anubis-v6.json
hx rm -f "$jar4" "$jar6"
browser outside 192.0.2.10 solve /SOGo/ --jar "$jar4" --expect SOGo
for path in / /domainadmin/ /SOGo/so/; do
  expect_browser "200 backend" outside 192.0.2.10 "$path" --jar "$jar4" --expect "$( [ "$path" = /SOGo/so/ ] && echo SOGo || echo mailcow)"
done
# Roundcube is there unless ANUBIS_REAL_ONLY skipped its scenario.
! hx test -f "$dir/data/web/rc/index.php" || expect_browser "200 backend" outside 192.0.2.10 /rc/ --jar "$jar4" --expect Roundcube
browser outside 2001:db8::10 solve / --jar "$jar6" --expect mailcow
expect_browser "200 backend" outside 2001:db8::10 /SOGo/ --jar "$jar6" --expect SOGo
# Anubis binds the cookie to the address: the IPv4 cookie does not pass over
# IPv6 (a copy: Anubis's page also clears the cookie it refused).
hx cp "$jar4" /tmp/jar-anubis-v4-copy.json
expect_browser "401 challenge" outside 2001:db8::10 /SOGo/ --jar /tmp/jar-anubis-v4-copy.json

echo "== Anubis: mail clients, the API and ACME pass with a browser's User-Agent, in each case mailcow serves"
hx sh -c "mkdir -p $dir/data/web/.well-known/acme-challenge && echo noix-acme-test >$dir/data/web/.well-known/acme-challenge/noix-test"
for path in /SOGo/dav/ /SOGo/dav /SOGo/Microsoft-Server-ActiveSync /Microsoft-Server-ActiveSync \
  /.well-known/caldav /.well-known/carddav \
  /Autodiscover/Autodiscover.xml /autodiscover/autodiscover.xml /AUTODISCOVER/AUTODISCOVER.XML /AutoDiscover/autodiscover.json \
  /mail/config-v1.1.xml /Mail/Config-v1.1.xml /.well-known/autoconfig/mail/config-v1.1.xml \
  /.well-known/acme-challenge/noix-test /.well-known/mta-sts.txt; do
  expect_unchallenged "$path"
done
expect_unchallenged /Microsoft-Server-ActiveSync -X OPTIONS
expect_unchallenged /api/v1/get/status/version -H 'X-API-Key: not-a-key'
expect_own 401 outside 192.0.2.10 /api/v1/get/status/version -A "$browser_ua" -H 'X-API-Key: not-a-key'
hx grep -qF '"msg":"authentication failed"' /tmp/noix-body || fail "the API did not answer with its own JSON"
expect_own 200 outside 2001:db8::10 /.well-known/acme-challenge/noix-test -A "$browser_ua"
hx grep -qx noix-acme-test /tmp/noix-body || fail "the ACME challenge file was not served"
expect_own 401 outside 192.0.2.10 /SOGo/dav/ -A "$browser_ua"
# A wrong password stays mailcow's 401 (nginx's page, the auth check sends no
# WWW-Authenticate), not the challenge, with mailcow's security headers.
for pair in "192.0.2.10 /SOGo/dav/" "2001:db8::10 /SOGo/dav/" "192.0.2.10 /Microsoft-Server-ActiveSync" \
  "2001:db8::10 /Microsoft-Server-ActiveSync"; do
  read -r source path <<<"$pair"
  expect_status 401 outside "$source" "$path" -A "$browser_ua" -u noix@example.test:wrong -D /tmp/noix-headers
  not_challenged "$source $path with a wrong password"
  for header in Strict-Transport-Security X-Frame-Options; do
    hx grep -qi "^$header:" /tmp/noix-headers || fail "$source $path: the wrong-password 401 lacks $header"
  done
done

echo "== Anubis: without the sync rule DAV and ActiveSync are challenged, and the checks above see it"
play_ok anubis-no-sync "$here/anubis.yml" -e "@$here/anubis-no-sync-vars.yml"
for path in /SOGo/dav/ /Microsoft-Server-ActiveSync /SOGo/Microsoft-Server-ActiveSync; do
  expect_browser "401 challenge" outside 192.0.2.10 "$path"
  if (expect_unchallenged "$path") 2>/dev/null; then
    fail "expect_unchallenged $path passed while Anubis challenges it"
  fi
done
play_ok anubis-sync-back "$here/anubis.yml"
expect_unchallenged /SOGo/dav/

echo "== Anubis: the reach check takes a challenge (401) or a denial (403) of its own request as reachable"
# A rule for the check's User-Agent (anubis_test_extra_rules, anubis-vars.yml).
for pair in "CHALLENGE 401" "DENY 403"; do
  read -r action status <<<"$pair"
  play_ok "anubis-reach-$status" "$here/anubis.yml" \
    -e "{\"anubis_test_extra_rules\": [{\"name\": \"reach-probe\", \"action\": \"$action\", \"user_agent_regex\": \"^noix-mailcow-check\$\"}]}"
  reach="$(hx bash -c "cd $dir && docker compose exec -T nginx-mailcow wget -q -O /dev/null -T 5 -U noix-mailcow-check \
    --header 'X-Real-IP: 127.0.0.1' http://noixdev-anubis:8923/.within.website/x/cmd/anubis/api/check 2>&1" || true)"
  [[ "$reach" == *"HTTP/1."?" $status"* ]] || fail "with a $action rule for its User-Agent the reach check did not get $status: $reach"
done
play_ok anubis-reach-back "$here/anubis.yml"
expect_idempotent "$here/anubis.yml"

echo "== Anubis: the admin restriction comes first, Anubis's own paths are open, DENY gets the noix page"
for source in 192.0.2.10 2001:db8::10; do
  expect_page 403 outside "$source" /admin/ -A "$browser_ua"
  expect_page 403 outside "$source" /rspamd/ -A "$browser_ua"
done
# The admins' networks pass by the policy's IP rule (anubis-vars.yml), also
# on /SOGo through mailcow's SOGo auth check.
for source in 10.99.0.5 fd00:99::5; do
  expect_own 200 allowed "$source" /admin/ -A "$browser_ua"
  expect_own 200 allowed "$source" /SOGo/ -A "$browser_ua"
done
for client in "outside 192.0.2.10" "outside 2001:db8::10" "allowed 10.99.0.5"; do
  read -r who source <<<"$client"
  expect_status 200 "$who" "$source" /.within.website/x/xess/xess.min.css -A "$browser_ua"
  expect_status 200 "$who" "$source" /.within.website/x/cmd/anubis/static/js/main.mjs -A "$browser_ua"
done
# An empty User-Agent: Anubis's default policy denies it (403).
expect_page 403 outside 192.0.2.10 / -A ''

echo "== Anubis: an address claimed with X-Forwarded-For does not pass the admins' IP rule"
# mailcow's nginx believes the header from private addresses; Anubis gets the
# address that connected. /SOGo and ActiveSync, which mailcow's SOGo auth
# check asks with mailcow's $remote_addr, refuse such requests.
expect_browser "401 challenge" outside 192.168.77.10 / --header X-Forwarded-For:10.99.0.5
expect_browser "401 challenge" outside fd00:77::10 / --header X-Forwarded-For:fd00:99::5
expect_browser "401 challenge" outside 192.0.2.10 / --header X-Forwarded-For:10.99.0.5
expect_browser "401 challenge" outside 192.0.2.10 /SOGo/ --header X-Forwarded-For:10.99.0.5
for path in /SOGo/ /Microsoft-Server-ActiveSync; do
  expect_page 403 outside 192.168.77.10 "$path" -A "$browser_ua" -H 'X-Forwarded-For: 10.99.0.5'
  expect_page 403 outside fd00:77::10 "$path" -A "$browser_ua" -H 'X-Forwarded-For: fd00:99::5'
done
# Without the header the same private client is challenged as anyone.
expect_browser "401 challenge" outside 192.168.77.10 /SOGo/

echo "== Anubis: client-sent forwarding headers and path tricks do not get past the check"
for path in / /SOGo/; do
  for header in X-Original-Uri:/api/v1/x X-Forwarded-Uri:/api/v1/x X-Original-URI:/SOGo/dav/ \
    X-Real-IP:10.99.0.5 X-Forwarded-For:203.0.113.9 X-Forwarded-For:10.99.0.5 X-Forwarded-Host:evil.test; do
    expect_browser "401 challenge" outside 192.0.2.10 "$path" --header "$header"
    expect_browser "401 challenge" outside 2001:db8::10 "$path" --header "$header"
  done
done
for path in //SOGo/ //SOGo/so/ /api/v1/../../SOGo/ /api/v1/%2e%2e/%2e%2e/SOGo/ /api/v1/..%2F..%2FSOGo/ \
  /.well-known/acme-challenge/../../ /.well-known/acme-challenge/%2e%2e/%2e%2e/SOGo/ \
  /Microsoft-Server-ActiveSync/../SOGo/ /SOGo/dav/../ /SOGo/dav/%2e%2e/ /SOGo/dav/../so/ \
  /.within.website/../SOGo/ /.within.website/x/cmd/anubis/static/../../../../../ /api/v1//../../ \
  "/Autodiscover/Autodiscover.xml/../../SOGo/"; do
  expect_unreached "$path"
done
statuses=""
for path in //SOGo/ /api/v1/../../SOGo/ /api/v1/%2e%2e/%2e%2e/SOGo/ /SOGo/dav/../; do
  statuses="$statuses $path=$(browser outside 192.0.2.10 probe "$path" | cut -d' ' -f1)"
done
echo "   path tricks answered:$statuses"

echo "== Anubis stopped: every checked request fails closed, nginx -t and a restart still work"
hx docker stop "$anubis" >/dev/null
down=""
for path in / /SOGo/ /rc/; do
  got="$(browser outside 192.0.2.10 probe "$path" --jar "$jar4")"
  down="$down $path=${got%% *}"
  [ "${got%% *}" = 500 ] || fail "$path with a valid cookie answered '$got' while Anubis is down, expected 500"
done
for path in / /SOGo/ /SOGo/dav/ /Microsoft-Server-ActiveSync /Autodiscover/Autodiscover.xml /api/v1/get/status/version \
  /.well-known/acme-challenge/noix-test /mail/config-v1.1.xml; do
  got="$(request outside 192.0.2.10 "$path")"
  down="$down curl:$path=$got"
  [ "$got" = 500 ] || fail "curl $path answered $got while Anubis is down, expected 500"
done
expect_page 502 outside 192.0.2.10 /.within.website/x/xess/xess.min.css
expect_page 403 outside 192.0.2.10 /admin/
echo "   Anubis down:$down"
nginx_test
hx bash -c "cd $dir && docker compose restart nginx-mailcow" >/dev/null 2>&1
for _ in $(seq 60); do
  hx bash -c "cd $dir && docker compose exec -T nginx-mailcow test -s /var/run/nginx.pid" 2>/dev/null && break
  sleep 2
done
[ "$(https_status)" = 500 ] || fail "nginx-mailcow did not start again without Anubis (HTTPS answered $(https_status))"
# The mailcow role alone names it.
hx sha256sum "$dir/data/conf/nginx/noix.conf" "$dir/data/conf/nginx/site.noix.custom" >"$out/anubis-down.sha256"
play_fails anubis-down "$here/converge.yml" -e "@$here/anubis-vars.yml"
expect_in_log anubis-down "nginx-mailcow does not reach Anubis at http://noixdev-anubis:8923"
hx sha256sum "$dir/data/conf/nginx/noix.conf" "$dir/data/conf/nginx/site.noix.custom" | cmp -s - "$out/anubis-down.sha256" \
  || fail "the run without Anubis changed the nginx files"
# The anubis role starts it again; the cookie from before passes.
play_ok anubis-back "$here/anubis.yml"
expect_browser "200 backend" outside 192.0.2.10 /SOGo/ --jar "$jar4" --expect SOGo
expect_idempotent "$here/anubis.yml"
hx rm "$dir/data/web/.well-known/acme-challenge/noix-test"

echo "== Anubis after docker compose down and up, also with mailcow's network recreated (ENABLE_IPV6 switched)"
# The network nginx-mailcow joins for Anubis is not mailcow's: compose can
# remove and recreate mailcow's own network, which a foreign container on it
# would block ("has active endpoints").
for ipv6 in false true; do
  hx bash -euc "cd $dir && docker compose down && sed -i 's/^ENABLE_IPV6=.*/ENABLE_IPV6=$ipv6/' mailcow.conf && docker compose up -d --quiet-pull" \
    >"$out/anubis-down-up.log" 2>&1 || { cat "$out/anubis-down-up.log" >&2; fail "mailcow did not come up again (ENABLE_IPV6=$ipv6)"; }
  wait_https
  nginx_on_anubis || fail "nginx-mailcow is not on Anubis's network after docker compose up (ENABLE_IPV6=$ipv6)"
  [ "$(hx docker network inspect -f '{{.EnableIPv6}}' mailcowdockerized_mailcow-network)" = "$ipv6" ] \
    || fail "mailcow's network was not recreated with ENABLE_IPV6=$ipv6"
  expect_browser "401 challenge" outside 192.0.2.10 /SOGo/
  expect_browser "200 backend" outside 192.0.2.10 /SOGo/ --jar "$jar4" --expect SOGo
  expect_unchallenged /SOGo/dav/
done
expect_idempotent "$here/anubis.yml"

echo "== Anubis switched off: no Anubis lines, no override, nginx-mailcow off its network, no 500 meanwhile"
# curl's answers to / every half second while the run switches Anubis off: a
# check whose Anubis nginx-mailcow cannot reach any more would answer 500
# (000 while nginx-mailcow restarts is fine).
hx rm -f /tmp/noix-off-statuses /tmp/noix-off-stop
hx bash -c "while [ ! -e /tmp/noix-off-stop ]; do curl -sk -m 5 -o /dev/null -w '%{http_code}\n' -H 'Host: mail.example.test' https://127.0.0.1/ >>/tmp/noix-off-statuses; sleep 0.5; done" &
poller=$!
play_ok anubis-off "$here/converge.yml"
hx touch /tmp/noix-off-stop
wait "$poller" || true
off_statuses="$(hx sort /tmp/noix-off-statuses | uniq -c | tr -s ' \n' ' ')"
echo "   answers while switching off:$off_statuses"
hx grep -qx 200 /tmp/noix-off-statuses || fail "the poll while switching Anubis off saw no 200 at all"
no_match "a request answered 500 while Anubis was switched off ($off_statuses)" -qx 500 /tmp/noix-off-statuses
# The nginx files without Anubis are restarted before the override goes and
# nginx-mailcow leaves Anubis's network.
restart_line="$(grep -n 'TASK \[noixdev.infra.mailcow : Restart nginx-mailcow\]' "$out/anubis-off.log" | cut -d: -f1)"
remove_line="$(grep -n "TASK \[noixdev.infra.mailcow : Remove the role's compose override\]" "$out/anubis-off.log" | cut -d: -f1)"
recreate_line="$(grep -n 'TASK \[noixdev.infra.mailcow : Recreate nginx-mailcow with the compose override\]' "$out/anubis-off.log" | cut -d: -f1)"
if ! { [ -n "$restart_line" ] && [ -n "$remove_line" ] && [ -n "$recreate_line" ] \
  && [ "$restart_line" -lt "$remove_line" ] && [ "$remove_line" -lt "$recreate_line" ]; }; then
  fail "switching Anubis off did not restart nginx with the new files before removing the override and recreating (lines $restart_line, $remove_line, $recreate_line)"
fi
for task in "Restart nginx-mailcow" "Remove the role's compose override" "Recreate nginx-mailcow with the compose override"; do
  grep -A1 -F "TASK [noixdev.infra.mailcow : $task]" "$out/anubis-off.log" | grep -q '^changed:' \
    || fail "switching Anubis off did not run: $task"
done
no_match "mailcow_anubis_url \"\" left Anubis lines in the nginx files" \
  -qi anubis "$dir/data/conf/nginx/noix.conf" "$dir/data/conf/nginx/site.noix.custom"
hx test ! -e "$dir/docker-compose.override.yml" || fail "mailcow_anubis_url \"\" left the compose override"
! nginx_on_anubis || fail "nginx-mailcow is still on Anubis's network"
expect_own 200 outside 192.0.2.10 / -A "$browser_ua"
expect_own 200 outside 2001:db8::10 /SOGo/ -A "$browser_ua"
check_nginx anubis-off
expect_idempotent

echo "== takeover of the previous release with the documentation's cron script"
reset_host
hx git clone -q https://github.com/mailcow/mailcow-dockerized.git "$dir"
older="${MAILCOW_TAKEOVER_TAG:-$(hx bash -c "cd $dir && head=\$(git rev-parse HEAD) && for t in \$(git tag --merged HEAD --sort=-creatordate); do [ \"\$(git rev-parse \"\$t^{commit}\")\" = \"\$head\" ] || { echo \"\$t\"; break; }; done")}"
[ -n "$older" ] || fail "no release before master's head"
echo "   taking over mailcow $older"
hx git -C "$dir" reset -q --hard "$older"
generate_config
hx bash -c "cd $dir && docker compose up -d --quiet-pull" >"$out/takeover-start.log" 2>&1 \
  || { cat "$out/takeover-start.log" >&2; fail "mailcow $older did not start"; }
wait_https
docs_cron_script
# With Anubis (still running from above): the role's override and nginx files
# are in place before update.sh, which runs docker compose down and up.
play_ok takeover "$here/anubis.yml"
hx test ! -e /etc/cron.daily/mailcow-backup || fail "the documentation's cron script is still there"
[ "$(fact takeover updated)" = True ] || fail "the takeover did not update mailcow"
hx git -C "$dir" merge-base --is-ancestor origin/master HEAD || fail "the clone does not contain origin/master after the update"
[ "$(backup_folders)" = 1 ] || fail "the takeover did not leave exactly one backup"
# The backup came before update.sh's "Before update" commit.
backup_time="$(last_folder | sed -E 's/.*mailcow-([0-9]{4}-[0-9]{2}-[0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2})$/\1 \2:\3:\4/')"
[ "$(hx date -d "$backup_time" +%s)" -le "$(hx git -C "$dir" log -1 --format=%ct --grep='^Before update')" ] \
  || fail "the backup was not made before update.sh ran"
[ "$(https_status)" = 200 ] || fail "mailcow does not answer over HTTPS after the takeover"
verify
# Written before update.sh ran; the repeated converge must not need to
# write them again.
check_nginx takeover
check_anubis takeover
expect_idempotent "$here/anubis.yml"
[ "${ANUBIS_REAL_ONLY:-0}" != 1 ] || { echo "== the Anubis scenarios of the real mailcow passed in $(($(date +%s) - started)) seconds"; exit 0; }
# The stub needs none of mailcow's images; the machine needs the disk back.
if [ -z "${NOIXDEV_INFRA_MAILCOW_DOCKER_VOLUME:-}" ]; then
  reset_host
  hx docker image prune -af >/dev/null
fi
fi

extra_vars=(-e "@$here/stub-vars.yml")
[ "${RC_STUB_ONLY:-0}" != 1 ] || { rc_stub; echo "== the Roundcube scenarios of the stub passed"; exit 0; }

echo "== update.sh asking to be started again is started again"
stub_install
release 2
hx touch "$flags/rerun-once"
play_ok rerun "$here/converge.yml"
[ "$(update_calls)" = "--check --force --force " ] || fail "update.sh calls: $(update_calls)"
[ "$(stub_version)" = 2 ] || fail "the stub was not updated to release 2"
[ "$(fact rerun updated)" = True ] || fail "mailcow_updated is not true after the update"
hx test ! -e "$marker" || fail "a successful update left the marker"
verify
expect_idempotent

echo "== a restart of nginx-mailcow left pending by a stopped run is made by the next run"
# As a run leaves it that stopped after writing the files: the copies of what
# nginx-mailcow runs and the flag outside the clone, a changed file inside.
hx bash -euc "mkdir -p -m 0700 $nginx_previous && cp -p $dir/data/conf/nginx/noix.conf $dir/data/conf/nginx/site.noix.custom $nginx_previous/ && touch $nginx_pending"
hx sh -c "echo '# written by a run that stopped' >>$dir/data/conf/nginx/noix.conf"
nginx_before="$(nginx_started)"
play_ok nginx-pending "$here/converge.yml"
[ "$(nginx_started)" != "$nginx_before" ] || fail "the pending restart of nginx-mailcow was not made"
hx test ! -e "$nginx_pending" || fail "the flag of the pending restart is still there"
hx test ! -e "$nginx_previous" || fail "the copies of the nginx files are still there"
no_match "noix.conf is not the role's" -q 'a run that stopped' "$dir/data/conf/nginx/noix.conf"
expect_idempotent

echo "== a backup directory that is a symbolic link to the backup disk is accepted"
hx ln -sfn "$backups" /srv/backup-link
play_ok backup-link "$here/converge.yml" -e mailcow_backup_dir=/srv/backup-link
hx /usr/local/sbin/mailcow-backup --reason update >"$out/backup-link-script.log" 2>&1 \
  || { cat "$out/backup-link-script.log" >&2; fail "mailcow-backup failed with a linked backup directory"; }
[[ "$(last_folder)" == /srv/backup-link/mailcow-* ]] || fail "the backup through the link is not on record: $(last_folder)"
hx test -s "$(last_folder)/extra-files.tar.gz" || fail "the backup through the link is incomplete"
# Back to the directory itself, with a backup on record there.
play_ok backup-link-back "$here/converge.yml" >/dev/null
sleep 1
hx /usr/local/sbin/mailcow-backup --reason update >/dev/null
hx rm /srv/backup-link
verify

echo "== an update must not run when its backup has no space"
before="$(hx git -C "$dir" rev-parse HEAD)"
hx mount -t tmpfs -o size=8m tmpfs "$backups"
hx mkdir "$backups/mailcow-2026-01-01-00-00-00"
hx sh -c "head -c 5000000 /dev/urandom >$backups/mailcow-2026-01-01-00-00-00/backup_vmail.tar.zst"
hx sh -c "printf 'folder: $backups/mailcow-2026-01-01-00-00-00\ntime: %s\nreason: daily\n' \$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) >$last"
release 3
hx rm -f /var/log/mailcow-stub/update.calls
play_fails no-space "$here/converge.yml"
expect_in_log no-space "No update: the backup before the update failed"
expect_in_log no-space "space check failed"
[ "$(hx git -C "$dir" rev-parse HEAD)" = "$before" ] || fail "the clone changed without a backup"
[ "$(stub_version)" = 2 ] || fail "the stub was updated without a backup"
[ "$(update_calls)" = "--check " ] || fail "update.sh calls without space: $(update_calls)"
hx umount "$backups"

echo "== a failing health check after the update names the step and the backup"
hx touch "$flags/break-after-update"
play_fails health "$here/converge.yml" -e mailcow_health_timeout=20
expect_in_log health "unhealthy after the update"
expect_in_log health "Health step failed: containers"
expect_in_log health "dovecot-mailcow (exited)"
expect_in_log health "The backup taken before the update is $(last_folder)"
expect_in_log health "does not run again until /var/lib/noix-mailcow/update-failed is removed"
[ "$(stub_version)" = 3 ] || fail "the stub was not updated to release 3"
failed_backup="$(last_folder)"
hx grep -qx "backup: $failed_backup" /var/lib/noix-mailcow/update-failed || fail "the marker does not name the backup"
hx grep -q '^failed_step: "health check after the update: containers' /var/lib/noix-mailcow/update-failed \
  || fail "the marker does not name the failed step: $(hx cat /var/lib/noix-mailcow/update-failed)"
hx rm -f "$flags/break-after-update"
hx bash -c "cd $dir && docker compose up -d --quiet-pull" >/dev/null 2>&1

echo "== the marker of the failed update stops the next run and keeps its backup"
release 4
hx rm -f /var/log/mailcow-stub/update.calls
play_fails marker "$here/converge.yml"
expect_in_log marker "/var/lib/noix-mailcow/update-failed exists: an update of mailcow in $dir did not complete (health check after the update: containers"
expect_in_log marker "The backup taken before it is $failed_backup"
expect_in_log marker "rm /var/lib/noix-mailcow/update-failed"
expect_unchanged marker
[ "$(update_calls)" = "" ] || fail "update.sh ran despite the marker: $(update_calls)"
[ "$(stub_version)" = 3 ] || fail "the stub was updated despite the marker"
# Daily backups go on and prune, but never the marker's backup: a control
# copy of it, as old, goes.
set_last_backup_age 13
hx /usr/local/sbin/mailcow-backup --reason daily >/dev/null
hx cp -a "$failed_backup" "$backups/mailcow-2020-01-01-00-00-00"
hx touch -d '5 days ago' "$failed_backup" "$backups/mailcow-2020-01-01-00-00-00"
set_last_backup_age 13
hx /usr/local/sbin/mailcow-backup --reason daily >/dev/null
hx test -d "$failed_backup" || fail "the daily backup pruned the backup of the failed update"
hx test ! -e "$backups/mailcow-2020-01-01-00-00-00" || fail "the daily backup did not prune an old folder"
hx rm /var/lib/noix-mailcow/update-failed
play_ok marker-removed "$here/converge.yml"
[ "$(stub_version)" = 4 ] || fail "the run after removing the marker did not update"
hx test ! -e "$marker" || fail "a successful update left the marker"
expect_idempotent

echo "== update.sh that runs out of time fails with the role's message and leaves the marker"
release 5
hx touch "$flags/update-hangs"
play_fails update-timeout "$here/converge.yml" -e mailcow_update_timeout=15
expect_in_log update-timeout "update.sh --force in $dir did not finish within 15 seconds, so it was stopped"
expect_in_log update-timeout "The backup taken before the update is $(last_folder)"
! grep -Eq "is undefined|has no attribute" "$out/update-timeout.log" || fail "the time limit gave a template error, not the role's message"
hx grep -q '^failed_step: "update.sh --force did not finish within 15 seconds' "$marker" \
  || fail "the marker does not name the time limit: $(hx cat "$marker")"
[ "$(stub_version)" = 4 ] || fail "the stopped update.sh changed the stub"
play_fails update-timeout-again "$here/converge.yml"
expect_in_log update-timeout-again "update-failed exists"
expect_unchanged update-timeout-again
hx rm "$marker"

echo "== a run stopped while update.sh runs leaves the marker, the next run refuses"
hx rm -f /var/log/mailcow-stub/update.calls
# Its own process group, so the whole ansible-playbook goes as when a
# worker or its connection is lost; the job on the host runs on.
set -m
play "$here/converge.yml" >"$out/update-killed.log" 2>&1 &
run_pid=$!
set +m
for _ in $(seq 120); do
  [[ "$(update_calls)" == *--force* ]] && break
  sleep 1
done
[[ "$(update_calls)" == *--force* ]] || { kill -TERM -- "-$run_pid" 2>/dev/null || true; cat "$out/update-killed.log" >&2; fail "update.sh --force did not start"; }
kill -TERM -- "-$run_pid" 2>/dev/null || true
wait "$run_pid" 2>/dev/null || true
hx pkill -f 'update.sh --force' || true
hx pkill -f 'sleep 600' || true
hx test -e "$marker" || fail "the stopped run left no marker"
hx grep -q '^failed_step: "update.sh --force started and did not report back' "$marker" \
  || fail "the marker does not say that update.sh did not report back: $(hx cat "$marker")"
hx grep -qx "backup: $(last_folder)" "$marker" || fail "the marker does not name the backup"
play_fails update-killed-again "$here/converge.yml"
expect_in_log update-killed-again "update-failed exists: an update of mailcow in $dir did not complete (update.sh --force started and did not report back"
expect_unchanged update-killed-again
hx rm "$marker" "$flags/update-hangs"

echo "== a marker that cannot be written stops the update before update.sh"
# A directory where the marker goes: the role cannot write the file.
hx mkdir -p "$marker/blocked"
hx rm -f /var/log/mailcow-stub/update.calls
play_fails marker-unwritable "$here/converge.yml"
expect_in_log marker-unwritable "No update: the role cannot write $marker"
expect_in_log marker-unwritable "before update.sh --force starts"
[ "$(update_calls)" = "--check " ] || fail "update.sh ran without the marker: $(update_calls)"
[ "$(stub_version)" = 4 ] || fail "the stub was updated without the marker"
hx rm -rf "$marker"
play_ok marker-writable "$here/converge.yml"
[ "$(stub_version)" = 5 ] || fail "the stub was not updated to release 5"
hx test ! -e "$marker" || fail "a successful update left the marker"

# conflicting_release: a release and a local edit of the same line.
conflicting_release() {
  hx bash -euc "cd /srv/mailcow-work && sed -i 's/^myhostname = .*/myhostname = upstream.example.test/' data/conf/postfix/main.cf && git commit -qam 'Release 2' && git push -q origin master"
  hx sed -i 's/^myhostname = .*/myhostname = local.example.test/' "$dir/data/conf/postfix/main.cf"
}

echo "== a local change the update replaced (update.sh's merge -Xtheirs) is reported"
stub_install
conflicting_release
play_ok replaced "$here/converge.yml"
expect_in_log replaced "met local changes that conflict with the release in data/conf/postfix/main.cf"
expect_in_log replaced "The backup taken before the update is $(last_folder)"
hx grep -qx 'myhostname = upstream.example.test' "$dir/data/conf/postfix/main.cf" || fail "the release's line is not in main.cf"
hx git -C "$dir" merge-base --is-ancestor origin/master HEAD || fail "the release was not merged"
expect_idempotent

echo "== a merge conflict left unmerged names the file and leaves the tree as it is"
stub_install
conflicting_release
hx touch "$flags/merge-stops"
play_fails conflict "$here/converge.yml"
expect_in_log conflict "left a merge conflict in data/conf/postfix/main.cf"
expect_in_log conflict "The backup taken before the update is $(last_folder)"
[ -n "$(hx git -C "$dir" ls-files --unmerged)" ] || fail "the conflicting file is not left unmerged"
hx test -e /var/lib/noix-mailcow/update-failed || fail "the conflict wrote no marker"
play_fails conflict-again "$here/converge.yml"
expect_in_log conflict-again "update-failed exists"
expect_in_log conflict-again "update.sh left a merge conflict in data/conf/postfix/main.cf"
expect_unchanged conflict-again
hx rm /var/lib/noix-mailcow/update-failed
play_fails conflict-unmerged "$here/converge.yml"
expect_in_log conflict-unmerged "has files with an unresolved merge conflict"
expect_unchanged conflict-unmerged

echo "== a failing backup with old folders and no backup on record changes nothing"
stub_install
# Two complete backups of an old cron script, 5 days old, none on record.
for old in mailcow-2026-01-01-06-25-00 mailcow-2026-01-02-06-25-00; do
  hx bash -c "mkdir $backups/$old && cp $dir/mailcow.conf $backups/$old/ && for c in vmail crypt redis rspamd postfix mariadb; do echo x >$backups/$old/backup_\$c.tar.zst; done && touch -d '5 days ago' $backups/$old"
done
release 2
hx touch "$flags/backup-fails"
play_fails backup-fails "$here/converge.yml"
expect_in_log backup-fails "No update: the backup before the update failed"
expect_in_log backup-fails "backup_and_restore.sh backup all failed (exit 1)"
[ "$(stub_version)" = 1 ] || fail "the stub was updated although its backup failed"
hx test ! -e "$last" || fail "a failed backup was recorded"
[ "$(backup_folders)" = 2 ] || fail "the failed backup left a folder or pruned the old ones: $(hx ls $backups)"
hx rm "$flags/backup-fails"
play_ok backup-fails-then "$here/converge.yml"
[ "$(stub_version)" = 2 ] || fail "the stub was not updated"
[ "$(backup_folders)" = 1 ] || fail "the old folders were not pruned after a successful backup: $(hx ls $backups)"
verify

echo "== a failing update check names it, after the health and backup checks ran"
hx touch "$flags/check-fails"
hx cp "$last" /root/last-backup.saved
set_last_backup_age 30
play_fails check-fails "$here/converge.yml"
expect_in_log check-fails "update.sh --check in $dir failed (exit 99): A problem occurred while trying to fetch the latest revision from github."
expect_in_log check-fails "mailcow : Wait for IMAP over TLS"
expect_in_log check-fails "Also: The last successful mailcow backup"
expect_unchanged check-fails
hx mv /root/last-backup.saved "$last"
hx rm "$flags/check-fails"

echo "== SMTP that does not answer fails the health check without an update, naming the held errors"
# mailcow.conf points the check at a port nothing listens on; the
# containers keep running as they are. A failing update check and an old
# backup in the same run are named in the health failure too.
hx sed -i 's/^SMTP_PORT=.*//' "$dir/mailcow.conf"
hx sh -c "echo SMTP_PORT=2525 >>$dir/mailcow.conf"
hx touch "$flags/check-fails"
hx cp "$last" /root/last-backup.saved
set_last_backup_age 30
play_fails smtp "$here/converge.yml" -e mailcow_health_timeout=10
expect_in_log smtp "mailcow in $dir is unhealthy. Health step failed: SMTP: 127.0.0.1:2525 did not greet with 220"
expect_in_log smtp "Also: update.sh --check in $dir failed (exit 99)"
expect_in_log smtp "Also: The last successful mailcow backup"
expect_unchanged smtp
hx mv /root/last-backup.saved "$last"
hx rm "$flags/check-fails"
hx test ! -e /var/lib/noix-mailcow/update-failed || fail "a health failure without an update wrote the marker"
hx sed -i '/^SMTP_PORT=/d' "$dir/mailcow.conf"

echo "== a backup older than mailcow_backup_max_age_hours must fail a run without an update"
hx cp "$last" /root/last-backup.saved
set_last_backup_age 30
play_fails stale "$here/converge.yml"
expect_in_log stale "is 30.0 hours old, more than mailcow_backup_max_age_hours (26)"
expect_unchanged stale
hx mv /root/last-backup.saved "$last"

echo "== a foreign cron script must be reported and kept"
hx mkdir -p /etc/cron.daily
printf '#!/bin/sh\n# Our own backup\n/opt/mailcow-dockerized/helper-scripts/backup_and_restore.sh backup mysql\n' \
  | hxi sh -c 'cat >/etc/cron.daily/mailcow-backup && chmod 0755 /etc/cron.daily/mailcow-backup'
play_ok foreign-cron "$here/converge.yml"
expect_in_log foreign-cron "is not the backup script from mailcow's documentation, so the role keeps it"
expect_unchanged foreign-cron
hx test -e /etc/cron.daily/mailcow-backup || fail "the foreign cron script was removed"

hx rm /etc/cron.daily/mailcow-backup

echo "== a backup stopped midway leaves no folder and records nothing"
echo 30 | hxi sh -c "cat >$flags/backup-seconds"
set_last_backup_age 13
hx cp "$last" /root/last-backup.before
folders_before="$(backup_folders)"
hx systemctl start --no-block mailcow-backup.service
for _ in $(seq 20); do
  [ "$(backup_folders)" -gt "$folders_before" ] && break
  sleep 0.5
done
[ "$(backup_folders)" -gt "$folders_before" ] || fail "the backup did not start"
hx systemctl stop mailcow-backup.service
[ "$(backup_folders)" = "$folders_before" ] || fail "the stopped backup left its folder: $(hx ls $backups)"
hx cmp -s "$last" /root/last-backup.before || fail "the stopped backup was recorded"
echo 1 | hxi sh -c "cat >$flags/backup-seconds"

echo "== the daily backup running while the run backs up before its update"
stub_install
play_ok concurrent-setup "$here/converge.yml" >/dev/null
# Due for the daily backup, too young for the age check.
set_last_backup_age 13
folders_before="$(backup_folders)"
release 2
# The daily backup holds the lock until the run is waiting for it (no
# timing: on a slow machine the run reached its backup after a 20-second
# daily backup had already finished).
calls_before="$(hx sh -c 'cat /var/log/mailcow-stub/backup.calls 2>/dev/null | wc -l')"
hx touch "$flags/backup-hold"
hx systemctl start --no-block mailcow-backup.service
for _ in $(seq 60); do
  [ "$(hx sh -c 'cat /var/log/mailcow-stub/backup.calls 2>/dev/null | wc -l')" -gt "$calls_before" ] && break
  sleep 1
done
[ "$(hx sh -c 'cat /var/log/mailcow-stub/backup.calls 2>/dev/null | wc -l')" -gt "$calls_before" ] \
  || fail "the daily backup did not start"
play_ok concurrent "$here/converge.yml" -v &
converge=$!
# The run's backup waits in `flock 9` (mailcow-backup's lock); the daily
# backup took the lock with flock --nonblock, which does not linger. The
# role's log shows the message only when the async task ends.
waiting() {
  hx sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\0" " " <"$f" 2>/dev/null; echo; done | grep -qx "flock 9 "'
}
for _ in $(seq 600); do
  waiting && break
  kill -0 "$converge" 2>/dev/null || break
  sleep 1
done
waiting || { hx rm -f "$flags/backup-hold"; wait "$converge" || true; fail "the run's backup never waited for the daily backup"; }
hx rm -f "$flags/backup-hold"
wait "$converge" || fail "converge concurrent failed"
for _ in $(seq 60); do
  [ "$(hx systemctl show -p ActiveState --value mailcow-backup.service)" = inactive ] && break
  sleep 1
done
[ "$(hx systemctl show -p Result --value mailcow-backup.service)" = success ] || fail "the daily backup failed"
hx journalctl -u mailcow-backup.service --no-pager >"$out/concurrent-journal.log"
grep -q "mailcow-backup: done: " "$out/concurrent-journal.log" || fail "the daily backup made no backup"
expect_in_log concurrent "another backup is running; waiting for it to finish"
[ $(($(backup_folders) - folders_before)) -le 2 ] || fail "more than two backups for one daily backup and one update"
[ "$(stub_version)" = 2 ] || fail "the stub was not updated"
verify
echo 1 | hxi sh -c "cat >$flags/backup-seconds"
expect_idempotent

rc_stub

echo "== all mailcow tests passed in $(($(date +%s) - started)) seconds"
