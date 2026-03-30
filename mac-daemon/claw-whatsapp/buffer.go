package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

type BufferWriter struct {
	path string
	mu   sync.Mutex
}

func NewBufferWriter(path string) *BufferWriter {
	return &BufferWriter{path: path}
}

func (bw *BufferWriter) Write(msg Message) error {
	bw.mu.Lock()
	defer bw.mu.Unlock()

	if err := os.MkdirAll(filepath.Dir(bw.path), 0700); err != nil {
		return err
	}

	f, err := os.OpenFile(bw.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()

	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = f.Write(data)
	return err
}
