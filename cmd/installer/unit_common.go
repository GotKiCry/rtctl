// unit_common.go —— Linux 安装计划生成（纯函数，无 build 标签，
// 便于在任意平台 dry-run 展示与单元测试）。
package main

import (
	"errors"
	"fmt"
)

// linuxPlan 一次 Linux 安装的生成物。
type linuxPlan struct {
	unitName   string            // systemd 服务名
	binaryName string            // /usr/local/bin 下的二进制名
	user       string            // 运行账户
	unit       string            // systemd unit 全文
	extraFiles map[string]string // 额外配置文件：路径 -> 内容
	sudoers    string            // 非空时写 /etc/sudoers.d/rtctl-agent（root:root 0440，不入 extraFiles）
}

// buildLinuxPlan 根据安装参数生成 systemd unit 与配置文件内容。
func buildLinuxPlan(cfg *installConfig) (*linuxPlan, error) {
	var name, unitName string
	switch cfg.component {
	case "agent":
		name, unitName = "rtctl-agent", "rtctl-agent"
	case "clientd":
		name, unitName = "rtctl-client", "rtctl-clientd"
	default:
		return nil, errors.New("未知组件")
	}
	user := cfg.user
	if user == "" {
		user = name
		if user == "rtctl-client" {
			user = "rtctl"
		}
	}
	dst := "/usr/local/bin/" + name
	plan := &linuxPlan{unitName: unitName, binaryName: name, user: user, extraFiles: map[string]string{}}
	execLine := ""
	unitExtra := ""
	// sudo 需要 setuid（NoNewPrivileges=true 会阻止 sudo 提权）；
	// 仅在被控端 agent 且用户批准提权时才放开。
	noNewPrivs := "true"
	switch cfg.component {
	case "agent":
		execLine = fmt.Sprintf("%s -listen %q", dst, cfg.listen)
		if cfg.tlsCert != "" {
			execLine += fmt.Sprintf(" -tls-cert %q -tls-key %q", cfg.tlsCert, cfg.tlsKey)
		}
		execLine += fmt.Sprintf(" -id %q", cfg.id)
		if cfg.allowSudo {
			execLine += " -allow-sudo"
			noNewPrivs = "false"
			// sudoers 按命令路径最小放行：agent 提权只用 /bin/sh 执行与 /usr/bin/kill 杀进程树
			plan.sudoers = fmt.Sprintf(`# rtctl agent 提权通道（由 rtctl 安装器生成；卸载或重装为不授权时自动删除）
%s ALL=(ALL) NOPASSWD: /bin/sh, /usr/bin/sh, /usr/bin/kill, /bin/kill
`, user)
		}
		unitExtra = fmt.Sprintf("Environment=RTCTL_TOKEN=%s\n", cfg.token)
	case "clientd":
		execLine = fmt.Sprintf("%s -client-id clientd serve -listen %q -devices /etc/rtctl/clientd-devices.json -api-key %q",
			dst, cfg.httpListen, cfg.apiKey)
		if cfg.allowSudo {
			// clientd 本身不需提权（sudo 在设备端执行），只是打开特权请求转发闸
			execLine += " -allow-sudo"
		}
	}

	unit := fmt.Sprintf(`[Unit]
Description=rtctl %s
After=network-online.target
Wants=network-online.target

[Service]
User=%s
%sExecStart=%s
Restart=always
RestartSec=3
NoNewPrivileges=%s

[Install]
WantedBy=multi-user.target
`, cfg.component, user, unitExtra, execLine, noNewPrivs)
	plan.unit = unit
	return plan, nil
}
