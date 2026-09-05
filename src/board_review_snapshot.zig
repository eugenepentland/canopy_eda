//! Read-only board evidence assembly for system review packages.
//!
//! This is the shared seam the old review endpoints were missing: one
//! evaluator instance produces the Markdown, PDF, JSON, BOM and physical PCB
//! preview, and the requested saved layout is threaded into both the thermal
//! scenarios and the physical render. The function never persists generated
//! IDs or rewrites a BOM sidecar, so draft review exports stay read-only.

const std = @import("std");
const build_id = @import("build_id.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const ids = @import("eval/ids.zig");
const env_mod = @import("eval/env.zig");
const erc = @import("erc.zig");
const frequency_plan = @import("frequency_plan.zig");
const pll_loop = @import("pll_loop.zig");
/// The shared declared-vs-saved outline predicate — the SAME comparison the
/// readiness `outline-drift` finding makes, called rather than restated. It
/// also carries the fab view's outline rectangle and arc types, so this file
/// still names no placement-optimizer symbol of its own.
const outline_mod = @import("placement/outline.zig");
const power_budget = @import("eval/power_budget.zig");
const thermal = @import("eval/thermal.zig");
const export_pdf = @import("export_pdf.zig");
const export_kicad = @import("export_kicad.zig");
const export_kicad_footprint = @import("export_kicad_footprint.zig");
const fab_readiness = @import("fab_readiness.zig");
const fab_release = @import("fab_release.zig");
const flat_netlist = @import("flat_netlist.zig");
const system_sexp = @import("system_sexp.zig");
const infra_fs = @import("infra/fs.zig");
const net_name = @import("net_name.zig");
const paths = @import("paths.zig");
const pdf = @import("pdf.zig");
const render_pcb_png = @import("render_pcb_png.zig");
const optimizer = @import("placement/optimizer.zig");
const req_checks = @import("req_checks.zig");
const review = @import("review.zig");
const review_json = @import("review_json.zig");
const review_md = @import("review_md.zig");
const review_thermal = @import("review_thermal.zig");
const thermal_scenarios = @import("thermal_scenarios.zig");
const review_assets = @import("system_review_assets.zig");
const zipfile = @import("zipfile.zig");
const block_diagram = @import("diagram/diagram.zig");
const membership = @import("diagram/membership.zig");
const bom_html = @import("serve/bom_html.zig");
const mcp_tools = @import("serve/mcp_tools.zig");
const notes = @import("serve/notes.zig");
const pcb = @import("serve/pcb_layout_page.zig");
const thermal_api = @import("serve/thermal_api.zig");

/// mirror-of: serve/api.zig.max_source_bytes
const max_source_bytes = 10 * 1024 * 1024;
const max_source_closure_bytes = 64 * 1024 * 1024;
const max_source_closure_entries = 4096;

/// Physical-view and output choices for one board snapshot.
pub const Options = struct {
    /// Exact saved layout named by the system manifest. Null retains the
    /// board-level blessed-layout fallback for backward-compatible manifests.
    layout: ?[]const u8 = null,
    pdf_theme: @import("svg2pdf.zig").Theme = .print,
    pcb_width: u32 = 1400,
    /// Stable connector handles whose evaluated pin/net observations must be
    /// retained for system-level interface validation.
    connectors: []const []const u8 = &.{},
};

/// One evaluated connector contact, retained independently of the evaluator.
pub const Connection = struct {
    connector: []const u8,
    pin: []const u8,
    net: []const u8,
};

/// One connector endpoint's complete pad table, retained beside the wired
/// `connections` so a system contract can tell a pad the netlist leaves
/// unconnected from a pad the connector does not have at all. `pads` is empty
/// when the instance resolves no pinout, which is absent evidence rather than
/// a connector with no contacts.
pub const ConnectorPads = struct {
    connector: []const u8,
    pads: []const []const u8,
};

/// Retention ceilings for the engineering evidence below. A system document
/// quotes headline numbers and a bounded list of the worst offenders; the
/// complete lists already travel as `review.json` beside it, so nothing is
/// lost by capping here — and the caps keep one pathological board from
/// growing the analysis, the Markdown and the PDF without limit.
const max_retained_rails: usize = 64;
const max_retained_erc_findings: usize = 32;
const max_retained_pll_reports: usize = 16;
const max_retained_pll_screens: usize = 32;
const max_retained_schedule_entries: usize = 32;
const max_retained_frequency_reports: usize = 8;
const max_retained_frequency_screens: usize = 32;
/// One sideband plan enumerates at most `frequency_plan.max_products` (83)
/// rows today, so this ceiling does not bite on any authorable declaration —
/// it is the bound that keeps a future order limit from growing the document
/// without one. A section that truncates says so in its own rendered text.
const max_retained_spur_products: usize = 96;

/// What declared the rail and how much it can deliver. Grouped because a
/// source without its capacity says nothing a budget table can use.
pub const RailSource = struct {
    /// Sub-block output port path that sources the rail, or "" when undeclared.
    label: []const u8 = "",
    max_a: ?f64 = null,
};

/// One rail's budget row, retained independently of the evaluated design.
pub const PowerRail = struct {
    net: []const u8,
    /// Declared nominal rail voltage (V), or null when nothing declared one.
    nominal_v: ?f64 = null,
    source: RailSource = .{},
    load_max_a: f64 = 0,
    margin_pct: ?f64 = null,
    status: power_budget.RailStatus = .no_source,
    /// Per-device consumer rows behind `load_max_a`, counted rather than
    /// retained: the full breakdown is already in the board's `review.json`.
    consumers: usize = 0,
};

/// The part the board's heat hangs on.
pub const HottestPart = struct {
    ref_des: []const u8 = "",
    watts: f64 = 0,
};

/// Ambient window (°C) the whole board is good for. Either edge stays null
/// when nothing on the board constrains it.
pub const AmbientWindow = struct {
    max_c: ?f64 = null,
    min_c: ?f64 = null,
};

/// Which thermal model answered, and what the other one said.
///
/// Two models screen the same board. `eval/thermal.zig` scales one datasheet
/// theta-JA per part, and a datasheet theta-JA is measured on the JEDEC 2s2p
/// board (76 x 114 mm), so it is systematically OPTIMISTIC for anything
/// smaller. The cooling ladder in `thermal_scenarios.zig` reads the junctions a
/// spreader computed over the board's actual outline, stackup and part
/// positions. Where they disagree the ladder is the board being built, so the
/// snapshot's headline `Thermal.verdict` is the ladder's whenever there is one
/// and the datasheet answer is retained here, demoted and labelled.
pub const ThermalModel = struct {
    /// True when the review resolved a placement and the layout-aware ladder
    /// governed `Thermal.verdict` and `Thermal.window`. False ⇒ no layout, so
    /// the headline IS `estimate` and a reader must be told so.
    board_coupled: bool = false,
    /// The package-level datasheet screen's own verdict — an estimate, never
    /// the headline where a ladder exists.
    estimate: thermal.Verdict = .insufficient_data,
    /// The ambient window that estimate is good for, on the same JEDEC-board
    /// assumption.
    estimate_window: AmbientWindow = .{},
};

/// How much of the board the heat screen actually saw. A board where most
/// parts declare no power reads cool for want of input rather than by
/// engineering, so every surface that quotes the numbers states this beside
/// them.
pub const ThermalCoverage = struct {
    /// Parts that dissipate something the screen could compute a rise from.
    with_power: usize = 0,
    /// Screened parts whose dissipation nothing declared or derived.
    unknown_power: usize = 0,

    /// Every part the screen looked at, modelled or not.
    pub fn screened(self: ThermalCoverage) usize {
        return self.with_power + self.unknown_power;
    }
};

/// Heat evidence for the whole board, headlined by the board-coupled answer.
pub const Thermal = struct {
    ambient_c: f64 = 0,
    /// The verdict a document states: the board-coupled ladder's where the
    /// review resolved one (`model.board_coupled`), else the package screen's.
    /// Never the optimistic datasheet answer while a board answer exists.
    verdict: thermal.Verdict = .insufficient_data,
    /// Sum of every screened part's declared/derived dissipation (W).
    total_w: f64 = 0,
    hottest: HottestPart = .{},
    /// The window that goes with `verdict`: hot end from the governing cooling
    /// scenario when a ladder governs (null when no scenario clears every
    /// junction), cold end always the parts' ratings floor.
    window: AmbientWindow = .{},
    model: ThermalModel = .{},
    coverage: ThermalCoverage = .{},
};

/// One retained error-severity ERC violation.
pub const Finding = struct {
    kind: []const u8,
    ref_des: []const u8,
    net: []const u8,
    message: []const u8,
};

/// The board's rule-check rollup: violation counts by severity, the worst
/// findings themselves, and the evaluator's assertion outcomes.
pub const Checks = struct {
    errors: usize = 0,
    warnings: usize = 0,
    /// Error-severity findings, capped at `max_retained_erc_findings`.
    findings: []const Finding = &.{},
    /// True when `errors` exceeds the retained `findings`.
    truncated: bool = false,
    assertions_pass: usize = 0,
    assertions_warn: usize = 0,
    assertions_fail: usize = 0,
};

/// One outline rectangle, either as declared in source or as measured on the
/// selected saved layout. `present` false ⇒ nothing declared/resolved.
pub const Outline = struct {
    w: f64 = 0,
    h: f64 = 0,
    corner_radius: f64 = 0,
    present: bool = false,
};

/// Board mechanical evidence. `measured` comes from the same resolved fab view
/// the PCB preview is rendered from, so it is inside this module's read trace.
pub const Mechanical = struct {
    declared: Outline = .{},
    measured: Outline = .{},
    /// The shared drift predicate's verdict for this board — the same call
    /// `fab_readiness` makes for its `outline-drift` finding, so the two
    /// surfaces cannot disagree, and it names WHAT drifted (size, profile, or
    /// a stale `(outline-approved …)` pin) rather than only that something
    /// did. Surfaced at document level so a drifted board is visible without
    /// opening `fab-readiness.json`.
    outline: outline_mod.Verdict = .not_compared,
    stackup_preset: []const u8 = "",
    stackup_layers: u8 = 0,
};

/// One PLL loop screen's outcome, retained independently of the evaluator's
/// assertion list.
pub const PllScreen = struct {
    screen: []const u8,
    status: pll_loop.Status,
    message: []const u8,
};

/// One screened component population of one `(pll-loop …)` declaration.
pub const PllPopulation = struct {
    kind: pll_loop.PopulationKind,
    /// Plain numbers only — safe to copy by value out of the evaluator.
    results: pll_loop.Results,
    pass: usize = 0,
    warn: usize = 0,
    fail: usize = 0,
    /// Non-passing screens, capped at `max_retained_pll_screens`.
    failing: []const PllScreen = &.{},
};

/// The declaration figures a loop-filter table prints beside its results.
pub const PllProfile = struct {
    pfd_hz: f64 = 0,
    charge_pump_a: f64 = 0,
    prescaler: f64 = 0,
    pll_n: f64 = 0,
    op_amp_gbw_hz: f64 = 0,
    phase_margin_target_deg: pll_loop.Range = .{},
    max_ramp_phase_error_rad: f64 = 0,
};

/// One `(pll-loop …)` declaration's result, in snapshot-owned memory. The
/// evaluator's own `pll_loop.Report` borrows its names and verdict messages
/// from the assertion list and is freed with the evaluator, so every string
/// here is a copy.
pub const PllReport = struct {
    name: []const u8,
    mode: pll_loop.Mode,
    outcome: pll_loop.Outcome,
    profile: PllProfile,
    populations: []const PllPopulation,
    /// Quantized charge-pump schedule knots, empty unless a synthesis ran.
    schedule: []const pll_loop.ScheduleEntry,
};

/// One frequency-plan screen's outcome, retained independently of the
/// evaluator's assertion list — the same copy discipline `PllScreen` uses.
pub const FrequencyScreen = struct {
    screen: []const u8,
    status: frequency_plan.Status,
    message: []const u8,
};

/// The screens charged to one sideband plan: how many of each outcome, and the
/// non-passing ones themselves capped at `max_retained_frequency_screens`.
pub const FrequencyScreens = struct {
    pass: usize = 0,
    warn: usize = 0,
    fail: usize = 0,
    failing: []const FrequencyScreen = &.{},
};

/// One enumerated mixer product, reduced to what a document renders.
///
/// The engine's `Product` also carries the monotone `branches` of
/// `|m·RF − n·LO|`; they are deliberately NOT retained. `band` is already the
/// hull of those branches, and a renderer that reached for the endpoints would
/// be recomputing an overlap the engine has settled — so the type it renders
/// from does not offer them.
pub const SpurProduct = struct {
    order: frequency_plan.Order,
    /// Hull of every branch: the interval a table row states.
    band: frequency_plan.Band,
    placement: frequency_plan.Placement,
    /// `.none` unless `placement == .filter_rejected`.
    rejection: frequency_plan.Rejection,
    level: frequency_plan.Level,
};

/// One sideband plan's enumerated products. `enumerated` is how many the
/// engine produced, so `rows.len < enumerated` is exactly the truncation a
/// document must state rather than hide.
pub const SpurTable = struct {
    /// Retained rows, capped at `max_retained_spur_products`.
    rows: []const SpurProduct = &.{},
    enumerated: usize = 0,
};

/// One analysed sideband of one `(frequency-plan …)` declaration.
pub const FrequencyPlanSideband = struct {
    sideband: frequency_plan.Sideband,
    rf: frequency_plan.RfWindow = .{},
    image: frequency_plan.Image = .{},
    diagonal: frequency_plan.Diagonal = .{},
    spurs: SpurTable = .{},
    screens: FrequencyScreens = .{},
};

/// The declaration figures a spur table prints beside its results. The
/// authored `(spur-table …)` rows are not retained separately: every entry
/// that matched a product already travels on that product's `level`.
pub const FrequencyProfileLimits = struct {
    max_order: u8 = 0,
    in_band_limit_dbc: f64 = 0,
    limit_declared: bool = false,
};

/// What one `(frequency-plan …)` declaration states, normalized to SI.
pub const FrequencyProfile = struct {
    plan: frequency_plan.PlanConfig = .{},
    mixer: frequency_plan.MixerConfig = .{},
    spurs: FrequencyProfileLimits = .{},
};

/// One `(frequency-plan …)` declaration's result, in snapshot-owned memory.
/// The evaluator's own `frequency_plan.Report` borrows its name and every
/// verdict message from the assertion list and is freed with the evaluator, so
/// every string here is a copy.
pub const FrequencyPlanReport = struct {
    name: []const u8,
    mode: frequency_plan.Mode,
    outcome: frequency_plan.Outcome,
    profile: FrequencyProfile,
    /// One entry per analysed sideband, in evaluation order — `(sideband
    /// either)` publishes two, high side first.
    plans: []const FrequencyPlanSideband,
};

/// Everything the system document computes from the design rather than reads
/// from authored prose, gathered from the one evaluation this snapshot already
/// pays for. Grouped so a surface that carries board evidence carries all of
/// it, and so `Snapshot` itself stays four fields wide.
pub const Engineering = struct {
    /// Rail budget rows, tightest-first, capped at `max_retained_rails`.
    power: []const PowerRail = &.{},
    thermal: Thermal = .{},
    checks: Checks = .{},
    mechanical: Mechanical = .{},
    /// One entry per `(pll-loop …)` declaration, capped at
    /// `max_retained_pll_reports`.
    pll: []const PllReport = &.{},
    /// One entry per `(frequency-plan …)` declaration, capped at
    /// `max_retained_frequency_reports`.
    frequency: []const FrequencyPlanReport = &.{},
    bom: bom_html.BomRollup = .{},
};

/// A cached top-down component body used to populate the dossier's static
/// assembly views. The bounds are footprint-local millimetres, matching the
/// browser Assembly renderer's persistent model-sprite contract.
pub const AssemblySprite = struct {
    footprint: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    png: []const u8,
};

/// The self-contained physical-review board plus cached model bodies installed
/// into it by the dossier shell. The board document is the same interactive
/// semantic renderer as Assembly: green solder mask, exposed copper, face-aware
/// silkscreen, top/bottom orientation, zoom and pan. Footprint-local sprites are
/// deduplicated because the board document already owns every placed transform.
pub const AssemblyEvidence = struct {
    board_html: []const u8 = "",
    sprites: []const AssemblySprite = &.{},
};

/// Fully rendered, immutable evidence for one board member. Every byte slice
/// belongs to the caller's allocator.
pub const Snapshot = struct {
    identity: struct {
        name: []const u8,
        /// Exact project-relative root source selected by the design resolver.
        source: []const u8,
        title: []const u8,
        part_number: []const u8,
        revision: []const u8,
        layout: []const u8,
        generated_at: []const u8,
    },
    review: struct {
        status: review.Status,
        open_notes: usize,
        /// Expected project-relative notes sidecar path, retained even when
        /// absent so a later stability check can prove it stayed absent.
        notes_path: []const u8,
        /// Exact optional notes sidecar bytes that contributed to the gate.
        notes_source: ?zipfile.Entry,
        markdown: []const u8,
        pdf: []const u8,
        json: []const u8,
        bom_csv: []const u8,
        /// Standalone SVG document of the board's block diagram, rendered from
        /// the same evaluated design as the Markdown above. Empty when the
        /// design has no diagram to draw, in which case the archive omits the
        /// member. Held here so a document composer can inline the diagram
        /// without re-evaluating the design.
        diagram_svg: []const u8,
    },
    physical: struct {
        pcb_png: []const u8,
        assembly: AssemblyEvidence = .{},
        /// Canonical digest of every exact filesystem byte consumed while
        /// producing this snapshot, verified again before returning.
        consumed_sha256: [64]u8,
        /// Retained full read-set so the surrounding system gate can replay
        /// every direct and transitive dependency after its second fab read.
        consumed_trace: infra_fs.ReadTrace,
        /// Source/layout/BOM identities computed with the same trace contract
        /// as the fabrication release service.
        fab_inputs: fab_release.TracedInputs,
        /// Complete evaluated source closure under project-relative names.
        sources: []const zipfile.Entry,
        connections: []const Connection,
        /// Complete pad tables for the same requested connectors.
        connector_pads: []const ConnectorPads = &.{},
    },
    /// Design-derived engineering evidence — power, heat, rule checks,
    /// mechanical outline, loop filters, BOM rollup — computed from the same
    /// single evaluation as the Markdown above and owned by this allocator.
    analysis: Engineering,
};

const BuildError = @typeInfo(@typeInfo(@TypeOf(buildImpl)).@"fn".return_type.?).error_union.error_set;

/// Build all non-CAM evidence for a board from one evaluated source snapshot.
pub fn build(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
) BuildError!Snapshot {
    return buildImpl(allocator, project_dir, name, options);
}

fn buildImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
) !Snapshot {
    var read_trace = infra_fs.ReadTrace.init(allocator);
    errdefer read_trace.deinit();
    read_trace.begin();

    const root_source_path = try paths.designSourcePathUnique(allocator, project_dir, name);
    defer allocator.free(root_source_path);
    const root_source = try projectRelativeSource(allocator, project_dir, root_source_path);

    var evaluator = Evaluator.init(allocator, project_dir);
    defer evaluator.deinit();

    const named = try mcp_tools.evalNamedBlock(allocator, project_dir, name, &evaluator);
    const violations = try erc.runErc(allocator, named.block, project_dir);
    var checks = try req_checks.runChecks(allocator, &evaluator, named.block);
    req_checks.applyVerifications(&checks, named.block, named.block.instances);

    var doc = try review.buildReview(
        allocator,
        name,
        named.block,
        evaluator.assertions.items,
        violations,
        &checks,
    );
    doc.power.scenarios = try thermal_api.scenariosFor(
        allocator,
        project_dir,
        name,
        doc.power.thermal,
        doc.power.thermal.ambient_c,
        options.layout,
    );

    const md = try review_md.renderToMarkdown(
        allocator,
        named.block,
        project_dir,
        name,
        doc,
        build_id.current(),
    );
    const json = try review_json.renderToJson(allocator, doc);
    const note_evidence = try loadNotesEvidence(allocator, project_dir, name, root_source);
    const open_notes = note_evidence.open;
    const pdf_bytes = try export_pdf.compose(
        allocator,
        named.block,
        project_dir,
        name,
        doc,
        .{
            .theme = options.pdf_theme,
            .generated_at = doc.generated_at,
            .build_id = build_id.current(),
            .open_notes = open_notes,
        },
    );
    try pdf.validate(pdf_bytes);

    var bom_out: std.Io.Writer.Allocating = .init(allocator);
    try bom_html.writeBomCsv(allocator, &bom_out.writer, named.block);
    const diagram_svg = try renderDiagram(allocator, named.block);

    const fv = try pcb.fabViewForResolved(allocator, project_dir, name, options.layout, named.block);
    const pcb_png = try render_pcb_png.render(allocator, fv.placement, .{
        .width = std.math.clamp(options.pcb_width, 400, 2200),
        .title = name,
        .routed = fv.routed,
        .texts = fv.texts,
        .silk_keepouts = fv.silk_keepouts,
        .user_zones = fv.zones,
        .grid = true,
    });
    const assembly = AssemblyEvidence{
        .board_html = try pcb.standaloneDossierReviewBoardHtml(allocator, project_dir, name, fv),
        .sprites = try collectAssemblySprites(allocator, project_dir, fv.placement),
    };

    const source_entries = try collectSources(allocator, project_dir, root_source_path, &evaluator);
    const connections = try collectConnections(allocator, named.block, options.connectors);
    const connector_pads = try collectConnectorPads(allocator, &evaluator, named.block, options.connectors);
    const engineering = try collectEngineering(
        allocator,
        named.block,
        doc,
        violations,
        .{
            .pll = evaluator.pll_reports.items,
            .frequency = evaluator.frequency_plan_reports.items,
        },
        fab_readiness.savedOutline(fv.placement),
    );
    read_trace.end();
    if (!read_trace.verify()) return error.InputsChanged;
    const consumed_sha256 = read_trace.digest();
    const traced_fab_inputs = try fab_release.tracedInputs(allocator, &read_trace, project_dir, name);
    return .{
        .identity = .{
            .name = try allocator.dupe(u8, name),
            .source = root_source,
            .title = try allocator.dupe(u8, named.block.name),
            .part_number = try allocator.dupe(u8, named.block.board.part_number),
            .revision = try allocator.dupe(u8, named.block.revision.id),
            .layout = try allocator.dupe(u8, fv.selection.name),
            .generated_at = try allocator.dupe(u8, doc.generated_at),
        },
        .review = .{
            .status = doc.summary.status,
            .open_notes = open_notes,
            .notes_path = note_evidence.path,
            .notes_source = note_evidence.source,
            .markdown = md,
            .pdf = pdf_bytes,
            .json = json,
            .bom_csv = bom_out.written(),
            .diagram_svg = diagram_svg,
        },
        .physical = .{
            .pcb_png = pcb_png,
            .assembly = assembly,
            .consumed_sha256 = consumed_sha256,
            .consumed_trace = read_trace,
            .fab_inputs = traced_fab_inputs,
            .sources = source_entries,
            .connections = connections,
            .connector_pads = connector_pads,
        },
        .analysis = engineering,
    };
}

