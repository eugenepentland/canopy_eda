// implement-design — turn a (stub …)-based EDA design into a real, built,
// ERC-checked implementation.
//
// Invoke:  Workflow({ name: "implement-design", args: { design: "barracuda" } })
//
// What it does, per phase:
//   0 Introspect   read the design .sexp, enumerate every (stub …)              [serial]
//   1 Resolve MPNs one agent per stub → DigiKey resolve_mpn → real MPN          [parallel]
//   2 Import       one agent per MPN → CSE download_footprint → lib/ entries     [parallel]
//   3 Promote      rewrite each imported (stub …) as (instance …) with real pins [serial]
//   4 Verify       build + run_checks (ERC) + generate_review                    [serial]
//
// Parallelism is in phases 1–2 (the slow external lookups); the server-side
// rate limiters (CSE / DigiKey) throttle the actual HTTP so the fan-out can't
// trip a 429. Everything that edits the single .sexp (0, 3, 4) is serial to
// avoid write races.
//
// SAFETY: this workflow never commits, pushes, exports to the KiCad board, or
// writes the NAS — it stops at build+ERC+review and hands back a report for a
// human to inspect and approve. Requires the eda MCP server connected (its
// tools — read_file, edit_file, resolve_mpn, download_footprint, build,
// run_checks, generate_review — are reached by sub-agents via ToolSearch).

export const meta = {
  name: 'implement-design',
  description: 'Resolve every stub in an EDA design to a real part, import footprints, promote stubs to instances, then build + ERC + review (no commit/export)',
  phases: [
    { title: 'Introspect', detail: 'read the .sexp, enumerate stubs' },
    { title: 'Resolve MPNs', detail: 'per-stub DigiKey lookup (parallel, rate-limited)' },
    { title: 'Import', detail: 'per-MPN CSE footprint download (parallel, rate-limited)' },
    { title: 'Promote', detail: 'rewrite stubs as instances with real pins' },
    { title: 'Verify', detail: 'build + ERC + review' },
  ],
}

const STUB_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    stubs: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          name: { type: 'string' },
          ref_des: { type: 'string' },
          mpn_raw: { type: 'string' },
          role: { type: 'string' },
          category: { type: 'string' },
          signals: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              properties: { name: { type: 'string' }, class: { type: 'string' }, net: { type: 'string' } },
              required: ['name', 'net'],
            },
          },
        },
        required: ['name', 'mpn_raw', 'signals'],
      },
    },
  },
  required: ['stubs'],
}

const MPN_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    primary_mpn: { type: 'string' },
    mpn: { type: 'string' },
    manufacturer: { type: 'string' },
    datasheet_url: { type: 'string' },
    candidates: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: { mpn: { type: 'string' }, manufacturer: { type: 'string' }, description: { type: 'string' } },
        required: ['mpn'],
      },
    },
    also: { type: 'string', description: 'other parts named in the stub hint, if it bundled several' },
    note: { type: 'string' },
  },
  required: ['mpn'],
}

const IMPORT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    status: { type: 'string', enum: ['success', 'not_found', 'import_error', 'timeout'] },
    component: { type: 'string' },
    footprint: { type: 'string' },
    pinout: { type: 'string' },
    has_3d_model: { type: 'boolean' },
    error: { type: 'string' },
  },
  required: ['status'],
}

const PROMO_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    promoted: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          stub: { type: 'string' },
          ref_des: { type: 'string' },
          component: { type: 'string' },
          pins: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              properties: { pin: { type: 'string' }, net: { type: 'string' } },
              required: ['pin', 'net'],
            },
          },
        },
        required: ['stub', 'component'],
      },
    },
    skipped: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: { stub: { type: 'string' }, reason: { type: 'string' } },
        required: ['stub', 'reason'],
      },
    },
    ambiguous_pin_mappings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: { stub: { type: 'string' }, signal: { type: 'string' }, note: { type: 'string' } },
        required: ['stub', 'signal'],
      },
    },
  },
  required: ['promoted'],
}

const VERIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    build_ok: { type: 'boolean' },
    version: { type: 'number' },
    erc_errors: { type: 'number' },
    erc_warnings: { type: 'number' },
    erc_detail: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: { severity: { type: 'string' }, rule: { type: 'string' }, detail: { type: 'string' } },
        required: ['rule'],
      },
    },
    review_summary: { type: 'string' },
  },
  required: ['build_ok'],
}

// ── Parameters ────────────────────────────────────────────────────
const design = (args && typeof args === 'object' && args.design) || (typeof args === 'string' && args) || null
if (!design) throw new Error('implement-design: pass the design name, e.g. { args: { design: "barracuda" } }')

const tool_note =
  'Find and use the eda MCP tools via ToolSearch (they are prefixed by the eda server id). '
  + 'If the eda MCP server is not connected, stop and report that — do not guess.'

// ── Phase 0: introspect ───────────────────────────────────────────
phase('Introspect')
const inv = await agent(
  `${tool_note}\n\nRead the source of EDA design "${design}" (use read_file / glob / list_designs to locate its .sexp under projects/designs). `
  + `Extract EVERY (stub …) form: its name (the quoted key), ref_des if explicit, the (mpn "…") string verbatim as mpn_raw, (category …), and each (signal "NAME" class "NET") as {name, class, net}. Return the full stub inventory.`,
  { schema: STUB_SCHEMA, phase: 'Introspect' },
)
log(`introspected ${inv.stubs.length} stubs in "${design}"`)

