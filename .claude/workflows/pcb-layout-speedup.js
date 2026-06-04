// pcb-layout-speedup — head-to-head shootout of single-threaded speedups for the
// PCB-layout placement optimizer (src/placement/optimizer.zig).
//
// Each variant agent works in its OWN git worktree (isolation: 'worktree') so
// the parallel edits to the same hot file never collide. Every agent:
//   1. implements ONE optimization technique in optimizer.zig (+ helper files)
//   2. builds the SLIM bench exe  (zig build bench-layout -Doptimize=ReleaseFast)
//      — a separate target that pulls in only the optimizer + evaluator (no
//      server/render stack, no Guardian), so it rebuilds in ~25s, not ~2m40s.
//   3. runs the bench on a few designs and checks the grid-quantized pose
//      CHECKSUM against the baseline — the correctness gate. A pure perf
//      refactor MUST reproduce the baseline layout bit-for-bit at grid
//      resolution; a divergent checksum means the variant changed the result.
//   4. deposits its binary + a git patch in OUT_DIR for the (separate,
//      contention-free) authoritative timing sweep the caller runs afterward.
//
// WHY timing is NOT done here: N agents build in parallel, so any wall-clock
// number an agent measures is corrupted by CPU contention. Agents only prove
// BUILD + CORRECTNESS; the caller times each deposited binary serially on a
// quiet machine. Agents are told to ignore their own timings.
//
// Invoke:
//   Workflow({ scriptPath: ".../pcb-layout-speedup.js" })                 // defaults below
//   Workflow({ scriptPath: "...", args: { variants:["soa-relax","fastmath"] } })  // subset
//
// Phases:
//   1 Implement  one agent per variant, in a worktree — edit, build, verify checksum,
//                deposit binary+patch.                                          [parallel]

export const meta = {
  name: 'pcb-layout-speedup',
  description: 'Implement & verify single-threaded SoA/SIMD/algorithmic speedups for the PCB-layout optimizer in parallel worktrees; caller times the deposited binaries serially',
  phases: [
    { title: 'Implement', detail: 'one agent per speedup variant, isolated worktree: edit optimizer.zig, build slim bench, verify identical layout checksum, deposit binary+patch' },
  ],
}

// ── args (all overridable; defaults are this machine's discovered values) ──
let _a = args
if (typeof _a === 'string') { try { const p = JSON.parse(_a); if (p && typeof p === 'object') _a = p } catch (_e) { /* ignore */ } }
const PROJECT_DIR = (_a && _a.projectDir) || '/home/epentland/ai/canopy/eda/projects/designs'
const GUARDIAN_PATH = (_a && _a.guardianPath) || '/home/epentland/ai/canopy/guardian-zig'
const OUT_DIR = (_a && _a.outDir) || '/tmp/pcb-bench'
// Fast designs (each <1s) that exercise both solve paths, with their baseline
// grid-quantized pose checksums. Agents verify their build reproduces these.
const CORRECTNESS = (_a && Array.isArray(_a.correctness) && _a.correctness.length) ? _a.correctness : [
  { name: 'lt3045', checksum: '71b3a3051173327a' },        // 6 parts  — router-bound (rerank path)
  { name: 'rf-switch-8way', checksum: '5b7a7b3271d0c848' }, // 30 parts — relax path
  { name: 'adf5901', checksum: 'c0ef4a368a1cf9b3' },        // 25 parts — relax, multistart
  { name: 'nestedarray', checksum: '555cef21198cca0e' },    // 28 parts — relax, multistart
  { name: 'adcarray', checksum: 'c22279cb374e3fb5' },       // 75 parts — relax, single-start
]
const ALL_VARIANTS = ['soa-relax', 'simd-repulsion', 'soa-simd', 'simd-objective', 'fastmath', 'spatial-grid']
const WANT = (_a && Array.isArray(_a.variants) && _a.variants.length) ? _a.variants : ALL_VARIANTS

const CORR_NAMES = CORRECTNESS.map((c) => c.name).join(' ')
const CORR_TABLE = CORRECTNESS.map((c) => `      ${c.name} = ${c.checksum}`).join('\n')

