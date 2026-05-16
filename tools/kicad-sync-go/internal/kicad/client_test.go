package kicad

import (
	"os"
	"testing"

	"google.golang.org/protobuf/types/known/anypb"

	board_types "github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad/proto/board/board_types"
	base_types "github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad/proto/common/types/base_types"
)

// TestSwapFootprintReplacesViaDeleteAndAdd pins the post-bug-discovery
// behaviour: KiCad's IPC UpdateItems silently no-ops Definition changes,
// so SwapFootprint has to delete the old fp and create a fresh one with
// the new geometry, using a freshly-minted KiCad UUID to dodge the
// CreateItems / DeleteItems collision that wiped J1/J4 in the original
// implementation.
//
// Required invariants exercised here:
//   - old kicad uuid lands in c.removed (so DeleteItems flushes it)
//   - exactly one new fp lands in c.added (CreateItems flushes it)
//   - the new fp has a different kicad uuid than the old one
//   - canopy_uuid is preserved on the new fp's Definition.Items
//   - cache aliases the old kicad uuid to the new fp so subsequent
//     set_field / set_pad_net ops in the same commit land on the new fp
//   - newly-created fp is NOT marked dirty (UpdateItems against a
//     UUID KiCad hasn't seen would error out)
func TestSwapFootprintReplacesViaDeleteAndAdd(t *testing.T) {
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
		isNew:   map[*board_types.FootprintInstance]struct{}{},
	}

	// SwapFootprint now stages the kicad_mod into a per-board library
	// dir before calling CreateItems. That needs an absolute board path
	// — set it via the SetBoardPath path the orchestrator uses in
	// production, not by mutating c.doc directly.
	tmpBoard := t.TempDir() + "/board.kicad_pcb"
	c.boardPathAbs = tmpBoard
	const kicadMod = `(footprint "NEW_FOOTPRINT" (version 20221018) (generator pcbnew) (layer "F.Cu"))`
	defJSON := []byte(`{"id":{"libraryNickname":"eda-sync","entryName":"NEW_FOOTPRINT"},"items":[]}`)
	if err := c.SwapFootprint(kid, defJSON, kicadMod, "NEW_FOOTPRINT", [][2]string{{"1", "VDD"}}); err != nil {
		t.Fatalf("SwapFootprint: %v", err)
	}

	if _, ok := c.removed[kid]; !ok {
		t.Errorf("expected old kicad uuid %q in c.removed so DeleteItems flushes it", kid)
	}
	if len(c.added) != 1 {
		t.Fatalf("expected exactly 1 new fp in c.added, got %d", len(c.added))
	}
	newFp := c.added[0]
	if newFp.GetId().GetValue() == "" {
		t.Error("new fp must have a fresh KiCad UUID — CreateItems against an empty id is undefined")
	}
	if newFp.GetId().GetValue() == kid {
		t.Errorf("new fp reused the deleted kicad uuid %q — that's the original collision bug", kid)
	}
	if _, dirtyMarked := c.dirty[newFp.GetId().GetValue()]; dirtyMarked {
		t.Error("new fp's kicad uuid must not be in c.dirty — UpdateItems against a not-yet-created UUID errors out")
	}
	if c.cache[kid] != newFp {
		t.Errorf("cache[%q] should alias to the new fp so set_field/set_pad_net follow-ups land on the swap target", kid)
	}
	if c.cache[newFp.GetId().GetValue()] != newFp {
		t.Errorf("cache[%q] should point at the new fp", newFp.GetId().GetValue())
	}

	gotName := newFp.GetDefinition().GetId().GetEntryName()
	if gotName != "NEW_FOOTPRINT" {
		t.Errorf("library entry name on new fp: got %q, want %q", gotName, "NEW_FOOTPRINT")
	}
	gotLib := newFp.GetDefinition().GetId().GetLibraryNickname()
	if gotLib != edaSyncLibName {
		t.Errorf("library nickname on new fp: got %q, want %q", gotLib, edaSyncLibName)
	}
	canopyAfter := readCanopyUUID(t, newFp)
	if canopyAfter != cid {
		t.Errorf("canopy_uuid lost in swap: got %q, want %q", canopyAfter, cid)
	}
	// The kicad_mod must have landed in the per-board library dir so
	// KiCad's CreateItems can resolve the LibraryIdentifier — without
	// this file, the swap renders an empty footprint.
	staged := tmpBoard[:len(tmpBoard)-len("/board.kicad_pcb")] + "/" + edaSyncLibDir + "/NEW_FOOTPRINT.kicad_mod"
	if _, err := os.Stat(staged); err != nil {
		t.Errorf("expected staged kicad_mod at %s: %v", staged, err)
	}
}

