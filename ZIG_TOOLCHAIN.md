# Pinned Zig toolchains

This repository requires Zig version `0.17.0-dev.1683+5ceec001b`. `build.zig`
rejects any other version, including a later Zig master snapshot. Production is
stricter: both release preparation and deployment require the exact official
compiler binary and SHA-256 below, so a same-version compiler cannot silently
change the generated executable.

Official Linux x86_64 archive:

```text
https://ziglang.org/builds/zig-x86_64-linux-0.17.0-dev.1683+5ceec001b.tar.xz
SHA-256 e6e5c7e0834626bded90cd786d148bebf211dc80b013afefd631472b57b41f77
```

The production host keeps this official archive at
`/home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b` and points
`/home/epentland/.local/bin/zig` at it for ordinary self-hosted Debug work.
Other development machines may use any path; `zig version` must match
`.zigversion` exactly.

Production ReleaseSafe candidates use the reconstructed compiler package:

```text
Path      /home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b-eda-286f77f2-8f4af965/zig
SHA-256   8f4af9650b5358abcdd8a283976d30b5dcdca2b400e44af25953b2e34101e7d4
Source    /home/epentland/ai/canopy/zig-eda-candidate-auto-inline @ 286f77f28e
```

It is not selected through `PATH`: the release and deploy scripts default to
the absolute path above and verify the binary SHA before any gate, candidate
reuse, installation, or restart. The package includes the source commit's
complete `lib/` tree. The compiler host was emitted once with LLVM ReleaseFast,
but it contains no LLVM backend; production application code is emitted by the
self-hosted x86-64 backend.

The experimental source remains in
`/home/epentland/ai/canopy/zig-eda-private`, but it is not production-approved.
The full EDA gate exposed a deterministic router miscompile in both Debug and
ReleaseSafe output from compiler SHA `e3c839e6...`; a later clean-cache rebuild
still failed the same focused test. Keeping that repository available supports
future diagnosis without putting its compiler on the production path.

## Build-mode boundary

All internal EDA work uses Zig's self-hosted Debug backend: application builds,
focused and full tests, dev servers, render/export tools, mutation runs,
solver experiments, and benchmarks. Use plain `zig build`/`zig build test` or
spell `-Doptimize=debug`; do not request LLVM or ReleaseSafe for those tasks.

Self-hosted ReleaseSafe is reserved for the production artifact created by
`.githooks/prepare-release.sh` and installed by the deployment hook. Developers
should invoke the release script, not construct a second
ReleaseSafe binary manually. The prebuilt ReleaseSafe `guardian-check` is a
separate build-gate tool, not an EDA application artifact; it stays optimized
so running the gate does not add roughly 40x overhead to every Debug build.

Only the deployed ReleaseSafe EDA executable is stripped. Because the current
self-hosted backend does not honor the build graph's strip request for this ELF,
`prepare-release.sh` applies `/usr/bin/strip --strip-all` and verifies the
result has no debug or symbol-table sections before publication. Internal
self-hosted Debug artifacts retain symbols. The exact deployed commit is
supplied as
validated runtime candidate metadata rather than embedded as a compiler option,
which lets Zig reuse the verified output when only non-compiler inputs move.

Zig 0.17 renamed build option enum values. Use `-Doptimize=debug`,
`-Doptimize=safe`, `-Doptimize=fast`, and `-Doptimize=small`; only `debug` is a
normal developer choice in this repository. The deploy scripts own `safe`.
Direct compiler commands continue to accept spellings such as `-ODebug`.

Pass `--seed=1` to repeatable build/test gates. The 0.17 maker adds its random
seed to test-runner arguments after `build.zig` configuration, so the previous
in-script seed rewrite is no longer possible; a fixed command-line seed keeps
an unchanged test run cacheable.

## 2026-08-16 production decision

Commit `a54011c1b066ccbf7d995df0446c104c568ab2c4` passed the complete release
gate with the pinned official compiler forced through the self-hosted x86-64
backend. All 79 Guardian checks and the application tests passed, the resulting
binary was stripped, and the candidate metadata recorded compiler SHA-256
`1d314883fd8cf4490c1c29dd73ad8b64e319a8a53c4d9087d1135b52977df37f`.
The exact response JSON matched the deployed LLVM ReleaseSafe binary on all
four benchmark boards.

The canary nevertheless failed the runtime-performance acceptance criterion:

| Artifact | Four-board runtime | Relative to deployed LLVM |
| --- | ---: | ---: |
| Deployed LLVM ReleaseSafe | 0.203349 s | 1.00x |
| Official Zig, self-hosted ReleaseSafe | 0.893649 s | 4.39x slower |
| Historical self-hosted Debug baseline | 0.964540 s | 4.74x slower |

The self-hosted candidate compiled in 15 seconds versus the historical LLVM
ReleaseSafe build's roughly 223 seconds, but it was only 1.08x faster at runtime
than the old Debug baseline and did not approach the 1.5x measured experimental
compiler or the 3x target. `perf` recorded 16.606 billion cycles and 26.215
billion instructions for the candidate versus 2.771 billion cycles and 6.082
billion instructions for the deployed LLVM artifact.

Decision: keep this work on `codex/production-zig-pin`; do not merge, install,
or restart production. Production remains at commit `37ba1bf6` with executable
SHA-256 `7dde59dc08e8591450282c4f5d6aeaf9f1accd7221ec4824dbf8b2402e5fdc10`.
The next candidate must both pass the full correctness gate and close the
runtime gap before rollout.

## 2026-08-16 reconstructed compiler result

The unsafe source was reduced to a reproducible checkpoint at Zig source commit
`e3baa78b1e`. EDA commit `6886c8e93e73ddce92fb67bac124e0d00c558d92`
then passed all 79 Guardian checks and all 2,945 application tests. The exact
release gate built the stripped ReleaseSafe artifact in 11 seconds:

```text
Compiler SHA-256  8f4af9650b5358abcdd8a283976d30b5dcdca2b400e44af25953b2e34101e7d4
Netlisp SHA-256   cac0b3ff67847dd5b00da7c701ce32368512a2e4441fdc3e402537c2df7dc1a2
```

An adjacent seven-repetition, CPU-pinned canary produced identical response
SHA-256 values for all four boards:

| Artifact | Four-board mean | Relative to deployed LLVM |
| --- | ---: | ---: |
| Deployed LLVM ReleaseSafe | 0.204200 s | 1.00x |
| Reconstructed self-hosted ReleaseSafe | 0.726507 s | 3.56x slower |

The reconstruction is 1.23x faster than the official self-hosted candidate and
1.33x faster than the historical 0.964540-second Debug baseline. Hardware
counters recorded 18.642 billion cycles and 30.783 billion instructions for
the reconstruction versus 3.863 billion cycles and 8.449 billion instructions
for deployed LLVM.

Decision: correctness and reproducibility are restored, but the runtime gate
still fails. Keep the reconstructed compiler and EDA pin on their feature
branches; do not merge or deploy this candidate.

## 2026-08-17 retained compiler optimizations

The removed post-checkpoint changes were rebuilt and measured independently.
The work is committed in the Zig worktree
`/home/epentland/ai/canopy/zig-eda-candidate-auto-inline` on branch
`eda-candidate-auto-inline`:

```text
1c3775dc08  x86: retain safe EDA runtime optimizations
001f1a9712  docs: hand off isolated EDA compiler results
```

The retained changes are bounded automatic scalar-leaf inlining and paired
x86-64 `cos`/`sin` lowering. The final LLVM-hosted compiler built from that
tracked source passed the focused router discriminator, all 79 Guardian checks,
and all 2,945 EDA tests. Its tested unstripped SHA-256 is
`86ced2d8adcb348ea5d9639c3b94271b1ae5661d3e2cd17a7d5005cabac9e5ea`.

Alternating 21-request canary windows measured 0.677069 and 0.677919 seconds
per four-board pass, with all four response hashes equal to deployed LLVM. This
is about 7% faster than the 0.726507-second safe checkpoint and about 1.42x the
throughput of the historical Debug build, but still roughly 3.3x slower than
deployed LLVM ReleaseSafe.

Early call-argument death independently reproduced the router miscompile and is
rejected. Pointer-argument pinning and balanced switch lowering were correct but
slower and are also rejected. Full commands, individual measurements, and the
continuation checklist are in that Zig branch's `EDA_COMPILER.md`.

This result is a handoff, not a production cutover. The compiler has not been
packaged or installed, this branch's existing compiler pin has not changed, and
main/production remain untouched. A successor must rebuild and strip from
`1c3775dc08`, package the matching `lib/`, pin the resulting final SHA, run the
exact release gate, and repeat the production canary before considering merge.
