# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: Responsive LAN target prompts, WinRM snapshot collection, discovery, and history workflows.
function Read-TuiLine {
    param(
        [Parameter(Mandatory)][scriptblock]$RenderBlock,
        [string]$DefaultValue = '',
        [bool]$IsPassword = $false
    )

    $inputVal = $DefaultValue
    
    try {
        [Console]::CursorVisible = $true
        while ($true) {
            $displayInput = $(if ($IsPassword) { '*' * $inputVal.Length } else { $inputVal })
            & $RenderBlock $displayInput

            $key = Read-ConsoleKey
            if ($null -eq $key -or -not $key.PSObject.Properties['Key']) {
                Start-Sleep -Milliseconds 10
                continue
            }
            
            switch ($key.Key) {
                'Enter' {
                    return $inputVal
                }
                'Escape' {
                    return $null
                }
                'Backspace' {
                    if ($inputVal.Length -gt 0) {
                        $inputVal = $inputVal.Substring(0, $inputVal.Length - 1)
                    }
                }
                'ResizeEvent' {
                    $script:RequestForceClear = $true
                    continue
                }
                default {
                    if ($key.KeyChar -ne [char]0 -and -not [char]::IsControl($key.KeyChar) -and -not $key.ControlPressed) {
                        $inputVal += [string]$key.KeyChar
                    }
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $false } catch {}
    }
}

function New-DeviceCheckCredentialFromPrompt {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$DefaultUserName
    )

    $script:RequestForceClear = $true
    if ([string]::IsNullOrWhiteSpace($DefaultUserName)) {
        $DefaultUserName = "$ComputerName\joty79"
    }

    # Prompt for Username
    $renderUserBlock = {
        param($currentInput)
        $width = Get-UiWidth
        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title "Credentials Required" -Subtitle "Connecting to $ComputerName" -Width $width
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Enter credentials for WinRM management on target PC.$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Target :$($_C.Reset) $($_C.Info)$ComputerName$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Bold)$($_C.White)Username [$DefaultUserName]:$($_C.Reset)$($_C.EraseLn)"
        $null = $frame.Append("  Username: $currentInput")
        Write-UiFrame -Frame $frame
    }
    $userName = Read-TuiLine -RenderBlock $renderUserBlock -DefaultValue ''
    if ($null -eq $userName) {
        throw "Connection cancelled by user."
    }
    if ([string]::IsNullOrWhiteSpace($userName)) {
        $userName = $DefaultUserName
    }

    # Prompt for Password
    $script:RequestForceClear = $true
    $renderPasswordBlock = {
        param($currentInput)
        $width = Get-UiWidth
        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title "Credentials Required" -Subtitle "Connecting to $ComputerName" -Width $width
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Enter credentials for WinRM management on target PC.$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Target :$($_C.Reset) $($_C.Info)$ComputerName$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)User   :$($_C.Reset) $($_C.White)$userName$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Bold)$($_C.White)Password for $($userName):$($_C.Reset)$($_C.EraseLn)"
        $null = $frame.Append("  Password: $currentInput")
        Write-UiFrame -Frame $frame
    }
    $passwordStr = Read-TuiLine -RenderBlock $renderPasswordBlock -DefaultValue '' -IsPassword $true
    if ($null -eq $passwordStr) {
        throw "Connection cancelled by user."
    }
    $password = $(if ([string]::IsNullOrEmpty($passwordStr)) {
        [System.Security.SecureString]::new()
    } else {
        ConvertTo-SecureString $passwordStr -AsPlainText -Force
    })
    return [System.Management.Automation.PSCredential]::new($userName, $password)
}

function Show-RemoteSnapshotCollectionScreen {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$UserName,
        [string]$Subtitle = 'Collecting full remote snapshot over WinRM.',
        [switch]$ShowCollecting,
        [string]$ProgressText
    )

    $frame = New-Object System.Text.StringBuilder
    $width = Get-UiWidth
    Add-UiFrameBanner -Frame $frame -Title "Refresh $ComputerName" -Subtitle $Subtitle -Width $width

    $null = $frame.AppendLine('')
    $null = $frame.AppendLine("  $($_C.Dim)Target :$($_C.Reset) $($_C.Info)$ComputerName$($_C.Reset)$($_C.EraseLn)")
    if (-not [string]::IsNullOrWhiteSpace($UserName)) {
        $null = $frame.AppendLine("  $($_C.Dim)User   :$($_C.Reset) $($_C.White)$UserName$($_C.Reset)$($_C.EraseLn)")
    }
    $null = $frame.AppendLine('')

    if ($ShowCollecting) {
        $barText = $(if (-not [string]::IsNullOrWhiteSpace($ProgressText)) { $ProgressText } else { '[##########----------] Collecting system, devices, properties, pnputil, monitors...' })
        $null = $frame.AppendLine("  $($_C.Info)$barText$($_C.Reset)$($_C.EraseLn)")
        $null = $frame.AppendLine('')
        $null = $frame.AppendLine("  $($_C.Dim)This can take a few seconds on LAN. Press ESC to cancel.$($_C.Reset)$($_C.EraseLn)")
    }
    
    Write-UiFrame -Frame $frame
}

function Invoke-RemoteSnapshotCollectionScreen {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$PromptForCredential,
        [switch]$Quick,
        [switch]$ArchiveSample
    )

    try {
        Clear-TuiScreen
        $defaultUserName = "$ComputerName\joty79"
        $captureSubtitle = $(if ($ArchiveSample) {
                'Collecting full archive sample over WinRM.'
            } elseif ($Quick) {
                'Collecting quick remote snapshot over WinRM.'
            } else {
                'Collecting full remote snapshot over WinRM.'
            })
        if ($PromptForCredential -or $null -eq $Credential) {
            Show-RemoteSnapshotCollectionScreen -ComputerName $ComputerName -UserName $defaultUserName -Subtitle 'Enter credentials for this LAN target.'
            $Credential = New-DeviceCheckCredentialFromPrompt -ComputerName $ComputerName -DefaultUserName $defaultUserName
            Clear-TuiScreen
        }

        $progressCallback = {
            param($progressText)
            Show-RemoteSnapshotCollectionScreen -ComputerName $ComputerName -UserName $Credential.UserName -Subtitle $captureSubtitle -ShowCollecting -ProgressText $progressText
        }

        $export = Invoke-DeviceCheckSnapshotExport -ComputerName $ComputerName -Credential $Credential -OnProgress $progressCallback -Quick:$Quick -ArchiveSample:$ArchiveSample
        return [PSCustomObject]@{
            Success    = $true
            Credential = $Credential
            Export     = $export
            Error      = $null
        }
    } catch {
        $message = $_.Exception.Message
        Remove-DeviceCheckStoredCredential -ComputerName $ComputerName
        
        $renderErrorBlock = {
            param()
            Clear-TuiScreen
            $width = Get-UiWidth
            $frame = New-Object System.Text.StringBuilder
            Add-UiFrameBanner -Frame $frame -Title "Cannot connect to $ComputerName" -Subtitle 'The target may be asleep, offline, blocked by firewall, or rejecting credentials.' -Width $width
            
            $null = $frame.AppendLine('')
            $null = $frame.AppendLine("  $($_C.Fail)Connection failed.$($_C.Reset)$($_C.EraseLn)")
            $null = $frame.AppendLine('')
            
            foreach ($line in (Wrap-PlainText -Text $message -Width ([Math]::Max(50, $width - 6)) -MaxLines 8)) {
                $null = $frame.AppendLine("  $($_C.Warn)$line$($_C.Reset)$($_C.EraseLn)")
            }
            $null = $frame.AppendLine('')
            
            if ($script:RemoteConnectionLog -and $script:RemoteConnectionLog.Count -gt 0) {
                $null = $frame.AppendLine("  $($_C.Bold)$($_C.White)Connection Log:$($_C.Reset)$($_C.EraseLn)")
                foreach ($logLine in $script:RemoteConnectionLog) {
                    $null = $frame.AppendLine("    $($_C.Dim)> $logLine$($_C.Reset)$($_C.EraseLn)")
                }
                $null = $frame.AppendLine('')
            }
            
            $null = $frame.AppendLine("  $($_C.Dim)No target switch was made. Wake the PC / check WinRM, then try again.$($_C.Reset)$($_C.EraseLn)")
            $null = $frame.AppendLine('')
            $null = $frame.AppendLine("  $($_C.Info)Press Enter to return$($_C.Reset)$($_C.EraseLn)")
            $null = $frame.AppendLine('')
            $null = $frame.AppendLine("$($_E)[J")
            
            try { [Console]::Write($frame.ToString()) } catch { $frame.ToString() | Write-Host }
        }

        while ($true) {
            & $renderErrorBlock
            $key = Read-ConsoleKey
            if ($null -eq $key -or -not $key.PSObject.Properties['Key']) {
                Start-Sleep -Milliseconds 10
                continue
            }
            if ($key.Key -eq 'Enter') {
                break
            }
            if ($key.Key -eq 'ResizeEvent') {
                $script:RequestForceClear = $true
                continue
            }
        }

        return [PSCustomObject]@{
            Success    = $false
            Credential = $Credential
            Export     = $null
            Error      = $message
        }
    }
}

function Set-ActiveSnapshotTarget {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$SnapshotPath,
        [Parameter(Mandatory)][string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential
    )

    foreach ($id in @($script:ActiveSearches.Keys)) {
        Stop-DeviceLookup -InstanceId $id
    }
    if ($null -ne $script:EvidenceBatchQueue) { $script:EvidenceBatchQueue.Clear() }
    if ($null -ne $script:EvidenceBatchQueuedIds) { $script:EvidenceBatchQueuedIds.Clear() }
    $script:EvidenceBatchState = $null

    $script:TargetMode = 'RemoteSnapshot'
    $script:TargetComputerName = $ComputerName
    $script:TargetCredential = $Credential
    if ($null -ne $Credential -and -not [string]::IsNullOrWhiteSpace($ComputerName)) {
        $script:CredentialCache[$ComputerName.ToLower()] = $Credential
        Save-DeviceCheckStoredCredential -ComputerName $ComputerName -Credential $Credential
    }
    $script:TargetSnapshot = $Snapshot
    $script:TargetSnapshotPath = $SnapshotPath
    $script:MachineEvidence = Convert-SnapshotMachineToMachineEvidence -Snapshot $Snapshot
    $script:MachineCacheRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath "machines\$($script:MachineEvidence.MachineId)"
    try { $null = New-Item -ItemType Directory -Path $script:MachineCacheRoot -Force } catch {}

    $script:categories = Get-DeviceCategoriesFromSnapshot -Snapshot $Snapshot
    $script:selectedIndex = 0
    $script:DetailScrollOffset = 0
    $script:DetailCursorIndex = 0
    $script:ActivePane = 'Tree'
    $script:VisibleRowsDirty = $true
    $script:visibleRows = Update-VisibleRows
    $script:VisibleRowsDirty = $false
    $script:RequestForceClear = $true

    $deviceCount = 0
    foreach ($category in $script:categories) {
        $deviceCount += @($category.Devices).Count
    }
    $script:SystemScanMessage = "Connected to $ComputerName snapshot: $deviceCount devices | $(Get-Date -Format 'HH:mm:ss')"
}

