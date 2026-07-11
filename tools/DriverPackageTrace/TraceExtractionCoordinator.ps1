Set-StrictMode -Version Latest

function Invoke-TraceDriverPackagePayloadExtraction {
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('None', 'Safe', 'Extended')][string]$Mode,
        [switch]$ForceReextract,
        [ValidateRange(0, 4)][int]$MaxDepth = 2,
        [switch]$PromptForExtendedExtraction
    )

    $extractionCacheRoot = Join-Path $RepoRoot '.devicecheck-data\driver-package-extractions'
    $existingPayloadRoot = Find-ExistingExtractedPackageRoot -PackagePath $InstallerPath
    $effectiveMode = $Mode
    $guardBefore = $null
    $guardDiff = $null

    if ($effectiveMode -eq 'Extended') {
        if (-not (Get-IsAdministrator)) {
            Write-Host ''
            Write-Host '⚠️⚠️⚠️ ELEVATION REQUIRED' -ForegroundColor Yellow
            throw 'Extended extraction can execute an administrative installer path and requires elevation.'
        }
        Write-Host ''
        Write-Host '⚠️⚠️⚠️ EXTENDED EXTRACTION' -ForegroundColor Yellow
        Write-Host 'This mode may execute a proven InstallShield administrative path. A system-mutation guard will run before and after.' -ForegroundColor Yellow
        $guardBefore = New-DriverPackageExtractionGuardSnapshot -Name 'before' -OutputDirectory $OutputDirectory
    }

    Write-TraceSection 'Payload extraction'
    $result = Invoke-DriverPackagePayloadExtraction -PackagePath $InstallerPath -Mode $effectiveMode -CacheRoot $extractionCacheRoot -ExistingPayloadRoot $existingPayloadRoot -ForceReextract:$ForceReextract -MaxDepth $MaxDepth

    if ($effectiveMode -eq 'Safe' -and $PromptForExtendedExtraction) {
        $safeInventory = Get-TraceObjectValue -InputObject $result.Manifest -Name 'Inventory'
        $safeInfCount = [int](Get-TraceObjectValue -InputObject $safeInventory -Name 'InfCount')
        $extendedCandidates = @(Get-TraceObjectValue -InputObject $result.Manifest -Name 'ExtendedCandidates')
        if ($safeInfCount -eq 0 -and $extendedCandidates.Count -gt 0) {
            Write-Host ''
            Write-Host '⚠️⚠️⚠️ SAFE EXTRACTION INCOMPLETE' -ForegroundColor Yellow
            Write-Host 'InstallShield was detected, but Safe extraction found no INF files.' -ForegroundColor Yellow
            Write-Host 'Extended extraction can execute a proven administrative path under before/after mutation guards.' -ForegroundColor Yellow
            $extendedAnswer = Read-Host 'Run Extended extraction now? [y/N]'
            if ($extendedAnswer -match '^(?i:y|yes)$') {
                if (-not (Get-IsAdministrator)) {
                    Write-Host '⚠️⚠️⚠️ ELEVATION REQUIRED' -ForegroundColor Yellow
                    throw 'Extended extraction requires an elevated PowerShell session.'
                }
                $effectiveMode = 'Extended'
                $guardBefore = New-DriverPackageExtractionGuardSnapshot -Name 'before' -OutputDirectory $OutputDirectory
                $result = Invoke-DriverPackagePayloadExtraction -PackagePath $InstallerPath -Mode Extended -CacheRoot $extractionCacheRoot -ExistingPayloadRoot $existingPayloadRoot -ForceReextract:$ForceReextract -MaxDepth $MaxDepth
            }
        }
    }

    if ($effectiveMode -eq 'Extended' -and $null -ne $guardBefore) {
        $guardAfter = New-DriverPackageExtractionGuardSnapshot -Name 'after' -OutputDirectory $OutputDirectory
        $guardDiff = Compare-DriverPackageExtractionGuardSnapshots -Before $guardBefore -After $guardAfter
        $result.Manifest | Add-Member -NotePropertyName Guard -NotePropertyValue $guardDiff -Force
    }

    $traceManifestPath = Join-Path $OutputDirectory 'extraction-manifest.json'
    Save-JsonFile -Data $result.Manifest -Path $traceManifestPath
    if (-not [string]::IsNullOrWhiteSpace([string]$result.ManifestPath)) {
        Save-JsonFile -Data $result.Manifest -Path ([string]$result.ManifestPath)
    }

    $inventory = Get-TraceObjectValue -InputObject $result.Manifest -Name 'Inventory'
    $identification = Get-TraceObjectValue -InputObject $result.Manifest -Name 'Identification'
    Write-Host "Engine  : $(Get-TraceObjectValue -InputObject $identification -Name 'Engine')" -ForegroundColor Cyan
    Write-Host "Payload : $($result.PayloadRoot)" -ForegroundColor Cyan
    Write-Host ("Files   : {0}; INF: {1}; MSI: {2}; SYS: {3}; CAT: {4}" -f
        (Get-TraceObjectValue -InputObject $inventory -Name 'FileCount'),
        (Get-TraceObjectValue -InputObject $inventory -Name 'InfCount'),
        (Get-TraceObjectValue -InputObject $inventory -Name 'MsiCount'),
        (Get-TraceObjectValue -InputObject $inventory -Name 'SysCount'),
        (Get-TraceObjectValue -InputObject $inventory -Name 'CatCount')) -ForegroundColor Cyan
    if ($result.CacheReused) {
        Write-Host 'Cache   : reused by source SHA-256' -ForegroundColor Green
    }

    $unavailableAttempts = @((Get-TraceObjectValue -InputObject $result.Manifest -Name 'Attempts') | Where-Object { [string]$_.Status -eq 'Tool unavailable' })
    if ($unavailableAttempts.Count -gt 0) {
        Write-Host ''
        Write-Host '⚠️⚠️⚠️ NEED TOOL' -ForegroundColor Yellow
        foreach ($unavailableAttempt in $unavailableAttempts) {
            Write-Host ("{0}: {1}" -f $unavailableAttempt.Tool, $unavailableAttempt.Error) -ForegroundColor Yellow
        }
    }

    if ($null -ne $guardDiff -and $guardDiff.SystemMutationDetected) {
        Write-Host ''
        Write-Host '⚠️⚠️⚠️ EXTRACTION CHANGED SYSTEM STATE' -ForegroundColor Red
        throw 'Extended extraction changed DriverStore, SetupAPI, or uninstall state. The normal installer trace was stopped; inspect extraction guard evidence.'
    }

    return $result
}

