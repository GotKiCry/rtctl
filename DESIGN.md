# rtctl — 远程终端控制系统设计文档

## 1. 目标

一个基于 Go 的远程设备终端控制系统，由三部分组成：

- **server（控制服务器）**：居中转发，管理设备在线状态，路由指令。
- **agent（被控端）**：部署在目标 Linux / Windows 设备上，主动连接服务器，接收指令并执行。
- **client（控制端 CLI）**：操作者使用的命令行工具，连接服务器后向目标设备发指令。

支持两种控制模式：
1. **exec 一次性执行**：发一条 shell 命令，等待执行完，拿回 stdout / stderr / 退出码。
2. **shell 实时交互终端**：像 SSH 一样打开目标设备的交互式终端，实时双向收发。

## 2. 架构

```
+-------------+   HTTP    +----------+   wss://   +----------+   wss://   +--------------+
|  AI Agent   | --------> | clientd  | ---------> |  server  | <--------- |    agent     |
| (任何程序)  |  JSON API | (client   |  JSON消息  | (中继/路由)|  JSON消息  |  (目标设备)   |
+-------------+           |  serve)  |            +----------+            +--------------+
                          +----------+
                              |  CLI 子命令: list / exec / shell / file-put / file-get
```

- **clientd**（`client serve`）是操作机上的常驻 HTTP 服务：Agent 通过 REST API 直控设备，token 只存在于 clientd 本地设备清单，Agent 不接触凭据、不手动传输文件。
- **agent 主动拨出**连接服务器（而非服务器连目标机），因此目标机可以位于 NAT / 防火墙之后，无需公网 IP。
- server 与 agent 之间、server 与 client 之间均为 WebSocket 长连接，双向 JSON 消息。
- 服务器**不存储指令内容语义**，只做路由与审计，是纯转发层。

## 3. 认证模型（token）

按需求：**每台设备一个 token，任何持有该 token 的客户端都可以向该设备发指令。**

- 服务器启动时通过配置文件加载设备清单：`devices: [{id, token}]`；id 与 token 均不得重复、不得为空，否则拒绝启动；`change-me-` 前缀的占位 token 会告警。
- agent 连接后发送 `register` 消息，携带 `id + token + 设备元数据（OS/架构/主机名/版本）`；服务器校验通过才把设备标记为在线，`list` 会展示这些元数据。
- **注册被拒（token 错误）时，agent 立即退出，不无限重连**（普通断线仍指数退避重连）。
- client 发送 `exec / shell_open` 指令时携带目标设备的 `token`；服务器用 token 定位到对应设备并转发。错误区分：token 不存在返回 `bad_token`（配置错误），设备离线返回 `device_offline`（可重试）。
- 可选：服务器可配置 `client_key`，要求 client 连接时也出示密钥，防止陌生人连上服务器。
- 可选：client 上报 `client_id`（操作者/Agent 标识），写入审计日志用于归因。
- 传输层建议使用 WSS（TLS），配置 `tls_cert / tls_key` 后自动开启；两者必须同时提供。

## 4. 消息协议（JSON over WebSocket）

所有消息为 UTF-8 JSON，统一外壳：

```json
{
  "type": "exec",
  "id": "消息唯一ID（UUID）",
  "device_id": "目标设备ID",
  "token": "目标设备token",
  "session_id": "会话ID（shell模式用）",
  "payload": { "...": "类型相关字段" }
}
```

### 4.1 设备注册（agent -> server）

| type | payload | 说明 |
|---|---|---|
| register | {id, token, os?, arch?, hostname?, version?} | agent 上线注册，服务器校验 token 并记录元数据 |
| register_ack | {ok, error?} | 注册结果；失败时服务器先送达错误再断开 |

### 4.2 设备发现（client -> server）

| type | payload | 说明 |
|---|---|---|
| list | {} | 查询设备（含元数据） |
| list_ack | {devices: [{id, online, os?, arch?, hostname?, version?}]} | 返回设备列表 |

### 4.3 一次性执行（exec）

| type | 方向 | payload | 说明 |
|---|---|---|---|
| exec | client -> agent | {cmd, timeout_ms?, workdir?, stdin?} | 发起执行；stdin 为写入进程 stdin 后关闭的数据 |
| exec_output | agent -> client | {seq, data, done, exit_code?, error?, error_code?, truncated?} | 输出分片回传，最后一片 done=true 携带退出码；truncated=true 表示输出因背压被丢弃过 |
| exec_kill | client -> agent | {exec_id} | 取消执行 |

