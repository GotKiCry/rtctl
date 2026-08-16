# rtctl — 远程终端控制系统设计文档（纯直连版）

## 1. 目标

一个基于 Go 的远程终端控制系统，专为 **AI Agent 直控目标服务器** 设计，由两部分组成：

- **agent（被控端）**：部署在目标 Linux / Windows 设备上，自带 WS 服务端，client/clientd 直接连接。
- **client（控制端）**：CLI + 常驻 HTTP 服务（`serve`，供 AI Agent 直控）。

两种控制模式：
1. **exec 一次性执行**：发一条 shell 命令，拿回 stdout / stderr / 退出码。
2. **shell 实时交互终端**：像 SSH 一样打开目标设备的交互式终端（Linux 真 PTY / Windows cmd 管道）。

另有**文件传输**（分片上传/下载）供 Agent 免手动传文件。

## 2. 架构（纯直连，无中继）

```
+-------------+   HTTP    +----------+   直连 wss    +-------------------+
|  AI Agent   | --------> | clientd  | ------------> | agent (-listen)   |
| (任何程序)  |  JSON API | (client   |   JSON消息    | (目标设备, 自带监听) |
+-------------+           |  serve)  |               +-------------------+
                          +----------+
                              |  CLI 子命令: list / exec / shell / file-put / file-get
```

- **agent 自带监听**（`-listen`，支持 `-tls-cert/-tls-key`）：实现完整服务端协议（auth/list/exec/shell/file）。
- **clientd**（`client serve`）是操作机上的常驻 HTTP 服务：Agent 通过 REST API 直控设备，token 只存在于 clientd 本地设备清单（`{devices:[{id,token,url}]}`），Agent 不接触凭据、不手动传输文件。
- 设备清单每条设备**必须带 url 直连地址**；clientd 按请求独立连接设备，`list` 逐个探活。

## 3. 认证模型（token）

**每台设备一个 token，任何持有该 token 的客户端都可以向该设备发指令。**

- agent 启动时配置 `id + token`（`-id/-token` 或环境变量 `RTCTL_ID/RTCTL_TOKEN`）。
- **token 校验**：agent 对发起类消息（exec/exec_kill/shell_open/file_put/file_get/file_abort）逐条校验设备 token；分片/流消息（file_put_chunk/shell_data/resize/close）不带 token，按 ID/会话绑定。
- 连接建立先 `auth` 握手（可选字段 `id`，审计归因）；agent 默认拒绝跨源 Origin。
- 建议 WSS（TLS）；token 请通过环境变量注入，避免进命令行历史。

## 4. 消息协议（JSON over WebSocket）

所有消息为 UTF-8 JSON，统一外壳：

```json
{
  "type": "exec",
  "id": "消息唯一ID（exec/文件传输关联用）",
  "token": "设备token（发起类消息校验用）",
  "session_id": "会话ID（shell模式用）",
  "payload": { "...": "类型相关字段" }
}
```

### 4.1 连接与发现

| type | 方向 | payload | 说明 |
|---|---|---|---|
| auth | client -> agent | {id?} | 连接握手（操作者/Agent 标识） |
| auth_ack | agent -> client | {ok, error?} | 握手结果 |
| list | client -> agent | {} | 查询设备信息 |
| list_ack | agent -> client | {devices:[{id, online, os?, arch?, hostname?, version?}]} | 设备信息（单设备） |

### 4.2 一次性执行（exec）

| type | 方向 | payload | 说明 |
|---|---|---|---|
| exec | client -> agent | {cmd, timeout_ms?, workdir?, stdin?} | 发起执行 |
| exec_output | agent -> client | {seq, data, done, exit_code?, error?, error_code?, truncated?} | 输出分片；最后一片 done=true 携带退出码；truncated=true 表示输出因背压被丢弃过 |
| exec_kill | client -> agent | {exec_id} | 取消执行 |

