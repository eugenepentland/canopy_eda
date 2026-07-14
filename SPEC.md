# Netlisp

CLI-driven electronic design automation for schematic capture using S-expression syntax.

## sexpr/tokenizer

- Tokenizes parentheses and atoms from S-expression input
- Tokenizes integer and float numbers with optional unit suffixes
- Tokenizes SI-scaled literals (220k, 100nF, 3.3V, 10mA) as si_val with the suffix in the token text
- SI suffix rules leave mm/mil dimensions, bare milli, and longer identifiers untouched
- SI literal at a paren boundary ends the token
- Skips line comments starting with semicolon
- Tokenizes arithmetic operators as distinct tokens
- Tokenizes comparison operators as distinct tokens
- Tracks line and column position for each token
- Tokenizes KiCad-style unquoted filenames containing +
- Tokenizes KiCad-style unquoted filenames containing ,
- Records the source span of an unexpected character for diagnostics
- Records the opening-quote span of an unterminated string

## sexpr/parser

- Parses a simple S-expression list into an AST node
- Parses nested S-expression lists into a tree
- Parses numbers and unit values into typed AST nodes
- Parses SI-scaled literals (220k, 100nF, 3.3V, 10mA) into scaled float nodes
- Parses input containing comments by ignoring them
- Parses multiple top-level forms into separate AST nodes
- Identifies forms by head atom via isForm helper
- Reports the line and column of a syntax error midway through a multi-line source
- A parse diagnostic column locates the offending token so a caret aligns under it
- An unterminated list is reported at the unclosed open paren
- Fuzzing the parser tolerates arbitrary bytes without crashing or leaking

## sexpr/printer

- Prints a simple list as a single-line S-expression string
- Prints short nested lists inline on one line
- Prints long nested lists with multiline indentation
- Round-trips parse to print to parse producing identical AST
- Round-trips every .sexp and .kicad_pcb file under projects/designs through parse → print → parse with structurally equal AST
- Fuzzing parse-print-parse yields a structurally identical AST for accepted input

## sexpr/ast

- Constructs typed AST nodes for list, atom, string, int, float, and unit values

## kicad_pcb/format

Public functions: padNumberText, sexprEscape, sexprUnescape

- padNumberText reads quoted, bare-atom, and bare-int pad numbers
- sexprEscape escapes embedded quotes and trailing backslash so the printed token round-trips
- sexprUnescape inverts sexprEscape so a load→save round-trip does not double-escape

## kicad_pcb/reader

Public functions: readBoard

- parses footprint reference, value, kicad_uuid, and canopy_uuid from properties
- parses (locked yes) as locked footprint
- reads every footprint in a real .kicad_pcb fixture
- reads a bare-integer pad number so the pad still enters the net diff
- parses the (model …) offset/rotate so the diff can detect 3D-model drift
- skips a pad net id that is non-finite or out of integer range
- Fuzzing readBoard with arbitrary bytes never crashes

## kicad_pcb/writer

Public functions: applyOpsToSource, applyOpsToSourceWithStats

- set_pad_net rewrites the (net …) form on the matching pad
- set_pad_net matches a bare-integer pad number
- set_pad_net with an empty net clears the pad's (net …) form
- remove drops the matching footprint from the output
- set_field upserts a property on the targeted footprint
- set_locked toggles (locked yes) on the targeted footprint
- add wires pad nets from the op's [pin, net] array
- swap_footprint accepts a legacy (module …) kmod
- swap_footprint mirrors a kmod onto the back for a footprint on B.Cu (layers F→B, local Y negated)
- swap_footprint stores pad angles absolutely (footprint rotation + pad-local rotation)
- add drops legacy (angle …) arcs the modern board parser rejects
- preserves pcbnew-style boards: in-element net forms
- add places the new footprint at the op's staging (x, y) and bakes canopy_net / canopy_section properties
- add places the new footprint at the premade layout's (x, y, rotation)
- add bakes design properties (MPN, Manufacturer, …) on the first sync
- add_via inserts a (via …) form stitching the GND net
- add_via at an existing via position is a no-op
- create_board_item writes a section staging box as a (gr_rect …) on Dwgs.User
- create_board_item writes a section label as a (gr_text …) on Dwgs.User
- hides the refdes, value, and metadata so the silk/fab carries no auto-generated text
- leaves already-correct property visibility untouched (idempotent)

## placement/geometry

Public functions: load

- parses pads and courtyard half-extents from a footprint sexp
- synthesizes a fallback box sized by pin count when the footprint is missing
- parses silkscreen lines and circles from a footprint sexp
- parses an oval drill into a slot (minor-axis tool + arc-centre offset), pad rotation, and roundrect ratio

## placement/optimizer

Public functions: solve

- classifies hub vs passive ref-des, handling hierarchical paths
- anchor pick prefers net degree over courtyard area, area only breaks ties
- partial apply locks every covered part and leaves the rest free
- legalization never moves a locked part; the free side absorbs the push
- a locked anchor keeps its pose and the ring transforms into its frame
- a pinned block pushes free blocks aside and never moves
- a starred module layout seeds the sub-block macro, matched by origin key
- a switcher board tries the zone floorplan before the ring; ferrites on plain rails do not qualify
- excludes ground nets from spring forces
- board rules resolve declared pours by outer face and plane membership by net name
- derives the routable signal-layer set from the stackup: outer faces always, inner layers only when no plane claims them
- multi-pin wirelength uses the rectilinear MST, which equals span when collinear and exceeds HPWL otherwise
- loop inductance floors at the via mounting inductance and rises with conductor length
- the scored loop term is the smooth analytic surrogate, continuous in part position (no routing cliffs)
- input-rail names (and raw rails ≥7V) read as the switching hot loop; output/low rails do not
- routing congestion is zero with no multi-pin nets and positive when nets pile into one region
- legalization separates two overlapping courtyards
- a bottom-side part mirrors footprint-local x in world transforms and never collides with top-side parts
- cached poses restore each part's board side and lock flag
- rotates footprint-local offsets in right-angle steps matching the page
- rotation refine picks the orientation that shortens the decoupling loop
- loop legs measure edge-to-edge to the nearest hub pad
- reserves a breakout corridor only for single-component nets
- ground-return selection keeps real grounds over straps, with a never-empty fallback
- relieves the loop pull of caps in a same-rail bank
- pulls group members toward their centroid, anchoring the IC
- zone-pack snaps a rail direction to an IC edge
- zone-pack rotates a cap so its power pad faces the IC
- zone-pack lays a group into an aligned row/column
- rough seed keeps each module a rigid, non-interleaved block
- (board ...) edge default rotation turns connector pads toward the board interior
- (board ...) docks edge parts flush inside the outline and pins corners
- (board ...) edge parts wanting the same spot de-overlap along the edge
- a series part's rotation aligns its pad axis with its matched hub pins
- series detection pairs a 2-pad part with two single-hub legs to one hub
- series rotations are applied and pinned; authored spec rotations win
- synthesizes an aggressor-avoidance keep-out for a feedback passive
- the surrogate objective ranks a tighter layout below a spread one
- a passive belongs to the hub its decoupling loop or most local signal net serves; power rails carry no locality
- a satellite hub's circuit solves in its own frame and docks rigidly at the anchor pads that tie it in
- an authored (group ...) islands its members around the group core
- port directions are the flow compass: in enters left, out leaves right
- differential twins mirror the P lane onto the N lane at the pads' pitch
- design-rules resolve authored values over built-in defaults, absent form keeps every default

