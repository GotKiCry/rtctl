package server

import (
	"net/http"
	"net/url"
	"strings"

	"github.com/gorilla/websocket"
)

// Server WebSocket 入口。
type Server struct {
	Hub *Hub
	// AllowAnyOrigin 放行任意 Origin（便于 Web 端接入）。
	// 默认关闭：只允许无 Origin（非浏览器客户端）或与 Host 同源，防跨站 WebSocket 劫持。
	AllowAnyOrigin bool
}

// originAllowed 判断 WebSocket 升级请求的 Origin 是否可接受。
func originAllowed(r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" {
		return true // 非浏览器客户端（Go/CLI）通常不带 Origin
	}
	u, err := url.Parse(o)
	if err != nil {
		return false
	}
	return strings.EqualFold(u.Host, r.Host)
}

// HandleWS 处理 /ws 连接，按 role 参数分流。
func (s *Server) HandleWS(w http.ResponseWriter, r *http.Request) {
	upgrader := websocket.Upgrader{
		ReadBufferSize:  4096,
		WriteBufferSize: 4096,
		CheckOrigin:     func(r *http.Request) bool { return s.AllowAnyOrigin || originAllowed(r) },
	}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	switch r.URL.Query().Get("role") {
	case "agent":
		ac := newAgentConn(s.Hub, conn, r.RemoteAddr)
		go ac.writePump()
		go ac.readPump()
	case "client":
		cc := newClientConn(s.Hub, conn, r.RemoteAddr)
		go cc.writePump()
		go cc.readPump()
	default:
		conn.WriteMessage(websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "role 必须为 agent 或 client"))
		conn.Close()
	}
}
