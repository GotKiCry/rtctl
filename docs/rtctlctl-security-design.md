# rtctlctl 安全与凭据模型设计（install.sh 专题）

> 范围：仓库根单一 `install.sh`（POSIX sh，兼安装器与常驻管理脚本，安装后名 `rtctlctl`）的安全设计。
> 只做设计，不写完整代码。所有结论均基于已读源码（`cmd/agent/main.go`、`internal/agent/{agent,standalone,shell_linux,shell_exec_linux}.go`、`cmd/client/main.go`、`cmd/agent/firewall_linux.go`、`internal/proto/proto.go`、`build.ps1`）与 git 历史中的旧安装器/`deploy.sh`。

## 0. 设计输入：代码级事实（这些事实决定了下面每一条对策）

| # | 已核实事实 | 对设计的影响 |
|---|---|---|
| F1 | token 只在 agent 启动时读入内存，`checkToken` 逐条消息比对 `a.Token` | 轮换必须 restart 才生效；无灰度/双 token；restart 会断开全部会话 |
| F2 | `-init` 遇已存在配置 `log.Fatalf`，且 `writeConfig` 用 `os.WriteFile(0600)` | 安装脚本必须先判存在性；以 root 跑出的 conf 属主是 root，必须 chown |
| F3 | `-init` 的 `MkdirAll(dir, 0700)` 只对不存在的目录生效，不修改已有目录权限 | 目录必须由脚本先建；顺序错 → rtctl 用户无法穿越 `/etc/rtctl` |
| F4 | agent 启动块与 `-init` 汇总块都把完整 token 打到 stdout | 必须 `-print-token=false`（启动块）+ 脚本重定向 `-init` 的 stdout |
| F5 | `cmd/client` 无任何 TLS 相关 flag，`websocket.DefaultDialer.Dial(url, nil)` 走系统信任库 | 自签证书默认不可用，必须在控制机导入 CA；脚本要写清这条 |
| F6 | 快捷入口 `rtctl host:port token cmd` 由 `normalizeServer` 强制补 `ws://` | 启用 TLS 后必须改用 `-server wss://host:port/ws exec -token ...`；连接示例要按 TLS 状态切换 |
| F7 | `auth` / `list` / `/healthz` 不需要 token | 8443 上存在**未认证信息泄露**（主机名/OS/架构/版本）；只能靠防火墙/监听地址收窄 |
| F8 | `handleExec` 把完整命令写入 stderr 日志（`exec 开始 ...: <cmd>`） | journald 会成为"命令里夹带的秘密"（`mysql -pXXX`、`Authorization: Bearer ...`）的落点 |
| F9 | `file_put` 先写 `<path>.rtctl-partial`（`O_CREATE|O_TRUNC`，跟随符号链接），再 `chmod` 到 `mode`（默认 0644）、`rename` | 敏感路径写入面 = rtctl 用户可写的一切；遗留 `.rtctl-partial` 是磁盘垃圾 |
| F10 | `shellExecArgs(sudo=true)` = `sudo -n -- /bin/sh -c <cmd>` | 任何能让它成功的 sudoers 规则都等价于「token 持有者 = root」 |
| F11 | 旧 agent（v3.2.0 及以前）不认识 `-print-token` / `-version` | unit 写死新 flag + 旧二进制 = 启动即 `flag provided but not defined` → crash loop |
| F12 | `bin/SHA256SUMS.txt` 实测 CRLF（6×CR / 6×LF） | Linux `sha256sum -c` 会把 `\r` 当成文件名 → 校验永远失败；脚本解析必须 `tr -d '\r'` |
| F13 | agent 以非 root 启动时会 `sudo -n` 尝试放行防火墙 | unit 固定 `-open-firewall=false`，把放行收敛到安装期一次性 root 操作 |

---

## 1. token 全生命周期

### 1.1 总览

| 环节 | 谁执行 | 位置 / 权限 | 泄露面 | 对策 |
|---|---|---|---|---|
| 生成 | agent 自身 `genToken()`（`crypto/rand` 32B → 64 hex），脚本**不自己造 token** | 直接落 `/etc/rtctl/agent.conf` | 生成瞬间的 stdout | `-init` 的 stdout 重定向到 `/dev/null`；脚本改为以 root 读 conf 取值；**绝不** `-token` 走 argv（`/proc/<pid>/cmdline` 全局可读） |
| 存储 | 脚本（system scope 以 root） | `/etc/rtctl/agent.conf` `0600 rtctl:rtctl`；目录 `0750 root:rtctl` | 备份/快照/镜像复制；同机其他用户 | 不用 EnvironmentFile（不进 `/proc/pid/environ`）、不写 unit（0644 全局可读）、不写 `install.env`（0644）；轮换备份同样 0600 |
| 读取 | `rtctlctl token show`（需 root） | 内存 → stdout | 终端回滚、重定向到文件、CI 日志 | 默认 masked + fingerprint；`--reveal` 必须 TTY；非 TTY 直接拒绝（exit 5），`--force` 才绕过并 stderr 告警 |
| 分发 | 人（`token show --reveal` 输出块） | 一次性终端输出 | 群聊/工单/截图/共享剪贴板 | 输出块带"勿贴群聊"警示；TLS 开启时输出 `wss://` 形式；控制端用 `read -r -s` 读入变量 |
| 轮换 | `rtctlctl token reset`（root） | 备份 → 新 token 写 conf → restart → 双探针验证 | 备份文件、回滚残留 | 备份 0600、`--purge` 一并清理；失败自动回滚；验证含「旧 token 必须 `bad_token`」 |
| 销毁 | `uninstall` / `uninstall --purge` | 默认保留 conf，`--purge` 用 `shred -u` | "卸载了以为钥匙没了" | 卸载末尾显式打印保留路径与销毁命令；`--purge` 连带删 `.bak-*` |

### 1.2 生成（install / upgrade）

1. **前置**：`install -d -m 0750 -o root -g rtctl /etc/rtctl`（必须在 `-init` 之前，见 F3）。
2. **判存在**：`[ -f /etc/rtctl/agent.conf ]` 为真 → **不调用 `-init`**（否则 `log.Fatalf`，见 F2），打印 `已保留既有 token（轮换请用 rtctlctl token reset）`，跳到第 5 步。
3. **生成**：`rtctl-agent -init -config /etc/rtctl/agent.conf -id "$id" -listen "$listen" [-allow-sudo] >/dev/null 2>>"$LOG"`。
   - stdout 必须重定向（F4）；stderr 进脚本日志（不含 token）。
   - 不传 `-token`：token 由 agent 自己生成（熵与格式单一来源）。
