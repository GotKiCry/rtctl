// Package agent 实现被控端：连接服务器、接收指令、执行命令。
package agent

import (
	"context"
	"encoding/base64"
	"encoding/json"
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

	"rtctl/internal/proto"
)

// Version agent 版本号，随 register 上报。
const Version = "2.0.0"

const (
	execSendQueueSize  = 256
	maxConcurrentExec  = 32 // 单设备并发 exec 上限
	maxConcurrentShell = 8  // 单设备并发 shell 上限
	maxConcurrentPut   = 8  // 单设备并发上传上限
	maxConcurrentGet   = 8  // 单设备并发下载上限
	fileChunkSize      = 256 * 1024
	maxFileSize        = 256 << 20 // 单文件上限 256MB
)

var (
	errSendQueueFull = errors.New("发送队列已满")
	// errAuthRejected 注册被拒绝：id/token 无效，重连无意义，立即退出。
	errAuthRejected = errors.New("注册被拒绝（id 或 token 无效），停止重连")
)

// Agent 被控端。
type Agent struct {
	ServerURL string
	ID        string
	Token     string

	mu       sync.Mutex
	ws       *websocket.Conn               // 由 mu 保护；每轮连接替换
	send     chan []byte                   // 由 mu 保护；每轮连接替换
	execs    map[string]context.CancelFunc // exec 消息 ID -> 取消函数
	shells   map[string]*shellHandle       // session_id -> 终端会话
	putFiles map[string]*filePutState      // 传输 ID -> 上传状态

	execSem  chan struct{} // exec 并发信号量
	shellSem chan struct{} // shell 并发信号量
	getSem   chan struct{} // 文件下载并发信号量（上传并发按 putFiles 计数）
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
func New(serverURL, id, token string) *Agent {
	return &Agent{
		ServerURL: serverURL,
		ID:        id,
		Token:     token,
		execs:     make(map[string]context.CancelFunc),
		shells:    make(map[string]*shellHandle),
		putFiles:  make(map[string]*filePutState),
		execSem:   make(chan struct{}, maxConcurrentExec),
		shellSem:  make(chan struct{}, maxConcurrentShell),
		getSem:    make(chan struct{}, maxConcurrentGet),
	}
}

// Run 主循环：连接 -> 注册 -> 服务，断线自动重连（指数退避，上限 30s）。
// 注册被拒绝（token 错误）时立即返回错误退出，不无限重连。
func (a *Agent) Run(ctx context.Context) error {
	delay := time.Second
	for {
		select {
		case <-ctx.Done():
			return nil
		default:
		}
		err := a.connectAndServe(ctx)
		a.cleanup()
		if err == nil {
			return nil
		}
		if errors.Is(err, errAuthRejected) {
			return err // 不重连
		}
		log.Printf("[agent] 连接断开: %v，%s 后重连", err, delay)
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(delay):
		}
		if delay < 30*time.Second {
			delay *= 2
			if delay > 30*time.Second {
				delay = 30 * time.Second
			}
		}
	}
}

