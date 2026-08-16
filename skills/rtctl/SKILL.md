---
name: rtctl
description: Build, run, test, and extend the rtctl remote terminal control system (Go agent + client, direct-connect architecture, no relay). Covers the agent standalone WS server, clientd REST API for AI agents, chunked file transfer protocol, Machine Client Contract (completion/truncation/error-code semantics), the rtctl-wizard binary installer, Windows-specific execution pitfalls, and the end-to-end smoke-test procedure used to verify fixes.
---

# rtctl — 远程终端控制系统（纯直连版）

rtctl 由两个组件构成：**agent**（被控端，自带 WS 监听，Linux/Windows）+ **client**（控制端 CLI，含 `serve` 子命令——常驻 HTTP 服务供 AI Agent 直控）。**没有中继/中心服务器**。
执行模型：`exec` 一次性命令（完成帧 + 退出码）、`shell` 交互终端（Linux 真 PTY / Windows cmd 管道）、`file-put/file-get` 分片文件传输。设备以 token 寻址：持有设备 token 即拥有该设备 shell 权限。

## 目录与分层

```
rtctl/
├── cmd/agent         # 被控端入口（-listen 直连监听）
├── cmd/client        # CLI：main.go(list/exec/shell) + file.go(文件传输) + serve.go(clientd HTTP 服务)
├── cmd/installer     # rtctl-wizard 二进制安装向导（agent/clientd/client 三组件）
├── deploy.sh/.ps1    # 脚本化部署（agent/clientd/client/status/info/update/uninstall）
└── internal/
    ├── proto         # 消息外壳 + 各 payload + 错误码常量（协议唯一定义处）
    ├── agent         # 执行器 + standalone.go(直连服务端)（linux/windows 分平台）
    └── idutil        # 消息/会话/传输 ID
```

关键架构点：
- **sendSink 抽象**（`internal/agent`）：处理函数（exec/shell/file）的响应目标可插拔——每条直连客户端连接的响应队列。改动任何"发响应"的代码都要走 sink。
- **standalone 服务端**（`standalone.go`）：实现完整 client 侧协议；token 只校验**发起类消息**（exec/exec_kill/shell_open/file_put/file_get/file_abort），分片/流消息不带 token 按 ID/会话绑定。
- **clientd**（`cmd/client/serve.go`）：设备清单条目必须带 `url` 直连地址；每请求独立连接设备；`list` 逐个探活。

平台拆分约定（`//go:build` 标签）：`shell_linux.go` / `shell_windows.go`（shell 会话实现）、`shell_exec_linux.go` / `shell_exec_windows.go`（exec argv 与进程树终止）。改执行逻辑时必须同时看两个平台文件。

## 构建

- 模块要求 `go >= 1.25.0`（`go.mod`）。本机 `go` 可能不在 PATH：可用 `D:\Test\go-sdk\go\bin\go.exe`；版本不足时 Go 会通过 GOTOOLCHAIN 自动下载（需网络）。
- 常用命令（在仓库根目录执行）：
  ```powershell
  & D:\Test\go-sdk\go\bin\go.exe build ./...        # 本机构建
  & D:\Test\go-sdk\go\bin\go.exe vet ./...          # 静态检查
  & D:\Test\go-sdk\go\bin\go.exe test ./...         # 单测（installer 有测试）
  & D:\Test\go-sdk\go\bin\gofmt.exe -l <files>      # 格式检查（提交前必须为空）
  $env:GOOS='linux'; $env:GOARCH='amd64'; $env:CGO_ENABLED='0'; & D:\Test\go-sdk\go\bin\go.exe build ./...  # Linux 交叉构建
  ```
- 单文件跨平台（`agent.go` 等）不得使用平台专属符号（如 `syscall.SysProcAttr.Setpgid`）；平台差异一律放 build-tag 文件里，否则交叉构建失败。
- `bin/` 下的提交二进制需与源码一致（用哈希比对）；改动后应重建（Windows exe + Linux amd64/arm64 + rtctl-wizard 三个平台）。

## 运行与冒烟测试（验证修复的标准流程）

