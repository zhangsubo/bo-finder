package config

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	ActionMask  = "mask"
	ActionBlock = "block"

	AllowFingerprint = "fingerprint"
	AllowPath        = "path"
)

type RuleGroups struct {
	KnownEnvSecrets         bool `json:"knownEnvSecrets"`
	DomesticCloudAndIM      bool `json:"domesticCloudAndIM"`
	InternationalCloudAndAI bool `json:"internationalCloudAndAI"`
	PrivateKeysAndAuth      bool `json:"privateKeysAndAuth"`
	DatabaseURIs            bool `json:"databaseURIs"`
	ContextualAssignments   bool `json:"contextualAssignments"`
}

type CustomPattern struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Pattern    string `json:"pattern"`
	IgnoreCase bool   `json:"ignoreCase"`
	Enabled    bool   `json:"enabled"`
}

type AllowlistEntry struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"` // "fingerprint" | "path"
	Value     string    `json:"value"`
	Note      string    `json:"note"`
	CreatedAt time.Time `json:"createdAt"`
}

type Config struct {
	ListenAddr       string           `json:"listenAddr"`
	DefaultLLMAction string           `json:"defaultLLMAction"` // "mask" (default) | "block"
	SyncEnvSecrets   bool             `json:"syncEnvSecrets"`
	ProtectedDomains []string         `json:"protectedDomains"`
	UpstreamProxyURL string           `json:"upstreamProxyURL"`
	RuleGroups       RuleGroups       `json:"ruleGroups"`
	CustomPatterns   []CustomPattern  `json:"customPatterns"`
	Allowlist        []AllowlistEntry `json:"allowlist"`
}

func DefaultProtectedDomains() []string {
	return []string{
		"api.anthropic.com",
		"api.openai.com",
		"chatgpt.com",
		"generativelanguage.googleapis.com",
		"api.deepseek.com",
		"openrouter.ai",
		"api.moonshot.cn",
		"open.bigmodel.cn",
		"dashscope.aliyuncs.com",
		"api.siliconflow.cn",
		"api.github.com",
		"github.com",
	}
}

func Default() Config {
	return Config{
		ListenAddr:       "127.0.0.1:19840",
		DefaultLLMAction: ActionMask,
		SyncEnvSecrets:   true,
		ProtectedDomains: DefaultProtectedDomains(),
		UpstreamProxyURL: "",
		RuleGroups: RuleGroups{
			KnownEnvSecrets:         true,
			DomesticCloudAndIM:      true,
			InternationalCloudAndAI: true,
			PrivateKeysAndAuth:      true,
			DatabaseURIs:            true,
			ContextualAssignments:   true,
		},
		CustomPatterns: []CustomPattern{},
		Allowlist:      []AllowlistEntry{},
	}
}

var customNameRe = regexp.MustCompile(`^[A-Z0-9_]{2,40}$`)

