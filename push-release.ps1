# push-release.ps1 —— 一键推送代码 + 创建 GitHub Release（附件含二进制、install.sh、SHA256SUMS）
# 用法：pwsh ./push-release.ps1 -Version v1.0.0
# 需要：git 已配置凭据（或弹窗登录），或已装 gh CLI（gh auth login 过）。
param([string]$Version = '')
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not $Version) {
  $Version = (git describe --tags --exact-match 2>$null)
  if (-not $Version) {
    throw '未指定版本且当前提交无 tag：请用 pwsh ./push-release.ps1 -Version v1.0.0'
  }
  $Version = $Version.Trim()
}
Write-Host "发布版本: $Version" -ForegroundColor Cyan

$Assets = @(
  (Join-Path $PSScriptRoot 'bin/rtctl.exe'),
  (Join-Path $PSScriptRoot 'bin/rtctl-agent.exe'),
  (Join-Path $PSScriptRoot 'bin/rtctl-linux-amd64'),
  (Join-Path $PSScriptRoot 'bin/rtctl-agent-linux-amd64'),
  (Join-Path $PSScriptRoot 'bin/rtctl-linux-arm64'),
  (Join-Path $PSScriptRoot 'bin/rtctl-agent-linux-arm64'),
  (Join-Path $PSScriptRoot 'bin/install.sh'),
  (Join-Path $PSScriptRoot 'bin/SHA256SUMS.txt')
)

Write-Host '== 1/4 检查资产 ==' -ForegroundColor Cyan
$missing = @()
foreach ($a in $Assets) { if (-not (Test-Path $a)) { $missing += $a } }
if ($missing.Count -gt 0) {
  Write-Host '缺少以下资产，请先执行：pwsh ./build.ps1' -ForegroundColor Red
  $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  throw '资产不全'
}
Write-Host ("资产齐全：{0} 个" -f $Assets.Count) -ForegroundColor Green

Write-Host '== 2/4 计算 install.sh 的 sha256（写进 RELNOTES / release 正文）==' -ForegroundColor Cyan
$installHash = (Get-FileHash (Join-Path $PSScriptRoot 'bin/install.sh') -Algorithm SHA256).Hash.ToLower()
Write-Host "  install.sh sha256 = $installHash" -ForegroundColor Yellow
Write-Host '  把这一行补进 RELNOTES.md 与 release 正文（README 的 --pinned-sha256 用它）' -ForegroundColor Yellow

Write-Host '== 3/4 推送代码与 tag ==' -ForegroundColor Cyan
git push origin main --tags
if ($LASTEXITCODE -ne 0) { throw 'git push 失败：请检查网络 / 登录（git credential manager 会弹窗）' }

Write-Host '== 4/4 创建 Release ==' -ForegroundColor Cyan
if (Get-Command gh -ErrorAction SilentlyContinue) {
  gh release create $Version $Assets --title "rtctl $Version" --notes-file (Join-Path $PSScriptRoot 'RELNOTES.md') --target main
  if ($LASTEXITCODE -ne 0) { throw 'gh release create 失败（试试 gh auth login）' }
  Write-Host '✔ Release 创建完成：' -ForegroundColor Green
  Write-Host '  https://github.com/GotKiCry/rtctl/releases/tag/' + $Version
  Write-Host '  一行安装命令（README 用这个）：' -ForegroundColor Green
  Write-Host ('  curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh -o /tmp/rt-install.sh && sudo sh /tmp/rt-install.sh')
} else {
  Write-Host '没装 gh CLI，请用网页手动创建：' -ForegroundColor Yellow
  Write-Host '  1. 打开 https://github.com/GotKiCry/rtctl/releases/new'
  Write-Host "  2. 选 tag: $Version"
  Write-Host "  3. 标题: rtctl $Version"
  Write-Host '  4. Notes: 粘贴 RELNOTES.md 内容（务必含 install.sh sha256 那一行）'
  Write-Host ("  5. 把 bin/ 目录下 {0} 个文件全部拖进 Assets" -f $Assets.Count)
  Write-Host '  6. Publish release'
}
