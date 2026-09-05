//! The deploy contract, asserted where a gate actually runs it.
//!
//! Production is a `systemd --user` unit rendered from
//! `.githooks/netlisp.service.in` by `.githooks/install.sh`, with a checked-in
//! EXAMPLE render at `systemd/netlisp.service` — the same template resolved
//! against a placeholder root, never a real machine's paths. Its `ExecStart`
//! must name
//! `.deploy/bin/netlisp` — the artifact `deploy-prod.sh` installs atomically
//! after a compiler-SHA check, a test run and a checksum — and must NEVER name
//! `zig-out/bin/netlisp`, which any local `zig build` overwrites, including
//! with a Debug binary. That substitution is the 2026-08-19 Debug-in-prod
//! incident, and it recurred as audit finding DRIFT-INFRA-002 when the
//! checked-in copy drifted back to `zig-out/bin` while the live unit and the
//! template had both moved on.
//!
//! This module is invariants only — it declares no runtime API. The two files
//! arrive as anonymous imports wired up by `addDeployUnitImports` in build.zig,
//! because `@embedFile` cannot reach outside the `src/` module root. That
//! wiring is deliberate: a shell script asserting the same thing existed and
//! was run by nothing, which is how the drift survived a full audit cycle.

const std = @import("std");

/// The unit as shipped, with install.sh's placeholders already substituted.
const shipped = @embedFile("netlisp.service");
/// The template install.sh renders, `@TOP@`/`@PORT@` still in place.
const template = @embedFile("netlisp.service.in");

/// The one path production may execute. Anything else is either unverified
/// (a build tree) or unmanaged (a hand-copied binary).
const deploy_exec_suffix = "/.deploy/bin/netlisp";
/// The build-output path that must never appear in a unit file.
const forbidden_exec_dir = "zig-out";
/// The placeholder root the checked-in EXAMPLE render is resolved against.
/// It is deliberately not any machine's checkout — the unit production runs is
/// rendered per machine by `.githooks/install.sh --deploy` — so pinning it
/// keeps the tracked copy an example: a real path here (a user's home, an
/// operator's install prefix) means someone pasted their own render back into
/// the tree, which is a private path in a public repo and the same drift
/// channel that produced DRIFT-INFRA-002. Change it only together with the
/// header comment in `systemd/netlisp.service` that names it.
const example_root = "/srv/netlisp";

/// Return the value of the first `key=` directive in a unit file, ignoring
/// comment lines so a directive quoted in a rationale comment is not mistaken
/// for the real thing. Returns null when the key is absent.
fn directive(unit: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, unit, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len <= key.len or line[key.len] != '=') continue;
        return line[key.len + 1 ..];
    }
    return null;
}

/// Every non-comment line of a unit, trimmed — for directive-set comparisons
/// that must not be perturbed by the two files' differing rationale comments.
fn directiveLines(unit: []const u8, out: *std.ArrayList([]const u8), gpa: std.mem.Allocator) !void {
    var lines = std.mem.splitScalar(u8, unit, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try out.append(gpa, line);
    }
}

/// The `--port` value from an ExecStart line, or null when it is absent or is
/// still an unrendered `@PORT@` placeholder rather than a number.
fn execPort(exec: []const u8) ?[]const u8 {
    const flag = "--port ";
    const at = std.mem.indexOf(u8, exec, flag) orelse return null;
    const port = std.mem.trim(u8, exec[at + flag.len ..], " \t");
    if (port.len == 0) return null;
    for (port) |c| {
        if (c < '0' or c > '9') return null;
    }
    return port;
}

fn expectSameLines(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| try std.testing.expectEqualStrings(a, b);
}

// spec: Development pipeline - The production systemd unit executes the deploy-installed binary and never the build-output path that a local build overwrites
test "the systemd unit runs the deployed binary, never zig-out" {
    // DRIFT-INFRA-002. `zig-out/bin/netlisp` is whatever the last `zig build`
    // in this checkout produced — Debug, a feature branch, a half-finished
    // refactor. Production must run only the artifact deploy-prod.sh verified
    // and installed, so the substring below is a hard ban in both files.
    for ([_][]const u8{ shipped, template }) |unit| {
        const exec = directive(unit, "ExecStart") orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, exec, forbidden_exec_dir) == null);
        try std.testing.expect(std.mem.indexOf(u8, exec, deploy_exec_suffix) != null);
        // The ban covers the whole file, not just ExecStart: an ExecStartPre
        // or ExecReload reaching into the build tree is the same mistake.
        try std.testing.expect(std.mem.indexOf(u8, unit, forbidden_exec_dir) == null);
    }

    // The executable is the FIRST token of ExecStart — a path appearing later
    // as an argument would satisfy a naive substring check while systemd ran
    // something else entirely.
    const shipped_exec = directive(shipped, "ExecStart").?;
    const first = shipped_exec[0 .. std.mem.indexOfScalar(u8, shipped_exec, ' ') orelse shipped_exec.len];
    try std.testing.expect(std.mem.endsWith(u8, first, deploy_exec_suffix));
    try std.testing.expect(first[0] == '/');

    // The checked-in copy is an EXAMPLE render and has to stay one: both of
    // its paths sit under the placeholder root, never a real machine's. The
    // template, by contrast, still holds `@TOP@` — an unrendered placeholder
    // is the correct state there and is checked below.
    try std.testing.expectEqualStrings(
        example_root,
        directive(shipped, "WorkingDirectory") orelse return error.TestUnexpectedResult,
    );
    try std.testing.expect(std.mem.startsWith(u8, first, example_root ++ "/"));
    try std.testing.expect(std.mem.indexOf(u8, directive(template, "WorkingDirectory") orelse "", "@TOP@") != null);
}

