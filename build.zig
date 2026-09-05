const std = @import("std");
const zt = @import("zt");
const builtin = @import("builtin");
/// The `zig build test` shard partition. Data only — no imports — so pulling it
/// into the build script cannot drag src/ into the build graph.
const test_shards = @import("src/test_shards.zig");

pub const required_zig_version = "0.17.0-dev.1683+5ceec001b";

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, required_zig_version)) {
        std.debug.panic(
            "netlisp requires Zig {s}; found {s}. See ZIG_TOOLCHAIN.md (scripts/install-zig.sh installs it).",
            .{ required_zig_version, builtin.zig_version_string },
        );
    }
    const target = b.standardTargetOptions(.{});
    // Default mode is Debug (unpinned): dev/test/mutation builds stay Debug for
    // fast iteration, so the optimize mode is deliberately NOT pinned globally
    // here. The PRODUCTION build is pinned separately at the deploy point —
    // `zig build -Doptimize=safe` in the verified release-preparation hook.
    // Rationale: the server parses untrusted
    // input, so a safety-off build (ReleaseFast/Small) turns any remaining
    // unguarded cast/overflow into silent UB — a wrong board — whereas
    // ReleaseSafe makes it a panic that systemd `Restart=always` recovers in
    // ~2s. See the cast-safety campaign (numeric.checkedInt / int_from_float).
    const optimize = b.standardOptimizeOption(.{});

    // The full unit-test binary (`zig build test`) gets its OWN optimize mode,
    // independent of `-Doptimize`, via `-Dtest-opt` (default Debug). Zig
    // 0.17.0-dev.1683 makes the representative self-hosted Debug optimizer
    // workload 3.09x faster than Zig 0.15.1 (43.53s vs 134.47s) while keeping
    // the much cheaper Debug compile. That reverses the old whole-suite
    // tradeoff which required ReleaseSafe just to keep solver tests usable.
    // The option remains available as a low-level diagnostic escape hatch, but
    // repository policy is self-hosted Debug for every internal test; only the
    // deployment pipeline builds the netlisp application with self-hosted ReleaseSafe.
    // This affects ONLY the `test` binary below; the main artifact, bench,
    // wasm, and `test-fast` keep honoring `-Doptimize`.
    const test_opt = b.option(
        std.builtin.OptimizeMode,
        "test-opt",
        "Optimize mode for the full unit-test binary only (repository workflow uses debug)",
    ) orelse .debug;

    // Ad-hoc subset runner for the full `test` binary: `-Dtest-filter=<substr>`
    // (repeatable) forwards to the compiler's --test-filter, so only tests whose
    // name contains one of the substrings are analyzed, compiled, and run.
    // Verifying a handful of new tests otherwise costs a whole suite wall.
    // Unset = the empty filter list = today's behaviour exactly: everything runs.
    // This is a DEVELOPER convenience on the `test` step alone; the mutation
    // smoke tier below keeps its own hardcoded, stable filter set (Guardian's
    // per-mutant tier depends on that set not moving), and no gated step passes
    // this option, so a filtered run can never narrow the gate.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only unit tests whose name contains this substring (repeatable; `test` step only, default: run all)",
    ) orelse &.{};

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const ward_mod = b.createModule(.{
        .root_source_file = b.path("vendor/ward/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zt_dep = b.dependency("zt", .{
        .target = target,
        .optimize = optimize,
    });

    // Guardian — runs on every build. Baseline mode is configured in
    // guardian.toml: every check records existing violations once and
    // only fails when new ones appear, so the full check suite can be
    // turned on without fixing the back-catalogue first.
    //
    // Resolved HERE, above the test modules, because every test binary below is
    // compiled with Guardian's counting test runner (see `test_runner`).
    //
    // Build guardian-check optimized regardless of the design's build mode. It's
    // a tool we *run* (88 checks over the whole src/ tree) on EVERY build, not
    // code we ship, so its run time is paid per build while its compile is paid
    // once per build cache. ReleaseSafe (not ReleaseFast) keeps bounds/overflow
    // checks in guardian's parser — worth it for a gate we trust to be correct.
    //
    // Guardian is a `.url`+`.hash` package (build.zig.zon), so there is no
    // sibling checkout with a `zig-out/bin/guardian-check` for `addAllChecks`
    // to reuse: a fresh cache COMPILES it. ReleaseSafe means LLVM with the
    // official toolchain, and that compile dominates a cold build. Measured on
    // this tree (fresh ZIG_LOCAL_CACHE_DIR, warm package cache), cold `zig
    // build` / steady-state rebuild:
    //
    //   .safe, LLVM (this configuration)   1m45s / 8.5s
    //   .safe, check_exe.use_llvm = false   1m13s /  70s
    //   .debug                              1m09s /  71s
    //
    // The self-hosted and Debug binaries compile ~35s faster ONCE and then cost
    // ~60s of gate on EVERY build (guardian's `concept` check alone goes 1s →
    // 30s), so the slow cold compile is the right trade: pay it once per cache,
    // keep every later build at ~8s.
    //
    // Escape hatches, neither needed for a plain clone:
    //   * `GUARDIAN_PREBUILT=<path>/guardian-zig/zig-out/bin/guardian-check`
    //     reuses an already-built binary from a LOCAL guardian checkout and
    //     skips the compile (cold build 1m45s → 17s — worth exporting if you
    //     spin up worktrees often, since each build cache pays the compile
    //     once). It stays honest: the `guardian-selfcheck` step makes that
    //     binary re-derive the source digest of the FETCHED package and fail
    //     the build unless the checkout is exactly the pinned tag.
    //   * `GUARDIAN_PREBUILT=off` forces the compile back on.
    const guardian = @import("guardian");
    const guardian_dep = b.dependency("guardian", .{
        .target = target,
        .optimize = .safe,
    });
    const check_exe = guardian_dep.artifact("guardian-check");

    // Guardian's counting test runner, used by EVERY test binary here.
    // `-Dtest-filter` and `test-fast`'s hardcoded filter set are both applied by
    // the COMPILER, so a filter matching nothing produces an empty test binary
    // that exits 0 — output-identical to a green suite. This runner prints
    // `guardian/test: N test(s) selected` before the first test and FAILS a run
    // whose filters named nothing. `.mode = .server` keeps the build system's
    // progress display, per-test failure attribution, and --fuzz support.
    const test_runner = guardian.testRunner(guardian_dep);

    // Compile .zt → .zig (run before any module that imports them).
    const templates_step = zt.addTemplates(b, zt_dep, &.{
        b.path("src/serve/templates/pages.zt"),
        b.path("src/serve/templates/pdf_viewer.zt"),
        b.path("src/serve/templates/library.zt"),
    });

    // Template generation writes source files, so it must finish formatting
    // before any compiler or Guardian process can read the tree. Keeping this
    // as one predecessor fixes fresh-worktree races where those consumers used
    // to run beside generation/formatting and observe missing or partial files.
    const templates_fmt = b.addFmt(.{
        .paths = &.{b.path("src/serve/templates")},
        .check = false,
    });
    templates_fmt.step.dependOn(templates_step);
    const templates_ready = b.step("templates", "Generate and format the zt templates");
    templates_ready.dependOn(&templates_fmt.step);
    const templates_prepared = b.option(
        bool,
        "templates-prepared",
        "Trust the checked-in generated templates (release orchestration only)",
    ) orelse false;
    const prepared_templates = b.step(
        "templates-prepared",
        "Use templates prepared and cleanliness-checked by release orchestration",
    );
    const template_predecessor = if (templates_prepared)
        prepared_templates
    else
        &templates_fmt.step;

    // Client-side WASM DRC. Compiles the SAME placement/drc.zig engine to
    // wasm32-freestanding (the fs/eval paths in optimizer.zig are lazily skipped
    // by Zig's analysis) and exposes a JSON bridge (src/wasm_drc.zig) so the
    // browser can run the design-rule check locally, off the server. Always
    // ReleaseSmall and target-fixed, independent of the host build mode. The
    // artifact is embedded into the server binary (the `drc.wasm` anonymous
    // import on exe_mod/test_mod below) and served at /static/drc.wasm.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_drc.zig"),
        .target = wasm_target,
        .optimize = .small,
    });
    const wasm_drc = b.addExecutable(.{
        .name = "drc",
        .root_module = wasm_mod,
    });
    wasm_drc.entry = .disabled; // -fno-entry: a library of exports, not a program
    wasm_drc.rdynamic = true; // keep the @export'd wasm_alloc/drc_check + memory
    const wasm_bin = wasm_drc.getEmittedBin();
    const wasm_install = b.addInstallArtifact(wasm_drc, .{});
    const wasm_step = b.step("wasm-drc", "Build the client-side WASM DRC (drc.wasm)");
    wasm_step.dependOn(&wasm_install.step);

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Deployment is the only ReleaseSafe application build. Strip that
    // artifact to avoid spending roughly a minute emitting 40 MiB of symbols;
    // every internal self-hosted Debug artifact keeps its debugging metadata.
    exe_mod.strip = optimize == .safe;
    exe_mod.addImport("httpz", httpz.module("httpz"));
    exe_mod.addImport("ward", ward_mod);
    exe_mod.addImport("zt", zt_dep.module("zt"));
    // Embed the compiled drc.wasm so static_assets.zig can @embedFile it.
    exe_mod.addAnonymousImport("drc.wasm", .{ .root_source_file = wasm_bin });

    // Codegen backend for the `netlisp` executable. The pinned official Zig
    // ships LLVM, but every optimized build here goes through the self-hosted
    // x86-64 backend by default: LLVM turns a seconds-long ReleaseSafe compile
    // into a multi-minute one, which is why releases (and any local
    // `-Doptimize=safe`) are self-hosted. `-Dllvm` opts a build back into LLVM
    // when the faster *runtime* is worth the slow compile — it is not used by
    // any gate, release, or deploy path. Debug leaves the choice to the
    // compiler default (also self-hosted on this target).
    const use_llvm = b.option(
        bool,
        "llvm",
        "Emit the netlisp executable through LLVM instead of the self-hosted backend (much slower compile)",
    ) orelse false;

    const exe = b.addExecutable(.{
        .name = "netlisp",
        .root_module = exe_mod,
        .use_llvm = if (use_llvm) true else if (optimize == .debug) null else false,
    });
    exe.step.dependOn(template_predecessor);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the netlisp CLI");
    run_step.dependOn(&run_cmd.step);

    // Slim PCB-layout optimizer benchmark. Its module pulls in only the
    // optimizer + evaluator (no httpz/zt, no serve/render/diagram stack), so an
    // edit to placement/optimizer.zig rebuilds a fraction of the full `netlisp`
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

    // Tests — compiled at `-Dtest-opt` (default Debug), NOT `-Doptimize`.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = test_opt,
    });
    test_mod.addImport("httpz", httpz.module("httpz"));
    test_mod.addImport("ward", ward_mod);
    test_mod.addImport("zt", zt_dep.module("zt"));
    test_mod.addAnonymousImport("drc.wasm", .{ .root_source_file = wasm_bin });
    addDeployUnitImports(b, test_mod);

    const test_step = b.step("test", "Run unit tests");
    // A real listener catches route-registration and Ward HTTP protocol drift
    // that request-double tests cannot see. Uses isolated temporary state.
    const ward_hosting_test = b.addSystemCommand(&.{"python3"});
    ward_hosting_test.addFileArg(b.path("scripts/test_ward_hosting.py"));
    ward_hosting_test.addArtifactArg(exe);
    test_step.dependOn(&ward_hosting_test.step);
    const ward_client_tests = b.addTest(.{ .root_module = ward_mod });
    const ward_client_run = b.addRunArtifact(ward_client_tests);
    test_step.dependOn(&ward_client_run.step);
    addTreePolicyChecks(b, test_step);
    // SHARDED. `test` compiles one test binary per shard in src/test_shards.zig
    // and runs them concurrently — the build system executes independent steps
    // in parallel (default `-j` = core count), so the suite's 78s serial test
    // wall becomes the wall of its slowest shard. Every shard is the SAME
    // module (src/test_root.zig), the SAME optimize mode and the SAME Guardian
    // runner; only the compiler's `--test-filter` set differs, and the manifest
    // partitions the tree so each named test is compiled into exactly one
    // shard. See src/test_shards.zig for the invariant and the test in
    // src/test_root.zig that enforces it.
    //
    // Sharding is skipped for `-Dtest-filter=...`: the developer subset runner
    // has to stay one binary whose selection is exactly what the flag said, and
    // intersecting a hand-typed filter with a shard's filter list is the kind of
    // silent narrowing this repository does not allow near the test step.
    if (test_filters.len != 0) {
        addTestShard(b, test_step, test_mod, test_runner, template_predecessor, test_filters, null);
    } else {
        for (test_shards.shards, 0..) |shard_filters, shard_index| {
            addTestShard(b, test_step, test_mod, test_runner, template_predecessor, shard_filters, shard_index);
        }
    }

    // test-compile: the middle tier between a filtered `zig build test` and the
    // full gate. Compiles the WHOLE test binary (no filters, ever) and runs
    // none of it, so `-fno-emit-bin` applies and the compiler stops after
    // semantic analysis. This is the tier whose absence let two commits land on
    // a suite that would not compile: `test-fast` only ever type-checks the 8
    // filters below, so a production call site can change and its own stale
    // test is never analyzed. Deliberately NOT a dependency of `test` — making
    // it one would re-analyze the whole suite on every filtered run and erase
    // the reason to filter. It IS part of `[gate] test_command` (guardian.toml).
    const compile_probe = guardian.addTestCompileProbe(b, .{
        .root_module = test_mod,
        .test_runner = test_runner,
    });
    // The probe compiles src/test_root.zig, which imports the zt-generated
    // src/serve/templates/*.zig, so template codegen has to be a true
    // PREDECESSOR of it — see `orderProbeAfter` below, called once
    // `templates_fmt` exists. addTestCompileProbe returns the top-level step, so
    // the ordering has to be applied to its dependencies (the probe's compile
    // step); hanging it off the top-level step would let codegen and the compile
    // run as concurrent siblings.

    // Mutation smoke tier. Guardian runs this focused set first for each
    // mutant, then still runs the complete test suite for every smoke survivor.
    // A smoke failure therefore saves a full ~70s suite without weakening the
    // final verdict. Keep the filters focused on small fail-closed boundary
    // cases that commonly kill mutants quickly.
    //
    // Stays on `-Doptimize` (Debug by default), deliberately NOT `-Dtest-opt`:
    // the mutation tier REBUILDS this binary for every mutant, so the slower
    // ReleaseSafe compile would multiply across ~8-100 mutants. Its filtered set
    // is small fail-closed boundary cases (no solver work) and already runs in
    // ~2.3s Debug, so it gains nothing from ReleaseSafe at runtime — the
    // per-mutant incremental compile cost is what matters here.
    const fast_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fast_test_mod.addImport("httpz", httpz.module("httpz"));
    fast_test_mod.addImport("ward", ward_mod);
    fast_test_mod.addImport("zt", zt_dep.module("zt"));
    fast_test_mod.addAnonymousImport("drc.wasm", .{ .root_source_file = wasm_bin });
    addDeployUnitImports(b, fast_test_mod);

    // ─────────────────────────────────────────────────────────────────────
    // BUNDLED STANDARD LIBRARY — self-contained region, see `stdlibEmbed`.
    //
    // `stdlib/**/*.sexp` is compiled INTO every artifact as the module
    // `stdlib_embed`, so a `netlisp` binary carries the component families,
    // footprints and pinouts a first design needs and a project directory
    // with no `lib/` of its own still evaluates. Every module that can reach
    // `src/stdlib.zig` needs the import — the exe, both test binaries, the
    // slim layout bench, and the wasm DRC (which pulls in
    // placement/geometry.zig). See docs/standard-library.md.
    // ─────────────────────────────────────────────────────────────────────
    const stdlib_embed = stdlibEmbed(b);
    for ([_]*std.Build.Module{ exe_mod, test_mod, fast_test_mod, bench_mod, wasm_mod }) |mod| {
        mod.addAnonymousImport("stdlib_embed", .{ .root_source_file = stdlib_embed });
    }
    // ───────────────────────── end bundled standard library ──────────────

    //
    // Hoisted to a named const because the runner is told the same list twice:
    // once as the compiler's `--test-filter` set, once as the filter texts
    // `announceFilters` forwards. A rename here that matched nothing would
    // otherwise produce an empty, silently-green smoke tier — and this tier
    // gates every mutant.
    const smoke_filters: []const []const u8 = &.{
        "parse rejects excessively deep nesting",
        "fuzz: parser never crashes",
        "modulo rejects non-positive divisor",
        "checkedInt rejects",
        "designSiblingPath rejects",
        "sanitizeKicadName neutralizes traversal",
        "route flags grid overflow",
        "mcpSetPartPoses rejects an empty poses array",
    };
    const fast_tests = b.addTest(.{
        .name = "mutation-smoke",
        .root_module = fast_test_mod,
        .filters = smoke_filters,
        .test_runner = test_runner,
    });
    fast_tests.step.dependOn(template_predecessor);
    const run_fast_tests = b.addRunArtifact(fast_tests);
    run_fast_tests.setCwd(b.path("."));
    guardian.announceFilters(run_fast_tests, smoke_filters);
    const fast_test_step = b.step("test-fast", "Run the mutation smoke-test subset");
    fast_test_step.dependOn(&run_fast_tests.step);

    // Generated template files (src/serve/templates/*.zig) are auto-formatted
    // immediately after compilation by `templates_fmt` below — skip them in the
    // strict --check pass so the build doesn't fail on the brief unformatted
    // window between template codegen and the auto-fmt step.
    const fmt_check = b.addFmt(.{
        .paths = &.{b.path("src")},
        .exclude_paths = &.{b.path("src/serve/templates")},
        .check = true,
    });
    fmt_check.step.dependOn(template_predecessor);
    b.getInstallStep().dependOn(&fmt_check.step);
    test_step.dependOn(&fmt_check.step);

    b.getInstallStep().dependOn(template_predecessor);
    test_step.dependOn(template_predecessor);

    // A plain `zig build` runs Guardian's external gates, which spawn `node`
    // and `python3` themselves — so the host probe guards the default step
    // too, not just `test`'s tree-policy checks.
    b.getInstallStep().dependOn(addHostPrereqCheck(b));

    // Order the compile-only probe behind template codegen AND its auto-fmt.
    // Behind codegen because the probe compiles src/test_root.zig, which imports the
    // generated files; behind the fmt because otherwise `zig build test-compile`
    // regenerates those files and leaves them unformatted in the tree, which
    // reds Guardian's `formatting` check on the very next gate run — a
    // standalone tier must leave the tree exactly as it found it.
    orderProbeAfter(compile_probe, template_predecessor);

    const gate_ordering: guardian.Options = .{
        .prerequisites = &.{template_predecessor},
    };
    guardian.addAllChecks(b, check_exe, b.getInstallStep(), gate_ordering);
    guardian.addAllChecks(b, check_exe, test_step, gate_ordering);

    // Auto-generated language reference (docs/language-forms.md).
    // `zig build docs` regenerates it from the evaluator's dispatch
    // tables; the --check twin runs on every `zig build test` (with an
    // explicit cwd, so it can't silently skip the way a cwd-dependent
    // unit test could) and fails when the committed file is stale.
    const docs_gen_run = b.addRunArtifact(exe);
    docs_gen_run.addArgs(&.{"gen-language-docs"});
    docs_gen_run.setCwd(b.path("."));
    docs_gen_run.has_side_effects = true;
    const docs_step = b.step("docs", "Regenerate docs/language-forms.md from the form dispatch tables");
    docs_step.dependOn(&docs_gen_run.step);

    const docs_check_run = b.addRunArtifact(exe);
    docs_check_run.addArgs(&.{ "gen-language-docs", "--check" });
    docs_check_run.setCwd(b.path("."));
    docs_check_run.has_side_effects = true;
    test_step.dependOn(&docs_check_run.step);
    b.getInstallStep().dependOn(&docs_check_run.step);

    // spec-init: generate starter SPEC.md
    const spec_init_run = b.addRunArtifact(check_exe);
    spec_init_run.addArgs(&.{ "spec-init", "." });
    spec_init_run.setCwd(b.path("."));
    const spec_init_step = b.step("spec-init", "Generate starter SPEC.md from pub fn signatures");
    spec_init_step.dependOn(&spec_init_run.step);

    // INVARIANT: validating must never write the install prefix. A `zig build
    // test` (or a filtered subset run) has to be safe to fire while a long
    // measurement or a live server is executing `zig-out/bin/netlisp`, so the
    // test steps must not reach an install step — otherwise a 20-second
    // validation would relink the executable underneath a 13-minute run.
    //
    // It holds today by construction: the test steps depend only on compile /
    // run / fmt steps, `docs_check_run` executes the exe straight out of the
    // build cache rather than the installed copy, and Guardian's addAllChecks
    // re-orders artifact installs only when the step it is wired onto IS the
    // install step. All of that is easy to undo by accident with one
    // `dependOn(b.getInstallStep())`, so the property is asserted at configure
    // time rather than left as a comment. See CLAUDE.md > Testing.
    assertDoesNotInstall(test_step, "test");
    assertDoesNotInstall(fast_test_step, "test-fast");
    assertDoesNotInstall(compile_probe, "test-compile");
    addAffectedTestStep(b);
}

