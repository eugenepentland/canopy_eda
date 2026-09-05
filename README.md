# Netlisp

*Schematics as S-expressions, written by an agent, compiled to KiCad.*

Netlisp is a command-line electronic design automation tool. A design is a
set of `.sexp` text files, not a drawing: you (or an agent) write the
schematic as S-expressions, and one binary evaluates it into a live web
viewer with electrical rule checks, a BOM, PCB placement and routing with
design-rule checks, Gerber and KiCad export, and design-review reports.
There is no GUI capture step; the browser is a viewer and review surface.

- **Language:** a small S-expression DSL with components, parameterised
  component families, modules with closures, nets inferred from pin
  connections, sections, assertions and formatting directives.
  See [docs/sexp-language.md](docs/sexp-language.md) and the generated
  reference [docs/language-forms.md](docs/language-forms.md).
- **Outputs:** HTML schematic with inline SVG, ERC and requirement checks,
  BOM resolution, PCB layout (placement, autorouting, copper pours, DRC),
  Gerber/drill fabrication packages, KiCad netlist + footprints + a full
  hierarchical `.kicad_sch` project, PDF reviews, thermal FEM cases.
- **Agent-first:** every operation is a structured CLI tool with a JSON
  schema (`netlisp tool list`), so an agent can drive the whole flow
  without a browser or a server.

Status: early public release. Linux x86_64 is the platform the test suite
runs on. Toolchain archives for macOS and aarch64 Linux are mirrored, but
those builds are untested.

## Prerequisites

| Tool | Version | Needed for |
| --- | --- | --- |
| Zig | exactly the snapshot in [`.zigversion`](.zigversion) | everything; `scripts/install-zig.sh` installs it |
| Node.js | 20 or newer | build-time asset gates and JS unit tests run by `zig build` |
| Python | 3.11 or newer | two build-time policy checks (`tomllib`) |
| git | any recent | build-identity stamps and the Guardian gate |

Optional: `strip`/`readelf` (binutils) for release builds, Playwright for the
browser performance scripts, KiCad 8 for the board sync workflows, and
ElmerSolver for thermal comparisons. See
[ZIG_TOOLCHAIN.md](ZIG_TOOLCHAIN.md) for the full toolchain story.

## Quick start

```bash
git clone https://github.com/eugenepentland/netlisp.git
cd netlisp
scripts/install-zig.sh --link     # downloads and verifies the pinned Zig
zig build --seed=1                # first build fetches the Guardian gate once (network), ~2 min cold
zig build run -- serve --project-dir test/fixtures/stdlib-smoke
```

