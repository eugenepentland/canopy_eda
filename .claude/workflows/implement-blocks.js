// implement-blocks — turn each stub into a reusable-module-aware,
// datasheet-reviewed implementation, designing independent blocks in parallel.
//
// Invoke (defaults to barracuda's 11 imported blocks):
//   Workflow({ scriptPath: ".../implement-blocks.js" })
// or override:
//   Workflow({ scriptPath: "...", args: { design:"barracuda", sexp:"src/barracuda/barracuda.sexp",
//             blocks:[{stub:"ldo_3v3a", component:"lt3042edd#pbf", role:"+3.3V LDO"}, …] } })
//
// Phases:
//   0 Prepare one agent per block: discover reusable modules before schematic work     [parallel]
//   1 Review  one agent per unique direct component completes its cited datasheet review [parallel]
//   2 Design  one agent per prepared block → returns replacement S-expr text           [parallel]
//   3 Apply   single agent: (a) ensures every referenced component is in the top-level
//             (import …) form, (b) edit_file-replaces each (stub …) with its block.
//             ONE writer, so no write races.                                            [serial]
//   4 Verify  build + run_checks(profile=preflight)                                     [serial]
//   5 Repair  ONLY if Verify's build fails: one agent fixes the known build-error
//             classes (missing import, nested design-block, 1-arg note, unquoted net)
//             and rebuilds. Bounded to 2 attempts.                                      [serial, conditional]
//
// HARDENED (2026-06-02): the first run of this workflow emitted every one of the
// build-breaking bug classes below; the Design RULES + Apply step + Repair phase now
// guard against each:
//   1. components referenced but never (import …)ed  → UnboundVariable
//   2. output wrapped in a nested (design-block …)   → not allowed inside the top block
//   3. every main IC labeled "U1"                     → duplicate_refdes + pin_multi_net cascade
//   4. crystal used as a family: (crystal "12MHz")    → it's a fixed component, use bare `crystal`
//   5. one-arg (note "…")                             → ArityError (note takes exactly 2 args)
//   6. bare (pin 1 GND) instead of (pin 1 "GND")      → the net is eval'd → UnboundVariable
//
// SAFETY: never commits, pushes, exports a board, or writes the NAS. The original
// (id <hex>) is preserved on each main instance so PCB identity is stable. Every
// block returns its full text in the result, so even if Apply/Verify hiccup the
// designs are recoverable.

export const meta = {
  name: 'implement-blocks',
  description: 'Discover reusable modules, complete cited datasheet reviews, implement prepared stubs in parallel, then run strict preflight',
  phases: [
    { title: 'Prepare', detail: 'discover canonical/recommended modules and identify direct-component review work' },
    { title: 'Review', detail: 'one agent per unique direct component completes its full cited datasheet review' },
    { title: 'Design', detail: 'one agent per prepared block — produce a sub-block or reviewed direct implementation' },
    { title: 'Apply', detail: 'single writer: ensure imports, then replace each stub with its block' },
    { title: 'Verify', detail: 'build + unified strict preflight' },
    { title: 'Repair', detail: 'conditional: fix known build-error classes and rebuild' },
  ],
}

// ── args ──────────────────────────────────────────────────────────
let _a = args
if (typeof _a === 'string') { try { const p = JSON.parse(_a); if (p && typeof p === 'object') _a = p } catch (_e) { /* ignore */ } }
const design = (_a && _a.design) || 'barracuda'
const SEXP = (_a && _a.sexp) || 'src/barracuda/barracuda.sexp'
const BLOCKS = (_a && Array.isArray(_a.blocks) && _a.blocks.length) ? _a.blocks : [
  { stub: 'ldo_5v', component: 'lt3045edd#pbf', role: '+5V ultra-low-noise analog LDO' },
  { stub: 'ldo_3v3a', component: 'lt3042edd#pbf', role: '+3.3V low-noise analog LDO' },
  { stub: 'buck_3v3d', component: 'lmr33630adda', role: '+3.3V digital buck' },
  { stub: 'boost22', component: 'lm2733xmf-nopb', role: '+22V boost (VCO tune / CP supply)' },
  { stub: 'hmc733', component: 'hmc733lc4btr', role: 'wideband VCO (X-band)' },
  { stub: 'hmc998', component: 'hmc998apm5etr', role: 'LO driver amplifier' },
  { stub: 'dsa', component: 'hmc1119lp4metr', role: '7-bit digital step attenuator (SPI)' },
  { stub: 'lmx2595', component: 'lmx2595rhar', role: 'LO synthesizer (SPI, 10MHz ref)' },
  { stub: 'adf4159', component: 'adf4159ccpz-rl7', role: 'PLL ramp generator (SPI, 10MHz ref)' },
  { stub: 'usbc', component: 'usb4125-gf-a-0190', role: 'USB-C receptacle (USB FS)' },
  { stub: 'mcu', component: 'w55rp20-s2e', role: 'RP2040+W5500 MCU (3 SPI buses, USB, Ethernet)' },
]

