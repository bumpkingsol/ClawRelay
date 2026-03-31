# WhatsApp Message Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture WhatsApp messages from whitelisted contacts/groups via the whatsmeow protocol and integrate them into ClawRelay's capture-ship-digest pipeline.

**Architecture:** A Go binary (`claw-whatsapp`) wraps the whatsmeow library to connect as a linked WhatsApp Web device. It syncs messages in real-time, filters by a whitelist in `privacy-rules.json`, and writes matching messages to a JSONL buffer. The existing daemon reads this buffer every 2 minutes and ships it to the server, where the digest processor includes a new WhatsApp section.

**Tech Stack:** Go (whatsmeow), Bash (daemon integration), Python 3 (server), Swift (menu bar UI)

**Spec:** `docs/superpowers/specs/2026-03-30-whatsapp-capture-design.md`

---

## File Structure

### New Files
```
mac-daemon/claw-whatsapp/
  go.mod                          # Go module definition
  go.sum                          # Dependency checksums
  main.go                         # Entry point, flag parsing, mode dispatch
  auth.go                         # QR code pairing flow
  sync.go                         # Message event handler, main sync loop
  whitelist.go                    # Whitelist loading, JID matching, SIGHUP reload
  whitelist_test.go               # Tests for whitelist logic
  buffer.go                       # JSONL buffer writer with file rotation safety
  buffer_test.go                  # Tests for buffer writing
  health.go                       # Health file writer
  health_test.go                  # Tests for health reporting
  pause.go                        # Pause/sensitive mode checking
  pause_test.go                   # Tests for pause/sensitive mode
  setup.go                        # Interactive whitelist population
  message.go                      # Message struct and extraction from whatsmeow events
  message_test.go                 # Tests for message extraction
mac-daemon/com.openclaw.context-bridge-whatsapp.plist  # launchd service config
```

### Modified Files
```
mac-daemon/context-daemon.sh      # Add buffer read + atomic rotation (~lines 533-555)
mac-daemon/context-helperctl.sh   # Add whatsappLaunchdState, restart-whatsapp
mac-daemon/install.sh             # Add claw-whatsapp build + plist install step
server/context-receiver.py        # Accept whatsapp_messages in sanitizer + INSERT
server/context-digest.py          # New WhatsApp Messages section in digest output
```

---

## Task 1: Go Module Scaffold + Whitelist Logic

**Files:**
- Create: `mac-daemon/claw-whatsapp/go.mod`
- Create: `mac-daemon/claw-whatsapp/whitelist.go`
- Create: `mac-daemon/claw-whatsapp/whitelist_test.go`

This task builds the whitelist matching engine — the core filtering logic that everything else depends on.

- [ ] **Step 1: Initialize Go module**

```bash
cd mac-daemon/claw-whatsapp
go mod init github.com/bumpkingsol/openclaw-computer-vision/claw-whatsapp
```

- [ ] **Step 2: Write failing tests for whitelist loading and JID matching**

Create `whitelist_test.go`:
```go
package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadWhitelist_ParsesContacts(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "privacy-rules.json")
	os.WriteFile(path, []byte(`{
		"whatsapp_whitelist": {
			"mode": "whitelist",
			"contacts": [
				{"id": "+34612345678", "label": "Nil Porras"},
				{"id": "group:120363012345678901@g.us", "label": "Team Chat"}
			]
		}
	}`), 0600)

	wl, err := LoadWhitelist(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(wl.Contacts) != 2 {
		t.Fatalf("expected 2 contacts, got %d", len(wl.Contacts))
	}
}

func TestLoadWhitelist_EmptyFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "privacy-rules.json")
	os.WriteFile(path, []byte(`{}`), 0600)

	wl, err := LoadWhitelist(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(wl.Contacts) != 0 {
		t.Fatalf("expected 0 contacts, got %d", len(wl.Contacts))
	}
}

func TestLoadWhitelist_MissingFile(t *testing.T) {
	_, err := LoadWhitelist("/nonexistent/privacy-rules.json")
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestWhitelist_MatchPhone(t *testing.T) {
	wl := &Whitelist{
		Contacts: []WhitelistContact{
			{ID: "+34612345678", Label: "Nil Porras"},
		},
	}
	// whatsmeow JID format: 34612345678@s.whatsapp.net
	if !wl.IsAllowed("34612345678@s.whatsapp.net") {
		t.Error("expected phone JID to match")
	}
	if wl.IsAllowed("99999999999@s.whatsapp.net") {
		t.Error("expected non-whitelisted JID to not match")
	}
}

func TestWhitelist_MatchGroup(t *testing.T) {
	wl := &Whitelist{
		Contacts: []WhitelistContact{
			{ID: "group:120363012345678901@g.us", Label: "Team Chat"},
		},
	}
	if !wl.IsAllowed("120363012345678901@g.us") {
		t.Error("expected group JID to match")
	}
	if wl.IsAllowed("999999999999999999@g.us") {
		t.Error("expected non-whitelisted group to not match")
	}
}

func TestWhitelist_EmptyDisallowsAll(t *testing.T) {
	wl := &Whitelist{Contacts: []WhitelistContact{}}
	if wl.IsAllowed("34612345678@s.whatsapp.net") {
		t.Error("empty whitelist should disallow all")
	}
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd mac-daemon/claw-whatsapp
go test -v -run TestLoadWhitelist
go test -v -run TestWhitelist_Match
```

Expected: compilation errors (types not defined)

- [ ] **Step 4: Implement whitelist.go**

```go
package main

import (
	"encoding/json"
	"os"
	"strings"
	"sync"
)

type WhitelistContact struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

type Whitelist struct {
	Contacts []WhitelistContact
	mu       sync.RWMutex
	jidMap   map[string]string // JID -> label for fast lookup
}

type privacyRules struct {
	WhatsAppWhitelist struct {
		Mode     string             `json:"mode"`
		Contacts []WhitelistContact `json:"contacts"`
	} `json:"whatsapp_whitelist"`
}

// LoadWhitelist reads privacy-rules.json and extracts the WhatsApp whitelist.
func LoadWhitelist(path string) (*Whitelist, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var rules privacyRules
	if err := json.Unmarshal(data, &rules); err != nil {
		return nil, err
	}
	wl := &Whitelist{
		Contacts: rules.WhatsAppWhitelist.Contacts,
		jidMap:   make(map[string]string),
	}
	for _, c := range wl.Contacts {
		jid := contactIDToJID(c.ID)
		wl.jidMap[jid] = c.Label
	}
	return wl, nil
}

// Reload re-reads the whitelist from disk (called on SIGHUP).
func (wl *Whitelist) Reload(path string) error {
	newWL, err := LoadWhitelist(path)
	if err != nil {
		return err
	}
	wl.mu.Lock()
	defer wl.mu.Unlock()
	wl.Contacts = newWL.Contacts
	wl.jidMap = newWL.jidMap
	return nil
}

// IsAllowed checks if a JID (e.g. "34612345678@s.whatsapp.net") is whitelisted.
func (wl *Whitelist) IsAllowed(jid string) bool {
	wl.mu.RLock()
	defer wl.mu.RUnlock()
	_, ok := wl.jidMap[jid]
	return ok
}

// LabelFor returns the human-readable label for a JID, or empty string.
func (wl *Whitelist) LabelFor(jid string) string {
	wl.mu.RLock()
	defer wl.mu.RUnlock()
	return wl.jidMap[jid]
}

// contactIDToJID converts a whitelist ID to a whatsmeow JID string.
// "+34612345678" -> "34612345678@s.whatsapp.net"
// "group:120363...@g.us" -> "120363...@g.us"
func contactIDToJID(id string) string {
	if strings.HasPrefix(id, "group:") {
		return strings.TrimPrefix(id, "group:")
	}
	// Strip leading + and add @s.whatsapp.net
	phone := strings.TrimPrefix(id, "+")
	return phone + "@s.whatsapp.net"
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd mac-daemon/claw-whatsapp
go test -v ./...
```

Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add mac-daemon/claw-whatsapp/go.mod mac-daemon/claw-whatsapp/whitelist.go mac-daemon/claw-whatsapp/whitelist_test.go
git commit -m "feat(claw-whatsapp): scaffold Go module with whitelist matching logic"
```

---

## Task 2: Message Struct + Buffer Writer

**Files:**
- Create: `mac-daemon/claw-whatsapp/message.go`
- Create: `mac-daemon/claw-whatsapp/message_test.go`
- Create: `mac-daemon/claw-whatsapp/buffer.go`
- Create: `mac-daemon/claw-whatsapp/buffer_test.go`

- [ ] **Step 1: Write failing tests for message struct and buffer writing**

Create `message_test.go`:
```go
package main

