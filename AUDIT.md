# netlisp / co-circuit — Full Codebase Audit

_Generated 2026-07-01. Scope: the entire `netlisp` Zig codebase (~100 kLOC across 156 files under `src/`), plus build/docs/project hygiene. Read-only static audit — no code was changed, no builds run, no board files touched._

**Method.** The tree was partitioned into 11 subsystems and each audited by a dedicated agent that read the source directly and reported concrete, `file:line`-anchored findings ranked by severity. Agents were steered to weight the failure modes that matter per area: security/XSS/path-traversal for the internet-facing serve layers, data-integrity for the KiCad board writer + sync, DEFLATE/PNG correctness for the hand-rolled rasterizer, false-positive/negative logic for ERC, and hot-path cost for the placement optimizer. Findings below are the agents' raw output; this header adds cross-cutting synthesis and a fix-first ordering.

## Verdict

The codebase is **fundamentally well-built** — arena discipline is real, the DSL dispatch tables are genuinely drift-proof, the OAuth store hashes secrets, the KiCad *board-write* happy path is defensive (placement guard → atomic rename → rotated backup), and the hand-rolled DEFLATE/PNG encoder audits clean against RFC 1951/2083. The problems are not architectural rot; they cluster into a few **repeating patterns**, and the highest-severity ones are concentrated in the **internet-facing HTTP surface**, which has outgrown its "local dev tool" security model.

**148 findings: 3 Critical · 31 High · 55 Medium · 59 Low.**

The three Criticals plus the High-severity auth/XSS findings mean the public server (`co-circuit.eugenepentland.dev`) should be treated as **currently exploitable by any authenticated user, and — via one header — by an unauthenticated remote attacker.** Everything else can be scheduled; these should not.

---

## Fix-first ordering

### P0 — Critical (remote compromise; fix before anything else)

| # | Issue | Location | Detail §  |
|---|-------|----------|-----------|
| C1 | **`Host: localhost` header = full unauthenticated admin.** "Am I local?" is decided from the client-controlled `Host` header while the server binds `0.0.0.0`; the middleware short-circuits *all* auth and promotes to admin. One header → VFS write/delete, every MCP mutation, user/invite management. | `serve/auth.zig:581-593,723-725`; `serve.zig:322` | 8 |
| C2 | **Arbitrary file write → RCE via `X-Filename` header.** The zip/model upload path templates the unsanitized header into `/tmp/eda-upload-{s}` and writes the request body; `../../../` escapes `/tmp`. Service runs as a systemd `--user` unit → write `~/.ssh/authorized_keys`. | `serve/upload.zig:92,259`; `serve/library.zig:332` | 10 |
| C3 | **Session-token theft via `/api/module-source?src=auth/sessions.json`.** The "copy source" reader blocks only `..`/leading-`/` and serves any project-relative file; `sessions.json` holds raw live tokens → any `reader` impersonates admin. | `serve/modules.zig:93,105,138` | 10 |

### P1 — High, security (authenticated-user escalation / stored & reflected XSS)

| # | Issue | Location | § |
|---|-------|----------|---|
| S1 | **No per-route role enforcement.** The writer/admin gate exists *only* on the MCP `tools/call` path; every HTTP `/api/edit-*`, notes, sync, library-delete, restore, and upload route accepts any valid session including `reader`. (This is what turns C2/C3 and the XSS bugs into "any account can.") | `serve/mcp.zig:120` vs `edit.zig`/`api.zig`/`notes.zig`/`upload*.zig` (no `getRole`) | 8, 10 |
| S2 | **MCP WebSocket escalates any bearer token to admin** — `upgrade()` never derives email from the token, and empty email defaults to `.admin`. | `serve/mcp.zig:308-311,324-329` | 8 |
| S3 | **Entire SVG emit path writes net names / ref-des / values / pin labels into markup unescaped** — XSS reachable via `import-kicad` net names, uploaded symbols, MCP `write_file`. | `render_svg/{draw,branch,section_inset,connection}.zig` | 5 |
| S4 | **`</script>` breakout in the `<script>const PCB=…</script>` blob & editor `window.SCENE`** — `writeJsonStr` is a JSON escaper, not a `<script>`-context escaper; a saved-layout/net/ref name containing `</script>` → stored XSS. | `serve/pcb_layout_page.zig:3828`; `serve/editor_page.zig:131` | 9 |
| S5 | **Stored XSS in the schematic BOM card** — component/value/MPN/manufacturer/datasheet-href rendered with raw `{s}`; MPN/manufacturer are attacker-writable via `editMpnApi`. | `serve/bom_html.zig:207-249` | 10 |
| S6 | **Reflected XSS + arbitrary `.sexp`/model read in the 3D viewer** — `:footprint` param embedded raw in HTML and interpolated into read paths without `isSafeLibName`. | `serve/library_3d.zig:89,95,167,57` | 10 |
| S7 | **`render_html` title + `data-ref`, and scene-graph JSON `name`, unescaped** — RCDATA/attribute/JSON breakout right next to correctly-escaped siblings. | `render_html.zig:89,664,707`; `render_json.zig:1631` | 5 |

### P2 — High, correctness / crash-safety / data-integrity

| # | Issue | Location | § |
|---|-------|----------|---|
| K1 | **Unchecked `@intFromFloat` on design/layout numbers = UB in the shipping ReleaseSmall build.** A NaN/huge value from a `.sexp` or a corrupt `layouts.json` becomes memory-unsafe UB, not a clean error. Same class in the rasterizer, ERC power-budget, `%`/`e96` builtins, and `pushToServer`'s `term.Exited`. | `eval/design_block.zig:523`, `eval/builders.zig:248,518`, `eval/ids.zig:662`, `raster.zig:101-242`, `erc.zig:1988`, `eval/builtins.zig:52,128`, `commands.zig:505` | 1,2,5,6,11 |
| K2 | **No recursion / import-cycle bounds anywhere in the front-end** — deeply nested input stack-overflows the server; `(defmodule m () (m))` or circular imports crash it. Server-reachable via MCP/`/api/push`/upload. | `sexpr/parser.zig:99-111`; `eval/modules.zig:91-135,430-502` | 1 |
| K3 | **`printFloat` collapses any `|v| < 5e-7` to `"0.0"`** (a `100n` literal loses its value) — and that same printer rewrites real `.kicad_pcb` board files in place; the round-trip test's 0.0001 tolerance masks it. | `sexpr/printer.zig:74-87`; `kicad_pcb/writer.zig:73,126` | 1 |
| K4 | **`buildNets` net-tie merge is non-transitive** — chained ties resurrect merged-away nets (splitting one declared rail into two), and a self-tie `(net "X" "X")` is a use-after-free that deletes the net. Silent wrong connectivity. | `eval/design_block.zig:1074-1116` | 2 |
| K5 | **Bare-token `(bus …)` omits `.is_auto`** — its function-name tie can hard-merge two user-declared nets across a series element (the exact jumper the auto-tie guard exists to prevent). | `eval/builders.zig:441-445` | 2 |
| K6 | **Use-after-scope: bare-integer pad numbers return a dangling stack slice** in the footprint converter → garbage pad names in generated library footprints → broken pad↔net mapping. | `convert/footprint.zig:85-91` | 7 |
| K7 | **Channel-fold "isomorphism" can't distinguish two internal nets with the same digit-template** — a genuinely rewired channel folds and is silently replaced with the exemplar's wiring. | `import_fold.zig:386` | 7 |
| K8 | **`netlisp check` exits 0 regardless of ERC errors; `netlisp build` never runs ERC** — directly contradicting CLAUDE.md's "fails the build" claims. CI/agents gating on exit codes pass broken designs. | `commands.zig:93-147,156-307` | 11 |
| K9 | **Half the ERC rules never recurse into sub-blocks** (dup-refdes, missing value/footprint, pin-functions, pin-multi-net, voltage-domain; power-pins/ports one level deep) — module internals silently pass checks the top level would fail. | `erc.zig:601,632,800,836,1747,2036,2178` | 6 |

### P3 — High, subsystem-local (dead code, perf, resolution bugs)

| # | Issue | Location | § |
|---|-------|----------|---|
| P3a | **Router's `isGroundName` never got the numbered-ground fix the optimizer got** — `GND1`/`PGND_2` maze-routed as signal copper on split-ground boards. | `router.zig:1215` vs `optimizer.zig:7350` | 3 |
| P3b | **`autofillOne` calls `std.math.clamp` with invertible bounds** — assert-panic in Debug, UB in ReleaseSmall, on real `(board …)` staging-band boards. | `optimizer.zig:1653-1661` | 3 |
| P3c | **Dead post-refactor features:** `emitBest` (live-regen animation) and `applySeriesRotations` (series-part rotation pinning) have no production callers, yet their support work runs every solve. | `optimizer.zig:305,6220` | 3 |
| P3d | **Hot-path cost:** `prepare` re-parses each footprint file per instance (runs per drag-score event), and the maze router's `blocked()` is O(nodes × pads) per leg. The two biggest wins in the placement engine. | `optimizer.zig:4550`; `router.zig:905-930` | 3 |
| P3e | **Layout-tab drag writeback emits display labels, but `(place …)` resolves by authoring key** — dragged sub-block/stub positions are silently lost on save. | `diagram/render.zig:644-650` vs `layout.zig:576-581` | 4 |
| P3f | **CLAUDE.md doc drift** — documents removed `(placement …)`/`(layout …)` forms and a nonexistent `/api/spec-save`, and denies MCP tools that exist. CLAUDE.md is the operative agent instruction file. | `CLAUDE.md:303-305,332,479,583,676` | 11 |

---

## Cross-cutting themes

These are the patterns behind the individual findings — fixing the pattern once is worth more than fixing each site.

1. **Output escaping is applied by convention, not by construction (7+ findings, incl. 4 of the P1 security items).** Correct escapers exist (`writeHtmlEscaped`, `json_writer.writeString`, `zt.writeEscaped`) and are used *almost* everywhere — but the whole `render_svg/*` path, three `render_html`/`render_json` sinks, the `review_json` power-tree, `review_md` hub blocks, the BOM card, the 3D viewer, and the `<script>`-context serializers each bypass them. **Recommendation:** make the sink types escape by construction (a writer wrapper that escapes on `print`), add a `<script>`-safe variant (`</`→`<\/`, U+2028/9), and treat any raw `{s}` of design-derived text as a lint. Untrusted text enters from `import-kicad` net names, uploads, and MCP `write_file` — this is not theoretical.

2. **`@intFromFloat` / `@intCast` on unvalidated numbers is UB in production (ReleaseSmall, safety-off) — ~8 sites across 5 subsystems.** Every place a design-file number, layout-sidecar pose, or arithmetic result is narrowed to an int without an `isFinite` + range guard is a latent memory-safety bug in the deployed binary. **Recommendation:** one shared `checkedInt(comptime T, f64) ?T` (reject NaN/inf, range-check, `warnFmt`) used at every narrowing site; audit `@intCast` similarly.

3. **The HTTP server still runs on a single-tenant "localhost is trusted" model while being internet-facing.** Auth proves *a* session exists but not its *role*; "local" is header-derived; the `dev@localhost` fallback is admin. **Recommendation:** derive "local" from the TCP peer address (or an explicit `--dev` flag), add a `requireWriter`/`requireAdmin` middleware keyed on the session/bearer role, and stop binding `0.0.0.0` if only the proxy should reach it.