4. **收权**：`install -m 0600 -o rtctl -g rtctl /etc/rtctl/agent.conf`（root 跑出来的文件默认 `root:root`，不 chown 就是 crash loop）。
5. **取值**：`token="$(sed -n 's/^[[:space:]]*token[[:space:]]*=[[:space:]]*//p' /etc/rtctl/agent.conf | head -n1 | tr -d '\r')"`，校验 `^[0-9a-f]{64}$`（不匹配仅 WARN，允许自定义 token）。
6. **展示**：仅当 `[ -t 1 ]` 且未给 `--no-print-token` 时，打印一次完整 token + 连接示例；否则打印 masked + `请在本机终端执行 sudo rtctlctl token show --reveal`。

> 非 root 安装（user scope）：`rtctl-agent -init -config "$HOME/.rtctl/agent.conf"`，`~/.rtctl` 由 agent 自己建（0700），无需 chown；不创建 `rtctl` 用户、不碰 systemd 系统 unit。

### 1.3 读取与脱敏输出

`rtctlctl token show` 输出契约（固定，便于脚本消费）：

```
# 默认（masked，非 TTY 也允许）
token = 3f9a…c2e1
fingerprint = 1a2b3c4d        # sha256(token) 前 8 hex，可安全进工单/日志
length = 64 hex (32 字节熵)
来源 = /etc/rtctl/agent.conf (0600 rtctl:rtctl)
完整值: sudo rtctlctl token show --reveal   # 需交互终端
```

- `--reveal`：`[ -t 1 ]` 为假 → `exit 5`，stderr：`拒绝在非终端输出完整 token（如确需请加 --force，并确认输出不会进日志/CI）`；`--force` 时 stderr 追加一条醒目告警。
- `--json`：默认字段 `{masked, fingerprint, length, is_hex, source}`；**只有** `--reveal --json` 才出现 `token` 字段，并同时出现 `"warning":"完整 token 已输出"`。
- fingerprint 的用途：核对"手里这把钥匙是不是这台机器的"——可写进工单/群聊，不泄密。

### 1.4 分发

- 推荐渠道：密码管理器 / 端到端加密 IM / 一次性链接。输出块固定带一行：`⚠ token 即设备全部权限，勿贴群聊、工单、截图、CI 日志`。
- 控制端落地（`cmd/client` 没有 `RTCTL_TOKEN` 环境变量、也没有 `-token-file`，token 必然出现在 argv，见 §7-A3）：
  ```sh
  printf 'token: ' >&2; read -r -s T; printf '\n' >&2
  rtctl -server wss://TARGET:8443/ws exec -token "$T" -c 'uptime'; unset T
  ```
- TLS 开启时**不要**用快捷入口（F6）：快捷形式强制 `ws://`，会明文失败/明文裸奔。示例统一按状态切换：
  - 无 TLS：`rtctl TARGET:8443 <token> 'uptime'`
  - 有 TLS：`rtctl -server wss://TARGET:8443/ws exec -token <token> -c 'uptime'`

### 1.5 轮换（`token reset`）—— 原子步骤

| 步 | 动作 | 失败处理 |
|---|---|---|
| 0 | 前置：euid=0；unit 存在；conf 存在；二进制可执行 | `exit 3/4`，不改任何东西 |
| 1 | 备份：`cp -p agent.conf agent.conf.bak-$(date +%Y%m%dT%H%M%S)`，`chmod 0600`、`chown rtctl:rtctl` | 备份失败即中止 |
| 2 | 生成新 token：`openssl rand -hex 32`；无 openssl 用 `head -c 32 /dev/urandom \| od -An -tx1 \| tr -d ' \n'`；两者都无 → 中止（**不使用** `$RANDOM`/`date` 类低熵源） | 中止 |
| 3 | 写：同目录临时文件 `agent.conf.new.$$`（0600 rtctl:rtctl）→ `mv` 覆盖（原子替换，同目录） | 中止并删临时文件 |
| 4 | `systemctl restart rtctl-agent` | 回滚：恢复备份 → restart → 报错 `exit 7` |
| 5 | 双探针：`rtctl -server ws://127.0.0.1:$PORT/ws exec -token <新> -c true` 必须成功；同一形式用 `<旧>` 必须回 `bad_token` | 任一不符 → 回滚 + `exit 7` |
| 6 | 打印新 token（同 §1.3 的 `--reveal` 保护）+ 影响说明 | — |

**准确文案（必须原样进 `--help` 与输出）**：

> 旧 token 在 agent 进程重启完成之前**一直有效**——agent 只在启动时把 token 读进内存，改配置文件不影响正在运行的进程。
> `restart` 会断开当前全部 exec / shell / 文件传输；重启完成瞬间旧 token 失效，此后仅新 token 可用。
> 本工具没有双 token / 灰度机制，轮换是一次性切换，不能新旧并行。

`config set token <值>` **不存在**：写 token 的唯一入口是 `token reset`（避免两条路径、两套审计）。

### 1.6 销毁

| 场景 | 行为 |
|---|---|
| `uninstall`（默认） | 停用并删 unit、删二进制、按 `install.env` 撤销防火墙规则；**保留** `/etc/rtctl/agent.conf` 与 `install.env`（重装沿用同一把钥匙/同一设备 ID）。结尾必须打印：<br>`⚠ token 仍保留在 /etc/rtctl/agent.conf；彻底销毁：sudo rtctlctl uninstall --purge`<br>`仅销毁凭据：sudo shred -u /etc/rtctl/agent.conf`（无 `shred` 时 `rm -f`） |
| `uninstall --purge` | 顺序：停服务 → 撤销防火墙 → `shred -u` `agent.conf` **及全部 `agent.conf.bak-*`** → 删 `install.env`、`tls/`、`/var/log/rtctl` → `rmdir /etc/rtctl`（空才删）→ `userdel rtctl`（失败只提示不阻断，`userdel -r` 不用：home 是 `/nonexistent`） |
| 永不自动做 | 删除 `/etc/sudoers.d/rtctl-agent`。它不是本脚本创建的（见 §4），`--purge` 只打印提示：`如曾手工配置提权，请自行删除 /etc/sudoers.d/rtctl-agent` |
| 残留提示 | 若 `/etc` 曾被 etckeeper / 快照 / 镜像备份，`agent.conf` 可能已被复制到不受控位置 → 文档写明：**视为已泄露，轮换或销毁后重新生成** |

---

## 2. 权限矩阵

### 2.1 system scope（root 安装）

