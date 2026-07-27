Set-StrictMode -Version Latest

function ConvertTo-TraceEvidenceVersionKey {
    param([AllowEmptyString()][string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return '' }
    return (@($Version.Trim() -split '\.' | ForEach-Object { if ($_ -match '^\d+$') { [string][int64]$_ } else { $_.ToLowerInvariant() } }) -join '.')
}

function ConvertFrom-TraceEvidenceDriverVer {
    param([AllowEmptyString()][string]$DriverVer)
    if ($DriverVer -notmatch '^\s*(?<date>[^,]+),\s*(?<version>.+?)\s*$') {
        return [pscustomobject]@{ Date=''; VersionKey=(ConvertTo-TraceEvidenceVersionKey $DriverVer) }
    }
    [datetime]$date = [datetime]::MinValue
    $dateText = if ([datetime]::TryParse($Matches.date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) { $date.ToString('yyyy-MM-dd') } else { $Matches.date.Trim() }
    return [pscustomobject]@{ Date=$dateText; VersionKey=(ConvertTo-TraceEvidenceVersionKey $Matches.version) }
}

function Test-TraceEvidencePackageNode {
    param($Node, $PreviewMatch)

    $previewName = [IO.Path]::GetFileName(([string]$PreviewMatch.Inf).Replace('\', [IO.Path]::DirectorySeparatorChar))
    if (-not $previewName -or $previewName -ine [string]$Node.OriginalName) { return $false }
    $previewVersion = ConvertFrom-TraceEvidenceDriverVer -DriverVer ([string]$PreviewMatch.DriverVer)
    $nodeVersionKey = ConvertTo-TraceEvidenceVersionKey -Version ([string]$Node.DriverVersion)
    return $previewVersion.Date -eq [string]$Node.DriverDate -and $previewVersion.VersionKey -eq $nodeVersionKey
}

function Get-DriverPackageTraceEvidence {
    param(
        [string]$TraceFolder,
        [string]$InstanceId
    )

    $previewPath = Join-Path $TraceFolder 'package-preview.json'
    $diffPath = Join-Path $TraceFolder 'diff.json'
    if (-not (Test-Path -LiteralPath $previewPath -PathType Leaf)) {
        throw "Required trace preview evidence file not found: $previewPath"
    }

    $preview = Get-Content -LiteralPath $previewPath -Raw | ConvertFrom-Json
    $diff = if (Test-Path -LiteralPath $diffPath -PathType Leaf) { Get-Content -LiteralPath $diffPath -Raw | ConvertFrom-Json } else { $null }
    $targetNodes = @(
        if ($null -ne $diff) {
            $diff.SetupApiDriverNodes | Where-Object { $_.DeviceID -eq $InstanceId }
        }
    )
    $targetMatches = @($preview.Matches | Where-Object { $_.InstanceId -eq $InstanceId })
    $targetPackageNodes = @(
        $targetNodes | Where-Object {
            $node = $_
            @($targetMatches | Where-Object { Test-TraceEvidencePackageNode -Node $node -PreviewMatch $_ }).Count -gt 0
        }
    )

    [pscustomobject]@{
        Source                 = 'OEMTrace'
        Confidence             = 'Observed'
        EvidenceSource         = @($previewPath, $(if ($null -ne $diff) { $diffPath }))
        TraceFolder            = $TraceFolder
        InstallerPath          = [string]$preview.InstallerPath
        InstallerName          = [string]$preview.InstallerName
        InstallerHash          = [string]$preview.InstallerHash
        PayloadKind            = [string]$preview.PayloadKind
        InfCount               = [int]$preview.InfCount
        TargetPreviewMatches   = @($targetMatches)
        TargetDriverNodes      = @($targetNodes)
        TargetPackageNodes     = @($targetPackageNodes)
        AddedPublishedDrivers  = @($(if ($null -ne $diff) { $diff.AddedPublishedDrivers }))
        AddedDriverStoreFolders = @($(if ($null -ne $diff) { $diff.AddedDriverStoreFolders }))
        Outcome                = if (@($targetPackageNodes | Where-Object { $_.NodeKind -eq 'Extension' -and $_.Status -match 'Selected|Installed' }).Count -gt 0) {
            'ObservedAppliedExtension'
        }
        elseif (@($targetPackageNodes | Where-Object { $_.NodeKind -eq 'Driver' -and $_.Status -match 'Selected|Installed' }).Count -gt 0) {
            'ObservedSelectedPackageCandidate'
        }
        elseif (@($targetPackageNodes | Where-Object { $_.Status -match 'Outranked' }).Count -gt 0) {
            'ObservedOutrankedCandidate'
        }
        elseif ($targetMatches.Count -gt 0 -and $null -eq $diff) {
            'ObservedPackageMatchPreviewOnly'
        }
        elseif ($targetMatches.Count -gt 0) {
            'ObservedPackageMatch'
        }
        else {
            'NoTargetMatchObserved'
        }
        Interpretation         = 'Trace evidence describes this installer run and local selection event; it is not a general source-wide ranking rule.'
    }
}
