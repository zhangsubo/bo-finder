package proxy_test

import (
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/zhangsubo/deskside-guard/internal/admin"
	"github.com/zhangsubo/deskside-guard/internal/audit"
	"github.com/zhangsubo/deskside-guard/internal/config"
	"github.com/zhangsubo/deskside-guard/internal/detector"
	"github.com/zhangsubo/deskside-guard/internal/masker"
	"github.com/zhangsubo/deskside-guard/internal/proxy"
)

func TestDualEgressProxySurgeHopMITMAndZeroPlaintextDisk(t *testing.T) {
	stateDir := t.TempDir()
	envSecret := "SuperSensitiveDeskSideEnvToken#889900"
	bootToken := "boot_ephemeral_token_test_1234567890abcdef"

	var upstreamSawHop atomic.Bool
	var upstreamSawMasked atomic.Bool

	// Mock TLS upstream acting as both LLM SSE server and GitHub API server.
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get(proxy.GuardHopHeader) == bootToken {
			upstreamSawHop.Store(true)
		}
		body, _ := io.ReadAll(r.Body)
		bodyStr := string(body)

		if strings.Contains(bodyStr, envSecret) {
			t.Errorf("SECURITY FAILURE: upstream received raw secret: %s", bodyStr)
		}
		if strings.Contains(bodyStr, "<SECRET_1>") {
			upstreamSawMasked.Store(true)
		}

		// Return gzip-compressed SSE stream splitting <SECRET_1> across 3 chunks!
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Content-Encoding", "gzip")
		gz := gzip.NewWriter(w)
		chunks := []string{
			`data: {"choices":[{"index":0,"delta":{"content":"Echo: <"}}]}`,
			`data: {"choices":[{"index":0,"delta":{"content":"SECRET_"}}]}`,
			`data: {"choices":[{"index":0,"delta":{"content":"1> done"}}]}`,
			`data: [DONE]`,
		}
		for _, ch := range chunks {
			_, _ = fmt.Fprintf(gz, "%s\n\n", ch)
			_ = gz.Flush()
		}
		_ = gz.Close()
	}))
	defer upstream.Close()

	upstreamURL, _ := url.Parse(upstream.URL)

	var (
		engine  *detector.Engine
		proxySv *proxy.Server
	)
	store, err := config.NewStore(stateDir, func(c config.Config) {
		if engine != nil {
			engine.UpdateConfig(c)
		}
		if proxySv != nil {
			proxySv.ReloadConfig(c)
		}
	})
	if err != nil {
		t.Fatal(err)
	}

	cfg := store.Get()
	cfg.ListenAddr = "127.0.0.1:0"
	cfg.ProtectedDomains = append(cfg.ProtectedDomains, "127.0.0.1", "localhost", "api.github.com", "github.com")
	if err := store.Update(cfg); err != nil {
		t.Fatal(err)
	}

	engine = detector.NewEngine(store.Get())
	vault := masker.NewVault(10 * time.Minute)
	ledger, err := audit.NewLedger(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := proxy.LoadOrCreateCA(stateDir)
	if err != nil {
		t.Fatal(err)
	}

	proxySv = proxy.NewServer(store, engine, vault, ledger, ca, bootToken)
	proxySv.ExtraTransportTLSConfig = &tls.Config{InsecureSkipVerify: true}
	proxySv.ReloadConfig(store.Get())

	adminSv := admin.NewServer(stateDir, "1.0.0-test", bootToken, store, engine, vault, ledger, ca, proxySv)
	if err := adminSv.Start(); err != nil {
		t.Fatal(err)
	}
	defer adminSv.Shutdown(context.Background())

	if err := proxySv.Start(); err != nil {
		t.Fatal(err)
	}
	defer proxySv.Shutdown(context.Background())

	// Sync DeskSide EnvManager secret over 0600 Unix socket!
	sockPath := config.AdminSocketPath(stateDir)
	unixClient := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", sockPath)
			},
		},
	}

	syncBody, _ := json.Marshal(admin.SecretSyncRequest{
		Secrets: []detector.KnownSecretInput{{Name: "DESKSIDE_TOKEN", Value: envSecret}},
	})
	syncResp, err := unixClient.Post("http://unix/v1/secrets/sync", "application/json", bytes.NewReader(syncBody))
	if err != nil || syncResp.StatusCode != http.StatusOK {
		t.Fatalf("sync secrets via unix socket failed: %v", err)
	}
	_ = syncResp.Body.Close()

	// 1. Test Tier 1/2 Surge `/_guard/https/<host>/...` hop + spoofed X-Guard-Hop header + gzipped SSE restore!
	hopEndpoint := fmt.Sprintf("http://%s/_guard/https/%s/v1/chat/completions", proxySv.Addr(), upstreamURL.Host)
	llmPayload := fmt.Sprintf(`{"model":"gpt-5","messages":[{"role":"user","content":"My token is %s"}]}`, envSecret)
	req, _ := http.NewRequest(http.MethodPost, hopEndpoint, strings.NewReader(llmPayload))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "claude-cli/1.0")
	req.Header.Set(proxy.GuardHopHeader, "spoofed_token_attempt")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("guard hop request failed: %v", err)
	}
	respBytes, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()

	if !upstreamSawHop.Load() {
		t.Fatalf("expected upstream to receive authentic bootToken in X-Guard-Hop")
	}
	if !upstreamSawMasked.Load() {
		t.Fatalf("expected upstream to receive <SECRET_1> masked body")
	}
	assembled := concatOpenAISSEContent(string(respBytes))
	if assembled != "Echo: "+envSecret+" done" {
		t.Fatalf("expected assembled SSE stream %q, got %q (raw:\n%s)", "Echo: "+envSecret+" done", assembled, string(respBytes))
	}

	// 2. Test Tier 3 CONNECT Selective MITM with LocalCA trust pool!
	caPool := x509.NewCertPool()
	caPool.AppendCertsFromPEM(ca.CertPEM())
	proxyURL, _ := url.Parse("http://" + proxySv.Addr())
	mitmClient := &http.Client{
		Transport: &http.Transport{
			Proxy:           http.ProxyURL(proxyURL),
			TLSClientConfig: &tls.Config{RootCAs: caPool},
		},
	}

	mitmResp, err := mitmClient.Post(upstream.URL+"/v1/messages", "application/json", strings.NewReader(llmPayload))
	if err != nil {
		t.Fatalf("Tier 3 CONNECT MITM request failed: %v", err)
	}
	mitmBody, _ := io.ReadAll(mitmResp.Body)
	_ = mitmResp.Body.Close()
	if !strings.Contains(string(mitmBody), envSecret) {
		t.Fatalf("Tier 3 CONNECT MITM failed to restore secret: %s", string(mitmBody))
	}

	// 3. Test GitHub Contents API Base64 strict block (`403 Forbidden`)!
	b64Content := base64.StdEncoding.EncodeToString([]byte("OPENAI_API_KEY=" + envSecret + "\n"))
	ghJSON := fmt.Sprintf(`{"message":"add env","content":%q}`, b64Content)
	ghURL := fmt.Sprintf("http://%s/_guard/https/api.github.com/repos/user/demo/contents/.env", proxySv.Addr())
	ghResp, err := http.Post(ghURL, "application/json", strings.NewReader(ghJSON))
	if err != nil {
		t.Fatalf("github contents request failed: %v", err)
	}
	_ = ghResp.Body.Close()
	if ghResp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected GitHub Contents API leak to be blocked with 403, got %d", ghResp.StatusCode)
	}

	// 4. Test GitHub `git-receive-pack` zlib PACK inspection (`git push --no-verify` over HTTPS fallback)!
	packPayload := buildMinimalGitPackBlob([]byte("secret=" + envSecret))
	packURL := fmt.Sprintf("http://%s/_guard/https/github.com/user/demo.git/git-receive-pack", proxySv.Addr())
	packResp, err := http.Post(packURL, "application/x-git-receive-pack-request", bytes.NewReader(packPayload))
	if err != nil {
		t.Fatalf("git-receive-pack request failed: %v", err)
	}
	_ = packResp.Body.Close()
	if packResp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected git-receive-pack with secret blob to be blocked with 403, got %d", packResp.StatusCode)
	}

	// 5. Run Unix socket self-test endpoint!
	stResp, err := unixClient.Post("http://unix/v1/self-test", "application/json", strings.NewReader(`{}`))
	if err != nil || stResp.StatusCode != http.StatusOK {
		t.Fatalf("self-test failed: %v", err)
	}
	var st admin.SelfTestResponse
	_ = json.NewDecoder(stResp.Body).Decode(&st)
	_ = stResp.Body.Close()
	if !st.Passed {
		t.Fatalf("expected self-test to pass, got %+v", st)
	}

	// 6. Strict Zero-Plaintext Disk Audit: verify raw secret NEVER appears in any file under stateDir!
	err = filepath.Walk(stateDir, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil || info.IsDir() || (info.Mode()&os.ModeSocket) != 0 {
			return nil
		}
		data, rErr := os.ReadFile(path)
		if rErr != nil {
			return nil
		}
		if bytes.Contains(data, []byte(envSecret)) {
			t.Fatalf("ZERO-PLAINTEXT VIOLATION: raw secret persisted in %s", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func concatOpenAISSEContent(rawSSE string) string {
	var sb strings.Builder
	for _, line := range strings.Split(rawSSE, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "" || payload == "[DONE]" {
			continue
		}
		var frame struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(payload), &frame); err == nil && len(frame.Choices) > 0 {
			sb.WriteString(frame.Choices[0].Delta.Content)
		}
	}
	return sb.String()
}

func buildMinimalGitPackBlob(blob []byte) []byte {
	var buf bytes.Buffer
	buf.WriteString("0000PACK")
	var hdr [8]byte
	binary.BigEndian.PutUint32(hdr[0:4], 2) // version 2
	binary.BigEndian.PutUint32(hdr[4:8], 1) // 1 object
	buf.Write(hdr[:])

	// Object type 3 (OBJ_BLOB), size <= 15 fits in single header byte: (3 << 4) | (size & 0x0f)
	size := len(blob)
	first := byte((3 << 4) | (size & 0x0f))
	rem := size >> 4
	if rem > 0 {
		first |= 0x80
	}
	buf.WriteByte(first)
	for rem > 0 {
		b := byte(rem & 0x7f)
		rem >>= 7
		if rem > 0 {
			b |= 0x80
		}
		buf.WriteByte(b)
	}

	zw := zlib.NewWriter(&buf)
	_, _ = zw.Write(blob)
	_ = zw.Close()
	return buf.Bytes()
}
