# rtctl Linux 一键安装/管理脚本 — 设计方案

> **状态：设计定稿，实施进行中。** 用户已拍板全部关键决策（见 0.1）。

---

## 0.1 最终决策（用户拍板，**覆盖下文旧表述**）

| # | 决策 | 说明 |
|---|---|---|
| 1 | 命令名 **`rt`**（remote terminal） | 系统级 `/usr/local/bin/rt`，用户级 `~/.local/bin/rt`；下文凡写 `rtctlctl` 均指此命令 |
| 2 | **端口自动随机** | 首次安装随机取 **5 位数端口**（10000–65535），三路探测未被占用并避开常见端口黑名单；`--port N` 可显式指定；只在首次生成，写入 `agent.conf` 后固定 |
| 3 | **TLS 默认关闭但可自动生成** | 默认明文继续（安装末尾 WARN + `doctor` FAIL）；`--tls-generate` 生成自签 CA+证书并打印控制机导入 CA 的命令；后续 `rt config set tls_cert/tls_key` 手动配置；**必须支持反向代理与路径前缀**——agent 新增 `-ws-path`（默认 `/ws`），脚本生成 nginx/caddy 反代模板 |
| 4 | 运行用户 **`rtctl`**；sudo **两层授权** | **脚本层**：`--sudo ask`（默认，当场输密码）/ `--sudo nopasswd`（写 `/etc/sudoers.d/rt-installer`）。**agent 层**：`rt sudo enable`（永久，写 `/etc/sudoers.d/rtctl-agent` NOPASSWD）/ `rt sudo disable` / `rt sudo status`；**临时授权** = 客户端 `-sudo -sudo-ask` 当场输 root 密码，agent 用 `sudo -S` 从 stdin 读，不落盘 |
| 5 | 自举 URL | `https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh`；发版资产必须含 `install.sh` |
| 6 | agent 新增 flag | `-version`、`-print-token=false`、`-ws-path`、`-open-firewall=false`；**全部能力探测**（`-h \| grep`）后才写进 unit |

> 实施状态：Go 侧改动（proto/agent/client）已完成；`install.sh`、`build.sh`、`build.ps1`、`push-release.ps1`、README 已落地。**本机未安装 Go**，Go 侧尚未编译验证。

---

## 0. 教研方式与产出

| 环节 | 参与 | 产出 |
|---|---|---|
| 并行设计 | 5 个专题组（脚本架构与命令面 / 分发校验与升级 / 交互引导与首次运行 / 系统集成与生命周期 / 安全与凭据） | 各自的决策、命令矩阵、文件布局、坑位 |
| 交叉评审 | 独立评审组逐份挑刺 | 6 条「已核实」的硬伤 + 边界冲突 + must_fix |
| 主代理拍板 | 复核代码事实、裁决冲突、定稿 | 本方案第 3 节 10 条核心决策 |

评审里 3 条硬伤由主代理在仓库中**亲自复核确认**（见 2.2），不是推测。

---

## 1. 需求拆解（用户原话 → 可验收项）

> 原话：Linux 脚本，用户只需从 README 执行一串 bash 即可自动下载，然后出现引导信息；后续开关、初始化、卸载、升级以及很多未实现的功能都通过这个脚本运行。

| 编号 | 需求 | 验收标准 |
|---|---|---|
| R1 | README 一行 bash 自举 | 干净的 Debian 12 / Rocky 9 / Alpine 3.19 上粘贴一行，无需预装 Go/Node/Python，能跑完 |
| R2 | 自动下载 | 自动识别 OS+arch，拉对应二进制与校验清单，SHA256 校验通过才落盘 |
| R3 | 引导信息 | 结束打印：服务状态、本机地址、token 查看方式、控制机可直接粘贴的连接示例、下一步命令 |
| R4 | 生命周期管理 | init/start/stop/restart/status/logs/enable/disable/upgrade/uninstall/config/token/doctor 全部可用且幂等 |
| R5 | 承载未实现功能 | 新增子命令 = 加一个函数 + 一行注册，解析器与帮助渲染不动 |

---

## 2. 硬约束（全部来自代码核实，不是猜的）

### 2.1 事实 → 强制影响

| 事实（出处） | 对脚本的强制影响 |
|---|---|
| `-init` 遇已存在配置直接 `log.Fatalf` 退出（`cmd/agent/main.go:241`） | init 必须脚本侧先判存在；重装/重置走「备份 → 生成新文件 → 原子替换」，绝不覆盖 |
| 配置查找顺序 `-config > ~/.rtctl/agent.conf > exe 同目录 > cwd`（`main.go:112-132`） | 系统级安装**必须**显式 `-config /etc/rtctl/agent.conf`，否则 agent 去找运行用户 HOME 下的配置 |
| 启动块把**完整 token** 打到 stdout（`main.go:213`） | 服务单元必须传 `-print-token=false`，否则 token 进 journald，`logs` 变成泄露通道 |
| `-open-firewall` 默认 true，非 root 走 `sudo -n`（`firewall_linux.go:77`） | 单元传 `-open-firewall=false`；放行由 install 一次性完成并记录，便于卸载回滚 |
| SIGINT/SIGTERM 优雅退出（`main.go:325`） | stop 交给服务管理器（默认 SIGTERM），脚本不自己 kill |
| 静态二进制、`CGO_ENABLED=0` | 不依赖 glibc 与发行版，脚本只需判 arch |
| `build.ps1:33` 用 `Set-Content` 写校验清单 | 实测 CRLF（6 个 CR，见 2.2）→ 解析必须去 `\r`，构建侧必须修 |
| 两个二进制都**没有** `-version`（`cmd/client/main.go` 只有 4 个 flag） | 版本一致性无法自证 → 需给两个二进制各加 `-version`（约 3 行） |
| v3.2.0 `RELNOTES.md:9`「移除安装器/向导、deploy 脚本」 | 规模必须受控：首版 16 个子命令、单文件、有行数预算 |
| **旧 agent（≤v3.2.0）不认识 `-print-token` / `-version`** | unit 写死新 flag + 旧二进制 = 启动即 `flag provided but not defined` → **崩溃循环**；新 flag 必须做成**可探测能力**（`-h \| grep`） |
| `cmd/client` **无任何 TLS flag**，`DefaultDialer` 走系统信任库 | 自签证书默认不可用 → README 必须把「控制机导入 CA」写成 TLS 前置步骤 |
| 快捷入口由 `normalizeServer` 强制补 `ws://` | 开 TLS 后必须改用 `-server wss://host:port/ws exec -token …`；连接示例要按 TLS 状态切换 |
| `auth` / `list` / `/healthz` **不需要 token** | 8443 存在未认证信息泄露（主机名/OS/架构/版本），只能靠监听地址与防火墙收窄 |
| `handleExec` 把**完整命令**写入 stderr 日志 | journald 成为「命令里夹带的秘密」的落点（`mysql -pXXX`、Bearer token） |
| `set -euo pipefail` 在 dash/busybox 上报 `Illegal option -o pipefail` | 脚本**只能用 `set -eu`**，探测性管道加 `\|\| true` |

