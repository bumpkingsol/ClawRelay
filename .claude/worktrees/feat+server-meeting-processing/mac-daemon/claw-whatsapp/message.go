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

func FormatTimestamp(t time.Time) string {
	return t.UTC().Format(time.RFC3339)
}
