# Web Server

> Moved verbatim from CLAUDE.md (2026-08-19); linked from its Reference Docs section.

The production netlisp server runs at **https://netlisp.eugenepentland.dev** —
that's the canonical URL for the KiCad-sync agent and browser clients. The
structured tool surface is local-only through `netlisp tool`.
Local dev still uses `http://localhost:7050`.

`netlisp serve` starts an HTTP server with the schematic viewer:

- **Design list**: `GET /` — links to all .sexp designs, with per-card health chips (ERC errors/warnings, failed assertions, open notes, green PASS)
- **Schematic viewer**: `GET /schematics/:name` — server-rendered HTML schematic with embedded SVG. The page also embeds the design-review panels inline (power-budget table, power-sequence, test-points, per-section coverage). There is no standalone review-report endpoint.
- **Thermal review**: `GET /thermal/:name[?ambient=NN][?scenario=natural|airflow_1ms|airflow_2ms|heatsink][?layout=<saved>][?fragment=1][?row=<saved>]` — the **Thermal** tab (last in the shared design-view bar, right after Assembly, on the schematic / PCB / 3D / assembly pages; modules get it too, without Assembly). Server-rendered dark page: the board-coupled verdict pill + sentence with the package-level screen demoted under it, the ambient window, a cooling-scenario picker, the `?thermal=1` heat-zone image of the selected scenario, the four-rung cooling ladder, a per-part junction table for that scenario sorted hottest first (each row cross-probing to `/pcb-layout/<name>?focus=<ref>` + `/schematics/<name>#comp-<ref>` and announcing itself on the shared `netlisp-xprobe` channel), and a coverage footer with the unplaced refs and the screening-grade caveat. Every sentence and cell comes from `review_thermal.zig`, so the page and the review panel/PDF can never disagree. `?ambient` is clamped to −55…125 rather than refused and `?fragment=1` answers the two ambient-dependent regions alone (what the page's own client swaps in); switching scenario is client-side. A design with no cooling ladder shows the reason instead of the picker, the image and the ladder — never a broken image. Toolbar: `⤓ PDF` → `/api/schematic-pdf/:name`, `{ } JSON` → `/api/thermal/:name`. `?layout=<saved>` screens one named saved layout instead of the design's default board — a layout picker beside the ambient window switches it, and the choice rides into the board frame, the tab bar, the cross-probe links and the JSON link, so nothing on the page describes a board other than the one it names; a `?layout` nobody saved falls back to the default board and says so rather than screening a board under the wrong name. Below the tables a **Compare layouts** panel lists every saved layout of the design (parts, saved copper, hottest part, Tj, and Δ against the board on screen). Only the shown board's row is filled on load — every other row is a whole second solve, so rows fill one at a time on click or via a "Solve all" sweep the reader can stop; `?row=<saved>` answers one row's cells alone. A design with one board renders no panel. `:name` resolves as a design or a bare `lib/modules` module (percent-decoded first); unknown name → 404 plain text. Read-only (`src/serve/thermal_page.zig`).
- **Scene graph**: `GET /api/scene-graph/:name` — JSON scene graph for schematic (used by the live-push pipeline)
- **Schematic PDF**: `GET /api/schematic-pdf/:name[?theme=light]` — the design-review document as an `application/pdf` attachment (default = the viewer's dark screen theme, page background included; `?theme=light` = print palette) (`<name>.pdf`): cover, one A4-landscape sheet per `(section …)` (the section's hub blocks **plus the single-instance `(sub-block …)` modules that section owns** shelf-packed into a 2D grid at one uniform scale, each cell captioned with its pin-group label or `<sub-block> - <module title>`, the section's notes and its modules' notes under the grid; a section with no drawing at all packs as a compact entry, and the `(sub-block)` appendix keeps only what no section drew — unattached and multi-instance `x N` modules), validation appendix, power/test-point tables. The HTTP twin of `netlisp export-pdf` (`src/serve/schematic_pdf.zig` → `src/export_pdf.zig`), so the download and the CLI's output are the same document, with a real `/CreationDate` added. `:name` resolves as a design or a bare `lib/modules` module (percent-decoded first); unknown name → 404 plain text. Read-only, composed on demand, self-checked by `pdf.validate` before it is served. The schematic page's `⤓ PDF` toolbar button points here (module pages too).
- **KiCad schematic**: `GET /api/kicad-sch/:name[?vendor=0][?flat=1]` — the
  exported `.kicad_sch` hierarchy plus its project sidecars (`sym-lib-table`,
  `fp-lib-table`, `<name>.kicad_pro`, `netlisp.kicad_sym`) as one store-only
  ZIP attachment (`<name>-kicad-sch.zip`). Every member is a bare name at the
  archive root — the root sheet's `Sheetfile` links name bare siblings and the
  sidecars only resolve from the directory holding the `.kicad_pro`, so the
  whole export must unpack into ONE directory. The HTTP twin of `netlisp
  export-kicad-sch` (`src/serve/kicad_sch_export.zig` →
  `src/export_kicad_sch.zig`), with `?vendor=0` / `?flat=1` mirroring
  `--no-vendor-symbols` / `--flat`. `:name` resolves as a design or a bare
  `lib/modules` module (percent-decoded first); unknown name → 404 plain text.
  Read-only, composed on demand, and every sheet is re-parsed + structurally
  checked before it is served. No cache: the vendor `.kicad_sym` index it
  rebuilds per call is ~0.36 s of a 0.95 s *Debug* export of the largest board
  here, and caching it would need an invalidation signal `lib/` does not have
  (`lib/sources/` is writable through the CLI VFS and the library page). The
  schematic page's `⤓ KiCad` toolbar button points here (module pages too).
  Footprint links resolve only when `footprints.pretty/` sits beside the sheets
  — `GET /api/export-kicad/:name` carries both and opens with 0 ERC warnings.
- **KiCad schematic push**: `POST /api/sync-kicad-sch/:name[?dry_run=1][?force=1]`
  — writes that same schematic INTO the KiCad project directory the design's
  `(kicad-pcb "<path>")` names, under the KiCad project's own name (`Cyclops
  Digital.kicad_sch` + `Cyclops Digital-<section>.kicad_sch` children + a
  matching `.kicad_pro`). The schematic twin of `POST
  /api/sync-kicad-pcb/:name`, and shaped like it: `?dry_run=1` returns the
  per-file plan without writing, and a refusal is a **409** carrying the reason
  in the same JSON envelope as a success. Guarded — an existing sheet is
  replaced only when it is a previous netlisp push or an empty eeschema stub,
  anything else refuses the whole push (`?force=1` overrides), and a KiCad lock
  (`~<file>.lck`) in the project directory refuses **even with force**. An
  existing `.kicad_pro` / `sym-lib-table` is kept (a table with no `netlisp`
  row is reported with the exact line to add), `fp-lib-table` is untouched
  (board domain), and replaced files roll into `backups/`. Missing
  `(kicad-pcb …)` → 400 naming the form; unknown design → 404. Body:
  `{ok,name,dir,project,root,dry_run,written,summary{…},refusal?,files[{name,
  action,bytes,note}]}`. Driven by the schematic viewer's **↑ Push SCH**
  button, which dry-runs first and shows the plan for confirmation. Writer in
  `src/kicad_sch_push.zig`, surfaces in `src/serve/sync_kicad_sch.zig`.
- **PCB layout PNG**: `GET /api/pcb-png/:name` — server-rendered PNG of the force-directed PCB layout, so an AI agent (or any HTTP client) can *see* the board, not just parse the placement JSON. Mirrors the browser viewer's colours/projection (`src/render_pcb_png.zig` rasterizes onto `src/raster.zig`'s software canvas, encoded by `src/png.zig` — pure-Zig, no image dependency). Query: `?nets=A,B` / `?refs=U1,C3` enter *focus mode* (spotlight those nets/components in amber, dim the rest — `refs` match the bare leaf of a sub-block-prefixed ref); `?route=1` overlays routed copper + DRC markers; `?names=ref|origin|both` picks part labels (default: `origin`, the module-local sub-block-relative names, falling back to `ref` when no origin is known); `?pins=U13,C5` (or `pins=hubs`) labels those parts' pads with net names; `?crop=U1&r=6` zooms on one part (matched by ref, leaf, or origin name — combine with `?pins=`); `?sheet=1` returns a contact sheet (whole board + per-hub pin-labeled closeups); `?critique=1` draws a numbered worst-problems overlay (hottest loops by nH, longest airwire, staged parts, DRC count); `?width=`, `?layout=<saved>`, `?regen=1`, `?sub=<slug>`. When the design declares a `(board (size W H) …)` form, the physical outline rectangle + dimensions are drawn under the parts (green). Read-only; reuses the design's auto-layout cache.
- **Two-sided boards + standalone-PCB groundwork (2026-07-02)**: every pose
  (viewer, sidecars, sync) carries a board `side` (top/bottom) and `locked`
  flag — in the `/pcb-layout` viewer **F** flips the hovered part (bottom parts
  render blue + mirrored, matching worldPt's local-x mirror), **L** locks it
  (drag/rotate/flip refused). The router is layer-aware (bottom parts' pads
  block/connect on the bottom copper; through-hole pads on both; cross-side
  nets via by construction), and KiCad sync lands bottom parts on B.Cu with
  KiCad's stored back-side convention (+180° stored angle — netlisp mirrors
  local X, KiCad mirrors local Y). New top-level forms: `(stackup N (plane IDX
  "NET")…)` (no form = legacy implicit 4-layer with assumed planes;
  `(stackup 2)` = plane-less 2-layer, ground routes as real copper) and
  `(net-class "name" (width MM) (clearance MM) (via DIA DRILL) (nets …))`
  (per-net routing geometry; grid pitch sized to the widest class). DRC adds
  annular-ring (0.1 mm floor) + board-edge checks.
- **The implicit stackup plants a SUPPLY-RAIL plane, not just ground
  (2026-08-11).** A block with no `(stackup …)` runs on the legacy implicit
  4-layer model. In1.Cu has always been ground — which is why a bypass cap's
  ground leg needs one stitch via and never a trace — while In2.Cu was a second
  ground plane, so a rail landing on a dozen QFN pads was left to the router as
  an ordinary net and, on a dense part, simply came out open (straps-synth's
  `V_3V3` was THE unrouted net, 22/23). In2 now carries the block's **dominant
  supply rail** and the rail behaves exactly as ground does: the router stitches
  each of its pads to the plane, the connectivity oracle counts them joined,
  port escape exempts them, and In2's Gerber pours the rail with antipads around
  every foreign hole. The rail is chosen deterministically — of the flattened
  nets that read as a supply by the project's existing predicates
  (`pin_roles.isSupplyFn` / `rails.looksLikeRail`, no new naming rule), the one
  on the most pads, ties by first appearance, and only when its `/`-leaf names
  exactly ONE net (a shared leaf would let the pour short two sub-blocks'
  private rails together). **No qualifying rail ⇒ both inner planes stay
  ground**, byte-identically to the old model, and a design that DECLARES a
  `(stackup …)` is untouched — `(stackup 2)` included. The whole model lives in
  `src/placement/implicit_plane.zig` because the router, the oracle, the DRC,
  the pour fill, the client wasm DRC and the Gerber export must never disagree
  about it: a board where the router assumes a plane the Gerbers do not pour is
  a shipped short. `/api/pcb-describe` reports the assignment under
  `board.stackup` (`declared:false` + one row per inner plane) so it is never
  silent. Per-pin bypass-stub micro-nets (`<rail>.<REF>.<PAD>`) are deliberately
  NOT planed — the split exists so each decoupling loop can be measured, and
  planing it would replace the local cap→pad trace with two vias.
- **A plane-carried net draws its local surface loop FIRST, then shares one
  stitch via (2026-08-11).** Planing a net used to mean "every pad drops a via
  and the plane joins them" — right for two pads on opposite corners of a
  board, wrong for a bypass cap's leg and the QFN pad it decouples 1.5 mm away:
  each got a barrel, nothing joined them on the surface, and the decoupling
  loop the placer tightened was routed DOWN to an inner layer and back up.
  `src/placement/plane_stitch.zig` now names the pad pairs the placement's own
  decoupling model binds (`optimizer.Loop` — the `(decouples "IC" PIN)` /
  per-pin-shorthand binding, power leg on the rail and ground leg on ground, so
  no plane kind is a special case), the router draws each with the ordinary
  short-hookup machinery (`net_topology.padJoin` through the same DRC-grade
  probe every direct leg uses), and only then stitches: a pad whose own surface
  copper already reaches a same-net via within **`via_share_max_mm` = 3.0 mm**
  — measured along that copper — contributes no barrel of its own. The barrel
  lands on the CAP's land and the run carries the rail on to the pin, which is
  the textbook "route power through the decoupling cap" order. The same 3 mm is
  what makes a pair *local*: further apart than that is no bond at all, so no
  run is ever drawn that one via could not serve. Everything is geometry-gated
  — a bond the probe refuses is not drawn (on straps-synth every GROUND leg is
  refused, because a cap's ground land faces away from its hub, so ground keeps
  the per-pad via the hand board also draws), and a net that reaches its plane
  NOWHERE keeps none of the bond copper. Measured on straps-synth-lmx2595
  (rough + route): `V_3V3` 15 vias → **10**, its copper 3.2 → 8.5 mm, 23/23
  routed and DRC unchanged (0 errors); barracuda's `bench-route` is
  byte-identical (declared stackup, 79/92, 539 tracks, 663.70 mm); the
  rough-placement corpus is byte-identical. **Routes persist**: saved
  layouts capture their routed copper (net-NAME keyed) in the sidecar;
  Load/page-open restores it and DRC re-checks it against current poses;
  moving a part invalidates only its own nets' copper. **Hand routing**: the
  ✎ Draw button (key **X**) draws tracks/vias onto the same model — click a
  pad to start (net/layer/width from pad + Route panel's track-width), click
  to fix 45°/grid-snapped corners (Shift = free angle), **V** drops a via +
  flips layer, finish on a same-net pad / double-click, Backspace
  steps back, right-click deletes copper under the cursor; Save/Update
  persists it like any routed copper (works on module pages → the module's
  `.layouts.json`). A click that magnetically snaps to a same-net pad or
  existing trace endpoint finishes the manual trace only after the path reaches
  that endpoint. While a trace is live, a faded dashed ratsnest line follows
  the legal preview endpoint to the closest unresolved same-net pad, trace body,
  via, or filled-pour point outside the launch island (and remains available
  when routing resumes from existing copper). After each fixed corner, a
  bounded scoped autorouter run preserves the manual prefix and replaces that
  straight guide with a faded dashed preview of the proposed remainder (both
  nets are previewed and committed together for a coupled differential pair);
  **Enter** commits that remainder, including proposed vias, as the trace's one
  undoable completion. If the autorouter has not answered yet, Enter waits for
  the in-flight proposal. If there is no completion target, Enter keeps the
  trace live rather than silently saving a partial route; double-click still
  performs that explicit manual finish.
  **Rigid sub-circuits**: parts sharing a sub-block prefix
  drag/rotate as one unit (G explodes/re-coheres; per-design localStorage),
  and the sidebar Sub-circuits palette **Stamp**s a whole module ★ layout
  onto the board via the same origin_key bridge KiCad sync seeds from
  (`PCB.subseeds`). **Stamped copper**: Stamp also carries the module ★
  snapshot's saved routes onto the board (`PCB.subroutes`, built server-side
  with module net names mapped to parent nets over the origin-key pin bridge;
  unbridged private nets get the `slug/NET` flatten spelling). Stamped copper
  is tagged with its group slug (`g` on tracks/vias, persisted through the
  sidecar), so rigid-group drags/rotates carry it along; it's dropped only
  when its group is broken apart (a member moved alone), and a re-Stamp
  replaces only that tagged copper. Board-level tracks, vias, and RF paths on
  nets connected to the sub-circuit remain in place; ratsnest and DRC show any
  gap created by a moved pad. Nets touching a locked (not-moved) member are
  skipped.
- **Three-tier editor payload (2026-08-26)**: `GET /pcb-layout/<design>` answers
  in three dependency-cached responses, each keyed separately in the PCB page
  cache. The **page** carries placement and saved copper and paints
  immediately. **`?derived=1`** follows after first paint with everything
  derived from that copper — poured fills, the reporting DRC, mask relief,
  trace EM, the power-handling screen, the fab-identity mark. **`?pdn=1`**
  follows *that* with the PDN impedance sweep alone, which is the single most
  expensive analysis the server runs (barracuda: 6.3 s against 6.6 s for
  everything else combined) and is read only by the PDN section of the
  track/via properties inspector. `"power_integrity": {"ac": null}` in the
  `?derived=1` body is the marker the viewer reads as "the sweep exists, fetch
  it"; an absent `ac` key means the board has no routed copper to sweep and
  nothing is fetched. The startup warm-up fills all three — pages first (about
  a second for the whole corpus), then the two analysis tiers — and a
  plain-page cache miss starts a capped background warm, so an edit's payloads
  are usually already rendering before the browser asks.
- **Named layouts + per-layout URLs (2026-07-27)**: every block — top-level
  DESIGNS included — keeps as many named saved layouts as you save, listed in
  the Sub-circuits pane's Layouts panel. (This *replaces* the 2026-07-02
  "single-layout designs" rule, under which a design kept exactly one layout
  and got no panel; a board being autorouted wants several placement/routing
  candidates to compare.) **`GET /pcb-layout/<design>?layout=<name>` is each
  layout's permalink**: it renders that snapshot verbatim — poses *and* its
  persisted copper, outline and silk — outranking the ★ default, so a URL names
  one specific board. A name matching nothing 404s and lists the names that do
  exist, rather than silently showing a different board under a shared link.
  `?refine=<name>` is the other spelling: same seed, but re-solved. The panel
  links each row by its permalink, and the viewer keeps the address bar on the
  active layout (`?layout=…`, solve flags scrubbed) after every Load/Save, so
  what's in the bar always reproduces what's on screen. The page adopts the
  layout it rendered as the edit target, so Update + the idle autosave write
  back into it. A block's FIRST-ever save is auto-starred (something must be
  blessed for KiCad sync + fab outputs to resolve); after that the ★ is your
  pick and no later save steals it. `import-kicad-layout` claims the star but
  keeps the design's other layouts. Sub-block previews (`?sub=`) always solve
  fresh, so `?layout=` isn't read there and their rows carry no links.
  After a live Regenerate/Rough run the page reloads with `?show=cache` so the
  fresh result is what you see (not the starred layout); Save commits it.
  Static assets serve with content-hash ETags + no-cache revalidation, so a
  deploy can never leave a browser running stale viewer JS.
- **`backfill-layouts` (2026-07-27)**: recover layouts that survive only in
  history. `history/<name>/layouts/` keeps the pre-write copy taken before every
  layout mutation, and git keeps every committed revision of the sidecar; under
  the retired single-layout rule a design's Save REPLACED its whole list, so
  those archives hold the only copy of each superseded board (barracuda's
  autoroute progression, one snapshot per run). `netlisp backfill-layouts
  [--project-dir <d>] [<block>…] [--dry-run] [--limit <n>]` mines both, drops
  anything whose board already exists (fingerprinted on placement **and**
  copper, so two routings of one placement stay distinct), and appends the rest
  as ordinary manual rows — each with its own `?layout=` permalink. Existing
  rows keep their order and the ★ never moves, so KiCad sync + fab resolve the
  same board before and after. `--limit` (default 20) bounds what one block
  gains and the run reports what it turned away. Prints one JSON object.
  Two scale rules this exposed and fixed: the sidecar read cap is
  `sidecar_max_bytes` = 16 MiB (a routed multi-layout board runs to megabytes;
  the old 1 MiB cap read such a board back as **zero** layouts, silently
  stripping the viewer, the sync seed and the fab outputs — an unreadable or
  unparseable sidecar now warns), and the page blob inlines copper only for the
  layout it SHOWS, marking other routed rows `"routes":null` so the viewer
  follows their permalink instead of carrying megabytes of unclicked tracks.
- **Fab outputs (full package, Gerber included)**: `GET
  /api/pcb-gerbers/:name` — the complete manufacturing package as one ZIP
  (the `⤓ Gerbers` toolbar button on `/pcb-layout`): RS-274X/X2 Gerbers —
  outer copper (pads + the ★ layout's persisted routed tracks/vias), inner
  planes per the `(stackup …)` form (no form = the router's implicit 4-layer
  model, emitted as two inner ground planes with clearance antipads around
  foreign holes; a plane declared on an outer layer pours it with
  clear-polarity isolation), solder mask (0.05 mm expansion, vias tented),
  paste, silkscreen (footprint art + 5x7 ref-des strokes, mirrored on the
  bottom), and the board profile (the ★ layout's drawn outline > authored
  `(board …)` rect > parts-bbox fallback) — plus the Excellon PTH/NPTH
  drills, centroid/BOM CSVs, release reports, checksums, and a standalone
  `<name>-assembly.html`. That HTML embeds the exact released CAM, operator
  search/BOM data, and rework guides, so it opens directly from disk without
  the server. An authored `(board (part-number "…") …)` is printed beside the
  eight-hex fabrication ID on silkscreen and is recorded in every release
  report; the part number also participates in the fabrication digest. KiCad
  file naming + Protel extensions let fab CAM auto-detect layers. Writer in
  `src/export_gerber.zig`, store-only ZIP in `src/zipfile.zig`. Individual pieces stay available: `GET
  /api/pcb-centroid/:name` — side-aware pick-and-place CSV at the blessed
  poses (★ default → newest manual → any → cache, the KiCad-sync
  preference); `GET /api/pcb-drill/:name[?npth=1]` — Excellon drill
  (plated: thru pads + the ★ layout's persisted routed vias; `?npth=1`:
  non-plated mounting holes). Formatters in `src/export_fab.zig`. Every fab
  output — `/api/fab-readiness` included — accepts `?layout=<row>` to build
  against that named saved layout instead of the ★ selection (the same row
  the CLI tools' `layout` arg picks); an unknown name 404s naming the rows
  that do exist, like `/pcb-layout`'s direct link. **All fab
  outputs share one coordinate frame** (`export_fab.Frame`: y-UP, origin at
  the board outline's bottom-left, centroid rotation CCW-positive — the
  Gerber/KiCad-pos convention; the placement model itself stays y-down), so
  the package stacks exactly in CAM — never mix files from different
  requests/frames.
- **PCB layout facts**: `GET /api/pcb-describe/:name` — structured spatial facts about the solved placement (`src/serve/pcb_describe.zig`), the textual twin of the PNG: built from the identical placement-selection logic and accepting the same query parameters, so the facts always describe the board the image shows. Returns JSON with the axes convention (y grows down; "top" = −y), the anchor (largest hub IC), per-part `ref`/`origin`/side-of-anchor/`gap_mm`/nets/`unplaced`, per-decoupling-loop net + power-leg mm + nH + side, each hub's net→package-edge pad map, spec coverage (incl. `unresolved` spec names), per-part `want_side` (the part sits OPPOSITE the hub edge its net's pads are on), a `module_policy` block (Phase 0 of the module-placement ruleset — `src/placement/module_policy.zig`: the detected `ModuleClass` per hub IC (buck/ldo/mcu/rf_amp/generic, best-effort — integrated power modules with no discrete inductor read `generic`), the criticality `net_classes` (input_rail/switch_node/clock/rf/feedback/analog — the routing-order taxonomy), and the inferred passive `roles` (input_cap/decoupling_cap/bulk_cap/feedback_divider/matching_element)), a `lint` array (fell-back-to-auto / unresolved-name / unplaced errors; wrong-side / long-loop / outside-outline warns; plus the Phase-1 layout gates in `src/placement/layout_lint.zig` — `decap-far` (HF decap power-leg to its nearest supply pad >6 mm; bulk caps exempt), `hot-loop-not-tightest` (the switcher input loop is looser than a less-critical decoupling loop), `feedback-near-aggressor` (an FB/comp part within ~2 mm of a switch-node/clock/RF passive)), `board.outline` (the authored `(board (size W H) …)` rectangle when one exists), and (with `?route=1`) `routed:{trace_mm,tracks,vias,drc}`. Every DRC record (here, on `/api/pcb-drc`, `/api/pcb-route`, and the viewer blob) also names WHO it is between: `a`/`b` party objects carrying `net` / `ref` / `pad`, so a `track↔pad` reads "GND ↔ VDD3V3 on U7 pad 12" and a `net open` names its net plus a pad from each island it failed to join. A side the rule has no party for (a courtyard clash has no net; a `net open` has one) is simply absent. The same facts flow through the CLI `describe_pcb_layout` tool. Agents should read measurements here and use the PNG for gestalt. Repeat requests are answered from a dependency-validated in-memory cache (`src/serve/describe_cache.zig`): the plain request and the `?layout=` / `?cropnet=` / `?pads=` variants each keep their own entry, invalidated by the design's sources, its `.layouts.json` / `.autolayout.json` / `.drc-rules.json` sidecars and its live-edit version — the same contract `/api/layout-progress` and the `/pcb-layout` page use. `?route=1` (route fresh), `?regen=1` (fresh solve), `?sub=` and every other parameter bypass it. `X-Netlisp-Describe-Cache: hit|miss|bypass` reports which happened.
- **Rough-vs-starred match**: `GET /api/layout-match/:name` — score how hand-like the `?rough=1` seed is versus the design's *starred* layout (the saved layout flagged `"default"`/★ in `/pcb-layout`, the user's blessed hand-finished reference; `src/serve/layout_match.zig`). The metric is per interchangeable class (kind+value+footprint+net set), per IC edge, COUNT agreement — credit `min(rough, starred)` parts per edge — so swapping which fungible 100 nF cap sits on an edge isn't penalized and looseness is tolerated (only the wrong edge/proportion costs). Returns `{name, starred, n, area_match_pct, classes[]}` (each class's rough/starred per-edge tallies show which subsystem the rough scattered differently), else `{starred:null, message}` when nothing is starred yet. Measures placement hand-likeness / how little dragging remains to finish — NOT the electrical score. CLI twin: `compare_layout_to_starred`.
- **Layout state**: one sidecar per design — `<design>.layouts.json` `{default, cache, layouts[]}`. `layouts[]` = named snapshots (manual saves + auto-recorded optimizer runs), `default` = the starred (★) / KiCad-sync seed, `cache` = the single-slot optimizer cache (tuning params + poses, overwritten each solve). Precedence the `/pcb-layout` viewer shows as a scorebar chip: explicit `?refine=<snapshot>` > starred (★) default > cache > fresh solve > plain grid. (The old source-authored `(placement …)` spec once sat at the top of this chain; that DSL form is retired — layout is seeded from saved snapshots / the `?rough=1` seed now, not from a spec form in the `.sexp`.) Legacy standalone `<design>.autolayout.json` is still read as a fallback and deleted on the next solve; `.placement.json` migration was dropped (all designs migrated).
  A named layout may also carry one physical finned heatsink assembly. In the
  PCB editor choose the ♨ tool, drag its base/contact rectangle, then select
  the physical top/bottom face and target part and enter material, base
  thickness, fin height/thickness/gap/direction, and thermal-pad thickness and
  conductivity. The editor derives fin count and a still-air plate-fin
  theta-SA estimate, the 3D tab renders the pad/base/fins at those dimensions,
  and both the built-in field and Elmer export use that exact rectangle and
  package-direction mapping when the `heatsink` scenario is selected. The
  estimate assumes open straight fins and a 10 W/m²K still-air film; it is a
  comparative screening model, not enclosure or fan-curve CFD.
- **Live push**: `POST /api/push/:name` — rebuild and push update. On eval failure the JSON (and the schematic page, and the CLI `build` tool) carries a structured `diagnostic` `{file,line,col,message,source_line}` rendered compiler-style with a caret (`src/serve/diag_format.zig`).
- **Version history + diff**: `GET /api/history/:name` — stored snapshot ids (file copies under `<project>/history/<name>/<timestamp>/`, written before every mutation); `GET /api/diff/:name?from=<id>&to=<id|current>` — request-local netlist diff (instances added/removed, value/footprint changes, net membership changes; `src/serve/design_diff.zig`). Schematic header's History panel renders it. Caveat: snapshots capture the design file only, so an old revision re-evaluates against today's lib/ modules.
- **Datasheet attach**: `POST /api/attach-datasheet` `{component,file}` — splices an uploaded PDF filename or an HTTP(S) URL into `lib/components/<name>.sexp` (idempotent and scheme/path-safe); the library page has a per-card attach control. `GET /api/datasheets` lists uploaded local candidates.
- **Cross-probing**: `/pcb-layout/:name?focus=REF` (or `#REF`) zooms/flashes a part (leaf-matching like `?refs=`); PCB sidebar rows link "Show in schematic →" (`#comp-REF` scroll+flash), schematic component detail links "Locate on PCB →". **Two-window live sync**: with `/pcb-layout/<name>` and `/schematics/<name>` open in separate tabs/windows of the same browser (the KiCad two-monitor workflow), clicking a part on one page highlights it on the other through the `BroadcastChannel("netlisp-xprobe")` bridge in `pcb_board.js` and `schematic_viewer.js` (messages carry the design and ref; receivers ignore other designs; no server round-trip).
- **PCB Find**: the full `/pcb-layout/:name` editor has a dock-wide Find field above its four workflow tabs (`Ctrl/Cmd+F`; arrows preview; Enter locates; F3 / Shift+F3 steps). Its client-only index covers component refs/values/footprints, collapsed nets, DRC ids/kinds/parties, sub-circuits, and board text; results reuse the normal part selection, review-focus, DRC locator, and point-focus paths. Prefixes `ref:`, `net:`, `drc:`, `sub:`, `text:`, `value:`, and `fp:` narrow a query, and `*` / `?` provide simple wildcards. Embeds omit the dock and keep native browser Find.
- **Version polling**: `GET /api/version/:name` — returns `{"version":N}`
- **Client interaction log**: `POST /api/client-log/:name` — ingest a batch of
  browser events into the server's interaction log (see **Interaction log**
  below). Body `{"page_build":"<9hex|unknown>","events":[{"t":<client epoch
  ms>,"evt":"<name>", …scalars}, …]}`; answers `{"ok":true,"n":<lines
  written>}`. Caps: body > 256 KiB → 413, more than 200 events → 400, non-JSON
  or no `events` array → 400. Same auth as every other `/api` route
  (`src/serve/request_log.zig`).
