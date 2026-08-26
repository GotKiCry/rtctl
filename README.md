# rtctl — 远程终端控制工具（直连版）

> ⚠️ **安全警告（请先读）**
> - **token 就是钥匙**：谁拿到 token 谁就能控制这台服务器，别发群里、别写进代码仓库、别截图乱传。
> - **默认是明文连接**：不配置证书时，命令和 token 都在网络上明文传输，同一网络的人可以截获。公网/共享网络**务必**配置 `tls_cert` / `tls_key` 启用加密。
> - **启动日志会打印 token**：注意日志文件的可见范围，别把 agent 的日志发出去。
> - **agent 请用普通用户运行**（别用 root）；这会远程执行 Shell，等于把目标机器交给你，**只装在你可信的机器上**。

一句话：两个小工具。**agent 放在目标服务器上**，**rtctl 在你本机**，输一行命令就能远程执行 Shell 并拿回结果：

```bash
rtctl 192.168.1.5:8443 你的token 'uptime'
```

不需要中继服务器、不需要中心数据库、不需要装一大堆东西。就这两个二进制，Linux/Windows 都能跑。

## 三分钟上手

**目标服务器上（Linux / Windows 都行）：**

```bash
./rtctl-agent -init        # 第一次运行：自动生成配置文件 + 随机钥匙（token）
./rtctl-agent             # 之后直接启动，启动时会打印钥匙，抄下来就行
```

启动后你会看到类似：

```text
rtctl-agent 启动: id=node-01 listen=:8443 tls=false allow-sudo=false token=4a82...（配置: agent.conf）
```

**你自己电脑上（把 IP、token 换成上面的）：**

```bash
./rtctl 192.168.1.5:8443 4a82... 'uptime'                    # 执行一条命令
./rtctl 192.168.1.5:8443 4a82... 'df -h && free -m'          # 多命令拼一起也行
./rtctl 192.168.1.5:8443 4a82... 'ping -c 3 baidu.com'       # 有输出的都拿得回来
```

结果包含：**命令输出 + 退出码**。命令失败（比如退出码 42），rtctl 也会返回 42，方便脚本判断。

## 还能做什么

| 操作 | 命令 | 说明 |
|---|---|---|
| 执行命令 | `rtctl <IP>:<端口> <token> '命令'` | 最常用，支持超时、指定目录、输入 |
| 交互式终端 | `rtctl -server ws://IP:8443/ws shell -token <token>` | 像 SSH 一样进入终端，Linux 上可以跑 vim/top |
| 查看设备信息 | `rtctl -server ws://IP:8443/ws list` | 系统类型、架构、主机名、版本 |
| 传文件上去 | `rtctl -server ws://IP:8443/ws file-put -token <token> 本地文件 /远端/路径` | 大文件自动分段传，256MB 以内 |
| 把文件拉回来 | `rtctl -server ws://IP:8443/ws file-get -token <token> /远端/路径 本地文件` | 传完会校验，内容不一致会报错 |

一些更常用的写法：

```bash
# 执行带超时的命令（50 秒自动停止，并把命令连同子进程一起结束）
rtctl <IP>:<端口> <token> -c 'sleep 999' -timeout 50000

# 输出结构化 JSON，方便程序调用
rtctl -json -server ws://IP:8443/ws exec -token <token> -c 'uptime'
```

> `-timeout`、`-c` 这些参数是全局参数还是子命令参数，看下面的用法说明即可；最常用的第一种写法已经够用。

## agent 的配置文件（agent.conf）

第一次运行 `-init` 会自动生成，内容很简单：

```ini
listen = :8443          # 监听端口，0.0.0.0 上的 8443
id = node-01            # 给这台机器起个名字
token = 4a82...         # 连接钥匙，别人拿到就能控制这台机器
tls_cert =              # 两个都填上 = 启用加密连接（推荐外网使用）
tls_key =
allow_sudo = false      # 是否允许远程执行需要 root 权限的命令
```

配置和程序放同一个目录就行；也可以用 `-config` 指定别的路径。

## 需要管理员/root 权限的命令怎么办

agent 默认以**当前用户**的身份运行（所以尽量用普通用户跑，别用 root）。

- **Linux**：远程命令加 `-sudo`，配合三层确认：
  1. agent 要开了 `allow_sudo = true`；
  2. 本机执行时你会被当面询问"确定吗？"（脚本里用 `-confirm-sudo`）；
  3. 服务器上给 agent 用户配一条 sudo 免密规则（`NOPASSWD`，只放行需要的命令）。
  缺哪一层都直接报错（`sudo_disabled` / `sudo_denied`），**不会静默降级执行**。
- **Windows**：没有 sudo 这东西，agent 能拿到多少权限就是运行它的用户有多少权限（管理员运行 = 全局权限，普通用户运行 = 普通权限）。

## 安全提示（重要）

1. **token 就是钥匙**：谁拿到 token 谁就能控制这台服务器，别发群里、别写进代码/脚本提交到仓库。
2. 建议内网直连；跨公网时**务必**填上 `tls_cert` / `tls_key` 开启加密（否则命令和 token 是明文传输，同一网络的人能截获）。
3. agent.conf 权限已设为仅本人可读（0600）；启动日志会打印 token，注意日志别外传。
4. 远程 shell 能力 = 这台机器等同交给你：只在你自己可信的机器上部署。

## 自己构建

```powershell
pwsh ./build.ps1
# 生成 bin/ 目录下的 rtctl、rtctl-agent（Windows/Linux、x64/arm64 共 4 个），
# 以及 SHA256SUMS.txt 校验文件。需要本机装了 Go 1.25+。
```

详细协议说明（字段、错误码、边界行为）见 [DESIGN.md](DESIGN.md)。
