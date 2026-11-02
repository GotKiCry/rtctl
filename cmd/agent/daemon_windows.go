//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/windows"
)

const detachedProcess = 0x00000008

func detachProcess(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | detachedProcess,
	}
}

func ignoreTerminalHangup() {}

func processExecutable(pid int) (string, error) {
	handle, err := syscall.OpenProcess(syscall.PROCESS_QUERY_INFORMATION, false, uint32(pid))
	if err != nil {
		return "", err
	}
	defer syscall.CloseHandle(handle)
	var exitCode uint32
	if err := syscall.GetExitCodeProcess(handle, &exitCode); err != nil {
		return "", err
	}
	if exitCode != 259 {
		return "", os.ErrProcessDone
	}
	buf := make([]uint16, 32768)
	size := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(windows.Handle(handle), 0, &buf[0], &size); err != nil {
		return "", err
	}
	return syscall.UTF16ToString(buf[:size]), nil
}

func sameExecutable(a, b string) bool {
	return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
}

func terminateProcess(pid int) error {
	handle, err := syscall.OpenProcess(syscall.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		return err
	}
	defer syscall.CloseHandle(handle)
	if err := syscall.TerminateProcess(handle, 1); err != nil {
		return fmt.Errorf("TerminateProcess: %w", err)
	}
	return nil
}

// isAddrInUse 报告 listen 失败是否因端口被占用。
// Windows 上 Go 返回的是原始 WSA 错误码，syscall.EADDRINUSE 与它并不相等。
func isAddrInUse(err error) bool {
	var errno syscall.Errno
	return errors.As(err, &errno) && errno == windows.WSAEADDRINUSE
}
