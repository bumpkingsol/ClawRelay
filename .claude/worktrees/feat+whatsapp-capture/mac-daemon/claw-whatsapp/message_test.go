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
