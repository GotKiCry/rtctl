// serve.go —— rtctl-client serve：常驻 HTTP 服务。
// AI Agent / 自动化程序通过本服务操控目标设备，无需处理 token、无需手动传输文件。
//
// 两种设备接入方式（可在同一份设备清单中混用）：
//   - 直连：设备清单中带 url 的条目，clientd 直接连接 agent 的 WS 端口（无需中继）
//   - 中继：不带 url 的条目，经 -server 指定的中继服务器转发（NAT 场景）
//
// 设备清单格式（与 server 的 devices.json 兼容，url 可选）:
//
//	{ "devices": [ { "id": "jp", "url": "wss://1.2.3.4:8443/ws", "token": "..." },
//	               { "id": "web-01", "token": "..." } ] }
//
// API（Authorization: Bearer <api-key>）:
//
//	GET  /healthz                     健康检查（免认证）
//	GET  /api/v1/devices              设备列表
//	POST /api/v1/exec                 {"device_id","cmd","timeout_ms","workdir","stdin"}
//	POST /api/v1/files/upload         {"device_id","path","data"(base64),"mode"}
//	POST /api/v1/files/download       {"device_id","path"}
package main

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"rtctl/internal/idutil"
	"rtctl/internal/proto"
)

const serveChunkSize = 256 * 1024

// serveConfig 本地设备清单（device_id -> token[+url]）。
type serveConfig struct {
	Devices []struct {
		ID    string `json:"id"`
		Token string `json:"token"`
		URL   string `json:"url,omitempty"` // 直连地址（ws://或wss://），留空经中继
	} `json:"devices"`
}

// deviceTarget 一个设备的接入信息。
type deviceTarget struct {
	id    string
	token string
	url   string // 空 = 经中继
}

// wsHub 与中继的常驻连接：写队列 + 按消息 ID 分发响应。
type wsHub struct {
	serverURL string
	key       string
	clientID  string

	mu      sync.Mutex
	conn    *websocket.Conn
	send    chan []byte
	dead    chan struct{} // 当前连接存活信号；断开时关闭
	pending map[string]chan proto.Msg

	listMu sync.Mutex // 串行化 list 请求（list_ack 不带 ID）
	listCh chan proto.Msg
}

func newWSHub(serverURL, key, clientID string) *wsHub {
	return &wsHub{
		serverURL: serverURL,
		key:       key,
		clientID:  clientID,
		pending:   make(map[string]chan proto.Msg),
		listCh:    make(chan proto.Msg, 8),
	}
}

// run 连接 + 服务，断线指数退避重连（上限 30s）。
func (h *wsHub) run(ctx context.Context) {
	delay := time.Second
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		err := h.serveOnce()
		h.failAll()
		if err != nil {
			log.Printf("[clientd] 中继连接断开: %v，%s 后重连", err, delay)
		}
		select {
		case <-ctx.Done():
			return
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

// serveOnce 建立一次连接并服务消息直到断开。
func (h *wsHub) serveOnce() error {
	conn, _, err := websocket.DefaultDialer.Dial(h.serverURL, nil)
	if err != nil {
		return err
	}
	auth, _ := proto.WithPayload(proto.Msg{Type: proto.TypeAuth}, proto.AuthPayload{Key: h.key, ID: h.clientID})
	if err := conn.WriteJSON(auth); err != nil {
		conn.Close()
		return err
	}
	var ack proto.Msg
	if err := conn.ReadJSON(&ack); err != nil {
		conn.Close()
		return err
	}
	var p proto.AuthAckPayload
	ack.PayloadOf(&p)
	if !p.OK {
		conn.Close()
		return errors.New(p.Error)
	}

	send := make(chan []byte, 256)
	dead := make(chan struct{})
	h.mu.Lock()
	h.conn, h.send, h.dead, h.pending = conn, send, dead, make(map[string]chan proto.Msg)
	h.mu.Unlock()
	log.Printf("[clientd] 已连接中继 %s", h.serverURL)

	// 写循环（本轮连接的局部资源）
	go func() {
		ticker := time.NewTicker(25 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case b := <-send:
				conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				if err := conn.WriteMessage(websocket.TextMessage, b); err != nil {
					conn.Close()
					return
				}
			case <-ticker.C:
				conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					conn.Close()
					return
				}
			}
		}
	}()

	// 读循环：list_ack 走独立通道，其余按 ID 分发（阻塞推送 = 天然背压）
	conn.SetReadLimit(4 << 20)
	conn.SetReadDeadline(time.Now().Add(90 * time.Second))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(90 * time.Second))
		return nil
	})
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		var m proto.Msg
		if err := json.Unmarshal(data, &m); err != nil {
			continue
		}
		if m.Type == proto.TypeListAck {
			select {
			case h.listCh <- m:
			default:
			}
			continue
		}
		if m.ID == "" {
			continue
		}
		h.mu.Lock()
		ch := h.pending[m.ID]
		h.mu.Unlock()
		if ch != nil {
			ch <- m
		}
	}
}

