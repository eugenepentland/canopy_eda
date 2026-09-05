//! System-level design-review manifests and immutable content attestations.
//!
//! A board release is already locked to one evaluated design. A system review
//! adds the missing layer above it: which boards form the product, which exact
//! connector contacts join them, and which authored/generated documents belong
//! beside each fabrication archive. This module is deliberately pure. It owns
//! no filesystem, HTTP, CLI, evaluator, or package behavior; callers provide
//! manifest/document bytes and decide where the validated artifacts travel.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// The only manifest schema accepted by this module.
pub const schema_v1 = "netlisp-system-review-v1";
/// Maximum accepted manifest source size.
pub const max_manifest_bytes: usize = 1024 * 1024;
/// Maximum accepted project-relative path length.
pub const max_relative_path_bytes: usize = 4096;
/// Prefix for a generated Markdown region's opening marker.
pub const generated_region_open = "<!-- netlisp:generated ";
/// Complete marker that closes a generated Markdown region.
pub const generated_region_close = "<!-- /netlisp:generated -->";

const max_boards: usize = 64;
const max_interfaces: usize = 256;
const max_interface_contacts: usize = 4096;
const max_documents: usize = 512;
const max_attested_inputs: usize = 4096;

/// Whether parts marked do-not-populate are omitted or retained in outputs.
pub const DnpPolicy = enum { drop, keep };

/// Intended use of a review-package document.
pub const DocumentClassification = enum {
    design,
    review,
    checklist,
    bringup,
    manufacturing,
    reference,
};

/// Lifecycle state of a review-package document.
pub const DocumentStatus = enum { active, historical };

/// Generated section kinds supported by the v1 review package.
pub const GeneratedSection = enum {
    @"system-summary",
    @"board-summary",
    @"interface-matrix",
    @"validation-summary",
    @"release-status",
    @"bom-summary",
    @"drc-summary",
    @"checklist-summary",
    @"power-summary",
    @"thermal-summary",
    @"pll-summary",
    @"frequency-plan-summary",
    @"erc-summary",
    @"mechanical-summary",
    @"open-items",
    @"system-diagram",
};

/// One board participating in a system review.
pub const BoardMember = struct {
    /// Design lookup name, for example `barracuda-base`.
    name: []const u8,
    /// Human-authored system role, for example `base` or `rf`.
    role: []const u8,
    /// Project-relative design source.
    source: []const u8,
    part_number: []const u8,
    revision: []const u8,
    /// `blessed` means the board's starred/default release layout.
    layout: []const u8 = "blessed",
    dnp: DnpPolicy = .drop,
};

/// One stable connector endpoint in an interface contract.
pub const InterfaceEndpoint = struct {
    board: []const u8,
    /// Stable source identity (`J1` or `base-interface/J1`), never a mutable
    /// flattened ref-des.
    connector: []const u8,
};

/// One physical contact mapping between two interface endpoints.
pub const InterfaceSignal = struct {
    /// System-level semantic signal name. It may repeat across contacts (for
    /// example four V_12V contacts and many GND contacts).
    canonical: []const u8,
    left_pin: []const u8,
    left_net: []const u8,
    right_pin: []const u8,
    right_net: []const u8,
    required: bool = true,
};

/// An explicit board-local to system-canonical net-name mapping.
pub const InterfaceAlias = struct {
    board: []const u8,
    local: []const u8,
    canonical: []const u8,
};

/// Complete physical and semantic contract between two board connectors.
pub const InterfaceContract = struct {
    id: []const u8,
    left: InterfaceEndpoint,
    right: InterfaceEndpoint,
    /// Physical contact count. `signals` must carry exactly this many records,
    /// including NC and repeated ground/power contacts.
    contact_count: usize,
    signals: []const InterfaceSignal,
    aliases: []const InterfaceAlias = &.{},
};

/// One authored document included in a system review package.
pub const DocumentSpec = struct {
    id: []const u8,
    title: []const u8,
    path: []const u8,
    classification: DocumentClassification,
    status: DocumentStatus = .active,
    /// Null means system-wide; otherwise names one `boards[]` member.
    board: ?[]const u8 = null,
    required: bool = true,
    include_in_fab: bool = true,
    /// IDs of generated regions expected in the Markdown source. Each region
    /// uses `<!-- netlisp:generated <id> -->` and the shared close marker.
    generated_sections: []const []const u8 = &.{},
};

/// Counts extracted from CommonMark task-list items.
pub const ChecklistSummary = struct {
    total: usize = 0,
    complete: usize = 0,
    open: usize = 0,

    /// True when the checklist is nonempty and contains no open tasks.
    pub fn allComplete(self: ChecklistSummary) bool {
        return self.total > 0 and self.open == 0;
    }
};

/// Hash attestation for a project-relative source input.
pub const InputAttestation = struct {
    path: []const u8,
    sha256: []const u8,
};

/// Hash and checklist attestation for one declared review document.
pub const DocumentAttestation = struct {
    id: []const u8,
    path: []const u8,
    sha256: []const u8,
    checklist: ChecklistSummary = .{},
};

/// Immutable content evidence attached to an exported system snapshot.
pub const Attestation = struct {
    /// Canonical digest over the manifest (excluding this attestation), sorted
    /// input hashes, and sorted document hashes/checklist counts.
    system_lock_sha256: []const u8,
    /// Authenticated user identity that approved the stored attestation.
    attested_by: ?[]const u8 = null,
    /// UTC timestamp in `YYYY-MM-DDTHH:MM:SSZ` form.
    attested_at: ?[]const u8 = null,
    inputs: []const InputAttestation,
    documents: []const DocumentAttestation,
};

/// Strict v1 system review manifest.
pub const SystemSpec = struct {
    schema: []const u8,
    name: []const u8,
    title: []const u8,
    /// Stable system assembly identity, independent of the human title.
    part_number: []const u8,
    revision: []const u8,
    boards: []const BoardMember,
    interfaces: []const InterfaceContract = &.{},
    documents: []const DocumentSpec = &.{},
    /// Normally absent from the authored manifest and attached to an exported
    /// snapshot. When present it is checked as strictly as the authored data.
    attestation: ?Attestation = null,
};

/// Evaluated net observed at one physical connector contact.
pub const ContactObservation = struct {
    pin: []const u8,
    net: []const u8,
};

/// Evaluated contacts for one stable board connector endpoint.
pub const InterfaceObservation = struct {
    board: []const u8,
    connector: []const u8,
    contacts: []const ContactObservation,
};

/// Hash and structural facts extracted from one review document.
pub const DocumentContent = struct {
    sha256: [64]u8,
    checklist: ChecklistSummary,
    generated_regions: usize,
};

/// Machine-readable category for a system-review validation failure.
pub const DiagnosticCode = enum {
    none,
    manifest_too_large,
    invalid_json,
    unsupported_schema,
    empty_field,
    invalid_identifier,
    unsafe_path,
    collection_too_large,
    duplicate_board,
    duplicate_board_role,
    unknown_board,
    duplicate_interface,
    invalid_interface,
    incomplete_interface,
    duplicate_pin,
    duplicate_alias,
    missing_alias,
    invalid_alias,
    duplicate_document,
    unsupported_document_type,
    unknown_document_board,
    missing_required_checklist,
    duplicate_generated_section,
    unknown_generated_section,
    invalid_sha256,
    duplicate_attestation_input,
    duplicate_document_attestation,
    missing_attestation_input,
    missing_document_attestation,
    unknown_document_attestation,
    attestation_path_mismatch,
    invalid_attestation_identity,
    invalid_attestation_timestamp,
    missing_attestation_identity,
    missing_attestation_timestamp,
    system_lock_mismatch,
    missing_interface_observation,
    duplicate_observed_pin,
    interface_net_mismatch,
    undeclared_generated_region,
    duplicate_generated_region,
    nested_generated_region,
    orphan_generated_region_close,
    unclosed_generated_region,
    missing_generated_region,
    empty_checklist,
    incomplete_checklist,
    // `(system …)` source failures. The sexp manifest produces the identical
    // in-memory spec, so it shares this diagnostic — only its syntax-level
    // rejections need codes of their own.
    invalid_sexp,
    unknown_sexp_form,
    missing_sexp_field,
    duplicate_sexp_field,
    invalid_sexp_value,
    unresolved_connector,
    unknown_contact,
};

/// Structured, allocation-free diagnostic. `field` and `message` are stable
/// literals; `value` points into the parsed manifest/content supplied by the
/// caller (or is a static error name for JSON syntax failures).
pub const Diagnostic = struct {
    code: DiagnosticCode = .none,
    field: []const u8 = "",
    message: []const u8 = "",
    value: []const u8 = "",

    /// Reset the diagnostic before a new operation.
    pub fn clear(self: *Diagnostic) void {
        self.* = .{};
    }

    fn set(
        self: *Diagnostic,
        code: DiagnosticCode,
        field: []const u8,
        message: []const u8,
        value: []const u8,
    ) void {
        self.* = .{ .code = code, .field = field, .message = message, .value = value };
    }
};

