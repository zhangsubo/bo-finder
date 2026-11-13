package audit

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	maxMemoryEvents = 500
	maxLogFileBytes = 2 * 1024 * 1024 // 2 MB auto-rotate
)

// Event represents a strictly zero-plaintext security audit record.
type Event struct {
	ID            string    `json:"id"`
	Timestamp     time.Time `json:"timestamp"`
	Channel       string    `json:"channel"`       // "llm" | "github" | "git" | "self-test"
	Action        string    `json:"action"`        // "masked" | "blocked"
	Target        string    `json:"target"`        // domain or git remote
	Client        string    `json:"client"`        // e.g. "Claude Code", "Codex", "Git Push"
	Category      string    `json:"category"`      // e.g. "ENV_SECRET", "CLOUD_AK"
	RuleName      string    `json:"ruleName"`      // e.g. "ENV:OPENAI_API_KEY", "ALIYUN_ACCESS_KEY"
	MaskedPreview string    `json:"maskedPreview"` // e.g. "LTAI5t****8f2a" (NEVER plaintext)
	Fingerprint   string    `json:"fingerprint"`   // e.g. "sha256:9a1b2c3d4e5f"
	Location      string    `json:"location"`      // JSON field or commit:file:line
	Count         int       `json:"count"`
}

type DailyStats struct {
	Date            string `json:"date"`
	ScannedRequests int    `json:"scannedRequests"`
	MaskedCount     int    `json:"maskedCount"`
	BlockedCount    int    `json:"blockedCount"`
	GitScans        int    `json:"gitScans"`
	GitBlockedCount int    `json:"gitBlockedCount"`
}

type Ledger struct {
	mu          sync.RWMutex
	filePath    string
	events      []Event
	stats       DailyStats
	subscribers map[chan Event]struct{}
}

func NewLedger(stateDir string) (*Ledger, error) {
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return nil, err
	}
	l := &Ledger{
		filePath:    filepath.Join(stateDir, "audit.jsonl"),
		events:      make([]Event, 0, 128),
		stats:       DailyStats{Date: todayKey()},
		subscribers: make(map[chan Event]struct{}),
	}
	l.loadExisting()
	return l, nil
}

func todayKey() string {
	return time.Now().Format("2006-01-02")
}

func newEventID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func (l *Ledger) ensureTodayLocked() {
	today := todayKey()
	if l.stats.Date != today {
		l.stats = DailyStats{Date: today}
	}
}

func (l *Ledger) RecordScan(channel string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.ensureTodayLocked()
	if channel == "git" {
		l.stats.GitScans++
	} else {
		l.stats.ScannedRequests++
	}
}

func (l *Ledger) Record(ev Event) Event {
	if ev.ID == "" {
		ev.ID = newEventID()
	}
	if ev.Timestamp.IsZero() {
		ev.Timestamp = time.Now()
	}
	if ev.Count <= 0 {
		ev.Count = 1
	}

	l.mu.Lock()
	l.ensureTodayLocked()
	switch ev.Action {
	case "masked":
		l.stats.MaskedCount += ev.Count
	case "blocked":
		l.stats.BlockedCount += ev.Count
		if ev.Channel == "git" {
			l.stats.GitBlockedCount += ev.Count
		}
	}

	l.events = append(l.events, ev)
	if len(l.events) > maxMemoryEvents {
		l.events = append([]Event(nil), l.events[len(l.events)-maxMemoryEvents:]...)
	}
	_ = l.appendDiskLocked(ev)

	subs := make([]chan Event, 0, len(l.subscribers))
	for ch := range l.subscribers {
		subs = append(subs, ch)
	}
	l.mu.Unlock()

	for _, ch := range subs {
		select {
		case ch <- ev:
		default:
			// Non-blocking drop if slow UI subscriber falls behind.
		}
	}
	return ev
}

func (l *Ledger) ListRecent(limit int) []Event {
	l.mu.RLock()
	defer l.mu.RUnlock()
	n := len(l.events)
	if limit <= 0 || limit > n {
		limit = n
	}
	// Return newest first for UI timeline.
	out := make([]Event, 0, limit)
	for i := n - 1; i >= n-limit; i-- {
		out = append(out, l.events[i])
	}
	return out
}

func (l *Ledger) Stats() DailyStats {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.ensureTodayLocked()
	return l.stats
}

func (l *Ledger) Clear() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.events = nil
	l.stats = DailyStats{Date: todayKey()}
	_ = os.Remove(l.filePath)
	_ = os.Remove(l.filePath + ".1")
	return nil
}

func (l *Ledger) Subscribe() (chan Event, func()) {
	ch := make(chan Event, 32)
	l.mu.Lock()
	l.subscribers[ch] = struct{}{}
	l.mu.Unlock()

	cancel := func() {
		l.mu.Lock()
		if _, ok := l.subscribers[ch]; ok {
			delete(l.subscribers, ch)
			close(ch)
		}
		l.mu.Unlock()
	}
	return ch, cancel
}

func (l *Ledger) loadExisting() {
	f, err := os.Open(l.filePath)
	if err != nil {
		return
	}
	defer f.Close()

	today := todayKey()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 512*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var ev Event
		if err := json.Unmarshal(line, &ev); err != nil {
			continue
		}
		l.events = append(l.events, ev)
		if ev.Timestamp.Format("2006-01-02") == today {
			switch ev.Action {
			case "masked":
				l.stats.MaskedCount += ev.Count
			case "blocked":
				l.stats.BlockedCount += ev.Count
				if ev.Channel == "git" {
					l.stats.GitBlockedCount += ev.Count
				}
			}
		}
	}
	if len(l.events) > maxMemoryEvents {
		l.events = append([]Event(nil), l.events[len(l.events)-maxMemoryEvents:]...)
	}
}

func (l *Ledger) appendDiskLocked(ev Event) error {
	if info, err := os.Stat(l.filePath); err == nil && info.Size() >= maxLogFileBytes {
		_ = os.Rename(l.filePath, l.filePath+".1")
	}
	f, err := os.OpenFile(l.filePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_ = f.Chmod(0o600)

	raw, err := json.Marshal(ev)
	if err != nil {
		return err
	}
	_, err = f.Write(append(raw, '\n'))
	return err
}
