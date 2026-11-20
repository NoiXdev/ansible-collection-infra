"""The traefik scenario's recording backend: answers 200 to every request
and prints "<request line> | <User-Agent> | <body sha256> | <body bytes>" for
each to stdout (docker logs), so the suite can tell which requests got past
the WAF and whether their bodies arrived whole. Bodies come with a
Content-Length or chunked."""

import hashlib
import http.server


class Recorder(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def read_exactly(self, digest, length):
        left = length
        while left > 0:
            chunk = self.rfile.read(min(left, 65536))
            if not chunk:
                break
            digest.update(chunk)
            left -= len(chunk)
        return length - left

    def read_body(self, digest):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            total = 0
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    # Trailers, up to the empty line.
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return total
                total += self.read_exactly(digest, size)
                self.rfile.readline()
        return self.read_exactly(digest, int(self.headers.get("Content-Length") or 0))

    def answer(self):
        digest = hashlib.sha256()
        length = self.read_body(digest)
        print(f"{self.requestline} | {self.headers.get('User-Agent', '')} | {digest.hexdigest()} | {length}",
              flush=True)
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
