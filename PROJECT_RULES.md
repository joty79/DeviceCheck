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