// ── shared preamble embedded in EVERY agent ──────────────────────────
const PREAMBLE = `
You are optimizing a single Zig file in an ISOLATED git worktree (your CWD is the
worktree root). The project is an S-expression EDA tool; the file under test is
the PCB auto-placement optimizer.

GOAL: make \`pub fn solve\` in src/placement/optimizer.zig run FASTER, single-threaded,
WITHOUT changing the placement it produces. Same board out, fewer cycles.

═══ THE HOT PATH (by function name — line numbers drift, don't trust them) ═══
\`solve\` → \`optimize\` (or \`rerankSolve\` for tiny boards) → per multi-start (STARTS=48)
\`runStart\` → \`relax\` (up to ITERS=600 cooling iterations). Each relax iteration:
  • zero two force arrays ax[],ay[]  (length n = parts.len)
  • springs loop: gather worldPt(parts[s.a]) etc, accumulate spring forces
  • \`accumulateLoops\` → \`accumulateLeg\` (worldRect / nearestHubPad / nearestPoints)
  • \`accumulateCompaction\` (centroid pull)
  • \`accumulateRepulsion\`  ← O(n²) over a precomputed \`boxes: []KeepBox\`. DOMINANT on big boards.
  • integrate: parts[i].x += clampDisp(step*ax[i]/mass); same for y
Then once per start: \`objectiveCost\` = \`wireScore\`(HPWL/RMST over nets) + loop_w*\`weightedLoop\`
  + w_align*\`compactnessTerm\` (default \`tidinessPenalty\`, O(n²)) + congestion(default OFF).
Then \`polish\` (local search) on the winning start only.

DATA LAYOUT (the AoS the task is about): \`pub const Part = struct { ref_des, kind,
hw, hh, pads, fallback, value, silk_*, x, y, rot, keep }\`. The hot numeric fields are
x, y, rot and the rotation-aware extents. rot/kind are FIXED during a single relax call
(rotation only changes between relax calls, in optimizeRotations). \`KeepBox{cxo,cyo,hw,hh}\`
is already extracted to a contiguous local array (\`boxes\`) in relax/legalize — mirror that.
maxParts = 4096 (stack arrays are sized to it; keep using fixed [maxParts] stack buffers,
do NOT heap-allocate per iteration). f64 throughout.

═══ BUILD (fast, ~25s, NO Guardian) ═══
  zig build bench-layout -Doptimize=ReleaseFast
The binary lands at ./zig-out/bin/bench-layout. ALWAYS use ReleaseFast (Debug timings are
meaningless). If the build fails configuring the 'guardian' dependency / can't find
\`../guardian-zig\`, run this once from the worktree root then rebuild:
  ln -s ${GUARDIAN_PATH} ../guardian-zig 2>/dev/null; true
Do NOT edit build.zig, src/bench_layout.zig, SPEC.md, or anything under ${PROJECT_DIR}.

═══ CORRECTNESS GATE (this is what determines if your variant is usable) ═══
Run:
  ./zig-out/bin/bench-layout --project-dir ${PROJECT_DIR} --reps 1 ${CORR_NAMES}
Each line prints \`checksum=<hex>\`. It is a hash of every part's grid-snapped (x,y,rot),
so it is IDENTICAL whenever the final layout is identical — robust to sub-ULP float drift,
sensitive to any real move. Your checksums MUST equal the baseline:
${CORR_TABLE}
If any differ, your change altered the result — DEBUG AND FIX until they match (re-read the
math you touched; a reordered floating-point accumulation that feeds back into positions
will compound over 600 iterations and move parts). Bit-identical force accumulation is the
safe target. (The 'fastmath' variant is the ONE exception — see its brief.)

IGNORE the median_ms/min_ms your run prints — they are corrupted by other agents building
in parallel. The caller measures real timings later, serially. Your deliverable is a
binary that BUILDS and reproduces the baseline checksums.

═══ DELIVERABLES (do these before you finish — the shootout needs them) ═══
  mkdir -p ${OUT_DIR}
  cp ./zig-out/bin/bench-layout ${OUT_DIR}/__ID__
  git add -A && git diff --cached > ${OUT_DIR}/__ID__.patch
Then report via the StructuredOutput tool.

CONSTRAINTS: single-threaded only (no std.Thread / no async). Keep \`solve\`'s public
signature unchanged. Confine edits to src/placement/optimizer.zig unless your technique
needs a new helper file in src/placement/ (include it; it'll be in your patch). Preserve
all existing behavior except speed.
`

