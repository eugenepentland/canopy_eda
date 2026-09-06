//! `netlisp serve`'s command line, parsed BEFORE anything is opened.
//!
//! `serve` is the one subcommand whose dispatch has side effects that outlive
//! the process's first millisecond: it creates `<state>/logs/interactions-*.jsonl`,
//! binds a listening socket and then blocks forever. That made it the one
//! subcommand where a typo is unrecoverable rather than diagnostic —
//! `serve --help` started the server, `--port abc` and `--port 99999` silently
//! served on 7050, `--port` with no value did the same, and `--allow-remoote`
//! left the gate on while the operator believed they had turned it off.
//!
//! So the command line is decided here, as a pure function over `args`, and the
//! caller only opens a socket for a `.run`. Every rejection names the argument
//! that caused it; `--help` is answered without touching the filesystem.
//!
//! Deliberately strict: an unrecognised `--flag` and a stray positional are
//! both errors, because `serve` has no positional arguments and a silently
//! ignored flag on a long-running server is a wrong security or port setting
//! that looks like a working one. (`--lib-dir` / `--state-dir` never reach
//! here — `main.zig` consumes those for the whole process before dispatch.)

const std = @import("std");
const serve_mod = @import("serve.zig");

/// The default listening port, and the one the usage banner documents.
pub const default_port: u16 = 7050;

const port_radix: u8 = 10;

/// What the caller should do with the command line it was given.
pub const Parsed = union(enum) {
    /// `--help` / `-h`: print `usage_text` and exit 0. No files, no socket.
    help,
    /// A malformed command line. Print `describe` and exit nonzero.
    invalid: Invalid,
    /// A well-formed command line; start the server with these options.
    run: serve_mod.ServeOptions,
};

/// Why a command line was rejected, with the token that caused it.
pub const Invalid = struct {
    pub const Kind = enum {
        /// A `--flag` `serve` does not accept.
        unknown_flag,
        /// A value-taking flag that was the last argument.
        missing_value,
        /// `--port` whose value is not a decimal number in 1…65535.
        bad_port,
        /// A bare word; `serve` takes no positional arguments.
        unexpected_positional,
    };

    kind: Kind,
    /// The offending argument, or the flag whose value was offending.
    arg: []const u8,
    /// The rejected value for `bad_port`; empty otherwise.
    value: []const u8 = "",

    /// Render the diagnostic into `buf`. Truncates rather than fails: the
    /// caller is on its way to a fatal exit and a clipped sentence beats none.
    pub fn describe(self: Invalid, buf: []u8) []const u8 {
        return switch (self.kind) {
            .unknown_flag => std.fmt.bufPrint(buf, "netlisp serve: unknown option '{s}' (try `netlisp serve --help`)", .{self.arg}),
            .missing_value => std.fmt.bufPrint(buf, "netlisp serve: option '{s}' needs a value", .{self.arg}),
            .bad_port => std.fmt.bufPrint(buf, "netlisp serve: --port '{s}' is not a port number (1-65535)", .{self.value}),
            .unexpected_positional => std.fmt.bufPrint(buf, "netlisp serve: unexpected argument '{s}' (serve takes options only; the project is --project-dir)", .{self.arg}),
        } catch buf[0..@min(buf.len, 0)];
    }
};

