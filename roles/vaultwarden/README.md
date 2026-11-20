# vaultwarden

Runs Vaultwarden, a Bitwarden-compatible password server, in Docker Compose
behind the `traefik` role: the vault for the official Bitwarden apps, its admin
page, the database of your choice (a file, a PostgreSQL container of its own
or a PostgreSQL server of your own), mail and push notifications, a backup
before every update and a rollback when an update fails.

Docker comes from the playbook (the `docker` role); the role checks for it.
`vaultwarden_hostname` is required, and with PostgreSQL `vaultwarden_db_password`
(keep it in a vault). The full reference is in `meta/argument_specs.yml`, the
defaults in `defaults/main.yml`.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `vaultwarden_version` | `1.37.5` | Vaultwarden release, `X.Y.Z`, 1.37.0 or newer; no `latest`, no `-alpine` |
| `vaultwarden_image` | `docker.io/vaultwarden/server` | Image repository |
| `vaultwarden_dir` | `/opt/vaultwarden` | The compose project: compose file, secrets, markers |
| `vaultwarden_data_dir` | `<vaultwarden_dir>/data` | The data and the backups; no comma in the path |
| `vaultwarden_data_dir_mountpoint` | `false` | Refuse every run while the data directory is not a mountpoint |
| `vaultwarden_hostname` | required | The host name Traefik routes to the vault |
| `vaultwarden_url` | `https://<hostname>` | The origin the clients see |
| `vaultwarden_traefik_network` | `proxy` | Traefik's network |
| `vaultwarden_traefik_entrypoints` | `[]` | Entrypoints of the vault's router (empty: Traefik's default ones); while the admin page is on, it leaves `/admin` to the admin router |
| `vaultwarden_traefik_middlewares` | `[]` | Middlewares of the vault's router, which do not apply to `/admin` while the admin page is on |
| `vaultwarden_traefik_admin_entrypoints` | the vault's | Entrypoints of the router of `/admin`, the only ones `/admin` answers on |
| `vaultwarden_traefik_admin_middlewares` | `[]` | Middlewares of the router of `/admin`, the only ones that apply there (an IP allowlist, for example) |
| `vaultwarden_traefik_priority` | `100` | Priority of the routers (the admin router one above) |
| `vaultwarden_database` | `sqlite` | `sqlite`, `postgres` (a container of the project) or `postgres_external` (a server of your own) |
| `vaultwarden_postgres_image` | `docker.io/library/postgres:18` | PostgreSQL image of the own database (18 or newer); for an external server the role runs the client of the server's major from the same repository |
| `vaultwarden_db_password` | required with PostgreSQL | Password of the PostgreSQL user |
| `vaultwarden_db_host` | required with `postgres_external` | Host name or address of the external server |
| `vaultwarden_db_port` | `5432` | Its port |
| `vaultwarden_db_name` | `vaultwarden` | The database |
| `vaultwarden_db_user` | `vaultwarden` | The user, which must own the database |
| `vaultwarden_db_sslmode` | `prefer` | TLS to the external server: `disable`, `prefer` or `require` |
| `vaultwarden_admin_token_hash` | `""` | Argon2id hash of the admin token; empty switches the admin page off |
| `vaultwarden_signups_allowed` | `false` | Open registration; while it is off, users join by invitation |
| `vaultwarden_invitation_org_name` | `Vaultwarden` | The name in invitation mails |
| `vaultwarden_smtp` | no mail | `host`, `port` (587), `security` (`starttls`, `force_tls` or `off`), `username`, `password`, `from`, `from_name` |
| `vaultwarden_push_installation_id` | `""` | Push notifications through Bitwarden's relay (from bitwarden.com/host), with the key |
| `vaultwarden_push_installation_key` | `""` | Its key: both or neither |
| `vaultwarden_push_region` | `us` | The relay's region, `us` or `eu` |
| `vaultwarden_env` | `{}` | More settings of Vaultwarden; the ones the role sets itself are refused |
| `vaultwarden_backups_keep` | `3` | Backups before updates that are kept |
| `vaultwarden_health_timeout` | `300` | Seconds to wait until Vaultwarden is healthy |
| `vaultwarden_rollback_timeout` | the health timeout | Seconds a rollback waits for the previous version |
| `vaultwarden_restore_interrupted` | `false` | For one run: restore the backup of an update that did not finish |

## Database modes

The mode is fixed at install and recorded in `<vaultwarden_dir>/database-target`
(for an external server also its host, port and database): a run with another
mode or another external database is refused, as Vaultwarden would start an
empty vault there. An external server must be PostgreSQL 15 or newer, the user
must own the database, and an install refuses a database that already holds
tables.

## Admin page

The admin page is on only with `vaultwarden_admin_token_hash`, an Argon2id hash
made with `docker run --rm -it vaultwarden/server:<version> /vaultwarden hash`;
a plain token is refused. While it is on, the vault's router leaves `/admin` to
a router of its own, so `/admin` answers only on
`vaultwarden_traefik_admin_entrypoints`, with
`vaultwarden_traefik_admin_middlewares`. A save of settings on the admin page
writes a `config.json` that would override the role's settings, so every run
refuses while it exists and names the keys it holds; managing users there does
not write it.

## Secrets

The admin token's hash, the database URL, the database password (own
PostgreSQL), the SMTP password and the push key live in files of mode 0600 in
`<vaultwarden_dir>/secrets`, never in the compose file or the run's output. A
changed setting restarts Vaultwarden, also a changed secret alone, which leaves
the compose file as it is; a run stopped before that restart leaves
`restart-pending`, and the next run restarts it.

## Updates, backups and rollbacks

A newer `vaultwarden_version` is an update; an older one is refused, as
Vaultwarden cannot migrate its database down. Before the new version starts,
the role stops Vaultwarden and takes a backup in
`<vaultwarden_data_dir>/backups/<time>-<from>-to-<to>/`: the compose file, the
secrets, the data (without the icon cache) and with PostgreSQL a dump of the
database. Then the new version starts and must be healthy within
`vaultwarden_health_timeout`, including a read of its database. The newest
`vaultwarden_backups_keep` backups are kept.

A failed update is rolled back to the backup (with PostgreSQL the database is
emptied and loaded from the dump) and the run fails. `update-failed` in
`vaultwarden_dir` then keeps the role from trying that version again: remove
it to retry, or pin another version. The data of the failed attempt stays in
`<backup>-failed`. When the rollback fails too, `update-failed` refuses every
version, and the message says how to put the backup back by hand.

A run that stopped during an update (a lost connection, a reboot) leaves
`update-in-progress`:

- Stopped during the backup, nothing had changed yet: the next run removes the
  partial backup and updates.
- Stopped after the backup: every run refuses, naming both versions and the
  backup. Set `vaultwarden_restore_interrupted: true` for one run to restore
  the backup and run the previous version again, or remove
  `update-in-progress` to keep Vaultwarden as it is. The variable is refused
  when there is no such update; remove it after the run.

A failed install leaves `install-incomplete`, and every later run refuses until
the partial installation is removed as the message says.
