# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: Thin DeviceCheck adapters for canonical WinRM target history and catalog rows.

function Get-DeviceCheckConnectionHistory {
    if ($null -ne (Get-Command -Name 'Get-WinRMConnectionHistory' -ErrorAction SilentlyContinue)) {
        return [System.Collections.Generic.List[object]]::new(@(Get-WinRMConnectionHistory))
    }
    $path = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'connection-history.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $history = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($history -is [Array]) {
                return [System.Collections.Generic.List[object]]::new($history)
            }
            return [System.Collections.Generic.List[object]]::new(@($history))
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
    if ($null -ne (Get-Command -Name 'Add-WinRMConnectionHistoryEntry' -ErrorAction SilentlyContinue)) {
        Add-WinRMConnectionHistoryEntry -ComputerName $ComputerName -LastIPAddress $LastIPAddress -MACAddress $MACAddress -UserName $UserName -NetworkId $NetworkId
        return
    }
    if (-not (Test-DeviceCheckIPv4Address -Address $LastIPAddress)) { $LastIPAddress = $null }

    $historyList = Get-DeviceCheckConnectionHistory
    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($historyList)) { $history.Add($item) }

    $existing = $null
    foreach ($entry in $history) {
        if ($entry.NetworkId -ne $NetworkId) { continue }
        if ($entry.ComputerName.Equals($ComputerName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $existing = $entry
            break
        }
        if ($entry.ComputerName -match '^\d+\.\d+\.\d+\.\d+$' -and ($entry.ComputerName -eq $LastIPAddress -or $entry.LastIPAddress -eq $LastIPAddress)) {
            $existing = $entry
            break
        }
    }

    if ($null -ne $existing) {
        if ($existing.ComputerName -match '^\d+\.\d+\.\d+\.\d+$' -and $ComputerName -notmatch '^\d+\.\d+\.\d+\.\d+$') { $existing.ComputerName = $ComputerName }
        if (-not [string]::IsNullOrWhiteSpace($LastIPAddress)) { $existing.LastIPAddress = $LastIPAddress }
        if (-not [string]::IsNullOrWhiteSpace($MACAddress) -and $MACAddress -ne 'Unknown') { $existing.MACAddress = $MACAddress }
        $existing.UserName = $UserName
        $existing.LastConnected = (Get-Date).ToString('o')
    } else {
        $history.Add([PSCustomObject]@{
            ComputerName  = $ComputerName
            LastIPAddress = $LastIPAddress
            MACAddress    = $(if ([string]::IsNullOrWhiteSpace($MACAddress)) { 'Unknown' } else { $MACAddress })
            UserName      = $UserName
            NetworkId     = $NetworkId
            LastConnected = (Get-Date).ToString('o')
        })
    }

    $sortedHistory = [System.Collections.Generic.List[object]]::new(@($history | Sort-Object { [DateTime]$_.LastConnected } -Descending))
    Save-DeviceCheckConnectionHistory -History $sortedHistory
}
