// status.go —— rtctl-wizard status：查看已安装组件的运行与开机自启状态。
package main

import (
	"fmt"
	"os/exec"
	"runtime"
	"strings"
)

// statusService 一个组件的状态快照。
type statusService struct {
	component string
	active    string
	enabled   string
}

func queryLinux(unit string) (active, enabled string) {
	if out, err := exec.Command("systemctl", "is-active", unit).CombinedOutput(); err == nil {
		active = strings.TrimSpace(string(out))
	} else {
		active = "未安装"
	}
	if out, err := exec.Command("systemctl", "is-enabled", unit).CombinedOutput(); err == nil {
		enabled = strings.TrimSpace(string(out))
	} else {
		enabled = "未安装"
	}
	return
}

func queryWindows(task string) (active, enabled string) {
	out, err := exec.Command("schtasks", "/Query", "/TN", task, "/FO", "LIST").CombinedOutput()
	if err != nil {
		return "未安装", "未安装"
	}
	s := string(out)
	switch {
	case strings.Contains(s, "正在运行") || strings.Contains(s, "Running"):
		active = "运行中"
	case strings.Contains(s, "就绪") || strings.Contains(s, "Ready"):
		active = "已就绪（未运行）"
	default:
		active = "已安装（状态未知）"
	}
	enabled = "已安装" // 计划任务开机触发即自启
	return
}

// printStatus 打印所有 rtctl 组件的运行与开机自启状态。
func printStatus() {
	fmt.Println("rtctl 组件状态:")
	fmt.Printf("  %-12s %-16s %s\n", "组件", "运行状态", "开机自启")
	fmt.Println(strings.Repeat("-", 44))
	if runtime.GOOS == "windows" {
		a, e := queryWindows("rtctl-agent")
		fmt.Printf("  %-12s %-16s %s\n", "agent", a, e)
		c, ce := queryWindows("rtctl-clientd")
		fmt.Printf("  %-12s %-16s %s\n", "clientd", c, ce)
	} else {
		a, e := queryLinux("rtctl-agent")
		fmt.Printf("  %-12s %-16s %s\n", "agent", a, e)
		c, ce := queryLinux("rtctl-clientd")
		fmt.Printf("  %-12s %-16s %s\n", "clientd", c, ce)
	}
	fmt.Println()
	fmt.Println("说明: 开机自启 = enabled（Linux systemd）/ 已安装（Windows 计划任务开机触发）")
	fmt.Println("      未安装表示需要先运行: sudo ./rtctl-wizard（Linux）或管理员运行向导（Windows）")
}
