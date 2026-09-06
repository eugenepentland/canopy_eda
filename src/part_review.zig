//! The per-part review: one placed part's whole contract in one record.
//!
//! Every fact below is already computed somewhere in this binary — identity in
//! the BOM resolve path, class and unmet obligations in `review_profiles`, the
//! datasheet-review record on the instance itself, requirement outcomes in
//! `preflight`, applied stress against rating in the fabrication gate's rating
//! screen, current draw in `eval/power_budget`, junction temperature in
//! `eval/thermal`, PDF coverage in `review_datasheet_inventory`. What did not
//! exist was a join: nothing keyed those five modules by ref-des, so "does this
//! component meet its spec" was answerable only by reading five outputs.
//!
//! `collect` runs each engine ONCE for the whole board and then attributes its
//! findings per part, so the per-part endpoint and the whole-BOM chip endpoint
//! cost the same evaluation. No geometry is resolved: the rating screen is
//! entered through `fab_readiness.ratingReport` over a board-free placement, so
//! a design that has never been placed still gets its ratings judged.
//!
//! Refs are sub-block-qualified (`ldo_3v3_lmx/U21`) — the spelling the BOM tab,
//! the flattened netlist, the power budget and the thermal screen all use.
//! Preflight and the profile evaluation work in the LEAF ref-des space (ref-des
//! are globally unique once a block is materialized), so findings are attributed
//! on the leaf plus the component name, exactly as `review_audit` does.
//!
//! Read-only: nothing here writes to the project directory.