- **Value editing**: `POST /api/edit-value/:name` — edit component value in .sexp file
- **ERC**: `GET /api/erc/:name` — electrical-rule violations
- **Thermal facts**: `GET /api/thermal/:name[?ambient=NN][?layout=<saved>]` — the lumped
  steady-state thermal screening (`src/eval/thermal.zig`) as read-only JSON:
  `ambient_c`, the board `verdict`
  (`passive_ok`/`needs_airflow`/`needs_heatsink`/`over_limit`/`insufficient_data`),
  the `limiting_ref` it hangs on, the `max_ambient`/`min_ambient` window with the
  part setting each end, coverage `counts`, and a `parts[]` row per part
  (power/theta/limits/result; unknown figures are `null`, never 0). `:name` is a
  design or a bare `lib/modules` module (percent-decoded, resolved standalone
  through its parameter defaults); an unknown name is 404 plain text and a
  non-numeric `?ambient` is 400. `Tj = Ta + P·θJA` with no coupling and no
  layout — a screening yardstick, not a simulation. The same analysis renders as
  the **Thermal** panel on the schematic page, in the markdown report, on the
  review PDF's "Power & Bring-Up" sheet, and under the review JSON's `thermal`
  key (`src/review_thermal.zig` formats all of them, so no two surfaces can
  state different numbers). `?layout=<saved>` spreads the heat over that saved
  layout's own board rather than the design's default one, so two layouts of one
  design answer with different temperatures; a name nobody saved is answered
  with the sentence saying so instead of the default board's numbers, and naming
  the starred layout folds to the default board so both spellings share one
  cached solve. `GET /api/thermal-field/:name` (the board overlay's heat field)
  takes the same argument. CLI twin: `describe_thermal`, sharing this
  endpoint's whole body (`src/serve/thermal_api.zig`).
- **KiCad sync**: `POST /api/sync-kicad-pcb/:name` — file-based sync. Reads the `.kicad_pcb` declared by the design's `(kicad-pcb "<path>")` form, diffs it against the flattened netlist, and writes the updated board in place so footprint placements and routing are preserved. Driven by the schematic viewer's "Push to KiCad PCB" button, which dry-runs first and shows a categorized preview modal (board changes up top, metadata collapsed) before the real write, with a result toast. The heuristic relink (parent-path + value + net signature) is ON by default, so a refdes drift (e.g. FB→L) renames the placed part instead of staging a duplicate; a placement guard aborts the write with HTTP 409 if it would move, rotate, or side-flip any existing footprint; every write rolls a timestamped backup into a `backups/` subdirectory beside the board (`backups/<name>.bak-<stamp>`, newest 10 kept — the KiCad project dir stays free of `.bak-*` siblings). (`?dry_run=1` / `?prune=1` / `?no_migrate=1` / `?no_swap=1` modifiers — `no_swap` suppresses all `swap_footprint` geometry re-bakes so hand-tuned board lands survive; the withheld count is reported as `swaps_suppressed`.)

  The PCB editor also exposes the inverse **“⇡ Push to KiCad”** handoff. It
  flushes the editor save queue, requires an exact named saved layout, and
  previews `POST /api/sync-kicad-pcb/:name?push_layout=1&layout=<name>` before
  applying it with the current layout-sidecar `rev`. This explicit mode makes
  netlisp authoritative: it moves/flips and refreshes current design footprints,
  prunes stale KiCad footprints, and replaces all top-level tracks, copper
  arcs, vias, groups, and Edge.Cuts with the saved layout's routes and outline.
  The named layout must cover every current design footprint and have an
  outline. KiCad zones, board setup/rules, and unrelated drawings are preserved;
  netlisp-authored zones and board text are not exported yet, so refill the retained
  KiCad zones before using KiCad DRC or generating Gerbers. The ordinary sync's
  no-movement guard remains unchanged; only this named, revision-checked action
  may change existing placement. Writes retain the same atomic backup and
  pcbnew-lock warning behavior.

  **Seeding a FRESH board reproduces the starred layout whole — placement AND
  copper.** Three tiers pick each first-insertion pose: a `(sub-block …)` whose
  module has its own `lib/modules/<m>.layouts.json` default is seeded from THAT
  layout into an off-board staging band; then the design's own saved layout
  places anything left at its exact (x, y, rot, side); then a section-staging
  grid. Tier 1 **yields** when the board is fresh and the design layout already
  names every added part — the design layout is the more specific authority
  there (it positions the modules relative to each other and carries rotation +
  side), and letting module seeding win sent black-canyon's 46 sub-block
  children to ~300–457 mm while the other 56 parts landed correctly.
  `?no_seed_blocks=1` forces that same bypass when the layout covers most but
  not all of the board. A part that *does* reach the staging grid now keeps its
  saved rotation and side — the grid owns the position, not the orientation.
  On such a whole-layout seed the sync also writes the layout's **own saved
  copper** (tracks + vias, in board coordinates, untransformed) alongside the
  computed GND-stitch pass; net names go through the same "strip the hierarchy
  prefix only when the bare leaf is globally unique" map the pads got, so a
  saved `amp1/AMP_IN` track joins the pads on `amp1/AMP_IN` instead of splitting
  the net onto a bare `AMP_IN`, and copper on a net the design no longer has is
  dropped rather than renamed. `?no_layout_tracks=1` / `?no_layout_vias=1` seed
  placement only. All of it is gated on a fresh board with a fully-named seed:
  on a populated board saved coordinates would land in the middle of real work.
- **KiCad bundle**: `GET /api/export-kicad/:name[?schematic=0]` — the netlist +
  generated footprints + STEP models, **plus** the `.kicad_sch` hierarchy and its
  project sidecars, as one zip. Schematic inclusion is default-ON here (the
  archive then opens as a complete KiCad project); `?schematic=0` returns the
  netlist-only bundle this endpoint used to serve, byte-identical. The CLI's
  directory flow is the other way round — opt in with `--with-schematic`.
- **Library upload**: `GET /library`, `POST /api/upload-symbol`, `POST /api/upload-footprint`

### Interaction log

`netlisp serve` appends a structured record of what it did to
**`<project_dir>/logs/interactions-YYYY-MM-DD.jsonl`** — one JSON object per
line, one file per UTC day, created on demand (production's `projects/designs`
is gitignored under `/projects/`, so the logs never reach a commit). The path
is printed on stderr at startup. Writer: `src/serve/request_log.zig`; it is
best-effort throughout — a write failure can never fail a request — and it
records sizes, counts, names and timings only, never design content.

Every line carries four common fields: `ts` (ISO-8601 UTC with milliseconds),
`build` (`build_id.current()`, the 9-hex git short hash of the code that
produced the line), `src` (`server` or `client`) and `evt`.

| `evt` | Written by | Extra fields |
| --- | --- | --- |
| `server.start` | `serve()`, once per process | `port`, `project_dir` |
| `req` | the dispatch seam, once per request | `method`, `path`, `status`, `ms`, `bytes_in`, `bytes_out` |
| `stages` | an instrumented handler | `path`, `design`, `ms_total`, `stages:{<phase>:<ms>, …}` |
| *(client event name)* | `POST /api/client-log/:name` | `design`, `page_build`, `t_client`, plus the event's own scalar fields |

`ms` on a `req` line is the whole cost of answering — auth middleware, handler
and gzip included — measured on the monotonic clock. Fast requests under
`/api/version/`, `/assets/` and `/static/` are skipped below 100 ms, so the
browser's 2 s version poll does not bury the file.

Two handlers report their own phase breakdown, because whole-request timing
could not say which part of an autosave was slow:

- `POST /api/pcb-layouts/:name` → `parse`, `resolve`, `snapshot`, `write`.
  `resolve` is the whole-design re-evaluation inside
  `layout_save_layers.savedLayoutLayers`, which every save pays for the layer
  rules it validates a pour against; it is named apart from the rest of the
  write so a slow evaluator and a slow handler are distinguishable. (A save no
  longer scores the arrangement, so the old `score_poses` phase is gone — it was
  27.2 s of a 27.7 s Debug autosave on barracuda.)
- `POST /api/pcb-drc/:name` → `parse`, `resolve`, `restore`, `drc`, `pours`,
  `respond`. `resolve` is the reconcile session's design evaluation +
  `placeFromPoses` — near zero when the session answered from a retained
  placement, seconds when it had to build one.

Every `/api/*` response also carries **`X-Netlisp-Server-Ms`**, the same
whole-handler figure, so a browser can subtract server work from its own
`fetch` timing and post the difference back as a client event. The
`/pcb-layout` page's embedded `PCB` blob carries **`PCB.build_id`** — the build
that RENDERED the page — which the client echoes as `page_build`, so a tab held
open across a deploy files its events under the code that drew it.
### Startup: what is in front of the socket, and what is behind it

A merge deploys, and a deploy restarts this process, so "cold" is a state
production is in several times a day. The ordering that keeps that from being a
visible outage:

**Nothing expensive runs before `listen()`.** `serve()` configures rate limits,
builds `ServerState`, initialises the ward adapter from `WARD_*`, registers the
routes, and binds. Measured on the four-board corpus (ReleaseSafe, 2026-08-28):
**8 ms from exec to the first accepted connection.** The startup banner is
followed by `[I] startup: listening after N ms …`, which is the number to read
when a restart looks slow — if it is small, the delay is a *request*, not the
boot.

**The deploy health check never touches a design.** `.githooks/deploy-prod.sh`
polls `HEALTH_URLS` — `/.well-known/oauth-protected-resource` expecting **200**
and `/` expecting **302** — for up to `HEALTH_TIMEOUT` (90 s). Both are answered
ahead of every handler: the metadata route is on the session allowlist and
returns a static RFC 9728 document, and `/` is answered by
`ward_auth.authMiddleware`, which redirects an unauthenticated request to the
ward login *before* `pages.indexPage` is ever called. Neither can be delayed by
a cold cache, a warm-up sweep, or a design scan. Measured cold, at boot, the
metadata route answers in 4 ms.

Two things to know when reproducing this locally:

- **`NETLISP_DEV=1` changes what `/` means.** Dev mode bypasses auth for
  loopback, so `/` renders the actual home page — which on a cold process gathers
  every design and is the slowest read on the server. The deploy health check
  never sees that page, because prod does not set `NETLISP_DEV`.
- **Ward-less local runs answer 503, not 302**, by design (`sessionConfigured` is
  false → fail closed). That is not a health-check regression; it means the probe
  cannot be reproduced without `WARD_VERIFY_URL` / `WARD_LOGIN_URL` set. Check
  the *metadata* URL locally, and check the pair against a ward-configured
  server.

**Everything else warms behind the socket.** `serve/warmup.zig` runs on its own
thread: the design-summary gather first (`[I] warmup: N design summary(s) ready
in M ms`), then PCB editor pages, then their deferred `?derived=1` payloads, then
the progress ladders. A request that arrives mid-warm is never refused — it joins
the warm work per design (`serve/warm_sched.zig`'s `Flight`, and the PCB page
cache's own `reserveWarm`) rather than starting a duplicate render.

**The design scan is the one thing a request blocks on.** `GET /api/designs` and
`GET /` both evaluate every design under `src/` on a cold process. That scan is
now parallel across a bounded worker set (half the host's cores, capped at four)
and single-flighted per design, so a poller retrying during a restart joins the
scan in progress instead of starting a second one. Its floor is the single
slowest design in the corpus, since the response needs all of them.

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

### Structured CLI tools

Every structured operation is available locally without starting `netlisp
serve`. Run `netlisp tool list` for the authoritative JSON schemas, then invoke
one with `netlisp tool <name> --args '<json object>'`. Use `--args-file` for a
larger request and `--output` for text or decoded image output.

Tools include:

- **Project / introspection (read-only)**: `list_designs`, `list_library`,
  `list_history`, `list_instances`, `list_free_pins`, `get_net`,
  `describe_component`, `get_schematic`, `get_pcb_layout_image`, `get_version`,
  `run_checks`. `get_pcb_layout_image` returns the PCB layout
  as a PNG (same renderer as `GET /api/pcb-png/:name`) so
  an agent can visually inspect placement; args: `name`, optional `nets`/`refs`
  (arrays or comma-strings) to spotlight a subsystem, `route`, `width`, `layout`,
  `sub`, `regen`, `names` (ref|origin|both part labels), `pins` (label pad net
  names on the given refs, or "hubs"). `describe_pcb_layout` is its textual
  twin — the `/api/pcb-describe` facts JSON built from the identical placement
  (args: `name`, optional `route`/`layout`/`sub`/`regen`/`rough`/`pads`/`cropnet`;
  `pads` adds the full pad **obstacle set**, off by default because it roughly
  doubles the payload). `compare_layout_to_starred`
  scores the `?rough=1` seed against the design's starred (default ★) layout —
  per-interchangeable-class, per-IC-edge area-match, the "is the rough in the
  right general area to finish by hand" check (args: `name`). The image tool
  also accepts `crop`/`r`/`sheet`/`critique` view modes.
  **`diagnose_net`** (args: `name`, `net`, optional `layout`/`sub`) diagnoses ONE
  named net on the shown board — the CLI twin of `POST
  /api/pcb-route-analyze/:name`, sharing one `analyzeNetJson` body so the two can
  never answer about different boards. A failed net comes back
  `{net,status:"failed",failure_mode,why,blockers[],remedies[],drc_related[]}`, a
  routed one `{net,status:"routed",trace_mm,vias,layers[]}`. It exists because
  the whole-board answers cannot cover one net on demand: `route_experiment`'s
  `stuck[]` is capped at 16 and only ever describes nets that FAILED, so a net
  the board routed — or one buried past the cap — otherwise had no answer short
  of re-routing everything.
  **`describe_thermal`** (args: `name`, optional numeric `ambient`, optional
  `layout` naming a saved PCB layout) is the
  read-only twin of `GET /api/thermal/:name`, returning the identical bytes
  through one shared `thermalJson` body, so an agent and the browser can never
  be told different junction temperatures for the same design, ambient and
  layout. It
  resolves a design or a bare `lib/modules` module and touches nothing on disk.
- **Language / module authoring (read-only)**: `get_language_reference` —
  the auto-generated S-expression reference rendered live from the dispatch
  tables (same content as `docs/language-forms.md`; optional `section` arg
  returns one `## ` section). `preview_module` — evaluate a `lib/modules`
  defmodule standalone with caller-chosen args (request-local, nothing
  written): `view=summary` returns `{title,ports,instances,nets,sub_blocks,
  erc,assertions}`, `view=scene_graph` the full schematic JSON.
  For module-level *layout*, the PCB tools above accept a module name as
  `name` directly (resolved via a real instantiation in a design, else a
  zero-arg call).
- **VFS file ops**: `read_file`, `list_dir`, `glob` (read-only);
  `write_file`, `edit_file`, `delete_file`, `move_file` (mutation).
- **Build / state**: `build`, `regenerate_pinout`, `restore_version`.
- **KiCad schematic export**: `export_kicad_sch` — export a design's (or a bare
  module's) `.kicad_sch` hierarchy + project sidecars. Args: `name`, optional
  `vendor`/`flat` (the `--no-vendor-symbols` / `--flat` twins), optional
  `output_dir`. **Without `output_dir` it is a read**: the result is a compact
  summary (`{ok,name,sheets,components,vendor_bodies,instances,bytes_total,
  files[{name,bytes}],sidecars[{name,bytes}],written}`), never the sheet text
  — a real board is a megabyte across twenty sheets; fetch the bytes from
  `GET /api/kicad-sch/<name>` when you actually need them. **With `output_dir`
  it writes** the files there; the directory must be ABSOLUTE, free of `..`,
  and **outside the project directory** — this is an export, not a design edit,
  and a write into `projects/designs` would be swept up by the CLI auto-commit
  seam as if the agent had authored it. Registered as a mutation so the write
  path is gated to writer roles; an existing sidecar is kept, never overwritten.
  `sync_kicad_sch` is the push twin: it writes the schematic into the KiCad
  project directory the design's `(kicad-pcb "<path>")` names (args: `name`,
  optional `dry_run` / `force`), under the KiCad project's own name. Same
  guards as the endpoint above — a sheet that is neither a previous netlisp
  push nor an empty eeschema stub refuses the whole push, a KiCad lock refuses
  even with `force`, existing sidecars are kept, and replaced files roll into
  `backups/`. A refusal comes back as an `ok:false` result carrying the reason,
  not as a tool error.
- **Parts sourcing**: `search_components`, `resolve_mpn`, `check_stock`
  (read-only, DigiKey / Component Search Engine lookups); `download_footprint`,
  `download_datasheet` (mutation — import an ECAD model / datasheet into `lib/`);
  `read_datasheet` (read-only, extract text from an imported datasheet).
- **Per-design notes**: `list_design_notes` (read-only), `add_design_note`,
  `complete_design_note`, `reopen_design_note`, `remove_design_note`
  (mutation) — TODO sidecar (`<design>.notes.md`) for next-revision follow-ups.
- **Component requirements**: `list_component_requirements` (read-only),
  `add_component_requirement`, `remove_component_requirement` (mutation) —
  library `(requirement …)` rules that live on a part and are inherited by
  every design instantiating it (vs. `design_note`, which is per-design).

There is **no** granular `add_component` / `swap_component` / `edit_value` /
`rewire_pin` / `remove_component` tool — schematic edits go through
`read_file` → `edit_file` (or `write_file`) on the design's `.sexp` file,
then `build` to push the new version. Mutation tools
return the new `live_version`, so the browser picks up changes via its
existing 2 s poll of `/api/version/:name`.

### Hand routing from an agent: `add_tracks`

`route_pcb` / `route_experiment` only ever re-run the **autorouter**, and so do
every remedy `describe_pcb_layout`'s `stuck[]` emits. When a net's diagnosis is
`cdt_geometry_limit` ("CDT finds no path even with every foreign net removed —
no priority edit reopens it"), no amount of DSL/priority iteration can close it;
the loop is closed. **`add_tracks`** is the write seam that breaks it — the
mutation counterpart of `clear_routes`:

```jsonc
add_tracks {
  "name": "barracuda",
  "tracks": [{"net": "IF1_LPF", "layer": "F.Cu",
              "points": [[176.6, 101.6], [177.884, 101.6]]}],   // N points → N-1 segments
  "vias":   [{"net": "IF1_LPF", "x": 177.0, "y": 101.6}]        // optional, for layer changes
}
```

- Coordinates are board mm in the **same frame `describe_pcb_layout` reports**
  (x right, y **down**) — read positions there, draw them here.
- `width` / `dia` / `drill` are optional; omitted, they resolve through the net's
  `(net-class …)` rule exactly as `router.setNetParams` would, so hand copper
  matches what the autorouter would have drawn on that net.
- Copper is **appended** to the layout's persisted tracks/vias (custom pours are
  preserved), then DRC-checked against the current poses.
- Validation is **all-or-nothing**: an unknown net, an unknown copper layer, or a
  polyline with <2 points rejects the whole request, so a bad call never
  half-lands a route.
- The result carries post-edit `routed`/`total`/`open[]` from the shared
  connectivity oracle — you see immediately whether the copper actually **closed
  the net**, with no follow-up describe — plus `drc` (all violations) and
  `drc_errors` (the fab-blocking subset). **Gate rollback on `drc_errors`**: a
  sharp-bend or diff-skew *warning* is not a reason to reject good copper.

**Aiming data — `open_nets[]` and `?pads=1`.** `describe_pcb_layout` carries, for
every still-open net, `{net, islands, pads[], gaps[]}`: each pad's `ref`/`pad`/
`x`/`y`/`side`/`thru` plus the copper **island** it currently sits in, and the
shortest pad-to-pad **hops** that would close the net (`islands - 1` of them,
nearest first). Previously `stuck[]` gave precise coordinates for the copper
*blocking* a net but never for the net's own pads (hub pads were reduced to
compass words like `edges:["center"]`), so there was nothing to aim `add_tracks`
at. `?pads=1` / `pads:true` adds the full pad table (`ref`,`pad`,`net`,`x`,`y`,
`hw`,`hh`,`side`,`thru`) — the **obstacle set**, off by default because it
roughly doubles the payload. Without it a caller can dodge tracks and vias but
not foreign pads, and a straight bridge between two pads of an IC silently cuts
through the pads in between. (`pads` is declared in `describe_pcb_layout`'s
input schema as of 2026-08-04 — the handler always read it, but the schema is
`additionalProperties:false`, so a strict CLI client refused the very argument
the `close_open_nets` remedy string tells you to pass.)

**`route_experiment` names its own failures.** It carries `unrouted[]` (the
oracle's still-open net names — trust these over `stuck[]`, which is
router-derived, capped at 16, and can be empty while `routed < total`) and a
compact `open_nets[]` of `{net, islands, pads, gaps[{mm, from/to{ref,pad,x,y,
side}}]}` — the same closing hops describe reports, minus the obstacle table. So
one call both scores a plan edit and says which nets to aim `add_tracks` at,
instead of forcing a second full-board describe per trial. It also takes
`layout` / `sub` (which board) and `effort` (`one_shot` skips the rescue ladder —
the tier for an agent iterating), and routes with the shown layout's pours as
source copper so its board is the one `route_pcb` would commit.

**Pours are connecting copper.** `shownLayoutCopper` carries the layout's pour
zones into connectivity/fab-readiness. A rail poured rather than traced
(barracuda's `V_12V`/`V_5VA`/`V_6VA`/`V_3V3A`/`V_3V3_LMX`) is joined by its zone
and by nothing else; omitting zones made every pad on such a rail read as its
own isolated island.

**`route_pcb` success is not connectivity.** It reports per-net results from the
ROUTER's own view and treats a plane-carried net as nothing to do — on barracuda
it returns `1/1 routed` for `GND` in 2 s while the oracle finds 17 islands. Trust
`describe_pcb_layout`'s `routed`/`total`/`open_nets`, not the router's tally.

**One connectivity oracle.** `routed`/`total`/`open` everywhere now come from
`fab_readiness.routableTally` (over `netConnectivity`): the `add_tracks` result,
`/api/pcb-describe`'s `routed` block, and the completion ladder's routing rung.
Nets needing no copper (a single pad, or a plane-carried net the pour joins) are
excluded from **both** numerator and denominator. Previously a describe *without*
`?route=1` reported the router's own counters for copper the router never
routed — a hardcoded `routed:0,total:0` with an empty `unrouted[]`, which read
as "fully routed" on a board with 17 open nets. `?route=1` still means "throw the
saved copper away and autoroute fresh", so it answers about a **different board**
than the one on disk (and costs a full solve); prefer the plain call to ask what
is actually open.

**Git persistence for design mutations.** Production runs the designs repo as
a live working directory and batches persistence through
`netlisp-designs-checkpoint.timer`. Once per minute it checks the exact content
fingerprint of all dirty, non-ignored paths; after five unchanged minutes it
creates one checkpoint commit. Browser, CLI, and direct filesystem edits thus
share the same backup path, the checkout becomes clean between stable edit
batches, and a long editing session is not committed mid-write. The production
service sets `NETLISP_GIT_AUTOCOMMIT=0`; the checkpoint runs only on the live
checkout's `main`, skips hooks, never pushes, and leaves unrelated staged paths
alone. Configure the quiet period with `DESIGNS_CHECKPOINT_QUIET_SECONDS` when
running `.githooks/install.sh --deploy`.

The optional per-request auto-commit seam (`src/serve/autocommit.zig`) remains
available for other deployments. When enabled and `--project-dir` is a git
checkout, every **successful** CLI mutation is committed under the local CLI
identity. The seam is one choke point in `src/tool_cli.zig`: it snapshots the repo's
dirty paths *before* the mutation and commits exactly the paths that became
newly dirty *after* it (`after − before`). This means it is **path-scoped**
— never `git add .`/`-A`, so loose uncommitted human work already in the tree
is never swept in — and `history/` snapshots plus `*.bak-*`/`backups/`
artifacts are always excluded. The commit is authored as `netlisp-dev`, with
the committer left as the tool
(`netlisp <netlisp@server>`); the one-line message is
`cli: <tool> <paths…>`. It is **fail-open** — git missing, not a repo, a
commit race, or any non-zero git exit is logged to stderr and swallowed, so
the mutation result never fails because of git — and git index operations are
serialized by a mutex. Enabled by default; set **`NETLISP_GIT_AUTOCOMMIT=0`**
(env or `.env`) to disable. HTTP mutation endpoints (edit-value, layout
saves, uploads, attach-datasheet) do **not** yet share this seam — they are a
follow-up.

```bash
netlisp tool list
netlisp tool run_checks --project-dir projects/designs \
  --args '{"name":"barracuda","profile":"preflight"}'
netlisp tool get_pcb_layout_image --project-dir projects/designs \
  --args '{"name":"barracuda"}' --output barracuda.png
```