执行语义：Linux 上经 `/bin/sh -c`，Windows 上经 `cmd /C`（使用精确命令行构造，嵌套引号不会被剥掉）。
输出按 32KB 分片。超时/取消会终止**整个进程树**（Linux 进程组、Windows `taskkill /T`）。

### 4.4 交互式终端（shell）

| type | 方向 | payload | 说明 |
|---|---|---|---|
| shell_open | client -> agent | {} | 打开交互终端（Linux: 真 PTY；Windows: cmd 管道模式） |
| shell_ack | agent -> client | {ok, error?} | 打开结果 |
| shell_data | 双向 | {data} | 终端字节流：client->agent 为 stdin，agent->client 为 stdout+stderr |
| shell_resize | client -> agent | {cols, rows} | 调整 PTY 窗口大小（client 在打开时与 SIGWINCH 时自动发送） |
| shell_close | 任意一方 | {} | 关闭终端会话 |

### 4.5 通用

| type | 说明 |
|---|---|
| auth / auth_ack | 客户端认证（{key, id?}），client_id 用于审计归因 |
| error | {error, code?} 任何错误；code 为机器可读错误码（见 11.2） |
| ping / pong | 心跳（配合 WebSocket ping/pong 保活） |

### 4.6 文件传输（分片，Msg.ID 为传输 ID）

| type | 方向 | payload | 说明 |
|---|---|---|---|
| file_put | client -> agent | {path, mode?, size} | 开始上传；agent 建临时文件 `<path>.rtctl-partial` |
| file_put_chunk | client -> agent | {seq, data(base64), done} | 256KB 分片；最后一片 done=true 时落盘 chmod + 原子改名 |
| file_put_ack | agent -> client | {ok, error?} | 上传回执（成功/失败均终结传输） |
| file_get | client -> agent | {path} | 请求下载 |
| file_get_chunk | agent -> client | {seq, data(base64), done, error?, error_code?} | 下载分片；失败 done=true 带错误码（not_found 等） |
| file_abort | server -> agent | — | client 断开时由 server 代发，agent 清理临时文件 |

- 传输绑定与 exec 相同：`(ID -> {client, agent})` 双向校验，ID 冲突拒绝；agent 掉线即通知发起方，client 断开即 abort。
- 文件数据不可静默丢弃：分片走阻塞发送（10s），失败断连（慢消费者保护）。
- 上限：单文件 256MB（agent）、128MB（clientd 上传）；并发 put 8 / get 8（单设备）。
- Windows 覆盖同名文件先移除目标（os.Rename 语义差异）。

## 5. 服务器内部结构

```
server
 ├── hub          设备注册表 + client 会话表（map + 互斥锁）
 ├── agentConn    agent 连接封装（发送队列、设备信息）
 ├── clientConn   client 连接封装（发送队列）
 ├── router       消息分发：register / list / exec / shell 路由
 └── audit        审计日志：时间 / 操作者 / 设备 / 指令（写入日志文件）
```

路由规则：
- 按 `token` 定位目标设备（token -> device_id -> agentConn）。
- exec：client 发起的指令，由服务器转发给 agent；agent 的 exec_output 按消息 id 路由回原 client。**在途 exec 以 (id -> {client, agent}) 绑定**：输出帧必须同时匹配发起 client 与目标 agent 才转发，ID 冲突会被拒绝（`conflict`），防止跨客户端串线。
- 文件传输：file_put / file_get 同样按 (id -> {client, agent}) 绑定（putPend / getPend），分片与回执双向校验归属。
- agent 掉线时，其所有在途 exec 立即向发起 client 回 `agent_lost` 错误；client 断开时，其在途 exec 会向 agent 转发 exec_kill、在途上传转发 file_abort（不产生孤儿进程/残留临时文件）。
- shell：shell_open 时建立 session_id，服务器记录 `session_id -> clientConn + agentConn` 双向绑定，后续 shell_data / shell_resize / shell_close 按 session_id 转发。
- 背压：发送队列满时普通帧丢弃，并在该 exec 的 done 帧上标注 `truncated=true`；done 帧与文件分片阻塞送达（5s/10s），送达失败即关闭连接（客户端会得到错误而非永久挂起）。
- 慢消费者保护：客户端持续无法跟上输出时，服务器写超时（10s）会断开该客户端，其 exec 被同步取消。

## 5.5 clientd（client serve）

操作机上的常驻 HTTP 服务（与 server 之间是普通 client 连接，含 auth 与断线重连）：

