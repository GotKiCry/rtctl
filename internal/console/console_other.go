//go:build !windows

package console

// DisableQuickEdit 仅 Windows 控制台有 QuickEdit 概念，其他平台为空实现。
func DisableQuickEdit() {}
