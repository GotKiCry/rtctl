---
name: rtctl
description: Build, run, test, and extend the rtctl remote terminal control system (Go server + agent + client with clientd HTTP service). Covers the three-component topology plus the clientd REST API for AI agents, chunked file transfer protocol, Machine Client Contract (completion/truncation/error-code semantics), Windows-specific execution pitfalls, and the end-to-end smoke-test procedure used to verify fixes.
---

# rtctl — 远程终端控制系统

rtctl 是一个 Go 实现的远程终端控制系统：**server**（中继）+ **agent**（被控端，主动拨出，可穿透 NAT）+ **client**（控制端 CLI，含 `serve` 子命令——常驻 HTTP 服务供 AI Agent 直控）。
执行模型：`exec` 一次性命令（完成帧 + 退出码）、`shell` 交互终端（Linux 真 PTY / Windows cmd 管道）、`file-put/file-get` 分片文件传输。设备以 token 寻址：持有设备 token 即拥有该设备 shell 权限。

## 目录与分层

```
rtctl/
├── cmd/server        # HTTP(S)/WebSocket 入口，flag 解析
├── cmd/agent         # 被控端入口
├── cmd/client        # CLI：main.go(list/exec/shell) + file.go(文件传输) + serve.go(clientd HTTP 服务)
├── deploy.sh/.ps1    # 一键部署唯一入口（server/agent/client/clientd/update 五模式）
└── internal/
    ├── proto         # 消息外壳 + 各 payload + 错误码常量（协议唯一定义处）
    ├── server        # hub(路由/在途绑定) conn(读写泵/背压) server(Origin) audit
    ├── agent         # 连接生命周期 + exec/shell/file 执行器（linux/windows 分文件）
    └── idutil        # 消息/会话/传输 ID
```

平台拆分约定（`//go:build` 标签）：`shell_linux.go` / `shell_windows.go`（shell 会话实现）、`shell_exec_linux.go` / `shell_exec_windows.go`（exec argv 与进程树终止）。改执行逻辑时必须同时看两个平台文件。

## 构建

- 模块要求 `go >= 1.25.0`（`go.mod`）。本机 `go` 可能不在 PATH：可用 `D:\Test\go-sdk\go\bin\go.exe`；版本不足时 Go 会通过 GOTOOLCHAIN 自动下载（需网络）。
- 常用命令（在仓库根目录执行）：
  ```powershell
  & D:\Test\go-sdk\go\bin\go.exe build ./...        # 本机构建
  & D:\Test\go-sdk\go\bin\go.exe vet ./...          # 静态检查
  & D:\Test\go-sdk\go\bin\gofmt.exe -l <files>      # 格式检查（提交前必须为空）
  $env:GOOS='linux'; $env:GOARCH='amd64'; $env:CGO_ENABLED='0'; & D:\Test\go-sdk\go\bin\go.exe build ./...  # Linux 交叉构建（agent 仅支持 linux/windows）
  ```
- 单文件跨平台（`agent.go` 等）不得使用平台专属符号（如 `syscall.SysProcAttr.Setpgid`）；平台差异一律放 build-tag 文件里，否则交叉构建失败。
- `bin/` 下的提交二进制需与源码一致（用哈希比对）；改动后应重建。

## 运行与冒烟测试（验证修复的标准流程）

1. 构建：`go build -o .\smoke\server.exe ./cmd/server`（agent/client 同理）。
2. 起 server：`Start-Process .\smoke\server.exe -ArgumentList '-listen','127.0.0.1:18090','-devices','devices.json','-audit','smoke\audit.log' -WindowStyle Hidden -RedirectStandardOutput ... -RedirectStandardError ...`
3. 起 agent：`... '-server','ws://127.0.0.1:18090/ws?role=agent','-id','web-01','-token','change-me-web-01-token'`（token 来自 `devices.json`）。
4. 验证清单（每项都应有明确断言）：
   - `client list` / `client -json list`：设备在线 + 元数据（os/arch/hostname/version）。
   - `exec` 退出码透传：`exec 'exit /b 42'` → exit 42；`-workdir` 生效。
   - **嵌套引号**：`exec -c 'powershell -NoProfile -Command "1..5 | ForEach-Object { ''x'' }"'` 必须输出 5 行（历史 bug：cmd.exe 剥引号导致静默错误执行，修复靠 `SysProcAttr.CmdLine`）。
   - **超时杀进程树**：`exec -timeout 1000 'ping -n 10 127.0.0.1'` 应 ~1s 返回 `[执行超时]`（而非等 ping 跑完）。
   - **错误码**：错 token → `[bad_token]`；离线设备 → `[device_offline]`；同 ID 两客户端 → 后者 `[conflict]`。
   - **掉线通知**：exec 进行中杀 agent → 客户端很快收到 `[agent 掉线，执行中断]` 并退出（不得挂死）。
   - **注册拒绝**：错 token 的 agent 必须**立即退出**（不得无限重连）。
   - **JSON 模式**：`-json exec` 输出 `{"exit_code":...,"output":...,"truncated":...,"error_code":...,"duration_ms":...}`。
   - **stdin**：`-stdin-file f 'sort'` 输出排序后的输入。
   - **截断标记**：慢速消费者 + 大输出时，done 帧必须带 `truncated=true` 且可靠送达（可用 2ms/帧 的慢读 harness 模拟）。
   - **文件传输**：`file-put`/`file-get` 往返后哈希一致（用 >256KB 随机文件覆盖分片路径）；覆盖同名文件生效；不存在文件回 `not_found`。
   - **clientd**：`client serve -listen 127.0.0.1:18080 -devices devices.json -api-key test` 起服务后：`/healthz` 免认证 ok；无 key 401；`/api/v1/devices`、`/api/v1/exec`（退出码/超时）、`/api/v1/files/upload|download`（哈希一致）；并发 5 exec + 2 上传；杀中继 → 在途请求回 `connection_lost`、重启中继后 ~2s 自动恢复。