const std = @import("std");
const bom = @import("bom.zig");
const component_classification = @import("component_classification.zig");
const env = @import("eval/env.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const fab_readiness = @import("fab_readiness.zig");
const fab_schematic_gate = @import("fab_schematic_gate.zig");
const flat_netlist = @import("flat_netlist.zig");
const impedance_rules = @import("placement/impedance_rules.zig");
const json_writer = @import("json_writer.zig");
const net_name = @import("net_name.zig");
const optimizer = @import("placement/optimizer.zig");
const paths = @import("paths.zig");
const power_budget = @import("eval/power_budget.zig");
const preflight = @import("preflight.zig");
const review_datasheet_inventory = @import("review_datasheet_inventory.zig");
const review_profiles = @import("review_profiles.zig");
const brief_checks = @import("brief_checks.zig");
const review_thermal = @import("review_thermal.zig");
const thermal = @import("eval/thermal.zig");

/// The seven words every review surface states a verdict in. `unproven` means
/// the engine ran and names the missing input; `waived` means a record is
/// linked; `not_applicable` means the population is absent; `not_declared`
/// means the board never gave the engine an input at all; `manual` means only
/// a person can close it.
pub const Verdict = enum {
    pass,
    fail,
    unproven,
    waived,
    not_applicable,
    not_declared,
    manual,

    /// The verdict's wire spelling — the tag name, so the JSON, the chips and
    /// the registry vocabulary cannot drift apart.
    pub fn key(self: Verdict) []const u8 {
        return @tagName(self);
    }
};

/// How many rows of a part produced each verdict.
pub const Counts = struct {
    pass: usize = 0,
    fail: usize = 0,
    unproven: usize = 0,
    waived: usize = 0,
    not_applicable: usize = 0,
    not_declared: usize = 0,
    manual: usize = 0,

    /// Tally one more row.
    pub fn add(self: *Counts, verdict: Verdict) void {
        switch (verdict) {
            .pass => self.pass += 1,
            .fail => self.fail += 1,
            .unproven => self.unproven += 1,
            .waived => self.waived += 1,
            .not_applicable => self.not_applicable += 1,
            .not_declared => self.not_declared += 1,
            .manual => self.manual += 1,
        }
    }

    /// The verdict a chip shows for a GROUP of identical parts: the worst any
    /// member reported. Fail beats not-declared beats unproven beats manual
    /// beats pass — the order a reviewer triages in.
    pub fn worst(self: Counts) Verdict {
        if (self.fail > 0) return .fail;
        if (self.not_declared > 0) return .not_declared;
        if (self.unproven > 0) return .unproven;
        if (self.manual > 0) return .manual;
        if (self.pass > 0) return .pass;
        return .not_applicable;
    }
};

/// The datasheet page a rule was taken from.
pub const Citation = struct {
    pdf: []const u8 = "",
    page: u32 = 0,
    quote: []const u8 = "",
};

/// One cited requirement as it stands on THIS placement: what the datasheet
/// demands, what the check engine said, and who signed it off if anyone did.
pub const RequirementRow = struct {
    id: []const u8,
    text: []const u8,
    citation: ?Citation = null,
    /// `library` for a rule the component declares, `design` for one the board
    /// wrote about itself.
    source: []const u8 = "library",
    /// The check primitive's form name (`voltage-range`, `decoupling`, …), or
    /// "" for a prose-only rule no engine can judge.
    check: []const u8 = "",
    /// The preflight finding status tag (`pass`, `pending`, `unproven`, …).
    status: []const u8,
    verdict: Verdict,
    /// What the check said, or the sign-off rationale when one closed it.
    message: []const u8,
    /// Who signed the rule off, "" when nobody did.
    signed_off_by: []const u8 = "",
    /// The sign-off's own prose, "" when there is no sign-off.
    rationale: []const u8 = "",
};

/// One supply pin's recommended window and whether the board's envelope sits
/// inside it — the `voltage-range` requirements, pulled out of the requirement
/// list because "is every supply pin inside its window" is the question a
/// reviewer asks first.
pub const SupplyWindow = struct {
    pin: []const u8,
    min_v: f64,
    max_v: f64,
    status: []const u8,
    verdict: Verdict,
    message: []const u8,
};

/// One applied-stress-versus-rating or authored-spec finding for the part,
/// carrying the fabrication gate's own finding id.
pub const RatingRow = struct {
    id: []const u8,
    severity: []const u8,
    message: []const u8,
    verdict: Verdict,
};

/// One unmet component-class profile obligation.
pub const ProfileRow = struct {
    code: []const u8,
    message: []const u8,
};

/// What the part draws from one rail, and its share of that rail's typical
/// load.
pub const PowerRow = struct {
    rail: []const u8,
    net: []const u8,
    pins: []const []const u8,
    i_typ: ?f64 = null,
    i_max: ?f64 = null,
    /// Percentage of the rail's typical load this row accounts for. Null when
    /// the rail has no annotated typical load to take a share of.
    share_pct: ?f64 = null,
};

/// The part's thermal row, already formatted by `review_thermal.cells` so the
/// spec sheet, the thermal tab and the review PDF round identically.
pub const ThermalRow = struct {
    ambient_c: f64,
    power: []const u8,
    theta: []const u8,
    tj: []const u8,
    margin: []const u8,
    max_ambient: []const u8,
    /// True when the part declares a dissipation figure of its own or one was
    /// derived; false means the screen had no heat to work from.
    has_power: bool,
};

/// The library's digest-bound datasheet-review record, as authored.
pub const ReviewRecord = struct {
    present: bool = false,
    datasheet: []const u8 = "",
    sha256: []const u8 = "",
    /// True when the record names a PDF digest at all — an unbound record
    /// cannot go stale, which is the point of binding it.
    digest_bound: bool = false,
    status: []const u8 = "",
    reviewed_by: []const u8 = "",
    date: []const u8 = "",
    categories: []const []const u8 = &.{},
    not_applicable: []const env.DatasheetReviewNa = &.{},
};

/// The datasheet-compliance block: the preflight verdict on the review, the
/// record it judged, and whether the exact fitted part's PDF is readable here.
pub const DatasheetBlock = struct {
    status: []const u8 = "missing",
    verdict: Verdict = .not_declared,
    message: []const u8 = "",
    record: ReviewRecord = .{},
    /// `local`, `remote_only`, `missing`, `missing_mpn`, or "" when the
    /// generated BOM could not be read.
    inventory: []const u8 = "",
};

/// A part's identity as the BOM resolve path settled it.
pub const Identity = struct {
    value: []const u8 = "",
    footprint: []const u8 = "",
    mpn: []const u8 = "",
    manufacturer: []const u8 = "",
    datasheet: []const u8 = "",
    dnp: bool = false,
    attrs: []const []const u8 = &.{},
    properties: []const env.Property = &.{},
};

/// One placed part's whole review contract.
pub const PartReview = struct {
    /// Sub-block-qualified ref (`ldo_3v3_lmx/U21`).
    ref: []const u8,
    /// The bare ref-des (`U21`) — the space preflight and ERC name parts in.
    ref_leaf: []const u8,
    /// The sub-block path the part sits in, "" at the root.
    block_path: []const u8 = "",
    component: []const u8,
    /// True for a part the class profiles and the datasheet review apply to.
    active: bool = false,
    class: []const u8 = "",
    /// True when the part's class was authored rather than inferred from pins.
    class_declared: bool = false,
    identity: Identity = .{},
    counts: Counts = .{},
    datasheet: DatasheetBlock = .{},
    profile_items: []const ProfileRow = &.{},
    requirements: []const RequirementRow = &.{},
    supply_windows: []const SupplyWindow = &.{},
    ratings: []const RatingRow = &.{},
    power: []const PowerRow = &.{},
    thermal: ?ThermalRow = null,
    electrical: []const env.ElectricalDecl = &.{},

    /// The compact chip this part contributes to the BOM's Review column.
    pub fn chip(self: PartReview) Chip {
        return .{
            .ref = self.ref,
            .class = self.class,
            .pass = self.counts.pass + self.counts.waived,
            .unproven = self.counts.unproven + self.counts.manual,
            .fail = self.counts.fail,
            .not_declared = self.counts.not_declared,
        };
    }
};

/// The BOM Review column's payload for one placed part: the four numbers the
/// chip prints, plus the class it was judged under.
pub const Chip = struct {
    ref: []const u8,
    class: []const u8,
    pass: usize = 0,
    unproven: usize = 0,
    fail: usize = 0,
    not_declared: usize = 0,
};

/// Every placed part of one design, reviewed.
pub const Board = struct {
    design: []const u8,
    ambient_c: f64 = thermal.default_ambient_c,
    parts: []const PartReview = &.{},

    /// The review of one sub-block-qualified ref, or null when the design has
    /// no such placement. A bare leaf ref matches too, so an agent that only
    /// knows `U21` need not learn the module path first.
    pub fn find(self: Board, ref: []const u8) ?PartReview {
        for (self.parts) |part| if (std.mem.eql(u8, part.ref, ref)) return part;
        for (self.parts) |part| if (std.mem.eql(u8, part.ref_leaf, ref)) return part;
        return null;
    }
};

/// Everything `collect` can fail with beyond allocation.
pub const CollectError = std.mem.Allocator.Error || error{ EvaluateFailed, NotADesign, InvalidName };

/// What to screen at. The ambient only reaches the thermal row.
pub const Options = struct {
    ambient_c: ?f64 = null,
};

// ── Verdict mapping ───────────────────────────────────────────────────────

/// The verdict a preflight requirement status states. `pending` is `manual`:
/// the rule is cited but no engine can judge it, so only a `(verifies …)`
/// closes it. `deferred` is `unproven` here because the netlist surface ran
/// and cannot decide — the layout lint is the missing input.
fn requirementVerdict(status: preflight.FindingStatus) Verdict {
    return switch (status) {
        .pass => .pass,
        .fail, .stale => .fail,
        .verified => .waived,
        .pending => .manual,
        .unproven, .incomplete, .deferred => .unproven,
        .missing => .not_declared,
    };
}

/// The verdict a datasheet-review finding states. A missing record is
/// `not_declared` (nothing was ever authored); a stale one is a `fail`,
/// because the PDF moved under a review that claims to bind it.
fn reviewVerdict(status: preflight.FindingStatus) Verdict {
    return switch (status) {
        .pass, .verified => .pass,
        .stale, .fail => .fail,
        .missing => .not_declared,
        else => .unproven,
    };
}

/// The verdict a fabrication-gate rating/spec finding states, by id. Missing
/// evidence is `not_declared` — the board never gave the screen an input —
/// while an inconclusive screen is `unproven` and everything else is a fail.
fn ratingVerdict(id: []const u8) Verdict {
    if (std.mem.endsWith(u8, id, "-missing")) return .not_declared;
    if (std.mem.endsWith(u8, id, "-unproven")) return .unproven;
    if (std.mem.endsWith(u8, id, "-margin")) return .unproven;
    return .fail;
}

/// The form name of a requirement's check primitive, or "" when the rule
/// carries no executable check.
fn checkName(check: ?env.Check) []const u8 {
    const value = check orelse return "";
    return switch (value) {
        .connected => "connected",
        .decoupling => "decoupling",
        .pullup_range => "pullup-range",
        .voltage_range => "voltage-range",
        .tied_to_net => "tied-to-net",
        .not_connected => "not-connected",
        .pin_not_floating => "pin-not-floating",
        .pins_on_same_net => "pins-on-same-net",
        .decoupling_per_pin => "decoupling-per-pin",
        else => @tagName(value),
    };
}

// ── Collection ────────────────────────────────────────────────────────────

/// Everything one board-wide run computed once, ready to be attributed to a
/// part. Held as one struct so the per-part builder stays inside the runtime
/// parameter budget.
const Evidence = struct {
    arena: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env.DesignBlock,
    forms: review_profiles.Forms,
    report: preflight.Report,
    rails: []const power_budget.Rail,
    heat: thermal.BoardThermal,
    ratings: []const fab_readiness.Item,
    rating_warnings: []const fab_readiness.Item,
    specs: []const fab_readiness.Item,
    inventory: []const review_datasheet_inventory.Row,
};

/// Review every placed part of `name`. `arena` must outlive the result; every
/// string in it is either arena-owned or borrowed from the evaluated block,
/// which the arena also owns.
pub fn collect(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
) CollectError!Board {
    var eval = Evaluator.init(arena, project_dir);
    defer eval.deinit();
    return collectWith(arena, &eval, project_dir, name, options);
}

/// The same review, over an evaluator the CALLER owns and keeps alive.
///
/// The server wants both: the review, and the file read-set the evaluation
/// touched, so the answer can be retained against it. `eval` must be freshly
/// initialised over `project_dir` — this evaluates the design into it — and
/// must outlive the returned `Board`, which borrows strings from the block.
pub fn collectWith(
    arena: std.mem.Allocator,
    eval: *Evaluator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
) CollectError!Board {
    const board_path = try paths.designSourcePath(arena, project_dir, name);
    const result = eval.evalFile(board_path) catch return error.EvaluateFailed;
    const block = switch (result) {
        .design_block => |b| b,
        else => return error.NotADesign,
    };
    return collectFor(arena, eval, block, project_dir, name, options);
}

/// The same review, over a design the CALLER already evaluated into an
/// evaluator it keeps alive. The Board Review Card composes this review beside
/// the audit's facts over ONE evaluation — evaluating the same file twice into
/// one evaluator would double the analysis reports it collects — so this is the
/// seam that takes the block rather than the path.
pub fn collectFor(
    arena: std.mem.Allocator,
    eval: *Evaluator,
    block: *const env.DesignBlock,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
) CollectError!Board {
    const bom_path = try paths.designSiblingPath(arena, project_dir, name, ".bom");
    // A `.bom` sidecar that is missing or unreadable is a NORMAL state — the
    // design may never have been built — and every identity the review needs is
    // still on the instance as authored. So the merge is best-effort and its
    // failure changes nothing but which MPN string the sheet shows.
    bom.applyExisting(arena, block, bom_path, project_dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };

    const report = try preflight.runFor(arena, eval, block, project_dir, .release, name);
    const rating = try ratingReportFor(arena, block, brief_checks.deratingForBoard(arena, project_dir, name));
    const evidence = Evidence{
        .arena = arena,
        .project_dir = project_dir,
        .block = block,
        .forms = formsOf(eval),
        .report = report,
        .rails = try power_budget.analyze(arena, block),
        .heat = try brief_checks.analyzeGoverned(arena, block, project_dir, name, options.ambient_c),
        .ratings = rating.errors,
        .rating_warnings = rating.warnings,
        .specs = try fab_schematic_gate.selectionReport(arena, block, project_dir, false),
        .inventory = review_datasheet_inventory.collect(arena, project_dir, name) catch &.{},
    };

    var parts: std.ArrayList(PartReview) = .empty;
    try walkParts(evidence, block, "", &parts);
    return .{
        .design = name,
        .ambient_c = evidence.heat.ambient_c,
        .parts = try parts.toOwnedSlice(arena),
    };
}

/// Which analysis forms the design declared, and whether every one of them
/// gates — the input `review_profiles` needs to judge an `analysis-form` item.
fn formsOf(eval: *const Evaluator) review_profiles.Forms {
    var forms: review_profiles.Forms = .{};
    var pll_gate = true;
    for (eval.pll_reports.items) |report| {
        forms.pll_any = true;
        if (report.mode != .gate) pll_gate = false;
    }
    forms.pll_gate = forms.pll_any and pll_gate;
    var plan_gate = true;
    for (eval.frequency_plan_reports.items) |report| {
        forms.plan_any = true;
        if (report.mode != .gate) plan_gate = false;
    }
    forms.plan_gate = forms.plan_any and plan_gate;
    return forms;
}

/// Run the release gate's rating screen over a BOARD-FREE placement built from
/// the flattened netlist and the analysed rails. No layout is resolved: the
/// screen reads instances, nets and the physical rail model, and nothing else.
fn ratingReportFor(
    arena: std.mem.Allocator,
    block: *const env.DesignBlock,
    derating: ?brief_checks.Derating,
) std.mem.Allocator.Error!fab_readiness.Report {
    var instances: std.ArrayList(flat_netlist.FlatInstance) = .empty;
    try flat_netlist.collectInstances(arena, block, "", &instances);
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, block, &nets);
    const model: impedance_rules.RailModel = .{
        .specs = block.rails,
        .net_envelopes = block.envelopes.published,
        .branch_loads = try power_budget.branchLoads(arena, block),
        .intents = block.pdn_intents,
    };
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = instances.items,
        .nets = nets.items,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = false,
        .rules = .{ .physical = .{
            .rails = try power_budget.analyze(arena, block),
            .rail_model = model,
        } },
    };
    return fab_readiness.ratingReport(arena, placement, false, derating);
}

