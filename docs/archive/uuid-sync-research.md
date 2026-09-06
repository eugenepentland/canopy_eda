# Component UUID generation & KiCad sync — how it works today, why it loses sync, and what to research

> Research note. Goal: document the *current* mechanism end-to-end so we can
> redesign the identity model. Reference design throughout is
> `projects/designs/src/stm32n6/stm32n6.sexp` + its sibling `stm32n6.bom`.
>
> TL;DR — there are **three** identifiers for one physical part, bridged by
> derivation and heuristic matching:
>
> 1. an **8-char hex `(id …)`** authored/stored in the `.sexp`,
> 2. a **36-char UUID** stored in the per-design `.bom` file, and
> 3. a **`canopy_uuid` custom field** on the KiCad footprint (plus KiCad's own KIID).
>
> Only *some* components carry a real `(id …)` token in source. Decouple/series
> children and every sub-block instance get a **derived** id that is *recomputed
> every build* from volatile inputs (net names, host labels, positional index)
> and lives only in the `.bom`. When those inputs change, the id changes, the
> BOM's primary match misses, and the part falls through to weaker heuristics —
> that's the churn.

---

## 1. The identity chain

```
 ┌─────────────────────────── source of truth (authored) ───────────────────────────┐
 │  .sexp instance form                                                               │
 │     (instance "stm32" stm32n657l0h3q (id b22d91d5))                                │
 │                                   └────┬────┘                                      │
 │   8-char hex id — written ONCE, idempotent for top-level instances                 │
 └────────────────────────────────────────┬───────────────────────────────────────-─┘
                                           │  BOM Pass 0 match key = (id …)
                                           ▼
 ┌──────────────────── persistent UUID anchor (auto-generated file) ─────────────────┐
 │  src/<design>.bom                                                                  │
 │     (part "U8" "2bc6897c-52c9-5e1e-a6c3-e01f6ff60d14" "stm32n657l0h3q"             │
 │        (id "b22d91d5")                                                             │
 │        (nets "PSRAM_NCS" … "VDD.U8.J14" … "GND"))                                  │
 │   ref_des ── 36-char uuid ── family ── (id) ── net signature ── properties         │
 └────────────────────────────────────────┬───────────────────────────────────────-─┘
                                           │  inst.uuid  (export prefers BOM uuid;
                                           │             else uuidFromId(id))
                                           ▼
 ┌────────────────────────── KiCad-facing identity ──────────────────────────────────┐
 │  netlist:   (comp (ref "U8") … (tstamp 2bc6897c-…-0d14))                           │
 │  footprint: KIID = 2bc6897c-…  +  custom field  canopy_uuid = 2bc6897c-…           │
 └────────────────────────────────────────┬───────────────────────────────────────-─┘
                                           │  sync-plan match key:
                                           │     canopy_uuid → ref-des fallback
                                           ▼
                              KiCad PCB footprint placement + routing
```

Key files for each hop:

| Hop | File / function | What it does |
|-----|-----------------|--------------|
| Generate hex id | `src/eval/ids.zig:300 generateId` | random 8-char hex (first char `a–f`) |
| Derive child/sub id | `src/eval/ids.zig:308 deriveChildId` | SHA-256(parent ⨯ context ⨯ index) → 8-char hex |
| Write id into `.sexp` | `src/id_insert.zig:16 insertPendingIds` | inserts `(id …)` before a form's closing paren |
| Resolve identity → uuid | `src/bom_resolve.zig:68 resolveIdentities` | 5-pass match against old `.bom`, assigns `inst.uuid` |
| Persist uuids | `src/bom_resolve.zig:472 saveBom` | rewrites `src/<design>.bom` |
| id → uuid (deterministic) | `src/export_kicad.zig:59 uuidFromId` | SHA-256("canopy:"+id) → RFC-4122 v5 UUID |
| Emit netlist tstamp | `src/export_kicad_netlist.zig:50` | `inst.uuid` (else `uuidFromId(id)`) → `(tstamp …)` |
| Diff vs board | `src/serve/sync.zig:659 sync-plan handler` | matches design ⨯ board, emits ops |
| Read/apply board | `tools/kicad-sync-go/internal/{kicad,sync}` | reads footprints over IPC, applies ops |

---

## 2. Stage 1 — where the hex `(id …)` comes from

### 2.1 Random generation (`ids.zig:300`)

```zig
pub fn generateId(self: *Evaluator) EvalError![]const u8 {
    var bytes: [4]u8 = undefined;
    infra_random.bytes(&bytes);
    const first: u8 = (bytes[0] % ID_FIRST_LETTER_RANGE) + 'a'; // a–f
    return std.fmt.allocPrint(self.allocator, "{c}{x:0>2}{x:0>2}{x:0>2}{x:0>1}",
        .{ first, bytes[1], bytes[2], bytes[3], bytes[0] & 0x0f });
}
```

- First char forced to `a–f` so the tokenizer reads it as an atom, not a number.
- **Effective entropy ≈ 30.6 bits** (`log2(6)` + 24 bits from `bytes[1..3]` + 4 bits from
  `bytes[0]&0x0f`). For a few hundred parts the birthday-collision risk is small but
  **not checked anywhere** — there is no uniqueness assertion at generation time.

### 2.2 Which forms get a *real, written* id?

Only three call sites push to `pending_ids` (the list that `insertPendingIds`
writes back to the `.sexp`):

| Form | Call site | Gets a source-resident `(id …)`? |
|------|-----------|-----------------------------------|
| `(instance …)` | `instance.zig:106` | ✅ yes — written once, idempotent |
| `(series "REF" (comp) a b)` *named* | `instance.zig:452` | ✅ yes |
| `(series (comp) a b c d …)` *auto* | `instance.zig:429` | ⚠️ parent only — children **derived** |
| `(decouple …)` | `design_block.zig:248`, `:551` (via `getOrCreateFormId`) | ⚠️ parent only — children **derived** |

### 2.3 Idempotent re-parse (`ids.zig:286 parseId`)

On every build, `parseId` scans a form's children for the **first** `(id …)` and
returns it. If present, no new id is generated → top-level instances are stable
across rebuilds. If absent, a random id is generated and queued for insertion.

### 2.4 Insertion back into source (`id_insert.zig`)

`insertPendingIds` sorts pending entries by descending `form_offset` (so earlier
offsets don't shift), finds the matching `)` via `findMatchingClose`, and splices
` (id xxxxxxxx)` in front of it. Only the **board** `.sexp` is rewritten —
module-scope ids (offsets into a different file) are *deliberately discarded*
(`builders.zig:753, 779`).

> ⚠️ **Silent failure.** If `findMatchingClose` returns `null` (e.g. the byte at
> `form_children[0].span.offset - 1` is not `(` — possible when a comment or odd
> whitespace sits between the paren and the head atom), the loop just `continue`s
> and **the id is dropped**. Next build it's regenerated → a fresh random id →
> churn, with no error surfaced.

---

## 3. Stage 2 — derived ids for multi-instance & sub-block parts

This is the core of the instability. Three classes of component have **no
authored token in source**; their id is a pure function recomputed every build.

### 3.1 `deriveChildId` (`ids.zig:308`)

```zig
hasher.update(parent_id);  hasher.update(":");
hasher.update(context);    hasher.update(":");
hasher.update(index_str);
// → 8-char hex
```

### 3.2 Decouple children (`builders.zig:537–553`)

```zig
const sub_net = "{net}.{ref_str}.{target_pin}";          // e.g. "VDD.stm32.J14"
const cap_id  = try ids.deriveChildId(self, decouple_id, sub_net, ci);
```

`ref_str` is the host's **source label** captured during eval (`builders.zig:505`)
— `"stm32"`, *not* the auto-assigned `U8` (renaming to `U8` happens later in
`autoAssignRefDes`, and rewrites the stored net string after the id is already
fixed). So a decouple child's id is keyed on:

> **parent decouple id** ⨯ **net name** ⨯ **host label** ⨯ **pin** ⨯ **child index `ci`**

### 3.3 Series-auto children (`instance.zig:438`)

```zig
const child_id = try ids.deriveChildId(self, series_id, ta.nets.items[ni], ni / 2);
```

Keyed on: **parent series id** ⨯ **net name at that pair** ⨯ **pair index**.

### 3.4 Sub-block instances (`ids.zig:334 reassignSubBlockIds`, called `builders.zig:780`)

```zig
const context = if (inst.ref_des.len > 0) inst.ref_des else inst.label;
inst.id = try deriveChildId(self, sub_name, context, 0);   // nested: "{parent}/{child}"
```

Keyed on: **sub-block instance name** (`"adc1"`, `"buck"`, …) ⨯ **module-local
label/ref-des**. Random ids the module assigned during its own eval are thrown
away (`builders.zig:779`) precisely because they can't be written to the shared
module file. So a sub-block part's only persistence is the `.bom`, matched by
this derived id.

> The recent commit *"derive sub-block ids from stable label, not renumbered
> ref-des"* was a patch to exactly this function — confirming sub-block id churn
> has already bitten once.

### 3.5 Net signature in the BOM

`stm32n6.bom` shows decouple child `C36` as:

```lisp
(part "C36" "d04a86d5-7e1d-5b3c-a3d2-392d0c0af5e9" "cap-0201"
  (id "e0514e18")
  (nets "VDD.U8.J14" "GND")
  (mpn "0201X104K160CT"))
```

Note the stored net `VDD.U8.J14` is *post-rename* (`stm32`→`U8`), but the id
`e0514e18` was derived from the *pre-rename* `VDD.stm32.J14`. The two encodings
of "the same fact" are why a rename or net refactor can desync them.

---

## 4. Stage 3 — the BOM: persistent UUID anchor + heuristic matcher

`src/<design>.bom` (e.g. `projects/designs/src/stm32n6/stm32n6.bom`, 210 parts)
is auto-generated and stores, per instance: `ref_des`, 36-char `uuid`, `family`,
`(id …)`, `(nets …)`, and user properties (mpn, manufacturer…).

`resolveIdentities` (`bom_resolve.zig:68`) tries to carry each instance's old
UUID forward through **five ordered passes**, claiming each old entry at most once:

| Pass | Key | Survives… | Risk |
|------|-----|-----------|------|
| 0 | exact `(id …)` | ref-des rename, section move | misses if **id changed** (derived ids!) |
| 1 | exact `ref_des` | id removed/changed | misses if ref-des renumbered |
| 2 | same family + **sole** unclaimed survivor | rename of a unique part | wrong pick if >1 candidate |
| 2.5 | **net overlap ≥ 99%** (`bom.zig:223 netOverlap`) | small edits | breaks on rewire; can mis-bind |
| 3 | **mint**: `uuidFromId(id)` if id present, else random v4 | — | brand-new uuid (the "lost sync" event) |

`uuidFromId` (`export_kicad.zig:59`) = `SHA-256("canopy:" + id)` → v5 UUID, so a
*stable id* always yields the *same uuid* even without a BOM. But a **derived id
that drifted** produces a **new uuid** in Pass 3.

**When is it run / persisted?** `build`, `export-kicad`, `kicad-sync`
(`serve/sync.zig`), and the HTTP edit endpoints all call `resolveIdentities` and
then `saveBom` — i.e. the `.bom` is rewritten on essentially every mutation.

**Export precedence** (`export_kicad_netlist.zig`): `inst.uuid` (from BOM) wins;
`uuidFromId(inst.id)` is the fallback when the BOM hasn't assigned one yet.

---

## 5. Stage 4 — KiCad export & sync

### 5.1 Export

The resolved `inst.uuid` is written to the netlist as `(tstamp …)`
(`export_kicad_netlist.zig:50`). On the board each footprint carries KiCad's own
**KIID** plus a **`canopy_uuid` custom field** equal to the design uuid.

### 5.2 Sync-plan diff (`serve/sync.zig:659`, `matchInstance` `:1034`)

The Go agent reads footprints over IPC and POSTs `BoardFp{ uuid (=canopy_uuid),
kicad_uuid, ref, value, footprint, pads, … }`. The server matches each design
instance to a board footprint in priority order:

1. `by_uuid` — design `inst.uuid` == footprint `canopy_uuid` (claimed at most once).
2. `by_ref` — fall back to ref-des, **unless** that footprint's KIID is *reserved*
   by some other instance's uuid, or already claimed. On a by-ref match to a
   footprint lacking a `canopy_uuid`, the server emits `set_field` to **backfill**
   it so the next sync matches by uuid directly.
3. (migration only) net-signature / `(parent_path, footprint, value)` tuple.

The *double-claim guard* (`pickByUuidOrRef`, commit *"refuse double-claims in
matchInstance"*) and the *reserved-uuid* pre-walk exist specifically to stop the
**flip-flop** where two design instances collide on one footprint (one via uuid,
one via ref) and emit contradictory `set_field` ops every sync.

### 5.3 Apply (`tools/kicad-sync-go`)

- New parts: footprint created with **KIID = design uuid** at (0,0)
  (`internal/kicad/client.go AddFootprint`), so it's uuid-matchable next sync.
- Swap: new random KIID, but **all custom fields incl. `canopy_uuid` are copied
  over** so identity survives the swap.
- Strict mode (commit *"fail loudly when IPC degrades silently"*): if the
  "Update Footprint(s) From Library" `RunAction` is rejected, the agent records a
  warning, **skips writing the `applied_ops` sidecar** (forcing re-evaluation next
  sync), and — unless `--best-effort` — exits non-zero.

---

## 6. Where UUIDs lose sync — concrete failure modes

Ordered roughly by how often they likely bite.

### F1 — Derived ids drift when their inputs change *(primary suspect)*
Decouple/series children and sub-block parts have **no source-resident id**.
Their id is recomputed each build from net names, host labels, sub-block names,
and positional indices (§3). Any of these edits silently changes the id:

- renaming a net (`VDD` → `VDD_MCU`) — affects every decouple/series child on it;
- the `bus-net` / `bus-port` refactor (recent commits) changed net-name shapes;
- renaming a sub-block instance (`adc1` → `adc_1`) — re-keys *every* part inside;
- renaming the host label (`stm32` → `mcu`) — re-keys all its decouple children;
- inserting/removing an earlier entry in a `series`/`decouple` — shifts the
  positional `index`, re-keying every later child.

When the id drifts, **BOM Pass 0 misses**. Survival then depends on Pass 1
(ref-des) / Pass 2.5 (net overlap) still holding — and if the same edit also
moved the ref-des or rewired nets, all heuristics miss and Pass 3 **mints a fresh
uuid** → KiCad sees a new part, loses placement + routing.

### F2 — Auto ref-des is positional, and it's a fallback match key
Auto ref-des (`C1, C2, …`) come from per-prefix counters walked in source order
(`ids.zig:23 nextRefDes`). Insert one cap mid-file and everything after renumbers.
Ref-des is *id-independent* (good), but it's **Pass 1 of BOM matching and the
sync-plan fallback** — so a renumber that coincides with an id drift (F1) removes
the safety net. (In `stm32n6.bom` the MCU labeled `"stm32"` is `U8` purely by
position — add a `U`-part above it and it becomes `U9`.)

### F3 — Silent id-insertion failure
`insertPendingIds` drops an id when `findMatchingClose` fails, with no error
(§2.4). That instance regenerates a random id next build → guaranteed churn until
it happens to land cleanly.

### F4 — Three identifiers, two minting paths
Identity is split across `.sexp (id)`, `.bom uuid`, and KiCad `canopy_uuid`,
bridged by *derivation* (`uuidFromId`) **and** *independent minting* (BOM Pass 3
random v4 for id-less parts; `setBomProperty` stubs at `bom_resolve.zig:618`).
"Which uuid wins" depends on whether the BOM has resolved yet, so the same part
can get `uuidFromId(id)` on a fresh export but a different stored uuid after a
BOM resolve — a desync window.

### F5 — Heuristic mis-binding
Pass 2 ("sole survivor") and Pass 2.5 ("net overlap ≥ 99%") can transplant a uuid
onto the **wrong** part when multiple candidates exist or nets were rewired. This
desyncs *silently* — no error, just the wrong footprint keeps the placement.

### F6 — Legacy residue already in `stm32n6.sexp`
The current code attaches **at most one** id per form, but the file still carries
corruption from older insertion logic. These are inert today (`parseId` reads only
the first id) but pollute the source and risk mis-parse / mis-export:

- **Nested ids** — `stm32n6.sexp:102`:
  `(decouple … P7 (id cfc02418 (id b422d7a1) (id a60c6e44) (id abe074be) (id ac98150c)))`
- **Ids on a `note`** — `:151`: `(note "…" (id db0a04fb) (id c4ca02d6))`
- **Three ids on a `net`** — `:310`: `(net "GND" … (id fd3769fb) (id a3355d70) (id c1d107cc))`
  (notes/nets never request ids in the current code — pure residue.)
- **Non-hex hand-typed id** — `:135`: `(id c0de5wd6)` contains `w`/`s`; `uuidFromId`
  still hashes it to a stable uuid, but it violates the format invariant and
  bypasses any future hex validation.

### F7 — KiCad first-sync depends on ref-des backfill
Footprints placed in KiCad *before* their first sync have no `canopy_uuid`; they're
matched by ref-des and backfilled. If the ref-des was edited in KiCad first, or two
instances collide, you get duplicates or the flip-flop the double-claim guard exists
to suppress.

---

## 7. Options to research for a more stable model

Grouped from least to most invasive. None are decided — these are the design
space to evaluate.

### A. Give *every* component a source-resident, immutable id
The root cause of F1 is that derived ids have no anchor. Two ways to fix:

- **Expand-then-stamp.** On first build, expand `decouple`/`series` into explicit
  `(instance …)` forms in the `.sexp`, each getting its own written `(id …)` via
  the existing idempotent path. The DSL shorthand stays for *authoring*; the build
  "lowers" it once and from then on every part is a first-class instance with a
  stable token. (Trade-off: the source gets more verbose / less DSL-pretty.)
- **Child-id sidecar.** Keep the shorthand but write the children's ids back as a
  *flat, ordered list* attached to the parent form (e.g. `(ids a1 a2 a3 a4)`),
  parsed positionally so re-runs reuse them instead of re-deriving. Requires
  `parseId`/insertion to understand multi-id forms (today they don't — F6).

### B. Stop feeding volatile strings into id derivation
If derivation stays, seed it only from stable inputs: `parent_id` + a
**source-local ordinal** among that form's children — never the net name, host
label, or post-rename ref-des. That alone removes the net-rename and host-rename
churn (most of F1).

### C. Collapse to one identity with a pure `id → uuid` function
Make the authored `(id …)` the *only* identity token. Define
`uuid = uuidFromId(id)` everywhere and **drop the BOM's independent uuid field** —
the BOM keeps only properties (mpn/manufacturer/nets), keyed by id. This deletes
F4 and the entire heuristic-matching surface (F5): there's nothing to "match"
because the uuid is a deterministic function of an immutable id. (Requires every
component to have a real id first — i.e. A is a prerequisite.)

### D. Pin ref-des, or remove it from matching
Either assign ref-des once and persist it (BOM already stores it — make it
authoritative and stop renumbering), or drop ref-des from BOM Pass 1 and the
sync-plan fallback entirely and rely solely on the immutable id. Removes F2.

### E. Make insertion fail loud + idempotent for multi-id forms
`insertPendingIds` should return an error (or at minimum log + non-zero exit)
when it can't place an id, instead of silently dropping it (F3). Add a one-shot
**cleanup/lint pass** that strips nested ids, ids on notes/nets, and flags
non-hex/duplicate ids (F6).

### F. Stronger id tokens
Use the full first hex nibble (don't burn it to force `a–f` — instead prefix with
a fixed letter like `i` so atoms still parse), widen to e.g. 12 hex chars, and
**assert uniqueness at generation** against the in-memory + BOM id set.

### G. KiCad side: eager `canopy_uuid` on import
Stamp `canopy_uuid` at netlist-import time for *all* parts (not lazy ref-des
backfill on first sync), so the board never has uuid-less footprints and F7
disappears.

**Suggested starting point:** A (expand-then-stamp) + C (pure `id→uuid`) together
eliminate F1, F4, and F5 — the silent-churn modes — and reduce the BOM to a pure
property store. B is a smaller stop-gap if A is too invasive short-term. E and the
F6 cleanup are low-risk hygiene worth doing regardless.

---

## 8. Appendix — quick file/function reference

| Concern | Location |
|---------|----------|
| Random id | `src/eval/ids.zig:300 generateId` |
| Derived id | `src/eval/ids.zig:308 deriveChildId` |
| Parse existing id | `src/eval/ids.zig:286 parseId` |
| Queue id for insertion | `src/eval/ids.zig:347 getOrCreateFormId` |
| Auto ref-des | `src/eval/ids.zig:23 nextRefDes`, `:56 autoAssignRefDes` |
| Sub-block id reassign | `src/eval/ids.zig:334 reassignSubBlockIds` |
| Instance id at eval | `src/eval/instance.zig:100` |
| Series id | `src/eval/instance.zig:422–456` |
| Decouple id (top/section) | `src/eval/design_block.zig:248, :551` |
| Decouple child id | `src/eval/builders.zig:537–553` |
| Sub-block pending discard | `src/eval/builders.zig:753, :779` |
| Write id into `.sexp` | `src/id_insert.zig:16 insertPendingIds` |
| BOM load/save | `src/bom.zig`, `src/bom_resolve.zig:472 saveBom` |
| BOM 5-pass match | `src/bom_resolve.zig:68 resolveIdentities` |
| Apply uuid to instance | `src/bom_resolve.zig:438`, `src/bom.zig:267` |
| id → uuid (v5) | `src/export_kicad.zig:59 uuidFromId` |
| Netlist tstamp | `src/export_kicad_netlist.zig:50, :152–188` |
| Sync-plan diff / match | `src/serve/sync.zig:659, :1034 matchInstance, :1011 pickByUuidOrRef` |
| Go agent (read/apply) | `tools/kicad-sync-go/internal/{kicad,sync}/` |
| Reference design + BOM | `projects/designs/src/stm32n6/{stm32n6.sexp,stm32n6.bom}` |
