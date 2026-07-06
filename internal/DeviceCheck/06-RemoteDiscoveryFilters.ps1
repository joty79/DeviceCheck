function Test-DeviceCheckLanDiscoveryIPv4 {
    param(
        [AllowEmptyString()][string]$Address,
        [string[]]$SubnetPrefixes = @()
    )

    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }

    $octets = $Address.Split('.')
    if ($octets.Count -ne 4) { return $false }
    $first = [int]$octets[0]
    $last = [int]$octets[3]
    if ($first -in @(0, 127, 255) -or ($first -ge 224 -and $first -le 239)) { return $false }
    if ($first -eq 169 -and [int]$octets[1] -eq 254) { return $false }
    if ($last -eq 0 -or $last -eq 255) { return $false }

    $prefixes = @($SubnetPrefixes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($prefixes.Count -gt 0) {
        $matchesSubnet = $false
        foreach ($prefix in $prefixes) {
            if ($Address.StartsWith("$prefix.", [System.StringComparison]::OrdinalIgnoreCase)) {
                $matchesSubnet = $true
                break
            }
        }
        if (-not $matchesSubnet) { return $false }
    }

    return $true
}

function ConvertTo-DeviceCheckHostDisplayName {
    param(
        [AllowEmptyString()][string]$HostName,
        [AllowEmptyString()][string]$FallbackIP
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) { return $FallbackIP }
    $name = $HostName.Trim()
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($name, [ref]$parsed)) { return $FallbackIP }
    if ($name -match '\.in-addr\.arpa$') { return $FallbackIP }
    if ($name -match '^([^.]+)\.') { return $Matches[1] }
    return $name
}

function Get-DeviceCheckWsDiscoveryProbeFields {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -notmatch 'pub:Computer' -and $Text -notmatch '(?:^|[<\s/])(?:[A-Za-z0-9_-]+:)?Computer(?:[>\s/])') { return $null }

    $xaddr = $null
    $uuid = $null
    if ($Text -match '<(?:[A-Za-z0-9_-]+:)?Address>(urn:uuid:[^<]+)</(?:[A-Za-z0-9_-]+:)?Address>') { $uuid = $Matches[1] }
    if ($Text -match '<(?:[A-Za-z0-9_-]+:)?XAddrs>(http://[^<]+)</(?:[A-Za-z0-9_-]+:)?XAddrs>') { $xaddr = $Matches[1] }

    return [PSCustomObject]@{
        XAddr = $xaddr
        Uuid  = $uuid
    }
}

function Get-DeviceCheckWsDiscoveryMetadataComputerName {
    param([AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return $null }
    if ($Content -match '<(?:[A-Za-z0-9_-]+:)?Computer(?:\s[^>]*)?>([^<]+)</(?:[A-Za-z0-9_-]+:)?Computer>') {
        $computer = $Matches[1]
        if ($computer -match '^([^/]+)') { return $Matches[1] }
        return $computer
    }

    return $null
}

function Get-DeviceCheckExplorerNetworkComputerNameFromPath {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($Path -match '^\\\\([^\\]+)') { return $Matches[1].Trim() }
    return $null
}

function Invoke-DeviceCheckWsDiscoveryProbe {
    param(
        [string[]]$SubnetPrefixes = @(),
        [int]$TimeoutMs = 1800
    )

    $results = [ordered]@{}
    $messageId = [guid]::NewGuid().ToString()
    $probe = @"
<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
  <e:Header>
    <w:MessageID>uuid:$messageId</w:MessageID>
    <w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
    <w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
  </e:Header>
  <e:Body><d:Probe /></e:Body>
</e:Envelope>
"@

    $client = [Net.Sockets.UdpClient]::new(0)
    try {
        $client.EnableBroadcast = $true
        $client.MulticastLoopback = $false
        $client.Client.ReceiveTimeout = 250
        $bytes = [Text.Encoding]::UTF8.GetBytes($probe)
        $endpoint = [Net.IPEndPoint]::new([Net.IPAddress]::Parse('239.255.255.250'), 3702)
        [void]$client.Send($bytes, $bytes.Length, $endpoint)

        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
                $data = $client.Receive([ref]$remote)
                $text = [Text.Encoding]::UTF8.GetString($data)
                $ip = $remote.Address.ToString()
                if (-not (Test-DeviceCheckLanDiscoveryIPv4 -Address $ip -SubnetPrefixes $SubnetPrefixes)) { continue }
                $probeFields = Get-DeviceCheckWsDiscoveryProbeFields -Text $text
                if ($null -eq $probeFields) { continue }

                if (-not $results.Contains($ip)) {
                    $results[$ip] = [PSCustomObject]@{
                        IP       = $ip
                        HostName = $ip
                        XAddr    = $probeFields.XAddr
                        Uuid     = $probeFields.Uuid
                        Source   = 'WS-Discovery'
                    }
                }
            } catch [Net.Sockets.SocketException] {}
        }
    } catch {
    } finally {
        $client.Dispose()
    }

    foreach ($entry in $results.Values) {
        if (-not [string]::IsNullOrWhiteSpace($entry.XAddr) -and -not [string]::IsNullOrWhiteSpace($entry.Uuid)) {
            $name = Get-DeviceCheckWsDiscoveryComputerName -XAddr $entry.XAddr -Uuid $entry.Uuid
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $entry.HostName = $name
            }
        }
    }

    return @($results.Values)
}

