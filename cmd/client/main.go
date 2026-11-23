// rtctl 控制端 CLI：直连目标设备的 agent 发指令。
//
// 用法:
//
//	rtctl [全局参数] list
//	rtctl [全局参数] exec -token <token> [-timeout ms] [-workdir dir] [-stdin-file f] [-sudo] [-confirm-sudo] [-c 命令 | 命令...]
//	rtctl [全局参数] shell -token <token>
//
// 全局参数（必须放在子命令之前）:
//
//	-server    设备地址（agent 直连地址，默认 ws://127.0.0.1:8443/ws）
//	-client-id 操作者/Agent 标识（记日志用）
//	-json      结构化输出（list / exec 生效）
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/term"

	"rtctl/internal/idutil"
	"rtctl/internal/proto"
)

// version 客户端版本号（构建时经 -ldflags "-X main.version=<tag>" 注入）。
var version = "dev"

var (
	serverURL   string
	clientID    string
	jsonMode    bool
	quietMode   bool   // 关闭执行上下文摘要（stdout 始终纯命令输出）
	caFile      string // 自定义 CA 证书文件（自签 / 私有 CA 场景）
	insecureTLS bool   // 跳过 TLS 证书校验（仅调试用）
)

// execResult exec 的 JSON 结果（-json 模式输出）。
type execResult struct {
	ExitCode   int    `json:"exit_code"`
	Output     string `json:"output"`
	Truncated  bool   `json:"truncated"`
	Error      string `json:"error,omitempty"`
	ErrorCode  string `json:"error_code,omitempty"`
	DurationMS int64  `json:"duration_ms"`
}

func main() {
	fs := flag.NewFlagSet("rtctl", flag.ExitOnError)
	fs.StringVar(&serverURL, "server", "ws://127.0.0.1:8443/ws", "设备地址（agent 直连地址）")
	fs.StringVar(&clientID, "client-id", "", "操作者/Agent 标识（记日志用）")
	fs.BoolVar(&jsonMode, "json", false, "结构化输出（list / exec）")
	fs.BoolVar(&quietMode, "quiet", false, "关闭执行上下文摘要（不打印目标地址/命令/耗时）")
	fs.StringVar(&caFile, "cafile", "", "自定义 CA 证书文件（自签 / 私有 CA 场景）")
	fs.BoolVar(&insecureTLS, "insecure", false, "跳过 TLS 证书校验（仅调试用，勿用于生产）")
	showVersion := fs.Bool("version", false, "打印版本后退出")
	fs.Usage = usage
	fs.Parse(os.Args[1:])

	if *showVersion {
		fmt.Printf("rtctl %s\n", version)
		return
	}

	args := fs.Args()
	if len(args) == 0 {
		usage()
		os.Exit(2)
	}
	var err error
	switch args[0] {
	case "list":
		err = cmdList()
	case "exec":
		err = cmdExec(args[1:])
	case "shell":
		err = cmdShell(args[1:])
	case "file-put":
		err = cmdFilePut(args[1:])
	case "file-get":
		err = cmdFileGet(args[1:])
	default:
		// 快捷入口: rtctl <host:port> <token> <cmd...>
		// 显式传入地址优先于 -server 默认值（用户给出 host:port 即视为连接目标）。
		if len(args) >= 2 && strings.Contains(args[0], ":") {
			serverURL = normalizeServer(args[0])
			cmdArgs := []string{"-token", args[1]}
			if len(args) > 2 {
				cmdArgs = append(cmdArgs, "-c", strings.Join(args[2:], " "))
			}
			err = cmdExec(cmdArgs)
		} else {
			usage()
			os.Exit(2)
		}
	}
	if err != nil {
		if jsonMode {
			printJSONError(err)
		} else {
			fmt.Fprintln(os.Stderr, "错误:", err)
		}
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `rtctl - 远程终端客户端

用法：
  rtctl <目标机IP:端口> <token> '<命令>'
  rtctl [全局选项] <命令> [命令选项]

命令：
  list       查看目标机信息
  exec       执行一次命令并返回输出和退出码
  shell      打开交互式远程终端
  file-put   上传文件
  file-get   下载文件

示例：
  rtctl 192.168.1.5:8443 <token> 'uptime'
  rtctl -server wss://192.168.1.5:8443/ws exec -token <token> -c 'uptime'

全局选项（必须放在子命令之前）：
  -server URL      目标机地址，默认 ws://127.0.0.1:8443/ws
  -cafile FILE     指定自签或私有 CA 证书
  -insecure        跳过 TLS 证书校验，仅限调试
  -client-id ID    操作者标识，用于目标机日志
  -json            list 和 exec 使用 JSON 输出
  -quiet           不显示目标、命令和耗时摘要
  -version         显示版本

查看命令选项：rtctl exec -h、rtctl shell -h、rtctl file-put -h

远程 sudo：
  目标机必须允许 sudo；交互执行需要确认，脚本执行需要 -confirm-sudo。
  临时授权使用 -sudo -sudo-ask；公网或共享网络必须使用 wss://，否则 token 和 root 密码可能泄露。
`)
}

