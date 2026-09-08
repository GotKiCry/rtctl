# rtctl v3.3.0 — 一键安装版

远程终端控制工具（agent + client 双二进制，无中继、无中心服务器）。

## 本次更新

### 新增：Linux 一键安装与管理脚本 `install.sh`（安装后命令名 `rt`）

```bash
curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh -o /tmp/rt-install.sh \
  && sudo sh /tmp/rt-install.sh
```

- **自动下载 + SHA256 校验**，识别 amd64 / arm64
- **随机 5 位端口**：首次安装自动挑一个未被占用、避开常见端口的 5 位数端口（10000–65535），也可 `--port` 指定
- **专用运行用户 `rtctl`**（无登录 shell），配置落 `/etc/rtctl/agent.conf`（0600）
- **服务托管**：systemd（系统级 / 用户级）、OpenRC、无 init 的容器/WSL 三套后端自动探测
- **生命周期命令**：`rt install|init|start|stop|restart|status|logs|enable|disable|upgrade|uninstall|config|token|doctor|sudo|proxy|version|help`
- **升级安全**：停服务 → 同目录原子替换 → 启动 → `/healthz` 健康检查 → 失败自动回滚上一版
- **卸载**：默认保留配置与 token；`--purge` 彻底清除（含 token、运行用户、防火墙规则回滚）

### 新增：TLS 与反向代理支持

- `rt install --tls-generate`：生成自签 CA + 服务器证书，并打印控制机导入 CA 的命令
- 后续可 `rt config set tls_cert/tls_key` 手动配置证书
- **反向代理 / 路径前缀**：agent 新增 `-ws-path`（默认 `/ws`），`rt proxy nginx|caddy` 生成反代模板（含 WebSocket 升级头与长连接超时）
- 开 TLS 后控制端须用完整地址：`rtctl -server wss://host/rt/ws exec -token <token> -c '...'`

### 新增：两层特权（sudo）授权

agent 以普通用户 `rtctl` 运行，特权命令有两种授权方式：

- **永久授权**：`rt sudo enable` 写 `/etc/sudoers.d/rtctl-agent`（NOPASSWD，仅放行 `/bin/sh` 等）。⚠️ 之后任何持有 token 的人都能获得 root
- **临时授权**：执行时 `-sudo -sudo-ask`，当场输入 root 密码；agent 用 `sudo -S` 从 stdin 读取，不落盘、不进日志

三层审批仍然生效（agent `allow_sudo` + 客户端确认 + 服务器侧 sudoers/密码），缺哪层都明确报错，不静默降级。

### agent 变更

- 新增 `-version`（打印版本后退出）
- 新增 `-print-token=false`（启动块不打印完整 token，避免 token 进入 journald）
- 新增 `-ws-path`（WebSocket 路径，默认 `/ws`；路径前缀场景健康检查同步注册在 `<前缀>/healthz`）
- 配置文件新增 `ws_path` 字段
- 协议 `exec` 新增可选字段 `sudo_password`（临时提权用）

### client 变更

- 新增 `-version`
- 新增 `-sudo-ask`（交互提示输入 root 密码）与 `-sudo-password-stdin`（脚本调用）

### 构建与发布

- `build.ps1` / 新增 `build.sh`：注入版本号（`-ldflags -X`）、产出 `bin/install.sh`、`SHA256SUMS.txt` 改为 **LF 行尾**（修复 Linux 端 `sha256sum -c` 把 `\r` 当文件名的问题）
- 新增 `.gitattributes`：`*.sh` / `*.go` / `*.md` / `SHA256SUMS.txt` 强制 LF
- `push-release.ps1`：资产列表加入 `install.sh`，版本号参数化，并打印 `install.sh` 的 sha256 供 README 的 `--pinned-sha256` 引用

## 本版资产

| 文件 | 平台 | 用途 |
|---|---|---|
| `rtctl-linux-amd64` / `rtctl-linux-arm64` | Linux | 控制端 |
| `rtctl-agent-linux-amd64` / `rtctl-agent-linux-arm64` | Linux | 被控端 |
| `rtctl.exe` / `rtctl-agent.exe` | Windows | 同上 |
| `install.sh` | Linux | 一键安装/管理脚本（命令名 `rt`） |
| `SHA256SUMS.txt` | — | 校验值（LF 行尾） |

校验：

```bash
sha256sum -c SHA256SUMS.txt
```

> `install.sh` 与二进制来自同一个 release，只能发现传输损坏或镜像给错文件，**不能防「发布源本身被篡改」**。要锚定来源请用独立渠道公布的 `install.sh` sha256，或 `sh install.sh install --pinned-sha256 <hex>`。

## 安全提示

- token 即设备全部权限：别发群、别提交仓库、注意日志可见范围
- 公网/共享网络务必启用 TLS（`rt install --tls-generate` 或反向代理）
- 永久提权授权等于交出 root：优先用临时授权
- 本工具等于远程 Shell，只装可信机器
