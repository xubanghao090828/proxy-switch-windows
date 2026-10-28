param(
    [ValidateSet('Menu', 'On', 'Off', 'Status')]
    [string]$Action = 'Menu',
    [ValidateRange(1, 65535)]
    [int]$Port = 7877,
    [ValidateSet('Clash', 'V2rayN', 'Manual')]
    [string]$Client = 'Manual'
)

$ErrorActionPreference = 'Stop'
$envFile = Join-Path $env:USERPROFILE '.codex\.env'
$begin = '# BEGIN CODEX_PROXY_TOGGLE'
$end = '# END CODEX_PROXY_TOGGLE'
$pattern = '(?ms)^# BEGIN CODEX_PROXY_TOGGLE\r?\n.*?^# END CODEX_PROXY_TOGGLE\r?\n?'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Get-EnvText {
    if (Test-Path -LiteralPath $envFile) {
        return [System.IO.File]::ReadAllText($envFile)
    }
    return ''
}

function Test-Socks5Listener {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $task.Wait(1500)) { return $false }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 1500
        $stream.WriteTimeout = 1500
        [byte[]]$hello = @(5, 1, 0)
        $stream.Write($hello, 0, $hello.Length)
        [byte[]]$reply = @(0, 0)
        if ($stream.Read($reply, 0, 2) -ne 2) { return $false }
        return $reply[0] -eq 5 -and $reply[1] -eq 0
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Write-EnvText([string]$text) {
    $dir = Split-Path -Parent $envFile
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($envFile, $text, $utf8)
}

$fromMenu = $Action -eq 'Menu'
if ($fromMenu) {
    Write-Host 'Codex 本地代理开关（不修改 Windows 用户或系统环境变量）'
    Write-Host '1. 开启  2. 关闭  3. 查看状态'
    $choice = Read-Host '请输入 1、2 或 3'
    $Action = switch ($choice) {
        '1' { 'On' }
        '2' { 'Off' }
        '3' { 'Status' }
        default { throw '无效选择，未做任何修改。' }
    }
    if ($Action -eq 'On') {
        $enteredPort = Read-Host "SOCKS5 端口（直接回车用 $Port；v2rayN 常用 10808）"
        if ($enteredPort) {
            $parsedPort = 0
            if (-not [int]::TryParse($enteredPort, [ref]$parsedPort) -or $parsedPort -lt 1 -or $parsedPort -gt 65535) {
                throw '端口无效，未做任何修改。'
            }
            $Port = $parsedPort
        }
    }
}

$text = Get-EnvText
$matches = [regex]::Matches($text, $pattern)
if ($text.Contains($begin) -ne $text.Contains($end) -or $matches.Count -gt 1) {
    throw 'Codex .env 中的代理开关标记不完整或重复，未做任何修改。'
}
$managed = $matches.Count -eq 1
$unmanaged = [regex]::Replace($text, $pattern, '')
$conflicts = [regex]::Matches($unmanaged, '(?im)^\s*(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|WS_PROXY|WSS_PROXY|NO_PROXY)\s*=')

if ($Action -eq 'Status') {
    if ($managed) {
        $configuredPort = [regex]::Match($matches[0].Value, '(?im)^ALL_PROXY=socks5h://127\.0\.0\.1:(\d+)\s*$')
        if ($configuredPort.Success) { $Port = [int]$configuredPort.Groups[1].Value }
    }
    Write-Host "Codex 代理开关：$(if ($managed) { '开启' } else { '关闭' })"
    Write-Host "127.0.0.1:$Port SOCKS5：$(if (Test-Socks5Listener) { '可用' } else { '不可用' })"
    if ($conflicts.Count -gt 0) { Write-Warning 'Codex .env 还存在其他代理变量，请人工检查。' }
    Write-Host '当前已经运行的 Codex 进程不会因切换而改变；需完全退出并重新打开应用。'
    exit 0
}

if ($conflicts.Count -gt 0) {
    throw 'Codex .env 已有其他代理变量；为避免覆盖原设置，未做任何修改。'
}

if ($Action -eq 'On') {
    if (-not (Test-Socks5Listener)) {
        throw "127.0.0.1:$Port 不是可用的 SOCKS5 代理；未做任何修改。"
    }
    $prefix = $unmanaged.TrimEnd("`r", "`n")
    if ($prefix.Length -gt 0) { $prefix += "`r`n" }
    $url = "socks5h://127.0.0.1:$Port"
    $block = @(
        $begin,
        "# PROXY_CLIENT=$Client",
        "HTTP_PROXY=$url",
        "HTTPS_PROXY=$url",
        "ALL_PROXY=$url",
        'NO_PROXY=localhost,127.0.0.1,::1',
        $end,
        ''
    ) -join "`r`n"
    Write-EnvText ($prefix + $block)
    Write-Host "已开启：Codex 专用 .env 指向 127.0.0.1:$Port。"
} else {
    if ($managed) { Write-EnvText $unmanaged }
    Write-Host '已关闭：Codex 专用代理段已移除。'
}

Write-Host '请完全退出并重新打开 ChatGPT/Codex 桌面应用后再测试任务。'
Write-Host '此开关针对 Codex 后端；它不保证桌面界面的全部流量经代理。'
