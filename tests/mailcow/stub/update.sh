#!/usr/bin/env bash
# Test stub of mailcow's update.sh, in a clone of a local "upstream" repository
# (run.sh). Records its calls in /var/log/mailcow-stub/update.calls.
#   --check  0 when origin/master is not merged yet, 3 when it is.
#   --force  what the real one does around Git: mailcow down, local changes
#            committed ("Before update"), origin/master merged with
#            -Xtheirs (a conflicting local change loses to the release; what
#            is still in conflict is added as it is and committed), mailcow up.
# Flags in /etc/mailcow-stub: rerun-once (exit 2 asking to be started again,
# once, as after update.sh updated itself), merge-stops (a plain merge that
# stops on a conflict, leaving it unmerged, and exit 1), break-after-update
# (stops dovecot-mailcow after the update), check-fails (--check exits 99 as
# when GitHub cannot be reached), update-hangs (--force sleeps 600 seconds
# before it changes anything).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
flags=/etc/mailcow-stub
mkdir -p /var/log/mailcow-stub
echo "$*" >>/var/log/mailcow-stub/update.calls
git() { command git -c user.name=moo -c user.email=moo@cow.moo "$@"; }

case "${1:-}" in
  --check)
    if [ -e "$flags/check-fails" ]; then
      echo "A problem occurred while trying to fetch the latest revision from github."
      exit 99
    fi
    git fetch -q origin master || exit 99
    if git merge-base --is-ancestor origin/master HEAD; then
      echo "No updates available."
      exit 3
    fi
    echo "Updated code is available."
    exit 0
    ;;
  --force) ;;
  *)
    echo "update.sh stub: unknown arguments: $*"
    exit 1
    ;;
esac

if [ -e "$flags/update-hangs" ]; then
  sleep 600
fi

if [ -e "$flags/rerun-once" ]; then
  rm -f "$flags/rerun-once"
  echo "update.sh changed, please run this script again, exiting."
  exit 2
fi

docker compose down
git add -u
git commit -qm "Before update on $(date +%F_%T)" >/dev/null
git fetch -q origin
message="After update on $(date +%F_%T)"
if [ -e "$flags/merge-stops" ]; then
  if ! git merge -q -m "$message" origin/master; then
    echo "Oh no, something went wrong. Please check the error message above."
    exit 1
  fi
else
  git merge -q -Xtheirs -Xpatience -m "$message" origin/master
  case "$?" in
    0) ;;
    1)
      git status --porcelain | grep -E "UD|DU" | awk '{print $2}' | xargs -r rm -v
      git add -A
      git commit -qm "$message" >/dev/null
      git checkout .
      ;;
    *)
      echo "Oh no, something went wrong. Please check the error message above."
      exit 1
      ;;
  esac
fi
docker compose up -d
if [ -e "$flags/break-after-update" ]; then
  docker compose stop dovecot-mailcow
fi
exit 0
