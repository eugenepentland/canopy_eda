# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A CLI-driven electronic design automation tool for schematic capture. All design files use S-expression syntax. A single Zig binary (`netlisp`) parses, evaluates, validates, renders, and serves designs.

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
(section "USB" "USB 2.0 HS via USB-C — chip details sealed in usb-c-hs module"
  (row 3) (col 1)
  ...)
(section "3.3V Buck" "TPS62823 12V-to-3.3V, 2A"
  (row 0) (col 1)
  ...)
```

**When to create a section.** A design file reads as a wiring harness:
the main IC sits at the center, and each `(section …)` is one *functional
subsystem* hanging off it. `stm32n6.sexp` is the reference — work through
these four cases to decide whether something becomes a section:

1. **Peripheral with a distinct main-IC pin interface** (a bus, a clutch
   of GPIO control lines, dedicated clock pins). Make a section. Inside
   it, declare the main-IC-side mapping with `(pins "<ic>" (group "…")
   (pin …) …)`, plus `(role …)`, `(protocol …)`, and `(note …)` entries
   for firmware contracts and datasheet rationale. The peripheral's own
   pin-level implementation is sealed in a `(defmodule …)` under
   `lib/modules/` and brought in as a `(sub-block …)` — see the ERC
   `main_ic_in_design` check. **Structural constraint:** `(sub-block …)`
   forms are *not* evaluated inside `(section …)`; place the sub-block at
   design-block top level immediately after its section (e.g. `(section
   "USB" …)` then `(sub-block "usb" (usb-c-hs))`).
2. **Self-contained hardware with no main-IC interface** — test points,
   mounting standoffs, fiducials. Make a section that directly
   `(instance …)`s the parts; there is no pin map and no sub-block.
3. **The main IC's own support infrastructure** — power rails, boot/reset,
   on-chip clocks, debug. This is *one* section ("… Core System"),
   subdivided with `(pins "<ic>" (group "VDD Power") …)`, `(group "Boot &
   Reset")`, `(group "SWD Debug")`, etc. Crystals and the debug header are
   simple enough to `(instance …)` directly inside this section alongside
   their `(decouple …)` / `(series …)` passives.
4. **Power-delivery blocks that only produce rails** — battery, charger,
   buck, LDO, voltage references. These get *no* section. Declare them as
   top-level `(sub-block …)`s and wire them with consolidated `(net …)`
   forms (one `(net …)` per rail so the validator doesn't flag a rail as
   split across sections). They surface in the system-overview diagram as
   their own synthetic chips.

One section per coherent subsystem — don't merge unrelated functions, and
don't split one subsystem (or one rail) across two sections. Section
bodies may also carry `(port …)` boundary declarations, `(calc …)` design
math, and `(bus …)` multi-bit shorthand; see `stm32n6.sexp` for each.

**Section-labeling conventions.** Every section has a *name* (short
functional role) and an optional *subtitle* (one-line technical summary).
Both feed the schematic header's system-overview SVG: the renderer in
`src/render_block_types.zig` `classifyByName` does case-insensitive keyword
matching on the **name** to pick the section's column + color, then prints
the **subtitle** as the chip caption.

- **Name** — 1–4 words, capitalized, functional role first. The classifier
  recognizes these keywords (see `classifyByName`); pick at least one so
  the chip lands in the right column instead of falling through to the
  generic peripheral bucket:
  - **mcu** (blue, hub column): `MCU`, `SoC`, `CPU`, `Core System`,
    `STM32`, `ESP32`, `nRF`, `Microcontroller`
  - **power** (red, regulation column): `Buck`, `LDO`, `Regulator`,
    `Power`, `Charger`, `Converter`, `PMIC`
  - **memory** (purple): `Flash`, `PSRAM`, `RAM`, `EEPROM`, `SD Card`
  - **clock** (teal): `Clock`, `HSE`, `LSE`, `Oscillator`, `PLL`,
    `Crystal`
  - **comms** (cyan): `USB`, `Ethernet`, `BLE`, `WiFi`, `CAN`, `UART`
  - **sensor** (green): `IMU`, `ADC`, `Sensor`, `Temperature`,
    `Accelerometer`, `Gyro`
  - **analog** (magenta): `Analog`, `DAC`, `Op-Amp`, `Reference`,
    `Amplifier`
  - **protection** (grey): `ESD`, `Protection`, `Fuse`, `TVS`
  - **connector** (yellow, I/O column): `Connector`, `Expansion`,
    `Header`, `Mounting`, `SWD`, `Debug`, `RJ45`, `B2B`
- **Subtitle** — one-line technical summary: part number, key spec
  (voltage / frequency / current), and any "chip details sealed in
  `<module>` module" pointer for sub-blocks. This is the caption that
  shows up under the chip in the overview, so prefer concrete numbers
  ("12V-to-3.3V, 2A") over generic phrases ("buck regulator").
- **Granularity** — one section per coherent functional block (a single
  rail, a peripheral, a debug interface). Don't merge unrelated functions
  into one section; don't split a single rail across two sections. For
  designs whose body is mostly `(sub-block …)` calls (e.g. power-6v.sexp,
  the small RF demos), a top-level `(section …)` per sub-block is
  optional — the system-overview SVG falls back to a synthetic per-design
  chip when none are declared.
- **Grid placement** — `(row N) (col N)` positions the section card in
  the schematic page. Convention used in `stm32n6.sexp` and
  `som-h563.sexp`: MCU/core in column 0, peripherals + buses in column 1,
  power rails stacked in column 0–1 at the top, connectors and
  bring-up/debug in the rightmost column.

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

### Sub-block identity: legacy sidecar vs. hierarchical (opt-in)

Every part needs a stable `id` (→ `uuidFromId` → KiCad footprint) that survives
ref-des renumbering. For parts *inside* a `(sub-block …)` there are two schemes:

- **Legacy (default).** Each `(sub-block …)` carries an enumerated `(ids ("U1"
  …) ("C106" …) …)` sidecar — one frozen entry per child, keyed on the
  seed-time ref-des, written at the call site. Verbose (N×M entries for a module
  used N times with M parts) and the key drifts if a part renumbers because of
  an edit upstream of the sub-block. This is what `stm32n6.sexp` uses; it stays
  the default so already-adopted boards never churn.

- **Hierarchical (opt-in, "Option 4").** Add `(hierarchical-ids)` to the
  design-block body. Then each `(sub-block …)` gets **one** uuid (auto-minted
  into the design file on first build), and every child's id is
  `deriveChildId(subblock_uuid, child.origin_key)`, where `origin_key` is the
  child's stable *module-local* key (the source name for named instances, the
  `value@pin#index` / `value#index` structural key for `decouple`/`series`
  children). Both inputs are renumber-proof, so child ids survive sub-block
  renames *and* global renumbers. The module stays a clean, un-annotated
  template; storage scales as N+M (one uuid per call + the module written once).
  Mirrors KiCad's hierarchical-sheet path identity. See `src/adcarray/`.

