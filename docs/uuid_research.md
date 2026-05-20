# Fixing the Canopy ↔ KiCad Component-Identity Drift

## TL;DR

- **Stop deriving identifiers from volatile inputs.** The root cause of churn is exactly F1: `deriveChildId` (and the sub-block instance/series id assignment) feeds net names, host labels, and positional ordinals into a hash that is recomputed every build. Every other EDA tool that survives this problem — KiCad itself (KIID), Horizon EDA, Altium, atopile, SKiDL — gives every routable object an **immutable, source-resident or source-derivable identifier** assigned exactly once at *creation* time, not at every rebuild. Canopy must do the same.
- **Recommended path: A (sidecar child-id stamping) + C (collapse to a single id-only identity, drop the per-design `.bom` UUID) + E (loud, idempotent insertion and a one-shot cleanup) + G (eager `canopy_uuid` on KiCad import).** Keep the DSL shorthand exactly as it is; on first build of a parent that contains decouple/series/sub-block children, stamp a `(ids …)` sidecar list of stable 8-char tokens **into the parent form in source**, then derive the per-instance UUID purely as `uuidv5("canopy:" + id)`. Drop the `.bom` UUID column. F (more entropy in tokens) and B (stable inputs only) are useful supporting fixes but neither fixes the problem on its own. D (drop ref-des from matching) and pinned ref-des are partial mitigations that should ship in phase 1 but do not resolve the underlying drift.
- **Concrete ordering**: Phase 1 (ship this week) — hygiene: make `insertPendingIds` fail loud, add a lint/cleanup pass for orphan `.bom` rows, demote ref-des to last-resort in `pickByUuidOrRef`, add a uniqueness assertion in `generateId`. Phase 2 — expand the `(id …)` schema to `(ids …)` sidecars on decouple/series/sub-block parents, write a one-shot migration that stamps tokens for every existing derived child. Phase 3 — delete the `.bom` UUID column; rebuild `bom_resolve.zig` around id-only matching (the 5-pass matcher collapses to a 1-pass join). Phase 4 — teach the Go agent (`tools/kicad-sync-go`) to write `canopy_uuid` on any imported footprint that doesn't have one, using the deterministic `uuidv5("canopy:" + id)` formula.

---

## Key Findings

1. **Canopy's architecture matches Horizon EDA and SKiDL more closely than KiCad.** Horizon EDA assigns an immutable UUID at *creation* of every library and design item and uses **UUID v5 (RFC 4122)** to derive flattened-design UUIDs from a stable namespace plus the hierarchical instance path. Per DeepWiki's analysis of the SKiDL GitHub repository, citing `src/skidl/tools/kicad8/gen_netlist.py` lines 19–94: "SKiDL uses UUID5 (SHA-1 hash) with a fixed namespace to generate deterministic identifiers for parts and hierarchy levels: This ensures that regenerating the same circuit produces identical UUIDs, enabling stable association between netlists and PCB footprints across design iterations." Canopy already does the SHA-256("canopy:"+id) → v5 trick in `uuidFromId`, but its 8-char `id` itself is unstable for derived children, which defeats the determinism.

2. **KiCad's two-tier matcher is exactly what `pickByUuidOrRef` already implements**, and KiCad's design rule is the right one to copy. Per the KiCad 9.0 Schematic Editor documentation (`docs.kicad.org/9.0/en/eeschema/eeschema_schematic_to_pcb.html`): "In normal use, the Re-link footprints to schematic symbols based on their reference designators option should be unchecked. In this mode, symbols with the same identifier as a footprint will update that footprint, regardless of the reference designator." That is, ref-des is a *recovery* path, not a primary key. Canopy's failure mode F1 happens precisely when the KIID-equivalent (the canopy id) changes between builds, forcing fallback to the weaker ref-des heuristic — the same failure KiCad warns about when a "block of schematic [is] cut-and-pasted… break[ing] the identifier-based links."

3. **Altium teaches the strongest lesson about the cost of getting this wrong.** Altium's Unique IDs are the *only* primary key for the schematic↔PCB link; designators are deliberately demoted. Per the Altium Designer 15.1–17.1 official documentation (`altium.com/documentation/altium-designer/workspacemanager-dlg-failed-to-matchfailed-to-match-unique-identifiers-ad?version=17.0`): "The Failed to Match Unique Identifiers dialog is used to choose whether to manually match the components or to abort the process entirely… Yes - click to open the Match Manually dialog. No - click to abort the process." From version 18.0 onward, Altium replaced these options with "Automatically Create Component Links," making the silent-fallback case impossible. Canopy's BOM 5-pass match-then-fallback chain is the opposite of this discipline; F1 + F4 (ref-des collision after re-annotation) is the same failure pattern Altium guards against. The lesson: make ID-mismatch loud (Option E) and *never* silently fall back if an ID was previously stamped.