- **凭据隔离**：本地设备清单（`{devices:[{id,token}]}`，与 server 同格式）提供 device_id -> token 映射；Agent 只使用 device_id，永远不接触 token。
- **API**：`GET /api/v1/devices`、`POST /api/v1/exec`、`POST /api/v1/files/upload|download`，Bearer API 密钥认证（不传自动生成）。
- **多路复用**：单条 WS 连接上按消息 ID 并发分发多个请求；list_ack 无 ID，串行化处理。
- **生命周期**：请求超时/断开即向 agent 发 exec_kill / file_abort；中继断线给在途请求回 `connection_lost`，指数退避重连后自动恢复。

## 6. Agent 实现要点

- 平台差异封装在 `internal/agent/shell_linux.go`（build tag linux）与 `shell_windows.go`（build tag windows）：
  - **Linux**：`github.com/creack/pty` 创建真 PTY，`sh` 作为登录壳，支持窗口 resize，行为与 SSH 一致（vim / top 等全屏程序可用）。
  - **Windows**：`cmd.exe` 管道模式（stdin/stdout 管道）。说明：非真 PTY，交互式全屏程序（如 vim 在 Windows 上）体验受限，普通命令完全可用。
- **超时/取消终止整个进程树**：Linux 用 `Setpgid` + 杀进程组；Windows 用 `taskkill /T /F`（`TerminateProcess` 只杀直接子进程，孙进程会存活并持有管道）。
- **Windows 命令构造**：`exec` 经 `SysProcAttr.CmdLine` 精确控制命令行，嵌套双引号不会被 cmd.exe 剥掉（默认 argv 引用方式会静默错误执行）。
- **输出转码**：Windows 上对输出做启发式转码（已是 UTF-8 原样保留，否则按 GBK/CP936 解码），中文输出不再乱码。
- **文件传输**：上传先写临时文件 `<path>.rtctl-partial`，done 分片时 chmod + 原子改名（Windows 先移除同名目标）；下载 256KB 分片流式回传，文件分片阻塞发送保证完整；断线/abort 自动清理临时文件。
- 并发上限：单设备最多 32 个并发 exec、8 个并发 shell、8 并发上传/下载，超限直接回 `overload` 错误。
- 单文件上限 256MB（上传与下载同）。
- 断线自动重连：指数退避，最多 30s 间隔；**注册被拒（token 错误）立即退出**。
- 心跳保活：30s 应用层 ping，60s 超时判定断线。
- 重连生命周期：每轮连接的 ws 与发送队列为该轮局部资源（互斥锁保护交换），旧连接的写循环不会串到新连接。

## 7. 配置

所有组件支持命令行参数 + 环境变量，无配置文件也行：

| 组件 | 参数 | 默认 | 说明 |
|---|---|---|---|
| server | -listen | :8080 | 监听地址 |
| server | -devices | devices.json | 设备清单文件（校验：无空项、无重复 id/token） |
| server | -client-key | 空 | 客户端连接密钥（可选） |
| server | -tls-cert / -tls-key | 空 | 开启 WSS（必须同时提供） |
| server | -allow-any-origin | false | 放行任意 Origin；默认仅允许无 Origin 或同源 |
| server | -audit | audit.log | 审计日志（0600 权限） |
| agent | -server | ws://host:8080 | 服务器地址 |
| agent | -id / -token | — | 设备身份（或环境变量 RTCTL_ID / RTCTL_TOKEN） |
| client | -server | ws://host:8080 | 服务器地址 |
| client | -key | 空 | 客户端密钥（与 server 对应） |
| client | -client-id | 空 | 操作者/Agent 标识（审计归因） |
| client | -json | false | 结构化输出（list / exec） |
| client exec | -timeout | 0 | 超时毫秒（0=不限；agent 侧终止整个进程树） |
| client exec | -deadline | 0 | 客户端总等待秒数（0=不限；默认 timeout+10s 宽限） |
| client exec | -workdir | 空 | 工作目录 |
| client exec | -stdin-file | 空 | 写入命令 stdin 的文件内容 |
| client exec | -c | 空 | 原样命令字符串（不再拼接参数） |
| client serve | -listen | 127.0.0.1:18080 | HTTP 监听地址（Agent 调用入口） |
| client serve | -devices | devices.json | 本地设备清单（device_id -> token） |
| client serve | -api-key | 空 | API 密钥（留空自动生成并打印） |
| client file-put | -mode | 0644 | 上传文件权限（Linux 生效） |

## 8. 目录结构

