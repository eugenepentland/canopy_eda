package kicad

// Client is the surface the sync orchestrator depends on. The real
// implementation talks to KiCad over NNG REQ/REP; the Fake is a Go-only
// stand-in used in tests.
//
// Mutations are buffered between Begin and Push so KiCad records the whole
// sync as a single undoable commit.
type Client interface {
	// BoardPath returns the absolute path of the currently-open PCB.
	// On Windows KiCad's GetOpenDocuments returns just the bare
	// filename; the orchestrator threads the absolute path in via
	// SetBoardPath when it has one (i.e. when called with --board).
	BoardPath() (string, error)

	// SetBoardPath records the orchestrator's authoritative absolute
	// board path. Used by per-board library staging since
	// `filepath.Dir("foo.kicad_pcb")` is just "." and would write
	// `eda-sync.pretty/` to the agent's CWD instead of next to the
	// project. No-op when called with an empty string.
	SetBoardPath(absPath string)

	// ListFootprints returns every footprint on the open board.
	ListFootprints() ([]Footprint, error)

	// Begin opens a transaction. All subsequent Set/Add/Remove calls are
	// buffered until Push is called.
	Begin(message string) error

	// SetField updates a custom field (or the special "reference" / "value"
	// fields) on the footprint identified by uuid.
	SetField(uuid, field, value string) error

	// SetPadNet sets the net assignment of one pad on `uuid`.
	SetPadNet(uuid, padNumber, netName string) error

	// AddFootprint instantiates a footprint from the proto-canonical
	// `defJSON` (a `kiapi.board.types.Footprint` message containing the
	// pad geometry) plus the verbatim `kicadMod` text. The agent stages
	// the kicadMod into the board's per-project library directory and
	// registers eda-sync in fp-lib-table so the LibraryIdentifier
	// resolves at CreateItems time, then sends a FootprintInstance with
	// inline Items (decoded from defJSON) so KiCad populates pads in
	// the same commit. Without inline Items, KiCad's CreateItems
	// produces a placeholder with `pads=0` and only fills geometry on
	// a subsequent "Update Footprint(s) From Library" action.
	// xNm/yNm is the staging position the new fp is moved to after
	// CreateItems (0,0 = no hint → stays at the origin).
	AddFootprint(defJSON []byte, kicadMod, entryName, uuid, ref, value string, padNets [][2]string, xNm, yNm int64) error

	// CreateBoardItem creates a standalone board object from a proto-
	// canonical JSON Any (with @type), e.g. a BoardGraphicShape rectangle
	// or a BoardText label. Used to draw the per-section staging boxes +
	// labels on Dwgs.User. The item is buffered and flushed via CreateItems
	// in the same commit as the added footprints.
	CreateBoardItem(itemJSON []byte) error

	// SwapFootprint replaces the existing footprint at `uuid` with a
	// fresh instance of `entryName`. defJSON carries the new
	// Definition (decoded inline so geometry shows up immediately);
	// kicadMod is staged into the per-board library so the
	// LibraryIdentifier on the new fp resolves on subsequent reads.
	// Carries over canopy_uuid + custom Fields, ref, value, position,
	// orientation, and layer from the old fp; uses a freshly-minted
	// KiCad UUID so the delete and the new create don't collide.
	SwapFootprint(uuid string, defJSON []byte, kicadMod, entryName string, padNets [][2]string) error

	// Remove stages the footprint for deletion in this commit.
	Remove(uuid string) error

	// SetLocked toggles KiCad's "Lock footprint" flag (the padlock
	// overlay in the PCB editor). The sync server emits set_locked=true
	// alongside flag_stale so orphan footprints are visually obvious in
	// the board view; the user can unlock + delete from there.
	SetLocked(uuid string, locked bool) error

	// Push commits the transaction. After this, KiCad records the change
	// as one undo step.
	Push() error

	// Close releases any held resources (NNG socket, etc.). Safe to call
	// multiple times.
	Close() error

	// Warnings returns non-fatal degradations that occurred during the
	// most recent Push — primarily TOOL_ACTION names KiCad rejected (e.g.
	// "Update Footprint(s) From Library" renamed in a KiCad bump), where
	// the apply succeeded *structurally* but a follow-on refresh that
	// keeps the board in lockstep with the design didn't fire. Strict
	// mode treats a non-empty result as a failed sync so silent staleness
	// doesn't accumulate across versions. Cleared by the next Begin.
	Warnings() []string
}
