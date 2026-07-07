# Part of DeviceCheck.ps1. Dot-sourced by the root entrypoint; keep script-scope state shared.
# Purpose: AI model selection, screen clearing, and local credential persistence helpers.
function Initialize-AvailableModels {
    $script:AvailableModels = [System.Collections.Generic.List[object]]::new()

    $csvPath = Join-Path -Path $script:DeviceCheckRepoRoot -ChildPath 'data\google-ai-studio-rate-limits-only free.csv'
    $loadedFromCsv = $false

    if (Test-Path -LiteralPath $csvPath) {
        try {
            $csvData = Import-Csv -LiteralPath $csvPath
            # Filter rows where section is 'Models' and category is 'Text-out models' or it's Gemma in 'Other models'
            $filteredRows = $csvData | Where-Object {
                $_.section -eq 'Models' -and (
                    $_.category -eq 'Text-out models' -or
                    ($_.category -eq 'Other models' -and $_.model -like '*Gemma*')
                )
            }
            foreach ($row in $filteredRows) {
                if ([string]::IsNullOrWhiteSpace($row.model)) { continue }

                $apiName = $(if ($row.model -like '*Gemma*') {
                    if ($row.model -like '*26B*') { 'gemma-4-26b-a4b-it' } else { 'gemma-4-31b-it' }
                } else {
                    ($row.model -replace ' ', '-').ToLower()
                })

                # Check for duplicate API IDs
                $existing = $script:AvailableModels | Where-Object { $_.ApiId -eq $apiName }
                if ($null -ne $existing) { continue }

                $script:AvailableModels.Add([pscustomobject]@{
                    Provider     = 'Gemini'
                    FriendlyName = $row.model
                    ApiId        = $apiName
                    Selected     = ($apiName -eq 'gemini-3.1-flash-lite')
                    RpmLimit     = $row.rpm_limit
                    TpmLimit     = $row.tpm_limit
                    RpdLimit     = $row.rpd_limit
                })
            }
            if ($script:AvailableModels.Count -gt 0) {
                $loadedFromCsv = $true
            }
        } catch {
            # Fallback will run below
        }
    }

    if (-not $loadedFromCsv) {
        $fallbackModels = @(
            @{ Name = 'Gemini 3.1 Flash Lite'; Id = 'gemini-3.1-flash-lite'; Selected = $true; RPM = 15; TPM = 250000; RPD = 500 }
            @{ Name = 'Gemini 2.5 Flash'; Id = 'gemini-2.5-flash'; Selected = $false; RPM = 5; TPM = 250000; RPD = 20 }
            @{ Name = 'Gemini 3.5 Flash'; Id = 'gemini-3.5-flash'; Selected = $false; RPM = 5; TPM = 250000; RPD = 20 }
            @{ Name = 'Gemini 2.5 Flash Lite'; Id = 'gemini-2.5-flash-lite'; Selected = $false; RPM = 10; TPM = 250000; RPD = 20 }
            @{ Name = 'Gemini 3 Flash'; Id = 'gemini-3-flash'; Selected = $false; RPM = 5; TPM = 250000; RPD = 20 }
            @{ Name = 'Gemma 4 26B'; Id = 'gemma-4-26b-a4b-it'; Selected = $false; RPM = 15; TPM = 0; RPD = 1500 }
            @{ Name = 'Gemma 4 31B'; Id = 'gemma-4-31b-it'; Selected = $false; RPM = 15; TPM = 0; RPD = 1500 }
        )

        foreach ($m in $fallbackModels) {
            $script:AvailableModels.Add([pscustomobject]@{
                Provider     = 'Gemini'
                FriendlyName = $m.Name
                ApiId        = $m.Id
                Selected     = $m.Selected
                RpmLimit     = $m.RPM
                TpmLimit     = $m.TPM
                RpdLimit     = $m.RPD
            })
        }
    }

    # Add OpenRouter models
    $script:AvailableModels.Add([pscustomobject]@{
        Provider     = 'OpenRouter'
        FriendlyName = 'Nvidia Nemotron 3 Super 120B (Free)'
        ApiId        = 'nvidia/nemotron-3-super-120b-a12b:free'
        Selected     = $true
        RpmLimit     = ''
        TpmLimit     = ''
        RpdLimit     = ''
    })

    # Load persisted selection if exists
    $configPath = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'config.json'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            if ($null -ne $config) {
                if ($config.SelectedModelIds) {
                    $selectedIds = [System.Collections.Generic.HashSet[string]]::new([string[]]$config.SelectedModelIds, [System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($model in $script:AvailableModels) {
                        $model.Selected = $selectedIds.Contains($model.ApiId)
                    }
                }
                if ($null -ne $config.BenchmarkMode) {
                    $script:BenchmarkMode = [bool]$config.BenchmarkMode
                }
            }
        } catch {
            # Fallback to default selection if config is corrupt
        }
    }
}

