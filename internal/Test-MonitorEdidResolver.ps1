[CmdletBinding()]
param(
    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MonitorEdidResolver.psm1') -Force

function Add-EdidAssertion {
    param(
        [System.Collections.Generic.List[object]] $Assertions,
        [string] $Name,
        [bool] $Passed,
        [AllowEmptyString()][string] $Expected,
        [AllowEmptyString()][string] $Actual
    )

    $Assertions.Add([pscustomobject]@{
            Name     = $Name
            Passed   = $Passed
            Expected = $Expected
            Actual   = $Actual
        }) | Out-Null
}

function New-TestEdid {
    $edid = [byte[]]::new(128)
    $header = @(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00)
    for ($i = 0; $i -lt $header.Count; $i++) {
        $edid[$i] = [byte]$header[$i]
    }

    # GSM = LG Electronics as a standard EISA/PNP monitor manufacturer code.
    $edid[8] = 0x1E
    $edid[9] = 0x6D
    $edid[10] = 0xD3
    $edid[11] = 0x5B
    $edid[16] = 12
    $edid[17] = 35
    $edid[18] = 1
    $edid[19] = 4
    $edid[20] = 0xA5
    $edid[21] = 60
    $edid[22] = 34
    $edid[23] = 120

    foreach ($entry in @(
            @{ Offset = 54; Type = 0xFC; Text = "LG TEST`n     " },
            @{ Offset = 72; Type = 0xFF; Text = "SER123`n      " }
        )) {
        $descriptor = [byte[]]::new(18)
        $descriptor[3] = [byte]$entry.Type
        $textBytes = [System.Text.Encoding]::ASCII.GetBytes([string]$entry.Text)
        for ($i = 0; $i -lt [Math]::Min(13, $textBytes.Count); $i++) {
            $descriptor[$i + 5] = $textBytes[$i]
        }
        $descriptor.CopyTo($edid, [int]$entry.Offset)
    }

    $sum = 0
    for ($i = 0; $i -lt 127; $i++) {
        $sum += [int]$edid[$i]
    }
    $edid[127] = [byte]((256 - ($sum % 256)) % 256)
    return $edid
}

$assertions = [System.Collections.Generic.List[object]]::new()
$decoded = ConvertFrom-EdidBytes -Edid (New-TestEdid)

Add-EdidAssertion -Assertions $assertions -Name 'EDID header and checksum validate' `
    -Passed ($decoded.IsValid -and $decoded.HeaderValid -and $decoded.ChecksumValid) `
    -Expected 'valid' `
    -Actual ("IsValid={0}; Header={1}; Checksum={2}" -f $decoded.IsValid, $decoded.HeaderValid, $decoded.ChecksumValid)
Add-EdidAssertion -Assertions $assertions -Name 'EDID manufacturer code decodes as GSM' `
    -Passed ($decoded.ManufacturerId -eq 'GSM') `
    -Expected 'GSM' `
    -Actual ([string]$decoded.ManufacturerId)
Add-EdidAssertion -Assertions $assertions -Name 'EDID product code preserves little-endian product' `
    -Passed ($decoded.ProductCode -eq '5BD3') `
    -Expected '5BD3' `
    -Actual ([string]$decoded.ProductCode)
Add-EdidAssertion -Assertions $assertions -Name 'EDID monitor name descriptor is decoded' `
    -Passed ($decoded.MonitorName -eq 'LG TEST') `
    -Expected 'LG TEST' `
    -Actual ([string]$decoded.MonitorName)
Add-EdidAssertion -Assertions $assertions -Name 'EDID manufacture year is decoded' `
    -Passed ($decoded.ManufactureYear -eq 2025) `
    -Expected '2025' `
    -Actual ([string]$decoded.ManufactureYear)

$invalid = ConvertFrom-EdidBytes -Edid ([byte[]](1..128))
Add-EdidAssertion -Assertions $assertions -Name 'Invalid EDID header is rejected' `
    -Passed (-not $invalid.IsValid -and -not $invalid.HeaderValid) `
    -Expected 'invalid header' `
    -Actual ("IsValid={0}; Header={1}" -f $invalid.IsValid, $invalid.HeaderValid)

$failed = @($assertions | Where-Object { -not $_.Passed })
$summary = [pscustomobject]@{
    Passed     = ($failed.Count -eq 0)
    Count      = $assertions.Count
    Assertions = @($assertions)
}

if ($AsJson) {
    $summary | ConvertTo-Json -Depth 8
}
else {
    $status = if ($summary.Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] MonitorEdidResolver assertions: {1}" -f $status, $summary.Count)
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
