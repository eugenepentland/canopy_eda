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
	UUID          string `json:"uuid"`
	KicadUUID     string `json:"kicad_uuid,omitempty"`
	Ref           string `json:"ref"`
	Value         string `json:"value"`
	FootprintName string `json:"footprint_name"`
	// Fields is every custom KiCad field on this footprint, keyed by
	// field name (e.g. "MPN", "Manufacturer", "canopy_uuid"). The server
	// diffs design properties against this map and emits set_field ops
	// for any drift — so a new field type becomes a pure server-side
	// change, no agent update required. UUID above is the canonical
	// canopy_uuid value duplicated out of Fields for the server's
	// by_uuid matching index.
	Fields map[string]string `json:"fields,omitempty"`
	Pads   []PadAssign       `json:"pads"`
	// Locked mirrors KiCad's "Lock footprint" toggle. Sent so the server
	// can skip emitting a redundant set_locked op when the fp is already
	// locked, and (in future) respect a user's manual unlock by not
	// re-locking on subsequent stale flagging.
	Locked bool `json:"locked,omitempty"`
}

// SyncPlanRequest is the JSON body posted to /api/sync-plan/:name.
type SyncPlanRequest struct {
	Board            []BoardFp `json:"board"`
	PruneStale       bool      `json:"prune_stale"`
	MigrateHeuristic bool      `json:"migrate_heuristic,omitempty"`
	// AppliedOps carries the set of state-asserting ops the agent
	// has already pushed to KiCad in prior syncs. Server uses it to
	// suppress re-emission of ops the agent already applied — works
	// around a KiCad IPC quirk where some UpdateItems writes (custom
	// Field text, pad nets) land on disk but the subsequent GetItems
	// returns the pre-write value, causing the server to keep
	// emitting ops it can't tell were already applied.
	AppliedOps []AppliedOp `json:"applied_ops,omitempty"`
}

// AppliedOp is one previously-pushed mutation the agent records in the
// `<board>.applied_ops.json` sidecar and ships in the next sync request.
// Only state-asserting ops are tracked — `add` / `swap_footprint` /
// `remove` are state-changing and won't naturally re-emit if KiCad
// accepted them, so they're skipped.
//
// Key disambiguates which sub-thing of the op was set: field name for
// set_field, pad number for set_pad_net, empty string for set_locked.
type AppliedOp struct {
	UUID  string `json:"uuid"`
	Op    string `json:"op"`
	Key   string `json:"key,omitempty"`
	Value string `json:"value"`
}

// Op is one server-emitted operation. Fields not relevant for a given `op`
// are zero-value. PadNets is encoded as `[][2]string` over the wire.
//
// KicadMod is the verbatim `(footprint …)` S-expression source for an
// `add` / `swap_footprint` op. The agent stages it into the board's
// per-project `eda-sync.pretty` directory (and registers eda-sync in
// fp-lib-table) so KiCad's library lookup resolves at CreateItems time.
//
// FootprintDef is proto-canonical JSON for the same Footprint message —
// `kiapi.board.types.Footprint` with its Items list (Any-wrapped Pads).
// The agent decodes it via protojson and uses it as the inline
// Definition on CreateItems so KiCad doesn't need a separate "Update
// Footprint(s) From Library" action to populate the pad geometry.
// Empirically (KiCad 10), CreateItems with a resolvable LibraryIdentifier
// alone produces a placeholder fp with `pads=0`; inline Items is the
// only way we found to make pads appear in the same commit.
//
// PadNets carries per-instance net assignments (the geometry JSON is
// shared across every instance of a footprint name); the agent stamps
// them onto the decoded Pad messages after Unmarshal.
type Op struct {
	Op               string          `json:"op"`
	UUID             string          `json:"uuid,omitempty"`
	Field            string          `json:"field,omitempty"`
	Value            string          `json:"value,omitempty"`
	Pad              string          `json:"pad,omitempty"`
	Net              string          `json:"net,omitempty"`
	Ref              string          `json:"ref,omitempty"`
	FootprintName    string          `json:"footprint_name,omitempty"`
	NewFootprintName string          `json:"new_footprint_name,omitempty"`
	KicadMod         string          `json:"kicad_mod,omitempty"`
	FootprintDef     json.RawMessage `json:"footprint_def,omitempty"`
	PadNets          [][2]string     `json:"pad_nets,omitempty"`
	// Locked is the desired KiCad lock state for the `set_locked` op.
	// Pointer so we can tell a zero-value omit ({"locked": false} on
	// the wire) from an unset value. Used to visually flag stale fps
	// via the PCB editor's padlock overlay.
	Locked *bool `json:"locked,omitempty"`
}

// Summary is the counts the server tracked while building the plan.
type Summary struct {
	Updated      int `json:"updated"`
	Added        int `json:"added"`
	Removed      int `json:"removed"`
	Swapped      int `json:"swapped"`
	FlaggedStale int `json:"flagged_stale"`
	// Suppressed counts state-asserting ops the server WOULD have
	// emitted but skipped because the agent's applied_ops sidecar
	// already had the matching fingerprint. Surfacing it in the
	// result toast lets the user spot KiCad-IPC-leak situations
	// without having to read the synclog.
	Suppressed int `json:"suppressed,omitempty"`
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
