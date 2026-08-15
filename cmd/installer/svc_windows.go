//go:build windows

package main

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"os"
	"os/exec"
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

// installService Windows：拷贝二进制 + 计划任务 + 立即运行。
func installService(cfg *installConfig, binPath string) error {
	var (
		exeName string
		task    string
		args    string
		env     *taskVariables
	)
	installDir := `C:\Program Files\rtctl`
	switch cfg.component {
	case "agent":
		exeName, task = "rtctl-agent.exe", "rtctl-agent"
		if cfg.listen != "" {
			args = fmt.Sprintf("-listen %q -id %q", cfg.listen, cfg.id)
			if cfg.tlsCert != "" {
				args += fmt.Sprintf(" -tls-cert %q -tls-key %q", cfg.tlsCert, cfg.tlsKey)
			}
		} else {
			args = fmt.Sprintf("-server %q -id %q", cfg.serverURL, cfg.id)
		}
		env = &taskVariables{Variable: []taskVariable{{Name: "RTCTL_TOKEN", Value: cfg.token}}}
	case "clientd":
		exeName, task = "rtctl-client.exe", "rtctl-clientd"
		if cfg.serverURL != "" {
			args = fmt.Sprintf("-server %q -key %q", cfg.serverURL, cfg.clientKey)
		}
		devicesAbs, _ := filepath.Abs(cfg.devices)
		args += fmt.Sprintf(" -client-id clientd serve -listen %q -devices %q -api-key %q", cfg.httpListen, devicesAbs, cfg.apiKey)
	case "server":
		exeName, task = "rtctl-server.exe", "rtctl-server"
		// 设备清单与 token 生成到安装目录
		var tokens bytes.Buffer
		var devs bytes.Buffer
		devs.WriteString(`{ "devices": [`)
		for i, id := range cfg.deviceIDs {
			tok := genToken()
			if i > 0 {
				devs.WriteString(",")
			}
			fmt.Fprintf(&devs, ` { "id": %q, "token": %q }`, id, tok)
			fmt.Fprintf(&tokens, "设备 %s 的 token: %s\r\n", id, tok)
		}
		devs.WriteString(" ] }")
		devicesPath := filepath.Join(installDir, "devices.json")
		if !*flDryRun {
			os.MkdirAll(installDir, 0o755)
			os.WriteFile(devicesPath, devs.Bytes(), 0o600)
			os.WriteFile(filepath.Join(installDir, "tokens.txt"), tokens.Bytes(), 0o600)
		}
		args = fmt.Sprintf("-listen :%s -devices %q -client-key %q -audit %q",
			trimPort(cfg.port), devicesPath, cfg.clientKey, filepath.Join(installDir, "audit.log"))
		if cfg.tlsCert != "" {
			args += fmt.Sprintf(" -tls-cert %q -tls-key %q", cfg.tlsCert, cfg.tlsKey)
		}
	default:
		return errors.New("未知组件")
	}

	if *flDryRun {
		return nil
	}
	if err := os.MkdirAll(installDir, 0o755); err != nil {
		return err
	}
	dst := filepath.Join(installDir, exeName)
	if err := copyFile(binPath, dst); err != nil {
		return fmt.Errorf("安装二进制失败: %w", err)
	}
	if binPath != dst {
		os.Remove(binPath)
	}

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
	t.Actions.Exec.Command = dst
	t.Actions.Exec.Arguments = args
	t.Actions.Exec.EnvironmentVariables = env

	raw, err := xml.MarshalIndent(t, "", "  ")
	if err != nil {
		return err
	}
	// 计划任务 XML 要求 UTF-16 LE
	var buf bytes.Buffer
	buf.Write([]byte{0xFF, 0xFE})
	for _, r := range string(raw) {
		for _, u := range utf16.Encode([]rune{r}) {
			buf.WriteByte(byte(u))
			buf.WriteByte(byte(u >> 8))
		}
	}
	xmlPath := filepath.Join(os.TempDir(), task+".xml")
	if err := os.WriteFile(xmlPath, buf.Bytes(), 0o600); err != nil {
		return err
	}
	defer os.Remove(xmlPath)

	if out, err := exec.Command("schtasks", "/Create", "/TN", task, "/XML", xmlPath, "/F").CombinedOutput(); err != nil {
		return fmt.Errorf("注册计划任务失败（需管理员权限）: %v %s", err, out)
	}
	if out, err := exec.Command("schtasks", "/Run", "/TN", task).CombinedOutput(); err != nil {
		return fmt.Errorf("启动任务失败: %v %s", err, out)
	}
	printSummary(cfg)
	return nil
}

func trimPort(port string) string {
	for len(port) > 0 && port[0] == ':' {
		port = port[1:]
	}
	return port
}
