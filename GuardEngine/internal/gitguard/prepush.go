package gitguard

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/zhangsubo/deskside-guard/internal/audit"
	"github.com/zhangsubo/deskside-guard/internal/config"
	"github.com/zhangsubo/deskside-guard/internal/detector"
)

var (
	hunkHeaderRe       = regexp.MustCompile(`^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@`)
	gitBypassFlagRe    = regexp.MustCompile(`(?:^|\s)git\s+(?:[^\n;|&]*\s+)?(?:commit|push|merge|cherry-pick|rebase)\b[^\n;|&]*(?:\s--no-verify\b|\s-[A-Za-z]*n[A-Za-z]*\b)`)
	gitHooksTamperRe   = regexp.MustCompile(`(?:^|\s)git\s+config\b[^\n;|&]*\bcore\.hooksPath\b`)
	guardStateTamperRe = regexp.MustCompile(`(?:\.config/deskside-guard|deskside-guard\.sgmodule|hop-router\.js)`)
	leakedTokenRe      = regexp.MustCompile(`<(?:SECRET|DB_URI|PRIVATE_KEY|CUSTOM)_\d+>`)
)

type Hit struct {
	Commit        string
	FilePath      string
	Line          int
	Category      string
	RuleName      string
	MaskedPreview string
	Fingerprint   string
}

type internalScanRequest struct {
	Text     string `json:"text"`
	FilePath string `json:"filePath"`
}

type internalScanResponse struct {
	Findings []detector.Finding `json:"findings"`
}

// RunPrePush inspects all commits about to be pushed to a remote, blocks on any secret hit,
// and chains to any repository-local `.git/hooks/pre-push` if clean.
func RunPrePush(stateDir, repoDir, remoteName, remoteURL string, stdin io.Reader, stderr io.Writer) int {
	rawStdin, err := io.ReadAll(stdin)
	if err != nil {
		return 0
	}

	sc := newScanner(stateDir)
	sc.recordGitScan()

	target := remoteURL
	if target == "" {
		target = remoteName
	}
	if target == "" {
		target = "git-remote"
	}

	var allHits []Hit
	lineScanner := bufio.NewScanner(bytes.NewReader(rawStdin))
	for lineScanner.Scan() {
		fields := strings.Fields(lineScanner.Text())
		if len(fields) < 4 {
			continue
		}
		localSHA := fields[1]
		remoteSHA := fields[3]
		if isAllZeros(localSHA) {
			// Deleting a remote ref sends no new blobs.
			continue
		}

		var args []string
		if isAllZeros(remoteSHA) {
			args = []string{"log", "--format=__GUARD_COMMIT__%H", "-p", "--no-color", "-U0", localSHA}
			if remoteName != "" {
				args = append(args, "--not", "--remotes="+remoteName)
			}
		} else {
			args = []string{"log", "--format=__GUARD_COMMIT__%H", "-p", "--no-color", "-U0", remoteSHA + ".." + localSHA}
		}

		diffOut, gitErr := runGitOutput(repoDir, args...)
		if gitErr != nil || len(diffOut) == 0 {
			continue
		}
		hits := sc.scanUnifiedDiff(diffOut, "")
		allHits = append(allHits, hits...)
		if len(allHits) >= 25 {
			break
		}
	}

	if len(allHits) > 0 {
		sc.reportBlockedHits("Git Push", target, allHits)
		printBlockBanner(stderr, "git push", target, allHits)
		return 1
	}

	return chainRepoLocalHook(repoDir, "pre-push", []string{remoteName, remoteURL}, rawStdin, stderr)
}

// RunPreCommit inspects staged changes (`git diff --cached`) and chains to repo-local `pre-commit`.
func RunPreCommit(stateDir, repoDir string, stderr io.Writer) int {
	sc := newScanner(stateDir)
	sc.recordGitScan()

	diffOut, err := runGitOutput(repoDir, "diff", "--cached", "--no-color", "-U0")
	if err == nil && len(diffOut) > 0 {
		hits := sc.scanUnifiedDiff(diffOut, "staged")
		if len(hits) > 0 {
			sc.reportBlockedHits("Git Commit", "staged", hits)
			printBlockBanner(stderr, "git commit", "staged index", hits)
			return 1
		}
	}

	return chainRepoLocalHook(repoDir, "pre-commit", nil, nil, stderr)
}

