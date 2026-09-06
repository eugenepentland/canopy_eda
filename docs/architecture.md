# Netlisp Architecture

**What this is:** the map of what netlisp can do and how the pieces fit
together — read it first if you are deciding whether the tool covers your
workflow, or you need to know which subsystem owns a behaviour before you go
looking for it. It is capability-focused and deliberately implementation-light:
the code lives in `src/`, and this document names a module only when knowing
the name saves you a search. For the reference docs it sits in front of, see
[`README.md`](README.md).

- For the design language itself, see [`sexp-language.md`](sexp-language.md),
  with the generated grammar in [`language-forms.md`](language-forms.md).
- For every HTTP route and structured tool, see [`webserver-api.md`](webserver-api.md).

## 1. What the tool is

**A command-line EDA tool where the design is S-expression source, and one
binary takes it from a schematic to fabrication artwork.** `netlisp` parses,
evaluates, validates, renders, places, routes, checks and exports; the browser
is a viewer and a review surface, not a capture tool. There is no GUI schematic
editor and no drawing step — the `.sexp` file *is* the schematic.

A design evaluates into an in-memory graph that fans out to six families of
output:

- **Schematic** — a server-rendered HTML page with inline SVG (hub-and-spoke
  layout, live-updating), a headless PNG, and a review PDF.
- **Checks** — electrical rules, executable component requirements,
  design-owned rules, power-budget and thermal screening, gated by a profile
  (`authoring` / `preflight` / `release`).
- **PCB layout** — force-directed placement, a maze autorouter with rip-up and
  rescue, copper pours and planes, geometric DRC, impedance-driven track
  widths, RF via fencing, and a 2D/3D board viewer.
- **Fabrication** — Gerber artwork, Excellon drills, pick-and-place centroids,
  a revision-locked fab package, a panelizer, and a pre-fab readiness gate.
- **Interop** — a complete KiCad project (netlist, footprints, STEP models and
  a hierarchical `.kicad_sch`), board push and import in both directions,
  a firmware pin map, and a flattened SPICE deck.
- **Review** — board and system review documents, release dossiers, a waiver
  register, and a complete engineering handoff archive.

Every one of those is reachable three ways: a `netlisp` subcommand, an HTTP
route on `netlisp serve`, and a structured tool with a JSON schema
(`netlisp tool …`). The structured tools are the surface an agent drives; see
[`agents.md`](agents.md).

**What the tool is not.** It is not a circuit simulator: there is a
steady-state thermal field solve, a transmission-line impedance solver and a
PLL/frequency-plan model, but no time- or frequency-domain circuit solver —
`export-spice` writes a deck for someone else's simulator, with no models and
no parasitics. It has no GUI schematic capture, no visual version diff, and no
schematic auto-placement (grid positions are authored hints, not solved
pixels). Its parts data is local: `lib/parts/*.sexp` tables plus live DigiKey
and Component Search Engine lookups, not a hosted component database. And it
is a single-user local tool — no accounts, no multi-tenant server.

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
| **Standard library** | The component set compiled into the `netlisp` binary (`stdlib/`): the sixteen passive families every design auto-imports, their land patterns, and a few generic board features. Resolution is project `lib/` → `--lib-dir` / `NETLISP_LIB_DIR` → `NETLISP_STDLIB_DIR` → the bundle, first hit per name — so a project with no `lib/` still evaluates and a project with one always wins. See [standard-library.md](standard-library.md). |
| **Stable ID** | An 8-char hex ID grafted onto every instance/series/decouple, written back into the source file on first build. Lets ref-deses be reshuffled without breaking BOM/PCB linkage. |
| **Sidecar** | A file that sits beside `src/<design>.sexp` and is autoloaded into the design without an `(import …)`: `<design>.checks.sexp` (verification sign-offs), `.layout.sexp` (board, stackup, net classes, PCB plan), `.diagram.sexp` (diagram layout and grouping). Generated sidecars — `.bom`, `.layouts.json`, `.notes.md`, `.trials.json` — are written by the tool and are never hand-edited. |
| **Saved layout** | A named board state (poses, outline, tracks, vias, pours, text) inside `<design>.layouts.json`. One layout per design may be *starred* — the default the PCB page, the exporters and the fab gate all read. |
| **Net class** | A `(net-class …)` rule binding named nets to physical intent: track width or a target impedance, clearance, via geometry, routing priority, differential pairing, RF ground fencing. It is what makes the router's copper reproducible from the design rather than from a mouse. |
| **Variant** | An assembly variant — one PCB and one netlist, several build configurations differing only in which parts are populated and what value a populated part carries. Declared with `(variant "NAME" …)` and selected with `--variant` / `?variant=` / a tool argument. |
| **Check profile** | How strict a check run is. `authoring` reports, `preflight` gates, `release` adds the component-class review obligations, a cited-requirement demand on every active part, and evaluator warnings as findings. |

