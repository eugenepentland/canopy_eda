# Codebase Maintainability Audit

_A survey of redundancies to remove, code to simplify, and structural improvements that make the tree easier to work on. Findings are verified against the whole `src/` tree (grep-confirmed reference counts), and ordered by impact ÷ effort. Nothing here is a correctness bug — it's all drift that quietly raises the cost of the next change._

## Executive summary

The codebase is in genuinely good shape. The health signals are strong: only 7 TODO markers (all legitimate "design-note" references, not debt), ~10 lines of commented-out code, **no orphaned test files** (every one of the 70 test-bearing files is reachable from `main.zig`'s import closure, so `zig build test` runs them all), and Guardian's file/function-size caps are holding. The two output layers that looked most duplication-prone on inspection — the review emitters and the KiCad/`.sexp` emitters — turned out to be **correctly factored** (shared model, format-specific serializers), so the big risky merge is *not* warranted.

The real opportunities are concentrated in four themes:

1. **Cross-module helper duplication** — the same small utility is copy-pasted across 2–4 files where one shared home would do: `sha256Hex` (×4), the auth-store persistence pattern (×4), HTML/JSON/S-expr escaping (×2–3, some bypassing the canonical `json_writer`), `warnResolveIdentities` (×3), `baseNetName`/`containsCI`/`isTestPoint` (×3 each).
2. **The SVG↔JSON scene-graph emitters** — `render_json.zig` is a structural clone of the `render_svg/*` pipeline; every layout change must be made twice. This is the single largest lockstep-edit surface.
3. **Accumulated dead code** behind Zig's silence on unused file-scope decls — whole rendering paths, abandoned-approach residue, stranded constants/aliases. All grep-confirmed zero-caller.
4. **A few stale/contradictory metadata items** — comments and an arity schema that disagree with the code (and, in one case, with generated docs).

---

## Quick wins — dead code (pure deletions, grep-confirmed zero callers)

Each is a straight subtraction with no behavior change.

- [ ] **`render_json.zig` dead port-block path** — `collectPortBlock`, `countDir`, `countNonOut`, `JsonPort`, `JsonPortBlock`, `SceneGraph.port_blocks`, the local `PORT_BLOCK_PAD`/`PORT_SPACING` (`render_json.zig:62-63`), and the serialization loop (`render_json.zig:1754-1787`). `scene.port_blocks` is always empty → output unchanged.
- [ ] **`placement/optimizer.zig` abandoned `aux_pads` residue (~80 lines, 3440-3522)** — `pinoutKey` (3440), `AUX_TOKENS` const, `isAuxRailPin` (3468, only called by the dead loader), `loadAuxPads` (3494). Leftover from the aux-pad approach that `pin_roles.zig` replaced; zero live callers.
- [ ] **`serve/sync.zig` dead tail** — `sha256Hex` (2689), `FootprintEntry` (2678), `ModelEntry` (2684), and the now-orphan `Sha256` import (14). Zero in-file uses.
- [ ] **`serve/edit.zig`** — `parseJsonFloat` (912) and `designBomPath` (999): private, zero callers tree-wide.
- [ ] **`render_svg/context.zig:176 collectSubBlockAsHub`** (~40 lines) — zero call sites; live path is `collectFlatWithRenames`.
- [ ] **`render_svg/draw.zig` `compactPinNumbers`** (423) + its two tests (434, 442) — no production caller since stub-folding replaced the "Nx pins" collapse.
- [ ] **`review_html.zig:279 writeSections`** — private, zero callers (live paths are `writeSectionCoverage`/`writeSection`).
- [ ] **`render_svg/hub.zig` stranded aliases + constants** — 6 aliases (`hub_width`, `hub_x`, `pin_stub`, `shortRef`, `displayValue`, `writeDebugPin`, lines 9-18) and 7 layout constants (`HUB_VPAD`, `HUB_TITLE_Y`, `PIN_LABEL_PAD_X/Y`, `PIN_NUMBER_INSET_LEFT/RIGHT`, `PIN_NUMBER_BASELINE`, 25-31). Live copies live in `section_inset.zig:22-31`.
- [ ] **`render_svg/connection.zig:125-126`** — discarded `total_height` local + its `_ =` discard; rename `total_h2`→`total_height`.
- [ ] **`serve/mcp.zig`** — drop `errorEnvelopeRawId` (253; `errorEnvelope(…, null, …)` is byte-identical), and collapse the JSONRPC `*_ABS` magic-number dance (13-24) to four direct `const … : i32 = -32600;` (the `magic-number` checker that motivated it is in `guardian.toml`'s `disabled` list).
- [ ] **`sexpr/printer.zig`** — drop `FALLBACK_INT_WIDTH` (6, 102-106); an i64 is ≤20 chars in a 24-byte buffer so the fallback is unreachable (`bufPrint(…) catch unreachable`). **Keep** the float/unit fallbacks — those are reachable.

## Quick wins — helper hoists (collapse N copies to 1, behavior-preserving)

- [ ] **`sha256Hex` ×4 → one util.** Three copies are byte-identical (`oauth_store.zig`, `plugin_tokens.zig`, `sync.zig`); `vfs.zig` is a buffer-writing variant of the same logic. Put one `pub fn sha256Hex(allocator, input) ![]u8` (+ a buffer overload) in a shared `serve/` or `infra/` util; delete the rest. (The `sync.zig` copy is also dead — see above.)
- [ ] **Auth-store persistence pattern ×4 → shared store helper.** `users.zig`, `oauth_store.zig`, `plugin_tokens.zig`, `passwords.zig` each implement `ensureAuthDir` (**byte-identical** `makePath`+warn), `ensureLoaded` (lazy load), `load`, `save` (read/parse/serialize/atomic-write JSON under `auth_dir`). Extract a small generic "JSON file under auth_dir" store (or at minimum hoist the identical `ensureAuthDir`).
- [ ] **Route JSON escaping through the canonical `json_writer`.** `json_writer.zig` already exports `writeEscaped`/`writeString`, but `diagram/render.zig:912` (`writeEscaped`), `serve/pcb_layout_page.zig:2101` (`writeEscaped`) + `:2121` (`writeJsonStr`), and `serve/footprint_preview.zig:389` (`writeJsonStr`) re-implement it. Import the shared one. _(Note: `emit.zig:180 writeString` is **not** a dup — it wraps raw bytes for S-expr output and deliberately does not escape. Leave it; maybe rename for clarity.)_
- [ ] **One HTML-escape util.** `writeHtmlEscaped` ×3 (`review_html.zig`, `render_html.zig`, `serve/modules.zig`) and `writeUrlEncoded` ×3 (same files). Create one shared helper. ⚠️ `render_html.zig`'s copy omits the `'`→`&#39;` escape the other two have — reconcile that difference deliberately when merging.
- [ ] **`component_info.zig` ↔ `design_doc.zig` overlap.** Both define `writeSexprEscaped`, `writeJsonError`, `validComponentName`, `writeComponentFile`. Hoist into one shared component-file module.
- [ ] **`warnResolveIdentities` ×3 → `bom.zig`** (it owns `resolveIdentities`). Delete the byte-identical copies in `mcp_tools.zig:58`, `sync.zig:92`, `edit.zig:69` (10 call sites).
- [ ] **`isTestPoint` ×3 → one predicate.** Identical in `review.zig`, `coverage.zig`, `serve/bom_html.zig` (two take `Instance`, one takes the component string — standardize on the string form).
- [ ] **`baseNetName`** — alias `render_svg/draw.zig:332` to the documented home `eval/net_analysis.zig` and delete the local copy. Decide whether `bom_html.zig:637`'s extra `/`-strip is intentional; if so rename it `baseNetNameStripScope`.
- [ ] **`containsCI` ×3 → one** (natural home `render_block_types.zig:120`); `draw.zig:388` and `traceability.zig:273` import it. **Keep** traceability's explicit empty-needle guard or its edge behavior changes.
- [ ] **`Evaluator.warnFmt(self, comptime fmt, args)`** — fold the allocPrint-catch-append boilerplate at `validate.zig:85,128,148,184,210` + `builders.zig:676` into one method. Also unifies the inconsistent `catch continue` vs `catch ""` failure handling.
- [ ] **`writeViolationJson(w, v)`** — extract and call from both ERC-emit loops (`mcp_tools.zig:1318` and `1790`) so `run_checks` and `build` tool outputs can't silently diverge.
- [ ] **`notes.writeNoteJson`** — make `pub` (notes.zig:237) and delete `mcp_tools.writeNoteJsonMcp` (442); call the original from `mcp_tools.zig:390,413`.
- [ ] **`sync.zig` micro-dups** — merge `bareNetName` (205) and `shortRefLocal` (2173) into one `afterLastSlash`; extract `joinPadNetSig(arena, pairs)` for the byte-identical sort+join tail of `designInstanceNetSig` (1769) and `boardFpNetSig` (1797).
- [ ] **`render_html.zig`** — extract `instanceIsHub(inst)` to replace 6 copy-pasted `FlatInst` hub projections (602, 1226, 1545, 1565, 1815, 1844), and `populateSectionMap(ctx, block)` for the duplicated walk at `render_html.zig:469-491` / `render_json.zig:492-525`.
- [ ] **`mcp_tools.zig:589`** — delete the single-use `Ctx` struct in `dispatchVfs`; pass four bare params like every sibling dispatcher.
- [ ] **`readFileOrExit` CLI helper.** The read-file→`catch |err|` print→`exit(1)` block recurs across the `cmd*` helpers in `main.zig` (101 `readFileAlloc` sites / 67 `process.exit(1)` tree-wide; the CLI cluster is the clearest target).

---

## Larger refactors (do deliberately, owner in the loop)

### 1. Unify the SVG and JSON scene-graph emitters — highest structural payoff
`render_json.zig` is a structural clone of the `render_svg/*` pipeline: `collectGroupConnections↔renderGroupedConnections`, `collectConnBody↔renderConnBody`, `collectPassiveChainLeft/Right↔drawPassiveChainLeft/Right`, `collectBranchTreeLeft/Right↔drawBranchTreeLeft/Right`, `collectTerminals↔renderTerminalGroups`. The net-classification/should-show loop at `render_json.zig:1014-1056` is **line-for-line identical** to `connection.zig:58-100`. Every layout change must be made twice.

**Approach:** the full fix is a shared traversal over a sink interface (SVG = streaming writes; JSON = builds a `SceneGraph`). The leaf emit calls differ structurally, so don't try to share the leaf layer in one go. **Start with the low-risk slice:** extract the identical net-classification/should-show block into one shared helper both call — that kills the most-edited duplicated region by itself. ⚠️ Preserve one known divergence: SVG's `renderGroupedConnections` draws an NC symbol on empty `group.conns` (`connection.zig:38-45`) where JSON just returns.

### 2. Share the group-balancer and Left/Right mirror logic in the render layer
(a) `splitGroupsByMergeAwareHeight` (`render_json.zig:394`) is the same greedy balancer as `hub.splitGroupsByHeight` (`hub.zig:292`), differing only in allocator threading + which heights fn it calls — parameterize `splitGroupsByHeight` to take a heights function (share **only** the splitter; the merge-aware height pass is legitimately distinct). (b) `branch.zig`'s `drawBranchTreeLeft/Right`, `renderBranchTerminalsLeft/Right`, `drawPassiveChainLeft/Right`, `drawPassiveLeft/Right` are pairwise mirrors. **Start with `drawPassiveLeft/Right` (`branch.zig:227` vs `257`)** — they differ by exactly one line. Merge `renderBranchTerminalsLeft/Right` last (it flips six coupled values).

### 3. Reconcile the special-form arity schema with reality (and generated docs)
`checkArity` (`special_forms.zig:20`, file-private) is called by only 5 of the handlers; cond/import/defmodule/design_block hand-roll their own checks. The schema is also **wrong**: `forms.zig:187` declares import `{min_args=1, max_args=1}` but `evalImport` (`modules.zig:55`) loops over all args — and that wrong row is rendered into `docs/language-forms.md:21`. `forms.zig:188` says defmodule `min_args=3` but `evalDefmodule` enforces ≥2. **Fix** `forms.zig:187`→`max_args=null`, `188`→`min_args=2` (corrects the generated doc), then pick one mechanism: expose `checkArity` so the hand-rolled handlers use it, or drop those rows and document that they self-validate. The registry-sync test (`forms.zig:635`) is the guardrail.

### 4. Remove the dead `(function …)` form (needs owner sign-off)
`ScopeForm.function` (`forms.zig:118`) → `parseFunction` (`design_block.zig:1393`) populates `block.functions`, which **no renderer or server reads** — only the write, struct decl (`env.zig:1075`), parser, and one unit test reference it. Its doc row even names the removed "Function view" / "Signal Chain view" (per project history, those tabs were deleted). Confirm intent, then remove the whole path together (form + docs row + parse arm + `parseFunction` + `FunctionGroup` + `functions` field + test) and regenerate `docs/language-forms.md`.

### 5. (Optional) Extract the `evalFile→design_block` preamble in `mcp_tools`
The `designSourcePath → Evaluator.init → evalFile catch{ERR_BUILD_FAILED} → switch{.design_block / else ERR_NOT_DESIGN}` preamble recurs at 6 sites (`mcp_tools.zig:334,1233,1352,1476,1531,1635`). ⚠️ Return the block **plus the live `Evaluator`** (the evaluator owns the block's backing memory; a naive `!*const DesignBlock` returner would deinit and dangle). **Scope to `mcp_tools` only** — the `sync.zig` sites use a different error contract.

---

## By subsystem

- **`src/sexpr/` (tokenizer, parser, printer)** — clean. One real coupling: the mil/mm unit is detected in the tokenizer (`tokenizer.zig:173-197`), discarded, then re-derived by the parser re-scanning source bytes (`parser.zig:51-61`) — carry an `is_mil` flag on the Token to delete the re-scan (fully test-covered). Plus stale-comment nits (`tokenizer.zig:187` "convert to mm", `printer.zig:34` "no nested lists" contradicted by its own test).
- **`src/eval/`** — solid. Highest-value cleanup is the `warnFmt` boilerplate; then the arity schema (#3) and dead `(function …)` form (#4). `loadComponent` (`modules.zig:122-239`) is under cap but its inline requirement sub-walk reads as its own `parseRequirement`.
- **`src/render_svg/` + `render_json.zig` + `render_html.zig`** — the maintainability hotspot: refactors #1 and #2, plus the bulk of the dead code. Treat new render features as a prompt to start collapsing the parallel emitters rather than adding a third copy.
- **`src/serve/` (auth)** — `auth.zig`/`oauth_store.zig`/`users.zig`/`passwords.zig`/`plugin_tokens.zig` share the store pattern (quick-wins above). No correctness issues.
- **`src/serve/` (sync, mcp_tools, mcp, edit, notes)** — good, repeated boilerplate only. Naming nits: `dispatchReview`→`dispatchHistory` (it only does `restore_version`); extend `dispatchInfo`'s doc to list its 3 omitted tools.
- **`src/serve/` (component_info, design_doc, upload)** — the four shared helpers above; otherwise fine.
- **`src/placement/`** — the `aux_pads` residue is the one finding (quick-wins). The optimizer is large but its size is inherent to the solver; not flagged.
- **`src/review*` + emitters** — **healthy.** `review.zig` computes one `ReviewDoc`; `review_html`/`review_json`/`review_md` are format-specific serializers of it. Same-named `write*` functions across them are different renderings, not duplication — leave them.
- **KiCad export (`export_kicad*`, `emit.zig`, `kicad_pcb/`)** — `export_kicad_netlist.zig` works from re-parsed source (`extractPadNames`, `collectInstances/Nets/NetTies`) while `emit.zig` flattens the evaluated `DesignBlock` — different layers, justified separation. Low-priority: worth a deeper look someday for shared net-traversal, but not an obvious win.

---

## What was investigated and found NOT worth changing
- **Test-aggregator gap** — refuted. 30 files have `test` blocks outside `main.zig`'s explicit `test {}` list, but all are transitively `@import`-reachable, so their tests run. No action needed.
- **Review/KiCad emitter "redundancy"** — refuted (shared model already).
- **`emit.writeString` vs `json_writer.writeString`** — correctly distinct (S-expr no-escape vs JSON escape).
- **TODO/commented-code debt** — negligible (7 legit TODOs, ~10 comment-lines).

---

_Method note: 4 subsystems (sexpr, eval-forms, render-svg/html, serve-sync-mcp) were audited by independent reviewer agents with adversarial verification (35 confirmed findings, 1 refuted); the remaining subsystems and all cross-cutting duplication/dead-code claims were verified inline via whole-tree grep + an import-graph closure computation. Every "dead"/"duplicate" claim above was confirmed against actual reference counts._