// RunAgentHook inspects Claude Code / Codex PreToolUse payloads on stdin to prevent
// agents from bypassing Git hooks, tampering with DeskSide Guard config, or writing placeholders to disk.
func RunAgentHook(stateDir string, stdin io.Reader, stderr io.Writer) int {
	raw, err := io.ReadAll(io.LimitReader(stdin, 2*1024*1024))
	if err != nil || len(bytes.TrimSpace(raw)) == 0 {
		return 0
	}

	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		return 0
	}

	toolName := firstString(payload, "tool_name", "tool", "name")
	toolInput, _ := payload["tool_input"].(map[string]any)
	if toolInput == nil {
		toolInput, _ = payload["input"].(map[string]any)
	}
	if toolInput == nil {
		return 0
	}

	sc := newScanner(stateDir)

	// 1. Check shell/bash commands for hook bypass or guard tampering.
	cmdStr := firstString(toolInput, "command", "cmd")
	if cmdStr != "" {
		if gitBypassFlagRe.MatchString(cmdStr) {
			sc.reportTamper("Agent Hook", "blocked --no-verify git hook bypass")
			fmt.Fprintln(stderr, "[DeskSide 安全网关] 已拦截：禁止使用 --no-verify / -n 绕过 Git 密钥安全检查。")
			return 2
		}
		if gitHooksTamperRe.MatchString(cmdStr) || guardStateTamperRe.MatchString(cmdStr) {
			sc.reportTamper("Agent Hook", "blocked guard/hooksPath configuration tamper")
			fmt.Fprintln(stderr, "[DeskSide 安全网关] 已拦截：禁止 Agent 修改 core.hooksPath 或安全网关受保护配置。")
			return 2
		}
	}

	// 2. Check file write/edit targets & placeholder leakage.
	targetPath := firstString(toolInput, "file_path", "path", "target_file")
	if targetPath != "" {
		normPath := filepath.ToSlash(targetPath)
		if strings.Contains(normPath, ".config/deskside-guard") ||
			strings.Contains(normPath, "deskside-guard.sgmodule") ||
			strings.Contains(normPath, "hop-router.js") ||
			strings.Contains(normPath, ".git/hooks/") {
			sc.reportTamper("Agent Hook", "blocked protected file write: "+filepath.Base(normPath))
			fmt.Fprintf(stderr, "[DeskSide 安全网关] 已拦截：禁止 Agent 直接修改安全守护文件 (%s)。\n", targetPath)
			return 2
		}
	}

	for _, contentKey := range []string{"content", "new_string", "replacement", "patch"} {
		if val, ok := toolInput[contentKey].(string); ok && val != "" {
			if m := leakedTokenRe.FindString(val); m != "" {
				fmt.Fprintf(stderr, "[DeskSide 安全网关] 已拦截 (%s)：检测到未还原的脱敏占位符 %s，已阻止写入源文件以免损坏配置。\n", toolName, m)
				return 2
			}
		}
	}

	return 0
}

type diffScanner struct {
	stateDir    string
	sockPath    string
	localEngine *detector.Engine
	unixClient  *http.Client
}

func newScanner(stateDir string) *diffScanner {
	if stateDir == "" {
		stateDir = config.DefaultStateDir()
	}
	store, err := config.NewStore(stateDir, nil)
	cfg := config.Default()
	if err == nil {
		cfg = store.Get()
	}
	sockPath := config.AdminSocketPath(stateDir)

	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", sockPath)
		},
	}

	return &diffScanner{
		stateDir:    stateDir,
		sockPath:    sockPath,
		localEngine: detector.NewEngine(cfg),
		unixClient: &http.Client{
			Transport: transport,
			Timeout:   250 * time.Millisecond,
		},
	}
}

func (s *diffScanner) analyzeText(text, filePath string) []detector.Finding {
	if strings.TrimSpace(text) == "" {
		return nil
	}
	// Prefer live daemon scan so DeskSide EnvManager secrets in daemon memory are included!
	reqPayload, err := json.Marshal(internalScanRequest{
		Text:     text,
		FilePath: filePath,
	})
	if err == nil {
		resp, postErr := s.unixClient.Post("http://unix/v1/internal/scan", "application/json", bytes.NewReader(reqPayload))
		if postErr == nil {
			defer resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				var parsed internalScanResponse
				if decErr := json.NewDecoder(resp.Body).Decode(&parsed); decErr == nil {
					return parsed.Findings
				}
			}
		}
	}
	return s.localEngine.Analyze(text, detector.ScanOptions{FilePath: filePath})
}

