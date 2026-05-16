// Package sync orchestrates one click of the EDA Sync button: read board
// via IPC, POST to /api/sync-plan, apply returned ops in one IPC commit.
package sync

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

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
	// DryRun fetches the plan and logs every op via synclog but skips the
	// IPC apply step. Lets the user inspect a finished-board diff before
	// any add / swap_footprint / remove can disturb existing placements.
	DryRun bool
}

// StaleEntry is one row in the `<board>.stale.json` sidecar: a board
// footprint the server flagged as no-longer-in-the-design, with enough
// identifying info that the user can locate it in KiCad and decide
// whether to delete it.
type StaleEntry struct {
	Ref           string `json:"ref"`
	KicadUUID     string `json:"kicad_uuid"`
	CanopyUUID    string `json:"canopy_uuid,omitempty"`
	FootprintName string `json:"footprint_name,omitempty"`
	Value         string `json:"value,omitempty"`
}

// StaleSidecar is the on-disk shape of `<board>.stale.json`. Written
// next to the .kicad_pcb on every sync (including --dry-run) so the user
// always has an up-to-date "what's no longer in the design" list. The
// file is rewritten in full each time — an empty Stale slice with a
// fresh timestamp signals "everything matches" without needing a
// separate "clean" sentinel.
type StaleSidecar struct {
	Design     string       `json:"design"`
	LastSync   string       `json:"last_sync_at"`
	DryRun     bool         `json:"dry_run"`
	Total      int          `json:"stale_count"`
	Stale      []StaleEntry `json:"stale"`
}

// Run pulls board state, asks the server for a plan, and applies the ops.
// Returns the parsed response so the caller can show a result toast.
// boardPath is used to write the `<board>.stale.json` sidecar listing
// every footprint the server flagged as no-longer-in-the-design.
func Run(client *eda.Client, kc kicad.Client, boardPath, design string, opts Options) (*eda.SyncPlanResponse, error) {
	synclog.Logf("Run design=%q prune=%v migrate=%v dry_run=%v", design, opts.Prune, opts.MigrateHeuristic, opts.DryRun)
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

	// Write the stale sidecar BEFORE applying — even a failed apply
	// shouldn't lose the orphan list, and a dry-run still wants the
	// sidecar so the user can inspect what would be flagged.
	if boardPath != "" {
		if err := writeStaleSidecar(boardPath, design, plan, fps, opts.DryRun); err != nil {
			synclog.Logf("WriteStaleSidecar failed (non-fatal): %v", err)
		}
	}

	if opts.DryRun {
		synclog.Logf("dry-run: skipping apply of %d ops", len(plan.Ops))
		return plan, nil
	}

	if err := apply(kc, design, plan); err != nil {
		synclog.Logf("apply ops failed: %v", err)
		return plan, fmt.Errorf("apply ops: %w", err)
	}
	synclog.Logf("apply ops completed")
	return plan, nil
}

// writeStaleSidecar rewrites `<boardPath>.stale.json` with the current
// orphan list. Failures are logged but never abort the sync — losing a
// sidecar write is annoying, not catastrophic, and a sync that aborted
// mid-apply because of a disk issue on a sidecar would be worse than
// just continuing.
func writeStaleSidecar(boardPath, design string, plan *eda.SyncPlanResponse, fps []kicad.Footprint, dryRun bool) error {
	// Build kid → board fp map for op→entry enrichment (footprint name,
	// value, canopy_uuid). The server's flag_stale op only carries the
	// kicad uuid + ref, which alone isn't enough to disambiguate a list
	// of "C81" candidates by eye.
	byKid := make(map[string]kicad.Footprint, len(fps))
	for _, fp := range fps {
		byKid[fp.KicadUUID] = fp
	}
	var stale []StaleEntry
	for _, op := range plan.Ops {
		if op.Op != "flag_stale" {
			continue
		}
		entry := StaleEntry{Ref: op.Ref, KicadUUID: op.UUID}
		if bfp, ok := byKid[op.UUID]; ok {
			entry.CanopyUUID = bfp.UUID
			entry.FootprintName = bfp.FootprintName
			entry.Value = bfp.Value
		}
		stale = append(stale, entry)
	}
	if stale == nil {
		stale = []StaleEntry{}
	}
	sidecar := StaleSidecar{
		Design:   design,
		LastSync: time.Now().UTC().Format(time.RFC3339),
		DryRun:   dryRun,
		Total:    len(stale),
		Stale:    stale,
	}
	body, err := json.MarshalIndent(sidecar, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal stale sidecar: %w", err)
	}
	body = append(body, '\n')
	path := boardPath + ".stale.json"
	if err := os.WriteFile(path, body, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	synclog.Logf("wrote stale sidecar: %s (%d entries)", path, len(stale))
	return nil
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
			Locked:        fp.Locked,
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
	case "set_locked":
		if op.Locked == nil {
			return nil
		}
		return kc.SetLocked(op.UUID, *op.Locked)
	case "flag_stale":
		// Informational only — no IPC mutation. The caller surfaces these
		// via the result notification + the <board>.stale.json sidecar.
		// Visual flagging happens via the separate set_locked op the
		// server emits alongside flag_stale.
		return nil
	default:
		// Unknown ops are skipped rather than aborted: the server may
		// extend the protocol in ways the older client doesn't know yet.
		return nil
	}
}