4. **Atopile and JITX show that the constraint "keep the DSL shorthand" is compatible with a stable-id model**, because both languages reify the hierarchy path into a stable address ("addressable" in atopile's case). Atopile's KiCad sync flow ("select the group you want to sync, and hit the 'Pull' (Down arrow) button to pull the layout from the module's KiCad layout file") relies on the compiler's hierarchical address — not on user-written tokens — to map the same module instance to the same footprint across rebuilds. The address is derived from the **source location** (file + module + member name), not from runtime net names. This is the lesson behind Option B's "stable inputs only," but as shown in §3 below, a *purely* hash-based stable-input approach can't quite reach KiCad-strength stability for shorthand-generated children when the user reorders source.

5. **Horizon EDA solved exactly this problem in Q4 2021** when it added hierarchical schematics in version 2.2 "Halo." Per the Horizon EDA Blog post "Progress Report September–December 2021 (What's new in Version 2.2)" by Lukas, published January 9, 2022 (`blog.horizon-eda.org/progress/2022/01/09/progress-2021-09-12.html`): "the arbitrary data consists of the instance path, i.e. the list of all instance UUIDs leading to a particular component or net, and the UUID of the component or net itself." The change totalled "about 6000 lines of code" per the same post. Crucially, Horizon does *not* hash net names or labels into the derived UUID; the input is the *instance path* of immutable per-instance UUIDs plus the child's library-defined identity. Net-name drift in a sub-block cannot propagate to the derived UUIDs because the inputs are the parent's stable instance UUIDs plus the child's library-defined slot — not runtime nets.

6. **Canopy's own SPEC.md already encodes the correct contract for the matcher.** Verbatim: "pickByUuidOrRef returns the by_uuid match when the instance's canopy_uuid is on the board / falls back to by_ref when canopy_uuid is missing and the fp is not reserved / refuses a by_ref match whose fp is reserved by another instance's canopy_uuid." This is good. The problem is upstream: the `canopy_uuid` *itself* changes between builds for derived children, so the by_uuid path silently misses and the by_ref fallback fires constantly. Fix the id; the matcher is already correct.

7. **The `.bom` UUID column is structurally redundant.** `uuidFromId` is a pure function `id → uuid`. The only reason to persist the uuid separately is to survive id-rotation, which is itself the bug we're fixing. Once every component has a stable source-resident `id`, the BOM can be id-keyed only, and `bom_resolve.zig`'s 5-pass matcher collapses to a single join. This is Option C, and it removes an entire class of "BOM row says one uuid, hash now says another" reconciliation bugs (F2/F3 territory).

---

## Details

### 1. Survey of how other EDA tools handle component identity and KiCad sync

#### KiCad (the target)
Every routable item in KiCad has a **KIID**: a UUID generated at object creation and serialized into every persistent file. Per the KiCad doxygen for class `KIID`, the same UUID is referenced by `SCH_LABEL::Serialize`, `FOOTPRINT::Serialize`, `PAD::Serialize`, and the API handlers `API_HANDLER_SCH` / `API_HANDLER_PCB`. For schematic↔PCB sync (the "Update PCB from Schematic" tool), KiCad's documented rule (KiCad 9.0 docs) is: "Symbols with the same identifier as a footprint will update that footprint, regardless of the reference designator. In normal use, the Re-link footprints to schematic symbols based on their reference designators option should be unchecked." When KIID-based linking breaks (e.g. after copy-paste and re-annotation of a block), KiCad provides a one-shot recovery via designator matching and then "the next forward annotation should use the normal identifier-based linking." The KIID is otherwise *immutable for the life of the object*.

KiCad v6+ uses random UUID v4 for KIIDs (the doxygen reference to "SHA-256 hash" in the spec is misleading; per the KiCad.info forum thread "UUIDs in schematic files v6", actual KiCad files contain v4 UUIDs like `8efee08b-b92e-4ba6-8722-c…`). Footprints carry **(tstamp …)** in legacy files and **(uuid …)** in 20240108+ (KiCad 8) files (as documented by the third-party `edea` library: "The tstamp field got renamed to uuid in 20240108 (KiCad 8)"). Sheet path uses **(KIID_PATH)** — slash-separated UUIDs — to disambiguate hierarchical instances.

**Implication for Canopy**: KiCad's KIID is exactly the analogue of Canopy's source-resident `(id …)`. The KIID has no "derived from inputs" mode; if KiCad had one, KiCad's PCB sync would have the same drift bug.

#### Horizon EDA
"All items get assigned an immutable UUID at time of their creation. This UUID is then used by other items to reference this item." Hierarchical blocks introduced exactly the problem Canopy faces — instantiating a sub-block must give every component inside the instance a per-instance UUID — and Horizon solved it deterministically. Per the Horizon EDA blog (January 9, 2022): "This requires generating unique and predictable UUIDs for components and nets from instantiated blocks. For this purpose, version 5 UUIDs specified in RFC 4122 come in handy as they describe how to derive UUIDs from arbitrary data… the arbitrary data consists of the instance path, i.e. the list of all instance UUIDs leading to a particular component or net, and the UUID of the component or net itself."

Crucially, Horizon does *not* hash net names or labels into the derived UUID; the input is the *instance map* stored in the top block, which itself contains the immutable per-instance UUIDs. Net-name drift in a sub-block cannot propagate to the derived UUIDs because the inputs are the parent's stable instance UUIDs plus the child's library-defined slot — not runtime nets.

#### Altium Designer
Altium's `Unique ID` is the primary key for the schematic↔PCB link; designators are not authoritative. From the standard tooltip in Altium 15.1+ ECO documentation: the ECO is the "list of modifications required to implement changes to one or more design documents in order to bring those documents into a state of synchronization," and synchronization is *Unique-ID driven*. When ID-based matching fails (e.g. after copying a sheet from another project), Altium 15.1–17.1 surfaces the "Failed to Match Unique Identifiers" dialog with the explicit "Yes — open the Match Manually dialog / No — abort the process" choice. From version 18.0 onward, Altium replaced these options with "Automatically Create Component Links," eliminating the silent-fallback case altogether. The deeper lesson: **never silently fall back when you've previously stamped an ID**.

#### Atopile
Atopile is the closest analogue to Canopy because both compile a textual DSL to a KiCad layout and both ship a KiCad plugin for sync. Atopile's identity model is the *hierarchical address* (atopile's "addressable" — file path + module + member name), which is intrinsically derived from source location. Layout sync is via "select the group you want to sync, and hit the 'Pull' (Down arrow) button to pull the layout from the module's KiCad layout file. The ato compiler will map layouts with a class or super-class that has a build." The address is stable as long as the user doesn't rename the module member; renaming a member is treated as a delete+create, which is acceptable because atopile users edit member names rarely.

