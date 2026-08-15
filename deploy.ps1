# ============================================================
# rtctl 一键部署脚本（唯一入口，Windows，管理员 PowerShell）
# ============================================================
# 用法:
#   ① 中心机（装中继服务器）:
#       .\deploy.ps1 -Mode Server -Port 8443 -Id web-01,db-01
#   ② 被控机（装 agent）:
#       .\deploy.ps1 -Mode Agent -ServerUrl 'wss://中继:8443/ws?role=agent' -Id win-web-01 -Token '<token>'
#   ③ 操作机（取 client）:
#       .\deploy.ps1 -Mode Client
#   ④ 操作机（常驻 HTTP 服务，AI Agent 调用入口）:
#       .\deploy.ps1 -Mode Clientd -ServerUrl 'wss://中继:8443/ws?role=client' -ClientKey '<密钥>' -Devices '.\devices.json'
#   ⑤ 升级: .\deploy.ps1 -Mode Update -Component server|agent|client|clientd
#
# 二进制来源: 本地 .\bin 优先；缺省自动从 GitHub 下载（私有仓库设 -GhToken）。
# 免下载直跑: irm https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.ps1 -OutFile deploy.ps1
# ============================================================

param(
    [Parameter(Mandatory=$true)][ValidateSet('Server','Agent','Client','Clientd','Update')][string]$Mode,
    [string]$ServerUrl,
    [string[]]$Id,
    [string]$Token,
    [int]$Port = 8443,
    [string]$ClientKey,
    [string]$Component,
    [string]$Devices,
    [string]$Listen = '127.0.0.1:18080',
    [string]$ApiKey,
    [string]$GhBase = 'https://raw.githubusercontent.com/GotKiCry/rtctl/main/bin',
    [string]$GhToken
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$InstallDir = 'C:\Program Files\rtctl'
$Arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'x86' }

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

function New-TaskXml([string]$ExePath, [string]$Args, [string]$Desc, [string]$EnvName, [string]$EnvValue) {
    $escArgs  = [System.Security.SecurityElement]::Escape($Args)
    $escDesc  = [System.Security.SecurityElement]::Escape($Desc)
    $escExe   = [System.Security.SecurityElement]::Escape($ExePath)
    $escName  = [System.Security.SecurityElement]::Escape($EnvName)
    $escValue = [System.Security.SecurityElement]::Escape($EnvValue)
    $envXml = if ($EnvName) {
        "      <EnvironmentVariables><Variable><Name>$escName</Name><Value>$escValue</Value></Variable></EnvironmentVariables>`n"
    } else { '' }
    return @"
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
}

function Install-Task([string]$TaskName, [string]$ExePath, [string]$Args, [string]$Desc, [string]$EnvName, [string]$EnvValue) {
    $xml = New-TaskXml $ExePath $Args $Desc $EnvName $EnvValue
    $xmlPath = Join-Path $env:TEMP "$TaskName.xml"
    [System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)
    schtasks /Create /TN $TaskName /XML $xmlPath /F | Out-Null
    Remove-Item $xmlPath -Force
    schtasks /Run /TN $TaskName | Out-Null
}

# ---------- ① Server ----------

