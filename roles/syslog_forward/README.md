# syslog_forward

Forwards the host's logs to one or more syslog receivers. rsyslog takes
what the journal hands it, and one drop-in,
`/etc/rsyslog.d/60-noixdev-forward.conf`, sends it to every target in RFC
5424 format. The role knows nothing about the receiver. Use it with the
`graylog` role's syslog inputs or with any other syslog server.

The role installs `rsyslog` when it is missing, plus `rsyslog-gnutls` and
`ca-certificates` when a target uses TLS. Before rsyslog restarts, it checks
the whole configuration with `rsyslogd -N1`. If the check refuses the new
drop-in, the role puts the previous one back (or removes it when there was
none), and the run fails with rsyslog's error. An empty
`syslog_forward_targets` (the default) removes the drop-in.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `syslog_forward_targets` | `[]` | The receivers, see below |
| `syslog_forward_filter` | `*.*` | The rsyslog selector of what is forwarded, for example `auth,authpriv.*` |

Each target:

| Key | Default | Purpose |
|---|---|---|
| `host` | required | The receiver's host name or address |
| `port` | `514` | Its port |
| `protocol` | `tcp` | `udp` or `tcp` |
| `tls` | `false` | TLS, TCP only |
| `ca_file` | `""` | With TLS, the CA file on the host that signs the receiver's certificate; empty for the system's CA bundle. It must exist, readable by the `syslog` user |
| `queue_size` | `10000` | TCP only, the messages the queue holds in memory |
| `queue_max_disk` | `512m` | TCP only, the space the queue may take on disk beyond that (`k`, `m` or `g`) |

```yaml
syslog_forward_targets:
  - host: logs.example.test
    port: 6514
    tls: true
  - host: 10.0.0.5
    port: 1514
    protocol: udp
```

## Delivery

UDP sends and forgets, so messages are lost while the receiver is down or
the network drops them. TCP keeps a queue per target, in memory and on disk
under `/var/spool/rsyslog`. While the receiver is down, the queue holds up to
`queue_size` messages in memory and up to `queue_max_disk` on disk, sends
them once the receiver is back and keeps them across a restart of rsyslog.
Local logging never waits for the receiver: once the queue is full, new
messages for that target are dropped. Leave room for `queue_max_disk` per
TCP target on the filesystem of `/var/spool/rsyslog`.

With TLS the receiver's certificate must carry `host` as its name, which
rsyslog also sends as the server name (SNI). A receiver behind a TLS proxy
that routes by server name, as the `graylog` role's TCP routes through
Traefik do, therefore needs a target given by name, not by address.
Through such a proxy the queue only covers an outage of the proxy: what the
proxy accepted while the receiver behind it was down can be lost.
