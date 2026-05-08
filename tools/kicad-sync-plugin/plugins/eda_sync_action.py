"""Entry point for the EDA Sync KiCad action plugin.

Invoked by KiCad 10 when the user clicks the toolbar button. KiCad sets the
IPC environment (KICAD_API_SOCKET / KICAD_API_TOKEN) so kipy can connect to
the running editor.

Workflow:
    1. Load per-board config (server URL, design, OAuth client).
    2. If incomplete, show a Tk setup dialog.
    3. Ensure OAuth token; run browser auth if needed.
    4. Pull manifest + netlist + new footprints from the server.
    5. Apply via kipy in a single commit.
    6. Show result dialog.
"""

from __future__ import annotations

import argparse
import os
import sys
import traceback
from typing import Optional

from . import config as cfg_mod
from . import eda_client
from . import netlist_parser
from . import oauth_client
from . import sync_core
from .eda_client import EdaClient, ObjectCache, Manifest


def _resolve_board_path() -> Optional[str]:
    """KiCad 10 sets KICAD_DOCUMENT_PATH (or similar) when invoking an
    IPC plugin against a specific document. Fall back to asking kipy."""
    for env_var in ("EDA_BOARD_PATH", "KICAD_DOCUMENT_PATH", "KICAD_BOARD_PATH"):
        v = os.environ.get(env_var)
        if v:
            return v
    try:
        from .kipy_adapter import _import_kipy, _kipy

        _import_kipy()
        kicad = _kipy.KiCad()  # type: ignore[union-attr]
        board = kicad.get_board()
        return getattr(board, "filename", None) or getattr(board, "path", None)
    except Exception:
        return None


# ── First-run dialog ─────────────────────────────────────────────────────


def _tk_setup_dialog(initial: cfg_mod.BoardConfig) -> Optional[cfg_mod.BoardConfig]:
    """Tk-based setup form. Returns None if the user cancels.

    Only collects the server URL and the design name. OAuth credentials
    are minted automatically on first sync via dynamic client
    registration — the user just clicks Authorize in the browser."""
    try:
        import tkinter as tk
        from tkinter import ttk
    except ImportError:
        print("Tkinter is unavailable; configure the .eda-sync.json file manually.", file=sys.stderr)
        return None

    out: dict[str, str] = {}

    root = tk.Tk()
    root.title("EDA Sync — first-run setup")
    root.geometry("520x200")

    fields = [
        ("Server URL", "server_url", initial.server_url or "http://127.0.0.1:7050"),
        ("Design name", "design", initial.design),
    ]
    entries: dict[str, tk.Entry] = {}
    for i, (label, key, default) in enumerate(fields):
        ttk.Label(root, text=label).grid(row=i, column=0, sticky="e", padx=8, pady=4)
        e = ttk.Entry(root, width=50)
        e.insert(0, default)
        e.grid(row=i, column=1, padx=8, pady=4)
        entries[key] = e

    note = ttk.Label(
        root,
        text=(
            "On the next sync, your browser will open and ask you to sign in "
            "(if needed) and approve EDA Sync. No client_id or client_secret "
            "is required — they're minted automatically and cached locally."
        ),
        foreground="#555",
        wraplength=480,
        justify="left",
    )
    note.grid(row=len(fields), column=0, columnspan=2, padx=8, pady=8, sticky="w")

    cancelled = {"v": True}

    def on_ok():
        for k, e in entries.items():
            out[k] = e.get().strip()
        cancelled["v"] = False
        root.destroy()

    def on_cancel():
        root.destroy()

    btns = ttk.Frame(root)
    btns.grid(row=len(fields) + 1, column=0, columnspan=2, pady=10)
    ttk.Button(btns, text="Cancel", command=on_cancel).grid(row=0, column=0, padx=4)
    ttk.Button(btns, text="Save & sync", command=on_ok).grid(row=0, column=1, padx=4)

    root.mainloop()

    if cancelled["v"]:
        return None
    return cfg_mod.BoardConfig(
        server_url=out["server_url"],
        design=out["design"],
        last_synced_version=initial.last_synced_version,
    )


def _show_result(summary: sync_core.SyncSummary, version: int) -> None:
    title = "EDA Sync"
    body_lines = [
        f"Synced @ v{version}",
        "",
        f"Updated:  {len(summary.updated)}",
        f"Added:    {len(summary.added)}",
        f"Removed:  {len(summary.removed)}",
        f"Swapped:  {len(summary.swapped)}",
    ]
    if summary.flagged_stale:
        body_lines.append(f"Stale (kept): {', '.join(summary.flagged_stale)}")
    if summary.warnings:
        body_lines.append("")
        body_lines.append("Warnings:")
        body_lines.extend(f"  - {w}" for w in summary.warnings)
    body = "\n".join(body_lines)
    print(body)
    try:
        import tkinter as tk
        from tkinter import messagebox

        tk.Tk().withdraw()
        messagebox.showinfo(title, body)
    except Exception:
        pass


def _show_error(msg: str) -> None:
    print(f"EDA Sync error: {msg}", file=sys.stderr)
    try:
        import tkinter as tk
        from tkinter import messagebox

        tk.Tk().withdraw()
        messagebox.showerror("EDA Sync", msg)
    except Exception:
        pass


# ── Object cache → FootprintSource ───────────────────────────────────────


