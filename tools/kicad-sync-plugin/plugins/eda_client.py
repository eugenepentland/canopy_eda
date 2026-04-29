"""HTTP client for the EDA server's read endpoints.

All endpoints accept `Authorization: Bearer <token>`. The server is at most
a few hops away (typically localhost:7050) so we rely on the standard library
rather than pulling in `requests`.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Optional
from urllib import error as urlerror
from urllib import request
from urllib.parse import urljoin


@dataclass
class FootprintEntry:
    name: str
    sha: str
    size: int


@dataclass
class ModelEntry:
    name: str
    sha: str
    size: int


@dataclass
class Manifest:
    version: int
    netlist_sha: str
    netlist_size: int
    footprints: list[FootprintEntry]
    models: list[ModelEntry]


class EdaClient:
    def __init__(self, base_url: str, token: str, *, timeout: float = 30.0):
        self.base_url = base_url.rstrip("/") + "/"
        self.token = token
        self.timeout = timeout

    def _req(self, path: str, *, headers: Optional[dict[str, str]] = None) -> tuple[int, dict[str, str], bytes]:
        url = urljoin(self.base_url, path.lstrip("/"))
        h = {"Authorization": f"Bearer {self.token}"}
        if headers:
            h.update(headers)
        req = request.Request(url, headers=h, method="GET")
        try:
            with request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urlerror.HTTPError as e:
            return e.code, dict(e.headers or {}), e.read() or b""

    def get_version(self, design: str) -> int:
        status, _, body = self._req(f"/api/version/{design}")
        if status != 200:
            raise RuntimeError(f"version fetch failed: HTTP {status}")
        return int(json.loads(body)["version"])

    def get_manifest(self, design: str) -> Manifest:
        status, _, body = self._req(f"/api/sync-manifest/{design}")
        if status == 401:
            raise PermissionError("server rejected token (401)")
        if status != 200:
            raise RuntimeError(f"manifest fetch failed: HTTP {status} — {body[:200]!r}")
        d = json.loads(body)
        return Manifest(
            version=int(d.get("version", 0)),
            netlist_sha=d["netlist"]["sha"],
            netlist_size=int(d["netlist"]["size"]),
            footprints=[FootprintEntry(**fp) for fp in d.get("footprints", [])],
            models=[ModelEntry(**m) for m in d.get("models", [])],
        )

    def get_netlist(self, design: str, *, etag: Optional[str] = None) -> tuple[str, Optional[str]]:
        """Returns (text, etag). Returns (cached_text="", etag) on 304 — caller
        is expected to keep the previous text around if it wants to cache."""
        headers = {"If-None-Match": etag} if etag else None
        status, h, body = self._req(f"/api/netlist/{design}", headers=headers)
        if status == 304:
            return "", etag
        if status != 200:
            raise RuntimeError(f"netlist fetch failed: HTTP {status}")
        return body.decode("utf-8", errors="replace"), h.get("ETag") or h.get("etag")

    def get_object(self, sha: str) -> bytes:
        if not all(c in "0123456789abcdef" for c in sha):
            raise ValueError(f"invalid sha: {sha!r}")
        status, _, body = self._req(f"/api/object/{sha}")
        if status != 200:
            raise RuntimeError(f"object {sha[:8]}… fetch failed: HTTP {status}")
        return body


class ObjectCache:
    """Filesystem-backed content-addressed cache. Keyed by sha; values are
    raw bytes (footprint .kicad_mod text or 3D-model binary)."""

    def __init__(self, root: str):
        self.root = root
        os.makedirs(root, exist_ok=True)

    def _path(self, sha: str) -> str:
        # Two-level fanout to keep directories shallow.
        return os.path.join(self.root, sha[:2], sha)

    def has(self, sha: str) -> bool:
        return os.path.exists(self._path(sha))

    def get(self, sha: str) -> bytes:
        with open(self._path(sha), "rb") as f:
            return f.read()

    def put(self, sha: str, data: bytes) -> None:
        p = self._path(sha)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        tmp = p + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, p)