The contrast with Canopy: atopile has **no decouple/series shorthand that synthesizes children whose names depend on net labels**. Every component in atopile is a named member, so its address is naturally stable. Canopy's shorthand violates this: the user writes `(decouple … 100nF)` and Canopy synthesizes a child whose only identity is "the decoupling cap on net VDD of host U1," which makes the natural address volatile. This is the exact mismatch the user's note identifies, and it's why atopile's "stable address" approach does not transplant unchanged — atopile doesn't have to solve this problem because its DSL doesn't have shorthand.

#### tscircuit
tscircuit ships KiCad export through `circuit-json-to-kicad`. Identity is `name` (JSX `name="R1"`), and exported KiCad files carry KiCad-format UUIDs that tscircuit emits at export time. tscircuit's `KicadFootprintProperties` schema preserves `uuid?: string` on every field. tscircuit does **not** appear to maintain a stable round-trip identity across edits — it is fundamentally a one-way generator. There is no equivalent of `pickByUuidOrRef`. The lesson here is negative: a one-way emitter is much simpler but gives up incremental layout preservation.

#### JITX
JITX's docs are explicit: "Reference designator prefix for this component… is a required data point for matching components between builds. If this value changes (including changing from unset to set), it will be treated as a new component, even if nothing else changes." Note that JITX is reference-designator-driven for build-to-build matching at the *prefix* level, not at the full designator. JITX also lets users explicitly pin a reference designator with `reference-designator(object) = "R5"`. The lesson: if Canopy adopts Option D, full-designator pinning (`U1` not `U`) must be source-resident, not generated. JITX's import note also matters: importing from KiCad requires that "Reference designators in the project files must be consistent. Nets on the board, in the schematic, and netlist must be consistent" — i.e. JITX assumes ref-des is the user-managed primary key and refuses to import if it isn't.

#### SKiDL
Per DeepWiki's analysis of the SKiDL GitHub repository, citing `src/skidl/tools/kicad8/gen_netlist.py` lines 19–94: SKiDL "uses UUID5 (SHA-1 hash) with a fixed namespace to generate deterministic identifiers for parts and hierarchy levels: This ensures that regenerating the same circuit produces identical UUIDs, enabling stable association between netlists and PCB footprints across design iterations." This is the closest direct precedent for Canopy's `uuidFromId`. SKiDL embeds the hierarchical name path into the UUID v5 input, and that name path is determined by the user's `Group()`/`SubCircuit` decorators — *not* by net names. This is Option B done right: stable inputs are *source-structural* (hierarchical group name path), not *electrical* (net name, host label).

#### Lepton EDA / gEDA family
Identity here is purely the ref-des (`R1`, `C2`), assigned by user or by `refdes` tools. There is no separate stable ID. The schematic→PCB flow is fragile under re-annotation; this is the model Canopy correctly chose to move beyond. Not recommended as a reference.

#### Comparison table

