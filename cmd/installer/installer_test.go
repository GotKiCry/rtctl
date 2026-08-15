package main

import (
	"encoding/json"
	"strings"
	"testing"
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
