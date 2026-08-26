// Package agent 实现被控端：直连模式，自带 WS 服务端，
// 本机 client 直接连接并执行指令。
package agent

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"rtctl/internal/idutil"
	"rtctl/internal/proto"
)

// Version agent 版本号。
const Version = "3.1.0"

const (
	maxConcurrentExec  = 32 // 单设备并发 exec 上限
	maxConcurrentShell = 8  // 单设备并发 shell 上限
	maxConcurrentPut   = 8  // 单设备并发上传上限
	maxConcurrentGet   = 8  // 单设备并发下载上限
	fileChunkSize      = 256 * 1024
	maxFileSize        = 256 << 20 // 单文件上限 256MB
)

var errSendQueueFull = errors.New("发送队列已满")

// Agent 被控端。
type Agent struct {
	ID    string
	Token string

	// AllowSudo 是否允许特权命令（sudo:true）。默认关闭：
	// 关闭时特权请求回 sudo_disabled，需管理员在被控端显式开启（人工授权）。
	AllowSudo bool

	mu       sync.Mutex
	execs    map[string]context.CancelFunc // exec 消息 ID -> 取消函数
	shells   map[string]*shellHandle       // session_id -> 终端会话
	putFiles map[string]*filePutState      // 传输 ID -> 上传状态

	execSem  chan struct{} // exec 并发数量限制
	shellSem chan struct{} // shell 并发数量限制
	getSem   chan struct{} // 文件下载并发数量限制（上传按 putFiles 计数）
}

// filePutState 一个进行中的文件上传。
type filePutState struct {
	file    *os.File
	tmpPath string
	path    string
	mode    uint32
	size    int64
	written int64
	sink    sendSink // 回执目标
}

// New 创建 Agent。
func New(id, token string) *Agent {
	return &Agent{
		ID:       id,
		Token:    token,
		execs:    make(map[string]context.CancelFunc),
		shells:   make(map[string]*shellHandle),
		putFiles: make(map[string]*filePutState),
		execSem:  make(chan struct{}, maxConcurrentExec),
		shellSem: make(chan struct{}, maxConcurrentShell),
		getSem:   make(chan struct{}, maxConcurrentGet),
	}
}

// writePump 每条直连连接的写循环（参数局部化，避免跨连接串写）。
func writePump(ws *websocket.Conn, send chan []byte) {
	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case b := <-send:
			ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := ws.WriteMessage(websocket.TextMessage, b); err != nil {
				ws.Close()
				return
			}
		case <-ticker.C:
			ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				ws.Close()
				return
			}
		}
	}
}

// sendSink 响应目标抽象：每条直连客户端连接的响应队列。
type sendSink interface {
	Send(proto.Msg) error
	SendBlocking(proto.Msg, time.Duration) error
	CloseConn() // 关键帧送达失败时断开对应连接
}

// ---- 消息分发 ----

func (a *Agent) handleMsg(ctx context.Context, m proto.Msg, sink sendSink) {
	switch m.Type {
	case proto.TypeExec:
		go a.handleExec(m, sink)
	case proto.TypeExecKill:
		a.handleExecKill(m)
	case proto.TypeShellOpen:
		// 同步创建并注册会话，避免 shell_data 早于注册被丢弃
		a.handleShellOpen(m, sink)
	case proto.TypeShellData, proto.TypeShellResize, proto.TypeShellClose:
		a.handleShellCtrl(m)
	case proto.TypeFilePut:
		// 先同步创建临时文件并登记状态，避免后续数据段早到被丢掉
		a.handleFilePut(m, sink)
	case proto.TypeFilePutChunk:
		a.handleFilePutChunk(m)
	case proto.TypeFileGet:
		go a.handleFileGet(m, sink)
	case proto.TypeFileAbort:
		a.handleFileAbort(m)
	default:
		log.Printf("[agent] 未知消息类型: %s", m.Type)
	}
}

// ---- exec 一次性执行 ----

