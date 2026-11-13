#!/usr/bin/env bash
# Test stub of mailcow's backup_and_restore.sh: "backup all" writes a
# mailcow-<date> folder in MAILCOW_BACKUP_LOCATION with every archive of the
# real one (1 KiB of random data each) and mailcow.conf, and prints what
# mariabackup prints when it succeeds. Records its calls in
# /var/log/mailcow-stub/backup.calls. Flags in /etc/mailcow-stub:
# backup-seconds (how long a backup takes, default 1), backup-hold (the
# backup waits while it exists, after backup-seconds), backup-fails (exit 1
# after half the archives).
set -euo pipefail
flags=/etc/mailcow-stub
mkdir -p /var/log/mailcow-stub
echo "$* (MAILCOW_BACKUP_LOCATION=${MAILCOW_BACKUP_LOCATION:-})" >>/var/log/mailcow-stub/backup.calls
[ "$*" = "backup all" ] || { echo "stub: only backup all"; exit 1; }
[ -n "${MAILCOW_BACKUP_LOCATION:-}" ] || { echo "stub: no MAILCOW_BACKUP_LOCATION"; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
folder="$MAILCOW_BACKUP_LOCATION/mailcow-$(date +%Y-%m-%d-%H-%M-%S)"
mkdir -p "$folder"
cp "$here/../mailcow.conf" "$folder/"
sleep "$(cat "$flags/backup-seconds" 2>/dev/null || echo 1)"
while [ -e "$flags/backup-hold" ]; do sleep 1; done
n=0
for component in vmail crypt redis rspamd postfix mariadb; do
  head -c 1024 /dev/urandom >"$folder/backup_$component.tar.zst"
  n=$((n + 1))
  if [ "$n" = 3 ] && [ -e "$flags/backup-fails" ]; then
    echo "stub: backup failed" >&2
    exit 1
  fi
done
echo "[00] 2026-01-01 00:00:00 completed OK!"
echo "[00] 2026-01-01 00:00:01 completed OK!"
