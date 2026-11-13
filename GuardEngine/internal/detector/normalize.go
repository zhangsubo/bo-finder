package detector

import (
	"encoding/base64"
	"strings"
	"unicode/utf8"
)

type byteSpan struct {
	origStart int
	origEnd   int
}

type normalizedView struct {
	text  string
	spans []byteSpan // len(spans) == len(text), maps each byte in text to original byte span
}

func isZeroWidthRune(r rune) bool {
	switch {
	case r == 0x00AD, r == 0xFEFF:
		return true
	case r >= 0x200B && r <= 0x200F:
		return true
	case r >= 0x202A && r <= 0x202E:
		return true
	case r >= 0x2060 && r <= 0x2069:
		return true
	default:
		return false
	}
}

func fromHex(b byte) (byte, bool) {
	switch {
	case b >= '0' && b <= '9':
		return b - '0', true
	case b >= 'a' && b <= 'f':
		return b - 'a' + 10, true
	case b >= 'A' && b <= 'F':
		return b - 'A' + 10, true
	default:
		return 0, false
	}
}

// normalizeText strips zero-width evasion runes and decodes valid UTF-8 percent-encoding (%xx)
// while tracking exact byte spans back to raw input so redaction never shifts offsets.
func normalizeText(raw string) normalizedView {
	needsWork := false
	for i := 0; i < len(raw); i++ {
		c := raw[i]
		if c == '%' || c >= 0x80 {
			needsWork = true
			break
		}
	}
	if !needsWork {
		return normalizedView{text: raw}
	}

	var out strings.Builder
	out.Grow(len(raw))
	spans := make([]byteSpan, 0, len(raw))

	i := 0
	for i < len(raw) {
		// Decode contiguous %xx runs when they form valid printable UTF-8.
		if raw[i] == '%' && i+2 < len(raw) {
			if _, ok1 := fromHex(raw[i+1]); ok1 {
				if _, ok2 := fromHex(raw[i+2]); ok2 {
					runStart := i
					var decodedBytes []byte
					var escapeOffsets []int
					j := i
					for j+2 < len(raw) && raw[j] == '%' {
						hi, okH := fromHex(raw[j+1])
						lo, okL := fromHex(raw[j+2])
						if !okH || !okL {
							break
						}
						decodedBytes = append(decodedBytes, (hi<<4)|lo)
						escapeOffsets = append(escapeOffsets, j)
						j += 3
					}
					if utf8.Valid(decodedBytes) {
						consumed := 0
						for consumed < len(decodedBytes) {
							r, size := utf8.DecodeRune(decodedBytes[consumed:])
							srcStart := escapeOffsets[consumed]
							srcEnd := escapeOffsets[consumed+size-1] + 3
							consumed += size
							if isZeroWidthRune(r) || r == 0 {
								continue
							}
							var buf [4]byte
							n := utf8.EncodeRune(buf[:], r)
							for k := 0; k < n; k++ {
								out.WriteByte(buf[k])
								spans = append(spans, byteSpan{origStart: srcStart, origEnd: srcEnd})
							}
						}
						i = j
						_ = runStart
						continue
					}
				}
			}
		}

		r, size := utf8.DecodeRuneInString(raw[i:])
		if r != utf8.RuneError && isZeroWidthRune(r) {
			i += size
			continue
		}
		for k := 0; k < size; k++ {
			out.WriteByte(raw[i+k])
			spans = append(spans, byteSpan{origStart: i, origEnd: i + size})
		}
		i += size
	}

	return normalizedView{
		text:  out.String(),
		spans: spans,
	}
}

func (v normalizedView) mapSpan(start, end int) (int, int) {
	if v.spans == nil || len(v.spans) == 0 {
		return start, end
	}
	if start < 0 {
		start = 0
	}
	if end > len(v.spans) {
		end = len(v.spans)
	}
	if start >= end {
		return 0, 0
	}
	return v.spans[start].origStart, v.spans[end-1].origEnd
}

type base64Candidate struct {
	origStart int
	origEnd   int
	decoded   string
}

func isBase64BodyChar(b byte) bool {
	return (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '+' || b == '/' || b == '-' || b == '_'
}

// extractBase64Blocks finds standalone or multi-line wrapped Base64 blocks (including git diff '+' lines)
// that decode into printable UTF-8 text >= 12 bytes, allowing nested secret inspection.
func extractBase64Blocks(text string) []base64Candidate {
	const minEncodedLen = 20
	const maxEncodedLen = 16384

	var results []base64Candidate
	n := len(text)
	i := 0
	for i < n {
		if !isBase64BodyChar(text[i]) {
			i++
			continue
		}
		// Ensure left boundary is not identifier/path continuation.
		if i > 0 && isBase64BodyChar(text[i-1]) {
			i++
			continue
		}

		start := i
		var sb strings.Builder
		cur := i
		end := i

		for cur < n && sb.Len() <= maxEncodedLen {
			segStart := cur
			for cur < n && isBase64BodyChar(text[cur]) {
				cur++
			}
			eqCount := 0
			for cur < n && text[cur] == '=' && eqCount < 2 {
				cur++
				eqCount++
			}
			segLen := cur - segStart
			if segLen < 4 {
				break
			}
			sb.WriteString(text[segStart:cur])
			end = cur

			// Check if wrapped across newline (60/64/76 columns or git diff '+').
			pureLen := segLen - eqCount
			if eqCount > 0 || (pureLen != 60 && pureLen != 64 && pureLen != 76) {
				break
			}
			nextLine := cur
			if nextLine < n && text[nextLine] == '\r' {
				nextLine++
			}
			if nextLine >= n || text[nextLine] != '\n' {
				break
			}
			nextLine++
			// Optional git diff leading '+' followed by optional indentation.
			if nextLine < n && text[nextLine] == '+' && (nextLine+1 >= n || text[nextLine+1] != '+') {
				nextLine++
			}
			for nextLine < n && (text[nextLine] == ' ' || text[nextLine] == '\t') {
				nextLine++
			}
			if nextLine >= n || !isBase64BodyChar(text[nextLine]) {
				break
			}
			cur = nextLine
		}

		if end > i {
			i = end
		} else {
			i++
		}

		encoded := sb.String()
		if len(encoded) < minEncodedLen || len(encoded) > maxEncodedLen {
			continue
		}
		if decoded, ok := tryDecodePrintableUTF8(encoded); ok {
			results = append(results, base64Candidate{
				origStart: start,
				origEnd:   end,
				decoded:   decoded,
			})
		}
	}
	return results
}

func tryDecodePrintableUTF8(s string) (string, bool) {
	clean := strings.TrimRight(s, "=")
	if len(clean)%4 == 1 {
		return "", false
	}
	var data []byte
	var err error
	if strings.ContainsAny(clean, "-_") {
		data, err = base64.RawURLEncoding.DecodeString(clean)
	} else {
		data, err = base64.RawStdEncoding.DecodeString(clean)
	}
	if err != nil || len(data) < 10 || !utf8.Valid(data) {
		return "", false
	}
	printable := 0
	total := 0
	for _, r := range string(data) {
		total++
		if r == '\n' || r == '\r' || r == '\t' || (r >= 0x20 && r != 0x7F && r != utf8.RuneError) {
			printable++
		}
	}
	if total == 0 || float64(printable)/float64(total) < 0.90 {
		return "", false
	}
	return string(data), true
}
