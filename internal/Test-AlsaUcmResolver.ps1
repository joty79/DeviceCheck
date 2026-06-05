[CmdletBinding()]
param(
    [string] $CacheRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data\hwdb'),
    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AlsaUcmResolver.psm1') -Force

$updateScript = Join-Path $PSScriptRoot 'Update-AlsaUcmProfiles.ps1'
& $updateScript -OutputRoot $CacheRoot > $null

$assertions = [System.Collections.Generic.List[object]]::new()
function Add-AlsaAssertion {
    param(
        [System.Collections.Generic.List[object]] $Assertions,
        [string] $Name,
        [bool] $Passed,
        [AllowEmptyString()][string] $Expected,
        [AllowEmptyString()][string] $Actual
    )

    $Assertions.Add([pscustomobject]@{
            Name = $Name
            Passed = $Passed
            Expected = $Expected
            Actual = $Actual
        }) | Out-Null
}

$cache = Import-AlsaUcmUsbAudioProfileCache -CacheRoot $CacheRoot
$match = @(Resolve-AlsaUcmUsbAudioProfile -HardwareId 'USB\VID_0DB0&PID_CD0E&REV_0005&MI_00' -Cache $cache | Select-Object -First 1)

Add-AlsaAssertion -Assertions $assertions -Name 'ALSA UCM cache has profile rules' `
    -Passed (@($cache.Rules).Count -gt 0) `
    -Expected '> 0' `
    -Actual ([string]@($cache.Rules).Count)
Add-AlsaAssertion -Assertions $assertions -Name '0db0:cd0e maps to Realtek/ALC4080' `
    -Passed (($match.Count -gt 0) -and ($match[0].ProfileName -eq 'Realtek/ALC4080')) `
    -Expected 'Realtek/ALC4080' `
    -Actual ($(if ($match.Count -gt 0) { [string]$match[0].ProfileName } else { '<no match>' }))
Add-AlsaAssertion -Assertions $assertions -Name '0db0:cd0e remains open-source profile evidence' `
    -Passed (($match.Count -gt 0) -and ($match[0].EvidenceLabel -eq 'OPEN-SOURCE-PROFILE')) `
    -Expected 'OPEN-SOURCE-PROFILE' `
    -Actual ($(if ($match.Count -gt 0) { [string]$match[0].EvidenceLabel } else { '<no match>' }))
Add-AlsaAssertion -Assertions $assertions -Name 'MSI X870 Tomahawk comment is preserved when available' `
    -Passed (($match.Count -gt 0) -and ($match[0].CommentLabel -like '*X870*Tomahawk*')) `
    -Expected 'contains X870 Tomahawk' `
    -Actual ($(if ($match.Count -gt 0) { [string]$match[0].CommentLabel } else { '<no match>' }))

$failed = @($assertions | Where-Object { -not $_.Passed })
$summary = [pscustomobject]@{
    Passed = ($failed.Count -eq 0)
    Count = $assertions.Count
    Assertions = @($assertions)
}

if ($AsJson) {
    $summary | ConvertTo-Json -Depth 8
}
else {
    $status = if ($summary.Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] ALSA UCM resolver assertions: {1}" -f $status, $summary.Count)
    foreach ($assertion in $assertions) {
        $assertionStatus = if ($assertion.Passed) { 'PASS' } else { 'FAIL' }
        Write-Host ("  [{0}] {1}" -f $assertionStatus, $assertion.Name)
        if (-not $assertion.Passed) {
            Write-Host ("       expected: {0}" -f $assertion.Expected)
            Write-Host ("       actual  : {0}" -f $assertion.Actual)
        }
    }
}

if (-not $summary.Passed) {
    exit 1
}
