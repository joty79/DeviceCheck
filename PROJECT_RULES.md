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