// clip 按 rune 截断长字符串（显示前 n 个字符 + 省略号），用于摘要行。
func clip(s string, n int) string {
	rs := []rune(s)
	if len(rs) <= n {
		return s
	}
	return string(rs[:n]) + "…"
}

func printJSONError(err error) {
	b, _ := json.Marshal(map[string]string{"error": err.Error()})
	fmt.Println(string(b))
}

// normalizeServer 把用户输入规范为 ws URL：host:port -> ws://host:port/ws。
// 已带 ws:// / wss:// 前缀则保留；路径缺省时补 /ws。
func normalizeServer(addr string) string {
	s := addr
	if !strings.HasPrefix(s, "ws://") && !strings.HasPrefix(s, "wss://") {
		s = "ws://" + s
	}
	rest := s[strings.Index(s, "://")+3:]
	if !strings.Contains(rest, "/") {
		s += "/ws"
	}
	return s
}

// connect 连接服务器并完成认证，返回就绪的连接。
// wss:// 且指定 -cafile / -insecure 时使用自定义 TLS 配置（自签证书场景必需）。
func connect() (*websocket.Conn, error) {
	dialer := *websocket.DefaultDialer
	if strings.HasPrefix(serverURL, "wss://") && (caFile != "" || insecureTLS) {
		tlsConf := &tls.Config{MinVersion: tls.VersionTLS12}
		if insecureTLS {
			tlsConf.InsecureSkipVerify = true
		}
		if caFile != "" {
			pemBytes, rerr := os.ReadFile(caFile)
			if rerr != nil {
				return nil, rerr
			}
			pool := x509.NewCertPool()
			if !pool.AppendCertsFromPEM(pemBytes) {
				return nil, fmt.Errorf("无法解析 CA 文件: %s", caFile)
			}
			tlsConf.RootCAs = pool
		}
		dialer.TLSClientConfig = tlsConf
	}
	conn, _, err := dialer.Dial(serverURL, nil)
	if err != nil {
		return nil, err
	}
	m, _ := proto.WithPayload(proto.Msg{Type: proto.TypeAuth}, proto.AuthPayload{ID: clientID})
	if err := conn.WriteJSON(m); err != nil {
		conn.Close()
		return nil, err
	}
	var ack proto.Msg
	if err := conn.ReadJSON(&ack); err != nil {
		conn.Close()
		return nil, err
	}
	var p proto.AuthAckPayload
	ack.PayloadOf(&p)
	if !p.OK {
		conn.Close()
		return nil, errors.New(p.Error)
	}
	return conn, nil
}

// ---- list ----

func cmdList() error {
	conn, err := connect()
	if err != nil {
		return err
	}
	defer conn.Close()
	if err := conn.WriteJSON(proto.Msg{Type: proto.TypeList}); err != nil {
		return err
	}
	for {
		var m proto.Msg
		if err := conn.ReadJSON(&m); err != nil {
			return err
		}
		switch m.Type {
		case proto.TypeListAck:
			var p proto.ListAckPayload
			if err := m.PayloadOf(&p); err != nil {
				return err
			}
			if jsonMode {
				b, _ := json.Marshal(p.Devices)
				fmt.Println(string(b))
				return nil
			}
			fmt.Printf("%-20s %-6s %-12s %-8s %-24s %s\n", "设备ID", "状态", "OS", "架构", "主机名", "版本")
			for _, d := range p.Devices {
				status := "离线"
				if d.Online {
					status = "在线"
				}
				fmt.Printf("%-20s %-6s %-12s %-8s %-24s %s\n", d.ID, status, d.OS, d.Arch, d.Hostname, d.Version)
			}
			return nil
		case proto.TypeError:
			var p proto.ErrorPayload
			m.PayloadOf(&p)
			return fmt.Errorf("[%s] %s", p.Code, p.Error)
		}
	}
}

