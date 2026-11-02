# Changelog

本项目的重要变更记录在此文件中。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Changed

- 重写 README，补充开发说明、安全政策和变更记录。
- 架构文档移至 `docs/architecture.md`，移除过期设计草案、重复发布脚本和本地构建产物。

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

[Unreleased]: https://github.com/GotKiCry/rtctl/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/GotKiCry/rtctl/releases/tag/v1.0.0
