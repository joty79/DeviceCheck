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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The custom masked TUI returns the already-entered password as a transient in-memory string; it is converted immediately and is never logged or persisted.')]
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
    if ([string]::IsNullOrEmpty($passwordStr)) {
        return New-WinRMBlankPasswordCredential -UserName $userName
    }
    $password = ConvertTo-SecureString $passwordStr -AsPlainText -Force
    $password.MakeReadOnly()
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
        [string]$DefaultUserName,
        [switch]$PromptForCredential,
        [switch]$Quick,
        [switch]$ArchiveSample
    )

    while ($true) {
    try {
        Clear-TuiScreen
        if ([string]::IsNullOrWhiteSpace($DefaultUserName)) { $DefaultUserName = "$ComputerName\joty79" }
        $captureSubtitle = $(if ($ArchiveSample) {
                'Collecting full archive sample over WinRM.'
            } elseif ($Quick) {
                'Collecting quick remote snapshot over WinRM.'
            } else {
                'Collecting full remote snapshot over WinRM.'
            })
        if ($PromptForCredential -or $null -eq $Credential) {
            Show-RemoteSnapshotCollectionScreen -ComputerName $ComputerName -UserName $DefaultUserName -Subtitle 'Enter credentials for this LAN target.'
            $Credential = New-DeviceCheckCredentialFromPrompt -ComputerName $ComputerName -DefaultUserName $DefaultUserName
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
            ErrorCategory = $null
        }
    } catch {
        $message = $_.Exception.Message
        $connectionCategory = Get-WinRMConnectionErrorCategory -ErrorObject $_
        $credentialRejected = ($connectionCategory -eq 'AuthenticationRejected')
        $failedUserName = $(if ($null -ne $Credential) { $Credential.UserName } else { $DefaultUserName })
        if ($credentialRejected) {
            Remove-DeviceCheckStoredCredential -ComputerName $ComputerName
        }

        $renderErrorBlock = {
            param()
            Clear-TuiScreen
            $width = Get-UiWidth
            $frame = New-Object System.Text.StringBuilder
            Add-UiFrameBanner -Frame $frame -Title $(if ($credentialRejected) { "Credentials rejected for $ComputerName" } else { "Cannot connect to $ComputerName" }) -Subtitle $(if ($credentialRejected) { 'WinRM is reachable, but the username/password was rejected.' } else { 'The target may be asleep, offline, blocked by firewall, or rejecting credentials.' }) -Width $width

            $null = $frame.AppendLine('')
            $null = $frame.AppendLine("  $($_C.Fail)Connection failed.$($_C.Reset)$($_C.EraseLn)")
            $null = $frame.AppendLine('')
            if ($credentialRejected -and -not [string]::IsNullOrWhiteSpace($failedUserName)) {
                $null = $frame.AppendLine("  $($_C.Dim)Tried user:$($_C.Reset) $($_C.White)$failedUserName$($_C.Reset)$($_C.EraseLn)")
                $null = $frame.AppendLine('')
            }

            foreach ($line in (Wrap-PlainText -Text $message -Width ([Math]::Max(50, $width - 6)) -MaxLines 8)) {
                $null = $frame.AppendLine("  $($_C.Warn)$line$($_C.Reset)$($_C.EraseLn)")
            }
            $null = $frame.AppendLine('')

            if ($credentialRejected) {
                $null = $frame.AppendLine("  $($_C.Info)Use local-account format, for example COMPUTER\user.$($_C.Reset)$($_C.EraseLn)")
                $null = $frame.AppendLine("  $($_C.Info)For a blank password, leave Password empty and press Enter.$($_C.Reset)$($_C.EraseLn)")
                $null = $frame.AppendLine('')
            }

            if ($script:RemoteConnectionLog -and $script:RemoteConnectionLog.Count -gt 0) {
                $null = $frame.AppendLine("  $($_C.Bold)$($_C.White)Connection Log:$($_C.Reset)$($_C.EraseLn)")
                foreach ($logLine in $script:RemoteConnectionLog) {
                    $null = $frame.AppendLine("    $($_C.Dim)> $logLine$($_C.Reset)$($_C.EraseLn)")
                }
                $null = $frame.AppendLine('')
            }

            $null = $frame.AppendLine("  $($_C.Dim)No target switch was made.$($_C.Reset)$($_C.EraseLn)")
            $null = $frame.AppendLine('')
            $null = $frame.AppendLine("  $($_C.Info)R$($_C.Reset)     = Retry with different credentials$($_C.EraseLn)")
            $null = $frame.AppendLine("  $($_C.Info)Enter$($_C.Reset) = Return$($_C.EraseLn)")
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
            if ($key.Key -eq 'R') {
                $Credential = $null
                $PromptForCredential = $true
                $script:RequestForceClear = $true
                continue 2
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
            ErrorCategory = $connectionCategory
        }
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
    $global:TargetMode = 'RemoteSnapshot'
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

function Get-DeviceCheckDiscoveredHosts {
    param([AllowEmptyString()][string]$NetworkId = '')

    if ($null -ne (Get-Command -Name 'Find-WinRMComputer' -ErrorAction SilentlyContinue)) {
        $discoveryParameters = @{
            StateRoot         = $script:DeviceCheckCacheRoot
            IncludeDiagnostics = [bool]$script:BenchmarkMode
        }
        if (-not [string]::IsNullOrWhiteSpace($NetworkId)) { $discoveryParameters.NetworkId = $NetworkId }
        return @(Find-WinRMComputer @discoveryParameters)
    }

    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()

    $discovered = [System.Collections.Generic.List[object]]::new()
    $results = @()

    # 1. Interfaces lookup
    $swPhase = [System.Diagnostics.Stopwatch]::StartNew()
    $interfaces = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceAlias -notmatch "Loopback|vEthernet" -and
            $_.AddressState -eq "Preferred" -and
            $_.IPAddress -notmatch "^169\.254\."
        }

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
    $currentNetwork = Get-CurrentNetworkIdentity
    $currentNetworkId = $currentNetwork.NetworkId

    $dnsDetailsLog = [System.Collections.Generic.List[string]]::new()
    $explorerNetworkIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $explorerHostNameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ipList = [System.Collections.Generic.List[string]]::new()
    $hostNamesToResolveSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($history) {
        # Add static IP history entries instantly if they match the current network ID
        foreach ($entry in $history) {
            if ($entry.NetworkId -eq $currentNetworkId -and $entry.LastIPAddress -match '^\d+\.\d+\.\d+\.\d+$') {
                $ipList.Add($entry.LastIPAddress)
                $historyIpToName[$entry.LastIPAddress] = $entry.ComputerName
            }
        }

        # Filter hostnames that need DNS lookup from the current network
        $hostsToResolve = $history | Where-Object {
            $_.NetworkId -eq $currentNetworkId -and
            -not [string]::IsNullOrWhiteSpace($_.ComputerName) -and
            $_.ComputerName -notmatch '^\d+\.\d+\.\d+\.\d+$' -and
            ([string]::IsNullOrWhiteSpace($_.LastIPAddress) -or $_.LastIPAddress -notmatch '^\d+\.\d+\.\d+\.\d+$')
        } | Select-Object -ExpandProperty ComputerName -Unique

        foreach ($hostToResolve in @($hostsToResolve)) {
            if (-not [string]::IsNullOrWhiteSpace($hostToResolve)) {
                $null = $hostNamesToResolveSet.Add($hostToResolve)
            }
        }
    }

    $explorerNetworkHosts = @(Get-DeviceCheckExplorerNetworkComputers)
    if ($explorerNetworkHosts.Count -gt 0) {
        $dnsDetailsLog.Add("    Explorer Network computers: $(@($explorerNetworkHosts.HostName) -join ', ')")
        foreach ($explorerHost in $explorerNetworkHosts) {
            if (-not [string]::IsNullOrWhiteSpace($explorerHost.HostName)) {
                $null = $explorerHostNameSet.Add($explorerHost.HostName)
                $null = $hostNamesToResolveSet.Add($explorerHost.HostName)
            }
        }
    }

    $hostsToResolve = @($hostNamesToResolveSet)
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
                                    $parsed = $null
                                    if ([System.Net.IPAddress]::TryParse([string]$r.IPAddress, [ref]$parsed) -and $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                                        $ips.Add($r.IPAddress)
                                    }
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
                                if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                                    $ips.Add($ip.IPAddressToString)
                                }
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
                                if ($explorerHostNameSet.Contains($res.ComputerName)) {
                                    $null = $explorerNetworkIPsSet.Add($ip)
                                }
                            }
                        }
                    }
                }
            }
    }
    $historyIPs = @($ipList | Select-Object -Unique)
    $timeDns = $swPhase.Elapsed.TotalMilliseconds

    # 3. Keep refresh fast; active TCP/WS-D probes refresh neighbors without a foreground ARP purge.
    $swPhase.Restart()
    $timeArpClear = $swPhase.Elapsed.TotalMilliseconds

    # 4. ICMP is skipped for the PC-only selector; WS-D/TCP prove computer visibility.
    $swPhase.Restart()

    # Get neighbors first to know which IPs to target
    $localSubnetPrefixes = @(
        foreach ($if in $interfaces) {
            if ($if.IPAddress -match '^(\d+\.\d+\.\d+)\.\d+$') { $Matches[1] }
        }
    ) | Select-Object -Unique

    $neighbors = foreach ($if in $interfaces) {
        Get-NetNeighbor -InterfaceIndex $if.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.State -ne 'Unreachable' -and
                $_.LinkLayerAddress -ne '00-00-00-00-00-00' -and
                (Test-DeviceCheckLanDiscoveryIPv4 -Address $_.IPAddress -SubnetPrefixes $localSubnetPrefixes)
            }
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

    $swWsDiscovery = [System.Diagnostics.Stopwatch]::StartNew()
    $wsDiscoveryHosts = @(Invoke-DeviceCheckWsDiscoveryProbe -SubnetPrefixes $localSubnetPrefixes)
    $timeWsDiscovery = $swWsDiscovery.Elapsed.TotalMilliseconds
    $wsDiscoveryIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $sweepExcludedIPs = [System.Collections.Generic.List[string]]::new()
    foreach ($ip in $localIPs) { $sweepExcludedIPs.Add($ip) }
    foreach ($ip in $gateways) { $sweepExcludedIPs.Add($ip) }
    $swComputerSweep = [System.Diagnostics.Stopwatch]::StartNew()
    $computerPortHosts = @(Invoke-DeviceCheckComputerPortSweep -SubnetPrefixes $localSubnetPrefixes -ExcludedIPs @($sweepExcludedIPs))
    $timeComputerSweep = $swComputerSweep.Elapsed.TotalMilliseconds
    $computerPortIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $neighborIPs = @()
    if ($neighbors) {
        $neighborIPs = @($neighbors.IPAddress)
    }

    # Combine neighbor cache IPs and history IPs
    $targetIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in $neighborIPs) { $null = $targetIPsSet.Add($ip) }
    foreach ($hostEntry in $wsDiscoveryHosts) {
        if (-not $localIPs.Contains($hostEntry.IP)) {
            $null = $wsDiscoveryIPsSet.Add($hostEntry.IP)
            $null = $targetIPsSet.Add($hostEntry.IP)
            if (-not [string]::IsNullOrWhiteSpace($hostEntry.HostName) -and $hostEntry.HostName -ne $hostEntry.IP) {
                $historyIpToName[$hostEntry.IP] = $hostEntry.HostName
            }
        }
    }
    foreach ($hostEntry in $computerPortHosts) {
        if (-not $localIPs.Contains($hostEntry.IP)) {
            $null = $computerPortIPsSet.Add($hostEntry.IP)
            $null = $targetIPsSet.Add($hostEntry.IP)
        }
    }
    foreach ($ip in $historyIPs) {
        if (Test-DeviceCheckLanDiscoveryIPv4 -Address $ip -SubnetPrefixes $localSubnetPrefixes) { $null = $targetIPsSet.Add($ip) }
    }

    $targetIPs = @(
        $targetIPsSet | Where-Object { -not $gateways.Contains($_) -and -not $localIPs.Contains($_) }
    )

    $swPhase.Restart()
    $timePing = $swPhase.Elapsed.TotalMilliseconds

    # 5. Neighbor/Active Target Setup
    $swPhase.Restart()
    $uniqueIPs = $targetIPs
    $timeNeighbors = $swPhase.Elapsed.TotalMilliseconds

    # 6. Fast parallel TCP scan on port 5985 and 445
    $swPhase.Restart()
    $winrmOpenIPs = [System.Collections.Generic.List[string]]::new()
    $smbOpenIPs = [System.Collections.Generic.List[string]]::new()

    foreach ($hostEntry in $computerPortHosts) {
        if ($hostEntry.WinRmOpen -and -not ($winrmOpenIPs -contains $hostEntry.IP)) { $winrmOpenIPs.Add($hostEntry.IP) }
        if ($hostEntry.SmbOpen -and -not ($smbOpenIPs -contains $hostEntry.IP)) { $smbOpenIPs.Add($hostEntry.IP) }
    }

    $tcpScanIPs = @(
        foreach ($ip in $uniqueIPs) {
            if (-not ($computerPortIPsSet.Contains($ip) -and ($winrmOpenIPs -contains $ip))) { $ip }
        }
    )

    if ($tcpScanIPs) {
        $connections = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($ip in $tcpScanIPs) {
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

    # Keep confirmed WS-Discovery computers visible before WinRM is enabled, without listing ARP-only phones/cameras.
    $onlineIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in $winrmOpenIPs) { $null = $onlineIPsSet.Add($ip) }
    foreach ($ip in $smbOpenIPs) { $null = $onlineIPsSet.Add($ip) }
    $detectedOnlyIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in $targetIPs) {
        if (($wsDiscoveryIPsSet.Contains($ip) -or $computerPortIPsSet.Contains($ip) -or $explorerNetworkIPsSet.Contains($ip)) -and -not $onlineIPsSet.Contains($ip)) { $null = $detectedOnlyIPsSet.Add($ip) }
    }
    foreach ($ip in $detectedOnlyIPsSet) { $null = $onlineIPsSet.Add($ip) }

    $onlineIPs = @($onlineIPsSet)
    $resolvedNames = @{}
    $hostsCache = Get-DeviceCheckHostsCache -NetworkId $currentNetworkId
    $cacheUpdatedFromDiscovery = $false
    foreach ($entry in $historyIpToName.GetEnumerator()) {
        $displayName = ConvertTo-DeviceCheckHostDisplayName -HostName $entry.Value -FallbackIP $entry.Key
        if ($displayName -ne $entry.Key -and ((-not $hostsCache.ContainsKey($entry.Key)) -or $hostsCache[$entry.Key] -ne $displayName)) {
            $hostsCache[$entry.Key] = $displayName
            $cacheUpdatedFromDiscovery = $true
        }
    }
    if ($cacheUpdatedFromDiscovery) {
        Save-DeviceCheckHostsCache -Cache $hostsCache -NetworkId $currentNetworkId
    }

    $unresolvedIPs = [System.Collections.Generic.List[string]]::new()
    foreach ($ip in $onlineIPs) {
        if ($historyIpToName.ContainsKey($ip)) {
            $displayName = ConvertTo-DeviceCheckHostDisplayName -HostName $historyIpToName[$ip] -FallbackIP $ip
            if ($displayName -ne $ip) {
                $resolvedNames[$ip] = $displayName
            } else {
                $unresolvedIPs.Add($ip)
            }
        } elseif ($hostsCache.ContainsKey($ip)) {
            $displayName = ConvertTo-DeviceCheckHostDisplayName -HostName $hostsCache[$ip] -FallbackIP $ip
            if ($displayName -ne $ip) {
                $resolvedNames[$ip] = $displayName
            } else {
                $unresolvedIPs.Add($ip)
            }
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
                    $hostName = ConvertTo-DeviceCheckHostDisplayName -HostName $rt.Task.Result.HostName -FallbackIP $rt.IP
                    if ($hostName -ne $rt.IP) {
                        $resolvedNames[$rt.IP] = $hostName
                        $newlyResolved[$rt.IP] = $hostName
                    }
                }
            }
            if ($newlyResolved.Count -gt 0) {
                foreach ($ip in $newlyResolved.Keys) {
                    $hostsCache[$ip] = $newlyResolved[$ip]
                }
                Save-DeviceCheckHostsCache -Cache $hostsCache -NetworkId $currentNetworkId
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
                    $dnsName = ConvertTo-DeviceCheckHostDisplayName -HostName $dnsRes[0].NameHost -FallbackIP $ip
                    if ($dnsName -ne $ip) {
                        $resolvedNames[$ip] = $dnsName
                        $hostsCache[$ip] = $dnsName
                        Save-DeviceCheckHostsCache -Cache $hostsCache -NetworkId $currentNetworkId
                    } else {
                        $resolvedNames[$ip] = $ip
                        $stillUnresolved.Add($ip)
                    }
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

    $netBiosCandidates = @(
        $stillUnresolved |
            Where-Object { ($smbOpenIPs -contains $_) -or $detectedOnlyIPsSet.Contains($_) } |
            Select-Object -First 6
    )
    foreach ($ip in $netBiosCandidates) {
        $netBiosName = Resolve-DeviceCheckNetBiosName -IPAddress $ip -TimeoutMs 350
        if (-not [string]::IsNullOrWhiteSpace($netBiosName) -and $netBiosName -ne $ip) {
            $resolvedNames[$ip] = $netBiosName
            $hostsCache[$ip] = $netBiosName
            Save-DeviceCheckHostsCache -Cache $hostsCache -NetworkId $currentNetworkId
        }
    }

    $stillUnresolvedAfterNetBios = [System.Collections.Generic.List[string]]::new()
    foreach ($ip in $stillUnresolved) {
        if (-not $resolvedNames.ContainsKey($ip) -or $resolvedNames[$ip] -eq $ip) {
            $stillUnresolvedAfterNetBios.Add($ip)
        }
    }
    $stillUnresolved = $stillUnresolvedAfterNetBios

    # Resolve unresolved IPs in background to populate cache for future scans
    if ($stillUnresolved.Count -gt 0) {
        Start-DeviceCheckBackgroundResolver -IPs @($stillUnresolved) -NetworkId $currentNetworkId
    }

    # Build final scan results list
    $scanResultsList = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($ip in $onlineIPs) {
        $name = $resolvedNames[$ip]
        $isWinRm = $ip -in $winrmOpenIPs
        $isSmb = $ip -in $smbOpenIPs
        $isDetectedOnly = $detectedOnlyIPsSet.Contains($ip)
        $scanResultsList.Add([PSCustomObject]@{ IP = $ip; HostName = $name; WinRmOpen = $isWinRm; SmbOpen = $isSmb; DetectedOnly = $isDetectedOnly })
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
            $discovered.Add([PSCustomObject]@{ IP = $res.IP; HostName = $res.HostName; MAC = $mac; WinRmOpen = $res.WinRmOpen; SmbOpen = $res.SmbOpen; DetectedOnly = $res.DetectedOnly })
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
    $logLines.Add("  Phase 4b (WS-Disc): $([Math]::Round($timeWsDiscovery, 1)) ms ($($wsDiscoveryHosts.Count) hosts)")
    $logLines.Add("  Phase 4c (PCPort): $([Math]::Round($timeComputerSweep, 1)) ms ($($computerPortHosts.Count) hosts)")
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
        # Check for absolute mismatches first:
        # 1. MAC mismatch: both are known, but different
        $macMismatch = $false
        if (-not [string]::IsNullOrWhiteSpace($Entry.MACAddress) -and $Entry.MACAddress -ne 'Unknown' -and
            -not [string]::IsNullOrWhiteSpace($d.MAC) -and $d.MAC -ne 'Unknown') {
            if ($Entry.MACAddress.Replace(':', '-').ToLower() -ne $d.MAC.Replace(':', '-').ToLower()) {
                $macMismatch = $true
            }
        }

        # 2. Hostname mismatch: both are known hostnames (not IPs), but different
        $nameMismatch = $false
        if (-not [string]::IsNullOrWhiteSpace($Entry.ComputerName) -and $Entry.ComputerName -notmatch '^\d+\.\d+\.\d+\.\d+$' -and
            -not [string]::IsNullOrWhiteSpace($d.HostName) -and $d.HostName -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            if ($Entry.ComputerName.ToLower() -ne $d.HostName.ToLower()) {
                $nameMismatch = $true
            }
        }

        # If it's a mismatch, this discovered host is NOT our history entry
        if ($macMismatch -or $nameMismatch) {
            continue
        }

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

function Test-DeviceCheckIPv4Address {
    param([AllowEmptyString()][string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $false
    }

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        return $false
    }

    return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Get-DeviceCheckIPv4Addresses {
    param($Addresses)

    foreach ($address in @($Addresses)) {
        $addressText = $null
        if ($address -is [System.Net.IPAddress]) {
            $addressText = $address.IPAddressToString
        } else {
            $addressText = [string]$address
        }

        if (Test-DeviceCheckIPv4Address -Address $addressText) {
            $addressText
        }
    }
}

function ConvertTo-DeviceCheckCatalogDiscoveredHosts {
    param([AllowNull()]$Catalog)

    if ($null -eq $Catalog) { return @() }
    return @(
        @($Catalog.Targets) |
            Where-Object { $_.HasDiscoverySnapshot } |
            ForEach-Object {
                [PSCustomObject]@{
                    HostName     = $_.ComputerName
                    IP           = $_.IPAddress
                    MAC          = $_.MACAddress
                    WinRmOpen    = [bool]$_.WinRMHttpOpen
                    SmbOpen      = [bool]$_.SMBOpen
                    DetectedOnly = [bool]$_.DetectedOnly
                    Status       = $_.CachedStatus
                }
            }
    )
}

function Get-DeviceCheckTargetStatusPresentation {
    param([Parameter(Mandatory)]$Item)

    $validationStatus = ''
    if ($null -ne $Item.PSObject.Properties['ValidationStatus']) {
        $validationStatus = [string]$Item.ValidationStatus
    }

    if ($validationStatus -eq 'NotChecked') {
        return [PSCustomObject]@{ Kind = 'NotChecked'; Label = 'Not checked' }
    }
    if (-not [bool]$Item.IsOnline) {
        return [PSCustomObject]@{ Kind = 'Offline'; Label = 'Offline' }
    }
    if ([bool]$Item.WinRmOpen) {
        return [PSCustomObject]@{ Kind = 'Online'; Label = 'Online' }
    }

    $detectedOnly = $false
    if ($null -ne $Item.PSObject.Properties['DetectedOnly']) {
        $detectedOnly = [bool]$Item.DetectedOnly
    }
    if ($detectedOnly) {
        return [PSCustomObject]@{ Kind = 'DetectedOnly'; Label = 'Computer - mgmt closed' }
    }
    return [PSCustomObject]@{ Kind = 'WinRMDisabled'; Label = 'WinRM Disabled' }
}

function Invoke-ConnectionHistorySelector {
    param(
        [Parameter(Mandatory)]$NetworkInfo,
        [AllowNull()]$Catalog = $null
    )

    if ($null -eq $Catalog) {
        $Catalog = Get-WinRMTargetCatalog -NetworkId $NetworkInfo.NetworkId -IncludeDiagnostics:$script:BenchmarkMode
    }
    $currentDiscovered = @(ConvertTo-DeviceCheckCatalogDiscoveredHosts -Catalog $Catalog)

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
            $hasFreshDiscoverySnapshot = $false
            if ($null -ne $Catalog -and $null -ne $Catalog.PSObject.Properties['SnapshotCapturedAtUtc']) {
                $hasFreshDiscoverySnapshot = -not [string]::IsNullOrWhiteSpace([string]$Catalog.SnapshotCapturedAtUtc)
            }

            # Section 1: Saved Connections. Loading this section is local-only;
            # the selected row is validated later by Resolve-WinRMHistoryTargetAddress.
            $items.Add([PSCustomObject]@{
                Type       = 'Header'
                Text       = "$($_C.Bold)$($_C.Info)Saved Connections$($_C.Reset)"
                Selectable = $false
            })

            $savedCount = 0
            foreach ($entry in $filteredHistory) {
                $savedCount++
                $discoveryState = Test-DeviceCheckHistoryEntryOnline -Entry $entry -DiscoveredHosts $currentDiscovered -CurrentNetworkId $networkId
                $displayIP = $(if ($hasFreshDiscoverySnapshot -and (Test-DeviceCheckIPv4Address -Address $discoveryState.ResolvedIP)) {
                        $discoveryState.ResolvedIP
                    } elseif (Test-DeviceCheckIPv4Address -Address $entry.LastIPAddress) {
                        $entry.LastIPAddress
                    } else {
                        'address unknown'
                    })
                $validationStatus = $(if ($hasFreshDiscoverySnapshot) { 'CachedDiscovery' } else { 'NotChecked' })
                $displayText = "$($entry.ComputerName) ($displayIP) - user: $($entry.UserName)"

                $items.Add([PSCustomObject]@{
                    Type          = 'Saved'
                    Text          = $displayText
                    Selectable    = $true
                    Data          = $entry
                    IsOnline      = $(if ($hasFreshDiscoverySnapshot) { [bool]$discoveryState.IsOnline } else { $false })
                    WinRmOpen     = $(if ($hasFreshDiscoverySnapshot) { [bool]$discoveryState.WinRmOpen } else { $false })
                    DetectedOnly  = $false
                    ResolvedIP    = $displayIP
                    ValidationStatus = $validationStatus
                    Source        = 'History'
                    SourceNetwork = Get-DeviceCheckNetworkLabel -NetworkId $entry.NetworkId
                })
            }

            if ($savedCount -eq 0) {
                $items.Add([PSCustomObject]@{
                    Type       = 'Placeholder'
                    Text       = "  $($_C.Dim)(No saved connections on this network)$($_C.Reset)"
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

            $items.Add([PSCustomObject]@{
                Type          = 'OfflineLibrary'
                Text          = '[Offline Snapshots...]'
                Selectable    = $true
                IsOnline      = $false
                WinRmOpen     = $false
                Data          = $null
                Source        = 'Library'
            })

            $items.Add([PSCustomObject]@{
                Type       = 'Separator'
                Text       = ""
                Selectable = $false
            })

            # Section 3: short-lived results from the last explicit scan.
            $items.Add([PSCustomObject]@{
                Type       = 'Header'
                Text       = "$($_C.Bold)$($_C.Info)Recent Discovery Snapshot$($_C.Reset)"
                Selectable = $false
            })

            $discoveredCount = 0
            foreach ($d in $currentDiscovered) {
                # Check if already in history as an active/saved connection
                $inHistory = $false
                foreach ($entry in $filteredHistory) {
                    $macMismatch = $false
                    if (-not [string]::IsNullOrWhiteSpace($entry.MACAddress) -and $entry.MACAddress -ne 'Unknown' -and
                        -not [string]::IsNullOrWhiteSpace($d.MAC) -and $d.MAC -ne 'Unknown') {
                        if ($entry.MACAddress.Replace(':', '-').ToLower() -ne $d.MAC.Replace(':', '-').ToLower()) {
                            $macMismatch = $true
                        }
                    }
                    $nameMismatch = $false
                    if (-not [string]::IsNullOrWhiteSpace($entry.ComputerName) -and $entry.ComputerName -notmatch '^\d+\.\d+\.\d+\.\d+$' -and
                        -not [string]::IsNullOrWhiteSpace($d.HostName) -and $d.HostName -notmatch '^\d+\.\d+\.\d+\.\d+$') {
                        if ($entry.ComputerName.ToLower() -ne $d.HostName.ToLower()) {
                            $nameMismatch = $true
                        }
                    }

                    if ($macMismatch -or $nameMismatch) {
                        continue
                    }

                    if ($entry.ComputerName.ToLower() -eq $d.HostName.ToLower() -or
                        ($entry.LastIPAddress -eq $d.IP -and $entry.NetworkId -eq $networkId)) {
                        $inHistory = $true
                        break
                    }
                }

                if (-not $inHistory) {
                    $discoveredCount++
                    $statusLabel = $(if ($d.WinRmOpen) { "(Online)" } elseif ($d.DetectedOnly) { "(Computer - mgmt closed)" } else { "(WinRM Disabled)" })
                    $displayText = "$($d.HostName) ($($d.IP)) $statusLabel"
                    $items.Add([PSCustomObject]@{ Type = 'Discovered'; Text = $displayText; Selectable = $true; Data = $d; IsOnline = $true; WinRmOpen = $d.WinRmOpen; DetectedOnly = $d.DetectedOnly })
                }
            }

            if ($discoveredCount -eq 0) {
                $snapshotSummary = $(if (-not $hasFreshDiscoverySnapshot) {
                        'No fresh scan snapshot. Choose Scan network now.'
                    } elseif ($currentDiscovered.Count -gt 0) {
                        $targetWord = $(if ($currentDiscovered.Count -eq 1) { 'PC is' } else { 'PCs are' })
                        "Fresh scan found $($currentDiscovered.Count) $targetWord already listed under Saved Connections."
                    } else {
                        'Fresh scan completed; no PCs detected.'
                    })
                $items.Add([PSCustomObject]@{
                    Type       = 'Placeholder'
                    Text       = "  $($_C.Dim)($snapshotSummary)$($_C.Reset)"
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
                Text       = '[Scan network now...]'
                Selectable = $true
                Data       = 'Scan'
                IsOnline   = $false
            })

            $items.Add([PSCustomObject]@{
                Type       = 'Action'
                Text       = "[Connect to new target...]"
                Selectable = $true
                Data       = 'New'
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
                            $cleanText = $item.Text -replace '\s*\((Online|Offline|Not checked|WinRM Disabled|Detected - mgmt closed|Computer - mgmt closed)\)\s*$'
                            $status = Get-DeviceCheckTargetStatusPresentation -Item $item
                            switch ($status.Kind) {
                                'NotChecked' { $statusColor = $_C.Gold }
                                'Offline' { $statusColor = $_C.Fail }
                                'Online' { $statusColor = $_C.OK }
                                default { $statusColor = $_C.Warn }
                            }
                            $statusLabel = "($($status.Label))"
                            $statusText = " $statusColor$statusLabel$($_C.Reset)$($_C.SelBg)$($_C.SelFg)$($_C.Bold)"
                        }
                        Add-UiFrameLine -Frame $frame -Text "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $($cleanText)$($statusText) $($_C.Reset)$($_C.EraseLn)"
                    } else {
                        if ($item.Type -eq 'Action' -or $item.Type -eq 'OfflineLibrary') {
                            Add-UiFrameLine -Frame $frame -Text "    $($_C.OK)$($item.Text)$($_C.Reset)$($_C.EraseLn)"
                        } else {
                            $status = Get-DeviceCheckTargetStatusPresentation -Item $item
                            $statusColor = $(switch ($status.Kind) {
                                    'NotChecked' { $_C.Gold; break }
                                    'Offline' { $_C.Fail; break }
                                    'Online' { $_C.OK; break }
                                    default { $_C.Warn; break }
                                })
                            $onlineColor = " $statusColor($($status.Label))$($_C.Reset)"
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

                    $currentDiscovered = @(Get-DeviceCheckDiscoveredHosts -NetworkId $networkId)
                    $Catalog = Get-WinRMTargetCatalog -NetworkId $networkId -IncludeDiagnostics:$script:BenchmarkMode
                    $currentDiscovered = @(ConvertTo-DeviceCheckCatalogDiscoveredHosts -Catalog $Catalog)

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
                        if ([string]$item.Data -eq 'Scan') {
                            $frame = New-UiFrame
                            Add-UiFrameBanner -Frame $frame -Title 'Connecting to LAN' -Subtitle "Active Network: $networkName" -Width (Get-UiWidth)
                            Add-UiFrameLine -Frame $frame
                            Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Scanning local network for active PCs (testing WinRM 5985)...$($_C.Reset)$($_C.EraseLn)"
                            Write-UiFrame -Frame $frame
                            $currentDiscovered = @(Get-DeviceCheckDiscoveredHosts -NetworkId $networkId)
                            $Catalog = Get-WinRMTargetCatalog -NetworkId $networkId -IncludeDiagnostics:$script:BenchmarkMode
                            $currentDiscovered = @(ConvertTo-DeviceCheckCatalogDiscoveredHosts -Catalog $Catalog)
                            $selectedIndex = -1
                            $script:RequestForceClear = $true
                            $needsReload = $true
                            continue
                        }
                        return [PSCustomObject]@{
                            Action       = 'New'
                            ComputerName = $null
                            LastIP       = $null
                            MAC          = $null
                            UserName     = 'Unknown'
                        }
                    } elseif ($item.Type -eq 'OfflineLibrary') {
                        $frame = New-UiFrame
                        Add-UiFrameBanner -Frame $frame -Title 'Offline Snapshot Library' -Subtitle 'Loading local hardware snapshots...' -Width (Get-UiWidth)
                        Add-UiFrameLine -Frame $frame
                        Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Reading saved snapshot metadata. No network scan is running.$($_C.Reset)$($_C.EraseLn)"
                        Write-UiFrame -Frame $frame
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
        Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)Loading saved targets and recent scan snapshot...$($_C.Reset)$($_C.EraseLn)"
        Write-UiFrame -Frame $frame

        $catalog = Get-WinRMTargetCatalog -NetworkId $networkInfo.NetworkId -IncludeDiagnostics:$script:BenchmarkMode

        $choice = Invoke-ConnectionHistorySelector -NetworkInfo $networkInfo -Catalog $catalog
        if ($null -eq $choice) {
            # Switch back to local host machine instead of previous logged target
            $script:TargetMode = 'Local'
            $global:TargetMode = 'Local'
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

            $script:SystemScanMessage = "Connect cancelled. Switched back to local host. | $(Get-Date -Format 'HH:mm:ss')"
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

            $resolvedIp = Resolve-WinRMHistoryTargetAddress -ComputerName $target -LastIPAddress $choice.LastIP -MACAddress $targetMac
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
            $global:TargetMode = 'Local'
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
            if ($null -eq $existingCredential) { $existingCredential = $script:CredentialCache[$target.ToLower()] }
            if ($null -eq $existingCredential -and -not [string]::IsNullOrWhiteSpace($resolvedIp)) { $existingCredential = $script:CredentialCache[$resolvedIp.ToLower()] }
            if ($null -eq $existingCredential) { $existingCredential = Get-DeviceCheckStoredCredential -ComputerName $target }
            if ($null -eq $existingCredential -and -not [string]::IsNullOrWhiteSpace($resolvedIp)) { $existingCredential = Get-DeviceCheckStoredCredential -ComputerName $resolvedIp }
            $expectedUser = [string]$choice.UserName
            if ($null -ne $existingCredential -and -not [string]::IsNullOrWhiteSpace($expectedUser) -and $expectedUser -ne 'Unknown') {
                $cachedLeaf = ($existingCredential.UserName -split '\\')[-1]
                $expectedLeaf = ($expectedUser -split '\\')[-1]
                if (-not $cachedLeaf.Equals($expectedLeaf, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Remove-DeviceCheckStoredCredential -ComputerName $target; if (-not [string]::IsNullOrWhiteSpace($resolvedIp)) { Remove-DeviceCheckStoredCredential -ComputerName $resolvedIp }; $existingCredential = $null
                }
            }
            $promptUserName = $(if (-not [string]::IsNullOrWhiteSpace($expectedUser) -and $expectedUser -ne 'Unknown') { if ($expectedUser -match '\\') { $expectedUser } else { "$target\$expectedUser" } } elseif (-not [string]::IsNullOrWhiteSpace($target) -and -not (Test-DeviceCheckIPv4Address -Address $target)) { "$target\user" } else { $null })

            $collection = Invoke-RemoteSnapshotCollectionScreen -ComputerName $resolvedIp -Credential $existingCredential -DefaultUserName $promptUserName -PromptForCredential:($null -eq $existingCredential) -Quick:(-not $archiveSampleRequested) -ArchiveSample:$archiveSampleRequested
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
                if ($null -ne $collection -and $collection.ErrorCategory -eq 'AuthenticationRejected') {
                    Remove-DeviceCheckStoredCredential -ComputerName $target
                    if (-not [string]::IsNullOrWhiteSpace($resolvedIp)) {
                        Remove-DeviceCheckStoredCredential -ComputerName $resolvedIp
                    }
                }
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
