<#
.SYNOPSIS
    Resize-safe, flicker-free PowerShell TUI blueprint for Windows Terminal.

.DESCRIPTION
    Canonical target runtime: Windows Terminal (WT) + PowerShell 7.

    This blueprint captures the architecture that survived real-world debugging
    in WinAppManager after multiple failed approaches:

      1) WT synchronized output mode 2026 for atomic frame rendering
      2) Stateless immediate-mode redraw on every frame
      3) Responsive resize polling via KeyAvailable + Test-WindowResized
      4) BufferSize = WindowSize to kill scrollback tearing
      5) Primary buffer only; do NOT use the alternate screen buffer

    The important lesson is that for complex PowerShell TUIs in WT, "partial
    redraw" is not the canonical answer once resize/stretch correctness matters.
    The stable answer is immediate-mode full redraw wrapped in synchronized output.

.USAGE
    Dot-source or import this file, then adapt:
        - Initialize-TuiHost / Restore-TuiHost
        - Read-ConsoleKey
        - Lock-ViewportToWindow
        - Show-InteractiveMenu
        - Show-SearchInputBox / Invoke-SearchMode (when modal search is needed)

    This file is a reusable template/reference, not a finished app.
#>

$_E = [char]27
$_C = @{
    H1      = "$_E[38;2;90;180;240m"
    H2      = "$_E[38;2;140;160;180m"
    OK      = "$_E[38;2;46;204;113m"
    Warn    = "$_E[38;2;241;196;15m"
    Fail    = "$_E[38;2;231;76;60m"
    Info    = "$_E[38;2;52;152;219m"
    Gold    = "$_E[38;2;243;156;18m"
    White   = "$_E[38;2;220;225;230m"
    Dim     = "$_E[38;2;100;110;120m"
    SelBg   = "$_E[48;2;40;80;120m"
    SelFg   = "$_E[38;2;255;255;255m"
    Bold    = "$_E[1m"
    Reset   = "$_E[0m"
    EraseLn = "$_E[K"
}

$script:LastWindowWidth = 0
$script:LastWindowHeight = 0

function Begin-SyncRender {
    [Console]::Write("$_E[?2026h")
}

function End-SyncRender {
    [Console]::Write("$_E[?2026l")
}

function Initialize-TuiHost {
    try {
        # Avoid alternate screen in PowerShell TUIs: ConPTY can freeze window math.
        # Disable auto-wrap to reduce horizontal resize tearing.
        Write-Host "`e[?7l" -NoNewline
    }
    catch {
    }
}

function Restore-TuiHost {
    try {
        [Console]::CursorVisible = $true
    }
    catch {
    }

    try {
        Write-Host "`e[?7h`e[?25h" -NoNewline
    }
    catch {
    }
}

function Get-UiWidth {
    try { [Math]::Max(60, $Host.UI.RawUI.WindowSize.Width - 2) }
    catch { 80 }
}

function Lock-ViewportToWindow {
    try {
        $windowSize = $Host.UI.RawUI.WindowSize
        if ($Host.UI.RawUI.BufferSize.Height -ne $windowSize.Height) {
            $Host.UI.RawUI.BufferSize = $windowSize
        }
    }
    catch {
    }
}

function Test-WindowResized {
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        $height = $Host.UI.RawUI.WindowSize.Height
    }
    catch {
        return $false
    }

    if ($width -ne $script:LastWindowWidth -or $height -ne $script:LastWindowHeight) {
        $script:LastWindowWidth = $width
        $script:LastWindowHeight = $height
        return $true
    }

    return $false
}

function Write-UiBanner {
    param(
        [string]$Title,
        [string]$Subtitle
    )

    $width = Get-UiWidth
    $border = [string]::new([char]0x2550, ($width - 2))
    $maxTextWidth = $width - 3

    # Format Title
    $displayTitle = $Title
    if ($displayTitle.Length -gt $maxTextWidth) {
        $displayTitle = $displayTitle.Substring(0, [Math]::Max(1, $maxTextWidth - 1)) + [char]0x2026
    }
    $titlePad = [Math]::Max(0, $maxTextWidth - $displayTitle.Length)

    # Format Subtitle
    $displaySubtitle = $Subtitle
    $subtitlePad = 0
    if ($Subtitle) {
        if ($displaySubtitle.Length -gt $maxTextWidth) {
            $displaySubtitle = $displaySubtitle.Substring(0, [Math]::Max(1, $maxTextWidth - 1)) + [char]0x2026
        }
        $subtitlePad = [Math]::Max(0, $maxTextWidth - $displaySubtitle.Length)
    }

    Write-Host ''
    Write-Host "$($_C.H1)$([char]0x2554)$border$([char]0x2557)$($_C.Reset)"
    Write-Host "$($_C.H1)$([char]0x2551)$($_C.Bold)$($_C.White) $displayTitle$($_C.Reset)$(' ' * $titlePad)$($_C.H1)$([char]0x2551)$($_C.Reset)"
    if ($Subtitle) {
        Write-Host "$($_C.H1)$([char]0x2551)$($_C.Dim) $displaySubtitle$($_C.Reset)$(' ' * $subtitlePad)$($_C.H1)$([char]0x2551)$($_C.Reset)"
    }
    Write-Host "$($_C.H1)$([char]0x255A)$border$([char]0x255D)$($_C.Reset)"
    Write-Host ''
}

