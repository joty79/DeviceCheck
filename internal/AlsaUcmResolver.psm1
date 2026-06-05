Set-StrictMode -Version Latest

function Get-AlsaUcmCacheRoot {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return (Join-Path $repoRoot 'data\hwdb')
}

function Import-AlsaUcmUsbAudioProfileCache {
    param(
        [string] $CacheRoot = (Get-AlsaUcmCacheRoot)
    )

    $cachePath = Join-Path $CacheRoot 'normalized\alsa-ucm-usb-audio.json'
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        throw "Missing ALSA UCM profile cache file: $cachePath. Run internal\Update-AlsaUcmProfiles.ps1 first."
    }

    return (Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json)
}

function ConvertTo-AlsaUcmUsbId {
    param(
        [AllowEmptyString()]
        [string] $HardwareId
    )

    if ([string]::IsNullOrWhiteSpace($HardwareId)) {
        return $null
    }

    $normalized = $HardwareId.Trim().Trim('"').ToUpperInvariant()
    $idMatch = [regex]::Match($normalized, '^(?:USB|HID)\\.*?VID_(?<vendor>[0-9A-F]{4}).*?PID_(?<product>[0-9A-F]{4})')
    if (-not $idMatch.Success) {
        return $null
    }

    [pscustomobject]@{
        VendorId = $idMatch.Groups['vendor'].Value
        ProductId = $idMatch.Groups['product'].Value
        UsbId = ('{0}:{1}' -f $idMatch.Groups['vendor'].Value, $idMatch.Groups['product'].Value).ToLowerInvariant()
    }
}

function Test-AlsaUcmRuleMatch {
    param(
        [Parameter(Mandatory)]
        [string] $UsbId,
        [Parameter(Mandatory)]
        [object] $Rule
    )

    $pattern = [string]$Rule.IdPattern
    if ([string]::IsNullOrWhiteSpace($pattern)) {
        return $false
    }

    if ([string]$Rule.MatchType -eq 'StringMatch') {
        return [string]::Equals($UsbId, $pattern.ToLowerInvariant(), [System.StringComparison]::OrdinalIgnoreCase)
    }

    try {
        return [regex]::IsMatch($UsbId, ('^(?:{0})$' -f $pattern), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    catch {
        return $false
    }
}

function Resolve-AlsaUcmUsbAudioProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string[]] $HardwareId,
        [string] $CacheRoot = (Get-AlsaUcmCacheRoot),
        [object] $Cache
    )

    begin {
        if ($null -eq $Cache) {
            $Cache = Import-AlsaUcmUsbAudioProfileCache -CacheRoot $CacheRoot
        }
    }

    process {
        foreach ($hardwareIdValue in @($HardwareId)) {
            $usbIdentity = ConvertTo-AlsaUcmUsbId -HardwareId $hardwareIdValue
            if ($null -eq $usbIdentity) {
                continue
            }

            foreach ($rule in @($Cache.Rules)) {
                if (-not (Test-AlsaUcmRuleMatch -UsbId $usbIdentity.UsbId -Rule $rule)) {
                    continue
                }

                $comment = @($rule.CommentedUsbIds | Where-Object {
                        [string]::Equals([string]$_.UsbId, $usbIdentity.UsbId, [System.StringComparison]::OrdinalIgnoreCase)
                    } | Select-Object -First 1)

                [pscustomobject]@{
                    Input = $hardwareIdValue
                    UsbId = $usbIdentity.UsbId
                    VendorId = $usbIdentity.VendorId
                    ProductId = $usbIdentity.ProductId
                    ProfileName = [string]$rule.ProfileName
                    RuleName = [string]$rule.Name
                    MatchType = [string]$rule.MatchType
                    IdPattern = [string]$rule.IdPattern
                    EvidenceLabel = 'OPEN-SOURCE-PROFILE'
                    SourceId = [string]$Cache.Source.SourceId
                    SourceName = [string]$Cache.Source.Name
                    SourceVersion = [string]$Cache.Source.Version
                    SourceCommit = [string]$Cache.Source.Commit
                    SourcePath = [string]$Cache.Source.UpstreamPath
                    License = [string]$Cache.Source.License
                    CommentLabel = if ($comment.Count -gt 0) { [string]$comment[0].Label } else { '' }
                    Notes = @('ALSA UCM profile evidence is an open-source audio profile match, not a usb.ids product lookup.')
                }
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Import-AlsaUcmUsbAudioProfileCache',
    'ConvertTo-AlsaUcmUsbId',
    'Resolve-AlsaUcmUsbAudioProfile'
)
