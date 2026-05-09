// Package synclog writes a verbose append-only trace of every sync run to
// %TEMP%/eda-kicad-sync.log (cross-platform, uses os.TempDir). The agent
// is normally invoked by KiCad's plugin host with no terminal attached,
// so any error or unexpected state is otherwise invisible — this log is
// the only place we get to see what really happened during a click.
//
// The file is opened lazily on first Logf and held open for the life of
// the process. Each session emits a header so multiple runs are easy to
// distinguish when the user pastes the file back. Tokens / secrets are
// the caller's responsibility to redact before passing them in.
package synclog

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var (
	once   sync.Once
	file   *os.File
	logErr error
)

// Path returns where the log lives. Surfaced to main so the user-facing
// notification can include the path on error paths.
func Path() string {
	return filepath.Join(os.TempDir(), "eda-kicad-sync.log")
}

func openOnce() {
	once.Do(func() {
		path := Path()
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			logErr = err
			return
		}
		file = f
		fmt.Fprintf(file, "\n==== %s session start (pid=%d) ====\n",
			time.Now().Format(time.RFC3339), os.Getpid())
	})
}

// Logf appends one timestamped line. Format is fmt.Printf style. A
// trailing newline is added if `format` doesn't already end with one.
// Best-effort: silently no-ops if the log file couldn't be opened, so a
// readonly TEMP doesn't break sync.
func Logf(format string, args ...any) {
	openOnce()
	if file == nil {
		return
	}
	fmt.Fprintf(file, "[%s] ", time.Now().Format("15:04:05.000"))
	fmt.Fprintf(file, format, args...)
	if !strings.HasSuffix(format, "\n") {
		fmt.Fprint(file, "\n")
	}
	_ = file.Sync()
}

// Redact returns a token suitable for logging without leaking the
// underlying secret — keeps the first 4 and last 4 chars and replaces
// the middle with the byte length so we can still spot a stale-vs-new
// token by eye.
func Redact(secret string) string {
	if len(secret) <= 8 {
		return strings.Repeat("*", len(secret))
	}
	return fmt.Sprintf("%s…%s (len=%d)", secret[:4], secret[len(secret)-4:], len(secret))
}
