// eda-kicad-sync is the EDA Sync agent invoked by KiCad 10's plugin button.
//
// One binary, two implicit modes dispatched by env + flags:
//
//   - KiCad-spawned mode (KICAD_API_SOCKET is set): connect to the open
//     PCB, read board state, POST to /api/sync-plan, apply ops.
//   - Setup mode (--setup or config incomplete): start a tiny HTTP server
//     on :53683 with a setup form, run OAuth, save config, exit.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/canopy/eda/tools/kicad-sync-go/internal/config"
	"github.com/canopy/eda/tools/kicad-sync-go/internal/eda"
	"github.com/canopy/eda/tools/kicad-sync-go/internal/kicad"
	"github.com/canopy/eda/tools/kicad-sync-go/internal/notify"
	"github.com/canopy/eda/tools/kicad-sync-go/internal/oauth"
	"github.com/canopy/eda/tools/kicad-sync-go/internal/setup"
	"github.com/canopy/eda/tools/kicad-sync-go/internal/sync"
)

func main() {
	var (
		setupMode = flag.Bool("setup", false, "open the setup web page and exit")
		boardArg  = flag.String("board", "", "explicit path to .kicad_pcb (otherwise: ask IPC)")
		prune     = flag.Bool("prune", false, "remove footprints whose canopy_uuid is no longer in the netlist")
		migrate   = flag.Bool("migrate", false, "one-shot heuristic remap: when ref_des doesn't match the design, rename board footprints whose (parent, footprint, value) is uniquely identifiable on both sides. Use this once after upgrading from the legacy Python plugin so existing placements stay attached to the new schematic.")
	)
	flag.Parse()

	if err := run(*setupMode, *boardArg, *prune, *migrate); err != nil {
		notify.Show("EDA Sync — error", err.Error())
		os.Exit(1)
	}
}

func run(setupMode bool, boardArg string, prune, migrate bool) error {
	boardPath, kc, err := openBoard(boardArg)
	if err != nil {
		return err
	}
	if kc != nil {
		defer kc.Close()
	}

	cfg, err := config.LoadBoard(boardPath)
	if err != nil {
		return err
	}

	if setupMode || !cfg.Complete() {
		return runSetup(boardPath, cfg)
	}

	creds, err := resolveClient(cfg)
	if err != nil {
		return fmt.Errorf("OAuth client: %w", err)
	}

	token, err := oauth.EnsureToken(cfg.ServerURL, creds.ClientID, creds.ClientSecret, nil)
	if err != nil {
		return fmt.Errorf("OAuth: %w", err)
	}

	if kc == nil {
		// Setup-only path normally returns earlier; if we reach this
		// branch we have a complete config but couldn't connect to KiCad.
		return errors.New("not connected to KiCad — open a board and click EDA Sync from inside KiCad")
	}

	client := eda.New(cfg.ServerURL, token.AccessToken)
	opts := sync.Options{Prune: prune, MigrateHeuristic: migrate}
	plan, err := sync.Run(client, kc, cfg.Design, opts)
	if errors.Is(err, eda.ErrUnauthorized) {
		// Token revoked — force re-auth once.
		fresh, err2 := oauth.Authorize(cfg.ServerURL, creds.ClientID, creds.ClientSecret)
		if err2 != nil {
			return fmt.Errorf("OAuth retry: %w", err2)
		}
		_ = config.DefaultTokenStore().Put(fresh)
		client = eda.New(cfg.ServerURL, fresh.AccessToken)
		plan, err = sync.Run(client, kc, cfg.Design, opts)
	}
	if err != nil {
		return err
	}

	cfg.LastSyncedVersion = plan.DesignVersion
	_ = config.SaveBoard(boardPath, cfg)
	notify.Show("EDA Sync", summarize(plan))
	return nil
}

func openBoard(boardArg string) (string, kicad.Client, error) {
	// Setup mode flow can be invoked without KiCad running — only require
	// the IPC connection when KICAD_API_SOCKET is actually set.
	if os.Getenv("KICAD_API_SOCKET") == "" {
		if boardArg == "" {
			return "", nil, errors.New(
				"no .kicad_pcb specified and KICAD_API_SOCKET is unset — run from KiCad's button or pass --board")
		}
		return boardArg, nil, nil
	}
	kc, err := kicad.Connect()
	if err != nil {
		return "", nil, err
	}
	if boardArg != "" {
		return boardArg, kc, nil
	}
	path, err := kc.BoardPath()
	if err != nil {
		_ = kc.Close()
		return "", nil, fmt.Errorf("ask KiCad for board path: %w", err)
	}
	return path, kc, nil
}

func runSetup(boardPath string, initial config.BoardConfig) error {
	cfg, err := setup.Run(boardPath, initial)
	if err != nil {
		return fmt.Errorf("setup: %w", err)
	}
	if err := config.SaveBoard(boardPath, cfg); err != nil {
		return fmt.Errorf("save board config: %w", err)
	}
	creds, err := resolveClient(cfg)
	if err != nil {
		return fmt.Errorf("register OAuth client: %w", err)
	}
	tok, err := oauth.Authorize(cfg.ServerURL, creds.ClientID, creds.ClientSecret)
	if err != nil {
		return fmt.Errorf("OAuth authorize: %w", err)
	}
	if err := config.DefaultTokenStore().Put(tok); err != nil {
		return fmt.Errorf("save token: %w", err)
	}
	notify.Show("EDA Sync", "Setup complete. Click EDA Sync again to run the first sync.")
	return nil
}

// resolveClient returns the OAuth credentials for cfg.ServerURL. Order of
// preference:
//
//  1. Legacy ClientID/ClientSecret stored directly in BoardConfig (configs
//     written before dynamic registration landed).
//  2. The shared ClientStore at ~/.config/eda-kicad-sync/clients.json.
//  3. Dynamic registration (RFC 7591) against the server, with the result
//     written through to the ClientStore for next time.
func resolveClient(cfg config.BoardConfig) (config.ClientCredentials, error) {
	if cfg.ClientID != "" && cfg.ClientSecret != "" {
		return config.ClientCredentials{
			ServerURL:    cfg.ServerURL,
			ClientID:     cfg.ClientID,
			ClientSecret: cfg.ClientSecret,
		}, nil
	}
	return oauth.EnsureClient(cfg.ServerURL, nil)
}

func summarize(p *eda.SyncPlanResponse) string {
	s := p.Summary
	out := fmt.Sprintf("Synced @ v%d\n\nUpdated:  %d\nAdded:    %d\nRemoved:  %d\nSwapped:  %d",
		p.DesignVersion, s.Updated, s.Added, s.Removed, s.Swapped)
	if s.FlaggedStale > 0 {
		out += fmt.Sprintf("\nStale (kept): %d", s.FlaggedStale)
	}
	return out
}
