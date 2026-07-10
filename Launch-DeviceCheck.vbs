Option Explicit

Dim shell
Dim appShell
Dim fso
Dim repoRoot
Dim scriptPath
Dim launchProgram
Dim launchArguments
Dim hasWindowsTerminal

Set shell = CreateObject("WScript.Shell")
Set appShell = CreateObject("Shell.Application")
Set fso = CreateObject("Scripting.FileSystemObject")

repoRoot = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(repoRoot, "DeviceCheck.ps1")

If Not fso.FileExists(scriptPath) Then
    MsgBox "DeviceCheck.ps1 was not found beside Launch-DeviceCheck.vbs:" & vbCrLf & scriptPath, vbExclamation, "DeviceCheck"
    WScript.Quit 1
End If

hasWindowsTerminal = (shell.Run("%ComSpec% /c where wt.exe >nul 2>nul", 0, True) = 0)

If hasWindowsTerminal Then
    launchProgram = "wt.exe"
    launchArguments = "-d " & Quote(repoRoot) & " pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File " & Quote(scriptPath)
Else
    launchProgram = "pwsh.exe"
    launchArguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File " & Quote(scriptPath)
End If

appShell.ShellExecute launchProgram, launchArguments, repoRoot, "runas", 1

Function Quote(ByVal value)
    Quote = Chr(34) & value & Chr(34)
End Function
