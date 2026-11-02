package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestRotatingLogKeepsBoundedBackups(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.log")
	writer, err := openRotatingLog(path, 5, 2)
	if err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{"aaaaa", "bbbbb", "ccccc", "ddddd"} {
		if _, err := writer.Write([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{
		path:        "ddddd",
		path + ".1": "ccccc",
		path + ".2": "bbbbb",
	} {
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != want {
			t.Fatalf("%s = %q, want %q", name, data, want)
		}
	}
	if _, err := os.Stat(path + ".3"); !os.IsNotExist(err) {
		t.Fatalf("unexpected old backup: %v", err)
	}
}

func TestRotatingLogConcurrentWritesStayWhole(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.log")
	writer, err := openRotatingLog(path, 1<<20, 1)
	if err != nil {
		t.Fatal(err)
	}
	const goroutines = 8
	const writesPerGoroutine = 100
	var wg sync.WaitGroup
	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for j := 0; j < writesPerGoroutine; j++ {
				fmt.Fprintf(writer, "worker=%d line=%d\n", id, j)
			}
		}(i)
	}
	wg.Wait()
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != goroutines*writesPerGoroutine {
		t.Fatalf("got %d lines, want %d", len(lines), goroutines*writesPerGoroutine)
	}
	for _, line := range lines {
		var id, number int
		if _, err := fmt.Sscanf(line, "worker=%d line=%d", &id, &number); err != nil {
			t.Fatalf("corrupted log line %q: %v", line, err)
		}
	}
}