const model_sprite_cache_rel = "lib/models/.sprites";
const model_sprite_render_version = "2";
const max_model_sprite_bytes: usize = 8 * 1024 * 1024;
const max_model_sprite_meta_bytes: usize = 2048;
const png_signature = "\x89PNG\r\n\x1a\n";

const SpriteBounds = struct { x: f64, y: f64, w: f64, h: f64 };

fn safeSpriteName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| {
        if (safeSpriteNameByte(c)) continue;
        return false;
    }
    return true;
}

fn safeSpriteNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '.', '-', '_', ',', '#' => true,
        else => false,
    };
}

fn jsonFloat(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

fn validSpriteBounds(bounds: SpriteBounds) bool {
    for ([_]f64{ bounds.x, bounds.y, bounds.w, bounds.h }) |value|
        if (!std.math.isFinite(value) or @abs(value) > 10_000) return false;
    return bounds.w > 0 and bounds.h > 0;
}

/// Recompute the persistent sprite key exactly as the Assembly endpoint does.
/// A model/config edit may leave the old PNG on disk until Assembly next opens;
/// the dossier omits that stale body instead of presenting it as current.
fn currentSpriteKey(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    footprint: []const u8,
) ?u64 {
    const config = export_kicad.loadModelConfig(allocator, project_dir);
    const transform = config.get(footprint);
    const model_name = if (transform) |value|
        if (value.model) |name| allocator.dupe(u8, name) catch return null else export_kicad_footprint.findModelFile(allocator, project_dir, footprint, footprint)
    else
        export_kicad_footprint.findModelFile(allocator, project_dir, footprint, footprint);
    const resolved = model_name orelse return null;
    const model_path = std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, resolved }) catch return null;
    const stat = infra_fs.cwd().statFile(model_path) catch return null;
    const offset = if (transform) |value| value.offset else [3]f64{ 0, 0, 0 };
    const rotation = if (transform) |value| value.rotation else [3]f64{ 0, 0, 0 };

    var hash = std.hash.Wyhash.init(0x535052495445);
    hash.update(model_sprite_render_version);
    hash.update(resolved);
    var size = stat.size;
    var mtime = stat.mtime.nanoseconds;
    hash.update(std.mem.asBytes(&size));
    hash.update(std.mem.asBytes(&mtime));
    var transform_buf: [256]u8 = undefined;
    const transform_text = std.fmt.bufPrint(&transform_buf, "{d},{d},{d};{d},{d},{d}", .{
        offset[0], offset[1], offset[2], rotation[0], rotation[1], rotation[2],
    }) catch return null;
    hash.update(transform_text);
    return hash.final();
}