/// The `serve`-only help, printed for `--help` / `-h`. The whole-CLI banner in
/// `main.zig` carries the one-line form; this is the same set of flags with
/// what each one does.
pub const usage_text =
    \\netlisp serve — start the local web server (schematic, PCB and review pages)
    \\
    \\Usage:
    \\  netlisp serve [--project-dir <d>] [--port <n>] [--bind <addr>]
    \\                [--auth-dir <d>] [--allow-remote] [--skip-warmup]
    \\
    \\Options:
    \\  --project-dir <d>  Design project to serve (default: the current directory)
    \\  --port <n>         Listening port, 1-65535 (default: 7050)
    \\  --bind <addr>      Interface to bind (default: 127.0.0.1, loopback only)
    \\  --auth-dir <d>     Plugin-token store (default: NETLISP_AUTH_DIR, else <project-dir>/auth)
    \\  --allow-remote     Treat EVERY request as an authenticated admin. Correct
    \\                     only behind a reverse proxy that is itself
    \\                     authenticating callers — it disables netlisp's own gate.
    \\  --skip-warmup      Do not pre-render designs and PCB pages at startup
    \\  -h, --help         Print this and exit without opening logs or a socket
    \\
    \\Runtime state and library flags (--state-dir, --lib-dir) are process-wide;
    \\`netlisp help` documents them.
    \\
;

/// Decide `args` (everything after `serve`) without touching the filesystem.
///
/// `auth_dir_env` is the already-read `NETLISP_AUTH_DIR`, used only when
/// `--auth-dir` is absent, so the environment lookup stays with the caller and
/// this function stays pure.
pub fn parse(args: []const []const u8, auth_dir_env: ?[]const u8) Parsed {
    var options: serve_mod.ServeOptions = .{
        .port = default_port,
        .project_dir = ".",
        .auth_dir = auth_dir_env,
    };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "--skip-warmup")) {
            options.skip_warmup = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-remote")) {
            options.allow_remote = true;
            continue;
        }
        if (valueFlag(arg)) |field| {
            i += 1;
            if (i >= args.len) return .{ .invalid = .{ .kind = .missing_value, .arg = arg } };
            const value = args[i];
            switch (field) {
                .port => {
                    // Zig parses "0" happily and the OS would then choose an
                    // arbitrary ephemeral port; a caller naming a port means it.
                    const parsed = std.fmt.parseInt(u16, value, port_radix) catch 0;
                    if (parsed == 0) return .{ .invalid = .{ .kind = .bad_port, .arg = arg, .value = value } };
                    options.port = parsed;
                },
                .project_dir => options.project_dir = value,
                .bind => options.bind = value,
                .auth_dir => options.auth_dir = value,
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return .{ .invalid = .{ .kind = .unknown_flag, .arg = arg } };
        return .{ .invalid = .{ .kind = .unexpected_positional, .arg = arg } };
    }
    return .{ .run = options };
}

/// Which option a value-taking flag writes to, or null when `arg` takes no value.
const ValueField = enum { port, project_dir, bind, auth_dir };

