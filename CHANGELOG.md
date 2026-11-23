# Changelog

本项目的重要变更记录在此文件中。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- 安装和升级支持 `--dev` 选择 GitHub 预发行版，`--stable` 切回稳定渠道，`--release TAG` 可固定测试版本。

### Fixed

- 后台升级提示实际日志位置，并显示与安装范围匹配的版本检查命令。使用 `rt upgrade --wait` 可在当前终端查看升级结果。
- 覆盖安装和升级在下载、校验通过后才停止旧服务。升级在备份旧版 agent 后执行，恢复二进制、重启和健康检查都成功才记为已回滚。

- 修复健康检查未绕过 `http_proxy`/`HTTP_PROXY`：带代理的机器上 curl/wget 会把 `127.0.0.1` 的探活请求发给代理，造成 agent 正常却安装失败（exit 9）；curl 加 `--noproxy '*'`，wget 加 `no_proxy`。
- 修复 `rt_open_tty` 在严格 POSIX sh（dash、`bash --posix`）且无控制终端（`curl | sh`、ssh 未加 `-t`、cron、CI）时，`exec 3</dev/tty` 重定向错误直接杀死非交互 shell，脚本零输出退出；改用非特殊内建先探测再持有。
- 修复 `rt enable` 在 systemd/openrc 下成功后仍误报"无法设置开机自启"：`svc_enable` 成功后未更新 `RT_AUTOSTART`，状态文件记录与实际不符。
- 修复 `rt doctor` 权限检查不区分安装范围：用户级安装的 `600 <用户>:<组>` 被按系统级 `600 rtctl:rtctl` 误报；期望值现按 scope 生成。

### Changed

- 安装、连接引导和自检提供只读防火墙检查与手工配置提示。安装器、agent 和卸载器均不修改系统的防火墙规则。

- `rtctl-agent -status` 默认显示当前设备 token，可通过 `-print-token=false` 隐藏，手工部署无需再直接读取配置文件。
- 精简 Linux 安装、管理命令及客户端/agent 输出，实现细节移至 `--verbose`，帮助页按使用场景组织。
- 修正临时 sudo 示例缺少 `-sudo-ask`、客户端下载命令缺少 `./` 的提示，并明确明文连接下的 root 密码风险。

## [1.0.1] - 2026-11-03

### Changed

- 重写 README，补充开发说明、安全政策和变更记录。
- 架构文档移至 `docs/architecture.md`，移除过期设计草案、重复发布脚本和本地构建产物。

### Fixed

- 修复 Windows exec 超时/取消时双重终止导致子进程残留和结果延迟，以及正常退出后按旧 PID 误清理的风险；Windows exec 与 shell 统一使用 Job Object 管理进程树。

### Upgrade notes

本次更新不改变配置文件或 WebSocket 协议。Linux 可通过 `rt upgrade` 或新版安装脚本升级；Windows 请替换 `rtctl-agent.exe` 并重启 Agent 实例，使进程树清理修复生效。

`v1.0.1` 的 `install.sh` SHA256：

```text
150482777c3a6669ccbf957ce1a743143595051cc13fd550f447b47fa0fac674
```

## [1.0.0] - 2026-11-02

### Added

- Linux 一键安装与管理脚本 `install.sh`，安装后的命令为 `rt`。
- Linux amd64/arm64 和 Windows amd64 的 agent、client 发布资产。
- systemd、OpenRC、nohup 服务托管，以及系统级和用户级安装。
- agent 默认后台启动、启动就绪通知、PID 文件、`-status` 和 `-stop`。
- `-foreground` 前台模式，供调试和服务管理器使用。
- 自管理日志、约 10MB 轮转、3 个备份，以及 `-logs` 尾部查看和跟随。
- 日志事件着色、token/私钥脱敏和 Windows 控制台支持。
- TLS、WebSocket 路径前缀、nginx/Caddy 反向代理和两层 sudo 授权。
- 升级健康检查、原子替换、失败回滚，以及升级时同步管理脚本和服务单元。

### Changed

- 直连服务支持在预先绑定的 listener 上启动，并正确处理正常关闭。
- 无 root 或免密 sudo 时不修改防火墙，仅检查端口连通性。
- 发布脚本统一注入版本号，安装脚本不再硬编码历史版本。
- `golang.org/x/sys` 调整为直接依赖。

### Fixed

- 发布校验清单统一为 LF 和纯文件名，同时兼容 Git Bash 生成的 `*filename` 格式。
- 升级时使用目标 Release 的管理脚本，避免保留正在执行的旧脚本。
- 回滚时按旧二进制支持的能力重新生成服务单元。

### Upgrade notes

早期版本的服务单元缺少 `-foreground`。从这些版本或误发的高版本覆盖到 `v1.0.0` 时，必须使用新版 `install.sh` 完成覆盖安装，不要直接使用旧版 `rt upgrade`。覆盖安装保留配置和 token。

`v1.0.0` 的 `install.sh` SHA256：

```text
86a57c830b6bd12f66464891b33ac28e10ed2877e0383e887e3baeeed106a70f
```

[Unreleased]: https://github.com/GotKiCry/rtctl/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/GotKiCry/rtctl/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/GotKiCry/rtctl/releases/tag/v1.0.0