// Passive families are auto-loaded (no import needed); everything else must be imported.
const FAMILY_RE = /^(cap|res|ind|ferrite)-\d{3,4}$/
const isFamily = (c) => FAMILY_RE.test(String(c || '').trim())

// ── shared design rules embedded in EVERY agent so parallel agents converge ──
const RULES = `
SYNTAX (house style — copy EXACTLY):
  Module:   (sub-block "<STUB-NAME>" (<module> <params>) (bridge "" <port mappings>) (id <orig-hex>))
            • Use this whenever preparation selected a module. Do not reproduce the module's internals.
  Main IC:  (instance "<STUB-NAME>" <component> (pin 1 "NET_A") (pin 2 3 4 "GND") … (id <orig-hex>))
            • <component> is the lib basename, UNQUOTED (e.g. lt3045edd#pbf, hmc733lc4btr, crystal).
            • Pin numbers/ids are the ids from describe_component; several pins on one net: (pin 2 3 4 "GND").
  Passive:  (instance "C_<stub>_VDD" (cap-0402 "100nF") (pin 1 "RAIL") (pin 2 "GND"))
            • Auto-loaded families (NO import): cap-0201/0402/0603/0805, res-0201/0402, ind-0402/2016, ferrite-0402 — each takes a "value".
  Crystal:  (instance "Y_<stub>" crystal (pin 1 "XIN") (pin 2 "GND") (pin 3 "XOUT") (pin 4 "GND"))
            • crystal is a FIXED component used BARE — NEVER (crystal "12MHz"), that is not a family and will fail to evaluate.
  Notes:    (note "<ref_des>" "one-line rationale")  — EXACTLY TWO string args. A one-arg (note "…") is an ArityError.

FORBIDDEN OUTPUT (these broke the build last time — do NONE of them):
  ✗ Do NOT wrap your output in (design-block …) or any other container. Emit ONLY top-level (instance …) + (note …) forms.
  ✗ For a direct implementation, do NOT label the main IC "U1"/"U2"/etc. EVERY block uses "U1" → duplicate ref-des + a pin-merge cascade.
    Label the main instance with the STUB NAME you were given. Support passives get descriptive labels like "C_<stub>_VDD1".
  ✗ Do NOT use a bare net token: (pin 1 GND) evaluates GND as a variable → UnboundVariable. Nets are ALWAYS quoted: (pin 1 "GND").
    (Pin IDS may be bare — alphanumeric BGA pins like (pin A9 B9 "VBUS") are fine.)
  ✗ Do NOT reference any non-passive component you don't list in "imports" (see HARD RULE 7).
  ✗ Do NOT directly instantiate a component with an applicable canonical module. Use the module as a sub-block.

HARD RULES:
1. PRESERVE the stub's external nets EXACTLY. Whatever nets the stub's (signal …) forms use
   (e.g. "V_5VA", "GND", "VCO_RF", "SPI_DSA") are this block's interface to the rest of the board —
   the matching pins MUST connect to those same net names, or the board disconnects.
2. KEEP the stub's (id <hex>) on the replacement sub-block or MAIN instance (stable PCB identity). Support passives need no id (auto-assigned).
3. For direct implementations, CONNECT EVERY IC PIN. Every supply pin → its rail with datasheet-required local decoupling to GND
   per supply pin, plus ONE bulk cap (1–10uF) per rail. Every GND pin AND the exposed/paddle pin → "GND".
   Leave NO supply or ground pin unconnected (the ERC flags "IC has no power/ground connection").
4. EXPAND ABSTRACT BUSES with this EXACT convention so the other end (a different agent) matches:
   - SPI on "SPI_<X>"  → "SPI_<X>_SCK", "SPI_<X>_SDI", "SPI_<X>_CSN", and "SPI_<X>_SDO" ONLY IF the part
       has a readback/MUXOUT pin (otherwise omit SDO — a dangling SDO becomes a floating-net warning).
       peripheral mapping: CLK→SCK, DATA/MOSI/SDI→SDI, LE/CS/SEN→CSN, MUXOUT/SDO/DOUT→SDO.
       add a 10k pull-up (res-0201) from CSN to its logic rail (mirror cyclops "R_PU_CS_*").
   - USB on "USB_DP"   → pair "USB_DP","USB_DM" — and BOTH the MCU end and the USB-C connector end must wire them.
   - ETH on "ETH_MDI"  → "ETH_TXP","ETH_TXN","ETH_RXP","ETH_RXN" — wire the same four at the magjack end.
   - single-ended nets (REF_10MHZ, REF_EXT, LOCK_DET, VTUNE, CPOUT, *_RF, LO_*, V_*): keep the stub name as-is.
5. The preparation phase has already completed the whole datasheet review. Apply EVERY requirement from
   describe_component (the "requirements" array), not just the convenient machine-checkable subset. Compute real values
   (e.g. LT304x: VOUT = 100uA × RSET → RSET = VOUT/100uA; IN≥4.7uF; OUT≥10uF; EN/UV→IN; ILIM→GND or RILIM;
   PGFB→IN; CSET ~470nF on SET; OUTS Kelvin to VOUT). Respect each pin's RATED VOLTAGE — never tie a pin
   rated ≤3.45V (e.g. a charge-pump VP) to a higher rail like +22V; if no correct rail exists, say so in "unresolved".
   DO NOT invent values you can't justify — list them in "unresolved".
6. RF first-pass: connect RF pins directly to their external RF nets. Where a DC block / bias-tee / balun is
   really required, still connect the net but record it in "unresolved" (don't fabricate the network).
7. IMPORTS: in the "imports" field, list the lib basename of EVERY module or non-passive component your new_string
   references — the selected module/main <component> PLUS any extra IC / crystal / connector you add (e.g. a fanout buffer,
   a TCXO). Do NOT list passive families. The workflow uses this to ensure each is (import …)ed.

OUTPUT new_string = the COMPLETE multi-line replacement text (selected sub-block, or main instance + every support instance + notes),
correctly balanced parentheses, that will literally REPLACE the (stub …) form. No surrounding prose, no (design-block …).
Be HONEST in "unresolved": list any pin you guessed, any value you couldn't derive, any support network you skipped.`