// failAll 连接断开：关闭死信号并向所有等待者广播连接丢失错误。
func (h *wsHub) failAll() {
	h.mu.Lock()
	if h.dead != nil {
		close(h.dead)
	}
	for id, ch := range h.pending {
		em, _ := proto.WithPayload(proto.Msg{Type: proto.TypeError, ID: id},
			proto.ErrorPayload{Error: "与中继的连接断开", Code: proto.ErrorCodeConnLost})
		select {
		case ch <- em:
		default:
		}
	}
	h.pending = make(map[string]chan proto.Msg)
	h.dead = nil
	h.mu.Unlock()
}

// request 注册等待者并发送消息，返回响应通道与连接死信号。
func (h *wsHub) request(ctx context.Context, m proto.Msg) (chan proto.Msg, chan struct{}, error) {
	ch := make(chan proto.Msg, 256)
	b, err := json.Marshal(m)
	if err != nil {
		return nil, nil, err
	}
	h.mu.Lock()
	if h.dead == nil || h.send == nil {
		h.mu.Unlock()
		return nil, nil, errors.New("中继未连接")
	}
	h.pending[m.ID] = ch
	send, dead := h.send, h.dead
	h.mu.Unlock()
	select {
	case send <- b:
		return ch, dead, nil
	case <-ctx.Done():
		h.unregister(m.ID)
		return nil, nil, ctx.Err()
	}
}

// sendRaw 直接发送一条消息（无需等待响应）。
func (h *wsHub) sendRaw(m proto.Msg) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	h.mu.Lock()
	send := h.send
	h.mu.Unlock()
	if send == nil {
		return errors.New("中继未连接")
	}
	select {
	case send <- b:
		return nil
	case <-time.After(3 * time.Second):
		return errors.New("发送超时")
	}
}

func (h *wsHub) unregister(id string) {
	h.mu.Lock()
	delete(h.pending, id)
	h.mu.Unlock()
}

// ---- HTTP 层 ----

type serveAPI struct {
	hub     *wsHub
	apiKey  string
	devices map[string]deviceTarget
}

func cmdServe(args []string) error {
	sub := flag.NewFlagSet("serve", flag.ExitOnError)
	listen := sub.String("listen", "127.0.0.1:18080", "HTTP 监听地址（Agent 调用入口）")
	devicesFile := sub.String("devices", "devices.json", "设备清单（device_id -> token[+url]，url 留空经中继）")
	apiKey := sub.String("api-key", "", "API 密钥（留空自动生成并打印一次）")
	sub.Parse(args)

	data, err := os.ReadFile(*devicesFile)
	if err != nil {
		return fmt.Errorf("读取设备清单失败: %w", err)
	}
	var cfg serveConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return fmt.Errorf("解析设备清单失败: %w", err)
	}
	devices := make(map[string]deviceTarget, len(cfg.Devices))
	for _, d := range cfg.Devices {
		if d.ID == "" || d.Token == "" {
			return errors.New("设备清单存在空 id 或空 token")
		}
		devices[d.ID] = deviceTarget{id: d.ID, token: d.Token, url: d.URL}
	}
	if len(devices) == 0 {
		return errors.New("设备清单为空")
	}
	if *apiKey == "" {
		*apiKey = idutil.New()
		log.Printf("[clientd] 未指定 -api-key，已自动生成: %s", *apiKey)
	}
	cid := clientID
	if cid == "" {
		cid = "clientd"
	}
	hub := newWSHub(serverURL, clientKey, cid)
	go hub.run(context.Background())
	api := &serveAPI{hub: hub, apiKey: *apiKey, devices: devices}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("/api/v1/devices", api.withAuth(api.handleDevices))
	mux.HandleFunc("/api/v1/exec", api.withAuth(api.handleExec))
	mux.HandleFunc("/api/v1/files/upload", api.withAuth(api.handleUpload))
	mux.HandleFunc("/api/v1/files/download", api.withAuth(api.handleDownload))

	httpSrv := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("[clientd] HTTP 服务启动: http://%s  (Authorization: Bearer %s)", *listen, *apiKey)
	return httpSrv.ListenAndServe()
}

