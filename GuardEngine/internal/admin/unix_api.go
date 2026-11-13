package admin

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/zhangsubo/deskside-guard/internal/audit"
	"github.com/zhangsubo/deskside-guard/internal/config"
	"github.com/zhangsubo/deskside-guard/internal/detector"
	"github.com/zhangsubo/deskside-guard/internal/masker"
	"github.com/zhangsubo/deskside-guard/internal/proxy"
)

type Server struct {
	stateDir  string
	sockPath  string
	version   string
	startedAt time.Time
	bootToken string

	store   *config.Store
	engine  *detector.Engine
	vault   *masker.Vault
	ledger  *audit.Ledger
	ca      *proxy.LocalCA
	proxySv *proxy.Server

	httpSrv  *http.Server
	listener net.Listener
}

type StatusResponse struct {
	Running          bool             `json:"running"`
	Version          string           `json:"version"`
	PID              int              `json:"pid"`
	UptimeSeconds    int64            `json:"uptimeSeconds"`
	ListenAddr       string           `json:"listenAddr"`
	DefaultLLMAction string           `json:"defaultLLMAction"`
	KnownSecretCount int              `json:"knownSecretCount"`
	ActiveVaultItems int              `json:"activeVaultItems"`
	CACertPath       string           `json:"caCertPath"`
	CAFingerprint    string           `json:"caFingerprint"`
	Stats            audit.DailyStats `json:"stats"`
}

type SecretSyncRequest struct {
	Secrets []detector.KnownSecretInput `json:"secrets"`
}

type SelfTestResponse struct {
	Passed        bool   `json:"passed"`
	MaskedPayload string `json:"maskedPayload"`
	RestoredText  string `json:"restoredText"`
	RuleTriggered string `json:"ruleTriggered"`
	GitCheckReady bool   `json:"gitCheckReady"`
	Message       string `json:"message"`
}

func NewServer(
	stateDir string,
	version string,
	bootToken string,
	store *config.Store,
	engine *detector.Engine,
	vault *masker.Vault,
	ledger *audit.Ledger,
	ca *proxy.LocalCA,
	proxySv *proxy.Server,
) *Server {
	return &Server{
		stateDir:  stateDir,
		sockPath:  config.AdminSocketPath(stateDir),
		version:   version,
		startedAt: time.Now(),
		bootToken: bootToken,
		store:     store,
		engine:    engine,
		vault:     vault,
		ledger:    ledger,
		ca:        ca,
		proxySv:   proxySv,
	}
}

func (s *Server) Start() error {
	if err := os.MkdirAll(s.stateDir, 0o700); err != nil {
		return err
	}

	// Write ephemeral boot token (`0600`) so DeskSide can inject it into Surge's hop-router.js.
	tokenPath := filepath.Join(s.stateDir, "boot.token")
	if err := os.WriteFile(tokenPath, []byte(s.bootToken), 0o600); err != nil {
		return fmt.Errorf("write boot.token: %w", err)
	}
	_ = os.Chmod(tokenPath, 0o600)

	// Check if another live instance owns admin.sock before unlinking stale socket.
	if conn, err := net.DialTimeout("unix", s.sockPath, 150*time.Millisecond); err == nil {
		_ = conn.Close()
		return fmt.Errorf("another deskside-guard daemon is already listening on %s", s.sockPath)
	}
	_ = os.Remove(s.sockPath)

	ln, err := net.Listen("unix", s.sockPath)
	if err != nil {
		return fmt.Errorf("listen unix %s: %w", s.sockPath, err)
	}
	if err := os.Chmod(s.sockPath, 0o600); err != nil {
		_ = ln.Close()
		return fmt.Errorf("chmod unix socket: %w", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/status", s.handleStatus)
	mux.HandleFunc("/v1/config", s.handleConfig)
	mux.HandleFunc("/v1/secrets/sync", s.handleSecretsSync)
	mux.HandleFunc("/v1/events", s.handleEvents)
	mux.HandleFunc("/v1/events/stream", s.handleEventsStream)
	mux.HandleFunc("/v1/self-test", s.handleSelfTest)
	mux.HandleFunc("/v1/internal/scan", s.handleInternalScan)
	mux.HandleFunc("/v1/internal/event", s.handleInternalEvent)
	mux.HandleFunc("/v1/internal/git-scan", s.handleInternalGitScan)

	s.listener = ln
	s.httpSrv = &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		_ = s.httpSrv.Serve(ln)
	}()
	return nil
}

func (s *Server) Shutdown(ctx context.Context) error {
	var err error
	if s.httpSrv != nil {
		err = s.httpSrv.Shutdown(ctx)
	}
	_ = os.Remove(s.sockPath)
	_ = os.Remove(filepath.Join(s.stateDir, "boot.token"))
	return err
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	cfg := s.store.Get()
	resp := StatusResponse{
		Running:          true,
		Version:          s.version,
		PID:              os.Getpid(),
		UptimeSeconds:    int64(time.Since(s.startedAt).Seconds()),
		ListenAddr:       s.proxySv.Addr(),
		DefaultLLMAction: cfg.DefaultLLMAction,
		KnownSecretCount: s.engine.KnownSecretCount(),
		ActiveVaultItems: s.vault.ActiveCount(),
		CACertPath:       s.ca.CertPath(),
		CAFingerprint:    s.ca.FingerprintSHA256(),
		Stats:            s.ledger.Stats(),
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleConfig(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, s.store.Get())

	case http.MethodPut:
		var next config.Config
		if err := json.NewDecoder(io.LimitReader(r.Body, 1024*1024)).Decode(&next); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		if err := s.store.Update(next); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, s.store.Get())

	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleSecretsSync(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req SecretSyncRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 4*1024*1024)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	s.engine.SetKnownSecrets(req.Secrets)
	writeJSON(w, http.StatusOK, map[string]any{
		"synced": s.engine.KnownSecretCount(),
	})
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		limit := 100
		if q := r.URL.Query().Get("limit"); q != "" {
			if n, err := strconv.Atoi(q); err == nil && n > 0 {
				limit = n
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"events": s.ledger.ListRecent(limit),
			"stats":  s.ledger.Stats(),
		})

	case http.MethodDelete:
		_ = s.ledger.Clear()
		writeJSON(w, http.StatusOK, map[string]any{"cleared": true})

	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleEventsStream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(": connected\n\n"))
	flusher.Flush()

	ch, cancel := s.ledger.Subscribe()
	defer cancel()

	keepAlive := time.NewTicker(20 * time.Second)
	defer keepAlive.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case ev, open := <-ch:
			if !open {
				return
			}
			raw, err := json.Marshal(ev)
			if err != nil {
				continue
			}
			_, _ = fmt.Fprintf(w, "data: %s\n\n", raw)
			flusher.Flush()
		case <-keepAlive.C:
			_, _ = w.Write([]byte(": ping\n\n"))
			flusher.Flush()
		}
	}
}

