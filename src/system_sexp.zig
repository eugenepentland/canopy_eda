//! `(system …)` — the system contract as a DSL form, and its discovery.
//!
//! A system review manifest has always been hand-maintained JSON
//! (`src/systems/<name>/system.json`, schema `netlisp-system-review-v1`).
//! This module adds the same contract as an S-expression source file
//! (`src/systems/<name>/system.sexp`) written in the project's own language,
//! and parses it into the very `system_review.SystemSpec` the JSON loader
//! produces — one in-memory spec, one validator, one set of gates.
//!
//! Two things the JSON cannot express are added here:
//!
//!   * `(auto)` on an interface derives the whole contact table from the two
//!     boards' evaluated netlists by contact number, so a bring-up contract
//!     does not have to be transcribed by hand;
//!   * an explicit `(signal …)` overrides or annotates one derived contact.
//!
//! Board-local to system-canonical aliases are DERIVED rather than authored:
//! the JSON schema already requires exactly one alias per endpoint-local net
//! that differs from the canonical name, and requires every authored alias to
//! describe a signal record, so the derived set is the only valid set. That
//! makes `JSON -> spec` and `JSON -> sexp -> spec` the same spec, which
//! `convert-system-manifest` and its round-trip test rely on.
//!
//! The module never writes into a project. It reads through the contained-path
//! reader only — `locate`, which decides which of the two files is a
//! workspace's contract and is the single discovery every reader shares, and
//! `convertTool`, which prints the equivalent source for one JSON manifest.
//! Where any result is stored stays the caller's decision, which is why the
//! attestation editors here (`withAttestation`, `withoutAttestation`) return
//! new bytes rather than touching the file: persistence belongs at the
//! authenticated VFS boundary, and the bytes they return differ from the ones
//! they were given only inside the `(attestation …)` form.

const std = @import("std");

const ast = @import("sexpr/ast.zig");
const paren_span = @import("sexpr/paren_span.zig");
const parser = @import("sexpr/parser.zig");
const system_review = @import("system_review.zig");

const Node = ast.Node;
const Diagnostic = system_review.Diagnostic;
const SystemSpec = system_review.SystemSpec;

/// Manifest file names inside `src/systems/<name>/`, in precedence order.
pub const sexp_manifest_name = "system.sexp";
/// The long-standing JSON manifest, still loaded unchanged.
pub const json_manifest_name = "system.json";

/// Prefix of the synthetic net name `(auto)` gives a contact the netlist
/// leaves unconnected on one side. It is deliberately not a legal design net
/// name shape, so a derived contract cannot be confused for a wired one.
pub const unconnected_net_prefix = "(nc ";

/// Every head atom a `(system …)` source accepts, anywhere in the grammar.
/// The parser's per-scope ladders decide WHERE each one is legal; this is the
/// flat set the generated reference must document, and a test proves the two
/// agree in both directions so a new form cannot ship undocumented.
pub const accepted_forms = [_][]const u8{
    "system",         "title",          "part-number", "revision",
    "board",          "role",           "source",      "layout",
    "dnp",            "interface",      "mates",       "contact-count",
    "auto",           "signal",         "left",        "right",
    "document",       "classification", "status",      "required",
    "include-in-fab", "generated",      "attestation", "system-lock",
    "attested-by",    "attested-at",    "input",       "checklist",
    "brief",          "purpose",        "environment", "ambient",
    "cooling",        "altitude",       "ingress",     "input-power",
    "voltage",        "transient",      "current-max", "temperature-grade",
    "derating",       "ipc-class",      "compliance",  "esd",
    "emc",            "safety",         "connector",   "impedance",
    "power-max",      "protocol",       "goal",        "unit",
    "min",            "max",            "verify-by",   "measured",
    "feeds",
};

/// One connector contact as the evaluated board reports it. `net` is empty
/// for a pad the netlist leaves unconnected.
pub const Contact = struct {
    pin: []const u8,
    net: []const u8 = "",
};

/// Supplies the connector pad tables `(auto)` derives a contact map from.
/// `lookupFn` returns the connector's complete ordered pad table, or null when
/// the board or the connector cannot be resolved at all.
pub const Resolver = struct {
    /// Everything a pad-table lookup may report. Implementations collapse
    /// their own failures (a design that will not evaluate, an unreadable
    /// library) into `ResolveFailed` so this contract stays narrow.
    pub const Error = std.mem.Allocator.Error || error{ResolveFailed};

    ctx: *anyopaque,
    lookupFn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        board: []const u8,
        connector: []const u8,
    ) Error!?[]const Contact,

    /// Resolve one endpoint's pad table.
    pub fn lookup(
        self: Resolver,
        allocator: std.mem.Allocator,
        board: []const u8,
        connector: []const u8,
    ) Error!?[]const Contact {
        return self.lookupFn(self.ctx, allocator, board, connector);
    }
};

/// Errors returned while parsing a `(system …)` source.
pub const ParseError = std.mem.Allocator.Error || error{
    SourceTooLarge,
    InvalidSystemSexp,
};

/// Errors returned while serializing a spec back to `(system …)`.
pub const WriteError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Compare two contact identifiers. Pad ids reach this module from two
/// unrelated spellings of the same physical contact — a pinout file's
/// zero-padded `01` and a design source's `1` — so equality is numeric
/// whenever both sides are plain decimal, and byte-exact otherwise.
pub fn sameContact(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const left = decimalValue(a) orelse return false;
    const right = decimalValue(b) orelse return false;
    return left == right;
}

fn decimalValue(text: []const u8) ?u64 {
    if (text.len == 0 or text.len > 19) return null;
    var value: u64 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        value = value * 10 + (byte - '0');
    }
    return value;
}

/// True when `net` is the synthetic name `(auto)` gives an unconnected pad.
pub fn isUnconnectedNet(net: []const u8) bool {
    return std.mem.startsWith(u8, net, unconnected_net_prefix);
}

// ── Parsing ──────────────────────────────────────────────────────────

/// How much of a contract one parse needs.
pub const Options = struct {
    /// Supplies the pad tables an `(auto)` interface derives its contact table
    /// from. Absent when the caller has no evaluator to spend.
    resolver: ?Resolver = null,
    /// Drop an `(auto)` interface that no resolver can derive instead of
    /// refusing the whole contract. Only for callers that read identity and
    /// counts — the home page's cards — where a derived contact table costs a
    /// full evaluation of both boards and appears in nothing they render.
    omit_underivable_interfaces: bool = false,
};

/// Parse one `(system …)` source into the same strict v1 spec the JSON loader
/// produces. Everything returned is allocated from `allocator`; callers use an
/// arena and free it whole. The result is NOT yet semantically validated —
/// run `system_review.validateSystemSpec` on it, exactly as the JSON path does.
pub fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
    resolver: ?Resolver,
    diagnostic: *Diagnostic,
) ParseError!SystemSpec {
    return parseWith(allocator, source, .{ .resolver = resolver }, diagnostic);
}

/// `parse` with the derivation policy spelled out. See `Options`.
pub fn parseWith(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
    diagnostic: *Diagnostic,
) ParseError!SystemSpec {
    diagnostic.clear();
    if (source.len > system_review.max_manifest_bytes) {
        diagnostic.* = .{
            .code = .manifest_too_large,
            .field = "manifest",
            .message = "system manifest exceeds the 1 MiB input limit",
        };
        return error.SourceTooLarge;
    }
    var syntax: parser.ParseDiagnostic = .{};
    const nodes = parser.parseDiag(allocator, source, &syntax) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(diagnostic, .invalid_sexp, "manifest", syntax.message, ""),
    };
    var root: ?Node = null;
    for (nodes) |node| {
        if (!node.isForm("system"))
            return fail(diagnostic, .unknown_sexp_form, "manifest", "a system contract source contains one (system …) form and nothing else", "");
        if (root != null)
            return fail(diagnostic, .duplicate_sexp_field, "manifest", "a system contract source declares exactly one (system …) form", "");
        root = node;
    }
    const system = root orelse
        return fail(diagnostic, .missing_sexp_field, "manifest", "no (system …) form in this source", "");
    return parseSystem(allocator, system, options, diagnostic);
}

fn parseSystem(
    allocator: std.mem.Allocator,
    node: Node,
    options: Options,
    diagnostic: *Diagnostic,
) ParseError!SystemSpec {
    const children = node.asList().?;
    const name = try requiredHeadString(allocator, children, "system", diagnostic);

    var spec: SystemSpec = .{
        .schema = system_review.schema_v1,
        .name = name,
        .title = "",
        .part_number = "",
        .revision = "",
        .boards = &.{},
    };
    var boards: std.ArrayList(system_review.BoardMember) = .empty;
    var interfaces: std.ArrayList(InterfaceDraft) = .empty;
    var documents: std.ArrayList(system_review.DocumentSpec) = .empty;
    var goals: std.ArrayList(system_review.GoalSpec) = .empty;
    var seen_attestation = false;
    var seen_status = false;

    for (children[2..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "system", "every (system …) child is a parenthesised form", "");
        if (std.mem.eql(u8, head, "title")) {
            try setOnce(&spec.title, try requiredArgString(allocator, child, "title", diagnostic), "title", diagnostic);
        } else if (std.mem.eql(u8, head, "part-number")) {
            try setOnce(&spec.part_number, try requiredArgString(allocator, child, "part-number", diagnostic), "part-number", diagnostic);
        } else if (std.mem.eql(u8, head, "revision")) {
            try setOnce(&spec.revision, try requiredArgString(allocator, child, "revision", diagnostic), "revision", diagnostic);
        } else if (std.mem.eql(u8, head, "board")) {
            try boards.append(allocator, try parseBoard(allocator, child, diagnostic));
        } else if (std.mem.eql(u8, head, "interface")) {
            try interfaces.append(allocator, try parseInterface(allocator, child, diagnostic));
        } else if (std.mem.eql(u8, head, "document")) {
            try documents.append(allocator, try parseDocument(allocator, child, diagnostic));
        } else if (std.mem.eql(u8, head, "status")) {
            if (seen_status)
                return fail(diagnostic, .duplicate_sexp_field, "system", "a system declares (status …) once", spec.name);
            seen_status = true;
            const token = try requiredArgToken(allocator, child, "status", diagnostic);
            spec.status = std.meta.stringToEnum(system_review.SystemStatus, token) orelse
                return fail(diagnostic, .invalid_sexp_value, "system.status", "status is concept, design, review or released", token);
        } else if (std.mem.eql(u8, head, "brief")) {
            if (spec.brief != null)
                return fail(diagnostic, .duplicate_sexp_field, "system", "a system declares at most one (brief …)", spec.name);
            spec.brief = try parseBrief(allocator, child, diagnostic);
        } else if (std.mem.eql(u8, head, "goal")) {
            try goals.append(allocator, try parseGoal(allocator, child, diagnostic));
        } else if (std.mem.eql(u8, head, "attestation")) {
            if (seen_attestation)
                return fail(diagnostic, .duplicate_sexp_field, "system", "a system declares at most one (attestation …)", "");
            seen_attestation = true;
            spec.attestation = try parseAttestation(allocator, child, diagnostic);
        } else {
            return fail(diagnostic, .unknown_sexp_form, "system", "unknown (system …) child form", head);
        }
    }

    if (spec.title.len == 0) return fail(diagnostic, .missing_sexp_field, "system", "a system declares (title \"…\")", spec.name);
    if (spec.part_number.len == 0) return fail(diagnostic, .missing_sexp_field, "system", "a system declares (part-number \"…\")", spec.name);
    if (spec.revision.len == 0) return fail(diagnostic, .missing_sexp_field, "system", "a system declares (revision \"…\")", spec.name);

    spec.boards = boards.items;
    spec.documents = documents.items;
    spec.goals = goals.items;
    spec.interfaces = try resolveInterfaces(allocator, interfaces.items, options, diagnostic);
    return spec;
}

