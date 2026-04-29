// Package notify shows a result toast after a sync. Best-effort across
// platforms — falls through to stdout if nothing's wired up.
package notify

import (
	"fmt"
	"os/exec"
	"runtime"
	"strings"
)

// Show sends `body` as a desktop notification with `title`. Always also
// prints to stdout so logs capture the result.
func Show(title, body string) {
	fmt.Println("=", title)
	fmt.Println(body)

	switch runtime.GOOS {
	case "linux":
		_ = exec.Command("notify-send", title, body).Run()
	case "darwin":
		// AppleScript handles quoting via the display notification syntax.
		script := fmt.Sprintf(`display notification %q with title %q`, body, title)
		_ = exec.Command("osascript", "-e", script).Run()
	case "windows":
		// PowerShell BurntToast or fallback msg.exe — both flaky from
		// non-interactive subprocesses. Stdout is the reliable channel
		// here; KiCad captures it.
		body = strings.ReplaceAll(body, "\n", " — ")
		_ = exec.Command("msg", "*", "/TIME:8", title+": "+body).Run()
	}
}