fn walkParts(
    evidence: Evidence,
    block: *const env.DesignBlock,
    prefix: []const u8,
    out: *std.ArrayList(PartReview),
) std.mem.Allocator.Error!void {
    const arena = evidence.arena;
    for (block.instances) |inst| {
        if (inst.placeholder or env.isTestPoint(inst.component)) continue;
        const ref = if (prefix.len == 0)
            inst.ref_des
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, inst.ref_des });
        try out.append(arena, try buildPart(evidence, block, inst, ref));
    }
    for (block.sub_blocks) |sub| {
        const child = if (prefix.len == 0)
            sub.name
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, sub.name });
        try walkParts(evidence, sub.block, child, out);
    }
}

fn buildPart(
    evidence: Evidence,
    block: *const env.DesignBlock,
    inst: env.Instance,
    ref: []const u8,
) std.mem.Allocator.Error!PartReview {
    const arena = evidence.arena;
    const active = component_classification.isActiveSemiconductor(inst);
    const resolved = review_profiles.resolve(arena, evidence.project_dir, inst);
    var part = PartReview{
        .ref = ref,
        .ref_leaf = net_name.leaf(ref),
        .block_path = net_name.parent(ref) orelse "",
        .component = inst.component,
        .active = active,
        .class = resolved.class.key(),
        .class_declared = resolved.declared,
        .identity = identityOf(inst),
        .electrical = inst.electrical,
    };
    part.requirements = try requirementRows(evidence, inst);
    part.supply_windows = try supplyWindows(arena, inst, part.requirements);
    part.ratings = try ratingRows(evidence, ref);
    part.power = try powerRows(arena, evidence.rails, ref);
    part.thermal = try thermalRow(arena, evidence.heat, ref);
    if (active) {
        part.datasheet = try datasheetBlock(evidence, inst, ref);
        part.profile_items = try profileRows(evidence, block, inst);
    }
    part.counts = tally(part);
    return part;
}

