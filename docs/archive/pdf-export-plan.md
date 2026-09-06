# Schematic PDF Export — Implementation Plan

Goal: `netlisp export-pdf <design>` (plus a `⤓ PDF` button on the schematic
page) produces a single self-contained, emailable PDF a customer can review
without netlisp, KiCad, or a browser account. Vector output — crisp at any
zoom, text-searchable. This is Phase 0 of the KiCad-handoff track (the
`.kicad_sch` exporter is a separate, later plan).

## Why this shape (verified against the codebase, 2026-07-29)

The whole document already exists in one place: **`src/review_md.zig`
`renderToMarkdown`** builds the static design-review doc — status summary,
system block diagram, validation (ERC + assertions + requirement checks),
power budget / sequencing / test-point tables, and the per-section hub
schematic SVGs — served today from `src/serve/api.zig:555` (export-zip path).
PDF export is that same document in a second medium, not a new renderer.

The schematic SVGs are machine-generated from a **closed, tiny subset**
(verified by grepping every emitter in `src/render_svg/*.zig`,
`src/render_html.zig`, `src/diagram/*.zig`):

- Elements: `line` (33 sites), `text` (13), `g` (9), `rect` (7),
  `polyline` (5), `polygon` (3), `path` (1 — a single arc form:
  `M x y A rx ry 0 0 1 x y`, the inductor bump at
  `src/render_svg/draw.zig:173`), `circle` (1 — debug pin,
  `display:none`), `title` (1 — tooltip only).
- **No `transform=` anywhere. No `tspan`, no `use`, no `image`, no rotated
  text.** `text-anchor` ∈ {absent, `middle`, `end`}; `font-size` ∈
  {9, 10, 11, 12}; one font family (SF Mono / monospace).
- Styling comes from ~9 CSS class rules already curated for static export:
  **`render_html.zig:556` `static_svg_css`** (`.component`, `.pin-stub`,
  `.net`, `.passive` — rect/line/text each), plus a handful of inline
  `stroke=`/`fill=` attributes. Skippable noise: `stroke="transparent"`
  hit-areas, `display:none` debug pins, `<title>` tooltips.

So a strict translator for exactly this subset is small, and any renderer
drift outside the subset can *fail loudly* instead of rendering wrong —
the same philosophy as `requireAllDocumented` in docgen.

Other verified groundwork:

- `src/deflate.zig` has raw DEFLATE (for a later FlateDecode toggle — needs
  only a zlib header + Adler-32 wrapper). **v1 emits uncompressed streams**:
  debuggable, deterministic goldens, still email-sized.
- No PDF tooling on the box (no qpdf/poppler/mutool) → validation must be
  in-repo (see Validation). Reviewing agents CAN visually check output: the
  Read tool renders PDFs.
- `render_html.zig:528 setupRenderCtx` + `render_html.zig:537 renderHubSvg`
  are the public per-hub SVG entries `review_md.zig` already composes with.

## Architecture — three new modules + wiring

```
DesignBlock ──review doc assembly (exists)──►  export_pdf.zig (WP-C composer)
                                                    │ per-hub SVG strings via renderHubSvg
                                                    ▼
                                   svg2pdf.zig (WP-B)  SVG subset ──► []DrawOp
                                                    │
                                                    ▼
                                       pdf.zig (WP-A)  pages/ops ──► file bytes
```

**Decoupling rule that makes WP-A ∥ WP-B parallel-safe:** `svg2pdf.zig` does
NOT call `pdf.zig`. It translates SVG text into a flat `[]DrawOp`
display-list (pure, standalone-testable). The composer maps `DrawOp` →
`pdf.zig` calls (~50 lines in WP-C). No shared API to pin, no race.

### WP-A — `src/pdf.zig` (foundation, no deps)

Minimal PDF 1.4 writer. Object table + xref + trailer, pages tree, one
content stream per page, base-14 fonts only (no embedding):

- **Fonts**: `Courier` / `Courier-Bold` for everything monospace (all
  schematic text — fixed 600/1000 em width makes anchor math exact),
  `Helvetica` / `Helvetica-Bold` for headings/prose/tables. Embed the
  Helvetica AFM width table (256 entries) for `text-anchor` and table
  layout; expose `pub fn textWidth(font, size, s) f64`.
