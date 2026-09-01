//go:build windows

// firewall_windows.go —— Windows 防火墙放行（需管理员）：
// 通过 netsh 添加"入站 TCP 端口"规则，放行 agent 监听端口。
package main

import (
	"fmt"
	"net"
	"os/exec"
	"strings"
)

// openFirewallPort 添加 Windows 防火墙入站规则，返回摘要与详细提示。
// best-effort：非管理员会失败，只提示不阻塞启动。
func openFirewallPort(listen string) (firewallResult, error) {
	_, port, err := net.SplitHostPort(listen)
	if err != nil || port == "" {
		return firewallResult{}, fmt.Errorf("无法解析监听地址端口: %s", listen)
	}
	name := fmt.Sprintf("rtctl-agent-%s", port)
	// 先删旧规则（不存在时忽略错误），再添加，避免重复规则堆积
	_ = exec.Command("netsh", "advfirewall", "firewall", "delete", "rule", "name="+name).Run()
	args := []string{"advfirewall", "firewall", "add", "rule",
		"name=" + name, "dir=in", "action=allow", "protocol=TCP", "localport=" + port}
	out, err := exec.Command("netsh", args...).CombinedOutput()
	if err != nil {
		return firewallResult{
			summary: fmt.Sprintf("⚠ 未放行（需管理员添加规则，port=%s）", port),
			detail: fmt.Sprintf("自动添加防火墙规则失败：%s\n  请以管理员身份运行，或手动执行：\n    netsh %s",
				strings.TrimSpace(string(out)), strings.Join(args, " ")),
		}, err
	}
	return firewallResult{summary: fmt.Sprintf("已放行 TCP %s（入站规则 %s）", port, name)}, nil
}
