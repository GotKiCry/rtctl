//go:build windows

package agent

import "syscall"

// shellExecArgs Windows：cmd /C；用 SysProcAttr.CmdLine 精确控制命令行。
// 若走默认 argv 引用，Go 的转义与 cmd.exe 引号规则冲突，
// 嵌套双引号会被剥掉导致命令被静默错误执行。
func shellExecArgs(cmd string) ([]string, *syscall.SysProcAttr) {
	return []string{"cmd", "/C", cmd}, &syscall.SysProcAttr{CmdLine: windowsCmdLine(cmd)}
}

// windowsCmdLine 构造 cmd.exe 可正确解析的命令行。
// cmd /C 引号规则：命令文本首字符为引号时，剥掉整串的首、尾两个引号。
// 因此在命令外包裹一对引号后，被剥掉的恰好是外层这对，内层内容原样保留
// （无论命令本身是否含引号、是否以引号开头）。/D 禁用 AutoRun。
func windowsCmdLine(cmd string) string {
	return `cmd /D /C "` + cmd + `"`
}
