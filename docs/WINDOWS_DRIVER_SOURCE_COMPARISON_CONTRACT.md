# Contract σύγκρισης πηγών Windows drivers

## Σκοπός

Αυτό το έγγραφο είναι το verified contract για το standalone DeviceCheck driver-source comparison lab.

Το lab συγκρίνει evidence από το ενεργό Windows device stack, το Windows Update, το public Microsoft Update Catalog, OEM/vendor packages και το SDIO. Δεν εγκαθιστά drivers και δεν ενσωματώνεται στο κύριο DeviceCheck TUI.

Το εργαλείο πρέπει να απαντά:

> Τι αποδεικνύει κάθε πηγή για αυτή τη συσκευή και τον συγκεκριμένο candidate, και τι παραμένει άγνωστο;

Δεν πρέπει να απαντά «ποιος driver είναι ο καλύτερος», εκτός αν τα Windows έχουν παράγει authoritative local selection evidence για το συγκεκριμένο candidate και device.

## Verified Windows model

### Local PnP selection

- Το Windows driver rank είναι ένα DWORD με μορφή `0xSSGGTHHH`.
- Μικρότερο rank σημαίνει καλύτερη κατάταξη.
- Τα πεδία είναι Signature Score, Feature Score και Identifier Score.
- Τα exact Hardware ID matches προηγούνται από compatible-ID fallbacks.
- Το driver date και μετά το driver version επιλύουν candidates που έχουν κατά τα άλλα ίδιο rank.
- Η παρουσία στο Driver Store αποδεικνύει staging, όχι active binding.
- Ένα Extension INF μπορεί να εφαρμόσει configuration χωρίς να αντικαταστήσει τον ενεργό base function driver.
- Το SetupAPI evidence είναι authoritative για το local selection event που κατέγραψε, αλλά δεν αποδεικνύει ολόκληρο το Windows Update offer universe.

Primary references:

- https://learn.microsoft.com/windows-hardware/drivers/install/how-windows-ranks-driver-packages
- https://learn.microsoft.com/windows-hardware/drivers/install/identifier-score--windows-vista-and-later-
- https://learn.microsoft.com/windows-hardware/drivers/install/feature-score--windows-vista-and-later-
- https://learn.microsoft.com/windows-hardware/drivers/install/signature-score--windows-vista-and-later-
- https://learn.microsoft.com/windows-hardware/drivers/install/how-windows-selects-a-driver-for-a-device
- https://learn.microsoft.com/windows-hardware/drivers/install/using-an-extension-inf-file

### Windows Update

- Το Windows Update προσφέρει το καλύτερο applicable match, όχι απαραίτητα το νεότερο public package.
- Το applicability μπορεί να περιλαμβάνει Hardware IDs, OS/architecture targeting, publishing labels και CHIDs.
- Τα automatic/critical και optional/manual delivery αποτελούν διαφορετικές evidence states.
- Το WUAPI μπορεί να αναφέρει τι επιστρέφει το τρέχον client search. Δεν αποκαλύπτει ολόκληρο το cloud-side selection algorithm.
- Ένα ολοκληρωμένο current search χωρίς matching offer σημαίνει μόνο `NoCurrentApplicableOfferObserved`.
- Δεν σημαίνει ότι το Windows Update δεν πρόσφερε ποτέ driver στο παρελθόν.
- Το parsing του internal `DataStore.edb` δεν είναι stable supported contract και δεν απαιτείται από αυτό το lab.

Primary references:

- https://learn.microsoft.com/windows-hardware/drivers/dashboard/publish-a-driver-to-windows-update
- https://learn.microsoft.com/windows/deployment/update/windows-update-logs
- https://learn.microsoft.com/windows/win32/api/wuapi/nn-wuapi-iupdatesearcher

### Public Microsoft Update Catalog

- Ένα Catalog text search ανακαλύπτει public rows.
- Ένα row δεν αποδεικνύει machine applicability, CHID eligibility, current WU assignment, PnP rank ή active selection.
- Η public Catalog visibility δεν είναι εγγυημένη για κάθε WU-deliverable driver, επειδή ένα publishing label μπορεί να περιορίζει το public disclosure.
- Το MSCatalogLTS χρησιμοποιεί το public Catalog website μέσω HTML parsing. Είναι πρακτικός discovery adapter, όχι official Catalog API.
- Τα `SupportUrl` και `SHA1` μπορεί να απαιτούν πρόσθετα per-update requests. Η απουσία τους από ένα search row δεν αποδεικνύει ότι το metadata δεν είναι διαθέσιμο.

