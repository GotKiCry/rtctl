package main

import (
	"encoding/xml"
	"strings"
	"testing"
	"unicode/utf16"
)

func TestBuildLinuxPlanAgentDirect(t *testing.T) {
	cfg := &installConfig{component: "agent", id: "jp-tokyo-01", listen: ":8443", token: "tok-abc"}
	plan, err := buildLinuxPlan(cfg)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`ExecStart=/usr/local/bin/rtctl-agent -listen ":8443" -id "jp-tokyo-01"`,
		"Environment=RTCTL_TOKEN=tok-abc",
		"User=rtctl-agent",
		"Restart=always",
		"WantedBy=multi-user.target",
		"NoNewPrivileges=true",
	} {
		if !strings.Contains(plan.unit, want) {
			t.Errorf("unit 缺少 %q\n%s", want, plan.unit)
		}
	}
	if plan.unitName != "rtctl-agent" {
		t.Errorf("unitName=%s", plan.unitName)
	}
	if plan.sudoers != "" {
		t.Errorf("未授权提权时不应生成 sudoers: %s", plan.sudoers)
	}
}

func TestBuildLinuxPlanAgentAllowSudo(t *testing.T) {
	cfg := &installConfig{component: "agent", id: "jp-tokyo-01", listen: ":8443", token: "tok-abc", allowSudo: true}
	plan, err := buildLinuxPlan(cfg)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"-allow-sudo",
		"NoNewPrivileges=false",
	} {
		if !strings.Contains(plan.unit, want) {
			t.Errorf("unit 缺少 %q\n%s", want, plan.unit)
		}
	}
	if !strings.Contains(plan.sudoers, "rtctl-agent ALL=(ALL) NOPASSWD: /bin/sh, /usr/bin/sh, /usr/bin/kill, /bin/kill") {
		t.Errorf("sudoers 内容不对:\n%s", plan.sudoers)
	}
}

func TestBuildLinuxPlanClientdAllowSudo(t *testing.T) {
	cfg := &installConfig{component: "clientd", httpListen: "127.0.0.1:18080", apiKey: "key-1", allowSudo: true}
	plan, err := buildLinuxPlan(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(plan.unit, "-allow-sudo") {
		t.Errorf("clientd unit 应含 -allow-sudo\n%s", plan.unit)
	}
	if !strings.Contains(plan.unit, "NoNewPrivileges=true") {
		t.Error("clientd 不需提权，NoNewPrivileges 应保持 true")
	}
	if plan.sudoers != "" {
		t.Errorf("clientd 不应生成 sudoers: %s", plan.sudoers)
	}
}

func TestBuildLinuxPlanClientd(t *testing.T) {
	cfg := &installConfig{component: "clientd", httpListen: "127.0.0.1:18080", apiKey: "key-1", devices: "devices.json"}
	plan, err := buildLinuxPlan(cfg)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`serve -listen "127.0.0.1:18080"`,
		`-devices /etc/rtctl/clientd-devices.json`,
		`-api-key "key-1"`,
		"User=rtctl",
	} {
		if !strings.Contains(plan.unit, want) {
			t.Errorf("unit 缺少 %q\n%s", want, plan.unit)
		}
	}
	if plan.unitName != "rtctl-clientd" {
		t.Errorf("unitName=%s", plan.unitName)
	}
}

func TestBuildLinuxPlanUnknown(t *testing.T) {
	if _, err := buildLinuxPlan(&installConfig{component: "nope"}); err == nil {
		t.Error("未知组件应报错")
	}
}

func TestArgAfter(t *testing.T) {
	line := `-listen ":8443" -id "jp-tokyo-01" -tls-cert "/a b/c.pem"`
	for flag, want := range map[string]string{
		"-listen":   ":8443",
		"-id":       "jp-tokyo-01",
		"-tls-cert": "/a", // 空格在引号内：解析器只取第一个空白分隔 token（listen/id/token 不含空格，够用）
	} {
		if got := argAfter(line, flag); got != want {
			t.Errorf("argAfter(%q)=%q want %q", flag, got, want)
		}
	}
	if got := argAfter(line, "-nope"); got != "" {
		t.Errorf("未知 flag 应返回空串，got %q", got)
	}
}

