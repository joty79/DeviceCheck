# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: Console input cleanup, resize-aware key polling, and ignored-input handling.
function Clear-PendingConsoleInput {
    param([int]$MaxCount = 64)

    $drained = 0
    while ([Console]::KeyAvailable -and $drained -lt $MaxCount) {
        try {
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
        catch {
            try { $null = [Console]::ReadKey($true) } catch { break }
        }
        $drained++
    }

    return $drained
}

# Override Read-ConsoleKey to support background search ticks & smooth rendering
function Read-ConsoleKey {
    try { [Console]::CursorVisible = $false } catch {}

    $keyName = $null
    $keyChar = [char]0
    $virtualKeyCode = $null
    $controlPressed = $false

    try {
        while (-not [Console]::KeyAvailable) {
            if (Test-WindowResized) {
                return [pscustomobject]@{
                    Key            = 'ResizeEvent'
                    KeyChar        = [char]0
                    VirtualKeyCode = 0
                    ControlPressed = $false
                }
            }

            # Update active/pending background searches and redraw
            if ($script:ActiveSearches.Count -gt 0 -or $script:EvidenceBatchQueue.Count -gt 0) {
                Update-ActiveSearches
                if ($script:VisibleRowsDirty) {
                    $script:visibleRows = Update-VisibleRows
                    $script:VisibleRowsDirty = $false
                }
                if ($script:visibleRows.Count -gt 0) {
                    $script:selectedIndex = [Math]::Max(0, [Math]::Min($script:selectedIndex, $script:visibleRows.Count - 1))
                } else {
                    $script:selectedIndex = 0
                }
                Render-Frame
                Start-Sleep -Milliseconds 150
            } else {
                Start-Sleep -Milliseconds 10
            }
        }

        $keyInfo = $null
        try {
            $keyInfo = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
        catch {
            $keyInfo = [Console]::ReadKey($true)
        }

        if ($null -ne $keyInfo) {
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

            if ($keyInfo.PSObject.Properties['Modifiers']) {
                $controlPressed = (([string]$keyInfo.Modifiers) -match 'Control')
            }
            elseif ($keyInfo.PSObject.Properties['ControlKeyState']) {
                $controlPressed = (([string]$keyInfo.ControlKeyState) -match 'CtrlPressed')
            }
        }

        if ($keyChar -ne [char]0 -and -not [char]::IsControl($keyChar) -and [Console]::KeyAvailable) {
            $drained = Clear-PendingConsoleInput
            $script:SystemScanMessage = "Ignored pasted/input burst ($($drained + 1) keys). Use keyboard shortcuts one at a time; right-click paste is ignored. | $(Get-Date -Format 'HH:mm:ss')"
            return [pscustomobject]@{
                Key            = 'IgnoredInputBurst'
                KeyChar        = [char]0
                VirtualKeyCode = 0
                ControlPressed = $false
            }
        }
    }
    catch {
        throw $_
    }

    return [pscustomobject]@{
        Key            = $keyName
        KeyChar        = $keyChar
        VirtualKeyCode = $virtualKeyCode
        ControlPressed = $controlPressed
    }
}
