//! CLI build worker: evaluate one design/module, collect unified validation,
//! and publish the rendered scene only after strict preflight succeeds.

const std = @import("std");
const bom = @import("../bom.zig");
const diag_format = @import("diag_format.zig");
const env_mod = @import("../eval/env.zig");
const erc_mod = @import("../erc.zig");
const eval_modules = @import("../eval/modules.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const history = @import("history.zig");
const id_insert = @import("../id_insert.zig");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const preflight = @import("../preflight.zig");
const render_json = @import("../render_json.zig");
const serve_root = @import("../serve.zig");

/// One assertion failure surfaced from the evaluator.
pub const AssertionFailure = struct {
    message: []const u8,
    is_warning: bool,
};

/// One non-fatal eval/lint warning surfaced from the evaluator.
pub const BuildWarning = struct {
    line: u32,
    col: u32,
    message: []const u8,
};

const BuildValidation = struct {
    assertions: []const AssertionFailure = &.{},
    erc: []const erc_mod.Violation = &.{},
    profile: preflight.Profile = .authoring,
    findings: []const preflight.Finding = &.{},
    finding_errors: usize = 0,
    finding_warnings: usize = 0,
};

const BuildFailure = struct {
    message: ?[]const u8 = null,
    diagnostic: ?diag_format.Diagnostic = null,
};

/// Result of a `build` CLI call, including the unified validation payload.
pub const BuildReport = struct {
    ok: bool,
    version: u32,
    snapshot: ?[]const u8 = null,
    eval_ok: bool,
    failure: BuildFailure = .{},
    validation: BuildValidation = .{},
    warnings: []const BuildWarning = &.{},

    /// Release the owned structured preflight findings after serialization.
    pub fn deinitPreflight(self: BuildReport, allocator: std.mem.Allocator) void {
        preflight.deinitFindings(allocator, self.validation.findings);
    }
};

const Context = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    profile: preflight.Profile,
    snapshot: ?[]const u8 = null,
};

const Evaluation = union(enum) {
    block: *env_mod.DesignBlock,
    failure: BuildReport,
};

fn failure(ctx: Context, eval_ok: bool, message: []const u8) BuildReport {
    return .{
        .ok = false,
        .version = serve_root.getLiveVersion(ctx.name),
        .snapshot = ctx.snapshot,
        .eval_ok = eval_ok,
        .failure = .{ .message = message },
        .validation = .{ .profile = ctx.profile },
    };
}

fn evaluate(ctx: Context, eval: *Evaluator, path: []const u8) Evaluation {
    const result = eval.evalFile(path) catch |err| {
        const diagnostic = diag_format.load(
            ctx.allocator,
            path,
            @errorName(err),
            eval.last_error,
        ) catch null;
        const message = if (diagnostic) |value|
            (diag_format.formatText(ctx.allocator, value) catch @errorName(err))
        else
            @errorName(err);
        var report = failure(ctx, false, message);
        report.failure.diagnostic = diagnostic;
        return .{ .failure = report };
    };
    return switch (result) {
        .design_block => |block| .{ .block = block },
        else => evaluateModule(ctx, eval),
    };
}

fn evaluateModule(ctx: Context, eval: *Evaluator) Evaluation {
    const result = eval_modules.instantiateStandalone(eval, ctx.name) catch
        return .{ .failure = failure(ctx, false, "not a design-block") };
    return switch (result) {
        .design_block => |block| .{ .block = block },
        else => .{ .failure = failure(ctx, false, "not a design-block") },
    };
}

fn collectAssertions(allocator: std.mem.Allocator, eval: *const Evaluator) []const AssertionFailure {
    var failures: std.ArrayList(AssertionFailure) = .empty;
    for (eval.assertions.items) |assertion| {
        if (!assertion.passed) {
            failures.append(allocator, .{
                .message = assertion.message,
                .is_warning = assertion.is_warning,
            }) catch break;
        }
    }
    return failures.items;
}