## 3. The pipeline

```
.sexp source  (+ autoloaded .checks/.layout/.diagram sidecars)
   │
   ▼
tokenize → parse  (every AST node carries a byte/line/col span)
   │
   ▼
evaluate          (recursive: special forms, builtins, lexical scope,
   │               modules with closure capture, eager eval otherwise)
   │              ─ resolves all (import …)
   │              ─ expands all (sub-block …)
   │              ─ expands structural control flow, connect/chain,
   │                interface bundles and the selected variant
   │              ─ accumulates assertions
   ▼
post-build        (insert auto-generated 8-char hex IDs back into source,
   │               assign ref-deses deterministically by source order,
   │               resolve BOM data with Pass 3.5 fixed-point UUID-swap
   │               correction, enrich single-alt pin functions, tie nets,
   │               build power-budget graph and net voltage envelopes)
   ▼
DesignBlock       (instances, nets, ports, sections, sub-blocks, assertions,
   │               power-budget edges, requirement coverage, physical rules)
   │
   ├── render_html / render_svg          →  schematic page (hub-and-spoke SVG)
   ├── render_block_diagram_svg          →  compass block diagram (page header)
   ├── render_system_svg                 →  chip strip (review header)
   ├── render_json                       →  scene-graph JSON  (live-push channel)
   ├── preflight / erc / req_*           →  findings at the chosen profile
   ├── review / review_audit             →  board + system review documents
   ├── emit                              →  flattened post-eval .sexp
   ├── export_kicad, export_kicad_sch    →  a complete KiCad project
   ├── export_pinmap, export_spice       →  firmware pin map, SPICE deck
   │
   └── flat netlist ──► placement ──► routing ──► DRC ──► fabrication
         (optimizer)   (router,       (drc.*)     (export_gerber,
                        pour, vias)                export_fab, panelize,
                                                   fab_readiness, fab_release)
```

The board half of that diagram reads its poses and copper from the design's
saved layout, and writes them back there — the schematic stays canonical, and
the layout is a sidecar over it rather than a second source of truth.

Four observations worth flagging:

- **Spans survive the whole pipeline.** Every error and every auto-inserted ID points back at a (line, col, byte) in the source file. The printer is round-trip safe — IDs get grafted in place without lexical drift.
- **Assertions never abort the build.** `(assert …)` and `(assert-range …)` accumulate pass/fail entries that surface in the review report. A failing assertion is a finding, not a stop.
- **The live-push pipeline runs scene-graph JSON, not HTML.** `netlisp build --push` increments a per-design version counter on the running server. Browsers poll `/api/version/:name` every 2 s; on a bump they re-fetch the JSON scene graph and re-render. The server-side HTML page is canonical for first load and review-mode.
- **Post-build is deterministic and idempotent.** Ref-deses are assigned by walking instances in source-offset order (so repeated evaluations produce byte-identical BOMs). BOM resolution has a Pass 3.5 fixed-point step that converges UUID-swap corrections in one call. The `pin_enrichment` pass auto-fills `(as …)` for any pin whose pinout entry has exactly one alt, so downstream consumers (renderer, KiCad export, ERC) see the unique alt as if it had been typed.

## 4. Capability inventory

### S-expression language

The schematic source language. Full reference in [`sexp-language.md`](sexp-language.md). Headline features:

- Special forms: `let`, `if`, `fmt`, `assert`, `assert-range` (there is no `cond`).
- Builtins: arithmetic (`+ - * / %`), comparison (`> >= < <= == !=`), logic (`and or not`).
- Format directives for engineering units: `~V` (voltage), `~R` (resistance), `~C` (capacitance), `~A` (current), `~S` (string).
- Parameterised modules — `(block name (params…) …)`, with `defmodule` as a permanent alias — with closure capture. A parameter may be a component, so a module can take the part it places. A `(param default)` pair makes the argument optional, so a fully-defaulted module renders standalone.
- `import` system that searches `lib/components/` then `lib/modules/`, project-local then shared.
- Stable identity via auto-generated 8-char hex `(id …)` markers, flushed back to disk on build.
- **Structural control flow** — `when`, `unless`, `if`, `for` and `repeat` expand into whatever the enclosing design scope accepts, so a whole sub-circuit can be conditional or repeated. Each carries a source-resident `(id …)` anchor so the parts it generates keep their identity across an edit.
- **Autoloaded sidecars** — `<design>.checks.sexp`, `.layout.sexp` and `.diagram.sexp` are spliced into the `(design-block …)` body without an import, so verification records and physical declarations live beside the circuit rather than inside it. `netlisp tool split-design` performs the split, refusing any write whose netlist or design-scope form set changes.
- **Assembly variants** — `(variant "NAME" …)` plus `(only-in …)` / `(dnp-in …)` / `(value-in …)` on an instance; one board, several build configurations.
- **Anonymous wiring** — `(connect …)` names a node by its ends and `(chain …)` states a whole cascade in order, instead of inventing an identifier for every node in a signal chain.
- **Interface bundles** — `(interface …)` defines a named signal vocabulary (SPI, I²C, UART, SWD, JTAG), `(port-group …)` declares a module boundary from it, and `(bridge-interface …)` wires a sub-block's group to board nets. ERC holds a group to a both-or-neither rule.
- Bus shorthand for wide pin groups (`(bus "FLASH_IO" T19 P19 V19 …)` → `FLASH_IO0`, `FLASH_IO1`, …), indexed net ties (`bus-net`), indexed ports (`bus-port`) and one-line differential pairs (`diff-port`).
- Decoupling shorthand (`(decouple …)` auto-generates per-pin sub-nets and cap instances).
- **Typed attributes** — a family instantiation takes bare or keyed attributes interchangeably: `(cap-0402 "1uF" x7r "10%" "25V")` and `(cap-0402 "1uF" (dielectric x7r) (tolerance 10%) (rating 25V))` mean the same thing.
- **Design-owned rules** — `(requirement … (on "REF") (check …))` and `(net-rule … (nets …) predicate…)` let a board state, and then gate on, the rules its own author wrote down, alongside the datasheet requirements a library part carries.
- **Module envelopes** — per-net worst-case DC voltage envelopes that reach *inside* a module, so a part's rating can be checked against the potential its copper actually sees rather than only the top-level rail.
- **Physical declarations** — `(board …)` (outline, edge hardware, named keepouts, heatsink and fan), `(stackup …)`, `(net-class …)`, `(pcb-plan …)`, `(design-rules …)`, `(pdn …)`, `(module-policy …)`, `(power-plane …)`: the layout intent the placer, router and DRC read.
- **System contracts** — `(system …)` declares which boards form a product, which connector contacts join them, and which documents belong to the release.

`netlisp reference [section]` prints the authoritative grammar out of the
binary; it is the same content as `language-forms.md`, generated from the
evaluator's own dispatch tables, so it cannot drift from what the parser
accepts.
- Section opt-out from the block-diagram view: `(diagram hidden)` for sections like test points and fiducials.

### Schematic rendering

Server-rendered HTML page with inline SVG.

- **Hub-and-spoke topology.** ICs/connectors/transistors are hubs (rendered as boxes on a row/col grid). Passives (R/C/L/F/D) are spokes — drawn inline on the wire between two hubs.
- **Functional-view returns.** A single series R/L on the edge row of a pin group whose far end is another pin group of the same hub, on the same side and immediately adjacent, turns vertical on the pin-stub column and lands on that group's nearest stub (a pull-up from a control pin to the IC's own filtered rail, a bias inductor into the RF input). Signal nets always qualify; a supply rail qualifies when it is private to that hub, or when the destination group is where THIS hub makes the rail (an `OUT` / `OUTS` / `VOUT` pin) — a regulator's power-good pull-up and its feedback divider's upper leg draw into the output node they sense. A pull-up to a shared rail the hub merely consumes keeps its label, because that label is what lets the reader find the rail elsewhere. Two returns turning onto one output row name that rail once. Rows are ordered so such a return sits on the edge nearest its destination, and an outside direct-return lane is pushed clear of any net label on the rows it spans. Sub-block path prefixes (`dsa/VDD_F`) are stripped before a net is classified as supply or signal.
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

A structured per-design TODO log, stored as `<design>.notes.md` next to the design source. Each note carries an 8-char hex ID, body text, UTC `created_at` / `completed_at` timestamps, and an open/done state. Surfaced in the schematic viewer's notes panel and through CLI tools (`list_design_notes`, `add_design_note`, `complete_design_note`, `reopen_design_note`, `remove_design_note`). Distinct from `(note …)` forms inside `.sexp` source — design notes are a workflow scratchpad outside the netlist, meant for "follow up before tape-out" items that wouldn't make sense as ref-des-attached annotations.

### Electrical-rule checks (ERC)

A post-build pass over the resolved design block. ERC is one input to the
unified finding model in `src/preflight.zig` — `netlisp check`, `netlisp build`
and the `run_checks` tool all consume that model, so none of them can disagree
about a design's status, and the **check profile** decides which findings gate.
The complete list of ERC finding kinds is `erc.ViolationKind` in `src/erc.zig`;
the ones worth naming here:

