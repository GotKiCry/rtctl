# rtctl 一键部署（纯直连版）

**两个入口任选**：二进制向导（交互式引导）或脚本（非交互）。

## 推荐：二进制向导（一条指令）

```bash
# Linux（被控机/操作机通用）
curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/main/bin/rtctl-wizard-linux-amd64 -o rtctl-wizard
chmod +x rtctl-wizard && sudo ./rtctl-wizard
```

```powershell
# Windows（管理员 PowerShell）
irm https://raw.githubusercontent.com/GotKiCry/rtctl/main/bin/rtctl-wizard.exe -OutFile rtctl-wizard.exe
.\rtctl-wizard.exe
```

向导引导：选组件（**agent 被控端 / clientd 控制服务 / client**）→ 设备 ID → 端口 → token（自动生成高熵或手动自定义）→ WSS 可选 → 装完立即运行 + 开机自启（Linux systemd / Windows 计划任务）→ 打印验证命令与可复制的 clientd 设备清单片段。

非交互（脚本化）与预览：

```bash
sudo ./rtctl-wizard --component agent --id jp-tokyo-01 --listen :8443 --gen-token
sudo ./rtctl-wizard --component clientd --devices devices.json --gen-api-key
./rtctl-wizard --component client
./rtctl-wizard --component agent --id X --listen :8443 --token T --dry-run   # 只预览不安装
```

## 脚本版

### ① 每台被控机：装 agent（自带监听，无需中继）

```bash
curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.sh -o deploy.sh
bash deploy.sh agent --listen :8443 --id jp-tokyo-01 --token <自定高熵token>
```

```powershell
irm https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.ps1 -OutFile deploy.ps1
.\deploy.ps1 -Mode Agent -Listen ':8443' -Id jp-tokyo-01 -Token '<token>'
```

脚本自动：下载二进制 → 低权限用户（Linux）→ 注册开机自启服务（token 经环境变量注入，不进命令行）→ 启动。防火墙放行监听端口。生产建议加 `--tls-cert/--tls-key` 开 WSS。

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

之后 AI Agent 直接调 HTTP API（API 密钥自动生成，开机自启）：

```bash
curl -H 'Authorization: Bearer <API密钥>' \
  -d '{"device_id":"jp-tokyo-01","cmd":"uptime","timeout_ms":10000}' \
  http://127.0.0.1:18080/api/v1/exec
```

### ③ 验证 / 升级

```bash
./client-linux-amd64 -server ws://jp服务器IP:8443/ws list              # CLI 直连验证
bash deploy.sh update agent|client|clientd                             # 升级
```

## 选项

| 选项 | 说明 |
|---|---|
| `agent --listen` | agent 监听地址（默认向导 :8443） |
| `agent --tls-cert --tls-key` | WSS |
| `clientd --listen / --api-key` | HTTP 监听地址 / API 密钥（默认自动生成） |
| 环境变量 `GH_BASE` | 二进制下载源（内网镜像/私有仓库） |

## 安全基线

| 项 | 已做 |
|---|---|
| token 高熵 | 向导自动生成 / 脚本自定（务必用高熵随机串） |
| 低权限运行账户 | Linux agent 默认 rtctl-agent、clientd 默认 rtctl |
| token 不进命令行 | 环境变量 / 任务环境变量注入 |
| 设备清单 0600 且归属服务账户 | Linux 安装器自动 chown |
| 跨源防护 | agent 默认拒绝跨源 Origin |
| WSS/TLS | 传参启用（生产必开） |
