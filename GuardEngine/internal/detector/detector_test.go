package detector

import (
	"encoding/base64"
	"fmt"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/zhangsubo/deskside-guard/internal/config"
)

func TestKnownSecretsAhoCorasickAndEncodings(t *testing.T) {
	eng := NewEngine(config.Default())
	rawSecret := "my-custom-prod-db-secret#2026!"
	shortSecret := "p@ss77"

	eng.SetKnownSecrets([]KnownSecretInput{
		{Name: "PROD_DB_SECRET", Value: rawSecret},
		{Name: "SHORT_PIN", Value: shortSecret},
	})

	// 1. Direct plaintext hit
	f1 := eng.Analyze("connect using "+rawSecret+" please", ScanOptions{})
	if len(f1) != 1 || f1[0].RuleName != "ENV:PROD_DB_SECRET" {
		t.Fatalf("expected ENV:PROD_DB_SECRET hit, got %+v", f1)
	}
	if strings.Contains(f1[0].MaskedPreview, "custom-prod-db") {
		t.Fatalf("masked preview leaked secret middle: %s", f1[0].MaskedPreview)
	}

	// 2. Base64-encoded hit
	b64 := base64.StdEncoding.EncodeToString([]byte(rawSecret))
	f2 := eng.Analyze("AuthorizationPayload="+b64, ScanOptions{})
	if len(f2) == 0 || !strings.HasPrefix(f2[0].RuleName, "ENV:PROD_DB_SECRET") {
		t.Fatalf("expected base64 known secret hit, got %+v", f2)
	}

	// 3. URL-encoded hit
	escaped := url.QueryEscape(rawSecret)
	f3 := eng.Analyze("https://example.com/callback?sec="+escaped, ScanOptions{})
	if len(f3) == 0 {
		t.Fatalf("expected url-encoded known secret hit")
	}

	// 4. Short secret (< 8 chars) requires assignment cue
	if hits := eng.Analyze("random token p@ss77 without equals", ScanOptions{}); len(hits) != 0 {
		t.Fatalf("short secret without assignment context should not trigger, got %+v", hits)
	}
	if hits := eng.Analyze(`PIN="p@ss77"`, ScanOptions{}); len(hits) == 0 {
		t.Fatalf("short secret with assignment context should trigger")
	}
}

func TestDomesticAndInternationalRecognizers(t *testing.T) {
	eng := NewEngine(config.Default())

	cases := []struct {
		name     string
		input    string
		wantRule string
	}{
		{
			name:     "Aliyun AccessKey",
			input:    "export ALIYUN_AK=" + "LTAI" + "5t9x8A7b6C5d4E3f2G1h",
			wantRule: "ALIYUN_ACCESS_KEY",
		},
		{
			name:     "Tencent SecretId",
			input:    "secretId: " + "AKID" + "9z8y7x6w5v4u3t2s1r0qponmlkjihgfe",
			wantRule: "TENCENT_SECRET_ID",
		},
		{
			name:     "Feishu Bot Webhook",
			input:    "webhook = https://open.feishu.cn/open-apis/" + "bot/v2/hook/9a8b7c6d-1234-5678-9abc-def012345678",
			wantRule: "FEISHU_BOT_WEBHOOK",
		},
		{
			name:     "WeCom Bot Webhook",
			input:    "notify https://qyapi.weixin.qq.com/cgi-bin/" + "webhook/send?key=693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa",
			wantRule: "WECOM_BOT_WEBHOOK",
		},
		{
			name:     "Anthropic Key",
			input:    "key is " + "sk-ant-" + "api03-abcdefghijklmnopqrstuvwxyz012345",
			wantRule: "ANTHROPIC_API_KEY",
		},
		{
			name:     "GitHub PAT",
			input:    "token: " + "ghp_" + "1234567890abcdefghijklmnopqrstuvwx",
			wantRule: "GITHUB_TOKEN",
		},
		{
			name:     "PEM Private Key",
			input:    "-----BEGIN " + "OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END " + "OPENSSH PRIVATE KEY-----",
			wantRule: "PEM_PRIVATE_KEY",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			hits := eng.Analyze(tc.input, ScanOptions{})
			if len(hits) == 0 {
				t.Fatalf("expected hit for %s, got none", tc.name)
			}
			if hits[0].RuleName != tc.wantRule {
				t.Fatalf("want rule %s, got %+v", tc.wantRule, hits[0])
			}
		})
	}
}

func TestDatabaseURIPreservesHostAndDB(t *testing.T) {
	eng := NewEngine(config.Default())
	input := `DATABASE_URL="postgres://` + `app_admin:Sup3rS3cretP@ss!` + `@rds.internal.local:5432/orders"`
	hits := eng.Analyze(input, ScanOptions{})
	if len(hits) != 1 {
		t.Fatalf("expected 1 DB URI hit, got %+v", hits)
	}
	matched := input[hits[0].Start:hits[0].End]
	if matched != "app_admin:Sup3rS3cretP@ss!" {
		t.Fatalf("expected only userinfo span to be matched, got %q", matched)
	}
}

func TestZeroWidthAndMultiLineBase64Evasion(t *testing.T) {
	eng := NewEngine(config.Default())

	// Zero-width space injected inside sk-ant-api03-...
	evasive := "sk-ant-\u200b" + "api03-abcdefghijklmnopqrstuvwxyz012345"
	hits := eng.Analyze("please use "+evasive+" now", ScanOptions{})
	if len(hits) != 1 || hits[0].RuleName != "ANTHROPIC_API_KEY" {
		t.Fatalf("expected zero-width evasive key to be caught, got %+v", hits)
	}
	if gotSlice := ("please use " + evasive + " now")[hits[0].Start:hits[0].End]; gotSlice != evasive {
		t.Fatalf("byte span mismatch: got %q, want %q", gotSlice, evasive)
	}

	// Base64-wrapped .env secret
	inner := "AWS_ACCESS_KEY_ID=" + "AKIA" + "IOSFODNN7EXAMPLE\n"
	encoded := base64.StdEncoding.EncodeToString([]byte(inner))
	b64Hits := eng.Analyze("payload: "+encoded, ScanOptions{})
	if len(b64Hits) == 0 || !strings.HasPrefix(b64Hits[0].RuleName, "ENCODED_BASE64_") {
		t.Fatalf("expected nested base64 secret detection, got %+v", b64Hits)
	}
}

