package detector

import (
	"encoding/base64"
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