func (a *serveAPI) withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(token), []byte(a.apiKey)) != 1 {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "未授权：缺少或错误的 API 密钥")
			return
		}
		next(w, r)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": msg, "error_code": code})
}

// dialDirect 直连设备：拨号 + auth 握手。
func dialDirect(ctx context.Context, url string) (*websocket.Conn, error) {
	d := websocket.Dialer{HandshakeTimeout: 10 * time.Second}
	conn, _, err := d.DialContext(ctx, url, nil)
	if err != nil {
		return nil, err
	}
	cid := clientID
	if cid == "" {
		cid = "clientd"
	}
	auth, _ := proto.WithPayload(proto.Msg{Type: proto.TypeAuth}, proto.AuthPayload{ID: cid})
	if err := conn.WriteJSON(auth); err != nil {
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

// probeDirect 直连设备探活：返回设备信息（失败返回 offline 与错误）。
func probeDirect(ctx context.Context, tgt deviceTarget) proto.DeviceInfo {
	info := proto.DeviceInfo{ID: tgt.id}
	conn, err := dialDirect(ctx, tgt.url)
	if err != nil {
		return info
	}
	defer conn.Close()
	if err := conn.WriteJSON(proto.Msg{Type: proto.TypeList}); err != nil {
		return info
	}
	var m proto.Msg
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if err := conn.ReadJSON(&m); err != nil || m.Type != proto.TypeListAck {
		return info
	}
	var p proto.ListAckPayload
	if m.PayloadOf(&p) == nil && len(p.Devices) > 0 {
		d := p.Devices[0]
		d.ID = tgt.id
		return d
	}
	return info
}

// handleDevices 设备列表：中继设备 + 直连设备（逐个探活）。
func (a *serveAPI) handleDevices(w http.ResponseWriter, r *http.Request) {
	relayDevices := map[string]proto.DeviceInfo{}
	var direct []deviceTarget
	for _, t := range a.devices {
		if t.url == "" {
			relayDevices[t.id] = proto.DeviceInfo{ID: t.id}
		} else {
			direct = append(direct, t)
		}
	}
	if len(relayDevices) > 0 {
		a.hub.listMu.Lock()
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		for {
			select {
			case <-a.hub.listCh:
			default:
				goto drained
			}
		}
	drained:
		if err := a.hub.sendRaw(proto.Msg{Type: proto.TypeList}); err == nil {
			select {
			case m := <-a.hub.listCh:
				var p proto.ListAckPayload
				if m.PayloadOf(&p) == nil {
					for _, d := range p.Devices {
						relayDevices[d.ID] = d
					}
				}
			case <-ctx.Done():
			}
		}
		cancel()
		a.hub.listMu.Unlock()
	}

	out := make([]proto.DeviceInfo, 0, len(a.devices))
	seen := map[string]bool{}
	for _, t := range a.devices {
		if t.url != "" {
			probeCtx, cancel := context.WithTimeout(r.Context(), 6*time.Second)
			out = append(out, probeDirect(probeCtx, t))
			cancel()
			seen[t.id] = true
		}
	}
	for id, d := range relayDevices {
		if !seen[id] {
			out = append(out, d)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

// execReq exec 请求体。
type execReq struct {
	DeviceID  string `json:"device_id"`
	Cmd       string `json:"cmd"`
	TimeoutMS int    `json:"timeout_ms"`
	Workdir   string `json:"workdir"`
	Stdin     string `json:"stdin"`
}

// handleExec 执行命令并等待完成（直连/中继自动分派）。
func (a *serveAPI) handleExec(w http.ResponseWriter, r *http.Request) {
	var req execReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadPayload, "请求体无效")
		return
	}
	if req.DeviceID == "" || req.Cmd == "" {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadPayload, "device_id 与 cmd 必填")
		return
	}
	tgt, ok := a.devices[req.DeviceID]
	if !ok {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadDevice, "未知设备: "+req.DeviceID)
		return
	}
	if tgt.url != "" {
		a.execDirect(w, r, tgt, req)
		return
	}
	a.execRelay(w, r, tgt, req)
}

// execDirect 直连设备：独立连接 + 单次执行。
func (a *serveAPI) execDirect(w http.ResponseWriter, r *http.Request, tgt deviceTarget, req execReq) {
	overall := 1 * time.Hour
	if req.TimeoutMS > 0 {
		overall = time.Duration(req.TimeoutMS)*time.Millisecond + 30*time.Second
	}
	ctx, cancel := context.WithTimeout(r.Context(), overall)
	defer cancel()
	conn, err := dialDirect(ctx, tgt.url)
	if err != nil {
		writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, "连接设备失败: "+err.Error())
		return
	}
	defer conn.Close()
	conn.SetReadDeadline(time.Now().Add(overall))

	id := idutil.New()
	m := proto.Msg{Type: proto.TypeExec, ID: id, Token: tgt.token}
	m, _ = proto.WithPayload(m, proto.ExecPayload{Cmd: req.Cmd, TimeoutMS: req.TimeoutMS, Workdir: req.Workdir, Stdin: req.Stdin})
	if err := conn.WriteJSON(m); err != nil {
		writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, err.Error())
		return
	}
	var sb strings.Builder
	start := time.Now()
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			if ctx.Err() != nil {
				writeErr(w, http.StatusGatewayTimeout, proto.ErrorCodeTimeout, "执行超时")
				return
			}
			writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, "连接中断: "+err.Error())
			return
		}
		var msg proto.Msg
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		switch msg.Type {
		case proto.TypeExecOutput:
			var p proto.ExecOutputPayload
			msg.PayloadOf(&p)
			sb.WriteString(p.Data)
			if p.Done {
				writeJSON(w, http.StatusOK, map[string]any{
					"exit_code":   p.ExitCode,
					"output":      sb.String(),
					"truncated":   p.Truncated,
					"error":       p.Error,
					"error_code":  p.ErrorCode,
					"duration_ms": time.Since(start).Milliseconds(),
				})
				return
			}
		case proto.TypeError:
			var p proto.ErrorPayload
			msg.PayloadOf(&p)
			writeErr(w, http.StatusBadGateway, p.Code, p.Error)
			return
		}
	}
}