/// Allocator-owned result of strict JSON parsing.
pub const ParsedSystemSpec = std.json.Parsed(SystemSpec);
/// Errors returned while parsing and semantically validating a manifest.
pub const ParseError = std.mem.Allocator.Error || error{
    ManifestTooLarge,
    InvalidJson,
    InvalidManifest,
};
/// Errors returned while semantically validating decoded review data.
pub const ValidationError = std.mem.Allocator.Error || error{InvalidManifest};
/// Errors returned while inspecting a declared document's content.
pub const DocumentError = std.mem.Allocator.Error || error{InvalidDocument};
/// Errors returned while constructing an input content attestation.
pub const AttestInputError = std.mem.Allocator.Error || error{UnsafePath};
/// Errors returned while serializing a deterministic attestation object.
pub const AttestationWriteError = std.mem.Allocator.Error || std.Io.Writer.Error;
/// Errors returned while serializing a typed system manifest.
pub const SystemSpecWriteError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Parse one strict v1 manifest. Unknown JSON fields, duplicate fields, wrong
/// types, and malformed enums are rejected by the typed JSON parser; semantic
/// and cross-reference failures return `InvalidManifest` with `diagnostic` set.
/// The caller must call `deinit` on the returned `ParsedSystemSpec`.
pub fn parseSystemSpec(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostic: *Diagnostic,
) ParseError!ParsedSystemSpec {
    diagnostic.clear();
    if (source.len > max_manifest_bytes) {
        diagnostic.set(.manifest_too_large, "manifest", "system manifest exceeds the 1 MiB input limit", "");
        return error.ManifestTooLarge;
    }
    var parsed = std.json.parseFromSlice(SystemSpec, allocator, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch |err| {
        diagnostic.set(.invalid_json, "manifest", "invalid or non-conforming system-review JSON", @errorName(err));
        return error.InvalidJson;
    };
    errdefer parsed.deinit();
    try validateSystemSpec(allocator, parsed.value, diagnostic);
    return parsed;
}

/// Validate an already-decoded manifest, including optional attestation.
pub fn validateSystemSpec(
    allocator: std.mem.Allocator,
    spec: SystemSpec,
    diagnostic: *Diagnostic,
) ValidationError!void {
    diagnostic.clear();
    try validateSystemFields(spec, diagnostic);
    try validateBoards(spec, diagnostic);
    try validateInterfaces(allocator, spec, diagnostic);
    try validateDocuments(spec, diagnostic);
    if (spec.attestation) |attestation| try validateAttestation(allocator, spec, attestation, diagnostic);
}

fn validateSystemFields(spec: SystemSpec, diagnostic: *Diagnostic) error{InvalidManifest}!void {
    if (!std.mem.eql(u8, spec.schema, schema_v1))
        return invalid(diagnostic, .unsupported_schema, "schema", "expected netlisp-system-review-v1", spec.schema);
    if (!isSimpleId(spec.name))
        return invalid(diagnostic, .invalid_identifier, "name", "system name must be a non-empty portable identifier", spec.name);
    if (!isBoundedPlainText(spec.title))
        return invalid(diagnostic, .empty_field, "title", "system title must be bounded printable text", spec.title);
    if (!isBoundedPlainText(spec.part_number))
        return invalid(diagnostic, .empty_field, "part_number", "system part number must be bounded printable text", spec.part_number);
    if (!isBoundedPlainText(spec.revision))
        return invalid(diagnostic, .empty_field, "revision", "system revision must be bounded printable text", spec.revision);
    if (spec.boards.len == 0)
        return invalid(diagnostic, .empty_field, "boards", "a system must declare at least one board", "");
    if (spec.boards.len > max_boards)
        return invalid(diagnostic, .collection_too_large, "boards", "system declares more than 64 boards", "");
    if (spec.interfaces.len > max_interfaces)
        return invalid(diagnostic, .collection_too_large, "interfaces", "system declares more than 256 interfaces", "");
    if (spec.documents.len > max_documents)
        return invalid(diagnostic, .collection_too_large, "documents", "system declares more than 512 documents", "");
}

fn validateBoards(spec: SystemSpec, diagnostic: *Diagnostic) error{InvalidManifest}!void {
    for (spec.boards, 0..) |board, index| {
        if (!isSimpleId(board.name))
            return invalid(diagnostic, .invalid_identifier, "boards[].name", "board name must be a portable design identifier", board.name);
        if (!isSimpleId(board.role))
            return invalid(diagnostic, .invalid_identifier, "boards[].role", "board role must be a portable identifier", board.role);
        if (!isSafeRelativePath(board.source))
            return invalid(diagnostic, .unsafe_path, "boards[].source", "board source must be a normalized project-relative path", board.source);
        if (!isBoundedPlainText(board.part_number))
            return invalid(diagnostic, .empty_field, "boards[].part_number", "board part number must be bounded printable text", board.name);
        if (!isBoundedPlainText(board.revision))
            return invalid(diagnostic, .empty_field, "boards[].revision", "board revision must be bounded printable text", board.name);
        if (!isBoundedPlainText(board.layout))
            return invalid(diagnostic, .empty_field, "boards[].layout", "layout name must be bounded printable text", board.layout);
        for (spec.boards[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, board.name))
                return invalid(diagnostic, .duplicate_board, "boards[].name", "board names must be unique", board.name);
            if (std.mem.eql(u8, earlier.role, board.role))
                return invalid(diagnostic, .duplicate_board_role, "boards[].role", "board roles must be unique archive identities", board.role);
        }
    }
}

fn validateInterfaces(
    allocator: std.mem.Allocator,
    spec: SystemSpec,
    diagnostic: *Diagnostic,
) ValidationError!void {
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    defer ids.deinit(allocator);
    for (spec.interfaces) |interface| {
        if (!isSimpleId(interface.id))
            return invalid(diagnostic, .invalid_identifier, "interfaces[].id", "interface id must be a portable identifier", interface.id);
        const id = try ids.getOrPut(allocator, interface.id);
        if (id.found_existing)
            return invalid(diagnostic, .duplicate_interface, "interfaces[].id", "interface ids must be unique", interface.id);
        try validateInterfaceEndpoints(spec, interface, diagnostic);
        try validateInterfaceSignals(allocator, interface, diagnostic);
        try validateInterfaceAliases(allocator, interface, diagnostic);
    }
}

fn validateInterfaceEndpoints(
    spec: SystemSpec,
    interface: InterfaceContract,
    diagnostic: *Diagnostic,
) error{InvalidManifest}!void {
    if (!hasBoard(spec, interface.left.board))
        return invalid(diagnostic, .unknown_board, "interfaces[].left.board", "left endpoint names no system board", interface.left.board);
    if (!hasBoard(spec, interface.right.board))
        return invalid(diagnostic, .unknown_board, "interfaces[].right.board", "right endpoint names no system board", interface.right.board);
    if (std.mem.eql(u8, interface.left.board, interface.right.board))
        return invalid(diagnostic, .invalid_interface, "interfaces[]", "system interface endpoints must belong to different boards", interface.id);
    if (!isStableHandle(interface.left.connector))
        return invalid(diagnostic, .invalid_identifier, "interfaces[].left.connector", "connector must use a stable source handle such as J1 or block/J1", interface.left.connector);
    if (!isStableHandle(interface.right.connector))
        return invalid(diagnostic, .invalid_identifier, "interfaces[].right.connector", "connector must use a stable source handle such as J1 or block/J1", interface.right.connector);
}

fn validateInterfaceSignals(
    allocator: std.mem.Allocator,
    interface: InterfaceContract,
    diagnostic: *Diagnostic,
) ValidationError!void {
    if (interface.contact_count == 0 or interface.contact_count > max_interface_contacts)
        return invalid(diagnostic, .invalid_interface, "interfaces[].contact_count", "contact_count must be between 1 and 4096", interface.id);
    if (interface.signals.len != interface.contact_count)
        return invalid(diagnostic, .incomplete_interface, "interfaces[].signals", "signals must contain exactly one record per physical contact", interface.id);
    var left_pins: std.StringHashMapUnmanaged(void) = .empty;
    defer left_pins.deinit(allocator);
    var right_pins: std.StringHashMapUnmanaged(void) = .empty;
    defer right_pins.deinit(allocator);
    for (interface.signals) |signal| {
        if (!isPlainText(signal.canonical))
            return invalid(diagnostic, .empty_field, "interfaces[].signals[].canonical", "canonical net name must be non-empty printable text", interface.id);
        if (!isPlainText(signal.left_net))
            return invalid(diagnostic, .empty_field, "interfaces[].signals[].left_net", "left net name must be non-empty printable text", interface.id);
        if (!isPlainText(signal.right_net))
            return invalid(diagnostic, .empty_field, "interfaces[].signals[]", "canonical and endpoint net names must be non-empty printable text", interface.id);
        if (!isPinName(signal.left_pin) or !isPinName(signal.right_pin))
            return invalid(diagnostic, .invalid_identifier, "interfaces[].signals[].*_pin", "contact pin names must be non-empty printable tokens", interface.id);
        if ((try left_pins.getOrPut(allocator, signal.left_pin)).found_existing)
            return invalid(diagnostic, .duplicate_pin, "interfaces[].signals[].left_pin", "left connector pin appears more than once", signal.left_pin);
        if ((try right_pins.getOrPut(allocator, signal.right_pin)).found_existing)
            return invalid(diagnostic, .duplicate_pin, "interfaces[].signals[].right_pin", "right connector pin appears more than once", signal.right_pin);
    }
}

