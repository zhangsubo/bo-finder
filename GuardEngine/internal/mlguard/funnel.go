package mlguard

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	DefaultL2ExemptThreshold = 0.18
	DefaultL3DetectThreshold = 0.85
)

type ScoreItem struct {
	Text     string `json:"text"`
	Start    int    `json:"start"`
	End      int    `json:"end"`
	RuleName string `json:"ruleName,omitempty"`
	FilePath string `json:"filePath,omitempty"`
	Channel  string `json:"channel,omitempty"`
}

type CoprocessorRequest struct {
	Items []ScoreItem `json:"items"`
}

type CoprocessorResponse struct {
	Results []Prediction `json:"results"`
}

// CoprocessorSocketPath computes a macOS-safe (<=96 byte sun_path) Unix domain socket path
// for DeskSide's local CoreML ANE / FoundationModels AI coprocessor.
func CoprocessorSocketPath(stateDir, explicitPath string) string {
	if p := strings.TrimSpace(explicitPath); p != "" {
		return p
	}
	if stateDir == "" {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			stateDir = filepath.Join(home, ".config", "deskside-guard")
		} else {
			stateDir = ".deskside-guard"
		}
	}
	direct := filepath.Join(stateDir, "ai-coproc.sock")
	if len(direct) <= 96 {
		return direct
	}
	sum := sha256.Sum256([]byte(filepath.Clean(stateDir)))
	return fmt.Sprintf("/tmp/dg-ai-%d-%s.sock", os.Getuid(), hex.EncodeToString(sum[:6]))
}

// CoprocessorClient queries DeskSide's local CoreML ANE / FoundationModels Unix socket when active,
// falling back immediately in <2µs if the socket is absent or times out.
type CoprocessorClient struct {
	sockPath string
	client   *http.Client
}

func NewCoprocessorClient(sockPath string) *CoprocessorClient {
	if strings.TrimSpace(sockPath) == "" {
		return nil
	}
	tr := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", sockPath)
		},
		MaxIdleConns:    4,
		IdleConnTimeout: 30 * time.Second,
	}
	return &CoprocessorClient{
		sockPath: sockPath,
		client: &http.Client{
			Transport: tr,
			Timeout:   900 * time.Millisecond,
		},
	}
}

func (c *CoprocessorClient) ScoreBatch(items []ScoreItem) ([]Prediction, bool) {
	if c == nil || len(items) == 0 || c.sockPath == "" {
		return nil, false
	}
	if info, err := os.Stat(c.sockPath); err != nil || info.IsDir() {
		return nil, false
	}
	body, err := json.Marshal(CoprocessorRequest{Items: items})
	if err != nil {
		return nil, false
	}
	resp, err := c.client.Post("http://unix/v1/score", "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, false
	}
	var parsed CoprocessorResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil || len(parsed.Results) != len(items) {
		return nil, false
	}
	return parsed.Results, true
}

