package kicad

import (
	crand "crypto/rand"
	"errors"
	"fmt"
	"os"

	"go.nanomsg.org/mangos/v3"
	"go.nanomsg.org/mangos/v3/protocol/req"
	_ "go.nanomsg.org/mangos/v3/transport/ipc" // Unix socket / Windows named pipe
	_ "go.nanomsg.org/mangos/v3/transport/tcp"
	"google.golang.org/protobuf/types/known/anypb"

	board_types "github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad/proto/board/board_types"
	base_commands "github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad/proto/common/commands/base_commands"
	editor_commands "github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad/proto/common/commands/editor_commands"
	base_types "github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad/proto/common/types/base_types"
	enums "github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad/proto/common/types/enums"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/synclog"
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
	synclog.Logf("Connect: dialing %s (token=%s)", dialURL, synclog.Redact(token))
	if err := sock.Dial(dialURL); err != nil {
		_ = sock.Close()
		synclog.Logf("Connect: dial failed: %v", err)
		return nil, fmt.Errorf("dial %s: %w", dialURL, err)
	}
	synclog.Logf("Connect: dial OK")
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

	dirty   map[string]struct{}              // uuids of mutated FPs
	removed map[string]struct{}              // uuids to delete
	added   []*board_types.FootprintInstance // staged new footprints
	// isNew flags fps that were synthesized by SwapFootprint / AddFootprint
	// in the current commit so SetField / SetPadNet don't mark them dirty
	// (they'll already be flushed via CreateItems with whatever in-place
	// mutations landed). Without this an UpdateItems against a UUID that
	// KiCad hasn't seen yet trips a "no such item" rpc error.
	isNew map[*board_types.FootprintInstance]struct{}

	commitID      *base_types.KIID
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
		neutral := footprintToNeutral(&fp)
		// Cache aliasing: ops from the server may target the footprint by
		// either the KiCad-internal UUID or the project's canopy_uuid (the
		// stable identity that survives KiCad re-imports). Both keys map to
		// the same FootprintInstance pointer so SetField/SetPadNet/Remove
		// resolve regardless of which form the op carries.
		c.cache[neutral.KicadUUID] = &fp
		if neutral.UUID != "" {
			c.cache[neutral.UUID] = &fp
		}
		out = append(out, neutral)
	}
	return out, nil
}

// footprintToNeutral converts a KiCad FootprintInstance to our internal
// Footprint type. Custom fields (most importantly `canopy_uuid`) live
// inside Definition.Items as Any-wrapped Field messages, so we walk that
// list once to pull out both pads and any project-level identity field.
func footprintToNeutral(fp *board_types.FootprintInstance) Footprint {
	// Field.Text is a BoardText which wraps base_types.Text; the actual
	// string lives at fp.<Field>.Text.Text.Text.
	out := Footprint{
		KicadUUID:     fp.GetId().GetValue(),
		Reference:     fp.GetReferenceField().GetText().GetText().GetText(),
		Value:         fp.GetValueField().GetText().GetText().GetText(),
		FootprintName: fp.GetDefinition().GetId().GetEntryName(),
	}
	for _, item := range fp.GetDefinition().GetItems() {
		var pad board_types.Pad
		if err := item.UnmarshalTo(&pad); err == nil {
			out.Pads = append(out.Pads, Pad{
				Number: pad.GetNumber(),
				Net:    pad.GetNet().GetName(),
			})
			continue
		}
		var field board_types.Field
		if err := item.UnmarshalTo(&field); err == nil {
			name := field.GetName()
			if name == "" {
				continue
			}
			text := field.GetText().GetText().GetText()
			if out.Fields == nil {
				out.Fields = map[string]string{}
			}
			out.Fields[name] = text
			if name == fieldCanopyUUID {
				out.UUID = text
			}
			continue
		}
	}
	return out
}