```scheme
(design-block "ADC Array"
  (hierarchical-ids)                 ;; opt in — all sub-blocks below use it
  (sub-block "adc1" (ad7380-channel 1))   ;; (id …) auto-minted on first build
  (sub-block "adc2" (ad7380-channel 2))
  (sub-block "adc3" (ad7380-channel 3)))
```

The two schemes coexist per-design. Switching an existing design to
`(hierarchical-ids)` changes its child ids (different derivation), so it is a
one-time board re-stamp — adopt deliberately, not casually.

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

`netlisp serve` starts an HTTP server with the schematic viewer + review report:

- **Design list**: `GET /` — links to all .sexp designs
- **Schematic viewer**: `GET /schematics/:name` — server-rendered HTML schematic with embedded SVG
- **Review report**: `GET /review/:name` — HTML design-review doc (summary banner, power-budget table, per-section cards, BOM, assertions, unresolved issues). JSON form at `GET /api/review/:name` for programmatic use.
- **Scene graph**: `GET /api/scene-graph/:name` — JSON scene graph for schematic (used by the live-push pipeline)
- **PCB layout PNG**: `GET /api/pcb-png/:name` — server-rendered PNG of the force-directed PCB layout, so an AI agent (or any HTTP client) can *see* the board, not just parse the placement JSON. Mirrors the browser viewer's colours/projection (`src/render_pcb_png.zig` rasterizes onto `src/raster.zig`'s software canvas, encoded by `src/png.zig` — pure-Zig, no image dependency). Query: `?nets=A,B` / `?refs=U1,C3` enter *focus mode* (spotlight those nets/components in amber, dim the rest — `refs` match the bare leaf of a sub-block-prefixed ref); `?route=1` overlays routed copper + DRC markers; `?names=ref|origin|both` picks part labels (default: `origin` — the module-local names a `(placement …)` spec is written in — whenever a spec drives the solve, `ref` otherwise); `?pins=U13,C5` (or `pins=hubs`) labels those parts' pads with net names; when a spec drives the solve, the header shows its coverage (`SPEC: ALL PLACED` / `N UNPLACED` / `FELL BACK TO AUTO`) and spec-unlisted parts are hatched red in the staging band; `?width=`, `?layout=<saved>`, `?regen=1`, `?sub=<slug>`. Read-only; reuses the design's auto-layout cache.
- **PCB layout facts**: `GET /api/pcb-describe/:name` — structured spatial facts about the solved placement (`src/serve/pcb_describe.zig`), the textual twin of the PNG: built from the identical placement-selection logic and accepting the same query parameters, so the facts always describe the board the image shows. Returns JSON with the axes convention (y grows down; "top" = −y, matching `(placement …)` spec words), the anchor (largest hub IC), per-part `ref`/`origin`/side-of-anchor/`gap_mm`/nets/`unplaced`, per-decoupling-loop net + power-leg mm + nH + side, each hub's net→package-edge pad map, spec coverage, and (with `?route=1`) `routed:{trace_mm,tracks,vias,drc}`. Agents should read measurements here and use the PNG for gestalt.
- **Live push**: `POST /api/push/:name` — rebuild and push update
- **Version polling**: `GET /api/version/:name` — returns `{"version":N}`
- **Value editing**: `POST /api/edit-value/:name` — edit component value in .sexp file
- **ERC**: `GET /api/erc/:name` — electrical-rule violations
- **KiCad sync**: `POST /api/sync-kicad-pcb/:name` — file-based sync. Reads the `.kicad_pcb` declared by the design's `(kicad-pcb "<path>")` form, diffs it against the flattened netlist, and writes the updated board in place so footprint placements and routing are preserved. Driven by the schematic viewer's "Push to KiCad PCB" button. (`?dry_run=1` / `?migrate=1` / `?prune=1` modifiers.)
- **Library upload**: `GET /library`, `POST /api/upload-symbol`, `POST /api/upload-footprint`

