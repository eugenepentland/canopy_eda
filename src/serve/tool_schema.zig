//! Hold every structured tool to the schema it advertises.
//!
//! `assets/tools_list_result.json` is the contract: `tools/list` returns it, an
//! agent's client validates against it, and the CLI prints it for `netlisp tool
//! list`. Nothing enforced it. A test keeps the tool NAMES in lockstep with the
//! registration table; the parameters were on their honour, and four ways of
//! being wrong went straight through to a handler that shrugged:
//!
//!   * `list_free_pins {"filter":"nonsense"}` returned `{"free_pins":[],
//!     "assigned_pins":[]}` and exit 0 — a typo'd filter is indistinguishable
//!     from an IC with no free pins.
//!   * `get_schematic_image {"view":"nope"}` rendered a PNG with the default
//!     view. `{"theme":"chartreuse"}` did the same. An invalid explicit value
//!     silently bought an expensive default.
//!   * `get_schematic {"viwe":"summary"}` was accepted despite
//!     `"additionalProperties": false` — a misspelled option name is invisible.
//!   * `{"flatten":"yes"}` passed a string to a declared boolean.
//!
//! `get_schematic {"view":"bogus"}` DID reject, which is the point: the answer
//! depended on whether an individual handler happened to check. So the check
//! moved to the one place every surface passes through (`mcp_tools.call`,
//! shared by the HTTP routes and `netlisp tool`), and it validates against the
//! advertised document ITSELF rather than a transcription of it. The two cannot
//! drift, because there is only one of them.
//!
//! The document is parsed per call, into the caller's allocator. At ~142 KB
//! that is well under a millisecond against tool calls that run from a hundred
//! milliseconds to a minute, and it buys no process-wide mutable cache to get
//! wrong across the server's threads.
//!
//! Deliberately NOT a general JSON Schema implementation. It enforces the four
//! constructs this document actually uses — `required`, `additionalProperties:
//! false`, `type`, `enum` — and ignores anything else, so an unrecognised
//! keyword can never turn a valid call into a rejected one.

const std = @import("std");

/// Why a call was rejected. `message` is ready to show a caller.
pub const Violation = struct {
    /// The offending property, or the tool name for a whole-object problem.
    property: []const u8,
    message: []const u8,
};

/// Check `args` against `tool_name`'s advertised schema in `schema_doc`
/// (normally `mcp_tools.tools_list_result`). Returns null when the call
/// conforms, or when the tool is absent from the document — an unknown tool is
/// the caller's rejection to make, not this one's.
///
/// Allocation failure yields null: a validator that turned an out-of-memory
/// condition into "your arguments are wrong" would be worse than not running.
pub fn validate(
    allocator: std.mem.Allocator,
    schema_doc: []const u8,
    tool_name: []const u8,
    args: ?std.json.Value,
) ?Violation {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, schema_doc, .{}) catch return null;
    defer parsed.deinit();
    const schema = findSchema(parsed.value, tool_name) orelse return null;
    return check(allocator, schema, tool_name, args);
}

/// The `inputSchema` object for `tool_name`.
fn findSchema(doc: std.json.Value, tool_name: []const u8) ?std.json.ObjectMap {
    const tools = switch (doc) {
        .object => |o| o.get("tools") orelse return null,
        else => return null,
    };
    const items = switch (tools) {
        .array => |a| a.items,
        else => return null,
    };
    for (items) |tool| {
        const obj = switch (tool) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, name, tool_name)) continue;
        return switch (obj.get("inputSchema") orelse return null) {
            .object => |o| o,
            else => null,
        };
    }
    return null;
}

