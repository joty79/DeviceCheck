# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: Thin DeviceCheck adapters for canonical WinRM target history and catalog rows.

function Get-DeviceCheckConnectionHistory {
    return [System.Collections.Generic.List[object]]::new(@(Get-WinRMConnectionHistory))
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
    Add-WinRMConnectionHistoryEntry -ComputerName $ComputerName -LastIPAddress $LastIPAddress -MACAddress $MACAddress -UserName $UserName -NetworkId $NetworkId
}
