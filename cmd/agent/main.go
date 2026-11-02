// rtctl-agent 被控端：部署在目标 Linux / Windows 设备上。
// 直连模式：agent 自带 WS 服务端，本机 client 直接连接。
//
// 启动方式：
//
//	./rtctl-agent -init      # 生成 agent.conf（含随机 token）并打印连接信息
//	./rtctl-agent            # 后台运行，确认监听就绪后返回
//	./rtctl-agent -foreground # 前台运行，供调试或服务管理器托管
//	./rtctl-agent -listen :8443 -id node-01 -token <token>   # 纯命令行
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"rtctl/internal/agent"
	"rtctl/internal/console"
)

const configName = "agent.conf"

// cfg agent 配置。字段对应 agent.conf 的 key。
type cfg struct {
	listen    string
	id        string
	token     string
	tlsCert   string
	tlsKey    string
	allowSudo bool
	wsPath    string
}

// firewallResult 各平台 firewall_*.go 的 openFirewallPort 返回值：
// summary 为单行摘要（进启动块），detail 为附加提示（可为空）。
type firewallResult struct {
	summary string
	detail  string
}

// loadConfig 解析 agent.conf（key = value，# 或 ; 注释，空行忽略）。
func loadConfig(path string) (cfg, error) {
	var c cfg
	f, err := os.Open(path)
	if err != nil {
		return c, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "listen":
			c.listen = strings.TrimSpace(v)
		case "id":
			c.id = strings.TrimSpace(v)
		case "token":
			c.token = strings.TrimSpace(v)
		case "tls_cert":
			c.tlsCert = strings.TrimSpace(v)
		case "tls_key":
			c.tlsKey = strings.TrimSpace(v)
		case "allow_sudo":
			c.allowSudo, _ = strconv.ParseBool(strings.TrimSpace(v))
		case "ws_path":
			c.wsPath = strings.TrimSpace(v)
		}
	}
	return c, sc.Err()
}

// writeConfig 写配置（0600：token 属凭据）。
func writeConfig(path string, c cfg) error {
	content := fmt.Sprintf("# rtctl-agent 配置（token 即设备钥匙，请勿外泄）\n"+
		"listen = %s\n"+
		"id = %s\n"+
		"token = %s\n"+
		"tls_cert = %s\n"+
		"tls_key = %s\n"+
		"allow_sudo = %v\n"+
		"ws_path = %s\n", c.listen, c.id, c.token, c.tlsCert, c.tlsKey, c.allowSudo, c.wsPath)
	return os.WriteFile(path, []byte(content), 0o600)
}

// homeConfigPath 返回用户级配置文件路径：~/.rtctl/agent.conf。
// 配置（含 token 凭据）统一放在用户目录下，多个部署/多用户不会互相覆盖。
func homeConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".rtctl", configName)
}

