param([string]$PreviewPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$viewPath = Join-Path $PSScriptRoot 'Proxy-Switch-UI.xaml'
$switchPath = Join-Path $PSScriptRoot 'Desktop-Proxy-Switch.ps1'
$discoveryPath = Join-Path $PSScriptRoot 'Proxy-Discovery.ps1'
$xaml = [xml][IO.File]::ReadAllText($viewPath)
$reader = [Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$hero = $window.FindName('HeroCard')
$statusTitle = $window.FindName('StatusTitle')
$statusSubtitle = $window.FindName('StatusSubtitle')
$statusBadge = $window.FindName('StatusBadge')
$statusBadgeText = $window.FindName('StatusBadgeText')
$clashState = $window.FindName('ClashState')
$v2rayState = $window.FindName('V2rayState')
$clashButton = $window.FindName('ClashButton')
$v2rayButton = $window.FindName('V2rayButton')
$offButton = $window.FindName('OffButton')
$refreshButton = $window.FindName('RefreshButton')
$minimizeButton = $window.FindName('MinimizeButton')
$closeButton = $window.FindName('CloseButton')
$tunText = $window.FindName('TunText')
$script:busy = $false
$script:job = $null
$script:jobTimer = $null
$script:jobStarted = $null
$script:statusJob = $null
$script:statusTimer = $null
$script:refreshPending = $false
$script:endpoints = @{
    Clash = [pscustomobject]@{ State = 'Checking'; Port = $null; Ports = @() }
    V2rayN = [pscustomobject]@{ State = 'Checking'; Port = $null; Ports = @() }
}

function Set-Brush($control, [string]$property, [string]$hex) {
    $brush = [Windows.Media.BrushConverter]::new().ConvertFromString($hex)
    $control.$property = $brush
}

function Format-Endpoint($endpoint) {
    switch ($endpoint.State) {
        'Ready' { return "可用  ·  127.0.0.1:$($endpoint.Port)" }
        'Ambiguous' { return '检测到多个 SOCKS5 端口，请检查客户端' }
        'Checking' { return '正在自动检测 SOCKS5 端口…' }
        'Error' { return '端口检测失败，请刷新重试' }
        default { return '未启动或未检测到 SOCKS5 端口' }
    }
}

function Get-Mode {
    $codexEnv = Join-Path $env:USERPROFILE '.codex\.env'
    $envText = if (Test-Path -LiteralPath $codexEnv) { [IO.File]::ReadAllText($codexEnv) } else { '' }
    $values = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY') |
        ForEach-Object { [Environment]::GetEnvironmentVariable($_, 'User') }
    $present = @($values | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($present.Count -eq 0) {
        if ($envText.Contains('# BEGIN CODEX_PROXY_TOGGLE')) {
            return 'CodexOnly'
        }
        return 'Off'
    }
    if ($present.Count -ne 3 -or $present[0] -ne $present[1] -or $present[1] -ne $present[2]) {
        return 'Other'
    }
    $managed = [regex]::Match($envText,
        '(?ms)^# BEGIN CODEX_PROXY_TOGGLE\r?\n(.*?)^# END CODEX_PROXY_TOGGLE\s*$')
    if ($managed.Success) {
        $client = [regex]::Match($managed.Groups[1].Value,
            '(?m)^# PROXY_CLIENT=(Clash|V2rayN)\s*$')
        $proxy = [regex]::Match($managed.Groups[1].Value,
            '(?m)^ALL_PROXY=(socks5h://127\.0\.0\.1:\d{1,5})\s*$')
        if ($client.Success -and $proxy.Success -and $present[0] -eq $proxy.Groups[1].Value) {
            return $client.Groups[1].Value
        }
    }
    # Support the two fixed ports written by the original version of this switch.
    switch ($present[0]) {
        'socks5h://127.0.0.1:7877' { return 'Clash' }
        'socks5h://127.0.0.1:10808' { return 'V2rayN' }
        default { return 'Other' }
    }
}

function Update-View {
    $mode = Get-Mode
    $clashReady = $script:endpoints.Clash.State -eq 'Ready'
    $v2rayReady = $script:endpoints.V2rayN.State -eq 'Ready'
    $clashState.Text = Format-Endpoint $script:endpoints.Clash
    $v2rayState.Text = Format-Endpoint $script:endpoints.V2rayN
    $clashButton.Content = if ($mode -eq 'Clash') { '正在使用' } else { '使用 Clash' }
    $v2rayButton.Content = if ($mode -eq 'V2rayN') { '正在使用' } else { '使用 v2rayN' }
    $foreign = $mode -eq 'Other'
    $clashButton.IsEnabled = $clashReady -and $mode -ne 'Clash' -and -not $foreign -and -not $script:busy
    $v2rayButton.IsEnabled = $v2rayReady -and $mode -ne 'V2rayN' -and -not $foreign -and -not $script:busy
    $offButton.IsEnabled = $mode -ne 'Off' -and -not $foreign -and -not $script:busy
    $refreshButton.IsEnabled = -not $script:busy
    $closeButton.IsEnabled = -not $script:busy

    switch ($mode) {
        'Clash' {
            $statusTitle.Text = '已配置 Clash'
            $statusSubtitle.Text = if ($script:endpoints.Clash.State -in @('Unavailable', 'Error')) {
                'Clash 端口暂不可用，请检查客户端或关闭代理。'
            } else { '新打开的应用会收到 Clash 代理设置。' }
            $statusBadgeText.Text = if ($script:endpoints.Clash.State -in @('Unavailable', 'Error')) { '端口失联' } else { '已开启' }
            Set-Brush $hero 'Background' '#DDF7EC'
            Set-Brush $statusBadge 'Background' '#BCEBD4'
        }
        'V2rayN' {
            $statusTitle.Text = '已配置 v2rayN'
            $statusSubtitle.Text = if ($script:endpoints.V2rayN.State -in @('Unavailable', 'Error')) {
                'v2rayN 端口暂不可用，请检查客户端或关闭代理。'
            } else { '新打开的应用会收到 v2rayN 代理设置。' }
            $statusBadgeText.Text = if ($script:endpoints.V2rayN.State -in @('Unavailable', 'Error')) { '端口失联' } else { '已开启' }
            Set-Brush $hero 'Background' '#E9EFFF'
            Set-Brush $statusBadge 'Background' '#CCD9FA'
        }
        'CodexOnly' {
            $statusTitle.Text = 'Codex 单独开启'
            $statusSubtitle.Text = '用户代理已关闭，Codex 专用配置仍在。可点下方关闭。'
            $statusBadgeText.Text = '需同步'
            Set-Brush $hero 'Background' '#FFF2D9'
            Set-Brush $statusBadge 'Background' '#FFE2A2'
        }
        'Other' {
            $statusTitle.Text = '检测到其他代理设置'
            $statusSubtitle.Text = '为避免覆盖已有设置，此开关不会修改它们。'
            $statusBadgeText.Text = '已保护'
            Set-Brush $hero 'Background' '#FFF2D9'
            Set-Brush $statusBadge 'Background' '#FFE2A2'
        }
        default {
            $statusTitle.Text = '代理已关闭'
            $statusSubtitle.Text = '选择下方可用的代理即可开启。'
            $statusBadgeText.Text = '未开启'
            Set-Brush $hero 'Background' '#E9F1ED'
            Set-Brush $statusBadge 'Background' '#D7E3DC'
        }
    }

    try {
        $adapter = Get-NetAdapter -Name 'Clash Plus' -ErrorAction SilentlyContinue
        if ($adapter -and $adapter.Status -eq 'Up') {
            $tunText.Text = 'Clash 的 TUN 当前开启；此开关不会关闭 TUN。'
            Set-Brush $tunText 'Foreground' '#B26A21'
        } else {
            $tunText.Text = 'TUN 由 Clash 单独控制；此开关只管理代理设置。'
            Set-Brush $tunText 'Foreground' '#8B9B91'
        }
    } catch {
        $tunText.Text = 'TUN 由 Clash 单独控制。'
    }
}

function Start-StatusCheck {
    if ($script:statusJob) {
        $script:refreshPending = $true
        return
    }
    $script:endpoints.Clash = [pscustomobject]@{ State = 'Checking'; Port = $null; Ports = @() }
    $script:endpoints.V2rayN = [pscustomobject]@{ State = 'Checking'; Port = $null; Ports = @() }
    if (-not $script:busy) { Update-View }
    try {
        $script:statusJob = Start-Job -ScriptBlock {
            param($path)
            . $path
            $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
            $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
            foreach ($client in @('Clash', 'V2rayN')) {
                $result = Get-ProxyEndpoint -Client $client -Processes $processes -Listeners $listeners
                [pscustomobject]@{
                    Client = $client
                    State = $result.State
                    Port = $result.Port
                    Ports = $result.Ports
                }
            }
        } -ArgumentList $discoveryPath
    } catch {
        $script:endpoints.Clash.State = 'Error'
        $script:endpoints.V2rayN.State = 'Error'
        if (-not $script:busy) { Update-View }
        return
    }
    $script:statusTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:statusTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:statusTimer.Add_Tick({
        if ($script:statusJob.State -notin @('Completed', 'Failed', 'Stopped') -or $script:busy) { return }
        $script:statusTimer.Stop()
        $finished = $script:statusJob
        $results = @()
        if ($finished.State -eq 'Completed') {
            $results = @(Receive-Job -Job $finished -ErrorAction SilentlyContinue)
        }
        Remove-Job -Job $finished -Force -ErrorAction SilentlyContinue
        $script:statusJob = $null
        foreach ($client in @('Clash', 'V2rayN')) {
            $result = @($results | Where-Object { $_.Client -eq $client }) | Select-Object -First 1
            if ($result) {
                $script:endpoints[$client] = $result
            } else {
                $script:endpoints[$client] = [pscustomobject]@{ State = 'Error'; Port = $null; Ports = @() }
            }
        }
        Update-View
        if ($script:refreshPending) {
            $script:refreshPending = $false
            Start-StatusCheck
        }
    })
    $script:statusTimer.Start()
}

function Start-Switch([string]$action) {
    if ($script:busy) { return }
    $script:busy = $true
    Update-View
    $statusTitle.Text = '正在切换…'
    $statusSubtitle.Text = '正在确认本地代理并保存设置。'
    $statusBadgeText.Text = '请稍候'
    try {
        $script:job = Start-Job -ScriptBlock {
            param($path, $selected)
            & $path -Action $selected
        } -ArgumentList $switchPath, $action
    } catch {
        $script:busy = $false
        Update-View
        [Windows.MessageBox]::Show('无法启动切换操作：' + $_.Exception.Message,
            '代理开关', 'OK', 'Error') | Out-Null
        return
    }
    $script:jobStarted = [DateTime]::Now
    $script:jobTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:jobTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:jobTimer.Add_Tick({
        if ($script:job.State -notin @('Completed', 'Failed', 'Stopped')) {
            if (([DateTime]::Now - $script:jobStarted).TotalSeconds -gt 55) {
                $statusSubtitle.Text = '仍在保存设置，请等操作完成。'
            }
            return
        }
        $script:jobTimer.Stop()
        $finished = $script:job
        $success = $finished.State -eq 'Completed'
        $reason = if ($finished.ChildJobs.Count -gt 0 -and $finished.ChildJobs[0].JobStateInfo.Reason) {
            $finished.ChildJobs[0].JobStateInfo.Reason.Message
        } else { '代理未响应或切换超时。' }
        try { Receive-Job -Job $finished -ErrorAction SilentlyContinue | Out-Null } catch {}
        Remove-Job -Job $finished -Force -ErrorAction SilentlyContinue
        $script:job = $null
        $script:busy = $false
        Update-View
        if ($success) {
            $statusSubtitle.Text = '切换完成。请完全退出并重新打开 ChatGPT / Codex。'
        } else {
            [Windows.MessageBox]::Show("设置未改变。`n$reason", '代理开关', 'OK', 'Warning') | Out-Null
        }
        Start-StatusCheck
    })
    $script:jobTimer.Start()
}

$closeButton.Add_Click({ $window.Close() })
$minimizeButton.Add_Click({ $window.WindowState = [Windows.WindowState]::Minimized })
$window.FindName('TitleBar').Add_MouseLeftButtonDown({
    if ([Windows.Input.Mouse]::LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) {
        try { $window.DragMove() } catch { }
    }
})
$refreshButton.Add_Click({ Start-StatusCheck })
$clashButton.Add_Click({ Start-Switch 'Clash' })
$v2rayButton.Add_Click({ Start-Switch 'V2rayN' })
$offButton.Add_Click({ Start-Switch 'Off' })
$window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:busy) { $eventArgs.Cancel = $true }
    if (-not $eventArgs.Cancel -and $script:statusJob) {
        if ($script:statusTimer) { $script:statusTimer.Stop() }
        if ($script:statusJob.State -in @('Completed', 'Failed', 'Stopped')) {
            Remove-Job -Job $script:statusJob -Force -ErrorAction SilentlyContinue
            $script:statusJob = $null
        }
    }
})

if ($PreviewPath) {
    . $discoveryPath
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    foreach ($client in @('Clash', 'V2rayN')) {
        $script:endpoints[$client] = Get-ProxyEndpoint -Client $client -Processes $processes -Listeners $listeners
    }
    Update-View
    $window.WindowStartupLocation = 'Manual'
    $window.Left = -10000
    $window.Top = -10000
    $window.ShowInTaskbar = $false
    $window.Show()
    $window.UpdateLayout()
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        600, 620, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window.Content)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $file = [IO.File]::Create($PreviewPath)
    try { $encoder.Save($file) } finally { $file.Dispose() }
    $window.Close()
    exit 0
}
Start-StatusCheck
[void]$window.ShowDialog()
