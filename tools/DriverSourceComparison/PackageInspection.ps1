Set-StrictMode -Version Latest

function ConvertFrom-DriverComparisonDriverVer {
    param(
        [AllowEmptyString()]
        [string]$DriverVer
    )

    if ($DriverVer -notmatch '^\s*(?<Date>\d{1,2}/\d{1,2}/\d{4})\s*,\s*(?<Version>[0-9.]+)\s*$') {
        return [pscustomobject]@{ Date = $null; Version = ''; Raw = $DriverVer }
    }

    $parsedDate = [datetime]::MinValue
    [void][datetime]::TryParseExact(
        $Matches.Date,
        [string[]]@('M/d/yyyy', 'MM/dd/yyyy'),
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsedDate
    )

    [pscustomobject]@{
        Date    = if ($parsedDate -eq [datetime]::MinValue) { $null } else { $parsedDate }
        Version = $Matches.Version
        Raw     = $DriverVer
    }
}

function Get-DriverComparisonInfFeatureScore {
    param(
        [string]$InfPath,
        [string]$InstallSection
    )

    $sectionPattern = '^\s*\[' + [regex]::Escape($InstallSection) + '(?:\.[^\]]+)?\]\s*$'
    $insideTargetSection = $false
    foreach ($line in [IO.File]::ReadLines($InfPath)) {
        if ($line -match '^\s*\[[^\]]+\]\s*$') {
            $insideTargetSection = $line -match $sectionPattern
            continue
        }
        if ($insideTargetSection -and $line -match '^\s*FeatureScore\s*=\s*(?<Score>0x[0-9A-Fa-f]{1,2}|\d+)') {
            $text = $Matches.Score
            $value = if ($text.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) {
                [Convert]::ToInt32($text.Substring(2), 16)
            }
            else {
                [int]$text
            }
            return [pscustomobject]@{ Value = $value; Source = 'ExplicitFeatureScore' }
        }
    }

    return [pscustomobject]@{ Value = 0xFF; Source = 'DocumentedDefaultNoDirective' }
}

function Get-DriverComparisonInfIdPosition {
    param(
        [AllowEmptyString()]
        [string]$ModelLine,
        [string]$HardwareId
    )

    if ($ModelLine -notmatch '=') {
        return -1
    }

    $right = ($ModelLine -split '=', 2)[1]
    $parts = @($right -split ',' | ForEach-Object { $_.Trim() })
    for ($index = 1; $index -lt $parts.Count; $index++) {
        if ($parts[$index] -eq $HardwareId) {
            return ($index - 1)
        }
    }
    return -1
}

function Get-DriverComparisonRelation {
    param(
        $Candidate,
        $Active
    )

    $dateRelation = 'Unknown'
    if ($null -ne $Candidate.Date -and $null -ne $Active.Date) {
        $dateRelation = if ($Candidate.Date -gt $Active.Date) { 'Newer' } elseif ($Candidate.Date -lt $Active.Date) { 'Older' } else { 'Same' }
    }

    $versionRelation = 'Unknown'
    $candidateVersion = $null
    $activeVersion = $null
    if ([version]::TryParse($Candidate.Version, [ref]$candidateVersion) -and [version]::TryParse($Active.Version, [ref]$activeVersion)) {
        $versionRelation = if ($candidateVersion -gt $activeVersion) { 'Higher' } elseif ($candidateVersion -lt $activeVersion) { 'Lower' } else { 'Same' }
    }

    [pscustomobject]@{
        DateRelation    = $dateRelation
        VersionRelation = $versionRelation
        RuleReminder    = 'Windows compares date before version after otherwise-equal rank.'
    }
}

function Import-CatalogPackageInspectionEvidence {
    param(
        [string]$ManifestPath,
        [string]$ExpectedInstanceId
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Catalog inspection manifest not found: $ManifestPath"
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ([int]$manifest.SchemaVersion -ne 1) {
        throw "Unsupported Catalog inspection schema version '$($manifest.SchemaVersion)'."
    }
    if ($manifest.Target.InstanceId -ne $ExpectedInstanceId) {
        throw "Catalog inspection target '$($manifest.Target.InstanceId)' does not match '$ExpectedInstanceId'."
    }
    if ($manifest.Safety.InstallsDrivers -or $manifest.Safety.StagesDrivers) {
        throw 'Catalog inspection manifest does not satisfy the no-install/no-stage safety contract.'
    }

    return $manifest
}