## Verified SDIO model

Το SDIO μοντελοποιεί μέρος του Windows ranking, αλλά προσθέτει δικό του policy και ordering.

Verified source functions:

- `source/enum.cpp::calc_signature`
- `source/enum.cpp::calc_score`
- `source/enum.cpp::calc_identifierscore`
- `source/matcher.cpp::Hwidmatch::calc_status`
- `source/matcher.cpp::Hwidmatch::cmp`
- `source/matcher.cpp::MatcherImp::findHWIDs`

Τα τρέχοντα `DRIVER_STATUS` flags είναι:

| Name | Value |
|---|---:|
| `STATUS_BETTER` | `0x001` |
| `STATUS_SAME` | `0x002` |
| `STATUS_WORSE` | `0x004` |
| `STATUS_INVALID` | `0x008` |
| `STATUS_MISSING` | `0x010` |
| `STATUS_NEW` | `0x020` |
| `STATUS_CURRENT` | `0x040` |
| `STATUS_OLD` | `0x080` |
| `STATUS_NF_MISSING` | `0x100` |
| `STATUS_NF_UNKNOWN` | `0x200` |
| `STATUS_NF_STANDARD` | `0x400` |
| `STATUS_DUP` | `0x800` |

Σημαντικά boundaries:

- Το SDIO score/status δεν αποτελεί Windows PnP rank evidence.
- Το SDIO `calc_signature` μοντελοποιεί την παρουσία Catalog fields και τη συμπεριφορά `.nt` sections. Δεν κάνει πλήρες Windows cryptographic trust evaluation.
- Ο SDIO comparator χρησιμοποιεί επίσης alternative-section, decoration, marker, date και status evidence.
- Ένα top SDIO candidate δεν εγγυάται ότι τα Windows θα το ενεργοποιήσουν.
- Το changelog περιγράφει ένα hash-algorithm experiment για μείωση cross-index collisions. Δεν αποδεικνύει ότι τα collisions εξαλείφθηκαν.

## Evidence schema

Κάθε source result πρέπει να διατηρεί τα παρακάτω concepts όπου είναι διαθέσιμα:

| Field | Meaning |
|---|---|
| `Source` | `ActiveStack`, `WindowsUpdate`, `CatalogPublic`, `OEMTrace`, `VendorPackage` ή `SDIO` |
| `PackageIdentity` | Published INF, original INF, Update ID, Catalog GUID ή pack/INF identity |
| `HardwareId` | Candidate ή query Hardware ID |
| `MatchKind` | Exact Hardware ID, compatible ID, text-search hit ή unknown |
| `DriverDate` / `DriverVersion` | Native package values χωρίς cross-branch assumptions |
| `Signer` | Observed signer evidence |
| `PackageRole` | Base, Extension, Component, SoftwareComponent ή unknown |
| `StagedState` | Observed, not observed ή unknown |
| `ActiveState` | Active, selected extension, outranked, not active ή unknown |
| `WindowsRank` | Μόνο Windows-observed rank· ποτέ SDIO score ως υποκατάστατο |
| `SdioScore` / `SdioStatus` | Μόνο SDIO-native evidence |
| `WuAssignment` | Current WUAPI properties όπως assigned/browse-only, όταν εκτίθενται |
| `CatalogMetadata` | Μόνο public-row metadata |
| `Confidence` | `Observed`, `StrongInference`, `DiscoveryOnly` ή `Unknown` |
| `EvidenceSource` | Το ακριβές command, file, API, log ή trace |

## Verdict rules

