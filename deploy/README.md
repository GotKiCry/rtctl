# rtctl 一键部署

**只有一个入口**：Linux 用 `deploy.sh`，Windows 用 `deploy.ps1`。脚本会自动下载对应架构的预编译二进制（公开仓库无需任何准备，本地 `bin/` 存在时优先用本地），无需安装 Go。

## 三步部署

### ① 中心机：装中继服务器（一条命令）

```bash
# Linux（root）
curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.sh -o deploy.sh
bash deploy.sh server --port 8443 jp-tokyo-01 db-osaka-01 web-01
```

```powershell
# Windows（管理员 PowerShell）
irm https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.ps1 -OutFile deploy.ps1
.\deploy.ps1 -Mode Server -Port 8443 -Id jp-tokyo-01,db-osaka-01,web-01
```

脚本自动完成：下载 server 二进制 → 创建低权限运行用户 → 为每台设备**生成高熵 token**（Linux 存 `/etc/rtctl/tokens.txt`，Windows 存 `C:\Program Files\rtctl\tokens.txt`）→ 生成客户端密钥 → 注册开机自启服务 → 启动并健康检查。结尾会打印每台机器的 agent 安装命令，直接复制。

生产启用 WSS：`bash deploy.sh server --tls-cert /path/fullchain.pem --tls-key /path/privkey.pem <设备ID...>`

### ② 每台被控机：装 agent（复制脚本输出里的命令）

```bash
curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.sh -o deploy.sh
bash deploy.sh agent --server-url wss://中继:8443/ws?role=agent --id jp-tokyo-01 --token <该设备token>
```

```powershell
irm https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.ps1 -OutFile deploy.ps1
.\deploy.ps1 -Mode Agent -ServerUrl 'wss://中继:8443/ws?role=agent' -Id jp-tokyo-01 -Token '<该设备token>'
```

- 被控机**无需公网 IP、无需入站端口**（agent 主动拨出），NAT/防火墙后可用
- token 经环境变量/任务环境变量注入，不进命令行与进程参数
- Linux 默认以低权限用户 `rtctl-agent` 运行；需系统管理权限时加 `--user root`
- 断线自动重连；token/id 不匹配会立即退出并在日志写明原因（`journalctl -u rtctl-agent`）

### ③ 操作机：给 AI Agent 装常驻 HTTP 服务（clientd）

```bash
bash deploy.sh clientd --server-url wss://中继:8443/ws?role=client --client-key <客户端密钥> --devices devices.json
```

```powershell
.\deploy.ps1 -Mode Clientd -ServerUrl 'wss://中继:8443/ws?role=client' -ClientKey '<密钥>' -Devices '.\devices.json'
```

脚本自动：下载 client 二进制 → 拷贝设备清单（0600）→ 生成 API 密钥 → 注册开机自启服务 → 启动。之后 AI Agent 直接调 HTTP API，**无需手动复制指令或传输文件**：

```bash
curl -H 'Authorization: Bearer <API密钥>' \
  -d '{"device_id":"jp-tokyo-01","cmd":"uptime","timeout_ms":10000}' \
  http://127.0.0.1:18080/api/v1/exec
```

`devices.json` 里的 token 只存在于本机（0600），Agent 全程只使用 `device_id`。

### ④ 验证（也可用 CLI）

```bash
bash deploy.sh client
./bin/client-linux-amd64 -server wss://中继:8443/ws?role=client -key <客户端密钥> list
```

## 升级

```bash
bash deploy.sh update server|agent|client|clientd   # Linux
.\deploy.ps1 -Mode Update -Component server         # Windows
```

## 选项

| 选项 | 说明 |
|---|---|
| `--port / -Port` | 中继监听端口（默认 8443） |
| `--client-key / -ClientKey` | 客户端密钥（不填自动生成） |
| `--tls-cert --tls-key` | 启用 WSS |
| `--listen-ip` | 监听地址（默认 0.0.0.0） |
| `--user / -GhToken` 等 | 运行用户 / 私有仓库下载 token |
| 环境变量 `GH_BASE` | 二进制下载源（内网镜像/私有仓库） |

## 安全基线

| 项 | 脚本已做 |
|---|---|
| token 唯一且高熵 | ✔ 自动生成，仅存于 root/SYSTEM 可读文件 |
| 低权限运行账户 | ✔ agent 默认 rtctl-agent |
| 审计日志 0600 / 设备清单 0600 | ✔（Linux） |
| 跨源防护 | ✔ server 默认拒绝跨源 Origin |
| WSS/TLS | 传参启用（生产必开） |
| 占位 token 告警 | ✔ server 启动时对 change-me-* 告警 |

防火墙只需放行中继监听端口（默认 8443）。**注意**：重新运行 server 安装会重新生成全部 token，agent 需同步更换。
