Set-StrictMode -Version Latest

function Resolve-MSCatalogModulePath {
    param(
        [AllowEmptyString()]
        [string]$RequestedPath,
        [string]$RepoRoot
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates.Add($RequestedPath)
    }

    $scriptsRoot = Split-Path -Parent $RepoRoot
    $candidates.Add((Join-Path $scriptsRoot 'MSCatalogLTS\MSCatalogLTS.psd1'))
    $candidates.Add((Join-Path $env:USERPROFILE 'scripts\MSCatalogLTS\MSCatalogLTS.psd1'))

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }

    throw "MSCatalogLTS module not found. Checked: $(@($candidates) -join ', ')"
}

function Get-CatalogDriverEvidence {
    param(
        [string[]]$HardwareIds,
        [string]$ModulePath,
        [int]$MaximumRows = 25
    )

    Import-Module $ModulePath -Force -ErrorAction Stop
    if ($null -eq (Get-Command Get-MSCatalogUpdate -ErrorAction SilentlyContinue)) {
        throw "Get-MSCatalogUpdate was not exported by '$ModulePath'."
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $attempts = [System.Collections.Generic.List[object]]::new()
    $updates = @()
    $selectedHardwareId = ''
    foreach ($hardwareId in @($HardwareIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique -First 4)) {
        $queryStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $queryRows = @(Get-MSCatalogUpdate -Search $hardwareId -ErrorAction Stop)
        $queryStopwatch.Stop()
        $attempts.Add([pscustomobject]@{
                HardwareId = $hardwareId
                RowCount   = $queryRows.Count
                ElapsedMs  = [int]$queryStopwatch.ElapsedMilliseconds
            })
        if ($queryRows.Count -gt 0) {
            $selectedHardwareId = $hardwareId
            $updates = @($queryRows)
            break
        }
    }
    $stopwatch.Stop()

    $rows = @(
        foreach ($update in @($updates | Select-Object -First $MaximumRows)) {
            [pscustomobject]@{
                Source             = 'CatalogPublic'
                Confidence         = 'DiscoveryOnly'
                EvidenceSource     = 'MSCatalogLTS public Catalog HTML search'
                QueryHardwareId    = $selectedHardwareId
                MatchKind          = 'CatalogTextSearchHit'
                Title              = [string]$update.Title
                Products           = [string]$update.Products
                Classification     = [string]$update.Classification
                LastUpdated        = if ($update.LastUpdated -is [datetime]) { $update.LastUpdated.ToString('o') } else { [string]$update.LastUpdated }
                Version            = [string]$update.Version
                Size               = [string]$update.Size
                Guid               = [string]$update.Guid
                SupportUrl         = [string]$update.SupportUrl
                SHA1               = [string]$update.SHA1
                MachineApplicable  = 'Unknown'
                WindowsRank        = $null
                ActiveState        = 'Unknown'
            }
        }
    )

    [pscustomobject]@{
        Source          = 'CatalogPublic'
        Confidence      = 'DiscoveryOnly'
        EvidenceSource  = 'MSCatalogLTS public Catalog HTML search'
        ModulePath      = $ModulePath
        QueryHardwareId = $selectedHardwareId
        QueryAttempts    = @($attempts)
        TotalRowCount   = $updates.Count
        ReturnedRows    = $rows.Count
        ElapsedMs       = [int]$stopwatch.ElapsedMilliseconds
        Outcome         = if ($updates.Count -gt 0) { 'CatalogDiscoveryOnly' } else { 'NoPublicCatalogRowsObserved' }
        Interpretation  = 'Public Catalog rows do not prove machine applicability, CHID targeting, current WU assignment, PnP rank, or active selection.'
        Rows            = @($rows)
    }
}