function Write-UiSection {
    param(
        [string]$Title,
        [string]$Icon = [string][char]0x25C6
    )

    $width = Get-UiWidth
    $prefix = if ($Icon) { " $Icon $Title " } else { " $Title " }
    $remaining = [Math]::Max(0, $width - $prefix.Length - 1)
    $line = [string]::new([char]0x2500, $remaining)

    Write-Host ''
    Write-Host "$($_C.H1)$prefix$($_C.Dim)$line$($_C.Reset)"
}

function New-UiShortcutSegment {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Color
    )

    [pscustomobject]@{ Text = $Text; Color = $Color }
}

function Write-UiShortcutSegments {
    param(
        [Parameter(Mandatory)][object[]]$Segments,
        [int]$Width = (Get-UiWidth)
    )

    Write-Host '  ' -NoNewline
    $remaining = [Math]::Max(1, $Width - 3)
    foreach ($segment in $Segments) {
        if ($remaining -le 0) { break }
        $text = [string]$segment.Text
        if ($text.Length -gt $remaining) {
            $text = if ($remaining -eq 1) { $text.Substring(0, 1) } else { $text.Substring(0, $remaining - 1) + '~' }
        }
        Write-Host "$($segment.Color)$text$($_C.Reset)" -NoNewline
        $remaining -= $text.Length
    }
    Write-Host "$($_C.EraseLn)"
}

function Write-UiNavFooter {
    param(
        [ValidateSet('Select','Cancel','Exit','Back')][string]$Mode = 'Select',
        [int]$Width = (Get-UiWidth)
    )

    $segments = @(
        New-UiShortcutSegment -Text "$([char]0x2191)$([char]0x2193)" -Color $_C.White
        New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
        New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
        New-UiShortcutSegment -Text ' = select   ' -Color $_C.Dim
    )

    if ($Mode -eq 'Cancel') {
        $segments += @(
            New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
            New-UiShortcutSegment -Text ' = cancel' -Color $_C.Dim
        )
    }
    elseif ($Mode -eq 'Exit') {
        $segments += @(
            New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
            New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
        )
    }
    elseif ($Mode -eq 'Back') {
        $segments = @(
            New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
            New-UiShortcutSegment -Text ' / ' -Color $_C.Dim
            New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
            New-UiShortcutSegment -Text ' = back' -Color $_C.Dim
        )
    }

    Write-UiShortcutSegments -Segments $segments -Width $Width
}

function Show-SearchInputBox {
    param(
        [AllowEmptyString()]
        [string]$Query,
        [int]$MatchCount,
        [int]$MaxWidth = 56
    )

    # Keep the search control anchored and compact; do not let it stretch to full width.
    $boxWidth = [Math]::Min($MaxWidth, [Math]::Max(34, [Math]::Floor((Get-UiWidth) * 0.58)))
    $innerWidth = $boxWidth - 2
    $title = ' Search Mode '
    $titlePad = [Math]::Max(0, $innerWidth - $title.Length)
    $indent = '  '
    $prompt = '> '
    $inputWidth = [Math]::Max(8, $innerWidth - 1)
    $displayQuery = if ($Query.Length -gt $inputWidth) { $Query.Substring($Query.Length - $inputWidth) } else { $Query }
    $inputText = "$prompt$displayQuery"
    $queryPadding = [Math]::Max(0, $inputWidth - $inputText.Length)
    $topBorder = [string]::new([char]0x2550, $titlePad)
    $bottomBorder = [string]::new([char]0x2550, $innerWidth)

    try {
        $inputRow = $Host.UI.RawUI.CursorPosition.Y + 1
    }
    catch {
        $inputRow = 0
    }

    Write-Host "$indent$($_C.Warn)$([char]0x2554)$title$topBorder$([char]0x2557)$($_C.Reset)$($_C.EraseLn)"
    Write-Host "$indent$($_C.Warn)$([char]0x2551)$($_C.White)$inputText$(' ' * $queryPadding)$($_C.Warn) $([char]0x2551)$($_C.Reset)$($_C.EraseLn)"
    Write-Host "$indent$($_C.Warn)$([char]0x255A)$bottomBorder$([char]0x255D)$($_C.Reset)$($_C.EraseLn)"
    Write-Host "$($_C.Dim)  Matches: $($_C.OK)$MatchCount$($_C.Reset)$($_C.EraseLn)"

    [pscustomobject]@{
        CursorLeft = $indent.Length + 1 + $prompt.Length + $displayQuery.Length
        CursorTop  = $inputRow
    }
}