| Check | What it catches |
| --- | --- |
| `duplicate_refdes` | Two instances with the same ref-des. |
| `pin_multi_net` | A single pin connected to two different nets. |
| `floating_net` | A net referenced by zero instances (dangling wire). |
| `unconnected_pin` | A section port that no instance drives, or a power/ground pin not connected. |
| `missing_value` | An R/C/L instance with no value. |
| `missing_footprint` | An instance whose component has no footprint assigned. |
| `missing_decoupling` | A power pin lacking a nearby bypass cap. |
| `invalid_emi_coupling` | An `(emi-couples …)` capacitor does not bridge its declared domain to ground or conflicts with decoupling intent. |
| `voltage_mismatch` | A pin's expected voltage doesn't match the net's voltage rating. |
| `concept_remaining` | A section still marked `concept` — design-readiness reminder. |
| `power_budget` | A net's current draw exceeds a declared rating. |
| `pin_function_unsupported` | A pin's `(as "FN")` assertion names a function that isn't in the pinout's primary + alts list. |
| `pin_function_required` | A pin whose pinout entry has ≥ 2 alts was wired without an `(as …)` to disambiguate. (Pins with exactly one alt auto-fill via `pin_enrichment` and don't trigger this; pins with no alts don't need one.) The pinout lookup is dual-keyed by BGA position *and* logical name, so `(pin H4 …)` and `(pin PC13 …)` both resolve. |
| `interface_half_connected` | A `(port-group …)` whose lanes were partly wired — SCK and MOSI connected, CS left open. Lanes marked `optional` are never demanded. |

Three kinds are **informational** — they never fail `netlisp check` and no
profile escalates them, because each surfaces a decision the tool made on the
author's behalf rather than a fault:

| Check | What it surfaces |
| --- | --- |
| `layout_class_inferred` | A net whose PCB-layout criticality class was guessed from its name. Pin it with `(module-policy (placement-class "NET" <class>))`. |
| `section_category_inferred` | A section whose system-overview category was guessed from a keyword in its name. Pin it with `(category <key>)` in the section body. |
| `deprecated_form` | A superseded spelling, with the `file:line:col` of the form and the spelling that replaces it. Old spellings keep working; this is the only place they are reported, deliberately NOT as an evaluator warning (the release profile turns those into errors). |
| `interface_naming` | A module declaring two or more ports out of one interface's naming vocabulary without a `(port-group …)`, with the exact line that would replace them. Deliberately INFO, not a warning: "you could have written this more compactly" must never fail a release. |

The `power_no_cap` violation kind exists in the enum but isn't currently invoked from the runner.

### PCB layout

The board is solved from the same evaluated design, and every stage is
reachable from the CLI, the `/pcb-layout/:name` page and a structured tool.

- **Placement** — a force-directed relaxation over the parts (`src/placement/optimizer.zig`). Decoupling caps are pulled edge-to-edge onto the pad pair that closes their hot loop; authored `(group …)` islands, port sides, connector edges and `(pcb-plan …)` zones steer the rest. `set_part_poses` overrides any of it by hand.
- **Routing** — a grid maze router (`src/placement/router.zig`) over a rasterised board, with a rip-up/rescue ladder, differential-pair routing, escape-lane assignment for fine-pitch pads, waypoint seeding and octilinear cleanup. Priority tiers from `(net-class …)` decide who routes first. `add_tracks` draws copper by hand when the router cannot.
- **Copper** — real computed pours and planes on a signed-margin field (`src/placement/pour.zig`), one fill shared by the exporter, the connectivity oracle and the viewer, so nothing can disagree about what is connected. Plane stitching, ground-via seeding and RF ground **via fencing** (`(net-class … (fence …))`) generate their vias after placement and routing have settled.
- **Rules** — track widths derived from a target impedance against the declared `(stackup …)` (microstrip, stripline, coplanar and coupled variants, each with its own solver in `src/placement/impedance_*.zig`); per-branch power widths and via currents solved from the design's own current declarations; length-matched groups; return-path and loop-area audits.
- **DRC** — a geometric post-route check (`src/placement/drc.zig`): clearance between every copper pair on different nets, drill, edge, courtyard, mask, silk, width, differential skew, keepout and board-keepout rules, reported with edge-to-edge gaps and coordinates.
- **Diagnosis** — `describe_pcb_layout` (facts), `get_pcb_layout_image` (PNG), `diagnose_net`, `routability_preflight`, `placement_sensitivity` and `compare_layout_to_starred` are the read-only surfaces an agent or a reviewer inspects the board through without a browser.

### Fabrication

- **Artwork** — Gerber copper/mask/paste/silk/edge layers (`src/export_gerber.zig`) plus Excellon drills and a pick-and-place centroid CSV (`src/export_fab.zig`). Together they are a complete manufacturing package with KiCad out of the loop.
- **Readiness gate** — `run_fab_readiness` / `GET /api/fab-readiness/:name` re-runs DRC and every other release obligation over the *same* blessed placement and persisted copper the export writes, so the check and the files always describe the same board.
- **Release lock** — a fab package binds the exact source, evaluated BOM identities, centroid mode, CAM digest, readiness result, DRC policy, design revision, project commit and tool build, so a confirmation token cannot authorise a changed board.
- **Panelize** — export-only panel geometry: repeated board artwork in a panel frame with either V-score guides or tab routing with mouse-bite drills. It never mutates the authored placement.
- **Handoff archive** — `POST /api/design-archive/:name` wraps the authorised fab ZIP byte-for-byte and adds the schematic, every evaluated source, the layout/BOM/check sidecars, a complete KiCad project and the full-board AP242 STEP model.

