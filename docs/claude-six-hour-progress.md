# Netlisp six-hour sprint progress

- Start UTC: **2026-09-06T05:27:55Z**
- Deadline UTC (fixed across resumes): **2026-09-06T11:27:55Z**
- Closeout begins UTC: **2026-09-06T10:42:55Z** (last 45 min)
- Starting main commit: `517cc58b`
- Execution worktree and branch: `.claude/worktrees/claude-sprint-0906` / `claude/sprint-0906`
- Allowance basis / starting use / latest observed use: **not measurable from
  inside this session.** No usage telemetry tool is exposed here (`/usage` is an
  interactive terminal command, not a tool call), so this sprint runs on the
  **time budget only**. The user's stated "~50% of allowance" is recorded but
  cannot be tracked or converted; context-window occupancy is deliberately NOT
  used as a proxy.
- Usage observable: **no**; measurement source: none available.

## Ownership check (done at start)

18 sibling worktrees. Files they hold, and this sprint therefore avoided:
`src/placement/*` (rough-intent, black-canyon-rf-straight, internal-cutouts,
pour-gap-everywhere, pad-size-aware-tapers), `src/serve/pcb_layout_mcp.zig` +
`pcb_layout_page.zig` (net-rename-copper, trace-selection-priority),
`src/serve/assets/pcb_board.js` (three worktrees), `src/export_fab.zig`
(jlc-export-format), `src/export_gerber.zig` (internal-cutouts,
pour-gap-everywhere). That ruled out A05/A06/A07/A12 and most of the B queue by
file collision. Lane taken: **CLI / inspection tooling / registry + review
correctness**, which no sibling worktree touches.

| Item | State | Evidence / commit |
| --- | --- | --- |
| A01 CLI help + arg safety | **verified, committed** | `cac63843` |
| A02 bulk net-envelope surface | **verified, committed** | `0bdef86f` + `dcd7ca4f` |
| A03 bench-route checkpoint | **verified, committed** | `5b7a2a71` |
| C12 test-registration gate | **verified, committed** | `d4ba1587` + `7c4d111a` |
| C09 tool schema vs dispatch | **verified, committed** | `73059345` + `357e417b` |
| A11 review-surface reconciliation | **verified, committed** (rating fix) | `19e1c152` |
| A04 system readiness | **partly fixed, partly reproduced, partly disproved** | `33dfdde9` + `0d6dcf87` + `83e09a77` |
| C15 ledger reconciliation | **verified, committed** | `83e09a77` |
| C05 parser/printer | **already-covered** — no defect found (evidence below) |
| C11 persistence failures | **already-safe** — fault-injected, no defect (evidence below) |
| A09 offline fab-release fixture | **already-implemented** (evidence below) |
| C06 DSL identity | **verified at the observable level** (evidence below) |
| C01 KiCad netlist membership | **covered now**; through-KiCad half blocked (no `kicad-cli`) | `f103e6af` |
| C10 script-context escaping | **already-guarded** — verified at the real sink (evidence below) |
| C07 finding consistency | **already-consistent** — check/build/tools agree (evidence below) |
| C08 evidence freshness | **already-safe** — every input invalidates (evidence below) |
| C16 hermetic examples | **already-hermetic** under `env -i` (evidence below) |
| A05 A06 A07 A12, B01–B06 | **owned-elsewhere** — skipped on file collision |

## Completed changes

### A01 — `serve` decides its command line before opening anything (`cac63843`)

`netlisp serve --help` started the server: it created
`<project>/logs/interactions-<date>.jsonl`, bound the port and blocked until
killed. `--port abc`, `--port 99999` and a valueless `--port` silently served on
7050; `--allow-remoote` was ignored, so an operator who believed they had
disabled the auth gate had not. `src/serve_args.zig` is now a pure
`parse(argv, auth_dir_env)`; `dispatchServe` opens a socket only for `.run`.
Verified on a disposable project: `--help` exits 0 leaving the directory
byte-identical, five malformed forms exit 1 writing nothing, and
`--port 7188 --skip-warmup` still answers HTTP 200. 8 unit tests.

