package proxy

import (
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/zhangsubo/deskside-guard/internal/audit"
	"github.com/zhangsubo/deskside-guard/internal/config"
	"github.com/zhangsubo/deskside-guard/internal/detector"
	"github.com/zhangsubo/deskside-guard/internal/masker"
)

const (
	GuardHopHeader = "X-Guard-Hop"
	maxBodyBytes   = 12 * 1024 * 1024 // 12 MB inspection ceiling
)

type chanListener struct {
	ch     chan net.Conn
	closed chan struct{}
	once   sync.Once
}

func newChanListener() *chanListener {
	return &chanListener{
		ch:     make(chan net.Conn, 128),
		closed: make(chan struct{}),
	}
}

func (l *chanListener) Accept() (net.Conn, error) {
	select {
	case c, ok := <-l.ch:
		if !ok {
			return nil, net.ErrClosed
		}
		return c, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *chanListener) Close() error {
	l.once.Do(func() {
		close(l.closed)
	})
	return nil
}

func (l *chanListener) Addr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0}
}

func (l *chanListener) Enqueue(c net.Conn) bool {
	select {
	case <-l.closed:
		return false
	default:
	}
	select {
	case l.ch <- c:
		return true
	case <-l.closed:
		return false
	}
}

type Server struct {
	store     *config.Store
	engine    *detector.Engine
	vault     *masker.Vault
	ledger    *audit.Ledger
	ca        *LocalCA
	bootToken string

	mu              sync.RWMutex
	transport       *http.Transport
	surgeHopTrans   *http.Transport
	cachedSysProxy  string
	sysProxyCheckAt time.Time
	domains         map[string]struct{}
	listenAddr      string

	httpSrv  *http.Server
	mitmLn   *chanListener
	mitmSrv  *http.Server
	listener net.Listener

	// ExtraTransportTLSConfig is an optional test hook for self-signed upstream test servers.
	ExtraTransportTLSConfig *tls.Config
}

func NewServer(
	store *config.Store,
	engine *detector.Engine,
	vault *masker.Vault,
	ledger *audit.Ledger,
	ca *LocalCA,
	bootToken string,
) *Server {
	s := &Server{
		store:     store,
		engine:    engine,
		vault:     vault,
		ledger:    ledger,
		ca:        ca,
		bootToken: bootToken,
		mitmLn:    newChanListener(),
	}
	s.ReloadConfig(store.Get())
	s.mitmSrv = &http.Server{
		Handler:           http.HandlerFunc(s.handleMITMRequest),
		ReadHeaderTimeout: 30 * time.Second,
	}
	return s
}

func (s *Server) ReloadConfig(cfg config.Config) {
	domMap := make(map[string]struct{}, len(cfg.ProtectedDomains))
	for _, d := range cfg.ProtectedDomains {
		norm := normalizeHost(d)
		if norm != "" {
			domMap[norm] = struct{}{}
		}
	}

	tr := &http.Transport{
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          128,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   15 * time.Second,
		ExpectContinueTimeout: 2 * time.Second,
		DisableCompression:    true, // We control Accept-Encoding & gzip explicitly.
	}
	if s.ExtraTransportTLSConfig != nil {
		tr.TLSClientConfig = s.ExtraTransportTLSConfig.Clone()
	}
	if strings.TrimSpace(cfg.UpstreamProxyURL) != "" {
		if pu, err := url.Parse(strings.TrimSpace(cfg.UpstreamProxyURL)); err == nil {
			tr.Proxy = http.ProxyURL(pu)
		}
	} else {
		tr.Proxy = nil
	}

	s.mu.Lock()
	s.domains = domMap
	s.transport = tr
	s.listenAddr = cfg.ListenAddr
	s.mu.Unlock()
}

func (s *Server) Start() error {
	cfg := s.store.Get()
	ln, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.listener = ln
	s.listenAddr = ln.Addr().String()
	s.httpSrv = &http.Server{
		Handler:           s,
		ReadHeaderTimeout: 30 * time.Second,
	}
	s.mu.Unlock()

	go func() {
		_ = s.mitmSrv.Serve(s.mitmLn)
	}()
	go func() {
		_ = s.httpSrv.Serve(ln)
	}()
	return nil
}

func (s *Server) Addr() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.listenAddr
}

