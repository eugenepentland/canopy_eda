# Build & Run

> Moved verbatim from CLAUDE.md (2026-08-19); linked from its Reference Docs section.

```bash
# Build
zig build

# Run tests (also runs the Guardian gate)
zig build test

# Regenerate the auto-generated language reference (docs/language-forms.md)
# from the evaluator's dispatch tables. `zig build` / `zig build test` FAIL
# when the committed file is stale, so run this after any DSL change.
zig build docs

# Start web server (default port 7050)
zig build run -- serve --project-dir projects/designs

# Dev server / feature review at production speed (~1.5x Debug at runtime).
# The pinned compiler emits ReleaseSafe through its self-hosted x86-64 backend
# in well under a minute; `-Dllvm` would take minutes, so do not add it.
# Give the side build its own prefix so it cannot overwrite the
# zig-out/bin/netlisp a running server or measurement is executing — and keep
# throwaway prefixes off /tmp: it has a per-user quota here and stale prefixes
# filled it once (2026-08-26), breaking every tool needing tmpfile space.
zig build --seed=1 -Doptimize=safe -p ~/.cache/netlisp/builds/my-prefix

# Build a design (stdout), --push sends to running server
zig build run -- build --project-dir projects/designs --push <design-name>

# IDENTITY IS PERSISTED AT WRITE TIME. Every part needs a stable `(id …)`
# (→ `uuidFromId` → its KiCad footprint/symbol uuid), and `eval/ids.generateId`
# is process randomness: an id that never reaches the source is a DIFFERENT id —
# and therefore a different uuid, and a missed `.bom` property carry-forward —
# on the next evaluation. So every surface that WRITES pins the ids its
# evaluation minted back into `src/<design>.sexp` before anything derives a uuid
# from them, through the one shared `id_insert.persistMintedIds` wrapper: the
# CLI `build`, the MCP `build` tool, every schematic-editor save / granular edit
# / history restore (`serve/edit.zig`'s `writeAndRebuild` + `rebuildAndPush` +
# `restoreDesignCore` tails, so every route sharing them is covered), the KiCad
# board sync (on a dry run too — the preview exists to show exactly what the
# write will do), and the CLI exporters below. The exporters mutate the source
# because they ALREADY write the `.bom` sidecar recording the id and uuid they
# resolved; pinning is what stops that sidecar naming a token no source carries.
# READ paths — the schematic page, the PDF / KiCad-sch HTTP exports, the MCP
# read tools — deliberately never write: after one build or save the ids are
# already in the file, so there is nothing left for a read to mint.

# Export KiCad netlist + footprints (handoff to KiCad's PCB editor).
# --with-schematic ALSO writes the .kicad_sch hierarchy + project sidecars, so
# the output directory opens in KiCad as a complete project (netlist,
# footprints.pretty/, models/, sheets, sym-lib-table, fp-lib-table,
# <name>.kicad_pro, netlisp.kicad_sym). Without the flag the output is
# byte-identical to what it has always been.
zig build run -- export-kicad --project-dir projects/designs --output-dir <dir> [--with-schematic]

# Export the design as a KiCad SCHEMATIC (.kicad_sch). Label-connected: every
# symbol pin gets a short wire stub ending in a global label carrying the
# flattened net name, so connectivity is correct by construction and placement
# is only tidy. Ref-des and net spellings come from the SAME flattener the
# netlist exporter uses and each symbol's (uuid …) is the instance identity the
# netlist's (tstamp …) and the board's footprint already carry.
#
# The SHORT connections are drawn as real wire instead: a bypass cap's power leg
# to the exact IC pad its `(decouples "IC" PIN)` (or a `(decouple … per-pin …)`
# key) names, and any net whose entire design-wide membership is 2-3 pins that
# landed in one cluster. Routes are orthogonal, on the 1.27 mm grid, and pushed
# out through escape lanes clear of the symbol's ring of stub ends and labels;
# a small net is drawn as a CHAIN (pin to pin) so each leg gets its own
# corridor, and a point where three wire ends meet carries a `(junction …)`.
# A drawn run keeps exactly ONE global label — the run's head — and its spokes
# drop theirs; drop them all and KiCad renames the net `Net-(U1-Pad3)`. Any
# connection with no clean route keeps today's label pair, so the drawing is
# never a risk to the netlist. Measured (2026-08-03): stm32n6 63 connections
# drawn, cyclops-analog 53, labstation 61, barracuda 30, rf-switch-8way 2, with
# `kicad-cli sch erc` still at 0 errors on all five.
#
# DECOUPLING CAPS ARE GANGED INTO BANKS instead, which is what a hand-drawn
# sheet does and what per-cap wires were getting wrong (they ran far across the
# page and crossed each other). Caps sharing an IC cluster, a rail and a ground
# are drawn in parallel between ONE horizontal rail wire and ONE ground wire —
# each standing on end, tapping both rails through a junction dot, ref-des and
# value read to its right — under a single global label naming the rail, a
# single GND power symbol, and a `Decoupling — <IC> · <RAIL>` caption. That one
# label replaces every member's own, and the bank replaces the point-to-point
# runs the wiring pass would otherwise have drawn to them. Both rails are cut
# into one wire per span so each tap is a real wire END (a wire ending on
# another's interior does not connect in KiCad), and the bank occupies ONE cell
# in its cluster's packing, sized to its label, its lead and one column per
# member. A cap qualifies when it is a `C`-prefixed two-terminal glyph with one
# leg on a ground-class net and the other on a rail it either declares it
# decouples or that reads like a supply (`pin_roles.isSupplyFn` /
# `rails.looksLikeRail` — no new naming rule); anything else, and any pair with
# only one member, falls back to its labels rather than to a drawing that would
# misstate it. Per-pin bypass stubs of one rail gang together, which is the
# same merge their shared collapsed label already made. Measured (2026-08-03):
# stm32n6 13 banks / 53 caps, barracuda 16/49, labstation 15/52,
# cyclops-analog 14/49, rf-switch-8way 1/3 — and runs longer than 25 mm, the
# ones a reader has to chase, drop 103→76 on stm32n6, 80→46 on cyclops-analog,
# 42→34 on barracuda, with wire crossings 151→121 across the five boards.
#
# A SYMBOL'S SAME-NET PINS ARE GANGED. A rail that lands on fifteen of an MCU's
# pads used to draw fifteen ground symbols in a row (printing "GNDGNDGNDGND…")
# and a supply on six pads six stacked hexagons. Now the pads of one net on one
# edge are joined by a single wire running along that edge through their stub
# tips, a junction dot at every interior tap, and ONE adornment for the whole
# run — one global label, or one `#PWR` ground symbol plus the existing
# PWR_FLAG machinery. A gang never leaves its own symbol's edge, so two gangs on
# one net are two independent runs joined by the label each keeps, exactly as
# the separate labels joined them before; the netlist is unchanged (the oracle
# reports the same components and nets it did before ganging).
#
# Membership is strict because a global label attaches to ANY wire its anchor
# lies on, interior included: a foreign pin's tip caught between two members
# would pull its net into the gang. So `src/kicad_sch/shape.zig` re-slots each
# edge to put one net's pads side by side (first-appearance order, so it stays
# deterministic), and `src/kicad_sch/gang.zig` re-checks the geometry it is
# handed — collinear tips, nothing foreign between them — and cuts a run in two
# rather than spanning an interloper. That makes it safe on a VENDOR body too,
# whose pin order nothing reorders. `verify.zig` backs the whole thing with a
# structural check that no global label sits anywhere but a wire's own end.
#
# Ganged pads also stop DRAWING their function names: fifteen `VSS_n` printed
# vertically into a body ten millimetres tall ran through each other and through
# the names coming in from the opposite edge. The gang's one label says what
# they are. The name stays in the file — only its font size is zeroed, which is
# the one spelling KiCad 10.0.1 honours (`(hide yes)` inside a pin's name
# effects parses and is then ignored; an empty name drops the pad's
# `pinfunction` from KiCad's netlist). The names that remain are kept apart
# structurally: a body is sized so the names running in from opposite edges
# cannot meet, a pin is drawn long enough to hold the pad number KiCad straddles
# across it, and a symbol's Reference/Value are anchored past its pins AND past
# the ring of labels hanging off that edge. Measured (2026-08-03) by the new
# text-overlap warning: the Cyclops core-system sheet went from 196 colliding
# text pairs to 1, stm32n6 as a whole 237 -> 1, labstation 121 -> 0, barracuda
# 105 -> 0, with `kicad-cli sch erc` still at 0 errors.
#
# A FINE-PITCH EDGE HAS ITS LABELS DEALT INTO TWO COLUMNS. A synthesised body
# puts its pins 2.54 mm apart, which leaves a whole line of air between one net
# label and the next; a VENDOR body owes nothing to that — the Hirose BK13H
# board-to-board connector on the Cyclops boards draws twenty pins per edge
# **1.27 mm** apart, and a label is drawn 1.27 mm tall, so forty net names came
# out stacked with no gap at all, each arrow outline through the next. Pin
# geometry is the vendor's and must not move (it is what the pads mean), so
# `src/kicad_sch/stagger.zig` makes the space OUTSIDE the body: every other run
# on that edge gets a longer stub, far enough to clear the widest label in the
# near column, so the adornments sit in two columns 2.54 mm apart. Three things
# make that safe rather than merely tidier — columns are dealt per contiguous
# same-net RUN (never per pin), so a gang's tips stay collinear and it still
# forms; a run's neighbours are always in the OTHER column, so a long stub never
# crosses a gang's wire; and the offset is measured with `emit.labelSpan`, the
# same rule the packer reserves cell width by. An edge already a line of text
# apart is left alone, which is every synthesised box and every vendor body on
# the usual pitch — the pass is a no-op for them, byte for byte. `gang.zig` cuts
# a net's run at a column change as well as at a foreign tip, so a net dealt into
# two columns still gangs each column's own stretch instead of losing both.
#
# Two smaller rules finish the same sheet. A pin whose function NAME only repeats
# its own pad number draws the number alone (a connector pinout names every
# contact after its own contact number, so the name was the same string printed
# twice, once outside the body and once in). And a pin's name and number are
# drawn at the size its edge's pin spacing leaves room for — two thirds of the
# spacing, capped at the standard 1.27 mm — because KiCad straddles a number
# across the pin on the row the pin sits on, so at 1.27 mm pitch forty full-size
# numbers were one vertical smear. Only a crowded edge shrinks; everything else
# keeps 1.27 mm. Measured (2026-08-03): the three Cyclops boards carrying that
# connector went from 22 / 11 / 22 colliding text pairs to **0**, with
# `kicad-cli sch erc` unchanged at 0 errors and the oracle unchanged.
#
# A HUB DISPLAYS ITS PART NUMBER. An IC or connector is read for its MPN — the
# one thing a reader cannot infer from the drawing — so a resolved `mpn` property
# is written as a VISIBLE `MPN` field one clear line under the symbol's Value,
# and the packer reserves that line plus the width the number needs either side
# of the origin. A PASSIVE is the other way round: `100nF` already is its
# identity, and `GRM155R71C104KA88D` under all fifty bypass caps would be noise,
# so a passive keeps its MPN as the hidden BOM field it has always been. The
# split is the exporter's own hub/passive one (`kicad_sch/plan.zig`) — the same
# rule that decides which parts head a cluster, not a sixth ref-des heuristic —
# and a part whose BOM resolved no number gains no field at all, visible or empty.
#
# EVERY EMITTED SHEET IS SCANNED FOR OVERLAPPING TEXT. `src/kicad_sch/textbox.zig`
# boxes every drawn string — captions, global labels, visible fields, pin names
# and numbers — at its final place and counts the colliding pairs, reported per
# sheet on stderr with an example and its coordinates. It is a WARNING and never
# a failure: the extents are estimates (one font size per character, measured
# off KiCad's own rendering) and a document KiCad reads perfectly must not be
# refused over an estimate. Treat the count as a ratchet — a placement change
# that raises it made the drawing worse.
#
# Passives are drawn as KiCad's OWN stock Device glyphs, not boxes: the narrow
# IEC rectangle for a resistor, two plates for a capacitor (the marked-plate
# variant for a polarized family), the four-arc coil for an inductor, the
# slashed parallelogram for a ferrite bead, triangle-plus-bar for a diode (with
# emission arrows for an LED), a probe circle for a test point. The geometry is
# transcribed into `src/kicad_sch/glyph.zig` as comptime constants — nothing is
# read from /usr/share/kicad at export time — quarter-turned where the stock
# symbol is vertical, since every placed symbol here sits at angle 0 with its
# labels running left and right. Pins keep the stock 3.81 mm reach (a multiple
# of the 1.27 mm connection grid) and pin numbers/names are hidden as stock
# passives hide them. The class comes from the component family name, then the
# declared `(symbol …)`, then the ref-des prefix; a part with the wrong pad
# count for its glyph, or any part with a vendor `lib/sources/*.kicad_sym`,
# keeps the old body — vendor passthrough always wins.
#
# Per-pin bypass-stub nets are LABELLED AS THEIR RAIL. netlisp's
# `(decouple … per-pin …)` shorthand carves a `<base>.<REF>.<PAD>` micro-net off
# a rail per bypassed pad (so the placer can measure each loop); KiCad has no
# notion of that, so the schematic labels every one of them `<base>` and they
# read as the one rail — a deliberate display merge. Detection is structural
# (`src/kicad_sch/stub.zig`): the name must split into three non-empty parts on
# its last two dots, the net must carry `REF`'s own pad `PAD` on a placed part,
# and a net named `<base>` must exist, so a design's genuinely dotted name
# (`3.3V_SENSE`) can never be folded. Only the drawn label changes — net
# identity for wiring, clustering and the design-wide pin census stays
# netlisp's own, and the netlist + file-based sync keep the split and stay the
# board authority. `scripts/verify_kicad_sch.sh` applies the same fold to the
# netlisp side of its diff, so the oracle still proves every other net exact.
# Measured (2026-08-03): stm32n6 folds 40 of its 41 dotted nets (the 41st is a
# rail whose trunk has no pins left, so no base net exists to fold onto).
#
# A design of any size comes out hierarchical: a root sheet plus one child per
# (section …) — drawing the section's own parts and the (sub-block …) modules it
# adopts, per diagram/membership, the same authority the review PDF uses — one
# sheet per unadopted module, and a trailing sheet for the rest. Small designs
# (<= 24 parts) stay flat; --flat forces that anywhere. Parts with an original
# lib/sources/*.kicad_sym are drawn from that real body (--no-vendor-symbols
# forces the synthesised box). Deterministic, and every emitted file is
# re-parsed and structurally self-checked before it is written.
#
# Children are written beside the root under the bare names its Sheetfile
# properties link to, so the whole export must land in ONE directory. The
# project sidecars land there too — sym-lib-table, fp-lib-table,
# <name>.kicad_pro, netlisp.kicad_sym — which is what makes KiCad resolve the
# netlisp: symbols and footprints: label noise on stm32n6 drops from 730 ERC
# violations to 2 (0 errors). An existing sidecar is KEPT, never overwritten.
# Footprint links resolve only once footprints.pretty/ (from export-kicad) sits
# beside the sheets — hence --with-schematic above for the complete package.
#
# Caveat inherited from KiCad: a netlist KiCad generates from this schematic
# escapes `/` in net names (usb/DP -> usb{slash}DP), so the exported schematic
# must not drive "Update PCB from Schematic" against a netlisp-synced board.
# netlisp's own netlist + file-based sync stay the board authority.
zig build run -- export-kicad-sch --project-dir projects/designs <design> [--output <root.kicad_sch>] [--output-dir <dir>] [--flat] [--no-vendor-symbols]

