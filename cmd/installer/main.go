// rtctl-wizard —— rtctl 二进制安装器（一条指令安装并运行）
//
// 命名避开 install/setup/update/patch 等词：Windows 会按安装器启发式
// 对这类文件名触发提权/拦截。
//
// 用法:
//
//	交互式（推荐）:  ./rtctl-wizard
//	   向导会引导选择组件（agent 直连/中继、clientd、server、client），
//	   引导填写端口 / token（可自动生成高熵或手动自定义）/ API 密钥等，
//	   装完立即运行并开机自启，结尾打印验证命令与可复制的设备清单片段。
//
//	非交互（脚本化）: ./rtctl-wizard --component agent --id web-01 --listen :8443 --gen-token
//	   --dry-run 只打印将执行的步骤，不实际安装。
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const ghBaseDefault = "https://raw.githubusercontent.com/GotKiCry/rtctl/main/bin"

var (
	reader = bufio.NewReader(os.Stdin)

	flComponent  = flag.String("component", "", "组件: agent / clientd / server / client")
	flID         = flag.String("id", "", "设备 ID")
	flToken      = flag.String("token", "", "设备 token")
	flGenToken   = flag.Bool("gen-token", false, "自动生成设备 token")
	flListen     = flag.String("listen", "", "agent 直连监听地址（如 :8443）")
	flServerURL  = flag.String("server-url", "", "中继服务器地址（agent 拨出 / clientd 中继）")
	flPort       = flag.String("port", "8443", "server 中继监听端口")
	flDeviceIDs  = flag.String("device-ids", "", "server 设备 ID 列表（逗号分隔）")
	flClientKey  = flag.String("client-key", "", "中继客户端密钥")
	flDevices    = flag.String("devices", "devices.json", "clientd 设备清单文件")
	flAPIKey     = flag.String("api-key", "", "clientd API 密钥")
	flGenAPIKey  = flag.Bool("gen-api-key", false, "自动生成 clientd API 密钥")
	flHTTPListen = flag.String("http-listen", "127.0.0.1:18080", "clientd HTTP 监听地址")
	flTLSCert    = flag.String("tls-cert", "", "TLS 证书路径")
	flTLSKey     = flag.String("tls-key", "", "TLS 私钥路径")
	flUser       = flag.String("user", "", "运行账户（Linux，默认自动创建低权限用户）")
	flDryRun     = flag.Bool("dry-run", false, "只打印步骤，不实际安装")
	flYes        = flag.Bool("yes", false, "跳过确认")
	flGhBase     = flag.String("gh-base", ghBaseDefault, "二进制下载源")
	flGhToken    = flag.String("gh-token", "", "下载源访问 token")
)

func main() {
	flag.Parse()
	log.SetFlags(0)

	cfg, err := wizard()
	if err != nil {
		log.Fatalf("错误: %v", err)
	}
	if err := runInstall(cfg); err != nil {
		log.Fatalf("安装失败: %v", err)
	}
}

// installConfig 一次安装的参数（向导/参数填充）。
type installConfig struct {
	component  string
	id         string
	token      string
	listen     string // agent 直连
	serverURL  string // agent 拨出 / clientd 中继
	port       string
	deviceIDs  []string
	clientKey  string
	devices    string
	apiKey     string
	httpListen string
	tlsCert    string
	tlsKey     string
	user       string
	genToken   bool
}

func ask(prompt, def string) string {
	if def != "" {
		fmt.Printf("%s [%s]: ", prompt, def)
	} else {
		fmt.Printf("%s: ", prompt)
	}
	line, err := reader.ReadString('\n')
	if err != nil && len(strings.TrimSpace(line)) == 0 {
		if def != "" {
			return def
		}
		log.Fatal("输入读取失败")
	}
	line = strings.TrimSpace(line)
	if line == "" {
		return def
	}
	return line
}

func askChoice(prompt string, options []string, def int) int {
	fmt.Println(prompt)
	for i, o := range options {
		mark := " "
		if i == def {
			mark = "*"
		}
		fmt.Printf("  %s [%d] %s\n", mark, i+1, o)
	}
	ans := ask("请选择", fmt.Sprintf("%d", def+1))
	for i := range options {
		if ans == fmt.Sprintf("%d", i+1) {
			return i
		}
	}
	return def
}

