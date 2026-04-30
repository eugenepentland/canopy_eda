package kicad

import (
	"strings"

	"google.golang.org/protobuf/types/known/anypb"

	board_types "github.com/canopy/eda/tools/kicad-sync-go/internal/kicad/proto/board/board_types"
	base_types "github.com/canopy/eda/tools/kicad-sync-go/internal/kicad/proto/common/types/base_types"
)

func wrapPad(pad *board_types.Pad) (*anypb.Any, error) {
	return anypb.New(pad)
}

// buildFootprintInstance materialises a FootprintInstance proto from the
// structured FootprintDef the server hands us. Origin position, F.Cu
// layer, ref + value fields, and pads with their nets — enough for KiCad
// to render a valid footprint with correct routing targets.
func buildFootprintInstance(def *FootprintDef, uuid, ref, value string, padNets [][2]string) *board_types.FootprintInstance {
	netByPad := map[string]string{}
	for _, kv := range padNets {
		netByPad[kv[0]] = kv[1]
	}

	pads := make([]*base_types.KIID, 0)
	_ = pads // unused — pad IDs are auto-assigned by KiCad when omitted

	defPb := &board_types.Footprint{
		Id: &base_types.LibraryIdentifier{
			LibraryNickname: "eda-sync",
			EntryName:       def.Name,
		},
	}

	for _, pad := range def.Pads {
		anyPad, err := wrapPad(buildPad(pad, netByPad[pad.Number]))
		if err == nil {
			defPb.Items = append(defPb.Items, anyPad)
		}
	}

	fp := &board_types.FootprintInstance{
		Id:          &base_types.KIID{Value: uuid},
		Position:    &base_types.Vector2{}, // (0, 0) origin
		Orientation: &base_types.Angle{ValueDegrees: 0},
		Layer:       board_types.BoardLayer_BL_F_Cu,
		Definition:  defPb,
	}
	if ref != "" {
		ensureBoardTextString(ensureField(&fp.ReferenceField)).Text = ref
	}
	if value != "" {
		ensureBoardTextString(ensureField(&fp.ValueField)).Text = value
	}
	return fp
}

func buildPad(p PadDef, netName string) *board_types.Pad {
	pad := &board_types.Pad{
		Id:       &base_types.KIID{},
		Number:   p.Number,
		Type:     padTypeToProto(p.Type),
		Position: mmToVector2(p.Pos),
		PadStack: buildPadStack(p),
	}
	if netName != "" {
		pad.Net = &board_types.Net{Name: netName}
	}
	return pad
}

func buildPadStack(p PadDef) *board_types.PadStack {
	layer := layerNameToProto(firstLayer(p.Layers, p.Type))
	stackLayer := &board_types.PadStackLayer{
		Layer: layer,
		Shape: padShapeToProto(p.Shape),
		Size:  mmToVector2(p.Size),
	}
	if p.Shape == "roundrect" {
		stackLayer.CornerRoundingRatio = 0.25
	}
	stack := &board_types.PadStack{
		Type:         board_types.PadStackType_PST_NORMAL,
		Layers:       layersForType(p.Type),
		CopperLayers: []*board_types.PadStackLayer{stackLayer},
		Angle:        &base_types.Angle{ValueDegrees: p.Rotation},
	}
	if p.Drill > 0 {
		stack.Drill = &board_types.DrillProperties{
			StartLayer:    board_types.BoardLayer_BL_F_Cu,
			EndLayer:      board_types.BoardLayer_BL_B_Cu,
			Diameter:      mmToVector2([2]float64{p.Drill, p.Drill}),
		}
	}
	return stack
}

// firstLayer returns the primary copper layer for a pad given its declared
// `layers` array (may be empty) and pad type. SMD pads default to F.Cu;
// thru-hole defaults to F.Cu plus broadcast handled in layersForType.
func firstLayer(layers []string, padType string) string {
	for _, l := range layers {
		if strings.HasSuffix(l, ".Cu") {
			return l
		}
	}
	return "F.Cu"
}

// layersForType returns the BoardLayer set this pad participates in. SMD =
// front side only; thru-hole = front+back copper plus mask layers.
func layersForType(padType string) []board_types.BoardLayer {
	switch padType {
	case "thru_hole", "np_thru_hole":
		return []board_types.BoardLayer{
			board_types.BoardLayer_BL_F_Cu,
			board_types.BoardLayer_BL_B_Cu,
			board_types.BoardLayer_BL_F_Mask,
			board_types.BoardLayer_BL_B_Mask,
		}
	default: // smd
		return []board_types.BoardLayer{
			board_types.BoardLayer_BL_F_Cu,
			board_types.BoardLayer_BL_F_Paste,
			board_types.BoardLayer_BL_F_Mask,
		}
	}
}

func padTypeToProto(s string) board_types.PadType {
	switch s {
	case "smd":
		return board_types.PadType_PT_SMD
	case "thru_hole":
		return board_types.PadType_PT_PTH
	case "np_thru_hole":
		return board_types.PadType_PT_NPTH
	}
	return board_types.PadType_PT_SMD
}

func padShapeToProto(s string) board_types.PadStackShape {
	switch s {
	case "rect":
		return board_types.PadStackShape_PSS_RECTANGLE
	case "circle":
		return board_types.PadStackShape_PSS_CIRCLE
	case "oval":
		return board_types.PadStackShape_PSS_OVAL
	case "roundrect":
		return board_types.PadStackShape_PSS_ROUNDRECT
	}
	return board_types.PadStackShape_PSS_RECTANGLE
}

func layerNameToProto(s string) board_types.BoardLayer {
	switch s {
	case "F.Cu":
		return board_types.BoardLayer_BL_F_Cu
	case "B.Cu":
		return board_types.BoardLayer_BL_B_Cu
	case "F.Paste":
		return board_types.BoardLayer_BL_F_Paste
	case "F.Mask":
		return board_types.BoardLayer_BL_F_Mask
	case "B.Mask":
		return board_types.BoardLayer_BL_B_Mask
	case "F.SilkS":
		return board_types.BoardLayer_BL_F_SilkS
	case "B.SilkS":
		return board_types.BoardLayer_BL_B_SilkS
	}
	return board_types.BoardLayer_BL_F_Cu
}

func mmToVector2(p [2]float64) *base_types.Vector2 {
	return &base_types.Vector2{
		XNm: int64(p[0] * 1e6),
		YNm: int64(p[1] * 1e6),
	}
}
