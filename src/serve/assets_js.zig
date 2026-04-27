// ── Interaction JavaScript ─────────────────────────────────────────────
// Split into two parts so we can inject the design name between them.

pub const INTERACTION_JS_PART1 =
    \\(function(){try{
    \\
;

pub const INTERACTION_JS_PART2 = @embedFile("assets/interaction_part2.js");
