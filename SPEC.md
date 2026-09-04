# Netlisp

CLI-driven electronic design automation for schematic capture using S-expression syntax.

## CLI allocation lifetime

- one-shot CLI commands keep process-lifetime evaluation storage on the automatically cleaned process arena
- completeness-waiver: empty inputs (allocator selection occurs before command parsing and does not inspect input)
- completeness-waiver: large inputs (the process arena grows through checked allocator calls and is released in bulk at process exit)
- completeness-waiver: unauthorized access (allocator selection is internal and grants no file, network, or user capability)
- completeness-waiver: i/o failure (allocator selection performs no I/O; command-specific I/O errors keep their existing handling)
- completeness-waiver: concurrent access (each CLI process owns its process arena, while the long-running server retains the thread-safe GPA)
- completeness-waiver: malformed encoding (allocator selection does not decode command or design bytes)
- completeness-waiver: integer overflow (the arena delegates size arithmetic to the allocator's checked allocation path)
- completeness-waiver: panic-free (allocation failure remains an error from command allocations; arena teardown is automatic process infrastructure)

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
- Paren-span matching skips quoted parens and honours the dialect's comment style

## sexpr/printer

- Prints a simple list as a single-line S-expression string
- Prints short nested lists inline on one line
- Prints long nested lists with multiline indentation
- Round-trips parse to print to parse producing identical AST
- Round-trips every .sexp and .kicad_pcb file in the projects/designs tree, dot-directories excluded, through parse → print → parse with structurally equal AST, failing when the corpus count leaves its expected order of magnitude
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
- add_zone inserts a netlisp-owned refillable copper zone
- add_via at an existing via position is a no-op
- add_track inserts a (segment …) form on the op's layer
- seeded sub-circuit groups include their routed tracks and vias
- add_track at an existing segment (order-insensitive endpoints) is a no-op
- create_board_item writes a section staging box as a (gr_rect …) on Dwgs.User
- create_board_item writes a section label as a (gr_text …) on Dwgs.User
- create_board_item writes a perimeter mask segment as a (gr_line …) on F.Mask
- hides the refdes, value, and metadata so the silk/fab carries no auto-generated text
- leaves already-correct property visibility untouched (idempotent)
- an authoritative layout push moves footprints and replaces tracks vias groups and Edge.Cuts while preserving zones and unrelated drawings

## serve/layout-backfill

Public functions: backfill, boardKey, run

The `backfill-layouts` command: recover PCB layouts that survive only in the
`history/<name>/layouts/` snapshots or in git revisions of the sidecar, and
append them to each block's `.layouts.json` as ordinary named rows. Under the
retired single-layout rule a design's Save replaced its whole list, so those
archives hold the only copy of each superseded board. Recovered rows are plain
manual entries, so each gets a `?layout=<name>` permalink and the usual
Load / star / Delete. The existing rows and the star are never touched.

- a board's identity covers its copper, so two routings of one placement stay distinct
- a recovered board already present in the sidecar is skipped
- recovered rows append after the existing ones and never move the star
- a recovered row keeps its archive name when free and is dated from its snapshot when taken
- the limit bounds how many rows one block gains and reports what it turned away
- a dry run reports what it would add and writes nothing
- the argument parser reads the project dir, named blocks, dry-run flag, and limit
- empty inputs: a block with no archive and an empty sidecar recovers nothing and writes nothing
- malformed encoding: an unparseable snapshot is skipped and the boards around it still recover
- completeness-waiver: large inputs (every read is capped — a snapshot body at sidecar_max_bytes, one git capture at git_output_cap under a timeout, the revision walk at max_git_revisions, and the rows one block gains at the caller's limit)
- completeness-waiver: i/o failure (each archive read is independently fallible and degrades to "recover nothing from this one"; the sidecar write is atomic tmp-rename and reports false rather than raising)
- completeness-waiver: unauthorized access (a local CLI over caller-supplied paths; the archives are read-only and server-side access control lives in serve/ward_auth)
- completeness-waiver: concurrent access (a single-threaded CLI; the sidecar write is the same atomic whole-file replace every layout save performs, and it bumps the rev so an open editor tab 409s rather than clobbering)
- completeness-waiver: integer overflow (the only arithmetic is bounded row counting; the git revision walk and the per-block row count are both hard-capped)
- completeness-waiver: panic-free (every fallible step degrades to "recover nothing" — a missing archive, an unreadable snapshot, absent git, and a failed write all return a report instead of raising)

## serve/layout-merge

Public functions: run

The `merge-layout` command transfers one named layout row between monolithic
`.layouts.json` sidecars through the same protected semantic upsert used by the
editor. It preserves unrelated target rows, the target cache and star, records
history, and bumps the target revision, avoiding a textual Git conflict between
independent layout candidates. A source star moves only when `--star` explicitly
requests it.

- the argument parser reads project, source, layout, star and dry-run flags
- an upsert replaces only its named row and preserves the target star
- a dry run predicts its insert and leaves the target sidecar unchanged
- a missing target design is refused before any sidecar can be created
- completeness-waiver: empty inputs (design, source and layout are mandatory CLI arguments; a source with no matching row exits before writing)
- completeness-waiver: large inputs (the source read is capped at 256 MiB and target rows are traversed linearly)
- completeness-waiver: unauthorized access (a local CLI over caller-supplied paths; server access control is outside this command)
- completeness-waiver: i/o failure (an unreadable source or a target write that cannot be read back returns an explicit fatal error)
- completeness-waiver: concurrent access (the protected write snapshots history and bumps rev so a stale editor save is rejected)
- completeness-waiver: malformed encoding (an invalid source JSON or missing named row exits before the target is touched)
- completeness-waiver: integer overflow (row counts are slice lengths widened to i64 only for reporting; revisions are read and incremented by the existing protected writer)
- completeness-waiver: panic-free (fallible reads, parsing, allocation and persistence verification return errors rather than indexing unchecked input)

## kicad_pcb/import-layout

Public functions: build, writeReport, run, writeImportedStarredLayout

The `import-kicad-layout` command: port a routed KiCad board's placement,
outline, and copper INTO a design's `<design>.layouts.json` sidecar as its
starred layout, making the netlisp tool the system of record. The board
file is opened read-only and never written. The core (`build`) is a pure,
arena-based function over the parsed snapshot plus the flattened design view;
the CLI seam owns evaluation, file reads, the JSON result, and the sidecar
write.

- a board footprint matches by canopy_uuid first, then by exact ref-des
- unmatched board footprints and design instances are reported, never dropped
- a pose copies x and y and derives rotation and side via the sync bake inverse
- stale copper-only net names fold onto their pad-carrying canonical before mapping
- a board net whose pads agree on one design net maps to it as identical or renamed
- a board net whose pads split across design nets keeps its spelling as ambiguous
- a board net with no shared pads keeps its spelling and is reported unmatched
- a track on a layer outside the signal stack is dropped with layer, net, and length
- a copper arc tessellates into chords whose deviation stays within the chord tolerance
- every via imports as a through via and spans other than outer-to-outer are counted
- edge-cuts pieces chain end-to-start into one closed outline polygon
- an unclosed outline falls back to the flagged bounding-box rectangle
- zone boundaries/fills are imported with mapped net/layer geometry and keepouts stay nonconductive
- a pour-fed rail with under five millimetres of imported track is reported
- per-net imported track length and via count are reported
- the inbound HTTP preview reports geometry without claiming it was written
- the PCB editor previews KiCad warnings before replacing its starred layout
- an empty board yields no poses, no copper, and a flagged empty outline
- --dry-run parses as report-only and --chord-tol-mm overrides the tolerance
- the imported layout becomes the sole starred manual layout and bumps the rev
- the import keeps the design's other saved layouts, taking only the star from them
- the report renders as one stable json object
- completeness-waiver: large inputs (linear scans over the parsed snapshot's typed slices; a bigger board only lengthens the report lists, never the shape)
- completeness-waiver: unauthorized access (a local CLI over caller-supplied paths; the board is opened read-only and server-side access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (build is pure over parsed inputs; the CLI routes board-file read errors through the fatal helper and the sidecar write returns false instead of raising)
- completeness-waiver: concurrent access (a single-threaded CLI; the sidecar write is the same whole-file replace every layout save performs — last writer wins)
- completeness-waiver: malformed encoding (consumes the typed snapshot from kicad_pcb/snapshot; malformed-board rejection is upstream in the sexpr parser and board reader)
- completeness-waiver: integer overflow (millimetre math stays in f64; the only float→int narrowing is the clamped arc chord count through numeric.checkedInt)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## Development pipeline

The build graph and tracked hooks keep a fresh worktree deterministic while
shortening the commit-to-deploy critical path. Generated zt output is committed
and still regenerated from source; every reader waits on the same generate and
format predecessor. Every internal netlisp artifact and workflow uses self-hosted
Debug. Release preparation is the sole ReleaseSafe boundary: it gates one clean
commit, then overlaps the Debug full suite with the independent self-hosted
ReleaseSafe production build and publishes an immutable, checksum-addressed
candidate for deployment.

- Roots unit tests separately from the production executable
- Runs the unit-test suite as concurrent shards whose filters claim every named test, including local-first routing regressions, exactly once
- Ground-via seed model and endpoint tests remain claimed by the shard manifest
- RF pad adaptation tests remain claimed by the shard manifest
- The live sub-circuit Stamp endpoint regression remains claimed by the shard manifest
- The saved-pose identity tests remain claimed by the shard manifest
- Panelization export tests remain claimed by the shard manifest
- Bridges every test-bearing module into the shard import graph so filters alone decide a shard's contents
- Rejects a shard filter that no longer names a test in the tree
- Pins every gated full-test invocation with `--seed=1` so an unchanged tree's test run is a cache hit
- Resolves build identity at runtime without making each commit a compiler input
- Follows a worktree gitdir pointer and commondir to the shared refs, with packed-refs and detached HEAD fallbacks
- Orders generated templates before every compiler and Guardian consumer
- Runs full tests and forces the concurrent ReleaseSafe build through the self-hosted backend for one exact commit
- Cancels the complete concurrent ReleaseSafe process group as soon as full Debug tests fail
- Selects a bounded reverse-dependency Debug subset from the Git diff, always includes boundary smoke tests, then analyzes the whole suite without narrowing the release gate
- Strips only the deployment ReleaseSafe executable while internal Debug artifacts keep symbols
- Verifies the self-hosted production ELF has no debug or symbol-table sections before publication
- Records the source tree hash alongside every candidate it publishes
- Binds release candidates and caches to the exact compiler binary, not only its reported version
- Rejects production preparation and deployment unless the compiler binary matches the pinned SHA-256
- Carries an exact runtime build ID and artifact policy with every release candidate
- Adopts an already-verified candidate for an identical tree instead of rebuilding
- Adopts only a candidate carrying its verification marker and a passing checksum, and otherwise falls back to the full build
- Deploys only a checksum-verified candidate for the exact main commit
- A failed test or build keeps its grouped status and full logs without publishing a candidate
- An absent candidate on main is prepared before the running service is restarted
- An unhealthy new process rolls back to the last health-checked binary
- Restores the runtime build ID paired with the last health-checked binary during rollback
- A healthy deploy refreshes the design-agent folder's binary and runtime build id
- Serializes heavy gates behind one machine-wide lock with an environment bypass
- Prepares a release under that gate lock without re-entering it
- The production systemd unit executes the deploy-installed binary and never the build-output path that a local build overwrites
- The checked-in systemd unit is the rendered form of the deploy-hook template, so the two cannot drift apart in the directives that matter
- The production unit keeps the restart and autocommit settings that recovered the 2026-07-25 outage and that keep design persistence on the checkpoint timer
- completeness-waiver: empty inputs (the pipeline has no user collection input; an empty source tree cannot configure the declared Zig artifacts and therefore fails before candidate publication)
- completeness-waiver: large inputs (logs stream to files rather than memory and the candidate contains one production binary plus bounded metadata; source and test scale remain the Zig build system's domain)
- completeness-waiver: unauthorized access (the scripts mutate only the current repository's shared git directory and production service, and production activation remains an explicit machine-local hook opt-in)
- completeness-waiver: i/o failure (every template, gate, test, build, checksum, copy, rename, restart, and health-probe failure exits nonzero; deployment does not restart before candidate installation succeeds)
- completeness-waiver: concurrent access (exact-commit preparation and deployment each use flock, separate Zig local caches isolate the parallel jobs, and candidate publication is an atomic same-filesystem rename)
- completeness-waiver: malformed encoding (commit IDs come from git, status files contain script-produced decimal fields, and paths are shell-quoted; no untrusted structured payload is decoded)
- completeness-waiver: integer overflow (elapsed seconds are shell integers derived from the local clock and bounded by process lifetime; no source-sized value is used in arithmetic)
- completeness-waiver: panic-free (shell commands report nonzero status rather than panic; panic-freedom in the compiled application remains enforced repo-wide by Guardian)

## placement/geometry

Public functions: load

- parses pads and courtyard half-extents from a footprint sexp
- synthesizes a fallback box sized by pin count when the footprint is missing
- parses silkscreen lines and circles from a footprint sexp
- parses an oval drill into a slot (minor-axis tool + arc-centre offset), pad rotation, and roundrect ratio
- parses a pad's own solder-mask margin and its no-paste keyword, defaulting to the board rule when absent

## placement/pose_math

Public functions: rotate, aabbHalf, obbPenetration

- arbitrary-angle pose math keeps exact right angles and bounds a 45-degree rectangle
- two oriented rectangles report the penetration and a point inside the region they share, and none at all when a separating axis exists
- completeness-waiver: empty inputs (both functions consume fixed scalar arguments; zero extents and a zero angle are defined identity cases)
- completeness-waiver: large inputs (constant-time scalar arithmetic allocates nothing and has no collection-sized work)
- completeness-waiver: unauthorized access (pure numeric helpers perform no access control, filesystem, network, or external-state operations)
- completeness-waiver: i/o failure (pure numeric helpers perform no I/O)
- completeness-waiver: concurrent access (pure functions share and mutate no state)
- completeness-waiver: malformed encoding (the typed f64 API parses no external encoding)
- completeness-waiver: integer overflow (all operations remain in f64; no integer conversion or indexing occurs)
- completeness-waiver: panic-free (the helpers allocate nothing, index only fixed two-element values internally, and have no error or panic path)

## placement/optimizer

Public functions: solve

- a placement carries the per-net rules its preparation already resolved rather than resolving a second identical copy
- a pose seed that misses parts stages them in a band below the covered bbox, never stacked at the origin, and reports their refs
- the authored board rectangle centres on seed-covered parts only, so an uncovered part cannot drag the outline
- classifies hub vs passive ref-des, handling hierarchical paths
- anchor pick prefers net degree over courtyard area, area only breaks ties
- an explicit rough anchor overrides a passive-looking ref-des prefix and is prepared as a hub
- (rough …) anchor/group tokens match by ref-des or origin name
- an authored rough critical-loop parses as a named closed-chain member set and contributes whole-loop compactness to placement ranking
- partial apply locks every covered part and leaves the rest free
- an authored board keepout region refuses a component pose on the face it reserves, leaves the other face alone, and charges the guidance hinge for a courtyard that settles inside
- legalization never moves a locked part; the free side absorbs the push
- a locked anchor keeps its pose and the ring transforms into its frame
- a pinned block pushes free blocks aside and never moves
- a starred module layout seeds the sub-block macro, matched by origin key
- a switcher board tries the zone floorplan before the ring; ferrites on plain rails do not qualify
- excludes ground nets from spring forces
- board rules resolve declared pours by outer face and plane membership by net name
- derives the routable signal-layer set from the stackup: outer faces always, inner layers only when no plane claims them
- resolves a copper-layer name to its routable signal-layer index, rejecting junk and plane-claimed inner names
- the shared layer table places the implicit model's four layers with ground and rail planes inside
- a declared stackup's routable indices skip its plane-claimed inner layers
- a copper-layer name resolves case-insensitively to its routable index and plane-claimed inners resolve to none
- an imported copper spelling is recognized case-insensitively apart from the board's own rows
- the layer table spells each copper layer's Gerber suffix and X2 file function, giving every inner layer the spec's Inr regardless of any plane on it
- the layer table carries the fixed technical rows (mask, paste, silkscreen, profile) after its copper, with their KiCad, UI and Gerber spellings
- each named layer constant is the exact KiCad spelling the materialized table gives that role and face
- a front-side layer name flips to its back-side twin while a sideless or already-back name passes through unchanged
- a stack row takes the KiCad palette colour of its physical position and an outer pour keeps its routable index
- the board theme's copper entries are the shared layer table's own face colours and every wire entry is a well-formed colour
- a theme wash is its own base colour at an alpha, decoded by the one hex parser
- the board theme emits once as a blob object and once as :root CSS custom properties, carrying the same values
- an empty routable-layer set allows every layer while a named one allows only its members
- multi-pin wirelength uses the rectilinear MST, which equals span when collinear and exceeds HPWL otherwise
- loop inductance floors at the via mounting inductance and rises with conductor length
- the scored loop term is the smooth analytic surrogate, continuous in part position (no routing cliffs)
- input-rail names (and raw rails ≥7V) read as the switching hot loop; output/low rails do not
- routing congestion is zero with no multi-pin nets and positive when nets pile into one region
- legalization separates two overlapping courtyards
- fresh rough placement lets adjacent courtyard edges share one grid line exactly while retaining overlap-free legalization
- a bottom-side part mirrors footprint-local x in world transforms and never collides with top-side parts
- cached poses restore each part's board side and lock flag
- a rejected cache leaves no part pinned
- rotates footprint-local offsets at editor-authored 45-degree poses
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
- one authored pour-clearance sets the outer-face pour gap as well as the inner-plane one
- a bridged subcircuit keeps its class and adopts destination profile fields
- escape defaults to 1 mm on a max-freq class; explicit (escape) overrides
- a net-class min-bend-radius lowers onto its nets' resolved rule
- a net-class mask-relief resolves onto its nets' rule and leaves undeclared classes at the sentinel
- a net-class fence resolves as one unit so the best-ranked declaring class wins the whole block
- a declared keepout with no escape radius inherits the net's resolved rf escape
- a pose seed's drawn outline overrides the authored board rect and grows the framing bbox; authored-only leaves the placement untouched
- outlineOf lifts a placement's folded board outline into a pose seed, authored-only when the placement carries none
- a part bound only to a supply rail follows its private chain to the pad that anchors it
- a series part across two package edges takes its signal end, and the busier node when both are signals
- an authored group's unbindable members join the edge its bound members hold, and a bypass bank is untouched
- a chain child hangs off a ring-bound entry on its chain's home edge, spreading over the entries there
- a 2-pad part with a precise partner on each leg turns its pad axis to face them
- authored rough groups map to a per-part grouping, first membership winning
- a bypass cap on a rail shared by several ICs loops to the IC its binding names, not the first part carrying that pad number
- a decoupling binding naming another IC yields no pad for that hub while an unnamed one still does
- an explicit decoupling binding outranks the per-pin structural key when reading a part's target
- a (near "REF" PIN) binding resolves to the declaring part's leg on the target pad's net
- (own PAD) overrides the inferred leg and an off-net (own PAD) resolves nothing
- a (near …) naming an absent ref, an absent pad, or a foreign net resolves nothing and is reported
- a design that declares no (near …) resolves to no adjacency pairs at all
- a near-bound passive is owned by the part it names even when its two legs straddle different hubs
- decoupling criticality reads capacitance through the shared parser, so a micro-sign value ranks as the bulk cap it is
- the design-level critical rough judges ground with the project's one predicate, so a split or numbered ground is never mistaken for signal

## placement/router

Public functions: route, perNetRouted, returnPathViolations, canonicalizeTraceJunctions, glossFinishedTracks, foldNetBranches, cleanupBoard

- maze-routes a two-pad net into connected track segments
- an equal-length octilinear tie is settled toward the straight path rather than an arbitrary staircase of the same length
- the maze queue orders on A* priority alone, with corner count priced into the cost rather than ranked beside it
- a maze leg is charged for the escape stub each pad gateway implies, so it buys the entry that points where the route goes instead of the outermost free one
- a connection that routes far past its own span is retried once on another face and keeps whichever route costs the board less
- a net whose policy forbids vias keeps its detour rather than gaining one from the detour guard
- a failed broad net retries its repair-waypoints before lower waves can claim the corridor, without perturbing a successful ordinary route
- an authored branch tree routes a multi-drop net through one corridor per drop, bound to the terminals by geometry rather than by authored order
- a branch tree that cannot be bound to distinct terminals guides nothing, leaving the net to the ordinary multi-terminal router
- a timed deferred repair corridor runs under one flat probe budget, so corridor length cannot scale its claim on the shared deadline
- a pour-derived field string-pulls an open corridor to one direct off-grid segment
- the field's exact oracle removes conservative raster waypoints while preserving required corridor turns
- field-directed finish accepts exact-clearance continuous shortcuts instead of retaining octilinear quantization detours
- a sub-base-grid opening remains visible at the fixed 0.05 mm field pitch
- routing the same placement twice is byte-identical
- vectorized maze-source discovery preserves ascending node order
- route-space immutable rasters and cached path payloads share one memory budget while the single live raster is independently cell-bounded
- the copper index's nearSegment query is a superset of the full scan: every box within reach of the segment appears in the candidates
- a clearance probe never resolves a stale copper index: after a cleanup compaction slides survivors into removed slots the probes fall back to the full scan instead of judging the wrong track
- exact clearance probes inspect copper appended after their spatial index was built
- a gap hop's terminal stub is probed against the live board copper, so it cannot be drawn through a via the maze itself routed around
- exact same-net vias at one coordinate collapse to one physical drill before final DRC
- generated same-net cap overlap is closed by an explicit endpoint-on-centreline bridge
- adjacent same-net branches merge into an established trunk without losing any terminal connection
- a blocked perpendicular branch fusion tries the adjacent 45-degree trunk landings before retaining a parallel same-net run
- adjacent same-net SMD lands share one escape instead of retaining a multi-leg pad comb
- same-net runs separated by one intervening routing lane still consolidate into the shorter trunk
- a generated trace that only grazes a via receives an explicit centreline-to-via-centre weld
- a generated mid-span X is split at one exact coordinate while retained copper stays byte-identical
- canonical junction repair never rewrites or augments caller-retained copper
- finished autorouter copper removes dangling trace leaves and vias used on fewer than two layers
- a finished route offered two paths between the same lands keeps one of them and reports no dangling copper
- the finish deletes every stored section whose removal preserves all pad and live-via connectivity, keeping the run that carries the net
- the finish's section-deletion plan never strips retained out-of-scope copper
- the finish leaves copper that reaches at most one support to the leaf pass, since a fill-blind seam cannot tell dead metal from a pour connection
- a section-deletion plan built over a filled region drops exactly one leg of a doubled pad stub
- a pad some run already enters at full trace width receives no centre weld
- the shared route gate applies a jointly safe deletion plan so alternate paths cannot be deleted together
- the shared route gate retains a single-layer via when removing its annulus would split the net
- the shared route gate consumes the jointly safe redundant non-ground via plan
- a failed authored guide gets one immediate half-pitch retry before lower waves claim its corridor unless a whole-route deadline prioritizes breadth
- ordered waypoints seed one clearance-aware shared trunk for a multi-terminal net before exact-guide fallback
- every leg of a shared guided trunk enters its waypoint chain from the same end, so the trunk is one corridor rather than two opposed ones
- a net spanning the two board sides routes through a via, each leg on its part's layer unless the barrel stands in that pad's own land
- a board outline detours routed copper around a concave notch; no-outline routes unchanged
- a plane-less stackup routes ground as real copper instead of dropping plane vias
- signal nets in an explicit authored route wave claim their copper before plane stitching, while the rest wave still follows the plane pass
- exposed-pad thermal fields use practical centred 3x3 and 4x4 arrays instead of the DRC-densest possible drill packing
- large and tightly packed exposed-pad thermal arrays reserve their field before authored before-plane signal waves, while preferred-pitch 3x3 arrays and ordinary plane stitching retain their later order
- plane nets follow authored route-wave priority within the plane-stitch pass, so a ground wave can reserve stitch sites before a competing power pour
- routes through a plane-free inner signal layer when both outer faces are blocked; a 2-signal stackup never emits inner copper
- a retained same-net pour on an excluded inner layer reuses its nearest same-net pour via within 3 mm, then prefers a legal via-in-pad before a maze stub
- reports a grid too large to route via RouteResult.grid_overflow instead of a silent empty result
- a (match-group …) joins nets across classes on the authored name and takes the tightest declared tolerance
- a match-group name and its tolerance resolve independently through the class hierarchy
- an undeclared (match-group) tolerance falls back to the module default
- a match-group length charges each via barrel the board thickness, defaulting to the fab standard when no stackup declares one
- a match group's spread is measured over its routed members only, and an unroutable member never reads as a mismatch
- within a match group the router routes the longest-expected member first, leaving every other net's slot untouched
- a match group whose members are absent from the routing order is left alone
- a 1-2-net scoped route whose automatic fine-grid promotion overflows the node budget falls back to the base pitch instead of routing nothing
- an outer-layer pour connects same-side pads directly; only opposite-face pads get a stitching via
- a net-class rule sets its nets' trace width and via size; unruled nets keep defaults
- a declared keepout halo pushes a later net's copper and vias off the keepout net's own layer
- a keepout net's component pad stamps its exact halo on the SMD face and every signal layer when through-hole
- the far copper layer under an RF trace stays passable, but a run parallel to the trace there pays the corridor shadow
- a ground net is never held off by a keepout halo, so a stitching return may hug the RF trace
- a full RF fence corridor remains a routing cost between same-class nets, so a tiny authored fence cannot collapse a wider keepout halo
- a keepout halo carried by retained copper holds off a net routed on its own
- the router's escape gate is built once per route and admits, per net, only the zones that net owns a pad inside
- a keepout escape zone lets out the neighbour pin that owns a pad in it and refuses a net merely passing between two RF pads
- a foreign net's pad landing carved out of a keepout halo is keyed to that pad's net, so no other net threads it
- a measured approach to a keepout net's copper is held to its ordinary clearance inside an escape zone that admits the routing net, and to the full halo everywhere else
- the keepout escape gate re-aims at another net mid-route, so a coupled diff pair judges each leg by the zones its OWN pads sit in and never its twin's
- an obstacle's raster stamp always claims the ordinary clearance under its keepout halo and claims the surplus above it only where no admitting escape zone covers the node
- a derived context's obstacle stamp opens its keepout surplus inside an admitting escape zone and keeps the full halo outside it, on the raster and on the exact re-measure alike
- an RF corridor reaches the far edge of the full fence-via diameter for declared and max-freq-derived fences, never shrinking below a wider authored halo
- a fenced net's copper shadows every signal layer, its owner and exempt ground pay nothing, and a via into the shadow costs more than a step
- a via reads the RF shadow on every signal layer while a step reads only its own, since a through barrel occupies them all
- a synthesized segment crossing an RF corridor is admitted by the angle it meets it at, so a 45 degree lattice crossing passes where a shallow approach and a parallel run do not
- each crossing of an RF corridor is judged on its own contiguous span, so one segment crossing several unrelated corridors squarely is not refused for their sum
- a foreign net crossing a shadowed RF corridor crosses it roughly square instead of running along it
- ground copper crosses an RF corridor without paying the shadow, so a return path may still follow the trace
- the router's fence-corridor width agrees with the via-fence generator's outermost resolved row
- routes corners as 45° diagonals rather than 90° bends
- straightEscapePair accepts an axis-aligned pad pair that faces along the hop, rejecting a diagonal, a perpendicular-facing, a coincident, or a cross-layer pair
- LoopRouter measures a real per-leg trace length that detours foreign pads
- counts signal vias lacking a nearby ground stitching via as return-path discontinuities
- stitches each signal via's return path with a nearby GND plane via
- the final autorouter pass adds a DRC-clean plane via within the authored maximum of every eligible SMD ground pad
- removes a single-pin breakout's unfinished stub and one-layer via from finished copper
- elevates only the switching hot loop above the baseline routing tier
- lets authored (net-class (priority …)) dominate the intrinsic net-class rank
- auto-elevates a bare hub-to-inductor bridge net to the hot-loop tier
- names the nets that failed to route in RouteResult.failed
- a failed leg's goal is never a same-net source, so a later leg cannot weld to a stranded pad
- a failed multi-terminal net retains a subtree only after two real pads are electrically joined
- a refused whole-net rescue puts back the retained copper it lifted, so an attempt that changes nothing costs nothing
- a leg seeded on a pad-buried halo node has its copper trimmed back off the land instead of the net being failed
- the pad-buried source trim happens at the shared search seam, so a pass that does no trimming of its own still emits pad-clearing copper
- a later leg's weld to the net's occupancy halo is bridged to the real copper so the two legs share metal
- a halo weld whose bridge would cross foreign copper is refused instead of laid over it
- a pad-centre join stops at the foreign-pad clearance instead of emitting the segment nothing probed
- perNetRouted totals a net's routed copper length and via count
- a route records the lattice it searched on, and the vision mask replays the maze's own blocked predicate against a timeline event's copper
- a vision mask is refused rather than guessed when the timeline recorded no lattice or the design's layer count has since changed
- a net's vision mask uses that net's own class clearance, so a wide net sees a tighter board than a thin one at the same instant
- smooths an rf net's corners inline as it routes, recording a per-net bend event
- an escape-constrained pad exits straight for the declared distance before its first bend
- rip-up runs no rounds when the greedy pass already routed every net
- routed copper stays on the octilinear headings when the pad span is off-axis
- ordinary QFN pads enter and exit at the pad centre on a 45 degree heading that never points back past the land, straight until they are clear of it
- rip-up leaves a wall-blocked net failed without disturbing an already-routed net
- final cleanup removes an unfinished escape stub without disturbing routed foreign copper
- reserves diagonal corner cells so later nets keep trace-to-trace clearance
- escapes a fine-pitch pad through an off-grid gateway stub when no grid lane clears
- a hemmed breakout drops its unfinished escape stub when no legal via can land
- final topology pruning runs after RF finishing and ground-pad stitching, so no copper producer bypasses it
- keeps every placed via a hole-to-hole wall from every other drilled hole
- a candidate via site keeps the hole-to-hole wall from every through-pad bore, its own net's pads included
- a maze via candidate is refused inside a through-pad bore's hole-to-hole wall
- a barrel's wall to a bore is measured end-to-end along an oval slot, and a bore coincident with the barrel is the same hole rather than a wall
- a pad's own quarter rotation reorients its routing obstacle so the vacated lane routes straight and DRC agrees
- a max-freq net's routed staircase collapses straight at finish and its arcs rebuild on the taut path
- diff-pair resolution pairs a two-net class and matches a larger class by P/N naming
- diff-pair naming follows KiCad's P/N and +/- suffix rule, including trailing digits and underscores
- KiCad pair names support P/N and +/- with trailing suffix digits, while pair rules inherit Default and respect board and physical-hole minima
- routes a diff pair's N net immediately after its P net
- dilates the routed P copper into a per-layer coupling corridor bitset
- dilates foreign copper into the coupled diff-pair envelope's exclusion mask
- coupled diff-pair pad matching pairs the ends by proximity and refuses pads too far apart to launch a pair
- the coupled diff-pair chainer refuses copper that is not a simple two-ended path
- a coupled diff pair splits one centreline into two legs at the class offset, each landing on its own pad
- a coupled diff pair miters every centreline bend so the legs hold the class offset through the corner
- a coupled diff pair turns each centreline layer change into a via pair spread along the path normal
- a coupled diff pair sizes its via-pair spread so both barrels clear each other and the opposite leg
- a coupled diff pair applies KiCad's edge-to-edge via gap independently of its trace gap
- a coupled diff pair length-matches its legs in the pad fans, leaving the coupled section untouched
- a coupled diff pair threads its end's pad pairs in sequence, terminus first, converging to the class gap beyond the last
- the coupled diff-pair chainer welds a run onto a barrel within half a track of the drill centre, not only dead on it
- a coupled diff pair leaves each end straight along its escape before tapering, so the legs never cut across their own pad field
- the coupled diff-pair construction cuts a hairpin corner out of its centreline instead of mitering the legs through each other
- a declined coupled diff pair can name the copper that blocked it, telling the pair's own legs apart from a foreign net
- a coupled diff pair turns a doubling-back at its escape into a layer transition, cutting only the hairpins that cannot be one
- coupled diff-pair end options are capped and ordered every escape direction's preferred way out first
- a coupled diff pair keeps each leg on the physical side its own pads are on, flipping its offset sign at every via the centreline reverses through
- a declined coupled diff pair that never reached the clearance gate can name the stage it gave up at
- a coupled diff pair whose ends demand opposite sides absorbs the twist at ONE in-line via transition, and an untwisted pair keeps its barrels across the path
- effective copper length is the shortest path over merged copper, so a retraced or spurred leg measures its real electrical length
- effective copper length crosses layers only through a via, and reports unreachable copper as unmeasurable
- a coupled diff pair's centreline drops copper it retraces and the no-op via a reversal split leaves behind, and spends no layer change on the fold it removed
- a coupled diff pair offers a straight approach at an end that overruns its terminal as a candidate alongside the layer change, so the probe picks between them
- a coupled diff pair holds the class gap for the whole run, departing it only at a pad span or a via barrel and entering each departure by one 45 degree jog
- a coupled diff pair refuses a construction whose leg overlaps or crosses its own copper, and matches lengths on the effective path
- a differential pair whose ends are too tight to carry a coupled run holds the narrow pad pitch in a straight launch and fans outward once at the wider pads
- a too-short differential pair whose endpoint pitches differ only by placement tolerance takes one direct pad-to-pad segment per leg
- a too-short differential pair is routed directly before an exterior coupled escape can send it back through its first component
- a differential pair with room for a coupled run is not given the short-pair fan construction
- a twisted differential pair is refused the short-pair fan construction rather than crossed over itself
- a diff pair's N net is biased into a corridor hugging its already-routed P twin
- an empty diff-pairs set leaves routing unchanged and deterministic
- escalation widens the maze expansion budget only for a retried search-limited leg
- a leg following a soft reference guide searches on the targeted expansion budget, since its heuristic is discounted to stay admissible
- a diff pair whose follower leg fails keeps its already-routed leader leg
- an escalation re-couple rips both legs, re-runs the coupled construction and freezes both, and rolls the whole transaction back when it declines
- a declared pair's member escalates through the pair driver, never as a singleton
- a declared diff pair routes deterministically across identical runs
- a coupled diff pair's under-radius corners are reported as sharp bends even though its copper is never reshaped
- rip-up eligibility covers any net still failed after budget escalation
- the expensive finishing rungs arm only once the residual is down to the last few nets, and a wider residual leaves every tier byte-identical
- the widened rungs carry a per-board spend cap, so a wide residual cannot each pay a whole fine-grid retry
- rip-up equal-count keep-best scoring preserves authored wave priority before preferring shorter copper
- a rolled-back attempt restores the search-limited marks its own probe added, leaving the set byte-identical
- a last-resort retry escalates a residual leg to a larger expansion budget than an ordinary escalation
- budget escalation re-runs after rip-up as a safe no-op once every leg is routed
- a fine window's grid-cell count scales with its rectangle and pitch
- a fine-window tier over budget yields no candidate at that pitch
- a fine window grows a net's terminal box by the margin and clamps it to the board
- a fine-window multi-terminal net orders legs by nearest unconnected pair spanning every terminal
- a scoped route echoes retained out-of-scope copper byte-identical; no finish pass rewrites an unselected net
- a batch or scoped route retries a bounded-classifier base-grid quantization failure on a quarter-pitch single-net window over live copper even when an earlier coarse attempt recorded a search limit
- a high-fanout retained-pour net gets per-terminal fine-window rescue after higher-priority copper routes
- a fine rescue window bounds the escape direct-synthesis probe sweep it forces on, while a whole-board route keeps the unbounded sweep an author-declared escape net is allowed
- collapses a collinear multi-pad net to one straight through-line
- snaps a terminal via onto its pad centre and drops the sliver tail
- a terminal-via snap reuses the earlier same-net barrel when recentering would create the barracuda TXDATA via-spacing error
- drops sub-micron degenerate track segments from the finished copper
- bridges a same-net copper gap so a routed net is connected by construction
- a trace that only grazes a pad is welded from its centreline to the exact pad centre
- finds a redundant layer hop whose detour can be redrawn on the layer both its ends already use
- refuses to delete a layer hop whose run branches or whose ends leave on different layers
- keeps a layer hop whose replacement would double back over the copper already leaving a via
- keeps a layer hop on a net whose policy authors its own layer choices
- the CDT rescue threads a sub-grid pocket the coarse grid pitch cannot represent
- an obstacle-free CDT window routes a straight terminal-to-terminal segment
- a fully sealed CDT pocket yields no path
- a CDT scene records which of the caller's obstacles each inflated polygon came from, so a failed search names real copper and measures the two bodies rather than the anonymous rings that hid them
- when no channel joins two terminals on any layer the multi-layer CDT search names the narrowest wall between them, the copper on each side of it, and the clearance there against the clearance the request needed
- a mesh search that finds its channel reports the route and no pinch, so the diagnosis is paid for only where there is something to diagnose
- the CDT funnel detours around a single convex blocker keeping clearance
- the CDT rescue routes deterministically across identical runs
- exact orient2d and inCircle predicates agree with the geometric sign
- a CDT constraint edge survives in the triangulation and bounds a blocked interior
- a CDT route bounds its total meshing work with a global budget and gives up (no path) instead of spinning on a degenerate scene
- a board-scale CDT scene of a thousand-plus obstacles meshes inside the work budget and routes the channel between them
- a CDT mesh keeps its edge set, vertex incidence and point index consistent with the triangles after splits and constraint flips
- a board-scale CDT route is deterministic and every obstacle boundary survives as a constraint edge
- a CDT window seals the lattice-thin ribbon along its hull so an obstacle clamped to the window cannot be walked around
- the multi-layer CDT router dives through a via to cross a wall that seals its own layer
- the multi-layer CDT router stays on one layer when that layer already has a channel
- the multi-layer CDT router reports no route when the only via site is sealed on the far layer
- the multi-layer CDT router is deterministic across identical runs
- the multi-layer CDT router refuses a terminal on a layer the net may not use
- the multi-layer CDT router escapes a terminal sealed in its own pocket only when a via site lies inside that pocket
- a CDT obstacle whose net declares a keepout halo is inflated by it, so the path keeps the halo distance the emitting caller's own clearance gate measures rather than the ordinary clearance the mesh used to model
- a CDT keepout region blocks the free space of the layer it names, and of every layer when it is declared board-wide
- a shape window is clamped to its own context's raster, not to the whole board, because the emission gate refuses every point outside that raster
- the shape tier anchors a fine disc of via candidates on each terminal, so a pocket the window lattice never samples still gets a layer change
- the shape tier withholds a terminal via candidate the hop's own via ban covers
- the shape tier declines a clock-free board and accepts one with wall clock to spare per remaining net
- the shape tier offers a net the layers its policy allows, priced as the maze prices them
- the shape tier's window is the net's terminal box with room to bow, clamped to the routing grid
- every gridless mesh request is assembled by one builder, which models the routing net's own track width unless the caller names a wider channel
- a gap hop the maze cannot draw is re-asked of the gridless mesh before any copper is ripped
- a gap hop past the maze's practical reach asks the gridless mesh first and the maze second, so a doomed cross-board maze cannot spend the whole attempt before the geometry answer is tried
- a progress sink observes every captured timeline event in order during a routed run
- a cancelled run stops at a net boundary and still finishes to a valid partial result
- a run cancelled before it starts routes nothing and still records a complete timeline
- closeGaps bridges two same-net pads around foreign pad copper and welds both pad centres into the new track chain
- a gap bridge that changes layer never drops its via inside a terminal pad
- a gap pass reports one progress event per requested hop, in order, saying whether it landed and carrying that hop's own reason
- a gap pass that cannot reach the far pad reports a blocked channel rather than a sealed terminal
- the smd_ok terminal-via policy frees an SMD terminal pad for a hop's escape via while a through-hole terminal stays banned
- a gap hop leaves each terminal from the clearest point inside that pad, not from the pad centre
- a gap pass keeps a new barrel clear of every drill already on the board, the routed vias as well as the through pads
- a gap pass re-asked on a finer grid divisor threads a corridor whose only legal lane is invisible at the standard gap pitch
- a blocked gap bridge rips a foreign net walling its path, not only copper crowding a terminal
- an escalated gap bridge walled by several nets at once clears them together once no single rip opens the channel, and names every net it took
- a gap pass's rip-up skips the nets its caller refuses, so its candidate budget is spent on aggressors it may actually move
- a gap pass started higher on the rip ladder clears the whole aggressor net instead of a terminal subset
- a gap bridge threads a channel sized for its own net class, not for the board's widest
- gap copper keeps its own net's real clearance from the foreign copper it threads past
- a gap-pass via site counts its clearance from already-inflated foreign copper once, not twice
- a gap pass puts only the copper its caller keeps onto the board the rest of the batch routes against
- a plane stitch lands only where its own pour's copper survives a higher-priority overlap
- a plane stitch may land in ANY of its net's pours, not only the largest
- a stitch hop's own SMD terminal pad is never via-banned, while a through-hole stitch terminal stays banned
- a plane stitch with no legal via site falls back to the oracle's short pad bridge
- a stranded pad's stitch target is the pour copper that survives priority clipping AROUND THAT PAD, so a net whose fill is knocked back there is stitched as if it had no pour
- a stitch onto a pour a higher-priority overlap knocked back falls through to its trace fallback, while the same geometry at equal priority still stitches
- a needless layer dive is replaced by a three-segment corridor path on the layer both its ends already use
- a corridor whose legs would overshoot the dive's own span is refused rather than doubled back on
- the corridor sweep tries the plain elbows first and then deviates from the dive's own midline outward
- a dive is elided only when the net's route policy admits the surviving layer and asks for no geometry of its own
- a net that declares RF bend discipline keeps its dives, because its corners are authored arcs
- a dive is elided only when nothing the removed via's land alone joined would be stranded by the thinner trace that replaces it
- a dive scan pairs two pure transition vias through a single-layer run and refuses a run that branches
- a via crowding an existing same-net via is folded onto it instead of kept as a second drill
- a same-net via fold never moves fence or stamped copper and never crosses nets
- a same-net via fold is never planned onto a via that is itself being folded away
- the closing gloss drops every repeat of one finished section, keeping the widest copy once
- the closing gloss drops a dangling tail shorter than half its own width and keeps one its copper does not cover
- the closing gloss fuses a collinear pair at a bare vertex and refuses one carrying a junction, a barrel, or a land
- the closing gloss leaves immutable caller copper byte-identical
- a cancelled run still ships deduplicated, tail-free copper instead of raw maze output
- a net-scoped branch fold folds a caller's accumulated parallel legs and hands back unfoldable copper verbatim
- one shared pass resolves every placed pad's world copper, net and bore, so the DRC and the client probe read identical pad geometry
- one shared projection turns a world pad list into the keepout escape terminals, guarding only netted plated copper
- the shared topology projection canonicalises pad nets only for the caller that asks for it
- one shared raster stamps every routing halo disc, covering exactly the lattice nodes within its radius
- a halo swept along a segment samples it at half-grid steps, so consecutive discs always overlap
- a cleanup pass never rewrites copper outside the route's own scope, and never one leg of a differential pair alone

## serve/subcircuit-route

Public functions: routeAll, regressed

The hierarchical autorouter routes each first-level sub-circuit before the
assembled board. A local pass retains the real board outline, stackup, design
rules, pours, and keepouts. Its primary placement retains every assembled-board
component as a physical obstacle while exposing only that sub-circuit's net
terminals, and its maze sees no saved trace/via copper or foreign reserved lanes.
It lowers the child block's own PCB plan in the child's net namespace;
the parent board may narrow hard layer and via constraints. Nets with two or
more terminals inside the sub-circuit route their local island even when the
same parent net continues elsewhere. The resulting parent-indexed copper is
validated against the assembled placement and then fixed as same-net source
copper for the single global pass.

- a sub-circuit routing view keeps every board component as an obstacle, exposes only its own net terminals, and uses local bounds
- an unselected scoped net is never routed by a sub-circuit phase
- a local sub-circuit uses the child plan's authored effort and the same completion gate as the standalone module Route button before its copper is offered to the assembled-board gate
- a module-only retry drops an impossible parent-only route constraint, follows standalone surface and pad-neck geometry, then must pass the parent's via budget and full-board DRC
- local signal routing treats the same module's exact supply bonds as immutable physical obstacles
- completeness-waiver: empty inputs (a block with no sub-circuits or no net with two local terminals returns empty copper and the caller takes the plain global path)
- completeness-waiver: large inputs (sub-circuits route serially on component-local lattices; all allocations share the caller's request arena and the global quality comparison is bounded to the two existing candidates)
- completeness-waiver: unauthorized access (an in-process routing phase over an already-authorized design and placement, with no file, request, or mutation surface)
- completeness-waiver: i/o failure (no I/O; module snapshot fallback remains in the caller and this phase only transforms typed in-memory placement data)
- completeness-waiver: concurrent access (all state is request-local except the router's existing synchronous timing/cancel hooks, which are already per-run)
- completeness-waiver: malformed encoding (the evaluator and placement builder have already resolved hierarchy paths and typed geometry before this module runs)
- completeness-waiver: integer overflow (part/net membership walks bounded slices; router grid sizing retains its existing checked node budget)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/router-via-rules

Public functions: edgeInset, pointInset, clearsOutline, buildOutlineMask, netOffboard, pairCenterNeed, clears, pathClears

- same-net via copper spacing overrides the drill-wall-only placement that produced TXDATA's doubled vias
- exact off-grid via clearance measures the via radius against the physical outline
- completeness-waiver: empty inputs (an absent outline accepts points and an empty via slice clears; both are explicit early-out/loop identities)
- completeness-waiver: large inputs (the outline mask is one boolean per route-grid node and via slices are bounded by routed copper)
- completeness-waiver: unauthorized access (pure geometry over caller-owned values; there is no I/O or authorization surface)
- completeness-waiver: i/o failure (no I/O)
- completeness-waiver: concurrent access (all inputs are immutable and no shared state is written)
- completeness-waiver: malformed encoding (design-rule parsing validates the numbers before this module receives them)
- completeness-waiver: integer overflow (grid dimensions are bounded by the router before mask allocation)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot)

## bench-route

Public functions: geomeanCompletion, benchOne, corpus, writeTable, writeJson, cmdBenchRoute

The whole-corpus routing benchmark that makes "the router got better" checkable.
Every router change so far was judged on ONE board, and at least two changes that
looked reasonable were net-negative on the same board they were designed against
(`docs/autorouter-plan.md` §4). `netlisp bench-route --project-dir <dir>
[--route-space lattice|field] [--json] [<design> ...]` routes every design at
its starred placement through the shared
`route_plan` seam — so `routed`/`total` are the connectivity oracle's answer, not
the router's claim — and prints a per-board table (routed, DRC by severity,
tracks, vias, copper mm, wall clock) plus the geometric mean of per-board
completion. Under `--json` each board row additionally NAMES its still-open nets
(`"open": [...]`, sorted) from the same oracle tally the counts come from, so two
runs diff net by net instead of only by a count. Read-only: no layout sidecar is
written, so it is safe against a served project dir.

`--baseline <file>` (added with the round-two audit, `docs/autorouter-audit-round-two.md` §3a)
is the durable regression gate: it compares each scorable board against a
committed `--json` baseline and exits non-zero when any board loses more than
one net, or when the geomean over the shared board set drops. Record a baseline
with `netlisp bench-route --project-dir <dir> --json > baseline.json` and gate
CI on `netlisp bench-route --project-dir <dir> --baseline baseline.json`, so
"the router got better" is a checkable, non-regressing claim rather than a
one-board anecdote.

- a board's completion fraction is its routed share of routable nets, and a board with nothing to route counts complete
- the corpus score is the geometric mean of per-board completion, so one collapsed board cannot be averaged away by easy ones
- a board that failed to load or route is reported, not silently dropped from the corpus score
- a board with no saved layout is reported but kept out of the corpus score, since its fallback placement is neither blessed nor stable
- the corpus results serialise to JSON so a driver can record them in the benchmark ledger
- the JSON per-board row names the oracle's still-open nets, sorted, so a completion change reads net by net
- trace totals separate completed-net copper from partial copper left by open nets, and JSON reports per-net trace/via totals so runs with unlike completion can be compared on common nets
- --route-space field selects the signed-margin path director while lattice remains the default
- degree-two direction changes are bends and a short segment trapped between two bends is a micro-jog
- collinear track runs do not count as bends
- a bend with a core-DRC-clear shortcut is reported as removable
- the --baseline gate passes a run identical to its committed baseline
- the --baseline gate fails a scorable board that loses more than one net, even when every other number is healthy
- the --baseline gate tolerates a one-net loss but still fails a geomean drop over the shared board set
- the --baseline gate reports a newly-scored board as unlined rather than silently passing on it
- the --baseline gate ratchets dangling-copper, implicit-junction, and hairline-gap counts per board so none may rise
- completeness-waiver: empty inputs (an empty corpus scores 0 and a zero-net board counts complete; both are unit-tested)
- completeness-waiver: large inputs (each board routes in its own arena, freed before the next; corpus size bounds memory to one board at a time)
- completeness-waiver: unauthorized access (a local CLI over a project directory the invoking user already owns; there is no network or auth surface)
- completeness-waiver: i/o failure (a design that fails to load or route is reported as an ok=false row rather than aborting the corpus)
- completeness-waiver: concurrent access (read-only — no sidecar or project file is written, so a concurrent server is unaffected)
- completeness-waiver: malformed encoding (design parsing and its diagnostics belong to the evaluator; a file that fails to evaluate becomes a FAILED row)
- completeness-waiver: integer overflow (counts come from routed slices; the score arithmetic widens to f64 before any accumulation)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## drc-dump

Public functions: cmdDrcDump, mutate

The board's WHOLE violation multiset, printed. `netlisp drc-dump
[--project-dir <dir>] [--mutate <k>] [--prime] <design> …` evaluates a design,
restores its saved layout exactly as the PCB page does, and writes every field
of every violation from both DRC seams — the geometry-only pass
(`drc_rules.checkGeometry`) and the full composed report
(`drc_rules.checkFilteredZones`, fill-aware topology plus `net_open`
connectivity plus the design's severity sidecar) — sorted, one per line, with
each seam's wall time and the copper-fill memo's reuse tally on `#` comment
lines that `diff -I '^#'` ignores.

It exists because nothing else produces one: `netlisp check` is schematic ERC,
`bench-page` reports three aggregate DRC counts, and `describe_pcb_layout`
summarises. Aggregate counts cannot tell "the same NUMBER of findings" from
"the same findings", which is the only claim a pure DRC speedup makes — three
consecutive DRC refactors each had to add a throwaway dump command, build two
binaries with it, diff the corpus, and strip the patch again.

A board that fails to solve marks the run UNRESOLVED and the command FAILS
(`error.UnresolvedBoard`), and `# SWEEP RESULT boards=` counts only boards that
actually ran — a soak can never read a vacuous "0 discrepancies over 0 boards"
as green (that exact vacuous pass happened once, from a wrong `--project-dir`).

`--mutate <k>` applies one deterministic copper edit IN MEMORY (move / delete /
add a track, move a distant track, delete / move a via) and `--prime` runs a
discarded DRC pass over the unmutated board first, so `--mutate k --prime`
versus `--mutate k` in a fresh process is a direct test that a memo's borrowed
fills are bit-identical to poured ones. The command is read-only: it writes no
file and starts no server.

`--scoped` is the same idea one level up. It primes a full check, walks a
SEQUENCE of edits through the incremental seam the editor's server reconcile
uses, and after every step also runs a cold full check of the identical state in
the same process, labelling the two `scoped` and `full` so one `diff` is the
whole claim. The three kinds a scoped pass defers
(`reference_plane_gap`, `reference_transition`, `loop_area`) are excluded from
that diff and checked separately against the priming pass's answer for them,
because carrying them forward is the decision under test rather than a
discrepancy.

- the CLI parses the project dir, the mutation selector, the priming flag and the scoped-seam benchmark repetition count with positionals as design names
- every violation renders one line carrying every field, including the track identity automatic cleanup reads, and the lines sort deterministically
- each mutation edits copper in memory only, leaving the board it was given untouched
- a board that fails to solve marks the run UNRESOLVED and the command fails, so a soak can never read a vacuous pass as green
- completeness-waiver: empty inputs (a dump with no design named is a usage error rather than an empty dump that would trivially match any comparison; a board that does not resolve prints one marked comment line, and the run fails after every board has had its chance)
- completeness-waiver: large inputs (each board runs in its own arena, freed before the next, so a corpus dump peaks at one board's DRC)
- completeness-waiver: unauthorized access (a local read-only CLI over the caller's own project directory; no network, no auth surface, and no file is written)
- completeness-waiver: concurrent access (single-threaded, and the process-wide fill memo it reads through is itself mutex-guarded and refcounted)
- completeness-waiver: i/o failure (a design that cannot be evaluated or whose layout cannot be restored prints an UNRESOLVED comment for that board; the remaining boards still dump, then the command fails with error.UnresolvedBoard)
- completeness-waiver: malformed encoding (the design and its saved layout are parsed by the same seam the PCB page uses, which rejects malformed input long before a violation exists to print)
- completeness-waiver: integer overflow (no arithmetic on the dump path beyond formatting already-computed violation fields)
- completeness-waiver: panic-free (every failing stage degrades to a comment line and the next board; a DRC seam that errors contributes an empty list rather than aborting the dump)

## gerber-dump

Public functions: cmdGerberDump

The Gerber half of the differential tier, and the answer to a class of bug no
other gate here can see. Three defects found by the 2026-08-29 audit changed
EMITTED BYTES while every count stayed identical: an arc's sweep direction taken
from quantized coordinates rather than the model (a sliver emitting as a
near-full turn of spurious copper), a bare pad token the SI tokenizer re-read as
a number, and a hole matched to two adjacent drill tools. Unit tests did not
cover them, and the DRC gate counts findings rather than reading artwork.

It drives the real writers — the same `fabViewFor` selector the fabrication
endpoints use, then `planLayers`/`writeLayer`/`writeJobFile`/`excellonDrill` in
the package's own order and under its own entry names — so the bytes compared
are the bytes that ship. It is NOT a release path: no archive, no revision lock,
no readiness evidence, nothing a fab could be handed; it answers only "what does
the writer produce". Determinism comes from passing no clock stamp, so the
`%TF.CreationDate` a released package carries is simply absent.

Read a diff with one thing in mind: the fabrication identity is stamped into the
silk, so ANY artwork change also moves the `fab-id` line and both silk layers.
That coupling is the canary that the board changed at all — but it means the
layer worth reading first is the one that is not silk.

- the CLI parses the project dir, the saved-layout selector and the digest-only flag with positionals as design names
- two dumps of one board are byte-identical, and the creation-date stamp a released package carries is absent from the compared output
- every line of the dumped artwork is compared while the command's per-run numbers stay on #-prefixed lines, and --digest keeps every member banner while dropping the bodies
- a board that fails to resolve marks the run UNRESOLVED and the command fails, so a corpus differential can never read a vacuous pass as green

- completeness-waiver: empty inputs (a dump naming no design is a usage error rather than an empty dump that would trivially match any comparison; a board that does not resolve prints one marked comment line and fails the run)
- completeness-waiver: large inputs (each board runs in its own arena, freed before the next, so a corpus dump peaks at one board's artwork; `--digest` drops the bodies when the bytes themselves are not wanted)
- completeness-waiver: unauthorized access (a local read-only CLI over the caller's own project directory; no network, no auth surface, and no file is written)
- completeness-waiver: concurrent access (single-threaded, and the process-wide fill memo it reads through is itself mutex-guarded and refcounted)
- completeness-waiver: i/o failure (a design that cannot be evaluated or whose layout cannot be restored prints an UNRESOLVED comment for that board; the remaining boards still dump, then the command fails)
- completeness-waiver: malformed encoding (the design and its saved layout are parsed by the same seam the PCB page uses, which rejects malformed input long before any artwork exists to write)
- completeness-waiver: integer overflow (no arithmetic on the dump path beyond the writers' own already-audited coordinate quantization)
- completeness-waiver: panic-free (every failing stage degrades to a comment line and the next board rather than aborting the dump)

## netlist-dump

Public functions: cmdNetlistDump

The connectivity half of the differential tier. A pad that silently leaves a net
is invisible to every count-based gate — the audit's pad-quoting bug did exactly
that, because a pad whose bare token re-read as a float returned null from the
reader and dropped out of the netlist while its copper stayed on the board. One
sorted line per net, each carrying its sorted `refdes.pad` members, turns that
into a one-line diff. It reuses `flat_netlist.flattenAndMergeNets` over a block
from the read-only resolve path rather than walking the hierarchy again.

- the CLI parses the project dir with positionals as design names and refuses a run that names no design
- every net renders one compared line carrying its sorted refdes.pad members, nets sort by name, the same netlist dumps byte-identically twice, and a reordering of either is not a difference
- a design that fails to resolve marks the run UNRESOLVED and the command fails, producing no compared line at all rather than a vacuous match

- completeness-waiver: empty inputs (a run naming no design is a usage error; a design with no nets renders no compared line and is reported rather than passing as a trivial match)
- completeness-waiver: large inputs (one arena per design, freed before the next, so a corpus dump peaks at one design's flattened netlist)
- completeness-waiver: unauthorized access (a local read-only CLI over the caller's own project directory; no network, no auth surface, and no file is written)
- completeness-waiver: concurrent access (single-threaded, sharing no state between designs)
- completeness-waiver: i/o failure (a design that cannot be resolved prints an UNRESOLVED comment and the command fails after every design has had its chance)
- completeness-waiver: malformed encoding (the design is parsed by the same evaluator seam the PCB page uses, which rejects malformed input before a net exists to print)
- completeness-waiver: integer overflow (no arithmetic beyond formatting already-computed net and pad counts)
- completeness-waiver: panic-free (a design that fails to resolve degrades to a comment line and the next design)

## power-flow

Public functions: cmdPowerFlow, Args, FlowError

Why each power rail's current solve reached the verdict it did. The DRC prints
`power_width_envelope … incomplete-load-terminals` and stops, which names the
verdict and hides the evidence: WHICH consumer of the rail failed to resolve,
and whether it failed because none of its pins are on this net, because its pad
was not found, or because the copper it sits on never reaches the source.
`netlisp power-flow [--project-dir <d>] [--layout <name>] [--net <name>]
[--text] <design>` prints, per rail, the two axis statuses, the declared
demand, every source terminal with its resolved pad count, every load with its
contacts / pin completeness / per-axis placement, the unplaced amperes, and
then each track and barrel whose required capacity exceeds what is there,
carrying the envelope flag and the reason. It is read-only, writes no file, and
reads the same two entry points the DRC and the PCB page read, so a rail it
calls solved is a rail the board's own screens call solved.

- the CLI parses the project dir, the saved layout, the rail filter and the text-output flag with one positional design name
- the rail filter matches a rail by its exact name or by its hierarchical leaf, and never by a bare substring
- a board that fails to solve reports UNRESOLVED and fails the command rather than printing an empty report
- an unresolved load is annotated with which of the three resolution failures it hit

- completeness-waiver: empty inputs (a run naming no design is a usage error; a board with no power rails prints an empty rail list under the board's own track and via counts rather than failing silently)
- completeness-waiver: large inputs (one arena for the whole run, freed at the end, so the peak is one board's solved placement)
- completeness-waiver: unauthorized access (a local read-only CLI over the caller's own project directory; no network, no auth surface, and no file is written)
- completeness-waiver: concurrent access (single-threaded over one board, sharing no state)
- completeness-waiver: i/o failure (a design that cannot be evaluated or whose layout cannot be restored prints an UNRESOLVED comment and the command fails)
- completeness-waiver: malformed encoding (the design and its saved layout are parsed by the same seam the PCB page uses, which rejects malformed input long before a rail exists to report)
- completeness-waiver: integer overflow (no arithmetic beyond formatting already-computed currents, widths and contact counts)
- completeness-waiver: panic-free (every failing stage degrades to a comment line and a non-zero exit rather than aborting mid-report)

## rewrite-pins-by-name

Public functions: tool

The corpus writes pin pads by number 2699 times against 291 by name, then
repeats the pinout in a trailing comment — `(pin 5 "GND") ;; ILIM` beside
`(strap-ok 5 "ILIM->GND …")`. The language already resolves a function name
through the part's pinout, so writing the name makes the strap and no-connect
sign-offs self-documenting and turns a pad renumber into a resolvable name
rather than a silent re-point. The rewrite is spliced at AST byte spans (the
`id_insert` discipline) so nothing outside the replaced token moves, and it is
gated twice: per token by re-running the evaluator's own resolver on the
proposed spelling, and per file by flattening both sources and demanding the
identical netlist and the identical resolved bindings.

- the rewrite splices at AST spans, so every comment and blank line survives byte for byte, the line count is unchanged, and multi-pad shorthand rewrites each pad independently
- a function name repeated on several pads is skipped with its reason, and a connector whose pinout names every contact after its own number is left entirely alone
- strap-ok, nc-ok and a near form's own pad resolve through the declaring part's pinout while near and decouples resolve their target pad through the named part's
- the rewritten source is accepted only when it evaluates and its flattened netlist and resolved bindings match the original line for line, so a rewrite that moved a pad is refused
- the default run writes nothing and returns the unified diff, and write true replaces the file atomically with the proven bytes
- the tool is registered as a mutation and its declared schema round-trips through netlisp tool list

- completeness-waiver: empty inputs (a missing `file`, a file outside lib/modules and src/, and a file with nothing to rewrite each answer with a named result instead of a write)
- completeness-waiver: large inputs (the source is read under the same 10 MiB library cap the evaluator uses, and the reported skip list is capped with the remainder counted)
- completeness-waiver: unauthorized access (a local CLI over the caller's own project directory; the path is confined to lib/modules and src/, traversal and absolute paths are refused, and the write is registered as a mutation like every other design edit)
- completeness-waiver: i/o failure (an unreadable source is refused before anything is planned, and the write is a tmp-then-rename atomic replace so a crash cannot truncate the design)
- completeness-waiver: concurrent access (single-threaded; the plan is computed and proven against bytes already read, and each evaluation owns its own evaluator and arena)
- completeness-waiver: malformed encoding (a source that does not parse or does not evaluate is refused, and a function name the tokenizer would read back as anything else is never spliced)
- completeness-waiver: integer overflow (byte offsets come from the parser's own spans and are bounds-checked against the source before any splice; no input-derived arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## bench-page

Public functions: benchOne, corpus, writeTable, writeResultsJson, cmdBenchPage

The primary-page latency benchmark that makes "a page got slower" a checkable
claim before it reaches main. Page-load and DRC-update latency regressed
repeatedly because nothing measured them. `netlisp bench-page
[--project-dir <dir>] [--reps <n>] [--json] [--baseline <file>] [<design> …]`
times the production seams per board — design evaluation, `.layouts.json`
read+parse, `solveForRequest` (verbatim ★ restore + copper restore), the
reporting DRC (`drc_rules.checkFilteredZones`, `net_open` included), the
geometry-only `drc.check` (native twin of the client WASM engine), and the
complete cold PCB page render through the boot warm-up's page-scoped seam
(`pcb_derived.warmPage(…, .page)`) on a fresh cache, which stops where the
reader's first paint does and leaves the `?derived=1` analyses out. It also
times cold default renders of `/assembly-debug/:name` (parent workspace only;
the iframe is the separately measured PCB page), `/thermal/:name`, and
`/schematics/:name`, and prints per-board phase medians plus the DRC counts,
rendered PCB-page size, and whether that render was admitted to the page cache.
The corpus is every design with a saved-layout sidecar (the boot warm-up's own guard), so nothing is
solved-and-persisted for a board nobody laid out.

`--baseline <file>` is the durable regression gate the tracked `pre-push` hook
runs for main (via `scripts/perf_gate.sh`, behind `scripts/gate.sh`'s
machine-wide lock): it compares each board's phase medians against a committed
`--json` recording and exits non-zero on a per-board allowance breach
(`max(base×1.30, base+25 ms)`), a corpus-wide geomean drift past 1.10, a
hand-set absolute budget in the baseline's `budgets` object, moved DRC counts
(unlike work is not comparable), or lost page-cache retention. Full workflow:
`docs/benchmarks/pcb-page/README.md`.

The gate lock serializes only jobs that take it, so the bench also reads
`/proc/loadavg`'s 1-minute average around every board and labels the run —
and each board measured beside the excess — as CONTENDED in the table and the
JSON when a sample exceeds the quiet-machine model (`1 + (start − 1)·e^(−t/60)`
— the bench's own busy core plus the decay of whatever ran before it) by more
than 2 runnable tasks. The label never flips the gate verdict; it exists so
`scripts/perf_gate.sh --record` can refuse to install a contended recording
and so a contended FAIL reads as "re-run quiet first". Where `/proc/loadavg`
does not exist, no load facts are reported and no label is invented.

- the CLI parses project dir, reps, output and baseline flags with positionals as design names
- phase medians are the outlier-tolerant middle of the rep samples
- the JSON recording round-trips through the baseline loader with every phase and invariant intact
- the --baseline gate passes a run identical to its committed baseline
- a phase past both the ratio and absolute allowance fails the gate and names the board, phase, and limit
- millisecond-scale jitter under the absolute floor never fails the ratio rule
- corpus-wide drift fails the gate even when every board stays inside its own allowance
- a hand-set absolute budget in the baseline file caps every board regardless of the recorded medians
- a board without a blessed layout skips layout-dependent PCB/thermal phases but still gates its stable assembly and schematic renders
- moved DRC counts mean unlike work, which fails the gate with a re-record hint instead of comparing wall times
- losing page-cache retention fails the gate even when every timing column improved
- new and vanished boards are noted rather than silently passing or failing the gate
- a missing or corrupt baseline is a gate failure, never a pass
- a failed board renders as FAILED in the table and carries ok=false in JSON
- a page render the cache refused is flagged in the table so a silent every-load-cold regression is visible
- the page-cache retention probe asks under the same entry and live version the page warm admitted, so a cached page is never reported as NOT retained
- the load tripwire parses the leading 1-minute loadavg figure and refuses malformed content
- the load model forgives a high start decaying after a gated build and the bench's own busy core
- load that persists or arrives mid-run exceeds the decay model and labels the run contended
- a contended run is labelled in the table and JSON so it cannot be recorded as a clean baseline silently
- completeness-waiver: empty inputs (an empty corpus prints an empty table; a zero-baseline phase is ratio-floored so it cannot divide by zero)
- completeness-waiver: large inputs (each rep runs in its own arena, freed before the next; the corpus peaks at one rep's render)
- completeness-waiver: unauthorized access (a local CLI over a project directory the invoking user already owns; no network or auth surface)
- completeness-waiver: i/o failure (a design that fails to load or solve is an ok=false FAILED row rather than aborting the corpus; an unreadable baseline fails the gate, never passes it)
- completeness-waiver: concurrent access (renders through the same warm-up seam the server boot uses, against this process's own fresh cache; sidecar writes are the render path's own, identical to boot warm-up)
- completeness-waiver: malformed encoding (a sidecar that fails to parse is logged and still timed — the parse work it measured is real; design-parse diagnostics belong to the evaluator)
- completeness-waiver: integer overflow (all timing arithmetic widens to f64; counts come from slice lengths)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/route-timing

Public functions: PhaseTimer (begin, end, beginNet, endNet, noteAttempt, elapsed, total, label)

Per-phase wall-clock instrumentation for the autorouter pipeline, armed by the
whole-corpus benchmark (`netlisp bench-route --breakdown`) through
`route_policy.Options.timing` (default null, one null-check per site on
production paths). Phases mirror the pipeline: build_ctx, plane_vias, greedy,
maze, gateways, direct, smooth, escalate, ripup, last_resort, fine_rescue,
escape_stubs, stitch_return, straighten, cleanup, finish_total, gate. The same
timer carries whole-run counters (maze expansions and legs, direct via-checks,
dogleg probes) and the 8 slowest per-net greedy attempts, so a speed change is
judged on phase numbers and the nets that own them, not just total wall time.

- begin/end accumulates per-phase elapsed time, and total covers every slot
- noteAttempt counts each whole pipeline attempt
- completeness-waiver: empty inputs (a timer with no begin/end pairs measures 0 in every slot; both unit-tested)
- completeness-waiver: large inputs (the timer is a fixed 10-slot accumulator plus an 8-slot slow-net list — constant memory regardless of board size)
- completeness-waiver: unauthorized access (instrumentation is opt-in via a pointer only the benchmark supplies; there is no network or auth surface)
- completeness-waiver: i/o failure (the timer only reads a wall clock; allocation failures cannot originate here)
- completeness-waiver: concurrent access (a timer is owned by one routing run on one thread; concurrent runs each carry their own)
- completeness-waiver: malformed encoding (no input is parsed; phase names are a compile-time enum)
- completeness-waiver: integer overflow (elapsed deltas are non-negative; the total uses saturating += so an over-long run cannot wrap)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/route-resolution

Public functions: declaredPitch

`(net-class "…" (resolution MM) …)` — the raster pitch a net's bounded rescue
windows use. The maze must place a centerline on a lattice, so a net whose only
legal path clears its obstacles by less than the grid pitch cannot be routed at
ANY ordering, priority or waypoint: barracuda's `SPI_SCK` has a legal detour
clearing by 0.07-0.20 mm that the ~0.11 mm raster provably cannot represent,
which is why every DSL remedy failed on it while a hand route and an offline
0.05 mm search both found it immediately. A declared pitch is tried as the FIRST
window tier, ahead of the adaptive half/quarter tiers, and only the nets that
declare one pay for it. Because it is an explicit author instruction rather than
a router gamble, it is honoured even under `(effort one-shot)` and without the
grid-quantization classifier having to agree.

A board-spanning net's WHOLE-NET window at a fine declared pitch is far past the
automatic cell cap (barracuda's `SPI_SCK`: 283,094 cells at 0.05 mm), so holding
the declared tier to that cap made the form inert on exactly the net it was
written for. It is admitted at its own, larger cap instead — but only together
with a connectivity ACCEPT GATE, because raising the cap alone was measured
net-negative (83/90 -> 81/90 while the router's own claim rose to 87): a
board-scale detour can island the plane another net was riding, which the
per-window DRC check cannot see. An over-cap window's result is therefore
weighed by the one connectivity oracle before and after, and kept only when the
board strictly improves; anything else rolls back byte for byte. The allowance
is for one window per net (a leg keeps the automatic cap), the search inside it
is one full sweep of its own lattice, and the gate spends a bounded number of
oracle evaluations per route.

- a net class may declare the raster pitch its rescue windows use, tried ahead of the adaptive tiers
- a net that declares no resolution keeps the adaptive half- and quarter-pitch tiers exactly
- a declared resolution is honoured under one-shot effort, since it is the author's instruction rather than a router retry
- a whole-net window at a declared resolution may exceed the automatic cell cap, and is flagged over-cap so the router gates and budgets it
- a declared-resolution rescue window is accepted only when the connectivity oracle says the whole board strictly improved
- an arbitrary joint-rescue copper replacement is accepted only when the connectivity oracle connects more nets and disconnects none
- a declared-resolution rescue window whose copper closes its own net but islands the plane another net rides is refused, and the gate leaves the copper it judged untouched
- a declared-resolution rescue window that closes its net without costing another is kept
- the accept gate spends a bounded number of oracle evaluations per route and refuses, rather than admits, an attempt arriving past that ceiling
- the connectivity accept gate can judge ONE net's island merge, so a hop that joins two islands without yet closing the net is a measurable gain
- the accept gate weighs a board's swept RF paths and native arcs too, so copper duplicating a net an RF taper already joins buys nothing
- a net whose only legal corridor lands on no raster the rescue builds by itself routes once its class declares that raster, and stays unrouted without the declaration
- completeness-waiver: empty inputs (a board with no declared resolution takes the unchanged adaptive path, unit-tested)
- completeness-waiver: large inputs (a declared window is budgeted by the same cell cap as every other tier, so a huge net yields no window rather than a huge search)
- completeness-waiver: unauthorized access (a parse-time design property; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the pitch is read from already-parsed design rules)
- completeness-waiver: concurrent access (read-only per-net rule data; no shared mutable state)
- completeness-waiver: malformed encoding (a non-positive pitch warns at parse time and leaves the default)
- completeness-waiver: integer overflow (millimetre floats; the cell count is bounded by the same budget as the adaptive tiers)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/class-pitch

Public functions: selectedCount, maxRouteParams, narrowestPitch, routeGridDims,
effectiveGridScale, fittedGridScale, selectedDiffPairGap

Which net class sizes the whole-board routing lattice. Historically exactly one
pitch served a board and it came from the WIDEST class, so barracuda's 0.127 mm
control nets raster at its 0.3124 mm RF class's 0.4394 mm pitch — 1.73x coarser
than they need, on a board where most nets are control nets. The pitch does not
carry the clearance guarantee by itself: every net already routes with its OWN
width and clearance for obstacle halos, copper stamping and the DRC probes
(`setNetParams` / `stampBoardCopper`), so the lattice is purely a centerline
quantization and a FINER pitch is strictly more expressive, never less legal.

`Mode.narrowest` therefore rasters the board at the finest pitch any of its own
nets needs instead of the coarsest. It is bounded on both sides: never coarser
than the `widest` lattice it replaces, and never finer than the per-signal-layer
node budget affords — a board whose finest class would overflow keeps the
finest lattice that fits (found by a fixed-step bisection, so two identical runs
answer identically), and a board already too large for its widest lattice is not
refined into a deeper overflow. On a board whose nets all resolve to one pitch —
which is every corpus design with no `(net-class …)` geometry — the two modes
compute the same number, so the same lattice, so byte-identical copper.

The mode is a BOARD rule (`BoardRules.lattice`), not a per-net or per-request
one, because it decides one raster for one route; every lattice-sizing call site
already holds the placement those rules ride on, so nothing new is threaded. It
defaults to `widest`, the historical raster.

A finer raster is not a free routability win, which is why it is opt-in: the
per-leg expansion budget is a COUNT, so the same budget sweeps a smaller
physical radius on a finer lattice (halving the pitch quarters the reachable
area).

- a board whose nets all resolve to one pitch rasters identically under either lattice mode
- the narrowest mode rasters a mixed-class board at the finest class's own pitch, not the widest
- a wide current-rated power class keeps the ordinary centreline lattice because its electrical width is added after routing
- the narrowest lattice is never coarser than the widest-class lattice it replaces
- a finer class pitch that would overflow the node budget falls back to the finest lattice that fits, never to an overflow
- a board that cannot afford even its widest-class lattice keeps that lattice rather than being refined into a deeper overflow
- the finest-affordable pitch search is deterministic across identical calls
- the narrowest pitch of a board with no net classes is the board default geometry
- a net class narrower than the board default lowers the board's narrowest pitch
- a selection mask confines the narrowest-pitch scan to the enabled nets
- a board with no net classes lays byte-identical copper under either lattice mode
- a fine-class net whose only corridor is narrower than the widest class's pitch routes on the narrowest lattice and fails on the widest
- routing a board twice on the narrowest lattice is byte-identical
- completeness-waiver: empty inputs (a board with no net classes resolves both modes to the board default geometry, unit-tested)
- completeness-waiver: large inputs (a board too large for any affordable raster keeps its widest-class lattice and the existing overflow report, unit-tested)
- completeness-waiver: unauthorized access (a board rule read from an already-parsed placement; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the pitch is computed from already-parsed design rules)
- completeness-waiver: concurrent access (pure functions over read-only rule data; no shared mutable state)
- completeness-waiver: malformed encoding (a zero-valued class geometry falls back to the board default rather than to a zero pitch)
- completeness-waiver: integer overflow (millimetre floats; node counts go through numeric.toCount and are compared against the same budget the allocation uses)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/route-effort

Public functions: retries

How hard one route tries before it reports a net failed, authored as
`(pcb-plan (route (effort one-shot|standard) …))`. The retry machinery — the
escalate/rip-up interleave, the last-resort expansion tier, the windowed fine
rescue — does not earn its cost on a board someone is iterating on: measured on
barracuda, universal rip-up eligibility bought zero nets and the multi-net rip
tier was net-negative, while failed hops spend seconds to minutes proving a path
impossible. `one_shot` makes a net the maze cannot route fail immediately with
its diagnosis, so an agent reading `stuck[]` gets its next DSL edit in seconds.
`standard` (the default, and what every design without the form gets) keeps the
historical behaviour.

- a tier name becomes a tier through one shared spelling that takes the enum and DSL forms and rejects anything else
- an authored (effort one-shot) route skips the escalate, rip-up and fine-rescue machinery entirely
- a one-shot route lets the post-route oracle gate finish the nets the router gave up on, since no rescue ladder runs behind it
- a design with no authored effort routes exactly as it did before the form existed
- (effort ...) under (place ...) or with an unknown word warns and leaves the default in place
- completeness-waiver: empty inputs (an absent form is the documented default and is unit-tested)
- completeness-waiver: large inputs (the knob is a two-valued enum consulted per pass, independent of board size)
- completeness-waiver: unauthorized access (a parse-time design property; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the form is parsed from an already-read design file)
- completeness-waiver: concurrent access (the value is copied into the run's context; no shared mutable state)
- completeness-waiver: malformed encoding (an unrecognised word warns and falls back to the default, unit-tested)
- completeness-waiver: integer overflow (no arithmetic — the value is an enum)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/route-deadline

Public functions: Stop

An authored `(pcb-plan (route (max-route-seconds N) …))` gives one complete
route transaction a cooperative wall-clock budget. The relative duration is
armed once into an absolute deadline and copied through sub-circuit candidate
comparisons, topology planning, retries, and the post-route connectivity gate,
so no inner pass silently resets the allowance. The router polls at net/round boundaries and
inside its two expensive unbounded-looking loops: every 1024 direct-clearance
probes and every 1024 maze expansions. Expiry returns a valid partial result
with `cancelled=true`; it never persists as a completed automatic route.

- max-route-seconds parses only in the route section and rejects non-positive or fractional budgets
- an expired route deadline stops before the first net and returns a valid cancelled partial board
- an expired route deadline keeps the additive connectivity gate from starting new hops
- a route deadline reached during an additive gap hop stops that hop's maze rather than waiting for its expansion ceiling
- a route deadline that expires while a gate hop is routing drops that hop's copper instead of committing it
- topology planning consumes the same route deadline as detailed routing rather than starting an untimed pre-pass
- completeness-waiver: empty inputs (an absent form lowers to zero and preserves the historical clock-free behavior)
- completeness-waiver: large inputs (the deadline is independent of board size and is polled inside the two measured hot loops)
- completeness-waiver: unauthorized access (a parse-time design property; route authorization stays at the serve boundary)
- completeness-waiver: i/o failure (the monotonic clock port is the only runtime dependency; expiry is a normal partial result)
- completeness-waiver: concurrent access (deadline and optional cancel flag are request-local values copied into each route context)
- completeness-waiver: malformed encoding (invalid, fractional, zero, negative, or over-one-day values warn and are ignored)
- completeness-waiver: integer overflow (the parser caps seconds at 86400 before milliseconds/nanoseconds conversion)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/guide-branch

Public functions: resolve

Bind an authored `(pcb-plan (route (wave … (branches …))))` guide TREE to one
net's router terminals. `route_policy.GuideBranch` is positional — branch `i`
connects terminal 0 to terminal `i + 1` — and that order falls out of netlist
flattening, which a design author cannot see. So an authored tree names its
drops the only way a human can, by where each limb's copper ends, and this
resolves that geometry into the positional contract: the root is the terminal
nearest where the limbs all start, each limb claims the terminal nearest where
it ends, and the claims must be distinct. A tree it cannot land is refused
whole, because a wrong root sends the entire tree across the board while a
refusal only leaves the net routing the way it did before the form existed.

- an authored branch tree binds each limb to the terminal nearest its last point and the root to the limbs' shared first point
- a branch tree whose limbs do not land on distinct terminals is refused whole rather than applied to the wrong drops
- a branch tree whose limb count cannot cover the net's terminals exactly once is refused so the ordinary multi-terminal router runs unchanged
- one branch on a two-terminal net lowers to the ordinary waypoint chain instead of a tree
- a limb ending on the tree's own root terminal refuses the tree rather than leaving a real drop unguided
- reading an authored tree is a pure extension, so a policy carrying none answers every hard-guide question exactly as it did before the form existed
- completeness-waiver: empty inputs (no authored limbs, a limb with no points, and fewer than two terminals each return a refusal, and are unit-tested)
- completeness-waiver: large inputs (an O(limbs · terminals) scan over one net's own terminals; a bigger board adds nets, never terminals to one net)
- completeness-waiver: unauthorized access (a pure in-memory function over caller-supplied geometry; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no disk, socket or syscall — every input arrives in the caller's slices)
- completeness-waiver: concurrent access (a stateless pure function over immutable inputs into caller-arena storage, so concurrent resolutions are independent)
- completeness-waiver: malformed encoding (inputs are typed Zig structs, not parsed bytes; the parser upstream already warned and skipped malformed limbs)
- completeness-waiver: integer overflow (the only arithmetic is f64 distance; the indices produced are bounded by the terminal slice length)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/escape-assign

Public functions: plan, guideTracks

Simultaneous multi-net escape assignment: parallel lanes for a set of nets that
all leave one hub through one corridor. The router routes nets sequentially, so
where several nets share a narrow escape the early ones take the middle of the
channel and the late ones are starved — and no reordering fixes it, because
whichever net goes first claims the same lane. This picks the whole set's lanes
JOINTLY: detect the shared hub and the direction its destinations lie in, cut a
cross-section across that direction at the tightest constriction that still
fits every net, slice its free intervals into track-pitch lanes, and map nets
onto lanes with an exact dynamic program over MONOTONE assignments (lane order
follows endpoint order, so no two assignments cross). The result lowers to SOFT
per-net guide tracks, so an unusable lane costs a net a detour, never the net.

Detection runs without the form: `detect` turns the same cut scan and joint
schedule on EVERY hub of a board and reports the sides whose escape fan the
corridor there cannot seat, steering nothing and emitting no guide, with
`suggestDsl` rendering each finding as the one-line `(assign-escapes …)` wave a
human would author to act on it. The split is a measurement, not caution: on
barracuda ANY steering of the eight J1 control escapes scores 81/91 against the
82/91 control, so an automatic assignment there spends a routed net to buy a
tidier picture. Where the contention is, the geometry can say unattended;
whether to steer it stays authored.

Free space along a cross-section is routinely BIMODAL, so each contiguous free
BAND is solved as its own capacity-limited sub-corridor over the nets whose
ideals land nearest it. A single monotone program over the flat lane list would
honour its ordering ACROSS the void between bands and drag a net millimetres
into free space it never wanted; within a band the ordering is real (the nets
share clear space), between bands it is not (an obstacle separates them). A net
whose lane would sit farther than the corridor's displacement cap from its own
ideal is REFUSED instead — it keeps no guide and routes exactly as it does with
no assignment authored, and the refusal is reported rather than silent.

- a contended net set resolves to one shared hub and the direction its destinations lie in
- a net set with no part in common assigns nothing and says so
- lanes are the free intervals of the corridor cross-section at track pitch, with every foreign courtyard removed
- the tightest cross-section that still fits every contended net is the one scheduled
- every contended net gets its own lane, in the order its endpoints already imply, so no two assignments cross
- a corridor with fewer lanes than nets leaves the worst-fitting nets unassigned instead of doubling one up
- a roomy corridor is thinned to a few more lanes than the contended set, so the assignment spreads instead of packing at minimum pitch
- each assignment lowers to one soft per-net lane guide that starts clear of the hub's own pads
- an empty or single-net request assigns nothing
- assigning the same board twice yields the identical corridor, lanes and assignment
- each contiguous free band of the cross-section is scheduled on its own, so no net is dragged across the void between bands
- the displacement cap is measured in the lane spacings one band offers, never across the gap between two bands
- a net whose ideal crossing is farther than the displacement cap from every band is refused rather than moved onto a lane it never wanted
- a refused net contributes no guide track, so it routes exactly as it does with no assignment authored
- a bimodal corridor's refusals and band assignments are identical on a second run
- no lane is offered outside the design's declared board outline, where no copper can go
- a net that reaches the corridor from no hub pad is reported as refused rather than dropped in silence
- every hub side whose escape fan the corridor cannot seat is found with no assignment form authored
- an escape fan the corridor seats in full is not reported as contended
- a fan every net of which an authored assignment already covers is not detected again
- a detected fan renders as a paste-ready assign-escapes wave naming its own nets, hub and layer
- a plane-carried net is never part of an escape fan, because it rejoins through the pour instead of taking a lane
- detecting the same board twice yields the identical fans in the identical order
- completeness-waiver: empty inputs (a request naming fewer than two nets, or nets with no shared hub, returns an empty plan with a reason — unit-tested)
- completeness-waiver: large inputs (the cut scan is a fixed 20-step sweep and the assignment is O(nets x lanes); a bigger board only lengthens the obstacle scan, which is one linear pass over parts)
- completeness-waiver: unauthorized access (a pure in-memory computation with no I/O or auth surface — access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk, socket, or syscall — placement geometry arrives as typed slices from the caller)
- completeness-waiver: concurrent access (a stateless pure function over immutable inputs into per-call arena-owned slices — concurrent assignments are independent)
- completeness-waiver: malformed encoding (inputs are typed Zig structs, not parsed bytes; an out-of-range net index or unknown pad name is skipped, never a hard error)
- completeness-waiver: integer overflow (lane counts go through numeric.toCount, which rejects non-finite and out-of-range floats; every other index is bounded by a slice length)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/reserved-lanes

Public functions: stamp, segmentBlocked, viaBlocked, radiusOf

The HARD half of `(assign-escapes …)`. The soft half hands the maze guide
tracks — a cost bonus biasing it toward the lane the joint assignment gave each
net, which a later net is free to ignore and route straight across. That is
what makes a guide safe (it can never fail a net) and also what makes an
assignment fail to survive contact with the nets routed after it. Authoring
`(reserve)` emits the SAME lane geometry a second time as a claim: the lane's
own net crosses it freely, every other net is refused it for the whole run.

The mechanism is `router.Ctx.resv`, which already means exactly this — `blocked`
refuses a cell purely on net-id mismatch, and Dijkstra never seeds from one, so
a reservation walls off strangers without becoming phantom copper its owner can
"connect" to. `resv` is policy-free state the router reallocates or clears at
six points in a run (the run's own grids, a fine window, a gap board, the gap
pass's finer raster, a rip-up, an immediate fine-guided retry), so the claim is
re-stamped at every one of them; missing one drops the reservation mid-route
with nothing to show for it. The maze is not the only thing that draws copper,
so the direct-synthesis segment and via oracles ask the same question in world
space (a direct run is off-grid by construction) — without that half the
reservation is skipped outright for any net a straight run can serve.

Two nets' lanes can land on one node when the assignment's lane pitch is finer
than the routing raster. Such a node is left FREE rather than given to the
first claimant, because locking a net out of its own assigned lane is the one
outcome a reservation must never produce; a raster too coarse to express the
plan therefore degrades to no effect instead of to a wrong effect, and the
result never depends on lane order.

- an authored reserved lane claims its own corridor cells for its owning net and leaves every other cell free
- stamping reserved lanes never overwrites a cell that already carries a reservation
- a cell two different nets' reserved lanes both cover is left free rather than locking one of them out of its own lane
- re-stamping the reserved lanes of one net restores exactly that net's claim, so a rip-up that clears its cells cannot drop the reservation
- a run that authors no reserved lane stamps nothing at all
- a reserved lane naming a layer the router does not model is skipped rather than mis-stamped
- an authored reserved lane holds its corridor for its owner against a net that routes earlier, which a soft guide cannot do
- a finishing hop is refused a lane reserved for another net, and the same hop lands when nothing is reserved
- a net routes through its OWN reserved lane freely, so a reservation costs its owner nothing
- completeness-waiver: empty inputs (an empty lane list early-outs before any grid is touched — unit-tested)
- completeness-waiver: large inputs (cost is lanes x lanes x nodes-per-lane, and a lane is a few millimetres of an escape corridor; the whole board is never scanned)
- completeness-waiver: unauthorized access (a pure in-memory stamp over caller-owned slices — access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk, socket, or syscall — lanes and grids arrive as typed slices)
- completeness-waiver: concurrent access (a pure function of its inputs writing only the caller's own per-run grids)
- completeness-waiver: malformed encoding (inputs are typed Zig structs, not parsed bytes; an out-of-range layer is skipped, never a hard error)
- completeness-waiver: integer overflow (the disc radius goes through numeric.checkedInt, which rejects non-finite and out-of-range floats; every index is bounded by the grid dims)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)


## Topology planner

Public functions: plan

Global topology planning: a per-wave, all-nets-of-the-wave-simultaneous flow
relaxation that decides WHICH corridor each net threads before the sequential
detailed router draws any copper. The router routes one net at a time, so a
board's global topology is an accident of net order — whoever routes first
takes the short path and the rest detour around its metal. Here every net of a
wave is relaxed together on a coarse lattice (Physarum conductance adaptation
under congestion pricing with a PathFinder history term), so a net pushed out
of a contended gap moves while it is still free to move. Waves earlier than the
one being planned are stamped in as consumed capacity; later waves enter as a
FROZEN background congestion field at a light weight, so ties break in favour of
leaving room without re-solving work the wave cannot emit — measured on
barracuda, per-frame relaxation of the not-yet-planned waves was 87–98% of every
frame and made one flagged wave cost as much as sixteen. Planning likewise stops
after the last guide-emitting wave, whose stamps no later wave reads. The result
lowers to SOFT `route_policy` guides, so a corridor that turns out to be
unusable costs a net a detour, never the net.

- two nets contending for two gaps are planned through different gaps
- a lone net is planned through the shorter of two unequal detours
- a net whose terminals no open corridor joins is refused a guide and told why
- a net restricted to one layer is planned on that layer with no guide vias
- a guided net that may change layer never receives tracks without vias
- planning the same board twice yields structurally identical guides and diagnoses
- a later wave is planned around the corridor an earlier wave's backbone consumed
- a diff-pair member or authored-guide net consumes capacity but is never given a guide
- only a topology-flagged wave's nets are given guides, while an unflagged wave is still planned for its capacity
- a plan with no topology-flagged wave never runs the planner and leaves the router's guides untouched
- a net an escape-lane guide already targets keeps that guide and is never given a planner corridor
- planning stops after the last guide-emitting wave, whose capacity stamps no later wave reads
- a backbone that must change layer does so exactly once each way, never flapping between layers
- a channel narrower than a net's own cross-section is not a corridor, however finely the lattice resolves it
- a channel at least a net's cross-section wide carries it
- a net no reference-pitch corridor joins is replanned on a finer lattice, and every diagnosis names the pitch it was planned on
- pinning the lattice pitch plans every wave on it and suppresses refinement
- a net a copper plane carries is never relaxed and is diagnosed as plane-carried
- completeness-waiver: empty inputs (no waves, or a wave whose nets have fewer than two distinct terminal cells, returns an empty plan and a no_terminals diagnosis — unit-tested)
- completeness-waiver: large inputs (the frame budget is fixed and the lattice is deliberately coarse at twice the router's pitch; a bigger board lengthens one linear pass per frame, it never changes the shape of the result)
- completeness-waiver: unauthorized access (a pure in-memory computation with no I/O or auth surface — access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk, socket, or syscall — placement geometry and net inputs arrive as typed slices from the caller)
- completeness-waiver: concurrent access (a stateless pure function over immutable inputs into per-call allocator-owned slices — concurrent plans are independent)
- completeness-waiver: malformed encoding (inputs are typed Zig structs, not parsed bytes; an out-of-range net index or unknown pad name is skipped, never a hard error)
- completeness-waiver: integer overflow (cell counts go through numeric.toCount, which rejects non-finite and out-of-range floats; every other index is bounded by a slice length)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/route-close

Public functions: reconcile

The post-route ORACLE GATE. A batch route counts a net routed when its own maze
reached each terminal, which is not the question "does this copper join the
net's pads" — on barracuda the whole-board route claimed 85/90 while the
connectivity oracle found 77/90, the difference being short joins the router
never emitted (a 0.98 mm divider tie, a 1.34 mm switch-node hop, a `GND` net
shipped as 34 islands). The router's in-house closer cannot see them because it
counts COPPER islands: a pad it never reached carries no copper and so is not an
island at all. This module asks `fab_readiness.routableTally` instead, closes
the island-joining hops the oracle names through `router.closeGaps`, re-tallies,
and reports the oracle's `routed`/`total`/`failed`. It is scoped to nets the
router itself claimed were routed (a genuinely failed net needs the finishing
pass's rip-up machinery, not a second route's wall clock) and it is strictly
additive — rip-up is off and a judge refuses any path that ripped copper — so it
can never make a board worse.

"Did it rip anything?" is the whole verdict for a two-pad BRIDGE, because a maze
that reached both pads produced a join and one that did not produced nothing. It
is not the verdict for a hop on a PLANE- or POUR-carried net: a stitch barrel is
"landed" whether or not the fill it drops into is the fill its island needed, and
such a rail closes one island at a time rather than all at once. Those hops are
therefore committed as independent TRANSACTIONS (`placement/island_accept`) —
each hop's copper built as a separate candidate, weighed by the connectivity
oracle plus the geometry DRC, and adopted only on a strict gain. Both the stitch
and the short surface join are requested per gap, because a pour is no rescue for
an island its fill never reaches: of barracuda's `V_3V3A` islands only two sit
over the In3 zone that carries the rail, and the rest are 1.0-10.2 mm pad-to-pad
hops. Committing those same hops unweighed measured 102 -> 98 connected nets.

- a fresh route's routed/total counters are the connectivity oracle's answer, not the router's own claim
- a pour-carried net's island-joining hop is committed only when the connectivity oracle credits it with a merged island or a closed net
- a pour-carried bridge keeps the short default ceiling even at the wide standard gate tier, so a long leg is left to the residual passes instead of a gate-time corridor maze
- an island-joining hop whose copper merges no island is refused, so a stitch that lands without reaching its net's metal is never committed
- an island-joining hop that had to rip foreign copper is never committed, so the post-route gate stays additive
- an island-joining hop that closes its own net by islanding a net the board already connected is refused
- a transactional island pass refuses, rather than admits, a hop arriving past its oracle-evaluation budget
- a hop on a plane- or pour-carried net is committed transactionally, while an ordinary bridge keeps the cheap additive rule
- a pour-carried net's islands are each requested as their own hop, so one leg too long for the gate never withdraws the short joins beside it
- a poured rail's redundant island hops are refused once the one that merged its islands is kept
- the post-route oracle gate closes the short island-joining hops a batch route left open and reports the net routed
- the post-route oracle gate never plans a hop longer than its ceiling, leaving genuine routing problems to the finishing pass
- a net with any over-ceiling gap consumes no bounded gate hops because its shorter joins cannot make the net complete
- the post-route oracle gate skips nets the router itself reported failed unless the caller opts in
- a reconciliation pass that keeps no copper reuses its first connectivity tally
- a scoped re-route's gate confines its hops to the scope while still reporting the whole board's tally
- a keepout or unassigned zone is skipped rather than named as a net's pour
- the post-route oracle gate is additive: it never drops copper the route already earned
- the post-route oracle gate stitches only the islands its plane or pour does not already carry
- the post-route oracle gate stitches every stranded island of a plane-carried net but its main body
- disconnected components of the same pour are joined by a surface bridge because another stitch would land back in the same component
- the post-route oracle gate spends its hop budget cheapest-net-first, so one net's islands cannot starve the rest
- a bounded gate attempts only whole net runs so its last budget slots never buy copper that cannot change a routed tally
- a hop an earlier gate pass of the same route already had refused is not planned again
- the gate ladder's last pass lets a long island-joining hop search a corridor proportional to its own span, so a stuck bridge gets room to detour only once no other plan can be blocked by it
- a net whose hops the gate has refused enough times in one route stops being planned, so a many-islanded treadmill cannot starve the nets behind it
- a hop whose gridless shape attempt one gate pass already refused is asked of the maze alone on every later pass, at either corridor width, so the same mesh is never rebuilt for the same answer
- a net the route's gate has answered terminally reads as sealed — the per-net refusal cutoff, or a hop whose gridless mesh found no channel — while a net it never planned reads as unanswered, and the shape tally is kept apart from the one that ends planning
- completeness-waiver: empty inputs (a board with no open nets short-circuits to the tally and is unit-tested; an empty placement yields an empty tally)
- completeness-waiver: large inputs (hop planning is bounded by the oracle's per-net island count and the `max_hop_mm` ceiling; the underlying maze carries its own node/expansion budgets)
- completeness-waiver: unauthorized access (a pure in-process function over caller-supplied placement and copper; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the oracle and the gap router are pure functions of placement plus copper)
- completeness-waiver: concurrent access (no shared or mutable state; every buffer is arena-local to one call)
- completeness-waiver: malformed encoding (inputs are typed structs, never parsed bytes)
- completeness-waiver: integer overflow (counts come from the oracle's own slices; the only arithmetic is float millimetre comparison)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/vacate-policy

Public functions: judge, judgeAll, cheaperFirst, select, selectMany

Which foreign copper a walled-in net's transaction may VACATE. The gap closer's
wholesale re-route already strips whole nets, routes a stuck seed across the
freed channel and puts the displaced nets back inside one all-or-nothing
transaction; what it could not do is pick the right nets. Its own predicate asks
"is this copper safe to restructure?" and answers no for anything a plane or a
pour carries — so the cheapest copper on the board to move is the one category
it never nominated. A pour-carried rail stays WHOLE with its tracks gone (the
zones ride through the transaction untouched), which makes it the *first* thing
a human operator clears and the last thing the engine would consider. This
module ranks by RESTORE CHEAPNESS instead — poured nets, then short stubs, then
a declared differential pair whose caller will re-lay it coupled, and nothing
else — behind guards that refuse ground, unclaimed diff-pair members, `(max-freq
…)` RF, fenced traces and any net that is itself still open. Measured on
barracuda's `auto-full-v2`: `GND` behind a 2.3 mm bridge the maze cannot walk,
the LDO pocket held by 44 elements of the poured `V_6VA`, and the standard tier
nominating only the two control stubs beside it — the move that does not work.

The pair rank is the one class admitted by a CALLER'S CLAIM rather than by a
fact about the board. A pair is refused by default for a real reason — its
geometry was placed deliberately and an ordinary re-route would not reproduce it
— and that refusal is what makes a declared pair the copper that seals a
corridor nothing else can open. But its contract is spacing and skew, not an
absolute position, and the router owns a construction that reproduces exactly
that. So `NetFacts.pair_recouple` is the caller asserting it will rip both legs
and re-lay them through that construction; the pair's other protections still
refuse it, its authored priority is exempted for the same reason a pour's is
(the copper is re-laid to contract, not taken away), and the re-proof is the
caller's to run.

- a pour-carried net is nominated as the cheapest copper to vacate
- a pour-carried net outranking the seed is still nominated because the pour underwrites its restoration
- a short whole stub is nominated and a long unpoured net is refused as not cheap
- ground, diff-pair, max-freq RF, fenced and still-open nets are never vacated
- a diff-pair member is nominated as pair_recouple only when the caller will re-lay the whole pair coupled, and the pair's other protections still refuse it
- a pair nomination ranks behind every poured net and short stub, so the dearest restore is tried last
- the cheap tier ranks poured nets ahead of stubs and caps the subset it strips
- a transaction's copper budget skips an oversized poured rail without shutting out the stubs behind it
- the cheap tier's nomination order is deterministic for a given board
- a net outranking the seed is nominated as rank_lifted when the caller says it will lift it corridor-only, ranks behind every cheaper class, and is refused as before without that claim
- a joint transaction refuses every one of its own seeds and judges authored priority against the highest-ranked one
- a joint transaction ranks and caps the union of its seeds' candidates as one transaction, not once per seed
- completeness-waiver: empty inputs (an empty fact list yields an empty decision; unit-tested through `select`'s cap and ranking cases)
- completeness-waiver: large inputs (the caller bounds the fact list to one corridor's occupants, and `Limits.max_nets` caps what is picked)
- completeness-waiver: unauthorized access (pure in-process predicates over caller-supplied structs; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — every input is a struct the caller assembled)
- completeness-waiver: concurrent access (no shared or mutable state; the only allocation is the caller's own decision buffers)
- completeness-waiver: malformed encoding (inputs are typed structs, never parsed bytes)
- completeness-waiver: integer overflow (element counts come from slice lengths; the only comparisons are usize and f64)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/escalate-retry

Public functions: isCandidate, fingerprint, run

The escalation ladder's missing rung: a plain re-attempt of the BLOCKED
residual after a rip-up round changed the board.
`router.escalateSearchLimited` retries exactly one failure class — a leg that
ran out of node expansions (`ctx.search_limited`). Its complement, a leg whose
frontier DRAINED because the copper on the board walled it in, is never retried
by any later tier, which is the wrong half to freeze: "search harder" rarely
changes an answer on an unchanged board, while "the board was in the way" is
precisely what the next phase, rip-up, exists to fix. `ripUpReroute` does not
cover it either — a net boxed in by PADS yields an empty rippable set from
`router.detectBlockers`'s soft probe and is skipped without a plain re-route,
and after the ladder's last rip-up round only the last-resort escalation runs.

The tier is purely additive: a failed net has no copper on the board, nothing
is ripped, and a net that still cannot route leaves the board as it found it,
so there is no accept gate to fail and the routed count can only rise. It is
budgeted three ways (a per-leg expansion budget, a per-net lifetime attempt cap,
a per-pass net cap), carries its own `route_timing` phase, and skips entirely
when the board is unchanged since its previous pass — which is what makes it
safe to call after every rip-up round rather than only after an accepted one.

It ships DISABLED. Measured A/B over the whole corpus (`bench-route`,
ReleaseSafe, against `05e365c`) it fires on exactly the nets it was designed for
— 50 re-attempts, barracuda's `SPI_MOSI` / `SPI_ADF_CSN` / `adf4159/*_1V8` /
`V_12V` / `buck_6v/VIN_F` among them — and routes none of them, at +6 % to +11 %
wall on every board carrying a residual. The trace agrees with `joint-rescue`'s
independent finding: a residual net that drained its frontier on these boards
drained for structural reasons (pad geometry, escape assignment, lattice
resolution), so the copper a rip frees was never what walled it in. The rung is
kept whole and switched off rather than deleted, since that is a fact about the
corpus rather than about the mechanism.

- the blocked residual is a still-failed, re-routable net whose failure was not a search-budget failure
- a net's re-attempts are capped for the whole run, so a permanently walled net cannot be re-flooded every round
- the tier skips a pass whose board is unchanged since its previous one, so calling it after every rip-up round costs nothing when nothing was accepted
- a board fingerprint compares copper element count and routed count, so any accepted rip reads as a change
- the tier is disabled by default, because on the measured corpus it re-attempts the blocked residual at real wall cost and routes none of it
- completeness-waiver: empty inputs (an empty working set yields an empty report; the pass allocates nothing per net)
- completeness-waiver: large inputs (`Policy` caps the nets one pass takes, the re-attempts one net ever gets, and the expansions one leg searches)
- completeness-waiver: unauthorized access (an in-process routing pass over the caller's own live context; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the pass reads the live routing context and writes only copper)
- completeness-waiver: concurrent access (one pass drives one working set it was handed; the router holds no shared mutable state across routes)
- completeness-waiver: malformed encoding (inputs are typed structs and live copper, never parsed bytes)
- completeness-waiver: integer overflow (counts come from slice lengths and capped usize increments)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/joint-rescue

Public functions: judge, cheaperFirst, byIndex, select, sequence, orderIsNovel, closesANet, run

The router's ONE joint (multi-net, multi-order) rescue tier, run from
`finishBatch` after the fine-window rescue. Every other conflict the router
resolves is resolved one net at a time: greedy routes in priority order,
escalation retries a single leg under a bigger budget, rip-up rips a failed
net's blockers and re-routes the failed net first, the fine rescue re-mazes one
residual net on a finer lattice. Nowhere is a set of mutually conflicting nets
re-routed jointly. This tier takes each still-failed net as a VICTIM, nominates
a small cluster of the copper in its way, rips victim and cluster together, and
re-routes the cluster under several orders, keeping the best outcome only when
strictly more nets ended routed.

Nomination has two halves, and the second is the one that makes the tier fire.
`router.detectBlockers`'s soft probe reports the foreign nets on the victim's
cheapest path — but only along a path it completed, and a foreign PAD is a hard
wall to that probe, so on barracuda six of the seven nets reaching this tier
produce an empty probe result. The straight-hop corridor sweep the post-route
vacate tier nominates from supplies the rest — and both halves now go through
`placement/blocker-nomination`, the one seam that tier nominates through too.
Ranking departs from `vacate-policy` deliberately: nearest-the-corridor leads,
because this tier's victim has no copper at all and the cluster is worth forming
only if it holds the nets actually standing where the victim must go — measured
on `SPI_MOSI`, cheapness-first picked two unrelated nets and refused its four
sibling SPI lines `over_budget`.

Historical pre-policy measurement from zero (`bench-route`, ReleaseSafe;
current internal runs use self-hosted Debug): barracuda unchanged at 82/91
(every one of its residual nets fails to route even with its three nearest
corridor occupants entirely off the board — the wall there is lattice
resolution, pad geometry and escape assignment, not removable copper),
cyclops-xband-sip 18 → 19, straps 79 → 80, with the corpus baseline gate PASS
and no board losing a net.

- a routed, re-routable, no-higher-priority blocker is taken into the victim's cluster
- ground, plane-carried, pour-carried, diff-pair and max-freq RF copper is never ripped by the joint tier
- a still-open, frozen, or strictly-higher-priority net is refused rather than ripped
- the joint tier ranks blockers nearest the victim's corridor first, then by least authored priority and fewest elements, and caps the cluster
- the joint tier accepts a cluster only when it leaves strictly more nets routed, never on an equal-count board with shorter copper
- the joint tier's copper budget skips an oversized blocker without shutting out the short ones behind it
- a cluster is re-routed victim-first, in authored wave order, and victim-last
- the wave order is skipped when it would repeat the victim-first or victim-last sequence
- the joint tier's victim and attempt caps bound the whole pass, not each victim separately
- the joint tier's nomination order is deterministic for a given board
- the joint pass forms a cluster for a walled-in net and, when no order closes it, leaves the board byte-identical and the routed count unchanged
- a victim whose corridor holds only refused copper forms no cluster, so the tier never rips an RF class to reach it
- running the joint pass twice over the same board produces identical copper and an identical report
- completeness-waiver: empty inputs (an empty candidate list yields an empty decision, and a board with no failed net returns before the pass allocates anything)
- completeness-waiver: large inputs (`Limits` caps victims, cluster width, cluster copper, whole-pass attempts and every maze budget the pass spends)
- completeness-waiver: unauthorized access (an in-process routing pass over the caller's own live context; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the pass reads the live routing context and writes only copper)
- completeness-waiver: concurrent access (one pass drives one `RouteCore` it was handed; the router holds no shared mutable state across routes)
- completeness-waiver: malformed encoding (inputs are typed structs and live copper, never parsed bytes)
- completeness-waiver: integer overflow (counts come from slice lengths; the only arithmetic is usize decrement under a checked cap and f64 millimetre comparison)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/target-unblock

Public functions: blockerLimits, blockerFacts, pairFacts, liftFacts, pairHeld, pairHealthAll, targetOf, closestToClosedFirst, order, sliceDeadline, restoreDeadline, transactionClosed, Gate.init, Gate.deinit, Gate.accepts

The policy half of the residual tier that rips ONE open net's diagnosed
blockers, routes that net through the corridor they vacate, and puts them back
inside a single all-or-nothing transaction. The driver is `serve/route-plan`'s
residual area, because ripping and re-routing is a route-lowering operation and
the authority it commits under is `fine_accept.Gate` — the connectivity oracle
every other tier is judged by.

Two other shapes were measured on barracuda's 102/109 residual first and neither
moved the board. A whole-field joint rescue inside the timed route STARVED: the
residual tail is tens of seconds and one unbounded multi-net re-route spends all
of it, so the run ended with the copper it started with. One AGGREGATE cluster
over three open seeds and their six shared blockers was cheap, safe and bought
nothing — those seeds' corridors are not one corridor (`LOCK_DET` crosses the
board 55 mm while `EN_BUCK6V` needs 16 mm into a different pocket), so freeing
their union frees nobody's, and the all-or-nothing gate then has six restores to
prove instead of two. The untried variant is the small, explicit, per-target
transaction, and its bounds are this module's whole contribution: the rip,
nomination and accept machinery already exists.

A target is a wholly open two-terminal net — two pads, two islands, one
island-joining hop — because such a net's entire problem is that hop, so freeing
a corridor can plausibly close it and the transaction's success test is
unambiguous. Targets are attempted cheapest hop first, so a 55 mm cross-board
corridor cannot spend the tail three shorter targets could have used, and each
gets an equal share of the remaining budget, floored (a slice too short to route
anything is not handed out at all) and capped (one target may not take a whole
tail). Blocker selection is `placement/vacate-policy`'s restore-cheapness
ranking, the one measured on this board: the post-route vacate tier took
barracuda 85 -> 91 picking a corridor's cheapest occupants, and its pour
exemption is what let the winning transaction displace a poured rail whose
restore the pour underwrites.

Two classes of copper are displaceable HERE that `placement/vacate-policy`
refuses everywhere else, and both exist because "unrippable" was a policy answer
where the physical one is "movable, under a construction that reproduces its
contract". Plane- or pour-carried ground is the first: its surface hookups and
stitch vias are not what makes it connected, and the transaction re-measures
ground pad by pad before it commits. A declared differential pair is the second:
its contract is spacing and skew rather than an absolute position, the router
owns the coupled construction that reproduces it, and the transaction rips both
legs, re-routes them through that construction under their own authored class
and wave, and re-proves the result per pair on top of the whole-board gate. Both
are gated on the caller asserting the transaction really will do that work — for
the pair, a tier with pair recoupling switched on plus a resolved twin — so
neither is available to the narrow transaction that cannot afford it, and a
board with no route deadline never reaches the tier at all.

The ground permission alone changes nothing on a real board, which is what the
corridor lift is for. A plane-carried ground is whole, displaceable and lying
across every sealed corridor — and carries hundreds of elements, so the copper
budget refuses it as over-budget and is right to: re-laying a board's entire
stitch field inside one transaction's slice is a second route, not a rip. What
is actually in the way is the handful of barrels and hookups crossing the
channel, and for a plane- or pour-carried net those are not its connectivity —
which is the same argument that made it nominable at all, applied to a SUBSET of
its tracks. So a lifting tier charges such a blocker for the corridor copper it
will remove, rips only that, freezes the rest byte-for-byte, and lets the router
re-stitch what it disturbed; the corridor is measured with the nomination's own
per-element gap, so the copper charged for and the copper removed are the same
copper.

That same arithmetic sizes the transaction's SLICE, because a rip scaled by
corridor length under a flat wall-clock cap is strictly worse than the small
transaction it replaced: the corridor is freed, the clock stops the re-route
halfway, and the board learns nothing about whether the join exists. So the cap
grows per element of rip authority the corridor bought, saturates where that
authority saturates, and stops at its own ceiling — while the pass's equal share
and its reserve still bound what is actually handed out, so a long-corridor
target takes a longer slice only out of time no other target and no close behind
it had a claim on.

The module sits at the repository root rather than under `src/placement/`
because guardian's `serve-placement-internals` layering rule forbids the serve
layer from compiling against the solver's internals and its own fix note names
the remedy — a module both layers may import (`src/fab_readiness.zig` is the
same shape). That is also why `Gate` wraps `fine_accept.Gate` instead of the
lowering seam reaching into it; the judgement it applies is entirely
`fine_accept`'s and is specified under `placement/route-resolution`.

- only a wholly open two-terminal net, two pads in two islands one hop apart, becomes an unblock target
- a many-islanded open net yields one transaction per gap, smallest first, capped per net
- the pass's shared accept gate is sized for a ladder of island merges rather than for a handful of rescue attempts, and its budget may only be raised
- every open net the whole-net rule does not claim yields per-gap transactions instead, so a two-island net of many pads is a target rather than a hole between the two rules
- among targets whose nets are equally far from closed, unblock attempts the smallest island gap first, tie-broken on net index, and caps the pass
- an unblock target whose net has fewer island gaps left is attempted before one with more, whatever their hop lengths, because the fewer-gap net is the one an accept finishes
- one many-islanded net's per-gap targets may not crowd another open net out of the pass; every net gets its first attempt before any net gets its second, and the cap counts nets
- each unblock transaction gets an equal share of the route budget's remainder, floored and capped, and none is started once too little of it is left
- a transaction is closed only when the oracle connects its target and reconnects every net it ripped
- one unblock transaction rips at most three blockers and bounds the copper its restore must re-lay
- the unblock pass never spends the end of the route budget, so the additive connectivity close behind it still has a slice
- a transaction's rip budget and corridor band are sized by the length of the corridor it is clearing, so a cross-board join is not held to the bounds an endpoint pocket was sized for, and both stay bounded
- ground copper a plane or pour carries is displaceable by an unblock transaction, while ground with nothing behind it stays refused
- a declared differential pair is displaceable only under a tier that turns pair recoupling on and names the twin it will rip with it
- a re-laid differential pair is kept only when both legs carry copper, its coupling window is no worse and its skew is within the constructor's equalisation window of what it was
- a plane- or pour-carried blocker is charged for the corridor copper a lifting tier will actually remove, so a heavily stitched ground is negotiable instead of refused for its size
- a blocker held out on authored rank alone is negotiable to a tier that declares it, charged for the corridor copper it will lift, while a tier without the switch, or a blocker with no copper in the corridor, keeps today's refusal
- a transaction's slice cap grows with the rip authority its corridor bought it, saturating where that authority does and stopping at its own ceiling, while the pass's equal share still bounds what is handed out
- a transaction's slice cap also grows with the copper its own restore has to re-lay, charged at the same per-element rate under the same ceiling, and a tier that declares no rate keeps its flat cap
- a formed transaction may claim what its own restore is priced at when that beats its equal share of the remainder, never past the grown cap and never into the floor every target behind it is still owed, and a clock-free board or a rateless tier keeps the equal-share answer
- the tail an earlier phase must hold back is this tier's own corridor slice for the widest target plus the additive close's reserve, held under the caller's ceiling
- completeness-waiver: empty inputs (no open net yields no target, an empty target list yields an empty attempt order, and a transaction naming nothing is never formed)
- completeness-waiver: large inputs (`Limits` caps targets per pass, blockers per transaction, displaced copper, and the wall time each transaction may hold)
- completeness-waiver: unauthorized access (pure policy over the caller's own already-authorized route result; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — inputs are typed counts, net names and one caller-supplied timestamp)
- completeness-waiver: concurrent access (stateless pure functions over immutable inputs; the pass's own mutable state belongs to its driver)
- completeness-waiver: malformed encoding (inputs are typed structs and oracle-owned net names, never parsed bytes)
- completeness-waiver: integer overflow (counts are slice lengths; the arithmetic is one i128 nanosecond division clamped between a floor and a cap)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/congestion

Public functions: crossable, surcharge, walls, price, accepts, nextPresent, absorbLane, reclaimLane, run, runWith

Negotiated congestion (PathFinder-style present + history pricing), run inside an
OVERLAP-TOLERANT global accept gate. The gate is the prerequisite and the durable
half. The algorithm was tried in this router once before, inside the DRC-gated
transactional rip-up path, and measured WORSE than doing nothing (83/90 on
barracuda) — because that path requires every INTERMEDIATE board to be legal,
which is precisely what negotiated congestion cannot promise. Its whole mechanism
is to let nets overlap, price the overlap, and let the prices push them apart
over several rounds; a gate that refuses the first illegal state refuses the
algorithm.

So the sandbox permits illegal board-wide states and judges nothing until it
closes. Inside it, copper a re-routable non-guarded net owns is passable at a
price rather than blocking (`walls` / `price`, the two entry points
`router.blocked` and `router.relaxStep` consult behind a nullable pointer, so an
unarmed route's walls and costs are bit-for-bit what they always were). Ground,
plane- and pour-carried nets, diff-pair members, `(max-freq …)` RF nets and
anything the engine froze stay hard walls, as does every pad and every reserved
lane. Each round rips the whole victim set, re-routes it in one fixed order,
attributes every lattice cell that changed hands to the net that took it
(`absorbLane` — the occupancy grid records one owner per cell, so a diff against
the pre-claim image is the only way to see a share), charges those cells to the
congestion history, and pulls the displaced nets into the victim set for the next
round. A round in which nobody takes a cell over is the loop's convergence
signal.

At the end, and only there, the board meets the strict regime the house already
trusts: `fine_accept.strictlyBetter` over the connectivity oracle (strictly more
nets joined, not one previously joined net lost) plus `drc.errorCount` not risen,
AND the loop must have converged — an unconverged sandbox is holding two nets in
one place, which no connectivity gain buys. Anything else restores the snapshot,
and the board is exactly the one the phase opened on.

The tier SHIPS DISARMED (`Limits.max_iterations = 0`), which is the audit item's
armed kill criterion: negotiated congestion is the last of three families of
global steering measured on this corpus (topology corridors at three doses,
escape guides, now this) and none has paid. Arming it is a one-line A/B against
the same binary, the shape `placement/joint-rescue` established. The measured
trace lives in the commit message and `docs/autorouter-audit-2026-08.md`.

- the negotiated-congestion tier ships disarmed, so a route that never raises its iteration cap is bit-for-bit the route it always was
- foreign copper is a hard wall for every route outside the sandbox and passable-at-a-price only for a net the sandbox can itself re-route
- an unarmed route pays no congestion surcharge at all, and an armed one prices a shared cell by present congestion plus its accumulated history
- the present-congestion factor ramps geometrically between iterations and is clamped, so late rounds insist on legality without becoming an unreachable wall
- a cell a victim takes over is charged to the congestion history and names the net it was taken from, and a later round in which nobody takes a cell over reports the round legal
- the sandbox's board survives only when the round converged, the connectivity oracle strictly improved, and the fab-blocking DRC count did not rise
- the end-state measurement reads the live context's arcs and swept RF paths, so a net joined only by a taper is not counted open
- a cell a victim took from a net still on the board is handed back when the victim's copper comes off, so a board where two nets' copper coincides can never read as legal
- the negotiated set is laid down legally in the router's own priority order, not in the order the negotiation happened to pull nets in
- inside an armed sandbox a cell another re-routable net's copper holds stops walling the maze out, and the same cell walls it out again the moment the sandbox closes
- a sandbox whose end state the gate refuses restores the board byte for byte, copper and occupancy alike
- two runs of the same armed sandbox over the same board make the same decisions and leave the same copper
- the disarmed phase leaves the board and the working set exactly as the rest of the ladder left them
- completeness-waiver: empty inputs (a board with no open re-routable net returns before the phase allocates its lattice images)
- completeness-waiver: large inputs (`Limits` caps rounds, victims, whole-phase re-routes and every maze budget the phase spends; no bound is a deadline)
- completeness-waiver: unauthorized access (an in-process routing phase over the caller's own live context; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the phase reads the live routing context and writes only copper)
- completeness-waiver: concurrent access (one phase drives one `RouteCore` it was handed; the router holds no shared mutable state across routes)
- completeness-waiver: malformed encoding (inputs are typed structs and live copper, never parsed bytes)
- completeness-waiver: integer overflow (counts come from slice lengths and saturating history increments; the price schedule is f64 and clamped)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/diff-shape

Public functions: envelopeChannel

The gridless channel search for a coupled differential pair's envelope — the
mesh tier behind `placement/router`'s coupled construction, which until now had
only the raster maze.

A declared pair is routed as ONE centreline whose copper profile is the whole
pair envelope (`2·width + gap`), then split into two exact ±(width+gap)/2 offset
legs. When the maze cannot find an envelope-wide corridor the pair falls back to
two independent leader/follower routes. That verdict is the one every other
residual tier learned not to trust: a channel narrower than the grid pitch, or
one that only opens by diving to another layer, is not a path a lattice can
represent however much budget it is handed, and `cdt_layers` answers exactly that
question for single nets. A pair could never reach it — the shape rescue tier
skips every pair member by name, because a leg drawn alone is copper the coupling
contract is certain to throw away — so the mesh is asked for the ENVELOPE
instead, and what comes back is a corridor both legs fit in by construction.

The module is a CENTRELINE SOURCE and nothing else. The two representations
already agree field for field (`cdt_layers.Leg` is a layer plus a polyline and
`diff_route.Run` is a layer plus a polyline, and both carry one via per layer
change), so the transcription is a transcription — but its SHAPE is checked
rather than assumed. `diff_route.chain` guarantees N runs joined by N-1 vias for a
maze centreline, and `build` and `shiftVia` both read the run past every via on
the strength of it; the mesh does not make that guarantee, because
`cdt_layers.extract` appends a via unconditionally and drops a leg whose funnel
yields no polyline. The router's own emitter is happy with the looser shape, so
the refusal lives on the one consumer whose contract is tighter. What comes back
is handed to the caller's own `diff_route.build` / `equalize` / exact-probe chain unchanged, so
a mesh channel earns its copper on precisely the terms a maze channel does:
mitered through every bend, paired at every via, length-matched in the pad fans,
and refused outright when any constructed segment fails the honest clearance
probe. Nothing here emits copper and nothing here relaxes a rule.

The via sites come from `router.shapeInput`, seeded at the single-track legality
the router can answer on its own; a pair needs room for a barrel PAIR, which only
the construction knows, so the caller's via-float ladder walks each transition
until the exact probe passes. A site this seed offers that no pair fits simply
loses its candidate, exactly as a maze-chosen transition does.

Reached only when the caller's tier turns it on
(`route_policy.PairChannel.mesh_behind_maze`), so every board that has ever
routed without it stays byte-identical.

- a mesh channel is transcribed into a pair centreline run for run, point for point, and via for via
- a mesh channel that changes layers carries one centreline via per layer change, at the site the mesh dived through
- a degenerate mesh answer yields no centreline at all rather than a run the leg construction cannot use
- a mesh answer that is not N runs joined by N-1 vias is refused, because the leg construction reads the run past every via
- the pair envelope search asks the mesh for a channel two widths and one intra-pair gap across, not for a single trace's
- the pair envelope search launches from the same two far escape points the coupled maze search does
- the pair mesh tier is off unless a caller turns it on, so an ordinary run routes every declared pair on the lattice alone
- a pair the mesh cannot channel either leaves the board exactly as the maze left it, so the tier can never buy copper by relaxing a rule
- the pair envelope search reports the wall that stopped it and records it for a caller holding rip authority, instead of only reporting that it found nothing
- completeness-waiver: empty inputs (a mesh answer with no leg, or a leg with fewer than two points, yields no centreline)
- completeness-waiver: large inputs (bounded by `cdt_layers`' own node ceiling and by the caller's search window; a bigger board only widens the window the caller already sized)
- completeness-waiver: unauthorized access (pure in-process geometry over the caller's own live routing context; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — inputs are the live routing context and the pair's resolved terminals)
- completeness-waiver: concurrent access (one pair is constructed inside one router context; the router holds no shared mutable state across routes)
- completeness-waiver: malformed encoding (inputs are typed structs from the router and the pair resolver, never parsed bytes)
- completeness-waiver: integer overflow (layer indices are the context's own; every other quantity is f64 millimetres)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/pair-pinch

Public functions: Report.owner, Log.record, Log.reports

Where a coupled differential pair's envelope search hit a wall, carried back out
of the router to the caller that can do something about it.

The pair channel search triangulates the pair's free space at envelope width
and, when no channel exists, walks its own walls to find the narrowest cut
between the two terminals and the copper that owns each side of it. That is a
fact the CALLER needs rather than the router: the transaction that lost the pair
is the one holding rip authority, and "these two nets are 0.31 mm apart where the
pair needs 0.52 mm" names copper a deepening round can nominate, where the old
verdict — "no envelope channel in the mesh either" — named nothing at all.

So this is a SINK, sized like the two the route options already carry (the
progress sink and the phase timer): a caller that wants the diagnosis hands one
in, and a run with none is byte-identical to a run before it existed. It is a
fixed-size buffer rather than a list because it is written from inside a routing
pass, where an allocation failure must never be able to lose copper — a full log
stops recording, and a dropped diagnosis costs a verdict line rather than a
board. A side owned by a keepout or the board-edge band names no net, because
there is nothing there a rip could ever be asked to move.

- a pinch log records what it is handed in order, stops at its cap rather than growing, and names only the sides whose owner is a net a caller could nominate
- completeness-waiver: empty inputs (a log nobody wrote to reports nothing; a report with no nameable side names no owner)
- completeness-waiver: large inputs (bounded by `max_reports`; past it the log stops recording rather than growing)
- completeness-waiver: unauthorized access (a plain value the caller allocates in its own frame; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the values are net indices, millimetres and a layer already resolved by the geometry that found them)
- completeness-waiver: concurrent access (one log belongs to one route transaction; the router holds no shared mutable state across routes)
- completeness-waiver: malformed encoding (typed fields written by the geometry, never parsed bytes)
- completeness-waiver: integer overflow (net indices are the flattener's own and the length is bounded by a comptime cap)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/pinch-probe

Public functions: probe, padPart, pairEnds, Pinch.shortfallMm

What walls a net — or a coupled pair's envelope — at THIS PLACEMENT, asked
standalone.

The router already knows how to name a wall: the layered CDT search triangulates
the free space at the width a channel needs and, when no channel exists, walks
its own walls to the narrowest cut between the two terminals and the copper that
owns each side of it. The coupled-pair tier uses that to explain a decline and
the unblock phase turns the answer into a rip nomination. Both of those live
inside a ROUTE — a live routing context, a live transaction, a live rip
authority — and that is the wrong shape for the question a placement repair asks.
"Which two bodies leave this net no room?" is a fact about where the PARTS are,
and it has to be answerable before any copper exists and without permission to
tear any up.

Two properties make asking it over the placement alone honest rather than merely
cheaper. The model is PADS: no copper, no halos, no keepouts, no via sites, so
every richer model the router builds only ADDS obstacles to this one and a wall
found here is a wall in all of them. And the search runs on the terminals' own
signal layer with no via sites, which is STRICTER than the router's — so
"pinched" never claims "the router has no route", only "this face has no
channel". Whether widening it helps is settled by re-routing, never asserted
here.

A pinch names both sides by the placed PART carrying the pad, not only by net.
That is the whole reason this exists next to the pair-pinch log: a net index is
the handle a rip takes, and a part index is the handle a pose takes.

- a pad obstacle index resolves to the placed part carrying it, by the running pad count `buildObstacles` itself walks
- a channel with room reports no pinch at all, so a caller only ever acts on geometry that is genuinely short
- a channel walled by two pads names both parts, the room it has and the room it needs, and the shortfall between them
- a coupled pair's probe terminals are the midpoints of the pad pairs at its two extremes, so a leg carrying a termination or a coupling cap still has an envelope, and a leg with fewer than two pads has none
- a probe with no routing net of its own makes every pad foreign, including the unnetted lands the router itself spells -1
- a probe asked for no width at all answers nothing rather than triangulating a channel with no meaning
- completeness-waiver: empty inputs (a placement with no pads has no wall to name and answers no pinch; a zero-width ask is refused outright)
- completeness-waiver: large inputs (the mesh is built over one bounded window around the two terminals, and the CDT engine's own node ceiling refuses a pathological one)
- completeness-waiver: unauthorized access (pure geometry over a caller-owned arena; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the inputs are poses and millimetres the caller already holds)
- completeness-waiver: concurrent access (reads the placement and writes nothing, so a probe holds no state two callers could share)
- completeness-waiver: malformed encoding (typed geometry, never parsed bytes)
- completeness-waiver: integer overflow (the obstacle index is bounded by the placement's own pad count and resolves to null past it)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/place-repair

Public functions: plan, Why.text, Move.distMm

Turn a placement pinch into a legal micro-move, or say why there isn't one.

The probe measures; this decides. WHICH of a wall's two bodies may move, WHICH
WAY, HOW FAR, and whether the resulting pose is one the placement model still
accepts. It is deliberately timid, because a placement move is the most expensive
edit an engine can make: it invalidates every routed net touching the part and
changes a board a human may already have reviewed.

Only a movable passive moves. A hub IC anchors its whole subsystem, an RF-fenced
or `(near …)`-bound part was placed where it is on purpose, a declared diff-pair
member IS the geometry under discussion, and a locked part is a human's explicit
"do not touch". Each of those is refused BY NAME, so a pass that moves nothing
still says what it looked at.

The move is the shortfall and no more: the pinch's own `need − have` plus one
margin, along the axis away from the body on the far side of the wall, snapped
OUTWARD onto the pose grid so the snap can only give the channel more room than
was asked for. A shortfall past the micro-move ceiling is refused rather than
half-satisfied.

The trial pose is judged by the model that already exists — courtyard overlaps,
the declared board outline, and the layout lint — and any of them worsening
rejects the move. Nothing here invents a new placement rule, and whether a legal
move actually HELPS is not a question this module answers: it plans, the caller
routes, and the routed count decides.

- a computed translation is the measured shortfall plus one margin, along the axis away from the far body, snapped outward onto the pose grid
- a snapped move rounds outward, so the pose grid can only ever give the channel more room than the shortfall asked for
- only an unlocked two-terminal passive may be translated; a hub, a lock and a foreign ref-des prefix are each refused by name
- every refusal carries a reason a reader can act on, and the reasons are distinct
- a wall whose two sides are pads of one rigid part is refused by name, because translating that part carries both pads and cannot widen the gap
- a part whose trial pose would leave the declared board outline is refused, and a board with no declared outline refuses nothing on that ground
- a placement whose channel has room yields no finding, no move and no refusal, so the option changes nothing on a board that does not need it
- a pinch between two movable passives yields one bounded move that opens the channel, and re-probing the moved placement finds the channel open
- completeness-waiver: empty inputs (no aims plans nothing; an aim whose channel has room yields no finding, no move and no refusal)
- completeness-waiver: large inputs (one invocation moves at most `Limits.max_moves` parts and probes one bounded window per aim)
- completeness-waiver: unauthorized access (pure planning over a caller-owned allocator; the acting surface is gated at the serve boundary)
- completeness-waiver: i/o failure (no I/O — poses in, poses out)
- completeness-waiver: concurrent access (the placement is read and every trial pose is written to the caller's own copy)
- completeness-waiver: malformed encoding (typed poses and millimetres, never parsed bytes)
- completeness-waiver: integer overflow (part indices come from the placement's own slice and every lookup is bounds-checked)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## route_repair

Public functions: run, writeRepairJson

The `repair_placement` half of `route_experiment`: probe the board that just
routed for the geometry walling its still-open nets, compute one bounded set of
micro-moves, re-route once on the moved poses, and keep or discard on the count.

The campaign this exists for had run its routing economics to the end — ten
measurements holding at the same routed tally with the same survivors, each with
a proven wall: a coupled pair with no alternative channel, a pocket whose every
freed blocker revealed another, corridors geometry-sealed after rips. The one
lever left is where the PARTS are, and the pinch diagnostics make that surgical
rather than speculative because they name the two bodies and the exact
millimetres between them.

Aims are probed keystone first: every declared differential pair's envelope
(a pair is the one structure that occupies a corridor it cannot share), then each
still-open net's shortest closing hop — the oracle's own aiming data, so the
probe asks about the same gap `add_tracks` would.

Two properties are load-bearing. It is OFF by default and byte-identical when
off, so the baseline route is exactly the route it always was. And it PERSISTS
NOTHING: `route_experiment`'s defining property is that it writes no sidecar, and
a repair that silently starred a new layout would take that away. An accepted
trial comes back as the exact pose list a caller feeds to `set_part_poses` and
`save_pcb_layout`, which are the tools already gated for writing.

- a repair pass with nothing to probe reports that it had no aim rather than claiming the board is clear
- a pinch side is named by the part carrying it, falling back to its net and then to what kind of body it is
- repair_placement is an argument of the read-only route_experiment tool, so a repair pass persists nothing
- a repair JSON block always names its verdict and its four lists, so a channel probed and found clear is legible rather than silently absent
- completeness-waiver: empty inputs (a board with no declared pair and no open net has nothing to probe and says so)
- completeness-waiver: large inputs (aims are capped at `max_aims`, moves at the plan's own limit, and exactly one trial route runs)
- completeness-waiver: unauthorized access (it rides a read-only CLI tool and writes nothing; write access is gated on the mutation tools it hands its poses to)
- completeness-waiver: i/o failure (no I/O of its own — the routing and DRC seams it calls own their own failure handling)
- completeness-waiver: concurrent access (request-local: the trial routes over a private copy of the poses and the caller's placement is never written)
- completeness-waiver: malformed encoding (its inputs are the typed route result and placement the caller already holds)
- completeness-waiver: integer overflow (counts come from the router's own tallies and part indices from the placement's slice)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/blocker-nomination

Public functions: nearer, count, has, ranked, nearerFirst, foldProbe, sweepHops, trackGap, viaGap

The ONE nomination both rip-and-re-route tiers ask: whose copper stands in a
stuck net's way. `placement/joint-rescue` asks it inside the batch route and the
`close_open_nets` vacate tier asks it afterwards over a saved layout, and each
had grown its own answer, over its own hash map, with its own unspecified
iteration order — the 2026-08 router audit's finding that three nomination
implementations exist and the tier facing the hardest problem uses the weakest.

There are exactly two ways to answer and they fail in opposite directions, which
is why neither is redundant. The PROBE (`router.detectBlockers`, a soft Dijkstra
with foreign copper passable at a penalty) reports every net whose occupancy the
stuck net's cheapest path crosses — via barrels, step reservations and keepout
halos included, because all three live in the grid it walks — but it treats a
foreign PAD as a hard wall and records nothing off a path that did not complete,
so a net boxed in by pads yields nothing at all (six of barracuda's seven
in-route residuals). The corridor SWEEP always answers, because it is pure
geometry, but both copies of it looked only at TRACKS, so a via field parked
across a channel was invisible.

This module is their union: one table, one rule (a net's CLOSEST approach wins,
and a net the probe walked through is recorded at zero), one deterministic
order, and a sweep that can take vias as well as tracks. The via-aware policy is
what the post-route tier needs and the in-route tier does not: the router's
context is built and dropped inside each gap-closing call, so the post-route
tier cannot probe at all and geometry is its only sense. Judgement stays out —
what may be RIPPED differs between the tiers on real grounds
(`placement/vacate-policy` will displace a poured rail because the pour
underwrites its restoration; the in-route tier will not, because mid-route
nothing underwrites anything), and only the nomination was accidentally
different.

- the shared nomination records each candidate net's closest approach to any of the stuck net's corridors
- a net the soft probe walked through is nominated at distance zero, ahead of every net merely near the corridor
- a via field across a corridor is nominated under the via-aware policy and invisible without it, and a barrel is measured from its edge
- a nomination never nominates the stuck net's own copper, nor copper outside the corridor radius
- the per-element corridor gap the sweep nominates by is the same measure a caller reads to decide which of a net's own tracks and barrels lie in the way
- the shared nomination's order is deterministic for a given board, nearest first and net index on a tie
- one nomination table accumulates several seeds' corridors, so a joint transaction's candidate set is their union
- completeness-waiver: empty inputs (no hops, no copper or an empty probe yield an empty table, which every caller treats as "nothing to displace")
- completeness-waiver: large inputs (the caller bounds the hop list, and the sweep is one linear pass over the board's copper per hop with no allocation beyond one entry per distinct net)
- completeness-waiver: unauthorized access (pure in-process geometry over caller-supplied slices; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — every input is a slice the caller assembled)
- completeness-waiver: concurrent access (the table is owned by the one transaction raising it; the module holds no shared or mutable state)
- completeness-waiver: malformed encoding (inputs are typed structs, never parsed bytes)
- completeness-waiver: integer overflow (net ids are validated non-negative before the cast; everything else is a slice length or an f64 millimetre)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/route-score

Public functions: score, completionFraction, bendCount, qualityWarnCount

The single deterministic scalar the constraint-DSL routing loop judges an
accept/reject on. A pure function of the routing-result fields the describe and
replay surfaces already emit — completion fraction (routed/total), via count,
routed-copper length, bend count, self-inflicted DRC warnings, and
error-severity DRC count — with no clock or RNG, so the same routed board always
scores identically. v2 is
`1000·completion − 0.5·vias − 0.1·trace_mm − 0.05·bends − 1·quality_warns − 50·drc_errors`;
higher is better. v1 priced a via at 2.0 (20 mm of copper) against the maze's own
~1 mm via cost and scored bends and warnings at zero, so it rejected shorter,
straighter boards the router preferred. `bendCount` and `qualityWarnCount` are
the shared measurements every scoring surface must use, so two scores at one
`formula_version` are counted the same way. The weights are named public
constants (one-line tuning) and `formula_version` tags every downstream score so
stored numbers are only compared within a version.

- a fully routed board with no vias, copper, bends, warnings, or DRC errors scores the completion weight
- each via, mm of copper, bend, quality warning, and DRC error lowers the score by its named weight
- a board with no routable nets counts as fully complete rather than a divide-by-zero
- more vias, longer copper, more bends, more quality warnings, or more DRC errors never raise the score
- completion outranks every geometry penalty combined, so a score can never prefer a board that routes fewer nets
- spending vias to shorten and straighten a route now scores as the improvement it is, where v1 rejected it
- two vias buy back their own cost from a millimetre of copper and a dozen corners, which v1 could never repay
- a via is priced within an order of magnitude of the maze's own via cost, so the search and the score want the same board
- a straight run split into segments has no bends, and each corner in a chain counts once
- bend chains never span a net, a layer, a branch, or a zero-length segment
- a sub-degree jog is a rounding artifact, not a bend
- the score's warning term counts only the self-inflicted geometry kinds, never advisory warnings or errors
- completeness-waiver: empty inputs (a zero-net board is the documented total==0 full-completion convention, unit-tested; an empty track slice counts zero bends)
- completeness-waiver: large inputs (the score is an O(1) arithmetic combination of scalar inputs, independent of board size; bend counting is one O(n log n) sort over the routed segments)
- completeness-waiver: unauthorized access (a pure in-process function over caller-supplied scalars; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the inputs are plain integers and floats already in memory)
- completeness-waiver: concurrent access (no shared or mutable state; the function is reentrant and side-effect-free)
- completeness-waiver: malformed encoding (inputs are typed scalars, never parsed bytes)
- completeness-waiver: integer overflow (the usize counts are widened to f64 before any arithmetic; no integer accumulation occurs)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/ldo-route-quality

The routing-quality ratchet: one real board, routed end to end on every test
run, with every reading that the routing audit moved held to a bound.

Every fix the audit produced — the bend price and the detour guard, the priced
gateway escapes and pad-escape reversal, the finish-pipeline gloss and its
cancel tail, via-in-pad containment, the leg-scoped bypass freeze, score v2,
current-sized rail width, the deterministic implicit-plane tie-break — was
measured on one module: `bcuda-lt3045-ldo`, an LT3045 LDO with a DFN-10 and
exposed pad, seven passives, a four-layer stack carrying a ground plane and a
VOUT plane, and two authored `(decouples "IC" PIN)` bonds. Every one of them has
a unit test of its own, and none of those tests can see the thing that actually
regresses: the fixes INTERACT, and a change that keeps each unit honest can
still ship a worse board. So the board itself is the test. Unit tests cannot
read `projects/`, so the placement is constructed from that module's measured
geometry — the eleven DFN lands, each passive's real pose, the real net list in
the real order, the four decoupling loops the optimizer resolves — and routed
through the ordinary whole-board entry.

The DESIGN half of the module is deliberately left out: no net-class width, no
authored route wave. What the fixture holds still is the ROUTER on that
geometry, so a design-side change can never be mistaken for a routing
regression, and a routing regression cannot be hidden behind a design that
steers around it.

Every bound is a measurement plus headroom, never a transcript. Per net, routed
copper may not exceed 1.6x its own terminal MST (the yardstick `detour_guard`
already uses); the audit's VIN leg toured at 1.96x and today's worst net is
1.19x. The board may draw 16 corners (12 today, 19+ before), 26 barrels (22),
and 6 self-inflicted DRC warnings (3 today, 24+ before). No fab-blocking DRC
error is allowed at all, and both authored bonds must close over surface copper.
No barrel standing in one of its own lands may hang its ring off it, and the one
exception the geometry forces — a DFN edge land 0.10 mm narrower than a 0.4 mm
ring, so no site on it could contain one — is COUNTED rather than ignored and
bounded at one, because a pass that stopped containing barrels puts two more of
them on this board's ground lands. The finished copper must be the closing
gloss's own fixed point — running `glossFinishedTracks` again changes nothing —
which is how a duplicate section or a dangling micro-tail is detected with the
router's own predicate rather than a second one.

The score floor is derived rather than quoted: `route_score.score` evaluated at
the limit of every gate above is the score of the worst board this fixture still
accepts, and the real board must clear it. Being implied by the conjunction is
the point — it pins the scalar the routing loop optimizes to the geometry the
rest of the section bounds, so a formula that grew a penalty term none of these
gates bounds would charge the board and not the floor.

- the LT3045 fixture routes every routable net with no fab-blocking DRC error, and both authored bypass bonds close over surface copper
- no barrel on the LT3045 fixture hangs its ring off a land that could have contained it, and only the one DFN land too small for any ring carries one that does
- no routed net on the LT3045 fixture runs past its own terminal span by more than the detour budget, and the board's corner count, via count, and self-inflicted warnings all stay inside their measured ceilings
- the LT3045 fixture's finished copper is the closing gloss's own fixed point, and every sub-0.1mm section is either pad-neck copper or held at both ends
- the LT3045 fixture's v2 route score clears the score of the worst board its own quality gates still admit
- routing the LT3045 fixture twice yields byte-identical copper, so the audit's retries and guards stay deterministic
- completeness-waiver: empty inputs (the fixture is a fixed board; there is no caller-supplied input to be empty, and the router's own empty-input behaviour is covered in placement/router)
- completeness-waiver: large inputs (one eight-part board routed per test; the measurements are linear or one sort in its two dozen sections)
- completeness-waiver: unauthorized access (an in-process route over a compiled-in placement; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the placement is compiled in precisely because unit tests may not read the project tree)
- completeness-waiver: concurrent access (no shared state; each test owns its arena and routes its own copy of the board)
- completeness-waiver: malformed encoding (the fixture is typed structs, never parsed bytes)
- completeness-waiver: integer overflow (counts are bounded by the fixture's own two dozen sections; the rest is float millimetre arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/bend-smooth

Public functions: minBendRadius, apply, detect, tessellate, arcLength

- detect measures a persisted chord run as one circular bend instead of treating its tessellation vertices as hard corners
- the clearance oracle judges an arc as exactly the chord polyline the emitters draw, so no chord is fabricated at a clearance no probe measured

The pass's own clearance probe sees tracks, vias, pads and the board outline —
enough for a board handed in as plain data, but blind to the blocking zones,
declared keepout halos and RF crossing shadow the ROUTER enforces. A caller
that has the router's oracle therefore passes it as `Input.ext`, and a
candidate must clear both, so an accepted arc is one every clearance surface in
the system would accept. `detect` is the measure-only mode: it reports a
constrained net's under-radius corners and moves no copper at all — the answer
for a coupled diff-pair leg, whose shape may only change in lock-step with its
twin.

RF bend discipline for `(net-class … (max-freq HZ))` nets: each such net's
polylines are rebuilt and every corner is replaced with a tangent arc aiming
for the LARGEST centerline radius that fits its legs and clearance (capped at
5x the trace width), with 3x width as the compliance minimum (the standard RF
rule of thumb). A RIGHT-ANGLE corner drops that cap and aims at the geometric
maximum its two legs can host: its own share of each leg plus whatever the
corner at the leg's far end does not want (halved when that corner is a right
angle too, so two cuts never overlap), always stopping one trace width short of
the leg's far end. A fillet only cuts inside its corner, so a bigger one
shortens the copper; the aim is still only an aim, and a cut that crowds
anything descends the same ladder to the same floor.
Corners that miss the minimum are reported for the
`sharp_bend` DRC warning; a declared `(escape MM)` reserve keeps arcs off the
straight stretch leaving each pad; preserved (stamped reference) copper is
never reshaped. Arcs are three-point (start / mid / end, KiCad's spelling);
arc-blind consumers use the sagitta-bounded chord tessellation.

- a net-class max-freq derives a 3x-width minimum bend radius
- a net-class min-bend-radius overrides the 3x floor for the aim and flag threshold
- a right-angle corner on a constrained net becomes a tangent arc at the target radius
- a corner opens to the largest radius that fits its legs above the minimum
- two right-angle corners split the leg between them instead of overlapping their cuts
- a maximal right-angle aim descends until the clearance oracle accepts the cut
- arcs stay clear of the straight escape reserve at a pad exit
- corners that cannot fit the radius smooth smaller and flag sharp_bend
- a 45-degree bend's arc stays inside its corner wedge
- consecutive corners share a leg fairly and both smooth
- a bend that would crowd foreign copper shrinks its radius until the cut clears
- pad keep-away measures the pad's true box, not a bounding disc
- a pad's own quarter rotation orients its keep-away box
- a sub-width pad-entry jog collapses instead of vetoing the adjacent bend
- a sub-width jog collapse that would sweep the adjacent run into foreign copper is refused
- unconstrained nets and preserved copper pass through untouched
- tessellated arc chords stay on the true circle within the sagitta bound
- an asymmetric biarc retry is tangent to both legs and continuous at its join
- a starved same-sense corner pair merges at the virtual apex to reach the floor radius
- a candidate arc that would bulge past the board outline is rejected, keeping smoothed copper inside the edge
- an under-floor arc flags the sharp_bend marker on the arc, not at the bare vertex
- a corner arc within five percent of the floor radius is not flagged sharp_bend
- an arc the router's own clearance oracle refuses is rejected even when the geometric probe accepts it
- detect reports a constrained net's under-radius corners without moving any copper
- completeness-waiver: empty inputs (no routed tracks or no constrained net returns the input unchanged with changed=false — the pass-through test's case)
- completeness-waiver: large inputs (linear over the routed segment count; chains and chord counts are bounded per corner at 64)
- completeness-waiver: unauthorized access (a pure geometry pass inside the router; endpoint access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk or socket — inputs are in-memory routed copper and resolved net rules)
- completeness-waiver: concurrent access (a stateless pure function over immutable inputs into per-call arena-owned slices)
- completeness-waiver: malformed encoding (inputs are typed router structs; degenerate/collinear geometry degrades to chords, never errors)
- completeness-waiver: integer overflow (counts are slice lengths; chord counts are clamped to 64; coordinates stay f64)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/rf-port-frame-routing

Public functions: solve, frameFit, forNet, passBoard, fromResult, collectOrdered

A controlled-impedance point-to-point RF net is routed between physical port
frames, not footprint centres. Each frame carries the exact land centre, the
land's transformed long-axis tangent in propagation order, and zero required
entry curvature. The final solver fixes both frames, keeps at least one trace
width straight at each pad, replaces every direction change with a symmetric
Euler chain (linear-curvature clothoid, circular middle, linear-curvature
clothoid), and rejects any profile below the class's width-multiple radius
floor or outside the live router clearance oracle.

Each deterministic trial varies radius and clothoid share, evaluates curvature
and curvature-rate energy, length excess, and a lossless cascaded-section ABCD
return-loss model, and records its complete metrics. `(band MIN MAX)` defines
the electrical evaluation range; legacy `(max-freq MAX)` uses MAX/100..MAX.
`(return-loss DB)` defines the minimum worst-case return loss and defaults to
20 dB. Feasibility and the return-loss target precede the weighted objective.
Design roughing uses the same frame/radius lower bound while enumerating
straight and 45-degree connector fans, and keeps pass-through series lands on
the owning switch pad axis.

- eval/design_block - RF band and return-loss target are captured by net-class
- placement/net_rules - RF band and return-loss resolve with backward-compatible defaults
- G2 route matches both port frames and keeps one-width straight entries
- a cramped switch launch fits against one trace-width of straight entry even when its pad taper is longer
- Euler bend has zero-curvature seams and finite curvature-rate energy
- every single-ended controlled-impedance SMD launch tapers between the pad-boundary chord available at its actual path crossing and nominal width, including wider lands, bends inside the pad, full flat-face collars on rectangular and oval pads whose harmless cleanup skew stays face-aligned, and via-fed or branched nets, without diagonal centre-chord flares
- every single-ended controlled-impedance through-via launch tapers between the via's actual annulus diameter and nominal width independently on every connected signal layer
- a named saved layout made before automatic tapers reconciles only uncovered nominal-width launch runs, accepts no new routing-class DRC errors, persists the approved RF paths through ordinary autosave, and exposes each rejected taper as a clickable DRC error at the blocking clearance
- a trace taper remains one logical swept path with compact edit handles while DRC lowers conservative private width-profile chords and folded offset rings lower to overlapping simple fabrication regions
- autorouter fallback tapers are captured before final copper cleanup, including two-sided pad-to-pad profiles, then exported as exact straight-sided swept copper with hidden connectivity handles instead of overlapping round-ended slices
- an autorouter pad taper that outlives its straight escape leg continues linearly by arclength through the following bend instead of ending in a width step at the corner
- late route-plan rescue re-applies DRC-clean exact RF tapers to generated nets that lost finished path metadata without rewriting retained user copper, and keeps the gate-proven uniform trace when no legal flare fits
- solver RF geometry and taper proof survive saved-layout round trips
- a solver-proven one-width pad taper may narrow below the controlled line width, but thin copper away from the land still fails DRC
- a route removed by the final DRC gate is never rendered, saved, replayed, or fabricated as an RF polygon
- feasibility and return-loss success precede the weighted geometry objective
- identical inputs produce identical trial histories and winners
- ABCD mismatch model rejects a badly mismatched launch across the band
- clearance probe makes an otherwise smooth candidate infeasible
- an unrouted point-to-point RF net falls back to its exact port-frame chord instead of waiting for a legacy maze guide
- frame fit rejects cramped tangent intersection and accepts a straight spoke
- a terminal-to-terminal RF calibration net becomes its own physical island
- every attempted RF net exposes its chosen trial, all trial scores, feasibility, entry error, curvature energy, and worst return loss in pcb-describe
- a sampled path claims a stored track only where its own copper is at least that wide, so an orphaned or stale run can never delete a wider trace and re-emit it thinner
- an orphaned or stale swept path never narrows a wider stored trace that shares its coordinates, and still deduplicates the chords it does describe
- completeness-waiver: empty inputs (no eligible two-pin controlled-impedance net is a no-op; an empty/degenerate guide records an infeasible trial rather than indexing it)
- completeness-waiver: large inputs (one net explores a bounded 96-profile table across direct, dogleg, and mirrored lateral-detour families and bounds every Euler chord by the authored chord length; whole-board work is linear in eligible nets)
- completeness-waiver: unauthorized access (pure geometry plus an in-process final router pass; endpoint authorization remains at the existing serve boundary)
- completeness-waiver: i/o failure (the solver and placement lower bound perform no I/O; diagnostics are arena-owned values written by the existing pcb-describe writer)
- completeness-waiver: concurrent access (all solver, trial, and route state is request-arena-owned with no globals, RNG, clock, or cross-run cache)
- completeness-waiver: malformed encoding (netclass numbers are parsed through the typed design evaluator, invalid/non-increasing bands warn, and non-finite geometry fails feasibility)
- completeness-waiver: integer overflow (trial counts are fixed small arrays, sample counts use numeric.toCount, and net indices derive from bounded slices)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/perimeter-fence

Public functions: generate, append, outlinePoints, maskSegments, maskSegmentsForFace, maskSegmentsForFaceWithVias, isGenerated

A `(board … (perimeter-fence …))` declaration generates a plated via ring from
the board's exact finished outline. Its `(via DIA DRILL)` values are finished
copper and hole diameters in millimetres, `(spacing PITCH)` is the maximum
centre-to-centre pitch, `(edge-offset OFFSET)` is the via-centre distance inward
from Edge.Cuts, `(mask-width WIDTH)` is the maximum exposed band measured inward
from the edge on each outer face carrying a matching ground pour, and
`(net "NAME")` selects the stitch net (GND by default). All geometry is derived:
saved `@perimeter` vias are replaced from the current outline and declaration,
not accumulated as hand-authored copper.

- a rectangular fence closes at no more than the declared pitch and keeps every centre at its exact edge offset
- exact rounded/polygon outlines, not their bounding boxes, drive perimeter sites
- incomplete declarations and unresolved stitch nets emit no copper
- component bodies and courtyards do not interrupt generated perimeter vias
- component bodies and courtyards do not interrupt the exposed perimeter mask band
- pad proximity is the only component-derived reason to suppress a perimeter via site, retaining 0.2 mm from pad copper to the via annulus; ordinary copper and drill DRC legality still applies
- a face without a declared ground pour matching the fence net has no perimeter mask opening
- each face's perimeter opening retains mask over foreign pads, routed traces, vias, and the matching GND pour's clearance around them, without suppressing otherwise-valid fence sites
- fabrication and physical views form that opening as one continuous edge band with copper-shaped clear-polarity protectors, leaving the 0.2 mm pad dam without extra round-ended mask scallops
- a perimeter keepout begins at the fence via's inward copper edge, carries typed block policy, and admits named nets
- Gerber opens at most the authored-width solder-mask band around the exact board outline, clipped to matching outer-face GND pour copper
- completeness-waiver: empty inputs (no effective board outline, incomplete dimensions, or an unresolved net produce an empty site set)
- completeness-waiver: large inputs (work is linear in outline vertices plus generated sites; site count is perimeter divided by a positive authored spacing)
- completeness-waiver: unauthorized access (pure placement geometry; HTTP and CLI authorization remains at the existing serve boundary)
- completeness-waiver: i/o failure (generation is in-memory; persistence, Gerber, drill, and KiCad writers retain their own error contracts)
- completeness-waiver: concurrent access (stateless derivation into caller-owned allocator memory; no shared mutable generator state)
- completeness-waiver: malformed encoding (the evaluator clamps negative dimensions inert and typed placement geometry is validated before offsetting)
- completeness-waiver: integer overflow (finite perimeter is checked and floating site count is range-checked before integer conversion)
- completeness-waiver: panic-free (invalid/self-intersecting inset polygons and impossible counts return an empty fence rather than trapping)

## placement/via-fence

Public functions: guidedWavelengthMm, resolvedPitchMm, resolvedFenceVia, resolvedGapMm, guideDistMm, minPitchMm, effectivePitchMm, resolvedLayers, fenceOuterEdgeMm, generate (placement/via_guide: trace, perimeter)

Spec resolution and on-demand generation for a `(net-class … (fence …))` ground
via fence: the concentric rows of stitching vias an RF class's routed traces get,
generated once placement and routing have settled. Every child of the form is
optional — a bare `(fence)` is legal — so the parsed spec and the resolved
`NetRule` both carry "derive me" sentinels, and this layer turns them into
millimetres. Pitch derives as a tenth of the guided wavelength implied by the
class's `(max-freq HZ)` (εr 4.4 FR4), via geometry through the
fence-then-class-then-board fallback chain. The `(offset MM)` number is an
EDGE-TO-EDGE GAP — from the fenced net's copper edge to the fence via's own copper
edge — and derives as the class clearance + a 0.1 mm fabrication margin; the guide
curve therefore runs at that gap plus the via's radius. A centreline-referenced
number would say nothing about the pads a trace lands on, and a pad is wider than
the trace: the same 0.2 mm that clears a 0.3 mm trace buries a via inside a 0.6 mm
0402 land. A class with neither an authored pitch nor a max-freq resolves to no
spacing at all, which is the signal that its fence is unresolvable rather than an
invitation to guess one.

- the end-of-design pass adds a centred 5 mm square GND stitching lattice across the board after RF fences, and a blocked nominal point moves to a legal site no farther than 1 mm away

`(layers N)` selects 1–32 concentric rows and defaults to one, preserving every
existing design. The first row uses the resolved edge gap; each later row is one
effective pitch farther outward. Effective pitch is the authored/derived pitch
raised to the same copper and hole-to-hole manufacturing floor used along a row,
so adjacent rows are buildable by construction. The RF crossing shadow reserves
the full outer-row corridor before routing. Solder-mask relief extends over every
row by default; `(mask-layers N)` limits that derived opening to the N innermost
rows without changing the generated fence or its routing reservation.

The generator reads a solved placement plus a saved layout's persisted copper.
**A fence wraps copper, not centrelines.** Per fenced net, `placement/via_guide`
builds the net's copper UNION — ordinary track segments as capsules, sampled
variable-width paths as exact swept polygons, every pad the net lands on, its
own via barrels — and traces the level set at the resolved distance
from that union's boundary: an exact distance field over the copper's
bounds (0.05 mm cell, stamped per primitive so cost follows copper area) run
through marching squares with linearly interpolated crossings, the same
iso-line construction a copper pour's isolation boundary uses. Cuts are emitted
directed with the inside on their left, so a blob's outer boundary comes out with
positive signed area and an interior hole with negative: only the OUTER contours
are marched, because a via dropped inside a moat sits inside the copper it was
meant to shield. Copper the net shares is one blob, so two chains a pad joins
trace as ONE contour rather than two rings that have to be deduplicated
afterwards. The union spans every LAYER at once, because a fence via is a through
barrel: a top-routed net whose land sits on the bottom face (a board-to-board
connector's pad) would otherwise be wrapped by a contour that knows nothing about
that pad, and the barrel would drill straight through it. Copper that is far apart
in the plane still traces as separate contours, so the merge happens exactly where
the copper touches. A net with no routed track on any layer is left unfenced — a fence
shields a routed path, and ringing bare pads would only wall off the routing still
to come. The pitch is divided evenly into each contour's perimeter (`round(L /
pitch)` sites at an actual spacing of `L / n`), so the fence closes with no seam
gap and no bunching. In legal mode that uniform lattice is tried at eighth-pitch phase
offsets around the closed contour and the phase retaining the most legal sites
wins, so the contour's arbitrary first vertex cannot strand a manufacturable slot
between candidates. A contour too short or a pitch too coarse for even one
division still takes a whole minimum ring rather than a lone via.

- in legal mode the uniform contour lattice shifts in eighth-pitch steps when the contour's arbitrary first vertex misses usable sites, retaining the phase that places the most vias without changing pitch
- a guide around a variable-width path follows the swept polygon's sloped copper edge instead of its compact constant-width edit handle
- restored variable-width RF paths replace their compact edit handles in the fenced copper union, so fence rows follow the final taper outline

How hard each ring site is vetted is the caller's mode. `legal`, the DEFAULT, vets
each site against the board, where **gaps are preferred over conflicts**: a
candidate that crowds a pad, a foreign track, an existing via, a footprint via
keepout, or the board edge is skipped and counted by reason, never forced, and no
existing copper is ever moved. A footprint keepout is transformed by the part's
exact pose and rejects the candidate's full copper disc, including edge overlap;
arbitrary rotations never fall back to an axis-aligned bounding box.
`all` places every site instead, checking only intra-run coincidence — the raw ring
geometry, for judging what the generator drew. A site landing on a pad of the
STITCH net is not a conflict in either mode: via-in-pad on ground stitches that pad
straight to the plane, which is what a fence wants, so only the net-blind
hole-to-hole rule still applies to it — and the same goes for a track or via of the
stitch net, which a fence via may merge with freely. Coincidence dedup runs in BOTH
modes at half the pitch and only across rings, never within the ring being marched,
because it is generation correctness rather than a board rule. Two adjacent fence
vias may not sit closer than the copper (`dia + clearance`) and net-blind hole
(`drill + hole_to_hole`) rules allow, so an unbuildably tight declared pitch is
clamped up to that floor and the clamp is reported. Each accepted via carries the
FENCED net's name as provenance while stitching the ground net, so a fence
invalidates and regenerates with the trace it belongs to.

**The legality prefilter is an exact mirror of `placement/drc`, not an
approximation of it.** Its contract is that the fence adds zero new error-severity
violations while keeping the MAXIMUM number of sites, and both halves are lost by
guessing: a threshold a rounding step tight drops manufacturable vias, one measured
against the wrong rule lets a shorting via through. So each arm of the prefilter is
its DRC twin's predicate written as a keep/skip decision, on the same numbers — the
pairwise `clearanceBetween` rather than the fence net's own class clearance, the
same `eps` slack (so a candidate resting exactly on a rule is KEPT), the same
same-net exemptions, a foreign pad's real outline rather than its bounding box, a
drilled bore as the capsule the drill station measures rather than a disc
swallowing a slot's whole length, and the net-blind `hole_to_hole` floor between
every pair of bores. Three departures are deliberate and all three are STRICTER
than the checker, which forgives copper staged >10 mm off-board, an exactly
coincident pair of drills, and the edge rule on a board with no rectangle: a fence
via wants none of those. A fence via geometry the board's own annular-ring or
min-drill rule rejects is refused per net with a reason rather than marched into a
ring of identical violations.

- a fence pitch derives a tenth of the guided wavelength from the class max-freq
- (fence (layers N)) marches N concentric closed rows one effective pitch apart while the default remains one
- (fence (mask-layers N)) changes only mask reach and leaves generated fence geometry intact
- a fence with neither pitch nor max-freq resolves to no spacing so the generator can report it unresolvable
- a fence offset is the gap from the net's copper edge to the fence via's copper edge, derived from the class clearance and a fabrication margin
- the guide contour is the level set at one distance from the net's copper, so a straight trace traces a racetrack that distance from its edge
- a pad wider than the trace bulges the guide contour out around the pad's own edge at the same distance, so no site lands inside the pad
- copper the net shares merges into one guide contour, so two chains joined by a pad are wrapped once instead of ringed separately
- only the outer boundaries of a net's copper union are traced, so an enclosed interior gap is never marched with vias
- a via barrel is copper of the union too, so a net whose only copper is a barrel still traces a circle around it
- a fence via is a through barrel, so the guide wraps the net's pads on every layer, a bottom-side land under a top-routed trace included
- every fenced through-via gets first claim on a local return-via ring, so general-contour dedup cannot consume the posts surrounding the transition
- a part carrying fenced copper gets first-claim legal return-via anchors in each stitch-net pad, searching within the land when its centre is blocked
- a ground fence via stays outside the signal via's synthesized plane antipad, including the 50-ohm default of a max-freq-only RF class
- a fenced net with pads but no routed track on any layer is left unfenced, because there is no routed path to shield yet
- a fence via falls back from the fence geometry to the class via to the board design rules
- the generator marches the resolved pitch evenly around each guide contour of the net's copper, so the fence closes with no seam
- the guide wraps past a fenced trace's endpoints, so the fence closes around its ends instead of leaving two open-ended rows
- a guide contour too short or too coarse for the pitch is still marched into a whole minimum ring, and copper with no length is wrapped in a circle
- the vetted legal mode is the default and drops the guide sites the board vetoes, while mode all places every one the geometry produced, both marching the same guide
- legal fence sites reject full-disc overlap with an exactly rotated footprint via keepout
- the legality prefilter judges a candidate on the DRC's own pairwise clearance and slack, so a site resting exactly on a rule is kept and one a micron inside it is skipped
- a track of the stitch net is no more a conflict than a pad of it, while the net-blind hole-to-hole floor still applies to both
- a fence site crowding an existing via of its own stitch net is refused as a duplicate drill rather than placed
- a foreign pad is measured on its real outline and its bore on the capsule the drill station measures, so neither a chamfered corner nor a slot's length vetoes a site the DRC would pass
- a fence via geometry the board's own annular-ring or min-drill rule rejects is refused per net rather than placed and then culled
- the twin pad of a series part the fenced net lands on is foreign copper, so the guide's sites over it are skipped, while a ground twin takes the via-in-pad
- a derived fence gap is raised to the pairwise clearance the stitch net and the fenced net owe each other, while an authored offset still wins outright
- in legal mode a fence site landing on a pad of the stitch net is wanted via-in-pad, while a pad of any other net still skips it
- a fence pitch below the board's copper and hole-to-hole floor is clamped up to it and the clamp is reported
- two fenced traces sharing a corridor stitch it once, the second ring's coincident sites deduping against the first's in every mode
- a fenced class with no resolvable pitch and a board with no ground net are reported per net, not crashed on
- the generator stitches every fence target — a declared (fence …) or a (max-freq …) RF trace — and only those a caller's net filter names; a plain net's copper is never marched
- a (max-freq …) RF class is fenced even when it declares no (fence …), its pitch deriving as λg/10 exactly as a bare (fence)'s does
- a max-freq RF class with no (fence …) is stitched with its derived pitch, so the Fence action covers the board's RF traces by default
- an impedance-only class is not a fence target: with no frequency there is no wavelength to derive a pitch from
- fenceable is the one predicate both the generate walk and the anyFenceable probe use, so "is there anything to fence" and "what gets fenced" can never diverge
- the anyFenceable probe answers true for a max-freq RF class that declares no fence, so the Fence action and button cover such a board
- anyFenceable answers false for a board whose classes carry neither a fence nor a max-freq
- in legal mode a fence site outside the board outline or inside its copper-edge clearance is skipped as an outline gap
- completeness-waiver: empty inputs (a default-constructed rule declares no fence and every helper answers 0 — the no-pitch-no-max-freq test's case)
- completeness-waiver: large inputs (layer count is capped at 32; each resolver is constant-time arithmetic over one rule; each guide field is capped at 8M nodes per net and row, coarsening its cell rather than growing without bound)
- completeness-waiver: unauthorized access (pure millimetre arithmetic with no endpoint; server-side access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk or socket — the inputs are an in-memory NetRule and the resolved board DesignRules)
- completeness-waiver: concurrent access (stateless pure functions over by-value inputs, holding no allocator and no mutable state)
- completeness-waiver: malformed encoding (inputs are typed structs; DSL text rejection lives in eval/design_block, which warns and drops a bad value)
- completeness-waiver: integer overflow (all arithmetic stays in f64 millimetres and hertz; nothing is narrowed to an integer here)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/octilinear

Public functions: isOctilinear, isAxisAligned, elbows, axisElbows, compass45, snap45, elbow, emitJoin, padExit, padPair, heading, turned, turnedAlways

Octilinear (H/V/45) trace geometry — the router's angle discipline, shared by
every stage that creates copper. The discipline is a reviewability property,
not an electrical one: a trace on the eight compass headings has a few
meaningful corners a human (or an `add_tracks` agent) can follow and edit,
while an arbitrary-angle line threading a dozen obstacles must be redrawn
whenever anything near it moves. `isOctilinear` judges a finished segment
within a 1° tolerance (scale-free, so a long trace is held to the same angular
standard as a short one) and treats a sub-nanometre segment as compliant since
it carries no heading. `elbows` returns the two octilinear two-segment
connections between any pair of points — axis-run-then-45°, and
45°-then-axis-run — which are exactly octilinear on each leg and equal in total
length, so a caller probes both for clearance and takes whichever fits; an
already-octilinear pair degenerates onto an endpoint so the single straight run
falls out without a special case. `turned` reports whether a maze move changes
heading; the router accumulates it per search state and uses it to order
EQUAL-COST states so ties settle toward the straight run instead of a
micro-staircase. It is deliberately a tie-break and not a cost term: pricing a
bend into the distance leaves the Euclidean heuristic estimating a quantity the
search no longer minimises, so A* degenerates toward Dijkstra and legs start
failing on the expansion budget (measured on barracuda: 81/90 nets routed and 19
DRC violations became 61/90 and 257). Ordering is free, so angle discipline can
never trade away a routed net. Arcs on `(max-freq …)` nets are the deliberate
exception and are owned by placement/bend-smooth.

`axisElbows` and `turnedAlways` are the axis-only halves of that pair, used by
the RF Manhattan attempt (placement/manhattan-route) and by nothing else.
`axisElbows` drops the 45° leg, leaving the two L corners — same equal-length,
degenerate-on-an-aligned-pair contract as `elbows`. `turnedAlways` is `turned`
without the corridor gate, because a search that BUYS a corner has to see the
one it is buying; silencing it there would produce the staircase the gate exists
to avoid, not preserve a pinned shape. That the RF attempt prices a corner at
all is not a reversal of the measurement above: the regression came from pricing
bends on every net's search, while this price is paid only by the few `(max-freq
…)` nets of a board, on the wider targeted expansion budget an escape-shaped net
already gets, and an attempt that exhausts it costs nothing — the ordinary
ladder then routes the net exactly as it did before.

- judges the eight octilinear headings compliant and an off-axis heading not
- judges a degenerate segment compliant so a join stub is never reported as off-axis
- distinguishes horizontal and vertical runs from diagonal octilinear copper
- both elbow connections are octilinear on each leg and equal in total length
- an already-octilinear pair degenerates to a single run with a zero-length leg
- a compass fan quantizes an arbitrary preferred heading onto the axis-referenced 45 degree multiples
- the join seam emits one straight run for a compliant pair and a two-segment elbow otherwise
- the join seam falls back to the direct segment when neither elbow clears so connectivity is never lost
- a pad pair leaves both centres along their outward horizontal or vertical axes before joining
- a single pad escape tries longer outward axis runs when its nearest join is blocked
- a heading change is counted as a turn while a straight continuation and a via are not
- a corner priced as search cost is counted even on a leg whose corner tie-break is suppressed
- the axis-only elbow pair offers both L corners and degenerates on an already-axis-aligned pair
- completeness-waiver: empty inputs (a zero-length pair has no heading: judged compliant, and its elbows collapse onto the shared point)
- completeness-waiver: large inputs (both functions are O(1) closed-form arithmetic over two points)
- completeness-waiver: unauthorized access (pure geometry inside the router; endpoint access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk or socket — inputs are two coordinate pairs)
- completeness-waiver: concurrent access (stateless pure functions over immutable inputs, returning by value)
- completeness-waiver: malformed encoding (inputs are f64 coordinate pairs; degenerate geometry is handled explicitly, never errors)
- completeness-waiver: integer overflow (no integer arithmetic — coordinates and residuals stay f64)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/manhattan-route

Public functions: State, stateFor, attempt, axisStub, turn_cost_mult

The axis-only first rung of the per-net ladder, taken by `(max-freq …)` nets and
by nothing else. The ordinary maze moves on eight headings, so an RF trace
through a dense board arrives as a meander of short 45° facets — each one an
impedance discontinuity, and each one a corner the bend smoother has to fillet
with a radius it has no room for. A hand router draws a few long straights
meeting at square corners instead, spaced far enough apart that every corner can
carry a wide arc.

The rung reaches for that shape in two tiers. The DIRECT tier draws a
two-terminal, single-layer net between its pad CENTRES with no lattice anywhere:
one straight run when the pads are near enough to collinear, else one square
elbow of two full-length legs, bending late so the copper leaves the first pad
along the long leg and turns in open space (a declared pad escape axis overrides
that ordering). Geometry is what makes the bend smoother work — its per-corner
budget is a function of the neighbouring segment lengths, so a corner between two
long clean legs opens to a wide sweep while the same corner between
lattice-quantized fragments starves — which is why the tier joins the pads
exactly rather than through the raster. The straight is the one place an RF net's
copper may leave the compass, bounded to a perpendicular offset no wider than the
trace itself: squaring up a sub-width misalignment produces a pair of facets
inside the trace's own width, which is worse copper than a hair-off-axis line and
is not something a bend radius can rescue. It reaches the finished board intact
for two reasons worth naming, since either later pass could have eaten it: a
whole-net straight is a two-point chain, which placement/straighten returns
untouched before any of its octilinear gates apply; and the pad-escape post-pass,
which would otherwise re-anchor both ends onto the pads' outward axes and produce
exactly the facet pair this removes, skips any net carrying a declared escape
reserve — which every resolved `(max-freq …)` class does. Measured both ways on a
3 mm / 0.06 mm pair: one segment with the reserve, three without it.

The MAZE tier takes everything the direct tier cannot draw — multi-drop trees,
pairs needing a via to change layer, and any pair whose straight and both elbows
are blocked — and is where the rest of the discipline lives: the maze expands
only its four axis neighbours, every heading change is priced at
`turn_cost_mult` grid pitches, and an off-grid pad centre joins the raster
through the axis L (`axisStub`) rather than the axis-then-45° elbow.

The corner price is load-bearing rather than cosmetic. On an axis lattice every
monotone path between two nodes has the SAME length, so with no price the search
would settle on an arbitrary staircase — strictly worse copper than the meander
it replaced. It is sized as a preference, not a wall, so a boxed-in net can still
turn as often as it must.

Vias, layer masks, budgets and every clearance oracle are untouched: the attempt
narrows which shapes are reachable and nothing else, and an accepted route lands
through the same terminal-tree seam as any other. `attempt` is transactional —
no path, a pad it cannot join on the axes, an oracle refusal, copper that came
out off-axis anyway, and a closure that only happened by running far past the
net's own span all roll back whole (copper, occupancy, the authored waypoints,
the partial-tree flags, the search-limited report), and the pre-existing ladder
then runs on exactly the state it would have seen. It also declines outright
wherever something else already owns a leg's shape: a differential pair's
constructed centreline, a coupling or reference corridor, or an authored
guide-branch tree whose per-drop corridors this rung cannot walk.

Plain `(waypoints …)` deliberately do NOT refuse it. On barracuda those were
authored by earlier ROUTING campaigns as a means to a clean shape — the
`lo-drive-rounded` wave asks in its own words for "one remote elbow with long
horizontal and vertical arms, leaving enough tangent length for the full RF bend
radius", which is this rung's native output — so honouring the letter of the
guide while ignoring its purpose would be the wrong reading. The attempt clears
them for its own span and restores them on every exit, since the ladder below
still owns them if it declines. A `(guides …)`/`(branches …)` tree is refused
even when a two-terminal net lowers it to a waypoint chain: the author asked for
a tree, so the policy is read rather than its lowered form.

Both acceptance tests are POST-HOC measurements of the finished copper rather
than search terms — the properties are stated about a route, and a refusal is
free. The second one, the detour budget, exists because square corners are worth
buying only while the trace stays near its own span: an accepted route may lay at
most 1.5× the Euclidean minimum spanning tree of its terminals, √2 rounded up,
because a single-corner L costs at most √2 times the line it replaces (exactly
that, for the perpendicular equal-arm elbow). Measured on barracuda: `RF1_HPF`, a
0.61 mm hop, closed axis-only at 1.78 mm by going the long way around an
obstacle — 2.9×, and refused now.

- an RF net routes on horizontal and vertical runs alone, while the same board without the class keeps its diagonals
- the axis-only search buys long straights instead of a staircase of ninety degree corners
- a near-collinear RF pair is drawn as one straight run rather than squared up into facets inside its own trace width
- a sub-width-offset RF straight reaches the finished board as one segment, while the same geometry without the class is re-anchored into facets
- an offset RF pair is drawn as one square elbow of two full-length legs, so the bend smoother has room to open the corner
- an offset RF pair bends late, leaving the first pad along the long leg and turning in open space
- an RF pair whose straight and both elbows are blocked falls through to the maze tier and still routes
- a cross-layer RF pair skips the direct tier, since one segment cannot change layer
- a declared pad escape axis decides which elbow an RF pair tries first, and a sub-width offset is drawn straight
- a direct shape that cannot give a declared escape reserve its straight run is not drawn at all, leaving the reserve to the maze tier
- a plain waypointed RF net takes the axis attempt and its waypoint goes unused when the attempt closes
- a declined axis attempt hands its net back to the waypoint machinery with the authored waypoints intact
- an authored guide-branch tree still owns its RF net's shape and refuses the axis attempt
- an axis closure that only exists as a long detour is declined, so a short RF hop is never lengthened to keep its corners square
- the detour budget admits a clean elbow and refuses a route that runs far past its own span
- declaring RF discipline never costs a board a routed net, because a declined axis attempt rolls back and the ordinary ladder runs unchanged
- a differential pair member, a pinned corridor, an authored guide and a plain net are all refused the axis-only attempt
- a corner costs the axis-only search four grid pitches and every other route the ordinary octilinear nudge, with a shape-pinned leg paying nothing
- the axis join emits an L only when both legs clear and reports failure rather than falling back to a diagonal
- an accepted axis-only route is measured for the off-axis copper its join seams can still emit
- completeness-waiver: empty inputs (a net with no declared max-freq, an empty pair table and a route that laid no copper are each the ordinary decline path, asserted above)
- completeness-waiver: large inputs (the attempt adds no unbounded work — it runs the router's own terminal tree under its existing per-leg expansion budget, and the axis scan is one pass over the copper that one net just laid)
- completeness-waiver: unauthorized access (pure routing geometry inside the placement engine; endpoint access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk or socket — inputs are the live route context and one net's terminals)
- completeness-waiver: concurrent access (one net's turn at a single-threaded route context; the flag is set and cleared inside one attempt and never outlives it)
- completeness-waiver: malformed encoding (inputs are typed placement/router structs, never parsed bytes — there is no encoding to malform)
- completeness-waiver: integer overflow (the only integer arithmetic is a 0/1 turn count widened to f64; coordinates and costs stay f64)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/net-topology

Public functions: landRun, padJoin, sourceCost, connectOrder

Where a multi-pad net's own copper MEETS itself. A net of three or more pads is
routed as a small tree of pad-to-pad edges, and a pad taking two edges is the
tree's branch point. A hand router draws a CHAIN there — the copper runs from
one pad to the next and the branch point IS a pad, because a pad is solid metal
and joining on it costs nothing. This router drew a TRUNK instead: the
outward-axis escape join (placement/octilinear `padPair`) leaves BOTH terminals
along their component-outward face before joining, so two edges sharing a pad
both left through its single escape point — one trace half-width outside the
land — and the run onward went with them, straight down the lane in front of
the pad faces, tapping each land sideways with a stub. Measured on
straps-synth-lmx2595 (2026-08-11): `LMX_RFOUTAM` left R6 pad 2 westward at
x = 3.8565, 0.063 mm off its land, and ran the full height of R6's and R7's
west faces.

The outward escape is right for a pad reaching open board — it is what keeps
copper out of a neighbour's escape lane. It is wrong for the one case this
module names: two pads whose LANDS face each other across open board, where the
straight run between them is shorter than any escape route, needs no bend, and
terminates on solid copper at both ends. `landRun` builds exactly that and
nothing else, and `padJoin` falls straight back to the escape join whenever it
does not apply — a blocked run, lands that barely overlap, lands not a run
apart, a hop past `land_run_max_mm`, or a leg whose shape is already pinned by
an RF straight reserve or a diff-pair corridor.

The maze reaches the same picture from the other side: a leg seeds from every
node its net's copper already owns and stops at the first one it reaches, which
near a pad is that same escape lane. `sourceCost` prices those seeds — free on
the net's own pad copper, `midspan_join_penalty_mm` anywhere else — so a
mid-span join stays legal (a free-space junction really is the shorter tree
sometimes, and hand routes carry them) but has to be at least that much shorter
than the pad-terminated alternative. `connectOrder` is the third piece: a net's
terminals are walked closest-pair-first, nearest-to-the-tree after, so the legs
being joined are neighbourly hops to begin with.

- two same-net pads whose lands face each other across open board join with one straight run terminating inside both, not through their outward escape points
- a land run offset from both centres sits on a line inside both lands, so each end still terminates on solid pad copper
- a land run blocked by foreign copper falls back to the outward-axis escape join rather than being drawn through it
- an escape-ruled or coupled leg never takes a land run, so RF and diff-pair copper is unchanged
- two lands sharing less than a trace width across the run keep the escape join, so a run is never drawn tangent to the copper it ends on
- a land run longer than land_run_max_mm keeps the outward-axis escape, so only a neighbourly hop leaves a pad through a side face
- overlapping lands are not a run apart and keep the escape join
- a three-pad net whose two passives stack on one edge crosses the gap between their lands on the lands' own band, not down the escape lane in front of both faces
- a maze leg starts free on its net's own pad copper and pays the mid-span margin to start anywhere else, so a join standing in front of a pad lands on it instead
- a leg whose net offers no pad land prices every source at zero, leaving that search byte-identical
- a net's terminals are connected closest pair first and then nearest to the tree, so the route grows as a chain of neighbourly hops
- completeness-waiver: empty inputs (coincident terminals are no run at all: `runAxis` returns null and the escape join answers)
- completeness-waiver: large inputs (a join is O(1) arithmetic over two pad boxes plus at most three clearance probes; a source is priced against the net's own land list, and the connection order is the O(terminals squared) walk a net's handful of pads has always paid)
- completeness-waiver: unauthorized access (pure geometry inside the router; endpoint access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk or socket — inputs are two pad terminals and the caller's probe)
- completeness-waiver: concurrent access (stateless pure functions over immutable inputs, returning by value)
- completeness-waiver: malformed encoding (inputs are typed pad terminals; degenerate geometry is refused, never errors)
- completeness-waiver: integer overflow (no integer arithmetic — coordinates stay f64)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/straighten

Public functions: pass, passBoard, glossHop

Post-route simplification "gloss". After routing finishes (greedy + rip-up +
the escape/stitch post-passes) each routed signal net's polylines are simplified
against the finished board in four stages: direct-first (collapse a same-layer
subpath to one endpoint-to-endpoint segment when it clears), corner-cutting
(drop every interior vertex whose A—C shortcut clears, to a fixed point via
bounded forward sweeps), re-elbow (rewrite each surviving staircase as the
two-segment octilinear elbow spanning it, longest span first), then chamfer
(cut each surviving right-angle corner with the largest clearing 45° diagonal).
The public `pass`, lattice whole-board seam, and finishing-hop seam are
octilinear-preserving: stages 1 and 2 refuse any replacement that would leave
the eight H/V/45 headings, stage 3 constructs its replacement from
`placement/octilinear` elbows, and stage 4 cuts equal lengths off two
perpendicular arms. The continuous field whole-board seam deliberately skips
the octilinear gate and re-elbow stage so its exact-clearance chords remove the
last raster/lattice quantization detours; pad terminal legs, via pins, escape
reserves, connectivity, and exact clearance remain hard constraints. A right
angle is the one shape stages 1–3 cannot reach — its A—C shortcut is off-axis
unless the arms happen to be exactly equal, and the re-elbow stage only spans
three segments or more — so without the chamfer every square corner the maze
leaves survives onto the finished board. The chamfer's cut is maximal by
default, which turns a one-grid-step jog between two long runs into a single
diagonal; a blocked cut halves until it fits, and a corner with no room stays
square. No stage moves copper off a via the net's run passes through (a mid-run
stitch), which would strand the copper hanging off its other layer. Stages 1–3
reduce segment count and stage 4 spends up to one vertex per corner; none of
them in lattice mode trades the board's angle discipline for a shorter line — the maze search
already emits octilinear paths (its 8-neighbour lattice can express nothing
else), so the discipline holds whether or not this pass finds anything to do,
which is what keeps it safe on a tight board where the shortcut probes are the
first thing to stop clearing. Clearance is judged by the
router's DRC-grade segment probe (pads, vias, foreign tracks, zones/keepouts,
board outline).
Running after all routing means no later net can crowd a taut off-grid segment
(the grid-vs-off-grid clearance gap of an inline pass), so the pass can only
hold trace count flat or reduce it, never add a DRC violation. Chain endpoints
never move, so connectivity holds. Escape-ruled nets (every `(max-freq …)` net
by default) keep every corner-cut vertex inside a pad end's straight reserve,
and take the direct collapse only when the single segment still leaves each pad
along its outward escape axis (the net's `PadExit` list) — the segment then IS
the escape line. Ordinary pad anchors likewise keep their first and last H/V
legs through direct collapse, corner cutting and re-elbowing, and keep a
straight run of them through the chamfer: the corner NEXT to a pad is cut, but
only down to a reserve, so the copper always leaves its pad on one heading
before the miter starts. Refusing that corner outright — which is what the pass
used to do — meant refusing nearly every corner there is, since a short hookup
leaves the maze as pad → axis escape → one perpendicular run → pad, three points
whose single corner is adjacent to both ends. An arm shorter than the reserve
keeps its right angle. A
straightened `(max-freq …)` net gets its arcs rebuilt on the
taut polyline and its per-net arc metadata refreshed. That rewrite is
transactional: if the shorter centreline introduces an under-floor bend or
reduces the net's minimum achieved arc radius, the pre-finish RF copper and
metadata survive unchanged. Diff-pair legs are skipped
in v1. `straighten.pass` returns the replacement copper on change, else null.

The pass reaches the board through THREE seams, and the copper that misses one
of them is exactly the copper that keeps its staircases. `passBoard` runs it
over a whole finished board (the router's finish). It runs again AFTER the
post-route cleanup passes, because those rewrite geometry the first run had
already finished with — a collinear collapse replaces a whole staircase with a
through-line, a net-open closure bridge lands square — so the corners they leave
would otherwise never meet the chamfer. And `glossHop` runs it over ONE
finishing hop inside the gap-closing pass, which routes long after the finish
and would otherwise put raw lattice copper onto a nearly-done board: a
shallow-angle finishing hop comes out of the maze as dozens of alternating
one-cell steps where one 45° diagonal plus one axis run is the answer. A hop is
glossed against the live board plus itself, with the copper the hop ripped
already taken out, so the judgement is made against the metal that will actually
be there; its endpoints never move, so the caller's accept gate sees a hop that
is exactly as connected as it was routed.

A chamfer does not require its two arms to be octilinear, only that the CUT is:
a routed corner can sit a degree or two off square when one arm is the join stub
onto an off-grid pad centre, and refusing those leaves square corners on the
board for a property already lost upstream. The chord's heading is fixed by the
arm directions alone, so one octilinear test on it settles every cut length —
and it is what bounds the corner tolerance, since a corner far from square
yields a chord too far from 45° to pass. A cut narrower than a trace width is
refused outright: it is invisible at fab resolution and spends two vertices.

- the straighten pass collapses an unobstructed multi-segment hop to one direct segment
- the straighten pass corner-cuts a removable staircase vertex and keeps one whose shortcut is blocked
- the straighten pass refuses a shortcut that would leave the octilinear headings
- ordinary pad anchors keep their horizontal or vertical terminal legs through every simplification stage
- the re-elbow stage rewrites a surviving staircase as a two-segment octilinear elbow
- the straighten pass keeps an escape-ruled net's near-pad vertex inside the straight reserve
- an escape-ruled net goes fully straight only when the direct line leaves both pads outward
- the straighten pass leaves a diff-pair leg untouched
- the straighten pass returns null when a net has no removable corner so the router keeps its maze copper
- finish-time RF gloss never trades a clean inline bend for a smaller-radius or under-floor bend
- clamps the escape reserve to a third of a short hop so its middle jog straightens
- the chamfer stage cuts a surviving right-angle corner with the largest clearing 45 degree diagonal
- the chamfer stage halves a blocked corner cut until it fits and leaves the corner square when none does
- no simplifier stage moves copper off a via the net's run passes through
- a finishing hop's lattice staircase is glossed to one 45 degree diagonal plus one axis run
- the hop gloss keeps a hop's endpoints exactly and hands back a hop with nothing to simplify verbatim
- the chamfer cuts a corner whose arms sit slightly off-axis, and refuses one whose cut would not be a 45 degree diagonal
- the chamfer cuts the corner next to a pad terminal but keeps a straight run leaving that pad, and refuses an arm shorter than the reserve
- the chamfer refuses a cut narrower than a trace width rather than spend two vertices on it
- re-emitting a simplified chain of fewer than two points draws no copper instead of panicking
- completeness-waiver: empty inputs (a net with no fresh tracks or one straight run returns null — the already-straight test's case)
- completeness-waiver: large inputs (linear over the net's segment count; corner-cutting is bounded to a few forward sweeps over a short routed chain)
- completeness-waiver: unauthorized access (a pure geometry pass inside the router; endpoint access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk or socket — inputs are in-memory routed copper, resolved net rules, and a clearance probe)
- completeness-waiver: concurrent access (a pure function over immutable inputs into per-call arena-owned slices; the caller serialises copper mutation)
- completeness-waiver: malformed encoding (inputs are typed router structs; degenerate/collinear geometry is dropped, never errors)
- completeness-waiver: integer overflow (counts are slice lengths; sweeps are bounded by a small constant; coordinates stay f64)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/pad-entry

Public functions: trimHead, passBoard

Single-point pad entry — how much copper a route leaves lying ON the pad it
terminates at. Every terminal is anchored at its pad's centre (or the clearest
interior site found there) and the escape leaves along the pad's outward axis,
so on a land longer than it is wide — a 0.5 mm-pitch QFN pad, a 0402's
rectangle — the copper runs the pad's whole half-length before it reaches open
board. Electrically that is nothing (a track anywhere on the land is the same
node); visually it is a lap joint, reading as a trace alongside the pad rather
than into it, and saying nothing about which point of the pad the route serves.

The pass trims each such entry back to ONE crossing of the pad outline plus a
short stub inside it. It only ever removes copper, and only from a chain's pad
end, which is what makes it safe at the very end of the finish: shortening a
segment can only remove approaches, so it cannot create a clearance violation;
the surviving end still carries a full trace-width cross-section on the pad's
real copper — checked against the pad's outline, not just its bounding box —
which is what the connectivity oracle's pad↔track union reads as a robust land
entry; and
a via inside the span a trim would remove refuses that end, since dropping
copper off a via would strand everything hanging off its other layer (a via at
the chain's FAR end is no reason to leave this end's lap in place, and a via
standing on the pad's own land keeps its join through the land itself). A chain
every vertex of which lies on one pad's land is dropped outright rather than
trimmed: it joins nothing the solid land does not already join, so it is a
failed escape attempt drawn along the pad, which is the picture the pass exists
to stop. Through-hole pads
are out of scope (the barrel is the connection, so copper across the annulus is
not a lap), as are `(max-freq …)` escape-ruled nets, whose straight reserve is
measured from the pad anchor, and diff-pair legs, where trimming one leg alone
would decouple the pair. Nets outside a scoped route's selection are left
byte-identical.

It runs LAST in the finish, after the closing gloss, because it is the one pass
whose result the others would undo: the straighten pass reads a chain's pad end
as a fixed anchor and would re-straighten copper back across the land it was
just taken off.

- a route that runs the length of its pad is trimmed to one outline crossing plus a short stub
- an entry already shorter than the stub keeps its copper byte-identical
- a trimmed entry keeps its end on the pad's real copper, refusing the trim when a rounded land would not hold it
- both ends of a pad-to-pad hop are trimmed, and a via off the land inside the span a trim would remove pins that end while one on the land does not
- the trim never lengthens a route and never moves copper that is already outside the pad
- copper lying wholly on one pad's land is dropped rather than trimmed, since the land already joins whatever it touches
- completeness-waiver: empty inputs (a chain with no pad end, or one already inside the stub, returns null and the copper is echoed verbatim)
- completeness-waiver: large inputs (linear in the net's segment count; each end walks its own chain once)
- completeness-waiver: unauthorized access (a pure geometry pass inside the router; endpoint access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk or socket — inputs are in-memory routed copper and pad outlines)
- completeness-waiver: concurrent access (a pure function over immutable inputs into per-call arena-owned slices; the caller serialises copper mutation)
- completeness-waiver: malformed encoding (inputs are typed router structs; degenerate geometry is dropped, never errors)
- completeness-waiver: integer overflow (counts are slice lengths; coordinates stay f64)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/pad-escape

Public functions: passBoard

Pad-escape discipline — how generated copper LEAVES the pad it connects to.
The rule, in the board owner's own words: within 0.15 mm of a pad the copper
must be a SINGLE trace on a 45-degree increment, and from the CENTRE of the pad
there must be a trace on one of those headings escaping out of the land to at
least 0.15 mm beyond its edge; past that point the route is unconstrained. So
every connection to a pad is one straight ray, anchored on the pad's own centre,
on one of the eight compass headings, running until it is clear of the land —
no bend, no branch, no second trace inside that zone.

It supersedes the OPPOSITE convention `placement/pad-entry` used to own — the
trim that kept at most a short stub of copper inside the land — but not its
prohibition, because a centre-anchored 45-degree ray is by construction not a
lap joint: it crosses the outline exactly once, radially, and it is the only
copper of its connection inside the land. The two are ONE ladder: the lap trim
runs first (it also drops copper lying wholly on a land, which joins nothing the
solid pad does not), then this pass re-anchors what it can. An end that cannot
be made compliant keeps the earlier rung's geometry and is counted as a
fallback: the rule may never cost connectivity, so the pass only ever writes
copper it has probed at DRC clearance, and refuses the whole end otherwise.

Nothing the old copper carried may be left behind by the new: every via it
touched and every junction with the rest of the net must still be touched after
the rewrite, and a ring of copper (duplicated segments, whose two ends are one
point) is left alone entirely. SMD lands only — a through-hole pad's barrel is
the connection on every layer, so copper across the annulus is not an escape to
discipline — and `(max-freq …)` escape-ruled nets keep their own authored,
longer straight reserve. A declared differential pair is rewritten pairwise,
never leg by leg: both legs take the same heading and the same escape length at
each end, the clearing candidate that leaves the legs closest in length wins,
and a pair whose rewrite would spend skew keeps the copper it has.

WHICH heading a pad leaves on decides whether the connection bends at 45 degrees
or at 90, and the heading the maze happened to leave on is axis-aligned because
a lattice step is. So the fan is not taken first-clear: every heading, and
rejoining the route past the maze's own first bend when that bend is lattice
noise sitting on the ray's exit, is built and the candidate leaving the fewest
square corners wins, then the fewest TOTAL bends, then the shortest, then the
lowest fan index. A vertex far
enough out to be some earlier pass's routing decision is never skipped. Only candidates within the mitre budget of the shortest
compete, so a mitre is bought with a bounded amount of copper and never with a
detour. Every candidate is the same probed, via-safe, junction-safe rewrite the
pass always emitted; only which of them is kept has changed.

The fan's own width is the other half of that choice. It is centred on the
heading the maze left by and reaches only the forward five, because a heading
pointing back past the pad is not an escape — while the copper it is centred on
is going somewhere. When it is NOT, the centre is the thing that is wrong: a
chain whose own second leg turns more than 90 degrees off the first left its pad
the wrong way, which is the shape a free gateway ring used to buy the maze. Such
a chain opens the fan to all eight headings, measures the "no ray can serve this
hop" test against the shortest escape any of them asks for rather than the
suspect heading's own, and lets the reversal rejoin the route past the wrong-way
stub it undoes — the same lattice-noise budget, read radially rather than from
one point on the ring, and never past a vertex the new ray is heading towards.
Nothing else changes: the widened candidates are scored and budgeted exactly like
the rest, so a well-formed escape sees the same five headings in the same order.

Total bends is the second key because square corners alone do not separate the
two shapes a reader tells apart: an escape leaving on the maze's heading and then
mitring turns one 45-degree corner where the same connection escaping toward its
partner turns none, and both score zero square corners, so the tie fell to the
lowest fan index — the maze's own heading.

Compliance is an ENTRY to that comparison, not an exit from it. An end can obey
the rule and still draw the connection badly: a legal ray aimed away from the pin
it serves turns 90 degrees the instant it is clear of the land, which was half of
the corpus's surviving near-pad right angles. So the copper an end already
carries joins the fan as the candidate to beat — first in the list, so it wins
every tie, and exempt from the mitre budget, because keeping what is already on
the board spends nothing — and is replaced only by a candidate that strictly
beats it and clears every guard. Scoring runs to convergence, which is what makes
the pass a fixed point rather than a step towards one. Because a chain does not
only end on pads — a daisy chain threads THROUGH the lands between its ends, and
the direct line between those ends is shorter and straighter — every same-net
land the old copper covered must still be covered by the new, exactly as its vias
and junctions must.

The other side of that coin is which lands the new copper may TOUCH. Re-aiming a
chain's far end may rejoin one vertex further along and so redraw the near end's
escape too, and a diagonal that clips the near land's corner turns one corner
where the disciplined ray turns two — so the corner-count score actively prefers
it. One end at a time is structurally not enough when the connection's shape is
decided by BOTH reaches at once: a pin escaping straight out of its land and a
cap escaping on the diagonal are each compliant, and the jog between those two
legal rays can only meet the straight one at a right angle. So a SHORT chain
whose two ends both terminate on their own lands is also planned end to end —
every compass heading at each end, the octilinear join between the two exits,
scored by the same keys — and taken only when it strictly beats what the
per-end passes left. Enumerating the whole compass rather than a fan around the
copper it is handed is what makes that plan a fixed point: run again it
enumerates the identical set and ties with itself. It is a full redraw, so it is
fenced to a hop rather than a route, held inside the mitre budget, probed leg by
leg, and refused by every guard the single-ended path obeys.

How many same-net lands a candidate DIRTIES that the copper it would replace
left clean (see `placement/land-transit`) is therefore the score's first key,
ahead of every corner term: copper in the corridor between two pins is worse
than a corner. It is a key rather than a refusal because when every candidate
laps something a refusal leaves the end with what it has, corners and all, while
a key still takes the best of a bad set — and because the copper an end already
carries always scores zero there, so a clean end is never traded for a
square-free lap. The count is measured against the old copper, so an end that
inherited a lap can still be improved.

- a connection to a pad is anchored on the pad centre and leaves it straight on a 45 degree heading until it is clear of the land
- copper that already leaves the pad centre straight and clear competes as the candidate to beat and is kept byte-identical unless something strictly better clears
- an entry that bends before it is clear of the land is not compliant, and neither is one on an arbitrary heading
- the escape reach is measured to the land's own edge on the heading it leaves by, plus the clearance
- an escape whose straight-on heading is blocked swivels to the next compass heading rather than giving up
- a blocked escape falls back to the copper it already had rather than costing the connection
- a connection shorter than the escape the rule asks for keeps the copper it has
- both ends of a pad-to-pad chain get their own escape ray
- a rewrite never leaves a via the old copper carried, so re-anchoring cannot abandon a barrel
- a rewrite never drops a junction the old copper carried, so no re-anchor can open a net
- a ring of copper has no ends to discipline and is left exactly as it is
- both legs of a differential pair take the same escape heading and length at each end, so the rewrite cannot add skew
- a differential pair keeps its old copper unless the rewrite can be drawn without spending skew
- the escape is chosen for the connection it draws, so every fan heading and rejoin point is built and the candidate leaving the fewest square corners wins
- an escape may rejoin the route past the maze's own first bend when that bend is lattice noise sitting on its exit, and never past a vertex far enough out to be a routing decision
- a heading wins on corners only while its copper stays within the mitre budget of the shortest candidate, so a mitre is never bought with a detour
- headings tied on square corners, total bends and length resolve to the lowest fan index, so the escape choice stays deterministic
- an escape that is already compliant still competes against the whole fan, so a legal ray aimed the wrong way is re-read instead of waved through
- the score counts total bends after square corners, so an escape that draws the connection straight beats one that leaves on the maze's heading and then mitres
- the pass is a fixed point, so running it again over its own output rewrites nothing
- a rewrite never drops a same-net land the old copper covered, so re-aiming an escape cannot strand a part daisy-chained between the ends
- lapping a same-net land the connection does not serve is the first key of the escape score, so no number of corners saved buys copper into a pad's flank
- a short chain whose two ends both sit on lands is planned as one shape, so a jog between two legal rays is not forced to meet one of them square
- the joint plan is bounded to a hop and refused whenever it does not strictly beat the copper it would replace
- a chain that turns back on the heading it left the pad by opens the fan to every heading, so a wrong-way escape can be re-aimed at the route it serves
- the fan only opens past its forward headings for a chain whose own second leg turns back on the first, so a well-formed escape is scored against exactly the headings it always was
- a reversal may rejoin past the wrong-way stub it undoes, measuring the same lattice-noise budget radially, and never past a vertex the new ray is heading towards
- an authored (max-freq …) escape reserve outranks this pass, so no widened fan can re-aim an RF net's straight exit
- completeness-waiver: empty inputs (a chain with no pad end, or one already compliant, returns null and the copper is echoed verbatim)
- completeness-waiver: large inputs (linear in the net's segment count; each end walks its own chain once, over a fan of at most eight headings)
- completeness-waiver: unauthorized access (a pure geometry pass inside the router; endpoint access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk or socket — inputs are in-memory routed copper and pad outlines)
- completeness-waiver: concurrent access (a pure function over immutable inputs into per-call arena-owned slices; the caller serialises copper mutation)
- completeness-waiver: malformed encoding (inputs are typed router structs; degenerate geometry is dropped, never errors)
- completeness-waiver: integer overflow (counts are slice lengths; coordinates stay f64)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/land-transit

- An offending segment can be split locally into centre-anchored rays with no remaining own-land offence.
- Board cleanup reaches a fixed point with every selected same-net land crossing centre-anchored.
- Adjacent same-net lands are repaired as one centre-to-centre cluster so their individual anchoring cannot oscillate.
- An offending on-land junction snaps all of its same-net branches to the land centre together, preserving the junction.
- A hierarchical route seed carrying a same-net land transit is rejected before the assembled-board router can reuse it.
- A hierarchical route seed is centre-anchored through same-net lands before board acceptance and remains rejected when the normalized copper is not DRC-clean.
- Authored exact bypass paths are immutable at the aggregate seed gate, so nearby same-rail lands cannot retarget their endpoints.
- An axis-aligned run whose swept copper stays inside the land's own column and reaches a segment end there is the pad's connection, not an offence; a column-contained fly-through, a flank lap, and every diagonal stay judged by the strict ray rule.

Public functions: offence, segmentOffence, worsens, onLand

Copper of net X lying on a net-X pad it is not CONNECTING to. Electrically it is
nothing — a track anywhere on a land is the same node, and every clearance rule
stays silent because the two objects share a net — but the copper that laps a
land has to come from somewhere and go somewhere, and on a fine-pitch part the
only route out of a land's flank is the fifth of a millimetre between it and its
neighbour. Half a trace width parked in that corridor is solder-bridge bait, and
it was invisible to every existing check: the lap trim removes copper lying
WHOLLY on a land and the escape discipline governs the ray a connection LEAVES
on, but neither has an opinion about a run that merely crosses a land on its way
past.

The rule: net-X copper may touch a net-X land only as that land's own
connection, and a connection is anchored on the pad's centre. So a run of copper
inside a land is legal exactly when it lies on a straight ray through that
centre — every vertex strictly inside the run is at the centre, every segment the
run covers is aimed at the centre, and the run either contains an end of the
copper or contains the centre itself. The aim test is on the segment's LINE
rather than on its end point because the lap trim deliberately stops a terminal
short of the middle of the land, which is still on the ray.

The measurement is on SWEPT copper — centreline plus half the track width —
because the corridor cares where the metal's edge is, not where its middle is: a
leg whose centreline runs exactly along a land's boundary scores zero overlap on
the centreline and puts a full half-width beside the pad. Through-hole pads are
out of scope, as they are for the lap trim and the escape discipline, and so is
a land larger than the paddle threshold in both axes: an exposed thermal paddle
is not entered on a ray and has no flank corridor of its own.

- a centre-anchored ray that leaves a land once is not a finding, trimmed back to a stub or not
- copper that turns while still beside a land is a finding, measured by how far the corner misses the pad centre
- copper that laps or transits a land it does not terminate on is a finding even though it is the same net
- an exposed thermal paddle is out of scope, since nothing anchors on its centre and it has no flank corridor
- a rewrite is refused only when it dirties a land that was clean, so inherited overlap never freezes an improvement
- completeness-waiver: empty inputs (a polyline of fewer than two points, or one that never reaches the land, has no run to judge and returns null)
- completeness-waiver: large inputs (linear in the polyline's segment count; each segment is clipped against one land box once)
- completeness-waiver: unauthorized access (a pure geometry predicate inside the router and the DRC; endpoint access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk or socket — inputs are in-memory copper and pad outlines)
- completeness-waiver: concurrent access (a pure function over immutable inputs into per-call arena-owned slices)
- completeness-waiver: malformed encoding (inputs are typed coordinate pairs; degenerate geometry is dropped, never errors)
- completeness-waiver: integer overflow (counts are slice lengths; coordinates stay f64)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/via-centre

Public functions: passBoard

Via-in-pad discipline — where a barrel standing on a same-net land belongs, and
what copper it makes redundant. The rule, in the board owner's own words: a via
being made in a pad is placed in the CENTRE of that pad unless something else
obstructs it. Those two halves are one idea seen from its ends — a via in a land
is the pad's connection to the other side, so it belongs where the pad's
connection belongs, and once it is there the copper that used to reach it from
the centre has zero length and stops existing. That is the answer to the second
half of the same report: a pad whose net continues only through a barrel on its
own land needs no surface stub on either face, because a centred barrel leaves
none to draw.

It is a POST-PASS over the finished via list rather than a rule inside each
emitter, and deliberately so. A dozen places put a barrel down — the plane
stitcher's grid-snapped pad anchor and its in-pad ring walk, the maze's layer
change (a grid NODE, so off-centre by construction), the direct-hop lattice, the
escape-stub fan, the zone via-in-pad drop, hand copper through `add_tracks` —
each with its own reason for the coordinate it picks. Asking the question once
over the finished list is the only version every emitter obeys, and the only one
the client-side DRC, the Gerber and Excellon writers and KiCad sync agree with
for free, since all of them read that same list and none re-derives a via site.

It may never cost connectivity or clearance, so a move is refused unless the
target sits on the pad's real copper, the barrel clears every foreign pad, via,
track and drill there, every leg that ENDED on the old barrel still probes clear
re-anchored on the new one, and every same-net track that merely TOUCHED the old
barrel still touches the new one or touches the land itself. A refusal keeps the
via exactly where it stood. Through-hole pads, declared differential pairs,
`(max-freq …)` escape-ruled nets and any net outside a scoped route's selection
are out of scope.

- a barrel standing on a same-net land is sited on that land's centre
- a through-hole pad is never centred on, since its own barrel is already the connection
- a leg terminating on a barrel travels with it, so centring re-anchors it rather than breaking it
- a chain both of whose ends lie on one same-net land, touched by nothing off that land, is copper the land already provides
- redundant land copper is dropped only where a same-net barrel stands on that land, and only while the chain stays local to it
- a differential pair leg is never re-sited, so a matched pair's skew survives the pass
- an authored exact bypass rail is in scope, and its net transaction rolls back a drop that leaves one of its bonds no longer closing
- completeness-waiver: empty inputs (a board with no via, or none standing on a land, moves nothing and returns)
- completeness-waiver: large inputs (linear in vias times the net's own copper; each net's chains are extracted once per layer)
- completeness-waiver: unauthorized access (a pure geometry pass inside the router; endpoint access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk or socket — inputs are in-memory routed copper and pad outlines)
- completeness-waiver: concurrent access (arena-owned per-call slices over caller-owned copper; the caller serialises copper mutation)
- completeness-waiver: malformed encoding (inputs are typed router structs; degenerate geometry is dropped, never errors)
- completeness-waiver: integer overflow (counts are slice lengths; coordinates stay f64)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/copper-topology

Public functions: BranchSupport, ViaSupport, RedundancyAnalysis, ImplicitJoin, looseEnd, looseEnds, viaUseCount, viaUseCounts, redundantSections, analyzeRedundancy, analyzeViaRedundancy, implicitJoins, repairableJoins

- a trace end must land on a same-net pad, via, pour, or trace; a free leaf remains loose
- a stored trace section is redundant when deleting it preserves the connectivity of every pad, live via, and poured region
- a redundancy verdict is marked spanning only when the section's component joins more than one support, separating an alternate path from copper that reaches nothing
- separate fabricated fill components on one net and layer never form an alternate route for redundancy deletion
- a redundant-section removal plan considers newest copper first and preserves support connectivity after all planned deletions are applied together
- physical same-net contact does not join route topology unless an endpoint lands on the other centreline
- overlapping round caps remain electrically open until a real centreline bridge gives them a full-width junction
- a trace crossing a same-net land at mid-span electrically supports that land
- a via used by one routed layer is dangling while a second layer, pad, pour, or plane makes it useful
- a ground via backed by its net's authored outer-face pour is not reported as a single-layer routing artifact
- redundant-via pruning preserves every persistent copper component and chooses a jointly safe subset of parallel layer jumps
- a via that is the only robust bridge between persistent copper features is never deletion-invariant
- a via that is the sole support for a trace endpoint remains even when deleting its graph leaf would not split a component
- one shared copper index answers every section's endpoints and every barrel's layer count exactly as the per-feature sweep does
- completeness-waiver: empty inputs (an empty copper list has no endpoint or via to classify)
- completeness-waiver: large inputs (bounded section-deletion walks over the already-bounded routed copper and support lists)
- completeness-waiver: unauthorized access (pure in-memory geometry with no request or persistence surface)
- completeness-waiver: i/o failure (reads typed slices and performs no I/O)
- completeness-waiver: concurrent access (all inputs are immutable caller-owned slices and the module holds no shared state)
- completeness-waiver: malformed encoding (coordinates and net ids have already been parsed into typed routing records)
- completeness-waiver: integer overflow (layer masks are explicitly bounded to 64 routable layers and counts are slice-bounded)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/copper-support

Public functions: Zone, Support, assemble, pourLayers, pourComponent, componentsAt, planeContacts

The ONE assembly of the support context `copper_topology.analyzeRedundancy`
reads. The DRC reports its verdict and the router's finish acts on it; while
each built the record itself the finish deleted a different set from the one the
check named, and copper the check called dead survived every route. Both call
`assemble`, so they can differ only in the zones they are handed — a data
question each caller answers honestly through `Zone.component`.

- one assembly credits pads, tracks, poured trace ends, fill identity, and barrels made live by a pour or a declared plane
- a barrel with no plane contour falls back to the stackup declaration, and exact plane contours override it
- completeness-waiver: empty inputs (no copper and no zone yields an empty support record, unit-tested through the bare reading)
- completeness-waiver: large inputs (point-in-zone reads are bounded by the already-bounded copper and zone lists)
- completeness-waiver: unauthorized access (pure in-memory geometry with no request or persistence surface)
- completeness-waiver: i/o failure (reads typed slices and performs no I/O)
- completeness-waiver: concurrent access (all inputs are immutable caller-owned slices and the module holds no shared state)
- completeness-waiver: malformed encoding (coordinates, net ids and layer indices arrive already parsed into typed records)
- completeness-waiver: integer overflow (layer masks are bounded to 64 routable layers and plane counts saturate)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/drc

- a bottleneck cross-section is judged by the same verdict whether it is found at a trace end, in mid-span, or refused as a flank graze
- a scoped connectivity pass carries the nets one copper edit could not reach and reports exactly what a cold pass over the same board reports
- a pour audit given the placement's retained pad shapes reports exactly what one that builds them per pass reports, and a scoped audit whose fills all held builds none at all
- a surface's measured ring bounds only skip contact tests that could not have found anything, so a boxed surface answers every contact question exactly as an unmeasured one
- the net-open island chain's bounding-box estimate never exceeds the exact nearest approach, so a skipped pair could not have beaten the frontier
- an authored ground-via maximum warns on an SMD ground pad until a same-net plane via falls within the budget
- an optional NC or input-strap land assigned to ground is excluded from the ground-via maximum because its same-package real ground return owns the required plane connection
- a routed power via carrying more than its plated barrel can take is a fab-blocking error naming how many barrels the transition needs
- two parallel same-net barrels that the current solve proves share a load each pass on their own share, with no special case
- an unsolved rail charges every barrel the whole envelope, warning only where the stitched same-net barrels beside it cannot carry it together
- a board that declares no rail current runs no via-capacity solve and reports no barrel findings

Public functions: check, checkTopology, checkWithZones, checkWithPreparedCopper, countKind, defaultSeverity, errorCount

- RF bend findings are reconstructed from submitted or saved copper, not only transient router metadata
- a successful swept RF path suppresses only its internal tessellation vertices, not unrelated same-net corners
- every check stamps its kind's canonical default severity, and each warning kind is proved by a fixture
- reporting DRC reuses its exact cached plane, pour, and user-zone fills when solving local power-track current
- malformed final pour outers and holes are fab-blocking DRC errors
- sibling Gerber clear-hole regions may be disjoint or meet at zero-area tangencies, while proper crossings, positive-area overlap, containment/nesting, malformed rings, and dark-outer contact remain invalid
- final pour overlap checks subtract holes and allow same-net unions
- different-net final pour solids may not overlap or touch on one physical copper layer
- pour overlap compares a zone signal index with a plane's physical stack index
- independently emitted tracks, vias, and signal-layer pads may not contact a foreign final pour solid, while holes and physical-layer separation remain empty
- native routed arc strokes are audited against final pours on outer and inner physical layers, subtract holes, and replace their stored chords
- foreign-pour DRC audits an RF path's exact swept regions and suppresses its compact handles, never replacing a narrow taper end with the widest endpoint capsule
- a wide RF taper is checked as its exact butt-ended sweep, so a short launch land does not acquire a round cap behind its centre and falsely crowd the adjacent pad
- a via beside a variable-width RF path is checked against the exact swept copper, so a legal fence row beside a launch taper is not rejected by conservative max-width chord capsules
- implicit ground fills are one physical carrier and a fill whose boundary construction failed remains invalid even when empty
- a leaf-only net alias is accepted only when unique; sibling flattened nets with the same leaf remain distinct copper
- reporting DRC retains the same exact variable-width RF carve that Gerber computes from the raw route proof
- warns when a signal net's own copper laps one of its pads instead of being aimed at the pad centre, while ground nets are exempt
- reports one own-land warning per physical land — carrying the worst offence measured on it — rather than one per tessellation chord or stored segment
- a hand-drawn chain that laps one land in several stored segments is a single finding carrying the worst miss
- a match group spreading wider than its tolerance warns once, naming the longest and shortest nets
- a match group with fewer than two routed members is reported as unfinished, never as mismatched
- a design declaring no match group produces no measurement and no violation
- two match-group members with equal trace length but different layer hops measure apart
- the fab-blocking error count drops warnings and an open net, which is already the completion term
- flags a via that crowds a foreign pad's clearance
- a foreign via must clear the synthesized RF via antipad, not only ordinary copper clearance
- passes a via that shares the pad's net
- a routed module with a crowded ground pad has no clearance violations
- flags a via whose annular ring is under the fab minimum
- flags copper crowding the board outline and skips the off-board staging band
- checks the board edge against a non-rectangular outline polygon, catching copper in a notch
- the polygon board-edge inset is measured against the copper-edge design rule
- flags a component land crowding the board edge, exempts a staged off-board part, and reports nothing without an outline
- component courtyards default to a 0.2 mm edge margin, honor an authored override, and exempt NPTH-only/staged/edge-overhanging parts
- component-edge clearance follows the exact rounded outline rather than its rectangular bounding box
- a pad inside the board rectangle but in a concave notch is measured against the outline polygon
- a typed perimeter keepout flags only its blocked feature families, admits named nets, and exempts generated fence vias
- an authored board keepout flags the courtyards, tracks and vias inside it on the face it reserves, admits its allowed nets, and leaves the opposite face alone
- an authored board keepout blocking only some families ignores the others, and a both-sides region also reserves the inner copper layers
- a board declaring no authored keepout region runs no region geometry at all
- flags same-layer track crossings and sub-clearance pairs between nets
- flags a track crossing a foreign pad on its layer; other-layer SMD pads don't clash
- parent-rail copper may touch a structurally proven generated per-pin bypass pad, while dotted lookalike nets remain foreign
- A copper-clearance DRC violation names both nets it is between, and a pad party names its part and pad number
- inner signal layers get the same same-layer checks; through pads clash on every inner layer
- SMD pads on opposite board faces may overlap in 2D; sharing a face or a through barrel still clashes
- flags two placed parts whose courtyards overlap, but not disjoint or opposite-side ones
- the courtyard clash measures both parts' rotated keep-out rectangles, so parts clear on the diagonal do not read as overlapping
- the component-edge check measures the courtyard's own corners, so a chamfer clears a rotated part its bounding box would flag
- a component's perimeter-band inset is measured at its rotated courtyard corners
- flags two drilled holes whose walls sit closer than the hole-to-hole rule
- the grid-culled hole-to-hole and courtyard sweeps report exactly the brute all-pairs findings
- flags two vias of the SAME net crowded closer than the via-to-via rule, which the foreign-net clearance rule exempts
- the same-net via spacing rule defaults to the pair's resolved clearance, and an authored (design-rules (via-to-via ...)) overrides it
- flags a drilled hole below the minimum drill diameter (pads and vias); SMD pads exempt
- board-level design rules resolve to the documented toolchain defaults when no form is authored
- a (design-rules …) value overrides the matching default in the DRC
- a wider board clearance flags copper the default rule allowed
- a net-class clearance override is enforced against that net's neighbours server-side
- an oval slot's hole-to-hole clearance is measured end-to-end (capsule), not at its centre
- flags silkscreen that crosses a foreign pad's mask opening, as a warning
- flags board-level silkscreen text crossing a same-side component courtyard, as a warning
- silk-over-pad checks authored footprint silk rather than inventing reference-designator artwork
- flags a plated through-hole pad whose annular ring is under the minimum; NPTH pads exempt
- flags a track narrower than its net-class width, else the board minimum, as an error
- a solved local-current requirement replaces the whole-net class width for that power track, but never permits copper below its own IPC-2221 requirement or the authored branch floor
- a solved local-current width replaces the net-class width for that track, floored by fabrication and the authored power-branch-width
- a whole-rail envelope width, used when the per-branch current solve fails, is reported as an explained warning rather than as the solved error
- an unsolvable rail is judged against the whole-rail envelope as a warning naming the solver status, not as a fabrication error
- a net with no solved entry and no rail demand imposes no current-capacity requirement at all
- each power-width shortfall becomes one finding of its own kind and severity, with the envelope reason attached
- a short neck forced by a same-net land narrower than the solved power width is exempt when its far end reaches solved-width copper, while an overlong neck is not
- a mid-run pinch between two solved-width runs and a neck narrower than its forcing land both keep the power-width finding
- a bounded pad-entry neck may terminate in a same-net poured zone instead of solved-width track copper
- the adaptive power-width error skips a bounded neck forced by a same-net land narrower than the solved width, and returns the moment that land no longer explains the narrowing
- flags a routed trace endpoint that reaches no same-net copper as a copper-stub error when its section still carries support connectivity
- warns once when same-net trace capsules touch across separate explicit centreline components
- warns once per stored trace section whose deletion preserves all pad, live-via, and pour connectivity
- swept RF paths remain one semantic topology object even when their overlapping physical profile is tessellated into many chords
- warns on a through-via that reaches fewer than two copper layers
- a jointly safe subset of multi-layer non-ground vias is reported for cleanup while every ground via is protected
- credits same-net user zones when classifying trace ends and via layer use, including priority clipping
- existing copper violations are error-severity; only the hygiene checks are warnings
- a declared keepout halo and its escape radius resolve per net, and a board declaring none reports so
- a ground-named or plane-carried net is exempt from every keepout halo
- net-class identity interns per net so the keepout exemption pairs one class's own members case-insensitively and nobody else
- the keepout escape exemption suspends the halo within its radius of the net's own pads, and only for a net with its own pad in that zone
- flags foreign copper inside an RF net's keepout halo on the same layer and passes a crossing on another layer
- a keepout net's component pad guards its exact copper outline on the SMD face and every layer when through-hole
- a foreign via's barrel breaks an RF keepout halo from either layer while foreign pads never offend
- ground copper is never a keepout aggressor, so a stitching fence via beside an RF trace is clean
- a plane-carried rail is exempt from a keepout halo even when it is not ground-named
- two nets of one net-class never break each other's keepout halo, while a net in a different class still does
- the keepout escape radius clears a neighbour leaving the same pad as the RF net
- a keepout escape zone excuses only a net with its own pad inside it, so a foreign trace threading between two RF pads is still flagged
- a pad inside a keepout halo is never an offender and copper outside the halo is silent
- one keepout finding is reported per offending copper piece rather than per segment pair
- flags a differential pair whose legs are uncoupled and passes a tightly-coupled pair
- flags a differential pair whose leg lengths are skewed and passes a length-matched pair
- flags a net whose drawn copper splits into disconnected islands at the nearest-approach gap
- A net-open DRC violation names its net and a pad from each copper island it failed to join
- A net-open DRC violation carries the two nearest island probe coordinates used to report its missing join
- a track bridging the two islands clears the net-open flag
- a persisted solver RF polygon contributes its compact centreline to connectivity DRC without reviving chord-level geometry findings
- a via joining two same-net islands across layers clears the net-open flag
- a plane-carried net's islands are exempt when each pad reaches the plane
- orphan copper touching no pad is flagged as a net-open island
- two same-net tracks that cross mid-span with no shared endpoint are one island (no net-open)
- a user copper pour unites its enclosed same-net copper islands so no net-open is flagged
- a custom copper pour connects pads by real polygon overlap even when neither pad centre lies inside the pour
- a custom copper pour connects a via by circular-land overlap even when the via centre lies outside the pour
- every net earns its own user pour's credit from the run's shared zone raster
- an inner-layer user pour unites its enclosed same-net through-hole pads but not SMD pads
- the net-open sweep rasters the board's user pours once for all nets and each net still reads only its own pour
- a pad no copper ever reached is a net-open island, not silently excused as unrouted
- a routable net with no drawn copper at all is flagged, matching the fab gate's airwire verdict
- a scoped recheck returns the findings a full check of the same board returns, for every kind it does not defer
- a scoped recheck retires the findings its edit changed and carries the ones it did not
- the three reference-plane kinds are carried across scoped rechecks rather than recomputed
- the copper diff reports only the features that changed, whichever position they hold in the posted arrays
- two identical copper features are two features, so deleting one of them is an edit
- a via edit is reported with its own geometry so a scoped recheck can grow the region a drill rule reaches
- same-net copper that physically overlaps without forming a certifiable junction is reported as a warning-severity net_open, while islands that genuinely never touch stay error-severity
- a pad's gap CLASS is measured against its real outline, so a rotated or concave land's empty bounding-box corner cannot demote a genuine net_open to a graze warning
- completeness-waiver: empty inputs (each rule iterates the geometry present, so a design with no copper or parts yields no violations by construction)
- completeness-waiver: large inputs (a bounded pairwise geometry scan; working memory stays proportional to the parsed design, with no unbounded buffering)
- completeness-waiver: unauthorized access (a pure in-memory computation with no auth surface here; access control lives in serve/users)
- completeness-waiver: i/o failure (operates on already-parsed in-memory geometry; all file and network I/O is upstream in the reader and exporter layers)
- completeness-waiver: concurrent access (runs single-threaded over an immutable design snapshot, with no shared mutable state)
- completeness-waiver: malformed encoding (consumes typed geometry from the parser; malformed-input rejection is upstream in sexpr and kicad_pcb parsing)
- completeness-waiver: integer overflow (clearance and distance geometry is computed in f64 over bounded board coordinates; the only integers are net-id indices, not accumulating arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/outline

Public functions: contains, distToEdge, signedInset, bboxRect, segCrossesEdge, roundedRectPoly, arcCircle, arcOwnsSegment, filletPath, selfIntersects, valid, compare, digest, driftMessage

- point-in-polygon and signed inset classify an L-shaped outline's interior, notch, and edges
- a segment crossing a concave notch edge reports the crossing point
- rounded-rect generation clamps the radius and keeps corner points inside the rect
- selfIntersects flags a bow-tie but not a concave outline; valid rejects degenerate polys
- polygon fillets retain exact three-point arcs while producing a bounded-sagitta DRC polygon
- the saved-outline digest identifies the nominal profile, surviving float jitter, arc tessellation, start vertex and board position while a moved notch changes it
- the shared drift predicate always compares the declared dimensions, accepts a profile the source pinned by digest, and reports an outdated pin as a stale approval

## placement/pour

Public functions: compute, computeMaskShared, computeMasks, initMargin, planeConnect, segmentComponents, stampDisc, stampPad, stampSeg, viaPlaneClearance

- a seeded pour keeps its component and drops an unseeded orphan island
- the configured minimum pour width erodes and regrows the fill, removing a connected neck narrower than the fabrication floor while restoring broad copper to its ordinary clearance boundary
- the configured pour corner radius fillets emitted contour corners
- the configured corner radius rounds exterior copper without scalloping an RF via's signed-distance antipad hole
- contour tracing closes every boundary, decomposes pinched walks into strict simple regions, allows only zero-area sibling-hole tangency, and fails closed on irreparable topology
- contour simplification and corner rounding fall back to the last strict simple boundary instead of emitting a crossing
- a clipped user pour confines the fill to the drawn polygon, carves foreign copper, and keeps its region when no same-net seed lies inside
- a clipped user pour skips foreign-copper stamp windows wholly outside the clip's boundary halo
- a small drawn zone lands its copper edge on the clip boundary no matter how much board lies outside it
- an inner-layer user pour carves a clipped fill, stamping only through-hole/via copper as foreign while SMD pads leave it intact
- a pour outranks a different-net overlapping pour only with strictly greater priority on the same layer
- a higher-priority overlapping pour knocks the lower pour back by the clearance so they do not short
- a point inside a higher-ranked overlapping pour is reported clipped from the lower pour
- a declared pour recedes around any user pour on the same face whatever its priority
- plane connectivity stops crediting a pad the declared plane receded from under a user pour
- an outer-face pour holds the tighter outer default gap while an inner plane keeps the fab-safe one
- the shared fill lattice is pitched for the tighter of the two pour-clearance defaults
- a foreign net-class clearance widens the ground-pour gap around its track
- a grounded-coplanar ground gap overrides the generic ground-pour clearance without changing non-ground pours
- the finished Gerber contour, rather than the raster's conservative guard offset, realizes the controlled-impedance ground gap
- an opt-in CPWG gap profile follows taper width and stops at its authored maximum
- restored variable-width RF paths carve their exact swept taper polygon instead of the compact constant-width editor handle
- native routed arcs carve their exact directed envelope and suppress only stored implementation chords with matching layer, net, and width
- a bottom CPWG gap uses the bottom physical stackup on multilayer boards
- a single-ended controlled-impedance via gets the same stackup-derived antipad clearance on every foreign pour
- a max-freq via with no authored impedance target synthesizes its antipad at the 50 ohm default
- every emitted contour point keeps at least the pour clearance from foreign copper
- contour vertices interpolate the clearance iso-line instead of snapping to grid corners
- a foreign via interior to a seeded pour punches an antipad hole that encircles it at clearance
- an inner-layer foreign plated through-hole carves its full copper land rather than only its drill
- a round NPTH on an outer face punches a round antipad instead of its bounding square
- a foreign trace that splits a plane leaves its same-net pads in separate components
- a track crossing a fill is assigned to every fabricated component it traverses even when both endpoints lie outside
- an opposite-winding pinch repair clears every raster cell intersecting its removed wedge, so connectivity cannot credit copper absent from the final contour
- a repair-cleared articulation cell relabels its surviving sides as different fill components while previously dropped cells stay dropped
- the fill respects a non-rectangular board outline
- an isolated same-net pad reports no pour component
- the vectorised row kernel seeds every lane with the value the scalar outline walk gives
- a connectivity fill reuses one edge-margin field, applies topology-repair clears, and omits returned contours while labelling exactly what a rendering fill labels
- a batch of sampling fills shares one edge field, applies topology-repair clears, and omits returned contours
- a board's fills seed from one shared edge-margin field and each still traces exactly the contours an unshared fill traces
- carryingLayers resolves declared planes and the implicit ground model
- gridCount collapses a non-finite extent to zero cells instead of an unchecked narrowing
- a fill updated from the previous generation's raster is bit-identical to the same fill poured cold, across a seeded script of track and via additions, moves and deletions on every carrying layer
- a fill whose seed set alone moved is still updated from the previous raster, because a seed lowers no margin, and still matches the cold pour exactly
- a fill update is declined and the fill poured cold when the lattice or a pour rule moved under it, because the retained raster no longer describes the same fill
- a memo that offers no patch base pours every fill cold and still answers with the same raster, so the update is an optional seam rather than a required one
- the sub-window base reseed writes exactly the values the full board-edge and clip seeding writes, cell for cell
- the changed-obstacle diff is a multiset difference over content digests, so a reordered obstacle list asks for no re-raster and a moved obstacle asks for both of its windows
- a drawn zone's content key and its stability predicate both ignore a same-net via too far outside the clip to seed it, and both still see one that can
- the indexed ring containment test answers exactly what the signed-inset predicate answers, inside, outside and on the boundary

The low-level signed-margin grid, obstacle stamps, and component labeller give
pours a consistent board-edge, pad-shape, track, via, and deterministic
connectivity model.
- completeness-waiver: concurrent access (a pour is computed inside one solve from the caller's arena and this module holds no globals, so two pours never share state; publishing the result is the serve layer's sidecar concern, specified there)

- completeness-waiver: concurrent access (pour computation reads one immutable placement snapshot and writes only allocator-owned result buffers; it holds no shared mutable state)

- completeness-waiver: concurrent access (each fill owns its allocator-backed grids and reads an immutable placement snapshot; callers serialize mutations to the copper handed into a later fill)

## placement/fill-cache

Public functions: acquire, beginSession, key, put

- one board fingerprints identically from two independently built copies and differently after any change to its copper
- the fingerprint ignores the objective score and whether the optimizer ran, so one saved board shares an entry across the surfaces that resolve it
- a retained fill is copied out of the request arena that poured it and stays readable after that arena is gone
- an evicted board is freed only once its last reader releases it, so a DRC pass reading a fill is never overtaken by a newer board
- a board already retained is never duplicated, and the least recently borrowed board is the one eviction takes
- a board with no planes, pours or zones retains its empty fill so the surfaces after it skip the pour attempt too
- a board whose fill alone exceeds the whole store's byte ceiling is declined rather than retained, and every later pass simply pours it again
- a board entry the byte ceiling declines gives back exactly the raster claims it took, so the pass that lent them can still release its own
- a second reporting DRC over an unchanged board reuses the retained fill instead of re-pouring it and returns the identical verdict
- the content fingerprint separates two values that differ in any fold-in and matches two independently built copies of one value
- a fingerprint tag separates two runs of otherwise identical scalars so adjacent feature kinds cannot alias
- one fill retained under its own content key is borrowed by the next pass over a DIFFERENT board, so an edit re-pours only what it changed
- a board entry built from a session references the retained fills instead of copying them, and they stay alive as long as the entry does
- a pass holding a fill the store could not retain publishes its board by COPYING the fill, never by referencing memory the pass owns
- retained fills nothing references are given up before a whole board state is, and a fill a live board entry still needs is never freed under it
- a board rebuilt after a copper edit borrows the fills the edit did not reach, and every borrowed raster is bit-identical to the one a cold pour produces
- a reporting pass hands its poured board fill to the caller's own whole-board sweeps instead of making each of them pour the board again
- one patch base is retained per fill identity, copied out of the pass's arena, and replaced rather than accumulated when that fill is built again
- a patch base superseded or evicted while a pass is reading it is unlinked rather than freed, and a base over the whole budget is declined outright
- a fill-build session takes part in the patch-base chain only when it asks to, so a read-only surface neither copies a margin field nor updates from one
- only the editor's scoped recheck asks to retain patch bases; the priming pass an editor page runs on load does not, so the first edit after a page load pours once and the second updates

The reporting DRC seam pours every declared plane, every pour and every drawn
zone of a board before it can judge copper topology or connectivity, and that
raster is the whole cost of the seam. It is a pure function of the board, so it
is retained under a 128-bit content fingerprint of the placement, the routed
copper and the user zones, and borrowed rather than re-poured by every later
pass over the same board.

That board fingerprint is all-or-nothing, and a board under edit changes on
every keystroke, so each FILL is also retained under its own content key
(`placement/pour`'s `fillKey`, computed by the same traversal that stamps the
raster). A board rebuilt after an edit borrows every fill whose own inputs did
not move — every inner plane across any track edit, every other layer's fills
across a same-layer edit, and every drawn zone the edit did not reach — and
pours only the rest. Fills are refcounted independently of the board entries
that reference them, so consecutive board states share one copy of everything
between them rather than each holding a whole board's rasters.

A fill the edit DID reach is updated rather than re-poured, for the one caller
that will be asked the same question again with one track moved: the editor's
reconcile. One margin field per fill IDENTITY is retained beside the fills,
together with the obstacle set that produced it; the next generation of that fill diffs the two obstacle sets, copies
the field, throws away only the windows the changed obstacles can write in, and
rasters those again. The update is bit-identical to a cold pour by construction —
the field is a pure per-cell `min`, so a cell outside every changed window has
already seen exactly the obstacles it would see again — and any case that cannot
be shown to be (a moved lattice, a moved rule, a diff too large to be worth it,
no previous generation) falls back to the cold pour. Retaining a base is opt-in
per pass, because it deep-copies a margin field per fill: every read-only
surface — page render, derived warm, background sweep, describe, fab gate —
skips it and behaves exactly as it did before the update existed, and the first
edit after a cold page pours once to establish the base the next one updates
from.

- completeness-waiver: large inputs (a single board's fill is refused outright when it exceeds the store's whole byte ceiling, and the retained set is bounded by both a board count and that ceiling; the fill itself is already cell-capped by placement/pour)
- completeness-waiver: unauthorized access (an in-process memo over boards a caller already holds; entries are reachable only through a fingerprint of the exact board's own bytes, so nothing can read copper it did not already have, and there is no file, request, or auth surface)
- completeness-waiver: concurrent access (the store is mutex-guarded and every borrow is refcounted, so an entry evicted under a reader is unlinked and freed by that reader's release rather than under it; a published entry is immutable, so passes over one board share it with no lock held while they read)
- completeness-waiver: i/o failure (no I/O — the memo copies typed in-memory fills and reads no path; an allocation failure declines the entry and leaves the caller's freshly poured fill standing)
- completeness-waiver: malformed encoding (typed placement and pour values only; design parsing and board-file rejection happen long before a fill exists to retain)
- completeness-waiver: integer overflow (the fingerprint widens every scalar to its own storage width before hashing and does no arithmetic on it; the byte total only ever adds a measured arena capacity and subtracts the same value on eviction)
- completeness-waiver: panic-free (every failure path degrades to a miss — a failed allocation, an oversized board, and a key another thread published first all return without retaining, and the DRC pass pours its own fill as it always did)

## placement/module_policy

Public functions: analyze, classifyNetName, isInductor

- classifies ground, input-rail, switch-node and feedback nets by name
- infers a buck module from an inductor on the input rail and tags the input cap
- applies (module-policy …) author overrides over the heuristic detection
- exports the detected policy as an editable (module-policy …) block

## placement/power-routing
- a branch whose end lands inside the trunk's copper joins the trunk even when its centreline misses the trunk's by less than the copper half-width
- a via joins every track whose copper its barrel overlaps, not only tracks ending exactly at its centre
- an explicit copper-contact junction joins a branch that overlaps the trunk's copper but whose centreline misses it by more than the branch half-width
- a junction naming a via whose geometry found fewer than two contacts still creates the barrel hub so the layer jump conducts
- one unplaceable load leaves the rest of the rail solved and reports the dropped current instead of refusing the axis
- a rail whose every annotated load is unplaceable still refuses the axis rather than reporting a partial solve
- a load on copper the source cannot reach reports disconnected, not a partial solve, when it is the only load
- a net whose copper graph exceeds the node budget reports too-large instead of allocating a dense n-squared matrix
- a net with no annotated current never builds a copper graph at all
- the node spatial hash returns the same node the linear scan did, so a dense same-layer cluster keeps its historical currents
- the current solver's connectivity follows the canonical copper-contact policy, so a branch that overlaps the trunk's copper is one node even when the centrelines miss
- a net whose canonical copper topology is a single island never solves disconnected
- copper the canonical policy leaves open stays two islands, so a genuinely broken rail is still reported
- a pour component joins the traces whose copper covers its contact points, not only traces whose centreline passes exactly through them
- every pad of every part on a rail conducts, so two tracks that meet only on one pad are one island in the current solve exactly as they are in DRC topology
- a pad credits only copper whose full cross-section sits on its land, so a trace that stops short of the pad stays open
- a track and a via that meet only through a pad conduct through it, so a rail's layer jump on a land is not an open
- the sheet contact map credits every pad geometry, so a pin's plated pad-vias carry the rail into an inner plane even when its outer land does not
- a source terminal whose sub-block carries no hub pad on the rail resolves the discrete pads the current physically enters through
- a junction naming a barrel enters it through the barrel's own spoke, so the transition's current flows through the plating instead of around it
- one shared current solve answers the track-width and via-current rules with exactly the arrays the two per-rule entry points return
- a net declaring no current is answered no-current without building a copper graph or rastering its sheet contacts
- the per-net diagnosis names every source terminal's contact count and every load's contacts, pin completeness and per-axis placement

Public functions: capacityForArea, traceCapacityA, requiredTraceWidthMm,
viaCapacityA, requiredViaDrillMm, routingCurrentA, powerWidthForNet,
powerViaDrillForNet, routedTrackRequiredWidths, routedTrackRequiredWidthsPrepared,
routedViaRequirements, routedViaRequirementsPrepared, adaptiveTargetWidth, exactWidth
adaptiveTargetWidth, exactWidth, adaptiveFloorWidth, targetFor, netLimits,
trackLimits, wantsBranchSizing, boardTargets, solveLocalWidths
routedViaRequirements, routedViaRequirementsPrepared, routedPowerRequirements,
routedPowerRequirementsMemo, routedPowerRequirementsMemoZones,
routedPowerRequirementsPrepared, adaptiveTargetWidth, exactWidth

Power routing derives conservative pre-route copper geometry from the rail's
declared load envelope, the actual stack foil, the 10 °C IPC-2221 screening
target, and the board's via-plating rule. Shared traces without plane or pour
support first route a fabrication-legal centreline, then grow toward the full
rail width wherever exact copper clearance permits. A class that opts in with
`(power-branch-width MM)` instead grows each SEGMENT toward the width its own
solved branch current needs, so a test-point stub is not built at trunk width;
the whole-rail width is retained wherever that solve cannot judge a branch, and
on every class that never opted in. Pad-sized and constrained necks receive
automatic tapers, and every remaining electrical shortfall is reported together
without turning connectivity into a DRC error.
For a rail carried by an explicitly
declared plane or copper zone, the fill reserves the neck its own solved
current needs, and every segment of every current-rated rail is judged after
routing at the local branch current solved by the power-integrity analysis;
`(power-branch-width MM)` is a floor on that verdict, not the switch that
enables it. A rail whose topology cannot be solved is screened at its whole
declared current on each segment, carrying the reason it could not be
localized, and the PCB DRC panel can widen only failing opted-in segments on
1 mil increments without moving their centre lines. The router
does not invent planes on arbitrary layers, and it routes every barrel at the
class/board via geometry: a rail's current divides between parallel barrels, so
the whole-rail single-barrel drill is a reference value rather than a geometry
routing imposes. Each routed barrel is instead judged after the fact against
its own solved share, and a transition short of capacity is reported with the
number of vias it needs.

- a maximum load is the pre-route envelope, with typical used only when no maximum was authored
- a power pour's effective minimum neck is raised above the board fabrication floor by the rail maximum and actual stack foil
- board rules derive the worst-layer trace width and one-barrel drill from maximum rail load
- an unpoured current-rated rail routes through a QFN-sized land at fabrication width, then grows to its electrical target with an automatic pad taper
- an adaptive power launch uses the pad's smaller physical dimension and the shortest 45-degree taper to nominal width
- the hand router receives an electrical target for every unpoured current-rated rail, including an otherwise-unclassed net
- the hand router steers an unpoured current-rated rail at ordinary fabrication width, then independently exact-DRC-fits each local interval as the same ordinary track capsule it will commit, up to its electrical target with 45-degree tapers from the pad's smaller dimension
- adaptive routing retains the full maximum-current target while a pour-backed rail keeps its short authored fanout width
- an adaptive rail reports every actionable electrical shortfall in one pass while the fabrication minimum remains a hard error
- power-width comparison accepts the one-micrometre persistence quantum but rejects a material shortfall
- a solved plane-aware rail exposes an index-aligned required width for each local-current branch, while an unsolved rail screens every segment at the whole-rail current and reports why
- a port-keyed consumer whose module-side net reaches only passive parts resolves those pads as its load contacts
- a consumer whose annotated pad sits behind a two-terminal series part on a sibling net enters this net's copper at that part's pad
- a consumer several two-terminal series parts downstream still enters this rail at the first part's pad on it
- a rail's per-pin bypass stubs are one piece of copper with it, so a consumer whose pins were renamed onto them still resolves and the whole family solves as one graph
- a solved rail sizes each pour's neck for the current that pour actually carries, and keeps the whole-rail envelope only while the solve is unproven
- a rail with no annotated load routes for its declared source capacity, so a standalone regulator page sizes copper from its own output rating
- declared loads outrank source capacity, so a rail routes for what the board draws rather than what its supply could deliver
- a standalone module that rates its own output port and declares a bare layer count gets an IPC-2221 width for that rail; without the stackup no width is invented
- power-routing named tests remain assigned to exactly one test shard
- an adaptive rail carries its width as ordinary copper: a drawn run commits its shaped tracks with equal-width collinear stations collapsed, an inherited overlay bakes its sample widths onto the tracks it owns before any edit releases it, and a gesture that collapses copper to zero length takes the crumb with it
- moving adaptive power copper recuts the maximal same-net runs the gesture touched to the clearance they have after the move, growing or shrinking under the exact DRC gate and never below the routing floor
- the PCB DRC panel offers an undoable repair for every authoritative adaptive power-width finding that loads the exact geometry gate on demand, recuts only failing runs without moving their centre lines, removes generated stitching posts crossed by the wider copper, commits independently clean repairs when another run is constrained, and never expands one finding into more taper-slice findings
- Two adaptive slices meeting at a bend or at a plain two-way splice with existing copper are emitted at one width, with the 45-degree transition moved onto the adjoining straight, while pad lands, via corners and T-junctions keep their free trunk/branch step
- two adaptive power tracks that meet at a bend take the narrower of their two widths at that joint, including where one side is copper this pass left alone, and the wider side tapers back to its electrical target along its own straight
- a routed power segment on a class that opted into branch sizing is widened for the current its own branch carries, not for the whole rail, while an unsolved branch, an uncovered segment, and every class that never opted in keep the whole-rail target
- a trunk and a branch sized for their own solved currents still meet at one width, the wider side tapering back to its own target rather than stepping at the joint
- a three-track junction, a same-net barrel, or a pad land at the meeting point leaves every leg its own width, so only a bare two-track joint is equalized
- completeness-waiver: concurrent access (capacity functions are pure and routing reads one immutable placement snapshot while mutating only its caller-owned route)
- completeness-waiver: empty inputs (a missing or empty stack and a rail without an unambiguous declared load produce no derived geometry)
- completeness-waiver: i/o failure (the model performs no I/O; board rules and load annotations arrive as in-memory values)
- completeness-waiver: integer overflow (capacity geometry is floating point and via-count conversion is bounded before narrowing)
- completeness-waiver: large inputs (a board stack is bounded to 32 copper layers and each width calculation is a fixed-cost pass over it)
- completeness-waiver: malformed encoding (this layer receives parsed numeric geometry; non-finite or non-positive values are rejected)
- completeness-waiver: panic-free (invalid geometry returns zero or null and the inverse solver uses a fixed iteration count)
- completeness-waiver: unauthorized access (pure calculations over caller-supplied board data have no identity, file, environment, or network access)

## placement/impedance

Public functions: microstripZ0, groundedCoplanarZ0, striplineZ0, refZ0,
refZ0WithGroundGap, refEffectiveErWithGroundGap, refGroundGapForZ0, refDiffZ0, refWidthForZ0, refWidthForZ0WithGroundGap,
refWidthForDiffZ0, reference, signalLayers, preferredLayer, targetLayer,
resolvedWidthMm, resolvedWidthMmWithGroundGap,
resolvedWidthMmOnLayerWithGroundGap, resolvedDiffWidthMmOnLayer, mismatchPct,
mismatchPctWithGroundGap, diffMismatchPct, analyzeOnLayer, analyzeDiffOnLayer,
resolvedWidthMmOnLayerWithProcess, resolvedDiffWidthMmOnLayerWithProcess,
broadsideDiffZ0, traceIsCoated

Characteristic impedance (Z₀) of a trace against the board's `(stackup …)`
buildup — the pure math plus the stack model that turns a layer index into a
microstrip or stripline reference geometry. Microstrip uses the continuous,
high-accuracy Hammerstad-Jensen homogeneous-impedance and effective-
permittivity equations with their finite-thickness correction; zero-thickness
symmetric stripline uses Cohn's exact elliptic-integral conformal map, while
finite copper uses the Cohn-Wadell narrow and wide reductions as published in
IPC-2141A, blended over their crossover so the curve stays continuous and
monotonic. The offset (asymmetric) case is built by parallel-capacitance
superposition calibrated to reduce exactly to the symmetric result. Every
formula refuses geometry outside its published domain rather than
extrapolating, and the inverse (width from a target Z₀) is a fixed-iteration
bisection so it is deterministic to the last bit.

An outer-layer `(ground-gap MM)` selects the grounded coplanar-waveguide model
of Ghione and Naldi with Gupta's finite-copper-thickness correction. The same
resolved gap controls the ground pour, and it is raised to the applicable DRC
clearance floor before synthesis or checking; inner signal layers remain
stripline.

A `(diff-impedance OHMS)` target uses Kirschning-Jansen edge-coupled
microstrip on an outer layer or Cohn's shielded coupled-strip analysis plus
Wadell's offset-strip image correction on an inner layer. The pair's authored
`(diff-pair GAP)` supplies its edge-to-edge spacing and differential impedance
is twice the calculated odd-mode impedance. An optional nested `(layer IDX)`
on either target selects the actual 1-based copper layer instead of the first
usable signal layer.

Declared soldermask, trapezoidal etch profiles, mixed-dielectric stripline and
broadside pairs use a finite-volume quasi-static capacitance-matrix fallback.
It solves the same cross-section in vacuum to obtain inductance, excites pair
odd/even modes directly, and calibrates supported shapes as a field-solver
actual/ideal ratio on their closed-form baseline.

- microstrip Z0 matches the published 50 ohm width on 1.6 mm FR-4
- microstrip Z0 matches the published 50 ohm width on thin prepreg
- grounded coplanar analysis uses the authored ground gap and round-trips its synthesized width
- propagation uses the same grounded coplanar effective permittivity as impedance synthesis
- a widening CPWG trace grows its side-ground slot only until the declared cap
- grounded coplanar analysis refuses a non-positive or copper-closed slot
- an offset L3 coupled stripline solves the Barracuda 100 ohm LVDS geometry and round-trips
- an outer differential pair uses coupled microstrip odd mode and round-trips through synthesis
- vacuum capacitance and dielectric capacitance produce the quasi-TEM impedance and effective permittivity of a layered microstrip
- odd mode drives two conductors oppositely and differential impedance is exactly twice the resulting odd-mode impedance
- declared soldermask and trapezoidal etch profile correct the closed-form microstrip through a calibrated field ratio
- coated coupled microstrip synthesis remains self-consistent for both USB and Ethernet targets
- mixed-dielectric stripline uses each physical interval instead of collapsing the stack to one average Dk
- broadside coupled pairs expose even and odd modes from the capacitance matrix and define differential impedance as twice odd mode
- width solved from a target Z0 round-trips back to that Z0
- a stripline is narrower than a microstrip of the same impedance
- the symmetric stripline reduces to Cohn's published formula
- Complete elliptic integral K(k) matches published values and refuses its degenerate endpoints
- the narrow and wide stripline branches are blended into one continuous monotonic curve
- an offset stripline sits between its two symmetric bounds
- geometry outside a formula's published domain is refused, not extrapolated
- a target Z0 no width in the domain reaches is reported unreachable
- impedance solving is deterministic across repeated calls
- an outer layer references the nearest plane as microstrip and an inner layer between planes as stripline
- outer poured faces remain signal layers when resolving impedance references
- a layer with no reference plane yields no impedance rather than a guess
- a stackup with no authored dielectric intervals falls back to a uniform buildup
- the resolved width comes from the first signal layer with a usable reference
- the mismatch percentage measures an authored width against its class target
- an empty or zero-length stackup (no layers declared) computes no impedance at all
- completeness-waiver: large inputs (a stackup is a handful of layers — the whole model is a fixed number of closed-form evaluations over at most 32 copper layers, with no unbounded input)
- completeness-waiver: unauthorized access (pure math over caller-supplied numbers; the module reads no file, no network and no user identity)
- completeness-waiver: i/o failure (the module performs no I/O — the stackup arrives already parsed, as plain slices)
- completeness-waiver: concurrent access (the field fallback owns allocator-backed scratch per call and has no global mutable state)
- completeness-waiver: malformed encoding (inputs are f64 geometry, never bytes or text; a nonsensical value is rejected by the published-domain checks, not by decoding)
- non-finite or non-positive geometry is rejected by the domain checks rather than overflowing
- the solver never panics: it is a fixed-count bisection returning an error instead of diverging

## placement/trace-em

Public functions: analyzeNet

A routed single-ended controlled-impedance net can be inspected as a 2.5D
quasi-TEM two-port. Each actual copper segment is solved against its physical
stackup/reference planes with its own routed width and resolved grounded-CPWG
gap, then the route is ordered as a point-to-point chain and cascaded as lossy
transmission-line ABCD sections. Skin effect uses bulk-copper conductivity;
dielectric loss uses the surfaced generic-FR-4 tan-delta assumption; a
through-via uses an equivalent distributed barrel derived from the existing
stackup-aware antipad L/C estimate, preserving its low-frequency inductance and
capacitance while remaining passive beyond the lumped approximation's useful
range. Barrel resistance is included, but pad stacks, unused stubs, local
return-via geometry, and full-wave 3D coupling remain outside the model.

The result includes local and route-wide Z0, delay, Zin, S11 return loss and
S21 insertion loss over the class band. The PCB inspector identifies the
clicked section and plots the full sweep. The UI names the model and its limits:
it is not full-wave 3D sign-off and does not model solder mask, roughness,
radiation, connector launches, or coupling to nearby copper. Branched, looped,
disconnected, or unsupported-stackup copper is explicitly refused rather than
silently coerced into a two-port.

- a matched quarter-wave section remains matched
- a width step is visible as finite return loss
- routed CPWG sections synthesize their local gap from exact widths
- route layer 1 maps to bottom physical copper on multilayer boards
- a distributed through-via preserves the antipad model's low-frequency inductance and capacitance
- a target-matched 1.6 mm through-via swept to 20 GHz requires 3D verification instead of passing by construction
- an unsolved through-via refuses analysis instead of becoming an identity
- an inner-layer through-via requires 3D verification for its unused barrel stub
- completeness-waiver: empty inputs (a controlled net with no routed tracks returns an explicit no-copper result; a net without an impedance target is outside this analysis and returns null)
- completeness-waiver: large inputs (topology extraction and local field analysis are linear in the selected net's routed tracks and vias; every sweep has a fixed 61 points)
- completeness-waiver: unauthorized access (pure analysis of an already-authorized in-memory placement and route; it performs no request or identity work)
- completeness-waiver: i/o failure (the solver performs no I/O; browser serialization is handled by the existing page writer)
- completeness-waiver: concurrent access (all graph, section, and sweep storage belongs to the request allocator; constants are immutable and there is no cache or global mutable state)
- completeness-waiver: malformed encoding (the solver receives typed finite geometry after design/layout parsing; unsupported formula domains return an explicit status)
- completeness-waiver: integer overflow (counts are bounded by input slice lengths, allocations use the allocator's checked size arithmetic, and the sweep count is a small compile-time constant)
- completeness-waiver: panic-free (unsupported topology and field geometry return statuses, and the transmission-line math is entered only after positive impedance, width, band, and stackup checks)

## placement/pdn-impedance

Public functions: analyze, analyzeCopper, writeSpice

The routed-board target-impedance screen resolves each decoupling branch from
the selected BOM C/ESR/ESL and finite mounting inductance. Explicit tracks use
the selected path's bottleneck width. Saved power and ground pours are credited
only through the exact clearance-carved, non-coarsened fill component, with a
finite sheet-inductance integral capped by terminal spreading. A missing or
refused physical path remains available as a labelled diagnostic estimate but
cannot produce a green rail verdict. Inner-plane return proof requires authored
surface copper from each pad to a same-net via and exact same-component plane
copper between the barrels. Characterized MLCC rows may provide a voltage bias
curve plus tolerance and temperature factors. This is not a plane-cavity,
package, regulator-loop, or full-wave solver.

- a saved custom-pour corridor reaches live PDN analysis and reports computed-pour provenance for each credited leg
- PDN pour extraction retains only compact per-capacitor path facts and recycles each board-sized fill before rasterizing the next surface
- a computed PDN pour path integrates finite transverse sheet width capped by terminal spreading, so a broad fill lowers mounting inductance while a narrow neck limits it
- a hole, split island, or coarsened fill refuses PDN pour-path credit
- a routed PDN path uses the selected route's bottleneck width, not unrelated copper on the same net
- a fallback or estimated-via-return PDN mounting path remains diagnostic and cannot produce a green target-impedance verdict
- a same-component pour path may bend around a clearance hole, but still integrates finite path length and width instead of treating the component as equipotential
- a capacitor and any actual load ground pad earn computed-via-plane proof only when authored surface copper reaches same-net vias in one exact inner-plane fill component
- characterized capacitor DC-bias curves interpolate at the resolved rail voltage and combine with tolerance and temperature derating
- completeness-waiver: empty inputs (a design with no PDN intents returns an empty rail list; an intent with no bound capacitors retains an explicit diagnostic rail rather than fabricating a branch)
- completeness-waiver: large inputs (only PDN and ground fill masks are built; membership-only fills omit returned contours after applying topology repairs and share the caller's edge field, while each capacitor corridor is sampled at the fill half-pitch)
- completeness-waiver: unauthorized access (pure analysis of an already-authorized in-memory placement and saved copper; it performs no request or identity work)
- completeness-waiver: i/o failure (the analyzer performs no I/O; optional SPICE and browser serialization are handled by callers)
- completeness-waiver: concurrent access (all masks, paths, sweeps, and output belong to the request allocator; there is no mutable global state)
- completeness-waiver: malformed encoding (typed finite geometry and resolved component properties enter the model; invalid or coarsened fill refuses physical-path credit)
- completeness-waiver: integer overflow (raster dimensions and sweep counts use checked conversions and allocator-checked slice sizes)
- completeness-waiver: panic-free (domain checks precede logarithms, square roots, divisions, and raster indexing; unsupported geometry remains an explicit unproven path)

## placement/mask-relief

Public functions: reliefMm, compute, computeRouted, strokePoly, openingPoly, terminalFinish

Shared solder-mask relief geometry for RF copper
(`src/placement/mask_relief.zig`) — the one computation the Gerber mask
writer, the viewer blob, and the generated sub-circuit silkscreen consume, so
no surface can disagree about where the board ships bare.

- a fenced max-freq class's default band widens to expose the fence row's annular rings
- a layered fence's default band reaches the outermost row
- a layered fence can limit its derived mask opening to the innermost N rows
- a max-freq class without a (fence …) widens the same way, because it is a fence target too and its generated fence row must untent
- an exposed run shorter than one millimetre stays tented
- a pad beside an exposed RF trace does not interrupt the trace relief centreline
- exposure runs merge across segment joints before the length test
- mask relief contains no per-via state; via exposure is solely polygon overlap with copper
- an exposed RF trace-to-via transition opens its solved antipad plus the trace pullback only on the connected face
- a rotated land's dam follows its outline, so relief runs up to the pad and not to its bounding box
- a bend between two exposed runs emits a rounding disc at the shared vertex
- a continuous exposure run emits one closed offset polygon whose actual boundary vertices receive the editable corner radius
- a solver-authored variable-width pad taper stays fully tented while its uniform trace run opens from one exact, non-rasterized boundary
- a pad-dam termination uses the authored mask-relief corner radius without weakening the mask web
- a pad-dam terminal keeps its authored fillet when the dam boundary lands between short route chords
- overlapping round caps from short route chords are replaced by one authored-radius terminal fillet
- an authored mask-relief overrides the fenced default and zero keeps the net tented
- completeness-waiver: unauthorized access (a pure geometry function of an in-memory placement — no request, file, or user surface; access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (reads and returns arena-allocated slices only — no file, socket, or process boundary is crossed)
- completeness-waiver: concurrent access (pure functions of their inputs with no globals or shared state; each call owns its arena)
- completeness-waiver: empty inputs (empty copper or an all-tented rule set returns the empty Relief by construction — the byte-identity guarantee `any()` reports, exercised by export_gerber's no-relief mask test)
- completeness-waiver: integer overflow (all geometry stays in f64 millimetres; the one float-to-int conversion — the sample count — is guarded by numeric.checkedInt)
- completeness-waiver: large inputs (slices are bounded by the board's own routed copper; sampling is linear in copper length at a 0.05 mm pitch and every allocation is arena-bounded)
- completeness-waiver: malformed encoding (inputs are typed placement/router structs, never parsed bytes — there is no encoding to malform)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/via-antipad

Public functions: solve

First-order circular antipad synthesis for a single-ended controlled-impedance
through-via. The model combines the empirical via inductance and capacitance
equations from Intel AN 529 with Z=sqrt(L/C), using the actual pad/drill,
finished stack thickness, and thickness-weighted dielectric constant. The
solved opening is floored at the ordinary copper-clearance rule. It is an
auditable starting estimate for pour and Gerber generation, not a substitute
for a coupled 3D EM model; differential transitions are therefore excluded.

- published via equations reproduce the Intel AN 529 example geometry
- Black Canyon through-via solves a 50 ohm antipad from its buildup
- ordinary copper clearance floors an electrically smaller antipad
- completeness-waiver: empty inputs (missing stackup or non-positive target/pad/drill returns null, unit-tested through the pure guards)
- completeness-waiver: large inputs (constant-time scalar math independent of board size)
- completeness-waiver: unauthorized access (pure calculation over already-resolved board rules; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O)
- completeness-waiver: concurrent access (pure function over immutable stack and scalar geometry)
- completeness-waiver: malformed encoding (non-finite or non-positive inputs return null instead of entering logarithms or division)
- completeness-waiver: integer overflow (no integer arithmetic beyond bounded stack-layer iteration)
- completeness-waiver: panic-free (domain guards precede every logarithm, square root, and division)

## placement/impedance-cache

Public functions: resolvedWidthMm, resolvedDiffWidthMm, keyOf, stats

- an identical synthesis query is answered from the memo, with the same bits the model would have returned
- changing any keyed input mints a new key and re-solves rather than replaying a stale width
- an unreachable target is memoised as the null the model returned, not re-attempted
- an empty stackup is answered null without a field solve, and a board that declares no impedance never reaches the memo at all
- the store is bounded and drops its least recently answered query first

Solving `(impedance …)` for a track width is an iterative inverse: a closed-form
seed, then up to five secant steps, each running two electrostatic field solves
over the trapezoidal, mask-coated cross-section. On a coated process that is
seconds per net class, and `placement/optimizer`'s `prepare` re-resolves the net
rules on every solve — so the page render, the PNG, `describe`, the thermal page
and every autosave's DRC re-synthesised widths nobody had changed.

The synthesised width is a pure function of the buildup, the layer, the target,
the resolved gap and whether the class's mask artwork coats the trace, so it is
retained under a 128-bit content fingerprint of exactly those. The fingerprint
uses `placement/fill-cache`'s reflective walk, which fails the BUILD on a field
it cannot reduce to bytes: a property added to the stackup later joins the key
automatically rather than being silently left out of it. Board clearance is not
keyed directly and does not need to be — it reaches the synthesis only through
the gap `placement/impedance_rules` resolves before calling in, so a clearance
that does not move the gap cannot change the width either.

- completeness-waiver: large inputs (the key is a fingerprint of a stackup the evaluator already bounds to 32 layers, and the retained set is bounded by an entry count with least-recently-answered eviction)
- completeness-waiver: unauthorized access (an in-process memo over a buildup the caller already holds; an entry is reachable only through a fingerprint of that exact buildup's own bytes, and there is no file, request or auth surface)
- completeness-waiver: concurrent access (the store is mutex-guarded, and the synthesis itself runs outside the lock so one board's multi-second solve cannot serialize another's; two threads racing one key both solve it and agree, because the synthesis is pure, and the first published entry stands)
- completeness-waiver: i/o failure (no I/O — the memo holds plain f64 values and reads no path; an allocation failure declines the entry and leaves the caller with the width it just solved)
- completeness-waiver: malformed encoding (typed stackup and query values only; a nonsensical number is caught by the parser's range checks and by the model's own domain checks, which answer null)
- completeness-waiver: integer overflow (the fingerprint widens every scalar to its own storage width before hashing and does no arithmetic on it; the only counters are hit/miss tallies)
- completeness-waiver: panic-free (every failure path degrades to a miss: a failed allocation and a key another thread published first both return without retaining, and the caller keeps the answer the model gave it)

## placement/impedance_rules

Public functions: stackOf, deriveWidths, resolvedPairGap

The bridge between the design's `(stackup …)` / `(net-class …)` forms and the
pure impedance model: it translates the evaluated stackup into the model's
`Stack`, and fills in the track width of every resolved net rule whose class
declared `(impedance OHMS)` but no `(width MM)`.

- a net class declaring only (impedance …) has its width solved from the stackup
- a differential target derives both members' width from the selected layer and pair gap
- an authored width beats a declared impedance target and is not re-derived
- a ground-gap selects grounded-coplanar synthesis and resolves to at least the DRC clearance
- a class with no impedance target, or a board with no stackup, derives no width
- the stack bridge carries every authored foil, interval and plane through unchanged
- a dielectric with no authored (er …) takes the generic FR-4 default
- an empty rule list derives nothing and never builds a stack
- re-resolving an unchanged board replays its derived widths instead of re-running the field synthesis
- completeness-waiver: large inputs (a stackup is at most 32 layers and the rule list is the design's net count — both already bounded by the evaluator upstream)
- completeness-waiver: unauthorized access (a pure translation between two in-memory representations; it reads no file, no network and no user identity)
- completeness-waiver: i/o failure (performs no I/O — the design block arrives already evaluated)
- completeness-waiver: concurrent access (a single pass over a caller-owned slice with a caller-supplied arena; the only shared state it touches is `placement/impedance-cache`'s mutex-guarded memo, which answers identically whether or not it hits)
- completeness-waiver: malformed encoding (inputs are typed evaluator structs, never bytes or text; a nonsensical number is caught by the parser's range checks and by the model's domain checks)
- completeness-waiver: integer overflow (the only integers are 1-based layer indices the evaluator already bounded to 1-32; all arithmetic here is f64 geometry)
- an unreachable or uncomputable target leaves the width alone; the bridge never panics

## placement/layout_lint

Public functions: lint, freeFindings

- flags a decoupling cap whose power-leg exceeds the 6 mm budget
- flags a feedback part placed within keep-out of a switching-node aggressor
- flags a net class whose authored width misses its declared (impedance …) target
- differential impedance lint uses the selected layer and authored pair gap
- a width matching its impedance target, or derived from it, raises no mismatch
- a board with no stackup raises no impedance mismatch rather than guessing a buildup
- flags a near-bound passive sitting more than 5 mm from the exact pad it declared, and clears when it is adjacent
- reports a near binding that resolved to nothing, naming the cause, so a declaration that did nothing is never silent
- measures a bottom-side part through the optimizer's own mirrored pad transform, so a flipped decap is judged where the board draws it
- measures a (check (max-distance …)) requirement against the nearest qualifying passive and clears when one is close enough
- a distance requirement whose netlist carries no qualifying passive is left to the build-time checker rather than reported per placement

## placement/routability_lint

Public functions: preflight, freeFindings

A STATIC routability preflight: geometrically doomed routing situations read
off the placement and the design rules alone, with no router, no raster and no
net search. Every finding is a closed-form comparison between a measured
millimetre gap and the millimetres that net class's copper demands, so a
verdict here does not move when ordering, priority or effort tier change —
which is exactly what makes it actionable, because the DSL knobs an agent
reaches for after a failed route cannot help against footprint geometry. Two
measured barracuda cases motivate it: `adf4159/C116`'s two pads face across
0.180 mm against the 0.2536 mm a `(net-class "power" (width 0.2532))` track
needs to enter either pad from between them, and the ADF4159 CE pad the router
diagnosed as "could not break out of its own footprint — every exit is sealed".
Corridor capacity in GENERAL (rats crossing an arbitrary bottleneck strip vs.
`floor(gap/pitch)` lanes) stays deliberately absent: which nets cross a given
strip is a routing decision, not a placement fact, so any static demand count is
a guess. The `escape-contended` gate is not that check — its strip is one hub's
own escape and its demand is not guessed, because a net with a pad on that hub
and its counterparts on that side must cross the hub's boundary there whatever
path the router later picks. It reports the shortfall (nets vs. lanes at the
tightest cut, band-aware) plus the `(assign-escapes …)` wave that would schedule
the fan, and steers nothing itself; a fan an authored wave already covers is not
re-flagged. A fourth gate, `port-blocked`, answers the question the other
three structurally cannot: all of them key off nets that route INSIDE the block,
so a `(port …)` net terminating on ONE pad has no airwire, no lane demand and no
router opinion (a one-pin net is not routed), and a seed can fence it in
completely with every surface calling the board clean. It is measured by
`placement/port_escape` and fires only when the caller — who holds the
`DesignBlock` a `Placement` does not — supplies the port-net mask.

- flags two pads of one part facing across less than half a track plus clearance
- a corridor wide enough for the net class's copper is not flagged
- identical corridors across many parts collapse into one bucketed finding
- adjacent QFN pads that cannot both carry legal in-pad vias are flagged before routing
- flags a pad whose eight octilinear escapes are all inside foreign clearance
- a pad keeping one clear octilinear exit is not sealed
- a plane-carried net's pad is exempt from the sealed gate, declared plane or implicit ground alike
- the sealed-pad report is capped at the tightest pads so an unplaced board cannot flood it
- an empty placement yields no findings and allocates nothing to free
- flags a hub escape fan the corridor at its tightest cut cannot seat, with the paste-ready assignment
- an escape fan the corridor seats in full is not flagged
- an escape fan every net of which an authored assignment already covers is not flagged
- a port net with no corridor out of the block and no room for a via is flagged, and only when the caller supplies the port mask
- a corridor is measured at the adaptive router's narrow search width, while a plane-carried rail keeps its authored fanout width
- an adaptive rail's authored wide class remains an electrical target and does not widen the static route corridor
- completeness-waiver: empty inputs (a placement with no parts is unit-tested to return an empty finding slice)
- completeness-waiver: large inputs (the pad table is built once and every scan is bounded by the pad count; findings are bucketed and ref lists capped, so a dense board yields a bounded report)
- completeness-waiver: unauthorized access (a pure in-memory analysis of an already-resolved placement; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the placement and its rules are already parsed)
- completeness-waiver: concurrent access (read-only over a caller-owned placement; no shared mutable state)
- completeness-waiver: malformed encoding (pad numbers and net names arrive already parsed; a pad with no net is treated as unnamed copper rather than rejected)
- completeness-waiver: integer overflow (millimetre floats throughout; the only integer is the 8-direction exit tally)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/rough_routability

Public functions: tally, repair

The rough placement seed's objective is wire length, loop inductance and
compactness; none of those asks whether the copper can be DRAWN, so the seed
will pack a ring flush enough to seal a pad's every escape, stack two parts on
one spot, or lay a whole hub side in one column so the corridor behind it offers
four lanes to six nets. `placement/routability_lint` already measures all of
that in closed form off the placement and the net classes; this is the other
half — the rough solve reads those findings and repairs the ones a placement can
answer. Four rounds, each bounded and reverted whole unless its own measure
strictly improves: separate stacked courtyards, back a sealed pad's named
blocker off it, open a blocked `(port …)` net's way out of the block, and relieve
a contended escape by dealing its corridor into two depth ranks (`stagger`) or
opening lane gaps along it (`spread`). The two escape
reliefs are SOFT and additionally have to pay for themselves in the rough
objective — a contended fan is a warning by its own gate's account ("routes
today, just in whatever order"), so relief is only worth having while it is cheap
in wire length, loop inductance and compactness; the budget is a measured
fraction of the objective per net the round seats. The stacked, sealed and port
rounds are hard defects and are never priced: a module whose port cannot leave is
unusable as designed, so no wire-length saving buys that back. The port round
backs EVERY wall the gate named off the pad, not just the tightest one, because a
fenced pad is normally fenced by a pair and opening one side of a mouth leaves
the other where it was; and it opens a whole lane rather than merely clearing the
halo, since the shortfall a finding reports is measured at one frontier cell. A
blocked port also counts in the score every OTHER round is judged against, so a
stagger that seats two escaping nets by walling a port in is refused without any
round needing to know what a port is. `pad-corridor-tight` is measured and
reported but never repaired — it compares two pads of one
part, so it is a footprint-and-net-class fact no placement moves. Un-stacking is
the one round judged on its own count alone: two parts on one spot are a
courtyard-overlap DRC error and seal by definition, not a trade-off a
routability score is entitled to price.

- a placement whose gates find nothing is left untouched
- two parts stacked on one spot are separated
- the tally counts each gate the preflight reported
- repairing the same placement twice gives the same poses
- a part is never displaced past the repair's own budget
- an escape relief may spend objective only in proportion to the nets it seats
- an unpriced escape relief is not refused for its objective
- a port net fenced out of its own block is repaired by backing its walls off, and the moved parts still do not overlap
- the port round is skipped entirely when the caller names no port nets
- repairing a blocked port twice gives the same poses
- completeness-waiver: empty inputs (a placement with no parts scores zero and returns before any round runs)
- completeness-waiver: large inputs (the caller gates the pass on a part-count cap and every round is bounded — four gates, four fans, a fixed sweep count)
- completeness-waiver: unauthorized access (a pure in-memory pass over a placement the solver already owns; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the placement and its rules are already resolved)
- completeness-waiver: concurrent access (operates on the caller's own placement inside one solve; the reported verdict is threadlocal like the other solve diagnostics)
- completeness-waiver: malformed encoding (findings arrive as parsed structs from the preflight; a finding naming a ref the placement lacks is skipped)
- completeness-waiver: integer overflow (millimetre floats throughout; the net deficit uses saturating subtraction)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/port_escape

Public functions: portNets, detect

Can a block's own `(port …)` net physically LEAVE the block? Every other
routability gate keys off nets that route INSIDE the placement, and a module port
does not: `straps-synth-lmx2595`'s `SPI_SCK` terminates on one pad of `U1` and
goes nowhere else, so it has no airwire, no lane demand at any hub's escape fan,
and nothing for the router to fail at — a one-pin net is not something the router
routes. A rough seed can therefore wall that pad in completely and no surface
reports a thing. The proof is a reachability question answered as one: walk a
track centre from the net's own pads through free space until it either leaves
the HULL — the bounding box of every part's world courtyard, i.e. the footprint
the block occupies on its parent board — or reaches a spot where a via of the
net's class fits, which puts the signal on a layer the block's parts are not on.
Either proves the port. Obstacles are foreign-net pad copper sharing the pad's
face, inflated by `width/2 + clearance` (the router's own model), deliberately
NOT courtyards — routing between the pads of two side-by-side 0402s is ordinary
practice. A via is measured against both faces, since its barrel drills through
them, and may not land in any pad. The walk is a 4-connected flood over a square
lattice whose pitch is one-sided on purpose: a lattice can only MISS a corridor,
never invent one, so it is set fine enough that any corridor with a free band at
least one pitch wide is found. Cells are tested lazily against a bucket index of
the pads, so a port that escapes early never pays for the rest of the board.
Exemptions mirror the sealed gate — a plane-carried port net rejoins through its
pour, a through-hole pad is already on every layer, and a port naming no pad in
this block has nothing to prove.

- a port net whose only pad is fenced in reports the pad and the parts walling it in
- a lane wide enough for the net's class proves the port escapes
- a reachable spot big enough for the net's class via proves the port escapes with no corridor at all
- a plane-carried port net needs no surface escape
- the port mask names exactly the block's declared port nets, matching a flattened net on its leaf
- detecting on the same placement twice reports the same findings
- an empty port mask leaves every net unexamined
- a port corridor uses the adaptive power router's narrow search width while a plane-carried fanout keeps its authored width
- completeness-waiver: empty inputs (an empty port mask and a placement with no parts both return an empty finding slice before any lattice is built)
- completeness-waiver: large inputs (the lattice is refused above a cell cap and the flood stops at the first escape; the pad index bounds every cell test to its own bucket)
- completeness-waiver: unauthorized access (a pure in-memory analysis of an already-resolved placement; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the placement, its rules and the block's ports are already parsed)
- completeness-waiver: concurrent access (read-only over a caller-owned placement, with the visit map allocated per call from the caller's arena)
- completeness-waiver: malformed encoding (pad numbers, net names and port names arrive already parsed; a port naming no net in this block simply masks nothing)
- completeness-waiver: integer overflow (millimetre floats throughout; every float-to-index narrowing is clamped in float space by numeric.toCount)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/implicit-plane

Public functions: carries, carriesRail, dominantRail, innerPlanes

A block that authors no `(stackup …)` runs on the legacy IMPLICIT board model:
four copper layers whose two inner ones are planes. In1 has always been ground,
which is why a bypass cap's ground leg needs one stitch via and never a trace;
In2 was a second ground plane, so a supply rail landing on a dozen IC pads was
left as an ordinary net for the router to draw — and on a dense QFN it drew
nothing at all. In2 carries the block's DOMINANT SUPPLY RAIL when its
`(power-plane on)` compatibility setting is enabled, so the rail behaves
exactly as ground does: the router stitches each of its pads to the plane, the
connectivity oracle counts those pads joined, port escape exempts
them, and the Gerber's In2 pours the rail with antipads around foreign holes.
The whole model lives in one module because the router, the oracle, the DRC, the
pour fill and the Gerber export must never disagree about it — a board where the
router assumes a plane the Gerbers do not pour is a shipped short.

WHICH rail wins is settled by a tie-break ladder — most pads, then an output
rail over an input rail, then the lower net name — which is a strict total order
over the qualifying nets. The rail that loses is left to long surface routing,
so the choice may not turn on the order the flattener happened to emit nets in:
reordering two pin declarations in a `.sexp` must never move the plane.

- the dominant supply rail is the rail-class net with the most pads
- a tie on pad count resolves the same whatever order the nets arrive in
- a pad-count tie hands the plane to an output rail over an input rail
- a block with no qualifying rail keeps both inner planes on ground
- the rail plane carries its net by full name or leaf, and nothing else
- In1 is always ground and In2 is the chosen rail when enabled, else ground
- the u8 layer helpers on BoardRules answer exactly what the shared layer table does
- the implicit rail plane pours In2 and antipads the holes it does not carry
- a design that declares a `(stackup …)` plants no implicit rail and emits exactly its effective declared planes
- a disabled subcircuit power plane leaves the dominant supply rail unplaned without authoring a stackup
- completeness-waiver: empty inputs (an empty net list yields no rail, unit-tested)
- completeness-waiver: large inputs (the scan is linear in the flattened net list the caller already holds)
- completeness-waiver: unauthorized access (pure in-process predicates over caller-supplied structs; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O - every input is a struct the caller already holds)
- completeness-waiver: concurrent access (no shared or mutable state; every function is a pure read of its arguments)
- completeness-waiver: malformed encoding (inputs are typed structs, never parsed bytes)
- completeness-waiver: integer overflow (pad counts are slice lengths; no arithmetic beyond comparison)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/pin_roles

Public functions: load, isGroundFn, isSupplyFn, strapPads, padRequirements

- groundy function names are recognised, straps are not
- plain NC names are optional package lands while do-not-connect and reserved names are not routing grounds
- supply function names are recognised, grounds and signals are not
- electrical type overrides the name heuristic; signal types demote to strap
- config-strap function names are recognised, supplies grounds and GPIO are not
- strapPads maps strap pads to their function name via name or electrical type
- strapPads skips connector positional pins named after their pad
- connectionRequirement tiers an unconnected pad by confidence
- padRequirements keeps only the flaggable pads of a part

## placement/ground-via-seed

Public functions: generateLive

- hand routing can seed one legal exposed-pad field and one centred GND-pad barrel without replacing existing copper, preserving the exact centre of an off-grid transformed subcircuit pad when it is legal
- after via-in-pad seeding, hand routing places the nearest legal barrel within the authored ground-via maximum beside every still-unserved ground pad and adds its surface join when that face has no same-net pour
- running the ground-via seed repeatedly adds each eligible barrel at most once
- a candidate that would add a fabrication DRC error is reported as blocked and is not returned
- completeness-waiver: empty inputs (a board with no eligible ground-plane pads returns an empty outcome, unit-tested by the plane-via candidate contract)
- completeness-waiver: large inputs (the autorouter candidate pass and indexed incremental DRC gate bound the work; no unbounded search is introduced)
- completeness-waiver: unauthorized access (pure in-process transformation over caller-supplied structs; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O; every input is a typed struct)
- completeness-waiver: concurrent access (no shared mutable state; the result is arena-owned)
- completeness-waiver: malformed encoding (inputs are typed structs, never parsed bytes)
- completeness-waiver: integer overflow (counts are bounded by candidate slice length)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/plane-via

Public functions: InPad, barrelFits, inLandBarrelFits, landAt, thermalAxis, ThermalArray, fanDir, swivel

Where a plane-stitching via may land on the pad it serves. Both searches that
drop one — the router's plane pass and the post-route gate's island stitch —
used to look only OUTSIDE the pad: the anchor snapped to the routing grid, then
candidates a whole grid pitch further out (~0.44 mm on barracuda), each joined
back with a stub. That is right for a chip pad, smaller than the grid anyway,
and wrong for a big one: a buck's exposed thermal land is millimetres across, so
a site a couple of tenths off its origin is still deep inside its own copper —
clear of the neighbour that refused the origin, needing no stub, and invisible
to a search that only ever steps by the grid. Measured on barracuda's
`buck_6v/U22.3` (1.32 x 1.72 mm): the anchor sits 0.063 mm from the `FB` pad and
needs 0.327, while a site 0.275 mm below it clears everything, inside the same
pad. `InPad` is that search — a ring walk over a lattice pinned to the pad's
anchor, yielding only sites whose whole via barrel stays within the pad's
copper. It says where a via MAY sit as far as the pad is concerned; the caller
still applies its own clearance rules, so the search can only add legal sites,
never relax a rule.

The opposite extreme is the FINE-PITCH FINGER, where barrel containment is not
merely empty but impossible: a 1.27 mm-pitch board-to-board connector's B.Cu
finger is 1.0 x 0.35 mm and the board's via is 0.4 mm, so the pad is narrower
than the barrel is wide and no point of it can hold one — while outside the pad
the fan is walled by the row neighbours 0.635 mm away. Such a pad ships as its
own one-pad copper island, which is what barracuda's last open GND gap was: 192
fan sites tried and refused, and a maze that found 596 legal sites further out
with no lane on its own layer to reach one. So a second containment is offered
for the site the routed reference board actually carries there — a via at the
finger's own centre, its HOLE on the pad's copper and its annular RING hanging
over the edge. The hole being ringed by the pad's own copper is what makes it a
via IN the pad rather than beside it; the overhanging ring is the pad's own net,
so the only thing it can offend is a FOREIGN object, and those the caller
already measures one class at a time. A pad too small to hold even the hole
still offers nothing, both walks share one lattice in one order (so a caller
running both gains sites and never trades one), and the relaxed walk is offered
only after the strict walk and the fan have both declined.

CONTAINMENT itself lives here too, because the answer has to be one answer. A
via sited ON a pad must keep its finished annulus on that pad's copper: a ring
hanging over the land edge is unsupported copper across the mask opening and a
solder-wicking path out of the joint, and nothing else on the board can catch it
— every copper clearance probe skips the routing net's OWN pads, and a land the
via is drilled into is exactly that. So one predicate measures it (`barrelFits`,
the barrel centre plus eight rim samples against the real outline) and every
via-in-pad site is put through it: the ring walk's strict tier, the thermal
array's regular cells, and the router's own pad-centre and fan candidates. The
pad EDGE is the boundary, with a nanometre of tolerance that exists only so a
barrel exactly as wide as its land is not lost to arithmetic; a manufacturable
overhang is tens of microns and is refused. Measured on `bcuda-lt3045-ldo`: the
plane pass opens on the pad anchor snapped to the routing lattice, and on U1's
0.80 x 0.30 mm DFN ground land that put a 0.4 mm barrel on the land with the ring
about 0.05 mm past the 0.30 mm edge on each side — legal by every clearance rule
and a defect on the board.

A refused site is not a lost via. The tiers below the pad centre take over in
order, and they are centre-out: the in-pad walk opens on the land's own
UNSNAPPED anchor, so a land that can hold the barrel at all gets it at (or
nearest to) its own centre — strictly closer than the snapped candidate was, and
with no stub. Only a land that cannot contain the barrel ANYWHERE falls through
to a fan site beside it plus a stub, one grid pitch out. That ordering is what
keeps the bonded-bypass rule honest: a cap land contains its barrel and keeps the
exact-centre drop the loop-inductance argument asks for, and a cap land too small
to contain one degrades by a grid pitch instead of shipping an unlanded ring.

- the in-pad scan yields the pad's own anchor first when the barrel fits there
- the in-pad scan never yields a site whose via barrel leaves the pad's copper
- a pad too small to hold the via barrel offers the in-pad scan no site at all
- a via-in-pad site may hang its annular ring over the pad edge while its drilled hole stays on the pad's own copper, so a finger narrower than the barrel still offers one
- a pad too small to hold even the drilled hole offers no in-pad site, and a via with no usable drill is held to its barrel
- the in-pad scan is deterministic: the same pad, anchor and via size replay the identical sequence
- the in-pad ring walk visits every lattice cell of a ring exactly once
- a via-in-pad site must land its whole annular ring on the pad, so a land too small to hold the barrel is refused at its own centre
- the pad edge is the containment boundary: a barrel exactly as wide as its land is contained, and a micron of real overhang is not
- a via standing on no land of its own net is not a via-in-pad and is not held to containment
- the land under a via site is the routing net's own pad on that layer, and a foreign or other-layer pad is not one
- a plane return is never sited where its annular ring would hang off the land it stands on
- a land too small to contain the barrel keeps its plane return, taken from the outward fan beside it
- a bonded bypass cap keeps its barrel at the exact land centre when the land contains it, and degrades to the nearest contained site when it does not
- a thermal pad whose anchor is via-illegal is still stitched, from a site inside its own copper
- an exposed-pad thermal array keeps its centred regular field, which containment sizes but never displaces
- the plane-via pass is deterministic: the same board replays the identical via positions
- completeness-waiver: empty inputs (a degenerate pad yields an empty scan, unit-tested; an empty obstacle list gives the fan its documented +y fallback)
- completeness-waiver: large inputs (the ring walk is capped at 16 rings whatever the pad measures)
- completeness-waiver: unauthorized access (pure in-process geometry over caller-supplied shapes; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O - every input is a struct the caller already holds)
- completeness-waiver: concurrent access (no shared or mutable state; the scan's cursor is caller-owned)
- completeness-waiver: malformed encoding (inputs are typed structs, never parsed bytes)
- completeness-waiver: integer overflow (ring indices are bounded by the 16-ring cap; the rest is float millimetre arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/bypass-intent

Public functions: exactNet, build, Legs, Seg

Which copper the finish must keep so an authored `(decouples "IC" PIN)` bond
survives its own cleanup. `placement/bypass-open` decides the bond by one
question — over same-net tracks on the two parts' shared outer face, is the
cap's rail land united with the exact IC supply land — so the answer is a WALK:
one cap-land → track → … → track → pin-land path through that same graph, taken
fewest-hops with ties by track order. The rest of the rail (a `(decouples rail)`
reservoir's escape, a branch to a connector, the plane drops) is ordinary copper
the geometry passes may clean, and freezing it bought nothing: measured on
`bcuda-lt3045-ldo`, one authored bond froze the whole `VIN` rail and cost the
gloss three `land_transit` findings it could otherwise remove.

A pass that acts object by object refuses the walk's own objects, which is
sufficient because the walk's union-find edges depend only on its tracks and the
two lands, and no finisher moves a part. A pass that rebuilds a whole net at
once re-runs the walk over its candidate copper instead and puts the net back
when a bond that was closed has come open — holding one chain rigid while the
copper around it moves is not the conservative choice but a third board neither
version would produce, and on `bcuda-lt3045-ldo` that shape cost `VIN` its route
to a `track_width` finding. A bond with no walk protects nothing: it is one
`bypass-open` reports open already, and no pass can push that verdict lower.

- the copper frozen for an authored exact bypass bond is the cap-land-to-pin-land surface walk, not the whole rail net
- a rail whose only copper is its exact bypass leg is frozen entire, exactly as the whole-net freeze left it
- a whole-net rewrite is refused when it leaves an authored bypass bond that was closed no longer closing over routed copper
- an authored exact bypass bond that no surface walk closes protects no copper, because the bond is already open and cleanup cannot open it further
- leg membership survives the chain rebuild and junction splits that cleanup passes perform
- completeness-waiver: empty inputs (a placement with no authored bond allocates nothing and answers false to every query)
- completeness-waiver: large inputs (each walk is filtered to one rail on one face before its breadth-first sweep, and boards carry a handful of authored bonds)
- completeness-waiver: unauthorized access (pure in-process geometry over an already-authorized layout)
- completeness-waiver: i/o failure (no I/O; every input is typed placement and routed-copper data)
- completeness-waiver: concurrent access (no shared state; every result is arena-owned by the caller)
- completeness-waiver: malformed encoding (inputs are typed structs, never parsed bytes)
- completeness-waiver: integer overflow (net and part indices are bounds-checked before conversion, and every allocation follows a slice length)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot)

## placement/bypass-open

Public functions: check

The final-state connectivity check for the local high-frequency leg of an
authored decoupling loop. Whole-net connectivity is not sufficient: separate
plane drops can join a rail globally while leaving the capacitor out of the
short surface-current path to the supply land it is meant to serve.

- A decoupling capacitor must have continuous same-face copper to the exact IC supply pad its loop targets
- Vias and remote pours do not substitute for a bypass capacitor's local surface leg
- rail-level reservoir capacitors explicitly marked `(decouples rail)` are outside the exact-pad rule
- optimizer-inferred proximity loops are outside the authored exact-pad rule
- The bypass connectivity check judges the lowered swept-path copper every sibling rule measures, not the compact editor handle's floor width
- completeness-waiver: empty inputs (a placement with no decoupling loops produces no findings)
- completeness-waiver: large inputs (the pass is final-state reporting only and filters copper by each loop's one rail and outer face)
- completeness-waiver: unauthorized access (pure in-process geometry over an already-authorized layout)
- completeness-waiver: i/o failure (no I/O; every input is typed placement and routed-copper data)
- completeness-waiver: concurrent access (no shared state; every graph is arena-owned by the caller)
- completeness-waiver: malformed encoding (inputs are typed structs, never parsed bytes)
- completeness-waiver: integer overflow (indices are bounds-checked before conversion and graph allocation follows slice lengths)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot)

## placement/physical-net-identity

Public functions: Identity.init, Identity.same, Identity.canonical, Identity.canonicalName

The physical-copper identity shared by clearance, topology, and connectivity
checks. Per-pin decoupling shorthand preserves an exact target by splitting a
logical rail into a small connection net, but the fabricated copper on that
connection remains part of the parent rail. Aliasing requires the placement's
explicit bypass-loop metadata plus matching hub and capacitor pins; punctuation
alone is never evidence.

- Generated per-pin bypass connection nets share fabricated copper with their parent rail
- Dotted net names without matching explicit bypass-loop and pin evidence remain electrically distinct
- Alias connectivity does not duplicate parent-only orphan copper into every bypass-stub open-net report
- completeness-waiver: empty inputs (an empty netlist produces an empty identity map and exact comparisons)
- completeness-waiver: large inputs (construction is one bounded loop scan with linear net lookup; physical comparisons are constant-time)
- completeness-waiver: unauthorized access (pure in-process identity over an already-authorized placement)
- completeness-waiver: i/o failure (no I/O; every input is typed placement data)
- completeness-waiver: concurrent access (no shared state; the identity slice is arena-owned by the caller)
- completeness-waiver: malformed encoding (inputs are typed structs and all indices are bounds-checked)
- completeness-waiver: integer overflow (indices are checked before conversion and allocations follow slice lengths)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot)

## placement/plane-stitch

Public functions: netHasPlane, declaredPlaneContacts, netPourLayers, padInPour, bonds, viaOrder, packageTieObstacle, Bond, Web, via_share_max_mm

How a plane-carried net reaches its plane. Such a net is never routed by the
maze: each of its pads drops a via and the plane joins them. That is right for
two pads on opposite corners of a board and wrong for a bypass cap's leg and the
IC pad it decouples a millimetre and a half away — those got a via each and no
copper between them, so the decoupling loop the placer spent its objective
tightening was then routed down to an inner layer and back up, and the board
carried two barrels where one serves. Measured on straps-synth-lmx2595
(2026-08-11): all six `V_3V3` bypass caps bound to `U1` by `(decouples …)` were
joined only through In2. So a non-ground carried rail draws the LOCAL SURFACE
CONNECTION FIRST — the pad pairs the placement's own decoupling model names,
drawn with the ordinary short-hookup machinery through the same DRC-grade probe
— and only then stitches, sharing one via across the copper it just drew. A
dedicated ground plane instead receives independent local drops and no routed
pad-to-pad surface web, preserving the escape channel for each decoupling cap's
signal-side path. A bond the probe refuses is not drawn and its pads keep the
two vias they had, so geometry decides and nothing here relaxes a rule.

Both halves of the share rule measure the SAME length — the pair's span, land
centre to land centre. Charging the emitted polyline instead is how the pass came
to plant both barrels on a pair it had just joined: that polyline still carries
the entry laps inside both lands which `pad_entry` deletes at the end of the
finish, so on straps-synth-lmx2595's `C_VCCBUF` ↔ `U1` pad 21 the walk saw
3.4961 mm on copper that ships at 2.6407 mm and refused to share (span 2.6712).
The cluster's one barrel then stands ON the bypass cap's own land centre when the
land admits it, which is where the loop-inductance literature puts it and which
leaves no stub for the walk to charge at all.

A package tie-off is a local package bond only on an uncarried net. A plain
`NC`, `N/C`, or numbered `NC` land deliberately assigned to ground may join the
nearest real ground pad; an explicitly typed input/control strap may join the
nearest real ground or supply pad on that net. A dedicated ground plane skips
those bonds and drops each reachable land locally. Pins marked `DNC`, `DNU`,
reserved, or RFU never enter this rule.

- the implicit model plants a plane on ground and the dominant rail, a declared stackup on exactly its declared nets
- a barrel's declared plane contacts count only interior planes of its own net, and fall back to the implicit model's single plane when no stackup is declared
- grounded NC and input-strap pads bond to their package's real ground pad with the real return offered the shared via, while an ordinary unclassified pad does not
- obstacle-order role lookup identifies package tie-off lands so the router's ground-via maximum cannot recreate their suppressed barrels
- a ground plane never surface-bonds an HMC-style grounded tie-off ring or capacitor returns; each reachable land drops locally while the exposed-pad thermal array remains
- a pad already sitting in an outer-layer pour of its own net is stitched by the pour, not by a via
- a decoupling loop's power leg bonds the cap's rail land to the hub pad it decouples
- a loop's ground leg may bond on an uncarried ground net, while a dedicated ground plane suppresses every such surface bond
- a leg whose pads are not both terminals of the net being stitched is no bond, so a rail's pass never draws a ground leg
- a lone leg whose pads are farther apart than via_share_max_mm is no bond, so no run is drawn that one via could not serve
- a same-target capacitor bank extends a far exact-target leg through bounded local cap-to-cap hops while the path-length gate still places another via when needed
- the bonded cap land is offered a via before any other pad, so the shared barrel lands beside the cap
- a pad whose surface copper reaches a same-net via within via_share_max_mm needs no via of its own
- a pad further along the copper than via_share_max_mm keeps its own via
- a net with no drawn copper shares nothing, so every pad of it is stitched exactly as before
- a bond carries the pair's span, so the share walk charges a run the same length the gate admitted it on
- final fill-blind copper cleanup preserves exact-target bypass surface paths even when a rail plane makes their trace sections connectivity-redundant
- a non-ground plane-carried net draws its bound cap's surface run to the hub pad before it stitches, and one via then serves both pads
- a diagonal bound decoupling leg that the compact land hookup declines falls back to the continuous direct search instead of becoming two unrelated plane drops
- the shared via of a DRAWN bond stands on the bypass cap's own land centre, so no copper is spent reaching the drop
- a bond with every DRC-clean surface path blocked is not drawn, and its pads keep the independent stitch via each of them had
- a plane-carried net that reaches its plane nowhere keeps no bond copper, so a pass that stitches nothing leaves the board as it found it
- completeness-waiver: empty inputs (a placement with no loops yields no bonds and stitches exactly as before, unit-tested)
- completeness-waiver: large inputs (bonds are bounded by the loop count and the share walk relaxes over that same edge list)
- completeness-waiver: unauthorized access (pure in-process predicates over caller-supplied structs; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O - every input is a struct the caller already holds)
- completeness-waiver: concurrent access (no shared or mutable state; a Web is owned by the one net's pass that built it)
- completeness-waiver: malformed encoding (inputs are typed structs, never parsed bytes)
- completeness-waiver: integer overflow (terminal indices are slice offsets; the rest is float millimetre arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/thermal_field

Public functions: solveScenarios, solveScenario, heatsinkTarget, spreaderLayers, defaultSheet, gridShape, adaptiveGridShape, cellsForBox, discretize, sinkToAmbient, finCount, fanVelocity, fanFilmCoefficient

`eval/thermal.zig` answers the paper question — `Tj = Ta + P·θJA`, one part at a
time, no board and no neighbours. That is the right screen before a package is
chosen and the wrong one afterwards, because θJA already contains an assumed
board: it cannot see a hot buck sitting 3 mm from the MCU, and it cannot say
that another plane would fix either of them. This module asks the layout
question instead. The exact board outline is cut into square cells, with the
base grid refined to resolve powered packages and non-rectangular boundaries;
cells outside the outline are excluded. Every active cell
conducts to its four neighbours through a sheet conductance built from the
stackup's own finished thickness and foil weights, derated where the outer
copper is not actually poured, and sheds to ambient through its two faces
separately, each at the scenario's film coefficient unless a part body sits on
it; the rim is adiabatic, since edge convection is already counted in the face
term. A powered part injects its watts over the cells its courtyard box covers,
and its junction sits `P·(θJB + θ_transfer)` above the hottest cell underneath
it, where the transfer term is how hard it is for that part's heat to reach the
layers the sheet lumps together — short where a via array stitches the land to
the planes, long where nothing does. A drawn heatsink adds one shared
isothermal plate node. On an unobstructed PCB face its pad couples covered board
cells to that node and parts across the board use declared θJC(bottom) where
available; on a populated face each covered powered package needs declared
θJC(top) to gain a direct junction-to-plate branch. The plate reaches ambient
through one θSA, so covering more cells or packages never duplicates its rated
cooling capacity.

Four baseline screening scenarios come back in one call: still air, roughly 1 m/s and
2 m/s of forced air, and a small stamped heatsink bolted to the part with the
least junction margin in still air. A board-authored fan adds a fifth row ahead
of the generic airflow brackets, and a configured fan plus physical heatsink
adds a sixth simultaneous row after their standalone rows. Its catalog free-flow and shutoff-pressure
endpoints remain distinct, an explicit installed-flow fraction sets the volume
flow, and its position, face and target clearance produce a distance-expanded local jet
instead of a global film coefficient. When fan and board-mounted heatsink share
a face, clearance is measured to the fin tips, jet/contact overlap drives the
fin film coefficient, and the base replaces bare-PCB convection beneath it;
opposite-face assemblies remain aerodynamically isolated. Linearity is the load-bearing invariant — the
system is solved with ambient as the ZERO reference, so what is returned is a
RISE field that is independent of the ambient it will be read at, and one solve
per scenario therefore serves every ambient a caller asks about. It is a
screening estimate, not a simulation: uniform copper, one lumped dielectric, no
coupling through the air.

- every watt injected leaves through the cells' faces and any heatsink, so the solved field balances the board's power to within a tenth of a percent
- a single centered source is hottest at the source, decays monotonically along a ray to the edge, and is symmetric about the board centre
- the rise field is linear in the injected power, so two sources solved together equal the two solved apart added cell by cell
- more airflow strictly lowers the board's maximum rise, and the heatsink scenario strictly lowers its target part's junction rise
- an authored fan adds a spatial cooling rung whose selected face, projected position, standoff and installed-flow assumption drive the per-cell film coefficient
- a saved layout can override the authored fan's projected position, PCB face and outlet-to-target clearance without changing how the thermal field consumes its operating point
- a configured fan and heatsink add one simultaneous rung, and when they occupy opposite PCB faces the fan changes only its own face while the sink keeps its natural-convection path
- a fan aimed at a board-mounted heatsink on the same PCB face measures clearance to the fin tips, cools the fins in proportion to jet/contact overlap, leaves the covered PCB without a duplicate bare-face path, and reaches exposed PCB at the additional sink height
- one scenario can be solved on its own and matches the ladder's answer for it, and the heatsink asked for alone still bolts its sink to the part the still-air solve names
- a drawn straight-fin heatsink derives its fin count and theta-SA from material and geometry, and applies that sink over the exact authored contact rectangle
- a PCB-mounted heatsink needs no component target, couples a bare-face pad to one shared sink node, and reports the directional package-bottom junction path beneath that contact
- flipping a shared drawn heatsink from an unobstructed PCB backside to a populated face changes it into a package-lid network: every usable lid crosses declared theta-JC-top, missing directional data receives no direct credit, and theta-SA is applied once to the common plate
- a part with no pose is reported as skipped instead of placed, a part hanging off the board docks onto the nearest cell, and neither panics
- a board with nothing to dissipate solves to an all-zero field, converged and free of NaN
- a junction is computed through the declared theta-jb, else through half the theta-ja with the row flagged estimated, and through nothing at all when neither is declared
- a scenario's maximum ambient is the tightest junction ceiling and the caller's ratings cap, each naming the part that sets it
- the base grid cuts the bounding rectangle into square cells of one to four millimetres with at most sixty-four along the longer side
- the solve refines to at least eight cells across a powered package and excludes cells outside an authored polygon from conduction convection rendering and hotspot selection
- the spreading sheet counts the two outer faces plus one layer per inner plane, so a plane-less stack spreads strictly less than the implicit four-layer board
- the conducting sheet is built from the stackup's own finished thickness and per-foil copper weights, and a caller declaring none keeps the 1.6 mm one-ounce screening convention
- outer copper is derated cell by cell by the coverage map the caller sampled, so an unpoured cell spreads through the inner planes alone and a fully covered board reproduces the uniform sheet exactly
- the two board faces convect separately and a face a part body sits on sheds a fraction of the bare-laminate coefficient, so a cell with parts on both sides sheds least and a bare cell most
- a junction sits above the board through theta-jb plus a board-transfer path, which thermal vias under the part shorten and the part's own outer-foil spreading bounds so it never runs away on a small land
- the grid a board resolves to is answerable without solving it, so a caller can rasterize a coverage map onto exactly the cells the solve will use
- the packed four-scenario solver uses less per-cell ladder storage than four independent sheet ambient power and rise arrays
- without a shared drawn plate, the exported FEM coefficients conserve component power and reproduce the built-in sheet and two-face still-air conductances cell for cell
- the thermal kernel benchmark accepts a board, saved layout and positive repetition count while keeping project resolution outside its timed solve loop
- completeness-waiver: empty inputs (a board with no parts, and one whose parts dissipate nothing, both solve to a zero field, unit-tested)
- completeness-waiver: large inputs (the grid is capped at 512 cells per axis and the solve at 10k sweeps, so allocation and wall time are bounded by construction)
- completeness-waiver: unauthorized access (pure in-process arithmetic over caller-supplied structs; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O - every input is a struct the caller already holds)
- completeness-waiver: concurrent access (no shared or mutable state; a scenario's working buffers are owned by the one solve that built them)
- completeness-waiver: malformed encoding (inputs are typed structs, never parsed bytes; a non-finite dimension or watt figure is neutralised rather than parsed)
- completeness-waiver: integer overflow (cell indices narrow through numeric.checkedInt and the plane count saturates; everything else is f64 millimetre and watt arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## export_elmer_thermal

Public functions: build, parseVtu, compare, comparisonJson, comparisonMarkdown

Portable Elmer FEM handoff for the board thermal screen. The case is a separate
finite-element discretization of the normalized coefficients the built-in
solver actually used: one hexahedron through the thickness of every active
thermal-grid cell (cells outside an exact outline are omitted), equivalent
sheet conductivity in plane, volumetric component heat,
the selected still- or forced-air film loss on the two faces, and adiabatic
edges. The manifest records
the board, stackup-derived rules, component powers, grid, and coefficient-group
counts so the handoff remains auditable outside netlisp.

A drawn board-wide heatsink is solved in-process as one shared isothermal plate
node. The board-only Elmer mesh cannot reproduce that extra node: bare-PCB
contact is exported only as an explicitly labelled local-series approximation,
while package-top θJC branches are deliberately not projected. The comparison
command refuses either shared-plate case rather than publishing mismatched
results as a numerical cross-check.

`compare-elmer-thermal` exports the case, runs `ElmerSolver`, reconstructs its
renumbered nodes from VTU point coordinates, and writes JSON plus Markdown with
built-in and Elmer board/junction temperatures side by side. Both columns use
the same package and board-transfer uplift, so their delta isolates the board
spreading solve. This is a numerical cross-check of one screening model, not an
independent validation of PCB material properties.

- an exported case contains a native hexahedral mesh, the selected natural or forced-air heat equation, normalized thermal-rule manifest, and portable run instructions
- VTU point coordinates restore Elmer's renumbered nodal temperatures to the native mesh node order
- component watts are conserved as volumetric heat and each cell's two face losses equal the built-in cell-to-ambient conductance
- cells clipped away by a rounded or custom outline are omitted from Elmer bodies and face boundaries
- a comparison reports board maximum and per-part board and junction temperatures in JSON and a side-by-side Markdown table
- the CLI defaults to 25 C ambient and natural still air, accepts either forced-air rung and a saved layout, and can export without running Elmer
- the comparison refuses a non-converged built-in field, a failed Elmer process, or a malformed/missing VTU result instead of publishing partial numbers
- shared drawn heatsinks disclose whether Elmer approximates or omits their extra thermal network, and the comparison refuses those structurally incomplete projections
- completeness-waiver: empty inputs (a zero-sized or coefficient-less model is rejected, and the CLI refuses a board with no placed powered part)
- completeness-waiver: large inputs (the upstream thermal grid is capped at 512 cells per axis; mesh and report generation are linear in that bounded grid, and VTU reads are capped at 256 MiB)
- completeness-waiver: unauthorized access (the CLI reads the same local project files as other exports and writes only the caller-selected output directory; it exposes no network surface)
- completeness-waiver: i/o failure (directory creation, file writes, process spawn/exit, and result reads are checked and reported as command failures)
- completeness-waiver: concurrent access (generation uses per-command arena-owned buffers and no shared mutable state; callers choosing the same output directory own that race)
- completeness-waiver: malformed encoding (design/layout resolution is typed upstream, JSON strings use the shared escaper, and malformed numeric VTU arrays are rejected)
- completeness-waiver: integer overflow (the public builder rejects grid axes beyond the thermal solver's 512-cell cap before mesh count arithmetic)
- completeness-waiver: panic-free (point coordinates are checked finite and in-grid before float-to-index conversion; panic-freedom is otherwise enforced repo-wide by guardian's panic-budget snapshot)

## placement/pad_shape

Public functions: worldShape, worldCourtyardCorners, pointDist, shapeGap

- a concave pad's notch reads as clear copper, its prong as covered
- shapeGap clears a pad nested in a concave neighbour's notch
- the polygon distance scan returns the per-edge minimum with a single root
- simplifies a dense outline to a few corners within tolerance
- a rectangular pad off a quarter turn carries its four rotated corners, so its keepout is the land and not the land's square bounding box
- a rotated rectangular pad on a bottom-side part carries corners mirrored with the part
- a circle carries a round collision outline while an oval conservatively keeps its bounding box
- The widest scanline interval picks the larger copper lobe of a notched pad

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
- The instance sub-form registry reserves exactly the head atoms an instance body must not read as an inline property
- The sub-block sub-form registry accepts bridge, id, ids and reflow directly and keeps rename nested inside bridge
- The pins-block sub-form registry accepts pin, bus and group directly and keeps as-prefix nested inside bus
- The component sub-form registry reserves every structural field plus both definition head atoms

## docgen

- renderLanguageReference output matches the committed docs/language-forms.md so docs can never lag the registries
- extractSection returns one ## section of the rendered reference, matching the title case-insensitively
- SectionIterator walks every ## heading of the rendered reference in order
- The generated reference names every category key so (category …) docs follow the classifier map
- The generated reference has a Requirement checks section rendered from the checker's check_docs table
- Every isForm head atom under src/eval is reachable from a form registry or listed as a deliberate exception
- The generated reference renders one sub-form section per compound-form registry

## eval/fmt

- Formats voltage values with SI prefix and V suffix
- Formats resistance values with SI prefix and ohm suffix
- Formats capacitance values with SI prefix and F suffix
- Formats amperage values with SI prefix (uA/mA/A)
- Formats tilde escape sequences in format strings
- Formats mixed specifiers in a single format string
- The directives table and format()'s dispatch recognise exactly the same specifier characters
- Lowercase ~a displays scalar values without adding engineering-unit suffixes

## eval/instance

- (power …) on an instance records the authored dissipation and the component's thermal envelope rides along
- bare string arguments after the component bind physical pads 1, 2, and onward in order
- a pin function repeated on several pads resolves to the lowest pad and warns instead of picking by hash order
- numeric-aware pad ordering keeps a repeated function on the same pad across rehashes
- positional nets coexist with legacy pin declarations and all instance metadata sub-forms
- (near "REF" PIN) records the adjacency target with no own pad inferred at parse time
- (near … (own PAD)) records which of the declaring part's own legs docks against the target
- a (near …) missing its ref or pin warns and binds nothing rather than half a target
- an instance sub-form within two edits of a real one is an error naming the spelling meant
- an unknown sub-form head that is not a near-miss still becomes an inline property
- a pad token outside the part's known pad set is an error carrying the pad count
- strap-ok, nc-ok and a (near …) own pad are held to the same pad set as (pin …)
- a part with neither a pinout nor a footprint has an unknown pad set and every pad token passes
- a footprint's pad ids check the pads of a part that has no pinout file
- completeness-waiver: empty inputs (an instance with no net arguments retains the established component-only behavior)
- completeness-waiver: large inputs (positional pad numbering is a bounded linear walk over the parsed instance children)
- completeness-waiver: unauthorized access (pure in-process AST lowering with no request, identity, or authorization surface)
- completeness-waiver: i/o failure (instance lowering performs no filesystem, socket, or process I/O)
- completeness-waiver: concurrent access (each evaluator and accumulator is caller-owned and shares no mutable globals)
- completeness-waiver: malformed encoding (the parser has already produced typed string nodes before instance lowering runs)
- completeness-waiver: integer overflow (the pad counter is bounded by the source slice length and formatting returns allocation errors)
- completeness-waiver: panic-free (all new allocation and conversion failures propagate through the evaluator error set)

## eval/micro_forms

- pullup and pulldown lower to one resistor with explicit signal and rail nets
- divider emits two resistors and records a checked expected tap voltage
- led emits a resistor and diode and accepts an explicit anode net for migrations
- a shorthand value that is not the family's declared kind is rejected like a family call
- completeness-waiver: empty inputs (each shorthand diagnoses missing positional arguments and emits no partial circuit)
- completeness-waiver: large inputs (every form emits at most two parts and scans only its own bounded child list)
- completeness-waiver: unauthorized access (pure in-process AST lowering with no user, request, or authorization surface)
- completeness-waiver: i/o failure (microform lowering performs no filesystem, socket, or process I/O)
- completeness-waiver: concurrent access (all state belongs to the caller's evaluator and per-design accumulators)
- completeness-waiver: malformed encoding (typed AST strings and numbers are validated before component emission)
- completeness-waiver: integer overflow (resistor math uses finite floating-point inputs and IDs use bounded source keys)
- completeness-waiver: panic-free (arity, type, allocation, and invalid-value failures return explicit evaluator errors)

## eval/env

- Stores and retrieves values by name in an environment
- Resolves names through a parent environment chain

## eval/check_grammar

- every check_docs row's syntax leads with the kebab-case keyword parseCheck dispatches on
- parseCheck dispatches every documented check keyword to its Check variant via check_docs
- decoupling max-uf prevents bulk capacitors satisfying HF bypass rules
- decoupling rejects malformed or inverted capacitor bounds
- cap-rating defaults to the documented ceramic derating ratio when neither bound is written
- cap-rating rejects unknown, repeated or non-positive bounds
- max-distance accepts the four passive kinds with an optional value window and rejects an inverted one
- sequence accepts only the before relation word and a non-negative margin

## eval/pin_enrichment

- Fills a pin's asserted_fns with the unique alt when the pinout has exactly one alternative
- Fills a bare-integer pad's asserted_fns from its single alt

## eval/modules

- a component's (thermal …) form is cached on the component and a component-family declares one for its whole package
- Module calls bind purely positional arguments in declaration order
- Module calls accept named (param expr) arguments in any order
- Module calls mix leading positional with trailing named arguments
- A 2-list whose head is not a declared param stays a positional expression
- Binding the same module parameter twice is diagnosed by name
- A positional argument after a named argument is rejected
- Unbound module parameters are diagnosed by name at the call site
- Surplus positional arguments are diagnosed with expected and actual counts
- A syntax error in an imported library file is diagnosed with the file path and location
- component datasheet-review records preserve digest provenance, categories, and N/A rationale
- malformed executable requirements and electrical declarations produce diagnostics
- implementation metadata is evaluable but has no runtime value
- wrapped module roots retain defmodule provenance independently of their design-block title
- a warning raised inside an imported module is attributed to the module's own file
- an error raised inside an imported module is attributed to the module's own file

## eval/value-kind

- every value spelling the design corpus passes to a typed family is accepted
- a value carrying another quantity's unit or magnitude is rejected for the declared kind
- a value the unit decoder cannot place is accepted rather than guessed at
- completeness-waiver: empty inputs (an empty value string decodes to nothing and is accepted, like every other unplaceable spelling)
- completeness-waiver: large inputs (the decoder reads only the first whitespace token and at most its two suffix letters)
- completeness-waiver: unauthorized access (a pure string predicate with no user, request, or permission surface)
- completeness-waiver: i/o failure (classification reads the value string in memory and performs no I/O)
- completeness-waiver: concurrent access (the predicate holds no state and its inputs are caller-owned slices)
- completeness-waiver: malformed encoding (a value the decoder cannot place — corrupt, non-UTF-8, or simply unusual — is accepted rather than rejected)
- completeness-waiver: integer overflow (no arithmetic on the magnitude: the digits are skipped, never parsed into a number)
- completeness-waiver: panic-free (every path is a bounds-checked slice or a switch with an else, so it cannot panic)

## eval/footprint-pads

- a footprint's pad ids load as a set with numeric and alphanumeric ids normalized alike
- a missing or padless footprint yields an empty set that reads as unknown rather than as zero pads
- a footprint is read once and served from the evaluator cache afterwards
- completeness-waiver: empty inputs (an empty footprint name resolves to no pad record at all, and a padless file to the empty set)
- completeness-waiver: large inputs (the loader caps the read at the shared footprint byte limit and keeps only pad ids)
- completeness-waiver: unauthorized access (library reads inside the project directory, with no user or permission surface)
- completeness-waiver: i/o failure (a read error yields the empty unknown set, so a missing or unreadable footprint never fails a build)
- completeness-waiver: concurrent access (the cache belongs to one caller-owned evaluator and is shared with nothing)
- completeness-waiver: malformed encoding (a corrupt or non-footprint file parses to the empty unknown set instead of raising)
- completeness-waiver: integer overflow (pad ids stay text; the only counter is the hash map's own bounded size)
- completeness-waiver: panic-free (every failure path returns the empty set, so no allocation or parse error can panic)

## eval/suggest

- editDistance computes the Levenshtein distance between names
- unbound library name yields an import hint naming the missing import
- a near-miss name yields a did-you-mean suggestion from env and cache candidates
- a name with no close candidate reports a plain unknown-name message
- a fixed vocabulary yields the nearest spelling and never suggests an exact match

## eval/net_suggest

- a one-off net name suggests the established net it is closest to
- a net name beyond edit distance two or equal to a candidate yields no suggestion
- a neighbour carrying a different index is a numbered sibling, not a suggestion
- established nets are those with two or more connections plus every declared port
- the did-you-mean hint is an appendable suffix that is empty without a candidate
- an oversized or malformed name is skipped or compared bytewise so the scan never panics and cannot overflow its fixed buffers
- completeness-waiver: unauthorized access (a pure in-memory ranking over names the caller already holds; it opens nothing and checks no identity)
- completeness-waiver: i/o failure (no file, socket or process is touched — the candidates come from an already-evaluated design block)
- completeness-waiver: concurrent access (evaluation and ERC are single-threaded, and every call takes its candidates by value and shares no mutable state)

## eval/validate

- a dead-end net within two edits of a well-connected net suggests that net
- a dead-end net with no near neighbour keeps its plain message
- a design block with an empty net list produces no dead-end lint at all
- an oversized net name is linted with no suggestion and a malformed one is ranked bytewise — the scan never panics and cannot overflow
- completeness-waiver: unauthorized access (post-build lint over an in-memory design block; it opens nothing and checks no identity)
- completeness-waiver: i/o failure (the validator reads only the already-materialized block, never the filesystem)
- completeness-waiver: concurrent access (validation runs inline on the single evaluation thread that built the block)

## eval/evaluator
- prescanIds skips the requirement id a (req (id …)) sign-off reference names, so a derived requirement id never collides with its own reference

- A component-family attribute resolves a bound parameter to its value while an unbound vocabulary word stays literal
- a component-family value contradicting the declared parameter kind is rejected at the call site
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
- repeat evaluates every integer in its inclusive range and composes with arithmetic and fmt
- repeat binds its index lexically without replacing an enclosing binding
- repeat rejects fractional bounds instead of silently rounding them
- for evaluates its body once per listed item, binding strings and let-bound values in a fresh scope
- for binds its item lexically without replacing an enclosing binding
- for rejects a second argument that is not a parenthesised item list
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
- a pinout-less instance wiring three or more pads warns that the pad numbers are unchecked
- loadPinoutFile reads a library pinout at the class-owned lib_limits cap, so a pinout past the retired 256 KiB figure still yields its pin names

## id_insert

- findMatchingClose finds correct closing paren
- findMatchingClose handles strings containing parens
- insertPendingIds aborts on a duplicate pending token
- insertPendingIds aborts when a pending id already exists in the source
- insertPendingIds writes a child (ids …) sidecar and stays idempotent
- persistMintedIds writes minted ids back like the CLI and is a no-op when nothing is pending
- a CLI export pins the ids its evaluation minted, so a second export of an untouched design reproduces the same identity

## convert/footprint

- Converts a KiCad footprint file into S-expression format
- Captures F.Fab body outline and silkscreen polygons into the footprint
- Expands a custom pad's gr_poly primitive into a real polygon outline with bbox-derived pos/size
- Bakes a custom pad's at-angle into the emitted polygon in KiCad's counter-clockwise display sense
- Flattens a plain pad's exact quarter-turn at-angle into a width/height swap with no rotation token
- Preserves a plain pad's non-quarter-turn at-angle as a netlisp-frame pos rotation token
- Emits the pad number as a quoted token so an SI-shaped or spaced pad name reads back unchanged

## convert/symbol

- Converts a KiCad symbol file into S-expression format

## import_kicad

- Parses board footprints into parts with ref, value, MPN, and per-pad net + pinfunction
- Sanitizes KiCad net names (sheet-slash stripped, auto-net parens dropped, unconnected pads null)
- Emits a design with family-mapped passives, custom-part imports, net-grouped pins, and deduped thermal pads
- Generates pinout files from pad pinfunctions with numeric-then-alpha pin ordering
- Normalizes pad angles against footprint rotation when emitting footprint geometry
- Preserves a pad's non-quarter-turn footprint-local angle as a netlisp-frame pos rotation token
- Grows a preserved-angle pad's courtyard envelope to its rotated extents
- Renames pure-numeric and family-clashing component names so they stay referenceable atoms
- Sanitizes library names to lowercase slugs
- Writes a board's description, value, MPN and pin name back verbatim, so an escaped quote survives the import instead of being substituted
- Escapes the caller-supplied design title, the one import string that does not come through the tokenizer
- Keeps a pin id bare only when the tokenizer reads it back as the same text
- Quotes a pad number or pin id whose bare spelling the tokenizer would re-read as an SI value

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
- Strokes an exported footprint's F.SilkS art at the 0.15 mm the Gerber writer plots, and keeps the never-manufactured F.Fab at KiCad's 0.1 mm documentation default
- Emits silkscreen/fab (poly …) as a filled fp_poly and (rect …) as fp_rect on the target layer
- Emits a custom pad's (poly …) outline as a valid KiCad custom pad with (primitives (gr_poly …)) in pad-local coords
- Emits a pad's (pos X Y ROT) rotation as KiCad's (at X Y ANGLE) third argument, negated into KiCad's counter-clockwise frame
- Leaves a custom pad's exported (at …) unrotated because its (poly …) outline already carries the rotation
- Inflates the emitted F.CrtYd courtyard by BBOX_MARGIN_MM so KiCad matches the placement page's drawn courtyard
- Names the exported footprint's own layer and each SMD pad's copper/mask/paste layers with KiCad's spellings, with paste dropped on a no-paste pad
- a cap's decoupling target IC survives the flatten carrying the same sub-block prefix its ref-des takes
- Declares the flattened-netlist currency types in a neutral module beneath both the export and placement layers
- Re-exports the flattened-netlist currency types from the export layer as the same types
- Escapes the netlist's design name, the one field that is not a tokenizer slice, and copies already-escaped design strings through untouched
- Escapes a 3D-model filename in the emitted .kicad_mod so a quote or backslash in the file name cannot break the (model …) path
- Replaces a source .kicad_mod's (model …) block by scanning parens outside quoted strings, so a parenthesis in the model path cannot mis-splice the file

## export_kicad_sch

- A DNP instance is marked dnp and dropped from the BOM while staying on the board
- A bank cell budgets its label, its lead and one column per member
- A bank draws its caps smallest capacitance first, so bulk reservoirs end the row, with ties broken on ref-des
- A bank rail is drawn as one span per tap so every member joins it end to end
- A bank's caption names the IC it serves and the rail it gangs, and drops the IC when its cluster has none
- A bank's rails, taps and terminating ends land on the connection grid around its members
- A child sheet's symbols carry the root-then-sheet instance path and only the root carries sheet_instances
- A child sheet's symbols carry the root-then-sheet instance path while the root carries its own
- A clear run between two stub ends routes straight, and an offset pair takes a single bend
- A cluster packs into a compact block that keeps its members in the order given
- A component name that is not a legal KiCad lib_id token is sanitized
- A component with a matching vendor symbol is drawn from its real body and pins instead of a synthesised box
- A connection further apart than the wiring span keeps its label pair
- A declared decoupling cap and a small in-cluster net are drawn as wire, each net keeping exactly one label
- A decoupling cap is drawn beside the IC it declares, and other passives beside the hub they share the most nets with
- A decoupling cap's module-local IC reference is re-qualified with its own sub-block path
- A design name needing JSON escapes is escaped in the exported .kicad_pro rather than breaking it
- A diode glyph puts the cathode under its bar whichever pad the pinout numbers it
- A dotted net name only reads as a bypass stub when it carries a base, a reference, and a pad
- A file that is not a KiCad symbol library is rejected instead of half-read
- A fixture design drawn from a vendor symbol exports byte-for-byte to its own committed golden schematic
- A fixture design exports byte-for-byte to its committed golden schematic
- A ganged cap is turned so its rail leg is up and its ground leg down, and a part that is not a plain two-terminal glyph is never ganged
- A ganged cap stands on end between the bank's rails, with its ref-des and value read beside it and no stub of its own
- A glyph draws its stock body with both pins on the connection grid at the stock 3.81 mm reach
- A ground pin is drawn as a power symbol and every ground rail gets one PWR_FLAG driver
- A junction is reported exactly where three or more wire ends meet
- A label's justification mirrors its angle so the net name never draws across the symbol
- A large design splits into a root plus one child sheet per section, per unadopted module, and one for parts no section declares
- A multi-file export is byte-identical across runs, filenames included
- A negative sheet coordinate survives the junction point key intact
- A net naming a ref-des with no instance is reported rather than silently dropped
- A net whose pins land in different clusters keeps its label pair instead of a wire
- A pad the vendor symbol does not draw is added as a trailing unit rather than failing the export
- A part declaration that claims every pad leaves no catch-all unit behind
- A part with a vendor symbol in lib/sources is drawn from it, and --no-vendor-symbols forces the synthesised box everywhere
- A passive reaches the sheet as its stock KiCad glyph, at the stock pin reach and with its pin text hidden
- A passive ref-des is recognised by its leaf prefix even under a sub-block path
- A per-pin bypass-stub net is labelled with its base rail name, proven by its own host pad and an existing base net
- A project with no lib/sources directory, or an unparseable vendor file in it, yields an empty vendor index rather than an error
- A rail-class net name is recognised by the project's own supply classifiers, and a signal net is not
- A route is refused when every candidate would touch a foreign connection point
- A route may cross an existing wire but never tee onto one, overlap it, or enter a symbol body
- A sheet filename slug is lowercase, hyphen-separated, bounded, and never collides with a sibling
- A sheet with no hub at all still draws every part, in a single trailing cluster
- A small design stays on one flat sheet, and --flat forces that for any design
- A sub-symbol name yields its unit and body-style numbers only when it really carries them
- A symbol's pad set is the pinout widened by footprint pads and net-referenced pads, de-duplicated
- A two-pin passive draws its stock glyph while a wider part of the same class falls back to a box
- A vendor .kicad_sym written with its items directly under the symbol reads as one common unit carrying the pins and body
- A vendor body's sub-hundredth coordinates print exactly, with trailing zeros trimmed
- A vendor pin angle maps to the symbol edge its stub and label run from
- A vendor symbol is found by component, symbol, or pinout name, case-insensitively and with underscores folded onto hyphens
- A vendor symbol that repeats a pad number, or whose pins collide once snapped, falls back to a synthesised box
- A vendor symbol's per-unit sub-symbols read as separate units and its off-grid, high-precision geometry survives
- An empty design with no instances and no nets still exports a sheet that parses and self-checks
- An instance with (part …) groups places one symbol per unit, sharing its reference and keeping every pad drawn once
- Coordinates print as exact decimals and quoted text escapes quotes and backslashes
- Decoupling caps on one rail are ganged between a rail wire and a ground wire under a single label, replacing their own label pairs
- Decoupling caps sharing a rail and a ground gang into one bank, and a pair with too few members does not
- Each (part …) grouping becomes one KiCad unit and unclaimed pads form a trailing catch-all unit
- Each passive ref class picks its own stock KiCad glyph, and an unrecognised part keeps the box
- Every per-pin bypass stub of one rail is labelled with the rail name, so KiCad reads them as that one net
- Every symbol pin lands on the connection grid even when the vendor drew the part on a half-grid pitch
- Exporting a design twice produces byte-identical schematic output
- Fuzzing the vendor symbol reader with arbitrary bytes never crashes
- Grid snapping moves a half-grid coordinate one whole step and leaves an on-grid one alone
- Ground-class nets are drawn as power symbols while every other net keeps its label
- Integer square root and grid snapping stay exact
- Net labels carry the flattened net name verbatim, slashes and dots included
- Per-pin bypass stubs of one rail gang into that rail's single bank, the same merge their shared label already made
- Shelf packing keeps every origin on the grid, wraps into rows, and never reports a page below the minimum sheet
- Synthesised symbol pins land on the 1.27 mm grid with supplies on top and grounds on the bottom
- The export-kicad bundle gains the schematic sheets and project sidecars only when asked, leaving every netlist and footprint byte where it was
- The exported netlisp.kicad_sym names its symbols bare while a sheet's lib_symbols block names the same entries by lib_id
- The grid scan exempts a vendor body's drawing while still rejecting an off-grid connection point
- The project sidecars are a sym-lib-table, an fp-lib-table, a minimal <design>.kicad_pro, and a netlisp.kicad_sym holding every placed symbol
- The self-check accepts a well-formed sheet and rejects one whose symbol has been removed
- The self-check demands a junction dot where three wire ends meet and rejects one that connects nothing
- The self-check names the first flattened pin that never reached a symbol
- The self-check rejects a broken child-sheet link and a ground symbol naming the wrong rail
- The self-check rejects a dropped net label, a stray no-connect, and an unknown lib_id
- The self-check rejects a wire drawn across a pin, a diagonal wire, and a lost segment
- The self-check rejects an off-grid coordinate and a repeated pad number
- The text scan boxes a caption from its anchor and reports a clean sheet as having no overlaps
- The text scan reports a pair of overlapping labels and stays silent on a sheet whose texts clear each other
- A pin whose name is drawn at zero size contributes no text to the overlap scan
- Two or more same-net pins on one edge of a symbol form a gang, and a lone pin on a net does not
- A gang is refused when a foreign pin's stub tip lies on the run, or when its own tips are not collinear
- A gang's wire is one span per tap so every member joins it end to end
- A foreign pin part-way along an edge cuts the same-net run in two rather than losing both halves
- Same-net pins on one edge of a symbol are joined by one wire carrying a single label or ground symbol for the whole run
- Same-net pads are drawn side by side on their edge and drop their function names, so the edge can be ganged under one label
- A pin is drawn long enough to hold its own pad number, which KiCad straddles across it
- A pin whose function name only repeats its own pad number draws the number alone
- A pin's own name and number are drawn at the size its edge's pin spacing leaves room for
- An edge whose pins sit closer together than a line of label text has its runs dealt into two columns, and one on the usual pitch is left alone
- A stub column is dealt per contiguous same-net run, so the pads a gang joins keep one column and one adornment
- Spreading an edge is deterministic and never moves a pad that carries no net
- A symbol with no first-instance net map is never spread, so a shape built without one keeps its stubs
- Spreading a crowded edge moves only the stub and its label, never a vendor body's own pin geometry
- A net whose pins were dealt into two stub columns still gangs each column's own stretch
- A hub whose BOM resolved a part number displays it as a visible MPN field, a passive keeps it hidden, and a part without one gains no field
- A displayed part number sits under its symbol's Value, inside the cell reserved for it, and collides with nothing on the sheet
- A band whose heading repeats the sheet's own title is drawn once, as the title, and a module inside it drops the section prefix
- A power symbol's Value follows the body it names, whichever way the symbol was turned
- A rail-carried pin reserves the ground symbol's whole reach, and a labelled one its text plus the label's own lead
- The self-check rejects a global label sitting inside a wire rather than at its end
- The sheet carries the KiCad 10 header, one placed symbol per instance, and the instance UUID verbatim
- The vendor symbol reader models polylines, circles, arcs, and text and drops graphics it cannot read
- completeness-waiver: concurrent access (single-threaded and read-only with respect to the project; the exporter holds no shared state and returns bytes rather than touching the filesystem)
- completeness-waiver: i/o failure (an unreadable pinout or footprint degrades to a pads-only symbol rather than failing the export; the exporter itself writes nothing — the CLI writes the returned root and its siblings, and every write error goes through the CLI fatal helper)
- completeness-waiver: integer overflow (all geometry is i32 hundredths of a millimetre bounded by the clamped page, and the packing area accumulates in i64)
- completeness-waiver: large inputs (output is linear in parts x pads; every library read is capped at max_lib_bytes / max_footprint_bytes and the packed page is clamped to a sheet KiCad accepts)
- completeness-waiver: malformed encoding (library files — pinouts, footprints, and vendor .kicad_sym sources alike — are parsed by the shared sexpr parser and any parse failure degrades to "no data for this component"; the vendor reader carries a std.testing.fuzz harness, and the emitted bytes are re-parsed by that same parser before they are returned)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)
- completeness-waiver: unauthorized access (a local CLI over a project directory the invoking user already owns; every library file is opened read-only and server-side access control lives in serve/ward_auth)

## kicad_sch_push

Public functions: classify, commit, findLock, isLockName, planFor, run, targetFor

- The push names its root sheet and every child from the KiCad project the board path belongs to, not from the netlisp design name
- An existing sheet is replaceable only when it is netlisp-generated or an empty eeschema stub; a hand-drawn sheet or an unparseable file is foreign
- The lib_symbols block and the symbol_instances block never make a stub look drawn, because only the root sheet's direct children are scanned
- A missing sheet is created, a netlisp or stub sheet is overwritten, and a hand-drawn sheet refuses the whole push unless force is given
- A KiCad lock file in the project directory refuses the push by name, whoever holds it and whatever force says
- A lock file blocks the push even with force, because writing under it races the human who has the project open
- The push creates an absent .kicad_pro and sym-lib-table, keeps either when it exists, reports the row to add to a sym-lib-table with no netlisp entry, and never touches the fp-lib-table
- Committing writes every sheet and creatable sidecar, rolls a timestamped backup of what it replaced, and leaves the fp-lib-table and an existing .kicad_pro alone
- A refused plan writes nothing at all, so one blocked sheet can never leave a torn set of sheets behind
- The sync-kicad-sch CLI reads --project-dir, --dry-run and --force in any order and takes the lone positional as the design
- completeness-waiver: empty inputs (a design with no board declaration is the empty case and is rejected by name on every surface; an empty target directory is the ordinary first push, covered by the create path)
- completeness-waiver: large inputs (every read is capped — an existing sheet at max_sheet_bytes, a lock body at max_lock_bytes — and the emitted bytes are the exporter's, already self-checked before they reach here)
- completeness-waiver: unauthorized access (the CLI runs as the invoking user over paths that user already owns; the HTTP and CLI surfaces sit behind the existing ward middleware and the tool is registered as a mutation)
- completeness-waiver: i/o failure (a target that cannot be read classifies as foreign and refuses rather than being overwritten; a staging failure removes its temps and leaves the directory byte-identical)
- completeness-waiver: concurrent access (a KiCad lock in the project directory refuses the push outright — that is the concurrency guard — and the writes themselves are rename-into-place)
- completeness-waiver: malformed encoding (an unparseable existing sheet is foreign, so malformed input refuses instead of being replaced; parsing itself belongs to sexpr/parser, which is fuzzed)
- completeness-waiver: integer overflow (the only arithmetic is byte counting and per-action tallies over a fixed file list)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## export_fab

Public functions: Package.add, Package.addNamed, assemblyBomCsv, centroidCsv, panelAssemblyBomCsv, panelCentroidCsv, excellonDrill, frameFor, outlineRect

- ordinary manufacturing-package members are named from the package's one shared prefix; vendor-contract auxiliary files may retain an exact safe basename, and the job file's Path fields resolve both forms exactly

- the centroid CSV labels coordinate units in its headers and lists each part's unitless-numeric pose with its board side
- the centroid CSV drops DNP parts by default and keeps them under keep_dnp
- the fabrication BOM groups normalized MPNs into quantity rows and uses component identity only when MPN is absent
- panel assembly outputs repeat centroid coordinates in every board frame, multiply BOM quantities, and suffix matching references with their row and column
- the Excellon writer splits plated pads + vias from non-plated holes and groups tools by diameter
- fab writers share one y-up frame derived from the board outline
- an oval drill exports as a G85 slot at its minor-axis tool between the two arc centres, in both drill files
- each Excellon file declares its X2 file function, naming its plating and the copper span it drills through
- every hole is drilled by exactly one Excellon tool, even when its diameter sits inside two tool buckets
- the Excellon tool lookup partitions diameters, giving each hole exactly one owning tool
- panel Excellon repeats board drills in every panel frame and adds panel-only holes only to NPTH

## export_gerber

Public functions: planLayers, writeLayer

- plans the file set from the stackup (implicit 4-layer, declared planes, plain 2-layer)
- every copper Gerber file takes its name and X2 file function from the shared layer table row
- the mask, paste, silkscreen and profile files take their names and X2 file functions from the shared layer table's technical rows
- the fab package's job-file and Excellon drill members are named by the Gerber writer rather than by whatever assembles the archive
- CAM output filename detection recognizes layer, job, drill, and arbitrary inner-copper extensions from the Gerber owner
- the job file's LayerNumber counts the copper files the package actually ships, and every entry's polarity is the one its own Gerber carries
- every job-file Path is the exact archive entry name the package builds for that same file
- a vendor-named backing Gerber follows the board face and clears only matching-side footprint courtyards
- the implicit stackup's inner planes pour exactly the nets the router treats as plane-carried
- outer copper flashes side-correct pads and draws routed tracks/vias in the y-up frame
- a solver RF taper is emitted as one swept polygon rather than its centreline chord apertures
- a folded RF sweep emits overlapping simple dark regions instead of a self-crossing G36 region
- separately saved swept RF runs that share an endpoint receive one round junction collar, so a sampled fillet cannot leave a copper sliver before its straight continuation
- downstream geometry consumes an RF portal collar as physical copper even when no compact track handle was persisted
- mask opens pads at the resolved margin and tents vias; paste covers only same-side SMD pads
- pad openings separated by a positive web below mask-web are merged across that web instead of producing a mask-sliver DRC warning
- an IC exposed paddle opens the opposite-face solder mask at the exact EP outline, without the component-side mask margin
- non-ground outer-face traces and vias remain masked where they cross an opposite-face exposed-paddle window, and a non-ground pour suppresses that window
- a pad's own (mask-margin …) sizes its mask opening instead of the board rule, and a no-paste pad gets no stencil aperture
- a relieved max-freq net opens solder mask only with layer polygons, never via flashes
- a solver-authored pad taper remains mask-covered while the following uniform RF trace opens without sampled-width stair steps
- mask relief restores a local pad-shaped web and then reopens the pad without interrupting the exposed trace
- mask-relief pad-dam terminations use the authored corner fillet in the fabrication layer
- fence vias never emit solder-mask apertures; the widened RF polygon alone exposes overlapping copper
- (mask-relief 0) keeps a max-freq net tented and an authored pullback opts in a class without max-freq
- an inner plane pours solid copper and antipads only foreign holes
- an inner plane emits the pour engine's retained clear regions, so a foreign plated through-hole clears its full inner copper land rather than only its drill
- an inner plane applies full foreign-land and drill clearances after thermal copper, so a nearby spoke cannot repaint an antipad
- a plane thermal emits dark spokes only when their full bounding square stays inside one retained fill solid; otherwise the same-net land falls back to a safe solid connection
- an inner signal layer emits its routed tracks, via lands, and through-pad barrels; other layers' tracks stay off it
- outer and user pours emit the editor's computed contours and holes without rebuilding bounding-box antipads or adding thermal reliefs to own-net through-hole pads
- a seeded pour island enclosed by another component's clearance hole is restored after the clear-polarity pass
- an outer-layer user copper pour emits its carved fill as a G36 region on that face
- an inner-layer user copper pour emits its carved fill on that signal layer's Gerber, leaving a declared plane on another layer untouched
- a layer omits %TF.CreationDate unless the caller supplies one, so the writer stays byte-reproducible and only a served package is stamped
- copper apertures carry their X2 %TA.AperFunction (SMD pad, component pad, via land, conductor) and the profile is classified, while openings and clearances stay unclassified
- the edge layer closes the board outline; silk exports authored footprint artwork without synthesizing component ref-des text
- panel export repeats every fabrication layer in one shared array frame and replaces the source outline with the panel profile
- routed panels preserve rounded board corners as native profile arcs while tabs interrupt only straight edges
- each selected rail side emits two global top-copper fiducials near its ends with larger top-mask openings and no bottom-layer flashes
- a V-score panel ships its score centre lines as an explicit fabrication drawing
- Four L corners bound each isolated flattened sub-circuit, and its fixed-size horizontal label first tries a corner-near slot on the top or bottom edge
- overlapping same-face sub-circuit bounds each keep their own four-corner envelope instead of merging
- chained overlapping sub-circuits keep one independent corner envelope per member instead of merging transitively
- same-face sub-circuit box edges whose X or Y coordinates differ by at most 1 mm snap to the shared midpoint so nearby envelopes align
- same-face sub-circuit boxes align near-parallel edges within 1 mm even when the boxes do not overlap on the perpendicular axis
- nearby sub-circuit boxes on opposite board faces keep their own edge positions
- overlapping sub-circuit bounds on opposite board faces keep independent corner envelopes
- a keepout that would clip a sub-circuit box's corner marks shifts the box slightly so the marks still draw whole
- sub-circuit labels stay horizontal and inside Edge.Cuts by falling back inside their box when a fixed-size name cannot fit inline
- fixed-size horizontal sub-circuit labels search left and right near the corners of top and bottom edges before using any fallback
- blocked inline sub-circuit labels retry the same horizontal corner-near slots 1 mm inward or outward from the top and bottom edges
- a crowded sub-circuit box keeps its name by searching the nearest valid board space beyond the box fallbacks
- an editable board text tagged with a sub-circuit identity replaces exactly that generated name
- when edge and 1 mm offset slots are blocked, a fixed-size horizontal sub-circuit label searches anywhere inside its box while preferring corners
- sub-circuit labels respect concave Edge.Cuts instead of trusting the board bounding rectangle
- sub-circuit labels may cross courtyards when their inline slot is clear of actual pads
- sub-circuit labels search away from same-side pads instead of printing across them
- generated sub-circuit names reserve their chosen silk space from later labels on the same face
- generated sub-circuit corner arms retain every printable fragment while clipping only the spans crossing Edge.Cuts or same-face pads
- a pad crossing the middle of one corner arm splits that arm into two silk fragments without removing its printable ends or neighboring arm
- generated sub-circuit names and stroke fragments keep 0.2 mm of finished-silk clearance from pads, keepouts, and Edge.Cuts
- saved keepout polygons move generated sub-circuit names away and suppress corner legs that would enter them
- a generated pin-one dot prefers a slot clear of routed copper on its own face, so the marker never reads as a via sitting on a trace
- copper is only a preference for a pin-one dot, so a part whose whole search ring is covered keeps its marker instead of losing it
- physical test points get uniform horizontal 0.8 mm labels directly above their pad whenever that slot is clear
- a blocked test-point label searches nearby horizontal slots without crossing pads, keepouts, or Edge.Cuts
- test-point labels reserve their chosen position so neighboring labels on the same face do not overlap
- an editable board text tagged with a test-point identity replaces exactly that generated label
- non-testpoint components do not receive generated test-point silkscreen labels
- generated sub-circuit legs and names avoid mask-relieved bare copper like pads
- the mask margin comes from (design-rules …), defaulting to 0 mm for 1:1 pad openings
- a non-rectangular board emits its exact outline polygon on the edge layer
- board-level silkscreen text strokes onto the silk layer at its world anchor, and only on its own side
- fabricated silkscreen text uses scalable single-line vector glyphs with independent stroke thickness and one consistent cap height for capitals and digits
- fabricated glyphs occupy 90 percent of their nominal text height and advance proportionally by per-glyph widths
- the viewer strokes board silkscreen text from the same glyph table the Gerber writer fabricates
- silkscreen text scales with its nominal size (2x size gives 2x glyph extent)
- every fabrication package prints its eight-hex content ID at the bottom-right of top silk when that exact slot is clear
- automatic fabrication-ID placement stays clear of a face's perimeter solder-mask opening
- a blocked top-side bottom-right fabrication ID retries that exact slot on bottom silk before moving along the bottom edge
- a fabrication ID that is too wide for a narrow board rotates along its long axis instead of aborting page and CAM rendering
- when both bottom-right silk faces are blocked, fabrication-ID placement scans the bottom edge right-to-left before using another row
- fabrication identity is the deterministic eight-hex prefix of the full pre-mark Gerber and Excellon SHA-256
- an adopted fabrication identity keeps its editable position without entering the identity digest
- an adopted fabrication identity keeps its editable position when board changes produce a new ID
- an adopted fabrication identity is replaced, not duplicated, when composing the final silkscreen texts
- a physical fabrication-geometry change produces a different printed identity
- Gerber read-back preserves ordered polarity operations, filled contours, and native arcs for the Assembly CAM preview
- the Assembly CAM profile preserves the authored minor fillets after Gerber write/read-back and coordinate restoration
- generated-Gerber CAM region fillets meet straight edges without a visible chord sliver
- the Assembly CAM payload shares one board-edge field across its fabrication identity and every planned Gerber, remains byte-identical to independently seeded layers, and carries both Excellon drill files plus the fabrication digest
- a roundrect pad emits its rounded outline as a G36 region while a plain rect stays an R aperture
- a custom polygon pad's mask opening dilates its original fill with a round boundary stroke by the mask margin, preserving concave notches without self-intersecting offset rings
- custom polygon pad copper and mask preserve every authored outline vertex in Gerber while placement collision math may simplify a private copy
- a pad at a non-quarter angle emits a rotated region instead of an axis-aligned aperture
- the .gbrjob board thickness comes from the stackup (thickness …), defaulting to 1.6 mm
- copper and board-outline arcs use native G02/G03 interpolation instead of chord-only output
- Declares the routed-copper bundle in a neutral module beneath both the placement and export layers
- both silk faces and the fabrication-ID search share one silkscreen solve, and a prepared plan writes byte-identical silk
- silk label placement clears pads through a spatial index that answers every clearance probe exactly as a full pad scan
- an arc whose bow falls below the output lattice is emitted as its straight chord instead of a G75 arc
- a native arc's G02/G03 sweep direction is carried from the model, not re-derived from the rounded output coordinates

## pdf

Public functions: Doc.init, Doc.beginPage, Doc.finish, textWidth, encodeWinAnsi, validate

Minimal deterministic PDF 1.4 writer (`src/pdf.zig`, with font metrics /
WinAnsi encoding in `src/pdf_afm.zig` and the structural self-check in
`src/pdf_verify.zig`) — the output backend for the schematic PDF export. Object
table + cross-reference table + trailer, a pages tree with a per-page MediaBox,
one uncompressed content stream per page, and base-14 fonts only. Callers work
in y-down (SVG) coordinates and every page helper converts arithmetically
(`y' = height − y`); a CTM mirror is never emitted, because that flips glyphs.

- a multi-page document exercising every drawing operation passes the structural self-check
- page helpers take y-down coordinates and emit them flipped by the page height, never a mirroring transform
- Courier advances a fixed 600/1000 em and the Helvetica tables give per-glyph widths
- middle and end text anchors shift the origin by half and all of the measured width
- a non-WinAnsi glyph encodes through the fallback table and an unmappable one becomes a question mark
- malformed UTF-8 input encodes to question marks rather than raising
- two identical builds produce byte-identical output and a caller timestamp is the only variable
- an empty document and a page with no operations still emit a structurally valid file
- a non-finite or out-of-range coordinate saturates to the writable range
- a very large page count keeps one xref entry per object with matching offsets
- the self-check rejects a corrupted stream length, xref offset, and unbalanced content stream
- dash patterns, clip rectangles, and translation nest and unwind with the graphics-state stack
- fuzzing an arbitrary operation sequence never crashes and always passes the structural self-check
- completeness-waiver: unauthorized access (an in-memory byte writer with no request, file, or user surface; access control for the export endpoint lives in serve/ward_auth)
- completeness-waiver: i/o failure (finish returns the whole file as bytes the caller owns — the writer opens no file, socket, or pipe, so writing them out is the caller's failure domain)
- completeness-waiver: concurrent access (a Doc owns its pages and their content buffers with no globals or shared state; concurrent documents are independent, and a single Doc is used by one thread the way an ArrayList is)
- completeness-waiver: integer overflow (coordinates stay in clamped f64 arithmetic, while object numbers, byte offsets, and page counts are allocator-backed slice lengths bounded by the process address space)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)
- completeness-waiver: integer overflow (every number the writer emits — object ids, xref offsets, page counts — is a usize bounded by the length of the byte buffer it is describing, so a document big enough to overflow one cannot be assembled in memory first)

## zipfile

Public functions: write

- packs entries into a store-method archive the standard extractor reads back
- Fuzzing the writer with arbitrary entry bytes produces a well-formed archive

## bom

- Generates deterministic UUIDs in the expected format
- The canonical UUID text form stamps the version nibble and variant bits in one place
- Derives a stable UUID from an instance id
- Loads an empty BOM file without error
- Detects net overlap between components

## bom-resolve

Public functions: entryMatchesSource

- identity resolution is a fixed point: two consecutive resolveIdentities calls produce a byte-identical BOM
- identity is deterministic: each part takes uuidFromId(its stable id), independent of any prior .bom contents
- automatically assigned refdes reuse the prior BOM label by stable ID while newly inserted parts take numbers above the prior range
- a selected parts-table row persists its complete rated and analysis properties, replaces the previous row's managed properties, and may migrate an exact legacy MPN to its declared current MPN
- a same-MPN parts-row rating correction invalidates persisted selected-row evidence
- a stable id cannot carry an old MPN across a value or canonical-net change
- a fixed component sidecar cannot override source-authored manufacturer/MPN, including through differently-cased duplicate keys
- a non-passive component with a parts table round-trips its exact selected row instead of being mistaken for inline-only fixed identity
- resolving a non-passive parts-table family twice on one in-memory block keeps a stable source fingerprint and fresh BOM evidence
- a non-passive component with a parts table cannot fall back to inline fixed identity when its authored selection has no exact row
- manufacturing lookup refuses a value-only fallback when an authored passive specification has no exact row
- the read-only release presentation donates the current parts-table selection over a stale sidecar without rewriting it

## render_html

Public functions: parseSchematicView, renderToHtml, setupRenderCtx, renderHubSvg

- A passive bridging a single-hub-pin net and a multi-hub-pin net renders off its single-pin side
- A passive bridging two single-hub-pin nets has no anchor and keeps default placement
- Schematic pages expose a URL-backed Sequential and Functional slider with Functional as the default a bare URL renders
- Functional pin ordering terminates when several pins share one earlier partner
- The schematic page renders no thermal panel, linking out to /thermal/:name instead, so the page reads nothing but the design's own .sexp
- Each sub circuit card links out to its PCB layout in a new tab rather than embedding one, so no sub circuit opens a layout from the schematic page
- A sub circuit backed by a reusable module links to that module's own layout editor, and a path- or inline-sourced one to the design-scoped view of its slice
- The schematic page escapes the design name everywhere it appears — document title, heading, subtitle filename — and escapes each hub card's ref-des into its data-ref attribute
- An exported schematic HTML document inlines its drawing CSS, search index, and read-only search/navigation runtime and carries no server-only static asset references
- The schematic page's inline script blob escapes the less-than sign, so a design name, section name or ref-des carrying a closing script tag cannot terminate the element

## diagram/types

Public functions: viewLabel, viewId, viewSlug, viewColor, viewOf

## diagram/membership

Public functions: attachedSubBlocks, build, computeSubBlockAttachments

- Excludes power-classified nets so a power-producer sub-block is not adopted into a consuming section
- Lists one section's attached sub-blocks as indices in declaration order, shared by the schematic page and the PDF composer

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
- The standalone SVG document carries its own root, stylesheet and canvas so an archived .svg file stands alone
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

## diagram/system_of_boards

Public functions: renderSystemSvg, renderSystemDocumentSvg, classifySignal, laneColor, laneLabel

- Classifies an interface contact into a power, clock, comms, control, RF or ground lane by its canonical net name
- An unrecognised canonical net name falls back to the control lane
- Renders one board node per member carrying its role, design name, part number and revision
- Groups an interface's contacts into per-class lanes labeled with the class, its contact count and representative net names
- The ground lane collapses to a contact count instead of listing return nets
- The same system spec renders byte-identical SVG on every run
- A board-free system renders nothing while one-board and three-board systems still render
- A system with no interface contracts renders its boards with an empty spine
- The document form is a standalone SVG root with its own namespace, intrinsic size and painted background, and draws the same body as the page fragment
- completeness-waiver: empty inputs (a board-free spec writes nothing and an interface with no signals contributes no lane row, both covered by the board-count behavior above)
- completeness-waiver: large inputs (each lane names at most three representative nets and folds the rest into a count, so a wide contract cannot grow the fragment per contact)
- completeness-waiver: unauthorized access (the renderer reads an in-memory manifest snapshot and has no authorization or external access surface)
- completeness-waiver: i/o failure (no file or network access; the only failure modes are the caller's writer and allocator errors, both propagated)
- completeness-waiver: concurrent access (rendering is pure over an immutable spec with no globals and a request-local arena)
- completeness-waiver: malformed encoding (names are opaque byte slices escaped for XML on output; manifest decoding rejects malformed UTF-8 before this renderer sees it)
- completeness-waiver: integer overflow (contact tallies are bounded by the signal slice length and all geometry is f64 derived from those counts)
- completeness-waiver: panic-free (the lane fallback makes classification total, unresolved endpoint board names are skipped rather than unwrapped, and allocation failure is returned)

## diagram/diagram

Public functions: renderBlockDiagramTabs, renderSystemSvg

## render_svg

Public functions: renderSchematic

- Docks a (decouples ...) bypass cap on the bound hub pad instead of every pin of the rail
- A passive bias island shared by RF output pins and a busy supply rail is owned by the pin that continues to a declared output port, falling back to the lowest RF pin
- Ground pads fold into one row at their first physical occurrence while ordinary signals remain in pin order
- Ground and supply pins sharing a rail render one labeled stub and pin number per physical pad
- Hub pin spacing reserves rows only for connections the scene graph actually draws
- Pin groups classify supply and ground roles from function or net names
- An attached sub-block folds into its host section instead of paging its module title
- Sheet metadata classifies each authored sheet with the system-overview category
- Scene hubs serialize their authored sheet and the scene lists sheet categories
- A bare-integer pinout pad id carries its alternate functions into the scene graph
- A bridged sub-block port net keeps its wire and net label on the module's own pin
- A bridged sub-block port net renders its label without being coloured or flagged a board-boundary port
- A hub pin whose connections all filter away draws the no-connect glyph only when every net it reaches is a single-pin dead end
- A ground pad on a multi-pin rail draws no no-connect glyph when its group renders before any of the rail's spokes
- Two pads of one hub tied to each other draw no no-connect glyph
- A feedback divider return and its output pin on the same hub side draw as one outside rail with a single net label
- A Functional local direct return omits its redundant generated net label
- Functional differential inputs keep their coupling parts beside the hub, turn the boundary termination vertical, and retain both port stubs
- Functional hub pins joined by a passive-only signal path stay in the same column
- A Functional shared-bias pull-up is drawn from its own destination pin while the outside lane carries the common bias node
- A Functional shared RF bias rail directly joins compact P/M pull-up rows and centers its choke/bypass tree between them
- A Functional RF pair keeps its grounded termination and externally visible signal on clear outer rows instead of crossing the centered shared-bias tree
- Functional shared supply rails keep signal-owned RF bias chokes off unrelated pull-ups such as CE
- The Original schematic view keeps feedback endpoints label-connected without an outside cross-pin rail
- A supply pull-up and the IC's own supply pin retain labels instead of masquerading as a feedback loop
- Two feedback loops competing for one outside side fall back to net labels instead of drawing overlapping rails
- Functional direct returns rotate an outside-edge series resistor toward the destination pin while Original keeps it horizontal
- Functional direct returns rotate a one-inductor bridge vertically between two hub-pin rows
- Parallel passives returning to the same hub pin reserve their full branch-tree height instead of masquerading as a cross-pin island
- A parallel passive island reserves one grouped hub entry so its outer bus stops at the last visible branch
- A Functional turned series return shares the destination rail's x-coordinate so VTUNE closes straight down without an outside detour
- A vertical passive labels away from its hub: left of left-side parts and right of right-side parts
- Functional pin rows put the pin's own net before a ground shunt so the shunt draws below the pin; Original remains alphabetical
- Identical decoupling capacitors each render as their own labeled schematic symbol
- The scene graph preserves one entry per identical decoupling capacitor
- Net names are XML-escaped in the emitted SVG markup
- The shared passive-chain walk advances one body width and one pin gap per spoke, mirrored per side
- The shared terminal-group walk buses a repeated terminal off its nearest branch end and skips an insignificant one
- Both scene-graph pinout readers take the class-owned lib_limits cap, so a pinout past the retired 256 KiB figure still carries its pin names and alternates
- Functional boundary signals keep their labels on a dedicated row above a local ground shunt while internal shared-bias trees stay compact, and DNP passives are crossed and labeled

## decouple_key

- the per-pin origin key yields the host pad it encodes and nothing else does
- capacitance strings parse to farads across SI prefixes and the UTF-8 micro sign
- completeness-waiver: empty inputs (an empty key or value string resolves to no pad and zero farads)
- completeness-waiver: large inputs (both rules are single bounded scans of one short identifier)
- completeness-waiver: unauthorized access (pure string parsing with no request, identity, or authorization surface)
- completeness-waiver: i/o failure (neither rule performs filesystem, socket, or process I/O)
- completeness-waiver: concurrent access (both functions are pure and hold no mutable state)
- completeness-waiver: malformed encoding (an unparseable value reads as zero farads and an unstructured key as no pad)
- completeness-waiver: integer overflow (parsing is floating-point and slicing is bounded by the input length)
- completeness-waiver: panic-free (every failure path returns null or zero rather than trapping)

## erc

- a floating net within two edits of a well-connected net suggests that net
- a net pinned by (module-policy (net-class …)) is not reported as an inferred layout class
- a declared differential pair with exactly one wired lane is reported as half-connected, naming the wired lane and the open one
- a declared differential pair wired on both lanes, or on neither, is not reported
- a sub-block's differential pair tied on only one lane by the parent is reported as half-connected
- a module-local supply node whose name carries a supply token counts as the IC's power connection
- EMI coupling intent must bridge its declared domain to ground and cannot also claim supply decoupling
- an explicitly signal-typed rated input is not a supply rail and does not require decoupling
- explicit decoupling bindings must resolve to the cap's actual rail and return
- an adjacency binding must name a local non-passive target whose pin shares a net with the declaring passive
- adjacency and decoupling intents are mutually exclusive on one part, and only two-terminal passives may declare adjacency
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
- a bare-integer pinout pad id is checked for its alternates like an alphanumeric one
- an asserted function absent from a bare-integer pad's pinout row is rejected
- a quoted-string pinout pad id keeps loading beside bare-integer pads
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
- Does not flag an IC that declares at least one requirement, nor for passives
- Recurses sub-blocks and flags once per undocumented component
- an unbound HF decoupling cap on a multi-supply-pad rail is an error, with bound/bulk/rail-optout/per-pin/EMI-coupling caps exempt
- config straps tied to the rail are excluded from the supply-pad count, like the placer's hubTargets
- a dangling (verifies …) sign-off declared inside a reused module is flagged too
- A declared rail voltage over-stresses a rated pin sitting on the same net
- Emits no overvoltage violation when every driver stays inside the declared ratings
- Flags a driver whose output high exceeds a receiver's declared absolute-maximum voltage
- The strap direct-tie check shares the power-pin check's supply-rail vocabulary

## eval/power_budget

Public functions: analyze

- a sealed module's declared input-port current is one consumer on the rail it taps when the module annotates no pin there
- a connector module's declared input-port current is the rail's delivery envelope, not a consumer, when the port's net reaches only its own contacts
- a sibling sub-block's annotated pins load the parent rail its port ties to, so a rail whose consumers are all sealed in modules is no longer empty
- the sub-block load walk recurses, so a module nested inside a module still credits the board rail its ports chain up to
- only a sub-block net a port exposes credits the parent; a module's private net stays private however heavily it is annotated
- a regulator's back-computed input draw counts its output rail's sub-block loads exactly once, as one consumer row on the input rail
- a regulator's input draw is charged to a supply input, never to the rail an explicitly signal-kinded enable input sits on
- a top-level input power port is an external rail source, and its declared current capacity and synthetic physical terminal survive into the rail budget
- a standalone module page's own out power port rates the rail it exports, so a module routed as the board still has a current figure to size copper against
- only a `(current …)` on a top-level out port creates a rail, and an explicitly signal-kinded output never becomes one
- a parent board reads a module's rating through its sub-block port, and the highest declared capacity wins a rail whichever way it was declared
- a sub-block input power port's declared current is reported as a branch load for series sizing and never enters the rail's summed budget
- a rail an internally sourced board re-exports draws its declared output current as a load at a physical exit terminal, never as a second injection point
- a rail whose top-level pass-through pin already declares the current it exports is credited once, at that physical pad, not a second time at its @export terminal

## eval/thermal

Public functions: analyze, parseThermal, parsePower, packageTheta

- the library (thermal …) form records theta-ja, theta-jb, psi-jt, tj-max and the rated ambient range
- a malformed or empty (thermal …) sub-form value is rejected whole rather than recorded as a partial rating
- (power W) and (power (typ W) (max W)) both declare an instance's dissipation in watts
- a part's dissipation comes from its explicit (power …) ahead of any pin-current rollup
- a part with no declared power draws its dissipation from its annotated pin currents times the resolved rail voltage
- a pass-through connector's annotated pin currents are throughput, not dissipation, and charge it nothing
- a regulator's dissipation falls back to its back-computed conversion loss, attributed to the module's single hub IC
- a part with no declared theta-ja is screened against a package estimate and the row says the figure was estimated
- a screened row carries the part's declared theta-jb untouched beside its theta-ja, whether or not the theta-ja itself had to be estimated
- the package theta table is ordered most-specific-first so a footprint matching two hints always resolves to the same one
- the board verdict is the least intervention (still air, airflow, heatsink) under which every powered part clears its derated junction limit
- the board's ambient window is the tightest junction-derived maximum and the highest declared minimum, each naming the part that sets it
- an empty design, and one whose parts carry no dissipation, both return insufficient_data with nothing to judge
- a rail with no resolvable voltage and a part with no theta-ja are skipped with no panic and no half-computed row
- a regulator whose entire load lives in a sibling sub-block is still charged its conversion loss, because the rail walk credits sealed modules
- a scalar-efficiency converter whose input rail declares no voltage still reports its loss from the output side alone
- completeness-waiver: large inputs (one linear pass over an already-evaluated block, with no size-dependent path of its own to exercise)
- completeness-waiver: unauthorized access (a pure in-memory analysis over a block the caller already holds; it opens nothing and exposes no surface of its own)
- completeness-waiver: i/o failure (reads no files and no network; every input arrives in the DesignBlock the evaluator already built)
- completeness-waiver: concurrent access (read-only over the block, writing only into the caller's own allocator, so it holds no shared state to contend for)
- completeness-waiver: integer overflow (every quantity is an f64 watt, degree or degree-per-watt; the analysis performs no integer arithmetic)

## eval/power_sequencing

Public functions: analyze

- Emits one always_on row per sub-block output with no enable
- Orders dependent rail after its enable source
- Flags enable that never resolves to a known rail
- Routes enable through PG signal to source rail

## eval/design_block

- two instances authored with one ref-des are an error naming both source locations
- a repeat body that mints one ref-des twice is a duplicate like any other
- shorthand-generated ref-des never collide with each other or with authored ones
- each sub-block is its own ref-des namespace so two modules may both name R1
- module-policy form pins the placement class of named nets on the design block
- design-rules captures an optional ground-via maximum distance for SMD ground-pad plane stitching
- design-rules captures an optional finished via-wall plating thickness for power-capacity analysis

- stub form parses a placeholder part with role, mpn, category, and size
- stub auto-assigns a ref-des from the category prefix when ref is omitted
- stub signal contributes a named virtual pin tied to a net so the stub joins the netlist
- stub channels count stacks the block as N identical channels in the diagram
- bus-net expands one net tie per index in the inclusive range
- a net-class match-group sub-form records the group name and its tolerance, warning on a nameless group
- bus-net strided form distributes channels across over x ports with suffixes
- bus-net mapped form applies a parent suffix and an offset child port base
- sub-block bridge ties prefixed board nets to module ports with optional rename
- fanout places one component from COMMON to each listed net
- decouple-defaults lets decouple omit its component and host ref
- decouple with no defaults keeps its legacy explicit form
- decouple per-pin auto expands the decouple-defaults IC's pins on the decoupled net
- decouple per-pin auto without a decouple-defaults ic is diagnosed
- a decoupling binding resolves its pin through the target IC's pinout whichever of the two is declared first
- an adjacency binding resolves its pin through the target's pinout whichever of the two is declared first
- a decouple per-pin child records its host ref and resolved pad as a binding for pad and function-name spellings alike
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
- diff-port expands one base name into a paired _P and _N port carrying the differential kind
- diff-port replays every trailing port modifier onto both lanes
- a diff-port suffixes override renames both lanes and a long-form net base is suffixed per lane
- a section-scope diff-port expands two section ports typed differential
- a diff-port missing its direction is an arity error naming the form
- buildPort reads a bare trailing number as the port nominal voltage with an explicit nominal form overriding it
- kicad-pcb form captures the literal path on the design block
- stackup form captures layer count and plane assignments on the design block
- net-envelope form publishes an authored voltage envelope on the design block
- pdn form captures an explicit AC-domain target and source model
- stackup captures per-layer copper foil and core/prepreg construction details
- stackup process entries capture stepped soldermask and per-layer trapezoidal etch geometry
- fabrication backing parses an explicit face, editable regions, thickness metadata, and side-scoped footprint cutouts
- a named fabricator stackup expands to physical construction while board plane and pour roles remain authored locally
- a stackup dielectric captures its (er X) permittivity and defaults it when absent
- an out-of-range or misplaced (er X) is warned and dropped rather than stored
- a net class captures its impedance target and grounded-coplanar gap while rejecting invalid values
- (pour top|bottom "NET") is stackup sugar for a plane on the matching outer layer
- a bare 2-layer stackup declares no planes so ground routes as copper
- net-class profiles and memberships can be declared independently
- net-class diff-pair sub-form flags the class and captures an explicit or default gap
- net-class min-bend-radius sub-form captures the per-class bend-radius floor multiple
- net-class mask-relief sub-form captures the pullback and an explicit zero keeps the class tented
- net-class fence sub-form captures its pitch, layer count, offset, via and stitch net, and a bare (fence) opts in at every default
- net-class fence sub-form captures a mask-open layer count independently of its generated layer count
- a fence layer count outside 1–32 or not a whole number is warned and keeps the one-row default
- a fence mask-layer count outside 1–32 or not a whole number is warned and keeps the expose-all default
- a fence mask-layer count above the generated layer count is warned and clamped
- net-class keepout sub-form captures the halo distance and leaves its escape radius at the inherit sentinel unless authored
- an unknown child of a net-class fence or keepout records a lint warning naming it
- design-rules form captures the board-level default rules on the design block
- design-rules via-to-via sub-form captures the same-net via spacing rule
- design-rules pour-clearance sets the base copper-pour isolation gap and warns when it undercuts the copper clearance
- a design with no design-rules form leaves every rule at its zero (default) sentinel
- layout form parses (anchor "name") roots and (place "name" (rel "ref")) directives
- layout place resolves right-of/left-of/above/below into a relative offset from the referenced block
- layout place collects multiple constraints so a block is positioned by several references
- layout row form parses an ordered band of block keys
- layout group form parses a labeled region over member block keys
- layout edge form parses left/right edge-pinned block keys
- hosts form records the sub-block instance names a section owns
- section row and col hints seed diagram-layout rows when no explicit layout exists
- sub-block inside a section materializes globally and records syntactic section ownership
- compact decouple infers one host from pin functions and mixes per-pin with bulk capacitors
- bare top-level pins forms attach electrical pins instead of silently no-oping
- board form parses outline size, corner radius, edge lists, corners, and typed perimeter keepouts
- board form accepts an outline-approved digest only in the exact hex shape the drift finding prints, warning and dropping anything else
- board form parses repeatable authored keepout regions with their side, blocked families, allowed nets, and reason
- an authored board keepout with a rectangle outside the outline, a non-positive size, an unknown side or blocks word, or a missing rect or side is an evaluation error
- board-role form sets the explicit board/subcircuit role
- board-role defaults to subcircuit when the form is absent
- board-role remains authoritative whether it appears before or after the board geometry form
- power-plane defaults on, and off remains authoritative before or after board geometry
- power-plane off removes authored non-ground planes from subcircuits while retaining ground planes, stackup geometry, and whole-board declarations
- revision form captures id, date, and newest-first changelog
- revision form with only an id is present with empty date/changelog
- a design with no (revision …) form is unversioned (present=false)
- verifies req with an (id …) target parses as a stable-id sign-off leaving ref-des empty
- verifies req with a ref-des target parses as a ref-des sign-off leaving target-id empty
- a group naming both a concept section and a sub-block upgrades it to implemented
- a sub-block form directly after its section upgrades the concept section to implemented
- a concept section with no group tie or adjacent sub-block stays concept
- repeat materializes its design-scope body for every integer in the inclusive range
- repeat bodies compose with arithmetic and lowercase fmt generic display
- repeat derives distinct stable child ids from its anchor origin key and lexical index
- repeat ids sidecars override indexed child derivation for UUID-preserving migrations
- repeat composes with sub-block calls and gives each repeated module a distinct stable hierarchy
- for materializes its design-scope body once per listed item, composing ref-des and net names from a string item
- for derives distinct stable child ids from its anchor origin key and the item ordinal
- a for nested inside a repeat expands the whole product with the outer loop still owning every child identity
- a bus-port index range whose lane span would overflow the i64 subtraction is diagnosed and expands nothing
- a zero-based bus-port range still expands and the lane cap admits a span of exactly 4095
- a frequency-plan declaration is collected during the block body and evaluated after it, publishing its typed report on the evaluator beside the loop-filter ones

## eval/test_point

Public functions: parse

- Parses ref-des and net from the first two positional arguments
- Parses an optional (purpose "...") sub-form into the purpose field
- Parses (required-for ...) sub-form recognizing bring-up power clock reset debug and signal tags
- Returns null when ref-des or net positional arguments are missing
- Ignores unknown sub-forms and unknown required-for tags
- Parses (virtual) as an explicit marker-only test point
- Materializes a physical testpoint instance and pin-1 net by default
- Keeps (virtual) test points marker-only with no physical instance or pad net
- Materializes test points inside sections and preserves section membership
- Materializes test points inside nested sections and preserves nested membership

## eval/electrical

Public functions: parse, parseSubForms

- Parses pin function name from the first positional argument
- Returns null when the pin function name is missing
- Rejects malformed values for recognised electrical fields
- Recognises every electrical-type enum atom
- Parses voltage level fields v-ih-min v-il-max v-oh-typ v-ol-typ max-voltage
- Ignores unknown sub-forms for forwards compatibility
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
- Preserves a rail's rated voltage range for worst-case release checks
- Returns empty slice when design declares no rails

## component_classification

Public functions: isActiveSemiconductor, isPassThroughConnector

- isActiveSemiconductor exempts the MK mounting-hardware ref-des class
- isPassThroughConnector identifies a connector by its authored J/P class or by a supply-free positional pinout
- isPassThroughConnector keeps dissipating inert parts (LED, crystal) out of the connector class
- isActiveSemiconductor exempts a connector carrying an importer-default U ref-des
- isActiveSemiconductor exempts LEDs crystals and tactile switches wearing a U ref-des
- isActiveSemiconductor keeps a supply-pinned IC active when its description names an inert class
- isActiveSemiconductor reclassifies nothing when no pinout corroborates the description
- completeness-waiver: empty inputs (an empty ref-des yields an empty class that matches no table, an absent description contributes no vocabulary match, and a part with no pinout is left on the ref-des path unchanged)
- completeness-waiver: large inputs (classification is one pass over a fixed vocabulary and the instance's own property slice; nothing is accumulated and nothing is allocated)
- completeness-waiver: unauthorized access (a pure function over an already-built Instance — it opens no file, reads no environment, and grants no capability)
- completeness-waiver: i/o failure (no I/O here; the pinout read happens once at instance-build time and its failure is already recorded as `known = false`, which this treats as "no evidence")
- completeness-waiver: concurrent access (no shared or mutable state — the instance is taken by value and every table is comptime-constant)
- completeness-waiver: malformed encoding (descriptions are matched byte-wise with ASCII case folding, so non-UTF-8 bytes simply fail to match rather than being decoded)
- completeness-waiver: integer overflow (the only arithmetic is a saturating pad count made at build time and compared, never summed)
- completeness-waiver: panic-free (every path is a bounded slice comparison over caller-owned memory with no indexing beyond a length-checked loop)
## eval/net-envelopes

Public functions: build

- Derives a voltage envelope for a sub-block-internal net across a module-internal ferrite bead
- An internal input port's rated range is a pin tolerance and does not widen the net it sits on
- Leaves a design with no sub-blocks and no declarations unchanged
- An authored net-envelope declaration bounds a signal net the topology cannot derive
- Reports a declared envelope that fails to cover the envelope the design already proves
- A series resistor propagates a known envelope onto a capacitor-terminated node as one correlated domain
- An inductor bias feed derives its bias node from the rail it taps
- A device pin on a derived domain widens it to the device's own known supplies
- A device with no envelope-known net anywhere poisons the domain it drives
- A divider tap anchored by two different known nets is refused rather than guessed
- A DNP series resistor is absent copper and derives nothing
- An inductor between two unknown nets is a switching coil and merges nothing
- completeness-waiver: empty inputs (a design with no sub-blocks, no rated ports and no declarations returns both slices empty, which is the covered no-envelopes-proven case)
- completeness-waiver: large inputs (one flatten plus a near-linear union-find over its nets, the same pass the netlist exporter already runs on every board)
- completeness-waiver: unauthorized access (a pure derivation over an already-evaluated block; it opens no file, reaches no network, and consults no external state)
- completeness-waiver: i/o failure (no I/O — the design has already been read and evaluated by the time this runs)
- completeness-waiver: concurrent access (single-threaded inside design evaluation, reading an immutable block and writing only caller-owned slices)
- completeness-waiver: malformed encoding (net names arrive as evaluated slices, compared bytewise; nothing here parses an external encoding)
- completeness-waiver: integer overflow (voltages stay in f64 and the only integers are slice lengths the allocator already bounds)
- completeness-waiver: panic-free (every lookup is an optional consulted with orelse, and an unorderable declaration is skipped rather than asserted)

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

## review_thermal

Public functions: summaryLines, headlineVerdict, cells, scenarioCells, scenarioNote, writeJson

Presentation and serialization for `eval/thermal.zig`'s lumped screening — the
one place a `BoardThermal` becomes the sentences, the table cells and the JSON
that the schematic page's review panel, the markdown report, the review PDF,
the review JSON, `GET /api/thermal/:name` and the `describe_thermal` CLI tool
all show. Sharing the formatted CELLS (not merely the numbers) is what keeps
the three tables reading alike: the rounding, the power-source marker and the
`est.` flag on a package-derived theta are decided once. Every shared string is
WinAnsi-encodable on purpose, because the PDF composer draws these same
sentences through a base-14 font and an unencodable glyph becomes a question
mark on the page — hence `theta-JA` in the coverage line, while each renderer's
own column headers are free to use the Greek letter.

- the verdict renders as one plain sentence naming the part an intervention hangs on
- the ambient window names the part setting each end, and an end nothing computed is said in words rather than printed as a bound
- the coverage line counts the parts whose power is known, unknown, declared-theta and estimated-theta
- insufficient data carries a hint naming the power, pin-current and thermal forms, and a board with real data carries none
- a part's cells carry the power source marker, an est. marker on an estimated theta, and a dash for every figure the analysis could not compute
- the shared JSON body spells unknowns as null, the estimated and defaulted flags as booleans, and both enums as their tag names
- a scenario's cells name the cooling, the hottest part and the ambient ceiling with the part that sets it, and dash every figure the solve could not produce
- a missing ladder carries the reason a surface prints in its place, falling back to the shared needs-a-layout sentence when nothing explained it
- when a cooling ladder exists the headline verdict and sentence come from the board model, and the package-level screen is kept below it labelled with the JEDEC board that makes it optimistic
- with a cooling ladder the ambient window's hot end is the governing scenario's ceiling and names the cooling it assumes, adding the still-air ceiling whenever passive operation is not viable
- the shared JSON body carries the board-coupled verdict as its own additive key, null when there is no ladder, while the package-level verdict key keeps its meaning untouched
- the shared JSON body carries the scenario ladder as absolute degrees per rung, including its physical heatsink interface, shared-plate temperature and directional package path, or a null ladder beside the sentence saying why there is none
- completeness-waiver: empty inputs (a board with no rows renders prose and no table, and an unknown figure is a dash or a JSON null, both covered by the bullets above)
- completeness-waiver: large inputs (one linear pass over the already-computed rows; a bigger board only lengthens the slice it formats)
- completeness-waiver: unauthorized access (pure formatting over a value the caller already holds; it opens nothing and exposes no surface of its own)
- completeness-waiver: i/o failure (reads no files and no network; every input arrives in the BoardThermal the analyzer already built)
- completeness-waiver: concurrent access (read-only over its argument, writing only into the caller's own allocator, so it holds no shared state to contend for)
- completeness-waiver: malformed encoding (strings are escaped through the shared json_writer helpers, and the shared sentences are WinAnsi-encodable so the PDF path cannot produce a fallback glyph)
- completeness-waiver: integer overflow (the counts are usize tallies of an existing slice; every measured quantity is an f64 watt, degree or degree-per-watt)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## thermal_scenarios

Public functions: boardOf, spreaderLayersOf, sheetOf, coverageOf, ratingsCap, partInputs, inputsFor, resolveMountedTarget, rowsByPart, solveAt, ladderAt, paintAt, boardVerdict, governingRow, rowFor, scenarioLabel, coolingClause, interventionPhrase

The one seam between `eval/thermal.zig` (what each part burns, and what it is
rated for) and `placement/thermal_field.zig` (where that heat goes once the
parts have positions). Four surfaces need the projection — the `?thermal=1`
heat-zone image, the `scenarios` block of `GET /api/thermal/:name`, the
`describe_thermal` CLI tool sharing those bytes, and the review document's
cooling-scenario table — and a reader comparing the picture against the table is
entitled to assume they are the same simulation, so it is written once here.

Two things are said out loud rather than guessed. A design with no authored
`(board …)` outline is solved over its parts' bounding box and the substitution
is reported, because a board bigger than its parts spreads more heat and the two
are genuinely different answers. A powered part that matches no placed part is
SKIPPED and named, never docked onto a position it does not have, because
dropping a watt on the floor would make the whole field quietly optimistic.

Everything handed back is ABSOLUTE °C at a caller-chosen ambient, converted here
from the solver's ambient-free rise field — one solve serves every ambient, and
the arithmetic that adds the ambient lives in exactly one place.

- the board carries the placement's exact authored outline as well as its bounds, and a design without one falls back to the parts bounding box with the substitution reported
- screened parts are matched to placed parts by exact ref then by unique leaf, and a row matching nothing is left unplaced for the solver to report as skipped
- layout thermal rows follow scoped origin identity across ref-des renumbering before considering a recycled exact ref
- the spreader layer count is the implicit four-layer board when no stackup is declared and the declared inner planes plus two outer faces when one is
- the conducting sheet is read off a declared stackup's finished thickness, per-foil copper weights and dielectric hop, and a design declaring none falls back to the solver's own screening convention
- a part carries its mounted side and the vias standing inside its own courtyard into the solver, so a bottom-side part blocks the bottom face and a via array under a land is counted
- outer copper coverage is sampled from the board's own poured fills onto the solver's cells, and a design whose rules declare no stackup hands the solver no coverage rather than a guessed one
- the ratings cap is the tightest declared operating maximum and never the lumped screen's junction-derived ceiling
- the ladder reports absolute temperatures at the caller's ambient, shifting junction and board figures by it while leaving each part's maximum ambient alone
- each placed part is handed back the very row the facts report for it, and a part the screen said nothing about is handed none
- the ladder's rung fields are solvable on their own, ambient-free, so a caller can retain one solve and read it at any ambient afterwards
- a scenario can be painted from an already-solved ladder, giving the same field, row and part rows as solving that scenario fresh
- every scenario carries a label a table can print, and the heatsink row names the part its sink is bolted to
- a board whose parts are all unplaced still solves, reporting every screened part as skipped rather than failing
- the board verdict is the first cooling scenario in ladder order under which every judgeable part sits the shared derate margin under its junction limit, and over_limit when none does
- completeness-waiver: empty inputs (a board with no placed parts and a screen with no rows both solve to an all-skipped ladder over a zero field, unit-tested above)
- completeness-waiver: large inputs (one linear pass per part over slices the caller already holds; the solve itself is bounded by thermal_field's own grid and iteration caps)
- completeness-waiver: unauthorized access (pure in-process projection over structs the caller already holds; access control lives at the serve boundary)
- completeness-waiver: i/o failure (no I/O — the screened rows and the solved placement both arrive as values)
- completeness-waiver: concurrent access (read-only over its arguments, writing only into the caller's own allocator, so it holds no shared state to contend for)
- completeness-waiver: malformed encoding (inputs are typed structs, never parsed bytes; ref-des are opaque byte slices compared for equality and never decoded)
- completeness-waiver: integer overflow (part indices are bounds-checked slice offsets with an explicit ambiguity sentinel; every measured quantity is an f64 millimetre, watt or degree)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## render_thermal_png

Public functions: render, rampColor, View, Options

The heat-zone image: one solved cooling scenario painted over the board it was
solved on, served as `GET /api/pcb-png/:name?thermal=1` and returned by the
`get_pcb_layout_image` CLI tool with `thermal:true`. `GET /api/thermal/:name`
already answers the same question in numbers and the numbers are the authority;
what they cannot do is show WHERE the heat is, and that is a picture. The caller
hands over a solved scenario plus the absolute-°C rows derived from it, so the
image cannot describe a different board, scenario or ambient than the JSON —
nothing here re-solves anything.

Four channels carry the field so no single one has to be trusted alone: the
colour ramp, isotherm lines at fixed fractions of the absolute 25–125 °C scale
(which read in greyscale and under any colour blindness), each powered part's
junction temperature printed on it, and the legend bar captioned with the
absolute temperatures its two ends stand for. The ramp's luminance climbs monotonically
from deep blue through cyan to yellow and then turns red — a bounded, deliberate
exception, since a strictly luminance-monotone ramp cannot end in a saturated
red at all, and the other three channels are what carry the hot end.

- the heat-zone image is a valid PNG whose pixels differ between two cooling scenarios of the same board
- an authored non-rectangular outline clips the heat wash and is stroked as its exact polygon instead of the rectangular bounding box
- the field is painted against one absolute 25 °C to 125 °C scale, clamping temperatures outside it so the same colour means the same heat across boards and cooling scenarios
- absolute temperatures on the image follow the requested ambient, shifting one for one with it
- the ramp runs cold to hot through one blue, cyan and yellow band each, ends on red, and clamps outside the unit interval
- a reported part always keeps its label while an unreported one keeps its ref only when the text fits its own box and lands clear of every label already placed
- the heat-zone image labels every part the screen reported on and drops the refs of small unreported parts, so a dense board's temperatures stay readable
- a board that dissipates nothing still renders, painting a flat field with no hotspot marker
- completeness-waiver: empty inputs (a board dissipating nothing renders a flat field with no hotspot, and a placement with no parts frames the solved grid alone, both covered above)
- completeness-waiver: large inputs (the output is clamped to a fixed pixel band and painted in fixed-size blocks, so cost follows the image and never the board)
- completeness-waiver: unauthorized access (pure rasterization of values the caller already holds; access control lives at the serve boundary)
- completeness-waiver: i/o failure (writes no file and reads none — the PNG bytes are returned to the caller)
- completeness-waiver: concurrent access (read-only over its arguments; the canvas it paints is created and owned by the one render that returns it)
- completeness-waiver: malformed encoding (labels are drawn through the shared 5x7 ASCII font, which renders an unmapped byte as blank rather than mis-decoding it, and no text is parsed)
- completeness-waiver: integer overflow (pixel extents are clamped into the canvas bands before narrowing, and colour channels are clamped into 0..255 before the byte cast)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## review_md

Public functions: renderToMarkdown

- emits markdown header for design name
- the markdown Thermal section carries the verdict sentence, the ambient range, one row per screened part, and the coverage line
- the markdown Thermal section carries the cooling-scenario table with one row per scenario, and prints the missing-layout reason when there is no ladder

## system_review_md

Public functions: parse, renderMarkdown, renderMarkdownAlloc, renderHtml, renderHtmlAlloc, stripEmphasis, deinit, uncheckedChecklistCount

- parses the complete bounded authoring profile into a public AST and renders stable Markdown and inert HTML
- renders paired asterisk emphasis as strong and em in both the Markdown and the HTML face, and canonicalizes back to the same source on re-parse
- keeps unpaired, empty, space-padded and nested asterisk runs as literal text instead of failing the document
- folds a wrapped list item's continuation lines into that item, ending the item at any new block and the list at a blank line
- rejects active markup, external targets, traversal, encoded paths, and unsafe image types before rendering
- accepts only approved, syntactically valid netlisp directives occupying their whole source line
- treats fenced code as literal text while escaping it in HTML and refuses unterminated fences and code spans
- enforces source, line, structural, table, and list bounds without partial output
- normalizes line endings and escapes authored text and attributes in deterministic output
- completeness-waiver: empty inputs (an empty or whitespace-only source parses to an empty document and both renderers emit an empty fragment)
- completeness-waiver: large inputs (caller-configurable byte, line, block, inline, list-item, table-row, and table-column ceilings fail before unbounded output is produced)
- completeness-waiver: unauthorized access (the module performs pure in-memory parsing and rendering; package authorization and file loading remain at the caller boundary)
- completeness-waiver: i/o failure (the parser performs no I/O and writer failures are returned by the streaming renderers)
- completeness-waiver: concurrent access (each document owns a private arena and the module has no mutable globals, filesystem state, or shared cache)
- completeness-waiver: malformed encoding (invalid UTF-8 and forbidden control bytes are rejected before normalization or AST construction)
- completeness-waiver: integer overflow (all input-driven counts are bounded by slice lengths and explicit usize ceilings before renderer arithmetic)
- completeness-waiver: panic-free (syntax and safety violations use explicit errors, allocations propagate OutOfMemory, and every optional delimiter lookup is checked)

## system-review

- readiness reports the waiver register drift and a board whose release layout is not frozen fails board review
- evaluated source paths retain the buildable src/lib shape in a review package
- interface evidence resolves stable sub-block connector handles through the canonical flattened netlist
- per-board block diagram evidence is one standalone SVG document rendered from the same evaluated design, omitted when there is nothing to draw
- per-board block diagram evidence is archived as boards/<role>/diagram.svg in draft and release, reproducibly, and omitted when the design has no diagram
- the only archived SVG is the tool-rendered per-board block diagram; SVG is refused at every other archive path in draft and release alike
- generated power evidence carries each rail's budget row beside the voltage its design declares, including through a ferrite-bridged alias
- generated thermal evidence is the heat rollup — dissipation, the hottest part, the ambient window and the population the screen actually saw
- generated thermal evidence headlines the board-coupled verdict and the window that goes with it, keeping the datasheet package screen only as a labelled estimate
- generated rule-check evidence counts every ERC severity and assertion outcome, and retains a capped list of the error-severity findings
- generated mechanical evidence pairs the declared outline and stackup with the selected layout's measured edge and flags a drift between them
- the mechanical summary and the fabrication-readiness outline finding are the same predicate, agreeing on an unapproved, an approved, and a stale-pinned non-rectangular outline alike
- generated loop-filter evidence copies each PLL report's screens out of the evaluator, keeping only the non-passing ones beside the population verdict counts
- generated frequency-plan evidence copies each declaration's screens out of the evaluator, keeps only the non-passing ones, and retains each product's band hull rather than its branches
- the generated BOM rollup counts the exact placements, lines and do-not-populate parts the archived bom.csv carries
- the generated power, thermal, mechanical and BOM sections render each board's own computed rows
- the generated loop-filter section renders each population's bandwidth and phase-margin ranges, its failing screens and the charge-pump schedule
- the generated frequency-plan section renders each sideband's band closure, image rejection wording, both diagonal counts and every enumerated product's placement, claiming a level only where one was declared
- the generated frequency-plan section renders an unrealizable sideband as a stated refusal and names its own retention caps whenever a product or screen list truncates
- failing and warning frequency-plan screens join the aggregated open-items register beside the loop screens, one row per screen
- the generated ERC section reports counts by severity and lists the error-severity findings, stating the cap when it truncates
- every generated section renders bounded, safe Markdown that is deterministic and states its own no-data line when the design declares nothing
- the generated thermal section states each board's board-coupled verdict and quotes the datasheet package screen only as a labelled estimate
- the generated thermal section discloses how much of the screened population carries no power data whenever any part does not
- the aggregated open-items register lists every failing package gate, board review note, ERC error and failing loop screen, and says so plainly when there are none
- no open-items row carries a summary that only restates the severity column beside it
- the system block diagram is archived as review/system-diagram.svg, referenced by the generated system-diagram section, and admitted as the one system-level SVG
- system Markdown becomes a structurally valid searchable PDF with draft marking
- the offline HTML dossier is one self-contained file with no external request; its only executable content is the inlined read-only Assembly board viewer and the small shell that installs cached model sprites and drives board-side selection
- the offline HTML dossier ships beside the combined Markdown and PDF in draft and release, carrying the draft marker only in draft
- the HTML dossier carries the draft marker only in draft mode and numbers one section per manifest document
- the dossier places its sticky section index beside the leading board gallery so the sidebar remains visible throughout the interactive board views and the one continuous evidence document, without repeating section titles
- every board leads the dossier with one Assembly physical-review viewer, defaulted to top and offering top/bottom selection plus the shared wheel/pinch zoom and drag-pan behavior; the viewer uses solder mask/exposed-copper rendering and deduplicated cached 3D-model sprites, no PCB-editor Layout figure is integrated, and the sidebar contains section navigation rather than interface-contact metrics
- the dossier leads with a structured gate summary and distinguishes waiver-required evidence from an accepted release waiver
- the HTML dossier inlines each board's block diagram and omits the figure when the design has none
- the HTML dossier is a pure function of its inputs and renders byte-identically on repeat
- a generated engineering section's no-data line reaches the HTML dossier through the same single expansion the Markdown face renders
- every identity string interpolated into the HTML dossier is escaped rather than emitted as markup
- identity text reaching the HTML dossier is escaped, so no manifest string can become page markup
- long UTF-8 review lines wrap only between complete codepoints in the generated PDF
- the review PDF lays emphasised Markdown out as plain words, printing no emphasis markers outside fenced code
- board archive roles are unique and authored review documents are Markdown; binary evidence uses the bounded assets area
- a board release reports CAM blocking and waiver conditions independently
- independently allocated fabrication snapshots compare their identity strings by value
- draft archives are visibly non-fabrication packages and contain no nested board release ZIPs
- archive members are safe, unique project-relative paths, and draft validation rejects CAM and nested ZIP payloads
- optional active documents may be absent without blocking release, while every required active document and required checklist must pass
- duplicate attestation or source paths are accepted only when their bytes agree
- the release manifest states which self-referential inventory and checksum members it excludes
- the system release token binds the stable content lock to every ordinary board release token
- CLI system review commands share project, system, and output argument parsing
- CLI system review commands reject unknown flags, missing option values, duplicate positionals, and draft output flags on readiness checks
- flat safe workspace assets are content-validated, deterministically hashed, and archived beside combined Markdown under review/assets
- system-review file reads resolve canonically below the project root and reject parent-symlink escapes
- system-review mutations require the custom review header, document replacement requires If-Match, and release JSON is size-bounded
- the standalone draft dossier is the archive's own HTML member composed without the archive around it
- a dossier request over a workspace that cannot compose answers the composer's diagnostic rather than a crash or a partial page
- the system review page offers the dossier as a page action beside the draft download, pointing at the system's own dossier path
- a strict assembly sidecar repeats reviewed board definitions as uniquely identified physical instances and preserves its authored pitch, and the system workspace opens as a 2D solved heat-field map with a separate 3D assembly view and bounded wheel gestures, a D driving-dimension shortcut, and direct extrusion of a closed active sketch
- a dossier request answers from the current or explicitly stale composed copy, or a loader when no copy exists, without ever composing inside the request
- a completed dossier persists atomically below out and is rehydrated after restart for the same tool build, marked stale when its project tree changed and rejected when its bytes are damaged
- one dossier composition per system is ever in flight, and a reload during one joins it rather than starting a second
- a system-review mutation marks the retained dossier stale and retires the compose in flight, so old results stay readable without being presented as current
- a failed dossier composition is recorded against its system and reported rather than retried on every reload
- a dossier composition that failed in the background reaches the next page request as the composer's diagnostic
- a saved review document makes the prior dossier load immediately with a stale notice instead of deleting it or automatically recomposing it
- the dossier's board-free refusals are decided without starting a composition, so a broken workspace is refused on the first request
- the dossier status endpoint reports composition state, staleness, and freshness without starting or serving a composition
- a stale dossier offers authenticated writers an explicit regenerate action while continuing to serve the old results until the single background replacement finishes
- the dossier loader waits and reloads rather than polling, so a composition in flight is not destabilised by its own progress page
- a dossier composition that lost its input closure to concurrent server work is composed again within a bounded number of attempts
- completeness-waiver: empty inputs (a system must name at least one board and every required active document must exist, so an empty workspace is rejected with a diagnostic)
- completeness-waiver: large inputs (manifest, Markdown, image, collection, and ZIP-member limits reject oversized review inputs before unbounded work)
- completeness-waiver: unauthorized access (draft/readiness are read-only; attestation, document writes, uploads, and final release require the authenticated writer role)
- completeness-waiver: i/o failure (contained project reads, atomic VFS writes, PDF composition, and archive writers propagate failure and never publish a partial final package)
- completeness-waiver: concurrent access (document and attestation mutations share one lock; release locks and final revalidation reject inputs that move during composition)
- completeness-waiver: malformed encoding (strict typed JSON and UTF-8 Markdown parsing reject malformed manifests, controls, active markup, and unsafe paths)
- completeness-waiver: integer overflow (explicit byte/count ceilings and checked allocator/writer arithmetic bound all input-derived sizes)
- completeness-waiver: panic-free (invalid manifests, stale approvals, missing confirmation, unsafe paths, and release races return explicit errors without forced unwraps)

## req_checks

Public functions: runChecks, deinit, parseMicroFarads, parseOhms, parseMicroHenries

- parseMicroFarads handles SI-suffixed cap values
- parseOhms handles SI prefixes for resistor values
- pin-voltage walk treats supply-feed resistors as DC-equivalent up to 25 ohm
- parseMicroHenries handles SI-suffixed inductor values
- applyVerifications matches a verifies form to an instance by stable id when target-id is set
- applyVerifications matches a verifies form to an instance by ref-des when target-id is empty
- applyVerifications honors verification forms declared inside nested reusable modules
- pin connectivity checks accept physical pin ids as well as pinout function names
- runChecks frees a partial result on map allocation failure
- decoupling-per-pin requires distinct physical capacitors
- voltage-not-above compares the control worst-case maximum against the supply worst-case minimum plus margin

## net_analysis

- a top-level input power port creates decoupling demand
- a capacitor only qualifies when it bridges the supply to ground
- chassis ground counts as 0 V for rating but is not a ground token the pour may fill
- completeness-waiver: empty inputs (empty port, section, instance, and net slices produce no missing-rail result)
- completeness-waiver: large inputs (analysis is bounded by the immutable design slices and allocator failure is returned)
- completeness-waiver: unauthorized access (pure in-memory design analysis has no authorization or external access surface)
- completeness-waiver: i/o failure (the analysis performs no I/O; callers own project and library loading)
- completeness-waiver: concurrent access (the checker only reads an immutable design snapshot and uses request-local maps)
- completeness-waiver: malformed encoding (names are opaque UTF-8 byte slices; malformed source is rejected before evaluation)
- completeness-waiver: integer overflow (the checker only counts slice entries with usize and performs no integer arithmetic)
- completeness-waiver: panic-free (all analysis allocations return allocator errors and optional lookups are checked)

## req_physical_checks

Public functions: evalCapRating, evalMaxDistance, evalSequence, resolveDistanceRules

- cap-rating passes a capacitor rated above the derived envelope and fails one rated below it
- cap-rating reports an unrated capacitor and an underivable net envelope as unproven rather than passing either
- max-distance defers to the layout lint when a qualifying passive exists and fails at build time when the netlist has none
- resolving a max-distance rule records the measured pad and every qualifying passive on its net for the layout lint
- sequence passes a derived power-up order that satisfies it and fails one that reverses it
- sequence reports an undetermined power-up order as unproven and names what would prove it
- evaluating a design resolves its max-distance requirements onto the instances the placement layer reads
- parseVolts reads a rating attribute and rejects the foreign units that sit beside it
- completeness-waiver: empty inputs (an unresolved pin, an empty envelope table, or an empty sequencing model each produce a failed or unproven check result rather than indexing absent data)
- completeness-waiver: large inputs (the checks scan the already-allocated instance, net and envelope slices linearly and allocate only their diagnostic message and the resolved candidate list)
- completeness-waiver: unauthorized access (a pure design-analysis layer with no access surface; authorization is enforced before CLI dispatch)
- completeness-waiver: i/o failure (the primitives perform no I/O; pinout loading is owned by the evaluator and a miss becomes an unresolved-pin result)
- completeness-waiver: concurrent access (the checks read an immutable design snapshot plus request-local evaluator state; the one mutation, resolveDistanceRules, runs inside the single-threaded post-build pass)
- completeness-waiver: malformed encoding (typed design data comes from the S-expression parser, while an unreadable voltage or component-value spelling returns null and simply does not qualify)
- completeness-waiver: integer overflow (voltage, distance and value arithmetic is f64; the only integer is the sequencing order the analyzer already bounds at eight relaxation passes)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## req_derived_checks

- feedback-divider and SET-current checks reject the mismatched values used by straps
- rail-name fallback decodes common voltage conventions used by flat designs
- a second resistor on one feedback leg is reported instead of silently replacing it
- rail-name fallback decodes the imported underscore decimal and signed negative spellings
- resistor values are read through the canonical req_checks parser including the milliohm suffix
- completeness-waiver: empty inputs (missing pins, nets, or programming resistors produce a failed check result rather than indexing absent data)
- completeness-waiver: large inputs (the checks scan the already-allocated instance and net slices linearly and allocate only their diagnostic message)
- completeness-waiver: unauthorized access (a pure design-analysis layer with no access surface; authorization is enforced before CLI dispatch)
- completeness-waiver: i/o failure (pinout lookup failure is represented as an unresolved-pin check result; project loading is owned by the evaluator)
- completeness-waiver: concurrent access (checks read an immutable design snapshot and request-local evaluator state, with no shared mutable data)
- completeness-waiver: malformed encoding (typed design data comes from the S-expression parser, while malformed resistor and rail spellings return null)
- completeness-waiver: integer overflow (derived calculations use f64; integer work is limited to bounds-checked slice indices)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## preflight

- an append allocation failure releases the already-owned finding message
- authoring warns for pending requirements while strict preflight fails them
- the release profile fails profile gaps and unknown sub-forms that preflight only warns about
- complete reviews require every category or a reasoned N/A
- digest identity uses canonical lowercase SHA-256 text
- replacing a reviewed PDF makes a completed digest-bound review stale
- completeness-waiver: empty inputs (a design with no instances produces an empty report, while missing review fields become explicit findings)
- completeness-waiver: large inputs (recursive traversal is proportional to the allocated design tree and propagates allocator failure)
- completeness-waiver: unauthorized access (preflight only validates an already-loaded design; CLI and CLI authorization live at their entry points)
- completeness-waiver: i/o failure (an unreadable reviewed PDF becomes an incomplete-review finding instead of aborting validation)
- completeness-waiver: concurrent access (each run owns its result map and findings while reading an immutable design snapshot)
- completeness-waiver: malformed encoding (library parsing is upstream; malformed review metadata is rejected through structured incomplete findings)
- completeness-waiver: integer overflow (finding counts are bounded by allocator-backed slices and use no input-derived integer arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## review_html

Public functions: writeSummaryTable, writePowerBudget, writePowerSequence, writeTestPoints, writeUnresolved, writeAssertions, writeSectionCoverage

Thermal rendering moved out of this module: its panel needed the cooling-scenario
ladder, the ladder needs the saved layouts, and the schematic page these fragments
embed reads nothing but the design's own `.sexp`. Thermal is served by
`serve/thermal_page.zig` at `/thermal/:name` and by `serve/thermal_api.zig` at
`/api/thermal/:name`, both of which opt into the layout read deliberately.

## tool_cli

Public functions: run

- A structured tool invocation accepts one JSON source and the common project and output flags
- completeness-waiver: empty inputs (a missing tool name or flag value exits with a usage diagnostic)
- completeness-waiver: large inputs (argument files are capped at 16 MiB and tool handlers retain their own bounds)
- completeness-waiver: unauthorized access (the CLI runs with the invoking user's filesystem authority)
- completeness-waiver: i/o failure (input and output failures are reported through the CLI error path)
- completeness-waiver: concurrent access (each process owns its parser and output buffers; optional git commits retain the existing index mutex)
- completeness-waiver: malformed encoding (arguments must parse as a JSON object and image base64 must decode before it is written)
- completeness-waiver: integer overflow (argument sizing and base64 sizing use checked standard-library operations)
- completeness-waiver: panic-free (invalid CLI input exits with a diagnostic; fallible allocation and I/O propagate)

## serve

Public functions: notFound, serve

- Ward member maps to the writer role, admin to admin, and an unknown role to reader
- A configured browsable url is reported to ward while an unset one omits the header
- An unconfigured ward adapter reports session and bearer paths unconfigured so requests fail closed
- The service scope check accepts a scope containing the service name and rejects one without it
- The ward auth-server url is derived by stripping the login path from the configured login url
- The auth-server url prefers explicit config over the login-path strip
- A cookieless session request is decided as a redirect to the ward login url carrying the return target
- An api path is distinguished from a non-api path for the 401-versus-redirect choice
- The ward session cookie value is read from the cookie header and absent when empty or missing
- A cached session role is read back by token and reported unknown when absent or expired
- Admin and writer may write while reader may not, and roles stringify lowercase
- An unavailable session verifier resolves the request to fail closed rather than admit it
- A loopback request under dev mode bypasses auth even when the ward backend is unconfigured
- A loopback request carrying any proxy header does not receive the dev bypass
- A request from a non-loopback peer does not receive the dev bypass
- A loopback request with dev mode disabled does not receive the dev bypass
- An ipv6 loopback peer receives the dev bypass while a non-loopback ipv6 peer does not
- An unauthenticated api request is answered 401 json rather than a login redirect
- An unauthenticated page request is redirected 302 to the ward login carrying the return url
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
- The sync bearer grant requires both a service scope and a writer-capable role
- A ward reader's netlisp-scoped bearer does not admit the destructive sync write while a member's and an admin's do
- Every read-only post prefix exempts only its own route family while safe methods are never write-gated
- Every public route entry is served without a session while a sibling sharing its leading text is not
- The system dossier page is session-gated and refuses like its sibling system page rather than as a JSON api

## serve/sync

Public functions: runSyncPlan, syncKicadPcbApi

- runSyncPlan diffs a parsed board state against the design and returns a JSON envelope with version, summary, and the ops list
- seeded copper spells its KiCad layer with the shared layer-table names
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
- buildNetlispNetValue renders each passive pad as destRef.destPin.net for a single hub pin, else the bare net name
- buildNetlispNetValue lists a passive's pads in numeric order joined by ' / ' and returns null when the passive has no connected pads
- sectionForRef attributes a sub-block part to its sub-block name and a top-level part to its declared section, else ""
- stripSubPrefix removes a leading "<sub>/" so a flattened sub-block ref maps to its module layout's ref
- boxCols returns a roughly-square (ceil-sqrt) column count for a staging box of N parts
- buildStagingLayout gives each part a fixed staging seat from the whole design, independent of push composition
- maybeCollapseDotSubNet folds a per-pin sub-net to its rail by default but keeps it verbatim in dot-net mode
- no-swap mode withholds swap_footprint as swaps_suppressed while set_field ops still flow
- a stale board pad is cleared only when the design nets that signal on another pad the board footprint actually has
- formatBackupStamp renders epoch seconds as a sortable filesystem-safe stamp
- writeFileAtomic rolls a timestamped board backup and prunes beyond MAX_BOARD_BACKUPS
- placement guard reports moved, rotated, or side-flipped footprints and exempts adds/removes
- placement guard passes when every existing footprint keeps its pose
- computeGroupAnchors matches a group's anchor to the board through the same relink tiers the differ uses
- placeOneSelected keys an on-board anchor by origin_key to centre its module's seeded passives
- seeded sub-circuit copper lands on the board with bridged nets and the group offset
- seeded sub-circuit copper adopts the destination net-class track and via geometry
- buildSubCircuitsJson reports each seedable group's module track and via counts
- kicadRotToNetlisp inverts netlispRotToKicad for top and bottom parts
- groupTransform is a pure translation for a same-side unrotated anchor
- placeOneSelected flips a seeded sub-circuit to a bottom-side anchor
- placeOneSelected rotates a seeded sub-circuit to match a 180-degree anchor
- emitSeedCopper mirrors flipped sub-circuit copper and swaps its outer layer
- a flipped seed keeps coincident pads coincident on the board
- buildNetDisplayMap strips a hierarchy prefix only when the bare leaf is globally unique
- a fresh board whose design layout names every add skips per-sub-block module seeding
- no_seed_blocks forces the whole-design layout to be the only placement authority
- a whole-design seed writes the saved layout's own routed tracks and vias onto the board
- saved copper on a net the design no longer has is skipped rather than renamed
- no_layout_tracks withholds the saved tracks while the saved vias still flow
- saved copper is withheld unless the seed reproduced the whole layout on a fresh board
- a staged part keeps the rotation and side the design layout gives it
- an authoritative layout emits one full replacement batch using only live design nets
- an authoritative layout without declared stackup planes retains its saved zone count in the sync summary
- authoritative placement converts netlisp rotation/side into a targeted KiCad pose op
- authoritative stale pruning also removes pre-netlisp manual KiCad footprints
- an authoritative push counts and names the saved copper it could not emit, so emitted plus dropped accounts for every saved track and via

## route-cleanup-gate

- a cleanup candidate is refused when it grows the error count, opens a routed net, or grows the bypass_open count, and accepted when nothing regresses
- a refused candidate is attributed to exact nets, by the tally names that are newly open and the nets whose bypass_open count grew
- completeness-waiver: concurrent access (pure functions over caller-owned slices; no shared state and no I/O — the serve layer owns sessions and persistence)
- completeness-waiver: empty inputs (an empty violation list and unchanged tallies gate green, attribute nothing, and delete nothing; the paired tests exercise the empty lists directly)
- completeness-waiver: i/o failure (the module performs no I/O; candidates and verdicts are in-memory slices handed in by the caller)
- completeness-waiver: integer overflow (counts are usize tallies over allocator-bounded slices; net indices are bounds-checked before every cast)
- completeness-waiver: large inputs (linear scans over the board's own violation and net lists; nothing is quadratic beyond open-net name matching, which is bounded by the board's net count)
- completeness-waiver: malformed encoding (no bytes are decoded; inputs are already-typed violations, tallies, and net tables)
- completeness-waiver: panic-free (every `net_a`/index cast is guarded by a sign and bounds check first; out-of-range parties are skipped, not indexed)
- completeness-waiver: unauthorized access (authorization is the MCP layer's concern; this module never touches files, sessions, or the network)

## serve/route-plan

Public functions: lower, lowerOrEmpty, lowerWithWaves, routeLoweredCandidate, finishLoweredCandidate, routeLoweredDiagnosticCandidate, finishLoweredDiagnosticCandidate, routeLoweredDiagnostic, pruneTopologyArtifacts, includeDiffPartners

The one `(pcb-plan (route …))` lowering seam shared by every routing surface —
the `route_pcb` CLI commit path, `POST /api/pcb-route`, the `/pcb-layout`
page's `?route=1` preview, the PNG endpoint, and `/api/pcb-describe` — so a
fresh preview route always equals what a commit would produce (wave priority
order, preferred/allowed layer masks, waypoints, via budgets).

- a design with no authored plan lowers to empty options
- lowering turns authored route waves into per-net wave priority and layer masks
- a preview route through the shared seam honors the authored allowed-layers restriction
- resolveScope selects a criticality class group over the analyzed context
- a scoped route preserves an unselected net's existing copper and reroutes only the selected net
- selecting either differential-pair member for an incremental route automatically includes its partner
- a diagnostic route preserves user copper zones as same-net source copper
- a lowering failure degrades a read-only surface to plan-less routing
- an override plan routes through the experiment seam and surfaces its unknown-target warnings
- an experiment run honors the caller's effort override and routes from the layout's retained pours
- lowering with waves returns the resolved route waves beside the per-net options they produced
- a caller's own lowered options route through the diagnostic seam and come back gated by the connectivity oracle
- a scoped transaction's gate plans its target's own long join at the unattended hop ceiling while a broad one-shot gate keeps the short one
- a scoped gate's hop ceiling reaches its own target's join and no further, while a broad gate of either effort keeps exactly the ceiling it was tuned on
- the standard-effort gate attempts bounded additive joins on router-failed nets before deciding whether the residual rescue ladder is needed
- standard effort gives its non-ripping connectivity gate a larger deterministic distance and hop budget than interactive one-shot routing
- a timed standard lattice route starts with one whole-board one-shot pass and spends the shared remainder only on additive oracle-open-net retries
- the wide unblock slice affords a cross-board scoped re-route, so a time verdict means the maze was tried, not truncated
- residual-phase diagnostics print at info level, so a ReleaseSafe binary's wide and pair tiers stay observable
- a timed gate call bounds its reconcile with a pass slice that stops new hops without cancelling the board; an untimed run stays unsliced
- a gate pass stopped by the ladder's reserve boundary keeps the hops it already landed and ends the ladder, rather than discarding the pass
- both residual head phases run against a deadline pulled in by the tail the per-target unblock pass needs, sized from that pass's own entry census, bounded by a share of what the residual has left, and zero on a clock-free board
- the residual tail is priced from the census the phase is entered with, one breadth probe per distinct open net plus room for the deep ladders funded behind them, and a census with no target, no open net or no wall clock left prices no tail at all
- a demand-priced residual tail never falls below the single-corridor price it replaced, so no board reserves less of its residual than it did before the tail was priced against a plan
- a residual tail claims no more than its declared share of what the residual has left, so the gate ladder and the guided retries keep a working share of even a budget the tail's own demand outgrows
- the topology prune judges a round's damage as soon as it lands, since pruning only removes copper
- the board is topology-pruned exactly once, after the residual ladder has converged, so cleanup never rewrites the copper a functional pass is still planning against
- a prune that leaves a net carrying more requirement damage than it arrived with hands that net's copper back, and rejects the whole plan when the damage outlives the salvage budget
- a prune round that opens a net hands that net's copper back untouched and freezes it for the remaining rounds, keeping every removal the fabrication oracle agreed with
- a prune whose damage cannot be attributed net by net still rejects the whole plan, so the connectivity guarantee never weakens
- a guided corridor retry's gate is judged against the board's clock, not the per-net route slice that has already expired
- a timed guided corridor retry skips the targets this route's gate has already sealed and reports what that yields the unblock tail, while a target the route has not answered keeps its slice and a clock-free run skips nothing
- a target whose narrow unblock transaction was refused is retried with wider rip authority when the board has spare wall time per remaining target, while a clock-free run keeps exactly one narrow attempt
- a narrow unblock refusal the board answered on geometry skips the wide retry unless the wider nomination reaches a negotiable-class blocker the narrow rip did not hold, while a refusal about time, authority or scope is retried wider as before
- a ripped net a scoped restore left open is re-homed by the gridless shape channel alone before the transaction is declared lost, additively and re-tallied by the oracle, while a whole-net target that stayed open is never offered to it
- a lost differential-pair victim is re-homed by a scoped coupled re-route of both its legs over the candidate's frozen copper, kept only when the oracle joins both, while a leg whose pair the board no longer declares is named and left alone
- a lost differential-pair victim's coupled re-home asks the mesh-augmented search first and the lattice alone behind it, keeping whichever board the oracle joins both legs on, because a mesh construction stands in front of the pair's own legacy fallback
- one refused transaction's own lost victim earns exactly one alternate nomination whichever tier formed it, holding that net and any declared twin out of the sweep, while an accepted or victimless outcome earns none
- a scoped transaction's gate reconciles in a window out of the clock the pass still holds rather than the slice its own re-route has already spent, and a clock-free board keeps exactly the deadline it had
- a scoped transaction whose gate overran that slice is judged on the board the gate produced instead of reported as no candidate, while the board's own deadline and cancel flag stay the authority and a re-route cut off before it drew a board is still a dead end
- an unblock transaction the board refused only because a net it ripped could not be put back is retried once with exactly that net held out of the nomination, on a board with measured spare wall time, while every other refusal and every clock-free run keeps today's single attempt
- an unblock transaction the board refused with its target still open extends its rip with the blockers the board it produced still shows in the way, for a bounded number of rounds, never past the additive close's reserve or a floor slice still owed to a target behind it, while a clock-free run keeps today's single attempt
- a deepened unblock rip adds only the blockers it does not already hold, and a sweep that adds none ends the ladder rather than re-ripping the same copper
- a deepening round negotiates a blocker its tier held out on authored rank alone, lifting it corridor-only under the same restore discipline, and the switch is off again for every transaction outside the round
- a per-gap unblock transaction keeps its target net's own copper, draws one island join in the channel its rip freed, and is accepted only on a credited island merge
- a pour-carried net may be a per-gap unblock target though never a whole-net one, and a plane- or pour-carried ground net may be one too, while unbacked ground, diff-pair, RF and fenced nets are excluded from both
- affordability decides only how many per-gap targets the tail can pay for, priced at the floor slice every admitted target is owed its first question in rather than at the wide retry it may never run, and the cheapest-first order decides which; a clock-free board admits none
- a scoped transaction's gate stops at reconciliation when a net the transaction named is still open, before the canonicalization and DRC ratchet its rolled-back candidate would never keep
- a per-gap unblock transaction that was accepted re-enters at once for its net's next island gap, read off the board it just left, and the ladder ends when the oracle reports that net no gap at all
- a net that has earned an unblock accept this phase retires a refused hop and continues its ladder at the next-smallest, each hop offered at most once per phase, while a net that has proved nothing is still abandoned on its first refusal
- the remaining route budget is divided among the unblock LADDERS still live, so a planned target whose net an earlier refusal abandoned stops taking a share, and one net's several planned slots take a single share between them
- an unblock ladder takes another rung only while the remainder still covers a floor slice for every net behind it that has not yet had its first attempt, so re-entry can never spend a planned target's only turn
- every repeated tail gate pass is full-gated, so copper a pass closes is never victim-dropped wholesale at a phase boundary
- deferred repair selection uses only authored repair-waypoints, never ordinary waypoints, reference branches, or scoped/retained copper
- the bounded broad seed phase excludes repair-only waypoint corridors
- repair-only waypoints do not replace ordinary broad-pass waypoints
- a fresh route drops DRC-implicated mutable copper and reports the affected net open instead of returning a fab error
- the gate's DRC ratchet judges copper against the same fabricated fill its topology prune does, so a trace that ends on its own net's pour is never dropped as a stub
- a dropped gate victim names the rule that chose it and the other party to it, and says so plainly when no finding names it at all
- the victim re-home runs in a window out of the clock the pass still holds rather than the transaction slice its own scoped re-route has already spent, and a clock-free board keeps exactly the deadline it had
- the alternate nomination after a lost victim is priced at the narrow tier it actually runs rather than at the wide tier's spare-time gate, while a clock-free run still declines it
- a timed route never returns a board less connected than one it already held, and a phase that comes back worse is checkpointed back to the best board while its cancellation is still reported
- the field route retries oracle-open nets against frozen completed copper and removes generated fragments that remain open
- a field residual cluster is capped at three open seeds and formed deterministically from shared blocker nominations
- static escape contention can cluster open seeds without emitting guides or reservations
- a field residual cluster never trades a previously complete net for one of its old airwires
- rerouting a residual net replaces its shape and search diagnostics while retaining untouched nets' metadata
- a field residual cluster accepts only candidates which preserve every frozen track and via instance exactly
- a field residual cluster declines caller-retained vias because the router-neutral copper surface cannot carry saved RF-fence provenance
- the per-target unblock pass attempts only the oracle-open two-terminal nets its scope may reroute, cheapest island gap first
- a per-target unblock transaction that cannot close its target leaves the baseline board byte-for-byte
- an unblock transaction nominates a declared differential pair only under the wide tier, rips both of its legs together, and rolls the whole board back byte-for-byte when the target still will not close
- a transaction that re-laid a declared pair is refused when the pair comes back with a leg missing, a wider coupling gap or more skew than the coupled constructor equalizes to
- a plane-carried unblock blocker is lifted only where it crosses the target's corridor, its copper elsewhere stays byte-for-byte, and only a tier that declares the lift lifts at all
- only a pour-carried nomination under a lifting tier is ripped corridor-only; every other pick and every non-lifting tier is ripped whole
- an unblock corridor charge is measured against the target's own corridor lines, so every candidate one sweep prices is measured against the same corridor and a target with no hop is charged nothing
- a formed unblock transaction traces the copper it rips and the granularity it rips at, why a built candidate was rolled back, and every candidate it declined and why, and no trace can be taken down by an out-of-range net index
- a transaction that produces no candidate board names which cause it hit, and never reports a corridor with no legal path as an expired slice
- a corridor-lifted net's surviving copper is exempt from the frozen-copper echo, because the same transaction put that net in the router's scope; every other net's frozen copper must still come back byte-for-byte
- the per-target unblock phase ends with one additive connectivity close, kept only when the oracle's open set strictly shrinks
- on a timed board with several unblock targets the phase gives every target one narrow slice-bounded transaction before any target is given a ladder, and a board with no deadline or a single target keeps the single-round pass exactly
- a breadth probe's slice cap is the phase remainder split between its own targets and the depth round behind it, floored at the tier's own minimum and never raised above the narrow tier's measured cap
- a timed breadth probe negotiates a pour-carried blocker's corridor lift and nothing else, so its restore is sized by the copper in the corridor rather than by the whole net, while the depth ladder behind it keeps the whole-net rip
- the depth round funds its ladders in the order the breadth verdicts earned, and a target the board sealed on geometry with no class a deeper tier may negotiate sorts last
- a breadth refusal that rolled back a re-routed board outranks one that produced no board at all, because a deepening round is the tier that can act on it
- two rolled-back refusals are funded cheapest-rip first, and the rip count never reorders any other verdict
- round 2 funds only the deep ladders the phase remainder can pay for at one wide retry apiece, floors that at a single ladder while any remainder is left, and funds every net on a board with no clock
- the funded round-2 plan carries every target of a funded net, releases the targets it cannot fund outright, and names the funded nets in its timeline line
- round 2 deals its funded ladders' rungs round-robin in promise order, so a target that has already spent a ladder this pass takes its next rung only behind every funded target that has spent none
- a timed ladder deepens past its two free rounds only while the remainder still covers its own measured round price after a whole funded ladder is held for every ladder behind it, stops at a hard round cap, and keeps the two-round bound exactly on a board with no clock
- a breadth transaction runs no deepening round and prices a coupled victim re-home as the ordinary hop it shares a window with, so one target cannot spend another's turn
- a pair channel's pinch owners join the deepening round's nomination sweep and nowhere else, are judged by the same vacate policy as swept copper, and a wall owned by a keepout or the board edge is reported and never nominated
- the public topology cleanup seam removes deletion-invariant trace sections and connectivity-redundant non-ground vias with the same connectivity gate as a normal route
- generated physical trace contacts are canonicalized before the route gate can count or persist them
- the route gate's closing gloss fuses the collinear halves a junction split leaves behind while keeping the split that names a real junction
- a topology-flagged route wave lowers into planner corridor guides for its nets
- the same plan without the topology flag lowers to exactly the guides it had before
- a net whose wave authored waypoints keeps them and receives no planner guide
- only a topology-flagged wave's nets receive planner guides when a plan mixes flagged and unflagged waves
- a route_experiment topology override plans a topology for every route wave of that run alone
- The retained-copper bundle handed to the connectivity oracle carries the board's poured zones, so a net joined only through a pour is not reported open
- completeness-waiver: large inputs (linear over the placement's nets and the plan's waves; a bigger board only lengthens the policy slice)
- completeness-waiver: unauthorized access (a pure in-memory lowering; endpoint access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk or socket — inputs are the already-evaluated block and solved placement)
- completeness-waiver: concurrent access (a stateless pure function over immutable inputs into per-call arena-owned slices)
- completeness-waiver: malformed encoding (inputs are typed Zig structs from the evaluator; unknown selector names become plan warnings upstream)
- completeness-waiver: integer overflow (layer indices are bounded to the 64-bit mask by plan_resolve; counts are slice lengths)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## serve/route-result-stats

Public functions: writeDrc

Routing mutation responses keep the compatibility total violation count while
also separating fabrication errors, advisory warnings, differential-pair
warnings, topology artifacts, and elapsed wall time.

- a route response separates DRC errors, warnings, differential warnings and topology artifacts
- completeness-waiver: empty inputs (an empty finding slice reports zero in every category)
- completeness-waiver: large inputs (one linear pass over the checker-owned finding slice)
- completeness-waiver: unauthorized access (pure response formatting over already-authorized route results)
- completeness-waiver: i/o failure (writer errors propagate to the caller)
- completeness-waiver: concurrent access (no shared state; all counters are call-local)
- completeness-waiver: malformed encoding (typed violations and integer elapsed time arrive after parsing)
- completeness-waiver: integer overflow (counts are bounded by the finding slice length and elapsed time is only echoed)
- completeness-waiver: panic-free (no indexing or unchecked casts)

## serve/route-analyze

Public functions: pcbRouteAnalyzeApi, analyzeNetJson, mcpDiagnoseNet, writeAnalysis, AnalyzeOpts, AnalyzeError

`POST /api/pcb-route-analyze/:name` — on-demand diagnosis of ONE named net on
the surviving router surface (the read-only twin of the retired Route Lab
`analyze`). It runs the SAME plan-lowered diagnostic route the /pcb-layout
Route button runs (`route_plan.routePlannedDiagnostic`, request-local, persists
no copper), then answers for the caller's net: a failed net returns its full
stuck diagnosis tagged `"status":"failed"` through the shared `stuck_json`
serialization; a routed net returns `"status":"routed"` with its trace length,
via count, and signal layers filtered from the RouteResult; an unmatched name
is a 404. Net names resolve through the shared exact-or-leaf case-insensitive
`(nets …)` lookup (`plan_resolve.netIndexByName`). Read-only POST — access
control lives in serve/ward_auth (listed in read_only_posts).

The same analysis is the read-only `diagnose_net` CLI tool (args `name`, `net`,
optional `layout` / `sub`), so an agent can interrogate one net without routing
the whole board to read a capped, failure-only `stuck[]`. Both surfaces run
through one `analyzeNetJson` body — resolve the shown board, route it, answer —
so the tool and the endpoint can never diagnose different boards for the same
request.

- a failed net is answered with its stuck diagnosis tagged status failed
- a routed net is answered with status routed and its trace length via count and layers
- an unknown net name yields no answer so the endpoint replies not found
- a failed net past the diagnostic cap still answers status failed
- diagnose_net is a registered read-only CLI tool
- diagnose_net names the argument a caller left out instead of diagnosing nothing
- an unresolvable design reaches diagnose_net's caller as an error line, never as a partial answer
- the analyze failure mapping keeps the shared PCB read status codes and adds this module's own two
- completeness-waiver: empty inputs (a missing or empty "net" field is rejected 400 by parseNet before any routing, and a net matching nothing answers 404)
- completeness-waiver: large inputs (answering is a linear scan of the one bounded diagnostic route's tracks, vias, and failed set — a bigger board only lengthens those slices)
- completeness-waiver: unauthorized access (a read-only POST whose access control lives in serve/ward_auth's read_only_posts, not restated here)
- completeness-waiver: i/o failure (project reads flow through solveForRequest, whose PngError maps to a 404/500 JSON error; the handler does no direct disk I/O)
- completeness-waiver: concurrent access (each request routes into its own per-call arena and persists nothing, so there is no shared mutable state)
- completeness-waiver: malformed encoding (a non-object body or non-string/absent "net" field is rejected 400 before any routing runs)
- completeness-waiver: integer overflow (net indices are slice positions and layer indices are bounded by signalLayerCount; trace length is f64 accumulation)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## serve/urlcodec

Public functions: decodeAlloc

The one percent-decoder for HTTP path parameters. httpz hands `:param` values
over verbatim, so every handler that turns one into a filesystem or design
lookup decodes it first — and six handlers grew their own byte-identical
private copy doing exactly that. This module is the canonical home guardian's
`percent-decode-wrapper` idiom rule names; new handlers call it rather than
adding a seventh copy, and the existing copies fold in as they are touched. The
decode runs over a private copy, so the result is always the caller's to keep
and never a view into httpz's request buffer — and its length matches its
allocation, which the private copies get wrong: `percentDecodeInPlace` returns
a shorter view of the buffer it decoded into, and freeing that view is an
invalid free that only their request arenas hide.

- a decoded path parameter is a fresh copy the caller owns and can free, leaving an invalid escape as written
- completeness-waiver: empty inputs (an empty parameter decodes to an empty slice; the bullet above covers the escape-shaped edges)
- completeness-waiver: large inputs (one allocation plus a single in-place pass, both linear in a path parameter httpz has already bounded)
- completeness-waiver: unauthorized access (a pure string transform reachable only from handlers whose access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (touches no file, socket or process; its only failure is allocation)
- completeness-waiver: concurrent access (allocates and mutates only the caller's own copy, so two callers share nothing)
- completeness-waiver: malformed encoding (an invalid or truncated escape is left as written rather than rejected, which is the bullet above)
- completeness-waiver: integer overflow (no arithmetic of its own; the decode is std.Uri's byte walk)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## serve/thermal_cache

Public functions: Key, Store, publish, active

The solved thermal field, kept between requests. A cooling-scenario ladder costs
a placement resolve (which re-parses a potentially multi-megabyte `.layouts.json`
sidecar) plus four relaxed steady-state spreader fields — seconds on a real
board, and it was paid again on every thermal page load, every heat-zone image,
every review render and every ambient nudge for a board that had not changed a
byte between them.

What is retained is the solver's own `[]ScenarioResult`, whose temperatures are
RISES above ambient. That is what lets one cached solve answer every ambient:
`thermal_scenarios.ladderAt` is the only place an ambient is ever added, so
re-screening at 70 °C is arithmetic over a retained field rather than four fresh
relaxations.

Validity is `serve/pcb_page_cache.zig`'s, because the inputs are the same ones —
the evaluator's read-set (design, checks, every transitively imported `lib/`
file) plus the `.layouts.json` / `.autolayout.json` sidecars the placement is
resolved from, mtime-stamped through `page_cache.FileSet`, and the design's
live-edit version on top. Entries are keyed by project directory AND design
name, so two projects in one process cannot read each other's board — and by
the SAVED LAYOUT the field was solved over, because two layouts of one design
are two different boards for heat: the same parts, placed differently, over
different pours and via stitching. The empty layout is the design's default
board, and a request naming the starred layout is folded to it upstream, so the
default board keeps one entry however a link spells it.

Entries are pinned to the process allocator because the HTTP server frees its
per-request arena after every response, and a hit is COPIED back into the
caller's arena under the store's own lock — an entry can be evicted by another
thread the instant the lock drops, and a borrowed field would then be a
use-after-free.

- a cached field is returned only while the design, its checks, its imported library files, its layout sidecars and its live-edit version are all unchanged, and a stale entry is dropped on the lookup that finds it
- a hit is a deep copy the caller owns, so it survives both the request arena it was solved in and the entry's eviction
- entries are keyed by project directory as well as design name, so the same design name in two projects never crosses over
- entries are keyed by the saved layout the field was solved over, so two layouts of one design keep separate fields
- the store is bounded by entry count and by retained bytes, evicting least-recently-used first, and refuses outright to retain a single field larger than the whole budget
- a store with no allocator misses every lookup and retains nothing, which is what an offline CLI run and a handler test both want
- the published store is what every cache-aware surface reads, and nothing is published when no server is running
- every lookup, insert and eviction is serialised on the store's own lock, so concurrent request threads sharing one store can read and retain simultaneously without tearing an entry or handing back a field another thread is evicting
- completeness-waiver: empty inputs (an empty ladder is retained and returned as an empty slice; a never-seen design is the miss the first bullet covers)
- completeness-waiver: large inputs (a field over-running the byte budget is refused rather than retained, and the trim above bounds everything else; the grid itself is capped by placement/thermal_field)
- completeness-waiver: unauthorized access (an in-process cache behind handlers whose access control lives in serve/ward_auth; the project-dir key is what keeps two projects apart)
- completeness-waiver: i/o failure (the only I/O is the mtime stat page_cache performs, whose failure invalidates the entry rather than propagating)
- completeness-waiver: malformed encoding (keys are opaque byte slices joined by a NUL that cannot occur in either half, compared for equality and never decoded)
- completeness-waiver: integer overflow (the byte tally is a usize sum bounded by the budget above and the use clock wraps deliberately; every cached quantity is an f32 or f64 degree)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## serve/thermal

Public functions: thermalApi, thermalJson, scenariosFor, mcpDescribeThermal, HandlerError, ThermalError

`GET /api/thermal/:name` — the lumped steady-state thermal screening
(`eval/thermal.zig`) as read-only facts JSON: `ambient_c`, the board `verdict`,
the `limiting_ref` it hangs on, the `max_ambient` / `min_ambient` window with
the part setting each end, the coverage `counts`, and a `parts[]` row per part
carrying its power, theta, limits and computed result. Unknown figures are
`null` rather than 0, the estimated / defaulted flags are booleans, and both
enums travel as their tag names. `:name` is percent-decoded and resolves as a
design or as a bare `lib/modules` module instantiated standalone through its
parameter defaults — the same resolution every other read surface uses.
`?ambient=NN` screens at the caller's ambient instead of bench 25 °C; a value
that is not a number is answered 400 rather than silently ignored, because
ignoring it would report temperatures for an ambient nobody asked for.

`?layout=<name>` spreads the heat over one NAMED saved layout instead of the
design's default board — the comparison the thermal page is built on, since two
saved layouts are two different boards for heat and only their temperatures say
which placement is worth keeping. A name nobody saved is answered with the
sentence saying so rather than the default board's numbers under that name, and
naming the starred layout is folded to the default board so both spellings share
one solve. `/api/thermal-field/:name` takes the same argument, because the
picture the board overlay paints and the numbers beside it must be of one board.

The same analysis is the read-only `describe_thermal` CLI tool (args `name`,
optional numeric `ambient`, optional `layout`). Both surfaces run through one `thermalJson` body —
resolve, screen, serialize — so the tool and the endpoint can never report
different junction temperatures for the same design and ambient. Read-only:
nothing here writes to the project dir.

- GET /api/thermal/:name screens a design and answers the analysis as facts JSON
- GET /api/thermal/:name resolves a bare lib/modules module standalone through its parameter defaults
- GET /api/thermal/:name?ambient=NN screens at the caller's ambient and rejects one that is not a number
- GET /api/thermal/:name carries the layout-aware cooling ladder as four baseline rungs of absolute degrees at the requested ambient, each naming its hotspot, its ambient ceiling and any part it could not place
- a board-authored fan adds an auditable fan-only row with its model, face, installed flow, velocity and pressure estimate
- a board with an explicit fan and heatsink adds a simultaneous row carrying both assemblies after their standalone rows
- the cooling ladder is read at the caller's ambient, so every temperature on it shifts one for one with ?ambient while each ambient ceiling stays put
- a design with nothing to dissipate answers with a null ladder beside a sentence naming what is missing, and keeps every lumped field
- GET /api/thermal/:name answers an unknown design or module name with a 404 whose body is not JSON
- describe_thermal is a registered read-only CLI tool answering with the endpoint's own bytes
- describe_thermal names the argument a caller left out or mis-typed instead of screening a default
- a solved cooling ladder is retained between requests and re-solved only once the design, its libraries, its layout sidecars or its live-edit version change
- a cached solve is reused across ambients, so changing ?ambient re-screens without relaxing a single field again
- a caller that has already resolved a placement shares the same cached solve rather than resolving the board a second time
- GET /api/thermal/:name?layout=<name> screens that saved layout's own board, so two layouts of one design answer with different temperatures
- a ?layout nobody saved is answered with the sentence saying so instead of the default board's temperatures
- describe_thermal takes the same optional layout argument and shares the endpoint's bytes for it
- GET /api/thermal-field/:name?layout=<name> paints the named layout's own field
- a heat-zone image of a named saved layout shares that layout's cached solve, and any other placement override solves its own field
- GET /api/thermal-field/:name answers one scenario's rise grid, its hotspot and its per-part rows as the JSON the board overlay paints from
- GET /api/thermal-field/:name says why it has no field instead of answering an empty grid, and rejects a non-numeric ?ambient
- completeness-waiver: empty inputs (a missing :name and a name matching nothing are both answered 404 by the bullets above; a design with no thermal data screens to insufficient_data, which eval/thermal covers)
- completeness-waiver: large inputs (answering is one linear pass over an already-evaluated block; a bigger design only lengthens the rows it formats)
- completeness-waiver: unauthorized access (a read-only GET whose access control lives in serve/ward_auth, not restated here)
- completeness-waiver: i/o failure (every project read flows through evalNamedBlock, whose FileNotFound / NotADesign / InvalidName map to a 404 and whose remaining failures map to a logged 500; the handler does no direct disk I/O)
- completeness-waiver: concurrent access (each request evaluates into its own arena and persists nothing, so there is no shared mutable state)
- completeness-waiver: malformed encoding (the path param is percent-decoded before any lookup and a non-numeric ?ambient is rejected 400; every emitted string is escaped through the shared json_writer helpers)
- completeness-waiver: integer overflow (the counts are usize tallies of an existing slice; every measured quantity is an f64 watt, degree or degree-per-watt)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## serve/thermal-page

Public functions: thermalPage, HandlerError

`GET /thermal/:name` — the Thermal tab: one server-rendered page carrying the
board-coupled verdict headline (with the package-level screen demoted below it
and the ambient window under that), a cooling-scenario picker, the four-rung
cooling ladder, a per-part junction table for the selected scenario sorted
hottest first, and a coverage footer naming what the screen saw, what it could
not place and what the model deliberately does not include — all of it in a
panel beside the board itself, which is the read-only PCB viewer embedded the
way the assembly page embeds it, with the thermal overlay painting the solved
field over the real copper. Every sentence, pill and cell is built
by `review_thermal.zig` — the same builders the review panel, the markdown
report and the review PDF render from — so the page cannot state a verdict the
document does not. `:name` is percent-decoded and resolves as a design or as a
bare `lib/modules` module, the same resolution `GET /api/thermal/:name` uses;
an unknown name is a 404 with a plain-text body.

The Thermal tab sits last in the shared design-view bar, immediately after
Assembly, on the schematic, PCB, 3D and assembly pages and active on this one.
Modules keep the bar's existing scoping — no Assembly tab — but do get Thermal,
because the screening resolves a module standalone.

`?ambient=NN` screens the whole page at that ambient, clamped to the control's
own range rather than refused (the control is a spinner a reader can hold
down); `?scenario=<tag>` opens on that rung, falling back to still air for a
word nothing recognises. `?fragment=1` answers the two ambient-dependent
regions alone — the response the page's own client swaps in, because the facts
JSON carries numbers and not prose and re-deriving the verdict sentence in the
browser is exactly the disagreement this page is built to prevent. Switching
cooling scenario needs no round trip: every available scenario's per-part table is rendered into
the document and the client reveals one.

Saved fan and heatsink assemblies can be independently included in or excluded
from the active simulation without mutating their layout definitions. The two
controls select still air, fan only, heatsink only, or the simultaneous
fan-plus-heatsink scenario from the already-rendered ladder, so comparing their
effects is instantaneous and neither assembly has to be deleted and recreated.
They also hide or show the matching assembly in the embedded 3D setup.
Inside the embedded thermal 3D view, its Fan and Heatsink visibility controls
select those same simulation scenarios as well as hiding or showing the models;
the controls remain visibility-only in the standalone PCB 3D viewer.

`?scale_min=NN&scale_max=NN` selects the heat-map colour range only. The two
legend endpoints are editable number controls, default to 25–125 °C, require a
finite maximum above the minimum, recolour the cached field without a solve,
and remain in the URL so a reload or shared link reproduces the same picture.

`?layout=<name>` screens one saved layout of the design instead of its default
board, and the choice rides into the board frame, the tab bar, the cross-probe
links and the facts link, so nothing on the page describes a board other than
the one it names; a `?layout` nobody saved falls back to the default board and
SAYS so, because screening one board under another's name is the one answer this
page must never give. Beneath the tables, a comparison panel lists every saved
layout of the design in one table — parts, saved copper, hottest part, junction
temperature and the difference from the board on screen. Only the shown board's
row is filled on load: every other row is a whole second solve of a whole second
board, so rows are filled one at a time on request (`?row=<layout>` answers one
row's cells alone), by a click or by a sweep the reader starts and can stop.
Nothing is capped and nothing is solved behind the reader's back — a design with
fifty saved layouts is fifty solves, and silently comparing a handful of them
would read as the whole answer. A design with one board renders no table. A design with no cooling ladder renders
the sentence saying why in place of the picker, the board frame and the ladder,
because an empty board under a heat legend would read as "solved, and cold".
Read-only: nothing here writes to the project dir.

- GET /thermal/:name renders the verdict headline, the scenario picker, the cooling ladder, per-part rows, the coverage footer and the PDF and JSON links
- the Thermal tab is active on /thermal/:name and follows Assembly on the schematic, PCB and assembly headers
- GET /thermal/:name resolves a design or a bare lib/modules module and answers an unknown name with a 404 whose body is not HTML
- a design with no cooling ladder renders the reason in place of the picker, the board frame and the ladder, and still lists the parts the lumped screen saw
- ?ambient=NN screens the whole page at that ambient clamped to the control's range, and ?fragment=1 answers the verdict and table regions alone
- ?scenario=<tag> opens the page on that rung with its own part table shown and the board frame opened on it
- saved fan and heatsink assemblies can be independently included in or excluded from the active simulation without mutating their layout definitions
- thermal fan and heatsink controls stay synchronized between the scenario panel and 3D setup, selecting the matching simulation scenario and model visibility
- the page's client swaps only the ambient-dependent regions, keeps scenario switching local, and broadcasts a picked ref on the shared cross-probe channel
- the page puts its panel beside a live board frame rather than a static heat image, embedding the read-only PCB viewer with the thermal overlay on
- the board's legend starts at 25 °C to 125 °C, lets the reader edit both endpoints without another solve, and preserves a valid manual range in the page URL
- hovering the thermal board reports the interpolated temperature at the pointer from the same solved grid that paints the heat field
- thermal part labels start hidden, clicking an IC shows only that IC's reference and temperature, and the optional All labels control reveals every reported part on the visible face
- the thermal board view switches between the physical top and mirrored bottom faces without a new solve, shows temperature labels only for parts on the visible face, paints a same-face heatsink above the board and occludes an opposite-face heatsink behind it, and keeps the selected face in the page URL
- the thermal board frame omits generated CAM artwork, routed copper, DRC, pour geometry, and editor-only layout metadata because its exclusive heat overlay hides that data
- GET /thermal/:name?layout=<name> screens that saved layout and carries the choice into the board frame, the tab bar, the cross-probe links and the facts link
- a ?layout nobody saved falls back to the default board and says so rather than screening a board under the wrong name
- the page lists every saved layout of the design in one comparison table, filled only for the board on screen
- GET /thermal/:name?row=<layout> answers one comparison row's cells alone, differenced against the board on screen
- a design with only one board renders no comparison table
- the client solves comparison rows one at a time and can be stopped, and the embedded board frame paints the same layout the page names
- the thermal page uses touch-sized navigation and single-column content at phone width, with wide tables scrolling inside their own box rather than the page
- completeness-waiver: empty inputs (a missing :name and a name matching nothing are both answered 404 by the bullets above; a design with no thermal data renders the insufficient-data hint review_thermal already covers)
- completeness-waiver: large inputs (rendering is a linear pass over an already-screened block; a bigger design only lengthens the rows it formats, and the wide tables scroll inside their own box)
- completeness-waiver: unauthorized access (a read-only GET whose access control lives in serve/ward_auth, not restated here)
- completeness-waiver: i/o failure (every project read flows through evalNamedBlock, whose FileNotFound / NotADesign / InvalidName map to a 404 and whose remaining failures map to a logged 500; a placement that fails to solve degrades to the no-ladder page rather than an error)
- completeness-waiver: concurrent access (each request evaluates and screens into its own request arena and persists nothing, so there is no shared mutable state)
- completeness-waiver: malformed encoding (the path param is percent-decoded before any lookup, every emitted string is HTML-escaped and every emitted URL percent-encoded, and a non-numeric ?ambient falls back to bench ambient)
- completeness-waiver: integer overflow (every measured quantity is an f64 watt, degree or degree-per-watt; the only counts are usize tallies of an existing slice)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## serve/board-review

Public functions: reviewPage, getStateApi, updateStateApi, auditApi

The board Review tab is a board-scoped, generated release checklist. It renders
the supplied 13-section research checklist as 258 stable decisions, detects
which component/interface families apply, closes exact machine-provable checks
as Pass, Fail, or N/A, and queues the remaining evidence packets for either an
agent or a human/measurement decision. Saved human and agent dispositions are
explicit overrides on those generated results. A scoped assessment loads after
first paint from release-profile facts, component profiles, layout progress, DRC,
and BOM evidence without rendering sourcing or fabrication documentation into
the Review page. Each override records Open, Pass, Fail, N/A, or Needs info plus
evidence, a note, an agent tool-attempt ledger, the actor identity/origin, and a UTC timestamp in the
design-sibling .review.json sidecar.

- the PCB header exposes Review only for board designs and preserves a selected saved layout
- the Review page carries the selected saved layout through every physical-board link
- the supplied review catalog retains all 13 sections and 258 discrete decisions
- the page reports ready, static pass, agent queue, human/measurement, blocked and open totals, and supports search plus generated-work filters
- generated applicability closes an absent component or interface family only from evaluated board inventory, while present or uncertain families remain queued unless an analyzer proves the complete criterion
- generated Pass and Fail decisions cite current ERC, power-budget, layout, fabrication, BOM, identity, test-point, or board-declaration evidence rather than the saved sidecar
- human dispositions round-trip all evidence fields in bounded JSON
- a checklist mutation accepts only a catalog item id and fixed status, bounds its evidence and note, requires writer authority plus the review mutation header, and stamps the authenticated identity instead of a body-supplied reviewer
- concurrent checklist mutations serialize their whole read-modify-write and atomically replace the design-sibling sidecar
- agents can read the generated review queue and record evidence-backed item dispositions without editing its sidecar
- the engineering-review scope statically excludes purchase sourcing and fabrication-output paperwork, while the configured DRC profile remains fabrication-rule authority and real DRC violations remain review failures
- the agent queue inventories datasheet coverage by exact fitted BOM MPN and directs local reads, catalogue downloads, or manufacturer-URL fetches before component decisions
- an agent cannot record Needs info without a concrete tool-attempt ledger, and a datasheet blocker requires both acquisition and reading attempts; legacy agent deferrals without that ledger reopen for review
- the automated assessment loads separately after the checklist shell paints and returns only scoped item verdicts plus exact fitted-part datasheet coverage
- read-only reviewers see every disposition and generated result but cannot edit controls
- completeness-waiver: empty inputs (a missing or unknown board name answers 404; a missing sidecar is the valid all-open review state)
- completeness-waiver: large inputs (the catalog is fixed at 258 items, persisted entries are capped to that count, state and request bytes are bounded, and evidence/note fields have independent limits)
- completeness-waiver: unauthorized access (GET is session-gated and read-only; POST additionally requires a writer role and the review mutation header)
- completeness-waiver: i/o failure (state read/write failures answer JSON errors without replacing the prior atomic sidecar; an audit collection failure is shown separately without hiding the checklist)
- completeness-waiver: concurrent access (one server-state mutex covers each state read-modify-write and atomic replacement prevents torn readers)
- completeness-waiver: malformed encoding (the JSON parser validates request/state structure, catalog ids and statuses are allowlisted, HTML uses the shared XML escaper, script strings use the shared script-safe JSON writer, and audit HTML comes from the safe Markdown AST)
- completeness-waiver: integer overflow (all progress counts are bounded by the 258-item catalog and every body/field length is checked before allocation into state)
- completeness-waiver: panic-free (malformed state, invalid item data, missing designs and audit failures return explicit HTTP errors; repo-wide panic-budget covers the remaining allocation-only paths)

## serve/route-review

Public functions: routeReviewPage, routeReviewApi, designRouteReviewApi, cachedDesignRouteReviewApi

The interactive autoroute review page and its compute endpoints. Upload mode
parses and routes a KiCad board entirely in memory; design mode solves a
project design's placement exactly as /pcb-layout would (or, on a POST body of
part poses, places the client's on-screen board verbatim) and routes it fresh
through the shared `(pcb-plan)` seam with the router's decision timeline
captured, filtering the final DRC through the design's rule overrides so the
count matches the /pcb-layout page. Both answer one wire shape so the playback
UI is mode-blind. Design replay is driven from each design's /pcb-layout Replay
panel now — the standalone page is upload-only — and replays are additionally
saved to the project's generated `out/` cache and served back by the cached
endpoint, so a review survives leaving the page; design sources and board files
are never touched.

- the multipart upload filename is read from the part headers
- the design replay honors the authored plan's allowed-layers restriction
- the design replay freezes accepted local sub-circuit copper in its first timeline frame before whole-board routing decisions
- the design replay JSON carries design mode, empty zones, and placement bounds
- the shared routing-surface string writer escapes a control byte instead of dropping it, so a net name survives the round trip intact
- the design replay JSON labels each net with its class name and priority
- the design replay JSON carries the deterministic routing score and its formula version
- a design replay saved to the project cache is read back verbatim
- a POST body of part poses routes the replay at those exact poses
- the design replay filters DRC through the project's rule overrides
- the design replay never opens the design's kicad-pcb board path
- the design replay reports the connectivity oracle's routed/total and keeps the router's own claim beside it
- the replay final payload carries solver RF paths so adopting it preserves custom taper polygons
- the upload replay layers the net-open connectivity check onto its geometric DRC
- completeness-waiver: large inputs (uploads are size-capped at 48/8 MiB before parsing; the design replay is linear over the solved placement's nets)
- completeness-waiver: unauthorized access (read-only compute endpoints; access control lives in serve/ward_auth, and a design name must match the project design list — also the traversal guard)
- completeness-waiver: i/o failure (the upload path is in-memory; design solve/list failures surface as the shared 404/500 pngFailure JSON and nothing is ever written)
- completeness-waiver: concurrent access (request-local arena state only; no shared state is mutated)
- completeness-waiver: malformed encoding (a malformed multipart body answers 400 via parseUpload; the board/project parsers are fuzzed in kicad_pcb/snapshot)
- completeness-waiver: integer overflow (counts are slice lengths bounded by the placement; timeline indices are validated against the net list before printing)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## serve/route-live

Public functions: routeLiveStartApi, routeLivePollApi, routeLiveCancelApi

Background live-route jobs — the streaming twin of the blocking `POST
/api/pcb-route/:name`. `POST /api/route-live/:name/start` takes the same
route body, solves the placement synchronously in the request (errors are
immediate 4xx/5xx and nothing is spawned), then starts a detached routing
thread whose progress sink serializes every captured timeline event into a
mutex-guarded, generation-versioned per-design job store; the response
carries the job generation and the net-name table the streamed tuple net
indices reference. `GET /api/route-live/:name?since=K&attempt=A` returns the
job envelope plus events past the cursor (capped per batch, in
route-review's replay timeline element shape); a finer-grid router restart
bumps the attempt and restarts the stream from zero, and a finished run
splices the blocking endpoint's exact response contract into the envelope as
`final` and persists as the design's cached replay. `POST …/cancel` trips
the router's cooperative cancel flag; the job still finishes to a valid
partial result, and skips the stuck-net diagnosis (minutes of remedy search
over nets the user chose not to wait for) so the stop lands promptly. Both
surfaces route through pcb_layout_page's shared prepare/route/write
pipeline, so the blocking and live contracts cannot drift.

- a started live job streams the router's timeline events and finishes with the blocking route contract as its final payload
- each streamed event serializes exactly as a replay timeline array element
- polling with a cursor returns only events past it and caps one batch
- a finer-grid restart bumps the attempt and restarts the event stream from zero
- a second start while a job is running is refused with the in-flight generation
- a cancelled live job still finishes to a valid partial result
- a cancelled live run skips stuck-net diagnostics so the stop lands promptly
- a completed live run persists as the design's cached replay
- completeness-waiver: empty inputs (a missing body or parts array answers 400 before any job begins; polling or cancelling a design with no job answers 404; a partless placement routes to an immediate done job with empty arrays)
- completeness-waiver: large inputs (each poll batch is capped at 200 events and the client re-polls; events and payloads are linear in the router's own bounded timeline)
- completeness-waiver: unauthorized access (start and cancel are compute-only POSTs allowlisted in serve/ward_auth's read_only_posts exactly like the blocking route; the poll is a GET behind the same dispatch middleware)
- completeness-waiver: i/o failure (the only disk write is the best-effort cached-replay persist, swallowed like the design replay's; a failed solve answers 4xx/5xx and spawns nothing, and a failed spawn finishes the job as errored)
- completeness-waiver: concurrent access (one Store mutex serializes every job mutation; jobs are generation-versioned so a superseded thread's writes are dropped, a start while running is refused, and only a finished job's replacement frees its memory)
- completeness-waiver: malformed encoding (a body that isn't JSON answers 400 before any thread exists; malformed query cursors read as zero; event JSON strings are escaped by the shared writeJsonString)
- completeness-waiver: integer overflow (cursors clamp to the stored event count; counts are slice lengths bounded by the placement; elapsed time is i64 milliseconds)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

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
- denies write_file on lib/datasheets (PDFs are read-only via CLI)
- readFile reports an error when a non-zero offset is at or beyond the end of the file
- writeFile append mode concatenates content onto the existing file
- writeFile append composes with expected_sha256 CAS checked against the pre-append file
- dirtyDesignsForPath maps a nested src/**/<name>.sexp path to the design basename

## serve/component_info

Public functions: describeComponent, listRequirements, addRequirement, removeRequirement

- kebab-cases every Check variant tag
- describe reports an authored class key
- findSourceComment finds the source-of-truth path
- parsePinoutBody normalises pin ID shapes
- describeComponent resolves the pinout via the symbol ref and reports it
- describeComponent attaches the electrical type to each matching pin
- listRequirements returns each requirement with its derived id
- addRequirement appends a requirement form before the component close
- addRequirement rejects a check clause the checker does not recognize
- addRequirement rejection names the accepted check primitives and reference section
- removeRequirement deletes a requirement by id or exact text
- formEnd skips parens inside string literals
- form bounds skip a semicolon comment and refuse an opening byte that is not a paren
- add list and remove requirement round-trip on disk
- describeComponent reverse-maps explicit module implementations
- describeComponent exposes digest-bound datasheet review evidence

## serve/notes

Public functions: getNotesApi, saveNotesApi, getTasksApi, addTaskApi, completeTaskApi, reopenTaskApi, removeTaskApi, parseNotes, renderNotes, loadNotes, addTaskCore, mutateTaskCore

- Reads and writes `<design>.notes.md` next to the design source file
- Returns an empty string when no notes file exists yet
- Rejects bodies larger than 1 MiB
- Parses open and done task lines and preserves scratchpad
- Ignores lines that don't match the structured task format

## serve/upload

Public functions: importZipBytes, extractStepBytes, uploadZipApi

- KiCad ZIP import stages outside RAM-backed /tmp and reads entries with bounded std.zip extraction, without requiring system unzip
- completeness-waiver: empty inputs (an empty or non-ZIP body fails archive extraction and writes no library entry)
- completeness-waiver: large inputs (HTTP bodies are capped at 64 MiB; extracted symbols and footprints at 10 MiB each; STEP models at 50 MiB)
- completeness-waiver: unauthorized access (the route is dispatched only after the shared Ward authorization middleware accepts the request)
- completeness-waiver: i/o failure (staging and library-write failures return a 500-class ImportError and the staged archive is removed on every later exit)
- completeness-waiver: concurrent access (process-unique timestamp-plus-atomic-counter staging names prevent colliding uploads)
- completeness-waiver: malformed encoding (std.zip validates archive structure, filenames, compression methods, extents, and CRC before bytes reach a converter)
- completeness-waiver: integer overflow (ZIP sizes are checked before u64-to-usize conversion and output allocation)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## serve/upload_datasheet

Public functions: uploadDatasheetApi, listDatasheetsApi, serveDatasheetApi, isPdfMagic, sanitizeFilename, storeDatasheet, storeErrorBody, storeErrorStatus

- sanitize strips path segments
- sanitize forces .pdf extension
- sanitize replaces unsafe chars
- sanitize strips duplicate-download marker
- sanitize preserves trailing-digit names
- sanitize keeps `+` so a Mini-Circuits filename survives its own round trip
- isPdfMagic gates non-PDF input

## serve/edit

- datasheet dedupe ignores re-download counter suffix
- datasheet stem preserves trailing-digit part numbers
- edit-footprint locates the component token within the instance form
- rewire-pin locates the instance by component-token offset
- rewire-pin splits a multi-pin shorthand to re-wire one pin
- rewire-pin finds a pin in a section pins map
- a design saved through writeAndRebuild pins its minted (id …) into the source, so the next save reproduces the same uuid and its exact selected-row BOM identity
- restoring a history snapshot pins the restored source's minted ids before identity resolution

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
- modelUrl targets the ga/model.php endpoint by part id
- safeFilename builds a path-safe LIB_<part>.zip
- searchVariants relaxes the part number
- parses part id and datasheet url from a suggestion
- collectHits maps suggestions to search hits
- containsHit dedups aggregated hits by part name
- hoistExact moves the exact query match to the front
- every fetched URL follows a -- end-of-options guard so a URL beginning with a dash cannot become a curl option

## serve/digikey

Public functions: resolveMpn, searchErrorMessage, downloadDatasheet, datasheetErrorMessage

- parseAccessToken extracts the bearer token from the OAuth response
- searchRequestBody excludes marketplace listings from every keyword search
- collectProducts maps the Products array to resolved parts
- collectProducts captures live stock, unit price, status, and per-variation price breaks
- keywordVariants drops trailing keywords for graceful relaxation
- normalizeDatasheetUrl unwraps a gotoUrl interstitial
- completeness-waiver: concurrent access (each adapter call owns its request and response buffers; shared outbound admission and spacing are synchronised and tested by serve/rate_limiter)

## serve/rate_limiter

Public functions: init, acquire, release

- acquire/release pair leaves no slots held
- acquire spaces successive call starts by the minimum interval
- acquire blocks a caller once max_in_flight is reached until a release

## serve/subprocess

Public functions: runCaptured, deinit

- runCaptured captures stdout and a zero exit code for an in-budget run
- runCaptured reports timed_out and kills a child that overruns the deadline
- runCaptured reports output_too_long when a child exceeds the byte cap

## serve/datasheet

Public functions: read, fetch

- window clamps offset and limit to the text and flags truncation
- read_datasheet result exposes the current PDF digest for datasheet-review provenance
- fetch_datasheet stores a fetched PDF under a sanitized lib/datasheets name and reports its sha256 and byte count
- fetch_datasheet re-fetching identical bytes is idempotent and reports the unchanged digest
- fetch_datasheet refuses to replace a stored datasheet whose bytes differ unless overwrite is requested
- fetch_datasheet content-sniffs the %PDF magic and rejects a non-PDF body and any non-http(s) URL without writing
- fetch_datasheet accepts a validated manufacturer source_page and forwards it as the HTTP Referer for product-gated PDF endpoints
- fetch_datasheet derives its target name from the URL path segment, dropping query and fragment
- a fetched Mini-Circuits filename keeps its trailing `+` and read_datasheet resolves that exact stored name

## serve/mcp_checks

- build and run_checks share structured requirement/datasheet preflight finding fields
- build preflight_ok includes non-warning assertion failures
- completeness-waiver: empty inputs (missing names and invalid profiles return explicit tool errors; designs with no findings serialize empty arrays)
- completeness-waiver: large inputs (the handler streams JSON and keeps only request-local change sets and validation results proportional to the design)
- completeness-waiver: unauthorized access (the CLI runs with the invoking user's filesystem authority)
- completeness-waiver: i/o failure (design and history snapshot load failures return explicit false tool results with error text)
- completeness-waiver: concurrent access (every invocation owns its evaluator, maps, and output buffer without shared mutable state)
- completeness-waiver: malformed encoding (the JSON layer validates arguments upstream, and this handler rejects invalid profile and snapshot-id text)
- completeness-waiver: integer overflow (serialized counters and slice walks are bounded by request-owned allocations, with no untrusted integer arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## serve/mcp_tools

- get_pcb_layout_image declares its heat-zone thermal flag and the scenario enum, so a strict client may send the arguments the renderer reads
- clean_route_topology removes deletion-invariant saved trace sections and recursively exposed loose stubs transactionally without rerouting the board
- clean_route_topology supports a non-persisting dry run and an optional net-name scope
- normalize_junctions CLI/HTTP actions explicitly repair saved implicit joins, support dry-run/net scope, and persist only a connectivity- and DRC-safe candidate
- Saved-copper rewrites preserve stamp-group, fence-provenance, and via-span tags on unchanged geometry
- CLI virtual-file mutations refuse .layouts.json sidecars and direct callers to protected PCB layout tools
- restore_layout_snapshot restores protected PCB layout history after snapshotting the current sidecar and bumping its revision
- stitch_ground_pads applies the autorouter's final ground-reference pass transactionally to a saved layout
- attach_datasheet links a stored PDF into the library component, refuses a filename absent from lib/datasheets, and reports an already-linked stem instead of duplicating it

Public functions: isMutationTool, call, listFreePins, listDesignNames, listDesignSummaries, renderSceneGraph, requireString, optionalString, optionalU64, optionalBool, missingArg

- fuzzyScore returns 0 when the needle does not match the haystack as a substring or subsequence
- fuzzyScore ranks a contiguous substring hit above a scattered subsequence hit
- fuzzyScore ranks a prefix hit above a mid-token hit for the same needle
- libEntryScore ranks a name match above a description-only match
- list_library with a query returns only fuzzily-matching entries ranked best-first
- list_library without a query returns a names-only {count,names} listing per category
- list_library caps the ranked query results per category at the limit argument
- list_library category argument scopes the response to a single library subdir
- severityPasses passes all violations when the filter is null, else only that severity
- build tool severity arg filters the erc[] array to the named severity
- build response carries eval warnings in a warnings[] array separate from erc[]
- The tools registration table and the embedded tools_list_result.json declare exactly the same tool names
- get_schematic defaults to a compact summary far smaller than the full scene graph
- build, list_instances, and get_net resolve allocator-owned refdes from the same stable-ID BOM ledger
- flatten makes list_instances include sub-block children with prefixed refs and origins
- list_instances counts pins from the component pinout when the part declares no symbol
- flatten makes get_net return the merged rail and resolve a sub-scoped net spelling
- flatten makes get_net resolve a bare leaf name to the unique module-internal net
- flatten makes get_net list the candidates when a bare leaf name is ambiguous
- A module file that uses its own components imports them, so a design can import the module alone without also importing the module's dependencies
- flatten makes list_free_pins match a flattened child by name and read merged assignments
- flatten merges a sub-block stitch written against a port name whose module net differs
- finishDatasheet returns false when the store rejects the bytes
- parse_kicad_netlist returns components, pads, and a connected-net count
- A name-list tool argument reads the same from a JSON array and from a comma string
- parse_kicad_netlist rejects a board_path that does not end in .kicad_pcb
- import_kicad with dry_run reports importer counts without writing files

## config

Public functions: cseEmail, csePassword, digikeyClientId, digikeyClientSecret, digikeyApiBase, cseMinIntervalMs, cseMaxInFlight, digikeyMinIntervalMs, digikeyMaxInFlight

- stripQuotes removes one layer of matching quotes
- The ward cache ttl maps a zero or out-of-range value to the default and keeps valid values
- The git auto-commit env gate disables only on a bare 0 and is enabled otherwise

## paths

Public functions: designSourcePath, designSourcePathUnique, designSiblingPath

- Resolves <name>.sexp via designSourcePath, falling back to flat layout when missing
- Resolves sibling artifacts via designSiblingPath using the supplied extension
- A release source lookup rejects duplicate design basenames instead of selecting the first directory walk result
- Module release sidecars resolve beside the selected module source even when an orphan artifact with the same basename exists under src
- A src index revalidation triggered by another request leaves a traced lookup's consumed-input closure unchanged

## lib_limits

The read caps on netlisp's own `lib/` source files, owned in one place so a cap
is a property of the FILE CLASS rather than of whichever module happens to open
it. Two classes: `lib/footprints/<name>.sexp` and the
`lib/<components|pinouts|modules>/<name>.sexp` family. Spelling a cap per-reader
produced a real defect twice — a footprint that loaded in the editor was refused
by the preview, and two pinout readers stayed at 256 KiB while the rest read
1 MiB. Every reader still swallows an over-cap read (`catch continue` /
`catch return null` / `catch return false`) rather than failing a request, so a
part goes missing from a page, a BOM row or a pin-name map instead of erroring —
but the swallow is no longer silent: each reader now logs the file and the
fallback it took, skipping only the ordinary `FileNotFound` case, so the
degradation is visible without changing any caller's control flow or status code.
`retired_lib_file_cap_bytes` records the superseded 256 KiB figure so the
"raise never lower" rule is testable rather than only asserted here: every
reader's regression test sizes its fixture off it.

- Both lib/ read caps clear the largest part this tree targets, so neither may be lowered back under its worst case
- The shared over-cap pinout fixture is larger than the retired 256 KiB cap and still inside the live class cap

- completeness-waiver: empty inputs (a zero-byte lib file is under every cap; emptiness is the parser's contract, not this module's. `synthPinoutSource` with `min_bytes = 0` or an empty name still emits a well-formed head and sentinel row, so it has no degenerate output)
- completeness-waiver: large inputs (this module IS the large-input policy; the over-cap case is the caller's swallowed read, specified and tested in each reader's own section)
- completeness-waiver: unauthorized access (both classes live under the trusted local project dir and neither is an upload seam; the traversal contract on the names spliced into these paths belongs to `paths` and each handler's own name validation)
- completeness-waiver: I/O failure (no I/O here; the module declares caps and builds a fixture string in memory — it opens nothing)
- completeness-waiver: concurrent access (the caps are comptime constants and `synthPinoutSource` touches only its own locals and the caller's allocator, so there is no shared mutable state)
- completeness-waiver: malformed encoding (no parsing here; a lib file's syntax is the sexpr parser's contract)
- completeness-waiver: integer overflow (the three cap values are comptime `usize` literals ~1e6, six orders of magnitude inside the type; `synthPinoutSource`'s row counter is bounded by `min_bytes`, which the allocator would refuse long before the counter could wrap)
- completeness-waiver: panic-free (the caps are comptime declarations, and the one runtime path — `synthPinoutSource` — returns `Allocator.Error` rather than panicking, so an exhausted allocator surfaces as an error to the caller)

## infra/atomic-write

The one place a file is replaced rather than rewritten in place. A truncating
`createFile` + `writeAll` pair leaves the target empty or half-filled if the
process dies between the two syscalls, and the files this guards — a design's
`.sexp` source, a library component, a notes document — are the user's authored
work with no other copy. Every write stages into a sibling temporary, flushes,
fsyncs, and renames, so a reader sees either the whole previous file or the
whole new one and never a torn middle. It wraps `infra/fs.zig`'s `AtomicFile`
rather than hand-rolling create+rename: that keeps the tree's one I/O-capability
boundary intact and inherits a randomly named temporary that is retried on
collision, which is what a fixed `<path>.tmp` gets wrong when two writers race.
The fsync is the one thing added on top, and it is best-effort and logged — a
filesystem that does not implement it must not fail a user's save for a reason
the user cannot act on.

Atomicity is not serialization: this module stops a torn file, not a lost
update. Two callers that each read, modify and write the same path still race,
and that ordering belongs to the caller.

- writeFile replaces the target with exactly the new bytes, an empty body included
- an oversized body larger than the staging buffer lands whole
- a staged write abandoned before commit, or stopped by a write error, leaves the previous file contents intact
- neither a committed nor an abandoned write leaves a temporary file behind
- write and commit on a Staged whose begin never succeeded return NotStaged with no panic
- two concurrent writers staging one target use distinct temporaries and the later commit wins whole

- completeness-waiver: unauthorized access (it opens exactly the path it is handed and grants no capability of its own; name validation and traversal defence belong to the callers — `paths.designSourcePath`, `library.isSafeLibName`, and each route's own `:name` check)
- completeness-waiver: malformed encoding (the payload is an opaque byte slice that is never parsed here; a design source's or a notes document's syntax is the sexpr and notes parsers' contract)
- completeness-waiver: integer overflow (no arithmetic beyond one comptime buffer length and the slice lengths the writer already bounds)

## numeric

The sanctioned narrowing guard. `[int_from_float]` in `guardian.toml` names
`checkedInt` as the one wrapper a raw `@intFromFloat` may hide inside, so every
float that becomes an integer anywhere in the evaluator, the placer, the KiCad
importer and the board readers passes through here. That makes its bound a
safety property of the whole tree rather than a local detail: a value it wrongly
admits is undefined behaviour in the safety-off production build, at whichever
call site happens to receive it.

The upper bound is therefore exclusive — `maxInt(T) + 1` — because for any T
whose value bits exceed the f64 mantissa, `@floatFromInt(maxInt(T))` cannot
represent the maximum and rounds *up* to exactly `maxInt(T) + 1`. An inclusive
`r > hi` test compares equal there and waves the out-of-range value through.
`maxInt(T) + 1` is a power of two and so is exact in f64 at every width, which
is what makes the predicate exact rather than approximately right.

- checkedInt admits exactly the values representable in T, rejecting the maxInt+1 overflow bound at every width

- completeness-waiver: empty inputs (the input is a single f64; there is no collection to be empty, and the non-finite cases are part of the specified behaviour rather than an edge)
- completeness-waiver: unauthorized access (pure arithmetic on a value the caller already holds; it reads no ambient state and grants no capability)
- completeness-waiver: I/O failure (no I/O — the module opens nothing and reads nothing)
- completeness-waiver: concurrent access (pure functions over their arguments with no shared mutable state, so every call is independent)
- completeness-waiver: malformed encoding (an f64 is not parsed here; NaN and the infinities are specified inputs, not encoding errors)
- completeness-waiver: large inputs (a magnitude past the target type's range is the case this module exists to reject, and it is specified above rather than waived away)
- completeness-waiver: panic-free (every path returns `null` or a value; the `@intFromFloat` is reached only after the range test that makes it defined)

## Web Server

- The panel export disables V-score for rounded, curved, or non-rectangular outlines, selects routed tabs instead, and explains the constraint before export
- The panel export groups rail presence into one top-and-bottom toggle and one left-and-right toggle while preserving each side's configured width and features
- The panel export shows a live dimensioned preview that repeats the actual board outline inside its configured rails and marks scores, tooling holes and fiducials
- The panel export controls independently size every rail side and selects pairs of NPTH tooling holes and top-copper fiducials near both ends of each enabled side
- The Full archive control runs the ordinary fab-readiness confirmation flow, posts the same analytic full-board STEP recipe as the 3D tab, and downloads the complete design archive
- A failed Full archive download identifies the archive and displays the server's actual rejection reason
- The DRC reconcile session answers only for a board whose non-copper inputs are unchanged
- A DRC reconcile store with no allocator retains nothing and every request takes the full check
- The DRC reconcile store keeps two designs and evicts the least recently leased
- A reconcile session is claimed by one design name and one sub-circuit slug
- A reconcile snapshot that carries the previous one's deferred findings forward is retained without aliasing the memory it copies from
- A background full-board DRC sweep refreshes the kinds a scoped recheck defers, and the next reconcile answer carries them
- A background full-board DRC sweep corrects a ledger that lost a finding or invented one, and counts the disagreement
- A background DRC sweep answer for a state the session has left is dropped without touching its ledger
- Background DRC sweeps are one thread per design, capped across designs, and a re-arm during one coalesces into it
- A background DRC sweep refreshes the deferred kinds and treats a difference in them as the refresh, never as a discrepancy
- A background DRC sweep reports every non-deferred finding the scoped answer and a full pass disagree about, in both directions
- A background DRC sweep of a design with nothing accepted does nothing
- The DRC endpoint re-checks a copper edit against the board state it last accepted and returns the answer a full check returns
- Every interaction-log line carries an ISO-8601 timestamp, the build id, its source and its event name, with JSON-escaped values
- The interaction log appends one line per event to a dated file under the project's logs directory, creating it on demand, and writes nothing at all when no project directory is set
- A handler's stage timer reports every phase it names and a total that covers the work after the last one
- An instrumented handler files its own phase breakdown in the interaction log, naming every stage it ran and the total that covers them
- The layout-save endpoint reports its design-resolve phase separately from the rest of the write, so an autosave's cost is attributable
- A saved layout is persisted without an objective score, and an identically placed auto run is left alone rather than promoted into it
- The client-log endpoint appends one line per posted browser event, passing its scalar fields through, and refuses an oversized body or event burst without writing anything
- the schematic page exposes the current board role as a Design type selector on designs but not reusable module pages
- the schematic Design type control replaces only the design root's board-role form, preserving comments and nested module text
- the schematic Design type control adds an explicit role when a string-named block currently relies on the subcircuit default

- A PCB design with PDN intents resolves selected BOM electrical model properties before placement
- The PCB trace inspector marks a target-synthesized through-via beyond its lambda-over-twenty model band as requiring 3D verification and never presents its diagnostic sweep as a green full-band verdict
- The PCB PDN inspector labels each capacitor power and ground path provenance and withholds a green target verdict when any mounting path remains estimated or no bound capacitor was extracted
- Hierarchical routing processes first-level sub-circuits in authored order, freezes each accepted DRC-clean local signal tree, and then runs exactly one assembled-board global candidate
- Live autorouting names each first-level sub-circuit when it starts and streams its cumulative copper when it finishes, before whole-board global routing begins, so full and subcircuits-only runs both reveal local progress
- A fresh isolated candidate supersedes saved module copper on the same net, including supply nets, so stale snapshots cannot poison valid bypass bonds.
- The PCB live-route status freezes the local-stage clock when whole-board routing starts, names final DRC work, and preserves the final elapsed time after the job ends
- A hierarchical local pass resolves each child PCB plan in the child's net namespace, including flattened port renames, while the destination board may narrow hard layer and via constraints
- When two local candidates collide, the earlier DRC-clean net remains frozen and only the later candidate is deferred to the global route
- Accepted local plane drops are immutable same-net sources in the single global pass, so the global plane phase does not duplicate their barrels
- Route responses report attempted, completed, and timed-out local sub-circuits, deferred supply nets, and accepted carrier drops while the compatibility fallback flag remains false
- Carrier-backed ground terminals receive independent local drops and never a routed pad-to-pad surface web. Other carried power/input rails may keep authored exact-target bypass cap-to-pin surface bonds; without a declared plane or retained pour, authored passive-to-IC bonds and validated starred module copper complete bounded local supply trees while the board-spanning remainder waits for global routing
- A hard route deadline gives all local sub-circuit completion attempts at most one quarter of the initially remaining time and preserves the original absolute deadline for the global phase
- get_schematic_image is a registered read-only CLI tool
- get_pcb_layout_image renders the heat-zone image when thermal is set, and a different picture for each cooling scenario
- The board PNG query turns ?thermal=1 into a heat-zone request carrying its scenario and ambient, and an unknown scenario word falls back to still air rather than refusing the image
- export-schematic-png parses native image focus, view, theme, width, and output options
- Native schematic export paints the SVG display list into a valid PNG without a browser
- Schematic image view parsing accepts the UI's Sequential and Functional names and defaults to Functional
- The schematic display-list translator applies the renderer's rotate group transform to vertical passives
- The src basename index resolves a design sibling without re-walking the tree, and rebuilds when a directory it walked changes mtime
- A sexp under src that declares no top-level design-block is judged once and the verdict reused until that file changes
- A design whose evaluation fails is cached against the library files its imports could resolve to, so creating the missing one re-evaluates it
- The home page's data gather runs without a request, so the startup warm-up fills exactly the caches a render reads
- The home page lists every `src/systems/` review workspace as its own card kind, from the same enumeration `/api/systems` serves, so a system is reachable without knowing its URL
- A system card's search text leads with its kind word and carries its identity, so the home page's existing search box and its Systems filter both surface it with no extra client script
- The PCB layout page renders without a request, reading a missing request as the plain no-query page, so the startup warm-up can retain it under the same cache entry a bare URL looks up
- Startup warms PCB editor pages before the slower progress ladders, so an unrelated lazy diagnostic cannot leave every editor cache cold after a deploy
- Startup warms every PCB page before any deferred payload, so a deploy has the pages a reader blocks on cached in about a second rather than behind twelve boards of analyses
- One warm-up render answers both the PCB page and its deferred payload, each reserved and retained under its own cache identity
- A deferred-payload warm reserves the SAME cache entry the editor's `?derived=1` fetch looks up, so the browser joins that render instead of starting a second one
- Background PCB deferred-payload warms are capped, so a burst of saves cannot put the heaviest read-only render on every core
- Background warm concurrency is bounded at half the host's cores so a startup sweep cannot occupy the machine it is warming
- A parallel warm sweep processes every design exactly once regardless of how many workers it runs
- Concurrent design scans coalesce onto one evaluation per design instead of each starting its own
- Two different designs never block each other in the scan's single-flight latch
- A background warm sweep pauses for in-flight requests and still proceeds when the server stays busy
- A process that never marked a start reports no boot elapsed, so CLI commands carry no server timing
- A process-start mark taken before the I/O capability is installed is refused rather than recorded, so the startup line reports real elapsed milliseconds or none at all
- The design scan lists every design under src whatever order its parallel fill ran in, and concurrent scans agree
- The startup board sweep skips designs with no saved layout and dispatches the heaviest remaining board first, so the last one to start does not set the wall
- A warm-up reservation drops a retained PCB entry an edit has already invalidated, so the warm that edit triggered actually runs instead of deferring to the dead entry
- The PDN impedance sweep rides its own response behind the after-paint payload, marked by a null `ac`, so the board's own diagnostics never wait on the editor's most expensive analysis
- The PDN sweep is keyed apart from the after-paint payload, so the viewer's two fetches never collide on one cache entry
- The progress store accepts a ladder computed off-request under the same size and read-set rules as a served one
- The saved-routes parser silently culls a track that has collapsed into a sub-micron ball, on the save and the sidecar load alike, judging an arc on all three of its points and keeping one whose points still describe a circle
- Reading a saved layout back out of its sidecar drops the collapsed sub-micron crumbs its copper carries, so an old board opens healed without its file being edited

- One library basename allowlist admits both the library endpoints' name params and the 3D viewer's footprint params, so a part number carrying a plus sign resolves through either route
- completeness-waiver: concurrent access (the umbrella section owns no single mutable store; endpoint-specific locking, revision conflicts, atomic sidecar writes, and request-local state are specified and tested in their dedicated serve sections)

- On phone-width screens the PCB layout prioritizes a full-height touch viewport with read-only inspection and layer bottom sheets
- Phone-width Design, Library, Schematic, and Assembly pages use touch-sized navigation, single-column content, and board-first inspection without horizontal page overflow
- PCB drag/drop keeps full-board work and retained-overlay rebuilds off the interactive path
- visible board silkscreen text can be selected and grid-dragged directly in Select mode, with one undo step and refreshed DRC
- R and Shift-R rotate a held board-silkscreen label live and commit the whole drag as one undo step
- PCB keepout overlays retain width-batched net-class geometry and one transform-keyed raster cropped to the visible halo bounds, painting fixed regions directly so a zoom never clears or copies a redundant viewport-sized overlay
- Stable PCB layout pages reuse dependency-validated rendered HTML and invalidate it when the design or layout sidecar changes
- Repeat assembly workspace loads reuse dependency-validated HTML and invalidate when rework-guide availability changes
- A captured page-cache read-set stamps the evaluated design's own source file, so editing it invalidates the cached result
- The layout-progress ladder endpoint bypasses its cache for any query parameter
- The layout-progress ladder endpoint reuses a dependency-validated JSON body and invalidates it when the design or its sidecars change
- The layout-progress cache refuses a body whose dependency set stamps nothing
- The PCB-describe endpoint reuses a dependency-validated facts document and invalidates it when the design or its sidecars change
- The PCB-describe endpoint caches only its allow-listed query modes and bypasses fresh-solve and sub-scoped requests
- The PCB-describe cache refuses a body whose dependency set stamps nothing
- The read-only response caches reuse a dependency-validated body and invalidate it when the design changes
- The read-only response caches key their allow-listed query parameters and bypass every other one
- The read-only response caches refuse a body that stamps no file, that is over budget, or that a live edit raced
- The read-only response caches are bounded by entry count and by retained bytes, evicting a keyed variant before the plain answer
- A read-only response cache with no allocator retains nothing, so a handler test computes every answer fresh
- A cached ERC answer is byte-identical to the freshly computed one it was retained from, and an edit to the design retires it
- A cached thermal answer is byte-identical to the freshly computed one it was retained from, and an edit to the design retires it
- The PCB image endpoint reuses a dependency-validated image and invalidates it when the design or its sidecars change
- The PCB image endpoint caches only its allow-listed framing modes and bypasses fresh-route, fresh-solve and sub-scoped requests
- The PCB image cache refuses a body whose dependency set stamps nothing
- The PCB image cache retains nothing when its server gave it no allocator
- A cached read endpoint frames a hit exactly as a freshly computed answer and reports a failed computation in its own error shape
- The shared cache eviction sweep spends a keyed variant before the plain answer
- The shared cache eviction sweep falls back to plain recency for a store whose entries carry no variant flag
- A shared-core cache teardown frees every retained entry, and does nothing at all for a store that was never given an allocator
- The layout-status reader reuses a parsed layouts sidecar until that file's mtime or size changes
- The fab-readiness gate reuses caller-supplied net connectivity instead of recomputing it
- The navigation bar routes home through the Netlisp brand and carries no separate Designs tab
- A standalone module opened through the schematic page exposes direct pin-net editing and deletion for source-backed parts
- The PCB editor can explicitly make one named saved layout authoritative in KiCad after a destructive-change preview
- The PCB editor paints saved geometry, restores exact-state copper fills from persistent browser storage or the fast refill endpoint, then launches whole-board diagnostics and electrical analyses
- The PCB editor batches attributable saved-layout RF taper migration candidates into at most two whole-board DRC passes, conservatively falls back for unlocated errors, and reuses rejected results while the submitted board state is unchanged
- Saved-layout RF taper migration follows unambiguous physically overlapping legacy capsules across centreline gaps and bridges the terminal land overlap, so replacing round caps with exact butt-ended swept copper cannot open the routed net
- RF finish preserves the autorouter's already-shaped variable-width taper segments as physical copper; class-width normalization and saved-handle retrofit apply only to legacy or human-authored compact handles
- A plain click on the board outline's edge or a corner handle shows its properties instead of being swallowed by the outline-edit drag arming
- The PCB editor's DXF import assembles a line/arc contour into a closed outline even when the export left sub-µm endpoint seams, mixed winding, or a duplicated contour
- The PCB editor imports a DXF board outline: the page ships a DXF button (toolstrip + embed action bar) and the importer script, whose client-side parser exposes the loops a picked .dxf found (LWPOLYLINE/POLYLINE loops, LINE/ARC chains, $INSUNITS units, Y-flip to the board frame)
- The PCB editor imports a DXF board outline: the importer honours $INSUNITS, flips Y to the board frame, preserves native arcs in the editable sketch, and feeds the existing outline-override seam (Save/Update persists it like any drawn outline)
- The PCB board-outline sketch keeps stable entities, constraints, driving dimensions, and exact arcs in a separately testable client model loaded before the editor
- The neutral shape-sketch kernel is shared by board outlines, custom copper pours and keepouts, fabrication backing regions, custom footprint pads, footprint courtyards, and closed silk/fab artwork; board cutouts and slots remain outside this single-contour engine
- Dragging an endpoint of a horizontal or vertical outline segment changes its length without translating the constrained line, with dominant-direction disambiguation at H/V corners
- Sliding a shape-sketch line through line-arc-line corner fillets carries each valid arc rigidly, including saved near-tangent fillets, and changes only the length of its outer straight neighbour
- Two selected straight sketch curves can be constrained co-linear, and dragging the two loose line endpoints of one open contour together snaps and merges their stable point identity to close the fabrication profile
- The PCB outline sketch box-selects corner vertices in Outline mode or the Outline-only filter; Delete removes selected vertices and their incident curves without healing the resulting open profile, while Remove fillet remains a separate sharp-corner command
- The PCB editor selection filter includes the board outline and a session-only Outline only preset that disables every other filter type and suppresses board-text selection without making a reopened board appear unresponsive
- The PCB outline Line tool stays inside the sketch, creates connected native line chains, snaps endpoints to shared existing point IDs and H/V inference, lets Enter retain an open chain, and normalizes a reconnected closed loop for fabrication
- While drawing a custom copper area, nearly horizontal or vertical segments snap onto that axis in both the live preview and committed polygon; holding Ctrl bypasses only this axis inference
- Backspace or Delete on a selected native outline curve removes only that curve, leaves loose endpoints for free sketch editing, remains undoable, and Save explains that open geometry must be reconnected
- A malformed custom copper-area save names a clickable exact zone that enters its sketch and frames it; a single connected two-endpoint gap exposes an explicit undoable Close profile repair and is safely closed on save for stale sessions, while branches and disconnected geometry are never guessed closed
- When a copper-area sketch cannot compile as a closed contour but its persisted visible polygon is valid, Update rebuilds a clean closed line sketch from that exact polygon and saves the remaining layout edits; crossing or zero-area visible polygons are still rejected
- The PCB editor overlays source-declared fabrication backing, edits every region with the outline sketch palette and undo, and persists compiled polygons plus index-aligned native sketches without changing side or material
- The PCB editor draws one target-free physical heatsink rectangle on either PCB face, reopens it for parameter edits, drags it to reposition, resizes it with corner handles, directly edits fin count or gap, material, base/fins and thermal pad, persists the assembly with the named layout, previews its pad/base/fins in 3D, and resolves a populated face through covered packages' directional theta-JC-top into one shared plate while an unobstructed face couples the PCB through the pad
- The PCB editor offers a persistent display-only heatsink visibility toggle in Appearance > Objects, without changing saved geometry or thermal simulations, and entering the heatsink edit tool reveals a hidden heatsink
- The PCB editor draws a movable circular axial-fan target and outlet footprint, edits its PCB face and outlet-to-target distance with its catalog airflow/pressure and installed-flow assumption, explains that a same-face heatsink makes the target its fin tips, and persists the exact fan assembly with each saved layout for the thermal fan scenario
- Selecting a board outline exposes editable dimensions, slides horizontal/vertical edges only perpendicular to themselves, and uses Shift to constrain non-axis-aligned edge slides to their dominant axis
- The PCB passive inspector offers compatible footprint families from the project library
- PCB passive footprint edits update the exact owning schematic source
- tangent trace bends and outline fillets remain native editable arcs in the PCB editor
- While hand-routing, the PCB editor can toggle the preview and committed path between 45-degree octilinear and 90-degree Manhattan bends
- The PCB hand router defers adaptive electrical-width verdicts its zone-blind WASM tier cannot prove, while retaining branch-floor and fabrication-minimum errors locally
- The PCB editor defers every server-solved power finding — the solved width, its whole-rail envelope variant, and the via-count rule — to the authoritative server DRC
- The PCB editor widens adaptive power copper to each track's own solved branch current, falling back to the whole-rail envelope only when that screen is absent, stale, or unsolved
- The PCB editor places repeated standalone vias on a chosen net without creating trace segments, using grid/copper snapping, net-class geometry, the live DRC gate, and one undo step per via
- Escape cancels an active manual route even when its final route-wide DRC check rejects finishing it, restoring the route-start copper and exiting Draw instead of retrying the blocked finish
- A hand-routed RF launch keeps its generated portal collar inside the source pad, retries a DRC-blocked wide-land taper with progressively shorter flares, and finishes with the independently DRC-confirmed uniform trace when no automatic taper fits
- A controlled-impedance launch approaching a pad corner substitutes the pad's narrow dimension for a degenerate local chord, retaining a visible wide-land taper while a genuinely narrow land still receives its physical-width taper
- Every saved trace segment and via has a stable inspector-visible ID that survives saves and retained-copper rewrites, with deterministic IDs backfilled for legacy copper
- The PCB editor rotates components, rigid groups, and their carried copper in 45-degree increments

- A saved pose binds by sub-block-scoped origin key before its ref string, each live part claimed once, so a renumber-recycled ref cannot mis-bind a pose
- A sole unmatched legacy hub pose migrates to a sole unmatched explicit rough anchor in the same sub-block scope
- A partial starred layout reports style/coverage but is invalid as a physics-objective reference
- The page blob's saved-layout rows are re-keyed onto the shown flatten, so a client Load applies poses by exact ref
- A saved pose whose part was deleted is dropped when a renumbered live part inherited its ref, so the genuine pose is not shadowed by a stale one
- The page blob's re-keyed rows drop a stale shadowing pose and its dimension, so the client's ref-keyed Load cannot pick the wrong one
- Merging duplicate layout rows keeps the starred row's name, so the ★ permalink still reproduces its board
- close_open_nets folds a redundant same-net via onto the barrel already there, and restores the board when the fold makes it worse
- The WASM DRC session via probe refuses a via crowding an existing same-net via, matching the checker's via-spacing rule
- Layout coverage counts poses the way a Load lands them, so colliding module-local origin keys cannot report a stale row as full
- A ?refine= re-solve is never adopted as the page's edit target, so the idle autosave cannot overwrite the named row with solver output
- The viewer's idle autosave pauses while unplaced parts remain, lifting when they are placed or explicitly saved
- The route_pcb scope resolver selects a group token's concrete nets and reports a whole-board route when no selector is given
- The route_pcb scope resolver rejects an unknown group or net token with an error and no scope
- An unscoped route_pcb call immediately after clear_routes routes the whole board and echoes scope "all"
- The route_pcb CLI tool can select a bounded retry tier, checkpoints routed copper before optional deferred DRC, and rejects unknown tiers
- route_pcb can learn hard path topology and reserve its proven transition sites from a completed saved reference layout while preserving authored wave/layer policy
- a reference-guided route reports how many nets received learned topology and how many required exact-copper fallback
- coordinate-scoped clear_routes removes one selected via without erasing the rest of a dense shared net
- The viewer Route scope parses a group into an incremental ScopedRoute that retains submitted copper for the unselected nets
- The route-body effort parser accepts both one-shot spellings and standard, while leaving each API surface to choose its missing-field default
- Route board is bounded on the server even for an already-open legacy page that omits effort, while an explicit API standard tier wins over that default
- One lowering builds the route options for a prepared body, so the blocking and live halves route it at the same scope and effort
- The page blob names which rung of the layout ladder the shown board came from, so the viewer can tell a persisted layout from an unsaved solve
- The page blob ships every single-ended controlled-impedance via's solved and minimum plane-antipad diameters, and the viewer's layer panels expose an Antipads overlay that draws both rings and prints the numbers
- The Antipads overlay measures each via's achieved plane opening from the drawn fills and flags a starved reference plane in red with the excess printed
- The scorebar offers Route plan on an unsaved solve only, running the shared route flow at the one-shot tier and marking the copper a non-persisted plan
- The PCB autorouter sidebar exposes one whole-board Route action; routing-wave scope remains an API concern rather than a routine UI choice
- The PNG and describe endpoints restore the shown layout's persisted routed copper against the current netlist when no fresh route is requested
- routableTally summarises copper connectivity into routed/total/open counts, excluding nets that need no copper
- The Routed UI count collapses per-pin micro-net connections onto unique logical net names while requiring every member connection to close
- the route-vision mask survives a run-length round trip across both long runs and maximal alternation
- the route-vision reach flood promotes only free space connected to the seed pad, leaving a walled-off pocket unreached
- two same-net pads whose lands touch are one island, and opposite-face SMD pads are not
- describe reports net-completion from the connectivity oracle, so neither a restored board's empty unrouted list nor a fresh route's optimistic count survives
- The add_tracks tool lowers a requested polyline into one persisted track segment per consecutive point pair
- The add_tracks tool defaults track width and via geometry to the net's declared net-class rule
- The add_tracks tool rejects an unknown net, an unknown copper layer, or a polyline shorter than two points without persisting anything
- The add_tracks result separates fab-blocking DRC errors from total violations
- The add_tracks rollback gate counts only geometry violations, never an open net, so an unfinished escape stub is kept
- The close_open_nets tool keeps a hop only when the connectivity oracle reports fewer islands on that net
- A fine gap rescue tries an exact outer-face escape before its inner-layer multi-via fallback after the ordinary raster drains
- A fine gap rescue on a plane-only four-layer stack uses the opposite outer face when its terminal face is blocked
- The close_open_nets global fine detour is reserved for a bounded number of long exhausted bridges in the last few open nets
- A fine gap raster may opt into a capped expansion multiplier without changing its allocated search region
- A final bridge gets deterministic board-edge corridor candidates derived from solved geometry
- The close_open_nets widened-rung policy arms its two capped rungs only once the board's residual is down to the last few nets, and only for a bounded number of hops
- A close_open_nets board with nothing open arms no widened rung
- The close_open_nets accept gate counts geometry DRC errors and never the net-open airwire it is closing
- The close_open_nets tool plans hops only for the open nets the caller named
- A close_open_nets stitch is never planned for the island its plane or pour already carries
- A close_open_nets stitch island whose first pad is memoised dead is retried from its next pad
- A close_open_nets round bridges a plane-carried net straight away when that round could plan it no stitch at all, so a call scoped to such a net is never a no-op
- A no-path bridge takes the fine corridor rescue only in the last few open nets, while a stitch always remains eligible
- the routability_preflight tool emits each finding's measurements and a per-rule tally
- routability_preflight carries an escape-contention finding's counts, cut and paste-ready suggestion
- the escape-contention suggestion parses back as an (assign-escapes …) route wave for the same nets
- The close_open_nets finishing pass orders its hops by the design's routing-plan wave order before hop length
- A DRC-rejected hop reports the violations it introduced, each with the rule, the shortfall, and the nets or pads it collided with
- A gap pass's rip filter is told which net is asking, so a caller can refuse copper the design ranks above it
- Hand-added copper that raises the error-severity DRC count is rolled back rather than persisted, unless the caller opts out
- A violation's reported nets name only copper that could be party to that rule — a drill finding never blames a surface pad
- A close_open_nets round routes its longest-span hops before its short ones so a cheap bridge cannot spend a long hop's only corridor
- A close_open_nets pass runs on past a round that kept nothing while a later round still has hops that one could not ask for
- The close_open_nets accept gate ratchets its DRC error ceiling down as the board cleans up, so errors it removes can never come back
- The close_open_nets accept gate rejects an independently-finished differential leg when it would increase coupling or skew warnings
- The close_open_nets accept gate spends a caller-declared DRC error budget on a hop that closes a net, and never spends one it was not given
- The placement_sensitivity probe set nudges a part both ways on each axis, and adds rotations only when asked
- The placement_sensitivity probe clamps its nudge to a window where a move is still a perturbation
- The placement_sensitivity flip classifier reports a net that changed connectivity verdict and ignores nets needing no copper
- The placement_sensitivity flip classifier reports nothing when the two runs are not the same netlist
- A placement_sensitivity probe scopes a part to its own nets plus the foreign copper threading its neighbourhood
- A placement_sensitivity probe pins every net outside its scope to the copper the saved layout drew
- A placement_sensitivity perturbation moves only the probed part and leaves every other pose alone
- A placement_sensitivity part name resolves by full ref-des, sub-block leaf, or stable origin name
- A placement_sensitivity verdict names the net and the move for a load-bearing part, and the window for a stable one
- A placement_sensitivity headline prefers a net the move breaks over one it only fixes, and a fixed net still marks the part load-bearing
- The placement_sensitivity result states its scope limit and names a field the payload actually carries
- The close_open_nets accept gate holds every net a hop's rip cascade touched to no worse than it found it, not only the first victim
- A close_open_nets transaction treats a previously whole pour net split by newly added copper as a repair victim even when no track was ripped
- A close_open_nets hop may only rip copper from a net that is currently whole, never from one the pass has still to close
- A close_open_nets round that finished a net drops the dead-end memo, because a whole net is copper the hops behind it may now rip
- A close_open_nets hop every rip tier refused is re-asked once on a finer raster with no rip at all, and that last rung's diagnosis is the reported one
- A refused close_open_nets hop escalates through corridor-bounded fine rasters, coarsest first
- Every close_open_nets failure carries the next thing worth trying, not just the verdict that rejected it
- A close_open_nets remedy never tells an already-scoped caller to narrow the job further
- Copper is de-duplicated on its way to the layout sidecar, so an appender that re-lays a segment cannot persist it twice
- A fresh route's facts report the router's own pre-gate claim only when it exceeded what the connectivity oracle confirmed
- The close_open_nets pass reads its board back as live copper with an index map, so a rip reported against it lands on the board's own tracks
- The close_open_nets wholesale re-route never takes plane, pour, ground, RF, or diff-pair copper off the board
- The close_open_nets wholesale re-route displaces only the whole nets whose copper crosses a still-open net's island-joining corridor
- The close_open_nets wholesale re-route asks for the seed's own hops before the hops of the copper it displaced
- The close_open_nets wholesale re-route holds the DRC ceiling at the pre-phase count so the copper it stripped may go back on
- The close_open_nets wholesale re-route restores the board byte-for-byte unless the set of open nets strictly shrank
- The close_open_nets wholesale re-route leaves a seed still in more islands than its transaction could close alone, and strips nothing for it
- The close_open_nets wholesale re-route retries a failed seed once on a finer gap grid, even when nothing was displaceable at the base pitch
- The close_open_nets wholesale re-route restores a plane-carried net by stitching it into its own pour before it will ask for a surface bridge
- The close_open_nets result names the nets a cheap-restore transaction vacated, what became of each, and the corridor copper it refused
- The close_open_nets result reports the round loop's failures apart from the wholesale phase's own, and marks the ones whose transaction was rolled back
- The close_open_nets joint tier clusters only the still-open nets that provably contend for the same copper
- A close_open_nets joint transaction vacates the union of its seeds' corridors, which no sequence of single-seed transactions can reach
- A close_open_nets joint transaction is re-tried with its seeds first, contending, and last, because a maze is first-claim-wins
- The close_open_nets joint tier closes a cluster of contending nets in one transaction and puts the copper it displaced back
- The close_open_nets joint tier is deterministic: the same board yields the same cluster, the same transaction and the same copper
- A refused close_open_nets joint transaction restores the board byte-for-byte, dead-end memo included
- The close_open_nets joint tier's cluster and attempt caps bound the whole call, not each cluster separately
- Both rip-and-re-route tiers nominate through one shared seam, so the post-route tier sees exactly what the in-route tier's corridor sweep sees
- route_order_search is a registered mutation CLI tool because it records the trials it ran
- a recorded route_order_search trial names the ordering it tried, its score, and the scope it was measured under
- a small route_order_search cluster is searched exhaustively, the authored order first
- a route_order_search cluster too big to enumerate is seeded from the blocker diagnoses and the pours
- route_order_search ranks trials by oracle connectivity first and DRC errors only as a tiebreak
- route_order_search recommends the smallest plan edit among orderings that measured the same board
- a route_order_search ordering re-deals only the cluster's own authored priority slots
- a route_order_search whose trials all measure identically under cluster scope says so rather than reporting no effect
- route_order_search derives its cluster from the nets the stuck diagnoses name as blocking each other
- The shown layout's copper carries its pour zones, so a rail poured rather than traced counts as connected
- openNets reports each unconnected net's pads with their coordinates and copper island
- openNetsAmong builds open-net detail only for requested exact names while retaining placement order
- closingGaps chains the islands nearest-first, emitting one hop per island beyond the first
- The describe facts emit the full pad obstacle table only when pads are requested
- every option a PCB read handler honours is declared in that tool's strict input schema
- A placement-selection PCB read honours the seed flags and ignores the route and pad-table flags
- a tool property that documents a comma-separated string declares string among its schema types
- cropnet= computes the viewport as a net set's pad + copper bbox plus a margin, case-insensitively and excluding other nets' copper
- Library previews edit footprint courtyards with PCB-style controls
- The footprint editor uses the shared shape-sketch tools for custom pad polygons, polygon courtyards, and closed silkscreen/fabrication artwork, while retaining conventional physical footprint forms for export and placement
- The PCB editor's sidebar footprint button opens the part's library card (datasheet links, footprint editor, 3D-model drag-in and alignment) instead of only the courtyard modal
- Footprint preview reports exact geometry bounds separately from its padded SVG viewport
- Footprint preview carries a pad's own (pos X Y ROT) rotation so the library SVG draws it turned
- A saved layout round-trips a polygon board outline; the rect fields are re-derived as its bbox
- a deferred PCB load retains an adopted fabrication-ID position and refreshes its derived text before Update persists it
- applyShownOutline folds a saved layout's drawn outline (rect or polygon) onto the placement, and is a no-op for a layout without one
- outlineForBody prefers a submitted outline, else the blessed drawn outline (the default layout's first, else the first layout carrying one), else authored-only
- the outline write paths reject a self-intersecting or zero-area polygon but accept a concave one
- the /pcb-layout viewer reshapes a drawn outline via vertex drag, edge slide, insert, and delete
- Inner-layer copper (l ≥ 2) round-trips the sidecar; legacy entries without an l stay top copper
- a saved layout round-trips its user-drawn copper-pour zones through the sidecar
- one custom pour applied to multiple selected layers expands into an independent fill and routing source on every layer
- the custom-pour dialog independently selects multiple copper layers and persists the complete selection through create, edit, and undo
- a filled inner-layer user zone emits a layer-tagged zone_fill with no side and preserves priority through both routing adapters
- saved/imported keepout zones feed the generated-silkscreen exclusion geometry on both board faces
- the PCB viewer uses the same above-first, fixed-horizontal collision search for generated test-point labels
- the PCB blob and pour-refill compute carved zone_fills for each filled netted outer-layer user zone
- refill pours returns visible fill geometry before independently refreshed DRC/connectivity work
- Stamped module copper keeps its group tag through the sidecar so rigid-group moves carry it
- Stamped module copper maps its net names onto the parent design via the origin-key bridge, slug-prefixing private nets
- Stamped copper adopts destination net-class geometry
- Restamping a sub-circuit preserves its anchor's board side and rigidly mirrors its parts and stamped copper onto that side
- Restamping a sub-circuit replaces only that group's stamped copper and preserves board-level tracks, vias, and RF paths on the same nets
- Stamp fetches the current module layout when clicked, so a sub-circuit edit in another tab applies without reloading a board and without discarding its unsaved work
- Stamp defaults to the sub-circuit's starred layout, while its adjacent picker can stamp any compatible named saved layout without changing the star
- Saving a rigid sub-circuit from its parent PCB is the inverse of Stamp: poses, group-owned copper, and local connected traces/vias return to module coordinates, including a board-side mirror; a copper run reaching any component outside the sub-circuit remains board-owned
- Save to sub-circuit captures untagged local connected traces and vias while excluding a connected run that reaches any component outside the sub-circuit
- A live Stamp refresh keeps every stampable sub-circuit's palette action visible when the fresh grid placement uses different ref-des assignments from the open board
- Selecting a rigid sub-circuit exposes its Stamp and layout-page actions directly in Properties
- The PCB Sub-circuits palette and Properties expose Save to sub-circuit, which fetches a fresh target revision before capturing that group's poses, stamped copper, and locally connected traces/vias as a new layout
- the PCB hand router defaults to the active net class while the sidebar keeps its resolved geometry controls hidden
- the PCB hand router previews an authored pad neck at its tapered physical width, checks wide/short-pad launches against their exact swept regions, and submits compact handles plus those regions to the synchronous DRC gate
- The /pcb-layout Route panel presents Route board, Stop, status, and live replay without cached-load, interactive-session, scope, or advanced-routing controls
- A completed Route board run persists its applied copper to the active layout, or creates the conventional first `layout` snapshot; Route plan remains temporary
- The PCB replay client streams the live-route endpoint into the timeline player, follows the head, and reattaches to a running job through the overlay seam
- The PCB live-route Stop action freezes the displayed elapsed time immediately while cooperative cancellation finishes, and resumes live progress if the cancellation request fails
- The PCB autorouter client offers full local-then-global and subcircuits-only stages, and the local stage never falls back to the blocking whole-board endpoint
- A subcircuit's PCB autorouter offers a Power plane toggle for implicit and authored stackups: on keeps supply planes, off routes supplies as ordinary copper while retaining ground planes; the choice is saved in design source and reused by routing, DRC, reload, and fabrication outputs
- The PCB board editor publishes the replay overlay, copper-adopt, and live-route result seams the replay client drives
- The PCB thermal overlay paints the cached heat field over the read-only board through the overlay seam
- The interactive route-session client bundles the stuck-net, corridor, and frontier surfaces
- Every /pcb-layout client reads the page's lexical PCB blob directly, so no board read is gated on the undefined window.PCB
- The PCB blob carries the resolved board design-rule scalars for a byte-identical client DRC
- PCB blobs carry fixed perimeter keepout geometry together with its clearance, blocked feature families, and allowed nets
- PCB blobs carry each authored board keepout region as a solid named rectangle beside the derived perimeter band
- the pcb-describe board facts list every authored keepout region in world millimetres with its side, blocked families, allowed nets and reason
- The PCB blob emits each pad's rotation, roundrect ratio, oval slot, and through-hole flag
- The layout sidecar is snapshotted into history and listed newest-first
- Layout snapshots are pruned to the newest retention cap
- Source-snapshot listing skips the reserved layouts subdir
- The layout sidecar carries an optimistic-concurrency rev, emitted only when non-zero
- readLayoutRev reads the sidecar rev (0 for a legacy file), and a save stamps disk_rev+1
- A page render whose layout sidecar was saved mid-render is not cached
- A CLI layout mutation snapshots the sidecar to history and bumps the rev like a viewer Save
- A CLI layout mutation refreshes the auto-layout cache poses so a default read reflects the write
- A no-arg CLI PCB read defaults rough off to render the starred layout verbatim, not a re-solve
- pcb-describe answers an unknown design or sub-block distinctly from an internal failure
- describeDesign reports facts for a design composed only of sub-blocks and rejects an unknown name
- pcb-describe stuck diagnostics name the rippable equal-priority net boxing a congested net
- a stuck-net blocker names its copper layer through the board's own stackup, so a declared inner plane does not shift every inner name by one
- a stuck net whose routing order comes from a plan wave is offered the wave-reorder lever, never the net-class priority form that cannot move it
- pcb-describe stuck diagnostics flag a sealed pad as escape-blocked with an escape remedy
- a stuck net with an open sub-grid corridor and no rippable copper yields a router-code remedy
- stuck-net blocker attribution crops to each net's own pad corridor, so nets with disjoint pads get disjoint attribution windows
- stuck-net blocker shares are per-net-normalized and a goal-directed-probe fallback blocker is marked with share 0
- stuck-net diagnosis is hard-capped so a heavily-failed board cannot stall the route response
- the routed facts serialize a stuck block with per-net failure mode, blockers, and ranked DSL remedies
- the routed facts block carries the deterministic routing score and its formula version
- Stuck-net diagnostics serialize through one shared writer so the facts JSON and the viewer route response agree
- the CDT probe forks a copper-blocked isolation-routable net to congestion, an isolation-blocked net to a geometry limit, and a both-routable net to a maze gap
- the CDT congestion verdict upgrades a code-target or unclassified stuck mode to order-congestion while leaving a genuine order mode intact
- the CDT probe verdict leads the remedy list with a dsl reorder for congestion and a code fix for a geometry limit or maze gap
- the CDT probe's window obstacle count includes a track or via whose box overlaps the window and excludes one clear of it
- the CDT probe reads a with-copper corridor as blocked when the isolation path runs within clearance of a routed track
- the shared stuck writer serializes the CDT feasibility probe's isolation and with-copper verdicts, and null when a net was unprobed
- The /pcb-layout accordion carries a Stuck-nets chip and its diagnostics dock
- The Stuck-nets panel client renders the Route response's stuck diagnostics with copyable DSL remedies
- The /pcb-layout page ships a self-contained WebGPU board renderer, on by default where the browser exposes WebGPU and inert under the ?gpu=0 opt-out
- Assembly requires WebGPU for generated Gerber/Excellon artwork; an unavailable adapter, initialization/render failure, device loss, or Assembly ?gpu=0 displays a blocking requirement message instead of invoking a Canvas manufacturing renderer
- Custom pads use the exact Canvas2D polygon path instead of the WebGPU triangle fan
- The PCB status bar carries a live renderer chip that reads GPU or 2D and follows device loss
- Hovering visible routed copper, vias, pours, or unrouted airwires identifies their net in the PCB status bar while pad hover retains its component context
- M opens a move-by-distance dialog for mixed footprints/copper or selected outline geometry (X and/or Y in the current units, one undo step) and D arms the ruler/measure tool
- With one footprint selected, D authors a persistent driving dimension from that footprint origin to a perpendicular straight outline edge
- Double-clicking a saved PCB driving dimension line or value reopens its exact-distance editor
- The ruler drag keeps its live measurement across redraws: the drawn overlay clears per frame but the drag's start/end state survives until the gesture ends
- The overscan pan-buffer fingerprint reads the clearance-halo toggle from view state instead of a removed DOM checkbox, so a pan never throws
- PCB pad-number labels remain capped at 13 screen pixels regardless of pad geometry or zoom
- Front-only and Back-only PCB presets hide opposite-face SMD pad numbers and layer-scoped DRC markers while retaining through-hole labels and layerless findings
- Front-only and Back-only PCB presets hide opposite-face sub-circuit bounding boxes and remove their empty-area hit targets
- Front-only and Back-only PCB views exclude opposite-face footprints from hover, direct and exact-pad clicks, marquee and select-all selection, and every part/group transform
- WebGPU pan and zoom frames replay a cached render bundle until geometry, layer order, or visible-pour membership changes
- Swept variable-width RF paths remain on WebGPU as exact triangulated stencil unions, while their hidden centreline tracks are omitted from the GPU copper stream and a hidden copper layer cannot leak its taper through a visible layer's stencil cover
- The deterministic PCB-editor zoom gate measures fit-to-8×-to-fit paints in both directions, covers the DPR-2 Canvas fallback, asserts an RF-heavy Barracuda workload stays on WebGPU, and is required metadata on every deployable release candidate
- Release preparation waits for a stable quiet-host window before PCB-editor timing, retries timing-budget misses after contention clears, and never retries renderer or infrastructure failures
- The WebGPU renderer drops a track whose layer the board does not have instead of repainting it on F.Cu
- A new copper pour defaults to the active copper layer and its picker lists every routable layer
- Custom copper pours and board outlines use one versioned shape-sketch engine: a pour exposes the outline editor's rectangle/line creation, vertex and edge editing, dimensions, geometric constraints, arc/line conversion, fillet removal/addition, chamfer, offset, mirror, selection deletion and undo/redo; its native sketch round-trips while fill, routing, DRC and export consume the compiled polygon
- Custom copper keepouts use the same copper-area picker and the same full shape-sketch palette as pours; generated rule/perimeter keepouts remain derived and read-only
- The read-only assembly review opens on an outer board face even when the editor was left on an inner layer
- The clearance-halo toggle persists with the rest of the PCB view state and both of its surfaces read that one value
- A layout save refuses a copper pour on a layer this board has not got while keeping the spellings a KiCad import carries
- The opt-in PCB frame benchmark briefly dwells at fit, maximum zoom, seek, and pan turnarounds without mixing those pauses into movement percentiles
- The opt-in PCB frame benchmark waits for the page's deferred DRC, RF retrofit and pour round-trips before measuring, so the repaint each answer triggers is never recorded as a camera frame
- The /pcb-layout left dock tabs Properties, Autorouter, DRC, and Sub-circuits, showing one pane at a time
- The /pcb-layout DRC pane docks the violations list under a previous/next step-through
- Net-open DRC reporting groups every island gap by full net name and counts each open net once while retaining expandable per-gap details
- The DRC summary's open-net count reveals and locates the nearest missing connection instead of acting as inert text
- Net-open DRC rows and their expanded missing connections sort by shortest gap first
- Selecting a grouped net-open row or one of its gaps frames and draws a net-coloured line between that finding's nearest island probes
- The selected net-open bridge uses a screen-space hairline and hollow endpoint rings that shrink for short gaps
- Net-open DRC findings draw their exact missing bridge and endpoint rings, remain board-clickable, and retain the grouped DRC list
- The /pcb-layout accordion carries no optimizer tuning or score-reweigh panel
- The /pcb-layout saved-version navigator sits inside Autorouter, immediately after the route controls
- ?layout=<name> shows that saved layout verbatim, outranking the starred default, while ?refine= re-solves from it
- A ?layout= name matching no saved layout is a 404 that lists the names that do exist
- A /pcb-layout design that exists but fails to parse or evaluate returns a compiler-style build-error page with file, line, column, failing source line/caret when available, and the evaluator message; only a genuinely unknown design/module name returns the not-found message
- The fab-readiness report and the fab package endpoints resolve ?layout=<name> to that named saved row and 404 an unknown name, never silently reporting a different board
- Every block keeps many named layouts, and the saved-layouts panel links each one by its own ?layout= permalink
- The /pcb-layout saved-version sidebar renames and deletes any selected named layout, rejecting duplicate names and stale revisions
- A block's first-ever saved layout is starred, and a later save never takes the star from the user's pick
- A named save always lands, and two named layouts sharing a placement are never merged, so routings of one board survive as separate candidates
- A layout sidecar past a megabyte still reads back in full, and one that cannot be read or parsed is reported instead of passing as no layouts
- The page blob inlines copper for the layout it shows and marks the other routed rows as server-side, so page weight does not grow with the candidates kept
- The viewer adopts the shown layout as its edit target and keeps the address bar on that layout's permalink
- The PCB viewer keeps net colours permanently on and omits the Nets tab, Ratsnest control, and Placement guides control
- DRC error and warning markers have independent persisted visibility controls in the PCB Appearance objects list
- Board text and generated annotations live on their physical F./B.Silkscreen layers without an extra Appearance row or per-hover geometry rebuild
- The /pcb-layout Appearance dock provides one generic Keepouts layer for fixed typed regions and clean active-copper net-class halos without overlap-darkened fills or decorative pad-escape rings
- PCB edits autosave after idle and retain crash drafts until that save succeeds
- the PCB blob ships one layer-table row per physical copper layer and the viewer derives its routable list from it
- every copper geometry in the PCB blob names its layer with one key, a KiCad layer name on a fill and a name array on a keepout region
- a saved layout's track layer is validated against the board's routable layers on read, and out-of-range copper is kept and reported
- a saved via may declare its layer span, which round-trips through the sidecar and add_tracks while routing still treats every via as through
- A per-layer DRC violation carries its copper layer on the wire and in its id, so two defects at one point on different layers stay distinct
- The WASM DRC bridge is given the board's copper stack, so the client engine's layer arithmetic matches the server's on a declared stackup
- The WASM DRC credits an exact same-net fill on a routable internal power layer as a via contact, while an antipad hole remains disconnected
- PCB blob layer rows take their names, colours and plane nets from the shared layer table
- The PCB blob names the fixed copper, silkscreen, outline and courtyard layers beside its layer table, so the browser spells no KiCad layer of its own
- Inner-layer copper paints one colour across the PCB blob, the page legend and the PNG
- the PCB PNG's object colours are the shared board theme's rather than re-typed literals, and a routed track takes its layer table row's colour
- the PCB viewer and replay clients derive their palettes from the blob theme, keeping their literals only as a no-blob fallback
- PCB design settings expose authored stackup, rules, net classes, and route plan provenance
- The PCB blob's plan lists the resolved placement and routing waves with member names and the synthesized flag
- The PCB pad aligner snaps exact pad centers and moves a source sub-circuit as one owner
- The PCB pad aligner moves only the source footprint when both selected pads belong to the same sub-circuit, while an outside target still moves the source sub-circuit as one owner
- Editable sub-circuit PCB embeds expose the pad aligner's Same X and Same Y controls
- physical board navigation exposes stable 3D and a read-only assembly workspace
- the system CAD workspace opens as a solved 2D heat-field map with a separate 3D assembly/CAD view, shows imported PCBs as reference geometry without inferring an enclosure, imports legacy board-attached fans as independently persisted system fans that can be added, removed, positioned and configured, provides clickable XY/XZ/YZ origin datum planes, locks active sketch editing to a flat orthographic plane with the PCB outline editor's selection/constraint/modify palette, creates preview or STEP/STL solids only from explicit enabled extrusions while ignoring legacy generated-enclosure documents, and content-hashes its first-party asset URLs so fresh HTML cannot execute a stale control schema
- the PCB 3D viewer extrudes the physical outline at the authored thickness and mounts bottom-side footprints beneath it
- the PCB 3D viewer places its visible axis origin at the PCB outline bounding-box centre in X/Y and the board thickness mid-plane in Z, and its camera orbits that same datum
- the PCB 3D viewer paints its base board before component previews finish, parses vendor STEP models outside the UI thread, renders only after scene or camera changes, and lowers raster density while interacting on a software WebGL renderer
- the footprint 3D alignment viewer renders only after scene or camera changes and temporarily lowers raster density during camera gestures
- the PCB 3D viewer asks the server for a self-contained millimetre-based AP242 assembly: each unique library STEP entity graph is embedded once without tessellation and reused through rigid component occurrences, the board outline/thickness/mechanical holes become one green analytic manifold B-rep rather than a faceted mesh, native board-outline arcs become circular edge curves and cylindrical side faces rather than chorded corner facets, and an unchecked heatsink is omitted from the assembly
- the PCB STEP assembly places its origin at the PCB outline bounding-box centre in X/Y and the board thickness mid-plane in Z, translating component occurrences and generated solids by the same offset
- the PCB STEP download name ends in `_ID_XXXXXXXX.step` using the exact eight-hex fabrication identity printed on that PCB
- the PCB 3D viewer composites each face's outer copper, soldermask, and silkscreen—including generated sub-circuit, test-point, and pin-1 artwork—into one non-overlapping visible canvas cap; the regular STEP export omits that raster artwork instead of turning it into selectable geometry, and only mechanical drills strictly larger than 1 mm are cut through the board
- every board renderer paints exposed pad copper above routed traces, so a normally masked trace entering a land cannot visually coat that component pad with solder mask
- a via-in-pad keeps its drilled centre visible after component pads paint above routed copper
- exposed RF copper on both board faces uses the same swept taper polygons in Assembly and the PCB 3D viewer
- the retired /pcb-route-lab page 302-redirects to the /pcb-layout page for the same design
- assembly model bodies load from persistent calibrated PNGs and render STEP only to populate a missing or stale filesystem cache entry
- the assembly model-picture cache invalidates when its STEP file or saved alignment changes
- A ?sub= scope is accepted only when it is spelled like a sub-block slug, so it can never build a path outside the design directory
- A percent-encoded traversal in ?sub= resolves to no sub-block rather than a sub-block scope
- the live scene graph is answered only for the design it was pushed for
- a live scene-graph read copies the bytes so a later push cannot free the response body
- assembly review groups sourceable parts by normalized MPN and records DNP placements
- assembly applies the persisted BOM through stable source identity before grouping, so inserting a newly auto-numbered part cannot shift MPNs onto unrelated refdes
- assembly BOM rows sort by visible quantity and show top, bottom, or both placement badges
- assembly BOM rows expose stable kit indices, allow their text to be copied, and mark the exact refdes picked on the board
- assembly and board labels show globally unique leaf refdes without internal sub-block path prefixes
- assembly/debug board focus covers direct copper picks, refs, tracks, vias, pours, zones, and plane layers while excluding keepouts from connectivity
- assembly component and pad picks reveal and highlight the owning component in the active sidebar, while placement selection preserves the board viewport
- assembly component hit-testing only considers placements on the board face currently being viewed
- an assembly component click scopes same-ref highlighting to placements on the board face currently being viewed
- assembly part and BOM selections highlight only placements on the currently viewed board face and retarget when that face is switched
- assembly review hides scores, DRC, and clearance, loads 3D models only on request, preserves board appearance when component picks update the sidebar, and retains middle-pan and scene-only orientation
- assembly review derives bare via copper only by clipping it through mask-opening geometry, including the exact authored-width board-edge band
- Before opt-in CAM Review supplies its exact profile, Assembly preserves the saved outline's native arcs instead of joining their endpoints as chamfers
- assembly sidebar selections sit beside their row without scrolling a list the row is already visible in, and omit the copper focus report
- assembly parts, BOM lines, and selections link uploaded local datasheets and HTTP(S) component datasheet URLs
- the assembly workspace opens on its parts list, leaving the guide panel one tab click or a deep link away
- assembly searches keyboard-highlight the first match, wrap through results with arrow keys, and activate the current row with Enter
- assembly refdes omit connection tables, repeat pad picks select nets, and review copper picks omit reports
- assembly selected components render visible pad 1 in red for placement orientation
- assembly uses one unified part and board-object search, omits component connection blocks, and reveals board-picked test points with their connected net
- assembly clears its current selection when Escape is pressed or the physical review is clicked outside the board outline
- assembly rework guides bind stable component UUID, footprint-pad, and net targets to exact read-only board focus and retain board context when centering component and pad targets
- assembly discovers every <design>-<slug>.rework.md companion beside the legacy guide, orders the legacy file first and the rest by filename, and never adopts another design's guide
- a rework guide whose slug is itself a design in the same directory stays that design's own legacy guide and is never adopted by its name-prefixed neighbour
- the schematic page serves an embedded pane variant that drops the navbar, page header, and sidebar
- the schematic layout's deep semantic-zoom layer reuses existing inset SVGs through references instead of cloning their full DOM during a wheel gesture
- the schematic page HTML cache keys the embedded pane apart from the full page
- each assembly rework guide takes its title from its first Markdown H1 and falls back to its filename slug
- the assembly guide panel opens as a clickable list of guide titles, renders one guide at a time, and returns to that list from any guide
- PCB trace selection preserves layer color and component drags ignore click jitter
- PCB design-rule settings illustrate every board rule with an accessible SVG
- The DRC policy settings section edits each check's error, warning, or ignored action in grouped rows and resets them to defaults
- The DRC policy drawer sections its checks from one server-shipped grouping table that covers every violation kind exactly once
- PCB Layers shows plane-only rows and B toggles the persisted focused outer layer, including while the trace-drawing tool is armed or has a live route head
- every physical copper layer is selectable and a plane-only view uses its computed fill
- Drilled via and through-hole pad bores remain board-coloured on every copper view, including generated RF fence sites and the far side of opaque pours
- selecting a routable copper layer reveals it and gives custom pour fills on that active layer a clear baseline highlight
- custom copper-pour fills, boundaries, and labels use their net colour in both the 2D and WebGPU renderers
- the /pcb-layout action toolbar carries a first-class pour-refill button gated to designs that declare outer-layer copper pours
- the toolbar pour button flags a stale indicator after board edits and disables during replay
- the /pcb-layout toolbar carries a custom copper-pour tool that draws a polygon zone, picks its net and layer, persists it with the layout, and refills its fill
- The PCB Route request always carries the current custom copper pours so the autorouter can terminate pour nets through vias
- The route_pcb CLI tool preserves custom copper pours and passes them to the autorouter for whole-board and scoped routes
- The route_pcb CLI tool counts DRC against the shown custom pours through the direct pour-aware checker result
- a pour with an interior foreign feature ships its antipad holes and the viewer fills them even-odd
- assembly copper pours retain even-odd antipad holes around foreign traces, vias, and pads
- assembly review uses a fixed translucent copper wash so the PCB editor's persisted pour-opacity slider cannot obscure soldermask
- the PCB PNG paints declared outer pours as computed fill contours with antipad holes carved by the routed copper the image draws
- footprint silk paints above routed copper on the board PNG
- the viewer strokes footprint silk as one pass above the copper pass, and under the assembly review's package bodies
- one canonical stage list names the board paint order for every renderer
- the viewer's paint stages mirror the canonical order name for name
- the board PNG washes and names each authored board keepout region, leaving the rest of the board bare
- the board PNG paints the canonical stages in order
- the board PNG fills inner planes from the same pour engine the fabrication outputs use
- the board PNG strokes a routed arc as a curve and drops the chords it owns
- RF-only saved paths paint the same butt-ended swept polygons as Gerber instead of round-capped conservative DRC chords
- the board PNG paints bottom-side parts under top-side parts
- A DRC violation carries a stable 4-hex id emitted by the shared JSON writer
- The whole-rail power-width warning ships its own kind word and the power-solve status that forced it
- The shared DRC JSON writer emits each violation's named parties and omits the sides the checker could not name
- The WASM DRC bridge parses board-state JSON to the same violations as a direct drc.check run
- Both client DRC bridges read the blob's design-rule object through one shared reader, so the stateless check and the session probe resolve identical board rules
- A design-rule key absent from the page blob falls back to its built-in default, so a dropped key cannot read as zero
- The WASM DRC bridge returns an error object on malformed input instead of trapping
- The WASM DRC bridge treats every board-state field as optional, defaulting to a clean board
- The WASM DRC bridge resolves a diffpairs entry like a direct drc.check
- The WASM DRC bridge carries a net class's keepout halo and the declared plane nets, so the client flags the same intrusions
- The WASM DRC bridge applies the same net-gated keepout escape as the server, excusing only a net with its own pad in the zone
- The WASM DRC bridge carries each net's class identity, so the client waives the keepout halo between one class's own members exactly as the server does
- The WASM DRC bridge carries typed generic perimeter keepouts and their allowed nets
- The WASM DRC bridge marshals no rail current, so the client engine never rasters the board's planes for a power-branch width verdict
- The /pcb-layout viewer runs the WASM DRC in a worker with a server fallback
- The WASM DRC session load returns the board's net table for probe indexing
- The WASM DRC session segment probe matches a full drc.check for new routing-class violations
- The WASM DRC session via probe matches a full drc.check for new routing-class violations
- The WASM DRC session segment clip returns the largest violation-free prefix fraction
- Loading a new board replaces the WASM DRC session so probes answer against the current state
- A WASM DRC probe with no loaded session returns the no-session sentinel
- Per-design DRC rule overrides retag or drop violations before every reporting surface
- The per-design DRC rule sidecar is parsed once per file state, and an edited or deleted sidecar is honoured on the very next check
- The DRC policy table advertises the same built-in severity the checker emits, differential-pair rules included
- A DRC check for copper outside any project design still layers the net-open connectivity rule onto the built-in severities
- The /pcb-layout Properties dock hosts the inspector with segment editing and DRC rule settings
- Clicking a selected PCB part's component name or resolved MPN in Properties copies that exact identifier to the clipboard and reports success
- Selecting a DRC violation in Properties explains the check, distinguishes the concrete occurrence, and reuses the Design Settings rule illustration when that check has one
- Segment drags preserve neighbouring trace support lines: compatible neighbours only stretch or shrink, while collinear runs, arcs, and ambiguous junctions remain anchored behind a connector
- Dragging a native trace fillet re-solves its circle against both neighbouring support lines so both joins remain tangent
- The hand-route head dodges or clips at clearance obstacles instead of drawing violating copper
- Moving a placed component leaves its connected traces in place instead of deleting them
- Dragging or rotating a marquee selection carries the tracks and vias the band caught
- A resolved board click retains the exact-object stack so Tab or Alt-click can cycle priority losers with the hold picker's preview and unified selection apply path
- Marquee and Select All expose transient count chips that can drop one selection kind or Alt-keep only footprints, tracks, vias, or combined copper without changing the global Objects filter
- Double-clicking routed copper or pressing J under the pointer selects its endpoint/via-connected run, and repeating expands through the shared mixed-selection commit to every track and via on the net
- Ctrl/Cmd-click toggles footprints, rigid sub-circuits, tracks, and vias into one multi-selection without a marquee drag
- Holding Ctrl/Cmd after an ordinary first click retains that part, sub-circuit, track, or via when the next item joins the multi-selection
- Ctrl/Cmd+C and Ctrl/Cmd+V copy and paste a selected trace, via, or mixed copper selection as one undoable edit with fresh identities
- L locks or unlocks every footprint in an explicit multi-selection without requiring a hovered member
- Two selected connected trace segments expose a right-click Fillet command that applies an exact native-arc radius through the normal copper edit gates
- F rigidly mirrors a selected sub-circuit or marquee group to the opposite board side around one stable anchor, preserving relative positions, orientations, traces, vias, and copper pours in one undo
- A multi-part drag or rotate carries copper on nets private to the moving parts and leaves shared-net copper in place
- Align, distribute, and pad-align carry each entity's own copper by that entity's own delta
- A press on marquee-selected copper drags the whole selection instead of sliding that one segment
- The Objects tab offers a selection filter that skips unchecked object types when clicking
- The Appearance panel separates Layers and Objects tabs, listing real fabrication layers in top-to-bottom physical order and the feature overlays under Objects
- The /pcb-layout Appearance dock and the embed layers popover render their rows from one shared builder, so a layer is named, ordered and wired identically in both
- Footprint silkscreen and courtyards are visible per board side, and a hidden courtyard layer never hides a selected part's outline
- Ordinary PCB-editor courtyard outlines use a 0.25-pixel stroke, standalone-part hover and selection outlines stay emphasized, and rigid sub-circuit hover highlights only the group bounding box
- Every PCB layer's visibility is keyed by its canonical layer name and a stored legacy view state migrates onto those names once
- A PCB plane layer carries its own visibility eye, still renders when it is not the viewed row, and keeps vias drawn when it is the only visible copper
- The Appearance Layers tab offers All, Front, Back and Copper-only presets that rewrite the layer visibility map in one click
- The Objects filter disables sub-circuit hits so overlapping traces remain selectable
- The Objects filter picks pours and keepouts only at their visible edges and offers enable-all and disable-all actions
- Routing toward a same-net pad snaps the whole approach onto the pad centreline
- A click that magnetically snaps to a same-net pad or existing trace endpoint finishes the manual trace only after the path reaches that endpoint.
- While hand-routing, one faded dashed ratsnest line follows the legal preview endpoint to the closest unresolved same-net pad, trace body, via, or filled-pour point outside the launch island, including when routing resumes from existing copper.
- While hand-routing a single trace or coupled differential pair, the scoped autorouter preserves the fixed manual prefix, previews only its proposed remainder as faded dashed tracks and vias, and Enter commits that proposal as one undoable trace completion; Enter never substitutes a manual partial finish when no proposal is ready, while double-click remains the explicit manual finish action.
- hand-routing starts and continues only from pads and traces on the active copper layer, so opposite-face lands cannot steal a route click
- The hand-route tool lays both legs of a differential pair together with mitered offset corners
- The hand-route differential pair holds its class gap through the shared run, then fans each leg to its own outstanding destination when the pair terminates on separate series passives
- The auto-commit author is the ward user, falling back to the dev-admin identity
- The auto-commit parses porcelain status into a dirty-path set including a rename's source
- The auto-commit always excludes history snapshots and backup artifacts
- The auto-commit stages only new-or-changed paths, never pre-existing loose work
- The auto-commit message names the tool and touched paths on one greppable line
- A per-mutation auto-commit records only touched paths as the ward user, sparing loose work
- The auto-commit is a silent no-op when the project dir is not a git repository
- Browser Component Search Engine imports auto-commit the combined generated library changes
- the pcb-describe JSON carries a progress block and mirrors stale-plan warnings into lint
- the pcb-describe JSON carries a match_groups block with each member's routed length, and omits it when no group is declared
- the pcb-describe loop facts mark each decoupling target authored or defaulted and name the declared hub pad
- the pcb-describe bindings array names each (near …) adjacency with its gap and reports an unresolved one with its cause
- the /pcb-layout board blob carries a decoupling loop's declared hub pad and omits it when the solver defaulted
- the placement-guide power line is dashed for a defaulted decoupling target and solid for an authored one
- home design cards lazily show the same six-stage PCB completion tracker as the layout editor
- home design cards put issue counts only in stage one and omit legacy issue/section chips
- get_layout_progress is a registered read-only CLI tool
- review_audit is a registered read-only CLI tool
- route_experiment is a registered read-only CLI tool
- preview_escape_assignment is a registered read-only CLI tool
- preview_escape_assignment rejects a request naming fewer than two nets
- preview_escape_assignment renders its assignment as a pasteable per-net waypoint plan
- preview_escape_assignment reports the nets its assignment refused and why
- a well-formed route_experiment plan override parses into a route plan spec
- a malformed route_experiment plan override is rejected with a structured parse error
- a route_experiment plan override that is a non-plan form is rejected
- a route_experiment result names the oracle's still-open nets and the pad-to-pad hops that would close them
- a route_experiment on a fully connected board emits an empty unrouted list and no open_nets block
- the route_experiment effort argument selects the router retry tier and rejects any other word
- record_route_trial then list_route_trials round-trips a recorded routing trial
- route-trial ids stay monotonic and are never reused after a remove
- recording past the route-trial retention cap drops the oldest trial
- recording a route trial on an unknown design is rejected
- a batch of search trials appends in one write, continuing the same id sequence and cap
- an empty search batch writes nothing at all
- a trial sidecar written before the source field existed still loads, as agent-recorded rows
- record_route_trial is a registered mutation CLI tool
- list_route_trials is a registered read-only CLI tool
- remove_route_trial is a registered mutation CLI tool
- a sub-block needs a layout when the placement carries parts under its slug prefix
- a module counts as starred when its saved layouts include a default snapshot with parts
- the progress ladder maps the fab-gate net connectivity in placement-net order
- the progress plan context records each section's declared instance ref-des
- module source names become progress PCB targets while file sources remain read-only
- An RF fence via keeps the name of the net it flanks through the sidecar and the page blob, stitching ground while belonging to that trace
- A moved RF part drops its trace's fence with its copper, because a fence via is invalidated by the net it flanks and not by the ground net it stitches
- Two vias in the same hole on the same net are one via whatever their provenance tags say, and the first row is the one kept
- POST /api/pcb-fence/:name lays (and regenerates) the RF ground via fence onto a saved layout's persisted copper — every declared (fence …) or (max-freq …) RF trace — and reports what it placed and skipped
- The unfiltered fence endpoint also persists a 5 mm board-wide GND stitching grid, reports its shifted and blocked nominal sites, and replaces that generated grid on a repeated run
- The fence endpoint reports the resolved layer count for each fenced net
- A board whose RF class carries only (max-freq …) — no (fence …) — is still fenced by the endpoint, the pitch deriving as λg/10 and the vias persisting with the flanked net as provenance
- The fence endpoint accepts a max-freq-only RF board and reports a normal dry run on it, so the Fence action covers RF traces that never spelled (fence) out
- A fence dry run reports what it would place and writes nothing to the layout
- A fence run defaults to the vetted mode, placing only sites the board accepts and ending at the DRC error count it started from, while mode=all places every non-coincident site and reports the DRC without culling it
- The fence's DRC ratchet culls the fence vias implicated in a new error-severity violation and leaves warnings, net-open findings and pre-existing copper alone
- Repeated DRC findings from one generated fence via cull that via once rather than consuming its legal neighbours
- The fence ratchet compares violation identity against the baseline and never culls a new fence via merely because it is near a pre-existing error
- The fence endpoint and the generate_fence tool reject an unknown mode naming the two spellings that exist
- Re-running the fence on a layout replaces the previous fence rather than stacking a second row beside the same trace
- The fence endpoint 404s an unknown layout naming the rows that exist, and refuses a board that declares no fence
- The generate_fence CLI tool and the fence HTTP endpoint share one implementation, so they report the same board
- Generated RF fence sites render with a dashed annular ring in both Canvas and WebGPU views, while ordinary and perimeter vias stay solid; all remain selectable and editable, and provenance remains internal for safe regeneration
- Generated RF fence vias are disposable while hand-routing: previews, exact DRC gates, and scoped autocomplete ignore them, committed copper removes only intersecting posts, and perimeter/ordinary vias remain obstacles
- The PCB editor always shows the RF via-fence action, regardless of whether the board declares perimeter fencing or currently resolves a fenceable RF class
- The PCB page blob carries both the authored keepout halo and the full RF fence corridor through the far edge of its vias
- The PCB page blob carries each net class's resolved mask relief and fence untent reach so the assembly view shows the shipped mask
- The PCB page blob serves each continuous mask-relief run as one closed filleted polygon so the assembly view draws the shipped mask
- The PCB page blob keeps solver-authored pad tapers fully masked and begins RF relief at the exact uniform-trace boundary
- Assembly opens on its compact read-only semantic board and requests no Gerber/Excellon payload until the operator enables CAM Review
- CAM Review paints parsed Gerber/Excellon operations in WebGPU instead of rebuilding fabrication artwork from browser fonts and placement objects
- A settled CAM Review rerasterizes retained generated Gerber/Excellon operations into a camera-matched two-samples-per-axis WebGPU film, while only the short pan/zoom gesture window samples a full-board preview and its trailing paint restores inspection quality; Canvas2D remains only as the transparent component/interaction overlay and never interprets CAM operations
- CAM Review decomposes self-crossing Gerber region contours into simple faces selected by the Gerber non-zero winding rule before triangulation
- An opposite-face heatsink is retained in the WebGPU CAM command stream behind the opaque board instead of forcing a Canvas CAM fallback
- The Assembly CAM Review toggle lazy-loads dependency-cached Gerber/Excellon artwork, can return instantly to the semantic board, and exposes CAM layer controls only while exact files are active
- The Assembly CAM Review control visibly distinguishes fast, loading, exact, and failed states and applies same-document mode changes directly with a message fallback
- Assembly exposes a read-only Gerber ruler that snaps both endpoints to visible exact artwork edges, measures in world millimetres, reports fine mm and mil values, uses compact endpoint dots, and remains available in frozen release pages
- The initial Assembly iframe omits hidden DRC, editable-layout metadata, editor-only scripts, and inline CAM while exposing the lazy generated-files URL
- The Assembly physical-review embed omits optimizer, DRC, and route-status reporting while retaining the hidden route geometry inputs its read-only painter consumes
- Assembly layer controls independently toggle face copper, every physical inner copper layer, solder mask, paste, silkscreen, drills, board outline, and component overlays
- Assembly paints the closest enabled copper film from the viewed face bright gold and every enabled film behind it dim gold
- Assembly mask openings repaint actual pour copper as bare copper while leaving only copper-free gaps as exposed substrate
- Design Settings edits board-level numeric rules in the GUI, preserves unrelated source forms, rebuilds, and reloads the shown layout
- Design Settings renders validated numeric rule inputs with save-and-rebuild feedback
- Design Settings creates a design-rules source form when a board previously relied entirely on defaults
- Design Settings adds, edits, and deletes whole-layer copper planes without replacing physical stackup construction or comments
- Saving plane controls on an implicit board authors the visible copper count and supports an explicitly plane-free stack
- Design Settings exposes whole-layer copper assignments with add, edit, delete, validated save, and read-only states
- Assembly mask relief retains one authored-radius terminal fillet where a pad terminates or crosses the RF route
- Assembly and 3D mask relief restore a local pad-shaped web without interrupting the exposed trace
- The datasheet PDF viewer loads its pinned PDF.js runtime and worker from same-origin embedded assets, so offline/headless browsing never depends on a third-party CDN
- The PCB page blob names the declared plane nets, and omits the key entirely when the design declares no stackup
- The PCB page blob names the implicit model's supply-rail plane so the client DRC shares the server's plane-carried verdict
- The PCB page blob always carries the ground-name token vocabulary so the browser's ground test cannot drift from the server's
- The PCB viewer offers one Tapers + fence action that preserves RF route centerlines while refreshing controlled-impedance widths and ground-pour gaps, replaces stale taper paths from current pad and route geometry, DRC-gates and saves the result, then regenerates the RF ground via fence around that exact copper and a board-wide 5 mm GND stitching grid whose blocked sites may shift by at most 1 mm
- Saving an unchanged PCB state rechecks DRC without invalidating a concurrent copper-pour refill for that same state
- Copper-pour refill responses are accepted only when their exact board and pour inputs still match; the RF finish action waits for an existing refill instead of treating the occupied refill slot as a failure
- The PCB hand-routing editor offers one undoable GND-vias action that seeds DRC-legal exposed-pad arrays and centred ground-pad barrels, then places nearest-legal barrels beside pads still failing the ground-via-distance rule without replacing submitted copper
- GET /api/schematic-pdf/:name returns the composed review PDF as an application/pdf attachment that passes the writer's structural self-check
- GET /api/schematic-pdf/:name answers an unknown design or module name with a 404 whose body never reads as a PDF
- GET /api/schematic-pdf/:name?theme=light composes the print palette, yielding different bytes over the same pages as the default screen palette
- GET /api/schematic-pdf/:name percent-decodes the path param, so an encoded design name resolves to the same design as its decoded form
- The served PDF's /CreationDate is the review document's own generation instant, re-spelled in PDF date syntax
- GET /api/kicad-sch/:name returns a store-only zip whose flat member list is the schematic sheets followed by the four project sidecars
- GET /api/kicad-sch/:name is byte-identical across repeated requests for an unchanged design
- GET /api/kicad-sch/:name answers an unknown design or module name with a 404 whose body is never an archive
- GET /api/kicad-sch/:name percent-decodes the path param, so an encoded design name resolves to the same design as its decoded form
- GET /api/kicad-sch/:name?vendor=0 and ?flat=1 are the query twins of the --no-vendor-symbols and --flat CLI flags
- POST /api/sync-kicad-sch/:name?dry_run=1 reports the per-file plan and writes nothing, and the same call without it writes the sheets into the board's directory
- POST /api/sync-kicad-sch/:name answers 409 and writes nothing when an existing schematic is not netlisp's, and 404 for an unknown name
- POST /api/sync-kicad-sch/:name answers 400 naming the missing (kicad-pcb ...) form for a design that declares no board
- The sync_kicad_sch CLI tool is registered as a mutation and rejects a call with no name
- The sync_kicad_sch CLI tool reports a refusal as an ok:false result carrying the reason, rather than as a tool error
- The export_kicad_sch tool refuses an output_dir that is relative, escapes through '..', or points inside the project directory
- The export_kicad_sch tool is registered as a mutation, so writing an export is gated to writer roles
- The export_kicad_sch summary reports the file list with byte counts and the export's coverage tallies, never the sheet text
- style score credits matching part orientation, comparing a 2-pad passive mod 180 degrees
- style score rounds a part rotation to its nearest quarter turn
- The layout JSON measures a decoupling leg through the optimizer's own pad transform, so a bottom-side cap's leg_mm is the length the placer scored
- A repeated response body is gzipped once and served from a content-keyed memo
- A response body that changed by one byte misses the gzip memo instead of serving the page it replaced
- A response body too small to be worth memoising is still compressed
- A server whose gzip memo has no allocator still compresses its responses
- The one-parse layout read still falls back to the legacy .autolayout.json cache when the sidecar carries no cache slot
- Silk texts resolve against an already-parsed layout list, naming the requested row or falling back to the starred default
- A named layout save holds one sidecar lock across its whole revision check-then-write, so two saves that observed the same revision cannot both be accepted
- Concurrent writers of one design's layout sidecar are serialized so that every accepted write advances the revision by exactly one and no write's saved row is overwritten by a peer that read the same revision
- Edit-source provenance in the PCB blob is escaped for the script element, so neither a ref-des key nor an instance label can close the tag
- One sidecar always hashes to one lock slot and its guard releases it, so a collision only over-serializes and can never deadlock
- Part fields in the PCB blob are escaped for the script element they sit in, so no ref-des, value, MPN, footprint, pad or pad-net name can close the tag
- Plane net names in the PCB blob's layer table are escaped for the script element, so a plane net cannot close the tag
- Power-integrity net and terminal names in the PCB blob are escaped for the script element, so neither can close the tag
- Each power net in the PCB blob carries a "flow" object naming its per-axis status, unplaced current, per-terminal source contacts and per-load resolution
- The BOM symbol-pin cache reads library pinouts at the class-owned lib_limits cap, so a pinout past the retired 256 KiB figure still contributes its pads
- The pinout endpoint reads its library file at the class-owned lib_limits cap, so a pinout past the retired 256 KiB figure is served rather than answered 404
- The revision-free sidecar writers, the render dedup and the regenerate record, re-read under the sidecar lock rather than trusting a value read before it
- Two saved vias that differ only in their layer span are different copper and both survive a sidecar save round-trip
- The schematic BOM card escapes every attacker-writable field it renders — component, value, footprint, attrs, MPN, manufacturer and property keys — and refuses to make a link out of a non-http datasheet URL
- The BOM card links a datasheet only for an http(s) or site-absolute URL, and that link is emitted with rel="noopener noreferrer"
- The 3D viewer validates its `:footprint` route param after percent-decoding, so a decoded name carrying traversal or markup reaches neither a read path nor the page
- The staged-upload temp path is minted from a timestamp and a process-unique counter with no request input in it, so an uploaded archive cannot steer where it is written
- A library import ignores the client's X-Filename header entirely, so two uploads of one archive under different filenames produce identical results
- One shared parser reads the client DRC board payload, so the stateless check and the session probe see identical parts, pads and net rules
- The session parse copies every string out of the payload buffer so a loaded board survives the buffer being reused
- The WASM DRC session probe enforces an RF net's declared keepout halo, so the mid-drag gate refuses the copper the full check flags
- The WASM DRC session probe reads each net's class identity, waiving the keepout halo between one class's own members and inside a pad-escape zone
- The shared DRC JSON writer escapes a violation's names for the page's script blob, so a net named </script> cannot close the element
- completeness-waiver: concurrent access (httpz owns request threading and each handler answers from its own response arena; the two pieces of state that really are shared — the live scene graph and a design's layout sidecar — are specified where they live, under the push and layout-backfill sections, rather than restated per endpoint)

## fab_readiness

Public functions: check, writeJson, savedOutline, declaredOutline, outlineDrift

- a routed net is connected; an unrouted multi-pad net is flagged
- Copper connectivity uses a 1 µm numeric contact tolerance; a same-net 1–20 µm gap stays electrically open and is an error-severity hairline_gap
- An SMD pad joins routed copper only on its authored outer face; a through-hole pad joins every copper layer
- Declared plane-carried ground nets default to a 1 mm maximum SMD-pad-to-stitch-via distance
- A flattened net pin whose part or pad no longer resolves is a fab-readiness error, never a silently dropped terminal
- pad-to-track connectivity requires a full cross-section of the narrower copper feature; a capsule-only edge or corner graze stays open
- track-to-track connectivity requires a full cross-section of the narrower trace inside the other trace; a cap-only or parallel-flank graze stays open
- track-to-via connectivity requires a full cross-section of the narrower copper feature; a tangential land graze stays open
- a rail net joined only by an inner-layer copper pour passes the unrouted-net gate
- a pad inside a higher-priority overlapping pour drops out of the lower pour's connectivity
- connectivity propagates across an inner-signal-layer chain through its vias
- a ground plane connects its pads without routed copper
- a surface pad isolated from the plane is flagged until a plane via bridges it
- a whole-board sweep handed the board's rasters reports exactly what pouring them per sweep reported
- an open net's island report marks the island already joined to the net's plane or pour copper
- a same-net trace that enters a user pour joins it without a sacrificial via
- two same-net vias that abut with no track between them are one copper island
- the net graph reports whether its plane verdict was computed on a coarsened pour raster
- a missing outline, off-board part, drill-less via, and DNP all surface
- a clean board produces no errors and reports ok
- the fab gate's DRC measures against the design's resolved clearance rule
- solver-proven RF pad tapers retain their route metadata and do not become false track-width errors at the export gate
- a warning-severity DRC finding flows through as a gate warning; an error-severity one blocks
- a custom outline polygon with fewer than 3 points warns that the profile fell back to a rect
- a part in a concave notch is flagged off-board by the polygon inset, not just the bbox rect
- release confirmation tokens bind report findings, CAM identity, source and evaluated BOM
- a zero-length track is a point feature that joins the same-net copper covering its centre, and its own half-width disc grants it nothing more
- a notched saved outline reports outline-drift carrying the digest to pin, clears once the source pins that digest, and reports an outdated pin as a distinct stale approval

## fabrication-release

- DRC findings require a separate explicit browser acknowledgment while non-DRC evidence failures remain visibly non-waivable
- every acknowledged fabrication ZIP includes dedicated JSON and Markdown reports containing every raw DRC error and warning
- a panelized fabrication ZIP retains the single-board BOM and centroid and adds panel BOM and centroid files with repeated placements and total quantities
- a stable release renderer may extend the exact read trace with assembly-only inputs, while any changed byte still blocks packaging
- revision, source-ID, BOM/centroid, and fallback-geometry identity failures can never be waived
- consumed-input closure identity is independent of filesystem read order
- exact read tracing retains child-directory identity and rejects an A/B/A byte sequence
- a hidden cache probe is absent from the read trace while a real mid-scope edit still fails verification
- a cache probe ended away from its owner thread fails the hidden trace closed
- release tracing binds directory membership and absent optional inputs to the exact evaluated snapshot
- logical file and directory aliases retain their exact resolved target through release verification
- relative project roots resolve to the canonical absolute path identity recorded by the exact read trace
- rail checks use worst-case voltage, reject underrating, preserve unknown endpoints, and size zero-ohm jumpers by rail current
- a series-correlated pair is checked at its IR drop, not as two independent intervals
- independently declared envelopes never collapse, so a genuinely underrated series resistor still fails
- a series element is charged the branch its own rail data declares, and the whole rail's worst case only when the design declared no branch
- a rail with no per-branch declaration still charges every series element its whole worst-case load
- a zero-ohm configuration strap to ground carries no rail current, while a jumper any rail reaches or a ground-to-ground link stays unproven
- a series magnetic sealed inside a module inherits that module's declared input current, and keeps none of it on a leg the declaration never covered
- a net a ferrite bead ties to a rail is that rail's node for current as well as voltage, so a module-internal series element behind the bead is charged the rail
- saved rounded outlines must exactly match authored dimensions, radius, polygon, and native arcs
- synthesized footprint fallback geometry is a non-waivable release identity failure
- 0R0 is a zero-ohm jumper that requires authored current and maximum-resistance evidence, never tolerance
- HTTP and MCP readiness expose the same revision lock independent of canonical project-root spelling
- strict canonical-module policy is incomplete, and therefore release-blocking, when any module source is malformed
- SI-prefixed passive ratings are parsed with case-insensitive unit names, including the common `mOhm` spelling
- selected layout evidence rejects every malformed or silently defaulted manufacturing record before release
- allocation failure while lowering saved fabrication layers, copper, zones, keepouts, or perimeter vias blocks release rather than certifying a partial board
- allocation failure while parsing a valid selected sidecar row is non-waivable incomplete evidence rather than silently dropped copper or silk
- redundant saved polygons and dimensions must match the exact sketch-derived manufacturing geometry or release evidence is incomplete
- duplicate design basenames are a non-waivable source-bundle ambiguity while all independent release findings remain visible
- MCP preserves the full release report and null authorization token for an ambiguous source bundle
- an in-request A/B/A sidecar mutation invalidates HTTP readiness and export without granting an authorization token
- release tokens bind finding counts, report statistics, and complete DRC bridge evidence
- a fabrication package request whose project source revision already blocks the release is refused before the board is placed, checked or digested
- the fast fabrication refusal cites the same source-revision finding as the full report and states that the rest of the report was not computed
- the fast fabrication refusal declines every request the saved-layout selection still owes a 404
- a collapsed sub-micron track crumb the parser culls is not dropped manufacturing copper, while any other missing track still fails release evidence
- a first readiness run against a stale BOM sidecar reports the steady-state findings plus only the non-waivable staleness block, without rewriting the sidecar
- every non-waivable release-blocking id is still spelled at the site that emits it
- completeness-waiver: empty inputs (an empty/missing selection has no exact manufacturing row and is a non-waivable evidence failure)
- completeness-waiver: large inputs (the sidecar read is capped at 16 MiB before the strict JSON tree and entity validation run)
- completeness-waiver: unauthorized access (the validator is read-only; HTTP authorization remains at the manufacturing endpoint boundary)
- completeness-waiver: i/o failure (missing, unreadable, or changing source/sidecar/review inputs make evidence incomplete and block release)
- completeness-waiver: concurrent access (the exact read trace binds consumed bytes, directory membership, aliases, and absent candidates, then verifies them again before packaging)
- completeness-waiver: malformed encoding (invalid JSON or invalid typed manufacturing fields are rejected as incomplete evidence)
- completeness-waiver: integer overflow (layer/revision/count conversions are finite, range-checked, and never lossy in the strict release validator)
- completeness-waiver: panic-free (release evidence failures are structured non-waivable findings; the gate contains no intentional panic path)

## serve/fab_filename

Public functions: prefix

- forbidden JLCPCB words and special characters fall back to a neutral fabrication basename
- completeness-waiver: empty inputs (the empty basename deterministically falls back to `board`)
- completeness-waiver: large inputs (the scan is linear in the already-bounded route basename and allocates nothing)
- completeness-waiver: unauthorized access (pure filename classification has no access or mutation surface)
- completeness-waiver: I/O failure (the function performs no I/O)
- completeness-waiver: concurrent access (the function has no mutable or shared state)
- completeness-waiver: malformed encoding (non-ASCII bytes fail the allow-list and fall back to `board`)
- completeness-waiver: integer overflow (window bounds are derived only after proving `name.len >= word.len`)
- completeness-waiver: panic-free (all slices are bounded by the checked window length)

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

## eval/pcb-plan

The top-level `(pcb-plan (place (wave …)…) (route (wave …)…))` form declares the
ordered plan for completing a PCB layout. It parses and stores only — a later
slice resolves the selector member names into part/net sets.

- A pcb-plan form captures each place and route wave's selectors, reason, and rest flag
- A design with no pcb-plan form leaves DesignBlock.pcb_plan null
- A duplicate pcb-plan form keeps the first and warns
- A wave with no leading name string is skipped with a warning
- A route-only selector inside a place wave is skipped with a warning
- Relative route guides parse as ordered pin- and part-relative instructions
- An (assign-escapes) route selector records its optional layer and hub overrides
- A route wave's (branches) records one ordered corridor per limb and skips a malformed or pointless limb with a warning
- A pcb-plan form inside a section is rejected by the scope table with a warning
- completeness-waiver: empty inputs (a bare `(pcb-plan)` or empty place/route parses to an empty PcbPlanSpec — every member slice defaults empty, no special case)
- completeness-waiver: large inputs (the parser only copies atoms already present in the AST, adding no multiplicative expansion; wave/member counts are bounded by the source file the evaluator already holds)
- completeness-waiver: unauthorized access (pure AST-to-struct parsing with no I/O, network, or auth surface — access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no file, socket, or syscall access — the parser reads only the in-memory AST, so there is no I/O to fail)
- completeness-waiver: concurrent access (a pure function over an immutable AST slice into per-call ArrayLists — no shared mutable state, so concurrent evaluations are independent)
- completeness-waiver: malformed encoding (malformed waves — no name, unknown selector head, cross-section selector, unknown class atom, duplicate rest — are warned and skipped, never a hard error; covered by the skip/warn tests)
- completeness-waiver: integer overflow (no arithmetic — the parser only copies string slices and sets bool/optional flags)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

### (pcb-plan (topology))

The opt-in flag that hands a route wave's nets to the global topology planner
instead of letting them contend one net at a time. Parsed on the plan or on a
single route wave and lowered into `ResolvedWave`/`ResolvedPlan`, where
`serve/route-plan`'s one lowering seam turns it into soft corridor guides; a
design that authors none resolves — and routes — unchanged.

- A plan-level (topology) sets the resolved topology flag on every route wave including the implicit rest wave
- A wave-level (topology) sets the resolved flag on that wave alone and leaves the other waves false
- A plan with no (topology) anywhere resolves every place and route wave with the flag false
- A wave-level (topology) is a known route selector and is not warned as an unknown word
- A wave-level (seed-first) is a known route selector and records a deferred bounded repair request against frozen completed copper

## placement/progress

Public functions: compute, writeJson

- the schematic rung is done exactly when there are no ERC errors
- the sub-circuits rung is done exactly when every needs-layout module is starred
- a missing starred module layout carries its module PCB target for one-click completion
- the board-setup rung is done exactly when the board has an outline
- the placement rung is done exactly when every part is locked
- the routing rung is done exactly when every routable net is connected
- the fab-ready rung is done exactly when the fab gate passed on a saved layout
- the current stage is the first not-done rung even when a later rung is done
- ledger items carry stable ids across two recomputations of the same finding
- writeJson emits all six stages with status, done, total, and open items
- an empty placement leaves the placement and routing rungs vacuously done
- netConnectivity reports the routable and connected counts the fab report records
- netConnectivity credits parent-rail copper to structurally proven generated per-pin bypass connections
- a place wave is done only when every member part is locked
- a route wave counts only its routable members toward done and total
- the current wave is the first incomplete wave of the current stage
- an out-of-order advisory fires when a later wave progresses before an earlier one finishes
- writeJson renders the per-wave tallies and tags open items with their wave
- plan warnings surface in the report and in its JSON
- completeness-waiver: large inputs (a pure O(nets+parts) pass over typed slices; a bigger board only lengthens the ledger, it never changes the shape of the result)
- completeness-waiver: unauthorized access (a pure in-memory computation with no I/O or auth surface; access control lives in serve)
- completeness-waiver: i/o failure (no disk or network — every input arrives in the caller-assembled Inputs struct)
- completeness-waiver: concurrent access (a stateless pure function over immutable inputs; callers each compute their own Report)
- completeness-waiver: malformed encoding (inputs are typed Zig structs, not parsed bytes, so there is no encoding to malform)
- completeness-waiver: integer overflow (counts are bounded by slice lengths and the id hash folds with defined wrapping arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/plan-resolve

Public functions: resolve

Turns a parsed `(pcb-plan …)` (`?PcbPlanSpec`) plus the solved design/placement
context into a `ResolvedPlan` — each wave's selector names expanded to concrete
part/net index sets — or, when no plan is authored, synthesizes a default from
ref-des conventions and `module_policy` detection. A pure, deterministic
function; unresolved selector names become warnings, never errors.

- a refs selector matches parts by exact ref and by bare sub-block leaf
- a sections selector claims every instance declared in the named section
- a sub-blocks selector claims every part under the sub-block slug prefix
- a classes selector claims every net of the named module-policy class
- a net-classes selector inherits all nets of the authored net-class it names
- a nets selector claims nets by name
- relative route guides lower from current part and pin geometry into deterministic waypoints
- an authored branch tree lowers into per-net guide branches in authored limb order, and a limb count that cannot cover a member net warns
- an (assign-escapes) route wave lowers its nets into soft per-net escape-lane guides
- an (assign-escapes) wave whose nets share no hub warns instead of silently routing unassigned
- the nets an authored (assign-escapes) wave hands to the assigner are reported as a mask, and a plan authoring none reports an empty one
- an (assign-escapes) wave that assigns only some of its nets keeps the guides it earned and warns naming every net it refused
- the guides an (assign-escapes) wave lowers are exactly the ones the escape assigner reports for the same net set, so the preview and the route agree
- a route wave whose only permitted layers are fully covered by foreign pours warns naming each reserved layer and its pours
- resolveNetScope selects a criticality-class group token's nets and reports the selector count
- resolveNetScope resolves an authored net-class name and unions multiple group tokens
- resolveNetScope selects a sub-block slug's private and boundary nets by pin membership
- resolveNetScope collects an unrecognized token and resolves explicit nets while empty selectors mark a whole-board route
- a part matched by two waves belongs to the first wave in document order
- parts unmatched by any wave fall to the rest wave whether authored or implicit
- an unknown selector name yields a stable warning and is never dropped silently
- resolving the same inputs twice yields an identical plan
- an absent plan synthesizes connector power and high-speed waves from module policy
- completeness-waiver: empty inputs (an empty PcbPlanSpec resolves to a single implicit rest wave per section; a placement with no parts/nets yields empty member sets — no special case)
- completeness-waiver: large inputs (a pure O(waves·members + parts + nets) scan over typed slices; a bigger board only lengthens the member sets, never the plan shape)
- completeness-waiver: unauthorized access (a pure in-memory computation with no I/O or auth surface — access control lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk, socket, or syscall — every input arrives in the caller-assembled Context and PcbPlanSpec)
- completeness-waiver: concurrent access (a stateless pure function over immutable inputs into per-call arena-owned slices — concurrent resolutions are independent)
- completeness-waiver: malformed encoding (inputs are typed Zig structs, not parsed bytes; an unrecognized selector name is warned, never a hard error)
- completeness-waiver: integer overflow (the only arithmetic is the id hash's defined wrapping FNV fold; indices are bounded by slice lengths)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## serve/route-session

Public functions: startSessionApi, getSessionApi, hintSessionApi, deleteSessionApi, distillSessionApi

Interactive routing sessions — the HTTP half. `POST …/start` solves a design's
placement exactly as the design replay does (starred layout preferred, or the
posted `{"parts":[…]}` poses placed verbatim), begins a router session that
owns its own arena, runs the first event, and answers full state in the shared
route-review board/timeline wire shape (so the front-end replays it unchanged)
plus a `stuck` block (paused net, pads, the base64-encoded maze frontier,
competing blockers, per-layer occupancy) or a `final` block when done. `GET
…/:name` returns state without advancing; `POST …/hint` applies one hint
(corridor / rip / route_now / layers / abandon — net NAMES in the wire resolved
to indices) and advances; `DELETE …/:name` discards; `GET …/distill` renders the
accepted hints as a `(pcb-plan (route …))` fragment. One session per design in a
mutex-guarded, idle-evicted, capped table held in ServerState.

- a hint's layer name resolves through the shared board layer lookup, so a plane-claimed inner names no bit
- a route session start routes the placement exactly as the design replay does
- the layers popover's offered rows are exactly the copper layers a layers hint resolves, on a declared stack and on the implicit model
- a hint naming an unknown net is a 400 that leaves the session unadvanced
- the distilled plan fragment parses as a valid s-expression
- the stuck block serializes each layer's occupancy grid alongside the frontier
- a second start replaces the design's existing session
- manual completion serializes successful swept RF paths instead of discarding their fabrication geometry
- idle sessions are evicted on access
- the frontier grid cells round-trip through base64
- completeness-waiver: empty inputs (a design with no parts/nets solves to an empty placement that routes to a done summary with empty board arrays; a hint body with no net/points/layers answers 400 via parseHint; distilling zero accepted hints yields a bare `(pcb-plan)`)
- completeness-waiver: large inputs (the solve is bounded by the design; the timeline/board JSON is linear over the placement's nets and parts; the frontier grid is capped by the router's own bounds)
- completeness-waiver: unauthorized access (all /api routes gate through the serve dispatch middleware / serve/ward_auth, and a design name must match the project design list — also the path-traversal guard, via route_review.isListedDesign)
- completeness-waiver: i/o failure (a design solve/list failure surfaces as a 404/500 JSON error and leaves no session — createSession frees its partial arena via errdefer; the router session owns its own arena and never touches the design's board file)
- completeness-waiver: concurrent access (one Store mutex serializes every session operation; sessions are one-per-design, capped, and idle-evicted, and each session's retained hint memory lives in its own arena that outlives requests)
- completeness-waiver: malformed encoding (a malformed hint body answers 400 via parseHint; a malformed poses body degrades to no poses via route_review.parsePosesFromBody; the design source is never re-serialized)
- completeness-waiver: integer overflow (counts are usizes / slice lengths bounded by the placement; base64 sizing uses std.base64's checked calc; net indices are range-checked before printing)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## placement/route-session

Public functions: start, runUntilEvent, applyHint, currentRun, acceptedHints, deinit

The interactive-routing driver (the router-core half). `RouteSession` runs the
WHOLE standard pipeline first via `router.routeCoreStart` (plane vias, the
greedy maze pass, and every bounded rip-up round — the router exhausts its own
tricks), then presents the nets still failed after that ONE AT A TIME as
`StuckReport` stuck-points. Each report carries the stuck net's pads, a
cropped/downsampled search-frontier snapshot (a bounded reachability flood from
the first pad over the router's own `blocked` cost model — cells tagged
reached / blocked-by-copper / blocked-by-clearance), the ranked blocker nets
(share of the frontier's blocked copper each owns, plus its rip cost in mm), and
per-layer occupancy. A human applies a `Hint` — a corridor of waypoints
(lowered onto the waypoint policy), a forced rip of blocking nets (the rip-up
`ripNet` path), a queue reorder, an allowed-layer override, or an abandon — which
is recorded (into the accepted-hints log and the timeline as a `hint_applied`
decision) and consumed by the next `runUntilEvent`: the stuck net is retried
first via the same per-net maze call greedy/rip-up use (`router.rerouteNet`),
forced-rip nets rejoin the queue after it, and the net either pops (routed) or is
re-presented with a bumped attempt count. When the queue empties (or every
remaining net is abandoned) the finish passes run ONCE via `RouteCore.finish`
and the session is done. The session owns its own arena so its state survives
across requests; the non-session entry points (`route` / `routeWithOptions` /
`routeWithTimeline`) share `routeCoreStart` + `RouteCore.finish` and are
unchanged by the session machinery.

- the interactive session presents each post-ripup failed net once as a stuck report with a search-frontier snapshot
- the stuck report carries per-layer occupancy grids over the frontier window distinguishing foreign copper from other keepouts
- the stuck report ranks the nets whose copper the search pressed against
- a rip hint forces the named nets off the board and retries the stuck net before them
- a corridor hint guides the retried net through its waypoints
- an abandoned net is skipped and the finish passes still run to a done summary
- the non-session route entry points route identically alongside the session machinery
- accepted hints are recorded in order and appended to the timeline as decisions
- completeness-waiver: empty inputs (a fully-routable board has an empty failure queue, so the first event finishes straight to a done summary; an empty/overflowed grid yields an aborted status with no live session)
- completeness-waiver: large inputs (the automatic passes are the router's own bounded passes; the frontier flood is expansion-capped and its grid downsamples to a bounded cell count, recording the effective cell_mm)
- completeness-waiver: unauthorized access (an in-process router driver with no auth surface; endpoint access control lives in serve/ward_auth on the serve half)
- completeness-waiver: i/o failure (no disk or socket — inputs are an in-memory placement plus routing options, and the session owns an arena rather than any board file)
- completeness-waiver: concurrent access (one session is single-threaded over its own arena that outlives requests; the serve half serializes session operations under a Store mutex)
- completeness-waiver: malformed encoding (inputs are typed router structs; a hint naming an out-of-range net index is bounds-checked and ignored rather than raising)
- completeness-waiver: integer overflow (counts are slice lengths and bounded grid-cell usizes; the downsample factor is checked ceil-division over small grid dimensions; millimetre coordinates stay f64 and float→int narrowing happens only inside the router's grid helpers via numeric.checkedInt)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## svg2pdf

Public functions: translate, translateAll

Strict translator from the schematic renderer's closed SVG subset (what
`render_html.renderHubSvg` emits through `src/render_svg/*.zig`) to a flat
`DrawOp` display list with absolute coordinates and resolved RGB colours. It
holds no dependency on the PDF writer: the output is pure data, so the composer
is the only place the two halves meet. Anything outside the subset is a hard
error carrying a byte offset, so renderer drift fails loudly instead of
rendering wrong.

- Translates the emitted line/polyline/rect/text subset into resolved DrawOps
- Resolves a class style when no inline attribute overrides it
- The print palette darkens strokes and text for a white page
- An unlisted light colour is darkened rather than passed through to a white page
- Preserves the single emitted arc path form with its radii and sweep
- Rejects path data outside the single arc form with the offending byte offset
- Drops hit-area, debug-pin, display-none and transparent-stroke markup
- Rejects an element outside the subset with its byte offset
- Rejects an unsupported group transform or an unstyled style
- Rejects a class the style table does not know
- Rejects a non-finite or unparseable coordinate rather than saturating it
- Rejects an unsupported colour keyword
- An empty or root-less input is rejected instead of yielding an empty document
- Rejects malformed or unterminated markup rather than reading past the end of the input
- Translates a multi-SVG hub render as a sequence of documents
- Each document carries the pin-group heading written above its svg, entity-decoded
- A bulk render of many hub SVGs translates without error or quadratic blowup
- The Zig style table agrees rule-for-rule with render_html.static_svg_css
- Every style-table rule names classes and elements the emitters actually use
- A real per-hub render of passives, an inductor arc, a ground glyph and net labels translates strictly
- Ref-des, pin-function and net labels survive translation as text ops
- The full-project sweep skips gracefully when the design tree read fails or is not checked out
- Translates the block-icon polygon glyph the draw layer can emit
- Fuzzing the translator with arbitrary bytes never panics and never leaks
- completeness-waiver: unauthorized access (a pure in-memory string-to-display-list function with no auth surface; the SVG it consumes is produced in-process by the renderer, and access control for the endpoints that will serve the PDF lives in serve/ward_auth)
- completeness-waiver: concurrent access (stateless — every call owns a stack-local Parser and allocates only into the caller's arena, so two translations share nothing and need no locking)

## export-pdf

Public functions: compose

Review-document PDF composer (`src/export_pdf.zig`) — the only place the PDF
writer and the SVG-subset translator meet. It builds `review_md.zig`'s report in
a second medium from the same `review.ReviewDoc` and the same
`render_html.renderHubSvg` per-hub renders: cover (title, revision, injected
generation stamp + build hash, status roll-up), one A4-landscape sheet per
`(section …)` with the section's hub schematics shelf-packed into a 2D grid at
one bisected scale (each cell captioned with its pin-group label), a validation
appendix (ERC, assertions, per-IC requirement checks), and the power budget /
sequencing / test-point tables. A section sheet is UNIFIED: the modules
`diagram/membership.attachedSubBlocks` says it owns — the same authority the
schematic page renders attached cards from — draw in that one grid, so a section
whose hardware is sealed in a `(sub-block …)` shows its name, subtitle, status,
its module's schematic and its notes on one self-contained page instead of
describing a circuit several pages away. Only single-instance modules attach: one
instantiated more than once keeps its appendix entry with its `x N` caption, and
the appendix holds exactly what no section drew. Notes follow their circuit — a
module's own `(note …)` entries render on whichever sheet draws it (deduplicated
against the section notes that repeat them), and a ref-anchored `(note "REF" …)`
lands on the sheet declaring that ref, or in the appendix when no section does. A
section the grid cannot pack at any legible scale falls back to the sequential
flow, whose unit is one translated document: a hub is never split across a break,
and only a document taller than the usable page height is sliced (clip +
translate, section header repeated). Sections and sub-block modules are collected
once, in declaration order, then laid out: one whose hubs draw nothing is a
COMPACT entry that flows onto the page already in progress, and a sheet sizes its
tail reserve from its own measured prose plus a look-ahead at the compact entries
that actually follow it — trimmed to what the sheet can spare above the grid's
floor-scale footprint, so the reserve never costs the grid its sheet. Nothing here
reads a clock, so a fixed injected stamp yields byte-identical output.

- The composed document carries the design title, every rendered ref-des and net label as extractable text
- No text in the composed document falls back to an unmappable question mark
- A composed document passes the writer's structural self-check
- A fixed injected timestamp makes two composes byte-identical
- The cover page carries the injected generation stamp, build hash and status roll-up
- Every page after the cover carries a footer naming the design and its page number
- A document taller than the page scales down to fit one page before it is ever sliced
- A very large schematic document taller than one page slices across pages with the section header repeated
- A document that fits the page flows as one block without being split
- A section's blocks pack onto one sheet as a 2D grid rather than one block per row
- A grid cell carrying a pin-group label draws that label above its block
- An empty design with no sections, sub-blocks or findings still composes a valid document
- A module note repeating a section note's visible text is dropped while an identical note from a sibling module is kept
- A section with no drawable schematic flows inline instead of claiming its own page
- Two schematic-less sections in a row share the preceding sheet instead of the second claiming a page
- A sub-block whose module draws no hub schematic becomes an inline entry, not a blank page
- A repeated sub-block module renders once with its instantiation count
- A section's attached single-instance sub-block draws on the section's own sheet, and the sub-block appendix does not repeat it
- A module instantiated more than once stays an appendix entry with its repeat count rather than being drawn into every section hosting it
- A module's own notes render on the sheet that draws its circuit
- A ref-anchored design note draws on the sheet holding its part, and one whose ref no section declares surfaces in the appendix
- A sheet trims its notes reserve to what it can spare rather than abandoning the grid, so a lone tall hub never leaves the sheet holding only its header
- Long table cells truncate to their column instead of overrunning the page
- The thermal screen reaches the Power & Bring-Up sheet with its verdict sentence, ambient range and per-part row
- The light theme resolves the print palette while the default resolves the screen palette
- The default dark theme paints every page with the web background while the print theme leaves pages white
- The Tj extractor decodes escaped parens, backslashes and octal escapes
- completeness-waiver: unauthorized access (an in-memory composer over an already-evaluated DesignBlock, with no request, user, or write surface; the CLI resolves the design by name through the same path build/check use, and access control for the endpoint that will serve the PDF lives in serve/ward_auth)
- completeness-waiver: i/o failure (compose returns the whole file as bytes the caller owns and opens no file, socket, or pipe; the only read it triggers is the render context's library lookup, which the renderer already degrades gracefully, and writing the result out is the CLI's failure domain)
- completeness-waiver: concurrent access (a Composer owns its pdf.Doc, its page list, and a scratch arena with no globals or shared state, so two composes share nothing; the DesignBlock and ReviewDoc it borrows are read-only)
- completeness-waiver: malformed encoding (the composer consumes trusted in-process data — an evaluated DesignBlock plus SVG its own renderer just emitted — and every byte it writes goes through pdf.encodeWinAnsi, which is fuzzed in the pdf section; markup outside the SVG subset is rejected by svg2pdf, whose fuzz harness covers arbitrary bytes)
- completeness-waiver: integer overflow (all page arithmetic is f64 and saturates in the writer; the only integer values are page and repeat counts bounded by the design's own section/sub-block lists)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## Shove primitive

Public functions: shove

The geometry engine for push-and-shove: nudge existing copper sideways so a
requested lane opens. The router's conflict resolution can only RIP a net and
retry it — it has no move for copper that is in the way by a tenth of a
millimetre while having half a millimetre of empty board on its far side, which
is exactly the failure this closes (and exactly what KiCad's PNS does).

`src/placement/shove.zig` is pure: plain records in (`Scene` — polyline copper,
vias, pads, per-net width/clearance `Rule`s, and the usable board rectangle —
plus a `Request` naming a corridor centreline, a lane half-width, a layer and a
net), deterministic slices out. No routing context, no RNG, no clock, no disk.

One primitive does all the work: **push a polyline out of the capsule around
another polyline**. The requested lane is a capsule (corridor + half-width) and
a track that was itself shoved is a capsule (centreline + half its width), so a
cascade is only "the pushed track's capsule becomes the next round's zone".
A shove displaces the intruding interior of a run by the smallest distance along
the escape direction that reaches the required centre-to-centre clearance,
leaves both anchors exactly where they were, and inserts ONE ramp vertex on each
boundary — the shortest one whose segment is still octilinear, so an octilinear
run comes back octilinear. Vias and pads never move; a lane holding one is a
refusal that names it. Every displaced run is then re-measured against every
pad, via, foreign track, the board rectangle and the lane, and anything still
short is a refusal naming the binding object and the millimetres it lacked.

- A foreign track with slack is displaced the least distance that opens the requested lane
- A track pinned against an immovable pad refuses and names the pad plus the millimetres of clearance it lacked
- A shove that can only clear the lane by pushing its neighbour cascades one level and moves both runs
- A cascade deeper than the requested limit refuses and leaves every run where it was
- A via inside the requested lane refuses and names the via, because v1 never moves a via
- A shoved octilinear run stays octilinear and gains no corner sharper than a 45 degree jog
- A run whose endpoint is anchored on a pad keeps that endpoint at exactly its original coordinates
- The same scene and request run twice produce byte-identical geometry
- A displacement that would carry copper outside the board rectangle refuses instead
- A track whose intruding copper lies on both sides of the corridor refuses as a crossing rather than being nudged
- An empty corridor or an empty working set is a no-op that reports the lane already achieved
- Partial mode keeps the chains that succeeded and drops every chain that hit a refusal
- The ramp fraction picks the shortest octilinear jog and falls back to a perpendicular staple when no jog exists
- A direction is snapped to the exact octilinear table so a displaced run carries no rounding dust
- completeness-waiver: large inputs (every scan is bounded before it runs — a polyline is walked at a fixed 0.05 mm step capped at 65536 samples, the displacement solve is capped at 6 rebuild passes and 12 mm of travel, and cascade breadth is bounded by the caller's max_cascade; a working set is one router rescue's local copper, not a whole board)
- completeness-waiver: unauthorized access (an in-process geometry function with no request, user, file, or socket; the rescue tier that calls it runs inside the router, and access control for the endpoints that reach the router lives in serve/ward_auth)
- completeness-waiver: i/o failure (no disk, socket, or pipe — the inputs are caller-owned slices of millimetre coordinates and every byte of output is allocated from the caller's allocator, so the only failure mode is OutOfMemory, which is propagated)
- completeness-waiver: concurrent access (single-threaded and side-effect-free: the engine owns a private slot array in the caller's arena, never writes through any input slice, and holds no globals, so two shoves over the same Scene share nothing)
- completeness-waiver: malformed encoding (there is no encoding — inputs are typed f64 records, not parsed text; a degenerate polyline, an empty corridor, or a zero-length segment is handled structurally rather than raised, and a caller's non-finite coordinate simply fails every clearance comparison and refuses)
- completeness-waiver: integer overflow (all geometry is f64; the only integers are slice indices derived from slice lengths and the sample count, which goes through numeric.toCount and is then clamped into [1, 65536] before it is ever used as a divisor or a loop bound)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## MATLAB RF PCB simulation export

Public functions: build, errorMessage, pcbMatlabRfApi, fabViewFor

The PCB layout page exports a saved L1 `CAL_THRU` route as one MATLAB R2022b
RF PCB Toolbox simulation ZIP. Version 1 crops the model from connector-pad edge
to connector-pad edge: the connector bodies and connector lands stay outside,
while the complete routed width/taper sequence, local CPWG ground, nearby plated
GND via fence, continuous L2/L3 GND references, and L4 via lands stay inside.
Two explicit 50-ohm edge ports terminate the straight route endpoints at the
crop boundary. The common y-up, top-view frame is centered on that boundary and
is shared by every Gerber, Excellon hit, manifest coordinate, port, via, and
preview.

The ZIP root and filename are `<project>_matlab_rf_export_v1`. It contains
strict `manifest.json`,
four separate aligned copper-positive RS-274X files, plated-only Excellon data,
the patterned top-mask Gerber, a registered all-copper preview, and a labeled
stackup preview. The manifest preserves the exact authored JLCPCB preset,
finished and modeled thicknesses, each foil and dielectric interval, material
names and epsilon-R, per-via connectivity/diameters, edge-port geometry, and the
60 MHz-to-class-maximum full-wave MoM sweep request. Unknown laminate and mask
loss properties remain JSON `null` and make material status `incomplete`; the
export never invents them.

- CAL_THRU exports as one self-contained ZIP with the specified root directory and required files
- ambiguous or branched routes fail instead of emitting misleading edge ports
- a swept RF path in the crop is exported as its real width profile and tented taper, never as the compact editor handle
- completeness-waiver: empty inputs (an absent design, saved layout, stackup, route, or GND fence returns a named refusal and no ZIP; no empty placeholder artifact is valid)
- completeness-waiver: large inputs (v1 accepts one unbranched routed net and crops to its two endpoints; array sizes are bounded by the saved route/via slices and the ZIP writer's fixed entry set)
- completeness-waiver: unauthorized access (the exporter is an in-process serializer over one already-authorized saved PCB view; HTTP authorization remains the server middleware's responsibility)
- completeness-waiver: i/o failure (the exporter opens no files or sockets and returns caller-owned bytes; writer and allocator failures are propagated or converted into an explicit HTTP failure)
- completeness-waiver: concurrent access (all geometry, validation state, previews, manifest bytes, and ZIP entries live in the request arena with no mutable globals)
- completeness-waiver: malformed encoding (names go through the shared strict JSON string writer and archive tokens admit only ASCII letters, digits, dash, and underscore; generated JSON is parsed again before packaging)
- completeness-waiver: integer overflow (Gerber coordinates are bounded by finite PCB millimetre geometry before their fixed 1e6 conversion, entry counts come from bounded in-memory slices, and the shared ZIP writer validates its own fixed-width casts)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## frequency-plan

- the absolute value of a product range that crosses DC inside the RF sweep folds into two branches reaching down to zero, never the naive endpoint-magnitude interval
- the diagonal product count at an IF matches the closed form and names the IF above which the commanded band carries none
- the required RF window, its image and the output sub-band an RF gap costs are exact inverses of one another on both sidebands
- an RF window that leaves a declared passband reports the uncovered sub-interval on the side it leaves from, and reports nothing when it is contained
- a declared cutoff rejects a product only when every folded branch lies wholly beyond it
- the required RF window is checked against the delivered passband, so a fixed LO that closes the commanded band passes and one 950 MHz lower fails naming the uncovered sub-interval and the output frequencies it costs
- a failed plan limit is a warning in advisory mode and a failure in gate mode, with the same message and the same typed row either way
- each enumerated product is classified against the output band and the declared cutoffs, with the leakage rows present and the wanted product distinguished from the co-channel ones
- a product whose signed frequency changes sign inside the required RF sweep is split into both folded branches, so it is seen to reach DC and lands in band where a single-interval fold would miss it
- a declared suppression entry is checked against the in-band limit at the co-channel product it names, and no level is claimed for any product the table omits
- the reported diagonal family matches the closed-form count at the band's low edge at several band positions and names the IF above which the band carries none
- the image sideband is placed and is called rejected only when a declared cutoff or the delivered passband actually excludes it
- each declaration publishes a typed report whose plans concatenate back into assertion order, one verdict per screen matching that assertion's pass/warn/fail, and (sideband either) publishes both sidebands high side first
- evaluating one declaration twice produces byte-identical assertions and structurally identical reports, so the analysis is a pure function of what was declared
- the parser requires a title, mode, output band, LO and mixer sense, bounds the enumeration order at nine, and refuses sum mixing rather than approximating it
- the authored Barracuda declaration round-trips through the parser into the same plan the fixture screens, with SI-suffixed frequencies and signed dBm resolved
- a low-side plan under an LO below the commanded band is refused as unrealizable rather than screened against a negative RF window
- completeness-waiver: empty inputs (the parser rejects a declaration without a title, a mode, an output band, an LO frequency, and a mixer sense before evaluation; a source range that does not contain its own delivered passband is refused with them)
- completeness-waiver: large inputs (one declaration enumerates at most the ninth-order square plus two leakage rows — 83 products — over a single required RF interval, admits at most 64 spur-table rows, and plans at most two sidebands)
- completeness-waiver: unauthorized access (an in-process calculation over an already-authorized parsed declaration with no request, file, socket, user, or write surface)
- completeness-waiver: i/o failure (the analysis performs no I/O and appends allocator-owned assertion messages; OutOfMemory is propagated)
- completeness-waiver: concurrent access (all state is stack-local or owned by the calling evaluator; the module holds no shared mutable object of any kind)
- completeness-waiver: malformed encoding (the existing s-expression parser supplies typed nodes; malformed forms, non-finite numbers, inverted intervals, non-integer or out-of-range orders, and sum mixing are rejected before evaluation)
- completeness-waiver: integer overflow (order loops are bounded by the parse-time nine-order cap, the product buffer is a fixed array sized from that cap, and the one float-to-integer conversion is guarded by its own floor comparison)
- completeness-waiver: panic-free (interval arithmetic is total over finite inputs, table lookup and level claims use optional/enum returns, and panic-freedom is also enforced repo-wide by Guardian's panic-budget snapshot)

## pll-loop

- AN-2548 active filter model retains the expected crossover and phase trend across Kvco
- phase detector polarity changes the feedback sign by 180 degrees
- dynamically formatted validation messages are released with their evaluator
- E24 synthesis jointly satisfies an authored divider/Kvco curve, tolerance corners, and ramp limit
- corrected-model synthesis still clears corner phase margin and the ramp limit
- the synthesis search is memoised on its complete input, so a design evaluated again runs it no second time and a changed value never reads the old answer
- pinned values snap onto the E24 grid at parse, so the printed decimal text round-trips to the search's bit-identical f64s, and a non-E24 value is kept verbatim rather than moved
- a pin whose key matches answers from its own values without consulting the search or its memo, and prints no re-pin offer
- a pin whose key no longer matches is ignored with a warning and the full search runs, so a pin can only skip recomputation and never change an answer
- a pin whose values are not the answer its key certifies is refused as stale, so a hand-authored pin cannot pass fabricated values off as the synthesized population
- a populated set with a synthesize clause is screened under the quantized I_CP schedule too, so a population that is neither the search winner nor a pin still prints its scheduled-face margins beside the fixed-I_CP face
- the BOM echo prints fractional catalogue values to a tenth rather than truncating them to whole units
- each declaration publishes a typed report carrying the numbers its assertion strings print, one verdict per screen matching that assertion's pass/warn/fail
- a pinned synthesis publishes a second population beside the fitted one, whose components, results and schedule are the pinned answer, and whose verdicts concatenate back into assertion order
- the open-loop trace is deterministically log-spaced over the solver's own span and reads back a phase margin inside the nominal sweep it accompanies
- charge-pump-full-scale is parsed as a positive authored current
- an authored charge-pump full scale rescales schedule currents without changing step choices
- completeness-waiver: empty inputs (the parser rejects a declaration without a name, complete component-role bindings, topology, PFD, charge pump, feedback divider, Kvco range, and op-amp GBW before evaluation)
- completeness-waiver: large inputs (one declaration resolves exactly seven named parts; validation sweeps a fixed 256 R/C corners, while optional synthesis admits at most 16 operating-curve points and uses a fixed 12,000-member deterministic E24 search plus bounded coordinate refinement from each of its best eight candidates, followed by exact tolerance verification)
- completeness-waiver: unauthorized access (an in-process calculation over an already-authorized evaluated DesignBlock with no request, file, socket, user, or write surface)
- completeness-waiver: i/o failure (the validator performs no I/O and appends allocator-owned assertion messages; OutOfMemory is propagated)
- completeness-waiver: concurrent access (all solver state is stack-local or owned by the calling evaluator; the one shared object is the process-lifetime synthesis memo, whose fixed entry table is read and written only under its own mutex and whose values are plain scalars)
- completeness-waiver: malformed encoding (the existing s-expression parser supplies typed nodes; malformed forms and non-finite or out-of-range numeric fields are rejected before evaluation)
- completeness-waiver: integer overflow (loop bounds are fixed constants except the seven-element tolerance mask, whose shift count is compile-time bounded)
- completeness-waiver: panic-free (component lookup, value parsing, and crossover failure use optional/error returns; panic-freedom is also enforced repo-wide by Guardian's panic-budget snapshot)

## review-profiles

- an authored (class …) wins over pin-name inference and unknown keys are rejected
- supply pins without voltage-range and decoupling checks, currents, or control-pin thresholds are named as unmet profile items
- a loop or mixer class demands its design-level analysis in gate mode
- completeness-waiver: empty inputs (a part with no library pinout yields no supply or control items, and an empty design yields no findings)
- completeness-waiver: large inputs (every walk is linear in the part's pins, requirements and declarations and propagates allocator failure)
- completeness-waiver: unauthorized access (profiles read the already-loaded design and library under the caller's project directory; authorization lives at the CLI entry points)
- completeness-waiver: i/o failure (an unreadable component or pinout file degrades to an empty pad list exactly as pin roles do)
- completeness-waiver: concurrent access (evaluation owns its arena and item list while reading an immutable design snapshot)
- completeness-waiver: malformed encoding (library parsing is upstream; a malformed pinout yields no pads and an unknown class key is rejected)
- completeness-waiver: integer overflow (item counts are bounded by allocator-backed slices and use no input-derived integer arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## waiver-register

- register tables are read only under a heading naming the board and only when the second column is Count
- drift lists every kind whose registered count differs from the release run's warning count, unrecognised categories included
- a table row with no leading pipe or more cells than fit is refused rather than parsed into misaligned columns
- completeness-waiver: empty inputs (an empty register or an empty readiness document yields no entries and no drift)
- completeness-waiver: large inputs (parsing is a single linear pass over lines and cells with fixed-size cell buffers)
- completeness-waiver: unauthorized access (the register arrives as an already-read document owned by the system manifest)
- completeness-waiver: i/o failure (this module performs no I/O; the document reader upstream reports failures)
- completeness-waiver: concurrent access (pure functions over caller-owned slices with no shared state)
- completeness-waiver: malformed encoding (a row whose count is not an integer is skipped and an unrecognised category is reported as drift)
- completeness-waiver: integer overflow (counts are parsed as usize and summed per kind from a bounded document)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)

## review-audit

- the rendered audit parses as safe review Markdown with no raw HTML
- regenerating into an existing audit keeps the reviewer's disposition cells for rows that are still rendered
- completeness-waiver: empty inputs (a design with no active parts, no findings and no layout renders the placeholder rows)
- completeness-waiver: large inputs (the findings register is capped and every cell is clipped on a codepoint boundary)
- completeness-waiver: unauthorized access (the audit reads the caller's project directory through the same evaluator and gate the CLI already exposes)
- completeness-waiver: i/o failure (an unavailable fabrication gate or ladder renders as unavailable instead of aborting the audit)
- completeness-waiver: concurrent access (collection owns its evaluator and arena; nothing is written)
- completeness-waiver: malformed encoding (readiness and ladder JSON that fails to parse leaves those sections unavailable)
- completeness-waiver: integer overflow (counts are tallied from bounded slices with no input-derived arithmetic)
- completeness-waiver: panic-free (panic-freedom is enforced repo-wide by guardian's panic-budget snapshot, not restated per section)
