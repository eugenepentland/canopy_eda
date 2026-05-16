package sync_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/eda"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/sync"
)

// stubKicadMod returns a minimal `(footprint …)` S-expression with the
// supplied library entry name. Tests only inspect FootprintName via the
// Fake, so we don't need real geometry — the agent's add / swap path
// just stages this verbatim into the per-board library dir.
func stubKicadMod(entryName string) string {
	return fmt.Sprintf(`(footprint %q (version 20221018) (generator pcbnew) (layer "F.Cu"))`, entryName)
}

// stubFootprintDef returns the proto-canonical JSON shape the agent
// expects on `add` / `swap_footprint` ops — minimal Footprint message
// with no Items. The Fake's AddFootprint/SwapFootprint don't actually
// decode it; this is just here so the wire round-trips cleanly.
func stubFootprintDef(entryName string) []byte {
	return fmt.Appendf(nil, `{"id":{"libraryNickname":"eda-sync","entryName":%q},"items":[]}`, entryName)
}

// fakeServer hands back the canned response and records the body it received.
func fakeServer(t *testing.T, resp eda.SyncPlanResponse, gotReq *eda.SyncPlanRequest) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
			t.Errorf("missing/wrong auth header: %q", got)
		}
		var body eda.SyncPlanRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		*gotReq = body
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
}

// TestRequestCarriesBothUUIDs covers the wire-format change: the agent
// must send the KiCad-internal UUID alongside the canopy UUID so the
// server can target ops back at the right footprint, even on legacy
// boards where canopy_uuid is empty or in the old long-form.
func TestRequestCarriesBothUUIDs(t *testing.T) {
	board := []kicad.Footprint{
		{UUID: "8char001", KicadUUID: "kicad-0001", Reference: "C1", Value: "10nF",
			FootprintName: "C_0402"},
		// Legacy: canopy_uuid never set (e.g. user-placed mechanical).
		{UUID: "", KicadUUID: "kicad-0002", Reference: "MH1", Value: "",
			FootprintName: "MountingHole_3.2mm"},
	}
	kc := kicad.NewFake("/tmp/test.kicad_pcb", board)

	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, eda.SyncPlanResponse{}, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "", "demo", sync.Options{}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(gotReq.Board) != 2 {
		t.Fatalf("expected 2 board entries, got %d", len(gotReq.Board))
	}
	if gotReq.Board[0].UUID != "8char001" || gotReq.Board[0].KicadUUID != "kicad-0001" {
		t.Errorf("entry 0 wrong UUIDs: %+v", gotReq.Board[0])
	}
	if gotReq.Board[1].UUID != "" || gotReq.Board[1].KicadUUID != "kicad-0002" {
		t.Errorf("entry 1 wrong UUIDs (legacy mechanical should ship empty canopy + real kicad): %+v", gotReq.Board[1])
	}
}

// TestSetFieldByKicadUUIDResolves covers the apply-side fix: server-emitted
// ops target a footprint by its KiCad-internal UUID; the agent's lookup
// must resolve that to the same slot whether the footprint already has a
// canopy_uuid or not. Without this, every matched footprint silently
// no-ops (the original bug).
func TestSetFieldByKicadUUIDResolves(t *testing.T) {
	board := []kicad.Footprint{
		{UUID: "", KicadUUID: "kicad-xyz", Reference: "R7", Value: "1k",
			FootprintName: "R_0402",
			Pads: []kicad.Pad{{Number: "1"}, {Number: "2"}}},
	}
	kc := kicad.NewFake("/tmp/test.kicad_pcb", board)

	planResp := eda.SyncPlanResponse{
		DesignVersion: 1,
		Summary:       eda.Summary{Updated: 1},
		Ops: []eda.Op{
			// Server emits ops keyed by the KiCad-internal UUID since the
			// footprint has no canopy_uuid yet.
			{Op: "set_field", UUID: "kicad-xyz", Field: "canopy_uuid", Value: "abc12345"},
			{Op: "set_field", UUID: "kicad-xyz", Field: "value", Value: "4.7k"},
		},
	}
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "", "demo", sync.Options{}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if kc.Footprints[0].UUID != "abc12345" {
		t.Errorf("canopy_uuid not backfilled: %q", kc.Footprints[0].UUID)
	}
	if kc.Footprints[0].Value != "4.7k" {
		t.Errorf("value not updated: %q", kc.Footprints[0].Value)
	}
}

