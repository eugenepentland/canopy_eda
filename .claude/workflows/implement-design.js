// implement-design — turn a (stub …)-based netlisp design into a reusable-module-
// aware, datasheet-reviewed implementation that passes strict preflight.
//
// Invoke:  Workflow({ name: "implement-design", args: { design: "barracuda" } })
//
// What it does, per phase:
//   0 Introspect   read the design .sexp, enumerate every (stub …)              [serial]
//   1 Resolve MPNs one agent per stub → DigiKey resolve_mpn → real MPN          [parallel]
//   2 Discover     prefer canonical/recommended modules and existing parts      [parallel]
//   3 Import       download footprints only for parts genuinely missing         [parallel]
//   4 Review       read every active-IC datasheet window; record cited rules     [parallel]
//   5 Promote      use sub-blocks where possible; direct instances otherwise     [serial]
//   6 Preflight    build + strict unified checks (ERC + requirements + reuse)     [serial]
//
// Parallelism is in resolve, discovery, import, and datasheet-review phases; server-side
// rate limiters (CSE / DigiKey) throttle the actual HTTP so the fan-out can't
// trip a 429. Everything that edits the single .sexp (0, 3, 4) is serial to
// avoid write races.
//
// SAFETY: this workflow never commits, pushes, exports to the KiCad board, or
// writes the NAS — it stops at build+preflight and hands back a report for a
// human to inspect and approve. Requires the netlisp MCP server connected (its
// tools — read/edit, library search, datasheet/requirement tools, build, and
// run_checks — are reached by sub-agents via ToolSearch).

export const meta = {
  name: 'implement-design',
  description: 'Resolve stubs, reuse canonical modules, complete cited datasheet reviews, implement, then pass strict preflight (no commit/export)',
  phases: [
    { title: 'Introspect', detail: 'read the .sexp, enumerate stubs' },
    { title: 'Resolve MPNs', detail: 'per-stub DigiKey lookup (parallel, rate-limited)' },
    { title: 'Discover reuse', detail: 'find existing components and canonical/recommended modules before downloading' },
    { title: 'Import', detail: 'download only genuinely missing ECAD models (parallel, rate-limited)' },
    { title: 'Datasheet review', detail: 'read the full datasheet and record cited requirements before implementation' },
    { title: 'Promote', detail: 'replace stubs with reusable sub-blocks or reviewed direct instances' },
    { title: 'Preflight', detail: 'build + unified strict checks' },
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

const REUSE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    stub: { type: 'string' },
    status: { type: 'string', enum: ['module', 'component', 'missing', 'blocked'] },
    component: { type: 'string' },
    module: { type: 'string' },
    module_policy: { type: 'string', enum: ['canonical', 'recommended', 'example'] },
    reason: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
    parent_requirements: { type: 'array', description: 'manual/application obligations carried into the parent design', items: {
      type: 'object', additionalProperties: false,
      properties: { ref_des: { type: 'string' }, requirement_id: { type: 'string' }, text: { type: 'string' } },
      required: ['requirement_id', 'text'],
    } },
  },
  required: ['stub', 'status'],
}

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    component: { type: 'string' },
    status: { type: 'string', enum: ['complete', 'not_applicable', 'blocked'] },
    datasheet: { type: 'string' },
    sha256: { type: 'string' },
    requirements_added: { type: 'array', items: { type: 'string' } },
    categories: { type: 'array', items: { type: 'string' } },
    blockers: { type: 'array', items: { type: 'string' } },
  },
  required: ['component', 'status'],
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
          implementation: { type: 'string', enum: ['module', 'direct'] },
          module: { type: 'string' },
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
        required: ['stub', 'implementation'],
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
    preflight_pass: { type: 'boolean' },
    version: { type: 'number' },
    erc_errors: { type: 'number' },
    erc_warnings: { type: 'number' },
    requirement_failures: { type: 'number' },
    datasheet_review_failures: { type: 'number' },
    module_policy_failures: { type: 'number' },
    erc_detail: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: { severity: { type: 'string' }, rule: { type: 'string' }, detail: { type: 'string' } },
        required: ['rule'],
      },
    },
    preflight_summary: { type: 'string' },
  },
  required: ['build_ok'],
}

// ── Parameters ────────────────────────────────────────────────────
// args may arrive as an object, a bare string ("barracuda"), or a JSON string
// ('{"design":"barracuda"}') depending on how the runtime serialized it — normalize all three.
let _a = args
if (typeof _a === 'string') { try { const p = JSON.parse(_a); if (p && typeof p === 'object') _a = p } catch (_e) { /* bare string design name */ } }
const design = (_a && typeof _a === 'object' && _a.design) || (typeof _a === 'string' && _a) || null
if (!design) throw new Error('implement-design: pass the design name, e.g. { args: { design: "barracuda" } }')

