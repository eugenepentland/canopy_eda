//! The review-check registry: one stable id for every check the toolchain can
//! run, with the layer it lives at, the review category it answers, what it
//! asserts, which engine produces it, the DSL form that closes it, and how
//! hard it blocks. `docs/language-forms.md` renders its "Review checks"
//! section straight from `rows`, so the published catalogue cannot drift from
//! the table, and the mapping functions below turn each engine's private
//! vocabulary (ERC violation kinds, DRC kinds, fabrication finding ids,
//! preflight findings and class-profile item codes, requirement-check and
//! net-rule keywords, rail/thermal/PLL/frequency-plan verdicts, the system
//! gate flags and interface-contract mismatches) into one of those ids.
//!
//! This module is a static table plus pure lookups: it runs no check, reads
//! no file and changes no engine behaviour. Consumers join engine findings to
//! rows so a review surface can group, filter and cite them by id.

const std = @import("std");
const erc = @import("erc.zig");
const drc = @import("placement/drc.zig");
const preflight = @import("preflight.zig");
const power_budget = @import("eval/power_budget.zig");
const thermal = @import("eval/thermal.zig");
const pll_loop = @import("pll_loop.zig");
const frequency_plan = @import("frequency_plan.zig");
const check_grammar = @import("eval/check_grammar.zig");
const authored_rules = @import("eval/authored_rules.zig");
const system_interface_check = @import("system_interface_check.zig");

/// Where the check's input is authored and where its verdict belongs.
/// `library` rules travel with a part, `unit` rules judge one board, `system`
/// rules judge a product made of boards.
pub const Layer = enum { library, unit, system };

/// The twelve fixed review categories a board review is organised into. Every
/// row belongs to exactly one; the set is board-agnostic because the physics
/// is (every board has supplies, loads, copper, heat, parts and datasheets).
pub const Category = enum {
    identity,
    connectivity,
    supply_voltages,
    power_budget,
    decoupling,
    sequencing_levels,
    component_ratings,
    thermal,
    datasheet_compliance,
    bom,
    layout,
    domain_analyses,

    /// Heading text for the category, as review surfaces and the generated
    /// language reference spell it.
    pub fn title(self: Category) []const u8 {
        return switch (self) {
            .identity => "Identity and sources",
            .connectivity => "Connectivity",
            .supply_voltages => "Supply voltages",
            .power_budget => "Power budget and copper",
            .decoupling => "Decoupling and bulk",
            .sequencing_levels => "Sequencing and levels",
            .component_ratings => "Component ratings",
            .thermal => "Thermal",
            .datasheet_compliance => "Datasheet compliance",
            .bom => "BOM",
            .layout => "Layout",
            .domain_analyses => "Domain analyses",
        };
    }
};

/// What one finding of the row is about — the granularity its subject names.
pub const Scope = enum { part, pin, net, rail, board, system };

/// How hard a failing row blocks. `blocking` stops a release, `waivable`
/// stops one until a waiver record is linked, `advisory` never stops one.
pub const Policy = enum { blocking, waivable, advisory };

/// The seven-word result vocabulary every review surface uses. `unproven`
/// means the engine ran and names the missing input; `waived` means a record
/// is linked; `not_applicable` means the population is absent and the row
/// says so; `not_declared` means the board never gave the engine an input;
/// `manual` means a human must judge it and attach evidence.
pub const Verdict = enum { pass, fail, unproven, waived, not_applicable, not_declared, manual };

/// One registered check.
pub const Row = struct {
    /// Stable kebab-case identifier. Findings cite it; it never changes.
    id: []const u8,
    /// Where the check's input is authored and its verdict belongs.
    layer: Layer,
    /// Which of the twelve review categories the row answers.
    category: Category,
    /// The granularity one finding of the row is about.
    scope: Scope,
    /// One sentence stating what must be true for the row to pass.
    asserts: []const u8,
    /// The engine that produces the row, named as module plus finding kind.
    engine: []const u8,
    /// The DSL form or action that closes a failing row.
    closes_with: []const u8,
    /// How hard a failing row blocks a release.
    policy: Policy,
    /// Every verdict this row can produce.
    verdicts: []const Verdict,
};

// ── Verdict sets ──────────────────────────────────────────────────
/// A row the engine always decides: it either holds or it does not.
const binary: []const Verdict = &.{ .pass, .fail };
/// A row a reviewer may close with a linked waiver record.
const waivable_row: []const Verdict = &.{ .pass, .fail, .waived };
/// A row whose engine can run and still fail to decide.
const screened: []const Verdict = &.{ .pass, .fail, .unproven };
/// A row that reports the absence of its own input rather than passing.
const declared: []const Verdict = &.{ .pass, .fail, .not_declared };
/// A row that both needs an authored input and can fail to decide.
const declared_screened: []const Verdict = &.{ .pass, .fail, .unproven, .not_declared };
/// A waivable row whose population may be absent on a given board.
const waivable_population: []const Verdict = &.{ .pass, .fail, .waived, .not_applicable };
/// A declared row a reviewer may close with a waiver record.
const declared_waivable: []const Verdict = &.{ .pass, .fail, .waived, .not_declared };
/// A row only a human closes, with an evidence field.
const judged: []const Verdict = &.{ .manual, .waived, .pass };