执行语义：Linux 上经 `/bin/sh -c`，Windows 上经 `cmd /C`（精确命令行构造，嵌套引号不被剥掉）。
输出按 32KB 分片。超时/取消会终止**整个进程树**（Linux 进程组、Windows `taskkill /T`）。

### 4.3 交互式终端（shell）

| type | 方向 | payload | 说明 |
|---|---|---|---|
| shell_open | client -> agent | {} | 打开交互终端（Linux: 真 PTY；Windows: cmd 管道模式） |
| shell_ack | agent -> client | {ok, error?} | 打开结果 |
| shell_data | 双向 | {data} | 终端字节流 |
| shell_resize | client -> agent | {cols, rows} | 调整 PTY 窗口（client 在打开时与 SIGWINCH 时自动发送） |
| shell_close | 任意一方 | {} | 关闭终端会话 |

### 4.4 文件传输（分片，Msg.ID 为传输 ID）

| type | 方向 | payload | 说明 |
|---|---|---|---|
| file_put | client -> agent | {path, mode?, size} | 开始上传；agent 建临时文件 `<path>.rtctl-partial` |
| file_put_chunk | client -> agent | {seq, data(base64), done} | 256KB 分片；最后一片 done=true 时 chmod + 原子改名 |
| file_put_ack | agent -> client | {ok, error?} | 上传回执 |
| file_get | client -> agent | {path} | 请求下载 |
| file_get_chunk | agent -> client | {seq, data(base64), done, error?, error_code?} | 下载分片；失败 done=true 带错误码 |
| file_abort | client -> agent | — | 取消上传，清理临时文件 |

- 文件数据不可静默丢弃：分片走阻塞发送（10s），失败断连。
- 上限：单文件 256MB；并发 put 8 / get 8 / exec 32 / shell 8（单设备）。

### 4.5 通用

| type | 说明 |
|---|---|
| error | {error, code?} 任何错误；code 为机器可读错误码（见 6.2） |
| ping / pong | 心跳（配合 WebSocket ping/pong 保活） |

## 5. 组件实现要点

### 5.1 agent（`cmd/agent` + `internal/agent`）

- 平台差异封装在 `shell_linux.go` / `shell_windows.go`（build tag）：
  - Linux：`creack/pty` 真 PTY + `sh`；窗口 resize；vim/top 可用。
  - Windows：`cmd.exe` 管道模式（非真 PTY，全屏程序体验受限）。
- **超时/取消终止整个进程树**：Linux `Setpgid`+杀进程组；Windows `taskkill /T /F`。
- **Windows 命令构造**：`SysProcAttr.CmdLine` 精确控制命令行（默认 argv 引用会剥内层引号导致静默错误执行）。
- **输出转码**：Windows 启发式转码（UTF-8 原样，否则 GBK/CP936 解码）。
- **响应定向**：处理函数经 `sendSink` 抽象——响应写回发起请求的那条客户端连接。
- **连接断开清理**：client 断开时取消其 exec、关闭其 shell、清理其上传临时文件（不留孤儿）。

### 5.2 clientd（`cmd/client serve`）

- **凭据隔离**：本地设备清单提供 device_id -> token+url 映射；Agent 只使用 device_id。API 密钥优先从 `RTCTL_API_KEY` 环境变量读取（安装器经 EnvironmentFile 注入）。
- **API**：`GET /api/v1/devices`、`POST /api/v1/exec`、`POST /api/v1/files/upload|download`，Bearer API 密钥（不传自动生成）。
- **生命周期**：每请求独立连接；请求超时/断开即向 agent 发 exec_kill / file_abort。
- **背压**：agent 侧发送队列满时普通帧丢弃并在 done 帧标注 `truncated`；done 帧与文件分片阻塞送达；慢消费者 10s 写超时断连并取消其 exec。

## 6. Machine Client Contract（机器客户端契约）

### 6.1 完成语义