// ── per-variant technique briefs ─────────────────────────────────────
const BRIEFS = {
  'soa-relax': `
TECHNIQUE — Struct-of-Arrays in the relaxation loop (scalar; this isolates the
memory-layout win from SIMD).
Today \`relax\` reads/writes parts[i].x / .y interleaved with all the cold Part fields,
so every position touch pulls a near-full Part (~150+ bytes) into cache. Convert the
relax hot loop to SoA:
  • At the top of \`relax\` (and \`legalize\`/\`legalizeOnGrid\` where they iterate positions),
    extract contiguous stack arrays: px:[maxParts]f64, py:[maxParts]f64, prot:[maxParts]f64,
    and a mass:[maxParts]f64 (or is_hub:[maxParts]bool) — loaded once from parts.
  • Rewrite the per-iteration math (springs, accumulateLoops/accumulateLeg,
    accumulateCompaction, accumulateRepulsion, integration) to read px/py/prot instead of
    parts[i].x/.y/.rot. Add SoA-aware overloads of worldPt/worldRect/nearestHubPad/the
    accumulate* helpers that take px,py,prot slices (or a small SoA view struct) — keep the
    AoS versions for other callers.
  • Write px/py back into parts[i].x/.y ONCE at the end of relax (rot is unchanged inside relax).
Keep \`Part\` (AoS) as the public type — this is LOCAL SoA inside the hot loop only. Do not
change any arithmetic or iteration order: aim for bit-identical checksums.`,

  'simd-repulsion': `
TECHNIQUE — SIMD the O(n²) overlap test in \`accumulateRepulsion\` (and \`legalize\`).
The inner j-loop computes dx,dy and the overlap ox,oy for every pair; in a settled layout
MOST pairs do NOT overlap, so the cheap TEST dominates and is perfectly vectorizable, while
the force application (rare, branchy: axis-of-least-penetration + signNudge + scatter to
ax[i]/ax[j]) must stay scalar to remain bit-identical.
  • For each i, lay the inner operands out contiguously: cxj[k]=parts[j].x+boxes[j].cxo,
    cyj[k], hwj[k]=boxes[j].hw, hhj[k]. (Build these once per relax iteration into
    [maxParts]f64 scratch so every i reuses them.)
  • Process j in chunks of @Vector(4, f64): compute dx,dy (vs broadcast cxi,cyi), ox,oy,
    and the overlap mask ox>0 & oy>0 with vector ops; @reduce(.Or, ...) to skip empty chunks.
  • For lanes flagged overlapping, fall back to the EXACT scalar force code (unchanged) so
    forces — and therefore final poses — are bit-identical to baseline.
Optionally also vectorize \`tidinessPenalty\` (pure O(n²) sum) — but note a reordered sum can
perturb the objective's low bits and (rarely) flip which multistart candidate wins, changing
the checksum; if that happens, keep tidiness scalar. Leave \`Part\` AoS.`,

  'soa-simd': `
TECHNIQUE — Combine SoA + SIMD (the expected synergy).
Do the SoA extraction of px/py/prot/mass at the top of \`relax\` exactly as the 'soa-relax'
brief describes, THEN vectorize the O(n²) overlap test in \`accumulateRepulsion\` with
@Vector(4,f64) over those contiguous SoA arrays (no per-iteration gather needed — px/py are
already contiguous). Overlapping lanes fall back to exact scalar force application so results
stay bit-identical. Also vectorize the integration step (px[i]+=clamp(step*ax[i]/mass[i]))
and the array zeroing with @Vector where trivial. Target bit-identical checksums.`,

  'simd-objective': `
TECHNIQUE — SIMD the per-start SCORING terms (helps multistart-heavy boards: STARTS=48
evaluations of objectiveCost, plus polish).
Vectorize with @Vector(4,f64) / @reduce:
  • \`tidinessPenalty\` — O(n²) min/clamp/sum.
  • \`compactnessArea\` — min/max reductions of p.x±effHw(p), p.y±effHh(p).
  • \`compactnessProtrusion\` — centroid then Σ(rx²+ry²).
  • \`accumulateCompaction\` — centroid sum then per-part pull.
  • If tractable, the reduction in \`wireScore\`.
Precompute effHw/effHh into contiguous arrays where it enables clean vector loads. CAVEAT:
a reordered reduction changes the objective's low bits, which can flip a \`cost < best_cost\`
choice and change the checksum. Prefer a summation order matching the scalar baseline (e.g.
keep the scalar tail in the same order); if a term can't be made checksum-stable, leave it
scalar and report which ones you vectorized. Do NOT touch the relax force loops.`,

  'fastmath': `
TECHNIQUE — Let the compiler do it: add \`@setFloatMode(.optimized)\` (fast-math:
reassociation + FMA + freer auto-vectorization) to the hottest functions: relax,
accumulateRepulsion, accumulateLeg, accumulateLoops, accumulateCompaction, objectiveCost,
wireScore, tidinessPenalty, compactnessArea, compactnessProtrusion, worldPt, worldRect,
nearestHubPad, nearestPoints, rectGap. (Put \`@setFloatMode(.optimized);\` as the first
statement of each.) This is the lowest-effort experiment and a useful speed ceiling.
EXCEPTION TO THE GATE: fast-math reassociation WILL perturb floating-point results, so your
checksums MAY differ from baseline — that is EXPECTED here, do NOT fight it. Instead REPORT,
per correctness design, whether the checksum matched, and (your judgment) whether the layout
looks essentially the same or materially changed. Make all_identical_to_baseline reflect
reality (likely false for some designs). Still must BUILD and RUN.`,

  'spatial-grid': `
TECHNIQUE — Algorithmic: drop \`accumulateRepulsion\` / \`legalize\` from O(n²) to ~O(n) with a
uniform spatial hash grid (biggest potential win on 100–300-part boards: stm32n6,
cyclops-analog, labstation). Only nearby courtyards can overlap, so bucket the boxes into a
grid (cell ≈ the max courtyard extent, or 2× the median) and test each box only against
boxes in its own + 8 neighbor cells.
CRITICAL — preserve results: the baseline applies forces in i<j order with signNudge(d,i,j)
tie-breaking, and floating-point force accumulation is order-sensitive. To stay bit-identical
you must apply each overlapping pair exactly once in the SAME global order the nested loop
would (for each i ascending, its overlapping j>i in ascending order). E.g. gather candidate
j's from neighbor cells, filter j>i, sort ascending, then apply the unchanged scalar force
code. Rebuild/refresh the grid each iteration (positions move). Keep fixed-capacity stack
buffers (maxParts=4096), single-threaded. If exact ordering proves impossible, get as close
as you can and REPORT whether checksums matched (the grid quantization may absorb tiny drift).`,
}

