# Driving netlisp from an agent

**What this is:** the page to read if you are an AI coding agent working on a
board, or a person setting one up to. netlisp was built to be driven this way —
the design is text, every operation has a JSON schema, and nothing needs a
browser or a running server. This page covers the structured tool CLI, the
grammar dump, what a design repository looks like, and a `CLAUDE.md` you can
drop into your own.

If you are instead working on the netlisp *tool* itself — the Zig source in
this repository — read [`../CONTRIBUTING.md`](../CONTRIBUTING.md),
[`../AGENTS.md`](../AGENTS.md) and [`worktrees.md`](worktrees.md); the rules
there are enforced by the build, not by convention.

For the shape of the whole workflow, [`schematic-design-workflow.svg`](schematic-design-workflow.svg)
sketches it end to end: brief → component sourcing → datasheet-derived
requirements → reusable subcircuits → integration → preflight review.

## The structured tool CLI

```bash
netlisp tool list                      # every tool, description and JSON input schema
netlisp tool <name> --project-dir <d> --args '<json>'
netlisp tool <name> --project-dir <d> --args-file request.json --output result.png
```

`tool list` is the contract: it prints one entry per tool with a JSON Schema
for its arguments, so an agent can discover the surface rather than being told
it. There are 84 tools as of v0.1.0. Text results go to stdout; image tools
return base64 JSON unless `--output` is given, in which case they write decoded
bytes (`--output -` writes to stdout). Use `--args-file` when the request is
large — a copper-zone polygon set, a batch of poses.

None of this needs `netlisp serve`. The same handlers back the HTTP routes, so
an agent and a browser looking at the same design always see the same answer.

### Read-only versus mutating

Every tool is flagged one way or the other in the registry, and the split is
load-bearing rather than advisory:

- **Read-only tools never write a project file.** That includes some expensive
  ones: `route_experiment` routes a whole board request-locally and persists
  nothing; `run_fab_readiness` re-runs DRC over the saved copper;
  `export_pinmap` and `export_spice` return the exported text itself, so
  `--output pinmap.h` writes a usable header without the tool touching your
  tree.
- **Mutating tools** edit `.sexp` sources, the layout sidecar, the notes
  sidecar or the library, and return the new `live_version` so a running
  browser picks the change up on its next poll.

An agent loop that is exploring should stay entirely in the read-only half. The
practical rule: read with `describe_*` / `list_*` / `get_*` / `run_checks`,
decide, then make exactly one mutation and re-read.

### The tools you will actually use

**Understand the design.** `list_designs`, `list_instances` (add `variant` to
select an assembly variant), `get_net`, `list_free_pins`, `describe_component`,
`get_schematic`, `get_schematic_image`, `list_library`.

**Check it.** `run_checks` takes a `profile`:

| Profile | Behaviour |
| --- | --- |
| `authoring` (default) | Reports pending, manual and legacy review gaps as warnings. What you want while iterating. |
| `preflight` | Gates them as errors. The bar a design must clear before layout or handoff. |
| `release` | Preflight plus the component-class profile obligations (`profile_incomplete`), a cited requirement on every active part, and evaluator warnings as findings. |

The result carries `assertion_failures`, `erc`, `findings`, `preflight_ok` and
the error/warning counts. `build` accepts the same `profile` and refuses to
publish a new live version when a gating profile fails.

**Edit it.** There is deliberately **no** `add_component` / `swap_component` /
`rewire_pin` tool. Edits go `read_file` → `edit_file` (or `write_file`) on the
design's `.sexp`, then `build`. The source file stays the single source of
truth, and every edit is reviewable as a text diff. `edit_file` takes an
optional `expected_sha256` for compare-and-swap when several writers are live.

**Lay the board out.** The order that works:

```bash
P="--project-dir my-board"
netlisp tool set_board_outline $P --args '{"name":"my-board","rect":{"x":0,"y":0,"w":46,"h":30}}'
netlisp tool set_part_poses    $P --args '{"name":"my-board","poses":[{"ref":"U2","x_mm":25.0,"y_mm":17.0}]}'
netlisp tool route_pcb         $P --args '{"name":"my-board"}'
netlisp tool normalize_junctions $P --args '{"name":"my-board"}'
netlisp tool save_pcb_layout   $P --args '{"name":"my-board","layout_name":"routed","star":true}'
```