const DESIGN_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    stub: { type: 'string' },
    ref_des: { type: 'string', description: 'the label on the main instance — MUST equal the stub name' },
    implementation: { type: 'string', enum: ['module', 'direct'] },
    module: { type: 'string' },
    new_string: { type: 'string' },
    imports: { type: 'array', items: { type: 'string' }, description: 'lib basenames of every non-passive component referenced (main + extras), excluding passive families' },
    support_count: { type: 'number', description: 'number of support passives added' },
    assumptions: { type: 'array', items: { type: 'string' } },
    unresolved: { type: 'array', items: { type: 'string' } },
  },
  required: ['stub', 'implementation', 'new_string', 'imports'],
}

const PREP_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    stub: { type: 'string' },
    component: { type: 'string' },
    implementation: { type: 'string', enum: ['module', 'direct', 'blocked'] },
    module: { type: 'string' },
    module_policy: { type: 'string', enum: ['canonical', 'recommended', 'example'] },
    datasheet_review: { type: 'string', enum: ['complete', 'not_applicable', 'blocked', 'module_owned'] },
    datasheet: { type: 'string' },
    sha256: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
    parent_requirements: { type: 'array', description: 'manual/application obligations a selected module leaves for the parent design', items: {
      type: 'object', additionalProperties: false,
      properties: { ref_des: { type: 'string' }, requirement_id: { type: 'string' }, text: { type: 'string' } },
      required: ['requirement_id', 'text'],
    } },
    rationale: { type: 'string' },
  },
  required: ['stub', 'component', 'implementation', 'datasheet_review'],
}

const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    component: { type: 'string' },
    status: { type: 'string', enum: ['complete', 'not_applicable', 'blocked'] },
    datasheet: { type: 'string' },
    sha256: { type: 'string' },
    requirements_added: { type: 'array', items: { type: 'string' } },
    blockers: { type: 'array', items: { type: 'string' } },
  },
  required: ['component', 'status'],
}

const APPLY_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    imports_added: { type: 'array', items: { type: 'string' } },
    applied: { type: 'array', items: { type: 'string' } },
    failed: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { stub: { type: 'string' }, reason: { type: 'string' } }, required: ['stub', 'reason'] } },
  },
  required: ['applied'],
}

