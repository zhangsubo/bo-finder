package detector

import (
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"

	"github.com/zhangsubo/deskside-guard/internal/config"
)

type ruleDef struct {
	ruleName   string
	category   string
	group      string // "intl" | "domestic" | "priv"
	re         *regexp.Regexp
	valueGroup int // 0 means whole match, >0 means submatch index
	score      float64
}

var (
	compiledRules = []ruleDef{
		// --- Private keys & Auth headers ---
		{
			ruleName: "PEM_PRIVATE_KEY",
			category: CategoryPrivateKey,
			group:    "priv",
			re:       regexp.MustCompile(`(?s)(?:-----|---- )BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?(?:-----| ----).*?(?:(?:-----|---- )END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?(?:-----| ----)|$)`),
			score:    0.99,
		},
		{
			ruleName:   "AUTH_BEARER_BASIC",
			category:   CategoryAuthToken,
			group:      "priv",
			re:         regexp.MustCompile(`(?i)["']?(?:proxy-)?authorization["']?\s*:\s*["']?(?:bearer|basic)\s+([A-Za-z0-9._~+/=-]{12,})`),
			valueGroup: 1,
			score:      0.97,
		},
		{
			ruleName: "JWT_TOKEN",
			category: CategoryAuthToken,
			group:    "priv",
			re:       regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`),
			score:    0.96,
		},
		{
			ruleName:   "NPM_DOCKER_AUTH",
			category:   CategoryAuthToken,
			group:      "priv",
			re:         regexp.MustCompile(`(?i)(?:"auth"\s*:\s*"([A-Za-z0-9+/]{12,}={0,2})"|(?:npm_config_)?_auth(?:Token)?\s*=\s*["']?([A-Za-z0-9._+/=-]{12,})["']?)`),
			valueGroup: -1, // first non-empty submatch
			score:      0.96,
		},

		// --- International Cloud, AI & Git ---
		{
			ruleName: "ANTHROPIC_API_KEY",
			category: CategoryAIKey,
			group:    "intl",
			re:       regexp.MustCompile(`\bsk-ant-(?:api\d{2}-|admin\d{2}-)?[A-Za-z0-9_-]{20,}\b`),
			score:    0.99,
		},
		{
			ruleName: "OPENAI_API_KEY",
			category: CategoryAIKey,
			group:    "intl",
			re:       regexp.MustCompile(`\bsk-(?:proj-|svcacct-|live-|None-)?[A-Za-z0-9_-]{20,}\b`),
			score:    0.98,
		},
		{
			ruleName: "GOOGLE_API_KEY",
			category: CategoryAIKey,
			group:    "intl",
			re:       regexp.MustCompile(`\b(?:AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]{24,})\b`),
			score:    0.99,
		},
		{
			ruleName: "AWS_ACCESS_KEY_ID",
			category: CategoryCloudAK,
			group:    "intl",
			re:       regexp.MustCompile(`\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b`),
			score:    0.99,
		},
		{
			ruleName:   "AZURE_STORAGE_KEY",
			category:   CategoryCloudAK,
			group:      "intl",
			re:         regexp.MustCompile(`(?i)\bAccountKey=([A-Za-z0-9+/]{44,}={0,2})`),
			valueGroup: 1,
			score:      0.98,
		},
		{
			ruleName: "GITHUB_TOKEN",
			category: CategoryGitToken,
			group:    "intl",
			re:       regexp.MustCompile(`\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{22,})\b`),
			score:    0.99,
		},
		{
			ruleName: "GITLAB_TOKEN",
			category: CategoryGitToken,
			group:    "intl",
			re:       regexp.MustCompile(`\bgl(?:pat|rt|dt|ptt|ft|soat)-[A-Za-z0-9_-]{20,}\b`),
			score:    0.99,
		},
		{
			ruleName: "STRIPE_SECRET_KEY",
			category: CategoryCloudAK,
			group:    "intl",
			re:       regexp.MustCompile(`\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b`),
			score:    0.99,
		},
		{
			ruleName: "SLACK_TOKEN",
			category: CategoryWebhookSecret,
			group:    "intl",
			re:       regexp.MustCompile(`\b(?:xox[abposr]|xapp)-[0-9A-Za-z-]{12,}\b`),
			score:    0.99,
		},
		{
			ruleName: "SLACK_DISCORD_WEBHOOK",
			category: CategoryWebhookSecret,
			group:    "intl",
			re:       regexp.MustCompile(`https://(?:hooks\.slack\.com/services|discord(?:app)?\.com/api/webhooks)/[^\s"'<>]+`),
			score:    0.99,
		},
		{
			ruleName: "NPM_HF_SENDGRID_TOKEN",
			category: CategoryCloudAK,
			group:    "intl",
			re:       regexp.MustCompile(`\b(?:npm_[A-Za-z0-9]{36}|hf_[A-Za-z0-9]{30,}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,})\b`),
			score:    0.99,
		},

		// --- Domestic Cloud, AI & IM Webhooks ---
		{
			ruleName: "ALIYUN_ACCESS_KEY",
			category: CategoryCloudAK,
			group:    "domestic",
			re:       regexp.MustCompile(`\bLTAI[A-Za-z0-9]{12,24}\b`),
			score:    0.99,
		},
		{
			ruleName: "TENCENT_SECRET_ID",
			category: CategoryCloudAK,
			group:    "domestic",
			re:       regexp.MustCompile(`\bAKID[A-Za-z0-9]{13,40}\b`),
			score:    0.99,
		},
		{
			ruleName: "VOLCENGINE_AK",
			category: CategoryCloudAK,
			group:    "domestic",
			re:       regexp.MustCompile(`\bAKLT[A-Za-z0-9]{20,48}\b`),
			score:    0.98,
		},
		{
			ruleName: "FEISHU_BOT_WEBHOOK",
			category: CategoryWebhookSecret,
			group:    "domestic",
			re:       regexp.MustCompile(`https://open\.(?:feishu\.cn|larksuite\.com)/open-apis/bot/v2/hook/[0-9a-fA-F-]{16,}`),
			score:    0.99,
		},
		{
			ruleName:   "WECOM_BOT_WEBHOOK",
			category:   CategoryWebhookSecret,
			group:      "domestic",
			re:         regexp.MustCompile(`https://qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=([0-9a-zA-Z-]{16,})`),
			valueGroup: 0,
			score:      0.99,
		},
		{
			ruleName:   "DINGTALK_BOT_WEBHOOK",
			category:   CategoryWebhookSecret,
			group:      "domestic",
			re:         regexp.MustCompile(`https://oapi\.dingtalk\.com/robot/send\?access_token=([0-9a-fA-F]{32,})`),
			valueGroup: 0,
			score:      0.99,
		},
	}

	// Database & generic URI credential patterns (greedy userinfo up to last `@host` before path/delimiter).
	dbURIRe = regexp.MustCompile(`(?i)\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis(?:s)?|mssql|sqlserver|clickhouse)(?:\+[a-z0-9_]+)?://([^\s"'<>/]+)@([A-Za-z0-9._-]+(?::\d+)?)(?:[/\s"'<>?#]|$)`)

	genericURIPassRe = regexp.MustCompile(`(?i)\b(?:https?|ftp|amqp(?:s)?|smtp(?:s)?|ssh)://([^/\s"'<>:]+:[^/\s"'<>]{3,})@([A-Za-z0-9._-]+(?::\d+)?)(?:[/\s"'<>?#]|$)`)

	// Contextual assignments: .env, YAML, JSON, TOML, typed declarations (`db_password: str = "..."`).
	contextKeyAssignRe = regexp.MustCompile(
		`(?im)(?:^|[\s,{(\["'])` +
			`([A-Za-z0-9_.-]{0,48}?(?:password|passwd|pwd|secret[_-]?key|access[_-]?key[_-]?secret|api[_-]?key|private[_-]?key|auth[_-]?token|client[_-]?secret|signing[_-]?key|encryption[_-]?key|db[_-]?pass|secret|token)[A-Za-z0-9_.-]{0,32})` +
			`["']?\s*(?:\?[ \t]*:[ \t]*[A-Za-z0-9_\[\]|<>]+[ \t]*=|:|=)\s*` +
			`(?:"([^"\r\n]{6,256})"|'([^'\r\n]{6,256})'|([^\s,}\]"'#;]{6,256}))`,
	)

	// Environment lookup fallback literals (os.getenv / process.env / shell parameter expansion).
	envFallbackCallRe = regexp.MustCompile(
		`(?i)(?:os\.getenv|os\.environ\.get|ENV\.fetch|getOrDefault)\(\s*["']([A-Za-z0-9_]*(?:PASSWORD|PASSWD|PWD|SECRET|TOKEN|API_KEY|PRIVATE_KEY)[A-Za-z0-9_]*)["']\s*,\s*(?:default\s*=\s*)?["']([^"'\r\n]{6,256})["']`,
	)
	envFallbackOrRe = regexp.MustCompile(
		`(?i)(?:process\.env\.([A-Za-z0-9_]+)|import\.meta\.env\.([A-Za-z0-9_]+))\s*(?:\|\||\?\?)\s*["']([^"'\r\n]{6,256})["']`,
	)
	shellFallbackRe = regexp.MustCompile(
		`(?i)\$\{([A-Za-z0-9_]*(?:PASSWORD|PASSWD|PWD|SECRET|TOKEN|API_KEY|PRIVATE_KEY)[A-Za-z0-9_]*):-([^}$\s"']{6,256})\}`,
	)
	cliPasswordFlagRe = regexp.MustCompile(
		`(?i)--(?:password|api-key|secret|token)(?:=|\s+)(?:"([^"\r\n]{6,256})"|'([^'\r\n]{6,256})'|([^\s"';&|]{6,256}))`,
	)

	// False-positive exemptions (ported & adapted from GetSHIM/shim-cli).
	envReferenceRe = regexp.MustCompile(
		`^(?:\$\{[A-Za-z_][A-Za-z0-9_]*(?:[:?+=-].*)?\}|\$[A-Za-z_][A-Za-z0-9_]*|%[A-Za-z_][A-Za-z0-9_]*%|` +
			`(?:os\.Getenv|os\.LookupEnv|os\.getenv|os\.environ|process\.env|import\.meta\.env|System\.getenv|Environment\.GetEnvironmentVariable|std::env::var|env::var|viper\.GetString)\b.*)$`,
	)
	placeholderShapeRe    = regexp.MustCompile(`^(?:<[A-Za-z0-9_:-]+>|YOUR_[A-Z0-9_]+|[Xx*•.…-]{4,}|changeme|example[_-]?[a-z0-9]*|replace[_-]?me|dummy[_-]?[a-z0-9]*|test[_-]?(?:key|secret|token|password))$`)
	nonSecretKeyPrefix    = regexp.MustCompile(`(?i)^(?:category|rule|kind|type|const|err|error|header|env_?var|placeholder)[A-Z0-9_.-]`)
	nonSecretKeySuffix    = regexp.MustCompile(`(?i)(?:_?(?:id|ids|name|names|type|header|url|uri|endpoint|path|file|dir|env|ttl|timeout|expire|expires|limit|count|max|min|len|length|enabled|disabled|flag|mode|version|hash|algo|algorithm|prefix|regex|pattern|label|key_name))$`)
	screamingSnakeConstRe = regexp.MustCompile(`^[A-Z]{2,}(?:_[A-Z]{2,})+$`)
	codeExprValueRe       = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+(?:\([^)]*\))?$|^[A-Za-z_][A-Za-z0-9_]*\([^)]*\)$`)
	camelIdentifierRe     = regexp.MustCompile(`^[a-z]+(?:[A-Z][a-z0-9]+)+$`)
)

type compiledCustom struct {
	name string
	re   *regexp.Regexp
}

type Engine struct {
	mu               sync.RWMutex
	cfg              config.Config
	knownSecrets     *KnownSecretMatcher
	customs          []compiledCustom
	allowFingerprint map[string]struct{}
	allowPaths       []string
}

func NewEngine(cfg config.Config) *Engine {
	e := &Engine{
		knownSecrets: NewKnownSecretMatcher(),
	}
	e.UpdateConfig(cfg)
	return e
}

func (e *Engine) UpdateConfig(cfg config.Config) {
	var customs []compiledCustom
	for _, cp := range cfg.CustomPatterns {
		if !cp.Enabled {
			continue
		}
		expr := cp.Pattern
		if cp.IgnoreCase {
			expr = "(?i)" + expr
		}
		if re, err := regexp.Compile(expr); err == nil {
			customs = append(customs, compiledCustom{name: cp.Name, re: re})
		}
	}

	fps := make(map[string]struct{})
	var paths []string
	for _, item := range cfg.Allowlist {
		v := strings.TrimSpace(item.Value)
		if v == "" {
			continue
		}
		switch item.Kind {
		case config.AllowFingerprint:
			fps[v] = struct{}{}
		case config.AllowPath:
			paths = append(paths, v)
		}
	}

	e.mu.Lock()
	e.cfg = cfg
	e.customs = customs
	e.allowFingerprint = fps
	e.allowPaths = paths
	e.mu.Unlock()
}

func (e *Engine) SetKnownSecrets(inputs []KnownSecretInput) {
	e.knownSecrets.SetSecrets(inputs)
}

func (e *Engine) KnownSecretCount() int {
	return e.knownSecrets.Count()
}

func (e *Engine) IsPathAllowed(filePath string) bool {
	if filePath == "" {
		return false
	}
	e.mu.RLock()
	paths := e.allowPaths
	e.mu.RUnlock()

	clean := filepath.ToSlash(filePath)
	for _, pat := range paths {
		p := filepath.ToSlash(pat)
		if clean == p || strings.HasSuffix(clean, "/"+p) || strings.Contains(clean, p) {
			return true
		}
		if matched, _ := filepath.Match(p, filepath.Base(clean)); matched {
			return true
		}
	}
	return false
}

func (e *Engine) Analyze(raw string, opts ScanOptions) []Finding {
	if len(raw) == 0 {
		return nil
	}
	if opts.FilePath != "" && e.IsPathAllowed(opts.FilePath) {
		return nil
	}

	e.mu.RLock()
	cfg := e.cfg
	customs := e.customs
	allowFP := e.allowFingerprint
	e.mu.RUnlock()

	var findings []Finding

	// 1. Exact Known Secrets from DeskSide EnvManager (on original bytes).
	if cfg.SyncEnvSecrets && cfg.RuleGroups.KnownEnvSecrets {
		findings = append(findings, e.knownSecrets.Scan(raw)...)
	}

	// Normalize invisible chars & %xx escapes while preserving byte mapping.
	norm := normalizeText(raw)
	findings = append(findings, scanNormalized(raw, norm, cfg, customs, true)...)

	// Deduplicate & resolve overlapping findings.
	resolved := deduplicateFindings(findings)

	// Filter out fingerprinted allowlist items & synthetic placeholders (<SECRET_1>).
	if len(resolved) == 0 {
		return nil
	}
	kept := resolved[:0]
	for _, f := range resolved {
		if f.Start < 0 || f.End > len(raw) || f.Start >= f.End {
			continue
		}
		val := raw[f.Start:f.End]
		if isGuardPlaceholder(val) {
			continue
		}
		if _, allowed := allowFP[f.Fingerprint]; allowed {
			continue
		}
		kept = append(kept, f)
	}
	return kept
}

func scanNormalized(raw string, norm normalizedView, cfg config.Config, customs []compiledCustom, checkBase64 bool) []Finding {
	text := norm.text
	var out []Finding

	emit := func(cat, rule string, normStart, normEnd int, score float64) {
		origStart, origEnd := norm.mapSpan(normStart, normEnd)
		if origStart >= origEnd || origStart < 0 || origEnd > len(raw) {
			return
		}
		rawSlice := raw[origStart:origEnd]
		out = append(out, Finding{
			Category:      cat,
			RuleName:      rule,
			Start:         origStart,
			End:           origEnd,
			Score:         score,
			MaskedPreview: MaskValue(rawSlice),
			Fingerprint:   FingerprintValue(rawSlice),
		})
	}

	// Layer 2A: High-confidence vendor rules.
	for _, r := range compiledRules {
		switch r.group {
		case "intl":
			if !cfg.RuleGroups.InternationalCloudAndAI {
				continue
			}
		case "domestic":
			if !cfg.RuleGroups.DomesticCloudAndIM {
				continue
			}
		case "priv":
			if !cfg.RuleGroups.PrivateKeysAndAuth {
				continue
			}
		}

		matches := r.re.FindAllStringSubmatchIndex(text, -1)
		for _, loc := range matches {
			s, e := loc[0], loc[1]
			if r.valueGroup > 0 && r.valueGroup*2+1 < len(loc) {
				s, e = loc[r.valueGroup*2], loc[r.valueGroup*2+1]
			} else if r.valueGroup == -1 {
				for g := 2; g+1 < len(loc); g += 2 {
					if loc[g] >= 0 && loc[g+1] > loc[g] {
						s, e = loc[g], loc[g+1]
						break
					}
				}
			}
			if s < 0 || e <= s {
				continue
			}
			e = trimTrailingProse(text, s, e)
			if s < e && !isPlaceholderOrReference(text[s:e]) {
				emit(r.category, r.ruleName, s, e, r.score)
			}
		}
	}

	// Layer 2B: Database URIs (mask only userinfo, preserving host:port/db!).
	var dbSpans [][2]int
	if cfg.RuleGroups.DatabaseURIs {
		for _, loc := range dbURIRe.FindAllStringSubmatchIndex(text, -1) {
			uStart, uEnd := loc[2], loc[3]
			if uStart >= 0 && uEnd > uStart {
				userInfo := text[uStart:uEnd]
				dbSpans = append(dbSpans, [2]int{loc[0], loc[1]})
				// Require non-placeholder password or long token userinfo.
				if !isPlaceholderUserInfo(userInfo) {
					emit(CategoryDBURI, "DATABASE_URI_CREDENTIALS", uStart, uEnd, 0.99)
				}
			}
		}
		for _, loc := range genericURIPassRe.FindAllStringSubmatchIndex(text, -1) {
			if overlapsAny(loc[0], loc[1], dbSpans) {
				continue
			}
			uStart, uEnd := loc[2], loc[3]
			host := text[loc[4]:loc[5]]
			// Skip git@github.com:org/repo.git (no ://) and sha256 image digests.
			if strings.HasPrefix(strings.ToLower(host), "sha256:") {
				continue
			}
			userInfo := text[uStart:uEnd]
			if _, pass, ok := strings.Cut(userInfo, ":"); ok && !isPlaceholderOrReference(pass) {
				emit(CategoryDBURI, "URI_EMBEDDED_PASSWORD", uStart, uEnd, 0.98)
			}
		}
	}

	// Layer 3: Contextual assignments & env fallback defaults.
	if cfg.RuleGroups.ContextualAssignments {
		for _, loc := range contextKeyAssignRe.FindAllStringSubmatchIndex(text, -1) {
			key := text[loc[2]:loc[3]]
			var valStart, valEnd int
			quoted := false
			switch {
			case loc[4] >= 0:
				valStart, valEnd, quoted = loc[4], loc[5], true
			case loc[6] >= 0:
				valStart, valEnd, quoted = loc[6], loc[7], true
			case loc[8] >= 0:
				valStart, valEnd, quoted = loc[8], loc[9], false
			default:
				continue
			}
			if !quoted {
				valEnd = trimUnquotedValueEnd(text, valStart, valEnd)
			}
			if valEnd-valStart < 6 {
				continue
			}
			val := text[valStart:valEnd]
			if shouldExemptContextAssignment(key, val, quoted) {
				continue
			}
			emit(CategoryContextSecret, "CONTEXT_KEY_SECRET", valStart, valEnd, 0.92)
		}

		for _, loc := range envFallbackCallRe.FindAllStringSubmatchIndex(text, -1) {
			key := text[loc[2]:loc[3]]
			valStart, valEnd := loc[4], loc[5]
			val := text[valStart:valEnd]
			if !shouldExemptContextAssignment(key, val, true) {
				emit(CategoryContextSecret, "ENV_FALLBACK_SECRET", valStart, valEnd, 0.95)
			}
		}

		for _, loc := range envFallbackOrRe.FindAllStringSubmatchIndex(text, -1) {
			key := ""
			if loc[2] >= 0 {
				key = text[loc[2]:loc[3]]
			} else if loc[4] >= 0 {
				key = text[loc[4]:loc[5]]
			}
			if !containsSecretCue(key) {
				continue
			}
			valStart, valEnd := loc[6], loc[7]
			val := text[valStart:valEnd]
			if !shouldExemptContextAssignment(key, val, true) {
				emit(CategoryContextSecret, "ENV_FALLBACK_SECRET", valStart, valEnd, 0.95)
			}
		}

		for _, loc := range shellFallbackRe.FindAllStringSubmatchIndex(text, -1) {
			key := text[loc[2]:loc[3]]
			valStart, valEnd := loc[4], loc[5]
			val := text[valStart:valEnd]
			if !shouldExemptContextAssignment(key, val, false) {
				emit(CategoryContextSecret, "SHELL_FALLBACK_SECRET", valStart, valEnd, 0.95)
			}
		}

		for _, loc := range cliPasswordFlagRe.FindAllStringSubmatchIndex(text, -1) {
			var valStart, valEnd int
			quoted := false
			switch {
			case loc[2] >= 0:
				valStart, valEnd, quoted = loc[2], loc[3], true
			case loc[4] >= 0:
				valStart, valEnd, quoted = loc[4], loc[5], true
			case loc[6] >= 0:
				valStart, valEnd, quoted = loc[6], loc[7], false
			default:
				continue
			}
			val := text[valStart:valEnd]
			if !shouldExemptContextAssignment("password", val, quoted) {
				emit(CategoryContextSecret, "CLI_FLAG_SECRET", valStart, valEnd, 0.95)
			}
		}

		// Multi-line & single-line Base64 unwrapping (1 level recursion).
		if checkBase64 {
			for _, cand := range extractBase64Blocks(text) {
				innerNorm := normalizedView{text: cand.decoded}
				innerFindings := scanNormalized(cand.decoded, innerNorm, cfg, customs, false)
				if len(innerFindings) > 0 {
					emit(CategoryContextSecret, "ENCODED_BASE64_"+innerFindings[0].RuleName, cand.origStart, cand.origEnd, 0.96)
				}
			}
		}
	}

	// Layer 4: User Custom Regexes (Go RE2 -> O(N) linear time guaranteed).
	for _, cp := range customs {
		for _, loc := range cp.re.FindAllStringIndex(text, -1) {
			if loc[1] > loc[0] {
				emit(CategoryCustom, "CUSTOM:"+cp.name, loc[0], loc[1], 0.90)
			}
		}
	}

	return out
}

func containsSecretCue(key string) bool {
	lower := strings.ToLower(key)
	for _, cue := range []string{"password", "passwd", "pwd", "secret", "token", "api_key", "apikey", "private_key", "access_key"} {
		if strings.Contains(lower, cue) {
			return true
		}
	}
	return false
}

func shouldExemptContextAssignment(key, val string, quoted bool) bool {
	trimmed := strings.TrimSpace(val)
	if len(trimmed) < 6 {
		return true
	}
	if nonSecretKeyPrefix.MatchString(key) || nonSecretKeySuffix.MatchString(key) {
		return true
	}
	if screamingSnakeConstRe.MatchString(trimmed) {
		return true
	}
	if isPlaceholderOrReference(trimmed) {
		return true
	}
	lowerVal := strings.ToLower(trimmed)
	if lowerVal == "true" || lowerVal == "false" || lowerVal == "null" || lowerVal == "none" || lowerVal == "undefined" {
		return true
	}
	if strings.HasPrefix(lowerVal, "http://") || strings.HasPrefix(lowerVal, "https://") {
		// Plain URL without userinfo is an endpoint, not a secret (webhooks & userinfo URLs are caught by dedicated rules).
		return true
	}
	if strings.HasPrefix(trimmed, "/") || strings.HasPrefix(trimmed, "./") || strings.HasPrefix(trimmed, "~/") {
		return true
	}
	// Exempt string interpolations & dynamic concatenation fragments (Swift `\(x)`, JS `${x}`, Go `"+x+"`).
	if strings.Contains(trimmed, `\(`) || strings.Contains(trimmed, "${") ||
		strings.HasPrefix(trimmed, "+") || strings.HasSuffix(trimmed, "+") {
		return true
	}
	if !quoted {
		// Unquoted code identifier or call/member syntax: `password = password`, `token: rec.foo.split(`, `struct SecretInput: Codable`.
		cleanIdent := strings.Trim(trimmed, ";,).`")
		if isPureASCIILetters(cleanIdent) {
			return true
		}
		if strings.ContainsAny(trimmed, "()[]{}") || strings.Contains(trimmed, "=>") || strings.Contains(trimmed, "?.") {
			return true
		}
		if codeExprValueRe.MatchString(cleanIdent) {
			return true
		}
		if strings.EqualFold(cleanIdent, key) || camelIdentifierRe.MatchString(cleanIdent) {
			return true
		}
		// Unquoted pure digits for non-password keys (e.g. `MAX_TOKENS=128000`, `TOKEN_TTL=864000`).
		lowerKey := strings.ToLower(key)
		isPasswordKey := strings.Contains(lowerKey, "pass") || strings.Contains(lowerKey, "pwd")
		if !isPasswordKey && isAllDigits(cleanIdent) {
			return true
		}
	}
	return false
}

func isPlaceholderUserInfo(userInfo string) bool {
	u := strings.TrimSpace(userInfo)
	if u == "" || strings.HasPrefix(u, "<DB_URI_") || isPlaceholderOrReference(u) {
		return true
	}
	user, pass, hasColon := strings.Cut(u, ":")
	if !hasColon {
		// Passwordless `postgres://postgres@localhost/db` is not a secret unless userinfo itself is a long token.
		return len(u) < 20
	}
	p := strings.TrimSpace(pass)
	if p == "" || isPlaceholderOrReference(p) {
		return true
	}
	lp := strings.ToLower(p)
	lu := strings.ToLower(strings.TrimSpace(user))
	if (lu == "user" || lu == "username" || lu == "dbuser") && (lp == "pass" || lp == "password" || lp == "pwd") {
		return true
	}
	return false
}

func isPlaceholderOrReference(val string) bool {
	v := strings.TrimSpace(val)
	if v == "" {
		return true
	}
	if isGuardPlaceholder(v) {
		return true
	}
	if envReferenceRe.MatchString(v) {
		return true
	}
	if placeholderShapeRe.MatchString(v) {
		return true
	}
	return false
}

var guardPlaceholderRe = regexp.MustCompile(`^<(?:SECRET|DB_URI|PRIVATE_KEY|CUSTOM)_\d+>$`)

func isGuardPlaceholder(v string) bool {
	return guardPlaceholderRe.MatchString(strings.TrimSpace(v))
}

func isAllDigits(s string) bool {
	if len(s) == 0 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func isPureASCIILetters(s string) bool {
	if len(s) == 0 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') {
			return false
		}
	}
	return true
}

