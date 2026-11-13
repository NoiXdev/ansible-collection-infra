#!/usr/bin/env python3
"""Fake of the GitHub API's Roundcube release list, for tests/mailcow/run.sh.

  fake-github.py serve DIR PORT
      Serves DIR on 127.0.0.1:PORT. GET /releases (any query) answers with
      DIR/releases.json, or with GitHub's rate-limit answer (403 and
      x-ratelimit-remaining: 0) while DIR/rate-limit exists; every other path
      is a file below DIR.

  fake-github.py releases DIR BASE_URL MODE CACHE SPEC...
      Writes DIR/releases.json (newest first, as given) and the tarballs below
      DIR/dl. SPEC is TAG[:FLAG,...]; FLAGs: pre (a prerelease), noasset (no
      -complete.tar.gz), nodigest (no checksum), bad (a checksum that does not
      match), nodl (a download URL that is not served), phpX.Y (composer.json
      requires PHP >=X.Y; the default is >=8.1), php=CONSTRAINT (composer.json
      requires exactly that). MODE stub writes a
      tiny tarball with the release's iniset.php; MODE real takes the
      release's real tarball from github.com (kept in CACHE).
"""
import hashlib
import http.server
import io
import json
import os
import sys
import tarfile
import time
import urllib.request


def serve(directory, port):
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=directory, **kwargs)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/releases":
                if os.path.exists(os.path.join(directory, "rate-limit")):
                    body = b'{"message": "API rate limit exceeded for 192.0.2.1."}'
                    self.send_response(403)
                    self.send_header("x-ratelimit-limit", "60")
                    self.send_header("x-ratelimit-remaining", "0")
                    self.send_header("x-ratelimit-reset", str(int(time.time()) + 1800))
                else:
                    with open(os.path.join(directory, "releases.json"), "rb") as f:
                        body = f.read()
                    self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            super().do_GET()

    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


def stub_tarball(tag, constraint):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for name, content in {
            "program/include/iniset.php": "<?php\ndefine('RCMAIL_VERSION', '%s');\n" % tag,
            "index.php": "<?php // stub Roundcube\n",
            "composer.json": json.dumps({"require": {"php": constraint}}),
        }.items():
            data = content.encode()
            info = tarfile.TarInfo("roundcubemail-%s/%s" % (tag, name))
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def releases(directory, base_url, mode, cache, specs):
    os.makedirs(os.path.join(directory, "dl"), exist_ok=True)
    os.makedirs(cache, exist_ok=True)
    out = []
    for spec in specs:
        tag, _, flag_text = spec.partition(":")
        flags = set(flag_text.split(",")) if flag_text else set()
        release = {"tag_name": tag, "prerelease": "pre" in flags, "draft": False, "assets": []}
        if "noasset" not in flags:
            name = "roundcubemail-%s-complete.tar.gz" % tag
            if mode == "stub":
                php = next((f[3:] for f in flags if f.startswith("php") and not f.startswith("php=")), "8.1")
                constraint = next((f[4:] for f in flags if f.startswith("php=")), ">=" + php)
                data = stub_tarball(tag, constraint)
            else:
                cached = os.path.join(cache, name)
                if not os.path.exists(cached):
                    url = "https://github.com/roundcube/roundcubemail/releases/download/%s/%s" % (tag, name)
                    with urllib.request.urlopen(url, timeout=120) as response, open(cached + ".part", "wb") as f:
                        f.write(response.read())
                    os.rename(cached + ".part", cached)
                with open(cached, "rb") as f:
                    data = f.read()
            with open(os.path.join(directory, "dl", name), "wb") as f:
                f.write(data)
            asset = {
                "name": name,
                "browser_download_url": "%s/dl/%s" % (base_url, "missing-" + name if "nodl" in flags else name),
            }
            if "nodigest" not in flags:
                asset["digest"] = "sha256:" + ("0" * 64 if "bad" in flags else hashlib.sha256(data).hexdigest())
            release["assets"].append(asset)
        out.append(release)
    with open(os.path.join(directory, "releases.json"), "w") as f:
        json.dump(out, f)


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        serve(sys.argv[2], int(sys.argv[3]))
    elif sys.argv[1] == "releases":
        releases(*sys.argv[2:6], sys.argv[6:])
    else:
        sys.exit(__doc__)