// execRelay 中继设备：经常驻中继连接执行。
func (a *serveAPI) execRelay(w http.ResponseWriter, r *http.Request, tgt deviceTarget, req execReq) {
	id := idutil.New()
	overall := 1 * time.Hour
	if req.TimeoutMS > 0 {
		overall = time.Duration(req.TimeoutMS)*time.Millisecond + 30*time.Second
	}
	ctx, cancel := context.WithTimeout(r.Context(), overall)
	defer cancel()

	m := proto.Msg{Type: proto.TypeExec, ID: id, Token: tgt.token}
	m, _ = proto.WithPayload(m, proto.ExecPayload{Cmd: req.Cmd, TimeoutMS: req.TimeoutMS, Workdir: req.Workdir, Stdin: req.Stdin})
	ch, dead, err := a.hub.request(ctx, m)
	if err != nil {
		writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, err.Error())
		return
	}
	defer a.hub.unregister(id)

	var sb strings.Builder
	start := time.Now()
	for {
		select {
		case <-ctx.Done():
			// 调用方超时/断开：取消远端执行，避免孤儿进程
			kill, _ := proto.WithPayload(proto.Msg{Type: proto.TypeExecKill, Token: tgt.token},
				proto.ExecKillPayload{ExecID: id})
			a.hub.sendRaw(kill)
			writeErr(w, http.StatusGatewayTimeout, proto.ErrorCodeTimeout, "执行超时")
			return
		case <-dead:
			writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, "与中继的连接断开")
			return
		case m := <-ch:
			switch m.Type {
			case proto.TypeExecOutput:
				var p proto.ExecOutputPayload
				m.PayloadOf(&p)
				sb.WriteString(p.Data)
				if p.Done {
					writeJSON(w, http.StatusOK, map[string]any{
						"exit_code":   p.ExitCode,
						"output":      sb.String(),
						"truncated":   p.Truncated,
						"error":       p.Error,
						"error_code":  p.ErrorCode,
						"duration_ms": time.Since(start).Milliseconds(),
					})
					return
				}
			case proto.TypeError:
				var p proto.ErrorPayload
				m.PayloadOf(&p)
				writeErr(w, http.StatusBadGateway, p.Code, p.Error)
				return
			}
		}
	}
}

