# Canopy EDA

A CLI-driven electronic design automation tool. Schematics are written
as S-expressions (no GUI capture), built into a live web viewer with
review, ERC, and BOM, and exported to KiCad for PCB layout. A separate
Go agent syncs the open KiCad PCB back to the design source.

## Quick start

Requires [Zig 0.15.1](https://ziglang.org/download/).

```bash
zig build
zig build run -- serve --project-dir projects/designs
# open http://localhost:7050
```

`zig build` runs the [Guardian](https://github.com/eugenepentland/canopy_eda/tree/main/.guardian)
checks (formatting, file size, spec drift, …) alongside the test suite.

To rebuild a single design and live-push it to a running server:

```bash
zig build run -- build --project-dir projects/designs --push <design-name>
```

## KiCad sync plugin

The Go agent that syncs an open `.kicad_pcb` from a Canopy EDA design
lives at [`tools/kicad-sync-go/`](tools/kicad-sync-go/) and installs
without cloning the repo:

```bash
go install github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/cmd/eda-kicad-sync@latest
eda-kicad-sync --install-kicad-plugin
```

See [`tools/kicad-sync-go/README.md`](tools/kicad-sync-go/README.md)
for the full setup, OAuth flow, and per-OS plugin paths.

## Architecture

The pipeline (tokenize → parse → evaluate → build DesignBlock → render
HTML / export KiCad / run ERC) and per-module entry points are
documented in [`CLAUDE.md`](CLAUDE.md). [`SPEC.md`](SPEC.md) tracks the
public function signatures.

## License

[MIT](LICENSE) © 2026 Eugene Pentland.
