package main

import (
	"encoding/json"
	"os"
	"strings"
	"sync"
)

// WhitelistContact represents a single allowed contact entry in privacy-rules.json.
// ID formats:
//   - Phone: "+34612345678"       → JID: "34612345678@s.whatsapp.net"
//   - Group: "group:...@g.us"    → JID: "...@g.us"
type WhitelistContact struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

// Whitelist holds the set of allowed contacts and provides thread-safe JID matching.
type Whitelist struct {
	Contacts []WhitelistContact
	mu       sync.RWMutex
	jidMap   map[string]string // normalised JID → label
}

// privacyRules mirrors the top-level structure of privacy-rules.json.
type privacyRules struct {
	WhatsAppWhitelist struct {
		Mode     string             `json:"mode"`
		Contacts []WhitelistContact `json:"contacts"`
	} `json:"whatsapp_whitelist"`
}

// LoadWhitelist reads and parses a privacy-rules.json file at path.
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
	}
	if wl.Contacts == nil {
		wl.Contacts = []WhitelistContact{}
	}
	wl.buildJIDMap()
	return wl, nil
}

// buildJIDMap (re)builds the internal lookup map from Contacts.
// Must be called after any direct mutation of Contacts (e.g. in tests).
func (wl *Whitelist) buildJIDMap() {
	wl.mu.Lock()
	defer wl.mu.Unlock()
	wl.jidMap = make(map[string]string, len(wl.Contacts))
	for _, c := range wl.Contacts {
		jid := contactIDToJID(c.ID)
		wl.jidMap[jid] = c.Label
	}
}

// Reload atomically replaces the whitelist contents from a file.
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

// IsAllowed reports whether jid is on the whitelist.
func (wl *Whitelist) IsAllowed(jid string) bool {
	wl.mu.RLock()
	defer wl.mu.RUnlock()
	_, ok := wl.jidMap[jid]
	return ok
}

// LabelFor returns the human-readable label for jid, or "" if not found.
func (wl *Whitelist) LabelFor(jid string) string {
	wl.mu.RLock()
	defer wl.mu.RUnlock()
	return wl.jidMap[jid]
}

// contactIDToJID converts a human-readable contact ID to a whatsmeow JID string.
func contactIDToJID(id string) string {
	if strings.HasPrefix(id, "group:") {
		return strings.TrimPrefix(id, "group:")
	}
	// Strip leading "+" from phone number to get the numeric part used in JIDs.
	phone := strings.TrimPrefix(id, "+")
	return phone + "@s.whatsapp.net"
}
