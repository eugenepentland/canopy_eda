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

	// AddFootprint stages the supplied `kicad_mod` text into the board's
	// per-project library directory, registers eda-sync in fp-lib-table
	// if needed, then asks KiCad to instantiate the footprint via IPC
	// CreateItems with a LibraryIdentifier referencing that library.
	// `entryName` is the library entry the proto's LibraryIdentifier
	// will point at.
	//
	// We tried sending Definition.Items inline in the FootprintInstance
	// proto (the proto-canonical path); KiCad's CreateItems silently
	// drops the inline geometry when the LibraryIdentifier doesn't
	// resolve to a real library, leaving an empty footprint on the
	// board. Staging the .kicad_mod first is the only reliable way to
	// get a freshly-added fp to render with pads.
	AddFootprint(kicadMod, entryName, uuid, ref, value string, padNets [][2]string) error

	// SwapFootprint replaces the existing footprint at `uuid` with a
	// fresh instance of `entryName` (also staged from the supplied
	// kicad_mod text). Carries over canopy_uuid + custom Fields, ref,
	// value, position, orientation, and layer from the old fp; uses a
	// freshly-minted KiCad UUID so the delete and the new create don't
	// collide. Pad-net assignments arrive via the surrounding set_pad_net
	// ops the server emits after the swap.
	SwapFootprint(uuid, kicadMod, entryName string, padNets [][2]string) error

	// Remove stages the footprint for deletion in this commit.
	Remove(uuid string) error

	// Push commits the transaction. After this, KiCad records the change
	// as one undo step.
	Push() error

	// Close releases any held resources (NNG socket, etc.). Safe to call
	// multiple times.
	Close() error
}
