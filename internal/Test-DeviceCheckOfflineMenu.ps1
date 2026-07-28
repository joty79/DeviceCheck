#requires -version 5.1
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'Loads the canonical TUI blueprint into script scope exactly as DeviceCheck.ps1 does.')]
param(
    [string]$PythonPath = '',
    [switch]$SkipVirtualTerminalReplay
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$blueprintPath = Join-Path $repoRoot 'PS_UI_Blueprint.psm1'
$blueprintReceiptPath = Join-Path $repoRoot 'PS_UI_Blueprint.sha256'
$expectedBlueprintHash = (Get-Content -Raw -LiteralPath $blueprintReceiptPath).Trim()
$actualBlueprintHash = (Get-FileHash -LiteralPath $blueprintPath -Algorithm SHA256).Hash
if ($actualBlueprintHash -ne $expectedBlueprintHash) {
    throw "DeviceCheck TUI blueprint drift. Expected=$expectedBlueprintHash Actual=$actualBlueprintHash"
}
if ([string]::IsNullOrWhiteSpace($env:POWERSHELL_TUI_PRIMARY_BUFFER)) {
    $script:TuiPrimaryBufferModeOverride = $true
}
Invoke-Expression (Get-Content -LiteralPath $blueprintPath -Raw)
. (Join-Path $PSScriptRoot 'DeviceCheck\04-UiTextFormatting.ps1')
. (Join-Path $PSScriptRoot 'DeviceCheck\06-RemoteConnectionOfflineMenu.ps1')

function Assert-OfflineMenuTest {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Test-OfflineMenuPythonExecutable {
    param([AllowEmptyString()][string]$CandidatePath)

    if ([string]::IsNullOrWhiteSpace($CandidatePath) -or -not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
        return $false
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $CandidatePath -c 'import sys; raise SystemExit(0)' *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-VerifiedOfflineMenuWheel {
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Sha256
    )

    $downloadRoot = Join-Path $repoRoot '.devicecheck-data\test-tools\downloads'
    $null = New-Item -Path $downloadRoot -ItemType Directory -Force
    $target = Join-Path $downloadRoot $FileName
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $existingHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($existingHash -eq $Sha256) { return $target }
        throw "Cached wheel hash mismatch: $target"
    }

    $metadata = Invoke-RestMethod -Uri "https://pypi.org/pypi/$Package/$Version/json" -TimeoutSec 30
    $artifact = @($metadata.urls | Where-Object { $_.filename -eq $FileName }) | Select-Object -First 1
    if ($null -eq $artifact -or [string]$artifact.digests.sha256 -ne $Sha256.ToLowerInvariant()) {
        throw "Official PyPI metadata did not verify $FileName"
    }
    Invoke-WebRequest -Uri $artifact.url -OutFile $target -UseBasicParsing -TimeoutSec 60
    $downloadHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($downloadHash -ne $Sha256) { throw "Downloaded wheel hash mismatch: $target" }
    return $target
}

function Get-OfflineMenuViewportTestFrame {
    param(
        [int]$Width,
        [int]$WindowHeight,
        [int]$SelectedRow,
        [switch]$ForceClear
    )

    $visibleLineBudget = Get-DeviceCheckOfflineMenuVisibleLineBudget -WindowHeight $WindowHeight
    $frame = New-UiFrame
    Add-UiFrameBanner -Frame $frame -Title 'Offline Snapshot Library' -Subtitle 'Active Network: datacomputer2' -Width $Width
    Add-UiFrameLine -Frame $frame
    Add-UiFrameLine -Frame $frame -Text "$($_C.EraseLn)"

    for ($index = 0; $index -lt $visibleLineBudget; $index++) {
        if ($index -eq 0) {
            $text = '  Offline Snapshots: datacomputer2'
        } elseif ($index -eq $SelectedRow) {
            $text = "  > selected snapshot $index"
        } else {
            $text = "    snapshot row $index"
        }
        Add-UiFrameLine -Frame $frame -Text "$(Format-PlainToWidth -Text $text -Width $Width)$($_C.EraseLn)"
    }

    Add-UiFrameLine -Frame $frame -Text "$($_C.EraseLn)"
    Add-UiFrameLine -Frame $frame -Text "$($_C.EraseLn)"
    Add-UiFrameShortcutSegments -Frame $frame -Segments @(
        (New-UiShortcutSegment -Text 'Up/Down' -Color $_C.White)
        (New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim)
        (New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail)
        (New-UiShortcutSegment -Text ' = back' -Color $_C.Dim)
    ) -Width $Width

    $frameLineCount = [regex]::Matches($frame.ToString(), "`n").Count
    Assert-OfflineMenuTest -Condition ($frameLineCount -le ($WindowHeight - 1)) -Message "Offline selector frame uses $frameLineCount lines in a $WindowHeight-row viewport."

    $escape = [string][char]27
    $prefix = $(if ($ForceClear) { Get-TuiForceClearSequence } else { "$escape[H" })
    return "$escape[?2026h$prefix$($frame.ToString())$escape[J$escape[?2026l"
}

foreach ($case in @(
        [pscustomobject]@{ Height = 22; Expected = 10 },
        [pscustomobject]@{ Height = 30; Expected = 18 },
        [pscustomobject]@{ Height = 44; Expected = 32 }
    )) {
    $actual = Get-DeviceCheckOfflineMenuVisibleLineBudget -WindowHeight $case.Height
    Assert-OfflineMenuTest -Condition ($actual -eq $case.Expected) -Message "Unexpected visible-line budget for height $($case.Height): $actual"
}

$widthSequence = @(120, 101, 100, 99, 98, 80, 60, 120)
$terminalHeight = 44
$frames = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $widthSequence.Count; $index++) {
    $terminalWidth = $widthSequence[$index]
    $state = $index + 1
    $frames.Add([pscustomobject]@{
            Width = $terminalWidth
            Height = $terminalHeight
            State = $state
            Data = Get-OfflineMenuViewportTestFrame -Width ($terminalWidth - 2) -WindowHeight $terminalHeight -SelectedRow $state -ForceClear
        })
}

if (-not $SkipVirtualTerminalReplay) {
    $pythonCandidates = [System.Collections.Generic.List[string]]::new()
    foreach ($candidatePath in @(
            $PythonPath
            $env:DEVICECHECK_TEST_PYTHON
            (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe')
        )) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and -not $pythonCandidates.Contains($candidatePath)) {
            $pythonCandidates.Add($candidatePath)
        }
    }

    foreach ($commandName in @('python', 'python3')) {
        $pythonCommand = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($null -ne $pythonCommand -and -not $pythonCandidates.Contains($pythonCommand.Source)) {
            $pythonCandidates.Add($pythonCommand.Source)
        }
    }

    $PythonPath = @(
        $pythonCandidates |
            Where-Object { Test-OfflineMenuPythonExecutable -CandidatePath $_ }
    ) | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($PythonPath)) {
        throw 'A working Python executable is required for the pyte virtual-terminal replay. Pass -PythonPath, set DEVICECHECK_TEST_PYTHON, or use -SkipVirtualTerminalReplay.'
    }

    $pyteWheel = Get-VerifiedOfflineMenuWheel -Package 'pyte' -Version '0.8.2' -FileName 'pyte-0.8.2-py3-none-any.whl' -Sha256 '85DB42A35798A5AAFA96AC4D8DA78B090B2C933248819157FC0E6F78876A0135'
    $wcwidthWheel = Get-VerifiedOfflineMenuWheel -Package 'wcwidth' -Version '0.8.2' -FileName 'wcwidth-0.8.2-py3-none-any.whl' -Sha256 'D63947694A0539A1D51E01EDA7CAF800C291020E6CDD7E28AD7B14DD33AD4F85'

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("DeviceCheck-OfflineMenu-VT-{0}" -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempRoot
    try {
        $manifest = [System.Collections.Generic.List[object]]::new()
        foreach ($frame in $frames) {
            $framePath = Join-Path $tempRoot ("frame-{0}.txt" -f $frame.State)
            [System.IO.File]::WriteAllText($framePath, $frame.Data, [System.Text.UTF8Encoding]::new($false))
            $manifest.Add([pscustomobject]@{ width = $frame.Width; height = $frame.Height; state = $frame.State; path = $framePath })
        }
        $manifestPath = Join-Path $tempRoot 'manifest.json'
        [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))

        $previousPythonPath = $env:PYTHONPATH
        $env:PYTHONPATH = "$pyteWheel;$wcwidthWheel"
        try {
            $pythonCode = @'
import pathlib
import json
import re
import sys
import pyte
from wcwidth import wcswidth

ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")

class TrackingScreen(pyte.Screen):
    def __init__(self, columns, lines):
        super().__init__(columns, lines)
        self.scrolls = 0

    def index(self):
        bottom = self.lines - 1 if self.margins is None else self.margins.bottom
        at_bottom = self.cursor.y == bottom
        super().index()
        if at_bottom:
            self.scrolls += 1

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
first = manifest[0]
screen = TrackingScreen(first["width"], first["height"])
stream = pyte.Stream(screen)
previous_marker = None
for item in manifest:
    screen.resize(lines=item["height"], columns=item["width"])
    with pathlib.Path(item["path"]).open("r", encoding="utf-8", newline="") as handle:
        payload = handle.read()
    for source_line in ANSI.sub("", payload).splitlines():
        display_width = wcswidth(source_line)
        if display_width >= item["width"]:
            raise SystemExit(f"state {item['state']}: line width {display_width} exceeds safe viewport {item['width']}")

    scrolls_before = screen.scrolls
    stream.feed(payload)
    if screen.scrolls != scrolls_before:
        raise SystemExit(f"state {item['state']}: viewport scrolled during redraw")

    display = "\n".join(screen.display)
    marker = f"> selected snapshot {item['state']}"
    if display.count("Offline Snapshot Library") != 1:
        raise SystemExit(f"state {item['state']}: banner duplication detected")
    if display.count("Offline Snapshots: datacomputer2") != 1:
        raise SystemExit(f"state {item['state']}: content-header duplication detected")
    if display.count(marker) != 1:
        raise SystemExit(f"state {item['state']}: current selection marker missing or duplicated")
    if previous_marker and previous_marker in display:
        raise SystemExit(f"state {item['state']}: stale selection marker remained")
    previous_marker = marker

print("DeviceCheck pyte resize replay passed: 120->101->100->99->98->80->60->120, zero wraps, zero scrolls, zero stale frames")
'@
            $pythonScriptPath = Join-Path $tempRoot 'replay.py'
            [System.IO.File]::WriteAllText($pythonScriptPath, $pythonCode, [System.Text.UTF8Encoding]::new($false))
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $vtOutput = & $PythonPath $pythonScriptPath $manifestPath 2>&1
                $pythonExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            if ($pythonExitCode -ne 0) { throw ($vtOutput -join [Environment]::NewLine) }
            $vtOutput | Write-Output
        } finally {
            $env:PYTHONPATH = $previousPythonPath
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'Offline snapshot menu viewport regression passed.'
