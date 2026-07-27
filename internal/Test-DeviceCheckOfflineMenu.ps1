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
Invoke-Expression (Get-Content -LiteralPath (Join-Path $repoRoot 'PS_UI_Blueprint.psm1') -Raw)
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
    $clear = $(if ($ForceClear) { "$escape[2J" } else { '' })
    return "$escape[?2026h$clear$escape[H$($frame.ToString())$escape[J$escape[?2026l"
}

foreach ($case in @(
        [pscustomobject]@{ Height = 22; Expected = 10 },
        [pscustomobject]@{ Height = 30; Expected = 18 },
        [pscustomobject]@{ Height = 44; Expected = 32 }
    )) {
    $actual = Get-DeviceCheckOfflineMenuVisibleLineBudget -WindowHeight $case.Height
    Assert-OfflineMenuTest -Condition ($actual -eq $case.Expected) -Message "Unexpected visible-line budget for height $($case.Height): $actual"
}

$terminalWidth = 156
$uiWidth = $terminalWidth - 2
$height = 44
$firstFrame = Get-OfflineMenuViewportTestFrame -Width $uiWidth -WindowHeight $height -SelectedRow 7 -ForceClear
$secondFrame = Get-OfflineMenuViewportTestFrame -Width $uiWidth -WindowHeight $height -SelectedRow 8

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

    $downloadRoot = Join-Path $repoRoot '.devicecheck-data\test-tools\downloads'
    $pyteWheel = Join-Path $downloadRoot 'pyte-0.8.2-py3-none-any.whl'
    $wcwidthWheel = Join-Path $downloadRoot 'wcwidth-0.8.2-py3-none-any.whl'
    foreach ($wheel in @($pyteWheel, $wcwidthWheel)) {
        if (-not (Test-Path -LiteralPath $wheel -PathType Leaf)) {
            throw "Required verified VT test wheel is missing: $wheel"
        }
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("DeviceCheck-OfflineMenu-VT-{0}" -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempRoot
    try {
        $firstPath = Join-Path $tempRoot 'frame-1.txt'
        $secondPath = Join-Path $tempRoot 'frame-2.txt'
        [System.IO.File]::WriteAllText($firstPath, $firstFrame, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($secondPath, $secondFrame, [System.Text.UTF8Encoding]::new($false))

        $previousPythonPath = $env:PYTHONPATH
        $env:PYTHONPATH = "$pyteWheel;$wcwidthWheel"
        try {
            $pythonCode = @'
import pathlib
import sys
import pyte

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

width = int(sys.argv[1])
height = int(sys.argv[2])
screen = TrackingScreen(width, height)
stream = pyte.Stream(screen)
for frame_path in sys.argv[3:]:
    with pathlib.Path(frame_path).open("r", encoding="utf-8", newline="") as handle:
        stream.feed(handle.read())

display = "\n".join(screen.display)
if screen.scrolls != 0:
    raise SystemExit(f"viewport scrolled {screen.scrolls} times")
if display.count("Offline Snapshot Library") != 1:
    raise SystemExit("banner duplication detected")
if display.count("Offline Snapshots: datacomputer2") != 1:
    raise SystemExit("content-header duplication detected")
if "> selected snapshot 8" not in display:
    raise SystemExit("second navigation frame was not rendered")
print("pyte VT replay passed: 156x44, two navigation frames, zero scrolls, zero duplicate headers")
'@
            $pythonScriptPath = Join-Path $tempRoot 'replay.py'
            [System.IO.File]::WriteAllText($pythonScriptPath, $pythonCode, [System.Text.UTF8Encoding]::new($false))
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $vtOutput = & $PythonPath $pythonScriptPath $terminalWidth $height $firstPath $secondPath 2>&1
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