// handleUpload 上传文件（data 为 base64）。
func (a *serveAPI) handleUpload(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID string `json:"device_id"`
		Path     string `json:"path"`
		Data     string `json:"data"`
		Mode     uint32 `json:"mode"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 192<<20)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadPayload, "请求体无效或过大")
		return
	}
	if req.DeviceID == "" || req.Path == "" || req.Data == "" {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadPayload, "device_id / path / data 必填")
		return
	}
	raw, err := base64.StdEncoding.DecodeString(req.Data)
	if err != nil {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadPayload, "data 不是合法 base64")
		return
	}
	if len(raw) > 128<<20 {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadPayload, "文件过大（上限 128MB）")
		return
	}
	tgt, ok := a.devices[req.DeviceID]
	if !ok {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadDevice, "未知设备: "+req.DeviceID)
		return
	}
	if tgt.url != "" {
		a.uploadDirect(w, r, tgt, req.Path, req.Mode, raw)
		return
	}
	a.uploadRelay(w, r, tgt, req.Path, req.Mode, raw)
}

// uploadDirect 直连上传：独立连接，分片发送。
func (a *serveAPI) uploadDirect(w http.ResponseWriter, r *http.Request, tgt deviceTarget, path string, mode uint32, raw []byte) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()
	conn, err := dialDirect(ctx, tgt.url)
	if err != nil {
		writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, "连接设备失败: "+err.Error())
		return
	}
	defer conn.Close()

	id := idutil.New()
	begin, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFilePut, ID: id, Token: tgt.token},
		proto.FilePutPayload{Path: path, Mode: mode, Size: int64(len(raw))})
	if err := conn.WriteJSON(begin); err != nil {
		writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, err.Error())
		return
	}
	for off := 0; off < len(raw); off += serveChunkSize {
		end := off + serveChunkSize
		if end > len(raw) {
			end = len(raw)
		}
		chunk, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFilePutChunk, ID: id},
			proto.FileChunkPayload{Seq: off / serveChunkSize,
				Data: base64.StdEncoding.EncodeToString(raw[off:end]), Done: end == len(raw)})
		if err := conn.WriteJSON(chunk); err != nil {
			writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, "发送分片失败: "+err.Error())
			return
		}
	}
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, "等待回执失败: "+err.Error())
			return
		}
		var m proto.Msg
		if err := json.Unmarshal(data, &m); err != nil {
			continue
		}
		switch m.Type {
		case proto.TypeFilePutAck:
			var p proto.FilePutAckPayload
			m.PayloadOf(&p)
			if !p.OK {
				writeErr(w, http.StatusBadGateway, "", p.Error)
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "path": path, "size": len(raw)})
			return
		case proto.TypeError:
			var p proto.ErrorPayload
			m.PayloadOf(&p)
			writeErr(w, http.StatusBadGateway, p.Code, p.Error)
			return
		}
	}
}

// uploadRelay 中继上传（复用常驻连接）。
func (a *serveAPI) uploadRelay(w http.ResponseWriter, r *http.Request, tgt deviceTarget, path string, mode uint32, raw []byte) {
	id := idutil.New()
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()

	begin, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFilePut, ID: id, Token: tgt.token},
		proto.FilePutPayload{Path: path, Mode: mode, Size: int64(len(raw))})
	ch, dead, err := a.hub.request(ctx, begin)
	if err != nil {
		writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, err.Error())
		return
	}
	defer a.hub.unregister(id)
	for off := 0; off < len(raw); off += serveChunkSize {
		end := off + serveChunkSize
		if end > len(raw) {
			end = len(raw)
		}
		chunk, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFilePutChunk, ID: id},
			proto.FileChunkPayload{Seq: off / serveChunkSize,
				Data: base64.StdEncoding.EncodeToString(raw[off:end]), Done: end == len(raw)})
		if err := a.hub.sendRaw(chunk); err != nil {
			writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, "发送分片失败: "+err.Error())
			return
		}
	}
	for {
		select {
		case <-ctx.Done():
			a.hub.sendRaw(proto.Msg{Type: proto.TypeFileAbort, ID: id})
			writeErr(w, http.StatusGatewayTimeout, proto.ErrorCodeTimeout, "上传超时")
			return
		case <-dead:
			writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, "与中继的连接断开")
			return
		case m := <-ch:
			switch m.Type {
			case proto.TypeFilePutAck:
				var p proto.FilePutAckPayload
				m.PayloadOf(&p)
				if !p.OK {
					writeErr(w, http.StatusBadGateway, "", p.Error)
					return
				}
				writeJSON(w, http.StatusOK, map[string]any{"ok": true, "path": path, "size": len(raw)})
				return
			case proto.TypeError:
				var p proto.ErrorPayload
				m.PayloadOf(&p)
				writeErr(w, http.StatusBadGateway, p.Code, p.Error)
				return
			}
		}
	}
}

// handleDownload 下载文件，返回 base64 内容。
func (a *serveAPI) handleDownload(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID string `json:"device_id"`
		Path     string `json:"path"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadPayload, "请求体无效")
		return
	}
	if req.DeviceID == "" || req.Path == "" {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadPayload, "device_id 与 path 必填")
		return
	}
	tgt, ok := a.devices[req.DeviceID]
	if !ok {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadDevice, "未知设备: "+req.DeviceID)
		return
	}
	if tgt.url != "" {
		a.downloadDirect(w, r, tgt, req.Path)
		return
	}
	a.downloadRelay(w, r, tgt, req.Path)
}