fn loadAssemblySprite(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    footprint: []const u8,
) ?AssemblySprite {
    if (!safeSpriteName(footprint)) return null;
    const meta_path = std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}.json",
        .{ project_dir, model_sprite_cache_rel, footprint },
    ) catch return null;
    const meta = infra_fs.cwd().readFileAlloc(allocator, meta_path, max_model_sprite_meta_bytes) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, meta, .{}) catch return null;
    const object = switch (parsed) {
        .object => |value| value,
        else => return null,
    };
    const key = switch (object.get("key") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    if (key.len != 16) return null;
    const source_key = currentSpriteKey(allocator, project_dir, footprint) orelse return null;
    var key_buf: [16]u8 = undefined;
    const expected_key = std.fmt.bufPrint(&key_buf, "{x:0>16}", .{source_key}) catch return null;
    if (!std.mem.eql(u8, key, expected_key)) return null;
    const bounds: SpriteBounds = .{
        .x = jsonFloat(object.get("x") orelse return null) orelse return null,
        .y = jsonFloat(object.get("y") orelse return null) orelse return null,
        .w = jsonFloat(object.get("w") orelse return null) orelse return null,
        .h = jsonFloat(object.get("h") orelse return null) orelse return null,
    };
    if (!validSpriteBounds(bounds)) return null;
    const png_path = std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}.png",
        .{ project_dir, model_sprite_cache_rel, footprint },
    ) catch return null;
    const bytes = infra_fs.cwd().readFileAlloc(allocator, png_path, max_model_sprite_bytes) catch return null;
    if (!std.mem.startsWith(u8, bytes, png_signature)) return null;
    return .{
        .footprint = allocator.dupe(u8, footprint) catch return null,
        .x = bounds.x,
        .y = bounds.y,
        .w = bounds.w,
        .h = bounds.h,
        .png = bytes,
    };
}

fn collectAssemblySprites(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    placement: optimizer.Placement,
) ![]const AssemblySprite {
    var sprites: std.ArrayList(AssemblySprite) = .empty;
    var by_footprint: std.StringHashMapUnmanaged(void) = .empty;
    defer by_footprint.deinit(allocator);

    for (placement.parts, 0..) |_, index| {
        if (index >= placement.instances.len) break;
        const footprint = placement.instances[index].footprint;
        if (by_footprint.contains(footprint)) continue;
        const sprite = loadAssemblySprite(allocator, project_dir, footprint) orelse continue;
        try sprites.append(allocator, sprite);
        try by_footprint.put(allocator, sprite.footprint, {});
    }
    return sprites.toOwnedSlice(allocator);
}

/// The typed analysis records the evaluator publishes beside its assertion
/// list. Grouped so one evaluation hands the collector every declared-analysis
/// result in a single argument instead of a growing parameter list.
const EvaluatedReports = struct {
    pll: []const pll_loop.Report = &.{},
    frequency: []const frequency_plan.Report = &.{},
};

/// Retain everything the system document computes from this design, copying
/// each string into the snapshot's allocator: the evaluator that owns the PLL
/// verdict messages is destroyed when `buildImpl` returns.
///
/// `saved` is the fab view's resolved outline — the selected saved layout's
/// drawn edge (bbox rectangle plus the exact profile when it has one), else
/// the authored rectangle — so the measurement is already covered by this
/// module's read trace.
fn collectEngineering(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    doc: review.ReviewDoc,
    violations: []const erc.Violation,
    reports: EvaluatedReports,
    saved: ?outline_mod.Saved,
) !Engineering {
    return .{
        .power = try collectPowerRails(allocator, block, doc.power.budget),
        .thermal = try collectThermal(allocator, doc.power.thermal, doc.power.scenarios),
        .checks = try collectChecks(allocator, violations, doc.assertions),
        .mechanical = try collectMechanical(allocator, block, saved),
        .pll = try collectPllReports(allocator, reports.pll),
        .frequency = try collectFrequencyPlans(allocator, reports.frequency),
        .bom = try bom_html.rollupBom(allocator, block),
    };
}

fn collectPowerRails(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    budget: []const power_budget.Rail,
) ![]const PowerRail {
    const retained = @min(budget.len, max_retained_rails);
    const rails = try allocator.alloc(PowerRail, retained);
    for (budget[0..retained], rails) |rail, *out| out.* = .{
        .net = try allocator.dupe(u8, rail.net),
        .nominal_v = declaredRailVoltage(block, rail.net),
        .source = .{
            .label = try allocator.dupe(u8, rail.source_label),
            .max_a = rail.source_max_a,
        },
        .load_max_a = rail.load_max_a,
        .margin_pct = rail.margin_pct,
        .status = rail.status,
        .consumers = rail.consumers.len,
    };
    return rails;
}

