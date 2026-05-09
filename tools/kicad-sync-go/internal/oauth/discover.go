// OAuth server discovery (RFC 8414) + dynamic client registration (RFC 7591).
//
// Together these let the agent register itself with the EDA server the first
// time it talks to that server, instead of asking the user to manually mint a
// client_id/client_secret on /account and paste them into the setup form.
//
// The redirect_uri we register matches the loopback callback our auth-code
// flow uses. The server's redirectUriMatches accepts any port on a loopback
// host (RFC 8252 §7.3) so the registered URI keeps working even if a future
// build switches LoopbackPort.

package oauth

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/config"
)

// AuthServerMetadata is the subset of the RFC 8414 document we care about.
type AuthServerMetadata struct {
	Issuer                string `json:"issuer"`
	AuthorizationEndpoint string `json:"authorization_endpoint"`
	TokenEndpoint         string `json:"token_endpoint"`
	RegistrationEndpoint  string `json:"registration_endpoint"`
}

// Discover fetches the authorization-server metadata document. Returns a
// helpful error if the server doesn't expose one — that's the case where we
// fall back to manual setup.
func Discover(serverURL string) (AuthServerMetadata, error) {
	url := strings.TrimRight(serverURL, "/") + "/.well-known/oauth-authorization-server"
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return AuthServerMetadata{}, fmt.Errorf("fetch %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return AuthServerMetadata{}, fmt.Errorf("GET %s: HTTP %d", url, resp.StatusCode)
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	var meta AuthServerMetadata
	if err := json.Unmarshal(body, &meta); err != nil {
		return AuthServerMetadata{}, fmt.Errorf("parse metadata: %w", err)
	}
	return meta, nil
}

// Register performs an RFC 7591 dynamic client registration against the
// given endpoint and returns the freshly minted credentials.
func Register(registrationEndpoint, clientName string) (config.ClientCredentials, error) {
	body := map[string]any{
		"client_name":   clientName,
		"redirect_uris": []string{RedirectURI()},
		"scope":         scope,
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return config.ClientCredentials{}, err
	}
	req, err := http.NewRequest("POST", registrationEndpoint, bytes.NewReader(buf))
	if err != nil {
		return config.ClientCredentials{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return config.ClientCredentials{}, fmt.Errorf("POST %s: %w", registrationEndpoint, err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 16*1024))
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		return config.ClientCredentials{}, fmt.Errorf("registration HTTP %d: %s", resp.StatusCode, respBody)
	}
	var payload struct {
		ClientID     string `json:"client_id"`
		ClientSecret string `json:"client_secret"`
	}
	if err := json.Unmarshal(respBody, &payload); err != nil {
		return config.ClientCredentials{}, fmt.Errorf("decode registration response: %w", err)
	}
	if payload.ClientID == "" || payload.ClientSecret == "" {
		return config.ClientCredentials{}, fmt.Errorf("registration response missing client_id/client_secret: %s", respBody)
	}
	return config.ClientCredentials{
		ClientID:     payload.ClientID,
		ClientSecret: payload.ClientSecret,
	}, nil
}

// EnsureClient returns OAuth credentials for serverURL. Order of preference:
//
//  1. Already cached in the ClientStore — return as-is.
//  2. Otherwise: discover the registration endpoint and register a new
//     client. Cache the result for next time.
//
// hostname is best-effort and only used to label the registered client in
// the server's UI (so the user can identify it on /account).
func EnsureClient(serverURL string, store *config.ClientStore) (config.ClientCredentials, error) {
	if store == nil {
		store = config.DefaultClientStore()
	}
	if cached := store.Get(serverURL); cached.ClientID != "" && cached.ClientSecret != "" {
		return cached, nil
	}
	meta, err := Discover(serverURL)
	if err != nil {
		return config.ClientCredentials{}, fmt.Errorf("discover %s: %w", serverURL, err)
	}
	if meta.RegistrationEndpoint == "" {
		return config.ClientCredentials{}, fmt.Errorf(
			"server at %s doesn't advertise a registration_endpoint — "+
				"either run a newer EDA server build or mint a client manually at %s/account",
			serverURL, strings.TrimRight(serverURL, "/"))
	}
	creds, err := Register(meta.RegistrationEndpoint, clientLabel())
	if err != nil {
		return config.ClientCredentials{}, fmt.Errorf("register client: %w", err)
	}
	creds.ServerURL = serverURL
	if err := store.Put(creds); err != nil {
		return creds, fmt.Errorf("save client credentials: %w", err)
	}
	fmt.Fprintf(os.Stderr, "oauth: registered new client %s at %s\n", creds.ClientID, serverURL)
	return creds, nil
}

// clientLabel is what the server shows on its consent + /account pages.
// We use the hostname so a user juggling multiple machines can tell them
// apart at a glance.
func clientLabel() string {
	host, err := os.Hostname()
	if err != nil || host == "" {
		return "EDA Sync (kicad-sync-go)"
	}
	return fmt.Sprintf("EDA Sync — %s", host)
}
