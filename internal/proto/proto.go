// Package proto 定义 rtctl 的 WebSocket JSON 消息协议。
package proto

import "encoding/json"

// 消息类型常量。
const (
	TypeRegister     = "register"       // agent -> server 设备注册
	TypeRegisterAck  = "register_ack"   // server -> agent 注册结果
	TypeAuth         = "auth"           // client -> server 客户端认证
	TypeAuthAck      = "auth_ack"       // server -> client 认证结果
	TypeList         = "list"           // client -> server 查询在线设备
	TypeListAck      = "list_ack"       // server -> client 设备列表
	TypeExec         = "exec"           // client -> agent 一次性执行命令
	TypeExecOutput   = "exec_output"    // agent -> client 执行输出分片
	TypeExecKill     = "exec_kill"      // client -> agent 取消执行
	TypeShellOpen    = "shell_open"     // client -> agent 打开交互终端
	TypeShellAck     = "shell_ack"      // agent -> client 终端打开结果
	TypeShellData    = "shell_data"     // 双向 终端字节流
	TypeShellResize  = "shell_resize"   // client -> agent 调整窗口大小
	TypeShellClose   = "shell_close"    // 双向 关闭终端
	TypeFilePut      = "file_put"       // client -> agent 开始上传（Msg.ID 为传输 ID）
	TypeFilePutChunk = "file_put_chunk" // client -> agent 上传分片（最后一个分片 done=true）
	TypeFilePutAck   = "file_put_ack"   // agent -> client 上传完成回执
	TypeFileGet      = "file_get"       // client -> agent 请求下载
	TypeFileGetChunk = "file_get_chunk" // agent -> client 下载分片（最后一个分片 done=true）
	TypeFileAbort    = "file_abort"     // client/server -> agent 取消传输
	TypeError        = "error"          // 通用错误
)

