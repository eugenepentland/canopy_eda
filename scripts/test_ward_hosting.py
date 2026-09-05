#!/usr/bin/env python3
"""Exercise local and optional Ward hosting against a real netlisp binary.

Usage: python3 scripts/test_ward_hosting.py /absolute/path/to/netlisp
Uses temporary project state and a loopback Ward protocol fixture. No real
sessions, production data, or running services are changed.
"""
import contextlib
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time


class Ward(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        cookie = self.headers.get("Cookie", "")
        verdicts = {
            "ward_session=admin-fixture": (200, "admin", b"alice"),
            "ward_session=member-fixture": (200, "member", b"bob"),
            "ward_session=reader-fixture": (200, "unknown", b"reader"),
            "ward_session=unavailable-fixture": (503, "unknown", b"down"),
        }
        status, role, body = verdicts.get(cookie, (401, "unknown", b"unauthorized"))
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Ward-Role", role)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def request(port, path, method="GET", cookie=None, forwarded=False):
    headers = {}
    if cookie:
        headers["Cookie"] = "ward_session=" + cookie
    if forwarded:
        headers.update({"X-Forwarded-For": "198.51.100.10", "X-Forwarded-Proto": "https"})
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=8)
    try:
        conn.request(method, path, headers=headers)
        response = conn.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        conn.close()


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextlib.contextmanager
def instance(binary, ward_port, mode, configured=True, extra_args=()):
    with tempfile.TemporaryDirectory(prefix="netlisp-ward-test-") as tmp:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("WARD_", "NETLISP_"))}
        if mode is not None:
            env["NETLISP_AUTH"] = mode
        env["NETLISP_GIT_AUTOCOMMIT"] = "0"
        if configured:
            env.update({
                "WARD_VERIFY_URL": f"http://127.0.0.1:{ward_port}/verify",
                "WARD_LOGIN_URL": "https://ward.example.com/login",
                "WARD_SERVICE_NAME": "netlisp",
                "WARD_SERVICE_URL": "https://netlisp.example.com",
            })
        port = free_port()
        project = Path(tmp) / "project"
        project.mkdir()
        with (Path(tmp) / "server.log").open("w+") as log:
            proc = subprocess.Popen(
                [binary, "serve", "--project-dir", str(project), "--port", str(port), *extra_args],
                cwd=tmp, env=env, stdout=log, stderr=log,
            )
            try:
                if mode not in (None, "local", "ward") or (mode == "ward" and extra_args):
                    assert proc.wait(timeout=15) != 0, "invalid policy must refuse startup"
                    yield None
                    return
                for _ in range(100):
                    if proc.poll() is not None:
                        log.seek(0)
                        raise AssertionError(log.read())
                    try:
                        if request(port, "/healthz")[0] == 200:
                            break
                    except (ConnectionError, OSError):
                        pass
                    time.sleep(0.1)
                else:
                    raise AssertionError("server did not become ready")
                yield port
            except BaseException:
                log.seek(0)
                print(log.read()[-8000:], file=sys.stderr)
                raise
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()


def main():
    binary = str(Path(sys.argv[1]).resolve(strict=True))
    ward = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Ward)
    thread = threading.Thread(target=ward.serve_forever, daemon=True)
    thread.start()
    try:
        ward_port = ward.server_address[1]
        # WARD_* values alone must not change the default local policy.
        with instance(binary, ward_port, None) as port:
            assert request(port, "/api/designs")[0] == 200
            assert request(port, "/", forwarded=True)[0] == 403
        with instance(binary, ward_port, "ward") as port:
            status, headers, _ = request(port, "/", forwarded=True)
            assert status == 302 and headers["location"].startswith("https://ward.example.com/login?rd=")
            assert request(port, "/")[0] == 302, "loopback must also authenticate"
            assert request(port, "/api/designs", forwarded=True)[0] == 401
            assert request(port, "/", cookie="invalid-fixture", forwarded=True)[0] == 302
            for identity in ("admin-fixture", "member-fixture", "reader-fixture"):
                assert request(port, "/api/designs", cookie=identity, forwarded=True)[0] == 200
            assert request(port, "/api/sync-kicad-pcb/missing?push_layout=1", method="POST", cookie="reader-fixture")[0] == 403
            assert request(port, "/api/sync-kicad-pcb/missing?push_layout=1", method="POST", cookie="member-fixture")[0] == 400
            assert request(port, "/", cookie="unavailable-fixture")[0] == 503
            status, _, body = request(port, "/.well-known/oauth-protected-resource", forwarded=True)
            assert status == 200 and json.loads(body)["authorization_servers"] == ["https://ward.example.com"]
            assert request(port, "/healthz", forwarded=True)[0] == 200
            ward.shutdown()
            assert request(port, "/", cookie="uncached-after-outage")[0] == 503
        with instance(binary, ward_port, "ward", configured=False) as port:
            assert request(port, "/")[0] == 503
        with instance(binary, ward_port, "wards"):
            pass
        with instance(binary, ward_port, "ward", extra_args=("--allow-remote",)):
            pass
        print("PASS: local default, Ward login/API auth, roles, discovery, outages, and invalid policies")
    finally:
        ward.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    main()
