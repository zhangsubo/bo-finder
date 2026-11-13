package gitguard

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zhangsubo/deskside-guard/internal/audit"
)

func runGitCmd(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_AUTHOR_NAME=Test",
		"GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=Test",
		"GIT_COMMITTER_EMAIL=test@example.com",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v failed: %v\n%s", args, err, string(out))
	}
	return strings.TrimSpace(string(out))
}

func TestPrePushCatchesHistoricalCommitSecretAndChainsLocalHook(t *testing.T) {
	tmp := t.TempDir()
	stateDir := filepath.Join(tmp, "state")
	bareDir := filepath.Join(tmp, "remote.git")
	workDir := filepath.Join(tmp, "work")

	if err := os.MkdirAll(bareDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(workDir, 0o755); err != nil {
		t.Fatal(err)
	}

	runGitCmd(t, bareDir, "init", "--bare")
	runGitCmd(t, workDir, "init", "-b", "main")
	runGitCmd(t, workDir, "remote", "add", "origin", bareDir)

	// Initial clean commit pushed to remote.
	if err := os.WriteFile(filepath.Join(workDir, "README.md"), []byte("# Clean Repo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitCmd(t, workDir, "add", "README.md")
	runGitCmd(t, workDir, "commit", "-m", "initial clean")
	baseSHA := runGitCmd(t, workDir, "rev-parse", "HEAD")
	runGitCmd(t, workDir, "push", "origin", "main")

	// Commit 1: introduces a hardcoded secret.
	secret := "ghp_" + "HistoricalSecretToken1234567890abcdef"
	if err := os.WriteFile(filepath.Join(workDir, "config.yaml"), []byte("github_token: "+secret+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitCmd(t, workDir, "add", "config.yaml")
	runGitCmd(t, workDir, "commit", "-m", "add config")

	// Commit 2: removes the secret in HEAD, leaving it buried in Commit 1!
	if err := os.WriteFile(filepath.Join(workDir, "config.yaml"), []byte("github_token: ${GITHUB_TOKEN}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitCmd(t, workDir, "add", "config.yaml")
	runGitCmd(t, workDir, "commit", "-m", "oops remove token")
	headSHA := runGitCmd(t, workDir, "rev-parse", "HEAD")

	stdinLine := "refs/heads/main " + headSHA + " refs/heads/main " + baseSHA + "\n"
	var stderr bytes.Buffer
	code := RunPrePush(stateDir, workDir, "origin", bareDir, strings.NewReader(stdinLine), &stderr)
	if code == 0 {
		t.Fatalf("expected pre-push to block buried secret in historical commit, but exited 0")
	}
	if !strings.Contains(stderr.String(), "GITHUB_TOKEN") {
		t.Fatalf("expected GITHUB_TOKEN in block banner, got:\n%s", stderr.String())
	}
	if strings.Contains(stderr.String(), secret) {
		t.Fatalf("stderr leaked full plaintext secret!")
	}

	// Verify offline audit ledger recorded zero-plaintext event.
	ledger, err := audit.NewLedger(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	events := ledger.ListRecent(10)
	if len(events) == 0 || events[0].Action != "blocked" || events[0].Channel != "git" {
		t.Fatalf("expected blocked git event in ledger, got %+v", events)
	}

	// Reset back to baseSHA, add a clean commit + repo-local pre-push hook, and verify chaining works!
	runGitCmd(t, workDir, "reset", "--hard", baseSHA)
	if err := os.WriteFile(filepath.Join(workDir, "app.go"), []byte("package main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitCmd(t, workDir, "add", "app.go")
	runGitCmd(t, workDir, "commit", "-m", "clean code")
	cleanSHA := runGitCmd(t, workDir, "rev-parse", "HEAD")

	markerFile := filepath.Join(tmp, "local-hook-ran")
	localHookPath := filepath.Join(workDir, ".git", "hooks", "pre-push")
	hookScript := "#!/bin/sh\necho ok > " + markerFile + "\nexit 0\n"
	if err := os.WriteFile(localHookPath, []byte(hookScript), 0o755); err != nil {
		t.Fatal(err)
	}

	var cleanStderr bytes.Buffer
	cleanStdin := "refs/heads/main " + cleanSHA + " refs/heads/main " + baseSHA + "\n"
	if code := RunPrePush(stateDir, workDir, "origin", bareDir, strings.NewReader(cleanStdin), &cleanStderr); code != 0 {
		t.Fatalf("expected clean push to succeed, got code %d: %s", code, cleanStderr.String())
	}
	if _, err := os.Stat(markerFile); err != nil {
		t.Fatalf("expected repo-local pre-push hook to be chained and executed: %v", err)
	}
}

func TestAgentHookBlocksBypassAndPlaceholders(t *testing.T) {
	stateDir := t.TempDir()

	blockedPayloads := []string{
		`{"tool_name":"Bash","tool_input":{"command":"git push origin main --no-verify"}}`,
		`{"tool_name":"Bash","tool_input":{"command":"git commit -nm 'quick'"}}`,
		`{"tool_name":"Bash","tool_input":{"command":"git config --global core.hooksPath /tmp/fake"}}`,
		`{"tool_name":"Write","tool_input":{"file_path":"/repo/.env","content":"API_KEY=<SECRET_1>"}}`,
	}
	for _, p := range blockedPayloads {
		var stderr bytes.Buffer
		if code := RunAgentHook(stateDir, strings.NewReader(p), &stderr); code != 2 {
			t.Fatalf("expected exit code 2 for payload %s, got %d", p, code)
		}
	}

	cleanPayload := `{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}`
	var stderr bytes.Buffer
	if code := RunAgentHook(stateDir, strings.NewReader(cleanPayload), &stderr); code != 0 {
		t.Fatalf("expected clean command to pass, got %d (%s)", code, stderr.String())
	}
}