### 2.2 主代理亲自复核的三条硬伤

1. **校验清单是 CRLF**：`bin/SHA256SUMS.txt` 实测 `bytes=512 CR=6 LF=6`。`awk '$2==f'` 永不命中 → 每次安装都会「校验失败」。**必须** `tr -d '\r'` 后解析，并修 `build.ps1` 与加 `.gitattributes`。
2. **脚本落盘 0644 装不起来**：若把脚本按 0644 落到 `lib/` 再软链，内核检查最终目标模式 → `Permission denied`。脚本本体必须 0755。
3. **`/etc/rtctl` 属主与运行用户冲突**：`-init` 对新建目录用 `MkdirAll(0700)`、对配置用 `WriteFile(0600)`，属主是执行者。若先由 root 跑 init 再以 `rtctl` 用户运行服务，目录进不去、配置读不到 → systemd 崩溃循环且只显示 exit 1。**必须**由 install 先建 `0750 root:rtctl` 目录、init 后 `chown` 配置。

---

## 3. 核心决策（13 条）

| # | 决策 | 为什么（第一性原理） |
|---|---|---|
| D1 | **单一脚本、双身份**：仓库根 `install.sh` 既是自举安装器，也是装好后的常驻管理脚本 `rtctlctl` | 脚本的分发单位就是一次 HTTP 抓取；一个可校验字节流才能保证安装原子性。拆多文件会让 README 那行串行抓 N 个文件，断网即半安装 |
| D2 | 管理命令名 **`rtctlctl`** | `rtctl` 已被控制端二进制占用，同名会遮蔽客户端；`rtctl-linux` 与 Release 资产 `rtctl-linux-amd64`（控制端）撞脸 |
| D3 | README 主推**先落盘再执行**，管道式为辅 | `curl \| sh` 时 stdin 就是脚本自身，任何 `read` 都在吞自己的源码；落盘后 `$0` 是普通文件，自举/自更新才有锚点 |
| D4 | **两态安装**：root 系统级 与 `--scope user` 用户级 | README 明确建议 agent 用普通用户跑；且大量机器没有 sudo |
| D5 | 系统级默认创建**专用系统用户 `rtctl`** 运行 agent | 既不违反「别用 root 跑 agent」，又比沿用 `SUDO_USER` 稳定（不依赖谁在调用） |
| D6 | 配置的**唯一写入者**是 `rtctl-agent -init`；脚本只读 + 备份 + 原子替换 | 复刻 INI 语义（首个 `=` 分割、仅整行 `#`/`;` 注释、`ParseBool`、重复 key 后者覆盖）成本高且易错，交给唯一权威实现 |
| D7 | 防火墙**唯一归属 install**（一次放行 + 记录），单元 `-open-firewall=false` | agent 每次启动放行会累积 iptables 重复规则、`firewall-cmd --reload` 重载整个防火墙、非 root 每次 `sudo -n` 失败刷日志 |
| D8 | 升级 = **停服务 → 同目录原子替换 → 启动 → 健康检查 → 失败回滚** | `cp` 覆盖运行中二进制会 `ETXTBSY`；跨文件系统 `mv` 退化为 copy+unlink 非原子；不重启则进程持旧 inode，版本自欺 |
| D9 | 首版**只保留 16 个子命令** + 扩展注册表；未实现功能用独立退出码 | v3.2.0 删过一版安装器；但「后续功能都能通过这个脚本运行」是硬需求，所以扩展点进架构，而不是靠堆命令名 |
| D10 | 校验锚点是 `SHA256SUMS.txt`（去 `\r` + awk 精确匹配），并**公布 install.sh 自身 sha256** | sums 与二进制同源同 TLS，只能防传输损坏；脚本自身是链上唯一无法自校验的一环，用「公布哈希 + 两段式安装」缓解 |
| D11 | 新 flag（`-print-token` / `-version`）必须**能力探测**后再写进 unit | 老二进制 + 新 unit = 崩溃循环；`rtctl-agent -h \| grep -- -print-token` 通过才加，否则省略并警告 |
| D12 | `token show` 默认 **masked + fingerprint**，`--reveal` 才输出完整值（非 TTY 拒绝） | 完整 token 只有一条取用路径，避免「随手重定向进日志/CI」成为默认行为 |
| D13 | 脚本**只用 `set -eu`**，绝不 `pipefail`；探测性管道一律 `\|\| true` | POSIX sh（dash/busybox）不支持 `pipefail`，直接报错退出；`grep` 无匹配在 `set -e` 下会杀脚本 |

---

## 4. 命令面

### 4.1 子命令矩阵

| 命令 | 作用 | root | 风险 | 幂等行为 |
|---|---|---|---|---|
| `install` | 下载 → 校验 → 落盘 → 建用户/目录 → init 配置 → 装单元 → 放行防火墙 → 启动 → 打印引导块 | 是 | 高 | 已装同版本同哈希：跳过替换，仍执行 enable+start+健康检查 |
| `init` | 调 `rtctl-agent -init -config <state>` 生成配置与 token | 视 scope | 中 | 配置已存在 → exit 8 并指向 `token reset` |
| `start` / `stop` / `restart` | 服务启停（走唯一 `svc_*` 实现） | 视 scope | 中 | 已处于目标状态即 no-op |
| `status` | 只读汇总：服务 active/enabled、监听端口与占用进程、配置路径与权限、脚本与二进制版本 | 否 | 低 | 纯只读 |
| `logs` | `journalctl -u rtctl-agent`（systemd）/ 日志文件（OpenRC、nohup）；`-f` 跟随 | 否 | 低 | 纯只读 |
| `enable` / `disable` | 开机自启开关（`systemctl enable/disable`、`rc-update add/del`） | 视 scope | 中 | 已启用/已禁用即 no-op |
| `upgrade` | `--check` 只查；默认升级：stop → 原子替换 → start → 健康检查 → 失败回滚 | 视 scope | 高 | 目标版本等于当前版本 → no-op |
| `uninstall` | stop → disable → 删单元 → 删二进制/软链 → 撤销防火墙规则；默认保留配置 | 是 | 高 | 缺失文件跳过，不报错 |
| `uninstall --purge` | 额外删 `agent.conf`（token）、`/etc/rtctl`、状态目录、专用用户 | 是 | 高 | 需 `--yes` 确认 |
| `config show\|get\|set\|edit` | 只读/修改 agent.conf 的 6 个 key；`set` 只写文件，`--restart` 才重启 | 视 scope | 中 | `set` 相同值 → no-op |
| `token show` | 默认 **masked + fingerprint**；`--reveal` 才输出完整 token（非 TTY 拒绝，需 `--force`） | 视 scope | 中 | 纯只读；`config get token` 一律被拒绝 |
| `token reset` | 备份旧配置 → 生成新配置 → 原子替换 → restart → **双探针**（新 token 通、旧 token 必须 `bad_token`） | 视 scope | 高 | 需 `--yes`；失败自动回滚 |
| `doctor` | 只读自检，ok/warn/fail 三级，有 fail → exit 10 | 否 | 低 | 纯只读 |
| `version` | 脚本/二进制/scope/state 版本；`--json` 供编排 | 否 | 低 | 纯只读 |
| `help` | 从注册表渲染命令、风险等级、计划中功能 | 否 | 低 | 纯只读 |