| Tool | Primary ID | Where stored | Derived-child strategy | Survives rename/reorder | KiCad sync |
|---|---|---|---|---|---|
| KiCad | KIID (UUID v4) | In `.kicad_sch` and `.kicad_pcb` next to every object | n/a (no shorthand) | Yes (until copy-paste of block) | Native; KIID-first, ref-des fallback |
| Horizon EDA | UUID at creation | JSON design files | UUID v5 from namespace + instance path | Yes — derived from immutable parent UUIDs | Not native |
| Altium | Unique ID | Schematic + PCB | n/a | Yes; explicit "reset Unique IDs" or "Automatically Create Component Links" (18.0+) | Native; UID-first, ECO confirms |
| atopile | Addressable (file::module.member path) | Source location | n/a (no shorthand) | Yes (until member rename) | Pull/push via plugin; address-keyed |
| tscircuit | `name` prop + emitted KiCad UUID | Source + export | n/a; one-way generator | Limited (one-way) | Export only |
| JITX | Ref-des prefix; designator opt. pinned | Source `.stanza` | Auto-generated; user can pin | Yes if user pins | Import/export only |
| SKiDL | UUID v5 from `Group()` path | Generated netlist | UUID v5 from hierarchical path | Yes (until `Group()` name change) | Netlist-only |
| **Canopy (current)** | 8-char hex `(id …)` + 36-char `.bom` UUID + `canopy_uuid` field on footprint | 3 places (sexp, bom, KiCad fp) | **Hashed from net names + host labels + positional index** (F1 root cause) | **No** — drifts on net rename, host rename, sub-block reorder | Custom Go IPC agent (`tools/kicad-sync-go`) |
| **Canopy (proposed)** | 8-char hex `(id …)` in `.sexp` only; uuid is `uuidv5("canopy:" + id)` | 1 place (sexp), 1 derived (KiCad) | **`(ids a1 a2 a3 …)` sidecar on parent**, stamped on first build | Yes — sidecars are persistent | Same Go IPC agent, but eager `canopy_uuid` write on import |

### 2. Evaluation of options A–G against the actual Canopy code

The SPEC.md test bullets confirm the existing contracts we have to preserve:
- `generateId produces 8-char hex starting with letter`
- `deriveChildId produces the same child ID when called with identical inputs / unique child IDs across different index values`
- `parseId extracts 8-char ID from form children` / `returns null when no ID present`
- `Pass 3.5 is a fixed point: two consecutive resolveIdentities calls produce a byte-identical BOM`
- `pickByUuidOrRef` priority is by_uuid → by_ref(if fp not reserved) → null

These bullets tell us: (a) the id schema is already a top-level child form, so adding a sibling `(ids …)` is purely additive; (b) fixed-point convergence of the BOM resolver is already a test, which we can re-use to verify the simplified resolver in Option C; (c) the matcher is already two-tier with reservation guards, so Option D and Option G are mostly about feeding it cleaner data.

#### Option A — Give every component a source-resident, immutable id

Two sub-variants:

**A.1 — Expand-then-stamp**: rewrite the shorthand into explicit instances in source on first build. *Conflicts with the user's constraint.* The whole point of `(decouple …)` and `(series …)` is to keep source compact and readable. Expand-then-stamp loses the abstraction and inflates diffs.

**A.2 — Child-id sidecar (`(ids a1 a2 a3 a4)` attached to the parent form)**: keep the shorthand syntactically, but on first build of a parent that has decouple/series/sub-block children, write a sibling form listing one 8-char hex token per generated child, in deterministic order. This is the right answer.

- **Pros**: minimal source-format change (one extra form per parent that needs it), no expansion of the shorthand, the existing `id_insert.zig` machinery (`findMatchingClose`, span-based insertion per CLAUDE.md) extends directly. Once written, the sidecar tokens are immutable, exactly like Horizon's per-instance UUIDs. The mapping "i-th synthesized child of parent X gets token `(ids X)[i]`" is purely positional within the *parent's* shorthand list, which is exactly the position the user wrote — far more stable than net names.
- **Cons**: requires a one-shot migration to stamp tokens into every existing parent that has derived children. Requires deciding on canonical ordering of synthesized children (e.g. for `(decouple …)`: order = `[bulk, hf1, hf2, ...]`; for `(series …)`: order = `[first … last]`; for sub-block instances: order = `(instance N times)` ordinal). This must be documented as an invariant and tested with a SPEC.md bullet.
- **Files touched**: `src/eval/ids.zig` (new `parseIdList`, `deriveChildIdFromSidecar`); `src/eval/builders.zig` (decouple child id derivation now reads sidecar instead of computing); `src/eval/design_block.zig` (decouple id assignment); `src/eval/instance.zig` (series/sub-block id assignment); `src/id_insert.zig` (new `insertPendingIdSidecars`); roughly 200–400 lines of Zig.
- **Solves**: F1 (volatile inputs eliminated for child ids), F2 (no more `(id …)` drift in source), partial F3 (some BOM rows can still go stale if a user deletes a parent — addressed in Phase E cleanup), F4 (children get real ids, so ref-des fallback stops firing), partial F5/F6/F7 depending on details.
- **Constraint compatibility**: ✓ keeps DSL shorthand verbatim.

#### Option B — Stop feeding volatile strings into id derivation (stable inputs only)