func (s *diffScanner) scanUnifiedDiff(diffBytes []byte, defaultCommit string) []Hit {
	var hits []Hit
	currentCommit := defaultCommit
	currentFile := ""
	currentNewLine := 0

	var addedLines []string
	blockStartLine := 0

	flushAddedBlock := func() {
		if len(addedLines) == 0 {
			return
		}
		joined := strings.Join(addedLines, "\n")
		findings := s.analyzeText(joined, currentFile)
		for _, f := range findings {
			lineOffset := 0
			if f.Start > 0 && f.Start <= len(joined) {
				lineOffset = strings.Count(joined[:f.Start], "\n")
			}
			hits = append(hits, Hit{
				Commit:        currentCommit,
				FilePath:      currentFile,
				Line:          blockStartLine + lineOffset,
				Category:      f.Category,
				RuleName:      f.RuleName,
				MaskedPreview: f.MaskedPreview,
				Fingerprint:   f.Fingerprint,
			})
		}
		addedLines = addedLines[:0]
	}

	scanner := bufio.NewScanner(bytes.NewReader(diffBytes))
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()

		if strings.HasPrefix(line, "__GUARD_COMMIT__") {
			flushAddedBlock()
			sha := strings.TrimSpace(strings.TrimPrefix(line, "__GUARD_COMMIT__"))
			if len(sha) > 8 {
				sha = sha[:8]
			}
			currentCommit = sha
			currentFile = ""
			currentNewLine = 0
			continue
		}

		if strings.HasPrefix(line, "diff --git ") {
			flushAddedBlock()
			currentNewLine = 0
			continue
		}

		if strings.HasPrefix(line, "+++ ") {
			flushAddedBlock()
			rawPath := strings.TrimSpace(strings.TrimPrefix(line, "+++ "))
			if rawPath == "/dev/null" {
				currentFile = ""
			} else {
				currentFile = strings.TrimPrefix(rawPath, "b/")
			}
			continue
		}

		if m := hunkHeaderRe.FindStringSubmatch(line); len(m) == 2 {
			flushAddedBlock()
			n, _ := strconv.Atoi(m[1])
			currentNewLine = n
			continue
		}

		if currentNewLine > 0 && strings.HasPrefix(line, "+") && !strings.HasPrefix(line, "+++") {
			if len(addedLines) == 0 {
				blockStartLine = currentNewLine
			}
			addedLines = append(addedLines, line[1:])
			currentNewLine++
			continue
		}

		flushAddedBlock()
		if currentNewLine > 0 && strings.HasPrefix(line, " ") {
			currentNewLine++
		}
	}
	flushAddedBlock()

	return hits
}

func (s *diffScanner) recordGitScan() {
	resp, err := s.unixClient.Post("http://unix/v1/internal/git-scan", "application/json", bytes.NewReader([]byte(`{}`)))
	if err == nil {
		_ = resp.Body.Close()
		return
	}
	if ledger, lErr := audit.NewLedger(s.stateDir); lErr == nil {
		ledger.RecordScan("git")
	}
}

func (s *diffScanner) reportBlockedHits(clientName, target string, hits []Hit) {
	var offlineLedger *audit.Ledger
	for _, h := range hits {
		loc := fmt.Sprintf("%s:%d", h.FilePath, h.Line)
		if h.Commit != "" && h.Commit != "staged" {
			loc = fmt.Sprintf("%s:%s:%d", h.Commit, h.FilePath, h.Line)
		}
		ev := audit.Event{
			Timestamp:     time.Now(),
			Channel:       "git",
			Action:        "blocked",
			Target:        target,
			Client:        clientName,
			Category:      h.Category,
			RuleName:      h.RuleName,
			MaskedPreview: h.MaskedPreview,
			Fingerprint:   h.Fingerprint,
			Location:      loc,
			Count:         1,
		}
		if !s.postEventToDaemon(ev) {
			if offlineLedger == nil {
				offlineLedger, _ = audit.NewLedger(s.stateDir)
			}
			if offlineLedger != nil {
				offlineLedger.Record(ev)
			}
		}
	}
}

func (s *diffScanner) reportTamper(clientName, detail string) {
	ev := audit.Event{
		Timestamp:     time.Now(),
		Channel:       "git",
		Action:        "blocked",
		Target:        "local-guard",
		Client:        clientName,
		Category:      "GUARD_TAMPER",
		RuleName:      "HOOK_BYPASS_ATTEMPT",
		MaskedPreview: "••••••",
		Fingerprint:   "guard:tamper",
		Location:      detail,
		Count:         1,
	}
	if !s.postEventToDaemon(ev) {
		if ledger, err := audit.NewLedger(s.stateDir); err == nil {
			ledger.Record(ev)
		}
	}
}

func (s *diffScanner) postEventToDaemon(ev audit.Event) bool {
	data, err := json.Marshal(ev)
	if err != nil {
		return false
	}
	resp, err := s.unixClient.Post("http://unix/v1/internal/event", "application/json", bytes.NewReader(data))
	if err != nil {
		return false
	}
	_ = resp.Body.Close()
	return resp.StatusCode >= 200 && resp.StatusCode < 300
}

