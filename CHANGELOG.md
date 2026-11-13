# Changelog

## Unreleased

- `error_pages_export`: new internal role, used by `cloudpanel` and `mailcow`, that exports the noix
  error pages to static files. `cloudpanel` behaves as before: same files, same export script.
- `dns`: a `dns_records` entry has either `addresses` or the new `tailscale_peer` (exactly one;
  both or neither fails before anything changes). `tailscale_peer` is a node's host name as in
  `tailscale status --json` (`Peer[*].HostName`, matched case-insensitively; the DNS host itself,
  `Self`, can be named too); the name then answers that node's Tailscale IPv4 and IPv6 addresses.
  The tailnet is read once per run, and only when an entry uses `tailscale_peer` (needs the
  `tailscale` CLI on the DNS host; without it the run fails naming the entries). A peer that is
  not on the tailnet yet gives a warning and no record, so the run stays green (also on a tailnet
  without peers, `"Peer": null`, and for a node without addresses, `"TailscaleIPs": null`); a host
  name shared by two nodes fails the run instead of picking one.
- `listmonk`: new role that runs listmonk (`listmonk_version`, default `v6.2.0`) and PostgreSQL
  (`listmonk_postgres_image`, default `postgres:17`) as one compose project in `listmonk_dir`
  (default `/opt/listmonk/listmonk-app`; its basename is the project name), with the containers
  `<listmonk_name>_db` and `<listmonk_name>_app` (default `listmonk_app`), the data in
  `data/postgresql/data` and `data/listmonk/uploads`, and listmonk on `listmonk_bind:listmonk_port`
  (default `127.0.0.1:9000`). The compose file `docker-compose.yaml` (mode `0600`) holds
  `listmonk_db_password`, which is required; the first admin (`listmonk_admin_user`,
  `listmonk_admin_password`) is needed for a fresh install only and is passed to listmonk's
  `--install` without being written to the host. Each run reads the host and picks one state:
  *install* (no compose file and no containers; refused over an existing database),
  *reconfigure* (the running version equals the pin but the compose file or the database password
  differs), *noop* (nothing differs) or *update* (a newer pin). The running version comes from
  the app image's tag when it is `vX.Y.Z` and from the listmonk binary otherwise (such as
  `latest`); a pin lower than the running version is refused before anything changes. A *noop*
  run pulls, starts and restarts nothing, but fails when the app container is not running or
  listmonk does not answer `/health` within `listmonk_health_timeout` seconds. Before it checks
  the database password the role waits up to `listmonk_health_timeout` seconds for a database
  that is still starting (after a reboot); only an authentication failure counts as a wrong
  password.
- `listmonk`: takes over an existing installation in this layout in place (such as one with the
  image tag `latest` and the database password `listmonk`). Before it changes anything it checks
  the compose file, the project, the container names and the data directories, and refuses with
  the expected and the found layout when they differ; it also refuses a database that takes
  neither `listmonk_db_password` nor `listmonk_db_password_old` (default `listmonk`). A
  reconfigure dumps the database first (`pg_dump -Fc`, read back in full, to
  `backups/<UTC time>-<version>.dump`, never overwriting one, the newest `listmonk_dumps_keep`
  kept), sets `listmonk_db_password` when the database still uses the old one, writes the compose
  file, recreates what changed and waits up to `listmonk_health_timeout` seconds for `/health`.
  When any of that fails it puts the previous compose file (mode `0600`) and password back,
  recreates the database empty and loads the dump into it (so tables a newer listmonk added do not
  survive or block the restore), starts listmonk again and fails the run saying that it restored
  the installation, or naming the dump to restore by hand.
- `listmonk`: updates to a newer `listmonk_version`. A failed pull of the new image changes
  nothing. Then the role dumps the database (as above, the dump named after the running
  version), stops listmonk, sets `listmonk_db_password` when the database still uses
  `listmonk_db_password_old` (an old installation updated on its first run), runs the new
  release's `listmonk --upgrade --yes` against the database, writes the compose file with the new
  version, starts listmonk and waits up to `listmonk_health_timeout` seconds for `/health`. Any
  failure after the dump rolls back: the previous compose file, database password and the dump
  (as for a reconfigure), and the run fails with "update to X failed, rolled back to Y", or
  naming the dump to restore by hand when the rollback fails too. The compose file names the new
  version only from the upgrade until a rollback, so a later `docker compose up -d` starts the
  version that works.
