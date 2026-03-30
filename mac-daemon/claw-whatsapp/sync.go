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
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// classifyMessageType maps message field presence flags to a type string.
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

// extractMessage converts a whatsmeow event into our Message struct,
// returning nil if the chat is not whitelisted or the message type is unknown.
func extractMessage(evt *events.Message, wl *Whitelist) *Message {
	chatJID := evt.Info.Chat.String()
	if !wl.IsAllowed(chatJID) {
		return nil
	}

	proto := evt.Message
	if proto == nil {
		return nil
	}

	senderJID := "self"
	senderName := "self"
	if !evt.Info.IsFromMe {
		senderJID = evt.Info.Sender.String()
		senderName = evt.Info.PushName
		if senderName == "" {
			senderName = senderJID
		}
	}

	var text, caption, replyTo string
	hasText := proto.GetConversation() != "" || proto.GetExtendedTextMessage() != nil
	hasImage := proto.GetImageMessage() != nil
	hasVideo := proto.GetVideoMessage() != nil
	hasDoc := proto.GetDocumentMessage() != nil
	hasAudio := proto.GetAudioMessage() != nil

	msgType := classifyMessageType(hasText, hasImage, hasVideo, hasDoc, hasAudio)

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

	if img := proto.GetImageMessage(); img != nil {
		caption = img.GetCaption()
	} else if vid := proto.GetVideoMessage(); vid != nil {
		caption = vid.GetCaption()
	} else if doc := proto.GetDocumentMessage(); doc != nil {
		caption = doc.GetCaption()
	}

	if msgType == "unknown" {
		return nil
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

// RunSync starts the persistent WhatsApp sync loop. It:
//   - creates a whatsmeow client backed by a SQLite session store
//   - loads the whitelist from privacyRulesPath
//   - registers an event handler that filters by whitelist and writes to buffer
//   - connects to WhatsApp
//   - handles SIGHUP (reload whitelist), SIGINT/SIGTERM (disconnect)
//   - updates health every 30 seconds
func RunSync(sessionDir, privacyRulesPath, bufferPath, healthPath, cbDir string) error {
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

	clientLog := waLog.Stdout("Client", "WARN", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	wl, err := LoadWhitelist(privacyRulesPath)
	if err != nil {
		return fmt.Errorf("load whitelist: %w", err)
	}

	buffer := NewBufferWriter(bufferPath)
	health := NewHealthReporter(healthPath)
	pause := NewPauseChecker(cbDir)
	var lastMsgTime time.Time

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

	if err := client.Connect(); err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	log.Println("Connected to WhatsApp")

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM)

	healthTicker := time.NewTicker(30 * time.Second)
	defer healthTicker.Stop()

	health.Update("syncing", lastMsgTime)

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
