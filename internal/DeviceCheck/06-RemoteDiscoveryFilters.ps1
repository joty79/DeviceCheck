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
                if ($text -notmatch 'pub:Computer') { continue }

                $xaddr = $null
                $uuid = $null
                if ($text -match '<wsa:Address>(urn:uuid:[^<]+)</wsa:Address>') { $uuid = $Matches[1] }
                if ($text -match '<wsd:XAddrs>(http://[^<]+)</wsd:XAddrs>') { $xaddr = $Matches[1] }

                if (-not $results.Contains($ip)) {
                    $results[$ip] = [PSCustomObject]@{
                        IP       = $ip
                        HostName = $ip
                        XAddr    = $xaddr
                        Uuid     = $uuid
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
        if ($content -match '<pub:Computer>([^<]+)</pub:Computer>') {
            $computer = $Matches[1]
            if ($computer -match '^([^/]+)') { return $Matches[1] }
            return $computer
        }
    } catch {}

    return $null
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
