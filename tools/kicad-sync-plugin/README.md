# EDA Sync — KiCad 10 IPC plugin

Sync the open `.kicad_pcb` from a Canopy EDA server. Replaces the older
server-side `pcb_update.py` flow that wrote board files on the server's
disk: this plugin runs locally inside KiCad, talks to the EDA server over
HTTP, and pushes the diff into the *open* board through the KiCad 10 IPC
API. Footprints are matched by stable `canopy_uuid` so placements and
routing are preserved.

## Requirements

- KiCad 10 with the IPC API enabled (Preferences → Plugins → IPC API).
- Python 3.9+.
- `kicad-python` (`kipy`) ≥ 0.4 — `pip install kicad-python`.

## Install

1. Copy this directory into KiCad's plugin folder, or use *Tools →
   External Plugins → Install From Folder*.
2. Restart KiCad. The toolbar gets an **EDA Sync** button.

## First-run setup

1. In the EDA web UI, sign in at `/account` and mint an OAuth client.
2. Set the registered **Redirect URI** to exactly:
   ```
   http://127.0.0.1:53682/callback
   ```
   The plugin binds that exact port; the server enforces strict equality.
3. Open your `.kicad_pcb` in KiCad and click **EDA Sync**.
4. Fill in: server URL (e.g. `http://localhost:7050`), design name,
   `client_id`, `client_secret`. Settings are stored next to the board
   as `<board>.eda-sync.json`.
5. A browser opens for the OAuth approval. Click *Approve*. The token
   caches at `~/.config/eda-kicad-sync/tokens.json` (mode 0600) and
   subsequent clicks sync silently.

## What each click does

1. `GET /api/sync-manifest/:design` — list of footprint + model SHAs.
2. `GET /api/object/:sha` — fetches any footprint blob not already in
   `~/.cache/eda-kicad-sync/<server>/<design>/objects/`.
3. `GET /api/netlist/:design` — netlist text (uses `If-None-Match` to
   skip the body when unchanged).
4. Indexes the open board's footprints by `canopy_uuid` field and walks
   the netlist:
   - Existing match → updates ref-des, value, footprint name (with
     position-preserving swap if needed), and pad → net assignments.
   - No match → drops a fresh footprint at `(0, 0)` for the user to
     place.
   - Stale `canopy_uuid` on board with no netlist counterpart → flagged
     in the result dialog; with `--prune` (or the dialog checkbox)
     they're removed.
5. Wrapped in one `board.push_commit(...)` so the user can undo as a
   single step.

## CLI

The plugin is also runnable outside KiCad (as long as KiCad is open and
the IPC socket is reachable):

```bash
python -m plugins.eda_sync_action --board /path/to/board.kicad_pcb [--prune]
```

## Tests

```bash
pip install pytest
python -m pytest tests/
```

The tests don't import `kipy` — `sync_core` talks to a `BoardAdapter`
protocol and the suite supplies a `FakeBoard` that records mutations.

## Layout

```
plugins/
  eda_sync_action.py   # Action entry + Tk setup dialog + result dialog
  sync_core.py         # Diff algorithm (testable, no kipy)
  kipy_adapter.py      # BoardAdapter implementation backed by kipy
  netlist_parser.py    # KiCad-netlist S-expression parser
  eda_client.py        # HTTP client + filesystem ObjectCache
  oauth_client.py      # OAuth auth-code+PKCE + loopback redirect
  config.py            # <board>.eda-sync.json read/write
tests/
  test_netlist_parser.py
  test_sync_core.py
metadata.json          # KiCad PCM plugin manifest
```

## Limitations (v1)

- New footprints land at `(0, 0)`. `pcb_update.py` does grid placement
  using `sections.json` / `modules.json`; v2 can add an
  `/api/sections/:name` endpoint and port the layout heuristics.
- 3D models are listed in the manifest but not fetched.
- Decoupling-cap snapping and module replication from `pcb_update.py`
  are intentionally not ported.
- Sync is click-driven only — no continuous-poll mode.
