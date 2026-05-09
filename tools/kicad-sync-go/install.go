// Package kicadsync provides the assets and installer used by
// `eda-kicad-sync --install-kicad-plugin` to drop the KiCad 10 plugin
// manifest and the agent binary into KiCad's per-user plugin folder
// without requiring a checkout of this repository — the design goal is
// that `go install ...@latest` followed by one extra subcommand is the
// complete install path.
package kicadsync

import (
	_ "embed"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
)

// pluginManifest is the canonical plugin.json shipped to KiCad. We
// embed it so the installed manifest stays in sync with this binary's
// version even when the user installed via `go install` and never
// cloned the repo. Updating plugin.json at the module root is the
// single source of truth.
//
//go:embed plugin.json
var pluginManifest []byte

// EnvPluginDir overrides the per-OS install destination. Useful for
// non-standard KiCad installs (Flatpak, custom $XDG_DATA_HOME, sandboxed
// macOS builds).
const EnvPluginDir = "EDA_KICAD_PLUGIN_DIR"

// DefaultPluginDir returns the conventional per-user KiCad 10 plugin
// folder for the current OS, or an error if the platform isn't one of
// linux / darwin / windows. Mirrors the paths the legacy Makefile
// targeted so a `go install`-driven install lands where `make install`
// used to.
func DefaultPluginDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	switch runtime.GOOS {
	case "linux":
		return filepath.Join(home, ".local", "share", "kicad", "10.0", "3rdparty", "plugins", "eda-sync"), nil
	case "darwin":
		return filepath.Join(home, "Library", "Preferences", "kicad", "10.0", "3rdparty", "plugins", "eda-sync"), nil
	case "windows":
		return filepath.Join(home, "Documents", "KiCad", "10.0", "3rdparty", "plugins", "eda-sync"), nil
	default:
		return "", fmt.Errorf("unsupported OS %q — set %s to install manually", runtime.GOOS, EnvPluginDir)
	}
}

// Install drops plugin.json and the running executable into KiCad's
// per-user plugin folder. The destination can be overridden via the
// EDA_KICAD_PLUGIN_DIR env var (e.g. for Flatpak installs). On
// Linux/macOS the binary is symlinked from $GOBIN so a subsequent
// `go install` propagates to KiCad without re-running this command;
// Windows symlinks need elevation, so we copy there.
func Install() error {
	dst := os.Getenv(EnvPluginDir)
	if dst == "" {
		var err error
		dst, err = DefaultPluginDir()
		if err != nil {
			return err
		}
	}

	if err := os.MkdirAll(dst, 0o755); err != nil {
		return fmt.Errorf("create plugin dir %s: %w", dst, err)
	}

	manifestPath := filepath.Join(dst, "plugin.json")
	if err := os.WriteFile(manifestPath, pluginManifest, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", manifestPath, err)
	}

	src, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locate running binary: %w", err)
	}
	// Resolve symlinks so we point at the real `go install` output and
	// not, e.g., a tempdir wrapper a developer left in $PATH.
	if real, errResolve := filepath.EvalSymlinks(src); errResolve == nil {
		src = real
	}

	binName := "eda-kicad-sync"
	if runtime.GOOS == "windows" {
		binName += ".exe"
	}
	binPath := filepath.Join(dst, binName)

	if err := installBinary(src, binPath); err != nil {
		return err
	}

	fmt.Fprintf(os.Stderr,
		"EDA Sync installed:\n  manifest: %s\n  binary:   %s\nRestart KiCad to pick up the EDA Sync toolbar button.\n",
		manifestPath, binPath)
	return nil
}

// installBinary places the agent binary at dst. On Unix we use a
// symlink so re-running `go install` is enough to update the KiCad
// install too. On Windows we copy because non-admin symlinks require
// Developer Mode and quietly fail otherwise.
func installBinary(src, dst string) error {
	// Always start from a clean slate — a stale symlink/file would
	// otherwise block both `Symlink` (EEXIST) and a copy of a binary
	// that's currently being executed by KiCad.
	if err := os.Remove(dst); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove existing %s: %w", dst, err)
	}

	if runtime.GOOS != "windows" {
		if err := os.Symlink(src, dst); err != nil {
			return fmt.Errorf("symlink %s -> %s: %w", dst, src, err)
		}
		return nil
	}

	return copyFile(src, dst, 0o755)
}

func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	defer out.Close()

	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Chmod(mode)
}
