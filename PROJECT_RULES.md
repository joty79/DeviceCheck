# Project Rules - DeviceCheck

This repository contains `DeviceCheck.ps1`, an interactive, flicker-free PowerShell TUI for checking connected hardware devices and querying local databases and AI APIs (Gemini, OpenRouter) for details.

## 🔵 PowerShell Runspace Guidelines

🔸 **Disable Progress Reporting:**
Always set `$ProgressPreference = 'SilentlyContinue'` at the beginning of any background runspace script block.
Background commands like `Invoke-WebRequest` and `Invoke-RestMethod` write progress bars to the host, which will deadlock the console and corrupt the TUI rendering when executed concurrently.

🔸 **Use Basic Parsing:**
Always use the `-UseBasicParsing` parameter for `Invoke-WebRequest` inside background runspaces to avoid launching the Internet Explorer HTML rendering engine (which hangs or fails on systems without configured IE).

🔸 **Safe Runspace Cleanup:**
Always wrap runspace `.Dispose()` and `.Stop()` calls in `try/catch` blocks and explicitly nullify the PowerShell references (e.g., `$ps = $null`).
This prevents parser interruption from skipping the null assignment and creating an infinite loop.

---

## 🔵 TUI Rendering Guidelines

🔸 **Synchronized Rendering:**
Wrap TUI frame redraws inside Windows Terminal synchronized output sequences (`Begin-SyncRender` and `End-SyncRender`) to prevent frame tearing and flicker.

🔸 **Color Tagging:**
Highlight model name tags dynamically in the tree.
Use `$_C.Info` (Blue) for Gemini models and `$_C.OK` (Green) for Nvidia/OpenRouter models.

---

## 🔵 API Key Setup

- Google Gemini API key is loaded from `GOOGLE_API_KEY` or `GEMINI_API_KEY` environment variables (both process-level and user-level registry).
- OpenRouter API key is loaded from the `OPENROUTER_API_KEY` environment variable.

---

## Google AI Studio Free Tier Quota Snapshot

Snapshot date: 2026-05-30.
Source: user-provided Google AI Studio rate-limit screenshots.
Official reference: https://ai.google.dev/gemini-api/docs/rate-limits
Canonical local extract: `data/google-ai-studio-rate-limits-only free.csv` and `docs/google-ai-studio-rate-limits-only-free.md`.
Official context: Google documents rate limits as RPM/TPM/RPD, applies them per project rather than per API key, resets RPD at midnight Pacific time, and says active limits should be checked in AI Studio because actual limits can change by tier/account.

Guardrail:
- Treat this as an observed dashboard snapshot, not a universal guarantee.
- Do not infer normal text-generation quota from the `Tools` section. Tool quotas such as Map grounding/Search grounding are separate from `generateContent` text-out model quotas.
- For repeated developer testing, prefer models with observed RPD >= 500 only when that row belongs to the actual API path being used.

Quick lookup:
- The canonical CSV currently contains 34 free-tier limit rows: 19 model rows and 15 tool rows.
- `Gemini 3.1 Flash Lite` is the visible high-quota text-out option: 15 RPM, 250K TPM, 500 RPD.
- `Gemini 2.5 Flash` and `Gemini 3.5 Flash` are visible at 5 RPM, 250K TPM, 20 RPD.
- Use the CSV/Markdown extract for the full table instead of duplicating the data in this rules file.

### Decision Log

Date: 2026-06-17
Problem: After removing `dcadmin`, the account was gone but `C:\Users\dcadmin` and `C:\Users\dcadmin.<COMPUTERNAME>` profile folders remained because the account had been used for multiple WinRM test logons.
Root cause: `Enable-RemotePs.ps1` cleanup removed only the local account and did not clean Windows user profiles or leftover profile directories. On Windows, deleting a local user does not necessarily remove `C:\Users\<user>*` profile folders.
Guardrail/rule: DeviceCheck temporary-user cleanup must remove both the account and its matching profile data. Prefer `Win32_UserProfile` removal for non-loaded profiles, then remove only safe leftover folders under `%SystemDrive%\Users` whose leaf is exactly the temporary username or starts with `<username>.`. Before recursive deletion, verify the resolved full path stays inside the Users root and matches the expected temporary-user naming pattern.
Files affected: `Enable-RemotePs.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `Enable-RemotePs.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; `git ls-files --eol` confirmed LF endings; non-admin smoke confirmed the script stops early with the administrator warning when not elevated; non-destructive path-safety smoke confirmed only `C:\Users\dcadmin` and `C:\Users\dcadmin.*` match, while unrelated user folders and paths outside `C:\Users` do not. Elevated profile cleanup still required on the laptop.

Date: 2026-06-17
Problem: After a successful remote snapshot, the user wants to remove the temporary `dcadmin` account without remembering a separate cleanup switch or manual command.
Root cause: `Enable-RemotePs.ps1` had explicit `-RemoveDeviceCheckUser` cleanup, but the natural workflow is to run the same helper again on the target PC after the snapshot and let it detect/offer cleanup.
Guardrail/rule: The normal `.\Enable-RemotePs.ps1` flow should detect the configured temporary DeviceCheck user (default `dcadmin`) before setup, ask whether to remove it, and exit after removal when confirmed. Keep `-RemoveDeviceCheckUser` for non-interactive cleanup, and allow `-CreateDeviceCheckUser`/`-NoUserPrompt` to bypass the cleanup prompt when automation needs setup behavior.
Files affected: `Enable-RemotePs.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `Enable-RemotePs.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; `git ls-files --eol` confirmed LF endings; non-admin smoke confirmed the script stops early with the administrator warning when not elevated. Elevated target cleanup still required on the laptop.

Date: 2026-06-17
Problem: Running only `.\Enable-RemotePs.ps1` on the target laptop still printed `Local user 'dcadmin' already exists`, then failed to add `dcadmin` to `Administrators` and `Remote Management Users` because the principal did not actually exist.
Root cause: The ADSI WinNT user-existence fallback created a `DirectoryEntry` for `WinNT://COMPUTER/user,user` and treated that object as proof of existence. The WinNT provider can return a lazy object for a missing account; the failure appears later when the account is used.
Guardrail/rule: Do not treat an ADSI `DirectoryEntry` object as existence proof. For WinNT users, use `[System.DirectoryServices.DirectoryEntry]::Exists()` with exception-as-missing and/or enumerate `WinNT://COMPUTER,computer` children for an exact `SchemaClassName = User` and case-insensitive `Name` match.
Files affected: `Enable-RemotePs.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `Enable-RemotePs.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; missing-user ADSI existence smoke confirmed `[System.DirectoryServices.DirectoryEntry]::Exists()` returns false for a definitely missing local user when exceptions are treated as missing; non-admin smoke confirmed the script stops early with the administrator warning when not elevated. Elevated target rerun still required on the laptop.

Date: 2026-06-17
Problem: On the target laptop, `Enable-RemotePs.ps1` failed again during temporary user creation under PowerShell 7.6.2 with `Could not load type 'Microsoft.PowerShell.Telemetry.Internal.TelemetryAPI' from assembly 'System.Management.Automation, Version=7.6.0.500'`.
Root cause: The Windows `LocalAccounts` cmdlets can load unreliably through the PowerShell 7.x compatibility path on some systems. `New-LocalUser` failed before creating the user, and relying on a Windows PowerShell 5.1 relaunch is not acceptable for fresh/customer PCs where the user runs the helper from PowerShell 7 and the Windows PowerShell host may have unrelated first-run/setup problems.
Guardrail/rule: For setup helpers that create/delete local Windows users, keep the primary `LocalAccounts` cmdlet path simple but include an ADSI `WinNT://` fallback for create, group membership, and removal. Prefer this PowerShell 7-compatible fallback over relaunching Windows PowerShell 5.1 or using `net user`, because it handles passwordless users, secure-string conversion, and quoting more reliably inside the current host.
Files affected: `Enable-RemotePs.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `Enable-RemotePs.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; harmless ADSI bind checks for the local computer and Administrators group succeeded from PowerShell 7; non-admin smoke confirmed the script stops early with the administrator warning when not elevated. Elevated target rerun still required on the laptop.

Date: 2026-06-17
Problem: Creating the temporary DeviceCheck WinRM admin failed on a customer/work laptop when the user entered password `1234`. `New-LocalUser` rejected the `Description` argument because Windows local user descriptions are limited to 48 characters, but the script still printed a misleading created message and then group membership failed because the user did not exist.
Root cause: The helper used a 53-character description and trusted the cmdlet path too optimistically before verifying that the account existed.
Guardrail/rule: Keep `New-LocalUser -Description` values at 48 characters or fewer. After creating local users in setup helpers, re-query the account before printing success or adding group memberships so validation failures cannot produce false success.
Files affected: `Enable-RemotePs.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `Enable-RemotePs.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; non-admin smoke confirmed the script stops early with the administrator warning when not elevated. Elevated target rerun still required on the laptop.

Date: 2026-06-17
Problem: Work/customer PCs and the user's own formatted PCs often use local accounts with no password by default. When a target is signed in with a Microsoft Account and has no enabled local administrator account, WinRM may be enabled but DeviceCheck still lacks a reliable local credential for snapshot collection.
Root cause: `Enable-RemotePs.ps1` enabled WinRM but did not detect MicrosoftAccount-only administrator setups or offer a complete create/use/remove lifecycle for a temporary local WinRM admin. During follow-up, a generic security-hardening instinct briefly treated blank-password remote logon as something to keep blocked, which contradicts the established shop/workbench baseline.
Guardrail/rule: In DeviceCheck's shop/workbench WinRM setup, passwordless local accounts are an intentional supported default. `Enable-RemotePs.ps1` should detect usable enabled local admins, warn when only Microsoft Account admins are present, offer or force-create a temporary local admin such as `dcadmin`, allow Enter/no password when creating it, keep `LimitBlankPasswordUse = 0`, and provide `-RemoveDeviceCheckUser` cleanup after snapshots. Do not silently create users by default; prompt unless `-CreateDeviceCheckUser` is explicit.
Files affected: `Enable-RemotePs.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `Enable-RemotePs.ps1`; verified `New-LocalUser` supports the `-NoPassword` parameter set; non-admin smoke confirmed the script stops early with the administrator warning when not elevated.

Date: 2026-06-16
Problem: 1. Connecting to a LAN target at work (e.g. `datacomputer2`) maps or displays it as a home LAN PC (e.g. `PALIOS`) when both share the same IP (e.g. `192.168.1.7`) via DHCP or static lease. 2. Pressing Escape while viewing a remote target or saved snapshot exits the script completely to shell instead of going back to the connection selector. 3. Pressing Escape in the "Ctrl+L" connection selector menu should switch target mode back to the local host machine instead of staying on the previously logged remote target.
Root cause: 1. The local network scanning history retrieval and hostname resolution cache mapped IP addresses globally without scoping them to the active NetworkId. 2. Escape was hardcoded to set `$running = $false` on all targets in the main event loop. 3. The connection selector cancel path did not reset target mode properties to local host and trigger a local scan.
Guardrail/rule: 1. Scope connection history scanning and name-resolution caches in `Get-DeviceCheckDiscoveredHosts` strictly to the current NetworkId. Implement MAC/name checks on matches. 2. Escape key on remote targets (`TargetMode -eq 'RemoteSnapshot'`) must call `Invoke-ConnectLanTarget` to return to target selection, preserving exit to shell only for local host targets. 3. Escape key / cancellation inside the `Ctrl+L` selector must reset `$script:TargetMode = 'Local'` and trigger `Invoke-SystemScan -Quiet` to clean active state and refresh the view.
Files affected: `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1` and all dot-sourced files; `internal\Test-DeviceCheckStructure.ps1` structural check succeeded; verified Escape key behavior on local target (exits script), remote targets (redirects to LAN connection selector), and inside connection selector (resets target back to local host).

Date: 2026-06-13
Problem: The remote cached snapshot action screen had only open/refresh/cancel, so there was no deliberate way to capture a slower archive-grade sample before a work/customer PC left the bench.
Root cause: Normal remote refresh and archive/sample capture were treated as the same operation, even though daily ID logging should stay fast and repair-shop sample capture can afford a heavier full snapshot.
Guardrail/rule: Keep normal remote refresh on `R` as quick snapshot collection. Add `F = Full archive sample` only for online targets in the cached snapshot action screen. Full archive samples must run full collection, save under the normal snapshot folder, and mark the JSON collector metadata with `SnapshotMode = FullArchive` and `CapturePurpose = RepairShopSample`.
Files affected: `internal\DeviceCheck\05-InventoryAndSnapshots.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\05-InventoryAndSnapshots.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; temp-output localhost quick smoke confirmed `QuickMode=True`; temp-output localhost archive smoke confirmed `QuickMode=False`, `SnapshotMode=FullArchive`, `CapturePurpose=RepairShopSample`, 233 devices, 233 per-device property groups, and `pnputil` output.

Date: 2026-06-12
Problem: The `Ctrl+L` LAN selector treated every saved target as an active current-network connection, so offline home targets and one-time work/customer PCs were either noisy in the active list or hard to reach later as snapshot samples.
Root cause: The selector filtered primarily by the current network history and did not have an automatic offline snapshot view that included other saved networks or snapshot-only `latest.json` files.
Guardrail/rule: Treat online connection targets and offline snapshot samples as separate UI surfaces. `Ctrl+L` should show active online saved connections for the current network, then a compact `Offline Snapshots` submenu grouped by saved network. That submenu is populated from the local `%LOCALAPPDATA%\DeviceCheck` history and snapshot files for the PC running DeviceCheck; snapshots collected from another PC must be scanned again or imported/synced before they appear. Offline entries from other networks must open the exact selected cached snapshot without trying stale same-subnet IPs on the current LAN or rewriting that PC into the current network history. Saved offline history entries without a local `latest.json` should remain visible as `No Snapshot` instead of disappearing silently.
Files affected: `internal\DeviceCheck\06-RemoteConnection.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; isolated temp-cache smoke confirmed offline entries are grouped by network and saved offline history without local `latest.json` stays visible as `No Snapshot`.

Date: 2026-07-07
Problem: Hardware-based offline snapshot names made the Offline Snapshots submenu more useful, but the entries rendered as long, mostly white, log-like lines with poor vertical alignment.
Root cause: Offline snapshot rows were built as a single interpolated `Text` string instead of a TUI row with fixed columns and separately colored fields.
Guardrail/rule: Dense DeviceCheck TUI lists that show hardware labels must split parseable labels into fixed-width hardware columns (`Model`, `CPU`, `GPU`, `RAM`, `Disk`) with field-specific colors. Keep plain `TextLines` aligned for selected rows, and use separate colored `RenderLines` for non-selected rows. If a column overflows because of current Windows Terminal width, wrap that row into continuation lines and make the viewport calculation line-aware so the footer/header remain stable.
Files affected: `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `06-RemoteConnectionOfflineMenu.ps1`; `internal\Test-DeviceCheckStructure.ps1`; non-interactive sample render of an offline snapshot row confirmed aligned `Hardware label`, `PC name`, `Last IP`, `Devices`, `Captured`, and `Status` columns.

Date: 2026-07-07
Problem: Opening the Offline Snapshots submenu crashed with `The property 'Count' cannot be found on this object` after adding wrapped hardware columns.
Root cause: The row wrapper stored per-column line results in a loosely typed array, and the selected `< Back to networks` row used a subexpression that unwrapped `@($item.Text)` into a scalar string. Under `Set-StrictMode -Version Latest`, direct `.Count` access on those strings is a terminating error.
Guardrail/rule: In DeviceCheck TUI helpers that store nested line collections, use typed nested collections such as `List[string[]]` or explicitly assign arrays before reading `.Count`. Avoid `$()` subexpressions around `@(...)` when the result will be counted. Always run a StrictMode smoke for helper functions and selected non-wrapped rows that will be called from `DeviceCheck.ps1`.
Files affected: `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `06-RemoteConnectionOfflineMenu.ps1`; StrictMode non-interactive render smoke across widths 190, 165, 145, and 130; StrictMode smoke for selected `< Back to networks` row; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`.

Date: 2026-07-07
Problem: Offline snapshot libraries became hard to scan after hardware labels improved because desktops and laptops were mixed in one long network list.
Root cause: The offline network view grouped only by saved network, not by physical device type, even though snapshots already include useful battery/device evidence.
Guardrail/rule: Offline snapshot network views should keep device-type sections always expanded. Classify laptops first by captured ACPI battery devices (`Microsoft ACPI-Compliant Control Method Battery`), then by laptop model keywords. Classify desktops by desktop model keywords and strong desktop CPU suffixes such as Intel `K`, Ryzen `X`, and AMD `FX` desktop parts. Use `Unknown` rather than guessing when evidence is weak.
Files affected: `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `06-RemoteConnectionOfflineMenu.ps1`; StrictMode classification smoke over real `.devicecheck-data\snapshots` returned 14 laptops and 8 desktops; `PALIOS` and `NEOS` classified as desktops via desktop CPU evidence.

Date: 2026-07-07
Problem: Laptop/desktop classification should improve as more workbench PCs are captured, not depend only on old snapshot labels and PnP battery devices.
Root cause: New snapshots did not store dedicated physical-form-factor evidence such as chassis type, PC system type, or `Win32_Battery`; classification therefore had to infer too much from labels and device names.
Guardrail/rule: Capture physical-kind evidence in both local and remote snapshots: `Win32_ComputerSystem.PCSystemType`, `PCSystemTypeEx`, `Win32_SystemEnclosure.ChassisTypes`, and `Win32_Battery`. Classifier precedence should be chassis type, PC system type, `Win32_Battery`, PnP ACPI battery, laptop/desktop model keywords, desktop CPU hints, then `Unknown`.
Files affected: `internal\DeviceCheck\02-MachineAndTarget.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for changed PowerShell files; StrictMode classification smoke over existing snapshots returned 14 laptops and 8 desktops; temp-output local quick exporter smoke confirmed `PCSystemType`, `PCSystemTypeEx`, `SystemEnclosure`, and `Batteries` are written, with current laptop chassis type `31` and one battery.

Date: 2026-06-12
Problem: `DeviceCheck.ps1` had grown past 8,100 lines, making review, AI-assisted edits, and bug isolation slow and risky.
Root cause: Most feature areas lived in one root script even though they had clear boundaries such as model selection, evidence resolvers, remote connection workflows, rendering, lookup actions, and input handling.
Guardrail/rule: Keep `DeviceCheck.ps1` as the entrypoint with startup state and the main event loop. Put new reusable functions into the appropriate dot-sourced `internal\DeviceCheck\*.ps1` function group, and use `$script:DeviceCheckRepoRoot` inside those groups for repo-root paths instead of `$PSScriptRoot`.
Executable guardrail: Run `pwsh -ExecutionPolicy Bypass -File .\internal\Test-DeviceCheckStructure.ps1` after DeviceCheck edits. The guard fails when `DeviceCheck.ps1` exceeds the entrypoint line budget, regains local function definitions, has parser errors, is missing function-group parts, or any dot-sourced part exceeds its per-file budget. Use `git config core.hooksPath .githooks` to enable the tracked local pre-commit hook, and keep `.github\workflows\devicecheck-structure.yml` as the PR/push safety net.
Files affected: `DeviceCheck.ps1`, `internal\DeviceCheck\*.ps1`, `internal\Test-DeviceCheckStructure.ps1`, `.githooks\pre-commit`, `.github\workflows\devicecheck-structure.yml`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1` and every `internal\DeviceCheck\*.ps1` part; non-interactive loader smoke loaded all parts, initialized available models, and read machine evidence; local resolver/inventory smoke initialized hardware, board, ALSA, and monitor resolvers and ran `Invoke-SystemScan -Quiet`; `internal\Test-DeviceCheckStructure.ps1`.

Date: 2026-06-08
Problem: DeviceCheck needed to compare known-good installed drivers with SDIO's indexed candidates without copying SDIO source logic or treating fallback matches as exact driver proof.
Root cause: SDIO ranks candidates from its own INF indexes and can propose same-version drivers through compatible IDs even when the installed driver matched a more specific hardware ID such as `SUBSYS+REV`. The first NEOS Realtek 5GbE sample showed SDIO candidates with status `CURRENT+WORSE` because the SDIO INF rows matched `PCI\VEN_10EC&DEV_8126&REV_01` / `PCI\VEN_10EC&DEV_8126`, not the installed exact `PCI\VEN_10EC&DEV_8126&SUBSYS_7E511462&REV_01`.
Guardrail/rule: Treat SDIO as an external audit oracle. Parse SDIO matcher logs and store candidate facts, status bits, INF path, pack path, version/date, and match kind, but do not promote SDIO candidates into install recommendations. DeviceCheck must label exact hardware ID, matching-device ID, hardware-ID, and compatible-ID fallback matches separately.
Files affected: `internal\Invoke-SdioDriverAudit.ps1`, `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1` and `internal\Invoke-SdioDriverAudit.ps1`; passive SDIO parse against the NEOS log `D:\Temp\Windows\UserTemp\DeviceCheck-SDIO-20260608-010409\logs\log.txt` matched the Realtek 5GbE device, wrote DeviceCheck cache JSON, and confirmed first SDIO candidate as `CompatibleId / WORSE+CURRENT`, version `10.79.50.1003`, HWID `PCI\VEN_10EC&DEV_8126&REV_01`; all-device cache population from the same log wrote 49 per-device SDIO cache files; `git diff --check`; no-index whitespace check for new `internal\Invoke-SdioDriverAudit.ps1`.

Date: 2026-06-08
Problem: During SDIO audit exploration, ad hoc PowerShell diagnostics repeatedly hit parser errors when complex inline expressions were piped directly.
Root cause: Combining `foreach` output, hashtable/object construction, inline `if/else`, and a trailing pipeline in one command made it easy for PowerShell to parse an empty pipe element or malformed expression.
Guardrail/rule: For diagnostic object pipelines, assign `foreach` output to a named `$rows` variable first, avoid inline multi-statement `if/else` inside hashtable values unless the expression is safely parenthesized, and pipe `$rows` afterward. Prefer small diagnostic scripts over compressed one-liners when inspecting logs or registry/device data.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Captured after real parser failures in SDIO log/device audit diagnostics.

Date: 2026-06-07
Problem: Agent answers rendered as all-white plain text, so Markdown structure, links, inline hardware IDs, source sections, and warnings were hard to scan in the selected-details pane.
Root cause: The TUI intentionally called `Convert-MarkdownResultToPlain` before wrapping the Agent answer, stripping Markdown markers and then coloring every answer line white. PowerShell's built-in `Show-Markdown` / `ConvertFrom-Markdown -AsVT100EncodedString` can render Markdown, but its output is a full terminal-oriented VT100 string and can violate DeviceCheck's pane width/height control.
Guardrail/rule: Render Agent Markdown through a controlled TUI-safe formatter that owns wrapping, ANSI width accounting, and the frame height budget. Use built-in Markdown cmdlets as references or for standalone viewing, not as raw embedded output inside the DeviceCheck immediate-mode frame unless their output is normalized first.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `Get-DriverUpdateAgent.ps1`, `PS_UI_Blueprint.psm1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; local `Show-Markdown` / `ConvertFrom-Markdown -AsVT100EncodedString` smoke showed raw VT100 rendering and bullet formatting that should not be embedded directly; `git diff --check`.