/// Compiles and runs ONE shard of the unit-test suite and hangs it off
/// `test_step`. `filters` is the shard's `--test-filter` set; an empty set is
/// the whole suite (what a single-binary `zig build test` used to be).
///
/// Every shard shares `test_mod`, so a shard cannot drift from the suite's
/// module graph, optimize mode, or root file: the only per-shard input is the
/// filter list, and `src/test_shards.zig` is proven to partition the tree.
/// Make the shipped systemd unit and its deploy-hook template readable from a
/// test. `@embedFile` cannot escape the module root (`src/`), so the two files
/// come in as anonymous imports instead. Tests only — `src/deploy_unit.zig`
/// asserts the two agree and that neither ExecStart points at `zig-out/bin`,
/// the path any local `zig build` overwrites and the cause of the 2026-08-19
/// Debug-in-prod incident. Adding them here also makes an edit to either file
/// re-run the suite.
fn addDeployUnitImports(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("netlisp.service", .{
        .root_source_file = b.path("systemd/netlisp.service"),
    });
    mod.addAnonymousImport("netlisp.service.in", .{
        .root_source_file = b.path(".githooks/netlisp.service.in"),
    });
}

fn addTestShard(
    b: *std.Build,
    test_step: *std.Build.Step,
    test_mod: *std.Build.Module,
    test_runner: std.Build.Step.Compile.TestRunner,
    template_predecessor: *std.Build.Step,
    filters: []const []const u8,
    shard_index: ?usize,
) void {
    const guardian = @import("guardian");
    const tests = b.addTest(.{
        .root_module = test_mod,
        .filters = filters,
        .test_runner = test_runner,
    });
    tests.step.dependOn(template_predecessor);
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    // Tells the shard which row of the manifest it IS, so the unnamed
    // integrity block in src/test_root.zig can hold the compiler to that row.
    // Absent for `-Dtest-filter`, whose selection no manifest row describes.
    if (shard_index) |index| {
        run_tests.setEnvironmentVariable("NETLISP_TEST_SHARD", b.fmt("{d}", .{index}));
    }
    // Tell the runner what the filter texts were — Zig never passes them to a
    // test runner, so without this it can only detect a completely empty binary
    // and an unnamed `test { }` block would pad the count of a zero-match run.
    // Per shard this is what turns "my filter matched nothing" from a silent
    // green run into a failure.
    guardian.announceFilters(run_tests, filters);
    test_step.dependOn(&run_tests.step);
}

