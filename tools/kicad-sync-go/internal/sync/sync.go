// Package sync orchestrates one click of the EDA Sync button: read board
// via IPC, POST to /api/sync-plan, apply returned ops in one IPC commit.
package sync

import (
	"fmt"

	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/eda"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad"
)

// Options bundles per-click flags so additions don't churn the Run
// signature. Most syncs leave both fields zero.
type Options struct {
	// Prune removes board footprints whose canopy_uuid no longer maps to
	// any design instance. Off by default so a stray "Save → click sync"
	// can't silently nuke user-placed parts.
	Prune bool
	// MigrateHeuristic enables (parent_path, footprint_name, value)
	// matching as a third-tier fallback after canopy_uuid + ref_des. The
	// agent's `--migrate` flag wires this on; intended as a one-shot
	// repair when a legacy board's ref-des numbering has drifted away
	// from the current schematic.
	MigrateHeuristic bool
}

// Run pulls board state, asks the server for a plan, and applies the ops.
// Returns the parsed response so the caller can show a result toast.
func Run(client *eda.Client, kc kicad.Client, design string, opts Options) (*eda.SyncPlanResponse, error) {
	fps, err := kc.ListFootprints()
	if err != nil {
		return nil, fmt.Errorf("list footprints: %w", err)
	}

	req := eda.SyncPlanRequest{
		Board:            toBoardFps(fps),
		PruneStale:       opts.Prune,
		MigrateHeuristic: opts.MigrateHeuristic,
	}
	plan, err := client.SyncPlan(design, req)
	if err != nil {
		return nil, err
	}

	if err := apply(kc, design, plan); err != nil {
		return plan, fmt.Errorf("apply ops: %w", err)
	}
	return plan, nil
}

func toBoardFps(fps []kicad.Footprint) []eda.BoardFp {
	out := make([]eda.BoardFp, 0, len(fps))
	for _, fp := range fps {
		pads := make([]eda.PadAssign, 0, len(fp.Pads))
		for _, p := range fp.Pads {
			pads = append(pads, eda.PadAssign{Number: p.Number, Net: p.Net})
		}
		out = append(out, eda.BoardFp{
			UUID:          fp.UUID,
			KicadUUID:     fp.KicadUUID,
			Ref:           fp.Reference,
			Value:         fp.Value,
			FootprintName: fp.FootprintName,
			Fields:        fp.Fields,
			Pads:          pads,
		})
	}
	return out
}

func apply(kc kicad.Client, design string, plan *eda.SyncPlanResponse) error {
	if len(plan.Ops) == 0 {
		return nil
	}
	msg := fmt.Sprintf("EDA sync: %s @ v%d", design, plan.DesignVersion)
	if err := kc.Begin(msg); err != nil {
		return err
	}
	for _, op := range plan.Ops {
		if err := applyOp(kc, op); err != nil {
			return err
		}
	}
	return kc.Push()
}

func applyOp(kc kicad.Client, op eda.Op) error {
	switch op.Op {
	case "set_field":
		return kc.SetField(op.UUID, op.Field, op.Value)
	case "set_pad_net":
		return kc.SetPadNet(op.UUID, op.Pad, op.Net)
	case "add":
		return kc.AddFootprint(op.KicadMod, op.FootprintName, op.UUID, op.Ref, op.Value, op.PadNets)
	case "swap_footprint":
		return kc.SwapFootprint(op.UUID, op.KicadMod, op.NewFootprintName, op.PadNets)
	case "remove":
		return kc.Remove(op.UUID)
	case "flag_stale":
		// Informational only — no IPC mutation. The caller surfaces these
		// via the result notification.
		return nil
	default:
		// Unknown ops are skipped rather than aborted: the server may
		// extend the protocol in ways the older client doesn't know yet.
		return nil
	}
}