fn valueFlag(arg: []const u8) ?ValueField {
    if (std.mem.eql(u8, arg, "--port")) return .port;
    if (std.mem.eql(u8, arg, "--project-dir")) return .project_dir;
    if (std.mem.eql(u8, arg, "--bind")) return .bind;
    if (std.mem.eql(u8, arg, "--auth-dir")) return .auth_dir;
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

fn expectInvalid(args: []const []const u8, kind: Invalid.Kind, arg: []const u8) !void {
    const result = parse(args, null);
    try testing.expect(result == .invalid);
    try testing.expectEqual(kind, result.invalid.kind);
    try testing.expectEqualStrings(arg, result.invalid.arg);
}

// spec: Serve CLI - help is answered without opening logs or a socket
test "serve --help and -h are decided before any option takes effect" {
    try testing.expect(parse(&.{"--help"}, null) == .help);
    try testing.expect(parse(&.{"-h"}, null) == .help);
    // Even mixed with real flags, and even when a LATER argument is malformed:
    // discovery must never be turned into a startup by its own typo.
    try testing.expect(parse(&.{ "--project-dir", "x", "--help" }, null) == .help);
    try testing.expect(parse(&.{ "--help", "--port", "abc" }, null) == .help);
}

// spec: Serve CLI - a malformed port is rejected instead of silently serving the default
test "serve rejects malformed and out-of-range ports" {
    try expectInvalid(&.{ "--port", "abc" }, .bad_port, "--port");
    try expectInvalid(&.{ "--port", "99999" }, .bad_port, "--port");
    try expectInvalid(&.{ "--port", "-1" }, .bad_port, "--port");
    try expectInvalid(&.{ "--port", "0" }, .bad_port, "--port");
    try expectInvalid(&.{ "--port", "" }, .bad_port, "--port");
    // The rejected text is reported back so the operator can see their typo.
    const result = parse(&.{ "--port", "70050" }, null);
    try testing.expectEqualStrings("70050", result.invalid.value);
}

// spec: Serve CLI - a value-taking flag with no value is an error, not a default
test "serve rejects a trailing value flag with no value" {
    try expectInvalid(&.{"--port"}, .missing_value, "--port");
    try expectInvalid(&.{"--project-dir"}, .missing_value, "--project-dir");
    try expectInvalid(&.{"--bind"}, .missing_value, "--bind");
    try expectInvalid(&.{"--auth-dir"}, .missing_value, "--auth-dir");
    try expectInvalid(&.{ "--port", "7060", "--bind" }, .missing_value, "--bind");
}

// spec: Serve CLI - an unrecognised flag or stray positional is rejected
test "serve rejects unknown flags and positionals" {
    try expectInvalid(&.{"--allow-remoote"}, .unknown_flag, "--allow-remoote");
    try expectInvalid(&.{"-p"}, .unknown_flag, "-p");
    try expectInvalid(&.{"barracuda-base"}, .unexpected_positional, "barracuda-base");
    // A flag value is never mistaken for a positional.
    try testing.expect(parse(&.{ "--project-dir", "barracuda-base" }, null) == .run);
}

// spec: Serve CLI - a valid command line still produces the same options as before
test "serve accepts every documented flag" {
    const result = parse(&.{
        "--project-dir",  "projects/designs",
        "--port",         "7060",
        "--bind",         "0.0.0.0",
        "--auth-dir",     "/var/auth",
        "--allow-remote", "--skip-warmup",
    }, null);
    try testing.expect(result == .run);
    const options = result.run;
    try testing.expectEqualStrings("projects/designs", options.project_dir);
    try testing.expectEqual(@as(u16, 7060), options.port);
    try testing.expectEqualStrings("0.0.0.0", options.bind);
    try testing.expectEqualStrings("/var/auth", options.auth_dir.?);
    try testing.expect(options.allow_remote);
    try testing.expect(options.skip_warmup);
}

// spec: Serve CLI - the no-argument defaults are unchanged
test "serve with no arguments keeps the documented defaults" {
    const result = parse(&.{}, null);
    try testing.expect(result == .run);
    try testing.expectEqual(default_port, result.run.port);
    try testing.expectEqualStrings(".", result.run.project_dir);
    try testing.expectEqualStrings(serve_mod.default_bind_address, result.run.bind);
    try testing.expect(result.run.auth_dir == null);
    try testing.expect(!result.run.allow_remote);
    try testing.expect(!result.run.skip_warmup);
}

// spec: Serve CLI - NETLISP_AUTH_DIR is the fallback and --auth-dir overrides it
test "serve auth dir falls back to the environment value" {
    try testing.expectEqualStrings("/env/auth", parse(&.{}, "/env/auth").run.auth_dir.?);
    try testing.expectEqualStrings("/flag/auth", parse(&.{ "--auth-dir", "/flag/auth" }, "/env/auth").run.auth_dir.?);
}

// spec: Serve CLI - every rejection renders a diagnostic naming the argument
test "every invalid kind describes itself with the offending argument" {
    var buf: [256]u8 = undefined;
    for (std.enums.values(Invalid.Kind)) |kind| {
        const invalid: Invalid = .{ .kind = kind, .arg = "--marker", .value = "marker-value" };
        const text = invalid.describe(&buf);
        try testing.expect(text.len > 0);
        try testing.expect(std.mem.indexOf(u8, text, "netlisp serve") != null);
        try testing.expect(std.mem.indexOf(u8, text, "marker") != null);
    }
}
