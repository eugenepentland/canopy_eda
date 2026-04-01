const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("httpz", httpz.module("httpz"));

    const exe = b.addExecutable(.{
        .name = "eda",
        .root_module = exe_mod,
    });
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

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Guardian — runs on every build
    const guardian_dep = b.dependency("guardian", .{
        .target = target,
        .optimize = optimize,
    });
    const check_exe = guardian_dep.artifact("guardian-check");

    const fmt_check = b.addFmt(.{ .paths = &.{"src"}, .check = true });
    b.getInstallStep().dependOn(&fmt_check.step);
    test_step.dependOn(&fmt_check.step);

    for ([_][]const u8{ "spec", "file-size", "boundaries" }) |cmd| {
        const run = b.addRunArtifact(check_exe);
        run.addArgs(&.{ cmd, ".", "--quiet" });
        run.setCwd(b.path("."));
        b.getInstallStep().dependOn(&run.step);
        test_step.dependOn(&run.step);
    }

    // spec-init: generate starter SPEC.md
    const spec_init_run = b.addRunArtifact(check_exe);
    spec_init_run.addArgs(&.{ "spec-init", "." });
    spec_init_run.setCwd(b.path("."));
    const spec_init_step = b.step("spec-init", "Generate starter SPEC.md from pub fn signatures");
    spec_init_step.dependOn(&spec_init_run.step);

}