/// The rail's declared nominal voltage. `power_budget` collapses ferrite-
/// bridged nets onto the source-side name, which is the same name
/// `eval/rails` keys a `PowerRail` on, so the primary name matches first and
/// the alias list covers a budget row named after a downstream leg.
fn declaredRailVoltage(block: *const env_mod.DesignBlock, net: []const u8) ?f64 {
    for (block.rails) |rail| {
        if (std.mem.eql(u8, rail.name, net)) return rail.nominal;
        for (rail.aliases) |alias| {
            if (std.mem.eql(u8, alias, net)) return rail.nominal;
        }
    }
    return null;
}

/// Retain the board's heat answer, headlined the way the board's own review
/// headlines it.
///
/// `scenarios` is the ladder the caller already resolved onto `doc.power`
/// before this ran — no new read, so the read trace is untouched — and the
/// headline goes through `review_thermal.headlineVerdict`, the same function
/// the review page's pill and the review Markdown use. A system document can
/// therefore never state a cooler verdict than the board review it was built
/// from.
fn collectThermal(
    allocator: std.mem.Allocator,
    heat: thermal.BoardThermal,
    scenarios: thermal_scenarios.Answer,
) !Thermal {
    var total_w: f64 = 0;
    var hottest: ?thermal.PartThermal = null;
    for (heat.parts) |part| {
        const watts = part.power.watts orelse continue;
        total_w += watts;
        if (hottest == null or watts > hottest.?.power.watts.?) hottest = part;
    }
    const estimate_window: AmbientWindow = .{ .max_c = heat.max_ambient.c, .min_c = heat.min_ambient.c };
    return .{
        .ambient_c = heat.ambient_c,
        .verdict = review_thermal.headlineVerdict(heat, scenarios),
        .total_w = total_w,
        .hottest = .{
            .ref_des = if (hottest) |part| try allocator.dupe(u8, part.ref_des) else "",
            .watts = if (hottest) |part| part.power.watts.? else 0,
        },
        .window = if (scenarios.ladder) |ladder| .{
            // The governing scenario sets the hot end (it is the cooling the
            // board actually needs); the cold end is a ratings floor that no
            // amount of airflow moves, so it stays the screen's own.
            .max_c = if (thermal_scenarios.governingRow(ladder)) |gov| gov.max_ambient.c else null,
            .min_c = heat.min_ambient.c,
        } else estimate_window,
        .model = .{
            .board_coupled = scenarios.ladder != null,
            .estimate = heat.verdict,
            .estimate_window = estimate_window,
        },
        .coverage = .{
            .with_power = heat.counts.with_power,
            .unknown_power = heat.counts.unknown_power,
        },
    };
}

fn collectChecks(
    allocator: std.mem.Allocator,
    violations: []const erc.Violation,
    assertions: []const review.AssertionReport,
) !Checks {
    var out: Checks = .{};
    var findings: std.ArrayList(Finding) = .empty;
    for (violations) |violation| switch (violation.severity) {
        .@"error" => {
            out.errors += 1;
            if (findings.items.len >= max_retained_erc_findings) continue;
            try findings.append(allocator, .{
                .kind = @tagName(violation.kind),
                .ref_des = try allocator.dupe(u8, violation.ref_des),
                .net = try allocator.dupe(u8, violation.net),
                .message = try allocator.dupe(u8, violation.message),
            });
        },
        .warning => out.warnings += 1,
        .info => {},
    };
    for (assertions) |assertion| switch (assertion.status) {
        .pass => out.assertions_pass += 1,
        .warn => out.assertions_warn += 1,
        .fail => out.assertions_fail += 1,
    };
    out.findings = findings.items;
    out.truncated = out.errors > findings.items.len;
    return out;
}

/// The declared-vs-measured outline comparison is not restated here: it is
/// `placement/outline.compare`, the one predicate `fab_readiness`'s
/// `outline-drift` finding also calls, so the two surfaces can never disagree
/// about whether a board drifted — nor about why. The scratch arena exists
/// only because the predicate fillets the declared rectangle and digests the
/// saved profile to answer; nothing it allocates escapes.
fn collectMechanical(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    saved: ?outline_mod.Saved,
) std.mem.Allocator.Error!Mechanical {
    const declared: Outline = .{
        .w = block.board.w,
        .h = block.board.h,
        .corner_radius = block.board.corner_radius,
        .present = block.board.present and block.board.w > 0 and block.board.h > 0,
    };
    const measured: Outline = if (saved) |outline| .{
        .w = outline.rect.w,
        .h = outline.rect.h,
        .corner_radius = declared.corner_radius,
        .present = true,
    } else .{};
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const drift = try outline_mod.compare(
        scratch.allocator(),
        fab_readiness.declaredOutline(block.board),
        if (declared.present) saved else null,
    );
    return .{
        .declared = declared,
        .measured = measured,
        .outline = drift.verdict,
        .stackup_preset = block.stackup.preset,
        .stackup_layers = block.stackup.layers,
    };
}

fn collectPllReports(
    allocator: std.mem.Allocator,
    reports: []const pll_loop.Report,
) ![]const PllReport {
    const retained = @min(reports.len, max_retained_pll_reports);
    const out = try allocator.alloc(PllReport, retained);
    for (reports[0..retained], out) |report, *copy| copy.* = .{
        .name = try allocator.dupe(u8, report.name),
        .mode = report.mode,
        .outcome = report.outcome,
        .profile = .{
            .pfd_hz = report.profile.pfd_hz,
            .charge_pump_a = report.profile.charge_pump_a,
            .prescaler = report.profile.prescaler,
            .pll_n = report.profile.pll_n,
            .op_amp_gbw_hz = report.profile.op_amp_gbw_hz,
            .phase_margin_target_deg = report.profile.phase_margin_target_deg,
            .max_ramp_phase_error_rad = report.profile.max_ramp_phase_error_rad,
        },
        .populations = try collectPllPopulations(allocator, report.populations),
        .schedule = try allocator.dupe(
            pll_loop.ScheduleEntry,
            report.schedule[0..@min(report.schedule.len, max_retained_schedule_entries)],
        ),
    };
    return out;
}

fn collectPllPopulations(
    allocator: std.mem.Allocator,
    populations: []const pll_loop.Population,
) ![]const PllPopulation {
    const out = try allocator.alloc(PllPopulation, populations.len);
    for (populations, out) |population, *copy| copy.* = try collectPllPopulation(allocator, population);
    return out;
}

fn collectPllPopulation(
    allocator: std.mem.Allocator,
    population: pll_loop.Population,
) !PllPopulation {
    var copy: PllPopulation = .{ .kind = population.kind, .results = population.results };
    var failing: std.ArrayList(PllScreen) = .empty;
    for (population.verdicts) |verdict| {
        switch (verdict.status) {
            .pass => copy.pass += 1,
            .warn => copy.warn += 1,
            .fail => copy.fail += 1,
        }
        if (verdict.status == .pass or failing.items.len >= max_retained_pll_screens) continue;
        try failing.append(allocator, .{
            .screen = @tagName(verdict.screen),
            .status = verdict.status,
            .message = try allocator.dupe(u8, verdict.message),
        });
    }
    copy.failing = failing.items;
    return copy;
}

/// Retain every `(frequency-plan …)` result, copying the declaration name and
/// each verdict message out of the assertion list the evaluator owns. The
/// engine's `Report.deinit` stays the evaluator's business; nothing here
/// aliases it.
fn collectFrequencyPlans(
    allocator: std.mem.Allocator,
    reports: []const frequency_plan.Report,
) ![]const FrequencyPlanReport {
    const retained = @min(reports.len, max_retained_frequency_reports);
    const out = try allocator.alloc(FrequencyPlanReport, retained);
    for (reports[0..retained], out) |report, *copy| copy.* = .{
        .name = try allocator.dupe(u8, report.name),
        .mode = report.mode,
        .outcome = report.outcome,
        .profile = .{
            .plan = report.profile.plan,
            .mixer = report.profile.mixer,
            .spurs = .{
                .max_order = report.profile.spurs.max_order,
                .in_band_limit_dbc = report.profile.spurs.in_band_limit_dbc,
                .limit_declared = report.profile.spurs.limit_declared,
            },
        },
        .plans = try collectFrequencySidebands(allocator, report.plans),
    };
    return out;
}

fn collectFrequencySidebands(
    allocator: std.mem.Allocator,
    plans: []const frequency_plan.SidebandPlan,
) ![]const FrequencyPlanSideband {
    const out = try allocator.alloc(FrequencyPlanSideband, plans.len);
    for (plans, out) |plan, *copy| copy.* = .{
        .sideband = plan.sideband,
        .rf = plan.rf,
        .image = plan.image,
        .diagonal = plan.diagonal,
        .spurs = try collectSpurTable(allocator, plan.products),
        .screens = try collectFrequencyScreens(allocator, plan.verdicts),
    };
    return out;
}

fn collectSpurTable(
    allocator: std.mem.Allocator,
    products: []const frequency_plan.Product,
) !SpurTable {
    const retained = @min(products.len, max_retained_spur_products);
    const rows = try allocator.alloc(SpurProduct, retained);
    for (products[0..retained], rows) |product, *copy| copy.* = .{
        .order = product.order,
        .band = product.band,
        .placement = product.placement,
        .rejection = product.rejection,
        .level = product.level,
    };
    return .{ .rows = rows, .enumerated = products.len };
}

fn collectFrequencyScreens(
    allocator: std.mem.Allocator,
    verdicts: []const frequency_plan.Verdict,
) !FrequencyScreens {
    var out: FrequencyScreens = .{};
    var failing: std.ArrayList(FrequencyScreen) = .empty;
    for (verdicts) |verdict| {
        switch (verdict.status) {
            .pass => out.pass += 1,
            .warn => out.warn += 1,
            .fail => out.fail += 1,
        }
        if (verdict.status == .pass or failing.items.len >= max_retained_frequency_screens) continue;
        try failing.append(allocator, .{
            .screen = @tagName(verdict.screen),
            .status = verdict.status,
            .message = try allocator.dupe(u8, verdict.message),
        });
    }
    out.failing = failing.items;
    return out;
}