// defaultConfigPath 返回默认配置路径，查找顺序：
//  1. ~/.rtctl/agent.conf        —— 推荐位置（-init 也写这里）
//  2. exe 同目录 agent.conf      —— 便携/旧版部署兼容
//  3. 当前工作目录 agent.conf    —— 旧版部署兼容
//  4. 都没有时返回 ~/.rtctl/agent.conf（作为 -init 写入目标 / 报错提示路径）
func defaultConfigPath() string {
	if p := homeConfigPath(); p != "" {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	if exe, err := os.Executable(); err == nil {
		p := filepath.Join(filepath.Dir(exe), configName)
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	legacy := filepath.Join(".", configName)
	if _, err := os.Stat(legacy); err == nil {
		return legacy
	}
	if p := homeConfigPath(); p != "" {
		return p
	}
	return legacy
}

// genToken 生成高熵 token（32 字节 = 64 hex 字符）。
func genToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// hostnameOrDefault 取主机名（供默认设备 ID）。
func hostnameOrDefault() string {
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return "node"
}

// localIPv4s 枚举本机 IPv4 地址（非回环优先，回环最后），启动时提示"该用什么地址连我"。
// 仅用标准库网卡枚举，返回失败时退化为 127.0.0.1。
func localIPv4s() []string {
	var out []string
	if ifs, err := net.Interfaces(); err == nil {
		for _, ifi := range ifs {
			if ifi.Flags&net.FlagUp == 0 {
				continue
			}
			addrs, err := ifi.Addrs()
			if err != nil {
				continue
			}
			for _, a := range addrs {
				ipn, ok := a.(*net.IPNet)
				if !ok {
					continue
				}
				ip4 := ipn.IP.To4()
				if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
					continue
				}
				out = append(out, ip4.String())
			}
		}
	}
	if len(out) == 0 {
		return []string{"127.0.0.1"}
	}
	return append(out, "127.0.0.1")
}

// printStartup 格式化打印启动信息：监听地址、本机可用地址、防火墙状态、连接示例。
// showToken=false 时不打印 token（避免 token 进入日志采集，如 journald）。
func printStartup(c cfg, configPath, fwSummary string, showToken bool) {
	schema := "ws"
	if c.tlsCert != "" {
		schema = "wss"
	}
	wsPath := c.wsPath
	if wsPath == "" {
		wsPath = "/ws"
	}
	host, port, perr := net.SplitHostPort(c.listen)
	if perr != nil {
		host, port = "", ""
	}
	var hostPorts []string
	if port == "" {
		// 端口解析失败（listen 格式异常）：直接原样展示，避免拼出 "IP:" 尾巴
		hostPorts = []string{c.listen}
	} else if host == "" || host == "0.0.0.0" || host == "::" {
		// 全监听：列出本机所有可用 IP
		for _, ip := range localIPv4s() {
			hostPorts = append(hostPorts, net.JoinHostPort(ip, port))
		}
	} else {
		// 指定了具体监听地址：只提示该地址
		hostPorts = append(hostPorts, net.JoinHostPort(host, port))
	}

	fmt.Printf("rtctl-agent 启动 ✔  (id=%s)\n", c.id)
	fmt.Printf("  监听地址 : %s（%s，路径 %s）\n", c.listen, schema, wsPath)
	fmt.Printf("  本机地址 : %s\n", strings.Join(hostPorts, " / "))
	if fwSummary != "" {
		fmt.Printf("  防火墙   : %s\n", fwSummary)
	}
	if showToken {
		fmt.Printf("  设备 token: %s\n", c.token)
	} else {
		fmt.Printf("  设备 token: <已隐藏>（查看: rt token show）\n")
	}
	fmt.Printf("  允许提权 : %v\n", c.allowSudo)
	fmt.Printf("  配置文件 : %s\n", configPath)
	fmt.Printf("  连接示例 :\n")
	for _, hp := range hostPorts {
		if wsPath == "/ws" {
			fmt.Printf("    rtctl %s <token> 'uptime'   # 从控制机执行\n", hp)
		} else {
			fmt.Printf("    rtctl -server %s://%s%s exec -token <token> -c 'uptime'   # 自定义路径\n", schema, hp, wsPath)
		}
	}
	fmt.Printf("⚠️  安全警告: token 即设备全部权限，请勿外泄；公网服务器请配置 tls_cert / tls_key 启用加密传输\n")
}

type runtimeOptions struct {
	configPath   string
	listen       string
	id           string
	token        string
	tlsCert      string
	tlsKey       string
	wsPath       string
	allowSudo    bool
	openFirewall bool
	printToken   bool
	foreground   bool
	logFile      string
	pidFile      string
	daemonReady  string
}

func main() {
	os.Exit(runMain())
}

func runMain() int {
	configPath := flag.String("config", "", "配置文件路径（默认 ~/.rtctl/agent.conf，兼容 exe 同目录和当前目录）")
	initMode := flag.Bool("init", false, "生成 agent.conf（含随机 token）并打印连接信息后退出")
	listen := flag.String("listen", "", "监听地址（如 :8443；缺省取配置/默认 :8443）")
	id := flag.String("id", "", "设备 ID（或环境变量 RTCTL_ID）")
	token := flag.String("token", "", "设备 token（或环境变量 RTCTL_TOKEN）")
	tlsCert := flag.String("tls-cert", "", "TLS 证书路径（与 -tls-key 同时提供则启用 WSS）")
	tlsKey := flag.String("tls-key", "", "TLS 私钥路径")
	allowSudo := flag.Bool("allow-sudo", false, "允许特权命令（sudo:true 经 sudo 提权；需 sudoers 放行，默认关闭）")
	openFirewall := flag.Bool("open-firewall", true, "启动时自动放行监听端口（Linux: ufw/firewalld/iptables；Windows: netsh；需 root/管理员或免密 sudo；关闭用 -open-firewall=false）")
	wsPath := flag.String("ws-path", "", "WebSocket 路径（默认 /ws；反向代理/路径前缀场景可改，如 /rt/ws）")
	printToken := flag.Bool("print-token", true, "启动信息打印完整设备 token（设为 false 可避免 token 进入终端或日志采集）")
	showVersion := flag.Bool("version", false, "打印版本后退出")
	foreground := flag.Bool("foreground", false, "前台运行（供调试或服务管理器托管；运行日志仍写入文件）")
	statusMode := flag.Bool("status", false, "查询本机 agent 运行状态后退出")
	stopMode := flag.Bool("stop", false, "停止 PID 文件对应的本机 agent 后退出")
	logsMode := flag.Bool("logs", false, "查看运行日志后退出（-follow 跟随，-lines 指定行数，-no-color 关闭颜色）")
	followLogs := flag.Bool("follow", false, "跟随日志输出（仅与 -logs 一起使用）")
	logLines := flag.Int("lines", 100, "-logs 显示的最后行数（仅与 -logs 一起使用）")
	noColor := flag.Bool("no-color", false, "禁用日志颜色（仅与 -logs 一起使用；NO_COLOR 环境变量同样生效）")
	logFile := flag.String("log-file", defaultRuntimePath("agent.log"), "运行日志文件（每个约 10MB，保留 3 个轮转备份）")
	pidFile := flag.String("pid-file", defaultRuntimePath("agent.pid"), "本机 agent 的 PID 文件")
	daemonReady := flag.String("daemon-ready", "", "内部使用：后台子进程的就绪通知文件")
	flag.Parse()

	if *showVersion {
		fmt.Printf("rtctl-agent %s\n", agent.Version)
		return 0
	}
	if *configPath == "" {
		*configPath = defaultConfigPath()
	}

	if *initMode {
		if _, err := os.Stat(*configPath); err == nil {
			log.Printf("配置文件已存在: %s（如需重新生成请先删除或手动编辑）", *configPath)
			return 1
		}
		if dir := filepath.Dir(*configPath); dir != "." {
			if err := os.MkdirAll(dir, 0o700); err != nil {
				log.Printf("创建配置目录失败: %v", err)
				return 1
			}
		}
		c := cfg{listen: ":8443", id: hostnameOrDefault()}
		if *listen != "" {
			c.listen = *listen
		}
		if *id != "" {
			c.id = *id
		} else if e := os.Getenv("RTCTL_ID"); e != "" {
			c.id = e
		}
		if *token != "" {
			c.token = *token
		} else if e := os.Getenv("RTCTL_TOKEN"); e != "" {
			c.token = e
		} else {
			t, err := genToken()
			if err != nil {
				log.Printf("生成 token 失败: %v", err)
				return 1
			}
			c.token = t
		}
		c.tlsCert, c.tlsKey, c.allowSudo = *tlsCert, *tlsKey, *allowSudo
		c.wsPath = *wsPath
		if err := writeConfig(*configPath, c); err != nil {
			log.Printf("写入配置失败: %v", err)
			return 1
		}
		fmt.Printf("✔ 配置已生成: %s\n", *configPath)
		fmt.Printf("  设备 ID      : %s\n", c.id)
		fmt.Printf("  监听地址    : %s%s\n", c.listen, tlsNote(c.tlsCert))
		fmt.Printf("  设备 token  : %s\n", c.token)
		fmt.Printf("\n本机连接示例（把 <IP> 换成目标机地址）:\n  rtctl <IP>%s <token> 'uptime'\n", c.listen)
		fmt.Printf("\n⚠️  安全警告: token 即设备全部权限，请仅通过安全渠道保存/分享；\n   公网服务器建议配置 tls_cert / tls_key 启用加密传输。\n")
		return 0
	}

	opts := runtimeOptions{
		configPath: *configPath, listen: *listen, id: *id, token: *token,
		tlsCert: *tlsCert, tlsKey: *tlsKey, wsPath: *wsPath,
		allowSudo: *allowSudo, openFirewall: *openFirewall, printToken: *printToken,
		foreground: *foreground, logFile: *logFile, pidFile: *pidFile, daemonReady: *daemonReady,
	}
	if *statusMode && *stopMode {
		fmt.Fprintln(os.Stderr, "rtctl-agent: -status 与 -stop 不能同时使用")
		return 2
	}
	if *logsMode && (*initMode || *statusMode || *stopMode) {
		fmt.Fprintln(os.Stderr, "rtctl-agent: -logs 不能与 -init/-status/-stop 同时使用")
		return 2
	}
	logsOnlyUsed := false
	flag.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "follow", "lines", "no-color":
			logsOnlyUsed = true
		}
	})
	if !*logsMode && logsOnlyUsed {
		fmt.Fprintln(os.Stderr, "rtctl-agent: -follow/-lines/-no-color 仅与 -logs 一起使用")
		return 2
	}
	if *logLines <= 0 {
		fmt.Fprintln(os.Stderr, "rtctl-agent: -lines 必须大于 0")
		return 2
	}
	if *statusMode {
		if rec, running := runningPIDRecord(opts.pidFile); running {
			fmt.Printf("rtctl-agent 运行中 (pid=%d)\n  日志文件 : %s\n", rec.PID, opts.logFile)
			fmt.Printf("  查看日志 : %s -logs -follow -log-file %s\n", strconv.Quote(os.Args[0]), strconv.Quote(opts.logFile))
			return 0
		}
		fmt.Printf("rtctl-agent 未运行\n  PID 文件 : %s\n", opts.pidFile)
		if hint := portOccupiedHint(statusListenAddr(opts)); hint != "" {
			fmt.Printf("  注意: %s\n", hint)
		}
		return 1
	}
	if *stopMode {
		pid, err := stopPIDFile(opts.pidFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "rtctl-agent: %v\n", err)
			return 1
		}
		if pid == 0 {
			fmt.Println("rtctl-agent 未运行")
		} else {
			fmt.Printf("rtctl-agent 已停止 (pid=%d)\n", pid)
		}
		return 0
	}

	// -logs 只读日志文件：不读配置、不校验 token、不启动服务、不写 PID。
	if *logsMode {
		console.DisableQuickEdit()
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		if err := showLogs(ctx, *logFile, *logLines, *followLogs, wantColor(*noColor), os.Stdout); err != nil {
			fmt.Fprintf(os.Stderr, "rtctl-agent: %v\n", err)
			return 1
		}
		return 0
	}

	c, err := loadRuntimeConfig(opts)
	if err != nil {
		return reportRuntimeError(opts, err)
	}
	if opts.daemonReady != "" {
		ignoreTerminalHangup()
	}

	fwSum, fwDetail := "", ""
	if opts.daemonReady == "" && opts.openFirewall {
		fr, _ := openFirewallPort(c.listen)
		fwSum, fwDetail = fr.summary, fr.detail
	}
	if fwDetail != "" {
		fmt.Println(fwDetail)
	}
	if opts.daemonReady == "" && opts.foreground {
		printStartup(c, opts.configPath, fwSum, opts.printToken)
		fmt.Printf("  日志文件 : %s\n", opts.logFile)
		fmt.Printf("  查看日志 : %s -logs -follow -log-file %s\n", strconv.Quote(os.Args[0]), strconv.Quote(opts.logFile))
	}
	if opts.daemonReady == "" && !opts.foreground {
		result, err := launchBackground(opts.pidFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "rtctl-agent: %v\n", err)
			return 1
		}
		printStartup(c, opts.configPath, fwSum, opts.printToken)
		fmt.Printf("  后台 PID  : %d\n", result.PID)
		if result.Addr != "" {
			fmt.Printf("  实际监听 : %s\n", result.Addr)
		}
		fmt.Printf("  日志文件 : %s（每个约 10MB，保留 3 个备份）\n", opts.logFile)
		fmt.Printf("  查看日志 : %s -logs -follow -log-file %s\n", strconv.Quote(os.Args[0]), strconv.Quote(opts.logFile))
		fmt.Printf("  查看状态 : %s -status -pid-file %s\n", strconv.Quote(os.Args[0]), strconv.Quote(opts.pidFile))
		fmt.Printf("  停止服务 : %s -stop -pid-file %s\n", strconv.Quote(os.Args[0]), strconv.Quote(opts.pidFile))
		return 0
	}

	if err := runAgent(opts, c); err != nil {
		return reportRuntimeError(opts, err)
	}
	return 0
}