// ---- exec ----

func cmdExec(args []string) error {
	sub := flag.NewFlagSet("exec", flag.ExitOnError)
	token := sub.String("token", "", "目标设备 token")
	timeoutMS := sub.Int("timeout", 0, "超时毫秒（0=不限）")
	deadlineSec := sub.Int("deadline", 0, "客户端最多等多少秒（0=不限；默认超时后再多等 10 秒）")
	workdir := sub.String("workdir", "", "工作目录")
	stdinFile := sub.String("stdin-file", "", "写入命令 stdin 的文件")
	rawCmd := sub.String("c", "", "原样命令字符串（不再拼接参数）")
	sudo := sub.Bool("sudo", false, "请求 root 提权执行（需被控端已开启 -allow-sudo；交互下会向用户确认）")
	confirmSudo := sub.Bool("confirm-sudo", false, "非交互场景下确认特权命令（等价于用户批准）")
	sudoAsk := sub.Bool("sudo-ask", false, "临时提权：交互提示输入 root 密码（不依赖 sudoers 免密规则）")
	sudoPwStdin := sub.Bool("sudo-password-stdin", false, "临时提权：从标准输入读取 root 密码（脚本调用用）")
	sub.Parse(args)
	rest := sub.Args()
	if *token == "" || (*rawCmd == "" && len(rest) == 0) {
		fmt.Fprintln(os.Stderr, "用法：rtctl exec -token <token> -c '<命令>' [选项]；完整选项：rtctl exec -h")
		os.Exit(2)
	}
	var cmdStr string
	if *rawCmd != "" {
		cmdStr = *rawCmd
	} else {
		cmdStr = strings.Join(rest, " ")
	}
	// 特权命令审批：交互终端向用户当面确认；非交互（Agent/管道）必须显式 -confirm-sudo
	if *sudo && !*confirmSudo {
		if !term.IsTerminal(int(os.Stdin.Fd())) {
			return errors.New("远程 sudo 需要确认：请在交互终端运行，或为脚本显式添加 -confirm-sudo")
		}
		fmt.Printf("⚠ 将以 root 执行：%s\n确认？[y/N] ", cmdStr)
		reader := bufio.NewReader(os.Stdin)
		line, _ := reader.ReadString('\n')
		line = strings.TrimSpace(strings.ToLower(line))
		if line != "y" && line != "yes" {
			return errors.New("已取消远程 sudo 命令")
		}
	}
	// 临时提权（临时授权）：当场读取 root 密码，随请求发给 agent，由 agent 用 `sudo -S` 使用。
	// 永久授权则不需要密码：agent 侧 sudoers 有 NOPASSWD 规则时直接 `sudo -n` 成功。
	sudoPw := ""
	if *sudoAsk || *sudoPwStdin {
		if !*sudo {
			return errors.New("-sudo-ask 和 -sudo-password-stdin 必须与 -sudo 一起使用")
		}
		if *sudoPwStdin {
			b, rerr := io.ReadAll(os.Stdin)
			if rerr != nil {
				return rerr
			}
			sudoPw = strings.TrimRight(string(b), "\r\n")
		} else {
			if !term.IsTerminal(int(os.Stdin.Fd())) {
				return errors.New("交互输入 root 密码需要终端；脚本请使用 -sudo-password-stdin")
			}
			fmt.Fprint(os.Stderr, "root 密码：")
			b, rerr := term.ReadPassword(int(os.Stdin.Fd()))
			fmt.Fprintln(os.Stderr)
			if rerr != nil {
				return rerr
			}
			sudoPw = string(b)
		}
		if sudoPw == "" {
			return errors.New("root 密码不能为空")
		}
		if strings.HasPrefix(serverURL, "ws://") {
			fmt.Fprintln(os.Stderr, "⚠ 当前未启用 TLS，root 密码将明文传输")
		}
	}
	var stdinData string
	if *stdinFile != "" {
		b, err := os.ReadFile(*stdinFile)
		if err != nil {
			return err
		}
		stdinData = string(b)
	}

	conn, err := connect()
	if err != nil {
		return err
	}
	defer conn.Close()

	execID := idutil.New()
	m := proto.Msg{Type: proto.TypeExec, Token: *token, ID: execID}
	m, err = proto.WithPayload(m, proto.ExecPayload{Cmd: cmdStr, TimeoutMS: *timeoutMS, Workdir: *workdir, Stdin: stdinData, Sudo: *sudo, SudoPassword: sudoPw})
	if err != nil {
		return err
	}
	if err := conn.WriteJSON(m); err != nil {
		return err
	}
	// 执行上下文摘要（stderr，不污染命令输出；-json/-quiet 时关闭）
	if !jsonMode && !quietMode {
		fmt.Fprintf(os.Stderr, "→ %s | %s\n", serverURL, clip(cmdStr, 80))
	}

	// 客户端读超时：避免 server/agent 异常时永久挂起
	if *deadlineSec > 0 {
		conn.SetReadDeadline(time.Now().Add(time.Duration(*deadlineSec) * time.Second))
	} else if *timeoutMS > 0 {
		conn.SetReadDeadline(time.Now().Add(time.Duration(*timeoutMS)*time.Millisecond + 10*time.Second))
	}

	// Ctrl+C / SIGTERM：先向 agent 发 exec_kill 再退出，避免远端进程成为孤儿
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		kill, _ := proto.WithPayload(proto.Msg{Type: proto.TypeExecKill, Token: *token},
			proto.ExecKillPayload{ExecID: execID})
		conn.WriteJSON(kill)
		conn.Close()
	}()

	start := time.Now()
	var sb strings.Builder
	lastNL := true // 上一条输出是否以换行结尾（避免摘要/告警与命令输出粘行）
	for {
		var msg proto.Msg
		if err := conn.ReadJSON(&msg); err != nil {
			if ctx.Err() != nil {
				os.Exit(130) // 被中断
			}
			return err
		}
		switch msg.Type {
		case proto.TypeExecOutput:
			var p proto.ExecOutputPayload
			if err := msg.PayloadOf(&p); err != nil {
				return err
			}
			if jsonMode {
				sb.WriteString(p.Data)
			} else {
				fmt.Print(p.Data)
				if p.Data != "" {
					lastNL = strings.HasSuffix(p.Data, "\n")
				}
			}
			if p.Done {
				if !jsonMode {
					if !lastNL {
						fmt.Fprintln(os.Stderr) // 先断开粘行
						lastNL = true
					}
					if p.Truncated {
						fmt.Fprintln(os.Stderr, "[警告：输出不完整，部分内容已丢弃]")
					}
					if p.Error != "" {
						fmt.Fprintf(os.Stderr, "[%s]\n", p.Error)
					}
					if !quietMode {
						if p.ErrorCode != "" {
							fmt.Fprintf(os.Stderr, "← 退出码 %d，错误码 %s，耗时 %dms\n",
								p.ExitCode, p.ErrorCode, time.Since(start).Milliseconds())
						} else {
							fmt.Fprintf(os.Stderr, "← 退出码 %d，耗时 %dms\n",
								p.ExitCode, time.Since(start).Milliseconds())
						}
					}
				}
				if jsonMode {
					res := execResult{ExitCode: p.ExitCode, Output: sb.String(), Truncated: p.Truncated,
						Error: p.Error, ErrorCode: p.ErrorCode, DurationMS: time.Since(start).Milliseconds()}
					b, _ := json.Marshal(res)
					fmt.Println(string(b))
				}
				if p.ExitCode != 0 {
					os.Exit(p.ExitCode)
				}
				return nil
			}
		case proto.TypeError:
			var p proto.ErrorPayload
			msg.PayloadOf(&p)
			return fmt.Errorf("[%s] %s", p.Code, p.Error)
		}
	}
}