func (s *Server) Shutdown(ctx context.Context) error {
	_ = s.mitmLn.Close()
	_ = s.mitmSrv.Shutdown(ctx)
	s.mu.RLock()
	srv := s.httpSrv
	s.mu.RUnlock()
	if srv != nil {
		return srv.Shutdown(ctx)
	}
	return nil
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		s.handleConnect(w, r)
		return
	}

	// Plain HTTP forward-proxy request (`GET http://example.com/foo HTTP/1.1`)
	if r.URL.IsAbs() && (r.URL.Scheme == "http" || r.URL.Scheme == "https") {
		targetURL := *r.URL
		s.inspectAndForward(w, r, &targetURL, false)
		return
	}

	// Local utility endpoints & Tier 1/2 `/_guard/` reverse-proxy ingress.
	switch {
	case r.URL.Path == "/healthz":
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
		return

	case r.URL.Path == "/proxy.pac":
		s.servePAC(w)
		return

	case r.URL.Path == "/ca.pem":
		w.Header().Set("Content-Type", "application/x-x509-ca-cert")
		_, _ = w.Write(s.ca.CertPEM())
		return

	case r.URL.Path == "/surge/deskside-guard.sgmodule" || r.URL.Path == "/deskside-guard.sgmodule":
		s.serveSurgeModule(w)
		return

	case r.URL.Path == "/surge/hop-router.js":
		s.serveSurgeHopRouter(w)
		return

	case strings.HasPrefix(r.URL.Path, "/_guard/"):
		targetURL, ok := parseGuardHopURL(r.URL)
		if !ok {
			http.Error(w, "invalid _guard target URL", http.StatusBadRequest)
			return
		}
		// Requests entering via /_guard/ came from Surge or mitmproxy; attach X-Guard-Hop on upstream egress
		// so Surge's hop-router.js recognizes the return hop and prevents infinite loops.
		s.inspectAndForward(w, r, targetURL, true)
		return

	default:
		http.Error(w, "DeskSide Security Gateway running", http.StatusOK)
	}
}

func parseGuardHopURL(u *url.URL) (*url.URL, bool) {
	// Format: /_guard/{https|http}/{host}/{optional-path...}
	rest := strings.TrimPrefix(u.EscapedPath(), "/_guard/")
	if rest == u.EscapedPath() {
		rest = strings.TrimPrefix(u.Path, "/_guard/")
	}
	scheme, afterScheme, ok := strings.Cut(rest, "/")
	if !ok || (scheme != "https" && scheme != "http") {
		return nil, false
	}
	host, rawPath, hasSlash := strings.Cut(afterScheme, "/")
	if host == "" {
		return nil, false
	}
	escapedPath := "/"
	if hasSlash {
		escapedPath = "/" + rawPath
	}
	parsed, err := url.Parse(scheme + "://" + host + escapedPath)
	if err != nil {
		return nil, false
	}
	parsed.RawQuery = u.RawQuery
	return parsed, true
}

func (s *Server) handleConnect(w http.ResponseWriter, r *http.Request) {
	hostPort := r.Host
	if hostPort == "" {
		hostPort = r.URL.Host
	}
	if !strings.Contains(hostPort, ":") {
		hostPort += ":443"
	}
	host := normalizeHost(hostPort)

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijacking unsupported", http.StatusInternalServerError)
		return
	}
	clientConn, clientBuf, err := hijacker.Hijack()
	if err != nil {
		return
	}

	// Non-protected domains use raw TCP pass-through (zero TLS MITM, zero cert replacement).
	if !s.isProtectedHost(host) {
		upConn, dErr := s.dialRawUpstream(hostPort)
		if dErr != nil {
			_, _ = clientConn.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
			_ = clientConn.Close()
			return
		}
		_, _ = clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
		if buffered := clientBuf.Reader.Buffered(); buffered > 0 {
			peeked, _ := clientBuf.Peek(buffered)
			_, _ = upConn.Write(peeked)
		}
		go tunnelBidirectional(clientConn, upConn)
		return
	}

	// Protected domain (Tier 3): perform local selective TLS MITM with dynamic leaf cert.
	if _, err := clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
		_ = clientConn.Close()
		return
	}

	wrappedConn := net.Conn(clientConn)
	if buffered := clientBuf.Reader.Buffered(); buffered > 0 {
		peeked, _ := clientBuf.Peek(buffered)
		wrappedConn = &prefixedConn{Conn: clientConn, prefix: bytes.NewReader(peeked)}
	}

	tlsCfg := &tls.Config{
		MinVersion: tls.VersionTLS12,
		NextProtos: []string{"h2", "http/1.1"},
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			sni := ""
			if hello != nil {
				sni = hello.ServerName
			}
			if sni == "" {
				sni = host
			}
			return s.ca.CertForHost(sni)
		},
	}

	tlsConn := tls.Server(wrappedConn, tlsCfg)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	err = tlsConn.HandshakeContext(ctx)
	cancel()
	if err != nil {
		_ = tlsConn.Close()
		return
	}

	if !s.mitmLn.Enqueue(tlsConn) {
		_ = tlsConn.Close()
	}
}