// connectAndServe 连接服务器并服务消息，直到连接断开。
// ws 与 send 通道作为本轮连接的局部资源，旧连接的 goroutine 不会触碰新连接。
func (a *Agent) connectAndServe(ctx context.Context) error {
	conn, _, err := websocket.DefaultDialer.Dial(a.ServerURL, nil)
	if err != nil {
		return err
	}
	send := make(chan []byte, execSendQueueSize)
	a.mu.Lock()
	a.ws, a.send = conn, send
	a.mu.Unlock()
	go writePump(conn, send)

	// 注册（携带设备元数据，供 server list 展示）
	hostname, _ := os.Hostname()
	reg, _ := proto.WithPayload(proto.Msg{Type: proto.TypeRegister, DeviceID: a.ID},
		proto.RegisterPayload{ID: a.ID, Token: a.Token,
			OS: runtime.GOOS, Arch: runtime.GOARCH, Hostname: hostname, Version: Version})
	if err := conn.WriteJSON(reg); err != nil {
		conn.Close()
		return err
	}

	conn.SetReadLimit(4 << 20)
	conn.SetReadDeadline(time.Now().Add(90 * time.Second))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(90 * time.Second))
		return nil
	})
	log.Printf("[agent] 已连接 %s，等待指令（设备 %s）", a.ServerURL, a.ID)

	registered := false
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		var m proto.Msg
		if err := json.Unmarshal(data, &m); err != nil {
			log.Printf("[agent] 消息解析失败: %v", err)
			continue
		}
		if !registered {
			// 注册确认前只接受 register_ack / error
			switch m.Type {
			case proto.TypeRegisterAck:
				var p proto.RegisterAckPayload
				_ = m.PayloadOf(&p)
				if !p.OK {
					return errAuthRejected
				}
				registered = true
			case proto.TypeError:
				return errAuthRejected
			default:
				continue // 忽略注册前指令
			}
			continue
		}
		a.handleMsg(ctx, m, a)
	}
}

// writePump 每轮连接独立的写循环（参数局部化，避免跨连接串写）。
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

// sendMsg 把消息放入当前连接的发送队列（非阻塞，队列满返回 errSendQueueFull）。
func (a *Agent) sendMsg(m proto.Msg) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	a.mu.Lock()
	send := a.send
	a.mu.Unlock()
	if send == nil {
		return errSendQueueFull
	}
	select {
	case send <- b:
		return nil
	default:
		return errSendQueueFull
	}
}

// sendMsgBlocking 阻塞发送关键帧（done / ack），队列满时最多等待 timeout。
func (a *Agent) sendMsgBlocking(m proto.Msg, timeout time.Duration) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	a.mu.Lock()
	send := a.send
	a.mu.Unlock()
	if send == nil {
		return errors.New("连接已关闭")
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case send <- b:
		return nil
	case <-timer.C:
		return errors.New("发送超时")
	}
}

// cleanup 连接断开后清理所有执行与终端。
func (a *Agent) cleanup() {
	a.mu.Lock()
	ws := a.ws
	a.ws, a.send = nil, nil
	for _, cancel := range a.execs {
		cancel()
	}
	a.execs = make(map[string]context.CancelFunc)
	shells := make([]*shellHandle, 0, len(a.shells))
	for _, sh := range a.shells {
		shells = append(shells, sh)
	}
	a.shells = make(map[string]*shellHandle)
	puts := make([]*filePutState, 0, len(a.putFiles))
	for _, st := range a.putFiles {
		puts = append(puts, st)
	}
	a.putFiles = make(map[string]*filePutState)
	a.mu.Unlock()
	for _, sh := range shells {
		sh.sess.Close()
	}
	for _, st := range puts {
		if st.file != nil {
			st.file.Close()
		}
		os.Remove(st.tmpPath)
	}
	if ws != nil {
		ws.Close()
	}
}

// sendSink 响应目标抽象：中继模式下为 agent 全局发送队列，
// 直连（standalone）模式下为对应客户端的连接队列。
type sendSink interface {
	Send(proto.Msg) error
	SendBlocking(proto.Msg, time.Duration) error
	CloseConn() // 关键帧送达失败时断开对应连接
}

// Send 实现 sendSink（中继模式：写入全局队列）。
func (a *Agent) Send(m proto.Msg) error { return a.sendMsg(m) }

// SendBlocking 实现 sendSink（中继模式）。
func (a *Agent) SendBlocking(m proto.Msg, timeout time.Duration) error {
	return a.sendMsgBlocking(m, timeout)
}

