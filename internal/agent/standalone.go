// standalone.go —— agent 直连模式：agent 自带 WS 服务端，
// 本机 client 直接连接目标机，无需中继 server。
package agent

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"rtctl/internal/proto"
)

// standaloneConn 直连模式下的一条客户端连接（实现 sendSink）。
type standaloneConn struct {
	ws   *websocket.Conn
	send chan []byte
	addr string

	mu     sync.Mutex
	execs  map[string]struct{} // 本连接发起的 exec ID
	shells map[string]struct{} // 本连接打开的 shell 会话
	puts   map[string]struct{} // 本连接发起的上传
}

func newStandaloneConn(ws *websocket.Conn, addr string) *standaloneConn {
	return &standaloneConn{
		ws: ws, send: make(chan []byte, 256), addr: addr,
		execs: make(map[string]struct{}), shells: make(map[string]struct{}), puts: make(map[string]struct{}),
	}
}

func (c *standaloneConn) Send(m proto.Msg) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	select {
	case c.send <- b:
		return nil
	default:
		return errSendQueueFull
	}
}

func (c *standaloneConn) SendBlocking(m proto.Msg, timeout time.Duration) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case c.send <- b:
		return nil
	case <-timer.C:
		return errSendQueueFull
	}
}

func (c *standaloneConn) CloseConn() { c.ws.Close() }

// Standalone agent 直连模式的 WS 服务端。
type Standalone struct {
	agent *Agent
}

// ServeStandalone 启动直连监听（阻塞直到 ctx 取消或服务出错）。
func (a *Agent) ServeStandalone(ctx context.Context, listen, tlsCert, tlsKey string) error {
	s := &Standalone{agent: a}
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", s.handleWS)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	srv := &http.Server{Addr: listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second}
	go func() {
		<-ctx.Done()
		srv.Close()
	}()
	log.Printf("[agent] 直连模式监听 %s（无需中继；连接需持有设备 token）", listen)
	if tlsCert != "" {
		return srv.ListenAndServeTLS(tlsCert, tlsKey)
	}
	return srv.ListenAndServe()
}

func originOK(r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" {
		return true // 非浏览器客户端通常不带 Origin
	}
	u, err := url.Parse(o)
	if err != nil {
		return false
	}
	return strings.EqualFold(u.Host, r.Host)
}

func (s *Standalone) handleWS(w http.ResponseWriter, r *http.Request) {
	up := websocket.Upgrader{
		ReadBufferSize:  4096,
		WriteBufferSize: 4096,
		CheckOrigin:     originOK,
	}
	ws, err := up.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	cc := newStandaloneConn(ws, r.RemoteAddr)
	go writePump(ws, cc.send)
	go s.serveConn(cc)
}