func (s *Server) handleMITMRequest(w http.ResponseWriter, r *http.Request) {
	host := r.Host
	if host == "" && r.TLS != nil {
		host = r.TLS.ServerName
	}
	if host == "" {
		http.Error(w, "missing host", http.StatusBadRequest)
		return
	}
	targetURL := &url.URL{
		Scheme:   "https",
		Host:     host,
		Path:     r.URL.Path,
		RawPath:  r.URL.RawPath,
		RawQuery: r.URL.RawQuery,
	}
	s.inspectAndForward(w, r, targetURL, false)
}

func (s *Server) inspectAndForward(w http.ResponseWriter, r *http.Request, targetURL *url.URL, attachGuardHop bool) {
	host := normalizeHost(targetURL.Host)
	clientName := detectClientLabel(r.Header.Get("User-Agent"))
	isWriteMethod := r.Method == http.MethodPost || r.Method == http.MethodPut || r.Method == http.MethodPatch

	var outBody io.Reader = r.Body
	var contentLength int64 = r.ContentLength
	dropReqContentEncoding := false

	if isWriteMethod && r.Body != nil && s.isProtectedHost(host) {
		rawBytes, truncated, readErr := readUpTo(r.Body, maxBodyBytes)
		if readErr != nil {
			http.Error(w, "failed to read request body", http.StatusBadRequest)
			return
		}

		if truncated {
			// Exceeded max inspection cap: stream remaining bytes verbatim without OOMing.
			outBody = io.MultiReader(bytes.NewReader(rawBytes), r.Body)
		} else {
			_ = r.Body.Close()
			inspectBytes := rawBytes
			wasGzip := strings.EqualFold(strings.TrimSpace(r.Header.Get("Content-Encoding")), "gzip")
			if wasGzip && len(rawBytes) > 0 {
				if gunzipped, gErr := decompressGzip(rawBytes, maxBodyBytes); gErr == nil {
					inspectBytes = gunzipped
				}
			}

			if isGitHubHost(host) {
				s.ledger.RecordScan("github")
				ghHits := s.inspectGitHubPayload(targetURL.Path, r.Header.Get("Content-Type"), inspectBytes)
				if len(ghHits) > 0 {
					s.recordHits("github", "blocked", host, clientName, ghHits)
					writeGitHubBlockResponse(w, ghHits)
					return
				}
				outBody = bytes.NewReader(rawBytes)
				contentLength = int64(len(rawBytes))
			} else {
				s.ledger.RecordScan("llm")
				cfg := s.store.Get()
				maskMode := cfg.DefaultLLMAction == config.ActionMask
				rewritten, llmHits, modified := masker.InspectAndMaskJSON(inspectBytes, s.engine, s.vault, maskMode)
				if len(llmHits) > 0 {
					if !maskMode {
						s.recordHits("llm", "blocked", host, clientName, llmHits)
						writeLLMBlockResponse(w, llmHits)
						return
					}
					s.recordHits("llm", "masked", host, clientName, llmHits)
				}
				if modified {
					outBody = bytes.NewReader(rewritten)
					contentLength = int64(len(rewritten))
					if wasGzip {
						dropReqContentEncoding = true
					}
				} else {
					outBody = bytes.NewReader(rawBytes)
					contentLength = int64(len(rawBytes))
				}
			}
		}
	}

	outReq, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL.String(), outBody)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	copyHeaders(outReq.Header, r.Header)
	stripHopByHopHeaders(outReq.Header)
	// Strip any client-supplied X-Guard-Hop; attach our ephemeral bootToken ONLY for /_guard/ ingress.
	outReq.Header.Del(GuardHopHeader)
	if attachGuardHop && s.bootToken != "" {
		outReq.Header.Set(GuardHopHeader, s.bootToken)
	}
	if dropReqContentEncoding {
		outReq.Header.Del("Content-Encoding")
	}
	outReq.Host = targetURL.Host
	outReq.ContentLength = contentLength

	isLLMProtected := s.isProtectedHost(host) && !isGitHubHost(host)
	if isLLMProtected {
		// Normalize Accept-Encoding to gzip so responses never arrive as brotli/zstd when token restoration is needed.
		outReq.Header.Set("Accept-Encoding", "gzip")
	}

	s.mu.RLock()
	tr := s.transport
	s.mu.RUnlock()
	if attachGuardHop && strings.TrimSpace(s.store.Get().UpstreamProxyURL) == "" {
		if hopTr := s.transportForSurgeReturnHop(); hopTr != nil {
			tr = hopTr
		}
	}

	resp, err := tr.RoundTrip(outReq)
	if err != nil {
		http.Error(w, fmt.Sprintf("[DeskSide Security Gateway] upstream error: %v", err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	respStream := io.ReadCloser(resp.Body)
	respEncoding := strings.ToLower(strings.TrimSpace(resp.Header.Get("Content-Encoding")))
	needRestore := isLLMProtected && s.vault.ActiveCount() > 0
	contentType := strings.ToLower(resp.Header.Get("Content-Type"))
	isSSE := strings.Contains(contentType, "text/event-stream")
	isJSON := strings.Contains(contentType, "application/json")

	if needRestore && (isSSE || isJSON) && respEncoding == "gzip" {
		if gzReader, gzErr := gzip.NewReader(resp.Body); gzErr == nil {
			respStream = gzReader
			defer gzReader.Close()
			resp.Header.Del("Content-Encoding")
			resp.Header.Del("Content-Length")
		}
	}

	copyHeaders(w.Header(), resp.Header)
	stripHopByHopHeaders(w.Header())

	if needRestore && isSSE {
		w.Header().Del("Content-Length")
		w.Header().Set("X-Accel-Buffering", "no")
		w.WriteHeader(resp.StatusCode)
		restorer := masker.NewSSERestorer(respStream, s.vault)
		streamFlush(w, restorer)
		return
	}

	if needRestore && isJSON {
		rawResp, truncated, rErr := readUpTo(respStream, maxBodyBytes)
		if rErr == nil && !truncated {
			restored := masker.RestoreJSONBody(rawResp, s.vault)
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(restored)))
			w.WriteHeader(resp.StatusCode)
			_, _ = w.Write(restored)
			return
		}
		w.Header().Del("Content-Length")
		w.WriteHeader(resp.StatusCode)
		_, _ = w.Write(rawResp)
		_, _ = io.Copy(w, respStream)
		return
	}

	w.WriteHeader(resp.StatusCode)
	if isSSE {
		streamFlush(w, respStream)
	} else {
		_, _ = io.Copy(w, respStream)
	}
}

