#!/usr/bin/env bash
# Host roles (base, docker, fail2ban, crowdsec, tailscale, oh_my_zsh, motd) on a systemd Ubuntu container:
# converge twice (the second run must change nothing), then verify.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
ubuntu="${UBUNTU:-26.04}"
host="${NOIXDEV_INFRA_TEST_HOST:-noixdev-infra-host-$ubuntu}"
out="$tests/output/host-$ubuntu"

# Loop devices stand in for block volumes (base_mounts). They belong to the
# Docker VM's kernel, not to the container, so they are detached here even
# when the run fails; a mounted one is freed when the container goes away.
loops=()
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return
  for dev in ${loops[@]+"${loops[@]}"}; do docker exec "$host" losetup -d "$dev" >/dev/null 2>&1 || true; done
  docker rm -f "$host" >/dev/null 2>&1 || true
}
# shellcheck source=/dev/null
. "$here/../lib/suite.sh"
noix_exit_guard

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
noix_link_collection "$root" "$tests/output"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"

docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$here" >/dev/null
docker rm -f "$host" >/dev/null 2>&1 || true
docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock --name "$host" "noixdev-infra-host:$ubuntu" >/dev/null
until (docker exec "$host" systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done

# loop_dev NAME: attach a fresh 512 MiB sparse image file (mkfs.xfs needs
# more than 300 MB) and set $dev to its loop device.
loop_dev() {
  local img="/var/lib/mounts-test/$1.img"
  docker exec "$host" sh -c "mkdir -p /var/lib/mounts-test && rm -f $img && truncate -s 512M $img"
  dev="$(docker exec "$host" losetup --find --show "$img")" || {
    echo "no free loop device in the Docker VM for the base_mounts tests (losetup --find failed)" >&2
    exit 1
  }
  loops+=("$dev")
}
loop_dev ext4; dev_ext4="$dev"
loop_dev xfs; dev_xfs="$dev"
loop_dev spare; dev_spare="$dev"

play() {
  ansible-playbook -i "$tests/inventory.yml" -e "test_host=$host" \
    -e "test_mount_dev_ext4=$dev_ext4" -e "test_mount_dev_xfs=$dev_xfs" "$@"
}

# oh_my_zsh: a user whose home is not under /home and belongs to the user
# (useradd creates it), with files of its own: a ~/.zshrc.local that the role
# must source and never write, and a hand-written ~/.zshrc that the role must
# back up before it takes the file over.
docker exec "$host" useradd -m -d /srv/deploy -s /bin/bash deploy
docker exec -u deploy "$host" sh -c 'echo "export NOIX_LOCAL=1" >/srv/deploy/.zshrc.local
  printf "# hand-written\nexport NOIX_OWN=1\n" >/srv/deploy/.zshrc && chmod 0600 /srv/deploy/.zshrc'

# motd: stock and older managed snippets that the role must remove.
docker exec "$host" sh -c 'mkdir -p /etc/update-motd.d && for f in 05-old-banner 50-motd-news; do printf "#!/bin/sh\necho old-%s\n" "$f" >"/etc/update-motd.d/$f"; chmod 0755 "/etc/update-motd.d/$f"; done'

echo "== converge (ubuntu $ubuntu)"
play "$here/converge.yml"

echo "== idempotence"
play "$here/converge.yml" | tee "$out/idempotence.log"
grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/idempotence.log" \
  || { echo "second converge changed something" >&2; exit 1; }

echo "== verify"
play "$here/verify.yml"

# tailscale: a failed login ends within tailscale_login_timeout, reports what
# tailscale up said and removes the auth key file. Without network access the
# login times out instead; both are "tailscale up failed".
echo "== tailscale login fails within the timeout"
start=$SECONDS
if play "$here/tailscale_login.yml" >"$out/tailscale-login.log" 2>&1; then
  echo "tailscale accepted a bad auth key" >&2; exit 1
fi
[ $((SECONDS - start)) -lt 90 ] || { echo "tailscale login did not stop at its timeout" >&2; exit 1; }
grep -qF "tailscale up failed" "$out/tailscale-login.log" \
  || { cat "$out/tailscale-login.log" >&2; echo "tailscale login: expected the message: tailscale up failed" >&2; exit 1; }
! grep -qF "flag provided but not defined" "$out/tailscale-login.log" \
  || { echo "tailscale up does not know --timeout" >&2; exit 1; }
! docker exec "$host" test -e /run/tailscale-authkey \
  || { echo "tailscale login left the auth key file behind" >&2; exit 1; }

# oh_my_zsh: deploy owns its home and can put a link there as ~/.zshrc. Root
# must neither write through it nor read it: the target stays as it is and
# its content shows up nowhere, not even in --diff output.
echo "== oh_my_zsh does not follow a link as ~/.zshrc"
docker exec "$host" sh -c 'printf "keep-zshrc-target\n" >/opt/zshrc-target && chown root:root /opt/zshrc-target && chmod 0600 /opt/zshrc-target'
docker exec -u deploy "$host" ln -sfn /opt/zshrc-target /srv/deploy/.zshrc
play "$here/oh_my_zsh.yml" --diff >"$out/zshrc-link.log" 2>&1 \
  || { cat "$out/zshrc-link.log" >&2; echo "oh_my_zsh failed with a link as ~/.zshrc" >&2; exit 1; }
! grep -qF keep-zshrc-target "$out/zshrc-link.log" \
  || { echo "oh_my_zsh showed the content behind the link in its --diff output" >&2; exit 1; }
{ [ "$(docker exec "$host" stat -c '%U:%G %a' /opt/zshrc-target)" = "root:root 600" ] \
  && [ "$(docker exec "$host" cat /opt/zshrc-target)" = keep-zshrc-target ]; } \
  || { echo "oh_my_zsh changed the target of the link" >&2; exit 1; }
docker exec "$host" sh -c 'test -f /srv/deploy/.zshrc && test ! -L /srv/deploy/.zshrc \
  && head -n 1 /srv/deploy/.zshrc | grep -qF "Managed by noixdev.infra" \
  && [ "$(stat -c %U /srv/deploy/.zshrc)" = deploy ]' \
  || { echo "/srv/deploy/.zshrc is not the managed file of deploy" >&2; exit 1; }

# mounts_fail NAME MESSAGE BASE_MOUNTS_JSON: the run must fail with MESSAGE
# and leave fstab, the mounts and /srv as they were.
hx() { docker exec "$host" "$@"; }
mounts_state() { hx sh -c 'sha256sum /etc/fstab; findmnt -rn -o SOURCE,TARGET; ls -la /srv'; }
# MOUNTS_SURVEY=1 reports every case that does not hold instead of stopping
# at the first (for seeing a set of new cases fail before the fix).
mounts_failed=0
mounts_bad() {
  echo "base_mounts $1" >&2
  [ "${MOUNTS_SURVEY:-0}" = 1 ] || exit 1
  mounts_failed=1
}
mounts_fail() {
  local log="$out/mounts-$1.log" before after
  before="$(mounts_state)"
  if play "$here/mounts.yml" -e "{\"base_mounts\": $3}" >"$log" 2>&1; then
    mounts_bad "$1: the run did not fail"; return
  fi
  grep -qF -- "$2" "$log" || { mounts_bad "$1: expected the message: $2"; return; }
  after="$(mounts_state)"
  [ "$before" = "$after" ] || {
    diff <(echo "$before") <(echo "$after") >&2 || true
    mounts_bad "$1: the failed run changed the host"; return
  }
  echo "   $1: refused"
}

echo "== base_mounts in check mode changes nothing"
play "$here/mounts.yml" --check -e "{\"base_mounts\": [{\"src\": \"$dev_ext4\", \"path\": \"/srv/data-ext4\"}, {\"src\": \"$dev_xfs\", \"path\": \"/srv/data-xfs/\", \"fstype\": \"xfs\", \"opts\": \"defaults,nofail,noatime\"}]}" \
  >"$out/mounts-check.log" 2>&1 || { cat "$out/mounts-check.log" >&2; echo "base_mounts --check failed" >&2; exit 1; }
grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/mounts-check.log" \
  || { cat "$out/mounts-check.log" >&2; echo "base_mounts --check reported changes" >&2; exit 1; }

echo "== base_mounts refuses unsafe entries"
mounts_fail duplicate-path "base_mounts: path /srv/dup appears more than once" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/dup\"}, {\"src\": \"$dev_xfs\", \"path\": \"/srv/dup\"}]"
mounts_fail duplicate-src "base_mounts: src $dev_spare appears more than once" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/a\"}, {\"src\": \"$dev_spare\", \"path\": \"/srv/b\"}]"
mounts_fail src-not-dev "base_mounts: src loop0 is not a device path under /dev/" \
  '[{"src": "loop0", "path": "/srv/x"}]'
mounts_fail path-root "base_mounts: path / is not an absolute mountpoint other than /" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/\"}]"
mounts_fail path-relative "base_mounts: path srv/x is not an absolute mountpoint other than /" \
  "[{\"src\": \"$dev_spare\", \"path\": \"srv/x\"}]"
mounts_fail path-space "base_mounts: path /srv/my data must not contain whitespace or a backslash" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/my data\"}]"
mounts_fail missing-device "base_mounts: no block device /dev/disk/by-id/scsi-0HC_Volume_missing" \
  '[{"src": "/dev/disk/by-id/scsi-0HC_Volume_missing", "path": "/srv/x"}]'

hx mkfs.ext4 -q -F "$dev_spare"
mounts_fail wrong-filesystem "base_mounts: $dev_spare has ext4, expected xfs" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/x\", \"fstype\": \"xfs\"}]"

uuid="$(hx blkid -s UUID -o value "$dev_spare")"
hx sh -c "echo 'UUID=$uuid /mnt/HC_Volume_1 ext4 discard,nofail,defaults 0 0' >>/etc/fstab"
mounts_fail fstab-elsewhere "/etc/fstab mounts $dev_spare at /mnt/HC_Volume_1" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/x\"}]"
grep -qF "remove that line" "$out/mounts-fstab-elsewhere.log" || { echo "base_mounts fstab-elsewhere: no hint to remove the line" >&2; exit 1; }
hx sed -i '\|/mnt/HC_Volume_1|d' /etc/fstab

# Hetzner's own automount line names the volume by its /dev/disk/by-id/ link.
hx sh -c "ln -sfn $dev_spare /dev/mounts-test-link && echo '/dev/mounts-test-link /mnt/HC_Volume_1 ext4 discard,nofail,defaults 0 0' >>/etc/fstab"
mounts_fail fstab-by-link "/etc/fstab mounts $dev_spare at /mnt/HC_Volume_1" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/x\"}]"
hx sed -i '\|/mnt/HC_Volume_1|d' /etc/fstab

hx e2label "$dev_spare" testvol
hx sh -c "echo 'LABEL=testvol /mnt/HC_Volume_1 ext4 nofail 0 0' >>/etc/fstab"
mounts_fail fstab-by-label "/etc/fstab mounts $dev_spare at /mnt/HC_Volume_1" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/x\"}]"
hx sed -i '\|/mnt/HC_Volume_1|d' /etc/fstab

mounts_fail same-device "base_mounts: $dev_spare and /dev/mounts-test-link are the same device" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/a\"}, {\"src\": \"/dev/mounts-test-link\", \"path\": \"/srv/b\"}]"
hx rm -f /dev/mounts-test-link

# src is a symlink, as /dev/disk/by-id/ paths are; the kernel shows the target.
hx sh -c "mkdir -p /mnt/other && mount $dev_spare /mnt/other && ln -sfn $dev_spare /dev/mounts-test-link"
mounts_fail mounted-elsewhere "base_mounts: /dev/mounts-test-link is mounted at /mnt/other" \
  '[{"src": "/dev/mounts-test-link", "path": "/srv/x"}]'
hx sh -c "umount /mnt/other && rm -f /dev/mounts-test-link"

hx wipefs -q -a "$dev_spare" >/dev/null 2>&1
# An MBR with one partition entry (the image has no sfdisk); blkid reports
# PTTYPE=dos and no filesystem.
hx bash -c "printf '\\x00\\x20\\x21\\x00\\x83\\x8a\\x08\\x41\\x00\\x08\\x00\\x00\\x00\\x00\\x10\\x00' | dd of=$dev_spare bs=1 seek=446 conv=notrunc status=none
  printf '\\x55\\xaa' | dd of=$dev_spare bs=1 seek=510 conv=notrunc status=none"
hx sh -c "blkid -p -o export $dev_spare | grep -qx PTTYPE=dos" || { echo "could not write the test partition table" >&2; exit 1; }
mounts_fail partition-table "base_mounts: $dev_spare has a partition table (dos)" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/x\"}]"
hx wipefs -q -a "$dev_spare" >/dev/null 2>&1

mounts_fail path-mounted "base_mounts: /srv/data-ext4 is already the mountpoint of $dev_ext4" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/data-ext4\"}]"

hx sh -c "mkdir -p /srv/full && touch /srv/full/keep"
mounts_fail path-not-empty "base_mounts: /srv/full is not empty" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/full\"}]"

hx ln -sfn /srv/full /srv/link
mounts_fail path-symlink "base_mounts: path /srv/link resolves to /srv/full" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/link\"}]"
hx rm -f /srv/link

hx touch /srv/file
mounts_fail path-file "base_mounts: /srv/file exists and is not a directory" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/file\"}]"
hx rm -f /srv/file

# No signature, but data: blkid sees nothing, the zero check must.
hx sh -c "head -c 4096 /dev/urandom | dd of=$dev_spare bs=4096 seek=10 conv=notrunc status=none"
mounts_fail raw-data "base_mounts: $dev_spare has no filesystem but is not blank" \
  "[{\"src\": \"$dev_spare\", \"path\": \"/srv/x\"}]"
hx sh -c "dd if=/dev/zero of=$dev_spare bs=4096 seek=10 count=1 conv=notrunc status=none"

[ "$mounts_failed" = 0 ] || exit 1
noix_done
echo "== host roles passed on ubuntu $ubuntu"