fn identityOf(inst: env.Instance) Identity {
    var identity = Identity{
        .value = inst.value,
        .footprint = inst.footprint,
        .dnp = inst.dnp,
        .attrs = inst.attrs,
        .properties = inst.properties,
    };
    for (inst.properties) |property| {
        if (std.mem.eql(u8, property.key, "mpn")) identity.mpn = property.value;
        if (std.mem.eql(u8, property.key, "manufacturer")) identity.manufacturer = property.value;
        if (std.mem.eql(u8, property.key, "datasheet")) identity.datasheet = property.value;
    }
    if (identity.datasheet.len == 0 and inst.docs.datasheets.len > 0) {
        identity.datasheet = inst.docs.datasheets[0];
    }
    return identity;
}

/// True when `finding` was raised about `inst`. Preflight names parts by leaf
/// ref-des, which is unique once the block is materialized; the component name
/// is compared too so a design rule that borrowed the ref cannot be mistaken
/// for a library rule on the part.
fn findingIsAbout(finding: preflight.Finding, inst: env.Instance) bool {
    if (!std.mem.eql(u8, finding.ref_des, inst.ref_des)) return false;
    if (finding.requirement.source == .design) return true;
    return std.mem.eql(u8, finding.component, inst.component);
}

fn requirementRows(
    evidence: Evidence,
    inst: env.Instance,
) std.mem.Allocator.Error![]const RequirementRow {
    const arena = evidence.arena;
    var rows: std.ArrayList(RequirementRow) = .empty;
    for (evidence.report.findings) |finding| {
        if (finding.kind != .requirement or !findingIsAbout(finding, inst)) continue;
        const signature = signOff(evidence.block, inst, finding.requirement.id);
        try rows.append(arena, .{
            .id = finding.requirement.id,
            .text = finding.requirement.text,
            .citation = citationOf(finding.requirement.citation),
            .source = @tagName(finding.requirement.source),
            .check = checkForId(inst, finding.requirement.id),
            .status = @tagName(finding.status),
            .verdict = requirementVerdict(finding.status),
            .message = finding.message,
            .signed_off_by = if (signature) |v| v.signed_by else "",
            .rationale = if (signature) |v| v.rationale else "",
        });
    }
    return try rows.toOwnedSlice(arena);
}

fn citationOf(ref: ?env.NoteRef) ?Citation {
    const value = ref orelse return null;
    return .{ .pdf = value.pdf, .page = value.page, .quote = value.quote orelse "" };
}

fn checkForId(inst: env.Instance, id: []const u8) []const u8 {
    for (inst.requirements) |requirement| {
        if (std.mem.eql(u8, requirement.id, id)) return checkName(requirement.check);
    }
    return "";
}

/// The design-side `(verifies …)` that answers `req_id` on this part, or null.
/// Searched by stable instance id first, then by ref-des — the two spellings
/// the form accepts — over the whole block tree, because a sign-off may be
/// authored in the module that placed the part or at the root.
fn signOff(
    block: *const env.DesignBlock,
    inst: env.Instance,
    req_id: []const u8,
) ?env.Verification {
    for (block.verifications) |verification| {
        if (!std.mem.eql(u8, verification.req_id, req_id)) continue;
        if (verification.target_id.len > 0) {
            if (std.mem.eql(u8, verification.target_id, inst.id)) return verification;
            continue;
        }
        if (std.mem.eql(u8, verification.ref_des, inst.ref_des)) return verification;
    }
    for (block.sub_blocks) |sub| {
        if (signOff(sub.block, inst, req_id)) |found| return found;
    }
    return null;
}

