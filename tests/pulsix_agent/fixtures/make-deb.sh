#!/bin/sh
# make-deb.sh NAME VERSION LIST: build /tmp/NAME_VERSION_all.deb, run inside the
# test container. LIST names a file with one path per line: a path ending in
# "/" is a directory, a unit file (.service, .socket, .timer) gets a working
# unit, anything else a small file. Files below /etc are conffiles, so that
# removing the package leaves them behind (dpkg state rc). The postinst
# enables every unit of the package that can run on its own.
set -eu

name="$1" version="$2" list="$3"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/DEBIAN"
: >"$work/DEBIAN/conffiles"
printf '#!/bin/sh\nset -e\nsystemctl daemon-reload || true\n' >"$work/DEBIAN/postinst"

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    */)
      mkdir -p "$work$path"
      continue
      ;;
  esac
  mkdir -p "$work$(dirname "$path")"
  case "$path" in
    *.service)
      printf '[Unit]\nDescription=fixture %s\n[Service]\nExecStart=/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n' "$name" >"$work$path"
      ;;
    *.socket)
      printf '[Unit]\nDescription=fixture %s\n[Socket]\nListenStream=127.0.0.1:16556\nAccept=yes\n[Install]\nWantedBy=sockets.target\n' "$name" >"$work$path"
      ;;
    *.timer)
      printf '[Unit]\nDescription=fixture %s\n[Timer]\nOnCalendar=daily\n[Install]\nWantedBy=timers.target\n' "$name" >"$work$path"
      ;;
    *.list | *.sources)
      printf '# fixture %s\n' "$name" >"$work$path"
      ;;
    *)
      printf 'fixture %s\n' "$name" >"$work$path"
      chmod 0755 "$work$path"
      ;;
  esac
  case "$path" in
    /etc/*) printf '%s\n' "$path" >>"$work/DEBIAN/conffiles" ;;
  esac
  case "$path" in
    */system/*@.service) ;;
    */system/*.service | */system/*.socket | */system/*.timer)
      printf 'systemctl enable --now %s || true\n' "$(basename "$path")" >>"$work/DEBIAN/postinst"
      ;;
  esac
done <"$list"

printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: test <test@example.test>\nDescription: fixture %s\n' \
  "$name" "$version" "$name" >"$work/DEBIAN/control"
chmod 0755 "$work/DEBIAN/postinst"
dpkg-deb --root-owner-group -b "$work" "/tmp/${name}_${version}_all.deb" >/dev/null