Open <http://127.0.0.1:7050>. The server binds loopback and treats local
requests as an admin, so nothing needs configuring for a laptop. The first
`zig build` downloads one dependency (the
[Guardian](https://github.com/eugenepentland/guardian-zig) code-quality gate,
pinned by URL and hash in `build.zig.zon`); every later build is offline.
Cold builds compile that gate at ReleaseSafe, warm rebuilds take seconds.

## Your first project

A project is a directory with `src/` holding designs and an optional `lib/`
holding your own components, footprints, pinouts and modules:

```text
my-board/
  src/
    my-board.sexp
  lib/            # optional; overrides the bundled library entry by entry
    components/
    footprints/
    modules/
```

Common passives (chip capacitors, resistors, inductors, ferrites and LEDs in
0201 to 0805 packages) come from the **bundled standard library**, so a
first design needs no library at all. Anything in your project's `lib/`
takes precedence over the bundled copy, `--lib-dir` (or `NETLISP_LIB_DIR`)
adds a shared library between the two, and `NETLISP_STDLIB_DIR` swaps the
bundled set for a directory of your own. The passive families need no
`(import …)`; test points, mounting holes and pin headers do. See
[docs/standard-library.md](docs/standard-library.md).

[`test/fixtures/stdlib-smoke`](test/fixtures/stdlib-smoke) is a complete
minimal project. Build it, check it, and hand it to KiCad:

```bash
zig build run -- build --project-dir test/fixtures/stdlib-smoke stdlib-smoke
zig build run -- check --project-dir test/fixtures/stdlib-smoke --profile preflight stdlib-smoke
zig build run -- export-kicad --project-dir test/fixtures/stdlib-smoke \
    --output-dir out/kicad --with-schematic stdlib-smoke
```

`netlisp help` lists every command; `netlisp reference [section]` prints the
language grammar from the binary itself.

## Driving it from an agent

Every structured operation is available locally with no server:

```bash
zig build run -- tool list
zig build run -- tool run_checks --project-dir my-board \
    --args '{"name":"my-board","profile":"preflight"}'
zig build run -- tool get_pcb_layout_image --project-dir my-board \
    --args '{"name":"my-board"}' --output my-board.png
```

Use `--args-file request.json` for larger requests. Text results go to
stdout; image tools return base64 JSON unless `--output` is given. The
tool schemas are the contract an agent should read first.

## Serving beyond localhost

Netlisp has no accounts, sessions or passwords. It binds `127.0.0.1`, admits
a loopback request that did not pass through a proxy as an admin, and
answers everything else with `403`. To publish it, put an authenticating
reverse proxy in front and start the server with `--allow-remote`, which
makes **every** request it receives an admin. `--bind <addr>` widens the
listening socket. Details and the plugin-token path for the KiCad sync
endpoint are in [docs/auth.md](docs/auth.md).

## Building and testing

```bash
zig build --seed=1                       # Debug, self-hosted backend (default)
zig build --seed=1 -Doptimize=safe       # ReleaseSafe, still self-hosted, ~25 s
zig build --seed=1 -Doptimize=safe -Dllvm  # opt into LLVM codegen, minutes
zig build --seed=1 test                  # full suite plus the Guardian gate, ~5 min
zig build test-affected                  # only the tests your diff touches
zig build docs                           # regenerate docs/language-forms.md after a DSL change
```

`zig build` and `zig build test` fail when `docs/language-forms.md` is stale
or when Guardian finds a new violation; `guardian-check explain <check>`
says why. [docs/build-and-run.md](docs/build-and-run.md),
[docs/build-system.md](docs/build-system.md) and
[docs/testing-guide.md](docs/testing-guide.md) cover the build graph, test
filters, sharding and mutation tiers.

## KiCad round trips

The schematic is canonical; the board is updated to match. Declare
`(kicad-pcb "<path>")` in a design and use **Push to KiCad PCB** in the
schematic viewer (`POST /api/sync-kicad-pcb/:name`): the server diffs the
board against the flattened netlist and rewrites it in place, preserving
placements, pad nets and field values, with new instances staged per
section.

For the reverse direction, the design's **PCB Layout** page offers **Sync
from KiCad**, which previews mismatches and then imports the board's
placement, tracks, vias and outline as the design's starred layout. The
same import runs without a browser:

```bash
zig build run -- import-kicad-layout --project-dir my-board stdlib-smoke
```

## Documentation

- [docs/architecture.md](docs/architecture.md): what the tool does and how the pipeline fits together
- [docs/sexp-language.md](docs/sexp-language.md): the design language, with [docs/language-forms.md](docs/language-forms.md) as the machine-checked reference
- [docs/standard-library.md](docs/standard-library.md): the bundled components and how overrides resolve
- [docs/webserver-api.md](docs/webserver-api.md): every HTTP route and structured tool
- [docs/auth.md](docs/auth.md): the local-only security model
- [ZIG_TOOLCHAIN.md](ZIG_TOOLCHAIN.md): the pinned compiler, mirrors and checksums
- [AGENTS.md](AGENTS.md) and [CLAUDE.md](CLAUDE.md): how agents and contributors are expected to work in this repository (worktrees, Guardian, the spec ledger)

## License

[MIT](LICENSE) © 2026 Eugene Pentland. Vendored Zig packages under
`vendor/` and the browser libraries under `src/serve/assets/` keep their
own licenses.
