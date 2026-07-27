# DeviceCheck Driver Package Advisor

## Σκοπός

Το Driver Package Advisor είναι το standalone Windows Terminal layer πάνω από τα υπάρχοντα driver trace και source-comparison εργαλεία. Παραμένει έξω από το main DeviceCheck TUI μέχρι να σταθεροποιηθούν το recommendation policy, τα safety gates και η παρουσίαση.

Δεν απαντά απλώς «ποιο version είναι νεότερο». Διαχωρίζει:

- τι περιέχει το package,
- ποια present devices ταιριάζουν,
- τι είναι active τώρα,
- τι παρατήρησαν πραγματικά τα Windows,
- τι προτείνεται να κάνει ο χρήστης,
- ποια evidence gaps και risks παραμένουν.

## Standalone flow από EXE

```text
Driver EXE
   ↓
Safe identification / extraction
   ↓
INF → present-device matching
   ↓
Package topology: function / Extension / declaration / component binding
   ↓
Package-filtered DeviceCheck-style tree
   ↓
Preview ή traced install result
   ↓
Historical completed-trace reuse με installer SHA-256
   ↓
Active / optional WUAPI/Catalog / OEM trace / fast automatic local SDIO evidence
   ↓
Explainable recommendation object
   ↓
Windows Terminal Advisor
```

Το Explorer `.exe` context menu εμφανίζει folder `DeviceCheck driver tools` με τέσσερα modes:

| Entry | Installer execution | Advisor |
|---|---:|---:|
| `Safe preview + Advisor` | Όχι | Ναι |
| `Trace install + Advisor` | Ναι | Ναι |
| `Safe preview only` | Όχι | Όχι |
| `Trace install only` | Ναι | Όχι |

Μετά από mode που περιλαμβάνει Advisor:

- ανοίγει πρώτα το package-filtered DeviceCheck-style tree ακόμη και για ένα matched device,
- το `Enter` συνεχίζει με Advisor μόνο για το selected device,
- το `A` συνεχίζει με Advisor για όλα τα matched devices,
- zero matches σταματούν με σαφή explanation,
- preview-only trace μπορεί να χρησιμοποιήσει παλιότερο completed trace με ίδιο installer SHA-256 και target Instance ID.

## Package Device View

Το `package-topology.json` είναι το standalone contract μεταξύ extraction/matching και presentation. Δεν εισάγει code στο main `DeviceCheck.ps1` και δεν αλλάζει το κανονικό machine inventory tree.

Η topology classification ξεχωρίζει:

| Relation | Meaning |
|---|---|
| `FunctionBinding` | Base/function INF που μπορεί να κάνει bind σε present device |
| `ExtensionApplication` | Extension INF που εφαρμόζεται πάνω σε parent/target device |
| `ComponentDeclaration` | `AddComponent`/`ComponentIDs` σχέση· δεν είναι δεύτερο driver binding |
| `ComponentBinding` | Πραγματικό component INF που κάνει bind στο child device |

Το filtered tree κρατά τις Device Manager classes αλλά εμφανίζει μόνο package-related present nodes. `[T]` σημαίνει stack target/root και `[C]` linked component. Το right pane εμφανίζει stack root, Instance ID, INF role, DriverVer, match kind/ID και ExtensionId. Σε στενό terminal γίνεται stacked tree/details view· σε φαρδύ terminal χρησιμοποιεί δύο panes.

| Key | Package Device View action |
|---|---|
| `↑` / `↓` | Navigate tree ή scroll details, ανάλογα με το active pane |
| `←` / `→` | Switch tree/details pane |
| `+` / `-` | Expand/collapse category |
| `Enter` | Analyze selected matched device |
| `A` | Analyze all matched devices |
| `PageUp` / `PageDown`, `Home` / `End` | Detail scrolling |
| `Esc` | Cancel και restore terminal |

## Windows Terminal UI

Το UI χρησιμοποιεί synchronized single-write frames, alternate screen buffer, resize polling, cursor restoration και strict viewport-height clamping.