- **Encoding**: WinAnsiEncoding. UTF-8 input mapped byte-accurate for
  Latin-1 range (µ, °, ± all present); explicit fallback table for known
  non-WinAnsi glyphs (`Ω`→`ohm`, `→`→`->`, `×`→`x`, `≤`→`<=`, `≥`→`>=`);
  anything else → `?`. A test asserts zero `?` on the fixture boards.
- **Coordinates**: PDF user space is y-up; SVG and the composer are y-down.
  Convert arithmetically (`y' = page_h - y`) inside the page helpers —
  **never** via a CTM `scale(1,-1)` flip, which mirrors glyphs. This is the
  classic trap; put a test on it (text op y-coordinates in the emitted
  stream must equal `page_h - input_y`).
- **Ops**: line, polyline, rect (stroke/fill/both), circle + single-arc
  path via cubic Bézier approximation, filled polygon, styled text
  (font, size, RGB, anchor), stroke color/width, dash pattern,
  clip-rect + translate push/pop (for slicing tall schematics across
  pages), per-page MediaBox (mixed page sizes allowed).
- **Determinism**: no `/CreationDate` unless a timestamp string is
  injected by the caller; stable object ordering → byte-identical goldens.
- Sketch (final shape is the implementer's call; keep it this small):

```zig
pub const Doc = struct {
    pub fn init(gpa: Allocator, opts: Options) Doc;         // Options: title, timestamp: ?[]const u8
    pub fn beginPage(d: *Doc, w_pt: f64, h_pt: f64) *Page;  // y-down helpers on Page
    pub fn finish(d: *Doc) ![]u8;                           // whole file
};
```

### WP-B — `src/svg2pdf.zig` (parallel with WP-A)

Strict tokenizer + translator for the closed subset → `[]DrawOp`.

- `pub const DrawOp = union(enum) { line, polyline, rect, circle, arc,
  polygon, text, … }` — resolved absolute coordinates, resolved RGB +
  stroke width + font size (no classes, no CSS left downstream).
- **Style resolution**: a Zig table mirroring the 9 `static_svg_css` rules,
  with **two palettes**: `screen` (the dark web colors) and `print`
  (light background, dark strokes — the PDF default; `--theme dark` keeps
  the web look). Plus inline `stroke=`/`fill=`/`font-size=`/`text-anchor=`
  attribute overrides.
- **Drift gate**: a sync test parses the `static_svg_css` string from
  `render_html.zig` and asserts the Zig table agrees rule-for-rule (same
  pattern as docgen's per-table sync tests). No refactor of review_md in
  this wave — the table + test is the single-authority stopgap.
- **Strict mode** (used by tests/composer): unknown element, unknown class,
  unknown attribute form, or unparseable path data → error with byte
  offset. Renderer drift breaks the build loudly, never renders wrong.
- Skips: `stroke="transparent"`, `style` containing `display:none`,
  `<title>`, `class="hit-area"`, `class="debug-pin"`.
- Not an XML library: a hand-rolled scanner for exactly the emitted forms
  (attributes are `{d:.1}`-formatted by our own code). ~300–400 lines.

### WP-C — `src/export_pdf.zig` composer + CLI (needs A+B)

Document outline mirrors `review_md.zig` (same assembly calls, same order —
verdict before visuals):

1. **Cover**: design title, revision block, generation stamp + runtime build ID
   (`build_id.current()`), status summary (ERC counts, assertion
   pass/fail, open notes).
2. **System overview**: the block-diagram SVG (`diagram/diagram.zig` via
   the same path review_md uses).
3. **Per-section schematics** — the pages the customer actually wants.
   Section name + subtitle as the page header; the section's per-hub SVGs
   flowed as blocks (pagination unit = one hub SVG — never cut mid-hub;
   slice *within* a hub only when a single hub exceeds a page, via
   clip+translate). Sub-block modules render once each (the "×N" rule the
   schematic page already applies).
4. **Validation appendix**: ERC table, assertions, requirement checks.
5. **Power budget / power sequencing / test points** tables.
6. Page furniture: footer with design name · page N/M · build hash.

- **Page size**: A4 landscape everywhere in v1 (usable width ~770 pt; a
  900 px hub SVG scales at ~0.86 → 10 px labels ≈ 8.6 pt — comfortable).
  Text pages could go portrait later; don't mix in v1. Fit-to-width
  scaling; no minimum-font logic in v1 — iterate visually.
- **CLI**: `netlisp export-pdf --project-dir <d> <design> [--output <f>]
  [--theme light|dark]` (default `<design>.pdf`, light). Wire into
  `main.zig`/`commands.zig` following `export-kicad`'s pattern. Works for
  bare modules too (modules resolve standalone everywhere designs do —
  reuse the same resolution the schematic page uses).

### WP-D — serve endpoint + button (needs C)

- `GET /api/schematic-pdf/:name[?theme=dark]` → `application/pdf`,
  `Content-Disposition: attachment; filename="<name>.pdf"`. Read-only;
  same design/module resolution as the schematic page. Percent-decode the
  `:name` param before file ops (httpz passes params verbatim).
- Toolbar `⤓ PDF` button on `/schematics/:name` next to the existing
  export controls.
- Docs: add the command to CLAUDE.md's Build & Run block and the endpoint
  to the Web Server list. (`zig build docs` / language-forms.md is NOT
  affected — no DSL change.)

## Validation (in-repo oracles; no external PDF tools exist on the box)

Per Guardian: every WP lands as SPEC.md `- ` bullets + `// spec:`-tagged
tests + code in ONE gated commit (`guardian-check commit --intent "…" .`).

1. **Structural self-check** (WP-A test helper, reused everywhere): walk
   the emitted bytes — xref offsets point at their objects, every stream's
   `/Length` matches, `q`/`Q` and `BT`/`ET` balanced, trailer `/Size`
   correct. We wrote the bytes; verifying our own invariants is cheap.
2. **Content oracle** (WP-C): extract all `Tj` strings from the finished
   PDF and assert the design title, every rendered ref-des, and every net
   label from the `DrawOp` stream appear. Ties the PDF to the
   `DesignBlock`, not to a golden.
3. **Golden byte test**: a small fixture design, injected timestamp →
   byte-identical output. Catches nondeterminism and accidental drift.
4. **Style sync test** (WP-B): Zig style table ⇄ `static_svg_css` string.
5. **Strictness test** (WP-B): feed the translator every design in
   `projects/designs` (and each module standalone) in strict mode — any
   emitter producing markup outside the subset fails here, today and
   forever.
6. **Fuzz harnesses** (`std.testing.fuzz`, smoke mode like the other
   codecs): svg2pdf tokenizer on arbitrary bytes never crashes;
   pdf.zig on arbitrary op sequences never crashes and always passes the
   structural self-check. Add both files to `guardian.toml
   [fuzz_presence] modules`.
7. **Visual acceptance**: generate stm32n6, barracuda, and one bare module
   PDF; the implementing agent Reads the PDFs (Read renders PDFs) and
   checks: pages present, no clipped hubs, labels legible, light theme
   sane. Eugene eyeballs before it goes to the customer.

## Execution notes for the implementing agents

- **Branch/worktree**: implementation continues on
  `claude/kicad-sexp-schematic-plan-bd3c57` (this worktree IS the task
  worktree). WP-A and WP-B may run as two parallel agents in their own
  worktrees **branched from this branch's current HEAD** (verify the base —
  isolated worktrees have branched from stale bases before), then merge
  here; WP-C and WP-D run here sequentially.
- **Merge hotspots** WP-A/WP-B both touch: `SPEC.md`, the `main.zig` test
  import block, `guardian.toml` (fuzz_presence). Keep those hunks minimal
  and expect a trivial conflict on merge.
- **Test aggregator**: a new module's tests only run if the file is
  `@import`-ed in `main.zig`'s test block. Do it in the same commit.
- **Never** run `zig test` / raw `zig build` loops for iteration — use
  `zig build test -Dtest-filter=<name>` (13 s floor). The full gate is
  ~4 min; budget Bash timeouts accordingly (600000 ms).
- `zig build test` never writes `zig-out/` — safe while the server runs.
- After edits in a worktree, verify the file actually changed on disk
  (Edit-tool writes have silently missed disk in worktrees before).
- Allocation style: match the surrounding code (arena/page_allocator
  patterns; slices reference source buffers and are not freed).

## Deliberately rejected

- **Headless browser / rsvg / wkhtmltopdf**: adds a prod deployment
  dependency for one feature in a codebase that hand-rolls PNG, DEFLATE,
  ZIP, and Gerber precisely to avoid that. Also none are installed.
- **Raster PDF (embed PNGs)**: `raster.zig` has no schematic drawing path
  (only PCB), so it saves nothing — and loses searchable text + crisp zoom.
- **Refactor render_svg to a backend-agnostic display list**: the right
  long-term shape, but it touches ~2 500 lines of ratcheted working code;
  the strict subset translator gets the same output with a fraction of the
  risk. Revisit if a third backend ever appears.
- **Browser print-to-PDF**: manual, unstyled pagination, not an export.

## Phase 2 candidates (not in this wave)

FlateDecode-compressed streams (zlib wrapper over `deflate.zig`); BOM
appendix table (`bom.zig` already resolves it); PDF outline/bookmarks per
section; clickable net cross-references; portrait text pages; MCP
`get_schematic_pdf` tool; generating `static_svg_css` *from* the WP-B style
table so the web CSS and PDF share one authority.

## Amendments (recorded as the work landed)

Deviations from the plan above, established by the implementing waves. These
override the corresponding text earlier in this document.

- **WP-C: the system-overview block-diagram page is DEFERRED.** Document
  section 2 ("System overview") is not built. The `diagram/` SVG carries its
  own ~80-rule stylesheet (`block_diagram.diagram_css`) whose classes are
  outside the closed subset WP-B's translator accepts, so feeding
  `renderBlockOverview` / `renderSystemSvg` output to `svg2pdf.translate`
  fails with `UnknownClass` — correctly, since that is exactly the drift gate
  the strict mode exists for. Bringing it in means either extending the style
  table to a second, much larger stylesheet or teaching the diagram engine to
  emit the schematic subset; neither is in this wave. Realised document order
  is therefore **cover → per-section schematic pages → validation appendix →
  power budget / power sequencing / test points**.
- **WP-C: per-hub output is a sequence, not one document.**
  `render_html.renderHubSvg` wraps a multi-group hub's SVGs in HTML
  `<div class="hub-group-block">` / `<h4>`, so the composer uses
  `svg2pdf.translateAll` (returning `[]Document`) rather than `translate`, and
  flows each returned document as its own page block.
- **WP-C: the composer slices with `clipRect` + `translate`, and scales in the
  mapping layer.** `pdf.zig` exposes no scale operator (deliberately — it would
  have to mirror-proof the CTM), so fit-to-width scaling is applied
  arithmetically as each `DrawOp` is mapped, which also scales stroke widths and
  font sizes proportionally.
- **WP-C: no check/cross glyphs.** The markdown report's `✓` / `✗` / `⚠` badges
  have no WinAnsi code point and would encode as `?`, so the PDF spells verdicts
  as `PASS` / `FAIL` / `VERIFIED` / `PENDING` and uses `-` where the markdown
  uses an em dash. A test asserts no `?` fallback reaches the output.
- **WP-C: `(rect rx …)` corner radii are dropped.** `pdf.Page.rect` paints square
  corners; the subset's only rounded rects are hub component boxes, so the loss
  is cosmetic.
- **WP-C: repeat collapse shares one authority.** Identical repeated sub-blocks
  get one page via `render_html.sameSubBlockShape` (made `pub` for this), the
  same predicate the schematic page uses for its "sub circuit ×N" card, so the
  two surfaces cannot disagree about what a repeat is.
- **WP-C: the CLI self-checks before writing.** `netlisp export-pdf` runs
  `pdf.validate` on the composed bytes and reports the page count, so a
  structurally broken file cannot reach disk.
- **Validation item 3 (golden byte test) is met as a determinism test, not a
  committed golden.** Two composes of one design with a fixed injected stamp are
  asserted byte-identical; no golden file is checked in (it would be a
  ~500 KB binary that any renderer tweak invalidates, and the content oracle
  already ties output to the `DesignBlock`).
- **Validation item 7 (visual acceptance) is NOT done in-repo.** There is no PDF
  renderer on the build box; the in-repo oracles (content, structural,
  determinism, pagination) are the gate. Eyeball the generated files downstream.
- **WP-D landed as planned, with two refinements.** `GET
  /api/schematic-pdf/:name[?theme=dark]` lives in `src/serve/schematic_pdf.zig`
  and resolves `:name` through `mcp_tools.evalNamedBlock` — the same
  design-then-standalone-module fallback the export-review package and the
  read-only MCP tools use — rather than duplicating the CLI's `evalForExport`.
  (1) The served file's `/CreationDate` is **derived from the review document's
  own `generated_at`** rather than a second clock read, so the visible cover date
  and the file metadata are the same instant by construction; the CLI still
  emits no `/CreationDate` at all, keeping its output byte-reproducible.
  (2) The `⤓ PDF` button is written in `render_html.writeHeader`, which both
  `/schematics/:name` and `/modules/:name` render, so module pages get it for
  free — no design-only branch.
- **Blocks shrink to fit one page before slicing (2026-07-30, Eugene's
  feedback on the first export).** A document taller than the page scales
  down (height-fit, floor `min_block_scale` = 0.35) so a tall hub lands on a
  single page; only blocks still taller than a page at the floor slice as
  before. Width-fit is never floored — a wide block must always fit the page
  width. The shrink budget is `usable_h − block_gap − 1 pt` so a shrunk
  block plus its gap always passes `ensure` on a fresh page (no blank-page
  emission at the boundary).
- **Dark is the default (2026-07-30, Eugene's call after seeing the samples).**
  The plan's light-print default is inverted: the CLI and the endpoint both
  default to the `.screen` palette, with `--theme light` / `?theme=light` as
  the print opt-out. Making dark the default meant making it *legible*: the
  composer now paints every page with the web viewer's `#0d1117` background
  and swaps its own furniture inks (headers, tables, footers, rules) per
  theme — previously the screen palette drew the web's light inks onto
  PDF-white, which was never reviewable output.
- **One page per section, 2D grid with group labels (2026-07-30, Eugene's
  direction: "each section goes into one page … just do a 2d grid and if things
  are grouped, have the group labels as well").** The pagination unit is no
  longer one translated document but one *section*. `gridBlocks` shelf-packs a
  section's blocks left-to-right, top-to-bottom in declaration order at one
  uniform scale, found by bisecting `packsAt` (monotone in the scale) between
  `grid_min_scale` = 0.10 and 1.0 — natural size is tried first, so a small
  section never shrinks. Each cell is captioned with the pin-group label the
  renderer wrote as `<h4 class="hub-group-label">` above that block's `<svg>`,
  now carried through the translator as `Document.title`; cells are clipped to
  their own box so nothing bleeds between them. A **lone** document floors at
  `min_block_scale` instead (nothing to pack against, so shrinking past
  legibility buys no density), and a section the grid cannot pack at its floor
  falls back to the pre-existing sequential shrink-then-slice flow — which
  therefore remains live and tested. Every sheet keeps a `flow_tail_reserve`
  band clear below its grid (plus its own measured notes, the pair capped at
  `tail_reserve_frac` of the sheet) so a schematic-less section or module
  continues ON the sheet rather than opening a page of its own; that is what
  packs stub entries into shared compact regions. Measured on the real boards:
  cyclops-kband 26 → 22 pages (its JM1 section went 4 pages → 1, JM2 3 → 1) and
  stm32n6 58 → 39 (Core System 9 pages → 1, Expansion Connector 4 → 1), with no
  blank pages in either.
- **Unified section + sub-block sheets (2026-07-30, Eugene's direction after the
  first customer-facing kband export).** On a module-heavy board most sections are
  thin wrappers around a `(sub-block …)`: the section's notes described a circuit
  whose schematic drew several pages later, in the sub-block appendix, so prose
  and drawing were disassociated (kband p3/p4/p6 were streams of nothing but stub
  headings). A section's attached modules now draw **in the section's own grid**.
  - *Attachment is shared, never re-derived.*
    `diagram/membership.attachedSubBlocks` (new, `pub`) returns the indices of the
    modules one section owns, off the same `computeSubBlockAttachments` map the
    schematic page already used; both surfaces call it, so a module cannot sit
    under one section on the web page and another in the PDF.
    `render_html.writeSection` now takes those indices rather than a copied
    `SubBlock` slice — the index IS a sub-block's identity, since two channels of
    one module are equal by value.
  - *Only single-instance modules attach.* A module instantiated more than once
    (render-identical per `render_html.sameSubBlockShape`) would be duplicated
    into N sections, which is exactly what the repeat collapse exists to prevent,
    so it keeps its appendix entry and its `x N` caption. A module that draws
    nothing (a passive network) is likewise left alone, keeping its inline
    appendix entry instead of vanishing. The appendix therefore holds exactly what
    no section drew.
  - *A previously schematic-less section becomes a real sheet* once it has an
    attached module (heading + grid + notes); one with neither own hubs nor an
    attached module is still a compact entry. Cells the renderer left unlabelled
    are captioned `<sub-block> - <module title>` (e.g. `bss1 - BSS138 BPSK Gate`);
    a cell carrying its own pin-group `<h4>` keeps it.
  - *Notes follow their circuit.* Three classes now render, resolved once into a
    flat `Prose` row list per entry (so the reserve's measurement and the renderer
    walk the same list): the section's own notes; each drawn module's notes — its
    `(section …)` notes and its ref-anchored ones, which reached the PDF NOWHERE
    before, prefixed `<sub-block>` / `<sub-block>/<ref>`; and the design's
    ref-anchored `(note "REF" …)` entries, filed onto the sheet whose section
    declares that ref (stm32n6's TP1…TP13 notes land on its Test Points sheet),
    with any ref no section declares surfacing under a "Design notes" heading in
    the validation appendix so none is dropped. A module note whose text a section
    note on the same sheet already states is dropped — boards routinely copy a
    module's rationale into the section wrapping it, which was invisible while the
    two lived pages apart.
  - *The reserve got two fixes the merge exposed.* A non-empty reserve now also
    covers the `block_gap` the grid leaves behind itself (without it the prose
    started one gap below where the reserve assumed, and its last row spilled onto
    a page of its own), and the requested reserve is trimmed by `grantableReserve`
    to what the sheet can spare above the grid's floor-scale footprint —
    previously a lone tall hub on a note-bearing sheet failed the reserved pack,
    fell to the sequential ladder, and that ladder's first `ensure` opened a fresh
    page, leaving the sheet holding nothing but its header. `tail_reserve_frac`
    rose 0.40 → 0.65 now that the drawing is protected from the other side: on a
    unified sheet the prose IS part of the deliverable.
  - Measured: cyclops-kband 22 → **19** pages (the p3/p4/p6 stub streams are gone
    — ADF4159 PLL, ADF5901 TX VCO, ADF5904 RX, LMX2594 LO and ADAR2004 each share
    a sheet with their module's schematic; `lna1 x2` and the unattached `boost5`
    are all the appendix keeps). One compact prose page remains BY DESIGN
    (BSS138/PMA3/5V-Boost heading+notes entries): their `lna1`/`lna2` modules are
    render-identical, and the ×N carve-out keeps a repeated module in the
    appendix rather than duplicating it into each hosting section — the two
    surfaces agree on ownership but the PDF declines to draw a copy per owner.
    stm32n6 41 → **29** (USB, Flash, PSRAM, IMU,
    Display, Motor, NeoPixel, Power Button and ADC Array all unified), with no
    blank and no lone-stub pages in either.