fn parseBoard(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!system_review.BoardMember {
    const children = node.asList().?;
    var board: system_review.BoardMember = .{
        .name = try requiredHeadString(allocator, children, "board", diagnostic),
        .role = "",
        .source = "",
        .part_number = "",
        .revision = "",
    };
    var layout: []const u8 = "";
    var seen_dnp = false;
    for (children[2..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "board", "every (board …) child is a parenthesised form", board.name);
        if (std.mem.eql(u8, head, "role")) {
            try setOnce(&board.role, try requiredArgToken(allocator, child, "board role", diagnostic), "role", diagnostic);
        } else if (std.mem.eql(u8, head, "source")) {
            try setOnce(&board.source, try requiredArgString(allocator, child, "source", diagnostic), "source", diagnostic);
        } else if (std.mem.eql(u8, head, "part-number")) {
            try setOnce(&board.part_number, try requiredArgString(allocator, child, "part-number", diagnostic), "part-number", diagnostic);
        } else if (std.mem.eql(u8, head, "revision")) {
            try setOnce(&board.revision, try requiredArgString(allocator, child, "revision", diagnostic), "revision", diagnostic);
        } else if (std.mem.eql(u8, head, "layout")) {
            try setOnce(&layout, try requiredArgString(allocator, child, "layout", diagnostic), "layout", diagnostic);
        } else if (std.mem.eql(u8, head, "dnp")) {
            if (seen_dnp) return fail(diagnostic, .duplicate_sexp_field, "board", "a board declares (dnp …) once", board.name);
            seen_dnp = true;
            const token = try requiredArgToken(allocator, child, "dnp policy", diagnostic);
            board.dnp = std.meta.stringToEnum(system_review.DnpPolicy, token) orelse
                return fail(diagnostic, .invalid_sexp_value, "board.dnp", "dnp is drop or keep", token);
        } else {
            return fail(diagnostic, .unknown_sexp_form, "board", "unknown (board …) child form", head);
        }
    }
    if (board.role.len == 0) return fail(diagnostic, .missing_sexp_field, "board", "a board declares (role …)", board.name);
    if (board.source.len == 0) return fail(diagnostic, .missing_sexp_field, "board", "a board declares (source \"…\")", board.name);
    if (board.part_number.len == 0) return fail(diagnostic, .missing_sexp_field, "board", "a board declares (part-number \"…\")", board.name);
    if (board.revision.len == 0) return fail(diagnostic, .missing_sexp_field, "board", "a board declares (revision \"…\")", board.name);
    if (layout.len > 0) board.layout = layout;
    return board;
}

// ── `(brief …)` and `(goal …)` ───────────────────────────────────────

fn parseBrief(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!system_review.Brief {
    var brief: system_review.Brief = .{};
    var interfaces: std.ArrayList(system_review.BriefInterface) = .empty;
    for (node.asList().?[1..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "brief", "every (brief …) child is a parenthesised form", "");
        if (std.mem.eql(u8, head, "purpose")) {
            try setOnce(&brief.purpose, try requiredArgString(allocator, child, "purpose", diagnostic), "purpose", diagnostic);
        } else if (std.mem.eql(u8, head, "environment")) {
            if (brief.environment != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief", "a brief declares (environment …) once", "");
            brief.environment = try parseEnvironment(allocator, child, diagnostic);
        } else if (std.mem.eql(u8, head, "input-power")) {
            if (brief.input_power != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief", "a brief declares (input-power …) once", "");
            brief.input_power = try parseInputPower(allocator, child, diagnostic);
        } else if (std.mem.eql(u8, head, "temperature-grade")) {
            if (brief.temperature_grade != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief", "a brief declares (temperature-grade …) once", "");
            const token = try requiredArgToken(allocator, child, "temperature-grade", diagnostic);
            brief.temperature_grade = std.meta.stringToEnum(system_review.TemperatureGrade, token) orelse
                return fail(diagnostic, .invalid_sexp_value, "brief.temperature-grade", "grade is commercial, industrial, extended or automotive", token);
        } else if (std.mem.eql(u8, head, "derating")) {
            if (brief.derating != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief", "a brief declares (derating …) once", "");
            brief.derating = try requiredArgString(allocator, child, "derating", diagnostic);
        } else if (std.mem.eql(u8, head, "ipc-class")) {
            if (brief.ipc_class != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief", "a brief declares (ipc-class …) once", "");
            const class = try requiredArgCountNamed(child, "ipc-class", diagnostic);
            if (class < 1 or class > 3)
                return fail(diagnostic, .invalid_sexp_value, "brief.ipc-class", "IPC class is 1, 2 or 3", "");
            brief.ipc_class = std.math.cast(u8, class) orelse
                return fail(diagnostic, .invalid_sexp_value, "brief.ipc-class", "IPC class is 1, 2 or 3", "");
        } else if (std.mem.eql(u8, head, "compliance")) {
            try parseCompliance(allocator, child, &brief.compliance, diagnostic);
        } else if (std.mem.eql(u8, head, "interface")) {
            try interfaces.append(allocator, try parseBriefInterface(allocator, child, diagnostic));
        } else {
            return fail(diagnostic, .unknown_sexp_form, "brief", "unknown (brief …) child form", head);
        }
    }
    brief.interfaces = interfaces.items;
    return brief;
}

fn parseEnvironment(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!system_review.Environment {
    var environment: system_review.Environment = .{ .ambient_min_c = 0, .ambient_max_c = 0 };
    var seen_ambient = false;
    for (node.asList().?[1..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "brief.environment", "every (environment …) child is a parenthesised form", "");
        const args = child.asList().?;
        if (std.mem.eql(u8, head, "ambient")) {
            if (seen_ambient)
                return fail(diagnostic, .duplicate_sexp_field, "brief.environment", "an environment declares (ambient …) once", "");
            seen_ambient = true;
            if (args.len != 3)
                return fail(diagnostic, .invalid_sexp_value, "brief.environment.ambient", "(ambient MIN MAX) names both edges in degrees C", "");
            environment.ambient_min_c = try numberValue(args[1], "brief.environment.ambient", diagnostic);
            environment.ambient_max_c = try numberValue(args[2], "brief.environment.ambient", diagnostic);
        } else if (std.mem.eql(u8, head, "cooling")) {
            if (environment.cooling != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief.environment", "an environment declares (cooling …) once", "");
            const token = try requiredArgToken(allocator, child, "cooling", diagnostic);
            environment.cooling = std.meta.stringToEnum(system_review.Cooling, token) orelse
                return fail(diagnostic, .invalid_sexp_value, "brief.environment.cooling", "unsupported cooling case", token);
        } else if (std.mem.eql(u8, head, "altitude")) {
            if (environment.altitude_m != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief.environment", "an environment declares (altitude …) once", "");
            environment.altitude_m = try requiredArgNumber(child, "brief.environment.altitude", diagnostic);
        } else if (std.mem.eql(u8, head, "ingress")) {
            if (environment.ingress != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief.environment", "an environment declares (ingress …) once", "");
            const rating = try requiredArgCountNamed(child, "ingress", diagnostic);
            if (rating > 99)
                return fail(diagnostic, .invalid_sexp_value, "brief.environment.ingress", "an IP rating is its two digits, for example 65", "");
            environment.ingress = std.math.cast(u16, rating) orelse
                return fail(diagnostic, .invalid_sexp_value, "brief.environment.ingress", "an IP rating is its two digits, for example 65", "");
        } else {
            return fail(diagnostic, .unknown_sexp_form, "brief.environment", "unknown (environment …) child form", head);
        }
    }
    if (!seen_ambient)
        return fail(diagnostic, .missing_sexp_field, "brief.environment", "an environment declares (ambient MIN MAX)", "");
    return environment;
}

fn parseInputPower(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!system_review.InputPower {
    var power: system_review.InputPower = .{ .source = "", .voltage_min_v = 0, .voltage_max_v = 0 };
    var seen_voltage = false;
    for (node.asList().?[1..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "brief.input-power", "every (input-power …) child is a parenthesised form", "");
        if (std.mem.eql(u8, head, "source")) {
            try setOnce(&power.source, try requiredArgString(allocator, child, "source", diagnostic), "source", diagnostic);
        } else if (std.mem.eql(u8, head, "voltage")) {
            if (seen_voltage)
                return fail(diagnostic, .duplicate_sexp_field, "brief.input-power", "input power declares (voltage …) once", "");
            seen_voltage = true;
            const args = child.asList().?;
            if (args.len != 3)
                return fail(diagnostic, .invalid_sexp_value, "brief.input-power.voltage", "(voltage LO HI) names both edges in volts", "");
            power.voltage_min_v = try numberValue(args[1], "brief.input-power.voltage", diagnostic);
            power.voltage_max_v = try numberValue(args[2], "brief.input-power.voltage", diagnostic);
        } else if (std.mem.eql(u8, head, "transient")) {
            if (power.transient_v != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief.input-power", "input power declares (transient …) once", "");
            power.transient_v = try requiredArgNumber(child, "brief.input-power.transient", diagnostic);
        } else if (std.mem.eql(u8, head, "current-max")) {
            if (power.current_max_a != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief.input-power", "input power declares (current-max …) once", "");
            power.current_max_a = try requiredArgNumber(child, "brief.input-power.current-max", diagnostic);
        } else if (std.mem.eql(u8, head, "feeds")) {
            try setOnce(&power.feeds, try requiredArgString(allocator, child, "feeds", diagnostic), "feeds", diagnostic);
        } else {
            return fail(diagnostic, .unknown_sexp_form, "brief.input-power", "unknown (input-power …) child form", head);
        }
    }
    if (power.source.len == 0)
        return fail(diagnostic, .missing_sexp_field, "brief.input-power", "input power declares (source \"…\")", "");
    if (!seen_voltage)
        return fail(diagnostic, .missing_sexp_field, "brief.input-power", "input power declares (voltage LO HI)", "");
    return power;
}

fn parseCompliance(
    allocator: std.mem.Allocator,
    node: Node,
    compliance: *system_review.Compliance,
    diagnostic: *Diagnostic,
) ParseError!void {
    for (node.asList().?[1..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "brief.compliance", "every (compliance …) child is a parenthesised form", "");
        const slot: *?[]const u8 = if (std.mem.eql(u8, head, "esd"))
            &compliance.esd
        else if (std.mem.eql(u8, head, "emc"))
            &compliance.emc
        else if (std.mem.eql(u8, head, "safety"))
            &compliance.safety
        else
            return fail(diagnostic, .unknown_sexp_form, "brief.compliance", "unknown (compliance …) child form", head);
        if (slot.* != null)
            return fail(diagnostic, .duplicate_sexp_field, "brief.compliance", "each compliance regime is declared once", head);
        slot.* = try requiredArgString(allocator, child, "compliance", diagnostic);
    }
}

fn parseBriefInterface(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!system_review.BriefInterface {
    const children = node.asList().?;
    var entry: system_review.BriefInterface = .{
        .name = try requiredHeadString(allocator, children, "interface", diagnostic),
    };
    for (children[2..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "brief.interface", "every (interface …) child is a parenthesised form", entry.name);
        if (std.mem.eql(u8, head, "connector")) {
            if (entry.connector != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief.interface", "a brief interface declares (connector …) once", entry.name);
            entry.connector = try requiredArgToken(allocator, child, "connector", diagnostic);
        } else if (std.mem.eql(u8, head, "impedance")) {
            if (entry.impedance_ohm != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief.interface", "a brief interface declares (impedance …) once", entry.name);
            entry.impedance_ohm = try requiredArgNumber(child, "brief.interface.impedance", diagnostic);
        } else if (std.mem.eql(u8, head, "power-max")) {
            if (entry.power_max_dbm != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief.interface", "a brief interface declares (power-max …) once", entry.name);
            entry.power_max_dbm = try requiredArgNumber(child, "brief.interface.power-max", diagnostic);
        } else if (std.mem.eql(u8, head, "protocol")) {
            if (entry.protocol != null)
                return fail(diagnostic, .duplicate_sexp_field, "brief.interface", "a brief interface declares (protocol …) once", entry.name);
            entry.protocol = try requiredArgString(allocator, child, "protocol", diagnostic);
        } else {
            return fail(diagnostic, .unknown_sexp_form, "brief.interface", "unknown brief (interface …) child form", head);
        }
    }
    return entry;
}

fn parseGoal(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!system_review.GoalSpec {
    const children = node.asList().?;
    var goal: system_review.GoalSpec = .{
        .id = try requiredHeadString(allocator, children, "goal", diagnostic),
        .unit = "",
        .verify_by = .measurement,
    };
    var seen_verify = false;
    for (children[2..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "goal", "every (goal …) child is a parenthesised form", goal.id);
        if (std.mem.eql(u8, head, "title")) {
            try setOnce(&goal.title, try requiredArgString(allocator, child, "title", diagnostic), "title", diagnostic);
        } else if (std.mem.eql(u8, head, "unit")) {
            try setOnce(&goal.unit, try requiredArgToken(allocator, child, "unit", diagnostic), "unit", diagnostic);
        } else if (std.mem.eql(u8, head, "min")) {
            if (goal.min != null)
                return fail(diagnostic, .duplicate_sexp_field, "goal", "a goal declares (min …) once", goal.id);
            goal.min = try requiredArgNumber(child, "goal.min", diagnostic);
        } else if (std.mem.eql(u8, head, "max")) {
            if (goal.max != null)
                return fail(diagnostic, .duplicate_sexp_field, "goal", "a goal declares (max …) once", goal.id);
            goal.max = try requiredArgNumber(child, "goal.max", diagnostic);
        } else if (std.mem.eql(u8, head, "verify-by")) {
            if (seen_verify)
                return fail(diagnostic, .duplicate_sexp_field, "goal", "a goal declares (verify-by …) once", goal.id);
            seen_verify = true;
            try parseVerifyBy(allocator, child, &goal, diagnostic);
        } else if (std.mem.eql(u8, head, "measured")) {
            if (goal.measured != null)
                return fail(diagnostic, .duplicate_sexp_field, "goal", "a goal declares (measured …) once", goal.id);
            goal.measured = try parseMeasured(allocator, child, goal.id, diagnostic);
        } else {
            return fail(diagnostic, .unknown_sexp_form, "goal", "unknown (goal …) child form", head);
        }
    }
    if (goal.unit.len == 0)
        return fail(diagnostic, .missing_sexp_field, "goal", "a goal declares (unit …)", goal.id);
    if (!seen_verify)
        return fail(diagnostic, .missing_sexp_field, "goal", "a goal declares (verify-by …)", goal.id);
    return goal;
}

/// `(verify-by ENGINE)` names an engine; `(verify-by measurement "ref")` names
/// the bring-up step instead, and only that spelling carries a reference.
fn parseVerifyBy(
    allocator: std.mem.Allocator,
    node: Node,
    goal: *system_review.GoalSpec,
    diagnostic: *Diagnostic,
) ParseError!void {
    const args = node.asList().?;
    if (args.len < 2 or args.len > 3)
        return fail(diagnostic, .invalid_sexp_value, "goal.verify-by", "(verify-by ENGINE) or (verify-by measurement \"reference\")", goal.id);
    const token = try tokenText(allocator, args[1], "verify-by", diagnostic);
    goal.verify_by = std.meta.stringToEnum(system_review.VerifyBy, token) orelse
        return fail(diagnostic, .invalid_sexp_value, "goal.verify-by", "verify-by names frequency-plan, thermal, power-budget, pll-loop, spur-table or measurement", token);
    if (args.len == 2) return;
    if (goal.verify_by != .measurement)
        return fail(diagnostic, .invalid_sexp_value, "goal.verify-by", "only (verify-by measurement \"reference\") carries a reference", token);
    goal.reference = try decodeString(allocator, args[2].asString() orelse
        return fail(diagnostic, .invalid_sexp_value, "goal.verify-by", "a measurement reference is a quoted string", goal.id));
}

fn parseMeasured(
    allocator: std.mem.Allocator,
    node: Node,
    id: []const u8,
    diagnostic: *Diagnostic,
) ParseError!system_review.GoalMeasurement {
    const args = node.asList().?;
    if (args.len != 3)
        return fail(diagnostic, .invalid_sexp_value, "goal.measured", "(measured VALUE \"evidence\")", id);
    return .{
        .value = try numberValue(args[1], "goal.measured", diagnostic),
        .evidence = try decodeString(allocator, args[2].asString() orelse
            return fail(diagnostic, .invalid_sexp_value, "goal.measured", "a measurement's evidence is a quoted string", id)),
    };
}

/// One authored `(signal …)` before `(auto)` derivation fills in whatever it
/// left unsaid. A non-auto interface's drafts are already complete records.
const SignalDraft = struct {
    canonical: []const u8,
    left_pin: []const u8,
    left_net: []const u8,
    right_pin: []const u8,
    right_net: []const u8,
    required: bool = true,
    has_left_net: bool,
    has_right_net: bool,
};

const InterfaceDraft = struct {
    id: []const u8,
    left: system_review.InterfaceEndpoint,
    right: system_review.InterfaceEndpoint,
    contact_count: usize,
    has_contact_count: bool,
    auto: bool,
    signals: []const SignalDraft,
};

fn parseInterface(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!InterfaceDraft {
    const children = node.asList().?;
    const id = try requiredHeadString(allocator, children, "interface", diagnostic);
    var draft: InterfaceDraft = .{
        .id = id,
        .left = .{ .board = "", .connector = "" },
        .right = .{ .board = "", .connector = "" },
        .contact_count = 0,
        .has_contact_count = false,
        .auto = false,
        .signals = &.{},
    };
    var signals: std.ArrayList(SignalDraft) = .empty;
    var seen_mates = false;
    for (children[2..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "interface", "every (interface …) child is a parenthesised form", id);
        if (std.mem.eql(u8, head, "mates")) {
            if (seen_mates) return fail(diagnostic, .duplicate_sexp_field, "interface", "an interface declares (mates …) once", id);
            seen_mates = true;
            const args = child.asList().?;
            if (args.len != 3)
                return fail(diagnostic, .invalid_sexp_value, "interface.mates", "(mates \"board/CONNECTOR\" \"board/CONNECTOR\") names exactly two endpoints", id);
            draft.left = try parseEndpoint(allocator, args[1], diagnostic);
            draft.right = try parseEndpoint(allocator, args[2], diagnostic);
        } else if (std.mem.eql(u8, head, "contact-count")) {
            if (draft.has_contact_count)
                return fail(diagnostic, .duplicate_sexp_field, "interface", "an interface declares (contact-count …) once", id);
            draft.has_contact_count = true;
            draft.contact_count = try requiredArgCount(child, diagnostic);
        } else if (std.mem.eql(u8, head, "auto")) {
            if (child.asList().?.len != 1)
                return fail(diagnostic, .invalid_sexp_value, "interface.auto", "(auto) takes no arguments", id);
            draft.auto = true;
        } else if (std.mem.eql(u8, head, "signal")) {
            try signals.append(allocator, try parseSignal(allocator, child, diagnostic));
        } else {
            return fail(diagnostic, .unknown_sexp_form, "interface", "unknown (interface …) child form", head);
        }
    }
    if (!seen_mates) return fail(diagnostic, .missing_sexp_field, "interface", "an interface declares (mates …)", id);
    draft.signals = signals.items;
    return draft;
}

fn parseEndpoint(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!system_review.InterfaceEndpoint {
    const handle = decodeString(allocator, node.asString() orelse
        return fail(diagnostic, .invalid_sexp_value, "interface.mates", "an endpoint is the quoted handle \"board/CONNECTOR\"", "")) catch |err| return err;
    // A connector handle may itself be a path (`base-interface/J1`), so the
    // board is the FIRST segment and the connector is everything after it.
    var segments = std.mem.splitScalar(u8, handle, '/');
    const board = segments.next() orelse "";
    const connector = segments.rest();
    if (board.len == 0 or connector.len == 0)
        return fail(diagnostic, .invalid_sexp_value, "interface.mates", "an endpoint handle is \"board/CONNECTOR\"", handle);
    return .{ .board = board, .connector = connector };
}

fn parseSignal(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!SignalDraft {
    const children = node.asList().?;
    const canonical = try requiredHeadString(allocator, children, "signal", diagnostic);
    var draft: SignalDraft = .{
        .canonical = canonical,
        .left_pin = "",
        .left_net = "",
        .right_pin = "",
        .right_net = "",
        .has_left_net = false,
        .has_right_net = false,
    };
    var seen_left = false;
    var seen_right = false;
    for (children[2..]) |child| {
        if (child.asAtom()) |token| {
            if (!std.mem.eql(u8, token, "optional"))
                return fail(diagnostic, .unknown_sexp_form, "signal", "the only bare (signal …) option is `optional`", token);
            draft.required = false;
            continue;
        }
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "signal", "a (signal …) child is (left …), (right …) or the bare token `optional`", canonical);
        const left = std.mem.eql(u8, head, "left");
        if (!left and !std.mem.eql(u8, head, "right"))
            return fail(diagnostic, .unknown_sexp_form, "signal", "unknown (signal …) child form", head);
        if (left and seen_left) return fail(diagnostic, .duplicate_sexp_field, "signal", "a signal declares (left …) once", canonical);
        if (!left and seen_right) return fail(diagnostic, .duplicate_sexp_field, "signal", "a signal declares (right …) once", canonical);
        const args = child.asList().?;
        if (args.len < 2 or args.len > 3)
            return fail(diagnostic, .invalid_sexp_value, "signal.side", "a side is (left PIN) or (left PIN \"NET\")", canonical);
        const pin = try pinText(allocator, args[1], diagnostic);
        const net: []const u8 = if (args.len == 3)
            try decodeString(allocator, args[2].asString() orelse
                return fail(diagnostic, .invalid_sexp_value, "signal.side", "a side's net is a quoted name", canonical))
        else
            "";
        if (left) {
            seen_left = true;
            draft.left_pin = pin;
            draft.left_net = net;
            draft.has_left_net = args.len == 3;
        } else {
            seen_right = true;
            draft.right_pin = pin;
            draft.right_net = net;
            draft.has_right_net = args.len == 3;
        }
    }
    if (!seen_left or !seen_right)
        return fail(diagnostic, .missing_sexp_field, "signal", "a signal declares both (left …) and (right …)", canonical);
    return draft;
}

fn parseDocument(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!system_review.DocumentSpec {
    const children = node.asList().?;
    var document: system_review.DocumentSpec = .{
        .id = try requiredHeadString(allocator, children, "document", diagnostic),
        .title = "",
        .path = "",
        .classification = .reference,
    };
    var seen_classification = false;
    var seen_status = false;
    var seen_required = false;
    var seen_fab = false;
    var seen_generated = false;
    for (children[2..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "document", "every (document …) child is a parenthesised form", document.id);
        if (std.mem.eql(u8, head, "title")) {
            try setOnce(&document.title, try requiredArgString(allocator, child, "title", diagnostic), "title", diagnostic);
        } else if (std.mem.eql(u8, head, "path")) {
            try setOnce(&document.path, try requiredArgString(allocator, child, "path", diagnostic), "path", diagnostic);
        } else if (std.mem.eql(u8, head, "classification")) {
            if (seen_classification) return fail(diagnostic, .duplicate_sexp_field, "document", "a document declares (classification …) once", document.id);
            seen_classification = true;
            const token = try requiredArgToken(allocator, child, "classification", diagnostic);
            document.classification = std.meta.stringToEnum(system_review.DocumentClassification, token) orelse
                return fail(diagnostic, .invalid_sexp_value, "document.classification", "unsupported document classification", token);
        } else if (std.mem.eql(u8, head, "status")) {
            if (seen_status) return fail(diagnostic, .duplicate_sexp_field, "document", "a document declares (status …) once", document.id);
            seen_status = true;
            const token = try requiredArgToken(allocator, child, "status", diagnostic);
            document.status = std.meta.stringToEnum(system_review.DocumentStatus, token) orelse
                return fail(diagnostic, .invalid_sexp_value, "document.status", "status is active or historical", token);
        } else if (std.mem.eql(u8, head, "board")) {
            if (document.board != null) return fail(diagnostic, .duplicate_sexp_field, "document", "a document declares (board …) once", document.id);
            document.board = try requiredArgString(allocator, child, "board", diagnostic);
        } else if (std.mem.eql(u8, head, "required")) {
            if (seen_required) return fail(diagnostic, .duplicate_sexp_field, "document", "a document declares (required …) once", document.id);
            seen_required = true;
            document.required = try requiredArgBool(allocator, child, "required", diagnostic);
        } else if (std.mem.eql(u8, head, "include-in-fab")) {
            if (seen_fab) return fail(diagnostic, .duplicate_sexp_field, "document", "a document declares (include-in-fab …) once", document.id);
            seen_fab = true;
            document.include_in_fab = try requiredArgBool(allocator, child, "include-in-fab", diagnostic);
        } else if (std.mem.eql(u8, head, "generated")) {
            if (seen_generated) return fail(diagnostic, .duplicate_sexp_field, "document", "a document declares (generated …) once", document.id);
            seen_generated = true;
            const args = child.asList().?;
            var sections: std.ArrayList([]const u8) = .empty;
            for (args[1..]) |section| try sections.append(allocator, try tokenText(allocator, section, "generated section", diagnostic));
            document.generated_sections = sections.items;
        } else {
            return fail(diagnostic, .unknown_sexp_form, "document", "unknown (document …) child form", head);
        }
    }
    if (document.title.len == 0) return fail(diagnostic, .missing_sexp_field, "document", "a document declares (title \"…\")", document.id);
    if (document.path.len == 0) return fail(diagnostic, .missing_sexp_field, "document", "a document declares (path \"…\")", document.id);
    if (!seen_classification) return fail(diagnostic, .missing_sexp_field, "document", "a document declares (classification …)", document.id);
    return document;
}

fn parseAttestation(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!system_review.Attestation {
    var attestation: system_review.Attestation = .{
        .system_lock_sha256 = "",
        .inputs = &.{},
        .documents = &.{},
    };
    var inputs: std.ArrayList(system_review.InputAttestation) = .empty;
    var documents: std.ArrayList(system_review.DocumentAttestation) = .empty;
    for (node.asList().?[1..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "attestation", "every (attestation …) child is a parenthesised form", "");
        const args = child.asList().?;
        if (std.mem.eql(u8, head, "system-lock")) {
            try setOnce(&attestation.system_lock_sha256, try requiredArgString(allocator, child, "system-lock", diagnostic), "system-lock", diagnostic);
        } else if (std.mem.eql(u8, head, "attested-by")) {
            attestation.attested_by = try requiredArgString(allocator, child, "attested-by", diagnostic);
        } else if (std.mem.eql(u8, head, "attested-at")) {
            attestation.attested_at = try requiredArgString(allocator, child, "attested-at", diagnostic);
        } else if (std.mem.eql(u8, head, "input")) {
            if (args.len != 3)
                return fail(diagnostic, .invalid_sexp_value, "attestation.input", "(input \"path\" \"sha256\")", "");
            try inputs.append(allocator, .{
                .path = try decodeString(allocator, args[1].asString() orelse return fail(diagnostic, .invalid_sexp_value, "attestation.input", "(input \"path\" \"sha256\")", "")),
                .sha256 = try decodeString(allocator, args[2].asString() orelse return fail(diagnostic, .invalid_sexp_value, "attestation.input", "(input \"path\" \"sha256\")", "")),
            });
        } else if (std.mem.eql(u8, head, "document")) {
            try documents.append(allocator, try parseDocumentAttestation(allocator, child, diagnostic));
        } else {
            return fail(diagnostic, .unknown_sexp_form, "attestation", "unknown (attestation …) child form", head);
        }
    }
    if (attestation.system_lock_sha256.len == 0)
        return fail(diagnostic, .missing_sexp_field, "attestation", "an attestation declares (system-lock \"…\")", "");
    attestation.inputs = inputs.items;
    attestation.documents = documents.items;
    return attestation;
}

fn parseDocumentAttestation(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError!system_review.DocumentAttestation {
    const args = node.asList().?;
    if (args.len < 4)
        return fail(diagnostic, .invalid_sexp_value, "attestation.document", "(document \"id\" \"path\" \"sha256\" [(checklist T C O)])", "");
    var record: system_review.DocumentAttestation = .{
        .id = try decodeString(allocator, args[1].asString() orelse return fail(diagnostic, .invalid_sexp_value, "attestation.document", "a document attestation names its id", "")),
        .path = try decodeString(allocator, args[2].asString() orelse return fail(diagnostic, .invalid_sexp_value, "attestation.document", "a document attestation names its path", "")),
        .sha256 = try decodeString(allocator, args[3].asString() orelse return fail(diagnostic, .invalid_sexp_value, "attestation.document", "a document attestation carries its digest", "")),
    };
    for (args[4..]) |child| {
        const head = formHead(child) orelse
            return fail(diagnostic, .unknown_sexp_form, "attestation.document", "every trailing child is a parenthesised form", record.id);
        if (!std.mem.eql(u8, head, "checklist"))
            return fail(diagnostic, .unknown_sexp_form, "attestation.document", "unknown document-attestation child form", head);
        const counts = child.asList().?;
        if (counts.len != 4)
            return fail(diagnostic, .invalid_sexp_value, "attestation.document.checklist", "(checklist TOTAL COMPLETE OPEN)", record.id);
        record.checklist = .{
            .total = try countValue(counts[1], diagnostic),
            .complete = try countValue(counts[2], diagnostic),
            .open = try countValue(counts[3], diagnostic),
        };
    }
    return record;
}

// ── `(auto)` derivation and alias synthesis ──────────────────────────

fn resolveInterfaces(
    allocator: std.mem.Allocator,
    drafts: []const InterfaceDraft,
    options: Options,
    diagnostic: *Diagnostic,
) ParseError![]const system_review.InterfaceContract {
    var out: std.ArrayList(system_review.InterfaceContract) = .empty;
    for (drafts) |draft| {
        if (draft.auto and options.resolver == null and options.omit_underivable_interfaces) continue;
        const signals = if (draft.auto)
            try deriveSignals(allocator, draft, options.resolver, diagnostic)
        else
            try explicitSignals(allocator, draft, diagnostic);
        if (draft.has_contact_count and draft.contact_count != signals.len)
            return fail(diagnostic, .invalid_sexp_value, "interface.contact-count", "declared contact-count does not match the interface's contact records", draft.id);
        try out.append(allocator, .{
            .id = draft.id,
            .left = draft.left,
            .right = draft.right,
            .contact_count = signals.len,
            .signals = signals,
            .aliases = try deriveAliases(allocator, draft, signals, diagnostic),
        });
    }
    return out.items;
}

fn explicitSignals(
    allocator: std.mem.Allocator,
    draft: InterfaceDraft,
    diagnostic: *Diagnostic,
) ParseError![]const system_review.InterfaceSignal {
    var out: std.ArrayList(system_review.InterfaceSignal) = .empty;
    for (draft.signals) |signal| {
        if (!signal.has_left_net or !signal.has_right_net)
            return fail(diagnostic, .missing_sexp_field, "interface.signal", "without (auto) each side names its net: (left PIN \"NET\")", signal.canonical);
        try out.append(allocator, .{
            .canonical = signal.canonical,
            .left_pin = signal.left_pin,
            .left_net = signal.left_net,
            .right_pin = signal.right_pin,
            .right_net = signal.right_net,
            .required = signal.required,
        });
    }
    return out.items;
}

fn deriveSignals(
    allocator: std.mem.Allocator,
    draft: InterfaceDraft,
    maybe_resolver: ?Resolver,
    diagnostic: *Diagnostic,
) ParseError![]const system_review.InterfaceSignal {
    const resolver = maybe_resolver orelse
        return fail(diagnostic, .unresolved_connector, "interface.auto", "(auto) needs the two boards' evaluated netlists, which this caller did not supply", draft.id);
    const left = (resolver.lookup(allocator, draft.left.board, draft.left.connector) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResolveFailed => null,
    }) orelse
        return fail(diagnostic, .unresolved_connector, "interface.auto", "the left connector could not be resolved on its board", draft.left.connector);
    const right = (resolver.lookup(allocator, draft.right.board, draft.right.connector) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResolveFailed => null,
    }) orelse
        return fail(diagnostic, .unresolved_connector, "interface.auto", "the right connector could not be resolved on its board", draft.right.connector);
    if (left.len == 0)
        return fail(diagnostic, .unresolved_connector, "interface.auto", "the left connector reports no contacts", draft.left.connector);

    var out: std.ArrayList(system_review.InterfaceSignal) = .empty;
    for (left) |pad| {
        const mate = findContact(right, pad.pin) orelse
            return fail(diagnostic, .unknown_contact, "interface.auto", "the right connector has no contact matching a left contact", pad.pin);
        const left_net = if (pad.net.len > 0) pad.net else try unconnectedNet(allocator, pad.pin);
        const right_net = if (mate.net.len > 0) mate.net else try unconnectedNet(allocator, mate.pin);
        const wired = pad.net.len > 0 or mate.net.len > 0;
        try out.append(allocator, .{
            .canonical = if (pad.net.len > 0) left_net else right_net,
            .left_pin = pad.pin,
            .left_net = left_net,
            .right_pin = mate.pin,
            .right_net = right_net,
            .required = wired,
        });
    }

    // An explicit record overrides exactly one derived contact and may not
    // name a contact neither connector carries.
    for (draft.signals) |override| {
        const index = indexOfContact(out.items, override.left_pin) orelse
            return fail(diagnostic, .unknown_contact, "interface.signal", "signal names a contact the left connector does not carry", override.left_pin);
        const target = &out.items[index];
        if (!sameContact(target.right_pin, override.right_pin))
            return fail(diagnostic, .unknown_contact, "interface.signal", "signal pairs contacts the two connectors do not mate", override.right_pin);
        for (draft.signals[0..indexOfDraft(draft.signals, override)]) |earlier| {
            if (sameContact(earlier.left_pin, override.left_pin))
                return fail(diagnostic, .duplicate_pin, "interface.signal", "two signals claim one contact", override.left_pin);
        }
        target.canonical = override.canonical;
        target.required = override.required;
        if (override.has_left_net) target.left_net = override.left_net;
        if (override.has_right_net) target.right_net = override.right_net;
    }
    return out.items;
}

fn indexOfDraft(signals: []const SignalDraft, target: SignalDraft) usize {
    for (signals, 0..) |signal, index| {
        if (std.mem.eql(u8, signal.left_pin, target.left_pin) and
            std.mem.eql(u8, signal.canonical, target.canonical)) return index;
    }
    return signals.len;
}

fn findContact(contacts: []const Contact, pin: []const u8) ?Contact {
    for (contacts) |contact| if (sameContact(contact.pin, pin)) return contact;
    return null;
}

fn indexOfContact(signals: []const system_review.InterfaceSignal, pin: []const u8) ?usize {
    for (signals, 0..) |signal, index| if (sameContact(signal.left_pin, pin)) return index;
    return null;
}

fn unconnectedNet(allocator: std.mem.Allocator, pin: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s})", .{ unconnected_net_prefix, pin });
}

/// Build the minimal alias set the strict schema requires: one record per
/// endpoint-local net that differs from its contact's canonical name. A local
/// net that would need two different canonical names is a contract error, not
/// a silently dropped alias.
fn deriveAliases(
    allocator: std.mem.Allocator,
    draft: InterfaceDraft,
    signals: []const system_review.InterfaceSignal,
    diagnostic: *Diagnostic,
) ParseError![]const system_review.InterfaceAlias {
    var out: std.ArrayList(system_review.InterfaceAlias) = .empty;
    for (signals) |signal| {
        try appendAlias(allocator, &out, draft.left.board, signal.left_net, signal.canonical, diagnostic);
        try appendAlias(allocator, &out, draft.right.board, signal.right_net, signal.canonical, diagnostic);
    }
    return out.items;
}

fn appendAlias(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(system_review.InterfaceAlias),
    board: []const u8,
    local: []const u8,
    canonical: []const u8,
    diagnostic: *Diagnostic,
) ParseError!void {
    if (std.mem.eql(u8, local, canonical)) return;
    for (out.items) |existing| {
        if (!std.mem.eql(u8, existing.board, board) or !std.mem.eql(u8, existing.local, local)) continue;
        if (!std.mem.eql(u8, existing.canonical, canonical))
            return fail(diagnostic, .duplicate_alias, "interface.signal", "one board-local net cannot carry two canonical names", local);
        return;
    }
    try out.append(allocator, .{ .board = board, .local = local, .canonical = canonical });
}

// ── Printing ─────────────────────────────────────────────────────────

/// Serialize a validated spec as the equivalent `(system …)` source. The
/// output re-parses to the same spec, which is what makes the converter a
/// migration rather than a rewrite.
pub fn write(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    spec: SystemSpec,
) WriteError!void {
    try writer.writeAll(";; Generated by `netlisp tool convert-system-manifest`.\n");
    try writer.writeAll(";; This file is the system contract; edit it as ordinary netlisp source.\n");
    try writer.writeAll("(system ");
    try writeQuoted(writer, spec.name);
    try writer.writeByte('\n');
    try writeField(writer, "title", spec.title);
    try writeField(writer, "part-number", spec.part_number);
    try writeField(writer, "revision", spec.revision);
    try writer.print("  (status {s})\n", .{@tagName(spec.status)});
    if (spec.brief) |brief| try writeBrief(writer, brief);
    for (spec.goals) |goal| try writeGoal(writer, goal);
    for (spec.boards) |board| try writeBoard(writer, board);
    for (spec.interfaces) |interface| try writeInterface(allocator, writer, interface);
    for (spec.documents) |document| try writeDocument(writer, document);
    if (spec.attestation) |attestation| try writeAttestationForm(allocator, writer, attestation);
    try writer.writeAll(")\n");
}

fn writeField(writer: *std.Io.Writer, name: []const u8, value: []const u8) WriteError!void {
    try writer.print("  ({s} ", .{name});
    try writeQuoted(writer, value);
    try writer.writeAll(")\n");
}

/// Print the `(brief …)` form. Optional clauses are printed only when the
/// brief carries them, so a converted manifest states exactly what it declares
/// and re-parses to the same record.
fn writeBrief(writer: *std.Io.Writer, brief: system_review.Brief) WriteError!void {
    try writer.writeAll("\n  (brief\n");
    if (brief.purpose.len > 0) {
        try writer.writeAll("    (purpose ");
        try writeQuoted(writer, brief.purpose);
        try writer.writeAll(")\n");
    }
    if (brief.environment) |environment| try writeBriefEnvironment(writer, environment);
    if (brief.input_power) |power| try writeBriefInputPower(writer, power);
    if (brief.temperature_grade) |grade| try writer.print("    (temperature-grade {s})\n", .{@tagName(grade)});
    if (brief.derating) |derating| try writeIndented(writer, "derating", derating);
    if (brief.ipc_class) |class| try writer.print("    (ipc-class {d})\n", .{class});
    try writeBriefCompliance(writer, brief.compliance);
    for (brief.interfaces) |entry| try writeBriefInterface(writer, entry);
    try writer.writeAll("    )\n");
}

fn writeBriefEnvironment(writer: *std.Io.Writer, environment: system_review.Environment) WriteError!void {
    try writer.print("    (environment (ambient {d} {d})", .{ environment.ambient_min_c, environment.ambient_max_c });
    if (environment.cooling) |cooling| try writer.print(" (cooling {s})", .{@tagName(cooling)});
    if (environment.altitude_m) |altitude| try writer.print(" (altitude {d})", .{altitude});
    if (environment.ingress) |ingress| try writer.print(" (ingress {d})", .{ingress});
    try writer.writeAll(")\n");
}

fn writeBriefInputPower(writer: *std.Io.Writer, power: system_review.InputPower) WriteError!void {
    try writer.writeAll("    (input-power (source ");
    try writeQuoted(writer, power.source);
    try writer.print(") (voltage {d} {d})", .{ power.voltage_min_v, power.voltage_max_v });
    if (power.transient_v) |transient| try writer.print(" (transient {d})", .{transient});
    if (power.current_max_a) |current| try writer.print(" (current-max {d})", .{current});
    try writer.writeAll(")\n");
}

fn writeBriefCompliance(writer: *std.Io.Writer, compliance: system_review.Compliance) WriteError!void {
    if (compliance.esd == null and compliance.emc == null and compliance.safety == null) return;
    try writer.writeAll("    (compliance");
    const regimes = [_]struct { name: []const u8, value: ?[]const u8 }{
        .{ .name = "esd", .value = compliance.esd },
        .{ .name = "emc", .value = compliance.emc },
        .{ .name = "safety", .value = compliance.safety },
    };
    for (regimes) |regime| {
        const value = regime.value orelse continue;
        try writer.print(" ({s} ", .{regime.name});
        try writeQuoted(writer, value);
        try writer.writeByte(')');
    }
    try writer.writeAll(")\n");
}

fn writeBriefInterface(writer: *std.Io.Writer, entry: system_review.BriefInterface) WriteError!void {
    try writer.writeAll("    (interface ");
    try writeQuoted(writer, entry.name);
    if (entry.connector) |connector| {
        try writer.writeAll(" (connector ");
        try writeQuoted(writer, connector);
        try writer.writeByte(')');
    }
    if (entry.impedance_ohm) |impedance| try writer.print(" (impedance {d})", .{impedance});
    if (entry.power_max_dbm) |power| try writer.print(" (power-max {d})", .{power});
    if (entry.protocol) |protocol| {
        try writer.writeAll(" (protocol ");
        try writeQuoted(writer, protocol);
        try writer.writeByte(')');
    }
    try writer.writeAll(")\n");
}

/// Print one `(goal …)` row. The unit is quoted rather than bare because a
/// unit may carry characters (`%`, `dBc/Hz`) the tokenizer would not read back
/// as one atom; the parser accepts either spelling.
fn writeGoal(writer: *std.Io.Writer, goal: system_review.GoalSpec) WriteError!void {
    try writer.writeAll("\n  (goal ");
    try writeQuoted(writer, goal.id);
    if (goal.title.len > 0) {
        try writer.writeAll(" (title ");
        try writeQuoted(writer, goal.title);
        try writer.writeByte(')');
    }
    try writer.writeAll(" (unit ");
    try writeQuoted(writer, goal.unit);
    try writer.writeByte(')');
    if (goal.min) |min| try writer.print(" (min {d})", .{min});
    if (goal.max) |max| try writer.print(" (max {d})", .{max});
    try writer.print(" (verify-by {s}", .{@tagName(goal.verify_by)});
    if (goal.reference) |reference| {
        try writer.writeByte(' ');
        try writeQuoted(writer, reference);
    }
    try writer.writeByte(')');
    if (goal.measured) |measured| {
        try writer.print(" (measured {d} ", .{measured.value});
        try writeQuoted(writer, measured.evidence);
        try writer.writeByte(')');
    }
    try writer.writeAll(")\n");
}

fn writeBoard(writer: *std.Io.Writer, board: system_review.BoardMember) WriteError!void {
    try writer.writeAll("\n  (board ");
    try writeQuoted(writer, board.name);
    try writer.print("\n    (role {s})\n    (source ", .{board.role});
    try writeQuoted(writer, board.source);
    try writer.writeAll(")\n    (part-number ");
    try writeQuoted(writer, board.part_number);
    try writer.writeAll(")\n    (revision ");
    try writeQuoted(writer, board.revision);
    try writer.writeAll(")\n    (layout ");
    try writeQuoted(writer, board.layout);
    try writer.print(")\n    (dnp {s}))\n", .{@tagName(board.dnp)});
}

fn writeInterface(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    interface: system_review.InterfaceContract,
) WriteError!void {
    try writer.writeAll("\n  (interface ");
    try writeQuoted(writer, interface.id);
    try writer.writeAll("\n    (mates ");
    try writeHandle(allocator, writer, interface.left);
    try writer.writeByte(' ');
    try writeHandle(allocator, writer, interface.right);
    try writer.print(")\n    (contact-count {d})\n", .{interface.contact_count});
    for (interface.signals) |signal| {
        try writer.writeAll("    (signal ");
        try writeQuoted(writer, signal.canonical);
        try writer.writeAll(" (left ");
        try writePin(writer, signal.left_pin);
        try writer.writeByte(' ');
        try writeQuoted(writer, signal.left_net);
        try writer.writeAll(") (right ");
        try writePin(writer, signal.right_pin);
        try writer.writeByte(' ');
        try writeQuoted(writer, signal.right_net);
        try writer.writeByte(')');
        if (!signal.required) try writer.writeAll(" optional");
        try writer.writeAll(")\n");
    }
    // Aliases are re-derived on parse, so they are printed only as a comment
    // trail: emitting them as forms would invite an authored set that the
    // derivation then contradicts.
    for (interface.aliases) |alias| {
        try writer.print("    ;; alias {s}: {s} -> {s}\n", .{ alias.board, alias.local, alias.canonical });
    }
    try writer.writeAll("    )\n");
}

fn writeHandle(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    endpoint: system_review.InterfaceEndpoint,
) WriteError!void {
    const handle = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ endpoint.board, endpoint.connector });
    defer allocator.free(handle);
    try writeQuoted(writer, handle);
}

fn writeDocument(writer: *std.Io.Writer, document: system_review.DocumentSpec) WriteError!void {
    try writer.writeAll("\n  (document ");
    try writeQuoted(writer, document.id);
    try writer.writeAll("\n    (title ");
    try writeQuoted(writer, document.title);
    try writer.writeAll(")\n    (path ");
    try writeQuoted(writer, document.path);
    try writer.print(")\n    (classification {s})\n    (status {s})\n", .{
        @tagName(document.classification),
        @tagName(document.status),
    });
    if (document.board) |board| {
        try writer.writeAll("    (board ");
        try writeQuoted(writer, board);
        try writer.writeAll(")\n");
    }
    try writer.print("    (required {s})\n    (include-in-fab {s})", .{
        if (document.required) "true" else "false",
        if (document.include_in_fab) "true" else "false",
    });
    if (document.generated_sections.len > 0) {
        try writer.writeAll("\n    (generated");
        for (document.generated_sections) |section| try writer.print(" {s}", .{section});
        try writer.writeByte(')');
    }
    try writer.writeAll(")\n");
}

/// Serialize one `(attestation …)` form, indented as a `(system …)` child and
/// framed by a leading and a trailing newline. Inputs and documents are
/// emitted in `system_review.canonicalAttestation` order, so this form and the
/// JSON attestation value describe byte-for-byte the same record.
pub fn writeAttestationForm(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    raw_attestation: system_review.Attestation,
) WriteError!void {
    const attestation = try system_review.canonicalAttestation(allocator, raw_attestation);
    defer system_review.freeCanonicalAttestation(allocator, attestation);
    try writer.writeAll("\n  (attestation\n    (system-lock ");
    try writeQuoted(writer, attestation.system_lock_sha256);
    try writer.writeAll(")\n");
    if (attestation.attested_by) |identity| try writeIndented(writer, "attested-by", identity);
    if (attestation.attested_at) |timestamp| try writeIndented(writer, "attested-at", timestamp);
    for (attestation.inputs) |input| {
        try writer.writeAll("    (input ");
        try writeQuoted(writer, input.path);
        try writer.writeByte(' ');
        try writeQuoted(writer, input.sha256);
        try writer.writeAll(")\n");
    }
    for (attestation.documents) |document| {
        try writer.writeAll("    (document ");
        try writeQuoted(writer, document.id);
        try writer.writeByte(' ');
        try writeQuoted(writer, document.path);
        try writer.writeByte(' ');
        try writeQuoted(writer, document.sha256);
        try writer.print(" (checklist {d} {d} {d}))\n", .{
            document.checklist.total,
            document.checklist.complete,
            document.checklist.open,
        });
    }
    try writer.writeAll("    )\n");
}

fn writeIndented(writer: *std.Io.Writer, name: []const u8, value: []const u8) WriteError!void {
    try writer.print("    ({s} ", .{name});
    try writeQuoted(writer, value);
    try writer.writeAll(")\n");
}

/// Print a pin id bare when it is a decimal token that survives the trip
/// through the parser's integer literal unchanged, and quoted otherwise —
/// a zero-padded `01` must not silently become `1`.
fn writePin(writer: *std.Io.Writer, pin: []const u8) WriteError!void {
    if (canonicalDecimal(pin)) {
        try writer.writeAll(pin);
        return;
    }
    try writeQuoted(writer, pin);
}

fn canonicalDecimal(text: []const u8) bool {
    if (text.len == 0 or text.len > 18) return false;
    if (text.len > 1 and text[0] == '0') return false;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn writeQuoted(writer: *std.Io.Writer, value: []const u8) WriteError!void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

// ── Node helpers ─────────────────────────────────────────────────────

fn formHead(node: Node) ?[]const u8 {
    const children = node.asList() orelse return null;
    if (children.len == 0) return null;
    return children[0].asAtom();
}

fn requiredHeadString(
    allocator: std.mem.Allocator,
    children: []const Node,
    form: []const u8,
    diagnostic: *Diagnostic,
) ParseError![]const u8 {
    if (children.len < 2)
        return fail(diagnostic, .missing_sexp_field, form, "this form is named by a quoted identifier", form);
    const raw = children[1].asString() orelse
        return fail(diagnostic, .invalid_sexp_value, form, "this form is named by a quoted identifier", form);
    return decodeString(allocator, raw);
}

fn requiredArgString(
    allocator: std.mem.Allocator,
    node: Node,
    field: []const u8,
    diagnostic: *Diagnostic,
) ParseError![]const u8 {
    const children = node.asList().?;
    if (children.len != 2)
        return fail(diagnostic, .invalid_sexp_value, field, "this form takes exactly one quoted argument", field);
    const raw = children[1].asString() orelse
        return fail(diagnostic, .invalid_sexp_value, field, "this form's argument is a quoted string", field);
    return decodeString(allocator, raw);
}

fn requiredArgToken(
    allocator: std.mem.Allocator,
    node: Node,
    field: []const u8,
    diagnostic: *Diagnostic,
) ParseError![]const u8 {
    const children = node.asList().?;
    if (children.len != 2)
        return fail(diagnostic, .invalid_sexp_value, field, "this form takes exactly one keyword argument", field);
    return tokenText(allocator, children[1], field, diagnostic);
}

fn tokenText(
    allocator: std.mem.Allocator,
    node: Node,
    field: []const u8,
    diagnostic: *Diagnostic,
) ParseError![]const u8 {
    if (node.asAtom()) |atom| return atom;
    if (node.asString()) |raw| return decodeString(allocator, raw);
    return fail(diagnostic, .invalid_sexp_value, field, "expected a bare keyword or a quoted string", field);
}

fn requiredArgBool(
    allocator: std.mem.Allocator,
    node: Node,
    field: []const u8,
    diagnostic: *Diagnostic,
) ParseError!bool {
    const token = try requiredArgToken(allocator, node, field, diagnostic);
    if (std.mem.eql(u8, token, "true")) return true;
    if (std.mem.eql(u8, token, "false")) return false;
    return fail(diagnostic, .invalid_sexp_value, field, "expected true or false", token);
}

fn requiredArgCount(node: Node, diagnostic: *Diagnostic) ParseError!usize {
    const children = node.asList().?;
    if (children.len != 2)
        return fail(diagnostic, .invalid_sexp_value, "contact-count", "this form takes exactly one non-negative integer", "");
    return countValue(children[1], diagnostic);
}

fn countValue(node: Node, diagnostic: *Diagnostic) ParseError!usize {
    return switch (node.tag) {
        .int => |value| if (value >= 0)
            @intCast(value)
        else
            fail(diagnostic, .invalid_sexp_value, "count", "expected a non-negative integer", ""),
        else => fail(diagnostic, .invalid_sexp_value, "count", "expected a non-negative integer", ""),
    };
}

fn requiredArgNumber(node: Node, field: []const u8, diagnostic: *Diagnostic) ParseError!f64 {
    const children = node.asList().?;
    if (children.len != 2)
        return fail(diagnostic, .invalid_sexp_value, field, "this form takes exactly one number", field);
    return numberValue(children[1], field, diagnostic);
}

fn requiredArgCountNamed(node: Node, field: []const u8, diagnostic: *Diagnostic) ParseError!usize {
    const children = node.asList().?;
    if (children.len != 2)
        return fail(diagnostic, .invalid_sexp_value, field, "this form takes exactly one non-negative integer", field);
    return countValue(children[1], diagnostic);
}

fn numberValue(node: Node, field: []const u8, diagnostic: *Diagnostic) ParseError!f64 {
    return switch (node.tag) {
        .int => |value| @floatFromInt(value),
        .float, .unit_val => |value| value,
        else => fail(diagnostic, .invalid_sexp_value, field, "expected a number", field),
    };
}

fn pinText(
    allocator: std.mem.Allocator,
    node: Node,
    diagnostic: *Diagnostic,
) ParseError![]const u8 {
    return switch (node.tag) {
        .int => |value| std.fmt.allocPrint(allocator, "{d}", .{value}),
        .atom => |atom| atom,
        .string => |raw| decodeString(allocator, raw),
        else => fail(diagnostic, .invalid_sexp_value, "signal.side", "a contact is an integer or a quoted pad id", ""),
    };
}

fn setOnce(
    slot: *[]const u8,
    value: []const u8,
    field: []const u8,
    diagnostic: *Diagnostic,
) ParseError!void {
    if (slot.len != 0)
        return fail(diagnostic, .duplicate_sexp_field, field, "this form is declared at most once", field);
    slot.* = value;
}

/// Decode the tokenizer's raw between-the-quotes slice. `Node.string` keeps
/// the source escaping verbatim (the printer relies on that), while a spec
/// field holds the decoded text the JSON loader would have produced.
fn decodeString(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        if (raw[index] != '\\' or index + 1 >= raw.len) {
            try out.append(allocator, raw[index]);
            continue;
        }
        index += 1;
        try out.append(allocator, switch (raw[index]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => raw[index],
        });
    }
    return out.items;
}

fn fail(
    diagnostic: *Diagnostic,
    code: system_review.DiagnosticCode,
    field: []const u8,
    message: []const u8,
    value: []const u8,
) error{InvalidSystemSexp} {
    diagnostic.* = .{ .code = code, .field = field, .message = message, .value = value };
    return error.InvalidSystemSexp;
}

// ── `convert-system-manifest` ────────────────────────────────────────

const review_assets = @import("system_review_assets.zig");
const json_writer = @import("json_writer.zig");

/// Everything the converter reports.
pub const ToolError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// `convert-system-manifest` — print the `(system …)` source equivalent to an
/// existing `src/systems/<name>/system.json`. It is deliberately read-only:
/// the operator decides whether the printed contract replaces the JSON, so a
/// conversion can be reviewed as a diff before a workspace changes hands.
pub fn convertTool(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) ToolError!bool {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const name = stringArg(args_val, "system") orelse
        return refuse(&aw.writer, "system is required");
    if (!isSimpleSystemName(name))
        return refuse(&aw.writer, "system must be a portable workspace name");
    const relative = try std.fmt.allocPrint(allocator, "src/systems/{s}/{s}", .{ name, json_manifest_name });
    const source = review_assets.readContainedFile(
        allocator,
        project_dir,
        relative,
        system_review.max_manifest_bytes,
    ) catch return refuse(&aw.writer, "cannot read this system's system.json");
    var diagnostic: Diagnostic = .{};
    var parsed = system_review.parseSystemSpec(allocator, source, &diagnostic) catch
        return refuse(&aw.writer, diagnostic.message);
    defer parsed.deinit();
    try write(allocator, &aw.writer, parsed.value);
    return true;
}

fn isSimpleSystemName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name[1..]) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') continue;
        return false;
    }
    return true;
}

fn stringArg(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const args = args_val orelse return null;
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn refuse(writer: *std.Io.Writer, message: []const u8) ToolError!bool {
    try writer.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(writer, message);
    try writer.writeAll("}");
    return false;
}

// ── Manifest discovery and in-place attestation edits ────────────────

/// Which of the two manifest spellings a workspace's contract is written in.
pub const ManifestKind = enum { sexp, json };

/// The one manifest file a workspace's contract is read from, and its bytes.
pub const Manifest = struct {
    kind: ManifestKind,
    /// Project-relative path the bytes came from.
    relative: []const u8,
    source: []const u8,
    /// True when a `system.sexp` won over a `system.json` still on disk. The
    /// JSON is then inert, and the readiness gate says so rather than
    /// silently ignoring it.
    shadowed_json: bool = false,
};

/// Errors `locate` reports. A workspace with neither manifest surfaces as the
/// `FileNotFound` the JSON read raises, so "no such system" keeps one spelling.
pub const LocateError = error{InvalidSystemName} ||
    @typeInfo(@typeInfo(@TypeOf(review_assets.readContainedFile)).@"fn".return_type.?).error_union.error_set;

/// Resolve which file is `name`'s contract and read it. The DSL contract wins
/// when it exists; the JSON stays loadable unchanged for every workspace that
/// has not migrated. Every reader and writer of a system manifest — the
/// readiness gate, the dossier composer, the home page's cards and the HTTP
/// attestation endpoint — goes through this one function, so no surface can
/// decide on its own that a workspace does not exist.
pub fn locate(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) LocateError!Manifest {
    if (!isSimpleSystemName(name)) return error.InvalidSystemName;
    const sexp_rel = try std.fmt.allocPrint(allocator, "src/systems/{s}/{s}", .{ name, sexp_manifest_name });
    if (readOptional(allocator, project_dir, sexp_rel)) |source| {
        const json_rel = try std.fmt.allocPrint(allocator, "src/systems/{s}/{s}", .{ name, json_manifest_name });
        defer allocator.free(json_rel);
        // Only whether the shadowed JSON is there matters; its bytes are inert.
        const shadow = readOptional(allocator, project_dir, json_rel);
        if (shadow) |bytes| allocator.free(bytes);
        return .{
            .kind = .sexp,
            .relative = sexp_rel,
            .source = source,
            .shadowed_json = shadow != null,
        };
    }
    allocator.free(sexp_rel);
    const json_rel = try std.fmt.allocPrint(allocator, "src/systems/{s}/{s}", .{ name, json_manifest_name });
    errdefer allocator.free(json_rel);
    return .{
        .kind = .json,
        .relative = json_rel,
        .source = try review_assets.readContainedFile(
            allocator,
            project_dir,
            json_rel,
            system_review.max_manifest_bytes,
        ),
    };
}

/// Read one optional manifest file. Only absence is null; every other read
/// failure still propagates through the caller's own read of the file it
/// decided to use.
fn readOptional(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    relative: []const u8,
) ?[]const u8 {
    return review_assets.readContainedFile(
        allocator,
        project_dir,
        relative,
        system_review.max_manifest_bytes,
    ) catch null;
}

/// Half-open byte range of a form inside a contract source.
pub const Span = struct { start: usize, end: usize };

/// Byte span of the `(attestation …)` child of the top-level `(system …)`
/// form, or null when the contract carries none. Located by parsing for the
/// form's start offset and matching its closing paren over the raw text, so a
/// paren inside a quoted net name cannot end it early.
/// `allocator` holds the throwaway parse; callers pass a scratch arena.
pub fn attestationSpan(allocator: std.mem.Allocator, source: []const u8) ?Span {
    const nodes = parser.parse(allocator, source) catch return null;
    for (nodes) |node| {
        if (!node.isForm("system")) continue;
        const children = node.asList() orelse continue;
        for (children) |child| {
            if (!child.isForm("attestation")) continue;
            const start: usize = child.span.offset;
            const end = paren_span.endIndex(source, start, .line_semicolon) orelse return null;
            return .{ .start = start, .end = end };
        }
    }
    return null;
}

/// True when the contract already carries an `(attestation …)`.
pub fn hasAttestation(allocator: std.mem.Allocator, source: []const u8) bool {
    return attestationSpan(allocator, source) != null;
}

/// Replace — or, when absent, append — the `(attestation …)` child of a
/// contract source, leaving every other byte, comment and blank line exactly
/// as authored. `form` is one rendered `(attestation …)` as
/// `writeAttestationForm` prints it. Null when the source has no top-level
/// `(system …)` form to edit.
pub fn withAttestation(
    allocator: std.mem.Allocator,
    source: []const u8,
    form: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    const body = std.mem.trim(u8, form, " \t\r\n");
    if (attestationSpan(allocator, source)) |span|
        return try std.mem.concat(allocator, u8, &.{ source[0..span.start], body, source[span.end..] });
    const close = systemFormClose(allocator, source) orelse return null;
    var insert_at = close;
    while (insert_at > 0 and std.ascii.isWhitespace(source[insert_at - 1])) insert_at -= 1;
    return try std.mem.concat(allocator, u8, &.{ source[0..insert_at], "\n  ", body, source[insert_at..] });
}

/// Drop the `(attestation …)` child of a contract source. A form that owns its
/// own lines takes its indentation and the newline above it with it, so
/// invalidating an approval restores the source `withAttestation` was handed;
/// a form written inline keeps the line it shares intact. Null when there is
/// none to drop — an approval that was never granted needs no invalidation,
/// and the caller can skip the write entirely.
pub fn withoutAttestation(
    allocator: std.mem.Allocator,
    source: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    const span = attestationSpan(allocator, source) orelse return null;
    var indent = span.start;
    while (indent > 0 and (source[indent - 1] == ' ' or source[indent - 1] == '\t')) indent -= 1;
    const start = if (indent > 0 and source[indent - 1] == '\n') indent - 1 else span.start;
    return try std.mem.concat(allocator, u8, &.{ source[0..start], source[span.end..] });
}

/// Byte offset of the `)` closing the top-level `(system …)` form.
fn systemFormClose(allocator: std.mem.Allocator, source: []const u8) ?usize {
    const nodes = parser.parse(allocator, source) catch return null;
    for (nodes) |node| {
        if (!node.isForm("system")) continue;
        return paren_span.matchingClose(source, node.span.offset, .line_semicolon);
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const fixture_source =
    \\(system "demo-system"
    \\  (title "Demo System")
    \\  (part-number "DEMO-001")
    \\  (revision "B3")
    \\  (board "rf"
    \\    (role rf)
    \\    (source "src/rf.sexp")
    \\    (part-number "SYS-RF")
    \\    (revision "B3"))
    \\  (board "base"
    \\    (role base)
    \\    (source "src/base.sexp")
    \\    (part-number "SYS-BASE")
    \\    (revision "B3")
    \\    (layout "release")
    \\    (dnp keep))
    \\  (interface "board-to-board"
    \\    (mates "rf/J1" "base/base-interface/J1")
    \\    (contact-count 2)
    \\    (signal "V_12V" (left 1 "V_12V") (right 1 "V_12V"))
    \\    (signal "SPI_CLK" (left 2 "SCK") (right 2 "SPI_CLK")))
    \\  (document "overview"
    \\    (title "Overview")
    \\    (path "src/systems/demo/overview.md")
    \\    (classification review)
    \\    (generated system-summary))
    \\  (document "release-checklist"
    \\    (title "Release checklist")
    \\    (path "src/systems/demo/release-checklist.md")
    \\    (classification checklist)))
;

/// Two four-pin headers that mate contact for contact. Pin 4 is wired on the
/// left and dead on the right, which is the case `(auto)` has to represent
/// without inventing a net name that could collide with a real one.
const left_pads = [_]Contact{
    .{ .pin = "1", .net = "V_5V" },
    .{ .pin = "2", .net = "GND" },
    .{ .pin = "3", .net = "SCK" },
    .{ .pin = "4", .net = "SPARE" },
};
const right_pads = [_]Contact{
    .{ .pin = "01", .net = "V_5V_SYS" },
    .{ .pin = "02", .net = "GND" },
    .{ .pin = "03", .net = "SPI_CLK" },
    .{ .pin = "04", .net = "" },
};

const FixtureResolver = struct {
    fail_left: bool = false,

    fn resolver(self: *FixtureResolver) Resolver {
        return .{ .ctx = self, .lookupFn = lookup };
    }

    fn lookup(
        ctx: *anyopaque,
        _: std.mem.Allocator,
        board: []const u8,
        _: []const u8,
    ) Resolver.Error!?[]const Contact {
        const self: *FixtureResolver = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, board, "rf")) {
            if (self.fail_left) return error.ResolveFailed;
            return &left_pads;
        }
        return &right_pads;
    }
};

// spec: system-review - the (system …) source parses to the same strict v1 spec the JSON manifest produces, deriving the canonical-net aliases the schema requires
test "system sexp parses a complete contract and derives its aliases" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: Diagnostic = .{};
    const spec = try parse(allocator, fixture_source, null, &diagnostic);
    try system_review.validateSystemSpec(allocator, spec, &diagnostic);

    try testing.expectEqualStrings(system_review.schema_v1, spec.schema);
    try testing.expectEqualStrings("demo-system", spec.name);
    try testing.expectEqualStrings("DEMO-001", spec.part_number);
    try testing.expectEqual(@as(usize, 2), spec.boards.len);
    try testing.expectEqualStrings("blessed", spec.boards[0].layout);
    try testing.expectEqual(system_review.DnpPolicy.drop, spec.boards[0].dnp);
    try testing.expectEqualStrings("release", spec.boards[1].layout);
    try testing.expectEqual(system_review.DnpPolicy.keep, spec.boards[1].dnp);

    const interface = spec.interfaces[0];
    try testing.expectEqualStrings("rf", interface.left.board);
    try testing.expectEqualStrings("J1", interface.left.connector);
    try testing.expectEqualStrings("base", interface.right.board);
    try testing.expectEqualStrings("base-interface/J1", interface.right.connector);
    try testing.expectEqual(@as(usize, 2), interface.contact_count);
    try testing.expect(interface.signals[1].required);
    // The one endpoint-local net that differs from its canonical name is the
    // one alias — nothing is authored and nothing extra is invented.
    try testing.expectEqual(@as(usize, 1), interface.aliases.len);
    try testing.expectEqualStrings("rf", interface.aliases[0].board);
    try testing.expectEqualStrings("SCK", interface.aliases[0].local);
    try testing.expectEqualStrings("SPI_CLK", interface.aliases[0].canonical);
    try testing.expectEqual(@as(usize, 1), spec.documents[0].generated_sections.len);
    try testing.expectEqual(system_review.DocumentStatus.active, spec.documents[0].status);
}

// spec: system-review - an (auto) interface derives every contact from the two connectors' pad tables by contact number, and an explicit signal overrides one of them
test "system sexp derives an auto interface and honours explicit overrides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var fixture = FixtureResolver{};
    var diagnostic: Diagnostic = .{};
    const source =
        \\(system "auto-demo"
        \\  (title "Auto Demo")
        \\  (part-number "AUTO-1")
        \\  (revision "A")
        \\  (board "rf" (role rf) (source "src/rf.sexp") (part-number "RF") (revision "A"))
        \\  (board "base" (role base) (source "src/base.sexp") (part-number "BASE") (revision "A"))
        \\  (interface "link"
        \\    (mates "rf/J1" "base/J1")
        \\    (auto)
        \\    (signal "SPI_CLK" (left 3) (right 3)))
        \\  (document "release-checklist" (title "Checklist")
        \\    (path "src/systems/auto-demo/release-checklist.md") (classification checklist)))
    ;
    const spec = try parse(allocator, source, fixture.resolver(), &diagnostic);
    try system_review.validateSystemSpec(allocator, spec, &diagnostic);

    const interface = spec.interfaces[0];
    try testing.expectEqual(@as(usize, 4), interface.contact_count);
    // Contact 1: the left net is canonical, the right local name is aliased.
    try testing.expectEqualStrings("V_5V", interface.signals[0].canonical);
    try testing.expectEqualStrings("V_5V_SYS", interface.signals[0].right_net);
    // The right connector spells its pads `01`; the derived record keeps that
    // spelling rather than pretending both sides agree on it.
    try testing.expectEqualStrings("01", interface.signals[0].right_pin);
    // Contact 2 is the same net on both sides, so it needs no alias at all.
    try testing.expectEqualStrings("GND", interface.signals[1].canonical);
    // Contact 3 is overridden: the canonical name is the authored one while
    // both endpoint-local nets stay as the netlists report them.
    try testing.expectEqualStrings("SPI_CLK", interface.signals[2].canonical);
    try testing.expectEqualStrings("SCK", interface.signals[2].left_net);
    // Contact 4 is wired on one side only, so its dead side carries the
    // synthetic no-net name and no real net is invented for it.
    try testing.expect(isUnconnectedNet(interface.signals[3].right_net));
    try testing.expectEqualStrings("SPARE", interface.signals[3].left_net);
    try testing.expect(interface.signals[3].required);
}

// spec: system-review - a (system …) source is refused with an actionable diagnostic for a syntax error, an unknown form, a missing field, an oversized source, a contact neither connector carries and an unresolvable auto endpoint
test "system sexp refuses malformed contracts with a located diagnostic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    try testing.expectError(error.InvalidSystemSexp, parse(allocator, "(system \"x\"", null, &diagnostic));
    try testing.expectEqual(system_review.DiagnosticCode.invalid_sexp, diagnostic.code);

    try testing.expectError(error.InvalidSystemSexp, parse(allocator,
        \\(system "x" (title "X") (part-number "P") (revision "A") (surprise "y"))
    , null, &diagnostic));
    try testing.expectEqual(system_review.DiagnosticCode.unknown_sexp_form, diagnostic.code);
    try testing.expectEqualStrings("surprise", diagnostic.value);

    try testing.expectError(error.InvalidSystemSexp, parse(allocator,
        \\(system "x" (part-number "P") (revision "A"))
    , null, &diagnostic));
    try testing.expectEqual(system_review.DiagnosticCode.missing_sexp_field, diagnostic.code);

    // Without (auto) each side names its own net; a half-declared contact is a
    // refusal rather than a record with an empty net.
    try testing.expectError(error.InvalidSystemSexp, parse(allocator,
        \\(system "x" (title "X") (part-number "P") (revision "A")
        \\  (board "a" (role a) (source "src/a.sexp") (part-number "A") (revision "A"))
        \\  (board "b" (role b) (source "src/b.sexp") (part-number "B") (revision "A"))
        \\  (interface "link" (mates "a/J1" "b/J1") (signal "S" (left 1) (right 1))))
    , null, &diagnostic));
    try testing.expectEqual(system_review.DiagnosticCode.missing_sexp_field, diagnostic.code);

    const oversized = try allocator.alloc(u8, system_review.max_manifest_bytes + 1);
    @memset(oversized, ' ');
    try testing.expectError(error.SourceTooLarge, parse(allocator, oversized, null, &diagnostic));
    try testing.expectEqual(system_review.DiagnosticCode.manifest_too_large, diagnostic.code);

    const auto_prefix =
        \\(system "x" (title "X") (part-number "P") (revision "A")
        \\  (board "rf" (role rf) (source "src/rf.sexp") (part-number "R") (revision "A"))
        \\  (board "base" (role base) (source "src/base.sexp") (part-number "B") (revision "A"))
        \\  (interface "link" (mates "rf/J1" "base/J1") (auto)
    ;
    var fixture = FixtureResolver{};
    try testing.expectError(error.InvalidSystemSexp, parse(
        allocator,
        auto_prefix ++ "\n    (signal \"S\" (left 9) (right 9))))",
        fixture.resolver(),
        &diagnostic,
    ));
    try testing.expectEqual(system_review.DiagnosticCode.unknown_contact, diagnostic.code);
    try testing.expectEqualStrings("9", diagnostic.value);

    // (auto) with no resolver, and a resolver that cannot see the board, are
    // both refusals: a derived contract is never quietly left empty.
    try testing.expectError(error.InvalidSystemSexp, parse(allocator, auto_prefix ++ "))", null, &diagnostic));
    try testing.expectEqual(system_review.DiagnosticCode.unresolved_connector, diagnostic.code);
    var broken = FixtureResolver{ .fail_left = true };
    try testing.expectError(
        error.ResolveFailed,
        broken.resolver().lookup(allocator, "rf", "J1"),
    );
    try testing.expectError(error.InvalidSystemSexp, parse(allocator, auto_prefix ++ "))", broken.resolver(), &diagnostic));
    try testing.expectEqual(system_review.DiagnosticCode.unresolved_connector, diagnostic.code);
}

// spec: system-review - a JSON manifest converted to (system …) and parsed back yields the identical canonical spec, so the converter is a migration rather than a rewrite
test "system sexp round-trips a JSON manifest through the canonical digest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const json =
        \\{
        \\  "schema":"netlisp-system-review-v1",
        \\  "name":"demo-system",
        \\  "title":"Demo \"quoted\" System",
        \\  "part_number":"DEMO-001",
        \\  "revision":"B3",
        \\  "boards":[
        \\    {"name":"rf","role":"rf","source":"src/rf.sexp","part_number":"SYS-RF","revision":"B3"},
        \\    {"name":"base","role":"base","source":"src/base.sexp","part_number":"SYS-BASE","revision":"B3","layout":"release","dnp":"keep"}
        \\  ],
        \\  "interfaces":[{
        \\    "id":"board-to-board",
        \\    "left":{"board":"rf","connector":"J1"},
        \\    "right":{"board":"base","connector":"base-interface/J1"},
        \\    "contact_count":3,
        \\    "signals":[
        \\      {"canonical":"V_12V","left_pin":"1","left_net":"V_12V","right_pin":"1","right_net":"V_12V_RF"},
        \\      {"canonical":"SPI_CLK","left_pin":"2","left_net":"SCK","right_pin":"2","right_net":"SPI_CLK"},
        \\      {"canonical":"NC","left_pin":"03","left_net":"NC","right_pin":"03","right_net":"NC","required":false}
        \\    ],
        \\    "aliases":[
        \\      {"board":"rf","local":"SCK","canonical":"SPI_CLK"},
        \\      {"board":"base","local":"V_12V_RF","canonical":"V_12V"}
        \\    ]
        \\  }],
        \\  "documents":[
        \\    {"id":"overview","title":"Overview","path":"src/systems/demo/overview.md",
        \\     "classification":"review","generated_sections":["system-summary","interface-matrix"]},
        \\    {"id":"release-checklist","title":"Release checklist","path":"src/systems/demo/release-checklist.md",
        \\     "classification":"checklist","board":"base","include_in_fab":false}
        \\  ]
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    var parsed = try system_review.parseSystemSpec(allocator, json, &diagnostic);
    defer parsed.deinit();

    var rendered: std.Io.Writer.Allocating = .init(allocator);
    try write(allocator, &rendered.writer, parsed.value);
    const round_tripped = try parse(allocator, rendered.written(), null, &diagnostic);
    try system_review.validateSystemSpec(allocator, round_tripped, &diagnostic);

    const before = try system_review.canonicalSpecDigest(allocator, parsed.value);
    const after = try system_review.canonicalSpecDigest(allocator, round_tripped);
    try testing.expectEqualSlices(u8, &before, &after);
    // A quoted title survives the escape round trip, and a zero-padded pad id
    // is not silently renumbered by the integer printer.
    try testing.expectEqualStrings("Demo \"quoted\" System", round_tripped.title);
    try testing.expectEqualStrings("03", round_tripped.interfaces[0].signals[2].left_pin);
    try testing.expect(!round_tripped.interfaces[0].signals[2].required);
}

// spec: system-review - convert-system-manifest is a read-only registered tool whose printed source re-parses to the manifest it was given
test "convert-system-manifest prints a re-parsable contract without writing" {
    const mcp_tools = @import("serve/mcp_tools.zig");
    try testing.expect(mcp_tools.isKnownTool("convert-system-manifest"));
    try testing.expect(!mcp_tools.isMutationTool("convert-system-manifest"));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "project/src/systems/demo");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "project/src/systems/demo/system.json",
        .data =
        \\{"schema":"netlisp-system-review-v1","name":"demo","title":"Demo","part_number":"SYS-1","revision":"A",
        \\ "boards":[{"name":"board","role":"main","source":"src/board.sexp","part_number":"PCB-1","revision":"A"}],
        \\ "documents":[{"id":"release-checklist","title":"Release checklist","path":"src/systems/demo/release.md","classification":"checklist"}]}
        ,
    });
    const project = try tmp.dir.realPathFileAlloc(testing.io, "project", allocator);

    var out: std.ArrayList(u8) = .empty;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"system\":\"demo\"}", .{});
    try testing.expect(try convertTool(allocator, project, args, &out));
    var diagnostic: Diagnostic = .{};
    const spec = try parse(allocator, out.items, null, &diagnostic);
    try system_review.validateSystemSpec(allocator, spec, &diagnostic);
    try testing.expectEqualStrings("demo", spec.name);
    try testing.expectEqualStrings("src/board.sexp", spec.boards[0].source);
    // The conversion is read-only: no `system.sexp` appears beside the JSON.
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(testing.io, "project/src/systems/demo/system.sexp", .{}),
    );

    var missing: std.ArrayList(u8) = .empty;
    const absent = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"system\":\"nope\"}", .{});
    try testing.expect(!try convertTool(allocator, project, absent, &missing));
    try testing.expect(std.mem.indexOf(u8, missing.items, "\"ok\":false") != null);
}

// spec: system-review - contact identifiers compare numerically across the pinout's zero-padded spelling and the netlist's bare one
test "system sexp compares contact identifiers across pad spellings" {
    try testing.expect(sameContact("1", "01"));
    try testing.expect(sameContact("40", "40"));
    try testing.expect(sameContact("A1", "A1"));
    try testing.expect(!sameContact("1", "2"));
    try testing.expect(!sameContact("A1", "1"));
    try testing.expect(!sameContact("", "0"));
}

/// The reverse direction of the reference-table sync check, hoisted so the
/// test itself keeps one top-level loop. Returns the first documented form the
/// parser would not accept, so the assertion names it.
fn firstDocumentedFormNotAccepted() []const u8 {
    const forms = @import("eval/forms.zig");
    for (forms.system_form_docs) |row| {
        var known = false;
        for (accepted_forms) |name| {
            if (std.mem.eql(u8, name, row.name)) known = true;
        }
        if (!known) return row.name;
    }
    return "";
}

/// The forward direction: the first accepted head atom the generated reference
/// does not document.
fn firstUndocumentedForm() []const u8 {
    const forms = @import("eval/forms.zig");
    for (accepted_forms) |name| {
        if (!forms.isSubForm(forms.system_form_docs, name)) return name;
    }
    return "";
}

// spec: system-review - the generated language reference documents exactly the head atoms a (system …) source accepts, in both directions
test "system contract forms and their reference table cannot drift" {
    try testing.expectEqualStrings("", firstUndocumentedForm());
    try testing.expectEqualStrings("", firstDocumentedFormNotAccepted());
    // Every atom the parser rejects outright still reads as unknown rather
    // than as a silently ignored child.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.InvalidSystemSexp, parse(
        arena_state.allocator(),
        "(system \"x\" (title \"X\") (part-number \"P\") (revision \"A\") (mates \"a/b\" \"c/d\"))",
        null,
        &diagnostic,
    ));
    try testing.expectEqual(system_review.DiagnosticCode.unknown_sexp_form, diagnostic.code);
}

// spec: system-review - a contract source's (attestation …) is replaced, appended or dropped at its byte span, leaving every other byte, comment and blank line as authored
test "attestation edits touch only the attestation form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const authored =
        \\;; hand-written header comment
        \\(system "demo"
        \\  (title "Demo")          ; trailing comment
        \\  (part-number "D-1")
        \\  (revision "A")
        \\  (board "b" (role main) (source "src/b.sexp") (part-number "P") (revision "A"))
        \\  (document "release-checklist" (title "C")
        \\    (path "src/systems/demo/c.md") (classification checklist)))
        \\
    ;
    try testing.expect(!hasAttestation(allocator, authored));

    var rendered: std.Io.Writer.Allocating = .init(allocator);
    try writeAttestationForm(allocator, &rendered.writer, .{
        .system_lock_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .attested_by = "writer@example.com",
        .attested_at = "2026-01-02T03:04:05Z",
        .inputs = &.{},
        .documents = &.{},
    });
    const attested = (try withAttestation(allocator, authored, rendered.written())).?;

    // Everything the author wrote survives byte for byte, comments included.
    try testing.expect(std.mem.startsWith(u8, attested, ";; hand-written header comment\n"));
    try testing.expect(std.mem.indexOf(u8, attested, "(title \"Demo\")          ; trailing comment") != null);
    try testing.expect(hasAttestation(allocator, attested));

    // And the appended form is a real child of `(system …)`: the contract
    // re-parses, carrying the attestation the writer just approved.
    var diagnostic: Diagnostic = .{};
    const spec = try parse(allocator, attested, null, &diagnostic);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", spec.attestation.?.system_lock_sha256);
    try testing.expectEqualStrings("writer@example.com", spec.attestation.?.attested_by.?);

    // A second approval replaces the form in place rather than appending a
    // second one, which the parser refuses outright.
    var replacement: std.Io.Writer.Allocating = .init(allocator);
    try writeAttestationForm(allocator, &replacement.writer, .{
        .system_lock_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .inputs = &.{},
        .documents = &.{},
    });
    const reattested = (try withAttestation(allocator, attested, replacement.written())).?;
    const respec = try parse(allocator, reattested, null, &diagnostic);
    try testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", respec.attestation.?.system_lock_sha256);
    try testing.expect(std.mem.indexOf(u8, reattested, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") == null);

    // Invalidation restores the authored source exactly.
    try testing.expectEqualStrings(authored, (try withoutAttestation(allocator, reattested)).?);
    try testing.expect((try withoutAttestation(allocator, authored)) == null);

    // A parenthesis inside a quoted value cannot end the form early, so the
    // span that gets spliced is the whole attestation and nothing beyond it.
    const quoted =
        \\(system "demo" (title "Demo") (part-number "D-1") (revision "A")
        \\  (board "b" (role main) (source "src/b.sexp") (part-number "P") (revision "A"))
        \\  (attestation (system-lock "lock") (input "src/(nc 1).md" "hash"))
        \\  (document "d" (title "T") (path "src/systems/demo/d.md") (classification design)))
    ;
    const span = attestationSpan(allocator, quoted).?;
    try testing.expectEqualStrings(
        "(attestation (system-lock \"lock\") (input \"src/(nc 1).md\" \"hash\"))",
        quoted[span.start..span.end],
    );

    // A source with no (system …) form has nothing to attest into, and says so
    // rather than writing a manifest that would not load.
    try testing.expect((try withAttestation(allocator, "(design-block \"x\")", "(attestation)")) == null);
}

// spec: system-review - manifest discovery answers with the contract source when a workspace has one and the JSON manifest otherwise, and a workspace with neither is absent rather than empty
test "manifest discovery picks the contract source over the JSON beside it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "project/src/systems/demo");
    const project = try tmp.dir.realPathFileAlloc(testing.io, "project", allocator);

    try testing.expectError(error.FileNotFound, locate(allocator, project, "demo"));
    try testing.expectError(error.InvalidSystemName, locate(allocator, project, "../escape"));

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "project/src/systems/demo/system.json",
        .data = "{\"name\":\"demo\"}",
    });
    const json = try locate(allocator, project, "demo");
    try testing.expectEqual(ManifestKind.json, json.kind);
    try testing.expectEqualStrings("src/systems/demo/system.json", json.relative);
    try testing.expect(!json.shadowed_json);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "project/src/systems/demo/system.sexp",
        .data = "(system \"demo\")\n",
    });
    const sexp = try locate(allocator, project, "demo");
    try testing.expectEqual(ManifestKind.sexp, sexp.kind);
    try testing.expectEqualStrings("src/systems/demo/system.sexp", sexp.relative);
    try testing.expectEqualStrings("(system \"demo\")\n", sexp.source);
    try testing.expect(sexp.shadowed_json);
}

// spec: system-review - an identity-only parse drops an (auto) interface it has no evaluator for instead of refusing the contract, so a listing surface never pays a board evaluation per workspace
test "an identity-only parse omits the interfaces it cannot derive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\(system "twin"
        \\  (title "Twin") (part-number "T-1") (revision "A")
        \\  (board "a" (role rf) (source "src/a.sexp") (part-number "A") (revision "A"))
        \\  (board "b" (role base) (source "src/b.sexp") (part-number "B") (revision "A"))
        \\  (interface "link" (mates "a/J1" "b/J1") (auto))
        \\  (document "d" (title "T") (path "src/systems/twin/d.md") (classification design)))
    ;
    var diagnostic: Diagnostic = .{};
    // With no resolver, the full parse refuses rather than inventing contacts.
    try testing.expectError(error.InvalidSystemSexp, parse(allocator, source, null, &diagnostic));
    try testing.expectEqual(system_review.DiagnosticCode.unresolved_connector, diagnostic.code);

    const spec = try parseWith(allocator, source, .{ .omit_underivable_interfaces = true }, &diagnostic);
    try testing.expectEqualStrings("Twin", spec.title);
    try testing.expectEqual(@as(usize, 2), spec.boards.len);
    try testing.expectEqual(@as(usize, 1), spec.documents.len);
    try testing.expectEqual(@as(usize, 0), spec.interfaces.len);
}