| 路径 | 权限 | 属主 | 为什么 |
|---|---|---|---|
| `/usr/local/bin/rtctl-agent` | 0755 | root:root | 可执行、不可被普通用户改写 |
| `/usr/local/bin/rtctl` | 0755 | root:root | 服务器侧自测/应急（`doctor` 探针用它） |
| `/usr/local/bin/rtctlctl` | 0755 | root:root | 管理脚本本体 |
| `/etc/rtctl/` | **0750** | **root:rtctl** | 其他用户不可列不可进；`rtctl` 组可穿越（agent 读 conf 必需）。见 §2.3 |
| `/etc/rtctl/agent.conf` | **0600** | **rtctl:rtctl** | token 唯一持久存储；属主必须是运行账户（F2 教训） |
| `/etc/rtctl/agent.conf.bak-*` | 0600 | rtctl:rtctl | 轮换备份仍是凭据；`--purge` 一并销毁 |
| `/etc/rtctl/install.env` | **0644** | **root:root** | 非敏感安装状态（见 §2.4）；**写前必须过 secret 扫描** |
| `/etc/rtctl/tls/` | 0750 | root:rtctl | TLS 材料目录 |
| `/etc/rtctl/tls/agent.crt` | 0644 | root:root | 公钥证书，公开无害 |
| `/etc/rtctl/tls/agent.key` | 0640 | root:rtctl | 私钥：仅 root 与运行账户可读 |
| `/etc/systemd/system/rtctl-agent.service` | 0644 | root:root | unit 全局可读 → **绝不放 token**（F4 反面） |
| `/etc/sudoers.d/rtctl-agent` | 0440 | root:root | **仅当用户手工创建时存在**；脚本只打印命令，不写（§4） |
| `/var/log/rtctl/` | 0750 | root:root | 脚本审计日志目录 |
| `/var/log/rtctl/install.log` | 0640 | root:root | 脚本操作审计（不含 token，argv 已脱敏） |
| 用户 `rtctl` | `useradd -r -M -d /nonexistent -s /usr/sbin/nologin` | — | 无 home（`file-put` 写不到 `~/.ssh/authorized_keys`）、无交互登录 |

### 2.2 user scope（非 root 安装）

| 路径 | 权限 | 属主 | 为什么 |
|---|---|---|---|
| `~/.local/bin/{rtctl-agent,rtctl,rtctlctl}` | 0755 | 用户 | 用户级安装 |
| `~/.rtctl/` | 0700 | 用户 | agent `-init` 自建；配置目录私有 |
| `~/.rtctl/agent.conf` | 0600 | 用户 | token 存储 |
| `~/.config/systemd/user/rtctl-agent.service` | 0644 | 用户 | user unit（`systemctl --user`） |
| `~/.local/state/rtctl/install.env` | 0644 | 用户 | 非敏感状态 |
| `~/.local/state/rtctl/install.log` | 0600 | 用户 | 审计日志 |

user scope 附加要求：开机自启需要 `loginctl enable-linger "$USER"`（需 root）→ 脚本**只打印**该命令；`doctor` 检查 linger 状态。

### 2.3 `/etc/rtctl` 0750 的平衡（本题重点）

- **不能 0700 root:root**：uid=rtctl 的 agent 连目录都进不去 → 读 conf 失败 → 崩溃循环。
- **不能 0755**：任何本地用户可枚举 `/etc/rtctl`（暴露 `agent.conf.bak-*`、`tls/` 等路径名），并在 `agent.conf` 权限被改坏时直接读到 token。0750 让"列目录"这一步就失败，是纵深防御。
- **为什么 conf 属主是 rtctl 而不是 root**：agent 必须能读；`0600 root:rtctl` 做不到（owner 优先于 group），`0640 root:rtctl` 也可以工作，但 0600 + owner=rtctl 让"谁能读"收敛到单一账户，且 `rtctlctl config edit` 以 root 编辑后必须重新 chown（§2.4 铁律 1）。
- **可选加固（不改默认决策）**：目录改 `0710 root:rtctl`（组可穿越、不可列目录），比 0750 更紧一档；代价是运维排障时 `ls /etc/rtctl` 需要 root。若要启用，`doctor` 的目录检查需接受 0750 与 0710 两种值。
- **不选 ACL 方案**：`setfacl -m u:rtctl:rx` 在 `ls -l` 里不可见、依赖 acl 支持，审计成本高于收益。

### 2.4 三条写文件铁律（脚本内强制，`doctor` 复核）

1. **凡写 `agent.conf` 必收尾**：`install -m 0600 -o rtctl -g rtctl` 或「同目录临时文件 + `chown` + `chmod` + `mv`」。涉及路径：`-init` 之后、`token reset`、`config set/edit`。
2. **目录先于 `-init`**：`install -d -m 0750 -o root -g rtctl /etc/rtctl`（F3：`MkdirAll` 不修正已有目录，但会以 0700 创建新目录）。
3. **公开文件写前扫密**：写 `install.env` 与写日志之前调用 `assert_no_secret`：命中 `[0-9a-f]{64}`、`BEGIN [A-Z ]*PRIVATE KEY`、`token[[:space:]]*[:=]` 即中止（`exit 1`）并打印命中行号。

### 2.5 `install.env` 字段（0644，禁止任何秘密）

```
RTCTLCTL_SCHEMA=1
SCOPE=system
INSTALLED_AT=2026-08-17T01:43:02Z
AGENT_VERSION=3.2.0
BIN_DIR=/usr/local/bin
CONF=/etc/rtctl/agent.conf
UNIT=/etc/systemd/system/rtctl-agent.service
LISTEN=:8443
PORT=8443
TLS_ENABLED=false
ALLOW_SUDO=false
PRINT_TOKEN_FLAG_SUPPORTED=true
FW_BACKEND=ufw
FW_ACTION=allow 8443/tcp
FW_UNDO=ufw delete allow 8443/tcp
BIN_SHA256_RTCTL_AGENT=<hex>
BIN_SHA256_RTCTL=<hex>
CTL_SHA256=<hex>
INSTALL_METHOD=verified-download
```

用途：幂等升级、卸载回滚防火墙、`doctor` 校验本地完整性。**不含** token、私钥、私钥路径。

---

## 3. 脚本自身的信任链

### 3.1 两条路径取舍

| 维度 | A. `curl -fsSL …/install.sh \| sh` | B. 下载 → 校验 → 执行（推荐） |
|---|---|---|
| 便利性 | 一行 | 两到三行 |
| 实际信任来源 | HTTPS + GitHub 账号/仓库本身 | 同上 **+ 出带公布的 sha256**（人类渠道） |
| 能防传输损坏/镜像错版 | ✅ | ✅ |
| 能防同源投毒 | ❌ | ❌（除非用出带哈希/签名） |
| 能防"本地已落地文件被换" | ❌ | ✅（校验后立即执行，且不落 `/tmp` 共享目录） |
| 适用 | 内网/一次性机器、能接受"信任 GitHub 账号" | **服务器/生产环境（README 首推）** |

**README 写法（照抄可用）**：