const tool_note =
  'Find and use the netlisp MCP tools via ToolSearch (they are prefixed by the netlisp server id). '
  + 'If the netlisp MCP server is not connected, stop and report that — do not guess.'

// ── Phase 0: introspect ───────────────────────────────────────────
phase('Introspect')
const inv = await agent(
  `${tool_note}\n\nRead the source of netlisp design "${design}" (use read_file / glob / list_designs to locate its .sexp under projects/designs). `
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

// ── Phase 2: discover reusable implementations before any library mutation ──
phase('Discover reuse')
const reuse = (await parallel(resolved.filter((r) => r.mpn).map((r) => () =>
  agent(
    `${tool_note}\n\nBefore downloading anything for stub "${r.stub}" / MPN "${r.mpn}", search the existing library. `
    + `Use list_library with the exact MPN, normalized component name, role terms, and category terms; describe every plausible exact component. `
    + `describe_component returns implementations[] when a reusable module declares (implements …). For every candidate, call preview_module with suitable parameters and run_checks on the standalone module with profile "preflight". Reject interface mismatches, automated requirement failures, ERC errors, stale/incomplete reviews, and failed canonical dependencies. Pending manual requirements that depend on the parent/application are obligations, not internal module failures: return them in parent_requirements so the final parent preflight must verify them. Prefer an internally-clean canonical module. Prefer an internally-clean recommended module when its ports and parameters fit this stub; do not use an example module as production implementation. `
    + `Return status "module" with module + policy when reusable, "component" when the exact component exists but no applicable reusable module does, "missing" only when the exact component truly is absent, or "blocked" when identity/interface is ambiguous. `
    + `A topology difference is not enough to silently bypass a canonical module: report the concrete port/parameter mismatch. Do not edit files or download a footprint in this phase.`,
    { label: `reuse:${r.stub}`, phase: 'Discover reuse', schema: REUSE_SCHEMA },
  ).then((x) => ({ stub: r.stub, ...x })),
))).filter(Boolean)
log(`reuse discovery: ${reuse.filter((r) => r.status === 'module').length} modules, ${reuse.filter((r) => r.status === 'component').length} existing components, ${reuse.filter((r) => r.status === 'missing').length} missing`)

// ── Phase 3: import only genuinely missing footprints ─────────────
phase('Import')
const missing = reuse.filter((x) => x.status === 'missing')
const imported = (await parallel(missing.map((x) => () => {
  const r = resolved.find((candidate) => candidate.stub === x.stub) || x
  return agent(
    `${tool_note}\n\nReuse discovery proved that MPN "${r.mpn}" (manufacturer "${r.manufacturer || ''}") is not in the project. Download and import its ECAD model using download_footprint. `
    + `Report status: "success" with the created component/footprint/pinout library names + whether a 3D model came through; or "not_found"/"import_error"/"timeout" with a short error. Do NOT retry more than once — surface failures for human follow-up instead of looping.`,
    { label: `import:${r.stub}`, phase: 'Import', schema: IMPORT_SCHEMA },
  ).then((result) => ({ stub: r.stub, mpn: r.mpn, manufacturer: r.manufacturer || '', ...result }))
}))).filter(Boolean)
const ok_imports = imported.filter((i) => i.status === 'success')
log(`imported ${ok_imports.length}/${imported.length} footprints`)

// ── Phase 4: complete datasheet reviews before direct instantiation ──
phase('Datasheet review')
const directByStub = [
  ...reuse.filter((x) => x.status === 'component').map((x) => ({ stub: x.stub, component: x.component })),
  ...ok_imports.map((x) => ({ stub: x.stub, component: x.component })),
].filter((x) => x.component)
const directComponents = [...new Set(directByStub.map((x) => x.component))]
const reviews = (await parallel(directComponents.map((component) => () =>
  agent(
    `${tool_note}\n\nComplete the pre-schematic datasheet review for component "${component}". First describe_component. Simple passive/mechanical parts may return not_applicable with a concrete reason; active or complicated ICs MUST complete every step below before any design may directly instantiate them.\n\n`
    + `1. Ensure the correct manufacturer datasheet is attached; if missing, use download_datasheet, then describe_component again.\n`
    + `2. Call read_datasheet repeatedly with increasing offsets until truncated=false. Do not review only the first window. Record the exact sha256 returned by read_datasheet; if it is unavailable, return blocked rather than inventing a digest.\n`
    + `3. Review all six strict categories: supply, decoupling, pin-straps, sequencing, thermal, layout. For each applicable schematic-violable rule, use add_component_requirement with one rule per requirement, a short page/quote citation, and a machine check whenever the grammar supports it. Do not add capabilities or duplicate requirements.\n`
    + `4. Re-describe the component and reconcile all cited requirements. Then edit its component .sexp to add or replace this exact completion form, using the real datasheet filename and digest:\n`
    + `   (datasheet-review (datasheet "...") (sha256 "<64 lowercase hex>") (status complete) (reviewed-by "Codex workflow") (date "${new Date().toISOString().slice(0, 10)}") (category supply) (category decoupling) (category pin-straps) (category sequencing) (category thermal) (category layout))\n`
    + `If a category is genuinely inapplicable, replace its category form with (category-na <category> "specific non-empty rationale"). Never mark status complete while any source ambiguity, uncited rule, unread window, or unresolved applicability remains. Return blocked with every blocker instead.`,
    { label: `datasheet:${component}`, phase: 'Datasheet review', schema: REVIEW_SCHEMA },
  )
))).filter(Boolean)
const reviewedComponents = new Set(reviews.filter((r) => r.status === 'complete' || r.status === 'not_applicable').map((r) => r.component))
log(`datasheet review: ${reviews.filter((r) => r.status === 'complete').length} complete, ${reviews.filter((r) => r.status === 'blocked').length} blocked`)

const ready = [
  ...reuse.filter((x) => x.status === 'module').map((x) => ({
    stub: x.stub,
    implementation: 'module',
    module: x.module,
    module_policy: x.module_policy,
    parent_requirements: x.parent_requirements || [],
  })),
  ...directByStub.filter((x) => reviewedComponents.has(x.component)).map((x) => ({ ...x, implementation: 'direct' })),
]

// ── Phase 5: promote stubs (serial — single agent edits one file) ──
phase('Promote')
const promo = await agent(
  `${tool_note}\n\nPromote only the reuse- and datasheet-approved stubs of design "${design}", editing the .sexp surgically and preserving comments, formatting, ordering, and ids.\n\n`
  + `For implementation="module", import the module, inspect it with preview_module, then replace the stub with a (sub-block …) whose bridge maps every external stub signal to a real module port. Preserve the stub id on the sub-block. Evaluate every parent_requirements obligation against real parent-design evidence. Add (verifies …) only with a concrete rationale and matching requirement id; leave unverifiable obligations for strict preflight to block. Never guess a bridge or bypass a canonical module; if its interface cannot represent the stub, leave the stub untouched and record skipped.\n\n`
  + `For implementation="direct", import and describe the reviewed component, map each stub signal NAME to a physical pin NUMBER, then replace\n`
  + `  (stub "<name>" … (signal "SIG" <class> "NET") … (id <hex>))\n`
  + `with\n`
  + `  (instance "<ref_des>" <component> (pin <n> "NET") …)\n`
  + `preserving every signal net, ref_des, id, and note. Leave blocked/unreviewed stubs untouched.\n\n`
  + `CRITICAL: when a stub signal name has no obvious matching pin (e.g. "GND" vs a pin named "VSS"/"PAD"), DO NOT guess — record it in ambiguous_pin_mappings for human review and skip that pin. Do not commit, push, or run any export.\n\n`
  + `Approved implementations (with full stub interfaces):\n`
  + `${JSON.stringify(ready.map((candidate) => ({ ...candidate, signals: (inv.stubs.find((s) => s.name === candidate.stub) || {}).signals, ref_des: (inv.stubs.find((s) => s.name === candidate.stub) || {}).ref_des })), null, 1)}`,
  { schema: PROMO_SCHEMA, phase: 'Promote' },
)
log(`promoted ${promo.promoted.length} stubs; ${(promo.ambiguous_pin_mappings || []).length} ambiguous pin mappings flagged`)

// ── Phase 6: build + unified strict preflight ─────────────────────
phase('Preflight')
const verify = await agent(
  `${tool_note}\n\nVerify design "${design}" after promotion: (1) build it with profile "preflight"; (2) call run_checks with profile "preflight" and no severity filter. This unified result is the release gate: it includes ERC, requirement outcomes, canonical-module policy, and datasheet-review completeness/digest checks. `
  + `Report preflight_pass=false if any error, failed requirement, incomplete/stale datasheet review, uncited active-IC requirement, canonical-module bypass, unresolved stub, or ambiguous mapping remains. Include counts for ERC errors/warnings, requirement_failures, datasheet_review_failures, and module_policy_failures plus a concise summary. A successful build alone is never a pass. `
  + `Do NOT commit, push, export to the KiCad board, or write any NAS file — stop here for human review.`,
  { schema: VERIFY_SCHEMA, phase: 'Preflight' },
)

return {
  design,
  stub_count: inv.stubs.length,
  resolved,
  reuse,
  imported,
  datasheet_reviews: reviews,
  promoted: promo,
  verify,
  next_steps: verify.preflight_pass
    ? 'Review the promoted .sexp and unified preflight report. Then a human may authorize commit/export.'
    : 'Resolve every blocked datasheet review, module-interface mismatch, ambiguous mapping, and preflight finding before commit/export.',
}