### Live update workflow

```bash
# Terminal 1: start server (default port 7050)
netlisp serve --project-dir projects/designs

# Terminal 2: edit and push
vim projects/designs/src/stm32n6/stm32n6.sexp
netlisp build --project-dir projects/designs --push stm32n6
# Browser auto-updates within 500ms
```

### Verifying source changes don't move the board (dry-run sync)

After a refactor like the `(bus-net …)` / `(bus-port …)` rewrites, confirm
the change produces zero netlist-driven ops by hitting the file-based sync
in dry-run mode — no KiCad, Xvfb, or IPC agent needed. It reads the
`.kicad_pcb` at the design's `(kicad-pcb "<path>")` form, diffs against the
flattened netlist, and returns the op list without writing:

```bash
# Server running on :7050 with the design loaded
curl -s -X POST "http://localhost:7050/api/sync-kicad-pcb/<design>?dry_run=1" \
  | python3 -m json.tool
# "summary" all-zero (updated/added/removed/swapped) ⇒ the source change
# is netlist-neutral and won't move or re-stamp anything on the board.
```

The board file is on the NAS at
`/mnt/nas/Cyclops/Cyclops Digital/Cyclops Digital.kicad_pcb`. If the project
is open elsewhere, KiCad's lock file holds `{"hostname": …, "username": …}` —
concurrent saves corrupt the board, so only touch it when no other session
is live.

### MCP server (Claude Code integration)

`netlisp serve` exposes an MCP server so Claude Code can pull schematics, edit
the underlying `.sexp` files, and have the browser viewer update live. Two
transports:

- **`POST /mcp`** — streamable HTTP, the transport Claude Code's remote MCP
  connector uses. Claude Code authenticates via OAuth 2.0 (authorization code
  + PKCE).
- **`GET /mcp`** — WebSocket upgrade, for local testing and any stdio bridge.