const brief_source =
    \\(system "brief-system"
    \\  (title "Brief System")
    \\  (part-number "BRIEF-001")
    \\  (revision "A1")
    \\  (status review)
    \\  (brief
    \\    (purpose "Swept X-band source with a 50-1500 MHz IF output")
    \\    (environment (ambient -10 60) (cooling sealed-conduction) (altitude 2000) (ingress 40))
    \\    (input-power (source "12 V barrel") (voltage 11.4 12.6) (transient 15) (current-max 1.2))
    \\    (temperature-grade industrial)
    \\    (derating "NASA EEE-INST-002")
    \\    (ipc-class 2)
    \\    (compliance (esd "IEC 61000-4-2, 8 kV contact"))
    \\    (interface "OUT1" (connector sma) (impedance 50) (power-max 10)))
    \\  (goal "if-band" (title "IF output band") (unit MHz) (min 50) (max 1500) (verify-by frequency-plan))
    \\  (goal "max-ambient" (unit C) (min 60) (verify-by thermal))
    \\  (goal "phase-noise-10k" (unit "dBc/Hz") (max -95) (verify-by measurement "bring-up 4.3")
    \\    (measured -97.2 "bring-up 4.3, 2026-09-04"))
    \\  (board "rf"
    \\    (role rf)
    \\    (source "src/rf.sexp")
    \\    (part-number "SYS-RF")
    \\    (revision "A1"))
    \\  (document "release-checklist"
    \\    (title "Release checklist")
    \\    (path "src/systems/brief-system/release-checklist.md")
    \\    (classification checklist)))
