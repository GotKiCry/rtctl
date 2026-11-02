//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows"
)

// enableANSI 给 stdout 控制台启用 Virtual Terminal Processing（ANSI 转义支持）。
// 失败（如 stdout 不是控制台）返回 false，调用方静默降级为纯文本。
func enableANSI() bool {
	h := windows.Handle(os.Stdout.Fd())
	var mode uint32
	if err := windows.GetConsoleMode(h, &mode); err != nil {
		return false
	}
	const enableVirtualTerminalProcessing = 0x0004
	if mode&enableVirtualTerminalProcessing != 0 {
		return true
	}
	return windows.SetConsoleMode(h, mode|enableVirtualTerminalProcessing) == nil
}
