// win_task.go —— Windows 计划任务 XML 生成（纯函数，无 build 标签，
// 便于 dry-run 与单元测试；svc_windows.go 负责落盘与 schtasks 注册）。
package main

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"path/filepath"
	"unicode/utf16"
)

type taskVariable struct {
	Name  string `xml:"Name"`
	Value string `xml:"Value"`
}

type taskXML struct {
	XMLName          xml.Name `xml:"Task"`
	Version          string   `xml:"version,attr"`
	Xmlns            string   `xml:"xmlns,attr"`
	RegistrationInfo struct {
		Description string `xml:"Description"`
	} `xml:"RegistrationInfo"`
	Triggers struct {
		BootTrigger struct {
			Enabled string `xml:"Enabled"`
		} `xml:"BootTrigger"`
	} `xml:"Triggers"`
	Principals struct {
		Principal struct {
			ID        string `xml:"id,attr"`
			UserID    string `xml:"UserId"`
			LogonType string `xml:"LogonType"`
			RunLevel  string `xml:"RunLevel"`
		} `xml:"Principal"`
	} `xml:"Principals"`
	Settings struct {
		MultipleInstancesPolicy    string `xml:"MultipleInstancesPolicy"`
		DisallowStartIfOnBatteries string `xml:"DisallowStartIfOnBatteries"`
		StopIfGoingOnBatteries     string `xml:"StopIfGoingOnBatteries"`
		ExecutionTimeLimit         string `xml:"ExecutionTimeLimit"`
		RestartOnFailure           struct {
			Interval string `xml:"Interval"`
			Count    int    `xml:"Count"`
		} `xml:"RestartOnFailure"`
	} `xml:"Settings"`
	Actions struct {
		Context string `xml:"Context,attr"`
		Exec    struct {
			Command              string         `xml:"Command"`
			Arguments            string         `xml:"Arguments"`
			EnvironmentVariables *taskVariables `xml:"EnvironmentVariables,omitempty"`
		} `xml:"Exec"`
	} `xml:"Actions"`
}

type taskVariables struct {
	Variable []taskVariable `xml:"Variable"`
}

// winPlan 一次 Windows 安装的生成物。
type winPlan struct {
	taskName string            // 计划任务名
	exeName  string            // 安装目录下的可执行文件名
	exePath  string            // 完整路径
	args     string            // 任务参数
	extra    map[string]string // 额外文件：路径 -> 内容
}

// buildWinPlan 生成 Windows 安装计划（含任务参数）。
func buildWinPlan(cfg *installConfig, installDir string) (*winPlan, error) {
	plan := &winPlan{extra: map[string]string{}}
	switch cfg.component {
	case "agent":
		plan.exeName, plan.taskName = "rtctl-agent.exe", "rtctl-agent"
		plan.args = fmt.Sprintf("-listen %q -id %q", cfg.listen, cfg.id)
		if cfg.tlsCert != "" {
			plan.args += fmt.Sprintf(" -tls-cert %q -tls-key %q", cfg.tlsCert, cfg.tlsKey)
		}
		if cfg.allowSudo {
			plan.args += " -allow-sudo" // SYSTEM 已最高权限，仅为协议一致性
		}
	case "clientd":
		plan.exeName, plan.taskName = "rtctl-client.exe", "rtctl-clientd"
		devicesAbs, _ := filepath.Abs(cfg.devices)
		plan.args = fmt.Sprintf("-client-id clientd serve -listen %q -devices %q -api-key %q", cfg.httpListen, devicesAbs, cfg.apiKey)
		if cfg.allowSudo {
			plan.args += " -allow-sudo"
		}
	default:
		return nil, fmt.Errorf("未知组件: %s", cfg.component)
	}
	plan.exePath = filepath.Join(installDir, plan.exeName)
	return plan, nil
}

// buildTaskXML 生成计划任务 XML（UTF-16LE），agent 的 token 经任务环境变量注入。
func buildTaskXML(cfg *installConfig, exePath, args string) ([]byte, error) {
	t := taskXML{Version: "1.2", Xmlns: "http://schemas.microsoft.com/windows/2004/02/mit/task"}
	t.RegistrationInfo.Description = "rtctl " + cfg.component
	t.Triggers.BootTrigger.Enabled = "true"
	t.Principals.Principal.ID = "Author"
	t.Principals.Principal.UserID = "S-1-5-18"
	t.Principals.Principal.LogonType = "ServiceAccount"
	t.Principals.Principal.RunLevel = "HighestAvailable"
	t.Settings.MultipleInstancesPolicy = "IgnoreNew"
	t.Settings.DisallowStartIfOnBatteries = "false"
	t.Settings.StopIfGoingOnBatteries = "false"
	t.Settings.ExecutionTimeLimit = "PT0S"
	t.Settings.RestartOnFailure.Interval = "PT1M"
	t.Settings.RestartOnFailure.Count = 999
	t.Actions.Context = "Author"
	t.Actions.Exec.Command = exePath
	t.Actions.Exec.Arguments = args
	if cfg.component == "agent" {
		t.Actions.Exec.EnvironmentVariables = &taskVariables{
			Variable: []taskVariable{{Name: "RTCTL_TOKEN", Value: cfg.token}},
		}
	}
	raw, err := xml.MarshalIndent(t, "", "  ")
	if err != nil {
		return nil, err
	}
	// 计划任务 XML 要求 UTF-16 LE（带 BOM）
	var buf bytes.Buffer
	buf.Write([]byte{0xFF, 0xFE})
	for _, r := range string(raw) {
		for _, u := range utf16.Encode([]rune{r}) {
			buf.WriteByte(byte(u))
			buf.WriteByte(byte(u >> 8))
		}
	}
	return buf.Bytes(), nil
}
