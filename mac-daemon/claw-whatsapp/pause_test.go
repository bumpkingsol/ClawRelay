package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPauseChecker_NotPausedByDefault(t *testing.T) {
	dir := t.TempDir()
	pc := NewPauseChecker(dir)
	if pc.IsPaused() {
		t.Error("should not be paused when no files exist")
	}
	if pc.IsSensitive() {
		t.Error("should not be sensitive when no files exist")
	}
}

func TestPauseChecker_PausedIndefinite(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "pause-until"), []byte("indefinite"), 0600)
	pc := NewPauseChecker(dir)
	if !pc.IsPaused() {
		t.Error("should be paused when pause-until contains 'indefinite'")
	}
}

func TestPauseChecker_PausedUntilFuture(t *testing.T) {
	dir := t.TempDir()
	future := time.Now().Add(1 * time.Hour).Unix()
	os.WriteFile(filepath.Join(dir, "pause-until"), []byte(time.Unix(future, 0).Format(time.RFC3339)), 0600)
	pc := NewPauseChecker(dir)
	if !pc.IsPaused() {
		t.Error("should be paused when pause-until is in the future")
	}
}

func TestPauseChecker_PausedUntilPast(t *testing.T) {
	dir := t.TempDir()
	past := time.Now().Add(-1 * time.Hour).Format(time.RFC3339)
	os.WriteFile(filepath.Join(dir, "pause-until"), []byte(past), 0600)
	pc := NewPauseChecker(dir)
	if pc.IsPaused() {
		t.Error("should not be paused when pause-until is in the past")
	}
}

func TestPauseChecker_SensitiveMode(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "sensitive-mode"), []byte("1"), 0600)
	pc := NewPauseChecker(dir)
	if !pc.IsSensitive() {
		t.Error("should be sensitive when sensitive-mode file exists")
	}
}