func (c *CoprocessorClient) ActiveModel() string {
	if c == nil || c.sockPath == "" {
		return "builtin-tiny-cnn"
	}
	if info, err := os.Stat(c.sockPath); err != nil || info.IsDir() {
		return "builtin-tiny-cnn"
	}
	resp, err := c.client.Get("http://unix/v1/info")
	if err != nil {
		return "builtin-tiny-cnn"
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "builtin-tiny-cnn"
	}
	var payload struct {
		Model string `json:"model"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err == nil && payload.Model != "" {
		return payload.Model
	}
	return "coreml-ane-large"
}

var grayZoneRules = map[string]struct{}{
	"CONTEXT_KEY_SECRET":                      {},
	"ENV_FALLBACK_SECRET":                     {},
	"SHELL_FALLBACK_SECRET":                   {},
	"CLI_FLAG_SECRET":                         {},
	"DATABASE_URI_CREDENTIALS":                {},
	"URI_EMBEDDED_PASSWORD":                   {},
	"ENCODED_BASE64_CONTEXT_KEY_SECRET":       {},
	"ENCODED_BASE64_ENV_FALLBACK_SECRET":      {},
	"ENCODED_BASE64_SHELL_FALLBACK_SECRET":    {},
	"ENCODED_BASE64_CLI_FLAG_SECRET":          {},
	"ENCODED_BASE64_DATABASE_URI_CREDENTIALS": {},
	"ENCODED_BASE64_URI_EMBEDDED_PASSWORD":    {},
}

// IsGrayZoneRule returns true ONLY for heuristic/contextual rules eligible for L2 AI false-positive review.
// L1 deterministic vendor tokens (`sk-ant-`, `ghp_`, `LTAI`, `ENV:*`, PEM blocks, etc.) ALWAYS return false.
func IsGrayZoneRule(ruleName string) bool {
	_, ok := grayZoneRules[ruleName]
	return ok
}

type GrayZoneVerdict struct {
	Exempt bool
	Prob   float64
	Model  string
	Reason string
}

var (
	mockValueCueRe = regexp.MustCompile(`(?i)(?:^|[_.:/-])(?:mock|fake|dummy|fixture|placeholder|changeme|example|sample|unit_?test|test_?(?:key|secret|token|pass|pwd)|demo_?(?:key|secret|token|pass|pwd)|your_?[a-z0-9_]+|replace_?me|default_?(?:label|name|type))(?:$|[_.:/0-9-])`)
	testFilePathRe = regexp.MustCompile(`(?i)(?:^|/)(?:tests?|specs?|fixtures?|testdata| mocks?|__tests__|examples?)/|(?:_test\.go|\.test\.[jt]sx?|\.spec\.[jt]sx?|Tests\.swift|\.md)$`)

	ipv4PortRe   = regexp.MustCompile(`^\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?$`)
	hostPortRe   = regexp.MustCompile(`^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*:\d{2,5}$`)
	semverRe     = regexp.MustCompile(`^v?\d+\.\d+(?:\.\d+)*(?:-[A-Za-z0-9.-]+)?$`)
	emailRe      = regexp.MustCompile(`^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,12}$`)
	uuidRe       = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	benignTechRe = regexp.MustCompile(`(?i)^(?:sha(?:1|256|384|512)|md5|base64|utf-?8|utf-?16|arm64|x86_64|amd64|http[123]|oauth2|tls1[._]?[23]|jwt|aes256|rsa2048|ed25519|localhost|127\.0\.0\.1|postgres(?:ql)?|mysql|redis|mongodb)$`)
)

// EvaluateGrayZoneBatch scores a slice of L2 gray-zone candidates using the hybrid stack
// (DeskSide CoreML ANE / FoundationModels coprocessor -> embedded pure-Go TinyCNN fallback).
func EvaluateGrayZoneBatch(items []ScoreItem, coproc *CoprocessorClient, threshold float64) []GrayZoneVerdict {
	if len(items) == 0 {
		return nil
	}
	if threshold <= 0 {
		threshold = DefaultL2ExemptThreshold
	}

	// For `user:password` URI spans, `bardsai/password-detector` expects `postgres://user:` in left context
	// (`seg=1`) and only `password` in candidate (`seg=2`). Normalize `ScoreItem` spans before scoring!
	normalizedItems := make([]ScoreItem, len(items))
	secretParts := make([]string, len(items))
	for i, it := range items {
		normIt := it
		cand := ""
		if it.Start >= 0 && it.End <= len(it.Text) && it.Start < it.End {
			cand = it.Text[it.Start:it.End]
		}
		secretPart := cand
		if strings.Contains(it.RuleName, "URI") {
			if colonIdx := strings.IndexByte(cand, ':'); colonIdx >= 0 && colonIdx+1 < len(cand) {
				secretPart = cand[colonIdx+1:]
				normIt.Start = it.Start + colonIdx + 1
			}
		}
		normalizedItems[i] = normIt
		secretParts[i] = secretPart
	}

	preds, ok := coproc.ScoreBatch(normalizedItems)
	if !ok {
		cnn, err := DefaultTinyCNN()
		preds = make([]Prediction, len(normalizedItems))
		for i, it := range normalizedItems {
			if err != nil {
				// Fail-safe: if embedded model ever fails, keep finding (`Prob = 1.0`).
				preds[i] = Prediction{Prob: 1.0, Kind: "generic", Model: "failsafe"}
			} else {
				preds[i] = cnn.Predict(it.Text, it.Start, it.End)
			}
		}
	}

	out := make([]GrayZoneVerdict, len(items))
	for i, it := range items {
		secretPart := secretParts[i]

		prob := preds[i].Prob
		reason := preds[i].Reason
		modelName := preds[i].Model
		if modelName == "" {
			modelName = "builtin-tiny-cnn"
		}

		prob, calReason := calibrateGrayZoneScore(prob, secretPart, it.FilePath)
		if calReason != "" && reason == "" {
			reason = calReason
		}
		out[i] = GrayZoneVerdict{
			Exempt: prob <= threshold,
			Prob:   prob,
			Model:  modelName,
			Reason: reason,
		}
	}
	return out
}