function Get-CurrentNetworkIdentity {
    $profileName = "Unknown Network"
    $gatewayMac = "00-00-00-00-00-00"
    $subnetId = "0.0.0.0"

    try {
        $profile = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object IPv4Connectivity -eq 'Internet' | Select-Object -First 1
        if ($null -eq $profile) {
            $profile = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($null -ne $profile) {
            $profileName = $profile.Name
        }
    } catch {}

    try {
        $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        if ($routes) {
            $gatewayIp = $routes[0].NextHop
            $neighbor = Get-NetNeighbor -IPAddress $gatewayIp -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($neighbor -and $neighbor.LinkLayerAddress) {
                $gatewayMac = $neighbor.LinkLayerAddress.ToUpper()
            }
        }
    } catch {}

    try {
        $ipInfo = $null
        if ($null -ne $profile) {
            $ipInfo = Get-NetIPAddress -InterfaceIndex $profile.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($null -eq $ipInfo) {
            $ipInfo = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
                Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet' } | 
                Select-Object -First 1
        }
        if ($ipInfo -and $ipInfo.IPAddress -match '^(\d+\.\d+\.\d+)\.\d+$') {
            $subnetId = $Matches[1]
        }
    } catch {}

    $networkId = "$profileName|$gatewayMac|$subnetId"
    return [PSCustomObject]@{
        NetworkId   = $networkId
        ProfileName = $profileName
        GatewayMac  = $gatewayMac
        SubnetId    = $subnetId
    }
}

function Get-DeviceCheckHostsCache {
    $path = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'hosts-cache.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
            $hash = @{}
            if ($null -ne $json) {
                foreach ($prop in $json.PSObject.Properties) {
                    $hash[$prop.Name] = $prop.Value
                }
            }
            return $hash
        } catch {}
    }
    return @{}
}

function Save-DeviceCheckHostsCache {
    param([Parameter(Mandatory)]$Cache)
    $path = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'hosts-cache.json'
    try {
        $json = $Cache | ConvertTo-Json -Depth 4
        $json | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {}
}

function Start-DeviceCheckBackgroundResolver {
    param([Parameter(Mandatory)][string[]]$IPs)
    if ($IPs.Count -eq 0) { return }
    $cachePath = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'hosts-cache.json'
    
    $null = Start-Job -ScriptBlock {
        param($ips, $path)
        $cache = @{}
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if ($null -ne $json) {
                    foreach ($prop in $json.PSObject.Properties) {
                        $cache[$prop.Name] = $prop.Value
                    }
                }
            } catch {}
        }
        $updated = $false
        foreach ($ip in $ips) {
            if (-not $cache.ContainsKey($ip)) {
                try {
                    $entry = [System.Net.Dns]::GetHostEntry($ip)
                    if ($entry.HostName) {
                        $name = $entry.HostName
                        if ($name -match '^([^.]+)\.') { $name = $Matches[1] }
                        $cache[$ip] = $name
                        $updated = $true
                    }
                } catch {
                    try {
                        $dnsRes = Resolve-DnsName -Name $ip -QuickTimeout -ErrorAction Stop
                        if ($dnsRes) {
                            $name = $dnsRes[0].NameHost
                            if ($name -match '^([^.]+)\.') { $name = $Matches[1] }
                            $cache[$ip] = $name
                            $updated = $true
                        }
                    } catch {}
                }
            }
        }
        if ($updated) {
            try {
                $json = $cache | ConvertTo-Json -Depth 4
                $json | Set-Content -LiteralPath $path -Encoding UTF8
            } catch {}
        }
    } -ArgumentList $IPs, $cachePath
}

