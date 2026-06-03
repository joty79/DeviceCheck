[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, Position = 0, ValueFromRemainingArguments = $true)]
    [Alias('Id')]
    [string[]]$HardwareId,

    [string]$CacheRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data\hwdb'),

    [switch]$AsJson,

    [switch]$AsObject
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path $PSScriptRoot 'HardwareIdResolver.psm1') -Force
    $hardwareIds = [System.Collections.Generic.List[string]]::new()
}

process {
    foreach ($hardwareIdValue in @($HardwareId)) {
        if (-not [string]::IsNullOrWhiteSpace($hardwareIdValue)) {
            $hardwareIds.Add($hardwareIdValue)
        }
    }
}

end {
    if ($hardwareIds.Count -eq 0) {
        throw 'Provide at least one hardware ID via -HardwareId, positional arguments, or pipeline input.'
    }

    $results = @(Resolve-HardwareId -HardwareId $hardwareIds.ToArray() -CacheRoot $CacheRoot)

    if ($AsObject) {
        $results
        return
    }

    if ($AsJson) {
        $results | ConvertTo-Json -Depth 16
        return
    }

    $formattedBlocks = @(Format-HardwareIdResolution -Resolution $results)
    $formattedBlocks -join ([Environment]::NewLine + [Environment]::NewLine)
}
