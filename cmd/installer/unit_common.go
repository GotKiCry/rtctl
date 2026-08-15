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
	var execLine, unitExtra string
	extra := map[string]string{}
	switch cfg.component {
	case "agent":
		execLine = fmt.Sprintf("%s -listen %q", dst, cfg.listen)
		if cfg.tlsCert != "" {
			execLine += fmt.Sprintf(" -tls-cert %q -tls-key %q", cfg.tlsCert, cfg.tlsKey)
		}
		execLine += fmt.Sprintf(" -id %q", cfg.id)
		unitExtra = fmt.Sprintf("Environment=RTCTL_TOKEN=%s\n", cfg.token)
	case "clientd":
		execLine = fmt.Sprintf("%s -client-id clientd serve -listen %q -devices /etc/rtctl/clientd-devices.json -api-key %q",
			dst, cfg.httpListen, cfg.apiKey)
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
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
`, cfg.component, user, unitExtra, execLine)
	return &linuxPlan{unitName: unitName, binaryName: name, user: user, unit: unit, extraFiles: extra}, nil
}
