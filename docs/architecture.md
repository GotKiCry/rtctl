# rtctl 架构与协议

本文面向开发者，说明直连架构、消息协议、错误码和边界行为。安装与使用说明见 [README](../README.md)。

## 1. 这个东西做什么

还是那两个二进制：

- **rtctl-agent**：放在目标服务器上，自己开一个 WebSocket 服务口，等别人连。
- **rtctl**：你电脑上的命令行工具，直接连 agent，发一条命令、收结果。

三种主要用法：
1. **一次性命令**（`exec`）：发一条 Shell 命令，拿回输出和退出码。
2. **交互式终端**（`shell`）：像 SSH 那样开一个会话，可以持续敲命令。
3. **文件传输**（`file-put` / `file-get`）：上传或下载单个文件。

## 2. 怎么连

```
+----------+   直连 WebSocket    +------------------+
|  rtctl   |  ----------------->  | agent（目标机）  |
| (你电脑) |    JSON 消息         | (自己监听端口)   |
+----------+                     +------------------+
```

要点：

- 没有中间服务器，agent 自己监听，rtctl 直连。
- 每台设备一把钥匙（token）。**token 就是设备全部权限**，谁有谁操作。
- 客户端连接后发送 `auth`（可带 `id` 标识操作者）；exec、shell 和文件操作会校验 token，`list` 与 `/healthz` 无需 token。
- agent 默认拒绝浏览器网页发起的跨站连接（防被人挂页面偷偷连）。

## 3. 消息长什么样

所有消息都是 JSON，外面套一个统一格式：

```json
{
  "type": "exec",        // 消息类型
  "id": "a1b2c3",        // 消息 ID（命令/传输用同一个 ID 串起来）
  "token": "设备钥匙",    // 发起类消息要带的钥匙
  "session_id": "s1",    // 交互终端会话的 ID
  "payload": {  ...  }   // 各类型自己的字段
}
```

### 3.1 打招呼与查询

| 类型 | 谁发给谁 | 说明 |
|---|---|---|
| auth | 客户端 → agent | 握手，可带 `id` 标识操作者 |
| auth_ack | agent → 客户端 | 握手结果 |
| list | 客户端 → agent | 查设备信息 |
| list_ack | agent → 客户端 | 系统/架构/主机名/版本/编号 |

### 3.2 一次命令（exec）

| 类型 | 谁发给谁 | 说明 |
|---|---|---|
| exec | 客户端 → agent | `{cmd, timeout_ms?, workdir?, stdin?, sudo?, sudo_password?}` 发起执行 |
| exec_output | agent → 客户端 | 输出分批回传；最后一帧 `done=true` 带退出码；`truncated=true` 表示输出太多了，中间有丢 |
| exec_kill | 客户端 → agent | `{exec_id}` 停止这个命令 |

执行细节：

- Linux 用 `/bin/sh -c`，Windows 用 `cmd /C`（Windows 上特殊处理了命令行转义，防止引号被吃掉导致命令悄悄变样）。
- 输出每 32KB 一段回传。
- 超时/被取消时，会把**命令和它生出来的所有子进程**全部结束（Linux 杀进程组，Windows 用 `taskkill /T`），不留后台孤儿。

### 3.3 交互终端（shell）

| 类型 | 谁发给谁 | 说明 |
|---|---|---|
| shell_open | 客户端 → agent | 开一个终端（Linux 用真终端，Windows 用 cmd 管道） |
| shell_ack | agent → 客户端 | 开好了没有 |
| shell_data | 双向 | 屏幕/键盘字节流 |
| shell_resize | 客户端 → agent | 窗口变化时改终端大小（全屏程序需要） |
| shell_close | 任意一方 | 关掉会话 |

### 3.4 文件传输

| 类型 | 谁发给谁 | 说明 |
|---|---|---|
| file_put | 客户端 → agent | `{path, mode?, size}` 开始上传，先写到临时文件 `<路径>.rtctl-partial` |
| file_put_chunk | 客户端 → agent | 每段 256KB，最后一段 `done=true` 时改好权限、替换正式文件 |
| file_put_ack | agent → 客户端 | 上传结果 |
| file_get | 客户端 → agent | 请求下载 |
| file_get_chunk | agent → 客户端 | 下载内容一段段回传 |
| file_abort | 客户端 → agent | 放弃上传，删掉临时文件 |

约定：

