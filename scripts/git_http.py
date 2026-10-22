"""Minimal smart-HTTP git server for local clone testing on the Android emulator.

Serves bare repos under GITROOT at http://127.0.0.1:8080/<repo>.git using
`git upload-pack` in stateless-rpc mode (read-only, upload-pack only).

Env knobs (all optional):
  GIT_AUTH=user:pass   require HTTP Basic auth with exactly these credentials
  GIT_AUTH_FIRST=user:pass  accept this once, then require GIT_AUTH (unused)
  GIT_KBPS=64          throttle response bodies to N KB/s to simulate slow nets
"""
import base64
import gzip
import http.server
import os
import subprocess
import sys
import time
import urllib.parse

GITROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gitrepo")
PORT = int(os.environ.get("GIT_PORT", "8080"))
AUTH = os.environ.get("GIT_AUTH", "").strip()
KBPS = int(os.environ.get("GIT_KBPS", "0") or 0)

ADV_HEAD = b"001e# service=git-upload-pack\n0000"
CHUNK = 4096


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[git-http] %s\n" % (fmt % args))

    # -- auth ---------------------------------------------------------------
    def _check_auth(self) -> bool:
        """Return True when the request may proceed; sends 401 otherwise."""
        if not AUTH:
            return True
        header = self.headers.get("Authorization") or ""
        if header.startswith("Basic "):
            try:
                raw = base64.b64decode(header[6:]).decode("utf-8", "replace")
            except Exception:
                raw = ""
            if raw == AUTH:
                return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="vault"')
        body = b"auth required\n"
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        return False

    # -- response -----------------------------------------------------------
    def _reply(self, ctype: str, body: bytes):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if KBPS <= 0:
            self.wfile.write(body)
            return
        step = max(CHUNK, KBPS * 1024 // 4)  # 4 flushes per second
        for i in range(0, len(body), step):
            self.wfile.write(body[i : i + step])
            self.wfile.flush()
            time.sleep(step / (KBPS * 1024))

    def _repo_dir(self, raw_path: str):
        name = urllib.parse.unquote(raw_path.strip("/"))
        target = os.path.abspath(os.path.join(GITROOT, name))
        if not target.startswith(GITROOT) or not os.path.isdir(target):
            self.send_error(404, "no such repo: %s" % name)
            return None
        return target

    # -- routes -------------------------------------------------------------
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if not parsed.path.endswith("/info/refs"):
            self.send_error(404, "only /<repo>.git/info/refs is served")
            return
        if not self._check_auth():
            return
        service = urllib.parse.parse_qs(parsed.query).get("service", [""])[0]
        if service != "git-upload-pack":
            self.send_error(403, "only git-upload-pack is supported")
            return
        repo = self._repo_dir(parsed.path[: -len("/info/refs")])
        if repo is None:
            return
        out = subprocess.run(
            ["git", "upload-pack", "--stateless-rpc", "--advertise-refs", repo],
            capture_output=True,
        )
        if out.returncode != 0:
            self.send_error(500, out.stderr.decode("utf-8", "replace"))
            return
        self._reply(
            "application/x-git-upload-pack-advertisement", ADV_HEAD + out.stdout
        )

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if not parsed.path.endswith("/git-upload-pack"):
            self.send_error(404, "only /<repo>.git/git-upload-pack is served")
            return
        if not self._check_auth():
            return
        repo = self._repo_dir(parsed.path[: -len("/git-upload-pack")])
        if repo is None:
            return
        length = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(length)
        if (self.headers.get("Content-Encoding") or "").lower() == "gzip":
            data = gzip.decompress(data)
        out = subprocess.run(
            ["git", "upload-pack", "--stateless-rpc", repo],
            input=data,
            capture_output=True,
        )
        if out.returncode != 0:
            self.send_error(500, out.stderr.decode("utf-8", "replace"))
            return
        self._reply("application/x-git-upload-pack-result", out.stdout)


if __name__ == "__main__":
    os.chdir(GITROOT)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(
        "serving %s on http://127.0.0.1:%d auth=%s kbps=%s"
        % (GITROOT, PORT, AUTH or "-", KBPS or "-"),
        flush=True,
    )
    srv.serve_forever()