### Thermal

`(thermal …)` declarations drive two levels of answer. The lumped screen is
`Tj = Ta + P·θJA`, one part at a time — the right check before a package is
chosen. The board-level answer is a built-in steady-state 2D field solve over
the copper spreader (`src/placement/thermal_field.zig`) with a cooling-scenario
ladder (natural convection, forced airflow, an authored heatsink, a fan), a
`/thermal/:name` page, a PNG renderer and the `describe_thermal` tool. For an
independent check, `netlisp export-elmer-thermal` writes an Elmer FEM case and
`compare-elmer-thermal` runs it and reports the two side by side.

### Reviews and release gating

- **Checks with a profile.** `netlisp check --profile authoring|preflight|release` runs one finding model (`src/preflight.zig`) over ERC, executable component requirements, design-owned rules and datasheet-review records. `authoring` reports, `preflight` gates, `release` additionally demands the component-class review obligations and a cited requirement on every active part.
- **Board Review Audit.** `netlisp review-audit` / the `review_audit` tool generates a Markdown document a reviewer dispositions: the identity block with release token and digests, the release-profile check summary, one row per active part with its class profile and unmet items, the completion ladder, the fabrication gate with DRC counts by kind, open notes and a findings register.
- **Waiver register.** A release's DRC waivers are only evidence while their counts match the run that produced them; `src/waiver_register.zig` re-reads the register and compares.
- **System review.** `(system …)` contracts declare which boards form a product and which connector contacts join them. `netlisp system-check` reports readiness; `netlisp export-system-review` produces a watermarked ZIP with combined Markdown, a searchable PDF and a self-contained offline HTML dossier, and no fabrication CAM.

### Part sourcing

`lib/parts/<family>.sexp` tables resolve a parameterised request (family +
value + attributes) to a concrete manufacturer part for the BOM. Beyond the
local tables, three read-only tools reach live catalogues — `resolve_mpn` and
`check_stock` (DigiKey Product Information API: manufacturer part numbers,
datasheet URLs, stock and the full price-break ladder) and `search_components`
(Component Search Engine) — and four mutating ones import what they find:
`download_footprint` (component + footprint + pinout + 3D model),
`download_datasheet`, `fetch_datasheet` (an explicit manufacturer URL, content
-sniffed and refusing a silent replacement) and `attach_datasheet`. Credentials
are read server-side from the environment and never travel over the CLI.

### Design-review report

Generated as a Markdown report plus CSV attachments, downloaded as a review
package from `GET /api/export-review/:name`. `netlisp export-pdf` renders the
same document as a PDF. The former interactive review page and review JSON
endpoint are no longer served. Report sections include:

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

| Format | Command / endpoint |
| --- | --- |
| Flattened post-eval `.sexp` | `netlisp build` |
| KiCad netlist (legacy `.net`) | `GET /api/export-netlist/:name` |
| KiCad project — netlist + footprints + STEP models, `--with-schematic` adds the `.kicad_sch` hierarchy and project sidecars | `netlisp export-kicad`, `GET /api/export-kicad/:name` |
| Hierarchical KiCad schematic on its own (root sheet + one per section/module, `sym-lib-table` / `fp-lib-table` / `.kicad_pro`) | `netlisp export-kicad-sch`, `GET /api/kicad-sch/:name` |
| BOM CSV | `GET /api/export-bom/:name` |
| Review markdown + CSV bundle (.zip) | `GET /api/export-review/:name` |
| Design-review PDF | `netlisp export-pdf` |
| Schematic PNG (headless) | `netlisp export-schematic-png` |
| Gerber + drill + centroid fabrication package | `GET /api/pcb-gerbers/:name`, gated by `GET /api/fab-readiness/:name` |
| Complete engineering handoff archive | `POST /api/design-archive/:name` |
| Firmware pin map (C header or JSON) | `netlisp export-pinmap`, `export_pinmap` tool |
| Flattened SPICE deck (no models, no parasitics) | `netlisp export-spice`, `export_spice` tool |
| Elmer FEM thermal case | `netlisp export-elmer-thermal` |
| System review ZIP — Markdown + PDF + offline HTML dossier | `netlisp export-system-review` |
| MATLAB RF export | `GET /api/pcb-matlab-rf/:name` |
| Board / full-assembly STEP | `POST /api/pcb-step/:name` |

### Web server (`netlisp serve`)

Default bind `127.0.0.1:7050` (`http://localhost:7050`); `--bind`/`--allow-remote` widen that for a deployment behind a reverse proxy.

[`webserver-api.md`](webserver-api.md) is the canonical route reference; this
is the shape of it.