const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    build_ok: { type: 'boolean' },
    preflight_pass: { type: 'boolean' },
    eval_ok: { type: 'boolean' },
    version: { type: 'number' },
    erc_errors: { type: 'number' },
    erc_warnings: { type: 'number' },
    requirement_failures: { type: 'number' },
    datasheet_review_failures: { type: 'number' },
    module_policy_failures: { type: 'number' },
    erc_detail: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { severity: { type: 'string' }, rule: { type: 'string' }, detail: { type: 'string' } }, required: ['rule'] } },
    preflight_summary: { type: 'string' },
    build_error: { type: 'string' },
  },
  required: ['build_ok'],
}

const REPAIR_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    build_ok: { type: 'boolean' },
    eval_ok: { type: 'boolean' },
    version: { type: 'number' },
    fixes: { type: 'array', items: { type: 'string' } },
    still_broken: { type: 'string' },
  },
  required: ['build_ok'],
}

const TOOL = 'Use the netlisp MCP tools via ToolSearch: read_file, edit_file, list_library, describe_component, preview_module, download_datasheet, read_datasheet, add_component_requirement, build, and run_checks.'

// ── Phase 0: reusable implementation discovery ────────────────────
phase('Prepare')
const preparations = (await parallel(BLOCKS.map((b) => () =>
  agent(
    `${TOOL}\n\nPrepare block "${b.stub}" (${b.role}) before any schematic implementation. Its proposed component is "${b.component}".\n\n`
    + `REUSE GATE:\n`
    + `1. Search list_library using the component name, exact MPN from describe_component, and role terms. describe_component returns implementations[] for modules declaring (implements …).\n`
    + `2. For each candidate module, call preview_module with parameters appropriate to this block, inspect every port, and run_checks on the standalone module with profile "preflight". Reject automated requirement failures, ERC errors, stale/incomplete datasheet review, or failed canonical dependencies. Pending manual requirements that depend on the parent/application (for example thermal analysis or VIN>VOUT) are not internal module failures: return each one in parent_requirements so the final parent preflight must verify it.\n`
    + `3. An applicable internally-clean canonical module MUST be selected. Prefer an internally-clean recommended module. Example modules are discovery aids only. A recommended module may be declined only with a concrete interface/package/topology rationale. A canonical mismatch blocks this block; do not silently design around it.\n\n`
    + `DIRECT-COMPONENT INVENTORY:\n`
    + `4. If no module applies, describe_component and inspect datasheet_review. Report whether its existing digest-bound review is complete or needs work; do not edit component or board files in this phase. Return implementation="direct" so the deduplicated Review phase can process the component once. Return implementation="blocked" only for unresolved identity or a canonical interface mismatch.`,
    { label: `prepare:${b.stub}`, phase: 'Prepare', schema: PREP_SCHEMA },
  ).then((r) => ({ component: b.component, stub: b.stub, ...r })),
))).filter(Boolean)
log(`prepared ${preparations.length}/${BLOCKS.length} blocks; ${preparations.filter((p) => p.implementation === 'module').length} use reusable modules`)

// ── Phase 1: one writer-agent per unique direct component ─────────
// Deduplication is intentional: two stubs using the same regulator must never
// race while editing the same lib/components/<name>.sexp review record.
phase('Review')
const directComponents = [...new Set(preparations
  .filter((p) => p.implementation === 'direct')
  .map((p) => p.component)
  .filter(Boolean))]
const reviews = (await parallel(directComponents.map((component) => () =>
  agent(
    `${TOOL}\n\nComplete the pre-schematic datasheet review for the unique direct component "${component}". Reuse a valid complete digest-bound review; otherwise ensure the correct manufacturer PDF is attached, then call read_datasheet with increasing offsets until truncated=false. Use its exact sha256. Review supply, decoupling, pin-straps, sequencing, thermal, and layout. Add every schematic-violable rule as one cited requirement with a machine check whenever supported; do not add capabilities, typical-only facts, duplicates, or uncited rules. Re-describe and reconcile, then edit the component source with a complete (datasheet-review ...) record using categories or reasoned category-na forms and date "${new Date().toISOString().slice(0, 10)}". Never fabricate a digest or mark an unread/ambiguous review complete; return blocked with every blocker.`,
    { label: `review:${component}`, phase: 'Review', schema: REVIEW_SCHEMA },
  )
))).filter(Boolean)
const reviewedComponents = new Set(reviews
  .filter((r) => r.status === 'complete' || r.status === 'not_applicable')
  .map((r) => r.component))
