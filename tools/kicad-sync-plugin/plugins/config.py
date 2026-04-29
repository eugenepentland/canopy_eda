"""Per-board sync configuration.

Stored next to the .kicad_pcb as `<board>.eda-sync.json` so it travels with
the project. Holds the design name, server URL, OAuth client id/secret, and
the last synced version (purely informational).
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from typing import Optional


@dataclass
class BoardConfig:
    server_url: str = ""
    design: str = ""
    client_id: str = ""
    client_secret: str = ""
    last_synced_version: int = 0


def config_path(board_path: str) -> str:
    return board_path + ".eda-sync.json"


def load(board_path: str) -> BoardConfig:
    p = config_path(board_path)
    if not os.path.exists(p):
        return BoardConfig()
    try:
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return BoardConfig()
    return BoardConfig(
        server_url=data.get("server_url", ""),
        design=data.get("design", ""),
        client_id=data.get("client_id", ""),
        client_secret=data.get("client_secret", ""),
        last_synced_version=int(data.get("last_synced_version", 0)),
    )


def save(board_path: str, cfg: BoardConfig) -> None:
    p = config_path(board_path)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(asdict(cfg), f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)


def cache_root(server_url: str, design: str) -> str:
    """Filesystem location for the per-(server, design) object cache."""
    safe_server = server_url.replace("://", "_").replace("/", "_").replace(":", "_")
    return os.path.join(
        os.path.expanduser("~"),
        ".cache",
        "eda-kicad-sync",
        safe_server,
        design,
    )