```bash
# 推荐：先下载再校验再执行（服务器/生产环境）
curl -fsSLO https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh
curl -fsSLO https://github.com/GotKiCry/rtctl/releases/latest/download/SHA256SUMS.txt
EXPECT=$(awk '/[ ]install\.sh$/{print $1}' SHA256SUMS.txt | tr -d '\r')
printf '%s  %s\n' "$EXPECT" install.sh | sha256sum -c -      # 必须 OK
sudo sh ./install.sh install

# 便利：一行自举（内网/临时机器；执行的就是远端返回的字节）
sh -c "$(curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh)"
```

**必须在 README 明写的事实（不许含糊）**：

> `SHA256SUMS.txt` 与 `install.sh` 来自同一个 release，**只能发现传输损坏或镜像给错文件，不能防"发布源本身被篡改"**。要真正锚定来源，请以**独立渠道公布的 install.sh sha256**（release 说明正文 / RELNOTES.md）为准，或用 `--pinned-sha256`。

### 3.2 `--pinned-sha256`

| 项 | 设计 |
|---|---|
| 语法 | `sh install.sh install --pinned-sha256 <64 hex>` |
| 时机 | 解析完参数后、做任何副作用（下载/写盘/改系统）之前 |
| 实现 | `[ -f "$0" ]` 且 `$0` 是常规文件 → 本地算 sha256 比对；`$0` 是管道/`/dev/fd/*`（`curl \| sh`）→ 直接 `exit 6` 并提示「管道执行无法自校验，请用下载后执行」 |
| 失败 | `exit 6`，stderr 打印期望值与实际值（哈希非秘密，可打印） |
| 环境变量替代 | 不提供。env 会被 `sudo` 的 `env_reset` 剥掉，行为不可预期（§4） |

### 3.3 二进制的下载与校验

1. 下载 `rtctl-agent-linux-<arch>`、`rtctl-linux-<arch>`、`SHA256SUMS.txt`（`curl` → `wget` 回退；`--base-url` 可覆盖，支持内网镜像）。
2. 校验：`sha256sum` → `shasum -a 256` → `openssl dgst -sha256` 三级回退；**三者皆无则拒绝继续**（`exit 4`），不做"跳过校验"的默认后门。
3. 解析清单时 `tr -d '\r'`（F12：现有 `SHA256SUMS.txt` 是 CRLF，不处理会让 `sha256sum -c` 报 `No such file or directory`）。
4. 校验通过后 `install -m 0755` 到**临时名**再 `mv` 到最终路径（避免覆盖运行中二进制触发 `text file busy`；`mv` 是 inode 替换，运行中的进程不受影响）。安装前先 `systemctl stop`（若已存在）。
5. 把实测 sha256 写进 `install.env`；`doctor` 复核"当前二进制 == 记录值"（**这只是本地篡改基线，不是信任锚**，文档要写清）。

### 3.4 发版时公布 install.sh 的 sha256

| 步骤 | 具体做法 |
|---|---|
| 1 | `build.ps1` 生成 `SHA256SUMS.txt` 改为 **LF**：`[IO.File]::WriteAllText($p, ($lines -join "`n") + "`n", [Text.Encoding]::ASCII)`（修 F12 的根因，而不是让每个消费者各自 `tr`） |
| 2 | release 资产清单加入 `install.sh`（与二进制同目录，`push-release.ps1` 一并上传） |
| 3 | `RELNOTES.md` 与 release 正文里单独贴一段：`install.sh sha256: <hex>`（人类渠道，独立于 SHA256SUMS.txt） |
| 4 | 每次改动 `install.sh` 必须重算并更新该行；发版检查表加一条「install.sh 哈希已更新」 |
| 5 | README 引用该哈希作为 `--pinned-sha256` 的示例来源 |
| 未来可选 | GitHub Actions 构建证明 / cosign 签名（v1 不做，避免复杂度） |

---

## 4. sudo 使用策略

### 4.1 哪些操作需要 root

| 操作 | 需要 root？ | 说明 |
|---|---|---|
| `install` / `upgrade`（system scope） | ✅ | 写 `/usr/local/bin`、`/etc`、`/etc/systemd/system`、`useradd`、`systemctl` |
| `uninstall [--purge]` | ✅ | 删系统文件、删用户、撤销防火墙 |
| `token show --reveal` / `token reset` | ✅ | 读/写 `0600 rtctl:rtctl` 的 `agent.conf`（root 绕过权限） |
| `config show`（masked）/ `config get <非 token 键>` | ✅（读 conf） | 同上；非 root 直接给 `sudo rtctlctl …` 提示 |
| `config set` / `config edit` | ✅ | 写 conf + 可能 `systemctl restart` |
| `doctor` | 部分 | 只读检查可非 root 跑（降级为 WARN）；读 conf/日志需 root，脚本自动降级而不是报错 |
| 防火墙放行/撤销 | ✅ | 安装期一次性，记进 `install.env` |
| user scope 安装 | ❌ | 全程用户身份；防火墙与 linger 只打印命令 |

### 4.2 提权模型（硬规则）

1. **脚本从不自己 `sudo` 提权**：`euid != 0` 且该操作需要 root → 打印 `需要 root：sudo rtctlctl <子命令>` 并 `exit 3`。
   - 理由：避免"半提权"状态（`HOME`/`PATH`/`umask` 已变但脚本以为自己是原用户）；避免在 cron/CI 里静默弹密码；让审计日志里的 `uid` 语义明确。
2. **`sudo -n` 只用于探测**（`sudo -n true >/dev/null 2>&1`），**绝不**用于写操作；**绝不**用 `sudo -S` 管道喂密码（密码会进 argv/管道，且掩盖失败）。
3. 所有外部命令用**绝对路径**，开头固定 `PATH=/usr/sbin:/usr/bin:/sbin:/bin`、`umask 077`。
4. 需要"真实用户"时用 `getent passwd "${SUDO_USER:-}"`，且仅用于提示与日志，不参与安全判断。

### 4.3 绝不自动写 sudoers（三条理由）

1. **失败代价不对称**：sudoers 语法错误会让**全系统** `sudo` 失效；安装器不该承担这个风险。
2. **收窄不了**：agent 的提权路径是 `sudo -n -- /bin/sh -c <cmd>`（F10）。任何能让它跑通的规则（`NOPASSWD: /bin/sh`）都等价于「**持有 token = 持有 root**」。脚本无法把它限制成"只允许某几条命令"。
3. **权限跃迁必须由人拍板**：它把「远程 shell as rtctl」静默升级为「远程 root」。

**替代：打印现成命令块（`install --allow-sudo` / `config set allow_sudo true` 时输出）**：

```bash
# ⚠ 执行后：任何持有本机 token 的人都能获得 root 权限。确认接受再执行。
sudo tee /etc/sudoers.d/rtctl-agent >/dev/null <<'EOF'
rtctl ALL=(ALL) NOPASSWD: /bin/sh, /usr/bin/sh, /usr/bin/kill, /bin/kill
EOF
sudo chown root:root /etc/sudoers.d/rtctl-agent
sudo chmod 0440 /etc/sudoers.d/rtctl-agent
sudo visudo -cf /etc/sudoers.d/rtctl-agent   # 必须输出 parsed OK
```