/// Every check the toolchain can run, grouped by category in category order.
/// The generated language reference renders this table verbatim, and every
/// mapping function below returns an id that appears here.
pub const rows: []const Row = &.{
    // ── Identity and sources ──────────────────────────────────────
    .{
        .id = "refdes-unique",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "No two placed parts share a ref-des anywhere in the flattened design.",
        .engine = "erc.zig - duplicate_refdes",
        .closes_with = "rename one placement, or let eval/ids.zig mint the ref-des",
    },
    .{
        .id = "instance-value-present",
        .layer = .unit,
        .category = .identity,
        .scope = .part,
        .policy = .waivable,
        .verdicts = waivable_row,
        .asserts = "Every placed part carries a value.",
        .engine = "erc.zig - missing_value",
        .closes_with = "give the instance a value at its call site",
    },
    .{
        .id = "instance-footprint-present",
        .layer = .unit,
        .category = .identity,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every placed part resolves to a footprint.",
        .engine = "erc.zig - missing_footprint",
        .closes_with = "(footprint <name>) on the library component",
    },
    .{
        .id = "concept-resolved",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "No concept placeholder survives into a design being reviewed.",
        .engine = "erc.zig - concept_remaining",
        .closes_with = "replace the (concept …) placeholder with a real part or module",
    },
    .{
        .id = "no-deprecated-forms",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .waivable,
        .verdicts = waivable_row,
        .asserts = "The design uses no form the language has deprecated.",
        .engine = "erc.zig - deprecated_form",
        .closes_with = "rewrite the form as the replacement the warning names",
    },
    .{
        .id = "blocks-grouped",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .advisory,
        .verdicts = waivable_population,
        .asserts = "Every diagram block of a board with five or more blocks sits inside a group.",
        .engine = "erc.zig - components_not_grouped",
        .closes_with = "(group \"NAME\" …) around the ungrouped blocks",
    },
    .{
        .id = "section-category-declared",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .advisory,
        .verdicts = declared,
        .asserts = "Every section states its category instead of relying on name-keyword inference.",
        .engine = "erc.zig - section_category_inferred",
        .closes_with = "(category <key>) in the section body",
    },
    .{
        .id = "module-reuse-preferred",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .advisory,
        .verdicts = waivable_row,
        .asserts = "A block a canonical module already implements instantiates that module.",
        .engine = "erc.zig - direct_component_implementation, canonical_module_check.zig",
        .closes_with = "instantiate the canonical module, or (module-bypass \"reason\")",
    },
    .{
        .id = "module-metadata-complete",
        .layer = .library,
        .category = .identity,
        .scope = .part,
        .policy = .advisory,
        .verdicts = declared,
        .asserts = "Every reusable module declares the metadata its library record needs.",
        .engine = "erc.zig - module_metadata_incomplete",
        .closes_with = "fill the module's metadata fields in lib/modules/<name>.sexp",
    },
    .{
        .id = "revision-missing",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "The design declares the revision the release is cut at.",
        .engine = "fab_gate.zig - revision-missing",
        .closes_with = "(revision \"…\") on the design block",
    },
    .{
        .id = "missing-identity",
        .layer = .unit,
        .category = .identity,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every placement carries a persisted stable id.",
        .engine = "fab_readiness.zig - missing-identity",
        .closes_with = "run netlisp build so ids are pinned back into the source",
    },
    .{
        .id = "duplicate-identity",
        .layer = .unit,
        .category = .identity,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "No two placements share a stable id.",
        .engine = "fab_readiness.zig - duplicate-identity",
        .closes_with = "delete the copied (id \"…\") so a fresh one is minted",
    },
    .{
        .id = "duplicate-source-identity",
        .layer = .unit,
        .category = .identity,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "No stable id appears twice in the design sources.",
        .engine = "fab_gate.zig - duplicate-source-identity",
        .closes_with = "remove the duplicated (id \"…\") from the source file",
    },
    .{
        .id = "fabrication-identity-incomplete",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The fabrication gate can bind the release to one complete identity record.",
        .engine = "fab_gate.zig - fabrication-identity-incomplete",
        .closes_with = "resolve the identity findings the gate lists, then re-run the gate",
    },
    .{
        .id = "schematic-check-failed",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Strict schematic preflight resolves the design the release is cut from.",
        .engine = "fab_gate.zig - schematic-check-failed",
        .closes_with = "make netlisp check --profile release pass on the design",
    },
    .{
        .id = "reviewed-input-evidence-incomplete",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "The release names the reviewed inputs it was cut from.",
        .engine = "fab_gate.zig - reviewed-input-evidence-incomplete",
        .closes_with = "attach the reviewed-input evidence the release lock asks for",
    },
    .{
        .id = "cache-layout",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The cached layout the release reads matches the design it was saved from.",
        .engine = "fab_readiness.zig - cache-layout",
        .closes_with = "re-save the layout so the cached poses match the design",
    },
    .{
        .id = "build-warning-free",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Evaluating the design emits no warning.",
        .engine = "preflight.zig - eval_warning",
        .closes_with = "fix the evaluator warning at the source span it names",
    },
    .{
        .id = "source-tree-clean",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "The project tree carries no uncommitted change when the release evidence is taken.",
        .engine = "fab_readiness.zig - project_status",
        .closes_with = "commit or revert the working tree, then take the evidence again",
    },
    .{
        .id = "layout-frozen",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "The reviewed layout is frozen: its parts are placed and locked and every sub-block layout is starred.",
        .engine = "serve/pcb_describe.zig - completion ladder placement and sub_circuits rungs",
        .closes_with = "lock the placement and star each sub-block's layout",
    },
    .{
        .id = "release-gate-clear",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "The fabrication-readiness gate reports no blocking error for the reviewed layout.",
        .engine = "serve/fab_release_service.zig - readiness errors",
        .closes_with = "close every gate error the readiness run names",
    },
    .{
        .id = "design-notes-closed",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .advisory,
        .verdicts = binary,
        .asserts = "Every design note raised against the board is closed.",
        .engine = "serve/notes.zig - open tasks in <design>.notes.md",
        .closes_with = "close the note, or restate it as a checklist item",
    },
    .{
        .id = "release-differential-reviewed",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .advisory,
        .verdicts = judged,
        .asserts = "The fabrication package is diffed against the previous release and every change is intended.",
        .engine = "gerber-dump --digest and netlist-dump on both commits (human)",
        .closes_with = "record the differential in the audit's Disposition cell",
    },
    .{
        .id = "source-revision-unavailable",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "The release can read the source revision the package is cut from.",
        .engine = "fab_release.zig - source-revision-unavailable",
        .closes_with = "run the release from a checkout whose revision the tool can read",
    },
    .{
        .id = "source-worktree-dirty",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The worktree the package is cut from carries no uncommitted change.",
        .engine = "fab_release.zig - source-worktree-dirty",
        .closes_with = "commit or revert the working tree, then cut the package again",
    },
    .{
        .id = "source-snapshot-changed",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The source did not change under the release while the package was being cut.",
        .engine = "fab_release.zig - source-snapshot-changed",
        .closes_with = "re-cut the package from a settled tree",
    },
    .{
        .id = "source-bundle-ambiguous",
        .layer = .unit,
        .category = .identity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Exactly one source bundle describes the release.",
        .engine = "fab_release.zig - source-bundle-ambiguous",
        .closes_with = "leave one source bundle beside the release and delete the others",
    },
    .{
        .id = "system-identity-complete",
        .layer = .system,
        .category = .identity,
        .scope = .system,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "The system declares title, part number and revision.",
        .engine = "system_review_package.zig - GateState.identity_ok",
        .closes_with = "(title …) (part-number …) (revision …) in src/systems/<name>/system.sexp",
    },
    .{
        .id = "system-board-reviews",
        .layer = .system,
        .category = .identity,
        .scope = .system,
        .policy = .blocking,
        .verdicts = declared_waivable,
        .asserts = "Every board the system claims has a current board review.",
        .engine = "system_review_package.zig - GateState.board_review_ok",
        .closes_with = "run and record the board review for each (board …)",
    },
    .{
        .id = "system-fabrication-ready",
        .layer = .system,
        .category = .identity,
        .scope = .system,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every board the system claims passes its own fabrication gate.",
        .engine = "system_review_package.zig - GateState.fab_ok",
        .closes_with = "clear each board's blocking fabrication findings",
    },
    .{
        .id = "system-checklists-complete",
        .layer = .system,
        .category = .identity,
        .scope = .system,
        .policy = .blocking,
        .verdicts = judged,
        .asserts = "Every authored release-checklist item is dispositioned.",
        .engine = "system_review_package.zig - GateState.checklists_ok",
        .closes_with = "disposition the remaining checklist rows in the review package",
    },
    .{
        .id = "system-attested",
        .layer = .system,
        .category = .identity,
        .scope = .system,
        .policy = .blocking,
        .verdicts = judged,
        .asserts = "A named reviewer has attested the release package.",
        .engine = "system_review_package.zig - GateState.attested",
        .closes_with = "sign the attestation in the system review package",
    },
    .{
        .id = "system-manifest-single-source",
        .layer = .system,
        .category = .identity,
        .scope = .system,
        .policy = .advisory,
        .verdicts = binary,
        .asserts = "A system is described by system.sexp or system.json, never both.",
        .engine = "system_interface_check.zig - manifest_shadowed",
        .closes_with = "delete the inert system.json beside the system.sexp",
    },

    // ── Connectivity ──────────────────────────────────────────────
    .{
        .id = "erc-clean",
        .layer = .unit,
        .category = .connectivity,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The electrical-rule check reports no error and no warning on the board.",
        .engine = "erc.zig - runErc totals",
        .closes_with = "close every violation the check reports, kind by kind",
    },
    .{
        .id = "net-not-floating",
        .layer = .unit,
        .category = .connectivity,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every net reaches at least two pins or is declared a block port.",
        .engine = "erc.zig - floating_net",
        .closes_with = "wire the net, or declare it with (port …)",
    },
    .{
        .id = "pin-connected",
        .layer = .unit,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every pad of every placed part is wired or explicitly dispositioned.",
        .engine = "erc.zig - unconnected_pin",
        .closes_with = "wire the pad, or mark it with (nc …)",
    },
    .{
        .id = "no-connect-dispositioned",
        .layer = .unit,
        .category = .connectivity,
        .scope = .pin,
        .policy = .waivable,
        .verdicts = waivable_row,
        .asserts = "Every deliberately unconnected pad carries a reason.",
        .engine = "erc.zig - no_connect",
        .closes_with = "(nc \"PIN\" \"reason\") on the instance",
    },
    .{
        .id = "pin-single-net",
        .layer = .unit,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "No pad is wired to more than one net.",
        .engine = "erc.zig - pin_multi_net",
        .closes_with = "remove the duplicate wiring of the pad",
    },
    .{
        .id = "pin-function-known",
        .layer = .unit,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every pin name a design wires exists in the part's library pinout.",
        .engine = "erc.zig - pin_function_unsupported",
        .closes_with = "use a pin function the pinout declares, or extend the pinout",
    },
    .{
        .id = "pin-function-required",
        .layer = .unit,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every pin function the part requires is wired.",
        .engine = "erc.zig - pin_function_required",
        .closes_with = "wire the required pin function on the instance",
    },
    .{
        .id = "strap-dispositioned",
        .layer = .unit,
        .category = .connectivity,
        .scope = .pin,
        .policy = .waivable,
        .verdicts = waivable_row,
        .asserts = "Every configuration strap tied straight to a rail is reviewed and justified.",
        .engine = "erc.zig - strap_tied_to_rail",
        .closes_with = "(strap-ok \"PIN\" \"reason\") citing the datasheet",
    },
    .{
        .id = "test-point-present",
        .layer = .unit,
        .category = .connectivity,
        .scope = .net,
        .policy = .advisory,
        .verdicts = waivable_population,
        .asserts = "Every net the design marks for bring-up carries a test point.",
        .engine = "erc.zig - test_point_missing, eval/test_point.zig",
        .closes_with = "place a test point on the net",
    },
    .{
        .id = "diff-pair-both-halves",
        .layer = .unit,
        .category = .connectivity,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Both halves of every differential pair are wired.",
        .engine = "erc.zig - diff_pair_half_connected",
        .closes_with = "wire the missing half of the pair",
    },
    .{
        .id = "interface-fully-wired",
        .layer = .unit,
        .category = .connectivity,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every signal a bound interface declares reaches both endpoints.",
        .engine = "erc.zig - interface_half_connected, erc_interface.zig",
        .closes_with = "wire the interface signals the finding names",
    },
    .{
        .id = "interface-naming-consistent",
        .layer = .unit,
        .category = .connectivity,
        .scope = .net,
        .policy = .advisory,
        .verdicts = binary,
        .asserts = "An interface signal's net is named as the interface declares it.",
        .engine = "erc.zig - interface_naming, erc_interface.zig",
        .closes_with = "rename the net to the interface's signal name",
    },
    .{
        .id = "unresolvable-pin",
        .layer = .unit,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every netlist pin resolves to a pad on the placed footprint.",
        .engine = "fab_readiness.zig - unresolvable-pin",
        .closes_with = "fix the pin name or the footprint's pad table",
    },
    .{
        .id = "net-rule-max-fanout",
        .layer = .unit,
        .category = .connectivity,
        .scope = .net,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "A net a design rule matches lands on no more pins than the rule allows.",
        .engine = "eval/authored_rules.zig - max_fanout; req_design_rules.zig",
        .closes_with = "(net-rule \"text\" (nets GLOB…) (max-fanout N))",
    },
    .{
        .id = "system-interface-endpoints",
        .layer = .system,
        .category = .connectivity,
        .scope = .system,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every system interface names two board endpoints that exist.",
        .engine = "system_review_package.zig - GateState.interface_ok",
        .closes_with = "(interface \"NAME\" …) naming both boards in system.sexp",
    },
    .{
        .id = "system-interface-contract",
        .layer = .system,
        .category = .connectivity,
        .scope = .system,
        .policy = .blocking,
        .verdicts = declared_screened,
        .asserts = "Every declared board-to-board contract checks clean end to end.",
        .engine = "system_review_package.zig - GateState.interface_contract_ok",
        .closes_with = "resolve the interface mismatches the system check lists",
    },
    .{
        .id = "interface-contact-connected",
        .layer = .system,
        .category = .connectivity,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every contract contact reaches a real net on both sides of the connector.",
        .engine = "system_interface_check.zig - contact_unconnected_one_side",
        .closes_with = "wire the contact on the board the finding names",
    },
    .{
        .id = "interface-contact-pin-known",
        .layer = .system,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every contact a contract names exists in the connector's pinout.",
        .engine = "system_interface_check.zig - unknown_contact_pin",
        .closes_with = "correct the contact name, or extend the connector pinout",
    },
    .{
        .id = "interface-contact-count",
        .layer = .system,
        .category = .connectivity,
        .scope = .system,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "A contract claims no more contacts than the connector has pads.",
        .engine = "system_interface_check.zig - contact_count_over_pads",
        .closes_with = "drop the surplus contacts, or pick a larger connector",
    },
    .{
        .id = "interface-contacts-covered",
        .layer = .system,
        .category = .connectivity,
        .scope = .system,
        .policy = .advisory,
        .verdicts = binary,
        .asserts = "Every pad the connector carries is covered by the contract.",
        .engine = "system_interface_check.zig - contacts_not_covered",
        .closes_with = "add the uncovered contacts to the interface contract",
    },
    .{
        .id = "interface-contact-unique",
        .layer = .system,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "No two contract signals claim the same physical contact.",
        .engine = "system_interface_check.zig - duplicate_contact_claim",
        .closes_with = "give each signal its own contact in the contract",
    },
    .{
        .id = "interface-pinout-available",
        .layer = .system,
        .category = .connectivity,
        .scope = .system,
        .policy = .blocking,
        .verdicts = declared_screened,
        .asserts = "Both connector pinouts are readable, so the contact checks can run.",
        .engine = "system_interface_check.zig - connector_pinout_unavailable",
        .closes_with = "add the connector's pinout file to the library",
    },
    .{
        .id = "check-connected",
        .layer = .library,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Both named pins of the placement resolve to the same net.",
        .engine = "eval/check_grammar.zig - connected; req_checks.zig",
        .closes_with = "(requirement \"…\" (check (connected (pin \"A\") (pin \"B\"))))",
    },
    .{
        .id = "check-tied-to-net",
        .layer = .library,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The named pin resolves to the exact net the datasheet rule names.",
        .engine = "eval/check_grammar.zig - tied_to_net; req_checks.zig",
        .closes_with = "(requirement \"…\" (check (tied-to-net (pin \"P\") (net \"N\"))))",
    },
    .{
        .id = "check-not-connected",
        .layer = .library,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The named pin is left unconnected, as the datasheet demands.",
        .engine = "eval/check_grammar.zig - not_connected; req_checks.zig",
        .closes_with = "(requirement \"…\" (check (not-connected (pin \"P\"))))",
    },
    .{
        .id = "check-pin-not-floating",
        .layer = .library,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The named pin is tied to a defined level rather than left floating.",
        .engine = "eval/check_grammar.zig - pin_not_floating; req_checks.zig",
        .closes_with = "(requirement \"…\" (check (pin-not-floating (pin \"P\"))))",
    },
    .{
        .id = "check-pins-on-same-net",
        .layer = .library,
        .category = .connectivity,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every listed pin function of the placement resolves to one net.",
        .engine = "eval/check_grammar.zig - pins_on_same_net; req_checks.zig",
        .closes_with = "(requirement \"…\" (check (pins-on-same-net (pins \"A\" \"B\" …))))",
    },

    .{
        .id = "interface-esd-protection",
        .layer = .unit,
        .category = .connectivity,
        .scope = .net,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every externally exposed interface the system brief names carries a protection-class part when the brief declares an ESD class.",
        .engine = "brief_checks.zig - Observation interface-esd-protection, via preflight FindingKind.brief",
        .closes_with = "place a TVS/ESD part on the interface net, or a part with (class protection)",
    },

    // ── Supply voltages ───────────────────────────────────────────
    .{
        .id = "rail-voltage-consistent",
        .layer = .unit,
        .category = .supply_voltages,
        .scope = .rail,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every declaration of a rail's voltage agrees with every other.",
        .engine = "erc.zig - voltage_mismatch",
        .closes_with = "make the (rail …) and port voltages agree, or split the rail",
    },
    .{
        .id = "rail-voltage-resolved",
        .layer = .unit,
        .category = .supply_voltages,
        .scope = .rail,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every supply rail resolves to a known voltage.",
        .engine = "erc.zig - rail_voltage_unresolved; eval/rails.zig",
        .closes_with = "(rail \"NAME\" V) or a port rating that fixes the rail",
    },
    .{
        .id = "pin-abs-max-respected",
        .layer = .unit,
        .category = .supply_voltages,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "No pin sees a declared voltage above its absolute-maximum rating.",
        .engine = "erc.zig - voltage_overstress; eval/net_envelopes.zig",
        .closes_with = "(electrical \"PIN\" … (max-voltage V)) plus real level shifting",
    },
    .{
        .id = "supply-pin-voltage-rule",
        .layer = .unit,
        .category = .supply_voltages,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every supply pin of a classed part carries a voltage-range requirement.",
        .engine = "review_profiles.zig - supply-voltage-check; preflight profile_incomplete",
        .closes_with = "(requirement \"…\" (check (voltage-range (pin \"PIN\") (min …) (max …))))",
    },
    .{
        .id = "net-rule-declared-envelope",
        .layer = .unit,
        .category = .supply_voltages,
        .scope = .net,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "A net a design rule matches carries a DC voltage envelope.",
        .engine = "eval/authored_rules.zig - declared_envelope; req_design_rules.zig",
        .closes_with = "(net-rule \"text\" (nets GLOB…) (declared-envelope)) plus (net-envelope …)",
    },
    .{
        .id = "interface-voltage-domain",
        .layer = .system,
        .category = .supply_voltages,
        .scope = .net,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "A contract signal joins two board nets of the same declared potential.",
        .engine = "system_interface_check.zig - voltage_domain_mismatch",
        .closes_with = "align the rails, or declare the translation the contract needs",
    },
    .{
        .id = "check-voltage-range",
        .layer = .library,
        .category = .supply_voltages,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "The voltage on the named pin's net lies inside the datasheet window.",
        .engine = "eval/check_grammar.zig - voltage_range; req_checks.zig over eval/net_envelopes.zig",
        .closes_with = "(requirement \"…\" (check (voltage-range (pin \"V\") (min L) (max H))))",
    },
    .{
        .id = "check-voltage-not-above",
        .layer = .library,
        .category = .supply_voltages,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "The highest voltage on one pin's net stays within a margin of another's lowest.",
        .engine = "eval/check_grammar.zig - voltage_range alias; req_checks.zig",
        .closes_with = "(requirement \"…\" (check (voltage-not-above (pin \"A\") (pin \"B\") (margin M))))",
    },

    .{
        .id = "brief-input-power-envelope",
        .layer = .unit,
        .category = .supply_voltages,
        .scope = .net,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "The board net the system brief's input power feeds proves an envelope covering the brief's (voltage LO HI) window and any (transient V) it must survive.",
        .engine = "brief_checks.zig - Observation brief-input-power-envelope, via preflight FindingKind.brief",
        .closes_with = "(port … (rated LO HI)) or (net-envelope \"NET\" (rated LO HI)) on the input net, and (input-power … (feeds \"NET\")) in the brief",
    },

    // ── Power budget and copper ───────────────────────────────────
    .{
        .id = "rail-budget-margin",
        .layer = .unit,
        .category = .power_budget,
        .scope = .rail,
        .policy = .blocking,
        .verdicts = declared_screened,
        .asserts = "Every rail's annotated load stays inside its source's rating with margin.",
        .engine = "eval/power_budget.zig - RailStatus ok/tight/over; erc.zig power_budget",
        .closes_with = "(i-typ …) / (i-max …) on the consumer pins, or a bigger source",
    },
    .{
        .id = "rail-sourced",
        .layer = .unit,
        .category = .power_budget,
        .scope = .rail,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every rail that carries load has a declared source.",
        .engine = "eval/power_budget.zig - RailStatus.no_source",
        .closes_with = "(rail \"NAME\" … (current …)) on the regulator or input port",
    },
    .{
        .id = "rail-consumers-annotated",
        .layer = .unit,
        .category = .power_budget,
        .scope = .rail,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every sourced rail has at least one annotated consumer to budget against.",
        .engine = "eval/power_budget.zig - RailStatus.no_consumers",
        .closes_with = "(i-typ …) / (i-max …) on the pins the rail feeds",
    },
    .{
        .id = "rail-source-used",
        .layer = .unit,
        .category = .power_budget,
        .scope = .rail,
        .policy = .advisory,
        .verdicts = binary,
        .asserts = "Every declared supply source feeds something.",
        .engine = "erc.zig - source_unused",
        .closes_with = "wire the source's output, or delete the unused source",
    },
    .{
        .id = "supply-pin-current-annotated",
        .layer = .unit,
        .category = .power_budget,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "A classed part's supply pins carry the current annotations the budget needs.",
        .engine = "review_profiles.zig - supply-current; preflight profile_incomplete",
        .closes_with = "(i-typ A) and (i-max A) on the instance's supply pin forms",
    },
    .{
        .id = "power-width",
        .layer = .unit,
        .category = .power_budget,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Routed power copper meets the IPC-2221 width for the current it was solved to carry.",
        .engine = "placement/drc.zig - power_width; placement/drc_power_width.zig",
        .closes_with = "widen the branch, or correct the (i-max …) model it was solved from",
    },
    .{
        .id = "power-width-envelope",
        .layer = .unit,
        .category = .power_budget,
        .scope = .net,
        .policy = .waivable,
        .verdicts = declared_screened,
        .asserts = "Power copper whose per-branch solve failed still meets the whole-rail envelope width.",
        .engine = "placement/drc.zig - power_width_envelope; placement/drc_power_width.zig",
        .closes_with = "fix the current model the finding names, or widen the copper",
    },
    .{
        .id = "via-current",
        .layer = .unit,
        .category = .power_budget,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every power via carries no more solved current than its plated barrel can take.",
        .engine = "placement/drc.zig - via_current; placement/drc_power_via.zig",
        .closes_with = "stitch the extra barrels the finding counts",
    },
    .{
        .id = "via-current-envelope",
        .layer = .unit,
        .category = .power_budget,
        .scope = .net,
        .policy = .waivable,
        .verdicts = declared_screened,
        .asserts = "A via whose net current did not solve still carries the whole-rail envelope.",
        .engine = "placement/drc.zig - via_current_envelope; placement/drc_power_via.zig",
        .closes_with = "fix the current model, or add same-net barrels beside it",
    },

    // ── Decoupling and bulk ───────────────────────────────────────
    .{
        .id = "supply-pin-decoupled",
        .layer = .unit,
        .category = .decoupling,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = declared_screened,
        .asserts = "Every supply pin has the decoupling its datasheet rule demands.",
        .engine = "erc.zig - missing_decoupling; decouple_key.zig",
        .closes_with = "place the capacitor, and bind it with (decouples \"REF\" \"PIN\")",
    },
    .{
        .id = "decoupling-binding-resolved",
        .layer = .unit,
        .category = .decoupling,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every declared decoupling binding resolves to a placed capacitor and pin.",
        .engine = "erc.zig - decoupling_unbound",
        .closes_with = "correct the (decouples …) target, or place the capacitor",
    },
    .{
        .id = "decoupling-binding-valid",
        .layer = .unit,
        .category = .decoupling,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every decoupling binding is well formed.",
        .engine = "erc.zig - invalid_decoupling_binding",
        .closes_with = "rewrite the (decouples …) form as the reference documents it",
    },
    .{
        .id = "rail-bulk-present",
        .layer = .unit,
        .category = .decoupling,
        .scope = .rail,
        .policy = .waivable,
        .verdicts = waivable_row,
        .asserts = "Every power rail carries bulk capacitance.",
        .engine = "erc.zig - power_no_cap",
        .closes_with = "place bulk on the rail, or (net-rule … (min-bulk-uf F)) to state the target",
    },
    .{
        .id = "supply-pin-decoupling-rule",
        .layer = .unit,
        .category = .decoupling,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every supply pin of a classed part carries a decoupling requirement.",
        .engine = "review_profiles.zig - supply-decoupling-check; preflight profile_incomplete",
        .closes_with = "(requirement \"…\" (check (decoupling …))) or a (decoupling-per-pin …) rule",
    },
    .{
        .id = "drc-bypass-open",
        .layer = .unit,
        .category = .decoupling,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "A bypass capacitor's rail land reaches its IC supply land on continuous same-face copper.",
        .engine = "placement/drc.zig - bypass_open; placement/bypass_open.zig",
        .closes_with = "route the local rail copper between the two lands",
    },
    .{
        .id = "net-rule-min-bulk-uf",
        .layer = .unit,
        .category = .decoupling,
        .scope = .net,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Capacitance to ground on a matched net meets the declared minimum.",
        .engine = "eval/authored_rules.zig - min_bulk_uf; req_design_rules.zig",
        .closes_with = "(net-rule \"text\" (nets GLOB…) (min-bulk-uf F))",
    },
    .{
        .id = "check-decoupling",
        .layer = .library,
        .category = .decoupling,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "A capacitor of the required value bridges the two named pins' nets.",
        .engine = "eval/check_grammar.zig - decoupling; req_checks.zig",
        .closes_with = "(requirement \"…\" (check (decoupling (pin \"A\") (pin \"B\") (min-uf F))))",
    },
    .{
        .id = "check-decoupling-per-pin",
        .layer = .library,
        .category = .decoupling,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "At least the required count of the listed pins each have their own bypass capacitor.",
        .engine = "eval/check_grammar.zig - decoupling_per_pin; req_checks.zig",
        .closes_with = "(requirement \"…\" (check (decoupling-per-pin (return-pin \"GND\") (pins …) (min-uf F) (count N))))",
    },

    // ── Sequencing and levels ─────────────────────────────────────
    .{
        .id = "enable-order-acyclic",
        .layer = .unit,
        .category = .sequencing_levels,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The derived enable graph has no cycle, so a power-up order exists.",
        .engine = "erc.zig - sequence_cycle; eval/power_sequencing.zig",
        .closes_with = "break the cycle in the (enable …) declarations",
    },
    .{
        .id = "logic-level-compatible",
        .layer = .unit,
        .category = .sequencing_levels,
        .scope = .net,
        .policy = .blocking,
        .verdicts = declared_screened,
        .asserts = "Every driver's declared output levels reach its receivers' input thresholds.",
        .engine = "erc.zig - voltage_domain_incompatible; eval/electrical.zig",
        .closes_with = "(electrical \"PIN\" (type …) (v-ih-min V) (v-il-max V) …) plus a level shifter where needed",
    },
    .{
        .id = "control-pin-levels-declared",
        .layer = .unit,
        .category = .sequencing_levels,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every control pin of a classed part declares its logic thresholds.",
        .engine = "review_profiles.zig - control-levels; preflight profile_incomplete",
        .closes_with = "(electrical \"PIN\" (type input) (v-ih-min V) (v-il-max V) (max-voltage V))",
    },
    .{
        .id = "check-sequence",
        .layer = .library,
        .category = .sequencing_levels,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "The rail on one pin powers up before the rail on another.",
        .engine = "eval/check_grammar.zig - sequence; req_checks.zig over eval/power_sequencing.zig",
        .closes_with = "(requirement \"…\" (check (sequence (pin \"A\") before (pin \"B\"))))",
    },

    // ── Component ratings ─────────────────────────────────────────
    .{
        .id = "component-rating-missing",
        .layer = .unit,
        .category = .component_ratings,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every passive whose stress the gate screens declares its rating.",
        .engine = "fab_readiness.zig - component-rating-missing",
        .closes_with = "author the rating attribute at the call site or in the parts table",
    },
    .{
        .id = "component-rating-invalid",
        .layer = .unit,
        .category = .component_ratings,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every declared rating parses as a number with a unit the screen understands.",
        .engine = "fab_readiness.zig - component-rating-invalid",
        .closes_with = "rewrite the rating attribute in the documented spelling",
    },
    .{
        .id = "component-rating-unproven",
        .layer = .unit,
        .category = .component_ratings,
        .scope = .part,
        .policy = .waivable,
        .verdicts = declared_screened,
        .asserts = "The stress applied to a rated part is known, so the rating can be judged.",
        .engine = "fab_readiness.zig - component-rating-unproven",
        .closes_with = "(net-envelope …) or a port rating that fixes the applied stress",
    },
    .{
        .id = "component-underrated",
        .layer = .unit,
        .category = .component_ratings,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "No part sees an applied voltage, power or current above its rating.",
        .engine = "fab_readiness.zig - component-underrated",
        .closes_with = "up-rate the part, or reduce the applied stress",
    },
    .{
        .id = "component-rating-margin",
        .layer = .unit,
        .category = .component_ratings,
        .scope = .part,
        .policy = .waivable,
        .verdicts = waivable_row,
        .asserts = "Every rated part keeps the derating margin the screen asks for.",
        .engine = "fab_readiness.zig - component-rating-margin",
        .closes_with = "up-rate the part, or record the accepted margin",
    },
    .{
        .id = "check-cap-rating",
        .layer = .library,
        .category = .component_ratings,
        .scope = .part,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "Every capacitor bridging the named pins is rated the required multiple of its working voltage.",
        .engine = "eval/check_grammar.zig - cap_rating; req_checks.zig",
        .closes_with = "(requirement \"…\" (check (cap-rating (pin \"A\") (pin \"B\") (min-ratio X))))",
    },

    .{
        .id = "part-temperature-grade",
        .layer = .unit,
        .category = .component_ratings,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every placed part's declared temperature grade meets or exceeds the grade the system brief requires.",
        .engine = "brief_checks.zig - Observation part-temperature-grade, via preflight FindingKind.brief",
        .closes_with = "(temperature-grade industrial) on the component, the call site, or the parts-table row",
    },
    .{
        .id = "component-derating-standard",
        .layer = .unit,
        .category = .component_ratings,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Applied stress stays inside the fraction of each part's rating that the derating standard named by the system brief allows.",
        .engine = "fab_readiness.zig - component-derating (ceramic voltage, resistor power, inductor current)",
        .closes_with = "select a higher-rated part, or state the programme's own standard in (derating \"…\")",
    },

    // ── Thermal ───────────────────────────────────────────────────
    .{
        .id = "thermal-dissipation-known",
        .layer = .unit,
        .category = .thermal,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every active part's dissipation is declared or derivable.",
        .engine = "eval/thermal.zig - PowerSource.none, Verdict.insufficient_data",
        .closes_with = "(power W) on the instance, or annotated supply-pin currents",
    },
    .{
        .id = "thermal-theta-ja-declared",
        .layer = .library,
        .category = .thermal,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every active part declares its junction-to-ambient resistance and maximum junction temperature.",
        .engine = "eval/thermal.zig - thermal_field_docs; review_profiles.zig thermal-decl",
        .closes_with = "(thermal (theta-ja C/W) (tj-max C)) in the component body",
    },
    .{
        .id = "thermal-junction-margin",
        .layer = .unit,
        .category = .thermal,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared_screened,
        .asserts = "Every part's junction temperature stays under its limit at the screened ambient.",
        .engine = "eval/thermal.zig - Verdict passive_ok/needs_airflow/needs_heatsink/over_limit",
        .closes_with = "cut the dissipation, improve theta-ja, or move up the cooling ladder",
    },
    .{
        .id = "thermal-board-cooling-scenario",
        .layer = .unit,
        .category = .thermal,
        .scope = .board,
        .policy = .waivable,
        .verdicts = declared_screened,
        .asserts = "The board's screened cooling scenario is the one the release is built for.",
        .engine = "review_thermal.zig, thermal_scenarios.zig - scenario ladder",
        .closes_with = "(board (heatsink …)) or the airflow the release assumes",
    },

    .{
        .id = "thermal-brief-ambient",
        .layer = .unit,
        .category = .thermal,
        .scope = .board,
        .policy = .advisory,
        .verdicts = declared,
        .asserts = "The thermal screen runs at the ambient the governing system brief states, in the scenario its declared cooling case maps to.",
        .engine = "brief_checks.zig - Plan/AmbientSource, rendered by review_thermal.zig on all six thermal surfaces",
        .closes_with = "(brief (environment (ambient MIN MAX) (cooling …))) on the system that owns the board",
    },
    .{
        .id = "part-operating-range",
        .layer = .unit,
        .category = .thermal,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every placed part's rated ambient range covers the whole ambient window the system brief states.",
        .engine = "brief_checks.zig - Observation part-operating-range, via preflight FindingKind.brief",
        .closes_with = "(thermal (operating MIN MAX)) in the component body, or a part rated over the brief window",
    },

    // ── Datasheet compliance ──────────────────────────────────────
    .{
        .id = "datasheet-declared",
        .layer = .library,
        .category = .datasheet_compliance,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every active component declares the datasheet that documents it.",
        .engine = "review_datasheet_inventory.zig; preflight.zig datasheet coverage",
        .closes_with = "(datasheet \"FILE.pdf\") in the component body",
    },
    .{
        .id = "datasheet-review-complete",
        .layer = .library,
        .category = .datasheet_compliance,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared_screened,
        .asserts = "Every active part has a complete datasheet review bound to the exact PDF digest.",
        .engine = "preflight.zig - datasheet_review",
        .closes_with = "(datasheet-review (datasheet …) (sha256 …) (status complete) …)",
    },
    .{
        .id = "datasheet-review-categories",
        .layer = .library,
        .category = .datasheet_compliance,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "The review answers every category the part's class requires.",
        .engine = "review_profiles.zig - class-categories; preflight profile_incomplete",
        .closes_with = "(category KEY) or (category-na KEY \"rationale\") in the review record",
    },
    .{
        .id = "part-requirements-authored",
        .layer = .library,
        .category = .datasheet_compliance,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every active part carries at least one cited datasheet requirement.",
        .engine = "erc.zig - missing_requirements; review_profiles.zig requirements",
        .closes_with = "(requirement \"…\" (ref …) (check …)) or (ignore-requirements) for an inert part",
    },
    .{
        .id = "verification-evidence-incomplete",
        .layer = .unit,
        .category = .datasheet_compliance,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "The release carries the verification evidence its lock names.",
        .engine = "fab_gate.zig - verification-evidence-incomplete",
        .closes_with = "attach the verification evidence the release lock asks for",
    },
    .{
        .id = "class-profile-items-met",
        .layer = .unit,
        .category = .datasheet_compliance,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every active part meets every item of the component-class profile it was judged under.",
        .engine = "review_profiles.zig - evaluate; preflight.zig profile_incomplete",
        .closes_with = "author the declaration each unmet item names, or (class …) the part correctly",
    },
    .{
        .id = "requirement-check",
        .layer = .library,
        .category = .datasheet_compliance,
        .scope = .part,
        .policy = .blocking,
        .verdicts = &.{ .pass, .fail, .unproven, .waived, .not_applicable, .manual },
        .asserts = "Every requirement on a placed part passes its machine check or is signed off with a citation.",
        .engine = "preflight.zig - requirement; req_checks.zig",
        .closes_with = "fix the design, or (verifies (req (id …) …) \"rationale\") in the design's checks file",
    },
    .{
        .id = "verification-bound",
        .layer = .unit,
        .category = .datasheet_compliance,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every authored sign-off names a requirement that still exists.",
        .engine = "erc.zig - verification_orphaned",
        .closes_with = "retarget or delete the orphaned (verifies …) record",
    },
    .{
        .id = "check-pullup-range",
        .layer = .library,
        .category = .datasheet_compliance,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "A resistor in the datasheet's range bridges the named pin's net and the target net.",
        .engine = "eval/check_grammar.zig - pullup_range; req_checks.zig",
        .closes_with = "(requirement \"…\" (check (pullup-range (pin \"P\") (net \"N\") (min-ohms L) (max-ohms H))))",
    },
    .{
        .id = "check-series-element",
        .layer = .library,
        .category = .datasheet_compliance,
        .scope = .pin,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "An R, L or C of the required value bridges the named pin's net and the target net.",
        .engine = "eval/check_grammar.zig - series_element; req_checks.zig",
        .closes_with = "(requirement \"…\" (check (series-element (kind R) (pin \"P\") (target-net \"N\") (min X) (max Y))))",
    },
    .{
        .id = "check-feedback-divider",
        .layer = .library,
        .category = .datasheet_compliance,
        .scope = .part,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "The feedback divider computes the output voltage the rail declares.",
        .engine = "eval/check_grammar.zig - feedback_divider; req_derived_checks.zig",
        .closes_with = "(requirement \"…\" (check (feedback-divider (pin \"FB\") (return-net \"GND\") (reference-v V) (tolerance-pct P))))",
    },
    .{
        .id = "check-set-resistor-output",
        .layer = .library,
        .category = .datasheet_compliance,
        .scope = .part,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "The set resistor computes the output voltage the rail declares.",
        .engine = "eval/check_grammar.zig - set_resistor_output; req_derived_checks.zig",
        .closes_with = "(requirement \"…\" (check (set-resistor-output (pin \"SET\") (return-net \"GND\") (output-pin \"OUT\") (current-ua I) (tolerance-pct P))))",
    },

    // ── BOM ───────────────────────────────────────────────────────
    .{
        .id = "bom-identity",
        .layer = .unit,
        .category = .bom,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every purchasable placement carries a manufacturer part number.",
        .engine = "fab_readiness.zig, fab_gate.zig - bom-identity; bom_resolve.zig",
        .closes_with = "(mpn \"…\") at the call site or a parts-table row",
    },
    .{
        .id = "bom-spec-missing",
        .layer = .unit,
        .category = .bom,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every placed passive authors the specs its purchasable identity needs.",
        .engine = "fab_schematic_gate.zig - bom-spec-missing",
        .closes_with = "author voltage, dielectric and tolerance attributes at the call site",
    },
    .{
        .id = "bom-spec-unmatched",
        .layer = .unit,
        .category = .bom,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every authored passive spec matches a row of the design's parts table.",
        .engine = "fab_schematic_gate.zig - bom-spec-unmatched",
        .closes_with = "reconcile the call-site attributes with the parts-table row",
    },
    .{
        .id = "bom-spec-library-missing",
        .layer = .unit,
        .category = .bom,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "The library the passive spec screen reads is present.",
        .engine = "fab_schematic_gate.zig - bom-spec-library-missing",
        .closes_with = "add the parts-table or component library the gate names",
    },
    .{
        .id = "attribute-row-matches-parts-table",
        .layer = .unit,
        .category = .bom,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "A placement's typed attributes agree with the parts-table row it resolves to.",
        .engine = "erc.zig - attribute_row_mismatch; parts.zig",
        .closes_with = "edit the attributes or the parts-table row so they agree",
    },
    .{
        .id = "bom-selection-drift",
        .layer = .unit,
        .category = .bom,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every placement's fitted identity still matches the selection the BOM sidecar recorded.",
        .engine = "fab_schematic_gate.zig - bom-selection-drift",
        .closes_with = "rebuild the BOM, or restore the selection the design authored",
    },
    .{
        .id = "bom-evidence-incomplete",
        .layer = .unit,
        .category = .bom,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "The release carries the BOM evidence its lock names.",
        .engine = "fab_gate.zig - bom-evidence-incomplete",
        .closes_with = "attach the BOM evidence the release lock asks for",
    },
    .{
        .id = "bom-lifecycle-stock-dated",
        .layer = .unit,
        .category = .bom,
        .scope = .part,
        .policy = .waivable,
        .verdicts = judged,
        .asserts = "Every purchasable placement is a lifecycle-active part with a dated stock check.",
        .engine = "resolve_mpn and check_stock, read by a reviewer",
        .closes_with = "record the lifecycle and stock date, or replace the part",
    },
    .{
        .id = "centroid-parity",
        .layer = .unit,
        .category = .bom,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The assembly centroid lists exactly the placements the netlist does.",
        .engine = "fab_readiness.zig, fab_gate.zig - centroid-parity",
        .closes_with = "re-save the layout so every placement has a pose",
    },
    .{
        .id = "dnp-in-centroid",
        .layer = .unit,
        .category = .bom,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "No do-not-populate part appears in the assembly centroid.",
        .engine = "fab_readiness.zig - dnp-in-centroid",
        .closes_with = "mark the part (dnp), or remove it from the assembly output",
    },

    // ── Layout ────────────────────────────────────────────────────
    .{
        .id = "drc-copper-clearance",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every pair of different-net copper features keeps the board's clearance rule.",
        .engine = "placement/drc.zig - via_pad, via_via, via_track, track_track, track_pad, pad_pad",
        .closes_with = "move the copper, or relax (design-rules (clearance …)) with the fab's blessing",
    },
    .{
        .id = "drc-via-spacing",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Same-net vias keep the drill-to-drill spacing their copper gap needs.",
        .engine = "placement/drc.zig - via_spacing",
        .closes_with = "delete the redundant barrel, or space the pair",
    },
    .{
        .id = "drc-annular-ring",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every drilled feature keeps the fabricator's minimum annular ring.",
        .engine = "placement/drc.zig - annular, pad_annular",
        .closes_with = "grow the pad or shrink the drill",
    },
    .{
        .id = "drc-board-edge-clearance",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Copper and components keep clear of the routed board edge.",
        .engine = "placement/drc.zig - board_edge, component_edge",
        .closes_with = "move the feature inboard, or grow the outline",
    },
    .{
        .id = "drc-courtyard-overlap",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "No two component courtyards overlap.",
        .engine = "placement/drc.zig - courtyard",
        .closes_with = "separate the placements",
    },
    .{
        .id = "drc-hole-spacing",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every pair of holes keeps the fabricator's hole-to-hole wall.",
        .engine = "placement/drc.zig - hole_hole",
        .closes_with = "space the drills, or relax (design-rules (hole-to-hole …))",
    },
    .{
        .id = "drc-min-drill",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every drill is at least the fabricator's minimum diameter.",
        .engine = "placement/drc.zig - min_drill",
        .closes_with = "enlarge the drill, or pick a fab process that supports it",
    },
    .{
        .id = "drc-track-width",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every routed track is at least the minimum width the board declares.",
        .engine = "placement/drc.zig - track_width",
        .closes_with = "widen the track, or lower (design-rules (min-track-width …))",
    },
    .{
        .id = "drc-pour-integrity",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every final pour solid is one unambiguous, non-degenerate polygon with legal holes.",
        .engine = "placement/drc.zig - pour_invalid; placement/drc_pour.zig",
        .closes_with = "redraw the zone outline so its holes stay inside and apart",
    },
    .{
        .id = "drc-pour-overlap",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Different-net pours never touch on the same copper layer.",
        .engine = "placement/drc.zig - pour_overlap; placement/drc_pour.zig",
        .closes_with = "separate the zones, or give them the same net",
    },
    .{
        .id = "drc-copper-stub",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "No trace endpoint lands on nothing of its own net.",
        .engine = "placement/drc.zig - copper_stub",
        .closes_with = "finish the route, or delete the artifact copper",
    },
    .{
        .id = "drc-implicit-junction",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = binary,
        .asserts = "Same-net traces that touch record an explicit endpoint junction.",
        .engine = "placement/drc.zig - implicit_junction",
        .closes_with = "re-route the join, or canonicalize the saved copper",
    },
    .{
        .id = "drc-hairline-gap",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "No same-net copper is separated by a gap too small to see and too large to conduct.",
        .engine = "placement/drc.zig - hairline_gap",
        .closes_with = "close the gap with a real overlap",
    },
    .{
        .id = "drc-dangling-copper",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = binary,
        .asserts = "No stored trace section is electrically redundant.",
        .engine = "placement/drc.zig - dangling_copper",
        .closes_with = "delete the section, or re-route the net",
    },
    .{
        .id = "drc-single-layer-via",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = binary,
        .asserts = "Every via barrel reaches at least two copper layers.",
        .engine = "placement/drc.zig - single_layer_via",
        .closes_with = "delete the via, or route the second layer to it",
    },
    .{
        .id = "drc-redundant-via",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = binary,
        .asserts = "Every via is an articulation of its net's copper graph.",
        .engine = "placement/drc.zig - redundant_via",
        .closes_with = "delete the redundant barrels the finding names",
    },
    .{
        .id = "drc-land-transit",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = binary,
        .asserts = "Same-net copper on a pad's land is aimed at its centre, not lapping its flank.",
        .engine = "placement/drc.zig - land_transit; placement/land_transit.zig",
        .closes_with = "re-route the run into the land's centre",
    },
    .{
        .id = "drc-ground-via-distance",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = declared,
        .asserts = "Every SMD ground pad has a same-net through via inside the authored budget.",
        .engine = "placement/drc.zig - ground_via_distance; ground_via_seed.zig",
        .closes_with = "stitch a via near the pad, or widen (ground-via-max MM)",
    },
    .{
        .id = "drc-reference-plane-gap",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = declared,
        .asserts = "Fast-net copper never crosses a void in its own reference plane.",
        .engine = "placement/drc.zig - reference_plane_gap; placement/drc_return_path.zig",
        .closes_with = "re-route around the split, or fill the plane",
    },
    .{
        .id = "drc-reference-transition",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = declared,
        .asserts = "Every signal via that changes reference planes has its stitching via or cross-reference capacitor.",
        .engine = "placement/drc.zig - reference_transition; placement/drc_return_path.zig",
        .closes_with = "stitch the return beside the signal via",
    },
    .{
        .id = "drc-loop-area",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = declared,
        .asserts = "Estimated trace-to-reference loop area stays inside the net class's budget.",
        .engine = "placement/drc.zig - loop_area; placement/drc_return_path.zig",
        .closes_with = "(net-class … (return-path (max-loop-area …))) plus a tighter route",
    },
    .{
        .id = "drc-silk-over-pad",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .waivable,
        .verdicts = binary,
        .asserts = "No silkscreen lands on solderable copper.",
        .engine = "placement/drc.zig - silk_over_pad",
        .closes_with = "move or clip the silkscreen",
    },
    .{
        .id = "drc-diff-pair-coupling",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = declared,
        .asserts = "Every differential pair stays coupled along its route.",
        .engine = "placement/drc.zig - diff_uncoupled; placement/drc_diffpair.zig",
        .closes_with = "re-route the pair together",
    },
    .{
        .id = "drc-diff-pair-skew",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = declared,
        .asserts = "Every differential pair's halves stay length-matched within tolerance.",
        .engine = "placement/drc.zig - diff_skew; placement/drc_diffpair.zig",
        .closes_with = "add the matching meander to the short half",
    },
    .{
        .id = "drc-length-match",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = declared,
        .asserts = "Every match group's members stay inside the declared length spread.",
        .engine = "placement/drc.zig - length_mismatch; placement/drc_match.zig",
        .closes_with = "(net-class … (match-group \"NAME\" (tolerance MM))) plus tuning",
    },
    .{
        .id = "drc-sharp-bend",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = binary,
        .asserts = "No routed corner is sharper than the board's bend rule allows.",
        .engine = "placement/drc.zig - sharp_bend",
        .closes_with = "smooth the corner",
    },
    .{
        .id = "drc-net-class-keepout",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .waivable,
        .verdicts = declared,
        .asserts = "No foreign copper sits inside a net class's declared isolation halo.",
        .engine = "placement/drc.zig - keepout_violation; placement/drc_keepout.zig",
        .closes_with = "(net-class … (keepout MM)) plus moving the intruding copper",
    },
    .{
        .id = "drc-perimeter-keepout",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Nothing sits inside the board's authored perimeter exclusion band.",
        .engine = "placement/drc.zig - perimeter_keepout; placement/drc_perimeter_keepout.zig",
        .closes_with = "move the feature out of (board … (perimeter-fence … (keepout …)))",
    },
    .{
        .id = "drc-board-keepout",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Nothing sits inside a named mechanical keepout region.",
        .engine = "placement/drc.zig - board_keepout; placement/drc_board_keepout.zig",
        .closes_with = "move the feature out of (board … (keepout \"NAME\" (rect …)))",
    },
    .{
        .id = "net-open",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every net's drawn copper forms one connected island.",
        .engine = "placement/drc.zig - net_open; placement/net_open.zig via serve/drc_rules.zig",
        .closes_with = "route the missing link between the islands",
    },
    .{
        .id = "layout-evidence-incomplete",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "The release carries the layout evidence its lock names.",
        .engine = "fab_gate.zig - layout-evidence-incomplete",
        .closes_with = "attach the layout evidence the release lock asks for",
    },
    .{
        .id = "layout-ladder-complete",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "Every rung of the layout completion ladder is done on the reviewed layout.",
        .engine = "placement/progress.zig - completion ladder",
        .closes_with = "finish the open items the rung lists",
    },
    .{
        .id = "drc",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The release run reports zero DRC errors.",
        .engine = "fab_readiness.zig - drc",
        .closes_with = "fix the copper the DRC errors name",
    },
    .{
        .id = "drc-warn",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .waivable,
        .verdicts = waivable_row,
        .asserts = "Every DRC warning category is waived with a current count.",
        .engine = "fab_readiness.zig - drc-warn; waiver_register.zig",
        .closes_with = "fix the copper, or record the category in drc-waivers.md",
    },
    .{
        .id = "drc-missing",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "A DRC run exists for the layout the release is cut from.",
        .engine = "fab_readiness.zig - drc-missing",
        .closes_with = "run the design-rule check on the saved layout",
    },
    .{
        .id = "drc-incomplete",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = screened,
        .asserts = "The DRC run that the release reads covered the whole board.",
        .engine = "fab_readiness.zig - drc-incomplete",
        .closes_with = "re-run the design-rule check to completion",
    },
    .{
        .id = "hairline-gap",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The release run finds no hairline gap in the fabricated copper.",
        .engine = "fab_readiness.zig - hairline-gap",
        .closes_with = "close the gap with a real overlap",
    },
    .{
        .id = "connectivity-coarsened",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .waivable,
        .verdicts = screened,
        .asserts = "The connectivity the release judged was measured at full resolution.",
        .engine = "fab_readiness.zig - connectivity-coarsened",
        .closes_with = "re-run the release check without the coarsened raster",
    },
    .{
        .id = "unrouted-net",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every net of the board is routed.",
        .engine = "fab_readiness.zig - unrouted-net",
        .closes_with = "route the remaining airwires",
    },
    .{
        .id = "no-outline",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "The board declares an outline.",
        .engine = "fab_readiness.zig - no-outline",
        .closes_with = "(board (outline …)) on the design",
    },
    .{
        .id = "malformed-outline",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The declared board outline is a closed, non-degenerate polygon.",
        .engine = "fab_readiness.zig - malformed-outline; placement/outline.zig",
        .closes_with = "redraw the outline so it closes",
    },
    .{
        .id = "outline-drift",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "The saved layout's outline matches the one the design declares.",
        .engine = "fab_readiness.zig - outline-drift",
        .closes_with = "re-save the layout, or restore the declared outline",
    },
    .{
        .id = "part-off-board",
        .layer = .unit,
        .category = .layout,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every placement sits inside the board outline.",
        .engine = "fab_readiness.zig - part-off-board",
        .closes_with = "move the placement onto the board",
    },
    .{
        .id = "via-no-drill",
        .layer = .unit,
        .category = .layout,
        .scope = .board,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every via carries a drill diameter the fabricator can build.",
        .engine = "fab_readiness.zig - via-no-drill",
        .closes_with = "give the via a drill, or delete it",
    },
    .{
        .id = "footprint-geometry-unresolved",
        .layer = .unit,
        .category = .layout,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every placement's footprint geometry resolves rather than falling back.",
        .engine = "fab_readiness.zig, fab_gate.zig - footprint-geometry-unresolved",
        .closes_with = "add the footprint to the library, or fix the reference",
    },
    .{
        .id = "layout-class-declared",
        .layer = .unit,
        .category = .layout,
        .scope = .part,
        .policy = .advisory,
        .verdicts = declared,
        .asserts = "Every placement states its layout class instead of relying on inference.",
        .engine = "erc.zig - layout_class_inferred; placement/module_policy.zig",
        .closes_with = "(layout-class <key>) on the instance or module",
    },
    .{
        .id = "near-binding-valid",
        .layer = .unit,
        .category = .layout,
        .scope = .part,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every placement-proximity binding names entities that exist.",
        .engine = "erc.zig - invalid_near_binding",
        .closes_with = "correct the (near …) target",
    },
    .{
        .id = "emi-coupling-valid",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .blocking,
        .verdicts = binary,
        .asserts = "Every declared EMI coupling names entities that exist.",
        .engine = "erc.zig - invalid_emi_coupling",
        .closes_with = "correct the coupling declaration's target",
    },
    .{
        .id = "net-rule-in-net-class",
        .layer = .unit,
        .category = .layout,
        .scope = .net,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "A net a design rule matches is listed by some net class.",
        .engine = "eval/authored_rules.zig - in_net_class; req_design_rules.zig",
        .closes_with = "(net-class \"NAME\" (nets …)) covering the net",
    },
    .{
        .id = "check-max-distance",
        .layer = .library,
        .category = .layout,
        .scope = .part,
        .policy = .waivable,
        .verdicts = declared_screened,
        .asserts = "The nearest matching passive sits within the datasheet's distance of the pad.",
        .engine = "eval/check_grammar.zig - max_distance; req_physical_checks.zig req-distance-far lint",
        .closes_with = "(requirement \"…\" (check (max-distance (pin \"P\") (kind C) (mm D)))) plus moving the part",
    },
    .{
        .id = "system-waiver-register",
        .layer = .system,
        .category = .layout,
        .scope = .system,
        .policy = .blocking,
        .verdicts = declared_waivable,
        .asserts = "A board that needs DRC waivers has a register whose counts match the release run.",
        .engine = "system_review_package.zig - GateState.waivers_ok; waiver_register.zig",
        .closes_with = "update drc-waivers.md so each category's count matches",
    },

    // ── Domain analyses ───────────────────────────────────────────
    .{
        .id = "class-analysis-form-gated",
        .layer = .unit,
        .category = .domain_analyses,
        .scope = .part,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "A part whose class demands a design-level analysis has that analysis in gate mode.",
        .engine = "review_profiles.zig - analysis-form; preflight profile_incomplete",
        .closes_with = "(pll-loop … (mode gate)) or (frequency-plan … (mode gate)) on the design",
    },
    .{
        .id = "pll-loop-binding",
        .layer = .unit,
        .category = .domain_analyses,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared_screened,
        .asserts = "The declared loop filter binds to real placed parts with usable values and dielectrics.",
        .engine = "pll_loop.zig - binding, bom_values, capacitor_dielectric, synthesis_stale_pin, synthesis_replacement, synthesis_profile, synthesis_pin_offer",
        .closes_with = "pin the loop components in the (pll-loop …) form and author their specs",
    },
    .{
        .id = "pll-loop-stability",
        .layer = .unit,
        .category = .domain_analyses,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared_screened,
        .asserts = "The loop solves a crossover with the phase margin, PFD and amplifier ratios the screens demand.",
        .engine = "pll_loop.zig - crossover_solve, nominal_sweep, nominal_phase_target, tolerance_corners, pfd_ratio, gbw_ratio, gbw_preferred, polarity",
        .closes_with = "re-solve the loop values, or widen the declared targets with a rationale",
    },
    .{
        .id = "pll-loop-operating-range",
        .layer = .unit,
        .category = .domain_analyses,
        .scope = .board,
        .policy = .waivable,
        .verdicts = declared_screened,
        .asserts = "The loop stays inside its tune, swing and supply limits across the scheduled operating curve.",
        .engine = "pll_loop.zig - operating_curve, scheduled_curve, output_swing, op_amp_supply, vtune_slew, charge_pump_suggestion, synthesis_schedule",
        .closes_with = "re-schedule the charge-pump current, or change the op-amp supply",
    },
    .{
        .id = "pll-loop-ramp-phase-error",
        .layer = .unit,
        .category = .domain_analyses,
        .scope = .board,
        .policy = .waivable,
        .verdicts = declared_screened,
        .asserts = "Ramp phase error stays inside the declared budget.",
        .engine = "pll_loop.zig - ramp_phase_error, synthesis_ramp_phase_error",
        .closes_with = "widen the loop bandwidth, or slow the ramp",
    },
    .{
        .id = "frequency-plan-lo-drive",
        .layer = .unit,
        .category = .domain_analyses,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared_screened,
        .asserts = "The LO drive delivered to each mixer stays inside its datasheet window.",
        .engine = "frequency_plan.zig - lo_drive",
        .closes_with = "adjust the gain chain, or restate the window in (frequency-plan …)",
    },
    .{
        .id = "frequency-plan-band-coverage",
        .layer = .unit,
        .category = .domain_analyses,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared_screened,
        .asserts = "The declared sources and filters cover the whole band the plan claims.",
        .engine = "frequency_plan.zig - rf_window, band_closure, source_range, spur_coverage",
        .closes_with = "extend the source range or the filters, or narrow the claimed band",
    },
    .{
        .id = "frequency-plan-spurious",
        .layer = .unit,
        .category = .domain_analyses,
        .scope = .board,
        .policy = .waivable,
        .verdicts = declared_screened,
        .asserts = "Every image and mixing product lands outside the band or under the declared limit.",
        .engine = "frequency_plan.zig - image_band, spur_placement, spur_levels, diagonal_family",
        .closes_with = "re-plan the LO, add filtering, or disposition the spur with evidence",
    },
    .{
        .id = "pdn-impedance-target",
        .layer = .unit,
        .category = .domain_analyses,
        .scope = .rail,
        .policy = .waivable,
        .verdicts = declared_screened,
        .asserts = "A rail with a declared PDN target meets it across the analysed band.",
        .engine = "placement/pdn_impedance.zig - analyze, analyzeCopper",
        .closes_with = "add bulk or bypass, or restate the rail's impedance target",
    },
    .{
        .id = "design-assertion",
        .layer = .unit,
        .category = .domain_analyses,
        .scope = .board,
        .policy = .blocking,
        .verdicts = declared,
        .asserts = "Every design-authored assertion holds when the design is built.",
        .engine = "eval/special_forms.zig - assert, assert-range",
        .closes_with = "(assert …) / (assert-range …) on the value that must hold",
    },
};

