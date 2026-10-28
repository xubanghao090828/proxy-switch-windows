param([string]$PreviewPath)

$ErrorActionPreference = 'Stop'
$appDirectory = Join-Path $env:LOCALAPPDATA 'ProxySwitch\0.1.0\src'
$uiScript = Join-Path $appDirectory 'Proxy-Switch-UI.ps1'

try {
    if (-not (Test-Path -LiteralPath $uiScript -PathType Leaf)) {
        throw '程序文件未能解压到当前用户的应用数据目录。'
    }
    # The embedded scripts are local to this process. No user or machine policy is changed.
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
    if ($PreviewPath) {
        & $uiScript -PreviewPath $PreviewPath
    } else {
        & $uiScript
    }
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        "代理开关无法启动。`n$($_.Exception.Message)",
        '代理开关',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
