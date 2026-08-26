# rtctl v3.2.0 — 精简直连版

远程终端控制工具（agent + client 双二进制，无中继、无中心服务器）。

## 本次更新

- **agent**：配置文件 `agent.conf` + `-init` 一键生成（自动生成随机 token 与安全警告）；启动即打印 token 与连接示例；移除 `-allow-any-origin`
- **client**：快捷入口 `rtctl <IP>:<端口> <token> '命令'` 一行直达；移除 serve（clientd）子命令
- **清理**：移除安装器/向导、deploy 脚本、设备清单等非核心组件（项目 45 文件精简至 22）
- **构建**：`build.ps1` 一键产出 4 平台静态二进制 + SHA256SUMS.txt（可按校验值核验）
- **文档**：README / DESIGN 中文通俗化重写，新增醒目安全警告；代码注释消除行话（原子改名→"先写临时文件再替换"等）
- 文件传输保留（分段传输、先写临时文件再替换正式文件、单文件 ≤256MB）
- 特权命令（sudo）保留三层审批（agent `allow_sudo` + 客户端确认 + sudoers 放行）

## 快速上手

```bash
# 1. 目标服务器（Linux / Windows 选对应文件）
./rtctl-agent -init          # 生成 agent.conf（含随机 token），按提示启动
./rtctl-agent                # 启动，日志会打印 token 与连接示例

# 2. 本机
./rtctl <目标IP>:8443 <token> 'uptime'      # 一行直达
./rtctl <目标IP>:8443 <token> 'df -h'       # 输出与退出码
```

## 本版资产

| 文件 | 平台 | 用途 |
|---|---|---|
| `rtctl-agent` | Linux amd64 / arm64 | 目标服务器被控端 |
| `rtctl-agent.exe` | Windows | 目标服务器被控端 |
| `rtctl` | Linux amd64 / arm64 | 本机控制端 |
| `rtctl.exe` | Windows | 本机控制端 |
| `SHA256SUMS.txt` | — | 以上文件校验值 |

下载后先校验证：
```bash
# Windows (PowerShell)
Get-FileHash rtctl-agent.exe -Algorithm SHA256   # 对比 SHA256SUMS.txt
# Linux/macOS
sha256sum -c SHA256SUMS.txt
```

## 安全提示

- token 即设备全部权限：别发群、别提交仓库、注意日志可见范围。
- 默认明文连接；公网/共享网络务必配置 `tls_cert` / `tls_key` 启用 WSS 加密。
- 建议普通用户运行 agent；本工具等于远程 Shell，只装可信机器。
