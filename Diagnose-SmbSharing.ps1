#requires -version 5.1
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$NonInteractive
)

# 1. Elevate to Administrator if not already running as one
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "=========================================================" -ForegroundColor Yellow
    Write-Host "⚠️🚨 [WARN] Αυτό το σενάριο απαιτεί δικαιώματα Administrator! 🚨⚠️" -ForegroundColor Yellow
    Write-Host "=========================================================" -ForegroundColor Yellow
    Write-Host "Προσπάθεια αυτόματης επανεκκίνησης ως Διαχειριστής..." -ForegroundColor Cyan
    
    $psExe = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh.exe' } else { 'powershell.exe' })
    $gsudo = Get-Command gsudo.exe -ErrorAction SilentlyContinue
    
    if ($null -ne $gsudo) {
        $proc = Start-Process -FilePath $gsudo.Source -ArgumentList "`"$psExe`" -NoProfile -File `"$PSCommandPath`"" -Wait -PassThru
    } else {
        $proc = Start-Process -FilePath $psExe -ArgumentList "-NoProfile -File `"$PSCommandPath`"" -Verb RunAs -Wait -PassThru
    }
    
    exit (if ($null -ne $proc) { $proc.ExitCode } else { 0 })
}

# Clear screen for readability
Clear-Host

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "🔵 Διάγνωση & Επιδιόρθωση Κοινής Χρήσης Αρχείων (SMB Sharing) 🔵" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

$issues = [System.Collections.Generic.List[object]]::new()

# --- 1. Δίκτυο & Προφίλ (Network Category) ---
Write-Host "🔸 1. Έλεγχος Προφίλ Δικτύου (Network Categories)..." -ForegroundColor Cyan
$interfaces = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet' }

$publicAdapters = @()
if ($interfaces) {
    $profiles = Get-NetConnectionProfile -InterfaceIndex $interfaces.InterfaceIndex -ErrorAction SilentlyContinue
    foreach ($profile in $profiles) {
        if ($profile.NetworkCategory -eq 'Public') {
            $publicAdapters += $profile
            Write-Host "   [WARN] Η κάρτα δικτύου '$($profile.InterfaceAlias)' είναι ρυθμισμένη ως Public!" -ForegroundColor Yellow
        } else {
            Write-Host "   [OK] Η κάρτα δικτύου '$($profile.InterfaceAlias)' είναι ρυθμισμένη ως $($profile.NetworkCategory)." -ForegroundColor Green
        }
    }
} else {
    Write-Host "   [WARN] Δεν βρέθηκαν ενεργές κάρτες δικτύου IPv4." -ForegroundColor Yellow
}

if ($publicAdapters.Count -gt 0) {
    $issues.Add([PSCustomObject]@{
        Category    = 'NetworkProfile'
        Description = "Αλλαγή του προφίλ δικτύου σε Private για $($publicAdapters.Count) κάρτα/ες"
        Action      = {
            foreach ($p in $publicAdapters) {
                Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
                Write-Host "   [+] Το προφίλ για την κάρτα '$($p.InterfaceAlias)' άλλαξε σε Private." -ForegroundColor Green
            }
        }
    })
}
Write-Host ""

# --- 2. Firewall (SMB Inbound Rules) ---
Write-Host "🔸 2. Έλεγχος Τείχους Προστασίας (Firewall)..." -ForegroundColor Cyan

# We check if SMB inbound rule is enabled
$smbRules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.DisplayGroup -eq "File and Printer Sharing" -or $_.Group -eq "@FirewallAPI.dll,-28502") -and
        ($_.Name -like "*SMB-In*" -or $_.DisplayName -like "*SMB-In*")
    }

$smbEnabled = $smbRules | Where-Object { $_.Enabled -eq 'True' }

if (-not $smbEnabled) {
    Write-Host "   [WARN] Οι κανόνες του Firewall για την Κοινή Χρήση Αρχείων (SMB-In) είναι απενεργοποιημένοι!" -ForegroundColor Yellow
    $issues.Add([PSCustomObject]@{
        Category    = 'FirewallSMB'
        Description = "Ενεργοποίηση των κανόνων Firewall για την Κοινή Χρήση Αρχείων (SMB)"
        Action      = {
            if ($smbRules) {
                foreach ($r in $smbRules) {
                    Enable-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
                }
            }
            Enable-NetFirewallRule -Group "@FirewallAPI.dll,-28502" -ErrorAction SilentlyContinue
            Write-Host "   [+] Οι κανόνες Firewall για την Κοινή Χρήση Αρχείων (SMB-In) ενεργοποιήθηκαν." -ForegroundColor Green
        }
    })
} else {
    Write-Host "   [OK] Οι κανόνες Firewall για την Κοινή Χρήση Αρχείων (SMB) είναι ενεργοποιημένοι." -ForegroundColor Green
}

# Check Network Discovery Rules
$ndRules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object {
        $_.DisplayGroup -eq "Network Discovery" -or $_.Group -eq "@FirewallAPI.dll,-32752"
    }

$ndEnabled = $ndRules | Where-Object { $_.Enabled -eq 'True' }

if (-not $ndEnabled) {
    Write-Host "   [WARN] Οι κανόνες του Firewall για την Ανακάλυψη Δικτύου (Network Discovery) είναι απενεργοποιημένοι!" -ForegroundColor Yellow
    $issues.Add([PSCustomObject]@{
        Category    = 'FirewallDiscovery'
        Description = "Ενεργοποίηση των κανόνων Firewall για την Ανακάλυψη Δικτύου (Network Discovery)"
        Action      = {
            if ($ndRules) {
                foreach ($r in $ndRules) {
                    Enable-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
                }
            }
            Enable-NetFirewallRule -Group "@FirewallAPI.dll,-32752" -ErrorAction SilentlyContinue
            Write-Host "   [+] Οι κανόνες Firewall για το Network Discovery ενεργοποιήθηκαν." -ForegroundColor Green
        }
    })
} else {
    Write-Host "   [OK] Οι κανόνες Firewall για την Ανακάλυψη Δικτύου (Network Discovery) είναι ενεργοποιημένοι." -ForegroundColor Green
}
Write-Host ""

# --- 3. Υπηρεσίες (Windows Services) ---
Write-Host "🔸 3. Έλεγχος Υπηρεσιών (Windows Services)..." -ForegroundColor Cyan

$servicesToCheck = @(
    @{ Name = 'LanmanServer'; Desc = 'Server (SMB Share Service)' }
    @{ Name = 'LanmanWorkstation'; Desc = 'Workstation (SMB Client Service)' }
    @{ Name = 'lmhosts'; Desc = 'TCP/IP NetBIOS Helper' }
    @{ Name = 'fdPHost'; Desc = 'Function Discovery Provider Host' }
    @{ Name = 'FDResPub'; Desc = 'Function Discovery Resource Publication' }
    @{ Name = 'SSDPSrv'; Desc = 'SSDP Discovery' }
    @{ Name = 'upnphost'; Desc = 'UPnP Device Host' }
)

$servicesToFix = [System.Collections.Generic.List[object]]::new()

foreach ($s in $servicesToCheck) {
    $service = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Write-Host "   [FAIL] Η υπηρεσία '$($s.Name)' ($($s.Desc)) δεν βρέθηκε στο σύστημα!" -ForegroundColor Red
        continue
    }

    $status = $service.Status
    $startType = $service.StartType

    if ($status -ne 'Running' -or $startType -ne 'Automatic') {
        Write-Host "   [WARN] Υπηρεσία '$($s.Name)' ($($s.Desc)): Κατάσταση = $status, Τύπος Εκκίνησης = $startType" -ForegroundColor Yellow
        $servicesToFix.Add($s)
    } else {
        Write-Host "   [OK] Υπηρεσία '$($s.Name)' ($($s.Desc)) λειτουργεί κανονικά." -ForegroundColor Green
    }
}

if ($servicesToFix.Count -gt 0) {
    $issues.Add([PSCustomObject]@{
        Category    = 'Services'
        Description = "Ρύθμιση σε Automatic και εκκίνηση $($servicesToFix.Count) υπηρεσιών ($(($servicesToFix.Name) -join ', '))"
        Action      = {
            foreach ($s in $servicesToFix) {
                Set-Service -Name $s.Name -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service -Name $s.Name -ErrorAction SilentlyContinue
                Write-Host "   [+] Η υπηρεσία '$($s.Name)' ρυθμίστηκε σε Automatic και εκκινήθηκε." -ForegroundColor Green
            }
        }
    })
}
Write-Host ""

# --- 4. Πρωτόκολλο SMB (SMB Protocol Configuration) ---
Write-Host "🔸 4. Έλεγχος Πρωτοκόλλου SMB (SMB Protocol)..." -ForegroundColor Cyan
try {
    $smbConfig = Get-SmbServerConfiguration -ErrorAction Stop
    $smb2Enabled = $smbConfig.EnableSMB2Protocol
    
    if (-not $smb2Enabled) {
        Write-Host "   [WARN] Το πρωτόκολλο SMBv2/v3 (Server) είναι απενεργοποιημένο!" -ForegroundColor Yellow
        $issues.Add([PSCustomObject]@{
            Category    = 'SmbProtocol'
            Description = "Ενεργοποίηση του πρωτοκόλλου SMBv2/v3"
            Action      = {
                Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force -ErrorAction SilentlyContinue
                Write-Host "   [+] Το πρωτόκολλο SMBv2/v3 ενεργοποιήθηκε." -ForegroundColor Green
            }
        })
    } else {
        Write-Host "   [OK] Το πρωτόκολλο SMBv2/v3 είναι ενεργοποιημένο." -ForegroundColor Green
    }
} catch {
    Write-Warning "Αποτυχία ελέγχου SMB Server Configuration: $_"
}
Write-Host ""

# --- 5. Πολιτική Blank Passwords (Blank Password Policy) ---
Write-Host "🔸 5. Έλεγχος Πολιτικής Blank Passwords (LimitBlankPasswordUse)..." -ForegroundColor Cyan
try {
    $lsaPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    $valueName = "LimitBlankPasswordUse"
    $regValue = Get-ItemProperty -Path $lsaPath -Name $valueName -ErrorAction SilentlyContinue
    
    $limitBlankPassword = $true
    if ($null -ne $regValue -and $regValue.$valueName -eq 0) {
        $limitBlankPassword = $false
    }
    
    if ($limitBlankPassword) {
        Write-Host "   [WARN] Η πολιτική 'Limit local account use of blank passwords to console logon only' είναι ενεργή (LimitBlankPasswordUse = 1)!" -ForegroundColor Yellow
        Write-Host "          Αυτό μπλοκάρει την εμφάνιση των κοινόχρηστων φακέλων (\\PC_NAME) όταν χρησιμοποιείται λογαριασμός χωρίς κωδικό!" -ForegroundColor Yellow
        
        $issues.Add([PSCustomObject]@{
            Category    = 'LimitBlankPassword'
            Description = "Απενεργοποίηση της πολιτικής LimitBlankPasswordUse (Να επιτρέπεται η σύνδεση/εμφάνιση με κενό κωδικό)"
            Action      = {
                if (-not (Test-Path -Path $lsaPath)) {
                    New-Item -Path $lsaPath -Force | Out-Null
                }
                New-ItemProperty -Path $lsaPath -Name $valueName -Value 0 -PropertyType DWord -Force | Out-Null
                Write-Host "   [+] Η πολιτική LimitBlankPasswordUse απενεργοποιήθηκε επιτυχώς (ορίστηκε σε 0)." -ForegroundColor Green
            }
        })
    } else {
        Write-Host "   [OK] Η πολιτική LimitBlankPasswordUse είναι απενεργοποιημένη (επιτρέπεται η χρήση κενών κωδικών απομακρυσμένα)." -ForegroundColor Green
    }
} catch {
    Write-Warning "Αποτυχία ελέγχου LimitBlankPasswordUse: $_"
}
Write-Host ""

# --- 6. Εφαρμογή Διορθώσεων ---
if ($issues.Count -eq 0) {
    Write-Host "=========================================================" -ForegroundColor Green
    Write-Host "✅ Όλες οι ρυθμίσεις είναι σωστές! Δεν βρέθηκαν προβλήματα." -ForegroundColor Green
    Write-Host "=========================================================" -ForegroundColor Green
    if (-not $NonInteractive) {
        Read-Host "Πατήστε Enter για έξοδο..."
    }
    exit 0
}

Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host "⚠️ Βρέθηκαν $($issues.Count) θέματα που χρήζουν επιδιόρθωσης:" -ForegroundColor Yellow
foreach ($issue in $issues) {
    Write-Host "   - $($issue.Description)" -ForegroundColor Yellow
}
Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host ""

$applyFixes = $Fix
if (-not $applyFixes -and -not $NonInteractive) {
    $response = Read-Host "Θέλετε να εφαρμόσετε τις διορθώσεις αυτόματα; (Y/N)"
    if ($response -match '^[YyΝν]') {
        $applyFixes = $true
    }
}

if ($applyFixes) {
    Write-Host "Εφαρμογή διορθώσεων..." -ForegroundColor Cyan
    foreach ($issue in $issues) {
        & $issue.Action
    }
    Write-Host ""
    Write-Host "✅ Οι διορθώσεις εφαρμόστηκαν επιτυχώς! Παρακαλώ δοκιμάστε να συνδεθείτε ξανά." -ForegroundColor Green
} else {
    Write-Host "Οι διορθώσεις δεν εφαρμόστηκαν." -ForegroundColor Gray
}

if (-not $NonInteractive) {
    Read-Host "Πατήστε Enter για έξοδο..."
}
