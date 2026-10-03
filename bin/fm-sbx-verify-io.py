#!/usr/bin/env python3
"""fm-sbx-verify-io.py - the two byte-level primitives of the verification broker.

Used only by bin/fm-sbx-verify-broker.sh, on the host, never inside a sandbox.
Standard library only.

  copy-in --src PATH --dst PATH --max BYTES [--magic png]
      Copy one regular file out of an untrusted directory into a host-only one.
      The source is opened with O_NOFOLLOW and O_NONBLOCK and judged by fstat on
      the open descriptor, so a symlink, a FIFO, a device or a directory is
      refused and a path swapped after the open cannot change what is read.
      The destination is created exclusively with mode 0600.
      Prints "<sha256> <bytes>" on success.
      Exit codes: 3 source missing, 4 not a regular file or a symlink,
      5 larger than --max, 6 wrong magic bytes, 7 destination exists or cannot
      be written, 2 usage.

  serve --file PATH --port N [--bind ADDR] [--ready PATH]
      Serve exactly one bundle and the two answers an Expo dev client needs before
      it will fetch it, read into memory once, and nothing else:
      GET and HEAD / answer with a fixed Expo manifest (application/expo+json)
      whose launchAsset points at http://<Host header>/index.bundle, GET and
      HEAD /status answer "packager-status:running", GET /index.bundle answers
      with the bytes (a query string is ignored) and HEAD /index.bundle with a
      javascript Content-Type and the length, and every other method or path
      answers a plain 404. A Host header that is not a plain host[:port] is a
      404 too. The manifest carries no worker-authored bytes.
      Nothing on the file system is ever consulted per request.
"""
import errno
import hashlib
import json
import os
import re
import stat
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
CHUNK = 1 << 20
# What an Expo dev client built for SDK 54 needs in the manifest before it loads a bundle.
# expo-updates is not installed in the dev client, so extra.expoGo.developer.tool must be set.
SDK_VERSION = "54.0.0"
RUNTIME_VERSION = "exposdk:" + SDK_VERSION
MANIFEST_ID = "00000000-0000-4000-8000-000000000000"
MANIFEST_CREATED = "2026-01-01T00:00:00.000Z"
HOST_RE = re.compile(r"^(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(?::[0-9]{1,5})?$")


def usage(msg):
    sys.stderr.write("fm-sbx-verify-io: %s\n" % msg)
    sys.exit(2)


def parse(argv, spec):
    out = {}
    i = 0
    while i < len(argv):
        key = argv[i]
        if key not in spec:
            usage("unknown argument %r" % key)
        if i + 1 >= len(argv):
            usage("%s needs a value" % key)
        out[key] = argv[i + 1]
        i += 2
    return out


def copy_in(argv):
    a = parse(argv, {"--src", "--dst", "--max", "--magic"})
    for need in ("--src", "--dst", "--max"):
        if need not in a:
            usage("%s is required" % need)
    try:
        limit = int(a["--max"])
    except ValueError:
        usage("--max must be an integer")
    magic = None
    if "--magic" in a:
        if a["--magic"] != "png":
            usage("--magic only knows png")
        magic = PNG_MAGIC
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(a["--src"], flags)
    except OSError as e:
        if e.errno == errno.ENOENT:
            return 3
        return 4
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return 4
        if st.st_size > limit:
            return 5
        data = b""
        while len(data) <= limit:
            chunk = os.read(fd, CHUNK)
            if not chunk:
                break
            data += chunk
        if len(data) > limit:
            return 5
    finally:
        os.close(fd)
    if magic is not None and not data.startswith(magic):
        return 6
    try:
        out = os.open(
            a["--dst"],
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
            0o600,
        )
    except OSError:
        return 7
    try:
        view = memoryview(data)
        while view:
            n = os.write(out, view)
            view = view[n:]
    except OSError:
        return 7
    finally:
        os.close(out)
    sys.stdout.write("%s %d\n" % (hashlib.sha256(data).hexdigest(), len(data)))
    return 0


def serve(argv):
    a = parse(argv, {"--file", "--port", "--bind", "--ready"})
    for need in ("--file", "--port"):
        if need not in a:
            usage("%s is required" % need)
    try:
        port = int(a["--port"])
    except ValueError:
        usage("--port must be an integer")
    with open(a["--file"], "rb") as fh:
        body = fh.read()
    bind = a.get("--bind", "127.0.0.1")

    class Handler(BaseHTTPRequestHandler):
        server_version = "fm-sbx-verify"
        sys_version = ""
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass

        def _plain_404(self):
            msg = b"not found\n"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(msg)))
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(msg)
            self.close_connection = True

        def _path(self):
            return self.path.split("?", 1)[0]

        def _host(self):
            host = self.headers.get("Host", "")
            return host if HOST_RE.match(host) else None

        def _send(self, ctype, payload, extra=()):
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            for k, v in extra:
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
            self.close_connection = True

        def _serve_get_or_head(self):
            path = self._path()
            if path == "/index.bundle":
                self._send("application/javascript", body)
            elif path == "/status":
                self._send("text/plain", b"packager-status:running")
            elif path == "/" and self._host():
                manifest = json.dumps(
                    {
                        "id": MANIFEST_ID,
                        "createdAt": MANIFEST_CREATED,
                        "runtimeVersion": RUNTIME_VERSION,
                        "launchAsset": {
                            "key": "bundle",
                            "contentType": "application/javascript",
                            "url": "http://%s/index.bundle" % self._host(),
                        },
                        "assets": [],
                        "metadata": {},
                        "extra": {
                            "expoGo": {"developer": {"tool": "expo-cli"}},
                            "expoClient": {
                                "name": "SportsMeet",
                                "slug": "sportsmeet",
                                "sdkVersion": SDK_VERSION,
                                "platforms": ["android"],
                            },
                        },
                    }
                ).encode()
                self._send(
                    "application/expo+json",
                    manifest,
                    (("expo-protocol-version", "0"), ("expo-sfv-version", "0")),
                )
            else:
                self._plain_404()

        do_HEAD = do_GET = _serve_get_or_head

        def _other(self):
            self._plain_404()

        do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_TRACE = do_CONNECT = _other

    httpd = ThreadingHTTPServer((bind, port), Handler)
    if "--ready" in a:
        tmp = a["--ready"] + ".tmp"
        with open(tmp, "w") as fh:
            fh.write("%d\n" % httpd.server_address[1])
        os.rename(tmp, a["--ready"])
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def main():
    if len(sys.argv) < 2:
        usage("a subcommand is required: copy-in or serve")
    cmd, rest = sys.argv[1], sys.argv[2:]
    if cmd == "copy-in":
        return copy_in(rest)
    if cmd == "serve":
        return serve(rest)
    usage("unknown subcommand %r" % cmd)


if __name__ == "__main__":
    sys.exit(main())