/// Re-read every archived source and the optional notes sidecar after the
/// surrounding fabrication snapshot. This rejects A/B/A changes that could
/// otherwise pair review evidence from B with fabrication evidence from A.
pub fn verifySnapshot(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    snapshot: Snapshot,
) bool {
    if (!snapshot.physical.consumed_trace.verify()) return false;
    for (snapshot.physical.sources) |source| {
        const current = review_assets.readContainedFile(
            allocator,
            project_dir,
            source.name,
            max_source_bytes,
        ) catch return false;
        defer allocator.free(current);
        if (!std.mem.eql(u8, current, source.data)) return false;
    }
    if (snapshot.review.notes_source) |notes_source| {
        const current = review_assets.readContainedFile(
            allocator,
            project_dir,
            snapshot.review.notes_path,
            1024 * 1024,
        ) catch return false;
        defer allocator.free(current);
        return std.mem.eql(u8, current, notes_source.data);
    }
    const unexpected = review_assets.readContainedFile(
        allocator,
        project_dir,
        snapshot.review.notes_path,
        1024 * 1024,
    ) catch |err| return err == error.FileNotFound;
    allocator.free(unexpected);
    return false;
}

/// Render the board's block diagram as a standalone SVG document from the one
/// evaluated design this snapshot already holds, so the diagram never costs a
/// second evaluation and can never disagree with the rest of the evidence.
///
/// The diagram engine is deliberately given an empty project root — the same
/// choice `review_md` makes for the export form. A project root would make the
/// renderer read each sub-module's `.layouts.json` sidecar for its maturity
/// star; those reads sit outside this module's `ReadTrace`, so admitting them
/// would leave the snapshot's `consumed_sha256` claiming a read set it does not
/// actually cover. Chips therefore cap at the `schematic` stage, exactly as
/// they do in the archived Markdown.
///
/// Returns empty bytes when the design has no diagram to draw, which the
/// archive reads as "omit the member".
fn renderDiagram(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
) ![]const u8 {
    const sub_attachments = try membership.computeSubBlockAttachments(allocator, block);
    defer allocator.free(sub_attachments);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    if (!try block_diagram.renderStandaloneSvg(allocator, block, sub_attachments, "", &out.writer)) {
        out.deinit();
        return "";
    }
    return out.written();
}

fn collectConnections(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    connectors: []const []const u8,
) ![]const Connection {
    const ConnectorTarget = struct {
        declared: []const u8,
        evaluated: []const u8,
    };

    var targets: std.ArrayList(ConnectorTarget) = .empty;
    for (connectors) |connector| try targets.append(allocator, .{
        .declared = connector,
        .evaluated = try evaluatedConnectorHandle(allocator, block, connector),
    });

    var out: std.ArrayList(Connection) = .empty;
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(allocator, block, &nets);
    for (nets.items) |net| for (net.pins) |pin| {
        const target = for (targets.items) |target| {
            if (std.mem.eql(u8, target.evaluated, pin.ref_des)) break target;
        } else continue;
        try out.append(allocator, .{
            .connector = try allocator.dupe(u8, target.declared),
            .pin = try allocator.dupe(u8, pin.pin),
            .net = try allocator.dupe(u8, net.name),
        });
    };
    std.mem.sort(Connection, out.items, {}, struct {
        fn lessThan(_: void, a: Connection, b: Connection) bool {
            const connector_order = std.mem.order(u8, a.connector, b.connector);
            if (connector_order != .eq) return connector_order == .lt;
            return std.mem.lessThan(u8, a.pin, b.pin);
        }
    }.lessThan);
    return out.items;
}

/// Resolve a stable source handle such as `base-interface/J1` to the instance
/// the evaluator produced for it. Evaluator-wide numbering may turn that
/// module-local `J1` into `U19`; `origin_key` and `label` retain the authored
/// identity specifically so contracts do not drift when unrelated parts are
/// inserted or removed.
fn findConnectorInstance(
    root: *const env_mod.DesignBlock,
    connector: []const u8,
) ?*const env_mod.Instance {
    const prefix = net_name.parent(connector) orelse "";
    const source_name = net_name.leaf(connector);

    var block = root;
    if (prefix.len > 0) {
        var segments = std.mem.splitScalar(u8, prefix, '/');
        while (segments.next()) |segment| {
            block = for (block.sub_blocks) |sub_block| {
                if (std.mem.eql(u8, sub_block.name, segment)) break sub_block.block;
            } else return null;
        }
    }

    for (block.instances) |*instance| {
        if (std.mem.eql(u8, instance.ref_des, source_name) or
            std.mem.eql(u8, instance.label, source_name) or
            std.mem.eql(u8, instance.origin_key, source_name)) return instance;
    }
    return null;
}

/// The same resolution as a flattened ref-des path, which is what the netlist
/// spells its pins with.
fn evaluatedConnectorHandle(
    allocator: std.mem.Allocator,
    root: *const env_mod.DesignBlock,
    connector: []const u8,
) ![]const u8 {
    const instance = findConnectorInstance(root, connector) orelse
        return allocator.dupe(u8, connector);
    const prefix = net_name.parent(connector) orelse "";
    if (prefix.len == 0) return allocator.dupe(u8, instance.ref_des);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, instance.ref_des });
}

/// Every contact of one stable connector handle on an already-evaluated
/// design: its complete pad table with the net each pad reaches, empty for a
/// pad the netlist leaves unconnected. Null when the handle names no instance
/// or the instance resolves no pinout — absent evidence, not a connector with
/// no contacts. This is the pad table `(system …)`'s `(auto)` derives from.
pub const ConnectorContactsError = std.mem.Allocator.Error;

pub fn connectorContacts(
    allocator: std.mem.Allocator,
    evaluator: *Evaluator,
    block: *const env_mod.DesignBlock,
    connector: []const u8,
) ConnectorContactsError!?[]const system_sexp.Contact {
    const instance = findConnectorInstance(block, connector) orelse return null;
    const pin_map = symbolPinsFor(evaluator, instance) orelse return null;
    var pads: std.ArrayList([]const u8) = .empty;
    var keys = pin_map.iterator();
    while (keys.next()) |entry| try pads.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, pads.items, {}, lessPadId);

    const evaluated = try evaluatedConnectorHandle(allocator, block, connector);
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(allocator, block, &nets);

    var out: std.ArrayList(system_sexp.Contact) = .empty;
    for (pads.items) |pad| {
        var wired: []const u8 = "";
        outer: for (nets.items) |net| {
            for (net.pins) |pin| {
                if (!std.mem.eql(u8, pin.ref_des, evaluated)) continue;
                if (!system_sexp.sameContact(pin.pin, pad)) continue;
                wired = net.name;
                break :outer;
            }
        }
        try out.append(allocator, .{ .pin = pad, .net = wired });
    }
    return out.items;
}

/// Read each requested connector's complete pad table out of the pinout its
/// placed part resolves to. A part with no pinout (every positional passive,
/// and any connector whose library entry omits one) yields an empty pad list,
/// which downstream contract checks treat as absent evidence rather than as a
/// zero-contact connector.
fn collectConnectorPads(
    allocator: std.mem.Allocator,
    evaluator: *Evaluator,
    block: *const env_mod.DesignBlock,
    connectors: []const []const u8,
) ![]const ConnectorPads {
    var out: std.ArrayList(ConnectorPads) = .empty;
    for (connectors) |connector| {
        var pads: std.ArrayList([]const u8) = .empty;
        if (findConnectorInstance(block, connector)) |instance| {
            if (symbolPinsFor(evaluator, instance)) |pin_map| {
                var pins = pin_map.iterator();
                while (pins.next()) |entry| try pads.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
                std.mem.sort([]const u8, pads.items, {}, lessPadId);
            }
        }
        try out.append(allocator, .{
            .connector = try allocator.dupe(u8, connector),
            .pads = pads.items,
        });
    }
    return out.items;
}

/// Prefer the component's declared pinout name, then its symbol name, then the
/// instance's own symbol — the same order `list_free_pins` resolves.
fn symbolPinsFor(
    evaluator: *Evaluator,
    instance: *const env_mod.Instance,
) ?*const std.StringHashMapUnmanaged([]const u8) {
    const lookup_name = if (evaluator.component_cache.get(instance.component)) |component|
        (if (component.pinout_name.len > 0)
            component.pinout_name
        else if (component.symbol_name.len > 0)
            component.symbol_name
        else
            instance.symbol)
    else
        instance.symbol;
    if (lookup_name.len == 0) return null;
    return ids.getSymbolPins(evaluator, lookup_name);
}

/// Order pad ids the way a reader expects a connector's contacts: numerically
/// when both are plain decimals (so `2` precedes `10`), lexically otherwise.
fn lessPadId(_: void, a: []const u8, b: []const u8) bool {
    const left = std.fmt.parseUnsigned(u64, a, 10) catch return std.mem.lessThan(u8, a, b);
    const right = std.fmt.parseUnsigned(u64, b, 10) catch return std.mem.lessThan(u8, a, b);
    if (left != right) return left < right;
    return std.mem.lessThan(u8, a, b);
}

const NotesEvidence = struct {
    open: usize,
    path: []const u8,
    source: ?zipfile.Entry,
};

fn loadNotesEvidence(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    root_source: []const u8,
) !NotesEvidence {
    const parent = std.fs.path.dirname(root_source) orelse return error.SourceOutsideProject;
    const relative = try std.fmt.allocPrint(allocator, "{s}/{s}.notes.md", .{ parent, name });
    const raw = review_assets.readContainedFile(allocator, project_dir, relative, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return .{ .open = 0, .path = relative, .source = null };
        allocator.free(relative);
        return err;
    };
    const parsed = notes.parseNotes(allocator, raw) catch |err| {
        allocator.free(relative);
        allocator.free(raw);
        return err;
    };
    defer {
        allocator.free(parsed.tasks);
        allocator.free(parsed.scratchpad);
    }
    var count: usize = 0;
    for (parsed.tasks) |task| if (task.completed == null) {
        count += 1;
    };
    return .{ .open = count, .path = relative, .source = .{ .name = relative, .data = raw } };
}

