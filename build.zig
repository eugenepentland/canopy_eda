const std = @import("std");
const zt = @import("zt");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const zt_dep = b.dependency("zt", .{
        .target = target,
        .optimize = optimize,
    });

    // Compile .zt → .zig (run before any module that imports them).
    const templates_step = zt.addTemplates(b, zt_dep, &.{
        b.path("src/serve/templates/pages.zt"),
        b.path("src/serve/templates/account.zt"),
        b.path("src/serve/templates/pdf_viewer.zt"),
    });

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("httpz", httpz.module("httpz"));
    exe_mod.addImport("zt", zt_dep.module("zt"));

    const exe = b.addExecutable(.{
        .name = "eda",
        .root_module = exe_mod,
    });
    exe.step.dependOn(templates_step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the eda CLI");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("httpz", httpz.module("httpz"));
    test_mod.addImport("zt", zt_dep.module("zt"));

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    tests.step.dependOn(templates_step);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Guardian — runs on every build. Baseline mode is configured in
    // guardian.toml: every check records existing violations once and
    // only fails when new ones appear, so the full check suite can be
    // turned on without fixing the back-catalogue first.
    const guardian = @import("guardian");
    const guardian_dep = b.dependency("guardian", .{
        .target = target,
        .optimize = optimize,
    });
    const check_exe = guardian_dep.artifact("guardian-check");

    // Generated template files (src/serve/templates/*.zig) are auto-formatted
    // immediately after compilation by `templates_fmt` below — skip them in the
    // strict --check pass so the build doesn't fail on the brief unformatted
    // window between template codegen and the auto-fmt step.
    const fmt_check = b.addFmt(.{
        .paths = &.{"src"},
        .exclude_paths = &.{"src/serve/templates"},
        .check = true,
    });
    fmt_check.step.dependOn(templates_step);
    b.getInstallStep().dependOn(&fmt_check.step);
    test_step.dependOn(&fmt_check.step);

    // Auto-format the zt-generated .zig files so a `zig fmt --check` over the
    // full tree (e.g. by an external CI lint) still passes.
    const templates_fmt = b.addFmt(.{
        .paths = &.{"src/serve/templates"},
        .check = false,
    });
    templates_fmt.step.dependOn(templates_step);
    b.getInstallStep().dependOn(&templates_fmt.step);
    test_step.dependOn(&templates_fmt.step);

    guardian.addAllChecks(b, check_exe, b.getInstallStep(), .{});
    guardian.addAllChecks(b, check_exe, test_step, .{});

    // spec-init: generate starter SPEC.md
    const spec_init_run = b.addRunArtifact(check_exe);
    spec_init_run.addArgs(&.{ "spec-init", "." });
    spec_init_run.setCwd(b.path("."));
    const spec_init_step = b.step("spec-init", "Generate starter SPEC.md from pub fn signatures");
    spec_init_step.dependOn(&spec_init_run.step);

}
