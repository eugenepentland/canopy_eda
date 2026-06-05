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
        b.path("src/serve/templates/oauth.zt"),
        b.path("src/serve/templates/library.zt"),
        b.path("src/serve/templates/auth.zt"),
        b.path("src/serve/templates/mcp_docs.zt"),
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

    // Slim PCB-layout optimizer benchmark. Its module pulls in only the
    // optimizer + evaluator (no httpz/zt, no serve/render/diagram stack), so an
    // edit to placement/optimizer.zig rebuilds a fraction of the full `eda`
    // exe — the fast inner loop for perf experiments. The `bench-layout` step
    // deliberately does NOT depend on Guardian, fmt-check, or the templates, so
    // a throwaway SoA/SIMD variant builds cleanly without baseline churn.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_layout.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench-layout",
        .root_module = bench_mod,
    });
    const bench_install = b.addInstallArtifact(bench_exe, .{});
    const bench_step = b.step("bench-layout", "Build the slim PCB-layout optimizer benchmark");
    bench_step.dependOn(&bench_install.step);

    // Slim PCB-layout *scoring* sensitivity / fuzz harness. Same minimal module
    // shape as bench-layout (optimizer + evaluator only, no Guardian/templates),
    // but it sweeps a part through fine sub-grid x/y/rotation steps and re-scores
    // via `optimizer.scorePoses` to map where the objective is non-smooth.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz_layout.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz-layout",
        .root_module = fuzz_mod,
    });
    const fuzz_install = b.addInstallArtifact(fuzz_exe, .{});
    const fuzz_step = b.step("fuzz-layout", "Build the PCB-layout scoring sensitivity/fuzz harness");
    fuzz_step.dependOn(&fuzz_install.step);

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
    // Build guardian-check optimized regardless of the design's build mode. It's
    // a tool we *run* (54 single-pass checks over the whole src/ tree), not code
    // we ship, so a Debug guardian-check would run ~11s every build vs ~1s here.
    // ReleaseSafe (not ReleaseFast) keeps bounds/overflow checks in guardian's
    // parser for ~0.4s more — worth it for a build gate we trust to be correct.
    const guardian_dep = b.dependency("guardian", .{
        .target = target,
        .optimize = .ReleaseSafe,
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