// ── Phase 1: resolve MPNs (parallel, rate-limited by the DigiKey limiter) ──
phase('Resolve MPNs')
const to_resolve = inv.stubs.filter((s) => s.mpn_raw && s.mpn_raw.trim().length > 0)
const resolved = (await parallel(to_resolve.map((s) => () =>
  agent(
    `${tool_note}\n\nResolve the real manufacturer part number for stub "${s.name}" (role: ${s.role || 'n/a'}, category: ${s.category || 'n/a'}). `
    + `Its mpn hint is: "${s.mpn_raw}". First normalize to a PRIMARY mpn — the part code before any "—", "+", "×", or space (e.g. "HMC733 — VCO" → "HMC733", "2× HFCW-9500+ + …" → "HFCW-9500+"). `
    + `Then call resolve_mpn with that primary mpn to get candidates. Return the best mpn + manufacturer + datasheet_url and the candidate list. If the hint clearly bundles several distinct parts, resolve the first and put the rest in "also".`,
    { label: `resolve:${s.name}`, phase: 'Resolve MPNs', schema: MPN_SCHEMA },
  ).then((r) => ({ stub: s.name, ...r })),
))).filter(Boolean)
log(`resolved ${resolved.length}/${to_resolve.length} MPNs`)

// ── Phase 2: import footprints (parallel, rate-limited by the CSE limiter) ──
phase('Import')
const imported = (await parallel(resolved.filter((r) => r.mpn).map((r) => () =>
  agent(
    `${tool_note}\n\nDownload and import the ECAD model for MPN "${r.mpn}" (manufacturer "${r.manufacturer || ''}") using download_footprint. `
    + `Report status: "success" with the created component/footprint/pinout library names + whether a 3D model came through; or "not_found"/"import_error"/"timeout" with a short error. Do NOT retry more than once — surface failures for human follow-up instead of looping.`,
    { label: `import:${r.stub}`, phase: 'Import', schema: IMPORT_SCHEMA },
  ).then((x) => ({ stub: r.stub, mpn: r.mpn, manufacturer: r.manufacturer || '', ...x })),
))).filter(Boolean)
const ok_imports = imported.filter((i) => i.status === 'success')
log(`imported ${ok_imports.length}/${imported.length} footprints`)

// ── Phase 3: promote stubs → instances (serial — single agent edits one file) ──
phase('Promote')
const promo = await agent(
  `${tool_note}\n\nPromote the successfully-imported stubs of design "${design}" from (stub …) placeholders to real (instance …) forms, editing the design .sexp with edit_file (surgical edits — preserve comments, formatting, and ordering).\n\n`
  + `For each imported stub below: read the component's pinout (lib/pinouts/<pinout>.sexp) to map each stub signal NAME to a physical pin NUMBER, then replace\n`
  + `  (stub "<name>" … (signal "SIG" <class> "NET") … (id <hex>))\n`
  + `with\n`
  + `  (instance "<ref_des>" (<component>) (pin <n> "NET") …)\n`
  + `preserving every signal's net, the ref_des, and any (note …). Leave un-imported stubs untouched as stubs.\n\n`
  + `CRITICAL: when a stub signal name has no obvious matching pin (e.g. "GND" vs a pin named "VSS"/"PAD"), DO NOT guess — record it in ambiguous_pin_mappings for human review and skip that pin. Do not commit, push, or run any export.\n\n`
  + `Imported stubs (with their full signal lists from the inventory):\n`
  + `${JSON.stringify(ok_imports.map((i) => ({ ...i, signals: (inv.stubs.find((s) => s.name === i.stub) || {}).signals, ref_des: (inv.stubs.find((s) => s.name === i.stub) || {}).ref_des })), null, 1)}`,
  { schema: PROMO_SCHEMA, phase: 'Promote' },
)
log(`promoted ${promo.promoted.length} stubs; ${(promo.ambiguous_pin_mappings || []).length} ambiguous pin mappings flagged`)

// ── Phase 4: build + ERC + review (serial) ────────────────────────
phase('Verify')
const verify = await agent(
  `${tool_note}\n\nVerify design "${design}" after the stub promotion: (1) build it; (2) run_checks at severity "error" (and note warning count); (3) generate_review and give a one-line summary (BOM size, unresolved count). `
  + `Report build_ok, version, erc_errors/erc_warnings with a short erc_detail list, and review_summary. `
  + `Do NOT commit, push, export to the KiCad board, or write any NAS file — stop here for human review.`,
  { schema: VERIFY_SCHEMA, phase: 'Verify' },
)

return {
  design,
  stub_count: inv.stubs.length,
  resolved,
  imported,
  promoted: promo,
  verify,
  next_steps: 'Review the promoted .sexp, the ambiguous pin mappings, and the ERC report. Then a human can commit, export-kicad, and (with explicit authorization) sync the board.',
}