func streamFlush(w http.ResponseWriter, src io.Reader) {
	flusher, canFlush := w.(http.Flusher)
	buf := make([]byte, 4096)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if _, wErr := w.Write(buf[:n]); wErr != nil {
				return
			}
			if canFlush {
				flusher.Flush()
			}
		}
		if err != nil {
			return
		}
	}
}

func (s *Server) inspectGitHubPayload(urlPath, contentType string, payload []byte) []masker.HitSummary {
	if len(payload) == 0 {
		return nil
	}
	var hits []masker.HitSummary

	addFindings := func(findings []detector.Finding, loc string) {
		for _, f := range findings {
			hits = append(hits, masker.HitSummary{
				Category:      f.Category,
				RuleName:      f.RuleName,
				MaskedPreview: f.MaskedPreview,
				Fingerprint:   f.Fingerprint,
				Location:      loc,
			})
		}
	}

	// 1. Git smart HTTP push (`/.../git-receive-pack`) — inspect raw & zlib-inflated packfile objects!
	if strings.HasSuffix(urlPath, "/git-receive-pack") || strings.Contains(contentType, "git-receive-pack") {
		addFindings(s.scanGitReceivePack(payload), "git-receive-pack")
		return hits
	}

	// 2. JSON API payloads (Contents API base64 `content`, Gists, Issues/PR comments, Actions secrets).
	var root any
	if err := json.Unmarshal(payload, &root); err == nil {
		var walkGH func(node any, path string)
		walkGH = func(node any, path string) {
			switch typed := node.(type) {
			case map[string]any:
				fileHint, _ := typed["path"].(string)
				for k, v := range typed {
					if k == "sha" || k == "node_id" || k == "tree" || k == "parents" {
						continue
					}
					nextPath := k
					if path != "" {
						nextPath = path + "." + k
					}
					if k == "content" {
						if strVal, ok := v.(string); ok {
							// GitHub Contents API & Blobs API send base64-encoded file contents under `content`.
							if decoded, okB64 := decodeLooseBase64(strVal); okB64 {
								addFindings(s.engine.Analyze(decoded, detector.ScanOptions{FilePath: fileHint}), nextPath+"(base64)")
								continue
							}
						}
					}
					walkGH(v, nextPath)
				}
			case []any:
				for i, elem := range typed {
					walkGH(elem, fmt.Sprintf("%s[%d]", path, i))
				}
			case string:
				addFindings(s.engine.Analyze(typed, detector.ScanOptions{}), path)
			}
		}
		walkGH(root, "")
		return hits
	}

	// 3. Fallback raw text scan.
	addFindings(s.engine.Analyze(string(payload), detector.ScanOptions{}), "body")
	return hits
}