/// The registered row with this id, or null when nothing claims it. Findings
/// carry ids; a surface joins them to the catalogue through this.
pub fn lookup(id: []const u8) ?Row {
    for (rows) |row| {
        if (std.mem.eql(u8, row.id, id)) return row;
    }
    return null;
}

/// The registry id an electrical-rule violation belongs to. Exhaustive: a new
/// `erc.ViolationKind` is a compile error until it is registered here.
pub fn ercId(kind: erc.ViolationKind) []const u8 {
    return switch (kind) {
        .duplicate_refdes => "refdes-unique",
        .floating_net => "net-not-floating",
        .unconnected_pin => "pin-connected",
        .no_connect => "no-connect-dispositioned",
        .missing_value => "instance-value-present",
        .missing_footprint => "instance-footprint-present",
        .voltage_mismatch => "rail-voltage-consistent",
        .missing_decoupling => "supply-pin-decoupled",
        .decoupling_unbound => "decoupling-binding-resolved",
        .invalid_decoupling_binding => "decoupling-binding-valid",
        .invalid_near_binding => "near-binding-valid",
        .invalid_emi_coupling => "emi-coupling-valid",
        .strap_tied_to_rail => "strap-dispositioned",
        .power_no_cap => "rail-bulk-present",
        .concept_remaining => "concept-resolved",
        .pin_multi_net => "pin-single-net",
        .pin_function_unsupported => "pin-function-known",
        .pin_function_required => "pin-function-required",
        .power_budget => "rail-budget-margin",
        .test_point_missing => "test-point-present",
        .source_unused => "rail-source-used",
        .rail_voltage_unresolved => "rail-voltage-resolved",
        .sequence_cycle => "enable-order-acyclic",
        .voltage_domain_incompatible => "logic-level-compatible",
        .voltage_overstress => "pin-abs-max-respected",
        .missing_requirements => "part-requirements-authored",
        .direct_component_implementation => "module-reuse-preferred",
        .module_metadata_incomplete => "module-metadata-complete",
        .layout_class_inferred => "layout-class-declared",
        .section_category_inferred => "section-category-declared",
        .deprecated_form => "no-deprecated-forms",
        .components_not_grouped => "blocks-grouped",
        .verification_orphaned => "verification-bound",
        .diff_pair_half_connected => "diff-pair-both-halves",
        .interface_half_connected => "interface-fully-wired",
        .interface_naming => "interface-naming-consistent",
        .attribute_row_mismatch => "attribute-row-matches-parts-table",
    };
}