- 一条 exec 只有在收到 `done=true` 的 exec_output 帧后才算完成；该帧携带 `exit_code`。
- 收到 `type=error` 帧表示请求被拒绝（未执行），错误码见 6.2。
- 任何连接错误（EOF / 超时）都表示**结果未知**：命令可能已执行。不得假定未执行而盲目重试非幂等命令。
- `truncated=true` 表示输出因背压被丢弃过，内容不完整，不得当作完整结果解析。
- 文件传输以 `file_put_ack{ok}` / `file_get_chunk{done,error为空}` 为成功标志。

### 6.2 错误码

| code | 含义 | Agent 建议动作 |
|---|---|---|
| bad_token | token 无效 | 配置错误：上报人类，勿重试 |
| auth_required | 未认证 | 先发 auth |
| bad_payload | 消息 payload 无效 | 修正请求 |
| conflict | ID 冲突 | 换新 ID 重试 |
| timeout | 执行超时（进程树已被终止） | 按需重试或降级 |
| killed | 执行被取消 | 按需重试 |
| start_failed | 进程启动失败 | 检查命令/workdir |
| overload | 并发超限 | 稍后重试 |
| not_found | 文件不存在 | 检查路径 |
| bad_device | 未知设备 ID（clientd 配置中不存在） | 检查设备清单 |
| connection_lost | 与设备的连接断开 | 稍后重试 |
| internal | 内部错误 | 上报 |
| sudo_disabled | 特权命令被拒：被控端 agent 未开 -allow-sudo | 上报人类，由管理员在被控端授权后重试 |
| sudo_denied | sudo 执行失败：sudoers 未放行（或密码缺失/NNP 阻挡） | 上报人类，检查被控端 sudoers |
| approval_required | 特权命令未获用户批准：clientd 未开 -allow-sudo（HTTP 403） | 征得用户同意后由用户在控制端开启 |

### 6.2a 特权命令（sudo）审批模型

- `exec` 载荷带 `sudo:true` 表示请求 root 提权执行。**三道闸，缺一不可**：
  1. **被控端授权**（agent `-allow-sudo`，安装时由管理员选择；默认关）——未开回 `sudo_disabled`；
  2. **控制端批准**（clientd `-allow-sudo`；CLI 交互下 y/N 当面确认，非交互须显式 `-confirm-sudo`）——clientd 未开回 HTTP 403 `approval_required`；
  3. **sudoers 放行**（`rtctl-agent ALL=(ALL) NOPASSWD: /bin/sh, /usr/bin/sh, /usr/bin/kill, /bin/kill`，按命令路径最小授权）——失败回 `sudo_denied`。
- 设备端执行：`sudo -n -- /bin/sh -c <cmd>`；agent 保持低权限用户运行，仅该条命令提权（与"agent 整体跑 root"相比保留了纵深防御）。
- **版本门槛**：`sudo:true` 需 agent ≥ 3.1.0。旧 agent（3.0.x）不认识该字段，会**静默按低权限执行**——调用方必须先 `list` 确认设备版本 ≥ 3.1.0 再发特权请求。
- 审计：agent 与 clientd 的日志对特权命令打 `(SUDO)` 标记。

### 6.3 超时语义

- `-timeout` 由 agent 强制执行：到期终止**整个进程树**，然后回 `done` 帧（`error_code=timeout`）。
- clientd 侧有总等待上限（默认 timeout + 30s 宽限）兜底，防止工具调用永久挂起。
- 调用方断开时，clientd 向 agent 发 exec_kill / file_abort，不留孤儿进程。

### 6.4 重试与幂等

- 网络层错误（连接失败 / 超时 / 断开）≠ 命令未执行。非幂等命令的重试必须由上层显式决策，协议不提供幂等键。
- 每次 exec 使用新的随机 ID（client 自动生成），ID 重复会被拒绝。

## 7. 配置