func (s *Server) scanGitReceivePack(payload []byte) []detector.Finding {
	var all []detector.Finding
	packIdx := bytes.Index(payload, []byte("PACK"))
	if packIdx < 0 || packIdx+12 > len(payload) {
		return s.engine.Analyze(string(payload), detector.ScanOptions{})
	}

	pack := payload[packIdx:]
	version := binary.BigEndian.Uint32(pack[4:8])
	numObjects := binary.BigEndian.Uint32(pack[8:12])
	if version != 2 && version != 3 {
		return nil
	}
	if numObjects > 2000 {
		numObjects = 2000
	}

	offset := 12
	for objIdx := uint32(0); objIdx < numObjects && offset < len(pack); objIdx++ {
		c := pack[offset]
		offset++
		objType := (c >> 4) & 0x07
		for (c&0x80) != 0 && offset < len(pack) {
			c = pack[offset]
			offset++
		}
		// Skip delta base headers for OBJ_OFS_DELTA (6) and OBJ_REF_DELTA (7).
		if objType == 6 {
			if offset >= len(pack) {
				break
			}
			b := pack[offset]
			offset++
			for (b&0x80) != 0 && offset < len(pack) {
				b = pack[offset]
				offset++
			}
		} else if objType == 7 {
			offset += 20
		}
		if offset >= len(pack) {
			break
		}

		br := bytes.NewReader(pack[offset:])
		zr, err := zlib.NewReader(br)
		if err != nil {
			break
		}
		inflated, _ := io.ReadAll(io.LimitReader(zr, 512*1024))
		_ = zr.Close()
		consumed := int(br.Size()) - br.Len()
		if consumed <= 0 {
			break
		}
		offset += consumed

		// Inspect Commit (1), Blob (3), and Tag (4) objects.
		if (objType == 1 || objType == 3 || objType == 4) && len(inflated) > 0 {
			findings := s.engine.Analyze(string(inflated), detector.ScanOptions{})
			all = append(all, findings...)
			if len(all) >= 20 {
				break
			}
		}
	}
	return all
}

func (s *Server) recordHits(channel, action, target, client string, hits []masker.HitSummary) {
	type groupKey struct {
		fp   string
		rule string
	}
	grouped := make(map[groupKey]*audit.Event)
	var order []groupKey
	for _, h := range hits {
		k := groupKey{fp: h.Fingerprint, rule: h.RuleName}
		if existing, ok := grouped[k]; ok {
			existing.Count++
			continue
		}
		order = append(order, k)
		grouped[k] = &audit.Event{
			Timestamp:     time.Now(),
			Channel:       channel,
			Action:        action,
			Target:        target,
			Client:        client,
			Category:      h.Category,
			RuleName:      h.RuleName,
			MaskedPreview: h.MaskedPreview,
			Fingerprint:   h.Fingerprint,
			Location:      h.Location,
			Count:         1,
		}
	}
	for _, k := range order {
		s.ledger.Record(*grouped[k])
	}
}

