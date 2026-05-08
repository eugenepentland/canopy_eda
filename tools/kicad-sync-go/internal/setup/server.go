// Package setup serves a tiny first-run configuration page on
// http://127.0.0.1:<free-port>/setup. The user fills in server URL, design
// name, and OAuth client_id/secret; on submit, the page kicks off the OAuth
// dance and saves the result.
//
// We ask the OS for a free port (net.Listen on :0) rather than hardcoding
// one — VS Code, Postman, and other dev tools randomly bind ports in this
// range and will silently steal a fixed choice, leaving the user with a
// browser that hangs forever talking to the wrong server.
package setup

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"html/template"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/canopy/eda/tools/kicad-sync-go/internal/config"
	"github.com/canopy/eda/tools/kicad-sync-go/internal/oauth"
)

//go:embed setup.html
var setupHTML string

//go:embed done.html
var doneHTML string

// Run starts the setup HTTP server, opens the user's browser, and blocks
// until the user completes the form (or times out). Returns the populated
// BoardConfig — the caller saves it next to the .kicad_pcb.
func Run(boardPath string, initial config.BoardConfig) (config.BoardConfig, error) {
	tmpl, err := template.New("setup").Parse(setupHTML)
	if err != nil {
		return initial, fmt.Errorf("parse template: %w", err)
	}
	doneTmpl, err := template.New("done").Parse(doneHTML)
	if err != nil {
		return initial, fmt.Errorf("parse done template: %w", err)
	}

	var (
		mu      sync.Mutex
		result  config.BoardConfig
		done    = make(chan error, 1)
	)

	mux := http.NewServeMux()
	mux.HandleFunc("/setup", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_ = tmpl.Execute(w, struct {
			Initial     config.BoardConfig
			BoardPath   string
			RedirectURI string
		}{initial, boardPath, oauth.RedirectURI()})
	})
	mux.HandleFunc("/save", func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		cfg := config.BoardConfig{
			ServerURL:    strings.TrimRight(strings.TrimSpace(r.FormValue("server_url")), "/"),
			Design:       strings.TrimSpace(r.FormValue("design")),
			ClientID:     strings.TrimSpace(r.FormValue("client_id")),
			ClientSecret: strings.TrimSpace(r.FormValue("client_secret")),
		}
		if !cfg.Complete() {
			http.Error(w, "all four fields are required", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_ = doneTmpl.Execute(w, cfg)

		mu.Lock()
		result = cfg
		mu.Unlock()
		select {
		case done <- nil:
		default:
		}
	})

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return initial, fmt.Errorf("bind setup port: %w", err)
	}
	addr, ok := listener.Addr().(*net.TCPAddr)
	if !ok {
		_ = listener.Close()
		return initial, fmt.Errorf("listener address is not TCP: %T", listener.Addr())
	}

	srv := &http.Server{Handler: mux}
	go func() {
		if err := srv.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			done <- err
		}
	}()
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()

	setupURL := fmt.Sprintf("http://127.0.0.1:%d/setup", addr.Port)
	fmt.Fprintf(os.Stderr, "Setup page: %s\n", setupURL)
	openBrowser(setupURL)

	select {
	case err := <-done:
		if err != nil {
			return result, err
		}
	case <-time.After(10 * time.Minute):
		return result, errors.New("setup timed out")
	}

	mu.Lock()
	out := result
	mu.Unlock()
	return out, nil
}

func openBrowser(u string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", u)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
	default:
		cmd = exec.Command("xdg-open", u)
	}
	_ = cmd.Start()
}
