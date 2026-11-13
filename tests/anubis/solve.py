#!/usr/bin/env python3
"""A browser stand-in for the anubis test suite (stdlib only).

It runs on the test host: tests/anubis/run.sh pipes it into python3 there.

  solve.py probe URL [--jar FILE] [--ua UA] [--header NAME:VALUE ...] [--echo NAME]
                [--response-header NAME ...]
      One GET; prints "<status> <kind>", kind is challenge (the Anubis
      challenge page), denied (Anubis's error page), backend (a whoami
      answer, or with --expect a page that contains TEXT) or other.
      --echo adds the value of request header NAME as the backend got it
      (whoami's echo), or "-"; each --response-header adds the value of the
      answer's header NAME, or "-".
  solve.py solve URL --jar FILE [--ua UA] [--difficulty N]
      GET URL, which must answer the challenge; solve its proof of work, call
      pass-challenge with redir=URL (as Anubis's page does: its own URL),
      follow the redirects, which must end on the backend (200), then GET
      URL again, which must be the backend without a second challenge.
      pass-challenge must set its cookies for the host only (no Domain
      attribute). The cookies go to FILE (per host). Prints "solved ...".
  solve.py redirect URL --redir TARGET --jar FILE
      GET URL, solve the challenge and call pass-challenge with redir=TARGET;
      prints "<status> <Location>" of that answer without following it.

Every command also takes --expect TEXT (the backend is a page with TEXT, for
backends that are not whoami), --resolve HOST=ADDRESS (connect to ADDRESS
for HOST, keeping HOST for the Host header and TLS) and --source ADDRESS
(the local address to connect from). Paths go out as given (dot segments
too); HTTPS certificates are not checked.

Cookies are kept per host by hand: the suite runs on plain HTTP, and Anubis
marks its cookies Secure, which a cookie jar would never send back there.
"""

import argparse
import gzip
import hashlib
import html
import json
import os
import re
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BROWSER_UA = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
CHALLENGE_RE = re.compile(r'<script id="anubis_challenge" type="application/json">(.*?)</script>', re.S)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


OPENER = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
# --expect: the text a backend page carries (None: a whoami answer).
EXPECT = None


def connect_options(resolve, source):
    """--resolve and --source, for every connection this process opens."""
    if resolve:
        name, _, address = resolve.partition("=")
        getaddrinfo = socket.getaddrinfo
        socket.getaddrinfo = lambda host, *a, **k: getaddrinfo(address if host == name else host, *a, **k)
    if source:
        create_connection = socket.create_connection

        def bound(address, timeout=socket._GLOBAL_DEFAULT_TIMEOUT, source_address=None, **k):
            return create_connection(address, timeout, (source, 0), **k)
        socket.create_connection = bound


def load_jar(path):
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_jar(path, jar):
    if path:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(jar, f)


def store_cookies(jar, host, headers):
    cookies = jar.setdefault(host, {})
    for line in headers.get_all("Set-Cookie") or []:
        parts = [p.strip() for p in line.split(";")]
        name, _, value = parts[0].partition("=")
        attrs = {p.split("=", 1)[0].lower(): p.partition("=")[2] for p in parts[1:]}
        if attrs.get("max-age") == "0" or (value == "" and "expires" in attrs):
            cookies.pop(name, None)
        else:
            cookies[name] = value


