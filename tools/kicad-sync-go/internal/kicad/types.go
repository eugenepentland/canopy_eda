// Package kicad is the KiCad 10 IPC client. The high-level Client interface
// hides the NNG REQ/REP + protobuf transport behind plain Go types so the
// rest of the agent (sync orchestrator, tests) is decoupled from the API
// surface.
//
// The real implementation in client.go uses go.nanomsg.org/mangos/v3 over
// the socket KiCad advertises via the KICAD_API_SOCKET env var, and
// protobuf messages generated from KiCad's api/proto/ tree (see
// scripts/gen-proto.sh). Tests use the in-process Fake from fake.go.
package kicad

// Pad describes one footprint pad as the agent reads/writes it.
type Pad struct {
	Number string
	Net    string // empty when unconnected
}

// Footprint is the subset of a KiCad footprint the sync algorithm needs.
//
// UUID is the project-stable identity sourced from the `canopy_uuid` custom
// field — this is what the server diffs against the design's instance IDs.
// Empty when the footprint hasn't been synced before.
//
// KicadUUID is the KiCad-internal handle that IPC mutation calls
// (SetField, SetPadNet, …) use to target the footprint. Always populated.
type Footprint struct {
	UUID          string
	KicadUUID     string
	Reference     string
	Value         string
	FootprintName string // KiCad library:name → name only
	// Fields carries every custom Field on the KiCad footprint, keyed by
	// the field name as KiCad has it (e.g. "MPN", "Manufacturer",
	// "canopy_uuid"). Posted up to the server so it can diff arbitrary
	// design properties against the board without the agent ever needing
	// to know which fields exist — adding a new BOM column becomes a
	// pure server-side change. UUID above is the same value as
	// Fields["canopy_uuid"], surfaced as a top-level convenience because
	// the server's `by_uuid` matching index keys on it directly.
	Fields map[string]string
	Pads   []Pad
}

// AddFootprint / SwapFootprint take their footprint geometry as
// proto-canonical JSON bytes (a `kiapi.board.types.Footprint` message)
// rather than a Go-side struct — see iface.go. The previous PadDef /
// FootprintDef helper structs went away when we moved geometry encoding
// to the server.