1. 构建：`go build -o .\smoke\agent.exe ./cmd/agent`（client 同理）。
2. 起 agent（直连）：`Start-Process .\smoke\agent.exe -ArgumentList '-listen','127.0.0.1:18443','-id','web-01','-token','t1' -WindowStyle Hidden -RedirectStandardOutput ... -RedirectStandardError ...`
3. 验证清单（每项都应有明确断言）：
   - `client -server ws://127.0.0.1:18443/ws list`：设备在线 + 元数据（os/arch/hostname/version）。
   - `exec` 退出码透传：`exec 'exit /b 42'` → exit 42；`-workdir` 生效。
   - **嵌套引号**：`exec -c 'powershell -NoProfile -Command "1..5 | ForEach-Object { ''x'' }"'` 必须输出 5 行（历史 bug：cmd.exe 剥引号，修复靠 `SysProcAttr.CmdLine`）。
   - **超时杀进程树**：`exec -timeout 1000 'ping -n 10 127.0.0.1'` 应 ~1s 返回 `[执行超时]`（Linux 用 `sleep 100`，之后 pgrep 确认无孤儿）。
   - **错误码**：错 token → `bad_token`；重复 exec ID → `conflict`（internal/agent/agent_test.go 覆盖，smoke/check.go 可端到端复核）。
   - **shell 会话**：两个并发 shell 各自 echo 不同标记，输出不得串台；开满 8 个后第 9 个被拒（agent_test.go 覆盖）。
   - **文件传输**：`file-put`/`file-get` 往返后哈希一致（用 >256KB 随机文件覆盖分片路径）；覆盖同名文件生效；不存在文件回 `not_found`。
   - **shell**：管道输入 `"echo hi`r`nexit`r`n"` 必须看到 hi 输出（EOF 宽限修复）。
   - **clientd**：`client serve -listen 127.0.0.1:18080 -devices devices.json -api-key test` 起服务后：`/healthz` 免认证 ok；无 key 401；`/api/v1/devices`、`/api/v1/exec`（退出码/超时）、`/api/v1/files/upload|download`（哈希一致）；并发 5 exec + 2 上传；设备掉线时请求回 `connection_lost`。另验证 `-api-key` 缺省时读 `RTCTL_API_KEY` 环境变量。
4. 收尾：`Stop-Process` 所有测试进程，删除 `smoke/`（含带凭据的测试助手脚本）。

## 协议契约（Machine Client Contract 要点）

完整契约见 `DESIGN.md` 第 6 节。关键不变量：

- **完成 = `done=true` 帧**；任何连接错误都表示结果未知（命令可能已执行），非幂等命令不得盲目重试。
- `truncated=true` = 输出被背压丢弃过，内容不可信。
- 错误码常量在 `internal/proto/proto.go`（`ErrorCode*`）：`bad_token`（配置错误勿重试）/ `connection_lost`（可重试）/ `timeout` / `killed` / `conflict` / `overload` / `not_found` / `bad_device` / `start_failed`。
- 背压：普通帧队列满即丢并在 done 帧标注 truncated；done 帧与文件分片阻塞送达；客户端持续不读会被 10s 写超时切断并取消其 exec。
- 文件数据不可静默丢弃（丢失 = 文件损坏）；临时文件 + 原子改名；断连清理临时文件。

## 已知限制与坑（不要再踩）

