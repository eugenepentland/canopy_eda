package sync_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/canopy/eda/tools/kicad-sync-go/internal/eda"
	"github.com/canopy/eda/tools/kicad-sync-go/internal/kicad"
	"github.com/canopy/eda/tools/kicad-sync-go/internal/sync"
)

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
	plan, err := sync.Run(client, kc, "demo", false)
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
				KicadMod:      `(footprint "C_0402" (layer F.Cu))`,
				PadNets:       [][2]string{{"1", "VDD"}, {"2", "GND"}}},
		},
	}
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "demo", false); err != nil {
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
				KicadMod: `(footprint "R_0805" (layer F.Cu))`,
				PadNets:  [][2]string{{"1", "VDD"}, {"2", "GND"}}},
		},
	}
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "demo", false); err != nil {
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

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "demo", true); err != nil {
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

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "demo", false); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(kc.Removed) != 0 {
		t.Errorf("flag_stale should not remove anything; got %+v", kc.Removed)
	}
	if len(kc.Footprints) != 1 {
		t.Errorf("flag_stale should not touch footprints; got %+v", kc.Footprints)
	}
}

func TestEmptyPlanSkipsCommit(t *testing.T) {
	kc := kicad.NewFake("/tmp/test.kicad_pcb", nil)
	planResp := eda.SyncPlanResponse{}
	var gotReq eda.SyncPlanRequest
	srv := fakeServer(t, planResp, &gotReq)
	defer srv.Close()

	if _, err := sync.Run(eda.New(srv.URL, "test-token"), kc, "demo", false); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(kc.CommitMessages) != 0 {
		t.Errorf("expected no commit for empty plan, got %v", kc.CommitMessages)
	}
}