Date: 2026-06-07
Problem: A cached PALIOS Agent run did not open the browser, but `[Tool Result]` JSON still contained nested `{ Type = Log, Message = ... }` objects before the actual cached result. The first follow-up fix then made Agent terminate unexpectedly immediately after `Requested tool`.
Root cause: Tool functions called `Write-AgentEvent`, which emits `Write-Output`, while those same functions were being captured into `$toolResult`. In PowerShell, any pipeline output produced inside a captured function can become part of the function result. The deferred-event fix also referenced `$script:AgentDeferredEvents` before initialization under `Set-StrictMode -Version Latest`, which is a terminating error.
Guardrail/rule: Agent tool-internal telemetry must not write directly to the output pipeline. Cache hit/miss, browser start/complete, and timing events should be deferred in initialized script-scope state and flushed by the main agent loop after the tool call has returned. Under StrictMode, initialize script-scope queues before first use or check existence with `Get-Variable`; never probe an undefined `$script:` variable directly. Keep `Write-AgentEvent` for top-level agent events that are intentionally streamed to the TUI.
Files affected: `Get-DriverUpdateAgent.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `Get-DriverUpdateAgent.ps1`, `PS_UI_Blueprint.psm1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; Node syntax validation for `tools\Search-GoogleRendered.js` and `tools\Fetch-RenderedPage.js`; parsed the failed PALIOS Agent log ending at `Requested tool`; `git diff --check`.

Date: 2026-06-07
Problem: Agentic `A` mode felt like it had unexplained 30-60 second pauses between steps, even when Gemini itself might not be slow.
Root cause: The Agent trace only logged before Gemini calls, requested tools, and final tool results. It did not log cache hit/miss, live tool start, live tool completion duration, rendered-browser helper timing, or Gemini response duration. The PALIOS Intel I219-V trace showed the real delays were rendered-browser tools: `SearchGoogleRendered` took about 58.8s and `FetchRenderedUrlText` about 30.7s, while Gemini responses took about 1-3s. The Node helpers also contain deliberate page-settling waits for Chrome startup, consent handling, typing/search submission, result loading, scrolling, and extraction.
Guardrail/rule: Agent logs must make blocking work visible. Log cache hit/miss, live tool start, live tool completion duration, rendered browser timeout/duration, per-stage browser helper timings, and Gemini response duration. Surface the latest Agent activity in the TUI status line so long waits identify the current blocking call instead of looking like dead air. Do not remove rendered-browser waits blindly; first measure which stage consumes time and whether cached/direct official-page paths can avoid the rendered search entirely.
Files affected: `Get-DriverUpdateAgent.ps1`, `DeviceCheck.ps1`, `tools\Search-GoogleRendered.js`, `tools\Fetch-RenderedPage.js`, `.gitattributes`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `Get-DriverUpdateAgent.ps1`, `PS_UI_Blueprint.psm1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; Node syntax validation for `tools\Search-GoogleRendered.js` and `tools\Fetch-RenderedPage.js`; parsed the PALIOS Intel I219-V Agent JSONL trace and measured event deltas; `git diff --check`.

Date: 2026-06-07
Problem: In remote snapshot mode, pressing `A` after refreshing PALIOS still showed `Web/AI lookups are local-target only... Press R to refresh PALIOS`, even though `R` had already refreshed the snapshot.
Root cause: The first remote slice blocked all Web/AI and Agent lookups whenever `TargetMode = RemoteSnapshot`, despite the snapshot already containing enough per-device PnP properties for local AI/web analysis. The status text incorrectly implied refresh would unlock a path that was still hard-blocked.
Guardrail/rule: Remote snapshot mode is a first-class target, not a view-only fallback. Any feature that can work from captured evidence should work for remote snapshots too, using snapshot evidence as its provider. Do not imply `R` changes feature availability; `R` refreshes snapshot data, while AI/web analysis should label its evidence source as `remote snapshot`. Only features that truly require live commands should ask for explicit live refresh/connection.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `PS_UI_Blueprint.psm1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; PALIOS latest snapshot smoke confirmed `Intel(R) Ethernet Connection (2) I219-V` has 72 captured properties including `DEVPKEY_Device_HardwareIds`; `git diff --check`.

Date: 2026-06-07
Problem: Pressing `A` on a selected device could appear to do nothing when Agent prerequisites were missing, especially when `GOOGLE_API_KEY` / `GEMINI_API_KEY` was not configured on another PC.
Root cause: The missing-key branch updated only the selected device search rows and details state, but did not update the top status/message line. The Agent/Web hotkey path also returned silently for unsupported selections.
Guardrail/rule: Any TUI hotkey that starts, blocks, cancels, or refuses a background action must update the visible status/message line immediately. Missing API keys and invalid selections are user-visible states, not silent no-ops.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `PS_UI_Blueprint.psm1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; static lookup of new status-message branches; `git diff --check`.

Date: 2026-06-07
Problem: The header subtitle repeated low-value or overly long system information such as generic system manufacturer/model strings, full Windows captions, full CPU marketing strings, live clock text, and long device/category words.
Root cause: `Get-MachineSummary` reused evidence-style raw fields for the header instead of a presentation-only compact summary.
Guardrail/rule: Header text is presentation-only. Keep full machine/system/board/CPU/OS data in evidence and details, but compact the header to stable high-signal fields: computer name, useful board product, compact CPU, compact OS, and `dev` / `cat` counts. Avoid guessing subjective motherboard names beyond safe boilerplate trims.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `PS_UI_Blueprint.psm1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; isolated header formatter smoke for NEOS and PALIOS examples; `git diff --check`.

Date: 2026-06-07
Problem: Long values in the selected details pane, especially `InstanceId`, were truncated with `...` while path rows such as `Cache` wrapped, making important hardware evidence unreadable.
Root cause: Most selected-details rows used a single-line `New-KeyValueLine` helper that formatted values with `Format-UiValue`, while path rows had a separate wrapping helper.
Guardrail/rule: Selected-details values should wrap into real generated frame rows using the current pane width. Do not rely on terminal soft-wrap, and do not use ellipsis for evidence identifiers that the user needs to inspect. Continuation rows should align under the value column and reflow naturally on live resize.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `PS_UI_Blueprint.psm1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; isolated `Add-KeyValueLines` smoke confirmed a long `InstanceId` wraps into multiple rows without `...`; verified no selected-details `.Add((New-KeyValueLine ...))` calls remain; `git diff --check`.

Date: 2026-06-07
Problem: After adding remote/login screens, DeviceCheck still broke the main TUI header when Windows Terminal was resized to very small widths/heights, while copied terminal text looked correct and the WinAppManager UI stayed stable.
Root cause: DeviceCheck only partially adopted the reusable UI blueprint. The remote modal screens used `Add-UiFrameBanner` / `Write-UiFrame`, but the main screen still used a separate legacy `Render-Frame` / `Add-FrameBanner` path with its own height math. In narrow mode it reserved fixed stacked detail rows even when the viewport could not fit them. The shared blueprint also still returned a minimum width of 60 columns even when the real viewport was smaller, and `Lock-ViewportToWindow` checked only buffer height, not width.
Guardrail/rule: Do not treat the UI template as a visual copy-paste layer. Complex TUIs must have one canonical frame pipeline and every branch must prove it writes no more than the current viewport height. Width helpers must never report more columns than the real viewport. Buffer locks must check both width and height. In short/narrow terminals, hide lower-priority panels before allowing scrollback movement.
Files affected: `DeviceCheck.ps1`, `PS_UI_Blueprint.psm1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `PS_UI_Blueprint.psm1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; narrow renderer line-budget smoke for terminal heights 16/20/24/25/30/40 with and without batch status; `git diff --check`.

Date: 2026-06-06
Problem: Even with ultra-fast rendering (3.5ms - 6ms), TUI scrolling during held arrow key repeat rate (~30-33Hz) was not smooth and suffered from stuttering.
Root cause: The idle key polling sleep of 40ms (`Start-Sleep -Milliseconds 40`) restricted the event loop frequency to ~25Hz with high jitter, causing the rendering of buffered keypresses to desynchronize from the input rate.
Guardrail/rule: Match the key polling loop sleep duration to the performance of the rendering pipeline. When rendering is fast (under 10ms), use a low polling sleep (e.g. 10ms) to achieve smooth, low-latency rendering synchronized with keyboard repeat rates without sacrificing CPU efficiency.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Checked `tui_benchmark.log` timings; verified `KeyDelay` matches ~30ms repeat rate with `KeyRead` latency minimized to 10-25ms; verified CPU usage remains minimal.

Date: 2026-06-06
Problem: Profiling performance lags during keyboard scrolling is difficult without timing data for key reads, event handlers, and screen rendering.
Root cause: Standard PowerShell hosts do not offer built-in latency logging for TUI event loops, and real-time logging to disk adds I/O lag that degrades scroll performance.
Guardrail/rule: When benchmarking TUI performance, collect stopwatch measurements in memory during the execution loops. Write the accumulated results to a log file (`tui_benchmark.log`) only when the session exits in the `finally` block to avoid disk write overhead during active navigation.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation succeeded; verified that exiting the TUI session successfully outputs a complete `tui_benchmark.log` with millisecond-level breakdowns for each keystroke.

Date: 2026-06-06
Problem: Rapid arrow navigation in the TUI skipped devices and felt laggy, and non-arrow keys could be swallowed/ignored. Also, non-maximized console windows suffered from double/layered banners and footers.
Root cause: Experimental arrow-key batching drained inputs from the console queue, which consumed non-arrow keys and skipped selection nodes. The standard `Clear-Host` on every frame caused visual blinking and redraw overhead. If the number of lines written in a frame exceeded the console window height, it scrolled the screen buffer, resulting in duplicate headers/footers when cursor positioning home was called.
Guardrail/rule: Do not use input batching to mask slow render frame times. Replace `Clear-Host` with cursor repositioning (`[Console]::Write("$($_E)[H")`) and trailing line erases for fast redraws. Gate full clears behind `$script:RequestForceClear`. Strictly calculate and constrain the visible row counts (`$maxVisible`) to ensure the total line output never exceeds `WindowSize.Height - 1`, preventing scrollback buffer overflow.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation succeeded; verified correct key handling, zero-flicker rendering, and strict height boundary constraints in both standard TUI loop and `Invoke-ModelSelector` dialog loop.

Date: 2026-06-04
Problem: ChatGPT/Gemini deep-research PDFs defined a broad local evidence database architecture, but the repo needed a practical laptop-ready implementation plan and the research files had to be preserved in Git.
Root cause: The research output was PDF-only and too broad to execute directly; without a repo-local plan, future laptop work could jump straight into ad hoc mappings or parser work without schemas, provenance, or harness guardrails.
Guardrail/rule: Treat `docs\LOCAL_HARDWARE_IDENTITY_DATABASE_PLAN.md` as the current roadmap for the local hardware identity database. Implement schema/harness/source-provenance work before broad enrichment sources. Keep the Realtek `USB\VID_0DB0&PID_CD0E&MI_00` case as a regression fixture proving incomplete `usb.ids` behavior, not as a hardcoded single-device feature.
Files affected: `docs\DeviceCheck_ Local Hardware Identity Design.pdf`, `docs\Designing a Reliable Local Digital Evidence Architecture.pdf`, `docs\LOCAL_HARDWARE_IDENTITY_DATABASE_PLAN.md`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `internal\HardwareIdResolver.psm1`, `internal\Resolve-HardwareIds.ps1`, and `internal\Update-HardwareIdDatabases.ps1`; JSON validation for `config\board-model-evidence.json` and `config\hardware-sources.json`; resolver smoke for `USB\VID_0DB0&PID_CD0E&REV_0005&MI_00` confirmed `VENDOR-ONLY`; PDF/plain-text extraction smoke read both research PDFs; `git diff --check`.

Date: 2026-06-04
Problem: `USB\VID_0DB0&PID_CD0E&MI_00` belongs to the desktop Realtek USB Audio path, and a chat answer claimed that upstream `usb.ids` contains `cd0e  USB Audio [Realtek ALC4080]`.
Root cause: Local and current upstream `usb.ids` sources only resolve `VID_0DB0` to Micro Star International and do not contain `PID_CD0E`; the exact `ALC4080` identity comes from correlating local motherboard evidence (`MAG X870 TOMAHAWK WIFI`) with MSI official specifications, not from the USB ID database or installed INF alone.
Guardrail/rule: Do not hardcode USB PID-to-codec mappings from chat/web claims. Verify local `source\hwdata\usb.ids`, generated `data\hwdb`, direct upstream `linux-usb.org/usb.ids`, hwdata raw, and usbids raw before treating a USB product name as database truth. If the exact codec comes from motherboard/OEM spec correlation, label it as derived/spec inference with source and confidence, not as `usb.ids` product identity.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `docs\GEMINI_NEXT_STEP_USB_AUDIO_IDENTITY.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `internal\HardwareIdResolver.psm1`, `internal\Resolve-HardwareIds.ps1`, and `internal\Update-HardwareIdDatabases.ps1`; JSON validation for `config\board-model-evidence.json` and `config\hardware-sources.json`; resolver smoke for `USB\VID_0DB0&PID_CD0E&REV_0005&MI_00` confirmed `VENDOR-ONLY` with empty `ProductName`; direct upstream checks against hwdata raw, `linux-usb.org/usb.ids`, and `usbids/usb.ids` found no `cd0e` product row; `git diff --check`.

Date: 2026-06-04
Problem: After the new structured `HardwareId` breakdown, the `Local Hardware Identity` section repeated the same facts as separate `Chip`, `Board Vendor`, `Board IDs`, `Exact Model`, and `Search Hint` rows, making the details pane noisy.
Root cause: The older local identity section was designed before the device-property breakdown existed, so it carried both parsed-ID explanation and evidence summary responsibilities.
Guardrail/rule: Keep parsed ID anatomy in `Device Properties` under the `HardwareId` breakdown. Keep `Local Hardware Identity` as an evidence summary: local match confidence/source, exact model when a source actually provides it, board-model evidence, confidence, source, and URL. Show fallback coverage/search-hint rows only when there is no better exact model or board evidence.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1` and `internal\HardwareIdResolver.psm1`; extracted GPU detail-row smoke for `PCI\VEN_10DE&DEV_2803&SUBSYS_51741462&REV_A1` confirmed `Local Hardware Identity` now contains only `Local Match`, `Board Model`, `Confidence`, `Source`, and `URL`; extracted breakdown smoke confirmed `SUBSYS_51741462` remains in `Device Properties`; `git diff --check`.

Date: 2026-06-03
Problem: The desktop repo depended on `source\hwdata` to rebuild `data\hwdb`, but `.gitignore` ignored all of `source`, so clones/branch moves could miss the runtime-critical ID files even though generated cache folders are intentionally ignored.
Root cause: The ignore rule treated cloned study sources and adopted runtime source data the same way.
Guardrail/rule: Track only the runtime-critical adopted `source\hwdata` files (`pci.ids`, `usb.ids`, `pnp.ids`, plus license/readme files) while keeping cloned study repos and generated caches ignored. Do not broaden this to whole upstream repos without an explicit packaging/license decision.
Files affected: `.gitignore`, `.gitattributes`, `source\hwdata\pci.ids`, `source\hwdata\usb.ids`, `source\hwdata\pnp.ids`, `source\hwdata\README`, `source\hwdata\LICENSE`, `source\hwdata\COPYING`, `README.md`, `CHANGELOG.md`, `docs\HARDWARE_SOURCE_INTAKE.md`, `PROJECT_RULES.md`.
Validation/tests run: `git check-ignore -v` confirmed only the adopted `source\hwdata` ID/license/readme files are unignored while study repos and non-adopted upstream files remain ignored; parent repo untracked-file check now shows the six adopted files after removing nested `source\hwdata\.git`; `git diff --check`; `git ls-files --eol` for tracked text policy.

Date: 2026-06-03
Problem: The user's desktop GPU exact marketing model is known, but local `pci.ids` only resolves chip and MSI board vendor/subdevice, not `MSI RTX 4060 Ti Ventus 2X Black OC 16 GB`.
Root cause: Public `pci.ids` subsystem coverage is incomplete for exact board marketing names, and search hints are not strong enough to present as exact identity.
Guardrail/rule: Store exact board/marketing names in a separate read-only board-model evidence layer with explicit source/confidence, and only display them when the PCI tuple matches. Do not convert search hints into exact model claims, and do not scrape/licensed GPU databases without a separate adapter/licensing decision.
Files affected: `DeviceCheck.ps1`, `config\board-model-evidence.json`, `docs\GEMINI_NEXT_STEP_GPU_BOARD_MODEL_EVIDENCE.md`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1` and `internal\HardwareIdResolver.psm1`; JSON parse for `config\board-model-evidence.json`; resolver smoke for `PCI\VEN_10DE&DEV_2803&SUBSYS_51741462&REV_A1`; extracted detail-row smoke confirmed `Exact Model` remains local-missing while `Board Model`, `Board Evidence`, and `Evidence URL` render from local evidence; `git diff --check`.

Date: 2026-06-03
Problem: The desktop TUI showed `Local ID: Unavailable; run internal\Update-HardwareIdDatabases.ps1` even after the resolver UI work, so the user saw no GPU identity improvement.
Root cause: `data\hwdb` is a generated/ignored cache and may not exist on another machine even when `source\hwdata` is present. Startup only tried to load the generated cache and did not bootstrap it.
Guardrail/rule: Generated local database caches must be self-healing when their source folder exists. At startup, DeviceCheck may build `data\hwdb` from `source\hwdata` before entering the TUI; only show an unavailable local-ID message when both generated cache loading and source-based rebuild fail.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1`; temporary `data\hwdb` build smoke using `internal\Update-HardwareIdDatabases.ps1`; extracted helper smoke confirmed missing-cache autobuild creates normalized `pci.json`, `usb.json`, and `pnp.json`; `git diff --check`.

Date: 2026-06-03
Problem: PCI devices with useful `SUBSYS` data, such as `PCI\VEN_10DE&DEV_2803&SUBSYS_51741462`, were only identified at chip level even though the same ID also contains board-vendor evidence.
Root cause: The resolver only promoted exact `pci.ids` subsystem rows. When `pci.ids` had no `10DE:2803` subsystem model row, DeviceCheck ignored the fallback subvendor lookup from the PCI vendor table.
Guardrail/rule: PCI identity must be shown in layers: chip vendor/device from `VEN/DEV`, exact subsystem model only when present, and board vendor/subdevice fallback from `SUBSYS` when exact model data is absent. Do not claim an exact board marketing model from `pci.ids` alone unless the exact subsystem row exists; use the layered identity to build better search terms and to decide which extra source database is needed.
Files affected: `internal\HardwareIdResolver.psm1`, `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Resolver smoke for `PCI\VEN_10DE&DEV_2803&SUBSYS_51741462&REV_A1` returned `EXACT-DEVICE+SUBVENDOR`, NVIDIA AD106/RTX 4060 Ti, subvendor `Micro-Star International Co., Ltd. [MSI]`, and subdevice `5174`; extracted detail-row smoke produced chip, board vendor, board IDs, exact-model-missing, and search-hint rows; PowerShell parser validation; `git diff --check`.

Date: 2026-06-03
Problem: Local source repos needed to inform DeviceCheck's driver-finding design without accidentally importing unsafe install/download behavior or GPL code.
Root cause: `source\OpenDriverUpdater` has useful metadata vocabulary but mostly stubbed source adapters, while `source\wininfparser` is GPL-3.0 and cannot be copied into DeviceCheck's own parser implementation.
Guardrail/rule: Use OpenDriverUpdater as a concept reference for `DeviceInfo`, `CandidateDriver`, `UpdateRecommendation`, version comparison, source priority, and trust-factor vocabulary only. Use wininfparser as a behavior reference only; keep `internal\InfDriverParser.psm1` independently implemented. Candidate metadata may include read-only `Recommendation` fields, but download/install/signature-verification workflows remain out of scope until a separate safety workflow exists.
Files affected: `config\driver-candidate-package.schema.json`, `internal\Test-DriverCandidatePackageMetadata.ps1`, `docs\LOCAL_SOURCE_PROJECT_AUDIT.md`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: JSON parse for `config\*.json`; parser validation for touched PowerShell scripts/modules; template smoke confirmed the optional `Recommendation` object; validator smoke accepted the generated template as expected `IncompleteMetadata`; `git diff --check`.

Date: 2026-06-03
Problem: Pressing `E` could save selected-device evidence before the TUI clearly treated that device as evidence-cached, so the user might need another render/selection movement to trust that details were fresh.
Root cause: `EvidenceCached` was marked only during active-search cleanup, not when the evidence pipeline output first reported a saved/loaded evidence path.
Guardrail/rule: Local evidence output should update the selected device's in-memory cache state as soon as the evidence result arrives. Keep the left tree free of evidence bookkeeping rows; show the useful result in the details pane and status line.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1` and `HardwareIdResolver.psm1`; isolated `Update-SearchFromPipelineOutput` smoke confirmed `EvidenceCached=True` and status-line update as soon as evidence output arrives; static helper presence check; `git diff --check`; pending user visual TUI smoke.