function Get-DeviceCheckWsDiscoveryComputerName {
    param(
        [Parameter(Mandatory)][string]$XAddr,
        [Parameter(Mandatory)][string]$Uuid
    )

    $messageId = [guid]::NewGuid().ToString()
    $body = @"
<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">
  <soap:Header>
    <wsa:To>$Uuid</wsa:To>
    <wsa:Action>http://schemas.xmlsoap.org/ws/2004/09/transfer/Get</wsa:Action>
    <wsa:MessageID>urn:uuid:$messageId</wsa:MessageID>
    <wsa:ReplyTo><wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address></wsa:ReplyTo>
  </soap:Header>
  <soap:Body />
</soap:Envelope>
"@

    try {
        $response = Invoke-WebRequest -Uri $XAddr -Method Post -Body $body -ContentType 'application/soap+xml; charset=utf-8' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        $content = [string]$response.Content
        return (Get-DeviceCheckWsDiscoveryMetadataComputerName -Content $content)
    } catch {}

    return $null
}

function Get-DeviceCheckExplorerNetworkComputers {
    param([int]$TimeoutMilliseconds = 700)

    $runspace = $null
    $ps = $null
    $async = $null
    try {
        $runspace = [Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()

        $ps = [PowerShell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript({
            $results = [ordered]@{}
            $shell = $null
            try {
                $shell = New-Object -ComObject Shell.Application
                $folder = $shell.Namespace('shell:::{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}')
                if ($null -ne $folder) {
                    foreach ($item in @($folder.Items())) {
                        $name = [string]$item.Name
                        $path = [string]$item.Path
                        if ([string]::IsNullOrWhiteSpace($name) -and [string]::IsNullOrWhiteSpace($path)) { continue }

                        $hostName = $null
                        if ($path -match '^\\\\([^\\]+)') {
                            $hostName = $Matches[1]
                        }

                        if ([string]::IsNullOrWhiteSpace($hostName)) { continue }
                        $hostName = $hostName.Trim()
                        if (-not $results.Contains($hostName)) {
                            $results[$hostName] = [PSCustomObject]@{
                                HostName = $hostName
                                Path     = $path
                                Source   = 'ExplorerNetwork'
                            }
                        }
                    }
                }
            } catch {
            } finally {
                if ($null -ne $shell) {
                    try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch {}
                }
            }

            return @($results.Values)
        })

        $async = $ps.BeginInvoke()
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            try { $ps.Stop() } catch {}
            return @()
        }

        return @($ps.EndInvoke($async))
    } catch {
        return @()
    } finally {
        if ($null -ne $async -and $null -ne $async.AsyncWaitHandle) { try { $async.AsyncWaitHandle.Dispose() } catch {} }
        if ($null -ne $ps) { try { $ps.Dispose() } catch {}; $ps = $null }
        if ($null -ne $runspace) { try { $runspace.Dispose() } catch {}; $runspace = $null }
    }
}

function Invoke-DeviceCheckComputerPortSweep {
    param(
        [string[]]$SubnetPrefixes = @(),
        [string[]]$ExcludedIPs = @(),
        [int[]]$Ports = @(3389, 5985, 445),
        [int]$TimeoutMs = 220,
        [int]$BatchSize = 2048
    )

    $prefixes = @($SubnetPrefixes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($prefixes.Count -eq 0) { return @() }

    $excluded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in @($ExcludedIPs)) {
        if (-not [string]::IsNullOrWhiteSpace($ip)) { $null = $excluded.Add($ip) }
    }

    $candidateIPs = [System.Collections.Generic.List[string]]::new()
    foreach ($prefix in $prefixes) {
        for ($lastOctet = 1; $lastOctet -le 254; $lastOctet++) {
            $ip = "$prefix.$lastOctet"
            if (-not $excluded.Contains($ip)) { $candidateIPs.Add($ip) }
        }
    }

    $results = [ordered]@{}
    for ($offset = 0; $offset -lt $candidateIPs.Count; $offset += $BatchSize) {
        $scanTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
        $end = [Math]::Min($offset + $BatchSize - 1, $candidateIPs.Count - 1)
        for ($index = $offset; $index -le $end; $index++) {
            $ip = $candidateIPs[$index]
            foreach ($port in $Ports) {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new()
                    $task = $tcp.ConnectAsync($ip, $port)
                    $scanTasks.Add([PSCustomObject]@{ IP = $ip; Port = $port; TcpClient = $tcp; Task = $task })
                } catch {}
            }
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            $allDone = $true
            foreach ($scanTask in $scanTasks) {
                if (-not $scanTask.Task.IsCompleted) {
                    $allDone = $false
                    break
                }
            }
            if ($allDone) { break }
            Start-Sleep -Milliseconds 15
        }

        foreach ($scanTask in $scanTasks) {
            try {
                if ($scanTask.Task.IsCompleted -and $scanTask.TcpClient.Connected) {
                    if (-not $results.Contains($scanTask.IP)) {
                        $results[$scanTask.IP] = [PSCustomObject]@{
                            IP        = $scanTask.IP
                            RdpOpen   = $false
                            WinRmOpen = $false
                            SmbOpen   = $false
                        }
                    }
                    if ($scanTask.Port -eq 3389) { $results[$scanTask.IP].RdpOpen = $true }
                    if ($scanTask.Port -eq 5985) { $results[$scanTask.IP].WinRmOpen = $true }
                    if ($scanTask.Port -eq 445) { $results[$scanTask.IP].SmbOpen = $true }
                }
            } finally {
                try { $scanTask.TcpClient.Dispose() } catch {}
            }
        }
    }

    return @($results.Values)
}