func TestReGroup(t *testing.T) {
	raw := `<Arguments>-listen &quot;:8443&quot;</Arguments>`
	if got := reGroup(raw, `(?s)<Arguments>(.*?)</Arguments>`); got != `-listen &quot;:8443&quot;` {
		t.Errorf("reGroup=%q", got)
	}
	if got := reGroup("no match", `(?s)<Arguments>(.*?)</Arguments>`); got != "" {
		t.Errorf("未匹配应返回空串，got %q", got)
	}
}

func TestBuildWinPlanAgentDirect(t *testing.T) {
	cfg := &installConfig{component: "agent", id: "jp-tokyo-01", listen: ":8443", token: "tok-win"}
	plan, err := buildWinPlan(cfg, `C:\Program Files\rtctl`)
	if err != nil {
		t.Fatal(err)
	}
	if plan.taskName != "rtctl-agent" || plan.exeName != "rtctl-agent.exe" {
		t.Errorf("taskName/exeName 不对: %+v", plan)
	}
	if !strings.Contains(plan.args, `-listen ":8443" -id "jp-tokyo-01"`) {
		t.Errorf("args 不对: %s", plan.args)
	}
}

func TestBuildTaskXMLAgent(t *testing.T) {
	cfg := &installConfig{component: "agent", id: "jp-tokyo-01", listen: ":8443", token: "tok-1"}
	raw, err := buildTaskXML(cfg, `C:\Program Files\rtctl\rtctl-agent.exe`, `-listen ":8443" -id "jp-tokyo-01"`)
	if err != nil {
		t.Fatal(err)
	}
	// UTF-16LE BOM 校验
	if len(raw) < 2 || raw[0] != 0xFF || raw[1] != 0xFE {
		t.Fatal("任务 XML 不是 UTF-16LE（缺 BOM）")
	}
	// 解码回 UTF-8 并反序列化验证结构
	u16 := make([]uint16, (len(raw)-2)/2)
	for i := 0; i < len(u16); i++ {
		u16[i] = uint16(raw[2+i*2]) | uint16(raw[2+i*2+1])<<8
	}
	utf8Raw := []byte(string(utf16.Decode(u16)))
	var task taskXML
	if err := xml.Unmarshal(utf8Raw, &task); err != nil {
		t.Fatalf("XML 反序列化失败: %v\n%s", err, utf8Raw)
	}
	if task.Triggers.BootTrigger.Enabled != "true" {
		t.Error("缺少开机触发")
	}
	if task.Principals.Principal.UserID != "S-1-5-18" {
		t.Errorf("任务账户不对: %s", task.Principals.Principal.UserID)
	}
	if task.Settings.RestartOnFailure.Interval != "PT1M" {
		t.Error("缺少崩溃重试")
	}
	if task.Actions.Exec.Command != `C:\Program Files\rtctl\rtctl-agent.exe` {
		t.Errorf("Command 不对: %s", task.Actions.Exec.Command)
	}
	if task.Actions.Exec.EnvironmentVariables == nil || len(task.Actions.Exec.EnvironmentVariables.Variable) != 1 {
		t.Fatal("缺少任务环境变量")
	}
	v := task.Actions.Exec.EnvironmentVariables.Variable[0]
	if v.Name != "RTCTL_TOKEN" || v.Value != "tok-1" {
		t.Errorf("环境变量不对: %+v", v)
	}
}

func TestBuildTaskXMLClientdNoEnv(t *testing.T) {
	cfg := &installConfig{component: "clientd", apiKey: "k1", httpListen: "127.0.0.1:18080"}
	raw, err := buildTaskXML(cfg, `C:\Program Files\rtctl\rtctl-client.exe`, `serve`)
	if err != nil {
		t.Fatal(err)
	}
	u16 := make([]uint16, (len(raw)-2)/2)
	for i := 0; i < len(u16); i++ {
		u16[i] = uint16(raw[2+i*2]) | uint16(raw[2+i*2+1])<<8
	}
	var task taskXML
	if err := xml.Unmarshal([]byte(string(utf16.Decode(u16))), &task); err != nil {
		t.Fatal(err)
	}
	if task.Actions.Exec.EnvironmentVariables != nil {
		t.Error("clientd 任务不应有环境变量（api-key 走参数）")
	}
}
