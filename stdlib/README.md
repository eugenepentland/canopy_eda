# `stdlib/` — the library compiled into the `netlisp` binary

Everything here is embedded into the executable at build time, so a project
directory with **no `lib/` of its own** still evaluates, checks and exports.
`build.zig` globs `stdlib/**/*.sexp` at configure time — adding a file needs no
registration anywhere.

```
stdlib/components/   →  <project>/lib/components/
stdlib/footprints/   →  <project>/lib/footprints/
stdlib/pinouts/      →  <project>/lib/pinouts/
```

`modules/` and `parts/` directories are not shipped; those two library kinds
resolve through the same search order from a project or a shared `--lib-dir`.

## Override order

For every `lib/<sub>/<name>.sexp`, first hit wins, per name:

1. `<project-dir>/lib/<sub>/<name>.sexp` — the project always wins
2. `<lib-dir>/lib/<sub>/<name>.sexp` — `--lib-dir <d>` or `NETLISP_LIB_DIR=<d>`
3. `<stdlib-dir>/<sub>/<name>.sexp` — `NETLISP_STDLIB_DIR=<d>`, laid out like
   this directory
4. this directory, as compiled into the binary

Dropping your own `lib/components/cap-0402.sexp` into a project replaces that
one family and nothing else.

## Contents

* **16 passive families** — `cap-`/`res-`/`ind-0201|0402|0603|0805`,
  `ind-1616`, `ind-2016`, `ferrite-0402`, `led-0402`. These are exactly the
  families the evaluator auto-imports into every design, so they never need an
  `(import …)` line. A test in `src/stdlib.zig` fails if that list and this
  directory disagree.
* **Their land patterns** — one footprint per family.
* **Generic board features** — `testpoint`, `mounting-hole-m2`, and 2.54 mm
  `pin-header-1x2` / `1x4` / `2x5`, each with a pinout.

Nothing here names a manufacturer, declares a `(datasheet …)`, or ships a 3D
model: these are generic parts, and the specific part a board buys is a project
decision.

## Provenance

Every file is written for this repository and carries the netlisp licence.
Nothing is copied from another component library.

The chip land patterns are computed from the IPC-7351B density-level-B
(nominal) equations over each package's published nominal body/terminal
dimensions. Each footprint's header comment states the dimensions, the fillet
goals, the fabrication and placement allowances, the equations and the
courtyard rule it used, so the numbers can be re-derived rather than trusted.
The through-hole and mechanical footprints state their dimensional basis the
same way — drill diameter, annular ring, pitch.

See `docs/standard-library.md` for the full reference.