- **Windows cmd 引号**：exec 必须走 `SysProcAttr.CmdLine` 的包裹式命令行（`windowsCmdLine`）。改动 `shellExecArgs` 时不要退回 `exec.Command("cmd","/C",s)` 默认 argv 引用（内层双引号会被剥掉）。
- **超时必须杀整树**：`TerminateProcess`/`Process.Kill` 只杀直接子进程，孙进程会继续持有管道导致读循环不结束。Linux 用 `Setpgid`+`kill(-pid)`，Windows 用 `taskkill /T /F`；且 ctx.Done 后要停止读循环。
- **注册类竞态**：凡"首消息建立状态 + 后续消息引用状态"的模式（shell_open、file_put），建立必须**同步**（不能在 goroutine 里），否则后续消息查不到状态被静默丢弃。
- **token 校验边界**：分片/流消息（file_put_chunk、shell_data/resize/close）不带 token，standalone 服务端对它们查 token 会误拒（表现为 bad_token）。只对发起类消息查 token。
- **安装向导写配置文件必须 chown 服务账户**：安装器以 root 运行，写的 0600 设备清单归 root，低权限服务账户读不到 → 崩溃循环。写完后 `os.Chown` 给服务账户。
- **覆盖安装先停旧服务**：Linux 不能覆盖正在运行的可执行文件（"text file busy"）。
- **shell 管道输入 EOF 宽限**：client 的 stdin 关闭后立即发 shell_close 会把远端 PTY 缓冲里没来得及执行的命令吞掉；EOF 后延迟 ~500ms 再发关闭。
- **Windows 输出编码**：中文系统 cmd 输出是 GBK；agent 侧启发式转码（UTF-8 有效则原样，否则 GBK 解码），分片边界切开多字节字符时该片回退原样——接受该不完美性。
- **安装器二进制命名**：文件名不要含 install/setup/update/patch——Windows 安装器启发式会对这类名字强制提权/拦截（实测）。当前命名 `rtctl-wizard`。
- **部署信息可复现**：装完当场打印连接信息（ID/地址/token/devices.json 片段/验证命令）；之后 `bash deploy.sh info`（菜单 4，无需 root）/ `rtctl-wizard info` / `deploy.ps1 -Mode Info` 重新查看。信息从 systemd unit（`systemctl cat` 的 ExecStart/Environment 行）或计划任务 XML 提取，不是存储新文件。
- **特权命令（sudo）三道闸**：① agent `-allow-sudo`（装时选允许提权，写 sudoers 最小放行 `/bin/sh /usr/bin/sh /usr/bin/kill /bin/kill` + NoNewPrivileges=false）；② CLI `-sudo`（TTY y/N 确认；非交互必须 `-confirm-sudo`）/ clientd `-allow-sudo`（否则 403 `approval_required`）；③ sudoers 匹配。错误码 `sudo_disabled` / `sudo_denied` / `approval_required`。旧 agent（<3.1.0）不认识 sudo 字段会**静默按低权限执行**——发特权请求前先 `list` 看版本。
- **sudo 执行不能用 CommandContext 杀树**：sudo 会为目标命令新建会话/进程组，且 ctx 取消时 CommandContext 抢先杀掉的只是 sudo 直接子进程——两者叠加导致孙进程全漏杀。sudo 路径用普通 `exec.Command`，杀树时经 `/proc/<pid>/stat` 的 ppid BFS 收集全部后代（含 sudo 自身），再 `sudo -n /bin/sh -c 'kill -KILL <pids...>'` 一次杀光（实测 timeout 1.5s → 1.6s 返回、无孤儿）。
- `-race` 构建在 Windows 需要 cgo（gcc）；本机没有时改用功能性测试替代。
- **凭据落盘只能走 EnvironmentFile**（0600 + chown 服务账户）：unit 文件 0644 全局可读、命令行参数 `ps` 全局可见，token/api-key 放这两处等于交给所有本地用户。clientd 的 api-key 优先读 `RTCTL_API_KEY` 环境变量；`info` 从 env 文件提取凭据（需 root），不要再回退到 unit 内联 `Environment=` / `-api-key` 参数。
- **shell 会话 ID 两端兜底**：client 用 `idutil.New()` 生成；agent 收到空 ID 时兜底生成并在 shell_ack 回传（历史 bug：空 ID 让多个 shell 在注册表里互相覆盖、按键串台、断连清理误杀）。
- **并发闸持有到资源释放**：shell 信号量在会话退出 goroutine 里释放（历史 bug：`defer` 在 handleShellOpen 返回时释放，maxConcurrentShell 形同虚设）。
- **ID 冲突必须拒绝**：exec / file_put / shell_open 注册前查重，冲突回 `conflict`（契约 6.4）；重复 ID 会覆盖注册表导致 kill 失效、输出混杂。

## 修改检查清单

| 改动 | 必查 |
| --- | --- |
| 协议字段 | `proto.go` 常量 + agent/client 两端同步；旧客户端兼容性 |
| 执行逻辑 | 双平台文件；超时/取消路径；输出读循环的退出条件 |
| 文件传输 | 分片大小、大小上限、临时文件清理（abort/断线两路径）、阻塞送达 |
| clientd API | 认证中间件、url 必填校验、请求超时的 kill/abort |
| 安装向导 | 组件分支、非交互缺参报错、配置文件 chown、先停旧服务 |
| CLI 参数 | `usage()` 文案、README/DESIGN 配置表同步 |
| 任何改动 | `go build ./...` + `go vet ./...` + `go test ./...` + Linux 交叉构建 + gofmt + 冒烟清单 3 |
