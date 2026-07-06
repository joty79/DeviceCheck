#requires -version 5.1
[CmdletBinding()]
param(
    [string[]]$ExpectedHostName = @(),
    [string[]]$ExpectedIP = @(),
    [switch]$CompareExplorer,
    [int]$ExplorerTimeoutMilliseconds = 5000,
    [switch]$RequireExplorerRows,
    [int]$RepeatCount = 1,
    [int]$RepeatDelaySeconds = 2,
    [switch]$FailOnMissing
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$script:DeviceCheckRepoRoot = $repoRoot
$script:DeviceCheckCacheRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DeviceCheck'
$script:BenchmarkMode = $true
$script:LastNetworkScanResult = $null

. (Join-Path $repoRoot 'internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1')
. (Join-Path $repoRoot 'internal\DeviceCheck\06-RemoteConnection.ps1')

function Resolve-TestExplorerHostIPv4 {
    param([AllowEmptyString()][string]$HostName)

    $resolvedIPs = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($HostName)) { return @() }

    try {
        $dnsRows = Resolve-DnsName -Name $HostName -DnsOnly -QuickTimeout -ErrorAction Stop
        foreach ($dnsRow in @($dnsRows)) {
            if ($dnsRow.IPAddress -and $dnsRow.IPAddress -match '^\d+\.\d+\.\d+\.\d+$') {
                $resolvedIPs.Add([string]$dnsRow.IPAddress)
            }
        }
    } catch {
        try {
            foreach ($addr in [System.Net.Dns]::GetHostAddresses($HostName)) {
                if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $resolvedIPs.Add($addr.IPAddressToString)
                }
            }
        } catch {}
    }

    return @($resolvedIPs | Select-Object -Unique)
}

if ($RepeatCount -lt 1) { $RepeatCount = 1 }
if ($RepeatDelaySeconds -lt 0) { $RepeatDelaySeconds = 0 }

$allMissing = [System.Collections.Generic.List[string]]::new()
$summaryRows = [System.Collections.Generic.List[object]]::new()

for ($runIndex = 1; $runIndex -le $RepeatCount; $runIndex++) {
    $script:LastNetworkScanResult = $null

    if ($RepeatCount -gt 1) {
        ''
        "Discovery run $runIndex / $RepeatCount"
    }

    $explorerHosts = @()
    if ($CompareExplorer) {
        $explorerHosts = @(Get-DeviceCheckExplorerNetworkComputers -TimeoutMilliseconds $ExplorerTimeoutMilliseconds)
    }

    $hosts = @(Get-DeviceCheckDiscoveredHosts)

    $hosts |
        Sort-Object IP |
        Select-Object IP, HostName, WinRmOpen, SmbOpen, DetectedOnly |
        Format-Table -AutoSize

    if ($script:LastNetworkScanResult) {
        ''
        $script:LastNetworkScanResult |
            Select-String -Pattern 'Phase|Scan Results|Total Time' |
            ForEach-Object { $_.Line }
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    $foundIPs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $foundHostNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($hostEntry in $hosts) {
        if (-not [string]::IsNullOrWhiteSpace($hostEntry.IP)) { $null = $foundIPs.Add([string]$hostEntry.IP) }
        if (-not [string]::IsNullOrWhiteSpace($hostEntry.HostName)) { $null = $foundHostNames.Add([string]$hostEntry.HostName) }
    }

    if ($CompareExplorer) {
        ''
        'Explorer Network Computers:'
        if ($explorerHosts.Count -gt 0) {
            $explorerRows = [System.Collections.Generic.List[object]]::new()
            foreach ($explorerHost in $explorerHosts) {
                $explorerName = [string]$explorerHost.HostName
                $resolvedIPs = @(Resolve-TestExplorerHostIPv4 -HostName $explorerName)

                $matchedByName = (-not [string]::IsNullOrWhiteSpace($explorerName)) -and $foundHostNames.Contains($explorerName)
                $matchedByIP = $false
                foreach ($resolvedIP in @($resolvedIPs)) {
                    if ($foundIPs.Contains($resolvedIP)) {
                        $matchedByIP = $true
                        break
                    }
                }
                $isMatched = $matchedByName -or $matchedByIP
                if (-not $isMatched) {
                    $missing.Add("Explorer $explorerName")
                }

                $explorerRows.Add([PSCustomObject]@{
                    HostName      = $explorerName
                    ResolvedIPs   = (@($resolvedIPs) -join ', ')
                    InDeviceCheck = $isMatched
                })
            }

            $explorerRows | Sort-Object HostName | Format-Table -AutoSize
        } else {
            "  (Explorer Network returned no Computer rows, or the bounded helper timed out after $ExplorerTimeoutMilliseconds ms.)"
            if ($RequireExplorerRows) {
                $missing.Add('Explorer Network Computer rows')
            }
        }
    }

    foreach ($expected in @($ExpectedIP)) {
        if ([string]::IsNullOrWhiteSpace($expected)) { continue }
        if (-not $foundIPs.Contains($expected)) {
            $missing.Add("IP $expected")
        }
    }

    foreach ($expected in @($ExpectedHostName)) {
        if ([string]::IsNullOrWhiteSpace($expected)) { continue }
        if (-not $foundHostNames.Contains($expected)) {
            $missing.Add("HostName $expected")
        }
    }

    $runMissingText = ''
    if ($missing.Count -gt 0) {
        $runMissingText = $missing -join ', '
        $allMissing.Add("run $runIndex`: $runMissingText")
        Write-Warning "Run $runIndex missing expected discovered PC(s): $runMissingText"
    }

    $summaryRows.Add([PSCustomObject]@{
        Run           = $runIndex
        DeviceCheckPCs = $hosts.Count
        ExplorerPCs   = $explorerHosts.Count
        Missing       = $runMissingText
    })

    if ($runIndex -lt $RepeatCount -and $RepeatDelaySeconds -gt 0) {
        Start-Sleep -Seconds $RepeatDelaySeconds
    }
}

if ($RepeatCount -gt 1) {
    ''
    'Repeat summary:'
    $summaryRows | Format-Table -AutoSize
}

if ($allMissing.Count -gt 0) {
    $message = "Missing expected discovered PC(s): $($allMissing -join '; ')"
    if ($FailOnMissing) { throw $message }
}