;

// spec: system-review - a (system …) source parses (status …), a (brief …) and (goal …) rows into the same strict v1 spec the JSON manifest carries, and prints them back unchanged
test "a contract source carries its status, brief and goals through a round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: Diagnostic = .{};
    const spec = try parse(allocator, brief_source, null, &diagnostic);
    try system_review.validateSystemSpec(allocator, spec, &diagnostic);

    try testing.expectEqual(system_review.SystemStatus.review, spec.status);
    const brief = spec.brief.?;
    try testing.expectEqualStrings("Swept X-band source with a 50-1500 MHz IF output", brief.purpose);
    try testing.expectEqual(@as(f64, -10), brief.environment.?.ambient_min_c);
    try testing.expectEqual(@as(f64, 60), brief.environment.?.ambient_max_c);
    try testing.expectEqual(system_review.Cooling.@"sealed-conduction", brief.environment.?.cooling.?);
    try testing.expectEqual(@as(u16, 40), brief.environment.?.ingress.?);
    try testing.expectEqualStrings("12 V barrel", brief.input_power.?.source);
    try testing.expectEqual(@as(f64, 12.6), brief.input_power.?.voltage_max_v);
    try testing.expectEqual(@as(f64, 15), brief.input_power.?.transient_v.?);
    try testing.expectEqual(system_review.TemperatureGrade.industrial, brief.temperature_grade.?);
    try testing.expectEqual(@as(u8, 2), brief.ipc_class.?);
    try testing.expectEqualStrings("IEC 61000-4-2, 8 kV contact", brief.compliance.esd.?);
    try testing.expectEqualStrings("OUT1", brief.interfaces[0].name);
    try testing.expectEqual(@as(f64, 50), brief.interfaces[0].impedance_ohm.?);

    try testing.expectEqual(@as(usize, 3), spec.goals.len);
    try testing.expectEqualStrings("IF output band", spec.goals[0].title);
    try testing.expectEqual(system_review.VerifyBy.@"frequency-plan", spec.goals[0].verify_by);
    try testing.expectEqual(@as(f64, 1500), spec.goals[0].max.?);
    try testing.expectEqual(system_review.VerifyBy.thermal, spec.goals[1].verify_by);
    try testing.expect(spec.goals[1].max == null);
    try testing.expectEqualStrings("bring-up 4.3", spec.goals[2].reference.?);
    try testing.expectEqual(@as(f64, -97.2), spec.goals[2].measured.?.value);

    // Printing and re-parsing yields the identical canonical spec, so the
    // converter stays a migration rather than a rewrite.
    var printed: std.Io.Writer.Allocating = .init(allocator);
    try write(allocator, &printed.writer, spec);
    const again = try parse(allocator, printed.written(), null, &diagnostic);
    try system_review.validateSystemSpec(allocator, again, &diagnostic);
    const before = try system_review.canonicalSpecDigest(allocator, spec);
    const after = try system_review.canonicalSpecDigest(allocator, again);
    try testing.expectEqualStrings(&before, &after);

    // A brief clause the grammar does not know is named rather than ignored.
    const unknown = try std.fmt.allocPrint(allocator, "{s}", .{
        "(system \"x\" (title \"X\") (part-number \"P\") (revision \"A\") (status concept) (brief (humidity 95)))",
    });
    try testing.expectError(error.InvalidSystemSexp, parse(allocator, unknown, null, &diagnostic));
    try testing.expectEqual(system_review.DiagnosticCode.unknown_sexp_form, diagnostic.code);
    try testing.expectEqualStrings("humidity", diagnostic.value);
}

