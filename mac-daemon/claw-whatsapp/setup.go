package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// contactEntry holds a display name and JID for interactive selection.
type contactEntry struct {
	Name string
	JID  types.JID
}

// RunSetup runs the interactive whitelist builder:
//   - connects to WhatsApp
//   - lists contacts and groups
//   - lets the user pick which to whitelist
//   - writes to privacy-rules.json (merging with existing)
//   - sends SIGHUP to a running --run process via PID file
func RunSetup(sessionDir, privacyRulesPath, cbDir string) error {
	dbLog := waLog.Stdout("Database", "WARN", true)
	container, err := sqlstore.New(context.Background(), "sqlite3",
		fmt.Sprintf("file:%s/whatsmeow.db?_foreign_keys=on", sessionDir), dbLog)
	if err != nil {
		return fmt.Errorf("database init: %w", err)
	}

	deviceStore, err := container.GetFirstDevice(context.Background())
	if err != nil {
		return fmt.Errorf("get device: %w", err)
	}

	if deviceStore.ID == nil {
		return fmt.Errorf("not paired — run --auth first")
	}

	clientLog := waLog.Stdout("Client", "WARN", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	if err := client.Connect(); err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer client.Disconnect()

	fmt.Println("Connected to WhatsApp. Fetching contacts and groups...")

	// Gather contacts
	var entries []contactEntry

	// Get joined groups
	groups, err := client.GetJoinedGroups(context.Background())
	if err != nil {
		log.Printf("Warning: could not fetch groups: %v", err)
	} else {
		for _, g := range groups {
			entries = append(entries, contactEntry{
				Name: fmt.Sprintf("[Group] %s", g.Name),
				JID:  g.JID,
			})
		}
	}

	// Get contacts from the store
	contacts, err := client.Store.Contacts.GetAllContacts(context.Background())
	if err != nil {
		log.Printf("Warning: could not fetch contacts: %v", err)
	} else {
		for jid, info := range contacts {
			name := info.PushName
			if name == "" {
				name = info.FullName
			}
			if name == "" {
				name = info.BusinessName
			}
			if name == "" {
				name = jid.User
			}
			entries = append(entries, contactEntry{
				Name: name,
				JID:  jid,
			})
		}
	}

	if len(entries) == 0 {
		fmt.Println("No contacts or groups found. Try sending/receiving a message first, then run --setup again.")
		return nil
	}

	// Display numbered list
	fmt.Println()
	fmt.Println("Available contacts and groups:")
	fmt.Println("------------------------------")
	for i, e := range entries {
		fmt.Printf("  %3d. %s  (%s)\n", i+1, e.Name, e.JID.String())
	}
	fmt.Println()
	fmt.Print("Enter numbers to whitelist (comma-separated, e.g. 1,3,5): ")

	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadString('\n')
	if err != nil {
		return fmt.Errorf("read input: %w", err)
	}

	selected := parseSelection(line, len(entries))
	if len(selected) == 0 {
		fmt.Println("No valid selections. Nothing changed.")
		return nil
	}

	// Build new whitelist contacts
	var newContacts []WhitelistContact
	for _, idx := range selected {
		e := entries[idx]
		id := jidToContactID(e.JID)
		label := e.Name
		// Strip the [Group] prefix for the label
		label = strings.TrimPrefix(label, "[Group] ")
		newContacts = append(newContacts, WhitelistContact{
			ID:    id,
			Label: label,
		})
	}

	// Merge with existing privacy rules
	if err := mergePrivacyRules(privacyRulesPath, newContacts); err != nil {
		return fmt.Errorf("write privacy rules: %w", err)
	}

	fmt.Printf("\nWhitelist updated (%d contacts added/merged) in %s\n", len(newContacts), privacyRulesPath)

	// Signal running daemon to reload
	sendSIGHUP(cbDir)

	return nil
}

// parseSelection parses a comma-separated list of 1-based indices.
func parseSelection(input string, max int) []int {
	var result []int
	seen := make(map[int]bool)
	parts := strings.Split(strings.TrimSpace(input), ",")
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		n, err := strconv.Atoi(p)
		if err != nil || n < 1 || n > max {
			continue
		}
		idx := n - 1
		if !seen[idx] {
			seen[idx] = true
			result = append(result, idx)
		}
	}
	return result
}

// jidToContactID converts a whatsmeow JID to our contact ID format.
func jidToContactID(jid types.JID) string {
	if jid.Server == types.GroupServer {
		return "group:" + jid.String()
	}
	return "+" + jid.User
}

// mergePrivacyRules reads existing privacy-rules.json, merges new contacts,
// and writes the result back.
func mergePrivacyRules(path string, newContacts []WhitelistContact) error {
	var rules privacyRules

	data, err := os.ReadFile(path)
	if err == nil {
		// File exists, parse it
		if err := json.Unmarshal(data, &rules); err != nil {
			return fmt.Errorf("parse existing rules: %w", err)
		}
	}

	// Ensure mode is set
	if rules.WhatsAppWhitelist.Mode == "" {
		rules.WhatsAppWhitelist.Mode = "whitelist"
	}

	// Build a set of existing IDs to avoid duplicates
	existing := make(map[string]bool)
	for _, c := range rules.WhatsAppWhitelist.Contacts {
		existing[c.ID] = true
	}

	// Merge new contacts
	for _, c := range newContacts {
		if !existing[c.ID] {
			rules.WhatsAppWhitelist.Contacts = append(rules.WhatsAppWhitelist.Contacts, c)
			existing[c.ID] = true
		}
	}

	// Write back
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}

	out, err := json.MarshalIndent(rules, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, out, 0600)
}

// sendSIGHUP reads the PID file and sends SIGHUP to the running daemon.
func sendSIGHUP(cbDir string) {
	pidPath := filepath.Join(cbDir, "whatsapp.pid")
	data, err := os.ReadFile(pidPath)
	if err != nil {
		// No PID file means no running daemon — that's fine
		return
	}

	pidStr := strings.TrimSpace(string(data))
	pid, err := strconv.Atoi(pidStr)
	if err != nil {
		log.Printf("Invalid PID in %s: %s", pidPath, pidStr)
		return
	}

	proc, err := os.FindProcess(pid)
	if err != nil {
		log.Printf("Could not find process %d: %v", pid, err)
		return
	}

	if err := proc.Signal(syscall.SIGHUP); err != nil {
		log.Printf("Could not send SIGHUP to PID %d: %v", pid, err)
	} else {
		fmt.Printf("Sent SIGHUP to running daemon (PID %d) to reload whitelist\n", pid)
	}
}
