package server

import (
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"
	"time"

	"rtctl/internal/idutil"
	"rtctl/internal/proto"
)

func newSessionID() string { return idutil.New() }

// Device 设备清单中的一台设备。
type Device struct {
	ID    string `json:"id"`
	Token string `json:"token"`
}

// Config 服务器配置（来自 devices.json 等）。
type Config struct {
	Devices []Device `json:"devices"`
}

// Session 一个交互式终端会话：绑定 client 与 agent。
type Session struct {
	ID     string
	Client *ClientConn
	Agent  *AgentConn
}

// execPending 一条在途 exec 的归属绑定：消息 ID -> 发起 client 与目标 agent。
// 输出帧必须同时匹配 client 与 agent 才转发，防止 ID 冲突导致跨客户端串线。
type execPending struct {
	client  *ClientConn
	agent   *AgentConn
	dropped bool // 已有输出帧因背压被丢弃
}

// Hub 持有所有连接状态并负责消息路由。
type Hub struct {
	mu       sync.Mutex
	tokenIdx map[string]Device     // token -> 设备（token 即设备钥匙）
	idIdx    map[string]Device     // device_id -> 设备
	agents   map[string]*AgentConn // device_id -> 在线 agent 连接
	execPend map[string]*execPending
	putPend  map[string]*execPending // 文件上传传输 ID -> {client, agent}
	getPend  map[string]*execPending // 文件下载传输 ID -> {client, agent}
	sessions map[string]*Session     // session_id -> 终端会话
	cliKey   string                  // 客户端密钥（空表示不校验）
	audit    *Audit
}

// NewHub 根据配置创建设备注册表，并校验设备清单。
func NewHub(cfg *Config, cliKey string, audit *Audit) (*Hub, error) {
	h := &Hub{
		tokenIdx: make(map[string]Device),
		idIdx:    make(map[string]Device),
		agents:   make(map[string]*AgentConn),
		execPend: make(map[string]*execPending),
		putPend:  make(map[string]*execPending),
		getPend:  make(map[string]*execPending),
		sessions: make(map[string]*Session),
		cliKey:   cliKey,
		audit:    audit,
	}
	tokenOwner := make(map[string]string) // token -> device id（查重）
	for _, d := range cfg.Devices {
		if d.ID == "" || d.Token == "" {
			return nil, fmt.Errorf("设备清单存在空 id 或空 token")
		}
		if _, dup := h.idIdx[d.ID]; dup {
			return nil, fmt.Errorf("设备清单存在重复 id: %s", d.ID)
		}
		if owner, dup := tokenOwner[d.Token]; dup {
			return nil, fmt.Errorf("设备清单存在重复 token（%s 与 %s 共用），token 必须唯一", owner, d.ID)
		}
		tokenOwner[d.Token] = d.ID
		h.tokenIdx[d.Token] = d
		h.idIdx[d.ID] = d
		if strings.HasPrefix(d.Token, "change-me-") {
			log.Printf("[警告] 设备 %s 使用占位 token（change-me- 前缀），部署前务必更换！", d.ID)
		}
	}
	return h, nil
}

func errMsgCoded(msgID, code, text string) proto.Msg {
	m, _ := proto.WithPayload(proto.Msg{Type: proto.TypeError, ID: msgID},
		proto.ErrorPayload{Error: text, Code: code})
	return m
}

func errMsg(msgID, text string) proto.Msg { return errMsgCoded(msgID, proto.ErrorCodeInternal, text) }

// ---- agent 注册 / 注销 ----