function Read-ConsoleKey {
    try { [Console]::CursorVisible = $false } catch {}

    try {
        while (-not [Console]::KeyAvailable) {
            if (Test-WindowResized) {
                return [pscustomobject]@{
                    Key            = 'ResizeEvent'
                    KeyChar        = [char]0
                    VirtualKeyCode = 0
                }
            }

            Start-Sleep -Milliseconds 40
        }
    }
    catch {
    }

    try {
        $keyInfo = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    catch {
        $keyInfo = [Console]::ReadKey($true)
    }

    $keyName = $null
    $keyChar = [char]0
    $virtualKeyCode = $null

    if ($keyInfo.PSObject.Properties['Key']) {
        $keyName = [string]$keyInfo.Key
    }
    elseif ($keyInfo.PSObject.Properties['VirtualKeyCode']) {
        $virtualKeyCode = [int]$keyInfo.VirtualKeyCode
        try {
            $keyName = [string][System.Enum]::ToObject([System.ConsoleKey], $virtualKeyCode)
        }
        catch {
            $keyName = [string]$virtualKeyCode
        }
    }

    if ($keyInfo.PSObject.Properties['KeyChar']) {
        $keyChar = [char]$keyInfo.KeyChar
    }
    elseif ($keyInfo.PSObject.Properties['Character']) {
        $keyChar = [char]$keyInfo.Character
    }

    [pscustomobject]@{
        Key            = $keyName
        KeyChar        = $keyChar
        VirtualKeyCode = $virtualKeyCode
    }
}

function Invoke-ArrowMenu {
    param(
        [string[]]$Items,
        [string]$Title = 'Select',
        [string]$CurrentItem = '',
        [scriptblock]$HeaderBlock = $null
    )

    if ($Items.Count -eq 0) {
        return $null
    }

    $cursor = [Math]::Max(0, [Array]::IndexOf($Items, $CurrentItem))

    [Console]::CursorVisible = $false
    try {
        while ($true) {
            Lock-ViewportToWindow

            try {
                $maxVisible = [Math]::Max(3, $Host.UI.RawUI.WindowSize.Height - 8)
            }
            catch {
                $maxVisible = 10
            }

            $viewTop = [Math]::Max(0, [Math]::Min($cursor - [int]($maxVisible / 2), [Math]::Max(0, $Items.Count - $maxVisible)))
            $viewBot = [Math]::Min($viewTop + $maxVisible - 1, $Items.Count - 1)

            Begin-SyncRender
            try { Clear-Host } catch {}

            if ($null -ne $HeaderBlock) {
                & $HeaderBlock
            }

            Write-UiSection -Title $Title -Icon ''
            Write-Host ''

            $aboveMessage = if ($viewTop -gt 0) { "  $($_C.Dim)$([char]0x2191) $viewTop more above$($_C.Reset)" } else { '' }
            Write-Host "$aboveMessage$($_C.EraseLn)"

            for ($index = $viewTop; $index -le $viewBot; $index++) {
                if ($index -eq $cursor) {
                    Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $([char]0x276F) $($Items[$index]) $($_C.Reset)$($_C.EraseLn)"
                }
                else {
                    Write-Host "    $($_C.Dim)$($Items[$index])$($_C.Reset)$($_C.EraseLn)"
                }
            }

            $below = $Items.Count - 1 - $viewBot
            $belowMessage = if ($below -gt 0) { "  $($_C.Dim)$([char]0x2193) $below more below$($_C.Reset)" } else { '' }
            Write-Host "$belowMessage$($_C.EraseLn)"
            Write-Host "$($_C.EraseLn)"
            Write-UiNavFooter -Mode Cancel
            Write-Host "$($_E)[J" -NoNewline

            End-SyncRender

            $key = Read-ConsoleKey
            switch ($key.Key) {
                'UpArrow' { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt ($Items.Count - 1)) { $cursor++ } }
                'PageUp' { $cursor = [Math]::Max(0, $cursor - $maxVisible) }
                'PageDown' { $cursor = [Math]::Min($Items.Count - 1, $cursor + $maxVisible) }
                'Home' { $cursor = 0 }
                'End' { $cursor = $Items.Count - 1 }
                'Enter' { return $Items[$cursor] }
                'Escape' { return $null }
                'ResizeEvent' { continue }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

function Show-InteractiveMenu {
    param(
        [string]$AppTitle = 'My App',
        [string]$AppSubtitle = '',
        [string[]]$Options = @('Option 1', 'Option 2', 'Exit'),
        [hashtable]$Actions = @{}
    )

    $selectedIndex = 0

    [Console]::CursorVisible = $false
    try {
        while ($true) {
            Lock-ViewportToWindow

            Begin-SyncRender
            try { Clear-Host } catch {}

            Write-UiBanner -Title $AppTitle -Subtitle $AppSubtitle
            Write-UiSection -Title 'Menu'

            for ($index = 0; $index -lt $Options.Count; $index++) {
                if ($index -eq $selectedIndex) {
                    Write-Host "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $([char]0x276F) $($Options[$index]) $($_C.Reset)$($_C.EraseLn)"
                }
                else {
                    Write-Host "    $($_C.White)$($Options[$index])$($_C.Reset)$($_C.EraseLn)"
                }
            }

            Write-Host ''
            Write-UiNavFooter -Mode Exit
            Write-Host "$($_E)[J" -NoNewline

            End-SyncRender

            $key = Read-ConsoleKey
            switch ($key.Key) {
                'UpArrow' { $selectedIndex = [Math]::Max(0, $selectedIndex - 1) }
                'DownArrow' { $selectedIndex = [Math]::Min($Options.Count - 1, $selectedIndex + 1) }
                'Escape' { return }
                'ResizeEvent' { continue }
                'Enter' {
                    if ($Actions.ContainsKey($selectedIndex)) {
                        & $Actions[$selectedIndex]
                    }
                    elseif ($selectedIndex -eq ($Options.Count - 1)) {
                        return
                    }
                }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

function Invoke-SearchMode {
    param(
        [scriptblock]$RenderHeader,
        [scriptblock]$RenderResults,
        [scriptblock]$GetVisibleItems,
        [ref]$Filter,
        [int]$SelectedIndex = 0
    )

    $originalFilter = [string]$Filter.Value
    $currentIndex = [Math]::Max(0, $SelectedIndex)

    while ($true) {
        Lock-ViewportToWindow
        $visibleItems = @(& $GetVisibleItems)
        if ($visibleItems.Count -eq 0) {
            $currentIndex = 0
        }
        else {
            $currentIndex = [Math]::Max(0, [Math]::Min($currentIndex, $visibleItems.Count - 1))
        }

        Begin-SyncRender
        try { Clear-Host } catch {}
        if ($null -ne $RenderHeader) { & $RenderHeader }
        $searchUi = Show-SearchInputBox -Query $Filter.Value -MatchCount $visibleItems.Count
        if ($null -ne $RenderResults) { & $RenderResults $visibleItems $currentIndex }
        [Console]::Write("$_E[J")
        End-SyncRender

        try { [Console]::SetCursorPosition($searchUi.CursorLeft, $searchUi.CursorTop) } catch {}
        try { [Console]::CursorVisible = $true } catch {}

        $keyInfo = Read-ConsoleKey
        switch ($keyInfo.Key) {
            'Escape' {
                $Filter.Value = $originalFilter
                return 0
            }
            'Enter' {
                $Filter.Value = $Filter.Value.Trim()
                return 0
            }
            'Backspace' {
                if ($Filter.Value.Length -gt 0) {
                    $Filter.Value = $Filter.Value.Substring(0, $Filter.Value.Length - 1)
                }
                $currentIndex = 0
                continue
            }
            'Delete' {
                $Filter.Value = ''
                $currentIndex = 0
                continue
            }
            'Spacebar' {
                $Filter.Value += ' '
                $currentIndex = 0
                continue
            }
            'ResizeEvent' {
                continue
            }
            default {
                if ($keyInfo.KeyChar -ne [char]0 -and -not [char]::IsControl($keyInfo.KeyChar)) {
                    $Filter.Value += [string]$keyInfo.KeyChar
                    $currentIndex = 0
                }
                continue
            }
        }
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  NATIVE WINDOWS FILE/FOLDER PICKERS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function Select-FileWithDialog {
    param(
        [string]$Title = 'Select File',
        [string]$Filter = 'All files (*.*)|*.*',
        [string]$InitialDir = ''
    )
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = $Title
    $dlg.Filter = $Filter
    $dlg.CheckFileExists = $true
    if ($InitialDir -and (Test-Path $InitialDir)) { $dlg.InitialDirectory = $InitialDir }
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.FileName }
    return ''
}
