# rtctl

[最新版本](https://github.com/GotKiCry/rtctl/releases/latest) · [变更记录](CHANGELOG.md) · [开发说明](CONTRIBUTING.md) · [安全政策](SECURITY.md) · [MIT 许可证](LICENSE)

> **安全提示：rtctl 等同于远程 Shell。token 即设备全部权限；公网或共享网络必须启用 TLS。只应在可信设备上安装 agent。**

## 功能

- 远程命令执行，返回完整输出和退出码
- Linux 交互式终端，以及 Windows 命令会话
- 文件上传、下载和断连清理
- 可选 TLS、WebSocket 路径前缀、nginx/Caddy 反向代理
- Linux 一键安装及 systemd、OpenRC、nohup 服务托管
- agent 后台启动、PID 管理、日志轮转、日志着色与脱敏
- 安装脚本升级、健康检查和失败回滚

## 支持平台

| 平台 | 架构 | agent | client |
|---|---|---|---|
| Linux | amd64 / arm64 | 支持 | 支持 |
| Windows | amd64 | 支持 | 支持 |

## 快速开始

### 1. 在 Linux 目标设备安装 agent

系统级安装（推荐）：

```bash
curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh \
  -o /tmp/rt-install.sh
sudo sh /tmp/rt-install.sh
```

用户级安装（不需要 root）：

```bash
sh /tmp/rt-install.sh install --scope user
```

安装脚本会下载并校验对应架构的二进制，生成随机端口和 token，配置服务并执行健康检查。系统级安装创建专用 `rtctl` 用户；用户级安装使用当前用户。

防火墙仅在 root 或免密 `sudo` 可用时自动配置；其他环境不会修改防火墙，只检查端口是否可连通。

### 2. 获取连接信息

系统级安装：

```bash
sudo rt status
sudo rt token show --reveal
```

用户级安装无需 `sudo`：

```bash
rt status
rt token show --reveal
```

请通过安全渠道保存和传递 token，不要将其提交到仓库或贴入公开日志。

### 3. 在控制机下载 client

Linux amd64：

```bash
curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/rtctl-linux-amd64 \
  -o rtctl
chmod +x rtctl
```

其他平台从 [Releases](https://github.com/GotKiCry/rtctl/releases/latest) 下载对应资产。

### 4. 执行第一条命令

```bash
./rtctl 192.168.1.5:41234 '<token>' 'uptime'
```

Windows PowerShell：

```powershell
.\rtctl.exe 192.168.1.5:41234 '<token>' 'uptime'
```

命令输出和退出码会返回控制机，便于脚本判断执行结果。

## 常用操作

### client

```bash
# 查看设备信息
rtctl -server ws://192.168.1.5:41234/ws list

# 指定超时和工作目录
rtctl -server ws://192.168.1.5:41234/ws exec \
  -token '<token>' -timeout 50000 -workdir /tmp -c 'df -h'

# 交互式终端
rtctl -server ws://192.168.1.5:41234/ws shell -token '<token>'

# 上传和下载
rtctl -server ws://192.168.1.5:41234/ws file-put \
  -token '<token>' ./local.txt /tmp/remote.txt
rtctl -server ws://192.168.1.5:41234/ws file-get \
  -token '<token>' /tmp/remote.txt ./local.txt
```

自动化输出可添加 `-json`；完整参数使用 `rtctl -h` 查看。

### Linux 服务管理

```bash
sudo rt status                 # 服务、端口和版本
sudo rt logs -f                # 实时日志
sudo rt restart                # 重启并检查健康状态
sudo rt doctor                 # 安装与安全自检
sudo rt config edit            # 编辑配置（之后执行 rt restart）
sudo rt upgrade                # 升级，失败自动回滚
sudo rt uninstall              # 默认保留配置和 token
```

用户级安装使用相同子命令，但不加 `sudo`。运行 `rt help` 查看全部管理命令。

### 手工运行 agent

不使用安装脚本时：

```bash
./rtctl-agent -init            # 生成 ~/.rtctl/agent.conf 和随机 token
./rtctl-agent                  # 默认后台启动，监听就绪后返回
./rtctl-agent -status          # 查看状态
./rtctl-agent -logs -follow    # 跟随日志
./rtctl-agent -stop            # 停止后台实例
```

服务管理器托管时必须使用 `-foreground`。默认日志为 `~/.rtctl/agent.log`，每个约 10MB，保留 3 个轮转备份；`-logs` 查看时会脱敏，管道或重定向输出自动禁用颜色。

## 升级与旧版本覆盖

使用 `v1.0.0` 及后续版本时：

```bash
sudo rt upgrade --check
sudo rt upgrade
```

用户级安装执行 `rt upgrade`，无需 `sudo`。

从早期版本或误发的高版本覆盖到 `v1.0.0`，请使用最新 `install.sh` 重新安装，不要直接用旧版 `rt upgrade` 替换 agent。新版安装脚本会更新服务单元并保留既有配置和 token。

## TLS 与反向代理

默认连接为明文 `ws://`，公网或共享网络必须启用 TLS。

自动生成自签 CA 和服务器证书：

```bash
sudo rt install --tls-generate
```

client 默认使用系统信任库。自签 CA 可按安装输出导入控制机，也可在连接时通过 `-cafile` 指定；`-insecure` 会跳过证书校验，仅限调试使用。

也可以使用已有证书：

```bash
sudo rt config set tls_cert /etc/rtctl/tls/agent.crt
sudo rt config set tls_key /etc/rtctl/tls/agent.key
sudo rt restart
```

启用 TLS 后使用完整 `wss://` 地址：

```bash
rtctl -server wss://example.com/ws exec -token '<token>' -c 'uptime'

# 自签 CA 未导入系统信任库时
rtctl -server wss://example.com/ws -cafile ./rtctl-ca.crt \
  exec -token '<token>' -c 'uptime'
```

需要反向代理或路径前缀时：

```bash
sudo rt proxy nginx             # 也支持 rt proxy caddy
sudo rt config set ws_path /rt/ws
sudo rt restart
```

对应连接地址为 `wss://example.com/rt/ws`。

## 配置

系统级配置：`/etc/rtctl/agent.conf`；用户级及手工运行配置：`~/.rtctl/agent.conf`。

```ini
listen = :41234
id = web-01
token = <token>
tls_cert =
tls_key =
allow_sudo = false
ws_path = /ws
```

手工运行时查找顺序为：`-config` 指定路径、`~/.rtctl/agent.conf`、可执行文件同目录、当前目录。

## 从源码构建

需要 Go 1.25 或更高版本。

```bash
go test ./...
sh ./build.sh                 # Linux / macOS
pwsh ./build.ps1              # Windows PowerShell 7
```

构建产物写入已忽略的 `bin/`：6 个二进制、`install.sh` 和 `SHA256SUMS.txt`。

```bash
cd bin && sha256sum -c SHA256SUMS.txt
```

## 文档

- [架构与协议](docs/architecture.md)
- [变更记录](CHANGELOG.md)
- [开发说明](CONTRIBUTING.md)
- [安全政策与使用边界](SECURITY.md)

## 许可证

[MIT License](LICENSE)