func calibrateGrayZoneScore(neuralProb float64, secretPart, filePath string) (float64, string) {
	trimmed := strings.TrimSpace(secretPart)
	if trimmed == "" {
		return 0.0, "empty"
	}

	// 1. Explicit mock / placeholder / unit-test token shapes strongly push toward exemption.
	if mockValueCueRe.MatchString(trimmed) && !looksHighEntropyRandom(trimmed) {
		if neuralProb > 0.05 {
			return 0.05, "mock_fixture_token"
		}
		return neuralProb, "mock_fixture_token"
	}

	// 2. Fail-safe guardrail: high-entropy random strings or multi-class complex credentials
	//    must NEVER be exempted even in test files unless explicitly mock-prefixed above.
	if looksStrongCredential(trimmed) && neuralProb < 0.55 {
		return math.Max(neuralProb, 0.55), "high_complexity_credential_guard"
	}

	// 3. Test/spec/documentation file path lowers borderline gray-zone identifiers.
	if filePath != "" && testFilePathRe.MatchString(filepath.ToSlash(filePath)) && neuralProb < 0.35 {
		return neuralProb * 0.5, "test_or_doc_context"
	}

	return neuralProb, "neural_score"
}

func looksHighEntropyRandom(s string) bool {
	if len(s) < 20 {
		return false
	}
	ent := shannonEntropy(s)
	classes := countCharClasses(s)
	return ent >= 4.0 && classes >= 3
}

func looksStrongCredential(s string) bool {
	if len(s) < 8 {
		return false
	}
	if ipv4PortRe.MatchString(s) || hostPortRe.MatchString(s) || semverRe.MatchString(s) || uuidRe.MatchString(s) {
		return false
	}
	classes := countCharClasses(s)
	ent := shannonEntropy(s)
	// Multi-class password (upper + lower + digit + symbol) with realistic entropy
	if classes >= 4 && ent >= 2.8 {
		return true
	}
	if len(s) >= 20 && classes >= 3 && ent >= 3.85 {
		return true
	}
	return false
}

func shannonEntropy(s string) float64 {
	if len(s) == 0 {
		return 0
	}
	var counts [256]int
	for i := 0; i < len(s); i++ {
		counts[s[i]]++
	}
	invN := 1.0 / float64(len(s))
	var ent float64
	for _, c := range counts {
		if c > 0 {
			p := float64(c) * invN
			ent -= p * math.Log2(p)
		}
	}
	return ent
}

func countCharClasses(s string) int {
	var hasLower, hasUpper, hasDigit, hasSym bool
	for i := 0; i < len(s); i++ {
		b := s[i]
		switch {
		case b >= 'a' && b <= 'z':
			hasLower = true
		case b >= 'A' && b <= 'Z':
			hasUpper = true
		case b >= '0' && b <= '9':
			hasDigit = true
		case b > 0x20 && b < 0x7f && b != '_' && b != '-' && b != '.':
			hasSym = true
		}
	}
	total := 0
	if hasLower {
		total++
	}
	if hasUpper {
		total++
	}
	if hasDigit {
		total++
	}
	if hasSym {
		total++
	}
	return total
}

// --- Layer 3: Natural-Language Unformatted Secret Span Detection (LLM Prompt Channel) ---

type NLSpan struct {
	Start int
	End   int
	Score float64
	Kind  string
	Model string
}

