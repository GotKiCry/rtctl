# rtctl — 远程终端控制系统（AI Agent 直控，纯直连版）

用 Go 实现的远程终端控制系统，专为 **AI Agent 直控目标服务器** 设计。**没有中继、没有中心服务器**——目标机上的 agent 自带监听，clientd/client 直接连接：

```
AI Agent ──HTTP API──→ clientd (client serve, 常驻服务) ──直连──→ agent (目标服务器, 自带监听)
```

- **Agent 不再手动复制指令、不再手动传输文件**：操作机上起一个常驻 HTTP 服务（`client serve`），Agent 通过 REST API 直接执行命令、上传/下载文件。
- **agent**（被控端，Linux/Windows）：自带 WS 服务端（`-listen`），持设备 token 即可控。
- **client**（控制端 CLI）：直连 agent，`list / exec / shell / file-put / file-get`。
- 每设备独立 token 认证；文件传输分片+哈希可校验；审计归因。

## 核心能力

| 能力 | 说明 |
|---|---|
| `exec` | 一次性命令：退出码、超时（杀整个进程树）、workdir、stdin、`-c` 原样命令 |
| 文件传输 | `file-put` / `file-get`（256KB 分片，哈希校验一致），CLI 与 HTTP API 双入口 |
| `shell` | 交互终端（Linux 真 PTY / Windows cmd 管道） |
| `list` | 设备信息与元数据（OS/架构/主机名/版本） |
| 机器契约 | `-json` 结构化输出、机器可读错误码、`truncated` 截断标记、done 帧可靠送达 |
| 可靠性 | 断开即取消远端（无孤儿进程）、并发/大小上限 |

## 快速开始

```bash
# 1. 构建（需 Go >= 1.25，或 GOTOOLCHAIN 自动下载）
go build -o bin/ ./cmd/...
#    bin/ 附带预编译产物：Windows exe + Linux amd64/arm64 静态二进制（免编译直传）

# 2. 目标服务器：agent 自带监听
RTCTL_TOKEN='设备token' ./bin/agent -listen :8443 -id jp-tokyo-01

# 3. 操作机：常驻 HTTP 服务（AI Agent 入口），设备清单里写 agent 的直连地址
cat > devices.json <<'EOF'
{ "devices": [ { "id": "jp-tokyo-01", "url": "ws://jp服务器IP:8443/ws", "token": "设备token" } ] }
EOF
./bin/client serve -listen 127.0.0.1:18080 -devices devices.json -api-key my-api-key

# 4. AI Agent 直接调用（无需手动复制指令/传文件）
curl -H 'Authorization: Bearer my-api-key' \
  -d '{"device_id":"jp-tokyo-01","cmd":"uptime"}' http://127.0.0.1:18080/api/v1/exec
```

CLI 也可直连：`./bin/client -server ws://jp服务器IP:8443/ws exec -token <token> 'uptime'`

## HTTP API（client serve）

| 端点 | 说明 |
|---|---|
| `GET /healthz` | 健康检查（免认证） |
| `GET /api/v1/devices` | 设备列表（逐个探活） |
| `POST /api/v1/exec` | `{"device_id","cmd","timeout_ms","workdir","stdin"}` → `{"exit_code","output","truncated","error","error_code","duration_ms"}` |
| `POST /api/v1/files/upload` | `{"device_id","path","data"(base64),"mode"}` → `{"ok","size"}` |
| `POST /api/v1/files/download` | `{"device_id","path"}` → `{"ok","size","data"(base64)}` |

- 认证：`Authorization: Bearer <api-key>`（`-api-key` 不传自动生成并打印）
- 设备寻址用 `device_id`，token 只存在于 clientd 的本地设备清单——Agent 永远不接触 token
- 调用方超时/断开会自动取消远端命令；连接失败回 `connection_lost`

CLI 文件传输：`client file-put -token T local.txt /etc/remote.txt`、`client file-get -token T /var/log/app.log ./app.log`

## 一条指令安装（二进制向导，推荐）

下载一个二进制向导，运行即进入交互式安装：**引导选择组件、端口、token（可自动生成或自定义）**，装完立即运行并开机自启：

```bash
# Linux（被控机 / 操作机通用，一条指令）
curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/main/bin/rtctl-wizard-linux-amd64 -o rtctl-wizard
chmod +x rtctl-wizard && sudo ./rtctl-wizard

# Windows（管理员 PowerShell，一条指令）
# irm https://raw.githubusercontent.com/GotKiCry/rtctl/main/bin/rtctl-wizard.exe -OutFile rtctl-wizard.exe
# .\rtctl-wizard.exe

# 非交互（脚本化）:
sudo ./rtctl-wizard --component agent --id jp-tokyo-01 --listen :8443 --gen-token
sudo ./rtctl-wizard --component clientd --devices devices.json --gen-api-key
./rtctl-wizard --component client      # 仅下载 client
./rtctl-wizard --component agent --id X --listen :8443 --token T --dry-run  # 只预览不安装
```

向导结尾会打印：验证命令、生成的 token / API 密钥、可复制的 clientd 设备清单片段。

脚本化部署（`deploy.sh` / `deploy.ps1`）仍可用，详见 [deploy/README.md](deploy/README.md)。

## 安全

- token 即设备钥匙；agent 对每条发起指令校验 token（分片/流消息按 ID/会话绑定）
- 生产建议 WSS（agent 支持 `-tls-cert/-tls-key`）；clientd 自带 API 密钥
- 默认拒绝跨源 Origin；低权限运行账户；文件临时写入 + 原子改名

完整协议与架构见 [DESIGN.md](DESIGN.md)，机器客户端契约（完成语义/错误码/重试幂等）见其第 6 节。

## 开源协议

[MIT License](LICENSE) © 2026 GotKiCry