func (h *Hub) registerAgent(ac *AgentConn, m proto.Msg) {
	var p proto.RegisterPayload
	if err := m.PayloadOf(&p); err != nil || p.ID == "" || p.Token == "" {
		// 先送达拒绝原因再断开，确保 agent 能读到（否则只能看到 EOF 而盲目重连）
		ac.sendMsgBlocking(errMsgCoded(m.ID, proto.ErrorCodeBadPayload, "register payload 无效"), 2*time.Second)
		ac.flushAndClose()
		return
	}
	h.mu.Lock()
	d, ok := h.tokenIdx[p.Token]
	if !ok || d.ID != p.ID {
		h.mu.Unlock()
		h.audit.Logf("agent 注册被拒: id=%s 来源=%s", p.ID, ac.addr)
		ac.sendMsgBlocking(errMsgCoded(m.ID, proto.ErrorCodeBadToken, "id 或 token 无效"), 2*time.Second)
		ac.flushAndClose()
		return
	}
	// 同一设备重复上线：踢掉旧连接
	if old, ok := h.agents[d.ID]; ok && old != ac {
		h.mu.Unlock()
		old.close()
		h.mu.Lock()
	}
	ac.deviceID = d.ID
	ac.os, ac.arch, ac.hostname, ac.version = p.OS, p.Arch, p.Hostname, p.Version
	h.agents[d.ID] = ac
	h.mu.Unlock()
	h.audit.Logf("agent 上线: id=%s 来源=%s os=%s/%s 主机=%s 版本=%s",
		d.ID, ac.addr, p.OS, p.Arch, p.Hostname, p.Version)
	ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeRegisterAck}, proto.RegisterAckPayload{OK: true})
	ac.sendMsg(ack)
}

func (h *Hub) unregisterAgent(ac *AgentConn) {
	h.mu.Lock()
	if cur, ok := h.agents[ac.deviceID]; ok && cur == ac {
		delete(h.agents, ac.deviceID)
	}
	var toNotify []*ClientConn
	for sid, s := range h.sessions {
		if s.Agent == ac {
			delete(h.sessions, sid)
			toNotify = append(toNotify, s.Client)
		}
	}
	// 该 agent 上的在途 exec：清理并通知发起 client（否则 client 永久挂起）
	for id, pend := range h.execPend {
		if pend.agent == ac {
			delete(h.execPend, id)
			toNotify = append(toNotify, pend.client)
			// 用 ID 关联到具体 exec，client 才能知道是哪条命令失败
			m, _ := proto.WithPayload(proto.Msg{Type: proto.TypeExecOutput, ID: id},
				proto.ExecOutputPayload{Done: true, ExitCode: 1, Error: "agent 掉线，执行中断",
					ErrorCode: proto.ErrorCodeAgentLost})
			pend.client.sendMsg(m)
		}
	}
	// 该 agent 上的在途文件传输：清理并通知发起 client
	for id, pend := range h.putPend {
		if pend.agent == ac {
			delete(h.putPend, id)
			ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFilePutAck, ID: id},
				proto.FilePutAckPayload{OK: false, Error: "agent 掉线，上传中断"})
			pend.client.sendMsg(ack)
		}
	}
	for id, pend := range h.getPend {
		if pend.agent == ac {
			delete(h.getPend, id)
			done, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFileGetChunk, ID: id},
				proto.FileGetChunkPayload{Done: true, Error: "agent 掉线，下载中断"})
			pend.client.sendMsg(done)
		}
	}
	h.mu.Unlock()
	for _, cc := range toNotify {
		cc.sendMsg(proto.Msg{Type: proto.TypeShellClose})
	}
	if ac.deviceID != "" {
		h.audit.Logf("agent 离线: id=%s", ac.deviceID)
	}
}

// ---- client 认证 / 注销 ----

func (h *Hub) authClient(cc *ClientConn, m proto.Msg) {
	var p proto.AuthPayload
	_ = m.PayloadOf(&p) // 无 payload 时按空处理
	cc.clientID = p.ID
	if h.cliKey == "" {
		ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeAuthAck}, proto.AuthAckPayload{OK: true})
		cc.sendMsg(ack)
		return
	}
	if p.Key != h.cliKey {
		ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeAuthAck}, proto.AuthAckPayload{OK: false, Error: "客户端密钥错误"})
		cc.sendMsg(ack)
		cc.flushAndClose()
		return
	}
	cc.authed = true
	h.audit.Logf("client 上线: id=%s 来源=%s", cc.name(), cc.addr)
	ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeAuthAck}, proto.AuthAckPayload{OK: true})
	cc.sendMsg(ack)
}