// spec: Development pipeline - The checked-in systemd unit is the rendered form of the deploy-hook template, so the two cannot drift apart in the directives that matter
test "the checked-in unit matches the template it is rendered from" {
    // The drift that produced DRIFT-INFRA-002 was silent precisely because the
    // two files were never compared: install.sh renders the template, nobody
    // reads the checked-in copy, and it rotted. Render the template the way
    // install.sh does (`sed s|@TOP@|…|g; s|@PORT@|…|g`) using the values the
    // shipped file itself carries, then require the directive sets to match.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const top = directive(shipped, "WorkingDirectory") orelse return error.TestUnexpectedResult;
    const shipped_exec = directive(shipped, "ExecStart") orelse return error.TestUnexpectedResult;
    // A port is what install.sh substitutes; a leftover `@PORT@` placeholder
    // would mean the checked-in copy was never rendered at all.
    const port = execPort(shipped_exec) orelse return error.TestUnexpectedResult;
    try std.testing.expect(execPort(directive(template, "ExecStart").?) == null);

    const with_top = try std.mem.replaceOwned(u8, gpa, template, "@TOP@", top);
    const rendered = try std.mem.replaceOwned(u8, gpa, with_top, "@PORT@", port);
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, '@') == null);

    var want: std.ArrayList([]const u8) = .empty;
    var got: std.ArrayList([]const u8) = .empty;
    try directiveLines(rendered, &want, gpa);
    try directiveLines(shipped, &got, gpa);

    try expectSameLines(want.items, got.items);
}

// spec: Development pipeline - The production unit keeps the restart and autocommit settings that recovered the 2026-07-25 outage and that keep design persistence on the checkpoint timer
test "the production unit keeps its restart and autocommit settings" {
    // These three were each written in response to a real incident, and each
    // is one word away from reverting. Restart=on-failure left prod dead for
    // seven hours after a `pkill` (systemd counts SIGTERM as a clean exit);
    // NETLISP_GIT_AUTOCOMMIT=1 would put a git commit on every MCP tool call.
    for ([_][]const u8{ shipped, template }) |unit| {
        try std.testing.expectEqualStrings("always", directive(unit, "Restart") orelse "");
        try std.testing.expectEqualStrings("simple", directive(unit, "Type") orelse "");
        try std.testing.expectEqualStrings(
            "NETLISP_GIT_AUTOCOMMIT=0",
            directive(unit, "Environment") orelse "",
        );
        // The crash-loop guard: without a burst limit a boot-time failure
        // spins the CPU indefinitely.
        try std.testing.expectEqualStrings("10", directive(unit, "StartLimitBurst") orelse "");
        try std.testing.expectEqualStrings("300", directive(unit, "StartLimitIntervalSec") orelse "");
    }
}

test "directive reads the first real setting and ignores comments" {
    // The comments in both unit files quote directives verbatim while
    // explaining them (`Restart=always, NOT on-failure (2026-07-25)`), so a
    // reader that did not skip comment lines would answer from the prose.
    const unit =
        \\[Service]
        \\# Restart=never would be wrong here
        \\Restart=always
        \\Restart=on-failure
        \\  Type=simple
        \\
    ;
    try std.testing.expectEqualStrings("always", directive(unit, "Restart").?);
    try std.testing.expectEqualStrings("simple", directive(unit, "Type").?);
    // A prefix match is not a key match: `Restart` must not answer `RestartSec`.
    try std.testing.expectEqualStrings("always", directive("RestartSec=2\nRestart=always\n", "Restart").?);
    try std.testing.expect(directive(unit, "ExecStart") == null);
    try std.testing.expect(directive("", "Restart") == null);
}
