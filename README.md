# rtctl

[最新稳定版](https://github.com/GotKiCry/rtctl/releases/latest) · [所有发布版本](https://github.com/GotKiCry/rtctl/releases) · [变更记录](CHANGELOG.md) · [开发说明](CONTRIBUTING.md) · [安全政策](SECURITY.md) · [MIT 许可证](LICENSE)

> **rtctl 提供远程 Shell。持有 token 的人拥有 agent 账号的权限。公网或共享网络必须启用 TLS。**

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

运行引导脚本后，选择 `1 Release`（稳定版）或 `2 Dev`（测试版）。要使用下文的 `rt` 互动菜单，请选择 `Dev`。

在 Linux 上使用固定引导脚本安装。普通账号通过 `sudo` 启动引导时，agent 仍属于该普通账号。全新机器上直接以 root 登录安装，agent 属于 root。

```bash
curl -fSL --progress-bar https://raw.githubusercontent.com/GotKiCry/rtctl/Linux/bootstrap.sh \
  -o /tmp/rt-install.sh &&
sudo sh /tmp/rt-install.sh
```

引导脚本在 `/usr/local/bin/rt` 注册管理入口，普通账号也可直接运行脚本，在注册时按提示输入 sudo 密码。`rt` 和 `sudo rt` 管理同一用户服务，端口和 token 保存在该账号的 `~/.rtctl/agent.conf`。安装器将用户命令目录加入登录 PATH。

旧机器只有系统级安装时继续维护该服务。若旧用户服务与系统服务同时存在，引导脚本会提示冲突。先确认要保留的端口和 token。保留用户服务时，用 `sudo /usr/local/bin/rt uninstall --scope system` 移除旧系统服务，再运行引导脚本。默认卸载保留旧配置。

引导脚本会显示正在下载的地址、终端传输进度和完成字节数。从 `v1.0.2-dev.7` 起，安装器下载二进制时也显示这些信息。失败时会指出具体文件和下载工具的退出码。`--verbose` 可查看哈希和服务单元等细节。

目标机通过 HTTP 正向代理访问 GitHub 时，使用 `--proxy`。例如本机已运行端口为 7890 的代理：

```sh
sudo sh /tmp/rt-install.sh install --proxy http://127.0.0.1:7890
```

使用把 GitHub 原始链接拼在节点地址后面的下载加速服务时，将可信节点传给引导脚本的 `--github-prefix`。这也覆盖渠道查询和发布文件下载，仍可交互选择 Release 或 Dev：

```sh
sudo sh /tmp/rt-install.sh --github-prefix https://v4.gh-proxy.org/
```

若节点查询 Dev 版本列表时返回 403，可在上述命令末尾加 `install --release v1.0.2-dev.7`，选择 Dev 后直接下载指定版本。

防火墙检查为只读。安装完成、`rt connect` 和 `rt doctor` 会提示如何从控制机验证连接，并根据目标机的防火墙给出手工检查或放行指引。已有规则由系统防火墙管理器维护。`--no-firewall` 可跳过检查和提示，`--allow-from CIDR` 可在手工指引中指定来源网段。

### 2. 获取连接信息

安装完成后会显示地址、token 和客户端命令。用 `rt status` 查看完整 token，用 `rt connect` 重看连接命令。

```bash
rt connect
rt status
```

使用 `rt status --no-print-token` 获取可分享的状态输出。

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
sudo rt status                 # 服务、端口、版本和完整 token
sudo rt token reset            # 轮换 token
sudo rt logs -f                # 实时日志
sudo rt restart                # 重启并检查健康状态
sudo rt doctor                 # 安装与安全自检
sudo rt config edit            # 编辑配置（之后执行 rt restart）
sudo rt upgrade                # 升级，失败时尝试恢复并检查旧版本
sudo rt uninstall              # 默认保留配置和 token
```

在终端输入 `rt` 进入互动菜单，可查看状态和日志、切换渠道、检查更新、升级或卸载。选择 **8 修改配置** 可查看配置、修改端口或编辑配置文件。修改端口会保留绑定地址并重启服务，等价于 `rt config set port 9000 --restart`（将 9000 换成你的端口）。编辑文件后，可在同一菜单选择 **应用配置并重启**。

菜单分别显示管理脚本和 agent 二进制的版本。用 `rt status --no-print-token` 查看配置监听地址和实际监听地址。

从 `v1.0.2-dev.9` 起，`rt sudo enable` 允许非 root agent 申请 sudo，`rt sudo disable` 关闭申请。是否授权、是否要求密码取决于目标机已有的 sudo 策略。旧版写入的免密规则可由管理员用 visudo 检查。已经以 root 身份运行的 agent 直接使用现有权限。执行管理命令时在前面加 `sudo` 不会改变 agent 的账号。

### 手工运行 agent

不使用安装脚本时：

```bash
./rtctl-agent -init            # 生成 ~/.rtctl/agent.conf 和随机 token
./rtctl-agent                  # 默认后台启动，监听就绪后返回
./rtctl-agent -status          # 查看状态及设备 token（-print-token=false 隐藏）
./rtctl-agent -logs -follow    # 跟随日志
./rtctl-agent -stop            # 停止后台实例
```

服务管理器托管时必须使用 `-foreground`。默认日志为 `~/.rtctl/agent.log`，每个约 10MB，保留 3 个轮转备份；`-logs` 查看时会脱敏，管道或重定向输出自动禁用颜色。

## 升级与旧版本覆盖

覆盖安装和升级会在下载、校验通过后停止旧服务。升级失败后，只有恢复旧版 agent、重启并通过本机健康检查才会报告回滚成功。

### 测试 dev 版本

菜单中的「切换渠道」会保存选择，之后「检查更新」和「升级」都使用该渠道。命令行可用 `rt channel stable` 或 `rt channel dev` 设置，系统级安装使用 `sudo rt channel stable` 或 `sudo rt channel dev`。降级到早期版本时保留较新的管理脚本，方便在菜单内再次切换。

`--dev` 和 `--stable` 可为单次安装或升级指定渠道，`--release TAG` 可指定确切版本。尚未保存渠道时，`rt upgrade` 沿用已安装版本的渠道。

固定的安装入口提供 Release 和 Dev 两种选择，会下载并校验所选渠道的最新安装脚本。已安装旧版的设备可用以下方式检查并升级：

```bash
curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/Linux/bootstrap.sh \
  -o /tmp/rt-bootstrap.sh
sudo sh /tmp/rt-bootstrap.sh upgrade --check
sudo sh /tmp/rt-bootstrap.sh upgrade
```

引导脚本会在当前终端等待升级结果。非交互运行时，把 `--stable` 或 `--dev` 放在子命令前，例如 `sudo sh /tmp/rt-bootstrap.sh --dev upgrade`。升级当前账号的用户级安装时可运行 `sh /tmp/rt-bootstrap.sh upgrade --scope user`。系统级升级完成后用 `sudo rt version` 确认版本。

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
