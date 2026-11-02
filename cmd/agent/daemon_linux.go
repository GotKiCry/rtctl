//go:build linux

package main

import (
	"errors"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func detachProcess(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

func ignoreTerminalHangup() {
	signal.Ignore(syscall.SIGHUP)
}

func processExecutable(pid int) (string, error) {
	exe, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/exe")
	if err != nil {
		return "", err
	}
	return strings.TrimSuffix(exe, " (deleted)"), nil
}

func sameExecutable(a, b string) bool {
	if ea, err := filepath.EvalSymlinks(a); err == nil {
		a = ea
	}
	if eb, err := filepath.EvalSymlinks(b); err == nil {
		b = eb
	}
	return filepath.Clean(a) == filepath.Clean(b)
}

func terminateProcess(pid int) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	err = process.Signal(syscall.SIGTERM)
	if errors.Is(err, os.ErrProcessDone) {
		return nil
	}
	return err
}

// isAddrInUse 报告 listen 失败是否因端口被占用。
func isAddrInUse(err error) bool {
	return errors.Is(err, syscall.EADDRINUSE)
}
