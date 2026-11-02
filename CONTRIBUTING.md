# 开发说明

这份文档记录本地开发、测试和发布流程，方便需要修改源码时参考。

## 问题反馈

可以通过 GitHub Issues 反馈问题，但不承诺固定的响应时间。缺陷报告最好包含：

- 操作系统、CPU 架构和 rtctl 版本（`rtctl -version`、`rtctl-agent -version`）
- 安装方式、复现步骤、预期结果和实际结果
- 相关日志及最小复现命令

**提交前必须删除 token、密码、私钥、内部地址和其他敏感信息。** 安全漏洞不要提交公开 Issue，请按 [SECURITY.md](SECURITY.md) 私下报告。

## 本地开发

### 环境要求

- Go 1.25 或更高版本
- Linux/macOS 的 POSIX shell，或 Windows PowerShell 7
- 修改安装脚本时，需要可用的 Linux 测试环境

### 常用命令

```bash
# 格式化和测试
gofmt -w <修改过的 Go 文件>
go test ./...

# 脚本语法检查
sh -n install.sh
sh -n build.sh

# 构建全部发布产物
sh ./build.sh                 # Linux / macOS
pwsh ./build.ps1              # Windows

# 校验构建产物
cd bin && sha256sum -c SHA256SUMS.txt
```

`bin/`、Go 缓存、日志和测试临时文件均为本地产物，不要提交。

## 修改与验证清单

- Go 代码遵循现有命名、包结构和错误处理方式，并为行为变更补充测试。
- Shell 代码保持 POSIX `sh` 兼容，只使用 `set -eu`，不要引入 `pipefail`、数组或 `[[ ]]`。
- 跨平台行为同时考虑 Linux 和 Windows，不因为某平台常用而随意新增依赖。
- 安装或服务行为变更后，验证安装、启动、日志、停止及适用的升级路径。
- 更新受影响的 README、架构说明和 CHANGELOG，避免保留旧命令或旧行为。
- 不提交真实 token、证书私钥、服务器配置或远程测试产生的文件。
- 每次变更保持聚焦，不混入无关格式化或文件调整。

## 作者发布流程

1. 更新 `CHANGELOG.md`，确认版本号、升级说明和兼容性事项。
2. 运行完整测试、脚本语法检查和构建。
3. 使用明确版本构建，例如 `sh ./build.sh v1.0.0`。
4. 在 `bin/` 执行 `sha256sum -c SHA256SUMS.txt`，确认 7 个资产全部通过。
5. 提交并推送代码，创建带注释的版本标签。
6. 用 GitHub CLI 发布 6 个二进制、`install.sh` 和 `SHA256SUMS.txt`，并将对应 CHANGELOG 小节及 `install.sh` 哈希写入 Release 说明。
7. 从 GitHub 重新下载资产并复验，再在测试机执行真实安装或升级。
8. 发布后删除本地临时文件；`bin/` 不上传为源码文件，资产只附在 Release 中。

不要为测试随意推送高版本标签或覆盖已发布资产。版本一旦发布，应通过新版本修复问题，而不是复用旧标签。