- 必须用 `sudo tee`（`>` 在重定向阶段以调用者身份建文件）；必须全路径；必须 `visudo -cf`。
- 在规则装好之前，`-sudo` 命令会返回 `sudo_denied`——脚本要提前说明，避免用户以为"开了 allow_sudo 就完事"。
- `doctor` 双向检查：`allow_sudo=false` 却存在该文件 → WARN「残留 root 通道」；`allow_sudo=true` → WARN「该规则等价 root」。

### 4.4 `env_reset` 剥离环境变量的处理写法

| 被剥离的东西 | 症状 | 脚本写法 |
|---|---|---|
| `RTCTL_*` | 脚本"读不到用户设的变量" | **一律不读任何环境变量作为输入**；全部走 flag / 配置文件 |
| `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` | `sudo rtctlctl install` 在代理网里下载失败 | 提供 `--proxy URL`（脚本显式 `export HTTPS_PROXY="$proxy"` 给子进程）；若 `${HTTPS_PROXY:-}` 仍存在则沿用并在日志记录"来自环境"；文档给逃生舱 `sudo -E rtctlctl install` 并注明「`-E` 会把整个环境（可能含秘密）带进 root 进程，仅限可信终端」 |
| `HOME` | `$HOME` 指向 `/root`，用户级路径写错位置 | 脚本不向 `$HOME` 写任何东西；system scope 全部绝对路径 |
| `PATH` | 可能少了 `/usr/sbin`，或带入用户 PATH（劫持风险） | 固定 `PATH`，外部命令全绝对路径 |
| `USER` / `LOGNAME` / `SUDO_USER` | 显示"root"而非真实用户 | 仅用于提示文案：`getent passwd "${SUDO_USER:-}"`，取不到就省略 |
| `EDITOR` | `config edit` 找不到编辑器 | 默认 `vi`；提示 `sudo EDITOR=nano rtctlctl config edit` |

---

## 5. 日志与输出脱敏

### 5.1 三条日志通道

| 通道 | 内容 | 风险 | 对策 |
|---|---|---|---|
| journald（agent） | 启动块（含 token，若未关）、每条 exec 的完整命令、file_put/get 路径 | token 永久留存；命令里夹带的密码/令牌留存 | unit 加 `-print-token=false`（能力探测通过才加，F11）；`doctor` 主动扫描；文档声明 journal 为敏感数据 |
| `/var/log/rtctl/install.log` | 脚本操作审计 | 脚本把秘密写进日志 | 格式固定 + argv 脱敏（§5.2） |
| TTY / stdout | 安装结果、`token show` | 终端回滚、重定向 | 默认 masked；`--reveal` 需 TTY（§1.3） |

### 5.2 脚本审计日志格式（0640 root:root）

```
2026-08-17T01:43:02Z uid=1000 euid=0 scope=system action=install result=ok listen=:8443 tls=false allow_sudo=false
2026-08-17T01:44:10Z uid=0 euid=0 scope=system action=token.show reveal=false result=ok
2026-08-17T01:45:00Z uid=0 euid=0 scope=system action=token.reset result=ok verify_new=ok verify_old=bad_token
```

- **不记录原始 argv**：只记录子命令路径 + 白名单参数（`reveal`、`scope`、`listen`、`tls`、`allow_sudo`）。
- 强制脱敏函数（写日志前必经）：任何匹配 `^[0-9a-f]{64}$`、`--token[= ]\S+`、`BEGIN [A-Z ]*PRIVATE KEY` 的片段替换为 `<redacted>`。
- 同时 `logger -t rtctlctl "$action result=$result"` 打一条 syslog（外部审计痕迹，防日志被改）。
- 日志轮转：不做自研轮转；依赖 distro logrotate（文档给出 `/etc/logrotate.d/rtctl` 示例，0644）。

### 5.3 `token show` 非 TTY 保护矩阵

| stdout | `--reveal` | 行为 |
|---|---|---|
| TTY | 否 | masked + fingerprint |
| TTY | 是 | 完整 token + 告警行 |
| 非 TTY（管道/文件/CI） | 否 | masked（可安全进日志） |
| 非 TTY | 是 | **拒绝**，`exit 5` |
| 非 TTY | 是 + `--force` | 输出完整 token，stderr 双行告警 |

### 5.4 `--json` 与 token

- `token show --json`：默认 `{masked, fingerprint, length, is_hex, source}`。
- `token show --reveal --json`：追加 `token` 与 `"warning"`。
- `config show --json`：token 键固定为 `"<redacted>"` + `fingerprint`。
- `config get token`：**直接拒绝**（`exit 5`，提示改用 `token show --reveal`）。全局不变量：**取完整 token 只有一条路径**，便于审计。

### 5.5 agent 日志里的命令（脚本能做到的边界）

`handleExec` 会打印完整命令（F8），所以 `journalctl -u rtctl-agent` 可能含 `mysql -pXXX`、`curl -H 'Authorization: Bearer …'` 之类的秘密。脚本**不能**改 agent 的日志行为，能做的是：

1. `doctor` 输出固定提示：`agent 日志包含完整命令文本，journald 应视为敏感数据`；
2. README 写明：限制 `systemd-journal` 组成员、不要把 journal 转发到不受控的日志平台；
3. `doctor` 附带检查 `/etc/systemd/journald.conf` 的 `Storage=`（`persistent` 时提醒留存周期）。

### 5.6 `-print-token=false` 的能力探测（防 F11 crash loop）

```sh
if /usr/local/bin/rtctl-agent -h 2>&1 | grep -q -- '-print-token'; then
  PRINT_TOKEN_FLAG_SUPPORTED=true; EXTRA_FLAG=' -print-token=false'
else
  PRINT_TOKEN_FLAG_SUPPORTED=false; EXTRA_FLAG=''   # 并在安装结尾打印醒目提示
fi
```

- 老二进制 + `-print-token=false` = 启动即失败 → 服务崩溃循环。**unit 必须按探测结果生成**。
- 不支持时，安装结尾必须警告：`当前 agent 版本启动时会在 journald 打印完整 token；建议升级到支持 -print-token 的版本，或执行 doctor 后按提示轮换`。
- `doctor` 复核：unit 含 `-print-token=false` 但二进制不支持 → FAIL。

---

## 6. systemd 服务加固与 agent 能力的兼容性结论

### 6.1 推荐组合（默认 unit）

