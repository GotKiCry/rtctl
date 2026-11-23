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

func TestStatusTokenPriority(t *testing.T) {
	dir := t.TempDir()
	confPath := filepath.Join(dir, "agent.conf")
	if err := os.WriteFile(confPath, []byte("token = config-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RTCTL_TOKEN", "env-token")
	if got := statusToken(runtimeOptions{configPath: confPath, token: "flag-token"}); got != "flag-token" {
		t.Fatalf("命令行 token = %q", got)
	}
	if got := statusToken(runtimeOptions{configPath: confPath}); got != "config-token" {
		t.Fatalf("配置文件 token = %q", got)
	}
	if got := statusToken(runtimeOptions{configPath: filepath.Join(dir, "missing.conf")}); got != "env-token" {
		t.Fatalf("环境变量 token = %q", got)
	}
}

func TestRunningStatusSummaryToken(t *testing.T) {
	opts := runtimeOptions{token: "status-secret", printToken: true, logFile: "agent.log"}
	got := runningStatusSummary(pidRecord{PID: 123}, opts)
	if !strings.Contains(got, "设备 token: status-secret") {
		t.Fatalf("-status 未打印 token：%q", got)
	}
	opts.printToken = false
	got = runningStatusSummary(pidRecord{PID: 123}, opts)
	if strings.Contains(got, "status-secret") || !strings.Contains(got, "设备 token: <已隐藏>") {
		t.Fatalf("-print-token=false 未隐藏 token：%q", got)
	}
}
