# EDA Architecture

A high-level map of what this tool does today. Capability-focused, language-agnostic — the implementation lives in `src/`, but this document deliberately stays out of it.

- For the design language itself, see [`sexp-language.md`](sexp-language.md).

## 1. What the tool is

**A CLI-driven schematic-capture EDA tool where designs are S-expression source files.** A single binary (`eda`) parses, evaluates, validates, renders, and serves designs. Source files in `projects/designs/` are evaluated into an in-memory design graph that fans out to four terminal forms:

- **Browser-rendered HTML schematic** with inline SVG (hub-and-spoke layout, live-updating).
- **Design-review report** — a structured HTML/JSON document with power-budget, BOM, ERC, and assertion roll-ups.
- **KiCad handoff** — netlist + footprints + STEP models for PCB layout.
- **MCP surface** — every read/write the schematic exposes to Claude Code.

The intended workflow is text-first and live: edit a `.sexp` file → run `eda build --push <design>` → the open browser tab refreshes within ~500 ms. There is no GUI editor; the browser is read-only with narrow value-edit affordances.

**What the tool is not, today.** It does not place or route a PCB (KiCad does). It does not simulate (no SPICE). It does not host a parts database (BOM data is sidecar `.sexp` files). It does not version-diff designs visually. It does not do schematic-level layout (positions are hints, not pixels).

## 2. Core concepts

| Concept | What it is |
| --- | --- |
| **Design block** | The unit of capture. A named container of instances, ports, nets, sections, and sub-blocks. Every `.sexp` design file evaluates to one. |
| **Instance** | A placed component with a stable 8-char hex ID (e.g. `(id ab12cd34)`), a ref-des (`R1`, `C2`, `U3` — auto-assigned by prefix if not given), and pin-to-net connections. |
| **Net** | An electrical connection inferred from the union of pins that name it. Nets are not declared; they emerge from `(pin … "NET")` connections. `(net …)` exists only to tie two names together. |
| **Port** | A design block's external interface — direction (`in`/`out`/`bidi`), signal type (`power`/`signal`/`clock`/…), voltage rating, role, protocol. |
| **Section** | A named, grid-positioned subdivision of a design — has a status (`concept`/`design`/`implemented`/`review`), a description, and a list of forms it owns. Drives both the schematic page layout *and* the auto-categorised block-diagram view in the page header. Set `(diagram hidden)` to exclude a section (e.g. test points, fiducials) from the block diagram. |
| **Sub-block** | An instance of another `.sexp` file. If that file is a `defmodule`, it takes parameters; otherwise it's a plain composition. |
| **Component vs component-family** | `component` is a fixed part (`res-0402`, `tpsm84338rcjr`). `component-family` is a parameterised template (`(cap "100nF")`, `(res "10k")`). |
| **Hubs vs spokes** | A rendering convention. Hubs are ICs/connectors/transistors (ref-des `U/J/P/X/Q`) — they get drawn as boxes on a grid. Spokes are R/C/L/F/D — they're rendered inline on the connection between two hubs. |
| **Stable ID** | An 8-char hex ID grafted onto every instance/series/decouple, written back into the source file on first build. Lets ref-deses be reshuffled without breaking BOM/PCB linkage. |

## 3. The pipeline

```
.sexp source
   │
   ▼
tokenize → parse  (every AST node carries a byte/line/col span)
   │
   ▼
evaluate          (recursive: special forms, builtins, lexical scope,
   │               modules with closure capture, eager eval otherwise)
   │              ─ resolves all (import …)
   │              ─ expands all (sub-block …)
   │              ─ accumulates assertions
   ▼
post-build        (insert auto-generated 8-char hex IDs back into source,
   │               assign ref-deses deterministically by source order,
   │               resolve BOM data with Pass 3.5 fixed-point UUID-swap
   │               correction, enrich single-alt pin functions, tie nets,
   │               build power-budget graph)
   ▼
DesignBlock       (instances, nets, ports, sections, sub-blocks, assertions,
   │               power-budget edges, requirement coverage)
   │
   ├── render_html / render_svg          →  schematic page (hub-and-spoke SVG)
   ├── render_block_diagram_svg          →  compass block diagram (page header)
   ├── render_system_svg                 →  chip strip (review report header)
   ├── render_json                       →  scene-graph JSON  (live-push channel)
   ├── review                            →  HTML + JSON design-review report
   ├── erc                               →  electrical-rule violations
   ├── emit                              →  flattened post-eval .sexp
   └── export_kicad                      →  netlist + footprints + STEP models
```

