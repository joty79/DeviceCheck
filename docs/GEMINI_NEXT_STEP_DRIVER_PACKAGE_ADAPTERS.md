# Gemini Next Step - Driver Package Adapter Layer

## Active Repo

- Repo: `D:\Users\joty79\scripts\DeviceCheck`
- Platform: Windows 10/11, PowerShell 7
- Current date context: 2026-06-03

## Current Goal

Συνέχισε το driver-finding work χωρίς να κάνεις download, install, update ή remove drivers.

Το repo έχει ήδη:

- readable `Device Inventory`
- `Find Driver Candidates` search-link layer
- local `Installed INF Matches`
- unified `Driver Evidence Bundle`
- readable terminal `Device View`
- `DriverResearchTrust` readiness score
- `DriverCandidatePackage` metadata schema/template/validator
- skeleton-only adapter collection plan για `MicrosoftCatalog`, `OEM`, `DriverPack`

## Files To Read First

1. `PROJECT_RULES.md`
2. `README.md`
3. `CHANGELOG.md`
4. `config\driver-candidate-package.schema.json`
5. `config\driver-package-source-adapters.json`
6. `internal\Test-DriverCandidatePackageMetadata.ps1`
7. `internal\New-DriverPackageMetadataCollectionPlan.ps1`
8. `internal\New-DriverEvidenceBundle.ps1`

## Safety Contract

Μην υλοποιήσεις downloader ή installer.

Allowed:

- read local JSON/Markdown/script/config files
- generate metadata templates
- generate collection plans
- validate manually supplied metadata JSON
- add read-only parser skeletons
- document next implementation gates

Not allowed yet:

- web scraping
- Microsoft Catalog package downloads
- OEM package downloads
- SDIO driverpack extraction
- `pnputil` install/update/delete
- driver store modification
- registry driver cleanup
- automatic driver recommendation beyond manual review readiness

All new outputs must keep these flags false:

- `AllowsNetwork`
- `AllowsDownload`
- `AllowsAutomaticInstall`
- `AllowsDriverRemoval`

## Current Commands That Should Work

```powershell
pwsh -ExecutionPolicy Bypass -File .\internal\New-DriverEvidenceBundle.ps1 -Filter Camera -NoReport -AsJson
pwsh -ExecutionPolicy Bypass -File .\internal\Show-DriverEvidenceView.ps1 -Refresh -Filter Camera -DeviceIndex 1
pwsh -ExecutionPolicy Bypass -File .\internal\Test-DriverCandidatePackageMetadata.ps1 -CreateTemplate -Filter Camera
pwsh -ExecutionPolicy Bypass -File .\internal\Test-DriverCandidatePackageMetadata.ps1 -CreateTemplate -Filter Camera -AsJson
pwsh -ExecutionPolicy Bypass -File .\internal\New-DriverPackageMetadataCollectionPlan.ps1 -Filter Camera
pwsh -ExecutionPolicy Bypass -File .\internal\New-DriverPackageMetadataCollectionPlan.ps1 -Filter Camera -Adapter MicrosoftCatalog -AsJson
```

## Recommended Next Implementation

Build the first read-only adapter-specific metadata parser as a **stub with fixture input**, not live web scraping.

Recommended order:

1. Add `fixtures\driver-package-metadata\` with one tiny manually crafted Microsoft Catalog-like metadata JSON fixture.
2. Add `internal\ConvertFrom-MicrosoftCatalogMetadataFixture.ps1`.
3. The script should read local fixture JSON only and output a `DriverCandidatePackage` metadata object matching `config\driver-candidate-package.schema.json`.
4. Run it through `internal\Test-DriverCandidatePackageMetadata.ps1`.
5. Keep output under ignored `driver-package-metadata\`.

Do not browse Microsoft Catalog yet. Do not download `.cab` files yet.

## Validation Checklist

Run parser validation:

```powershell
$files = @(
  '.\DeviceCheck.ps1',
  '.\internal\Test-DriverCandidatePackageMetadata.ps1',
  '.\internal\New-DriverPackageMetadataCollectionPlan.ps1'
)
foreach ($file in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) > $null
  if ($errors.Count -gt 0) {
    $errors
    throw "Parser errors in $file"
  }
}
```

Run smoke tests:

```powershell
pwsh -ExecutionPolicy Bypass -File .\internal\New-DriverPackageMetadataCollectionPlan.ps1 -Filter Camera -Adapter MicrosoftCatalog -NoReport -AsJson | ConvertFrom-Json
pwsh -ExecutionPolicy Bypass -File .\internal\Test-DriverCandidatePackageMetadata.ps1 -CreateTemplate -Filter Camera -NoReport -AsJson | ConvertFrom-Json
git diff --check
```

## Documentation Rules

If behavior changes, update:

- `README.md`
- `CHANGELOG.md`
- `PROJECT_RULES.md`

If you add a durable rule or safety boundary, add a concise entry near the top of `PROJECT_RULES.md`.

## Important Current Design Decision

`ManualPackageReviewReady` does not mean install-ready.

It only means a human can review package metadata. Automatic install/update remains blocked until a separate install/rollback workflow exists and is tested.
