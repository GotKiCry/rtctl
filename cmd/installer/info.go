// info.go —— rtctl-wizard info：打印可直接复制的连接信息
// （设备 ID / 监听地址 / token / clientd 设备清单片段 / 验证命令）。
package main

import (
	"fmt"
	"html"
	"os/exec"
	"regexp"
	"runtime"
	"strings"
)

// printInfo 打印本机 agent 的连接信息与 clientd（若已安装）的直控入口。
func printInfo() {
	fmt.Println("================ 连接信息（直接复制） ================")
	if runtime.GOOS == "windows" {
		printInfoWindows()
	} else {
		printInfoLinux()
	}
	fmt.Println("====================================================")
}

// printInfoLinux 从 systemd unit 提取 agent 接入信息（token 存于 Environment）。
func printInfoLinux() {
	execLine := unitLine("rtctl-agent", "ExecStart=")
	if execLine != "" {
		listen := argAfter(execLine, "-listen")
		id := argAfter(execLine, "-id")
		token := strings.Trim(strings.TrimPrefix(unitLine("rtctl-agent", "Environment=RTCTL_TOKEN="),
			"Environment=RTCTL_TOKEN="), "\"")
		ip := lanIPv4()
		if ip == "" {
			ip = "<本机IP>"
		}
		port := listen[strings.LastIndex(listen, ":"):]
		fmt.Printf("  设备 ID:   %s\n", id)
		fmt.Printf("  监听地址: %s\n", listen)
		fmt.Printf("  token:     %s\n", token)
		fmt.Println()
		fmt.Println("  ── clientd 设备清单片段（复制到控制机 devices.json 即可直连）──")
		fmt.Printf("  { \"devices\": [ { \"id\": %q, \"url\": \"ws://%s%s/ws\", \"token\": %q } ] }\n", id, ip, port, token)
		fmt.Println()
		fmt.Println("  ── 验证命令（任意有 client 的机器）──")
		fmt.Printf("  client -server ws://%s%s/ws exec -token %s 'uptime'\n", ip, port, token)
	} else {
		fmt.Println("agent 未安装（先运行: sudo ./rtctl-wizard）")
	}

	if cd := unitLine("rtctl-clientd", "ExecStart="); cd != "" {
		hl := argAfter(cd, "-listen")
		ak := argAfter(cd, "-api-key")
		fmt.Println()
		fmt.Println("  ── clientd（AI Agent 直控入口）──")
		fmt.Printf("  HTTP 地址: http://%s\n", hl)
		fmt.Printf("  API 密钥:  %s\n", ak)
		fmt.Printf("  调用示例: curl -H 'Authorization: Bearer %s' -d '{\"device_id\":\"<设备ID>\",\"cmd\":\"uptime\"}' http://%s/api/v1/exec\n", ak, hl)
	}
}

// printInfoWindows 从计划任务 XML 提取 agent 接入信息（token 存于任务环境变量）。
func printInfoWindows() {
	raw := taskXMLText("rtctl-agent")
	if raw != "" {
		args := html.UnescapeString(reGroup(raw, `(?s)<Arguments>(.*?)</Arguments>`))
		listen := argAfter(args, "-listen")
		id := argAfter(args, "-id")
		token := html.UnescapeString(reGroup(raw, `(?s)<Name>RTCTL_TOKEN</Name>\s*<Value>(.*?)</Value>`))
		ip := lanIPv4()
		if ip == "" {
			ip = "<本机IP>"
		}
		port := listen[strings.LastIndex(listen, ":"):]
		fmt.Printf("  设备 ID:   %s\n", id)
		fmt.Printf("  监听地址: %s\n", listen)
		fmt.Printf("  token:     %s\n", token)
		fmt.Println()
		fmt.Println("  ── clientd 设备清单片段（复制到控制机 devices.json 即可直连）──")
		fmt.Printf("  { \"devices\": [ { \"id\": %q, \"url\": \"ws://%s%s/ws\", \"token\": %q } ] }\n", id, ip, port, token)
		fmt.Println()
		fmt.Println("  ── 验证命令（任意有 client 的机器）──")
		fmt.Printf("  client.exe -server ws://%s%s/ws exec -token %s 'echo ok'\n", ip, port, token)
	} else {
		fmt.Println("agent 未安装（管理员运行向导先安装）")
	}

	if cd := taskXMLText("rtctl-clientd"); cd != "" {
		args := html.UnescapeString(reGroup(cd, `(?s)<Arguments>(.*?)</Arguments>`))
		hl := argAfter(args, "-listen")
		ak := argAfter(args, "-api-key")
		fmt.Println()
		fmt.Println("  ── clientd（AI Agent 直控入口）──")
		fmt.Printf("  HTTP 地址: http://%s\n", hl)
		fmt.Printf("  API 密钥:  %s\n", ak)
		fmt.Printf("  调用示例: curl -H 'Authorization: Bearer %s' -d '{\"device_id\":\"<设备ID>\",\"cmd\":\"uptime\"}' http://%s/api/v1/exec\n", ak, hl)
	}
}

// unitLine 返回 systemctl cat 输出中指定前缀的首行；未安装返回空串。
func unitLine(unit, prefix string) string {
	out, err := exec.Command("systemctl", "cat", unit).Output()
	if err != nil {
		return ""
	}
	for _, l := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(l, prefix) {
			return l
		}
	}
	return ""
}

// taskXMLText 返回 schtasks /Query /XML 的原始文本；未安装返回空串。
func taskXMLText(task string) string {
	out, err := exec.Command("schtasks", "/Query", "/TN", task, "/XML").Output()
	if err != nil {
		return ""
	}
	return string(out)
}

// argAfter 提取命令行中 flag 后的第一个参数（去掉包裹引号）。
func argAfter(line, flag string) string {
	i := strings.Index(line, flag)
	if i < 0 {
		return ""
	}
	fields := strings.Fields(line[i+len(flag):])
	if len(fields) == 0 {
		return ""
	}
	return strings.Trim(fields[0], "\"")
}

// reGroup 返回正则的第一个捕获组；未匹配返回空串。
func reGroup(s, pattern string) string {
	m := regexp.MustCompile(pattern).FindStringSubmatch(s)
	if len(m) < 2 {
		return ""
	}
	return m[1]
}
