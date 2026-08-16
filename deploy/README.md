# rtctl 一键部署（纯直连版）

## 一条指令直达管理菜单（推荐，v2ray-agent 风格）

```bash
# Linux（root 执行；非 root 自动提权）
wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.sh" \
  && chmod 700 /root/deploy.sh && /root/deploy.sh
```

```powershell
# Windows（管理员 PowerShell）
irm https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.ps1 -OutFile deploy.ps1
.\deploy.ps1
```

无参数运行进入**循环管理菜单**：

```
  [1] 安装 agent（被控端）               ← 引导：设备ID → 端口 → token(自动生成/手动) → WSS
  [2] 安装 clientd（AI Agent 直控服务）   ← 引导：设备清单路径 → 监听地址 → API密钥
  [3] 查看状态（运行 + 开机自启）
  [4] 查看连接信息（复制 token / 设备清单片段 / 验证命令，无需 root）
  [5] 升级到最新版
  [6] 卸载组件
  [7] 退出
```

装完**立即后台运行 + 开机自启**（Linux systemd enabled / Windows 计划任务开机触发），结尾打印验证命令与可复制的 clientd 设备清单片段；之后 `bash deploy.sh info`（菜单选 4）随时重看。

## 二进制向导版（交互问答 + status/uninstall 子命令）

```bash
curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/main/bin/rtctl-wizard-linux-amd64 -o rtctl-wizard
chmod +x rtctl-wizard && ./rtctl-wizard      # Linux 非 root 自动提权
./rtctl-wizard status                        # 查看运行状态与开机自启
./rtctl-wizard info                          # 查看连接信息（ID/地址/token/可复制的设备清单片段）
./rtctl-wizard uninstall agent|clientd|all   # 卸载
```

## 脚本化（非交互）

```bash
bash deploy.sh agent --listen :8443 --id jp-tokyo-01 --token <token> [--allow-sudo]  # 被控机；--allow-sudo=允许特权命令（写 sudoers）
bash deploy.sh clientd --devices devices.json [--allow-sudo]                        # 操作机（AI Agent 入口）；--allow-sudo=开启特权转发闸
bash deploy.sh client / status / info / update agent|clientd / uninstall all
```

## 选项

| 选项 | 说明 |
|---|---|
| `agent --listen` | agent 监听地址（默认向导 :8443） |
| `agent --tls-cert --tls-key` | WSS |
| `agent --allow-sudo` | 允许特权命令：写 sudoers 最小放行（/bin/sh、/usr/bin/kill）+ NoNewPrivileges=false + `-allow-sudo`；默认关 |
| `clientd --listen / --api-key` | HTTP 监听地址 / API 密钥（默认自动生成） |
| `clientd --allow-sudo` | 特权转发闸：开才转发 sudo:true，否则 403 approval_required；默认关 |
| 环境变量 `GH_BASE` | 二进制下载源（内网镜像/私有仓库） |

## 安全基线

| 项 | 已做 |
|---|---|
| token 高熵 | 菜单/向导自动生成 / 脚本自定（务必用高熵随机串） |
| 低权限运行账户 | Linux agent 默认 rtctl-agent、clientd 默认 rtctl |
| token 不进命令行 | 环境变量 / 任务环境变量注入 |
| 设备清单 0600 且归属服务账户 | Linux 安装器自动 chown |
| 跨源防护 | agent 默认拒绝跨源 Origin |
| WSS/TLS | 传参启用（生产必开） |
| 特权命令默认拒绝 | 三道闸（被控端授权 / 控制端批准 / sudoers 放行）全部由人显式打开；卸载自动清 sudoers |
