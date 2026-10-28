# Only consider SOCKS5 listeners owned by the selected proxy client.
function Test-LocalSocks5([int]$Port) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $connect.Wait(1000)) { return $false }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 1000
        $stream.WriteTimeout = 1000
        [byte[]]$hello = @(5, 1, 0)
        $stream.Write($hello, 0, $hello.Length)
        [byte[]]$reply = @(0, 0)
        $received = 0
        while ($received -lt $reply.Length) {
            $count = $stream.Read($reply, $received, $reply.Length - $received)
            if ($count -le 0) { return $false }
            $received += $count
        }
        return $reply[0] -eq 5 -and $reply[1] -eq 0
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Get-ProxyEndpoint(
    [ValidateSet('Clash', 'V2rayN')][string]$Client,
    [object[]]$Processes = $null,
    [object[]]$Listeners = $null
) {
    try {
        if ($null -eq $Processes) { $Processes = @(Get-CimInstance Win32_Process -ErrorAction Stop) }
        if ($Client -eq 'Clash') {
            # Clash Plus uses a helper service, so its core is not a child of MyClash.exe.
            $owned = @($Processes | Where-Object {
                $_.Name -in @('MyClash.exe', 'MyClashCore.exe')
            } | ForEach-Object { [int]$_.ProcessId })
            if ($owned.Count -eq 0) {
                return [pscustomobject]@{ State = 'Unavailable'; Port = $null; Ports = @() }
            }
        } else {
            $roots = @($Processes | Where-Object { $_.Name -eq 'v2rayN.exe' })
            if ($roots.Count -eq 0) {
                return [pscustomobject]@{ State = 'Unavailable'; Port = $null; Ports = @() }
            }
            $owned = @($roots | ForEach-Object { [int]$_.ProcessId })
            do {
                $children = @($Processes | Where-Object {
                    [int]$_.ParentProcessId -in $owned -and [int]$_.ProcessId -notin $owned
                } | ForEach-Object { [int]$_.ProcessId })
                $owned += $children
            } while ($children.Count -gt 0)
        }

        if ($null -eq $Listeners) { $Listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop) }
        $ports = @($Listeners |
            Where-Object { [int]$_.OwningProcess -in $owned } |
            Select-Object -ExpandProperty LocalPort -Unique)
        $socksPorts = @($ports | Where-Object { Test-LocalSocks5 ([int]$_) } |
            ForEach-Object { [int]$_ } | Sort-Object -Unique)
        if ($socksPorts.Count -eq 1) {
            return [pscustomobject]@{ State = 'Ready'; Port = $socksPorts[0]; Ports = $socksPorts }
        }
        if ($socksPorts.Count -gt 1) {
            return [pscustomobject]@{ State = 'Ambiguous'; Port = $null; Ports = $socksPorts }
        }
        return [pscustomobject]@{ State = 'Unavailable'; Port = $null; Ports = @() }
    } catch {
        return [pscustomobject]@{ State = 'Error'; Port = $null; Ports = @(); Detail = $_.Exception.Message }
    }
}