**全局选项**（子命令前后都接受）：`--prefix DIR`、`--scope system|user`、`--yes`、`--json`、`--quiet`、`--verbose`。

**透传选项**严格复用 agent 原拼写：`--listen`、`--id`、`--token`、`--tls-cert`、`--tls-key`、`--allow-sudo`、`--config`。
> ⚠️ Go flag 的 bool 必须写成一个 token：`-allow-sudo=false`；分开写会把 `false` 当位置参数、静默变成 true。
> ⚠️ 脚本**不读任何环境变量作为输入**（`sudo` 的 `env_reset` 会剥掉），一律走 flag 与配置文件。

### 4.2 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功（含「无变更」） |
| 1 | 通用失败（含 secret 扫描命中） |
| 2 | 用法错误 |
| 3 | 平台/架构不支持 |
| 4 | 下载失败 |
| 5 | 校验失败 |
| 6 | 权限不足（需要 root） |
| 7 | 服务操作失败 |
| 8 | 配置冲突/已存在 |
| 9 | 健康检查失败（已回滚） |
| 10 | 自检未通过（doctor） |
| 11 | 功能未实现（占位命令） |
| 12 | 拒绝在非终端输出敏感内容（`token show --reveal`） |
| 75 | 锁被占用（并发安装） |

---

## 5. 安装流程

### 5.1 README 给用户的一行（三种形态）

```bash
# 推荐：先落盘再执行（可先核验 install.sh 的 sha256 再运行）
curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh -o /tmp/rtctl-install.sh \
  && sudo sh /tmp/rtctl-install.sh

# 便捷一行（无交互，全默认值）
curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh | sudo sh -s -- install --yes

# 无 sudo 的机器：用户级安装
curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh -o /tmp/rtctl-install.sh \
  && sh /tmp/rtctl-install.sh --scope user
```

Alpine 无 curl 时用 `wget -qO /tmp/rtctl-install.sh <URL>`。README 同时给出 install.sh 自身 sha256，供两段式核验。

### 5.2 用户看到的过程

```text
$ sudo sh /tmp/rtctl-install.sh
rtctlctl v3.3.0 — rtctl agent 安装引导
  平台      : linux/amd64
  目标版本  : v3.3.0 (latest)
  安装模式  : system（需要 root，已确认）

  监听端口 [8443]:
  设备 ID  [web-01]:
  现在启动并设为开机自启? [Y/n]:

[1/8] 检查环境与工具链 ... ok
[2/8] 解析版本 ... v3.3.0
[3/8] 下载二进制与校验清单 ... ok
[4/8] 校验 SHA256 ... ok
[5/8] 安装二进制与脚本 ... ok
[6/8] 创建运行用户与配置 ... ok
[7/8] 安装服务单元 ... ok
[8/8] 放行防火墙 8443/tcp 并启动 ... ok

── 下一步 ───────────────────────────────────────────
服务状态 : active (enabled)，监听 :8443
本机地址 : 10.0.0.5:8443 / 127.0.0.1:8443
设备 token: <64 位>                查看: sudo rtctlctl token show
控制机上执行:
  curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/rtctl-linux-amd64 -o rtctl && chmod +x rtctl
  ./rtctl 10.0.0.5:8443 <token> 'uptime'
本机自检 : rtctlctl doctor      实时日志 : rtctlctl logs -f
改配置   : rtctlctl config edit  卸载     : rtctlctl uninstall
⚠ 公网使用务必配 tls_cert/tls_key（当前为明文 ws）
─────────────────────────────────────────────────────
```

同一块内容由 `rtctlctl connect` 随时重放；`--quiet` 只保留「控制机上执行」两行。

### 5.3 脚本视角的 8 步（每步失败都有退出码与「下一步命令」）

1. **环境预检**：`uname -s` 必须是 Linux；arch → amd64/arm64（其他 exit 3 + 交叉编译指引）；探测 curl/wget、sha256sum、`[ -d /run/systemd/system ]`；检查 `/usr/local/bin` 可写且非 noexec；`df -k` 空间 ≥ 3× 单文件；root 判定（非 root 且无 `sudo -n` → exit 6 并给 `--scope user` 一行命令）。
2. **解析版本**：`--version` / `RTCTL_VERSION` 优先；否则解析 `releases/latest` 的 302 重定向取 tag（**不调 API**，避免 60 次/小时限流），并用 `^v[0-9]+\.[0-9]+\.[0-9]+$` 白名单卡住结果。
3. **下载**：curl → wget 回退，落 `<state>/dl.<pid>/`（0700），校验失败即删并重下一次。
4. **校验**：先 `od` 验 ELF magic（防下到 HTML 错误页/错架构），再 `tr -d '\r' < SHA256SUMS.txt | awk -v f=<asset> '$2==f{print $1}'` 精确取期望值（不用 `grep`——`rtctl` 是 `rtctl-agent` 的子串；不用 `sha256sum -c`——清单含本机不存在的文件会整体报错）。期望值为空 → exit 5，**禁止静默跳过校验**。
5. **停旧服务**（若已装）：`svc_stop` 并轮询确认退出，不做 `kill -9`。
6. **原子替换**：同目录 `mktemp` → chmod 0755 / chown → `mv -f`；旧文件先存 `.prev` 供回滚。脚本自身同样原子替换（POSIX sh 已把脚本读入内存，替换正在执行的文件不影响本次运行）。
7. **配置与服务**：`/etc/rtctl` 建为 0750 root:rtctl → 不存在配置时以 root 显式 `-init -config /etc/rtctl/agent.conf` → `chown rtctl:rtctl` + `chmod 0600` → 渲染并安装单元 → 防火墙放行一次并记录到状态文件。
8. **启动 + 健康检查 + 引导**：`svc_start` → 等 active 且端口可连（`ss` / `netstat` / `/proc/net/tcp` 三路回退）→ 写状态文件 → 打印引导块。

---

## 6. 目录与文件布局

