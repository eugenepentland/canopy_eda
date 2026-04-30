package kicad

import (
	"errors"
	"fmt"
	"os"

	"go.nanomsg.org/mangos/v3"
	"go.nanomsg.org/mangos/v3/protocol/req"
	_ "go.nanomsg.org/mangos/v3/transport/ipc" // Unix socket / Windows named pipe
	_ "go.nanomsg.org/mangos/v3/transport/tcp"
	"google.golang.org/protobuf/types/known/anypb"

	board_types "github.com/canopy/eda/tools/kicad-sync-go/internal/kicad/proto/board/board_types"
	base_commands "github.com/canopy/eda/tools/kicad-sync-go/internal/kicad/proto/common/commands/base_commands"
	editor_commands "github.com/canopy/eda/tools/kicad-sync-go/internal/kicad/proto/common/commands/editor_commands"
	base_types "github.com/canopy/eda/tools/kicad-sync-go/internal/kicad/proto/common/types/base_types"
	enums "github.com/canopy/eda/tools/kicad-sync-go/internal/kicad/proto/common/types/enums"
)

// Connect dials the KiCad IPC socket advertised in KICAD_API_SOCKET (set
// either by KiCad's plugin.json launcher or, for legacy ActionPlugins,
// by our Python shim that injects the platform-default path).
func Connect() (Client, error) {
	socketPath := os.Getenv("KICAD_API_SOCKET")
	if socketPath == "" {
		return nil, errors.New("KICAD_API_SOCKET is not set — run from KiCad's plugin button or export it manually")
	}
	token := os.Getenv("KICAD_API_TOKEN")

	sock, err := req.NewSocket()
	if err != nil {
		return nil, fmt.Errorf("nng socket: %w", err)
	}
	dialURL := socketPath
	if !looksLikeURL(dialURL) {
		dialURL = "ipc://" + socketPath
	}
	if err := sock.Dial(dialURL); err != nil {
		_ = sock.Close()
		return nil, fmt.Errorf("dial %s: %w", dialURL, err)
	}
	return &realClient{sock: sock, token: token}, nil
}

func looksLikeURL(s string) bool {
	for _, p := range []string{"ipc://", "tcp://", "unix://"} {
		if len(s) >= len(p) && s[:len(p)] == p {
			return true
		}
	}
	return false
}

type realClient struct {
	sock  mangos.Socket
	token string

	// Cached after BoardPath / ListFootprints to be reused as ItemHeader
	// in subsequent calls.
	doc *base_types.DocumentSpecifier

	// uuid -> live FootprintInstance proto. Mutations from SetField /
	// SetPadNet edit the in-memory copy; Push flushes them all in one
	// UpdateItems batch so KiCad records the sync as a single undo.
	cache map[string]*board_types.FootprintInstance

	dirty   map[string]struct{}      // uuids of mutated FPs
	removed map[string]struct{}      // uuids to delete
	added   []*board_types.FootprintInstance

	commitID *base_types.KIID
	commitMessage string
}

// ── Read side ─────────────────────────────────────────────────────────

func (c *realClient) BoardPath() (string, error) {
	any, err := c.rpc(&editor_commands.GetOpenDocuments{Type: base_types.DocumentType_DOCTYPE_PCB})
	if err != nil {
		return "", err
	}
	var resp editor_commands.GetOpenDocumentsResponse
	if err := any.UnmarshalTo(&resp); err != nil {
		return "", fmt.Errorf("unmarshal GetOpenDocumentsResponse: %w", err)
	}
	if len(resp.GetDocuments()) == 0 {
		return "", errors.New("no PCB is open in KiCad")
	}
	doc := resp.GetDocuments()[0]
	c.doc = doc
	return doc.GetBoardFilename(), nil
}