function Add-TraceDriverPackageExtractionMarkdown {
    param(
        [Parameter(Mandatory)][object]$Lines,
        [AllowNull()][object]$Manifest
    )

    if ($null -eq $Manifest) { return }

    $Lines.Add('## Extraction Evidence')
    $Lines.Add('')
    $Lines.Add(('- Source SHA-256: `{0}`' -f (Get-TraceObjectValue -InputObject (Get-TraceObjectValue -InputObject $Manifest -Name 'Source') -Name 'Sha256')))
    $Lines.Add(('- Payload root: `{0}`' -f (Get-TraceObjectValue -InputObject $Manifest -Name 'PayloadRoot')))
    $inventory = Get-TraceObjectValue -InputObject $Manifest -Name 'Inventory'
    $Lines.Add(('- Inventory: `{0}` files, `{1}` INF, `{2}` MSI, `{3}` SYS, `{4}` CAT' -f
        (Get-TraceObjectValue -InputObject $inventory -Name 'FileCount'),
        (Get-TraceObjectValue -InputObject $inventory -Name 'InfCount'),
        (Get-TraceObjectValue -InputObject $inventory -Name 'MsiCount'),
        (Get-TraceObjectValue -InputObject $inventory -Name 'SysCount'),
        (Get-TraceObjectValue -InputObject $inventory -Name 'CatCount')))
    $Lines.Add('')

    $attempts = @(Get-TraceObjectValue -InputObject $Manifest -Name 'Attempts')
    if ($attempts.Count -gt 0) {
        $Lines.Add('| Kind | Depth | Engine | Tool | Status | Exit | Files | INF | Package |')
        $Lines.Add('|---|---:|---|---|---|---:|---:|---:|---|')
        foreach ($attempt in $attempts) {
            $Lines.Add(('| {0} | {1} | {2} | {3} | {4} | `{5}` | {6} | {7} | `{8}` |' -f
                (ConvertTo-MarkdownCell (Get-TraceObjectValue -InputObject $attempt -Name 'Kind')),
                (ConvertTo-MarkdownCell (Get-TraceObjectValue -InputObject $attempt -Name 'Depth')),
                (ConvertTo-MarkdownCell (Get-TraceObjectValue -InputObject $attempt -Name 'Engine')),
                (ConvertTo-MarkdownCell (Get-TraceObjectValue -InputObject $attempt -Name 'Tool')),
                (ConvertTo-MarkdownCell (Get-TraceObjectValue -InputObject $attempt -Name 'Status')),
                (ConvertTo-MarkdownCell (Get-TraceObjectValue -InputObject $attempt -Name 'ExitCode')),
                (ConvertTo-MarkdownCell (Get-TraceObjectValue -InputObject $attempt -Name 'FileCount')),
                (ConvertTo-MarkdownCell (Get-TraceObjectValue -InputObject $attempt -Name 'InfCount')),
                (ConvertTo-MarkdownCell (Get-TraceObjectValue -InputObject $attempt -Name 'PackagePath'))))
        }
        $Lines.Add('')
    } else {
        $Lines.Add('No extractor command ran; an existing payload or `None` mode was used.')
        $Lines.Add('')
    }

    $warnings = @(Get-TraceObjectValue -InputObject $Manifest -Name 'Warnings')
    if ($warnings.Count -gt 0) {
        $Lines.Add('### Extraction Warnings')
        $Lines.Add('')
        foreach ($warning in $warnings) {
            if (-not [string]::IsNullOrWhiteSpace([string]$warning)) {
                $Lines.Add(('- {0}' -f (ConvertTo-MarkdownCell $warning)))
            }
        }
        $Lines.Add('')
    }

    $guard = Get-TraceObjectValue -InputObject $Manifest -Name 'Guard'
    if ($guard -is [string] -and [string]::IsNullOrWhiteSpace($guard)) { return }

    $Lines.Add('### Extended Extraction Guard')
    $Lines.Add('')
    $Lines.Add(('- System mutation detected: `{0}`' -f (Get-TraceObjectValue -InputObject $guard -Name 'SystemMutationDetected')))
    $Lines.Add(('- Published drivers: `{0}` → `{1}`; changed: `{2}`' -f
        (Get-TraceObjectValue -InputObject $guard -Name 'PublishedDriverCountBefore'),
        (Get-TraceObjectValue -InputObject $guard -Name 'PublishedDriverCountAfter'),
        (Get-TraceObjectValue -InputObject $guard -Name 'PublishedDriversChanged')))
    $Lines.Add(('- SetupAPI changed: `{0}`; bytes: `{1}` → `{2}`' -f
        (Get-TraceObjectValue -InputObject $guard -Name 'SetupApiChanged'),
        (Get-TraceObjectValue -InputObject $guard -Name 'SetupApiLengthBefore'),
        (Get-TraceObjectValue -InputObject $guard -Name 'SetupApiLengthAfter')))
    $Lines.Add(('- Uninstall inventory: `{0}` → `{1}`; changed: `{2}`' -f
        (Get-TraceObjectValue -InputObject $guard -Name 'UninstallEntryCountBefore'),
        (Get-TraceObjectValue -InputObject $guard -Name 'UninstallEntryCountAfter'),
        (Get-TraceObjectValue -InputObject $guard -Name 'UninstallInventoryChanged')))
    $Lines.Add('')
}