const VARIANT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    variant: { type: 'string' },
    build_ok: { type: 'boolean', description: 'slim bench exe compiled in ReleaseFast' },
    build_error: { type: 'string', description: 'tail of the build error, or empty' },
    ran_ok: { type: 'boolean', description: 'binary ran the correctness designs without crashing' },
    checksums: {
      type: 'array',
      description: 'the checksum your build produced for each correctness design',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          design: { type: 'string' },
          checksum: { type: 'string' },
          matches_baseline: { type: 'boolean' },
        },
        required: ['design', 'checksum', 'matches_baseline'],
      },
    },
    all_identical_to_baseline: { type: 'boolean', description: 'every correctness checksum equals baseline (the usability gate; fastmath may be false)' },
    binary_path: { type: 'string', description: 'where you copied the binary, or empty if not produced' },
    patch_path: { type: 'string', description: 'where you wrote the git patch, or empty' },
    changed_files: { type: 'array', items: { type: 'string' } },
    loc_changed: { type: 'number', description: 'approx lines changed' },
    technique_summary: { type: 'string', description: '2-4 sentences: what you actually changed and where' },
    notes: { type: 'string', description: 'caveats, dead ends, what to try next' },
  },
  required: ['variant', 'build_ok', 'ran_ok', 'all_identical_to_baseline', 'technique_summary'],
}

phase('Implement')
log(`Spawning ${WANT.length} speedup variants in isolated worktrees: ${WANT.join(', ')}`)
log(`Each builds the slim bench (~25s) and gates on baseline checksums; timing is measured serially afterward.`)

const results = await parallel(
  WANT.map((id) => () => {
    const brief = BRIEFS[id]
    if (!brief) return Promise.resolve(null)
    const prompt =
      PREAMBLE.replaceAll('__ID__', id) +
      `\n═══ YOUR VARIANT: ${id} ═══\n` +
      brief +
      `\n\nWork iteratively: read the relevant functions, make the change, build, check checksums, fix, repeat. ` +
      `When done, ensure the binary and patch are in ${OUT_DIR} and fill in the StructuredOutput. ` +
      `Set all_identical_to_baseline honestly. If you cannot get it to build, set build_ok=false and explain in build_error/notes.`
    return agent(prompt, { label: id, phase: 'Implement', schema: VARIANT_SCHEMA, isolation: 'worktree' })
  }),
)

return { variants: results.filter(Boolean) }
