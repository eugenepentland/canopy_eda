//! One sentence per way a schematic push can fail.
//!
//! Two surfaces report the same failures — the `sync-kicad-sch` CLI and the
//! HTTP/MCP tool — and each had its own copy of the table, so the same error
//! could be explained two different ways depending on where the operator ran
//! it. The sentences name the RULE rather than the error tag, which is the
//! point of having them at all; that only works if there is one of each.
//!
//! Typed as `anyerror` deliberately: the two callers' error sets differ (the
//! tool surface adds the design-resolution errors), and an explanation table
//! that only one of them can call is the duplication this replaces.

/// The operator-facing sentence for `err`.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.PcbPathUnset => "this design declares no (kicad-pcb \"<path>\") form, " ++
            "so there is no KiCad project directory to push the schematic into",
        error.PcbPathNotInDirectory => "the design's (kicad-pcb \"<path>\") is a bare filename " ++
            "with no directory, so there is nowhere to write the schematic",
        error.PushWriteFailed => "writing into the KiCad project directory failed",
        error.FileNotFound, error.NotADesign, error.InvalidName => "no design by that name",
        error.OutOfMemory => "ran out of memory building the schematic",
        // What is left is the export itself: `export_kicad_sch.SchError` is the
        // emitter plus its own verifier, so a failure here means the schematic
        // it built did not describe the design it was built from.
        else => "the schematic export failed its own self-check",
    };
}