func askYesNo(prompt string, def bool) bool {
	suffix := " [Y/n]: "
	if !def {
		suffix = " [y/N]: "
	}
	fmt.Printf("%s%s", prompt, suffix)
	line, _ := reader.ReadString('\n')
	line = strings.TrimSpace(strings.ToLower(line))
	if line == "" {
		return def
	}
	return line == "y" || line == "yes"
}

func genToken() string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		log.Fatalf("生成随机 token 失败: %v", err)
	}
	return hex.EncodeToString(b)
}

// wizard 交互式收集安装参数（flags 已给的跳过提问）。
func wizard() (*installConfig, error) {
	cfg := &installConfig{component: *flComponent}

	if cfg.component == "" {
		cfg.component = []string{"agent", "clientd", "server", "client"}[askChoice(
			"=== rtctl 一键安装向导 ===\n选择要安装的组件:",
			[]string{
				"agent 被控端（装在目标服务器上，被控制）",
				"clientd 控制服务（装在操作机上，给 AI Agent 调用）",
				"server 中继（目标机在 NAT 后无法直连时才需要）",
				"client 客户端 CLI（仅下载二进制）",
			}, 0)]
	}
	switch cfg.component {
	case "agent":
		cfg.id = *flID
		if cfg.id == "" {
			cfg.id = ask("设备 ID（唯一名称，如 jp-tokyo-01）", "")
		}
		if *flListen != "" || *flServerURL != "" {
			cfg.listen, cfg.serverURL = *flListen, *flServerURL
		} else {
			mode := askChoice("接入方式:",
				[]string{"直连（推荐：目标机可被访问，无需中继）", "中继（NAT 后无法直连）"}, 0)
			if mode == 0 {
				cfg.listen = ask("监听端口", ":8443")
			} else {
				cfg.serverURL = ask("中继服务器地址", "wss://中继IP:8443/ws?role=agent")
			}
		}
		if cfg.listen != "" && !strings.Contains(cfg.listen, ":") {
			cfg.listen = ":" + cfg.listen
		}
		cfg.token = *flToken
		if cfg.token == "" {
			if *flGenToken {
				cfg.token = genToken()
			} else {
				choice := askChoice("设备 token:",
					[]string{"自动生成高熵 token（推荐）", "手动输入"}, 0)
				if choice == 0 {
					cfg.token = genToken()
				} else {
					cfg.token = ask("请输入 token", "")
					if cfg.token == "" {
						return nil, errors.New("token 不能为空")
					}
				}
			}
		}
		cfg.tlsCert, cfg.tlsKey = *flTLSCert, *flTLSKey
		if cfg.listen != "" && cfg.tlsCert == "" && askYesNo("启用 WSS（需要证书路径）?", false) {
			cfg.tlsCert = ask("证书路径", "")
			cfg.tlsKey = ask("私钥路径", "")
		}
		cfg.user = *flUser
	case "clientd":
		cfg.httpListen = *flHTTPListen
		if !strings.Contains(cfg.httpListen, ":") {
			cfg.httpListen = "127.0.0.1:" + cfg.httpListen
		}
		cfg.devices = *flDevices
		cfg.devices = ask("设备清单文件路径（先准备好，条目带 url 直连、不带 url 经中继）", cfg.devices)
		if _, err := os.Stat(cfg.devices); err != nil {
			return nil, fmt.Errorf("设备清单不存在: %s", cfg.devices)
		}
		cfg.serverURL = *flServerURL
		if cfg.serverURL == "" && askYesNo("清单里有不带 url 的设备（需经中继）?", false) {
			cfg.serverURL = ask("中继服务器地址", "wss://中继IP:8443/ws?role=client")
			cfg.clientKey = ask("中继客户端密钥", "")
		}
		cfg.apiKey = *flAPIKey
		if cfg.apiKey == "" {
			if *flGenAPIKey {
				cfg.apiKey = genToken()
			} else {
				choice := askChoice("HTTP API 密钥:",
					[]string{"自动生成（推荐）", "手动输入"}, 0)
				if choice == 0 {
					cfg.apiKey = genToken()
				} else {
					cfg.apiKey = ask("请输入 API 密钥", "")
				}
			}
		}
		cfg.user = *flUser
	case "server":
		cfg.port = *flPort
		if !strings.Contains(cfg.port, ":") {
			cfg.port = ":" + cfg.port
		}
		if *flDeviceIDs != "" {
			for _, id := range strings.Split(*flDeviceIDs, ",") {
				if id = strings.TrimSpace(id); id != "" {
					cfg.deviceIDs = append(cfg.deviceIDs, id)
				}
			}
		}
		if len(cfg.deviceIDs) == 0 {
			ids := ask("设备 ID 列表（逗号分隔，如 jp-tokyo-01,web-01）", "")
			for _, id := range strings.Split(ids, ",") {
				if id = strings.TrimSpace(id); id != "" {
					cfg.deviceIDs = append(cfg.deviceIDs, id)
				}
			}
		}
		if len(cfg.deviceIDs) == 0 {
			return nil, errors.New("至少需要一个设备 ID")
		}
		cfg.clientKey = *flClientKey
		if cfg.clientKey == "" {
			if *flGenToken {
				cfg.clientKey = genToken()
			} else {
				choice := askChoice("客户端密钥（client/clientd 连接中继用）:",
					[]string{"自动生成（推荐）", "手动输入"}, 0)
				if choice == 0 {
					cfg.clientKey = genToken()
				} else {
					cfg.clientKey = ask("请输入客户端密钥", "")
				}
			}
		}
		cfg.tlsCert, cfg.tlsKey = *flTLSCert, *flTLSKey
		if cfg.tlsCert == "" && askYesNo("启用 WSS（需要证书路径）?", false) {
			cfg.tlsCert = ask("证书路径", "")
			cfg.tlsKey = ask("私钥路径", "")
		}
		cfg.user = *flUser
	case "client":
		// 仅下载，无参数
	default:
		return nil, fmt.Errorf("未知组件: %s（agent / clientd / server / client）", cfg.component)
	}
	return cfg, nil
}