func writeLLMBlockResponse(w http.ResponseWriter, hits []masker.HitSummary) {
	first := hits[0]
	msg := fmt.Sprintf("[DeskSide 安全网关] 已拦截敏感凭据外发：%s (%s)，共 %d 处命中。可在 DeskSide 安全网关面板切换为“无感脱敏并还原”或加入白名单。", first.RuleName, first.MaskedPreview, len(hits))
	resp := map[string]any{
		"type": "error",
		"error": map[string]any{
			"type":    "deskside_security_block",
			"code":    "secret_detected",
			"message": msg,
		},
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusForbidden)
	_ = json.NewEncoder(w).Encode(resp)
}

func writeGitHubBlockResponse(w http.ResponseWriter, hits []masker.HitSummary) {
	first := hits[0]
	msg := fmt.Sprintf("[DeskSide Security Gateway] Blocked secret upload to GitHub: %s (%s) at %s (%d hit(s)). Remove hardcoded credentials before pushing.", first.RuleName, first.MaskedPreview, first.Location, len(hits))
	resp := map[string]any{
		"message":           msg,
		"documentation_url": "https://github.com/zhangsubo/DeskSide",
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusForbidden)
	_ = json.NewEncoder(w).Encode(resp)
}

func (s *Server) servePAC(w http.ResponseWriter) {
	s.mu.RLock()
	addr := s.listenAddr
	var doms []string
	for d := range s.domains {
		doms = append(doms, d)
	}
	s.mu.RUnlock()

	var conds []string
	for _, d := range doms {
		conds = append(conds, fmt.Sprintf(`host === %q || dnsDomainIs(host, %q)`, d, "."+d))
	}
	expr := "false"
	if len(conds) > 0 {
		expr = strings.Join(conds, " ||\n      ")
	}

	pac := fmt.Sprintf(`function FindProxyForURL(url, host) {
  host = host.toLowerCase();
  if (%s) {
    return "PROXY %s; DIRECT";
  }
  return "DIRECT";
}
`, expr, addr)

	w.Header().Set("Content-Type", "application/x-ns-proxy-autoconfig")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(pac))
}

func (s *Server) serveSurgeModule(w http.ResponseWriter) {
	cfg := s.store.Get()
	addr := s.Addr()
	if addr == "" {
		addr = cfg.ListenAddr
	}
	routerURL := fmt.Sprintf("http://%s/surge/hop-router.js", addr)
	escaped := make([]string, 0, len(cfg.ProtectedDomains))
	cleaned := make([]string, 0, len(cfg.ProtectedDomains))
	for _, d := range cfg.ProtectedDomains {
		d = strings.ToLower(strings.TrimSpace(d))
		if d == "" {
			continue
		}
		cleaned = append(cleaned, d)
		escaped = append(escaped, regexp.QuoteMeta(d))
	}
	pattern := `^https:\/\/(?:[a-z0-9-]+\.)?(?:` + strings.Join(escaped, "|") + `)(?:\/|$)`
	body := fmt.Sprintf(`#!name=DeskSide 安全网关 (LLM & GitHub 密钥防泄漏)
#!desc=由 DeskSide 自动维护：对大模型请求执行密钥脱敏与流式还原，对 GitHub 上传执行密钥硬阻断。网关停止时自动回退为直通。
#!category=Security

[Rule]
IP-CIDR,127.0.0.1/32,DIRECT,no-resolve

[Script]
deskside-guard-hop = type=http-request,pattern=%s,requires-body=0,timeout=5,script-path=%s

[MITM]
hostname = %%APPEND%% %s
`, pattern, routerURL, strings.Join(cleaned, ", "))

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(body))
}