function Get-DeviceCheckDiscoveredHosts {
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
    
    $discovered = [System.Collections.Generic.List[object]]::new()
    $results = @()
    
    # 1. Interfaces lookup
    $swPhase = [System.Diagnostics.Stopwatch]::StartNew()
    $interfaces = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet' }
    
    if (-not $interfaces) { 
        $timeInterfaces = $swPhase.Elapsed.TotalMilliseconds
        $logLines = @(
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] Network Scan Completed (No active interfaces)"
            "  Total Time       : $([Math]::Round($swTotal.Elapsed.TotalMilliseconds, 1)) ms"
            "  Phase 1 (Ifaces) : $([Math]::Round($timeInterfaces, 1)) ms"
        )
        if ($script:BenchmarkMode) {
            $script:LastNetworkScanResult = $logLines
            $resolvedScriptRoot = $script:DeviceCheckRepoRoot
            if ([string]::IsNullOrWhiteSpace($resolvedScriptRoot)) { $resolvedScriptRoot = $global:PSScriptRoot }
            if ([string]::IsNullOrWhiteSpace($resolvedScriptRoot)) { $resolvedScriptRoot = "." }
            $logsDir = Join-Path -Path $resolvedScriptRoot -ChildPath 'logs'
            if (-not (Test-Path -LiteralPath $logsDir)) { $null = New-Item -ItemType Directory -Path $logsDir -Force }
            $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
            $logFile = Join-Path -Path $logsDir -ChildPath "network_scan_$timestamp.log"
            try { $logLines | Out-File -FilePath $logFile -Append -Encoding utf8 } catch {}
        } else {
            $script:LastNetworkScanResult = $null
        }
        return $discovered 
    }
    $timeInterfaces = $swPhase.Elapsed.TotalMilliseconds

    # 2. History retrieval & Parallel DNS Lookup
    $swPhase.Restart()
    $historyIPs = @()
    $historyIpToName = @{}
    $history = Get-DeviceCheckConnectionHistory
    
    $dnsDetailsLog = [System.Collections.Generic.List[string]]::new()
    
    if ($history) {
        $ipList = [System.Collections.Generic.List[string]]::new()
        
        # Add static IP history entries instantly
        foreach ($entry in $history) {
            if ($entry.LastIPAddress -match '^\d+\.\d+\.\d+\.\d+$') {
                $ipList.Add($entry.LastIPAddress)
                $historyIpToName[$entry.LastIPAddress] = $entry.ComputerName
            }
        }
        
        # Filter hostnames that need DNS lookup
        $hostsToResolve = $history | Where-Object { 
            -not [string]::IsNullOrWhiteSpace($_.ComputerName) -and 
            $_.ComputerName -notmatch '^\d+\.\d+\.\d+\.\d+$' 
        } | Select-Object -ExpandProperty ComputerName -Unique
        
        if ($hostsToResolve) {
            $isPS6Plus = $PSVersionTable.PSVersion.Major -ge 6
            $hasResolveDnsName = $null -ne (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)
            
            $resolvedResults = $hostsToResolve | ForEach-Object -Parallel {
                $hostName = $_
                $ips = [System.Collections.Generic.List[string]]::new()
                $swSingle = [System.Diagnostics.Stopwatch]::StartNew()
                $methodUsed = "None"
                $hasResolveDns = $using:hasResolveDnsName
                
                if ($hasResolveDns) {
                    try {
                        $methodUsed = "Resolve-DnsName"
                        $resolved = Resolve-DnsName -Name $hostName -DnsOnly -QuickTimeout -ErrorAction Stop
                        if ($resolved) {
                            foreach ($r in $resolved) {
                                if ($r.IPAddress) {
                                    $ips.Add($r.IPAddress)
                                }
                            }
                        }
                    } catch {
                        # Resolve-DnsName failed (e.g. host offline). 
                        # methodUsed is already "Resolve-DnsName", which prevents the slow GetHostAddresses fallback.
                    }
                }
                
                if ($ips.Count -eq 0 -and $methodUsed -eq "None") {
                    try {
                        $dnsIps = [System.Net.Dns]::GetHostAddresses($hostName)
                        if ($dnsIps) {
                            $methodUsed = "GetHostAddresses"
                            foreach ($ip in $dnsIps) {
                                $ips.Add($ip.IPAddressToString)
                            }
                        }
                    } catch {}
                }
                
                $singleMs = $swSingle.Elapsed.TotalMilliseconds
                if ($ips.Count -gt 0) {
                    [PSCustomObject]@{
                        ComputerName = $hostName
                        IPs          = @($ips)
                        Success      = $true
                        Method       = $methodUsed
                        Duration     = $singleMs
                    }
                } else {
                    [PSCustomObject]@{
                        ComputerName = $hostName
                        IPs          = @()
                        Success      = $false
                        Method       = $methodUsed
                        Duration     = $singleMs
                    }
                }
            } -ThrottleLimit 10
            
            if ($resolvedResults) {
                foreach ($res in $resolvedResults) {
                    if ($null -ne $res) {
                        $dnsDetailsLog.Add("    Host '$($res.ComputerName)' resolved via $($res.Method) in $([Math]::Round($res.Duration, 1)) ms (Success: $($res.Success), IPs: $($res.IPs -join ', '))")
                        if ($res.Success) {
                            foreach ($ip in $res.IPs) {
                                $ipList.Add($ip)
                                $historyIpToName[$ip] = $res.ComputerName
                            }
                        }
                    }
                }
            }
        }
        $historyIPs = @($ipList | Select-Object -Unique)
    }
    $timeDns = $swPhase.Elapsed.TotalMilliseconds

    # 3. Clear OS-level negative ARP cache
    $swPhase.Restart()
    if ($historyIPs) {
        foreach ($ip in $historyIPs) {
            Remove-NetNeighbor -IPAddress $ip -Confirm:$false -ErrorAction SilentlyContinue
            try {
                arp.exe -d $ip *>$null
            } catch {}
        }
    }
    $timeArpClear = $swPhase.Elapsed.TotalMilliseconds

    # 4. Trigger active ICMP Ping discovery only for neighbor cache and history IPs (fast parallel Ping)
    $swPhase.Restart()
    
    # Get neighbors first to know which IPs to target
    $neighbors = foreach ($if in $interfaces) {
        Get-NetNeighbor -InterfaceIndex $if.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
            Where-Object { $_.State -ne 'Unreachable' -and $_.IPAddress -notmatch '^\d+\.\d+\.\d+\.255$' -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' }
    }
    
    # Filter out gateway IPs to avoid connecting to router
    $gateways = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    if ($routes) {
        foreach ($r in $routes) {
            if (-not [string]::IsNullOrWhiteSpace($r.NextHop)) {
                $null = $gateways.Add($r.NextHop)
            }
        }
    }
    
    # Filter out local machine IPs to avoid self-discovery
    $localIPs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($if in $interfaces) {
        $null = $localIPs.Add($if.IPAddress)
    }
    
    $neighborIPs = @()
    if ($neighbors) {
        $neighborIPs = @($neighbors.IPAddress)
    }
    
    # Combine neighbor cache IPs and history IPs
    $targetIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in $neighborIPs) { $null = $targetIPsSet.Add($ip) }
    foreach ($ip in $historyIPs) { $null = $targetIPsSet.Add($ip) }
    
    $targetIPs = @(
        $targetIPsSet | Where-Object { -not $gateways.Contains($_) -and -not $localIPs.Contains($_) }
    )
    
    $pingSuccessfulIPs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $pingTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
    
    if ($targetIPs) {
        foreach ($ip in $targetIPs) {
            try {
                $p = [System.Net.NetworkInformation.Ping]::new()
                $task = $p.SendPingAsync($ip, 250)
                $pingTasks.Add([PSCustomObject]@{
                    IP     = $ip
                    Pinger = $p
                    Task   = $task
                })
            } catch {}
        }
        
        if ($pingTasks.Count -gt 0) {
            $tasksArray = [System.Threading.Tasks.Task[]]::new($pingTasks.Count)
            for ($i = 0; $i -lt $pingTasks.Count; $i++) {
                $tasksArray[$i] = $pingTasks[$i].Task
            }
            try {
                $null = [System.Threading.Tasks.Task]::WaitAll($tasksArray, 300)
            } catch {}
        }
        
        foreach ($pt in $pingTasks) {
            if ($pt.Task.IsCompleted -and -not $pt.Task.IsFaulted -and $pt.Task.Result.Status -eq 'Success') {
                $null = $pingSuccessfulIPs.Add($pt.IP)
            }
            $pt.Pinger.Dispose()
        }
    }
    
    $timePing = $swPhase.Elapsed.TotalMilliseconds
    
    # 5. Neighbor/Active Target Setup
    $swPhase.Restart()
    $uniqueIPs = $targetIPs
    $timeNeighbors = $swPhase.Elapsed.TotalMilliseconds
    
    # 6. Fast parallel TCP scan on port 5985 and 445
    $swPhase.Restart()
    $winrmOpenIPs = [System.Collections.Generic.List[string]]::new()
    $smbOpenIPs = [System.Collections.Generic.List[string]]::new()
    
    if ($uniqueIPs) {
        $connections = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($ip in $uniqueIPs) {
            $tcp1 = [System.Net.Sockets.TcpClient]::new()
            $tcp2 = [System.Net.Sockets.TcpClient]::new()
            try {
                $ipObj = [System.Net.IPAddress]::Parse($ip)
                $task1 = $tcp1.ConnectAsync($ipObj, 5985)
                $task2 = $tcp2.ConnectAsync($ipObj, 445)
                $connections.Add([PSCustomObject]@{
                    IP         = $ip
                    TcpClient1 = $tcp1
                    Task1      = $task1
                    TcpClient2 = $tcp2
                    Task2      = $task2
                })
            } catch {
                $tcp1.Dispose()
                $tcp2.Dispose()
            }
        }
        
        # Wait up to 500ms for connection tasks to complete
        $swTimeout = [System.Diagnostics.Stopwatch]::StartNew()
        while ($swTimeout.ElapsedMilliseconds -lt 500) {
            $allDone = $true
            foreach ($c in $connections) {
                if (-not $c.Task1.IsCompleted -or -not $c.Task2.IsCompleted) {
                    $allDone = $false
                    break
                }
            }
            if ($allDone) { break }
            Start-Sleep -Milliseconds 20
        }
        $swTimeout.Stop()
        
        foreach ($c in $connections) {
            $winrmConnected = $c.Task1.IsCompleted -and $c.TcpClient1.Connected
            $smbConnected = $c.Task2.IsCompleted -and $c.TcpClient2.Connected
            
            if ($winrmConnected) {
                $winrmOpenIPs.Add($c.IP)
            } elseif ($smbConnected) {
                $smbOpenIPs.Add($c.IP)
            }
            
            $c.TcpClient1.Dispose()
            $c.TcpClient2.Dispose()
        }
    }
    $timeTcpScan = $swPhase.Elapsed.TotalMilliseconds
    
    # 7. Asynchronous Hostname Resolution for Online Hosts
    $swPhase.Restart()
    
    # Online hosts are those that have WinRM open or SMB open (excluding ping-only hosts to filter out sleeping PCs in Modern Standby or non-Windows devices)
    $onlineIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in $winrmOpenIPs) { $null = $onlineIPsSet.Add($ip) }
    foreach ($ip in $smbOpenIPs) { $null = $onlineIPsSet.Add($ip) }
    
    $onlineIPs = @($onlineIPsSet)
    $resolvedNames = @{}
    $hostsCache = Get-DeviceCheckHostsCache
    
    $unresolvedIPs = [System.Collections.Generic.List[string]]::new()
    foreach ($ip in $onlineIPs) {
        if ($historyIpToName.ContainsKey($ip)) {
            $resolvedNames[$ip] = $historyIpToName[$ip]
        } elseif ($hostsCache.ContainsKey($ip)) {
            $resolvedNames[$ip] = $hostsCache[$ip]
        } else {
            $unresolvedIPs.Add($ip)
        }
    }
    
    if ($unresolvedIPs.Count -gt 0) {
        $resolutionTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($ip in $unresolvedIPs) {
            # Start asynchronous NetBIOS/DNS resolution
            try {
                $dnsTask = [System.Net.Dns]::GetHostEntryAsync($ip)
                $resolutionTasks.Add([PSCustomObject]@{
                    IP   = $ip
                    Task = $dnsTask
                })
            } catch {}
        }
        
        if ($resolutionTasks.Count -gt 0) {
            $resTasksArray = [System.Threading.Tasks.Task[]]::new($resolutionTasks.Count)
            for ($i = 0; $i -lt $resolutionTasks.Count; $i++) {
                $resTasksArray[$i] = $resolutionTasks[$i].Task
            }
            try {
                $null = [System.Threading.Tasks.Task]::WaitAll($resTasksArray, 400)
            } catch {}
            
            $newlyResolved = @{}
            foreach ($rt in $resolutionTasks) {
                if ($rt.Task.IsCompleted -and -not $rt.Task.IsFaulted -and $rt.Task.Result.HostName) {
                    $hostName = $rt.Task.Result.HostName
                    if ($hostName -match '^([^.]+)\.') { $hostName = $Matches[1] }
                    $resolvedNames[$rt.IP] = $hostName
                    $newlyResolved[$rt.IP] = $hostName
                }
            }
            if ($newlyResolved.Count -gt 0) {
                foreach ($ip in $newlyResolved.Keys) {
                    $hostsCache[$ip] = $newlyResolved[$ip]
                }
                Save-DeviceCheckHostsCache -Cache $hostsCache
            }
        }
    }
    
    # Fallback to local DNS/IP lookup if async GetHostEntry failed or timed out
    $stillUnresolved = [System.Collections.Generic.List[string]]::new()
    foreach ($ip in $onlineIPs) {
        if (-not $resolvedNames.ContainsKey($ip)) {
            try {
                $dnsRes = Resolve-DnsName -Name $ip -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue
                if ($dnsRes) {
                    $dnsName = $dnsRes[0].NameHost
                    if ($dnsName -match '^([^.]+)\.') { $dnsName = $Matches[1] }
                    $resolvedNames[$ip] = $dnsName
                    $hostsCache[$ip] = $dnsName
                    Save-DeviceCheckHostsCache -Cache $hostsCache
                } else {
                    $resolvedNames[$ip] = $ip
                    $stillUnresolved.Add($ip)
                }
            } catch {
                $resolvedNames[$ip] = $ip
                $stillUnresolved.Add($ip)
            }
        }
    }
    
    # Resolve unresolved IPs in background to populate cache for future scans
    if ($stillUnresolved.Count -gt 0) {
        Start-DeviceCheckBackgroundResolver -IPs @($stillUnresolved)
    }
    
    # Build final scan results list
    $scanResultsList = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($ip in $onlineIPs) {
        $name = $resolvedNames[$ip]
        $isWinRm = $ip -in $winrmOpenIPs
        $isSmb = $ip -in $smbOpenIPs
        $scanResultsList.Add([PSCustomObject]@{
            IP        = $ip
            HostName  = $name
            WinRmOpen = $isWinRm
            SmbOpen   = $isSmb
        })
    }
    
    $results = @($scanResultsList)
    
    # Final mapping & MAC lookup
    $latestNeighbors = foreach ($if in $interfaces) {
        Get-NetNeighbor -InterfaceIndex $if.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    }
    $macLookup = @{}
    if ($latestNeighbors) {
        foreach ($n in $latestNeighbors) {
            if (-not [string]::IsNullOrWhiteSpace($n.IPAddress) -and -not [string]::IsNullOrWhiteSpace($n.LinkLayerAddress)) {
                $macLookup[$n.IPAddress] = $n.LinkLayerAddress.Replace(':', '-').ToUpper()
            }
        }
    }
    
    foreach ($res in $results) {
        if ($null -ne $res) {
            $mac = 'Unknown'
            if ($macLookup.ContainsKey($res.IP)) {
                $mac = $macLookup[$res.IP]
            }
            $discovered.Add([PSCustomObject]@{
                IP        = $res.IP
                HostName  = $res.HostName
                MAC       = $mac
                WinRmOpen = $res.WinRmOpen
                SmbOpen   = $res.SmbOpen
            })
        }
    }
    $timeFinalMap = $swPhase.Elapsed.TotalMilliseconds
    
    $totalMs = $swTotal.Elapsed.TotalMilliseconds
    
    # Write details and phases to benchmark log
    $logLines = [System.Collections.Generic.List[string]]::new()
    $logLines.Add("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] Network Scan Completed")
    $logLines.Add("  Total Time       : $([Math]::Round($totalMs, 1)) ms")
    $logLines.Add("  Phase 1 (Ifaces) : $([Math]::Round($timeInterfaces, 1)) ms")
    $logLines.Add("  Phase 2 (DNS)    : $([Math]::Round($timeDns, 1)) ms")
    if ($dnsDetailsLog.Count -gt 0) {
        foreach ($logDnsLine in $dnsDetailsLog) {
            $logLines.Add($logDnsLine)
        }
    }
    $logLines.Add("  Phase 3 (ArpClr) : $([Math]::Round($timeArpClear, 1)) ms")
    $logLines.Add("  Phase 4 (Ping)   : $([Math]::Round($timePing, 1)) ms")
    $logLines.Add("  Phase 5 (Neighbr): $([Math]::Round($timeNeighbors, 1)) ms")
    $logLines.Add("  Phase 6 (TCPScan): $([Math]::Round($timeTcpScan, 1)) ms")
    $logLines.Add("  Phase 7 (Reverse): $([Math]::Round($timeFinalMap, 1)) ms")
    $logLines.Add("  Scan Results     : $($discovered.Count) hosts found ($($uniqueIPs.Count) unique IPs scanned)")
    $logLines.Add("")
    
    if ($script:BenchmarkMode) {
        $script:LastNetworkScanResult = @($logLines)
        $resolvedScriptRoot = $script:DeviceCheckRepoRoot
        if ([string]::IsNullOrWhiteSpace($resolvedScriptRoot)) { $resolvedScriptRoot = $global:PSScriptRoot }
        if ([string]::IsNullOrWhiteSpace($resolvedScriptRoot)) { $resolvedScriptRoot = "." }
        $logsDir = Join-Path -Path $resolvedScriptRoot -ChildPath 'logs'
        if (-not (Test-Path -LiteralPath $logsDir)) { $null = New-Item -ItemType Directory -Path $logsDir -Force }
        $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $logFile = Join-Path -Path $logsDir -ChildPath "network_scan_$timestamp.log"
        try {
            $logLines | Out-File -FilePath $logFile -Append -Encoding utf8
        } catch {}
    } else {
        $script:LastNetworkScanResult = $null
    }
    
    return $discovered
}

