#requires -version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive audit summary is intentional; -AsJson provides pipeline-safe output.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'SHA-1 is verified only because Microsoft Catalog publishes that digest; SHA-256 is also recorded for integrity evidence.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$Guid,

    [string]$Filter = 'RZ616 Wi-Fi 6E',

    [AllowEmptyString()]
    [string]$InstanceId = '',

    [AllowEmptyString()]
    [string]$MSCatalogModulePath = '',

    [AllowEmptyString()]
    [string]$InspectionDirectory = '',

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$helperRoot = Join-Path $PSScriptRoot 'DriverSourceComparison'
. (Join-Path $helperRoot 'LocalEvidence.ps1')
. (Join-Path $helperRoot 'CatalogEvidence.ps1')
. (Join-Path $helperRoot 'PackageInspection.ps1')
Import-Module (Join-Path $repoRoot 'internal\InfDriverParser.psm1') -Force -ErrorAction Stop

$local = Get-DriverComparisonLocalEvidence -Filter $Filter -InstanceId $InstanceId -KnownActiveSource ''
$modulePath = Resolve-MSCatalogModulePath -RequestedPath $MSCatalogModulePath -RepoRoot $repoRoot
Import-Module $modulePath -Force -ErrorAction Stop
$catalogModule = Get-Module MSCatalogLTS
if ($null -eq $catalogModule) {
    throw "MSCatalogLTS did not load from '$modulePath'."
}

if ([string]::IsNullOrWhiteSpace($InspectionDirectory)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $InspectionDirectory = Join-Path $repoRoot ".devicecheck-data\driver-catalog-inspections\catalog-inspection-$stamp"
}
$InspectionDirectory = [IO.Path]::GetFullPath($InspectionDirectory)
$downloadRoot = Join-Path $InspectionDirectory 'downloads'
$extractedRoot = Join-Path $InspectionDirectory 'extracted'
New-Item -ItemType Directory -Path $downloadRoot, $extractedRoot -Force | Out-Null

$primarySearchId = @($local.Device.HardwareIds | Select-Object -Skip 1 -First 1)
if ($primarySearchId.Count -eq 0) {
    $primarySearchId = @($local.Device.HardwareIds | Select-Object -First 1)
}
$catalogRows = if ($primarySearchId.Count -gt 0) {
    @(Get-MSCatalogUpdate -Search $primarySearchId[0] -ErrorAction Stop)
}
else {
    @()
}

$guardBefore = [pscustomobject]@{
    PublishedInfCount      = @(Get-ChildItem "$env:windir\INF\oem*.inf" -File).Count
    DriverStoreFolderCount = @(Get-ChildItem "$env:windir\System32\DriverStore\FileRepository" -Directory).Count
    SetupApiLength         = (Get-Item "$env:windir\INF\setupapi.dev.log").Length
}