- `listmonk`: a failed update writes `update-failed` in `listmonk_dir` (`failed_version`,
  `rolled_back_to`, `dump`, `time`). While it names the pinned version, every run fails before
  changing anything and says how to clear it (remove the file, or pin another version); the
  first successful run with another version removes it.
- `listmonk`: an update waits while a campaign is sending (status `running`): the run stays
  green with a warning and counts the postponed runs per version in `update-postponed` in
  `listmonk_dir`; the run that reaches `listmonk_postpone_limit` (default 3) in a row fails. Like
  a *noop* run, a postponed run starts and restarts nothing, but fails when the app container is
  not running or listmonk does not answer `/health`. A run that goes ahead with the update
  removes the count, and so does any other successful run.
- `anubis`: new role that runs one Anubis container (`anubis_image`, default
  `ghcr.io/techarohq/anubis:v1.28.2`; compose project `anubis` in `anubis_dir`, default
  `/opt/anubis`; service and container `noixdev-anubis`, its only DNS name on its networks, at
  `http://noixdev-anubis:8923`) that protects web apps with a proof-of-work challenge.
  `anubis_mode` `traefik` (default) joins `anubis_traefik_network` (default `traefik_network`,
  else `proxy`) and writes `anubis.yml` to Traefik's file provider directory
  `anubis_traefik_dynamic_dir` (default `traefik_dir` with `/dynamic`, else
  `/opt/traefik/dynamic`; it must exist, and the traefik role leaves the file alone): the
  middleware `anubis@file` to add to a router's or an entrypoint's `middlewares` (one name for
  the chain `anubis-strip` (deletes a client-sent `X-Original-Uri` and `X-Forwarded-Uri`, which
  would let a client pick the path Anubis checks), `anubis-challenge` (`errors`: Anubis's 401
  becomes the challenge page for the original URL) and `anubis-check` (`forwardAuth` with
  `trustForwardHeader`)), and a router `anubis-<entrypoint>` for `PathPrefix(/.within.website/)`
  at priority `100000` on each of `anubis_traefik_entrypoints` (required in this mode, each one
  of `traefik_entrypoints` when that is set; the routers have no `tls` section, so TLS is set at
  entrypoint level, as the traefik role does). One instance serves any number of hosts on any
  number of domains; the cookie is set per host, so each host name is solved once. On an
  entrypoint it works behind the traefik role's error pages middlewares. Anubis's cookies are
  `Secure`: protect TLS entrypoints only, or set `COOKIE_SECURE` through `anubis_env`.
  `anubis_mode: nginx` (for nginx `auth_request`) joins its own network `anubis_nginx_network`
  (default `noixdev-anubis`), which the role creates as an internal bridge network when it is
  missing (an existing one that is not internal is refused): it never becomes the gateway of the
  nginx container that joins it, and Anubis has no internet access there. Every member reaches
  the nginx container's listeners on it (internal ones included) and Anubis never connects to
  nginx, so only containers trusted like the nginx container may join it. `anubis_networks`
  (default `[]`) names further existing networks to join. nginx mode writes no Traefik objects
  and removes an `anubis.yml` only when it carries the role's marker line (one written by
  traefik mode); a file of that name from elsewhere stays. A host runs one mode: Traefik routers
  and an nginx cannot share its Anubis.