// ---- shell ----

func cmdShell(args []string) error {
	sub := flag.NewFlagSet("shell", flag.ExitOnError)
	token := sub.String("token", "", "目标设备 token")
	sub.Parse(args)
	if *token == "" {
		fmt.Fprintln(os.Stderr, "用法: rtctl shell -token <token>")
		os.Exit(2)
	}

	conn, err := connect()
	if err != nil {
		return err
	}
	defer conn.Close()

	// 会话 ID 由客户端生成（空 ID 会让多个 shell 在 agent 注册表里互相覆盖）
	openMsg := proto.Msg{Type: proto.TypeShellOpen, Token: *token, SessionID: idutil.New()}
	if err := conn.WriteJSON(openMsg); err != nil {
		return err
	}
	// 等待 shell_ack
	opened := false
	sessionID := ""
	for !opened {
		var m proto.Msg
		if err := conn.ReadJSON(&m); err != nil {
			return err
		}
		switch m.Type {
		case proto.TypeShellAck:
			var p proto.ShellAckPayload
			if err := m.PayloadOf(&p); err != nil {
				return err
			}
			if !p.OK {
				return errors.New("打开终端失败: " + p.Error)
			}
			sessionID = m.SessionID
			opened = true
		case proto.TypeError:
			var p proto.ErrorPayload
			m.PayloadOf(&p)
			return fmt.Errorf("[%s] %s", p.Code, p.Error)
		}
	}

	fmt.Printf("已连接远程终端 %s；输入 exit 或按 Ctrl+D 退出。\n", serverURL)

	// 本地终端进入 raw 模式，把键盘输入原样转发
	fd := int(os.Stdin.Fd())
	if term.IsTerminal(fd) {
		oldState, err := term.MakeRaw(fd)
		if err != nil {
			return err
		}
		defer term.Restore(fd, oldState)
	}

	// 发送初始窗口尺寸，并在窗口变化（SIGWINCH）时重发（全屏程序依赖）
	sendResize := func() {
		if !term.IsTerminal(fd) {
			return
		}
		if w, h, err := term.GetSize(fd); err == nil {
			d, _ := proto.WithPayload(proto.Msg{Type: proto.TypeShellResize, SessionID: sessionID},
				proto.ShellResizePayload{Cols: uint16(w), Rows: uint16(h)})
			conn.WriteJSON(d)
		}
	}
	sendResize()
	winchCtx, winchStop := context.WithCancel(context.Background())
	defer winchStop()
	go watchWinch(winchCtx, sendResize)

	// 本地输入 -> shell_data（Ctrl+C/Ctrl+D 以字节原样转发）
	go func() {
		buf := make([]byte, 4096)
		for {
			n, rerr := os.Stdin.Read(buf)
			if n > 0 {
				d, _ := proto.WithPayload(proto.Msg{Type: proto.TypeShellData, SessionID: sessionID},
					proto.ShellDataPayload{Data: string(buf[:n])})
				if werr := conn.WriteJSON(d); werr != nil {
					return
				}
			}
			if rerr != nil {
				if rerr == io.EOF {
					// stdin 关闭（管道输入场景）：给远端 shell 一点时间消化
					// 让终端先把缓冲的输入处理完再关闭，否则刚敲的命令会被吃掉
					time.Sleep(500 * time.Millisecond)
					conn.WriteJSON(proto.Msg{Type: proto.TypeShellClose, SessionID: sessionID})
				}
				return
			}
		}
	}()

	for {
		var m proto.Msg
		if err := conn.ReadJSON(&m); err != nil {
			return err
		}
		switch m.Type {
		case proto.TypeShellData:
			var p proto.ShellDataPayload
			if err := m.PayloadOf(&p); err != nil {
				return err
			}
			os.Stdout.WriteString(p.Data)
		case proto.TypeShellClose:
			fmt.Println("\n远程终端已关闭。")
			return nil
		case proto.TypeError:
			var p proto.ErrorPayload
			m.PayloadOf(&p)
			return fmt.Errorf("[%s] %s", p.Code, p.Error)
		}
	}
}