Four observations worth flagging:

- **Spans survive the whole pipeline.** Every error and every auto-inserted ID points back at a (line, col, byte) in the source file. The printer is round-trip safe — IDs get grafted in place without lexical drift.
- **Assertions never abort the build.** `(assert …)` and `(assert-range …)` accumulate pass/fail entries that surface in the review report. A failing assertion is a finding, not a stop.
- **The live-push pipeline runs scene-graph JSON, not HTML.** `eda build --push` increments a per-design version counter on the running server. Browsers poll `/api/version/:name` every 2 s; on a bump they re-fetch the JSON scene graph and re-render. The server-side HTML page is canonical for first load and review-mode.
- **Post-build is deterministic and idempotent.** Ref-deses are assigned by walking instances in source-offset order (so repeated evaluations produce byte-identical BOMs). BOM resolution has a Pass 3.5 fixed-point step that converges UUID-swap corrections in one call. The `pin_enrichment` pass auto-fills `(as …)` for any pin whose pinout entry has exactly one alt, so downstream consumers (renderer, KiCad export, ERC) see the unique alt as if it had been typed.

## 4. Capability inventory

### S-expression language

The schematic source language. Full reference in [`sexp-language.md`](sexp-language.md). Headline features:

- Special forms: `let`, `if`, `cond`, `fmt`, `assert`, `assert-range`.
- Builtins: arithmetic (`+ - * / %`), comparison (`> >= < <= == !=`), logic (`and or not`).
- Format directives for engineering units: `~V` (voltage), `~R` (resistance), `~C` (capacitance), `~A` (current), `~S` (string).
- Parameterised modules (`defmodule`) with closure capture.
- `import` system that searches `lib/components/` then `lib/modules/`, project-local then shared.
- Stable identity via auto-generated 8-char hex `(id …)` markers, flushed back to disk on build.
- Bus shorthand for wide pin groups (`(bus "FLASH_IO" T19 P19 V19 …)` → `FLASH_IO0`, `FLASH_IO1`, …).
- Indexed net-tie shorthand (`(bus-net "FLASH_IO" 0 7 "flash")` → 8 `(net …)` ties across a sub-block boundary).
- Indexed port shorthand (`(bus-port "ADF_CH" 1 10 (suffixes P N) in differential)` → 20 differential-pair ports).
- Decoupling shorthand (`(decouple …)` auto-generates per-pin sub-nets and cap instances).
- Section opt-out from the block-diagram view: `(diagram hidden)` for sections like test points and fiducials.

### Schematic rendering

Server-rendered HTML page with inline SVG.

- **Hub-and-spoke topology.** ICs/connectors/transistors are hubs (rendered as boxes on a row/col grid). Passives (R/C/L/F/D) are spokes — drawn inline on the wire between two hubs.
- **Multi-part symbols.** A single MCU can spread across multiple grid cells via `(part "name" (row N) (col N) …)` blocks, each with its own pin set.
- **Named grid sections.** A `section` declares its own row/col placement (or accepts whatever is implicit from declaration order).
- **Block-diagram view.** Auto-generated SVG at the top of every schematic page. Classifies each section by name keyword (table below) and lays it out in a compass around the MCU hub: power producers west, connectors + comms north, memory south, sensors + peripherals east. Voltage rails are labelled inside each block (consumed in red, produced in green); inter-block wires carry a short bus tag (the first word of the section name plus the protocol if declared, e.g. `XSPI2 · OctoSPI`). Sections marked `(diagram hidden)` are skipped. The chip strip in the review-report header still uses the older flat-strip classifier (`render_block_types.classifyByName`). Both share the keyword table:

