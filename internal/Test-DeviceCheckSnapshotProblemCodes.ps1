#requires -version 5.1
[CmdletBinding()]
param([string]$SnapshotPath = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Parser errors in $Path" }
    $definition = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
    if ($null -eq $definition) { throw "Missing function: $Name" }
    $bodyText = $definition.Body.Extent.Text
    Set-Item -Path "Function:script:$Name" -Value ([scriptblock]::Create($bodyText.Substring(1, $bodyText.Length - 2)))
}

function Assert-ProblemCode {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

. (Join-Path $PSScriptRoot 'DeviceCheck\04-UiTextFormatting.ps1')
. (Join-Path $PSScriptRoot 'DeviceCheck\05-InventoryAndSnapshots.ps1')
Import-TestFunction -Path (Join-Path $PSScriptRoot 'DeviceCheck\02-MachineAndTarget.ps1') -Name 'Get-DeviceManagerClassName'
Import-TestFunction -Path (Join-Path $PSScriptRoot 'DeviceCheck\07-TreeDetailsAndModels.ps1') -Name 'Get-DeviceProblemDescription'
Import-TestFunction -Path (Join-Path $PSScriptRoot 'Export-DeviceCheckEvidence.ps1') -Name 'New-CollectorScriptBlock'
$script:deviceManagerClassNames = @{}

# Isolate cache side effects; exercise the real inventory/category import path.
function Set-SnapshotEvidenceCache { param($Snapshot) }

$fixtureDevices = @(
    [pscustomobject]@{ InstanceId = 'ACPI\VPC2004\0'; ConfigManagerErrorCode = 'CM_PROB_FAILED_INSTALL'; Status = 'Error'; ProblemDescription = 'The drivers for this device are not installed. (Code 28).' }
    [pscustomobject]@{ InstanceId = 'TEST\DVD'; ConfigManagerErrorCode = 'CM_PROB_DISABLED_SERVICE'; Status = 'Error' }
    [pscustomobject]@{ InstanceId = 'TEST\HEALTHY'; ConfigManagerErrorCode = 'CM_PROB_NONE'; Status = 'OK' }
    [pscustomobject]@{ InstanceId = 'TEST\NUMERIC'; ConfigManagerErrorCode = '43'; Status = 'Error' }
    [pscustomobject]@{ InstanceId = 'TEST\LEGACY'; ConfigManagerErrorCode = 'CM_PROB_FAILED_START'; Status = 'Error'; ProblemDescription = 'This device cannot start. (Code 10)' }
    [pscustomobject]@{ InstanceId = 'TEST\MALFORMED'; ConfigManagerErrorCode = 'unreadable'; Status = 'Error' }
    [pscustomobject]@{ InstanceId = 'TEST\MISSING'; Status = 'Unknown' }
    [pscustomobject]@{ InstanceId = 'TEST\PROPERTY'; ConfigManagerErrorCode = 'unreadable'; Status = 'Error' }
)
$snapshot = [pscustomobject]@{ Devices = [pscustomobject]@{
    Present = $fixtureDevices
    Properties = [pscustomobject]@{ 'TEST\PROPERTY' = @([pscustomobject]@{ KeyName = 'DEVPKEY_Device_ProblemCode'; Data = 22 }) }
} }
$imported = @((Get-DeviceCategoriesFromSnapshot -Snapshot $snapshot) | ForEach-Object { $_.Devices })
$expectedCodes = @(28, 32, 0, 43, 10, -1, -1, 22)
for ($index = 0; $index -lt $fixtureDevices.Count; $index++) {
    $device = $imported | Where-Object InstanceId -eq $fixtureDevices[$index].InstanceId
    Assert-ProblemCode ($device.ConfigManagerErrorCode -eq $expectedCodes[$index]) "Wrong imported problem code for $($fixtureDevices[$index].InstanceId)."
    Assert-ProblemCode ($device.IsProblem -eq ($expectedCodes[$index] -ne 0)) 'Unknown/error evidence was presented as healthy.'
}
Assert-ProblemCode ((Get-DeviceProblemDescription 28) -match 'Drivers not installed') 'Missing-driver description lost.'
Assert-ProblemCode ((Get-DeviceProblemDescription 32) -match 'service is disabled') 'Disabled-service description lost.'
Assert-ProblemCode ((Get-DeviceProblemDescription -1) -notmatch 'Working properly') 'Unknown code was presented as healthy.'

# Run the real staged device collector with typed enums, then JSON round-trip.
if (-not ('DeviceCheck.Tests.ProblemCode' -as [type])) {
    Add-Type -TypeDefinition 'namespace DeviceCheck.Tests { public enum ProblemCode { CM_PROB_NONE = 0, CM_PROB_FAILED_INSTALL = 28, CM_PROB_DISABLED_SERVICE = 32 } }'
}
function Get-PnpDevice {
    [CmdletBinding()]
    param([switch]$PresentOnly)
    foreach ($code in @(0, 28, 32)) {
        [pscustomobject]@{ Class = 'System'; FriendlyName = "Device $code"; InstanceId = "TEST\COLLECTED_$code"; ConfigManagerErrorCode = [DeviceCheck.Tests.ProblemCode]$code }
    }
}
$collector = New-CollectorScriptBlock
$collected = @(& $collector -RequestedComputerName 'fixture' -QuickMode $true -CollectorVersion 'test' -Stage 'Devices')
Assert-ProblemCode ($collected.Count -eq 3) "Staged collector returned $($collected.Count) fixture devices instead of three."
$roundTrip = $collected | ConvertTo-Json -Depth 8 | ConvertFrom-Json
foreach ($code in @(0, 28, 32)) {
    $device = $roundTrip | Where-Object InstanceId -eq "TEST\COLLECTED_$code"
    Assert-ProblemCode ($device.ConfigManagerErrorCode -is [ValueType] -and $device.ConfigManagerErrorCode -eq $code) 'Collector serialized a typed problem code as an enum name.'
}

if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $customerSnapshot = Get-Content -Raw -LiteralPath $SnapshotPath | ConvertFrom-Json
    $customerDevice = @((Get-DeviceCategoriesFromSnapshot -Snapshot $customerSnapshot) | ForEach-Object { $_.Devices }) |
        Where-Object InstanceId -eq 'ACPI\VPC2004\0'
    Assert-ProblemCode ($null -ne $customerDevice -and $customerDevice.ConfigManagerErrorCode -eq 28 -and $customerDevice.IsProblem) 'Customer VPC2004 snapshot did not retain Code 28.'
    Write-Output 'Customer VPC2004 snapshot: Code 28, IsProblem=True.'
}

Write-Output 'DeviceCheck snapshot problem-code regression passed.'