Date: 2026-06-03
Problem: The remaining accidental `drivercheck` work needed a careful transfer audit instead of another broad copy.
Root cause: The donor repo contains both reusable hardware/driver-research tools and drivercheck-specific cleanup/snapshot tools for a different purpose.
Guardrail/rule: Treat the shared `internal\` hardware/driver-research scripts as migrated only when byte-identical or intentionally adapted in `DeviceCheck`. Do not copy `drivercheck` cleanup/snapshot tools such as `Compare-DriverSnapshots.ps1`, `Invoke-DriverCleanupFromSnapshots.ps1`, or `Save-DriverSnapshot.ps1` into `DeviceCheck` unless the Device Manager workflow explicitly needs them.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Hash audit confirmed all common `internal\` migrated scripts/modules are byte-identical between donor and target; config/docs are intentionally adapted for `DeviceCheck`.

Date: 2026-06-03
Problem: Selected-device cached evidence had useful installed-driver fields, but the TUI compressed them into one hard-to-read driver line.
Root cause: The evidence collection already captured `Win32_PnPSignedDriver` and key PnP driver properties, but the details pane treated that as a summary string rather than a scan-friendly section.
Guardrail/rule: Installed-driver evidence may be integrated into the TUI as a read-only presentation layer using already-cached fields only. Keep INF parsing, trust scoring, package metadata, downloads, installs, and rollback decisions outside the TUI until their own layer is explicitly integrated and verified.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1` and `HardwareIdResolver.psm1`; extracted-helper smoke against real cached Wi-Fi evidence resolved provider/version/INF/service; static check confirmed cached evidence driver/detail fields use safe optional-property reads; `git diff --check`; pending user visual TUI smoke.

Date: 2026-06-03
Problem: The first selected device after launch caused a 1-2 second TUI lag/black frame when cached evidence exposed local Hardware ID details.
Root cause: `Get-LocalHardwareIdentitySummaries` initialized and loaded the Hardware ID resolver/database from inside the selected-device details render path.
Guardrail/rule: Never load modules, parse databases, scan files, or perform other heavy cache initialization from per-frame render/detail functions. Preload required caches during startup or move them to explicit background work, then let render functions consume only already-loaded in-memory state.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1` and `HardwareIdResolver.psm1`; static check confirmed no resolver initialization inside `Get-LocalHardwareIdentitySummaries`; resolver smoke; `git diff --check`; pending user visual TUI smoke.

Date: 2026-06-03
Problem: The migrated Hardware ID resolver needed to reach the interactive DeviceCheck UI without rushing the deeper INF/trust/package layers into the TUI.
Root cause: The migrated engine is useful, but DeviceCheck already has a complex evidence cache and rendering loop where filesystem work or broad feature wiring can cause flicker/lag.
Guardrail/rule: Integrate migrated engine features into the TUI one layer at a time. The first allowed integration is read-only local Hardware ID resolution in the selected-device details pane, using cached resolver/database state and cached selected-device evidence only. Do not wire INF evidence, trust scoring, package metadata, downloads, or installs into the TUI until each prior layer is verified.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1` and `HardwareIdResolver.psm1`; resolver smoke; pending user visual TUI smoke.

Date: 2026-06-03
Problem: Hardware ID / driver-research prototype work was accidentally implemented in sibling repo `drivercheck` while the intended target was `DeviceCheck`.
Root cause: The active Codex workspace was `D:\Users\joty79\scripts\drivercheck`, but the user-provided research docs and cloned source repos were under `D:\Users\joty79\scripts\DeviceCheck`.
Guardrail/rule: Treat the migrated `internal\` engine/config/docs as DeviceCheck-owned from now on. Do not continue this feature in `drivercheck`. Keep the migrated engine audit-only until it is explicitly integrated into the existing DeviceCheck TUI and agent workflow.
Files affected: `.gitignore`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`, `internal\*`, `config\*`, `docs\HARDWARE_SOURCE_INTAKE.md`, `docs\GEMINI_NEXT_STEP_DRIVER_PACKAGE_ADAPTERS.md`.
Validation/tests run: Migration path audit; donor/target conflict check; mechanical file transfer; parser validation for migrated internal scripts; config JSON parse; hardware database import from `DeviceCheck\source\hwdata`; resolver smoke; inventory report smoke; candidate/INF/evidence bundle smokes; metadata template smoke; adapter plan smoke; `git diff --check`.

Date: 2026-05-30
Problem: Google AI Studio quota rows can be misread because text-out model quotas and tool-specific grounding quotas are shown in nearby dashboard sections.
Root cause: The `Tools` section exposes high RPD values for grounding paths, but `DeviceCheck.ps1` currently calls the `generateContent` text path.
Guardrail/rule: Before changing `$geminiModel` for quota reasons, verify the exact dashboard row belongs to the same API path used by the script.
Files affected: `PROJECT_RULES.md`, `CHANGELOG.md`, `.gitattributes`, `data/google-ai-studio-rate-limits-only free.csv`, `docs/google-ai-studio-rate-limits-only-free.md`.
Validation/tests run: `Import-Csv`; `git diff --check`; `git ls-files --eol`.

Date: 2026-05-30
Problem: AI result rows could look more authoritative than the evidence because only the first DuckDuckGo snippet was visible while all snippets were passed to Gemini/OpenRouter.
Root cause: `Search-DeviceWeb` collected up to 3 snippets, but the TUI displayed only `WebVal`, which is the first snippet.
Guardrail/rule: Display all collected web snippets as numbered evidence rows before relying on AI summaries.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`.

Date: 2026-05-30
Problem: Free-tier AI/API usage should not be spent repeatedly on devices before local evidence is captured and reusable.
Root cause: The lookup flow had no stable machine identity or selected-device evidence cache, so each lookup depended on live collection/web/AI state.
Guardrail/rule: Create a stable local machine ID from SMBIOS/CIM evidence, cache selected-device JSON under `%LOCALAPPDATA%\DeviceCheck\machines\<machineId>\devices\`, and include local evidence in AI prompts before web snippets.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`; `git ls-files --eol`.

Date: 2026-05-30
Problem: Evidence cache paths were visible, but selected-device scan details were not presented clearly or available as a local-only action.
Root cause: The UI only exposed evidence as a search result row, and `S` mixed local evidence collection with web/AI lookup.
Guardrail/rule: Keep `R` for system/PnP refresh, `E` for selected-device local evidence scan, and `S` for selected-device evidence refresh plus web/AI lookup; always show cached selected-device evidence in the details panel when available.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`.

Date: 2026-05-30
Problem: Pressing `R` looked like nothing happened because the synchronous system scan usually completed quickly and only changed a timestamp.
Root cause: The TUI did not render an explicit running state before blocking on `Get-PnpDevice -PresentOnly`, and the completion message did not report scan scope.
Guardrail/rule: `R` means a full present-PnP-tree refresh with machine evidence only, not deep per-device evidence. Render a visible running message before the scan and a complete message with device/category counts afterward.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`; non-admin `Get-PnpDevice -PresentOnly` smoke with device/category count.

Date: 2026-05-30
Problem: The TUI exposed PnP/setup class tokens such as `AudioEndpoint`, `HIDClass`, and `Net`, which made it harder to compare against Windows Device Manager.
Root cause: Category display reused internal PnP class keys directly.
Guardrail/rule: Keep internal PnP class keys for logic/cache, but render common categories with Device Manager-style names and use the Windows system name as the root row. Keep the stable machine hash for database paths, not primary human-facing labels.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`; non-admin class-name mapping smoke; non-admin System Information summary smoke.

Date: 2026-05-30
Problem: Long system status text overflowed past the blue header border, and the bottom details panel wasted space on wide terminals.
Root cause: The renderer used a single stacked layout and `Get-UiWidth` capped the UI at 100 columns while status text could continue across the real terminal width.
Guardrail/rule: Use a responsive renderer: dual-pane inside the same terminal when width is large enough, stacked fallback when narrow, and ANSI-aware truncation/padding for every row that must fit a pane or header.
Files affected: `DeviceCheck.ps1`, `PS_UI_Blueprint.psm1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1` and `PS_UI_Blueprint.psm1`; `git diff --check`.

Date: 2026-05-30
Problem: Selecting a device with cached evidence could crash under `Set-StrictMode` when an optional `ImportantProperties` key such as `DEVPKEY_Device_Service` was absent.
Root cause: The details renderer used direct dot-property access on optional JSON properties.
Guardrail/rule: Treat all cached evidence properties as optional and read them through a safe note-property helper.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`; strict-mode safe missing-property helper smoke.

Date: 2026-05-30
Problem: `Enter` for expand/collapse did not match the user's Device Manager muscle memory.
Root cause: The TUI reused a generic menu convention instead of Device Manager's `+`/`-` tree convention.
Guardrail/rule: Use `+` to expand and `-` to collapse. On the computer root, apply the action to every category; on a category, apply it only to that category. Arrow keys may remain as secondary navigation helpers.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`.

Date: 2026-05-30
Problem: The wide dual-pane view looked unbalanced because the right details pane became much wider than the device tree.
Root cause: The left pane was capped at 78 columns even on very wide terminals.
Guardrail/rule: In wide dual-pane mode, split the available terminal width near 50/50 unless a future measured UX issue requires a different ratio.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; dual-pane width math smoke for 136/160/204/240 columns; `git diff --check`.

Date: 2026-05-30
Problem: `[Evidence Cache]` rows appeared as children in the left device tree after scanning a device, making local cache bookkeeping look like a device/search result.
Root cause: Evidence collection status/results were appended to `SearchResults`, which is rendered in the tree.
Guardrail/rule: Keep cache/evidence status in the selected-device details pane. The left tree should show devices plus actual lookup outputs such as AI, local DB, and web snippets.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`; static `SearchResults` evidence-row check.

Date: 2026-05-30
Problem: Pressing `E` on a category such as `Disk drives` did nothing, even though category-level evidence collection is useful before spending web/AI quota.
Root cause: The `E` hotkey only handled device rows and result/status rows with a parent device.
Guardrail/rule: `E` on a category must start local evidence scans for every device in that category. Already-running device scans should be left running, not toggled/cancelled by the group action.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`; static hotkey/helper checks.

Date: 2026-05-30
Problem: Category-level evidence scans crashed with `The property 'DisplayName' cannot be found on this object`.
Root cause: `Start-CategoryEvidenceScan` accessed an optional category property directly under `Set-StrictMode`; category objects currently have `Name`, not `DisplayName`.
Guardrail/rule: Treat category metadata fields as optional unless they are created in `Get-DeviceCategories`; use safe property reads for optional display fields.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; strict-mode category `DisplayName` fallback smoke; `git diff --check`.

Date: 2026-05-30
Problem: Pressing `E` on the computer root (`NEOS`) did not collect evidence for the whole machine.
Root cause: The `E` hotkey handled category/device/result rows, but skipped root rows.
Guardrail/rule: `E` should scale by selection scope: root scans all present devices, category scans that group, device scans only the selected device. Already-running device scans should be skipped, not toggled off, by scoped batch scans.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`; static root/category/device hotkey checks.

Date: 2026-05-30
Problem: Root-level `E` evidence scans made the UI lag because the app started one runspace per present device at once.
Root cause: The batch scan helper directly called `Start-DeviceLookup` for every selected device without throttling.
Guardrail/rule: Root/category evidence scans must use a throttled queue (`EvidenceBatchMaxConcurrent`) and a visible progress line. Do not start hundreds of evidence runspaces in one frame.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`; static evidence batch queue/progress checks.

Date: 2026-05-30
Problem: Evidence batch scans reached `195/195` but the progress line stayed visible and elapsed time kept increasing.
Root cause: Completed batch state was never cleared after queue and active batch searches reached zero.
Guardrail/rule: When a throttled evidence batch finishes, move the final result into the normal status line and clear `EvidenceBatchState`/queued IDs so progress rendering stops.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; strict-mode batch completion smoke; `git diff --check`.

Date: 2026-05-30
Problem: The UI could still feel laggy after large evidence scans even when the batch was complete.
Root cause: Root/category detail panels counted cached evidence with `Test-Path` across many devices on every render.
Guardrail/rule: Avoid filesystem work inside per-frame render paths. Track device evidence cache presence in memory and update the flag when an evidence scan completes.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `git diff --check`; static render-path filesystem check review.

Date: 2026-05-31
Problem: The TUI froze after ~2 seconds of scanning, and pressing keys threw a strict-mode exception on `$key.Key`.
Root cause: 1) Models with `State = 'None'` (e.g. missing API keys) stayed `Started = $false`, making `$hasPendingModel` permanently `$true` and spamming runspace triggers in the key loop. 2) The spam caused exceptions that crashed the loop inside `Read-ConsoleKey`, which returned a `$null` or incomplete object that failed under `Set-StrictMode` when evaluating `$key.Key`.
Guardrail/rule: Exclude models with `State = 'None'` when querying for pending model runs. Ensure `Read-ConsoleKey` always returns a valid custom object structure and never throws exceptions when reading key events.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation.

Date: 2026-05-31
Problem: User model selections in the `M` menu were lost and reverted to default when restarting the script.
Root cause: Selected models state was kept only in memory and never persisted.
Guardrail/rule: Save active model selections to `config.json` inside `$script:DeviceCheckCacheRoot` (`%LOCALAPPDATA%\DeviceCheck`) upon selector exit, and restore them during initialization.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation.

Date: 2026-05-31
Problem: If EndInvoke returned null or an incomplete collection, reading its Count property in strict mode caused an exception.
Root cause: Lack of null checks for EndInvoke outputs under Set-StrictMode -Version Latest.
Guardrail/rule: Always verify that runspace EndInvoke collection outputs are not null before accessing properties like Count or attempting iteration.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation.

Date: 2026-05-31
Problem: Background rendering or update exceptions inside Read-ConsoleKey were caught and swallowed, leading to a silent infinite loop that eventually crashed the script.
Root cause: The catch block in Read-ConsoleKey suppressed exceptions, returning an empty key object immediately, causing the main loop to re-call it immediately without delay.
Guardrail/rule: Rethrow unexpected exceptions inside Read-ConsoleKey to stop execution immediately and reveal the actual failure stack trace.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation.

Date: 2026-05-31
Problem: Querying for pending model runs returned null when no items matched, causing a strict-mode exception when reading the Count property.
Root cause: Directly accessing the Count property on a null-valued pipeline result under Set-StrictMode -Version Latest.
Guardrail/rule: Always wrap pipeline expressions in array subexpressions `@(...)` before accessing the Count property to ensure it safely evaluates to 0 when the result is null.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation.

Date: 2026-05-31
Problem: Unexpected thread/pipeline termination or key-reading failures could cause Read-ConsoleKey to return null, crashing the main switch statement.
Root cause: Accessing the Key property on a null $key variable under Set-StrictMode -Version Latest.
Guardrail/rule: Always verify that the $key variable returned from Read-ConsoleKey is not null and has a valid Key property before invoking switch ($key.Key) in any loop.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation.

Date: 2026-05-31
Problem: Gemini 3.1 Flash Lite Agent failed with `400 Bad Request` after the first function call.
Root cause: The Agent saved only the `functionCall` object into the next request history and dropped Gemini's required `thoughtSignature` metadata from the model part. API errors were also emitted as normal `Result` objects, so the TUI showed `(Done)` for failures.
Guardrail/rule: For Gemini tool/function calling, append the full `candidate.content` returned by the model to conversation history, preserving `thoughtSignature`. API failures must be emitted as `Type = Error` and rendered as failed, not as successful result text.
Files affected: `Get-DriverUpdateAgent.ps1`, `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Gemini `models.list` availability check; live Agent smoke with `gemini-3.1-flash-lite`; PowerShell parser validation for `Get-DriverUpdateAgent.ps1` and `DeviceCheck.ps1`.

Date: 2026-05-31
Problem: During `A` agent mode, the right details pane only showed `(Running...)`, making the agent feel like a black box.
Root cause: The Agent emitted sparse logs, and the details renderer only showed agent logs inside the cached-evidence branch for selected device rows.
Guardrail/rule: Agent mode should surface observable activity, not hidden model thoughts: Gemini step number, requested tool, sanitized query/url/hardware-id arguments, and short tool-result previews. Render this trace both for the selected device and the selected `[Agent: ...]` result row.
Files affected: `Get-DriverUpdateAgent.ps1`, `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Live Agent smoke confirming `Log` events; PowerShell parser validation for `Get-DriverUpdateAgent.ps1` and `DeviceCheck.ps1`; `git diff --check`.

Date: 2026-05-31
Problem: Agent activity still did not appear live in the right pane; it stayed on `Waiting for first Gemini/tool event` until the Agent finished.
Root cause: `PowerShell.BeginInvoke($collection)` treated the supplied collection as input, so output was only available from `EndInvoke`. Also, removing items from a live `PSDataCollection` is a fragile streaming pattern.
Guardrail/rule: For live runspace output, use an explicit completed input collection plus output collection: `BeginInvoke($inputCollection, $outputCollection)`. Read live `PSDataCollection` output by index with a stored cursor instead of enumerating or `RemoveAt()` while the writer is active.
Files affected: `DeviceCheck.ps1`, `Get-DriverUpdateAgent.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Isolated runspace streaming smoke; live Agent streaming smoke showing 5 log entries after 2 seconds while still running; PowerShell parser validation; `git diff --check`.

Date: 2026-05-31
Problem: Gemini correctly saw MSI plain fetch failures/403s but then fell back to Microsoft Update Catalog, missing the newer official OEM Realtek audio driver.
Root cause: The Agent only had search/plain-fetch/catalog tools. The successful manual path required a real rendered browser session, JavaScript-loaded MSI support content, and clicking the correct driver category (`On-Board Audio Drivers`).
Guardrail/rule: For OEM pages that block plain HTTP or render driver rows client-side, provide a deterministic browser retrieval tool and instruct Gemini to use it before Catalog fallback. The browser tool should expose observable facts (rendered text, download links, clicked category) and write JSONL traces for audit. Catalog is fallback evidence, not primary OEM truth, when machine/motherboard model is known.
Files affected: `tools/Fetch-RenderedPage.js`, `Get-DriverUpdateAgent.ps1`, `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Rendered Chrome/CDP MSI support smoke found `Realtek HD Universal Driver` version `6.4.0.2443`, release `2026-05-18`, and `https://download.msi.com/dvr_exe/mb/realtek_audio_USB_R.zip`; live Gemini agent smoke used `FetchRenderedUrlText` twice and returned the official OEM MSI driver; PowerShell parser validation; `git diff --check`.

Date: 2026-05-31
Problem: AOC monitor Agent runs could spend all 10 steps on DuckDuckGo variations, then show a maximum-iteration error even when Gemini produced a final answer at the last step.
Root cause: `SearchWeb` returned snippets without reliable URLs and could be blocked by DuckDuckGo anti-bot challenges. The rendered browser helper could click tabs but could not type into OEM search inputs. The max-iteration check did not verify whether the loop had already completed.
Guardrail/rule: Search/tool traces should distinguish search-engine blockage from no results. For AOC monitor searches, route anti-bot failures toward rendered AOC Drivers & Software search with `inputText=<model>`. Rendered browser tooling must support both clicking and typing. Only emit max-iteration errors if the Agent loop is still active after the loop exits.
Files affected: `tools/Fetch-RenderedPage.js`, `Get-DriverUpdateAgent.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: AOC rendered search smoke for `27G4HRE` reached `https://aoc.com/us/gaming/drivers-downloads?query=27G4HRE` and returned official “Nothing found”; PowerShell parser validation; `node --check`; `git diff --check`.

Date: 2026-05-31
Problem: Agent final answers and web snippets expanded into many selectable rows in the left device tree, making the tree hard to scan and wasting the right details pane.
Root cause: `SearchResults` was used as both tree row storage and full result text storage, so multi-line Agent reports became child rows.
Guardrail/rule: Keep the left tree as navigation only. Agent mode should render one selectable result row and store the full answer, trace path, and download links on the device object for the right details pane.
Files affected: `DeviceCheck.ps1`, `Get-DriverUpdateAgent.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `node --check`; `git diff --check`.

Date: 2026-05-31
Problem: Agentic driver lookup can consume many Gemini requests and lose progress if rate limits, request budget, or transient tool failures stop a run.
Root cause: Agent state lived only in memory inside the current runspace, and tool results were refetched on every retry.
Guardrail/rule: Agent mode must checkpoint after each Gemini/tool step, pause cleanly on `429`/quota or step-budget exhaustion, and store reusable tool results under the machine cache. Pressing `A` again for the same device should resume only paused checkpoints; completed/error checkpoints are audit history, not automatic truth.
Files affected: `Get-DriverUpdateAgent.ps1`, `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; fake-key checkpoint smoke; `node --check`; `git diff --check`.

Date: 2026-05-31
Problem: Generic web search can miss valid regional OEM pages, such as AOC `27G4HRE` existing on the Greece product page but not the US page.
Root cause: The first rendered AOC workflow tried a US drivers search page and treated its miss as too strong a signal.
Guardrail/rule: Add deterministic vendor prefetch adapters ahead of Gemini when a safe pattern is known. For AOC monitor models, try regional product pages with rendered extraction and feed the official driver/manual download evidence to Gemini before it spends planning calls.
Files affected: `Get-DriverUpdateAgent.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: AOC Greece rendered smoke from previous turn; PowerShell parser validation; fake-key checkpoint smoke.

Date: 2026-05-31
Problem: On an LG UltraGear monitor, Gemini ignored the intended OEM-first workflow and spent steps on DuckDuckGo snippets, including cached/noisy search results and Microsoft Catalog fallback.
Root cause: `SearchWeb` was available too early, and the agent prompt only advised vendor-first behavior instead of enforcing it. The agent also received only a small device summary, not the full local PnP evidence that could help identify installed INF/provider/version details.
Guardrail/rule: Treat generic search as a guarded last resort. Build official vendor-first candidates from local device evidence before Gemini planning; block `SearchWeb` until at least one official `FetchRenderedUrlText`/`FetchUrlText` attempt has occurred when candidates exist; limit repeated search calls. Pass compact local device evidence JSON into the agent prompt.
Files affected: `Get-DriverUpdateAgent.ps1`, `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; LG fake-key checkpoint smoke confirmed LG official candidates and local evidence JSON are present before Gemini; `node --check`; `git diff --check`.