fn supplyWindows(
    arena: std.mem.Allocator,
    inst: env.Instance,
    rows: []const RequirementRow,
) std.mem.Allocator.Error![]const SupplyWindow {
    var out: std.ArrayList(SupplyWindow) = .empty;
    for (inst.requirements) |requirement| {
        const check = requirement.check orelse continue;
        if (check != .voltage_range) continue;
        const row = rowForId(rows, requirement.id);
        try out.append(arena, .{
            .pin = check.voltage_range.pin,
            .min_v = check.voltage_range.min_v,
            .max_v = check.voltage_range.max_v,
            .status = if (row) |r| r.status else "missing",
            .verdict = if (row) |r| r.verdict else .not_declared,
            .message = if (row) |r| r.message else "",
        });
    }
    return try out.toOwnedSlice(arena);
}

fn rowForId(rows: []const RequirementRow, id: []const u8) ?RequirementRow {
    for (rows) |row| if (std.mem.eql(u8, row.id, id)) return row;
    return null;
}

fn appendRatings(
    arena: std.mem.Allocator,
    out: *std.ArrayList(RatingRow),
    items: []const fab_readiness.Item,
    severity: []const u8,
    ref: []const u8,
) std.mem.Allocator.Error!void {
    for (items) |item| {
        const item_ref = item.ref orelse continue;
        if (!std.mem.eql(u8, item_ref, ref)) continue;
        try out.append(arena, .{
            .id = item.id,
            .severity = severity,
            .message = item.message,
            .verdict = ratingVerdict(item.id),
        });
    }
}

fn ratingRows(evidence: Evidence, ref: []const u8) std.mem.Allocator.Error![]const RatingRow {
    const arena = evidence.arena;
    var out: std.ArrayList(RatingRow) = .empty;
    try appendRatings(arena, &out, evidence.ratings, "error", ref);
    try appendRatings(arena, &out, evidence.specs, "error", ref);
    try appendRatings(arena, &out, evidence.rating_warnings, "warning", ref);
    return try out.toOwnedSlice(arena);
}

fn powerRows(
    arena: std.mem.Allocator,
    rails: []const power_budget.Rail,
    ref: []const u8,
) std.mem.Allocator.Error![]const PowerRow {
    var out: std.ArrayList(PowerRow) = .empty;
    for (rails) |rail| {
        for (rail.consumers) |consumer| {
            if (!std.mem.eql(u8, consumer.ref_des, ref)) continue;
            try out.append(arena, .{
                .rail = rail.net,
                .net = consumer.net,
                .pins = consumer.pins,
                .i_typ = consumer.i_typ,
                .i_max = consumer.i_max,
                .share_pct = sharePct(rail, consumer.i_typ),
            });
        }
    }
    return try out.toOwnedSlice(arena);
}

fn sharePct(rail: power_budget.Rail, i_typ: ?f64) ?f64 {
    const draw = i_typ orelse return null;
    if (rail.load_typ_a <= 0) return null;
    return 100.0 * draw / rail.load_typ_a;
}

fn thermalRow(
    arena: std.mem.Allocator,
    heat: thermal.BoardThermal,
    ref: []const u8,
) std.mem.Allocator.Error!?ThermalRow {
    for (heat.parts) |row| {
        if (!std.mem.eql(u8, row.ref_des, ref)) continue;
        const cells = try review_thermal.cells(arena, row);
        return .{
            .ambient_c = heat.ambient_c,
            .power = cells.power,
            .theta = cells.theta,
            .tj = cells.tj,
            .margin = cells.margin,
            .max_ambient = cells.max_ambient,
            .has_power = row.power.watts != null,
        };
    }
    return null;
}

fn datasheetBlock(
    evidence: Evidence,
    inst: env.Instance,
    ref: []const u8,
) std.mem.Allocator.Error!DatasheetBlock {
    var out = DatasheetBlock{ .record = recordOf(inst) };
    for (evidence.report.findings) |finding| {
        if (finding.kind != .datasheet_review or !findingIsAbout(finding, inst)) continue;
        out.status = @tagName(finding.status);
        out.verdict = reviewVerdict(finding.status);
        out.message = finding.message;
    }
    out.inventory = inventoryStatus(evidence.inventory, ref);
    return out;
}

fn recordOf(inst: env.Instance) ReviewRecord {
    const review = inst.docs.review orelse return .{};
    return .{
        .present = true,
        .datasheet = review.datasheet,
        .sha256 = review.sha256,
        .digest_bound = review.sha256.len > 0,
        .status = @tagName(review.status),
        .reviewed_by = review.reviewed_by,
        .date = review.date,
        .categories = review.categories,
        .not_applicable = review.not_applicable,
    };
}

fn inventoryStatus(rows: []const review_datasheet_inventory.Row, ref: []const u8) []const u8 {
    for (rows) |row| {
        for (row.refs) |candidate| {
            if (std.mem.eql(u8, candidate, ref)) return @tagName(row.status);
        }
    }
    return "";
}

fn profileRows(
    evidence: Evidence,
    block: *const env.DesignBlock,
    inst: env.Instance,
) std.mem.Allocator.Error![]const ProfileRow {
    const arena = evidence.arena;
    const items = try review_profiles.evaluate(arena, arena, inst, .{
        .block = block,
        .project_dir = evidence.project_dir,
        .forms = evidence.forms,
        .require_requirements = true,
    });
    var out: std.ArrayList(ProfileRow) = .empty;
    for (items) |item| try out.append(arena, .{ .code = item.code, .message = item.message });
    return try out.toOwnedSlice(arena);
}

/// Count every row of the part in the shared vocabulary. Supply windows are
/// deliberately NOT counted: each one is a requirement already counted above,
/// and double-counting it would inflate the chip.
fn tally(part: PartReview) Counts {
    var counts: Counts = .{};
    for (part.requirements) |row| counts.add(row.verdict);
    for (part.ratings) |row| counts.add(row.verdict);
    for (part.profile_items) |_| counts.add(.not_declared);
    if (part.active) counts.add(part.datasheet.verdict);
    if (part.ratings.len == 0) counts.add(.pass);
    if (part.thermal) |row| counts.add(if (row.has_power) Verdict.pass else Verdict.not_declared);
    return counts;
}