Poses are board millimetres with **y growing down**, and the coordinate is the
footprint's own origin. `add_tracks` draws copper by hand when the router
cannot close a net; `clear_routes`, `close_open_nets`, `repair_land_transit`,
`stitch_ground_pads`, `generate_fence` and `set_copper_zones` are the rest of
the write surface. `run_fab_readiness` is the gate that says whether the result
can go to a board house.

**Look at the board.** `get_pcb_layout_image` renders the layout as a PNG —

```bash
netlisp tool get_pcb_layout_image $P \
  --args '{"name":"my-board","route":true,"width":1200,"names":"ref"}' \
  --output board.png
```

Read the image. Coordinate JSON will not tell you that two connectors point at
each other or that a decoupling cap ended up on the wrong side of its IC.
Pass `nets` and/or `refs` to enter focus mode: the named nets and parts are
spotlighted while everything else dims, which is how you study one subsystem in
context. `describe_pcb_layout` is its textual twin, built from the identical
placement, so the picture and the facts can never disagree; add `pads:true`
when you need the full obstacle set. `diagnose_net` explains one net,
`get_layout_progress` reports the completion ladder, and
`routability_preflight` finds geometrically doomed routing before any router
runs.

**Iterate on routing without persisting.** `route_experiment` scores a plan
edit and names the still-open nets; `record_route_trial` / `list_route_trials`
keep a memory of what you already tried so a loop does not oscillate between
two reverted edits.

**Source parts.** `resolve_mpn` and `check_stock` (DigiKey), `search_components`
(Component Search Engine) are read-only; `download_footprint`,
`download_datasheet`, `fetch_datasheet` and `attach_datasheet` import what you
chose. `read_datasheet` extracts text from an imported PDF so a
`(datasheet-review …)` can cite it.

**Hand it off.** `export_kicad_sch` / `sync_kicad_sch` for the schematic,
`export_pinmap` for a firmware header, `export_spice` for a deck, and the
`netlisp export-*` commands for everything else.

## The grammar, from the binary

```bash
netlisp reference                       # the whole language reference
netlisp reference "Design-scope forms"  # one section
netlisp tool get_language_reference --args '{"section":"Structural control flow"}'
```

This is generated from the evaluator's own dispatch tables, and `zig build`
fails when the committed copy ([`language-forms.md`](language-forms.md)) is
stale — so it cannot describe a form the parser does not accept, or miss one it
does. **Consult it before authoring or editing a `.sexp` file**, rather than
recalling syntax. The sections are:

Special forms · Structural control flow · Builtin operators · String formatting
directives · Numeric literals · Typed attributes on a family instantiation ·
Design-scope forms · Instance sub-forms · Sub-block sub-forms · Interface
sub-forms · Port sub-forms · Identity and layout markers · Section-name
classifier keywords · System contract forms · Component library fields ·
Thermal declarations · Requirement checks · Net-rule predicates · Datasheet
review preflight

The prose companion — why a form exists and how to use it well — is
[`sexp-language.md`](sexp-language.md).

## What a design repository looks like

A netlisp project is an ordinary git repository. The tool never needs to be
built inside it: `netlisp` is a compiled binary that reads the project through
`--project-dir`.

```text
my-board/
├── src/
│   └── my-board/
│       ├── my-board.sexp          # the design — you write this
│       ├── my-board.layout.sexp   # authored sidecar: board, stackup, net classes, PCB plan
│       ├── my-board.checks.sexp   # authored sidecar: verification records, datasheet reviews
│       ├── my-board.diagram.sexp  # authored sidecar: diagram layout and grouping
│       ├── my-board.bom           # GENERATED — resolved part identities
│       ├── my-board.layouts.json  # GENERATED — named saved board layouts
│       ├── my-board.notes.md      # GENERATED — per-design TODO log
│       └── my-board.trials.json   # GENERATED — routing trial memory
├── lib/                           # optional; overrides the bundled stdlib per name
│   ├── components/ modules/ parts/ symbols/ footprints/ pinouts/ datasheets/
├── src/systems/<system>/          # optional (system …) release contracts
├── kicad-projects.sexp            # optional: design name → .kicad_pcb path
├── history/                       # GENERATED — per-design version snapshots
└── logs/                          # GENERATED — interaction log
```

Three things about this that catch agents out:

1. **The three authored sidecars are autoloaded.** `<design>.layout.sexp`,
   `.checks.sexp` and `.diagram.sexp` are spliced into the `(design-block …)`
   body with no `(import …)`. They are yours to edit; a form works exactly the
   same in the sidecar as in the main file. `netlisp tool split-design` moves
   forms out of an overgrown `.sexp` into them, refusing any write whose
   netlist or design-scope form set would change.
