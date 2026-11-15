package mlguard

import (
	"encoding/json"
	"fmt"
	"math"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTinyCNNMatchesPyTorchGoldenVectors(t *testing.T) {
	cnn, err := DefaultTinyCNN()
	if err != nil {
		t.Fatalf("DefaultTinyCNN failed: %v", err)
	}

	goldens := []struct {
		text     string
		cand     string
		wantProb float64
		wantKind string
	}{
		{
			text:     fmt.Sprintf("const %s = %q", "test_"+"api_key", "mock_secret_for_unit_test"),
			cand:     "mock_secret_for_unit_test",
			wantProb: 0.000003,
			wantKind: "none",
		},
		{
			text:     fmt.Sprintf("%s://%s@localhost:5432/testdb", "post"+"gres", "demo:demo_password"),
			cand:     "demo:demo_password",
			wantProb: 0.000299,
			wantKind: "none",
		},
		{
			text:     fmt.Sprintf("const %s = %q", "db_"+"password", "Qingdao#"+"Prod9981!"),
			cand:     "Qingdao#" + "Prod9981!",
			wantProb: 0.999999,
			wantKind: "password",
		},
		{
			text:     fmt.Sprintf("%s = %q", "SIGNING_"+"SECRET", "x9K#mP2$"+"vL8qR4wZ7nJ5"),
			cand:     "x9K#mP2$" + "vL8qR4wZ7nJ5",
			wantProb: 0.999993,
			wantKind: "generic",
		},
		{
			text:     fmt.Sprintf("%s=%s", "pass"+"word", "Xm9@"+"Server2026"),
			cand:     "Xm9@" + "Server2026",
			wantProb: 1.000000,
			wantKind: "password",
		},
	}

	for _, g := range goldens {
		start := strings.Index(g.text, g.cand)
		if start < 0 {
			t.Fatalf("cand %q not in %q", g.cand, g.text)
		}
		end := start + len(g.cand)
		pred := cnn.Predict(g.text, start, end)
		if math.Abs(pred.Prob-g.wantProb) > 1e-3 {
			t.Fatalf("cand %q: got prob %.6f, want %.6f", g.cand, pred.Prob, g.wantProb)
		}
		if pred.Kind != g.wantKind {
			t.Fatalf("cand %q: got kind %q, want %q", g.cand, pred.Kind, g.wantKind)
		}
	}
}

func TestL1DeterministicRulesAreNeverGrayZone(t *testing.T) {
	l1Rules := []string{
		"ENV:OPENAI_API_KEY",
		"ANTHROPIC_API_KEY",
		"OPENAI_API_KEY",
		"GITHUB_TOKEN",
		"ALIYUN_ACCESS_KEY",
		"TENCENT_SECRET_ID",
		"PEM_PRIVATE_KEY",
		"FEISHU_BOT_WEBHOOK",
		"CUSTOM:CORP_TOKEN",
	}
	for _, r := range l1Rules {
		if IsGrayZoneRule(r) {
			t.Fatalf("L1 rule %s must NEVER be eligible for L2 AI downgrade", r)
		}
	}

	l2Rules := []string{
		"CONTEXT_KEY_SECRET",
		"ENV_FALLBACK_SECRET",
		"SHELL_FALLBACK_SECRET",
		"CLI_FLAG_SECRET",
		"DATABASE_URI_CREDENTIALS",
		"URI_EMBEDDED_PASSWORD",
	}
	for _, r := range l2Rules {
		if !IsGrayZoneRule(r) {
			t.Fatalf("L2 rule %s should be eligible for gray-zone adjudication", r)
		}
	}
}

func TestL2GrayZoneExemptsMocksAndKeepsRealSecrets(t *testing.T) {
	mockCand := "mock_secret_for_unit_test"
	mockText := fmt.Sprintf("const %s = %q", "api_"+"key", mockCand)
	mStart := strings.Index(mockText, mockCand)

	realCand := "Qingdao#" + "Prod9981!"
	realText := fmt.Sprintf("const %s = %q", "db_"+"password", realCand)
	rStart := strings.Index(realText, realCand)

	verdicts := EvaluateGrayZoneBatch([]ScoreItem{
		{Text: mockText, Start: mStart, End: mStart + len(mockCand), RuleName: "CONTEXT_KEY_SECRET", FilePath: "auth_test.go"},
		{Text: realText, Start: rStart, End: rStart + len(realCand), RuleName: "CONTEXT_KEY_SECRET", FilePath: "auth_test.go"},
	}, nil, DefaultL2ExemptThreshold)

	if len(verdicts) != 2 {
		t.Fatalf("expected 2 verdicts, got %d", len(verdicts))
	}
	if !verdicts[0].Exempt {
		t.Fatalf("expected mock token to be AI-exempted, got %+v", verdicts[0])
	}
	if verdicts[1].Exempt {
		t.Fatalf("expected real password to be kept even in *_test.go, got %+v", verdicts[1])
	}
}

func TestCoprocessorUnixSocketAndFallback(t *testing.T) {
	sockPath := filepath.Join("/tmp", "dg-ai-test-"+filepath.Base(t.TempDir())+".sock")
	_ = os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen unix failed: %v", err)
	}
	defer func() {
		_ = ln.Close()
		_ = os.Remove(sockPath)
	}()

	srv := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req CoprocessorRequest
			_ = json.NewDecoder(r.Body).Decode(&req)
			res := make([]Prediction, len(req.Items))
			for i := range req.Items {
				res[i] = Prediction{Prob: 0.02, Kind: "none", Model: "coreml-ane-large", Reason: "ane_mock"}
			}
			_ = json.NewEncoder(w).Encode(CoprocessorResponse{Results: res})
		}),
	}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Close()

	client := NewCoprocessorClient(sockPath)
	candVal := "ambiguous_val_123"
	txt := fmt.Sprintf("%s = %q", "tok"+"en", candVal)
	s := strings.Index(txt, candVal)
	verdicts := EvaluateGrayZoneBatch([]ScoreItem{
		{Text: txt, Start: s, End: s + len(candVal), RuleName: "CONTEXT_KEY_SECRET"},
	}, client, DefaultL2ExemptThreshold)

	if !verdicts[0].Exempt || verdicts[0].Model != "coreml-ane-large" {
		t.Fatalf("expected coprocessor verdict from coreml-ane-large, got %+v", verdicts[0])
	}

	// Close coprocessor socket and verify seamless fallback to builtin-tiny-cnn.
	_ = srv.Close()
	_ = os.Remove(sockPath)
	fallback := EvaluateGrayZoneBatch([]ScoreItem{
		{Text: txt, Start: s, End: s + len(candVal), RuleName: "CONTEXT_KEY_SECRET"},
	}, client, DefaultL2ExemptThreshold)
	if fallback[0].Model != "builtin-tiny-cnn" {
		t.Fatalf("expected fallback to builtin-tiny-cnn, got %+v", fallback[0])
	}
}