/// The checks that guard what no Zig test can see: which browser assets have a
/// gate and whether they parse, whether the JavaScript unit tests still pass,
/// and whether every closed audit finding still names a live regression test.
///
/// All of these are ALSO declared as `[[external]]` gates in guardian.toml, and
/// that declaration is not what runs them. Measured 2026-08-29: an external
/// whose command exits nonzero does not block — `guardian-check all` reports
/// "0 blocking" with the audit-ledger checker failing under it, and so does
/// `zig build test`. Every `[[external]]` in this tree is advisory today,
/// including the twenty-one `node --check` asset gates, which is how a
/// syntax error in any browser asset rode a green build. Hanging them off the
/// `test` step is what makes them real, following `test-affected`'s precedent;
/// the guardian.toml entries stay, because they still declare these files to
/// the green-run digest and because they are the right home once that path is
/// fixed. See AUDIT-LEDGER.toml DRIFT-INFRA-004.
fn addTreePolicyChecks(b: *std.Build, test_step: *std.Build.Step) void {
    // Every check below spawns `node` or `python3`. Order them behind the
    // host-prerequisite probe so a machine without them reports what to
    // install instead of a bare "unable to spawn" from whichever gate lost the
    // race.
    const prereqs = addHostPrereqCheck(b);
    const checks = [_][]const []const u8{
        // `--syntax` parses every first-party asset with Node here, because
        // the `node --check` externals that were supposed to do it do not run.
        &.{ "python3", "scripts/check_js_asset_gates.py", "--syntax" },
        &.{ "python3", "scripts/check_js_asset_gates_test.py" },
        &.{ "python3", "scripts/check_audit_ledger.py" },
        &.{ "python3", "scripts/check_audit_ledger_test.py" },
        // Guardian blocks on a failing [[external]] again as of guardian-zig
        // 0453ca0; for an unknown stretch before that it did not, and all 45
        // gates here were decorative. Nothing in this tree could have noticed,
        // because a gate that never fires looks exactly like one that cannot.
        &.{"scripts/check_external_gates_armed.sh"},
        // One compiler, from PATH, pinned by `.zigversion` — asserted against
        // the release/deploy scripts, build.zig's backend default and the
        // systemd unit. It used to be a manual-only script that nothing ran
        // (AUDIT-LEDGER.toml), which is how the private-compiler pin it
        // guarded went unnoticed; it has a home now.
        &.{"scripts/test_production_toolchain_pin.sh"},
        // JavaScript unit-test runners. Each was declared as an
        // external and therefore ran nowhere — which put shape_sketch.test.js
        // back in exactly the state DRIFT-INFRA-003 described, "a unit test
        // wired to NOTHING". All three exit 0 with a pass line today.
        &.{ "node", "src/serve/assets/shape_sketch.test.js" },
        &.{ "node", "src/serve/assets/pcb_3d_surface.test.js" },
        &.{ "node", "src/serve/assets/system_cad.test.js" },
        &.{ "node", "scripts/test_pcb_region.js" },
        &.{ "node", "scripts/gerber_measure_snap_test.mjs" },
        &.{ "node", "scripts/perf_host_idle.test.js" },
    };
    for (checks) |argv| {
        const run = b.addSystemCommand(argv);
        run.setCwd(b.path("."));
        // Each reads the tree it is judging, so nothing about it is cacheable
        // by output hash — and a skipped policy check is the failure mode
        // these exist to prevent.
        run.has_side_effects = true;
        run.step.dependOn(prereqs);
        test_step.dependOn(&run.step);
    }
}

