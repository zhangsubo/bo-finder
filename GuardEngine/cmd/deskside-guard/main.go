package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/zhangsubo/deskside-guard/internal/admin"
	"github.com/zhangsubo/deskside-guard/internal/audit"
	"github.com/zhangsubo/deskside-guard/internal/config"
	"github.com/zhangsubo/deskside-guard/internal/detector"
	"github.com/zhangsubo/deskside-guard/internal/gitguard"
	"github.com/zhangsubo/deskside-guard/internal/masker"
	"github.com/zhangsubo/deskside-guard/internal/proxy"
)

var Version = "1.0.0"

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(2)
	}

	subcmd := os.Args[1]
	args := os.Args[2:]

	switch subcmd {
	case "serve":
		os.Exit(runServe(args))
	case "git-pre-push":
		os.Exit(runGitPrePush(args))
	case "git-pre-commit":
		os.Exit(runGitPreCommit(args))
	case "agent-hook":
		os.Exit(runAgentHook(args))
	case "scan":
		os.Exit(runScan(args))
	case "version", "--version", "-v":
		fmt.Printf("deskside-guard %s\n", Version)
		os.Exit(0)
	default:
		printUsage()
		os.Exit(2)
	}
}

func runServe(args []string) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	stateDir := fs.String("state-dir", config.DefaultStateDir(), "state directory")
	listenOverride := fs.String("listen", "", "override listen address")
	if err := fs.Parse(args); err != nil {
		fmt.Fprintf(os.Stderr, "deskside-guard serve: %v\n", err)
		return 2
	}

	var (
		engine  *detector.Engine
		proxySv *proxy.Server
	)

	store, err := config.NewStore(*stateDir, func(updated config.Config) {
		if engine != nil {
			engine.UpdateConfig(updated)
		}
		if proxySv != nil {
			proxySv.ReloadConfig(updated)
		}
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "deskside-guard: init config store failed: %v\n", err)
		return 1
	}

	if *listenOverride != "" {
		cfg := store.Get()
		cfg.ListenAddr = *listenOverride
		_ = store.Update(cfg)
	}

	cfg := store.Get()
	engine = detector.NewEngine(cfg)
	vault := masker.NewVault(45 * time.Minute)

	ledger, err := audit.NewLedger(store.StateDir())
	if err != nil {
		fmt.Fprintf(os.Stderr, "deskside-guard: init audit ledger failed: %v\n", err)
		return 1
	}

	ca, err := proxy.LoadOrCreateCA(store.StateDir())
	if err != nil {
		fmt.Fprintf(os.Stderr, "deskside-guard: init local CA failed: %v\n", err)
		return 1
	}

	bootToken := loadOrCreateGuardToken(store.StateDir())
	proxySv = proxy.NewServer(store, engine, vault, ledger, ca, bootToken)
	adminSv := admin.NewServer(store.StateDir(), Version, bootToken, store, engine, vault, ledger, ca, proxySv)

	if err := adminSv.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "deskside-guard: start admin socket failed: %v\n", err)
		return 1
	}
	if err := proxySv.Start(); err != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = adminSv.Shutdown(ctx)
		cancel()
		fmt.Fprintf(os.Stderr, "deskside-guard: start proxy listener failed: %v\n", err)
		return 1
	}

	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = proxySv.Shutdown(ctx)
	_ = adminSv.Shutdown(ctx)
	return 0
}

func runGitPrePush(args []string) int {
	fs := flag.NewFlagSet("git-pre-push", flag.ContinueOnError)
	stateDir := fs.String("state-dir", config.DefaultStateDir(), "state directory")
	repoDir := fs.String("repo", "", "repository directory")
	if err := fs.Parse(args); err != nil {
		return 0
	}
	rest := fs.Args()
	var remoteName, remoteURL string
	if len(rest) >= 1 {
		remoteName = rest[0]
	}
	if len(rest) >= 2 {
		remoteURL = rest[1]
	}
	return gitguard.RunPrePush(*stateDir, *repoDir, remoteName, remoteURL, os.Stdin, os.Stderr)
}

func runGitPreCommit(args []string) int {
	fs := flag.NewFlagSet("git-pre-commit", flag.ContinueOnError)
	stateDir := fs.String("state-dir", config.DefaultStateDir(), "state directory")
	repoDir := fs.String("repo", "", "repository directory")
	if err := fs.Parse(args); err != nil {
		return 0
	}
	return gitguard.RunPreCommit(*stateDir, *repoDir, os.Stderr)
}

func runAgentHook(args []string) int {
	fs := flag.NewFlagSet("agent-hook", flag.ContinueOnError)
	stateDir := fs.String("state-dir", config.DefaultStateDir(), "state directory")
	if err := fs.Parse(args); err != nil {
		return 0
	}
	return gitguard.RunAgentHook(*stateDir, os.Stdin, os.Stderr)
}

func runScan(args []string) int {
	fs := flag.NewFlagSet("scan", flag.ContinueOnError)
	stateDir := fs.String("state-dir", config.DefaultStateDir(), "state directory")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	store, err := config.NewStore(*stateDir, nil)
	cfg := config.Default()
	if err == nil {
		cfg = store.Get()
	}
	engine := detector.NewEngine(cfg)

	files := fs.Args()
	var all []detector.Finding
	if len(files) == 0 {
		raw, err := io.ReadAll(os.Stdin)
		if err != nil {
			return 1
		}
		all = engine.Analyze(string(raw), detector.ScanOptions{})
	} else {
		for _, fp := range files {
			raw, err := os.ReadFile(fp)
			if err != nil {
				continue
			}
			all = append(all, engine.Analyze(string(raw), detector.ScanOptions{FilePath: fp})...)
		}
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(map[string]any{
		"count":    len(all),
		"findings": all,
	})
	if len(all) > 0 {
		return 1
	}
	return 0
}

func loadOrCreateGuardToken(stateDir string) string {
	tokFile := stateDir + "/guard.token"
	if data, err := os.ReadFile(tokFile); err == nil {
		trimmed := string(data)
		if len(trimmed) >= 32 {
			return trimmed[:64]
		}
	}
	var b [32]byte
	_, _ = rand.Read(b[:])
	tok := hex.EncodeToString(b[:])
	_ = os.WriteFile(tokFile, []byte(tok), 0o600)
	_ = os.Chmod(tokFile, 0o600)
	return tok
}

func printUsage() {
	fmt.Fprintln(os.Stderr, "Usage: deskside-guard <serve|git-pre-push|git-pre-commit|agent-hook|scan|version> [options]")
}