- 单个文件最大 256MB；同一台设备同时执行：命令 32 个、终端 8 个、上传 8 个、下载 8 个，超出直接拒绝（`overload`）。
- 文件内容**不许悄悄丢**：传文件的帧是"必须送达"的，发不出去就断开连接。
- 上传是"先写临时文件、全部写完后才替换正式文件"——不会出现把原文件写一半的情况。

## 4. 各模块分工

### 4.1 agent（`cmd/agent` + `internal/agent`）

- 平台差异放在 `shell_linux.go` / `shell_windows.go`（用 build tag 区分编译）：
  - Linux：真终端 + `sh`；
  - Windows：`cmd.exe` 管道模式。
- 超时/取消会把命令和它生出的所有子进程一并结束（见 3.2）。
- Windows 输出的中文编码自动判断（UTF-8 直接用，否则按 GBK 转）。
- 每条消息处理完，把结果回给**发来请求的那条连接**。
- 客户端断开时，把所有它发起的命令、终端、上传全部清理掉，不留孤儿进程。
- 直接运行时默认脱离终端进入后台；父进程等子进程绑定监听成功后再返回，启动失败会带回错误（端口占用时附排查提示）。`-foreground` 禁止自后台化，供 systemd/OpenRC/nohup 等外部托管。`-status` 在 PID 文件无记录但监听端口被占时会提示存在未受管实例。
- 运行日志由 agent 自己写入文件（0600），每个文件约 10MB，保留 3 个轮转备份；PID 文件记录进程身份，用于 `-status` 与 `-stop`。`-logs` 在本机直接查看日志：文件保持纯文本，查看时按来源/结果着色并脱敏（token/私钥不原样显示）。

### 4.2 客户端（`cmd/client`）

- 支持 `list / exec / shell / file-put / file-get`，外加一个快捷入口：
  `rtctl <IP>:<端口> <token> '命令'` 等价于 `exec -c '命令'`。
- 每次命令用随机 ID；ID 撞车会被 agent 拒绝（返回 `conflict`）。

## 5. 给程序调用的约定（机器契约）

如果你写脚本/程序来调用 rtctl，这些行为是固定的：

### 5.1 命令什么时候算"结束"

- 收到 `done=true` 的那一帧才算结束，退出码也在这一帧里。
- 收到 `type=error` 的帧 = 请求被拒、**根本没执行**。
- 连接断了 / 超时 = **不知道结果**：命令可能已经跑了，别当它没执行过就重试（比如重启服务这种命令，重试可能出事）。
- `truncated=true` = 输出太多有丢失，内容不完整。
- 文件传输成功的标志：上传看 `file_put_ack{ok}`；下载看最后一帧 `{done, error为空}`。

### 5.2 错误码

| 错误码 | 含义 |
|---|---|
| bad_token | token 不对 |
| auth_required | 还没打招呼 |
| bad_payload | 消息格式不对 |
| conflict | ID 撞车，换一个重试 |
| timeout | 超时了（命令和子进程都已结束） |
| killed | 被取消了 |
| start_failed | 命令没启动起来（检查命令/路径对不对） |
| overload | 同时干的活儿太多，稍后再试 |
| not_found | 文件不存在 |
| internal | 内部错误 |
| sudo_disabled | 想用 root 权限但 agent 没开 `allow_sudo` |
| sudo_denied | sudo 密码错误或服务器侧授权失败 |
| approval_required | 特权命令没被确认（非交互没加 `-confirm-sudo`） |

### 5.3 root 权限（sudo）怎么把关

想用 `-sudo` 执行 root 命令，三层缺一不可：

1. **agent 层**：`allow_sudo = true`（默认关，防手滑）；
2. **客户端层**：交互时当面 y/N 确认；程序调用必须显式 `-confirm-sudo`；
3. **服务器层**：永久授权需要 sudoers 免密规则，临时授权需要有效的 root 密码。

永久授权通过 `sudo -n -- /bin/sh -c <命令>` 执行。临时授权由客户端使用 `-sudo-ask`（或脚本使用 `-sudo-password-stdin`）取得密码，agent 再通过 `sudo -S` 读取；密码只用于本次提权，不写入配置或日志。agent 本身始终保持普通用户运行，日志里特权命令会标 `(SUDO)`。

### 5.4 超时行为

