package main

import (
	"encoding/json"
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
}

func TestBuildLinuxPlanAgentRelay(t *testing.T) {
	cfg := &installConfig{component: "agent", id: "web-01", serverURL: "wss://relay:8443/ws?role=agent", token: "t1"}
	plan, err := buildLinuxPlan(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(plan.unit, `-server "wss://relay:8443/ws?role=agent" -id "web-01"`) {
		t.Errorf("unit 缺少中继参数:\n%s", plan.unit)
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

func TestBuildLinuxPlanClientdRelay(t *testing.T) {
	cfg := &installConfig{component: "clientd", serverURL: "wss://relay:8443/ws?role=client", clientKey: "ck", apiKey: "k", httpListen: "127.0.0.1:18080"}
	plan, err := buildLinuxPlan(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(plan.unit, `-server "wss://relay:8443/ws?role=client" -key "ck"`) {
		t.Errorf("unit 缺少中继接入参数:\n%s", plan.unit)
	}
}

func TestBuildLinuxPlanServer(t *testing.T) {
	cfg := &installConfig{component: "server", deviceIDs: []string{"jp-tokyo-01", "web-01"}, port: ":8443", clientKey: "ck-1"}
	plan, err := buildLinuxPlan(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(plan.unit, `-client-key "ck-1"`) {
		t.Errorf("unit 缺少 client-key:\n%s", plan.unit)
	}
	if !strings.Contains(plan.unit, `-listen :8443`) {
		t.Errorf("unit 缺少端口:\n%s", plan.unit)
	}
	devicesRaw, ok := plan.extraFiles["/etc/rtctl/devices.json"]
	if !ok {
		t.Fatal("缺少 devices.json")
	}
	var devices struct {
		Devices []struct {
			ID    string `json:"id"`
			Token string `json:"token"`
		} `json:"devices"`
	}
	if err := json.Unmarshal([]byte(devicesRaw), &devices); err != nil {
		t.Fatalf("devices.json 不是合法 JSON: %v\n%s", err, devicesRaw)
	}
	if len(devices.Devices) != 2 || devices.Devices[0].ID != "jp-tokyo-01" || devices.Devices[1].ID != "web-01" {
		t.Errorf("设备列表不对: %+v", devices.Devices)
	}
	if devices.Devices[0].Token == "" || devices.Devices[0].Token == devices.Devices[1].Token {
		t.Errorf("token 生成有问题: %+v", devices.Devices)
	}
	tokens := plan.extraFiles["/etc/rtctl/tokens.txt"]
	if !strings.Contains(tokens, "jp-tokyo-01") || !strings.Contains(tokens, "web-01") {
		t.Errorf("tokens.txt 缺少设备: %s", tokens)
	}
}

func TestBuildLinuxPlanUnknown(t *testing.T) {
	if _, err := buildLinuxPlan(&installConfig{component: "nope"}); err == nil {
		t.Error("未知组件应报错")
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
