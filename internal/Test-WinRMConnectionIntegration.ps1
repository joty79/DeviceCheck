[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path -Path $repoRoot -ChildPath '.assets\WinRMConnection\WinRMConnection.psd1'
$exporter = Join-Path -Path $PSScriptRoot -ChildPath 'Export-DeviceCheckEvidence.ps1'

Test-ModuleManifest -Path $manifest -ErrorAction Stop | Out-Null
Import-Module -Name $manifest -Force -ErrorAction Stop
if (-not (Get-Command -Name 'Connect-WinRMSession' -ErrorAction SilentlyContinue)) {
    throw 'Vendored WinRMConnection module did not export Connect-WinRMSession.'
}

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($exporter, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Export-DeviceCheckEvidence.ps1 has $($parseErrors.Count) parser error(s)."
}

$source = Get-Content -LiteralPath $exporter -Raw
if ($source -notmatch 'WinRMConnection\\WinRMConnection\.psd1') {
    throw 'DeviceCheck exporter does not import the vendored WinRMConnection module.'
}
if ($source -notmatch 'Connect-WinRMSession') {
    throw 'DeviceCheck exporter does not use the shared WinRM session connector.'
}
if ($source -match '\bNew-PSSession\b') {
    throw 'DeviceCheck exporter still contains an ad-hoc New-PSSession call.'
}
if ($source -notmatch 'Remove-PSSession\s+-Session\s+\$session|Remove-PSSession\s+\$session') {
    throw 'DeviceCheck exporter does not guarantee PSSession cleanup.'
}

Write-Host 'DeviceCheck WinRMConnection integration tests passed.' -ForegroundColor Green
