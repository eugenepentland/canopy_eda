//! Constants describing the `.kicad_pcb` S-expression schema, shared by
//! the reader and writer so the two stay in lockstep on what counts as
//! a "structural" property vs. a custom field.

/// `(property "Reference" "U1" …)` — the visible ref-des.
pub const PROP_REFERENCE = "Reference";
/// `(property "Value" "100nF" …)` — the visible value text.
pub const PROP_VALUE = "Value";
/// `(property "canopy_uuid" "<uuid>" …)` — our cross-sync identity tag.
pub const PROP_CANOPY_UUID = "canopy_uuid";