| 路径 | 权限 | 属主 | 说明 |
|---|---|---|---|
| `install.sh`（仓库根） | 0644 | — | 唯一分发文件，同时是安装后脚本的来源 |
| **系统级（root）** | | | |
| `/usr/local/bin/rtctlctl` | 0755 | root:root | 管理脚本本体（**必须 0755**，否则软链不可执行） |
| `/usr/local/bin/rtctl-agent` | 0755 | root:root | agent 二进制 |
| `/usr/local/bin/rtctl-agent.prev` | 0755 | root:root | 上一版本，保留 1 份供回滚 |
| `/etc/rtctl/` | 0750 | root:rtctl | 配置目录（**不能是 0700 root:root**，否则运行用户进不去） |
| `/etc/rtctl/agent.conf` | 0600 | rtctl:rtctl | agent 配置（含 token） |
| `/etc/rtctl/agent.conf.bak.<ts>` | 0600 | rtctl:rtctl | token reset / 升级前备份 |
| `/etc/rtctl/install.env` | 0644 | root:root | 状态文件（唯一事实源） |
| `/var/lib/rtctl/` | 0755 | root:root | 状态目录（锁、下载暂存、日志） |
| `/var/lib/rtctl/rtctlctl.log` | 0600 | root:root | 脚本操作日志（argv 中 64 位 hex 脱敏为 `<redacted>`） |
| `/etc/systemd/system/rtctl-agent.service` | 0644 | root:root | 服务单元 |
| **用户级（--scope user）** | | | |
| `~/.local/bin/rtctlctl` | 0755 | 用户 | 管理脚本 |
| `~/.local/bin/rtctl-agent` | 0755 | 用户 | agent 二进制 |
| `~/.rtctl/agent.conf` | 0600 | 用户 | 复用 agent 原生默认路径（**不传 `-config`**） |
| `~/.local/state/rtctl/install.env` | 0644 | 用户 | 状态文件 |
| `~/.config/systemd/user/rtctl-agent.service` | 0644 | 用户 | 用户级单元（需 `loginctl enable-linger`） |

**状态文件字段**（原子写：`mktemp` → 写 → `mv -f`，任何中断都不留半截文件；**永不含 token 明文**，只存 `TOKEN_FP` = token 的 sha256 前 12 位）：

`RTCTLCTL_VERSION`、`SCOPE`、`INIT`（systemd|openrc|nohup）、`UNIT`、`BIN_AGENT`、`BIN_CLIENT`、`CONF`、`STATE_DIR`、`RUN_USER`、`RUN_GROUP`、`LISTEN`、`PORT`、`LOG_SOURCE`、`LOG_FILE`、`PID_FILE`、`FW_BACKEND`、`FW_RULE`、`FW_APPLIED`、`FW_REMOVABLE`、`AUTOSTART`、`AGENT_VERSION`、`BINARY_SHA256`、`TOKEN_FP`、`INSTALLED_AT`、`UPGRADED_AT`、`LAST_UPGRADE_RESULT`（ok|rolled_back|rollback_failed）、`ROLLBACK_AT`、`ROLLBACK_FROM_VERSION`、`LAST_ERROR`、`TAKEOVER_FROM`、`PREV_BINARY`。

- 字段名**不加 `RTCTL_` 前缀**：状态文件只由解析函数按 key 读取，**绝不 `source`**——否则会把变量注入环境，与 agent 自身的 `RTCTL_ID`/`RTCTL_TOKEN` 撞名，导致 `-init` 生成出非预期的 token。
- 每个子命令入口先 `load_state`；缺失时提示「未检测到安装，请先执行 rtctlctl install」并 exit 8。

---

## 7. 服务集成（「系统集成与生命周期」组定稿）

### 7.1 后端探测（不能只看 `command -v systemctl`）

| 后端 | 判据 |
|---|---|
| systemd | `[ -d /run/systemd/system ]` **且** `/proc/1/comm` 为 `systemd` **且** `systemctl is-system-running` 有输出 |
| OpenRC | 存在 `/sbin/openrc` 或 `rc-service`，且有 `/etc/init.d` 与 `/run/openrc`（或 `/sbin/rc-update`） |
| nohup | 以上皆否（容器 / WSL 未开 systemd） |

必须拦住的反例：Debian 容器里装了 systemd 包 → `command -v systemctl` 成功，但操作报 `System has not been booted with systemd as init system (PID 1)`。`RTCTLCTL_INIT=systemd|openrc|nohup` 可强制覆盖（CI 用）。

### 7.2 系统级单元（完整，由脚本渲染）

