# build.ps1 —— 构建 rtctl / rtctl-agent（Windows + Linux 静态二进制）+ install.sh + SHA256SUMS
# 运行：pwsh ./build.ps1 [-Version v3.3.0]（需 Go 1.25+；版本缺省取 git describe）
param([string]$Version = '')
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$root = $PSScriptRoot
$out = Join-Path $root 'bin'
New-Item -ItemType Directory -Force -Path $out | Out-Null

if (-not $Version) {
  $Version = (git describe --tags --always --dirty 2>$null)
  if (-not $Version) { $Version = 'v0.0.0-dev' }
}
$Version = $Version.Trim()
Write-Host "版本: $Version" -ForegroundColor Cyan

$env:CGO_ENABLED = '0'
# 版本注入：agent 用 internal/agent.Version，client 用 main.version
$ld = "-s -w -X rtctl/internal/agent.Version=$Version -X main.version=$Version"

$targets = @(
  @{ os = 'windows'; arch = 'amd64' },
  @{ os = 'linux';   arch = 'amd64' },
  @{ os = 'linux';   arch = 'arm64' }
)

foreach ($t in $targets) {
  $env:GOOS = $t.os
  $env:GOARCH = $t.arch
  # Windows 用 rtctl.exe / rtctl-agent.exe；Linux 带架构后缀（amd64/arm64 不互相覆盖）
  $suffix = if ($t.os -eq 'windows') { '' } else { "-$($t.os)-$($t.arch)" }
  $ext = if ($t.os -eq 'windows') { '.exe' } else { '' }
  & go build -trimpath -ldflags $ld -o (Join-Path $out ("rtctl" + $suffix + $ext)) ./cmd/client
  if ($LASTEXITCODE -ne 0) { throw "build rtctl ($($t.os)/$($t.arch)) failed" }
  & go build -trimpath -ldflags $ld -o (Join-Path $out ("rtctl-agent" + $suffix + $ext)) ./cmd/agent
  if ($LASTEXITCODE -ne 0) { throw "build rtctl-agent ($($t.os)/$($t.arch)) failed" }
  Write-Host "built: rtctl$suffix$ext / rtctl-agent$suffix$ext  ($($t.os)/$($t.arch))"
}

# ---- install.sh：复制仓库根脚本并注入版本号（Release 资产之一，也是 README 一行自举的目标）----
$installSrc = Join-Path $root 'install.sh'
if (-not (Test-Path $installSrc)) { throw '缺少 install.sh（应在仓库根）' }
$script = [IO.File]::ReadAllText($installSrc)
$script = $script.Replace("`r`n", "`n")                      # 强制 LF
$script = $script -replace '@@RTCTL_VERSION@@', $Version
if ($script -match '@@') { throw 'install.sh 仍有未替换的 @@ 占位符' }
$utf8NoBom = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $out 'install.sh'), $script, $utf8NoBom)
Write-Host "built: install.sh ($Version)" -ForegroundColor Green

# ---- SHA256SUMS.txt：必须 LF（Linux 端 sha256sum -c / awk 才不会把 \r 当文件名）----
$lines = Get-ChildItem $out -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object Name | ForEach-Object {
  $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
  "$h  $($_.Name)"
}
$sumsPath = Join-Path $out 'SHA256SUMS.txt'
[IO.File]::WriteAllText($sumsPath, (($lines -join "`n") + "`n"), (New-Object Text.ASCIIEncoding))
$bytes = [IO.File]::ReadAllBytes($sumsPath)
if ($bytes -contains 13) { throw 'SHA256SUMS.txt 含 CR，必须是 LF' }
Write-Host "SHA256SUMS.txt written ($($lines.Count) entries, LF)" -ForegroundColor Green
Write-Host "提示：发布前核对 install.sh 的 sha256 并写进 RELNOTES（README 的 --pinned-sha256 用它）" -ForegroundColor Yellow