| Key | Action |
|---|---|
| `←` / `→` | Εναλλαγή `Overview`, `Sources`, `Candidates`, `Evidence`, `Actions` |
| `↑` / `↓` | Scroll στο active view |
| `PageUp` / `PageDown` | Page scroll |
| `Home` / `End` | Αρχή/τέλος view |
| `Esc` | Exit/Cancel και restore του terminal |

Το `POWERSHELL_TUI_ASCII=1` ενεργοποιεί ASCII glyph fallback. Το `POWERSHELL_TUI_PRIMARY_BUFFER=1` απενεργοποιεί το alternate screen όταν χρειάζεται host-specific troubleshooting.

## Recommendation contract

Το canonical object περιέχει:

| Field | Meaning |
|---|---|
| `Code` | Stable machine-readable recommendation code |
| `Title` / `Summary` | User-facing explanation |
| `RecommendedAction` | Τι προτείνεται τώρα, όχι τι είναι θεωρητικά διαθέσιμο |
| `Confidence` | `High`, `Medium`, `Low`, `Insufficient` |
| `EvidenceLevel` | Discovery, inspected package, observed selection ή observed activation |
| `Risk` | Activation/change risk για τη συγκεκριμένη device class |
| `Candidate` | Normalized selected candidate όταν υπάρχει |
| `Reasons` | Positive, caution, neutral ή blocking evidence |
| `Caveats` | Τι δεν έχει ακόμη αποδειχθεί |
| `Actions` | Safe/mutating/elevation metadata για μελλοντικό execution wiring |

Το Windows verdict και η Advisor recommendation είναι διαφορετικά. Για παράδειγμα, ένας network candidate μπορεί να είναι `Best Ranked` αλλά η recommendation να παραμένει `Keep current until connectivity-safe activation`.

## Τρέχοντες verified branches

| Case | Recommendation | Confidence | Risk |
|---|---|---:|---:|
| RZ616 inspected Catalog package, χωρίς observed selection | `InspectOrStageCandidate` | Medium | High |
| RZ616 stage-only Catalog winner | `ControlledActivationRecommended` | High | High |
| Realtek CardReader successful activation | `KeepVerifiedActiveCandidate` | High | Low |
| Lenovo WLAN package observed outranked | `SkipTestedOemCandidate` | High | Low |
| Lenovo Smart Appearance selected Extension INF | `KeepAppliedExtensionStack` | High | Low |
| Realtek Audio selected Dolby APO component | `KeepObservedSelectedPackageCandidate` | High | Low |
| RZ616 Bluetooth: extracted OEM = active, local SDIO μόνο παλαιότερα | `KeepCurrentNoVerifiedBetterCandidate` | High | Low |

Τα cases βρίσκονται στο `internal\fixtures\driver-advisor` και εκτελούνται σε κάθε `internal\Test-DriverAdvisor.ps1` run. Νέες rules δεν επιτρέπεται να χαλούν προηγούμενα verified outcomes.

## Package-node attribution

Το trace outcome δεν βασίζεται σε οποιοδήποτε SetupAPI node εμφανίστηκε στο ίδιο section. Ένα node αποδίδεται στο package μόνο όταν ταιριάζουν:

- original INF filename,
- DriverVer date,
- normalized numeric version χωρίς leading-zero διαφορές.

Έτσι:

- το Lenovo `lnvdmft.inf 1.0.0.27` αποδίδεται στο selected Extension node,
- το inbox `usbvideo.inf` δεν θεωρείται package node,
- το WLAN preview `23.032.2.0558` ταιριάζει με `23.32.2.558`,
- το active νεότερο `mtkwl6ex.inf` δεν συγχέεται με το παλιό package μόνο επειδή έχει ίδιο filename.

## Historical trace reuse

Σε preview-only run, ο coordinator αναζητά sibling completed traces με:

1. ίδιο installer SHA-256,
2. `diff.json`,
3. match για το ίδιο target Instance ID.

Αν βρεθεί, το observed historical selection evidence χρησιμοποιείται αντί να αντιμετωπιστεί το γνωστό package σαν καινούριο. Το `advisor-run.json` καταγράφει ποιο evidence trace χρησιμοποιήθηκε.

## Usage