- `anubis`: a limitation of traefik mode: `anubis-challenge` turns every 401 from behind
  `anubis@file` into the challenge page, the 401s of the backend and of the router's own
  middlewares (such as `basicAuth`) included, also on paths the policy ALLOWs and for clients
  Anubis lets through. The client gets Anubis's answer with status 401 (a browser the challenge
  page, a client Anubis lets pass such as `curl` a short page pointing back at the same URL),
  without the backend's `WWW-Authenticate` and body. Routers whose legitimate clients get a 401 (container registries, Basic auth, token
  APIs, SPAs that answer 401) must therefore not use `anubis@file`, and entrypoint mode suits only
  entrypoints that carry no such router. nginx mode is not affected: upstream 401s pass through.
  A redirect mode with its own Anubis host (Anubis's `PUBLIC_URL` setup) would avoid this; it is
  not part of the role yet.
- `anubis`: `anubis_redirect_domains` (host names with at least one dot, `*.example.com` for
  subdomains, a host on another port than 80/443 with its port; a bare `*` or `*.*` is refused)
  is required in both modes: without it Anubis would redirect a solved challenge to any host.
  The policy (`policy.yaml`) is Anubis's own asset and pass-challenge paths, then
  `anubis_policy_allow` (Anubis bot rules, such as ALLOW rules for API and sync paths), then
  Anubis's default bot list, with `status_codes` CHALLENGE 200 and DENY 403. Unlike Anubis's
  graded default thresholds (metarefresh for weight 1-9, difficulty 2 for browsers), there is
  one tier: weight 0 or less passes (curl), anything above (browsers) gets the proof of work at
  `anubis_difficulty` (default `4`); an empty User-Agent is denied (403), as in Anubis's default
  policy. `anubis_impressum` sets Anubis's imprint block. The signing key (`ed25519.key`, mode
  `0600`) is generated once on the host, or written from `anubis_private_key` (64 hex digits,
  never logged), so cookies survive restarts and recreates. `anubis_env` adds container
  environment but cannot set `BIND`, `METRICS_BIND`, `TARGET`, `PUBLIC_URL`, `REDIRECT_DOMAINS`,
  `DIFFICULTY`, `ED25519_PRIVATE_KEY_HEX(_FILE)` or `HS512_SECRET` (names without `=` or
  whitespace, values without line breaks); its values are in `compose.yaml` (mode `0600`) and
  reach the check container through a `0600` env file, never a command line or the log, and a
  secret among them belongs in a vault. `anubis_cpus` and `anubis_memory` limit the container
  (read-only, no capabilities, no published port).
- `anubis`: new settings (policy, `anubis_env`, image or given key) are rendered to
  `anubis_dir/staged/` and first run in a throwaway container (`noixdev-anubis-check`, no
  network); only when its health check answers within `anubis_health_timeout` seconds (default
  `60`) do they replace the running Anubis's files and container. Otherwise the run fails with
  "Anubis is not healthy with the new settings" and Anubis's log, and the running Anubis, its
  files and `anubis.yml` stay as they were. Every run then waits for the container's health
  check (`/healthz` on the metrics port) and fails with "Anubis is not healthy" otherwise; a
  stopped container is started again. `anubis.yml` is written only once Anubis is healthy, so a
  failed first install leaves routers that name `anubis@file` without the middleware (404).
  While Anubis is down, every router that uses `anubis@file` answers 500 (fails closed), also
  behind error pages that replace only 502-504; Anubis's own `/.within.website/` paths answer
  500 on an entrypoint with `anubis@file` and 502 where only single routers use it. A given key
  is staged only when it differs from the running one (compared by checksum) and the staged copy
  is removed once it is in place, or after a failed check. The container carries the SHA-256 of
  `policy.yaml` and of the key file as labels (`noixdev.infra.anubis.policy-sha256`,
  `noixdev.infra.anubis.key-sha256`; never the key), so a run that stopped after putting new
  files in place is finished by the next one, which recreates the container.
- `crowdsec`: reports what the role did not install or write, with a warning that never counts as
  a change; nothing is deleted. Reported are collections that `crowdsec_collections` does not list
  (the dependencies of listed collections, and of the reported ones, are not), sources in
  `/etc/crowdsec/acquis.yaml` and files in `/etc/crowdsec/acquis.d/` other than `noixdev-*.yaml`.
  The package's `setup.*.yaml` are still removed (`crowdsec_remove_setup_acquisitions`).
- `fail2ban`: warns about files in `/etc/fail2ban/jail.d/` that neither the role
  (`50-noixdev.local`) nor the fail2ban package wrote, and keeps them.
- `dashy`: new role that runs the Dashy start page (`dashy_image` and `dashy_version`, default
  `4.9.0`) behind Traefik on `dashy_host` (`dashy_traefik_network`, `dashy_traefik_entrypoint`),
  publishing no host port. `dashy_config` holds the whole config (`pageInfo`, `appConfig`,
  `sections`); the role renders it to `dashy_dir/conf.yml`, mounted read-only, and sets
  `appConfig.preventWriteToDisk`, `preventLocalSave` and `disableConfiguration` to `true` so the page
  cannot be edited in the browser. A changed config recreates only Dashy; an empty `sections` list
  is refused before the host is touched. `dashy_dns` sets the container's DNS servers so status
  checks resolve internal names; `dashy_cpus` and `dashy_memory` limit the container.
