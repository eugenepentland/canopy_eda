# The bundled standard library

`netlisp` ships a small component library compiled into the binary. A project
directory with no `lib/` of its own still evaluates, checks and exports: the
sixteen passive families the evaluator auto-imports, the land patterns those
families name, and a handful of generic board features a first board needs.

It is a starting point, not a catalogue. Real parts — the ICs, connectors and
vendor passives a board actually buys — belong in the project's own `lib/`,
which always wins over the bundle.

## Resolution order

Every `lib/<sub>/<name>.sexp` lookup — components, footprints, pinouts,
modules and parts tables alike — resolves through one place
(`src/stdlib.zig`), in this order:

| # | Where | How it is set |
| --- | --- | --- |
| 1 | `<project-dir>/lib/<sub>/<name>.sexp` | `--project-dir` (default `.`) |
| 2 | `<lib-dir>/lib/<sub>/<name>.sexp` | `--lib-dir <d>`, or `NETLISP_LIB_DIR=<d>` |
| 3 | `<stdlib-dir>/<sub>/<name>.sexp` | `NETLISP_STDLIB_DIR=<d>` |
| 4 | the library compiled into the binary | always present |

The first hit wins, per file. Shadowing is per *name*, not wholesale: dropping
your own `lib/components/cap-0402.sexp` into a project replaces that one family
and leaves every other bundled part in place.

`--lib-dir` names a **project-shaped** directory (it contains a `lib/`), so a
team can keep one shared library beside many boards. `NETLISP_STDLIB_DIR` names
a **`stdlib/`-shaped** directory (it contains `components/`, `footprints/`,
`pinouts/`, … directly) and replaces the compiled-in set for the names it
carries; anything it does not carry still comes from the binary.

Both are read once, at startup, before any command runs — so they apply
uniformly to `build`, `check`, `export-kicad`, `library`, `describe`, `serve`
and everything else.

## What is bundled

Sixteen passive families — the exact list `loadPassivesPrelude` auto-imports
into every design and module, so none of them needs an `(import …)` line:

| Family | Footprint | Parameter |
| --- | --- | --- |
| `cap-0201` `cap-0402` `cap-0603` `cap-0805` | `c-0201` `c-0402` `c-0603` `c-0805` | capacitance |
| `res-0201` `res-0402` `res-0603` `res-0805` | `r-0201` `r-0402` `r-0603` `r-0805` | resistance |
| `ind-0201` `ind-0402` `ind-0603` `ind-0805` | `l-0201` `l-0402` `l-0603` `l-0805` | inductance |
| `ind-1616` `ind-2016` | `l-1616` `l-2016` | inductance |
| `ferrite-0402` | `fb-0402` | impedance |
| `led-0402` | `led-0402` | color |

Plus the generic board features a first board needs, each with its pinout:

| Component | Footprint | What it is |
| --- | --- | --- |
| `testpoint` | `testpoint-1mm` | 1 mm SMD probe pad, no paste |
| `mounting-hole-m2` | `mounting-hole-m2` | M2 plated hole, 2.2 mm drill, 3.8 mm pad |
| `pin-header-1x2` | `pin-header-1x2-2-54mm` | 2-pin 2.54 mm through-hole header |
| `pin-header-1x4` | `pin-header-1x4-2-54mm` | 4-pin 2.54 mm through-hole header |
| `pin-header-2x5` | `pin-header-2x5-2-54mm` | 2x5 2.54 mm through-hole header |

No modules and no parts tables are bundled. `lib/modules/` and `lib/parts/`
resolve through the same order, so a shared `--lib-dir` or a project's own
directory supplies them.

The passive symbols (`generic-cap`, `generic-res`, `generic-ind`, `led`) are
drawn by the renderer, not read from a library file — there is nothing to ship
for them.

## Provenance and licence

Everything under `stdlib/` is written for this repository and carries the
netlisp licence. Nothing was copied from another library.

The chip land patterns are computed from the IPC-7351B density-level-B
(nominal) equations over each package's published nominal dimensions; the
inputs, the equations and the courtyard rule are stated in a comment at the top
of every footprint file, so each number is reproducible rather than asserted.
The through-hole and mechanical footprints record their dimensional basis the
same way (drill diameter, annular ring, pitch). No manufacturer is named, no
`(datasheet …)` is declared, and no vendor PDF, 3D model or parts table is
shipped — the passives are generic by design, because the specific part a board
buys is a project decision.

## Extending or replacing it

* **One part**: add `lib/components/<name>.sexp` (and its footprint/pinout) to
  your project. It shadows the bundled part of that name.
* **A shared library**: keep a project-shaped directory of your own and pass
  `--lib-dir <d>` (or set `NETLISP_LIB_DIR`). It is searched after the project
  and before the standard library.
* **A different standard library**: copy `stdlib/`, edit it, and point
  `NETLISP_STDLIB_DIR` at the copy.
* **Changing what ships**: edit `stdlib/**/*.sexp` in this repository.
  `build.zig` globs the tree at configure time and generates the embedded
  table, so a new file needs no registration — but a new *passive family* must
  also be added to `passives_prelude` in `src/eval/modules.zig`, and a test in
  `src/stdlib.zig` fails if a prelude family, or a footprint one of them names,
  is not bundled.

`test/fixtures/stdlib-smoke/` is a tracked project with no `lib/` at all,
proving the whole path end to end:

```bash
netlisp build       --project-dir test/fixtures/stdlib-smoke stdlib-smoke
netlisp check       --project-dir test/fixtures/stdlib-smoke stdlib-smoke
netlisp export-kicad --project-dir test/fixtures/stdlib-smoke --output-dir /tmp/out stdlib-smoke
```

## How it is delivered

`build.zig` walks `stdlib/` at configure time, copies every `.sexp` into a
generated module directory, and emits a `path → @embedFile(…)` table as the
`stdlib_embed` module. Every artifact that can reach `src/stdlib.zig` imports
it: the `netlisp` executable, both test binaries, the layout bench and the WASM
DRC. So `zig build run`, an installed binary executed from any working
directory, and the unit tests all see the same library with no path discovery
and no install step to forget.

A file served from the table reports a synthetic path,
`netlisp:stdlib/lib/<sub>/<name>.sexp`. It is deliberately not a filename:
callers that keep a read-set of what an evaluation consumed (the page cache,
the fabrication gate's consumed-input digest, the design archive) recognise it
and read it back out of the binary, so a design built against bundled parts
still has a complete, verifiable input closure.