function Get-DeviceCheckHostsCache {
    param([string]$NetworkId)
    $path = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'hosts-cache.json'
    $hash = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $json -and $json.PSObject.Properties[$NetworkId]) {
                $netObj = $json.PSObject.Properties[$NetworkId].Value
                if ($null -ne $netObj) {
                    foreach ($p in $netObj.PSObject.Properties) { $hash[$p.Name] = $p.Value }
                }
            }
        } catch {}
    }
    return $hash
}

function Save-DeviceCheckHostsCache {
    param([Parameter(Mandatory)]$Cache, [Parameter(Mandatory)][string]$NetworkId)
    $path = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'hosts-cache.json'
    try {
        $fullCache = @{}
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($null -ne $json) {
                foreach ($p in $json.PSObject.Properties) {
                    if ($p.Name -match '\|') { $fullCache[$p.Name] = $p.Value }
                }
            }
        }
        $fullCache[$NetworkId] = $Cache
        ($fullCache | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {}
}

function Start-DeviceCheckBackgroundResolver {
    param(
        [Parameter(Mandatory)][string[]]$IPs,
        [Parameter(Mandatory)][string]$NetworkId
    )
    if ($IPs.Count -eq 0) { return }
    $cachePath = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'hosts-cache.json'

    $null = Start-Job -ScriptBlock {
        param($ips, $path, $networkId)
        $fullCache = @{}
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if ($null -ne $json) {
                    foreach ($prop in $json.PSObject.Properties) {
                        if ($prop.Name -match '\|') { $fullCache[$prop.Name] = $prop.Value }
                    }
                }
            } catch {}
        }

        $netCache = @{}
        if ($fullCache.ContainsKey($networkId)) {
            $netObj = $fullCache[$networkId]
            if ($null -ne $netObj) {
                foreach ($prop in $netObj.PSObject.Properties) { $netCache[$prop.Name] = $prop.Value }
            }
        }

        $updated = $false
        foreach ($ip in $ips) {
            if (-not $netCache.ContainsKey($ip)) {
                try {
                    $entry = [System.Net.Dns]::GetHostEntry($ip)
                    if ($entry.HostName) {
                        $name = $entry.HostName
                        if ($name -eq $ip -or $name -match '\.in-addr\.arpa$') { $name = $ip } elseif ($name -match '^([^.]+)\.') { $name = $Matches[1] }
                        $netCache[$ip] = $name
                        $updated = $true
                    }
                } catch {
                    try {
                        $dnsRes = Resolve-DnsName -Name $ip -QuickTimeout -ErrorAction Stop
                        if ($dnsRes) {
                            $name = $dnsRes[0].NameHost
                            if ($name -eq $ip -or $name -match '\.in-addr\.arpa$') { $name = $ip } elseif ($name -match '^([^.]+)\.') { $name = $Matches[1] }
                            $netCache[$ip] = $name
                            $updated = $true
                        }
                    } catch {}
                }
            }
        }
        if ($updated) {
            try {
                $fullCache[$networkId] = $netCache
                $json = $fullCache | ConvertTo-Json -Depth 4
                $json | Set-Content -LiteralPath $path -Encoding UTF8
            } catch {}
        }
    } -ArgumentList $IPs, $cachePath, $NetworkId
}