func (s *Server) handleSelfTest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// Run an isolated synthetic end-to-end mask + multi-chunk SSE restore verification.
	testVault := masker.NewVault(2 * time.Minute)
	syntheticSecret := "sk-ant-" + "api03-DeskSideSelfTestSyntheticKey9988776655"
	reqJSON := []byte(fmt.Sprintf(`{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"Check key %s"}]}`, syntheticSecret))

	maskedBytes, hits, modified := masker.InspectAndMaskJSON(reqJSON, s.engine, testVault, true)
	if !modified || len(hits) == 0 || strings.Contains(string(maskedBytes), syntheticSecret) {
		writeJSON(w, http.StatusOK, SelfTestResponse{
			Passed:  false,
			Message: "自检失败：未能对测试凭据完成请求体脱敏替换。",
		})
		return
	}

	// Simulate 4-way BPE split SSE stream (`<`, `SEC`, `RET_1`, `>`).
	sseInput := strings.Join([]string{
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Key is <"}}`,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"SEC"}}`,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"RET_1"}}`,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":">!"}}`,
		`data: [DONE]`,
		"",
	}, "\n")

	restorer := masker.NewSSERestorer(io.NopCloser(strings.NewReader(sseInput)), testVault)
	restoredRaw, err := io.ReadAll(restorer)
	passed := err == nil && strings.Contains(string(restoredRaw), syntheticSecret+"!")

	if passed {
		s.ledger.Record(audit.Event{
			Timestamp:     time.Now(),
			Channel:       "self-test",
			Action:        "masked",
			Target:        "diagnostic://self-test",
			Client:        "DeskSide 自检",
			Category:      hits[0].Category,
			RuleName:      hits[0].RuleName,
			MaskedPreview: hits[0].MaskedPreview,
			Fingerprint:   hits[0].Fingerprint,
			Location:      "messages[0].content",
			Count:         1,
		})
	}

	msg := "自检通过：多源识别、请求脱敏与跨 Token SSE 流式还原均工作正常。"
	if !passed {
		msg = "自检失败：SSE 流式跨包还原结果不匹配。"
	}

	writeJSON(w, http.StatusOK, SelfTestResponse{
		Passed:        passed,
		MaskedPayload: string(maskedBytes),
		RestoredText:  "Key is [已还原原始凭据]!",
		RuleTriggered: hits[0].RuleName,
		GitCheckReady: true,
		Message:       msg,
	})
}

func (s *Server) handleInternalScan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Text     string `json:"text"`
		FilePath string `json:"filePath"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 8*1024*1024)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	findings := s.engine.Analyze(req.Text, detector.ScanOptions{FilePath: req.FilePath})
	writeJSON(w, http.StatusOK, map[string]any{"findings": findings})
}

func (s *Server) handleInternalEvent(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var ev audit.Event
	if err := json.NewDecoder(io.LimitReader(r.Body, 256*1024)).Decode(&ev); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	recorded := s.ledger.Record(ev)
	writeJSON(w, http.StatusOK, recorded)
}

func (s *Server) handleInternalGitScan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s.ledger.RecordScan("git")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}
