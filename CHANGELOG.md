# Changelog

## Unreleased

- `portainer`: an agent registers itself as an environment on a Portainer server. Set
  `portainer_agent_register_url` (the server, e.g. `https://portainer.example.com`) and
  `portainer_agent_register_api_token` (an access token; the run fails before any change when it is
  empty); `portainer_agent_register_address` pins the URL's host name to an address (curl
  `--resolve`, IPv6 allowed, TLS is still verified), `portainer_agent_register_name` (default the
  inventory host name) names the environment and `portainer_agent_register_endpoint` (default the
  first `portainer_agent_bind` address, port 9001) is where the server dials the agent. The
  environment is matched by exact name: missing is created (retried while the agent starts), the
  same name with the same endpoint is left alone, and the same name with another endpoint fails
  the run naming both and changes nothing. Nothing is created in check mode. The token only lives
  in a temporary 0600 header file that curl reads and that is removed afterwards, never on a
  command line or in the output. Removing or editing environments is not handled; the host needs
  curl (the `base` role installs it).
- `tailscale`: the first login gives up after `tailscale_login_timeout` seconds (default 120)
  instead of waiting forever. The run then fails with what `tailscale up` reported or, when the
  tailnet requires device approval, names the node to approve in the admin console. The auth key
  file is removed either way.
- Releases are cut by the `release` workflow (Actions tab, `bump` patch, minor or major, `dry_run`
  on by default): it checks main, CI, the signed test run and the changelog, then bumps
  `galaxy.yml` and `CHANGELOG.md`, tags `vX.Y.Z`, publishes the release, updates the README
  install example and announces it on Discord. The steps by hand stay in `CONTRIBUTING.md`.
- `nginx`: new role that installs nginx of one stable series from nginx.org (`nginx_version`, a
  quoted `major.minor` such as `"1.30"`; Ubuntu 24.04 and 26.04, any other release is refused
  before any change) and serves the sites of `nginx_sites`, the complete list: a site that leaves
  it loses its config, while its web root, logs and certificate stay. An apt pin keeps nginx in the
  series and Ubuntu's nginx packages out; the nginx.org origin joins unattended-upgrades. An
  installed nginx of another series, or Ubuntu's, is refused before any change. A site is a PHP
  site (`php_pool`, fastcgi to `/run/php/<pool>.sock`; only `php_front_controller` and
  `php_scripts` run, any other `.php` file answers 404), a proxy site (`proxy`, with WebSocket
  upgrades) or a static site; `www-data` joins each site's group, so web roots must be
  group-readable. TLS is `letsencrypt` (certbot, `nginx_acme_email`, HTTP-01 through a webroot,
  renewals reload nginx), `off`, or `{cert, key}` with OCSP stapling through `nginx_resolvers`
  (`127.0.0.53`, so other hosts than systemd-resolved ones set it). Global hardening: TLS 1.2 and
  1.3 with Mozilla's intermediate ciphers, `server_tokens off`, and a default server that closes
  the connection for an unknown host name. Per site: security headers and HSTS, 404 for dotfiles,
  `composer.json` and dumps (`hardening`), `rate_limit` zones (answer 429), `basic_auth` with an
  allowlist (`nginx_real_ip_from` for trusted proxies; the controller needs passlib), `headers`
  and `extra`. Every config change is tested with `nginx -t` before nginx reloads, and a config
  nginx rejects is put back. The noix error pages (`nginx_error_pages`, on by default, so the host
  needs Docker unless it sets `false`) answer nginx's own errors only; an app's own error pages
  pass through. A site with `anubis: true` is checked by the `anubis` role in host mode on
  `127.0.0.1:nginx_anubis_port` (keep it equal to `anubis_host_port`); a site cannot have both
  `anubis` and `basic_auth`, and 401 must not be among `nginx_error_pages_codes` while a site has
  Anubis. Deploy snippets (`user_includes`, `nginx_user_includes`, `nginx_include_user`) are not
  supported yet and are refused. `nginx_ipv6` ignores link-local addresses.
