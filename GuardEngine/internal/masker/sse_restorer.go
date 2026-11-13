package masker

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
)

const maxPlaceholderLen = 32

var fullPlaceholderRe = regexp.MustCompile(`^<(?:SECRET|DB_URI|PRIVATE_KEY|CUSTOM)_\d+>$`)

func isValidPlaceholderBodyChar(b byte) bool {
	return (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

// tokenWindow buffers only incomplete `<SECRET_...` prefixes across BPE token boundaries
// while passing normal streaming characters with zero buffering latency.
type tokenWindow struct {
	vault   *Vault
	pending string
}

func (w *tokenWindow) Feed(chunk string) string {
	if w.vault == nil || (w.pending == "" && !strings.ContainsRune(chunk, '<')) {
		return chunk
	}
	s := w.pending + chunk
	w.pending = ""

	var out strings.Builder
	out.Grow(len(s))

	i := 0
	for i < len(s) {
		lt := strings.IndexByte(s[i:], '<')
		if lt < 0 {
			out.WriteString(s[i:])
			break
		}
		out.WriteString(s[i : i+lt])
		start := i + lt

		// Scan candidate `<[A-Z0-9_]+>`
		j := start + 1
		for j < len(s) && (j-start) < maxPlaceholderLen && isValidPlaceholderBodyChar(s[j]) {
			j++
		}

		if j == len(s) && (j-start) < maxPlaceholderLen {
			// Reached end of current chunk while still matching valid `<[A-Z0-9_]*` prefix!
			// Hold this tiny tail for the next SSE token delta.
			w.pending = s[start:]
			break
		}

		if j < len(s) && s[j] == '>' && j > start+1 {
			cand := s[start : j+1]
			if fullPlaceholderRe.MatchString(cand) {
				if realVal, ok := w.vault.Lookup(cand); ok {
					out.WriteString(realVal)
					i = j + 1
					continue
				}
			}
			out.WriteString(cand)
			i = j + 1
			continue
		}

		// Not a placeholder (e.g. `<div`, `<=`, `<think>`): emit `<` immediately and continue at start+1.
		out.WriteByte('<')
		i = start + 1
	}

	return out.String()
}

func (w *tokenWindow) Flush() string {
	if w.pending == "" {
		return ""
	}
	rem := w.pending
	w.pending = ""
	return rem
}

func containsPotentialAngleBracket(raw []byte) bool {
	return bytes.IndexByte(raw, '<') >= 0 ||
		bytes.Contains(raw, []byte(`\u003c`)) ||
		bytes.Contains(raw, []byte(`\u003C`))
}

// RestoreJSONBody restores all active placeholders inside a non-streaming JSON response payload,
// skipping protocol metadata fields.
func RestoreJSONBody(raw []byte, vault *Vault) []byte {
	if vault == nil || vault.ActiveCount() == 0 || !containsPotentialAngleBracket(raw) {
		return raw
	}
	var root any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&root); err != nil {
		win := tokenWindow{vault: vault}
		s := win.Feed(string(raw)) + win.Flush()
		return []byte(s)
	}

	changed := false
	var walk func(node any) any
	walk = func(node any) any {
		switch val := node.(type) {
		case map[string]any:
			for k, child := range val {
				if isProtocolKey(k) {
					continue
				}
				val[k] = walk(child)
			}
			return val
		case []any:
			for i, child := range val {
				val[i] = walk(child)
			}
			return val
		case string:
			if !strings.ContainsRune(val, '<') {
				return val
			}
			win := tokenWindow{vault: vault}
			restored := win.Feed(val) + win.Flush()
			if restored != val {
				changed = true
			}
			return restored
		default:
			return node
		}
	}

	root = walk(root)
	if !changed {
		return raw
	}
	encoded, err := marshalUnescapedJSON(root)
	if err != nil {
		return raw
	}
	return encoded
}

// SSERestorer wraps an upstream text/event-stream ReadCloser and performs streaming
// cross-token restoration of `<SECRET_N>` placeholders without buffering full responses.
type SSERestorer struct {
	src     io.ReadCloser
	reader  *bufio.Reader
	vault   *Vault
	windows map[string]*tokenWindow
	outBuf  bytes.Buffer
	eof     bool
}

func NewSSERestorer(src io.ReadCloser, vault *Vault) *SSERestorer {
	return &SSERestorer{
		src:     src,
		reader:  bufio.NewReaderSize(src, 32*1024),
		vault:   vault,
		windows: make(map[string]*tokenWindow),
	}
}

func (r *SSERestorer) winFor(key string) *tokenWindow {
	w, ok := r.windows[key]
	if !ok {
		w = &tokenWindow{vault: r.vault}
		r.windows[key] = w
	}
	return w
}

func (r *SSERestorer) Read(p []byte) (int, error) {
	for r.outBuf.Len() == 0 {
		if r.eof {
			return 0, io.EOF
		}
		line, err := r.reader.ReadBytes('\n')
		if len(line) > 0 {
			r.processSSELine(line)
		}
		if err != nil {
			if err == io.EOF {
				r.eof = true
				break
			}
			return 0, err
		}
	}
	if r.outBuf.Len() == 0 && r.eof {
		return 0, io.EOF
	}
	return r.outBuf.Read(p)
}

func (r *SSERestorer) Close() error {
	return r.src.Close()
}

func (r *SSERestorer) processSSELine(line []byte) {
	if r.vault == nil || r.vault.ActiveCount() == 0 {
		r.outBuf.Write(line)
		return
	}

	trimmed := bytes.TrimRight(line, "\r\n")
	lineEnding := line[len(trimmed):]
	if len(lineEnding) == 0 {
		lineEnding = []byte("\n")
	}

	if !bytes.HasPrefix(trimmed, []byte("data:")) {
		r.outBuf.Write(line)
		return
	}

	payloadBytes := bytes.TrimSpace(trimmed[len("data:"):])
	if len(payloadBytes) == 0 || bytes.Equal(payloadBytes, []byte("[DONE]")) {
		r.outBuf.Write(line)
		return
	}

	// Fast path: if no window has pending `<` AND this frame has no `<` (or `\u003c`), forward verbatim with zero JSON parse!
	if !r.hasPendingWindow() && !containsPotentialAngleBracket(payloadBytes) {
		r.outBuf.Write(line)
		return
	}

	var obj map[string]any
	dec := json.NewDecoder(bytes.NewReader(payloadBytes))
	dec.UseNumber()
	if err := dec.Decode(&obj); err != nil {
		r.outBuf.Write(line)
		return
	}

	if r.transformSSEObject(obj, "root") {
		if encoded, err := marshalUnescapedJSON(obj); err == nil {
			r.outBuf.WriteString("data: ")
			r.outBuf.Write(encoded)
			r.outBuf.Write(lineEnding)
			return
		}
	}
	r.outBuf.Write(line)
}

func (r *SSERestorer) hasPendingWindow() bool {
	for _, w := range r.windows {
		if w.pending != "" {
			return true
		}
	}
	return false
}

func (r *SSERestorer) transformSSEObject(node map[string]any, scope string) bool {
	changed := false

	// Scope stream indices (OpenAI `choices[].index`, Anthropic `index` on content_block_delta)
	if idxVal, ok := node["index"]; ok {
		scope = fmt.Sprintf("%s#%v", scope, idxVal)
	}

	for k, v := range node {
		if isProtocolKey(k) {
			continue
		}
		fieldScope := scope + "." + k
		switch child := v.(type) {
		case map[string]any:
			if r.transformSSEObject(child, fieldScope) {
				changed = true
			}
		case []any:
			for idx, elem := range child {
				elemScope := fmt.Sprintf("%s[%d]", fieldScope, idx)
				switch typed := elem.(type) {
				case map[string]any:
					if r.transformSSEObject(typed, elemScope) {
						changed = true
					}
				case string:
					w := r.winFor(elemScope)
					next := w.Feed(typed)
					if next != typed {
						child[idx] = next
						changed = true
					}
				}
			}
		case string:
			w := r.winFor(fieldScope)
			next := w.Feed(child)
			if next != child {
				node[k] = next
				changed = true
			}
		}
	}
	return changed
}