/// The registry id a design-rule-check finding belongs to. Clearance-family
/// kinds share one row because they close the same way; the power, via-current
/// and open-net kinds keep their own. Exhaustive by construction.
pub fn drcId(kind: drc.Kind) []const u8 {
    return switch (kind) {
        .via_pad, .via_via, .via_track, .track_track, .track_pad, .pad_pad => "drc-copper-clearance",
        .via_spacing => "drc-via-spacing",
        .annular, .pad_annular => "drc-annular-ring",
        .board_edge, .component_edge => "drc-board-edge-clearance",
        .courtyard => "drc-courtyard-overlap",
        .hole_hole => "drc-hole-spacing",
        .min_drill => "drc-min-drill",
        .track_width => "drc-track-width",
        .power_width => "power-width",
        .power_width_envelope => "power-width-envelope",
        .via_current => "via-current",
        .via_current_envelope => "via-current-envelope",
        .pour_invalid => "drc-pour-integrity",
        .pour_overlap => "drc-pour-overlap",
        .copper_stub => "drc-copper-stub",
        .implicit_junction => "drc-implicit-junction",
        .hairline_gap => "drc-hairline-gap",
        .dangling_copper => "drc-dangling-copper",
        .single_layer_via => "drc-single-layer-via",
        .redundant_via => "drc-redundant-via",
        .land_transit => "drc-land-transit",
        .ground_via_distance => "drc-ground-via-distance",
        .reference_plane_gap => "drc-reference-plane-gap",
        .reference_transition => "drc-reference-transition",
        .loop_area => "drc-loop-area",
        .bypass_open => "drc-bypass-open",
        .silk_over_pad => "drc-silk-over-pad",
        .diff_uncoupled => "drc-diff-pair-coupling",
        .diff_skew => "drc-diff-pair-skew",
        .length_mismatch => "drc-length-match",
        .sharp_bend => "drc-sharp-bend",
        .keepout_violation => "drc-net-class-keepout",
        .perimeter_keepout => "drc-perimeter-keepout",
        .board_keepout => "drc-board-keepout",
        .net_open => "net-open",
    };
}