function Save-ModelSelection {
    try {
        if (-not (Test-Path -LiteralPath $script:DeviceCheckCacheRoot)) {
            $null = New-Item -ItemType Directory -Path $script:DeviceCheckCacheRoot -Force
        }
        $selectedIds = @(
            $script:AvailableModels | Where-Object { $_.Selected } | ForEach-Object { $_.ApiId }
        )
        $config = [pscustomobject]@{
            SelectedModelIds = $selectedIds
            BenchmarkMode    = $script:BenchmarkMode
        }
        $configPath = Join-Path -Path $script:DeviceCheckCacheRoot -ChildPath 'config.json'
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    } catch {
        # Silent fallback
    }
}

function Clear-TuiScreen {
    try {
        [Console]::Clear()
    } catch {
        try {
            [Console]::Write("$([char]27)[H$([char]27)[2J$([char]27)[3J")
        } catch {
            try { Clear-Host } catch {}
        }
    }
}

function Get-DeviceCheckStoredCredential {
    param([string]$ComputerName)

    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return $null }
    $credRoot = $(if (-not [string]::IsNullOrWhiteSpace($script:DeviceCheckLocalStateRoot)) { $script:DeviceCheckLocalStateRoot } else { $script:DeviceCheckCacheRoot })
    $credFolder = Join-Path -Path $credRoot -ChildPath 'credentials'
    $credPath = Join-Path -Path $credFolder -ChildPath "$($ComputerName.ToLower()).xml"
    if (Test-Path -LiteralPath $credPath -PathType Leaf) {
        try {
            return Import-Clixml -Path $credPath -ErrorAction Stop
        } catch {
            return $null
        }
    }
    return $null
}

function Save-DeviceCheckStoredCredential {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName) -or $null -eq $Credential) { return }
    $credRoot = $(if (-not [string]::IsNullOrWhiteSpace($script:DeviceCheckLocalStateRoot)) { $script:DeviceCheckLocalStateRoot } else { $script:DeviceCheckCacheRoot })
    $credFolder = Join-Path -Path $credRoot -ChildPath 'credentials'
    try {
        $null = New-Item -ItemType Directory -Path $credFolder -Force -ErrorAction SilentlyContinue
        $credPath = Join-Path -Path $credFolder -ChildPath "$($ComputerName.ToLower()).xml"
        $Credential | Export-Clixml -Path $credPath
    } catch {}
}

function Remove-DeviceCheckStoredCredential {
    param([string]$ComputerName)

    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return }
    $credRoot = $(if (-not [string]::IsNullOrWhiteSpace($script:DeviceCheckLocalStateRoot)) { $script:DeviceCheckLocalStateRoot } else { $script:DeviceCheckCacheRoot })
    $credFolder = Join-Path -Path $credRoot -ChildPath 'credentials'
    $credPath = Join-Path -Path $credFolder -ChildPath "$($ComputerName.ToLower()).xml"
    if (Test-Path -LiteralPath $credPath -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $credPath -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    if ($null -ne $script:CredentialCache) {
        $script:CredentialCache.Remove($ComputerName.ToLower())
    }
}
