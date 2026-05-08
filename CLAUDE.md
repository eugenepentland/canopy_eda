# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A CLI-driven electronic design automation tool for schematic capture. All design files use S-expression syntax. A single Zig binary (`eda`) parses, evaluates, validates, renders, and serves designs.

## Build & Run

```bash
# Build
zig build

# Run tests (includes Guardian checks: fmt, spec, file-size, boundaries)
zig build test

# Start web server (default port 7050)
zig build run -- serve --project-dir projects/designs

# Build a design (stdout), --push sends to running server
zig build run -- build --project-dir projects/designs --push <design-name>

# Export KiCad netlist + footprints (handoff to KiCad's PCB editor)
zig build run -- export-kicad --project-dir projects/designs --output-dir <dir>

# Convert KiCad files
zig build run -- convert-footprint <file.kicad_mod>
zig build run -- convert-symbol <file.kicad_sym> [--filter <name>]
zig build run -- convert-package <sym.kicad_sym> <fp.kicad_mod> [--name <name>]
zig build run -- convert-pinout <file.kicad_sym>
```

## Build System

Dependencies: `httpz` (HTTP server), `guardian` (code quality checks).

Guardian runs automatically on every build and test:
- `fmt-check`: Zig formatting validation
- `spec`: Validates SPEC.md matches public function signatures
- `file-size`: Enforces file size limits
- `boundaries`: Structural checks

Use `zig build spec-init` to regenerate SPEC.md from `pub fn` signatures.

## Architecture

### Pipeline

```
Source (.sexp files)
    → Tokenizer → Parser → AST (nodes with source spans)
    → Evaluator (recursive eval with special forms, builtins, modules)
    → DesignBlock (instances, nets, ports, notes, sections, sub_blocks)
    → Post-build (ID insertion, BOM resolution, assertion checks)
    → Output:
        Schematic: render_html.zig → server-rendered HTML (hub-and-spoke SVG)
        Export: emit.zig (.sexp), export_kicad.zig (KiCad netlist + footprints + STEP models)
        Checks: erc.zig (electrical rules)
```

### Key Modules

**S-expression layer** (`src/sexpr/`): tokenizer → parser → AST. Printer is round-trip capable.

**Evaluator** (`src/eval/`): Split across multiple files:
- `evaluator.zig` — Main eval dispatcher
- `env.zig` — Core types: Value (union type), Env (lexical scope chain), DesignBlock, Instance, Net, Port
- `special_forms.zig` — `let`, `if`, `cond`, `fmt`, `assert`
- `modules.zig` — `import` (searches lib/components/ then lib/modules/), `defmodule` with closure capture
- `design_block.zig` — `design-block` evaluation
- `instance.zig` — Instance building + pin-net resolution
- `builders.zig` — Port, note, group, section builders
- `ids.zig` — 8-char hex ID generation, ref-des auto-assignment (prefix-based: C→C1, C2...)
- `builtins.zig` — Arithmetic, comparison, logic operators
- `fmt.zig` — String formatting (~V voltage, ~R resistance, ~C capacitance, ~A amperage, ~S string)

**Schematic rendering** (`src/render_html.zig` + `src/render_svg/`): Converts DesignBlock to an HTML page with inline SVG. Hub/spoke model: Hubs = ICs/connectors (U/J/P/X/Q prefix, rendered as boxes). Spokes = passives (R/C/L/F/D prefix, rendered inline on connections). Grid layout from sections. `src/render_json.zig` still emits a scene-graph JSON (`/api/scene-graph/:name`) used by the live-push pipeline. `src/render_system_svg.zig` + `src/render_block_types.zig` produce the system-overview SVG embedded in the page header (auto-categorised columns: mcu, power, memory, peripheral, connector, etc.).

**Checks**: `erc.zig` (duplicate ref-des, floating nets, unconnected pins, voltage mismatches, missing decoupling).