function Get-DeviceCheckConnectionHistory {
    $path = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'connection-history.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $history = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($history -is [Array]) {
                return [System.Collections.Generic.List[object]]::new($history)
            } else {
                return [System.Collections.Generic.List[object]]::new(@($history))
            }
        } catch {}
    }
    return [System.Collections.Generic.List[object]]::new()
}

function Save-DeviceCheckConnectionHistory {
    param([Parameter(Mandatory)]$History)
    $path = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'connection-history.json'
    try {
        $json = $History | ConvertTo-Json -Depth 4
        $json | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {}
}

function Add-DeviceCheckConnectionHistoryEntry {
    param(
        [string]$ComputerName,
        [string]$LastIPAddress,
        [string]$MACAddress,
        [string]$UserName,
        [string]$NetworkId
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return }
    $historyList = Get-DeviceCheckConnectionHistory
    $history = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $historyList) {
        foreach ($item in @($historyList)) {
            $history.Add($item)
        }
    }
    
    $existing = $null
    foreach ($entry in $history) {
        if ($entry.NetworkId -eq $NetworkId) {
            if ($entry.ComputerName.ToLower() -eq $ComputerName.ToLower()) {
                $existing = $entry
                break
            }
            if ($entry.ComputerName -match '^\d+\.\d+\.\d+\.\d+$' -and ($entry.ComputerName -eq $LastIPAddress -or $entry.LastIPAddress -eq $LastIPAddress)) {
                $existing = $entry
                break
            }
        }
    }

    if ($null -ne $existing) {
        if ($existing.ComputerName -match '^\d+\.\d+\.\d+\.\d+$' -and $ComputerName -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            $existing.ComputerName = $ComputerName
        }
        $existing.LastIPAddress = $LastIPAddress
        if (-not [string]::IsNullOrWhiteSpace($MACAddress) -and $MACAddress -ne 'Unknown') {
            $existing.MACAddress = $MACAddress
        }
        $existing.UserName = $UserName
        $existing.LastConnected = (Get-Date).ToString('o')
    } else {
        $newEntry = [PSCustomObject]@{
            ComputerName    = $ComputerName
            LastIPAddress   = $LastIPAddress
            MACAddress      = $(if ([string]::IsNullOrWhiteSpace($MACAddress)) { 'Unknown' } else { $MACAddress })
            UserName        = $UserName
            NetworkId       = $NetworkId
            LastConnected   = (Get-Date).ToString('o')
        }
        $history.Add($newEntry)
    }

    $sortedHistory = [System.Collections.Generic.List[object]]::new(
        @($history | Sort-Object { [DateTime]$_.LastConnected } -Descending)
    )
    Save-DeviceCheckConnectionHistory -History $sortedHistory
}

function Get-DeviceCheckNetworkLabel {
    param([string]$NetworkId)

    if ([string]::IsNullOrWhiteSpace($NetworkId)) { return 'snapshot only' }
    $parts = $NetworkId -split '\|'
    if ($parts.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($parts[0])) {
        return $parts[0]
    }
    return 'unknown network'
}

function Test-DeviceCheckHistoryEntryOnline {
    param(
        $Entry,
        $DiscoveredHosts,
        [string]$CurrentNetworkId
    )

    foreach ($d in @($DiscoveredHosts)) {
        $nameMatch = $false
        if (-not [string]::IsNullOrWhiteSpace($Entry.ComputerName) -and -not [string]::IsNullOrWhiteSpace($d.HostName)) {
            $nameMatch = ($Entry.ComputerName.ToLower() -eq $d.HostName.ToLower())
        }
        $macMatch = $false
        if (-not [string]::IsNullOrWhiteSpace($Entry.MACAddress) -and $Entry.MACAddress -ne 'Unknown' -and -not [string]::IsNullOrWhiteSpace($d.MAC) -and $d.MAC -ne 'Unknown') {
            $macMatch = ($Entry.MACAddress.Replace(':', '-').ToLower() -eq $d.MAC.Replace(':', '-').ToLower())
        }
        $ipMatch = $false
        if ($Entry.NetworkId -eq $CurrentNetworkId -and -not [string]::IsNullOrWhiteSpace($Entry.LastIPAddress)) {
            $ipMatch = ($Entry.LastIPAddress -eq $d.IP)
        }
        if ($nameMatch -or $macMatch -or $ipMatch) {
            return [PSCustomObject]@{
                IsOnline   = $true
                WinRmOpen  = [bool]$d.WinRmOpen
                ResolvedIP = $d.IP
            }
        }
    }

    return [PSCustomObject]@{
        IsOnline   = $false
        WinRmOpen  = $false
        ResolvedIP = $Entry.LastIPAddress
    }
}

function Get-DeviceCheckLatestSnapshotEntries {
    $snapshotsRoot = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'snapshots'
    if (-not (Test-Path -LiteralPath $snapshotsRoot -PathType Container)) {
        return @()
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -Path $snapshotsRoot -Recurse -Filter 'latest.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $snapshot = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            $collector = Get-NotePropertyValue -Object $snapshot -Name 'Collector'
            $machine = Get-NotePropertyValue -Object $snapshot -Name 'Machine'
            $computerSystem = Get-NotePropertyValue -Object $machine -Name 'ComputerSystem'
            $computerName = [string](Get-NotePropertyValue -Object $collector -Name 'TargetComputerName')
            if ([string]::IsNullOrWhiteSpace($computerName)) {
                $computerName = [string](Get-NotePropertyValue -Object $computerSystem -Name 'Name')
            }
            if ([string]::IsNullOrWhiteSpace($computerName)) {
                $computerName = $file.Directory.Name
            }

            $devicesRoot = Get-NotePropertyValue -Object $snapshot -Name 'Devices'
            $deviceCount = [string](Get-NotePropertyValue -Object $devicesRoot -Name 'Count')
            if ([string]::IsNullOrWhiteSpace($deviceCount)) {
                $deviceCount = [string](@((Get-NotePropertyValue -Object $devicesRoot -Name 'Present')).Count)
            }

            $entries.Add([PSCustomObject]@{
                ComputerName    = $computerName
                RequestedTarget = [string](Get-NotePropertyValue -Object $collector -Name 'RequestedComputerName')
                FinishedAt      = [string](Get-NotePropertyValue -Object $collector -Name 'FinishedAt')
                DeviceCount     = $deviceCount
                SnapshotPath    = $file.FullName
                Snapshot        = $snapshot
            })
        } catch {}
    }

    return @($entries | Sort-Object FinishedAt -Descending)
}

function Test-PortOpen {
    param(
        [string]$ComputerName,
        [int]$Port = 5985,
        [int]$TimeoutMs = 1500
    )

    $tcp = [System.Net.Sockets.TcpClient]::new()
    $cts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $task = $tcp.ConnectAsync($ComputerName, $Port, $cts.Token)
            $task.GetAwaiter().GetResult()
        } else {
            $task = $tcp.ConnectAsync($ComputerName, $Port)
            $null = $task.Wait($TimeoutMs)
        }
        return $tcp.Connected
    } catch {
        return $false
    } finally {
        $cts.Dispose()
        $tcp.Dispose()
    }
}

function Resolve-HistoryTargetAddress {
    param(
        [string]$ComputerName,
        [string]$LastIPAddress,
        [string]$MACAddress
    )

    Write-Verbose "Resolving address for target $ComputerName..."
    
    # 1. Try to resolve the hostname directly via DNS/LLMNR
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($ComputerName)
        if ($ips) {
            $resolvedIp = $ips[0].IPAddressToString
            if (Test-PortOpen -ComputerName $resolvedIp -Port 5985) {
                return $resolvedIp
            }
        }
    } catch {}

    try {
        $resolved = Resolve-DnsName -Name $ComputerName -ErrorAction SilentlyContinue
        if ($resolved) {
            foreach ($r in $resolved) {
                if ($r.IPAddress -and (Test-PortOpen -ComputerName $r.IPAddress -Port 5985)) {
                    return $r.IPAddress
                }
            }
        }
    } catch {}

    # 2. Check local ARP cache
    if (-not [string]::IsNullOrWhiteSpace($MACAddress) -and $MACAddress -ne 'Unknown') {
        $normMAC = $MACAddress.Replace(':', '-').ToUpper()
        $neighbors = Get-NetNeighbor -ErrorAction SilentlyContinue | 
            Where-Object { 
                $nMac = $_.LinkLayerAddress
                if ($nMac) { $nMac = $nMac.Replace(':', '-').ToUpper() }
                $nMac -eq $normMAC -and $_.InterfaceAlias -notmatch 'Loopback|vEthernet' 
            }
        if ($neighbors) {
            $arpIp = $neighbors[0].IPAddress
            if (Test-PortOpen -ComputerName $arpIp -Port 5985) {
                return $arpIp
            }
        }
    }

    # 3. Fallback to last known IP
    if (-not [string]::IsNullOrWhiteSpace($LastIPAddress)) {
        if (Test-PortOpen -ComputerName $LastIPAddress -Port 5985) {
            return $LastIPAddress
        }
    }

    return $null
}