func (h *Hub) unregisterClient(cc *ClientConn) {
	h.mu.Lock()
	var toNotify []*AgentConn
	for sid, s := range h.sessions {
		if s.Client == cc {
			delete(h.sessions, sid)
			toNotify = append(toNotify, s.Agent)
		}
	}
	// 清理该 client 的在途 exec，并向 agent 转发 kill，避免孤儿进程继续运行
	var kills []struct {
		id   string
		pend *execPending
	}
	for id, pend := range h.execPend {
		if pend.client == cc {
			delete(h.execPend, id)
			kills = append(kills, struct {
				id   string
				pend *execPending
			}{id, pend})
		}
	}
	// 清理该 client 的在途文件传输：上传转发 abort（agent 清理临时文件）
	var aborts []struct {
		id   string
		pend *execPending
	}
	for id, pend := range h.putPend {
		if pend.client == cc {
			delete(h.putPend, id)
			aborts = append(aborts, struct {
				id   string
				pend *execPending
			}{id, pend})
		}
	}
	for id, pend := range h.getPend {
		if pend.client == cc {
			delete(h.getPend, id)
		}
	}
	h.mu.Unlock()
	for _, ac := range toNotify {
		ac.sendMsg(proto.Msg{Type: proto.TypeShellClose})
	}
	for _, k := range kills {
		kill, _ := proto.WithPayload(proto.Msg{Type: proto.TypeExecKill}, proto.ExecKillPayload{ExecID: k.id})
		k.pend.agent.sendMsg(kill)
	}
	for _, k := range aborts {
		k.pend.agent.sendMsg(proto.Msg{Type: proto.TypeFileAbort, ID: k.id})
	}
}

// clientName 审计归因：优先 client_id，否则来源地址。
func (cc *ClientConn) name() string {
	if cc.clientID != "" {
		return cc.clientID
	}
	return cc.addr
}

// ---- client 消息路由 ----

func (h *Hub) handleClientMsg(cc *ClientConn, m proto.Msg) {
	// 需要认证的指令
	if h.cliKey != "" && !cc.authed && m.Type != proto.TypeAuth {
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeAuthRequired, "请先发送 auth 认证"))
		return
	}
	switch m.Type {
	case proto.TypeAuth:
		h.authClient(cc, m)
	case proto.TypeList:
		h.routeList(cc, m)
	case proto.TypeExec:
		h.routeExec(cc, m)
	case proto.TypeExecKill:
		h.routeExecKill(cc, m)
	case proto.TypeShellOpen:
		h.routeShellOpen(cc, m)
	case proto.TypeShellData, proto.TypeShellResize, proto.TypeShellClose:
		h.routeToAgentBySession(cc, m)
	case proto.TypeFilePut, proto.TypeFilePutChunk:
		h.routeFilePut(cc, m)
	case proto.TypeFileGet:
		h.routeFileGet(cc, m)
	case proto.TypeFileAbort:
		h.routeFileAbort(cc, m)
	default:
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeBadPayload, "未知消息类型: "+m.Type))
	}
}

func (h *Hub) routeList(cc *ClientConn, m proto.Msg) {
	h.mu.Lock()
	out := make([]proto.DeviceInfo, 0, len(h.idIdx))
	for id := range h.idIdx {
		info := proto.DeviceInfo{ID: id}
		if ac, ok := h.agents[id]; ok {
			info.Online = true
			info.OS, info.Arch, info.Hostname, info.Version = ac.os, ac.arch, ac.hostname, ac.version
		}
		out = append(out, info)
	}
	h.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeListAck}, proto.ListAckPayload{Devices: out})
	cc.sendMsg(ack)
}

func (h *Hub) routeExec(cc *ClientConn, m proto.Msg) {
	var p proto.ExecPayload
	if err := m.PayloadOf(&p); err != nil || p.Cmd == "" {
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeBadPayload, "exec payload 无效"))
		return
	}
	if m.ID == "" {
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeBadPayload, "exec 缺少消息 ID"))
		return
	}
	// token 校验：先区分"token 错"与"设备离线"，供 Agent 决策
	h.mu.Lock()
	d, tokOK := h.tokenIdx[m.Token]
	ac := (*AgentConn)(nil)
	if tokOK {
		ac = h.agents[d.ID]
	}
	if !tokOK {
		h.mu.Unlock()
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeBadToken, "token 无效"))
		return
	}
	if ac == nil {
		h.mu.Unlock()
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeOffline, "设备离线"))
		return
	}
	if _, dup := h.execPend[m.ID]; dup {
		h.mu.Unlock()
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeConflict, "exec 消息 ID 冲突"))
		return
	}
	h.execPend[m.ID] = &execPending{client: cc, agent: ac}
	h.mu.Unlock()
	out := m
	out.Token, out.DeviceID = "", "" // 不下发 token
	if err := ac.sendMsg(out); err != nil {
		h.mu.Lock()
		delete(h.execPend, m.ID)
		h.mu.Unlock()
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeInternal, "指令转发失败: "+err.Error()))
		return
	}
	h.audit.Logf("exec: client=%s 设备=%s 命令=%q", cc.name(), ac.deviceID, p.Cmd)
}