- `harbor`: new role that installs Harbor (`harbor_version`, default `v2.15.4`) from its online
  installer, kept per version under `harbor_dir/installer/` (`harbor_installer_url` and
  `harbor_installer_checksum` override the GitHub release download and its md5 check). It renders
  `harbor.yml` (mode `0600`) from `harbor_hostname`, `harbor_external_url`,
  `harbor_admin_password`, `harbor_db_password`, `harbor_data_dir`, `harbor_storage`
  (`filesystem` or `s3` with `harbor_s3`), `harbor_trivy`, `harbor_log_dir` and
  `harbor_log_level`, runs `prepare` only when that file or the Trivy choice changed, and waits
  up to `harbor_wait_timeout` seconds until every service is healthy. Harbor's nginx publishes no
  host port: a compose override joins it to `harbor_traefik_network` with a router for
  `harbor_hostname` on `harbor_traefik_entrypoints` at `harbor_traefik_priority` (default `100`,
  above the error pages routes). The installed version is recorded in
  `harbor_dir/installed-version`; an older `harbor_version` is refused, and so is a run without
  that record over an existing database in `harbor_data_dir/database`. Before `v2.16.0`, whose
  images exist for amd64 only, the role refuses a platform other than amd64 (the host
  architecture, or `DOCKER_DEFAULT_PLATFORM` when it is set) before it changes anything, unless
  `harbor_installer_url` is set.
- `harbor`: a newer `harbor_version` upgrades Harbor. The role fetches the new installer first (a
  failed download leaves Harbor running), writes the marker `harbor_dir/upgrade-failed` (`from`,
  `to`, `backup`, `backup_complete`, `time`), stops every service except the database, takes a
  verified backup into a timestamped directory under `harbor_backup_dir`, stops the database and
  prepares and starts the new version. After success it removes the marker and keeps the newest
  `harbor_backups_keep` backups. On a failure Harbor stays stopped, the marker stays and the run
  fails with the `harbor-restore` command for the backup (or, when the backup did not complete, the
  steps to retry); while the marker exists every run fails at once and changes nothing.
- `harbor`: host scripts `/usr/local/sbin/harbor-backup [<dir>]` and `/usr/local/sbin/harbor-restore
  <dir>` (root, mode `0750`). `harbor-backup` writes one `pg_dump -Fc` file per Harbor database
  (`registry.dump`, read back in full to verify it), a copy of Harbor's `secret` directory (with its
  modes in `secret.modes`), `harbor.yml` and `version` into a new `0700` directory (files `0600`,
  directories `0700`); without an argument it replaces `harbor_backup_dir/latest` only once the
  backup is complete. It fails when `harbor-db` is not running, and without an argument also while
  `harbor_dir/upgrade-failed` exists (an upgrade is running or failed). `harbor-restore` refuses a
  backup of another version than the installed one; it stops Harbor except the database, moves
  clusters the database does not run on (left by a newer PostgreSQL) to
  `harbor_data_dir/database-stale-*`, drops and reloads the databases, restores `secret`, moves the
  Redis data (caches and job queue) aside, runs `prepare` with the role's `harbor.yml`, starts
  Harbor, waits until it is healthy and removes the `upgrade-failed` marker that names this backup.
- `traefik`: entrypoints accept `responding_timeouts` with the optional keys `read`, `write` and
  `idle` (Traefik durations such as `600s`, `0s` for no limit). They render as
  `transport.respondingTimeouts` of that entrypoint only; other entrypoints keep Traefik's
  defaults. `read` limits reading a request, so large uploads (pushes) need a long one; `write`
  limits writing a response, so large downloads (pulls) need a long one or `0s`.
- `portainer`: `portainer_admin_password` (server only, at least 12 characters) makes Portainer
  create the user `admin` with that password on a start without an admin, through
  `--admin-password-file`, so the five-minute setup window no longer applies. The role keeps the
  password in a file with mode `0600` and recreates the container when it changes. Portainer
  ignores it once an admin exists, so changing it later does not change the password.