fn validateInterfaceAliases(
    allocator: std.mem.Allocator,
    interface: InterfaceContract,
    diagnostic: *Diagnostic,
) ValidationError!void {
    if (interface.aliases.len > max_interface_contacts)
        return invalid(diagnostic, .collection_too_large, "interfaces[].aliases", "interface declares more than 4096 aliases", interface.id);
    var left_aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer left_aliases.deinit(allocator);
    var right_aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer right_aliases.deinit(allocator);
    for (interface.aliases) |alias| {
        const is_left = std.mem.eql(u8, alias.board, interface.left.board);
        const is_right = std.mem.eql(u8, alias.board, interface.right.board);
        if (!is_left and !is_right)
            return invalid(diagnostic, .invalid_alias, "interfaces[].aliases[].board", "alias board must be one of the interface endpoints", alias.board);
        if (!isPlainText(alias.local) or !isPlainText(alias.canonical))
            return invalid(diagnostic, .invalid_alias, "interfaces[].aliases[]", "alias local and canonical names must not be empty", interface.id);
        const aliases = if (is_left) &left_aliases else &right_aliases;
        const entry = try aliases.getOrPut(allocator, alias.local);
        if (entry.found_existing)
            return invalid(diagnostic, .duplicate_alias, "interfaces[].aliases[]", "a board-local net may have only one canonical alias", alias.local);
        entry.value_ptr.* = alias.canonical;
    }

    var used_left: std.StringHashMapUnmanaged(void) = .empty;
    defer used_left.deinit(allocator);
    var used_right: std.StringHashMapUnmanaged(void) = .empty;
    defer used_right.deinit(allocator);
    for (interface.signals) |signal| {
        if (left_aliases.get(signal.left_net)) |canonical| {
            if (std.mem.eql(u8, canonical, signal.canonical)) try used_left.put(allocator, signal.left_net, {});
        }
        if (right_aliases.get(signal.right_net)) |canonical| {
            if (std.mem.eql(u8, canonical, signal.canonical)) try used_right.put(allocator, signal.right_net, {});
        }
    }
    for (interface.aliases) |alias| {
        const used = if (std.mem.eql(u8, alias.board, interface.left.board))
            used_left.contains(alias.local)
        else
            used_right.contains(alias.local);
        if (!used)
            return invalid(diagnostic, .invalid_alias, "interfaces[].aliases[]", "alias does not describe any signal record on that endpoint", alias.local);
    }
    for (interface.signals) |signal| {
        if (!std.mem.eql(u8, signal.left_net, signal.canonical) and !aliasMatches(left_aliases, signal.left_net, signal.canonical))
            return invalid(diagnostic, .missing_alias, "interfaces[].aliases", "left local net differs from canonical but has no explicit alias", signal.left_net);
        if (!std.mem.eql(u8, signal.right_net, signal.canonical) and !aliasMatches(right_aliases, signal.right_net, signal.canonical))
            return invalid(diagnostic, .missing_alias, "interfaces[].aliases", "right local net differs from canonical but has no explicit alias", signal.right_net);
    }
}

fn aliasMatches(
    aliases: std.StringHashMapUnmanaged([]const u8),
    local: []const u8,
    canonical: []const u8,
) bool {
    const mapped = aliases.get(local) orelse return false;
    return std.mem.eql(u8, mapped, canonical);
}

fn validateDocuments(spec: SystemSpec, diagnostic: *Diagnostic) error{InvalidManifest}!void {
    var has_required_checklist = false;
    for (spec.documents, 0..) |document, index| {
        if (!isSimpleId(document.id))
            return invalid(diagnostic, .invalid_identifier, "documents[].id", "document id must be a portable identifier", document.id);
        if (!isBoundedPlainText(document.title))
            return invalid(diagnostic, .empty_field, "documents[].title", "document title must be bounded printable text", document.id);
        if (!isSafeRelativePath(document.path))
            return invalid(diagnostic, .unsafe_path, "documents[].path", "document path must be normalized and project-relative", document.path);
        if (!std.ascii.endsWithIgnoreCase(document.path, ".md"))
            return invalid(diagnostic, .unsupported_document_type, "documents[].path", "review documents must be Markdown; attach binary and tabular evidence under the system assets directory", document.path);
        if (document.board) |board| if (!hasBoard(spec, board))
            return invalid(diagnostic, .unknown_document_board, "documents[].board", "document scope names no system board", board);
        if (document.status == .active and document.required and document.classification == .checklist)
            has_required_checklist = true;
        for (spec.documents[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, document.id))
                return invalid(diagnostic, .duplicate_document, "documents[].id", "document ids must be unique", document.id);
            if (std.mem.eql(u8, earlier.path, document.path))
                return invalid(diagnostic, .duplicate_document, "documents[].path", "each document path may be declared only once", document.path);
        }
        try validateGeneratedSections(document, diagnostic);
    }
    if (!has_required_checklist)
        return invalid(diagnostic, .missing_required_checklist, "documents", "a system release requires at least one active required checklist", "");
}

fn validateGeneratedSections(
    document: DocumentSpec,
    diagnostic: *Diagnostic,
) error{InvalidManifest}!void {
    if (document.generated_sections.len > @typeInfo(GeneratedSection).@"enum".field_names.len)
        return invalid(diagnostic, .collection_too_large, "documents[].generated_sections", "document declares too many generated sections", document.id);
    for (document.generated_sections, 0..) |section, index| {
        if (generatedSection(section) == null)
            return invalid(diagnostic, .unknown_generated_section, "documents[].generated_sections[]", "generated section id is not supported", section);
        for (document.generated_sections[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, section))
                return invalid(diagnostic, .duplicate_generated_section, "documents[].generated_sections[]", "generated section ids must be unique per document", section);
        }
    }
}

/// Check a project-relative path without consulting the filesystem. Accepted
/// paths use `/`, contain no empty/`.`/`..` segment, control byte, Windows
/// drive prefix, or leading separator.
pub fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_relative_path_bytes) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return false;
    for (path) |byte| if (byte == '\\' or byte < 0x20 or byte == 0x7f) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

/// Resolve a supported generated-region id.
pub fn generatedSection(id: []const u8) ?GeneratedSection {
    return std.meta.stringToEnum(GeneratedSection, id);
}

/// Validate evaluated connector observations against every declared contact.
/// Observations use stable endpoint handles and must contain neither missing
/// nor extra contacts; every observed net must equal the endpoint-local name
/// recorded in the manifest.
pub fn validateInterfaceCompleteness(
    spec: SystemSpec,
    observations: []const InterfaceObservation,
    diagnostic: *Diagnostic,
) error{InvalidManifest}!void {
    diagnostic.clear();
    for (spec.interfaces) |interface| {
        const left = findObservation(observations, interface.left) orelse
            return invalid(diagnostic, .missing_interface_observation, "interfaces[].left", "no evaluated connector observation matches the left endpoint", interface.id);
        const right = findObservation(observations, interface.right) orelse
            return invalid(diagnostic, .missing_interface_observation, "interfaces[].right", "no evaluated connector observation matches the right endpoint", interface.id);
        try validateObservedEndpoint(interface, true, left, diagnostic);
        try validateObservedEndpoint(interface, false, right, diagnostic);
    }
}

fn findObservation(
    observations: []const InterfaceObservation,
    endpoint: InterfaceEndpoint,
) ?InterfaceObservation {
    for (observations) |observation| {
        if (std.mem.eql(u8, observation.board, endpoint.board) and
            std.mem.eql(u8, observation.connector, endpoint.connector)) return observation;
    }
    return null;
}

fn validateObservedEndpoint(
    interface: InterfaceContract,
    left: bool,
    observation: InterfaceObservation,
    diagnostic: *Diagnostic,
) error{InvalidManifest}!void {
    if (observation.contacts.len != interface.contact_count)
        return invalid(diagnostic, .incomplete_interface, "interface observation", "observed connector contact count does not match the contract", observation.connector);
    for (observation.contacts, 0..) |contact, index| {
        for (observation.contacts[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.pin, contact.pin))
                return invalid(diagnostic, .duplicate_observed_pin, "interface observation", "observed connector pin appears more than once", contact.pin);
        }
    }
    for (interface.signals) |signal| {
        const pin = if (left) signal.left_pin else signal.right_pin;
        const expected = if (left) signal.left_net else signal.right_net;
        const contact = findObservedContact(observation.contacts, pin) orelse
            return invalid(diagnostic, .incomplete_interface, "interface observation", "declared connector pin is absent from the evaluated observation", pin);
        if (!std.mem.eql(u8, contact.net, expected))
            return invalid(diagnostic, .interface_net_mismatch, "interface observation", "observed connector net differs from the declared endpoint-local net", pin);
    }
}