What counts as stable? *Source position* of the parent form (its byte offset or its parent-`(id …)` token), plus the *ordinal among siblings of the same shorthand role within that parent's body*. These are stable across net renames, host renames, and label edits. They are **not** stable across reordering the children inside the parent's source body — but reordering is a much rarer edit than renaming a net, and a positional ordinal is essentially what `(ids …)` would encode anyway.

- **Pros**: pure refactor of `deriveChildId`, no `.sexp` format change, no migration needed.
- **Cons**: still produces *new* ids when the user reorders siblings (e.g. swaps two decouple values), and Canopy has no way to distinguish "reorder" from "delete-and-insert" — so reordering still loses placement/routing. Also doesn't solve F2 (no source-stamped id means the user can't grep for it and the round-trip from KiCad still depends on `canopy_uuid` matching a derived value).
- **Verdict**: ship as a *transitional* fix in Phase 1 (gets you out of immediate pain), then supersede with A.2 in Phase 2. Alone it is *insufficient*.
- **Files touched**: `src/eval/ids.zig` only (one function). ~30 lines.

#### Option C — Collapse to one identity with a pure `id → uuid` function (drop BOM uuid)

`uuidFromId(id) = uuidv5(NS, "canopy:" + id)` is already pure. The `.bom` UUID column exists only to "remember" the uuid across drift. Once A.2 is in place, drift is eliminated and the bom uuid is redundant.

- **Pros**: removes a whole identity, simplifies `bom.zig`, `bom_resolve.zig` (the 5-pass match-and-fallback collapses to a 1-pass id-equality join), eliminates "bom uuid disagrees with computed uuid" as a class of bugs (F3 territory).
- **Cons**: requires Option A as a prerequisite (the user has identified this correctly). Until every component has a source-resident id, the bom uuid is the only stable thing to fall back on, so removing it without A.2 makes things worse, not better.
- **Files touched**: `src/bom.zig` (drop uuid column, rewrite `saveBom`), `src/bom_resolve.zig` (collapse passes 1–5 to 1-pass), `src/export_kicad.zig` (read uuid from `uuidFromId(id)`, not from `.bom` row), `src/serve/sync.zig` (`pickByUuidOrRef` matcher logic stays, but uuid input source changes). ~400–700 lines plus a `.bom` format migration tool.
- **Solves**: F2, F3, F5 (one source of truth → no divergence). Does not directly solve F1 but renders it moot because there's only one place to derive from.

#### Option D — Pin ref-des, or remove it from matching

The SPEC.md `pickByUuidOrRef` contract already uses ref-des only as a *fallback*. The bug is that the fallback fires too often because uuid matching keeps failing. Once A.2/C are in place, ref-des becomes pure UI sugar.

- **D.1 (pin ref-des in source)**: make `nextRefDes` look up an existing pinned designator in the source `(refdes "U7")` form before allocating. Good as a UX feature, doesn't fix the bug.
- **D.2 (remove ref-des from matching entirely)**: change `pickByUuidOrRef` to refuse the by_ref tier *unless* the instance has no `(id …)` at all. This is the right post-A.2/C policy: a pinned id never falls back; a missing id is treated as a brand-new component.
- **Files touched**: `src/serve/sync.zig` (matchInstance/pickByUuidOrRef policy bit). ~20 lines.
- **Recommendation**: implement D.2 in Phase 1 immediately, behind a feature flag, so that once A.2 ships the fallback path naturally dies.

#### Option E — Loud, idempotent insertion + cleanup/lint pass for legacy residue