| 组件 | 参数 | 默认 | 说明 |
|---|---|---|---|
| agent | -listen | :8443 | 监听地址 |
| agent | -id / -token | — | 设备身份（或环境变量 RTCTL_ID / RTCTL_TOKEN） |
| agent | -tls-cert / -tls-key | 空 | 启用 WSS（必须同时提供） |
| agent | -allow-any-origin | false | 放行任意 Origin（Web 接入用） |
| agent | -allow-sudo | false | 允许特权命令（sudo:true 经 sudo 提权；安装器同时写 sudoers 并放开 NoNewPrivileges） |
| client | -server | ws://127.0.0.1:8443/ws | 设备直连地址 |
| client | -client-id | 空 | 操作者/Agent 标识（审计归因） |
| client | -json | false | 结构化输出（list / exec） |
| client exec | -timeout / -workdir / -stdin-file / -c | — | 执行选项 |
| client exec | -sudo / -confirm-sudo | false | 特权命令 + 非交互确认（交互下 y/N 当面确认） |
| client serve | -listen | 127.0.0.1:18080 | HTTP 监听地址 |
| client serve | -devices | devices.json | 设备清单（device_id -> token+url） |
| client serve | -api-key | 空 | API 密钥（留空读 RTCTL_API_KEY，再为空自动生成并打印；推荐环境变量注入） |
| client serve | -allow-sudo | false | 特权命令转发闸（开才转发 sudo:true，否则 403 approval_required） |

## 8. 目录结构

```
rtctl/
├── go.mod
├── deploy.sh / deploy.ps1   # 一键部署（agent/client/clientd/update）
├── cmd/
│   ├── agent/main.go        # 被控端入口（直连监听）
│   ├── client/              # 控制端 CLI + clientd HTTP 服务
│   │   ├── main.go          # 入口/分发 + list/exec/shell
│   │   ├── file.go          # file-put / file-get 子命令
│   │   ├── serve.go         # clientd 常驻 HTTP 服务（Agent 入口）
│   │   └── winch_*.go       # 终端尺寸（SIGWINCH）
│   └── installer/           # rtctl-wizard 二进制安装向导
└── internal/
    ├── proto/proto.go       # 消息协议定义与编解码
    ├── agent/               # 执行器 + standalone 服务端（linux/windows 分平台）
    └── idutil/              # 消息/会话/传输 ID
```

## 9. 使用示例

```bash
# 1. 目标服务器启动 agent（自带监听）
RTCTL_TOKEN='高熵随机串' agent -listen :8443 -id jp-tokyo-01

# 2. 操作机：clientd（AI Agent 入口）
client serve -listen 127.0.0.1:18080 -devices devices.json -api-key k1

# 3. AI Agent 调用
curl -H 'Authorization: Bearer k1' \
  -d '{"device_id":"jp-tokyo-01","cmd":"uptime","timeout_ms":10000}' \
  http://127.0.0.1:18080/api/v1/exec

# 4. 或 CLI 直连
client -server ws://jp服务器IP:8443/ws exec -token <token> 'uptime'
client -server ws://jp服务器IP:8443/ws file-get -token <token> /var/log/app.log ./app.log
```

## 10. 安全注意事项

1. token 即设备钥匙，务必通过安全渠道分发，用环境变量注入而非命令行参数（避免进 shell history）。安装器经 EnvironmentFile（0600，root:服务账户）注入——不要回退到 unit 内联 `Environment=`（unit 0644 全局可读）或 `-api-key` 命令行参数（`ps` 全局可见）。
2. 生产建议启用 WSS（`-tls-cert/-tls-key`），否则 token 与指令内容明文传输。
3. 默认拒绝跨源 Origin；给 AI Agent 使用时建议在 agent 侧以最小权限账户运行。
4. 本系统等同远程 shell 的能力：只应在可信网络/设备上使用，不要部署到不信任的设备。
5. 特权命令（sudo）默认全链路拒绝：被控端 `-allow-sudo`、控制端 `-allow-sudo`、sudoers 放行三道闸都必须由人显式打开；AI Agent 无权自行解除（6.2a）。
