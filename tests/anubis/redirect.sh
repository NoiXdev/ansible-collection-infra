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

echo "== redirect part passed"