// fieldCanopyUUID is the well-known custom-field name carrying the project's
// stable instance ID on a KiCad footprint. The schematic-side evaluator
// emits 8-char hex; legacy boards from the Python plugin carry full 36-char
// UUIDs. The sync server treats both as opaque strings. Surfaced as
// Footprint.UUID alongside Footprint.Fields so existing match-by-uuid logic
// keeps working.
const fieldCanopyUUID = "canopy_uuid"

// ── Write side ────────────────────────────────────────────────────────

func (c *realClient) Begin(message string) error {
	c.dirty = map[string]struct{}{}
	c.removed = map[string]struct{}{}
	c.added = nil
	c.isNew = map[*board_types.FootprintInstance]struct{}{}
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
		// Custom field (e.g. canopy_uuid). Lives in Definition.Items as an
		// Any-wrapped Field with .Name == <field>. We mutate in place when
		// it already exists so KiCad sees an UPDATE, not a stack of
		// duplicates after repeated syncs.
		if err := setOrAppendCustomField(fp, field, value); err != nil {
			return err
		}
	}
	c.markDirtyIfExisting(fp)
	return nil
}

// markDirtyIfExisting flags fp for UpdateItems unless it was synthesized
// in this commit (SwapFootprint, AddFootprint). Newly-created fps go out
// via CreateItems with their in-place mutations already baked in, and an
// UpdateItems against a UUID KiCad hasn't seen yet would error out.
func (c *realClient) markDirtyIfExisting(fp *board_types.FootprintInstance) {
	if _, isNew := c.isNew[fp]; isNew {
		return
	}
	c.dirty[fp.GetId().GetValue()] = struct{}{}
}

// setOrAppendCustomField rewrites an existing Field.Text.Text.Text inside
// fp.Definition.Items, or appends a new Any-wrapped Field if no entry with
// that Name exists yet. Used for canopy_uuid backfill on legacy boards
// where the schematic ID hasn't yet been written to the footprint.
func setOrAppendCustomField(fp *board_types.FootprintInstance, name, value string) error {
	def := fp.GetDefinition()
	if def == nil {
		// A footprint with no Definition can't carry custom fields; the
		// caller's set_field op is meaningless here.
		return nil
	}
	for i, item := range def.Items {
		var existing board_types.Field
		if err := item.UnmarshalTo(&existing); err != nil {
			continue
		}
		if existing.GetName() != name {
			continue
		}
		ensureBoardTextString(&existing).Text = value
		newAny, err := anypb.New(&existing)
		if err != nil {
			return fmt.Errorf("marshal updated %s field: %w", name, err)
		}
		def.Items[i] = newAny
		return nil
	}
	fresh := &board_types.Field{Name: name}
	ensureBoardTextString(fresh).Text = value
	newAny, err := anypb.New(fresh)
	if err != nil {
		return fmt.Errorf("marshal new %s field: %w", name, err)
	}
	def.Items = append(def.Items, newAny)
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
		c.markDirtyIfExisting(fp)
		return nil
	}
	return nil
}

func (c *realClient) AddFootprint(kicadMod, entryName, uuid, ref, value string, padNets [][2]string) error {
	if err := c.stageLibraryAndCheck(kicadMod, entryName); err != nil {
		return fmt.Errorf("AddFootprint: %w", err)
	}
	fp := buildLibraryFootprintInstance(uuid, entryName, ref, value)
	c.added = append(c.added, fp)
	c.isNew[fp] = struct{}{}
	if c.cache == nil {
		c.cache = map[string]*board_types.FootprintInstance{}
	}
	c.cache[uuid] = fp
	return nil
}

