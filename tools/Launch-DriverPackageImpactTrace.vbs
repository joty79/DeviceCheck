Option Explicit

Dim shell
Dim appShell
Dim fso
Dim repoRoot
Dim toolsRoot
Dim traceScript
Dim launchMode
Dim extractionModeArguments
Dim installerPath
Dim launchProgram
Dim launchArguments
Dim hasWindowsTerminal

If WScript.Arguments.Count < 1 Then
    MsgBox "No installer path was passed to the DeviceCheck trace launcher.", vbExclamation, "DeviceCheck Driver Trace"
    WScript.Quit 1
End If

Set shell = CreateObject("WScript.Shell")
Set appShell = CreateObject("Shell.Application")
Set fso = CreateObject("Scripting.FileSystemObject")

installerPath = WScript.Arguments(0)
launchMode = "TraceAdvisor"
If WScript.Arguments.Count >= 2 Then
    launchMode = WScript.Arguments(1)
End If
toolsRoot = fso.GetParentFolderName(WScript.ScriptFullName)
repoRoot = fso.GetParentFolderName(toolsRoot)
traceScript = fso.BuildPath(toolsRoot, "Trace-DriverPackageImpact.ps1")

Select Case LCase(launchMode)
    Case "previewadvisor"
        extractionModeArguments = " -ExtractionMode Safe -PromptForExtendedExtraction -PreviewOnly -LaunchAdvisor"
    Case "traceadvisor"
        extractionModeArguments = " -ExtractionMode Safe -PromptForExtendedExtraction -RunInstaller -LaunchAdvisor"
    Case "previewonly"
        extractionModeArguments = " -ExtractionMode Safe -PromptForExtendedExtraction -PreviewOnly"
    Case "traceonly"
        extractionModeArguments = " -ExtractionMode Safe -PromptForExtendedExtraction -RunInstaller"
    Case Else
        MsgBox "Unknown DeviceCheck driver trace mode: " & launchMode, vbExclamation, "DeviceCheck Driver Trace"
        WScript.Quit 1
End Select

If Not fso.FileExists(traceScript) Then
    MsgBox "Trace-DriverPackageImpact.ps1 was not found:" & vbCrLf & traceScript, vbExclamation, "DeviceCheck Driver Trace"
    WScript.Quit 1
End If

If Not fso.FileExists(installerPath) Then
    MsgBox "The selected installer was not found:" & vbCrLf & installerPath, vbExclamation, "DeviceCheck Driver Trace"
    WScript.Quit 1
End If

hasWindowsTerminal = (shell.Run("%ComSpec% /c where wt.exe >nul 2>nul", 0, True) = 0)

If hasWindowsTerminal Then
    launchProgram = "wt.exe"
    launchArguments = "-d " & Quote(repoRoot) & " pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File " & Quote(traceScript) & " -InstallerPath " & Quote(installerPath) & extractionModeArguments & " -PauseAtEnd"
Else
    launchProgram = "pwsh.exe"
    launchArguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File " & Quote(traceScript) & " -InstallerPath " & Quote(installerPath) & extractionModeArguments & " -PauseAtEnd"
End If

appShell.ShellExecute launchProgram, launchArguments, repoRoot, "runas", 1

Function Quote(ByVal value)
    Quote = Chr(34) & value & Chr(34)
End Function
