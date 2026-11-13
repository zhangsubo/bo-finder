package masker

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/zhangsubo/deskside-guard/internal/detector"
)

const (
	defaultTTL        = 45 * time.Minute
	maxVaultEntries   = 4096
	maxInspectPayload = 8 * 1024 * 1024 // 8 MB JSON payload safety cap
)

type vaultEntry struct {
	placeholder string
	rawValue    string
	expiresAt   time.Time
}

// Vault stores bidirectional placeholder <-> secret mappings strictly in memory with TTL & bounded capacity.
type Vault struct {
	mu           sync.RWMutex
	ttl          time.Duration
	counterByCat map[string]int
	byRaw        map[string]string // prefixType + "\x00" + rawValue -> placeholder
	byToken      map[string]vaultEntry
	order        []string // insertion order of placeholders for FIFO/LRU eviction
}

func NewVault(ttl time.Duration) *Vault {
	if ttl <= 0 {
		ttl = defaultTTL
	}
	return &Vault{
		ttl:          ttl,
		counterByCat: make(map[string]int),
		byRaw:        make(map[string]string),
		byToken:      make(map[string]vaultEntry),
	}
}

func (v *Vault) PlaceholderFor(category, rawValue string) string {
	prefix := detector.PlaceholderType(category)
	composite := prefix + "\x00" + rawValue
	now := time.Now()

	v.mu.Lock()
	defer v.mu.Unlock()

	v.evictExpiredLocked(now)

	if existing, ok := v.byRaw[composite]; ok {
		if ent, ok2 := v.byToken[existing]; ok2 {
			ent.expiresAt = now.Add(v.ttl)
			v.byToken[existing] = ent
			return existing
		}
	}

	v.counterByCat[prefix]++
	token := fmt.Sprintf("<%s_%d>", prefix, v.counterByCat[prefix])
	v.byRaw[composite] = token
	v.byToken[token] = vaultEntry{
		placeholder: token,
		rawValue:    rawValue,
		expiresAt:   now.Add(v.ttl),
	}
	v.order = append(v.order, token)

	for len(v.byToken) > maxVaultEntries && len(v.order) > 0 {
		oldest := v.order[0]
		v.order = v.order[1:]
		if ent, exists := v.byToken[oldest]; exists {
			delete(v.byToken, oldest)
			for k, tok := range v.byRaw {
				if tok == ent.placeholder {
					delete(v.byRaw, k)
					break
				}
			}
		}
	}
	return token
}

func (v *Vault) Lookup(placeholder string) (string, bool) {
	now := time.Now()
	v.mu.RLock()
	ent, ok := v.byToken[placeholder]
	v.mu.RUnlock()
	if !ok || now.After(ent.expiresAt) {
		return "", false
	}
	return ent.rawValue, true
}

func (v *Vault) ActiveCount() int {
	v.mu.RLock()
	defer v.mu.RUnlock()
	return len(v.byToken)
}

func (v *Vault) evictExpiredLocked(now time.Time) {
	for len(v.order) > 0 {
		tok := v.order[0]
		ent, ok := v.byToken[tok]
		if !ok {
			v.order = v.order[1:]
			continue
		}
		if now.Before(ent.expiresAt) {
			break
		}
		v.order = v.order[1:]
		delete(v.byToken, tok)
		for k, val := range v.byRaw {
			if val == tok {
				delete(v.byRaw, k)
				break
			}
		}
	}
}

// Protocol metadata keys that must NEVER be rewritten in OpenAI / Anthropic / Gemini JSON payloads.
var protocolSkipKeys = map[string]struct{}{
	"id":                  {},
	"model":               {},
	"role":                {},
	"type":                {},
	"object":              {},
	"tool_call_id":        {},
	"tool_use_id":         {},
	"call_id":             {},
	"previous_response_id": {},
	"conversation":        {},
	"signature":           {},
	"thought_signature":   {},
	"thoughtSignature":    {},
	"encrypted_content":   {},
	"cached_content":      {},
	"cachedContent":       {},
	"media_type":          {},
	"mime_type":           {},
	"mimeType":            {},
	"stop_reason":         {},
	"finish_reason":       {},
	"service_tier":        {},
}

func isProtocolKey(key string) bool {
	if _, ok := protocolSkipKeys[key]; ok {
		return true
	}
	return strings.HasSuffix(key, "_id") || strings.HasSuffix(key, "_ids")
}