func (s *Server) serveSurgeHopRouter(w http.ResponseWriter) {
	cfg := s.store.Get()
	addr := s.Addr()
	if addr == "" {
		addr = cfg.ListenAddr
	}
	var quotedDoms []string
	for _, d := range cfg.ProtectedDomains {
		d = strings.ToLower(strings.TrimSpace(d))
		if d != "" {
			quotedDoms = append(quotedDoms, fmt.Sprintf("%q", d))
		}
	}
	js := fmt.Sprintf(`// DeskSide Security Gateway - Fail-Open Atomic Hop Router
(function () {
  var BOOT_TOKEN = %q;
  var GUARD_ADDR = "http://%s";
  var DOMAINS = [%s];

  var headers = $request.headers || {};
  var hop = headers["X-Guard-Hop"] || headers["x-guard-hop"] || "";
  if (hop === BOOT_TOKEN) {
    delete headers["X-Guard-Hop"];
    delete headers["x-guard-hop"];
    $done({ headers: headers });
    return;
  }

  var rawURL = $request.url || "";
  var m = rawURL.match(/^(https?):\/\/([^\/?#]+)(\/[\s\S]*)?$/i);
  if (!m) {
    $done({});
    return;
  }
  var scheme = m[1].toLowerCase();
  var hostPort = m[2];
  var hostOnly = hostPort.split(":")[0].toLowerCase();
  var pathAndQuery = m[3] || "/";

  var matched = false;
  for (var i = 0; i < DOMAINS.length; i++) {
    var d = DOMAINS[i];
    if (hostOnly === d || hostOnly.slice(-(d.length + 1)) === "." + d) {
      matched = true;
      break;
    }
  }
  if (!matched) {
    $done({});
    return;
  }

  $httpClient.get({ url: GUARD_ADDR + "/healthz", timeout: 1 }, function (err, resp) {
    if (err || !resp || resp.status !== 200) {
      $done({});
      return;
    }
    delete headers["X-Guard-Hop"];
    delete headers["x-guard-hop"];
    var nextURL = GUARD_ADDR + "/_guard/" + scheme + "/" + hostPort + pathAndQuery;
    $done({ url: nextURL, headers: headers });
  });
})();
`, s.bootToken, addr, strings.Join(quotedDoms, ", "))

	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(js))
}

func (s *Server) transportForSurgeReturnHop() *http.Transport {
	if runtime.GOOS != "darwin" {
		return nil
	}
	now := time.Now()
	s.mu.RLock()
	cachedURL := s.cachedSysProxy
	checkedAt := s.sysProxyCheckAt
	existingTr := s.surgeHopTrans
	selfAddr := s.listenAddr
	s.mu.RUnlock()

	if now.Sub(checkedAt) < 15*time.Second {
		return existingTr
	}

	detected := detectMacOSSystemHTTPProxy(selfAddr)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sysProxyCheckAt = now
	if detected == "" {
		s.cachedSysProxy = ""
		s.surgeHopTrans = nil
		return nil
	}
	if detected == cachedURL && s.surgeHopTrans != nil {
		return s.surgeHopTrans
	}
	pu, err := url.Parse(detected)
	if err != nil {
		return nil
	}
	hopTr := &http.Transport{
		Proxy:                 http.ProxyURL(pu),
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          64,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   15 * time.Second,
		DisableCompression:    true,
		ExpectContinueTimeout: 2 * time.Second,
	}
	if s.ExtraTransportTLSConfig != nil {
		hopTr.TLSClientConfig = s.ExtraTransportTLSConfig.Clone()
	}
	s.cachedSysProxy = detected
	s.surgeHopTrans = hopTr
	return hopTr
}

func detectMacOSSystemHTTPProxy(excludeHostPort string) string {
	out, err := exec.Command("/usr/sbin/scutil", "--proxy").Output()
	if err != nil {
		return ""
	}
	var enabled, host, port string
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "HTTPSEnable :"):
			enabled = strings.TrimSpace(strings.TrimPrefix(line, "HTTPSEnable :"))
		case strings.HasPrefix(line, "HTTPSProxy :"):
			host = strings.TrimSpace(strings.TrimPrefix(line, "HTTPSProxy :"))
		case strings.HasPrefix(line, "HTTPSPort :"):
			port = strings.TrimSpace(strings.TrimPrefix(line, "HTTPSPort :"))
		}
	}
	if enabled != "1" || host == "" || port == "" {
		return ""
	}
	hp := host + ":" + port
	if hp == excludeHostPort {
		return ""
	}
	return "http://" + hp
}

func (s *Server) isProtectedHost(host string) bool {
	host = normalizeHost(host)
	s.mu.RLock()
	doms := s.domains
	s.mu.RUnlock()

	if _, ok := doms[host]; ok {
		return true
	}
	for d := range doms {
		if strings.HasSuffix(host, "."+d) {
			return true
		}
	}
	return false
}

func isGitHubHost(host string) bool {
	return host == "github.com" || host == "api.github.com" || strings.HasSuffix(host, ".github.com")
}