// ── Serialization ─────────────────────────────────────────────────────────

fn writeFloatOrNull(w: anytype, value: ?f64) json_writer.WriteError!void {
    if (value) |v| try w.print("{d}", .{v}) else try w.writeAll("null");
}

fn writeStrings(w: anytype, values: []const []const u8) json_writer.WriteError!void {
    try w.writeAll("[");
    for (values, 0..) |value, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, value);
    }
    try w.writeAll("]");
}

fn writeCounts(w: anytype, counts: Counts) json_writer.WriteError!void {
    try w.print(
        "{{\"pass\":{d},\"fail\":{d},\"unproven\":{d},\"waived\":{d}," ++
            "\"not_applicable\":{d},\"not_declared\":{d},\"manual\":{d}}}",
        .{
            counts.pass,           counts.fail,         counts.unproven, counts.waived,
            counts.not_applicable, counts.not_declared, counts.manual,
        },
    );
}

fn writeIdentity(w: anytype, identity: Identity) json_writer.WriteError!void {
    try w.writeAll("{\"value\":");
    try json_writer.writeString(w, identity.value);
    try w.writeAll(",\"footprint\":");
    try json_writer.writeString(w, identity.footprint);
    try w.writeAll(",\"mpn\":");
    try json_writer.writeString(w, identity.mpn);
    try w.writeAll(",\"manufacturer\":");
    try json_writer.writeString(w, identity.manufacturer);
    try w.writeAll(",\"datasheet\":");
    try json_writer.writeString(w, identity.datasheet);
    try w.print(",\"dnp\":{s},\"attrs\":", .{if (identity.dnp) "true" else "false"});
    try writeStrings(w, identity.attrs);
    try w.writeAll(",\"properties\":[");
    for (identity.properties, 0..) |property, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"key\":");
        try json_writer.writeString(w, property.key);
        try w.writeAll(",\"value\":");
        try json_writer.writeString(w, property.value);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn writeCitation(w: anytype, citation: ?Citation) json_writer.WriteError!void {
    const value = citation orelse return w.writeAll("null");
    try w.writeAll("{\"pdf\":");
    try json_writer.writeString(w, value.pdf);
    try w.print(",\"page\":{d},\"quote\":", .{value.page});
    try json_writer.writeString(w, value.quote);
    try w.writeAll("}");
}

fn writeRequirement(w: anytype, row: RequirementRow) json_writer.WriteError!void {
    try w.writeAll("{\"id\":");
    try json_writer.writeString(w, row.id);
    try w.writeAll(",\"text\":");
    try json_writer.writeString(w, row.text);
    try w.writeAll(",\"citation\":");
    try writeCitation(w, row.citation);
    try w.print(",\"source\":\"{s}\",\"check\":", .{row.source});
    try json_writer.writeString(w, row.check);
    try w.print(",\"status\":\"{s}\",\"verdict\":\"{s}\",\"message\":", .{ row.status, row.verdict.key() });
    try json_writer.writeString(w, row.message);
    try w.writeAll(",\"signed_off_by\":");
    try json_writer.writeString(w, row.signed_off_by);
    try w.writeAll(",\"rationale\":");
    try json_writer.writeString(w, row.rationale);
    try w.writeAll("}");
}

fn writeSupplyWindow(w: anytype, row: SupplyWindow) json_writer.WriteError!void {
    try w.writeAll("{\"pin\":");
    try json_writer.writeString(w, row.pin);
    try w.print(",\"min_v\":{d},\"max_v\":{d},\"status\":\"{s}\",\"verdict\":\"{s}\",\"message\":", .{
        row.min_v, row.max_v, row.status, row.verdict.key(),
    });
    try json_writer.writeString(w, row.message);
    try w.writeAll("}");
}

fn writeRating(w: anytype, row: RatingRow) json_writer.WriteError!void {
    try w.writeAll("{\"id\":");
    try json_writer.writeString(w, row.id);
    try w.print(",\"severity\":\"{s}\",\"verdict\":\"{s}\",\"message\":", .{ row.severity, row.verdict.key() });
    try json_writer.writeString(w, row.message);
    try w.writeAll("}");
}

fn writePower(w: anytype, row: PowerRow) json_writer.WriteError!void {
    try w.writeAll("{\"rail\":");
    try json_writer.writeString(w, row.rail);
    try w.writeAll(",\"net\":");
    try json_writer.writeString(w, row.net);
    try w.writeAll(",\"pins\":");
    try writeStrings(w, row.pins);
    try w.writeAll(",\"i_typ\":");
    try writeFloatOrNull(w, row.i_typ);
    try w.writeAll(",\"i_max\":");
    try writeFloatOrNull(w, row.i_max);
    try w.writeAll(",\"share_pct\":");
    try writeFloatOrNull(w, row.share_pct);
    try w.writeAll("}");
}

fn writeThermal(w: anytype, row: ?ThermalRow) json_writer.WriteError!void {
    const value = row orelse return w.writeAll("null");
    try w.print("{{\"ambient_c\":{d},\"power\":", .{value.ambient_c});
    try json_writer.writeString(w, value.power);
    try w.writeAll(",\"theta_ja\":");
    try json_writer.writeString(w, value.theta);
    try w.writeAll(",\"tj\":");
    try json_writer.writeString(w, value.tj);
    try w.writeAll(",\"margin\":");
    try json_writer.writeString(w, value.margin);
    try w.writeAll(",\"max_ambient\":");
    try json_writer.writeString(w, value.max_ambient);
    try w.print(",\"has_power\":{s}}}", .{if (value.has_power) "true" else "false"});
}