const READY_BLOCKS = BLOCKS.map((b) => ({ ...b, prep: preparations.find((p) => p.stub === b.stub) }))
  .filter((b) => b.prep && (b.prep.implementation === 'module'
    || (b.prep.implementation === 'direct' && reviewedComponents.has(b.prep.component))))
log(`reviewed ${reviewedComponents.size}/${directComponents.length} direct components; ${READY_BLOCKS.length}/${BLOCKS.length} blocks ready`)

// ── Phase 2: design every block in parallel (read-only) ────────────
phase('Design')
const designs = (await parallel(READY_BLOCKS.map((b) => () =>
  agent(
    `${TOOL}\n\nYou are implementing ONE block of the "${design}" schematic (file ${SEXP}).\n`
    + `Block: stub "${b.stub}" — ${b.role}. Preparation selected ${b.prep.implementation === 'module' ? `reusable module "${b.prep.module}" (${b.prep.module_policy})` : `reviewed component "${b.prep.component}"`}.\n`
    + `Label the MAIN instance EXACTLY "${b.stub}" (NOT "U1"). Set ref_des = "${b.stub}".\n\n`
    + `STEPS:\n`
    + `1. read_file ${SEXP} and locate the (stub "${b.stub}" … (id <hex>)) form. Note its (signal "NAME" <class> "NET") list (the external interface) and its (id <hex>).\n`
    + (b.prep.implementation === 'module'
      ? `2. preview_module "${b.prep.module}" again and emit exactly one top-level (sub-block "${b.stub}" (${b.prep.module} <needed-params>) (bridge "" <complete port mapping>) (id <orig-hex>)). Preserve every external net and map every required module port. Do not reproduce its internal IC/passives. imports must include "${b.prep.module}". Parent/application obligations are ${JSON.stringify(b.prep.parent_requirements || [])}. Satisfy them with real evidence; add a (verifies ...) rationale only when that evidence exists, otherwise return them in unresolved so strict preflight blocks.\n`
      : `2. describe_component "${b.prep.component}" and apply every requirement from the completed digest-bound review. Emit the direct main instance plus justified support parts. imports must include "${b.prep.component}".\n`)
    + `3. For house style, you MAY read src/cyclops/cyclops-analog.sexp, but never copy wiring that contradicts the selected module or current datasheet review.\n`
    + `4. Return new_string (the full replacement text for the stub form), plus the imports list (HARD RULE 7). If the prepared interface cannot be mapped without guessing, return the issue in unresolved and do not fabricate a design.\n`
    + RULES,
    { label: `design:${b.stub}`, phase: 'Design', schema: DESIGN_SCHEMA },
  ).then((r) => ({ component: b.prep.component, role: b.role, selected_module: b.prep.module, ...r })),
))).filter(Boolean)
log(`designed ${designs.length}/${READY_BLOCKS.length} prepared blocks`)

// Union of every non-passive component that must be importable: the block components + any extras
// the agents introduced. Passive families are excluded (auto-loaded).
const requiredImports = [...new Set([
  ...READY_BLOCKS.map((b) => b.prep.implementation === 'module' ? b.prep.module : b.prep.component),
  ...designs.flatMap((d) => Array.isArray(d.imports) ? d.imports : []),
])].map((c) => String(c || '').trim()).filter((c) => c && !isFamily(c))

// ── Phase 3: apply — single writer ensures imports, then replaces each stub ─────────
phase('Apply')
const apply = await agent(
  `${TOOL}\n\nApply ${designs.length} designed blocks to ${SEXP}. Single writer — do everything one edit at a time.\n\n`
  + `STEP A — IMPORTS FIRST. read_file ${SEXP}. Find the top-level (import …) form (it sits BEFORE the (design-block …)). `
  + `Ensure it lists EVERY component below; for any that is missing, edit_file to add it to that (import …) form (multi-name form: \`(import a b c …)\`; "#" and "+" in names are fine). `
  + `Do NOT import passive families (cap-*/res-*/ind-*/ferrite-*). If no (import …) form exists, create one immediately before the (design-block …). Report what you added in imports_added.\n`
  + `Components that must be importable:\n${JSON.stringify(requiredImports, null, 1)}\n\n`
  + `STEP B — REPLACE STUBS. For EACH block below, read_file ${SEXP} (fresh), find the exact, complete (stub "<stub>" … (id …)) form, and edit_file replacing that exact text with the block's new_string. `
  + `Do them one at a time. If a stub form can't be matched exactly, skip it and record it in "failed" with the reason. `
  + `Sanity-check each new_string before writing: it must NOT contain a nested (design-block …); its replacement sub-block/main-instance label must equal the stub name (not "U1"); every (pin … "NET") net must be quoted; and every (note …) must have exactly 2 args. If a block violates these, do not guess—skip it and report failed. `
  + `Preserve everything else (the (layout …), comments, other stubs). Do NOT build, commit, push, or export.\n\n`
  + `Blocks (JSON):\n${JSON.stringify(designs.map((d) => ({ stub: d.stub, new_string: d.new_string })), null, 1)}`,
  { schema: APPLY_SCHEMA, phase: 'Apply' },
)
log(`imports added ${(apply.imports_added || []).length}; applied ${(apply.applied || []).length}; failed ${(apply.failed || []).length}`)