```ini
[Unit]
Description=rtctl-agent remote terminal daemon
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=rtctl
Group=rtctl
SupplementaryGroups=            # 不继承 docker/adm 等附加组权限
ExecStart=/usr/local/bin/rtctl-agent -config /etc/rtctl/agent.conf -open-firewall=false -print-token=false
Restart=on-failure
RestartSec=2
TimeoutStopSec=10
KillMode=control-group          # 重启/停止时连远程命令的子进程一起收掉

# —— 能开的安全项 ——
NoNewPrivileges=yes             # allow_sudo=true 时必须改成 no（sudo 是 setuid）
PrivateTmp=yes                  # 注意 /tmp 语义变化，见坑位 7
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK   # NETLINK 供 ip/ss 排障
LimitCORE=0                     # 不产生 core dump（内存里有 token）

# —— 明确不开（会破坏功能）见 6.2 ——

[Install]
WantedBy=multi-user.target
```

`allow_sudo=true` 时唯一改动：`NoNewPrivileges=no`（并在 unit 里留注释说明原因），`doctor` 对此打 WARN。

### 6.2 逐条结论

| 指令 | 结论 | 理由（基于代码） |
|---|---|---|
| `NoNewPrivileges` | `allow_sudo=false` 时 **yes**；`=true` 时 **必须 no** | sudo 是 setuid 程序，NNP 会阻止提权；agent 自己已有 `no new privileges` 失败识别 |
| `PrivateTmp` | **yes** | agent 不在 `/tmp` 放配置；上传临时文件写在目标路径旁边。代价：`file-put /tmp/x` 落到服务私有 `/tmp`（同 namespace 内 `exec` 能读到，宿主机/重启后不可见） |
| `ProtectSystem` | **不开**（保持 no） | `strict`/`full` 会把 `/etc`、`/usr`、`/opt`、`/var` 变只读 → `file-put` 到系统路径、`shell` 里 `apt install`/`systemctl` 全废。用 `ReadWritePaths` 白名单对"远程 shell"没有意义 |
| `ProtectHome` | **不开** | 会隐藏 `/home`、`/root`、`/run/user` → `file-get`/`shell` 访问用户目录直接失败 |
| `PrivateDevices` | **不开** | 会让 `/dev` 变成精简集，PTY 可用但块设备/`/dev/net/tun` 等消失；远程 shell 的价值就是完整系统视图 |
| `ProtectKernelTunables` | **不开** | 挡 `/proc/sys`、`/sys` 写入 → `sysctl -w` 失败 |
| `ProtectKernelModules` | **不开** | 挡 `modprobe` |
| `ProtectControlGroups` | **不开** | 挡 `systemctl`/容器相关操作 |
| `ProtectKernelLogs` | **不开** | 挡 `dmesg`（排障刚需） |
| `ProtectClock` / `ProtectHostname` | **不开** | 挡 `date -s` / `hostnamectl` |
| `RestrictNamespaces` | **不开** | 挡 `unshare`、`docker`、`podman`、`ip netns` |
| `MemoryDenyWriteExecute` | **不开** | 作用于整个 service cgroup（含远程子进程）→ Java/Node/部分解释器直接崩 |
| `SystemCallFilter` | **不开**（可作为未来 `--harden-strict` 选项） | `@system-service` 仍可能挡 `strace`/`perf`/虚拟化等；默认开会制造"命令莫名失败"的支持成本 |
| `CapabilityBoundingSet` | **不设置** | agent 以非 root 运行本无特权，但 `allow_sudo=true` 时清空会限制 setuid 后获得的 capabilities → sudo 变残废 |
| `ProtectProc=invisible` | **不开** | `killProcessTree` 依赖遍历 `/proc/<pid>/stat`；`allow_sudo` 下 sudo 子进程为 root，会被隐藏 → 杀树漏杀 |
| `RestrictSUIDSGID` | **不开** | 会让 `file-put` 上传的 setuid 文件静默丢掉 SUID 位（"上传了却不生效"） |
| `UMask=0077` | **不设置** | 会改变远程命令创建文件的默认权限（`touch x` 变 0600），属静默行为变更 |
| `TasksMax` / `LimitNOFILE` | 不设限（默认） | 远程编译/服务操作可能触发限制 |
| `KillMode=control-group` | **显式写上** | 停止/重启时连同远程命令的子孙进程一起收掉，不留孤儿 |
| `SupplementaryGroups=` | **空** | 不继承任何附加组（避免意外获得 `docker`/`adm` 等） |
| `StateDirectory` / `RuntimeDirectory` | 不需要 | agent 无状态 |

### 6.3 user scope（systemd --user）

- unit 放 `~/.config/systemd/user/rtctl-agent.service`，`systemctl --user enable --now rtctl-agent`。
- 开机自启需 `loginctl enable-linger "$USER"`（root 操作）→ 脚本只打印。
- 加固项同上（`NoNewPrivileges`、`PrivateTmp`、`RestrictAddressFamilies` 在 user manager 下同样有效）；`LimitCORE=0` 同样建议保留。

---

## 7. 攻击面清单

| # | 攻击面 | 前提 | 影响 | 脚本侧缓解 | 残余风险 |
|---|---|---|---|---|---|
| A1 | 8443 端口暴露 | `listen` 非回环 | 全网可扫；无速率限制/锁定（`checkToken` 无节流） | 默认回环（推荐方案 A）；`--listen` 显式暴露；`--allow-from <CIDR>` 收窄防火墙源；`doctor` 对 `0.0.0.0/::` 打 WARN | 扫描噪声与指纹；暴露后需靠防火墙/安全组 |
| A2 | 未认证信息泄露 | 同上 | `auth`/`list`/`/healthz` 不需要 token（F7）→ 主机名、OS、架构、agent 版本 | 无（脚本改不了 agent） | 只能靠监听地址与防火墙收窄；文档明写"8443 可被指纹识别" |
| A3 | token 泄露（多路径） | — | 见下表 | 见下表 | 轮换是唯一补救 |
| A4 | 无 TLS 明文 | 未配 `tls_cert/tls_key` | 一条命令即可被动嗅探到 token（token 随每条发起消息发送）→ 后续全部权限 | 非回环 + 无 TLS 时要求显式 `--insecure-plaintext` 才继续；`doctor` 该项 FAIL；连接示例强制 `wss://`（F6） | 用户可用 `--insecure-plaintext` 强行关闭 |
| A5 | `file-put` 到敏感路径 | 持有 token | 以 rtctl 身份写任意可写路径；可用 crontab / systemd --user / 自启脚本**持久化** | 无（能力设计如此）：`rtctl` 用户无 home、无 nologin 登录；`/etc/rtctl` 0750 使 conf 不可被 agent 自己改写 | 持久化是远程 RCE 的固有属性 → 只有轮换 token + 卸载/重装可清除 |
| A6 | 远程 shell 固有风险 | 持有 token | 等于该用户（+ `allow_sudo` 时等于 root）；无 MFA、无按命令授权、无 IP 绑定 | 保持 `allow_sudo=false`；`--allow-from` 限源；TLS；journald 审计 + 轮换手册 | 单静态凭据模型无法消除 |
| A7 | sudoers 通道 | 手工配置了 NOPASSWD `/bin/sh` | token 持有者 = root（F10） | 不自动写；只打印命令并警告；`doctor` 检测并 WARN；卸载不删只提示 | 一旦配置，等价于全权 |
| A8 | 脚本自身信任链 | `curl \| sh` | 同源投毒可执行任意 root 代码 | 首推下载-校验-执行；`--pinned-sha256`；出带公布 install.sh 哈希；固定 PATH/绝对路径 | 无签名体系时仍依赖发布账号 |
| A9 | journald 泄露 | token 打印未关 / 命令含秘密 | 历史日志长期留存凭据 | `-print-token=false`（能力探测）；`doctor` 扫 journal 与 `install.env`；轮换建议 | 命令内容泄露由 agent 日志行为决定 |
| A10 | 本地提权/越权读 | 同机其他用户 | 若 conf 权限被改坏（如 chmod 0644），可直读 token | `doctor` 校验 `stat -c '%a %U:%G'`；目录 0750 纵深防御 | 用户手工 `chmod` 后需 doctor 才发现 |
| A11 | 控制端 argv 泄露 | token 走 argv（client 无 env/file 支持） | 控制机上 `ps` 可见（同机其他用户、审计工具） | 文档给 `read -r -s` 用法 + 专用账号建议 | 需改 client 才能根治（不在本专题范围） |
| A12 | `.rtctl-partial` 跟随符号链接 | 目标目录可被第三方写 | 第三方预置符号链接可让上传截断敏感文件 | `/etc/rtctl` 不可写；文档提示不要把 agent 可写目录开放给其他用户 | agent 用 `O_CREATE\|O_TRUNC`（无 `O_NOFOLLOW`），属 agent 侧问题 |