func TestPureUpdateAppliesSetField(t *testing.T) {
	board := []kicad.Footprint{
		{UUID: "u-r1", Reference: "R1", Value: "1k", FootprintName: "R_0402",
			Pads: []kicad.Pad{{Number: "1", Net: "VDD"}, {Number: "2", Net: "GND"}}},
	}
	kc := kicad.NewFake("/tmp/test.kicad_pcb", board)

	planResp := eda.SyncPlanResponse{
		DesignVersion: 7,
		Summary:       eda.Summary{Updated: 1},
		Ops: []eda.Op{
			{Op: "set_field", UUID: "u-r1", Field: "value", Value: "4.7k"},
		},
	}
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	client := eda.New(srv.URL, "test-token")
	plan, err := sync.Run(client, kc, "", "demo", sync.Options{})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if plan.Summary.Updated != 1 {
		t.Fatalf("expected Updated=1, got %d", plan.Summary.Updated)
	}
	if kc.Footprints[0].Value != "4.7k" {
		t.Errorf("R1 value not updated: %q", kc.Footprints[0].Value)
	}
	if len(kc.CommitMessages) != 1 {
		t.Errorf("expected 1 commit, got %d", len(kc.CommitMessages))
	}
	if len(gotReq.Board) != 1 || gotReq.Board[0].UUID != "u-r1" {
		t.Errorf("server did not receive board state: %+v", gotReq.Board)
	}
}

func TestAddOpInsertsFootprint(t *testing.T) {
	kc := kicad.NewFake("/tmp/test.kicad_pcb", nil)

	planResp := eda.SyncPlanResponse{
		Summary: eda.Summary{Added: 1},
		Ops: []eda.Op{
			{Op: "add", UUID: "u-c1", Ref: "C1", Value: "100nF",
				FootprintName: "C_0402",
				KicadMod:      stubKicadMod("C_0402"),
				FootprintDef:  stubFootprintDef("C_0402"),
				PadNets:       [][2]string{{"1", "VDD"}, {"2", "GND"}}},
		},
	}
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "", "demo", sync.Options{}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(kc.Added) != 1 || kc.Added[0].UUID != "u-c1" {
		t.Errorf("expected 1 add of u-c1, got %+v", kc.Added)
	}
	if kc.Added[0].FootprintName != "C_0402" {
		t.Errorf("footprint name lost in add: %q", kc.Added[0].FootprintName)
	}
}

func TestSwapOpReplacesFootprint(t *testing.T) {
	board := []kicad.Footprint{
		{UUID: "u-r1", Reference: "R1", Value: "1k", FootprintName: "R_0402",
			Pads: []kicad.Pad{{Number: "1", Net: "VDD"}, {Number: "2", Net: "GND"}}},
	}
	kc := kicad.NewFake("/tmp/test.kicad_pcb", board)

	planResp := eda.SyncPlanResponse{
		Summary: eda.Summary{Swapped: 1},
		Ops: []eda.Op{
			{Op: "swap_footprint", UUID: "u-r1", NewFootprintName: "R_0805",
				KicadMod:     stubKicadMod("R_0805"),
				FootprintDef: stubFootprintDef("R_0805"),
				PadNets:      [][2]string{{"1", "VDD"}, {"2", "GND"}}},
		},
	}
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "", "demo", sync.Options{}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if kc.Footprints[0].FootprintName != "R_0805" {
		t.Errorf("expected swap to R_0805, got %q", kc.Footprints[0].FootprintName)
	}
}

func TestRemoveOpDeletesFootprint(t *testing.T) {
	board := []kicad.Footprint{
		{UUID: "u-stale", Reference: "X9", FootprintName: "Hole",
			Pads: []kicad.Pad{{Number: "1"}}},
		{UUID: "u-r1", Reference: "R1", FootprintName: "R_0402",
			Pads: []kicad.Pad{{Number: "1"}, {Number: "2"}}},
	}
	kc := kicad.NewFake("/tmp/test.kicad_pcb", board)

	planResp := eda.SyncPlanResponse{
		Summary: eda.Summary{Removed: 1},
		Ops:     []eda.Op{{Op: "remove", UUID: "u-stale"}},
	}
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "", "demo", sync.Options{Prune: true}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(kc.Removed) != 1 || kc.Removed[0] != "u-stale" {
		t.Errorf("expected 1 remove of u-stale, got %+v", kc.Removed)
	}
	if len(kc.Footprints) != 1 || kc.Footprints[0].UUID != "u-r1" {
		t.Errorf("expected only u-r1 remaining, got %+v", kc.Footprints)
	}
	if !gotReq.PruneStale {
		t.Errorf("prune flag not propagated to server")
	}
}