// serveConn 一条直连客户端的消息循环：auth -> 指令分发。
// 连接断开时清理该连接拥有的 exec / shell / 上传，不留孤儿。
func (s *Standalone) serveConn(cc *standaloneConn) {
	a := s.agent
	defer func() {
		a.cleanupStandaloneConn(cc)
		cc.ws.Close()
	}()
	cc.ws.SetReadLimit(4 << 20)
	cc.ws.SetReadDeadline(time.Now().Add(90 * time.Second))
	cc.ws.SetPongHandler(func(string) error {
		cc.ws.SetReadDeadline(time.Now().Add(90 * time.Second))
		return nil
	})
	authed := false
	for {
		_, data, err := cc.ws.ReadMessage()
		if err != nil {
			return
		}
		var m proto.Msg
		if err := json.Unmarshal(data, &m); err != nil {
			continue
		}
		if !authed {
			if m.Type != proto.TypeAuth {
				em, _ := proto.WithPayload(proto.Msg{Type: proto.TypeError, ID: m.ID},
					proto.ErrorPayload{Error: "请先发送 auth 认证", Code: proto.ErrorCodeAuthRequired})
				cc.Send(em)
				continue
			}
			ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeAuthAck}, proto.AuthAckPayload{OK: true})
			cc.Send(ack)
			authed = true
			log.Printf("[agent] 直连 client 接入: %s", cc.addr)
			continue
		}
		switch m.Type {
		case proto.TypeAuth:
			ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeAuthAck}, proto.AuthAckPayload{OK: true})
			cc.Send(ack)
		case proto.TypeList:
			hostname, _ := os.Hostname()
			ack, _ := proto.WithPayload(proto.Msg{Type: proto.TypeListAck},
				proto.ListAckPayload{Devices: []proto.DeviceInfo{{
					ID: a.ID, Online: true, OS: runtime.GOOS, Arch: runtime.GOARCH,
					Hostname: hostname, Version: Version,
				}}})
			cc.Send(ack)
		case proto.TypeExec:
			if !s.checkToken(cc, m) {
				continue
			}
			cc.mu.Lock()
			cc.execs[m.ID] = struct{}{}
			cc.mu.Unlock()
			go func() {
				defer func() {
					cc.mu.Lock()
					delete(cc.execs, m.ID)
					cc.mu.Unlock()
				}()
				a.handleExec(m, cc)
			}()
		case proto.TypeExecKill:
			if !s.checkToken(cc, m) {
				continue
			}
			a.handleExecKill(m)
		case proto.TypeShellOpen:
			if !s.checkToken(cc, m) {
				continue
			}
			cc.mu.Lock()
			cc.shells[m.SessionID] = struct{}{}
			cc.mu.Unlock()
			a.handleShellOpen(m, cc)
		case proto.TypeShellData, proto.TypeShellResize, proto.TypeShellClose:
			// 会话绑定消息不带 token（由 shell_open 校验并建立会话）
			a.handleShellCtrl(m)
		case proto.TypeFilePut:
			if !s.checkToken(cc, m) {
				continue
			}
			cc.mu.Lock()
			cc.puts[m.ID] = struct{}{}
			cc.mu.Unlock()
			a.handleFilePut(m, cc)
		case proto.TypeFilePutChunk:
			// 数据段消息不带 token（由 file_put 校验并建立传输）
			a.handleFilePutChunk(m)
		case proto.TypeFileGet:
			if !s.checkToken(cc, m) {
				continue
			}
			go a.handleFileGet(m, cc)
		case proto.TypeFileAbort:
			if !s.checkToken(cc, m) {
				continue
			}
			a.handleFileAbort(m)
		default:
			em, _ := proto.WithPayload(proto.Msg{Type: proto.TypeError, ID: m.ID},
				proto.ErrorPayload{Error: "未知消息类型: " + m.Type, Code: proto.ErrorCodeBadPayload})
			cc.Send(em)
		}
	}
}

// checkToken 直连模式的设备令牌校验（token 即设备钥匙）。
func (s *Standalone) checkToken(cc *standaloneConn, m proto.Msg) bool {
	if m.Token == s.agent.Token {
		return true
	}
	em, _ := proto.WithPayload(proto.Msg{Type: proto.TypeError, ID: m.ID},
		proto.ErrorPayload{Error: "token 无效", Code: proto.ErrorCodeBadToken})
	cc.Send(em)
	return false
}

// cleanupStandaloneConn 连接断开：取消其 exec、关闭其 shell、清理其上传临时文件。
func (a *Agent) cleanupStandaloneConn(cc *standaloneConn) {
	cc.mu.Lock()
	execIDs := make([]string, 0, len(cc.execs))
	for id := range cc.execs {
		execIDs = append(execIDs, id)
	}
	shellIDs := make([]string, 0, len(cc.shells))
	for id := range cc.shells {
		shellIDs = append(shellIDs, id)
	}
	putIDs := make([]string, 0, len(cc.puts))
	for id := range cc.puts {
		putIDs = append(putIDs, id)
	}
	cc.mu.Unlock()

	a.mu.Lock()
	for _, id := range execIDs {
		if cancel, ok := a.execs[id]; ok {
			cancel()
		}
	}
	for _, id := range shellIDs {
		if sh, ok := a.shells[id]; ok {
			delete(a.shells, id)
			sh.sess.Close()
		}
	}
	for _, id := range putIDs {
		if st, ok := a.putFiles[id]; ok {
			delete(a.putFiles, id)
			if st.file != nil {
				st.file.Close()
			}
			os.Remove(st.tmpPath)
		}
	}
	a.mu.Unlock()
	if len(execIDs)+len(shellIDs)+len(putIDs) > 0 {
		log.Printf("[agent] 直连 client %s 断开：清理 exec=%d shell=%d 上传=%d",
			cc.addr, len(execIDs), len(shellIDs), len(putIDs))
	}
}