### 7.1 token 泄露路径细分

| 路径 | 触发 | 对策 |
|---|---|---|
| agent 启动块 → journald | 未加 `-print-token=false` | unit 加 flag（能力探测）+ `doctor` 扫 journal 命中即 FAIL 并建议 `token reset` |
| `ps` / `/proc/<pid>/cmdline` | 用 `-token` 起 agent | 脚本从不把 token 放 argv；unit 只传 `-config` |
| `/proc/<pid>/environ` | 用 `EnvironmentFile` 注入 | **不用** EnvironmentFile，token 只在 conf |
| unit 文件 | 用 `Environment=` 内联 | unit 不含 token（0644 全局可读） |
| `install.env` | 误写 | 0644 + 写前 `assert_no_secret` + `doctor` 扫 `[0-9a-f]{64}` |
| 轮换备份 | `agent.conf.bak-*` 遗留 | 0600 rtctl:rtctl；`--purge` 一并 `shred` |
| `/etc` 备份/快照/镜像 | etckeeper、VM 快照 | 文档：视为已泄露 → 轮换；`doctor` 列出 `/etc/rtctl` 全部文件与权限 |
| shell history | `rtctl … <token> …` | 文档：`HISTCONTROL=ignorespace` + 前导空格，或用 `read -r -s` 包装 |
| core dump | agent 崩溃 | `LimitCORE=0` |
| `file-get` 自身配置 | 持有 token 者可下载 `agent.conf` | 属固有（凭据持有者已全权）；提醒：token 一旦外流必须轮换而非仅删除本地文件 |

### 7.2 TLS 材料与客户端信任（必须写进 README 的约束）

- `cmd/client` 无 `-insecure` / `-cafile`（F5）→ **自签证书只有在控制机导入了签发 CA 之后才能用**：
  - Debian/Ubuntu：`/usr/local/share/ca-certificates/rtctl-ca.crt` + `update-ca-certificates`；
  - RHEL 系：`/etc/pki/ca-trust/source/anchors/` + `update-ca-trust`；
  - Windows 控制端：导入"受信任的根证书颁发机构"。
- 因此脚本的 TLS 路径优先级：① 用户提供的受信任证书（`--tls-cert/--tls-key`）→ ② Let's Encrypt/corp CA → ③ `--tls-generate`（自签，**必须**同时打印控制机导入 CA 的命令，并明确"未导入则连接报 x509 unknown authority"）。
- 安装时对 TLS 材料的检查：cert/key 存在且可读；`agent.key` 权限 0640 root:rtctl；`openssl x509 -noout -subject -enddate` 打印到期时间（`openssl` 缺失则跳过并 WARN）；`openssl x509 -noout -modulus | sha256` 与 `openssl rsa -noout -modulus | sha256` 比对（不匹配 → FAIL）。

---

## 8. 坑位与待拍板

### 8.1 坑位（触发条件 + 表现 + 对策）

| # | 触发条件 | 表现 | 对策 |
|---|---|---|---|
| P1 | root 先跑 `-init`，脚本没先建目录 | `/etc/rtctl` 被 `MkdirAll` 建成 `0700 root:root`；rtctl 用户无法穿越 | 必须先 `install -d -m 0750 -o root -g rtctl /etc/rtctl`；`doctor` 校验目录模式 |
| P2 | root 跑完 `-init` 直接启动 | agent 反复重启，journal 报 `读取配置失败 … permission denied`（conf 是 `root:root 0600`） | `-init` 后立即 `install -m 0600 -o rtctl -g rtctl`；`config set/edit` 后同样收尾 |
| P3 | 升级时脚本无条件调用 `-init` | `配置文件已存在: …` 直接 `log.Fatalf`；若被 `\|\| true` 吞掉则后续读到空配置/错 token | 先判 `[ -f ]`；存在即保留 token 并提示轮换入口 |
| P4 | 用 `set -euo pipefail` 写 POSIX sh | dash/busybox 报 `set: Illegal option -o pipefail` 直接退出；或 `grep` 无匹配在 `set -e` 下杀掉脚本（旧 `deploy.sh` 实测坑） | 只用 `set -eu`；**所有探测性管道加 `\|\| true`**；不用 `pipefail` |
| P5 | 用现有 `SHA256SUMS.txt` 校验（CRLF，F12） | `sha256sum -c` 报 `…: No such file or directory`，用户以为"下载坏了" | 脚本解析时 `tr -d '\r'`；同时修 `build.ps1` 用 LF 写清单（根治） |
| P6 | 直接 `cp` 覆盖运行中的二进制 | `Text file busy` 或安装中断 | 先 `systemctl stop`，`install -m 0755` 到临时名再 `mv` |
| P7 | 给老 agent 的 unit 写 `-print-token=false`（F11） | 服务启动即 `flag provided but not defined` → 崩溃循环 | `-h` 能力探测后再决定是否加；`doctor` 复核二者一致性 |
| P8 | 开了 `PrivateTmp=yes` 后 `file-put /tmp/x` | 宿主机 `ls /tmp` 看不到；重启后消失（同 namespace 内 `exec` 能读到，容易误判为"没传上去"） | 文档写明；需要宿主机可见时改用 `/var/tmp`、`/opt` 等路径 |
| P9 | 轮换时先写 conf 再 restart，restart 失败 | 服务起不来且旧 token 已丢 → 彻底失联（只能 SSH 上去救） | 备份 → 临时文件 + `mv` → restart → 双探针 → 失败自动回滚 |
| P10 | 以为 `uninstall` 就等于销毁凭据 | token 仍在 `/etc/rtctl/agent.conf`（备份/快照里可能还有） | 卸载末尾强制打印保留路径 + `--purge` 指引 |
| P11 | user scope 安装后没开 linger | 重启机器后服务不自启（用户没登录） | 打印 `loginctl enable-linger "$USER"`；`doctor` 检查 linger |
| P12 | iptables 后端放行 | 重启后规则消失（agent 的 `-I` 不进持久化文件） | `install.env` 记录后端；iptables 情况额外提示 `netfilter-persistent save`（存在时）或改用 ufw/firewalld；`doctor` 复检端口 |
| P13 | 改 `listen` 端口 | 防火墙仍放行旧端口，新端口不通 | `config set listen` 时提示防火墙需重放行并打印现成命令；`doctor` 比对 `install.env` 的 `PORT` 与 conf 的 `listen` |
| P14 | 在代理环境 `sudo rtctlctl install` | `env_reset` 剥掉 `HTTPS_PROXY` → 下载超时 | `--proxy` 显式传入；文档给 `sudo -E` 逃生舱（附风险提示） |

