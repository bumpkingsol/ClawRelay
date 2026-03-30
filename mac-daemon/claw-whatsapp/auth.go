package main

import (
	"context"
	"fmt"
	"log"

	_ "github.com/mattn/go-sqlite3"
	"github.com/mdp/qrterminal/v3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// RunAuth handles the --auth mode: pairs with WhatsApp via QR code.
// If already paired, it prints the device ID and instructions to re-pair.
func RunAuth(sessionDir string) error {
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

	// If already paired, inform the user.
	if deviceStore.ID != nil {
		fmt.Printf("Already paired as device: %s\n", deviceStore.ID)
		fmt.Println("To re-pair, delete the session directory and run --auth again:")
		fmt.Printf("  rm -rf %s && claw-whatsapp --auth\n", sessionDir)
		return nil
	}

	clientLog := waLog.Stdout("Client", "WARN", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	qrChan, _ := client.GetQRChannel(context.Background())
	if err := client.Connect(); err != nil {
		return fmt.Errorf("connect: %w", err)
	}

	fmt.Println("Scan this QR code with WhatsApp (Settings > Linked Devices > Link a Device):")
	fmt.Println()

	for evt := range qrChan {
		switch evt.Event {
		case "code":
			qrterminal.GenerateHalfBlock(evt.Code, qrterminal.L, log.Writer())
			fmt.Println()
			fmt.Println("Waiting for scan...")
		case "login":
			fmt.Println("Paired successfully!")
			fmt.Printf("Device ID: %s\n", client.Store.ID)
			client.Disconnect()
			return nil
		case "timeout":
			client.Disconnect()
			return fmt.Errorf("QR code timed out — run --auth again")
		case "error":
			client.Disconnect()
			return fmt.Errorf("pairing error — run --auth again")
		}
	}

	client.Disconnect()
	return nil
}
