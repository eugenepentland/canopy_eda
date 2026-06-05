# KiCad Sync — setup

How to install the Go agent that syncs an open `.kicad_pcb` against a
Netlisp design. This is the operator-facing setup guide; for the
design contract see [`kicad-sync-architecture.md`](kicad-sync-architecture.md),
and for module-level detail see [`tools/kicad-sync-go/README.md`](../tools/kicad-sync-go/README.md).

## What this tool does

`eda-kicad-sync` is a single Go binary that lives on your machine and
relays footprint changes between KiCad 10 (over its IPC API) and the
EDA server (over HTTPS + OAuth). The diff algorithm runs on the server,
so updates ship to every user the next time they click the toolbar
button — no client redeploy.

Use it when you've edited a `.sexp` design and want the matching
`.kicad_pcb` updated without throwing away the layout work (placements,
routing, copper pours) you've already done.

## Prerequisites

- **KiCad 10**, with the IPC API enabled (Preferences → Plugins → check
  *Enable Plugin and Content Manager* and *Enable PCM API*). Older
  KiCad versions don't expose the protobuf IPC surface this tool needs.
- **Go 1.23+** on PATH, with `$(go env GOBIN)` (defaults to `~/go/bin`)
  also on PATH so the installed binary is callable.
- **An account on the EDA server** you want to sync against. The
  canonical production server is `https://co-circuit.eugenepentland.dev`;
  point at a local dev instance (default `http://localhost:7050`) for
  testing.

No `protoc`, no Python, no `kipy` — the generated protobuf bindings are
committed inside the Go module, and the KiCad plugin manifest invokes
the binary directly with zero scripting glue.

## Install

The recommended path is `go install`:

```bash
go install github.com/eugenepentland/netlisp/tools/kicad-sync-go/cmd/eda-kicad-sync@latest
eda-kicad-sync --install-kicad-plugin
```

The first command drops the binary into `$(go env GOBIN)`. The second
writes the KiCad plugin manifest (`plugin.json`) into KiCad's per-user
plugin folder and symlinks the binary alongside it. Restart KiCad and
the PCB editor gains an **EDA Sync** toolbar button.

Default install destinations:

| OS      | Path                                                                       |
|---------|----------------------------------------------------------------------------|
| Linux   | `~/.local/share/kicad/10.0/3rdparty/plugins/eda-sync/`                     |
| macOS   | `~/Library/Preferences/kicad/10.0/3rdparty/plugins/eda-sync/`              |
| Windows | `%USERPROFILE%\Documents\KiCad\10.0\3rdparty\plugins\eda-sync\`            |

On Linux/macOS the binary is symlinked; on Windows it's copied (non-admin
symlinks are flaky). Override the destination with `EDA_KICAD_PLUGIN_DIR`
for non-standard layouts (Flatpak, custom `XDG_DATA_HOME`, etc.):

```bash
EDA_KICAD_PLUGIN_DIR=~/.var/app/org.kicad.KiCad/data/kicad/10.0/3rdparty/plugins/eda-sync \
  eda-kicad-sync --install-kicad-plugin
```

To upgrade later, re-run `go install …@latest`. The plugin folder
symlinks back into `$GOBIN`, so KiCad picks up the new binary on its
next launch with no second install step. (Windows users need to re-run
`--install-kicad-plugin` to refresh the copied binary.)

### Building from source

When iterating on the agent itself:

```bash
git clone https://github.com/eugenepentland/netlisp
cd netlisp/tools/kicad-sync-go
make install
```

`make install` symlinks the *entire* working tree into KiCad's plugin
folder, so `git pull` updates the plugin in place. Use this for any
contributor work; end users should stick with `go install`.

## First-run setup

1. Open a `.kicad_pcb` in KiCad.
2. Click **EDA Sync** in the toolbar (or **Tools → External Plugins →
   EDA Sync — Setup**).
3. A setup page opens in your browser. Enter the server URL (e.g.
   `https://co-circuit.eugenepentland.dev`) and the design name (the
   `.sexp` filename without extension, e.g. `power-6v`). Submit.
4. The agent registers itself with the server using RFC 7591 dynamic
   client registration — no manual `client_id`/`client_secret` to copy
   around.
5. The browser redirects to the server's OAuth approve page. Sign in
   with a passkey if prompted, then click **Approve**. The minted
   client is bound to your account; revoke it any time at
   `<server>/account`.
6. Click **EDA Sync** again to run the first sync.

Where state lives:

| File                                                 | Contents                                          |
|------------------------------------------------------|---------------------------------------------------|
| `<board>.eda-sync.json` (next to the PCB)            | `server_url` + `design` only                      |
| `~/.config/eda-kicad-sync/clients.json` (mode 0600)  | Minted OAuth clients, shared across boards        |
| `~/.config/eda-kicad-sync/tokens.json` (mode 0600)   | Cached access tokens                              |

Legacy configs that already contain `client_id`/`client_secret` keep
working — those values take precedence over auto-registration so a
previously-minted client isn't silently replaced.

## Per-sync workflow

Click the **EDA Sync** toolbar button. The agent:

1. Reads board state from KiCad over IPC.
2. POSTs that state to `/api/sync-plan/<design>` on the server.
3. Receives an op list (`add`, `set_field`, `set_pad_net`,
   `swap_footprint`, `remove`, `flag_stale`).
4. Applies every op to KiCad in **one IPC commit** — a single Ctrl+Z
   reverts the entire sync.
5. Shows a desktop toast with the result.

Stale footprints (UUIDs no longer in the netlist) are flagged in the
toast rather than removed automatically. To prune them in one shot:

```bash
eda-kicad-sync --board /path/to/board.kicad_pcb --prune
```

The toolbar button deliberately doesn't expose `--prune` — board
deletions are easier to do wrong than to undo.

## Running headlessly (CI / regression checks)

Useful for verifying that a refactor doesn't move the board — e.g.
after the `(bus-net …)`/`(bus-port …)` rewrites that should produce
zero netlist-driven ops.

```bash
# 1. Headless X display
Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
export DISPLAY=:99

# 2. Launch pcbnew DIRECTLY on the .kicad_pcb. Do NOT launch the project
#    manager (`kicad …kicad_pro`) and spawn a sibling pcbnew — that
#    leaves the IPC API in AS_NOT_READY because the IPC handlers
#    register to whichever process owns /tmp/kicad/api.sock first.
nohup pcbnew "/path/to/Board.kicad_pcb" >/tmp/pcbnew.log 2>&1 &
until ! xwininfo -root -tree 2>&1 | grep -q "Load PCB"; do sleep 2; done

# 3. Point the agent at the live KiCad and dry-run
export KICAD_API_SOCKET=/tmp/kicad/api.sock
~/go/bin/eda-kicad-sync --dry-run --board "/path/to/Board.kicad_pcb"

# 4. Cleanup — pcbnew's lock files survive kill -9; remove them
pkill pcbnew Xvfb
rm -f /tmp/kicad/api.sock /tmp/kicad/api.lock
rm -f "/path/to/~Board.kicad_pcb.lck" "/path/to/~Board.kicad_pro.lck"
```

If the project is currently open by another user/machine, the `.lck`
file holds `{"hostname": …, "username": …}` — only remove it after
confirming the other session is genuinely gone. Concurrent saves
corrupt the board.

## Troubleshooting

| Symptom                                              | Cause / fix                                                                                                                                                                                                |
|------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `KICAD_API_SOCKET is not set`                        | Run from KiCad's plugin button (it sets this automatically), or export `KICAD_API_SOCKET` and `KICAD_API_TOKEN` manually for CLI use.                                                                      |
| `server rejected token (401)`                        | The server is missing `/api/sync-plan/:name`, or the cached OAuth client was deleted server-side. Delete `~/.config/eda-kicad-sync/clients.json` to force fresh registration on the next click.            |
| `server doesn't advertise a registration_endpoint`   | Server predates RFC 7591 dynamic registration. Either upgrade the server or mint a client manually at `<server>/account` and paste `client_id`/`client_secret` into `<board>.eda-sync.json`.               |
| OAuth callback timeout                               | Port 53682 (the loopback redirect target) is taken by another dev tool — VS Code in particular grabs random dynamic ports. Stop the conflicting process and retry.                                         |
| `protobuf wire format not generated yet`             | You're a contributor who deleted `internal/kicad/proto/`. Run `make proto` (needs `protoc` + `KICAD_SRC` pointing at a KiCad clone). End-user `go install` builds already include the bindings.            |
| Sync produces unexpected ops                         | The diff lives on the *server*, not the agent. Capture the agent's POST body and the server's response from `/tmp/eda-kicad-sync.log` (or pass `--verbose`) and file against the server, not the agent.    |

## See also

- [`kicad-sync-architecture.md`](kicad-sync-architecture.md) — design
  contract, op types, wire-stable board-state shape.
- [`tools/kicad-sync-go/README.md`](../tools/kicad-sync-go/README.md) —
  in-tree reference covering module layout, protobuf regeneration, and
  the orchestrator test harness.
- [`architecture.md`](architecture.md) §"KiCad handoff" — where the
  sync fits into the broader EDA pipeline.
