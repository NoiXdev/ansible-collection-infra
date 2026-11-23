# postal

Runs Postal, a mail delivery platform, in Docker Compose behind the `traefik`
role: the web interface and the sending API, SMTP with STARTTLS, open and
click tracking, spam and virus checks, the database of your choice (a MariaDB
container of its own or a MariaDB server of your own), a backup before every
update and a rollback when an update fails.

The role installs Postal with a MariaDB container of its own
or on a MariaDB server of your own, creates the first admin
(`postal_admin_email`, `postal_admin_password`), prints the DNS records to
set, applies changed settings, routes the API, the web interface and the
tracking domains through Traefik, gives the SMTP services a certificate for
STARTTLS, runs the spam and virus checks, checks on every run that Postal
answers (with STARTTLS offered and its main and a message database read), and updates Postal with a backup first and a rollback when the new
version fails. A MariaDB server of your own must be MariaDB 10.6 or
newer, reachable from the host and from Traefik's network, with a user that
has all privileges on `postal_db_name` and on the message databases
(`<postal_message_db_prefix>-%`); every run checks that before it changes
anything. An install on a database that already holds Postal's data, or with
`postal_import_dump` (loaded into the MariaDB container), takes that
installation over: it needs the old installation's `postal_signing_key` and
`postal_rails_secret_key`, refuses without them before any change, keeps the
data and its users and upgrades the schema. With
`postal_smtp_tls: traefik` the certificate is the one Traefik obtained for
`postal_smtp_hostname`: the role installs `/usr/local/sbin/postal-smtp-cert`
and a systemd timer that copies it twice a day and restarts the SMTP services
when it changed, and the first run waits for it. With `files` it copies
`postal_smtp_tls_cert` and `postal_smtp_tls_key` on every run. A customer
tracking domain added in Postal gets its router and its certificate on the
next run of the role, once Postal has verified its CNAME; its certificate
comes from HTTP-01 (the `traefik` role's `traefik_acme_http_resolver` with the
DNS-01 challenge). A password of the database user must not hold a double
quote or a backslash, which Postal cannot read. Docker comes from the playbook
(the `docker` role); the role checks for it. The host must be x86_64, as
Postal's image exists for that architecture only. `postal_web_hostname`,
`postal_dns_domain` and `postal_db_password` (keep it in a vault) are
required. The full reference is in `meta/argument_specs.yml`, the defaults in
`defaults/main.yml`.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `postal_version` | `3.5.0` | Postal release, `X.Y.Z`, 3.0.0 or newer; no `latest` |
| `postal_image` | `ghcr.io/postalserver/postal` | Image repository |
| `postal_dir` | `/opt/postal` | The compose project: compose file, configuration, markers |
| `postal_data_dir` | `<postal_dir>/data` | The data and the backups; no comma in the path |
| `postal_data_dir_mountpoint` | `false` | Refuse every run while the data directory is not a mountpoint |
| `postal_web_hostname` | required | The host name Traefik routes to the web interface and API |
| `postal_smtp_hostname` | the web host name | The host name of the SMTP services and their certificate |
| `postal_dns_domain` | required | The domain Postal's DNS names are derived from |
| `postal_dns` | `{}` | Overrides of the derived DNS names and DKIM settings |
| `postal_traefik_network` | `proxy` | Traefik's network |
| `postal_traefik_entrypoints` | `[]` | Entrypoints of the API and tracking routers |
| `postal_traefik_ui_entrypoints` | the API's | Entrypoints of the web interface router |
| `postal_traefik_track_cert_resolver` | `http` | Certificate resolver of the customer tracking domains |
| `postal_track_hostnames` | `[]` | More tracking host names, with the entrypoint's certificates |
| `postal_database` | `mariadb` | `mariadb` (a container of the project) or `mariadb_external` (MariaDB 10.6 or newer of your own) |
| `postal_db_password` | required | Password of the database user |
| `postal_db_host` | required with `mariadb_external` | Host name or address of the external server |
| `postal_signing_key`, `postal_rails_secret_key` | `""` | Keys of the installation; empty generates them on a fresh install; a takeover needs both |
| `postal_smtp_port` | `25` | Port of the receiving SMTP service |
| `postal_smtp_submission_port` | `587` | Port of the submission service; `0` switches it off |
| `postal_smtp_tls` | `traefik` | `traefik`, `files` or `off` |
| `postal_traefik_acme_file` | `/opt/traefik/acme/acme.json` | Traefik's certificate storage, with `traefik` |
| `postal_smtp_tls_cert`, `postal_smtp_tls_key` | `""` | Certificate (with its chain) and key on the host, with `files` |
| `postal_spam` | `none` | `none` or `rspamd` |
| `postal_clamav` | `false` | Virus checks with ClamAV |
| `postal_admin_email`, `postal_admin_password` | `""` | The first admin, created once on an install |
| `postal_import_dump` | `""` | A dump of an earlier installation's databases (`.sql` or `.sql.gz`), loaded once on an install into the own MariaDB |
| `postal_backups_keep` | `3` | Backups before updates that are kept |
| `postal_health_timeout` | `300` | Seconds to wait until Postal is healthy |
| `postal_rollback_timeout` | the health timeout | Seconds a rollback waits for the previous version |
| `postal_restore_interrupted` | `false` | For one run: restore the backup of an update that did not finish |
| `postal_config_extra` | `{}` | More of Postal's configuration; the keys the role owns are refused |