// downloadDirect 直连下载：独立连接收集分片。
func (a *serveAPI) downloadDirect(w http.ResponseWriter, r *http.Request, tgt deviceTarget, path string) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()
	conn, err := dialDirect(ctx, tgt.url)
	if err != nil {
		writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, "连接设备失败: "+err.Error())
		return
	}
	defer conn.Close()

	id := idutil.New()
	get, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFileGet, ID: id, Token: tgt.token},
		proto.FileGetPayload{Path: path})
	if err := conn.WriteJSON(get); err != nil {
		writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, err.Error())
		return
	}
	var raw []byte
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, "接收分片失败: "+err.Error())
			return
		}
		var m proto.Msg
		if err := json.Unmarshal(data, &m); err != nil {
			continue
		}
		switch m.Type {
		case proto.TypeFileGetChunk:
			var p proto.FileGetChunkPayload
			m.PayloadOf(&p)
			if p.Data != "" {
				b, err := base64.StdEncoding.DecodeString(p.Data)
				if err != nil {
					writeErr(w, http.StatusBadGateway, proto.ErrorCodeInternal, "分片解码失败")
					return
				}
				raw = append(raw, b...)
				if len(raw) > 256<<20 {
					writeErr(w, http.StatusBadGateway, proto.ErrorCodeInternal, "文件过大（上限 256MB）")
					return
				}
			}
			if p.Done {
				if p.Error != "" {
					writeErr(w, http.StatusNotFound, p.ErrorCode, p.Error)
					return
				}
				writeJSON(w, http.StatusOK, map[string]any{
					"ok": true, "path": path, "size": len(raw),
					"data": base64.StdEncoding.EncodeToString(raw),
				})
				return
			}
		case proto.TypeError:
			var p proto.ErrorPayload
			m.PayloadOf(&p)
			writeErr(w, http.StatusBadGateway, p.Code, p.Error)
			return
		}
	}
}

// downloadRelay 中继下载（复用常驻连接）。
func (a *serveAPI) downloadRelay(w http.ResponseWriter, r *http.Request, tgt deviceTarget, path string) {
	id := idutil.New()
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()

	get, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFileGet, ID: id, Token: tgt.token},
		proto.FileGetPayload{Path: path})
	ch, dead, err := a.hub.request(ctx, get)
	if err != nil {
		writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, err.Error())
		return
	}
	defer a.hub.unregister(id)

	var raw []byte
	for {
		select {
		case <-ctx.Done():
			writeErr(w, http.StatusGatewayTimeout, proto.ErrorCodeTimeout, "下载超时")
			return
		case <-dead:
			writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, "与中继的连接断开")
			return
		case m := <-ch:
			switch m.Type {
			case proto.TypeFileGetChunk:
				var p proto.FileGetChunkPayload
				m.PayloadOf(&p)
				if p.Data != "" {
					b, err := base64.StdEncoding.DecodeString(p.Data)
					if err != nil {
						writeErr(w, http.StatusBadGateway, proto.ErrorCodeInternal, "分片解码失败")
						return
					}
					raw = append(raw, b...)
					if len(raw) > 256<<20 {
						writeErr(w, http.StatusBadGateway, proto.ErrorCodeInternal, "文件过大（上限 256MB）")
						return
					}
				}
				if p.Done {
					if p.Error != "" {
						writeErr(w, http.StatusNotFound, p.ErrorCode, p.Error)
						return
					}
					writeJSON(w, http.StatusOK, map[string]any{
						"ok": true, "path": path, "size": len(raw),
						"data": base64.StdEncoding.EncodeToString(raw),
					})
					return
				}
			case proto.TypeError:
				var p proto.ErrorPayload
				m.PayloadOf(&p)
				writeErr(w, http.StatusBadGateway, p.Code, p.Error)
				return
			}
		}
	}
}
