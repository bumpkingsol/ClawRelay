package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestHealthReporter_WritesJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "whatsapp-health.json")
	hr := NewHealthReporter(path)

	hr.Update("syncing", time.Now())

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read health file: %v", err)
	}
	var status HealthStatus
	if err := json.Unmarshal(data, &status); err != nil {
		t.Fatalf("parse health JSON: %v", err)
	}
	if status.Status != "syncing" {
		t.Errorf("expected status 'syncing', got '%s'", status.Status)
	}
}
