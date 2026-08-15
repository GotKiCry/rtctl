# ============================================================
# rtctl 一键部署脚本（Windows，纯直连版，v2ray-agent 风格交互菜单）
# ============================================================
# 一条指令直达菜单（管理员 PowerShell）:
#   irm https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.ps1 -OutFile deploy.ps1
#   .\deploy.ps1
#
# 无参数运行进入交互菜单（安装 / 状态 / 升级 / 卸载 / 退出）；
# 也支持非交互模式（脚本化）:
#   .\deploy.ps1 -Mode Agent    -Listen ':8443' -Id win-web-01 -Token '<token>'
#   .\deploy.ps1 -Mode Clientd  -Devices '.\devices.json'
#   .\deploy.ps1 -Mode Client
#   .\deploy.ps1 -Mode Status
#   .\deploy.ps1 -Mode Info
#   .\deploy.ps1 -Mode Update   -Component agent|clientd
#   .\deploy.ps1 -Mode Uninstall -Component agent|clientd|all
# ============================================================

param(
    [ValidateSet('Agent','Clientd','Client','Status','Info','Update','Uninstall')][string]$Mode,
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

function Ask-Token {
    Write-Host "  设备 token:"
    Write-Host "    [1] 自动生成高熵 token（推荐）"
    Write-Host "    [2] 手动输入"
    $c = Read-Host "  请选择 [1]"
    if ($c -eq '2') {
        $t = Read-Host "  请输入 token"
        if (-not $t) { throw 'token 不能为空' }
        return $t
    }
    return (New-Token)
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

function Install-Agent([string]$Listen, [string]$Id, [string]$Token) {
    if (-not $Listen -or -not $Id -or -not $Token) { throw "-Listen / -Id / -Token 必填" }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $bin = Get-Bin 'agent.exe'
    Copy-Item $bin (Join-Path $InstallDir 'rtctl-agent.exe') -Force
    Install-Task 'rtctl-agent' (Join-Path $InstallDir 'rtctl-agent.exe') `
        "-listen `"$Listen`" -id `"$Id`"" `
        "rtctl agent (device $Id)" 'RTCTL_TOKEN' $Token
    $port = $Listen -replace '.*:', ''
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1).IPAddress
    if (-not $ip) { $ip = '<本机IP>' }
    Write-Host "[rtctl] ✔ agent ($Id) 已安装并启动：监听 $Listen（后台运行 + 开机自启，SYSTEM 账户）"
    Write-Host "[rtctl]   防火墙放行: netsh advfirewall firewall add rule name=rtctl-agent dir=in action=allow protocol=TCP localport=$port"
    Write-Host "[rtctl]   验证: client.exe -server ws://$ip`:$port/ws exec -token $Token 'echo ok'"
    Write-Host "[rtctl]   clientd 设备清单片段:"
    Write-Host "[rtctl]     { `"devices`": [ { `"id`": `"$Id`", `"url`": `"ws://$ip`:$port/ws`", `"token`": `"$Token`" } ] }"
    Write-Host "[rtctl]   以后随时查看: .\deploy.ps1 -Mode Info（菜单选 4）"
}

function Install-Clientd([string]$Devices, [string]$HttpListen, [string]$ApiKey) {
    if (-not $Devices -or -not (Test-Path $Devices)) { throw "-Devices <设备清单文件> 必填（每条设备带 url 直连地址）" }
    if (-not $ApiKey) { $ApiKey = New-Token }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $bin = Get-Bin 'client.exe'
    Copy-Item $bin (Join-Path $InstallDir 'rtctl-client.exe') -Force
    Copy-Item $Devices (Join-Path $InstallDir 'clientd-devices.json') -Force
    Install-Task 'rtctl-clientd' (Join-Path $InstallDir 'rtctl-client.exe') `
        "-client-id clientd serve -listen `"$HttpListen`" -devices `"$InstallDir\clientd-devices.json`" -api-key `"$ApiKey`"" `
        'rtctl client service (HTTP API for AI agents)' '' ''
    Write-Host "[rtctl] ✔ clientd 已安装并启动: http://$HttpListen（后台运行 + 开机自启）"
    Write-Host "[rtctl]   API 密钥: $ApiKey（Authorization: Bearer $ApiKey）"
    Write-Host "[rtctl]   测试: Invoke-RestMethod http://$HttpListen/api/v1/devices -Headers @{Authorization='Bearer $ApiKey'}"
    Write-Host "[rtctl]   以后随时查看: .\deploy.ps1 -Mode Info（菜单选 4）"
}

function Show-Info {
    Write-Host '================ 连接信息（直接复制） ================'
    $agentXml = schtasks /Query /TN rtctl-agent /XML 2>$null | Out-String
    if ($LASTEXITCODE -eq 0) {
        $argsLine = [regex]::Match($agentXml, '<Arguments>(.*?)</Arguments>').Groups[1].Value
        $listen = [regex]::Match($argsLine, '-listen &quot;([^&]+)&quot;').Groups[1].Value
        $id     = [regex]::Match($argsLine, '-id &quot;([^&]+)&quot;').Groups[1].Value
        $token  = [regex]::Match($agentXml, '<Name>RTCTL_TOKEN</Name>\s*<Value>(.*?)</Value>').Groups[1].Value
        $port = $listen -replace '.*:', ''
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -First 1).IPAddress
        if (-not $ip) { $ip = '<本机IP>' }

        Write-Host "  设备 ID:   $id"
        Write-Host "  监听地址: $listen"
        Write-Host "  token:     $token"
        Write-Host ''
        Write-Host '  ── clientd 设备清单片段（复制到控制机 devices.json 即可直连）──'
        Write-Host "  { `"devices`": [ { `"id`": `"$id`", `"url`": `"ws://$ip`:$port/ws`", `"token`": `"$token`" } ] }"
        Write-Host ''
        Write-Host '  ── 验证命令（任意有 client 的机器）──'
        Write-Host "  client.exe -server ws://$ip`:$port/ws exec -token $token 'echo ok'"
    } else {
        Write-Host '[提示] agent 未安装（菜单选 1 先安装）'
    }

    $cdXml = schtasks /Query /TN rtctl-clientd /XML 2>$null | Out-String
    if ($LASTEXITCODE -eq 0) {
        $argsLine = [regex]::Match($cdXml, '<Arguments>(.*?)</Arguments>').Groups[1].Value
        $hl = [regex]::Match($argsLine, '-listen &quot;([^&]+)&quot;').Groups[1].Value
        $ak = [regex]::Match($argsLine, '-api-key &quot;([^&]+)&quot;').Groups[1].Value
        Write-Host ''
        Write-Host '  ── clientd（AI Agent 直控入口）──'
        Write-Host "  HTTP 地址: http://$hl"
        Write-Host "  API 密钥:  $ak"
        Write-Host "  调用示例: Invoke-RestMethod http://$hl/api/v1/exec -Method Post -Headers @{Authorization='Bearer $ak'} -Body (@{device_id='<设备ID>';cmd='echo ok'} | ConvertTo-Json)"
    }
    Write-Host '===================================================='
}

function Show-Status {
    Write-Host "rtctl 组件状态:"
    Write-Host ("  {0,-12} {1,-16} {2}" -f '组件','运行状态','开机自启')
    Write-Host '  --------------------------------------------'
    foreach ($t in 'rtctl-agent','rtctl-clientd') {
        $out = schtasks /Query /TN $t /FO LIST 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) {
            $st = '未安装'; $en = '未安装'
        } else {
            $st = if ($out -match '正在运行|Running') { '运行中' } elseif ($out -match '就绪|Ready') { '已就绪（未运行）' } else { '已安装' }
            $en = '已安装'
        }
        Write-Host ("  {0,-12} {1,-16} {2}" -f ($t -replace '^rtctl-',''),$st,$en)
    }
}

function Uninstall-Rtctl([string]$Comp) {
    if (-not $Comp) { $Comp = 'all' }
    foreach ($c in 'agent','clientd') {
        if ($Comp -ne 'all' -and $Comp -ne $c) { continue }
        schtasks /Delete /TN "rtctl-$c" /F 2>$null | Out-Null
        switch ($c) {
            'agent'   { Remove-Item (Join-Path $InstallDir 'rtctl-agent.exe') -Force -ErrorAction SilentlyContinue }
            'clientd' { Remove-Item (Join-Path $InstallDir 'rtctl-client.exe'), (Join-Path $InstallDir 'clientd-devices.json') -Force -ErrorAction SilentlyContinue }
        }
        Write-Host "[rtctl] ✔ $c 已卸载"
    }
}

function Update-Rtctl([string]$Comp) {
    switch ($Comp) {
        'agent'   { $bin = Get-Bin 'agent.exe';  Copy-Item $bin (Join-Path $InstallDir 'rtctl-agent.exe') -Force; schtasks /End /TN rtctl-agent | Out-Null;  schtasks /Run /TN rtctl-agent | Out-Null;  Write-Host '[rtctl] ✔ agent 已更新并重启' }
        'clientd' { $bin = Get-Bin 'client.exe'; Copy-Item $bin (Join-Path $InstallDir 'rtctl-client.exe') -Force; schtasks /End /TN rtctl-clientd | Out-Null; schtasks /Run /TN rtctl-clientd | Out-Null; Write-Host '[rtctl] ✔ clientd 已更新并重启' }
        default   { throw "未知组件 $Comp" }
    }
}

# ---------- 非交互模式 ----------

if ($Mode -eq 'Agent')     { Install-Agent $Listen (@($Id)[0]) $Token }
if ($Mode -eq 'Clientd')   { Install-Clientd $Devices $HttpListen $ApiKey }
if ($Mode -eq 'Client')    { $bin = Get-Bin 'client.exe'; Write-Host "[rtctl] ✔ client 就绪: $bin"; Write-Host "[rtctl]   用法: $bin -server ws://<设备IP>:<端口>/ws exec -token <token> 'uptime'" }
if ($Mode -eq 'Status')    { Show-Status }
if ($Mode -eq 'Info')      { Show-Info }
if ($Mode -eq 'Update')    { Update-Rtctl $Component }
if ($Mode -eq 'Uninstall') { Uninstall-Rtctl $Component }

# ---------- 交互菜单 ----------

if (-not $Mode) {
    while ($true) {
        Write-Host ''
        Write-Host '========================================'
        Write-Host '   rtctl 远程终端控制 — 管理菜单（纯直连）'
        Write-Host '========================================'
        Write-Host '  [1] 安装 agent（被控端）'
        Write-Host '  [2] 安装 clientd（AI Agent 直控服务）'
        Write-Host '  [3] 查看状态（运行 + 开机自启）'
        Write-Host '  [4] 查看连接信息（复制 token / 设备清单 / 验证命令）'
        Write-Host '  [5] 升级到最新版'
        Write-Host '  [6] 卸载组件'
        Write-Host '  [7] 退出'
        $choice = Read-Host '请选择 [7]'
        switch ($choice) {
            '1' {
                $id = Read-Host '设备 ID（唯一名称，如 jp-tokyo-01）'
                if (-not $id) { Write-Host '[提示] 设备 ID 不能为空'; continue }
                $p = Read-Host '监听端口 [8443]'
                $listen = ':' + $(if ($p) { $p } else { '8443' })
                $token = Ask-Token
                Install-Agent $listen $id $token
            }
            '2' {
                $devices = Read-Host '设备清单文件路径（每条设备带 url 直连地址）'
                if (-not (Test-Path $devices)) { Write-Host "[提示] 文件不存在: $devices"; continue }
                $l = Read-Host 'HTTP 监听地址 [127.0.0.1:18080]'
                $hl = if ($l) { $l } else { '127.0.0.1:18080' }
                Write-Host '  API 密钥: [1] 自动生成（推荐） [2] 手动输入'
                $ac = Read-Host '  请选择 [1]'
                $ak = $null
                if ($ac -eq '2') { $ak = Read-Host '  请输入 API 密钥' }
                Install-Clientd $devices $hl $ak
            }
            '3' { Show-Status }
            '4' { Show-Info }
            '5' {
                $uc = Read-Host '升级组件 [1] agent [2] clientd'
                if ($uc -eq '2') { Update-Rtctl 'clientd' } else { Update-Rtctl 'agent' }
            }
            '6' {
                $uc = Read-Host '卸载组件 [1] agent [2] clientd [3] 全部'
                switch ($uc) { '1' { Uninstall-Rtctl 'agent' } '2' { Uninstall-Rtctl 'clientd' } default { Uninstall-Rtctl 'all' } }
            }
            '7' { Write-Host '[rtctl] 再见'; exit 0 }
            default { Write-Host '[提示] 无效选择' }
        }
    }
}
