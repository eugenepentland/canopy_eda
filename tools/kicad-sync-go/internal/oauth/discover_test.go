package oauth

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/canopy/eda/tools/kicad-sync-go/internal/config"
)

// fakeAuthServer mimics the EDA server's RFC 8414 metadata + RFC 7591
// registration endpoints just enough to exercise EnsureClient.
func fakeAuthServer(t *testing.T) (*httptest.Server, *int) {
	t.Helper()
	registerCalls := 0
	mux := http.NewServeMux()
	srv := httptest.NewServer(mux)
	mux.HandleFunc("/.well-known/oauth-authorization-server", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer":                 srv.URL,
			"authorization_endpoint": srv.URL + "/oauth/authorize",
			"token_endpoint":         srv.URL + "/oauth/token",
			"registration_endpoint":  srv.URL + "/oauth/register",
		})
	})
	mux.HandleFunc("/oauth/register", func(w http.ResponseWriter, r *http.Request) {
		registerCalls++
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"client_id":"eda_c_fake","client_secret":"eda_s_fake"}`))
	})
	t.Cleanup(srv.Close)
	return srv, &registerCalls
}

func TestEnsureClient_RegistersThenCaches(t *testing.T) {
	srv, calls := fakeAuthServer(t)

	tmp := t.TempDir()
	store := &config.ClientStore{Path: filepath.Join(tmp, "clients.json")}

	got, err := EnsureClient(srv.URL, store)
	if err != nil {
		t.Fatalf("first EnsureClient: %v", err)
	}
	if got.ClientID != "eda_c_fake" || got.ClientSecret != "eda_s_fake" {
		t.Fatalf("unexpected creds: %+v", got)
	}
	if *calls != 1 {
		t.Fatalf("want 1 register call, got %d", *calls)
	}

	// Second call must hit the cache, not the network.
	got2, err := EnsureClient(srv.URL, store)
	if err != nil {
		t.Fatalf("second EnsureClient: %v", err)
	}
	if got2 != got {
		t.Fatalf("cache returned different creds: %+v vs %+v", got2, got)
	}
	if *calls != 1 {
		t.Fatalf("cache miss: register called %d times, want 1", *calls)
	}
}

func TestEnsureClient_CanonicalisesServerURL(t *testing.T) {
	srv, calls := fakeAuthServer(t)

	tmp := t.TempDir()
	store := &config.ClientStore{Path: filepath.Join(tmp, "clients.json")}

	if _, err := EnsureClient(srv.URL, store); err != nil {
		t.Fatalf("first: %v", err)
	}
	// Same URL with a trailing slash should still hit the cache.
	if _, err := EnsureClient(srv.URL+"/", store); err != nil {
		t.Fatalf("second: %v", err)
	}
	if *calls != 1 {
		t.Fatalf("trailing-slash variant re-registered: %d calls", *calls)
	}
}

func TestEnsureClient_NoRegistrationEndpoint(t *testing.T) {
	mux := http.NewServeMux()
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	mux.HandleFunc("/.well-known/oauth-authorization-server", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer": srv.URL,
		})
	})

	tmp := t.TempDir()
	store := &config.ClientStore{Path: filepath.Join(tmp, "clients.json")}

	if _, err := EnsureClient(srv.URL, store); err == nil {
		t.Fatal("expected error when registration_endpoint is missing")
	}
}
