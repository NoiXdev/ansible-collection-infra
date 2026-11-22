#!/bin/sh
# Requests to Postal's web server, run inside the runner service (on the
# Traefik network) by run.sh: its curl talks to web at <address>, its address
# on that network, port 5000, with Host: postal.test.
#   web.sh get <address> <path>
#       prints the body, then the status on a line of its own
#   web.sh login <address>
#       stdin: the e-mail address on the first line, the password after it
#       (as it is, without a newline); logs in through the login form and
#       prints the status of the POST /login on a line of its own, then the
#       body of GET / and its status on a line of its own
#   web.sh reset <address>
#       stdin: the e-mail address; asks for a password reset mail through
#       the form and prints the status of the POST /login/reset
set -eu

action="$1"
base="http://$2:5000"
jar=/tmp/web.jar

req() { curl --silent --show-error --max-time 120 --header 'Host: postal.test' --cookie "$jar" --cookie-jar "$jar" "$@"; }

# The CSRF token of the form on the page <path>.
form_token() {
  req "$base$1" >/tmp/web.form
  sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p' /tmp/web.form | head -n 1
}

case "$action" in
  get)
    req --write-out '\n%{http_code}\n' "$base$3"
    ;;
  login)
    IFS= read -r email
    cat >/tmp/web.pw
    token="$(form_token /login)"
    req --output /dev/null --write-out '%{http_code}\n' --data-urlencode "authenticity_token=$token" \
      --data-urlencode "email_address=$email" --data-urlencode "password@/tmp/web.pw" "$base/login"
    rm -f /tmp/web.pw
    req --write-out '\n%{http_code}\n' "$base/"
    ;;
  reset)
    IFS= read -r email || true
    token="$(form_token /login/reset)"
    req --output /dev/null --write-out '%{http_code}\n' --data-urlencode "authenticity_token=$token" \
      --data-urlencode "email_address=$email" "$base/login/reset"
    ;;
  *)
    echo "usage: web.sh get|login|reset <address> [path]" >&2
    exit 2
    ;;
esac