fn findObservedContact(contacts: []const ContactObservation, pin: []const u8) ?ContactObservation {
    for (contacts) |contact| if (std.mem.eql(u8, contact.pin, pin)) return contact;
    return null;
}

/// Hash and inspect one Markdown document. Generated-region markers are
/// validated against `spec.generated_sections`; checklist documents must
/// contain at least one CommonMark task item (`- [ ]` / `- [x]`).
pub fn inspectDocumentContent(
    spec: DocumentSpec,
    content: []const u8,
    diagnostic: *Diagnostic,
) DocumentError!DocumentContent {
    diagnostic.clear();
    var seen: [@typeInfo(GeneratedSection).@"enum".field_names.len]bool = @splat(false);
    var active: ?GeneratedSection = null;
    var regions: usize = 0;
    var checklist: ChecklistSummary = .{};
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (active != null) {
            if (std.mem.eql(u8, line, generated_region_close)) {
                active = null;
                continue;
            }
            if (generatedMarkerId(line)) |id|
                return invalidDocument(diagnostic, .nested_generated_region, "document", "generated regions may not nest", id);
            continue;
        }
        if (in_fence) {
            if (std.mem.eql(u8, line, "```")) in_fence = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "```")) {
            in_fence = true;
            continue;
        }
        if (std.mem.eql(u8, line, generated_region_close)) {
            return invalidDocument(diagnostic, .orphan_generated_region_close, "document", "generated-region close marker has no open region", spec.id);
        }
        if (generatedMarkerId(line)) |id| {
            const section = generatedSection(id) orelse
                return invalidDocument(diagnostic, .unknown_generated_section, "document", "document contains an unsupported generated-region id", id);
            if (!declaresGeneratedSection(spec, id))
                return invalidDocument(diagnostic, .undeclared_generated_region, "document", "generated region is not declared by this document spec", id);
            const section_index = @backingInt(section);
            if (seen[section_index])
                return invalidDocument(diagnostic, .duplicate_generated_region, "document", "generated region appears more than once", id);
            seen[section_index] = true;
            active = section;
            regions += 1;
            continue;
        }
        countChecklistLine(line, &checklist);
    }
    if (active) |section|
        return invalidDocument(diagnostic, .unclosed_generated_region, "document", "generated region has no close marker", @tagName(section));
    for (spec.generated_sections) |id| {
        const section = generatedSection(id) orelse continue;
        if (!seen[@backingInt(section)])
            return invalidDocument(diagnostic, .missing_generated_region, "document", "declared generated region is absent from the document", id);
    }
    if (spec.classification == .checklist and checklist.total == 0)
        return invalidDocument(diagnostic, .empty_checklist, "document", "checklist document contains no Markdown task items", spec.id);
    return .{
        .sha256 = sha256Hex(content),
        .checklist = checklist,
        .generated_regions = regions,
    };
}

fn generatedMarkerId(line: []const u8) ?[]const u8 {
    const suffix = " -->";
    if (!std.mem.startsWith(u8, line, generated_region_open) or !std.mem.endsWith(u8, line, suffix)) return null;
    const id = line[generated_region_open.len .. line.len - suffix.len];
    if (id.len == 0 or std.mem.indexOfAny(u8, id, " \t\r\n") != null) return null;
    return id;
}

fn declaresGeneratedSection(spec: DocumentSpec, id: []const u8) bool {
    for (spec.generated_sections) |declared| if (std.mem.eql(u8, declared, id)) return true;
    return false;
}

fn countChecklistLine(line: []const u8, summary: *ChecklistSummary) void {
    if (line.len < 5) return;
    if (line[0] != '-' and line[0] != '*' and line[0] != '+') return;
    if (line[1] != ' ' or line[2] != '[' or line[4] != ']') return;
    switch (line[3]) {
        ' ' => {
            summary.total += 1;
            summary.open += 1;
        },
        'x', 'X' => {
            summary.total += 1;
            summary.complete += 1;
        },
        else => {},
    }
}

/// SHA-256 as lowercase hex, matching fabrication-release reports.
pub fn sha256Hex(content: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = @splat(0);
    Sha256.hash(content, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Create a hash record for any project-relative release input. Returned path
/// borrows the caller's slice; only the hex digest is allocated.
pub fn attestInput(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    diagnostic: *Diagnostic,
) AttestInputError!InputAttestation {
    diagnostic.clear();
    if (!isSafeRelativePath(path)) {
        diagnostic.set(.unsafe_path, "attestation.inputs[].path", "attested input path must be normalized and project-relative", path);
        return error.UnsafePath;
    }
    const digest = sha256Hex(content);
    return .{ .path = path, .sha256 = try allocator.dupe(u8, &digest) };
}

/// Inspect and attest one document. Returned id/path borrow `spec`; the digest
/// allocation belongs to `allocator`.
pub fn attestDocument(
    allocator: std.mem.Allocator,
    spec: DocumentSpec,
    content: []const u8,
    diagnostic: *Diagnostic,
) DocumentError!DocumentAttestation {
    const inspected = try inspectDocumentContent(spec, content, diagnostic);
    return .{
        .id = spec.id,
        .path = spec.path,
        .sha256 = try allocator.dupe(u8, &inspected.sha256),
        .checklist = inspected.checklist,
    };
}

/// Canonical manifest digest. Collection order does not affect it: boards,
/// interfaces, per-contact mappings, aliases, documents, and generated section
/// IDs are copied and sorted before hashing. The optional attestation is
/// intentionally excluded to avoid a self-referential lock.
pub fn canonicalSpecDigest(
    allocator: std.mem.Allocator,
    spec: SystemSpec,
) std.mem.Allocator.Error![64]u8 {
    var hash = Sha256.init(.{});
    try hashCanonicalSpec(allocator, &hash, spec);
    return finishHex(&hash);
}

/// Digest the canonical manifest plus sorted input/document attestations.
pub fn systemLockDigest(
    allocator: std.mem.Allocator,
    spec: SystemSpec,
    inputs: []const InputAttestation,
    documents: []const DocumentAttestation,
) std.mem.Allocator.Error![64]u8 {
    var hash = Sha256.init(.{});
    hashField(&hash, "netlisp-system-review-lock-v1");
    const spec_digest = try canonicalSpecDigest(allocator, spec);
    hashField(&hash, &spec_digest);

    const sorted_inputs = try allocator.dupe(InputAttestation, inputs);
    defer allocator.free(sorted_inputs);
    std.mem.sort(InputAttestation, sorted_inputs, {}, lessInputAttestation);
    hashCount(&hash, sorted_inputs.len);
    for (sorted_inputs) |input| {
        hashField(&hash, input.path);
        hashField(&hash, input.sha256);
    }

    const sorted_documents = try allocator.dupe(DocumentAttestation, documents);
    defer allocator.free(sorted_documents);
    std.mem.sort(DocumentAttestation, sorted_documents, {}, lessDocumentAttestation);
    hashCount(&hash, sorted_documents.len);
    for (sorted_documents) |document| {
        hashField(&hash, document.id);
        hashField(&hash, document.path);
        hashField(&hash, document.sha256);
        hashCount(&hash, document.checklist.total);
        hashCount(&hash, document.checklist.complete);
        hashCount(&hash, document.checklist.open);
    }
    return finishHex(&hash);
}

/// Construct the generated/export-time attestation wrapper. Slices borrow the
/// supplied records; the system-lock hex allocation belongs to `allocator`.
pub fn makeAttestation(
    allocator: std.mem.Allocator,
    spec: SystemSpec,
    inputs: []const InputAttestation,
    documents: []const DocumentAttestation,
) std.mem.Allocator.Error!Attestation {
    const digest = try systemLockDigest(allocator, spec, inputs, documents);
    return .{
        .system_lock_sha256 = try allocator.dupe(u8, &digest),
        .inputs = inputs,
        .documents = documents,
    };
}

/// Serialize only the top-level `attestation` object in stable field and
/// collection order. This is suitable for an atomic manifest-field update;
/// it deliberately emits neither a surrounding manifest nor a trailing
/// newline.
pub fn writeAttestationJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    attestation: Attestation,
) AttestationWriteError!void {
    const sorted_inputs = try allocator.dupe(InputAttestation, attestation.inputs);
    defer allocator.free(sorted_inputs);
    std.mem.sort(InputAttestation, sorted_inputs, {}, lessInputAttestation);

    const sorted_documents = try allocator.dupe(DocumentAttestation, attestation.documents);
    defer allocator.free(sorted_documents);
    std.mem.sort(DocumentAttestation, sorted_documents, {}, lessDocumentAttestation);

    var normalized = attestation;
    normalized.inputs = sorted_inputs;
    normalized.documents = sorted_documents;
    try std.json.Stringify.value(normalized, .{ .emit_null_optional_fields = false }, writer);
}

/// Serialize a complete typed manifest as stable, two-space-indented JSON.
/// Array order authored for boards, interfaces, contacts, and documents is
/// retained. Attestation inputs/documents are sorted because their order has
/// no meaning. A single trailing newline is emitted.
pub fn writeSystemSpecJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    spec: SystemSpec,
) SystemSpecWriteError!void {
    var normalized_spec = spec;
    if (spec.attestation) |attestation| {
        const sorted_inputs = try allocator.dupe(InputAttestation, attestation.inputs);
        defer allocator.free(sorted_inputs);
        std.mem.sort(InputAttestation, sorted_inputs, {}, lessInputAttestation);

        const sorted_documents = try allocator.dupe(DocumentAttestation, attestation.documents);
        defer allocator.free(sorted_documents);
        std.mem.sort(DocumentAttestation, sorted_documents, {}, lessDocumentAttestation);

        var normalized_attestation = attestation;
        normalized_attestation.inputs = sorted_inputs;
        normalized_attestation.documents = sorted_documents;
        normalized_spec.attestation = normalized_attestation;
        try std.json.Stringify.value(normalized_spec, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        }, writer);
    } else {
        try std.json.Stringify.value(normalized_spec, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        }, writer);
    }
    try writer.writeByte('\n');
}

