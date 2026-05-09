// Package eda is the HTTP client for the EDA server's sync-plan endpoint.
//
// The agent sends the user's current board state, the server runs the diff,
// and the agent applies the returned ops via IPC. Auth is a Bearer header
// carrying the OAuth access token.
package eda

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// PadAssign is one (pad_number, net_name) tuple.
type PadAssign struct {
	Number string `json:"number"`
	Net    string `json:"net"`
}

// BoardFp is one footprint on the user's board, as the client describes it.
//
// UUID is the project-stable canopy_uuid custom field — empty when the
// footprint hasn't been synced before. KicadUUID is the KiCad-internal
// handle the agent uses to apply mutations; the server echoes it back in
// emitted ops so the agent's cache lookup resolves regardless of whether
// the footprint already has a canopy_uuid.
type BoardFp struct {
	UUID          string      `json:"uuid"`
	KicadUUID     string      `json:"kicad_uuid,omitempty"`
	Ref           string      `json:"ref"`
	Value         string      `json:"value"`
	FootprintName string      `json:"footprint_name"`
	// MPN as the user's KiCad currently records it. Empty when the
	// footprint hasn't received an MPN from a prior sync. Server diffs
	// against the design's `(mpn …)` property and emits a set_field op
	// when they drift, so the BOM column in KiCad stays aligned with the
	// schematic source of truth without re-emitting on every sync.
	MPN  string      `json:"mpn,omitempty"`
	Pads []PadAssign `json:"pads"`
}

// SyncPlanRequest is the JSON body posted to /api/sync-plan/:name.
type SyncPlanRequest struct {
	Board            []BoardFp `json:"board"`
	PruneStale       bool      `json:"prune_stale"`
	MigrateHeuristic bool      `json:"migrate_heuristic,omitempty"`
}

// FootprintPad is one pad in a structured footprint definition. Distances
// are in millimetres; rotation is in degrees. Layers default to standard
// SMD/thru-hole sets when the wire omits them.
type FootprintPad struct {
	Number   string     `json:"number"`
	Type     string     `json:"type"`     // smd | thru_hole | np_thru_hole
	Shape    string     `json:"shape"`    // rect | circle | oval | roundrect
	Pos      [2]float64 `json:"pos"`      // mm, relative to footprint origin
	Size     [2]float64 `json:"size"`     // mm
	Drill    float64    `json:"drill,omitempty"`
	Rotation float64    `json:"rotation,omitempty"`
	Layers   []string   `json:"layers,omitempty"`
}

// FootprintDef is the structured form the server ships alongside the
// legacy kicad_mod text on add/swap ops, so the Go agent can build a
// FootprintInstance proto without parsing kicad_mod.
type FootprintDef struct {
	Name string         `json:"name"`
	Pads []FootprintPad `json:"pads"`
}

// Op is one server-emitted operation. Fields not relevant for a given `op`
// are zero-value. PadNets is encoded as `[][2]string` over the wire.
type Op struct {
	Op               string        `json:"op"`
	UUID             string        `json:"uuid,omitempty"`
	Field            string        `json:"field,omitempty"`
	Value            string        `json:"value,omitempty"`
	Pad              string        `json:"pad,omitempty"`
	Net              string        `json:"net,omitempty"`
	Ref              string        `json:"ref,omitempty"`
	FootprintName    string        `json:"footprint_name,omitempty"`
	NewFootprintName string        `json:"new_footprint_name,omitempty"`
	KicadMod         string        `json:"kicad_mod,omitempty"`
	FootprintDef     *FootprintDef `json:"footprint_def,omitempty"`
	PadNets          [][2]string   `json:"pad_nets,omitempty"`
}

// Summary is the counts the server tracked while building the plan.
type Summary struct {
	Updated      int `json:"updated"`
	Added        int `json:"added"`
	Removed      int `json:"removed"`
	Swapped      int `json:"swapped"`
	FlaggedStale int `json:"flagged_stale"`
}

// SyncPlanResponse is the parsed response body.
type SyncPlanResponse struct {
	DesignVersion int     `json:"design_version"`
	Summary       Summary `json:"summary"`
	Ops           []Op    `json:"ops"`
}

// ErrUnauthorized signals a 401 — the token has been revoked / expired.
// Caller is expected to re-run OAuth.
var ErrUnauthorized = errors.New("server rejected token (401)")

// Client is configured per-server. Reusable across multiple syncs.
type Client struct {
	BaseURL  string
	Token    string
	HTTP     *http.Client
}

// New returns a Client with sane defaults.
func New(baseURL, token string) *Client {
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Token:   token,
		HTTP:    &http.Client{Timeout: 60 * time.Second},
	}
}

// SyncPlan calls POST /api/sync-plan/:design.
func (c *Client) SyncPlan(design string, req SyncPlanRequest) (*SyncPlanResponse, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	url := c.BaseURL + "/api/sync-plan/" + design
	httpReq, err := http.NewRequest("POST", url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+c.Token)
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")

	resp, err := c.HTTP.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("sync-plan request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusUnauthorized {
		return nil, ErrUnauthorized
	}
	if resp.StatusCode != http.StatusOK {
		preview, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("sync-plan: HTTP %d — %s", resp.StatusCode, preview)
	}

	var out SyncPlanResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}
	return &out, nil
}