Date: 2026-05-31
Problem: Short generic searches such as `LG monitor driver download` or DuckDuckGo snippets did not identify the exact monitor model, while a raw Google query containing the Device Manager-style fields did surface useful AI Overview and official-result context.
Root cause: The agent was being asked to infer too much from normalized summary text and low-quality snippets. Google's model-identity hints were strongest when the full local evidence block was provided, including `InstanceId`, `HardwareId`, `CompatibleId`, `Service`, and installed `INF`.
Guardrail/rule: For agentic driver discovery, build Google/API queries from raw local evidence fields, not short SEO-style phrases. Prefer the official Google Custom Search JSON API when configured; it returns result URLs/snippets but not AI Overview. Treat AI Overview as an optional interactive/browser hint only, then verify driver version/date/download links on official vendor pages. Do not automatically open browser Google when safe official vendor-first candidates already exist; try those first, and use Google only when no vendor candidate can be built or when official pages are insufficient. When vendor sites are regional, try Greece/Europe official pages before US/global pages; a US 404 or empty search is not enough to conclude no driver exists. If browser Google returns anti-bot/reCAPTCHA, log the block explicitly, stop retrying Google for that run, and continue with official vendor candidates instead of looping.
Files affected: `Get-DriverUpdateAgent.ps1`, `tools/Search-GoogleRendered.js`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Direct rendered Google smoke reproduced useful AI Overview/official-result evidence once, then later Google returned anti-bot/reCAPTCHA; fake-key agent smoke confirmed automatic browser Google is skipped when official vendor-first candidates exist; PowerShell parser validation; `node --check`; `git diff --check`.

Date: 2026-05-31
Problem: AI Overview can be high-value identity evidence for devices, but it is not exposed by Google's official Custom Search JSON API and browser automation against Google Search can trigger reCAPTCHA.
Root cause: AI Overview is a Google Search UI feature, while the official JSON API returns normal result fields such as title/link/snippet. Automated Google SERP sessions are unreliable and can be classified as machine-generated traffic.
Guardrail/rule: Treat AI Overview as user-assisted evidence, not as a default automated dependency. The app should generate/copy/open the raw evidence query, let the user view AI Overview in their normal browser when available, then import pasted/copied AI Overview text into the selected device cache with query, timestamp, and source label. Gemini may use that evidence for identity hints, but final driver links must still be verified on official vendor pages.
Files affected: `README.md`, `PROJECT_RULES.md`.
Validation/tests run: Pending for future manual evidence import UI.

Date: 2026-05-31
Problem: Gemini still called the browser Google Search tool after `SearchGoogleCustom` reported that the official API was not configured, causing another Google reCAPTCHA/unusual-traffic page. However, previous successful experiments suggest rendered Google Search can work in some cases and may be valuable for AI Overview/model identity.
Root cause: The current Google rendered helper may be using a fragile browser/search pattern: fresh temporary profile, direct `/search?q=` navigation, long raw query, or other automation signals. Disabling the tool hides the problem instead of learning the right workflow.
Guardrail/rule: Keep `SearchGoogleRendered` available during active investigation, but log CAPTCHA blocks clearly and do not retry after a block in the same run. Maintain `docs/gemini-google-search-investigation.md` as the briefing prompt for Gemini/system-design review of better Google Search / AI Overview retrieval patterns. Do not treat AI Overview as final truth; verify driver links on official vendor pages.
Files affected: `Get-DriverUpdateAgent.ps1`, `docs/gemini-google-search-investigation.md`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Gemini API review request saved to `docs/gemini-google-search-investigation-response.md`; PowerShell parser validation; `node --check`; `git diff --check`.

Date: 2026-05-31
Problem: Gemini ignored prompt instructions and used short search queries like "lg monitor GSM5BD3 model drivers" when calling SearchGoogleRendered, resulting in poor AI Overview resolution.
Root cause: LLMs tend to generalize and summarize input queries for search tools, ignoring system instructions to pass exact blocks.
Guardrail/rule: Enforce query requirements programmatically inside the tool handler (SearchGoogleRendered) by detecting and overriding non-structured or short queries with the full script-scoped `$script:devicePropertiesBlock`.
Files affected: `Get-DriverUpdateAgent.ps1`, `PROJECT_RULES.md`, `CHANGELOG.md`.
Validation/tests run: PowerShell parser validation.

Date: 2026-05-31
Problem: Long log, checkpoint, and cache path strings were truncated in the details panel (ending with "..."), making it impossible for the user to see the filenames or copy/access the files. Also, automated Google searches typed queries but failed to submit on dynamic page variants.
Root cause: 1) `Format-UiValue` enforced truncation based on window width. 2) Modern Google Search home pages intercept `form.submit()`, causing the browser to stay on the home page.
Guardrail/rule: 1) For important file paths (Log, Checkpoint, Cache), use a custom `Add-WrappedPathLine` function to wrap the path on the right side of the pane and format each wrapped segment as a clickable terminal hyperlink using the `file:///` scheme. 2) Emulate keyboard `Enter` events and click the Google Search button as fallbacks to ensure form submission in `tools/Search-GoogleRendered.js`.
Files affected: `DeviceCheck.ps1`, `tools/Search-GoogleRendered.js`, `PROJECT_RULES.md`, `CHANGELOG.md`.
Validation/tests run: PowerShell parser validation.

Date: 2026-05-31
Problem: The current rendered Google Search workflow is not ideal/safe long-term, but it is the only usable path currently producing useful model-identity evidence for the driver-finder agent.
Root cause: Official Google Custom Search does not expose AI Overview, while browser-based Google Search can work only with a more realistic session/search flow and may still be fragile. Replacing it before a tested alternative exists would break the user's working workflow.
Guardrail/rule: Do not remove, disable, or "clean up" the current working `SearchGoogleRendered` behavior until a safer replacement is implemented and proven with the same LG/AOC/MSI test cases. Future work should investigate a safer mode using Playwright or a full agentic browser harness, persistent normal browser sessions, human-assisted fallback, and official vendor verification. For now, preserve the working Google rendered path and focus on improving local device evidence quality.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Reminder/guardrail only; no code changes.

Date: 2026-05-31
Problem: `SearchGoogleCustom` looked like a Gemini search-grounding leftover and cost an extra Gemini step when `GOOGLE_CUSTOM_SEARCH_API_KEY`/`GOOGLE_CUSTOM_SEARCH_CX` were not configured.
Root cause: Google Custom Search JSON API is a separate Programmable Search Engine product, not Gemini built-in search grounding. The tool was always advertised to Gemini, so the model could call it even though the user only had `GOOGLE_API_KEY` for Gemini.
Guardrail/rule: Hide `SearchGoogleCustom` from Gemini unless both the Custom Search API key and Programmable Search Engine `cx` are configured. Keep it as a future official low-noise discovery layer: it can return normal Google result titles/links/snippets with about 100 free queries/day, but it does not expose AI Overview and must still be followed by official vendor page verification.
Files affected: `Get-DriverUpdateAgent.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; static tool-declaration check with missing Custom Search env vars.

Date: 2026-05-31
Problem: After hiding `SearchGoogleCustom`, LG agent runs appeared to skip browser Google entirely and hit `POLICY BLOCKED` after cached `SearchGoogleRendered` results.
Root cause: `SearchGoogleRendered` incremented the per-run Google budget before checking the tool cache, and an empty cached Google-home result (`organicResults: []`, empty `aiOverviewHint`) was treated as valid evidence.
Guardrail/rule: Rendered Google cache hits must not consume the per-run browser-search budget. Empty Google-home/cache results should be deleted and retried once through the browser, and empty browser results should not be cached.
Files affected: `Get-DriverUpdateAgent.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; static cache/budget order review.

Date: 2026-06-06
Problem: Deep-research outputs correctly identified that the MSI X870 Tomahawk `USB\VID_0DB0&PID_CD0E&MI_00` Realtek USB Audio case needs multi-source enrichment, but the repo needed a concrete regression contract before adding ALSA/OEM importers.
Root cause: `usb.ids` can be vendor-only for new OEM USB devices, while Windows INF strings may be generic driver display names and ALSA/OEM evidence may carry the silicon/profile identity. Without tests, a future enrichment layer could accidentally attribute `Realtek ALC4080` to `usb.ids` or to the INF display name.
Guardrail/rule: Keep `USB\VID_0DB0&PID_CD0E&MI_00` as a permanent regression fixture, not a hardcoded live mapping. `usb.ids` product absence must remain `VENDOR-ONLY`; INF evidence is `Driver Identity`; ALSA/OEM-style evidence is a separate enrichment layer with its own provenance.
Files affected: `docs\DeviceCheck_ Local Hardware Identity Design.md`, `docs\Designing a Reliable Local Digital Evidence Architecture.md`, `docs\LOCAL_HARDWARE_IDENTITY_DATABASE_PLAN.md`, `schemas\hardware-source-manifest.schema.json`, `schemas\device-evidence-bundle.schema.json`, `schemas\hardware-regression-tests.schema.json`, `tests\fixtures\hardware-identity\TC_MSI_X870_REALTEK_AUDIO_001\*`, `internal\Test-HardwareIdentityHarness.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `internal\Test-HardwareIdentityHarness.ps1`; JSON parse validation for schemas and fixtures; `internal\Test-HardwareIdentityHarness.ps1 -AsJson`.

Date: 2026-06-06
Problem: The project goal is driven by power-user hardware auditing needs, not by a coder wanting implementation details for their own sake.
Root cause: The user can supply real-world devices and test observations from home/work PCs, but does not want to be responsible for choosing technical architecture, parsers, schemas, or confidence models.
Guardrail/rule: Codex should lead the technical path and explain each step in plain power-user language: what changed, what the user should test, what result matters, and what the evidence means. Treat the GPU and Realtek USB Audio examples as intentionally difficult calibration samples, not as the full dataset. Build toward repeatable collection at work where more PCs can become samples.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Documentation memory update only.

Date: 2026-06-06
Problem: The Realtek USB Audio details pane explained `VID`/`PID`/`MI`, but lost `REV_0005` when `REV` appeared before `MI`, and did not explain compatible USB class IDs such as `USB\Class_01&SubClass_00&Prot_20`.
Root cause: USB VID/PID parsing expected a specific optional-token order, and class-based compatible IDs were treated as unsupported instead of generic USB function evidence.
Guardrail/rule: USB token parsing must be order-independent for `VID`, `PID`, `REV`, and `MI`. USB class compatible IDs may be mapped to standard class meanings such as `Class_01 = Audio`, but this remains generic function evidence and must never become an exact product/chip model.
Files affected: `DeviceCheck.ps1`, `internal\HardwareIdResolver.psm1`, `internal\Test-HardwareIdResolver.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `internal\HardwareIdResolver.psm1`, `internal\Test-HardwareIdResolver.ps1`, and `internal\Test-HardwareIdentityHarness.ps1`; `internal\Test-HardwareIdResolver.ps1 -AsJson`; `internal\Test-HardwareIdentityHarness.ps1 -AsJson`; JSON parse validation for schemas, fixtures, and config; `git diff --check`.

Date: 2026-06-06
Problem: DeviceCheck needed a non-AI path from MSI USB audio ID `0db0:cd0e` to `Realtek/ALC4080` without falsely claiming that `usb.ids` knew the product.
Root cause: ALSA UCM contains USB audio profile rules that map `0db0:cd0e` into the `Realtek/ALC4080` profile, but this evidence belongs to an open-source audio profile layer, not the local USB product database layer.
Guardrail/rule: Keep ALSA UCM profile matches as `OPEN-SOURCE-PROFILE` evidence. `Audio Profile: Realtek/ALC4080` may be shown when the ALSA UCM resolver matches, but `Local Match` must remain `USB / VENDOR-ONLY / usb.ids` if `usb.ids` lacks the product. Preserve ALSA source commit, version, path, and license.
Files affected: `.gitignore`, `source\alsa-ucm-conf\*`, `config\hardware-sources.json`, `internal\Update-AlsaUcmProfiles.ps1`, `internal\AlsaUcmResolver.psm1`, `internal\Test-AlsaUcmResolver.ps1`, `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `docs\LOCAL_HARDWARE_IDENTITY_DATABASE_PLAN.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for touched scripts/modules; `internal\Test-AlsaUcmResolver.ps1 -AsJson`; `internal\Test-HardwareIdResolver.ps1 -AsJson`; `internal\Test-HardwareIdentityHarness.ps1 -AsJson`; JSON parse validation for schemas, fixtures, config, and source manifests; `git diff --check`.

Date: 2026-06-06
Problem: Disk drives showed poor `PNP / VENDOR-ONLY / pnp.ids` local identity rows while PCI devices showed rich breakdowns.
Root cause: NVIDIA GPU IDs are PCI IDs backed by `pci.ids`, while Windows disk devices often expose SCSI-style storage IDs such as `SCSI\DISK&VEN_NVME&PROD_*` even for NVMe drives. DeviceCheck did not yet have a SCSI/storage parser, so disk IDs fell through to generic fallback behavior.
Guardrail/rule: Treat `SCSI\...` disk IDs as Windows storage-stack identity, not PNP/PCI/USB database identity. Parse `DeviceType`, `VEN_*`, `PROD_*`, and `REV_*` where present; explain that NVMe/SATA disks can be surfaced through the SCSI enumerator. Do not infer a driver update or exact retail model beyond the storage ID string without additional evidence.
Files affected: `internal\HardwareIdResolver.psm1`, `internal\Test-HardwareIdResolver.ps1`, `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for touched scripts/modules; `internal\Test-HardwareIdResolver.ps1 -AsJson`; direct resolver smoke for `SCSI\DISK&VEN_NVME&PROD_KINGSTON_SKC3000`, compact Kingston SCSI disk ID, and `SCSI\Disk`; `internal\Test-AlsaUcmResolver.ps1 -AsJson`; `internal\Test-HardwareIdentityHarness.ps1 -AsJson`; JSON parse validation; `git diff --check`.

Date: 2026-06-06
Problem: Realtek HD Audio on the old ASUS Z170-A PC displayed as `PNP / PARSED-ONLY` with bogus `VEN_HDA` and `DEV_UDIO` breakdown rows.
Root cause: `HDAUDIO\...` IDs did not have a dedicated parser, so they fell through to the compact ACPI/PNP fallback parser, which split the literal bus name `HDAUDIO` as if it were an 8-character compact vendor/device code.
Guardrail/rule: Parse `HDAUDIO\FUNC_*&VEN_*&DEV_*&SUBSYS_*&REV_*` before ACPI/PNP fallback. Treat HDAUDIO as HD Audio codec identity: `VEN/DEV` identify the codec vendor/device code, `SUBSYS` is subsystem vendor(first 4) + board/implementation id(last 4), and exact codec marketing names require separate board/OEM/open-source evidence. Do not claim `pci.ids` knows Realtek codec models when it only resolved the vendor.
Files affected: `internal\HardwareIdResolver.psm1`, `internal\Test-HardwareIdResolver.ps1`, `DeviceCheck.ps1`, `config\board-model-evidence.json`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for touched scripts/modules; JSON parse validation for `config\board-model-evidence.json`; `internal\Test-HardwareIdResolver.ps1 -AsJson`; direct resolver smoke for `HDAUDIO\FUNC_01&VEN_10EC&DEV_0892&SUBSYS_10438698&REV_1003`; `internal\Test-AlsaUcmResolver.ps1 -AsJson`; `internal\Test-HardwareIdentityHarness.ps1 -AsJson`; `git diff --check`.

Date: 2026-06-06
Problem: Monitors and some disks still looked weak compared with PCI/USB network devices.
Root cause: Monitor IDs such as `DISPLAY\GSM5BD3` are EDID manufacturer/product codes, not generic PNP devices, and Windows can expose disks through multiple storage enumerators (`SCSI`, `USBSTOR`, `IDE`) with vendor/model strings instead of PCI/USB database tuples.
Guardrail/rule: Parse `DISPLAY\xxxYYYY` before ACPI/PNP fallback as monitor EDID identity: `xxx` is the EISA/PNP manufacturer code resolved through `pnp.ids`, and `YYYY` is the vendor-assigned EDID product code. Parse `SCSI`, `USBSTOR`, and `IDE` storage IDs as Windows storage-stack identity, not as driver update evidence. Exact monitor marketing model still needs EDID decode, monitor INF, or OEM evidence; exact disk retail model may need serial/model/firmware or vendor evidence.
Files affected: `internal\HardwareIdResolver.psm1`, `internal\Test-HardwareIdResolver.ps1`, `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for touched scripts/modules; `internal\Test-HardwareIdResolver.ps1 -AsJson`; `git diff --check`.

Date: 2026-06-06
Problem: DISPLAY IDs alone explain monitor vendor/product code but still cannot show the richer local facts users expect, such as monitor name descriptor, manufacture date, size, timing, and checksum.
Root cause: `DISPLAY\GSM5BD3` is a compact PnP/EDID identity string, while the richer monitor facts live in raw EDID bytes under the local Windows registry. Those bytes can include privacy-sensitive serial descriptors and can still be insufficient for exact retail model naming.
Guardrail/rule: Treat raw EDID as a separate local evidence layer from `pnp.ids`. Show EDID rows only with clear source/provenance, validate header/checksum, and never promote EDID product code alone into an exact retail model. Treat monitor serial text/numeric serial as privacy-sensitive when creating docs, screenshots, or shared fixtures.
Files affected: `internal\MonitorEdidResolver.psm1`, `internal\Test-MonitorEdidResolver.ps1`, `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `docs\DEEP_RESEARCH_PROMPT_MONITOR_EDID_IDENTITY.md`, `docs\ANTIGRAVITY_GEMINI_JOB_MONITOR_EDID_LAYER.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for touched scripts/modules; `internal\Test-MonitorEdidResolver.ps1 -AsJson`.

Date: 2026-06-06
Problem: Monitor details needed richer local evidence beyond registry EDID, but installed monitor INF and WMI strings can look like exact retail models even when they are only local driver/display descriptors.
Root cause: Windows exposes monitor identity through several partially overlapping layers: registry EDID, `root\wmi` monitor classes, active installed INF sections, and generic `monitor.inf`. These layers can disagree or be generic/overridden.
Guardrail/rule: Treat WMI and monitor INF as separate local evidence layers. Label INF strings as `INF Name`, not authenticated retail model proof. Keep deterministic EDID tests separate from optional live hardware tests; live WMI/INF checks must require `-IncludeLiveMonitor` so CI/laptop/VM runs do not fail because a monitor class is absent or driver-specific.
Files affected: `DeviceCheck.ps1`, `internal\MonitorEdidResolver.psm1`, `internal\Test-MonitorEdidResolver.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `internal\Test-MonitorEdidResolver.ps1 -AsJson`; `internal\Test-MonitorEdidResolver.ps1 -IncludeLiveMonitor -AsJson`; `git diff --check`.

Date: 2026-06-06
Problem: AOC monitors showed `Unknown display vendor` in the HardwareId breakdown even though Windows manufacturer, EDID, WMI, and INF evidence identified the monitor family.
Root cause: The offline `pnp.ids` cache does not include every monitor EISA code; `AOC` was missing there, so the DISPLAY resolver correctly stayed at `PARSED-DISPLAY` but the UI wording made that look like total non-recognition.
Guardrail/rule: For DISPLAY/MONITOR breakdowns, use local Windows manufacturer evidence as a clearly labeled fallback when `pnp.ids` lacks the EISA code. Keep the local identity section concise for monitors: avoid repeating EDID/WMI/INF sources and duplicate size/timing/name rows.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `internal\Test-MonitorEdidResolver.ps1 -AsJson`; `internal\Test-MonitorEdidResolver.ps1 -IncludeLiveMonitor -AsJson`; `git diff --check`.

Date: 2026-06-06
Problem: Disk drive HardwareId breakdowns showed ugly fixed-width padding such as `NVME____` and compact strings that glued model and firmware together.
Root cause: Windows storage devices can expose legacy SCSI-style identity fields where spaces/padding are represented as underscores. For NVMe disks, `VEN_NVME` is usually the Windows storage stack/protocol label, not the physical drive vendor.
Guardrail/rule: Preserve raw storage IDs as evidence, but clean trailing underscore padding for display. Prefer structured storage `InstanceId` values and the local Windows FriendlyName for visible disk model rows. Label `NVME` as a storage stack when appropriate, not as the drive vendor.
Files affected: `DeviceCheck.ps1`, `internal\HardwareIdResolver.psm1`, `internal\Test-HardwareIdResolver.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; `internal\Test-HardwareIdResolver.ps1 -AsJson`; full local resolver regression suite; `git diff --check`.

Date: 2026-06-06
Problem: TUI scan hotkeys could accidentally trigger broad evidence scans, especially when focus was visually on the right details pane or when Windows Terminal right-click/paste injected shortcut characters.
Root cause: `E` on the root row immediately queued all devices, and shortcut handling was duplicated between uppercase key names and lowercase `KeyChar` fallbacks. The details pane highlight could also make it unclear that commands still targeted the selected row in the left tree.
Guardrail/rule: Dangerous/broad TUI actions need an explicit confirmation step. Root/all-device evidence scan requires `E` twice within a short window and cannot be started from the right details pane. Pasted/input bursts should be ignored for shortcut dispatch. Keep hotkey logic centralized in helpers instead of duplicating scan dispatch in multiple switch branches.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for touched scripts; `internal\Test-HardwareIdResolver.ps1 -AsJson`; `internal\Test-MonitorEdidResolver.ps1 -AsJson`; `internal\Test-AlsaUcmResolver.ps1 -AsJson`; `internal\Test-HardwareIdentityHarness.ps1 -AsJson`; `git diff --check`. Manual Windows Terminal right-click behavior still needs user testing.