/// Validate attested paths/hashes, required coverage, optional metadata, and
/// the canonical lock. Authenticated identity and time are allowed to be
/// absent so authored manifests and pre-release drafts remain parseable.
pub fn validateAttestation(
    allocator: std.mem.Allocator,
    spec: SystemSpec,
    attestation: Attestation,
    diagnostic: *Diagnostic,
) ValidationError!void {
    diagnostic.clear();
    try validateAttestationMetadata(attestation, false, diagnostic);
    if (!isSha256Hex(attestation.system_lock_sha256))
        return invalid(diagnostic, .invalid_sha256, "attestation.system_lock_sha256", "system lock must be 64 lowercase hexadecimal characters", attestation.system_lock_sha256);
    if (attestation.inputs.len > max_attested_inputs)
        return invalid(diagnostic, .collection_too_large, "attestation.inputs", "attestation contains more than 4096 input records", "");
    if (attestation.documents.len > max_documents)
        return invalid(diagnostic, .collection_too_large, "attestation.documents", "attestation contains more than 512 document records", "");
    var input_paths: std.StringHashMapUnmanaged(void) = .empty;
    defer input_paths.deinit(allocator);
    for (attestation.inputs) |input| {
        if (!isSafeRelativePath(input.path))
            return invalid(diagnostic, .unsafe_path, "attestation.inputs[].path", "attested input path must be normalized and project-relative", input.path);
        if (!isSha256Hex(input.sha256))
            return invalid(diagnostic, .invalid_sha256, "attestation.inputs[].sha256", "input hash must be 64 lowercase hexadecimal characters", input.path);
        if ((try input_paths.getOrPut(allocator, input.path)).found_existing)
            return invalid(diagnostic, .duplicate_attestation_input, "attestation.inputs[].path", "an input path may be attested only once", input.path);
    }
    for (spec.boards) |board| if (!input_paths.contains(board.source))
        return invalid(diagnostic, .missing_attestation_input, "attestation.inputs", "board source is missing from the attested input set", board.source);

    var declared_documents: std.StringHashMapUnmanaged(DocumentSpec) = .empty;
    defer declared_documents.deinit(allocator);
    for (spec.documents) |document| try declared_documents.put(allocator, document.id, document);
    var attested_documents: std.StringHashMapUnmanaged(void) = .empty;
    defer attested_documents.deinit(allocator);
    for (attestation.documents) |document| {
        if (!isSha256Hex(document.sha256))
            return invalid(diagnostic, .invalid_sha256, "attestation.documents[].sha256", "document hash must be 64 lowercase hexadecimal characters", document.id);
        const declared = declared_documents.get(document.id) orelse
            return invalid(diagnostic, .unknown_document_attestation, "attestation.documents[].id", "attestation names no declared document", document.id);
        if (!std.mem.eql(u8, declared.path, document.path))
            return invalid(diagnostic, .attestation_path_mismatch, "attestation.documents[].path", "attested document path differs from its declaration", document.path);
        if (document.checklist.complete > document.checklist.total or
            document.checklist.open != document.checklist.total - document.checklist.complete)
            return invalid(diagnostic, .invalid_interface, "attestation.documents[].checklist", "checklist total must equal complete plus open", document.id);
        if ((try attested_documents.getOrPut(allocator, document.id)).found_existing)
            return invalid(diagnostic, .duplicate_document_attestation, "attestation.documents[].id", "a document may be attested only once", document.id);
    }
    for (spec.documents) |document| {
        if (document.status == .active and document.required and !attested_documents.contains(document.id))
            return invalid(diagnostic, .missing_document_attestation, "attestation.documents", "required active document has no content attestation", document.id);
    }
    const expected = try systemLockDigest(allocator, spec, attestation.inputs, attestation.documents);
    if (!std.mem.eql(u8, &expected, attestation.system_lock_sha256))
        return invalid(diagnostic, .system_lock_mismatch, "attestation.system_lock_sha256", "system lock does not match canonical manifest and content hashes", attestation.system_lock_sha256);
}

/// Validate an attestation for fabrication release. In addition to all normal
/// content checks, this requires an authenticated writer identity and a UTC
/// second-precision timestamp.
pub fn validateReleaseAttestation(
    allocator: std.mem.Allocator,
    spec: SystemSpec,
    attestation: Attestation,
    diagnostic: *Diagnostic,
) ValidationError!void {
    try validateAttestation(allocator, spec, attestation, diagnostic);
    try validateAttestationMetadata(attestation, true, diagnostic);
    for (spec.documents) |document| {
        if (document.status != .active or !document.required) continue;
        if (document.classification != .checklist) continue;
        const evidence = findDocumentAttestation(attestation.documents, document.id) orelse
            return invalid(diagnostic, .missing_document_attestation, "attestation.documents", "required active checklist has no content attestation", document.id);
        if (!evidence.checklist.allComplete())
            return invalid(diagnostic, .incomplete_checklist, "attestation.documents[].checklist", "fabrication release requires every task in a required active checklist to be complete", document.id);
    }
}

fn validateAttestationMetadata(
    attestation: Attestation,
    required: bool,
    diagnostic: *Diagnostic,
) error{InvalidManifest}!void {
    if (attestation.attested_by) |identity| {
        if (!isPlainText(identity))
            return invalid(diagnostic, .invalid_attestation_identity, "attestation.attested_by", "attested_by must be non-empty printable text", identity);
    } else if (required) {
        return invalid(diagnostic, .missing_attestation_identity, "attestation.attested_by", "fabrication release requires the authenticated writer identity", "");
    }
    if (attestation.attested_at) |timestamp| {
        if (!isUtcSecondTimestamp(timestamp))
            return invalid(diagnostic, .invalid_attestation_timestamp, "attestation.attested_at", "attested_at must use UTC form YYYY-MM-DDTHH:MM:SSZ", timestamp);
    } else if (required) {
        return invalid(diagnostic, .missing_attestation_timestamp, "attestation.attested_at", "fabrication release requires an attestation timestamp", "");
    }
}

fn hashCanonicalSpec(
    allocator: std.mem.Allocator,
    hash: *Sha256,
    spec: SystemSpec,
) std.mem.Allocator.Error!void {
    hashField(hash, "netlisp-system-review-spec-v1");
    hashField(hash, spec.schema);
    hashField(hash, spec.name);
    hashField(hash, spec.title);
    hashField(hash, spec.part_number);
    hashField(hash, spec.revision);
    try hashCanonicalBoards(allocator, hash, spec.boards);
    try hashCanonicalInterfaces(allocator, hash, spec.interfaces);
    try hashCanonicalDocuments(allocator, hash, spec.documents);
}

fn hashCanonicalBoards(
    allocator: std.mem.Allocator,
    hash: *Sha256,
    boards: []const BoardMember,
) std.mem.Allocator.Error!void {
    const sorted = try allocator.dupe(BoardMember, boards);
    defer allocator.free(sorted);
    std.mem.sort(BoardMember, sorted, {}, lessBoard);
    hashCount(hash, sorted.len);
    for (sorted) |board| {
        hashField(hash, board.name);
        hashField(hash, board.role);
        hashField(hash, board.source);
        hashField(hash, board.part_number);
        hashField(hash, board.revision);
        hashField(hash, board.layout);
        hashField(hash, @tagName(board.dnp));
    }
}