# WHERE THE BOARD PATH COMES FROM. Both the board sync and the schematic push
# below write into the KiCad project directory named by the design's board
# path. That path resolves in two places, project-level first:
#
#   1. <project-dir>/kicad-projects.sexp — a flat list of one entry per design,
#      `(kicad-pcb "<design-name>" "<absolute path to .kicad_pcb>")`. The design
#      name is the SOURCE FILE STEM, the same token `netlisp designs` prints and
#      every command takes, so `src/boards/barracuda/barracuda.sexp` keys on
#      "barracuda".
#   2. The design's own top-level `(kicad-pcb "<path>")` form.
#
# An entry in the file WINS over the in-source form, and supplies the target
# when the source declares none — which is the point: a machine path
# (/mnt/nas/kicad/…) is a property of this checkout, not of the schematic, so it
# can live outside the design and the source form can be dropped entirely. The
# in-source form keeps working unchanged and is still fine for a board whose
# path is stable everywhere the design is opened.
#
# The file is optional and fail-open: absent, unreadable, or holding a malformed
# entry, every design keeps whatever its own source declares. A file of
# machine-local paths must never be able to fail a build on a machine that does
# not have one. Keep it out of version control (or commit it deliberately, if
# every checkout really does share the paths).
#
#   ;; projects/designs/kicad-projects.sexp
#   (kicad-pcb "barracuda" "/mnt/nas/kicad/barracuda/barracuda.kicad_pcb")
#   (kicad-pcb "rds3"      "/mnt/nas/kicad/rds3/rds3.kicad_pcb")