Date: 2026-06-06
Problem: A right-pane keyboard clipboard shortcut workaround was implemented for Windows Terminal mouse selection bleed, but the user rejected it because it did not solve the actual problem.
Root cause: The real issue is mouse selection spanning the left/right pseudo-panes in a single terminal grid. Adding `c/C` copy shortcuts created extra UI surface without preventing the bad mouse-selection behavior.
Guardrail/rule: Do not ship workaround shortcuts for pane mouse-selection problems unless they directly address the user-visible failure. For this UI issue, either find a way to prevent/cancel mouse selection safely or leave it as a documented Windows Terminal limitation; do not add copy shortcuts as a substitute.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`; `git diff --check`.

Date: 2026-06-06
Problem: TUI scrolling improved after Gemini's cursor-home redraw/cache optimizations, but it still is not butter-smooth under held arrow-key navigation.
Root cause: The main `Render-Frame` path still emits many `Write-Host` calls per frame and rebuilds a full immediate-mode frame through PowerShell host machinery. Synchronized output hides tearing but does not remove PowerShell/ConPTY/write-call overhead.
Guardrail/rule: Future TUI performance work must be measured and reversible. First add optional frame timing/size counters, then test a single-frame StringBuilder plus one `[Console]::Write()` emission path. Do not jump to VT scroll regions or workaround UI features until output batching and key-repeat queue handling have been measured.
Files affected: `docs\TUI_Render_Performance_Limits.md`, `PROJECT_RULES.md`.
Validation/tests run: Documentation update only; code path unchanged; `git diff --check`.

Date: 2026-06-06
Problem: The TUI still needed a real performance experiment before doing more online research.
Root cause: The main frame previously crossed PowerShell host output many times per render. This made smooth held-arrow scrolling dependent on host/ConPTY throughput rather than just local frame construction.
Guardrail/rule: Keep `Render-Frame` as the first measured optimization target: build the main frame in memory and emit it with one `[Console]::Write()`. Keep optional perf metrics behind `DEVICECHECK_TUI_PERF=1`. Do not reintroduce arrow-key batching until measured render cost is no longer the obvious bottleneck.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `docs\TUI_Render_Performance_Limits.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`; `git diff --check`.

Date: 2026-06-06
Problem: DeviceCheck opened in a single-column layout on a wide terminal, so the Selected Details/right pane disappeared.
Root cause: The local `PS_UI_Blueprint.psm1` `Get-UiWidth` helper had been changed to cap width at 100 columns. `DeviceCheck.ps1` enables dual-pane mode only when `uiWidth >= 136`, so the cap made dual-pane mathematically impossible.
Guardrail/rule: Shared/simple menu width caps must not be used by complex apps that decide layout from real terminal width. `Get-UiWidth` for DeviceCheck must return the real window width minus safety margin, with a minimum floor such as `Max(60, WindowSize.Width - 2)`, not a max cap.
Files affected: `PS_UI_Blueprint.psm1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1` and `PS_UI_Blueprint.psm1`; static check confirmed `Get-UiWidth` uses `Max(60, WindowSize.Width - 2)` and `DeviceCheck.ps1` dual-pane threshold remains `uiWidth >= 136`; `git diff --check`.

Date: 2026-06-06
Problem: DeviceCheck needed to know whether LAN collection from another Windows PC is realistic before designing a remote mode.
Root cause: The TUI was built as a local interactive tool, but the underlying data sources might still be collectible through WinRM/PowerShell Remoting if the target permits it.
Guardrail/rule: Treat remote mode as a collector/viewer split, not as a remote interactive TUI. A Windows PowerShell 5.1 WinRM endpoint on `PALIOS` successfully returned `Get-PnpDevice`, `Get-PnpDeviceProperty`, `pnputil /enum-devices /connected`, and `HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY` registry data. Design future remote support around running collection commands on the target with explicit credentials, then rendering/importing evidence locally.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: User-run LAN smoke from main PC to `PALIOS` with `Invoke-Command -ComputerName PALIOS -Credential PALIOS\joty79`; confirmed admin group membership in the remote token, PnP device list, device property keys/data, `pnputil` connected-device output, and DISPLAY registry keys (`AOCB437`, `Default_Monitor`, `SNY2400`, `SNY2C02`).

Date: 2026-06-06
Problem: Remote LAN support needed an operator workflow decision, not only a backend collector decision.
Root cause: The expected usage is a same-LAN, same-workgroup home/workbench flow where the default target is always the local host, but the user may hotkey into another PC by entering its name/IP and credentials.
Guardrail/rule: Add remote target selection as a TUI workflow while keeping local host as the default. Use a hotkey such as `L`/`C` for `Connect to PC`, prompt for target computer name/IP, then username and password through `Get-Credential`. Auto-add only the exact target name/IP to client `TrustedHosts` after a visible admin/elevation check; never use wildcard `*`, never silently broaden trust, and never store passwords. Cache only non-secret recent targets/session state for the current run. Remote collection remains LAN/workgroup-only and should run collector commands on the target, while the TUI renders the selected target locally.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Design decision recorded from user workflow requirement; no code changed yet.

Date: 2026-06-06
Problem: DeviceCheck's remote feature needs to serve real computer-shop workflow, not just prove that WinRM works.
Root cause: The user works on many customer/workbench PCs and needs two staged capabilities: smooth same-LAN remote inspection first, then repeatable snapshots/database records for each PC so device identity answers can be improved and tested even when the PC is no longer connected.
Guardrail/rule: Prioritize remote connection and live remote collection first. Do not add broad snapshot/database UI before remote collection is reliable. Design the remote collector output so it can later become a durable per-PC snapshot corpus: include stable machine identity, target name/IP, collection timestamp, OS/system/board/BIOS facts, full present PnP tree, selected device properties, driver/INF evidence, monitor EDID/WMI/INF evidence, and provenance/tool version fields. Snapshots must be useful for offline regression tests and answer-quality improvement, not only for viewing history.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Product/workflow goal recorded from user requirement; no code changed yet.

Date: 2026-06-06
Problem: The user needed a repeatable PALIOS remote test command instead of retyping long WinRM smoke scripts.
Root cause: Manual `Invoke-Command` snippets proved the remote path but were too tedious for repeated shop/lab validation.
Guardrail/rule: Keep remote collection in `internal\Export-DeviceCheckEvidence.ps1` and use thin target-specific wrappers such as `Connect-PaliosDeviceCheck.ps1` only for convenience. Full mode collects per-device properties and may take noticeably longer; `-Quick` is the preferred first connectivity smoke. Store snapshots under `%LOCALAPPDATA%\DeviceCheck\snapshots\` with `latest.json` per machine folder. Do not store credentials or wildcard `TrustedHosts` entries.
Files affected: `internal\Export-DeviceCheckEvidence.ps1`, `Connect-PaliosDeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for new scripts; local `localhost -Quick -NoSave -AsJson` smoke returned 195 devices and 3 monitor registry entries in ~1.6s; local full `localhost -NoSave -AsJson` smoke returned 195 devices and 3 monitor registry entries in ~17.7s; `git diff --check`.

Date: 2026-06-06
Problem: The PALIOS shortcut needed real remote validation, not just local exporter smokes.
Root cause: Remote WinRM reliability and snapshot size/performance can only be judged from actual same-LAN target runs.
Guardrail/rule: Treat `PALIOS` as the first confirmed remote collector baseline: full snapshots through its Windows PowerShell 5.1 WinRM endpoint should collect about 127 present devices, 9 monitor registry entries, `pnputil` connected-device output, and run in about 10 seconds. If later PALIOS results deviate strongly, compare against `%LOCALAPPDATA%\DeviceCheck\snapshots\PALIOS-2f789028b9d45d78eaa21e7c\latest.json` before changing collector logic.
Files affected: `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: User ran `.\Connect-PaliosDeviceCheck.ps1` twice successfully; local validation parsed `C:\Users\joty79\AppData\Local\DeviceCheck\snapshots\PALIOS-2f789028b9d45d78eaa21e7c\latest.json` and confirmed `ComputerName=PALIOS`, `UserName=PALIOS\joty79`, `PowerShellVersion=5.1.19041.7181`, `IsAdmin=True`, `DeviceCount=127`, `MonitorRegistryKeys=9`, and `PnpUtil.Output` present.

Date: 2026-06-06
Problem: Remote collection needed to become reachable from the normal TUI flow without making every render or device action depend on live WinRM.
Root cause: The desired shop workflow is to start DeviceCheck locally, press `Ctrl+L`, type a same-LAN PC, authenticate once, and return to the same main screen showing that PC's devices.
Guardrail/rule: Implement remote TUI support as snapshot-backed target switching. `Ctrl+L` may collect a remote snapshot and rebuild the main tree from JSON; the default target remains local host. `R` refreshes the active remote snapshot. `E`, `S`, and `A` must stay guarded/disabled on remote snapshot targets until their remote equivalents are explicitly implemented, so they never accidentally run local evidence/search against the host while the UI is showing a remote PC. Do not add workgroup discovery until manual target entry is proven across home/work networks.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; `git diff --check`; local exporter smoke `localhost -Quick -NoSave -AsJson` returned `NEOS` with 195 devices; `internal\Test-HardwareIdResolver.ps1 -AsJson`; `internal\Test-MonitorEdidResolver.ps1 -AsJson`; `internal\Test-AlsaUcmResolver.ps1 -AsJson`; `internal\Test-HardwareIdentityHarness.ps1 -AsJson`. Manual TUI `Ctrl+L` PALIOS smoke is still required.

Date: 2026-06-06
Problem: The first interactive `Ctrl+L` remote target switch needed confirmation before designing saved-target/login behavior.
Root cause: The TUI can only become the main shop workflow if target switching returns smoothly to the normal main screen with the remote PC's devices shown.
Guardrail/rule: Treat `Ctrl+L -> PALIOS -> credential prompt -> snapshot-backed main tree` as a confirmed working baseline. The next design layer should focus on target/session organization: recent/saved PCs, optional credential reuse through Windows-safe mechanisms, on-demand refresh, and a clear distinction between cached snapshot view and live refresh. Keep the first screen local by default.
Files affected: `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: User manually confirmed the TUI `Ctrl+L` flow worked against `PALIOS`.

Date: 2026-06-06
Problem: The first `Ctrl+L` UI was ugly and every remote switch forced a slow fresh full snapshot even when a good local snapshot already existed.
Root cause: `Ctrl+L` was implemented as collect-first rather than target-switch-first, so reconnecting to `PALIOS` repeated the full all-device property collection path each time.
Guardrail/rule: `Ctrl+L` should default to opening the cached `latest.json` snapshot instantly when it exists. Fresh WinRM collection is an explicit refresh choice from the connect prompt or `R` from the active remote target. Treat the full remote snapshot as the all-device collection path; do not also run separate `E`-style collection on remote login unless selected-device refresh is intentionally implemented later.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; `git diff --check`; local exporter smoke `localhost -Quick -NoSave -AsJson` returned `NEOS` with 195 devices.