fn projectRelativeSource(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    source_path: []const u8,
) ![]const u8 {
    const project = try infra_fs.canonicalPathAlloc(allocator, project_dir);
    defer allocator.free(project);
    const source = try infra_fs.canonicalPathAlloc(allocator, source_path);
    defer allocator.free(source);
    if (source.len <= project.len) return error.SourceOutsideProject;
    if (!std.mem.startsWith(u8, source, project)) return error.SourceOutsideProject;
    if (project.len > 1 and source[project.len] != '/') return error.SourceOutsideProject;
    const relative_start = if (project.len == 1) project.len else project.len + 1;
    const relative = source[relative_start..];
    if (!sourceRelativeAllowed(relative)) return error.SourceOutsideProject;
    return allocator.dupe(u8, relative);
}

fn sourceRelativeAllowed(relative: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(relative)) return false;
    if (!std.mem.endsWith(u8, relative, ".sexp")) return false;
    return std.mem.startsWith(u8, relative, "src/") or
        std.mem.startsWith(u8, relative, "lib/");
}

fn appendSource(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    path: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList(zipfile.Entry),
    total_bytes: *usize,
) !void {
    const resolved = try infra_fs.canonicalPathAlloc(allocator, path);
    defer allocator.free(resolved);
    const name = try projectRelativeSource(allocator, project_dir, resolved);
    errdefer allocator.free(name);
    if (seen.contains(name)) {
        allocator.free(name);
        return;
    }
    const data = try review_assets.readContainedFile(allocator, project_dir, name, max_source_bytes);
    errdefer allocator.free(data);
    if (out.items.len >= max_source_closure_entries) return error.SourceClosureTooLarge;
    if (data.len > max_source_closure_bytes - total_bytes.*) return error.SourceClosureTooLarge;
    try seen.put(allocator, name, {});
    try out.append(allocator, .{ .name = name, .data = data });
    total_bytes.* += data.len;
}

fn collectSources(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    root_source: []const u8,
    evaluator: *Evaluator,
) ![]const zipfile.Entry {
    var out: std.ArrayList(zipfile.Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var total_bytes: usize = 0;
    try appendSource(allocator, project_dir, root_source, &seen, &out, &total_bytes);
    var it = evaluator.loaded_files.keyIterator();
    while (it.next()) |path| try appendSource(allocator, project_dir, path.*, &seen, &out, &total_bytes);
    std.mem.sort(zipfile.Entry, out.items, {}, struct {
        fn lessThan(_: void, a: zipfile.Entry, b: zipfile.Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return out.items;
}

test "dossier assembly evidence accepts only a current model sprite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/models/.sprites");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/demo.step", .data = "step-v1" });
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const key = currentSpriteKey(allocator, project_dir, "demo") orelse return error.TestUnexpectedResult;
    const metadata = try std.fmt.allocPrint(
        allocator,
        "{{\"key\":\"{x:0>16}\",\"x\":-1,\"y\":-2,\"w\":3,\"h\":4}}",
        .{key},
    );
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/.sprites/demo.json", .data = metadata });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/.sprites/demo.png", .data = png_signature ++ "pixels" });
    const current = loadAssemblySprite(allocator, project_dir, "demo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("demo", current.footprint);
    try std.testing.expectApproxEqAbs(@as(f64, 4), current.h, 1e-9);

    // Replacing the STEP changes the source key. Until Assembly refreshes its
    // cache, the dossier leaves the stale body out rather than showing it.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/demo.step", .data = "step-version-two" });
    try std.testing.expect(loadAssemblySprite(allocator, project_dir, "demo") == null);
}

// spec: system-review - interface evidence resolves stable sub-block connector handles through the canonical flattened netlist
test "connector observations retain hierarchy handles and canonical tied nets" {
    const env = @import("eval/env.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const child_pins = [_]env.PinRef{
        .{ .ref_des = "U19", .pin = "1" },
        .{ .ref_des = "U19", .pin = "2" },
    };
    const child_nets = [_]env.Net{.{ .name = "LOCAL", .pins = &child_pins }};
    const child_instances = [_]env.Instance{.{
        .ref_des = "U19",
        .label = "J1",
        .origin_key = "J1",
        .component = "connector",
        .value = "connector",
        .footprint = "connector",
        .symbol = "connector",
    }};
    var child = env.DesignBlock{
        .name = "connector",
        .instances = &child_instances,
        .nets = &child_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var sub_blocks = [_]env.SubBlock{.{ .name = "link", .block = &child }};
    const root_nets = [_]env.Net{.{ .name = "CANONICAL", .pins = &.{} }};
    const ties = [_]env.NetTie{.{ .a = "CANONICAL", .b = "link/LOCAL" }};
    const root = env.DesignBlock{
        .name = "root",
        .instances = &.{},
        .nets = &root_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sub_blocks,
        .net_ties = &ties,
    };

    const connections = try collectConnections(arena.allocator(), &root, &.{"link/J1"});
    try std.testing.expectEqual(@as(usize, 2), connections.len);
    try std.testing.expectEqualStrings("link/J1", connections[0].connector);
    try std.testing.expectEqualStrings("CANONICAL", connections[0].net);
}

// spec: system-review - per-board block diagram evidence is one standalone SVG document rendered from the same evaluated design, omitted when there is nothing to draw
test "board diagram evidence renders standalone or is cleanly absent" {
    const env = @import("eval/env.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A flat design with no groups, sections or sub-blocks: the grouped-cards
    // overview has nothing to show, so the synthetic single-box fallback still
    // produces a valid standalone document.
    const instances = [_]env.Instance{.{
        .ref_des = "U1",
        .label = "U1",
        .origin_key = "U1",
        .component = "mcu",
        .value = "mcu",
        .footprint = "qfn",
        .symbol = "ic",
    }};
    const flat = env.DesignBlock{
        .name = "flat",
        .instances = &instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const svg = try renderDiagram(allocator, &flat);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg "));
    try std.testing.expect(std.mem.endsWith(u8, svg, "</svg>"));
    // Same evaluated design ⇒ same bytes, so the archive stays reproducible.
    try std.testing.expectEqualStrings(svg, try renderDiagram(allocator, &flat));

    // Nothing placeable at all: no diagram, no member, no empty file.
    const bare = env.DesignBlock{
        .name = "bare",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    try std.testing.expectEqual(@as(usize, 0), (try renderDiagram(allocator, &bare)).len);
}

// spec: system-review - evaluated source paths retain the buildable src/lib shape in a review package
test "source closure rejects files outside project source roots" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var entries: std.ArrayList(zipfile.Entry) = .empty;
    defer entries.deinit(std.testing.allocator);
    var total_bytes: usize = 0;
    try std.testing.expectError(
        error.FileNotFound,
        appendSource(
            std.testing.allocator,
            "demo",
            "/definitely-not-a-netlisp-project/evaluated-source.data",
            &seen,
            &entries,
            &total_bytes,
        ),
    );
}

test "source closure rejects a project-local symlink to external bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/lib/modules");
    try tmp.dir.createDirPath(std.testing.io, "outside");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside/secret.sexp", .data = "(secret)" });
    try tmp.dir.symLink(
        std.testing.io,
        "../../../outside/secret.sexp",
        "project/lib/modules/linked.sexp",
        .{},
    );
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, "project", allocator);
    const linked = try std.fmt.allocPrint(allocator, "{s}/lib/modules/linked.sexp", .{project});
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var entries: std.ArrayList(zipfile.Entry) = .empty;
    var total_bytes: usize = 0;
    try std.testing.expectError(
        error.SourceOutsideProject,
        appendSource(allocator, project, linked, &seen, &entries, &total_bytes),
    );
    try std.testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "root source identity is resolved project relative" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/src/board.sexp", .data = "(design-block board)" });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, "project", std.testing.allocator);
    defer std.testing.allocator.free(project);
    const absolute_source = try std.fmt.allocPrint(std.testing.allocator, "{s}/src/board.sexp", .{project});
    defer std.testing.allocator.free(absolute_source);
    const source = try projectRelativeSource(
        std.testing.allocator,
        project,
        absolute_source,
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings("src/board.sexp", source);
    try std.testing.expectError(
        error.SourceOutsideProject,
        projectRelativeSource(std.testing.allocator, ".", "/etc/passwd"),
    );
}

// ── engineering evidence ───────────────────────────────────────────────

/// A one-rail board: a rated 3.3 V output port, a declared rail carrying a
/// downstream alias, a declared outline and stackup, and a populated BOM with
/// one do-not-populate variant and one test point.
fn engineeringFixture(allocator: std.mem.Allocator) !env_mod.DesignBlock {
    const aliases = try allocator.dupe([]const u8, &.{"VDDA33"});
    return .{
        .name = "engineering-fixture",
        .instances = try allocator.dupe(env_mod.Instance, &.{
            .{ .ref_des = "U1", .label = "U1", .component = "mcu", .value = "mcu", .footprint = "qfn", .symbol = "ic" },
            .{ .ref_des = "C1", .label = "C1", .component = "cap-0402", .value = "100nF", .footprint = "0402", .symbol = "cap" },
            .{ .ref_des = "C2", .label = "C2", .component = "cap-0402", .value = "100nF", .footprint = "0402", .symbol = "cap" },
            .{ .ref_des = "C3", .label = "C3", .component = "cap-0402", .value = "100nF", .footprint = "0402", .symbol = "cap", .dnp = true },
            .{ .ref_des = "TP1", .label = "TP1", .component = "testpoint", .value = "testpoint", .footprint = "tp", .symbol = "tp" },
        }),
        .nets = try allocator.dupe(env_mod.Net, &.{.{ .name = "V3P3", .pins = &.{} }}),
        .ports = try allocator.dupe(env_mod.Port, &.{.{
            .name = "V3P3",
            .net = "V3P3",
            .direction = "out",
            .kind = "power",
            .nominal = 3.3,
            .current_typ = 0.5,
            .current_max = 0.8,
        }}),
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .rails = try allocator.dupe(env_mod.PowerRail, &.{
            .{ .name = "V3P3", .nominal = 3.3, .aliases = aliases },
        }),
        .board = .{ .w = 60, .h = 40, .corner_radius = 2, .present = true },
        .stackup = .{ .layers = 6, .preset = "JLC06161H-3313", .present = true },
    };
}

// spec: system-review - generated power evidence carries each rail's budget row beside the voltage its design declares, including through a ferrite-bridged alias
test "power rail evidence joins the budget to the declared rail voltage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const block = try engineeringFixture(allocator);

    const budget = try power_budget.analyze(allocator, &block);
    const rails = try collectPowerRails(allocator, &block, budget);
    try std.testing.expect(rails.len > 0);
    const rail = for (rails) |candidate| {
        if (std.mem.eql(u8, candidate.net, "V3P3")) break candidate;
    } else return error.MissingRail;
    try std.testing.expectEqual(@as(?f64, 3.3), rail.nominal_v);
    try std.testing.expectEqual(@as(?f64, 0.8), rail.source.max_a);

    // A budget row named after a ferrite-bridged downstream leg still resolves
    // the rail voltage its source-side declaration carries.
    try std.testing.expectEqual(@as(?f64, 3.3), declaredRailVoltage(&block, "VDDA33"));
    try std.testing.expectEqual(@as(?f64, null), declaredRailVoltage(&block, "V1P8"));
}

// spec: system-review - generated thermal evidence is the heat rollup — dissipation, the hottest part, the ambient window and the population the screen actually saw
test "thermal evidence rolls up dissipation and names the hottest part" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parts = [_]thermal.PartThermal{
        .{ .ref_des = "U1", .component = "mcu", .power = .{ .watts = 0.25 } },
        .{ .ref_des = "U2", .component = "pa", .power = .{ .watts = 1.75 } },
        .{ .ref_des = "R1", .component = "res-0402", .power = .{} },
    };
    const heat = try collectThermal(allocator, .{
        .ambient_c = 25,
        .parts = &parts,
        .verdict = .needs_airflow,
        .max_ambient = .{ .c = 61.5, .ref_des = "U2" },
        .min_ambient = .{ .c = -40, .ref_des = "U1" },
        .counts = .{ .with_power = 2, .unknown_power = 1 },
    }, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), heat.total_w, 1e-9);
    try std.testing.expectEqual(@as(usize, 2), heat.coverage.with_power);
    try std.testing.expectEqual(@as(usize, 1), heat.coverage.unknown_power);
    try std.testing.expectEqual(@as(usize, 3), heat.coverage.screened());
    try std.testing.expectEqualStrings("U2", heat.hottest.ref_des);
    try std.testing.expectApproxEqAbs(@as(f64, 1.75), heat.hottest.watts, 1e-9);
    try std.testing.expectEqual(@as(?f64, 61.5), heat.window.max_c);

    // A board where nothing dissipates keeps an empty hottest slot rather than
    // naming an arbitrary part.
    const quiet = try collectThermal(allocator, .{ .ambient_c = 25 }, .{});
    try std.testing.expectEqualStrings("", quiet.hottest.ref_des);
    try std.testing.expectEqual(@as(usize, 0), quiet.coverage.with_power);
}