func TestFalsePositiveExemptionsAndAllowlist(t *testing.T) {
	cfg := config.Default()
	eng := NewEngine(cfg)

	cleanSamples := []string{
		`apiKey := os.Getenv("OPENAI_API_KEY")`,
		`const token = process.env.GITHUB_TOKEN`,
		`password: "${DB_PASSWORD}"`,
		`git clone git@github.com:zhangsubo/DeskSide.git`,
		`const user = { password: hashedPassword, token_ttl: 86400, max_tokens: 128000 }`,
		`Authorization: Bearer <SECRET_1>`,
		`CategoryAuthToken = "AUTH_TOKEN"`,
		`postgresql://user:pass@localhost:5432/app`,
		`postgresql://postgres@localhost:5432/dev`,
	}
	for _, sample := range cleanSamples {
		if hits := eng.Analyze(sample, ScanOptions{}); len(hits) != 0 {
			t.Fatalf("false positive on clean sample %q: %+v", sample, hits)
		}
	}

	// Test fingerprint allowlist & path allowlist
	secret := "LTAI" + "5t9x8A7b6C5d4E3f2G1h"
	fp := FingerprintValue(secret)
	cfg.Allowlist = []config.AllowlistEntry{
		{ID: "1", Kind: config.AllowFingerprint, Value: fp, CreatedAt: time.Now()},
		{ID: "2", Kind: config.AllowPath, Value: "Tests/fixtures/", CreatedAt: time.Now()},
	}
	eng.UpdateConfig(cfg)

	if hits := eng.Analyze("ak="+secret, ScanOptions{}); len(hits) != 0 {
		t.Fatalf("expected fingerprinted secret to be allowlisted, got %+v", hits)
	}
	if hits := eng.Analyze("ghp_"+"1234567890abcdefghijklmnopqrstuvwx", ScanOptions{FilePath: "Tests/fixtures/mock.env"}); len(hits) != 0 {
		t.Fatalf("expected allowlisted path to skip findings, got %+v", hits)
	}
}

func TestThreeLayerFunnelL1StrictL2MockExemptionAndL3NLDetection(t *testing.T) {
	cfg := config.Default()
	eng := NewEngine(cfg)

	l1Vendor := "sk-ant-" + "api03-StrictVendorPrefixMustNeverDowngrade123"
	l2Mock := "mock_secret_for_unit_test"
	l2Real := "Qingdao#" + "Prod9981!"
	l3ChatPwd := "Xm9@" + "Server2026"

	// 1. Code file scan (`Channel: "git"`): L1 vendor + L2 real kept; L2 mock auto-exempted in `aiExempted`!
	codeSample := fmt.Sprintf(
		"const %s = %q\nconst %s = %q\nconst %s = %q",
		"vendor", l1Vendor,
		"mock_"+"api_key", l2Mock,
		"prod_"+"password", l2Real,
	)

	kept, exempted := eng.AnalyzeDetailed(codeSample, ScanOptions{FilePath: "service_test.go", Channel: "git"})
	if len(kept) != 2 {
		t.Fatalf("expected 2 kept findings (L1 vendor + L2 real), got %d: %+v", len(kept), kept)
	}
	if len(exempted) != 1 || exempted[0].RuleName != "CONTEXT_KEY_SECRET" {
		t.Fatalf("expected 1 L2 AI-exempted finding for mock_api_key, got %+v", exempted)
	}

	// 2. LLM prompt scan (`Channel: "llm"`): L3 catches unformatted Chinese prose password!
	chatSample := "帮我连一下 10.0.1.8，线上 Redis 口令刚改成" + l3ChatPwd + "了，报错是 timeout_error。"
	llmKept, _ := eng.AnalyzeDetailed(chatSample, ScanOptions{Channel: "llm"})
	if len(llmKept) != 1 || llmKept[0].Category != CategoryAISecret || llmKept[0].RuleName != "AI_NL_SECRET" {
		t.Fatalf("expected 1 L3 AI_NL_SECRET finding on LLM channel, got %+v", llmKept)
	}
	if got := chatSample[llmKept[0].Start:llmKept[0].End]; got != l3ChatPwd {
		t.Fatalf("L3 span mismatch: got %q, want %q", got, l3ChatPwd)
	}

	// 3. Disabling L2/L3 toggles restores pure rule-based behavior.
	cfg.AIFunnel.L2VerifyEnabled = false
	cfg.AIFunnel.L3NLScanEnabled = false
	eng.UpdateConfig(cfg)

	keptNoAI, exemptedNoAI := eng.AnalyzeDetailed(codeSample, ScanOptions{FilePath: "service_test.go", Channel: "git"})
	if len(keptNoAI) != 3 || len(exemptedNoAI) != 0 {
		t.Fatalf("with L2 disabled, expected 3 kept & 0 exempted, got %d kept / %d exempted", len(keptNoAI), len(exemptedNoAI))
	}
	if llmNoL3 := eng.Analyze(chatSample, ScanOptions{Channel: "llm"}); len(llmNoL3) != 0 {
		t.Fatalf("with L3 disabled, expected 0 prose findings, got %+v", llmNoL3)
	}
}