/// Every finding id the fabrication gate, the readiness screen and the
/// schematic gate can emit. Each is registered under its own name, so the
/// gate's id IS the registry id; the test below proves it.
pub const fab_finding_ids: []const []const u8 = &.{
    "bom-evidence-incomplete",
    "bom-identity",
    "bom-selection-drift",
    "bom-spec-library-missing",
    "bom-spec-missing",
    "bom-spec-unmatched",
    "cache-layout",
    "centroid-parity",
    "component-derating-standard",
    "component-rating-invalid",
    "component-rating-margin",
    "component-rating-missing",
    "component-rating-unproven",
    "component-underrated",
    "connectivity-coarsened",
    "dnp-in-centroid",
    "drc",
    "drc-incomplete",
    "drc-missing",
    "drc-warn",
    "duplicate-identity",
    "duplicate-source-identity",
    "fabrication-identity-incomplete",
    "footprint-geometry-unresolved",
    "hairline-gap",
    "layout-evidence-incomplete",
    "malformed-outline",
    "missing-identity",
    "no-outline",
    "outline-drift",
    "part-off-board",
    "revision-missing",
    "reviewed-input-evidence-incomplete",
    "schematic-check-failed",
    "source-bundle-ambiguous",
    "source-revision-unavailable",
    "source-snapshot-changed",
    "source-worktree-dirty",
    "unresolvable-pin",
    "unrouted-net",
    "verification-evidence-incomplete",
    "via-no-drill",
};