- `nginx`: a link is followed only to a file of its own owner in every part of a path, the web
  root's own path too (`disable_symlinks if_not_owner` without `from=`): a site user's link in its
  root path (a deploy's `current`) re-pointed at another site's tree is not served. A deploy's
  `current -> releases/N` works when the site user owns both; a root reached through a link of one
  owner to another owner's tree is not served, so use the real path or a link of the same owner.
- `nginx`: the global config (`nginx.conf`, the default server, the hardening) is written and
  tested with the site configs in one `nginx -t`, and put back with them when nginx rejects the
  config: a rate limit zone or an `nginx_http_extra` definition leaves in the same run as the site
  that stops using it.
- `nginx`: a Let's Encrypt certificate whose renewal config names another ACME server than
  `nginx_acme_server` is reissued from `nginx_acme_server` on the next run, so a switch from
  Let's Encrypt's staging directory to production replaces the staging certificates.
- `nginx`: hardened sites also answer 404 for compressed dumps and backups (`*.sql`, `*.bak` and
  `*.swp` with `.gz`, `.bz2`, `.xz`, `.zst`, `.zip`, `.7z`, `.lz4` or `.lzma`, in any case).
- `nginx`: a site with the user or group `www-data`, or with a privileged group (`root`, `sudo`,
  `admin`, `wheel`, `adm`, `shadow`, `disk`, `kmem`, `docker`, `lxd`, `incus-admin`, `libvirt`,
  `systemd-journal`), is refused before any change: `www-data` joins a site's group, so every
  nginx worker would get it.
- `nginx`: a failed certificate request says what each site serves until a run gets it: a site
  with a certificate keeps its TLS block, a site without one (new, or switched to `letsencrypt`)
  only its HTTP block, the ACME challenges and a redirect to HTTPS, none of its content.
- `anubis`: new mode `host` for an nginx on the host itself (the `nginx` role's sites with
  `anubis: true`): the container publishes `127.0.0.1:anubis_host_port` (8923) only and joins none
  of the other modes' networks. One mode per host.
- `php`: new role that installs PHP versions from the ondrej/php PPA (Ubuntu 24.04 only for now; any
  other release is refused before any change) and runs every pool in `php_pools` as a PHP-FPM
  master of its own (`php-fpm@<name>`, socket `/run/php/<name>.sock` without a version in it,
  owned by the pool user and `php_fpm_listen_group`). A config change reloads only that pool, a
  version change restarts only that pool. Each pool has `/php-fpm-ping` (`pong`) and
  `/php-fpm-status`. `php_pools` is the complete list: a pool that leaves it is stopped and its
  config removed; its `tmp_dir` and log stay. Versions that leave `php_versions` stay installed,
  with their `php<v>-fpm` service stopped. With `php_fpm_per_pool_service: false` (classic mode)
  the pools run in the packages' `php<v>-fpm` services instead, and switching moves every pool.
  Pool `env` values starting with `$` are refused (FPM would expand them), a changed socket owner
  or listen group restarts the pool, and a config FPM rejects never replaces a running one: it is
  tested before anything is switched. Pool `env` and `ini` values never appear in the run's output.
  A pool with group root (gid 0) and pool names longer than 64 characters are refused before any
  change. `tmp_dir` and its `session`, `upload` and `sys` dirs are created without following
  links (the three dirs as the pool user): a link in `tmp_dir` or its path stops the run, naming
  it. A run that fails after a change, for example on a typo in one version's extensions, still
  reloads or restarts the pools for what it changed before it fails. Ubuntu's `php<v>-*`
  packages are pinned to -1 and the PPA preferred, so a run that cannot reach the PPA never
  installs Ubuntu's PHP. The PPA joins
  unattended-upgrades in both modes; with one master per pool an apt hook restarts the pools of
  each version with an upgraded `php<v>-*` package (extensions too) one at a time
  (`/usr/local/sbin/php-fpm-rolling-restart`). Each restart is bounded by
  `php_fpm_restart_timeout`; a pool that does not come back stops the rolling restart (see
  `journalctl -t php-fpm-rolling-restart`) while apt still succeeds. needrestart, installed by
  default on Ubuntu servers, is told to leave the `php-fpm@` pools to that hook
  (`/etc/needrestart/conf.d/50noixdev-php-fpm.conf`) instead of restarting them all at once. In
  classic mode the package's own restart applies, needrestart's included.
- `composer`: new role that installs Composer as `/usr/local/bin/composer` from the official phar
  at an exact version (`composer_version`) checked against a pinned SHA-256 (`composer_sha256`,
  from getcomposer.org's `.sha256sum`; a wrong checksum leaves the installed Composer alone),
  Composer 1 as `/usr/local/bin/composer1` with `composer1_enabled`, and `~/.config/composer/auth.json`
  for the users in `composer_auth` (mode 0600, written as the user, content never printed). The role
  owns the whole file; `state: absent` removes it. A user listed twice, an unknown user and a
  `present` entry without `auth` are refused. It needs a `php` on the host and installs
  `ca-certificates`.
- `portainer`, `traefik`, `dashy`, `pulsix_manager`, `pulsix_worker`, `dns`, `harbor`, `listmonk`,
  `anubis` and `mailcow` check for Docker first, before they change anything: the `docker` CLI,
  the compose plugin (`docker compose version`) and a daemon that answers (`docker version`).
  Without them the run fails with "Docker is not installed or not running on <host>; run
  noixdev.infra.docker (or install Docker with the compose plugin) before <role>" and the reason,
  instead of a module error later in the role. The roles still do not depend on the `docker`
  role: Docker comes from the playbook (the `docker` role, or Docker's own packages as on a
  mailcow host). The check is the new internal role `docker_check`; it changes nothing.
- `base`: new `base_mounts` list that mounts block devices persistently through fstab, for
  example a Hetzner volume (`/dev/disk/by-id/scsi-0HC_Volume_<id>`): `src`, `path`, `fstype`
  (`ext4`, the default, or `xfs`) and `opts` (default `defaults,nofail`). A device without any
  filesystem whose first and last MiB read as zeros is formatted once; a device is never
  reformatted. Before anything changes the role fails on a missing or unreadable device, a
  different filesystem, a partition table, a device without a filesystem that is not blank,
  the device in fstab (by path, link, `UUID=` or `LABEL=`) or mounted at another path
  (Hetzner's own automount, for example), a path that is another device's mountpoint, not
  empty, a file or behind a symlink, a path with whitespace or a backslash, and repeated
  entries or devices. The host test suites use loop devices for it.
- `oh_my_zsh`: new role that installs zsh and git, checks Oh My Zsh out once at a pinned commit
  (`oh_my_zsh_version`, a full 40-character SHA; no branches, no auto-update) into the root-owned
  `oh_my_zsh_dir` (default `/usr/local/share/oh-my-zsh`, readable for everyone also under a strict
  umask) and writes a managed `~/.zshrc` for each user in `oh_my_zsh_users` (default `root`; the
  home comes from the passwd database, the cache goes to `~/.cache/oh-my-zsh`, which Oh My Zsh
  creates as the user, never into the checkout). A `~/.zshrc` that the role did not write is
  copied once to `~/.zshrc.pre-oh_my_zsh` before the role replaces it; the copy and the managed
  file are written as the user, so a symlink in the home is never followed. The `noix` theme ships
  with the role; set `oh_my_zsh_theme` to a built-in theme, or add your own with
  `oh_my_zsh_theme_content`. `~/.zshrc.local` is sourced when present and never written. Also
  `oh_my_zsh_plugins` and `oh_my_zsh_login_shell`. Before anything changes the role fails on a
  user that does not exist or has no home directory, and on a theme or plugin name with other
  characters than letters, digits, `.`, `_` and `-`. Moving the SHA moves the checkout on hosts
  that have an older one.
- `motd`: new role that writes one banner to `/etc/update-motd.d/` (`motd_filename`, default
  `05-noix-managed`): `motd_title`, `motd_lines` (printed verbatim, never executed) and, with
  `motd_sysinfo`, host name, OS, uptime, load, memory, root disk and the running containers when
  `docker.service` is active and Docker answers (a stopped daemon is never started again through
  `docker.socket`). `motd_remove_snippets` lists the snippets the role removes (Ubuntu's help
  text, Landscape and news; add the file names of banners from earlier setups to the list).
  `motd_enabled: false` removes only the managed file; after changing `motd_filename`, list the
  old name in `motd_remove_snippets`.
- `paperless`: new role that runs Paperless-ngx v3 (pinned, major 3 only) with PostgreSQL, a Valkey
  broker, Tika and Gotenberg (`paperless_tika`) and a Samba scanner share (`paperless_samba`) as one
  compose project, behind Traefik with no published HTTP port. It needs Docker Engine 25 or later
  (the webserver's health check uses `start_interval`). `paperless_hostname`, `paperless_secret_key`
  and `paperless_db_password` are required, the first admin only for a fresh install. The data lives
  in `paperless_data_dir`, which can be a `base_mounts` volume (`paperless_data_dir_mountpoint`
  fails every run unless it is a mountpoint). Only an install or an import creates the data
  subdirectories and the containers bind them without creating them, so a volume that is not mounted
  keeps the containers from starting, and a run that finds the compose file without the
  subdirectories fails in every state. More `PAPERLESS_*` settings go through `paperless_env`; the
  ones the role sets itself are refused. The share offers SMB2 or newer only
  (`paperless_samba_min_protocol`, never `NT1`), and `paperless_samba_bind` is required, with no
  `0.0.0.0` default, because Docker bypasses the host firewall. An export of an old installation is
  imported once with `paperless_import_dir` (below `paperless_data_dir/export`, made by the exact
  pinned version, into an empty installation; later runs ignore it through `imported.yml`). Before
  an update the role takes a backup in `backups/`: `paperless.dump`, a copy of `data/` and `media/`
  as hard links; the newest `paperless_dumps_keep` are kept. A failed update is rolled back, writes
  `update-failed`, which blocks that version (after a rollback that failed too, every version until
  the backup is restored by hand), and leaves `<backup>-failed`, which is never pruned; Samba starts
  only once the new version is healthy; a Samba that does not start then fails the run without a
  rollback. A failed install or import stops the stack, Samba included. Refused before any change: a
  PostgreSQL image older than 18 (older images keep the database on a volume of their own, outside
  `paperless_data_dir`), a downgrade, a PostgreSQL major other than the database's, more than one
  PostgreSQL cluster, a `paperless_db_password` that the database does not take (PostgreSQL takes
  the password only when it creates the database: set a new one in the database first, as the
  message says), a compose file that is not YAML (the parser's error, which could quote a line with
  a secret, is not shown), an import into an existing installation, of another version or of an
  export that `paperless_uid` cannot read, and a leftover `install-incomplete` marker (beside
  `imported.yml` with a message to remove only the marker). The admin password and the import
  passphrase reach the container through stdin, so they are not in the output even at `-vvv`. See
  the role's guide in the docs.
- `paperless`: Paperless counts as healthy only when it can use its database. Once the webserver
  and the database are healthy, `manage.py migrate --check` and a read of the documents run in the
  webserver container as the `paperless` user, each bounded by what is left of
  `paperless_health_timeout`, but at least 10 seconds. So an update whose new release starts healthy
  while a migration is not applied is rolled back and recorded in `update-failed`, and a run
  without changes fails, within the health timeout (at least 10 seconds for each database check),
  while the database does not answer.
- `paperless`: an update that did not finish is no longer taken for a finished one. From its first
  change until it is healthy or rolled back, an update keeps `update-in-progress` in `paperless_dir`
  (root, `0600`: the versions, the step and the backup, with copies of the compose file and the
  Samba files). A run that stopped during the backup changed nothing else: the next run removes the
  partial backup and the marker, then goes on as any run does: it updates only while
  `paperless_version` is still newer. A run that stopped after it makes every later run refuse
  before any change, naming both versions and the backup, until either
  `paperless_restore_interrupted: true` for one run restores the backup with the files from before
  the update (and ends without trying the update again; the next run does), or the marker is removed
  to keep Paperless as it is. A restore that fails writes `update-failed` as a failed rollback does.
  The variable is refused without an interrupted update, a marker that is not YAML, lacks its keys
  or cannot be read is refused, a marker beside an `install-incomplete` marker is refused naming
  both files, and a marker beside `update-failed` of the same backup (a rollback that stopped after
  it wrote that) is removed, `update-failed` deciding, once no other refusal stops the run. With the
  variable set beside an `update-failed` of the same backup, the variable itself is refused (nothing
  is left to restore); beside one of another backup, its refusal says that the variable does not
  apply while that file stands. Beside an `update-failed` of another backup (an earlier update that
  was rolled back) it is handled as without one. A rollback restored again keeps the data of the
  failed attempt in `<backup>-failed` and sets the newer ones aside in `<backup>-failed-<time>`; a
  restore stopped while it puts `data/` and `media/` back can be run again.
- `n8n`: an update that did not finish is no longer taken for a finished one. From its first change
  until it is healthy or rolled back, an update keeps `update-in-progress` in `n8n_dir` (root,
  `0600`: the versions, the step and the backup, with a copy of the compose file). A run that
  stopped during the backup changed nothing else: the next run removes the partial backup and the
  marker, then goes on as any run does: it updates only while `n8n_version` is still newer. A run
  that stopped after it makes every later run refuse before any change, naming both versions and the
  backup, until either `n8n_restore_interrupted: true` for one run restores the backup with the
  compose file from before the update (the database and the n8n home too, workers among the
  services; the run ends without trying the update again, and the next one does), or the marker is
  removed to keep n8n as it is. A restore, like a rollback, stops every container of the project
  before it restores the database, also one of a service that the compose file on disk does not
  name. A restore that fails writes `update-failed` as a failed rollback does. The variable is
  refused without an interrupted update, a marker that is not YAML, lacks its keys or cannot be read
  is refused, and a marker beside `update-failed` of the same backup (a rollback that stopped after
  it wrote that) is removed, `update-failed` deciding, once no other refusal stops the run. With the
  variable set, a refusal of an `update-failed` says that the variable does not apply while that
  file stands. Beside an `update-failed` of another backup (an earlier update that was rolled back)
  it is handled as without one. A rollback restored again keeps the home of the failed attempt in
  `<backup>-failed` and sets the newer one aside in `<backup>-failed-<time>`; a restore stopped
  while it puts the home back can be run again. No database check of its own is added: n8n's
  readiness (`/healthz/readiness`) already fails while a migration is not applied or the database
  does not answer.
- `nodejs`: new role that installs one Node.js major series from NodeSource (`nodejs_version`,
  default `"24"`) and global npm packages at exact versions (`nodejs_npm_packages`, each with
  `name` and `version`; ranges and tags are refused). A `nodejs` of another series (Ubuntu's own,
  another NodeSource series) is refused before any change: a series change is a separate step.
  Ubuntu's `nodejs` is pinned to -1, so a run that cannot reach NodeSource never installs it.
- `redis`: new role that installs Redis from packages.redis.io, pinned to `redis_version`
  (default `"8"`). Without `redis_instances` the package's `redis-server` runs on
  `redis_bind_address:6379` (`redis_password`, `redis_maxmemory`, `redis_maxmemory_policy`,
  `redis_persistence`); with it, each entry runs as `redis-server@<name>` with its own config,
  data directory and log, on a `port` or a `unixsocket` (`/run/redis-<name>/redis.sock`, group
  `redis-<name>`, `clients` added to the group). Entries are checked before any change. An
  instance without a password on a port is open to every local user: set a password or use a
  socket instance. An instance that leaves the list is stopped and disabled; its data stays. A
  `redis-server` of another series, or one that is not from packages.redis.io (Ubuntu 26.04's
  own 8, for example), is refused before any change; Ubuntu's Redis packages are pinned to -1.
- `mariadb`: new role that installs MariaDB from mariadb.org, pinned to `mariadb_version`
  (default `"11.8"`), on `mariadb_bind_address` (default `127.0.0.1`), with `mariadb_settings`,
  `mariadb_databases` and `mariadb_users`. root has no password and uses the unix socket. On
  every run each listed user gets its password and exactly its listed privileges (`_` and `%` in
  `<db>.*` are escaped); role grants and PROXY grants are not revoked, and databases and users
  that leave a list stay. A privilege the server does not know stops the run naming the user (the
  passwords are set in a task of their own, without logging). For fresh servers: another series,
  a server from Ubuntu's archive (even of the pinned series) or MySQL on the host is refused
  before any change.
- `mysql`: new role that installs MySQL Community Server from MySQL's apt repository, pinned to
  `mysql_version` (default `"8.4"`), with the same variables and rules as `mariadb`
  (`mysql_settings`, `mysql_databases`, `mysql_users`). The repository has amd64 packages only:
  other architectures are refused. The role pins Ubuntu's `mysql-*` and `libmysqlclient*`
  packages to -1 host-wide, accounts use `caching_sha2_password`, and the X protocol listens on
  the bind address too. Both addresses are written before the package is installed (its own
  config sets none), so a first run that stops early never leaves MySQL on every interface.
  Another series, a server from Ubuntu's archive or MariaDB on the host is
  refused before any change.
- `tandoor`: new role that runs Tandoor Recipes 2 (`tandoor_version`, pinned, major 2 only) and
  PostgreSQL 18 or newer as one compose project in `tandoor_dir` (default `/opt/tandoor`), behind
  Traefik with no published port. It needs Docker. `tandoor_hostname`, `tandoor_secret_key` (at
  least 32 characters) and `tandoor_db_password` are required, the first admin
  (`tandoor_admin_user`, `tandoor_admin_password`, `tandoor_admin_email`) only for a fresh install,
  which creates the admin and the admin's first space itself, so nothing is left to set up on the
  first login. Open registration is always off; users join through Tandoor's invite links, and
  `tandoor_email` (SMTP) sends invites and password resets. The data lives in `tandoor_data_dir`,
  which can be a `base_mounts` volume (`tandoor_data_dir_mountpoint` fails every run unless it is a
  mountpoint); a run that finds the compose file without its data subdirectories fails in every
  state. Two Traefik routers share `tandoor_hostname`: the pages (`tandoor_traefik_middlewares`) and
  the paths the web UI and apps call without a page, `/api/`, `/_allauth/` and, with local media,
  `/media/` (`tandoor_traefik_api_middlewares`), one priority above. They answer 401 or 403 without
  a session, so a challenge such as Anubis belongs on the pages router only.
  `tandoor_trusted_proxy_count` (default 1) is the number of proxies in front of Tandoor; the role
  adds the image's own nginx for `ALLAUTH_TRUSTED_PROXY_COUNT`, without which every visitor shares
  one login rate limit. Media go to `tandoor_data_dir/mediafiles`, or to an S3 bucket with
  `tandoor_s3` (the secret key in a `0600` file that the container reads, not in the compose file or
  `docker inspect`; a new secret key recreates the Tandoor container, not the database; the
  container carries a salted hash of the key as a label, so a run after a failed start recreates it
  too). The media mode is fixed at install: a run that switches between local media and S3 is
  refused. More settings go through `tandoor_env`; the ones the role sets itself, `DATABASE_URL` and
  `SECRET_KEY_FILE` among them, and keys without a value are refused. Before an update the role
  takes a backup in `<tandoor_data_dir>/backups/` (`tandoor.dump`, a hard-link copy of local media
  and the compose file; the S3 secret file is not in it); the newest `tandoor_dumps_keep` complete
  backups are kept, while leftover `.partial` and `-failed` directories are not pruned. A failed
  update is rolled back (`tandoor_rollback_timeout` bounds the wait for the previous version) and
  writes `update-failed`, which blocks that version; after a rollback that failed too it blocks
  every version, older ones too, until the backup is restored by hand. A failed install stops the
  stack and leaves `install-incomplete`, which makes every later run refuse. Refused before any
  change: a PostgreSQL image older than 18, a downgrade, a PostgreSQL major other than the
  database's, left-over data without a compose file, a `tandoor_db_password` that the database does
  not take (PostgreSQL takes the password only when it creates the database: set a new one in the
  database first, as the message says) and a compose file that is not YAML (the parser's error,
  which could quote a line with a secret, is not shown). The admin password reaches the container
  through stdin, so it is not in the output even at `-vvv`. See the role's guide in the docs.
- `tandoor`: Tandoor counts as healthy only when it can use its database. Once the containers are
  healthy, `manage.py migrate --check` and a read of the spaces run in the web container, each
  bounded by what is left of the health wait (`tandoor_health_timeout`, or
  `tandoor_rollback_timeout` in a rollback), but at least 10 seconds. So an update whose new
  release starts healthy while a migration is not applied is rolled back and recorded in
  `update-failed`, and a run without changes fails, within the health timeout (at least 10 seconds
  for each database check), while the database does not answer.
- `tandoor`: an update that did not finish is no longer taken for a finished one. From its first
  change until it is healthy or rolled back, an update keeps `update-in-progress` in `tandoor_dir`
  (root, `0600`: the versions, the step and the backup, with copies of the compose file and, with
  S3, the secret file). A run that stopped during the backup changed nothing else: the next run
  removes the partial backup and the marker, then goes on as any run does: it updates only while
  `tandoor_version` is still newer. A run that stopped after it makes every later run refuse before
  any change, naming both versions and the backup, until either `tandoor_restore_interrupted: true`
  for one run restores the backup with the files from before the update (and ends without trying the
  update again; the next run does), or the marker is removed to keep Tandoor as it is. A restore
  that fails writes `update-failed` as a failed rollback does. The variable is refused without an
  interrupted update, a marker that is not YAML, lacks its keys or cannot be read is refused, and a
  marker beside `update-failed` of the same backup (a rollback that stopped after it wrote that) is
  removed, `update-failed` deciding, once no other refusal stops the run. With the variable set, a
  refusal of an `update-failed` says that the variable does not apply while that file stands. Beside
  an `update-failed` of another backup (an earlier update that was rolled back) it is handled as
  without one. A rollback restored again keeps the media of the failed attempt in `<backup>-failed`
  and sets the newer ones aside in `<backup>-failed-<time>`; a restore stopped while it puts the
  media back can be run again.
- `n8n`: new role that runs n8n 2 (`n8n_version`, pinned, major 2 and 2.17.0 or newer) and
  PostgreSQL 18 or newer as one compose project in `n8n_dir` (default `/opt/n8n`), behind Traefik
  with no published port. It needs Docker. `n8n_hostname`, `n8n_encryption_key`, `n8n_db_password`
  and the owner (`n8n_owner_email`, `n8n_owner_first_name`, `n8n_owner_last_name`,
  `n8n_owner_password`) are required on every run. The owner comes from the variables, which are
  the source of truth: n8n applies them on every start and locks the owner in the UI, and the
  password is rotated by changing `n8n_owner_password`. The bcrypt hash is computed in the n8n
  image on the target, with the password and the key on stdin. The installation keeps the
  encryption key it was made with: its sha256 is written to `encryption-key.sha256` and a different
  key, or a missing fingerprint file on an existing installation, is refused; back the key up,
  without it the credentials are lost. `n8n_workers` (default 0) switches between n8n's normal mode
  and queue mode: Valkey without data on disk and one compose service per worker, which start once
  the main instance is healthy; switching is a reconfigure and executions that run at that moment
  are lost, and community nodes installed from the UI are not on the workers
  (`N8N_REINSTALL_MISSING_PACKAGES` in `n8n_env`). Two Traefik routers share `n8n_hostname`: the UI
  (the editor, `/rest/` and everything else, `n8n_traefik_middlewares`) and the public endpoints
  (`/webhook/`, `/webhook-test/`, `/webhook-waiting/`, `/form/`, `/form-test/`, `/form-waiting/`,
  `/mcp/`, `/mcp-test/` and, with `n8n_traefik_public_api`, `/api/v1/`;
  `n8n_traefik_webhook_middlewares`), one priority above. The data lives in `n8n_data_dir`
  (`postgres`, `home`, `files`), which can be a `base_mounts` volume (`n8n_data_dir_mountpoint`
  fails every run unless it is a mountpoint); a run that finds the compose file without its data
  subdirectories fails in every state, before any other refusal. More settings go through
  `n8n_env`; the ones the role sets itself, and every `DB_`, `QUEUE_`, `N8N_INSTANCE_OWNER_` and
  `N8N_ENDPOINT_` key, are refused, and so is a key without a value; `N8N_PROXY_HOPS` defaults to 1.
  `N8N_RESTRICT_FILE_ACCESS_TO` defaults to `/files`, so the Read/Write Files from Disk nodes use the
  files directory in `n8n_data_dir` (n8n's own default is inside the container and lost on a recreate).
  `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` (30 seconds, set by the role) lets running executions finish on a
  stop and the containers get 15 seconds more before Docker kills them, so a stop can take about 45
  seconds and an update in queue mode waits for two health phases. Health is n8n's readiness, which
  touches the database. An update takes a backup in `<n8n_data_dir>/backups/` (`n8n.dump` read back
  in full, a copy of the n8n home and the compose file; the newest `n8n_dumps_keep` complete ones
  are kept, `.partial` and `-failed` directories are never pruned) and rolls back when the new
  version is not healthy (`n8n_rollback_timeout` bounds the wait for the previous version); the
  failed version is then recorded in `update-failed` and not tried again, and after a rollback that
  failed too the marker blocks every version until the backup is restored by hand. A failed install
  stops the stack and leaves `install-incomplete`, which makes every later run refuse. A changed
  `n8n_db_password` is checked against the database and refused with the `ALTER USER` step when it
  does not take it (PostgreSQL takes the password only when it creates the database). Also refused
  before any change: a PostgreSQL image older than 18, a downgrade, a PostgreSQL major other than
  the database's and a compose file that is not YAML (the parser's error, which could quote a line
  with a secret, is not shown). The encryption key, the database password and the owner's password
  reach containers only through the `0600` compose file or stdin, so they are not in the output
  even at `-vvv`. See the role's guide in the docs.

## 0.5.0 — 2026-11-14

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
- `mailcow`: new role for mailcow: dockerized in `mailcow_dir` (default `/opt/mailcow-dockerized`,
  compose project `mailcow_project`, default `mailcowdockerized`). An existing clone with
  `mailcow.conf` is taken over in place (same directory, project, volumes and `mailcow.conf`,
  which the role never changes); without `mailcow.conf` the role clones `mailcow_git_repo`
  (branch `master`), writes `mailcow.conf` with mailcow's `generate_config.sh`
  (`mailcow_hostname`, `mailcow_timezone`, both required for an install only), sets
  `mailcow_install_settings` (such as `SKIP_CLAMD: "y"`) on top, starts mailcow and warns that
  the default admin password must be changed. Before anything changes it checks Docker 24+ with
  Compose v2, that the clone is on `master` (another branch, a tag or a detached HEAD is
  refused, never switched), that no merge conflict is left from an earlier update, that
  `COMPOSE_PROJECT_NAME` is `mailcow_project`, that `mailcow_backup_dir` (required; it may be a
  symbolic link to the backup disk) and `mailcow_dir` are not nested (compared with symbolic links
  resolved), and that the backups are on another file system (device) than `/`, `mailcow_dir` and
  Docker's root directory (`mailcow_backup_require_mount`, default true).
- `mailcow`: latest stable release, no pin: every run (`mailcow_update`, default true) runs
  `update.sh --check` (0: due, 3: none; any other exit, such as GitHub out of reach, updates
  nothing and fails the run after the health and backup checks, together with their errors). When
  a release is due: a full backup first (no backup, no update), then `update.sh --force` (at most
  two hours; an `update.sh` that runs longer is stopped and fails the run naming the backup); an
  `update.sh` that updated itself or its `_modules` and
  asks to be started again is started once more (for the check and for the update). Files
  `update.sh` left unmerged fail the run naming them, with the tree left as `update.sh` left it;
  local changes its merge (`-Xtheirs`) replaced with the release's version are reported by name
  (found with `git merge-tree`, kept in the "Before update" commit). After every run a health check (`mailcow_health_timeout`, default 300 seconds):
  every compose service running and healthy, the UI over HTTPS (200 for `MAILCOW_HOSTNAME`), the
  SMTP banner, IMAP over TLS and `/rc/` when Roundcube is integrated (`data/web/rc/index.php` or
  `data/web/rc/public_html/index.php`). A failure names the step and, after an update, the backup
  to restore from; the role never rolls back. The marker `/var/lib/noix-mailcow/update-failed`
  (`backup`, `time`, `failed_step`) is written before `update.sh --force` runs (a marker that
  cannot be written, such as on a full disk, fails the run before the update), rewritten with the
  failed step when the update fails (update.sh failing or running out of time, a file left
  unmerged, or mailcow unhealthy afterwards) and removed once the health check after the update
  passed, so a run that stops during the update (a lost connection, a stopped worker) leaves it
  too. While it exists every run fails at once without changes, naming it, and `mailcow-backup`
  never prunes the backup it names; remove it after fixing mailcow.
  Facts: `mailcow_updated`, `mailcow_last_backup`, and `mailcow_update_backup` (the folder of
  the backup before the update, taken at most once per run by `tasks/update_backup.yml`).
- `mailcow`: backups with `/usr/local/sbin/mailcow-backup [--reason daily|update]` (mailcow's
  `backup_and_restore.sh backup all` into `mailcow_backup_dir`), daily from
  `mailcow-backup.timer` at `mailcow_backup_time` (default `06:25`) and before every update. One
  at a time (`flock` on `/run/lock/mailcow-backup.lock`; a second one waits); a daily backup is
  skipped when one succeeded less than `mailcow_backup_skip_hours` (default 12, at least 1) ago.
  Backup folders (`mailcow-YYYY-MM-DD-HH-MM-SS` only) older than `mailcow_backup_keep_days`
  (default 3) are removed, never the last successful backup, the newest complete folder or the
  failed update's backup; with a backup on record before the backup (so the space check counts
  the room), otherwise only after this backup succeeded. The free space must be at least 1.2
  times the newest backup. A backup counts only with
  exit 0, every archive present and not empty and both mariabackup steps completed; it gets
  `extra-files.tar.gz` (Roundcube's `data/web/rc`, own nginx `*.custom`/`*.conf`, Dovecot's
  `extra.conf`, `docker-compose.override.yml`, `mailcow.conf`, `vars.local.inc.php`) and is
  recorded in `/var/lib/noix-mailcow/last-backup`; a failed or stopped one's folder is removed and
  the error goes to stderr (the journal). `tar` reporting files changed while it read them is a
  warning, not a failure. The script's own files (`extra-files.tar.gz`, `last-backup`,
  `backup.log`) are mode `0600`. A run without an update fails when the last successful backup is
  older than `mailcow_backup_max_age_hours` (default 26); with none recorded it makes the first.
  The backup cron script from mailcow's documentation (`/etc/cron.daily/mailcow-backup`) is
  removed; one with other content, and other cron jobs running `backup_and_restore.sh`, are
  reported and kept.
- `mailcow`: `/admin` and `/rspamd/` only from `mailcow_admin_allow` (CIDRs, IPv4 and IPv6;
  default `[]` switches the restriction off), 403 for everyone else; the match ignores case and
  takes any first path segment that starts with `admin` or `rspamd` followed by something other
  than a letter, digit, `-` or `_` (`/Admin/`, `/admin;x`); the decision uses the address that
  connected to nginx (`$realip_remote_addr`), so a forged `X-Forwarded-For` does not count.
  `mailcow_admin_allow` with `0.0.0.0/0`, `::/0` or an entry that overlaps mailcow's own network
  (`IPV4_NETWORK`/`IPV6_NETWORK` of `mailcow.conf`, default `172.22.1.0/24` and
  `fd4d:6169:6c63:6f77::/64`), where proxied clients come from, is refused before anything
  changes, and so is an entry that does not parse as a network (such as leading zeros,
  `000.0.0.0/0`, which nginx would read as every address).
  Everything else (`/domainadmin`, `/`, `/SOGo`, the API, DAV, ActiveSync, Autodiscover, ACME)
  stays open. Clients that Docker's userland proxy carries (IPv6 with `ENABLE_IPV6=false`, the
  loopback) appear as mailcow's bridge and are refused. noix error pages
  (`mailcow_error_pages_enabled`, default true; `mailcow_error_pages_image`, `_theme`, `_env`,
  `_codes`, default `[502, 504, 413, 414, 403]`) for the errors nginx generates itself, exported
  with `error_pages_export` to `data/conf/nginx/noix-error-pages` (listed in `.git/info/exclude`).
  The role's files are `data/conf/nginx/noix.conf` and `site.noix.custom` (git-ignored by
  mailcow, kept by `update.sh`), written before the update; `nginx -t` runs in `nginx-mailcow`
  before it is restarted (only when a file changed), and a configuration nginx rejects is put
  back from copies kept outside the clone (`/var/lib/noix-mailcow/nginx-previous`). A restart
  that is due is flagged (`/var/lib/noix-mailcow/nginx-restart-pending`) before the files change,
  so the next run makes it when a run stopped before restarting `nginx-mailcow`.