**Pages.** `/` (design list), `/schematics/:name` and `/modules/:name` (board
and module schematics), `/pcb-layout/:name` (2D and `?view=3d`),
`/review/:name` (board review), `/systems/:name` (+ `/cad` and `/dossier`),
`/assembly-debug/:name`, `/thermal/:name`, `/library`,
`/library/footprint/:name`, `/library/3d/:footprint`, `/route-review`, and
`/pdf-view/:filename`. `/modules` and the retired `/pcb-route-lab/:name`
redirect into those current surfaces. The datasheet viewer loads its pinned
PDF.js runtime and worker from the embedded same-origin static registry, so it
has no CDN dependency. There are no sign-in or account pages: netlisp has no
accounts (see **Authentication & authorisation**).

**Read APIs.** Design and library metadata (`/api/designs`,
`/api/scene-graph/:name`, `/api/pinout/:name`, `/api/footprint/:name`,
`/api/datasheets`), findings (`/api/erc/:name`, `/api/fab-readiness/:name`),
board data (`/api/pcb-png/:name`, `/api/pcb-describe/:name`,
`/api/pcb-gerbers/:name`, `/api/thermal/:name`), review state
(`/api/board-review/:name`, `/api/board-review-audit/:name`,
`/api/systems/…`), and the live-update counter `/api/version/:name`.

**Mutation APIs.** `POST /api/push/:name` (rebuild + bump version), the
source-edit seam (`/api/edit-value/:name`, `/api/section-note/:name/…`), the
library uploads (`/api/upload-{datasheet,symbol,footprint}`,
`/api/component-datasheet/:component/…`), the board write path
(`/api/pcb-route/:name`, `/api/pcb-drc/:name`, layout save/restore,
`/api/pcb-step/:name`), and the KiCad sync endpoints below.

**Export APIs.** Listed in the Exports table above.

**Structured CLI tools.** The former remote tool transport is local-only now:
`netlisp tool list` prints every tool and JSON schema, while
`netlisp tool <name> --args '<json>'` invokes one against `--project-dir`.

### Authentication & authorisation

netlisp is a **local tool**: no accounts, no sessions, no external auth service. The whole model lives in `src/serve/auth.zig`, whose `authMiddleware` gates every request before dispatch. Full reference: [docs/auth.md](auth.md).

- **Loopback is admin.** A request whose *TCP peer* is loopback and which no reverse proxy relayed (no `Forwarded` / `X-Forwarded-*` / `X-Real-IP` header) acts as the `local` admin. Locality is derived from the connected socket, never from a header.
- **Everything else is `403`** — JSON on `/api/`, plain text elsewhere — naming `--allow-remote` in the body.
- **Plugin tokens (bearer).** For KiCad sync API clients — minted via `netlisp mint-plugin-token`, hashed into `plugin_tokens.json` under the auth dir, and accepted on `POST /api/sync-kicad-pcb/*` alone.
- **Public routes.** `GET /healthz` (a fixed liveness body for deployment probes) and `/static/*`.
- **Deployments.** `netlisp serve --bind <addr>` (default `127.0.0.1`) widens the socket; `--allow-remote` (or `NETLISP_ALLOW_REMOTE=1`) makes **every** request an admin. That combination is only correct behind a reverse proxy that is itself authenticating callers — netlisp lends it no auth of its own.
- **Roles.** `admin` / `writer` / `reader` still gate the review and system surfaces; an admitted request is `admin`, and the plugin-token sync path stays at the default `reader` because the token authorizes a route rather than an identity. Local CLI tools run with the invoking user's filesystem authority.

### Structured CLI tools

Exposes the project to local agents and scripts without a running server. Each
tool declares a JSON input schema and is flagged read-only or mutating; the
registry lives in `src/serve/mcp_tools.zig` and `netlisp tool list` prints it.
The buckets, with a representative tool or two each:

| Bucket | Read-only | Mutating |
| --- | --- | --- |
| **Project / library** | `list_designs`, `list_library`, `list_history`, `list_instances`, `list_free_pins`, `get_net`, `describe_component`, `get_schematic`, `get_schematic_image`, `get_version` | — |
| **Checks and review** | `run_checks`, `review_audit`, `review_checklist`, `review_datasheet_inventory`, `run_fab_readiness` | `record_review_item` |
| **PCB inspection** | `describe_pcb_layout`, `get_pcb_layout_image`, `diagnose_net`, `get_layout_progress`, `routability_preflight`, `route_experiment`, `placement_sensitivity`, `compare_layout_to_starred`, `preview_escape_assignment`, `describe_thermal` | — |
| **PCB editing** | — | `set_part_poses`, `set_board_outline`, `route_pcb`, `add_tracks`, `set_copper_zones`, `close_open_nets`, `clear_routes`, `clean_route_topology`, `normalize_junctions`, `repair_land_transit`, `stitch_ground_pads`, `generate_fence`, `save_pcb_layout`, `restore_layout_snapshot` |
| **Language / modules** | `get_language_reference`, `preview_module` | — |
| **Source files (VFS)** | `read_file`, `list_dir`, `glob` | `write_file`, `edit_file`, `delete_file`, `move_file` |
| **Build / state** | — | `build`, `regenerate_pinout`, `restore_version` |
| **Source rewriting** | — | `rewrite-pins-by-name`, `split-design` |
| **KiCad interop** | `parse_kicad_netlist`, `inspect_kicad_layout`, `benchmark_kicad_routing` | `import_kicad`, `export_kicad_sch`, `sync_kicad_sch` |
| **Hand-off exporters** | `export_pinmap`, `export_spice` | — |
| **Part sourcing** | `search_components`, `resolve_mpn`, `check_stock`, `read_datasheet` | `download_footprint`, `download_datasheet`, `fetch_datasheet`, `attach_datasheet` |
| **Notes and requirements** | `list_design_notes`, `list_component_requirements`, `list_route_trials` | `add_design_note`, `complete_design_note`, `reopen_design_note`, `remove_design_note`, `add_component_requirement`, `remove_component_requirement`, `record_route_trial`, `remove_route_trial` |

Three design choices worth calling out:

- **No granular schematic-edit tools.** There is no `add_component` / `swap_component` / `rewire_pin`. Edits flow through `read_file` → `edit_file` → `build`. This keeps the source file the single source of truth and avoids divergent representations.
- **Mutation tools return `live_version`.** The browser's 2-s poll of `/api/version/:name` picks up the change without any extra wiring.
- **Read-only means read-only.** `route_experiment` routes a whole board and never persists it; `export_pinmap` and `export_spice` return the exported text and write no project file. The split is what lets a reader role and an automated loop share one surface.

See [`agents.md`](agents.md) for how to drive this from an agent.

### KiCad interop

The schematic is canonical in every direction; KiCad holds the board.

