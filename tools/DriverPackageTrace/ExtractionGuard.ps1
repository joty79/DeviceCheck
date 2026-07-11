Set-StrictMode -Version Latest

function Get-DriverPackageExtractionOptionalProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return '' }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Get-DriverPackageExtractionUninstallInventory {
    $roots = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            $rows.Add([pscustomobject]@{
                Root = $root
                Key = [string]$key.PSChildName
                DisplayName = Get-DriverPackageExtractionOptionalProperty -InputObject $properties -Name 'DisplayName'
                DisplayVersion = Get-DriverPackageExtractionOptionalProperty -InputObject $properties -Name 'DisplayVersion'
                Publisher = Get-DriverPackageExtractionOptionalProperty -InputObject $properties -Name 'Publisher'
            })
        }
    }

    return @($rows | Sort-Object Root, Key)
}

function Get-DriverPackageExtractionPublishedDriverText {
    $lines = @(pnputil.exe /enum-drivers 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "pnputil /enum-drivers failed with exit code $exitCode."
    }
    return ($lines -join "`n")
}

function Get-DriverPackageExtractionTextHash {
    param([AllowEmptyString()][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function New-DriverPackageExtractionGuardSnapshot {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    $setupApiPath = Join-Path $env:WINDIR 'INF\setupapi.dev.log'
    $setupApiItem = Get-Item -LiteralPath $setupApiPath -ErrorAction SilentlyContinue
    $publishedDriverText = Get-DriverPackageExtractionPublishedDriverText
    $uninstallInventory = @(Get-DriverPackageExtractionUninstallInventory)
    $snapshot = [pscustomobject]@{
        CapturedAt = (Get-Date).ToString('o')
        Name = $Name
        PublishedDriverHash = Get-DriverPackageExtractionTextHash -Text $publishedDriverText
        PublishedDriverCount = @($publishedDriverText -split "`r?`n" | Where-Object { $_ -match '^(?i)Published Name\s*:' }).Count
        SetupApiPath = $setupApiPath
        SetupApiLength = if ($null -ne $setupApiItem) { [long]$setupApiItem.Length } else { 0 }
        SetupApiLastWriteTimeUtc = if ($null -ne $setupApiItem) { $setupApiItem.LastWriteTimeUtc.ToString('o') } else { '' }
        UninstallInventoryHash = Get-DriverPackageExtractionTextHash -Text (($uninstallInventory | ConvertTo-Json -Depth 4 -Compress))
        UninstallEntryCount = $uninstallInventory.Count
        UninstallInventory = $uninstallInventory
    }

    $path = Join-Path $OutputDirectory "$Name.extraction-guard.json"
    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $snapshot
}

function Compare-DriverPackageExtractionGuardSnapshots {
    param(
        [Parameter(Mandatory)][object]$Before,
        [Parameter(Mandatory)][object]$After
    )

    $publishedDriversChanged = [string]$Before.PublishedDriverHash -ne [string]$After.PublishedDriverHash
    $setupApiChanged = [long]$Before.SetupApiLength -ne [long]$After.SetupApiLength -or [string]$Before.SetupApiLastWriteTimeUtc -ne [string]$After.SetupApiLastWriteTimeUtc
    $uninstallChanged = [string]$Before.UninstallInventoryHash -ne [string]$After.UninstallInventoryHash

    return [pscustomobject]@{
        PublishedDriversChanged = $publishedDriversChanged
        PublishedDriverCountBefore = [int]$Before.PublishedDriverCount
        PublishedDriverCountAfter = [int]$After.PublishedDriverCount
        SetupApiChanged = $setupApiChanged
        SetupApiLengthBefore = [long]$Before.SetupApiLength
        SetupApiLengthAfter = [long]$After.SetupApiLength
        UninstallInventoryChanged = $uninstallChanged
        UninstallEntryCountBefore = [int]$Before.UninstallEntryCount
        UninstallEntryCountAfter = [int]$After.UninstallEntryCount
        SystemMutationDetected = $publishedDriversChanged -or $setupApiChanged -or $uninstallChanged
    }
}