$packages = [System.Collections.Generic.List[object]]::new()
foreach ($catalogGuid in @($Guid | Select-Object -Unique)) {
    $links = @(& $catalogModule { param($UpdateGuid) Get-UpdateLinks -Guid $UpdateGuid } $catalogGuid)
    if ($links.Count -eq 0) {
        throw "No Catalog download link was returned for GUID '$catalogGuid'."
    }
    if ($links.Count -gt 1) {
        throw "Catalog GUID '$catalogGuid' returned $($links.Count) files; explicit multi-file handling is required."
    }

    $link = $links[0]
    $url = [string]$link.Url
    $urlBaseName = [IO.Path]::GetFileNameWithoutExtension(([uri]$url).AbsolutePath)
    $payloadId = ($urlBaseName -split '_', 2)[0]
    $cabPath = Join-Path $downloadRoot "$payloadId.cab"
    if (-not (Test-Path -LiteralPath $cabPath -PathType Leaf)) {
        Save-MSCatalogUpdate -Guid $catalogGuid -Destination $downloadRoot -Force -ErrorAction Stop | Out-Host
    }
    if (-not (Test-Path -LiteralPath $cabPath -PathType Leaf)) {
        throw "MSCatalogLTS completed but expected CAB '$cabPath' was not found."
    }

    $advertisedSha1 = if (-not [string]::IsNullOrWhiteSpace([string]$link.SHA1)) {
        [BitConverter]::ToString([Convert]::FromBase64String([string]$link.SHA1)).Replace('-', '')
    }
    else {
        ''
    }
    $actualSha1 = (Get-FileHash -LiteralPath $cabPath -Algorithm SHA1).Hash
    $cabSha256 = (Get-FileHash -LiteralPath $cabPath -Algorithm SHA256).Hash
    if (-not [string]::IsNullOrWhiteSpace($advertisedSha1) -and $actualSha1 -ne $advertisedSha1) {
        throw "SHA-1 mismatch for '$cabPath'. Expected '$advertisedSha1', actual '$actualSha1'."
    }

    $packageExtractRoot = Join-Path $extractedRoot ("{0}-{1}" -f $payloadId, $cabSha256.Substring(0, 12).ToLowerInvariant())
    $completionPath = "$packageExtractRoot.complete.json"
    New-Item -ItemType Directory -Path $packageExtractRoot -Force | Out-Null
    $completion = if (Test-Path -LiteralPath $completionPath -PathType Leaf) {
        Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json
    }
    else {
        $null
    }
    $extractionReused = $null -ne $completion -and $completion.CabSHA256 -eq $cabSha256
    if (-not $extractionReused) {
        $expandOutput = & "$env:SystemRoot\System32\expand.exe" -F:* $cabPath $packageExtractRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "expand.exe failed for '$cabPath': $($expandOutput -join ' ')"
        }
        [pscustomobject]@{
            CabSHA256     = $cabSha256
            CompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $completionPath -Encoding UTF8
    }

    $files = @(Get-ChildItem -LiteralPath $packageExtractRoot -File -Recurse)
    $infReports = [System.Collections.Generic.List[object]]::new()
    foreach ($infFile in @($files | Where-Object Extension -eq '.inf')) {
        $parsedInf = ConvertFrom-InfDriverFile -Path $infFile.FullName
        $targetMatchRows = [System.Collections.Generic.List[object]]::new()
        foreach ($infMatch in @($parsedInf.HardwareIds)) {
            $deviceIdPosition = [array]::IndexOf([string[]]$local.Device.HardwareIds, [string]$infMatch.HardwareId)
            if ($deviceIdPosition -lt 0) {
                continue
            }
            $infIdPosition = Get-DriverComparisonInfIdPosition -ModelLine ([string]$infMatch.Line) -HardwareId ([string]$infMatch.HardwareId)
            $featureScore = Get-DriverComparisonInfFeatureScore -InfPath $infFile.FullName -InstallSection ([string]$infMatch.InstallSection)
            $identifierScore = if ($infIdPosition -eq 0) { $deviceIdPosition } else { 0x1000 + $deviceIdPosition + (0x100 * [Math]::Max(0, $infIdPosition)) }
            $rankBody = '00{0:X2}{1:X4}' -f $featureScore.Value, $identifierScore
            $targetMatchRows.Add([pscustomobject]@{
                    HardwareId             = [string]$infMatch.HardwareId
                    MatchKind              = if ($infIdPosition -eq 0) { 'DeviceHardwareIdToInfHardwareId' } else { 'DeviceHardwareIdToInfCompatibleId' }
                    DeviceIdPosition       = $deviceIdPosition
                    InfIdPosition          = $infIdPosition
                    InstallSection         = [string]$infMatch.InstallSection
                    ModelSection           = [string]$infMatch.ModelSection
                    FeatureScore           = ('0x{0:X2}' -f $featureScore.Value)
                    FeatureScoreSource     = $featureScore.Source
                    IdentifierScore        = ('0x{0:X4}' -f $identifierScore)
                    ComputedRankBody       = $rankBody
                    ComputedRankConfidence = 'StrongInferenceNotWindowsSelectionEvidence'
                })
        }

        $candidateDriverVer = ConvertFrom-DriverComparisonDriverVer -DriverVer ([string]$parsedInf.Metadata.DriverVer)
        $activeDriverVer = [pscustomobject]@{
            Date    = if ([string]::IsNullOrWhiteSpace([string]$local.ActiveDriver.Date)) { $null } else { [datetime]::ParseExact($local.ActiveDriver.Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
            Version = [string]$local.ActiveDriver.Version
        }
        $infReports.Add([pscustomobject]@{
                Name               = $infFile.Name
                Path               = $infFile.FullName
                SHA256             = (Get-FileHash -LiteralPath $infFile.FullName -Algorithm SHA256).Hash
                Provider           = [string]$parsedInf.Metadata.Provider
                Class              = [string]$parsedInf.Metadata.Class
                DriverVer          = [string]$parsedInf.Metadata.DriverVer
                DriverDate         = if ($null -eq $candidateDriverVer.Date) { '' } else { $candidateDriverVer.Date.ToString('yyyy-MM-dd') }
                DriverVersion      = $candidateDriverVer.Version
                CatalogFile        = [string]$parsedInf.Metadata.CatalogFile
                HardwareIdCount    = @($parsedInf.HardwareIds).Count
                TargetMatches      = @($targetMatchRows)
                ActiveComparison   = Get-DriverComparisonRelation -Candidate $candidateDriverVer -Active $activeDriverVer
            })
    }

    $catalogSignatures = @(
        foreach ($catFile in @($files | Where-Object Extension -eq '.cat')) {
            $signature = Get-AuthenticodeSignature -LiteralPath $catFile.FullName
            [pscustomobject]@{
                Name      = $catFile.Name
                SHA256    = (Get-FileHash -LiteralPath $catFile.FullName -Algorithm SHA256).Hash
                Status    = $signature.Status.ToString()
                Signer    = [string]$signature.SignerCertificate.Subject
                Issuer    = [string]$signature.SignerCertificate.Issuer
                NotAfter  = if ($null -eq $signature.SignerCertificate) { '' } else { $signature.SignerCertificate.NotAfter.ToString('o') }
            }
        }
    )
    $driverBinaries = @(
        foreach ($sysFile in @($files | Where-Object Extension -eq '.sys')) {
            $signature = Get-AuthenticodeSignature -LiteralPath $sysFile.FullName
            [pscustomobject]@{
                Name           = $sysFile.Name
                Length         = $sysFile.Length
                FileVersion    = [string]$sysFile.VersionInfo.FileVersion
                ProductVersion = [string]$sysFile.VersionInfo.ProductVersion
                SHA256         = (Get-FileHash -LiteralPath $sysFile.FullName -Algorithm SHA256).Hash
                Signature      = $signature.Status.ToString()
            }
        }
    )

    $catalogRow = @($catalogRows | Where-Object { $_.Guid -eq $catalogGuid } | Select-Object -First 1)
    $cabSignature = Get-AuthenticodeSignature -LiteralPath $cabPath
    $packages.Add([pscustomobject]@{
            Source             = 'CatalogPackageInspection'
            Confidence         = 'ObservedPackageContent'
            CatalogGuid        = $catalogGuid
            CatalogRow         = if ($catalogRow.Count -eq 0) { $null } else { [pscustomobject]@{
                    Title          = [string]$catalogRow[0].Title
                    Products       = [string]$catalogRow[0].Products
                    Classification = [string]$catalogRow[0].Classification
                    LastUpdated    = if ($catalogRow[0].LastUpdated -is [datetime]) { $catalogRow[0].LastUpdated.ToString('o') } else { [string]$catalogRow[0].LastUpdated }
                    Version        = [string]$catalogRow[0].Version
                    Size           = [string]$catalogRow[0].Size
                }
            }
            DownloadUrl         = $url
            CabPath             = $cabPath
            CabLength           = (Get-Item -LiteralPath $cabPath).Length
            AdvertisedSHA1      = $advertisedSha1
            ActualSHA1          = $actualSha1
            SHA1Verified        = [string]::IsNullOrWhiteSpace($advertisedSha1) -or $actualSha1 -eq $advertisedSha1
            SHA256              = $cabSha256
            CabSignatureStatus  = $cabSignature.Status.ToString()
            ExtractedRoot       = $packageExtractRoot
            ExtractionReused    = $extractionReused
            FileCount           = $files.Count
            InfCount            = @($files | Where-Object Extension -eq '.inf').Count
            CatalogCount        = @($files | Where-Object Extension -eq '.cat').Count
            DriverBinaryCount   = @($files | Where-Object Extension -eq '.sys').Count
            Infs                = @($infReports)
            CatalogSignatures   = @($catalogSignatures)
            DriverBinaries      = @($driverBinaries)
        })
}

$guardAfter = [pscustomobject]@{
    PublishedInfCount      = @(Get-ChildItem "$env:windir\INF\oem*.inf" -File).Count
    DriverStoreFolderCount = @(Get-ChildItem "$env:windir\System32\DriverStore\FileRepository" -Directory).Count
    SetupApiLength         = (Get-Item "$env:windir\INF\setupapi.dev.log").Length
}
$guardUnchanged = $guardBefore.PublishedInfCount -eq $guardAfter.PublishedInfCount -and
    $guardBefore.DriverStoreFolderCount -eq $guardAfter.DriverStoreFolderCount -and
    $guardBefore.SetupApiLength -eq $guardAfter.SetupApiLength
if (-not $guardUnchanged) {
    throw 'Catalog package inspection changed DriverStore, published INF, or SetupAPI state.'
}

$manifest = [pscustomobject]@{
    SchemaVersion  = 1
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Source          = 'CatalogPackageInspection'
    Confidence      = 'ObservedPackageContent'
    Safety          = [pscustomobject]@{
        Mode               = 'DownloadExtractInspectOnly'
        DownloadsPackages  = $true
        StagesDrivers      = $false
        InstallsDrivers    = $false
        RemovesDrivers     = $false
        ChangesDeviceState = $false
    }
    Target          = $local.Device
    ActiveDriver    = $local.ActiveDriver
    ModulePath      = $modulePath
    InspectionRoot  = $InspectionDirectory
    MutationGuard   = [pscustomobject]@{ Before = $guardBefore; After = $guardAfter; Unchanged = $guardUnchanged }
    Packages        = @($packages)
}
$manifestPath = Join-Path $InspectionDirectory 'inspection-manifest.json'
$manifest | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $manifestPath -Force

if ($AsJson) {
    $manifest | ConvertTo-Json -Depth 32
    return
}

Write-Host 'Catalog Driver Package Inspection' -ForegroundColor Cyan
Write-Host '---------------------------------' -ForegroundColor Cyan
Write-Host ("Device   : {0}" -f $manifest.Target.FriendlyName)
Write-Host ("Active   : {0} / {1}" -f $manifest.ActiveDriver.Date, $manifest.ActiveDriver.Version)
foreach ($package in @($manifest.Packages)) {
    $matchCount = @($package.Infs | ForEach-Object { $_.TargetMatches }).Count
    Write-Host ("Package  : {0} | SHA1 {1} | signature {2} | exact matches {3}" -f $package.CatalogGuid, $package.SHA1Verified, $package.CabSignatureStatus, $matchCount)
    foreach ($inf in @($package.Infs)) {
        Write-Host ("  INF    : {0} | {1} | date {2} vs active {3}" -f $inf.Name, $inf.DriverVer, $inf.ActiveComparison.DateRelation, $inf.ActiveComparison.VersionRelation)
    }
}
Write-Host ("Guard    : unchanged = {0}" -f $manifest.MutationGuard.Unchanged) -ForegroundColor Green
Write-Host ("Manifest : {0}" -f $manifestPath) -ForegroundColor DarkGray
