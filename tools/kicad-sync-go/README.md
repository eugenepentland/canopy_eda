# EDA Sync — Go agent for KiCad 10

Single-binary local agent that syncs the open `.kicad_pcb` from a Canopy
EDA design. Replaces the Python plugin under `../kicad-sync-plugin/`:

- **All sync logic lives on the EDA server** (`POST /api/sync-plan/:name`).
  Updates ship to every user on the next click — no client redeploy.
- **Local agent talks to KiCad over the IPC API** (NNG REQ/REP +
  protobuf). No `pcbnew` Python, no `kipy` install.
- **Registers as a native KiCad 10 plugin** via `plugin.json` — toolbar
  button, no Python at all.

## Architecture

```
┌─────────────────┐    HTTPS+OAuth    ┌────────────────────┐
│  EDA server     │◄─────────────────►│ User's PC          │
│  /api/sync-plan │                   │  ┌──────────────┐  │
│  (Zig)          │                   │  │ eda-kicad-   │  │
│                 │                   │  │ sync (Go bin)│  │
└─────────────────┘                   │  └──────┬───────┘  │
                                      │         │ NNG IPC  │
                                      │  ┌──────▼───────┐  │
                                      │  │ KiCad 10     │  │
                                      │  └──────────────┘  │
                                      └────────────────────┘
```

The agent is the only thing on the user's machine. The EDA server owns
the diff algorithm.

## Install

### From source

```bash
# Clone the repo, then:
cd tools/kicad-sync-go
make install                    # builds + symlinks into KiCad's plugin folder
```

After `make install`, restart KiCad. The PCB editor gets an **EDA Sync**
toolbar button + **Tools → External Plugins → EDA Sync** menu item.

KiCad's user plugin path varies by OS (the Makefile auto-detects):

- Linux: `~/.local/share/kicad/10.0/3rdparty/plugins/eda-sync/`
- macOS: `~/Library/Preferences/kicad/10.0/3rdparty/plugins/eda-sync/`
- Windows: `%APPDATA%\kicad\10.0\3rdparty\plugins\eda-sync\` (manual)

### Build from source (one-time codegen)

The agent depends on Go bindings generated from KiCad's protobuf API
definitions. The `internal/kicad/proto/` directory ships empty; running
`make proto` populates it. You only need to run this once per upstream
KiCad protocol bump.

```bash
git clone --depth 1 https://gitlab.com/kicad/code/kicad ~/src/kicad
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
KICAD_SRC=~/src/kicad make proto
make build
```

## First-run setup

1. Mint an OAuth client at `<server>/account` with redirect URI exactly
   `http://127.0.0.1:53682/callback`.
2. Open a `.kicad_pcb` in KiCad.
3. Click **EDA Sync** in the toolbar (or **Tools → External Plugins →
   EDA Sync — Setup**).
4. The agent opens `http://127.0.0.1:53683/setup` in your browser. Fill
   in server URL, design name, OAuth client ID/secret. Submit.
5. Browser redirects to the OAuth approve page. Click **Approve**.
6. Click **EDA Sync** again to run the first sync.

Per-board config lives at `<board>.eda-sync.json` next to the PCB.
Tokens are cached in `~/.config/eda-kicad-sync/tokens.json` (mode 0600).

## Per-sync workflow

Click the button. The agent:

1. Reads board state from KiCad via IPC.
2. POSTs to `/api/sync-plan/<design>` with the board state.
3. Receives a list of ops (add / set_field / set_pad_net /
   swap_footprint / remove / flag_stale).
4. Applies ops to KiCad in one IPC commit. Single Ctrl+Z reverts the
   whole sync.
5. Shows a desktop notification with the result.

To prune stale footprints (UUIDs no longer in the netlist):

```bash
./eda-kicad-sync --board /path/to/board.kicad_pcb --prune
```

The toolbar button doesn't expose `--prune` — by default stale entries
are flagged in the result toast so you can review before pruning.

## Module layout

```
cmd/eda-kicad-sync/main.go       entry: env → mode dispatch
internal/
  config/    per-board config + token cache
  eda/       HTTP client to /api/sync-plan
  oauth/     auth-code+PKCE + 127.0.0.1:53682 loopback
  setup/     127.0.0.1:53683 setup web page (embedded HTML)
  kicad/     IPC client (NNG REQ/REP + protobuf)
    types.go     neutral Footprint/Pad types
    iface.go     Client interface
    client.go    real impl (depends on internal/kicad/proto/)
    fake.go      in-process fake for tests
  sync/      orchestrator: read board → POST → apply ops
  notify/    desktop toast helper
plugin.json  KiCad 10 plugin manifest
scripts/gen-proto.sh   protoc invocation for KiCad protos
Makefile     build / install / proto / test / cross
```

## Testing

```bash
make test
```

The orchestrator test uses `httptest.NewServer` for the EDA HTTP side
and `kicad.Fake` for the IPC side, so it runs without KiCad or the
generated protos. Coverage: pure update, footprint swap, add at origin,
prune, flag_stale, empty plan.

## Co-existence with the Python plugin

The Python plugin in `../kicad-sync-plugin/` keeps working. It uses the
read endpoints (`/api/sync-manifest`, `/api/netlist`, `/api/object`);
the Go agent uses `/api/sync-plan`. They don't conflict. Once the Go
path covers the full v1 surface and you've used it for a bit, delete
`../kicad-sync-plugin/`.

## Troubleshooting

- **`KICAD_API_SOCKET is not set`** — run from KiCad's plugin button,
  or export `KICAD_API_SOCKET` and `KICAD_API_TOKEN` manually for CLI use.
- **`protobuf wire format not generated yet`** — run `make proto` (see
  "Build from source" above). The error message is intentional in builds
  shipped without generated bindings.
- **`server rejected token (401)`** — server doesn't have the
  `/api/sync-plan/:name` endpoint, or your OAuth client/secret is wrong.
  Confirm the server is running a build at or after the commit that
  added `POST /api/sync-plan/:name`.
- **Setup page never opens** — port 53683 is already in use by another
  process. Stop the conflicting one and retry.
- **OAuth callback timeout** — the registered redirect_uri at
  `<server>/account` doesn't match `http://127.0.0.1:53682/callback`
  exactly.