- `-timeout` 由 agent 强制执行：到点结束命令和所有子进程，然后回一帧 `{done:true, error_code:timeout}`。
- 客户端断开 = agent 清理该客户端的命令/终端/上传（见 4.1）。

### 5.5 重试注意事项

- 网络断了 ≠ 命令没跑。**别默认重试**非一次性命令。
- 每条命令用新 ID；重复 ID 会被拒绝。

## 6. 配置项

| 程序 | 参数 | 默认值 | 说明 |
|---|---|---|---|
| agent | `-config` | `~/.rtctl/agent.conf` | 配置文件路径（查找顺序：`-config` > `~/.rtctl/agent.conf` > exe 同目录 > 当前目录；`-init` 默认写入 `~/.rtctl/agent.conf`） |
| agent | `-init` | — | 生成配置（含随机 token）并打印连接信息 |
| agent | `-listen` | `:8443` | 监听地址 |
| agent | `-id` / `-token` | — | 设备编号/钥匙（或环境变量 `RTCTL_ID` / `RTCTL_TOKEN`） |
| agent | `-tls-cert` / `-tls-key` | 空 | 两个都填 = 开加密（WSS） |
| agent | `-ws-path` | `/ws` | WebSocket 路径，健康检查同步注册在对应前缀下 |
| agent | `-allow-sudo` | false | 允许 root 特权命令 |
| agent | `-print-token` | true | 启动信息是否打印完整 token；服务安装时默认关闭 |
| agent | `-open-firewall` | true | 启动时自动放行监听端口（best-effort：root/管理员直接执行，否则尝试免密 sudo；失败只提示不阻塞） |
| agent | `-foreground` | false | 前台运行；默认直接启动会后台化，服务管理器托管时必须传此参数 |
| agent | `-status` / `-stop` | — | 查询/停止 PID 文件对应的本机实例 |
| agent | `-logs` | — | 查看运行日志后退出（自带脱敏与终端着色；只读日志，不启动服务） |
| agent | `-follow` / `-lines` / `-no-color` | 100 行 | 仅配 `-logs`：跟随输出 / 显示行数 / 关颜色（`NO_COLOR` 环境变量同样生效） |
| agent | `-log-file` | `~/.rtctl/agent.log` | 自管理运行日志（0600，约 10MB 轮转，保留 3 个备份） |
| agent | `-pid-file` | `~/.rtctl/agent.pid` | PID 与可执行文件身份记录 |
| rtctl | `-server` | ws://127.0.0.1:8443/ws | 设备地址 |
| rtctl | `-cafile` / `-insecure` | 空 / false | 自定义 CA / 跳过证书校验（后者仅限调试） |
| rtctl | `-client-id` | 空 | 记录操作者身份（日志用） |
| rtctl | `-json` | false | 输出 JSON |
| rtctl exec | `-timeout` / `-workdir` / `-stdin-file` / `-c` | — | 执行选项 |
| rtctl exec | `-sudo` / `-confirm-sudo` | false | 特权命令 + 程序调用确认 |
| rtctl exec | `-sudo-ask` / `-sudo-password-stdin` | false | 临时提权：交互读取密码 / 从标准输入读取密码 |

取值优先级（agent）：命令行 > 配置文件 > 环境变量。

## 7. 目录结构

```
rtctl/
├── cmd/
│   ├── agent/               # 被控端入口、后台进程、PID 与日志管理
│   └── client/              # 控制端入口、命令分发和文件传输
├── internal/
│   ├── agent/               # 命令执行器与直连服务端
│   ├── console/             # Windows 控制台兼容处理
│   ├── idutil/              # 随机 ID
│   └── proto/               # 消息类型和字段定义
├── docs/architecture.md     # 本文档
├── install.sh               # Linux 安装与管理脚本
├── build.sh / build.ps1     # 跨平台构建
└── go.mod / go.sum          # Go 模块与依赖锁定
```

## 8. 安全注意

1. token 就是设备钥匙，走安全渠道分发；建议放进 agent.conf（0600）或环境变量，别放命令行历史。
2. 跨公网必开 WSS（`tls_cert/tls_key`），否则 token 和命令都是明文。
3. agent 默认拒绝网页跨站连接；建议用普通用户跑 agent，别用 root。
4. 这工具 = 远程 Shell：只在可信机器上装。
5. 特权命令默认关闭；必须显式启用 `allow_sudo`，并完成客户端确认和服务器侧授权。详见 [安全政策](../SECURITY.md)。
