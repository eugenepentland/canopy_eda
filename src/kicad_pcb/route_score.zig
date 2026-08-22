//! Lexicographic scoring for an in-memory reference-routing attempt.
//!
//! Completeness dominates newly introduced DRC errors, which dominate new
//! warnings and return-path regressions. Via count and length only distinguish
//! candidates after those electrical and manufacturing gates are equal.

const std = @import("std");

/// Completeness, DRC, selected return-path, and copper burden for one route.
pub const Quality = struct {
    routed: usize,
    total: usize,
    drc_errors: usize,
    drc_warnings: usize,
    return_path_warnings: usize,
    vias: usize,
    length_mm: f64,
};

/// Baseline-relative hard findings plus the comparable scalar objectives.
pub const Score = struct {
    missing_nets: usize,
    new_errors: usize,
    new_warnings: usize,
    new_return_path_warnings: usize,
    reference_objective: f64,
    objective: f64,
};

/// Compare a candidate with the adapter's reference baseline. DRC findings are
/// deltas because the adapter can conservatively approximate existing shapes;
/// selected-net return-path findings are absolute and can improve on reference.
pub fn compare(reference: Quality, candidate: Quality) Score {
    const missing = candidate.total -| candidate.routed;
    const errors = positiveDelta(candidate.drc_errors, reference.drc_errors);
    const warnings = positiveDelta(candidate.drc_warnings, reference.drc_warnings);
    const return_paths = positiveDelta(
        candidate.return_path_warnings,
        reference.return_path_warnings,
    );
    return .{
        .missing_nets = missing,
        .new_errors = errors,
        .new_warnings = warnings,
        .new_return_path_warnings = return_paths,
        .reference_objective = objective(
            0,
            0,
            0,
            reference.return_path_warnings,
            reference.vias,
            reference.length_mm,
        ),
        .objective = objective(
            missing,
            errors,
            warnings,
            candidate.return_path_warnings,
            candidate.vias,
            candidate.length_mm,
        ),
    };
}

fn positiveDelta(value: usize, baseline: usize) usize {
    return value -| baseline;
}

fn objective(
    missing: usize,
    errors: usize,
    warnings: usize,
    return_paths: usize,
    vias: usize,
    length_mm: f64,
) f64 {
    return @as(f64, @floatFromInt(missing)) * 1e12 +
        @as(f64, @floatFromInt(errors)) * 1e9 +
        @as(f64, @floatFromInt(warnings)) * 1e6 +
        @as(f64, @floatFromInt(return_paths)) * 1e3 +
        @as(f64, @floatFromInt(vias)) * 20 +
        length_mm;
}

test "route score is lexicographic with absolute selected return paths" {
    const reference = Quality{
        .routed = 2,
        .total = 2,
        .drc_errors = 4,
        .drc_warnings = 3,
        .return_path_warnings = 10,
        .vias = 2,
        .length_mm = 12,
    };
    const clean = compare(reference, .{
        .routed = 2,
        .total = 2,
        .drc_errors = 4,
        .drc_warnings = 2,
        .return_path_warnings = 10,
        .vias = 1,
        .length_mm = 14,
    });
    try std.testing.expectEqual(@as(usize, 0), clean.new_warnings);
    try std.testing.expectEqual(@as(f64, 10_034), clean.objective);

    const incomplete = compare(reference, .{
        .routed = 1,
        .total = 2,
        .drc_errors = 0,
        .drc_warnings = 0,
        .return_path_warnings = 0,
        .vias = 0,
        .length_mm = 0,
    });
    try std.testing.expect(incomplete.objective > 1e11);
}
