package main

import (
	"os"
	"path/filepath"
	"strings"
	"time"
)

type PauseChecker struct {
	cbDir string
}

func NewPauseChecker(cbDir string) *PauseChecker {
	return &PauseChecker{cbDir: cbDir}
}

func (pc *PauseChecker) IsPaused() bool {
	data, err := os.ReadFile(filepath.Join(pc.cbDir, "pause-until"))
	if err != nil {
		return false
	}
	content := strings.TrimSpace(string(data))
	if content == "" {
		return false
	}
	if content == "indefinite" {
		return true
	}
	t, err := time.Parse(time.RFC3339, content)
	if err != nil {
		return false
	}
	return time.Now().Before(t)
}

func (pc *PauseChecker) IsSensitive() bool {
	_, err := os.Stat(filepath.Join(pc.cbDir, "sensitive-mode"))
	return err == nil
}

func (pc *PauseChecker) ShouldCapture() bool {
	return !pc.IsPaused() && !pc.IsSensitive()
}