5. 收尾：`Stop-Process` 所有测试进程，删除 `smoke/` 测试产物（注意：本会话的 write 工具对已删除路径有缓存问题，重建文件请先用 `New-Item` 建目录或改用 pwsh `Set-Content`）。

## 协议契约（Machine Client Contract 要点）

完整契约见 `DESIGN.md` 第 11 节。关键不变量：

- **完成 = `done=true` 帧**；任何连接错误都表示结果未知（命令可能已执行），非幂等命令不得盲目重试。
- `truncated=true` = 输出被背压丢弃过，内容不可信。
- 错误码常量在 `internal/proto/proto.go`（`ErrorCode*`）：`bad_token`（配置错误勿重试）/ `device_offline`（可重试）/ `agent_lost`（结果未知）/ `timeout` / `killed` / `conflict` / `overload` / `start_failed`。
- 服务器路由不变量：在途 exec 绑定 `(id -> {client, agent})`，输出帧须同时匹配两者；agent 掉线 → 在途 exec 回 `agent_lost`；client 断开 → 在途 exec 被 exec_kill（无孤儿进程）。
- 背压：普通帧队列满即丢并在 done 帧标注 truncated；done 帧阻塞送达（5s），失败即断连；客户端持续不读会被服务端 10s 写超时切断并取消其 exec。

## 已知限制与坑（不要再踩）

- **Windows cmd 引号**：exec 必须走 `SysProcAttr.CmdLine` 的包裹式命令行（`windowsCmdLine`）。改动 `shellExecArgs` 时不要退回 `exec.Command("cmd","/C",s)` 默认 argv 引用（内层双引号会被剥掉）。
- **超时必须杀整树**：`TerminateProcess`/`Process.Kill` 只杀直接子进程，孙进程会继续持有管道导致读循环不结束。Linux 用 `Setpgid`+`kill(-pid)`，Windows 用 `taskkill /T /F`；且 ctx.Done 后要停止读循环。
- **注册拒绝送达竞态**：server 侧"先发错误再 close"必须用 `sendMsgBlocking` + `flushAndClose()`（writePump 排空队列后关闭）；直接 `close()` 会吞掉错误消息，agent 只能看到 EOF 而盲目重连。
- **agent 重连竞态**：每轮连接的 ws/发送队列必须是该轮局部资源（`a.mu` 保护交换，writePump 接收局部参数），旧连接的 goroutine 不得触碰新连接。
- **shell 注册竞态**：`handleShellOpen` 必须同步注册会话（不能放 goroutine 里），否则紧跟的 shell_data 会被静默丢弃。
- **file_put 注册竞态（实测踩过）**：`handleFilePut` 同样必须同步建临时文件并注册 `putFiles` 状态（不能在 goroutine 里），否则紧跟的分片查不到状态被静默丢弃、客户端永久等待 ack。凡"首消息建立状态 + 后续消息引用状态"的模式，建立必须同步。
- **文件数据不可静默丢弃**：exec 输出可以丢帧+打 truncated 标记，但文件分片丢失 = 文件损坏，必须走阻塞发送（agent/server 两端）。
- **Windows rename 语义**：`os.Rename` 不覆盖已存在目标，覆盖前先 `os.Remove`（仅 Windows）。
- **Windows 输出编码**：中文系统 cmd 输出是 GBK；agent 侧有启发式转码（UTF-8 有效则原样，否则 GBK 解码），分片边界切开多字节字符时该片回退原样——接受该不完美性。
- **慢消费者会被切断**（10s 写超时）——这是有意的保护行为，不是 bug；测试"截断标记"要用中速 drain（~2ms/帧），太慢会直接断连。
- `-race` 构建在 Windows 需要 cgo（gcc）；本机没有时改用功能性重连测试替代。
- 占位 token（`change-me-` 前缀）服务器只告警不拒绝——部署前必须更换。

## 修改检查清单

| 改动 | 必查 |
| --- | --- |
| 协议字段 | `proto.go` 常量 + agent/server/client 三端同步；旧客户端兼容性 |
| 路由逻辑 | 锁边界（`h.mu`）、execPend/putPend/getPend/sessions 清理路径（unregister 两个方向） |
| 执行逻辑 | 双平台文件；超时/取消路径；输出读循环的退出条件 |
| 文件传输 | 分片大小、大小上限、临时文件清理（abort/断线两路径）、阻塞送达 |
| clientd API | 认证中间件、pending 分发、断线 failAll、请求超时的 kill/abort |
| CLI 参数 | `usage()` 文案、README/DESIGN 配置表同步 |
| 任何改动 | `go build ./...` + `go vet ./...` + Linux 交叉构建 + gofmt + 冒烟清单 4 |