func Validate(cfg *Config) error {
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = "127.0.0.1:19840"
	}
	if cfg.DefaultLLMAction != ActionMask && cfg.DefaultLLMAction != ActionBlock {
		return fmt.Errorf("invalid defaultLLMAction %q: must be 'mask' or 'block'", cfg.DefaultLLMAction)
	}
	if len(cfg.CustomPatterns) > 64 {
		return errors.New("too many custom patterns (max 64)")
	}
	seen := make(map[string]struct{}, len(cfg.CustomPatterns))
	for i := range cfg.CustomPatterns {
		cp := &cfg.CustomPatterns[i]
		cp.Name = strings.ToUpper(strings.TrimSpace(cp.Name))
		if !customNameRe.MatchString(cp.Name) {
			return fmt.Errorf("custom pattern name %q must be 2-40 uppercase letters, digits, or underscores", cp.Name)
		}
		if _, dup := seen[cp.Name]; dup {
			return fmt.Errorf("duplicate custom pattern name %q", cp.Name)
		}
		seen[cp.Name] = struct{}{}
		if strings.TrimSpace(cp.Pattern) == "" {
			return fmt.Errorf("custom pattern %q cannot be empty", cp.Name)
		}
		expr := cp.Pattern
		if cp.IgnoreCase {
			expr = "(?i)" + expr
		}
		if _, err := regexp.Compile(expr); err != nil {
			return fmt.Errorf("custom pattern %q invalid regex: %w", cp.Name, err)
		}
		if cp.ID == "" {
			cp.ID = cp.Name
		}
	}

	cleanedDomains := make([]string, 0, len(cfg.ProtectedDomains))
	seenDom := make(map[string]struct{})
	for _, d := range cfg.ProtectedDomains {
		d = strings.ToLower(strings.TrimSpace(d))
		d = strings.TrimPrefix(d, "https://")
		d = strings.TrimPrefix(d, "http://")
		d = strings.TrimSuffix(d, "/")
		if d == "" {
			continue
		}
		if _, ok := seenDom[d]; !ok {
			seenDom[d] = struct{}{}
			cleanedDomains = append(cleanedDomains, d)
		}
	}
	if len(cleanedDomains) == 0 {
		cleanedDomains = DefaultProtectedDomains()
	}
	cfg.ProtectedDomains = cleanedDomains

	if cfg.CustomPatterns == nil {
		cfg.CustomPatterns = []CustomPattern{}
	}
	if cfg.Allowlist == nil {
		cfg.Allowlist = []AllowlistEntry{}
	}
	return nil
}

type Store struct {
	mu       sync.RWMutex
	stateDir string
	filePath string
	cfg      Config
	onChange func(Config)
}

func DefaultStateDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ".deskside-guard"
	}
	return filepath.Join(home, ".config", "deskside-guard")
}

// AdminSocketPath returns the Unix domain socket path for stateDir, falling back to a short
// user-scoped /tmp socket path if stateDir exceeds macOS's 104-byte sun_path kernel limit.
func AdminSocketPath(stateDir string) string {
	if stateDir == "" {
		stateDir = DefaultStateDir()
	}
	direct := filepath.Join(stateDir, "admin.sock")
	if len(direct) <= 96 {
		return direct
	}
	sum := sha256.Sum256([]byte(filepath.Clean(stateDir)))
	return fmt.Sprintf("/tmp/dg-%d-%s.sock", os.Getuid(), hex.EncodeToString(sum[:6]))
}

func NewStore(stateDir string, onChange func(Config)) (*Store, error) {
	if stateDir == "" {
		stateDir = DefaultStateDir()
	}
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return nil, fmt.Errorf("create state dir: %w", err)
	}
	_ = os.Chmod(stateDir, 0o700)

	s := &Store{
		stateDir: stateDir,
		filePath: filepath.Join(stateDir, "config.json"),
		cfg:      Default(),
		onChange: onChange,
	}

	if data, err := os.ReadFile(s.filePath); err == nil && len(data) > 0 {
		loaded := Default()
		if jsonErr := json.Unmarshal(data, &loaded); jsonErr == nil {
			if valErr := Validate(&loaded); valErr == nil {
				s.cfg = loaded
			}
		}
	} else {
		_ = s.saveLocked()
	}
	return s, nil
}

func (s *Store) StateDir() string {
	return s.stateDir
}

func (s *Store) Get() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return cloneConfig(s.cfg)
}

func (s *Store) Update(next Config) error {
	if err := Validate(&next); err != nil {
		return err
	}
	s.mu.Lock()
	s.cfg = cloneConfig(next)
	err := s.saveLocked()
	cb := s.onChange
	snap := cloneConfig(s.cfg)
	s.mu.Unlock()

	if err != nil {
		return err
	}
	if cb != nil {
		cb(snap)
	}
	return nil
}

func (s *Store) saveLocked() error {
	data, err := json.MarshalIndent(s.cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.filePath + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.filePath)
}

func cloneConfig(c Config) Config {
	out := c
	out.ProtectedDomains = append([]string(nil), c.ProtectedDomains...)
	out.CustomPatterns = append([]CustomPattern(nil), c.CustomPatterns...)
	out.Allowlist = append([]AllowlistEntry(nil), c.Allowlist...)
	return out
}