## placement/router

Public functions: route, perNetRouted, returnPathViolations

- maze-routes a two-pad net into connected track segments
- a net spanning the two board sides routes through a via, each leg on its part's layer
- a plane-less stackup routes ground as real copper instead of dropping plane vias
- routes through a plane-free inner signal layer when both outer faces are blocked; a 2-signal stackup never emits inner copper
- reports a grid too large to route via RouteResult.grid_overflow instead of a silent empty result
- an outer-layer pour connects same-side pads directly; only opposite-face pads get a stitching via
- a net-class rule sets its nets' trace width and via size; unruled nets keep defaults
- routes corners as 45° diagonals rather than 90° bends
- LoopRouter measures a real per-leg trace length that detours foreign pads
- counts signal vias lacking a nearby ground stitching via as return-path discontinuities
- stitches each signal via's return path with a nearby GND plane via
- escapes a single-pin breakout to an inner layer with a short stub and a via
- elevates only the switching hot loop above the baseline routing tier
- lets authored (net-class (priority …)) dominate the intrinsic net-class rank
- auto-elevates a bare hub-to-inductor bridge net to the hot-loop tier
- names the nets that failed to route in RouteResult.failed
- a failed leg's goal is never a same-net source, so a later leg cannot weld to a stranded pad
- perNetRouted totals a net's routed copper length and via count
- rip-up runs no rounds when the greedy pass already routed every net
- rip-up leaves a wall-blocked net failed without disturbing an already-routed net
- escape stubs keep clearance from routed tracks and leave at 45-degree headings
- reserves diagonal corner cells so later nets keep trace-to-trace clearance
- escapes a fine-pitch pad through an off-grid gateway stub when no grid lane clears
- a hemmed breakout keeps its stub clear of foreign pads instead of crossing them
- keeps every placed via a hole-to-hole wall from every other drilled hole

## placement/drc

Public functions: check, countKind