class _ManifestFootprintSource:
    """Resolves footprint name → cached .kicad_mod text using the manifest."""

    def __init__(self, manifest: Manifest, cache: ObjectCache):
        self._cache = cache
        self._by_name: dict[str, str] = {fp.name: fp.sha for fp in manifest.footprints}

    def get_kicad_mod(self, name: str) -> Optional[str]:
        sha = self._by_name.get(name)
        if not sha:
            return None
        return self._cache.get(sha).decode("utf-8", errors="replace")


# ── Main ─────────────────────────────────────────────────────────────────


def run(*, prune_stale: bool = False, board_path_override: Optional[str] = None) -> int:
    board_path = board_path_override or _resolve_board_path()
    if not board_path:
        _show_error(
            "Could not determine the open board's path. Open a .kicad_pcb in "
            "KiCad before running EDA Sync."
        )
        return 2

    cfg = cfg_mod.load(board_path)
    if not cfg.server_url or not cfg.design:
        new_cfg = _tk_setup_dialog(cfg)
        if new_cfg is None:
            return 1
        cfg = new_cfg
        cfg_mod.save(board_path, cfg)

    # Resolve OAuth credentials. Order of precedence:
    #   1. Per-server cache (~/.config/eda-kicad-sync/clients.json) populated
    #      by a previous dynamic registration on this machine.
    #   2. Legacy fields in BoardConfig (client_id/client_secret) — kept for
    #      configs minted before dynamic registration existed; migrated into
    #      the per-server cache and cleared from the board config.
    #   3. Dynamic client registration against /oauth/register (RFC 7591).
    client_store = oauth_client.ClientStore()
    client_rec = client_store.get(cfg.server_url)
    if client_rec is None and cfg.client_id and cfg.client_secret:
        # Migrate the legacy per-board credentials into the per-server cache.
        client_rec = oauth_client.ClientRecord(
            server_url=cfg.server_url.rstrip("/"),
            client_id=cfg.client_id,
            client_secret=cfg.client_secret,
        )
        client_store.put(client_rec)
        cfg.client_id = ""
        cfg.client_secret = ""
        cfg_mod.save(board_path, cfg)
    if client_rec is None:
        try:
            client_rec = oauth_client.register_client(cfg.server_url)
            client_store.put(client_rec)
        except Exception as e:
            _show_error(
                "Could not register an OAuth client with the server.\n\n"
                f"{e}\n\n"
                f"If your server is older and lacks /oauth/register, mint "
                f"a client manually at {cfg.server_url.rstrip('/')}/account "
                "and put the values in your .eda-sync.json file."
            )
            return 3

    try:
        token = oauth_client.ensure_token(cfg.server_url, client_rec.client_id, client_rec.client_secret)
    except Exception as e:
        _show_error(f"OAuth failed: {e}")
        return 3

    client = EdaClient(cfg.server_url, token.access_token)

    try:
        manifest = client.get_manifest(cfg.design)
    except PermissionError:
        # Token may have been revoked — force re-auth once.
        try:
            token = oauth_client.authorize(cfg.server_url, client_rec.client_id, client_rec.client_secret)
            oauth_client.TokenStore().put(token)
            client = EdaClient(cfg.server_url, token.access_token)
            manifest = client.get_manifest(cfg.design)
        except Exception as e:
            _show_error(f"Auth retry failed: {e}")
            return 3
    except Exception as e:
        _show_error(f"Manifest fetch failed: {e}")
        return 4

    cache_root = cfg_mod.cache_root(cfg.server_url, cfg.design)
    cache = ObjectCache(os.path.join(cache_root, "objects"))

    # Pull any footprint blobs we don't already have.
    for fp in manifest.footprints:
        if not cache.has(fp.sha):
            try:
                cache.put(fp.sha, client.get_object(fp.sha))
            except Exception as e:
                _show_error(f"failed to fetch footprint {fp.name}: {e}")
                return 5

    try:
        netlist_text, _etag = client.get_netlist(cfg.design)
    except Exception as e:
        _show_error(f"netlist fetch failed: {e}")
        return 6

    netlist = netlist_parser.parse(netlist_text)
    fp_source = _ManifestFootprintSource(manifest, cache)

    # Talk to KiCad now that we have all the inputs.
    try:
        from .kipy_adapter import KipyBoardAdapter, _is_no_board_open_error

        adapter = KipyBoardAdapter()
    except RuntimeError as e:
        # kipy_adapter already translated AS_UNHANDLED into a clear message.
        _show_error(str(e))
        return 7
    except Exception as e:
        if _is_no_board_open_error(e):
            from .kipy_adapter import _NO_BOARD_OPEN_MSG
            _show_error(_NO_BOARD_OPEN_MSG)
        else:
            _show_error(
                "Could not connect to KiCad's IPC API. Enable it under "
                f"Preferences → Plugins → IPC API and ensure a board is open.\n\n{e}"
            )
        return 7

    try:
        summary = sync_core.sync(
            adapter,
            netlist,
            fp_source,
            prune_stale=prune_stale,
            commit_message=f"EDA sync: {cfg.design} @ v{manifest.version}",
        )
    except Exception as e:
        _show_error(f"sync failed: {e}\n\n{traceback.format_exc()}")
        return 8

    cfg.last_synced_version = manifest.version
    cfg_mod.save(board_path, cfg)
    _show_result(summary, manifest.version)
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description="Sync the open KiCad PCB from an EDA design.")
    p.add_argument("--prune", action="store_true", help="Remove footprints whose canopy_uuid is no longer in the netlist.")
    p.add_argument("--board", help="Override the path of the .kicad_pcb to associate config with.")
    args = p.parse_args(argv)
    return run(prune_stale=args.prune, board_path_override=args.board)


if __name__ == "__main__":
    sys.exit(main())
