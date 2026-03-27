# EDA Tool

## Overview

A CLI-driven electronic design automation tool for schematic capture. All design files use S-expression syntax. A single Zig binary (`eda`) parses, evaluates, validates, renders, and serves designs.

## Build & Run

```bash
# Build
zig build

# Run tests
zig build test

# Start web server
zig build run -- serve --project-dir projects/designs --port 9000

# Build a design (stdout)
zig build run -- build --project-dir projects/designs --push <design-name>

# Convert KiCad files
zig build run -- convert-footprint <file.kicad_mod>
zig build run -- convert-symbol <file.kicad_sym> [--filter <name>]
```

## Project Structure

```
eda/
  src/
    main.zig              # CLI entry point
    sexpr/                # S-expression parser
      tokenizer.zig       # Lexer: atoms, strings, ints, floats, units, comments
      parser.zig          # Recursive descent parser → AST
      printer.zig         # Pretty-printer (round-trip capable)
      ast.zig             # Node types with source spans
    eval/                 # Design evaluator
      evaluator.zig       # Main eval: imports, modules, design-blocks, assertions
      env.zig             # Types: Value, Env, DesignBlock, Instance, Net, Port, Part
      builtins.zig        # Arithmetic, comparison, logic operators
      fmt.zig             # String formatting (~V, ~R, ~C, ~A, ~S specifiers)
    convert/              # KiCad converters
      footprint.zig       # .kicad_mod → .sexp footprint
      symbol.zig          # .kicad_sym → .sexp symbol (side+order classification)
    render_svg.zig        # SVG schematic renderer (hub/spoke model)
    emit.zig              # Resolved design emitter (flattens hierarchy)
    serve.zig             # HTTP server (httpz) with live update
  test/
    compare_svg.sh        # SVG comparison test script
  projects/
    designs/              # Main design project
      lib/
        components/       # Component definitions (.sexp)
        modules/          # Parameterized subcircuits (.sexp)
        symbols/          # Symbol pin definitions (.sexp)
        footprints/       # Physical pad geometry (.sexp)
      src/
        *.sexp            # Design source files
    tpsm84338_board/      # Reference design project
```

## S-Expression Design Language

### Instance with inline pin-net connections

```scheme
(instance "C1" (cap-0402 "100nF")
  (pin 1 "VDD")
  (pin 2 "GND"))

;; Multi-pin shorthand for same net
(instance "U1" stm32n657l0h3q
  (pin 1 2 3 4 5 "VDD")
  (pin 27 28 29 30 31 "GND"))
```

### Multi-part symbols with grid layout

```scheme
(instance "U1" stm32n657l0h3q
  (part "VDD Power" (row 0) (col 0)
    (pin 1 2 3 4 5 "VDD")
    (pin 27 28 29 30 31 "GND"))
  (part "USB" (row 3) (col 1)
    (pin 52 "USB_DP")
    (pin 53 "USB_DM")))
```

### Named grid sections

```scheme
(section "USB"          (row 3) (col 1))
(section "SMPS Power"   (row 0) (col 1))
```

### Hub grid positioning (non-part hubs)

```scheme
(instance "J2" amphenol-10164986
  (row 3) (col 1)
  (pin 1 12 13 24 "GND")
  (pin 4 9 16 21 "VBUS"))
```

### Parameterized modules

```scheme
(defmodule tpsm84338 (rfbt rfbb rled)
  (let vout (* 0.6 (+ 1.0 (/ rfbt rfbb))))
  (assert-range vout 0.6 16.0 "VOUT")
  (design-block (fmt "~V Buck" vout)
    (instance "U1" tpsm84338rcjr
      (pin 4 vout-str)
      ...)))

;; Usage
(sub-block "pwr" (tpsm84338 220000 47000 1000))
```

### Ports

```scheme
(port "VDD"  "VDD"  in  (rated 1.62 1.98))
(port "GND"  "GND"  bidi)
```

## Web Server

`eda serve` starts an HTTP server with:

- **Design list**: `GET /` — links to all .sexp designs
- **Schematic view**: `GET /schematics/:name` — interactive SVG schematic
- **Live push**: `POST /api/push/:name` — rebuild and push SVG update
- **Version polling**: `GET /api/version/:name` — returns `{"version":N}`
- **SVG endpoint**: `GET /api/svg/:name` — latest rendered SVG
- **Value editing**: `POST /api/edit-value/:name` — edit component value in .sexp file
- **Library upload**: `GET /library`, `POST /api/upload-symbol`, `POST /api/upload-footprint`

### Live update workflow

```bash
# Terminal 1: start server
eda serve --project-dir projects/designs --port 9000

# Terminal 2: edit and push
vim projects/designs/src/stm32n6.sexp
eda build --project-dir projects/designs --push stm32n6
# Browser auto-updates within 500ms
```

## SVG Renderer

The renderer uses a hub/spoke model:
- **Hubs**: ICs, connectors (U/J/P/X/Q prefix) rendered as boxes with pins
- **Spokes**: Passives (R/C/L/F/D prefix) rendered inline on connections
- **Chain following**: Passives chaining through intermediate nets
- **Branch trees**: Junction nets with vertical bus lines
- **Pin grouping**: Same-net pins merged into single rows
- **Grid layout**: Multi-part symbols and hubs arranged in a 2D grid
- **Interactive**: Click components/nets for sidebar details, pan/zoom, search

## Testing

```bash
# Unit tests
zig build test

# SVG comparison against Gleam reference
./test/compare_svg.sh

# Build all designs
for d in pma3-14ln stm32n6 adf5901 tpsm84338 lt3045 power-6v; do
  zig build run -- build --project-dir projects/designs --push $d
done
```