- flags a via that crowds a foreign pad's clearance
- passes a via that shares the pad's net
- a routed module with a crowded ground pad has no clearance violations
- flags a via whose annular ring is under the fab minimum
- flags copper crowding the board outline and skips the off-board staging band
- checks the board edge against a non-rectangular outline polygon, catching copper in a notch
- the polygon board-edge inset is measured against the copper-edge design rule
- flags same-layer track crossings and sub-clearance pairs between nets
- flags a track crossing a foreign pad on its layer; other-layer SMD pads don't clash
- inner signal layers get the same same-layer checks; through pads clash on every inner layer
- SMD pads on opposite board faces may overlap in 2D; sharing a face or a through barrel still clashes
- flags two placed parts whose courtyards overlap, but not disjoint or opposite-side ones
- flags two drilled holes whose walls sit closer than the hole-to-hole rule
- flags a drilled hole below the minimum drill diameter (pads and vias); SMD pads exempt
- board-level design rules default to the toolchain's legacy constants when no form is authored
- a (design-rules …) value overrides the matching default in the DRC
- a wider board clearance flags copper the default rule allowed
- a net-class clearance override is enforced against that net's neighbours server-side
- an oval slot's hole-to-hole clearance is measured end-to-end (capsule), not at its centre
- flags a thin solder-mask web between two adjacent pad openings, and is a warning
- flags silkscreen that crosses a foreign pad's mask opening, as a warning
- auto-places a ref-des clear of foreign pads when a side is free, else flags a boxed-in label
- flags a plated through-hole pad whose annular ring is under the minimum; NPTH pads exempt
- flags a track narrower than its net-class width, else the board minimum, as an error
- existing copper violations are error-severity; only the hygiene checks are warnings
- completeness-waiver: empty inputs (each rule iterates the geometry present, so a design with no copper or parts yields no violations by construction)
- completeness-waiver: large inputs (a bounded pairwise geometry scan; working memory stays proportional to the parsed design, with no unbounded buffering)
- completeness-waiver: unauthorized access (a pure in-memory computation with no auth surface here; access control lives in serve/users)
- completeness-waiver: i/o failure (operates on already-parsed in-memory geometry; all file and network I/O is upstream in the reader and exporter layers)
- completeness-waiver: concurrent access (runs single-threaded over an immutable design snapshot, with no shared mutable state)
- completeness-waiver: malformed encoding (consumes typed geometry from the parser; malformed-input rejection is upstream in sexpr and kicad_pcb parsing)
- completeness-waiver: integer overflow (clearance and distance geometry is computed in f64 over bounded board coordinates; the only integers are net-id indices, not accumulating arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/outline

Public functions: contains, distToEdge, signedInset, bboxRect, segCrossesEdge, roundedRectPoly

- point-in-polygon and signed inset classify an L-shaped outline's interior, notch, and edges
- a segment crossing a concave notch edge reports the crossing point
- rounded-rect generation clamps the radius and keeps corner points inside the rect

## placement/pour

Public functions: compute, planeConnect

- a seeded pour keeps its component and drops an unseeded orphan island
- a foreign trace that splits a plane leaves its same-net pads in separate components
- the fill respects a non-rectangular board outline
- an isolated same-net pad reports no pour component
- carryingLayers resolves declared planes and the implicit ground model
- gridCount collapses a non-finite extent to zero cells instead of an unchecked narrowing

## placement/module_policy

Public functions: analyze, classifyNetName, isInductor

- classifies ground, input-rail, switch-node and feedback nets by name
- infers a buck module from an inductor on the input rail and tags the input cap
- applies (module-policy …) author overrides over the heuristic detection
- exports the detected policy as an editable (module-policy …) block

## placement/layout_lint

Public functions: lint, freeFindings

- flags a decoupling cap whose power-leg exceeds the 6 mm budget
- flags a feedback part placed within keep-out of a switching-node aggressor

## placement/pin_roles

Public functions: load, isGroundFn, isSupplyFn, strapPads, padRequirements

- groundy function names are recognised, straps are not
- supply function names are recognised, grounds and signals are not
- electrical type overrides the name heuristic; signal types demote to strap
- config-strap function names are recognised, supplies grounds and GPIO are not
- strapPads maps strap pads to their function name via name or electrical type
- strapPads skips connector positional pins named after their pad
- connectionRequirement tiers an unconnected pad by confidence
- padRequirements keeps only the flaggable pads of a part

## placement/pad_shape

Public functions: worldShape, pointDist, shapeGap

- a concave pad's notch reads as clear copper, its prong as covered
- shapeGap clears a pad nested in a concave neighbour's notch
- simplifies a dense outline to a few corners within tolerance

## eval/builtins

- Evaluates arithmetic operations on numeric values
- Evaluates a voltage divider formula combining arithmetic operators
- Evaluates comparison operations returning boolean results
- Evaluates logic operations on boolean values
- Snaps a value to the nearest standard E-series resistor value

## eval/forms

- SpecialForm.fromAtom resolves every head atom the evaluator dispatches on
- SpecialForm.fromAtom rejects atoms that aren't registered special forms
- Builtin.fromAtom resolves every operator name
- ScopeForm.fromAtom resolves every form name that can appear in a design-block / section / subsection
- validateArity flags too-few and too-many arguments and accepts in-range counts
- schemaFor returns the schema for every special form whose arity is fixed
- block is the unified definition form; design-block and defmodule remain permanent aliases

## docgen

- renderLanguageReference output matches the committed docs/language-forms.md so docs can never lag the registries
- extractSection returns one ## section of the rendered reference, matching the title case-insensitively
- SectionIterator walks every ## heading of the rendered reference in order
- The generated reference names every category key so (category …) docs follow the classifier map

## eval/fmt

- Formats voltage values with SI prefix and V suffix
- Formats resistance values with SI prefix and ohm suffix
- Formats capacitance values with SI prefix and F suffix
- Formats amperage values with SI prefix (uA/mA/A)
- Formats tilde escape sequences in format strings
- Formats mixed specifiers in a single format string
- The directives table and format()'s dispatch recognise exactly the same specifier characters

## eval/env

- Stores and retrieves values by name in an environment
- Resolves names through a parent environment chain

## eval/pin_enrichment

- Fills a pin's asserted_fns with the unique alt when the pinout has exactly one alternative

## eval/modules

- Module calls bind purely positional arguments in declaration order
- Module calls accept named (param expr) arguments in any order
- Module calls mix leading positional with trailing named arguments
- A 2-list whose head is not a declared param stays a positional expression
- Binding the same module parameter twice is diagnosed by name
- A positional argument after a named argument is rejected
- Unbound module parameters are diagnosed by name at the call site
- Surplus positional arguments are diagnosed with expected and actual counts
- A syntax error in an imported library file is diagnosed with the file path and location

## eval/suggest

- editDistance computes the Levenshtein distance between names
- unbound library name yields an import hint naming the missing import
- a near-miss name yields a did-you-mean suggestion from env and cache candidates
- a name with no close candidate reports a plain unknown-name message

## eval/evaluator

- Evaluates arithmetic expressions from S-expression AST
- an error inside a module body appends the module call stack to the diagnostic
- block with a string name evaluates as a design root
- block with an atom name defines a callable module stamped embedded
- block with an atom name and a raw design-scope body materializes in place
- block with an atom name and a wrapped inner design-block still materializes the inner block
- SI-suffixed literals evaluate to their scaled numeric value
- SI-suffixed literals flow through module call arguments
- Evaluates let bindings that define named values in scope
- Evaluates if conditionals selecting a branch by predicate
- Evaluates fmt expressions producing formatted strings
- Evaluates assert-range that passes when value is in bounds
- Evaluates assert-range that fails when value is out of bounds
- evalFile auto-imports the standard passives prelude before user nodes run
- Module files loaded via resolveImport get the same passives prelude before their body evaluates
- componentPrefix maps passive families to their ref-des letters
- instancePrefix honors a component's explicit (refdes "X") class over the name heuristic
- Passives prelude resolves the standard cap/res/ind/ferrite/led families when their files exist
- Passives prelude silently skips library entries whose files are missing instead of failing the build
- Explicit import after prelude pre-loads is a no-op (resolveImport short-circuits on cached components)
- parseId extracts 8-char ID from form children
- parseId returns null when no ID present
- deriveChildId produces the same child ID when called with identical inputs
- deriveChildId produces unique child IDs across different index values
- generateId produces 8-char hex starting with letter
- generateId registers each token so a second call cannot collide
- parseChildIdSidecar reads (ids ("k" t)) pairs into a key-to-token map
- getOrCreateChildId returns the stored token for a known key
- getOrCreateChildId mints and queues a token for an unknown key
- reassignSubBlockIds takes a pinned child id from the (ids …) sidecar and seeds+queues a miss with the legacy derivation
- reassignSubBlockIdsV4 derives each child id from the sub-block uuid and the child's stable origin_key
- reassignSubBlockIdsV4 composes nested sub-blocks via the parent uuid and the nested name (sheet-path identity)
- hierarchical-ids derives decouple child ids from the form id instead of the (ids ...) sidecar
- without hierarchical-ids decouple child ids come from the (ids ...) sidecar
- hierarchical-ids derives series child ids from the form id instead of the (ids ...) sidecar
- decouple per-pin emits one cap per explicitly listed pin
- decouple per-pin without an explicit pin list is an error
- isStandardRefDes distinguishes standard from descriptive labels
- last_error records the source span of an unknown form so callers can report file:line:col
- last_error records the source span of an arity mismatch in a special form

## id_insert

- findMatchingClose finds correct closing paren
- findMatchingClose handles strings containing parens
- insertPendingIds aborts on a duplicate pending token
- insertPendingIds aborts when a pending id already exists in the source
- insertPendingIds writes a child (ids …) sidecar and stays idempotent

## convert/footprint

- Converts a KiCad footprint file into S-expression format
- Captures F.Fab body outline and silkscreen polygons into the footprint
- Expands a custom pad's gr_poly primitive into a real polygon outline with bbox-derived pos/size

## convert/symbol

- Converts a KiCad symbol file into S-expression format

## import_kicad

- Parses board footprints into parts with ref, value, MPN, and per-pad net + pinfunction
- Sanitizes KiCad net names (sheet-slash stripped, auto-net parens dropped, unconnected pads null)
- Emits a design with family-mapped passives, custom-part imports, net-grouped pins, and deduped thermal pads
- Generates pinout files from pad pinfunctions with numeric-then-alpha pin ordering
- Normalizes pad angles against footprint rotation when emitting footprint geometry
- Renames pure-numeric and family-clashing component names so they stay referenceable atoms
- Sanitizes library names to lowercase slugs

## import_fold

- Detects indexed net families (digit run → ~) excluding KiCad auto-names
- Picks the varying digit run as the channel index when other runs are constant
- Folds isomorphic channels into a module and leaves deviating channels flat

## convert/alt-functions

- Parses a long-format CSV with position/function/etype columns
- Parses ST open-pin-data XML into alt-function rows
- Merges CSV alternate-function rows into an existing pinout file

## emit

- Emits a placeholder for an empty resolved design

## parts

- Returns null when looking up a missing component family
- Matches component attributes against filter criteria
- Picks the preferred component from matching candidates

## export_kicad

- Generates a KiCad netlist from a resolved design
- Exports a KiCad footprint mod file from footprint data
- Emits a footprint's (fab …) body outline as fp_line/fp_circle on the F.Fab layer
- Emits silkscreen/fab (poly …) as a filled fp_poly and (rect …) as fp_rect on the target layer
- Emits a custom pad's (poly …) outline as a valid KiCad custom pad with (primitives (gr_poly …)) in pad-local coords
- Inflates the emitted F.CrtYd courtyard by BBOX_MARGIN_MM so KiCad matches the placement page's drawn courtyard

## export_fab

Public functions: centroidCsv, excellonDrill, frameFor, outlineRect

- the centroid CSV lists each part's pose with its board side
- the centroid CSV drops DNP parts by default and keeps them under keep_dnp
- the Excellon writer splits plated pads + vias from non-plated holes and groups tools by diameter
- fab writers share one y-up frame derived from the board outline
- an oval drill exports as a G85 slot at its minor-axis tool between the two arc centres, in both drill files

## export_gerber

Public functions: planLayers, writeLayer

- plans the file set from the stackup (implicit 4-layer, declared planes, plain 2-layer)
- outer copper flashes side-correct pads and draws routed tracks/vias in the y-up frame
- mask openings expand pads and tent vias; paste covers only same-side SMD pads
- an inner plane pours solid copper and antipads only foreign holes
- an inner signal layer emits its routed tracks, via lands, and through-pad barrels; other layers' tracks stay off it
- an outer-layer pour paints the copper file solid and isolates only foreign same-face features
- the edge layer closes the board outline; silk strokes footprint art and ref-des text
- the mask margin comes from (design-rules …), defaulting byte-identically to 0.05 mm
- a non-rectangular board emits its exact outline polygon on the edge layer
- board-level silkscreen text strokes onto the silk layer at its world anchor, and only on its own side
- silkscreen text scales with its cap-height size (2x size gives 2x glyph extent)
- a roundrect pad emits its rounded outline as a G36 region while a plain rect stays an R aperture
- a custom polygon pad's mask opening is offset outward from its copper by the mask margin
- a pad at a non-quarter angle emits a rotated region instead of an axis-aligned aperture
- the .gbrjob board thickness comes from the stackup (thickness …), defaulting to 1.6 mm

## zipfile

Public functions: write

- packs entries into a store-method archive the standard extractor reads back
- Fuzzing the writer with arbitrary entry bytes produces a well-formed archive

## bom

- Generates deterministic UUIDs in the expected format
- Loads an empty BOM file without error
- Detects net overlap between components

## bom-resolve

- identity resolution is a fixed point: two consecutive resolveIdentities calls produce a byte-identical BOM
- identity is deterministic: each part takes uuidFromId(its stable id), independent of any prior .bom contents

## render_html

Public functions: renderToHtml, setupRenderCtx, renderHubSvg

- A passive bridging a single-hub-pin net and a multi-hub-pin net renders off its single-pin side
- A passive bridging two single-hub-pin nets has no anchor and keeps default placement

## diagram/types

Public functions: viewLabel, viewId, viewSlug, viewColor, viewOf

## diagram/membership

Public functions: build, computeSubBlockAttachments

- Excludes power-classified nets so a power-producer sub-block is not adopted into a consuming section

## diagram/classify

Public functions: buildPortClassMap, netClass

- Classifies power, ground, clock, control, and RF nets by name
- Honors an explicit section-port signal type over the name heuristic
- An explicit port (class …) overrides signal-type and name heuristics
- A declared (class …) key extends the registry with a new class

## diagram/collect

Public functions: collectGraph

- Derives inter-block edges from the flattened netlist rather than an MCU hub
- Excludes ground nets and collapses parallel or differential nets into one edge
- Resolves a power edge's voltage from any block that declares the rail
- Parses a rail voltage from its V<d>P<d> name when no port declares one
- Picks each block's primary supply rail by pin count and records its full rail set
- Synthesises an antenna endpoint for a board-edge RF net touching one block
- Labels an unattached sub-block by its module's design-block title
- Surfaces an on-board crystal as a clock source feeding its block
- Carries a programmable rail's rated span onto the producer node
- Emits one diagram node per stub categorised by its declared category
- Derives a 3-stage chip maturity (concept/schematic/done) from content
- Resolves each block's headline part numbers from hub instances by uppercased component
- A (diagram hidden) host section lends its description + card anchor to the chip

## diagram/layout

Public functions: computeLayout, hasSystemView, computeSystemLayout, computeChainLayout, computeFreeLayout, computeGroupsLayout, hasFreeLayout

- computeFreeLayout pins each anchor and resolves placed blocks in dependency order
- computeFreeLayout positions a block from several references at once
- computeFreeLayout flows un-placed blocks into a fallback row below the placed cluster
- computeFreeLayout places a block with a missing reference into the fallback row without aborting
- computeFreeLayout breaks a placement cycle instead of looping forever
- computeFreeLayout bumps a placement that resolves onto an occupied cell to the next free cell
- computeFreeLayout drops a scattered group's box from routing obstacles instead of punching the wire through a block
- computeFreeLayout lays each layout row as a horizontal band, stacking bands top-to-bottom
- computeFreeLayout boxes each layout group around its members with a labeled top strip
- computeFreeLayout separates overlapping (group …) boxes onto disjoint grid cells so group regions never overlap
- computeFreeLayout pins edge-directive blocks to the column just outside the rest of the content
- computeFreeLayout routes each edge as an orthogonal polyline around any group box neither endpoint belongs to
- computeFreeLayout spreads wires sharing a corridor into parallel lanes instead of overlapping
- computeFreeLayout fans a face's wires evenly across the face ordered by far-end position
- computeGroupsLayout shows only the group boxes with one connector per pair of groups a net crosses, and no individual nodes
- Returns null for a view with no edges
- Ranks nodes left-to-right by signal flow, breaking cycles for layering
- Routes edges sharing a source through one common vertical trunk
- Flows the power source left of the regulators it feeds
- Groups power consumers into one load bucket per rail
- Lists a dual-rail consumer in both of its rail buckets
- Shows a cascade LDO that re-regulates a rail in its own column
- Folds a pass-through filter stage and feeds its rail from the parent regulator
- Treats test-point and mechanical nodes as instrumentation, excluded from load buckets
- System layout combines edges from every class in one diagram
- System view flows blocks by functional stage: Power → Core → Peripherals
- Attaches a same-column edge to a vertical face so it does not loop into the gap
- Attaches a cross-column edge to the source's horizontal face nearest the target
- Signal Chain layout orders blocks by declared narrative stage instead of category
- Falls back to isolated block boxes when there are no connections
- Omits an unconnected block from the System view when edges exist
- Keeps a force-shown block in the layout even when it has no edges

## diagram/lod

Public functions: buildGlanceEntities, writeGlanceLayer, nodeByKey, groupCoverage

- Aggregates base edges into one glance connection per entity pair and class, summing fanouts
- Renders a glance chip per group and per ungrouped block with member captions
- Separates overlapping glance chips so chips never stack while keeping each chip's original zoom target
- Reports the block count and which blocks no group cluster claims

## diagram/render

Public functions: renderTabs

- Renders a tab per non-empty view and nothing when no view has edges
- Leads with a Block overview tab of grouped cards when the design declares groups
- A designer-declared class renders its own view
- Draws all edge labels after all wires so net pills stay legible
- Draws each rail label once per source, not once per fanout branch
- Colors power edges by voltage and renders a voltage legend
- Draws per-rail load buckets with rail-colored headings in the power view
- Power-view producer cards and load pills cross-probe to their section
- RF signal edges get no tab of their own; the flow shows in the Layout/System view
- Puts the combined System view first and selects it by default
- System view draws every class's edges at once, colored by class, with a class legend
- System view labels functional bands so it reads as an architecture
- Wraps a block's description onto multiple lines instead of truncating at one
- Truncation backs up to a UTF-8 boundary so multi-byte characters never split

## diagram/diagram

Public functions: renderBlockDiagramTabs, renderSystemSvg

## render_svg

Public functions: renderSchematic

- Docks a (decouples ...) bypass cap on the bound hub pad instead of every pin of the rail
- Pin groups classify supply and ground roles from function or net names
- An attached sub-block folds into its host section instead of paging its module title
- Sheet metadata classifies each authored sheet with the system-overview category
- Scene hubs serialize their authored sheet and the scene lists sheet categories

## erc

- Flags a board with at least five blocks that leaves some outside every group cluster
- Skips the grouping rule for a design below the block-count floor
- Emits power_budget error when load max exceeds source max
- Emits power_budget warning when typ load is above 80 percent of source typ
- Emits no power_budget violation when load is well below source capacity
- Requires pin function assertion when pinout defines alternates
- Allows pins without alternates to omit (as ...)
- Accepts multiple asserted functions on a single pin
- Rejects asserted function that is not in the pinout
- Resolves pin lookup by logical name when source uses logical pin id
- Skips pin function required check for single alt pins
- Flags a power rail with no test point on its net or any alias
- Recognises test points declared via the test-point form
- Recognises legacy testpoint component instances as test points
- Emits no test point violation when every rail has a test point
- Flags a power rail with a declared source but no consumer pins
- Flags a power rail whose nominal voltage cannot be resolved
- Emits no integrity violation on a fully-resolved rail with consumers
- Treats a sub-block input port wired via net-tie as a rail consumer
- Flags a rail whose only net-tie is its own source port (no consumer)
- Recognises a VREF-supplied level translator as powered (no false positive)
- Recognises a V<int>P<frac> rail such as the 5V V5P0 as power
- Test points are exempt from the IC-ground/power check
- A passive RF part (no supply pin in its pinout) is not flagged for missing power
- A real IC with a VCC pin in its pinout but no power net is still flagged
- Recognises a post-filter local supply node ending in VDD/VCC as power
- Still flags an IC with a ground pin but no recognised power net
- Flags a sequencing cycle by emitting sequence_cycle per affected rail
- Flags a net where the worst driver high level is below the worst receiver high threshold
- Emits no voltage-domain violation when driver and receiver levels are compatible
- Treats a section port with electrical metadata as a virtual driver and receiver on its net
- Treats a top-level design port with electrical metadata as a virtual driver and receiver on its net
- Warns when an active IC's library component declares no requirements
- Accepts an MPN-identified fixed component as a valued passive (no missing_value)
- Recognizes KiCad-style signed rails (+5V, -5.0V, +3V3, +5_0V) as power nets
- Recognizes V_ underscore rails (V_3V3D, V_RF_3P3) as power nets
- Exempts connectors, ignore-requirements support parts, and passive-class components from the requirements warning
- a config strap tied directly to a rail is an error unless pulled through a resistor or blessed
- strapBlessing distinguishes a reasoned blessing from a blank one and none
- an unconnected pad the pinout wants connected is flagged by tier unless blessed
- Does not warn for an IC that declares at least one requirement, nor for passives
- Recurses sub-blocks and warns once per undocumented component
- an unbound HF decoupling cap on a multi-supply-pad rail is an error, with bound/bulk/rail-optout/per-pin caps exempt
- config straps tied to the rail are excluded from the supply-pad count, like the placer's hubTargets

## eval/power_budget

Public functions: analyze

## eval/power_sequencing

Public functions: analyze

- Emits one always_on row per sub-block output with no enable
- Orders dependent rail after its enable source
- Flags enable that never resolves to a known rail
- Routes enable through PG signal to source rail

## eval/design_block

- stub form parses a placeholder part with role, mpn, category, and size
- stub auto-assigns a ref-des from the category prefix when ref is omitted
- stub signal contributes a named virtual pin tied to a net so the stub joins the netlist
- stub channels count stacks the block as N identical channels in the diagram
- bus-net expands one net tie per index in the inclusive range
- bus-net strided form distributes channels across over x ports with suffixes
- sub-block bridge ties prefixed board nets to module ports with optional rename
- fanout places one component from COMMON to each listed net
- decouple-defaults lets decouple omit its component and host ref
- decouple with no defaults keeps its legacy explicit form
- decouple per-pin auto expands the decouple-defaults IC's pins on the decoupled net
- decouple per-pin auto without a decouple-defaults ic is diagnosed
- decouple per-pin auto with no matching declared pins is diagnosed with the declaration-order contract
- an unknown sub-form inside a section records a lint warning naming the form
- a misspelled role word records a warning listing the expected values
- an unknown design-block top-level form records a warning
- an unknown port option records a warning naming the option
- a non-property sub-form in an instance body records a warning
- inert id/ids/hierarchical-ids/row/col heads never draw warnings
- the decouple-defaults bypass component cascades into sub-block modules that declare none
- a sub-block module's own decouple-defaults bypass wins over the parent's
- the bypass default cascades transitively through nested sub-blocks while the ic ref stays local
- bus-port expands one port per index times optional suffix list
- buildPort reads a bare trailing number as the port nominal voltage with an explicit nominal form overriding it
- kicad-pcb form captures the literal path on the design block
- stackup form captures layer count and plane assignments on the design block
- (pour top|bottom "NET") is stackup sugar for a plane on the matching outer layer
- a bare 2-layer stackup declares no planes so ground routes as copper
- net-class forms capture width/clearance/via geometry and routing priority for their listed nets
- design-rules form captures the board-level default rules on the design block
- a design with no design-rules form leaves every rule at its zero (default) sentinel
- layout form parses (anchor "name") roots and (place "name" (rel "ref")) directives
- layout place resolves right-of/left-of/above/below into a relative offset from the referenced block
- layout place collects multiple constraints so a block is positioned by several references
- layout row form parses an ordered band of block keys
- layout group form parses a labeled region over member block keys
- layout edge form parses left/right edge-pinned block keys
- hosts form records the sub-block instance names a section owns
- board form parses outline size, corner radius, edge lists, and corners
- revision form captures id, date, and newest-first changelog
- revision form with only an id is present with empty date/changelog
- a design with no (revision …) form is unversioned (present=false)
- verifies req with an (id …) target parses as a stable-id sign-off leaving ref-des empty
- verifies req with a ref-des target parses as a ref-des sign-off leaving target-id empty

## eval/test_point

Public functions: parse

- Parses ref-des and net from the first two positional arguments
- Parses an optional (purpose "...") sub-form into the purpose field
- Parses (required-for ...) sub-form recognizing bring-up power clock reset debug and signal tags
- Returns null when ref-des or net positional arguments are missing
- Ignores unknown sub-forms and unknown required-for tags

## eval/electrical

Public functions: parse, parseSubForms

- Parses pin function name from the first positional argument
- Returns null when the pin function name is missing
- Recognises every electrical-type enum atom
- Parses voltage level fields v-ih-min v-il-max v-oh-typ v-ol-typ max-voltage
- Ignores unknown sub-forms and unrecognised enum atoms
- parseSubForms fills the electrical sub-fields on a caller-supplied ElectricalDecl
- parseSubForms is used by the port parser to read inline (electrical ...) clauses
- Port-level electrical declarations describe the logic levels carried by a net at a board boundary

## eval/rails

Public functions: build

- Derives one PowerRail per sub-block output port marked power direction out
- Recognizes a spec-less regulator output tied to a rail-named net
- Collapses ferrite-bead-bridged nets into a single rail via union-find
- Resolves rail voltage from sub-block output port nominal first
- Falls back to section power port voltage when sub-block port nominal absent
- Falls back to top-level design port nominal when neither sub-block nor section voltage declared
- Excludes GND from the derived rail set
- Records source_ref_des and source_port on each rail from the source instance
- Returns empty slice when design declares no rails

## coverage

Public functions: computeInstanceCoverage, computeSectionCoverage, computeOverallCoverage

- computeInstanceCoverage classifies passives by ref-des prefix and requires only value+footprint
- computeInstanceCoverage requires MPN, manufacturer, datasheet, and verified requirements for ICs
- computeInstanceCoverage honours requirements_ignored opt-out
- computeSectionCoverage rolls instance results into checked/complete counts per category
- computeOverallCoverage aggregates every section plus orphan sub-block instances
- computeOverallCoverage returns 100% when the design has zero checkable instances

## review

- buildPowerTree assigns each rail to a topological layer rooted at upstream sources
- buildPowerTree emits an empty tree when the block declares no rails
- slugify converts section titles to anchor-safe identifiers
- isoTimestamp formats epoch seconds as ISO-8601 UTC
- buildSummary marks status=pass when no errors or warnings
- buildSummary marks status=warn on warning-level violations
- buildSummary marks status=fail on error-level violations
- buildTestPoints collects testpoint instances with pin 1 net
- buildTestPoints ignores non-testpoints

## review_json

Public functions: renderToJson

## review_md

Public functions: renderToMarkdown

- emits markdown header for design name

## req_checks

Public functions: runChecks, deinit, parseMicroFarads, parseOhms, parseMicroHenries

- parseMicroFarads handles SI-suffixed cap values
- parseOhms handles SI prefixes for resistor values
- parseMicroHenries handles SI-suffixed inductor values
- applyVerifications matches a verifies form to an instance by stable id when target-id is set
- applyVerifications matches a verifies form to an instance by ref-des when target-id is empty

## review_html

Public functions: writeSummaryTable, writePowerBudget, writePowerSequence, writeTestPoints, writeUnresolved, writeAssertions, writeSectionCoverage

## serve

Public functions: notFound, serve

- Ward member maps to the writer role, admin to admin, and an unknown role to reader
- An unconfigured ward adapter reports session and bearer paths unconfigured so requests fail closed
- The MCP scope check accepts a scope containing the service name and rejects one without it
- The MCP role resolver returns the ward identity role, else admin on the dev bypass, else reader
- The ward auth-server url is derived by stripping the login path from the configured login url
- A cookieless session request is decided as a redirect to the ward login url carrying the return target
- An api path is distinguished from a non-api path for the 401-versus-redirect choice
- The ward session cookie value is read from the cookie header and absent when empty or missing
- A cached session role is read back by token and reported unknown when absent or expired
- The writer and admin roles may write while the reader role may not, and only admin may administer
- An unavailable session verifier resolves the request to fail closed rather than admit it
- A loopback request under dev mode bypasses auth even when the ward backend is unconfigured
- A loopback request carrying any proxy header does not receive the dev bypass
- A request from a non-loopback peer does not receive the dev bypass
- A loopback request with dev mode disabled does not receive the dev bypass
- An ipv6 loopback peer receives the dev bypass while a non-loopback ipv6 peer does not
- An unauthenticated api request is answered 401 json rather than a login redirect
- An unauthenticated page request is redirected 302 to the ward login carrying the return url
- A bearer-less mcp request is answered 401 with a resource-metadata www-authenticate challenge
- An mcp request fails closed with 503 when the bearer introspection url is unconfigured
- An mcp scope lacking the service is forbidden while one carrying it is admitted with its mapped role
- A reader's mutating request is forbidden while a writer, a safe method, or a read-only post passes
- A valid plugin token admits a sync request without a ward call while an invalid one falls through
- A live ward bearer admits a sync request as the fallback when no plugin token matches
- A malformed sync bearer with ward configured falls through to the session gate rather than admitting
- A session-allowlisted public route is served without any credential
- An allocation failure during the sync bearer fallback surfaces as an error rather than admitting
- The protected-resource metadata derives its resource url from the host and names the ward server
- A reader drives the read-only pcb-drc and pcb-score-batch posts but not the pcb-drc-rules write
- A sync bearer scoped for another service is not admitted and falls through to the session gate
- Ward state initialization builds distinct http clients for the session and bearer verify paths

## serve/sync

Public functions: runSyncPlan, syncKicadPcbApi

- runSyncPlan diffs a parsed board state against the design and returns a JSON envelope with version, summary, and the ops list
- runSyncPlan errors with NotADesign when the source file does not evaluate to a design-block
- runSyncPlan errors with BuildFailed when the source file fails to evaluate
- pickByUuidOrRef returns the by_uuid match when the instance's canopy_uuid is on the board
- pickByUuidOrRef falls back to by_ref when canopy_uuid is missing and the fp is not reserved
- pickByUuidOrRef refuses a by_ref match whose fp is reserved by another instance's canopy_uuid
- pickByUuidOrRef refuses a by_uuid match whose fp another instance already claimed in this walk
- pickByUuidOrRef returns null when neither tier matches
- pickByKicadUuid adopts an orphan whose KiCad uuid equals the instance's canopy_uuid
- pickByKicadUuid refuses an fp another instance already claimed in this walk
- isPassiveRef classifies R/C/L/F/D ref-des prefixes as passive spokes and everything else as a hub
- buildCanopyNetValue renders each passive pad as destRef.destPin.net for a single hub pin, else the bare net name
- buildCanopyNetValue lists a passive's pads in numeric order joined by ' / ' and returns null when the passive has no connected pads
- sectionForRef attributes a sub-block part to its sub-block name and a top-level part to its declared section, else ""
- stripSubPrefix removes a leading "<sub>/" so a flattened sub-block ref maps to its module layout's ref
- boxCols returns a roughly-square (ceil-sqrt) column count for a staging box of N parts
- buildStagingLayout gives each part a fixed staging seat from the whole design, independent of push composition
- protoBoardLayer maps F.Fab and B.Fab to their KiCad board-layer enums
- loadFootprintDefImpl ships a footprint's fab geometry on F.Fab so the synced part keeps its outline
- writeGeomBlockProtoJson traces a (poly …) outline as boundary segments and emits (rect …) on the block's layer
- maybeCollapseDotSubNet folds a per-pin sub-net to its rail by default but keeps it verbatim in dot-net mode
- no-swap mode withholds swap_footprint as swaps_suppressed while set_field ops still flow
- a stale board pad is cleared only when the design nets that signal on another pad the board footprint actually has
- formatBackupStamp renders epoch seconds as a sortable filesystem-safe stamp
- writeFileAtomic rolls a timestamped board backup and prunes beyond MAX_BOARD_BACKUPS
- placement guard reports moved, rotated, or side-flipped footprints and exempts adds/removes
- placement guard passes when every existing footprint keeps its pose

## serve/vfs

Public functions: readFile, writeFile, editFile, listDir, glob, deleteFile, moveFile, dirtyDesignsForPath

- rejects parent traversal
- rejects absolute paths
- rejects dot-prefixed segments
- rejects NUL and backslash bytes
- allows project source and library paths
- denies auth and oauth paths
- denies writes to history and out
- matches basic glob patterns
- import detection respects word boundaries
- denialHint redirects bare lib listing to list_library
- denialHint redirects PDF writes to the disk/browser route
- libraryEntityFor classifies library subdirs
- denies write_file on lib/datasheets (PDFs are read-only via MCP)

## serve/component_info

Public functions: describeComponent, listRequirements, addRequirement, removeRequirement

- kebab-cases every Check variant tag
- findSourceComment finds the source-of-truth path
- parsePinoutBody normalises pin ID shapes
- listRequirements returns each requirement with its derived id
- addRequirement appends a requirement form before the component close
- addRequirement rejects a check clause the checker does not recognize
- removeRequirement deletes a requirement by id or exact text
- formEnd skips parens inside string literals
- add list and remove requirement round-trip on disk

## serve/mcp_docs

Public functions: mcpDocsPage

- buildToolDocs projects each tool from the embedded schema
- buildToolDocs marks mutating tools and required params
- buildExample renders an example invocation

## serve/notes

Public functions: getNotesApi, saveNotesApi, getTasksApi, addTaskApi, completeTaskApi, reopenTaskApi, removeTaskApi, parseNotes, renderNotes, loadNotes, addTaskCore, mutateTaskCore

- Reads and writes `<design>.notes.md` next to the design source file
- Returns an empty string when no notes file exists yet
- Rejects bodies larger than 1 MiB
- Parses open and done task lines and preserves scratchpad
- Ignores lines that don't match the structured task format

## serve/upload_datasheet

Public functions: uploadDatasheetApi, listDatasheetsApi, serveDatasheetApi, isPdfMagic, sanitizeFilename, storeDatasheet, storeErrorBody, storeErrorStatus

- sanitize strips path segments
- sanitize forces .pdf extension
- sanitize replaces unsafe chars
- sanitize strips duplicate-download marker
- sanitize preserves trailing-digit names
- isPdfMagic gates non-PDF input

## serve/edit

- datasheet dedupe ignores re-download counter suffix
- datasheet stem preserves trailing-digit part numbers
- edit-footprint locates the component token within the instance form
- rewire-pin locates the instance by component-token offset
- rewire-pin splits a multi-pin shorthand to re-wire one pin
- rewire-pin finds a pin in a section pins map

## serve/edit_assist

Public functions: validateSourceApi, libIndexApi, saveDiagramLayoutApi

- lib-index extracts a module's parameter names
- lib-index handles (param default) pairs
- lib-index returns no params when the defmodule is absent
- lib-index reports each component's footprint name
- diagram-layout writeback locates the existing form

## serve/component_search

Public functions: downloadFootprint, errorMessage, searchComponents, searchErrorMessage

- percentEncode escapes spaces and reserved chars
- looksLikeZip detects the ZIP magic bytes
- safeFilename builds a path-safe LIB_<part>.zip
- searchVariants relaxes the part number
- parses part id and datasheet url from a suggestion
- collectHits maps suggestions to search hits

## serve/digikey

Public functions: resolveMpn, searchErrorMessage, downloadDatasheet, datasheetErrorMessage

- parseAccessToken extracts the bearer token from the OAuth response
- collectProducts maps the Products array to resolved parts
- collectProducts captures live stock, unit price, status, and per-variation price breaks
- keywordVariants drops trailing keywords for graceful relaxation
- normalizeDatasheetUrl unwraps a gotoUrl interstitial

## serve/rate_limiter

Public functions: init, acquire, release

- acquire/release pair leaves no slots held
- acquire spaces successive call starts by the minimum interval
- acquire blocks a caller once max_in_flight is reached until a release

## serve/mcp_tools

Public functions: isMutationTool, call, listFreePins, listDesignNames, listDesignSummaries, renderSceneGraph

- fuzzyScore returns 0 when the needle does not match the haystack as a substring or subsequence
- fuzzyScore ranks a contiguous substring hit above a scattered subsequence hit
- fuzzyScore ranks a prefix hit above a mid-token hit for the same needle
- libEntryScore ranks a name match above a description-only match
- list_library with a query returns only fuzzily-matching entries ranked best-first
- list_library without a query (or a blank one) lists every entry
- The tools registration table and the embedded tools_list_result.json declare exactly the same tool names

## config

Public functions: cseConnectSid, digikeyClientId, digikeyClientSecret, digikeyApiBase, cseMinIntervalMs, cseMaxInFlight, digikeyMinIntervalMs, digikeyMaxInFlight

- stripQuotes removes one layer of matching quotes
- The ward cache ttl maps a zero or out-of-range value to the default and keeps valid values

## paths

Public functions: designSourcePath, designSiblingPath

- Resolves <name>.sexp via designSourcePath, falling back to flat layout when missing
- Resolves sibling artifacts via designSiblingPath using the supplied extension

## Web Server

- A saved layout round-trips a polygon board outline; the rect fields are re-derived as its bbox
- Inner-layer copper (l ≥ 2) round-trips the sidecar; legacy entries without an l stay top copper
- Stamped module copper keeps its group tag through the sidecar so rigid-group moves carry it
- Stamped module copper maps its net names onto the parent design via the origin-key bridge, slug-prefixing private nets
- The layout sidecar is snapshotted into history and listed newest-first
- Layout snapshots are pruned to the newest retention cap
- Source-snapshot listing skips the reserved layouts subdir
- The layout sidecar carries an optimistic-concurrency rev, emitted only when non-zero
- readLayoutRev reads the sidecar rev (0 for a legacy file), and a save stamps disk_rev+1
- An MCP layout mutation snapshots the sidecar to history and bumps the rev like a viewer Save
- The /pcb-layout page names the corner-posture toggle and offers Net colours
- A DRC violation carries a stable 4-hex id emitted by the shared JSON writer
- Per-design DRC rule overrides retag or drop violations before every reporting surface
- The /pcb-layout Properties dock hosts the inspector with segment editing and DRC rule settings
- Segment drags preserve neighbour track angles and insert perpendicular jogs on collinear runs
- The hand-route head dodges or clips at clearance obstacles instead of drawing violating copper
- Moving a placed component leaves its connected traces in place instead of deleting them
- The decoupling-loop overlay has its own visibility toggle, hidden by default
- The Objects tab offers a selection filter that skips unchecked object types when clicking
- Routing toward a same-net pad snaps the whole approach onto the pad centreline

## fab_readiness

Public functions: check, writeJson

- a routed net is connected; an unrouted multi-pad net is flagged
- connectivity propagates across an inner-signal-layer chain through its vias
- a ground plane connects its pads without routed copper
- a surface pad isolated from the plane is flagged until a plane via bridges it
- a missing outline, off-board part, drill-less via, and DNP all surface
- a clean board produces no errors and reports ok
- the fab gate's DRC measures against the design's resolved clearance rule
- a warning-severity DRC finding flows through as a gate warning; an error-severity one blocks
- a custom outline polygon with fewer than 3 points warns that the profile fell back to a rect

## Fatal Exit Helper

Public functions: fatal, failure

- fatal and failure terminate with a nonzero failure status
- completeness-waiver: empty inputs (a zero-arg format string is valid; the helper prints and terminates regardless of message content)
- completeness-waiver: large inputs (std.debug.print streams straight to stderr with no buffering, so a large diagnostic cannot exhaust memory here)
- completeness-waiver: unauthorized access (a process-termination primitive with no access surface; auth lives in serve/users)
- completeness-waiver: i/o failure (std.debug.print discards a failed stderr write by design; the process still terminates with the failure status)
- completeness-waiver: concurrent access (stateless with no shared mutable state; concurrent callers each terminate the process independently)
- completeness-waiver: malformed encoding (the caller supplies a comptime format string and the bytes pass through verbatim to stderr)
- completeness-waiver: integer overflow (no arithmetic — only the constant failure_status exit code)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)