fn check(
    allocator: std.mem.Allocator,
    schema: std.json.ObjectMap,
    tool_name: []const u8,
    args: ?std.json.Value,
) ?Violation {
    const properties = switch (schema.get("properties") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    // A call with no arguments is an empty object: it can still be missing a
    // required property, and that is the same rejection as passing `{}`.
    const given: ?std.json.ObjectMap = switch (args orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        .null => null,
        else => return .{
            .property = tool_name,
            .message = "arguments must be a JSON object",
        },
    };

    if (schema.get("required")) |required| {
        if (required == .array) {
            for (required.array.items) |entry| {
                if (entry != .string) continue;
                const present = if (given) |g| g.get(entry.string) != null else false;
                if (!present) return .{
                    .property = entry.string,
                    .message = std.fmt.allocPrint(allocator, "missing required argument \"{s}\"", .{entry.string}) catch
                        "missing a required argument",
                };
            }
        }
    }

    const g = given orelse return null;
    const closed = switch (schema.get("additionalProperties") orelse std.json.Value{ .bool = true }) {
        .bool => |b| !b,
        else => false,
    };

    var it = g.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const declared = properties.get(key) orelse {
            if (!closed) continue;
            return .{
                .property = key,
                .message = std.fmt.allocPrint(
                    allocator,
                    "unknown argument \"{s}\" for {s} (its schema declares no such property)",
                    .{ key, tool_name },
                ) catch "unknown argument",
            };
        };
        if (declared != .object) continue;
        if (violatesType(declared.object, entry.value_ptr.*)) |wanted| return .{
            .property = key,
            .message = std.fmt.allocPrint(
                allocator,
                "argument \"{s}\" must be {s}, not {s}",
                .{ key, wanted, kindName(entry.value_ptr.*) },
            ) catch "argument has the wrong type",
        };
        if (violatesEnum(allocator, declared.object, entry.value_ptr.*)) |allowed| return .{
            .property = key,
            .message = std.fmt.allocPrint(
                allocator,
                "argument \"{s}\" is \"{s}\"; expected one of {s}",
                .{ key, entry.value_ptr.string, allowed },
            ) catch "argument is not one of the accepted values",
        };
    }
    return null;
}