// spec: system-review - only a (status concept) system may declare zero boards; every other status keeps the at-least-one-board rule
test "a concept system may declare no boards and every other status may not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const concept =
        \\(system "sketch"
        \\  (title "Sketch") (part-number "SKETCH-1") (revision "-")
        \\  (status concept)
        \\  (brief (purpose "A product that does not exist yet"))
        \\  (goal "max-ambient" (unit C) (min 55) (verify-by thermal))
        \\  (document "release-checklist" (title "Release checklist")
        \\    (path "src/systems/sketch/release-checklist.md") (classification checklist)))
    ;
    const boardless = try parse(allocator, concept, null, &diagnostic);
    try system_review.validateSystemSpec(allocator, boardless, &diagnostic);
    try testing.expectEqual(@as(usize, 0), boardless.boards.len);
    try testing.expectEqual(system_review.SystemStatus.concept, boardless.status);

    const designed = try parse(allocator, try std.mem.replaceOwned(u8, allocator, concept, "(status concept)", "(status design)"), null, &diagnostic);
    try testing.expectError(error.InvalidManifest, system_review.validateSystemSpec(allocator, designed, &diagnostic));
    try testing.expectEqual(system_review.DiagnosticCode.empty_field, diagnostic.code);
    try testing.expectEqualStrings("boards", diagnostic.field);
}