// TestSwapFootprintCreatesAtOriginAndQueuesMove pins the create-at-origin
// strategy that dodges KiCad's IPC bug. On CreateItems with a
// FootprintInstance whose Position is non-zero, inline Pad / Field /
// BoardGraphicShape positions get treated as ABSOLUTE board coords —
// proto docs claim "relative to the parent footprint's origin" but the
// implementation disagrees. Working around the bug per-item-type would
// take 100+ lines and a math.Sin call; creating at (0, 0) lets KiCad
// store every inner item with the correct relative coord on first pass.
// A follow-up UpdateItems in Push() snaps the new fp to the swapped-out
// fp's placement, and KiCad shifts every inner item along for the ride
// while keeping their now-correct relatives intact.
func TestSwapFootprintCreatesAtOriginAndQueuesMove(t *testing.T) {
	const kid = "k-uuid-old"
	const (
		oldX  int64 = 144_500_000
		oldY  int64 = 180_000_000
		oldDeg       = 90.0
	)

	originalPad := mustWrapPad(t, &board_types.Pad{
		Number:   "1",
		Position: &base_types.Vector2{XNm: -780_000, YNm: 0},
	})
	old := &board_types.FootprintInstance{
		Id:          &base_types.KIID{Value: kid},
		Position:    &base_types.Vector2{XNm: oldX, YNm: oldY},
		Orientation: &base_types.Angle{ValueDegrees: oldDeg},
		Layer:       board_types.BoardLayer_BL_B_Cu,
		Definition: &board_types.Footprint{
			Id:    &base_types.LibraryIdentifier{LibraryNickname: "old-lib", EntryName: "OLD"},
			Items: []*anypb.Any{originalPad},
		},
	}
	c := &realClient{
		cache:   map[string]*board_types.FootprintInstance{kid: old},
		dirty:   map[string]struct{}{},
		removed: map[string]struct{}{},
		isNew:   map[*board_types.FootprintInstance]struct{}{},
	}
	tmpBoard := t.TempDir() + "/board.kicad_pcb"
	c.boardPathAbs = tmpBoard

	const kicadMod = `(footprint "NEW" (version 20221018) (generator pcbnew) (layer "F.Cu"))`
	defJSON := []byte(`{"id":{"libraryNickname":"eda-sync","entryName":"NEW"},"items":[]}`)
	if err := c.SwapFootprint(kid, defJSON, kicadMod, "NEW", [][2]string{{"1", "VDD"}}); err != nil {
		t.Fatalf("SwapFootprint: %v", err)
	}

	if len(c.added) != 1 {
		t.Fatalf("expected 1 new fp in c.added, got %d", len(c.added))
	}
	newFp := c.added[0]

	// Invariant 1: new fp goes into CreateItems with Position(0, 0) and
	// Orientation(0). Send-as-zero is what lets KiCad store inline item
	// relative coords correctly on first pass.
	if px := newFp.GetPosition().GetXNm(); px != 0 {
		t.Errorf("new fp Position.X should be 0 at CreateItems time, got %d", px)
	}
	if py := newFp.GetPosition().GetYNm(); py != 0 {
		t.Errorf("new fp Position.Y should be 0 at CreateItems time, got %d", py)
	}
	if deg := newFp.GetOrientation().GetValueDegrees(); deg != 0 {
		t.Errorf("new fp Orientation should be 0 at CreateItems time, got %v", deg)
	}

	// Invariant 2: layer carries over verbatim — we don't trigger a
	// B.Cu→F.Cu round-trip that would re-mirror everything.
	if newFp.GetLayer() != board_types.BoardLayer_BL_B_Cu {
		t.Errorf("layer should carry over from old fp, got %v", newFp.GetLayer())
	}

	// Invariant 3: target placement is queued for the post-CreateItems
	// UpdateItems pass — old position and orientation, exactly.
	place, ok := c.pendingPlacements[newFp]
	if !ok {
		t.Fatalf("SwapFootprint did not queue a pending placement for the new fp")
	}
	if place.position.GetXNm() != oldX || place.position.GetYNm() != oldY {
		t.Errorf("queued placement position = %+v, want (%d, %d)", place.position, oldX, oldY)
	}
	if place.orientation.GetValueDegrees() != oldDeg {
		t.Errorf("queued placement orientation = %v, want %v", place.orientation.GetValueDegrees(), oldDeg)
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
