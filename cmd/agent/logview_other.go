//go:build !windows

package main

// enableANSI 非 Windows 终端默认支持 ANSI 转义。
func enableANSI() bool { return true }