- `ObservedActive`: το active binding επιβεβαιώθηκε από live Windows evidence.
- `ObservedAppliedExtension`: επιβεβαιώθηκε Extension configuration χωρίς base-driver replacement.
- `ObservedOutranked`: SetupAPI ή αντίστοιχο local selection evidence δείχνει ότι ο candidate έχασε.
- `CurrentWuOfferObserved`: το current WUAPI search επέστρεψε target-matching driver update.
- `NoCurrentWuOfferObserved`: το current WUAPI search ολοκληρώθηκε χωρίς target-matching offer.
- `CatalogDiscoveryOnly`: βρέθηκαν public rows, αλλά applicability/rank παραμένει άγνωστο.
- `ObservedPackageContent`: το CAB κατέβηκε, τα hashes/signatures επαληθεύτηκαν και το INF αναλύθηκε χωρίς staging.
- `SdioRecommendationOnly`: το SDIO παρήγαγε candidate· το Windows activation παραμένει άγνωστο.
- `InsufficientEvidence`: η σύγκριση απαιτεί package download, INF inspection ή local selection event.

Versions από διαφορετικά surfaces δεν συγκρίνονται τυφλά. Ένα Catalog title version μπορεί να περιγράφει release family ή submission label και όχι το INF `DriverVer` που θα κατατάξουν τα Windows.

## RZ616 proof of concept

Ο πρώτος target είναι το `RZ616 Wi-Fi 6E 160MHz`, επειδή γνωρίζουμε το provenance του active driver από το test installation:

- Active source: SDIO/manual audit provenance.
- Active package: `oem60.inf` / `mtkwl6ex.inf`.
- Active version/date: `25.40.2.586` / `2026-01-30`.
- Lenovo candidate: exact matching `mtkwl6ex.inf`, παλαιότερο και locally outranked.
- Το Lenovo combo payload έκανε επίσης stage ένα Realtek package χωρίς matching present device.

Το πλήρες opt-in prototype μπορεί να εκτελέσει:

1. Live PnP και signed-driver capture.
2. Προαιρετικό current WUAPI driver-offer search με `-IncludeWindowsUpdate`.
3. Προαιρετικό public Catalog ordered Hardware-ID text search μέσω MSCatalogLTS με `-IncludeCatalog`.
4. Optional import του υπάρχοντος Lenovo WLAN trace JSON evidence.
5. Optional parsing ενός υπάρχοντος SDIO audit report ή ενός ρητά ζητημένου audit-only SDIO run.

Το standalone trace-to-Advisor flow μπορεί πλέον να κάνει αυτόματο local SDIO audit. Επαναχρησιμοποιεί completed matcher log μόνο όταν είναι τουλάχιστον τόσο νέο όσο το νεότερο active `.7z` driver pack. Τα index matches χωρίς verified payload pack καταγράφονται ως `index-only` και δεν μετριούνται ως available local candidates. Truncated SDIO log pack names επιλύονται όταν υπάρχει μοναδικό suffix match στο active `drivers` root. Αν το index αναφέρει παλιότερο generation, το adapter μπορεί να επιθεωρήσει read-only current archives της ίδιας pack family με 7-Zip, αλλά δέχεται `ArchiveVerifiedFallback` μόνο όταν το actual INF περιέχει το exact matched Hardware ID και το ίδιο `DriverVer` date/version.

Το normalized linkage συγκρίνει active Windows `DriverVer`, extracted OEM preview match και κάθε available SDIO candidate. `NotRequiredSameAsActive` επιτρέπεται μόνο όταν OEM και active έχουν ίδιο matched ID, date και numeric version. Το SDIO `Score`/`StatusLabels` παραμένει native evidence και το `WindowsRank` παραμένει κενό μέχρι observed `pnputil`/SetupAPI selection.
Το fast default SDIO policy κρατά μόνο τον πρώτο/best candidate που έχει native `NEW` ή `BETTER` status και αποκλείει `CURRENT`, `OLD`, `WORSE`, `DUP`, `INVALID` και `MISSING` πριν από pack resolution. Better-only candidate παραμένει informational· δεν μετατρέπεται σε Windows recommendation χωρίς verified selection evidence. Το full matcher log γίνεται parse μία φορά σε invalidation-aware cache με log path/length/UTC ticks, και κάθε device χρησιμοποιεί target lookup πάνω στο cached audit.
6. Normalized JSON και Markdown report με σαφή evidence boundaries.

Το επόμενο package-inspection gate χρησιμοποιεί `MSCatalogLTS` για download, το built-in `expand.exe` για extraction και το υπάρχον `InfDriverParser` για INF evidence. Ένα computed rank body παραμένει `StrongInferenceNotWindowsSelectionEvidence` μέχρι τα Windows να αξιολογήσουν πραγματικά το staged candidate.