if ($Mode -eq 'Server') {
    if (-not $Id) { throw "-Id 必填（逗号分隔设备 ID，如 -Id web-01,db-01）" }
    if (-not $ClientKey) { $ClientKey = New-Token }
    New-Item -ItemType Directory -Force -Path $InstallDir, (Join-Path $InstallDir 'etc') | Out-Null
    $bin = Get-Bin 'server.exe'
    Copy-Item $bin (Join-Path $InstallDir 'server.exe') -Force

    $tokens = @()
    $devices = @()
    foreach ($dev in $Id) {
        $tk = New-Token
        $tokens += "设备 $dev 的 token: $tk"
        $devices += "{ `"id`": `"$dev`", `"token`": `"$tk`" }"
    }
    $devicesJson = '{ "devices": [ ' + ($devices -join ', ') + ' ] }'
    $devicesPath = Join-Path $InstallDir 'devices.json'
    [System.IO.File]::WriteAllText($devicesPath, $devicesJson, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $InstallDir 'tokens.txt'),
        ($tokens -join "`r`n") + "`r`n客户端密钥: $ClientKey", [System.Text.Encoding]::UTF8)

    Install-Task 'rtctl-server' (Join-Path $InstallDir 'server.exe') `
        "-listen `"0.0.0.0:$Port`" -devices `"$devicesPath`" -client-key `"$ClientKey`" -audit `"$InstallDir\audit.log`"" `
        'rtctl relay server' '' ''
    Start-Sleep -Seconds 2
    Write-Host "[rtctl] ================ 部署完成 ================"
    Write-Host "[rtctl] 服务器地址: ws://<本机IP>:$Port/ws   客户端密钥: $ClientKey"
    Write-Host "[rtctl] 设备 token 已保存: $InstallDir\tokens.txt"
    Write-Host "[rtctl] 防火墙放行: netsh advfirewall firewall add rule name=rtctl dir=in action=allow protocol=TCP localport=$Port"
    Write-Host "[rtctl] agent 部署命令见 deploy.sh server 输出或 deploy/README.md"
    Write-Host "[rtctl] ==========================================="
}

# ---------- ② Agent ----------

if ($Mode -eq 'Agent') {
    if (-not $Id -or -not $Token) { throw "-Id / -Token 必填" }
    $hasListen = $PSBoundParameters.ContainsKey('Listen')
    if (-not $ServerUrl -and -not $hasListen) { throw "-ServerUrl（中继模式）与 -Listen（直连模式）必须二选一" }
    $singleId = @($Id)[0]
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $bin = Get-Bin 'agent.exe'
    Copy-Item $bin (Join-Path $InstallDir 'agent.exe') -Force
    if ($hasListen) {
        Install-Task 'rtctl-agent' (Join-Path $InstallDir 'agent.exe') `
            "-listen `"$Listen`" -id `"$singleId`"" `
            "rtctl agent (standalone, device $singleId)" 'RTCTL_TOKEN' $Token
        $port = $Listen -replace '.*:', ''
        Write-Host "[rtctl] ✔ agent ($singleId) 直连模式已安装并启动：监听 $Listen（无需中继）"
        Write-Host "[rtctl]   防火墙放行: netsh advfirewall firewall add rule name=rtctl-agent dir=in action=allow protocol=TCP localport=$port"
        Write-Host "[rtctl]   验证: client.exe -server ws://<本机IP>:$port/ws exec -token $Token 'echo ok'"
    } else {
        Install-Task 'rtctl-agent' (Join-Path $InstallDir 'agent.exe') `
            "-server `"$ServerUrl`" -id `"$singleId`"" `
            "rtctl agent for device $singleId" 'RTCTL_TOKEN' $Token
        Write-Host "[rtctl] ✔ agent ($singleId) 已安装并启动（SYSTEM 账户，开机自启）"
        Write-Host "[rtctl]   验证: 操作机 client list 应看到设备在线"
    }
    Start-Sleep -Seconds 2
    Write-Host "[rtctl]   卸载: schtasks /Delete /TN rtctl-agent /F"
}

# ---------- ③ Client ----------

if ($Mode -eq 'Client') {
    $bin = Get-Bin 'client.exe'
    Write-Host "[rtctl] ✔ client 就绪: $bin"
    Write-Host "[rtctl]   用法: $bin -server wss://中继:8443/ws?role=client -key <客户端密钥> list"
}

# ---------- ③.5 Clientd：常驻 HTTP 服务（AI Agent 调用入口） ----------

if ($Mode -eq 'Clientd') {
    if (-not $ServerUrl -or -not $Devices -or -not (Test-Path $Devices)) { throw "-ServerUrl 与 -Devices <设备清单文件> 必填（文件需存在）" }
    if (-not $ApiKey) { $ApiKey = New-Token }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $bin = Get-Bin 'client.exe'
    Copy-Item $bin (Join-Path $InstallDir 'client.exe') -Force
    Copy-Item $Devices (Join-Path $InstallDir 'clientd-devices.json') -Force
    Install-Task 'rtctl-clientd' (Join-Path $InstallDir 'client.exe') `
        "-server `"$ServerUrl`" -key `"$ClientKey`" -client-id clientd serve -listen `"$Listen`" -devices `"$InstallDir\clientd-devices.json`" -api-key `"$ApiKey`"" `
        'rtctl client service (HTTP API for AI agents)' '' ''
    Start-Sleep -Seconds 2
    Write-Host "[rtctl] ✔ clientd 已启动并开机自启: http://$Listen"
    Write-Host "[rtctl]   API 密钥: $ApiKey（Authorization: Bearer $ApiKey）"
    Write-Host "[rtctl]   测试: Invoke-RestMethod http://$Listen/api/v1/devices -Headers @{Authorization='Bearer $ApiKey'}"
}

# ---------- ④ Update ----------

if ($Mode -eq 'Update') {
    if (-not $Component) { throw "Update 模式需要 -Component server|agent|client" }
    switch ($Component.ToLower()) {
        'server'  { $bin = Get-Bin 'server.exe'; Copy-Item $bin (Join-Path $InstallDir 'server.exe') -Force; schtasks /End /TN rtctl-server | Out-Null; schtasks /Run /TN rtctl-server | Out-Null; Write-Host '[rtctl] ✔ server 已更新并重启' }
        'agent'   { $bin = Get-Bin 'agent.exe';  Copy-Item $bin (Join-Path $InstallDir 'agent.exe') -Force; schtasks /End /TN rtctl-agent | Out-Null;  schtasks /Run /TN rtctl-agent | Out-Null;  Write-Host '[rtctl] ✔ agent 已更新并重启' }
        'clientd' { $bin = Get-Bin 'client.exe'; Copy-Item $bin (Join-Path $InstallDir 'client.exe') -Force; schtasks /End /TN rtctl-clientd | Out-Null; schtasks /Run /TN rtctl-clientd | Out-Null; Write-Host '[rtctl] ✔ clientd 已更新并重启' }
        'client'  { $bin = Get-Bin 'client.exe'; Write-Host "[rtctl] ✔ client 已更新: $bin" }
        default   { throw "未知组件 $Component" }
    }
}
