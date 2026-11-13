package detector

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"unicode/utf8"
)

const (
	CategoryEnvSecret     = "ENV_SECRET"
	CategoryCloudAK       = "CLOUD_AK"
	CategoryAIKey         = "AI_API_KEY"
	CategoryGitToken      = "GIT_TOKEN"
	CategoryWebhookSecret = "WEBHOOK_SECRET"
	CategoryPrivateKey    = "PRIVATE_KEY"
	CategoryAuthToken     = "AUTH_TOKEN"
	CategoryDBURI         = "DB_URI"
	CategoryContextSecret = "CONTEXT_SECRET"
	CategoryCustom        = "CUSTOM"
)

// PlaceholderType maps fine-grained categories to clean model-facing placeholder prefixes.
func PlaceholderType(category string) string {
	switch category {
	case CategoryDBURI:
		return "DB_URI"
	case CategoryPrivateKey:
		return "PRIVATE_KEY"
	default:
		return "SECRET"
	}
}

// Finding represents a detected sensitive span in the original input bytes.
// Raw secret values are strictly NOT stored on Finding for audit logging; callers
// needing replacement slice the in-memory request buffer using [Start:End].
type Finding struct {
	Category      string  `json:"category"`
	RuleName      string  `json:"ruleName"`
	Start         int     `json:"start"`
	End           int     `json:"end"`
	Score         float64 `json:"score"`
	MaskedPreview string  `json:"maskedPreview"`
	Fingerprint   string  `json:"fingerprint"`
}

type KnownSecretInput struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type ScanOptions struct {
	FilePath string
}

// MaskValue produces a safe zero-plaintext preview (e.g. "sk-proj-****9a2f").
func MaskValue(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	// Collapse multi-line PEM blocks to header summary.
	if strings.Contains(trimmed, "PRIVATE KEY") {
		firstLine, _, _ := strings.Cut(trimmed, "\n")
		if len(firstLine) > 36 {
			firstLine = firstLine[:36]
		}
		return firstLine + "••••"
	}
	runes := []rune(trimmed)
	n := len(runes)
	switch {
	case n <= 6:
		return "••••••"
	case n <= 12:
		return string(runes[:2]) + "****" + string(runes[n-2:])
	default:
		prefixLen := 6
		if prefixLen > n-4 {
			prefixLen = 3
		}
		return string(runes[:prefixLen]) + "****" + string(runes[n-4:])
	}
}

// FingerprintValue computes an irreversible truncated SHA-256 tag for deduplication & allowlisting.
func FingerprintValue(raw string) string {
	sum := sha256.Sum256([]byte("deskside-guard-v1:" + strings.TrimSpace(raw)))
	return "sha256:" + hex.EncodeToString(sum[:6]) // 12 hex chars (48 bits)
}

func isUTF8Boundary(s string, idx int) bool {
	if idx <= 0 || idx >= len(s) {
		return true
	}
	return utf8.RuneStart(s[idx])
}
