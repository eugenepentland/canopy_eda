# Netlisp

*Schematics as S-expressions — written by an agent, compiled to KiCad.*

A CLI-driven electronic design automation tool. Schematics are written
as S-expressions (no GUI capture), built into a live web viewer with
review, ERC, and BOM, and exported to KiCad for PCB layout. The server
also syncs an existing KiCad PCB back to match the design source in place
(`POST /api/sync-kicad-pcb/:name`; see [KiCad sync](#kicad-sync)).

## Quick start

Requires [Zig 0.15.1](https://ziglang.org/download/).

**Prerequisites (a bare clone is not enough):**

- **Guardian** — a sibling `../guardian-zig` checkout next to this repo.
  Guardian is an unpinned relative-path dependency (`build.zig.zon`) that gates
  every build, so clone it alongside `netlisp` first, e.g.
  `git clone <guardian-url> ../guardian-zig`.
- **A designs directory** — `projects/` is gitignored, so `projects/designs`
  is empty on a fresh clone. Point `--project-dir` at your own designs repo (or
  create `projects/designs/{src,lib}` with at least one `.sexp` design) before
  `serve` will show anything.

```bash
zig build
zig build run -- serve --project-dir projects/designs
# open http://localhost:7050
```

`zig build` runs the [Guardian](https://github.com/eugenepentland/guardian-zig)
checks (formatting, file size, boundaries, …) alongside the test suite.

### Production build mode

A plain `zig build` is **Debug** (unpinned — dev/test/mutation keep it that way
for fast iteration). The **deployed** server is pinned to **ReleaseSafe** at the
deploy point (`systemd/netlisp.service`'s `ExecStartPre` rebuilds
`zig build -Doptimize=ReleaseSafe` before serving). The server parses untrusted
input, so ReleaseSafe turns any residual unguarded cast/overflow into a panic
that `Restart=on-failure` recovers in ~2s, rather than the silent UB (a wrong
board) a safety-off build would emit. Editing the unit requires
`systemctl --user daemon-reload && systemctl --user restart netlisp.service` to
take effect; the merge-time deploy rebuild should use the same `-Doptimize=ReleaseSafe`.

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

## Architecture

The pipeline (tokenize → parse → evaluate → build DesignBlock → render
HTML / export KiCad / run ERC) and per-module entry points are
documented in [`CLAUDE.md`](CLAUDE.md). [`SPEC.md`](SPEC.md) tracks the
public function signatures.

## License

[MIT](LICENSE) © 2026 Eugene Pentland.