func loadRuntimeConfig(o runtimeOptions) (cfg, error) {
	c := cfg{listen: ":8443"}
	if loaded, err := loadConfig(o.configPath); err == nil {
		c = loaded
		if c.listen == "" {
			c.listen = ":8443"
		}
	} else if !os.IsNotExist(err) {
		return c, fmt.Errorf("读取配置失败 %s: %w", o.configPath, err)
	}
	if o.listen != "" {
		c.listen = o.listen
	}
	if o.id != "" {
		c.id = o.id
	} else if c.id == "" {
		c.id = os.Getenv("RTCTL_ID")
	}
	if o.token != "" {
		c.token = o.token
	} else if c.token == "" {
		c.token = os.Getenv("RTCTL_TOKEN")
	}
	if o.tlsCert != "" {
		c.tlsCert = o.tlsCert
	}
	if o.tlsKey != "" {
		c.tlsKey = o.tlsKey
	}
	if o.allowSudo {
		c.allowSudo = true
	}
	if o.wsPath != "" {
		c.wsPath = o.wsPath
	}
	if c.id == "" || c.token == "" {
		return c, fmt.Errorf("缺少设备 ID/token：编辑 %s 或运行 %s -init 自动生成（也可 -id/-token 或环境变量 RTCTL_ID/RTCTL_TOKEN）", o.configPath, os.Args[0])
	}
	if (c.tlsCert == "") != (c.tlsKey == "") {
		return c, fmt.Errorf("-tls-cert 与 -tls-key 必须同时提供（或同时留空）")
	}
	return c, nil
}