func trimTrailingProse(text string, start, end int) int {
	for end > start {
		switch text[end-1] {
		case '.', ',', ';', ':', '!', '?', ')', ']', '}', '>':
			end--
		default:
			return end
		}
	}
	return end
}

func trimUnquotedValueEnd(text string, start, end int) int {
	for end > start {
		switch text[end-1] {
		case ';', ',', ')', ']', '}', '`':
			end--
		default:
			return end
		}
	}
	return end
}

func overlapsAny(start, end int, spans [][2]int) bool {
	for _, sp := range spans {
		if start < sp[1] && sp[0] < end {
			return true
		}
	}
	return false
}

func deduplicateFindings(items []Finding) []Finding {
	if len(items) <= 1 {
		return items
	}
	// Sort by highest score first, then earliest start, then longest span.
	sort.SliceStable(items, func(i, j int) bool {
		if items[i].Score != items[j].Score {
			return items[i].Score > items[j].Score
		}
		if items[i].Start != items[j].Start {
			return items[i].Start < items[j].Start
		}
		return (items[i].End - items[i].Start) > (items[j].End - items[j].Start)
	})

	var selected []Finding
	for _, cand := range items {
		conflict := false
		for _, existing := range selected {
			if cand.Start < existing.End && existing.Start < cand.End {
				conflict = true
				break
			}
		}
		if !conflict {
			selected = append(selected, cand)
		}
	}

	// Return ordered by ascending byte offset for deterministic single-pass replacement.
	sort.Slice(selected, func(i, j int) bool {
		return selected[i].Start < selected[j].Start
	})
	return selected
}
