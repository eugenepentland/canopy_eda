#!/bin/bash
# Integration test: verify component IDs are stable under design edits
# Usage: bash test/test_id_stability.sh
set -e

EDA="./zig-out/bin/eda"
DESIGN="projects/designs/src/stm32n6.sexp"
BOM="projects/designs/src/stm32n6.bom"
PROJ="projects/designs"
PASS=0
FAIL=0

# Build EDA if needed
if [ ! -f "$EDA" ]; then
    echo "Building EDA..."
    zig build 2>/dev/null
fi

# Save original
cp "$DESIGN" /tmp/stm32n6_orig.sexp
cp "$BOM" /tmp/stm32n6_orig.bom 2>/dev/null || true

# Helper: build and extract sorted IDs from BOM
extract_ids() {
    $EDA build --project-dir "$PROJ" stm32n6 >/dev/null 2>&1 || true
    grep '(id "' "$BOM" | sed 's/.*id "\([^"]*\)".*/\1/' | sort
}

# Helper: compare IDs
check_ids() {
    local label="$1"
    local expected="$2"
    local actual
    actual=$(extract_ids)
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        diff <(echo "$expected") <(echo "$actual") || true
        FAIL=$((FAIL + 1))
    fi
}

echo "=== ID Stability Tests ==="

# Baseline: build and record IDs
echo "Building baseline..."
BASELINE=$(extract_ids)
BASELINE_COUNT=$(echo "$BASELINE" | wc -l)
echo "  Baseline: $BASELINE_COUNT component IDs"

# Test 1: Change a component value
echo "Test 1: Value change (10k -> 4.7k)..."
sed -i 's/res-0402 "10k"/res-0402 "4.7k"/g' "$DESIGN"
check_ids "value change" "$BASELINE"
cp /tmp/stm32n6_orig.sexp "$DESIGN"

# Test 2: Change a component family
echo "Test 2: Footprint change (res-0402 -> res-0201)..."
sed -i '0,/res-0402 "33R"/s/res-0402 "33R"/res-0201 "33R"/' "$DESIGN"
check_ids "footprint change" "$BASELINE"
cp /tmp/stm32n6_orig.sexp "$DESIGN"

# Test 3: Rename a label
echo "Test 3: Label rename (stm32 -> mcu)..."
sed -i 's/"stm32"/"mcu"/g; s/per-pin stm32/per-pin mcu/g; s/(pins "stm32"/(pins "mcu"/g' "$DESIGN"
check_ids "label rename" "$BASELINE"
cp /tmp/stm32n6_orig.sexp "$DESIGN"

# Test 4: Change a net name
echo "Test 4: Net rename (FLASH_RESET -> FLASH_RST)..."
sed -i 's/FLASH_RESET/FLASH_RST/g' "$DESIGN"
check_ids "net rename" "$BASELINE"
cp /tmp/stm32n6_orig.sexp "$DESIGN"

# Test 5: Modify a note
echo "Test 5: Note change..."
sed -i 's/AN5967 Fig 4/AN5967 Figure 4/' "$DESIGN"
check_ids "note change" "$BASELINE"
cp /tmp/stm32n6_orig.sexp "$DESIGN"

# Test 6: Change pin assignment
echo "Test 6: Pin reassignment..."
sed -i 's/pin W7 "SWDIO_MCU"/pin V8 "SWDIO_MCU"/' "$DESIGN"
check_ids "pin reassignment" "$BASELINE"
cp /tmp/stm32n6_orig.sexp "$DESIGN"

# Test 7: Rebuild is idempotent
echo "Test 7: Idempotent rebuild..."
check_ids "idempotent rebuild" "$BASELINE"

# Test 8: Add a component — existing IDs unchanged
echo "Test 8: Add component..."
sed -i '/section "Debug LED"/a\    (series "R_NEW" (res-0402 "1k") "PG10" "GND" (id aaaa1111))' "$DESIGN"
ADDED=$(extract_ids)
# Check all baseline IDs still present
MISSING=$(comm -23 <(echo "$BASELINE") <(echo "$ADDED"))
if [ -z "$MISSING" ]; then
    echo "  PASS: add component (existing IDs preserved)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: add component (lost IDs: $MISSING)"
    FAIL=$((FAIL + 1))
fi
cp /tmp/stm32n6_orig.sexp "$DESIGN"

# Test 9: Remove a component — remaining IDs unchanged
echo "Test 9: Remove component..."
# Remove the debug LED series R9 line
sed -i '/series "R9"/d' "$DESIGN"
REMOVED=$(extract_ids)
# R9's ID should be gone, all others should remain
R9_ID=$(echo "$BASELINE" | head -1)  # we don't know which ID is R9, but count should be baseline-1
REMOVED_COUNT=$(echo "$REMOVED" | wc -l)
EXPECTED_COUNT=$((BASELINE_COUNT - 1))
# Check that all remaining IDs are a subset of baseline
EXTRA=$(comm -13 <(echo "$BASELINE") <(echo "$REMOVED"))
if [ -z "$EXTRA" ] && [ "$REMOVED_COUNT" -eq "$EXPECTED_COUNT" ]; then
    echo "  PASS: remove component (remaining IDs preserved)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: remove component"
    FAIL=$((FAIL + 1))
fi
cp /tmp/stm32n6_orig.sexp "$DESIGN"

# Restore originals
cp /tmp/stm32n6_orig.sexp "$DESIGN"
cp /tmp/stm32n6_orig.bom "$BOM" 2>/dev/null || true
# Rebuild to ensure clean state
$EDA build --project-dir "$PROJ" stm32n6 >/dev/null 2>&1 || true

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