func runAgent(o runtimeOptions, c cfg) error {
	logWriter, err := openRotatingLog(o.logFile, defaultLogMaxBytes, defaultLogBackups)
	if err != nil {
		return err
	}
	defer logWriter.Close()
	log.SetOutput(logWriter)

	rec, err := writePIDFile(o.pidFile)
	if err != nil {
		return err
	}
	defer removeOwnPIDFile(o.pidFile)

	listener, err := net.Listen("tcp", c.listen)
	if err != nil {
		if isAddrInUse(err) {
			return fmt.Errorf("监听 %s 失败: 端口已被占用（排查: %s -status -pid-file %s；若非本 agent 实例占用，请用 -listen :<端口> 更换监听地址）",
				c.listen, strconv.Quote(os.Args[0]), strconv.Quote(o.pidFile))
		}
		return fmt.Errorf("监听 %s 失败: %w", c.listen, err)
	}
	defer listener.Close()
	if c.tlsCert != "" {
		if _, err := tls.LoadX509KeyPair(c.tlsCert, c.tlsKey); err != nil {
			return fmt.Errorf("加载 TLS 证书失败: %w", err)
		}
	}

	a := agent.New(c.id, c.token)
	a.AllowSudo = c.allowSudo
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	log.Printf("rtctl-agent 启动: pid=%d id=%s listen=%s tls=%v allow-sudo=%v（配置: %s）",
		rec.PID, c.id, c.listen, c.tlsCert != "", c.allowSudo, o.configPath)
	if err := notifyDaemon(o.daemonReady, daemonResult{PID: rec.PID, Addr: listener.Addr().String()}); err != nil {
		return err
	}
	if err := a.ServeStandaloneOn(ctx, listener, c.tlsCert, c.tlsKey, c.wsPath); err != nil {
		return fmt.Errorf("agent 服务退出: %w", err)
	}
	log.Printf("rtctl-agent 已停止: pid=%d", rec.PID)
	return nil
}

func reportRuntimeError(o runtimeOptions, err error) int {
	if o.daemonReady != "" {
		notifyDaemon(o.daemonReady, daemonResult{Error: err.Error()})
		log.Printf("rtctl-agent 启动失败: %v", err)
	} else {
		fmt.Fprintf(os.Stderr, "rtctl-agent: %v\n", err)
	}
	return 1
}

func tlsNote(cert string) string {
	if cert != "" {
		return "（WSS）"
	}
	return ""
}