import (
	"encoding/json"
	"testing"
)

func TestMessage_JSONRoundTrip(t *testing.T) {
	msg := Message{
		ChatID:    "34612345678@s.whatsapp.net",
		ChatLabel: "Nil Porras",
		Sender:    "Nil",
		SenderJID: "34612345678@s.whatsapp.net",
		Text:      "Let's push the demo to Friday",
		Timestamp: "2026-03-30T14:32:00Z",
		Type:      "text",
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal error: %v", err)
	}
	var decoded Message
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}
	if decoded.ChatID != msg.ChatID || decoded.Text != msg.Text {
		t.Errorf("roundtrip mismatch: got %+v", decoded)
	}
}

func TestMessage_ReplyToTruncation(t *testing.T) {
	long := make([]byte, 300)
	for i := range long {
		long[i] = 'a'
	}
	msg := Message{
		ChatID: "test@s.whatsapp.net",
		Text:   "reply",
		Type:   "reply",
	}
	msg.SetReplyTo(string(long))
	if len(msg.ReplyTo) > 200 {
		t.Errorf("reply_to should be truncated to 200 chars, got %d", len(msg.ReplyTo))
	}
}
```

Create `buffer_test.go`:
```go
package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestBufferWriter_AppendsJSONL(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "whatsapp-buffer.jsonl")
	bw := NewBufferWriter(path)

	msg1 := Message{ChatID: "a@s.whatsapp.net", Text: "hello", Type: "text"}
	msg2 := Message{ChatID: "b@s.whatsapp.net", Text: "world", Type: "text"}

	if err := bw.Write(msg1); err != nil {
		t.Fatalf("write msg1: %v", err)
	}
	if err := bw.Write(msg2); err != nil {
		t.Fatalf("write msg2: %v", err)
	}

	f, _ := os.Open(path)
	defer f.Close()
	scanner := bufio.NewScanner(f)
	var lines int
	for scanner.Scan() {
		lines++
		var msg Message
		if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
			t.Fatalf("line %d: invalid JSON: %v", lines, err)
		}
	}
	if lines != 2 {
		t.Fatalf("expected 2 lines, got %d", lines)
	}
}

func TestBufferWriter_CreatesFileIfMissing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "subdir", "buffer.jsonl")
	bw := NewBufferWriter(path)

	msg := Message{ChatID: "a@s.whatsapp.net", Text: "test", Type: "text"}
	if err := bw.Write(msg); err != nil {
		t.Fatalf("write error: %v", err)
	}

	if _, err := os.Stat(path); os.IsNotExist(err) {
		t.Fatal("buffer file was not created")
	}
}