The user's note has this exactly right. Current `insertPendingIds` quietly proceeds even when a parent already has an id; this is the source of F6 (legacy residue). The fix:
- `insertPendingIds` becomes a strict 3-state machine: (no id present) → insert; (id present and matches what we'd have generated) → no-op; (id present but disagrees with what we'd have generated) → **error and stop the build**, with a span-pointed message.
- A new `canopy lint --fix-legacy` pass: walks every `.sexp` and `.bom`, flags `(id …)` tokens that no longer correspond to any computed component (orphans), flags `.bom` rows whose `id` field doesn't appear in any source file, and offers to remove them.
- **Files touched**: `src/id_insert.zig` (rewrite `insertPendingIds`), new `src/lint.zig`. ~250 lines.
- **Solves**: F6 directly; F7 (the user's "stronger id tokens / uniqueness assertion") is best implemented as a check inside `insertPendingIds`: assert that the to-be-inserted id is not already present anywhere in the design.

#### Option F — Stronger id tokens (more entropy, uniqueness assertion)

8 hex chars = 32 bits = ~4.3 billion possible tokens. At the scale Canopy designs (hundreds of components per design), the birthday probability of a collision is negligible (~1.5×10⁻⁵ at 1000 components). The real risk is not collision per se but accidental reuse across designs or after copy-paste from another design.

- **Recommendation**: keep 8 chars for human-grep-ability; add a uniqueness assertion in `generateId` that scans the loaded design state and re-rolls on collision (per SPEC: "generateId produces 8-char hex starting with letter" — make the leading-letter constraint explicit and assert uniqueness across the whole design tree). Add a `canopy lint` rule that errors on duplicate `(id …)` tokens within a single design.
- **Files touched**: `src/eval/ids.zig` (~50 lines).
- **Solves**: F7 (and the "after copy-paste from another design" edge case).

#### Option G — KiCad side: eager `canopy_uuid` on import

When the Go agent (`tools/kicad-sync-go`) sees a footprint on the board that has no `canopy_uuid` field but whose ref-des matches a Canopy instance, it should write `canopy_uuid = uuidv5("canopy:" + id)` into the footprint *immediately*, in the same sync transaction. This closes the "imported via 'Update PCB from Schematic' without ID" gap and makes future round-trips uuid-keyed even if the user does something unusual.

- **Files touched**: `tools/kicad-sync-go/internal/kicad/` (footprint property write), `tools/kicad-sync-go/internal/sync/` (apply ops). ~150 lines of Go.
- **Solves**: the migration cliff for existing designs that already have a KiCad layout but no canopy_uuid fields populated.

#### Side-by-side: which options solve which failure modes

| Option | F1 (derived id drift) | F2 (.bom UUID drift) | F3 (canopy_uuid drift) | F4 (ref-des collision) | F5 (3 identities diverge) | F6 (orphans) | F7 (token uniqueness) |
|---|---|---|---|---|---|---|---|
| A.2 (sidecar) | **Solves** | partial | partial | indirect | partial | — | — |
| B (stable inputs) | partial | partial | partial | indirect | — | — | — |
| C (drop bom uuid) | — | **Solves** | **Solves** | — | **Solves** | — | — |
| D.2 (drop ref-des match) | — | — | — | **Solves** | — | — | — |
| E (loud + cleanup) | — | — | — | — | — | **Solves** | partial |
| F (entropy) | — | — | — | — | — | — | **Solves** |
| G (eager canopy_uuid) | — | partial | **Solves on import** | — | partial | — | — |

A.2 + C + D.2 + E + F + G together solve F1–F7 completely. B is subsumed by A.2 (don't ship both as the long-term answer; ship B in Phase 1 as a stopgap if A.2 isn't ready, then drop B).

### 3. Concrete phased implementation plan

#### Phase 1 — Hygiene (1–3 days, ships independently)

1. **Make `insertPendingIds` strict** (`src/id_insert.zig`):
   - States: no-id → insert; matches → no-op; disagrees → **abort** with `error.IdMismatch` and a span-pointed message.
   - Add an `--allow-id-rewrite` CLI flag for the one-shot migration only; default off.
2. **Demote ref-des fallback** (`src/serve/sync.zig`, `pickByUuidOrRef`):
   - Add an `instance.has_stamped_id` bit threaded through the matcher.
   - New rule: if `has_stamped_id` and uuid doesn't match anything on the board, return null. Only allow the by_ref tier when `!has_stamped_id`. This is D.2.
   - Update the SPEC.md `pickByUuidOrRef` bullets to reflect the new gate.
3. **Add uniqueness assertion in `generateId`** (`src/eval/ids.zig`):
   - Pass the loaded design's id set in; reject and re-roll on collision. Implements F (Option F).
4. **Add a `canopy lint` command** with two rules:
   - Orphan `(id …)`: an id appears in source but no component computed for it (suggests delete).
   - Orphan `.bom` row: a row whose id appears in no source file.
5. **Tests**: extend the SPEC.md `## id_insert` section with a "rejects mismatched id" bullet and a "uniqueness assertion across whole design" bullet.

This phase alone stops the bleeding: existing derived-id drift now produces a *loud error* instead of silent ref-des fallback, and the user can either accept the drift (with `--allow-id-rewrite`, in which case KiCad placement is intentionally lost) or fix the root cause.

#### Phase 2 — Sidecar identity model (1–2 weeks, requires Phase 1)

1. **Define the `(ids …)` sidecar form** (`src/eval/ids.zig`):
   - `(ids a1b2c3d4 e5f6a7b8 ...)` is a sibling form of `(id …)`, attached to the parent shorthand form.
   - Order convention (write as a SPEC bullet): decouple → `[bulk, hf₁, hf₂, ...]`; series → `[first … last]`; sub-block instance → ordinal in source order of the parent's `(instance N times …)` form.
2. **New helpers**:
   - `parseIdList(form) -> []const Id` (mirrors `parseId`).
   - `deriveChildIdFromSidecar(parent_sidecar, role, ordinal) -> Id` replaces `deriveChildId`.
   - On first build: if a parent has shorthand children but no sidecar, generate fresh ids for each (via `generateId` for uniqueness) and emit them via `id_insert.zig`'s new `insertPendingIdSidecars`.
3. **Update callers**:
   - `src/eval/design_block.zig` decouple id assignment: read from sidecar; if missing, emit pending.
   - `src/eval/builders.zig` decouple child id derivation: same.
   - `src/eval/instance.zig` series + sub-block instance id assignment: same.
4. **One-shot migration tool** (`canopy migrate-ids`):
   - For each `.sexp`, evaluate, find every parent that synthesizes children but lacks `(ids …)`.
   - Compute fresh ids (via `generateId`, with uniqueness against everything in the design).
   - For each computed child, find the *existing* uuid in the `.bom` (the one currently being used to match the KiCad footprint). Record the mapping `new_id → old_uuid` in a one-shot `canopy_migration.json`.
   - Write the `(ids …)` sidecar into source.
   - Rewrite the `.bom` so that each row's `id` field is the new stamped id (we'll keep the uuid column for one more phase to bridge).
   - Optional: emit a `canopy_uuid` rewrite plan for the Go agent: "footprint with old uuid `X` should be relabeled with new uuid `uuidv5("canopy:" + new_id)`". Apply this in the next KiCad open via the IPC agent. This preserves placement and routing across the migration.