func (h *Hub) routeExecKill(cc *ClientConn, m proto.Msg) {
	var p proto.ExecKillPayload
	if err := m.PayloadOf(&p); err != nil || p.ExecID == "" {
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeBadPayload, "exec_kill payload 无效"))
		return
	}
	h.mu.Lock()
	pend := h.execPend[p.ExecID]
	h.mu.Unlock()
	if pend == nil || pend.client != cc {
		return // 不是本 client 发起的执行，忽略
	}
	kill, _ := proto.WithPayload(proto.Msg{Type: proto.TypeExecKill}, proto.ExecKillPayload{ExecID: p.ExecID})
	pend.agent.sendMsg(kill)
}

// resolveAgent 校验 token 并返回目标 agent；失败时向 client 回错误并返回 nil。
func (h *Hub) resolveAgent(cc *ClientConn, token, msgID string) *AgentConn {
	h.mu.Lock()
	d, tokOK := h.tokenIdx[token]
	ac := (*AgentConn)(nil)
	if tokOK {
		ac = h.agents[d.ID]
	}
	h.mu.Unlock()
	if !tokOK {
		cc.sendMsg(errMsgCoded(msgID, proto.ErrorCodeBadToken, "token 无效"))
		return nil
	}
	if ac == nil {
		cc.sendMsg(errMsgCoded(msgID, proto.ErrorCodeOffline, "设备离线"))
		return nil
	}
	return ac
}

// ---- 文件传输路由 ----

// routeFilePut 首条 file_put 绑定传输 (ID -> {client, agent})；后续分片按 ID 转发。
func (h *Hub) routeFilePut(cc *ClientConn, m proto.Msg) {
	if m.ID == "" {
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeBadPayload, "file_put 缺少传输 ID"))
		return
	}
	if m.Type == proto.TypeFilePut {
		var p proto.FilePutPayload
		if err := m.PayloadOf(&p); err != nil || p.Path == "" {
			cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeBadPayload, "file_put payload 无效"))
			return
		}
		ac := h.resolveAgent(cc, m.Token, m.ID)
		if ac == nil {
			return
		}
		h.mu.Lock()
		if _, dup := h.putPend[m.ID]; dup {
			h.mu.Unlock()
			cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeConflict, "传输 ID 冲突"))
			return
		}
		h.putPend[m.ID] = &execPending{client: cc, agent: ac}
		h.mu.Unlock()
		out := m
		out.Token = "" // 不下发 token
		if err := ac.sendMsg(out); err != nil {
			h.mu.Lock()
			delete(h.putPend, m.ID)
			h.mu.Unlock()
			cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeInternal, "指令转发失败: "+err.Error()))
			return
		}
		h.audit.Logf("file_put: client=%s 设备=%s 路径=%q 大小=%d", cc.name(), ac.deviceID, p.Path, p.Size)
		return
	}
	// file_put_chunk：按绑定转发
	h.mu.Lock()
	pend := h.putPend[m.ID]
	h.mu.Unlock()
	if pend == nil || pend.client != cc {
		return
	}
	pend.agent.sendMsg(proto.Msg{Type: proto.TypeFilePutChunk, ID: m.ID, Payload: m.Payload})
}

// routeFilePutAck agent 上传完成回执：清理绑定并可靠送达 client。
func (h *Hub) routeFilePutAck(ac *AgentConn, m proto.Msg) {
	h.mu.Lock()
	pend := h.putPend[m.ID]
	if pend == nil || pend.agent != ac {
		h.mu.Unlock()
		return
	}
	delete(h.putPend, m.ID)
	h.mu.Unlock()
	if err := ccSendBlocking(pend.client, proto.Msg{Type: proto.TypeFilePutAck, ID: m.ID, Payload: m.Payload}, 10*time.Second); err != nil {
		pend.client.close()
	}
}

