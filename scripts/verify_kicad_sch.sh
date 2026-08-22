#!/usr/bin/env bash
#
# Oracle for `netlisp export-kicad-sch`: prove the exported schematic means the
# same netlist netlisp itself exports.
#
#   1. export the design as .kicad_sch  (the thing under test)
#   2. export the design as a KiCad .net (netlisp's own flattener — the truth)
#   3. have KiCad read the schematic back and write ITS netlist
#   4. diff net -> {(ref, pad)} between (2) and (3)
#
# Only ref / pad / net are compared. KiCad 10 writes `pinfunction` as
# "<name>_<pad>" for stock symbols too, so pin names are not comparable, and
# KiCad escapes `/` in net names ("usb/DP" -> "usb{slash}DP"), which is undone
# here. Nets KiCad invents for open pads (`unconnected-(…)`) and netlisp's
# code-0 NC bucket are excluded on both sides.
#
# Usage:
#   scripts/verify_kicad_sch.sh <design> [<design>...]
# Environment:
#   NETLISP     path to the netlisp binary       (default ./zig-out/bin/netlisp)
#   PROJECT_DIR project directory to read        (default projects/designs)
#   OUT_DIR     scratch output directory         (default a fresh mktemp -d)
#   KICAD_CLI   kicad-cli binary                 (default kicad-cli)
#
# Exits non-zero on the first mismatch.

set -euo pipefail

NETLISP=${NETLISP:-./zig-out/bin/netlisp}
PROJECT_DIR=${PROJECT_DIR:-projects/designs}
KICAD_CLI=${KICAD_CLI:-kicad-cli}
OUT_DIR=${OUT_DIR:-$(mktemp -d)}

if [ $# -lt 1 ]; then
    echo "usage: $0 <design> [<design>...]" >&2
    exit 2
fi
if [ ! -x "$NETLISP" ]; then
    echo "error: netlisp binary not found at $NETLISP (set NETLISP=)" >&2
    exit 2
fi
if ! command -v "$KICAD_CLI" >/dev/null 2>&1; then
    echo "error: $KICAD_CLI not on PATH (set KICAD_CLI=)" >&2
    exit 2
fi

mkdir -p "$OUT_DIR"
status=0

for design in "$@"; do
    echo "=== $design"
    sch="$OUT_DIR/$design.kicad_sch"
    ref_dir="$OUT_DIR/$design.netlisp"
    kicad_net="$OUT_DIR/$design.kicad.net"

    log="$OUT_DIR/$design.log"
    # netlisp's exporters narrate every written file; keep that out of the
    # oracle's own output but hold on to it for a post-mortem.
    if ! {
        "$NETLISP" export-kicad-sch --project-dir "$PROJECT_DIR" --output "$sch" "$design" &&
            "$NETLISP" export-kicad --project-dir "$PROJECT_DIR" --output-dir "$ref_dir" "$design" &&
            "$KICAD_CLI" sch export netlist --format kicadsexpr -o "$kicad_net" "$sch"
    } >"$log" 2>&1; then
        echo "  export FAILED — see $log" >&2
        tail -20 "$log" >&2
        status=1
        continue
    fi

    if python3 "$(dirname "$0")/verify_kicad_sch.py" "$ref_dir/$design.net" "$kicad_net"; then
        echo "  OK"
    else
        status=1
    fi
done

echo
if [ "$status" -eq 0 ]; then
    echo "all designs match (outputs in $OUT_DIR)"
else
    echo "MISMATCH — see above (outputs in $OUT_DIR)" >&2
fi
exit "$status"