// Msg 是所有消息的统一外壳。
type Msg struct {
	Type      string          `json:"type"`
	ID        string          `json:"id,omitempty"`        // 消息唯一ID（exec 关联用）
	DeviceID  string          `json:"device_id,omitempty"` // 设备ID（register 用）
	Token     string          `json:"token,omitempty"`     // 设备 token（定位目标设备）
	SessionID string          `json:"session_id,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
}

// PayloadOf 把 payload 反序列化到 v。
func (m *Msg) PayloadOf(v any) error {
	if len(m.Payload) == 0 {
		return nil
	}
	return json.Unmarshal(m.Payload, v)
}

// WithPayload 把 v 序列化为 payload 并挂到消息上。
func WithPayload(m Msg, v any) (Msg, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return m, err
	}
	m.Payload = b
	return m, nil
}

// ---- 各消息 payload ----

// RegisterPayload 设备注册。
type RegisterPayload struct {
	ID       string `json:"id"`
	Token    string `json:"token"`
	OS       string `json:"os,omitempty"`       // runtime.GOOS
	Arch     string `json:"arch,omitempty"`     // runtime.GOARCH
	Hostname string `json:"hostname,omitempty"` // 设备主机名
	Version  string `json:"version,omitempty"`  // agent 版本
}

// RegisterAckPayload 注册结果。
type RegisterAckPayload struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// AuthPayload 客户端认证。
type AuthPayload struct {
	Key string `json:"key"`
	ID  string `json:"id,omitempty"` // 操作者/Agent 标识（审计归因用）
}

// AuthAckPayload 认证结果。
type AuthAckPayload struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// DeviceInfo 设备信息。
type DeviceInfo struct {
	ID       string `json:"id"`
	Online   bool   `json:"online"`
	OS       string `json:"os,omitempty"`
	Arch     string `json:"arch,omitempty"`
	Hostname string `json:"hostname,omitempty"`
	Version  string `json:"version,omitempty"`
}

// ListAckPayload 设备列表。
type ListAckPayload struct {
	Devices []DeviceInfo `json:"devices"`
}

// ExecPayload 一次性执行。
type ExecPayload struct {
	Cmd       string `json:"cmd"`
	TimeoutMS int    `json:"timeout_ms,omitempty"` // 0 表示不限制
	Workdir   string `json:"workdir,omitempty"`
	Stdin     string `json:"stdin,omitempty"` // 写入进程 stdin 后关闭（非交互输入）
}

// ExecOutputPayload 执行输出分片；最后一帧 Done=true 携带退出码。
type ExecOutputPayload struct {
	Seq       int    `json:"seq"`
	Data      string `json:"data"`
	Done      bool   `json:"done"`
	ExitCode  int    `json:"exit_code,omitempty"`
	Error     string `json:"error,omitempty"`
	ErrorCode string `json:"error_code,omitempty"` // 机器可读错误码（见 ErrorCode* 常量）
	Truncated bool   `json:"truncated,omitempty"`  // 输出因背压被丢弃过（不可靠完整性）
}

// ExecKillPayload 取消执行。
type ExecKillPayload struct {
	ExecID string `json:"exec_id"`
}

// ShellAckPayload 终端打开结果。
type ShellAckPayload struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// ShellDataPayload 终端字节流。
type ShellDataPayload struct {
	Data string `json:"data"`
}

// ShellResizePayload 窗口大小。
type ShellResizePayload struct {
	Cols uint16 `json:"cols"`
	Rows uint16 `json:"rows"`
}

// ErrorPayload 通用错误。
type ErrorPayload struct {
	Error string `json:"error"`
	Code  string `json:"code,omitempty"` // 机器可读错误码（见 ErrorCode* 常量）
}

// FilePutPayload 开始上传：路径 + 目标权限 + 总大小（用于上限校验）。
type FilePutPayload struct {
	Path string `json:"path"`
	Mode uint32 `json:"mode,omitempty"` // 文件权限（Linux 生效；0 表示默认 0644）
	Size int64  `json:"size"`
}

// FileChunkPayload 文件分片：Data 为 base64 编码的原始字节。
type FileChunkPayload struct {
	Seq  int    `json:"seq"`
	Data string `json:"data"`
	Done bool   `json:"done"`
}

// FilePutAckPayload 上传回执。
type FilePutAckPayload struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// FileGetPayload 请求下载。
type FileGetPayload struct {
	Path string `json:"path"`
}

// FileGetChunkPayload 下载分片；失败时 Done=true 且 Error 非空。
type FileGetChunkPayload struct {
	Seq       int    `json:"seq"`
	Data      string `json:"data"`
	Done      bool   `json:"done"`
	Error     string `json:"error,omitempty"`
	ErrorCode string `json:"error_code,omitempty"`
}

// 机器可读错误码：Agent/自动化客户端可据此决策（重试 / 报错 / 改配置）。
const (
	ErrorCodeBadToken     = "bad_token"       // token 不存在（配置错误，重试无用）
	ErrorCodeOffline      = "device_offline"  // 设备离线（可等待重试）
	ErrorCodeAuthRequired = "auth_required"   // 未认证，先发 auth
	ErrorCodeBadPayload   = "bad_payload"     // 消息 payload 无效
	ErrorCodeTimeout      = "timeout"         // 执行超时
	ErrorCodeKilled       = "killed"          // 执行被取消/中断
	ErrorCodeAgentLost    = "agent_lost"      // 执行中 agent 掉线
	ErrorCodeStartFailed  = "start_failed"    // 进程启动失败
	ErrorCodeOverload     = "overload"        // 并发超限
	ErrorCodeConflict     = "conflict"        // ID 冲突
	ErrorCodeNotFound     = "not_found"       // 文件不存在
	ErrorCodeBadDevice    = "bad_device"      // 未知设备 ID（clientd 配置中不存在）
	ErrorCodeConnLost     = "connection_lost" // 服务与中继的连接断开
	ErrorCodeInternal     = "internal"        // 内部错误
)
