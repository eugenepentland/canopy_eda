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

1. Open your `.kicad_pcb` in KiCad and click **EDA Sync**.
2. The setup dialog asks for **Server URL** and **Design** (a dropdown
   populated from `GET /api/designs`). The dialog title carries a build
   tag (e.g. `(v2-dyn-reg)`) — if you don't see one, your installed
   plugin is older than dynamic registration; reinstall (see Install).
3. Click **Save & sync**. A browser opens for OAuth approval; click
   *Authorize*. Credentials are minted automatically (RFC 7591 dynamic
   client registration) and cached at
   `~/.config/eda-kicad-sync/clients.json`. Tokens cache at
   `~/.config/eda-kicad-sync/tokens.json`. Per-board settings (server +
   design) live next to the .kicad_pcb as `<board>.eda-sync.json`.

### Updating an existing install

If you already pulled the new plugin code but the dialog still asks for
`client_id` / `client_secret`, you have an older copy installed
elsewhere. The dialog title shows the build tag; if it's missing or the
tag predates `v2-dyn-reg`, reinstall.

The action plugin spawns `python -m plugins.eda_sync_action` directly,
so the `plugins/` package just needs to be importable from the spawned
process's cwd (which is the kicad-sync-plugin directory). A `pip
install -e .` is **optional** — and on Windows it can fail with
`WinError 2` on the leftover `eda-kicad-sync.exe` from older versions.
If you hit that:

```powershell
# Clean leftovers from an older install (Windows)
Remove-Item C:\Python311\Scripts\eda-kicad-sync* -ErrorAction SilentlyContinue
pip uninstall -y eda-kicad-sync   # ok if it says "not installed"

# Then either reinstall (now safe — no .exe entry point):
pip install -e tools/kicad-sync-plugin
# …or skip pip entirely; the KiCad toolbar button works without it.
```

Then fully restart KiCad (close all windows, reopen). KiCad's action-
plugin discovery runs once at startup; a fresh start guarantees the new
`kicad_action_plugin/__init__.py` and the new `plugins/eda_sync_action.py`
are both loaded.

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