### A02 — `netlisp envelopes` (`0bdef86f`, `dcd7ca4f`)

Reading every net's DC envelope took 1,863 separate `netlisp net` calls (~10 min
per binary). One command now answers from ONE evaluation per design, reusing
`mcp_flatten.writeNetEnvelope` — the same function the single-net query calls —
so bulk and single-net values cannot differ.
**Measured, read-only, against the live library** (checkout byte-identical
after): whole 19-design corpus **1,863 nets in 2.69 s / 218 MB peak RSS**;
barracuda-base 188 nets in 0.15 s. Identity check on blinky-breakout: 16/16 nets
equal to their own `netlisp net` output, 0 mismatches; 0.88 s per-net loop vs
0.055 s bulk. 899 of 1,863 nets are unbounded — reported as explicit
`null`/`unknown`, never 0 V. `0bdef86f` first extracted `dump_args.Common`
(Guardian's twin-drift caught the third copy of that arg scan).

### A03 — `bench-route --jsonl` (`5b7a2a71`)

Each board's row is flushed and fsynced as that board finishes, from
`writeBoardJson` — extracted from `writeJson`, so checkpoint and aggregate rows
are the same bytes (verified: all 48 fields equal). A failed board is a row with
`"ok":false`; an interrupted corpus has NO `complete` record.
**Verified on an isolated fixture copy**: SIGKILL as soon as the first row
landed → `run` header + the first board's full 16/16 row survive, 0 unparseable
records, no `complete` line.

### C12 — all three test registrations fail the build (`d4ba1587`, `7c4d111a`)

A new test-bearing module needs an explicit `test_root.zig` import, a
`test_shards.zig` filter, and the import must be explicit even when the module is
already reachable. Only the first was caught quickly; the others cost a full or
affected test run — a release gate once spent 118 s to report five of them.
`netlisp check-test-manifest` now runs on every `zig build`.
Making it cheap took measuring, not guessing — two plausible causes were wrong
(I/O is 6 ms for 24.5 MB; the byte-at-a-time scan was not it either). The cost
was 5,036 names × 621 filters of `indexOf`:
**2.70 s → 1.55 s** (split module/name match) **→ 0.22 s** (candidate list
memoized per source file). A test asserts the fast path equals
`std.mem.indexOf` over the whole committed manifest.
`7c4d111a` was prompted by my own `19e1c152` tripping the third case.

### C09 — every tool held to the schema it advertises (`73059345`)

Probed all 93 tools. Four ways of being wrong went straight through:
`list_free_pins {"filter":"nonsense"}` → empty pin list, exit 0;
`get_schematic_image {"view":"nope"}` / `{"theme":"chartreuse"}` → a PNG of the
default view; `{"viwe":…}` accepted under `additionalProperties:false`;
`{"flatten":"yes"}` accepted for a boolean. The check now runs once in
`mcp_tools.call`, against the advertised document itself.
**Deliberate behaviour change, one test updated**: `get_pcb_layout_image` used to
fall back to still air for an unrecognised `scenario`. It now refuses — the test
asserts the refusal, a strictly stronger claim.
Verified: 7 bad forms exit 1 with parseable JSON naming the argument; 5 valid
forms unchanged. Full suite 5,332 tests, 0 failures.

### C09 follow-up — the seven schemas that still ignored typos (`357e417b`)

`73059345` enforces the advertised schema, but only where the schema says the
object is closed. Seven `package_*` tools omitted `"additionalProperties": false`,
so the defect survived in the DOCUMENT: `package_show {"famly":"qfn"}` was
accepted and the typo ignored. Closing them is checked, not assumed — the
handlers read exactly the declared properties, and the GUI reaches them through
`/api/packages/<action>` rather than `tools/call`. The durable half is a test
requiring every advertised schema to close its object, so a tool added later
cannot reopen it.

### A11 — a nominal no longer excuses a declared rated span (`19e1c152`)

`evalVoltageRange` passed as soon as the nominal was in range and reached the
rated arm only when there was NO nominal — so adding a `(nominal …)` to a port
silently switched the rated-span rating check off, at release profile.
Reproduced: widening blinky's input to `(rated 4.5 24.0)` moved the envelope to
`hi=24` and left `run_checks` byte-identical at all three profiles, still passing
`port VIN = 5.000 V ∈ [2.500, 6.000] V` for a 6 V-max LDO.
**Corpus impact, measured read-only over all 19 live designs — two real
exceedances this hid**, neither fixed here (they are declarations in
`projects/designs`, its owner's call):
- `black-canyon` U12 (ADP150-3.3): port VOUT rated [3.200, 3.400] V vs the
  regulator's guaranteed [3.218, 3.350] V. This is a `requirement` error, so it
  **BLOCKS that board's fab-readiness gate**, which previously showed zero
  blocking errors. ← the one operational consequence of this sprint
- `cyclops-analog` U7: [3.135, 3.465] V vs [2.700, 3.450] V — 15 mV over; its
  fab gate is unaffected.

### A04 — system readiness (`33dfdde9`, `0d6dcf87`, and see `83e09a77`)

Two fixes and three measurements, from a small immutable two-board fixture built
out of `examples/blinky-breakout`:

1. **A rejected manifest now says which field** (`33dfdde9`). The validator
   already recorded field/expectation/value; `loadManifest` gave it a local
   `Diagnostic` that died with the error, so `system-check` printed only
   `InvalidManifest`. Now it prints
   `boards[].role: board role must be a portable identifier / got: "…"`.
2. **A board built on the bundled library can compose a system review**
   (`0d6dcf87`). `appendSource` canonicalizes every loaded file to prove
   containment, and a stdlib component has no on-disk path — so the whole
   composition aborted with a bare `FileNotFound`. Root-caused with strace (no
   failing syscall before the exit → a logic-level refusal) and confirmed by
   copying `stdlib/` into the fixture's `lib/`, which made the same system
   compose. Strict extension: the live 19-design library resolves no board
   source from stdlib, so nothing that composes today composes differently.
3. **The DRIFT-SYSREV-001 measurements**, now that the fixture runs:
   - determinism: 6 identical runs → 1 distinct (release_token, content_lock,
     verdict). The recorded 409s did **not** reproduce.
   - read-time writes: a readiness pass changed **no file**.
   - cost: the double fab computation is still present and code-verified —
     0.18 s per computation here (~13% of a 2.7–3.3 s composition), against the
     6.7–13.3 s per computation recorded on far larger boards.

### C15 — ledger reconciled against measurement (`83e09a77`)

DRIFT-SYSREV-001 updated with the three results above. DRIFT-SIZE-001 stays
**open** although its condition is gone (`pcb_layout_page.zig` is 8,131 lines
after a real six-module split, against the ~17.3k that was 96% of its ratchet):
closing it was tried and correctly refused by
`scripts/check_audit_ledger_test.py`'s standing claim that every fixed finding
names a test or harness. The condition is gone; the guarantee is not.

## Revalidated, no change needed

- **C05 parser/printer** — already has a fuzzed parser, a fuzzed
  parse→print→parse round trip and a whole-corpus round trip. 14 adversarial
  cases (escapes, nested-100, SI edges, hex, ±0, i64 bounds, float precision,
  parens/semicolons inside strings) all round-trip idempotently; Unicode inside
  strings survives, a non-ASCII atom is rejected with a correct span. No defect.
- **C11 persistence** — the layout sidecar goes through `infra/atomic_write.zig`.
  Fault-injected with `chmod a-w` on `src/` during a save: the save fails with
  `CannotWriteSidecar`, the prior sidecar is byte-identical, no stray temp is
  left and history survives. No defect. (`board_backup.zig`'s fixed `.tmp`, which
  `atomic_write.zig`'s header still describes in the present tense, is already
  fixed and has its own regression test — a stale comment, noted below.)
- **A09 fab-release fixture** — already implemented: `pcb_layout_fab.zig` calls
  the real endpoint, verifies a 24-member ZIP with checksums, an offline
  assembly HTML with no `/static/` references, the release and DRC reports, plus
  `in-request layout ABA invalidates HTTP readiness and export` for the
  stale-input refusal.
- **C07 ERC/requirements consistency** — the recorded gap is fixed. A
  net-envelope contradiction (`(net-envelope "VIN_5V" (rated 4.9 5.1))` against a
  derived 4.5–5.5 V) is reported identically, with the same sentence, by
  `netlisp check` (as an `error assertion` finding), by `netlisp tool run_checks`
  (as `assertion_failures`) and by `netlisp build`, which refuses to emit and
  points at `check`. The 2026-09-05 FEEDBACK entry saying these were invisible to
  `check` no longer holds.
- **C10 I/O boundaries (script-context escaping)** — the DRIFT-SEC-001 class is
  guarded and holds, checked against the real sink with a payload proven to
  reach it. A section description containing
  `</script><script>alert(2)</script>` reaches `/schematics/:name` 5 times and
  comes out as `\u003c/script>\u003cscript>alert(2)` inside the JSON script blob
  (so the block cannot be terminated early — zero raw `</script>` in it) and as
  `&lt;/script&gt;…` in the HTML body. **The first run of this probe was
  vacuous** and worth recording as a method note: the same payload produces a
  clean result on `/pcb-layout/:name` only because it never reaches that page
  at all (0 occurrences). A note-borne payload likewise did not reach either
  page, so notes remain unexercised.
- **C01 KiCad round trip** — the netlisp half is now covered (`f103e6af`, below);
  the through-KiCad half is environmentally blocked: `scripts/verify_kicad_sch.sh`
  needs `kicad-cli`, which is not installed here. Neither KiCad harness is wired
  as an `[[external]]` gate, and `scripts/test_kicad_sync_layout.py` cannot
  become one as written — it defaults to `projects/designs` / `barracuda-base`
  and performs a real push-to-KiCad sync, so it needs the live library and
  mutates it.
- **C08 review-evidence freshness** — every input class invalidates its dependent
  evidence, checked one input at a time on isolated copies of the example:
  a comment-only edit to the `.sexp` moves `source_sha256` (+4 more), a
  `.layouts.json` edit moves `layout_sha256` (+5), a `.bom` edit moves
  `bom_evidence_sha256` (+5), and a newly added `.checks.sexp` moves the
  consumed-inputs and read-set digests. No under-invalidation anywhere.
  Worth knowing: `source_sha256` also moves for sidecar-only changes, so it is
  broader than its name reads — conservative, never the dangerous direction.
- **C16 hermetic examples** — `examples/blinky-breakout` copied to a scratch
  directory and driven under `env -i PATH=… HOME=/nonexistent` from a cwd that is
  neither the project nor the repo: `build --output-dir`, `check --profile
  release`, `export-kicad`, `gerber-dump --digest`, `run_fab_readiness` and
  `envelopes` all succeed, and the source tree is byte-identical throughout. No
  private-library, working-directory or source-write assumption. (Before
  `0d6dcf87` the same example could not compose a SYSTEM review at all — that was
  the one real hermeticity defect, and it is fixed.)
- **C06 DSL identity** — three consecutive `netlisp build` runs leave the tree
  byte-identical, and flipping a `when` branch adds/removes only that branch's
  instance without disturbing the ref-des of its neighbours. The deeper property
  (id tokens pinned back into source) runs through the server edit path and was
  not reachable in the time left.

## Verification and measurements

All builds in this worktree with its own prefix (`-p zig-out-sprint`) so no
running server's binary is overwritten.

```
zig build --seed=1 -p zig-out-sprint          # + whole-tree Guardian, 0 blocking
zig build --seed=1 test                       # 5,340 tests, 0 failures
zig build --seed=1 test -Dtest-filter='<module>.test'
python3 scripts/check_audit_ledger.py         # 49 findings: 46 fixed, 2 open, 1 waived
```

Every measurement against `projects/designs` was read-only, and the checkout was
byte-identical afterwards each time (it carries two pre-existing modifications
from another session, untouched).

## Gate/integration status — MERGED AND DEPLOYED

Main advanced from `517cc58b` to `52df45e0` during the sprint (several other
sessions landed). Merged main into `claude/sprint-0906` rather than rebasing 16
commits through the same append-file conflicts; the only real conflict was
`FEEDBACK.md`, resolved by keeping both sides in log order.
`SPEC.md`, `.guardian/pub-api.txt`, `test_root.zig` and `test_shards.zig`
auto-merged, and all six of my SPEC sections plus every test registration
survived (verified by grep before committing).

- Merge commit: `d947830a`; full suite on the merged tree: **5,346 tests, 0 failures**.
- `.githooks/prepare-release.sh`: queued **271 s** behind another session's
  `perf_gate.sh --record`, then **candidate ready for d947830a4** —
  tests 127 s, ReleaseSafe build 131 s, editor perf 616 s, wall 790 s.
  The editor-perf stage missed once by 0.4 ms (`canvas.zoom_out.worst_p95_ms:
  45.4 ms > 45 ms`) under that contention; the script classified it as a
  timing-only miss and its own attempt 3 passed on a confirmed quiet host.
  **No baseline was re-recorded and no threshold relaxed** — my changes touch no
  editor canvas code.
- Fast-forwarded `main` to `d947830a`; the post-merge hook reused the verified
  candidate, restarted the service, and reported **health OK (all probes), service active**.
- Verified against the DEPLOYED binary (`.deploy/bin/netlisp`, not the stale
  `zig-out/` artifact): `serve --help` exits 0, `serve --port abc` refuses,
  `envelopes` answers, `check-test-manifest` reports 5,058 tests each claimed
  once, and `get_schematic {"viwe":…}` is rejected by argument name. Live server
  answers on :7050.
- `projects/designs` carries only the two modifications it already had from
  another session; nothing in it was written by this sprint.

## Reproduced blockers and preserved experiments

- `-Dtest-filter` matches the **test name**, not the `// spec:` tag; Guardian
  correctly fails a zero-match filter ("NOTHING YOU ASKED FOR RAN").
- `system-check`'s remaining opaque errors: `FileNotFound` named no path until
  `0d6dcf87` added the warning, and other read failures still do not. Fixtures
  preserved under the session scratchpad: `a04sys/` (two boards, stdlib-using),
  `a04flat/`, `a04one/`, `a04concept/`, `a04full/` (stdlib copied in).
- `atomic_write.zig`'s module header still cites `serve/board_backup.zig`'s fixed
  `<path>.tmp` in the present tense; that defect is fixed and tested. A stale
  comment in a safety module, worth a one-line correction by whoever next
  touches it.

## Next useful tasks

1. DRIFT-SYSREV-001's remaining two facts need a **board-scale** fixture: the
   double fab computation (dominant at that size) and the 409 nondeterminism,
   which small boards do not exhibit.
2. `black-canyon` U12's rail declaration vs the ADP150's guaranteed output — a
   designs-repo decision (tighten the rail, or waive), now blocking its fab gate.
3. Whether stdlib sources belong in the review evidence closure at all, rather
   than being skipped as `0d6dcf87` does — a policy question about what a
   release archive contains.
4. Make `file-size` blocking for `pcb_layout_page.zig`, or give it a ceiling
   test, so DRIFT-SIZE-001 can close.