**Push the netlist to a board.** `POST /api/sync-kicad-pcb/:name` (the schematic
viewer's **Push to KiCad PCB** button) reads the `.kicad_pcb` declared by the
design's `(kicad-pcb "<path>")` form — or the project's
`kicad-projects.sexp` mapping — diffs the on-disk board against the flattened
netlist, and applies the resulting ops (`add`, `set_field`, `set_pad_net`,
`swap_footprint`, `remove`, `flag_stale`) to the file in place. `?dry_run=1`
returns the diff without writing; `?migrate=1` enables the heuristic relink;
`?prune=1` turns `flag_stale` into real removals. Footprint UUIDs, pad
netlists, field values, board origin and placement coordinates are preserved,
and new instances land in a per-section staging area until they are placed.

**Push the schematic.** `netlisp export-kicad --with-schematic` (or
`export-kicad-sch`) writes a hierarchical `.kicad_sch` — one sheet per
section/module — plus `sym-lib-table`, `fp-lib-table` and a `.kicad_pro`, so
the output directory opens as a complete KiCad project. `netlisp sync-kicad-sch`
pushes it into an existing KiCad project directory, refusing a hand-drawn sheet
or a locked project and rolling replaced files into `backups/`.

**Import.** `netlisp import-kicad <board.kicad_pcb>` migrates an existing board
into a netlisp project — modern KiCad embeds the flattened netlist, pin
functions, footprint geometry and BOM properties in the board file, so no
schematic tracing is needed. `netlisp import-kicad-layout` brings a routed
board's placement, outline, tracks, vias and copper back in as the design's
starred layout, leaving the `.kicad_pcb` untouched. `netlisp inspect-kicad` and
`route-kicad-reference` read a board as a read-only routing reference.

> A standalone Go IPC agent (driven from inside KiCad over an NNG protobuf socket, posting to a now-removed `/api/sync-plan` endpoint) previously did the board sync. It was removed in favour of the file-based path above.

### Conversion tools

- `netlisp convert-footprint <file.kicad_mod>` — KiCad footprint → `.sexp`.
- `netlisp convert-symbol <file.kicad_sym> [--filter <name>]` — KiCad symbol → `.sexp`.
- `netlisp convert-pinout <file.kicad_sym> [--filter <name>]` — extract pinout (pin → function) only.
- `netlisp convert-package <sym.kicad_sym> <fp.kicad_mod> [--name <name>] [--filter <f>]` — combine symbol + footprint into a package.
- `netlisp merge-alt-functions <pinout.sexp> <alts.csv|alts.xml> [--write]` — enrich a pinout with alternate-function metadata from a vendor CSV/XML.

### Live-update loop

```
edit .sexp file
   ↓
netlisp build --push <name>
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
my-board/
├── src/                          # designs (flat, or one directory per design)
│   └── my-board/
│       ├── my-board.sexp         # the design — the only file you write by hand…
│       ├── my-board.layout.sexp  # …plus these three optional authored sidecars:
│       ├── my-board.checks.sexp  #   physical / verification / diagram
│       ├── my-board.diagram.sexp #   declarations, autoloaded into the design
│       ├── my-board.bom          # generated: resolved part identities
│       ├── my-board.layouts.json # generated: named saved board layouts
│       ├── my-board.notes.md     # generated: per-design TODO log
│       └── my-board.trials.json  # generated: routing trial memory
├── lib/                          # optional; overrides the bundled stdlib per name
│   ├── components/               # fixed parts
│   ├── modules/                  # parameterised compositions
│   ├── parts/                    # family → manufacturer-part tables
│   ├── symbols/                  # raw KiCad symbols (uploaded)
│   ├── footprints/               # land patterns
│   ├── pinouts/                  # pad → function lookups
│   └── datasheets/               # PDFs
├── src/systems/<system>/         # optional: (system …) release contracts
├── kicad-projects.sexp           # optional: design name → .kicad_pcb path
├── history/                      # generated: per-design version snapshots
├── logs/                         # generated: interaction log
└── auth/
    └── plugin_tokens.json        # KiCad-sync bearer tokens (netlisp_p_*)
```

The generated sidecars are the tool's output, not your source: never hand-edit
them. (`plugin_tokens.json` is the only auth sidecar netlisp has — there are no
users, sessions, invites or OAuth clients to store.) `history/` and `logs/`
appear once a project is served or laid out and are usually git-ignored.

KiCad sync writes the declared `.kicad_pcb` directly and does not maintain netlisp
sidecars beside it. KiCad may create transient project lock files while pcbnew
has the board open:

```
<board-dir>/
├── Board.kicad_pcb
└── ~Board.kicad_{pcb,pro}.lck         # KiCad's project lock files (transient)
```

**`(import …)` resolution.** Each name is resolved as `lib/components/<name>.sexp` then `lib/modules/<name>.sexp`, in `--project-dir` first then in the shared library directory (if configured). A file is identified as a *component* iff its first top-level form is `(component …)` or `(component-family …)` — otherwise it's a *module*. The same name can't be both.

## 6. CLI command map

`netlisp help` prints the authoritative list with every flag. Grouped by what
you are doing:

| Group | Commands |
| --- | --- |
| **Evaluate and check** | `parse`, `build`, `check [--profile authoring\|preflight\|release] [--variant V]`, `system-check`, `review-audit` |
| **Query a design (JSON)** | `designs`, `instances`, `net`, `free-pins`, `schematic`, `describe`, `library`, `power-flow`, `netlist-dump` |
| **Language** | `reference [section]`, `gen-language-docs [--check]` |
| **Structured tools** | `tool list`, `tool <name> [--args JSON\|--args-file F] [--output F]` |
| **Serve** | `serve [--port 7050] [--bind 127.0.0.1] [--allow-remote]`, `mint-plugin-token` |
| **KiCad** | `export-kicad [--with-schematic]`, `export-kicad-sch`, `sync-kicad-sch`, `import-kicad`, `import-kicad-layout`, `inspect-kicad`, `route-kicad-reference` |
| **Layout sidecars** | `backfill-layouts`, `merge-layout` |
| **Export** | `export-pdf`, `export-schematic-png`, `export-pinmap`, `export-spice`, `export-system-review`, `gerber-dump` |
| **Thermal** | `export-elmer-thermal`, `compare-elmer-thermal`, `bench-thermal` |
| **Convert a KiCad library file** | `convert-footprint`, `convert-symbol`, `convert-pinout`, `merge-alt-functions` |
| **Benchmark** | `bench-page` |
| **Misc** | `version`, `help` |

Library resolution flags (`--lib-dir`, `NETLISP_LIB_DIR`, `NETLISP_STDLIB_DIR`)
apply to every command; see [`standard-library.md`](standard-library.md).

(There is no user/invite/password management: netlisp has no accounts. The old `mint-invite` and `set-password` commands are gone.)

## 7. Where the exhaustive lists live

This document names capabilities, not every route, flag and schema — those
change with the code and are documented where they cannot drift:

| Surface | Authoritative source |
| --- | --- |
| Every HTTP route, with request/response shapes | [`webserver-api.md`](webserver-api.md) |
| Every structured tool and its JSON schema | `netlisp tool list` (and the prose in [`webserver-api.md`](webserver-api.md) → "Structured CLI tools") |
| Every CLI command and flag | `netlisp help` |
| Every language form, operator, directive and suffix | `netlisp reference [section]` — the same content as [`language-forms.md`](language-forms.md), generated from the evaluator's dispatch tables and checked stale on every build |
| Every bundled component and how overrides resolve | [`standard-library.md`](standard-library.md) |
| The auth model in full | [`auth.md`](auth.md) |
| Driving all of the above from an agent | [`agents.md`](agents.md) |