func (c *realClient) SwapFootprint(uuid, kicadMod, entryName string, padNets [][2]string) error {
	old, ok := c.cache[uuid]
	if !ok {
		// Nothing to swap — caller is targeting an unknown footprint.
		return nil
	}
	if err := c.stageLibraryAndCheck(kicadMod, entryName); err != nil {
		return fmt.Errorf("SwapFootprint: %w", err)
	}

	oldKid := old.GetId().GetValue()
	newKid := newKIID()
	newFp := &board_types.FootprintInstance{
		Id:          &base_types.KIID{Value: newKid},
		Position:    old.GetPosition(),
		Orientation: old.GetOrientation(),
		Layer:       old.GetLayer(),
		Definition: &board_types.Footprint{
			Id: &base_types.LibraryIdentifier{
				LibraryNickname: edaSyncLibName,
				EntryName:       entryName,
			},
		},
	}
	if t := old.GetReferenceField().GetText().GetText().GetText(); t != "" {
		ensureBoardTextString(ensureField(&newFp.ReferenceField)).Text = t
	}
	if t := old.GetValueField().GetText().GetText().GetText(); t != "" {
		ensureBoardTextString(ensureField(&newFp.ValueField)).Text = t
	}
	// Carry custom Fields (canopy_uuid, MPN, …) onto the new fp so the
	// server's UUID-based match keeps resolving on the next sync.
	if oldDef := old.GetDefinition(); oldDef != nil {
		for _, item := range oldDef.Items {
			var f board_types.Field
			if err := item.UnmarshalTo(&f); err == nil && f.GetName() != "" {
				newFp.Definition.Items = append(newFp.Definition.Items, item)
			}
		}
	}

	c.removed[oldKid] = struct{}{}
	c.added = append(c.added, newFp)
	c.isNew[newFp] = struct{}{}
	// Re-key the cache so any follow-up SetField / SetPadNet ops in this
	// commit land on the new fp.
	c.cache[oldKid] = newFp
	c.cache[newKid] = newFp
	return nil
}

// stageLibraryAndCheck writes the server-supplied kicad_mod text into the
// per-board `eda-sync.pretty` directory and registers eda-sync in the
// project's fp-lib-table. KiCad's IPC CreateItems silently drops inline
// Definition.Items unless the FootprintInstance's LibraryIdentifier
// resolves to a real on-disk library — so this staging step is what
// makes a freshly-synced footprint actually render with pads.
func (c *realClient) stageLibraryAndCheck(kicadMod, entryName string) error {
	if c.doc == nil {
		if _, err := c.BoardPath(); err != nil {
			return fmt.Errorf("locate board path: %w", err)
		}
	}
	boardPath := c.doc.GetBoardFilename()
	if boardPath == "" {
		return errors.New("KiCad reported no board path; cannot stage footprint library")
	}
	synclog.Logf("stage library footprint entry=%q board=%q kicad_mod_len=%d",
		entryName, boardPath, len(kicadMod))
	if err := stageLibraryFootprint(boardPath, entryName, kicadMod); err != nil {
		synclog.Logf("stage library failed: %v", err)
		return err
	}
	synclog.Logf("stage library OK")
	return nil
}

// buildLibraryFootprintInstance creates a minimal FootprintInstance proto
// pointing at the eda-sync library entry named `entryName`. Geometry
// comes from the .kicad_mod the agent staged via stageLibraryFootprint;
// KiCad reads it on CreateItems and fills in pads / drawings / silk.
func buildLibraryFootprintInstance(uuid, entryName, ref, value string) *board_types.FootprintInstance {
	fp := &board_types.FootprintInstance{
		Id:          &base_types.KIID{Value: uuid},
		Position:    &base_types.Vector2{},
		Orientation: &base_types.Angle{ValueDegrees: 0},
		Layer:       board_types.BoardLayer_BL_F_Cu,
		Definition: &board_types.Footprint{
			Id: &base_types.LibraryIdentifier{
				LibraryNickname: edaSyncLibName,
				EntryName:       entryName,
			},
		},
	}
	if ref != "" {
		ensureBoardTextString(ensureField(&fp.ReferenceField)).Text = ref
	}
	if value != "" {
		ensureBoardTextString(ensureField(&fp.ValueField)).Text = value
	}
	return fp
}