- `cloudpanel`: new role for CloudPanel CE v2 on Ubuntu 24.04 (any other release is refused
  before the host is changed). Where CloudPanel is not installed (no `clpctl`), it checks that
  SSH runs on port 22 (the installer's firewall opens only 22), downloads the official installer
  (`cloudpanel_installer_url`), verifies it against `cloudpanel_installer_sha256`, runs it with
  `cloudpanel_db_engine` (default `MARIADB_11.4`) and `cloudpanel_swap`, and removes it right
  after the run. It never runs the installer where CloudPanel exists or has left traces
  (`/home/clp`, or any dpkg state of `cloudpanel`), and refuses a `cloudpanel` package that is
  not fully installed. With `cloudpanel_admin_user`,
  `cloudpanel_admin_email` and `cloudpanel_admin_password` it creates the first admin with
  `clpctl user:add` on the fresh install; without them the owner finishes CloudPanel's first-visit
  setup. Sets the fact `cloudpanel_installed`.
- `cloudpanel`: every run (`cloudpanel_update`) runs `clp-update` (changed when the CloudPanel
  version changed) and then upgrades all packages with `apt-get dist-upgrade`, keeping changed
  config files and without autoremove. A simulated upgrade runs first: if it would remove or
  downgrade packages, the run fails and names them before anything is upgraded. When
  `/var/run/reboot-required` exists after the updates it reboots (`cloudpanel_reboot`,
  `cloudpanel_reboot_timeout`, `cloudpanel_reboot_boot_time_command`) and waits until nginx,
  PHP-FPM, the database and CloudPanel are all active; a required reboot that is not taken is a
  warning and the fact `cloudpanel_reboot_pending`. The handlers of the roles before it run right
  after it has listed the running compose projects; after a reboot, a Docker package upgrade or
  a restart of Docker it runs `docker compose up -d --no-recreate` for each of them
  (`cloudpanel_compose_reconcile`), skipping with a warning projects whose compose files are
  missing and hosts without the compose plugin. Then it requests `cloudpanel_health_urls` and the
  UI at `https://<cloudpanel_ui_host>:8443` (`cloudpanel_ui_check`) from the Ansible controller;
  a 5xx or no answer within `cloudpanel_health_timeout` seconds per URL (requests of at most 10
  seconds, 5 seconds apart) fails the run. Every failure names its step; nothing is rolled back.
  A failure from the updates on still runs the health check and adds its result to the message.
  A run on an up-to-date server changes nothing.
- `cloudpanel`: noix error pages in CloudPanel's nginx (`cloudpanel_error_pages_enabled`, default
  `true`). The role exports the pages of `cloudpanel_error_pages_image` (default
  `noixdev/error-pages:1.0.0`) once with Docker to static files in `cloudpanel_error_pages_dir`
  (default `/var/www/noix-error-pages`), in theme `cloudpanel_error_pages_theme` (default `classic`)
  and with `cloudpanel_error_pages_env` (languages and the rest, as on the Traefik hosts); no
  container keeps running, and a new image, theme or environment exports them again. nginx starts
  each page in the first language of the browser that the pages offer. The default codes
  (`cloudpanel_error_pages_default_codes`, default `502, 504, 413, 414`) are `error_page` lines at
  http level (`sites-enabled/noix-error-pages-http.conf`), which a vhost's own `error_page`
  replaces; `include /etc/nginx/noix-error-pages.conf;` in each server block serves the files.
  The role adds that line to CloudPanel's system vhost templates (new sites; CloudPanel imports
  them again every day and on updates, so every run checks them) and once to each existing
  site's vhost, in CloudPanel's database (what the vhost editor shows and saves) and in the vhost
  file (LF or CRLF, as the vhost editor stored it). A site whose include was removed in the
  vhost editor is reported, never changed again (fact `cloudpanel_error_pages_without`; the
  record keeps the site's id and creation time, so a site recreated under the same domain counts
  as new, and a lost record, or an include added by hand before the first run, reports instead
  of patching, fact `cloudpanel_error_pages_record_lost`). Nothing nginx rejects is left in place: an nginx
  configuration that fails `nginx -t` before the run is reported as such and nothing is changed;
  the vhosts are written, `nginx -t` runs before CloudPanel's database is committed, and when it
  or the commit fails, each file is restored on its own (a file that cannot be restored is
  named), the transaction is rolled back and the run fails; the three nginx files are kept with
  a backup until `nginx -t` passed. System templates with an `error_page` of their
  own are reported (fact `cloudpanel_error_pages_template_overrides`). A new export goes live
  with one rename and checks that every page has the theme.
  `include /etc/nginx/noix-error-pages-all.conf;` opts a site in to a page for every 4xx and 5xx.
- `cloudpanel`: maintenance switch. `/usr/local/sbin/noix-maintenance on|off|status` shows the
  maintenance page instead of the 5xx pages nginx generates, on every site of the server, and
  reloads nginx; sites that answer are not affected. It runs `nginx -t` first and switches
  nothing when it fails, and switches back when the reload fails. Every run sets it to
  `cloudpanel_maintenance` (default `false`).