fn writeRecord(w: anytype, record: ReviewRecord) json_writer.WriteError!void {
    try w.print("{{\"present\":{s},\"datasheet\":", .{if (record.present) "true" else "false"});
    try json_writer.writeString(w, record.datasheet);
    try w.writeAll(",\"sha256\":");
    try json_writer.writeString(w, record.sha256);
    try w.print(",\"digest_bound\":{s},\"status\":", .{if (record.digest_bound) "true" else "false"});
    try json_writer.writeString(w, record.status);
    try w.writeAll(",\"reviewed_by\":");
    try json_writer.writeString(w, record.reviewed_by);
    try w.writeAll(",\"date\":");
    try json_writer.writeString(w, record.date);
    try w.writeAll(",\"categories\":");
    try writeStrings(w, record.categories);
    try w.writeAll(",\"not_applicable\":[");
    for (record.not_applicable, 0..) |entry, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"category\":");
        try json_writer.writeString(w, entry.category);
        try w.writeAll(",\"rationale\":");
        try json_writer.writeString(w, entry.rationale);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn writeDatasheet(w: anytype, block: DatasheetBlock) json_writer.WriteError!void {
    try w.print("{{\"status\":\"{s}\",\"verdict\":\"{s}\",\"message\":", .{ block.status, block.verdict.key() });
    try json_writer.writeString(w, block.message);
    try w.writeAll(",\"inventory\":");
    try json_writer.writeString(w, block.inventory);
    try w.writeAll(",\"record\":");
    try writeRecord(w, block.record);
    try w.writeAll("}");
}

fn writeElectrical(w: anytype, decl: env.ElectricalDecl) json_writer.WriteError!void {
    try w.writeAll("{\"pin\":");
    try json_writer.writeString(w, decl.pin);
    try w.writeAll(",\"type\":");
    if (decl.electrical_type) |t| try json_writer.writeString(w, @tagName(t)) else try w.writeAll("null");
    try w.writeAll(",\"drive\":");
    if (decl.drive) |d| try json_writer.writeString(w, @tagName(d)) else try w.writeAll("null");
    try w.writeAll(",\"v_ih_min\":");
    try writeFloatOrNull(w, decl.v_ih_min);
    try w.writeAll(",\"v_il_max\":");
    try writeFloatOrNull(w, decl.v_il_max);
    try w.writeAll(",\"v_oh_typ\":");
    try writeFloatOrNull(w, decl.v_oh_typ);
    try w.writeAll(",\"v_ol_typ\":");
    try writeFloatOrNull(w, decl.v_ol_typ);
    try w.writeAll(",\"max_voltage\":");
    try writeFloatOrNull(w, decl.max_voltage);
    try w.writeAll(",\"domain\":");
    try json_writer.writeString(w, decl.domain);
    try w.writeAll("}");
}

/// Serialize the sections of `part` that carry rows. Split out of `writeJson`
/// so neither half runs past the complexity budget.
fn writeSections(w: anytype, part: PartReview) json_writer.WriteError!void {
    try w.writeAll(",\"profile_items\":[");
    for (part.profile_items, 0..) |row, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"code\":");
        try json_writer.writeString(w, row.code);
        try w.writeAll(",\"message\":");
        try json_writer.writeString(w, row.message);
        try w.writeAll("}");
    }
    try w.writeAll("],\"requirements\":[");
    for (part.requirements, 0..) |row, i| {
        if (i > 0) try w.writeAll(",");
        try writeRequirement(w, row);
    }
    try w.writeAll("],\"supply_windows\":[");
    for (part.supply_windows, 0..) |row, i| {
        if (i > 0) try w.writeAll(",");
        try writeSupplyWindow(w, row);
    }
    try w.writeAll("],\"ratings\":[");
    for (part.ratings, 0..) |row, i| {
        if (i > 0) try w.writeAll(",");
        try writeRating(w, row);
    }
    try w.writeAll("],\"power\":[");
    for (part.power, 0..) |row, i| {
        if (i > 0) try w.writeAll(",");
        try writePower(w, row);
    }
    try w.writeAll("],\"electrical\":[");
    for (part.electrical, 0..) |row, i| {
        if (i > 0) try w.writeAll(",");
        try writeElectrical(w, row);
    }
    try w.writeAll("]");
}

/// Serialize one `PartReview` as the whole body `GET /api/part-review/:name/:ref`
/// and the `part_review` CLI tool return. Strings go through `json_writer`, so
/// this is not a private escaper: it only composes the shared one.
pub fn writePartJson(w: anytype, design: []const u8, part: PartReview) json_writer.WriteError!void {
    try w.writeAll("{\"design\":");
    try json_writer.writeString(w, design);
    try w.writeAll(",\"ref\":");
    try json_writer.writeString(w, part.ref);
    try w.writeAll(",\"ref_leaf\":");
    try json_writer.writeString(w, part.ref_leaf);
    try w.writeAll(",\"block_path\":");
    try json_writer.writeString(w, part.block_path);
    try w.writeAll(",\"component\":");
    try json_writer.writeString(w, part.component);
    try w.print(",\"active\":{s},\"class\":", .{if (part.active) "true" else "false"});
    try json_writer.writeString(w, part.class);
    try w.print(",\"class_declared\":{s},\"identity\":", .{if (part.class_declared) "true" else "false"});
    try writeIdentity(w, part.identity);
    try w.writeAll(",\"counts\":");
    try writeCounts(w, part.counts);
    try w.writeAll(",\"datasheet_review\":");
    try writeDatasheet(w, part.datasheet);
    try w.writeAll(",\"thermal\":");
    try writeThermal(w, part.thermal);
    try writeSections(w, part);
    try w.writeAll("}");
}