/// A two-rung ladder at 25 °C whose still-air rung cooks the part and whose
/// 1 m/s rung saves it: the barracuda shape, where the datasheet screen says
/// passive is fine and the board being built needs a fan.
fn airflowLadderFixture() thermal_scenarios.Answer {
    const still = &[_]thermal_scenarios.PartRow{
        .{ .ref = "U2", .tj_c = 141, .board_c = 96, .max_ambient_c = -9.1 },
    };
    const moving = &[_]thermal_scenarios.PartRow{
        .{ .ref = "U2", .tj_c = 96, .board_c = 70, .max_ambient_c = 61.5 },
    };
    const rows = &[_]thermal_scenarios.Row{
        .{ .scenario = .natural, .board_max_c = 96, .max_ambient = .{ .c = -9.1, .ref = "U2" }, .parts = still },
        .{ .scenario = .airflow_1ms, .board_max_c = 70, .max_ambient = .{ .c = 61.5, .ref = "U2" }, .parts = moving },
    };
    return .{ .ladder = .{ .ambient_c = 25, .rows = rows } };
}

// spec: system-review - generated thermal evidence headlines the board-coupled verdict and the window that goes with it, keeping the datasheet package screen only as a labelled estimate
test "thermal evidence headlines the board verdict over the datasheet estimate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The datasheet screen's own answer, on a board whose ladder disagrees.
    const screen: thermal.BoardThermal = .{
        .ambient_c = 25,
        .verdict = .passive_ok,
        .max_ambient = .{ .c = 85, .ref_des = "U2" },
        .min_ambient = .{ .c = -40, .ref_des = "U1" },
        .counts = .{ .with_power = 4, .unknown_power = 5 },
    };

    const coupled = try collectThermal(allocator, screen, airflowLadderFixture());
    try std.testing.expectEqual(thermal.Verdict.needs_airflow, coupled.verdict);
    try std.testing.expect(coupled.model.board_coupled);
    try std.testing.expectEqual(thermal.Verdict.passive_ok, coupled.model.estimate);
    // The window follows the verdict: the governing rung's ceiling, not the
    // datasheet's optimistic one. The cold end is a ratings floor either way.
    try std.testing.expectEqual(@as(?f64, 61.5), coupled.window.max_c);
    try std.testing.expectEqual(@as(?f64, -40), coupled.window.min_c);
    try std.testing.expectEqual(@as(?f64, 85), coupled.model.estimate_window.max_c);

    // With no ladder there is no board answer to prefer, so the estimate is
    // the headline — and `board_coupled` says so rather than leaving a reader
    // to assume the layout was consulted.
    const uncoupled = try collectThermal(allocator, screen, .{});
    try std.testing.expectEqual(thermal.Verdict.passive_ok, uncoupled.verdict);
    try std.testing.expect(!uncoupled.model.board_coupled);
    try std.testing.expectEqual(@as(?f64, 85), uncoupled.window.max_c);
}

/// `count` identical error-severity violations, so a test can drive the
/// retention cap without carrying a loop of its own.
fn appendRepeatedErrors(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(erc.Violation),
    count: usize,
) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try out.append(allocator, .{
        .kind = .floating_net,
        .severity = .@"error",
        .message = "net has a single connection",
        .ref_des = "U1",
        .net = "SPARE",
    });
}

// spec: system-review - generated rule-check evidence counts every ERC severity and assertion outcome, and retains a capped list of the error-severity findings
test "rule-check evidence counts every severity and caps the retained findings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var violations: std.ArrayList(erc.Violation) = .empty;
    try appendRepeatedErrors(allocator, &violations, max_retained_erc_findings + 3);
    try violations.append(allocator, .{ .kind = .missing_decoupling, .severity = .warning, .message = "no bypass cap" });
    try violations.append(allocator, .{ .kind = .missing_decoupling, .severity = .info, .message = "informational" });
    const assertions = [_]review.AssertionReport{
        .{ .message = "ok", .status = .pass },
        .{ .message = "close", .status = .warn },
        .{ .message = "bad", .status = .fail },
    };

    const checks = try collectChecks(allocator, violations.items, &assertions);
    try std.testing.expectEqual(max_retained_erc_findings + 3, checks.errors);
    try std.testing.expectEqual(@as(usize, 1), checks.warnings);
    try std.testing.expectEqual(max_retained_erc_findings, checks.findings.len);
    try std.testing.expect(checks.truncated);
    try std.testing.expectEqualStrings("floating_net", checks.findings[0].kind);
    try std.testing.expectEqual(@as(usize, 1), checks.assertions_pass);
    try std.testing.expectEqual(@as(usize, 1), checks.assertions_warn);
    try std.testing.expectEqual(@as(usize, 1), checks.assertions_fail);

    const clean = try collectChecks(allocator, &.{}, &.{});
    try std.testing.expect(!clean.truncated);
    try std.testing.expectEqual(@as(usize, 0), clean.findings.len);
}

// spec: system-review - generated mechanical evidence pairs the declared outline and stackup with the selected layout's measured edge and flags a drift between them
test "mechanical evidence flags a measured outline that drifted from the declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const block = try engineeringFixture(arena.allocator());

    const alloc = arena.allocator();
    // The fixture declares `(corner-radius 2)`, so the outline that agrees
    // with it is the filleted one — the same geometry the release check
    // compares against, because it is the same predicate.
    const corners = [_][2]f64{ .{ 0, 0 }, .{ 60, 0 }, .{ 60, 40 }, .{ 0, 40 } };
    const radii: [4]f64 = @splat(2);
    const rounded = try outline_mod.filletPath(alloc, &corners, &radii, 0.01);
    const agreeing = try collectMechanical(alloc, &block, .{
        .rect = .{ .minx = 0, .miny = 0, .w = 60, .h = 40 },
        .poly = rounded.poly,
        .arcs = rounded.arcs,
    });
    try std.testing.expect(agreeing.declared.present and agreeing.measured.present);
    try std.testing.expectEqual(outline_mod.Verdict.matches, agreeing.outline);
    try std.testing.expectEqualStrings("JLC06161H-3313", agreeing.stackup_preset);
    try std.testing.expectEqual(@as(u8, 6), agreeing.stackup_layers);

    // The verdict names WHAT drifted, not merely that something did: a board
    // cut 0.5 mm wide, correctly filleted, is a SIZE drift and nothing else.
    const wide_corners = [_][2]f64{ .{ 0, 0 }, .{ 60.5, 0 }, .{ 60.5, 40 }, .{ 0, 40 } };
    const wide = try outline_mod.filletPath(alloc, &wide_corners, &radii, 0.01);
    const drifted = try collectMechanical(alloc, &block, .{
        .rect = .{ .minx = 0, .miny = 0, .w = 60.5, .h = 40 },
        .poly = wide.poly,
        .arcs = wide.arcs,
    });
    try std.testing.expectEqual(outline_mod.Verdict.dimensions, drifted.outline);
    try std.testing.expectEqualStrings("DRIFT (size)", drifted.outline.label());

    // A square saved profile under a rounded declaration is SHAPE drift — the
    // half the mechanical summary used to be blind to.
    const squared = try collectMechanical(alloc, &block, .{ .rect = .{ .minx = 0, .miny = 0, .w = 60, .h = 40 } });
    try std.testing.expectEqual(outline_mod.Verdict.shape, squared.outline);

    // No resolved outline at all ⇒ nothing to compare, so nothing is claimed.
    const unmeasured = try collectMechanical(alloc, &block, null);
    try std.testing.expect(!unmeasured.measured.present);
    try std.testing.expectEqual(outline_mod.Verdict.not_compared, unmeasured.outline);
}