func (a *Agent) handleExec(m proto.Msg, sink sendSink) {
	// 并发上限：超限直接回错误，不排队（Agent 侧应串行化自己的负载）
	select {
	case a.execSem <- struct{}{}:
		defer func() { <-a.execSem }()
	default:
		sendExecOutput(sink, m.ID, "", true, 1, "并发 exec 超限", proto.ErrorCodeOverload, false)
		return
	}

	var p proto.ExecPayload
	if err := m.PayloadOf(&p); err != nil || p.Cmd == "" {
		sendExecOutput(sink, m.ID, "", true, 1, "exec payload 无效", proto.ErrorCodeBadPayload, false)
		return
	}
	// 特权命令审批闸：sudo:true 且被控端未授权（-allow-sudo）→ 拒绝执行。
	// Windows 例外：计划任务本身以 SYSTEM 运行，sudo 字段无提权含义，直接放行。
	if p.Sudo && !a.AllowSudo && runtime.GOOS != "windows" {
		sendExecOutput(sink, m.ID, "", true, 1,
			"特权命令未获批准：被控端未开启 -allow-sudo（需管理员在被控端运行安装脚本并选择允许提权）",
			proto.ErrorCodeSudoDisabled, false)
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	if p.TimeoutMS > 0 {
		ctx, cancel = context.WithTimeout(ctx, time.Duration(p.TimeoutMS)*time.Millisecond)
	}
	// ID 冲突拒绝：重复 ID 会覆盖注册表项，导致 kill 失效、输出混杂（契约 6.4）
	a.mu.Lock()
	if _, dup := a.execs[m.ID]; dup {
		a.mu.Unlock()
		cancel()
		sendExecOutput(sink, m.ID, "", true, 1, "exec ID 冲突（请换新 ID 重试）", proto.ErrorCodeConflict, false)
		return
	}
	a.execs[m.ID] = cancel
	a.mu.Unlock()
	defer func() {
		cancel()
		a.mu.Lock()
		delete(a.execs, m.ID)
		a.mu.Unlock()
	}()

	argv, sysProc := shellExecArgs(p.Cmd, p.Sudo)
	// sudo 路径不能用 CommandContext：ctx 取消时它会抢先杀掉直接子进程 sudo，
	// 而 sudo 已把 /bin/sh 与孙进程放进新会话/进程组，剩下的树会漏杀。
	// 这里用普通 exec.Command，由下方 kill goroutine 统一经 /proc 遍历杀整树。
	var cmd *exec.Cmd
	if p.Sudo && runtime.GOOS == "linux" {
		cmd = exec.Command(argv[0], argv[1:]...)
	} else {
		cmd = exec.CommandContext(ctx, argv[0], argv[1:]...)
	}
	if sysProc != nil {
		cmd.SysProcAttr = sysProc
	}
	if p.Workdir != "" {
		cmd.Dir = p.Workdir
	}
	if p.Stdin != "" {
		cmd.Stdin = strings.NewReader(p.Stdin)
	}
	pr, pw, perr := os.Pipe()
	if perr != nil {
		sendExecOutput(sink, m.ID, "", true, 1, "创建管道失败: "+perr.Error(), proto.ErrorCodeStartFailed, false)
		return
	}
	cmd.Stdout = pw
	cmd.Stderr = pw
	if err := cmd.Start(); err != nil {
		pw.Close()
		pr.Close()
		sendExecOutput(sink, m.ID, "", true, 1, "启动进程失败: "+err.Error(), proto.ErrorCodeStartFailed, false)
		return
	}
	// 超时/取消时结束命令和所有子进程（孙进程也一起）
	go func() {
		<-ctx.Done()
		if ctx.Err() != nil {
			log.Printf("[agent] exec 超时/取消，结束命令与子进程 sudo=%v cmd=%s", p.Sudo, p.Cmd)
			killProcessTree(cmd, p.Sudo)
		}
	}()
	waitCh := make(chan error, 1)
	go func() {
		waitCh <- cmd.Wait()
		pw.Close()
	}()
	if p.Sudo {
		log.Printf("[agent] exec 开始(SUDO): %s", p.Cmd)
	} else {
		log.Printf("[agent] exec 开始: %s", p.Cmd)
	}

	buf := make([]byte, 32*1024)
	seq := 0
	truncated := false
	var head []byte // 输出开头（用于 sudo 失败识别，最多 4KB）
	for ctx.Err() == nil {
		n, rerr := pr.Read(buf)
		if n > 0 {
			data := buf[:n]
			if runtime.GOOS == "windows" {
				data = decodeConsoleOutput(data)
			}
			if len(head) < 4096 {
				head = append(head, data...)
			}
			if err := sendExecOutput(sink, m.ID, string(data), false, 0, "", "", false); err != nil {
				truncated = true // 发送忙不过来回传被丢过：在结束帧上标记内容不完整
			}
			seq++
		}
		if rerr != nil {
			break
		}
	}
	pr.Close()
	var werr error
	select {
	case werr = <-waitCh:
	case <-time.After(5 * time.Second):
		werr = errors.New("等待进程退出超时")
	}
	exitCode := 0
	if werr != nil {
		if ee, ok := werr.(*exec.ExitError); ok {
			exitCode = ee.ExitCode()
			if exitCode < 0 {
				exitCode = 1
			}
		} else {
			exitCode = 1
		}
	}
	errStr, errCode := "", ""
	switch {
	case ctx.Err() == context.DeadlineExceeded:
		errStr, errCode = "执行超时", proto.ErrorCodeTimeout
	case ctx.Err() == context.Canceled:
		errStr, errCode = "已被取消", proto.ErrorCodeKilled
	case p.Sudo && exitCode == 1 && sudoFailureMark(string(head)):
		// sudo -n 失败（sudoers 未放行 / NNP 阻挡 / 密码缺失）→ 机器可读错误码
		errStr, errCode = "sudo 执行失败：sudoers 未放行 rtctl-agent（需在被控端安装时选择允许提权）", proto.ErrorCodeSudoDenied
	}
	// done 帧必须可靠送达：阻塞发送，失败则断开对应连接
	if err := sendExecOutputBlocking(sink, m.ID, true, exitCode, errStr, errCode, truncated); err != nil {
		sink.CloseConn()
	}
	log.Printf("[agent] exec 结束: %s exit=%d %s", p.Cmd, exitCode, errStr)
}

func sendExecOutput(sink sendSink, id, data string, done bool, exitCode int, errStr, errCode string, truncated bool) error {
	out, _ := proto.WithPayload(proto.Msg{Type: proto.TypeExecOutput, ID: id},
		proto.ExecOutputPayload{Data: data, Done: done, ExitCode: exitCode, Error: errStr, ErrorCode: errCode, Truncated: truncated})
	return sink.Send(out)
}

// sudoFailureMark 判断输出开头是否为 sudo -n 的典型失败信息。
func sudoFailureMark(head string) bool {
	for _, m := range []string{
		"a password is required",
		"not allowed to run sudo",
		"no new privileges",
		"sudoers",
	} {
		if strings.Contains(head, m) {
			return true
		}
	}
	return false
}

func sendExecOutputBlocking(sink sendSink, id string, done bool, exitCode int, errStr, errCode string, truncated bool) error {
	out, _ := proto.WithPayload(proto.Msg{Type: proto.TypeExecOutput, ID: id},
		proto.ExecOutputPayload{Done: done, ExitCode: exitCode, Error: errStr, ErrorCode: errCode, Truncated: truncated})
	return sink.SendBlocking(out, 5*time.Second)
}

func (a *Agent) handleExecKill(m proto.Msg) {
	var p proto.ExecKillPayload
	if err := m.PayloadOf(&p); err != nil {
		return
	}
	a.mu.Lock()
	cancel, ok := a.execs[p.ExecID]
	a.mu.Unlock()
	if ok {
		cancel()
	}
}

// ---- 文件传输 ----

// handleFilePut 开始一次上传：校验大小、创建临时文件并注册状态。
// 数据段由 handleFilePutChunk（读循环内串行）处理，最后一段 done=true 落盘。
func (a *Agent) handleFilePut(m proto.Msg, sink sendSink) {
	var p proto.FilePutPayload
	if err := m.PayloadOf(&p); err != nil || p.Path == "" {
		sendFilePutAck(sink, m.ID, false, "file_put payload 无效")
		return
	}
	if p.Size <= 0 || p.Size > maxFileSize {
		sendFilePutAck(sink, m.ID, false, fmt.Sprintf("文件大小无效（上限 %dMB）", maxFileSize>>20))
		return
	}
	a.mu.Lock()
	if len(a.putFiles) >= maxConcurrentPut {
		a.mu.Unlock()
		sendFilePutAck(sink, m.ID, false, "并发上传超限")
		return
	}
	if _, dup := a.putFiles[m.ID]; dup {
		a.mu.Unlock()
		sendFilePutAck(sink, m.ID, false, "传输 ID 冲突（"+proto.ErrorCodeConflict+"）")
		return
	}
	a.mu.Unlock()

	mode := p.Mode
	if mode == 0 {
		mode = 0o644
	}
	tmpPath := p.Path + ".rtctl-partial"
	f, err := os.OpenFile(tmpPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		sendFilePutAck(sink, m.ID, false, "创建临时文件失败: "+err.Error())
		return
	}
	st := &filePutState{file: f, tmpPath: tmpPath, path: p.Path, mode: mode, size: p.Size, sink: sink}
	a.mu.Lock()
	a.putFiles[m.ID] = st
	a.mu.Unlock()
	log.Printf("[agent] file_put 开始: %s (%d 字节)", p.Path, p.Size)
}

func (a *Agent) handleFilePutChunk(m proto.Msg) {
	a.mu.Lock()
	st := a.putFiles[m.ID]
	a.mu.Unlock()
	if st == nil {
		return
	}
	var p proto.FileChunkPayload
	if err := m.PayloadOf(&p); err != nil {
		a.failFilePut(m.ID, st, "数据段解析失败")
		return
	}
	data, err := base64.StdEncoding.DecodeString(p.Data)
	if err != nil {
		a.failFilePut(m.ID, st, "数据段解码失败")
		return
	}
	if _, err := st.file.Write(data); err != nil {
		a.failFilePut(m.ID, st, "写入失败: "+err.Error())
		return
	}
	st.written += int64(len(data))
	if st.written > st.size || st.written > maxFileSize {
		a.failFilePut(m.ID, st, "写入超出声明大小")
		return
	}
	if !p.Done {
		return
	}
	// 完成：关文件、设权限、用临时文件替换正式文件（Windows 需先移除同名目标）
	if err := st.file.Close(); err != nil {
		a.failFilePut(m.ID, st, "关闭文件失败: "+err.Error())
		return
	}
	_ = os.Chmod(st.tmpPath, os.FileMode(st.mode))
	if runtime.GOOS == "windows" {
		os.Remove(st.path)
	}
	if err := os.Rename(st.tmpPath, st.path); err != nil {
		os.Remove(st.tmpPath)
		a.removeFilePut(m.ID)
		sendFilePutAck(st.sink, m.ID, false, "落盘改名失败: "+err.Error())
		return
	}
	a.removeFilePut(m.ID)
	sendFilePutAck(st.sink, m.ID, true, "")
	log.Printf("[agent] file_put 完成: %s (%d 字节)", st.path, st.written)
}

func (a *Agent) failFilePut(id string, st *filePutState, why string) {
	if st.file != nil {
		st.file.Close()
	}
	os.Remove(st.tmpPath)
	a.removeFilePut(id)
	sendFilePutAck(st.sink, id, false, why)
	log.Printf("[agent] file_put 失败: %s (%s)", st.path, why)
}

func (a *Agent) removeFilePut(id string) {
	a.mu.Lock()
	delete(a.putFiles, id)
	a.mu.Unlock()
}

func sendFilePutAck(sink sendSink, id string, ok bool, errStr string) {
	ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFilePutAck, ID: id},
		proto.FilePutAckPayload{OK: ok, Error: errStr})
	sink.Send(ack)
}