4. **Duplicated heuristics that have already drifted (5+ sites).** `isGroundName` (optimizer vs router — *already* diverged, causing P3a), three cap-value parsers (`erc.capFarads` can't read `µ` → false-positive build failure; `module_policy`; `req_checks`), `isSupplyFn`/`VS`-prefix in three forms, `deriveChildId` vs `generateId`, `evalDecoupleForm`/`evalSectionDecouple`, `evalSection`/`evalSubSection` (drift already produced two real bugs). **Recommendation:** hoist canonical predicates into one module each (`net_names.zig`, one cap parser) and delete the copies.

5. **Non-atomic writes on state that matters.** `.layouts.json` (written on GET, no lock — corruption loses all saved/starred layouts *and* the KiCad-sync seed), the auth stores (`credentials.json` truncate-then-write → passkey lockout on a crash), `insertPendingIds` rewriting hand-authored `.sexp` non-atomically, and unsynchronized read-modify-write on design files across worker threads. The board writer already has the right idiom (`tmp → fsync → rename → backup`); several `oauth_store` helpers do too. **Recommendation:** route every state write through the existing atomic-write-with-backup helper, and serialize per-design/per-board mutations behind a lock.

6. **Dead / inert machinery left by the "placement collapse" and Go-agent-removal sweeps.** `emitBest`, `applySeriesRotations`, `seriesFor`, ~250 LOC of `CompactGrid` compaction, always-zero `priority` plumbing, `optimizeRotations` (unreachable), `computeGroupsLayout` (dead + type-confuses `Route.from_gid`), the proto-JSON footprint emitters (served only the retired Go agent), and stale docs (`kicad-sync-setup.md` documents a deleted `tools/kicad-sync-go`). Beyond bloat, the surviving mute/restore plumbing and gid-overloading are active hazards. **Recommendation:** delete deliberately (each is called out with its call-site analysis in the detail sections).

7. **Silent truncation via fixed stack buffers.** 64-slot pin buffers (`render_svg/context.zig` — drops spokes on big rails → wrong schematic), 256-slot layout buffers, 128-byte net-key buffers in `pcb_describe`/`render_pcb_png`, `log.warn`'s 4 KiB cap. Each fails silently (dropped connection / unmatched focus / lost diagnostic) rather than erroring. **Recommendation:** arena-allocate to input size, or at minimum `log.warn` on overflow.

8. **Doc drift is broad and, because CLAUDE.md drives agents, materially harmful.** Removed forms still documented as live, a hard-gate claim (`netlisp check`) that the CLI doesn't honor, MCP tools both over- and under-documented, backups relocated, README quick-start broken (guardian is an unpinned sibling-path dep; `projects/` is gitignored). **Recommendation:** a single doc-sync pass against the dispatch tables + route table + tool registry; consider generating the CLAUDE.md tool/endpoint inventories.

---

## Severity totals by subsystem

| §  | Subsystem | Crit | High | Med | Low |
|----|-----------|:----:|:----:|:---:|:---:|
| 1  | Language front-end & evaluator dispatch | 0 | 5 | 3 | 3 |
| 2  | Design semantics, IDs & power analysis | 0 | 3 | 6 | 6 |
| 3  | PCB placement optimizer, router & DRC | 0 | 6 | 6 | 4 |
| 4  | Schematic diagram / semantic-zoom layout | 0 | 2 | 5 | 7 |
| 5  | Rendering (HTML/SVG/JSON + PCB raster/PNG) | 0 | 3 | 4 | 7 |
| 6  | ERC, review & coverage | 0 | 1 | 7 | 8 |
| 7  | KiCad interop, BOM & emit | 0 | 2 | 7 | 5 |
| 8  | Serve: HTTP core, auth/OAuth, MCP & VFS | 1 | 2 | 5 | 4 |
| 9  | Serve: PCB layout page & KiCad sync | 0 | 1 | 6 | 6 |
| 10 | Serve: library, components, editing & uploads | 2 | 3 | 3 | 2 |
| 11 | Build, CLI, infra, docs & project hygiene | 0 | 3 | 3 | 7 |
| | **Total** | **3** | **31** | **55** | **59** |

The detailed, `file:line`-anchored findings for each subsystem follow. Each section leads with a one-paragraph health assessment (including what audited *clean* — worth reading, since several subsystems are in good shape and the "not findings" notes save re-investigation).


---

# Audit: Language front-end + evaluator dispatch

## Language front-end & evaluator dispatch
_Audited the tokenizer→parser→AST→printer pipeline (`src/sexpr/`) and the evaluator core (`src/eval/`: evaluator, forms, special_forms, builtins, fmt, modules, validate, suggest), ~4.5 kLOC. Overall health is good: the dispatch-table architecture (SpecialForm/Builtin/ScopeForm enums + docgen sync tests) is genuinely drift-proof, SI-literal tokenization is careful and well-tested, and diagnostics are unusually strong for a hand-rolled Lisp. The real problems cluster in three places: (1) the printer's fixed-precision float formatting is lossy and its round-trip test tolerance is too coarse to notice — dangerous because the same printer rewrites `.kicad_pcb` board files in place; (2) nothing in the front-end bounds recursion, so nested input, circular imports, or a self-recursive module crashes the server process; (3) two builtins (`%`, `e96`) misbehave on legal-looking numeric edge cases (UB / infinite loop). `validate.zig`, `suggest.zig`, and `ast.zig` are clean._

### Findings

- **[HIGH] `printFloat` fixed `{d:.6}` precision silently destroys small values; the round-trip test's 0.0001 abs tolerance masks exactly this class** — `src/sexpr/printer.zig:74-87`
  - `printFloat` formats every float as `{d:.6}` (6 fixed decimals) then trims zeros. Any `|v| < 5e-7` collapses to `"0.0"`: a `100n` / `22p` SI literal parses to `.float 1e-7` (`src/sexpr/parser.zig:60-63`) and prints as `0.0` — the value is gone. Values needing >6 decimals are silently rounded. The "round-trip parse→print→parse" tests can't catch this because `expectNodesEqual` compares floats with `expectApproxEqAbs(…, NODE_EQ_FLOAT_TOLERANCE)` where the tolerance is **0.0001 absolute** (`printer.zig:10`, used at `printer.zig:218-225`) — 1e-7 vs 0.0 passes.
  - This printer is not test-only: `src/kicad_pcb/writer.zig:73` and `:126` return `printer.print(...)` as the **in-place rewrite of the user's real `.kicad_pcb` board file** (the file whose comment at `printer.zig:243-245` explicitly says a lossy round-trip "would silently corrupt the board"), and `src/serve/modules.zig:253` prints module parameter defaults on the home page — a `(rfbb 100n)` default renders as `0.0` today.
  - Fix: print floats with Zig's shortest-round-trip decimal (`{d}` with no precision) — it emits `0.0000001` for 1e-7 and round-trips exactly; keep the trailing-`.0` normalization for float/int distinction. Tighten the test comparison to exact-bits (or relative 1e-12) so future formatting regressions fail loudly.

- **[HIGH] `(% a b)` with a negative divisor violates `@mod`'s precondition — panic in safe builds, UB in the deployed ReleaseSmall binary** — `src/eval/builtins.zig:52-55`
  - The `.mod` arm only guards `b == ZERO_DIVISOR` before calling `@mod(a, b)`. Zig's `@mod` requires the caller to guarantee `denominator > 0`; a design containing `(% x -3)` is checked illegal behavior in Debug and **undefined behavior in the ReleaseSmall prod build** (prod deploys ReleaseSmall per repo convention). This is reachable from any `.sexp` a user pushes/builds.
  - Fix: guard `if (b <= ZERO_DIVISOR) return BuiltinError.DivisionByZero;` (or compute the Euclidean form `a - b * @floor(a / b)` if negative divisors should be legal, and document it in the `builtin_docs` row at `src/eval/forms.zig:326`).

- **[HIGH] `(e96 x)` infinite-loops on `x = +inf`, hanging the request thread** — `src/eval/builtins.zig:128-132`
  - `while (m >= 10.0) { m /= 10.0; … }` never terminates for `m = inf` (`inf/10 == inf`). Infinity is reachable without scientific notation: arithmetic overflow (`(* 1e12 (* 1e12 …))` nested ~26 deep) or dividing by a hand-written denormal (`0.000…001`). `x <= 0` at line 126 does not filter it. On the serve/MCP build path this pins a thread at 100% forever — a one-line DoS.
  - Fix: `if (!std.math.isFinite(x)) return .{ .number = x };` before the normalization loops (also cleanly handles NaN, which currently falls through to returning `decade * series[0]` — arguably wrong but at least terminating).

- **[HIGH] No recursion depth limit anywhere in the front-end: deeply nested input stack-overflows the server process** — `src/sexpr/parser.zig:99-111`, `src/eval/evaluator.zig:343-346`
  - `parseList` → `parseNode` → `parseList` recurses once per nesting level with no depth counter; `evalNode` → `evalForm` mirrors it at eval time. A file of ~100k `(` characters (a few hundred KB) overflows the 8 MB stack and **aborts the whole `netlisp serve` process**. This input is server-reachable: MCP `write_file` + `build`, `POST /api/push/:name`, library upload (`convert-footprint`/`upload-symbol` parse foreign files), and the editor's `/api/validate`.
  - Fix: thread a `depth: u32` through `parseNode`/`parseList` and return a new `ParseError.TooDeep` past a generous cap (e.g. 10_000). Bounding the parser bounds the evaluator for free, since eval recursion follows AST depth.

- **[HIGH] Module system has no cycle or depth guard: circular imports and self-recursive modules crash the server** — `src/eval/modules.zig:91-135` (resolveImport), `src/eval/modules.zig:430-502` (callModule)
  - Two related holes: (a) `resolveImport` has no "in progress" set — if `lib/modules/a.sexp` imports `b` and `b.sexp` imports `a`, each hop re-reads and re-evaluates the other file in a fresh env (`env.get(name)` at line 78 is per-env, so it never short-circuits the cycle) until stack overflow; (b) `callModule` has no recursion cap, so a user typo like `(defmodule m () (m))` — or two modules calling each other — recurses until the process dies. `module_stack` (`src/eval/evaluator.zig:181`) faithfully records the unbounded stack on the way down.
  - Both are plausible authoring accidents, not just adversarial input, and both take down the shared prod server.
  - Fix: keep a `StringHashMap(void)` of import-in-progress names in the Evaluator (insert at resolveImport entry, remove on exit; on re-entry return an `ImportError` diagnosing the cycle), and cap `module_stack.items.len` (e.g. 64) in `callModule` with a clear "module recursion too deep" diagnostic.

- **[MEDIUM] A syntax error inside a library file is misreported as "no lib/components/x.sexp"; a name-mismatched module file is silently skipped (and leaks an Env per search step)** — `src/eval/modules.zig:99`, `src/eval/modules.zig:122-131`, `src/eval/modules.zig:62-66`
  - `parser_mod.parse(...) catch return EvalError.ImportError` (line 99) discards the parse error **without setting `last_error`**, so `evalImport`'s fallback (lines 63-65) reports `cannot import 'x' — no lib/components/x.sexp or lib/modules/x.sexp` even though the file exists and is merely malformed — actively misleading for the exact user who most needs the diagnostic. Separately, if `lib/modules/foo.sexp` defines `(defmodule bar …)` (name ≠ filename), `mod_env.get(name)` fails at line 128 and the loop just continues to the next prefix/root — same misleading "not found" at the end, plus one heap-created, never-destroyed `Env` (line 123) per failed iteration.
  - Fix: on parse failure, `setErrorFmt` with the file path (the parser can't give line/col today, but naming the file + "syntax error" is already a big step); on module-name mismatch, emit a dedicated diagnostic ("`foo.sexp` defines '<actual>' not 'foo'") instead of falling through.

- **[MEDIUM] The arity-schema table isn't enforced for `import`/`defmodule`/`design-block` — they return bare `ArityError` without a diagnostic, so callers can render a stale `last_error`** — `src/eval/modules.zig:56`, `src/eval/modules.zig:324`, `src/eval/design_block.zig:64`; schema rows at `src/eval/forms.zig:196-199`
  - `checkArity` (the centralization described in its own doc comment, `src/eval/special_forms.zig:20-35`) is only called by let/if/fmt/assert/assert-range. `evalImport`, `evalDefmodule`, and `evalDesignBlock` hand-roll `if (args.len < N) return EvalError.ArityError;` with **no `setError`** — so `(import)` or `(defmodule x)` fails with whatever `last_error` happened to be set previously (or none), and the schema entries declared for them in `special_form_schema` are used only by docgen. Related: `checkArity`'s zero-arg fallback span is `ast.Span.zero` (`special_forms.zig:23`), pointing diagnostics at 1:1 of the file because the form-head span isn't passed in.
  - Fix: route the three handlers through `checkArity` (it already has their schemas), and pass the head node's span into `checkArity` for the empty-args case.

- **[MEDIUM] Module files are re-read, re-parsed, and re-evaluated once per importing environment; `loaded_files` is a recorder, never a cache** — `src/eval/modules.zig:75-135`
  - The early-outs at lines 77-78 are `component_cache` (evaluator-wide, works) and `env.get(name)` (per-env — misses every time a *different* module file or design imports the same module). Every miss re-runs `readFileAlloc` (line 97), `parse` (line 99), and full `evalNodes` on the module file (line 126), plus heap-allocates another `Env` (line 123). `loaded_files` (lines 106-110) is checked only to avoid duplicate *keys* — the freshly parsed nodes are used regardless, and each repeat load allocates a new never-freed `file_content` buffer, so memory grows with import-site count, not file count, within one evaluator.
  - For a design with many sub-blocks sharing modules this is O(import-sites × file-size) per build on the request path.
  - Fix: add a `module_cache: StringHashMapUnmanaged(BlockDef)` on the Evaluator mirroring `component_cache` (a module file's BlockDef is caller-independent — its `imports` env is its own file scope), or at minimum serve parsed nodes out of `loaded_files` before re-reading disk.

- **[LOW] Named-argument detection can capture a legitimate positional expression** — `src/eval/modules.zig:382-390`
  - `namedParamIndex` treats *any* 2-element list whose head atom matches a declared param as a named arg. A module with a param named `cap` (plausible: "which cap family to use") called as `(m (cap "100nF"))` silently binds `cap = "100nF"` instead of evaluating the canonical component-family call `(cap "100nF")`. The doc comment only covers the head-doesn't-match case; the head-collides case is a silent semantic change.
  - Fix: when the head matches a param name *and* also resolves as a callable/component in scope, emit a `warnFmt` ambiguity lint (the machinery exists), or require named args to use a sigil-free but unambiguous form going forward.

- **[LOW] String escape sequences are tokenized but never decoded — the backslash is part of the runtime value** — `src/sexpr/tokenizer.zig:160-165`
  - `readString` skips over `\x` pairs but returns the raw source slice, so `"a\"b"` evaluates to the 4-byte string `a\"b`. Every consumer (fmt `~S`, net names, notes, HTML rendering, `==` string equality) sees the backslash. The printer deliberately depends on this for round-trip fidelity (`src/sexpr/printer.zig:53-64`), so this is a coherent-but-surprising design point rather than an inconsistency — but it means there is *no way* to put a literal `"` (or anything via `\n`) into a string value.
  - Fix (if desired): decode escapes into an allocated buffer at parse time and re-escape in the printer; otherwise document in `docs/language-forms.md` that strings are verbatim with no escape processing beyond the quote.

- **[LOW] Doc drift: CLAUDE.md contradicts the dispatch tables on two retired forms** — `CLAUDE.md:107`, `CLAUDE.md:479`, `src/eval/forms.zig:180`
  - `CLAUDE.md:107` lists `cond` among `special_forms.zig`'s forms — `cond` was removed in the dead-form sweep and is not in `SpecialForm` (`src/eval/forms.zig:8-46`). `CLAUDE.md:479` states "**`(layout …)` is the legacy alias** — both parse", but the alias was retired: only `diagram-layout` maps to `ScopeForm.layout` (`src/eval/forms.zig:166`) and the test at `src/eval/forms.zig:561-566` asserts `fromAtom("layout") == null`, so a `(layout …)` form in a design is now a silent unknown-form lint, not a working alias. The comment at `src/eval/forms.zig:180` also still cites `cond` as an unbounded-arity example.
  - Fix: correct the two CLAUDE.md lines and the stale comment (the generated `docs/language-forms.md` is already correct — this drift lives only in the prose docs).

### Clean files
- `src/sexpr/ast.zig` — no significant issues; small, correct helpers.
- `src/eval/validate.zig` — no significant issues; hash-map churn is arena-allocated per request-path conventions.
- `src/eval/suggest.zig` — no significant issues; the iterator-buffer dupe at `suggest.zig:101-109` correctly handles the dangling-stem hazard, `editDistance` bounds are enforced by both callers, and the scans are error-path-only as documented.


---

# Design semantics, IDs & power analysis

## Design semantics, IDs & power analysis
_Overall health: good. The layer is well-tested (spec-tagged tests cover the id derivation, decouple shorthand, and rails/sequencing paths), the Option-4 hierarchical-id design is sound (`deriveChildId(subblock_uuid, origin_key)` inputs are genuinely renumber-proof), and the ref-des assignment pipeline has deliberate determinism guards (`stableRefAssignOrder`, prescan). The real weaknesses cluster in three places: `buildNets`'s net-tie merge is a naive sequential pairwise merge (not a union-find) with order-dependent wrong results; several `@intFromFloat` sites trust design-file numbers and are UB in the ReleaseSmall production build; and the two big files (design_block.zig 2314 lines, builders.zig 1354) contain duplicated section/decouple/bus parsers that have already drifted apart behaviorally — two of the concrete bugs below are exactly that drift._

### Findings

- **[High] `buildNets` net-tie merge is non-transitive; chained ties resurrect merged-away nets, and a self-tie is a use-after-free that deletes the net** — `src/eval/design_block.zig:1074-1116`
  - Ties are applied sequentially as `merge remove(nt.b) into keep(nt.a)` with no canonical-root resolution. Chain `(net "A" "B")` then `(net "B" "C")`: the first tie merges B into A and removes B; the second tie's `getOrPut(keep="B")` (line 1091) **re-creates an empty net "B"** and moves C's pins into it — the design ends with two disjoint nets `A` (A+B pins) and `B` (C pins) where the author declared one. The reverse order `(net "A" "B")`, `(net "C" "B")` also mis-merges (remove=B already gone → C's pins never join A). Additionally, a self-tie `(net "X" "X")` (a one-character typo) makes `src_pins` a by-value copy of the same list that `gop.value_ptr.append` reallocates mid-iteration (lines 1090-1097) — an iteration over a freed buffer — and then `net_map.remove(remove)` at line 1098 deletes the net entirely. Finally, the both-sides-empty skip at line 1078 also skips the `REMOVE.x → KEEP.x` bypass-stub rename (lines 1101-1115), so a rail whose pads are all on per-pin stubs loses the canonical-prefix rename the `missing_decoupling` aggregation depends on.
  - Wrong net membership is the worst class of bug in a netlist tool: it silently changes board connectivity (KiCad export splits a rail) with zero diagnostics.
  - Fix: resolve both tie endpoints through a union-find root map (the exact structure `rails.zig:178-197` already uses) before merging; guard `keep == remove`; perform the `.x` rename against the canonical root even when the trunk holds no direct pins. The per-tie full-map prefix scan (lines 1103-1108) becomes one pass at the end, also fixing the O(ties × nets) scan.

- **[High] Unchecked `@intFromFloat` on design-file numbers — UB/crash in the production (ReleaseSmall, safety-off) server** — `src/eval/design_block.zig:523`, `src/eval/builders.zig:248-249`, `src/eval/builders.zig:518`, `src/eval/ids.zig:662`
  - `numberAsUsize` (design_block.zig:520-524) rejects `f < 0` but not NaN (NaN `< 0` is false) or values above `maxInt(usize)`; `parseBusPortHeader` (builders.zig:248-249) casts unvalidated start/end into `i64`; `emitDecoupleItems` (builders.zig:518) casts COUNT into `u32` — `(decouple "VDD" (comp) -1 per-pin U1 7)` is a direct trap; `pinId` (ids.zig:662-663) casts any numeric pin token into `i64`, so `(pin 1e30 "X")` is UB. All are reachable from a `.sexp` file the HTTP server evaluates on every push/page load; ReleaseSmall disables safety checks, so these are true undefined behavior in prod, not clean panics. Relatedly, `(bus-net "X" 0 100000000 "sub")` passes all checks and allocates 100M ties — an OOM DoS with no range bound.
  - A malformed or hostile design file must produce a diagnostic, never take down `netlisp serve`.
  - Fix: one shared `checkedInt(comptime T, f64) ?T` helper (reject NaN/inf, range-check, warn via `warnFmt`), plus a sanity cap (e.g. 4096) on bus-net/bus-port expansion counts.

- **[High] Flat bus-token path emits a user-grade net tie — missing `.is_auto = true` — that can hard-merge two user-declared nets** — `src/eval/builders.zig:441-445` (vs. the correct `builders.zig:421-425`)
  - `processPinForm`'s `(bus …)` handler has two near-identical branches: grouped pin lists append the function-name tie with `.is_auto = true` (line 424); the bare-token branch appends `.{ .a = bus_net, .b = func_name }` with no flag (line 444), and `Evaluator.NetTie.is_auto` defaults to `false` (`src/eval/evaluator.zig:210`). Non-auto ties bypass the both-sides-populated guard at `design_block.zig:1086`, so a bare bus token whose pad has a pinout function name matching another populated net jumpers the two nets — exactly the "SDOA damping resistor" failure mode the guard's comment documents.
  - Silent netlist merge across a series element; the two branches drifted because ~30 lines are duplicated.
  - Fix: add `.is_auto = true` at builders.zig:444 and fold the two branches into one helper so they cannot drift again.

- **[Medium] Power budget undercounts input draw for dual-output regulators** — `src/eval/power_budget.zig:230-231, 269-299`
  - The back-computation's convergence state `sb_contrib` is keyed by `sb.name` alone, but the loop iterates every efficiency-declared **out_port** of the sub-block. For a dual-output module (e.g. a PMIC with two `(efficiency …)` outputs), output B's delta is computed against output A's contribution (`prev = sb_contrib.get(sb.name)` at line 269) and its upsert replaces it — the input rail ends up charged only for the last-visited output instead of the sum. The consumer group key (line 278) collides the same way.
  - The whole point of Step 3b is that upstream rails see cumulative regulator draw; a dual-output module silently under-reports, defeating the `over`/`tight` verdicts.
  - Fix: key `sb_contrib` (and the consumer group key) on `(sb.name, out_port.name)`.

- **[Medium] `(decouple … per-pin REF PIN…)` silently splits the net when the host pin isn't (yet) declared on it** — `src/eval/builders.zig:640-648`
  - After emitting caps onto the split net `NET.REF.PIN`, the loop reassigns the first matching `(ref, pin, net)` entry in `all_pin_nets` — and does nothing when no entry matches (pins declared *after* the decouple form, a typo'd pin, or a pad/function-name resolution mismatch). The caps then live on a stub net that contains no IC pad; the trunk keeps the pad. The flattened netlist/KiCad export has the cap electrically disconnected from the pin it "serves". The `auto` marker errors loudly on zero matches (`expandPinsOf`, builders.zig:682-685); the explicit list does not.
  - Silent connectivity split, ordering-dependent, in the most-used decoupling path.
  - Fix: warn (or error, matching `auto`) when the reassignment loop finds no `(ref_str, target_pin, net_name)` entry.

- **[Medium] Pin-function enrichment only descends one sub-block level, contradicting its own doc** — `src/eval/pin_enrichment.zig:43-46, 55-57` (doc at 24-25)
  - `enrichPinFunctions` runs `enrichNets` for `block` and `block.sub_blocks` but never recurses into `sb.block.sub_blocks`; `collectRefToSymbol` has the same one-level walk. The header comment promises "(and nested sub-blocks)". Designs with module-in-module nesting (e.g. the adcarray/power chains) leave nested pins' `asserted_fns` empty.
  - Single-alt pins inside nested modules draw spurious `pin_function_required` ERC findings and lose function annotations in renders/export.
  - Fix: make both walks recursive (the `ref_to_symbol` map is already global-ref-keyed since enrichment runs post-renumber).

- **[Medium] `evalSubSection` drift: nested-section instances get no auto pin-function aliases, and the `(group "label")` sibling in nested `(pins …)` is silently dropped** — `src/eval/design_block.zig:976-984, 985-1001` (vs. `770-774` and `860-868`)
  - The top-level section instance handler calls `appendAutoAliases` (line 774); the nested-section copy (lines 976-984) does not — so a nested instance whose pin net differs from its pinout function name emits no auto tie, and a net referenced elsewhere by function name won't merge (wrong net membership). The nested `(pins …)` handler also skips the sibling `(group "label")` parsing that `evalPinsForm` does (lines 862-868), and since `isKnownPinsChild` whitelists `group` (`builders.zig:456-458`) there isn't even a warning — the label just vanishes.
  - Same source form means different netlists depending on nesting depth; classic copy-drift between the ~100-line duplicated section walkers.
  - Fix: add the `appendAutoAliases` call and route nested pins through `evalPinsForm`; longer-term merge `evalSection`/`evalSubSection`.

- **[Medium] Doc drift: CLAUDE.md says `(layout …)` "is the legacy alias — both parse"; the alias was removed** — `CLAUDE.md:479` vs `src/eval/forms.zig:164-166, 560-564`
  - `ScopeForm.fromAtom("layout")` returns null (asserted by the forms.zig test "legacy aliases are retired"), so a design following CLAUDE.md's claim gets an `unknown sub-form (layout …)` warning and its diagram layout is silently dropped.
  - An agent (or human) trusting CLAUDE.md will author a form the evaluator discards.
  - Fix: update the CLAUDE.md paragraph (the project memory already flags "CLAUDE.md mixed placement prose" as a known TODO).

- **[Medium] `resolvePinName` silently picks an arbitrary pad when a function name maps to multiple pads** — `src/eval/instance.zig:565-575`
  - The reverse lookup iterates the `pad → function` hash map and returns the **first** value match in hash-iteration order. On parts where several pads share a function name (multi-pad VDD/GND on BGAs), `(pin VDD "3V3")`, `(decouples "U1" VCC)` (instance.zig:208-209), `(strap-ok VCC …)` and decouple pin lists (builders.zig:594) all bind one arbitrary pad with no diagnostic. It is also an O(pinout-size) scan per token.
  - An ambiguous binding should be an error the author sees, not a hash-order choice; the arbitrary pad feeds the placer's loop targets and ERC blessings.
  - Fix: build a reverse map once per pinout (also fixing the perf), store multi-pad functions as ambiguous, and warn when a multi-pad function name is used as a single-pin token.

- **[Low] Ref-des rename maps don't update `decouple_ic`, `Group.members`, or `Verification.ref_des`** — `src/eval/ids.zig:124-155, 187-231`
  - Both rename passes update nets/notes/sections only. A cap's `(decouples "stm32" 24)` targeting a labeled instance keeps the stale label after `stm32 → U1`; the renderer explicitly works around it by falling back to pad-only matching ("non-renumbered designs", `src/render_svg/context.zig:503-508`), and ERC only tests `decouple_pin`, so the impact is soft — but `(group …)` members and `(verifies (req "label" …))` targets written against labels break silently.
  - Sign-offs orphaning on rename is the exact failure the project memory warns about for `.checks.sexp`.
  - Fix: run `rename_map` over `decouple_ic`, group members, and ref-des-addressed verifications in both passes.

- **[Low] `deriveChildId` results are never registered in `design_ids` nor collision-checked** — `src/eval/ids.zig:419-432` (vs. `generateId` at 399-416)
  - Derived ids live in the same ~30-bit token space that `generateId` deduplicates against, but derived tokens are neither registered nor checked: two distinct `(parent, origin_key)` pairs can collide with each other or with a random source id. A collision silently gives two parts the same `uuidFromId` KiCad footprint identity.
  - Probability is small per design (~n²/2³¹) but the failure is invisible and permanent once synced to a board.
  - Fix: register derived ids via `registerId` and warn on a pre-existing hit (can't re-roll — derivation must stay deterministic — but the warning makes the 1-in-a-million case debuggable).

- **[Low] `power_budget.analyze` / `power_sequencing.analyze` return `list.items` instead of `toOwnedSlice`, contradicting their ownership doc** — `src/eval/power_budget.zig:347, 373`; `src/eval/power_sequencing.zig:138`
  - Doc comments say "the returned slice is owned by the caller's allocator", and the power_sequencing tests `alloc.free(rows)` — but `.items` is a sub-slice of a capacity-padded allocation, so a non-arena caller's `free` is size-mismatched and the slack is unfreeable. `rails.zig:145` does it correctly. Also `power_budget.resolveRailVoltage` allocates from `std.heap.page_allocator` directly (power_budget.zig:477) instead of the caller's allocator, punching through request arenas.
  - Works today only because callers happen to use arenas/page_allocator; the contract is a trap for the next caller.
  - Fix: `return out.toOwnedSlice(allocator)` at all three sites; use the passed allocator in `resolveRailVoltage`.

- **[Low] rails/power_budget duplicate four helpers, and ferrite union-find hard-codes pads "1"/"2"** — `src/eval/power_budget.zig:471-531` vs `src/eval/rails.zig:178-225`; pad assumption at `rails.zig:48-49`, `power_budget.zig:103-104`
  - `findRoot`, `unionNets`, `resolveRailVoltage`, `sectionVoltage` are copy-pasted between the two analyses (the header of `PowerRail` in env.zig even says rails.build exists so downstream analyses *stop* recomputing rail identity — power_budget still recomputes its own union-find rather than consuming `block.rails`). Both ferrite scans only recognize pins literally named "1"/"2", so a ferrite with letter pads or a 4-pad ferrite array silently fails to bridge, splitting the rail rollup.
  - Two hand-kept-in-sync copies of rail identity is exactly what the PowerRail refactor was meant to end; the pad assumption yields quietly wrong budgets on non-standard ferrites.
  - Fix: have power_budget consume `block.rails` (or at least share the helpers via net_analysis.zig); derive ferrite endpoints from its two nets regardless of pad names.

- **[Low] `evalDecoupleForm` and `evalSectionDecouple` are ~45-line near-verbatim duplicates** — `src/eval/design_block.zig:549-595` vs `889-929`
  - Identical logic (first-value check, sub-form detection, `emitDecoupleItems` fan-out) duplicated for top-level vs section scope; they already differ only in incidental text. This is the same duplication pattern that produced the `is_auto` and `appendAutoAliases` drifts above.
  - Fix: collapse to one function taking the item slice; pure deletion.

- **[Low] Explicit `(stub … (ref "U7"))` refs are not prescanned, so an earlier auto-mint can collide** — `src/eval/ids.zig:251-264` (prescan covers `instance`/`series`/`section` only) vs `src/eval/design_block.zig:186, 1339-1342`
  - Stub explicit refs register only when the stub form is reached during eval; a stub (or fanout/decouple child) auto-minted earlier in the body can take the same token, producing a duplicate ref-des that only ERC catches later.
  - Fix: teach `prescanRefDes` to read `(stub … (ref …))` (and `(fanout "REF" …)` if named forms are ever added).


---

# Audit: PCB placement optimizer, router & DRC

## PCB placement optimizer, router & DRC

_Overall health: good bones, post-refactor debris._ The math core is careful (fixed-pad surrogate keeps the objective continuous, loop inductance model is documented and tested, keepout boxes are hoisted out of the O(n²) repulsion loop, DP-simplified pad outlines gate on a slack radius). Determinism holds throughout: no RNG anywhere (seed angles are golden-ratio, tie-breaks are index/lexical), and hash maps are only ever used for keyed lookup, never iterated. The biggest problems are (a) the recent "placement collapse" sweep left several *documented* features silently dead or inert (series-rotation pinning, live-regen progress, the priority plumbing, ~250 LOC of orphaned spatial-hash compaction), (b) the router's ground-net predicate diverged from the optimizer's fixed one, and (c) two genuine hot-path costs: per-instance footprint file re-parsing in `prepare` (which runs per drag-score event) and the maze router's O(pads) obstacle scan per grid-node relaxation.

### Findings

- **[High] Router's `isGroundName` misses numbered grounds the optimizer recognises — split-ground boards route their ground nets as signal copper** — `src/placement/router.zig:1215-1221` vs `src/placement/optimizer.zig:7350-7371`
  - The optimizer's `isGroundName` was explicitly extended to accept numbered grounds (`GND1`, `GND2`, `AGND2`, `PGND_2`, `VSS1` — the comment at optimizer.zig:7352-7355 says the exact-match list "missed numbered grounds… corrupting loop detection"). The router kept the old exact-match list `{GND, GNDA, AGND, PGND, DGND, GNDD, VSS, VSSA}`.
  - On an isolated/split-ground board: placement treats `GND1` as a plane (excluded from springs/`wireScore`, decoupling returns assume a via drop), but `route()` pass 1 (router.zig:122) skips it, so pass 2 maze-routes the entire ground net as surface copper; `isGndVia` (router.zig:1181-1186) returns false for its vias, so `returnPathViolations` counts them as *unstitched signal vias* and the stitch pass tries to stitch them — wrong copper, wrong SI metric, and a placement/routing model mismatch on exactly the boards the optimizer fix targeted.
  - Fix: extract one shared ground predicate (the optimizer's numbered-suffix version) and use it in router.zig; the comment at router.zig:1213 already says "mirror optimizer.zig" — it no longer does.

- **[High] `autofillOne` fallback window: `std.math.clamp` with inverted bounds — UB in ReleaseSmall, panic in Debug** — `src/placement/optimizer.zig:1653-1661`
  - When a staged part sits > `RELOCATE_MAX_CELLS` (24 mm) from its anchors, the re-centre branch computes `clamp((minx+maxx)/2, minx - m + half_span, maxx + m - half_span)` with `half_span = 12.0`. Bounds are ordered only when `(maxx-minx) + 2m ≥ 24`; with a single anchor target (span 0) and a small part (`m = 6 + effHw + effHh ≈ 7.5`) the lower bound exceeds the upper. `std.math.clamp` asserts `lower <= upper` — a Debug/test panic, and *undefined behavior* in the shipping ReleaseSmall build (assert compiles to `unreachable`).
  - This branch exists precisely for the `(board …)` staging-band case (part staged 5 mm below a tall outline, anchor on a far connector pad), so it is reachable on real boards; a garbage window silently breaks auto-fill for that part.
  - Fix: when the span is smaller than the window, just centre on the targets: `if (lo > hi) cx0 = (minx+maxx)/2` (and same for y) instead of clamping into an inverted interval.

- **[High] Live-regen progress is dead: `emitBest` has zero call sites** — `src/placement/optimizer.zig:305-307` (sink installed at `src/serve/pcb_layout_page.zig:1083`)
  - The background-regen thread installs a `ProgressSink` via `setProgressSink`, and `SolveState` carefully mutes/restores it around nested solves (optimizer.zig:1797-1821, 2054) — but nothing in the solve pipeline ever calls `emitBest` anymore. The multi-start engine that streamed best-so-far frames was removed; the "board animates converging" feature now silently shows nothing until the final result.
  - Either re-emit frames from the surviving phases (`runRough` block arrangement, `packPadAnchored`, `routedPolish` sweeps) or delete the sink plumbing; keeping mute/restore machinery for a dead stream is pure hazard.

- **[High] Series-rotation pinning never runs: `applySeriesRotations` has no production caller, yet `SeriesPair`s are built every solve** — `src/placement/optimizer.zig:6220-6229` (built at 6133-6134, paired at 6145-6175, `seriesFor` at 6178 also dead)
  - `Part.rot_pin` (optimizer.zig:339-344) documents that series parts (buck inductor across LX1/LX2, feedback R) get a geometrically decided, pinned rotation because HPWL is blind to them. `pairSeriesLegs` runs in every `buildSprings`, but `applySeriesRotations` is called only from tests (7937, 7944) — so `rot_pin` is always `.none` in production, all four "pinned rotation — search position only" guards (1671, 4899, 5212, 5529) are inert, and a series inductor can ship at the HPWL-tied wrong rotation. The work to compute the pairs is also wasted every prepare.
  - Fix: call `applySeriesRotations(parts, built.series)` after seeding in `runPlacement`/`packPadAnchored` (per its own doc comment: "run after seeding, before the rotation-searching refinement passes"), or delete the whole SeriesPair path if the behavior is no longer wanted.

- **[High] `prepare` re-reads and re-parses the footprint file for every instance — no per-footprint cache, and `prepare` runs per drag-score event** — `src/placement/optimizer.zig:4550`, `src/placement/geometry.zig:59-109`
  - `geometry.load` does a file read + full s-expression parse per call. A board with 100 `cap-0402`s parses `lib/footprints/C_0402.sexp` 100 times per `prepare`. Pin roles got a cache (`roles_cache`, optimizer.zig:4544) but geometry did not.
  - `prepare` is not just per-solve: `scorePoses` (optimizer.zig:3849) is issued by the layout page "on every pointer move" (comment at 3861-3863), so a drag re-parses every footprint file continuously. On a 200+ part board that's hundreds of file opens + parses per pointer event — the single cheapest big win in the file.
  - Fix: a `StringHashMap([]const u8 → Geom)` keyed on footprint name inside `prepare` (mirroring `roles_cache`); geometry results are immutable and already arena-allocated. (A cross-request cache keyed on mtime would also fix the per-drag cost of the rest of `prepare`, but the intra-prepare cache alone removes the N× multiplier.)

- **[High] Maze router: `blocked()` scans every pad obstacle for every node relaxation — O(nodes × pads) per routed leg** — `src/placement/router.zig:905-930` (called from `relaxStep` 1063 and `relaxDiag` 1093)
  - On the top layer each Dijkstra relaxation loops over `ctx.obs` (every pad on the board) computing a distance per pad. A 400-pad board on a 50k-node grid visits ~50k nodes × 9 edges × 400 pads ≈ 180M distance tests *per pad-to-pad leg*, and `route()` runs a leg per pad per net. This multiplies into every consumer: `fullRouteCost`, `routedCount` (the veto inside `tightenPriorityLoops`/`autofillUnlisted`), `LoopRouter.legLen` per polish candidate, and the interactive `?route=1`.
  - The obstacle set is *static* across one `route()`/`LoopRouter` lifetime. Rasterize it once into a per-node grid (net id of the covering/nearby pad, `MULTI` sentinel when ≥2 nets are within reach, plus an "on own copper" grid), making `blocked()` O(1). Same for `viaClearsPads` inside `viaAllowed` (853-878). This is the dominant router cost and a pure hoist — results are identical.

- **[Medium] `polishCrossings` recomputes the whole crossing metric per candidate swap; `primEdges` is O(n³) and uncapped** — `src/placement/optimizer.zig:2925-2972` (metric 2874-2904, MST 2803-2830, gate 3191)
  - Runs on every rough solve for flat designs ≤80 parts (`packPadAnchored` is the default fallback engine). Each candidate swap rebuilds *every* net's MST plus all cap loops and then does O(segs²) crossing tests: parts² swaps × passes × segs² ≈ billions of orientation tests on an 80-part module. Two compounding issues: `primEdges` picks the next edge by scanning all in-tree × out-of-tree pairs (O(n³) total, unlike the O(n²) `rmstLen` at 6667); and `crossingMetric` only excludes *ground* — a 40-pin VDD rail's MST is rebuilt per swap and dominates segs².
  - Fix: cap net size like `MAX_WIRE_PTS` does (or skip nets with ≥`CLUSTER_MAX_RAIL_PADS` hub pads, matching the clustering rules); use the `best[]`-array Prim; and evaluate swaps incrementally (only segments touching the two swapped parts change).

- **[Medium] Objective evaluation hashes ref-des strings and linearly strcmp-scans pads per pin, per eval** — `src/placement/optimizer.zig:6638-6659` (`netWire`), 5920-5928 (`congestionPenalty`), lookup helpers 7293-7298
  - Every `wireScore`/`congestionPenalty` call does `idx_of.get(pr.ref_des)` (string hash) + `padLocal` (linear pad-number strcmp over up to 100+ pads for an MCU) for every pin of every net. These run per candidate in `routedPolishCost` (5178) and per drag-score in `breakdownWith`. The part index and footprint-local pad offset are invariant for a whole solve.
  - Fix: in `prepare`, resolve each net once into `[](part_idx, lx, ly)` and iterate that in `netWire`/`congestionPenalty`/`crossingMetric`. Removes all string work from the hot objective; results identical.

- **[Medium] Inert search phases still maintained: priority is always zero and `optimizeRotations` is unreachable** — `src/placement/optimizer.zig:4575-4578, 795, 4807-4840, 5079-5100, 5517-5543`
  - `prepare` memsets `priority` to 0 (comment: "`(placement-order …)` was removed"), so `tightenPriorityLoops` always no-ops at its `any` gate, `priorityWeight`/`PRIORITY_STEP`/`loopPriDesc` are dead, and the router's `netPriority` high bits never fire. `runStart` is only ever called with `rounds = 0` (795), so `optimizeRotations` — plus the multi-start `s`-decorrelation of `seedRing`/`seedAngle` — never executes in production. `surrogateObjective` (723) is test-only.
  - Risk beyond bloat: readers (and future tuning) reason about phases that don't run; the `routedPolish`/`tuckCap` rotation searches now carry the whole rotation burden with no `optimizeRotations` backstop. Delete or rewire deliberately.

- **[Medium] ~250 LOC of orphaned compaction machinery: `CompactGrid` spatial hash + dock helpers have no callers** — `src/placement/optimizer.zig:4949-5070, 7001-7140` (also `anyCourtOverlap` 4772, `courtyardTouchesAny` 5002)
  - `compactToContact` was removed in the sweep but its whole support cluster survives: `centralIndex`, `growSettled`, `bestDock`, `considerDock`, `Dock`, `COMPACT_MIN_OVERLAP`, `bucketCount`, `cellHash`, `CompactGrid` (99 lines). Ironically the one place that *could* use the spatial hash today — `autofillOne`'s coarse/fine window scan calling O(n) `overlapsAny` per candidate cell (1682, 1706) — doesn't.
  - Fix: delete the cluster, or repoint `autofillOne` at `CompactGrid.overlaps` (positions are static per candidate pass except the moved part, which is exactly the query it was built for).

- **[Medium] `routedPolish` rebuilds the router grid + obstacle list from scratch for every candidate cell** — `src/placement/optimizer.zig:5161-5237` (`routedSubsetWeighted` at 4713-4736 constructs a fresh `LoopRouter` per call; `router.zig:314-361`)
  - Per candidate (13×13 window × 4 rotations × caps × sweeps): `LoopRouter.init` re-runs `buildObstacles` (an `allocPrint`'d string key per net-pin, `worldShape` per pad — router.zig:425-443) and allocates + memsets two occupancy layers; `routedPolishCost` additionally recomputes full `wireScore`, `tidinessPenalty` (O(n²)), and `congestionPenalty` (8 KB bin zero + all-nets pass) though only one part moved. Gated to ≤16 parts, but this is why the routed polish costs seconds.
  - Fix: build the obstacle list + grid once per polished part (only the moved part's pads change per cell — patch those 2 rects), and evaluate HPWL/congestion deltas for the moved part's nets only.

- **[Medium] Ground pass reports a net "routed" even when every via placement failed; also pays `netPoints` before the ground filter** — `src/placement/router.zig:120-137` (and the same ordering in `groundVias` 284-297)
  - `findGroundVia` failures `continue` per pad, then `routed += 1` unconditionally — a fully hemmed-in ground net inflates `routed/total` (and thus `fullRouteCost`'s `unrouted` term sees nothing), hiding a real hand-fix. Separately, pass 1 computes `netPoints` (allocations + pad lookups) for *every* net and only then skips non-ground ones; hoist the `isGroundName` check above the `netPoints` call in both functions.

- **[Low] Three divergent copies of the name heuristics** — `capValueFarads`: `optimizer.zig:7319-7333` vs `module_policy.zig:306-320`; `isInductor`: `optimizer.zig:7302-7305` vs `module_policy.zig:294-297`; `isInputRailName` (`optimizer.zig:6273-6297`) vs `isInputRail` (`module_policy.zig:229-240`); ground: `pin_roles.isGroundFn` (`pin_roles.zig:135-152`, prefix-based — classifies `GND_SENSE` as ground via `module_policy.classifyNetName:153`) vs `optimizer.isGroundName:7350` (explicitly tests `GND_SENSE` as *not* ground, 7406)
  - Today the pairs are near-identical, but they are edited independently (the router ground copy already drifted — see the High finding). One `net_names.zig` with the canonical predicates would end the class of bug.

- **[Low] `runRough` computes macro bounding boxes under the *child* solve's threadlocal collision state** — `src/placement/optimizer.zig:2053-2064` (restore happens after all macros are built; `finishMacro` reads `keepBoxOf` → `g_collide_shrink`/`g_route_gap` at 1884-1888)
  - `buildSubMacro` → `solve(child)` → `prepare` overwrites `g_collide_shrink`/`g_route_gap`; `finishMacro` then measures the parent's part keepouts with the last child's values. Inert at the defaults (both 0 / equal), but any non-default `courtyard_overlap` makes macro extents inconsistent with the parent's later `legalizeComposed`. Move `saved.restore()` inside the loop (snapshot → child solve → restore → finishMacro) or pass the box params explicitly.

- **[Low] Threadlocal slices dangle into freed arenas between solves** — `src/placement/optimizer.zig:4601-4614` (`g_net_current`, `g_lowered`, `g_loop_force_scale` all point into the request arena)
  - Every current read path goes through a fresh `prepare` on the same thread first, so this is latent — but nothing enforces it. A future caller that touches `constraintCost`/`congestPitch`/`accumulateLoops` outside a solve reads freed memory. Cheap hardening: reset the three to empty at the end of `solve`/`scorePoses` (or document the invariant next to the globals).

- **[Low] `groundVias` is a hand-maintained copy of `route()` pass 1** — `src/placement/router.zig:254-299` vs 84-137
  - The comment demands they "MUST stay in lockstep" (grid setup + pass-1 loop duplicated line-for-line). The isGroundName drift shows how this class of duplication rots. Extract the shared grid-setup + pass-1 body into one function both call (a `collect_only` flag or a callback per via).


---

# Audit 04 — Schematic diagram / semantic-zoom layout

## Schematic diagram / semantic-zoom layout
_Scope: `src/diagram/{diagram,layout,lod,collect,classify,membership,render,types}.zig` (~7.8k lines, of which ~40% of layout.zig is spec-tagged tests)._

Overall health: **good**. The subsystem is arena-disciplined (per-panel `ArenaAllocator`s in render.zig, scratch arena + owned-allocator split in collect.zig), deterministic (no HashMap-iteration-order leaks into output — I checked `routeFreeEdges` face buckets, `assignRails` bucketing, and the palettes, all of which sort or are order-invariant), and the two separation passes (`separateGroupClusters`, `separateEntities`) provably converge (monotone +direction moves / capped passes). Test coverage is unusually strong. The real problems cluster around **identity resolution by display label instead of authoring key** (two findings, one of which silently loses user edits), a **BFS filter that contradicts its own contract**, and comments teaching a DSL form (`(layout …)`) the evaluator has since retired.

### Findings

- **[High] Layout-tab drag writeback emits display labels, but placements resolve by authoring key — dragged sub-block/stub positions are silently lost** — `src/diagram/render.zig:644-650`
  - `writeNode` stamps `data-name` with `node.label`, and the comment (render.zig:644-646) says this is so "the Layout-tab drag writeback can regenerate `(place "name" …)`". The viewer JS does exactly that (`src/serve/assets/schematic_viewer.js:3506,3565,3449-3472` builds `(anchor "<data-name>")` / `(place "<data-name>" …)` and POSTs `/api/diagram-layout/...`). But `(place …)`/`(anchor …)` names resolve through `nodeByKey` (`src/diagram/layout.zig:576-581`), which matches `Node.key` only. For an unattached **sub-block** node, `label` is the module's design-block title while `key` is the handle (`src/diagram/collect.zig:252` — `label = sb.block.name`, key = `sb.name`); for a **stub**, `label` prefers `p.role` over the `p.name` key (`src/diagram/collect.zig:284,299`). Sections happen to work only because their key == label.
  - Result: drag a power sub-block chip (which is *always* an unattached chip — collect.zig:57-65 deliberately un-adopts power sub-blocks) or a role-titled stub, hit Save, and the regenerated directive names a block that doesn't exist — which per the documented rule is "dropped silently", so the block falls back to the auto row and the user's edit evaporates on reload. Depending on which chip lands top-left, the emitted `(anchor …)` itself can be dead, scattering the whole saved layout.
  - Fix: emit the authoring key (`if (node.key.len > 0) node.key else node.label`) into `data-name` (or add `data-key` and prefer it in the JS). One-line change in `writeNode`; add a round-trip test with a sub-block whose module title differs from its handle.

- **[High] LOD glance layer resolves nodes→chips by display label; duplicate labels mis-aggregate or drop glance edges** — `src/diagram/lod.zig:271-300`
  - `entityOf` maps group chips via `entityByLabel(ents, gb.label)` (lod.zig:281) and solo blocks via `entityByLabel(ents, nd.label)` (lod.zig:290); `entityByLabel` returns the *first* label match (lod.zig:295-300). Duplicate labels are realistic: two sub-blocks instantiating the same defmodule share the module-title label (collect.zig:252 — e.g. the `adcarray` pattern of `adc1..adc3` on one module, or two identically-titled rail modules), two `(group …)`s may share a label, and both `TX_EMVS`/`TXEMVS` antenna bases render as "TX-EMVS cell" (collect.zig:665).
  - Result: all same-labelled blocks fold onto the first chip in `ent_of`, so aggregated connections between the twins vanish (`ea == eb` drop, lod.zig:358), other edges attach to the wrong chip, and net-count `×N` tags are wrong — at exactly the zoom level that's the page's default (`data-lod="0"`).
  - Fix: `buildEntities` already knows exactly which node ids each chip claims (the `grouped[]`/member loops, lod.zig:213-265); have it fill the `ent_of` array as it builds instead of re-deriving it by label afterwards. Removes `entityByLabel` entirely.

- **[Medium] `boundaryChip` BFS traverses ground nets, violating its own "never through a power/GND net" contract — antennas behind shunt matching elements silently disappear** — `src/diagram/collect.zig:697,728`
  - The doc comment (collect.zig:693-696) says the passive-closure trace never crosses "a power/GND net (so a shunt-to-ground match doesn't pull in the plane)", but the filter only skips `CLASS_POWER` (collect.zig:728); GND classifies as `CLASS_GROUND` (`classify.zig:75`), so a shunt cap/inductor to ground enqueues the entire GND plane, whose pins include every IC → `count ≥ 2` → `boundaryChip` returns null → the antenna node is never synthesised (collect.zig:772 `orelse continue`). Any RF feed with an L-network/shunt-C match — extremely common — loses its Layout-tab antenna with zero diagnostics.
  - Fix: `if (cls == CLASS_POWER or cls == CLASS_GROUND) continue;` (or `graph.classes[cls].is_reference`-aware). Add a test with a shunt-to-GND matching cap mirroring the existing `TX1_RFOUT` test at collect.zig:1286.

- **[Medium] Multiple `(edge …)` directives on the same side stack their members on identical cells with no bump or warning** — `src/diagram/layout.zig:487-521`
  - `resolveEdges` computes one shared column per side (`min_col - 1` / `max_col + 1`, layout.zig:511) and the same centred row window for every directive (layout.zig:509,516), and writes `cell_of` without consulting the occupancy that `resolvePlacements` so carefully maintains (bump + `log.warn`, layout.zig:429-443). Two `(edge left …)` bands therefore render exactly on top of each other; `resolveEdges` can also silently overwrite an earlier `(place …)`d block's cell. Same class of bug the placements collision-bump was added to kill (test at layout.zig:2747).
  - Fix: thread the `occupied` map into `resolveEdges` and bump along the stacking axis (or offset each same-side directive by its member count), warning like the placements path does.

- **[Medium] Power-view routes carry fabricated endpoint ids and multi-source designs fan every regulator feed from the first source card** — `src/diagram/layout.zig:2390-2416,2440-2443`
  - `pwRoute(0, g, …)` (layout.zig:2413) hard-codes `from_gid = 0` (graph node 0 — an arbitrary section) for every source→regulator wire, and bucket feeds use `to_gid = 0` (layout.zig:2442). These ids are emitted verbatim as `data-a`/`data-b` on paths and dots (`render.zig:759-761,919-921`), the attributes the hover-focus JS keys on — harmless today only because the power panel draws `dg-pcard`s, not `dg-node`s, but a trap for anyone extending hover/cross-probe to that view. Separately, with >1 source card the wire origins are all `src_top + frac * pw_src_h` where `src_top` is the *first* card's top (layout.zig:2390-2399,2411-2412) — a second source (e.g. battery + USB) renders as if it feeds nothing.
  - Fix: track the feeding source per regulator (`info.parent` already has it, layout.zig:2174) for both the geometry and `from_gid`; use a sentinel (`maxInt(u32)`) rather than 0 for the bucket pseudo-endpoint.

- **[Medium] `computeGroupsLayout` is dead code (~55 lines) that also type-confuses `Route.from_gid`** — `src/diagram/layout.zig:894-954`
  - No production caller: `renderTabs` renders blocks/free/system/class panels only (`render.zig:114-122`); the only references are its own spec test (layout.zig:2999) and `src/leak_tests/diagram.zig:268`. It also stuffs *group indices* into `Route.from_gid`/`to_gid` (layout.zig:937-938), a field documented as graph node ids (layout.zig:65-76) and consumed as such by every edge writer — a latent hover/cross-probe bug the moment someone wires the view up.
  - Fix: delete it (plus its tests), or if the Groups view is planned, give it its own route type instead of overloading `Route`.

- **[Medium] Doc drift: the package still teaches `(layout …)`, a form the evaluator has retired** — `src/diagram/diagram.zig:19-21`, `src/diagram/types.zig:179-182`, `src/diagram/layout.zig:328-341`, `src/diagram/render.zig:28-33,52-56`
  - `src/eval/forms.zig:164-166` declares `diagram-layout` "the canonical (and only) name", and its test (forms.zig:560-564) asserts `fromAtom("layout")` is `null` — the legacy alias no longer parses. Yet every doc comment in this package (`renderBlockDiagramTabs` "(`(layout …)`)", `Graph.layout` "Declarative `(layout …)` directives", the free-layout section header "with `(layout (anchor "a") …)`", render.zig's tab docs) presents `(layout …)` as the live spelling. CLAUDE.md's "**`(layout …)` is the legacy alias** — both parse" is also stale against forms.zig. An agent following these comments authors a form that no longer evaluates (surfacing only as a lint warning). Related drift: diagram.zig:18-21 and render.zig:1-3 say Layout/System leads, but Block overview leads whenever groups exist (render.zig:66-67,93-95).
  - Fix: sweep the comments to `(diagram-layout …)`, mention the Block-overview lead, and fix the CLAUDE.md sentence.

- **[Low] Lane-shifted routes skip the collision re-check, and rejected simple paths still consume a lane slot** — `src/diagram/layout.zig:1285-1296,1326-1341,1547-1551`
  - `clearHy`/`clearVx` validate the *centred* channel, then `hStair`/`vStair` shift the run by `laneDelta(n)` (±9 px per wire, layout.zig:1286,1293) with no re-check — with `route_clear = 6` px and enough wires in one corridor the shifted wire clips blocks the centred one cleared. `buildFreeRoute` also bumps the `mv`/`mh` lane counter before knowing the simple path survives (layout.zig:1326,1347), so failed candidates burn lane slots and leave uneven fans. In the System router, every blocked same-column ⊐ hop shares one fixed `lanex = colRightX + h_gap*0.45` (layout.zig:1548-1551), so parallel hops overlap exactly.
  - Fix: re-test the shifted polyline against `obs` (retreat to the centred one on hit); bump lanes only on the accepted shape; lane-spread the ⊐ x like the free router does.

- **[Low] Fixed 256-slot stack buffers silently degrade very large layers; DFS recursion is O(nodes) deep** — `src/diagram/layout.zig:1840,1977`
  - `medianKeys` caps neighbour sampling at `buf: [256]f64` (layout.zig:1840) and `resolveRankOverlap` skips vertices past `ord_buf: [256]u32` (layout.zig:1977-1983) — a >256-box column silently loses overlap resolution (overlapping boxes drawn). `dfsBreak` (layout.zig:1723) and `dfsBack` (layout.zig:2118) recurse per node. Only pathological diagrams (hundreds of sections) hit any of these, but the failure is silent misrender/stack growth rather than an error.
  - Fix: arena-allocate the scratch arrays to layer size; or at minimum `log.warn` when the cap truncates.

- **[Low] `classify` treats `VSS*` as a power rail, not ground** — `src/diagram/classify.zig:98`
  - `"VSS"` sits in `power_pre`; in most CMOS naming VSS *is* ground (the 0 V reference). A design using VSS/VSSA nets gets a spurious dense power-edge fan (the exact clique the ground reference-class exists to suppress, types.zig:44-46) instead of dropping the net as reference.
  - Fix: move `VSS` to the ground tables (`ground_pre`/`ground_eq`); keep `VS_`-style negative rails matched explicitly if needed.

- **[Low] OOM-path leak: membership maps are grown before their `deinit` defer is registered** — `src/diagram/collect.zig:101-105`
  - `membership.build` succeeds, then the stub loop `try mem.ref_to_node.put(...)` runs *before* `defer mem.deinit(allocator)` — an allocation failure in `put` leaks both hash maps. Same pattern-risk at the tail: `nodes.toOwnedSlice` succeeding while `edge_list.toOwnedSlice` fails leaks the node slice (collect.zig:136). OOM-only, but this codebase's leak_tests suite holds a higher bar.
  - Fix: register the defer immediately after `build`, before the put loop.

- **[Low] Per-edge obstacle rebuild + O(N) linear key lookups in nested loops** — `src/diagram/layout.zig:1414-1435,473-480`
  - `routeFreeEdges` reallocates the full obstacle Rect list (all nodes + group boxes) once *per edge* (layout.zig:1419-1426) → O(E·(N+G)) arena churn, and each `buildFreeRoute` scans O(chans·obs). `isEdgePinned` inside `resolveEdges`' bounds scan calls `nodeByKey` (O(N)) per member per node → O(N²·M). `lnodeOf` (layout.zig:957-960) is likewise an O(N) scan called per group member. Harmless at today's tens-of-nodes diagrams; worth precomputing (one shared blocks array + per-edge group filter, key→gid map) before diagrams grow into the hundreds.

- **[Low] Glance aggregation computed twice per render; group bounding-box logic duplicated** — `src/diagram/lod.zig:159-165,192-197`; `src/diagram/layout.zig:965-999,1074-1120`
  - `writeGlanceLayer` and `writeBaseAggLinks` each recompute `entityOf` + `aggregateEdges` from identical inputs in the same render pass (`render.zig:378-386`). And `computeGroupBoxes` vs `collectGroupObstacles` are near-identical member-bbox loops (stack extents, pads) that must stay byte-in-sync for "wires dodge the visible box" to hold — a drift hazard called out by neither. Compute the agg set once and pass it to both writers; extract one shared `groupBounds()` helper.

- **[Low] Maintainability: layout.zig hosts four unrelated layout engines in one 3.3k-line file** — `src/diagram/layout.zig:1,328,1009,2062`
  - Sugiyama pipeline (line 1), staged System/Chain layout (172-326), the free grid + obstacle router (328-1448), and the power supply-tree (2062-2494) share almost nothing beyond `Route`/`LNode`. The file is healthy per-function, but cross-engine constants (`node_w`, gaps) and the shared `Route` shape make accidental coupling easy (see the `computeGroupsLayout` gid confusion above). Natural split: `layout/free.zig` (grid + router), `layout/power.zig`, keeping the layered core here. Test-tag migration is mechanical since tests are colocated per engine.


---

# Rendering audit

## Rendering (HTML/SVG/JSON + PCB raster/PNG)

_Overall health: the raster→PNG→DEFLATE stack is in genuinely good shape — the hand-rolled fixed-Huffman DEFLATE was checked symbol-by-symbol against RFC 1951 (lit/len code ranges, length symbol 285 for 258, 5-bit reversed distance codes, zlib FCHECK 0x7801, PNG chunk CRCs, Up-filter round-trip) and no encoding bug was found; it also has real round-trip tests. The HTML side is split-brained on escaping: `writeHtmlEscaped`/`writeJsString`/`json_writer` exist and are used for most text, but a systemic set of raw `{s}` interpolations remains — the entire SVG emit path (`render_svg/*`) writes net names, ref-des, values and pin labels with **zero** escaping, and one hand-rolled JSON emitter skips the shared escaper for the design name. Since `import-kicad` ingests third-party board files whose net names flow straight into these sinks, that's a real XSS vector, not a theoretical one. Secondary issues: unsafe `@intFromFloat` on unclamped floats in the rasterizer (UB in the ReleaseSmall prod build), fixed 64-slot pin buffers that silently drop connections on big rails, and a 3× recomputation of the expensive merge-aware hub split in the scene-graph renderer._

### Findings

- **[High] Entire SVG emit path writes user-controlled text into markup unescaped** — `src/render_svg/draw.zig:74-76`, `src/render_svg/branch.zig:172-186`, `src/render_svg/branch.zig:233-251`, `src/render_svg/branch.zig:263-281`, `src/render_svg/section_inset.zig:170-192`, `src/render_svg/section_inset.zig:280-307`, `src/render_svg/connection.zig:163-169`
  - `drawNetWire` prints `data-net="{s}"` raw; `drawTerminal` prints the net name into both a `data-net` attribute and a `<text>` node raw; `drawPassiveLeft/Right` print `data-ref="{s}"` and `<text>{s} {s}</text>` (ref + `formatShort` = user value like `(cap-0402 "…")`); `renderHubAllPins`/`renderOneStub` print `data-ref`, `data-pin`, hub `displayValue`, and pin-function labels (from `lib/pinouts/*.sexp`) raw. These SVGs are inlined in the schematic HTML page, so a `"` breaks out of the attribute and `<script>`/`onmouseover` payloads execute. Net names, values, and pinout function names are attacker-reachable via `import-kicad` (arbitrary `.kicad_pcb` net names), uploaded symbols (`/api/upload-symbol`), and MCP `write_file`.
  - Fix: route every `{s}` in these files through a shared `writeXmlEscaped` (escape `< > & "`); the helper already exists in `render_html.zig` — move it somewhere shared (e.g. `render_svg/draw.zig`) and use it for both attribute and text-node contexts.

- **[High] `render_html`: design title unescaped in `<title>`, ref-des unescaped in `data-ref` attributes** — `src/render_html.zig:89`, `src/render_html.zig:664`, `src/render_html.zig:707`
  - Line 89: `w.print("<title>{s} — Schematic</title>", .{block.name})` — `block.name` is the `(design-block "…")` title; `</title><script>…` escapes the RCDATA context. Lines 664/707: `w.print("<div class=\"sec-hub-reqs\" data-ref=\"{s}\">…` / `"<div class=\"sch-hub\" data-ref=\"{s}\">"` — `(instance "REF" …)` names go into a double-quoted attribute raw; a `"` in the ref breaks out. Ironic detail: three lines later the *same* strings are correctly passed through `writeHtmlEscaped`, so these are clearly oversights, not policy.
  - Fix: `writeHtmlEscaped` for all three (title and both `data-ref`s).

- **[High] Scene-graph JSON: design name emitted without escaping** — `src/render_json.zig:1631`
  - `serializeScene` writes `try w.print(",\"name\":\"{s}\"", .{scene.design_name})` while every other string in the file goes through `json_writer.writeField/writeEscaped`. `design_name = block.name` (user-authored title). A `"` or `\` corrupts the whole `/api/scene-graph/:name` document (breaks the editor/live-push pipeline), and a crafted title can inject arbitrary sibling JSON keys into a payload other clients trust.
  - Fix: `try w.writeAll(",\"name\":");` + `json_writer.writeString(w, scene.design_name)` — one line.

- **[Medium] Rasterizer: `@intFromFloat` on unclamped values — UB in the ReleaseSmall prod build on non-finite/huge coordinates** — `src/raster.zig:101-104`, `src/raster.zig:156-157`, `src/raster.zig:175-176`, `src/raster.zig:237-242`, `src/render_pcb_png.zig:160-162`
  - `fillRect` computes `@intFromFloat(@round(x * s))` **before** clamping (`clampX` runs on the already-converted i64); `fillPoly` and `discRing` do the same for scanline bounds, and `renderCanvas` does `board_w = @intFromFloat(@round(cw_mm * scale))`. `@intFromFloat` on NaN/±inf or a value outside i64/u32 range is illegal behaviour, and the deploy hook builds ReleaseSmall (runtime safety off), so a single NaN part coordinate leaking out of the placement optimizer (0-length normalize, corrupt sidecar `layouts.json` poses, etc.) becomes silent memory-unsafe UB instead of a crash. `raster.zig`'s public draw calls are the choke point.
  - Fix: clamp in float space first (e.g. `std.math.clamp(v, -1e9, 1e9)` or an `isFinite` guard returning early) before every `@intFromFloat` in these five sites; cheap and centralizable in two small helpers.

- **[Medium] `synthesizeSpokeConnections`: fixed 64-slot buffers silently drop pins on big rails** — `src/render_svg/context.zig:545-548`, `src/render_svg/context.zig:551-565`
  - `hub_pins_buf: [64]PinRef` / `spoke_pins_buf: [64]PinRef` are filled with `if (count < buf.len)` guards and no diagnostics. A non-ground rail with >64 hub pads or >64 attached passives (a large MCU's VDD3V3 with per-pin bypass caps is exactly this shape) silently loses spokes: they never get an adjacency entry, so they vanish from the hub SVG and get reported as "staged/floating" in the editor scene graph — a wrong schematic, not a rendering nit.
  - Fix: switch to `std.ArrayListUnmanaged(PinRef)` on `self.allocator` (everything here is arena-backed already), or at minimum `log.warn` when a bound is exceeded.

- **[Medium] Scene-graph renderer computes the expensive merge-aware split three times per hub** — `src/render_json.zig:685` (via `mergeAwareHubHeight`, 483-529), `src/render_json.zig:870` (`collectHubData`), `src/render_json.zig:1020` (`collectHubConnections`)
  - Each of the three passes rebuilds the pin list, re-sorts it, rebuilds the pin-name map (re-reading + re-parsing `lib/pinouts/*.sexp` from disk in `collectHubData`), regroups, and calls `splitGroupsByMergeAwareHeight` — whose `mergeAwareGroupHeights` runs `findSpokeChain` (a recursive graph walk) per connection. The comment at 1014-1019 documents that passes 2 and 3 *must* split identically — the strongest possible hint they should share one computed result. On hub/cap-heavy designs this is the dominant cost of `renderSceneGraph`, which runs on every push/edit endpoint (`serve/edit.zig` calls it at 440/1959/2164/2230/2433).
  - Fix: compute `{groups, split}` once per (hub, part) cell, store next to `cell_heights`, and pass it into both collect functions. Also removes the mirror-invariant bug class.

- **[Medium] `design_name` interpolated raw into `href` attributes** — `src/render_html.zig:343-348`, `src/render_html.zig:370-374`, `src/render_html.zig:379-383`
  - `w.print("<a … href=\"/api/export-bom/{s}\" …", .{design_name})` etc. `design_name` is the on-disk design file stem — narrower attacker surface than net names (needs a hostile filename, creatable via MCP `write_file`/`move_file` or `POST /api/new-design`), but a `"` in it breaks out of the attribute. Lower probability than the SVG sinks, hence Medium.
  - Fix: `writeUrlEncoded` (already in the file at 2097) for the path segment, or `writeHtmlEscaped` at minimum.

- **[Low] Dead `findSpokeChain` calls and dead parameter in scene-graph collection** — `src/render_json.zig:1340-1344`, `src/render_json.zig:1350-1353`, `src/render_json.zig:978`, `src/render_json.zig:750`
  - `collectMergedPassive` runs the recursive chain walk on both sides and immediately discards it (`_ = chain;`) — pure wasted work on the hot path. `collectHubConnections` takes `json_hub: *JsonHub` and instantly `_ = json_hub`, and its caller then re-stores an unchanged struct (`scene.hubs.items[len-1] = json_hub`) — a no-op that implies mutation that never happens.
  - Fix: delete the two walk calls, drop the parameter, drop the re-store.

- **[Low] `upperInSet` 64-byte cap is asymmetric with unbounded key building** — `src/render_pcb_png.zig:1100-1105` vs `src/render_pcb_png.zig:1114-1118`, `src/render_pcb_png.zig:446-449`
  - Keys are inserted via unbounded `upper(alloc, ref)` but membership tests return `false` for any string >64 bytes, so a deep sub-block ref (`chan3/adc/C_BYP12`-style paths grow) can be highlighted-in but never match. Similarly `netOf` fails (returns null → part rendered dim/unlabeled) when `ref|pad` exceeds its 128-byte `bufPrint`. Silent focus/label misses only.
  - Fix: allocate (arena) for the >64 case, or cap key insertion identically so both sides agree.

- **[Low] PNG encoder edge guards** — `src/png.zig:18-21`, `src/png.zig:83`, `src/png.zig:119`
  - `encodeRgb` happily emits an IHDR with `width==0`/`height==0` (invalid PNG — decoders reject) if a caller ever passes a degenerate canvas (`render_pcb_png.zig:160` can round `board_w` toward 0 on pathological aspect ratios); `writeChunk`'s `@intCast(data.len)` to u32 is an unchecked panic-or-UB for a >4 GiB IDAT (unreachable today, but a one-line `std.debug.assert` documents it). Comment nit: `png.zig:119` says "validates the dynamic-Huffman stream" — the encoder emits *fixed*-Huffman.
  - Fix: `if (width == 0 or height == 0) return error…`/assert at the top of `encodeRgb`; assert in `writeChunk`; fix the comment.

- **[Low] DEFLATE: hash-chain positions stored as `i32`** — `src/deflate.zig:151` (`head[h] = @intCast(i);`)
  - Inputs ≥2 GiB overflow the `@intCast` (panic in safe builds, UB in ReleaseSmall). Unreachable at current canvas caps (≈17 MB filtered scanlines) and HTTP-response sizes, but the function is `pub` and generic — worth an assert or a doc line stating the 2 GiB limit. Otherwise the encoder audits clean: RFC 1951 fixed-code tables, symbol-285 handling, distance coding, MAX_DIST chain break, and overlap matches are all correct, with round-trip tests.

- **[Low] Duplication across the two renderers guarded only by comments** — `src/render_html.zig:952-976` vs `src/render_json.zig:151-170` (two near-identical `loadPinoutNames`, the JSON one silently missing `pinIdStr`'s atom fallback ordering), `src/render_html.zig:927-947` vs `src/render_json.zig:855-867` (pinout-supplement chains), `src/render_json.zig:805-938` vs `src/render_json.zig:968-1045` (`collectHubData`/`collectHubConnections` share ~60 lines of pin collection/sort/split), `src/render_json.zig:331-430` vs `src/render_json.zig:1235-1304` (merge-key logic in `mergeAwareGroupHeights` duplicates `mergeIdenticalSpokes`), `src/render_json.zig:1463-1548` (branch-tree Left/Right mirror pair, also mirrored again in `render_svg/branch.zig:51-100`)
  - The "must mirror exactly or wires miss their pins" invariant (`render_json.zig:1014`) is enforced by prose. Any drift is a visual-correctness bug that no test catches.
  - Fix: extract one `collectHubLayout(ctx, hub, part) → {groups, split}` used by all three passes (same change as the Medium perf finding), one shared pinout loader, and a side-parameterized branch-tree walker.

- **[Low] Hash-map double-lookup patterns in hot context building** — `src/render_svg/context.zig:687-696` (`buildNetIndex`: `get` + `append` + `put` copies the list header and hashes twice per pin), `src/render_svg/context.zig:846-850` (`adjAppend`, same pattern, called for every net pin + every synthesized spoke edge)
  - On large flattened designs these run tens of thousands of times per render. `getOrPut` halves the hashing and removes the struct copy-back.

- **[Low] `writeHtmlEscaped` doesn't escape `'`** — `src/render_html.zig:2082-2090`
  - All current attribute sinks are double-quoted so this is not exploitable today, but the helper's name promises attribute-safety it only half-delivers; one future single-quoted attribute re-opens the XSS class fixed above.
  - Fix: add `'\'' => "&#39;"` to the switch.


---

# Audit 06 — ERC, review & coverage

## ERC, review & coverage
_Scope: src/erc.zig, review*.zig, req_checks.zig, coverage.zig, checks.zig, asserted_fns.zig, query.zig (+ read-only inspection of their heuristics deps: placement/pin_roles.zig, eval/net_analysis.zig, placement/module_policy.zig, eval/validate.zig)._

Overall health: **good**. The three headline checks (`decoupling_unbound`, `strap_tied_to_rail`, `no_connect`) match their CLAUDE.md contracts closely — per-block recursion is real, the sign-off/exemption ladders (non-empty reason, bulk ≥4.7 µF, single-supply-pad, `(decouples rail)`, translator-channel demotion, positional-pin suppression) are implemented and well-tested. `missing_decoupling`'s base-rail aggregation (trunk + `.stub` folding, sub-block-cap credit via net-ties) is correct. `review_html.zig` HTML-escapes every dynamic string; `review_json.zig` escapes everything **except** the power-tree block. `asserted_fns.zig`, `checks.zig`, and `query.zig` are clean. The dominant defect class is **inconsistent sub-block coverage**: roughly half the ERC rules silently see only the top-level block, so a module's internals pass checks the top level would fail — a structural false-negative family, partially (but only partially) mitigated by the eval-time validator.

### Findings

- **[High] Half the ERC rules never look inside sub-blocks — module internals silently pass** — `src/erc.zig:601`, `src/erc.zig:632`, `src/erc.zig:800`, `src/erc.zig:836`, `src/erc.zig:2036-2041`, `src/erc.zig:2178`, `src/erc.zig:310`, `src/erc.zig:1747-1751`, `src/erc.zig:737`
  - CLAUDE.md's design principle is "checks run PER BLOCK (recursing sub-blocks)". That holds for `missing_requirements` (:156), `decoupling_unbound` (:982), `strap_tied_to_rail` (:1174), and `no_connect` (:1329) — but **not** for the rest:
    - `checkDuplicateRefDes` (:601), `checkMissingValues` (:800), `checkMissingFootprints` (:836) use `collectBlockInstances`, which explicitly returns *this block only* (:2036-2041). A module part with no value/footprint reaches the BOM (`review.zig:620-663` **does** recurse) yet is never ERC-flagged.
    - `checkPinFunctions` builds its ref→pinout map from **all** instances recursively (:2166) but then iterates only `block.nets` (:2178) — `(as …)` assertions and the mandatory multi-alt `pin_function_required` rule are never evaluated for pins inside any module.
    - `checkPinMultiNet` (:632) and `checkVoltageDomainCompat` (:273, :310) walk top-level nets/instances only.
    - `checkUnconnectedPowerPins` recurses exactly **one** level (:1747-1751 — `checkBlockPowerPins` itself never descends), so a module-inside-a-module IC with no ground is missed. `checkUnconnectedPorts` (:737) likewise validates only the top block's direct sub-block ports; a nested module's *required* port left unwired inside a level-1 module is never checked.
  - Why it matters: a broken board passes. The eval-time validator (`eval/validate.zig:21-26`, run per `(design-block …)` incl. module bodies, `eval/design_block.zig:252`) covers only single-pin nets, section-port voltage mismatch, missing decoupling, and description length — the pin-function, dup-ref, missing-value/footprint, power-presence, voltage-domain gaps have **no** other net.
  - Fix: give each of these the same recursive shape as `checkStrapTies` (per-block worker + `for (block.sub_blocks) recurse`). For `checkDuplicateRefDes`, decide the contract: either flatten (matching its docstring "across the full flattened design", :593) or per-block, but not the current top-only hybrid.

- **[Medium] `startsWith(base,"VS")` marks VSS/VSYNC/VSW/VSENSE as *power* — IC-power-presence false negatives** — `src/erc.zig:1884`
  - The inline `is_vdd` heuristic in `checkBlockPowerPins` includes `std.mem.startsWith(u8, base, "VS")`. `"VSS"` is classified ground at :1860 **and** power at :1884 (the two flags are computed independently, :1896-1900), so an IC whose only rail connection is VSS counts as powered — the exact case `pin_roles.isSupplyFn` deliberately guards against ("Ground names are rejected first so VSS/VSSA never read as a supply via the VS exact form", `src/placement/pin_roles.zig:157,173-180`, which uses **exact** `"VS"`). Signal nets `VSYNC`, `VSENSE`, and switch nodes named `VSW` also satisfy the power check, silencing the "IC has no power connection" warning.
  - Fix: reject `isGroundFn(base)` first and tighten the `VS` term to an exact/`VSYS` match — or simply delegate the whole predicate to `pin_roles.isSupplyFn`/`isGroundFn` to kill the duplicated, drifting heuristic.

- **[Medium] `capFarads` can't parse `µ` — a "10µF" bulk cap becomes a build-failing `decoupling_unbound` error** — `src/erc.zig:1066-1080`
  - The bulk-reservoir exemption (:932) parses the cap value with a local `capFarads` that recognizes only ASCII `p/n/u/m` and returns **0** for anything else, so `"10µF"` (or `"4.7µF"`) reads as 0 F → treated as an HF cap → flagged `decoupling_unbound` (**error** — gates `netlisp build`). Meanwhile `req_checks.parseMicroFarads` (`src/req_checks.zig:797`) *does* accept `µ` — the codebase already knows the format. Three near-identical cap parsers exist (`erc.capFarads`, `module_policy.capValueFarads` `src/placement/module_policy.zig:306`, `req_checks.parseMicroFarads`) with divergent behavior. Current corpus uses ASCII `uF` in values (µ appears only in comments), so this is latent — but one imported/hand-typed µ value produces a hard false positive.
  - Fix: accept the UTF-8 `µ` prefix (0xC2 0xB5) in `capFarads`/`capValueFarads`, or consolidate on one shared parser.

- **[Medium] Dangling `(verifies …)` sign-offs vanish silently — no orphan diagnostic anywhere** — `src/req_checks.zig:70-108`
  - `applyOneVerification` returns without effect when the target ref-des/id doesn't match any instance, or matches but the `req_id` is stale (:91 `orelse return`), or the ref isn't in the results map (:92). Nothing counts or reports unmatched verifications — not in ERC, not in the review doc. MEMORY.md already records the real-world failure ("ref-des drift orphans the whole `<design>.checks.sexp`"): a renumber flips previously VERIFIED requirements back to PENDING with zero indication that N sign-offs went dangling.
  - Fix: return/collect a "matched" flag per verification and surface unmatched ones as an ERC warning (e.g. `verification_orphaned`) or a review-doc row.

- **[Medium] Power-tree JSON emits rail/source names unescaped — malformed JSON on special chars** — `src/review_json.zig:73`, `src/review_json.zig:350-352`
  - `writePowerTreeNode` and the edges loop use raw `{s}` interpolation (`"rail":"{s}"`, `"from":"{s}"`, `"source_ref_des":"{s}"`) while every other field in the file goes through `json_writer.writeString`. A net name containing `"` or `\` (both accepted by the S-expression string parser) breaks the entire `/api/review/:name` document.
  - Fix: route these three fields through `json_writer.writeString` like everything else.

- **[Medium] `components_not_grouped` is an **error** — a style rule that fails builds and reddens health chips** — `src/erc.zig:249-253`
  - The grouping rule ("split components into `(group …)` regions … for a scannable block view") is purely organizational, yet it emits `severity=.@"error"`, which per the repo's own conventions fails `netlisp build`/`check`, turns the home-page chip red, and lands in the review "unresolved" list alongside genuine electrical faults. It also depends on diagram-graph construction (`collect.collectGraph`), so a rendering-layer change can flip electrical-gate status. CLAUDE.md's ERC documentation doesn't mention this check at all (its erc.zig summary — "duplicate ref-des, floating nets, unconnected pins, voltage mismatches, missing decoupling" — covers 5 of the 24 `ViolationKind`s; doc drift).
  - Fix: demote to `warning` (matching `missing_footprint`/`test_point_missing` treatment of non-electrical gaps), and refresh the CLAUDE.md check inventory.

- **[Medium] Test-point coverage matches only the exact component `"testpoint"`, not `testpoint-*` variants** — `src/erc.zig:558` vs `src/eval/env.zig:710-713`
  - `checkTestPointCoverage`'s legacy-instance scan uses `std.mem.eql(u8, inst.component, "testpoint")` while the canonical predicate `env_mod.isTestPoint` (used by the same file's power-pin check :1910 and by `review.zig:319`) also accepts `testpoint-…` (e.g. an SMD variant). A rail probed only by a `testpoint-smd` instance is falsely reported "has no test point" (warning-level FP), and the review Test-Points table (isTestPoint-based) will simultaneously *list* that same probe — visibly contradictory output.
  - Fix: use `env_mod.isTestPoint` at :558.

- **[Medium] `suffixToOhms` defaults unknown suffixes to ×1.0 — milliohm shunts read 1000× high** — `src/req_checks.zig:783-808`
  - `parseOhms("10m")` → suffix `"m"` isn't in {k, M, G} → multiplier 1.0 → 10 Ω instead of 0.01 Ω; `"4R7"` → 4 Ω; any garbage suffix silently passes as ohms. Contrast `suffixToMicroFarads`/`suffixToMicroHenries`, which return `null` on unknown suffixes so the part just doesn't qualify. This feeds `pullup_range` and `series_element(R)` requirement checks — a current-sense shunt or R-style value produces a confidently *wrong* pass/fail message in the review doc.
  - Fix: return `?f64` from `suffixToOhms` (null on unrecognized), add `m`/`R`-notation support if desired.

- **[Low] `checkPowerBudget` percent math: `@intFromFloat` of ∞ when `source_typ_a == 0`** — `src/erc.zig:1988`
  - `power_budget` marks a rail `.tight` whenever `load_typ > 0.8 * styp` (`src/eval/power_budget.zig:412`) — including `styp == 0.0` (a declared-zero `(current 0 …)`). Then `pct = @intFromFloat(100 * load / 0)` is `@intFromFloat(inf)` → safety panic in Debug, UB in release. One degenerate source annotation crashes the whole ERC pass.
  - Fix: guard `styp <= 0` before the division (emit the row without a percent), or clamp.

- **[Low] `checkVoltageMismatches` compares every entry only against `entries[0]`** — `src/erc.zig:1693-1713`
  - With declarations 3.30 / 3.291 / 3.309 V (tolerance 0.01), entries 2–3 differ by 0.018 V but both sit within tolerance of the first → no flag; conversely which mismatch gets reported depends on section iteration order, and only the first offending pair per net is emitted. Minor FN/nondeterminism at tolerance boundaries.
  - Fix: compare min vs max across all entries per net.

- **[Low] `isSupplyFn` whole-name prefix match swallows supply-named straps ("VDD_EN", "VIN_SEL0")** — `src/placement/pin_roles.zig:161-182`, `:395`
  - The name is separator-stripped *then* prefix-matched, so `VDD_EN` → `VDDEN` → `startsWith "VDD"` → supply. Since `isStrapFn` rejects supplies first (:395), such enable/select pins can never be straps → no `strap_tied_to_rail` check on them, and `connectionRequirement` returns `.skip` (:294) so a floating one is silent too. Also `VOUT…`/`VIN…`-prefixed sense pins (`VINSENSE`) read as supply.
  - Fix: tokenize (as `isStrapFn` already does) and test strap tokens *before* concluding supply for multi-token names, or require the supply token to be the whole normalized name when a strap token is also present.

- **[Low] `(decouples "IC" PIN)` accepted without validating the pad exists on that hub/rail** — `src/erc.zig:929`
  - Any non-empty `decouple_pin` exempts the cap; a typo'd pad (`(decouples "U1" 99)`) or a pad not on the cap's rail satisfies the *requirement* gate with no cross-check (only the placement-time `decouple-unbound` lint might notice, and only as a warning). Since this check's whole point is forcing a *correct* declaration, cheap validation (pad ∈ hub's pads on that net) would close the loop.

- **[Low] `evalNotConnected` ignores ports/net-ties — a "must float" pin wired by the parent still passes** — `src/req_checks.zig:451-488`
  - A pin on a single-pin net inside a module passes the `not_connected` requirement even when that net is exposed as a block port and tied externally by the parent design. Its mirror `evalPinNotFloating` (:524-528) explicitly credits block ports for exactly this topology — the NC direction needs the symmetric check (port/net-tie exposure ⇒ *connected* ⇒ fail).

- **[Low] Markdown review interpolates ref/component/value raw into inline HTML** — `src/review_md.zig:422-423`, `:348`
  - `writeHubBlock` prints `ref_des`/`component`/`value` unescaped inside `<details><summary>…</summary>` (and `writeSchematicSections` prints `sb.name` raw). Markdown renderers (GitHub/VSCode/Obsidian) pass inline HTML through, so a `<`/`&` in a component name breaks the collapsible structure; a hostile name is an HTML-injection vector into the exported report. `writeMdEscaped` (:623-629) escapes only `|` and newline and isn't applied here. Same class (much lower stakes) as the JSON power-tree finding.
  - Fix: HTML-escape these three fields (reuse the `review_html.zig:321` escaper).

- **[Low] Doc drift: `checkDuplicateRefDes` claims "full flattened design"** — `src/erc.zig:593` vs `:2036-2041`
  - The docstring promises flattened-design scope; `collectBlockInstances` intentionally returns the top block only (its own doc says so). Whichever way the High finding above is resolved, one of the two comments must change — today the docstring overstates the guarantee.

- **[Low] Per-pin linear scans in strap/decoupling checks are O(rail_pins × instances)** — `src/erc.zig:1143`, `:1147`, `:940-956`
  - `checkBlockStrapTies` calls `componentOf`/`instanceOf` (linear over `block.instances`) for **every pin of every rail net** — GND alone can be hundreds of pins — and `checkBlockDecouplingBinding` re-walks all nets per cap to find its legs. Fine at today's design sizes (hundreds of parts); on `import-kicad`-scale boards (1000+ parts, multi-thousand-pin ground nets) this turns quadratic. Cheap fix: one ref→instance hash map per block, and a per-net pin index.


---

# 07 — KiCad interop, BOM & emit

## KiCad interop, BOM & emit
_Overall: this bridge is in good shape where it matters most. The `.kicad_pcb` writer (`src/kicad_pcb/writer.zig`) is defensive and well-tested: name-only net references match pcbnew v20260206, idempotent ops, via/group dedup, back-side mirroring verified against a hand-flipped board, and the HTTP layer wraps writes in tmp→fsync→rename with rotated backups (`serve/sync.zig:1510`). The reader is tolerant of all three pad-number spellings and both net-reference forms. The BOM identity pipeline is deterministic (uuid = uuidFromId(stable id)) with a byte-identical-skip on save. The real weaknesses are at the edges: a use-after-scope in the footprint converter, an isomorphism check in channel folding that is weaker than advertised, lossy geometry round-trips (precision, oval drills), and a systematic miss of bare-numeric pad names in the netlist NC inventory. One boundary (JSON op strings → `Node.string` → verbatim print) has no escaping layer and protects a real board file only by convention._

### Findings

- **[High] Use-after-scope: bare-integer pad numbers in `convertFootprint` return a dangling stack slice** — `src/convert/footprint.zig:85-91`
  - `num_str` for a bare-int pad (`(pad 1 smd …)`, the normal KiCad-5 `(module …)` spelling and how KiCad re-saves numeric pads) is produced by `std.fmt.bufPrint(&num_buf, …)` where `var num_buf: [32]u8` is declared *inside* the `blk:` expression; the slice escapes the block and is used at line 170 after many intervening calls have reused that stack region. This is illegal behavior in Zig — the emitted `lib/footprints/*.sexp` can carry garbage pad numbers, silently breaking every later pad↔net mapping for that footprint.
  - Fix: hoist the buffer to function scope, or reuse the correct pattern already in `src/import_kicad.zig:636` (`padNumText(node, buf: *[32]u8)`) / `src/kicad_pcb/format.zig:22` (arena alloc).

- **[High] Channel-fold "structural isomorphism" cannot distinguish two internal nets with the same digit-template — a rewired channel can fold silently** — `src/import_fold.zig:386` (with `netTemplate` at `src/import_fold.zig:89`)
  - `partSignature` labels a pad on an internal net as `I:<netTemplate(net)>`. KiCad auto-nets from one IC (`Net-(IC4-Pad3)`, `Net-(IC4-Pad7)`) share the template `Net-IC~-Pad~`, so the signature records *that* a pad sits on some internal auto-net but not *which one*. Two channels whose passives are swapped between two same-template internal nets (R on pad-3 net vs pad-7 net) produce byte-identical channel signatures, pass the "verify" step (`channelSignature`, `finishFold`), and the deviant channel is then emitted with the exemplar's wiring (`import_fold_emit.zig:239-326` renders only the exemplar) — a silently wrong netlist for that channel.
  - Why it matters: `--fold-channels` is explicitly sold (module doc + CLAUDE.md) as "verify structural isomorphism"; the netlist is the ground truth being migrated. The only safety net is the manual dry-run sync workflow.
  - Fix: disambiguate same-template internal nets inside the signature — e.g. assign each internal net a canonical index from its sorted (part-slot, pad) membership set and put that partition into the label, or fall back to "channel deviates" whenever ≥2 internal nets in one channel share a template.

- **[Medium] No escaping layer between JSON op strings and the board file: a raw `"`/trailing `\` in any op value corrupts the written `.kicad_pcb`** — `src/kicad_pcb/writer.zig:729,812` (`makeNetForm`/`makeProperty` via `Node.string`) + `src/sexpr/printer.zig:53-63`
  - The printer writes `Node.string` payloads **verbatim** between quotes (by design, for round-tripping tokenizer slices, which are already escape-encoded). But the writer constructs `Node.string` from **JSON-decoded** op fields (net names, ref, value, MPN, canopy_net…). Any value that did not round-trip through the s-expr tokenizer and contains a raw `"` (or ends in `\`) yields an unparseable board file. The concrete unguarded entry point today: `setBomProperty` (`src/bom_resolve.zig:327`) writes a raw HTTP-supplied value into the `.bom` with `("{s} \"{s}\")` — a value containing `"` makes the `.bom` unparseable (silently dropped by `loadBom`'s `catch return &.{}`, losing all user MPN edits), and the same class of value flowing into a `set_field` op reaches the board writer unvalidated. `buildGrText` (`writer.zig:546-559`) has the sibling issue: the label is spliced into parseable text; an embedded `") (` injects extra top-level nodes that are then silently discarded (`nodes[0]` only).
  - Fix: one `sexprEscape()` at the writer/JSON boundary (or validate-and-reject values containing `"`/`\`), plus the same in `saveBom`/`writeBomEntries`.

- **[Medium] Oval drills silently dropped by board import; export then invents a full-pad-size drill (zero annular ring)** — `src/import_kicad.zig:599-607` + `src/export_kicad_footprint.zig:326-329`
  - `emitBoardPad` only accepts `(drill D)` (`dl[1].asNumber()`); `(drill oval DX DY)` — standard for connectors and Micro-USB shields — leaves `has_drill=false`, so the generated `lib/footprints/*.sexp` thru-hole pad has no drill at all. On the way back out, `emitKicadPad`'s fallback "guess drill as min dimension" emits `(drill @min(sx,sy))` — a hole the size of the pad. An import→export round-trip of an oval-drilled part produces an unmanufacturable footprint with no warning.
  - Fix: copy the oval-drill branch that already exists in `src/convert/footprint.zig:132-144` into `emitBoardPad`, and make the export fallback warn (or refuse) instead of guessing.

- **[Medium] Footprint geometry quantized to 0.01 mm at every conversion boundary** — `src/convert/footprint.zig:170`, `src/import_kicad.zig:622`, `src/export_kicad_footprint.zig:314-315`
  - Pad positions/sizes are printed with `{d:.2}` on import (`.kicad_mod`→`.sexp`), board-import (`.kicad_pcb`→`lib/footprints`), and export (`.sexp`→`.kicad_mod`). KiCad library metric footprints routinely carry 3-4 decimals (e.g. 0402 pads at ±0.485, 0.4 mm-pitch BGA at 0.1625 steps); each pass shifts coordinates by up to 5 µm, and errors compound across import→export. Fine-pitch parts land with pads measurably off the vendor geometry; DRC/paste apertures inherit the drift. (Custom-pad polys already use `{d:.3}` — the rectangles should be at least that.)
  - Fix: bump all geometry emission to `{d:.4}` (KiCad's own precision) — cheap and byte-stable.

- **[Medium] Imported DNP parts lose the machine-readable DNP flag** — `src/import_kicad.zig:751` (and `src/import_fold_emit.zig:294`)
  - `emitInstance` writes only a comment `;; DNP on the source board` and then a normal `(instance …)`. The DSL has first-class `(dnp)` (BOM badge/CSV, populated-qty exclusion, netlist `dnp`+`exclude_from_bom` on re-export). After import, every DNP part is counted populated in the BOM and re-exports as populate-me; syncing the imported design back to the source board would fight the board's own `(attr dnp)`.
  - Fix: emit `(dnp)` on the instance (the parser + downstream already support it); keep the comment for provenance.

- **[Medium] Netlist NC-pad inventory silently empty for bare-numeric pads (i.e. almost all of them)** — `src/export_kicad_netlist.zig:126` (also `src/convert/symbol.zig:165`)
  - `extractPadNames` reads a pad name with `asAtom() orelse asString()`, but project `.sexp` footprints write pad numbers as bare tokens (`(pad 1 smd …)` — see `convert/footprint.zig:170`, `import_kicad.zig:622`), which the tokenizer parses as `.int` nodes; both accessors return null and the pad is skipped. Result: `buildPadMap` yields empty pad lists for numerically-padded footprints, so the `(net (code "0") …)` unconnected section — the whole point of the pad map — no-ops except for alpha-padded parts (BGAs). `generatePackage` drops the same pads from package files. `ast.zig` already has the right helper (`tokenText`, line ~99).
  - Fix: use `tokenText(arena)` (or the `padName` buf pattern) in both call sites.

- **[Medium] Path traversal / zip-slip via the declared footprint name on export** — `src/export_kicad.zig:216,241` (file write), `src/export_kicad.zig:369,388` (zip entry names)
  - `kicad_name` is read from the *contents* of `lib/footprints/<x>.sexp` (`extractFootprintName`) and spliced into `"{s}/{s}.kicad_mod"` unchecked, then `createFile`d. A footprint declaring its name as `../../../home/user/x` writes outside `--output-dir`; the zip path embeds the same string as an archive entry name (zip-slip for whatever extracts it). Library files are semi-trusted, but `POST /api/upload-footprint` exists and `import-kicad` auto-generates these files from third-party boards.
  - Also worth noting: two distinct internal footprints declaring the same KiCad name silently overwrite each other's `.kicad_mod` in `footprints.pretty/` — the second part exports with the first part's geometry, with no warning.
  - Fix: reject/sanitize names containing `/`, `\`, or `..` at extraction time; warn on duplicate declared names.

- **[Medium] `swap_footprint` drops the board footprint's `(attr …)` forms** — `src/kicad_pcb/writer.zig:1254` (`preserve_keys`)
  - The swap preserves `at/uuid/layer/locked/tstamp` and every `(property …)`, but not `(attr …)`. If the user set `(attr dnp)` / `(attr exclude_from_bom)` / `(attr board_only)` in pcbnew, a footprint swap silently clears it (the replacement kmod from `.sexp`-generated footprints carries no `attr`). Assembly-relevant state loss on an otherwise placement-preserving operation.
  - Fix: add `"attr"` to `preserve_keys` (dedupe against an `attr` arriving from the kmod).

- **[Low] `insertPendingIds` rewrites the user's design source non-atomically** — `src/id_insert.zig:46-48`
  - The one code path in this area that mutates a *hand-authored* file (`src/<design>.sexp`, splicing minted `(id …)` forms on build) does truncate-then-write with no tmp→rename and no backup — a crash mid-write destroys the source file. Contrast the board writer's atomic path (`serve/sync.zig:1510`).
  - Fix: reuse the tmp-file + rename idiom (an `atomicFile` helper already exists in `serve/oauth_store.zig:286`).

- **[Low] `applyBomUuids` mismatches prefixed `.bom` keys in sub-blocks (latent — currently no callers)** — `src/bom.zig:254-262`
  - The recursion re-loads the same `.bom` per sub-block and matches by the child's *bare* `inst.ref_des`, but `.bom` entries for sub-block parts are hierarchical (`buck/C3`). Sub-block instances never match; worse, a top-level `C3` entry's uuid is applied to every same-named sub-block twin → duplicate canopy uuids if this path is ever wired up. Grep shows no callers today — either delete the pub fn or fix it to thread a prefix like `applyBom` (`bom_resolve.zig:212`) does.

- **[Low] `add`-op idempotency keyed on a possibly-empty uuid** — `src/kicad_pcb/writer.zig:311-314`
  - The first `add` with `uuid:""` registers `""` in `existing_canopy_uuids`; every subsequent uuid-less add in the batch (or on later pushes against the same board) is silently dropped. Ops normally carry uuids, but a malformed batch loses parts without any error. Guard with `if (target.len > 0)` around the dedup.

- **[Low] Deterministic-uuid collision tiebreak is renumber-sensitive; duplicate stable ids aren't rejected** — `src/bom_resolve.zig:117-121`
  - On a `used_uuids` hit (realistically only from two instances carrying the *same* `(id …)` token, e.g. copy-paste), the second part's uuid is re-derived from `"id/ref_des"` — but `ref_des` changes on renumber, so that part's board identity churns, defeating the whole renumber-proof-id design. A duplicate stable id is a source bug worth failing loudly on (mirroring `id_insert.zig`'s `IdCollision`), not silently tiebreaking.

- **[Low] Doc drift: fold-verification overclaim** — `CLAUDE.md` ("verify structural isomorphism", import-kicad section) vs `src/import_fold.zig:386`
  - Given the same-template blindness above, the fold's guarantee is "identical part/value/net-class multiset per channel", not full structural isomorphism. Either strengthen the signature (preferred, see High finding) or soften the claim so users know a dry-run sync against the original board is the actual verification step.


---

## Serve: HTTP core, auth/OAuth, MCP & VFS

**Overview / health.** The OAuth 2.0 store is well built: secrets/tokens are stored as SHA‑256 hashes only (`oauth_store.zig`), auth codes are single‑use with a 10‑min TTL and are actively swept, PKCE S256 is verified, and the persisted stores use atomic‑write‑with‑backup plus an empty‑list clobber guard. The VFS lexical path validation is solid against `..`, absolute paths, NUL/backslash, dotfiles, and a curated read/write allowlist with an auth/credentials deny‑list. The WebAuthn implementation verifies type, origin, challenge, and the P‑256 signature.

**Security posture summary — NOT good for an internet‑facing deployment.** The single biggest problem is that "am I localhost?" is decided from the client‑controlled `Host` header while the server binds `0.0.0.0`, so a remote attacker who sends `Host: localhost` obtains full unauthenticated admin. On top of that, the writer/admin role gate is enforced *only* on the MCP `tools/call` path — every HTTP mutation endpoint and the MCP WebSocket transport bypass it (the WS path defaults an empty email to admin). Design‑name inputs are inconsistently sanitized, and the read side of the VFS follows symlinks despite docs claiming otherwise. Auth‑state writes (sessions/credentials/users/invites/plugin tokens) are non‑atomic. Fix the Host‑trust bypass first; it makes every other control moot.

### Findings

- **[CRITICAL] `Host`-header "localhost" check is a total auth + role bypass** — `src/serve/auth.zig:581-593` (`isLocalhost`), `:723-725` (middleware short‑circuit), `:707-713` (`currentEmail` → `dev@localhost`); `src/serve/mcp.zig:47` (`resolveRole` → `.admin`); `src/serve/users.zig:172` (`dev@localhost` → admin); server binds all interfaces at `src/serve.zig:322`.
  - `isLocalhost` reads only the `Host` request header (`req.header("host")`), never the real peer/socket address. `authMiddleware` does `if (isLocalhost(req)) return true;` as its very first check, exempting the request from *all* auth. The MCP dispatcher and user store both promote localhost/`dev@localhost` to `admin`. Because `serve()` listens on `.all(port)` (0.0.0.0), any host that can reach port 7050 directly — and any request the reverse proxy forwards with a client‑supplied `Host` — can send `Host: localhost` (or `127.0.0.1`/`::1`) and get unauthenticated admin: full VFS write/delete, all MCP mutation tools, `/account`, invite minting, user deletion, KiCad sync.
  - Why it matters: complete remote compromise with a one‑line header. This is the top risk on a public server.
  - Fix: derive "local" from the actual TCP peer address (httpz exposes `req.address`), not the `Host` header; do not bind `0.0.0.0` if only the proxy should reach it; if a dev bypass is kept, gate it behind an explicit `--dev`/env flag, never a header.

- **[HIGH] MCP WebSocket transport escalates any bearer-token holder to admin** — `src/serve/mcp.zig:324-329` (`upgrade` resolves email from the session cookie only) and `:308-311` (`clientMessage`: `role = if (self.email.len > 0) getRole(...) else Role.admin`).
  - `authMiddleware` lets a remote `GET /mcp` through on a valid OAuth **bearer** token (`auth.zig:755-758`), but `upgrade()` never derives the email from that bearer token — it only checks the session cookie. A bearer‑authenticated client has no session cookie, so `email == ""`, and the per‑message role logic then defaults an empty email to `.admin`. Net effect: any valid OAuth token (including a `reader`‑role user's token) yields admin over the WebSocket transport. The "fall back to admin on the dev localhost path" comment is wrong — the code keys on empty email, not localhost.
  - Fix: resolve email from the bearer token in `upgrade()` (mirror `resolveRole`), and make the empty‑email fallback `.reader`, not `.admin`.

- **[HIGH] HTTP mutation endpoints do not enforce the writer/admin role** — role gating lives only at `src/serve/mcp.zig:120` (`isMutationTool` + `role.canWrite()`); no `getRole`/`canWrite` call exists in `edit.zig`, `api.zig`, `notes.zig`, or `sync.zig` (grep returns nothing). Routes registered at `src/serve.zig:382-471`.
  - `authMiddleware` only proves a *valid session exists*; it never checks the session's role. Every `/api/edit-value`, `/api/add-instance`, `/api/remove-instance`, `/api/rewire-pin`, `/api/set-dnp`, `/api/source` (save), `/api/notes/*`, `/api/library-delete/*`, `/api/sync-kicad-pcb/*`, and history restore is therefore usable by a `reader`‑role account — the exact operations the MCP layer forbids readers from doing. `createInviteApi` correctly checks `canAdmin` (`auth.zig:1722`), which shows the intended model that the edit endpoints skip.
  - Fix: add a shared "require writer" (and "require admin" for destructive/library ops) helper in the middleware or per handler, resolving role from the session/bearer email.

- **[MEDIUM] Inconsistent design-name sanitization → limited path traversal** — `src/paths.zig:44-67` (`designSiblingPath` interpolates `name` unchecked, falling back to `{project_dir}/src/{name}{ext}`); `src/serve/history.zig:50-87,133-153` (validates snapshot `id` but not `name`); `src/serve/mcp_tools.zig:~1636` (`run_checks` builds `"{s}/history/{s}/{s}/{s}.sexp"` with unchecked `name`). Only some HTTP handlers validate (e.g. `src/serve/api.zig:174`).
  - A `name` like `../../secret` resolves to `{project_dir}/src/../../secret.sexp`, so MCP read tools (`get_schematic`, `run_checks`, `list_instances`, `get_net`, `restore_version`, …) and the many unvalidated `:name` routes can read/evaluate arbitrary `.sexp` files (and, for history/restore, traverse into arbitrary directories) outside the project. The `.sexp` suffix and "must parse as a design" bounds the blast radius, but it still escapes the intended sandbox and is reachable by a reader/bearer client.
  - Fix: validate design names centrally (reject `/`, `\`, `..`, leading `.`, NUL) before any path construction — the same rule already applied ad hoc at `api.zig:174` and `mcp_tools.zig:1368`.

- **[MEDIUM] VFS read path follows symlinks, contradicting its own docs and the write path** — `src/serve/vfs.zig:411-471` (`readFile` calls `readFileAlloc` on the resolved path with no `statFile`/symlink check), `:683-774` (`listDir`) and `:785-846` (`glob`) likewise; module header `:1-8` and `:235` claim symlinks are rejected / "symlink‑escape check runs after open in readFile."
  - `checkAcl` operates on the *lexical* rel path, never the resolved realpath. A pre‑existing symlink such as `src/x -> ../auth/oauth_tokens.json` or `-> /etc/passwd` passes the allowlist (its lexical prefix is `src/`) and `readFile` follows it, escaping the deny‑list. `writeFile`/`editFile`/`deleteFile` all check `stat.kind == .sym_link`, but the read/list/glob paths do not. Exploitation needs a symlink planted out‑of‑band (the VFS can't create one), so this is defense‑in‑depth — but the doc actively claims a check that isn't there.
  - Fix: `statFile` (or `lstat`) and reject `sym_link` in `readFile`/`listDir`/`glob`, or realpath‑canonicalize and re‑check the prefix; fix the misleading comments.

- **[MEDIUM] WebAuthn challenge is one process-global slot** — `src/serve/auth.zig:207-222` (`pending_challenge: ?[32]u8`, `storePendingChallenge`/`takePendingChallenge`).
  - Registration and login share a single global challenge with no binding to a session, user, or ceremony. Two concurrent ceremonies clobber each other (last writer wins), so under any concurrency legitimate logins intermittently fail "challenge mismatch," and the challenge/response can't be correlated to who requested it. It's a robustness/availability defect (and weakens the anti‑replay story) rather than a direct bypass, since the signature must still verify.
  - Fix: store challenges keyed to a short‑lived per‑attempt id (cookie or returned handle) with a TTL, not a single global.

- **[MEDIUM] Long-lived session and OAuth-token stores grow unbounded** — sessions: `src/serve/auth.zig:180-192` evicts an expired entry only when that exact token is looked up again (abandoned sessions never do), and every login appends; OAuth tokens: `src/serve/oauth_store.zig:546-571` (`issueToken` appends, no sweep) and `:576-599` (`validateToken` skips but never removes expired). Only a process restart re‑filters (`loadTokens :217-218`). There is also no inbound rate limiting on `/oauth/token`, `/auth/login/*`, or `/auth/register/*` (`rate_limiter.zig` throttles only outbound CSE/DigiKey calls).
  - Why it matters: the in‑memory `sessions` map and `tokens_list` accumulate expired rows for the life of the process; the auth codes map is the only store that self‑sweeps. Slow but real memory growth of server state, plus unthrottled credential/token endpoints.
  - Fix: sweep expired sessions/tokens on write (mirror `sweepExpiredCodes`); add a simple per‑IP throttle to the auth/token endpoints.

- **[MEDIUM] Auth-state files are written non-atomically with no backup** — `src/serve/auth.zig:151-153` (`persistSessions`), `:277-279` (`saveCredentials`), `:326-328` (`saveInvites`); `src/serve/users.zig:95-106` (`saveUsers`); `src/serve/plugin_tokens.zig:64-79` (`save`). All use `createFile(..., .{})` (truncate) then `writeAll`.
  - A crash or short write between truncate and completion leaves a truncated/empty file. For `credentials.json` that means every passkey is lost → full lockout with no recovery point. `oauth_store.zig` already solves this with `writeFileAtomicWithBackup` (tmp+rename+`.bak`) and an empty‑list guard; the passkey/session/user/invite stores should reuse it.
  - Fix: route these saves through the same atomic‑write‑with‑backup helper.

- **[LOW] OAuth `state` is reflected into the redirect Location unencoded** — `src/serve/oauth.zig:228-231` (`"{s}{s}code={s}&state={s}"`).
  - `state` comes from the form and isn't URL‑encoded, so it can inject extra query fragments into the redirect. The redirect host/path is constrained to the registered or a loopback URI (`redirectUriMatches`), so this is parameter smuggling within an approved target, not an open redirect. Percent‑encode `state` (and `code`) anyway.

- **[LOW] Login challenge leaks all credential IDs when no `email` filter is supplied** — `src/serve/auth.zig:1259-1266`. The unauthenticated `/auth/login/challenge` returns every stored credential id when `?email=` is absent (needed for resident‑key flows), enabling enumeration of how many passkeys/users exist. Consider requiring the email filter or returning an empty `allowCredentials` for discoverable‑credential logins.

- **[LOW] Secret/token/PKCE/challenge comparisons use non-constant-time `mem.eql`** — `src/serve/oauth_store.zig:372` (client secret hash), `:585` (token hash), `:625` (PKCE), `plugin_tokens.zig:111` (plugin token hash), `auth.zig:1002/1413` (challenge). All compare SHA‑256/base64 digests, so an attacker can't grind byte‑by‑byte against a chosen hash (they control the preimage, not the digest), making practical exploitation unlikely — but constant‑time compare (`std.crypto.timing_safe.eql`) is the norm for auth material and cheap to adopt.

- **[LOW] Maintainability / doc-drift hazards** — `src/serve/mcp_tools.zig` (2720 lines), `src/serve/auth.zig` (1781, includes a hand‑rolled CBOR decoder, DER parser, and WebAuthn verifier — a large security‑critical surface with per‑field response duplication), `src/serve/vfs.zig` (1238). The vfs header comment and `:235` describe a symlink check that `readFile` doesn't perform (see above). These files are big enough that a subtle auth regression is easy to miss; the WebAuthn/CBOR code in particular warrants extraction + focused fuzzing.


---

## Serve: PCB layout page & KiCad sync

_Scope: `src/serve/{pcb_layout_page,sync,pcb_describe,layout_match,design_diff,schematic_page,editor_page}.zig`._

**Overall health: solid on the parts that matter most.** The file-based KiCad-sync write path is genuinely defensive: it runs a footprint-by-footprint placement guard (uuid-keyed compare of old vs. new board) *before* the write and aborts with HTTP 409 on any move/rotate/side-flip; it writes atomically (tmp → fsync → rename over the original, which is left untouched until the rename) and rolls a timestamped backup before overwriting; `runSyncPlan` is deterministic so dry-run and real-write see the same op list; all handlers here run on the request arena (no page-allocator leaks), and non-localhost access is auth-gated (bearer/session/plugin token). `design_diff.zig` is clean, keyed on stable flattened refs, with a real path-traversal guard on snapshot ids.

The soft spots are (1) **injection**: every string in the big `<script>const PCB=…</script>` blob (and the editor's `window.SCENE`) goes through `writeJsonStr`, which is a correct *JSON-string* escaper but does **not** neutralise `</script>` for the HTML `<script>` context, and the `/editor/:name` error page reflects `name` into raw HTML with no escaping at all; (2) **layout-sidecar writes** are non-atomic and happen on GET with no locking, so `.layouts.json` can be corrupted/lost under concurrency; (3) a handful of narrower sync-integrity edges (sub-second backup collision, shared `.tmp` on concurrent same-board sync, the parent+value migration relink rewiring pads to wrong nets). Board corruption from a routine write is well-guarded; the residual risks are concurrency/injection, not the happy path.

### Findings

- **[High] `writeJsonStr` doesn't escape `</script>` — stored/self XSS in the PCB data blob and editor scene** — `src/serve/pcb_layout_page.zig:3828` (`writeJsonStr`), used at `:3478` (`const PCB=`), `:3721` (`writeLayoutsJson`); `src/serve/editor_page.zig:131` (`window.SCENE=`).
  - `writeJsonStr` escapes `"`, `\`, control chars, but not `<`, `/`, U+2028/2029. Its output is emitted verbatim *inside* a `<script>` element, so any design/net/ref/value/footprint or saved-layout **name** containing `</script>` closes the script tag and injects markup. Layout names are the most exposed vector: `saveNamedLayoutApi` (`:1404`) accepts any `nm` with `0 < len ≤ 80` and no content check, persists it to `.layouts.json`, and it is later echoed into the `<script>` blob via `writeLayoutsJson`. Net/ref/value text from the design flows the same way. `window.SCENE=` in `editor_page.zig` embeds `render_json` output into `<script>` identically.
  - Why it matters: the server is internet-facing (`co-circuit.eugenepentland.dev`). Even auth-gated, a persisted `</script><script>…` layout name executes on every subsequent `/pcb-layout` load for the account owner. The visible panel path (`writeLayoutsPanel`) *does* use `writeEscaped`/`writeAttr`, so the gap is specifically the script-context serializer.
  - Fix: in `writeJsonStr` emit `<` as `<` (or replace `</` → `<\/`), and add U+2028/U+2029 escaping; that single change closes every `<script>`-context site since they all route through it.

- **[Medium] Reflected XSS: `/editor/:name` error page interpolates `name` into raw HTML** — `src/serve/editor_page.zig:86`.
  - When `sceneFor` fails (any unknown/bogus name — trivially triggered), the handler returns `allocPrint("<h1>Could not load {s}</h1><p>{s}</p>", .{ name, err })` with `name` un-escaped. `:name` is a single URL segment but may contain `<`, `"`, etc. after percent-decoding, so `/editor/%3Cscript%3E…` reflects an executable payload. The success path's `window.DESIGN="{s}"` (`:129`) trusts the "basename is safe" comment, which only holds because eval succeeded first — the *error* path has no such guarantee.
  - Why it matters: reflected XSS on an authenticated single-user surface — a crafted link the owner clicks runs script in the app origin.
  - Fix: HTML-escape `name` (and `err`) in the error body; treat the `:name` param as untrusted everywhere it reaches HTML.

- **[Medium] `.layouts.json` writes are non-atomic and occur on GET without locking — corruption / silent data loss** — `src/serve/pcb_layout_page.zig:1701` (`writeFileAll` = `createFile(truncate) + writeAll`, no tmp/rename), invoked from `writeLayouts`/`writeLayoutsSub`/`writeAutoCache`/`recordAutoLayout`, and notably from `displayLayouts` (`:2262`) which rewrites the sidecar during `pcbLayoutPage` rendering.
  - Every page load can persist a dedup rewrite, and `writeAutoCache`/`recordAutoLayout` persist on any generated solve — all through a truncate-then-write with no atomic rename and no mutex. Two concurrent requests for the same design (a page load racing a Save POST, or two solves) interleave a truncate against another writer's read-modify-write; a failed/partial write leaves a truncated file. Because `parseLayouts` treats any parse failure as "no layouts" (`readLayoutsSub` → empty slice), corruption silently discards every saved/starred layout — which the KiCad sync then also loses as its seed (`chooseSyncPoses`).
  - Fix: write the sidecar via tmp-file + rename (as `sync.writeFileAtomic` already does for the board), and serialize sidecar mutations per-design; avoid the write-side-effect inside the GET render (`displayLayouts` persisting dedups).

- **[Medium] Sub-second backup filename collision clobbers the only safety-net backup** — `src/serve/sync.zig:1526-1535` + `formatBackupStamp` (`:1350`).
  - The backup name is `backups/<board>.bak-<YYYY-MM-DDTHH-MM-SS>` at 1-second resolution, written with `copyFile` (overwrites the destination). Two pushes within the same second produce the *same* filename, so the second push's `copyFile` overwrites the first backup — and the second push's pre-state is the first push's post-state, so the pre-first-push board is lost. The code comment claims "a quick second push can't clobber the only good backup," which is false below 1 s spacing (e.g. the UI dry-run+confirm, or a double-click).
  - Fix: add sub-second precision or a monotonic suffix to the stamp, or refuse to overwrite an existing backup name (append `-2`, etc.).

- **[Medium] Concurrent same-board sync shares a fixed `.tmp` path with no sync-level lock** — `src/serve/sync.zig:1537-1550` (`tmp_path = "{path}.tmp"`); no mutex around `runKicadPcbSync`.
  - `writeFileAtomic` always uses `<board>.tmp`. Nothing serializes two `/api/sync-kicad-pcb/:name` requests for the same board. If two real writes overlap, both create/truncate the same `.tmp`; writer B truncating mid-write of A, then A renaming, can publish a partially-written board. The per-request placement guard doesn't help here — each request computed against a consistent `src`, but the shared tmp file is the corruption point.
  - Fix: make the tmp name unique (pid/random suffix) and/or take a per-board mutex (or advisory lock file) around read→guard→write.

- **[Medium] `(parent_path, value)` migration relink can rewire pads to the wrong nets (guard only checks position)** — `src/serve/sync.zig:2349` (`buildMigrationIndex`), consumed at `:2131` (`heuristicMatch`); default-on for the file path (`migrate = !no_migrate`, `:1050`).
  - Migration deliberately omits footprint and keys only on `(parent_path, value)`; when counts match on both sides it pairs board↔design by sorted ref-des. Two same-parent, same-value parts wired to *different* nets (common: two `10k` pulls in one section) can be paired in the wrong order. Since the adopted board fp then receives the design instance's pad nets via `emitPadNetOps`, the pads get renamed to nets that don't match the copper already routed to that physical part. The placement guard (`placementViolations`) compares only position/rotation/side, **not** net assignment, so a wrong-net rewrite passes the guard and lands.
  - Fix: include a wiring/footprint discriminator in the migration key, or refuse the pair when the paired board fp's existing net signature disagrees with the design instance's; at minimum surface migration relinks in the preview so the user can veto.

- **[Medium] Sync writes the board even when pcbnew holds it open (lock is advisory only)** — `src/serve/sync.zig:1163` (`pcbnewLockMessage`) + `:1226` (warning only, write still happens).
  - `~<board>.lck` is detected and reported but the write proceeds; a concurrent pcbnew save then overwrites (or is overwritten by) the sync, corrupting the board. This is documented/by-design ("per the user's choice") and CLAUDE.md warns about it, but it remains a real data-loss path with only a soft warning.
  - Fix: consider a `?force=1` gate so the default refuses to write over a live lock; keep the current behaviour behind the opt-in.

- **[Low] `(kicad-pcb "<path>")` target is an unvalidated absolute write path** — `src/serve/sync.zig:1107-1111`, `:1187`.
  - The board path comes from the design's `(kicad-pcb …)` form and is used to read and to write in place (plus creating `backups/`, `<design>-source/`, `models/` beside it). There's no check that it ends in `.kicad_pcb` or stays within an expected root. An authenticated user who can edit a design (VFS write endpoints) could point it at an arbitrary absolute path and have the server overwrite that file with KiCad-format text. Absolute NAS paths are intentional, so this is auth-gated and partly by-design, but the missing extension/location sanity check widens blast radius (accidental or malicious).
  - Fix: validate the target extension and optionally constrain to a configured board root / require the file to already exist.

- **[Low] Placement guard degrades to a no-op when the new board fails to parse** — `src/serve/sync.zig:1422-1424` (`collectPlacements` returns an empty map on parse error), `:1471-1508` (`placementViolations` iterates the old map; empty new map → every part `continue`s → returns null).
  - The guard's contract is "never move an existing part," but if `new_pcb` is malformed enough that the parser bails, `collectPlacements(new)` is empty, so no old part is found on the new side and the guard reports zero violations — i.e. a scrambled board would pass. `new_pcb` is writer-generated so this is unlikely in practice, but the guard silently trusts its own parse.
  - Fix: if `collectPlacements(new)` yields far fewer footprints than the old board (or fails to parse), treat that as a guard failure rather than a pass.

- **[Low] `extractOpsArrayJson` re-parses the envelope by string slicing** — `src/serve/sync.zig:1314`.
  - It finds `"ops":`, expects `[`, and slices to the last `}` in the whole envelope. It works for the current fixed shape (ops array last, single trailing `}`), but it's brittle: any future field emitted after `ops`, or an op string value containing an unbalanced `}`/`]`, breaks it silently. The value already exists structured in `runSyncPlan`; round-tripping it through string search is a maintenance hazard.
  - Fix: have `runSyncPlan` return the ops-array text separately instead of re-extracting it from the serialized envelope.

- **[Low] Fixed stack buffers silently drop long ref/net names in describe** — `src/serve/pcb_describe.zig:620` (`netOf`, `[128]u8`), `:309` (`groundish`, `[32]u8`).
  - `bufPrint`/`upperString` into fixed buffers return null/false for over-long inputs, so a ref+pad key >128 chars drops the net from the facts and a leaf name >32 chars is never treated as ground. Not a crash, but the facts JSON silently disagrees with the rendered board for deeply-nested hierarchical refs.
  - Fix: size from the actual input or use an allocating format.

- **[Low] Doc drift: backups live in a `backups/` subdir, not `<board>.bak-<stamp>` siblings** — `src/serve/sync.zig:1332` (`BACKUP_DIR_NAME`) vs. `CLAUDE.md:594` ("every write rolls a timestamped `<board>.bak-<stamp>`").
  - The code moved backups into `<board_dir>/backups/<name>.bak-<stamp>`; CLAUDE.md still describes sibling `.bak-*` files. Minor, but the sync doc is otherwise authoritative and this is the file users go hunting in after a bad push.

- **[Low] Mega-files / single-giant-writer maintainability** — `src/serve/pcb_layout_page.zig` (4277 lines; `writePcbData` `:3447` emits the entire `const PCB` blob in one function) and `src/serve/sync.zig` (4226 lines; `runSyncPlan`/`handleMatched`/`emitStagedAdds` carry deep responsibility).
  - Both files mix HTTP handling, JSON serialization, layout-sidecar persistence, and (in sync) proto-JSON footprint emission. The proto-JSON pad/geometry emitters in `sync.zig` (`writePadProtoJson` et al.) serve only the retired Go IPC agent per the module docstrings yet remain compiled and maintained. Not a bug, but the surface area amplifies the concurrency/injection risks above.
  - Fix: split the layout-persistence layer (`.layouts.json` read/write/dedup) out of `pcb_layout_page.zig`; consider dropping the dead proto-JSON emitters if no live client consumes them.


---

## Serve: library, components, editing & uploads

**Overview / health.** This slice is mostly careful: the surgical `.sexp` edit
endpoints (`edit.zig`) validate byte-offset splices with a comment/string-aware
`findFormEnd`, escape s-expr strings on write, snapshot before each mutation, and
re-parse before persisting; the JSON/introspection paths (`component_info.zig`,
`component_search.zig`, `digikey.zig`, `footprint_preview.zig`) route every
user/vendor string through `json_writer.writeString`; the HTML template layer
(`library.zt`/`account.zt`/`pdf_viewer.zt` + `diag_format`/`modules` source view)
auto-escapes via `zt.writeEscaped`/`writeAttr`/`writeHtmlEscaped`; and the
`datasheet_attach` + `edit.zig` datasheet cores DO enforce the "traversal-safe"
claim (`safeLibName`/`safePdfName` reject `..`,`/`,`\`,`"` and whitelist the PDF
name). CSE/DigiKey shell out through `std.process.Child.run` with an argv array
(no shell) and percent-encode the query, so there is no command injection.

**Security-posture note on uploads/attach.** The posture breaks in two places
that bypass the otherwise-consistent name-safety discipline:
(1) the KiCad-zip/model upload path trusts the raw `X-Filename` header as a
`/tmp` filename, giving an **arbitrary file write** (RCE-capable); and (2) the
`/api/module-source` "copy source" reader confines only `..`/leading-`/` and
happily serves any project-relative file, including `auth/sessions.json` (raw
live session tokens). Both are reachable by **any** authenticated user — auth is
a single session/bearer gate with **no per-route role check**, so a `reader`-role
account can drive every mutation and both of these. Everything off-`localhost`
requires a session (`auth.authMiddleware`), which is the only thing keeping these
off the open internet.

### Findings

- **[CRITICAL] Arbitrary file write via `X-Filename` header (path traversal in temp-file name)** — `upload.zig:92` (+ `upload.zig:213`, callers `upload.zig:259`, `library.zig:332`)
  - `importZipBytes`/`extractStepBytes` build the temp path as `TMP_ZIP_TEMPLATE = "/" ++ "tmp" ++ "/eda-upload-{s}"` filled with `filename`, then `createFile(tmp_zip).writeAll(zip_bytes)`. `uploadZipApi` passes `req.header("x-filename")` straight in (`upload.zig:259`); `uploadModelApi` likewise passes the raw `x-filename` to `extractStepBytes` (`library.zig:332`, 339). The header is never sanitized — the doc comment at `upload.zig:83-85` *asserts* "filename … must be path-safe" but nothing enforces it.
  - `X-Filename: ../../../etc/cron.d/evil` resolves `"/tmp/eda-upload-" ++ "../../../etc/cron.d/evil"` to `/etc/cron.d/evil` (first `..` cancels the glued `eda-upload-..` component, the next two climb out of `/tmp`), and the file content is the fully attacker-controlled request body. The service runs as a systemd `--user` unit, so an attacker can write `~/.ssh/authorized_keys`, `~/.bashrc`, `~/.config/systemd/user/*.service`, etc. → remote code execution. Reachable by any authenticated user (incl. `reader` role).
  - Fix: sanitize `filename` to a single path-safe basename before templating (reuse `library.isSafeLibName` / `sanitizeFilename`), or ignore the header entirely and mint the temp name from a random/timestamp token (as `TMP_EXTRACT_TEMPLATE` already does).

- **[CRITICAL] `/api/module-source` reads arbitrary project files → session-token theft** — `modules.zig:105` (`resolveSourcePath`), handler `modules.zig:138`
  - `resolveSourcePath` only rejects a leading `/` and `..` (`sourceIsSafe`, `modules.zig:93`), then treats any `src` containing `/` or ending `.sexp` as a project-relative path `"{project_dir}/{src}"` and returns its contents as `text/plain`. `?src=auth/sessions.json` passes every check (has `/`, no `..`, no leading `/`).
  - `auth/sessions.json` stores the **raw** session token per user (`auth.zig:147` writes `{"token":"<hex>",…}`, and `validateSession` looks tokens up directly — `auth.zig:180-184`), so any authenticated user (including a `reader`) can read every live admin/user session token and impersonate them. `auth/invites.json` (raw invite tokens → self-provision accounts), `oauth_tokens.json`/`oauth_clients.json` are equally exposed. This is full account/privilege escalation, gated only by having any session.
  - Fix: confine reads to the intended roots — resolve `src` only as a bare module/component name (no embedded `/`, `.sexp`-suffix optional) under `lib/modules/` + `lib/components/`, or canonicalize and assert the result stays under `{project_dir}/lib/`.

- **[HIGH] Stored XSS in the schematic BOM card (component/value/MPN/manufacturer/property + datasheet href)** — `bom_html.zig:207-249`
  - `writeSchematicBomHtml` interpolates untrusted strings with raw `{s}` into HTML: component (`:207`), value (`:208`), footprint (`:209`), attrs (`:215`), the MPN `<input value="{s}">` (`:227`), manufacturer `<input value="{s}">` (`:236`), free property `key: value` badges (`:249`), and the datasheet `<a href="{s}">` (`:247`). None are HTML-escaped (this function pointedly "emits no embedded JS" but still emits unescaped attributes/text).
  - MPN and manufacturer are directly attacker-writable through `edit.zig` `editMpnApi`/`editMpnCore` (`edit.zig:2291`, 2312) into the `.bom` sidecar with no validation/escaping, and component/value come from the design `.sexp`; a value like `"><img src=x onerror=…>` (or a `javascript:`/`data:` datasheet URL) is stored and then rendered into the always-visible BOM card on every `/schematics/:name` load → stored XSS running in an authenticated session (session-cookie theft, self-propagating). Contrast the neighboring `library.zt`/`component_info.zig` which escape consistently.
  - Fix: route every dynamic cell through an HTML-escaping writer (the module already imports `json_writer`; add/reuse an `htmlEscape`), and scheme-check the datasheet href (allow only `/datasheets/…` or `http(s):`).

- **[HIGH] Reflected XSS in the 3D-viewer page via the `:footprint` path param** — `library_3d.zig:89` and `library_3d.zig:95`
  - `viewerPage` percent-decodes the `:footprint` param (`library_3d.zig:76`) and prints it raw into HTML: `"<title>3D — {s}</title>"` and `"<span id=\"fp-name\">{s}</span>"`. httpz hands params back still-encoded (see the `urlDecode` rationale at `library.zig:298-304`), so `/library/3d/%3Cscript%3E…%3C%2Fscript%3E` decodes inside the handler to `<script>…` and injects it. Reflected XSS in an authenticated session (an attacker sends a logged-in user a crafted link).
  - Fix: HTML-escape `footprint` before embedding (the codebase already has `modules.writeHtmlEscaped`/`diag_format.writeHtmlEscaped`), and/or validate it with `library.isSafeLibName` up front.

- **[HIGH] Path traversal — arbitrary `.sexp`/model read in the 3D-viewer & footprint handlers** — `library_3d.zig:167` (`writePadsAndCourtyard`), also `library_3d.zig:57` (`modelFileApi`)
  - The read handlers in `library_3d.zig` decode `:footprint` (`urlDecode`, `library_3d.zig:55`,76,348) but never pass it through `isSafeLibName`, then interpolate it into `"{s}/lib/footprints/{s}.sexp"` (`:167`) and the model path (`:57`). Because params arrive percent-encoded, `?…/%2e%2e%2f%2e%2e%2f…` decodes to `../../…` after routing, so `writePadsAndCourtyard` reads any `.sexp` on the filesystem (and `resolveModelName`/`modelFileApi` any resolvable model). The sibling *write* endpoints in the same feature (`library.uploadModelApi:330`, `deleteLibraryEntryApi:378`, `saveTransformApi`) DO call `isSafeLibName`, so this is an inconsistency, not a missing convention. (`footprint_preview.footprintApi:72` uses the *undecoded* param, so a literal `..` alone can't escape one dir there — lower risk, but it still should validate.)
  - Fix: `if (!library.isSafeLibName(footprint)) return notFound(res);` in `modelFileApi`, `viewerPage`, `saveTransformApi`, and `footprintApi`/`boardFootprintApi`.

- **[MEDIUM] Remote crash / UB from JSON union misuse (`.object` on a non-object body)** — `notes.zig:320`, `notes.zig:360`, `notes.zig:403`, `edit.zig:2948`, `edit_assist.zig:68`, `edit_assist.zig:400`
  - These handlers do `parsed.value.object.get(...)` without first checking `parsed.value == .object`. A *valid* JSON body that isn't an object (`5`, `"x"`, `[]`) makes `.object` access the wrong union field. Prod builds with `-Doptimize=ReleaseSmall` (safety off, per CLAUDE.md), so this is undefined behavior → likely worker segfault; even in a safe build it panics the request. Remotely triggerable DoS for any authenticated user. `account_page.zig` guards this correctly (`if (parsed.value != .object)` at `:79`,160,213) — the notes/source/validate/layout endpoints do not.
  - Fix: add the `!= .object` guard (or use a typed parse) in each handler before `.object.get`.

- **[MEDIUM] No write-role enforcement on any mutation endpoint** — cross-cutting (`auth.authMiddleware` at `serve.zig:254`; affects `upload*.zig`, `edit.zig`, `notes.zig`, `library.deleteLibraryEntryApi`, `datasheet_attach.zig`, `library_3d.saveTransformApi`)
  - `authMiddleware` returns "allowed" for any valid session/bearer regardless of role (`auth.zig:769-771`); only `account_page.zig` re-checks `canAdmin()`. Roles (`admin`/`writer`/`reader`) exist and are surfaced on `/account`, but the edit/upload/delete/notes endpoints in this area never consult `users.getRole`, so a `reader` can rewrite designs, upload library files, delete library entries, and (combined with the two Criticals above) write arbitrary files / read session tokens.
  - Fix: gate mutating routes on a `writer`+ role (a `requireWriter` mirroring `account_page.requireAdmin`), applied in the middleware by method/path or at each handler head.

- **[MEDIUM] Unsynchronized read-modify-write races on the design `.sexp`** — `edit.zig:155`, `edit.zig:2207` (`writeAndRebuild`), and every sibling edit handler; `notes.zig:228` (`writeNotesFile`)
  - Each edit reads the whole `.sexp`, splices in memory, and `createFile`+`writeAll`s it back, with no per-file lock. httpz serves on multiple worker threads, so two concurrent edits to the same design (or an edit racing the KiCad-sync writer) interleave as last-writer-wins and silently drop one edit; a partial write is also observable by a concurrent reader. The notes structured-mutation path (`addTaskCore`/`mutateTaskCore`) has the same load→render→overwrite window.
  - Fix: serialize per-design mutations behind a mutex/file-lock (keyed by resolved path), or write-temp-then-rename with a compare check.

- **[LOW] Provider secrets exposed on the curl command line** — `digikey.zig:182-183` (+ `:191`), `component_search.zig:444`
  - `fetchToken` passes `client_id=<id>` / `client_secret=<secret>` as `--data-urlencode` argv, and CSE `httpGet` passes `-b connect.sid=<cookie>` — both land in the child process's argv, visible to any local user via `ps`/`/proc/<pid>/cmdline` while the request is in flight. Single-tenant host limits the blast radius, but prefer `--data-urlencode name@file` / `-H @file` / stdin (`--config -`) so secrets don't hit argv.

- **[LOW] Redirect-following outbound fetch of vendor-supplied URLs (bounded SSRF / curl arg-injection)** — `component_search.zig:140`,417, `digikey.zig:491`
  - Datasheet/model downloads run `curl -L …` against a URL taken from the CSE/DigiKey JSON response (`part.datasheet_url`, model download URL), following redirects with no host allowlist and no `--proto`/`--` guard. The URL is vendor-controlled (not directly user-supplied) and PDF/ZIP magic is validated, so impact is limited, but a hostile/compromised vendor response could point at an internal address, and a `-`-leading URL could be reparsed as a curl option. Add `--` before the URL and consider `--proto '=https'` + a redirect/host allowlist.


---

# Audit: Build, CLI, infra, docs & project hygiene

## Build, CLI, infra, docs & project hygiene

_Overview:_ The infrastructure layer is in good shape overall. The infra ports (`clock`/`fs`/`log`/`random`) are correct thin boundary markers matching the Guardian ban checks; `json_writer.zig` escapes correctly; the docgen pipeline is genuinely drift-proof (build-level `--check` with pinned cwd at `build.zig:151-156`, byte-compare in `src/main.zig:175-200`, plus the unit drift test in `src/docgen.zig:274`). Secrets hygiene is fundamentally sound: `.env` is gitignored (`.gitignore:31`), never appears in git history, `.env.example` is placeholder-only, the nested `projects/designs` repo gitignores `/auth/` (its `.gitignore` line 3), and generated template `.zig` files are ignored (`src/serve/templates/.gitignore`). No committed secret found.

The real problems are (a) CLI behavior that contradicts its own documentation — `netlisp build` can never print to stdout and always attempts a network push, and `netlisp check`'s exit code ignores ERC results despite CLAUDE.md twice calling it a hard gate — and (b) substantial doc drift in CLAUDE.md/README/docs following the placement-form and Go-agent removals, which matters more than usual here because CLAUDE.md is the operative instruction file for agents driving this codebase.

### Findings

- **[High] `netlisp build <design>` always pushes to a server; the documented stdout mode is unreachable dead code** — `src/commands.zig:181`, `src/commands.zig:287-304`
  - Line 181 promotes any positional design name into `push_name` (`if (push_name == null and positional_name != null) push_name = positional_name;`). Since `design = push_name orelse <usage-exit>` (line 183), `push_name` is *always* non-null past that point, so the `if (push_name) |name|` branch at line 287 always fires and the stdout branch guarded by `push_name == null and output_dir == null` (line 300) can never execute.
  - Consequences: `netlisp build --project-dir d mydesign` (no `--push`) shells out to curl against `http://localhost:7050` and **exits 1 with "Push failed"** when no server is running — even when `--output-dir` already succeeded (lines 268-285 write the file, then line 293 fails the run). This contradicts the function's own doc comment (`commands.zig:149-152`: "either prints the resolved design to stdout, writes it to `--output-dir`, or pushes it… via `--push`"), the usage string (`commands.zig:184`: `[--push] <design-name>`), and CLAUDE.md:26 ("Build a design (stdout), --push sends to running server").
  - Fix: only set `push_name` from the positional when the user actually passed `--push` as a bare flag, or introduce a separate `design` variable; make push failure after a successful `--output-dir` write non-fatal or clearly ordered.

- **[High] `netlisp check` always exits 0; `netlisp build` never runs ERC — contradicting CLAUDE.md's "hard gate" claims** — `src/commands.zig:93-147`, `src/commands.zig:156-307`, `CLAUDE.md:355`, `CLAUDE.md:405`
  - `cmdCheck` prints violations and returns; there is no `std.process.exit(1)` when error-severity violations exist (only usage/eval errors exit non-zero at lines 111/121). `cmdBuild` imports `erc_mod` but never calls it — only `(assert …)` failures gate the build (lines 232-247). CLAUDE.md states twice that the `decoupling_unbound` and `strap_tied_to_rail` ERC checks "fail `netlisp build` / `netlisp check`" — neither is true of the CLI. Any CI/agent gating on `netlisp check`'s exit code silently passes broken designs.
  - Fix: exit non-zero from `cmdCheck` when any `error`-severity violation survives the filter (and either run ERC in `cmdBuild` or correct CLAUDE.md's claim to name the surfaces that do gate).

- **[High] CLAUDE.md documents removed DSL forms, a removed endpoint, and denies MCP tools that exist** — `CLAUDE.md:303-305`, `CLAUDE.md:332`, `CLAUDE.md:479-481`, `CLAUDE.md:583-586`, `CLAUDE.md:676`
  - The `(placement …)`/`(floorplan …)`/`(placement-order …)` forms were deleted (no matches anywhere in `src/eval/`; confirmed removal per the sweep merged as `1fee057`), yet CLAUDE.md still: describes `POST /api/spec-save/<m>` "splicing a `(placement …)` form" (:303-305 — the route does not exist; only a stale doc-comment reference survives at `src/serve/edit_assist.zig:379`), calls `(decouples …)` "the per-instance twin of a `(placement-order … (near …))`" (:332), claims "`(layout …)` is the legacy alias — both parse" (:479) when `src/eval/forms.zig:560-563` has a test explicitly proving the `layout` alias is retired, and describes `?names=origin` defaults / `SPEC: ALL PLACED` headers / "`source (placement …) spec >` saved snapshot" precedence driven by placement specs (:583, :584, :586).
  - Separately, CLAUDE.md:676 asserts "There is no 'requirements' concept; this MCP server only models S-expression schematic capture" — but `src/serve/mcp_tools.zig:140-151` registers `list/add/remove_component_requirement` plus five `*_design_note` tools, and the sourcing tools (`search_components`, `resolve_mpn`, `check_stock`, `download_footprint`, `download_datasheet`, `read_datasheet` at :122-151) are absent from CLAUDE.md's tool inventory.
  - Why it matters: CLAUDE.md is the instruction set agents act on; it will cause authored `(placement …)` blocks the evaluator now lint-warns on, and denials of tools the server actually offers.
  - Fix: sweep the "mixed stale placement prose" (already flagged in project memory) and regenerate the MCP tool list from `tool_registry`.

- **[Medium] Guardian dependency is an unpinned relative-path dep; fresh clone cannot build; README quick start doubly broken** — `build.zig.zon:39-41`, `README.md:12-18`, `README.md:20`
  - `.guardian = .{ .path = "../guardian-zig" }` requires an unversioned sibling checkout outside the repo — no URL, no hash, no pinning, so builds are neither reproducible nor portable, and since Guardian gates *every* `zig build` (`build.zig:136-137`), a clone without the sibling fails immediately. README's quick start (`zig build` then `serve --project-dir projects/designs`) fails twice more: `projects/` is gitignored (`.gitignore:15`), so the directory is empty on a fresh clone, and neither prerequisite is mentioned. Also `build.zig.zon:47-54` `.paths` omits `docs/` and `guardian.toml`, so a fetched package would fail its own docs `--check` step.
  - Fix: pin guardian to a git URL+hash (or make it optional via `b.lazyDependency`/an env escape hatch), and document the sibling-checkout + designs-repo prerequisites in README.

- **[Medium] `paths.zig` unit tests never run — the file is missing from the root test block; CLI arg parsing has zero tests** — `src/main.zig:391-471`, `src/paths.zig:100-114`
  - Zig only collects tests from files referenced in a `test { _ = @import(…) }` chain. The root test block imports `config.zig`, `json_writer.zig`, `docgen.zig`, etc., but not `paths.zig` — its two tests (flat-fallback resolution) compile-check nowhere and never execute. Likewise `commands.zig` and `main.zig` have no tests at all: the always-push bug and the exit-code gap above are exactly the class of regression that arg-parsing tests would catch, and every `cmd*` handler exits the process on error paths, making them untestable as written.
  - Fix: add `_ = @import("paths.zig");` to the root test block; extract arg parsing in `commands.zig` into pure `parseBuildArgs`-style functions returning structs/errors and test those.

- **[Medium] `serve --port` silently falls back to 7050 on unparseable input** — `src/main.zig:140-143`
  - `std.fmt.parseInt(u16, p, 10) catch DEFAULT_SERVE_PORT` — a typo (`--port 70500`, `--port 8o80`) starts the server on the production default port 7050 with no diagnostic. Given prod runs on 7050 and worktree dev servers are expected on other ports (per project memory, a worktree accidentally serving on 7050 collides with prod), this silent fallback is an operational footgun.
  - Fix: print an error and exit 1 on unparseable port. Same pattern (silent `catch <default>`) exists throughout `src/bench_layout.zig:321,341-363` — acceptable for a bench tool, but `--reps abc` silently becoming 5 can invalidate a measurement protocol; a diagnostic line would cost nothing.

- **[Low] `pushToServer` accesses `term.Exited` without checking the union tag** — `src/commands.zig:505-506`
  - `const term = try child.wait(); if (term.Exited != 0)` — if curl dies from a signal, `term` is `.Signal` and the field access is safety-checked illegal behavior: panic in Debug, **UB in the ReleaseSmall prod build** (safety off). Fix: `if (term != .Exited or term.Exited != 0) return error.PushFailed;`.

- **[Low] `designSiblingPath` concatenates the caller-supplied name into paths unsanitized (traversal defense-in-depth)** — `src/paths.zig:60-66`
  - A `name` like `../../x` flows verbatim into `{s}/lib/modules/{s}.sexp` and the flat fallback `{s}/src/{s}`. Harmless for the CLI (user's own machine), but this helper is also called from server request paths keyed on URL `:name`. The VFS layer has proper protection (`validateRel` rejects `..`, `src/serve/vfs.zig:1137-1138`), but `paths.zig` itself — the shared chokepoint — enforces nothing and its module doc (:1-26) doesn't state the sanitization contract. Fix: reject names containing `/` or `..` here (design names are bare basenames by the module's own contract), so no future route can regress.

- **[Low] Guardian config drift vs. CLAUDE.md/README claims + stale artifacts** — `guardian.toml:2`, `guardian.toml:7`, `README.md:20-21`, `.guardian/baselines/`
  - `max_file_lines = 10000` effectively neuters the file-size check CLAUDE.md advertises ("file-size: Enforces file size limits") — the cap exists to accommodate `src/placement/optimizer.zig` at 8,515 lines. README:20 says `zig build` runs "spec drift" checks, but `spec-drift` is explicitly in `disabled` (`guardian.toml:7`); README's Guardian link (`github.com/eugenepentland/netlisp/tree/main/.guardian`) points at a baselines directory, not the tool. Stale baseline files for both disabled checks remain tracked (`.guardian/baselines/spec-drift.txt`, `magic-number.txt`). Also note `.guardian/baselines/spec.txt` grandfathers 83 SPEC.md violations, several referencing already-removed features (`placement-group`, `(module-policy …)` export) — SPEC.md is ratchet-enforced, not actually in sync, contra CLAUDE.md's "spec: Validates SPEC.md matches public function signatures".

- **[Low] Stale Go-agent documentation: `tools/kicad-sync-go` no longer exists** — `README.md:8`, `docs/kicad-sync-setup.md:3-78`
  - README's tagline still claims "A separate Go agent syncs the open KiCad PCB back to the design source," and `docs/kicad-sync-setup.md` is an entire install guide for `tools/kicad-sync-go` — a directory absent from the tree and from `git ls-files` (the Go IPC agent was removed; sync is now the in-server file-based `POST /api/sync-kicad-pcb/:name`, which README's own KiCad-sync section correctly describes). Fix: rewrite README:8 and delete or archive `kicad-sync-setup.md` (`docs/uuid_research.md` references to the Go agent are historical-research context, lower priority).

- **[Low] Usage-string gaps and loose arg handling across subcommands** — `src/main.zig:365`, `src/main.zig:378`, `src/commands.zig:324-326`, `src/commands.zig:445`
  - `printUsage`'s `build` line omits the design argument and the `--push`/`--output-dir`/`--server` flags entirely; `--server` is documented nowhere. Both `import-kicad` usage strings (main.zig:378, commands.zig:445) omit `--fold-channels`/`--fold-prefix`, which CLAUDE.md documents prominently. `cmdExportKicad`'s positional fallback (`} else { design_name = args[i]; }`, commands.zig:324-326) lacks the `!startsWith("--")` guard its sibling parsers have, so a stray/trailing flag (`--verbose`, or a value-flag at end of argv) is captured as the design name and produces a confusing "no such design `--verbose`" path. `bench_layout.zig:336-338` accepts `--seed` without `--poses` and silently ignores it (`src/bench_layout.zig:384-391`).

- **[Low] Local `.env` is world/group-readable and contains keys the code never reads** — `.env` (untracked), `src/config.zig:16-56`, `.env.example`
  - Not a repo leak (never committed, correctly ignored), but the live `.env` holding API credentials is mode `664` — should be `600`. Its `NEXAR_CLIENT_ID`/`NEXAR_CLIENT_SECRET`/`NEXAR_ACCESS_TOKEN` and `DIGIKEY_ENV` keys are read by nothing in `src/` (the sandbox override config.zig actually reads is `DIGIKEY_API_BASE`, config.zig:33-35) — so an operator setting `DIGIKEY_ENV=sandbox` silently hits the production DigiKey API. `.env.example` documents only `CSE_CONNECT_SID` and omits the `DIGIKEY_CLIENT_ID`/`DIGIKEY_CLIENT_SECRET`/`DIGIKEY_API_BASE` and rate-limit keys config.zig supports.

- **[Low] `log.warn` silently drops messages over 4096 bytes** — `src/infra/log.zig:26-30`
  - `bufPrint` into a fixed 4 KiB buffer with `catch return` discards the entire diagnostic on overflow (long paths in `paths.zig`'s ambiguity warning could plausibly hit this). Truncating (write what fits + `…`) would preserve the signal. Minor, but this is the designated last-resort diagnostics channel.

_Not findings (verified clean):_ docgen determinism + the three-layer drift enforcement is sound end-to-end; `build.zig`'s docs `--check` is wired to both install and test steps with explicit cwd (`build.zig:151-156`); guardian runs ReleaseSafe deliberately with a good rationale (`build.zig:102-110`); the templates fmt-race exclusion is handled correctly (`build.zig:117-134`); `infra/random.zig` correctly routes all entropy through `std.crypto.random` (deterministic layout code correctly uses seeded Wyhash instead, per the ban-rng design); the `bench-layout` step's deliberate Guardian bypass is documented and sensible; `.claude/worktrees/`, `guardian_runtime.db`, and `.guardian/cache/` are all correctly ignored; the nested designs repo ignores `/auth/`, `*.bom`, `*.autolayout.json` correctly (one cosmetic stray: tracked `src/boards/barracuda/barracuda.sexp.bak-preimpl` backup file in the designs repo).
