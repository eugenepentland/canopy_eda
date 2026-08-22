# ReleaseSafe build analysis — 2026-08-12

This records the clean-cache measurements behind the production-build update.
All application development, tests, tools, solver work, and profiling continue
to use the pinned Zig `0.17.0-dev.1683+5ceec001b` self-hosted Debug mode. LLVM
ReleaseSafe remains a deployment-only artifact.

## Attribution

Front-end-only ReleaseSafe analysis (`-fno-emit-bin`) took 4.85 s and 448,560
KiB RSS. Emitting optimized LLVM bitcode took 180.44 s and 3,617,628 KiB RSS;
the 71.8 MB bitcode shows LLVM optimization/code generation is the dominant
cost, not Zig semantic analysis. A server-only optimized-bitcode experiment
took 171.96 s, only 8.48 s (4.7%) less, so splitting the CLI from the server
would add architecture and release complexity for little compile-time gain.

## Implemented A/B

The controlled runs used fresh local/global Zig caches and the same source,
toolchain, target, ReleaseSafe optimization, and full application root. The
only changed compiler setting was the root module's strip flag.

| ReleaseSafe application | Wall | Max RSS | Binary |
|---|---:|---:|---:|
| Unstripped baseline | 293.66 s | 4,238,332 KiB | 61,137,016 B |
| Stripped production | 223.11 s | 2,262,192 KiB | 20,515,392 B |
| Improvement | 70.55 s (24.0%) | 1,976,140 KiB (46.6%) | 40,621,624 B (66.4%) |

ReleaseSafe bounds, overflow, and cast checks are unchanged. The deliberate
tradeoff is loss of the production binary's full symbol table; the candidate
commit/build ID and retained failed binary identify the exact source for Debug
reproduction.

The final exact-commit release gate confirmed the build-graph setting: commit
`b3d8b5562` passed 2,551/2,551 self-hosted Debug tests in 73 s and produced a
stripped 20,595,392-byte candidate in 231 s (234 s concurrent wall, 2,308,072
KiB peak RSS for the two jobs). The small difference from the 223.11 s direct
A/B is normal orchestration/source variance; both are about one minute faster
than the 293.66 s unstripped baseline.

## Cache invalidation

The old `build_options.git_hash` made every commit a compiler input, including
docs- and hook-only commits. Commit identity now travels as the candidate's
validated nine-character `build-id` and is installed atomically beside the
binary as `.git/netlisp-deploy-id`; rollback restores the paired ID. Local
Debug artifacts fall back to direct git metadata reads when no deployment ID
exists. Before this update, a cached unchanged release graph completed in 0.27
s. The exact docs-only follow-up confirmed the fix: release preparation reported
1 s for tests, 1 s for the ReleaseSafe build, and 4 s concurrent wall (3.69 s
external wall, 409,572 KiB peak RSS). Its executable SHA-256 was byte-identical
to the code commit's candidate even though its validated runtime `build-id` was
fresh for the new commit.

## Deferred work

Generic comparison sorts account for 563 emitted block-sort helpers and about
1.71 MB (18%) of executable text, but replacing them is a broad runtime change
that needs workload-specific profiling and correctness tests. The embedded
OCCT WASM asset is about 7.6 MB (70% of read-only data) but does not explain the
LLVM optimizer wall. Neither was changed in this low-risk release-build update.