# Push that same schematic INTO the LIVE KiCad project directory the design's
# board path names, so the KiCad project carries board AND
# schematic instead of the empty eeschema stub KiCad ships every new project
# with. The sheets are named after the KiCad PROJECT, not the netlisp design:
# `Cyclops Digital.kicad_pcb` gives `Cyclops Digital.kicad_sch` (what KiCad
# opens for `Cyclops Digital.kicad_pro`) plus `Cyclops Digital-<section>`
# children, so a second netlisp design pushed into the same folder cannot
# collide. Internally that is just the export run with the project stem as its
# design name — the one input that names the root, the children, the Sheetfile
# links and the .kicad_pro, so all four agree by construction.
#
# GUARDED. An existing sheet is replaced only when it is a previous netlisp
# push ((generator "netlisp")) or an empty eeschema stub (a (kicad_sch ...) with
# no placed symbol, sheet, wire, label or graphic — nothing to lose). Anything
# else refuses the WHOLE push by name and writes nothing; --force overrides
# that. A KiCad lock file (~<file>.lck) anywhere in the project directory
# refuses even with --force — close KiCad instead of pushing harder. Sidecars
# are treated as someone else's: an absent .kicad_pro / sym-lib-table is
# created and an existing one is never touched (a sym-lib-table with no netlisp
# row is reported with the exact line to paste), fp-lib-table belongs to the
# board sync and is left alone, and only netlisp.kicad_sym is regenerated.
# Replaced files roll into `backups/<name>.bak-<stamp>` beside the board (newest
# 10 kept) — the same convention the board sync uses. Everything is validated
# before anything is written and each file is staged under a temp name then
# renamed, so a failure cannot leave a torn set of sheets.
#
# CAVEAT, and it is why this is a read-only hand-off: KiCad escapes `/` in net
# names and netlisp deliberately labels each per-pin bypass stub as its rail, so
# a netlist KiCad generates from these sheets is NOT netlisp's netlist. Never
# run "Update PCB from Schematic" from them — netlisp's own netlist and the
# file-based board sync stay the board authority.
zig build run -- sync-kicad-sch --project-dir projects/designs <design> [--dry-run] [--force]