Tools exposed (defined in `src/serve/mcp_tools.zig`):

- **Project / introspection (read-only)**: `list_designs`, `list_library`,
  `list_history`, `list_instances`, `list_free_pins`, `get_net`,
  `describe_component`, `get_schematic`, `get_pcb_layout_image`, `get_version`,
  `run_checks`, `generate_review`. `get_pcb_layout_image` returns the PCB layout
  as a PNG **image content block** (same renderer as `GET /api/pcb-png/:name`) so
  an agent can visually inspect placement; args: `name`, optional `nets`/`refs`
  (arrays or comma-strings) to spotlight a subsystem, `route`, `width`, `layout`,
  `sub`, `regen`, `names` (ref|origin|both part labels), `pins` (label pad net
  names on the given refs, or "hubs"). `describe_pcb_layout` is its textual
  twin — the `/api/pcb-describe` facts JSON built from the identical placement
  (args: `name`, optional `route`/`layout`/`sub`/`regen`).
- **VFS file ops**: `read_file`, `list_dir`, `glob` (read-only);
  `write_file`, `edit_file`, `delete_file`, `move_file` (mutation).
- **Build / state**: `build`, `regenerate_pinout`, `restore_version`.

There is **no** granular `add_component` / `swap_component` / `edit_value` /
`rewire_pin` / `remove_component` tool — schematic edits go through
`read_file` → `edit_file` (or `write_file`) on the design's `.sexp` file,
then `build` to push the new version. There is no "requirements" concept;
this MCP server only models S-expression schematic capture. Mutation tools
return the new `live_version`, so the browser picks up changes via its
existing 2 s poll of `/api/version/:name`. `generate_review` is read-only
and returns the full review-doc JSON (matching `GET /api/review/:name`).

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
claude mcp add --transport http netlisp http://localhost:7050/mcp \
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

- **Never edit Zig code directly on `main` — always work in a worktree.** Any change to the compiler/server source (`src/**/*.zig`, `build.zig`, `build.zig.zon`) must be made on a feature branch in its own worktree under `.claude/worktrees/` (`git worktree add .claude/worktrees/<short-name> -b <branch>`) — do all edits, builds, and commits there. `main` is for merging finished code branches into and for rebuilding/deploying prod — never for in-progress code edits. Editing `main`'s checkout directly risks loose state being swept into auto-commits and silently reverting other branches (see the next rule). When a branch is ready, merge it into `main` (`--no-ff`, "Merge: …"), then rebuild/restart from the `main` checkout.
- **Design files and docs may be edited directly on `main`.** Design sources (`.sexp` files under `projects/designs/`) and documentation (`.md` files — `CLAUDE.md`, `SPEC.md`, `*.notes.md`, etc.) don't rebuild the binary, so they can be changed, committed, and pushed straight from the `main` checkout without a worktree. Still keep the tree clean: commit such edits promptly rather than leaving them loose (see the next rule).
- **Keep the main worktree's tree clean.** If `git status` on main shows anything (uncommitted edits, staged deletions, untracked scratch files), deal with it *before* asking anything to merge branches — uncommitted state on main gets swept into auto-commits and can silently revert work from other branches. Lesson learned the hard way: a partial-revert sitting staged on main deleted the schematic sidebar when another branch was merged.
- **Commit WIP; don't leave it dangling.** Across-session work should land as a `WIP: ...` commit on the feature branch (fine to squash later), never as loose edits in a worktree. Stashes are invisible to automation and to a future you — prefer a commit.
- **Rebase worktree branches onto main weekly or before handoff.** Branches that drift more than a few commits behind main produce wide conflicts and, worse, context-line drift (e.g. a function call surviving a rebase after the function itself was deleted upstream). Small, frequent rebases keep the delta legible.
- **Before bulk-merging worktrees, inventory them.** Run `git status` in each worktree (a `git worktree list` + loop works well). Flag any uncommitted work and decide commit-vs-discard *per worktree* before anything touches main.
- **Retire merged worktrees.** `git worktree remove <path> && git branch -D <branch>` once a branch is in main. Fewer live worktrees = fewer places for drift to hide.
- **Audit `git stash list` periodically.** Stashes labelled against deleted branches are almost always forgotten work worth reviewing or dropping.