- `mailcow`: Anubis in front of mailcow's web UI with `mailcow_anubis_url` (default `""`, off;
  such as `http://noixdev-anubis:8923`, http with a host and an optional port, no path), with
  the `anubis` role in nginx mode run first. Before anything changes the role refuses a missing
  `mailcow_anubis_network` (default `noixdev-anubis`, the `anubis` role's `anubis_nginx_network`),
  401 in `mailcow_error_pages_codes`, and a `docker-compose.override.yml` it did not write. It
  writes `docker-compose.override.yml` (marker line; git-ignored by mailcow, in its backups) that
  puts only `nginx-mailcow` on that network, so `update.sh` and `docker compose down`/`up` keep it
  there and mailcow's own network never carries a foreign container (which would stop
  `docker compose up` whenever mailcow's network must be recreated, such as when `update.sh`
  switches `ENABLE_IPV6`); `nginx-mailcow` is recreated when the file changes. It then checks
  from inside `nginx-mailcow` that Anubis answers, and fails naming it otherwise, before it
  changes mailcow's nginx. `site.noix.custom` checks every request of mailcow's server blocks
  (`auth_request` to Anubis's check with `X-Original-Uri` and `X-Forwarded-Uri` from
  `$request_uri` and `X-Real-IP` from `$realip_remote_addr`, the address that connected, as for
  the admin restriction, whatever the client sent; the name resolves per request through
  Docker's DNS, so `nginx -t` and nginx's start do not need Anubis). A browser without Anubis's
  cookie gets Anubis's challenge page (401) at the URL it asked for (Anubis renders it for the
  request as a GET), so once solved it goes back there with the whole query;
  `/.within.website/` goes to Anubis unchecked and unrestricted. IP rules (such as the admins'
  networks) therefore never match an address claimed with `X-Forwarded-For`; not for a mailcow
  behind a reverse proxy. `/SOGo` and
  `/Microsoft-Server-ActiveSync`, which have an `auth_request` of their own, are checked in
  mailcow's own SOGo auth check on its internal listener `127.0.0.1:65510` with the original URI
  and address mailcow passes there (its `$remote_addr`, so a request whose address nginx took
  from `X-Forwarded-For` gets 403 on those two paths); a challenge goes back from there marked, so a wrong SOGo or
  ActiveSync password stays a plain 401 (a warning when a mailcow release no longer uses that
  listener). The 403 of the admin restriction and mailcow's own redirects come first; the noix
  error pages are never checked. While Anubis is down every checked request answers 500 (fails
  closed), also the paths the policy ALLOWs; the health check then names Anubis. The role's
  defaults show the `anubis_policy_allow` rules for mailcow's mail clients (ActiveSync, DAV,
  Autodiscover and Thunderbird's autoconfig, ignoring case where mailcow does, the API, ACME,
  MTA-STS). Removing `mailcow_anubis_url` removes the Anubis lines and the role's override: the
  nginx files without Anubis are tested and `nginx-mailcow` restarted first, then the override
  goes and `nginx-mailcow` is recreated off Anubis's network, so no request answers 500 meanwhile.
  `nginx-mailcow` is recreated whenever its networks differ from what the override says (read
  from the container), so a recreate that failed or a run that stopped is made up by the next
  run. `mailcow_anubis_url` is refused with `NGINX_USE_PROXY_PROTOCOL` or `TRUSTED_PROXIES` set in
  `mailcow.conf` (before the install: in `mailcow_install_settings`, which an installed mailcow
  no longer reads): behind a reverse proxy every client would share
  the proxy's address and `/SOGo` and ActiveSync would answer 403; a proxy that `mailcow.conf`
  does not name cannot be detected. The challenge page and nginx's own 401s carry mailcow's
  security headers (HSTS, `X-Frame-Options`, `nosniff`, `Referrer-Policy` and the rest), repeated
  in the role's 401 location. The check that `nginx-mailcow` reaches Anubis takes any answer of
  Anubis's policy (also 401 or 403) as reachable.
