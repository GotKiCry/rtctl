# rtctl — 远程终端控制工具（直连版）

> ⚠️ **安全警告（请先读）**
> - **token 就是钥匙**：谁拿到 token 谁就能控制这台服务器，别发群里、别写进代码仓库、别截图乱传。
> - **默认是明文连接**：不配置证书时，命令和 token 都在网络上明文传输。公网/共享网络**务必**启用 TLS（见「TLS 与反向代理」）。
> - **启动日志可能打印 token**：安装脚本已默认关闭该行为（`-print-token=false`），但手工启动 agent 时注意日志可见范围。
> - **agent 以普通用户 `rtctl` 运行**（别用 root）；本工具等于远程 Shell，**只装在你可信的机器上**。

一句话：两个小工具。**agent 放在目标服务器上**，**rtctl 在你本机**，输一行命令就能远程执行 Shell 并拿回结果：

```bash
rtctl 192.168.1.5:41234 你的token 'uptime'
```

不需要中继服务器、不需要中心数据库。就两个二进制，Linux/Windows 都能跑。

---

## 一键安装（Linux 目标服务器）

```bash
curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh -o /tmp/rt-install.sh \
  && sudo sh /tmp/rt-install.sh
```

安装脚本会依次：

1. 识别系统与架构（amd64 / arm64），校验二进制 SHA256；
2. 创建专用运行用户 **`rtctl`**（无登录 shell）；
3. **自动随机挑一个 5 位端口**（10000–65535，检测未被占用、避开常见端口），也可用 `--port 41234` 指定；
4. 生成设备 token（写入 `/etc/rtctl/agent.conf`，权限 0600）；
5. 安装并启动 systemd 服务（无 systemd 时自动回退 OpenRC / nohup）；
6. 放行防火墙端口；
7. 打印端口、token 与可直接粘贴的连接示例。

> 只想装控制端、或没有 sudo？用用户级安装：
> ```bash
> curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh -o /tmp/rt-install.sh \
>   && sh /tmp/rt-install.sh --scope user
> ```

### 安装后常用命令（管理脚本名就是 `rt`）

```bash
sudo rt status                 # 服务状态 / 端口 / 配置路径 / 版本
sudo rt token show --reveal    # 查看 token 与连接示例（默认只显示掩码与指纹）
sudo rt logs -f                # 实时日志
sudo rt config edit            # 编辑配置（改完 rt restart 生效）
sudo rt sudo enable            # 开启「永久提权授权」（见下）
sudo rt proxy nginx            # 生成 nginx 反向代理模板
sudo rt upgrade                # 升级到最新版（失败自动回滚）
sudo rt uninstall              # 卸载（默认保留配置与 token）
sudo rt uninstall --purge      # 彻底清除（含配置、token、运行用户）
sudo rt doctor                 # 自检：权限 / 端口 / TLS / 服务 / 配置
sudo rt help                   # 全部命令
```

---

## 三分钟上手

**目标服务器上**（如果没用上面的安装脚本，也可以手工跑）：

```bash
./rtctl-agent -init        # 第一次运行：生成 agent.conf + 随机 token
./rtctl-agent             # 之后直接启动，启动时会打印连接信息
```

启动后你会看到类似：

```text
rtctl-agent 启动 ✔  (id=web-01)
  监听地址 : :41234（ws，路径 /ws）
  本机地址 : 192.168.1.5:41234 / 127.0.0.1:41234
  防火墙   : 已放行 41234/tcp（ufw）
  设备 token: <已隐藏>（查看: rt token show）
  允许提权 : false
  配置文件 : /etc/rtctl/agent.conf
  连接示例 :
    rtctl 192.168.1.5:41234 <token> 'uptime'   # 从控制机执行
```

**你自己电脑上**（把 IP、端口、token 换成上面的）：

```bash
./rtctl 192.168.1.5:41234 4a82... 'uptime'              # 执行一条命令
./rtctl 192.168.1.5:41234 4a82... 'df -h && free -m'    # 多命令拼一起
./rtctl -version                                        # 查看版本
```

结果包含**命令输出 + 退出码**；命令失败（如退出码 42），rtctl 也返回 42，方便脚本判断。

---

## 还能做什么

| 操作 | 命令 |
|---|---|
| 执行命令 | `rtctl <IP>:<端口> <token> '命令'` |
| 交互式终端 | `rtctl -server ws://IP:端口/ws shell -token <token>` |
| 查看设备信息 | `rtctl -server ws://IP:端口/ws list` |
| 传文件上去 | `rtctl -server ws://IP:端口/ws file-put -token <token> 本地文件 /远端/路径` |
| 把文件拉回来 | `rtctl -server ws://IP:端口/ws file-get -token <token> /远端/路径 本地文件` |
| 结构化输出 | 加 `-json` |

```bash
# 带超时（50 秒后连子进程一起结束）
rtctl <IP>:<端口> <token> -c 'sleep 999' -timeout 50000
```

---

## TLS 与反向代理

默认不启用 TLS（内网直连够用；**公网务必启用**）。三种方式：

**1. 自签（脚本一把生成 CA + 服务器证书）**

