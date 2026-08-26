# push-release.ps1 —— 一键推送代码 + 创建 GitHub Release（附件发二进制）
# 用法：在能联网、已登录 GitHub 的电脑上，进入仓库目录后执行：
#   pwsh ./push-release.ps1
# 需要：git 已配置凭据（或弹窗登录），或已装 gh CLI（gh auth login 过）。
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Version = 'v3.2.0'
$Assets = @(
  (Join-Path $PSScriptRoot 'bin/rtctl.exe'),
  (Join-Path $PSScriptRoot 'bin/rtctl-agent.exe'),
  (Join-Path $PSScriptRoot 'bin/rtctl-linux-amd64'),
  (Join-Path $PSScriptRoot 'bin/rtctl-agent-linux-amd64'),
  (Join-Path $PSScriptRoot 'bin/rtctl-linux-arm64'),
  (Join-Path $PSScriptRoot 'bin/rtctl-agent-linux-arm64'),
  (Join-Path $PSScriptRoot 'bin/SHA256SUMS.txt')
)

Write-Host '== 1/3 推送代码与 tag ==' -ForegroundColor Cyan
git push origin main --tags
if ($LASTEXITCODE -ne 0) { throw 'git push 失败：请检查网络 / 登录（git credential manager 会弹窗）' }

$assetsOk = $true
foreach ($a in $Assets) { if (-not (Test-Path $a)) { Write-Warn "缺少资产: $a（先在本机跑过 build.ps1？）"; $assetsOk = $false } }
if (-not $assetsOk) { throw '资产不全，先执行：pwsh ./build.ps1' }

Write-Host '== 2/3 创建 Release ==' -ForegroundColor Cyan
if (Get-Command gh -ErrorAction SilentlyContinue) {
  gh release create $Version $Assets --title 'rtctl v3.2.0 — 精简直连版' --notes-file (Join-Path $PSScriptRoot 'RELNOTES.md') --target main
  if ($LASTEXITCODE -ne 0) { throw 'gh release create 失败（试试 gh auth login）' }
  Write-Host '✔ Release 创建完成：' -ForegroundColor Green
  Write-Host '  https://github.com/GotKiCry/rtctl/releases/tag/' + $Version
} else {
  Write-Host '没装 gh CLI，请用网页手动创建（都一样快）：' -ForegroundColor Yellow
  Write-Host '  1. 打开 https://github.com/GotKiCry/rtctl/releases/new'
  Write-Host '  2. 选 tag: ' + $Version
  Write-Host "  3. 标题: rtctl $Version — 精简直连版"
  Write-Host '  4. Notes: 粘贴 RELNOTES.md 内容'
  Write-Host "  5. 把 bin/ 目录下 5 个文件拖进 Assets"
  Write-Host '  6. Publish release'
}

Write-Host '== 3/3 完成 ==' -ForegroundColor Cyan
Write-Host '下载直链示例（发布后可用）：'
Write-Host "  https://github.com/GotKiCry/rtctl/releases/download/$Version/rtctl-agent"
Write-Host "  https://github.com/GotKiCry/rtctl/releases/download/$Version/rtctl"