- `mailcow`: keeps an integrated Roundcube (`data/web/rc`, as mailcow's guide installs it) on the
  newest release of its series (`mailcow_roundcube_update`, default true; nothing happens without
  `data/web/rc/index.php` or `data/web/rc/public_html/index.php`). After mailcow's update and its
  health check, and with the same backup
  (one per run), the release's `-complete.tar.gz` is downloaded, must match the SHA-256 digest
  GitHub publishes for that release asset (a mismatch or a missing digest fails before anything is
  installed), and `bin/installto.sh` and `composer update --no-dev -o` run in `php-fpm-mailcow`
  (rsync is added to the running container first, Alpine's PHP image has none), which is restarted;
  then the health check, with `/rc/`, runs again. A newer series (1.8 for 1.7) is only reported.
  A release whose `composer.json` asks for a newer PHP than `php-fpm-mailcow` runs is skipped with
  a warning naming both versions (no backup, no change; a constraint the role cannot read is
  reported and does not block). The marker of a failed update is written before the install and
  removed once the health check with `/rc/` passed; a failed install step or a `/rc/` that does
  not answer fails the run naming the step and the backup. A failure before the install (the
  release list, GitHub's rate limit, the download or its checksum) changes nothing and fails the
  run after the backup checks. Roundcube's config and nginx snippet are never changed.
  `mailcow_roundcube_api_url` (GitHub's API) is for tests and mirrors; it and the download URLs
  must be https unless `mailcow_roundcube_allow_insecure_mirror` (test-only, default false) is
  true. Fact: `mailcow_roundcube_updated`.
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
- Tests: the Docker test suites run locally only, with `tests/all.sh` (all suites or the named
  ones, a summary with each suite's result and runtime). CI runs `ansible-lint` and `shellcheck`.
- Tests: a release needs a signed attestation of the local run: `tests/attest.sh` runs the suites
  that need it and publishes the SSH-signed result as a git note (`refs/notes/tests`) and the commit
  status `tests/local`; the tag workflow `release-gate.yml` verifies it
  (`.github/scripts/verify-tests-attestation.sh`) and flags a tag without a green one.
  `tests/attest.sh` refuses to start while a variable that narrows the suites is set (such as
  `HOST_UBUNTU` or `STUB_ONLY`), or when Docker cannot run `linux/amd64` images (the harbor
  suite needs them; on Apple silicon Docker Desktop needs Rosetta 2). `tests/all.sh --summary
  FILE` writes a machine-readable summary.
- Tests: the signed run is incremental. `tests/attest.sh` runs an entry (a suite, `host` and
  `services` once per Ubuntu release) only when its files changed, its last run was red or is
  older than 28 days, or a shared or unmapped file changed, and carries it from the newest valid
  signed run otherwise; `--plan` shows the decision and runs and signs nothing (it still
  replaces the local notes with origin's, dropping notes that exist only locally), `--all`
  runs everything, and a commit that changes only ignored files (such as `CHANGELOG.md`) needs no Docker. The map
  is `tests/suites.conf` (`[ignore]`, `[shared]`, `[suite <name>]`), checked by
  `attest_carry.py check-map` in the selftest. The release check accepts schema 1 and 2 notes,
  proves every carried entry against its source note, and refuses an entry older than 30 days at
  check time. `services` is part of the signed run as `services-24.04` and `services-26.04`
  (on Apple silicon with the note "mysql via systemctl shim"), and `tests/all.sh` accepts entry
  labels. New knobs that `tests/attest.sh` refuses: `SERVICES_UBUNTU`, `NOIXDEV_INFRA_SERVICES`
  and the n8n, paperless, tandoor and mailcow volume ones. Suites source `tests/lib/suite.sh`
  (`noix_exit_guard`, `noix_done`) so that macOS bash 3.2 cannot report a `set -u` error as green.

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
