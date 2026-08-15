# rtctl — 远程终端控制系统（AI Agent 直控版）

用 Go 实现的远程终端控制系统，专为 **AI Agent 直控目标服务器** 设计：

```
AI Agent ──HTTP API──→ clientd (client serve, 常驻服务)
                          │ 长连接
                          ↓
                      server (中继)
                          ↑ 长连接（主动拨出，穿透 NAT）
                       agent (目标服务器)
```

- **Agent 不再手动复制指令、不再手动传输文件**：本地起一个常驻 HTTP 服务（`client serve`），Agent 通过 REST API 直接执行命令、上传/下载文件。
- **agent**（被控端，Linux/Windows）主动连接中继，可穿透 NAT，无需公网 IP。
- **server**（中继）居中路由 + 审计，不存储指令语义。
- 每设备独立 token 认证；可选客户端密钥；可选 WSS/TLS；审计日志含操作者归因。

## 核心能力

| 能力 | 说明 |
|---|---|
| `exec` | 一次性命令：退出码、超时（杀整个进程树）、workdir、stdin、`-c` 原样命令 |
| 文件传输 | `file-put` / `file-get`（256KB 分片，1MB 文件哈希校验一致），CLI 与 HTTP API 双入口 |
| `shell` | 交互终端（Linux 真 PTY / Windows cmd 管道） |
| `list` | 设备在线状态 + 元数据（OS/架构/主机名/版本） |
| 机器契约 | `-json` 结构化输出、11 种机器可读错误码、`truncated` 截断标记、done 帧可靠送达 |
| 可靠性 | 掉线即通知（不挂死）、中断即取消远端（无孤儿进程）、断线自动重连 |

## 快速开始

```bash
# 1. 构建（需 Go >= 1.25，或 GOTOOLCHAIN 自动下载）
go build -o bin/ ./cmd/...
#    bin/ 附带预编译产物：Windows exe + Linux amd64/arm64 静态二进制（免编译直传）

# 2. 设备清单（每台设备一个 token，必须唯一）
cat > devices.json <<'EOF'
{ "devices": [ { "id": "web-01", "token": "MY-SECRET-TOKEN" } ] }
EOF

# 3. 中心机启动中继
./bin/server -listen :8080 -devices devices.json

# 4. 目标设备启动 agent
RTCTL_TOKEN=MY-SECRET-TOKEN ./bin/agent -server ws://server-ip:8080/ws?role=agent -id web-01

# 5. 操作机：启动常驻 HTTP 服务（AI Agent 入口）
./bin/client -server ws://server-ip:8080/ws?role=client serve \
  -listen 127.0.0.1:18080 -devices devices.json -api-key my-api-key

# 6. AI Agent 直接调用（无需手动复制指令/传文件）
curl -H 'Authorization: Bearer my-api-key' \
  -d '{"device_id":"web-01","cmd":"uptime"}' http://127.0.0.1:18080/api/v1/exec
```

## HTTP API（client serve）

| 端点 | 说明 |
|---|---|
| `GET /healthz` | 健康检查（免认证） |
| `GET /api/v1/devices` | 设备列表（在线状态 + 元数据） |
| `POST /api/v1/exec` | `{"device_id","cmd","timeout_ms","workdir","stdin"}` → `{"exit_code","output","truncated","error","error_code","duration_ms"}` |
| `POST /api/v1/files/upload` | `{"device_id","path","data"(base64),"mode"}` → `{"ok","size"}` |
| `POST /api/v1/files/download` | `{"device_id","path"}` → `{"ok","size","data"(base64)}` |

- 认证：`Authorization: Bearer <api-key>`（`-api-key` 不传自动生成并打印）
- 设备寻址用 `device_id`，token 只存在于 clientd 的本地设备清单——Agent 永远不接触 token
- 调用方超时/断开会自动取消远端命令；中继断线返回 `connection_lost`，恢复后自动重连

CLI 同样支持文件传输：`client file-put -token T local.txt /etc/remote.txt`、`client file-get -token T /var/log/app.log ./app.log`

## 一键部署

唯一入口：Linux `deploy.sh` / Windows `deploy.ps1`（自动下载二进制，免编译）：

```bash
# ① 中心机：中继 + 自动生成设备 token
curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.sh -o deploy.sh
bash deploy.sh server --port 8443 jp-tokyo-01 web-01

# ② 每台被控机：装 agent（命令由 ① 的输出复制）
bash deploy.sh agent --server-url wss://中继:8443/ws?role=agent --id jp-tokyo-01 --token <token>

# ③ 操作机：常驻 HTTP 服务（AI Agent 入口）
bash deploy.sh clientd --server-url wss://中继:8443/ws?role=client --client-key <密钥> --devices devices.json

# ④ 升级：bash deploy.sh update server|agent|client|clientd
```

详见 [deploy/README.md](deploy/README.md)（Windows 用法、安全基线、自动启动/开机自启/随机 token 说明）。

## 安全

- token 即设备钥匙；服务器启动时校验清单（无重复/空值）、对 `change-me-*` 占位 token 告警
- 生产务必 WSS；`-client-key` 限制谁能连中继；clientd 自身带 API 密钥
- WebSocket 默认拒绝跨源 Origin；审计日志 0600；低权限运行账户
- 文件传输走临时文件 + 原子改名，中断自动清理；上传/下载并发与大小受限

完整协议与架构见 [DESIGN.md](DESIGN.md)，机器客户端契约（完成语义/错误码/重试幂等）见其第 11 节。

## 开源协议

[MIT License](LICENSE) © 2026 GotKiCry
