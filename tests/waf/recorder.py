"""The traefik scenario's recording backend: answers 200 to every request
and prints "<request line> | <User-Agent> | <body bytes>" for each to stdout
(docker logs), so the suite can tell which requests got past the WAF."""

import http.server


class Recorder(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        left = length
        while left > 0:
            chunk = self.rfile.read(min(left, 65536))
            if not chunk:
                break
            left -= len(chunk)
        print(f"{self.requestline} | {self.headers.get('User-Agent', '')} | {length - left}", flush=True)
        body = b"recorded\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = answer

    def log_message(self, format, *args):  # noqa: A002 (the base class's name)
        pass


http.server.ThreadingHTTPServer(("", 8000), Recorder).serve_forever()
