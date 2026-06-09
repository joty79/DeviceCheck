# Enable-RemotePs.ps1
# Run this script as Administrator on the target Windows machine to enable Remote PowerShell / WinRM.

# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script MUST be run as Administrator! Please reopen PowerShell as Administrator."
    Exit
}

Write-Host "Starting Remote PowerShell configuration..." -ForegroundColor Cyan

# 2. Change network profile categories to Private (required to enable WinRM firewall rules)
Write-Host "Changing network profile categories to Private..." -ForegroundColor White
try {
    Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -ne 'DomainAuthenticated' } | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Stop
    Write-Host "✅ Network profile category changed to Private." -ForegroundColor Green
} catch {
    Write-Warning "Failed to set network category to Private: $_"
}

# 3. Enable PowerShell Remoting and quick config
Write-Host "Enabling PowerShell Remoting..." -ForegroundColor White
try {
    # WSMan quick configuration
    Enable-PSRemoting -Force -ErrorAction Stop
    Set-WSManQuickConfig -Force -ErrorAction Stop
    Write-Host "✅ PowerShell Remoting has been enabled." -ForegroundColor Green
} catch {
    Write-Warning "Failed to enable PSRemoting/WSMan: $_"
}

# 4. Configure WinRM service to start automatically
Write-Host "Configuring WinRM Service..." -ForegroundColor White
try {
    Set-Service -Name "WinRM" -StartupType "Automatic" -ErrorAction Stop
    Start-Service -Name "WinRM" -ErrorAction SilentlyContinue
    Write-Host "✅ WinRM Service set to Automatic." -ForegroundColor Green
} catch {
    Write-Warning "Failed to configure WinRM service: $_"
}

# 5. Enable firewall rules for WinRM
Write-Host "Enabling Firewall rules..." -ForegroundColor White
try {
    Enable-NetFirewallRule -Name "WINRM-HTTP-In-TCP" -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -Name "WINRM-HTTP-In-TCP-Public" -ErrorAction SilentlyContinue
    Write-Host "✅ Firewall rules enabled." -ForegroundColor Green
} catch {
    Write-Warning "Failed to enable firewall rules: $_"
}

# 6. Configure LocalAccountTokenFilterPolicy (UAC Remote Restrictions bypass) & LimitBlankPasswordUse (Allow blank passwords remotely)
Write-Host "Configuring registry settings for Local Accounts (UAC bypass & blank password policy)..." -ForegroundColor White
try {
    $registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    $valueName = "LocalAccountTokenFilterPolicy"
    
    if (-not (Test-Path -Path $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
    }
    
    if (-not (Get-ItemProperty -Path $registryPath -Name $valueName -ErrorAction SilentlyContinue)) {
        New-ItemProperty -Path $registryPath -Name $valueName -Value 1 -PropertyType DWord -Force | Out-Null
    } else {
        Set-ItemProperty -Path $registryPath -Name $valueName -Value 1 -Type DWord -Force | Out-Null
    }
    Write-Host "✅ LocalAccountTokenFilterPolicy configured successfully." -ForegroundColor Green
} catch {
    Write-Warning "Failed to configure LocalAccountTokenFilterPolicy: $_"
}

try {
    $lsaPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    $blankPasswordValueName = "LimitBlankPasswordUse"
    
    if (-not (Test-Path -Path $lsaPath)) {
        New-Item -Path $lsaPath -Force | Out-Null
    }
    
    if (-not (Get-ItemProperty -Path $lsaPath -Name $blankPasswordValueName -ErrorAction SilentlyContinue)) {
        New-ItemProperty -Path $lsaPath -Name $blankPasswordValueName -Value 0 -PropertyType DWord -Force | Out-Null
    } else {
        Set-ItemProperty -Path $lsaPath -Name $blankPasswordValueName -Value 0 -Type DWord -Force | Out-Null
    }
    Write-Host "✅ LimitBlankPasswordUse configured successfully (allowed blank passwords remotely)." -ForegroundColor Green
} catch {
    Write-Warning "Failed to configure LimitBlankPasswordUse: $_"
}

# 7. Restart WinRM service to apply all settings
Write-Host "Restarting WinRM Service to apply changes..." -ForegroundColor White
try {
    Restart-Service -Name "WinRM" -Force -ErrorAction Stop
    Write-Host "✅ WinRM Service restarted successfully." -ForegroundColor Green
} catch {
    Write-Warning "Failed to restart WinRM service: $_. Please restart the PC or the WinRM service manually."
}

Write-Host "`nConfiguration complete! You can now connect remotely using DeviceCheck." -ForegroundColor Green