/// The registry id a fabrication finding belongs to, or null when the id is
/// not one the registry knows.
///
/// Most gate findings carry the gate's own id, which IS the registry id. The
/// schematic half of the gate instead folds the release check run in under the
/// check KIND's name (`requirement`, `assertion`, …), so those spellings are
/// aliased onto the rows that already carry those checks rather than being
/// registered a second time.
pub fn fabFindingId(finding_id: []const u8) ?[]const u8 {
    if (lookup(finding_id)) |row| return row.id;
    return keyedId(fab_alias_table, finding_id);
}

/// A string key of an engine vocabulary paired with the registry row it means.
const KeyedId = struct {
    /// The engine's own spelling — a profile item code, a check keyword, a
    /// net-rule predicate keyword, or a system gate-state field name.
    key: []const u8,
    /// The registry id that key resolves to.
    id: []const u8,
};

fn keyedId(table: []const KeyedId, key: []const u8) ?[]const u8 {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.id;
    }
    return null;
}

/// Check-run kind names the fabrication gate emits as finding ids, each paired
/// with the registry row that already carries that check.
const fab_alias_table: []const KeyedId = &.{
    .{ .key = "requirement", .id = "requirement-check" },
    .{ .key = "assertion", .id = "design-assertion" },
    .{ .key = "profile_incomplete", .id = "class-profile-items-met" },
    .{ .key = "datasheet_review", .id = "datasheet-review-complete" },
    .{ .key = "eval_warning", .id = "build-warning-free" },
    .{ .key = "erc", .id = "erc-clean" },
};

