# rtctl v1.0.0

远程终端控制工具：agent 部署在目标设备，client 在控制机使用；直连 WebSocket，无中继、无中心服务器。

## 核心功能

- 远程执行命令、交互式 Shell、文件上传与下载
- Linux amd64/arm64 与 Windows amd64 agent/client
- token 认证、可选 TLS、WebSocket 路径前缀及 nginx/Caddy 反向代理
- Linux 一键安装脚本 `install.sh`，安装后的管理命令为 `rt`
- systemd、OpenRC、nohup 服务托管，支持系统级和用户级安装
- `rt upgrade` 自动校验、原子替换、健康检查及失败回滚

## 后台运行与日志

- agent 默认后台启动，父进程确认监听成功后才返回；启动失败会带回错误
- `-foreground` 供调试及服务管理器托管，`-status` / `-stop` 管理本机实例
- PID 文件记录进程身份，端口占用时提供排查提示
- 自管理日志默认写入 `~/.rtctl/agent.log`，每个约 10MB，保留 3 个轮转备份
- `-logs` 支持尾部查看、`-follow` 跟随、事件着色和 token/私钥脱敏
- `rt logs` 在新版 agent 上自动使用内置日志查看器

## 安装与升级

推荐先下载再执行：

```bash
curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh -o /tmp/rt-install.sh \
  && sudo sh /tmp/rt-install.sh
```

用户级安装：

```bash
sh /tmp/rt-install.sh install --scope user
```

从已有 `rt` 的旧版本（包括误发的高版本）升级到本版：

```bash
sudo rt upgrade --release v1.0.0
```

用户级安装无需 sudo：

```bash
rt upgrade --release v1.0.0
```

没有 `rt` 的旧版本可直接使用新版 `install.sh` 覆盖安装；既有配置和 token 会保留。

防火墙仅在 root 或免密 sudo 可用时自动放行；其他环境不修改防火墙，只检查端口是否可连通。

## 发布资产

| 文件 | 用途 |
|---|---|
| `rtctl-linux-amd64` / `rtctl-linux-arm64` | Linux 控制端 |
| `rtctl-agent-linux-amd64` / `rtctl-agent-linux-arm64` | Linux 被控端 |
| `rtctl.exe` / `rtctl-agent.exe` | Windows 控制端与被控端 |
| `install.sh` | Linux 一键安装与管理脚本 |
| `SHA256SUMS.txt` | 全部资产的 SHA256 校验清单 |

```bash
sha256sum -c SHA256SUMS.txt
```

`install.sh` SHA256：

```text
24bd20cf4f3d7d0eb532d413381f4a6b20a5d827d32d150fd695539f515272cb
```

也可使用 `sh install.sh install --pinned-sha256 <上面的哈希>` 校验安装脚本本身。

## 安全提示

- token 即设备全部权限，请勿提交仓库或通过不安全渠道传播
- 公网或共享网络务必启用 TLS（`rt install --tls-generate` 或反向代理）
- 永久提权授权等于交出 root，优先使用临时授权
- 本工具等同于远程 Shell，只安装在可信设备上