/// The `node` / `python3` probe a newcomer's first build hits before anything
/// else spawns them. Guardian's `[[external]]` gates alone shell out to `node`
/// 47 times and to `python3` four times on a plain `zig build`, and a missing
/// interpreter surfaces there as an unattributed external-gate failure. This
/// says "install Node 20+ / Python 3.11+" in one line instead. Returns the run
/// step so callers can order real work behind it.
fn addHostPrereqCheck(b: *std.Build) *std.Build.Step {
    const run = b.addSystemCommand(&.{"scripts/check_host_prereqs.sh"});
    run.setCwd(b.path("."));
    // It probes the machine, not the tree: nothing here is cacheable by output
    // hash, and a skipped probe is exactly the confusing failure it prevents.
    run.has_side_effects = true;
    return &run.step;
}

/// Developer-only changed-file selector. The script starts a nested filtered
/// `zig build test` followed by `test-compile`; the release gate never calls
/// this step and remains unfiltered.
fn addAffectedTestStep(b: *std.Build) void {
    const self_test = b.addSystemCommand(&.{ "python3", "scripts/test_affected_test.py" });
    self_test.setCwd(b.path("."));
    const run = b.addSystemCommand(&.{ "python3", "scripts/test_affected.py" });
    run.setCwd(b.path("."));
    run.step.dependOn(&self_test.step);
    if (b.option([]const u8, "affected-base", "Git revision test-affected compares against")) |base| {
        run.addArgs(&.{ "--base", base });
    }
    if (b.option(bool, "affected-list", "Print the affected-test plan without running it") orelse false) {
        run.addArg("--list");
    }
    if (b.option(bool, "affected-full", "Force test-affected to run the complete Debug suite") orelse false) {
        run.addArg("--full");
    }
    const step = b.step("test-affected", "Run conservatively affected Debug tests, then analyze the whole suite");
    step.dependOn(&run.step);
}

