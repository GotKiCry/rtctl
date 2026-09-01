//go:build linux

// firewall_linux.go —— Linux 防火墙自动放行（best-effort）：
// 启动时探测 ufw / firewalld / iptables，放行 agent 监听端口。
// root 直接执行；普通用户尝试免密 sudo；均失败时给出可复制的提示命令。
package main

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
)

// firewallResult 由各平台 firewall_*.go 的 openFirewallPort 返回：
// summary 为单行摘要（进启动块），detail 为附加提示（可为空）。
// （类型定义在 main.go，供所有平台共用。）

// openFirewallPort 放行监听端口，返回摘要与详细提示。
// 只做 best-effort：放行失败不影响 agent 启动。
func openFirewallPort(listen string) (firewallResult, error) {
	_, port, err := net.SplitHostPort(listen)
	if err != nil || port == "" {
		return firewallResult{}, fmt.Errorf("无法解析监听地址端口: %s", listen)
	}

	switch {
	case hasCmd("ufw"):
		return tryFirewallCmd(port, "ufw", []string{"allow", port + "/tcp"},
			fmt.Sprintf("ufw allow %s/tcp", port))
	case hasCmd("firewall-cmd"):
		// firewalld：规则入永久库 + reload
		if out, err := runFirewall("firewall-cmd", "--permanent", "--add-port="+port+"/tcp"); err != nil {
			return failure(port, "firewall-cmd", fmt.Sprintf("firewall-cmd 放行失败: %s", strings.TrimSpace(out))), err
		}
		_, _ = runFirewall("firewall-cmd", "--reload")
		return firewallResult{summary: fmt.Sprintf("已放行 %s/tcp（firewalld）", port)}, nil
	case hasCmd("iptables"):
		return tryFirewallCmd(port, "iptables",
			[]string{"-I", "INPUT", "-p", "tcp", "--dport", port, "-j", "ACCEPT"},
			fmt.Sprintf("iptables -I INPUT -p tcp --dport %s -j ACCEPT", port))
	default:
		return firewallResult{summary: fmt.Sprintf("⚠ 未放行（未找到 ufw/firewall-cmd/iptables，请自行放行 %s/tcp）", port)}, nil
	}
}

// tryFirewallCmd 执行一条放行命令；失败时给出 sudoers 建议与手动命令。
func tryFirewallCmd(port, bin string, args []string, manual string) (firewallResult, error) {
	if out, err := runFirewall(bin, args...); err != nil {
		return failure(port, bin, strings.TrimSpace(out)), err
	}
	return firewallResult{summary: fmt.Sprintf("已放行 %s/tcp（%s）", port, bin)}, nil
}

// failure 生成失败摘要 + 详细建议（手动命令与 sudoers 配置）。
func failure(port, bin, out string) firewallResult {
	path := bin
	if p, e := exec.LookPath(bin); e == nil {
		path = p
	}
	summary := fmt.Sprintf("⚠ 未放行（sudo %s ...）", bin)
	detail := "自动放行防火墙失败：" + out + "\n"
	detail += "  方案一：以 root 运行 agent\n"
	detail += "  方案二：配置免密 sudo（sudo visudo 添加）：\n"
	detail += fmt.Sprintf("    %s ALL=(ALL) NOPASSWD: %s\n", userOrRoot(), path)
	detail += "  方案三：手动执行对应命令（见上方摘要）"
	return firewallResult{summary: summary, detail: detail}
}

// runFirewall 以 root 直接执行；普通用户用 sudo -n（免密）。
func runFirewall(bin string, args ...string) (string, error) {
	var cmd *exec.Cmd
	if os.Geteuid() == 0 {
		cmd = exec.Command(bin, args...)
	} else {
		cmd = exec.Command("sudo", append([]string{"-n", bin}, args...)...)
	}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// hasCmd 判断系统命令是否存在。
func hasCmd(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// userOrRoot 取当前用户名（sudoers 建议用）。
func userOrRoot() string {
	if u := os.Getenv("USER"); u != "" {
		return u
	}
	if u := os.Getenv("LOGNAME"); u != "" {
		return u
	}
	return "<用户>"
}
