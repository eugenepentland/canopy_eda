// Package sync orchestrates one click of the EDA Sync button: read board
// via IPC, POST to /api/sync-plan, apply returned ops in one IPC commit.
package sync

import (
	"fmt"

	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/eda"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/synclog"
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
	synclog.Logf("Run design=%q prune=%v migrate=%v", design, opts.Prune, opts.MigrateHeuristic)
	fps, err := kc.ListFootprints()
	if err != nil {
		synclog.Logf("ListFootprints failed: %v", err)
		return nil, fmt.Errorf("list footprints: %w", err)
	}
	synclog.Logf("ListFootprints returned %d fps", len(fps))
	for _, fp := range fps {
		synclog.Logf("  fp ref=%q kid=%q canopy=%q name=%q pads=%d fields=%d",
			fp.Reference, fp.KicadUUID, fp.UUID, fp.FootprintName, len(fp.Pads), len(fp.Fields))
	}

	req := eda.SyncPlanRequest{
		Board:            toBoardFps(fps),
		PruneStale:       opts.Prune,
		MigrateHeuristic: opts.MigrateHeuristic,
	}
	synclog.Logf("POST /api/sync-plan/%s with %d board fps", design, len(req.Board))
	plan, err := client.SyncPlan(design, req)
	if err != nil {
		synclog.Logf("SyncPlan request failed: %v", err)
		return nil, err
	}
	synclog.Logf("SyncPlan returned: design_version=%d ops=%d summary=%+v",
		plan.DesignVersion, len(plan.Ops), plan.Summary)
	for i, op := range plan.Ops {
		synclog.Logf("  op[%d] %s uuid=%q ref=%q field=%q value=%q pad=%q net=%q fp_name=%q new_name=%q kicad_mod_len=%d pad_nets=%d",
			i, op.Op, op.UUID, op.Ref, op.Field, op.Value, op.Pad, op.Net,
			op.FootprintName, op.NewFootprintName, len(op.KicadMod), len(op.PadNets))
	}

	if err := apply(kc, design, plan); err != nil {
		synclog.Logf("apply ops failed: %v", err)
		return plan, fmt.Errorf("apply ops: %w", err)
	}
	synclog.Logf("apply ops completed")
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
		return kc.AddFootprint(op.FootprintDef, op.KicadMod, op.FootprintName, op.UUID, op.Ref, op.Value, op.PadNets)
	case "swap_footprint":
		return kc.SwapFootprint(op.UUID, op.FootprintDef, op.KicadMod, op.NewFootprintName, op.PadNets)
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