# Export the design-review document as a PDF (cover, ONE schematic sheet per
# section, validation appendix, power/test-point tables). Each section's hub
# blocks are shelf-packed into a 2D grid on its own sheet at one uniform scale,
# each cell captioned with its `(pins … (group "…"))` label, so a sheet reads
# like a hand-drawn schematic page instead of one block per row.
#
# Sheets are UNIFIED: the `(sub-block …)` modules a section owns (per
# `diagram/membership.attachedSubBlocks` — the same authority the schematic page
# renders its attached cards from) draw in that same grid, each cell captioned
# `<sub-block> - <module title>`. So a section whose hardware is sealed in a
# module shows name + subtitle + status + the module's schematic + its notes on
# one self-contained page, instead of prose here and drawing five pages later.
# Only single-instance modules attach — one instantiated more than once keeps its
# `(sub-block)` appendix entry with the `x N` caption rather than being drawn into
# each hosting section — and the appendix holds exactly what no section drew.
# Notes follow their circuit: a module's own `(note …)` entries render on the
# sheet that draws it (deduplicated against section notes repeating them), and a
# ref-anchored `(note "REF" …)` lands on the sheet declaring that ref, or in the
# validation appendix when no section does. A section with neither its own hubs
# nor an attached module still packs as a compact heading-plus-notes entry.
#
# Works on a design or a bare lib/modules module. Default look is the viewer's
# dark screen theme (dark page background included); `--theme light` swaps to the
# print palette for paper. Self-checks the composed bytes before writing.
zig build run -- export-pdf --project-dir projects/designs <design> [--output <file.pdf>] [--theme light]

