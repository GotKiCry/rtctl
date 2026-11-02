package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

type pidRecord struct {
	PID        int    `json:"pid"`
	Executable string `json:"executable"`
}

type daemonResult struct {
	PID   int    `json:"pid"`
	Addr  string `json:"addr,omitempty"`
	Error string `json:"error,omitempty"`
}

func defaultRuntimePath(name string) string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return filepath.Join(home, ".rtctl", name)
	}
	return name
}

// statusListenAddr 返回 -status 应探测的监听地址：-listen 优先，其次配置文件，最后默认 :8443。
func statusListenAddr(o runtimeOptions) string {
	if o.listen != "" {
		return o.listen
	}
	if c, err := loadConfig(o.configPath); err == nil && c.listen != "" {
		return c.listen
	}
	return ":8443"
}

// portOccupiedHint 在监听地址已被占用时返回一行排查提示，否则返回空串。
// 用于 -status：PID 文件显示未运行但端口被占时，说明存在未受管理的实例或其他程序。
func portOccupiedHint(listen string) string {
	ln, err := net.Listen("tcp", listen)
	if err == nil {
		ln.Close()
		return ""
	}
	if !isAddrInUse(err) {
		return ""
	}
	return fmt.Sprintf("监听地址 %s 当前被其他进程占用（可能是未受 PID 文件管理的旧实例，或其他程序）", listen)
}

func currentPIDRecord() (pidRecord, error) {
	exe, err := os.Executable()
	if err != nil {
		return pidRecord{}, err
	}
	return pidRecord{PID: os.Getpid(), Executable: exe}, nil
}

func readPIDRecord(path string) (pidRecord, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return pidRecord{}, err
	}
	var rec pidRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return pidRecord{}, err
	}
	if rec.PID <= 0 || rec.Executable == "" {
		return pidRecord{}, fmt.Errorf("PID 文件内容无效")
	}
	return rec, nil
}

func runningPIDRecord(path string) (pidRecord, bool) {
	rec, err := readPIDRecord(path)
	if err != nil {
		return pidRecord{}, false
	}
	exe, err := processExecutable(rec.PID)
	if err != nil || !sameExecutable(rec.Executable, exe) {
		return pidRecord{}, false
	}
	return rec, true
}

func writePIDFile(path string) (pidRecord, error) {
	if rec, running := runningPIDRecord(path); running {
		return rec, fmt.Errorf("agent 已在运行 (pid=%d)", rec.PID)
	}
	rec, err := currentPIDRecord()
	if err != nil {
		return pidRecord{}, fmt.Errorf("读取当前进程信息失败: %w", err)
	}
	if dir := filepath.Dir(path); dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return pidRecord{}, fmt.Errorf("创建 PID 目录失败: %w", err)
		}
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return pidRecord{}, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return pidRecord{}, fmt.Errorf("写入 PID 文件失败: %w", err)
	}
	if err = f.Chmod(0o600); err == nil {
		_, err = f.Write(data)
	}
	closeErr := f.Close()
	if err != nil {
		return pidRecord{}, fmt.Errorf("写入 PID 文件失败: %w", err)
	}
	if closeErr != nil {
		return pidRecord{}, fmt.Errorf("关闭 PID 文件失败: %w", closeErr)
	}
	return rec, nil
}

func removeOwnPIDFile(path string) {
	rec, err := readPIDRecord(path)
	if err == nil && rec.PID == os.Getpid() {
		os.Remove(path)
	}
}

func stopPIDFile(path string) (int, error) {
	rec, running := runningPIDRecord(path)
	if !running {
		if _, err := os.Stat(path); err == nil {
			os.Remove(path)
		}
		return 0, nil
	}
	if err := terminateProcess(rec.PID); err != nil {
		return rec.PID, fmt.Errorf("停止 agent 失败: %w", err)
	}
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		exe, err := processExecutable(rec.PID)
		if err != nil || !sameExecutable(rec.Executable, exe) {
			os.Remove(path)
			return rec.PID, nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return rec.PID, fmt.Errorf("等待 agent 停止超时 (pid=%d)", rec.PID)
}

func notifyDaemon(path string, result daemonResult) error {
	if path == "" {
		return nil
	}
	data, err := json.Marshal(result)
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("写入启动状态失败: %w", err)
	}
	return nil
}

func readDaemonResult(path string) (daemonResult, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return daemonResult{}, err
	}
	var result daemonResult
	if err := json.Unmarshal(data, &result); err != nil {
		return daemonResult{}, err
	}
	if result.PID <= 0 && result.Error == "" {
		return daemonResult{}, fmt.Errorf("启动状态内容无效")
	}
	return result, nil
}

func launchBackground(pidFile string) (daemonResult, error) {
	if rec, running := runningPIDRecord(pidFile); running {
		return daemonResult{}, fmt.Errorf("agent 已在运行 (pid=%d)", rec.PID)
	}
	if dir := filepath.Dir(pidFile); dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return daemonResult{}, fmt.Errorf("创建运行目录失败: %w", err)
		}
	}
	ready, err := os.CreateTemp(filepath.Dir(pidFile), ".rtctl-ready-*")
	if err != nil {
		return daemonResult{}, fmt.Errorf("创建启动状态文件失败: %w", err)
	}
	readyPath := ready.Name()
	if err := ready.Close(); err != nil {
		os.Remove(readyPath)
		return daemonResult{}, err
	}
	defer os.Remove(readyPath)

	exe, err := os.Executable()
	if err != nil {
		return daemonResult{}, fmt.Errorf("定位 agent 可执行文件失败: %w", err)
	}
	args := append([]string(nil), os.Args[1:]...)
	args = append(args, "-open-firewall=false", "-daemon-ready", readyPath)
	cmd := exec.Command(exe, args...)
	detachProcess(cmd)
	if err := cmd.Start(); err != nil {
		return daemonResult{}, fmt.Errorf("创建后台 agent 失败: %w", err)
	}
	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()

	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	timeout := time.NewTimer(15 * time.Second)
	defer timeout.Stop()
	for {
		select {
		case <-ticker.C:
			result, err := readDaemonResult(readyPath)
			if err == nil {
				if result.Error != "" {
					return daemonResult{}, errors.New(result.Error)
				}
				return result, nil
			}
		case err := <-waitCh:
			if result, readErr := readDaemonResult(readyPath); readErr == nil {
				if result.Error != "" {
					return daemonResult{}, errors.New(result.Error)
				}
				return result, nil
			}
			if err == nil {
				return daemonResult{}, fmt.Errorf("后台 agent 在报告就绪前退出")
			}
			return daemonResult{}, fmt.Errorf("后台 agent 启动失败: %w", err)
		case <-timeout.C:
			cmd.Process.Kill()
			return daemonResult{}, fmt.Errorf("等待后台 agent 就绪超时，请检查日志")
		}
	}
}