def get(url, jar, ua, extra=None):
    host = urllib.parse.urlsplit(url).hostname
    # An empty User-Agent goes out as an empty header line (urllib adds its
    # own only when none is set).
    headers = {"User-Agent": ua, "Accept": "text/html", "Accept-Encoding": "gzip", "Accept-Language": "en"}
    cookies = jar.get(host, {})
    if cookies:
        headers["Cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
    headers.update(extra or {})
    req = urllib.request.Request(url, headers=headers)
    try:
        resp = OPENER.open(req, timeout=15)
        status, hdrs, body = resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        status, hdrs, body = e.code, e.headers, e.read()
    if hdrs.get("Content-Encoding") == "gzip":
        body = gzip.decompress(body)
    store_cookies(jar, host, hdrs)
    return status, hdrs, body.decode("utf-8", "replace")


def host_only_cookies(url, hdrs):
    """pass-challenge's Set-Cookie lines: at least one, none with Domain."""
    lines = hdrs.get_all("Set-Cookie") or []
    if not lines:
        die(f"{url}: pass-challenge set no cookie")
    for line in lines:
        name, _, rest = line.partition(";")
        attrs = [p.strip().split("=", 1)[0].lower() for p in rest.split(";")]
        if "domain" in attrs:
            die(f"{url}: pass-challenge set {name.partition('=')[0]} with a Domain attribute:{rest}")


def challenge_data(body):
    m = CHALLENGE_RE.search(body)
    data = json.loads(html.unescape(m.group(1))) if m else None
    return data if isinstance(data, dict) and data.get("challenge") else None


def kind(body):
    # Anubis's other pages carry the challenge script too, set to null.
    if challenge_data(body):
        return "challenge"
    if "<title>Oh noes!</title>" in body:
        return "denied"
    if EXPECT is not None:
        return "backend" if EXPECT in body else "other"
    if "Hostname:" in body and "RemoteAddr:" in body:
        return "backend"
    return "other"


def die(msg, body=""):
    if body:
        msg += "; body: " + re.sub(r"\s+", " ", body)[:300]
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def pass_url(url, body, redir, want_difficulty):
    data = challenge_data(body)
    if not data:
        die(f"{url} did not answer the challenge", body)
    challenge, rules = data["challenge"], data["rules"]
    if challenge["method"] != "fast":
        die(f"challenge method {challenge['method']}, expected fast")
    difficulty = int(rules["difficulty"])
    if want_difficulty is not None and difficulty != want_difficulty:
        die(f"challenge difficulty {difficulty}, expected {want_difficulty}")
    start = time.time()
    want, nonce = "0" * difficulty, 0
    while True:
        digest = hashlib.sha256((challenge["randomData"] + str(nonce)).encode()).hexdigest()
        if digest.startswith(want):
            break
        nonce += 1
    query = urllib.parse.urlencode({
        "id": challenge["id"], "response": digest, "nonce": nonce, "redir": redir,
        "elapsedTime": int((time.time() - start) * 1000),
    })
    parts = urllib.parse.urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}/.within.website/x/cmd/anubis/api/pass-challenge?{query}", difficulty


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["probe", "solve", "redirect"])
    ap.add_argument("url")
    ap.add_argument("--jar")
    ap.add_argument("--ua", default=BROWSER_UA)
    ap.add_argument("--header", action="append", default=[])
    ap.add_argument("--redir")
    ap.add_argument("--difficulty", type=int)
    ap.add_argument("--echo")
    ap.add_argument("--response-header", action="append", default=[])
    ap.add_argument("--expect")
    ap.add_argument("--resolve")
    ap.add_argument("--source")
    args = ap.parse_args()
    global EXPECT
    EXPECT = args.expect
    connect_options(args.resolve, args.source)
    ua = args.ua
    extra = dict(h.split(":", 1) for h in args.header)
    jar = load_jar(args.jar)

    if args.command == "probe":
        status, hdrs, body = get(args.url, jar, ua, extra)
        save_jar(args.jar, jar)
        out = [str(status), kind(body)]
        if args.echo:
            m = re.search(rf"^{re.escape(args.echo)}: (.*?)\r?$", body, re.M | re.I)
            out.append(m.group(1) if m else "-")
        for name in args.response_header:
            out.append(hdrs.get(name) or "-")
        print(" ".join(out))
        return

    status, _, body = get(args.url, jar, ua)
    if kind(body) != "challenge":
        die(f"first GET {args.url}: {status} {kind(body)}, expected the challenge", body)
    nxt, difficulty = pass_url(args.url, body, args.redir or args.url, args.difficulty)

    if args.command == "redirect":
        status, hdrs, _ = get(nxt, jar, ua)
        save_jar(args.jar, jar)
        print(status, hdrs.get("Location") or "-")
        return

    hops = []
    for _ in range(5):
        status, hdrs, body = get(nxt, jar, ua)
        if not hops:
            host_only_cookies(nxt, hdrs)
        hops.append(str(status))
        if status in (301, 302, 303, 307, 308):
            nxt = urllib.parse.urljoin(nxt, hdrs["Location"])
            continue
        break
    if status != 200 or kind(body) != "backend":
        die(f"after pass-challenge: {status} {kind(body)} (hops {','.join(hops)}), expected the backend", body)
    status, _, body = get(args.url, jar, ua)
    if status != 200 or kind(body) != "backend":
        die(f"second GET {args.url}: {status} {kind(body)}, expected the backend without a challenge", body)
    save_jar(args.jar, jar)
    print(f"solved {args.url} difficulty={difficulty} hops={','.join(hops)}")


if __name__ == "__main__":
    main()