# Migrate an existing KiCad board INTO netlisp (reverse direction). Reads the
# .kicad_pcb alone — modern KiCad embeds the netlist (per-pad nets), pin names
# (pinfunction), footprint geometry, and BOM properties (Value/MPN/DNP) right
# in the board file, so no schematic wire-tracing is needed. Maps standard
# passives onto existing component families (cap-0402, res-0805, an FB ref on
# an L_0402 footprint → ferrite-0402), generates lib/components + lib/pinouts
# + lib/footprints for everything else (never overwrites existing library
# files), and writes src/<name>.sexp keeping KiCad's ref-des, with sanitized
# net names (unconnected-* pads dropped, DNP parts annotated). Imported
# designs are flat — section/sub-block structure is post-import curation.
#
# --fold-channels: for channelized boards (CH1_*/CH2_*/… net families) the
# importer detects the repeated per-channel circuit (seed by indexed net
# families, grow through private auto-nets, verify structural isomorphism)
# and emits ONE lib/modules/<design>-<prefix>.sexp defmodule + a (sub-block
# "chK" …) per channel with (net "CHK_X" "chK/X") stitching; channels that
# deviate structurally stay flat and are reported. Original ref-des survive
# as comments on each sub-block line. --fold-prefix CH overrides detection.
# Module port names are dot-free (+5.0V → port +5_0V) — dotted nets collide
# with the <rail>.<ic>.<pad> bypass-stub convention. The schematic page
# renders identical repeated sub-blocks once ("sub-block ×7").
zig build run -- import-kicad <board.kicad_pcb> --project-dir projects/designs --name <design> [--title <t>] [--dry-run] [--fold-channels] [--fold-prefix <P>]

# Convert KiCad files
zig build run -- convert-footprint <file.kicad_mod>
zig build run -- convert-symbol <file.kicad_sym> [--filter <name>]
zig build run -- convert-package <sym.kicad_sym> <fp.kicad_mod> [--name <name>]
zig build run -- convert-pinout <file.kicad_sym>
```

## Deployment and release tooling (maintainer-only)

`.githooks/install.sh` with no arguments is the one setup command a contributor
runs: it points `core.hooksPath` at the tracked hooks and nothing else. The
deploy worker, the release gate, the systemd unit templates under `.githooks/`
and `systemd/`, the design-checkpoint timer and the push-side performance gate
are the maintainer's production machinery for the single-user box that serves
the live viewer — see [.githooks/README.md](../.githooks/README.md), which
lists exactly which files those are. Building, testing and running netlisp
needs none of them.