- `noixdev.infra.warn`: action that shows a message as an Ansible warning without failing the
  run (used by `cloudpanel`).

## 0.4.0 — 2026-11-11

- `dns`: new role that runs CoreDNS on the host network. It answers `dns_records` (names with
  IPv4 and IPv6 addresses, `dns_ttl`) for the clients in `dns_allow` (all others are REFUSED) and
  forwards everything else to `dns_upstreams`, cached for `dns_cache` seconds. Records are served
  from a managed hosts file (not the host's `/etc/hosts`), and changes to them apply without a
  restart. It binds only `dns_bind` (wildcard addresses are refused), plus the node's Tailscale
  addresses with `dns_bind_tailscale`. Further variables: `dns_image`, `dns_dir`, `dns_project`,
  `dns_log_queries`, `dns_cpus`, `dns_memory`. The container is read-only without capabilities
  except `NET_BIND_SERVICE` and cannot gain privileges, and is recreated when the Corefile or
  the compose file changes.
  `dns_allow` must not contain `0.0.0.0/0` or `::/0`.
- `base`: `base_nonlocal_bind` (and `base_sshd_listen_addresses`) now also sets
  `net.ipv6.ip_nonlocal_bind`, so services can bind IPv6 addresses that are not up yet. It is
  skipped on a kernel without IPv6 (`ipv6.disable=1`).
- `traefik`: `traefik_acme_challenge: http` issues certificates with HTTP-01 on
  `traefik_acme_http_entrypoint` (an entrypoint on host port 80), one per router host, without a
  DNS API. The cert resolver is named after the challenge (`dns` or `http`); `dns` stays the
  default.
- `base`: the static route unit is started by the role itself, not only by a handler, so a run
  that failed after writing the script no longer leaves the routes unapplied.

## 0.3.0 — 2026-11-10

- `traefik`: entrypoints take `host_port`, the port published on the host (default: `port`), so
  two entrypoints can share a host port on different bind addresses. A redirect to such an
  entrypoint goes to its `host_port`.
- `traefik`: entrypoints take `middlewares`, which every router on the entrypoint gets; not
  allowed together with `redirect_to`.
- `traefik`: `traefik_docker_allow_empty_services` sets the Docker provider's
  `allowEmptyServices`, so containers without a healthy server keep their router (Traefik v3 answers them with 500, not 503).
- `traefik`: optional error pages (`traefik_error_pages_*`, off by default). The role writes
  `dynamic/error-pages.yml` with the middlewares `error-pages-errors` and
  `error-pages-compress`, which it attaches to the listed entrypoints, routers that answer with
  a fixed page (catch-all for unknown hosts, guards for names that must not be served on an
  entrypoint) and the service `error-pages`. Turning the feature off removes the file after
  Traefik has restarted without the middlewares.
- `traefik`: the error pages container (`traefik_error_pages_image`, default
  `noixdev/error-pages:1`) runs in the Traefik compose project as service `error-pages`:
  read-only, as 65532, without capabilities, with the image's healthcheck, CPU and memory limits
  and a volume on `/data` for maintenance mode. `traefik_error_pages_env` sets its environment
  (default theme `glass`, languages `en,de`). With `traefik_error_pages_container: false` it is
  not run and `traefik_error_pages_url` points at a service elsewhere.

## 0.2.0 — 2026-11-10

- Role `fail2ban`: journal backend, nftables bans, `sshd` and `recidive` jails, extra jails.
- Role `crowdsec`: CrowdSec and the iptables firewall bouncer from the official repository
  (key fingerprint checked), collections, acquisitions, allowlist parser, `INPUT` and
  `DOCKER-USER` chains, optional console enrollment.
- Shared `security_allowlist`, read by `fail2ban` and `crowdsec`, so management networks are
  never banned; entries are checked to be IP addresses or CIDRs.
- `base`: the sshd hardening drop-in now also enforces public-key-only authentication, connection
  and session limits, client keepalives, no agent forwarding, tunnels or gateway ports,
  `LogLevel VERBOSE` and modern key exchange, cipher and MAC lists. New variables
  `base_sshd_permit_root_login`, `base_sshd_allow_users`, `base_sshd_allow_tcp_forwarding` and
  others; see the role's argument specs.
- Roles `base`, `docker`, `tailscale`, `traefik`, `portainer`, `pulsix_manager`, `pulsix_worker`.
- Supported on Ubuntu 24.04 and 26.04; host roles are tested on both (`tests/host/run.sh`).
