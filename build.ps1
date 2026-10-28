$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$version = '0.1.0'
$toolVersion = '1.0.18'
$tools = Join-Path $root '.build-tools'
$module = Join-Path $tools "ps2exe\$toolVersion\ps2exe.psd1"
$dist = Join-Path $root 'dist'
$exe = Join-Path $dist 'ProxySwitch.exe'

if (-not (Test-Path -LiteralPath $module -PathType Leaf)) {
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    Save-Module -Name ps2exe -RequiredVersion $toolVersion -Path $tools -Force -ErrorAction Stop
}
Import-Module $module -Force -ErrorAction Stop
New-Item -ItemType Directory -Path $dist -Force | Out-Null

$embedded = @{}
foreach ($name in @(
    'Proxy-Switch-UI.ps1',
    'Proxy-Switch-UI.xaml',
    'Desktop-Proxy-Switch.ps1',
    'Codex-Proxy-Switch.ps1',
    'Proxy-Discovery.ps1'
)) {
    $embedded["%LOCALAPPDATA%\ProxySwitch\$version\src\$name"] = Join-Path (Join-Path $root 'src') $name
}

Invoke-PS2EXE -InputFile (Join-Path $root 'src\Launcher.ps1') -OutputFile $exe `
    -x64 -STA -noConsole -DPIAware `
    -iconFile (Join-Path $root 'assets\Proxy-Switch.ico') `
    -embedFiles $embedded `
    -title '代理开关' -product 'ProxySwitch' `
    -description 'Clash Plus / v2rayN 本地代理环境开关' `
    -version '0.1.0.0'

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw 'EXE 构建失败；请检查上面的 PS2EXE 错误。'
}

$zip = Join-Path $dist "ProxySwitch-v$version-win-x64.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
Compress-Archive -LiteralPath $exe -DestinationPath $zip
Get-FileHash -Algorithm SHA256 -LiteralPath $exe,$zip |
    ForEach-Object { '{0}  {1}' -f $_.Hash, (Split-Path -Leaf $_.Path) } |
    Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding Ascii
Get-ChildItem -LiteralPath $dist -File | Select-Object Name,Length
