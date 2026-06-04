// implement-blocks — turn each already-IMPORTED (stub …) into a real
// (instance … + support) block, designing all blocks in PARALLEL.
//
// Invoke (defaults to barracuda's 11 imported blocks):
//   Workflow({ scriptPath: ".../implement-blocks.js" })
// or override:
//   Workflow({ scriptPath: "...", args: { design:"barracuda", sexp:"src/barracuda/barracuda.sexp",
//             blocks:[{stub:"ldo_3v3a", component:"lt3042edd#pbf", role:"+3.3V LDO"}, …] } })
//
// Phases:
//   1 Design  one agent per block, READ-ONLY (describe_component + read the stub +
//             mirror cyclops-analog house style) → returns the replacement S-expr text  [parallel]
//   2 Apply   single agent: (a) ensures every referenced component is in the top-level
//             (import …) form, (b) edit_file-replaces each (stub …) with its block.
//             ONE writer, so no write races.                                            [serial]
//   3 Verify  build + run_checks(error) + generate_review                               [serial]
//   4 Repair  ONLY if Verify's build fails: one agent fixes the known build-error
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
  description: 'Design every imported stub into a real instance+support block in parallel, then ensure imports + apply + build + ERC, with an auto-repair pass on build failure',
  phases: [
    { title: 'Design', detail: 'one agent per block, read-only — produce the real (instance …) text' },
    { title: 'Apply', detail: 'single writer: ensure imports, then replace each stub with its block' },
    { title: 'Verify', detail: 'build + ERC + review' },
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
  ✗ Do NOT label the main IC "U1"/"U2"/etc. EVERY block uses "U1" → duplicate ref-des + a pin-merge cascade.
    Label the main instance with the STUB NAME you were given. Support passives get descriptive labels like "C_<stub>_VDD1".
  ✗ Do NOT use a bare net token: (pin 1 GND) evaluates GND as a variable → UnboundVariable. Nets are ALWAYS quoted: (pin 1 "GND").
    (Pin IDS may be bare — alphanumeric BGA pins like (pin A9 B9 "VBUS") are fine.)
  ✗ Do NOT reference any non-passive component you don't list in "imports" (see HARD RULE 7).

HARD RULES:
1. PRESERVE the stub's external nets EXACTLY. Whatever nets the stub's (signal …) forms use
   (e.g. "V_5VA", "GND", "VCO_RF", "SPI_DSA") are this block's interface to the rest of the board —
   the matching pins MUST connect to those same net names, or the board disconnects.
2. KEEP the stub's (id <hex>) on the MAIN instance (stable PCB identity). Support passives need no id (auto-assigned).
3. CONNECT EVERY IC PIN. Every supply pin → its rail with a 100nF (cap-0201/0402) decoupling cap to GND
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
5. Apply datasheet requirements from describe_component (the "requirements" array). Compute real values
   (e.g. LT304x: VOUT = 100uA × RSET → RSET = VOUT/100uA; IN≥4.7uF; OUT≥10uF; EN/UV→IN; ILIM→GND or RILIM;
   PGFB→IN; CSET ~470nF on SET; OUTS Kelvin to VOUT). Respect each pin's RATED VOLTAGE — never tie a pin
   rated ≤3.45V (e.g. a charge-pump VP) to a higher rail like +22V; if no correct rail exists, say so in "unresolved".
   DO NOT invent values you can't justify — list them in "unresolved".
6. RF first-pass: connect RF pins directly to their external RF nets. Where a DC block / bias-tee / balun is
   really required, still connect the net but record it in "unresolved" (don't fabricate the network).
7. IMPORTS: in the "imports" field, list the lib basename of EVERY non-passive component your new_string
   references — the main <component> PLUS any extra IC / crystal / connector you add (e.g. a fanout buffer,
   a TCXO). Do NOT list passive families. The workflow uses this to ensure each is (import …)ed.

OUTPUT new_string = the COMPLETE multi-line replacement text (main instance + every support instance + notes),
correctly balanced parentheses, that will literally REPLACE the (stub …) form. No surrounding prose, no (design-block …).
Be HONEST in "unresolved": list any pin you guessed, any value you couldn't derive, any support network you skipped.`

const DESIGN_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    stub: { type: 'string' },
    ref_des: { type: 'string', description: 'the label on the main instance — MUST equal the stub name' },
    new_string: { type: 'string' },
    imports: { type: 'array', items: { type: 'string' }, description: 'lib basenames of every non-passive component referenced (main + extras), excluding passive families' },
    support_count: { type: 'number', description: 'number of support passives added' },
    assumptions: { type: 'array', items: { type: 'string' } },
    unresolved: { type: 'array', items: { type: 'string' } },
  },
  required: ['stub', 'new_string', 'imports'],
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
    eval_ok: { type: 'boolean' },
    version: { type: 'number' },
    erc_errors: { type: 'number' },
    erc_warnings: { type: 'number' },
    erc_detail: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { severity: { type: 'string' }, rule: { type: 'string' }, detail: { type: 'string' } }, required: ['rule'] } },
    review_summary: { type: 'string' },
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

const TOOL = 'Use the eda MCP tools (prefixed mcp__eda__) via ToolSearch: read_file, describe_component, list_library, edit_file, build, run_checks, generate_review.'