var nlCredentialCues = []string{
	"密码", "口令", "密钥", "秘钥", "私钥", "账密",
	"passphrase", "password", "passwd", "pwd", "secret", "token",
}

func hasAnyCredentialCue(s string) bool {
	lower := strings.ToLower(s)
	for _, cue := range nlCredentialCues {
		if strings.Contains(lower, cue) {
			return true
		}
	}
	return false
}

// ScanNaturalLanguage detects unformatted credentials in conversational Chinese/English LLM prompts
// (e.g. "连一下 10.0.1.8，root 密码刚改成 Qingdao#Prod9981! 了") that lack `key=val` syntax or vendor prefixes.
func ScanNaturalLanguage(text string, existingSpans [][2]int, coproc *CoprocessorClient, threshold float64) []NLSpan {
	if len(text) < 6 || !hasAnyCredentialCue(text) {
		return nil
	}
	if threshold <= 0 {
		threshold = DefaultL3DetectThreshold
	}

	type rawCand struct {
		absStart int
		absEnd   int
		clause   string
		relStart int
		relEnd   int
		val      string
	}
	var cands []rawCand

	// Walk clauses split by newlines and major Chinese/English sentence punctuation.
	clauseStart := 0
	flushClause := func(cStart, cEnd int) {
		if cEnd-cStart < 6 {
			return
		}
		clause := text[cStart:cEnd]
		if !hasAnyCredentialCue(clause) {
			return
		}
		// Extract contiguous printable ASCII value runs bounded by whitespace, quotes, or non-ASCII CJK chars.
		i := 0
		for i < len(clause) {
			for i < len(clause) && !isCandidateASCIIByte(clause[i]) {
				i++
			}
			runStart := i
			for i < len(clause) && isCandidateASCIIByte(clause[i]) {
				i++
			}
			runEnd := i
			if runEnd <= runStart {
				continue
			}

			// Trim leading `:` / `=` (e.g. `密码:Qingdao#Prod9981!`) and trailing sentence punctuation (`.`, `?`).
			for runStart < runEnd && (clause[runStart] == ':' || clause[runStart] == '=') {
				runStart++
			}
			for runEnd > runStart && (clause[runEnd-1] == '.' || clause[runEnd-1] == '?') {
				runEnd--
			}
			// If token contains `=` or `:` (like `user:pass` vs `password=foo`), also inspect right-hand value if needed,
			// though `key=value` is normally already handled by L2.
			if idx := strings.IndexByte(clause[runStart:runEnd], '='); idx > 0 {
				lhs := clause[runStart : runStart+idx]
				if hasAnyCredentialCue(lhs) {
					runStart = runStart + idx + 1
				}
			}

			if runEnd-runStart < 6 || runEnd-runStart > 128 {
				continue
			}
			absS := cStart + runStart
			absE := cStart + runEnd
			if overlapsSpan(absS, absE, existingSpans) {
				continue
			}
			val := clause[runStart:runEnd]
			if !isPlausibleNLCredentialToken(val) {
				continue
			}
			cands = append(cands, rawCand{
				absStart: absS,
				absEnd:   absE,
				clause:   clause,
				relStart: runStart,
				relEnd:   runEnd,
				val:      val,
			})
		}
	}

	for idx := 0; idx < len(text); {
		b := text[idx]
		if b == '\n' || b == '\r' || b == ';' || b == ',' {
			flushClause(clauseStart, idx)
			idx++
			clauseStart = idx
			continue
		}
		// Check common UTF-8 Chinese clause delimiters: `，` (EF BC 8C), `。` (E3 80 82), `；` (EF BC 9B), `！` (EF BC 81), `？` (EF BC 9F)
		if idx+3 <= len(text) {
			s3 := text[idx : idx+3]
			if s3 == "，" || s3 == "。" || s3 == "；" || s3 == "！" || s3 == "？" {
				flushClause(clauseStart, idx)
				idx += 3
				clauseStart = idx
				continue
			}
		}
		idx++
	}
	flushClause(clauseStart, len(text))

	if len(cands) == 0 {
		return nil
	}

	// Score each candidate in BOTH raw clause context and normalized `"password=" + val` cue context
	// so Chinese credential cues ("密码刚改成 X") get the same neural sensitivity as English cues.
	scoreItems := make([]ScoreItem, 0, len(cands)*2)
	for _, c := range cands {
		scoreItems = append(scoreItems, ScoreItem{
			Text:    c.clause,
			Start:   c.relStart,
			End:     c.relEnd,
			Channel: "llm",
		})
		normCtx := "password=" + c.val
		scoreItems = append(scoreItems, ScoreItem{
			Text:    normCtx,
			Start:   len("password="),
			End:     len(normCtx),
			Channel: "llm",
		})
	}

	preds, ok := coproc.ScoreBatch(scoreItems)
	if !ok {
		cnn, err := DefaultTinyCNN()
		if err != nil {
			return nil
		}
		preds = make([]Prediction, len(scoreItems))
		for i, it := range scoreItems {
			preds[i] = cnn.Predict(it.Text, it.Start, it.End)
		}
	}

	var hits []NLSpan
	for i, c := range cands {
		pRaw := preds[i*2]
		pCue := preds[i*2+1]
		best := pRaw
		if pCue.Prob > best.Prob {
			best = pCue
		}
		if mockValueCueRe.MatchString(c.val) && !looksHighEntropyRandom(c.val) {
			continue
		}
		if best.Prob >= threshold {
			hits = append(hits, NLSpan{
				Start: c.absStart,
				End:   c.absEnd,
				Score: best.Prob,
				Kind:  best.Kind,
				Model: best.Model,
			})
		}
	}
	return hits
}