Το comparison command δεν εκτελεί driver installation, removal, rollback, Device Manager mutation, Registry integration ή main-TUI integration. Το ξεχωριστό inspection command επιτρέπεται να κατεβάσει και να εξαγάγει CABs, αλλά δεν κάνει stage ή install driver packages.

### RZ616 Catalog package-inspection result

Στο Windows 11 25H2 build `26200.8737`, δύο διαφορετικά public Catalog payloads για version `3.5.0.1392` εξετάστηκαν χωρίς staging:

| Catalog GUID | CAB size | INF DriverVer | Target match | Computed rank body |
|---|---:|---|---|---|
| `566cb1be-0030-4174-970c-6b6c159a34f2` | `11,981,727` bytes | `03/24/2026, 3.05.00.1392` | Exact target HWID | `00FF0001` |
| `9990c2a8-cab4-48df-ae4b-d5bc9a209f97` | `8,465,919` bytes | `03/24/2026, 3.05.00.1392` | Exact target HWID | `00FF0001` |

Verified observations:

- Τα advertised SHA-1 hashes ταίριαξαν με τα downloaded CABs.
- CAB, CAT και SYS signature checks επέστρεψαν `Valid`.
- Και τα δύο `mtkwl6ex.inf` περιέχουν το exact device Hardware ID στη θέση `1` της ordered device Hardware-ID list.
- Δεν υπάρχει explicit `FeatureScore` στο relevant install section, άρα εφαρμόζεται το documented default `0xFF`.
- Το computed IdentifierScore είναι `0x0001`, και το computed rank body είναι `00FF0001`.
- Το candidate date `2026-03-24` είναι νεότερο από το active date `2026-01-30`, ενώ το numeric version `3.5.0.1392` είναι χαμηλότερο από `25.40.2.586`.
- Η σύγκριση date/version έχει νόημα μόνο μετά από otherwise-equal Windows rank, με το date να προηγείται του version.
- Το current WUAPI search δεν προσφέρει κανένα RZ616 driver, παρότι τα public CABs περιέχουν exact matching INFs.
- Published-INF count, DriverStore folder count και `setupapi.dev.log` length έμειναν αμετάβλητα.

Συμπέρασμα αυτού του package-inspection gate: υπάρχει signed, exact-match, later-date Catalog candidate, αλλά σε αυτό το στάδιο δεν υπήρχε ακόμη observed Windows selection evidence ούτε current WU assignment. Τα δύο διαφορετικά payloads έχουν ίδιο target match/date/version και το public Catalog δεν εκθέτει αρκετό CHID/applicability evidence για ασφαλή επιλογή μεταξύ τους. Το επόμενο stage-only gate παρακάτω προσθέτει το selection evidence.

### RZ616 stage-only selection result

Στις 2026-07-11/12 έγινε ξεχωριστό, ρητά εξουσιοδοτημένο stage-only experiment για τα δύο inspected Catalog payloads:

- Κάθε command ήταν `pnputil /add-driver <mtkwl6ex.inf>` χωρίς `/install` και χωρίς `/reboot`.
- Το πρώτο payload δημοσιεύτηκε ως `oem11.inf` και το δεύτερο ως `oem167.inf`.
- Το active binding παρέμεινε `oem60.inf / 25.40.2.586`, το adapter έμεινε `Up` και η Wi-Fi σύνδεση δεν διακόπηκε.
- Το authoritative `pnputil /enum-devices /instanceid ... /drivers` έδειξε `oem11.inf` ως `Best Ranked`.
- Το active `oem60.inf` εμφανίστηκε ως `Outranked / Installed` και το δεύτερο ισοδύναμο Catalog payload `oem167.inf` ως `Outranked`.
- Και τα τέσσερα matching packages είχαν observed rank `00FF0001`. Με otherwise-equal rank, το Catalog `DriverVer` date `2026-03-24` κέρδισε το active date `2026-01-30`, παρότι το numeric version `3.5.0.1392` είναι χαμηλότερο από `25.40.2.586`.
- Μετά την καταγραφή αφαιρέθηκαν μόνο τα experimental `oem11.inf` και `oem167.inf` με `pnputil /delete-driver`, χωρίς `/uninstall` και χωρίς `/force`. Το baseline αποκαταστάθηκε: `oem60.inf` ξανά `Best Ranked / Installed`, adapter `Up`, problem code `0`.

