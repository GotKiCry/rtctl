package main

import (
	"encoding/json"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPIDFileLifecycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.pid")
	rec, err := writePIDFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if rec.PID != os.Getpid() {
		t.Fatalf("pid = %d, want %d", rec.PID, os.Getpid())
	}
	if got, running := runningPIDRecord(path); !running || got.PID != rec.PID {
		t.Fatalf("runningPIDRecord = %+v, %v", got, running)
	}
	removeOwnPIDFile(path)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("PID file was not removed: %v", err)
	}
}

func TestStalePIDFileDoesNotStopCurrentProcess(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.pid")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	rec, err := currentPIDRecord()
	if err != nil {
		t.Fatal(err)
	}
	rec.Executable = exe + ".not-the-agent"
	data, err := json.Marshal(rec)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	pid, err := stopPIDFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if pid != 0 {
		t.Fatalf("stopped pid %d for a stale record", pid)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("stale PID file was not removed: %v", err)
	}
}

func TestDaemonResultReportsError(t *testing.T) {
	ready, err := os.CreateTemp(t.TempDir(), "ready-*")
	if err != nil {
		t.Fatal(err)
	}
	path := ready.Name()
	if err := ready.Close(); err != nil {
		t.Fatal(err)
	}
	want := daemonResult{Error: "listen failed"}
	if err := notifyDaemon(path, want); err != nil {
		t.Fatal(err)
	}
	got, err := readDaemonResult(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.Error != want.Error {
		t.Fatalf("error = %q, want %q", got.Error, want.Error)
	}
}

func TestRunAgentRejectsOccupiedPort(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	dir := t.TempDir()
	opts := runtimeOptions{
		configPath: filepath.Join(dir, "agent.conf"),
		logFile:    filepath.Join(dir, "agent.log"),
		pidFile:    filepath.Join(dir, "agent.pid"),
	}
	oldLogWriter := log.Writer()
	defer log.SetOutput(oldLogWriter)
	err = runAgent(opts, cfg{listen: listener.Addr().String(), id: "test", token: "test-token"})
	if err == nil {
		t.Fatal("runAgent succeeded on an occupied port")
	}
	if !strings.Contains(err.Error(), "端口已被占用") {
		t.Fatalf("占用端口应给出排查提示，实际：%v", err)
	}
	if _, statErr := os.Stat(opts.pidFile); !os.IsNotExist(statErr) {
		t.Fatalf("PID file remained after startup failure: %v", statErr)
	}
}

func TestPortOccupiedHint(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if hint := portOccupiedHint(listener.Addr().String()); !strings.Contains(hint, "被其他进程占用") {
		t.Fatalf("占用端口应给出提示，实际：%q", hint)
	}
	free, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := free.Addr().String()
	if err := free.Close(); err != nil {
		t.Fatal(err)
	}
	if hint := portOccupiedHint(addr); hint != "" {
		t.Fatalf("空闲端口不应有提示：%q", hint)
	}
}

func TestStatusListenAddr(t *testing.T) {
	confPath := filepath.Join(t.TempDir(), "agent.conf")
	if got := statusListenAddr(runtimeOptions{configPath: confPath}); got != ":8443" {
		t.Fatalf("无配置默认 = %q", got)
	}
	if err := os.WriteFile(confPath, []byte("listen = 127.0.0.1:9999\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := statusListenAddr(runtimeOptions{configPath: confPath}); got != "127.0.0.1:9999" {
		t.Fatalf("配置文件取值 = %q", got)
	}
	if got := statusListenAddr(runtimeOptions{configPath: confPath, listen: ":7777"}); got != ":7777" {
		t.Fatalf("-listen 优先 = %q", got)
	}
}