func printBlockBanner(w io.Writer, opName, target string, hits []Hit) {
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "╔══════════════════════════════════════════════════════════════════╗")
	fmt.Fprintf(w, "║  DeskSide 安全网关：已拦截包含敏感凭据的 %-23s ║\n", opName)
	fmt.Fprintln(w, "╚══════════════════════════════════════════════════════════════════╝")
	fmt.Fprintf(w, "  目标远端: %s\n", target)
	limit := len(hits)
	if limit > 10 {
		limit = 10
	}
	for i := 0; i < limit; i++ {
		h := hits[i]
		prefix := ""
		if h.Commit != "" {
			prefix = h.Commit + " · "
		}
		fmt.Fprintf(w, "  [%d] %s%s:%d\n", i+1, prefix, h.FilePath, h.Line)
		fmt.Fprintf(w, "      规则: %s (%s)  预览: %s  指纹: %s\n", h.RuleName, h.Category, h.MaskedPreview, h.Fingerprint)
	}
	if len(hits) > limit {
		fmt.Fprintf(w, "  ... 以及其余 %d 处命中\n", len(hits)-limit)
	}
	fmt.Fprintln(w, "  提示: 请将硬编码密钥迁移至环境变量（DeskSide 环境变量面板），并清理历史提交后再推送。")
	fmt.Fprintln(w, "        如确认属于测试假数据，可在 DeskSide -> 安全网关 -> 策略与规则 中将该指纹加入白名单。")
	fmt.Fprintln(w, "")
}

func chainRepoLocalHook(repoDir, hookName string, args []string, stdinBytes []byte, stderr io.Writer) int {
	commonDirBytes, err := runGitOutput(repoDir, "rev-parse", "--git-common-dir")
	if err != nil {
		return 0
	}
	commonDir := strings.TrimSpace(string(commonDirBytes))
	if commonDir == "" {
		return 0
	}
	if !filepath.IsAbs(commonDir) && repoDir != "" {
		commonDir = filepath.Join(repoDir, commonDir)
	}
	localHook := filepath.Join(commonDir, "hooks", hookName)

	info, err := os.Stat(localHook)
	if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
		return 0
	}

	// Prevent infinite recursion if localHook resolves to current executable or global hooks directory.
	resolvedLocal, err := filepath.EvalSymlinks(localHook)
	if err != nil {
		resolvedLocal = filepath.Clean(localHook)
	}
	if selfExe, exeErr := os.Executable(); exeErr == nil {
		if resolvedSelf, symErr := filepath.EvalSymlinks(selfExe); symErr == nil && resolvedSelf == resolvedLocal {
			return 0
		}
	}
	if globalHooksOut, gErr := runGitOutput(repoDir, "config", "--global", "--get", "core.hooksPath"); gErr == nil {
		gh := strings.TrimSpace(string(globalHooksOut))
		if strings.HasPrefix(gh, "~/") {
			if home, hErr := os.UserHomeDir(); hErr == nil {
				gh = filepath.Join(home, gh[2:])
			}
		}
		if gh != "" {
			candidateGlobal := filepath.Join(gh, hookName)
			if resolvedGlobal, symErr := filepath.EvalSymlinks(candidateGlobal); symErr == nil && resolvedGlobal == resolvedLocal {
				return 0
			}
			if filepath.Clean(candidateGlobal) == resolvedLocal {
				return 0
			}
		}
	}

	cmd := exec.Command(localHook, args...)
	if repoDir != "" {
		cmd.Dir = repoDir
	}
	if stdinBytes != nil {
		cmd.Stdin = bytes.NewReader(stdinBytes)
	}
	cmd.Stdout = stderr
	cmd.Stderr = stderr
	if runErr := cmd.Run(); runErr != nil {
		if exitErr, ok := runErr.(*exec.ExitError); ok {
			return exitErr.ExitCode()
		}
		return 1
	}
	return 0
}

func runGitOutput(repoDir string, args ...string) ([]byte, error) {
	fullArgs := append([]string{"-c", "core.quotepath=false"}, args...)
	cmd := exec.Command("git", fullArgs...)
	if repoDir != "" {
		cmd.Dir = repoDir
	}
	return cmd.Output()
}

func isAllZeros(sha string) bool {
	if len(sha) == 0 {
		return true
	}
	for i := 0; i < len(sha); i++ {
		if sha[i] != '0' {
			return false
		}
	}
	return true
}

func firstString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if s, ok := m[k].(string); ok && strings.TrimSpace(s) != "" {
			return s
		}
	}
	return ""
}
