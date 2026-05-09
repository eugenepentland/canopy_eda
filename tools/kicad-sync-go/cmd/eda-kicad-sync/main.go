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

	kicadsync "github.com/eugenepentland/canopy_eda/tools/kicad-sync-go"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/config"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/eda"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/kicad"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/notify"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/oauth"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/setup"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/sync"
	"github.com/eugenepentland/canopy_eda/tools/kicad-sync-go/internal/synclog"
)

func main() {
	var (
		setupMode    = flag.Bool("setup", false, "open the setup web page and exit")
		boardArg     = flag.String("board", "", "explicit path to .kicad_pcb (otherwise: ask IPC)")
		prune        = flag.Bool("prune", false, "remove footprints whose canopy_uuid is no longer in the netlist")
		migrate      = flag.Bool("migrate", false, "one-shot heuristic remap: when ref_des doesn't match the design, rename board footprints whose (parent, footprint, value) is uniquely identifiable on both sides. Use this once after upgrading from the legacy Python plugin so existing placements stay attached to the new schematic.")
		installPlug  = flag.Bool("install-kicad-plugin", false, "drop plugin.json and a symlink to this binary into KiCad's per-user plugin folder, then exit. Set EDA_KICAD_PLUGIN_DIR to override the destination.")
	)
	flag.Parse()

	if *installPlug {
		if err := kicadsync.Install(); err != nil {
			fmt.Fprintln(os.Stderr, "install:", err)
			os.Exit(1)
		}
		return
	}

	synclog.Logf("startup args=%v setup=%v board=%q prune=%v migrate=%v",
		os.Args[1:], *setupMode, *boardArg, *prune, *migrate)
	synclog.Logf("env KICAD_API_SOCKET=%q KICAD_API_TOKEN=%s",
		os.Getenv("KICAD_API_SOCKET"),
		synclog.Redact(os.Getenv("KICAD_API_TOKEN")))

	if err := run(*setupMode, *boardArg, *prune, *migrate); err != nil {
		synclog.Logf("FATAL run error: %v", err)
		notify.Show("EDA Sync — error",
			fmt.Sprintf("%s\n\nLog: %s", err.Error(), synclog.Path()))
		os.Exit(1)
	}
	synclog.Logf("run completed cleanly")
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
		// KiCad's GetOpenDocuments returns the bare filename on Windows;
		// stash the orchestrator's authoritative absolute path so per-
		// board library staging writes the .kicad_mod next to the
		// project instead of to the agent's CWD.
		kc.SetBoardPath(boardArg)
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
	// Quiet path: when the diff produced zero ops we don't want to taunt
	// the user with "Updated: 0" — that read like a regression after we
	// stopped counting matched-but-unchanged instances. Keep the version
	// in the toast so they can confirm which design they were synced
	// against.
	if s.Updated == 0 && s.Added == 0 && s.Removed == 0 && s.Swapped == 0 && s.FlaggedStale == 0 {
		return fmt.Sprintf("Already up to date @ v%d", p.DesignVersion)
	}
	out := fmt.Sprintf("Synced @ v%d\n\nUpdated:  %d\nAdded:    %d\nRemoved:  %d\nSwapped:  %d",
		p.DesignVersion, s.Updated, s.Added, s.Removed, s.Swapped)
	if s.FlaggedStale > 0 {
		out += fmt.Sprintf("\nStale (kept): %d", s.FlaggedStale)
	}
	return out
}