// routeFileGet 下载请求：绑定传输并转发给 agent。
func (h *Hub) routeFileGet(cc *ClientConn, m proto.Msg) {
	if m.ID == "" {
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeBadPayload, "file_get 缺少传输 ID"))
		return
	}
	var p proto.FileGetPayload
	if err := m.PayloadOf(&p); err != nil || p.Path == "" {
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeBadPayload, "file_get payload 无效"))
		return
	}
	ac := h.resolveAgent(cc, m.Token, m.ID)
	if ac == nil {
		return
	}
	h.mu.Lock()
	if _, dup := h.getPend[m.ID]; dup {
		h.mu.Unlock()
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeConflict, "传输 ID 冲突"))
		return
	}
	h.getPend[m.ID] = &execPending{client: cc, agent: ac}
	h.mu.Unlock()
	out := m
	out.Token = ""
	if err := ac.sendMsg(out); err != nil {
		h.mu.Lock()
		delete(h.getPend, m.ID)
		h.mu.Unlock()
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeInternal, "指令转发失败: "+err.Error()))
		return
	}
	h.audit.Logf("file_get: client=%s 设备=%s 路径=%q", cc.name(), ac.deviceID, p.Path)
}

// routeFileGetChunk agent 下载分片：校验绑定后转发；文件数据不可静默丢弃，
// 阻塞发送，失败即断连（慢消费者保护）。
func (h *Hub) routeFileGetChunk(ac *AgentConn, m proto.Msg) {
	h.mu.Lock()
	pend := h.getPend[m.ID]
	if pend == nil || pend.agent != ac {
		h.mu.Unlock()
		return
	}
	var p proto.FileGetChunkPayload
	done := false
	if json.Unmarshal(m.Payload, &p) == nil {
		done = p.Done
	}
	if done {
		delete(h.getPend, m.ID)
	}
	h.mu.Unlock()
	if err := ccSendBlocking(pend.client, proto.Msg{Type: proto.TypeFileGetChunk, ID: m.ID, Payload: m.Payload}, 10*time.Second); err != nil {
		pend.client.close()
	}
}

// routeFileAbort client 取消自己的上传：通知 agent 清理临时文件。
func (h *Hub) routeFileAbort(cc *ClientConn, m proto.Msg) {
	h.mu.Lock()
	pend := h.putPend[m.ID]
	if pend == nil || pend.client != cc {
		h.mu.Unlock()
		return
	}
	delete(h.putPend, m.ID)
	h.mu.Unlock()
	pend.agent.sendMsg(proto.Msg{Type: proto.TypeFileAbort, ID: m.ID})
}

func (h *Hub) routeShellOpen(cc *ClientConn, m proto.Msg) {
	h.mu.Lock()
	d, tokOK := h.tokenIdx[m.Token]
	ac := (*AgentConn)(nil)
	if tokOK {
		ac = h.agents[d.ID]
	}
	if !tokOK {
		h.mu.Unlock()
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeBadToken, "token 无效"))
		return
	}
	if ac == nil {
		h.mu.Unlock()
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeOffline, "设备离线"))
		return
	}
	sid := newSessionID()
	h.sessions[sid] = &Session{ID: sid, Client: cc, Agent: ac}
	h.mu.Unlock()
	out := proto.Msg{Type: proto.TypeShellOpen, ID: m.ID, SessionID: sid}
	if err := ac.sendMsg(out); err != nil {
		h.mu.Lock()
		delete(h.sessions, sid)
		h.mu.Unlock()
		cc.sendMsg(errMsgCoded(m.ID, proto.ErrorCodeInternal, "指令转发失败: "+err.Error()))
		return
	}
	h.audit.Logf("shell_open: client=%s 设备=%s 会话=%s", cc.name(), ac.deviceID, sid)
}

// routeToAgentBySession 把 client 的 shell_data / shell_resize / shell_close 按会话转发给 agent。
func (h *Hub) routeToAgentBySession(cc *ClientConn, m proto.Msg) {
	h.mu.Lock()
	s := h.sessions[m.SessionID]
	h.mu.Unlock()
	if s == nil || s.Client != cc {
		return
	}
	if m.Type == proto.TypeShellClose {
		h.clientCloseSession(cc, m)
		return
	}
	s.Agent.sendMsg(proto.Msg{Type: m.Type, SessionID: m.SessionID, Payload: m.Payload})
}