func TestL3ScanNaturalLanguageChineseAndEnglish(t *testing.T) {
	pwd1 := "Qingdao#" + "Prod9981!"
	pwd2 := "Xm9@" + "Server2026"
	pwd3 := "Winter!" + "2026#Prod"

	prompt := strings.Join([]string{
		"帮我连一下 10.0.1.8:5432，root 密码刚改成" + pwd1 + "了，顺便看下 v1.2.3.13 日志。",
		"另外线上 Redis 口令：" + pwd2 + "，配置文件在 server_v2.py。",
		"The staging admin password is " + pwd3 + ".",
		"注意 mock_password_for_test 只是单测占位符，不要改；报错是 timeout_error。",
	}, "\n")

	spans := ScanNaturalLanguage(prompt, nil, nil, DefaultL3DetectThreshold)
	if len(spans) != 3 {
		var got []string
		for _, sp := range spans {
			got = append(got, prompt[sp.Start:sp.End])
		}
		t.Fatalf("expected exactly 3 L3 NL secrets, got %d (%v)", len(spans), got)
	}

	if got1 := prompt[spans[0].Start:spans[0].End]; got1 != pwd1 {
		t.Fatalf("span[0] = %q, want %q", got1, pwd1)
	}
	if got2 := prompt[spans[1].Start:spans[1].End]; got2 != pwd2 {
		t.Fatalf("span[1] = %q, want %q", got2, pwd2)
	}
	if got3 := prompt[spans[2].Start:spans[2].End]; got3 != pwd3 {
		t.Fatalf("span[2] = %q, want %q", got3, pwd3)
	}
}
