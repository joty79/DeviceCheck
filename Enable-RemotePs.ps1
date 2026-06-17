# Enable-RemotePs.ps1
# Run this script as Administrator on the target Windows machine to enable Remote PowerShell / WinRM.
[CmdletBinding()]
param(
    [string]$DeviceCheckUserName = 'dcadmin',
    [switch]$CreateDeviceCheckUser,
    [switch]$RemoveDeviceCheckUser,
    [switch]$NoUserPrompt
)

function Get-DeviceCheckPrincipalSource {
    param(
        [Parameter(Mandatory)]
        [object]$Member
    )

    $property = $Member.PSObject.Properties['PrincipalSource']
    if ($null -eq $property) {
        return ''
    }

    return [string]$property.Value
}

function Get-DeviceCheckLocalMemberName {
    param(
        [Parameter(Mandatory)]
        [object]$Member
    )

    $name = [string]$Member.Name
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }

    $computerPrefix = "$env:COMPUTERNAME\"
    if ($name.StartsWith($computerPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $name.Substring($computerPrefix.Length)
    }

    if ($name -notmatch '\\') {
        return $name
    }

    return $null
}

function Get-DeviceCheckRemoteAdminSummary {
    $enabledLocalUsers = @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Enabled })
    $enabledLocalUserMap = @{}
    foreach ($user in $enabledLocalUsers) {
        $enabledLocalUserMap[$user.Name.ToLowerInvariant()] = $user
    }

    $adminMembers = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue)
    $remoteManagementMembers = @(Get-LocalGroupMember -Group 'Remote Management Users' -ErrorAction SilentlyContinue)
    $usableLocalAdmins = @()
    $disabledLocalAdmins = @()
    $microsoftAccountAdmins = @()

    foreach ($member in $adminMembers) {
        $principalSource = Get-DeviceCheckPrincipalSource -Member $member
        if ($principalSource -eq 'MicrosoftAccount') {
            $microsoftAccountAdmins += $member
            continue
        }

        if ($principalSource -eq 'Local' -or [string]::IsNullOrWhiteSpace($principalSource)) {
            $localName = Get-DeviceCheckLocalMemberName -Member $member
            if ([string]::IsNullOrWhiteSpace($localName)) {
                continue
            }

            $lookupKey = $localName.ToLowerInvariant()
            if ($enabledLocalUserMap.ContainsKey($lookupKey)) {
                $usableLocalAdmins += $enabledLocalUserMap[$lookupKey]
            } else {
                $disabledLocalAdmins += $localName
            }
        }
    }

    [pscustomobject]@{
        EnabledLocalUsers       = $enabledLocalUsers
        AdminMembers            = $adminMembers
        RemoteManagementMembers = $remoteManagementMembers
        UsableLocalAdmins       = $usableLocalAdmins
        DisabledLocalAdmins     = $disabledLocalAdmins
        MicrosoftAccountAdmins  = $microsoftAccountAdmins
    }
}

function Add-DeviceCheckUserToGroup {
    param(
        [Parameter(Mandatory)]
        [string]$UserName,

        [Parameter(Mandatory)]
        [string]$GroupName
    )

    try {
        $existing = @(Get-LocalGroupMember -Group $GroupName -ErrorAction Stop | Where-Object {
                $_.Name -eq "$env:COMPUTERNAME\$UserName" -or $_.Name -eq $UserName
            })

        if ($existing.Count -eq 0) {
            Add-LocalGroupMember -Group $GroupName -Member $UserName -ErrorAction Stop
            Write-Host "✅ Added '$UserName' to '$GroupName'." -ForegroundColor Green
        } else {
            Write-Host "✅ '$UserName' is already in '$GroupName'." -ForegroundColor Green
        }
    } catch {
        Write-Warning "Failed to add '$UserName' to '$GroupName' with LocalAccounts cmdlets: $_"
        try {
            $group = [ADSI]"WinNT://$env:COMPUTERNAME/$GroupName,group"
            $group.Add("WinNT://$env:COMPUTERNAME/$UserName,user")
            Write-Host "✅ Added '$UserName' to '$GroupName' through ADSI." -ForegroundColor Green
        } catch {
            $message = $_.Exception.Message
            if ($message -match 'already|member') {
                Write-Host "✅ '$UserName' appears to already be in '$GroupName'." -ForegroundColor Green
            } else {
                Write-Warning "Failed to add '$UserName' to '$GroupName' through ADSI: $_"
            }
        }
    }
}