// ── Phase 4: unified strict preflight ──────────────────────────────
phase('Verify')
const verify = await agent(
  `${TOOL}\n\nVerify "${design}": (1) build it with profile "preflight"; (2) run_checks with profile "preflight" and no severity filter. `
  + `The unified preflight—not build success alone—is the release gate. Report build_ok, eval_ok, preflight_pass, version, `
  + `erc_errors/erc_warnings, requirement_failures, datasheet_review_failures, and module_policy_failures with a short detail list (rule + count + sample), preflight_summary, and build_error if eval failed. `
  + `Set preflight_pass=false for any unresolved stub/design item, failed or unverified requirement, stale/incomplete datasheet digest review, uncited active-IC rule, or canonical-module violation. `
  + `Do NOT commit, push, export the board, or write the NAS.`,
  { schema: VERIFY_SCHEMA, phase: 'Verify' },
)

// ── Phase 5: repair — ONLY if the build/eval failed (bounded to 2 attempts) ──────────
let repair = null
let lastVerify = verify
for (let attempt = 1; attempt <= 2 && !(lastVerify.build_ok && lastVerify.eval_ok !== false); attempt++) {
  phase('Repair')
  log(`build/eval not green (attempt ${attempt}) — running repair`)
  repair = await agent(
    `${TOOL}\n\nThe "${design}" build did NOT evaluate cleanly. Build error / status: ${JSON.stringify(lastVerify.build_error || lastVerify.preflight_summary || 'unknown')}.\n\n`
    + `The netlisp build reports UnboundVariable / ArityError WITHOUT a symbol name. The known causes (check ${SEXP} for each) are:\n`
    + `  1. A component is referenced but not in the top-level (import …) form → UnboundVariable. Add the missing import.\n`
    + `  2. A net token is unquoted, e.g. (pin 1 GND) → UnboundVariable. Quote it: (pin 1 "GND").\n`
    + `  3. A nested (design-block …) inside the top design-block → remove the wrapper, keep the bare (instance …) forms.\n`
    + `  4. A one-arg (note "…") → ArityError. Make it (note "<ref_des>" "…").\n`
    + `  5. crystal used as a family (crystal "…") → use it bare: (instance "Y…" crystal (pin …)).\n`
    + `If you can't tell which form is at fault, BISECT: write a copy that is the file's head truncated to N lines + a closing ")" and build it; halve N until the error flips. Locate the offending form, fix it in ${SEXP}, and rebuild. `
    + `Make the MINIMUM edits to get eval_ok. Report build_ok, eval_ok, version, the fixes you made, and still_broken if it won't evaluate. Do NOT commit, push, or export.`,
    { schema: REPAIR_SCHEMA, phase: 'Repair' },
  )
  lastVerify = { build_ok: repair.build_ok, eval_ok: repair.eval_ok, version: repair.version, build_error: repair.still_broken }
}

return {
  design,
  blocks_total: BLOCKS.length,
  preparations,
  datasheet_reviews: reviews,
  blocks_designed: designs.map((d) => ({ stub: d.stub, ref_des: d.ref_des, component: d.component, imports: d.imports || [], support_count: d.support_count, assumptions: d.assumptions || [], unresolved: d.unresolved || [], new_string: d.new_string })),
  required_imports: requiredImports,
  apply,
  verify,
  repair,
  next_steps: verify.preflight_pass
    ? 'Review each block and the unified preflight report; a human may then authorize commit/export.'
    : 'Resolve every preparation blocker, unresolved interface, datasheet-review finding, requirement failure, and module-policy finding before commit/export.',
}