fn hashCanonicalInterfaces(
    allocator: std.mem.Allocator,
    hash: *Sha256,
    interfaces: []const InterfaceContract,
) std.mem.Allocator.Error!void {
    const sorted = try allocator.dupe(InterfaceContract, interfaces);
    defer allocator.free(sorted);
    std.mem.sort(InterfaceContract, sorted, {}, lessInterface);
    hashCount(hash, sorted.len);
    for (sorted) |interface| {
        hashField(hash, interface.id);
        hashField(hash, interface.left.board);
        hashField(hash, interface.left.connector);
        hashField(hash, interface.right.board);
        hashField(hash, interface.right.connector);
        hashCount(hash, interface.contact_count);
        try hashCanonicalSignals(allocator, hash, interface.signals);
        try hashCanonicalAliases(allocator, hash, interface.aliases);
    }
}

fn hashCanonicalSignals(
    allocator: std.mem.Allocator,
    hash: *Sha256,
    signals: []const InterfaceSignal,
) std.mem.Allocator.Error!void {
    const sorted = try allocator.dupe(InterfaceSignal, signals);
    defer allocator.free(sorted);
    std.mem.sort(InterfaceSignal, sorted, {}, lessSignal);
    hashCount(hash, sorted.len);
    for (sorted) |signal| {
        hashField(hash, signal.canonical);
        hashField(hash, signal.left_pin);
        hashField(hash, signal.left_net);
        hashField(hash, signal.right_pin);
        hashField(hash, signal.right_net);
        hashBool(hash, signal.required);
    }
}

fn hashCanonicalAliases(
    allocator: std.mem.Allocator,
    hash: *Sha256,
    aliases: []const InterfaceAlias,
) std.mem.Allocator.Error!void {
    const sorted = try allocator.dupe(InterfaceAlias, aliases);
    defer allocator.free(sorted);
    std.mem.sort(InterfaceAlias, sorted, {}, lessAlias);
    hashCount(hash, sorted.len);
    for (sorted) |alias| {
        hashField(hash, alias.board);
        hashField(hash, alias.local);
        hashField(hash, alias.canonical);
    }
}

fn hashCanonicalDocuments(
    allocator: std.mem.Allocator,
    hash: *Sha256,
    documents: []const DocumentSpec,
) std.mem.Allocator.Error!void {
    const sorted = try allocator.dupe(DocumentSpec, documents);
    defer allocator.free(sorted);
    std.mem.sort(DocumentSpec, sorted, {}, lessDocument);
    hashCount(hash, sorted.len);
    for (sorted) |document| {
        hashField(hash, document.id);
        hashField(hash, document.title);
        hashField(hash, document.path);
        hashField(hash, @tagName(document.classification));
        hashField(hash, @tagName(document.status));
        hashOptionalField(hash, document.board);
        hashBool(hash, document.required);
        hashBool(hash, document.include_in_fab);
        const sections = try allocator.dupe([]const u8, document.generated_sections);
        defer allocator.free(sections);
        std.mem.sort([]const u8, sections, {}, lessString);
        hashCount(hash, sections.len);
        for (sections) |section| hashField(hash, section);
    }
}

fn hashField(hash: *Sha256, value: []const u8) void {
    hashCount(hash, value.len);
    hash.update(value);
}

fn hashOptionalField(hash: *Sha256, value: ?[]const u8) void {
    hashBool(hash, value != null);
    if (value) |present| hashField(hash, present);
}

fn hashCount(hash: *Sha256, value: usize) void {
    var bytes: [8]u8 = @splat(0);
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn hashBool(hash: *Sha256, value: bool) void {
    hash.update(&.{@intFromBool(value)});
}

fn finishHex(hash: *Sha256) [64]u8 {
    var digest: [Sha256.digest_length]u8 = @splat(0);
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn lessBoard(_: void, a: BoardMember, b: BoardMember) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessInterface(_: void, a: InterfaceContract, b: InterfaceContract) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn lessSignal(_: void, a: InterfaceSignal, b: InterfaceSignal) bool {
    const left_order = std.mem.order(u8, a.left_pin, b.left_pin);
    if (left_order != .eq) return left_order == .lt;
    const right_order = std.mem.order(u8, a.right_pin, b.right_pin);
    if (right_order != .eq) return right_order == .lt;
    return std.mem.lessThan(u8, a.canonical, b.canonical);
}

fn lessAlias(_: void, a: InterfaceAlias, b: InterfaceAlias) bool {
    const board_order = std.mem.order(u8, a.board, b.board);
    if (board_order != .eq) return board_order == .lt;
    const local_order = std.mem.order(u8, a.local, b.local);
    if (local_order != .eq) return local_order == .lt;
    return std.mem.lessThan(u8, a.canonical, b.canonical);
}

fn lessDocument(_: void, a: DocumentSpec, b: DocumentSpec) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn lessInputAttestation(_: void, a: InputAttestation, b: InputAttestation) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn lessDocumentAttestation(_: void, a: DocumentAttestation, b: DocumentAttestation) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn hasBoard(spec: SystemSpec, name: []const u8) bool {
    for (spec.boards) |board| if (std.mem.eql(u8, board.name, name)) return true;
    return false;
}

fn hasAttestedInput(inputs: []const InputAttestation, path: []const u8) bool {
    for (inputs) |input| if (std.mem.eql(u8, input.path, path)) return true;
    return false;
}

fn findDocument(documents: []const DocumentSpec, id: []const u8) ?DocumentSpec {
    for (documents) |document| if (std.mem.eql(u8, document.id, id)) return document;
    return null;
}

fn hasAttestedDocument(documents: []const DocumentAttestation, id: []const u8) bool {
    return findDocumentAttestation(documents, id) != null;
}

fn findDocumentAttestation(documents: []const DocumentAttestation, id: []const u8) ?DocumentAttestation {
    for (documents) |document| if (std.mem.eql(u8, document.id, id)) return document;
    return null;
}

fn isSimpleId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |byte| {
        if (!isSimpleIdByte(byte)) return false;
    }
    return true;
}

fn isSimpleIdByte(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return byte == '-' or byte == '_' or byte == '.';
}

fn isStableHandle(value: []const u8) bool {
    if (value.len == 0 or value.len > 512) return false;
    var segments = std.mem.splitScalar(u8, value, '/');
    while (segments.next()) |segment| if (!isSimpleId(segment)) return false;
    return true;
}

fn isPinName(value: []const u8) bool {
    if (!isPlainText(value)) return false;
    return std.mem.indexOfAny(u8, value, " \t/\\") == null;
}

fn isPlainText(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn isBoundedPlainText(value: []const u8) bool {
    return value.len <= 512 and isPlainText(value);
}

fn isSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

fn isUtcSecondTimestamp(value: []const u8) bool {
    if (value.len != 20) return false;
    if (value[4] != '-' or value[7] != '-') return false;
    if (value[10] != 'T' or value[13] != ':' or value[16] != ':') return false;
    if (value[19] != 'Z') return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 }) |index| {
        if (!std.ascii.isDigit(value[index])) return false;
    }
    return true;
}

fn invalid(
    diagnostic: *Diagnostic,
    code: DiagnosticCode,
    field: []const u8,
    message: []const u8,
    value: []const u8,
) error{InvalidManifest} {
    diagnostic.set(code, field, message, value);
    return error.InvalidManifest;
}

fn invalidDocument(
    diagnostic: *Diagnostic,
    code: DiagnosticCode,
    field: []const u8,
    message: []const u8,
    value: []const u8,
) error{InvalidDocument} {
    diagnostic.set(code, field, message, value);
    return error.InvalidDocument;
}

const fixture_boards = [_]BoardMember{
    .{ .name = "rf", .role = "rf", .source = "src/rf.sexp", .part_number = "SYS-RF", .revision = "B3" },
    .{ .name = "base", .role = "base", .source = "src/base.sexp", .part_number = "SYS-BASE", .revision = "B3" },
};

const fixture_signals = [_]InterfaceSignal{
    .{ .canonical = "V_12V", .left_pin = "1", .left_net = "V_12V", .right_pin = "1", .right_net = "V_12V" },
    .{ .canonical = "SPI_CLK", .left_pin = "2", .left_net = "SCK", .right_pin = "2", .right_net = "SPI_CLK" },
};

const fixture_aliases = [_]InterfaceAlias{
    .{ .board = "rf", .local = "SCK", .canonical = "SPI_CLK" },
};

const fixture_interfaces = [_]InterfaceContract{
    .{
        .id = "board-to-board",
        .left = .{ .board = "rf", .connector = "J1" },
        .right = .{ .board = "base", .connector = "base-interface/J1" },
        .contact_count = 2,
        .signals = &fixture_signals,
        .aliases = &fixture_aliases,
    },
};

