package masker

import (
	"io"
	"strings"
	"testing"
	"time"

	"github.com/zhangsubo/deskside-guard/internal/config"
	"github.com/zhangsubo/deskside-guard/internal/detector"
)

func TestInspectAndMaskJSONPreservesProtocolIDs(t *testing.T) {
	eng := detector.NewEngine(config.Default())
	vault := NewVault(10 * time.Minute)

	realKey := "sk-ant-" + "api03-RealProductionSecretKey1234567890"
	realDB := "postgres://" + "prod_user:ProdPass9988!" + "@pg.internal:5432/core"
	fakeLookingToolID := "toolu_" + "sk-ant-" + "api03-ProtocolIdentifierShouldNotChange12345"

	reqBody := `{
  "model": "claude-sonnet-4-6",
  "tools": [{"name": "bash", "description": "example ` + "sk-ant-" + `api03-ToolSchemaShouldStayUntouched12345"}],
  "messages": [
    {
      "role": "assistant",
      "content": [{"type": "tool_use", "id": "` + fakeLookingToolID + `", "name": "bash", "input": {"cmd": "cat .env"}}]
    },
    {
      "role": "user",
      "content": [
        {
          "type": "tool_result",
          "tool_use_id": "` + fakeLookingToolID + `",
          "content": "ANTHROPIC_API_KEY=` + realKey + `\nDATABASE_URL=` + realDB + `"
        }
      ]
    }
  ]
}`

	masked, hits, modified := InspectAndMaskJSON([]byte(reqBody), eng, vault, true)
	if !modified {
		t.Fatalf("expected payload to be modified")
	}
	if len(hits) != 2 {
		t.Fatalf("expected 2 hits, got %d: %+v", len(hits), hits)
	}
	out := string(masked)
	if strings.Contains(out, realKey) || strings.Contains(out, "ProdPass9988!") {
		t.Fatalf("masked payload still leaked plaintext secret: %s", out)
	}
	if !strings.Contains(out, "<SECRET_1>") || !strings.Contains(out, "postgres://<DB_URI_1>@pg.internal:5432/core") {
		t.Fatalf("expected semantic placeholders in masked JSON, got: %s", out)
	}
	if !strings.Contains(out, fakeLookingToolID) {
		t.Fatalf("protocol tool_use_id / id was mutated! got: %s", out)
	}
}

func TestSSERestorerHandlesSplitBPETokensAndHTML(t *testing.T) {
	vault := NewVault(10 * time.Minute)
	secretVal := "LTAI" + "5tRealAliyunKey99887766"
	dbVal := "admin:MySuperSecretDBPass"

	tok1 := vault.PlaceholderFor(detector.CategoryCloudAK, secretVal) // <SECRET_1>
	tok2 := vault.PlaceholderFor(detector.CategoryDBURI, dbVal)       // <DB_URI_1>
	if tok1 != "<SECRET_1>" || tok2 != "<DB_URI_1>" {
		t.Fatalf("unexpected placeholder names: %s, %s", tok1, tok2)
	}

	// Simulate 5-chunk split of <SECRET_1>, normal HTML `<div>` / `a < b`, and HTML-escaped `\u003cDB_URI_1\u003e`.
	sseFrames := strings.Join([]string{
		`event: content_block_delta`,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Check <div> & a < b, key="}}`,
		``,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"<"}}`,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"SEC"}}`,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"RET"}}`,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"_1"}}`,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"> and postgres://"}}`,
		`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\u003cDB_URI_1\u003e@db:5432"}}`,
		`data: [DONE]`,
		``,
	}, "\n")

	restorer := NewSSERestorer(io.NopCloser(strings.NewReader(sseFrames)), vault)
	restoredBytes, err := io.ReadAll(restorer)
	if err != nil {
		t.Fatalf("read SSE restorer failed: %v", err)
	}
	full := string(restoredBytes)
	if !strings.Contains(full, secretVal) {
		t.Fatalf("failed to restore 5-way split <SECRET_1>; output:\n%s", full)
	}
	if !strings.Contains(full, dbVal+"@db:5432") {
		t.Fatalf("failed to restore HTML-escaped <DB_URI_1>; output:\n%s", full)
	}
	if !strings.Contains(full, "Check <div> & a < b") {
		t.Fatalf("corrupted normal angle brackets; output:\n%s", full)
	}
}