2. **The generated sidecars are not.** Never hand-edit `.bom`,
   `.layouts.json`, `.notes.md` or `.trials.json` — they are tool output, and
   an edit to them is either overwritten or silently inconsistent with the
   source. Change the design and rebuild instead; use the layout tools for
   `.layouts.json` and the note tools for `.notes.md`.
3. **`netlisp build` writes to your source.** On the first build of a part that
   has no `(id …)`, the evaluator mints an 8-character hex id and splices it
   into the `.sexp` at the part's own source position. That id is the identity
   the BOM, the saved layout and the KiCad footprint all hang off, so it must
   be **committed**. A second build changes nothing — run `netlisp build` and
   `git status` should be clean. If ids are appearing on every build, something
   is discarding the write.

Commit `src/` and `lib/`. `history/` and `logs/` are runtime state and belong
in `.gitignore`.

## A `CLAUDE.md` for your own design repository

Drop this into the root of a board repository (`CLAUDE.md`, or `AGENTS.md` —
the content is the same) and adjust the names.

````markdown
# CLAUDE.md

This repository is a **netlisp design project**, not a software project. There
is nothing to compile: `netlisp` is an already-built binary that reads this
directory through `--project-dir .`.

## The loop

```bash
netlisp build --project-dir . <design>                       # evaluate, resolve the BOM, mint ids
netlisp check --project-dir . --profile preflight <design>   # gate: exits non-zero on an open finding
netlisp export-kicad --project-dir . --output-dir <out> --with-schematic <design>
```

1. Edit `src/<design>/<design>.sexp` (or one of its authored sidecars).
2. `netlisp build` — this both evaluates the design **and writes minted
   `(id …)` markers back into the source**. Commit them.
3. `netlisp check --profile preflight` — fix findings until it exits 0.
   `--profile authoring` is the lenient mode for mid-edit iteration;
   `--profile release` is the strict one before fabrication.
4. Export only after preflight is clean.

## Rules

- **Consult the grammar before writing a form.** `netlisp reference [section]`
  prints the authoritative language reference out of the binary; it is
  generated from the evaluator's dispatch tables and cannot be stale. Do not
  author a form from memory.
- **Never hand-edit a generated sidecar** — `<design>.bom`,
  `<design>.layouts.json`, `<design>.notes.md`, `<design>.trials.json`. They
  are tool output. Change the design and rebuild; use the layout and note tools
  for the rest.
- **The three authored sidecars are fair game** — `<design>.layout.sexp`
  (board, stackup, net classes, PCB plan), `<design>.checks.sexp`
  (verification and datasheet reviews), `<design>.diagram.sexp`. They are
  autoloaded into the design, so no `(import …)` is needed.
- **Ids are identity.** A part's 8-character `(id …)` is what ties it to the
  BOM row, the placed footprint and the routed copper. Never delete or
  re-key one by hand; a rename or a ref-des reshuffle is safe, an id edit is
  not.
- **Prefer the structured tools over ad-hoc parsing.** `netlisp tool list`
  prints every tool and its JSON schema. Read with `list_instances`, `get_net`,
  `describe_component`, `describe_pcb_layout`, `run_checks`; look at the board
  with `get_pcb_layout_image --output board.png` and actually read the image.
  Read-only tools never write a file.
- **Edit source through files, not through a schematic API.** There is no
  `add_component` tool by design: `read_file` → `edit_file` → `build`, so
  every change is a reviewable diff.
- **Commit `src/` and `lib/`.** `history/` and `logs/` are runtime state.

## Where things are

- `src/<design>/<design>.sexp` — the designs.
- `lib/components`, `lib/modules`, `lib/parts`, `lib/footprints`,
  `lib/pinouts`, `lib/datasheets` — this project's own library. It overrides
  the library bundled into the binary entry by entry, by name.
````

## Where to look next

- [`../examples/README.md`](../examples/README.md) — a complete twenty-part
  board taken from a clone to a KiCad project, one command at a time, with the
  exact tool calls that placed and routed it.
- [`sexp-language.md`](sexp-language.md) — the language, form by form.
- [`webserver-api.md`](webserver-api.md) → "Structured CLI tools" — the long
  prose on each tool, including the routing loop's failure semantics.
- [`architecture.md`](architecture.md) — what the tool does and how the stages
  fit together.
- [`standard-library.md`](standard-library.md) — what a project gets without a
  `lib/` of its own, and how overrides resolve.