/// Makes `predecessor` run before the compile(s) behind a `test-compile` probe
/// step. `guardian.addTestCompileProbe` returns the TOP-LEVEL step, and a step
/// runs after its dependencies but its dependencies run in parallel with each
/// other — so ordering has to be applied one level down, to the probe's compile
/// step, or codegen and the compile it feeds become concurrent siblings.
fn orderProbeAfter(probe_step: *std.Build.Step, predecessor: *std.Build.Step) void {
    for (probe_step.dependencies.items) |dep| dep.dependOn(predecessor);
}

/// Panics at configure time if `step`'s dependency closure reaches a step that
/// writes the install prefix (`zig-out/`). Used to keep the test steps
/// non-installing, so validating a tree cannot swap the binary underneath a
/// running measurement. `name` is the user-facing step name for the message.
fn assertDoesNotInstall(step: *std.Build.Step, name: []const u8) void {
    for (step.dependencies.items) |dep| {
        switch (dep.tag) {
            .install_artifact, .install_file, .install_dir => std.debug.panic(
                "build.zig: the `{s}` step must not write zig-out/ (it reaches install step '{s}'). " ++
                    "Validation runs while a measurement or server executes zig-out/bin/netlisp; " ++
                    "see CLAUDE.md > Testing.",
                .{ name, dep.name },
            ),
            else => assertDoesNotInstall(dep, name),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// BUNDLED STANDARD LIBRARY — self-contained region.
// ─────────────────────────────────────────────────────────────────────────

/// Compile `stdlib/**/*.sexp` into the binary as the `stdlib_embed` module.
///
/// The repository's `stdlib/` mirrors a project's `lib/` one level up
/// (`stdlib/components/…` ↔ `<project>/lib/components/…`), so this generates
/// a path→bytes table keyed on the PROJECT-relative sub-path — the same key
/// `src/stdlib.zig` is asked for after a project's own `lib/` misses.
///
/// Embedding rather than installing a directory is what makes the single
/// binary self-contained: `zig build run`, an installed `netlisp` executed
/// from any working directory, and the unit tests all see the same table with
/// no path discovery and no install step to forget. A user who wants to swap
/// the bundled set for their own points `NETLISP_STDLIB_DIR` at a directory
/// laid out like `stdlib/`; that is checked before the table.
///
/// The files are COPIED into the generated module's directory and reached with
/// `@embedFile`, because `@embedFile` cannot escape a module root — reading
/// their bytes here at configure time instead would work but would put the
/// whole library through the build script on every `zig build`. The copies are
/// `LazyPath`s onto the real files, so editing a `.sexp` re-runs the step.
fn stdlibEmbed(b: *std.Build) std.Build.LazyPath {
    const io = b.graph.io;
    var dir = b.root.root_dir.handle.openDir(io, "stdlib", .{ .iterate = true }) catch |err|
        std.debug.panic("build.zig: cannot open stdlib/: {t}", .{err});
    defer dir.close(io);

    var rel_paths: std.ArrayList([]const u8) = .empty;
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err|
        std.debug.panic("build.zig: cannot walk stdlib/: {t}", .{err})) |entry|
    {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".sexp")) continue;
        rel_paths.append(b.allocator, b.dupe(entry.path)) catch @panic("OOM");
    }
    // Directory order is undefined; sort so the generated table — and every
    // cache key derived from it — is a function of the tree alone.
    std.mem.sort([]const u8, rel_paths.items, {}, lessThanStdlibPath);

    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator,
        \\//! Generated by build.zig from stdlib/ — do not edit.
        \\//! One row per bundled library file, keyed on the project-relative
        \\//! sub-path `src/stdlib.zig` resolves. Sorted by that key.
        \\
        \\pub const Entry = struct {
        \\    /// e.g. "lib/components/cap-0402.sexp"
        \\    path: []const u8,
        \\    bytes: []const u8,
        \\};
        \\
        \\pub const entries = [_]Entry{
        \\
    ) catch @panic("OOM");
    for (rel_paths.items) |rel| {
        _ = wf.addCopyFile(b.path(b.fmt("stdlib/{s}", .{rel})), rel);
        src.appendSlice(b.allocator, b.fmt(
            "    .{{ .path = \"lib/{s}\", .bytes = @embedFile(\"{s}\") }},\n",
            .{ rel, rel },
        )) catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return wf.add("stdlib_embed.zig", src.items);
}

fn lessThanStdlibPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