/// The recess-in-one-edge board the `(board …)` rectangle cannot describe:
/// big corner fillets, small recess fillets, a bbox of exactly 40 x 20 mm.
fn notchedOutline(alloc: std.mem.Allocator) !outline_mod.Saved {
    const pts = [_][2]f64{
        .{ 0, 0 },   .{ 40, 0 },  .{ 40, 20 }, .{ 25, 20 },
        .{ 25, 14 }, .{ 15, 14 }, .{ 15, 20 }, .{ 0, 20 },
    };
    const radii = [_]f64{ 2, 2, 2, 0.9, 0.9, 0.9, 0.9, 2 };
    const cut = try outline_mod.filletPath(alloc, &pts, &radii, 0.01);
    return .{
        .rect = .{ .minx = 0, .miny = 0, .w = 40, .h = 20 },
        .poly = cut.poly,
        .arcs = cut.arcs,
    };
}

// spec: system-review - the mechanical summary and the fabrication-readiness outline finding are the same predicate, agreeing on an unapproved, an approved, and a stale-pinned non-rectangular outline alike
test "the mechanical summary and the readiness outline finding cannot disagree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var block = try engineeringFixture(alloc);
    block.board = .{ .w = 40, .h = 20, .present = true };
    const saved = try notchedOutline(alloc);

    // Unapproved: the readiness surface reports it, and the document surface
    // says the same thing in the same words rather than claiming a match.
    const open_mech = try collectMechanical(alloc, &block, saved);
    const open_finding = try fab_readiness.outlineDrift(alloc, fab_readiness.declaredOutline(block.board), saved);
    try std.testing.expectEqual(outline_mod.Verdict.shape, open_mech.outline);
    try std.testing.expect(open_finding != null);
    try std.testing.expectEqualStrings("outline-drift", open_finding.?.id);

    // Approved: both surfaces clear on the pin, and neither on the other's say-so.
    const pin = try outline_mod.digest(alloc, saved);
    block.board.outline_approved = &pin;
    const clean_mech = try collectMechanical(alloc, &block, saved);
    const clean_finding = try fab_readiness.outlineDrift(alloc, fab_readiness.declaredOutline(block.board), saved);
    try std.testing.expectEqual(outline_mod.Verdict.approved, clean_mech.outline);
    try std.testing.expect(clean_finding == null);
    try std.testing.expectEqualStrings("approved shape", clean_mech.outline.label());

    // Stale: both surfaces fire again, and the document says WHICH kind.
    block.board.outline_approved = "0123456789abcdef";
    const stale_mech = try collectMechanical(alloc, &block, saved);
    const stale_finding = try fab_readiness.outlineDrift(alloc, fab_readiness.declaredOutline(block.board), saved);
    try std.testing.expectEqual(outline_mod.Verdict.stale_approval, stale_mech.outline);
    try std.testing.expectEqualStrings("DRIFT (stale approval)", stale_mech.outline.label());
    try std.testing.expect(stale_finding != null);
    try std.testing.expect(std.mem.indexOf(u8, stale_finding.?.message, "0123456789abcdef") != null);
}

// spec: system-review - generated loop-filter evidence copies each PLL report's screens out of the evaluator, keeping only the non-passing ones beside the population verdict counts
test "loop-filter evidence copies screens and retains only the failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var name_buffer = "chirp-loop".*;
    var message_buffer = "phase margin 31.2 deg below 45.0 deg target".*;
    const verdicts = [_]pll_loop.Verdict{
        .{ .screen = .nominal_sweep, .status = .pass, .message = "ok" },
        .{ .screen = .nominal_phase_target, .status = .fail, .message = &message_buffer },
        .{ .screen = .pfd_ratio, .status = .warn, .message = "advisory" },
    };
    const populations = [_]pll_loop.Population{.{
        .kind = .fitted,
        .verdicts = &verdicts,
        .results = .{ .nominal = .{ .corners = 3, .min_bandwidth_hz = 1200, .max_bandwidth_hz = 3400 } },
    }};
    const schedule = [_]pll_loop.ScheduleEntry{.{ .pll_n = 200, .kvco_hz_per_v = 6e7, .step = 4, .current_a = 2.5e-3 }};
    const reports = [_]pll_loop.Report{.{
        .name = &name_buffer,
        .mode = .gate,
        .outcome = .screened,
        .profile = .{ .pfd_hz = 1e6, .pll_n = 200, .charge_pump_a = 2.5e-3 },
        .populations = &populations,
        .schedule = &schedule,
    }};

    const copied = try collectPllReports(allocator, &reports);
    try std.testing.expectEqual(@as(usize, 1), copied.len);
    try std.testing.expectEqualStrings("chirp-loop", copied[0].name);
    try std.testing.expectEqual(@as(usize, 1), copied[0].schedule.len);
    const population = copied[0].populations[0];
    try std.testing.expectEqual(@as(usize, 1), population.pass);
    try std.testing.expectEqual(@as(usize, 1), population.warn);
    try std.testing.expectEqual(@as(usize, 1), population.fail);
    try std.testing.expectEqual(@as(usize, 2), population.failing.len);
    try std.testing.expectEqualStrings("nominal_phase_target", population.failing[0].screen);

    // The evaluator's buffers are its own: overwriting them must not disturb
    // anything the snapshot retained.
    @memset(&name_buffer, 'x');
    @memset(&message_buffer, 'x');
    try std.testing.expectEqualStrings("chirp-loop", copied[0].name);
    try std.testing.expectEqualStrings("phase margin 31.2 deg below 45.0 deg target", population.failing[0].message);
}

// spec: system-review - generated frequency-plan evidence copies each declaration's screens out of the evaluator, keeps only the non-passing ones, and retains each product's band hull rather than its branches
test "frequency-plan evidence copies screens and retains the product hulls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var name_buffer = "Barracuda Band 1".*;
    var message_buffer = "leaves the delivered passband".*;
    const verdicts = [_]frequency_plan.Verdict{
        .{ .screen = .lo_drive, .status = .pass, .message = "ok" },
        .{ .screen = .band_closure, .status = .fail, .message = &message_buffer },
        .{ .screen = .spur_coverage, .status = .warn, .message = "no declared suppression" },
    };
    const products = [_]frequency_plan.Product{.{
        .order = .{ .m = 2, .n = 2 },
        // Two monotone branches whose hull is what a table must render.
        .branches = .{ .parts = .{ .{ .lo_hz = 0, .hi_hz = 3e8 }, .{ .lo_hz = 0, .hi_hz = 3e9 } }, .len = 2 },
        .band = .{ .lo_hz = 0, .hi_hz = 3e9 },
        .placement = .co_channel,
        .level = .{ .dbc = -62, .declared = true, .verdict = .within_limit },
    }};
    const plans = [_]frequency_plan.SidebandPlan{.{
        .sideband = .high,
        .rf = .{ .required = .{ .lo_hz = 11e9, .hi_hz = 12.45e9 }, .covered_checked = true },
        .diagonal = .{ .worst_case_count = 29, .enumerated_count = 4 },
        .products = &products,
        .verdicts = &verdicts,
    }};
    const reports = [_]frequency_plan.Report{.{
        .name = &name_buffer,
        .mode = .gate,
        .outcome = .screened,
        .profile = .{ .spurs = .{ .max_order = 5, .in_band_limit_dbc = -60, .limit_declared = true } },
        .plans = &plans,
    }};

    const copied = try collectFrequencyPlans(allocator, &reports);
    try std.testing.expectEqual(@as(usize, 1), copied.len);
    try std.testing.expectEqualStrings("Barracuda Band 1", copied[0].name);
    try std.testing.expectEqual(@as(u8, 5), copied[0].profile.spurs.max_order);
    const plan = copied[0].plans[0];
    try std.testing.expectEqual(@as(usize, 1), plan.screens.pass);
    try std.testing.expectEqual(@as(usize, 1), plan.screens.warn);
    try std.testing.expectEqual(@as(usize, 1), plan.screens.fail);
    try std.testing.expectEqual(@as(usize, 2), plan.screens.failing.len);
    try std.testing.expectEqualStrings("band_closure", plan.screens.failing[0].screen);
    // Both diagonal counts survive the copy, unconflated.
    try std.testing.expectEqual(@as(usize, 29), plan.diagonal.worst_case_count);
    try std.testing.expectEqual(@as(usize, 4), plan.diagonal.enumerated_count);
    // The retained row is the hull; the branches are deliberately not carried.
    try std.testing.expectEqual(@as(usize, 1), plan.spurs.rows.len);
    try std.testing.expectEqual(@as(usize, 1), plan.spurs.enumerated);
    try std.testing.expectEqual(@as(f64, 3e9), plan.spurs.rows[0].band.hi_hz);
    try std.testing.expect(!@hasField(SpurProduct, "branches"));

    // The evaluator's buffers are its own: overwriting them must not disturb
    // anything the snapshot retained.
    @memset(&name_buffer, 'x');
    @memset(&message_buffer, 'x');
    try std.testing.expectEqualStrings("Barracuda Band 1", copied[0].name);
    try std.testing.expectEqualStrings("leaves the delivered passband", plan.screens.failing[0].message);
}

// spec: system-review - the generated BOM rollup counts the exact placements, lines and do-not-populate parts the archived bom.csv carries
test "BOM rollup matches the archived CSV grouping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const block = try engineeringFixture(allocator);

    const rollup = try bom_html.rollupBom(allocator, &block);
    // Four sourced parts: the test point is a probe pad, not a purchased line.
    try std.testing.expectEqual(@as(usize, 4), rollup.placements);
    // The MCU, the populated 100nF pair, and the do-not-populate variant of the
    // same part, which the CSV keeps as its own line.
    try std.testing.expectEqual(@as(usize, 3), rollup.lines);
    try std.testing.expectEqual(@as(usize, 1), rollup.dnp_placements);
    try std.testing.expectEqual(@as(usize, 1), rollup.dnp_lines);
}
