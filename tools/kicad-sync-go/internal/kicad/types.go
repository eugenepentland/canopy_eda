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
	Pads          []Pad
}

// PadDef describes one pad of a footprint we're about to instantiate via
// IPC CreateItems. Coordinates are millimetres; rotation degrees. Mirrors
// the wire shape (eda.FootprintPad) but lives in the kicad package so the
// orchestrator can keep eda → kicad as a one-way dependency.
type PadDef struct {
	Number   string
	Type     string // smd | thru_hole | np_thru_hole
	Shape    string // rect | circle | oval | roundrect
	Pos      [2]float64
	Size     [2]float64
	Drill    float64
	Rotation float64
	Layers   []string
}

// FootprintDef is the input to AddFootprint / SwapFootprint — enough info
// to construct a KiCad FootprintInstance proto with valid pad geometry.
type FootprintDef struct {
	Name string
	Pads []PadDef
}
