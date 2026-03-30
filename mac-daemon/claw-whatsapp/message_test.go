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