Date: 2026-06-06
Problem: The first remote login/refresh screen looked unprofessional, duplicated credential UI, and failures from sleeping/offline targets leaked into the main TUI.
Root cause: Get-Credential writes its own host prompt outside DeviceCheck's layout, and refresh/connect failures were being reported through the main status line after the TUI redrew.
Guardrail/rule: Keep remote connect/refresh as a dedicated modal screen until success, cancel, or acknowledged failure. Prompt for username and password inline with `Read-Host -AsSecureString`, create `PSCredential` manually, and avoid the separate PowerShell credential request UI. When a target is asleep/offline/rejecting credentials, show the failure on the connect/refresh screen and wait for Enter before returning. For now, the refresh screen may show an indeterminate/full-snapshot status line; true per-stage progress requires making the exporter report staged progress or run asynchronously.
Files affected: `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; `git diff --check`; local exporter smoke `localhost -Quick -NoSave -AsJson` returned `NEOS` with 195 devices.

Date: 2026-06-06
Problem: TUI borders wrapped/stretched and remnants remained on very small window widths (under 60 columns) during LAN target switching/login prompts, and error screens blocked window resizing with standard `Read-Host`.
Root cause: `Restore-TuiHost` was called inside connection workflows, re-enabling terminal auto-wrap (`?7h`). This forced fixed-size elements (minimum 60 columns) to wrap onto multiple lines in narrow windows, breaking layout alignments. Additionally, standard `Read-Host` blocks console input loop, ignoring resize events.
Guardrail/rule: Do not call `Restore-TuiHost` or enable auto-wrap during connection or prompt screens. Let the viewport clip instead of wrap by keeping wrap off (`?7l`). Replace any blocking `Read-Host` error dialogs with custom responsive `Read-ConsoleKey` loops that capture and redraw on `ResizeEvent`.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Validated syntax with `Get-Command -Syntax -File DeviceCheck.ps1` successfully.

Date: 2026-06-06
Problem: Leftover background elements (e.g. details pane borders, status lines) from the main menu remained visible during the LAN target connection/login modal, until a manual window resize was triggered.
Root cause: When entering the connection wizard or transitioning between wizard stages, the first frame is rendered with `$script:RequestForceClear = $false`, meaning the shorter modal frame does not clear the wider/taller main menu contents underneath it. Window resizing sets `$script:RequestForceClear = $true` which triggers the screen wipe.
Guardrail/rule: Always set `$script:RequestForceClear = $true` at the start of `Invoke-ConnectLanTarget` and at the start/transitions of `New-DeviceCheckCredentialFromPrompt` to force a complete screen wipe on modal entry and stage transitions.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Checked syntax with `Get-Command -Syntax -File DeviceCheck.ps1` successfully.

Date: 2026-06-06
Problem: If a stale, expired, or mistyped credential is saved to disk/cache for a LAN target, subsequent target switches or refreshes (via `R`) fail immediately with `Access is denied` without offering a way to re-enter credentials.
Root cause: The remote collection logic automatically resolved credentials from disk/memory cache and bypassed prompting when a cached credential was found. The failures did not clean up the invalid cache.
Guardrail/rule: Implement `Remove-DeviceCheckStoredCredential` to delete stale credentials from disk (`%LOCALAPPDATA%\DeviceCheck\credentials\<computername>.xml`) and memory cache. Call this on any WinRM connection failure in `Invoke-RemoteSnapshotCollectionScreen` and clear `$script:TargetCredential` on refresh failures in `Invoke-SystemScan`.
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Validated syntax with `Get-Command -Syntax -File DeviceCheck.ps1` successfully.

Date: 2026-06-07
Problem: The progress bar shown while collecting a remote WinRM snapshot was static (`[##########----------]`), making the connection screen feel frozen and offering no cancellation path.
Root cause: The evidence collection was executed synchronously on the main thread, blocking the console event loop and preventing any TUI updates or key reads until completion.
Guardrail/rule: Run the remote snapshot collection asynchronously using `[PowerShell]::Create()` and `BeginInvoke()`. In the main thread loop, poll for completion, read keys, and animate the progress bar (marquee plus spinner) every 100ms. Handle window `ResizeEvent` dynamically and allow user cancellation at any time by pressing `ESC` (which calls `$ps.Stop()`).
Files affected: `DeviceCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Checked syntax with `Get-Command -Syntax -File DeviceCheck.ps1` successfully.

Date: 2026-06-07
Problem: The requested three-row footer rendered as one shortcut segment per row, producing a tall broken vertical list.
Root cause: The footer rows were built as nested arrays and passed through a typed `object[][]` helper, letting PowerShell flatten/enumerate the row structure differently than intended.
Guardrail/rule: For fixed TUI footer/header rows, prefer explicit row variables and explicit render calls over nested-array helper abstractions. If nested row collections are truly needed, validate the rendered row count with a smoke test before treating the layout as fixed.
Files affected: `DeviceCheck.ps1`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `PS_UI_Blueprint.psm1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; narrow renderer line-budget smoke for terminal heights 16/20/24/25/30/40 with and without batch status; `git diff --check`.

Date: 2026-06-07
Problem: PALIOS showed TUI arrows/triangles/diamonds as `?` or wrong characters even though Windows Terminal, PowerShell 7, and the font looked similar to NEOS.
Root cause: PALIOS had Windows UTF-8 worldwide language support disabled, so Windows used `ACP=1252`, `OEMCP=437`, and PowerShell inherited `[Console]::OutputEncoding=ibm437` / `chcp 437`. NEOS used `ACP/OEMCP/MACCP=65001`, so the same glyphs rendered correctly there.
Guardrail/rule: Do not require global OS locale changes or font installs for DeviceCheck to be usable. Use a reusable glyph map and automatically switch to ASCII UI glyphs when the console output codepage is not UTF-8; keep manual overrides through `DEVICECHECK_ASCII_UI=1`, `POWERSHELL_TUI_ASCII=1`, and `POWERSHELL_TUI_UNICODE=1`. Keep reusable encoding/glyph diagnostics in `.agent-shared`, not in DeviceCheck.
Files affected: `DeviceCheck.ps1`, `PS_UI_Blueprint.psm1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation for `DeviceCheck.ps1`, `PS_UI_Blueprint.psm1`, `internal\Export-DeviceCheckEvidence.ps1`, and `Connect-PaliosDeviceCheck.ps1`; ASCII fallback frame smoke with `DEVICECHECK_ASCII_UI=1` confirmed no non-ASCII glyphs in a sample banner/section/footer frame; narrow renderer line-budget smoke for terminal heights 16/20/24/25/30/40 with and without batch status; `git diff --check`.

Date: 2026-06-15
Problem: The Ctrl+L LAN target selector menu and the Offline Snapshots submenu lagged significantly when scrolling through items with arrow keys, while the main menu was fast.
Root cause: The selector loops in `Invoke-ConnectionHistorySelector` and `Invoke-OfflineSnapshotSelector` rebuilt the display items by calling `Get-DeviceCheckOfflineMenuEntries` and `Get-DeviceCheckConnectionHistory` on *every single keystroke* (arrows, resize, etc.). These functions perform disk I/O, recursively scanning the snapshots directory and reading/parsing multiple `latest.json` files from disk, causing substantial lag.
Guardrail/rule: Cache the connection history, filtered network history, offline menu entries, and scan benchmark log lines outside the interactive selection loops. Introduce a `$needsReload` flag within the selectors, set it to `$true` initially and on state-changing actions (e.g. rescan `R`, item deletion `Delete`, submenu transitions), and only read/parse disk files when this flag is active. Additionally, measure loop timings (Prep, Render, KeyRead, EventProcess) and append them to `$script:BenchmarkLog` to make input latency transparent.
Files affected: `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`, `PROJECT_RULES.md`, `CHANGELOG.md`.
Validation/tests run: PowerShell parser validation via `internal\Test-DeviceCheckStructure.ps1`.

Date: 2026-06-15
Problem: Selecting a monitor device (e.g. Generic PnP Monitor) in the main device tree caused a ~2.8-second TUI rendering freeze/lag when selected for the first time, on both host, remote, and offline snapshot targets.
Root cause: To resolve the friendly retail model name, `Get-MonitorInfEvidence` in `internal\MonitorEdidResolver.psm1` performed a slow, synchronous, line-by-line PowerShell recursive text search across all `oem*.inf` files in `C:\Windows\INF` when the driver was generic (e.g., `monitor.inf`). This resulted in hundreds of file reads and hundreds of thousands of regex matching loops in PowerShell. Additionally, this scan ran even on remote/offline targets, querying the host's local INF directory unnecessarily.
Guardrail/rule: Do not run synchronous recursive file loops or heavy text scans inside the detail panel rendering path. Optimize any system INF folder scans by using the compiled C#-native `Select-String` cmdlet to find matching files in one pass (~70ms), and parse only the single matched file. Furthermore, restrict host system INF directory scans to `Local` target mode only by inspecting `$global:TargetMode`.
Files affected: `internal\MonitorEdidResolver.psm1`, `PROJECT_RULES.md`, `CHANGELOG.md`.
Validation/tests run: PowerShell parser validation via `internal\Test-DeviceCheckStructure.ps1` and unit tests in `internal\Test-MonitorEdidResolver.ps1`.

Date: 2026-06-15
Problem: Selecting monitor and network adapter devices in the main TUI tree caused up to ~837ms lag when selected for the first time, on both host and remote/snapshot targets.
Root cause: 1) `Get-MonitorWmiEvidence` queried the `root\wmi` namespace dynamically (4 separate CIM class queries) for each hardware ID candidate on every frame render. 2) Monitor WMI/INF queries ran locally even for remote snapshot targets. 3) `Get-HardwareIdBreakdownLines` performed database lookups on every single frame render. 4) Caching did not clean up correctly, and strict mode prevented simple direct property lookups without fallback.
Guardrail/rule: Cache hardware ID breakdown lines in `$script:HardwareIdBreakdownCache` to avoid repeat lookups. Query WMI monitor classes in bulk at most once and cache them in module scope (`$script:GlobalWmiMonitorIDs`, etc.). Pre-warm this WMI cache synchronously/asynchronously at startup and rescan to avoid first-time selection render lags. Automatically bypass local WMI and INF monitor queries on remote snapshot targets. Clear all resolver and module caches in `Invalidate-EvidenceCache` when a rescan is triggered.
Files affected: `internal\DeviceCheck\03-EvidenceResolvers.ps1`, `internal\DeviceCheck\04-UiTextFormatting.ps1`, `internal\DeviceCheck\05-InventoryAndSnapshots.ps1`, `internal\MonitorEdidResolver.psm1`, `PROJECT_RULES.md`, `CHANGELOG.md`.
Validation/tests run: PowerShell parser validation via `internal\Test-DeviceCheckStructure.ps1` and unit tests in `internal\Test-MonitorEdidResolver.ps1`, `internal\Test-HardwareIdResolver.ps1`, `internal\Test-AlsaUcmResolver.ps1`, and `internal\Test-HardwareIdentityHarness.ps1`.

Date: 2026-06-19
Problem: During boot with high disk usage, WinRM service starts late even when set to Automatic because SCM defaults to Delayed Start, or Set-Service on Windows client OS preserves the DelayedAutoStart flag.
Root cause: Set-Service -StartupType Automatic does not clear the DelayedAutoStart registry flag.
Guardrail/rule: When configuring WinRM startup type in `Enable-RemotePs.ps1`, explicitly write `DelayedAutoStart = 0` to `HKLM:\SYSTEM\CurrentControlSet\Services\WinRM` to guarantee non-delayed startup.
Files affected: `Enable-RemotePs.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Local registry check confirms DelayedAutoStart is 0, parser validation via structure test.

Date: 2026-06-23
Problem: A saved LAN target (`DESKTOP-5RVAGU8`) had an existing snapshot captured from IPv4 `192.168.1.36`, but the connection history was later overwritten with an IPv6 link-local address (`fe80::...%12`), causing the offline snapshot row to show the wrong address and treat the target as offline/noisy.
Root cause: `Resolve-HistoryTargetAddress` accepted the first DNS/LLMNR result and ARP/MAC neighbor matches without restricting them to IPv4. The LAN scanner itself is IPv4-based, so saving a link-local IPv6 address broke later matching and display. The offline menu also trusted `connection-history.json` over the snapshot's original `Collector.RequestedComputerName`.
Guardrail/rule: DeviceCheck LAN target history must store IPv4 addresses only until the scanner is intentionally upgraded for first-class IPv6. Filter DNS/LLMNR, ARP/MAC, and history fallback results to IPv4 before saving or reconnecting. Offline snapshot display should recover the captured IPv4 target from the snapshot when history contains a non-IPv4 value, and it must do a quick WinRM probe against that recovered IPv4 before labeling a current-network entry offline.
Files affected: `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, and `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`; `internal\Test-DeviceCheckStructure.ps1`; focused offline menu smoke confirmed polluted history value `fe80::6efb:615f:88b3:1aff%12` and repaired history value `192.168.1.36` are both omitted from the offline menu when WinRM is reachable on `192.168.1.36`; active discovery smoke confirmed `DESKTOP-5RVAGU8` is found at `192.168.1.36` with `WinRmOpen = true`; live connectivity smoke confirmed `192.168.1.36` responds to ping and WinRM port `5985`.

Date: 2026-06-23
Problem: `DESKTOP-5RVAGU8` had WinRM enabled and a valid passwordless local `user` administrator, but DeviceCheck still failed with `Access is denied` because it reused an old saved `dcadmin` credential.
Root cause: DPAPI credential files are keyed by target name/IP and can outlive the actual intended workflow account. The reconnect path loaded the cached credential before considering the current history username, and the failed IP-based attempt only removed the IP credential alias, leaving the hostname credential (`desktop-5rvagu8.xml`) in place.
Guardrail/rule: When a connection history entry has a concrete username, cached credentials whose username leaf does not match must be discarded before connecting. Connection prompts should default to the history username (qualified as `<target>\<user>` when needed), not a hardcoded `joty79`. On failure, clear both hostname and resolved-IP credential aliases.
Files affected: `internal\DeviceCheck\06-RemoteConnection.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`; local cache repaired in `%LOCALAPPDATA%\DeviceCheck\connection-history.json` and stale `%LOCALAPPDATA%\DeviceCheck\credentials\desktop-5rvagu8.xml` removed.
Validation/tests run: Parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`, and `internal\Export-DeviceCheckEvidence.ps1`; `internal\Test-DeviceCheckStructure.ps1`; direct WinRM smoke with `[SecureString]::new()` blank password and `DESKTOP-5RVAGU8\user` returned `IsAdmin = true`; `internal\Export-DeviceCheckEvidence.ps1 -ComputerName 192.168.1.36 -Credential DESKTOP-5RVAGU8\user -Quick -NoSave -AsJson` succeeded and returned `ComputerName = DESKTOP-5RVAGU8`, `UserName = DESKTOP-5RVAGU8\user`, `QuickMode = true`, and device data.

Date: 2026-06-23
Problem: Computer Info showed no friendly RAM summary even though the collector had partial `TotalPhysicalMemory`, and Windows reports visible OS memory (e.g. ~14.69 GB) instead of installed module capacity (e.g. 16 GB).
Root cause: Local machine evidence did not collect `Win32_PhysicalMemory`/`Win32_PhysicalMemoryArray`, and remote snapshots only saved `Win32_ComputerSystem.TotalPhysicalMemory`. The details pane had no formatter that preferred installed module capacity over visible OS memory.
Guardrail/rule: Store RAM evidence as a dedicated `Machine.Memory` object with raw module and array fields for future UI, including module capacity, manufacturer, part number, serial number, speed, configured speed, SMBIOS memory type, form factor, data/total width, interleave position, slots used, and total slots. For the Computer Info summary, prefer summed module capacity over `TotalPhysicalMemory` so installed RAM displays as user-facing capacity like `16 GB`, then show slots, type, speed, and part number compactly.
Files affected: `internal\DeviceCheck\02-MachineAndTarget.ps1`, `internal\DeviceCheck\07-TreeDetailsAndModels.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\02-MachineAndTarget.ps1`, `internal\DeviceCheck\07-TreeDetailsAndModels.ps1`, and `internal\Export-DeviceCheckEvidence.ps1`; `internal\Test-DeviceCheckStructure.ps1`; local RAM smoke returned `LAPTOP`, `16 GB (4/4 slots) LPDDR5`, `6400 MHz`, `H58G56AK6BX069 x4`; remote WinRM smoke against `192.168.1.36` with `DESKTOP-5RVAGU8\user` returned `8 GB (1/2 slots) DDR4`, `2400 MHz`, `RMSA3260KC78HAF-2666`.

Date: 2026-06-26
Problem: A newly connected LAN PC at `192.168.1.66` was visible in the local ARP neighbor cache but did not appear in `Ctrl+L` discovery because WinRM was not enabled and SMB was closed.
Root cause: `Get-DeviceCheckDiscoveredHosts` kept only hosts with WinRM `5985` or SMB `445` open, so ARP/ping-visible hosts with closed management ports were filtered out completely even though they were genuinely on the LAN.
Guardrail/rule: LAN discovery should distinguish visibility from manageability. Keep WinRM-open hosts as `(Online)`, SMB-only hosts as `(WinRM Disabled)`, and ARP/ping-visible hosts with closed management ports as `(Detected - mgmt closed)` so the operator can see the PC before enabling WinRM. Snapshot collection still requires WinRM.
Files affected: `internal\DeviceCheck\06-RemoteConnection.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1` and `internal\DeviceCheck\06-RemoteConnection.ps1`; `internal\Test-DeviceCheckStructure.ps1`; live discovery smoke confirmed `192.168.1.66` appears with `MAC = D0-C6-37-91-0F-1E`, `WinRmOpen = false`, `SmbOpen = false`, and `DetectedOnly = true`.

Date: 2026-06-26
Problem: Showing ARP/ping-visible hosts made the `Ctrl+L` LAN selector include multicast/reserved neighbor entries such as `224.*`, `239.*`, `mdns`, and `igmp`, and IP-only reverse DNS results rendered as a misleading short host label like `192`.
Root cause: Windows neighbor cache includes multicast protocol entries, and the scanner's detected-only fallback accepted any IPv4 neighbor. The reverse DNS formatter also stripped anything after the first dot even when the returned hostname was just an IPv4 address.
Guardrail/rule: LAN discovery filters must accept only real unicast IPv4 hosts on the active local subnet(s), excluding multicast, loopback, APIPA, broadcast/network addresses, gateways, and local self IPs. If reverse DNS returns an IP address or `.in-addr.arpa`, display the full fallback IP, not the first octet. Keep discovery filters and host-cache helpers in `06-RemoteDiscoveryFilters.ps1` instead of growing `06-RemoteConnection.ps1` past the structure budget.
Files affected: `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, and `internal\DeviceCheck\06-RemoteConnection.ps1`; `internal\Test-DeviceCheckStructure.ps1`; live discovery smoke confirmed no `224.*`/`239.*`/`mdns`/`igmp` rows and confirmed `192.168.1.66` remains visible with `HostName = 192.168.1.66`; later direct connectivity check showed `Ping = true`, `WinRM5985 = true`, and `SMB445 = true` after the target ports were open.

Date: 2026-06-26
Problem: The target PC could appear in ARP but still time out on ping even after the usual SMB/network-sharing helper, because ICMP Echo Request was not part of `Diagnose-SmbSharing.ps1`.
Root cause: The helper repaired SMB, Network Discovery, LAN services, SMBv2/v3, and blank-password policy, but did not audit or enable the Windows Defender Firewall ICMPv4 Echo Request rules (`FPS-ICMP4-ERQ-In*` / `CoreNet-Diag-ICMP4-EchoRequest-In*`).
Guardrail/rule: Treat ping visibility as a diagnostic convenience, not as the required DeviceCheck management path. `Diagnose-SmbSharing.ps1` should include ICMPv4 Echo Request firewall repair so ping timeouts can be fixed with the same SMB/network visibility helper, while `Enable-RemotePs.ps1` remains the required WinRM setup path for remote snapshots.
Files affected: `Diagnose-SmbSharing.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `Diagnose-SmbSharing.ps1`; read-only firewall rule lookup confirmed matching local rule names exist (`FPS-ICMP4-ERQ-In*` and `CoreNet-Diag-ICMP4-EchoRequest-In*`). Elevated `-Fix` execution was not run here against the target PC.

Date: 2026-06-26
Problem: `Ctrl+L` LAN discovery did not match Windows Explorer Network Discovery. Explorer showed `DESKTOP-RUHR98M` at `192.168.1.64`, but DeviceCheck either missed it, showed only delayed IP-only entries, or depended on stale cache behavior.
Root cause: The scanner relied on local neighbor cache, history IPs, ping, TCP port checks, and reverse DNS/NetBIOS resolution. Windows Explorer also uses WS-Discovery-style computer publication signals, where the UDP probe response provides a metadata endpoint and the metadata response contains `pub:Computer` with the friendly computer name.
Guardrail/rule: `Ctrl+L` discovery must include an active WS-Discovery probe and WS-Transfer metadata lookup for `pub:Computer`, then merge those names with neighbor/history/TCP status. Passive ARP/reverse DNS alone is not enough for Explorer Network parity. If cache/history contains only `IP -> IP`, treat it as unresolved and retry name discovery instead of freezing the row as IP-only.
Files affected: `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `DeviceCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, and `Diagnose-SmbSharing.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; live discovery harness confirmed `192.168.1.64 DESKTOP-RUHR98M`, `192.168.1.66 DESKTOP-NFSVMUE`, `192.168.1.5 SE`, and `192.168.1.15 DATACOMPUTER-ER` in the same `Get-DeviceCheckDiscoveredHosts` path used by `Ctrl+L`.

Date: 2026-06-26
Problem: Follow-up explanations repeatedly risked adding generic warnings about passwordless local users even though the user's shop/workbench PCs intentionally use passwordless local accounts.
Root cause: Generic Windows remoting/security defaults conflict with this project's established operator baseline, where passwordless local accounts are deliberate and the scripts support `LimitBlankPasswordUse = 0`.
Guardrail/rule: In DeviceCheck work, do not add generic security warnings or discourage passwordless local users. Treat passwordless local accounts as a supported baseline and focus on whether `Enable-RemotePs.ps1`, `Diagnose-SmbSharing.ps1`, and `Ctrl+L` discovery/connection behavior support the workflow correctly.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Project memory update only; no runtime test needed.

Date: 2026-06-26
Problem: A final live port-check diagnostic hit the PowerShell parser error `An empty pipe element is not allowed` when piping directly after an inline `foreach { ... }` expression.
Root cause: The diagnostic command repeated a known fragile pattern: a complex inline `foreach` body followed immediately by a pipeline. This is easy to parse incorrectly in compressed PowerShell one-liners.
Guardrail/rule: For diagnostic rows, always assign `foreach` output to a named `$rows` variable first, then pipe `$rows` separately. This applies especially to final verification commands where a parser failure creates noise and can obscure the real test result.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Retried the probe with `$rows = foreach (...) { ... }; $rows | Format-Table -AutoSize`, confirming parser success and reporting port state for `192.168.1.64`, `192.168.1.65`, and `192.168.1.66`.

Date: 2026-06-26
Problem: After making ARP/ping-visible hosts visible, `Ctrl+L` listed phones, cameras, IoT devices, stale DHCP/ARP entries, and randomized-MAC mobile clients under `Discovered PCs on Network`.
Root cause: The detected-only fallback treated generic LAN visibility as enough to show a row, but ARP/ping visibility does not prove a Windows/workgroup computer. In live diagnostics, several yellow IPs had closed WinRM/SMB/WSD/NetBIOS and repeated the same randomized/local MAC, while the confirmed extra PC `DESKTOP-UQR1LBT` responded to WS-Discovery `pub:Computer`.
Guardrail/rule: `Discovered PCs on Network` must show computers only. Keep WinRM-open hosts as `(Online)`, SMB-only hosts as `(WinRM Disabled)`, and WS-Discovery-confirmed computers with closed management ports as `(Computer - mgmt closed)`. Do not show ARP/ping-only devices in the PC list; those belong in a future optional diagnostics view, not the target selector.
Files affected: `internal\DeviceCheck\06-RemoteConnection.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: WS-Discovery focused smoke confirmed `192.168.1.15 DATACOMPUTER-ER`, `192.168.1.5 SE`, and `192.168.1.62 DESKTOP-UQR1LBT`; live neighbor/port diagnostics confirmed `192.168.1.65`, `192.168.1.54`, and `192.168.1.51` were ARP/ping-only with repeated randomized/local MAC `66-83-E7-A7-DB-67`, and should not be shown as PCs.

Date: 2026-07-06
Problem: A PC at `192.168.1.91` already had the local setup helpers run and had WinRM/sharing available, but it did not appear in `Ctrl+L` discovery after multiple refreshes. It appeared only after the user connected to it with Remote Desktop.
Root cause: The selector could discover computers from history, local neighbor cache, WS-Discovery, and targeted TCP checks, but a ready PC that had not yet populated the local neighbor cache and did not answer the initial WS-Discovery probe was never added to the TCP target set. Manual RDP traffic woke/seeded the network state, making it appear afterward.
Guardrail/rule: `Ctrl+L` computer discovery needs a narrow active subnet sweep for PC-specific ports, not a generic ARP/ping-only device list. Use a short-budget TCP sweep for `3389` and `5985` to seed ready RDP/WinRM PCs into the target set while still excluding phones/cameras/TVs that only answer ARP or ping. Avoid ping-gated full-subnet sweeps in the foreground; they caught the PC but made normal refresh 3-4x slower.
Files affected: `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Direct port probe confirmed `192.168.1.91` responds on `3389`, `5985`, `445`, `5357`, and `139`; standalone short-budget TCP sweep confirmed `192.168.1.91` with `RdpOpen = true` and `WinRmOpen = true` in under 0.5s during tuning; full `Get-DeviceCheckDiscoveredHosts` live smoke confirmed `192.168.1.91 DESKTOP-79L36PK` appears as `WinRmOpen = true` without relying on manual target selection.

Date: 2026-06-30
Problem: SDIO stopped showing the RZ616 Wi-Fi update candidate after stale `_P_*.bin` indexes were removed, even though current driver packs still contained matching MediaTek `mtkwl6ex.inf` payloads.
Root cause: The visible SDIO Wi-Fi candidate depended on the old `_P_SDIO01_26044.bin` index and the matching `DP_SDIO01_26044.7z` driver pack. Keeping or redownloading only current `DP_*.bin` indexes was not enough, and the current `DP_SDIO03_26064.bin` / `DP_WLAN-WiFi_26061.bin` indexes returned zero candidates for `PCI\VEN_14C3&DEV_0616&SUBSYS_E0C617AA`.
Guardrail/rule: For RZ616 Wi-Fi 6E 160MHz clean-install reproduction through SDIO, preserve or redownload both the old SDIO index (`_P_SDIO01_26044.bin`) and its matching pack (`DP_SDIO01_26044.7z`). If the UI shows `DP_SDIO01_26044.7z` but the pack is missing, SDIO recognition may appear broken until the pack is restored. Verify installed driver with `Win32_PnPSignedDriver` rather than trusting UI state alone.
Files affected: `PROJECT_RULES.md`; SDIO external state under `D:\Programs\SDIO` only.
Validation/tests run: Verified `RZ616 Wi-Fi 6E 160MHz` is present and running; installed driver is `MediaTek, Inc.ti` version `25.40.2.586`, date `2026-01-30`, INF `oem60.inf`; verified `D:\Programs\SDIO\drivers\DP_SDIO01_26044.7z` exists after redownload.


Date: 2026-07-06
Problem: After adding the active PC-port sweep, normal `Ctrl+L` refresh felt 3-4x slower.
Root cause: The scanner treated tentative APIPA interfaces from Bluetooth/local pseudo adapters as active LAN prefixes, so the PC-port sweep scanned useless `169.254.*` ranges. It also still ran a foreground ARP purge and ICMP ping phase even though the PC-only selector now relies on WS-Discovery and TCP computer-port evidence.
Guardrail/rule: `Ctrl+L` PC discovery should scan only usable Preferred non-APIPA IPv4 interfaces. Do not use ICMP or ARP-only visibility to populate the PC selector; keep ICMP as a diagnostic concern for `Diagnose-SmbSharing.ps1`, not as foreground discovery proof. Avoid per-refresh ARP purges unless a future targeted stale-neighbor repair needs them.
Files affected: `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `internal\Test-DeviceCheckStructure.ps1`, `internal\Test-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryLive.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryLive.ps1`, and `Diagnose-SmbSharing.ps1`; `internal\Test-RemoteDiscoveryFilters.ps1`; `internal\Test-DeviceCheckStructure.ps1`, now also parser-checking top-level `internal\Test-*.ps1` scripts; `git diff --check`; live shop-network `Get-DeviceCheckDiscoveredHosts` timing dropped from about 8.6s to about 5.5s while keeping the online PC list to `DATACOMPUTER-ER`, `SE`, and `DESKTOP-UQR1LBT`; later home-network `internal\Test-RemoteDiscoveryLive.ps1 -ExpectedHostName NEOS -FailOnMissing` returned only `NEOS` in about 3.9s, confirming the PC-only selector path and expected-host gate still run without obvious phone/router/noise rows on a different LAN. `192.168.1.91` was not treated as an expected live result because the target was closing/low battery during this verification.

Date: 2026-07-07
Problem: The active PC-port sweep caught WinRM/RDP-ready PCs, but a Windows Explorer-visible PC that only exposes SMB/Network Discovery could still be missed if it did not answer WS-Discovery and had not yet entered local neighbor/history state.
Root cause: The PC-port sweep default ports omitted SMB `445`, and `Ctrl+L` did not directly seed from Explorer's own Network computer namespace even though the user's minimum goal is Explorer Network parity for PCs.
Guardrail/rule: `Ctrl+L` PC discovery should seed from Explorer's Network computer namespace when it exposes UNC computer paths, then resolve those names to IPv4 and merge them with WS-Discovery and PC-port evidence. Keep the active subnet sweep limited to computer-specific ports (`445`, `3389`, `5985`) rather than generic ping/ARP visibility.
Files affected: `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryLive.ps1`, and `Diagnose-SmbSharing.ps1`; `internal\Test-RemoteDiscoveryFilters.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; bounded Explorer Network helper smoke returned safely instead of hanging; home-network `internal\Test-RemoteDiscoveryLive.ps1` returned only `NEOS (192.168.1.6)` with `WinRmOpen = true`, `SmbOpen = true` in about 4.9s. Shop Explorer-visible PC parity still requires a later shop-network verification.

Date: 2026-07-07
Problem: Offline WS-Discovery regression tests showed the first prefix-flexible parser refactor missed normal `d:Types>pub:Computer` probe matches, and the metadata parser missed `<pub:Computer ...>` elements that carry namespace attributes.
Root cause: The parser briefly looked only for literal `Computer` element names in probe responses and for `<Computer>` elements without attributes in metadata responses. Windows WS-Discovery uses `pub:Computer` in `Types`, and metadata elements may be namespace-qualified with attributes.
Guardrail/rule: Keep WS-Discovery probe and metadata parsing in small tested helper functions. Probe parsing must accept `pub:Computer` type tokens and arbitrary XML prefixes. Metadata parsing must accept prefixed or unprefixed `Computer` elements with optional attributes and trim any `/Workgroup:...` suffix from the returned name.
Files affected: `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryFilters.ps1`, `PROJECT_RULES.md`.
Validation/tests run: Focused parser validation for `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1` and `internal\Test-RemoteDiscoveryFilters.ps1`; `internal\Test-RemoteDiscoveryFilters.ps1`.

Date: 2026-07-07
Problem: The shop parity check still depended on manually comparing Explorer's Network window with `Ctrl+L` output, which is easy to miss when a PC appears only after RDP or after several refreshes.
Root cause: `internal\Test-RemoteDiscoveryLive.ps1` could assert specific expected host/IP values, but it did not query Explorer's own Network computer namespace and compare that current list against DeviceCheck's discovered hosts.
Guardrail/rule: The live discovery verifier should support `-CompareExplorer` so shop testing can fail when a Windows Explorer-visible Computer row is missing from DeviceCheck. Match Explorer computers by hostname or by resolved IPv4 address, and combine it with `-FailOnMissing` for a hard parity gate.
Files affected: `internal\Test-RemoteDiscoveryLive.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryLive.ps1`, and `Diagnose-SmbSharing.ps1`; `internal\Test-RemoteDiscoveryFilters.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; home-network `internal\Test-RemoteDiscoveryLive.ps1 -CompareExplorer` returned only `NEOS (192.168.1.6)` and reported that Explorer Network returned no Computer rows on this host; home-network `internal\Test-RemoteDiscoveryLive.ps1 -CompareExplorer -ExpectedHostName NEOS -ExpectedIP 192.168.1.6 -FailOnMissing` passed.

Date: 2026-07-07
Problem: The first `-CompareExplorer` verifier used the same short bounded Explorer Network helper behavior as the interactive `Ctrl+L` path, so a strict shop proof could silently skip the comparison if Explorer enumeration timed out or returned zero rows.
Root cause: Fast interactive discovery and proof-oriented parity verification have different latency budgets. `Ctrl+L` should avoid waiting on Explorer COM, but the verifier should be allowed to wait longer and fail loudly when Explorer rows are expected.
Guardrail/rule: Keep the interactive Explorer seed short-budget, but let `internal\Test-RemoteDiscoveryLive.ps1 -CompareExplorer` use a longer `-ExplorerTimeoutMilliseconds` default. Add `-RequireExplorerRows` for shop proof runs where the user can see Explorer Computer rows and a zero-row Explorer helper result should be treated as failure.
Files affected: `internal\Test-RemoteDiscoveryLive.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryLive.ps1`, and `Diagnose-SmbSharing.ps1`; `internal\Test-RemoteDiscoveryFilters.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; home-network `internal\Test-RemoteDiscoveryLive.ps1 -CompareExplorer -ExpectedHostName NEOS -ExpectedIP 192.168.1.6 -FailOnMissing` passed while reporting zero Explorer Computer rows after 5000 ms; intentional strict-failure smoke with `-CompareExplorer -RequireExplorerRows -ExplorerTimeoutMilliseconds 100 -FailOnMissing` failed as expected with `Missing expected discovered PC(s): Explorer Network Computer rows`.

Date: 2026-07-07
Problem: The original issue was intermittent/delayed discovery: a PC could fail to appear after multiple `Ctrl+L` refreshes, then appear only after RDP or later network activity.
Root cause: A single live verifier run can prove current discovery, but it cannot prove that discovery is stable across repeated refresh attempts or expose which run first starts missing a target.
Guardrail/rule: `internal\Test-RemoteDiscoveryLive.ps1` should support `-RepeatCount` and `-RepeatDelaySeconds`, running all attempts before failing so intermittent shop discovery produces a clear per-run summary. Use this with `-CompareExplorer`, `-RequireExplorerRows`, and `-FailOnMissing` for the final shop parity gate.
Files affected: `internal\Test-RemoteDiscoveryLive.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryLive.ps1`, and `Diagnose-SmbSharing.ps1`; `internal\Test-RemoteDiscoveryFilters.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; home-network repeat smoke `internal\Test-RemoteDiscoveryLive.ps1 -CompareExplorer -ExpectedHostName NEOS -ExpectedIP 192.168.1.6 -RepeatCount 2 -RepeatDelaySeconds 1 -FailOnMissing` passed, with both runs finding only `NEOS (192.168.1.6)` and zero Explorer Computer rows on this host.

Date: 2026-07-07
Problem: The Explorer Network computer seed was safe after moving it to a bounded helper process, but the helper startup cost could consume the entire short interactive `Ctrl+L` budget and make the seed effectively unavailable during normal refresh.
Root cause: Launching a fresh `pwsh` process for every discovery refresh avoids COM hangs, but process startup is too expensive for a fast optional seed. Explorer's Shell COM object also expects STA apartment behavior, so a plain background job/runspace is not enough unless the apartment state is controlled.
Guardrail/rule: Use a bounded STA runspace for Explorer Network namespace enumeration. Keep the timeout safety and always dispose the PowerShell/runspace objects, but avoid spawning child PowerShell processes in the interactive discovery path.
Files affected: `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Focused parser validation for `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`; focused helper timing smoke returned safely with `Timeout=700` in about 27 ms and `Timeout=5000` in about 1 ms on the home network, both with zero Explorer Computer rows.

Date: 2026-07-07
Problem: Work-network discovery could find an SMB-only PC but display it as a bare IP, for example `192.168.1.13`, even though Windows NetBIOS node-status showed the computer name `DESKTOP-T76VFF3`.
Root cause: Reverse DNS can return only PTR placeholders or nothing for workgroup PCs, and WS-Discovery is not guaranteed for every SMB-visible Windows machine. The selector had no final NetBIOS name fallback for already-confirmed PC candidates.
Guardrail/rule: For unresolved hosts that are already PC candidates, use a tightly bounded NetBIOS node-status fallback and parse `<20>` or `<00>` UNIQUE registered names. Keep this fallback limited to unresolved SMB/detected computer candidates, not a full-subnet NetBIOS scan, so `Ctrl+L` remains fast and PC-only.
Files affected: `internal\DeviceCheck\06-RemoteConnection.ps1`, `internal\DeviceCheck\06-RemoteDiscoveryFilters.ps1`, `internal\Test-RemoteDiscoveryFilters.ps1`, `PROJECT_RULES.md`.
Validation/tests run: `internal\Test-RemoteDiscoveryFilters.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; direct helper smoke resolved `192.168.1.13 -> DESKTOP-T76VFF3`, `192.168.1.15 -> DATACOMPUTER-ER`, and `192.168.1.62 -> DESKTOP-UQR1LBT`; work-network live repeat `internal\Test-RemoteDiscoveryLive.ps1 -RepeatCount 2 -RepeatDelaySeconds 1` returned 4 PCs in both runs with names and no `.91` expectation because `.91` was closed.

Date: 2026-07-07
Problem: DeviceCheck snapshots/history were stored under `%LOCALAPPDATA%\DeviceCheck`, so running the same tool on the laptop and desktop produced separate databases and old snapshots could disappear from the user's workflow after switching PCs.
Root cause: `%LOCALAPPDATA%` is correct for local user state but wrong as the canonical DeviceCheck evidence database. Snapshots, history, hosts cache, machine evidence, and agent cache are intended shop/workbench data that should travel with the tool or point to a shared root. DPAPI credentials and browser profiles are the opposite: they must remain local to the Windows user/PC.
Guardrail/rule: Default the DeviceCheck database root to repo-adjacent `.devicecheck-data` and ignore that folder in git. Support `DEVICECHECK_DATA_ROOT` / `DEVICECHECK_CACHE_ROOT` for an explicit shared location. Keep DPAPI credentials and browser profile under `%LOCALAPPDATA%\DeviceCheck`, not under the shared database root. TUI snapshot collection and standalone `internal\Export-DeviceCheckEvidence.ps1` must write snapshots to the same database root by default. Use `tools\Merge-DeviceCheckDatabase.ps1` to import/merge old `%LOCALAPPDATA%\DeviceCheck`, laptop/desktop, or mounted backup roots into the portable database; do not copy credentials into the shared root.
Files affected: `DeviceCheck.ps1`, `.gitignore`, `internal\DeviceCheck\01-ModelsAndCredentials.ps1`, `internal\DeviceCheck\05-InventoryAndSnapshots.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, `tools\Merge-DeviceCheckDatabase.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `DeviceCheck.ps1`, `internal\DeviceCheck\01-ModelsAndCredentials.ps1`, `internal\DeviceCheck\05-InventoryAndSnapshots.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, and `tools\Merge-DeviceCheckDatabase.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; migrated existing local database content into `.devicecheck-data`; verified `.devicecheck-data\snapshots` contains the existing `latest.json` snapshots; quick local exporter smoke without `-OutputRoot` wrote `LAPTOP-...\latest.json` under `.devicecheck-data\snapshots`; `tools\Merge-DeviceCheckDatabase.ps1` dry-run and real merge against current `%LOCALAPPDATA%\DeviceCheck` completed with zero duplicate snapshot copies.

Date: 2026-07-07
Problem: Most shop/customer snapshots use generic Windows names such as `DESKTOP-*`, especially laptops, making old machines hard to identify in the offline library.
Root cause: Snapshot folders and menu rows were based mainly on Windows computer name and machine hash. That is stable for matching, but poor as a human archive label. The useful identity is usually brand/model, CPU, GPU, RAM, and disk evidence.
Guardrail/rule: Keep stable folder names for matching, but display and persist a human `SnapshotLabel` built from hardware evidence. Labels should prefer real system brand/model, compact CPU/GPU names, RAM capacity/type, and disk size/model. Backfill old snapshots with `tools\Update-DeviceCheckSnapshotLabels.ps1`, and write `.devicecheck-data\snapshot-index.csv` so the archive can be searched outside the TUI. New TUI-collected snapshots should save `Collector.SnapshotLabel`; old/standalone snapshots can compute the label at display/index time.
Files affected: `internal\DeviceCheck\02-MachineAndTarget.ps1`, `internal\DeviceCheck\05-InventoryAndSnapshots.ps1`, `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`, `internal\DeviceCheck\07-TreeDetailsAndModels.ps1`, `internal\DeviceCheck\08-Rendering.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, `tools\Update-DeviceCheckSnapshotLabels.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for edited PowerShell files; `internal\Test-DeviceCheckStructure.ps1`; `tools\Update-DeviceCheckSnapshotLabels.ps1` backfilled 22 snapshots and wrote `.devicecheck-data\snapshot-index.csv` with labels such as `LENOVO Yoga 7 14ARP8 | Ryzen 7 7735U | Radeon Graphics | 16GB LPDDR5 | 512GB WD PC SN740...`.

Date: 2026-07-08
Problem: Generic Windows names still made it hard to scan the offline library and Computer Info, because a `DESKTOP-*` hostname might actually be a laptop.
Root cause: The TUI had readable hardware labels, but no first-class device-kind field persisted in old snapshots or shown near the selected machine summary. Laptop/desktop inference was only a menu grouping concern.
Guardrail/rule: Treat laptop/desktop classification as snapshot metadata and UI identity, not only as a menu grouping helper. Persist `Collector.DeviceKind`, `DeviceKindGroup`, `DeviceKindConfidence`, and `DeviceKindReason`; include matching fields in `.devicecheck-data\snapshot-index.csv`; and show a colored `Type` row above `Label` in Computer Info for local, remote, and offline targets. Prefer chassis/system type evidence, then battery evidence, then model/CPU heuristics.
Files affected: `internal\DeviceCheck\02-MachineAndTarget.ps1`, `internal\DeviceCheck\05-InventoryAndSnapshots.ps1`, `internal\DeviceCheck\06-RemoteConnectionOfflineMenu.ps1`, `internal\DeviceCheck\07-TreeDetailsAndModels.ps1`, `internal\DeviceCheck\08-Rendering.ps1`, `internal\Export-DeviceCheckEvidence.ps1`, `tools\Update-DeviceCheckSnapshotLabels.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for edited PowerShell files; strict-mode local classifier smoke returned `Laptop (High: chassis type)`; existing `.devicecheck-data` snapshots grouped as `Desktops: 8` and `Laptops: 14` after backfill, with `NEOS` and `PALIOS` classified as desktops and `DESKTOP-NFSVMUE` / `DESKTOP-RUHR98M` classified as laptops; `internal\Test-DeviceCheckStructure.ps1`.

Date: 2026-07-08
Problem: Lenovo `Monitor Driver.exe` could not be extracted usefully through the 7-Zip context menu/path; 7-Zip only exposed the PE wrapper sections and a raw `[0]` stream instead of the real driver payload.
Root cause: The package is an Inno Setup installer. The useful payload is inside the Inno setup data, not exposed by 7-Zip's normal PE extraction. `D:\Programs\innoextract\innoextract.exe` is installed locally and can list/extract the real files; the WinGet-installed `innoextract` may also be available through `PATH`.
Guardrail/rule: For Lenovo driver package extraction, detect Inno Setup packages and prefer `D:\Programs\innoextract\innoextract.exe --list` / `--extract --output-dir <temp>` over 7-Zip when 7-Zip shows only PE sections. Use the PATH/WinGet `innoextract` only as a fallback. Keep extraction read-only/safe by writing to a new temp folder first and comparing hashes against any existing extracted payload before trusting it.
Files affected: `PROJECT_RULES.md`; external test output under `D:\Temp\DeviceCheck-MonitorDriver-innoextract-*`.
Validation/tests run: Verified `D:\Programs\innoextract\innoextract.exe --version` returns `innoextract 1.9`; `C:\Program Files\7-Zip\7z.exe l` on `D:\Users\joty79\Downloads\laptop driver\Monitor Driver.exe` showed only PE sections and metadata saying the installer was built with Inno Setup; `innoextract --list` showed `code$GetExtractPath$\displayhdr.inf`, `displayhdr.cat`, and `setup.bat`; `innoextract --extract --output-dir D:\Temp\DeviceCheck-MonitorDriver-innoextract-20260708-023754` extracted those three files; hashes matched the existing `D:\Users\joty79\Downloads\laptop driver\extracted\Monitor Driver` payload.

Date: 2026-07-08
Problem: During read-only PowerShell inspection, a repeated parser mistake used `} | Format-Table` directly after a `foreach` statement, producing `An empty pipe element is not allowed`.
Root cause: PowerShell statements such as `foreach (...) { ... }` cannot be piped as if they were expressions in that form.
Guardrail/rule: When piping results from statement blocks in ad hoc PowerShell, either assign the block output first (`$rows = foreach (...) { ... }; $rows | Format-Table`) or wrap it as an expression/subexpression. Prefer the assignment form for Codex inspection commands because it is clearer and parser-safe.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Re-ran the extraction and comparison using `$compareRows = foreach (...) { ... }; $compareRows | Format-Table`, which parsed and executed successfully.

Date: 2026-07-08
Problem: A reachable WinRM target at `192.168.1.11` (`DESKTOP-H5EEII4`) failed remote snapshot with `Access is denied`, but the TUI presented it like a generic offline/firewall failure and returned only on Enter. The correct credential was local `DESKTOP-H5EEII4\user` with a blank password; `dcadmin`/`1234` was invalid on that PC.
Root cause: The remote snapshot flow reused or tried a credential before prompting, and credential rejection was handled by the same screen as offline/network failures. The user had no immediate retry path from the failure screen.
Guardrail/rule: Treat `Access is denied` / logon failure as a credential-rejected state when WinRM is reachable. Show the attempted user, mention `COMPUTER\user` local-account format and blank-password entry, and offer retry credentials directly from the error screen. For discovered hostname targets with no known user, default the prompt to `HOST\user` instead of an IP-based `joty79` guess.
Files affected: `internal\DeviceCheck\06-RemoteConnection.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation and `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; live quick `-NoSave` snapshot smoke against `192.168.1.11` with `DESKTOP-H5EEII4\user` and blank password returned `QuickMode = true`, `DeviceCount = 129`, and `IsAdmin = true`.

Date: 2026-07-08
Problem: Driver matching is difficult when SDIO, AMD, Lenovo, and Microsoft expose different package names for the same or related hardware IDs.
Root cause: SDIO can rank a candidate higher or mark it newer based on driver date/score even when the OEM package treats the component as separate or not applicable on the current OS. AMD chipset is a key example: official AMD 8.05.04.516 release notes list separate component versions, and `AMD USB4 CM Driver 1.0.0.43` is Windows 10-only/not applicable on Windows 11 while this laptop uses the Microsoft USB4 stack.
Guardrail/rule: Audit drivers one package at a time, starting from each Lenovo driver EXE. For every device, compare Installed DriverStore INF, Lenovo official extracted INF, SDIO candidate INF, Microsoft inbox/current driver, and OEM release notes. Treat SDIO as a candidate source only, not an install list; verify exact hardware ID, INF family, OS applicability, provider, date, version, and whether OEM notes mark the component not applicable.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Read-only verification found the laptop's USB4 path uses Microsoft `usb4hostrouter.inf` for `USB4(TM) Host Router (Microsoft)` on `PCI\VEN_1022&DEV_162E...&USB4_MS_CM`, Microsoft `usb4devicerouter.inf` for `USB4 Root Router`, and Microsoft `ucmucsiacpiclient.inf` for `UCM-UCSI ACPI Device`. SDIO still lists AMD `amdusb4cm.inf 1.0.0.43` candidates as `BETTER+OLD` for the host router, matching AMD release notes that USB4 CM is not applicable on Windows 11.

Date: 2026-07-09
Problem: Mixing Lenovo baseline checks with SDIO or Microsoft Catalog newer-candidate checks made early driver verdicts noisy, especially when Catalog results include unrelated OEM packages with similar titles.
Root cause: The audit needs two separate passes: first prove what the current Windows install already has compared with Lenovo's extracted official packages, then add external candidate sources such as SDIO or MSCatalogLTS. Without that separation, a "newer" candidate can distract from the basic question of whether the Lenovo package is already installed or applicable.
Guardrail/rule: For the current driver audit, Phase 1 is installed DriverStore/`C:\Windows\INF` vs Lenovo extracted packages only. For each Lenovo package, identify the installed device/HWID, choose the matching vendor subfolder, compare `DriverVer`, exact hardware IDs, and hashes against DriverStore files, then give a baseline verdict. Defer SDIO, Microsoft Update Catalog, and MSCatalogLTS checks to Phase 2 after the Lenovo baseline pass is complete.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Read-only baseline checks already confirmed the old Lenovo MediaTek Bluetooth package and Sunplus camera package were byte-for-byte installed; a separate Microsoft Catalog Sunplus `5.0.26.6` sample was rejected because its INF hardware IDs were HP-specific and did not include this laptop's `USB\VID_5986&PID_215D`.

Date: 2026-07-09
Problem: Opening DeviceCheck manually from the repository became annoying during repeated driver-audit testing.
Root cause: DeviceCheck had no Explorer integration, so every run required navigating to the repo and launching `DeviceCheck.ps1` manually.
Guardrail/rule: Keep DeviceCheck's Explorer context menu as a current-user HKCU integration, not an admin-required machine install. `Install-DeviceCheckContextMenu.ps1` owns install/uninstall of the `Directory\Background`, `Directory`, and `Drive` shell verbs, uses `Launch-DeviceCheck.vbs` as the launcher, and uses the bundled `assets\devicemanager.ico` icon. The launcher should start DeviceCheck elevated via `ShellExecute(..., "runas")` because DeviceCheck's hardware/registry evidence paths often benefit from admin access; expect a UAC prompt from the context menu. Verify context-menu writes with `reg.exe query`, not only the PowerShell registry provider.
Files affected: `Install-DeviceCheckContextMenu.ps1`, `Launch-DeviceCheck.vbs`, `assets\devicemanager.ico`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `Install-DeviceCheckContextMenu.ps1`; installed HKCU context-menu keys; `reg.exe query` readback confirmed desktop/folder background, folder, and drive verbs point to `wscript.exe` with `Launch-DeviceCheck.vbs` and use `assets\devicemanager.ico`.

Date: 2026-07-10
Problem: Driver-source choice became confusing because DeviceCheck was being mentally pulled toward "driver updater" behavior before its evidence model was mature.
Root cause: Real driver stacks include active function drivers, extension INFs, software components, services, OEM enablement packages, Windows Update packages, SDIO candidates, and vendor installers that may all use different version/date schemes. Treating "newer" or "official" as a single global rule is unreliable.
Guardrail/rule: Treat DeviceCheck as a driver evidence explorer first, not a driver updater. For each device, show identity, active driver, attached stack, provenance, candidate-source comparisons, match strength, and risk/verdict labels. Before trusting any installer outcome, use a before/after tracker over DriverStore, `C:\Windows\INF`, PnP devices/properties, services, and SetupAPI logs.
Files affected: `docs\DRIVER_EVIDENCE_DECISION_MODEL.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Documentation-only update; `git diff --check`.