/// The declared type name when `value` does not satisfy it, else null.
///
/// A JSON `null` is treated as "not supplied" rather than as a type error: an
/// omitted optional argument and one written as `null` mean the same thing to
/// every handler here.
fn violatesType(declared: std.json.ObjectMap, value: std.json.Value) ?[]const u8 {
    const wanted = switch (declared.get("type") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (value == .null) return null;
    const ok = if (std.mem.eql(u8, wanted, "string"))
        value == .string
    else if (std.mem.eql(u8, wanted, "boolean"))
        value == .bool
    else if (std.mem.eql(u8, wanted, "integer"))
        value == .integer
    else if (std.mem.eql(u8, wanted, "number"))
        value == .integer or value == .float
    else if (std.mem.eql(u8, wanted, "array"))
        value == .array
    else if (std.mem.eql(u8, wanted, "object"))
        value == .object
    else
        // An unrecognised type keyword constrains nothing.
        true;
    return if (ok) null else wanted;
}

/// The accepted values, rendered, when `value` is a string outside the declared
/// `enum`; else null.
fn violatesEnum(allocator: std.mem.Allocator, declared: std.json.ObjectMap, value: std.json.Value) ?[]const u8 {
    if (value != .string) return null;
    const allowed = switch (declared.get("enum") orelse return null) {
        .array => |a| a.items,
        else => return null,
    };
    for (allowed) |candidate| {
        if (candidate == .string and std.mem.eql(u8, candidate.string, value.string)) return null;
    }
    return renderEnum(allocator, declared);
}

/// `components|modules|pinouts|footprints` for a diagnostic. Falls back to a
/// bare phrase rather than failing: the rejection is the point, not the list.
fn renderEnum(allocator: std.mem.Allocator, declared: std.json.ObjectMap) []const u8 {
    const fallback = "the declared values";
    const raw = declared.get("enum") orelse return fallback;
    if (raw != .array) return fallback;
    var out = std.Io.Writer.Allocating.init(allocator);
    var written: usize = 0;
    for (raw.array.items) |candidate| {
        if (candidate != .string) continue;
        if (written > 0) out.writer.writeAll("|") catch return fallback;
        out.writer.writeAll(candidate.string) catch return fallback;
        written += 1;
    }
    return if (written == 0) fallback else out.written();
}

fn kindName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "a boolean",
        .integer, .float, .number_string => "a number",
        .string => "a string",
        .array => "an array",
        .object => "an object",
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const fixture_doc =
    \\{"tools":[
    \\{"name":"probe","description":"d","inputSchema":{"type":"object","properties":{
    \\"name":{"type":"string"},
    \\"view":{"type":"string","enum":["summary","full"]},
    \\"flatten":{"type":"boolean"},
    \\"count":{"type":"integer"}},
    \\"required":["name"],"additionalProperties":false}},
    \\{"name":"open","description":"d","inputSchema":{"type":"object","properties":{
    \\"query":{"type":"string"}}}}
    \\]}
;

fn probe(args_json: ?[]const u8) !?Violation {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var value: ?std.json.Value = null;
    if (args_json) |text| {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
        value = parsed.value;
    }
    const found = validate(arena, fixture_doc, "probe", value);
    // The message lives in the arena, so copy what a caller would have read.
    if (found) |v| return .{
        .property = try testing.allocator.dupe(u8, v.property),
        .message = try testing.allocator.dupe(u8, v.message),
    };
    return null;
}

fn freeViolation(v: ?Violation) void {
    if (v) |found| {
        testing.allocator.free(found.property);
        testing.allocator.free(found.message);
    }
}

// spec: tool schema - a call that conforms to the advertised schema is accepted unchanged
test "a conforming call passes" {
    const conforming = try probe(
        \\{"name":"board","view":"full","flatten":true,"count":3}
    );
    defer freeViolation(conforming);
    try testing.expect(conforming == null);
    // An optional property written as null is the same as omitting it.
    const nulled = try probe(
        \\{"name":"board","view":null}
    );
    defer freeViolation(nulled);
    try testing.expect(nulled == null);
}

// spec: tool schema - a value outside a declared enum is rejected and the accepted values are named
test "a value outside a declared enum is rejected" {
    const found = try probe(
        \\{"name":"board","view":"bogus"}
    );
    defer freeViolation(found);
    try testing.expect(found != null);
    try testing.expectEqualStrings("view", found.?.property);
    try testing.expect(std.mem.indexOf(u8, found.?.message, "summary|full") != null);
}

// spec: tool schema - an argument the schema does not declare is rejected when the schema closes the object
test "an undeclared argument is rejected under additionalProperties false" {
    const closed = try probe(
        \\{"name":"board","viwe":"summary"}
    );
    defer freeViolation(closed);
    try testing.expect(closed != null);
    try testing.expectEqualStrings("viwe", closed.?.property);
    try testing.expect(std.mem.indexOf(u8, closed.?.message, "unknown argument") != null);

    // A schema that does NOT close the object still accepts extras: the rule is
    // the document's, not this validator's.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena,
        \\{"query":"x","extra":1}
    , .{});
    try testing.expect(validate(arena, fixture_doc, "open", parsed.value) == null);
}

// spec: tool schema - a required argument that is absent is rejected by name
test "a missing required argument is rejected by name" {
    const empty = try probe("{}");
    defer freeViolation(empty);
    try testing.expect(empty != null);
    try testing.expectEqualStrings("name", empty.?.property);
    const none = try probe(null);
    defer freeViolation(none);
    try testing.expect(none != null);
    try testing.expectEqualStrings("name", none.?.property);
}

// spec: tool schema - an argument whose JSON type contradicts the declared type is rejected
test "a wrongly typed argument is rejected" {
    const boolean = try probe(
        \\{"name":"board","flatten":"yes"}
    );
    defer freeViolation(boolean);
    try testing.expect(boolean != null);
    try testing.expectEqualStrings("flatten", boolean.?.property);
    try testing.expect(std.mem.indexOf(u8, boolean.?.message, "boolean") != null);

    const integer = try probe(
        \\{"name":"board","count":"3"}
    );
    defer freeViolation(integer);
    try testing.expect(integer != null);
    try testing.expectEqualStrings("count", integer.?.property);
}

// spec: tool schema - a tool the document does not describe is left for the caller to reject
test "a tool absent from the document is not this validator's rejection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(validate(arena, fixture_doc, "no_such_tool", null) == null);
    // …and a document that is not the expected shape constrains nothing either,
    // rather than rejecting every call.
    try testing.expect(validate(arena, "not json", "probe", null) == null);
}
