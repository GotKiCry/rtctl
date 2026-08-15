# rtctl 一键部署

**只有一个入口**：Linux 用 `deploy.sh`，Windows 用 `deploy.ps1`。脚本会自动下载对应架构的预编译二进制（公开仓库无需任何准备，本地 `bin/` 存在时优先用本地），无需安装 Go。

## 部署（默认：直连，无中继）

目标服务器可以被访问时（有公网 IP / 同内网），**不需要 server 机**，只有两步：

### ① 每台被控机：装 agent（直连模式，自带监听）

```bash
curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.sh -o deploy.sh
bash deploy.sh agent --listen :8443 --id jp-tokyo-01 --token <自定的高熵token>
```

```powershell
irm https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.ps1 -OutFile deploy.ps1
.\deploy.ps1 -Mode Agent -Id jp-tokyo-01 -Token '<token>' -Listen ':8443'
```

脚本自动：下载 agent 二进制 → 建低权限用户 → 注册开机自启服务（token 经环境变量注入，不进命令行）→ 启动。防火墙放行监听端口（8443）。生产建议加 `--tls-cert/--tls-key` 开 WSS。

### ② 操作机：装 clientd（AI Agent 直控入口）

设备清单里给每台设备写 `url` 直连地址：

```json
{ "devices": [ { "id": "jp-tokyo-01", "url": "ws://jp服务器IP:8443/ws", "token": "<token>" } ] }
```

```bash
bash deploy.sh clientd --devices devices.json
```

```powershell
.\deploy.ps1 -Mode Clientd -Devices '.\devices.json'
```

之后 AI Agent 直接调 HTTP API（API 密钥自动生成，服务开机自启）：

```bash
curl -H 'Authorization: Bearer <API密钥>' \
  -d '{"device_id":"jp-tokyo-01","cmd":"uptime","timeout_ms":10000}' \
  http://127.0.0.1:18080/api/v1/exec
```

## NAT 场景（可选）：经中继

目标机在 NAT 后不可直连时，才需要中继：

```bash
# ① 中心机：中继 + 自动生成设备 token
bash deploy.sh server --port 8443 jp-tokyo-01 web-01

# ② 被控机：拨出模式（命令由 ① 的输出复制）
bash deploy.sh agent --server-url wss://中继:8443/ws?role=agent --id jp-tokyo-01 --token <token>

# ③ 操作机：clientd（设备清单不带 url，--server-url 指向中继）
bash deploy.sh clientd --server-url wss://中继:8443/ws?role=client --client-key <密钥> --devices devices.json
```

直连与中继可在同一份设备清单混用（带 url 直连、不带 url 经中继）。

## 验证（也可用 CLI）

```bash
./client-linux-amd64 -server ws://jp服务器IP:8443/ws list                      # 直连
./client-linux-amd64 -server wss://中继:8443/ws?role=client -key <密钥> list   # 中继
```

## 升级

```bash
bash deploy.sh update server|agent|client|clientd   # Linux
.\deploy.ps1 -Mode Update -Component server         # Windows
```

## 选项

| 选项 | 说明 |
|---|---|
| `agent --listen` | 直连模式监听地址（设置后无需中继） |
| `agent --server-url` | 中继模式服务器地址（与 --listen 二选一） |
| `agent --tls-cert --tls-key` | 直连模式 WSS |
| `server --port / --client-key / --tls-cert --tls-key` | 中继选项（token 自动生成） |
| `clientd --server-url --client-key` | 中继接入参数（纯直连可省略） |
| `clientd --listen / --api-key` | HTTP 监听地址 / API 密钥（默认自动生成） |
| 环境变量 `GH_BASE` | 二进制下载源（内网镜像/私有仓库） |

## 安全基线

| 项 | 脚本已做 |
|---|---|
| token 唯一且高熵 | ✔ 中继模式自动生成；直连模式自定（务必用高熵随机串） |
| 低权限运行账户 | ✔ agent 默认 rtctl-agent |
| token 不进命令行 | ✔ 环境变量/任务环境变量注入 |
| 审计日志 0600 / 清单 0600 | ✔（Linux） |
| 跨源防护 | ✔ agent 直连与 server 默认拒绝跨源 Origin |
| WSS/TLS | 传参启用（生产必开） |

**注意**：中继模式重跑 server 安装会重新生成全部 token，agent 需同步更换；直连模式 token 由你自定，重装 agent 时保持一致即可。