fn collectWarnings(allocator: std.mem.Allocator, eval: *const Evaluator) []const BuildWarning {
    var warnings: std.ArrayList(BuildWarning) = .empty;
    for (eval.warnings.items) |warning| {
        warnings.append(allocator, .{
            .line = warning.span.line,
            .col = warning.span.col,
            .message = warning.message,
        }) catch break;
    }
    return warnings.items;
}

fn collectValidation(
    ctx: Context,
    eval: *Evaluator,
    block: *const env_mod.DesignBlock,
    assertions: []const AssertionFailure,
) BuildValidation {
    const erc = erc_mod.runErc(ctx.allocator, block, ctx.project_dir) catch &[_]erc_mod.Violation{};
    const report = preflight.run(ctx.allocator, eval, block, ctx.project_dir, ctx.profile) catch
        return .{
            .assertions = assertions,
            .erc = erc,
            .profile = ctx.profile,
            .finding_errors = 1,
        };
    return .{
        .assertions = assertions,
        .erc = erc,
        .profile = ctx.profile,
        .findings = report.findings,
        .finding_errors = report.errors,
        .finding_warnings = report.warnings,
    };
}

fn validationFailed(validation: BuildValidation) bool {
    if (validation.profile != .preflight) return false;
    if (validation.finding_errors > 0) return true;
    for (validation.erc) |violation| {
        if (violation.severity == .@"error") return true;
    }
    for (validation.assertions) |assertion| {
        if (!assertion.is_warning) return true;
    }
    return false;
}

fn snapshot(ctx: Context) ?[]const u8 {
    return history.snapshot(ctx.allocator, ctx.project_dir, ctx.name, "build") catch |err| {
        log.warn("[snapshot] failed for {s}: {s}", .{ ctx.name, @errorName(err) });
        return null;
    };
}

fn resolveBom(ctx: Context, block: *env_mod.DesignBlock) bool {
    const path = paths.designSiblingPath(ctx.allocator, ctx.project_dir, ctx.name, ".bom") catch
        return false;
    defer ctx.allocator.free(path);
    bom.resolveIdentities(ctx.allocator, block, path, ctx.project_dir) catch |err| {
        log.warn("resolveIdentities {s} failed: {s}", .{ ctx.name, @errorName(err) });
    };
    return true;
}

/// Re-evaluate one design, validate it, and publish its live scene.
pub fn run(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    profile: preflight.Profile,
) BuildReport {
    var ctx = Context{
        .allocator = allocator,
        .project_dir = project_dir,
        .name = name,
        .profile = profile,
    };
    const path = paths.designSourcePath(allocator, project_dir, name) catch
        return failure(ctx, false, "out of memory");
    defer allocator.free(path);
    ctx.snapshot = snapshot(ctx);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const block = switch (evaluate(ctx, &eval, path)) {
        .block => |value| value,
        .failure => |report| return report,
    };
    _ = id_insert.persistMintedIds(allocator, path, &eval);
    const assertions = collectAssertions(allocator, &eval);
    const warnings = collectWarnings(allocator, &eval);
    if (!resolveBom(ctx, block)) {
        var report = failure(ctx, true, "out of memory (bom path)");
        report.validation.assertions = assertions;
        report.warnings = warnings;
        return report;
    }

    const validation = collectValidation(ctx, &eval, block, assertions);
    if (validationFailed(validation)) {
        var report = failure(ctx, true, "preflight failed");
        report.validation = validation;
        report.warnings = warnings;
        return report;
    }

    const layout = render_json.renderSceneGraph(allocator, block, project_dir) catch null;
    serve_root.setLiveLayoutJson(name, layout);
    return .{
        .ok = true,
        .version = serve_root.bumpLiveVersion(name),
        .snapshot = ctx.snapshot,
        .eval_ok = true,
        .validation = validation,
        .warnings = warnings,
    };
}