| Category | Color | Keywords matched (case-insensitive) |
| --- | --- | --- |
| **mcu** | blue | `MCU`, `SoC`, `CPU`, `Core System`, `STM32`, `ESP32`, `nRF`, `Microcontroller` |
| **power** | red | `Buck`, `LDO`, `Regulator`, `Power`, `Charger`, `Converter`, `PMIC` |
| **memory** | purple | `Flash`, `PSRAM`, `RAM`, `EEPROM`, `SD Card` |
| **clock** | teal | `Clock`, `HSE`, `LSE`, `Oscillator`, `PLL`, `Crystal` |
| **comms** | cyan | `USB`, `Ethernet`, `BLE`, `WiFi`, `CAN`, `UART` |
| **sensor** | green | `IMU`, `ADC`, `Sensor`, `Temperature`, `Accelerometer`, `Gyro` |
| **analog** | magenta | `Analog`, `DAC`, `Op-Amp`, `Reference`, `Amplifier` |
| **protection** | grey | `ESD`, `Protection`, `Fuse`, `TVS` |
| **connector** | yellow | `Connector`, `Expansion`, `Header`, `Mounting`, `SWD`, `Debug`, `RJ45`, `B2B` |
| **peripheral** | (default) | fallback when no keyword matches |

If no keyword matches and the section's first instance has a ref-des starting with `J` or `P`, it falls into the connector bucket.

- **Scene-graph JSON.** A serialisable representation of the schematic at `GET /api/scene-graph/:name` — used by the live-push channel and any future UI client.
- **Sidebar.** Notes, BOM info, datasheet links, requirement-coverage hints, ERC violations attached to ref-deses.

### Design notes

A structured per-design TODO log, stored as `<design>.notes.md` next to the design source. Each note carries an 8-char hex ID, body text, UTC `created_at` / `completed_at` timestamps, and an open/done state. Surfaced in the schematic viewer's notes panel and through MCP tools (`list_design_notes`, `add_design_note`, `complete_design_note`, `reopen_design_note`, `remove_design_note`). Distinct from `(note …)` forms inside `.sexp` source — design notes are a workflow scratchpad outside the netlist, meant for "follow up before tape-out" items that wouldn't make sense as ref-des-attached annotations.

### Electrical-rule checks (ERC)

A post-build pass over the resolved design block. 12 checks ship today:

| Check | What it catches |
| --- | --- |
| `duplicate_refdes` | Two instances with the same ref-des. |
| `pin_multi_net` | A single pin connected to two different nets. |
| `floating_net` | A net referenced by zero instances (dangling wire). |
| `unconnected_pin` | A section port that no instance drives, or a power/ground pin not connected. |
| `missing_value` | An R/C/L instance with no value. |
| `missing_footprint` | An instance whose component has no footprint assigned. |
| `missing_decoupling` | A power pin lacking a nearby bypass cap. |
| `voltage_mismatch` | A pin's expected voltage doesn't match the net's voltage rating. |
| `concept_remaining` | A section still marked `concept` — design-readiness reminder. |
| `power_budget` | A net's current draw exceeds a declared rating. |
| `pin_function_unsupported` | A pin's `(as "FN")` assertion names a function that isn't in the pinout's primary + alts list. |
| `pin_function_required` | A pin whose pinout entry has ≥ 2 alts was wired without an `(as …)` to disambiguate. (Pins with exactly one alt auto-fill via `pin_enrichment` and don't trigger this; pins with no alts don't need one.) The pinout lookup is dual-keyed by BGA position *and* logical name, so `(pin H4 …)` and `(pin PC13 …)` both resolve. |

Two more violation kinds (`multiple_drivers`, `power_no_cap`) exist in the enum but aren't currently invoked from the runner.

### Design-review report

Available as HTML at `GET /review/:name` or JSON at `GET /api/review/:name`. Sections:

- **Summary banner** — overall pass/warn/fail status plus roll-up counts (sections, instances, nets, violations, assertions, requirement coverage, BOM MPN coverage).
- **Power-budget table** — per-net current sums, total dissipation, sequencing order across sub-blocks.
- **Per-section cards** — one per section: status, description, declared ports, attached violations, requirement coverage, contained instances.
- **Component-requirement verification** — library-declared rules for critical ICs (e.g. "VDD must be decoupled within 100 mil") + pass/fail per placement.
- **BOM table** — grouped by ref-des prefix (U/R/C/TP/…). Each row: ref-des, component, value, footprint, MPN status.
- **Assertions table** — pass/warn/fail status for every assertion (`(assert …)` / `(assert-range …)` from the design).
- **Test points** — if declared in the source.
- **ERC violations** — grouped by kind, then by ref-des.
- **Unresolved violations** — bucket for findings with no ref-des to attribute to.

### Exports

| Format | Endpoint / command |
| --- | --- |
| KiCad netlist (legacy `.net`) | `eda export-kicad`, `GET /api/export-netlist/:name` |
| KiCad netlist + footprints + STEP models | `eda export-kicad`, `GET /api/export-kicad/:name` |
| BOM CSV | `GET /api/export-bom/:name` |
| Review markdown + CSV bundle (.zip) | `eda export-review`, `GET /api/export-review/:name` |
| Flattened post-eval `.sexp` | `eda build` |

### Web server (`eda serve`)

Default port 7050. Dev URL: `http://localhost:7050`. Production URL: `https://co-circuit.eugenepentland.dev`.

**Pages.** `/` (design list), `/schematics/:name` (schematic viewer), `/review/:name` (review viewer), `/library` (library upload), `/account` (OAuth client management), `/auth/*` (login/setup pages), `/pdf-view/:filename` (datasheet viewer).

**Read APIs.** `/api/designs`, `/api/scene-graph/:name`, `/api/review/:name`, `/api/erc/:name`, `/api/version/:name`, `/api/pinout/:name`, `/api/footprint/:name`, `/api/datasheets`, `/datasheets/:filename`.

**Mutation APIs.** `POST /api/push/:name` (rebuild + bump version), `POST /api/edit-value/:name` (edit a component value in-place), `POST /api/section-note/:name/{add,remove}` (annotate a section), `POST /api/component-datasheet/:component/{add,remove}` (link/unlink datasheet), `POST /api/upload-datasheet`, `POST /api/upload-symbol`, `POST /api/upload-footprint`.

**Export APIs.** Listed in the Exports table above.

**KiCad sync orchestration.** `POST /api/sync-kicad-pcb/:name` — file-based sync: reads the `.kicad_pcb` at the design's `(kicad-pcb "<path>")` form, diffs it against the flattened netlist, and writes the updated board in place. See the [KiCad sync](#kicad-sync-file-based) section below.

