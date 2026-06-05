[CmdletBinding()]
param(
    [string] $SourceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'source\alsa-ucm-conf'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data\hwdb')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredTextFile {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required ALSA UCM source file not found: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw
}

function Get-UcmMacroValue {
    param(
        [Parameter(Mandatory)]
        [string] $Text,
        [Parameter(Mandatory)]
        [string] $Name
    )

    $blockPattern = '(?s)(?:^|\s){0}\s+"(?<value>[^"]+)"' -f [regex]::Escape($Name)
    $blockMatch = [regex]::Match($Text, $blockPattern)
    if ($blockMatch.Success) {
        return $blockMatch.Groups['value'].Value
    }

    $linePattern = '(?s)\b{0}=''{1}''' -f [regex]::Escape($Name), '(?<value>[^'']+)'
    $lineMatch = [regex]::Match($Text, $linePattern)
    if ($lineMatch.Success) {
        return $lineMatch.Groups['value'].Value
    }

    return ''
}

function Get-UcmCommentedUsbIds {
    param(
        [AllowEmptyString()]
        [string] $Text
    )

    $commented = [System.Collections.Generic.List[object]]::new()
    foreach ($commentMatch in [regex]::Matches($Text, '#\s*(?<id>[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4})\s*(?<label>.*?)(?:\r?\n|$)')) {
        $commented.Add([pscustomobject]@{
                UsbId = $commentMatch.Groups['id'].Value.ToLowerInvariant()
                Label = $commentMatch.Groups['label'].Value.Trim()
            }) | Out-Null
    }

    return @($commented)
}

function ConvertTo-UcmRule {
    param(
        [System.Text.RegularExpressions.Match] $MacroMatch
    )

    $macroName = $MacroMatch.Groups['name'].Value
    $matchType = $MacroMatch.Groups['type'].Value
    $body = if ($MacroMatch.Groups['block'].Success) {
        $MacroMatch.Groups['block'].Value
    }
    else {
        $MacroMatch.Groups['line'].Value
    }

    $id = Get-UcmMacroValue -Text $body -Name 'Id'
    $profile = Get-UcmMacroValue -Text $body -Name 'Profile'
    $remap = Get-UcmMacroValue -Text $body -Name 'Remap'

    if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($profile)) {
        return $null
    }

    [pscustomobject]@{
        Name = $macroName
        MatchType = $matchType
        IdPattern = $id
        ProfileName = $profile
        MixerRemap = $remap
        CommentedUsbIds = @(Get-UcmCommentedUsbIds -Text $body)
    }
}

$sourcePath = Join-Path $SourceRoot 'USB-Audio.conf'
$sourceJsonPath = Join-Path $SourceRoot 'SOURCE.json'
$versionPath = Join-Path $SourceRoot 'VERSION'
$sourceText = Get-RequiredTextFile -Path $sourcePath
$versionText = if (Test-Path -LiteralPath $versionPath -PathType Leaf) { (Get-Content -LiteralPath $versionPath -Raw).Trim() } else { '' }
$sourceManifest = if (Test-Path -LiteralPath $sourceJsonPath -PathType Leaf) {
    Get-Content -LiteralPath $sourceJsonPath -Raw | ConvertFrom-Json
}
else {
    $null
}

$rules = [System.Collections.Generic.List[object]]::new()
$macroPattern = '(?s)Macro\.(?<name>[A-Za-z0-9._-]+)\.(?<type>RegexMatch|StringMatch)\s*(?:\{(?<block>.*?)\}|(?<line>"[^"\r\n]*(?:''[^'']*''[^"\r\n]*)*"))'
foreach ($macroMatch in [regex]::Matches($sourceText, $macroPattern)) {
    $rule = ConvertTo-UcmRule -MacroMatch $macroMatch
    if ($null -ne $rule) {
        $rules.Add($rule) | Out-Null
    }
}

$normalizedRoot = Join-Path $OutputRoot 'normalized'
if (-not (Test-Path -LiteralPath $normalizedRoot -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $normalizedRoot -Force
}

$sourceItem = Get-Item -LiteralPath $sourcePath
$sourceHash = Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256
$payload = [ordered]@{
    SchemaVersion = 1
    Database = 'alsa-ucm-usb-audio'
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Source = [ordered]@{
        SourceId = 'alsa-ucm-conf'
        Name = 'ALSA Use Case Manager USB-Audio profiles'
        Repository = 'https://github.com/alsa-project/alsa-ucm-conf'
        Commit = if ($null -ne $sourceManifest) { [string]$sourceManifest.Commit } else { '' }
        Version = $versionText
        FileName = 'USB-Audio.conf'
        Path = $sourceItem.FullName
        UpstreamPath = 'ucm2/USB-Audio/USB-Audio.conf'
        License = 'BSD-3-Clause'
        Sha256 = $sourceHash.Hash
    }
    Counts = [ordered]@{
        Rules = $rules.Count
        CommentedUsbIds = @($rules | ForEach-Object { @($_.CommentedUsbIds).Count } | Measure-Object -Sum).Sum
    }
    Rules = @($rules)
}

$outputPath = Join-Path $normalizedRoot 'alsa-ucm-usb-audio.json'
$payload | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $outputPath -Encoding UTF8

[pscustomobject]@{
    OutputPath = $outputPath
    Rules = $rules.Count
    Version = $versionText
    Commit = $payload.Source.Commit
}