```
rtctl/
├── go.mod
├── deploy.sh / deploy.ps1   # 一键部署（唯一入口）
├── cmd/
│   ├── server/main.go      # 服务器入口
│   ├── agent/main.go       # 被控端入口
│   └── client/             # 控制端 CLI + clientd HTTP 服务
│       ├── main.go         # 入口/分发 + list/exec/shell
│       ├── file.go         # file-put / file-get 子命令
│       ├── serve.go        # clientd 常驻 HTTP 服务（Agent 入口）
│       └── winch_*.go      # 终端尺寸（SIGWINCH）
└── internal/
    ├── proto/proto.go      # 消息协议定义与编解码
    ├── server/             # 服务器：hub / conn / router / audit
    └── agent/              # agent：连接管理 + 执行器（linux/windows 分平台）
```

## 9. 使用示例

```bash
# 1. 配置设备清单 devices.json
# 2. 启动服务器（公网机器）
server -listen :8080 -devices devices.json

# 3. 在目标 Linux 机器上启动 agent
agent -server ws://server-ip:8080 -id web-01 -token T0k3n

# 4. 操作者执行命令
client -server ws://server-ip:8080 exec -token T0k3n "uptime"
client -server ws://server-ip:8080 shell -token T0k3n   # 进入交互终端，Ctrl+D 退出
client list        # 查看在线设备
```

## 10. 安全注意事项

1. token 即设备钥匙，务必通过安全渠道分发，建议用环境变量注入而非命令行参数（避免进 shell history）。
2. 生产环境务必启用 WSS（TLS），否则 token 与指令内容明文传输。
3. 审计日志（0600）记录所有指令与操作者标识，便于追溯。
4. WebSocket 默认拒绝跨源 Origin；Web 端接入需显式 `-allow-any-origin`。
5. 本系统等同远程 root shell 的能力：只应在可信网络/设备上使用，不要部署到不信任的设备；给 AI Agent 使用时建议在 agent 侧以最小权限账户运行。

## 11. Machine Client Contract（机器客户端契约）

面向 AI Agent / 自动化客户端的使用约定：

### 11.1 完成语义

- 一条 exec 只有在收到 `done=true` 的 exec_output 帧后才算完成；该帧携带 `exit_code`。
- 收到 `type=error` 帧表示请求被拒绝（未执行），错误码见 11.2。
- 任何连接错误（EOF / 超时 / 1006）都表示**结果未知**：命令可能已执行。不得假定未执行而盲目重试非幂等命令。
- `truncated=true` 表示输出因背压被丢弃过，内容不完整，不得当作完整结果解析。
- agent 掉线时在途 exec 会收到 `error_code=agent_lost` 的完成帧；client 中断时在途 exec 会被服务端取消（exec_kill），不会变成孤儿进程。

### 11.2 错误码

| code | 含义 | Agent 建议动作 |
|---|---|---|
| bad_token | token 不存在 | 配置错误：上报人类，勿重试 |
| device_offline | 设备离线 | 可等待后重试 |
| auth_required | 未认证 | 先发 auth |
| bad_payload | 消息 payload 无效 | 修正请求 |
| conflict | exec ID 冲突 | 换新 ID 重试 |
| timeout | 执行超时（进程树已被终止） | 按需重试或降级 |
| killed | 执行被取消 | 按需重试 |
| agent_lost | 执行中 agent 掉线 | 结果未知，谨慎重试非幂等命令 |
| start_failed | 进程启动失败 | 检查命令/workdir |
| overload | 并发超限 | 稍后重试 |
| not_found | 文件不存在 | 检查路径 |
| bad_device | 未知设备 ID（clientd 配置中不存在） | 检查设备清单 |
| connection_lost | clientd 与中继的连接断开 | 稍后重试（服务自动重连） |
| internal | 内部错误 | 上报 |

### 11.3 超时语义

- `-timeout` 由 agent 强制执行：到期终止**整个进程树**，然后回 `done` 帧（`error_code=timeout`）。
- 客户端读侧另有 `-deadline`（默认 = timeout + 10s 宽限）兜底，防止服务端异常导致工具调用永久挂起。
- 收到 SIGINT/SIGTERM 时 client 先向 agent 发 exec_kill 再退出。

### 11.4 输出约定

- stdout 与 stderr 合并输出（exec 模式）。
- Windows 控制台输出自动转码为 UTF-8（启发式：已是 UTF-8 原样，否则按 GBK 解码）。
- shell 模式包含 ANSI 转义序列与提示符回显，解析前需自行处理。

### 11.5 重试与幂等

- 网络层错误（连接失败 / 超时 / 断开）≠ 命令未执行。非幂等命令的重试必须由上层显式决策，协议不提供幂等键。
- 每次 exec 使用新的随机 ID（client 自动生成），ID 重复会被服务端拒绝。
