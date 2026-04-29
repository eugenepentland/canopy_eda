"""OAuth 2.0 authorization-code + PKCE client for the EDA server.

Mirrors the flow Claude Code uses for `/mcp` (see src/serve/oauth.zig). The
user mints a client_id / client_secret pair at /account in the EDA web UI
and registers a redirect_uri of `http://127.0.0.1:53682/callback`. The plugin
binds that exact port during the auth dance because the server enforces
strict redirect_uri equality.

Cached token lives at ~/.config/eda-kicad-sync/tokens.json (mode 0600).
"""

from __future__ import annotations

import base64
import hashlib
import http.server
import json
import os
import secrets
import threading
import time
import webbrowser
from dataclasses import dataclass
from typing import Optional
from urllib import error as urlerror
from urllib import request
from urllib.parse import parse_qs, urlencode, urljoin, urlparse


LOOPBACK_PORT = 53682
REDIRECT_PATH = "/callback"
SCOPE = "mcp"
TOKEN_LEEWAY_SECONDS = 60


def redirect_uri() -> str:
    return f"http://127.0.0.1:{LOOPBACK_PORT}{REDIRECT_PATH}"


@dataclass
class TokenRecord:
    server_url: str
    client_id: str
    access_token: str
    expires_at: int  # unix seconds
    scope: str

    def is_fresh(self, now: Optional[int] = None) -> bool:
        if not self.access_token:
            return False
        t = now if now is not None else int(time.time())
        return t + TOKEN_LEEWAY_SECONDS < self.expires_at


class TokenStore:
    """JSON file at ~/.config/eda-kicad-sync/tokens.json. Keyed by
    (server_url, client_id) → TokenRecord."""

    def __init__(self, path: Optional[str] = None):
        self.path = path or os.path.join(
            os.path.expanduser("~"), ".config", "eda-kicad-sync", "tokens.json"
        )

    def _read(self) -> dict:
        try:
            with open(self.path, encoding="utf-8") as f:
                return json.load(f)
        except FileNotFoundError:
            return {}
        except (OSError, json.JSONDecodeError):
            return {}

    def _write(self, data: dict) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    @staticmethod
    def _key(server_url: str, client_id: str) -> str:
        return f"{server_url.rstrip('/')}#{client_id}"

    def get(self, server_url: str, client_id: str) -> Optional[TokenRecord]:
        d = self._read().get(self._key(server_url, client_id))
        if not d:
            return None
        return TokenRecord(
            server_url=d["server_url"],
            client_id=d["client_id"],
            access_token=d["access_token"],
            expires_at=int(d.get("expires_at", 0)),
            scope=d.get("scope", ""),
        )

    def put(self, rec: TokenRecord) -> None:
        data = self._read()
        data[self._key(rec.server_url, rec.client_id)] = {
            "server_url": rec.server_url,
            "client_id": rec.client_id,
            "access_token": rec.access_token,
            "expires_at": rec.expires_at,
            "scope": rec.scope,
        }
        self._write(data)


# ── PKCE helpers ─────────────────────────────────────────────────────────


def _gen_verifier() -> str:
    # 32 random bytes → 43-char URL-safe base64.
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).decode("ascii").rstrip("=")


def _challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


# ── Loopback callback listener ───────────────────────────────────────────


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    captured: dict = {}

    def do_GET(self):  # noqa: N802 — http.server convention
        parsed = urlparse(self.path)
        if parsed.path != REDIRECT_PATH:
            self.send_response(404)
            self.end_headers()
            return
        params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        _CallbackHandler.captured.update(params)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(
            b"<html><body><h2>EDA sync authorized</h2>"
            b"<p>You can close this tab and return to KiCad.</p></body></html>"
        )

    def log_message(self, *_args, **_kwargs):
        pass  # silence stderr


def _wait_for_code(timeout: float = 180.0) -> dict:
    _CallbackHandler.captured = {}
    server = http.server.HTTPServer(("127.0.0.1", LOOPBACK_PORT), _CallbackHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    deadline = time.time() + timeout
    try:
        while time.time() < deadline:
            if "code" in _CallbackHandler.captured or "error" in _CallbackHandler.captured:
                return dict(_CallbackHandler.captured)
            time.sleep(0.1)
        raise TimeoutError("OAuth callback timed out")
    finally:
        server.shutdown()
        server.server_close()


# ── Public API ───────────────────────────────────────────────────────────


def authorize(
    server_url: str,
    client_id: str,
    client_secret: str,
    *,
    open_browser: bool = True,
) -> TokenRecord:
    """Run the auth-code+PKCE dance once. Returns a fresh TokenRecord."""

    server_url = server_url.rstrip("/")
    verifier = _gen_verifier()
    challenge = _challenge(verifier)
    state = secrets.token_urlsafe(16)

    auth_url = urljoin(
        server_url + "/",
        "oauth/authorize?"
        + urlencode(
            {
                "response_type": "code",
                "client_id": client_id,
                "redirect_uri": redirect_uri(),
                "scope": SCOPE,
                "state": state,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            }
        ),
    )

    if open_browser:
        webbrowser.open(auth_url)
    else:
        # Tests / headless environments.
        print(f"open this URL to authorize: {auth_url}")

    captured = _wait_for_code()
    if captured.get("error"):
        raise RuntimeError(f"OAuth error: {captured['error']}")
    if captured.get("state") != state:
        raise RuntimeError("OAuth state mismatch — possible CSRF")
    code = captured.get("code")
    if not code:
        raise RuntimeError("OAuth callback missing code")

    token_url = urljoin(server_url + "/", "oauth/token")
    body = urlencode(
        {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri(),
            "client_id": client_id,
            "client_secret": client_secret,
            "code_verifier": verifier,
        }
    ).encode("ascii")
    req = request.Request(
        token_url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with request.urlopen(req, timeout=30.0) as resp:
            payload = json.loads(resp.read())
    except urlerror.HTTPError as e:
        raise RuntimeError(f"token exchange failed: HTTP {e.code} — {e.read()[:300]!r}") from None

    expires_in = int(payload.get("expires_in", 0))
    return TokenRecord(
        server_url=server_url,
        client_id=client_id,
        access_token=payload["access_token"],
        expires_at=int(time.time()) + expires_in,
        scope=payload.get("scope", SCOPE),
    )


def ensure_token(
    server_url: str,
    client_id: str,
    client_secret: str,
    store: Optional[TokenStore] = None,
    *,
    open_browser: bool = True,
) -> TokenRecord:
    """Return a fresh token, running the OAuth dance only if needed."""
    s = store or TokenStore()
    cached = s.get(server_url, client_id)
    if cached and cached.is_fresh():
        return cached
    rec = authorize(server_url, client_id, client_secret, open_browser=open_browser)
    s.put(rec)
    return rec
