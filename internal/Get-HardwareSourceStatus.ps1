[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\hardware-sources.json'),

    [string]$SourceRoot = '',

    [switch]$IncludeDeferred,

    [switch]$CheckRemote,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Expand-SourcePath {
    param(
        [AllowEmptyString()]
        [string]$PathValue,
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ''
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return $expanded
    }

    return (Join-Path $RootPath $expanded)
}

function Get-AutoSourceRoot {
    param(
        [object]$Manifest
    )

    $candidateRoots = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string]$Manifest.SourceRootHint)) {
        $candidateRoots.Add((Expand-SourcePath -PathValue ([string]$Manifest.SourceRootHint) -RootPath (Get-Location).ProviderPath))
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidateRoots.Add((Join-Path (Join-Path $env:USERPROFILE 'scripts') 'DeviceCheck\source'))
    }

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptsRoot = Split-Path -Parent $repoRoot
    if (-not [string]::IsNullOrWhiteSpace($scriptsRoot)) {
        $candidateRoots.Add((Join-Path $scriptsRoot 'DeviceCheck\source'))
    }

    foreach ($candidateRoot in $candidateRoots) {
        if (-not [string]::IsNullOrWhiteSpace($candidateRoot) -and (Test-Path -LiteralPath $candidateRoot -PathType Container)) {
            return (Resolve-Path -LiteralPath $candidateRoot).ProviderPath
        }
    }

    if ($candidateRoots.Count -gt 0) {
        return $candidateRoots[0]
    }

    return (Get-Location).ProviderPath
}

function Get-ExistingSourcePath {
    param(
        [object]$Source,
        [string]$RootPath
    )

    $candidatePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($hint in @($Source.LocalPathHints)) {
        $expanded = Expand-SourcePath -PathValue ([string]$hint) -RootPath $RootPath
        if (-not [string]::IsNullOrWhiteSpace($expanded)) {
            $candidatePaths.Add($expanded)
            if ([System.IO.Path]::IsPathRooted($expanded)) {
                $leafName = Split-Path -Leaf $expanded
                if (-not [string]::IsNullOrWhiteSpace($leafName)) {
                    $candidatePaths.Add((Join-Path $RootPath $leafName))
                }
            }
        }
    }

    if ($candidatePaths.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$Source.RepoUrl)) {
        $candidatePaths.Add((Join-Path $RootPath ([string]$Source.Id)))
    }

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath -PathType Container) {
            return (Resolve-Path -LiteralPath $candidatePath).ProviderPath
        }
    }

    return ''
}

function Test-GitRemoteReachable {
    param(
        [AllowEmptyString()]
        [string]$RepoUrl
    )

    if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
        return 'N/A'
    }

    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        return 'GitMissing'
    }

    $output = & git ls-remote --heads $RepoUrl 2>$null
    if ($LASTEXITCODE -eq 0 -and $null -ne $output) {
        return 'Reachable'
    }

    return 'Unavailable'
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Hardware source manifest not found: $ManifestPath"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$root = if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    Get-AutoSourceRoot -Manifest $manifest
}
else {
    Expand-SourcePath -PathValue $SourceRoot -RootPath (Get-Location).ProviderPath
}
$results = [System.Collections.Generic.List[object]]::new()

foreach ($source in @($manifest.Sources)) {
    $decision = [string]$source.Decision
    if (-not $IncludeDeferred -and $decision -in @('Defer', 'ReferenceOnly')) {
        continue
    }

    $localPath = Get-ExistingSourcePath -Source $source -RootPath $root
    $localStatus = if ([string]::IsNullOrWhiteSpace($localPath)) { 'Missing' } else { 'Present' }
    if ([string]::IsNullOrWhiteSpace([string]$source.RepoUrl) -and @($source.LocalPathHints).Count -eq 0) {
        $localStatus = 'N/A'
    }

    $remoteStatus = 'NotChecked'
    if ($CheckRemote) {
        $remoteStatus = Test-GitRemoteReachable -RepoUrl ([string]$source.RepoUrl)
    }

    $action = switch ($decision) {
        'AdoptedNow' {
            if ($localStatus -eq 'Present') { 'Ready' } else { 'Need local source clone' }
            break
        }
        'TrackNext' { 'Review/download format before importer' ; break }
        'CloneWhenFeatureStarts' {
            if ($localStatus -eq 'Present') { 'Ready for feature study' } else { 'Clone only when feature work starts' }
            break
        }
        'StudyBeforeClone' { 'Study scope/license before clone' ; break }
        'CoveredByHwdata' { 'No clone while hwdata covers it' ; break }
        'ReferenceOnly' { 'Reference link only' ; break }
        'Defer' { 'Deferred' ; break }
        default { 'Review' ; break }
    }

    $results.Add([pscustomobject]@{
        Priority = [int]$source.Priority
        Id = [string]$source.Id
        Name = [string]$source.Name
        Kind = [string]$source.Kind
        Decision = $decision
        LocalStatus = $localStatus
        LocalPath = $localPath
        RemoteStatus = $remoteStatus
        Action = $action
        Url = [string]$source.Url
    })
}

$orderedResults = @($results | Sort-Object Priority, Id)

if ($AsJson) {
    [ordered]@{
        SchemaVersion = [int]$manifest.SchemaVersion
        SourceRoot = $root
        Count = $orderedResults.Count
        Sources = @($orderedResults)
    } | ConvertTo-Json -Depth 8
    return
}

$orderedResults | Format-Table Priority, Id, Decision, LocalStatus, Action -AutoSize