function Invoke-ConnectionHistorySelector {
    param(
        [Parameter(Mandatory)]$NetworkInfo,
        $DiscoveredHosts = @()
    )

    if ($null -eq $DiscoveredHosts) {
        $DiscoveredHosts = @()
    }

    $currentDiscovered = $DiscoveredHosts

    $networkId = $NetworkInfo.NetworkId
    $networkName = $NetworkInfo.ProfileName

    $resolvedScriptRoot = $script:DeviceCheckRepoRoot
    if ([string]::IsNullOrWhiteSpace($resolvedScriptRoot)) { $resolvedScriptRoot = $global:PSScriptRoot }
    if ([string]::IsNullOrWhiteSpace($resolvedScriptRoot)) { $resolvedScriptRoot = "." }

    [Console]::CursorVisible = $false
    try {
        $selectedIndex = -1
        $needsReload = $true
        $allHistory = $null
        $filteredHistory = $null
        $offlineEntries = $null
        $logLines = $null

        while ($true) {
            Lock-ViewportToWindow
            
            # Measure Prep
            $swPrep = [System.Diagnostics.Stopwatch]::StartNew()
            if ($needsReload) {
                $allHistory = Get-DeviceCheckConnectionHistory
                if ($null -eq $allHistory) {
                    $allHistory = [System.Collections.Generic.List[object]]::new()
                }
                $filteredHistory = [System.Collections.Generic.List[object]]::new()
                foreach ($entry in $allHistory) {
                    if ($entry.NetworkId -eq $networkId) {
                        $filteredHistory.Add($entry)
                    }
                }
                $offlineEntries = @(Get-DeviceCheckOfflineMenuEntries -AllHistory $allHistory -CurrentDiscovered $currentDiscovered -CurrentNetworkId $networkId)
                if ($script:BenchmarkMode) {
                    $logLines = $script:LastNetworkScanResult
                    if ($null -eq $logLines -or $logLines.Count -eq 0) {
                        $logsDir = Join-Path -Path $resolvedScriptRoot -ChildPath 'logs'
                        if (Test-Path -LiteralPath $logsDir) {
                            $latestLog = Get-ChildItem -Path $logsDir -Filter 'network_scan_*.log' -File -ErrorAction SilentlyContinue |
                                Where-Object { $_.LastWriteTime -ge $script:ScriptStartTime } |
                                Sort-Object LastWriteTime -Descending |
                                Select-Object -First 1
                            if ($latestLog) {
                                $logLines = @(Get-Content -LiteralPath $latestLog.FullName -ErrorAction SilentlyContinue)
                            }
                        }
                    }
                }
                $needsReload = $false
            }
            $prepMs = $swPrep.Elapsed.TotalMilliseconds
            $swPrep.Stop()

            # Measure Render
            $swRender = [System.Diagnostics.Stopwatch]::StartNew()
            $items = [System.Collections.Generic.List[object]]::new()
            
            # Section 1: Saved Connections
            $items.Add([PSCustomObject]@{
                Type       = 'Header'
                Text       = "$($_C.Bold)$($_C.Info)Saved Connections (Active)$($_C.Reset)"
                Selectable = $false
            })

            $savedCount = 0
            foreach ($entry in $filteredHistory) {
                $online = Test-DeviceCheckHistoryEntryOnline -Entry $entry -DiscoveredHosts $currentDiscovered -CurrentNetworkId $networkId
                if (-not $online.IsOnline) {
                    continue
                }

                $savedCount++
                $onlineText = $(if ($online.WinRmOpen) { " (Online)" } else { " (WinRM Disabled)" })
                $displayText = "$($entry.ComputerName) ($($online.ResolvedIP)) - user: $($entry.UserName)$onlineText"

                $items.Add([PSCustomObject]@{
                    Type          = 'Saved'
                    Text          = $displayText
                    Selectable    = $true
                    Data          = $entry
                    IsOnline      = $true
                    WinRmOpen     = $online.WinRmOpen
                    ResolvedIP    = $online.ResolvedIP
                    Source        = 'History'
                    SourceNetwork = Get-DeviceCheckNetworkLabel -NetworkId $entry.NetworkId
                })
            }

            if ($savedCount -eq 0) {
                $items.Add([PSCustomObject]@{
                    Type       = 'Placeholder'
                    Text       = "  $($_C.Dim)(No active saved connections on this network)$($_C.Reset)"
                    Selectable = $false
                })
            }

            $items.Add([PSCustomObject]@{
                Type       = 'Separator'
                Text       = ""
                Selectable = $false
            })

            # Section 2: Offline snapshot library
            $items.Add([PSCustomObject]@{
                Type       = 'Header'
                Text       = "$($_C.Bold)$($_C.Info)Offline Snapshots$($_C.Reset)"
                Selectable = $false
            })

            # Using cached $offlineEntries
            if ($offlineEntries.Count -gt 0) {
                $offlineNetworkCount = @($offlineEntries | Group-Object NetworkLabel).Count
                $offlineSnapshotCount = @($offlineEntries | Where-Object { $_.HasSnapshot }).Count
                $offlineHistoryOnlyCount = @($offlineEntries | Where-Object { -not $_.HasSnapshot }).Count
                $historyOnlyText = $(if ($offlineHistoryOnlyCount -gt 0) { ", $offlineHistoryOnlyCount no snapshot" } else { "" })
                $items.Add([PSCustomObject]@{
                    Type          = 'OfflineLibrary'
                    Text          = "[Offline Snapshots...] - $($offlineEntries.Count) pcs / $offlineNetworkCount networks / $offlineSnapshotCount snapshots$historyOnlyText"
                    Selectable    = $true
                    IsOnline      = $false
                    WinRmOpen     = $false
                    Data          = $null
                    Source        = 'Library'
                })
            } else {
                $items.Add([PSCustomObject]@{
                    Type       = 'Placeholder'
                    Text       = "  $($_C.Dim)(No offline snapshots or offline history targets found)$($_C.Reset)"
                    Selectable = $false
                })
            }
            
            $items.Add([PSCustomObject]@{
                Type       = 'Separator'
                Text       = ""
                Selectable = $false
            })
            
            # Section 3: Discovered PCs
            $items.Add([PSCustomObject]@{
                Type       = 'Header'
                Text       = "$($_C.Bold)$($_C.Info)Discovered PCs on Network$($_C.Reset)"
                Selectable = $false
            })
            
            $discoveredCount = 0
            foreach ($d in $currentDiscovered) {
                # Check if already in history
                $inHistory = $false
                foreach ($entry in $filteredHistory) {
                    if ($entry.ComputerName.ToLower() -eq $d.HostName.ToLower() -or $entry.LastIPAddress -eq $d.IP) {
                        $inHistory = $true
                        break
                    }
                }
                
                if (-not $inHistory) {
                    $discoveredCount++
                    $statusLabel = $(if ($d.WinRmOpen) { "(Online)" } else { "(WinRM Disabled)" })
                    $displayText = "$($d.HostName) ($($d.IP)) $statusLabel"
                    $items.Add([PSCustomObject]@{
                        Type       = 'Discovered'
                        Text       = $displayText
                        Selectable = $true
                        Data       = $d
                        IsOnline   = $true
                        WinRmOpen  = $d.WinRmOpen
                    })
                }
            }
            
            if ($discoveredCount -eq 0) {
                $items.Add([PSCustomObject]@{
                    Type       = 'Placeholder'
                    Text       = "  $($_C.Dim)(No other active PCs detected)$($_C.Reset)"
                    Selectable = $false
                })
            }
            
            $items.Add([PSCustomObject]@{
                Type       = 'Separator'
                Text       = ""
                Selectable = $false
            })
            
            # Section 4: Options/Actions
            $items.Add([PSCustomObject]@{
                Type       = 'Header'
                Text       = "$($_C.Bold)$($_C.Info)Actions$($_C.Reset)"
                Selectable = $false
            })
            
            $items.Add([PSCustomObject]@{
                Type       = 'Action'
                Text       = "[Connect to new target...]"
                Selectable = $true
                Data       = $null
                IsOnline   = $false
            })

            # Section 5: Scan Benchmark Results (if BenchmarkMode is ON)
            if ($script:BenchmarkMode) {
                $items.Add([PSCustomObject]@{
                    Type       = 'Separator'
                    Text       = ""
                    Selectable = $false
                })
                $items.Add([PSCustomObject]@{
                    Type       = 'Header'
                    Text       = "$($_C.Bold)$($_C.Info)Scan Benchmark Results$($_C.Reset)"
                    Selectable = $false
                })
                
                # Using cached $logLines
                
                if ($logLines) {
                    $lastScanIndex = -1
                    for ($i = $logLines.Count - 1; $i -ge 0; $i--) {
                        if ($logLines[$i] -match 'Network Scan Completed') {
                            $lastScanIndex = $i
                            break
                        }
                    }
                    if ($lastScanIndex -ne -1) {
                        for ($i = $lastScanIndex; $i -lt $logLines.Count; $i++) {
                            $line = $logLines[$i]
                            if (-not [string]::IsNullOrWhiteSpace($line)) {
                                $cleanLine = $line
                                if ($line -match 'Network Scan Completed') {
                                    $cleanLine = "$($_C.OK)$line$($_C.Reset)"
                                } elseif ($line -match 'Total Time|Phase \d') {
                                    $cleanLine = $line -replace '(Total Time|Phase \d \([^)]+\))', "$($_C.Gold)`$1$($_C.Reset)"
                                }
                                $items.Add([PSCustomObject]@{
                                    Type       = 'BenchmarkLine'
                                    Text       = "  $cleanLine"
                                    Selectable = $false
                                })
                            }
                        }
                    }
                } else {
                    $items.Add([PSCustomObject]@{
                        Type       = 'BenchmarkLine'
                        Text       = "  $($_C.Dim)(No scans run yet)$($_C.Reset)"
                        Selectable = $false
                    })
                }
            }

            # Initialize selectedIndex on the first selectable item if not set
            if ($selectedIndex -lt 0 -or $selectedIndex -ge $items.Count) {
                $selectedIndex = 0
                for ($i = 0; $i -lt $items.Count; $i++) {
                    if ($items[$i].Selectable) {
                        $selectedIndex = $i
                        break
                    }
                }
            } else {
                # Ensure the current selectedIndex is on a selectable item
                if (-not $items[$selectedIndex].Selectable) {
                    $found = $false
                    for ($i = $selectedIndex; $i -lt $items.Count; $i++) {
                        if ($items[$i].Selectable) {
                            $selectedIndex = $i
                            $found = $true
                            break
                        }
                    }
                    if (-not $found) {
                        for ($i = $selectedIndex; $i -ge 0; $i--) {
                            if ($items[$i].Selectable) {
                                $selectedIndex = $i
                                $found = $true
                                break
                            }
                        }
                    }
                }
            }

            try {
                $maxVisible = [Math]::Max(3, $Host.UI.RawUI.WindowSize.Height - 10)
            } catch {
                $maxVisible = 10
            }

            $viewTop = [Math]::Max(0, [Math]::Min($selectedIndex - [int]($maxVisible / 2), [Math]::Max(0, $items.Count - $maxVisible)))
            $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $items.Count - 1)

            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title 'Connect to LAN PC' -Subtitle "Active Network: $networkName (MAC Gateway: $($NetworkInfo.GatewayMac))" -Width (Get-UiWidth)
            Add-UiFrameLine -Frame $frame

            $aboveMessage = $(if ($viewTop -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Up) $viewTop more above$($_C.Reset)" } else { '' })
            Add-UiFrameLine -Frame $frame -Text "$aboveMessage$($_C.EraseLn)"

            for ($index = $viewTop; $index -le $viewBot; $index++) {
                $item = $items[$index]
                if ($item.Type -eq 'Header') {
                    Add-UiFrameLine -Frame $frame -Text "  $($item.Text)$($_C.EraseLn)"
                } elseif ($item.Type -eq 'Separator') {
                    Add-UiFrameLine -Frame $frame -Text "$($_C.EraseLn)"
                } elseif ($item.Type -eq 'Placeholder') {
                    Add-UiFrameLine -Frame $frame -Text "$($item.Text)$($_C.EraseLn)"
                } elseif ($item.Type -eq 'BenchmarkLine') {
                    Add-UiFrameLine -Frame $frame -Text "  $($item.Text)$($_C.Reset)$($_C.EraseLn)"
                } else {
                    if ($index -eq $selectedIndex) {
                        $statusText = ""
                        $cleanText = $item.Text
                        if ($item.Type -in @('Saved', 'OfflineSnapshot', 'Discovered')) {
                            $cleanText = $item.Text -replace '\s*\((Online|Offline|WinRM Disabled)\)\s*$'
                            if (-not $item.IsOnline) {
                                $statusColor = $_C.Fail
                                $statusLabel = "(Offline)"
                            } elseif ($item.WinRmOpen) {
                                $statusColor = $_C.OK
                                $statusLabel = "(Online)"
                            } else {
                                $statusColor = $_C.Warn
                                $statusLabel = "(WinRM Disabled)"
                            }
                            $statusText = " $statusColor$statusLabel$($_C.Reset)$($_C.SelBg)$($_C.SelFg)$($_C.Bold)"
                        }
                        Add-UiFrameLine -Frame $frame -Text "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $($cleanText)$($statusText) $($_C.Reset)$($_C.EraseLn)"
                    } else {
                        if ($item.Type -eq 'Action' -or $item.Type -eq 'OfflineLibrary') {
                            Add-UiFrameLine -Frame $frame -Text "    $($_C.OK)$($item.Text)$($_C.Reset)$($_C.EraseLn)"
                        } else {
                            $onlineColor = $(
                                if (-not $item.IsOnline) {
                                    " $($_C.Fail)(Offline)$($_C.Reset)"
                                } elseif ($item.WinRmOpen) {
                                    " $($_C.OK)(Online)$($_C.Reset)"
                                } else {
                                    " $($_C.Warn)(WinRM Disabled)$($_C.Reset)"
                                }
                            )
                            $baseText = $(if ($item.Type -eq 'Saved') {
                                "$($item.Data.ComputerName) ($($item.ResolvedIP)) - user: $($item.Data.UserName)"
                            } elseif ($item.Type -eq 'OfflineSnapshot') {
                                "$($_C.Dim)$($item.Text -replace '\s*\(Offline\)\s*$','')$($_C.Reset)"
                            } else {
                                "$($item.Data.HostName) ($($item.Data.IP))"
                            })
                            Add-UiFrameLine -Frame $frame -Text "    $($_C.White)$baseText$onlineColor$($_C.Reset)$($_C.EraseLn)"
                        }
                    }
                }
            }

            $below = $items.Count - 1 - $viewBot
            $belowMessage = $(if ($below -gt 0) { "  $($_C.Dim)$(Get-UiGlyph -Name Down) $below more below$($_C.Reset)" } else { '' })
            Add-UiFrameLine -Frame $frame -Text "$belowMessage$($_C.EraseLn)"
            Add-UiFrameLine -Frame $frame -Text "$($_C.EraseLn)"

            $benchmarkStatus = $(if ($script:BenchmarkMode) { "ON" } else { "OFF" })
            $segments = @(
                New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
                New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'R' -Color $_C.Info
                New-UiShortcutSegment -Text ' = rescan   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'B' -Color $_C.Gold
                New-UiShortcutSegment -Text " = benchmark ($benchmarkStatus)   " -Color $_C.Dim
                New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
                New-UiShortcutSegment -Text ' = select   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Del' -Color $_C.Fail
                New-UiShortcutSegment -Text ' = delete history   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
                New-UiShortcutSegment -Text ' = cancel' -Color $_C.Dim
            )
            Add-UiFrameShortcutSegments -Frame $frame -Segments $segments
            Write-UiFrame -Frame $frame
            $renderMs = $swRender.Elapsed.TotalMilliseconds
            $swRender.Stop()

            $swKey = [System.Diagnostics.Stopwatch]::StartNew()
            $key = Read-ConsoleKey
            $keyReadMs = $swKey.Elapsed.TotalMilliseconds
            $swKey.Stop()

            if ($null -eq $key -or -not $key.PSObject.Properties['Key']) {
                continue
            }

            $swProcess = [System.Diagnostics.Stopwatch]::StartNew()
            switch ($key.Key) {
                'B' {
                    $script:BenchmarkMode = -not $script:BenchmarkMode
                    Save-ModelSelection
                    $needsReload = $true
                }
                'UpArrow' {
                    $newIdx = $selectedIndex
                    while ($newIdx -gt 0) {
                        $newIdx--
                        if ($items[$newIdx].Selectable) {
                            $selectedIndex = $newIdx
                            break
                        }
                    }
                }
                'DownArrow' {
                    $newIdx = $selectedIndex
                    while ($newIdx -lt ($items.Count - 1)) {
                        $newIdx++
                        if ($items[$newIdx].Selectable) {
                            $selectedIndex = $newIdx
                            break
                        }
                    }
                }
                'PageUp' {
                    $count = 0
                    $newIdx = $selectedIndex
                    while ($newIdx -gt 0 -and $count -lt $maxVisible) {
                        $newIdx--
                        if ($items[$newIdx].Selectable) {
                            $selectedIndex = $newIdx
                            $count++
                        }
                    }
                }
                'PageDown' {
                    $count = 0
                    $newIdx = $selectedIndex
                    while ($newIdx -lt ($items.Count - 1) -and $count -lt $maxVisible) {
                        $newIdx++
                        if ($items[$newIdx].Selectable) {
                            $selectedIndex = $newIdx
                            $count++
                        }
                    }
                }
                'Home' {
                    for ($i = 0; $i -lt $items.Count; $i++) {
                        if ($items[$i].Selectable) {
                            $selectedIndex = $i
                            break
                        }
                    }
                }
                'End' {
                    for ($i = ($items.Count - 1); $i -ge 0; $i--) {
                        if ($items[$i].Selectable) {
                            $selectedIndex = $i
                            break
                        }
                    }
                }
                'Escape' { return $null }
                'ResizeEvent' { continue }
                'R' {
                    # Show scanning feedback
                    Clear-TuiScreen
                    $frame = New-UiFrame
                    Add-UiFrameBanner -Frame $frame -Title 'Connecting to LAN' -Subtitle "Active Network: $networkName" -Width (Get-UiWidth)
                    Add-UiFrameLine -Frame $frame
                    Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Active Network: $networkName$($_C.Reset)$($_C.EraseLn)"
                    Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Scanning local network for active PCs (testing WinRM 5985)...$($_C.Reset)$($_C.EraseLn)"
                    Write-UiFrame -Frame $frame
                    
                    $currentDiscovered = @(Get-DeviceCheckDiscoveredHosts)
                    
                    $selectedIndex = -1 # Reset selection
                    $script:RequestForceClear = $true
                    $needsReload = $true
                }
                'Delete' {
                    $item = $items[$selectedIndex]
                    if ($item.Type -in @('Saved', 'OfflineSnapshot') -and $item.Source -eq 'History') {
                        $targetEntry = $item.Data
                        $updatedHistory = [System.Collections.Generic.List[object]]::new()
                        foreach ($entry in $allHistory) {
                            if (-not ($entry.ComputerName.ToLower() -eq $targetEntry.ComputerName.ToLower() -and $entry.NetworkId -eq $targetEntry.NetworkId)) {
                                $updatedHistory.Add($entry)
                            }
                        }
                        Save-DeviceCheckConnectionHistory -History $updatedHistory
                        $selectedIndex = -1
                        $needsReload = $true
                    }
                }
                'Enter' {
                    $item = $items[$selectedIndex]
                    if ($item.Type -eq 'Action') {
                        return [PSCustomObject]@{
                            Action       = 'New'
                            ComputerName = $null
                            LastIP       = $null
                            MAC          = $null
                            UserName     = 'Unknown'
                        }
                    } elseif ($item.Type -eq 'OfflineLibrary') {
                        $offlineChoice = Invoke-OfflineSnapshotSelector -NetworkInfo $NetworkInfo -AllHistory $allHistory -DiscoveredHosts $currentDiscovered
                        if ($null -ne $offlineChoice -and $offlineChoice.Action -ne 'Back') {
                            return $offlineChoice
                        }
                        $selectedIndex = -1
                        $script:RequestForceClear = $true
                        $needsReload = $true
                    } elseif ($item.Type -eq 'Saved') {
                        return [PSCustomObject]@{
                            Action       = 'Connect'
                            ComputerName = $item.Data.ComputerName
                            LastIP       = $item.ResolvedIP
                            MAC          = $item.Data.MACAddress
                            UserName     = $item.Data.UserName
                        }
                    } elseif ($item.Type -eq 'OfflineSnapshot') {
                        return [PSCustomObject]@{
                            Action       = 'OpenOfflineSnapshot'
                            ComputerName = $item.Data.ComputerName
                            LastIP       = $item.ResolvedIP
                            MAC          = $item.Data.MACAddress
                            UserName     = $item.Data.UserName
                            SnapshotPath = $item.SnapshotPath
                        }
                    } elseif ($item.Type -eq 'Discovered') {
                        return [PSCustomObject]@{
                            Action       = 'ConnectDiscovered'
                            ComputerName = $item.Data.HostName
                            LastIP       = $item.Data.IP
                            MAC          = $item.Data.MAC
                            UserName     = 'Unknown'
                        }
                    }
                }
            }
            $processMs = $swProcess.Elapsed.TotalMilliseconds
            $swProcess.Stop()

            # Log benchmark entry
            $now = [datetime]::Now
            $repeatDelayMs = $(if ($script:LastKeyTimestamp -ne [datetime]::MinValue) {
                ($now - $script:LastKeyTimestamp).TotalMilliseconds
            } else {
                0
            })
            $script:LastKeyTimestamp = $now

            $logEntry = "[$(Get-Date -Format 'HH:mm:ss.fff')] [LAN-Menu] Key: $($key.Key) (char: '$($key.KeyChar)') | KeyRead: $([Math]::Round($keyReadMs, 1))ms | EventProcess: $([Math]::Round($processMs, 1))ms | Render: $([Math]::Round($renderMs, 1))ms | Prep: $([Math]::Round($prepMs, 1))ms | KeyDelay: $([Math]::Round($repeatDelayMs, 1))ms"
            $script:BenchmarkLog.Add($logEntry)
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

function Invoke-ConnectLanTarget {
    Reset-AllEvidenceScanConfirmation
    try { [Console]::CursorVisible = $true } catch {}
    $script:RequestForceClear = $true
    
    while ($true) {
        # Render scanning loading screens
        Clear-TuiScreen
        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title 'Connecting to LAN' -Subtitle 'Detecting network profile...' -Width (Get-UiWidth)
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Detecting network profile...$($_C.Reset)$($_C.EraseLn)"
        Write-UiFrame -Frame $frame

        $networkInfo = Get-CurrentNetworkIdentity
        $networkName = $networkInfo.ProfileName

        $frame = New-UiFrame
        Add-UiFrameBanner -Frame $frame -Title 'Connecting to LAN' -Subtitle "Active Network: $networkName" -Width (Get-UiWidth)
        Add-UiFrameLine -Frame $frame
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Active Network: $networkName$($_C.Reset)$($_C.EraseLn)"
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Scanning local network for active PCs (testing WinRM 5985)...$($_C.Reset)$($_C.EraseLn)"
        Write-UiFrame -Frame $frame

        $discoveredHosts = @(Get-DeviceCheckDiscoveredHosts)

        $choice = Invoke-ConnectionHistorySelector -NetworkInfo $networkInfo -DiscoveredHosts $discoveredHosts
        if ($null -eq $choice) {
            $script:SystemScanMessage = "Connect cancelled. | $(Get-Date -Format 'HH:mm:ss')"
            $script:RequestForceClear = $true
            try { Initialize-TuiHost } catch {}
            try { [Console]::CursorVisible = $false } catch {}
            return
        }

        $target = $null
        $resolvedIp = $null
        $targetMac = $null
        $targetIsOffline = $false
        $selectedSnapshotPath = $null
        $archiveSampleRequested = $false

        if ($choice.Action -eq 'New') {
            $renderBlock = {
                param($currentInput)
                $width = Get-UiWidth
                $frame = New-UiFrame
                Add-UiFrameBanner -Frame $frame -Title 'Connect to LAN PC' -Subtitle "Active Network: $networkName" -Width $width
                Add-UiFrameLine -Frame $frame
                Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Current target :$($_C.Reset) $($_C.Info)$(Get-TargetStatusText)$($_C.Reset)$($_C.EraseLn)"
                Add-UiFrameLine -Frame $frame
                Add-UiFrameLine -Frame $frame -Text "  $($_C.Bold)$($_C.White)Enter Computer name or IP (default: PALIOS - Use IP to bypass Kerberos lag):$($_C.Reset)$($_C.EraseLn)"
                $null = $frame.Append("  Target: $currentInput")
                Write-UiFrame -Frame $frame
            }
            $target = Read-TuiLine -RenderBlock $renderBlock -DefaultValue ''
            if ($null -eq $target) {
                $script:SystemScanMessage = "Connect cancelled. | $(Get-Date -Format 'HH:mm:ss')"
                $script:RequestForceClear = $true
                try { Initialize-TuiHost } catch {}
                try { [Console]::CursorVisible = $false } catch {}
                continue
            }
            if ([string]::IsNullOrWhiteSpace($target)) {
                $target = 'PALIOS'
            }
            $target = $target.Trim()
            $resolvedIp = $target
        } elseif ($choice.Action -eq 'ConnectDiscovered') {
            $target = $choice.ComputerName
            $resolvedIp = $choice.LastIP
            $targetMac = $choice.MAC
        } elseif ($choice.Action -eq 'OpenOfflineSnapshot') {
            $target = $choice.ComputerName
            $targetMac = $choice.MAC
            $resolvedIp = $choice.LastIP
            $targetIsOffline = $true
            $selectedSnapshotPath = $choice.SnapshotPath
        } else {
            $target = $choice.ComputerName
            $targetMac = $choice.MAC
            $resolvedIp = $choice.LastIP
            
            Clear-TuiScreen
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title "Connecting to $target" -Subtitle "Locating device on network '$networkName'..." -Width (Get-UiWidth)
            Add-UiFrameLine -Frame $frame
            Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Locating PC '$target' dynamically (checking DNS and ARP cache)...$($_C.Reset)$($_C.EraseLn)"
            Write-UiFrame -Frame $frame

            $resolvedIp = Resolve-HistoryTargetAddress -ComputerName $target -LastIPAddress $choice.LastIP -MACAddress $targetMac
            if ($null -eq $resolvedIp) {
                # Target is offline. Check if we have a cached snapshot before failing
                $cached = Find-LatestSnapshotForComputerName -ComputerName $target
                if ($null -ne $cached) {
                    $targetIsOffline = $true
                    $resolvedIp = $choice.LastIP  # Keep last IP to prevent connection history issues
                } else {
                    $script:SystemScanMessage = "Could not locate target PC '$target' on LAN. Verify it is online. | $(Get-Date -Format 'HH:mm:ss')"
                    $script:RequestForceClear = $true
                    
                    $renderErrorBlock = {
                        param()
                        Clear-TuiScreen
                        $width = Get-UiWidth
                        $frame = New-Object System.Text.StringBuilder
                        Add-UiFrameBanner -Frame $frame -Title "Cannot locate $target" -Subtitle "The device could not be reached via its hostname or MAC address." -Width $width
                        Add-UiFrameLine -Frame $frame
                        Add-UiFrameLine -Frame $frame -Text "  $($_C.Fail)Resolution failed.$($_C.Reset)$($_C.EraseLn)"
                        Add-UiFrameLine -Frame $frame
                        Add-UiFrameLine -Frame $frame -Text "  $($_C.Warn)The host '$target' (last IP: $($choice.LastIP)) did not respond on port 5985.$($_C.Reset)$($_C.EraseLn)"
                        Add-UiFrameLine -Frame $frame -Text "  $($_C.Warn)Ensure the target PC is awake, connected to network '$networkName', and WinRM is enabled.$($_C.Reset)$($_C.EraseLn)"
                        Add-UiFrameLine -Frame $frame
                        Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Press Enter to return$($_C.Reset)$($_C.EraseLn)"
                        Add-UiFrameLine -Frame $frame
                        try { [Console]::Write($frame.ToString()) } catch { $frame.ToString() | Write-Host }
                    }
                    while ($true) {
                        & $renderErrorBlock
                        $key = Read-ConsoleKey
                        if ($null -eq $key -or -not $key.PSObject.Properties['Key']) {
                            Start-Sleep -Milliseconds 10
                            continue
                        }
                        if ($key.Key -eq 'Enter') {
                            break
                        }
                        if ($key.Key -eq 'ResizeEvent') {
                            $script:RequestForceClear = $true
                            continue
                        }
                    }
                    try { Initialize-TuiHost } catch {}
                    try { [Console]::CursorVisible = $false } catch {}
                    continue
                }
            }
        }

        if (Test-DeviceCheckLocalTargetName -ComputerName $target) {
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title 'Connect to LAN PC' -Subtitle 'Switching back to local host...' -Width (Get-UiWidth)
            Add-UiFrameLine -Frame $frame
            Add-UiFrameLine -Frame $frame -Text "  $($_C.OK)Re-initializing local system scan...$($_C.Reset)$($_C.EraseLn)"
            Write-UiFrame -Frame $frame
            
            $script:TargetMode = 'Local'
            $script:TargetCredential = $null
            $script:TargetSnapshot = $null
            $script:TargetSnapshotPath = $null
            Invoke-SystemScan -Quiet
            $script:selectedIndex = 0
            $script:DetailScrollOffset = 0
            $script:DetailCursorIndex = 0
            $script:ActivePane = 'Tree'
            $script:VisibleRowsDirty = $true
            $script:visibleRows = Update-VisibleRows
            $script:VisibleRowsDirty = $false
            $script:RequestForceClear = $true
            try { Initialize-TuiHost } catch {}
            try { [Console]::CursorVisible = $false } catch {}
            return
        }

        $cached = $null
        if (-not [string]::IsNullOrWhiteSpace($selectedSnapshotPath) -and (Test-Path -LiteralPath $selectedSnapshotPath -PathType Leaf)) {
            try {
                $selectedSnapshot = Get-Content -LiteralPath $selectedSnapshotPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $cached = [PSCustomObject]@{
                    Snapshot   = $selectedSnapshot
                    LatestPath = $selectedSnapshotPath
                    Folder     = Split-Path -Parent $selectedSnapshotPath
                }
            } catch {
                $cached = $null
            }
        }
        if ($null -eq $cached) {
            $cached = Find-LatestSnapshotForComputerName -ComputerName $target
        }
        if ($null -ne $cached) {
            $collector = Get-NotePropertyValue -Object $cached.Snapshot -Name 'Collector'
            $finishedAt = [string](Get-NotePropertyValue -Object $collector -Name 'FinishedAt')
            $devicesRoot = Get-NotePropertyValue -Object $cached.Snapshot -Name 'Devices'
            $deviceCount = [string](Get-NotePropertyValue -Object $devicesRoot -Name 'Count')
            if ([string]::IsNullOrWhiteSpace($deviceCount)) {
                $deviceCount = [string](@((Get-NotePropertyValue -Object $devicesRoot -Name 'Present')).Count)
            }

            $script:RequestForceClear = $true
            $renderChoiceBlock = {
                param($currentInput)
                $width = Get-UiWidth
                $frame = New-UiFrame
                $statusMsg = $(if ($targetIsOffline) { " [OFFLINE]" } else { "" })
                Add-UiFrameBanner -Frame $frame -Title "Cached Snapshot Found$statusMsg" -Subtitle "Target computer: $target" -Width $width
                Add-UiFrameLine -Frame $frame
                Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Target :$($_C.Reset) $($_C.Info)$target$($_C.Reset)$($_C.EraseLn)"
                Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Time   :$($_C.Reset) $($_C.White)$finishedAt$($_C.Reset)$($_C.EraseLn)"
                Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)Devices:$($_C.Reset) $($_C.White)$deviceCount$($_C.Reset)$($_C.EraseLn)"
                Add-UiFrameLine -Frame $frame
                if ($targetIsOffline) {
                    Add-UiFrameLine -Frame $frame -Text "  $($_C.Warn)The target computer is currently offline/unreachable on port 5985.$($_C.Reset)$($_C.EraseLn)"
                    Add-UiFrameLine -Frame $frame -Text "  $($_C.Warn)You can only view the offline snapshot.$($_C.Reset)$($_C.EraseLn)"
                    Add-UiFrameLine -Frame $frame
                }
                Add-UiFrameLine -Frame $frame -Text "  $($_C.Bold)$($_C.White)Choose Action:$($_C.Reset)$($_C.EraseLn)"
                Add-UiFrameLine -Frame $frame -Text "  $($_C.OK)Enter$($_C.Reset) = Open cached snapshot$($_C.EraseLn)"
                if (-not $targetIsOffline) {
                    Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)R$($_C.Reset)     = Quick refresh snapshot now$($_C.EraseLn)"
                    Add-UiFrameLine -Frame $frame -Text "  $($_C.Gold)F$($_C.Reset)     = Full archive sample (slower)$($_C.EraseLn)"
                } else {
                    Add-UiFrameLine -Frame $frame -Text "  $($_C.Dim)F     = Full archive sample requires online target$($_C.Reset)$($_C.EraseLn)"
                }
                Add-UiFrameLine -Frame $frame -Text "  $($_C.Fail)C$($_C.Reset)     = Cancel connection$($_C.EraseLn)"
                Add-UiFrameLine -Frame $frame
                $null = $frame.Append("  Select option: $currentInput")
                Write-UiFrame -Frame $frame
            }
            
            $choiceSub = Read-TuiLine -RenderBlock $renderChoiceBlock -DefaultValue ''
            if ($null -eq $choiceSub) {
                $script:SystemScanMessage = "Connect cancelled. | $(Get-Date -Format 'HH:mm:ss')"
                $script:RequestForceClear = $true
                try { Initialize-TuiHost } catch {}
                try { [Console]::CursorVisible = $false } catch {}
                continue
            }
            
            if ([string]::IsNullOrWhiteSpace($choiceSub)) {
                $cachedCredential = $script:TargetCredential
                if ($null -eq $cachedCredential) {
                    $cachedCredential = $script:CredentialCache[$target.ToLower()]
                }
                if ($null -eq $cachedCredential -and -not [string]::IsNullOrWhiteSpace($resolvedIp)) {
                    $cachedCredential = $script:CredentialCache[$resolvedIp.ToLower()]
                }
                if ($null -eq $cachedCredential) {
                    $cachedCredential = Get-DeviceCheckStoredCredential -ComputerName $target
                }
                if ($null -eq $cachedCredential -and -not [string]::IsNullOrWhiteSpace($resolvedIp)) {
                    $cachedCredential = Get-DeviceCheckStoredCredential -ComputerName $resolvedIp
                }
                
                $userName = $(if ($null -ne $cachedCredential) { $cachedCredential.UserName } else { $choice.UserName })
                $actualComputerName = $target
                if ($null -ne $cached.Snapshot -and $null -ne $cached.Snapshot.Machine -and $null -ne $cached.Snapshot.Machine.ComputerSystem -and -not [string]::IsNullOrWhiteSpace($cached.Snapshot.Machine.ComputerSystem.Name)) {
                    $actualComputerName = $cached.Snapshot.Machine.ComputerSystem.Name
                }
                if (-not $targetIsOffline) {
                    Add-DeviceCheckConnectionHistoryEntry -ComputerName $actualComputerName -LastIPAddress $resolvedIp -MACAddress $targetMac -UserName $userName -NetworkId $networkInfo.NetworkId
                }

                Set-ActiveSnapshotTarget -Snapshot $cached.Snapshot -SnapshotPath $cached.LatestPath -ComputerName $actualComputerName -Credential $cachedCredential
                try { Initialize-TuiHost } catch {}
                try { [Console]::CursorVisible = $false } catch {}
                return
            }
            if ($choiceSub.Trim().Equals('C', [System.StringComparison]::OrdinalIgnoreCase)) {
                $script:SystemScanMessage = "Connect cancelled. | $(Get-Date -Format 'HH:mm:ss')"
                $script:RequestForceClear = $true
                try { Initialize-TuiHost } catch {}
                try { [Console]::CursorVisible = $false } catch {}
                continue
            }
            if ($choiceSub.Trim().Equals('R', [System.StringComparison]::OrdinalIgnoreCase) -and $targetIsOffline) {
                $script:SystemScanMessage = "Cannot refresh: Target PC '$target' is offline. | $(Get-Date -Format 'HH:mm:ss')"
                $script:RequestForceClear = $true
                $renderErrorBlock = {
                    param()
                    Clear-TuiScreen
                    $width = Get-UiWidth
                    $frame = New-Object System.Text.StringBuilder
                    Add-UiFrameBanner -Frame $frame -Title "Refresh Failed" -Subtitle "Target PC is offline." -Width $width
                    Add-UiFrameLine -Frame $frame
                    Add-UiFrameLine -Frame $frame -Text "  $($_C.Fail)Cannot refresh snapshot.$($_C.Reset)$($_C.EraseLn)"
                    Add-UiFrameLine -Frame $frame
                    Add-UiFrameLine -Frame $frame -Text "  $($_C.Warn)The host '$target' is currently offline or unreachable on port 5985.$($_C.Reset)$($_C.EraseLn)"
                    Add-UiFrameLine -Frame $frame -Text "  $($_C.Warn)Please wake the PC or check its WinRM configuration to refresh.$($_C.Reset)$($_C.EraseLn)"
                    Add-UiFrameLine -Frame $frame
                    Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Press Enter to return to options$($_C.Reset)$($_C.EraseLn)"
                    Add-UiFrameLine -Frame $frame
                    try { [Console]::Write($frame.ToString()) } catch { $frame.ToString() | Write-Host }
                }
                while ($true) {
                    & $renderErrorBlock
                    $key = Read-ConsoleKey
                    if ($null -eq $key -or -not $key.PSObject.Properties['Key']) {
                        Start-Sleep -Milliseconds 10
                        continue
                    }
                    if ($key.Key -eq 'Enter') {
                        break
                    }
                    if ($key.Key -eq 'ResizeEvent') {
                        $script:RequestForceClear = $true
                        continue
                    }
                }
                continue
            }
            if ($choiceSub.Trim().Equals('F', [System.StringComparison]::OrdinalIgnoreCase) -and $targetIsOffline) {
                $script:SystemScanMessage = "Cannot archive: Target PC '$target' is offline. | $(Get-Date -Format 'HH:mm:ss')"
                $script:RequestForceClear = $true
                continue
            }
            if ($choiceSub.Trim().Equals('F', [System.StringComparison]::OrdinalIgnoreCase)) {
                $archiveSampleRequested = $true
            } elseif (-not $choiceSub.Trim().Equals('R', [System.StringComparison]::OrdinalIgnoreCase)) {
                $script:SystemScanMessage = "Connect cancelled: unknown choice '$choiceSub'. | $(Get-Date -Format 'HH:mm:ss')"
                $script:RequestForceClear = $true
                try { Initialize-TuiHost } catch {}
                try { [Console]::CursorVisible = $false } catch {}
                continue
            }
        }

        try {
            $existingCredential = $script:TargetCredential
            if ($null -eq $existingCredential) {
                $existingCredential = $script:CredentialCache[$target.ToLower()]
            }
            if ($null -eq $existingCredential -and -not [string]::IsNullOrWhiteSpace($resolvedIp)) {
                $existingCredential = $script:CredentialCache[$resolvedIp.ToLower()]
            }
            if ($null -eq $existingCredential) {
                $existingCredential = Get-DeviceCheckStoredCredential -ComputerName $target
            }
            if ($null -eq $existingCredential -and -not [string]::IsNullOrWhiteSpace($resolvedIp)) {
                $existingCredential = Get-DeviceCheckStoredCredential -ComputerName $resolvedIp
            }
            
            $collection = Invoke-RemoteSnapshotCollectionScreen -ComputerName $resolvedIp -Credential $existingCredential -PromptForCredential:($null -eq $existingCredential) -Quick:(-not $archiveSampleRequested) -ArchiveSample:$archiveSampleRequested
            if ($null -ne $collection -and $collection.Success) {
                $connectedMac = "Unknown"
                try {
                    $neighbor = Get-NetNeighbor -IPAddress $resolvedIp -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($neighbor -and $neighbor.LinkLayerAddress) {
                        $connectedMac = $neighbor.LinkLayerAddress.ToUpper()
                    }
                } catch {}

                $userName = 'Unknown'
                if ($null -ne $collection.Credential) {
                    $userName = $collection.Credential.UserName
                } elseif ($null -ne $collection.Export -and $null -ne $collection.Export.Summary) {
                    $userName = $collection.Export.Summary.UserName
                }

                $actualComputerName = $target
                if ($null -ne $collection.Export) {
                    if ($null -ne $collection.Export.Summary -and -not [string]::IsNullOrWhiteSpace($collection.Export.Summary.ComputerName)) {
                        $actualComputerName = $collection.Export.Summary.ComputerName
                    } elseif ($null -ne $collection.Export.Snapshot -and $null -ne $collection.Export.Snapshot.Machine -and $null -ne $collection.Export.Snapshot.Machine.ComputerSystem -and -not [string]::IsNullOrWhiteSpace($collection.Export.Snapshot.Machine.ComputerSystem.Name)) {
                        $actualComputerName = $collection.Export.Snapshot.Machine.ComputerSystem.Name
                    }
                }

                Add-DeviceCheckConnectionHistoryEntry -ComputerName $actualComputerName -LastIPAddress $resolvedIp -MACAddress $connectedMac -UserName $userName -NetworkId $networkInfo.NetworkId

                Set-ActiveSnapshotTarget -Snapshot $collection.Export.Snapshot -SnapshotPath $collection.Export.LatestPath -ComputerName $actualComputerName -Credential $collection.Credential
                if ($archiveSampleRequested) {
                    $script:SystemScanMessage = "Full archive sample captured for $actualComputerName | $(Get-Date -Format 'HH:mm:ss')"
                }
                try { Initialize-TuiHost } catch {}
                try { [Console]::CursorVisible = $false } catch {}
                return
            } else {
                $script:SystemScanMessage = "Connect cancelled or failed: $target | $(Get-Date -Format 'HH:mm:ss')"
                $script:RequestForceClear = $true
                try { Initialize-TuiHost } catch {}
                try { [Console]::CursorVisible = $false } catch {}
                continue
            }
        } catch {
            $script:SystemScanMessage = "Connect failed: $target | $(Get-Date -Format 'HH:mm:ss')"
            $script:RequestForceClear = $true
            try { Initialize-TuiHost } catch {}
            try { [Console]::CursorVisible = $false } catch {}
            continue
        }
    }
}
