# The Zig toolchain

netlisp builds with one compiler: the official Zig master snapshot named in
[`.zigversion`](.zigversion).

```text
0.17.0-dev.1683+5ceec001b
```

`build.zig` compares `builtin.zig_version_string` against that file's contents
and refuses to configure on anything else, including a *newer* master snapshot.
The release and deploy scripts check `zig version` against the same file before
they start a build.

## Why it is pinned this exactly

Zig master has no stability guarantee: language, `std`, and build-system APIs
change between nightlies, and this tree tracks a snapshot rather than a release
because it depends on 0.17's self-hosted x86-64 backend for fast optimized
builds. A floating "latest master" would break the build on an arbitrary day
for reasons unrelated to any change here, so the snapshot is pinned and moved
deliberately (see [Bumping the pin](#bumping-the-pin)).

## Other prerequisites

`zig build` is not self-contained: the build graph and the Guardian gate shell
out to a few host tools. `scripts/check_host_prereqs.sh` runs first on every
build and names whichever is missing.

| Tool | Version | Why |
| --- | --- | --- |
| Zig | exactly `.zigversion` | The compiler. |
| Node.js | ≥ 20 | 47 Guardian external gates (`node --check` over the browser assets) plus the JS unit-test runners wired into `zig build test`. |
| Python | ≥ 3.11 | `scripts/check_audit_ledger.py` and `scripts/check_js_asset_gates.py`; 3.11 is where `tomllib` entered the standard library. |
| git | any recent | Guardian's process gates and the release/deploy hooks read repository state. |
| `strip`, `readelf` (binutils) | any recent | `prepare-release.sh` strips the deployed executable and verifies no symbols remain. Release only. |
| Playwright | optional | Only the browser performance scripts under `scripts/*_perf/` (`npm install`). |

## Install

```sh
scripts/install-zig.sh --link
```

That downloads the archive for your host, verifies its SHA-256 against the
checked-in table [`scripts/zig-toolchain.sha256`](scripts/zig-toolchain.sha256),
extracts it to `~/.local/share/netlisp/zig/<version>/`, and symlinks
`~/.local/bin/zig` at it. Without `--link` it prints the `export PATH=…` line
instead. Re-running it is a no-op once the right version is installed.

- `ZIG_INSTALL_DIR` overrides the install root.
- Supported hosts: linux and macOS on x86_64 and aarch64. On Windows, or if you
  would rather not run the script, install by hand below.

Check it worked:

```sh
zig version            # must print exactly the contents of .zigversion
zig build --seed=1     # builds netlisp
```

## Manual install

Download the archive for your platform, verify its SHA-256, extract it, and put
the resulting directory on `PATH`.

The repository mirrors the archives as assets of the GitHub release
[`toolchain-0.17.0-dev.1683`](https://github.com/eugenepentland/netlisp/releases/tag/toolchain-0.17.0-dev.1683),
because `ziglang.org/builds/` is a rotating nightly directory: it serves this
snapshot today and may drop it at any time. Both sources are the same bytes, so
either verifies against the same checksum.

```text
Mirror    https://github.com/eugenepentland/netlisp/releases/download/toolchain-0.17.0-dev.1683/<archive>
Upstream  https://ziglang.org/builds/<archive>
```

| Platform | Archive | SHA-256 |
| --- | --- | --- |
| linux x86_64 | `zig-x86_64-linux-0.17.0-dev.1683+5ceec001b.tar.xz` | `e6e5c7e0834626bded90cd786d148bebf211dc80b013afefd631472b57b41f77` |
| linux aarch64 | `zig-aarch64-linux-0.17.0-dev.1683+5ceec001b.tar.xz` | `b18bd9c61b751ec64982359f85c3d4aec3347f4988b9edbfc15a14c055452eee` |
| macOS x86_64 | `zig-x86_64-macos-0.17.0-dev.1683+5ceec001b.tar.xz` | `2b154b47ce5396c000260c06c8cf018a4bf22dd5f858fc8538e27f2012d86536` |
| macOS aarch64 | `zig-aarch64-macos-0.17.0-dev.1683+5ceec001b.tar.xz` | `1081a0318a97f492aaca1b76c4e6fe1ce5cd586a212ee2c0db364b05a29b5870` |
| Windows x86_64 | `zig-x86_64-windows-0.17.0-dev.1683+5ceec001b.zip` | `f5291dff1dec0ff16bffec0427b0a2b8629080cf2b89d55721b59eef988d3090` |

`scripts/zig-toolchain.sha256` holds the same sums in `sha256sum -c` format.

## Build modes

| Mode | Command | Backend | What it is for |
| --- | --- | --- | --- |
| Debug (default) | `zig build --seed=1` | self-hosted | All development and every test. |
| ReleaseSafe | `zig build --seed=1 -Doptimize=safe` | self-hosted | Releases, dev servers you actually interact with, benchmarks. |
| ReleaseSafe + LLVM | `zig build --seed=1 -Doptimize=safe -Dllvm` | LLVM | Opt-in only: a faster binary for a much longer compile. |

The pinned compiler ships LLVM, but netlisp does **not** use it by default:
`-Dllvm` defaults to false, so every optimized build goes through Zig's
self-hosted x86-64 backend. Measured on this tree (cold per-mode build cache,
warm global cache, 2026-09-05):

| Build | Wall | Installed binary |
| --- | ---: | ---: |
| Debug, self-hosted | 18.3 s | 448 MB |
| ReleaseSafe, self-hosted | 24.3 s | 162 MB |
| ReleaseSafe, `-Dllvm` | 300.0 s | 29 MB |

That is the whole reason the default is self-hosted: LLVM makes the same
optimized build **12.3x** slower to compile. Reach for `-Dllvm` only when a
measurement needs the faster generated code and you can wait; no gate, release,
or deploy path passes it.

(The size column is the *installed* binary. `build.zig` asks for a stripped
ReleaseSafe artifact and LLVM honors it; the self-hosted backend currently does
not, which is why `prepare-release.sh` runs `strip --strip-all` itself and
verifies the result.)

Mode notes:

- Backend selection is a *compiler* flag, not a build-runner flag.
  `zig build -fno-llvm` / `-fllvm` are invalid; use `-Dllvm` with `zig build`,
  or `-fno-llvm`/`-fllvm` with a direct `zig build-exe`.
- Zig 0.17 spells build-option optimize modes in lowercase: `-Doptimize=debug`,
  `safe`, `fast`, `small`. Direct compiler commands keep `-ODebug`,
  `-OReleaseSafe`, and so on.
- Pass `--seed=1` to any repeatable build or test gate. Zig 0.17 appends its
  random seed to the test runner's arguments after `build.zig` configuration,
  so a fixed command-line seed is what keeps an unchanged test run cacheable.

## The release artifact

`.githooks/prepare-release.sh` builds the one ReleaseSafe artifact that gets
deployed. It takes `zig` from `PATH` (override with `$ZIG`), fails loudly if
`zig version` is not the pinned string, and records the compiler binary's
SHA-256 alongside the candidate. That SHA is a *fingerprint*, not a second pin:
nothing requires a particular value, but it keys the per-tree build caches and
the candidate's provenance, so artifacts emitted by two different builds of the
same version can never be reused for each other.

Only that deployed executable is stripped — `prepare-release.sh` runs
`strip --strip-all` and verifies no `.debug_*`/`.symtab` sections remain,
because the self-hosted backend does not currently honor the build graph's
strip request for this ELF. Every internal Debug artifact keeps its symbols.

## Bumping the pin

Moving to a newer master snapshot is a deliberate change, not a maintenance
chore. The steps:

1. Put the new version string in `.zigversion` and in `required_zig_version` in
   `build.zig`.
2. Download every platform archive for the new version from
   `https://ziglang.org/builds/`, and regenerate the checksum table:

   ```sh
   sha256sum zig-*-<new-version>.* >>scripts/zig-toolchain.sha256
   ```

   Replace the old rows and update the `# Version:` header line, then update
   the table in this file to match.
3. Publish the archives as assets of a new GitHub release tagged
   `toolchain-<version without the +hash>` (e.g. `toolchain-0.17.0-dev.1683`).
   `scripts/install-zig.sh` derives that tag from `.zigversion`, so nothing in
   the script needs editing.
4. Install it (`scripts/install-zig.sh --link`) and run the full gate:
   `zig build --seed=1 test`. Expect real work here — a master bump usually
   moves `std` APIs.
5. Re-measure the build-mode table above if the timings shifted noticeably.

The dependency graph in `build.zig.zon` (httpz, zt, ward, guardian) is pinned
separately and generally has to move with the compiler.
