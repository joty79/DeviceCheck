#requires -version 5.1
[CmdletBinding()]
param(
    [int] $MaxEntryPointLines = 700,
    [int] $MaxEntryPointFunctions = 0,
    [int] $MaxPartLines = 2200,
    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$entryPointPath = Join-Path -Path $repoRoot -ChildPath 'DeviceCheck.ps1'
$partRoot = Join-Path -Path $PSScriptRoot -ChildPath 'DeviceCheck'

function Get-PowerShellParseResult {
    param([Parameter(Mandatory)][string] $Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    [pscustomobject]@{
        Path   = $Path
        Ast    = $ast
        Errors = @($errors)
    }
}

function New-StructureAssertion {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool] $Passed,
        [Parameter(Mandatory)][string] $Detail
    )

    [pscustomobject]@{
        Name   = $Name
        Passed = $Passed
        Detail = $Detail
    }
}

if (-not (Test-Path -LiteralPath $entryPointPath -PathType Leaf)) {
    throw "DeviceCheck entrypoint not found: $entryPointPath"
}
if (-not (Test-Path -LiteralPath $partRoot -PathType Container)) {
    throw "DeviceCheck function group folder not found: $partRoot"
}

$entryPointLines = @(Get-Content -LiteralPath $entryPointPath).Count
$entryParse = Get-PowerShellParseResult -Path $entryPointPath
$entryFunctions = @(
    $entryParse.Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)
)

$partFiles = @(Get-ChildItem -LiteralPath $partRoot -Filter '*.ps1' | Sort-Object Name)
$partResults = foreach ($partFile in $partFiles) {
    $partLines = @(Get-Content -LiteralPath $partFile.FullName).Count
    $partParse = Get-PowerShellParseResult -Path $partFile.FullName
    [pscustomobject]@{
        Name       = $partFile.Name
        Path       = $partFile.FullName
        Lines      = $partLines
        ParseError = @($partParse.Errors).Count
    }
}

$assertions = [System.Collections.Generic.List[object]]::new()
$assertions.Add((New-StructureAssertion -Name 'Entrypoint line budget' `
    -Passed ($entryPointLines -le $MaxEntryPointLines) `
    -Detail "DeviceCheck.ps1 has $entryPointLines lines; limit is $MaxEntryPointLines."))
$assertions.Add((New-StructureAssertion -Name 'Entrypoint has no local function definitions' `
    -Passed ($entryFunctions.Count -le $MaxEntryPointFunctions) `
    -Detail "DeviceCheck.ps1 has $($entryFunctions.Count) function definitions; limit is $MaxEntryPointFunctions."))
$assertions.Add((New-StructureAssertion -Name 'Entrypoint parses' `
    -Passed (@($entryParse.Errors).Count -eq 0) `
    -Detail "DeviceCheck.ps1 parser errors: $(@($entryParse.Errors).Count)."))
$assertions.Add((New-StructureAssertion -Name 'Function group parts exist' `
    -Passed ($partFiles.Count -ge 10) `
    -Detail "Found $($partFiles.Count) internal\DeviceCheck part files."))

foreach ($part in $partResults) {
    $assertions.Add((New-StructureAssertion -Name "Part line budget: $($part.Name)" `
        -Passed ($part.Lines -le $MaxPartLines) `
        -Detail "$($part.Name) has $($part.Lines) lines; limit is $MaxPartLines."))
    $assertions.Add((New-StructureAssertion -Name "Part parses: $($part.Name)" `
        -Passed ($part.ParseError -eq 0) `
        -Detail "$($part.Name) parser errors: $($part.ParseError)."))
}

$failed = @($assertions | Where-Object { -not $_.Passed })
$result = [pscustomobject]@{
    Passed              = ($failed.Count -eq 0)
    EntrypointLines     = $entryPointLines
    EntrypointFunctions = $entryFunctions.Count
    PartCount           = $partFiles.Count
    MaxPartLines        = ($partResults | Measure-Object -Property Lines -Maximum).Maximum
    Assertions          = @($assertions)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
} else {
    if ($result.Passed) {
        Write-Host 'DeviceCheck structure guard passed.' -ForegroundColor Green
    } else {
        Write-Host 'DeviceCheck structure guard failed.' -ForegroundColor Red
    }

    $assertions | Format-Table -AutoSize Name, Passed, Detail
}

if (-not $result.Passed) {
    exit 1
}