func (s *Server) dialRawUpstream(hostPort string) (net.Conn, error) {
	cfg := s.store.Get()
	if strings.TrimSpace(cfg.UpstreamProxyURL) == "" {
		return net.DialTimeout("tcp", hostPort, 15*time.Second)
	}
	pu, err := url.Parse(strings.TrimSpace(cfg.UpstreamProxyURL))
	if err != nil || pu.Host == "" {
		return net.DialTimeout("tcp", hostPort, 15*time.Second)
	}
	proxyConn, err := net.DialTimeout("tcp", pu.Host, 15*time.Second)
	if err != nil {
		return nil, err
	}
	connectReq := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", hostPort, hostPort)
	if _, err := proxyConn.Write([]byte(connectReq)); err != nil {
		_ = proxyConn.Close()
		return nil, err
	}
	buf := make([]byte, 1024)
	n, err := proxyConn.Read(buf)
	if err != nil || !strings.Contains(string(buf[:n]), " 200 ") {
		_ = proxyConn.Close()
		return nil, errors.New("upstream proxy CONNECT failed")
	}
	return proxyConn, nil
}

func tunnelBidirectional(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(b, a)
		_ = b.SetReadDeadline(time.Now().Add(250 * time.Millisecond))
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(a, b)
		_ = a.SetReadDeadline(time.Now().Add(250 * time.Millisecond))
	}()
	wg.Wait()
	_ = a.Close()
	_ = b.Close()
}

type prefixedConn struct {
	net.Conn
	prefix io.Reader
}

func (c *prefixedConn) Read(p []byte) (int, error) {
	if c.prefix != nil {
		n, err := c.prefix.Read(p)
		if n > 0 {
			return n, nil
		}
		if err == io.EOF {
			c.prefix = nil
		}
	}
	return c.Conn.Read(p)
}

func readUpTo(r io.Reader, limit int) ([]byte, bool, error) {
	data, err := io.ReadAll(io.LimitReader(r, int64(limit)+1))
	if err != nil {
		return nil, false, err
	}
	if len(data) > limit {
		return data[:limit], true, nil
	}
	return data, false, nil
}

func decompressGzip(raw []byte, limit int) ([]byte, error) {
	gr, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	defer gr.Close()
	return io.ReadAll(io.LimitReader(gr, int64(limit)))
}

func decodeLooseBase64(s string) (string, bool) {
	cleaned := strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == ' ' || r == '\t' {
			return -1
		}
		return r
	}, s)
	if len(cleaned) < 8 {
		return "", false
	}
	raw, err := base64.StdEncoding.DecodeString(cleaned)
	if err != nil {
		raw, err = base64.RawStdEncoding.DecodeString(strings.TrimRight(cleaned, "="))
		if err != nil {
			return "", false
		}
	}
	return string(raw), true
}

func detectClientLabel(ua string) string {
	lower := strings.ToLower(ua)
	switch {
	case strings.Contains(lower, "claude-cli") || strings.Contains(lower, "claude-code") || strings.Contains(lower, "anthropic"):
		return "Claude Code"
	case strings.Contains(lower, "codex") || strings.Contains(lower, "openai"):
		return "Codex / OpenAI"
	case strings.Contains(lower, "cursor"):
		return "Cursor"
	case strings.Contains(lower, "git/") || strings.Contains(lower, "git-lfs"):
		return "Git HTTPS"
	case strings.Contains(lower, "github cli") || strings.HasPrefix(lower, "gh/"):
		return "GitHub CLI (gh)"
	case strings.Contains(lower, "curl/"):
		return "curl"
	case strings.Contains(lower, "python"):
		return "Python SDK"
	case strings.Contains(lower, "node") || strings.Contains(lower, "undici"):
		return "Node / Agent CLI"
	default:
		if ua == "" {
			return "Local App"
		}
		if len(ua) > 28 {
			return ua[:28]
		}
		return ua
	}
}

func copyHeaders(dst, src http.Header) {
	for k, vals := range src {
		for _, v := range vals {
			dst.Add(k, v)
		}
	}
}

func stripHopByHopHeaders(h http.Header) {
	for _, k := range []string{
		"Connection",
		"Proxy-Connection",
		"Keep-Alive",
		"Proxy-Authenticate",
		"Proxy-Authorization",
		"Te",
		"Trailer",
		"Transfer-Encoding",
		"Upgrade",
	} {
		h.Del(k)
	}
}