const fixture_sections = [_][]const u8{ "system-summary", "interface-matrix" };
const fixture_documents = [_]DocumentSpec{
    .{
        .id = "overview",
        .title = "System overview",
        .path = "src/systems/demo/overview.md",
        .classification = .review,
        .generated_sections = &fixture_sections,
    },
    .{
        .id = "bringup",
        .title = "Bring-up checklist",
        .path = "src/systems/demo/bringup.md",
        .classification = .checklist,
        .board = "base",
    },
};

fn fixtureSpec() SystemSpec {
    return .{
        .schema = schema_v1,
        .name = "demo-system",
        .title = "Demo System",
        .part_number = "DEMO-001",
        .revision = "B3",
        .boards = &fixture_boards,
        .interfaces = &fixture_interfaces,
        .documents = &fixture_documents,
    };
}

// Strict manifests bind boards, complete contact maps, documents, and optional attestations without accepting unknown schema fields.
test "system review parses a strict manifest and applies release defaults" {
    const json =
        \\{
        \\  "schema":"netlisp-system-review-v1",
        \\  "name":"demo-system",
        \\  "title":"Demo System",
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
        \\    "contact_count":2,
        \\    "signals":[
        \\      {"canonical":"V_12V","left_pin":"1","left_net":"V_12V","right_pin":"1","right_net":"V_12V"},
        \\      {"canonical":"SPI_CLK","left_pin":"2","left_net":"SCK","right_pin":"2","right_net":"SPI_CLK"}
        \\    ],
        \\    "aliases":[{"board":"rf","local":"SCK","canonical":"SPI_CLK"}]
        \\  }],
        \\  "documents":[
        \\    {"id":"overview","title":"Overview","path":"src/systems/demo/overview.md",
        \\     "classification":"review","generated_sections":["system-summary"]},
        \\    {"id":"release-checklist","title":"Release checklist","path":"src/systems/demo/release-checklist.md",
        \\     "classification":"checklist"}
        \\  ]
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    var parsed = try parseSystemSpec(std.testing.allocator, json, &diagnostic);
    defer parsed.deinit();
    try std.testing.expectEqual(DiagnosticCode.none, diagnostic.code);
    try std.testing.expectEqualStrings("blessed", parsed.value.boards[0].layout);
    try std.testing.expectEqual(DnpPolicy.drop, parsed.value.boards[0].dnp);
    try std.testing.expectEqual(DnpPolicy.keep, parsed.value.boards[1].dnp);
    try std.testing.expectEqual(DocumentStatus.active, parsed.value.documents[0].status);
}