// CloseConn 实现 sendSink（中继模式：断开与服务器的连接）。
func (a *Agent) CloseConn() {
	a.mu.Lock()
	ws := a.ws
	a.mu.Unlock()
	if ws != nil {
		ws.Close()
	}
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
		// 同步创建临时文件并注册状态，避免后续分片早于注册到达被丢弃
		a.handleFilePut(m, sink)
	case proto.TypeFilePutChunk:
		a.handleFilePutChunk(m)
	case proto.TypeFileGet:
		go a.handleFileGet(m, sink)
	case proto.TypeFileAbort:
		a.handleFileAbort(m)
	case proto.TypeRegisterAck:
		// 已注册后忽略重复 ack
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
	ctx, cancel := context.WithCancel(context.Background())
	if p.TimeoutMS > 0 {
		ctx, cancel = context.WithTimeout(ctx, time.Duration(p.TimeoutMS)*time.Millisecond)
	}
	a.mu.Lock()
	a.execs[m.ID] = cancel
	a.mu.Unlock()
	defer func() {
		cancel()
		a.mu.Lock()
		delete(a.execs, m.ID)
		a.mu.Unlock()
	}()

	argv, sysProc := shellExecArgs(p.Cmd)
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
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
	// 超时/取消时终止整个进程树（孙进程也要杀）
	go func() {
		<-ctx.Done()
		if ctx.Err() != nil {
			killProcessTree(cmd)
		}
	}()
	waitCh := make(chan error, 1)
	go func() {
		waitCh <- cmd.Wait()
		pw.Close()
	}()
	log.Printf("[agent] exec 开始: %s", p.Cmd)

	buf := make([]byte, 32*1024)
	seq := 0
	truncated := false
	for ctx.Err() == nil {
		n, rerr := pr.Read(buf)
		if n > 0 {
			data := buf[:n]
			if runtime.GOOS == "windows" {
				data = decodeConsoleOutput(data)
			}
			if err := sendExecOutput(sink, m.ID, string(data), false, 0, "", "", false); err != nil {
				truncated = true // 背压丢帧：在 done 帧上打截断标记
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
// 分片由 handleFilePutChunk（读循环内串行）处理，最后一片 done=true 落盘。
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
		a.failFilePut(m.ID, st, "分片解析失败")
		return
	}
	data, err := base64.StdEncoding.DecodeString(p.Data)
	if err != nil {
		a.failFilePut(m.ID, st, "分片 base64 解码失败")
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
	// 完成：关闭、chmod、原子改名（Windows 需先移除同名目标）
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

// handleFileGet 下载文件：分片流式回传；文件数据必须可靠送达（阻塞发送）。
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
	select {
	case a.shellSem <- struct{}{}:
		defer func() { <-a.shellSem }()
	default:
		ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeShellAck, SessionID: m.SessionID},
			proto.ShellAckPayload{OK: false, Error: "并发 shell 超限"})
		sink.Send(ack)
		return
	}
	sess, err := newShellSession()
	if err != nil {
		ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeShellAck, SessionID: m.SessionID},
			proto.ShellAckPayload{OK: false, Error: err.Error()})
		sink.Send(ack)
		return
	}
	sh := &shellHandle{sess: sess}
	a.mu.Lock()
	a.shells[m.SessionID] = sh
	a.mu.Unlock()

	ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeShellAck, SessionID: m.SessionID},
		proto.ShellAckPayload{OK: true})
	sink.Send(ack)
	log.Printf("[agent] shell 打开: 会话=%s", m.SessionID)

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
				d, _ := proto.WithPayload(proto.Msg{Type: proto.TypeShellData, SessionID: m.SessionID},
					proto.ShellDataPayload{Data: string(data)})
				sink.Send(d)
			}
			if rerr != nil {
				break
			}
		}
	}()
	// 进程退出 -> 从注册表移除并通知服务器关闭会话
	go func() {
		sess.Wait()
		a.mu.Lock()
		_, ok := a.shells[m.SessionID]
		if ok {
			delete(a.shells, m.SessionID)
		}
		a.mu.Unlock()
		if ok {
			sink.Send(proto.Msg{Type: proto.TypeShellClose, SessionID: m.SessionID})
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
