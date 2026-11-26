#!/usr/bin/env bash
# End-to-end test of the watchtower role on a throwaway systemd Ubuntu host
# with Docker (the docker role), one fresh host per scenario group:
#   refusals  bad settings fail before any change;
#   update    a first run without registry credentials (no mount), a login and
#             a second run that mounts them (the container is recreated), an
#             update of the labelled container only (and cleanup of its old
#             image), then a changed registry password: the update fails with
#             the old login and works after a new `docker login`, without
#             running the role again (the config directory is mounted, not the
#             file);
#   settings  the time zone (set, and the host's), the secrets (compose file
#             0600, nothing in a -v log, a value such as 0123 kept as a
#             string), the limits and the network's MTU, absent (twice), and
#             absent over a directory without a compose file.
# Every successful converge is repeated and must change nothing.
#
# The registry (registry:2 with htpasswd) runs in the test host's Docker on
# localhost:5000, which Docker pulls from over plain HTTP without
# insecure-registries. Watchtower's own digest check cannot reach that
# localhost from its container and falls back to a pull by the daemon, with
# the credentials Watchtower read from DOCKER_CONFIG: the update path the
# credentials matter for. Updates are triggered through Watchtower's HTTP
# API (vars.yml), on the container's address in its compose network.
#
# NOIXDEV_INFRA_WATCHTOWER_TESTS selects scenario groups (default: all of
# "refusals update settings").
# The single-quoted scripts expand inside the container, not here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
host="${NOIXDEV_INFRA_WATCHTOWER_TEST_HOST:-noixdev-infra-watchtower-test}"
out="$tests/output/watchtower"
ubuntu=24.04
dir=/opt/watchtower
wt=watchtower-watchtower-1
registry=localhost:5000
token="$(sed -n 's/^  WATCHTOWER_HTTP_API_TOKEN: *//p' "$here/vars.yml")"
user=noix
password1=noix-registry-one
password2=noix-registry-two

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
hxi() { docker exec -i "$host" "$@"; }
play() { ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$@"; }
# converge NAME [ansible args]: the role, which must pass, and again, which
# must change nothing; the first run's output goes to $out/NAME.log.
converge() {
  local name="$1"
  shift
  play "$here/converge.yml" "$@" >"$out/$name.log" 2>&1 || { cat "$out/$name.log" >&2; fail "converge $name failed"; }
  play "$here/converge.yml" "$@" >"$out/$name-again.log" 2>&1 || { cat "$out/$name-again.log" >&2; fail "converge $name failed the second time"; }
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/$name-again.log" \
    || { cat "$out/$name-again.log" >&2; fail "converge $name changed something the second time"; }
}
# refused NAME MESSAGE [ansible args]: the role fails with MESSAGE and changes
# nothing (no directory, no container).
refused() {
  local name="$1" message="$2"
  shift 2
  if play "$here/converge.yml" "$@" >"$out/$name.log" 2>&1; then
    fail "converge $name succeeded but must fail"
  fi
  grep -qF -- "$message" "$out/$name.log" || { cat "$out/$name.log" >&2; fail "$name.log lacks: $message"; }
  ! grep -qF -- "$token" "$out/$name.log" || fail "$name: the API token of watchtower_env is in the log"
  hx test ! -e "$dir" || fail "$name: $dir was created"
  [ -z "$(hx docker ps -aq --filter "name=^$wt\$")" ] || fail "$name: a Watchtower container exists"
  echo "   $name: refused"
}
# The role's environment with these extra entries (JSON members), as one -e.
env_with() { printf '{"watchtower_env": {"WATCHTOWER_HTTP_API_UPDATE": "true", "WATCHTOWER_HTTP_API_TOKEN": "%s", "WATCHTOWER_HTTP_API_PERIODIC_POLLS": "true"%s}}' "$token" "${1:+, $1}"; }

# start_host: a fresh systemd host with Docker; inner Docker on anonymous
# volumes, which "docker rm -v" removes with the host.
start_host() {
  docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd \
    --name "$host" "noixdev-infra-host:$ubuntu" >/dev/null
  until (hx systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
  # The image's policy-rc.d (exit 101) keeps package scripts from starting
  # services; servers have none.
  hx rm -f /usr/sbin/policy-rc.d
  play "$here/prepare.yml" >"$out/prepare.log" 2>&1 || { cat "$out/prepare.log" >&2; fail "prepare failed"; }
}

# The registry with one user (htpasswd, bcrypt) on localhost:5000:
# registry_up PASSWORD. Restarted with the new file on every call.
registry_up() {
  hx mkdir -p /root/registry-auth
  hx sh -c 'htpasswd -Bbn "$1" "$2" >/root/registry-auth/htpasswd' sh "$user" "$1"
  if [ -n "$(hx docker ps -aq --filter name=^registry\$)" ]; then
    hx docker restart registry >/dev/null
  else
    hx docker run -d --name registry --restart unless-stopped -p 127.0.0.1:5000:5000 \
      -v /root/registry-auth:/auth:ro -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=noix \
      -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd registry:2 >/dev/null
  fi
  for _ in $(seq 30); do
    [ "$(hx curl -s -o /dev/null -w '%{http_code}' http://$registry/v2/)" = 401 ] && return 0
    sleep 1
  done
  fail "the registry does not answer on $registry"
}
login() { hx sh -c 'printf "%s" "$3" | docker login -u "$2" --password-stdin "$1"' sh "$registry" "$user" "$1" >/dev/null; }
# push_image NAME VERSION: a tiny image NAME:stable whose label noix.version
# is VERSION, pushed to the registry. It is built here, as noix-build/NAME:
# VERSION; after the push the registry's tag goes back to the version it named
# before (if any), whose build tag goes: as on a server, the new version is in
# the registry only, and the running container's image keeps its one tag
# until Watchtower pulls.
push_image() {
  local before
  before="$(hx docker image inspect -f '{{index .Config.Labels "noix.version"}}' "$registry/$1:stable" 2>/dev/null || true)"
  hxi docker build -q -t "noix-build/$1:$2" - >/dev/null <<EOF
FROM busybox:1.37
LABEL noix.version=$2
CMD ["sleep", "infinity"]
EOF
  hx docker tag "noix-build/$1:$2" "$registry/$1:stable"
  hx docker push -q "$registry/$1:stable" >/dev/null
  if [ -n "$before" ]; then
    hx docker tag "noix-build/$1:$before" "$registry/$1:stable"
    hx docker rmi -f "noix-build/$1:$before" >/dev/null
  fi
}
version_of() { hx docker inspect -f '{{index .Config.Labels "noix.version"}}' "$1"; }
image_of() { hx docker inspect -f '{{.Image}}' "$1"; }
wt_ip() { hx docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$wt"; }
# trigger: one update run through the HTTP API, a POST (it answers when the
# run is over).
trigger() {
  local ip
  ip="$(wt_ip)"
  for _ in $(seq 30); do
    hx curl -fsS -m 300 -X POST -H "Authorization: Bearer $token" "http://$ip:8080/v1/update" >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "Watchtower's HTTP API does not answer on $ip:8080"
}
wt_env() { hx docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$wt"; }
wt_mounts() { hx docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$wt"; }
wt_started() { hx docker inspect -f '{{.State.StartedAt}}' "$wt"; }

test_refusals() {
  echo "== refusals: bad settings fail before any change"
  start_host
  refused version-latest "watchtower_version must look like" -e watchtower_version=latest
  refused version-major "watchtower_version must look like" -e watchtower_version=1
  refused state "watchtower_state" -e watchtower_state=maybe
  refused schedule-5 "watchtower_schedule needs 6 fields" -e '{"watchtower_schedule": "0 5 * * *"}'
  refused zone-unknown "watchtower_timezone must be empty or a zone" -e watchtower_timezone=Not/AZone
  refused zone-path "watchtower_timezone must be empty or a zone" -e watchtower_timezone=../../etc/passwd
  refused env-owned "are none of" -e "$(env_with '"TZ": "UTC"')"
  refused env-key "must be a mapping whose keys match" -e "$(env_with '"lower_case": "x"')"
}

test_update() {
  echo "== update: credentials appear later, the labelled container is updated, a new login is seen without a restart"
  start_host
  registry_up "$password1"
  hx test ! -e /root/.docker || fail "the test host has a Docker config before any login"
  converge no-credentials
  [ "$(wt_mounts)" = "/var/run/docker.sock " ] || fail "without credentials Watchtower mounts: $(wt_mounts)"
  ! wt_env | grep -q '^DOCKER_CONFIG=' || fail "without credentials DOCKER_CONFIG is set"
  started="$(wt_started)"

  login "$password1"
  push_image app 1
  push_image other 1
  converge credentials
  grep -A2 'Start Watchtower' "$out/credentials.log" | grep -q '^changed:' || fail "the run after the login did not recreate Watchtower"
  [ "$(wt_started)" != "$started" ] || fail "Watchtower was not recreated after the login"
  wt_mounts | grep -qw /config || fail "Watchtower does not mount the credentials: $(wt_mounts)"
  wt_env | grep -qx 'DOCKER_CONFIG=/config' || fail "DOCKER_CONFIG is not /config"

  hx docker run -d --name app --label com.centurylinklabs.watchtower.enable=true "$registry/app:stable" >/dev/null
  hx docker run -d --name other "$registry/other:stable" >/dev/null
  old_app="$(image_of app)"
  push_image app 2
  push_image other 2
  trigger
  [ "$(version_of app)" = 2 ] || fail "the labelled container runs version $(version_of app), not 2"
  [ "$(version_of other)" = 1 ] || fail "the unlabelled container was updated to $(version_of other)"
  ! hx docker image inspect "$old_app" >/dev/null 2>&1 || fail "the labelled container's old image is still there (cleanup)"
  echo "   labelled: 2, unlabelled: 1, old image removed"

  # A new version, then the registry's password changes: the login Watchtower
  # reads is the old one, and the update fails.
  push_image app 3
  registry_up "$password2"
  trigger
  [ "$(version_of app)" = 2 ] || fail "the update with the old password worked (version $(version_of app)): the credentials are not used"
  started="$(wt_started)"
  # The Docker CLI writes config.json anew (a temporary file renamed over it).
  ino_before="$(hx stat -c %i /root/.docker/config.json)"
  login "$password2"
  [ "$(hx stat -c %i /root/.docker/config.json)" != "$ino_before" ] \
    || echo "   note: docker login rewrote config.json in place (same inode)"
  trigger
  [ "$(version_of app)" = 3 ] || fail "after the new login the labelled container runs version $(version_of app), not 3"
  [ "$(wt_started)" = "$started" ] || fail "Watchtower restarted for the new login"
  echo "   old password: refused, new login: seen without a restart"
}

test_settings() {
  echo "== settings: time zone, secrets, limits, absent"
  start_host
  converge zone-set -e watchtower_timezone=Europe/Berlin
  wt_env | grep -qx 'TZ=Europe/Berlin' || fail "TZ is not Europe/Berlin: $(wt_env | grep '^TZ=' || true)"
  for _ in $(seq 30); do
    hx docker logs "$wt" 2>&1 | grep -Eq 'Next scheduled run: [0-9-]+ [0-9:]+ CES?T ' && break
    sleep 1
  done
  hx docker logs "$wt" 2>&1 | grep -Eq 'Next scheduled run: [0-9-]+ [0-9:]+ CES?T ' \
    || { hx docker logs "$wt" >&2; fail "Watchtower does not schedule in Berlin's time"; }
  echo "   $(hx docker logs "$wt" 2>&1 | grep -o 'Next scheduled run: [^"]*' | head -1)"

  hx ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
  converge zone-host
  wt_env | grep -qx 'TZ=America/New_York' || fail "TZ is not the host's America/New_York: $(wt_env | grep '^TZ=' || true)"

  [ "$(hx docker inspect -f '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.RestartPolicy.Name}}' "$wt")" \
    = "500000000 134217728 unless-stopped" ] || fail "limits or restart policy: $(hx docker inspect -f '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.RestartPolicy.Name}}' "$wt")"
  [ "$(hx docker network inspect -f '{{index .Options "com.docker.network.driver.mtu"}}' watchtower_default)" = 1500 ] \
    || fail "the network's MTU is not 1500"

  local url='generic+http://127.0.0.1:9/noix-secret-notify-path'
  converge secrets -v -e "{\"watchtower_notification_url\": \"$url\"}" -e "$(env_with '"NOIX_TEST_VALUE": "0123"')"
  [ "$(hx stat -c %a "$dir/compose.yaml")" = 600 ] || fail "compose.yaml is not 0600"
  [ "$(hx stat -c %a "$dir")" = 750 ] || fail "$dir is not 0750"
  for secret in noix-secret-notify-path "$token"; do
    ! grep -qF -- "$secret" "$out/secrets.log" "$out/secrets-again.log" || fail "a secret is in the -v log: $secret"
  done
  wt_env | grep -qx 'NOIX_TEST_VALUE=0123' || fail "0123 did not reach the container as a string"
  wt_env | grep -qx "WATCHTOWER_NOTIFICATION_URL=$url" || fail "the notification URL did not reach the container"

  converge absent -e watchtower_state=absent
  hx test ! -e "$dir" || fail "absent left $dir"
  [ -z "$(hx docker ps -aq --filter "name=^$wt\$")" ] || fail "absent left the container"
  ! hx docker network inspect watchtower_default >/dev/null 2>&1 || fail "absent left the network"

  hx sh -c "mkdir -p $dir && echo stray >$dir/leftover"
  converge absent-stray -e watchtower_state=absent
  hx test ! -e "$dir" || fail "absent left $dir with only a stray file"
}

# All groups by default; NOIXDEV_INFRA_WATCHTOWER_TESTS="update" runs only it.
scenarios="${NOIXDEV_INFRA_WATCHTOWER_TESTS:-refusals update settings}"
for s in $scenarios; do
  case "$s" in
    refusals | update | settings) "test_$s" ;;
    *) fail "unknown scenario group $s (refusals update settings)" ;;
  esac
done
echo "== all watchtower tests passed"
noix_done
