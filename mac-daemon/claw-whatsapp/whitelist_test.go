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
	wl.buildJIDMap()
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
	wl.buildJIDMap()
	if !wl.IsAllowed("120363012345678901@g.us") {
		t.Error("expected group JID to match")
	}
	if wl.IsAllowed("999999999999999999@g.us") {
		t.Error("expected non-whitelisted group to not match")
	}
}

func TestWhitelist_EmptyDisallowsAll(t *testing.T) {
	wl := &Whitelist{Contacts: []WhitelistContact{}}
	wl.buildJIDMap()
	if wl.IsAllowed("34612345678@s.whatsapp.net") {
		t.Error("empty whitelist should disallow all")
	}
}