func isCandidateASCIIByte(b byte) bool {
	if b <= 0x20 || b >= 0x7f {
		return false
	}
	switch b {
	case '"', '\'', '`', '<', '>', '(', ')', '[', ']', '{', '}', ',', ';', '|', '\\':
		return false
	default:
		return true
	}
}

func isPlausibleNLCredentialToken(val string) bool {
	if len(val) < 6 || len(val) > 128 {
		return false
	}
	if strings.HasPrefix(val, "$") || strings.HasPrefix(val, "-") ||
		strings.HasPrefix(val, "/") || strings.HasPrefix(val, "./") || strings.HasPrefix(val, "~/") {
		return false
	}
	lower := strings.ToLower(val)
	if strings.Contains(lower, "://") || strings.HasPrefix(lower, "www.") {
		return false
	}
	if benignTechRe.MatchString(val) || ipv4PortRe.MatchString(val) ||
		hostPortRe.MatchString(val) || semverRe.MatchString(val) ||
		emailRe.MatchString(val) || uuidRe.MatchString(val) {
		return false
	}
	if mockValueCueRe.MatchString(val) {
		return false
	}

	// Require credential-like composition in prose: at least one ASCII letter AND at least one digit or symbol
	// (prevents ordinary English words like "password", "production", "timeout_error" or pure ports "5432" from matching).
	var hasLetter, hasDigit, hasSymbol bool
	for i := 0; i < len(val); i++ {
		b := val[i]
		switch {
		case (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z'):
			hasLetter = true
		case b >= '0' && b <= '9':
			hasDigit = true
		case b != '_' && b != '-' && b != '.':
			hasSymbol = true
		}
	}
	if !hasLetter || (!hasDigit && !hasSymbol) {
		return false
	}
	// Reject file-like extensions (`config.json`, `server_v2.py`, `backup_2026.sql`)
	if dot := strings.LastIndexByte(val, '.'); dot > 0 && dot+1 < len(val) {
		ext := strings.ToLower(val[dot+1:])
		switch ext {
		case "go", "py", "js", "ts", "tsx", "jsx", "swift", "json", "yaml", "yml", "toml", "md", "txt", "sh", "sql", "env", "pem", "crt", "key", "log", "csv", "xml", "html", "css", "zip", "gz":
			return false
		}
	}
	return true
}

func overlapsSpan(start, end int, spans [][2]int) bool {
	for _, sp := range spans {
		if start < sp[1] && sp[0] < end {
			return true
		}
	}
	return false
}
