#requires -version 5.1
[CmdletBinding()]
param(
    [string]$ComputerName = 'PALIOS',

    [string]$UserName = 'PALIOS\joty79',

    [string]$OutputRoot,

    [switch]$Quick,

    [switch]$SkipTrustedHosts,

    [switch]$NoSave,

    [switch]$PassThru,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$exportScript = Join-Path -Path $PSScriptRoot -ChildPath 'internal\Export-DeviceCheckEvidence.ps1'
if (-not (Test-Path -LiteralPath $exportScript -PathType Leaf)) {
    throw "Required exporter not found: $exportScript"
}

$credential = Get-Credential -UserName $UserName -Message "Enter credentials for $ComputerName"

$params = @{
    ComputerName = $ComputerName
    Credential   = $credential
}

if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
    $params.OutputRoot = $OutputRoot
}
if ($Quick) {
    $params.Quick = $true
}
if ($SkipTrustedHosts) {
    $params.SkipTrustedHosts = $true
}
if ($NoSave) {
    $params.NoSave = $true
}
if ($PassThru) {
    $params.PassThru = $true
}
if ($AsJson) {
    $params.AsJson = $true
}

& $exportScript @params
