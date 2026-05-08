// Package config persists per-board sync configuration and OAuth tokens.
//
// Per-board config lives next to the .kicad_pcb as `<board>.eda-sync.json` so
// it travels with the project. OAuth tokens live in a global cache keyed on
// (server_url, client_id) so multiple boards can share an auth.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// BoardConfig is the shape of <board>.eda-sync.json.
//
// ClientID/ClientSecret are kept for back-compat with configs written before
// dynamic client registration (RFC 7591) landed. New setups leave them
// empty; the agent looks up (or mints) credentials in the per-server
// ClientStore instead, keyed by ServerURL.
type BoardConfig struct {
	ServerURL         string `json:"server_url"`
	Design            string `json:"design"`
	ClientID          string `json:"client_id,omitempty"`
	ClientSecret      string `json:"client_secret,omitempty"`
	LastSyncedVersion int    `json:"last_synced_version"`
}

// Complete reports whether the config has the fields needed to start a sync.
// Client credentials are obtained via the ClientStore / dynamic registration,
// so they are no longer required here.
func (c BoardConfig) Complete() bool {
	return c.ServerURL != "" && c.Design != ""
}

// LoadBoard reads <boardPath>.eda-sync.json. Missing file → zero-value config + nil error.
func LoadBoard(boardPath string) (BoardConfig, error) {
	var c BoardConfig
	data, err := os.ReadFile(boardConfigPath(boardPath))
	if errors.Is(err, os.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(data, &c); err != nil {
		return c, fmt.Errorf("parse board config: %w", err)
	}
	return c, nil
}

// SaveBoard writes <boardPath>.eda-sync.json atomically with mode 0600.
func SaveBoard(boardPath string, c BoardConfig) error {
	path := boardConfigPath(boardPath)
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(path, data, 0o600)
}

func boardConfigPath(boardPath string) string {
	return boardPath + ".eda-sync.json"
}

// TokenRecord is one cached OAuth access token.
type TokenRecord struct {
	ServerURL   string `json:"server_url"`
	ClientID    string `json:"client_id"`
	AccessToken string `json:"access_token"`
	ExpiresAt   int64  `json:"expires_at"`
	Scope       string `json:"scope"`
}

// Fresh reports whether the token is still valid with a 60s leeway.
func (t TokenRecord) Fresh() bool {
	return t.AccessToken != "" && time.Now().Unix()+60 < t.ExpiresAt
}

// TokenStore is a JSON file at ~/.config/eda-kicad-sync/tokens.json.
type TokenStore struct {
	Path string
}

// DefaultTokenStore returns a TokenStore at the user's standard config dir.
func DefaultTokenStore() *TokenStore {
	home, _ := os.UserHomeDir()
	return &TokenStore{Path: filepath.Join(home, ".config", "eda-kicad-sync", "tokens.json")}
}

func (s *TokenStore) read() map[string]TokenRecord {
	out := map[string]TokenRecord{}
	data, err := os.ReadFile(s.Path)
	if err != nil {
		return out
	}
	_ = json.Unmarshal(data, &out)
	return out
}

func (s *TokenStore) write(m map[string]TokenRecord) error {
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(s.Path, data, 0o600)
}

// canonicalServerURL strips trailing slashes so a token saved with
// "https://x.dev" matches a lookup with "https://x.dev/" and vice versa.
// Without this, a stray slash in the per-board config triggers re-auth on
// every click.
func canonicalServerURL(s string) string {
	for len(s) > 0 && s[len(s)-1] == '/' {
		s = s[:len(s)-1]
	}
	return s
}

func tokenKey(serverURL, clientID string) string {
	return canonicalServerURL(serverURL) + "#" + clientID
}

// Get fetches the cached record for (serverURL, clientID), or zero-value if missing.
func (s *TokenStore) Get(serverURL, clientID string) TokenRecord {
	return s.read()[tokenKey(serverURL, clientID)]
}

// Put stores or replaces the record. The stored ServerURL is canonicalised
// so subsequent Get calls match regardless of trailing-slash variation.
func (s *TokenStore) Put(rec TokenRecord) error {
	rec.ServerURL = canonicalServerURL(rec.ServerURL)
	m := s.read()
	m[tokenKey(rec.ServerURL, rec.ClientID)] = rec
	return s.write(m)
}

// ClientCredentials is one OAuth client registered against a given server.
type ClientCredentials struct {
	ServerURL    string `json:"server_url"`
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
}

// ClientStore is a JSON file at ~/.config/eda-kicad-sync/clients.json mapping
// canonical server URL → (client_id, client_secret). One client is shared
// across all boards that talk to the same server, so we don't re-register
// every time the user opens a new PCB.
type ClientStore struct {
	Path string
}

// DefaultClientStore returns a ClientStore at the user's standard config dir.
func DefaultClientStore() *ClientStore {
	home, _ := os.UserHomeDir()
	return &ClientStore{Path: filepath.Join(home, ".config", "eda-kicad-sync", "clients.json")}
}

func (s *ClientStore) read() map[string]ClientCredentials {
	out := map[string]ClientCredentials{}
	data, err := os.ReadFile(s.Path)
	if err != nil {
		return out
	}
	_ = json.Unmarshal(data, &out)
	return out
}

func (s *ClientStore) write(m map[string]ClientCredentials) error {
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(s.Path, data, 0o600)
}

// Get returns the cached credentials for serverURL, or zero-value if missing.
func (s *ClientStore) Get(serverURL string) ClientCredentials {
	return s.read()[canonicalServerURL(serverURL)]
}

// Put stores or replaces credentials. ServerURL is canonicalised so a stored
// entry from "https://x.dev" matches a lookup with "https://x.dev/".
func (s *ClientStore) Put(rec ClientCredentials) error {
	rec.ServerURL = canonicalServerURL(rec.ServerURL)
	m := s.read()
	m[rec.ServerURL] = rec
	return s.write(m)
}

// Delete removes any cached credentials for serverURL. Used when the server
// rejects the stored client (e.g. operator deleted it on /account) so the
// next call re-registers cleanly.
func (s *ClientStore) Delete(serverURL string) error {
	m := s.read()
	delete(m, canonicalServerURL(serverURL))
	return s.write(m)
}

// CacheRoot is the per-(server, design) directory used by ObjectCache and the
// Python plugin's cache. Kept under ~/.cache/eda-kicad-sync/.
func CacheRoot(serverURL, design string) string {
	home, _ := os.UserHomeDir()
	safe := serverURL
	for _, c := range []string{"://", "/", ":"} {
		safe = replaceAll(safe, c, "_")
	}
	return filepath.Join(home, ".cache", "eda-kicad-sync", safe, design)
}

func replaceAll(s, old, new string) string {
	out := ""
	for {
		i := indexOf(s, old)
		if i < 0 {
			return out + s
		}
		out += s[:i] + new
		s = s[i+len(old):]
	}
}

func indexOf(s, sub string) int {
	if len(sub) == 0 {
		return 0
	}
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