function ConvertTo-DeviceCheckPlainText {
    param(
        [Parameter(Mandatory)]
        [securestring]$SecureString
    )

    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Test-DeviceCheckLocalUserExists {
    param(
        [Parameter(Mandatory)]
        [string]$UserName
    )

    try {
        $user = Get-LocalUser -Name $UserName -ErrorAction Stop
        return ($null -ne $user)
    } catch {
        try {
            return [System.DirectoryServices.DirectoryEntry]::Exists("WinNT://$env:COMPUTERNAME/$UserName,user")
        } catch {
            try {
                $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
                foreach ($child in @($computer.Children)) {
                    if ($child.SchemaClassName -eq 'User' -and [string]::Equals([string]$child.Name, $UserName, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return $true
                    }
                }
            } catch {
            }
        }
    }

    return $false
}

function Test-DeviceCheckSafeUserProfilePath {
    param(
        [Parameter(Mandatory)]
        [string]$UserName,

        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $usersRoot = [System.IO.Path]::GetFullPath((Join-Path $env:SystemDrive 'Users') + [System.IO.Path]::DirectorySeparatorChar)
        $candidatePath = [System.IO.Path]::GetFullPath($Path)
        $leaf = Split-Path -Path $candidatePath -Leaf

        if (-not $candidatePath.StartsWith($usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }

        if ([string]::Equals($leaf, $UserName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        return $leaf.StartsWith("$UserName.", [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Get-DeviceCheckUserProfileCandidates {
    param(
        [Parameter(Mandatory)]
        [string]$UserName
    )

    $candidates = [System.Collections.Generic.List[object]]::new()

    try {
        $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | Where-Object {
                -not $_.Special -and
                -not [string]::IsNullOrWhiteSpace($_.LocalPath) -and
                (Test-DeviceCheckSafeUserProfilePath -UserName $UserName -Path $_.LocalPath)
            })

        foreach ($profile in $profiles) {
            $candidates.Add([pscustomobject]@{
                    Kind      = 'CimProfile'
                    Path      = [string]$profile.LocalPath
                    Sid       = [string]$profile.SID
                    Loaded    = [bool]$profile.Loaded
                    CimObject = $profile
                })
        }
    } catch {
        Write-Warning "Failed to query Win32_UserProfile for '$UserName': $_"
    }

    $knownPaths = @{}
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate.Path)) {
            $knownPaths[$candidate.Path.ToLowerInvariant()] = $true
        }
    }

    $usersRoot = Join-Path $env:SystemDrive 'Users'
    foreach ($pattern in @($UserName, "$UserName.*")) {
        try {
            $folders = @(Get-ChildItem -LiteralPath $usersRoot -Directory -Force -Filter $pattern -ErrorAction SilentlyContinue)
            foreach ($folder in $folders) {
                if (-not (Test-DeviceCheckSafeUserProfilePath -UserName $UserName -Path $folder.FullName)) {
                    continue
                }

                if ($knownPaths.ContainsKey($folder.FullName.ToLowerInvariant())) {
                    continue
                }

                $candidates.Add([pscustomobject]@{
                        Kind      = 'Folder'
                        Path      = [string]$folder.FullName
                        Sid       = ''
                        Loaded    = $false
                        CimObject = $null
                    })
            }
        } catch {
            Write-Warning "Failed to inspect profile folders matching '$pattern': $_"
        }
    }

    return @($candidates)
}

function Remove-DeviceCheckUserProfiles {
    param(
        [Parameter(Mandatory)]
        [string]$UserName
    )

    $candidates = @(Get-DeviceCheckUserProfileCandidates -UserName $UserName)
    if ($candidates.Count -eq 0) {
        Write-Host "No '$UserName' profile folders found." -ForegroundColor Gray
        return
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-DeviceCheckSafeUserProfilePath -UserName $UserName -Path $candidate.Path)) {
            Write-Warning "Skipping unsafe profile path '$($candidate.Path)'."
            continue
        }

        if ($candidate.Loaded) {
            Write-Warning "Skipping loaded profile '$($candidate.Path)'. Sign out that user/session and run cleanup again."
            continue
        }

        if ($candidate.Kind -eq 'CimProfile' -and $null -ne $candidate.CimObject) {
            try {
                Remove-CimInstance -InputObject $candidate.CimObject -ErrorAction Stop
                Write-Host "✅ Removed Windows profile '$($candidate.Path)'." -ForegroundColor Green
                continue
            } catch {
                Write-Warning "Failed to remove Windows profile '$($candidate.Path)' through Win32_UserProfile: $_"
            }
        }

        if (Test-Path -LiteralPath $candidate.Path) {
            try {
                Remove-Item -LiteralPath $candidate.Path -Recurse -Force -ErrorAction Stop
                Write-Host "✅ Removed leftover profile folder '$($candidate.Path)'." -ForegroundColor Green
            } catch {
                Write-Warning "Failed to remove leftover profile folder '$($candidate.Path)': $_"
            }
        }
    }
}

function New-DeviceCheckLocalUserWithAdsi {
    param(
        [Parameter(Mandatory)]
        [string]$UserName,

        [securestring]$Password,

        [Parameter(Mandatory)]
        [bool]$NoPassword,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
    $user = $computer.Create('user', $UserName)

    try {
        if ($NoPassword) {
            $user.SetPassword('')
        } else {
            if ($null -eq $Password) {
                throw "Password was not supplied for '$UserName'."
            }

            $plainPassword = ConvertTo-DeviceCheckPlainText -SecureString $Password
            $user.SetPassword($plainPassword)
        }

        $user.Put('FullName', 'DeviceCheck temporary admin')
        $user.Put('Description', $Description)
        $user.Put('UserFlags', 0x10020)
        $user.SetInfo()
    } catch {
        try {
            $computer.Delete('user', $UserName)
        } catch {
        }
        throw
    }
}

function New-DeviceCheckTemporaryAdmin {
    param(
        [Parameter(Mandatory)]
        [string]$UserName
    )

    $description = 'DeviceCheck WinRM snapshots'
    $existingUser = $null
    try {
        $existingUser = Get-LocalUser -Name $UserName -ErrorAction Stop
    } catch {
        if (Test-DeviceCheckLocalUserExists -UserName $UserName) {
            $existingUser = [pscustomobject]@{
                Name    = $UserName
                Enabled = $true
            }
        }
    }
    if ($null -eq $existingUser) {
        Write-Host "Creating local DeviceCheck admin user '$UserName'..." -ForegroundColor White
        $password = Read-Host "Password for $UserName (press Enter for no password)" -AsSecureString

        $useNoPassword = $password.Length -eq 0
        try {
            if ($useNoPassword) {
                New-LocalUser `
                    -Name $UserName `
                    -NoPassword `
                    -FullName 'DeviceCheck temporary admin' `
                    -Description $description `
                    -AccountNeverExpires `
                    -ErrorAction Stop | Out-Null
            } else {
                New-LocalUser `
                    -Name $UserName `
                    -Password $password `
                    -FullName 'DeviceCheck temporary admin' `
                    -Description $description `
                    -AccountNeverExpires `
                    -ErrorAction Stop | Out-Null
            }
        } catch {
            Write-Warning "New-LocalUser failed in this PowerShell host: $_"
            Write-Host "Retrying user creation through ADSI WinNT provider..." -ForegroundColor Yellow
            New-DeviceCheckLocalUserWithAdsi `
                -UserName $UserName `
                -Password $password `
                -NoPassword $useNoPassword `
                -Description $description
        }

        if (-not (Test-DeviceCheckLocalUserExists -UserName $UserName)) {
            throw "New-LocalUser did not create '$UserName'."
        }

        Write-Host "✅ Local user '$UserName' created." -ForegroundColor Green
    } else {
        Write-Host "Local user '$UserName' already exists." -ForegroundColor Yellow
        if ($existingUser.PSObject.Properties['Enabled'] -and -not $existingUser.Enabled) {
            Enable-LocalUser -Name $UserName -ErrorAction Stop
            Write-Host "✅ Local user '$UserName' enabled." -ForegroundColor Green
        }
    }

    Add-DeviceCheckUserToGroup -UserName $UserName -GroupName 'Administrators'
    Add-DeviceCheckUserToGroup -UserName $UserName -GroupName 'Remote Management Users'
}

function Remove-DeviceCheckTemporaryAdmin {
    param(
        [Parameter(Mandatory)]
        [string]$UserName
    )

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($currentIdentity -eq "$env:COMPUTERNAME\$UserName" -or $currentIdentity.EndsWith("\$UserName", [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "Refusing to remove '$UserName' because this PowerShell session is running as that user."
        return
    }

    $userExists = Test-DeviceCheckLocalUserExists -UserName $UserName
    $profileCandidates = @(Get-DeviceCheckUserProfileCandidates -UserName $UserName)

    if ($userExists) {
        try {
            Remove-LocalUser -Name $UserName -ErrorAction Stop
        } catch {
            Write-Warning "Remove-LocalUser failed in this PowerShell host: $_"
            Write-Host "Retrying user removal through ADSI WinNT provider..." -ForegroundColor Yellow
            $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
            $computer.Delete('user', $UserName)
        }
        Write-Host "✅ Local user '$UserName' removed." -ForegroundColor Green
    } elseif ($profileCandidates.Count -eq 0) {
        Write-Host "Local user '$UserName' and matching profile folders do not exist. Nothing to remove." -ForegroundColor Yellow
        return
    }

    Remove-DeviceCheckUserProfiles -UserName $UserName
}

function Invoke-DeviceCheckUserCleanupPrompt {
    param(
        [Parameter(Mandatory)]
        [string]$UserName
    )

    $userExists = Test-DeviceCheckLocalUserExists -UserName $UserName
    $profileCandidates = @(Get-DeviceCheckUserProfileCandidates -UserName $UserName)

    if (-not $userExists -and $profileCandidates.Count -eq 0) {
        return $false
    }

    if ($userExists) {
        Write-Host "Temporary DeviceCheck user '$UserName' exists on this PC." -ForegroundColor Yellow
    }

    if ($profileCandidates.Count -gt 0) {
        Write-Host "Matching profile folder(s) found:" -ForegroundColor Yellow
        foreach ($candidate in $profileCandidates) {
            Write-Host "  - $($candidate.Path)" -ForegroundColor Gray
        }
    }

    $answer = Read-Host "Remove '$UserName' and matching profile folders now? (Y/N)"
    if ($answer -match '^[YyΝν]') {
        Remove-DeviceCheckTemporaryAdmin -UserName $UserName
        return $true
    }

    return $false
}

function Invoke-DeviceCheckRemoteAdminPreflight {
    param(
        [Parameter(Mandatory)]
        [string]$UserName
    )

    Write-Host "Checking local administrator accounts for WinRM..." -ForegroundColor White
    $summary = Get-DeviceCheckRemoteAdminSummary

    if ($CreateDeviceCheckUser) {
        if ($summary.UsableLocalAdmins.Count -gt 0) {
            Write-Host "Enabled local administrator account(s) already exist; ensuring requested DeviceCheck user '$UserName' too." -ForegroundColor Yellow
        }
        New-DeviceCheckTemporaryAdmin -UserName $UserName
        return
    }

    if ($summary.UsableLocalAdmins.Count -gt 0) {
        Write-Host "✅ Enabled local administrator account(s) found:" -ForegroundColor Green
        foreach ($admin in $summary.UsableLocalAdmins) {
            Write-Host "  - $env:COMPUTERNAME\$($admin.Name)" -ForegroundColor Gray
        }
        return
    }

    if ($summary.MicrosoftAccountAdmins.Count -gt 0) {
        Write-Host "⚠️ Microsoft Account administrator(s) found, but they are not reliable for this WinRM workflow:" -ForegroundColor Yellow
        foreach ($admin in $summary.MicrosoftAccountAdmins) {
            Write-Host "  - $($admin.Name)" -ForegroundColor Gray
        }
    }

    if ($summary.DisabledLocalAdmins.Count -gt 0) {
        Write-Host "Disabled local administrator account(s) found:" -ForegroundColor Yellow
        foreach ($adminName in $summary.DisabledLocalAdmins) {
            Write-Host "  - $env:COMPUTERNAME\$adminName" -ForegroundColor Gray
        }
    }

    if ($NoUserPrompt) {
        Write-Warning "No enabled local administrator user was found. Use -CreateDeviceCheckUser or create one manually before connecting over WinRM."
        return
    }

    $answer = Read-Host "Create temporary local admin '$UserName' for DeviceCheck WinRM snapshots? (Y/N)"
    if ($answer -match '^[YyΝν]') {
        New-DeviceCheckTemporaryAdmin -UserName $UserName
    } else {
        Write-Warning "No local WinRM admin user was created. Remote snapshots may fail unless you already know a usable local/domain admin credential."
    }
}

# 1. Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script MUST be run as Administrator! Please reopen PowerShell as Administrator."
    Exit
}

if ($RemoveDeviceCheckUser) {
    Remove-DeviceCheckTemporaryAdmin -UserName $DeviceCheckUserName
    Exit
}

if (-not $CreateDeviceCheckUser -and -not $NoUserPrompt) {
    if (Invoke-DeviceCheckUserCleanupPrompt -UserName $DeviceCheckUserName) {
        Exit
    }
}

Write-Host "Starting Remote PowerShell configuration..." -ForegroundColor Cyan
Invoke-DeviceCheckRemoteAdminPreflight -UserName $DeviceCheckUserName

# 2. Check and change network profile categories to Private
Write-Host "Checking network adapters and profile categories..." -ForegroundColor White
$requiresSkipNetworkProfileCheck = $false

try {
    # Get all active IPv4 interfaces (excluding loopback)
    $activeInterfaces = Get-NetIPInterface -AddressFamily IPv4 -ConnectionState Connected | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' }
    
    foreach ($interface in $activeInterfaces) {
        $profile = Get-NetConnectionProfile -InterfaceIndex $interface.InterfaceIndex -ErrorAction SilentlyContinue
        
        if ($profile) {
            Write-Host "Network Adapter: $($interface.InterfaceAlias) [Index: $($interface.InterfaceIndex)]" -ForegroundColor Gray
            Write-Host "  Profile Name: $($profile.Name)" -ForegroundColor Gray
            Write-Host "  Category    : $($profile.NetworkCategory)" -ForegroundColor Gray
            
            if ($profile.NetworkCategory -eq 'Public') {
                Write-Host "  Attempting to change Network Category to Private..." -ForegroundColor White
                try {
                    Set-NetConnectionProfile -InterfaceIndex $interface.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
                    Write-Host "  ✅ Category successfully changed to Private." -ForegroundColor Green
                } catch {
                    Write-Warning "  ❌ Failed to set category to Private: $_"
                    $requiresSkipNetworkProfileCheck = $true
                }
            }
        } else {
            # Active adapter with no NLA connection profile (unidentified network)
            Write-Host "⚠️ Warning: Network Adapter '$($interface.InterfaceAlias)' [Index: $($interface.InterfaceIndex)] has no active connection profile." -ForegroundColor Yellow
            Write-Host "  Windows treats Unidentified Networks as PUBLIC by default, which blocks WinRM." -ForegroundColor Yellow
            $requiresSkipNetworkProfileCheck = $true
        }
    }
} catch {
    Write-Warning "Failed to inspect network interfaces: $_"
    $requiresSkipNetworkProfileCheck = $true
}

# 3. Enable PowerShell Remoting and quick config
Write-Host "Enabling PowerShell Remoting..." -ForegroundColor White
try {
    if ($requiresSkipNetworkProfileCheck) {
        Write-Host "Note: Bypassing network profile checks due to Public or Unidentified network adapters..." -ForegroundColor Yellow
        Enable-PSRemoting -SkipNetworkProfileCheck -Force -ErrorAction Stop
        Set-WSManQuickConfig -SkipNetworkProfileCheck -Force -ErrorAction Stop
    } else {
        Enable-PSRemoting -Force -ErrorAction Stop
        Set-WSManQuickConfig -Force -ErrorAction Stop
    }
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

# 6. Configure LocalAccountTokenFilterPolicy (UAC Remote Restrictions bypass)
Write-Host "Configuring registry settings for local administrator WinRM access..." -ForegroundColor White
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

    Write-Host "Note: Passwordless local accounts are enabled by default for the DeviceCheck shop/workbench workflow." -ForegroundColor Yellow

    if (-not (Test-Path -Path $lsaPath)) {
        New-Item -Path $lsaPath -Force | Out-Null
    }

    if (-not (Get-ItemProperty -Path $lsaPath -Name $blankPasswordValueName -ErrorAction SilentlyContinue)) {
        New-ItemProperty -Path $lsaPath -Name $blankPasswordValueName -Value 0 -PropertyType DWord -Force | Out-Null
    } else {
        Set-ItemProperty -Path $lsaPath -Name $blankPasswordValueName -Value 0 -Type DWord -Force | Out-Null
    }
    Write-Host "✅ LimitBlankPasswordUse configured successfully (blank passwords allowed remotely)." -ForegroundColor Green
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
Write-Host "Use '$env:COMPUTERNAME\$DeviceCheckUserName' if you created the temporary DeviceCheck user." -ForegroundColor Cyan
Write-Host "After finishing snapshots, remove it with: .\Enable-RemotePs.ps1 -RemoveDeviceCheckUser -DeviceCheckUserName $DeviceCheckUserName" -ForegroundColor Cyan
