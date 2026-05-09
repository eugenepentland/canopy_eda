package kicad

import (
	"errors"
	"fmt"
)

// Fake is an in-process Client implementation backed by a Go map. Used by
// the sync_test.go suite — boards are seeded via Footprints, mutations are
// recorded in CommitMessages / Added / Removed for assertion.
type Fake struct {
	BoardFile      string
	Footprints     []Footprint
	pendingAdded   []Footprint
	pendingRemoved []string
	pendingDirty   map[string]struct{}
	pendingMessage string

	CommitMessages []string
	Added          []Footprint
	Removed        []string
}

// NewFake returns a Fake seeded with `fps`.
func NewFake(boardFile string, fps []Footprint) *Fake {
	return &Fake{
		BoardFile:    boardFile,
		Footprints:   append([]Footprint{}, fps...),
		pendingDirty: map[string]struct{}{},
	}
}

func (f *Fake) BoardPath() (string, error) { return f.BoardFile, nil }

// SetBoardPath updates the path BoardPath returns. The Fake doesn't do
// per-board library staging, so this is just here to satisfy the
// Client interface and let tests override the path mid-test if needed.
func (f *Fake) SetBoardPath(absPath string) {
	if absPath != "" {
		f.BoardFile = absPath
	}
}

func (f *Fake) ListFootprints() ([]Footprint, error) {
	out := make([]Footprint, len(f.Footprints))
	copy(out, f.Footprints)
	return out, nil
}

func (f *Fake) Begin(message string) error {
	f.pendingMessage = message
	f.pendingAdded = nil
	f.pendingRemoved = nil
	f.pendingDirty = map[string]struct{}{}
	return nil
}

// findIdx resolves a uuid to a slot in Footprints, matching either the
// canopy UUID or the KiCad-internal UUID. Mirrors the real client's cache
// aliasing so tests exercise the same lookup semantics.
func (f *Fake) findIdx(uuid string) (int, bool) {
	for i, fp := range f.Footprints {
		if fp.UUID == uuid || (fp.KicadUUID != "" && fp.KicadUUID == uuid) {
			return i, true
		}
	}
	return -1, false
}

func (f *Fake) SetField(uuid, field, value string) error {
	i, ok := f.findIdx(uuid)
	if !ok {
		return fmt.Errorf("SetField: uuid %q not found", uuid)
	}
	switch field {
	case "reference":
		f.Footprints[i].Reference = value
	case "value":
		f.Footprints[i].Value = value
	case fieldCanopyUUID:
		f.Footprints[i].UUID = value
	}
	f.pendingDirty[uuid] = struct{}{}
	return nil
}

func (f *Fake) SetPadNet(uuid, pad, net string) error {
	i, ok := f.findIdx(uuid)
	if !ok {
		return fmt.Errorf("SetPadNet: uuid %q not found", uuid)
	}
	for j := range f.Footprints[i].Pads {
		if f.Footprints[i].Pads[j].Number == pad {
			f.Footprints[i].Pads[j].Net = net
			f.pendingDirty[uuid] = struct{}{}
			return nil
		}
	}
	return fmt.Errorf("SetPadNet: pad %q not on uuid %q", pad, uuid)
}

func (f *Fake) AddFootprint(defJSON []byte, kicadMod, entryName, uuid, ref, value string, padNets [][2]string) error {
	pads := make([]Pad, 0, len(padNets))
	for _, kv := range padNets {
		pads = append(pads, Pad{Number: kv[0], Net: kv[1]})
	}
	fp := Footprint{
		UUID:          uuid,
		Reference:     ref,
		Value:         value,
		FootprintName: entryName,
		Pads:          pads,
	}
	f.pendingAdded = append(f.pendingAdded, fp)
	f.Footprints = append(f.Footprints, fp)
	return nil
}

func (f *Fake) SwapFootprint(uuid string, defJSON []byte, kicadMod, entryName string, padNets [][2]string) error {
	i, ok := f.findIdx(uuid)
	if !ok {
		return fmt.Errorf("SwapFootprint: uuid %q not found", uuid)
	}
	pads := make([]Pad, 0, len(padNets))
	for _, kv := range padNets {
		pads = append(pads, Pad{Number: kv[0], Net: kv[1]})
	}
	if entryName != "" {
		f.Footprints[i].FootprintName = entryName
	}
	f.Footprints[i].Pads = pads
	f.pendingDirty[uuid] = struct{}{}
	return nil
}

func (f *Fake) Remove(uuid string) error {
	i, ok := f.findIdx(uuid)
	if !ok {
		return fmt.Errorf("Remove: uuid %q not found", uuid)
	}
	f.pendingRemoved = append(f.pendingRemoved, uuid)
	f.Footprints = append(f.Footprints[:i], f.Footprints[i+1:]...)
	return nil
}

func (f *Fake) Push() error {
	if f.pendingMessage == "" {
		return errors.New("Push without Begin")
	}
	f.CommitMessages = append(f.CommitMessages, f.pendingMessage)
	f.Added = append(f.Added, f.pendingAdded...)
	f.Removed = append(f.Removed, f.pendingRemoved...)
	f.pendingMessage = ""
	f.pendingAdded = nil
	f.pendingRemoved = nil
	f.pendingDirty = map[string]struct{}{}
	return nil
}

func (f *Fake) Close() error { return nil }

// extractFpName grabs the first quoted name after `(footprint` or `(module`.
// Matches the Python plugin's tiny extractor — used by the Fake to populate
// FootprintName so tests can assert footprint swaps.
func extractFpName(text string) string {
	for _, head := range []string{"(footprint ", "(module "} {
		if i := index(text, head); i >= 0 {
			rest := text[i+len(head):]
			if rest == "" || rest[0] != '"' {
				continue
			}
			end := index(rest[1:], `"`)
			if end < 0 {
				continue
			}
			return rest[1 : 1+end]
		}
	}
	return ""
}

func index(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