func arch() string {
	switch runtime.GOARCH {
	case "amd64", "arm64":
		return runtime.GOARCH
	default:
		return ""
	}
}

func binaryName(component string) string {
	base := map[string]string{"agent": "agent", "server": "server", "client": "client", "clientd": "client"}
	if runtime.GOOS == "windows" {
		return base[component] + ".exe"
	}
	return fmt.Sprintf("%s-%s-%s", base[component], runtime.GOOS, arch())
}

// fetchBinary 取组件二进制：本地 ./bin 优先，否则从 GH_BASE 下载（校验魔数）。
func fetchBinary(name string) (string, error) {
	local := filepath.Join("bin", name)
	if fi, err := os.Stat(local); err == nil && fi.Size() > 0 {
		return local, nil
	}
	fmt.Printf("[rtctl] 下载 %s ...\n", name)
	tmp, err := os.CreateTemp("", name+"-*.bin")
	if err != nil {
		return "", err
	}
	defer func() {
		if err != nil {
			tmp.Close()
			os.Remove(tmp.Name())
		}
	}()
	req, err := http.NewRequest("GET", *flGhBase+"/"+name, nil)
	if err != nil {
		return "", err
	}
	if *flGhToken != "" {
		req.Header.Set("Authorization", "Bearer "+*flGhToken)
	}
	client := &http.Client{Timeout: 10 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("下载失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("下载失败: HTTP %d（私有仓库请设 --gh-token）", resp.StatusCode)
	}
	if _, err := io.Copy(tmp, resp.Body); err != nil {
		return "", err
	}
	tmp.Close()
	head := make([]byte, 4)
	f, err := os.Open(tmp.Name())
	if err != nil {
		return "", err
	}
	n, _ := f.Read(head)
	f.Close()
	ok := false
	if runtime.GOOS == "windows" {
		ok = n == 4 && head[0] == 'M' && head[1] == 'Z'
	} else {
		ok = n == 4 && head[0] == 0x7f && head[1] == 'E' && head[2] == 'L' && head[3] == 'F'
	}
	if !ok {
		os.Remove(tmp.Name())
		return "", errors.New("下载内容不是有效二进制")
	}
	os.Chmod(tmp.Name(), 0o755)
	return tmp.Name(), nil
}

// runInstall 按组件安装并启动。
func runInstall(cfg *installConfig) error {
	if cfg.component == "client" {
		name := binaryName("client")
		path, err := fetchBinary(name)
		if err != nil {
			return err
		}
		if *flDryRun {
			fmt.Printf("[dry-run] 仅下载: %s -> %s\n", name, path)
			return nil
		}
		dst := "rtctl-client"
		if runtime.GOOS == "windows" {
			dst = "rtctl-client.exe"
		}
		if path != filepath.Join("bin", name) {
			copyFile(path, dst)
			os.Remove(path)
		}
		fmt.Printf("✔ client 就绪: %s\n  用法: ./%s -server ws://<目标或中继>/ws [exec|list|file-put|...]\n", dst, dst)
		return nil
	}

	name := binaryName(cfg.component)
	if name == "" {
		return fmt.Errorf("不支持的架构: %s/%s", runtime.GOOS, runtime.GOARCH)
	}
	binPath, err := fetchBinary(name)
	if err != nil {
		return err
	}
	if *flDryRun {
		fmt.Printf("[dry-run] 组件=%s 二进制=%s\n", cfg.component, binPath)
		if plan, err := buildLinuxPlan(cfg); err == nil {
			fmt.Println("[dry-run] systemd unit 内容:")
			fmt.Println(strings.Repeat("-", 50))
			fmt.Println(plan.unit)
			for path, content := range plan.extraFiles {
				fmt.Printf("[dry-run] 将写入 %s (0600):\n%s\n", path, content)
			}
			fmt.Println(strings.Repeat("-", 50))
			fmt.Printf("[dry-run] systemctl enable --now %s（开机自启 + 立即运行）\n", plan.unitName)
		}
	}
	return installService(cfg, binPath)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

// printSummary 安装完成后的引导信息。
func printSummary(cfg *installConfig) {
	fmt.Println()
	fmt.Println("================ 安装完成 ================")
	switch cfg.component {
	case "agent":
		if cfg.listen != "" {
			fmt.Printf("✔ agent 直连模式已安装并启动：监听 %s（开机自启，无需中继）\n", cfg.listen)
			fmt.Printf("  设备 token: %s（请妥善保存，控制端需要它）\n", cfg.token)
			fmt.Println()
			fmt.Println("  验证（任意装有 client 的机器）:")
			fmt.Printf("    client -server ws://<本机IP>%s/ws exec -token %s 'uptime'\n", cfg.listen, cfg.token)
			fmt.Println()
			fmt.Println("  clientd 设备清单片段（复制到操作机 devices.json 即可直连）:")
			fmt.Printf("    { \"devices\": [ { \"id\": %q, \"url\": \"ws://<本机IP>%s/ws\", \"token\": %q } ] }\n",
				cfg.id, cfg.listen, cfg.token)
			fmt.Println("  （生产环境建议重装时启用 WSS）")
		} else {
			fmt.Printf("✔ agent 中继模式已安装并启动（开机自启，自动重连）\n")
			fmt.Printf("  日志: journalctl -u rtctl-agent -f\n")
		}
	case "clientd":
		fmt.Printf("✔ clientd 已安装并启动: http://%s（开机自启）\n", cfg.httpListen)
		fmt.Printf("  API 密钥: %s（Authorization: Bearer %s）\n", cfg.apiKey, cfg.apiKey)
		fmt.Println()
		fmt.Println("  AI Agent 调用示例:")
		fmt.Printf("    curl -H 'Authorization: Bearer %s' -d '{\"device_id\":\"<设备ID>\",\"cmd\":\"uptime\",\"timeout_ms\":10000}' http://%s/api/v1/exec\n",
			cfg.apiKey, cfg.httpListen)
		fmt.Printf("    curl -H 'Authorization: Bearer %s' http://%s/api/v1/devices\n", cfg.apiKey, cfg.httpListen)
	case "server":
		fmt.Printf("✔ 中继已安装并启动：监听 %s（开机自启）\n", cfg.port)
		fmt.Printf("  客户端密钥: %s\n", cfg.clientKey)
		fmt.Println("  设备 token 已保存到 /etc/rtctl/tokens.txt（或 C:\\Program Files\\rtctl\\tokens.txt），每台 agent 一个:")
		for _, id := range cfg.deviceIDs {
			fmt.Printf("    设备 %s: 见 tokens.txt 对应行\n", id)
		}
		fmt.Println()
		fmt.Println("  被控机安装（直连不需要中继；NAT 场景用拨出模式）:")
		fmt.Printf("    ./rtctl-wizard --component agent --server-url wss://<中继IP>%s/ws?role=agent --id <设备ID> --token <对应token>\n", cfg.port)
	}
	fmt.Println("==========================================")
}