// newKIID mints a fresh RFC 4122 v4 UUID string suitable for KiCad's
// `kiapi.common.types.KIID.value`. Used by SwapFootprint to avoid a
// CreateItems / DeleteItems collision on the same UUID.
func newKIID() string {
	var b [16]byte
	if _, err := crand.Read(b[:]); err != nil {
		// Falling back to a zero UUID is safer than panicking — the
		// surrounding rpc will fail loudly with an obvious "duplicate
		// id" if two zero UUIDs ever collide in the same commit.
		return "00000000-0000-0000-0000-000000000000"
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // RFC 4122 variant
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}


func (c *realClient) Remove(uuid string) error {
	if fp, ok := c.cache[uuid]; ok {
		c.removed[fp.GetId().GetValue()] = struct{}{}
		return nil
	}
	// Unknown UUID — record it anyway. Either a stale-prune from the
	// server or a uuid we never read; KiCad will just no-op the delete.
	c.removed[uuid] = struct{}{}
	return nil
}

func (c *realClient) Push() error {
	if c.commitID == nil {
		return errors.New("Push without Begin")
	}
	synclog.Logf("Push: dirty=%d added=%d removed=%d", len(c.dirty), len(c.added), len(c.removed))

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
		synclog.Logf("UpdateItems: sending %d items", len(items))
		if _, err := c.rpc(&editor_commands.UpdateItems{
			Header: &base_types.ItemHeader{Document: c.doc},
			Items:  items,
		}); err != nil {
			synclog.Logf("UpdateItems failed: %v", err)
			return fmt.Errorf("UpdateItems: %w", err)
		}
		synclog.Logf("UpdateItems OK")
	}

	// 2. CreateItems — flush newly-added footprints.
	if len(c.added) > 0 {
		items := make([]*anypb.Any, 0, len(c.added))
		for _, fp := range c.added {
			any, err := anypb.New(fp)
			if err != nil {
				return fmt.Errorf("pack new fp: %w", err)
			}
			items = append(items, any)
		}
		synclog.Logf("CreateItems: sending %d new fps", len(items))
		for _, fp := range c.added {
			synclog.Logf("  add fp id=%q lib=%q entry=%q ref=%q",
				fp.GetId().GetValue(),
				fp.GetDefinition().GetId().GetLibraryNickname(),
				fp.GetDefinition().GetId().GetEntryName(),
				fp.GetReferenceField().GetText().GetText().GetText())
		}
		if _, err := c.rpc(&editor_commands.CreateItems{
			Header: &base_types.ItemHeader{Document: c.doc},
			Items:  items,
		}); err != nil {
			synclog.Logf("CreateItems failed: %v", err)
			return fmt.Errorf("CreateItems: %w", err)
		}
		synclog.Logf("CreateItems OK")
	}

	// 3. DeleteItems — flush removals.
	if len(c.removed) > 0 {
		ids := make([]*base_types.KIID, 0, len(c.removed))
		for uuid := range c.removed {
			ids = append(ids, &base_types.KIID{Value: uuid})
		}
		synclog.Logf("DeleteItems: sending %d uuids", len(ids))
		if _, err := c.rpc(&editor_commands.DeleteItems{
			Header:  &base_types.ItemHeader{Document: c.doc},
			ItemIds: ids,
		}); err != nil {
			synclog.Logf("DeleteItems failed: %v", err)
			return fmt.Errorf("DeleteItems: %w", err)
		}
		synclog.Logf("DeleteItems OK")
	}

	// 4. EndCommit (action: COMMIT, with our message).
	if _, err := c.rpc(&editor_commands.EndCommit{
		Id:      c.commitID,
		Action:  editor_commands.CommitAction_CMA_COMMIT,
		Message: c.commitMessage,
		Header:  &base_types.ItemHeader{Document: c.doc},
	}); err != nil {
		synclog.Logf("EndCommit failed: %v", err)
		return fmt.Errorf("EndCommit: %w", err)
	}
	synclog.Logf("EndCommit OK; sync complete")

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
