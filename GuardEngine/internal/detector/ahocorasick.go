package detector

import (
	"encoding/base64"
	"net/url"
	"strings"
	"sync"
)

type acPattern struct {
	ruleName        string
	length          int
	requiresContext bool
}

type acNode struct {
	next map[byte]int
	fail int
	outs []acPattern
}

// KnownSecretMatcher holds an immutable Aho-Corasick automaton swapped atomically under RWMutex.
// Plaintext secrets live only inside the automaton's byte transitions in memory and are never persisted.
type KnownSecretMatcher struct {
	mu    sync.RWMutex
	nodes []acNode
	count int
}

func NewKnownSecretMatcher() *KnownSecretMatcher {
	m := &KnownSecretMatcher{}
	m.SetSecrets(nil)
	return m
}

func (m *KnownSecretMatcher) Count() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.count
}

func (m *KnownSecretMatcher) SetSecrets(inputs []KnownSecretInput) {
	nodes := []acNode{{next: make(map[byte]int)}}
	validEntries := 0

	addWord := func(word string, meta acPattern) {
		if len(word) == 0 {
			return
		}
		cur := 0
		for i := 0; i < len(word); i++ {
			b := word[i]
			nxt, ok := nodes[cur].next[b]
			if !ok {
				nxt = len(nodes)
				nodes = append(nodes, acNode{next: make(map[byte]int)})
				nodes[cur].next[b] = nxt
			}
			cur = nxt
		}
		// Avoid duplicate rule metadata on identical secret values.
		for _, existing := range nodes[cur].outs {
			if existing.ruleName == meta.ruleName && existing.length == meta.length {
				return
			}
		}
		nodes[cur].outs = append(nodes[cur].outs, meta)
	}

	for _, item := range inputs {
		name := strings.TrimSpace(item.Name)
		val := strings.TrimSpace(item.Value)
		if name == "" || len(val) < 4 {
			continue
		}
		lower := strings.ToLower(val)
		if lower == "true" || lower == "false" || lower == "null" || lower == "none" || lower == "localhost" {
			continue
		}
		validEntries++
		ruleName := "ENV:" + name
		shortNeedCtx := len(val) < 8

		addWord(val, acPattern{
			ruleName:        ruleName,
			length:          len(val),
			requiresContext: shortNeedCtx,
		})

		if len(val) >= 6 {
			b64 := base64.StdEncoding.EncodeToString([]byte(val))
			if len(b64) >= 8 {
				addWord(b64, acPattern{
					ruleName:        ruleName + "(base64)",
					length:          len(b64),
					requiresContext: false,
				})
			}
			rawB64 := base64.RawStdEncoding.EncodeToString([]byte(val))
			if rawB64 != b64 && len(rawB64) >= 8 {
				addWord(rawB64, acPattern{
					ruleName:        ruleName + "(base64)",
					length:          len(rawB64),
					requiresContext: false,
				})
			}
			escaped := url.QueryEscape(val)
			if escaped != val && len(escaped) >= 8 {
				addWord(escaped, acPattern{
					ruleName:        ruleName + "(urlencoded)",
					length:          len(escaped),
					requiresContext: false,
				})
			}
		}
	}

	// Build BFS failure links.
	queue := make([]int, 0, len(nodes))
	for _, child := range nodes[0].next {
		nodes[child].fail = 0
		queue = append(queue, child)
	}
	for len(queue) > 0 {
		u := queue[0]
		queue = queue[1:]
		for b, v := range nodes[u].next {
			f := nodes[u].fail
			for f > 0 {
				if nxt, ok := nodes[f].next[b]; ok {
					f = nxt
					break
				}
				f = nodes[f].fail
			}
			if f != u {
				if nxt, ok := nodes[f].next[b]; ok && nxt != v {
					nodes[v].fail = nxt
				} else {
					nodes[v].fail = 0
				}
			}
			if failOuts := nodes[nodes[v].fail].outs; len(failOuts) > 0 {
				nodes[v].outs = append(nodes[v].outs, failOuts...)
			}
			queue = append(queue, v)
		}
	}

	m.mu.Lock()
	m.nodes = nodes
	m.count = validEntries
	m.mu.Unlock()
}

func (m *KnownSecretMatcher) Scan(text string) []Finding {
	m.mu.RLock()
	nodes := m.nodes
	count := m.count
	m.mu.RUnlock()

	if count == 0 || len(nodes) <= 1 || len(text) == 0 {
		return nil
	}

	var out []Finding
	state := 0
	for i := 0; i < len(text); i++ {
		b := text[i]
		for state > 0 {
			if _, ok := nodes[state].next[b]; ok {
				break
			}
			state = nodes[state].fail
		}
		if nxt, ok := nodes[state].next[b]; ok {
			state = nxt
		}
		if len(nodes[state].outs) == 0 {
			continue
		}
		end := i + 1
		for _, pat := range nodes[state].outs {
			start := end - pat.length
			if start < 0 || !isUTF8Boundary(text, start) || !isUTF8Boundary(text, end) {
				continue
			}
			if pat.requiresContext && !hasAssignmentBoundary(text, start, end) {
				continue
			}
			raw := text[start:end]
			out = append(out, Finding{
				Category:      CategoryEnvSecret,
				RuleName:      pat.ruleName,
				Start:         start,
				End:           end,
				Score:         1.0,
				MaskedPreview: MaskValue(raw),
				Fingerprint:   FingerprintValue(raw),
			})
		}
	}
	return out
}

func hasAssignmentBoundary(text string, start, end int) bool {
	// Require non-identifier boundary on both sides AND an assignment cue nearby before start.
	if start > 0 && isIdentByte(text[start-1]) {
		return false
	}
	if end < len(text) && isIdentByte(text[end]) {
		return false
	}
	winStart := start - 24
	if winStart < 0 {
		winStart = 0
	}
	prefix := text[winStart:start]
	return strings.ContainsAny(prefix, "=:,'\"")
}

func isIdentByte(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}
