#!/bin/bash
# Compare Gleam reference SVG with Zig SVG structurally
set -e

REF="/home/epentland/ai/canopy/canopy_app/test/fixtures/pma3_14ln_reference.svg"
ZIG="/tmp/pma3_14ln_zig.svg"

# Generate Zig SVG
cd /home/epentland/ai/canopy/eda
ln -sf pma3-14ln.sexp projects/designs/src/board.sexp
zig build run -- render --project-dir projects/designs > "$ZIG" 2>/dev/null

echo "=== SVG Size Comparison ==="
echo "  Reference (Gleam): $(wc -c < "$REF") bytes"
echo "  Zig output:        $(wc -c < "$ZIG") bytes"

echo ""
echo "=== Element Counts ==="
for element in "<rect" "<line" "<text" "<path" "<polygon" "<g "; do
    ref_count=$(grep -o "$element" "$REF" | wc -l)
    zig_count=$(grep -o "$element" "$ZIG" | wc -l)
    status="OK"
    if [ "$ref_count" -ne "$zig_count" ]; then
        status="MISMATCH"
    fi
    printf "  %-12s  Ref: %3d  Zig: %3d  %s\n" "$element" "$ref_count" "$zig_count" "$status"
done

echo ""
echo "=== Key Component Labels ==="
for label in "U1" "C1" "C2" "C3" "C4" "C5" "C6" "C7" "C8" "L1" "L2" "R1" "FB1"; do
    ref_has=$(grep -c ">$label<\|>$label " "$REF" 2>/dev/null || echo 0)
    zig_has=$(grep -c ">$label<\|>$label " "$ZIG" 2>/dev/null || echo 0)
    if [ "$zig_has" -eq 0 ]; then
        echo "  $label: MISSING in Zig (Ref has $ref_has)"
    else
        echo "  $label: OK (Ref: $ref_has, Zig: $zig_has)"
    fi
done

echo ""
echo "=== Key Net Labels ==="
for net in "RF_INPUT" "RF_OUTPUT" "RF_IN" "RF_OUT" "VDD" "GND" "INPUT_BIAS" "OUTPUT_BIAS"; do
    ref_has=$(grep -c "$net" "$REF" 2>/dev/null || echo 0)
    zig_has=$(grep -c "$net" "$ZIG" 2>/dev/null || echo 0)
    if [ "$zig_has" -eq 0 ] && [ "$ref_has" -gt 0 ]; then
        echo "  $net: MISSING in Zig (Ref has $ref_has)"
    elif [ "$ref_has" -eq 0 ]; then
        echo "  $net: not in Ref either"
    else
        echo "  $net: OK (Ref: $ref_has, Zig: $zig_has)"
    fi
done

echo ""
echo "=== Ground Symbols ==="
ref_gnd=$(grep -c "stroke=\"#e8c547\"" "$REF" 2>/dev/null || echo 0)
zig_gnd=$(grep -c "stroke=\"#e8c547\"" "$ZIG" 2>/dev/null || echo 0)
echo "  GND symbol strokes - Ref: $ref_gnd, Zig: $zig_gnd"

echo ""
echo "=== Passive Symbol Shapes ==="
ref_passive=$(grep -c "stroke=\"#8888cc\"" "$REF" 2>/dev/null || echo 0)
zig_passive=$(grep -c "stroke=\"#8888cc\"" "$ZIG" 2>/dev/null || echo 0)
echo "  Passive shapes (#8888cc) - Ref: $ref_passive, Zig: $zig_passive"

echo ""
echo "=== Hub Box ==="
ref_hub=$(grep -c 'fill="#16213e"' "$REF" 2>/dev/null || echo 0)
zig_hub=$(grep -c 'fill="#16213e"' "$ZIG" 2>/dev/null || echo 0)
echo "  Hub boxes (#16213e) - Ref: $ref_hub, Zig: $zig_hub"

echo ""
echo "=== ViewBox ==="
echo "  Ref: $(grep -o 'viewBox="[^"]*"' "$REF")"
echo "  Zig: $(grep -o 'viewBox="[^"]*"' "$ZIG")"