// handleFileGet 下载文件：按段回传；文件数据必须送达（发不出去就断开）。
func (a *Agent) handleFileGet(m proto.Msg, sink sendSink) {
	select {
	case a.getSem <- struct{}{}:
		defer func() { <-a.getSem }()
	default:
		sendFileGetChunk(sink, m.ID, 0, "", true, "并发下载超限", "")
		return
	}
	var p proto.FileGetPayload
	if err := m.PayloadOf(&p); err != nil || p.Path == "" {
		sendFileGetChunk(sink, m.ID, 0, "", true, "file_get payload 无效", "")
		return
	}
	f, err := os.Open(p.Path)
	if err != nil {
		msg := "打开文件失败: " + err.Error()
		code := ""
		if os.IsNotExist(err) {
			msg = "文件不存在: " + p.Path
			code = proto.ErrorCodeNotFound
		}
		sendFileGetChunk(sink, m.ID, 0, "", true, msg, code)
		return
	}
	defer f.Close()
	log.Printf("[agent] file_get 开始: %s", p.Path)
	buf := make([]byte, fileChunkSize)
	seq, total := 0, 0
	for {
		n, rerr := f.Read(buf)
		if n > 0 {
			total += n
			if total > maxFileSize {
				sendFileGetChunk(sink, m.ID, seq, "", true, fmt.Sprintf("文件过大（上限 %dMB）", maxFileSize>>20), "")
				return
			}
			sendFileGetChunk(sink, m.ID, seq, base64.StdEncoding.EncodeToString(buf[:n]), false, "", "")
			seq++
		}
		if rerr == io.EOF {
			sendFileGetChunk(sink, m.ID, seq, "", true, "", "")
			log.Printf("[agent] file_get 完成: %s (%d 字节)", p.Path, total)
			return
		}
		if rerr != nil {
			sendFileGetChunk(sink, m.ID, seq, "", true, "读取失败: "+rerr.Error(), "")
			return
		}
	}
}

