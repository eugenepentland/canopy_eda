# EDA Sync — Go agent for KiCad 10

Single-binary local agent that syncs the open `.kicad_pcb` from a Canopy
EDA design.

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

The plugin is a tiny Python `pcbnew.ActionPlugin` shim
(`kicad_plugin/__init__.py`) that just spawns the Go binary, so KiCad
discovers it via its standard "External Plugins" menu. KiCad's user
plugin path varies by OS:

- Linux: `~/.config/kicad/10.0/scripting/plugins/eda-sync/`
- macOS: `~/Library/Preferences/kicad/10.0/scripting/plugins/eda-sync/`
- Windows: `%USERPROFILE%\Documents\KiCad\10.0\scripting\plugins\eda-sync\` (manual)

You install by symlinking the `kicad_plugin/` subfolder of this repo
into the KiCad plugins path above. The Go binary lives one level up
(in `tools/kicad-sync-go/`), so the shim resolves it via `..`.

**Windows (PowerShell):**
```powershell
$dst = "$env:USERPROFILE\Documents\KiCad\10.0\scripting\plugins\eda-sync"
cd C:\Users\you\Code\canvas_eda\tools\kicad-sync-go
New-Item -ItemType SymbolicLink -Path $dst -Target "$((Get-Location).Path)\kicad_plugin"
```

### Build from source (one-time codegen)

The agent depends on Go bindings generated from KiCad's protobuf API
definitions. The `internal/kicad/proto/` directory ships empty; running
the codegen script populates it. You only need to run this once per
upstream KiCad protocol bump.

You'll need:

- **protoc** on PATH ([releases](https://github.com/protocolbuffers/protobuf/releases))
- **protoc-gen-go**: `go install google.golang.org/protobuf/cmd/protoc-gen-go@latest`
  (puts `protoc-gen-go` in `$(go env GOPATH)/bin` — make sure that's on PATH)
- A clone of KiCad's source tree

**Linux / macOS:**
```bash
git clone --depth 1 https://gitlab.com/kicad/code/kicad ~/src/kicad
KICAD_SRC=~/src/kicad make proto
make build
```

**Windows (PowerShell):**
```powershell
git clone --depth 1 https://gitlab.com/kicad/code/kicad C:\Users\you\Code\kicad-src
$env:KICAD_SRC = "C:\Users\you\Code\kicad-src"
.\scripts\gen-proto.ps1
go build -o eda-kicad-sync.exe .\cmd\eda-kicad-sync
```

(PowerShell uses `$env:VAR = "..."` per-line — `VAR=value command`
inline syntax is bash-only. You can also run `gen-proto.sh` from Git
Bash if you'd rather: `KICAD_SRC=/c/Users/you/Code/kicad-src ./scripts/gen-proto.sh`.)

## First-run setup

1. Open a `.kicad_pcb` in KiCad.
2. Click **EDA Sync** in the toolbar (or **Tools → External Plugins →
   EDA Sync — Setup**).
3. The agent opens a setup page in your browser. Fill in the server URL
   and design name; submit.
4. The agent registers itself with the server (RFC 7591 dynamic client
   registration) — no manual client_id/secret needed.
5. Browser redirects to the OAuth approve page. Sign in if prompted, then
   click **Approve**. The minted client is bound to your account so you
   can revoke it later from `<server>/account`.
6. Click **EDA Sync** again to run the first sync.

Per-board config lives at `<board>.eda-sync.json` next to the PCB and
holds only `server_url` + `design`. The minted OAuth client is shared
across all boards talking to the same server and is cached in
`~/.config/eda-kicad-sync/clients.json`. Access tokens live in
`~/.config/eda-kicad-sync/tokens.json` (both mode 0600).

> Older configs that already contain `client_id`/`client_secret` keep
> working — those values take precedence over auto-registration so a
> previously-minted client isn't replaced silently.

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
  setup/     loopback setup web page (embedded HTML, OS-assigned port)
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

## Troubleshooting

- **`KICAD_API_SOCKET is not set`** — run from KiCad's plugin button,
  or export `KICAD_API_SOCKET` and `KICAD_API_TOKEN` manually for CLI use.
- **`protobuf wire format not generated yet`** — run `make proto` (see
  "Build from source" above). The error message is intentional in builds
  shipped without generated bindings.
- **`server rejected token (401)`** — server doesn't have the
  `/api/sync-plan/:name` endpoint, or the cached OAuth client was deleted
  on the server. Delete `~/.config/eda-kicad-sync/clients.json` to force
  a fresh registration on the next click.
- **`server doesn't advertise a registration_endpoint`** — server is
  running an older build that predates RFC 7591 support. Either upgrade
  the server, or mint a client manually at `<server>/account` and paste
  `client_id`/`client_secret` into `<board>.eda-sync.json` by hand.
- **OAuth callback timeout** — port 53682 is taken by another process
  (VS Code and similar dev tools randomly grab dynamic ports in this
  range). Stop the conflicting one and retry.
