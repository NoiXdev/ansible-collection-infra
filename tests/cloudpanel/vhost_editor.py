"""Saves a site's vhost through CloudPanel's vhost editor, as a customer does.

Runs inside the test host: logs in to the CloudPanel UI, reads the vhost the
editor shows (the site's vhost_template in CloudPanel's database), edits it
and posts it back. CloudPanel stores it and writes the vhost file.

usage: vhost_editor.py <user> <password> <domain> insert-after <anchor> <line> [--crlf]
       vhost_editor.py <user> <password> <domain> remove <line> [--crlf]

--crlf posts the vhost with CRLF line breaks, as a browser submits a textarea.
"""

import http.cookiejar
import re
import sqlite3
import ssl
import sys
import urllib.parse
import urllib.request

UI = "https://127.0.0.1:8443"
DB = "/home/clp/htdocs/app/data/db.sq3"


def main():
    user, password, domain, op, *args = sys.argv[1:]
    crlf = bool(args) and args[-1] == "--crlf"
    if crlf:
        args = args[:-1]
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=context),
    )

    def get(path):
        with opener.open(UI + path) as r:
            return r.read().decode()

    def post(path, data):
        with opener.open(UI + path, urllib.parse.urlencode(data).encode()) as r:
            return r.read().decode()

    def token(page, name):
        m = re.search(r'name="%s" value="([^"]*)"' % re.escape(name), page)
        if not m:
            sys.exit("no %s on the page" % name)
        return m.group(1)

    login = get("/login")
    post("/login", {"userName": user, "password": password, "_csrf_token": token(login, "_csrf_token")})
    page = get("/site/%s/vhost" % domain)
    with sqlite3.connect("file:%s?mode=ro" % DB, uri=True) as db:
        (vhost,) = db.execute("SELECT vhost_template FROM site WHERE domain_name = ?", (domain,)).fetchone()

    if op == "insert-after":
        anchor, line = args
        lines = vhost.split("\n")
        out = []
        for current in lines:
            out.append(current)
            if current.strip() == anchor:
                out.append(re.match(r"\s*", current).group(0) + line)
        edited = "\n".join(out)
    elif op == "remove":
        (line,) = args
        edited = "\n".join(x for x in vhost.split("\n") if x.strip() != line)
    else:
        sys.exit("unknown operation " + op)
    if edited == vhost:
        sys.exit("the edit changes nothing in the vhost of " + domain)
    if crlf:
        edited = edited.replace("\r\n", "\n").replace("\n", "\r\n")

    post("/site/%s/vhost" % domain, {"vhost-template": edited, "token": token(page, "token")})
    with sqlite3.connect("file:%s?mode=ro" % DB, uri=True) as db:
        (saved,) = db.execute("SELECT vhost_template FROM site WHERE domain_name = ?", (domain,)).fetchone()
    if saved.strip() != edited.strip():
        sys.exit("CloudPanel did not save the vhost of " + domain)


if __name__ == "__main__":
    main()