**MCP transport.** `POST /mcp` (streamable HTTP, the transport Claude Code's remote MCP connector uses), `GET /mcp` (WebSocket, for local testing). OAuth via `/.well-known/oauth-authorization-server`, `/.well-known/oauth-protected-resource`, `/oauth/authorize`, `/oauth/token`.

### Authentication & authorisation

- Passkey-first (WebAuthn challenge/complete), with a username+password fallback.
- Three roles: `admin`, `writer`, `reader`. Admins mint single-use invite links (7-day TTL); the invite link encodes the role.
- Per-install OAuth `client_id`/`client_secret` pairs for MCP clients. Secrets stored as SHA-256 hashes only. Persisted to `projects/designs/auth/oauth_clients.json` and `oauth_tokens.json`.
- Plugin tokens (bearer) for the KiCad sync agent — minted via `eda mint-plugin-token`.
- Localhost dev bypass: when no session exists and the request is from `localhost`, the account page falls back to a `dev@localhost` identity.

### MCP server

Exposes the project to Claude Code as a tool surface. Tools fall into five buckets:

| Bucket | Tools |
| --- | --- |
| **Project introspection** | `list_designs`, `list_library`, `list_history`, `describe_component`, `get_schematic`, `get_version`, `list_instances`, `list_free_pins`, `get_net` |
| **Analysis** | `run_checks`, `generate_review` |
| **VFS reads** | `read_file`, `list_dir`, `glob` |
| **VFS writes** | `write_file`, `edit_file`, `delete_file`, `move_file` |
| **Build / state** | `build`, `regenerate_pinout`, `restore_version` |
| **Design notes** | `list_design_notes`, `add_design_note`, `complete_design_note`, `reopen_design_note`, `remove_design_note` |

Two design choices worth calling out:

- **No granular schematic-edit tools.** There is no `add_component` / `swap_component` / `rewire_pin`. Edits flow through `read_file` → `edit_file` → `build`. This keeps the source file the single source of truth and avoids divergent representations.
- **Mutation tools return `live_version`.** The browser's 2-s poll of `/api/version/:name` picks up the change without any extra wiring.

### KiCad sync (file-based)

Schematic → PCB. The schematic is canonical; the server updates the `.kicad_pcb` to match. Implemented entirely server-side in `src/serve/sync.zig`:

- **Trigger.** The schematic viewer's **Push to KiCad PCB** button (`POST /api/sync-kicad-pcb/:name`). `?dry_run=1` returns the diff without writing; `?migrate=1` enables the heuristic relink; `?prune=1` turns `flag_stale` into real removals.
- **Protocol.** The server reads the `.kicad_pcb` declared by the design's `(kicad-pcb "<path>")` form, diffs the on-disk board against the design's flattened netlist (`runSyncPlan`), and applies the resulting ops (`add`, `set_field`, `set_pad_net`, `swap_footprint`, `remove`, `flag_stale`) to the file in place.
- **What's preserved.** Footprint UUIDs, pad netlists, field values, board origin, placement coordinates. New instances land in a per-section staging area off to the side until the user places them.

> A standalone Go IPC agent (driven from inside KiCad over an NNG protobuf socket, posting to a now-removed `/api/sync-plan` endpoint) previously did this. It was removed in favour of the file-based path above.

### Conversion tools

- `eda convert-footprint <file.kicad_mod>` — KiCad footprint → `.sexp`.
- `eda convert-symbol <file.kicad_sym> [--filter <name>]` — KiCad symbol → `.sexp`.
- `eda convert-pinout <file.kicad_sym> [--filter <name>]` — extract pinout (pin → function) only.
- `eda convert-package <sym.kicad_sym> <fp.kicad_mod> [--name <name>] [--filter <f>]` — combine symbol + footprint into a package.
- `eda merge-alt-functions <pinout.sexp> <alts.csv|alts.xml> [--write]` — enrich a pinout with alternate-function metadata from a vendor CSV/XML.

### Live-update loop

```
edit .sexp file
   ↓
eda build --push <name>
   ↓
server: re-evaluate, regenerate scene graph, increment per-design version counter
   ↓
browser: 2-s poll of /api/version/:name picks up the new version
   ↓
browser: re-fetch /api/scene-graph/:name and re-render
```

End-to-end latency is dominated by the 500-ms-to-2-s polling interval, not the rebuild.

## 5. Project layout

A project directory passed via `--project-dir` looks like:

```
projects/designs/
├── src/                          # designs (one directory per design)
│   ├── stm32n6/
│   │   ├── stm32n6.sexp
│   │   └── stm32n6.notes.md      # per-design TODO log (see Design notes)
│   ├── power-6v/
│   │   └── power-6v.sexp
│   └── …
├── lib/
│   ├── components/               # fixed parts (e.g. tpsm84338rcjr.sexp)
│   ├── modules/                  # parameterised compositions (e.g. tpsm84338.sexp)
│   ├── symbols/                  # raw KiCad symbols (uploaded)
│   ├── footprints/               # raw KiCad footprints
│   ├── pinouts/                  # extracted pinouts (pin → function lookups)
│   └── datasheets/               # uploaded PDFs
└── auth/
    ├── oauth_clients.json        # OAuth client_id/secret-hash store
    ├── oauth_tokens.json         # access-token store (hashed)
    ├── plugin_tokens.json        # KiCad-agent bearer tokens
    └── users.json                # passkey + password credentials
```

KiCad sync sidecars live next to the `.kicad_pcb` (not in `projects/designs/`):

```
<board-dir>/
├── Board.kicad_pcb
├── Board.kicad_pcb.applied_ops.json   # state-asserting op fingerprints
├── Board.kicad_pcb.stale.json         # orphan-footprint inventory
├── Board.kicad_pcb.eda-sync.json      # per-board agent config (server URL, design name)
└── ~Board.kicad_{pcb,pro}.lck         # KiCad's project lock files (transient)
```

**`(import …)` resolution.** Each name is resolved as `lib/components/<name>.sexp` then `lib/modules/<name>.sexp`, in `--project-dir` first then in the shared library directory (if configured). A file is identified as a *component* iff its first top-level form is `(component …)` or `(component-family …)` — otherwise it's a *module*. The same name can't be both.

## 6. CLI command map

| Command | Purpose |
| --- | --- |
| `eda parse <file>` | Parse and pretty-print a `.sexp` file. Round-trip sanity check. |
| `eda build [--project-dir P] [--push] <name>` | Evaluate a design; emit JSON scene-graph + build metadata. `--push` notifies a running server. |
| `eda check [--project-dir P] <name>` | Run ERC and emit violations as JSON. |
| `eda serve [--project-dir P] [--port 7050] [--auth-dir D]` | Start the web/MCP server. |
| `eda export-kicad [--project-dir P] --output-dir D <name>` | Export KiCad netlist + footprints + STEP models. |
| `eda export-review [--project-dir P] --output-dir D <name>` | Export design-review markdown + BOM CSV. |
| `eda convert-footprint <f.kicad_mod>` | Convert a KiCad footprint to `.sexp`. |
| `eda convert-symbol <f.kicad_sym> [--filter <n>]` | Convert a KiCad symbol to `.sexp`. |
| `eda convert-package <sym> <fp> [--name <n>] [--filter <f>]` | Combine a symbol + footprint into a `.sexp` package. |
| `eda convert-pinout <f.kicad_sym> [--filter <n>]` | Extract the pin → function pinout from a KiCad symbol. |
| `eda merge-alt-functions <pinout.sexp> <alts.csv\|.xml> [--write]` | Enrich a pinout with alternate-function metadata. |
| `eda mint-plugin-token [--label <l>] [--auth-dir D]` | Issue a bearer token for the KiCad sync agent. |
| `eda mint-invite [...]` | Mint a single-use invite link (7-day TTL, role-gated). |
| `eda set-password [...]` | Set or reset a user password and role (admin/writer/reader). |
| `eda help` | Print usage. |

## 7. Appendix: HTTP & MCP surface

### HTTP routes

#### Pages
| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` | Design list. |
| GET | `/style.css` | UI stylesheet. |
| GET | `/schematics/:name` | Schematic viewer page. |
| GET | `/review/:name` | Review-doc HTML page. |
| GET | `/library` | Library upload page. |
| GET | `/account` | OAuth client management (per-user). |
| GET | `/pdf-view/:filename` | Datasheet PDF viewer. |
| GET | `/datasheets/:filename` | Serve a datasheet PDF. |

#### Auth
| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/auth/login` | Login page. |
| GET | `/auth/setup` | First-run setup. |
| GET | `/auth/login/challenge` | WebAuthn login challenge. |
| POST | `/auth/login/complete` | WebAuthn login completion. |
| GET | `/auth/register/challenge` | WebAuthn register challenge. |
| POST | `/auth/register/complete` | WebAuthn register completion. |
| POST | `/auth/logout` | Sign out. |
| POST | `/auth/password/login` | Password login. |
| POST | `/auth/password/set` | Set/reset password. |
| GET | `/auth/password/status` | Whether password is set. |
| GET | `/auth/credentials/list` | List user credentials. |
| POST | `/auth/credentials/delete` | Delete a credential. |
| GET | `/auth/manage` | Account management. |
| GET | `/auth/invite/*` | Accept an invite link. |
| POST | `/auth/invite/create` | Mint an invite link. |

#### Read APIs
| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/designs` | List all designs. |
| GET | `/api/scene-graph/:name` | Schematic scene-graph JSON. |
| GET | `/api/version/:name` | Per-design version counter (live-update poll). |
| GET | `/api/review/:name` | Review-doc JSON. |
| GET | `/api/erc/:name` | ERC violations JSON. |
| GET | `/api/pinout/:name` | Component pinout JSON (for the schematic viewer). |
| GET | `/api/footprint/:name` | Footprint SVG preview. |
| GET | `/api/datasheets` | List uploaded datasheets. |
| GET | `/api/export-kicad/:name` | KiCad netlist + footprints + STEP models. |
| GET | `/api/export-netlist/:name` | KiCad netlist only. |
| GET | `/api/export-bom/:name` | BOM as CSV. |
| GET | `/api/export-review/:name` | Review package (.zip or .md+.csv). |
| GET | `/api/notes/:name` | Design notes as raw markdown. |
| GET | `/api/notes/:name/tasks` | Structured TODO entries + scratchpad. |

#### Mutation APIs
| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/api/push/:name` | Re-evaluate from source; bump version. |
| POST | `/api/edit-value/:name` | Edit a component value in-place. |
| POST | `/api/section-note/:name/add` | Add a note to a section. |
| POST | `/api/section-note/:name/remove` | Remove a section note. |
| POST | `/api/component-datasheet/:component/add` | Attach datasheet to component. |
| POST | `/api/component-datasheet/:component/remove` | Detach datasheet. |
| POST | `/api/upload-datasheet` | Upload a PDF datasheet. |
| POST | `/api/upload-symbol` | Upload a KiCad symbol to the project library. |
| POST | `/api/upload-footprint` | Upload a KiCad footprint. |
| POST | `/api/sync-plan/:name` | KiCad sync orchestration (server-side diff). |
| PUT | `/api/notes/:name` | Overwrite design notes markdown. |
| POST | `/api/notes/:name/tasks/add` | Append a TODO entry. |
| POST | `/api/notes/:name/tasks/complete` | Mark a TODO entry done. |
| POST | `/api/notes/:name/tasks/reopen` | Re-open a completed entry. |
| POST | `/api/notes/:name/tasks/remove` | Delete a TODO entry. |

#### MCP transport
| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/mcp` | Streamable HTTP MCP transport. |
| GET | `/mcp` | WebSocket MCP transport. |
| GET | `/.well-known/oauth-authorization-server` | OAuth metadata (RFC 8414). |
| GET | `/.well-known/oauth-protected-resource` | Protected-resource metadata (RFC 9728). |
| GET | `/oauth/authorize` | OAuth consent page. |
| POST | `/oauth/authorize/approve` | Consent form POST. |
| POST | `/oauth/token` | Authorization-code exchange. |

### MCP tools

| Tool | Purpose |
| --- | --- |
| `list_designs` | Enumerate all designs in the project. |
| `list_library` | Browse `lib/components`, `lib/modules`, `lib/symbols`, `lib/footprints`, `lib/pinouts`, `lib/datasheets`. |
| `list_history` | Per-design version-control log (author, timestamp, diffs). |
| `describe_component` | Symbol + footprint + pinout + properties for one component. |
| `get_schematic` | Scene-graph JSON for a design. |
| `get_version` | Schema version number. |
| `list_instances` | All placed components in a design. |
| `list_free_pins` | Unconnected pins on a design. |
| `get_net` | Pin list and voltage for a named net. |
| `run_checks` | Execute ERC; return violations. |
| `generate_review` | Build the full review document (matches `/api/review/:name`). |
| `read_file` | Read a project file. |
| `write_file` | Create/replace a file. |
| `edit_file` | Targeted edits (S-expression mutations). |
| `delete_file` | Remove a file. |
| `move_file` | Rename or relocate a file. |
| `list_dir` | Directory listing. |
| `glob` | Pattern-based file search. |
| `build` | Re-evaluate a design; auto-insert IDs; bump version. |
| `regenerate_pinout` | Re-derive a component's pinout from its KiCad source. |
| `restore_version` | Revert a design to an earlier revision. |
| `list_design_notes` | List open / done TODO entries for a design. |
| `add_design_note` | Append a new TODO entry to `<design>.notes.md`. |
| `complete_design_note` | Mark a TODO entry done (stamps `completed_at`). |
| `reopen_design_note` | Re-open a completed entry. |
| `remove_design_note` | Delete a TODO entry by id. |