func TestBufferWriter_SurvivesRename(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "buffer.jsonl")
	bw := NewBufferWriter(path)

	// Write first message
	bw.Write(Message{ChatID: "a@s.whatsapp.net", Text: "before", Type: "text"})

	// Simulate daemon atomic rotation: rename the file
	os.Rename(path, path+".processing")

	// Write second message — should create new file
	bw.Write(Message{ChatID: "a@s.whatsapp.net", Text: "after", Type: "text"})

	// New file should exist with 1 line
	f, _ := os.Open(path)
	defer f.Close()
	scanner := bufio.NewScanner(f)
	var lines int
	for scanner.Scan() {
		lines++
	}
	if lines != 1 {
		t.Fatalf("expected 1 line in new file after rename, got %d", lines)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd mac-daemon/claw-whatsapp
go test -v -run TestMessage
go test -v -run TestBufferWriter
```

Expected: compilation errors

- [ ] **Step 3: Implement message.go**

```go
package main

import "time"

type Message struct {
	ChatID    string `json:"chat_id"`
	ChatLabel string `json:"chat_label"`
	Sender    string `json:"sender"`
	SenderJID string `json:"sender_jid"`
	Text      string `json:"text"`
	Timestamp string `json:"ts"`
	Type      string `json:"type"`
	Caption   string `json:"caption,omitempty"`
	ReplyTo   string `json:"reply_to,omitempty"`
}

// SetReplyTo sets the reply context, truncating to 200 runes (UTF-8 safe).
func (m *Message) SetReplyTo(text string) {
	runes := []rune(text)
	if len(runes) > 200 {
		text = string(runes[:200])
	}
	m.ReplyTo = text
}

// FormatTimestamp converts a time.Time to ISO 8601.
func FormatTimestamp(t time.Time) string {
	return t.UTC().Format(time.RFC3339)
}
```

- [ ] **Step 4: Implement buffer.go**

```go
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

type BufferWriter struct {
	path string
	mu   sync.Mutex
}

func NewBufferWriter(path string) *BufferWriter {
	return &BufferWriter{path: path}
}

// Write appends a message as a JSON line to the buffer file.
// Creates the file (and parent dirs) if it doesn't exist.
// Safe for concurrent use. Handles the file being renamed by the daemon
// (atomic rotation) — opens fresh on each write.
func (bw *BufferWriter) Write(msg Message) error {
	bw.mu.Lock()
	defer bw.mu.Unlock()

	// Ensure parent directory exists
	if err := os.MkdirAll(filepath.Dir(bw.path), 0700); err != nil {
		return err
	}

	// Open with append+create, open fresh each time to handle renames
	f, err := os.OpenFile(bw.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()

	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = f.Write(data)
	return err
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd mac-daemon/claw-whatsapp
go test -v ./...
```

Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add mac-daemon/claw-whatsapp/message.go mac-daemon/claw-whatsapp/message_test.go mac-daemon/claw-whatsapp/buffer.go mac-daemon/claw-whatsapp/buffer_test.go
git commit -m "feat(claw-whatsapp): add message struct and JSONL buffer writer"
```

---

## Task 3: Health Reporter + Pause/Sensitive Mode

**Files:**
- Create: `mac-daemon/claw-whatsapp/health.go`
- Create: `mac-daemon/claw-whatsapp/health_test.go`
- Create: `mac-daemon/claw-whatsapp/pause.go`
- Create: `mac-daemon/claw-whatsapp/pause_test.go`

- [ ] **Step 1: Write failing tests for health and pause**

Create `health_test.go`:
```go
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestHealthReporter_WritesJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "whatsapp-health.json")
	hr := NewHealthReporter(path)

	hr.Update("syncing", time.Now())

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read health file: %v", err)
	}
	var status HealthStatus
	if err := json.Unmarshal(data, &status); err != nil {
		t.Fatalf("parse health JSON: %v", err)
	}
	if status.Status != "syncing" {
		t.Errorf("expected status 'syncing', got '%s'", status.Status)
	}
}
```

Create `pause_test.go`:
```go
package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPauseChecker_NotPausedByDefault(t *testing.T) {
	dir := t.TempDir()
	pc := NewPauseChecker(dir)
	if pc.IsPaused() {
		t.Error("should not be paused when no files exist")
	}
	if pc.IsSensitive() {
		t.Error("should not be sensitive when no files exist")
	}
}

func TestPauseChecker_PausedIndefinite(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "pause-until"), []byte("indefinite"), 0600)
	pc := NewPauseChecker(dir)
	if !pc.IsPaused() {
		t.Error("should be paused when pause-until contains 'indefinite'")
	}
}

func TestPauseChecker_PausedUntilFuture(t *testing.T) {
	dir := t.TempDir()
	future := time.Now().Add(1 * time.Hour).Unix()
	os.WriteFile(filepath.Join(dir, "pause-until"), []byte(time.Unix(future, 0).Format(time.RFC3339)), 0600)
	pc := NewPauseChecker(dir)
	if !pc.IsPaused() {
		t.Error("should be paused when pause-until is in the future")
	}
}

func TestPauseChecker_PausedUntilPast(t *testing.T) {
	dir := t.TempDir()
	past := time.Now().Add(-1 * time.Hour).Format(time.RFC3339)
	os.WriteFile(filepath.Join(dir, "pause-until"), []byte(past), 0600)
	pc := NewPauseChecker(dir)
	if pc.IsPaused() {
		t.Error("should not be paused when pause-until is in the past")
	}
}

func TestPauseChecker_SensitiveMode(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "sensitive-mode"), []byte("1"), 0600)
	pc := NewPauseChecker(dir)
	if !pc.IsSensitive() {
		t.Error("should be sensitive when sensitive-mode file exists")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd mac-daemon/claw-whatsapp
go test -v -run TestHealth
go test -v -run TestPauseChecker
```

Expected: compilation errors

- [ ] **Step 3: Implement health.go**

```go
package main

import (
	"encoding/json"
	"os"
	"sync"
	"time"
)

type HealthStatus struct {
	Status        string `json:"status"`
	LastMessageAt string `json:"last_message_at,omitempty"`
	UptimeSeconds int64  `json:"uptime_seconds"`
	Error         string `json:"error,omitempty"`
}

type HealthReporter struct {
	path      string
	startTime time.Time
	mu        sync.Mutex
}

func NewHealthReporter(path string) *HealthReporter {
	return &HealthReporter{
		path:      path,
		startTime: time.Now(),
	}
}

func (hr *HealthReporter) Update(status string, lastMsg time.Time) {
	hr.mu.Lock()
	defer hr.mu.Unlock()

	hs := HealthStatus{
		Status:        status,
		UptimeSeconds: int64(time.Since(hr.startTime).Seconds()),
	}
	if !lastMsg.IsZero() {
		hs.LastMessageAt = FormatTimestamp(lastMsg)
	}

	data, _ := json.Marshal(hs)
	// Write atomically: write to temp, then rename
	tmp := hr.path + ".tmp"
	os.WriteFile(tmp, data, 0600)
	os.Rename(tmp, hr.path)
}

func (hr *HealthReporter) UpdateError(errMsg string) {
	hr.mu.Lock()
	defer hr.mu.Unlock()

	hs := HealthStatus{
		Status:        "error",
		UptimeSeconds: int64(time.Since(hr.startTime).Seconds()),
		Error:         errMsg,
	}
	data, _ := json.Marshal(hs)
	tmp := hr.path + ".tmp"
	os.WriteFile(tmp, data, 0600)
	os.Rename(tmp, hr.path)
}
```

- [ ] **Step 4: Implement pause.go**

```go
package main

import (
	"os"
	"path/filepath"
	"strings"
	"time"
)

type PauseChecker struct {
	cbDir string
}

func NewPauseChecker(cbDir string) *PauseChecker {
	return &PauseChecker{cbDir: cbDir}
}

// IsPaused checks ~/.context-bridge/pause-until.
// Returns true if file contains "indefinite" or a future timestamp.
func (pc *PauseChecker) IsPaused() bool {
	data, err := os.ReadFile(filepath.Join(pc.cbDir, "pause-until"))
	if err != nil {
		return false // no file = not paused
	}
	content := strings.TrimSpace(string(data))
	if content == "" {
		return false
	}
	if content == "indefinite" {
		return true
	}
	// Try parsing as timestamp
	t, err := time.Parse(time.RFC3339, content)
	if err != nil {
		// Try unix timestamp
		return false
	}
	return time.Now().Before(t)
}

// IsSensitive checks if ~/.context-bridge/sensitive-mode file exists.
func (pc *PauseChecker) IsSensitive() bool {
	_, err := os.Stat(filepath.Join(pc.cbDir, "sensitive-mode"))
	return err == nil
}

// ShouldCapture returns true if neither paused nor in sensitive mode.
func (pc *PauseChecker) ShouldCapture() bool {
	return !pc.IsPaused() && !pc.IsSensitive()
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd mac-daemon/claw-whatsapp
go test -v ./...
```

Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add mac-daemon/claw-whatsapp/health.go mac-daemon/claw-whatsapp/health_test.go mac-daemon/claw-whatsapp/pause.go mac-daemon/claw-whatsapp/pause_test.go
git commit -m "feat(claw-whatsapp): add health reporter and pause/sensitive mode checker"
```

---

## Task 4: Message Event Handler (whatsmeow Integration)

**Files:**
- Create: `mac-daemon/claw-whatsapp/sync.go`
- Create: `mac-daemon/claw-whatsapp/message_test.go` (extend)

This task adds the whatsmeow dependency and implements the message event handler that extracts structured messages from protocol events.

- [ ] **Step 1: Add whatsmeow dependency**

```bash
cd mac-daemon/claw-whatsapp
go get go.mau.fi/whatsmeow@latest
go get google.golang.org/protobuf@latest
```

- [ ] **Step 2: Write failing test for message extraction from whatsmeow event**

Add to `message_test.go`:
```go
func TestExtractMessageType(t *testing.T) {
	tests := []struct {
		name     string
		hasText  bool
		hasImage bool
		hasVideo bool
		hasDoc   bool
		hasAudio bool
		want     string
	}{
		{"text only", true, false, false, false, false, "text"},
		{"image", false, true, false, false, false, "image"},
		{"video", false, false, true, false, false, "video"},
		{"document", false, false, false, true, false, "document"},
		{"audio", false, false, false, false, true, "voice"},
		{"nothing", false, false, false, false, false, "unknown"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := classifyMessageType(tt.hasText, tt.hasImage, tt.hasVideo, tt.hasDoc, tt.hasAudio)
			if got != tt.want {
				t.Errorf("classifyMessageType() = %s, want %s", got, tt.want)
			}
		})
	}
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd mac-daemon/claw-whatsapp
go test -v -run TestExtractMessageType
```

Expected: compilation error (classifyMessageType not defined)

- [ ] **Step 4: Implement sync.go with message extraction and the event handler**

```go
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/events"
	"go.mau.fi/whatsmeow/store/sqlstore"
	waLog "go.mau.fi/whatsmeow/util/log"
	waProto "go.mau.fi/whatsmeow/binary/proto"
)

// classifyMessageType determines the message type from protocol fields.
func classifyMessageType(hasText, hasImage, hasVideo, hasDoc, hasAudio bool) string {
	switch {
	case hasImage:
		return "image"
	case hasVideo:
		return "video"
	case hasDoc:
		return "document"
	case hasAudio:
		return "voice"
	case hasText:
		return "text"
	default:
		return "unknown"
	}
}

// extractMessage converts a whatsmeow Message event into our Message struct.
// Returns nil if the message should be skipped (non-whitelisted, empty, etc).
func extractMessage(evt *events.Message, wl *Whitelist) *Message {
	chatJID := evt.Info.Chat.String()
	if !wl.IsAllowed(chatJID) {
		return nil
	}

	proto := evt.Message
	if proto == nil {
		return nil
	}

	// Determine sender
	senderJID := "self"
	senderName := "self"
	if !evt.Info.IsFromMe {
		senderJID = evt.Info.Sender.String()
		senderName = evt.Info.PushName
		if senderName == "" {
			senderName = senderJID
		}
	}

	// Extract text and type
	var text, caption, replyTo string
	hasText := proto.GetConversation() != "" || proto.GetExtendedTextMessage() != nil
	hasImage := proto.GetImageMessage() != nil
	hasVideo := proto.GetVideoMessage() != nil
	hasDoc := proto.GetDocumentMessage() != nil
	hasAudio := proto.GetAudioMessage() != nil

	msgType := classifyMessageType(hasText, hasImage, hasVideo, hasDoc, hasAudio)

	// Get text content
	if conv := proto.GetConversation(); conv != "" {
		text = conv
	} else if ext := proto.GetExtendedTextMessage(); ext != nil {
		text = ext.GetText()
		if ctx := ext.GetContextInfo(); ctx != nil {
			if quoted := ctx.GetQuotedMessage(); quoted != nil {
				qText := quoted.GetConversation()
				if qText == "" && quoted.GetExtendedTextMessage() != nil {
					qText = quoted.GetExtendedTextMessage().GetText()
				}
				replyTo = qText
				msgType = "reply"
			}
		}
	}

	// Get captions from media messages
	if img := proto.GetImageMessage(); img != nil {
		caption = img.GetCaption()
	} else if vid := proto.GetVideoMessage(); vid != nil {
		caption = vid.GetCaption()
	} else if doc := proto.GetDocumentMessage(); doc != nil {
		caption = doc.GetCaption()
	}

	if msgType == "unknown" {
		return nil // Skip reaction-only, protocol messages, etc
	}

	msg := &Message{
		ChatID:    chatJID,
		ChatLabel: wl.LabelFor(chatJID),
		Sender:    senderName,
		SenderJID: senderJID,
		Text:      text,
		Timestamp: FormatTimestamp(evt.Info.Timestamp),
		Type:      msgType,
		Caption:   caption,
	}
	if replyTo != "" {
		msg.SetReplyTo(replyTo)
	}
	return msg
}

// RunSync starts the persistent sync loop.
func RunSync(sessionDir, privacyRulesPath, bufferPath, healthPath, cbDir string) error {
	// Set up logging
	dbLog := waLog.Stdout("Database", "WARN", true)
	container, err := sqlstore.New("sqlite3", fmt.Sprintf("file:%s/whatsmeow.db?_foreign_keys=on", sessionDir), dbLog)
	if err != nil {
		return fmt.Errorf("database init: %w", err)
	}

	deviceStore, err := container.GetFirstDevice()
	if err != nil {
		return fmt.Errorf("get device: %w", err)
	}

	clientLog := waLog.Stdout("Client", "WARN", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	// Load whitelist
	wl, err := LoadWhitelist(privacyRulesPath)
	if err != nil {
		return fmt.Errorf("load whitelist: %w", err)
	}

	// Set up components
	buffer := NewBufferWriter(bufferPath)
	health := NewHealthReporter(healthPath)
	pause := NewPauseChecker(cbDir)
	var lastMsgTime time.Time

	// Register message handler
	client.AddEventHandler(func(rawEvt interface{}) {
		switch evt := rawEvt.(type) {
		case *events.Message:
			if !pause.ShouldCapture() {
				return
			}
			msg := extractMessage(evt, wl)
			if msg == nil {
				return
			}
			if err := buffer.Write(*msg); err != nil {
				log.Printf("buffer write error: %v", err)
			}
			lastMsgTime = time.Now()
		}
	})

	// Connect
	if err := client.Connect(); err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	log.Println("Connected to WhatsApp")

	// SIGHUP reloads whitelist, SIGINT/SIGTERM disconnects
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM)

	// Health ticker
	healthTicker := time.NewTicker(30 * time.Second)
	defer healthTicker.Stop()

	// Write initial health
	health.Update("syncing", lastMsgTime)

	// Main loop
	for {
		select {
		case sig := <-sigCh:
			switch sig {
			case syscall.SIGHUP:
				log.Println("Reloading whitelist...")
				if err := wl.Reload(privacyRulesPath); err != nil {
					log.Printf("whitelist reload error: %v", err)
				} else {
					log.Println("Whitelist reloaded")
				}
			case syscall.SIGINT, syscall.SIGTERM:
				log.Println("Shutting down...")
				client.Disconnect()
				return nil
			}
		case <-healthTicker.C:
			status := "syncing"
			if !client.IsConnected() {
				status = "disconnected"
			} else if !pause.ShouldCapture() {
				status = "paused"
			}
			health.Update(status, lastMsgTime)
		}
	}
}
```

**Note:** The exact whatsmeow API may need adjustment based on the version. The import paths (`go.mau.fi/whatsmeow/binary/proto`) may differ — check the wacli source for the correct import paths when implementing. The `events.Message` struct fields (`Info.Chat`, `Info.Sender`, `Info.PushName`, `Info.IsFromMe`, `Info.Timestamp`) are stable across whatsmeow versions.

- [ ] **Step 5: Run tests**

`classifyMessageType` is defined in `sync.go` and tested in `message_test.go`. Both are `package main`, so this works. Run:
```bash
cd mac-daemon/claw-whatsapp
go test -v -run TestExtractMessageType
```

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add mac-daemon/claw-whatsapp/sync.go mac-daemon/claw-whatsapp/message.go mac-daemon/claw-whatsapp/message_test.go mac-daemon/claw-whatsapp/go.sum
git commit -m "feat(claw-whatsapp): add whatsmeow sync loop and message extraction"
```

---

## Task 5: Auth + Setup + Main Entry Point

**Files:**
- Create: `mac-daemon/claw-whatsapp/auth.go`
- Create: `mac-daemon/claw-whatsapp/setup.go`
- Create: `mac-daemon/claw-whatsapp/main.go`

- [ ] **Step 1: Implement auth.go (QR code pairing)**

```go
package main

import (
	"context"
	"fmt"
	"log"

	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// RunAuth handles the QR code pairing flow.
func RunAuth(sessionDir string) error {
	dbLog := waLog.Stdout("Database", "WARN", true)
	container, err := sqlstore.New("sqlite3", fmt.Sprintf("file:%s/whatsmeow.db?_foreign_keys=on", sessionDir), dbLog)
	if err != nil {
		return fmt.Errorf("database init: %w", err)
	}

	deviceStore, err := container.GetFirstDevice()
	if err != nil {
		return fmt.Errorf("get device: %w", err)
	}

	clientLog := waLog.Stdout("Client", "INFO", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	if client.Store.ID == nil {
		// No existing session, need to pair
		qrChan, _ := client.GetQRChannel(context.Background())
		if err := client.Connect(); err != nil {
			return fmt.Errorf("connect: %w", err)
		}

		for evt := range qrChan {
			switch evt.Event {
			case "code":
				fmt.Println("\nScan this QR code in WhatsApp > Settings > Linked Devices:\n")
				// Print QR code to terminal
				fmt.Println(evt.Code)
				fmt.Println("\n(Copy this code and use your phone's WhatsApp to scan or enter it)")
			case "login":
				fmt.Println("\nLogin successful! Device linked.")
				client.Disconnect()
				return nil
			case "timeout":
				client.Disconnect()
				return fmt.Errorf("QR code scan timed out — please try again")
			}
		}
	} else {
		fmt.Println("Already paired! Device ID:", client.Store.ID)
		fmt.Println("To re-pair, delete the session directory and run --auth again:")
		fmt.Printf("  rm -rf %s && claw-whatsapp --auth\n", sessionDir)
	}

	client.Disconnect()
	return nil
}
```

**Note:** For a proper terminal QR code display, add `github.com/mdp/qrterminal/v3` as a dependency and use `qrterminal.GenerateHalfBlock(evt.Code, qrterminal.L, os.Stdout)`. Reference the wacli source for the exact QR rendering approach.

- [ ] **Step 2: Implement setup.go (interactive whitelist builder)**

```go
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"

	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// RunSetup connects to WhatsApp, lists recent chats, and lets the user pick which ones to whitelist.
func RunSetup(sessionDir, privacyRulesPath string) error {
	dbLog := waLog.Stdout("Database", "WARN", true)
	container, err := sqlstore.New("sqlite3", fmt.Sprintf("file:%s/whatsmeow.db?_foreign_keys=on", sessionDir), dbLog)
	if err != nil {
		return fmt.Errorf("database init: %w", err)
	}

	deviceStore, err := container.GetFirstDevice()
	if err != nil {
		return fmt.Errorf("get device: %w", err)
	}
	if deviceStore.ID == nil {
		return fmt.Errorf("not paired yet — run claw-whatsapp --auth first")
	}

	clientLog := waLog.Stdout("Client", "WARN", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	if err := client.Connect(); err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer client.Disconnect()

	// Get contacts and groups
	contacts, err := client.Store.Contacts.GetAllContacts()
	if err != nil {
		log.Printf("Warning: could not load contacts: %v", err)
	}

	groups, err := client.GetJoinedGroups()
	if err != nil {
		log.Printf("Warning: could not load groups: %v", err)
	}

	type chatOption struct {
		jid   string
		label string
		id    string // whitelist ID format
	}

	var options []chatOption

	// Add individual contacts
	for jid, info := range contacts {
		name := info.FullName
		if name == "" {
			name = info.PushName
		}
		if name == "" {
			name = jid.User
		}
		options = append(options, chatOption{
			jid:   jid.String(),
			label: name,
			id:    "+" + jid.User,
		})
	}

	// Add groups
	for _, g := range groups {
		options = append(options, chatOption{
			jid:   g.JID.String(),
			label: g.Name,
			id:    "group:" + g.JID.String(),
		})
	}

	if len(options) == 0 {
		fmt.Println("No contacts or groups found. Send/receive some messages first, then try again.")
		return nil
	}

	// Display options
	fmt.Println("\nAvailable chats:\n")
	for i, opt := range options {
		fmt.Printf("  %3d. %-30s  %s\n", i+1, opt.label, opt.id)
	}

	// Get selections
	fmt.Println("\nEnter numbers to whitelist (comma-separated), or 'q' to quit:")
	fmt.Print("> ")
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Scan()
	input := strings.TrimSpace(scanner.Text())
	if input == "q" || input == "" {
		return nil
	}

	var selected []WhitelistContact
	for _, s := range strings.Split(input, ",") {
		s = strings.TrimSpace(s)
		n, err := strconv.Atoi(s)
		if err != nil || n < 1 || n > len(options) {
			fmt.Printf("Skipping invalid selection: %s\n", s)
			continue
		}
		opt := options[n-1]
		selected = append(selected, WhitelistContact{ID: opt.id, Label: opt.label})
		fmt.Printf("  Added: %s (%s)\n", opt.label, opt.id)
	}

	if len(selected) == 0 {
		fmt.Println("No contacts selected.")
		return nil
	}

	// Read existing privacy rules
	var rules map[string]interface{}
	data, err := os.ReadFile(privacyRulesPath)
	if err != nil {
		rules = make(map[string]interface{})
	} else {
		json.Unmarshal(data, &rules)
		if rules == nil {
			rules = make(map[string]interface{})
		}
	}

	// Merge with existing whitelist
	var existing []WhitelistContact
	if wlRaw, ok := rules["whatsapp_whitelist"].(map[string]interface{}); ok {
		if contactsRaw, ok := wlRaw["contacts"]; ok {
			b, _ := json.Marshal(contactsRaw)
			json.Unmarshal(b, &existing)
		}
	}

	// Deduplicate by ID
	seen := make(map[string]bool)
	for _, c := range existing {
		seen[c.ID] = true
	}
	for _, c := range selected {
		if !seen[c.ID] {
			existing = append(existing, c)
			seen[c.ID] = true
		}
	}

	rules["whatsapp_whitelist"] = map[string]interface{}{
		"mode":     "whitelist",
		"contacts": existing,
	}

	output, _ := json.MarshalIndent(rules, "", "  ")
	if err := os.WriteFile(privacyRulesPath, output, 0600); err != nil {
		return fmt.Errorf("write privacy rules: %w", err)
	}

	fmt.Printf("\nWhitelist updated: %d contacts in %s\n", len(existing), privacyRulesPath)

	// Signal running process to reload
	sendSIGHUP()
	return nil
}

// sendSIGHUP sends SIGHUP to a running claw-whatsapp --run process via PID file.
// Best-effort — if no PID file or process, silently skip.
func sendSIGHUP() {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return
	}
	pidPath := filepath.Join(homeDir, ".context-bridge", "whatsapp.pid")
	data, err := os.ReadFile(pidPath)
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return
	}
	if err := proc.Signal(syscall.SIGHUP); err != nil {
		fmt.Printf("Note: could not signal running process (PID %d): %v\n", pid, err)
	} else {
		fmt.Println("Signaled running claw-whatsapp to reload whitelist.")
	}
}
```

- [ ] **Step 3: Implement main.go**

```go
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
)

func main() {
	authMode := flag.Bool("auth", false, "Link WhatsApp by scanning QR code")
	runMode := flag.Bool("run", false, "Start persistent message sync (for launchd)")
	setupMode := flag.Bool("setup", false, "Interactively add contacts to whitelist")
	checkMode := flag.Bool("check", false, "Print current sync status")
	flag.Parse()

	homeDir, _ := os.UserHomeDir()
	cbDir := filepath.Join(homeDir, ".context-bridge")
	sessionDir := filepath.Join(cbDir, "whatsapp-session")
	privacyRulesPath := filepath.Join(cbDir, "privacy-rules.json")
	bufferPath := filepath.Join(cbDir, "whatsapp-buffer.jsonl")
	healthPath := filepath.Join(cbDir, "whatsapp-health.json")

	// Ensure session directory exists
	os.MkdirAll(sessionDir, 0700)

	modes := 0
	if *authMode { modes++ }
	if *runMode { modes++ }
	if *setupMode { modes++ }
	if *checkMode { modes++ }

	if modes != 1 {
		fmt.Println("Usage: claw-whatsapp --auth | --run | --setup | --check")
		os.Exit(1)
	}

	var err error
	switch {
	case *authMode:
		err = RunAuth(sessionDir)
	case *runMode:
		// Write PID file for SIGHUP signaling
		pidPath := filepath.Join(cbDir, "whatsapp.pid")
		os.WriteFile(pidPath, []byte(fmt.Sprintf("%d", os.Getpid())), 0600)
		defer os.Remove(pidPath)
		err = RunSync(sessionDir, privacyRulesPath, bufferPath, healthPath, cbDir)
	case *setupMode:
		err = RunSetup(sessionDir, privacyRulesPath)
	case *checkMode:
		err = RunCheck(healthPath, privacyRulesPath)
	}

	if err != nil {
		log.Fatalf("Error: %v", err)
	}
}

// RunCheck reads health and whitelist status and prints a summary.
func RunCheck(healthPath, privacyRulesPath string) error {
	data, err := os.ReadFile(healthPath)
	if err != nil {
		fmt.Println("Status: not running (no health file)")
		return nil
	}

	fmt.Printf("Health: %s\n", string(data))

	wl, err := LoadWhitelist(privacyRulesPath)
	if err != nil {
		fmt.Printf("Whitelist: error reading (%v)\n", err)
	} else {
		fmt.Printf("Whitelist: %d contacts\n", len(wl.Contacts))
		for _, c := range wl.Contacts {
			fmt.Printf("  - %s (%s)\n", c.Label, c.ID)
		}
	}
	return nil
}
```

- [ ] **Step 4: Verify the project builds**

```bash
cd mac-daemon/claw-whatsapp
go build -tags sqlite_fts5 -o claw-whatsapp .
```

Expected: binary created successfully. If there are import path issues with whatsmeow, check the wacli source (`go.mod` and import statements) for the correct module paths and adjust accordingly.

- [ ] **Step 5: Run all tests**

```bash
cd mac-daemon/claw-whatsapp
go test -v -tags sqlite_fts5 ./...
```

Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add mac-daemon/claw-whatsapp/
git commit -m "feat(claw-whatsapp): add auth, setup, check modes and main entry point"
```

---

## Task 6: Launchd Plist

**Files:**
- Create: `mac-daemon/com.openclaw.context-bridge-whatsapp.plist`

- [ ] **Step 1: Create the plist**

Reference: `mac-daemon/com.openclaw.context-bridge-fswatch.plist` for template pattern.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.context-bridge-whatsapp</string>

    <key>ProgramArguments</key>
    <array>
        <string>__CONTEXT_BRIDGE_BIN_DIR__/claw-whatsapp</string>
        <string>--run</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>StandardOutPath</key>
    <string>/tmp/claw-whatsapp.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claw-whatsapp-error.log</string>
</dict>
</plist>
```

Uses `__CONTEXT_BRIDGE_BIN_DIR__` template variable, same as fswatch plist — replaced by `install.sh` during installation.

- [ ] **Step 2: Commit**

```bash
git add mac-daemon/com.openclaw.context-bridge-whatsapp.plist
git commit -m "feat(claw-whatsapp): add launchd plist for persistent WhatsApp sync"
```

---

## Task 7: Daemon Integration (Buffer Reading)

**Files:**
- Modify: `mac-daemon/context-daemon.sh` (~lines 533-555 for buffer read, ~lines 728-755 for payload)

This integrates the WhatsApp buffer into the existing daemon capture cycle using the same pattern as fswatch log reading.

- [ ] **Step 1: Add buffer reading after the fswatch block**

In `context-daemon.sh`, after the fswatch log reading block (around line 541), add the WhatsApp buffer read with atomic file rotation. The `.processing` file is only deleted after a successful HTTP POST — if the send fails, it's retried on the next cycle.

```bash
# --- WhatsApp messages (atomic rotation) ---
WA_BUFFER="$CB_DIR/whatsapp-buffer.jsonl"
WA_PROCESSING="$CB_DIR/whatsapp-buffer.jsonl.processing"
WA_MESSAGES_FILE=""

# First: recover any leftover .processing file from a failed previous cycle
if [ -f "$WA_PROCESSING" ] && [ ! -f "$WA_BUFFER" ]; then
    # Previous cycle failed after mv but before successful send — reuse it
    WA_MESSAGES_FILE="$WA_PROCESSING"
elif [ -f "$WA_PROCESSING" ] && [ -f "$WA_BUFFER" ]; then
    # Both exist: merge .processing (older) with new buffer, then rotate
    cat "$WA_PROCESSING" "$WA_BUFFER" > "$WA_PROCESSING.merged"
    mv "$WA_PROCESSING.merged" "$WA_PROCESSING"
    rm -f "$WA_BUFFER"
    WA_MESSAGES_FILE="$WA_PROCESSING"
elif mv "$WA_BUFFER" "$WA_PROCESSING" 2>/dev/null; then
    # Normal case: rotate buffer to .processing
    WA_MESSAGES_FILE="$WA_PROCESSING"
fi

# Read into a temp file that the Python payload builder reads directly
# (avoids ARG_MAX limits for large message volumes)
WA_JSON_TMP=""
if [ -n "$WA_MESSAGES_FILE" ] && [ -s "$WA_MESSAGES_FILE" ]; then
    WA_JSON_TMP="$CB_DIR/whatsapp-payload.json"
    python3 -c "
import sys, json
lines = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            lines.append(json.loads(line))
        except json.JSONDecodeError:
            pass
with open('$WA_JSON_TMP', 'w') as f:
    json.dump(lines, f)
" < "$WA_MESSAGES_FILE"
fi
```

- [ ] **Step 2: Integrate into payload builder and handle cleanup**

Instead of passing through an environment variable (which has ARG_MAX limits), the payload builder reads the temp JSON file directly:

Add to the export block (around line 719):
```bash
export CB_WHATSAPP_MESSAGES_FILE="${WA_JSON_TMP:-""}"
```

In the payload builder Python block (around line 744), read from the file:
```python
wa_msgs = []
wa_file = os.environ.get('CB_WHATSAPP_MESSAGES_FILE', '')
if wa_file and os.path.exists(wa_file):
    with open(wa_file) as f:
        wa_msgs = json.load(f)
```

Then include in the payload dict:
```python
'whatsapp_messages': wa_msgs,
```

**After a successful HTTP POST**, delete both the `.processing` and temp files:
```bash
# After successful send (where HTTP response code is checked)
rm -f "$WA_PROCESSING" "$WA_JSON_TMP"
```

If the send fails and the payload is queued locally, leave `.processing` in place — it will be recovered on the next cycle.

- [ ] **Step 3: Test manually**

Create a test buffer file and run the daemon:
```bash
# Create test buffer
echo '{"chat_id":"test@s.whatsapp.net","chat_label":"Test","sender":"Test User","sender_jid":"test@s.whatsapp.net","text":"Hello world","ts":"2026-03-30T14:00:00Z","type":"text"}' > ~/.context-bridge/whatsapp-buffer.jsonl

# Run daemon (dry-run: check the payload output in logs)
bash mac-daemon/context-daemon.sh

# Verify buffer was rotated and cleaned up after send
ls ~/.context-bridge/whatsapp-buffer.jsonl.processing  # should not exist after successful send

# Check log for whatsapp_messages in payload
grep whatsapp_messages /tmp/context-bridge.log
```

- [ ] **Step 4: Commit**

```bash
git add mac-daemon/context-daemon.sh
git commit -m "feat(daemon): read WhatsApp message buffer with atomic file rotation"
```

---

## Task 8: Server Receiver Changes

**Files:**
- Modify: `server/context-receiver.py` (~lines 176-209 sanitizer, ~lines 226-259 INSERT)

**Design note:** The spec says to store `whatsapp_messages` inside the existing `raw_payload` JSON column with no schema change. We deviate here by adding a dedicated column for two reasons: (1) the digest processor can query it directly without parsing `raw_payload` for every row, and (2) it follows the pattern used by `notifications`, `whatsapp_context`, and other structured fields that have their own columns.

- [ ] **Step 1: Add whatsapp_messages to the sanitizer**

In `sanitize_activity_payload()` (around line 176), add handling for the new field:

```python
'whatsapp_messages': json.dumps(data.get('whatsapp_messages', [])) if data.get('whatsapp_messages') else None,
```

- [ ] **Step 2: Add column to activity_stream table**

In `init_db()`, add a migration-safe column addition after the existing CREATE TABLE and migration blocks (around line 67):

```python
# Add whatsapp_messages column if it doesn't exist (migration-safe)
try:
    db.execute("ALTER TABLE activity_stream ADD COLUMN whatsapp_messages TEXT")
except Exception:
    pass  # Column already exists
```

- [ ] **Step 3: Add to INSERT statement**

Update the INSERT INTO activity_stream statement (around line 226) to include `whatsapp_messages`. This requires three changes:
1. Add `whatsapp_messages` to the column list in the INSERT INTO clause
2. Add one more `?` placeholder to the VALUES clause (must match column count exactly)
3. Add `sanitized.get('whatsapp_messages')` to the values tuple

Count the existing columns and placeholders before and after to verify they match.

- [ ] **Step 4: Suppress from debug logging**

In the request logging section, ensure `whatsapp_messages` content is not logged (same as clipboard suppression pattern):
```python
# In the debug log line, replace whatsapp_messages with a count
log_safe = dict(sanitized)
if log_safe.get('whatsapp_messages'):
    msgs = json.loads(log_safe['whatsapp_messages'])
    log_safe['whatsapp_messages'] = f"[{len(msgs)} messages]"
```

- [ ] **Step 5: Test with curl**

```bash
curl -X POST http://localhost:7890/context/push \
  -H "Authorization: Bearer $CONTEXT_BRIDGE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "ts": "2026-03-30T14:34:00Z",
    "app": "WhatsApp",
    "whatsapp_messages": [
      {"chat_id": "test@s.whatsapp.net", "chat_label": "Test", "sender": "Nil", "text": "Hello", "ts": "2026-03-30T14:32:00Z", "type": "text"}
    ],
    "idle_state": "active",
    "idle_seconds": 0
  }'
```

Verify with:
```bash
python3 -c "
import sqlite3, json
db = sqlite3.connect('server/context_bridge.db')
db.row_factory = sqlite3.Row
row = db.execute('SELECT whatsapp_messages, raw_payload FROM activity_stream ORDER BY created_at DESC LIMIT 1').fetchone()
print('Column:', row['whatsapp_messages'])
print('Raw payload whatsapp_messages:', json.loads(row['raw_payload']).get('whatsapp_messages'))
"
```

- [ ] **Step 6: Commit**

```bash
git add server/context-receiver.py
git commit -m "feat(server): accept and store whatsapp_messages in activity stream"
```

---

## Task 9: Digest Processor — WhatsApp Section

**Files:**
- Modify: `server/context-digest.py` (~lines 564-576 communication section, new section after)

- [ ] **Step 1: Accumulate WhatsApp messages during data collection**

In the data collection loop (around lines 277-314), add accumulation:
```python
# WhatsApp messages accumulation (alongside existing notification accumulation)
all_whatsapp_messages = []
# In the per-row loop:
if row.get('whatsapp_messages'):
    try:
        msgs = json.loads(row['whatsapp_messages'])
        all_whatsapp_messages.extend(msgs)
    except (json.JSONDecodeError, TypeError):
        pass
```

- [ ] **Step 2: Add WhatsApp Messages section to digest output**

This is a new `## WhatsApp Messages` section that supplements (does not replace) the existing `## Communication` section. The Communication section continues to show window-title-based WhatsApp context (`whatsapp_context` field). The new section shows full message content from the `whatsapp_messages` field. When full message capture is active, both sections will be present — the Communication section provides timeline context, the Messages section provides content.

Add after the Communication section (around line 573), before AI Agent Sessions (around line 576):

```python
# WhatsApp Messages section
if all_whatsapp_messages:
    digest_lines.append("\n## WhatsApp Messages\n")
    # Group by chat
    chats = {}
    for msg in all_whatsapp_messages:
        chat_key = msg.get('chat_label', msg.get('chat_id', 'Unknown'))
        chat_id = msg.get('chat_id', '')
        if chat_key not in chats:
            chats[chat_key] = {'id': chat_id, 'messages': []}
        chats[chat_key]['messages'].append(msg)

    for chat_label, chat_data in chats.items():
        msgs = chat_data['messages']
        timestamps = [m.get('ts', '') for m in msgs if m.get('ts')]
        time_range = ""
        if timestamps:
            first = timestamps[0].split('T')[1][:5] if 'T' in timestamps[0] else timestamps[0]
            last = timestamps[-1].split('T')[1][:5] if 'T' in timestamps[-1] else timestamps[-1]
            time_range = f", {first}\u2013{last}"

        digest_lines.append(f"**{chat_label}** ({chat_data['id']}) \u2014 {len(msgs)} messages{time_range}\n")

        # Extract URLs
        urls = set()
        for msg in msgs:
            text = msg.get('text', '')
            # Simple URL extraction
            for word in text.split():
                if word.startswith('http://') or word.startswith('https://'):
                    urls.add(word)

        for msg in msgs:
            sender = msg.get('sender', '?')
            text = msg.get('text', '')
            msg_type = msg.get('type', 'text')
            caption = msg.get('caption', '')

            if msg_type != 'text' and msg_type != 'reply':
                type_tag = f"[{msg_type}]"
                line = f"- {sender}: {type_tag}"
                if caption:
                    line += f' "{caption}"'
                elif text:
                    line += f" {text}"
            else:
                line = f'- {sender}: "{text}"'
                reply_to = msg.get('reply_to', '')
                if reply_to:
                    line += f' (replying to: "{reply_to[:80]}...")'

            digest_lines.append(line)

        if urls:
            digest_lines.append(f"\nLinks shared:")
            for url in urls:
                digest_lines.append(f"  - {url}")

        digest_lines.append("")  # blank line between chats
```

- [ ] **Step 3: Test with sample data**

```bash
# Insert test data, then run digest
python3 server/context-digest.py --dry-run
```

Verify the output contains a `## WhatsApp Messages` section with the test messages.

- [ ] **Step 4: Commit**

```bash
git add server/context-digest.py
git commit -m "feat(digest): add WhatsApp Messages section with mechanical message extraction"
```

---

## Task 10: Helperctl Integration

**Files:**
- Modify: `mac-daemon/context-helperctl.sh` (~lines 13-61 status_json, ~lines 120-132 restart)

- [ ] **Step 1: Add whatsappLaunchdState to status_json()**

In the `status_json()` function (around line 50-59), add:
```python
wa_state = launchd_state("com.openclaw.context-bridge-whatsapp")
```

And in the output dict:
```python
"whatsappLaunchdState": wa_state,
```

- [ ] **Step 2: Add whatsapp-status action**

Add a new action handler that reads the health file:
```bash
whatsapp-status)
    HEALTH_FILE="$CB_DIR/whatsapp-health.json"
    if [ -f "$HEALTH_FILE" ]; then
        cat "$HEALTH_FILE"
    else
        echo '{"status": "not running"}'
    fi
    ;;
```

- [ ] **Step 3: Add restart-whatsapp action**

Following the `restart-watcher` pattern (around line 380):
```bash
restart-whatsapp)
    restart_launchd "com.openclaw.context-bridge-whatsapp"
    ;;
```

- [ ] **Step 4: Commit**

```bash
git add mac-daemon/context-helperctl.sh
git commit -m "feat(helperctl): add WhatsApp launchd state, status, and restart actions"
```

---

## Task 11: Install Script Update

**Files:**
- Modify: `mac-daemon/install.sh` (~lines 65-76 binary install, ~lines 142-151 plist install)

- [ ] **Step 1: Add Go build step**

After the existing binary copy block (around line 76), add:
```bash
# Build claw-whatsapp if Go is available
if command -v go &>/dev/null; then
    echo "  Building claw-whatsapp..."
    (cd "$SCRIPT_DIR/claw-whatsapp" && go build -tags sqlite_fts5 -o "$CB_DIR/bin/claw-whatsapp" .) || {
        echo "  Warning: claw-whatsapp build failed. WhatsApp capture will not be available."
        echo "  Install Go and re-run install.sh to enable WhatsApp capture."
    }
else
    echo "  Skipping claw-whatsapp (Go not installed). WhatsApp capture will not be available."
fi
```

- [ ] **Step 2: Add plist installation**

After the fswatch plist block (around line 151), add:
```bash
# WhatsApp sync service (only if binary exists)
if [ -f "$CB_DIR/bin/claw-whatsapp" ]; then
    WA_PLIST="$HOME/Library/LaunchAgents/com.openclaw.context-bridge-whatsapp.plist"
    sed "s#__CONTEXT_BRIDGE_BIN_DIR__#$CB_DIR/bin#g" \
        "$SCRIPT_DIR/com.openclaw.context-bridge-whatsapp.plist" > "$WA_PLIST"
    launchctl unload "$WA_PLIST" 2>/dev/null
    # Don't auto-load — user needs to run --auth first
    echo "  WhatsApp plist installed. Run 'claw-whatsapp --auth' to link, then load the service."
fi
```

- [ ] **Step 3: Commit**

```bash
git add mac-daemon/install.sh
git commit -m "feat(install): add claw-whatsapp build and plist installation"
```

---

## Task 12: Menu Bar Integration

**Files:**
- Modify: `mac-helper/ClawRelay/` (Swift UI files for the menu bar app)

This task adds the WhatsApp submenu to the ClawRelay menu bar app.

- [ ] **Step 1: Identify the menu construction file**

Check `mac-helper/ClawRelay/` for the file that builds the NSMenu / SwiftUI menu. Look for where `daemonLaunchdState` and `watcherLaunchdState` are displayed — the WhatsApp status goes alongside these.

- [ ] **Step 2: Add WhatsApp status reading**

In the status polling code (where `helperctl status` is called), parse the new `whatsappLaunchdState` field. Also read `~/.context-bridge/whatsapp-health.json` for detailed status.

- [ ] **Step 3: Add WhatsApp submenu**

Add a submenu with:
- Status line: "Syncing" / "Disconnected" / "Paused" / "Not installed"
- Whitelist contacts (read from `privacy-rules.json`)
- "Re-link WhatsApp..." → opens Terminal with `claw-whatsapp --auth`
- "Add Contact..." → opens Terminal with `claw-whatsapp --setup`

Pattern: follow how existing menu items launch terminal commands (reference existing `restart-watcher` or similar actions in the menu bar code).

- [ ] **Step 4: Build and test**

```bash
cd mac-helper
xcodebuild -project ClawRelay.xcodeproj -scheme ClawRelay build
```

- [ ] **Step 5: Commit**

```bash
git add mac-helper/
git commit -m "feat(menu-bar): add WhatsApp submenu with status, whitelist, and auth actions"
```

---

## Task 13: End-to-End Verification

- [ ] **Step 1: Build and install everything**

```bash
cd mac-daemon
bash install.sh
```

- [ ] **Step 2: Link WhatsApp**

```bash
~/.context-bridge/bin/claw-whatsapp --auth
# Scan QR code from phone
```

- [ ] **Step 3: Add test contact to whitelist**

```bash
~/.context-bridge/bin/claw-whatsapp --setup
# Pick a contact
```

- [ ] **Step 4: Start the service**

```bash
launchctl load ~/Library/LaunchAgents/com.openclaw.context-bridge-whatsapp.plist
```

- [ ] **Step 5: Verify capture**

```bash
# Check health
~/.context-bridge/bin/claw-whatsapp --check

# Send a test message to a whitelisted contact from your phone
# Wait a few seconds, then check the buffer
cat ~/.context-bridge/whatsapp-buffer.jsonl

# Wait for daemon cycle (2 min), then check server
python3 server/context-query.py now
```

- [ ] **Step 6: Verify digest**

```bash
python3 server/context-digest.py --dry-run
# Should show WhatsApp Messages section
```

- [ ] **Step 7: Test pause/sensitive mode**

```bash
# Pause capture
echo "indefinite" > ~/.context-bridge/pause-until

# Send a message — should NOT appear in buffer
cat ~/.context-bridge/whatsapp-buffer.jsonl  # should be empty or unchanged

# Resume
rm ~/.context-bridge/pause-until
```

- [ ] **Step 8: Test fallback (stop wacli, verify notification capture still works)**

```bash
launchctl unload ~/Library/LaunchAgents/com.openclaw.context-bridge-whatsapp.plist
# Check menu bar shows "Degraded"
# Send a message — notification capture should still catch incoming
```
