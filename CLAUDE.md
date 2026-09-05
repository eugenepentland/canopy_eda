# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Mandatory Worktree Rule

Do not edit any project file in the `main` checkout. Before the first write,
create a feature branch in a dedicated `.claude/worktrees/<short-task>`
worktree and perform all edits, generation, builds, tests, Guardian metadata
updates, and commits there. This applies to code, designs, docs, specs, config,
and generated files without exception. See [Worktrees](#worktrees) and the root
`AGENTS.md` for the full procedure.

## Overview

A CLI-driven electronic design automation tool for schematic capture. All design files use S-expression syntax. A single Zig binary (`netlisp`) parses, evaluates, validates, renders, and serves designs.

## Quick Reference

```bash
zig build                    # build (FAILS if docs/language-forms.md is stale)
zig build --seed=1 test      # unit tests + Guardian gate
zig build docs               # regenerate language reference after any DSL change
zig build test-affected      # default dev check: tests affected by your diff
zig build run -- serve --project-dir projects/designs   # web server :7050
scripts/perf_gate.sh         # Four primary-page latency gates vs committed baseline
                             # (pre-push on main runs this; --record re-baselines)
```

- One compiler: the official Zig pinned in `.zigversion`, from PATH. Install it
  with `scripts/install-zig.sh --link` (see ZIG_TOOLCHAIN.md).
- `zig build --seed=1 -Doptimize=safe` is the production-speed build (~1.5x
  Debug at runtime) and takes about half a minute — `-Dllvm` is opt-in and
  turns that into minutes, so do not pass it. Give a side build its own prefix
  (`-p zig-out-dbg`, `-p zig-out-browser-perf`) so it cannot overwrite the
  `zig-out/bin/netlisp` a running server or measurement is executing. Keep
  throwaway prefixes out of /tmp — it has a per-user quota that stale prefixes
  once filled, breaking every tool on the machine.
- Unit-test binary compiles at `-Dtest-opt` (keep Debug); do not pass `-Dtest-opt=safe`.
- IDs are persisted at write time: any surface that writes designs must pin
  minted ids back into `src/<design>.sexp` before deriving uuids
  (full rules: docs/build-and-run.md).

## Architecture

### Pipeline

```
Source (.sexp files)
    → Tokenizer → Parser → AST (nodes with source spans)
    → Evaluator (recursive eval with special forms, builtins, modules)
    → DesignBlock (instances, nets, ports, notes, sections, sub_blocks)
    → Post-build (ID insertion, BOM resolution, assertion checks)
    → Output:
        Schematic: render_html.zig → server-rendered HTML (hub-and-spoke SVG)
        Export: emit.zig (.sexp), export_kicad.zig (KiCad netlist + footprints + STEP models)
        Checks: erc.zig (electrical rules)
```

### Key Modules

**S-expression layer** (`src/sexpr/`): tokenizer → parser → AST. Printer is round-trip capable.

**Evaluator** (`src/eval/`): Split across multiple files:
- `evaluator.zig` — Main eval dispatcher
- `env.zig` — Core types: Value (union type), Env (lexical scope chain), DesignBlock, Instance, Net, Port
- `special_forms.zig` — `let`, `if`, `fmt`, `assert`, `assert-range`
- `modules.zig` — `import` (searches lib/components/ then lib/modules/), `defmodule` with closure capture
- `design_block.zig` — `design-block` evaluation
- `instance.zig` — Instance building + pin-net resolution
- `builders.zig` — Port, note, group, section builders
- `ids.zig` — 8-char hex ID generation, ref-des auto-assignment (prefix-based: C→C1, C2...)
- `builtins.zig` — Arithmetic, comparison, logic operators
- `fmt.zig` — String formatting (~V voltage, ~R resistance, ~C capacitance, ~A amperage, ~S string)

**Schematic rendering** (`src/render_html.zig` + `src/render_svg/`): Converts DesignBlock to an HTML page with inline SVG. Hub/spoke model: Hubs = ICs/connectors (U/J/P/X/Q prefix, rendered as boxes). Spokes = passives (R/C/L/F/D prefix, rendered inline on connections). Grid layout from sections. `src/render_json.zig` still emits a scene-graph JSON (`/api/scene-graph/:name`) used by the live-push pipeline. `src/render_system_svg.zig` + `src/render_block_types.zig` produce the system-overview SVG embedded in the page header (auto-categorised columns: mcu, power, memory, peripheral, connector, etc.).

**Checks**: `erc.zig` (duplicate ref-des, floating nets, unconnected pins, voltage mismatches, missing decoupling).

**Export**: `emit.zig` (flattened .sexp), `export_kicad.zig` + `export_kicad_netlist.zig` + `export_kicad_footprint.zig` + `export_kicad_model.zig` (KiCad netlist + footprints + STEP models — the bridge for handing schematic edits off to KiCad's PCB editor).

**Web server** (`src/serve.zig` + `src/serve/`): Serves the schematic viewer (with design-review panels embedded inline in the schematic page). Live update via version polling. JSON scene graph state protected by mutex.

**Docs generator** (`src/docgen.zig`): Renders `docs/language-forms.md` from the language's dispatch tables (forms registry, fmt directives, SI suffixes, classifier keywords). CLI: `netlisp gen-language-docs [--output <path>] [--check]`; build steps: `zig build docs` (regenerate), `--check` runs on every build/test.

### Component System

- **component-family**: Parameterized (e.g., `(cap "100nF" "np0")`) — `is_family: true`
- **component**: Fixed part (e.g., `(res-0402)`)
- Both cached in `component_cache: StringHashMap(ComponentData)`
- Import searches `lib/components/` then `lib/modules/` for `.sexp` files

## Conventions

- **Error handling**: `EvalError` enum propagated via `try`/`catch`. No panics. File load failures degrade gracefully.
- **Memory**: Uses `page_allocator` globally. File contents are never freed (AST slices reference source buffers).
- **Spans**: Every AST Node carries `span: Span` (line, col, byte offset) — used for ID insertion and error reporting.
- **Test tags**: Tests use `// spec: Section - Behavior` comments mapping to SPEC.md entries.
- **Strings**: All `[]const u8` slices into source or allocated buffers. Equality via `std.mem.eql(u8, ...)`.

## Reference Docs

Read the relevant file before working in that area — they are the canonical, complete versions of what used to live here:

- `docs/build-and-run.md` — full build / run / deploy reference incl. design-build, push, release-build rules, ID-persistence rules
- `docs/build-system.md` — build graph internals
- `docs/sexpr-language.md` — design language spec — read before editing .sexp designs
- `docs/webserver-api.md` — web server API reference — read before touching server endpoints
- `docs/auth.md` — the local-first auth model (loopback admin, plugin tokens, `--bind`, `--allow-remote`)
- `docs/testing-guide.md` — full testing guide: filters, test-compile, test-affected, mutation tiers
- `docs/worktrees.md` — worktree workflow details
