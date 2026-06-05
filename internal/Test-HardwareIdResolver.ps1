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

$scsiStructured = Resolve-HardwareId -HardwareId 'SCSI\DISK&VEN_NVME&PROD_KINGSTON_SKC3000' -Cache $cache
Add-ResolverAssertion -Assertions $assertions -Name 'SCSI structured disk ID resolves as storage identity' `
    -Passed (($scsiStructured.Bus -eq 'SCSI') -and ($scsiStructured.Confidence -eq 'PARSED-STORAGE')) `
    -Expected 'SCSI / PARSED-STORAGE' `
    -Actual ("{0} / {1}" -f $scsiStructured.Bus, $scsiStructured.Confidence)
Add-ResolverAssertion -Assertions $assertions -Name 'SCSI structured disk product is parsed' `
    -Passed ($scsiStructured.Lookup.ProductName -eq 'KINGSTON SKC3000') `
    -Expected 'KINGSTON SKC3000' `
    -Actual ([string]$scsiStructured.Lookup.ProductName)

$scsiCompact = Resolve-HardwareId -HardwareId 'SCSI\DiskNVMe____KINGSTON_SKC3000D2048GEIFK31.7' -Cache $cache
Add-ResolverAssertion -Assertions $assertions -Name 'SCSI compact disk ID resolves before PNP fallback' `
    -Passed (($scsiCompact.Bus -eq 'SCSI') -and ($scsiCompact.IdType -eq 'SCSI_STORAGE_COMPACT')) `
    -Expected 'SCSI / SCSI_STORAGE_COMPACT' `
    -Actual ("{0} / {1}" -f $scsiCompact.Bus, $scsiCompact.IdType)

$hdAudioCodec = Resolve-HardwareId -HardwareId 'HDAUDIO\FUNC_01&VEN_10EC&DEV_0892&SUBSYS_10438698&REV_1003' -Cache $cache
Add-ResolverAssertion -Assertions $assertions -Name 'HDAUDIO codec ID resolves before PNP fallback' `
    -Passed (($hdAudioCodec.Bus -eq 'HDAUDIO') -and ($hdAudioCodec.IdType -eq 'HDAUDIO_CODEC')) `
    -Expected 'HDAUDIO / HDAUDIO_CODEC' `
    -Actual ("{0} / {1}" -f $hdAudioCodec.Bus, $hdAudioCodec.IdType)
Add-ResolverAssertion -Assertions $assertions -Name 'HDAUDIO codec vendor resolves through pci.ids vendor table' `
    -Passed (($hdAudioCodec.Fields.VendorId -eq '10EC') -and ($hdAudioCodec.Lookup.VendorName -like 'Realtek*')) `
    -Expected '10EC / Realtek*' `
    -Actual ("{0} / {1}" -f $hdAudioCodec.Fields.VendorId, $hdAudioCodec.Lookup.VendorName)
Add-ResolverAssertion -Assertions $assertions -Name 'HDAUDIO SUBSYS parses ASUS vendor before board id' `
    -Passed (($hdAudioCodec.Fields.SubvendorId -eq '1043') -and ($hdAudioCodec.Fields.SubdeviceId -eq '8698')) `
    -Expected '1043 / 8698' `
    -Actual ("{0} / {1}" -f $hdAudioCodec.Fields.SubvendorId, $hdAudioCodec.Fields.SubdeviceId)

$hdAudioCompatible = Resolve-HardwareId -HardwareId 'HDAUDIO\FUNC_01&CTLR_VEN_8086&CTLR_DEV_A170&VEN_10EC&DEV_0892&REV_1003' -Cache $cache
Add-ResolverAssertion -Assertions $assertions -Name 'HDAUDIO compatible ID preserves Intel controller tuple' `
    -Passed (($hdAudioCompatible.Fields.ControllerVendorId -eq '8086') -and ($hdAudioCompatible.Fields.ControllerDeviceId -eq 'A170')) `
    -Expected '8086 / A170' `
    -Actual ("{0} / {1}" -f $hdAudioCompatible.Fields.ControllerVendorId, $hdAudioCompatible.Fields.ControllerDeviceId)
Add-ResolverAssertion -Assertions $assertions -Name 'HDAUDIO compatible ID remains codec-level evidence' `
    -Passed ($hdAudioCompatible.Confidence -eq 'CODEC-ID') `
    -Expected 'CODEC-ID' `
    -Actual ([string]$hdAudioCompatible.Confidence)

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