/// The eight class-profile item codes `review_profiles.evaluate` can push,
/// each paired with the registry row it fills.
const profile_item_table: []const KeyedId = &.{
    .{ .key = "requirements", .id = "part-requirements-authored" },
    .{ .key = "supply-voltage-check", .id = "supply-pin-voltage-rule" },
    .{ .key = "supply-decoupling-check", .id = "supply-pin-decoupling-rule" },
    .{ .key = "supply-current", .id = "supply-pin-current-annotated" },
    .{ .key = "control-levels", .id = "control-pin-levels-declared" },
    .{ .key = "class-categories", .id = "datasheet-review-categories" },
    .{ .key = "thermal-decl", .id = "thermal-theta-ja-declared" },
    .{ .key = "analysis-form", .id = "class-analysis-form-gated" },
};

/// The registry id a `profile_incomplete` finding's item code belongs to.
pub fn profileItemId(code: []const u8) ?[]const u8 {
    return keyedId(profile_item_table, code);
}

/// The four brief-driven check ids `brief_checks.observe` can produce. A
/// `.brief` finding carries its id in `requirement.id`, so the join is a
/// membership test rather than a second spelling of the vocabulary.
const brief_check_table: []const KeyedId = &.{
    .{ .key = "part-operating-range", .id = "part-operating-range" },
    .{ .key = "part-temperature-grade", .id = "part-temperature-grade" },
    .{ .key = "brief-input-power-envelope", .id = "brief-input-power-envelope" },
    .{ .key = "interface-esd-protection", .id = "interface-esd-protection" },
};

/// The registry id a brief-driven check code belongs to, or null when the code
/// is not one `brief_checks` can emit.
pub fn briefCheckId(code: []const u8) ?[]const u8 {
    return keyedId(brief_check_table, code);
}

/// The registry id a strict-preflight finding belongs to. `code` is the
/// `profile_incomplete` item code or the `brief` check id and is ignored for
/// the other kinds; an unregistered code yields null.
pub fn preflightId(kind: preflight.FindingKind, code: []const u8) ?[]const u8 {
    return switch (kind) {
        .requirement => "requirement-check",
        .datasheet_review => "datasheet-review-complete",
        .eval_warning => "build-warning-free",
        .profile_incomplete => profileItemId(code),
        .brief => briefCheckId(code),
    };
}

/// The sixteen documented `(check …)` primitives, keyed by the leading
/// keyword `check_grammar.parseCheck` dispatches on.
const check_primitive_table: []const KeyedId = &.{
    .{ .key = "connected", .id = "check-connected" },
    .{ .key = "decoupling", .id = "check-decoupling" },
    .{ .key = "pullup-range", .id = "check-pullup-range" },
    .{ .key = "voltage-range", .id = "check-voltage-range" },
    .{ .key = "tied-to-net", .id = "check-tied-to-net" },
    .{ .key = "not-connected", .id = "check-not-connected" },
    .{ .key = "pin-not-floating", .id = "check-pin-not-floating" },
    .{ .key = "pins-on-same-net", .id = "check-pins-on-same-net" },
    .{ .key = "decoupling-per-pin", .id = "check-decoupling-per-pin" },
    .{ .key = "series-element", .id = "check-series-element" },
    .{ .key = "feedback-divider", .id = "check-feedback-divider" },
    .{ .key = "set-resistor-output", .id = "check-set-resistor-output" },
    .{ .key = "cap-rating", .id = "check-cap-rating" },
    .{ .key = "max-distance", .id = "check-max-distance" },
    .{ .key = "sequence", .id = "check-sequence" },
    .{ .key = "voltage-not-above", .id = "check-voltage-not-above" },
};

/// The registry id a requirement-check primitive belongs to, keyed by the
/// keyword written inside `(check …)`.
pub fn checkPrimitiveId(keyword: []const u8) ?[]const u8 {
    return keyedId(check_primitive_table, keyword);
}

/// The four `(net-rule …)` predicates, keyed by their leading keyword.
const net_rule_table: []const KeyedId = &.{
    .{ .key = "min-bulk-uf", .id = "net-rule-min-bulk-uf" },
    .{ .key = "declared-envelope", .id = "net-rule-declared-envelope" },
    .{ .key = "in-net-class", .id = "net-rule-in-net-class" },
    .{ .key = "max-fanout", .id = "net-rule-max-fanout" },
};

/// The registry id a design-owned net-rule predicate belongs to.
pub fn netRulePredicateId(keyword: []const u8) ?[]const u8 {
    return keyedId(net_rule_table, keyword);
}

/// The registry id a power-budget rail verdict belongs to: a margin verdict
/// is the budget row, while a missing source or missing consumers is the row
/// naming the input the rail never got.
pub fn railStatusId(status: power_budget.RailStatus) []const u8 {
    return switch (status) {
        .ok, .tight, .over => "rail-budget-margin",
        .no_source => "rail-sourced",
        .no_consumers => "rail-consumers-annotated",
    };
}

