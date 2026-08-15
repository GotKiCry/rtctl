// serve.go —— rtctl-client serve：常驻 HTTP 服务。
// AI Agent / 自动化程序通过本服务操控目标设备，无需处理 token、无需手动传输文件。
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

// serveConfig 本地设备清单（device_id -> token），格式与 server 的 devices.json 相同。
type serveConfig struct {
	Devices []struct {
		ID    string `json:"id"`
		Token string `json:"token"`
	} `json:"devices"`
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
	devices map[string]string // device_id -> token
}

func cmdServe(args []string) error {
	sub := flag.NewFlagSet("serve", flag.ExitOnError)
	listen := sub.String("listen", "127.0.0.1:18080", "HTTP 监听地址（Agent 调用入口）")
	devicesFile := sub.String("devices", "devices.json", "设备清单（device_id -> token，与 server 同格式）")
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
	devices := make(map[string]string, len(cfg.Devices))
	for _, d := range cfg.Devices {
		if d.ID == "" || d.Token == "" {
			return errors.New("设备清单存在空 id 或空 token")
		}
		devices[d.ID] = d.Token
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

// handleDevices 设备列表（含在线状态与元数据）。
func (a *serveAPI) handleDevices(w http.ResponseWriter, r *http.Request) {
	a.hub.listMu.Lock()
	defer a.hub.listMu.Unlock()
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	// 清空历史 ack
	for {
		select {
		case <-a.hub.listCh:
		default:
			goto drained
		}
	}
drained:
	if err := a.hub.sendRaw(proto.Msg{Type: proto.TypeList}); err != nil {
		writeErr(w, http.StatusBadGateway, proto.ErrorCodeConnLost, err.Error())
		return
	}
	select {
	case m := <-a.hub.listCh:
		var p proto.ListAckPayload
		if err := m.PayloadOf(&p); err != nil {
			writeErr(w, http.StatusBadGateway, proto.ErrorCodeInternal, "解析设备列表失败")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"devices": p.Devices})
	case <-ctx.Done():
		writeErr(w, http.StatusGatewayTimeout, proto.ErrorCodeTimeout, "获取设备列表超时")
	}
}

// handleExec 执行命令并等待完成。
func (a *serveAPI) handleExec(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID  string `json:"device_id"`
		Cmd       string `json:"cmd"`
		TimeoutMS int    `json:"timeout_ms"`
		Workdir   string `json:"workdir"`
		Stdin     string `json:"stdin"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadPayload, "请求体无效")
		return
	}
	if req.DeviceID == "" || req.Cmd == "" {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadPayload, "device_id 与 cmd 必填")
		return
	}
	token, ok := a.devices[req.DeviceID]
	if !ok {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadDevice, "未知设备: "+req.DeviceID)
		return
	}
	id := idutil.New()
	overall := 1 * time.Hour
	if req.TimeoutMS > 0 {
		overall = time.Duration(req.TimeoutMS)*time.Millisecond + 30*time.Second
	}
	ctx, cancel := context.WithTimeout(r.Context(), overall)
	defer cancel()

	m := proto.Msg{Type: proto.TypeExec, ID: id, Token: token}
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
			kill, _ := proto.WithPayload(proto.Msg{Type: proto.TypeExecKill, Token: token},
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

// handleUpload 上传文件（请求体为 JSON，data 为 base64）。
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
	token, ok := a.devices[req.DeviceID]
	if !ok {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadDevice, "未知设备: "+req.DeviceID)
		return
	}
	id := idutil.New()
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()

	begin, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFilePut, ID: id, Token: token},
		proto.FilePutPayload{Path: req.Path, Mode: req.Mode, Size: int64(len(raw))})
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
				writeJSON(w, http.StatusOK, map[string]any{"ok": true, "path": req.Path, "size": len(raw)})
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
	token, ok := a.devices[req.DeviceID]
	if !ok {
		writeErr(w, http.StatusBadRequest, proto.ErrorCodeBadDevice, "未知设备: "+req.DeviceID)
		return
	}
	id := idutil.New()
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()

	get, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFileGet, ID: id, Token: token},
		proto.FileGetPayload{Path: req.Path})
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
						"ok": true, "path": req.Path, "size": len(raw),
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