/// Serialize the whole board's chips — the body `GET /api/part-review/:name`
/// returns, and what the BOM tab's Review column is filled from.
pub fn writeChipsJson(w: anytype, board: Board) json_writer.WriteError!void {
    try w.writeAll("{\"design\":");
    try json_writer.writeString(w, board.design);
    try w.print(",\"ambient_c\":{d},\"parts\":[", .{board.ambient_c});
    for (board.parts, 0..) |part, i| {
        if (i > 0) try w.writeAll(",");
        const chip = part.chip();
        try w.writeAll("{\"ref\":");
        try json_writer.writeString(w, chip.ref);
        try w.writeAll(",\"class\":");
        try json_writer.writeString(w, chip.class);
        try w.print(",\"pass\":{d},\"unproven\":{d},\"fail\":{d},\"not_declared\":{d},\"verdict\":\"{s}\"}}", .{
            chip.pass,
            chip.unproven,
            chip.fail,
            chip.not_declared,
            part.counts.worst().key(),
        });
    }
    try w.writeAll("]}");
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: part-review - a requirement status maps onto exactly one word of the shared verdict vocabulary
test "requirement and rating statuses map onto the shared verdict vocabulary" {
    try testing.expectEqual(Verdict.pass, requirementVerdict(.pass));
    try testing.expectEqual(Verdict.fail, requirementVerdict(.fail));
    try testing.expectEqual(Verdict.waived, requirementVerdict(.verified));
    try testing.expectEqual(Verdict.manual, requirementVerdict(.pending));
    try testing.expectEqual(Verdict.unproven, requirementVerdict(.unproven));
    try testing.expectEqual(Verdict.unproven, requirementVerdict(.deferred));
    try testing.expectEqual(Verdict.not_declared, requirementVerdict(.missing));
    try testing.expectEqual(Verdict.not_declared, reviewVerdict(.missing));
    try testing.expectEqual(Verdict.fail, reviewVerdict(.stale));
    try testing.expectEqual(Verdict.not_declared, ratingVerdict("component-rating-missing"));
    try testing.expectEqual(Verdict.unproven, ratingVerdict("component-rating-unproven"));
    try testing.expectEqual(Verdict.fail, ratingVerdict("component-underrated"));
    try testing.expectEqual(Verdict.not_declared, ratingVerdict("bom-spec-missing"));
}

// spec: part-review - a part's chip counts every row it carries and the group chip shows the worst verdict
test "the chip counts rows and the group verdict is the worst one" {
    var counts: Counts = .{};
    counts.add(.pass);
    counts.add(.pass);
    counts.add(.waived);
    counts.add(.unproven);
    try testing.expectEqual(Verdict.unproven, counts.worst());
    const part = PartReview{
        .ref = "ldo/U21",
        .ref_leaf = "U21",
        .component = "lt3045",
        .counts = counts,
    };
    const chip = part.chip();
    try testing.expectEqual(@as(usize, 3), chip.pass);
    try testing.expectEqual(@as(usize, 1), chip.unproven);
    try testing.expectEqual(@as(usize, 0), chip.fail);
    counts.add(.fail);
    try testing.expectEqual(Verdict.fail, counts.worst());
}

// spec: part-review - the board resolves a sub-block-qualified ref and its bare leaf, and answers nothing for an unknown one
test "board lookup resolves the qualified ref and its leaf" {
    const parts = [_]PartReview{
        .{ .ref = "ldo_3v3/U21", .ref_leaf = "U21", .component = "lt3045" },
        .{ .ref = "C7", .ref_leaf = "C7", .component = "cap-0402" },
    };
    const board = Board{ .design = "demo", .parts = &parts };
    try testing.expectEqualStrings("lt3045", (board.find("ldo_3v3/U21").?).component);
    try testing.expectEqualStrings("lt3045", (board.find("U21").?).component);
    try testing.expectEqualStrings("cap-0402", (board.find("C7").?).component);
    try testing.expect(board.find("U99") == null);
}

// spec: part-review - the per-part JSON carries every section a reviewer needs and escapes hostile text
test "part JSON carries every section and escapes hostile strings" {
    const requirements = [_]RequirementRow{.{
        .id = "6c41e000",
        .text = "IN needs 4.7 uF",
        .citation = .{ .pdf = "lt3045.pdf", .page = 12, .quote = "C_IN >= 4.7uF" },
        .check = "decoupling",
        .status = "pass",
        .verdict = .pass,
        .message = "found 10 uF on V_3V3 \"quoted\"",
    }};
    const part = PartReview{
        .ref = "ldo_3v3/U21",
        .ref_leaf = "U21",
        .block_path = "ldo_3v3",
        .component = "lt3045edd#pbf",
        .active = true,
        .class = "ldo",
        .class_declared = true,
        .identity = .{ .mpn = "LT3045EDD#PBF", .manufacturer = "Analog Devices" },
        .counts = .{ .pass = 1 },
        .datasheet = .{ .status = "pass", .verdict = .pass, .record = .{ .present = true, .digest_bound = true } },
        .requirements = &requirements,
        .thermal = .{
            .ambient_c = 25,
            .power = "0.149 (declared)",
            .theta = "34.0",
            .tj = "30.1",
            .margin = "94.9",
            .max_ambient = "119.9",
            .has_power = true,
        },
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writePartJson(&out.writer, "barracuda", part);
    const body = out.written();
    try testing.expect(std.mem.indexOf(u8, body, "\"ref\":\"ldo_3v3/U21\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"class\":\"ldo\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"digest_bound\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"supply_windows\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"theta_ja\":\"34.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\\\"quoted\\\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("requirements").?.array.items.len == 1);
}

// spec: part-review - the chips body names every placed part with its four counts and its worst verdict
test "chips JSON names every part with its counts" {
    const parts = [_]PartReview{
        .{ .ref = "ldo/U21", .ref_leaf = "U21", .component = "lt3045", .class = "ldo", .counts = .{ .pass = 12, .unproven = 1 } },
        .{ .ref = "C7", .ref_leaf = "C7", .component = "cap-0402", .class = "passive", .counts = .{ .fail = 1 } },
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeChipsJson(&out.writer, .{ .design = "barracuda", .parts = &parts });
    const body = out.written();
    try testing.expect(std.mem.indexOf(u8, body, "\"ref\":\"ldo/U21\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"pass\":12") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"verdict\":\"unproven\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"verdict\":\"fail\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.object.get("parts").?.array.items.len);
}