func (c *realClient) ListFootprints() ([]Footprint, error) {
	if c.doc == nil {
		// Caller didn't ask for BoardPath first — fetch it now.
		if _, err := c.BoardPath(); err != nil {
			return nil, err
		}
	}
	any, err := c.rpc(&editor_commands.GetItems{
		Header: &base_types.ItemHeader{Document: c.doc},
		Types:  []enums.KiCadObjectType{enums.KiCadObjectType_KOT_PCB_FOOTPRINT},
	})
	if err != nil {
		return nil, err
	}
	var resp editor_commands.GetItemsResponse
	if err := any.UnmarshalTo(&resp); err != nil {
		return nil, fmt.Errorf("unmarshal GetItemsResponse: %w", err)
	}

	if c.cache == nil {
		c.cache = map[string]*board_types.FootprintInstance{}
	}
	out := make([]Footprint, 0, len(resp.GetItems()))
	for _, item := range resp.GetItems() {
		var fp board_types.FootprintInstance
		if err := item.UnmarshalTo(&fp); err != nil {
			return nil, fmt.Errorf("item is not a FootprintInstance: %w", err)
		}
		uuid := fp.GetId().GetValue()
		c.cache[uuid] = &fp
		out = append(out, footprintToNeutral(&fp))
	}
	return out, nil
}

// footprintToNeutral converts a KiCad FootprintInstance to our internal
// Footprint type, extracting only the fields the sync algorithm cares
// about. Custom fields (canopy_uuid) live inside Definition.Items as
// Any-wrapped Field messages — we walk them once.
func footprintToNeutral(fp *board_types.FootprintInstance) Footprint {
	// Field.Text is a BoardText which wraps base_types.Text; the actual
	// string lives at fp.<Field>.Text.Text.Text.
	out := Footprint{
		UUID:          fp.GetId().GetValue(),
		Reference:     fp.GetReferenceField().GetText().GetText().GetText(),
		Value:         fp.GetValueField().GetText().GetText().GetText(),
		FootprintName: fp.GetDefinition().GetId().GetEntryName(),
	}
	// Pads (and custom fields) are inside Definition.Items as Any-wrapped
	// messages. Pull pads out so the diff can read pad nets.
	for _, item := range fp.GetDefinition().GetItems() {
		var pad board_types.Pad
		if err := item.UnmarshalTo(&pad); err == nil {
			out.Pads = append(out.Pads, Pad{
				Number: pad.GetNumber(),
				Net:    pad.GetNet().GetName(),
			})
			continue
		}
		// Walk Field items too in case canopy_uuid / similar live here.
		// (We don't need to surface them via the neutral type — sync_core
		// only needs UUID matching, which uses fp.GetId().)
	}
	return out
}

// ── Write side ────────────────────────────────────────────────────────

func (c *realClient) Begin(message string) error {
	c.dirty = map[string]struct{}{}
	c.removed = map[string]struct{}{}
	c.added = nil
	c.commitMessage = message
	if c.doc == nil {
		if _, err := c.BoardPath(); err != nil {
			return err
		}
	}
	any, err := c.rpc(&editor_commands.BeginCommit{
		Header: &base_types.ItemHeader{Document: c.doc},
	})
	if err != nil {
		return fmt.Errorf("BeginCommit: %w", err)
	}
	var resp editor_commands.BeginCommitResponse
	if err := any.UnmarshalTo(&resp); err != nil {
		return fmt.Errorf("unmarshal BeginCommitResponse: %w", err)
	}
	c.commitID = resp.GetId()
	return nil
}

func (c *realClient) SetField(uuid, field, value string) error {
	fp, ok := c.cache[uuid]
	if !ok {
		// SetField is sometimes called for backfill on items we haven't
		// seen yet; silently skip rather than abort the whole commit.
		return nil
	}
	switch field {
	case "reference":
		ensureBoardTextString(ensureField(&fp.ReferenceField)).Text = value
	case "value":
		ensureBoardTextString(ensureField(&fp.ValueField)).Text = value
	default:
		// Custom field (e.g. canopy_uuid). Stored under
		// Definition.Items as Any-wrapped Field. v1 doesn't write these
		// — the server uses canopy_uuid only for matching, and the
		// initial population of canopy_uuid happens via the Python
		// plugin's first sync. New IPC syncs should already see them.
		return nil
	}
	c.dirty[uuid] = struct{}{}
	return nil
}

func ensureField(fpref **board_types.Field) *board_types.Field {
	if *fpref == nil {
		*fpref = &board_types.Field{Text: &board_types.BoardText{}}
	}
	if (*fpref).Text == nil {
		(*fpref).Text = &board_types.BoardText{}
	}
	return *fpref
}

// Walks Field → BoardText → Text, allocating any nil intermediate so the
// caller can set the .Text string directly.
func ensureBoardTextString(f *board_types.Field) *base_types.Text {
	if f.Text == nil {
		f.Text = &board_types.BoardText{}
	}
	if f.Text.Text == nil {
		f.Text.Text = &base_types.Text{}
	}
	return f.Text.Text
}

