package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
)

func main() {
	authMode := flag.Bool("auth", false, "Pair with WhatsApp via QR code")
	runMode := flag.Bool("run", false, "Start persistent sync daemon")
	setupMode := flag.Bool("setup", false, "Interactive whitelist builder")
	checkMode := flag.Bool("check", false, "Print health and whitelist summary")
	flag.Parse()

	// Exactly one mode must be specified.
	modeCount := 0
	if *authMode {
		modeCount++
	}
	if *runMode {
		modeCount++
	}
	if *setupMode {
		modeCount++
	}
	if *checkMode {
		modeCount++
	}
	if modeCount != 1 {
		fmt.Fprintln(os.Stderr, "Exactly one mode must be specified: --auth, --run, --setup, or --check")
		flag.Usage()
		os.Exit(1)
	}

	// Resolve paths.
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("Cannot determine home directory: %v", err)
	}

	cbDir := filepath.Join(home, ".context-bridge")
	sessionDir := filepath.Join(cbDir, "whatsapp-session")
	privacyRulesPath := filepath.Join(cbDir, "privacy-rules.json")
	bufferPath := filepath.Join(cbDir, "whatsapp-buffer.jsonl")
	healthPath := filepath.Join(cbDir, "whatsapp-health.json")
	pidPath := filepath.Join(cbDir, "whatsapp.pid")

	// Ensure session directory exists.
	if err := os.MkdirAll(sessionDir, 0700); err != nil {
		log.Fatalf("Cannot create session directory: %v", err)
	}

	switch {
	case *authMode:
		if err := RunAuth(sessionDir); err != nil {
			log.Fatalf("Auth failed: %v", err)
		}

	case *runMode:
		// Write PID file.
		if err := os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
			log.Fatalf("Cannot write PID file: %v", err)
		}
		defer os.Remove(pidPath)

		if err := RunSync(sessionDir, privacyRulesPath, bufferPath, healthPath, cbDir); err != nil {
			log.Fatalf("Sync failed: %v", err)
		}

	case *setupMode:
		if err := RunSetup(sessionDir, privacyRulesPath, cbDir); err != nil {
			log.Fatalf("Setup failed: %v", err)
		}

	case *checkMode:
		if err := RunCheck(healthPath, privacyRulesPath); err != nil {
			log.Fatalf("Check failed: %v", err)
		}
	}
}

// RunCheck reads the health JSON and whitelist, and prints a summary.
func RunCheck(healthPath, privacyRulesPath string) error {
	fmt.Println("=== claw-whatsapp status ===")
	fmt.Println()

	// Health status
	fmt.Println("Health:")
	data, err := os.ReadFile(healthPath)
	if err != nil {
		fmt.Printf("  No health file found (%s)\n", healthPath)
		fmt.Println("  The daemon may not have been started yet.")
	} else {
		var hs HealthStatus
		if err := json.Unmarshal(data, &hs); err != nil {
			fmt.Printf("  Error parsing health file: %v\n", err)
		} else {
			fmt.Printf("  Status:       %s\n", hs.Status)
			if hs.LastMessageAt != "" {
				fmt.Printf("  Last message: %s\n", hs.LastMessageAt)
			}
			fmt.Printf("  Uptime:       %ds\n", hs.UptimeSeconds)
			if hs.Error != "" {
				fmt.Printf("  Error:        %s\n", hs.Error)
			}
		}
	}

	fmt.Println()

	// Whitelist summary
	fmt.Println("Whitelist:")
	wl, err := LoadWhitelist(privacyRulesPath)
	if err != nil {
		fmt.Printf("  No whitelist found (%s)\n", privacyRulesPath)
		fmt.Println("  Run --setup to configure whitelisted contacts.")
	} else {
		if len(wl.Contacts) == 0 {
			fmt.Println("  No contacts whitelisted.")
			fmt.Println("  Run --setup to add contacts.")
		} else {
			fmt.Printf("  %d contact(s) whitelisted:\n", len(wl.Contacts))
			for _, c := range wl.Contacts {
				fmt.Printf("    - %s (%s)\n", c.Label, c.ID)
			}
		}
	}

	return nil
}
