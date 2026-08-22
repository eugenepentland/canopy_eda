# Netlisp

*Schematics as S-expressions — written by an agent, compiled to KiCad.*

A CLI-driven electronic design automation tool. Schematics are written
as S-expressions (no GUI capture), built into a live web viewer with
review, ERC, and BOM, and exported to KiCad for PCB layout. The server
also syncs an existing KiCad PCB back to match the design source in place
(`POST /api/sync-kicad-pcb/:name`; see [KiCad sync](#kicad-sync)).

## Quick start

Requires exactly **Zig `0.17.0-dev.1683+5ceec001b`**. See
[ZIG_TOOLCHAIN.md](ZIG_TOOLCHAIN.md) for the official archive URL, checksum,
installation convention, and the Zig 0.17 build-option spellings. The build
rejects a different compiler so a moving master snapshot cannot silently
change the application or its dependencies.

**Prerequisites (a bare clone is not enough):**

- **Guardian** — a sibling `../guardian-zig` checkout next to this repo.
  Guardian is an unpinned relative-path dependency (`build.zig.zon`) that gates
  every build, so clone it alongside `netlisp` first, e.g.
  `git clone <guardian-url> ../guardian-zig`.
- **Ward** — a sibling `../../ward` checkout providing session-cookie and
  OAuth-bearer verification. It is also a relative-path dependency and must be
  checked out at the Zig-master-compatible revision used by this repository.
- **A designs directory** — `projects/` is gitignored, so `projects/designs`
  is empty on a fresh clone. Point `--project-dir` at your own designs repo (or
  create `projects/designs/{src,lib}` with at least one `.sexp` design) before
  `serve` will show anything.

```bash
zig build --seed=1
zig build run -- serve --project-dir projects/designs
# open http://localhost:7050
```

`zig build` runs the [Guardian](https://github.com/eugenepentland/guardian-zig)
checks (formatting, file size, boundaries, …) alongside the test suite.

Every structured automation operation is available locally through the CLI;
no server connection is required:

```bash
zig build run -- tool list
zig build run -- tool run_checks --project-dir projects/designs \
  --args '{"name":"my-board","profile":"preflight"}'
zig build run -- tool get_pcb_layout_image --project-dir projects/designs \
  --args '{"name":"my-board"}' --output my-board.png
```

Use `--args-file request.json` for larger JSON requests. Text results are
written directly to stdout; image tools return base64 JSON unless `--output`
is supplied, in which case the decoded image is written there.

### Build-mode policy

Use the self-hosted **Debug** build for every internal workflow: application
development, tests (including the full suite), dev servers, render/export
tools, mutation testing, solver work, and benchmarks. A plain `zig build` is
Debug; write `-Doptimize=debug` only when an explicit spelling helps. Do not
manually build ReleaseSafe for development or internal benchmarking.

The sole EDA ReleaseSafe build belongs to the deployment boundary.
`.githooks/prepare-release.sh` creates it with the pinned official compiler and
forces its self-hosted x86-64 backend while the Debug test suite runs. The
deploy hook validates the exact compiler and candidate SHA-256 before atomically
installing it; systemd only
runs that verified artifact and never compiles during restart. The server parses
untrusted input, so ReleaseSafe turns any residual unguarded cast/overflow into
a panic that `Restart=always` recovers in ~2s, rather than the silent UB (a
wrong board) a safety-off build would emit. Editing the unit requires
`systemctl --user daemon-reload && systemctl --user restart netlisp.service` to
take effect; production builds must go through `.githooks/prepare-release.sh`.

That production executable is explicitly stripped and then inspected before
publication; this keeps ReleaseSafe's runtime safety checks while omitting
symbols that are useful only during development. Debug applications, tests,
tools, and benchmarks remain unstripped. Deployment supplies the exact
nine-character commit ID at runtime
from checksum-verified candidate metadata, so changing only docs or release
plumbing no longer injects a new git hash into the compiler cache key.

To rebuild a single design and live-push it to a running server:

```bash
zig build run -- build --project-dir projects/designs --push <design-name>
```

## KiCad sync

The schematic is canonical; the board is updated to match. Open a design's
schematic viewer and use the **Push to KiCad PCB** button — the server reads
the `.kicad_pcb` declared by the design's `(kicad-pcb "<path>")` form, diffs
it against the flattened netlist, and writes the updated board in place
(`POST /api/sync-kicad-pcb/:name`). Footprint placements, pad nets, and field
values are preserved; new instances land in a per-section staging area.

For the reverse review workflow, declare the same `(kicad-pcb "<path>")`, open
the design's **PCB Layout** page, and choose **Sync from KiCad**. The editor
first previews footprint/net mismatches, dropped copper, unusual vias, zones,
and outline fallbacks. Confirming imports the board's placement, routed tracks,
vias, and Edge.Cuts into the EDA tool as its starred layout, then reloads the
PCB review. The KiCad board is opened read-only; the previous EDA layout is
saved in layout history. KiCad zones and keepouts are reported but are not
currently imported as rendered copper.

The same inbound operation is available without a browser:

```bash
zig build run -- import-kicad-layout --project-dir projects/designs <design>

# Recover layouts that survive only in history/ or git and append them as named rows
zig build run -- backfill-layouts --project-dir projects/designs [--dry-run] [--limit <n>]
```

## Architecture

The pipeline (tokenize → parse → evaluate → build DesignBlock → render
HTML / export KiCad / run ERC) and per-module entry points are
documented in [`CLAUDE.md`](CLAUDE.md). [`SPEC.md`](SPEC.md) tracks the
public function signatures.

## License

[MIT](LICENSE) © 2026 Eugene Pentland.