**Export**: `emit.zig` (flattened .sexp), `export_kicad.zig` + `export_kicad_netlist.zig` + `export_kicad_footprint.zig` + `export_kicad_model.zig` (KiCad netlist + footprints + STEP models — the bridge for handing schematic edits off to KiCad's PCB editor).

**Web server** (`src/serve.zig` + `src/serve/`): Serves the schematic viewer + review report. Live update via version polling. JSON scene graph state protected by mutex.

### Component System

- **component-family**: Parameterized (e.g., `(cap "100nF" "np0")`) — `is_family: true`
- **component**: Fixed part (e.g., `(res-0402)`)
- Both cached in `component_cache: StringHashMap(ComponentData)`
- Import searches `lib/components/` then `lib/modules/` for `.sexp` files

## Conventions

- **Error handling**: `EvalError` enum propagated via `try`/`catch`. No panics. File load failures degrade gracefully.
- **Memory**: Uses `page_allocator` globally. File contents are never freed (AST slices reference source buffers).
- **Spans**: Every AST Node carries `span: Span` (line, col, byte offset) — used for ID insertion and error reporting.
- **Test tags**: Tests use `// spec: Section - Behavior` comments mapping to SPEC.md entries.
- **Strings**: All `[]const u8` slices into source or allocated buffers. Equality via `std.mem.eql(u8, ...)`.

## S-Expression Design Language

### Instance with inline pin-net connections

```scheme
(instance "C1" (cap-0402 "100nF")
  (pin 1 "VDD")
  (pin 2 "GND"))

;; Multi-pin shorthand for same net
(instance "U1" stm32n657l0h3q
  (pin 1 2 3 4 5 "VDD")
  (pin 27 28 29 30 31 "GND"))
```

### Multi-part symbols with grid layout

```scheme
(instance "U1" stm32n657l0h3q
  (part "VDD Power" (row 0) (col 0)
    (pin 1 2 3 4 5 "VDD")
    (pin 27 28 29 30 31 "GND"))
  (part "USB" (row 3) (col 1)
    (pin 52 "USB_DP")
    (pin 53 "USB_DM")))
```

### Named grid sections

```scheme
(section "USB"          (row 3) (col 1))
(section "SMPS Power"   (row 0) (col 1))
```

### Hub grid positioning (non-part hubs)

```scheme
(instance "J2" amphenol-10164986
  (row 3) (col 1)
  (pin 1 12 13 24 "GND")
  (pin 4 9 16 21 "VBUS"))
```

### Parameterized modules

```scheme
(defmodule tpsm84338 (rfbt rfbb rled)
  (let vout (* 0.6 (+ 1.0 (/ rfbt rfbb))))
  (assert-range vout 0.6 16.0 "VOUT")
  (design-block (fmt "~V Buck" vout)
    (instance "U1" tpsm84338rcjr
      (pin 4 vout-str)
      ...)))

;; Usage
(sub-block "pwr" (tpsm84338 220000 47000 1000))
```

### Ports

```scheme
(port "VDD"  in  (rated 1.62 1.98))
(port "GND"  bidi)
;; Long form when net differs from name:
(port "VOUT" vout-str  out  (rated 0.6 16.0))
```

## Web Server

The production EDA server runs at **https://co-circuit.eugenepentland.dev** —
that's the canonical URL for the KiCad-sync agent and any remote MCP client.
Local dev still uses `http://localhost:7050`.

`eda serve` starts an HTTP server with the schematic viewer + review report:

- **Design list**: `GET /` — links to all .sexp designs
- **Schematic viewer**: `GET /schematics/:name` — server-rendered HTML schematic with embedded SVG
- **Review report**: `GET /review/:name` — HTML design-review doc (summary banner, power-budget table, per-section cards, BOM, assertions, unresolved issues). JSON form at `GET /api/review/:name` for programmatic use.
- **Scene graph**: `GET /api/scene-graph/:name` — JSON scene graph for schematic (used by the live-push pipeline)
- **Live push**: `POST /api/push/:name` — rebuild and push update
- **Version polling**: `GET /api/version/:name` — returns `{"version":N}`
- **Value editing**: `POST /api/edit-value/:name` — edit component value in .sexp file
- **ERC**: `GET /api/erc/:name` — electrical-rule violations
- **KiCad sync**: `POST /api/sync-plan/:name` — server-side diff for the local Go IPC agent (`tools/kicad-sync-go/`). The agent reads board state from KiCad over IPC, posts it here, and applies the returned ops in one commit so footprint placements and routing are preserved.
- **Library upload**: `GET /library`, `POST /api/upload-symbol`, `POST /api/upload-footprint`

### Live update workflow

```bash
# Terminal 1: start server (default port 7050)
eda serve --project-dir projects/designs

# Terminal 2: edit and push
vim projects/designs/src/stm32n6/stm32n6.sexp
eda build --project-dir projects/designs --push stm32n6
# Browser auto-updates within 500ms
```

### MCP server (Claude Code integration)

`eda serve` exposes an MCP server so Claude Code can pull schematics, edit
them (values, add/remove instances, rewire pins), and have the browser viewer
update live. Two transports:

- **`POST /mcp`** — streamable HTTP, the transport Claude Code's remote MCP
  connector uses. Claude Code authenticates via OAuth 2.0 (authorization code
  + PKCE).
- **`GET /mcp`** — WebSocket upgrade, for local testing and any stdio bridge.

Tools exposed: `list_designs`, `get_schematic`, `get_version`, `edit_value`,
`swap_component`, `add_component`, `remove_component`, `rewire_pin`,
`run_checks`, `generate_review`. Defined in `src/serve/mcp_tools.zig`; each
mutation tool calls a `…Core` function in `src/serve/edit.zig` and returns
the new `live_version`, so the browser picks up changes via its existing
2 s poll of `/api/version/:name`. `generate_review` is read-only and returns
the full review-doc JSON (matching `GET /api/review/:name`).

OAuth endpoints (implemented in `src/serve/oauth.zig`, store in
`src/serve/oauth_store.zig`):

- `GET /.well-known/oauth-authorization-server` (RFC 8414)
- `GET /.well-known/oauth-protected-resource` (RFC 9728)
- `GET /oauth/authorize` — consent page
- `POST /oauth/authorize/approve` — form POST from the consent page
- `POST /oauth/token` — authorization-code exchange

User-facing client management lives at `GET /account` — sign in with a
passkey, then mint an OAuth `client_id`/`client_secret` per Claude Code
install. Clients and access tokens are persisted to
`projects/designs/auth/oauth_clients.json` and `oauth_tokens.json` (secrets
are stored as SHA-256 hashes only). On `localhost`, the account page falls
back to a `dev@localhost` identity when no session exists, so local dev
works without a passkey setup.

```bash
# Connect from Claude Code:
claude mcp add --transport http eda http://localhost:7050/mcp \
  --client-id eda_c_... --client-secret eda_s_...
# Claude opens a browser for the authorize step.
```

## Testing

```bash
# Unit tests (also runs Guardian checks)
zig build test

# Build all designs
for d in pma3-14ln stm32n6 adf5901 tpsm84338 lt3045 power-6v; do
  zig build run -- build --project-dir projects/designs --push $d
done
```

## Worktrees

This repo routinely has several git worktrees in flight under `.claude/worktrees/` (one per feature branch). The directory is `.gitignore`d. A few rules keep them from colliding:

- **Keep the main worktree's tree clean.** If `git status` on main shows anything (uncommitted edits, staged deletions, untracked scratch files), deal with it *before* asking anything to merge branches — uncommitted state on main gets swept into auto-commits and can silently revert work from other branches. Lesson learned the hard way: a partial-revert sitting staged on main deleted the schematic sidebar when another branch was merged.
- **Commit WIP; don't leave it dangling.** Across-session work should land as a `WIP: ...` commit on the feature branch (fine to squash later), never as loose edits in a worktree. Stashes are invisible to automation and to a future you — prefer a commit.
- **Rebase worktree branches onto main weekly or before handoff.** Branches that drift more than a few commits behind main produce wide conflicts and, worse, context-line drift (e.g. a function call surviving a rebase after the function itself was deleted upstream). Small, frequent rebases keep the delta legible.
- **Before bulk-merging worktrees, inventory them.** Run `git status` in each worktree (a `git worktree list` + loop works well). Flag any uncommitted work and decide commit-vs-discard *per worktree* before anything touches main.
- **Retire merged worktrees.** `git worktree remove <path> && git branch -D <branch>` once a branch is in main. Fewer live worktrees = fewer places for drift to hide.
- **Audit `git stash list` periodically.** Stashes labelled against deleted branches are almost always forgotten work worth reviewing or dropping.
