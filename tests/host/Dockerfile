# A throwaway Ubuntu host with systemd, for the host roles.
ARG UBUNTU=26.04
FROM ubuntu:${UBUNTU}
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus openssh-server python3 iproute2 \
 && rm -rf /var/lib/apt/lists/*
# binfmt_misc is global to the Docker host's kernel, and this container is
# privileged: systemd-binfmt would flush every handler at boot (Docker
# Desktop's Rosetta and QEMU amd64 emulation, which the harbor suite needs)
# and register Ubuntu's own. Keep systemd away from it.
RUN systemctl mask systemd-binfmt.service proc-sys-fs-binfmt_misc.automount proc-sys-fs-binfmt_misc.mount
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