// A release manifest always declares an active required checklist; optional or historical checklists cannot silently satisfy the gate.
test "system review requires an active required checklist" {
    var diagnostic: Diagnostic = .{};
    var no_checklist = fixtureSpec();
    no_checklist.documents = fixture_documents[0..1];
    try std.testing.expectError(error.InvalidManifest, validateSystemSpec(std.testing.allocator, no_checklist, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.missing_required_checklist, diagnostic.code);

    const optional_checklist = [_]DocumentSpec{.{
        .id = "optional-checklist",
        .title = "Optional checklist",
        .path = "src/systems/demo/optional-checklist.md",
        .classification = .checklist,
        .required = false,
    }};
    no_checklist.documents = &optional_checklist;
    try std.testing.expectError(error.InvalidManifest, validateSystemSpec(std.testing.allocator, no_checklist, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.missing_required_checklist, diagnostic.code);

    var historical = optional_checklist;
    historical[0].required = true;
    historical[0].status = .historical;
    no_checklist.documents = &historical;
    try std.testing.expectError(error.InvalidManifest, validateSystemSpec(std.testing.allocator, no_checklist, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.missing_required_checklist, diagnostic.code);
}

// Manifest parsing rejects unknown keys rather than silently dropping release intent.
test "system review rejects unknown JSON fields" {
    const json =
        \\{"schema":"netlisp-system-review-v1","name":"demo","title":"Demo","part_number":"DEMO-001","revision":"A",
        \\ "boards":[{"name":"one","role":"main","source":"src/one.sexp","part_number":"ONE","revision":"A","surprise":true}]}
    ;
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidJson, parseSystemSpec(std.testing.allocator, json, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.invalid_json, diagnostic.code);
}

// Every manifest path is normalized project-relative and cannot escape the project root.
test "system review relative path validation rejects traversal and platform escapes" {
    for ([_][]const u8{
        "",
        "/src/board.sexp",
        "../src/board.sexp",
        "src/../board.sexp",
        "src//board.sexp",
        "src/./board.sexp",
        "C:/src/board.sexp",
        "src\\board.sexp",
        "src/board.sexp/",
        "src/board\x00.sexp",
    }) |path| try std.testing.expect(!isSafeRelativePath(path));
    try std.testing.expect(isSafeRelativePath("src/systems/barracuda/review package.md"));
}

// spec: system-review - board archive roles are unique and authored review documents are Markdown; binary evidence uses the bounded assets area
test "system review rejects ambiguous roles and non-Markdown documents" {
    var diagnostic: Diagnostic = .{};
    var duplicate_roles = fixture_boards;
    duplicate_roles[1].role = duplicate_roles[0].role;
    var role_spec = fixtureSpec();
    role_spec.boards = &duplicate_roles;
    try std.testing.expectError(error.InvalidManifest, validateSystemSpec(std.testing.allocator, role_spec, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.duplicate_board_role, diagnostic.code);

    var non_markdown = fixture_documents;
    non_markdown[0].path = "src/systems/demo/copper.gbr";
    var document_spec = fixtureSpec();
    document_spec.documents = &non_markdown;
    try std.testing.expectError(error.InvalidManifest, validateSystemSpec(std.testing.allocator, document_spec, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.unsupported_document_type, diagnostic.code);
}

// A connector contract carries exactly one unique mapping for each physical contact and names every local-to-canonical alias explicitly.
test "system review validates complete contact maps and aliases" {
    var diagnostic: Diagnostic = .{};
    try validateSystemSpec(std.testing.allocator, fixtureSpec(), &diagnostic);

    const short_interface = InterfaceContract{
        .id = "short",
        .left = fixture_interfaces[0].left,
        .right = fixture_interfaces[0].right,
        .contact_count = 3,
        .signals = &fixture_signals,
        .aliases = &fixture_aliases,
    };
    var short_spec = fixtureSpec();
    short_spec.interfaces = &.{short_interface};
    try std.testing.expectError(error.InvalidManifest, validateSystemSpec(std.testing.allocator, short_spec, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.incomplete_interface, diagnostic.code);

    var no_alias = fixture_interfaces[0];
    no_alias.aliases = &.{};
    var alias_spec = fixtureSpec();
    alias_spec.interfaces = &.{no_alias};
    try std.testing.expectError(error.InvalidManifest, validateSystemSpec(std.testing.allocator, alias_spec, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.missing_alias, diagnostic.code);
    try std.testing.expectEqualStrings("SCK", diagnostic.value);
}

// Evaluated connector observations must cover every declared pin and endpoint-local net exactly.
test "system review checks evaluated interface observations" {
    const left_contacts = [_]ContactObservation{
        .{ .pin = "1", .net = "V_12V" },
        .{ .pin = "2", .net = "SCK" },
    };
    const right_contacts = [_]ContactObservation{
        .{ .pin = "1", .net = "V_12V" },
        .{ .pin = "2", .net = "SPI_CLK" },
    };
    var observations = [_]InterfaceObservation{
        .{ .board = "rf", .connector = "J1", .contacts = &left_contacts },
        .{ .board = "base", .connector = "base-interface/J1", .contacts = &right_contacts },
    };
    var diagnostic: Diagnostic = .{};
    try validateInterfaceCompleteness(fixtureSpec(), &observations, &diagnostic);

    observations[1].contacts = &.{
        .{ .pin = "1", .net = "V_12V" },
        .{ .pin = "2", .net = "WRONG" },
    };
    try std.testing.expectError(error.InvalidManifest, validateInterfaceCompleteness(fixtureSpec(), &observations, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.interface_net_mismatch, diagnostic.code);
    try std.testing.expectEqualStrings("2", diagnostic.value);
}

// Markdown generated regions are declared, unique, paired, and attest checklist completion without rewriting authored prose.
test "system review inspects generated regions and checklist content" {
    const overview =
        \\# Review
        \\<!-- netlisp:generated system-summary -->
        \\Generated facts.
        \\<!-- /netlisp:generated -->
        \\<!-- netlisp:generated interface-matrix -->
        \\Generated matrix.
        \\<!-- /netlisp:generated -->
    ;
    var diagnostic: Diagnostic = .{};
    const inspected = try inspectDocumentContent(fixture_documents[0], overview, &diagnostic);
    try std.testing.expectEqual(@as(usize, 2), inspected.generated_regions);

    const checklist =
        \\# Bring-up
        \\- [x] Confirm current limit
        \\- [ ] Measure the 100 MHz reference
        \\* [X] Record serial number
    ;
    const checklist_result = try inspectDocumentContent(fixture_documents[1], checklist, &diagnostic);
    try std.testing.expectEqual(@as(usize, 3), checklist_result.checklist.total);
    try std.testing.expectEqual(@as(usize, 2), checklist_result.checklist.complete);
    try std.testing.expectEqual(@as(usize, 1), checklist_result.checklist.open);
    try std.testing.expect(!checklist_result.checklist.allComplete());
}

// Checklist-looking examples and generated placeholders are not approvable work items.
test "system review ignores checklist syntax in fences and generated regions" {
    var diagnostic: Diagnostic = .{};
    const fenced_only =
        \\```text
        \\- [x] This is only an example
        \\```
    ;
    try std.testing.expectError(error.InvalidDocument, inspectDocumentContent(fixture_documents[1], fenced_only, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.empty_checklist, diagnostic.code);

    const generated_and_real =
        \\<!-- netlisp:generated system-summary -->
        \\- [x] Generated status is not an approval
        \\<!-- /netlisp:generated -->
        \\- [ ] Human approval remains open
    ;
    var checklist_spec = fixture_documents[1];
    checklist_spec.generated_sections = &.{"system-summary"};
    const inspected = try inspectDocumentContent(checklist_spec, generated_and_real, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), inspected.checklist.total);
    try std.testing.expectEqual(@as(usize, 1), inspected.checklist.open);

    const marker_in_fence =
        \\```text
        \\<!-- netlisp:generated system-summary -->
        \\<!-- /netlisp:generated -->
        \\```
        \\- [x] Real approval
    ;
    try std.testing.expectError(error.InvalidDocument, inspectDocumentContent(checklist_spec, marker_in_fence, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.missing_generated_region, diagnostic.code);
}

// Malformed or undeclared generated regions fail with an actionable document diagnostic.
test "system review rejects malformed generated regions" {
    var diagnostic: Diagnostic = .{};
    const missing =
        \\<!-- netlisp:generated system-summary -->
        \\No close.
    ;
    try std.testing.expectError(error.InvalidDocument, inspectDocumentContent(fixture_documents[0], missing, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.unclosed_generated_region, diagnostic.code);

    const undeclared =
        \\<!-- netlisp:generated release-status -->
        \\No declaration.
        \\<!-- /netlisp:generated -->
    ;
    try std.testing.expectError(error.InvalidDocument, inspectDocumentContent(fixture_documents[0], undeclared, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.undeclared_generated_region, diagnostic.code);
}

// Canonical manifest and system-lock digests are independent of authored collection order and change with any attested content.
test "system review canonical digest and content attestations are deterministic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const direct = try canonicalSpecDigest(allocator, fixtureSpec());
    const reversed_boards = [_]BoardMember{ fixture_boards[1], fixture_boards[0] };
    const reversed_documents = [_]DocumentSpec{ fixture_documents[1], fixture_documents[0] };
    var reordered = fixtureSpec();
    reordered.boards = &reversed_boards;
    reordered.documents = &reversed_documents;
    const reordered_digest = try canonicalSpecDigest(allocator, reordered);
    try std.testing.expectEqualSlices(u8, &direct, &reordered_digest);

    var different_assembly = fixtureSpec();
    different_assembly.part_number = "DEMO-002";
    const different_assembly_digest = try canonicalSpecDigest(allocator, different_assembly);
    try std.testing.expect(!std.mem.eql(u8, &direct, &different_assembly_digest));

    const source_rf = try attestInput(allocator, "src/rf.sexp", "rf bytes", &diagnostic);
    const source_base = try attestInput(allocator, "src/base.sexp", "base bytes", &diagnostic);
    const overview =
        \\<!-- netlisp:generated system-summary -->
        \\Summary.
        \\<!-- /netlisp:generated -->
        \\<!-- netlisp:generated interface-matrix -->
        \\Matrix.
        \\<!-- /netlisp:generated -->
    ;
    const bringup = "- [x] Power rails\n";
    const review_doc = try attestDocument(allocator, fixture_documents[0], overview, &diagnostic);
    const checklist_doc = try attestDocument(allocator, fixture_documents[1], bringup, &diagnostic);
    const inputs = [_]InputAttestation{ source_rf, source_base };
    const documents = [_]DocumentAttestation{ review_doc, checklist_doc };
    const lock = try systemLockDigest(allocator, fixtureSpec(), &inputs, &documents);

    const reversed_inputs = [_]InputAttestation{ source_base, source_rf };
    const reversed_docs = [_]DocumentAttestation{ checklist_doc, review_doc };
    const reordered_lock = try systemLockDigest(allocator, fixtureSpec(), &reversed_inputs, &reversed_docs);
    try std.testing.expectEqualSlices(u8, &lock, &reordered_lock);

    const changed_source = try attestInput(allocator, "src/rf.sexp", "changed rf bytes", &diagnostic);
    const changed_inputs = [_]InputAttestation{ changed_source, source_base };
    const changed_lock = try systemLockDigest(allocator, fixtureSpec(), &changed_inputs, &documents);
    try std.testing.expect(!std.mem.eql(u8, &lock, &changed_lock));
}

// An exported attestation covers every board source and required active document and self-verifies its canonical lock.
test "system review validates complete attestations and rejects a stale lock" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var diagnostic: Diagnostic = .{};
    const inputs = [_]InputAttestation{
        try attestInput(allocator, "src/rf.sexp", "rf", &diagnostic),
        try attestInput(allocator, "src/base.sexp", "base", &diagnostic),
    };
    const overview =
        \\<!-- netlisp:generated system-summary -->
        \\Summary.
        \\<!-- /netlisp:generated -->
        \\<!-- netlisp:generated interface-matrix -->
        \\Matrix.
        \\<!-- /netlisp:generated -->
    ;
    const documents = [_]DocumentAttestation{
        try attestDocument(allocator, fixture_documents[0], overview, &diagnostic),
        try attestDocument(allocator, fixture_documents[1], "- [x] Measure output\n", &diagnostic),
    };
    const attestation = try makeAttestation(allocator, fixtureSpec(), &inputs, &documents);
    try validateAttestation(allocator, fixtureSpec(), attestation, &diagnostic);
    try std.testing.expectError(error.InvalidManifest, validateReleaseAttestation(allocator, fixtureSpec(), attestation, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.missing_attestation_identity, diagnostic.code);

    var released = attestation;
    released.attested_by = "reviewer@example.com";
    released.attested_at = "2026-08-29T12:34:56Z";
    try validateReleaseAttestation(allocator, fixtureSpec(), released, &diagnostic);

    var invalid_time = released;
    invalid_time.attested_at = "2026-08-29 12:34:56Z";
    try std.testing.expectError(error.InvalidManifest, validateReleaseAttestation(allocator, fixtureSpec(), invalid_time, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.invalid_attestation_timestamp, diagnostic.code);

    var open_documents = documents;
    open_documents[1].checklist = .{ .total = 1, .open = 1 };
    var incomplete = try makeAttestation(allocator, fixtureSpec(), &inputs, &open_documents);
    incomplete.attested_by = released.attested_by;
    incomplete.attested_at = released.attested_at;
    try std.testing.expectError(error.InvalidManifest, validateReleaseAttestation(allocator, fixtureSpec(), incomplete, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.incomplete_checklist, diagnostic.code);

    var attestation_json: std.Io.Writer.Allocating = .init(allocator);
    defer attestation_json.deinit();
    try writeAttestationJson(allocator, &attestation_json.writer, released);
    var reparsed_attestation = try std.json.parseFromSlice(Attestation, allocator, attestation_json.written(), .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
    defer reparsed_attestation.deinit();
    try validateReleaseAttestation(allocator, fixtureSpec(), reparsed_attestation.value, &diagnostic);

    var persisted = fixtureSpec();
    persisted.attestation = released;
    var manifest_json: std.Io.Writer.Allocating = .init(allocator);
    defer manifest_json.deinit();
    try writeSystemSpecJson(allocator, &manifest_json.writer, persisted);
    try std.testing.expect(std.mem.endsWith(u8, manifest_json.written(), "\n"));
    try std.testing.expect(std.mem.indexOf(u8, manifest_json.written(), "\n  \"part_number\": \"DEMO-001\"") != null);
    var reparsed_manifest = try parseSystemSpec(allocator, manifest_json.written(), &diagnostic);
    defer reparsed_manifest.deinit();
    try std.testing.expectEqualStrings("DEMO-001", reparsed_manifest.value.part_number);
    try std.testing.expectEqualStrings("reviewer@example.com", reparsed_manifest.value.attestation.?.attested_by.?);

    const stale_hex = sha256Hex("stale lock");
    var stale = attestation;
    stale.system_lock_sha256 = &stale_hex;
    try std.testing.expectError(error.InvalidManifest, validateAttestation(allocator, fixtureSpec(), stale, &diagnostic));
    try std.testing.expectEqual(DiagnosticCode.system_lock_mismatch, diagnostic.code);
}