// ── Phase 1: design every block in parallel (read-only) ────────────
phase('Design')
const designs = (await parallel(BLOCKS.map((b) => () =>
  agent(
    `${TOOL}\n\nYou are implementing ONE block of the "${design}" schematic (file ${SEXP}).\n`
    + `Block: stub "${b.stub}" — ${b.role}. The imported real component is "${b.component}".\n`
    + `Label the MAIN instance EXACTLY "${b.stub}" (NOT "U1"). Set ref_des = "${b.stub}".\n\n`
    + `STEPS:\n`
    + `1. read_file ${SEXP} and locate the (stub "${b.stub}" … (id <hex>)) form. Note its (signal "NAME" <class> "NET") list (the external interface) and its (id <hex>).\n`
    + `2. describe_component "${b.component}" → the real pin numbers, pin functions, RATED voltages, and the datasheet "requirements" array.\n`
    + `3. For house style, you MAY read src/cyclops/cyclops-analog.sexp — it implements ADF4159 / LMX / LT3045 / LDO decoupling / SPI CS pull-ups for real; mirror its conventions.\n`
    + `4. Design a correct FIRST-PASS block and return new_string (the full replacement text for the stub form), plus the "imports" list (HARD RULE 7).\n`
    + RULES,
    { label: `design:${b.stub}`, phase: 'Design', schema: DESIGN_SCHEMA },
  ).then((r) => ({ component: b.component, role: b.role, ...r })),
))).filter(Boolean)
log(`designed ${designs.length}/${BLOCKS.length} blocks`)

// Union of every non-passive component that must be importable: the block components + any extras
// the agents introduced. Passive families are excluded (auto-loaded).
const requiredImports = [...new Set([
  ...BLOCKS.map((b) => b.component),
  ...designs.flatMap((d) => Array.isArray(d.imports) ? d.imports : []),
])].map((c) => String(c || '').trim()).filter((c) => c && !isFamily(c))

// ── Phase 2: apply — single writer ensures imports, then replaces each stub ─────────
phase('Apply')
const apply = await agent(
  `${TOOL}\n\nApply ${designs.length} designed blocks to ${SEXP}. Single writer — do everything one edit at a time.\n\n`
  + `STEP A — IMPORTS FIRST. read_file ${SEXP}. Find the top-level (import …) form (it sits BEFORE the (design-block …)). `
  + `Ensure it lists EVERY component below; for any that is missing, edit_file to add it to that (import …) form (multi-name form: \`(import a b c …)\`; "#" and "+" in names are fine). `
  + `Do NOT import passive families (cap-*/res-*/ind-*/ferrite-*). If no (import …) form exists, create one immediately before the (design-block …). Report what you added in imports_added.\n`
  + `Components that must be importable:\n${JSON.stringify(requiredImports, null, 1)}\n\n`
  + `STEP B — REPLACE STUBS. For EACH block below, read_file ${SEXP} (fresh), find the exact, complete (stub "<stub>" … (id …)) form, and edit_file replacing that exact text with the block's new_string. `
  + `Do them one at a time. If a stub form can't be matched exactly, skip it and record it in "failed" with the reason. `
  + `Sanity-check each new_string before writing: it must NOT contain a nested (design-block …), its main instance label must equal the stub name (not "U1"), every (pin … "NET") net must be quoted, and every (note …) must have exactly 2 args — if a block violates these, fix it inline as you apply it and note the fix in "failed" reason (or applied list). `
  + `Preserve everything else (the (layout …), comments, other stubs). Do NOT build, commit, push, or export.\n\n`
  + `Blocks (JSON):\n${JSON.stringify(designs.map((d) => ({ stub: d.stub, new_string: d.new_string })), null, 1)}`,
  { schema: APPLY_SCHEMA, phase: 'Apply' },
)
log(`imports added ${(apply.imports_added || []).length}; applied ${(apply.applied || []).length}; failed ${(apply.failed || []).length}`)

// ── Phase 3: verify ────────────────────────────────────────────────
phase('Verify')
const verify = await agent(
  `${TOOL}\n\nVerify "${design}": (1) build it; (2) run_checks severity "error" and note the warning count; `
  + `(3) generate_review and give a one-line summary (BOM size, unresolved count). Report build_ok, eval_ok, version, `
  + `erc_errors/erc_warnings with a short erc_detail list (rule + count + a sample), review_summary, and build_error if eval failed. `
  + `Do NOT commit, push, export the board, or write the NAS.`,
  { schema: VERIFY_SCHEMA, phase: 'Verify' },
)

// ── Phase 4: repair — ONLY if the build/eval failed (bounded to 2 attempts) ──────────
let repair = null
let lastVerify = verify
for (let attempt = 1; attempt <= 2 && !(lastVerify.build_ok && lastVerify.eval_ok !== false); attempt++) {
  phase('Repair')
  log(`build/eval not green (attempt ${attempt}) — running repair`)
  repair = await agent(
    `${TOOL}\n\nThe "${design}" build did NOT evaluate cleanly. Build error / status: ${JSON.stringify(lastVerify.build_error || lastVerify.review_summary || 'unknown')}.\n\n`
    + `The eda build reports UnboundVariable / ArityError WITHOUT a symbol name. The known causes (check ${SEXP} for each) are:\n`
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
  blocks_designed: designs.map((d) => ({ stub: d.stub, ref_des: d.ref_des, component: d.component, imports: d.imports || [], support_count: d.support_count, assumptions: d.assumptions || [], unresolved: d.unresolved || [], new_string: d.new_string })),
  required_imports: requiredImports,
  apply,
  verify,
  repair,
  next_steps: 'Review each block (esp. its "unresolved" items + the ERC report). Then a human can refine values, add the not-yet-imported blocks, seal ICs in defmodule+sub-block to clear main_ic_in_design, and (with authorization) commit / export.',
}
