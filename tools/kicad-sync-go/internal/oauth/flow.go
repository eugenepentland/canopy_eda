// Package oauth implements an authorization-code + PKCE client for the EDA
// server, mirroring what the MCP / Python plugin uses.
//
// The redirect URI is fixed at http://127.0.0.1:53682/callback because the
// server enforces strict redirect_uri equality; the user must register that
// exact value when minting the client_id.
package oauth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/canopy/eda/tools/kicad-sync-go/internal/config"
)

const (
	// PreferredPort is what we try to bind first so the redirect URI is
	// stable and recognisable in logs. If something else is already using
	// it (VS Code and similar dev tools randomly grab dynamic ports in
	// this range), we fall back to an OS-assigned free port — the EDA
	// server's redirect_uri matcher accepts any port on a loopback host.
	PreferredPort = 53682
	redirectPath  = "/callback"
	scope         = "mcp"
)

// RedirectURI is the canonical loopback redirect URI registered with the
// server during dynamic client registration. The OAuth flow may use a
// different port at runtime when PreferredPort is busy; the server's
// loopback matcher accepts that.
func RedirectURI() string {
	return fmt.Sprintf("http://127.0.0.1:%d%s", PreferredPort, redirectPath)
}

func redirectURIForPort(port int) string {
	return fmt.Sprintf("http://127.0.0.1:%d%s", port, redirectPath)
}

// bindLoopback tries PreferredPort first, then falls back to an OS-assigned
// free port. Returns the listener + the port it actually bound.
func bindLoopback() (net.Listener, int, error) {
	if l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", PreferredPort)); err == nil {
		return l, PreferredPort, nil
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, 0, fmt.Errorf("no loopback port available (preferred %d busy and OS-assigned bind failed): %w", PreferredPort, err)
	}
	addr, ok := l.Addr().(*net.TCPAddr)
	if !ok {
		_ = l.Close()
		return nil, 0, fmt.Errorf("listener address is not TCP: %T", l.Addr())
	}
	return l, addr.Port, nil
}

// EnsureToken returns a fresh access token, running the browser auth dance
// only when the cached token is missing or expired.
func EnsureToken(serverURL, clientID, clientSecret string, store *config.TokenStore) (config.TokenRecord, error) {
	if store == nil {
		store = config.DefaultTokenStore()
	}
	cached := store.Get(serverURL, clientID)
	if cached.Fresh() {
		fmt.Fprintf(os.Stderr, "oauth: cache HIT for %s (expires_at=%d, now=%d)\n",
			clientID, cached.ExpiresAt, time.Now().Unix())
		return cached, nil
	}
	fmt.Fprintf(os.Stderr,
		"oauth: cache MISS for client_id=%s server=%s (cached.token=%q, cached.expires_at=%d, now=%d) — opening browser\n",
		clientID, serverURL, cached.AccessToken, cached.ExpiresAt, time.Now().Unix())
	rec, err := Authorize(serverURL, clientID, clientSecret)
	if err != nil {
		return config.TokenRecord{}, err
	}
	if err := store.Put(rec); err != nil {
		return rec, fmt.Errorf("save token: %w", err)
	}
	fmt.Fprintf(os.Stderr, "oauth: token saved at %s\n", store.Path)
	return rec, nil
}

// Authorize runs the auth-code+PKCE dance once and returns a fresh token.
// Side effect: opens the user's browser to the authorize URL and binds a
// loopback port to capture the callback.
func Authorize(serverURL, clientID, clientSecret string) (config.TokenRecord, error) {
	listener, port, err := bindLoopback()
	if err != nil {
		return config.TokenRecord{}, err
	}
	redirectURI := redirectURIForPort(port)

	verifier := genVerifier()
	challenge := s256(verifier)
	state := genState()

	q := url.Values{}
	q.Set("response_type", "code")
	q.Set("client_id", clientID)
	q.Set("redirect_uri", redirectURI)
	q.Set("scope", scope)
	q.Set("state", state)
	q.Set("code_challenge", challenge)
	q.Set("code_challenge_method", "S256")
	authURL := strings.TrimRight(serverURL, "/") + "/oauth/authorize?" + q.Encode()

	openBrowser(authURL)

	captured, err := waitForCodeOn(listener, state, 3*time.Minute)
	if err != nil {
		return config.TokenRecord{}, err
	}

	return exchangeCode(serverURL, clientID, clientSecret, captured.code, verifier, redirectURI)
}