```bash
sudo rt install --tls-generate
```

脚本会打印**控制机导入 CA** 的命令，照做即可（client 走系统信任库，不导入会报 `x509: certificate signed by unknown authority`）：

```bash
# Debian/Ubuntu 控制机
sudo cp rtctl-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
# RHEL 系控制机
sudo cp rtctl-ca.crt /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust
# Windows 控制机：把 rtctl-ca.crt 导入「受信任的根证书颁发机构」
```

**2. 自己的证书**

```bash
sudo rt config set tls_cert /etc/rtctl/tls/agent.crt
sudo rt config set tls_key  /etc/rtctl/tls/agent.key
sudo rt restart
```

**3. 反向代理（公网推荐：nginx/caddy 终止 TLS，agent 只监听回环）**

```bash
sudo rt proxy nginx      # 生成配置模板（caddy 用 rt proxy caddy）
```

nginx 要点（`proxy_read_timeout` 必须够大，否则长命令会被断）：

```nginx
location /rt/ {
    proxy_pass http://127.0.0.1:41234/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;
}
```

控制机连接（**开 TLS 后不能用快捷入口**，必须给完整地址）：

```bash
rtctl -server wss://example.com/rt/ws exec -token <token> -c 'uptime'
```

需要把 WebSocket 挂在子路径下（不经反代重写）时，让 agent 自己带路径：

```bash
sudo rt config set ws_path /rt/ws && sudo rt restart
```

---

## 特权命令（root）

agent 以普通用户 `rtctl` 运行，特权命令需要授权。**两种方式**：

| 方式 | 命令 | 特点 |
|---|---|---|
| **永久授权** | `sudo rt sudo enable` | 写 `/etc/sudoers.d/rtctl-agent`（NOPASSWD，仅放行 `/bin/sh` 等）。之后 `-sudo` 直接生效。⚠️ **任何持有 token 的人都能获得 root** |
| **临时授权** | 执行时加 `-sudo -sudo-ask` | 不写 sudoers，当场输入 root 密码；agent 用 `sudo -S` 使用，不落盘、不进日志 |

```bash
# 临时授权：当场输入 root 密码
rtctl -server ws://IP:端口/ws exec -token <token> -sudo -sudo-ask -c 'systemctl restart nginx'

# 永久授权已开启时：无需密码
rtctl -server ws://IP:端口/ws exec -token <token> -sudo -confirm-sudo -c 'systemctl restart nginx'

# 关闭永久授权
sudo rt sudo disable
```

三层审批仍然生效：agent 要开 `allow_sudo`（安装时 `--allow-sudo` 或 `rt config set allow_sudo true`）、客户端要显式 `-sudo` 并确认、服务器侧要有 sudoers 规则（永久授权）或密码（临时授权）。缺哪层都会明确报错（`sudo_disabled` / `sudo_denied`），**不会静默降级执行**。

---

## agent 的配置文件（agent.conf）

安装脚本写入 `/etc/rtctl/agent.conf`（0600，属主 `rtctl`）；手工运行时默认在 `~/.rtctl/agent.conf`：

```ini
listen = :41234         # 监听地址（脚本安装时随机生成）
id = web-01             # 设备名
token = 4a82...         # 连接钥匙
tls_cert =              # 两个都填 = 启用 WSS（推荐公网）
tls_key =
allow_sudo = false      # 是否允许特权命令
ws_path = /ws           # WebSocket 路径（反向代理/子路径场景可改）
```

查找顺序：`-config` 参数 → `~/.rtctl/agent.conf` → exe 同目录 → 当前目录。

---

## 安全提示

1. **token 就是钥匙**：走安全渠道分发，别进代码/仓库/群聊。`rt token show --reveal` 才显示完整值。
2. **公网务必 TLS**：`rt install --tls-generate` 或反向代理；否则命令与 token 明文传输。
3. **永久提权授权等于交出 root**：`rt sudo enable` 后，token 泄露 = root 泄露。优先用临时授权。
4. agent 只装在你可信的机器上；它等于远程 Shell。
5. 升级用 `rt upgrade`（自动校验、原子替换、健康检查失败自动回滚）。

---

## 自己构建

```bash
# Linux / macOS
sh ./build.sh                 # 产出 bin/ 下 6 个二进制 + install.sh + SHA256SUMS.txt

# Windows（PowerShell 7）
pwsh ./build.ps1
```

需要 Go 1.25+。产物：

| 文件 | 用途 |
|---|---|
| `rtctl-linux-amd64` / `rtctl-linux-arm64` | 控制端（Linux） |
| `rtctl-agent-linux-amd64` / `rtctl-agent-linux-arm64` | 被控端（Linux） |
| `rtctl.exe` / `rtctl-agent.exe` | Windows |
| `install.sh` | 一键安装/管理脚本（`rt`） |
| `SHA256SUMS.txt` | 校验值（LF 行尾，`sha256sum -c` 可用） |

详细协议说明见 [DESIGN.md](DESIGN.md)；安装脚本设计见 [docs/rtctl-install-script-plan.md](docs/rtctl-install-script-plan.md)。