Date: 2026-07-10
Problem: Driver installer behavior needs practical testing without prematurely integrating installer tracing into the DeviceCheck TUI.
Root cause: Extracted INF preview can predict likely matches, but only a before/after trace proves whether an EXE staged packages, changed active bindings, added extension INFs, wrote services, or did nothing because Windows driver ranking rejected it.
Guardrail/rule: Keep driver package impact tracing standalone under `tools\Trace-DriverPackageImpact.ps1` until reports prove useful. The `.exe` context menu launches elevated through `tools\Launch-DriverPackageImpactTrace.vbs`; the script creates `report.md` plus raw JSON snapshots/diffs under `.devicecheck-data\driver-package-traces` and asks before running the installer unless `-RunInstaller` is used explicitly.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `tools\Launch-DriverPackageImpactTrace.vbs`, `Install-DriverPackageTraceContextMenu.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation; safe `-PreviewOnly` smoke against Lenovo `Cardreader Driver (Genesys, Bayhub, Realtek).exe` found Realtek `RtsPer.inf` / `RtsCrExtPr.inf` matches and wrote `report.md` plus `before.snapshot.json`; installed the HKCU `.exe` context-menu verb and verified it with `reg.exe query`; no installer was run.

Date: 2026-07-10
Problem: The trace prototype hit strict-mode/runtime failures while building package preview output.
Root cause: A local `$matches` variable collided with PowerShell's automatic `$Matches` variable, and display-only `Format-Table` output inside a function polluted the function's returned data.
Guardrail/rule: In diagnostic/trace functions, never use case variants of automatic variables such as `$matches`. Keep functions data-pure; send display-only formatting to `Out-Host` or do formatting only after storing real data objects.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `PROJECT_RULES.md`.
Validation/tests run: Reworked the local variable names and display formatting, then reran the safe `-PreviewOnly` smoke successfully against the Lenovo cardreader package.

Date: 2026-07-10
Problem: The first real cardreader installer trace proved that "installed" is ambiguous: the Lenovo EXE staged packages in DriverStore but did not change the active Realtek cardreader binding.
Root cause: Windows can publish/stage driver packages with `pnputil /add-driver /install` while keeping the currently selected active driver if ranking/version/provider evidence does not require a switch. A newly published `oem*.inf` can therefore be duplicate availability, not a practical update.
Guardrail/rule: Driver impact reports must distinguish staged DriverStore packages from active device-driver changes. For every staged package, map `PublishedName -> OriginalName` and compare it with the active signed driver's `InfName`/original INF/version before calling anything an update. Same-original/same-version staged packages should be labeled as already-active duplicate availability.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Regenerated the real Lenovo cardreader trace report from existing raw evidence; the report now shows `oem145.inf` / `rtsper.inf` as `Staged only; same version already active` with active evidence `Realtek PCIE CardReader via oem19.inf / 10.0.22621.21365`, while BayHub and Genesys packages are staged-only and no active device driver changed.

Date: 2026-07-10
Problem: The Wacom trace showed that version number alone is not enough: Lenovo staged `WacHIDRouterISDF.inf` version `8.0.2.15`, but Windows kept active `oem45.inf` with the same version and a newer driver date.
Root cause: Windows driver ranking considers date and match quality in addition to version. Driver reports that only show version can make a staged-but-rejected package look equivalent to the active driver without explaining why Windows kept the existing binding.
Guardrail/rule: Driver impact reports must show active and staged driver dates next to versions. When the same original INF/version is active under another `oem*.inf`, compare dates and label newer-active cases as `same version already active with newer date`.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Regenerated the real Wacom trace report from existing raw evidence; the report now shows active `oem45.inf` / `wachidrouterisdf.inf` date `2025-02-20` version `8.0.2.15` and staged `oem146.inf` date `2025-01-21` version `8.0.2.15`, labeled `Staged only; same version already active with newer date`.

Date: 2026-07-10
Problem: Monitor and Peripheral/Re-Timer traces had empty before/after diffs but non-empty SetupAPI activity, so the human report originally hid useful reasons like `Already Imported` and `No better matching drivers found`.
Root cause: DriverStore/signed-driver diffs only show final state changes. SetupAPI can still explain attempted install behavior, including already-imported packages, no-update ranking decisions, non-present device marking, and section exit status.
Guardrail/rule: When `SetupAPI delta characters` is non-zero, reports should include `SetupAPI Outcome Signals` even if no DriverStore or active-driver state changed. Surface import outcome, driver INF, ranking/no-update messages, matching failures, non-present device markers, and section exit status from `SetupApiInterestingLines`.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Regenerated the real Monitor and Peripheral/Re-Timer reports from existing raw evidence. Monitor now shows `Already Imported`, `displayhdr.inf (oem59.inf)`, `Device does not need an update`, `No better matching drivers`, and `Section exit: SUCCESS`; Peripheral/Re-Timer now shows `Already Imported`, `prhiddrv.inf (oem26.inf)`, `prspbdrv.inf (oem36.inf)`, `No devices were updated`, multiple no-better-match ACPI devices, and `Section exit: FAILURE(0x00000103)`.

Date: 2026-07-10
Problem: During driver-package testing, important trace-script improvement notes can be missed if they are buried in normal chat while the user is running installers and handling restart prompts.
Root cause: The workflow is interactive and sequential: if the trace report format is weak for one package, continuing to the next installer can preserve avoidable blind spots.
Guardrail/rule: When `tools\Trace-DriverPackageImpact.ps1` clearly needs an improvement, make that script/report improvement before continuing the next driver audit whenever practical. Announce it with a high-visibility line that includes `⚠️ !!` so the user does not miss it.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Documentation-only workflow rule update.

Date: 2026-07-10
Problem: The Lenovo Smart Appearance trace looked like "no active driver changed", but the important truth was that SetupAPI selected both the base Sunplus camera driver and the Lenovo `lnvdmft.inf` Extension INF stack.
Root cause: `Win32_PnPSignedDriver` and Device Manager's normal Driver tab expose the base/function driver, but Extension INFs can be selected/installed beside that base driver without changing the visible active driver binding.
Guardrail/rule: Driver trace reports must surface SetupAPI selected driver stack nodes, not only final DriverStore/signed-driver diffs. Parse `Driver Node` and `Driver Extension Node` blocks from SetupAPI, show selected/outranked status, published/original INF, provider/class, date/version, rank, Extension ID, and configuration, and keep a report-regeneration path so old trace folders can be reinterpreted without rerunning installers.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `tools\Trace-DriverPackageImpact.ps1`; `internal\Test-DeviceCheckStructure.ps1`; `git diff --check`; regenerated the real Smart Appearance trace with `-RegenerateTraceDirectory`; safe `-PreviewOnly` smoke against the Smart Appearance EXE; `report.md` now shows `oem42.inf` / `spuvcbvmerge.inf` as selected base camera driver, `oem43.inf` / `lnvdmft.inf` as selected Lenovo Extension INF, and `usbvideo.inf` as outranked inbox fallback.

Date: 2026-07-10
Problem: `Lenovo MFGSTAT Log Clean.exe` looked like a driver in the Lenovo download folder, but its extracted payload contained only `RemoveMFGSTAT.exe` and no INF files; the trace report initially said the extracted payload was `not found`.
Root cause: The trace preview helper treated an extracted folder as "existing" only if it contained INF files. That hid utility/cleanup payloads and made non-driver packages look like missing extraction or failed driver traces.
Guardrail/rule: Driver trace reports must distinguish "no extracted payload" from "payload exists but contains no INF files". For OEM EXEs with extracted files but zero INF files and no DriverStore/SetupAPI/active-driver changes, label the verdict as utility/cleanup/non-driver package.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `tools\Trace-DriverPackageImpact.ps1`; regenerated the real `Lenovo MFGSTAT Log Clean` trace with `-RegenerateTraceDirectory`; safe `-PreviewOnly` smoke against the same EXE confirmed the report now shows one payload file, zero INF files, and a utility/cleanup verdict.

Date: 2026-07-10
Problem: `Dolby Vision Provisioning Kit.exe` extracted to an MSI (`DolbyVisionPQConfigInstaller.msi`) rather than an INF driver payload, but the no-INF report wording was too generic and grouped it with cleanup utilities.
Root cause: OEM download folders can contain provisioning/application packages beside real driver packages. A no-INF payload can still be meaningful software or configuration, especially when it is an MSI with product metadata.
Guardrail/rule: For no-INF extracted payloads, classify payload kind by file types. Surface MSI payloads as provisioning/application packages and include MSI product name, version, manufacturer, and file path in the report. Do not call MSI provisioning packages driver updates unless DriverStore, SetupAPI, or active-driver evidence changes.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `tools\Trace-DriverPackageImpact.ps1`; regenerated the real Dolby Vision trace with `-RegenerateTraceDirectory`; safe `-PreviewOnly` smoke against the same EXE confirmed `Payload kind: MSI provisioning/application payload` and MSI metadata `Dolby Vision PQ Config Installer 2.0.0.4` by Dolby.

Date: 2026-07-10
Problem: Installing the `.exe` trace context menu under `HKCU\Software\Classes\exefile\shell` made the DeviceCheck trace verb become the default action for `.exe` files, breaking normal double-click/open behavior for executables.
Root cause: A per-user `exefile\shell` override can shadow the machine `exefile` shell association. Because the DeviceCheck trace verb was the only user-level `exefile\shell` verb, Windows treated it as the default verb instead of the normal `open` command.
Guardrail/rule: Never install optional `.exe` file context-menu verbs under per-user `exefile\shell` unless deliberately changing executable default verbs. Use `HKCU\Software\Classes\SystemFileAssociations\.exe\shell\<VerbName>` for `.exe` file context menus, and always remove legacy `HKCU\Software\Classes\exefile` overrides when migrating away from a bad key. Verify `.exe=exefile`, `exefile="%1" %*`, `HKCR\exefile\shell\open\command`, and a ShellExecute `open` smoke after any `.exe` context-menu registry change.
Files affected: `Install-DriverPackageTraceContextMenu.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Deleted the live legacy `HKCU\Software\Classes\exefile` override; reinstalled the context menu under `SystemFileAssociations\.exe\shell`; verified `HKCU\Software\Classes\exefile` is absent, `.exe=exefile`, `exefile="%1" %*`, `HKCR\exefile\shell\open\command` is `"%1" %*`, and ShellExecute `open` against `cmd.exe /c exit 0` returned exit code 0.