Το νέο verdict είναι `CatalogCandidateObservedBestRanked_ActiveUnchanged`. Αυτό αποδεικνύει ποιο staged candidate επιλέγει τώρα το local Windows ranking, όχι ότι το current Windows Update το προσφέρει ούτε ότι η πραγματική ενεργοποίησή του είναι ασφαλής ή χρήσιμη. Actual binding απαιτεί ξεχωριστό connectivity-safe, resumable experiment.

### Realtek CardReader controlled-activation result

Το δεύτερο proof-of-concept χρησιμοποίησε non-network device ώστε να επαληθευτεί και το actual activation path χωρίς να απειληθεί η σύνδεση της task:

- Target: `Realtek PCIE CardReader`, `PCI\VEN_10EC&DEV_522A&SUBSYS_522A10EC`.
- Baseline: `oem19.inf / rtsper.inf`, `2023-06-01 / 10.0.22621.21365`, rank `00FF0001`, status `Best Ranked / Installed`.
- SDIO candidate: `DP_CardReader_26040.7z` → `RtsPerISO.inf`, `2025-12-24 / 10.0.26200.21387`, exact HWID, valid CAT/SYS signatures.
- Stage-only: δημοσιεύτηκε ως `oem11.inf` και έγινε `Best Ranked` με rank `00FF0001`, ενώ το `oem19.inf` έγινε `Outranked / Installed` χωρίς να αλλάξει ακόμη το binding.
- Controlled activation: `pnputil /add-driver <INF> /install`, χωρίς `/reboot`. Το SetupAPI κατέγραψε `Installing best driver`, device query-remove/start και `Restart verified`.
- Post-activation: `oem11.inf` `Best Ranked / Installed`, version `10.0.26200.21387`, device `OK`, problem code `0`, service `RTSPER`.
- Το υπάρχον Extension `oem18.inf` παρέμεινε `Best Ranked / Installed / Extension`.
- Το loaded `RtsPer.sys` είχε version `10.0.26200.21387`, valid WHCP signature και SHA-256 ίδιο με το extracted payload.
- Το current WUAPI search επέστρεψε μηδέν target offers, ενώ το public Catalog discovery επέστρεψε 25 rows μόνο μετά την αφαίρεση του revision suffix.
- Δεν υπήρχε inserted SD card/child storage device, επομένως το physical read/write status είναι `NotRunNoMediaDetected`, όχι verified functionality.

Το source-neutral verdict είναι `CandidateObservedBestRankedAndActivated`. Δεν σημαίνει ότι ο candidate προήλθε από Windows Update ούτε ότι έχει ολοκληρωθεί physical-media functional test.

## Advisor recommendation layer

Το Windows comparison verdict παραμένει evidence statement. Το standalone Advisor προσθέτει ξεχωριστό user-action contract με stable `Code`, `RecommendedAction`, `Confidence`, `EvidenceLevel`, activation `Risk`, normalized `Candidate`, `Reasons`, `Caveats` και action safety metadata.

Παραδείγματα:

- `CatalogCandidateObservedBestRanked_ActiveUnchanged` → `ControlledActivationRecommended` για RZ616, επειδή το selection είναι observed αλλά το network activation όχι.
- `CandidateObservedBestRankedAndActivated` → `KeepVerifiedActiveCandidate` για CardReader, επειδή activation, health και loaded binary επαληθεύτηκαν.
- `ObservedOutrankedCandidate` → `SkipTestedOemCandidate` μόνο όταν το outranked SetupAPI node αποδίδεται στο package INF/date/version.
- `ObservedAppliedExtension` → `KeepAppliedExtensionStack`, χωρίς να παρουσιάζεται το Extension σαν base-driver replacement.

Public Catalog rows και SDIO-native status δεν αρκούν μόνα τους για `High` Windows-selection confidence. Το πλήρες UI/case/action contract βρίσκεται στο `docs\DRIVER_PACKAGE_ADVISOR.md`.
