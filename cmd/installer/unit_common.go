// unit_common.go —— Linux 安装计划生成（纯函数，无 build 标签，
// 便于在任意平台 dry-run 展示与单元测试）。
package main

import (
	"errors"
	"fmt"
	"strings"
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
	case "server":
		name, unitName = "rtctl-server", "rtctl-server"
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
		if cfg.listen != "" {
			execLine = fmt.Sprintf("%s -listen %q", dst, cfg.listen)
			if cfg.tlsCert != "" {
				execLine += fmt.Sprintf(" -tls-cert %q -tls-key %q", cfg.tlsCert, cfg.tlsKey)
			}
		} else {
			execLine = fmt.Sprintf("%s -server %q", dst, cfg.serverURL)
		}
		execLine += fmt.Sprintf(" -id %q", cfg.id)
		unitExtra = fmt.Sprintf("Environment=RTCTL_TOKEN=%s\n", cfg.token)
	case "clientd":
		execLine = dst
		if cfg.serverURL != "" {
			execLine += fmt.Sprintf(" -server %q -key %q", cfg.serverURL, cfg.clientKey)
		}
		execLine += fmt.Sprintf(" -client-id clientd serve -listen %q -devices /etc/rtctl/clientd-devices.json -api-key %q", cfg.httpListen, cfg.apiKey)
	case "server":
		var tokens strings.Builder
		var devs strings.Builder
		devs.WriteString(`{ "devices": [`)
		for i, id := range cfg.deviceIDs {
			tok := genToken()
			if i > 0 {
				devs.WriteString(",")
			}
			fmt.Fprintf(&devs, ` { "id": %q, "token": %q }`, id, tok)
			fmt.Fprintf(&tokens, "设备 %s 的 token: %s\n", id, tok)
		}
		devs.WriteString(" ] }")
		extra["/etc/rtctl/devices.json"] = devs.String()
		extra["/etc/rtctl/tokens.txt"] = tokens.String()
		execLine = fmt.Sprintf("%s -listen :%s -devices /etc/rtctl/devices.json -client-key %q -audit /var/log/rtctl-audit.log",
			dst, strings.TrimPrefix(cfg.port, ":"), cfg.clientKey)
		if cfg.tlsCert != "" {
			execLine += fmt.Sprintf(" -tls-cert %q -tls-key %q", cfg.tlsCert, cfg.tlsKey)
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
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
`, cfg.component, user, unitExtra, execLine)
	return &linuxPlan{unitName: unitName, binaryName: name, user: user, unit: unit, extraFiles: extra}, nil
}
