// rtctl-client 控制端 CLI：连接服务器向目标设备发指令。
//
// 用法:
//
//	rtctl-client [全局参数] list
//	rtctl-client [全局参数] exec -token <设备token> [-timeout ms] [-workdir dir] [-stdin-file f] [-c 命令 | 命令...]
//	rtctl-client [全局参数] shell -token <设备token>
//
// 全局参数（必须放在子命令之前）:
//
//	-server    服务器地址（默认 ws://127.0.0.1:8080/ws?role=client）
//	-key       客户端密钥（与 server 的 -client-key 对应）
//	-client-id 操作者/Agent 标识（审计归因）
//	-json      结构化输出（list / exec 生效）
package main

import (
	"context"
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

var (
	serverURL string
	clientKey string
	clientID  string
	jsonMode  bool
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
	fs := flag.NewFlagSet("rtctl-client", flag.ExitOnError)
	fs.StringVar(&serverURL, "server", "ws://127.0.0.1:8080/ws?role=client", "服务器地址")
	fs.StringVar(&clientKey, "key", "", "客户端密钥")
	fs.StringVar(&clientID, "client-id", "", "操作者/Agent 标识（审计归因）")
	fs.BoolVar(&jsonMode, "json", false, "结构化输出（list / exec）")
	fs.Parse(os.Args[1:])

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
	case "serve":
		err = cmdServe(args[1:])
	default:
		usage()
		os.Exit(2)
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
	fmt.Fprint(os.Stderr, "rtctl-client - 远程终端控制端\n\n用法:\n  rtctl-client [全局参数] list\n  rtctl-client [全局参数] exec -token <设备token> [-timeout ms] [-workdir dir] [-stdin-file f] [-c 命令 | 命令...]\n  rtctl-client [全局参数] shell -token <设备token>\n  rtctl-client [全局参数] file-put -token <设备token> [-mode 0644] <本地文件> <远端路径>\n  rtctl-client [全局参数] file-get -token <设备token> <远端路径> <本地文件>\n  rtctl-client [全局参数] serve -listen 127.0.0.1:18080 -devices devices.json [-api-key K]\n\n全局参数:\n  -server    服务器地址 (默认 ws://127.0.0.1:8080/ws?role=client)\n  -key       客户端密钥（与 server 的 -client-key 对应）\n  -client-id 操作者/Agent 标识（审计归因）\n  -json      结构化输出（list / exec 生效）\n")
}

func printJSONError(err error) {
	b, _ := json.Marshal(map[string]string{"error": err.Error()})
	fmt.Println(string(b))
}

// connect 连接服务器并完成认证，返回就绪的连接。
func connect() (*websocket.Conn, error) {
	conn, _, err := websocket.DefaultDialer.Dial(serverURL, nil)
	if err != nil {
		return nil, err
	}
	m, _ := proto.WithPayload(proto.Msg{Type: proto.TypeAuth}, proto.AuthPayload{Key: clientKey, ID: clientID})
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
	deadlineSec := sub.Int("deadline", 0, "客户端总等待秒数（0=不限；默认 timeout+10s 宽限）")
	workdir := sub.String("workdir", "", "工作目录")
	stdinFile := sub.String("stdin-file", "", "写入命令 stdin 的文件")
	rawCmd := sub.String("c", "", "原样命令字符串（不再拼接参数）")
	sub.Parse(args)
	rest := sub.Args()
	if *token == "" || (*rawCmd == "" && len(rest) == 0) {
		fmt.Fprintln(os.Stderr, "用法: rtctl-client exec -token <设备token> [-timeout ms] [-workdir dir] [-stdin-file f] [-c 命令 | 命令...]")
		os.Exit(2)
	}
	var cmdStr string
	if *rawCmd != "" {
		cmdStr = *rawCmd
	} else {
		cmdStr = strings.Join(rest, " ")
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
	m, err = proto.WithPayload(m, proto.ExecPayload{Cmd: cmdStr, TimeoutMS: *timeoutMS, Workdir: *workdir, Stdin: stdinData})
	if err != nil {
		return err
	}
	if err := conn.WriteJSON(m); err != nil {
		return err
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
			}
			if p.Done {
				if !jsonMode {
					if p.Truncated {
						fmt.Fprintln(os.Stderr, "\n[警告: 输出被截断]")
					}
					if p.Error != "" {
						fmt.Fprintf(os.Stderr, "\n[%s]\n", p.Error)
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
		fmt.Fprintln(os.Stderr, "用法: rtctl-client shell -token <设备token>")
		os.Exit(2)
	}

	conn, err := connect()
	if err != nil {
		return err
	}
	defer conn.Close()

	openMsg := proto.Msg{Type: proto.TypeShellOpen, Token: *token}
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

	fmt.Println("=== 已进入远程终端（输入 exit 退出，Ctrl+D 断开）===")

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
			fmt.Println("\n=== 终端已关闭 ===")
			return nil
		case proto.TypeError:
			var p proto.ErrorPayload
			m.PayloadOf(&p)
			return fmt.Errorf("[%s] %s", p.Code, p.Error)
		}
	}
}