func TestFlagStaleIsInformational(t *testing.T) {
	kc := kicad.NewFake("/tmp/test.kicad_pcb", []kicad.Footprint{
		{UUID: "u-stale", Reference: "X9"},
	})
	planResp := eda.SyncPlanResponse{
		Summary: eda.Summary{FlaggedStale: 1},
		Ops:     []eda.Op{{Op: "flag_stale", UUID: "u-stale", Ref: "X9"}},
	}
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "", "demo", sync.Options{}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(kc.Removed) != 0 {
		t.Errorf("flag_stale should not remove anything; got %+v", kc.Removed)
	}
	if len(kc.Footprints) != 1 {
		t.Errorf("flag_stale should not touch footprints; got %+v", kc.Footprints)
	}
}

// TestStaleSidecarWritten covers `<board>.stale.json` — the user-facing
// list of orphans the next sync would either keep flagged or prune. Each
// entry needs enough identifying info (ref + KiCad UUID + footprint name
// + value) that the user can locate the part in KiCad and decide whether
// to delete. The sidecar is rewritten in full every sync (including dry
// runs) so an empty list after a clean sync replaces a stale file from
// a previous run instead of going out-of-date.
func TestStaleSidecarWritten(t *testing.T) {
	tmp := t.TempDir()
	boardPath := filepath.Join(tmp, "demo.kicad_pcb")
	board := []kicad.Footprint{
		{UUID: "canopy-x9", KicadUUID: "kicad-x9", Reference: "X9",
			Value: "10R", FootprintName: "R_0402"},
		{UUID: "canopy-r1", KicadUUID: "kicad-r1", Reference: "R1",
			Value: "1k", FootprintName: "R_0402"},
	}
	kc := kicad.NewFake(boardPath, board)
	planResp := eda.SyncPlanResponse{
		Summary: eda.Summary{FlaggedStale: 1},
		Ops:     []eda.Op{{Op: "flag_stale", UUID: "kicad-x9", Ref: "X9"}},
	}
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, boardPath, "demo", sync.Options{DryRun: true}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	sidecarPath := boardPath + ".stale.json"
	body, err := os.ReadFile(sidecarPath)
	if err != nil {
		t.Fatalf("expected sidecar at %s: %v", sidecarPath, err)
	}
	var got sync.StaleSidecar
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode sidecar: %v", err)
	}
	if got.Design != "demo" {
		t.Errorf("design: got %q, want demo", got.Design)
	}
	if !got.DryRun {
		t.Errorf("DryRun should be true for a --dry-run invocation")
	}
	if got.Total != 1 || len(got.Stale) != 1 {
		t.Fatalf("expected exactly 1 stale entry, got %+v", got)
	}
	e := got.Stale[0]
	// Cross-reference from kid into the board fp must enrich the entry
	// with footprint name + value — the ref alone isn't enough to
	// disambiguate when several fps share the same prefix.
	if e.Ref != "X9" || e.KicadUUID != "kicad-x9" ||
		e.CanopyUUID != "canopy-x9" || e.FootprintName != "R_0402" ||
		e.Value != "10R" {
		t.Errorf("entry not enriched from board state: %+v", e)
	}
	if got.LastSync == "" {
		t.Errorf("LastSync should be set to current time, got empty")
	}
}

// TestStaleSidecarOverwritesClean: a sync with zero flag_stale ops
// must rewrite the sidecar with an empty list so a previously-stale
// file from an older sync doesn't lie about the current state.
func TestStaleSidecarOverwritesClean(t *testing.T) {
	tmp := t.TempDir()
	boardPath := filepath.Join(tmp, "demo.kicad_pcb")
	// Seed an old sidecar with a stale entry that shouldn't exist anymore.
	prior := `{"design":"demo","stale_count":1,"stale":[{"ref":"OLD","kicad_uuid":"kicad-old"}]}` + "\n"
	if err := os.WriteFile(boardPath+".stale.json", []byte(prior), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	kc := kicad.NewFake(boardPath, nil)
	planResp := eda.SyncPlanResponse{} // no ops, no stale
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, boardPath, "demo", sync.Options{}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	body, _ := os.ReadFile(boardPath + ".stale.json")
	var got sync.StaleSidecar
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode sidecar after clean sync: %v", err)
	}
	if got.Total != 0 || len(got.Stale) != 0 {
		t.Errorf("clean sync should overwrite sidecar with empty list, got %+v", got)
	}
}

func TestEmptyPlanSkipsCommit(t *testing.T) {
	kc := kicad.NewFake("/tmp/test.kicad_pcb", nil)
	planResp := eda.SyncPlanResponse{}
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "", "demo", sync.Options{}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(kc.CommitMessages) != 0 {
		t.Errorf("expected no commit for empty plan, got %v", kc.CommitMessages)
	}
}