type capture struct {
	code  string
	state string
	err   string
}

// waitForCodeOn serves the callback on a listener that the caller has
// already bound. The caller-bound model means we surface "port in use"
// errors before opening the browser; the listener is closed when this
// function returns.
func waitForCodeOn(listener net.Listener, expectState string, timeout time.Duration) (capture, error) {
	out := make(chan capture, 1)
	mux := http.NewServeMux()
	mux.HandleFunc(redirectPath, func(w http.ResponseWriter, r *http.Request) {
		c := capture{
			code:  r.URL.Query().Get("code"),
			state: r.URL.Query().Get("state"),
			err:   r.URL.Query().Get("error"),
		}
		_, _ = io.WriteString(w,
			"<html><body><h2>EDA Sync authorized</h2>"+
				"<p>You can close this tab and return to KiCad.</p></body></html>")
		select {
		case out <- c:
		default:
		}
	})

	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(listener) }()
	defer srv.Close()

	select {
	case c := <-out:
		if c.err != "" {
			return c, fmt.Errorf("OAuth error from server: %s", c.err)
		}
		if c.state != expectState {
			return c, errors.New("OAuth state mismatch — possible CSRF")
		}
		if c.code == "" {
			return c, errors.New("OAuth callback missing code")
		}
		return c, nil
	case <-time.After(timeout):
		return capture{}, errors.New("OAuth callback timed out")
	}
}

func exchangeCode(serverURL, clientID, clientSecret, code, verifier, redirectURI string) (config.TokenRecord, error) {
	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("code", code)
	form.Set("redirect_uri", redirectURI)
	form.Set("client_id", clientID)
	form.Set("client_secret", clientSecret)
	form.Set("code_verifier", verifier)

	tokenURL := strings.TrimRight(serverURL, "/") + "/oauth/token"
	req, err := http.NewRequest("POST", tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return config.TokenRecord{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return config.TokenRecord{}, fmt.Errorf("token exchange: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 16*1024))
	if resp.StatusCode != http.StatusOK {
		return config.TokenRecord{}, fmt.Errorf("token exchange HTTP %d: %s", resp.StatusCode, body)
	}

	var payload struct {
		AccessToken string `json:"access_token"`
		TokenType   string `json:"token_type"`
		ExpiresIn   int    `json:"expires_in"`
		Scope       string `json:"scope"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return config.TokenRecord{}, fmt.Errorf("decode token response: %w", err)
	}

	return config.TokenRecord{
		ServerURL:   strings.TrimRight(serverURL, "/"),
		ClientID:    clientID,
		AccessToken: payload.AccessToken,
		ExpiresAt:   time.Now().Unix() + int64(payload.ExpiresIn),
		Scope:       payload.Scope,
	}, nil
}

// ── helpers ────────────────────────────────────────────────────────────

func genVerifier() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return strings.TrimRight(base64.URLEncoding.EncodeToString(b), "=")
}

func s256(v string) string {
	sum := sha256.Sum256([]byte(v))
	return strings.TrimRight(base64.URLEncoding.EncodeToString(sum[:]), "=")
}

func genState() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return strings.TrimRight(base64.URLEncoding.EncodeToString(b), "=")
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
	// Best-effort fallback: print the URL so a user without a default
	// browser handler can still complete auth.
	fmt.Fprintf(io.Discard, "open this URL to authorize: %s\n", u)
}
