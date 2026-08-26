# build.ps1 —— 构建 rtctl / rtctl-agent（Windows + Linux 静态二进制）+ SHA256SUMS
# 运行：pwsh ./build.ps1（需 Go >= 1.25）
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$out = Join-Path $root 'bin'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$env:CGO_ENABLED = '0'

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
  & go build -trimpath -ldflags '-s -w' -o (Join-Path $out ("rtctl" + $suffix + $ext)) ./cmd/client
  if ($LASTEXITCODE -ne 0) { throw "build rtctl ($($t.os)/$($t.arch)) failed" }
  & go build -trimpath -ldflags '-s -w' -o (Join-Path $out ("rtctl-agent" + $suffix + $ext)) ./cmd/agent
  if ($LASTEXITCODE -ne 0) { throw "build rtctl-agent ($($t.os)/$($t.arch)) failed" }
  Write-Host "built: rtctl$suffix$ext / rtctl-agent$suffix$ext  ($($t.os)/$($t.arch))"
}

$lines = Get-ChildItem $out -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object Name | ForEach-Object {
  $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
  "$h  $($_.Name)"
}
Set-Content -Path (Join-Path $out 'SHA256SUMS.txt') -Value $lines -Encoding ascii
Write-Host "SHA256SUMS.txt written ($($lines.Count) entries)"
