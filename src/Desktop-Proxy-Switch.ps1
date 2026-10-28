param(
    [ValidateSet('Toggle', 'Menu', 'Clash', 'V2rayN', 'Off', 'Status')]
    [string]$Action = 'Toggle'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Proxy-Discovery.ps1')
$codexSwitch = Join-Path $PSScriptRoot 'Codex-Proxy-Switch.ps1'
$codexEnv = Join-Path $env:USERPROFILE '.codex\.env'
$proxyNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')

function Get-ManagedProxy {
    if (-not (Test-Path -LiteralPath $codexEnv)) { return $null }
    $contents = [IO.File]::ReadAllText($codexEnv)
    $block = [regex]::Match($contents,
        '(?ms)^# BEGIN CODEX_PROXY_TOGGLE\r?\n(.*?)^# END CODEX_PROXY_TOGGLE\s*$')
    if (-not $block.Success) { return $null }
    $proxy = [regex]::Match($block.Groups[1].Value,
        '(?m)^ALL_PROXY=(socks5h://127\.0\.0\.1:(\d{1,5}))\s*$')
    if (-not $proxy.Success -or [int]$proxy.Groups[2].Value -gt 65535) { return $null }
    return $proxy.Groups[1].Value
}

function Get-UserProxy {
    $values = @{}
    foreach ($name in $proxyNames) {
        $values[$name] = [Environment]::GetEnvironmentVariable($name, 'User')
    }
    return $values
}

function Assert-NoForeignProxy($values) {
    $managed = Get-ManagedProxy
    $legacy = @('socks5h://127.0.0.1:7877', 'socks5h://127.0.0.1:10808')
    foreach ($name in $proxyNames) {
        $value = $values[$name]
        if ($null -ne $value -and $value -ne $managed -and $value -notin $legacy) {
            throw "用户环境变量 $name 已有其他值；为避免覆盖，未修改任何设置。"
        }
    }
}

function Set-UserProxy($values) {
    foreach ($name in $proxyNames) {
        [Environment]::SetEnvironmentVariable($name, $values[$name], 'User')
    }
}

function Refresh-Environment {
    try {
        if (-not ('ProxySwitchNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ProxySwitchNative {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hwnd, int msg, IntPtr wparam, string lparam,
        int flags, int timeout, out IntPtr result);
}
'@
        }
        $result = [IntPtr]::Zero
        [void][ProxySwitchNative]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [IntPtr]::Zero,
            'Environment', 2, 2000, [ref]$result)
    } catch {
        Write-Warning '环境刷新通知未成功；新程序可能需要重新登录 Windows 才能取得新变量。'
    }
}

if ($Action -eq 'Menu') {
    Write-Host ''
    Write-Host 'ChatGPT / Codex 代理开关'
    Write-Host '1  自动检测 Clash SOCKS5 端口并使用'
    Write-Host '2  自动检测 v2rayN SOCKS5 端口并使用'
    Write-Host '3  关闭并删除开关写入的代理变量'
    Write-Host '4  查看状态'
    $choice = Read-Host '请输入 1、2、3 或 4'
    $Action = switch ($choice) {
        '1' { 'Clash' }
        '2' { 'V2rayN' }
        '3' { 'Off' }
        '4' { 'Status' }
        default { throw '无效选择，未修改任何设置。' }
    }
}

$before = Get-UserProxy
Assert-NoForeignProxy $before

if ($Action -eq 'Toggle') {
    $hasUserProxy = @($proxyNames | Where-Object { $null -ne $before[$_] }).Count -gt 0
    if ($hasUserProxy) {
        $Action = 'Off'
    } else {
        $clashEndpoint = Get-ProxyEndpoint Clash
        $v2rayEndpoint = Get-ProxyEndpoint V2rayN
        if ($clashEndpoint.State -eq 'Ready' -and $v2rayEndpoint.State -eq 'Ready') {
            Write-Host 'Clash 和 v2rayN 都已启动。'
            $choice = Read-Host '输入 1 使用 Clash，或 2 使用 v2rayN'
            $Action = switch ($choice) {
                '1' { 'Clash' }
                '2' { 'V2rayN' }
                default { throw '无效选择，未修改任何设置。' }
            }
        } elseif ($clashEndpoint.State -eq 'Ready') {
            $Action = 'Clash'
        } elseif ($v2rayEndpoint.State -eq 'Ready') {
            $Action = 'V2rayN'
        } else {
            throw '未能确定 Clash 或 v2rayN 的唯一 SOCKS5 端口；请先启动并检查代理客户端。'
        }
    }
}

if ($Action -eq 'Status') {
    $active = @($proxyNames | ForEach-Object { $before[$_] } | Where-Object { $null -ne $_ })
    if ($active.Count -eq 0) {
        Write-Host '用户代理变量：关闭'
    } elseif ($active.Count -eq 3 -and $active[0] -eq $active[1] -and $active[1] -eq $active[2]) {
        Write-Host "用户代理变量：$($active[0])"
    } else {
        Write-Warning '用户代理变量只有部分设置；请选择关闭或重新开启。'
    }
    foreach ($client in @('Clash', 'V2rayN')) {
        $endpoint = Get-ProxyEndpoint $client
        $description = switch ($endpoint.State) {
            'Ready' { '127.0.0.1:' + $endpoint.Port + ' SOCKS5 可用' }
            'Ambiguous' { '检测到多个 SOCKS5 端口，未自动选择' }
            'Error' { '检测失败' }
            default { '未启动或未检测到 SOCKS5 端口' }
        }
        Write-Host "${client}：$description"
    }
    & $codexSwitch -Action Status
    exit 0
}

$hadCodexEnv = Test-Path -LiteralPath $codexEnv
if ($hadCodexEnv) { $codexEnvBackup = [IO.File]::ReadAllBytes($codexEnv) }

try {
    if ($Action -eq 'Off') {
        & $codexSwitch -Action Off
        $target = @{ HTTP_PROXY = $null; HTTPS_PROXY = $null; ALL_PROXY = $null }
    } else {
        $endpoint = Get-ProxyEndpoint $Action
        if ($endpoint.State -ne 'Ready') {
            throw "$Action 未找到唯一可用的 SOCKS5 端口（状态：$($endpoint.State)）；未修改任何设置。"
        }
        $port = [int]$endpoint.Port
        & $codexSwitch -Action On -Port $port -Client $Action
        $url = "socks5h://127.0.0.1:$port"
        $target = @{ HTTP_PROXY = $url; HTTPS_PROXY = $url; ALL_PROXY = $url }
    }
    Set-UserProxy $target
} catch {
    $problem = $_
    Set-UserProxy $before
    if ($hadCodexEnv) {
        [IO.File]::WriteAllBytes($codexEnv, $codexEnvBackup)
    } elseif (Test-Path -LiteralPath $codexEnv) {
        Remove-Item -LiteralPath $codexEnv
    }
    throw $problem
}

Refresh-Environment
if ($Action -eq 'Off') {
    Write-Host '已关闭：用户代理变量及 Codex 专用代理段已删除。原有 NO_PROXY 保留。'
    Write-Host '玩游戏前请另外关闭 Clash 的 TUN，并重开已在运行的游戏启动器。'
} else {
    Write-Host "已开启：新启动的程序将看到 $Action 的代理变量。原有 NO_PROXY 保留。"
}
Write-Host '请完全退出并重新打开 ChatGPT / Codex；已经运行的程序不会自动改变。'
Write-Host '桌面应用是否全部遵循这些变量，仍需关闭 TUN 后实际验证。'
