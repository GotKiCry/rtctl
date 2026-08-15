package server

import (
	"encoding/json"
	"errors"
	"log"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"rtctl/internal/proto"
)

const (
	sendQueueSize  = 256
	writeWait      = 10 * time.Second
	pongWait       = 90 * time.Second
	pingPeriod     = 25 * time.Second
	maxMessageSize = 4 << 20
)

// AgentConn 一台在线设备的连接。
type AgentConn struct {
	hub      *Hub
	ws       *websocket.Conn
	send     chan []byte
	deviceID string
	addr     string
	os       string // 以下为注册时上报的设备元数据
	arch     string
	hostname string
	version  string
	once     sync.Once // 保护 ws.Close
	quitOnce sync.Once // 保护 quit 关闭
	quit     chan struct{}
}

func newAgentConn(hub *Hub, ws *websocket.Conn, addr string) *AgentConn {
	return &AgentConn{hub: hub, ws: ws, send: make(chan []byte, sendQueueSize), addr: addr, quit: make(chan struct{})}
}

func (a *AgentConn) sendMsg(m proto.Msg) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	select {
	case a.send <- b:
		return nil
	default:
		return errors.New("发送队列已满")
	}
}

// sendMsgBlocking 阻塞发送关键帧（如注册拒绝原因），队列满时最多等待 timeout。
func (a *AgentConn) sendMsgBlocking(m proto.Msg, timeout time.Duration) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case a.send <- b:
		return nil
	case <-timer.C:
		return errors.New("发送超时")
	}
}

func (a *AgentConn) close() {
	a.once.Do(func() { a.ws.Close() })
}

// flushAndClose 先让 writePump 排空发送队列（关键帧务必送达）再关闭连接。
// 用于"先发送拒绝原因、再断开"的场景，避免消息被 close 竞态吞掉。
func (a *AgentConn) flushAndClose() {
	a.quitOnce.Do(func() { close(a.quit) })
}

func (a *AgentConn) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer ticker.Stop()
	for {
		select {
		case b := <-a.send:
			a.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := a.ws.WriteMessage(websocket.TextMessage, b); err != nil {
				a.close()
				return
			}
		case <-ticker.C:
			a.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := a.ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				a.close()
				return
			}
		case <-a.quit:
			// 排空队列中的消息后再关闭
			for {
				select {
				case b := <-a.send:
					a.ws.SetWriteDeadline(time.Now().Add(writeWait))
					if a.ws.WriteMessage(websocket.TextMessage, b) != nil {
						a.close()
						return
					}
				default:
					a.close()
					return
				}
			}
		}
	}
}

func (a *AgentConn) readPump() {
	defer func() {
		a.hub.unregisterAgent(a)
		a.close()
	}()
	a.ws.SetReadLimit(maxMessageSize)
	a.ws.SetReadDeadline(time.Now().Add(pongWait))
	a.ws.SetPongHandler(func(string) error {
		a.ws.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})
	for {
		_, data, err := a.ws.ReadMessage()
		if err != nil {
			return
		}
		var m proto.Msg
		if err := json.Unmarshal(data, &m); err != nil {
			log.Printf("[server] agent %s 消息解析失败: %v", a.deviceID, err)
			continue
		}
		a.hub.handleAgentMsg(a, m)
	}
}

// ClientConn 一个控制端连接。
type ClientConn struct {
	hub      *Hub
	ws       *websocket.Conn
	send     chan []byte
	addr     string
	clientID string // 操作者/Agent 标识（auth payload 上报，审计归因）
	authed   bool
	once     sync.Once // 保护 ws.Close
	quitOnce sync.Once // 保护 quit 关闭
	quit     chan struct{}
}

func newClientConn(hub *Hub, ws *websocket.Conn, addr string) *ClientConn {
	return &ClientConn{hub: hub, ws: ws, send: make(chan []byte, sendQueueSize), addr: addr, quit: make(chan struct{})}
}

func (c *ClientConn) sendMsg(m proto.Msg) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	select {
	case c.send <- b:
		return nil
	default:
		return errors.New("发送队列已满")
	}
}

// ccSendBlocking 阻塞发送（用于必须送达的关键帧，如 exec 的 done 帧）。
// 队列满时等待，超过 timeout 返回错误。
func ccSendBlocking(cc *ClientConn, m proto.Msg, timeout time.Duration) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case cc.send <- b:
		return nil
	case <-timer.C:
		return errors.New("发送超时")
	}
}

func (c *ClientConn) close() {
	c.once.Do(func() { c.ws.Close() })
}

// flushAndClose 先让 writePump 排空发送队列再关闭连接。
func (c *ClientConn) flushAndClose() {
	c.quitOnce.Do(func() { close(c.quit) })
}

func (c *ClientConn) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer ticker.Stop()
	for {
		select {
		case b := <-c.send:
			c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.ws.WriteMessage(websocket.TextMessage, b); err != nil {
				c.close()
				return
			}
		case <-ticker.C:
			c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				c.close()
				return
			}
		case <-c.quit:
			for {
				select {
				case b := <-c.send:
					c.ws.SetWriteDeadline(time.Now().Add(writeWait))
					if c.ws.WriteMessage(websocket.TextMessage, b) != nil {
						c.close()
						return
					}
				default:
					c.close()
					return
				}
			}
		}
	}
}

func (c *ClientConn) readPump() {
	defer func() {
		c.hub.unregisterClient(c)
		c.close()
	}()
	c.ws.SetReadLimit(maxMessageSize)
	c.ws.SetReadDeadline(time.Now().Add(pongWait))
	c.ws.SetPongHandler(func(string) error {
		c.ws.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})
	for {
		_, data, err := c.ws.ReadMessage()
		if err != nil {
			return
		}
		var m proto.Msg
		if err := json.Unmarshal(data, &m); err != nil {
			log.Printf("[server] client %s 消息解析失败: %v", c.addr, err)
			continue
		}
		c.hub.handleClientMsg(c, m)
	}
}