func sendFileGetChunk(sink sendSink, id string, seq int, data string, done bool, errStr, errCode string) {
	out, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFileGetChunk, ID: id},
		proto.FileGetChunkPayload{Seq: seq, Data: data, Done: done, Error: errStr, ErrorCode: errCode})
	if err := sink.SendBlocking(out, 10*time.Second); err != nil {
		sink.CloseConn()
	}
}

// handleFileAbort client 取消上传：清理临时文件。
func (a *Agent) handleFileAbort(m proto.Msg) {
	a.mu.Lock()
	st := a.putFiles[m.ID]
	a.mu.Unlock()
	if st == nil {
		return
	}
	if st.file != nil {
		st.file.Close()
	}
	os.Remove(st.tmpPath)
	a.removeFilePut(m.ID)
	log.Printf("[agent] file_put 取消: %s", st.path)
}

// ---- shell 交互终端 ----

type shellHandle struct {
	sess shellSession
}

// handleShellOpen 同步创建并注册会话（在读循环线程内），随后起 goroutine 泵输出。
func (a *Agent) handleShellOpen(m proto.Msg, sink sendSink) {
	// 并发闸必须持有到会话结束（defer 在函数返回时就释放，会让上限形同虚设）
	select {
	case a.shellSem <- struct{}{}:
	default:
		ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeShellAck, SessionID: m.SessionID},
			proto.ShellAckPayload{OK: false, Error: "并发 shell 超限"})
		sink.Send(ack)
		return
	}
	// 空会话 ID（旧客户端）由 agent 兜底生成，避免注册表键冲突
	sid := m.SessionID
	if sid == "" {
		sid = idutil.New()
	}
	fail := func(why string) {
		<-a.shellSem
		ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeShellAck, SessionID: sid},
			proto.ShellAckPayload{OK: false, Error: why})
		sink.Send(ack)
	}
	sess, err := newShellSession()
	if err != nil {
		fail(err.Error())
		return
	}
	sh := &shellHandle{sess: sess}
	a.mu.Lock()
	if _, dup := a.shells[sid]; dup {
		a.mu.Unlock()
		sess.Close()
		fail("会话 ID 冲突（" + proto.ErrorCodeConflict + "）")
		return
	}
	a.shells[sid] = sh
	a.mu.Unlock()

	ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeShellAck, SessionID: sid},
		proto.ShellAckPayload{OK: true})
	sink.Send(ack)
	log.Printf("[agent] shell 打开: 会话=%s", sid)

	// 进程输出 -> 上行消息
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, rerr := sess.Output().Read(buf)
			if n > 0 {
				data := buf[:n]
				if runtime.GOOS == "windows" {
					data = decodeConsoleOutput(data)
				}
				d, _ := proto.WithPayload(proto.Msg{Type: proto.TypeShellData, SessionID: sid},
					proto.ShellDataPayload{Data: string(data)})
				sink.Send(d)
			}
			if rerr != nil {
				break
			}
		}
	}()
	// 进程退出 -> 从注册表移除、通知关闭会话、释放并发闸（会话生命周期终点）
	go func() {
		sess.Wait()
		a.mu.Lock()
		_, ok := a.shells[sid]
		if ok {
			delete(a.shells, sid)
		}
		a.mu.Unlock()
		<-a.shellSem
		if ok {
			sink.Send(proto.Msg{Type: proto.TypeShellClose, SessionID: sid})
		}
	}()
}

