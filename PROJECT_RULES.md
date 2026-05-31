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
