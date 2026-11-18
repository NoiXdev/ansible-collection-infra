# shellcheck shell=bash
# shellcheck disable=SC2154  # fail, fails, expect_in_log, untouched, ... come from run.sh
# The redirect mode part of the anubis suite (anubis_public_url); sourced by
# run.sh, alone with ANUBIS_SUITE_PART=redirect. The last line is its pass
# signal: the early exit never reaches run.sh's final banner.

# The anubis role alone, ad hoc, with redirect-vars.yml and the given -e arguments.
redirect_role() {
  ansible all -i "$here/inventory.yml" -e "test_host=$host" -e "@$here/redirect-vars.yml" "$@" \
    -m ansible.builtin.include_role -a name=noixdev.infra.anubis
}
redirect_on=(-e anubis_public_url=https://anubis.example.test -e anubis_cookie_domain=example.test)
# The converge playbook (Traefik, Anubis, the fixtures) with redirect-vars.yml.
redirect_play() { play "$here/redirect-converge.yml" "$@"; }
# redirect_play twice: the second run must change nothing.
redirect_idempotent() {
  redirect_play "$@" | tee "$out/redirect-rerun.log"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/redirect-rerun.log" || fail "a repeated redirect mode converge changed something"
}

new_host
load_images

echo "== redirect mode: settings must be refused before any change"
# refuse <name> <text> <role arguments...>: redirect mode with the override must fail with text.
refuse() {
  local name="$1" text="$2"
  shift 2
  fails "$name" redirect_role "${redirect_on[@]}" "$@"
  expect_in_log "$name" "$text"
  untouched
}
refuse r-mode "anubis_public_url works in traefik mode only" -e anubis_mode=nginx
refuse r-http "anubis_public_url must be https://host[:port]" -e anubis_public_url=http://anubis.example.test
refuse r-slash "anubis_public_url must be https://host[:port]" -e anubis_public_url=https://anubis.example.test/
refuse r-path "anubis_public_url must be https://host[:port]" -e anubis_public_url=https://anubis.example.test/x
refuse r-no-cookie "anubis_cookie_domain is required with anubis_public_url" -e anubis_cookie_domain=
refuse r-cookie-port "anubis_cookie_domain must be a host name" -e anubis_cookie_domain=example.test:443
refuse r-cookie-dot "anubis_cookie_domain must be a host name" -e anubis_cookie_domain=test
refuse r-no-key "anubis_private_key is required with anubis_public_url" -e anubis_private_key=
refuse r-host-outside "The Anubis host is outside anubis_cookie_domain" -e anubis_public_url=https://anubis.other.test
refuse r-domains-outside "anubis_redirect_domains entries outside anubis_cookie_domain" \
  -e '{"anubis_redirect_domains": ["a.example.test", "b.other.test"]}'
refuse r-domains-suffix "anubis_redirect_domains entries outside anubis_cookie_domain" \
  -e '{"anubis_redirect_domains": ["*.test.example"]}'
refuse r-env-lower "anubis_env cannot set COOKIE_DOMAIN or COOKIE_DYNAMIC_DOMAIN" \
  -e '{"anubis_env": {"cookie_domain": "example.test"}}'
refuse r-env-dynamic "anubis_env cannot set COOKIE_DOMAIN or COOKIE_DYNAMIC_DOMAIN" \
  -e '{"anubis_env": {"COOKIE_DYNAMIC_DOMAIN": "true"}}'
refuse r-entrypoint "cannot serve the Anubis host" \
  -e '{"traefik_entrypoints": [{"name": "sec", "port": 443, "middlewares": ["anubis@file"]}]}'
# traefik_entrypoints with a port mapped by host_port; the Anubis URL has no port (443).
ep_internal='{"name": "internal", "port": 443, "bind": [127.0.0.1], "tls": true}'
refuse r-port-mw "carry anubis@file in traefik_entrypoints" \
  -e "{\"traefik_entrypoints\": [$ep_internal, {\"name\": \"public\", \"port\": 8443, \"host_port\": 443, \"tls\": true, \"middlewares\": [\"anubis@file\"]}], \"anubis_traefik_entrypoints\": [\"internal\"]}"
refuse r-port-unnamed "names none of them" \
  -e "{\"traefik_entrypoints\": [$ep_internal, {\"name\": \"other\", \"port\": 9443, \"tls\": true}], \"anubis_traefik_entrypoints\": [\"other\"]}"
# A trailing line break passes a regex that ends in $; a port needs 1 to 65535.
refuse r-url-newline "anubis_public_url must be https://host[:port]" -e '{"anubis_public_url": "https://anubis.example.test\n"}'
refuse r-cookie-newline "anubis_cookie_domain must be a host name" -e '{"anubis_cookie_domain": "example.test\n"}'
refuse r-port-zero "anubis_public_url has the port 0" -e anubis_public_url=https://anubis.example.test:0
refuse r-port-high "anubis_public_url has the port 99999" -e anubis_public_url=https://anubis.example.test:99999

fails cookie-alone redirect_role -e anubis_cookie_domain=example.test
expect_in_log cookie-alone "anubis_cookie_domain needs anubis_public_url"
untouched

# Names in any case, with a port and a glob, pass the redirect checks: the run
# goes on to the next check and fails on the missing Traefik directory.
fails r-accepted redirect_role "${redirect_on[@]}" \
  -e '{"anubis_redirect_domains": ["A.Example.Test", "b.example.test:8443", "*.example.test"]}'
expect_in_log r-accepted "/opt/traefik/dynamic"
if grep -qF "anubis_cookie_domain" "$out/r-accepted.log"; then fail "r-accepted.log names anubis_cookie_domain"; fi
untouched

# The Anubis host on public (container port 8443, published as 443), which
# carries no anubis@file, passes checks 10 and 11 up to the missing directory.
fails r-port-ok redirect_role "${redirect_on[@]}" \
  -e "{\"traefik_entrypoints\": [$ep_internal, {\"name\": \"public\", \"port\": 8443, \"host_port\": 443, \"tls\": true}], \"anubis_traefik_entrypoints\": [\"public\"]}"
expect_in_log r-port-ok "/opt/traefik/dynamic"
if grep -qF "anubis_public_url" "$out/r-port-ok.log"; then fail "r-port-ok.log names anubis_public_url"; fi
untouched

echo "== redirect mode: same-host baseline, then the switch"
redirect_play
wait_healthy
expect "401 challenge" https://a.example.test/

echo "== redirect mode: install, then the browser flow over HTTPS"
redirect_play "${redirect_on[@]}"
wait_healthy
play "$here/redirect-verify.yml"
redirect_idempotent "${redirect_on[@]}"

# A URL in mixed case with a port routes the lower-case host without it. The
# normal redirect state follows, so that the later sections still hold.
redirect_play -e anubis_public_url=https://Anubis.Example.TEST:8443 -e anubis_cookie_domain=example.test
wait_healthy
# shellcheck disable=SC2016  # the backticks are Traefik's rule syntax
host_rule='rule: Host(`anubis.example.test`) && PathPrefix(`/.within.website/`)'
hx grep -qF "$host_rule" /opt/traefik/dynamic/anubis.yml \
  || fail "the mixed-case URL with a port did not give the lower-case host without a port"
redirect_play "${redirect_on[@]}"
wait_healthy
play "$here/redirect-verify.yml"

loc='https://anubis.example.test/.within.website/?redir=https%3A%2F%2Fa.example.test%2Fp%3Fx%3D1'
want_bearer='Bearer realm="noix-registry"'
want_basic='Basic realm="noix-test"'
[ "$(solve probe 'https://a.example.test/p?x=1' --response-header Location)" = "307 other $loc" ] || fail "no redirect"
# A client cannot steer the target.
[ "$(solve probe 'https://a.example.test/p?x=1' --header X-Forwarded-Host:evil.test --header X-Forwarded-Uri:/x --response-header Location)" = "307 other $loc" ] \
  || fail "client headers steered the redirect"
expect "200 backend" https://a.example.test/api/items
[ "$(solve probe https://f.example.test/v2/ --ua curl/8.17.0 --response-header WWW-Authenticate)" = "401 other $want_bearer" ] || fail "backend 401 replaced"
[ "$(solve probe https://e.example.test/ --ua curl/8.17.0 --response-header WWW-Authenticate)" = "401 other $want_basic" ] || fail "basicAuth 401 replaced"
[ "$(solve probe https://f.example.test/api/x --response-header WWW-Authenticate)" = "401 other $want_bearer" ] || fail "401 on an ALLOWed path replaced"
expect "200 other" https://anubis.example.test/.within.website/x/xess/xess.min.css
[ "$(solve probe https://anubis.example.test/ | cut -d' ' -f1)" = 404 ] || fail "the Anubis host serves other paths"

echo "== redirect mode: Anubis's own paths on an app host never reach the backend"
for path in /.within.website/x/cmd/anubis/static/js/main.mjs /.within.website/x/xess/xess.min.css \
  /.within.website/x/cmd/anubis/api/pass-challenge /.within.website/x/cmd/anubis/api/imprint \
  /.within.website/x/cmd/anubis/ext/x.css \
  //.within.website/x/cmd/anubis/static/ \
  /.within.website/x/cmd/anubis/static/../../../../../secret \
  /.within.website/x/cmd/anubis/static/%2e%2e/%2e%2e/%2e%2e/%2e%2e/%2e%2e/secret \
  /.within.website/x/cmd/anubis/static/..%2F..%2F..%2F..%2F..%2Fsecret \
  /.within.website%2F..%2Fsecret /.within.website/x/xess/../../../secret; do
  not_backend "https://a.example.test$path"
done

echo "== redirect mode: one solve on the Anubis host, the cookie works on every app host"
jar_r="$(jar redirect)"
solve solve-redirect 'https://a.example.test/p?x=1' --jar "$jar_r" --cookie-domain example.test
expect "200 backend" https://a.example.test/other --jar "$jar_r"
[ "$(solve probe https://f.example.test/v2/ --jar "$jar_r" --response-header WWW-Authenticate)" = "401 other $want_bearer" ] \
  || fail "backend 401 replaced with the cookie"
[ "$(solve probe https://e.example.test/ --jar "$jar_r" --response-header WWW-Authenticate)" = "401 other $want_basic" ] \
  || fail "basicAuth 401 replaced with the cookie"

# Test-only keys; the first one is anubis_private_key of redirect-vars.yml.
key_main="$(sed -n 's/^anubis_private_key: *//p' "$here/redirect-vars.yml")"
key_other=a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718
[ "${#key_main}" = 64 ] || fail "no test key in redirect-vars.yml"
second_server=(-e anubis_public_url=https://anubis-b.example.test -e anubis_cookie_domain=example.test
  -e '{"anubis_policy_allow": [{"name": "other", "action": "ALLOW", "path_regex": "^/other/"}]}')

echo "== redirect mode: a second server with the same key accepts the cookie"
redirect_play "${second_server[@]}"
wait_healthy
expect "200 backend" https://a.example.test/x --jar "$jar_r"

echo "== redirect mode: a second server with another key rejects it"
# Anubis clears a cookie it cannot verify: $jar_r may be empty from here on.
redirect_play "${second_server[@]}" -e anubis_private_key="$key_other"
wait_healthy
expect "307 other" https://a.example.test/x --jar "$jar_r"

echo "== redirect mode: the keys stay out of a verbose run with --diff"
redirect_play "${redirect_on[@]}" -v --diff >"$out/redirect-verbose.log" 2>&1
grep -q 'PLAY RECAP' "$out/redirect-verbose.log" || fail "the verbose log is incomplete"
[ "$(wc -l <"$out/redirect-verbose.log")" -gt 50 ] || fail "the verbose log is too short to trust"
if grep -qF -e "$key_main" -e "$key_other" "$out/redirect-verbose.log"; then fail "a private key occurs in the verbose log"; fi
wait_healthy

echo "== redirect mode: Anubis down fails closed"
hx docker stop "$anubis" >/dev/null
expect "500 other" https://a.example.test/
redirect_play "${redirect_on[@]}"
wait_healthy

echo "== redirect mode: back to the same host"
redirect_play
wait_healthy
expect "401 challenge" https://a.example.test/
hx grep -q anubis-challenge /opt/traefik/dynamic/anubis.yml || fail "anubis.yml lacks anubis-challenge"
[ "$(hx grep -m1 'name:' /opt/anubis/policy.yaml | sed 's/.*name: *//')" = anubis-own-paths ] || fail "policy.yaml does not start with anubis-own-paths"
env_now="$(hx docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$anubis")"
[ -n "$env_now" ] || fail "no environment read from the container"
if printf '%s\n' "$env_now" | grep -Eq '^(PUBLIC_URL|COOKIE_DOMAIN)='; then fail "the container still has PUBLIC_URL or COOKIE_DOMAIN"; fi
redirect_idempotent

echo "== redirect part passed"
