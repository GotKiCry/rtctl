# ============================================================
# rtctl 一键部署脚本（唯一入口，Windows，纯直连版，管理员 PowerShell）
# ============================================================
# 用法:
#   ① 被控机（装 agent，自带监听）:
#       .\deploy.ps1 -Mode Agent -Listen ':8443' -Id win-web-01 -Token '<token>'
#   ② 操作机（装 clientd，AI Agent 直控入口）:
#       .\deploy.ps1 -Mode Clientd -Devices '.\devices.json'
#   ③ 操作机（取 client）:
#       .\deploy.ps1 -Mode Client
#   ④ 升级: .\deploy.ps1 -Mode Update -Component agent|client|clientd
#
# 二进制来源: 本地 .\bin 优先；缺省自动从 GitHub 下载（私有仓库设 -GhToken）。
# 免下载直跑: irm https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.ps1 -OutFile deploy.ps1
# ============================================================

param(
    [Parameter(Mandatory=$true)][ValidateSet('Agent','Clientd','Client','Update')][string]$Mode,
    [string]$Listen,
    [string[]]$Id,
    [string]$Token,
    [string]$Component,
    [string]$Devices,
    [string]$HttpListen = '127.0.0.1:18080',
    [string]$ApiKey,
    [string]$GhBase = 'https://raw.githubusercontent.com/GotKiCry/rtctl/main/bin',
    [string]$GhToken
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$InstallDir = 'C:\Program Files\rtctl'

function Get-Bin([string]$Name) {
    $local = Join-Path $PSScriptRoot "bin\$Name"
    if (Test-Path $local) { return $local }
    Write-Host "[rtctl] 下载 $Name ..."
    $headers = @{}
    if ($GhToken) { $headers['Authorization'] = "Bearer $GhToken" }
    $tmp = Join-Path $env:TEMP "$Name.tmp"
    Invoke-WebRequest -Uri "$GhBase/$Name" -Headers $headers -OutFile $tmp -UseBasicParsing
    $bytes = [System.IO.File]::ReadAllBytes($tmp)
    $magic = if ($bytes.Length -gt 2) { $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A } else { $false }
    if (-not $magic) { Remove-Item $tmp -Force; throw "$Name 不是有效的 Windows 可执行文件" }
    New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'bin') | Out-Null
    Move-Item $tmp $local -Force
    return $local
}

function New-Token {
    $b = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($b)
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Install-Task([string]$TaskName, [string]$ExePath, [string]$Args, [string]$Desc, [string]$EnvName, [string]$EnvValue) {
    $escArgs  = [System.Security.SecurityElement]::Escape($Args)
    $escDesc  = [System.Security.SecurityElement]::Escape($Desc)
    $escExe   = [System.Security.SecurityElement]::Escape($ExePath)
    $escName  = [System.Security.SecurityElement]::Escape($EnvName)
    $escValue = [System.Security.SecurityElement]::Escape($EnvValue)
    $envXml = if ($EnvName) {
        "      <EnvironmentVariables><Variable><Name>$escName</Name><Value>$escValue</Value></Variable></EnvironmentVariables>`n"
    } else { '' }
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$escDesc</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers>
  <Principals>
    <Principal id="Author"><UserId>S-1-5-18</UserId><LogonType>ServiceAccount</LogonType><RunLevel>HighestAvailable</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>"$escExe"</Command>
      <Arguments>$escArgs</Arguments>
$envXml    </Exec>
  </Actions>
</Task>
"@
    $xmlPath = Join-Path $env:TEMP "$TaskName.xml"
    [System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)
    schtasks /Create /TN $TaskName /XML $xmlPath /F | Out-Null
    Remove-Item $xmlPath -Force
    schtasks /Run /TN $TaskName | Out-Null
}

# ---------- ① Agent ----------

if ($Mode -eq 'Agent') {
    if (-not $Listen -or -not $Id -or -not $Token) { throw "-Listen / -Id / -Token 必填" }
    $singleId = @($Id)[0]
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $bin = Get-Bin 'agent.exe'
    Copy-Item $bin (Join-Path $InstallDir 'rtctl-agent.exe') -Force
    Install-Task 'rtctl-agent' (Join-Path $InstallDir 'rtctl-agent.exe') `
        "-listen `"$Listen`" -id `"$singleId`"" `
        "rtctl agent (device $singleId)" 'RTCTL_TOKEN' $Token
    $port = $Listen -replace '.*:', ''
    Write-Host "[rtctl] ✔ agent ($singleId) 已安装并启动：监听 $Listen（开机自启，SYSTEM 账户）"
    Write-Host "[rtctl]   防火墙放行: netsh advfirewall firewall add rule name=rtctl-agent dir=in action=allow protocol=TCP localport=$port"
    Write-Host "[rtctl]   验证: client.exe -server ws://<本机IP>:$port/ws exec -token $Token 'echo ok'"
    Write-Host "[rtctl]   卸载: schtasks /Delete /TN rtctl-agent /F"
}

# ---------- ② Clientd ----------

if ($Mode -eq 'Clientd') {
    if (-not $Devices -or -not (Test-Path $Devices)) { throw "-Devices <设备清单文件> 必填（每条设备带 url 直连地址）" }
    if (-not $ApiKey) { $ApiKey = New-Token }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $bin = Get-Bin 'client.exe'
    Copy-Item $bin (Join-Path $InstallDir 'rtctl-client.exe') -Force
    Copy-Item $Devices (Join-Path $InstallDir 'clientd-devices.json') -Force
    Install-Task 'rtctl-clientd' (Join-Path $InstallDir 'rtctl-client.exe') `
        "-client-id clientd serve -listen `"$HttpListen`" -devices `"$InstallDir\clientd-devices.json`" -api-key `"$ApiKey`"" `
        'rtctl client service (HTTP API for AI agents)' '' ''
    Write-Host "[rtctl] ✔ clientd 已安装并启动: http://$HttpListen（开机自启）"
    Write-Host "[rtctl]   API 密钥: $ApiKey（Authorization: Bearer $ApiKey）"
    Write-Host "[rtctl]   测试: Invoke-RestMethod http://$HttpListen/api/v1/devices -Headers @{Authorization='Bearer $ApiKey'}"
}

# ---------- ③ Client ----------

if ($Mode -eq 'Client') {
    $bin = Get-Bin 'client.exe'
    Write-Host "[rtctl] ✔ client 就绪: $bin"
    Write-Host "[rtctl]   用法: $bin -server ws://<设备IP>:<端口>/ws exec -token <设备token> 'uptime'"
}

# ---------- ④ Update ----------

if ($Mode -eq 'Update') {
    if (-not $Component) { throw "Update 模式需要 -Component agent|client|clientd" }
    switch ($Component.ToLower()) {
        'agent'   { $bin = Get-Bin 'agent.exe';  Copy-Item $bin (Join-Path $InstallDir 'rtctl-agent.exe') -Force; schtasks /End /TN rtctl-agent | Out-Null;  schtasks /Run /TN rtctl-agent | Out-Null;  Write-Host '[rtctl] ✔ agent 已更新并重启' }
        'clientd' { $bin = Get-Bin 'client.exe'; Copy-Item $bin (Join-Path $InstallDir 'rtctl-client.exe') -Force; schtasks /End /TN rtctl-clientd | Out-Null; schtasks /Run /TN rtctl-clientd | Out-Null; Write-Host '[rtctl] ✔ clientd 已更新并重启' }
        'client'  { $bin = Get-Bin 'client.exe'; Write-Host "[rtctl] ✔ client 已更新: $bin" }
        default   { throw "未知组件 $Component" }
    }
}