5. **Tests**: add SPEC bullets for sidecar ordering, sidecar idempotence across rebuilds, and "child id stable across net rename" / "child id stable across host rename" / "child id stable across sub-block name change" — those are the F1 regression tests.

#### Phase 3 — Drop the `.bom` UUID column (a few days, requires Phase 2)

1. **Format change** (`src/bom.zig`):
   - Old row: `id, uuid, mpn, value, footprint, ...`. New row: `id, mpn, value, footprint, ...`. UUID is computed on the fly via `uuidFromId(id)`.
   - Bump `.bom` schema version; old `.bom`s are auto-converted on first load by stripping the uuid column.
2. **Collapse `bom_resolve.zig`**:
   - The 5-pass matcher becomes a single pass: for each computed component, find the bom row whose `id` equals the component's `id`. The "Pass 3.5 fixed point" property is trivially preserved because there's no rotation to converge on.
   - Keep `resolveIdentities` as the entry point (it still resolves *non-ID* fields like mpn from supplier lookups), but the identity resolution itself is the trivial join.
3. **Tests**: re-run the "Pass 3.5 is a fixed point" bullet against the simplified resolver and confirm.
4. **Risk**: any tool that was reading the `.bom` uuid column directly (e.g. a script the user has outside the repo) will break. Mitigation: keep a `canopy bom --legacy-uuids` export mode for one release.

#### Phase 4 — KiCad-side eager `canopy_uuid` (a few days, ships any time after Phase 2)

In `tools/kicad-sync-go/internal/sync/`:
- When the Go agent reads the board state and a footprint has no `canopy_uuid` property but its ref-des matches exactly one Canopy instance with a stamped id, **write** `canopy_uuid = uuidv5("canopy:" + id)` into the footprint as part of the sync-plan apply step. Log it as an `op: stamp_canopy_uuid` so it's auditable.
- When the agent reads a footprint whose `canopy_uuid` doesn't match any computed instance, treat it as an orphan and surface in the sync plan ("Footprint U7 has canopy_uuid X; no matching instance in source. Delete or reassign?").
- Test: round-trip a brand-new design that the user imported into KiCad without canopy_uuid fields → expect the agent to stamp all of them on first sync.

#### What can ship independently

