# Local Source Project Audit

Ημερομηνία: 2026-06-03

Σκοπός: να ξεχωρίσουμε τι αξίζει να περάσει στο `DeviceCheck` από τα local source repos χωρίς να φέρουμε πρόωρα download/install behavior.

## Scope

Εξετάστηκαν:

| Source | Τοπικό path | Απόφαση |
|---|---|---|
| OpenDriverUpdater | `source\OpenDriverUpdater` | Reuse concepts/contracts only. Τα περισσότερα source adapters είναι stubs, αλλά το metadata model είναι χρήσιμο. |
| wininfparser | `source\wininfparser` | Reference only. Δεν αντιγράφουμε GPL code. Το δικό μας `internal\InfDriverParser.psm1` μένει independent parser. |

## OpenDriverUpdater Findings

Χρήσιμα concepts:

- `DeviceInfo`: καθαρό split σε `HardwareIds`, `CompatibleIds`, installed version/date/provider.
- `CandidateDriver`: title, version, release date, provider, download URL, source type, signed/beta flags, supported hardware IDs.
- `UpdateRecommendation`: installed version vs candidate version, recommendation type, trust score, reason.
- `TrustScore`: level, points, factor details.
- `VersionComparerService`: μικρό comparison contract με `IsNewer` και human-readable delta.
- `TrustEvaluatorService`: απλό factor model: official source, signed, OEM match, stable release, direct Hardware ID match.

Όρια/risks:

- `MicrosoftCatalogSource` parser είναι stub.
- Intel/AMD/NVIDIA sources είναι stubs.
- `PnpHardwareScanner` parses `pnputil` text simply and δεν είναι πιο πλούσιο από το υπάρχον DeviceCheck evidence.
- Signature validator concept είναι χρήσιμο, αλλά actual signature verification/download workflow πρέπει να μείνει εκτός μέχρι να υπάρχει package sandbox, hash, catalog, rollback, και elevation plan.
- Install/download code δεν μεταφέρεται τώρα.

## wininfparser Findings

Χρήσιμα concepts:

- Section-aware INF reading.
- Key/value/comment preservation.
- Section search helpers.
- Exact/partial key search.

Όρια/risks:

- Το repo είναι GPL-3.0. Δεν αντιγράφουμε implementation.
- Το DeviceCheck χρειάζεται read-only INF evidence, όχι INF editing/saving.
- Το υπάρχον `internal\InfDriverParser.psm1` ήδη κάνει ανεξάρτητο parsing για sections, CSV-like values, `%Strings%`, version metadata, and Hardware ID extraction.

## Transferred Into DeviceCheck

Μεταφέρθηκε ως contract, όχι ως code copy:

- Optional `Recommendation` section στο `config\driver-candidate-package.schema.json`.
- Template fields στο `internal\Test-DriverCandidatePackageMetadata.ps1`:
  - `Type`
  - `IsCandidateNewer`
  - `VersionComparison`
  - `TrustLevel`
  - `TrustScore`
  - `TrustFactors`
  - `CandidateFlags.IsBeta`
  - `CandidateFlags.IsSignedClaimed`
  - `CandidateFlags.DirectHardwareIdMatch`
  - `CandidateFlags.OemProviderMatch`

Αυτό κρατά το current layer metadata-only και δίνει χώρο σε μελλοντικό read-only recommendation/report χωρίς να επιτρέπει download/install.

## Next Safe Layer

Προτεινόμενο επόμενο βήμα:

1. Δημιουργία read-only version comparison helper για candidate metadata templates.
2. Προσθήκη trust-factor explanations στο `Test-DriverCandidatePackageMetadata.ps1` output, όχι στο TUI ακόμα.
3. Μετά, εμφάνιση μόνο summary badge στο TUI όταν υπάρχει validated candidate metadata artifact.

Δεν προχωράμε σε package download, signature verification on downloaded files, `pnputil /add-driver`, restore points, or rollback automation μέχρι να σχεδιαστεί ξεχωριστό safety workflow.