// ---- agent 消息路由 ----

func (h *Hub) handleAgentMsg(ac *AgentConn, m proto.Msg) {
	switch m.Type {
	case proto.TypeRegister:
		h.registerAgent(ac, m)
	case proto.TypeExecOutput:
		h.routeExecOutput(ac, m)
	case proto.TypeShellAck, proto.TypeShellData, proto.TypeShellClose:
		h.routeToClientBySession(ac, m)
	case proto.TypeFilePutAck:
		h.routeFilePutAck(ac, m)
	case proto.TypeFileGetChunk:
		h.routeFileGetChunk(ac, m)
	default:
		log.Printf("[hub] agent %s 发送未知消息类型: %s", ac.deviceID, m.Type)
	}
}

func (h *Hub) routeExecOutput(ac *AgentConn, m proto.Msg) {
	h.mu.Lock()
	pend := h.execPend[m.ID]
	if pend == nil || pend.agent != ac {
		h.mu.Unlock()
		return // 未知 ID 或来自非目标 agent：拒绝转发，防止串线
	}
	var p proto.ExecOutputPayload
	isDone := false
	if len(m.Payload) > 0 {
		if json.Unmarshal(m.Payload, &p) == nil {
			isDone = p.Done
		}
	}
	if isDone {
		delete(h.execPend, m.ID)
	}
	h.mu.Unlock()

	if isDone {
		// done 帧必须可靠送达：若 server 侧也丢过帧，标注 Truncated
		out := m
		if pend.dropped {
			p.Truncated = true
			if b, err := json.Marshal(p); err == nil {
				out.Payload = b
			}
		}
		if err := ccSendBlocking(pend.client, out, 5*time.Second); err != nil {
			// 客户端写不动，说明连接已死：关闭触发清理，避免 client 永久等待
			pend.client.close()
		}
		return
	}
	if err := pend.client.sendMsg(proto.Msg{Type: proto.TypeExecOutput, ID: m.ID, Payload: m.Payload}); err != nil {
		// 背压丢帧：记录以便在 done 帧上打截断标记
		h.mu.Lock()
		if cur, ok := h.execPend[m.ID]; ok && cur == pend {
			pend.dropped = true
		}
		h.mu.Unlock()
	}
}

// routeToClientBySession 把 agent 的 shell_ack / shell_data / shell_close 按会话转发给 client。
func (h *Hub) routeToClientBySession(ac *AgentConn, m proto.Msg) {
	h.mu.Lock()
	s := h.sessions[m.SessionID]
	h.mu.Unlock()
	if s == nil || s.Agent != ac {
		return
	}
	if m.Type == proto.TypeShellClose {
		h.agentCloseSession(ac, m)
		return
	}
	s.Client.sendMsg(proto.Msg{Type: m.Type, ID: m.ID, SessionID: m.SessionID, Payload: m.Payload})
}

// clientCloseSession client 主动关闭：转发给 agent，由 agent 优雅退出后确认。
func (h *Hub) clientCloseSession(cc *ClientConn, m proto.Msg) {
	h.mu.Lock()
	s := h.sessions[m.SessionID]
	h.mu.Unlock()
	if s == nil || s.Client != cc {
		return
	}
	s.Agent.sendMsg(proto.Msg{Type: proto.TypeShellClose, SessionID: m.SessionID})
}

// agentCloseSession agent 确认关闭（远端进程已退出）：清理会话并通知 client。
func (h *Hub) agentCloseSession(ac *AgentConn, m proto.Msg) {
	h.mu.Lock()
	s := h.sessions[m.SessionID]
	if s == nil || s.Agent != ac {
		h.mu.Unlock()
		return
	}
	delete(h.sessions, m.SessionID)
	h.mu.Unlock()
	s.Client.sendMsg(proto.Msg{Type: proto.TypeShellClose, SessionID: m.SessionID})
	h.audit.Logf("shell_close: 设备=%s 会话=%s", ac.deviceID, s.ID)
}

func (h *Hub) agentByToken(token string) *AgentConn {
	h.mu.Lock()
	defer h.mu.Unlock()
	d, ok := h.tokenIdx[token]
	if !ok {
		return nil
	}
	return h.agents[d.ID]
}
