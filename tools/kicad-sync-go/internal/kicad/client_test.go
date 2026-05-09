package kicad

import (
	"testing"

	"google.golang.org/protobuf/types/known/anypb"

	board_types "github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad/proto/board/board_types"
	base_types "github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad/proto/common/types/base_types"
)

// TestSwapFootprintMutatesInPlace pins the fix for the bug that wiped
// J1/J4 from the cyclops breakout on the second sync click: SwapFootprint
// used to queue both a delete and a create on the SAME KiCad UUID, which
// KiCad's IPC handles inconsistently — one path removed the original and
// dropped the canopy_uuid custom field, leaving the next sync with a
// footprint that couldn't be UUID-matched and (eventually) made the
// design appear stale. The correct behavior is to update the cached
// footprint's Definition in place so Push flushes a single UpdateItems
// call.
func TestSwapFootprintMutatesInPlace(t *testing.T) {
	const kid = "k-uuid-1"
	const cid = "canopy-uuid-1"

	canopyField := mustWrapField(t, &board_types.Field{
		Name: "canopy_uuid",
		Text: &board_types.BoardText{Text: &base_types.Text{Text: cid}},
	})
	originalPad := mustWrapPad(t, &board_types.Pad{
		Number: "1",
		Net:    &board_types.Net{Name: "OLD_NET"},
	})

	fp := &board_types.FootprintInstance{
		Id: &base_types.KIID{Value: kid},
		Definition: &board_types.Footprint{
			Id: &base_types.LibraryIdentifier{
				LibraryNickname: "old-lib",
				EntryName:       "OLD_FOOTPRINT",
			},
			Items: []*anypb.Any{originalPad, canopyField},
		},
	}

	c := &realClient{
		cache:   map[string]*board_types.FootprintInstance{kid: fp, cid: fp},
		dirty:   map[string]struct{}{},
		removed: map[string]struct{}{},
	}

	defJSON := []byte(`{
		"id": {"libraryNickname": "eda-sync", "entryName": "NEW_FOOTPRINT"},
		"items": [
			{"@type":"type.googleapis.com/kiapi.board.types.Pad","id":{},"number":"1","type":"PT_SMD","position":{"xNm":-1000000,"yNm":0},"padStack":{"type":"PST_NORMAL","layers":["BL_F_Cu","BL_F_Paste","BL_F_Mask"],"copperLayers":[{"layer":"BL_F_Cu","shape":"PSS_RECTANGLE","size":{"xNm":1000000,"yNm":1000000}}],"angle":{"valueDegrees":0}}},
			{"@type":"type.googleapis.com/kiapi.board.types.Pad","id":{},"number":"2","type":"PT_SMD","position":{"xNm":1000000,"yNm":0},"padStack":{"type":"PST_NORMAL","layers":["BL_F_Cu","BL_F_Paste","BL_F_Mask"],"copperLayers":[{"layer":"BL_F_Cu","shape":"PSS_RECTANGLE","size":{"xNm":1000000,"yNm":1000000}}],"angle":{"valueDegrees":0}}}
		]
	}`)
	if err := c.SwapFootprint(kid, defJSON, [][2]string{{"1", "VDD"}, {"2", "GND"}}); err != nil {
		t.Fatalf("SwapFootprint: %v", err)
	}

	if _, ok := c.removed[kid]; ok {
		t.Errorf("expected no entry in c.removed for kicad UUID %q after swap; the bug deletes-and-recreates on the same UUID", kid)
	}
	if len(c.added) != 0 {
		t.Errorf("expected no entries in c.added after swap, got %d", len(c.added))
	}
	if _, ok := c.dirty[kid]; !ok {
		t.Errorf("expected c.dirty to contain kicad UUID %q so Push flushes the in-place update", kid)
	}

	gotName := fp.GetDefinition().GetId().GetEntryName()
	if gotName != "NEW_FOOTPRINT" {
		t.Errorf("library entry name not updated: got %q, want %q", gotName, "NEW_FOOTPRINT")
	}

	canopyAfter := readCanopyUUID(t, fp)
	if canopyAfter != cid {
		t.Errorf("canopy_uuid lost during swap: got %q, want %q — next sync would fail UUID match and treat the footprint as stale", canopyAfter, cid)
	}
}

func readCanopyUUID(t *testing.T, fp *board_types.FootprintInstance) string {
	t.Helper()
	for _, item := range fp.GetDefinition().GetItems() {
		var f board_types.Field
		if err := item.UnmarshalTo(&f); err != nil {
			continue
		}
		if f.GetName() == fieldCanopyUUID {
			return f.GetText().GetText().GetText()
		}
	}
	return ""
}

func mustWrapPad(t *testing.T, p *board_types.Pad) *anypb.Any {
	t.Helper()
	a, err := anypb.New(p)
	if err != nil {
		t.Fatalf("wrap pad: %v", err)
	}
	return a
}

func mustWrapField(t *testing.T, f *board_types.Field) *anypb.Any {
	t.Helper()
	a, err := anypb.New(f)
	if err != nil {
		t.Fatalf("wrap field: %v", err)
	}
	return a
}
