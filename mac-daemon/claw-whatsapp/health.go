package main

import (
	"encoding/json"
	"log"
	"os"
	"sync"
	"time"
)

type HealthStatus struct {
	Status        string `json:"status"`
	LastMessageAt string `json:"last_message_at,omitempty"`
	UptimeSeconds int64  `json:"uptime_seconds"`
	Error         string `json:"error,omitempty"`
}

type HealthReporter struct {
	path      string
	startTime time.Time
	mu        sync.Mutex
}

func NewHealthReporter(path string) *HealthReporter {
	return &HealthReporter{
		path:      path,
		startTime: time.Now(),
	}
}

func (hr *HealthReporter) Update(status string, lastMsg time.Time) {
	hr.mu.Lock()
	defer hr.mu.Unlock()

	hs := HealthStatus{
		Status:        status,
		UptimeSeconds: int64(time.Since(hr.startTime).Seconds()),
	}
	if !lastMsg.IsZero() {
		hs.LastMessageAt = FormatTimestamp(lastMsg)
	}

	data, err := json.Marshal(hs)
	if err != nil {
		log.Printf("health marshal error: %v", err)
		return
	}
	tmp := hr.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		log.Printf("health write error: %v", err)
		return
	}
	if err := os.Rename(tmp, hr.path); err != nil {
		log.Printf("health rename error: %v", err)
	}
}

func (hr *HealthReporter) UpdateError(errMsg string) {
	hr.mu.Lock()
	defer hr.mu.Unlock()

	hs := HealthStatus{
		Status:        "error",
		UptimeSeconds: int64(time.Since(hr.startTime).Seconds()),
		Error:         errMsg,
	}
	data, err := json.Marshal(hs)
	if err != nil {
		log.Printf("health marshal error: %v", err)
		return
	}
	tmp := hr.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		log.Printf("health write error: %v", err)
		return
	}
	if err := os.Rename(tmp, hr.path); err != nil {
		log.Printf("health rename error: %v", err)
	}
}