Further variables (mail, single sign-on, log shipping, IP pools, relays,
worker and health ports, the pins of rspamd and ClamAV) are documented in
`meta/argument_specs.yml`.

## Updates, backups and rollbacks

A newer `postal_version` is an update; an older one is refused, as Postal
cannot migrate its databases down. The run first checks that the backup
directory has room for the databases (their size plus a fifth) and pulls the
new image; a refusal or a failed pull changes nothing. Then it stops the
Postal services (the worker first, the web interface last; the own MariaDB
keeps running) and takes a backup in
`<postal_data_dir>/backups/<time>-<from>-to-<to>/`: the compose file, the
configuration with the keys, and `databases/`, one complete dump of every
Postal database. It writes the new version, runs `postal upgrade`, starts
Postal and checks it within `postal_health_timeout`, the database included.
The newest `postal_backups_keep` backups are kept.

A failed update is rolled back to the backup: the configuration goes back,
the message databases are dropped, the main database is emptied, every dump
is loaded, and the previous version must be healthy within
`postal_rollback_timeout`. The run fails either way. `update-failed` in
`postal_dir` then keeps the role from trying that version again: remove it to
retry, or pin another version. When the rollback fails too, `update-failed`
refuses every version, and the message says how to put the backup back by
hand. A failure before the backup was complete starts Postal as it was and
removes the partial backup.

A run that stopped during an update (a lost connection, a reboot) leaves
`update-in-progress`:

- Stopped during the backup, nothing had changed yet: the next run removes the
  partial backup and updates.
- Stopped after the backup: every run refuses, naming both versions and the
  backup. Set `postal_restore_interrupted: true` for one run to restore the
  backup and run the previous version again, or remove `update-in-progress`
  to keep Postal as it is. The variable is refused when there is no such
  update; remove it after the run.

A failed install leaves `install-incomplete`, and every later run refuses until
the partial installation is removed as the message says.

## Backups with backrest

The role installs `/usr/local/sbin/postal-dump` (root's, mode 0700), the dump
an update takes, for a scheduled backup with the `backrest` role. Without an
argument it writes `<postal_data_dir>/backups/latest`, with one the directory
it names: a `.sql` file per database, `postal.yml` and `signing.key`. It
writes into `<dir>.tmp` and replaces the directory only once everything is
complete, so a failed or killed run never leaves half a backup there; it
exits non-zero on any error. An existing directory it did not write (it
marks its own with `.postal-dump`) is refused with exit code 2 and left as
it is. With an external MariaDB it logs in with
`<postal_dir>/dump.cnf` (mode 0600), never on a command line.

```yaml
backrest_apps:
  - name: postal
    requires_path: /opt/postal/compose.yaml
    dump:
      type: command
      command: /usr/local/sbin/postal-dump
      output: /opt/postal/data/backups/latest
```

The backup holds every secret of the installation; keep the repository
encrypted. To restore, follow the steps the message of a failed rollback
gives, with the backup's `databases/` and its `postal.yml` and
`signing.key` in `<postal_dir>/config`.

## Secrets

The database password, the keys, rspamd's password and the OIDC client's
secret live in `<postal_dir>/config`, in files only root and the container
that reads them can read (mode 0440), never in the compose file, a
container's environment, a process list or the run's output. The first
admin's password reaches Postal once, on the install, through stdin; the role
does not store it. With an external MariaDB, `postal-dump` logs in with
`<postal_dir>/dump.cnf` (mode 0600). Keep `postal_signing_key` and
`postal_rails_secret_key` of an installation in a vault: a new installation
or a takeover needs them, and a new signing key breaks the published DKIM
record. On an installation, a given key that differs from the installed one
is refused before any change; to rotate a key on purpose, write the new one
into `<postal_dir>/config` yourself (and publish its DKIM record), then run
the role with it.

## Notes

- Write `postal_smtp_tls: "off"` quoted; unquoted YAML makes it a boolean,
  which the role refuses.
- With `traefik`, a renewal is picked up by the timer, within about 13 hours.
  With `files`, it reaches Postal on the next run of the role: run the role
  on a schedule, or from your ACME client's deploy hook.
- `postal_smtp_relays` need host names: Postal finds no endpoint for an IP
  address.
- A wrong `postal_traefik_track_cert_resolver` is not refused by the role;
  Traefik then serves the tracking domain without a valid certificate.
- Set `postal_rspamd_password`: without it, rspamd's controller trusts every
  client that reaches it.
- GELF to `127.0.0.1` reaches the services on the host's network (SMTP,
  submission, worker), not the web interface.
- ClamAV downloads about 113 MB of signatures on its first start; on a slow
  link raise `postal_health_timeout`.
- With more than one worker, only the first has a health check; the others
  count as healthy while they run.
- A takeover does not detect a database migrated by a newer Postal than
  `postal_version`; pin at least the version the old installation ran.