type HitSummary struct {
	Category      string
	RuleName      string
	MaskedPreview string
	Fingerprint   string
	Location      string
}

// InspectAndMaskJSON parses an LLM JSON request payload, scans user/tool content fields,
// and when maskMode == true replaces detected secrets with session placeholders.
func InspectAndMaskJSON(rawBody []byte, engine *detector.Engine, vault *Vault, maskMode bool) ([]byte, []HitSummary, bool) {
	if len(rawBody) == 0 || len(rawBody) > maxInspectPayload {
		return rawBody, nil, false
	}

	var root any
	dec := json.NewDecoder(strings.NewReader(string(rawBody)))
	dec.UseNumber()
	if err := dec.Decode(&root); err != nil {
		// Fallback for plain text / multipart non-JSON bodies: scan raw string directly.
		text := string(rawBody)
		findings := engine.Analyze(text, detector.ScanOptions{})
		if len(findings) == 0 {
			return rawBody, nil, false
		}
		var hits []HitSummary
		var sb strings.Builder
		cursor := 0
		for _, f := range findings {
			hits = append(hits, HitSummary{
				Category:      f.Category,
				RuleName:      f.RuleName,
				MaskedPreview: f.MaskedPreview,
				Fingerprint:   f.Fingerprint,
				Location:      "body",
			})
			if maskMode && vault != nil {
				sb.WriteString(text[cursor:f.Start])
				sb.WriteString(vault.PlaceholderFor(f.Category, text[f.Start:f.End]))
				cursor = f.End
			}
		}
		if !maskMode || vault == nil {
			return rawBody, hits, false
		}
		sb.WriteString(text[cursor:])
		return []byte(sb.String()), hits, true
	}

	var hits []HitSummary
	modified := false

	var walk func(node any, path string, parentKey string) any
	walk = func(node any, path string, parentKey string) any {
		switch val := node.(type) {
		case map[string]any:
			// Skip base64 image blobs in Anthropic/OpenAI payloads.
			if t, _ := val["type"].(string); t == "image" || t == "redacted_thinking" {
				return val
			}
			for k, child := range val {
				if isProtocolKey(k) {
					continue
				}
				// Skip inline image data URLs (`data:image/...;base64,...`).
				if k == "data" {
					if mt, _ := val["media_type"].(string); strings.HasPrefix(mt, "image/") {
						continue
					}
					if mt, _ := val["mimeType"].(string); strings.HasPrefix(mt, "image/") {
						continue
					}
				}
				childPath := k
				if path != "" {
					childPath = path + "." + k
				}
				val[k] = walk(child, childPath, k)
			}
			return val

		case []any:
			for idx, item := range val {
				childPath := fmt.Sprintf("%s[%d]", path, idx)
				val[idx] = walk(item, childPath, parentKey)
			}
			return val

		case string:
			if strings.HasPrefix(val, "data:image/") {
				return val
			}
			// Do not rewrite tool declaration names or schema metadata under `tools`.
			if strings.HasPrefix(path, "tools[") {
				return val
			}
			findings := engine.Analyze(val, detector.ScanOptions{})
			if len(findings) == 0 {
				return val
			}
			for _, f := range findings {
				hits = append(hits, HitSummary{
					Category:      f.Category,
					RuleName:      f.RuleName,
					MaskedPreview: f.MaskedPreview,
					Fingerprint:   f.Fingerprint,
					Location:      path,
				})
			}
			if !maskMode || vault == nil {
				return val
			}
			var sb strings.Builder
			sb.Grow(len(val))
			cursor := 0
			for _, f := range findings {
				sb.WriteString(val[cursor:f.Start])
				sb.WriteString(vault.PlaceholderFor(f.Category, val[f.Start:f.End]))
				cursor = f.End
			}
			sb.WriteString(val[cursor:])
			modified = true
			return sb.String()

		default:
			return node
		}
	}

	root = walk(root, "", "")
	if !modified {
		return rawBody, hits, false
	}

	encoded, err := marshalUnescapedJSON(root)
	if err != nil {
		return rawBody, hits, false
	}
	return encoded, hits, true
}

func marshalUnescapedJSON(v any) ([]byte, error) {
	var sb strings.Builder
	enc := json.NewEncoder(&sb)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	out := sb.String()
	out = strings.TrimSuffix(out, "\n")
	return []byte(out), nil
}
