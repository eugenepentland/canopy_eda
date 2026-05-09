package kicad

// Client is the surface the sync orchestrator depends on. The real
// implementation talks to KiCad over NNG REQ/REP; the Fake is a Go-only
// stand-in used in tests.
//
// Mutations are buffered between Begin and Push so KiCad records the whole
// sync as a single undoable commit.
type Client interface {
	// BoardPath returns the filename of the currently-open PCB. Used to
	// load the per-board config file.
	BoardPath() (string, error)

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

	// AddFootprint instantiates a footprint at the origin from the proto-
	// canonical JSON `defJSON` (a `kiapi.board.types.Footprint` message),
	// stamps the canopy uuid as the KiCad-internal Id, applies pad-net
	// assignments, and stages it for commit. Decoding is handled via
	// protojson so this function carries no geometry-aware code — adding
	// new pad shapes / types / layers is a server-only change.
	AddFootprint(defJSON []byte, uuid, ref, value string, padNets [][2]string) error

	// SwapFootprint replaces the Definition on uuid in place with one
	// decoded from `defJSON`, preserving the cached fp's identity (KiCad
	// UUID, ref, value, position, custom Field entries like canopy_uuid).
	// Pad-net assignments are stamped onto the decoded pads after
	// deserialization.
	SwapFootprint(uuid string, defJSON []byte, padNets [][2]string) error

	// Remove stages the footprint for deletion in this commit.
	Remove(uuid string) error

	// Push commits the transaction. After this, KiCad records the change
	// as one undo step.
	Push() error

	// Close releases any held resources (NNG socket, etc.). Safe to call
	// multiple times.
	Close() error
}