```ini
# /etc/systemd/system/rtctl-agent.service  —— 由 rtctlctl 生成并托管，手工修改会被重写
[Unit]
Description=rtctl-agent remote terminal daemon
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=rtctl
Group=rtctl
SupplementaryGroups=          # 不继承 docker/adm 等附加组权限（最小权限）
WorkingDirectory=/
Environment=HOME=/var/lib/rtctl
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/bin/rtctl-agent -config /etc/rtctl/agent.conf -open-firewall=false -print-token=false
Restart=always
RestartSec=2
TimeoutStopSec=20
KillMode=control-group
KillSignal=SIGTERM
SendSIGKILL=yes
LimitNOFILE=65535
LimitCORE=0                   # 不产生 core dump（内存里有 token）
NoNewPrivileges=yes          # allow_sudo=true 时渲染为 no（见 7.4）
SyslogIdentifier=rtctl-agent
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### 7.3 关键行的依据

| 行 | 依据 |
|---|---|
| `Type=simple`（**不用 `Type=exec`**） | agent 未实现 `sd_notify`；systemd < 240（RHEL8=239）把未知 Type 当致命错误，unit 直接加载失败 |
| `After=network.target` | agent 只做监听，不依赖地址就绪；`network-online.target` 拖慢开机 |
| `Environment=HOME=/var/lib/rtctl` | `os.UserHomeDir()` 读 `$HOME`；系统用户家目录常是 `/nonexistent`，远程子命令会往 `$HOME` 写 |
| `Environment=PATH=...:/usr/sbin:/sbin` | 远程 exec 继承服务 PATH；systemd 默认 PATH 在部分发行版缺 `/usr/sbin`，导致远程 `iptables`/`useradd` 报 command not found |
| `-config /etc/rtctl/agent.conf` | 显式指定绕开查找链，HOME 变化不再影响配置定位 |
| `Restart=always` + `StartLimitBurst=5` | 配置损坏时 `log.Fatalf` 退出需自动拉起；5 次后进 failed，避免无限刷日志 |
| `KillMode=control-group` | stop/restart 时远程命令子进程随 cgroup 一起收信号，不留孤儿。**副作用要写进文档**：运维用 `nohup` 起的后台任务也会被停掉 |
| `LimitNOFILE=65535` | 同时持有多条 WS + shell 会话 + 文件传输，默认 1024 易打满 |
| `NoNewPrivileges` 动态渲染 | NNP 会阻止 setuid 提权，与 `allow_sudo=true` 硬冲突：`allow_sudo=false` → `yes`（封死误提权），`true` → `no`；`config set allow_sudo` 会重写该行并 reload+restart |
| `-print-token=false` **必须能力探测** | 老二进制不认识该 flag → 启动即失败、**崩溃循环**。`rtctl-agent -h \| grep -- -print-token` 通过才写进 unit，否则省略并警告「启动块会在 journald 打印完整 token」 |
| `SupplementaryGroups=`（空） | 不继承 docker/adm 等附加组；agent 不需要这些权限 |
| `LimitCORE=0` | 内存里持有 token，禁止 core dump 落盘 |

### 7.4 为什么不给 agent 加沙箱（`Protect*` 逐条结论）

**两组结论冲突处的裁决**（主代理定）：

| 选项 | 系统组 | 安全组 | 裁决 | 理由 |
|---|---|---|---|---|
| `PrivateTmp` | 不开 | 开 | **不开** | `file-put /tmp/x` 后宿主机 `ls /tmp` 看不到 → 高频困惑；隔离收益有限（同 namespace 内 exec 仍可读） |
| `RestrictAddressFamilies` | 不开 | 开 | **不开** | 会禁 `AF_PACKET` → `tcpdump` 不可用，远程排障刚需 |
| `SupplementaryGroups=` | 省略 | 空 | **空** | 最小权限；可用 `--extra-groups` 覆盖 |
| `Restart=` | always | on-failure | **always** | 覆盖「被远程 kill」的情况；`systemctl stop` 仍会阻止重启 |
| `LimitCORE=0` | — | 开 | **开** | 安全组新增，采纳 |

判定基准：agent 需要读配置、监听端口、`fork /bin/sh -c` 执行任意命令、`file-put/file-get` 读写任意路径、可选 `sudo -n` 提权。**结论：标准单元只做进程生命周期管理，不做伪沙箱**——agent 的定位就是「远程 shell 等价物」，任何文件系统/系统调用沙箱与功能定义互斥。

| 选项 | 结论 | 一句话理由 |
|---|---|---|
| `ProtectSystem` | 省略 | `/usr`、`/etc` 只读会让 `file-put` 到 `/etc` 必然失败 |
| `ProtectHome` | 省略 | 远程读写 `/home/*`、`/root/*` 是核心用法 |
| `PrivateTmp` | 省略 | 传进 `/tmp` 的文件对其他单元不可见，运维看不到 |
| `PrivateDevices` | 省略 | 远程常需 `/dev/sdX`（`fdisk`、`dd`、`smartctl`） |
| `ProtectProc` / `ProcSubset` | 省略 | agent 的进程树清理依赖 `/proc`，隐藏后 `exec -timeout` 杀树失效 |
| `SystemCallFilter` | 省略 | 远程执行任意命令无法预先枚举 syscall，必然误杀 |
| `RestrictNamespaces` | 省略 | `unshare`/`docker`/`podman` 全废 |
| `CapabilityBoundingSet=` | 省略 | 会让需要 cap 的命令（`ping` 的 `CAP_NET_RAW`）失败。**若把 listen 改成 `:443`**，改用 `AmbientCapabilities=CAP_NET_BIND_SERVICE`，`doctor` 会检测该组合 |
| `DynamicUser` | 省略 | 每次启动 uid 变化，配置属主与 sudoers 规则全部失配 |

需要收窄攻击面的人走**可选加固 drop-in**（`doctor --harden` 生成，默认不生成、需 `--yes`）：`ProtectSystem=strict` + `ProtectHome=read-only` + `SystemCallFilter=@system-service` + `CapabilityBoundingSet=` 等。启用后**确定失效**的能力必须提前告知：文件传输只能落 `ReadWritePaths` 白名单内、`sudo` 全废、`exec -timeout` 杀树失效、`systemctl`/`mount`/`docker`/`tcpdump`/任何 JIT 程序报错。

### 7.5 用户级单元与 linger

```ini
# ~/.config/systemd/user/rtctl-agent.service
[Unit]
Description=rtctl-agent (user scope)
After=default.target

[Service]
Type=simple
ExecStart=%h/.local/bin/rtctl-agent -open-firewall=false -print-token=false
WorkingDirectory=%h
Environment=HOME=%h
Environment=PATH=%h/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Restart=always
RestartSec=2
TimeoutStopSec=20
KillMode=control-group
SyslogIdentifier=rtctl-agent
NoNewPrivileges=yes

[Install]
WantedBy=default.target
```

- **不写 `User=`/`Group=`**（用户单元里写会导致加载失败）；**不传 `-config`**，走 agent 默认查找链命中 `%h/.rtctl/agent.conf`。
- `Environment=HOME=%h` 必须钉死：user manager 由 PAM 首次启动时继承环境，之后 `HOME` 可能是陈旧值，而 `os.UserHomeDir()` 依赖它。
- 顺序固定：写 unit → `loginctl enable-linger <user>` → 等 `/run/user/<uid>/bus` 就绪 → `systemctl --user daemon-reload` → `enable --now`。
- `enable-linger` 失败**不中止安装**（当前会话仍可用），但写 `AUTOSTART=none`、`doctor` 标 WARN、`status` 提示「未开 linger：注销后停止、重启不自启」。
- `systemctl --user` 报 `Failed to connect to bus` 的处理：root 下**不**做「连 root bus」的魔法，直接报错并打印 `sudo -u USER XDG_RUNTIME_DIR=/run/user/UID systemctl --user ...`；cron 里必须写全 `XDG_RUNTIME_DIR` 前缀。

### 7.6 OpenRC（Alpine）

```sh
#!/sbin/openrc-run
name="rtctl-agent"
command="/usr/local/bin/rtctl-agent"
command_args="-config /etc/rtctl/agent.conf -open-firewall=false -print-token=false"
command_user="rtctl:rtctl"
command_background="yes"
pidfile="/run/rtctl-agent.pid"
output_log="/var/log/rtctl-agent.log"
error_log="/var/log/rtctl-agent.log"
supervisor="supervise-daemon"
respawn_delay="2"
respawn_max="5"
retry="SIGTERM/20"
depend() { use net; after firewall; }
start_pre() {
    checkpath -d -m 0750 -o rtctl:rtctl /var/lib/rtctl
    checkpath -f -m 0640 -o rtctl:rtctl /var/log/rtctl-agent.log
}
```

- `use net` 而非 `need net`：最小系统可能没有 `net` 服务，`need` 会让服务永远起不来。
- `supervisor="supervise-daemon"` 需要 OpenRC ≥ 0.31；缺失时报错并建议 `--init nohup`，不引入额外 wrapper。
- `checkpath` 负责建目录/日志并设属主权限。

### 7.7 无 init（容器 / WSL）回退

- 不拒绝安装：照常落盘，用 `setsid "$BIN_AGENT" -config "$CONF" -open-firewall=false >>"$LOG_FILE" 2>&1 &` + pidfile 托管。
- **必须 `setsid`**：agent 的进程树清理会 `kill(-pgid)`，不脱离进程组会被连同 exec 的 shell 一起杀掉。
- pidfile 必须用 `/proc/$pid/exe` 反查校验，避免 PID 复用误杀。
- `enable`：检测到 crond 才写 `/etc/cron.d/rtctl-agent` 的 `@reboot`，否则 `AUTOSTART=none` + WARN（提示容器用 restart 策略、WSL 开 `/etc/wsl.conf` 的 `systemd=true`）。

### 7.8 健康检查（agent 已有 `/healthz`）

`internal/agent/standalone.go:92` 已注册 `/healthz` 返回 `ok`。探活地址必须**从 `listen` 推导**：空 / `0.0.0.0` / `::` → `127.0.0.1`，IPv6 加 `[]`，否则用该 IP——否则 `listen = 10.0.0.5:8443` 时固定打 `127.0.0.1` 会永远失败、把正常升级误判为失败并回滚。探测三路回退：`curl -fsS --max-time 2` → `wget -q -T 2 -O -` → `nc -w 2`（Alpine 最小镜像常无 curl）。

### 7.9 本专题坑位（摘）

| 触发 | 表现 | 对策 |
|---|---|---|
| `systemctl stop` 停 agent | agent 退出码 **1**（`ServeStandalone` 返回 `ErrServerClosed` → `log.Fatalf`） | 停止判定只看 `is-active`/pidfile，**忽略退出码**；文档写明「退出码 1 + inactive」= 正常停止 |
| 经 `rtctl exec` 远程升级 | 升级脚本在 agent 的 cgroup 内，`systemctl stop` 把它自己一起杀掉 → 二进制已换、服务没起、`.prev` 未回滚 | `systemd-run --unit=... --collect --pipe --wait` 脱离 cgroup；老 systemd 用 `/run/systemd/system` 临时单元 |
| 经 `rtctl exec` 非 sudo 起 `nohup agent &` | exec 结束/超时触发 `kill(-pgid)`，把刚起的 agent 一起杀掉 | `setsid` 起；脚本 `start` 末尾立即返回，随后用独立 `status` 复核 |
| 反复升级 / 单元已 failed | `start request repeated too quickly`，start 直接失败 | start/restart/升级前一律 `systemctl reset-failed rtctl-agent` |
| 升级 rtctlctl 自身 | `cp` 覆盖运行中的脚本 → `ETXTBSY` | 目标目录内 `mktemp` → `chmod` → `mv -f`（与二进制同一套） |
| SELinux Enforcing 下从 `/tmp` `mv` | label 仍是 `tmp_t` → 服务 exec 被拒 | staging 必须在目标目录内 `mktemp`；`mv` 后 `restorecon -F`（仅在 SELinux 启用时） |
| journald 速率限制 | `journalctl` 出现 `Suppressed N messages`，排障断片 | `doctor` 检测该字样，并支持 `config set log=file` 切文件日志 + logrotate |
| 卸载删 ufw/firewalld 规则 | 可能删掉管理员手工加的同一端口规则 | 只有 iptables 规则带 `-m comment --comment rtctlctl` 才自动删；ufw/firewalld 只打印手工命令 |

---

## 8. 升级与回滚

```text
rtctlctl upgrade [--check] [--version vX.Y.Z] [--yes]
  1. 解析目标版本（同 install）
  2. 目标 == 当前 且 sha256 一致 → 打印「已是最新」exit 0
  3. svc_stop（systemctl stop，超时 15s，轮询 is-active 确认退出；不用 kill -9）
  4. 下载 + 校验（同 install 第 3-4 步）
  5. cp -p 当前二进制 → .prev（同目录）
  6. 同目录 mktemp → chmod/chown → mv -f（原子替换；脚本自身同样替换）
  7. svc_start → 健康检查（active + 端口可连，最多等 10s）
  8. 失败：mv -f .prev → 当前 → svc_start → 回写状态 → exit 9
```

- **回滚非原子路径禁止**：不得从 `/var/lib/rtctl/rollback/` 直接 `mv` 到 `/usr/local/bin`（跨文件系统退化为 copy+unlink，且会把 `var_lib_t` SELinux 标签带进 `/usr`）。必须复制到目标同目录临时文件再 `mv`。
- **避免自杀式升级**：若经 `rtctl exec` 远程触发升级，被停的服务就是承载这条命令的 agent。install/upgrade 用 `systemd-run --unit=rtctl-upgrade --collect` 或 `nohup ... &` 脱离调用者。
- **状态回写**：升级成功与回滚成功都必须回写 `RTCTL_VERSION`，否则 `version` 与真实二进制不一致。

---

## 9. 卸载

```text
rtctlctl uninstall [--purge] [--yes]
  1. svc_stop → 确认 inactive
  2. svc_disable（关自启）
  3. systemctl reset-failed（若有失败记录）
  4. 删单元文件 → daemon-reload
  5. 删二进制、软链、.prev
  6. 撤销 install 记录的防火墙规则（ufw delete / firewall-cmd --remove-port / iptables -D）
  7. 默认保留 agent.conf（token 与配置是用户的资产）
  8. --purge 才删：agent.conf、/etc/rtctl、/var/lib/rtctl、专用用户 rtctl
```

删除顺序不可颠倒：先删文件后停服务 → 服务进入 `activating (auto-restart)` 无限重启。删除前列出将移除的清单并要求确认；非交互需 `--yes`。

---

## 10. 安全模型

> 详细定稿见 **[`rtctlctl-security-design.md`](./rtctlctl-security-design.md)**（token 生命周期全表、权限矩阵、攻击面 A1–A12、坑位 P1–P14、16 条验收项）。下面是决策层摘要。

### 10.1 token 生命周期

| 环节 | 做法 | 泄露面 | 对策 |
|---|---|---|---|
| **生成** | 只能由 `rtctl-agent -init` 的 `genToken()` 生成（`crypto/rand` 32 字节 → 64 hex） | 生成瞬间 stdout | 脚本**永不**自己造 token；`-init` 的 stdout 重定向到 `/dev/null`；**绝不** `-token` 走 argv |
| **存储** | 系统级 `/etc/rtctl/agent.conf` 0600 属主 `rtctl`；用户级 `~/.rtctl/agent.conf` 0600 | 同机其他用户、备份/快照 | 目录 0750 + 文件 0600；不用 EnvironmentFile、不写 unit、不写 `install.env`（写前过 `assert_no_secret`） |
| **查看** | `token show` 默认 **masked + fingerprint**；`--reveal` 才给完整值 | 重定向进日志/CI | 非 TTY 的 `--reveal` **拒绝**（exit 12）；`config get token` 一律拒绝 |
| **传输** | 无 TLS 时 token 与命令明文 | 同网络可截获 | `doctor` 对「非回环 + 无 TLS」打 FAIL；示例强制 `wss://` |
| **启动打印** | agent 启动块把完整 token 打到 stdout | journald 留存 | 单元传 `-print-token=false`（**能力探测通过才加**，见 D11）；`logs` 默认过滤 token 行 |
| **轮换** | 备份 → 临时文件 → `mv` → restart → **双探针** | 备份文件本身含旧 token | 备份 0600；失败自动回滚；文案必须写「**重启后**旧 token 失效」 |
| **销毁** | 默认卸载**保留**配置；`--purge` 用 `shred -u` 删配置**及全部 `.bak-*`** | 残留 token 仍能连入 | 卸载末尾强制打印保留路径与销毁命令 |

### 10.2 权限矩阵

见 §6 与安全文档 §2。四条不可动摇：脚本本体 0755、配置目录 `0750 root:rtctl`、配置文件 `0600 rtctl:rtctl`、unit 文件 0644 且**绝不放 token**。

### 10.3 脚本自身的信任链

- `curl | sh` 时脚本是整条链上**唯一无法自校验**的一环：能改 Release 附件的人同样能改 `SHA256SUMS.txt`。
- README **主推两段式**（下载 → 核对公布的 sha256 → 执行）；`--pinned-sha256 <hex>` 供钉死期望值（管道执行时直接拒绝，因为无法自校验）。
- 发版四件事：`build.ps1` 写 LF 清单、资产加入 `install.sh`、RELNOTES 单独公布 `install.sh` 的 sha256、README 引用该哈希。
- 表述纪律：**不要**把 SHA256SUMS 说成「签名」——它只防传输损坏与错版本。

### 10.4 sudo 策略

- 只有 `install` / `uninstall` / 系统级 `upgrade` / `config` / `token` 需要 root。
- **脚本从不自己 sudo 提权**：`euid != 0` 且需 root → 打印 `需要 root：sudo rtctlctl <子命令>` 并 exit 6。避免半提权状态（HOME/PATH/umask 已变）与 cron/CI 静默弹密码。
- `sudo -n` **只用于探测**；绝不用 `sudo -S` 喂密码。
- **绝不自动写 sudoers**：理由有三——语法错误会让全系统 sudo 失效；提权路径是 `sudo -n -- /bin/sh -c <cmd>`，任何放行规则都等价于「token 持有者 = root」；权限跃迁必须由人拍板。只打印现成命令块（含 `visudo -cf` 校验），并支持 `--print-sudoers <file>` 降低手抄出错率。
- 脚本**不读任何环境变量作为输入**（`env_reset` 会剥掉）；代理走 `--proxy`，逃生舱 `sudo -E` 仅限可信终端并注明风险。

### 10.5 日志与输出脱敏

- `/var/log/rtctl/install.log` 0640，**不记录原始 argv**，只记子命令 + 白名单参数；写前强制脱敏（`^[0-9a-f]{64}$`、`--token[= ]\S+`、`BEGIN … PRIVATE KEY`）。
- `handleExec` 会把**完整命令**写进 agent 日志 → journald 必须视为敏感数据；`doctor` 固定提示并检查 `journald.conf` 的 `Storage=`。
- `--json` 输出不含 token；`doctor` 不打印配置内容。

### 10.6 服务加固结论

标准单元**不做沙箱**（裁决见 §7.4）；按条件渲染的只有 `NoNewPrivileges` 与 `-print-token=false`（都依赖能力/配置探测）。需要收窄攻击面的人走可选 drop-in，并接受 §7.4 列出的能力损失。

### 10.7 TLS 与客户端信任（容易踩的坑）

`cmd/client` **没有任何 TLS flag**，走系统信任库 → **自签证书默认不可用**：必须先在控制机导入签发 CA（Debian/Ubuntu 用 `update-ca-certificates`，RHEL 系用 `update-ca-trust`，Windows 导入「受信任的根证书颁发机构」）。同时快捷入口会被强制补 `ws://`，开 TLS 后连接示例必须换成 `rtctl -server wss://host:port/ws exec -token <token> -c '<cmd>'`。这两条必须写进 README，否则用户会退回明文。

### 10.8 攻击面摘要

| 攻击面 | 现实风险 | 脚本能做的缓解 |
|---|---|---|
| 8443 暴露 | 全网可扫；`checkToken` 无速率限制 | `--listen` 收窄、`--allow-from <CIDR>` 限源、`doctor` 对 `0.0.0.0/::` 打 WARN |
| **未认证信息泄露** | `auth`/`list`/`/healthz` 不需 token → 泄露主机名/OS/架构/版本 | 改不了 agent；只能靠监听地址与防火墙；文档明写 |
| 无 TLS 明文 | 被动嗅探即得 token | `doctor` FAIL + README 醒目警告 |
| token 泄露（日志/ps/argv/history/备份/core） | 拿到即完全控制 | §10.1 全链路收敛 + `token reset`；`LimitCORE=0` |
| `file-put` 到敏感路径 | 可覆盖任意可写路径并**持久化** | agent 固有能力；rtctl 无 home + nologin；`/etc/rtctl` 0750 |
| 远程 shell 本身 | 等价于把机器交出去 | 普通用户运行 + 三层 sudo 审批 + 「只装可信机器」纪律 |
| sudoers 通道 | 一旦配置即 token = root | 不自动写；`doctor` 双向检测并 WARN |
| `commands.d` 扩展目录 | 被 source 等于提权 | 加载前校验「root 所有 + 非 group/world-writable」，否则跳过 |
| `.rtctl-partial` 跟随符号链接 | 第三方预置链接可让上传截断敏感文件 | 提示不要把 agent 可写目录开放给他人 |

---

## 11. 扩展机制（承载「未实现功能」）

- **注册表驱动**：`RTCTL_CMD_TABLE` 每行 `name<TAB>handler<TAB>risk<TAB>needs_root<TAB>desc`，`dispatch()` 查表调 `cmd_<name>()`；`main` 永不改动。
- **外部扩展点**：`<PREFIX>/lib/rtctl/commands.d/*.sh`，加载前校验「root 所有 + 非 group/world-writable」，否则告警跳过（这个目录会被 source，必须防提权）。
- **占位命令**：未实现功能注册到同一张表，handler 为 `cmd_not_implemented`，打印「功能 X 尚未实现（计划 vX.Y）」并 **exit 11**（与「用法错误 2」区分开，避免误导）。
- **`help` 直接渲染路线图**：注册表就是文档，新增功能只换 handler，命令名不漂移。

---

## 12. 需要改动的现有代码（共 4 处，都很小）

| # | 文件 | 改动 | 必要性 |
|---|---|---|---|
| C1 | `cmd/agent/main.go`、`cmd/client/main.go` | 各加 `-version` flag，打印 `internal/agent.Version` / 客户端版本；`build.ps1` 用 `-ldflags -X main.version=<tag>` 注入 | 否则 `version`/`doctor` 无法自证版本一致性 |
| C2 | `cmd/agent/main.go` | 加 `-print-token=false`（默认 true，保持兼容） | 否则 token 进 journald，`logs` 成泄露通道 |
| C3 | `build.ps1` | 校验清单改用 `[IO.File]::WriteAllText` 写 LF；新增产出 `bin/install.sh`（从仓库根复制并注入版本号）；收尾断言无 `\r`、无 `@@` 残留 | CRLF 会让校验链必失败（见 2.2） |
| C4 | 仓库新增 `.gitattributes` | `*.sh text eol=lf`、`SHA256SUMS.txt text eol=lf` | 防止 Windows 侧再次引入 CRLF |
| C5（可选） | `cmd/agent/main.go` 加 `-check-config`（解析配置、打印脱敏摘要后退出） | 让 `doctor` 能校验配置合法性与 `listen` 解析，不必先起服务（约 10 行） |
| C6（可选） | 仓库加 `build.sh`（Linux 侧等价 `build.ps1`） | 现状只有 Windows 构建脚本，Linux/CI 上产不出带校验清单的 `bin/` |

> C1/C2 是**必需**（否则版本无法自证、token 进 journald）；C5/C6 是可选增强。在三项未落地前的降级行为：`version` 读状态文件 + 实算 `sha256sum` 比对，`doctor` 用 `readlink /proc/$pid/exe` 与落盘文件的 inode 对比。

发布链还需：`push-release.ps1` 的 `$Assets` 补 `bin/install.sh`（并把硬编码的 `v3.2.0` 改为参数），README/RELNOTES 更新一行安装命令与 install.sh 的 sha256。

---

## 13. 风险清单（评审产出，已复核）

| 风险 | 触发条件 | 表现 | 对策 |
|---|---|---|---|
| 校验清单 CRLF | 任何安装 | 校验必失败或静默跳过 | `tr -d '\r'` + 修 build.ps1 + `.gitattributes` |
| 脚本落盘无执行位 | 用户执行 `rtctlctl` | `Permission denied` | 落盘 0755，install 后自检 `[ -x ]` |
| 配置属主冲突 | 系统级安装 | systemd 崩溃循环，只显示 exit 1 | install 建 0750 root:rtctl，init 后 chown |
| `curl \| sh` 吞 stdin | 管道安装 | 提问被跳过、sudo 提示乱码 | 交互只从 `/dev/tty` 读；无 tty 走默认值或要求 `--yes` |
| Alpine 缺件 | apk 系 | 无 curl、无 systemd、无 `runuser` | wget 回退、OpenRC 分支、去掉 `runuser` 依赖 |
| 跨文件系统 mv | 从 `/tmp` 或 `/var` 移动 | 非原子、半截二进制 | 目标同目录 `mktemp` + `mv` |
| 版本探测被限流 | 共享出口 IP | GitHub API 403 | 走 `releases/latest` 重定向，不调 API |
| 手工 nohup 与服务抢端口 | 已有手工部署 | `address already in use`、随机失败 | 启动前端口检测 + 迁移提示；用 `pgrep -f '^/usr/local/bin/rtctl-agent'` 锚定，**禁用 `pkill -f rtctl-agent`**（会杀掉执行命令的 shell 自身） |
| 规模膨胀 | 功能持续加 | 重蹈 v3.2.0 删安装器的覆辙 | 单文件、行数预算、扩展走注册表 |

---

## 14. 里程碑与验收

| 阶段 | 内容 | 验收 |
|---|---|---|
| M1 | 基础设施修复（C1-C4 + `.gitattributes`） | `sha256sum -c` 在 Linux 上通过；`rtctl-agent -version` 输出 tag |
| M2 | 脚本骨架：注册表、`ask()`（/dev/tty）、`die()`、颜色、状态文件、锁 | `sh install.sh help` 正确渲染；无 tty 下不阻塞 |
| M3 | install/uninstall/init/start/stop/restart/status/logs/enable/disable | Debian 12 + Rocky 9 上装→连→停→启→卸 全通过 |
| M4 | upgrade/rollback/config/token/doctor/version | 升级后 `rtctl list` 版本一致；人为损坏二进制后 doctor 报 fail |
| M5 | Alpine + 容器 + 用户级安装 | Alpine 3.19（OpenRC）与 `--scope user` 各跑通一次 |
| M6 | CI：shellcheck + 容器矩阵 + 冒烟（装→exec→升级→卸载） | PR 上自动跑 |

### 14.1 验收命令（可直接复制）

```sh
# 静态检查（CI 门槛）
dash -n install.sh && busybox ash -n install.sh && shellcheck --shell=sh -x install.sh

# systemd 系统级
sudo sh install.sh --scope system
systemctl is-enabled rtctl-agent && systemctl is-active rtctl-agent
systemctl show rtctl-agent -p User -p Group -p ExecStart -p Restart -p NoNewPrivileges -p KillMode
curl -fsS http://127.0.0.1:8443/healthz                     # 期望 ok
sudo ss -ltnp 'sport = :8443'                               # 期望属主是 rtctl
sudo -u rtctl cat /etc/rtctl/agent.conf >/dev/null && echo conf-ok
sudo stat -c '%a %U:%G' /etc/rtctl /etc/rtctl/agent.conf    # 期望 750 root:rtctl / 600 rtctl:rtctl
sudo sh install.sh upgrade ./rtctl-agent-linux-amd64 && sudo sh install.sh doctor

# systemd 用户级
sh install.sh --scope user
loginctl show-user "$USER" -p Linger                        # 期望 Linger=yes
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active rtctl-agent

# OpenRC（Alpine）
rc-service rtctl-agent status && rc-update show default | grep rtctl-agent
tail -n 50 /var/log/rtctl-agent.log

# nohup（容器 / WSL）
sudo RTCTLCTL_INIT=nohup sh install.sh --scope system
sh install.sh status && cat /run/rtctl-agent.pid
readlink /proc/$(cat /run/rtctl-agent.pid)/exe

# 卸载幂等：第二次应全 SKIP、退出码 0
sudo sh install.sh uninstall && sudo sh install.sh uninstall
```

---

## 15. 待你拍板的问题

| # | 问题 | 选项 | 主代理倾向 |
|---|---|---|---|
| 1 | **默认监听地址** | A `127.0.0.1:8443`（安全默认，对外须显式 `--listen`）<br>B `:8443`（对齐 agent 默认、开箱即用） | **B**——rtctl 的核心用途就是远程控制，默认回环会让「装完从控制机连不上」成为首要困惑；配合安装引导显式询问 + 非回环且无 TLS 时 `doctor` FAIL |
| 2 | **无 TLS 默认行为** | A 硬拒绝（必须显式 `--insecure-plaintext` 才继续）<br>B 仅 WARN 继续（`doctor` 打 FAIL） | **B**——A 会让内网首装直接卡住；B 保持可用并在结尾醒目警告 |
| 3 | **脚本落盘名** | `rtctlctl` / `rtctl-manage` / `rtctl-admin` | **`rtctlctl`** |
| 4 | **系统级运行用户** | A 创建专用系统用户 `rtctl`<br>B 沿用 `SUDO_USER` | **A** |
| 5 | **自举 URL** | A `releases/latest/download/install.sh`（需先发一个带该附件的新版，如 v3.3.0）<br>B `raw.githubusercontent.com/.../main/install.sh` | **A**；仓库若私有，B 的 raw 链接需要凭据、不可用 |
| 6 | **agent 两个小 flag**（`-version`、`-print-token=false`） | 接受 / 不接受 | **接受**；不接受则 `doctor` 无法自证版本、token 会留在 journald（降级方案：靠 `install.env` + sha256 反查） |
