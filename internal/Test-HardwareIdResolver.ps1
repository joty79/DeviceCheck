[CmdletBinding()]
param(
    [string] $CacheRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data\hwdb'),
    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'HardwareIdResolver.psm1') -Force

function Add-ResolverAssertion {
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

$cache = Import-HardwareIdDatabaseCache -CacheRoot $CacheRoot
$assertions = [System.Collections.Generic.List[object]]::new()

$usbDevice = Resolve-HardwareId -HardwareId 'USB\VID_0DB0&PID_CD0E&REV_0005&MI_00' -Cache $cache
Add-ResolverAssertion -Assertions $assertions -Name 'USB VID/PID resolves vendor-only' `
    -Passed ($usbDevice.Confidence -eq 'VENDOR-ONLY') `
    -Expected 'VENDOR-ONLY' `
    -Actual ([string]$usbDevice.Confidence)
Add-ResolverAssertion -Assertions $assertions -Name 'USB REV is parsed before MI' `
    -Passed ($usbDevice.Fields.Revision -eq '0005') `
    -Expected '0005' `
    -Actual ([string]$usbDevice.Fields.Revision)
Add-ResolverAssertion -Assertions $assertions -Name 'USB MI is parsed after REV' `
    -Passed ($usbDevice.Fields.InterfaceId -eq '00') `
    -Expected '00' `
    -Actual ([string]$usbDevice.Fields.InterfaceId)

$usbClass = Resolve-HardwareId -HardwareId 'USB\Class_01&SubClass_00&Prot_20' -Cache $cache
Add-ResolverAssertion -Assertions $assertions -Name 'USB compatible class resolves as Audio' `
    -Passed (($usbClass.IdType -eq 'USB_CLASS') -and ($usbClass.Lookup.ClassName -eq 'Audio')) `
    -Expected 'USB_CLASS / Audio' `
    -Actual ("{0} / {1}" -f $usbClass.IdType, $usbClass.Lookup.ClassName)
Add-ResolverAssertion -Assertions $assertions -Name 'USB compatible protocol remains generic class evidence' `
    -Passed ($usbClass.Lookup.ProtocolName -eq 'USB Audio 2.0-style class match') `
    -Expected 'USB Audio 2.0-style class match' `
    -Actual ([string]$usbClass.Lookup.ProtocolName)

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
    Write-Host ("[{0}] HardwareIdResolver assertions: {1}" -f $status, $summary.Count)
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