### 8.2 需要拍板的问题（3 条）

| # | 问题 | 选项 | 我的建议 |
|---|---|---|---|
| Q1 | 默认监听地址 | **A**：默认 `127.0.0.1:8443`（对外必须 `--listen`，安全默认、一行自举仍可用）<br>**B**：默认 `:8443`（对齐 agent 默认、开箱即用，但默认暴露） | **A**；配合「非回环 + 无 TLS → 必须 `--insecure-plaintext`」的硬闸 |
| Q2 | 无 TLS 的默认行为 | **A**：硬拒绝（必须显式 `--insecure-plaintext` 才继续）<br>**B**：仅 WARN 继续（`doctor` 打 FAIL） | **A**（配 `--tls-generate` 自签路径，并打印控制机导入 CA 的命令） |
| Q3 | `allow_sudo` 的安装期形态 | **A**：只设 `allow_sudo=true` 并打印 sudoers 命令（用户手工执行）<br>**B**：额外支持 `--print-sudoers <file>` 生成到文件供人工 `visudo -cf` 后安装 | **A + B 的 `--print-sudoers` 变体**：既不自动写，又降低手工抄写出错率 |

---

## 附录 A：命令面与退出码

| 子命令 | root | 关键参数 | 说明 |
|---|---|---|---|
| `install`（默认） | ✅（system） | `--scope`、`--listen`、`--allow-from`、`--tls-cert/--tls-key/--tls-generate`、`--allow-sudo`、`--insecure-plaintext`、`--base-url`、`--proxy`、`--pinned-sha256`、`--no-print-token`、`--id` | 幂等：已安装即升级（保留 token） |
| `token show` | ✅ | `--reveal`、`--force`、`--json` | §1.3 |
| `token reset` | ✅ | `--no-print-token` | §1.5 |
| `config show` / `get` / `set` / `edit` | ✅ | `--json` | token 键一律脱敏；`get token` 拒绝；`set` 白名单键，禁 `token` |
| `doctor` | 部分 | `--json`、`--fix`（v1 只报告不修） | §附录 B |
| `uninstall` | ✅ | `--purge`、`--keep-config` | §1.6 |
| `version` / `help` | ❌ | — | — |

| 退出码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 通用失败（含 secret 扫描命中） |
| 2 | 用法错误 |
| 3 | 需要 root（`sudo rtctlctl …`） |
| 4 | 前置条件不满足（非 Linux / 非 systemd / 缺校验工具 / 架构不支持 / 拒绝明文暴露） |
| 5 | 拒绝输出敏感内容（非 TTY） |
| 6 | 校验失败（pinned sha256 或二进制 sha256 不匹配） |
| 7 | 服务健康检查失败 |

## 附录 B：验收清单（每条可执行、可判定）

| # | 检查项 | 命令（root，system scope） | 期望 |
|---|---|---|---|
| 1 | 目录权限 | `stat -c '%a %U:%G' /etc/rtctl` | `750 root:rtctl` |
| 2 | 配置权限 | `stat -c '%a %U:%G' /etc/rtctl/agent.conf` | `600 rtctl:rtctl` |
| 3 | 状态文件 | `stat -c '%a %U:%G' /etc/rtctl/install.env` | `644 root:root` |
| 4 | 状态文件无秘密 | `grep -Eq '[0-9a-f]{64}' /etc/rtctl/install.env` | 退出码 1（无匹配） |
| 5 | 服务运行 | `systemctl is-active rtctl-agent` | `active` |
| 6 | unit 无 token | `grep -q 'print-token=false' /etc/systemd/system/rtctl-agent.service` | 匹配（且文件内无 64-hex） |
| 7 | journal 无 token | `journalctl -u rtctl-agent -o cat \| grep -cF "$(sed -n 's/^token *= *//p' /etc/rtctl/agent.conf)"` | `0` |
| 8 | 本地连通 | `rtctl -server ws://127.0.0.1:8443/ws exec -token "$T" -c true` | 退出码 0 |
| 9 | 错误 token 被拒 | 同上但用错 token | `bad_token` |
| 10 | 未认证信息面 | `printf '{"type":"list"}' \| websocat ws://…`（或用 `rtctl list`） | 能拿到主机名/版本（**已知**，见 A2） |
| 11 | 轮换原子性 | `rtctlctl token reset` 后重跑 #7/#8 | 新 token 通过、旧 token `bad_token`、无 `.bak` 权限偏差 |
| 12 | 卸载默认保留 | `rtctlctl uninstall` 后 `ls /etc/rtctl/agent.conf` | 存在，且输出含 `--purge` 提示 |
| 13 | `--purge` 销毁 | `rtctlctl uninstall --purge` 后 `ls /etc/rtctl`、`id rtctl` | 目录不存在/空；用户不存在 |
| 14 | 防火墙回滚 | 卸载后 `ufw status \| grep 8443`（或 firewalld/iptables 等价） | 无该端口规则 |
| 15 | 非 TTY 保护 | `sudo rtctlctl token show --reveal > /tmp/x` | 退出码 5，`/tmp/x` 不含 token |
| 16 | `doctor` 明文告警 | `rtctlctl doctor`（无 TLS + 非回环） | 该项 FAIL，退出码 2 |
