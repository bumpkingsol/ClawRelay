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

	bw.Write(Message{ChatID: "a@s.whatsapp.net", Text: "before", Type: "text"})
	os.Rename(path, path+".processing")
	bw.Write(Message{ChatID: "a@s.whatsapp.net", Text: "after", Type: "text"})

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
