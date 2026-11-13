#!/usr/bin/env bash
# End-to-end test of the anubis role on a throwaway Docker-in-Docker host with
# Traefik from the traefik role and whoami routers on unrelated .test domains
# (converge.yml): the refusals before any change; a first install whose
# settings never get healthy (no Traefik objects); the entrypoint mode (web,
# behind the error pages middlewares) and the per-router mode (opt), each
# solving the challenge once and then passing; a policy ALLOW rule; Anubis's
# own assets; client-sent forwarding headers and path tricks; curl and empty
# User-Agents; the redirect domains; the signing key across a container
# recreate; a stopped Anubis (fail closed, the next converge brings it back);
# a broken policy that must leave the running Anubis serving; a given signing
# key; a basicAuth router's 401 replaced behind anubis@file (the documented
# limitation) and kept without it; and the nginx mode on a second host (its
# own internal network and an extra one, the role's own Traefik file removed
# and a foreign one kept).
# Every successful converge is repeated and must change nothing.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
host="${NOIXDEV_INFRA_ANUBIS_TEST_HOST:-noixdev-infra-anubis-test}"
out="$tests/output/anubis"

cleanup() { [ "${KEEP:-0}" = 1 ] || docker rm -f -v "$host" >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
ln -sfn "$root" "$tests/output/ansible_collections/noixdev/infra"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"
export ANSIBLE_HOST_KEY_CHECKING=False

fail() { echo "$*" >&2; exit 1; }
hx() { docker exec "$host" "$@"; }
play() { ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$@"; }
# The anubis role alone, ad hoc, with vars.yml and the given -e arguments.
role() {
  ansible all -i "$here/inventory.yml" -e "test_host=$host" -e "@$here/vars.yml" "$@" \
    -m ansible.builtin.include_role -a name=noixdev.infra.anubis
}
# A run that must fail; its output goes to $out/<name>.log.
fails() {
  local name="$1"
  shift
  if "$@" >"$out/$name.log" 2>&1; then
    fail "run $name succeeded but must fail"
  fi
}
expect_in_log() {
  grep -qF -- "$2" "$out/$1.log" || { cat "$out/$1.log" >&2; fail "$1.log lacks: $2"; }
}
expect_idempotent() {
  play "$here/converge.yml" "$@" | tee "$out/rerun.log"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/rerun.log" || fail "a repeated converge changed something"
}
untouched() { hx test ! -e /opt/anubis || fail "anubis touched the host before checking its settings"; }

# The browser stand-in on the test host: solve <command> <url> [options].
solve() { docker exec -i "$host" python3 - "$@" <"$here/solve.py"; }
# expect <want> <solve arguments...>: the probe's "<status> <kind>" must be want.
expect() {
  local want="$1" got
  shift
  got="$(solve probe "$@")"
  [ "$got" = "$want" ] || fail "probe $*: got '$got', expected '$want'"
}
jar() { echo "/tmp/jar-$1.json"; }
anubis=noixdev-anubis
health() { hx docker inspect -f '{{.State.Health.Status}}' "$anubis" 2>/dev/null || echo missing; }
started_at() { hx docker inspect -f '{{.State.StartedAt}}' "$anubis"; }
no_check_container() {
  [ -z "$(hx docker ps -aq --filter name=noixdev-anubis-check)" ] || fail "the check container was left behind"
}
# not_backend <solve arguments...>: the probe must not reach whoami.
not_backend() {
  local got
  got="$(solve probe "$@")"
  [ "${got#* }" != backend ] || fail "probe $* reached the backend: $got"
}
wait_healthy() {
  for _ in $(seq 60); do
    [ "$(health)" = healthy ] && return 0
    sleep 1
  done
  fail "anubis is not healthy: $(health)"
}

# A fresh Docker-in-Docker host whose test names resolve to itself.
new_host() {
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  docker run -d --privileged --name "$host" \
    --add-host a.example.test:127.0.0.1 --add-host b.other.test:127.0.0.1 \
    --add-host c.example.test:127.0.0.1 --add-host d.other.test:127.0.0.1 \
    --add-host e.example.test:127.0.0.1 --add-host f.example.test:127.0.0.1 --add-host g.other.test:127.0.0.1 \
    docker:29-dind >/dev/null
  until hx docker info >/dev/null 2>&1; do sleep 1; done
  # Retried: the host's first DNS lookups fail now and then.
  for _ in 1 2 3; do hx apk add --no-cache python3 >/dev/null && return 0; sleep 3; done
  fail "cannot install python3 on the test host"
}
# The role defaults' images, the traefik role's and the fixture's, pulled once.
load_images() {
  local images=() tar
  images+=("$(sed -n 's/^anubis_image: *//p' "$root/roles/anubis/defaults/main.yml")")
  images+=("$(sed -n 's/^traefik_image: *//p' "$root/roles/traefik/defaults/main.yml")")
  images+=("$(sed -n 's/^traefik_socket_proxy_image: *//p' "$root/roles/traefik/defaults/main.yml")")
  images+=("$(sed -n 's/^traefik_error_pages_image: *//p' "$root/roles/traefik/defaults/main.yml")")
  images+=("$(sed -n 's/^fixtures_whoami_image: *//p' "$here/vars.yml")")
  for image in "${images[@]}"; do [ -n "$image" ] || fail "an image name is missing in the defaults"; done
  tar="$out/images-$(printf '%s\n' "${images[@]}" | shasum | cut -c1-12).tar"
  if [ ! -s "$tar" ]; then
    for image in "${images[@]}"; do docker pull -q "$image" >/dev/null; done
    docker save -o "$tar" "${images[@]}"
  fi
  docker exec -i "$host" docker load <"$tar" >/dev/null
}

new_host
load_images

echo "== settings must be refused before any change"
fails mode role -e anubis_mode=bogus
expect_in_log mode "anubis_mode"
untouched
fails redirect role -e '{"anubis_redirect_domains": []}'
expect_in_log redirect "anubis_redirect_domains is required"
untouched
for domains in '["a.example.test,b.other.test"]' '["*"]' '["*.*"]' '["*.test"]'; do
  fails redirect-bad role -e "{\"anubis_redirect_domains\": $domains}"
  expect_in_log redirect-bad "anubis_redirect_domains entries are host names"
  untouched
done
for env in '{"REDIRECT_DOMAINS": ""}' '{"ED25519_PRIVATE_KEY_HEX": "00"}' '{"ed25519_private_key_hex_file": "/x"}' \
  '{"PUBLIC_URL": "https://anubis.example.test"}' '{"TARGET": "http://whoami"}'; do
  fails env role -e "{\"anubis_env\": $env}"
  expect_in_log env "anubis_env cannot set"
  untouched
done
fails entrypoints role -e '{"anubis_traefik_entrypoints": []}'
expect_in_log entrypoints "anubis_traefik_entrypoints"
untouched
fails entrypoints-typo role -e '{"anubis_traefik_entrypoints": ["web", "pubic"]}'
expect_in_log entrypoints-typo "each one of traefik_entrypoints"
untouched
fails key role -e anubis_private_key=not-hex
expect_in_log key "anubis_private_key must be 64 hex digits"
untouched
# Traefik is not installed yet: no dynamic directory, no network.
fails no-traefik role
expect_in_log no-traefik "/opt/traefik/dynamic"
untouched

echo "== a first install whose settings never get healthy leaves no Traefik objects"
fails first-broken play "$here/converge.yml" -e anubis_health_timeout=15 \
  -e '{"anubis_env": {"POLICY_FNAME": "/anubis/missing.yaml"}}'
expect_in_log first-broken "Anubis is not healthy with the new settings"
expect_in_log first-broken "/anubis/missing.yaml"
hx test ! -e /opt/traefik/dynamic/anubis.yml || fail "the failed first install wrote the Traefik objects"
hx test ! -e /opt/anubis/policy.yaml || fail "the failed first install put the policy in place"
hx test ! -e /opt/anubis/compose.yaml || fail "the failed first install put the compose file in place"
[ -z "$(hx docker ps -aq --filter "name=^$anubis\$")" ] || fail "the failed first install created the Anubis container"
no_check_container

echo "== install"
play "$here/converge.yml"
wait_healthy
play "$here/verify.yml"
expect_idempotent

echo "== entrypoint mode: challenge on both domains, solved once, then pass"
for site in a.example.test b.other.test; do
  expect "401 challenge" "http://$site/page?x=1"
  solve solve "http://$site/page?x=1" --jar "$(jar "$site")" --difficulty 4
  expect "200 backend" "http://$site/other/path" --jar "$(jar "$site")"
done

echo "== per-router mode: only the router with anubis@file is challenged"
expect "401 challenge" http://c.example.test:8080/
solve solve http://c.example.test:8080/ --jar "$(jar c.example.test)"
expect "200 backend" http://d.other.test:8080/

echo "== a 401 from behind anubis@file is replaced by Anubis's answer, WWW-Authenticate and body included"
# The documented limitation of traefik mode: anubis-challenge (errors on 401)
# wraps everything after it, so a backend's or a middleware's 401 (here
# Traefik basicAuth, realm noix-test, body "401 Unauthorized") never reaches
# the client: a browser gets the challenge page, also on a path the policy
# ALLOWs; a client Anubis lets through (curl) gets Anubis's stub pointing back
# at the same URL. Both without WWW-Authenticate. The router without Anubis is
# the control: there the header and basicAuth's body are seen, so the checks
# below could tell.
auth=Authorization:'Basic bm9peDpub2l4LXRlc3Qtb25seQ=='
want_basic='Basic realm="noix-test"'
for ua in curl/8.17.0 'Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0'; do
  got="$(solve probe http://g.other.test:8080/api/x --ua "$ua" --response-header WWW-Authenticate --response-header Location)"
  [ "$got" = "401 other $want_basic -" ] || fail "the router without Anubis answered '$got' ($ua), expected '401 other $want_basic -'"
done
[ "$(solve probe http://g.other.test:8080/ --ua curl/8.17.0 --expect '401 Unauthorized')" = "401 backend" ] \
  || fail "the router without Anubis did not answer basicAuth's own body"
[ "$(solve probe http://g.other.test:8080/ --ua curl/8.17.0 --header "$auth")" = "200 backend" ] \
  || fail "the router without Anubis did not take the test credentials"
for url in http://e.example.test http://f.example.test:8080; do
  got="$(solve probe "$url/" --ua curl/8.17.0 --response-header WWW-Authenticate --response-header Location)"
  echo "   $url/ with curl: $got"
  [ "$got" = "401 other - $url/" ] || fail "$url/ with curl answered '$got', expected '401 other - $url/' (Anubis's stub)"
  [ "$(solve probe "$url/" --ua curl/8.17.0 --expect '401 Unauthorized')" = "401 other" ] \
    || fail "$url/ with curl got basicAuth's own body behind anubis@file"
  # /api/ is ALLOWed (vars.yml test-api): Anubis lets the browser through,
  # and basicAuth's 401 comes back as the challenge page.
  got="$(solve probe "$url/api/x" --response-header WWW-Authenticate)"
  echo "   $url/api/x with a browser (ALLOWed): $got"
  [ "$got" = "401 challenge -" ] || fail "$url/api/x answered '$got', expected '401 challenge -' (the replaced 401)"
  # With the credentials the backend answers: only the 401 is replaced.
  [ "$(solve probe "$url/" --ua curl/8.17.0 --header "$auth")" = "200 backend" ] \
    || fail "$url/ with curl and the test credentials did not reach the backend"
done

echo "== a policy ALLOW rule passes without a challenge"
expect "200 backend" http://a.example.test/api/items

echo "== Anubis's own assets pass, its check and challenge paths do not"
for url in http://a.example.test http://d.other.test:8080; do
  expect "200 other" "$url/.within.website/x/cmd/anubis/static/js/main.mjs"
  expect "200 other" "$url/.within.website/x/xess/xess.min.css"
done
expect "401 challenge" http://a.example.test/.within.website/x/cmd/anubis/api/check
expect "401 challenge" "http://a.example.test/.within.website/?redir=http://a.example.test/"

echo "== client-sent forwarding headers do not bypass the check"
# Each would let a client pick what Anubis checks: the path (X-Original-Uri,
# X-Forwarded-Uri, X-Forwarded-Prefix), the method, the host, the scheme or
# the address the cookie is bound to.
for site in http://a.example.test http://c.example.test:8080; do
  for header in X-Original-Uri:/.well-known/x X-Forwarded-Uri:/.well-known/x X-Forwarded-Prefix:/.well-known \
    X-Forwarded-Method:OPTIONS X-Forwarded-Host:d.other.test X-Forwarded-Proto:https X-Real-Ip:203.0.113.9 \
    X-Forwarded-For:203.0.113.9; do
    expect "401 challenge" "$site/secret" --header "$header"
  done
done
# With a valid cookie: the backend sees Traefik's values, not the client's
# (so neither does Anubis), and no X-Forwarded-Uri or X-Original-Uri at all.
jar_a="$(jar a.example.test)"
real_ip="$(solve probe http://a.example.test/ --jar "$jar_a" --echo X-Real-Ip | cut -d' ' -f3)"
[ "$(solve probe http://a.example.test/ --jar "$jar_a" --header X-Real-Ip:203.0.113.9 --echo X-Real-Ip)" = "200 backend $real_ip" ] \
  || fail "a client-sent X-Real-Ip reached the backend"
[ "$(solve probe http://a.example.test/ --jar "$jar_a" --header X-Forwarded-Host:d.other.test --echo X-Forwarded-Host)" \
  = "200 backend a.example.test" ] || fail "a client-sent X-Forwarded-Host reached the backend"
[ "$(solve probe http://a.example.test/ --jar "$jar_a" --header X-Forwarded-Proto:https --echo X-Forwarded-Proto)" \
  = "200 backend http" ] || fail "a client-sent X-Forwarded-Proto reached the backend"
for header in X-Forwarded-Uri X-Original-Uri; do
  [ "$(solve probe http://a.example.test/ --jar "$jar_a" --header "$header:/.well-known/x" --echo "$header")" \
    = "200 backend -" ] || fail "a client-sent $header reached the backend"
done

echo "== path tricks on Anubis's own prefix do not reach a backend unchecked"
for site in http://a.example.test http://c.example.test:8080; do
  for path in //.within.website/x/cmd/anubis/static/ \
    /.within.website/x/cmd/anubis/static/../../../../../secret \
    /.within.website/x/cmd/anubis/static/%2e%2e/%2e%2e/%2e%2e/%2e%2e/%2e%2e/secret \
    /.within.website/x/cmd/anubis/static/..%2F..%2F..%2F..%2F..%2Fsecret \
    /.within.website%2F..%2Fsecret /.within.website/x/xess/../../../secret; do
    not_backend "$site$path"
  done
done

echo "== User-Agents: curl passes by the default policy, an empty one is denied"
expect "200 backend" http://a.example.test/ --ua curl/8.17.0
expect "403 denied" http://a.example.test/ --ua ''
expect "403 denied" http://c.example.test:8080/ --ua ''

echo "== pass-challenge redirects to the redirect domains only"
[ "$(solve redirect http://a.example.test/ --redir http://evil.test/ --jar /tmp/jar-evil.json | cut -d' ' -f1)" = 400 ] \
  || fail "pass-challenge redirected to evil.test"
[ "$(solve redirect http://a.example.test/ --redir http://b.other.test/x --jar /tmp/jar-glob.json)" = "302 http://b.other.test/x" ] \
  || fail "pass-challenge did not redirect to b.other.test"

echo "== the signing key and the cookies survive a container recreate"
key_before="$(hx sha256sum /opt/anubis/ed25519.key)"
hx docker compose --project-directory /opt/anubis up -d --force-recreate >"$out/recreate.log" 2>&1 \
  || { cat "$out/recreate.log" >&2; fail "the recreate failed"; }
wait_healthy
[ "$(hx sha256sum /opt/anubis/ed25519.key)" = "$key_before" ] || fail "the signing key changed"
expect "200 backend" http://a.example.test/page?x=1 --jar "$(jar a.example.test)"
expect "200 backend" http://c.example.test:8080/ --jar "$(jar c.example.test)"
expect_idempotent

echo "== a stopped Anubis fails closed, the next converge brings it back"
hx docker stop "$anubis" >/dev/null
down_global="$(solve probe http://a.example.test/page?x=1 --jar "$(jar a.example.test)")"
down_router="$(solve probe http://c.example.test:8080/ --jar "$(jar c.example.test)")"
down_curl="$(solve probe http://b.other.test/ --ua curl/8.17.0)"
down_assets="$(solve probe http://a.example.test/.within.website/x/cmd/anubis/static/js/main.mjs)"
down_router_assets="$(solve probe http://d.other.test:8080/.within.website/x/xess/xess.min.css)"
echo "Anubis down: entrypoint router '$down_global', opted-in router '$down_router', curl '$down_curl'," \
  "own paths on the entrypoint '$down_assets', on single routers' entrypoint '$down_router_assets'"
for got in "$down_global" "$down_router" "$down_curl"; do
  [ "$got" = "500 other" ] || fail "a protected router answered '$got' while Anubis is down, expected '500 other'"
done
# On an entrypoint with anubis@file the anubis-<ep> router runs the
# entrypoint's chain too, whose dead forwardAuth answers first; where only
# single routers use it, Traefik answers for the missing service.
[ "$down_assets" = "500 other" ] || fail "Anubis's own paths on web answered '$down_assets' while Anubis is down, expected '500 other'"
[ "$down_router_assets" = "502 other" ] \
  || fail "Anubis's own paths on opt answered '$down_router_assets' while Anubis is down, expected '502 other'"
expect "200 backend" http://d.other.test:8080/
play "$here/converge.yml" | tee "$out/restart.log"
grep -Eq 'changed=[1-9][0-9]* +unreachable=0 +failed=0' "$out/restart.log" || fail "the converge did not start Anubis"
[ "$(health)" = healthy ] || fail "the converge left Anubis $(health)"
expect "200 backend" http://a.example.test/page?x=1 --jar "$(jar a.example.test)"
expect "401 challenge" http://b.other.test/fresh
solve solve http://b.other.test/fresh --jar /tmp/jar-fresh.json
expect_idempotent

echo "== a broken policy leaves the running Anubis serving"
before="$(started_at)"
policy_before="$(hx sha256sum /opt/anubis/policy.yaml)"
compose_before="$(hx sha256sum /opt/anubis/compose.yaml)"
traefik_before="$(hx sha256sum /opt/traefik/dynamic/anubis.yml)"
# An invalid regular expression: Anubis refuses the policy at start.
fails broken-policy play "$here/converge.yml" -e anubis_health_timeout=15 \
  -e '{"anubis_policy_allow": [{"name": "broken", "action": "ALLOW", "path_regex": "^/api/("}]}'
expect_in_log broken-policy "Anubis is not healthy with the new settings"
expect_in_log broken-policy "are unchanged"
[ "$(started_at)" = "$before" ] || fail "the broken policy restarted Anubis"
[ "$(health)" = healthy ] || fail "Anubis is $(health) after the broken policy"
[ "$(hx sha256sum /opt/anubis/policy.yaml)" = "$policy_before" ] || fail "the broken policy replaced policy.yaml"
[ "$(hx sha256sum /opt/anubis/compose.yaml)" = "$compose_before" ] || fail "the broken policy replaced compose.yaml"
[ "$(hx sha256sum /opt/traefik/dynamic/anubis.yml)" = "$traefik_before" ] || fail "the broken policy changed anubis.yml"
no_check_container
expect "200 backend" http://a.example.test/page?x=1 --jar "$(jar a.example.test)"
expect "200 backend" http://a.example.test/ --ua curl/8.17.0
expect "401 challenge" http://b.other.test/after-broken
solve solve http://b.other.test/after-broken --jar /tmp/jar-after-broken.json
# A broken environment on an update: the same.
fails broken-env play "$here/converge.yml" -e anubis_health_timeout=15 \
  -e '{"anubis_env": {"POLICY_FNAME": "/anubis/missing.yaml"}}'
expect_in_log broken-env "Anubis is not healthy with the new settings"
[ "$(started_at)" = "$before" ] || fail "the broken environment restarted Anubis"
[ "$(hx sha256sum /opt/anubis/compose.yaml)" = "$compose_before" ] || fail "the broken environment replaced compose.yaml"
expect "200 backend" http://c.example.test:8080/ --jar "$(jar c.example.test)"
# The good settings again: the running ones, nothing to restart.
play "$here/converge.yml"
[ "$(started_at)" = "$before" ] || fail "going back to the running settings restarted Anubis"
expect_idempotent

echo "== new files put in place by a run that stopped before the restart are started by the next run"
# A second ALLOW rule (^/hook/): a browser without a cookie passes there only
# when the running Anubis has the new policy.
hook=(-e '{"anubis_policy_allow": [{"name": "test-api", "action": "ALLOW", "path_regex": "^/api/"},
  {"name": "test-hook", "action": "ALLOW", "path_regex": "^/hook/"}]}')
play "$here/converge.yml" "${hook[@]}" >"$out/hook.log" 2>&1 || { cat "$out/hook.log" >&2; fail "the converge with the hook rule failed"; }
wait_healthy
expect "200 backend" http://a.example.test/hook/x
hx cp /opt/anubis/policy.yaml /tmp/policy-hook.yaml
hx cp /opt/anubis/compose.yaml /tmp/compose-hook.yaml
# Only policy.yaml (as a hand edit would), then both files (as the role's
# copy leaves them when the run stops before Start Anubis).
for files in policy.yaml "policy.yaml compose.yaml"; do
  play "$here/converge.yml" >"$out/hook-back.log" 2>&1 || { cat "$out/hook-back.log" >&2; fail "the converge without the hook rule failed"; }
  wait_healthy
  expect "401 challenge" http://a.example.test/hook/x
  for file in $files; do
    # A new file, as the role's copy writes it (the container keeps the old one).
    hx sh -c "cp -p /tmp/${file%.yaml}-hook.yaml /opt/anubis/$file.new && mv /opt/anubis/$file.new /opt/anubis/$file"
  done
  before="$(started_at)"
  expect "401 challenge" http://a.example.test/hook/x
  play "$here/converge.yml" "${hook[@]}" | tee "$out/hook-heal.log"
  [ "$(started_at)" != "$before" ] || fail "the run after an interrupted one ($files in place) did not recreate Anubis"
  wait_healthy
  expect "200 backend" http://a.example.test/hook/x
  expect_idempotent "${hook[@]}"
done

echo "== anubis_env values are neither in the log nor readable by others"
secret=noix-test-value-7f3e9b1c
play "$here/converge.yml" -v -e "{\"anubis_env\": {\"NOIX_TEST_VALUE\": \"$secret\"}}" >"$out/env-secret.log" 2>&1 \
  || { cat "$out/env-secret.log" >&2; fail "the converge with an anubis_env value failed"; }
grep -q 'Start the check container' "$out/env-secret.log" || fail "the converge with an anubis_env value did not run the check container"
if grep -qF "$secret" "$out/env-secret.log"; then fail "the converge logged an anubis_env value at -v"; fi
hx grep -qF "$secret" /opt/anubis/compose.yaml || fail "compose.yaml lacks the anubis_env value"
[ "$(hx stat -c '%a %U' /opt/anubis/compose.yaml)" = "600 root" ] || fail "compose.yaml is not 0600 owned by root"
hx docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$anubis" | grep -qxF "NOIX_TEST_VALUE=$secret" \
  || fail "the container lacks the anubis_env value"
hx test ! -e /opt/anubis/staged/check.env || fail "the check container's env file was left behind"
wait_healthy

echo "== a given signing key replaces the generated one"
given=0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0
play "$here/converge.yml" -e anubis_private_key="$given" | tee "$out/given-key.log"
if grep -qF "$given" "$out/given-key.log"; then fail "the converge logged the signing key"; fi
[ "$(hx cat /opt/anubis/ed25519.key)" = "$given" ] || fail "the key file does not hold the given key"
[ "$(hx stat -c '%a %u' /opt/anubis/ed25519.key)" = "600 65532" ] || fail "the given key file is not 0600 owned by 65532"
hx test ! -e /opt/anubis/staged/ed25519.key || fail "the staged copy of the given key was left behind"
wait_healthy
# Signed with the old key: no longer valid.
expect "401 challenge" http://a.example.test/page?x=1 --jar "$(jar a.example.test)"
solve solve http://a.example.test/given --jar /tmp/jar-given.json
expect_idempotent -e anubis_private_key="$given"
hx test ! -e /opt/anubis/staged/ed25519.key || fail "a repeated run staged the given key again"

echo "== nginx mode: its own internal network and the given ones, no Traefik objects"
new_host
load_images
hx docker network create mailnet >/dev/null
# A file of that name the role did not write stays.
hx sh -c 'mkdir -p /opt/traefik/dynamic && echo "http: {}" >/opt/traefik/dynamic/anubis.yml'
nginx_vars=(-e anubis_mode=nginx -e '{"anubis_networks": ["mailnet"]}')
role "${nginx_vars[@]}"
wait_healthy
# Go templates, not shell expansion.
# shellcheck disable=SC2016
[ "$(hx docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$anubis")" = "mailnet noixdev-anubis " ] \
  || fail "anubis is not on mailnet and noixdev-anubis only"
[ "$(hx docker network inspect -f '{{.Internal}} {{index .Labels "noixdev.infra.anubis"}}' noixdev-anubis)" = "true nginx" ] \
  || fail "noixdev-anubis is not the role's internal network"
for net in noixdev-anubis mailnet; do
  dns_names="$(hx docker inspect -f "{{json (index .NetworkSettings.Networks \"$net\").DNSNames}}" "$anubis")"
  [[ "$dns_names" == *"\"$anubis\""* && "$dns_names" != *'"anubis"'* ]] \
    || fail "anubis's DNS names on $net are not $anubis only: $dns_names"
done
hx grep -qx 'http: {}' /opt/traefik/dynamic/anubis.yml || fail "nginx mode removed an anubis.yml the role did not write"
# As left by traefik mode (the role's marker line): nginx mode removes it.
hx sh -c 'printf "# managed\n# Written by the noixdev.infra.anubis role (traefik mode).\nhttp: {}\n" >/opt/traefik/dynamic/anubis.yml'
role "${nginx_vars[@]}" >"$out/nginx-own-file.log"
hx test ! -e /opt/traefik/dynamic/anubis.yml || fail "nginx mode left the role's Traefik file"
role "${nginx_vars[@]}" | tee "$out/nginx-rerun.log"
grep -Eq 'CHANGED|changed": true' "$out/nginx-rerun.log" && fail "a repeated nginx mode run changed something"
# Its own network alone is enough.
role -e anubis_mode=nginx >"$out/nginx-own-network.log"
# shellcheck disable=SC2016
[ "$(hx docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$anubis")" = "noixdev-anubis " ] \
  || fail "anubis did not leave mailnet"
fails nginx-networks role -e anubis_mode=nginx -e '{"anubis_networks": ["missingnet"]}'
expect_in_log nginx-networks "missingnet do not exist"
hx docker network create plainnet >/dev/null
fails nginx-plain role -e anubis_mode=nginx -e anubis_nginx_network=plainnet
expect_in_log nginx-plain "plainnet (anubis_nginx_network) exists but is not internal"
[ "$(hx docker inspect -f '{{.State.Health.Status}}' "$anubis")" = healthy ] || fail "a refused run touched Anubis"

echo "== all anubis tests passed"