```powershell
# Pretty Advisor για το τελευταίο comparison report
.\tools\Invoke-DriverPackageAdvisor.ps1

# Συγκεκριμένο report
.\tools\Invoke-DriverPackageAdvisor.ps1 `
  -ReportPath '.devicecheck-data\driver-source-comparisons\driver-source-comparison-<timestamp>.json'

# Static snapshot για logs/tests
.\tools\Invoke-DriverPackageAdvisor.ps1 `
  -ReportPath '<report.json>' `
  -NoUI -PlainText -Width 88

# Trace-folder orchestration
.\tools\Invoke-DriverTraceAdvisor.ps1 `
  -TraceFolder '.devicecheck-data\driver-package-traces\<trace-folder>' `
  -SdioRoot 'E:\SDIO'

# Reopen only the package-filtered topology view
.\tools\Show-DriverPackageView.ps1 `
  -TraceFolder '.devicecheck-data\driver-package-traces\<trace-folder>'

# Static package-view snapshot για logs/tests
.\tools\Show-DriverPackageView.ps1 `
  -TraceFolder '.devicecheck-data\driver-package-traces\<trace-folder>' `
  -NoUI -PlainText -Width 120

# Opt-in network sources
.\tools\Invoke-DriverTraceAdvisor.ps1 `
  -TraceFolder '.devicecheck-data\driver-package-traces\<trace-folder>' `
  -IncludeWindowsUpdate -IncludeCatalog

# Optional slow signer/CIM evidence
.\tools\Invoke-DriverTraceAdvisor.ps1 `
  -TraceFolder '.devicecheck-data\driver-package-traces\<trace-folder>' `
  -IncludeSignatureEvidence

# Safe end-to-end EXE preview χωρίς installer execution
.\tools\Trace-DriverPackageImpact.ps1 `
  -InstallerPath 'D:\Downloads\Driver.exe' `
  -PreviewOnly -LaunchAdvisor

# Live comparison και άμεσο Advisor UI
.\tools\Compare-DriverSources.ps1 `
  -InstanceId '<exact-instance-id>' `
  -ShowAdvisor
```

## Safety boundary

Η τρέχουσα `Actions` view παρουσιάζει action metadata αλλά δεν εκτελεί stage/install/remove/rollback. Mutation wiring θα προστεθεί μόνο μέσω των ήδη verified `StageOnlyNoInstall` και `ControlledActivation` contracts, με elevation warning, checkpoint και explicit confirmation.

Το trace-to-Advisor flow αφήνει WUAPI και Catalog εκτός αν δοθούν ρητά `-IncludeWindowsUpdate` και `-IncludeCatalog`. Το local SDIO scan είναι audit-only: προτιμά reusable completed matcher log, αλλιώς καλεί SDIO με `-disableinstall -nogui -preservecfg` και 45-second timeout. Αν υπάρχει ήδη SDIO process και δεν υπάρχει current reusable log, επιστρέφει `SdioAuditDeferredProcessRunning` αντί να ανοίξει δεύτερο instance που μπορεί να κολλήσει.

Η `Sources` view ξεχωρίζει `available`, `newer` και `index-only` counts. Η `Candidates` view συνδέει σε μία σειρά το active Windows driver, το extracted OEM INF και τα διαθέσιμα deduplicated SDIO candidates μαζί με pack path, `DriverVer`, native SDIO status και relation προς το active. Για stale pack identities, το `ArchiveVerifiedFallback` σημαίνει ότι το πραγματικό current `.7z` επιθεωρήθηκε με 7-Zip και επιβεβαιώθηκαν exact Hardware ID και `DriverVer`· similarity του filename ή νεότερος pack αριθμός μόνος του δεν αρκεί.

Το fast SDIO filter κρατά μόνο τον πρώτο/best candidate με native status `NEW` ή `BETTER`, αποκλείοντας current/older/worse/duplicate/invalid rows πριν από payload resolution. Ένα machine-wide full-audit cache κάνει parse το matcher log μία φορά και μετά εκτελεί per-device target lookup. Τα benchmark logs καταγράφουν extraction, INF matching, snapshots, local PnP evidence, optional network queries, OEM import, SDIO cache build/load/lookup/archive verification, recommendation, report και UI.

Το main `DeviceCheck.ps1` δεν εισάγει ούτε καλεί τον Advisor ή το Package Device View.
