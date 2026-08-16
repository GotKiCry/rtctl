// serve.go —— rtctl-client serve：常驻 HTTP 服务。
// AI Agent / 自动化程序通过本服务直控目标设备，无需处理 token、无需手动传输文件。
//
// 设备清单格式（每条设备必须带 url 直连地址）:
//
//	{ "devices": [ { "id": "jp-tokyo-01", "url": "wss://1.2.3.4:8443/ws", "token": "..." } ] }
//
// API（Authorization: Bearer <api-key>）:
//
//	GET  /healthz                     健康检查（免认证）
//	GET  /api/v1/devices              设备列表（逐个探活）
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
	"time"

	"github.com/gorilla/websocket"

	"rtctl/internal/idutil"
	"rtctl/internal/proto"
)

const serveChunkSize = 256 * 1024

// serveConfig 本地设备清单（device_id -> token + 直连 url）。
type serveConfig struct {
	Devices []struct {
		ID    string `json:"id"`
		Token string `json:"token"`
		URL   string `json:"url"` // 直连地址（ws://或wss://），必填
	} `json:"devices"`
}

// deviceTarget 一个设备的接入信息。
type deviceTarget struct {
	id    string
	token string
	url   string
}

// ---- HTTP 层 ----

type serveAPI struct {
	apiKey    string
	allowSudo bool // 用户批准闸：true 才转发 sudo:true 特权命令
	devices   map[string]deviceTarget
}

func cmdServe(args []string) error {
	sub := flag.NewFlagSet("serve", flag.ExitOnError)
	listen := sub.String("listen", "127.0.0.1:18080", "HTTP 监听地址（Agent 调用入口）")
	devicesFile := sub.String("devices", "devices.json", "设备清单（device_id -> token + url 直连地址）")
	apiKey := sub.String("api-key", "", "API 密钥（留空自动生成并打印一次）")
	allowSudo := sub.Bool("allow-sudo", false, "允许转发特权命令（sudo:true）；未开启时特权请求回 approval_required，需用户批准后开启")
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
		if d.ID == "" || d.Token == "" || d.URL == "" {
			return fmt.Errorf("设备 %q 缺少 id/token/url（url 为直连地址，必填）", d.ID)
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
	api := &serveAPI{apiKey: *apiKey, allowSudo: *allowSudo, devices: devices}

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
	log.Printf("[clientd] HTTP 服务启动: http://%s  (Authorization: Bearer %s) allow-sudo=%v", *listen, *apiKey, *allowSudo)
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

// probeDirect 设备探活：返回设备信息（失败返回 offline）。
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

// handleDevices 设备列表：逐个探活。
func (a *serveAPI) handleDevices(w http.ResponseWriter, r *http.Request) {
	out := make([]proto.DeviceInfo, 0, len(a.devices))
	for _, t := range a.devices {
		probeCtx, cancel := context.WithTimeout(r.Context(), 6*time.Second)
		out = append(out, probeDirect(probeCtx, t))
		cancel()
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
	Sudo      bool   `json:"sudo"` // true = 特权命令（需 clientd 开启 -allow-sudo 才转发）
}

// handleExec 执行命令并等待完成（直连）。
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
	// 特权命令审批闸：未获用户批准（clientd 未开 -allow-sudo）→ 403，绝不降级静默执行
	if req.Sudo && !a.allowSudo {
		writeErr(w, http.StatusForbidden, proto.ErrorCodeApprovalRequired,
			"特权命令未获用户批准：clientd 未开启 -allow-sudo（AI Agent 需先征得用户同意，由用户在控制机以 -allow-sudo 开启）")
		return
	}
	if req.Sudo {
		log.Printf("[clientd] 特权命令(SUDO) device=%s cmd=%s", req.DeviceID, req.Cmd)
	}
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
	m, _ = proto.WithPayload(m, proto.ExecPayload{Cmd: req.Cmd, TimeoutMS: req.TimeoutMS, Workdir: req.Workdir, Stdin: req.Stdin, Sudo: req.Sudo})
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
		proto.FilePutPayload{Path: req.Path, Mode: req.Mode, Size: int64(len(raw))})
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
		proto.FileGetPayload{Path: req.Path})
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