Date: 2026-07-10
Problem: Re-running the Cardreader package produced repeated `SetupAPI Selected Driver Stack` rows for the same Realtek selected/outranked nodes, making the report look busier than the actual driver decision.
Root cause: SetupAPI can emit multiple driver-selection sections during one installer run, especially when an installer imports several related INFs or retries the same device update path. The report parser preserved every node instance verbatim.
Guardrail/rule: Dedupe SetupAPI driver stack rows by node kind, status, device ID, published/original INF, date/version, rank, Extension ID, and configuration before rendering. Keep distinct selected vs outranked/rank/configuration rows, but remove exact repeats.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `tools\Trace-DriverPackageImpact.ps1`; regenerated the real Cardreader trace with `-RegenerateTraceDirectory`; selected stack rows dropped from 10 to 6 while preserving Realtek selected base driver `oem19.inf`, selected extension `oem18.inf`, and outranked Lenovo-imported `oem145.inf` evidence.

Date: 2026-07-10
Problem: The Lenovo camera package staged Realtek `RtLeJF*.inf` packages into DriverStore, but SetupAPI immediately reported `Unable to find any matching devices`; the report initially labeled them only as generic `Staged only`.
Root cause: DriverStore publish/import is not the same as device applicability. OEM camera bundles can include vendor variants for other camera modules, and Windows may stage those packages while no present PnP device can bind to them.
Guardrail/rule: When SetupAPI reports `Unable to find any matching devices` after a `Driver INF - <inf> (<oem>.inf)` import, label matching staged packages as `Staged only; no matching present device`. If every staged package has that status and no active driver changed, the report verdict should say exactly that.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `tools\Trace-DriverPackageImpact.ps1`; regenerated the real Camera trace with `-RegenerateTraceDirectory`; report now labels `oem149.inf` / `rtlejf.inf` and `oem150.inf` / `rtlejfir.inf` as `Staged only; no matching present device`, while active Sunplus camera drivers remain unchanged.

Date: 2026-07-10
Problem: The Lenovo WLAN package preview falsely matched `Realtek PCIE CardReader` because the package INF contained a broad compatible ID that overlapped the cardreader's vendor-only PCI ID.
Root cause: Compatible IDs such as `PCI\VEN_####`, `PCI\CC_*`, generic USB class IDs, and generic HDAUDIO function IDs are too broad for preview matching. They can make an unrelated INF look applicable before SetupAPI proves real hardware applicability.
Guardrail/rule: Package preview matching may use exact hardware IDs and specific compatible IDs, but it must ignore vendor-only/class-only generic compatible IDs. Regeneration from an existing trace folder must recompute `package-preview.json` from the original installer when the installer path still exists, so old traces inherit safer matching logic.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for `tools\Trace-DriverPackageImpact.ps1`; regenerated the real WLAN trace with `-RegenerateTraceDirectory`; preview matches dropped from 2 to 1, leaving only exact `RZ616 Wi-Fi 6E 160MHz` hardware ID match on `MTK\mtkwl6ex.inf`. The report now shows active `oem60.inf` / `mtkwl6ex.inf` date `2026-01-30` version `25.40.2.586`, Lenovo MTK package `05/23/2023, 23.032.2.0558` as not a better match/already imported, and Realtek `oem151.inf` / `netrtwlane602.inf` as `Staged only; no matching present device`.

Date: 2026-07-10
Problem: The WLAN report showed a false hybrid SetupAPI stack row that combined Realtek `netrtwlane602.inf` import metadata with the preceding MediaTek RZ616 outranked node, and large SetupAPI deltas could silently lose outcome evidence after 500 filtered lines. Active-driver diffs also ignored bindings that appeared or disappeared between snapshots.
Root cause: The SetupAPI node parser did not flush and clear the final node at `Select Drivers`, update-device, or section boundaries, so later `Driver INF` and `Driver Version` lines overwrote it. `Compare-TraceSnapshots` truncated `SetupApiInterestingLines` and compared existing signed-driver rows only.
Guardrail/rule: Treat SetupAPI section/selection boundaries as hard driver-node boundaries; never allow later package-import metadata to mutate a completed node. Preserve the complete filtered SetupAPI evidence set for structured outcome parsing, show the node's device instance ID, and treat added/removed `Win32_PnPSignedDriver` bindings as active-driver state changes alongside updated bindings.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation; synthetic regression retained 650/650 filtered SetupAPI lines and detected one updated, one added, and one removed active binding; real WLAN raw-log regression returned only `oem60.inf` selected and `oem41.inf` outranked with no false Realtek node; regenerated all 24 existing trace folders without rerunning installers.

Date: 2026-07-10
Problem: Regenerated Camera preview evidence matched the present `SpitCameraGroup` device against four Realtek/Sunplus INFs only because each side contained the bare compatible ID `SensorGroup`.
Root cause: `SensorGroup` identifies a generic Windows camera sensor grouping role and has no bus, vendor, product, or model specificity, so treating it as package applicability creates cross-vendor false positives.
Guardrail/rule: Ignore bare `SensorGroup` compatible IDs during package preview matching. Keep exact camera hardware-ID matches and specific enumerator-qualified compatible IDs, and add new generic IDs to the preview deny-list only from observed false-positive evidence.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation; direct matching regression confirms `SensorGroup` is rejected while `USB\VID_5986&PID_215D` remains useful; regenerated the real Camera trace without rerunning its installer, reducing preview matches from 8 to 4 while retaining the exact Sunplus camera/composite-device matches.

Date: 2026-07-10
Problem: The Lenovo Energy Management trace had an exact `AcpiVpc.inf` hardware match but reported only “No new published drivers and no active driver changes,” hiding that the package driver was substantially older than the active same-family driver. The trace artifacts also omitted the installer process exit code even though it was printed during the live run.
Root cause: Verdict logic compared state changes and SetupAPI outcomes but did not join preview matches to the active driver's original INF/date/version. Installer execution metadata was transient console output rather than persisted evidence.
Guardrail/rule: For exact matched package INFs, compare package `DriverVer` against the active driver only when both resolve to the same original INF family, and report `Older`, `Same`, or `Newer` with the comparison basis. Persist future installer start/end timestamps, exit code, and after-snapshot capture time in `run-metadata.json`; do not invent or backfill an exit code for older traces.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation; in-memory `Older`/`Same`/`Newer` comparison regression; regenerated the real Energy Management trace without rerunning its installer. The report now shows package `AcpiVpc.inf` `2022-07-11 / 15.11.29.70` versus active `oem30.inf` / `acpivpc.inf` `2025-08-14 / 15.11.30.11` as `Older`, and honestly labels the historical exit code `not recorded`.

Date: 2026-07-10
Problem: The FingerPrinter package correctly reported zero local matches, but the report did not say which fingerprint devices its Egis/Goodix INFs actually supported, and preview providers appeared as unresolved `%EGIS%` / `%ManufacturerName%` tokens.
Root cause: Package preview stored general INF metadata but did not parse model-entry hardware IDs, and `Get-InfValueFromText` returned string indirection tokens without resolving the INF `[Strings]` section.
Guardrail/rule: When an INF package has no local matches, include a bounded table of its supported device IDs so no-present-device verdicts are auditable from `report.md`. Resolve exact `%Token%` metadata values through `[Strings]`, including quoted values with trailing INF comments, before rendering Provider/Class fields.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation; regenerated the real FingerPrinter trace without rerunning its installer; report lists Egis `USB\VID_1C7A&PID_0576` and Goodix `USB\VID_0BDA&PID_5811`, `USB\VID_27C6&PID_5584`, `USB\VID_27C6&PID_55B4` with resolved providers. The same real run verified `run-metadata.json` end-to-end with installer exit code `0`, start/end timestamps, and after-snapshot capture timestamp.

Date: 2026-07-10
Problem: The Realtek Audio preview rendered long `MatchedId` values and INF paths through `Format-Table -AutoSize -Wrap`, leaving large horizontal gaps while compressing the INF column to roughly three characters and expanding each candidate into many near-empty lines.
Root cause: PowerShell's automatic table formatter optimized all six variable-length columns together. A few long unbroken IDs consumed most of the calculated width, leaving no usable width for extracted relative paths.
Guardrail/rule: Do not use automatic multi-column table layout for driver preview records containing long unbroken hardware IDs and paths. Render each candidate as a compact width-aware block with aligned `Match`, `ID`, `INF`, `DriverVer`, and `Provider` fields, and use hanging continuation indentation when a value exceeds the terminal width.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: PowerShell parser validation; inspected the provided screenshot and captured administrator terminal output; regenerated the real Realtek Audio trace without rerunning its installer. All 13 candidates rendered as compact readable blocks, with the longest INF path using one aligned continuation line instead of character-by-character wrapping.

Date: 2026-07-10
Problem: The AMD VGA report called ten new packages “staged only,” but raw SetupAPI evidence showed that newly staged `oem158.inf` / `amduw23e.inf` was selected and applied as the Radeon Extension INF, the device subtree was removed/restarted, and PnP configuration succeeded while the newer active function driver remained unchanged. During the parser fix, enumerating a typed `List[object]` stored inside an ordered hashtable through `@(...)` raised runtime `Argument types do not match`.
Root cause: `Win32_PnPSignedDriver` does not expose Extension INF application, and the report parsed driver-selection nodes but not `Install Device: Configuration` actions. The SetupAPI device-ID regex also stopped at the first `}` inside `SWD\DRIVERENUM\{GUID}` IDs. PowerShell's dynamic enumerable binder was unreliable for the typed generic list retrieved directly from the hashtable indexer.
Guardrail/rule: Parse SetupAPI device-configuration transactions as first-class evidence: record every configured published INF, original INF/class, newly-staged status, device subtree removal, device restart, and PnP result. A newly staged INF that appears in a successful device configuration is `Applied`, not `Staged only`, and must take verdict priority even when the function-driver binding is unchanged. Capture update-device IDs through the final timestamp delimiter so embedded GUID braces remain intact. When a typed generic list is stored in a hashtable, cast it back to its declared `List[T]` type and enumerate `.ToArray()` instead of wrapping the index expression in `@(...)`.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation; regenerated the real AMD VGA trace without rerunning its installer; report now shows `oem158.inf` as `Applied Extension INF configuration`, Radeon configuration alongside active `oem12.inf`, device subtree removal/restart, and PnP result `00000000`. After snapshot confirms Radeon `Status=OK`, `Problem=0`, `ConfigManagerErrorCode=0`, active function driver `32.0.21043.19003`, and no reboot-required signal. The initial generic-list runtime failure was reproduced with a stack trace and eliminated by explicit typed `.ToArray()` enumeration.

Date: 2026-07-10
Problem: The first post-reboot audit command failed to parse with `An empty pipe element is not allowed` at `foreach (...) { ... } | Format-List`, before any checks ran.
Root cause: In an inline PowerShell command body, piping directly from that bare `foreach` statement form is not valid in the constructed grammar, even though the intended data flow is conceptually pipeline-compatible.
Guardrail/rule: In PowerShell audit/smoke commands, assign `foreach` output to a named variable first, then pipe that variable to `Format-*` or another consumer. Treat parser failure as zero execution, report it immediately, and rerun the complete read-only check rather than assuming earlier parallel branches produced usable results.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: The failed command produced only the parser error and no mutations. Rewritten `$fileRows` / `$driverRows` commands parsed and completed all post-reboot Radeon, Adrenalin, service, Event Log, `pnputil`, and DriverStore checks.

Date: 2026-07-10
Problem: After completing the Lenovo package audit and rebooting, the final state needed to distinguish what is actually active from packages that were merely staged during testing, especially because Adrenalin initially did not open before reboot.
Root cause: Large OEM bundles can mix older function drivers, Extension INFs, software components, and related audio drivers. DriverStore presence alone cannot identify the live stack, and Extension INF application is not visible through `Win32_PnPSignedDriver`.
Guardrail/rule: Use the post-reboot live baseline as the final authority: combine `Get-PnpDevice`/device properties, `Win32_PnPSignedDriver`, `pnputil /enum-devices /drivers`, running AMD processes/services, and post-boot Event Logs. For this laptop, retain active Radeon `oem12.inf / u0202073.inf` `32.0.21043.19003` and installed Extension `oem158.inf / amduw23e.inf`; do not classify `oem158.inf` as cleanup. Treat the other audit-added packages as cleanup candidates only after an explicit, separately authorized cleanup review.
Files affected: `PROJECT_RULES.md` and regenerated reports/diffs under `.devicecheck-data\driver-package-traces`.
Validation/tests run: Reboot confirmed at `2026-07-10 14:22:42`; Radeon is `Started/OK/CM_PROB_NONE` with active `oem12.inf`; live `pnputil` reports `oem158.inf` as `Best Ranked / Installed / Extension` and `oem157.inf` as outranked. `RadeonSoftware.exe` is responsive with AMD Software `26.6.4`; AMD services are running; no AMD/Radeon Application errors occurred after boot. One startup Event 219 for `ACPI\AMDI0080\1` was transient—current AMD UMDF Sensor is `OK`, problem code `0`, active `oem55.inf / 1.0.0.341`, and the warning did not repeat. Across 18 completed traces, no active signed-driver binding changed; only `oem158.inf` became an applied configuration. Of 21 audit-added DriverStore packages, `oem158.inf` is installed/applied and the other 20 are stored-only/not active bindings.

Date: 2026-07-10
Problem: Per-installer reports explained the immediate before/after result, but the standalone lab lacked a reusable post-reboot check and a cross-trace view. This made it difficult to distinguish currently active function drivers, retained Extension configuration, and packages that Windows only kept in the Driver Store. Installer exit codes also had no durable interpretation.
Root cause: Windows can independently stage an INF, select or outrank it, apply an Extension INF, preserve a newer function driver, and finalize state after reboot. No single evidence source exposes all of these outcomes, and `Win32_PnPSignedDriver` does not expose installed Extension INFs.
Guardrail/rule: Keep driver-package investigation standalone from the main DeviceCheck TUI until the evidence model proves which facts are useful for a future OEM/Windows Update/Catalog/SDIO recommendation engine. For final state, combine PnP health, live signed function drivers, per-device `pnputil /drivers` installed status, Driver Store presence, and relevant post-boot events. Classify `Stored-only` as evidence, never as an automatic cleanup or rejection decision. Interpret installer exit codes explicitly, including ambiguous wrapper/child-process code `259` and restart codes `1641`/`3010`. When parsing native output under `StrictMode`, preserve regex captures before another `-match` can overwrite `$Matches`, and never assume a filtered collection has a property or `.Count` without forcing array shape.
Files affected: `tools\Trace-DriverPackageImpact.ps1`, `tools\Invoke-DriverPackagePostRebootAudit.ps1`, `tools\Get-DriverPackageTraceSummary.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
Validation/tests run: Parser validation for all three PowerShell scripts; real post-reboot audit of the AMD VGA trace confirmed active Radeon `oem12.inf`, installed Extension `oem158.inf`, nine AMD VGA packages stored-only, device status `OK`/problem `0`, and no relevant post-boot warning/error; real consolidated summary classified one trace-added package as installed Extension/configuration and twenty as stored-only. The two initial `StrictMode` runtime failures on empty binding collections and overwritten `$Matches` were reproduced, fixed, and rerun successfully.

Date: 2026-07-10
Problem: A final verification command falsely reported that `DeviceCheck.ps1` had changed even though `git diff --quiet -- DeviceCheck.ps1` returned native exit code `0`.
Root cause: PowerShell `if (native-command)` evaluates the command's pipeline output, not `$LASTEXITCODE`. `git diff --quiet` intentionally emits no stdout in the unchanged case, so the condition evaluated as false.
Guardrail/rule: For native predicates such as `git diff --quiet`, run the command first and evaluate `$LASTEXITCODE` explicitly. Do not use native command stdout directly as a Boolean when success can legitimately produce no output.
Files affected: `PROJECT_RULES.md`.
Validation/tests run: Repeated `git diff --quiet -- DeviceCheck.ps1`, captured `$LASTEXITCODE = 0`, confirmed `Unchanged = True`, and reran `git diff --check` successfully.