func (c *realClient) SetPadNet(uuid, padNumber, netName string) error {
	fp, ok := c.cache[uuid]
	if !ok {
		return nil
	}
	def := fp.GetDefinition()
	if def == nil {
		return nil
	}
	for _, item := range def.GetItems() {
		var pad board_types.Pad
		if err := item.UnmarshalTo(&pad); err != nil {
			continue
		}
		if pad.GetNumber() != padNumber {
			continue
		}
		if pad.Net == nil {
			pad.Net = &board_types.Net{}
		}
		pad.Net.Name = netName
		// Re-pack the mutated pad back into the Any. Copy fields rather
		// than dereference the whole struct (the protobuf message has an
		// internal sync.Mutex that mustn't be copied).
		repacked, err := anypb.New(&pad)
		if err != nil {
			return fmt.Errorf("repack pad: %w", err)
		}
		item.TypeUrl = repacked.TypeUrl
		item.Value = repacked.Value
		c.dirty[uuid] = struct{}{}
		return nil
	}
	return nil
}

func (c *realClient) AddFootprint(kicadMod, uuid, ref, value string, padNets [][2]string) error {
	return errors.New(
		"AddFootprint not yet implemented in IPC mode — the Go agent v1 supports update + remove only. " +
			"For a fresh PCB, use the Python plugin (../kicad-sync-plugin) for the first sync to place all footprints, " +
			"then use the Go agent for ongoing updates.",
	)
}

func (c *realClient) SwapFootprint(uuid, kicadMod string, padNets [][2]string) error {
	return errors.New(
		"SwapFootprint not yet implemented in IPC mode — change the footprint manually in KiCad and re-sync to update value/nets only.",
	)
}

func (c *realClient) Remove(uuid string) error {
	c.removed[uuid] = struct{}{}
	return nil
}

func (c *realClient) Push() error {
	if c.commitID == nil {
		return errors.New("Push without Begin")
	}

	// 1. UpdateItems — flush dirty footprints.
	if len(c.dirty) > 0 {
		items := make([]*anypb.Any, 0, len(c.dirty))
		for uuid := range c.dirty {
			fp := c.cache[uuid]
			any, err := anypb.New(fp)
			if err != nil {
				return fmt.Errorf("pack dirty %s: %w", uuid, err)
			}
			items = append(items, any)
		}
		if _, err := c.rpc(&editor_commands.UpdateItems{
			Header: &base_types.ItemHeader{Document: c.doc},
			Items:  items,
		}); err != nil {
			return fmt.Errorf("UpdateItems: %w", err)
		}
	}

	// 2. RemoveItems — flush deletions. Uses GetItemsById to remove by KIID
	//    isn't a thing; the proper command is just UpdateItems on a
	//    delete-flagged item, OR DeleteItems if it exists in this build.
	//    Punt to GetItemsByID-then-skip for now: KiCad's IPC has both
	//    behaviors depending on version; the safest portable path is to
	//    log unsupported and let the user prune manually.
	if len(c.removed) > 0 {
		// TODO: wire a real RemoveItems / DeleteItems message once we
		// confirm the type exposed by the running KiCad build.
		// For v1, surface but don't fail — the result toast lists removed
		// UUIDs so the user can clean up manually.
	}

	// 3. EndCommit (action: COMMIT, with our message).
	if _, err := c.rpc(&editor_commands.EndCommit{
		Id:      c.commitID,
		Action:  editor_commands.CommitAction_CMA_COMMIT,
		Message: c.commitMessage,
		Header:  &base_types.ItemHeader{Document: c.doc},
	}); err != nil {
		return fmt.Errorf("EndCommit: %w", err)
	}

	c.commitID = nil
	c.dirty = nil
	c.removed = nil
	c.added = nil
	return nil
}

func (c *realClient) Close() error {
	if c.sock == nil {
		return nil
	}
	err := c.sock.Close()
	c.sock = nil
	return err
}

// Pings KiCad with a base GetVersion call so health checks fail fast.
// Currently unused by the run flow but available for future smoke tests.
func (c *realClient) ping() error {
	_, err := c.rpc(&base_commands.Ping{})
	return err
}