/// The registry id a thermal screen verdict belongs to: a screened part is
/// the junction-margin row, an unscreenable one the dissipation row.
pub fn thermalVerdictId(verdict: thermal.Verdict) []const u8 {
    return switch (verdict) {
        .passive_ok, .needs_airflow, .needs_heatsink, .over_limit => "thermal-junction-margin",
        .insufficient_data => "thermal-dissipation-known",
    };
}

/// The registry id a PLL loop screen belongs to. The twenty-four screens fall
/// into four rows: binding the filter, solving the loop, holding the
/// operating range, and the ramp phase-error budget.
pub fn pllScreenId(screen: pll_loop.Screen) []const u8 {
    return switch (screen) {
        .binding,
        .bom_values,
        .capacitor_dielectric,
        .synthesis_stale_pin,
        .synthesis_replacement,
        .synthesis_profile,
        .synthesis_pin_offer,
        => "pll-loop-binding",
        .crossover_solve,
        .nominal_sweep,
        .nominal_phase_target,
        .tolerance_corners,
        .pfd_ratio,
        .gbw_ratio,
        .gbw_preferred,
        .polarity,
        => "pll-loop-stability",
        .operating_curve,
        .scheduled_curve,
        .output_swing,
        .op_amp_supply,
        .vtune_slew,
        .charge_pump_suggestion,
        .synthesis_schedule,
        => "pll-loop-operating-range",
        .ramp_phase_error, .synthesis_ramp_phase_error => "pll-loop-ramp-phase-error",
    };
}

/// The registry id a frequency-plan screen belongs to: LO drive, band
/// coverage, or the spurious-product budget.
pub fn frequencyPlanScreenId(screen: frequency_plan.Screen) []const u8 {
    return switch (screen) {
        .lo_drive => "frequency-plan-lo-drive",
        .rf_window, .band_closure, .source_range, .spur_coverage => "frequency-plan-band-coverage",
        .image_band, .spur_placement, .spur_levels, .diagonal_family => "frequency-plan-spurious",
    };
}

/// The registry id a system interface-contract mismatch belongs to.
pub fn interfaceMismatchId(kind: system_interface_check.Kind) []const u8 {
    return switch (kind) {
        .contact_unconnected_one_side => "interface-contact-connected",
        .voltage_domain_mismatch => "interface-voltage-domain",
        .unknown_contact_pin => "interface-contact-pin-known",
        .contact_count_over_pads => "interface-contact-count",
        .contacts_not_covered => "interface-contacts-covered",
        .duplicate_contact_claim => "interface-contact-unique",
        .connector_pinout_unavailable => "interface-pinout-available",
        .manifest_shadowed => "system-manifest-single-source",
    };
}

/// The system release gate's boolean state fields, keyed by field name, each
/// paired with the registry row that carries its verdict.
const system_gate_table: []const KeyedId = &.{
    .{ .key = "identity_ok", .id = "system-identity-complete" },
    .{ .key = "interface_ok", .id = "system-interface-endpoints" },
    .{ .key = "board_review_ok", .id = "system-board-reviews" },
    .{ .key = "fab_ok", .id = "system-fabrication-ready" },
    .{ .key = "checklists_ok", .id = "system-checklists-complete" },
    .{ .key = "waivers_ok", .id = "system-waiver-register" },
    .{ .key = "interface_contract_ok", .id = "system-interface-contract" },
    .{ .key = "attested", .id = "system-attested" },
};

/// The registry id a `system_review_package.GateState` field belongs to,
/// keyed by the field's name.
pub fn systemGateId(field_name: []const u8) ?[]const u8 {
    return keyedId(system_gate_table, field_name);
}

// ── Catalogue invariants ──────────────────────────────────────────

fn isKebabCase(id: []const u8) bool {
    if (id.len == 0) return false;
    if (id[0] == '-' or id[id.len - 1] == '-') return false;
    for (id) |c| {
        const legal = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!legal) return false;
    }
    return true;
}

/// The first id that is not kebab-case, or null when every id is.
fn nonKebabId() ?[]const u8 {
    for (rows) |row| {
        if (!isKebabCase(row.id)) return row.id;
    }
    return null;
}

/// The first id claimed by two rows, or null when every id is unique.
fn duplicateId() ?[]const u8 {
    for (rows, 0..) |row, index| {
        for (rows[index + 1 ..]) |other| {
            if (std.mem.eql(u8, row.id, other.id)) return row.id;
        }
    }
    return null;
}

/// The first violation kind whose mapped id is unregistered, or null.
fn unregisteredErcKind() ?erc.ViolationKind {
    for (std.enums.values(erc.ViolationKind)) |kind| {
        if (lookup(ercId(kind)) == null) return kind;
    }
    return null;
}

/// The first DRC kind whose mapped id is unregistered, or null.
fn unregisteredDrcKind() ?drc.Kind {
    for (std.enums.values(drc.Kind)) |kind| {
        if (lookup(drcId(kind)) == null) return kind;
    }
    return null;
}

/// The first fabrication finding id the registry does not carry, or null.
fn unregisteredFabId() ?[]const u8 {
    for (fab_finding_ids) |id| {
        if (fabFindingId(id) == null) return id;
    }
    return null;
}

fn leadingKeyword(syntax: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, syntax, ' ') orelse syntax.len - 1;
    return syntax[1..end];
}

/// The first documented `(check …)` primitive with no registry row, or null.
fn unregisteredCheckPrimitive() ?[]const u8 {
    for (check_grammar.check_docs) |doc| {
        const keyword = leadingKeyword(doc.syntax);
        const id = checkPrimitiveId(keyword) orelse return keyword;
        if (lookup(id) == null) return keyword;
    }
    return null;
}

/// The first documented net-rule predicate with no registry row, or null.
fn unregisteredNetRulePredicate() ?[]const u8 {
    for (authored_rules.predicate_docs) |doc| {
        const keyword = leadingKeyword(doc.syntax);
        const id = netRulePredicateId(keyword) orelse return keyword;
        if (lookup(id) == null) return keyword;
    }
    return null;
}

/// The first review category with no registered row, or null.
fn emptyCategory() ?Category {
    for (std.enums.values(Category)) |category| {
        if (!categoryHasRow(category)) return category;
    }
    return null;
}

fn categoryHasRow(category: Category) bool {
    for (rows) |row| {
        if (row.category == category) return true;
    }
    return false;
}

/// The code a finding of this kind carries, for the resolution walk below.
/// The two kinds that carry one are checked against their whole table by the
/// helpers beneath; this only has to hand each kind something it accepts.
fn sampleCode(kind: preflight.FindingKind) []const u8 {
    return switch (kind) {
        .profile_incomplete => "requirements",
        .brief => "part-operating-range",
        .requirement, .datasheet_review, .eval_warning => "",
    };
}

/// Every preflight finding kind resolves, using each kind's own code space.
fn preflightKindsResolve() bool {
    for (std.enums.values(preflight.FindingKind)) |kind| {
        const id = preflightId(kind, sampleCode(kind)) orelse return false;
        if (lookup(id) == null) return false;
    }
    return true;
}

/// Every brief-driven check code resolves to a registered row.
fn briefCodesResolve() bool {
    for (brief_check_table) |entry| {
        const id = briefCheckId(entry.key) orelse return false;
        if (lookup(id) == null) return false;
    }
    return true;
}

/// Every class-profile item code resolves to a registered row.
fn profileCodesResolve() bool {
    for (profile_item_table) |entry| {
        const id = profileItemId(entry.key) orelse return false;
        if (lookup(id) == null) return false;
    }
    return true;
}

/// Every rail and thermal verdict resolves to a registered row.
fn railAndThermalVerdictsResolve() bool {
    for (std.enums.values(power_budget.RailStatus)) |status| {
        if (lookup(railStatusId(status)) == null) return false;
    }
    for (std.enums.values(thermal.Verdict)) |verdict| {
        if (lookup(thermalVerdictId(verdict)) == null) return false;
    }
    return true;
}

/// Every PLL, frequency-plan and interface-contract verdict resolves to a
/// registered row, as does every system gate-state field.
fn analysisAndSystemVerdictsResolve() bool {
    for (std.enums.values(pll_loop.Screen)) |screen| {
        if (lookup(pllScreenId(screen)) == null) return false;
    }
    for (std.enums.values(frequency_plan.Screen)) |screen| {
        if (lookup(frequencyPlanScreenId(screen)) == null) return false;
    }
    for (std.enums.values(system_interface_check.Kind)) |kind| {
        if (lookup(interfaceMismatchId(kind)) == null) return false;
    }
    for (system_gate_table) |entry| {
        const id = systemGateId(entry.key) orelse return false;
        if (lookup(id) == null) return false;
    }
    return true;
}

// spec: review-audit - every review-registry id is unique and kebab-case
test "every registry id is unique and kebab-case" {
    try std.testing.expectEqual(@as(?[]const u8, null), nonKebabId());
    try std.testing.expectEqual(@as(?[]const u8, null), duplicateId());
}

// spec: review-audit - every electrical-rule violation kind maps to a registered review check
test "every ERC violation kind maps to a registered row" {
    try std.testing.expectEqual(@as(?erc.ViolationKind, null), unregisteredErcKind());
}

// spec: review-audit - every design-rule check kind maps to a registered review check
test "every DRC kind maps to a registered row" {
    try std.testing.expectEqual(@as(?drc.Kind, null), unregisteredDrcKind());
}

// spec: review-audit - every fabrication finding id is registered under its own name
test "every fabrication finding id is registered" {
    try std.testing.expectEqual(@as(?[]const u8, null), unregisteredFabId());
}

// spec: review-audit - every documented requirement check and net-rule predicate maps to a registered review check
test "every check primitive and net-rule predicate maps to a registered row" {
    try std.testing.expectEqual(@as(?[]const u8, null), unregisteredCheckPrimitive());
    try std.testing.expectEqual(@as(?[]const u8, null), unregisteredNetRulePredicate());
}

// spec: review-audit - every preflight finding kind and class-profile item code maps to a registered review check
test "every preflight kind and profile item code maps to a registered row" {
    try std.testing.expect(preflightKindsResolve());
    try std.testing.expect(profileCodesResolve());
    try std.testing.expect(briefCodesResolve());
    try std.testing.expectEqual(@as(?[]const u8, null), briefCheckId("no-such-brief-check"));
}

// spec: review-audit - every rail, thermal, loop and interface-contract verdict maps to a registered review check
test "every rail, thermal, loop and interface verdict maps to a registered row" {
    try std.testing.expect(railAndThermalVerdictsResolve());
    try std.testing.expect(analysisAndSystemVerdictsResolve());
}

// spec: review-audit - every review category carries at least one registered check
test "every category carries at least one row" {
    try std.testing.expectEqual(@as(?Category, null), emptyCategory());
}

// spec: review-audit - lookup returns the registered row and nothing for an unknown id
test "lookup finds a registered row and rejects an unknown id" {
    const row = lookup("supply-pin-voltage-rule") orelse return error.MissingRow;
    try std.testing.expectEqual(Category.supply_voltages, row.category);
    try std.testing.expectEqual(Layer.unit, row.layer);
    try std.testing.expectEqual(Policy.blocking, row.policy);
    try std.testing.expectEqual(@as(?Row, null), lookup("no-such-review-check"));
}
