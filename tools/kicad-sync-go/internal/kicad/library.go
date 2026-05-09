package kicad

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// edaSyncLibName is the per-board library nickname the agent stages into
// fp-lib-table so KiCad can resolve eda-sync:<entry_name> footprints. The
// matching directory lives at <board_dir>/<edaSyncLibDir>/.
const (
	edaSyncLibName = "eda-sync"
	edaSyncLibDir  = "eda-sync.pretty"
)

// stageLibraryFootprint writes the server-supplied kicad_mod text to the
// board's local eda-sync.pretty directory and ensures the project's
// fp-lib-table has an entry pointing at it. KiCad's IPC CreateItems
// silently drops Definition.Items unless the FootprintInstance's
// LibraryIdentifier resolves to a real library on disk; staging the
// `.kicad_mod` here is what makes the lookup succeed so the new fp
// renders with pads.
//
// boardPath is the absolute .kicad_pcb path KiCad reported via BoardPath.
// entryName is the library entry the FootprintInstance will reference
// (matches LibraryIdentifier.entry_name in the proto).
// kicadModText is the verbatim `(footprint …)` S-expression the EDA
// server ships in the `kicad_mod` field of add / swap_footprint ops.
//
// Idempotent: re-running on the same entry overwrites the file (so a
// design tweak to a footprint propagates), and the fp-lib-table edit
// only adds a new lib row when the eda-sync entry is missing.
func stageLibraryFootprint(boardPath, entryName, kicadModText string) error {
	if entryName == "" {
		return fmt.Errorf("stageLibraryFootprint: empty entry name")
	}
	if kicadModText == "" {
		return fmt.Errorf("stageLibraryFootprint: server omitted kicad_mod for %q", entryName)
	}
	boardDir := filepath.Dir(boardPath)
	libDir := filepath.Join(boardDir, edaSyncLibDir)
	if err := os.MkdirAll(libDir, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", libDir, err)
	}
	fpPath := filepath.Join(libDir, entryName+".kicad_mod")
	if err := os.WriteFile(fpPath, []byte(kicadModText), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", fpPath, err)
	}
	return ensureFpLibTable(boardDir)
}

// ensureFpLibTable inserts an `(lib …)` entry for eda-sync into the
// project's fp-lib-table if one isn't already present. Creates the
// table fresh when no fp-lib-table exists yet.
//
// The entry uses ${KIPRJMOD} so KiCad resolves it relative to the
// project — the .kicad_pcb stays portable across machines / network
// shares.
func ensureFpLibTable(boardDir string) error {
	tablePath := filepath.Join(boardDir, "fp-lib-table")
	existing, err := os.ReadFile(tablePath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read %s: %w", tablePath, err)
	}

	libEntry := `  (lib (name "` + edaSyncLibName + `")(type "KiCad")(uri "${KIPRJMOD}/` + edaSyncLibDir + `")(options "")(descr "Canopy EDA sync staging area"))`

	// Already registered — nothing to do. Match on the (name "<libName>")
	// fragment so a manual edit with extra whitespace still counts.
	if strings.Contains(string(existing), `(name "`+edaSyncLibName+`")`) {
		return nil
	}

	if len(existing) == 0 {
		fresh := "(fp_lib_table\n  (version 7)\n" + libEntry + "\n)\n"
		return os.WriteFile(tablePath, []byte(fresh), 0o644)
	}

	// Splice the new lib row before the closing `)` of the fp_lib_table
	// form. Find the LAST `)` in the file — fp-lib-table is a single
	// top-level form so that's the matching close.
	s := string(existing)
	closeIdx := strings.LastIndex(s, ")")
	if closeIdx < 0 {
		return fmt.Errorf("malformed %s — no closing paren", tablePath)
	}
	updated := s[:closeIdx] + libEntry + "\n" + s[closeIdx:]
	return os.WriteFile(tablePath, []byte(updated), 0o644)
}
