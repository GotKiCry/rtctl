//go:build windows

// Package console 处理 Windows 控制台的启动期设置。
package console

import "golang.org/x/sys/windows"

// DisableQuickEdit 关闭本进程控制台的快速编辑模式（QuickEdit）。
//
// Win10 的 conhost（cmd 默认终端）默认开启 QuickEdit：用户在窗口内
// 点击/拖选后控制台进入“标记”状态（标题栏出现“选择”前缀），此后任何
// 向该控制台的写入都会阻塞，直到用户按 Esc/Enter。对常驻运行的 agent
// 而言，一条 log 写阻塞就会卡住整个命令处理循环。QuickEdit 是控制台
// 输入缓冲区的模式位，清除后对本控制台内所有进程生效。
//
// 打开 CONIN$ 而非用 STD_INPUT_HANDLE：stdin 可能被重定向到管道，
// 而这里要操作的是控制台本身。无控制台（如计划任务 session 0）或
// 任何一步失败时静默忽略。
func DisableQuickEdit() {
	name, err := windows.UTF16PtrFromString("CONIN$")
	if err != nil {
		return
	}
	h, err := windows.CreateFile(name,
		windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		return
	}
	defer windows.CloseHandle(h)

	// EXTENDED_FLAGS 必须置位，对 QUICK_EDIT 位的修改才会生效
	const (
		quickEditMode = 0x0040
		extendedFlags = 0x0080
	)
	var mode uint32
	if err := windows.GetConsoleMode(h, &mode); err != nil {
		return
	}
	mode &^= quickEditMode
	mode |= extendedFlags
	_ = windows.SetConsoleMode(h, mode)
}
