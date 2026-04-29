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
// The agent treats UUID as the stable identity (sourced from the
// `canopy_uuid` custom field).
type Footprint struct {
	UUID          string
	Reference     string
	Value         string
	FootprintName string // KiCad library:name → name only
	Pads          []Pad
}