- Phase 1 ships on its own (no `.sexp` or `.bom` format changes, no migration).
- Phase 4 ships on its own (the agent doesn't depend on Phase 2/3).
- Phase 2 requires Phase 1.
- Phase 3 requires Phase 2.

A pragmatic rollout: Phase 1 + Phase 4 this week, Phase 2 next week with a migration day for the `stm32n6` reference design, Phase 3 the week after.

### 4. Test strategy

Use the existing SPEC.md fixed-point and idempotence convention to lock in the new invariants. New required bullets:

Under `## eval/ids`:
- `parseIdList parses (ids a b c) into [a, b, c]`
- `deriveChildIdFromSidecar returns the i-th token`
- `child id is stable across net rename of host`
- `child id is stable across host label rename`
- `child id is stable across sub-block name change`
- `generateId rejects collisions against the existing design`

Under `## id_insert`:
- `insertPendingIds rejects mismatched (id …) and aborts the build`
- `insertPendingIdSidecars inserts (ids …) idempotently on rebuild`

Under `## bom-resolve` (Phase 3):
- `resolveIdentities is a 1-pass id-equality join after Phase 3`
- `Pass 3.5 fixed point trivially holds when no uuid column exists`

Under `## serve/sync`:
- `pickByUuidOrRef refuses by_ref fallback when instance has a stamped id`
- existing `pickByUuidOrRef` bullets remain (they're correct)

End-to-end regression on `projects/designs/src/stm32n6/`:
- Build → KiCad open → place a few footprints → close → rename a net in source → rebuild → re-open KiCad → assert all placements preserved.
- Repeat for: rename host label, reorder decouple values (this *should* drift placement of swapped pair only), delete a sub-block instance (placement of remaining instances preserved).

---

## Recommendations

**Do this:**

1. **Ship Phase 1 (hygiene) immediately.** It's a pure tightening of existing code, no format changes, no migration. The loud-fail on id mismatch alone will reduce the user's pain by stopping the silent ref-des fallback that produces churn today.
2. **Adopt Option A.2 (sidecar) + C (drop `.bom` uuid) + D.2 (drop ref-des match for stamped instances) + E (loud + lint) + F (uniqueness) + G (eager canopy_uuid).** Reject A.1 (expand-then-stamp violates the DSL-shorthand constraint) and treat B as a one-week stopgap if Phase 2 slips.
3. **Borrow Horizon EDA's UUID v5 derivation discipline**: never feed *runtime electrical* data (net names, label names, sub-block instance names that can be edited) into id derivation. Only feed *immutable structural* data: the parent's stamped id and the child's role/ordinal within the parent. The `(ids …)` sidecar is the source-resident realization of this discipline.
4. **Borrow Altium's "fail loud on ID mismatch" discipline**: if an id was previously stamped and now disagrees with what would be generated, the build must stop and ask the user, not silently emit a new id.

**Benchmarks/thresholds that would change the recommendation:**

- If the user finds that >5–10% of designs contain shorthand parents that themselves get renamed (e.g. the host U-prefix component is replaced with a different part) often, then the parent's own stamped id is no longer a stable anchor for the sidecar, and the recommendation shifts toward storing the sidecar in a separate `.ids` sidecar *file* keyed by file+byte-range — heavier but more robust.
- If `generateId` collision rate exceeds 1-in-1000 on real designs (it won't at 32 bits / hundreds of components), bump to 10–12 hex chars (Option F's stronger form).
- If round-trip sync turns out to need to handle KiCad designs imported from other tools (e.g. from atopile or tscircuit), prioritize Phase 4 over Phase 3 (you'd want `canopy_uuid` stamping before you've simplified the `.bom`).

**Open questions to validate against source** (the actual `.zig` files could not be fetched during research; these should be checked):
- Confirm `deriveChildId`'s exact hash inputs. The user's note says "net names, host labels, sub-block names, positional index"; verifying this in `src/eval/ids.zig` will confirm Phase 2's stable-input list.
- Confirm the `.bom` row schema. The Phase 3 migration script needs to know the exact column order.
- Confirm whether `canopy_uuid` is written as a KiCad footprint *property* or *field*. KiCad v8 uses `(property "canopy_uuid" "...")` syntax for footprints; the Go agent's KiCad IPC code in `tools/kicad-sync-go/internal/kicad/` should confirm.
- Confirm what the existing 5 passes of `bom_resolve.zig` actually do (only Pass 3.5 is named in SPEC.md). If pass 4 or 5 does something semantically meaningful beyond identity resolution (e.g. supplier reconciliation), Phase 3 must preserve that, not delete it.

---

## Caveats

- **The lead agent and the dispatched subagent were unable to fetch the actual Zig and Go source files** for `src/eval/ids.zig`, `src/eval/instance.zig`, `src/bom.zig`, `src/bom_resolve.zig`, `src/export_kicad.zig`, `src/serve/sync.zig`, `tools/kicad-sync-go/internal/*`, and the reference `.sexp` / `.bom` files. All claims about Canopy's internals in this report are grounded in: (a) the user's own description in the task prompt, (b) `SPEC.md` test-bullet excerpts which were the only source-tree content reachable, and (c) `CLAUDE.md` architectural notes. Specific line counts, function signature shapes, and exact `.bom` row formats above are estimates and should be confirmed against the actual source before implementation begins.
- **No direct Canopy code excerpts are quoted** for the same reason. The implementation plan's file targets (e.g. "rewrite `src/id_insert.zig`'s `insertPendingIds`") are derived from the user's prompt enumeration of files and from CLAUDE.md's module list.
- **KiCad's UUID format claim is mixed.** The KiCad spec text refers to "SHA256 hash" but KiCad in practice emits UUID v4 (random). Forum discussion confirms the spec is misleading here; the practical reality is v4 random UUIDs for KIIDs. Canopy is free to keep using UUID v5 (deterministic, derived from id) because the KiCad side only requires uniqueness, not v4-specific entropy.
- **Altium's "Reset Component Unique IDs" command** is mentioned as a recovery tool in third-party (4pcb.de) tutorial content, not in Altium's official docs that I could verify. The principle (Altium uses Unique IDs as primary key, designators as label) is well-established in Altium's official ECO documentation, but exact menu paths may vary by Altium version.
- **Horizon EDA's UUID v5 derivation** is described in the January 9, 2022 progress blog post for v2.2 "Halo." The actual code path is in `src/block/` and the JSON serialization is documented in the Horizon docs; the high-level design is verified verbatim but not line-by-line code-level details.
- **The "5-pass" structure of `bom_resolve.zig`** is the user's terminology and is corroborated only loosely by SPEC.md (which names "Pass 3.5"). The full pass list is not in SPEC.md or CLAUDE.md.
- **F1 as primary suspect**: the analysis above treats the user's F1 hypothesis as correct (derived ids drift on volatile inputs). This is consistent with every artifact I could verify, but the actual hash function in `src/eval/ids.zig` should be inspected to confirm the input list before committing to the Phase 2 design.