func (a *Agent) handleShellCtrl(m proto.Msg) {
	a.mu.Lock()
	sh := a.shells[m.SessionID]
	a.mu.Unlock()
	if sh == nil {
		return
	}
	switch m.Type {
	case proto.TypeShellData:
		var p proto.ShellDataPayload
		if err := m.PayloadOf(&p); err != nil {
			return
		}
		if _, err := sh.sess.Stdin().Write([]byte(p.Data)); err != nil {
			sh.sess.Close()
		}
	case proto.TypeShellResize:
		var p proto.ShellResizePayload
		if err := m.PayloadOf(&p); err != nil {
			return
		}
		sh.sess.Resize(p.Cols, p.Rows)
	case proto.TypeShellClose:
		// 只关闭进程；会话清理与关闭通知由 wait goroutine（进程退出）统一完成
		sh.sess.Close()
	}
}

// ---- 平台相关 ----

// shellExecArgs 返回执行一条 shell 命令的 argv 与平台相关属性。
// 实现按平台拆分：
//   - shell_exec_linux.go：/bin/sh -c，Setpgid 便于整组终止。
//   - shell_exec_windows.go：cmd /C，用 SysProcAttr.CmdLine 精确控制命令行，
//     避免 Go argv 引用与 cmd.exe 引号规则冲突导致内层引号被剥掉。
// killProcessTree 同理按平台拆分。
