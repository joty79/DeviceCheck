# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-05-31

### Added
- Parameterized the Agent model name using the `-ModelName` parameter in `Get-DriverUpdateAgent.ps1` and passed the user-selected model dynamically from the `DeviceCheck.ps1` TUI instead of hardcoding `gemini-3.1-flash-lite`.
- Disabled the built-in `google_search` grounding tool due to a Gemini API restriction that forbids combining built-in tools with custom Function Calling in the same request.
- Prevented monitor EDID hardware/PnP codes (such as `GSM5BD3`) from being prefetched as direct search inputs on LG support pages, allowing Google Search to perform model discovery first.
- Refactored `Get-GoogleSearchQueries` to build clean, deduplicated, single-line human-like queries combining device properties instead of robotic multiline blocks.
- Added `--disable-blink-features=AutomationControlled` to Chrome arguments in `Search-GoogleRendered.js` to disable webdriver detection and mitigate instant CAPTCHA challenges.
- Updated TUI status display to render the active Agent model name dynamically (e.g., `[Agent: gemini-2.5-flash]`).
- Implemented **Stealth Browser Automation & Persistent Profile** support in `tools/Search-GoogleRendered.js`, using a stable Chrome profile directory (`browser-profile`) and simulating human-like key typing (typed-search emulation) instead of direct URL queries to prevent reCAPTCHA blocks.
- Completed and documented the Gemini response for Google Search / AI Overview retrieval strategies (`docs/gemini-google-search-investigation-response.md`), outlining recommended workflows, tool/prompt changes, and human-in-the-loop fallback strategies.
- Added documentation analyzing Google Search AI Overview behavior in profiled vs non-profiled sessions, including test evidence logs (`docs/google-search-profile-analysis.md`).
- Added system design and research documentation for local/online Device ID databases (PCI, USB, EDID/PNP) to achieve offline deterministic device resolution (`docs/device-id-database-research.md`).
- Added autonomous Agentic Driver Finder (`Get-DriverUpdateAgent.ps1`) that uses Gemini 3.1 Flash Lite Function Calling (Tool Use) to automatically search for, identify, and locate the latest official drivers for any device.
- Agent has built-in tools for `SearchGoogleCustom` (official Google Custom Search JSON API when configured), `SearchWeb` (guarded DuckDuckGo fallback), `FetchUrlText` (plain HTML text/link extractor), `FetchRenderedUrlText` (real Chrome DevTools rendered-page extraction with optional category/tab click), and `SearchUpdateCatalog` (Microsoft Update Catalog search with direct `.cab` download link extraction via POST to DownloadDialog.aspx).
- Agent runs in a recursive loop: Gemini decides which tool to call, the script executes it locally and feeds the result back, until Gemini produces a final synthesized answer with version, date, and download URLs.
- Added `tools/Fetch-RenderedPage.js`, a dependency-light Node helper that drives local Chrome through DevTools Protocol for JavaScript-rendered OEM support pages that block plain HTTP fetches.
- Rendered-page helper can now type into visible search/product inputs, letting the Agent use OEM search pages such as AOC Drivers & Software.
- Integrated Agent into the DeviceCheck TUI via the `A` hotkey. Selecting a device and pressing `A` launches the Agent in a background runspace.
- Live Agent activity is displayed in real-time in the right-side Details Panel, including model steps, requested tools, query/url arguments, and short tool-result previews.
- Agent runs now write JSONL traces under the machine cache so failed or misleading lookup paths can be audited after the TUI run.
- Agent runs now save resumable checkpoints after every Gemini/tool step, including conversation state, tool results, candidate URLs, confirmed/failing URLs, and current plan.
- Added a tool-result cache for rendered pages, plain fetches, web searches, and Microsoft Update Catalog lookups so retries do not refetch recent evidence unnecessarily.
- Added a deterministic prefetch phase before Gemini planning, currently including an AOC regional product-page adapter as the first vendor-specific pattern.
- Added vendor-first candidate guidance for agent runs so Gemini receives official rendered-page actions before it can fall back to search snippets.
- Added `tools/Search-GoogleRendered.js`, a Chrome/Edge DevTools Google Search helper that feeds raw Device Manager-style evidence to Google, captures AI Overview text as an identity hint, and returns top organic result URLs for official-page confirmation.
- Added `SearchGoogleCustom`, an official Google Custom Search JSON API tool controlled by `GOOGLE_CUSTOM_SEARCH_API_KEY` and `GOOGLE_CUSTOM_SEARCH_CX`, so agent discovery can avoid automated Google SERP sessions.
- Added regional-first discovery guidance so Greece/Europe OEM pages are checked before US/global pages when vendor sites differ by region.
- Added Google anti-bot/reCAPTCHA detection so rendered search blocks are logged clearly and the agent stops retrying Google during that run.
- Limited automatic Google discovery to official Custom Search API when configured, reducing CAPTCHA risk while keeping browser Google only as an explicit fragile fallback/diagnostic.
- Added `docs/gemini-google-search-investigation.md`, a focused Gemini briefing for investigating reliable Google Search / AI Overview retrieval.
- Re-enabled the browser Google Search tool in Gemini's default tool list for active testing, while keeping block detection and retry limits.
- Added a 10-step Agent budget guard that pauses with checkpoint state instead of spending unbounded Gemini requests.
- Fixed Agent activity streaming so logs appear while the background runspace is still running instead of only after completion.
- Agent result rows now stay as one selectable tree item, while the full driver report, trace path, and clickable terminal download links are displayed in the right-side details pane.
- Added `A = agent` shortcut to both footer renderers (legacy and dual-pane).

### Fixed
- Fixed SyntaxError in the browser JS code of `tools/Search-GoogleRendered.js` caused by unescaped newlines inside the RegExp literal (`/\r?\n/g`) in Node's template string.
- Increased CDP command timeout in `tools/Search-GoogleRendered.js` to 45 seconds and optimized query input to simulate human paste (`document.execCommand('insertText')`) for long queries, preventing command timeouts on multiline property blocks.
- Hid `SearchGoogleCustom` from Gemini tool declarations unless `GOOGLE_CUSTOM_SEARCH_API_KEY`/`GOOGLE_CUSTOM_SEARCH_CX` (or the `GOOGLE_CSE_*` aliases) are configured, preventing a wasted agent step on the "Custom Search API is not configured" result.
- Fixed `SearchGoogleRendered` cache handling so empty Google-home results are ignored/deleted and cached results do not consume the per-run rendered Google budget before a real browser attempt.
- Improved Google Search form submission in `tools/Search-GoogleRendered.js` by emulating keyboard `Enter` events and clicking the Google Search button as fallbacks to raw `form.submit()`, ensuring typed queries submit correctly on dynamic search variants.
- Added programmatic wrapping and hyperlink formatting for `Log`, `Checkpoint`, and `Cache` path values in `DeviceCheck.ps1`'s details panel using `Add-WrappedPathLine` to prevent truncation and make them Ctrl-clickable terminal links.
- Enforced using the full multiline Device Properties Block as the search query in `SearchGoogleRendered` inside `Get-DriverUpdateAgent.ps1`. If the Gemini model tries to call the tool with a short/summarized search query, the function automatically overrides it with the full script-scoped `$script:devicePropertiesBlock` to guarantee accurate model resolution and AI Overview parsing in Google.
- Fixed Gemini 3 tool-calling `400 Bad Request` failures by preserving the full model content, including `thoughtSignature`, when sending function-call history back to the API.
- Fixed Agent API failures being displayed as successful `(Done)` results; they now return `Type = Error` and render as failed in the TUI.
- Fixed a strict-mode crash when Gemini returns a final text response without a `functionCall` property.
- Fixed final answers emitted on the last allowed Agent step being overwritten by a false maximum-iteration error.
- Fixed rate-limit handling so Gemini `429`/quota responses pause as `Paused: Rate limit` with a checkpoint instead of becoming an unrecoverable failed run.
- Improved DuckDuckGo anti-bot handling so AOC model searches point Gemini toward rendered AOC driver-page search instead of repeated failed web queries.
- Changed Agent `SearchWeb` into a guarded last-resort discovery tool: it now blocks premature DuckDuckGo use when official vendor candidates exist and limits repeated search loops.
- Passed compact local device evidence JSON into agent prompts so Gemini can see full PnP properties, signed-driver data, and `pnputil` output instead of only a few summary strings.
- Changed the pre-Gemini discovery query to use raw local evidence fields (`FriendlyName`, `InstanceId`, `HardwareId`, `CompatibleId`, `Service`, and installed `INF`) instead of short generic search phrases.
- Reduced Agent tree noise by hiding local/web snippet rows during agentic runs; observable tool activity remains available in the details pane and JSONL trace.

## [0.1.9] - 2026-05-31

### Added
- Added dynamic model configuration by loading free-tier Gemini and Gemma models from `data/google-ai-studio-rate-limits-only free.csv`.
- Added Gemma 4 models (`gemma-4-26b-a4b-it` and `gemma-4-31b-it`) to the available model list.
- Added interactive TUI Model Selector (`Invoke-ModelSelector` triggered by pressing `M`/`m`) to select which models are active for lookup.
- Added parallel background execution for multiple active models concurrently, scaling dynamically to any number of selected models.
- Added `M = models` footer shortcuts and polling key handlers.
- Updated tree highlighting and legacy stacked rendering to color OpenRouter models green (`$_C.OK`) and Gemini models blue (`$_C.Info`).

### Fixed
- Fixed TUI freeze caused by inactive models (State = 'None') keeping the pending model count permanently above zero.
- Fixed strict mode exception (`The property 'Key' cannot be found on this object`) in `Read-ConsoleKey` by wrapping properties extraction and ensuring a valid object is always returned.
- Fixed model selection persistence across sessions by automatically saving selections to `config.json` in `LocalApplicationData` and restoring them upon startup.
- Fixed potential strict-mode exceptions by adding null-checks for runspace EndInvoke outputs.
- Prevented silent infinite loop hangs by rethrowing unexpected exceptions in Read-ConsoleKey instead of swallowing them.
- Fixed strict-mode exception on pending models count query by wrapping it in an array subexpression `@(...)` to safely evaluate `.Count`.
- Added robust null and property existence guards to all loop `switch ($key.Key)` invocations to prevent strict-mode crashes when key objects are null.

## [0.1.8] - 2026-05-30

### Added
- Added responsive dual-pane rendering for wide terminals, with the Device Manager-style tree on the left and selected details/evidence on the right.
- Added ANSI-aware truncation/padding helpers so status lines and panes stay inside the header width instead of overflowing horizontally.
- Added a live evidence-scan progress line showing completed, active, queued, and elapsed work for root/category batch scans.
- Added Device Manager-style `+` and `-` expand/collapse shortcuts; on the computer root they expand/collapse every category.
- Added root-level `E` evidence scans so pressing `E` on the computer root scans all present devices locally.
- Added category-level `E` evidence scans so pressing `E` on a group scans all devices in that group locally.
- Added `R` system scan and `E` selected-device evidence scan hotkeys, keeping `S` for selected-device evidence refresh plus web/AI lookup.
- Added visible running/complete status for `R` system scans, including present-device/category counts and elapsed milliseconds.
- Added a Device Manager-style computer root row using the Windows system name.
- Added Device Manager-style category display names while preserving internal PnP class keys for logic.
- Added a human-readable system summary from System Information fields instead of showing the cache/database machine hash in the header.
- Added an always-visible selected-device evidence summary in the details panel when cached evidence exists.
- Added a stable machine evidence ID and selected-device JSON evidence cache under `%LOCALAPPDATA%\DeviceCheck\machines\<machineId>\devices\`.
- Added local evidence collection for selected devices, including PnP properties, signed driver data, and `pnputil /enum-devices /ids /relations /drivers` output.
- Included local machine/device evidence in the Gemini/OpenRouter prompt before web snippets so AI summaries are grounded in local facts first.
- Display all collected DuckDuckGo web snippets in the TUI as numbered evidence rows instead of showing only the first snippet.
- Added canonical CSV and Markdown extracts for the Google AI Studio free-tier RPM/TPM/RPD limit data.
- Documented the snapshot in `PROJECT_RULES.md`, including the distinction between text-out model quotas and tool-specific grounding quotas.
- Added a repository `.gitattributes` file to keep PowerShell, Markdown, JSON, and YAML files on LF line endings while preserving CRLF for Windows launcher/integration files.

### Changed
- Throttled root/category evidence scans to a small queued batch instead of starting every device runspace at once.
- Optimized root/category evidence counters to use in-memory cache flags instead of filesystem checks on every render.

### Fixed
- Fixed selected-device detail rendering when cached evidence is missing optional properties such as `DEVPKEY_Device_Service`.
- Balanced wide dual-pane rendering so the device tree and details pane split the terminal width near the middle.
- Removed evidence-cache status/path rows from the left device tree; selected-device evidence state now stays in the details pane.
- Fixed category-level evidence scans crashing under `Set-StrictMode` when a category has no optional `DisplayName` property.
- Fixed completed evidence batch progress staying visible and continuing to increase elapsed time after all devices finished.

## [0.1.7] - 2026-05-30

### Changed
- Switched default Google Gemini model from `gemini-3.5-flash` to `gemini-3.1-flash-lite` during quota testing, with quota interpretation documented in `PROJECT_RULES.md` because tool-specific grounding quotas are separate from normal text-out `generateContent` quotas.

## [0.1.6] - 2026-05-30

### Changed
- Updated the default Google Gemini model from `gemini-2.5-flash` to the newly released `gemini-3.5-flash` for better reasoning and performance in device information extraction.

## [0.1.5] - 2026-05-30

### Fixed
- Fixed runspace processing loop syntax error in `Update-ActiveSearches` which caused parser failures.
- Redesigned search result layout to print the model header and elapsed time on one line (colored in the model's theme color: Blue for Gemini, Green for OpenRouter/Nvidia), and the synthesized result text on a new indented line (in white).

## [0.1.4] - 2026-05-30

### Added
- Rewrote the device lookup pipeline to be completely asynchronous and non-blocking. The user can now navigate the connection tree, inspect other devices, and select results while a search is running.
- Added an elapsed time counter (e.g. `(Searching... / 4s)`) next to all active spinner rows.
- Implemented search toggling: pressing `S` on a searching device or any of its sub-rows cancels the active search immediately and stops the runspaces.

## [0.1.3] - 2026-05-30

### Added
- Modified Gemini and OpenRouter searches to run concurrently using separate PowerShell Runspaces instead of sequentially.
- Implemented individual real-time spinners in the TUI tree for each model request.
- Added dynamic model tags showing model names (`gemini-2.5-flash` and `nvidia/nemotron-3-super-120b-a12b:free`).
- Applied custom color highlights for model tags (Blue for Google Gemini, Green for Nvidia models).

### Fixed
- Fixed background thread deadlock and TUI frame corruption by setting `$ProgressPreference = 'SilentlyContinue'` in all background runspaces.
- Prevented Internet Explorer initialization hangs in PowerShell 5.1 by adding `-UseBasicParsing` to background web requests.
- Prevented potential loop freeze by wrapping runspace `Dispose()` and `Stop()` calls in `try/catch` and ensuring variable references are safely nullified.

## [0.1.2] - 2026-05-30

### Added
- Added OpenRouter API integration to run side-by-side with the primary Google Gemini API. If both `GOOGLE_API_KEY` (or `GEMINI_API_KEY`) and `OPENROUTER_API_KEY` are present, the script queries both APIs sequentially, displays both summaries in the TUI tree under `[Gemini AI]` and `[OpenRouter AI]`, and provides distinct error reporting for each path.

## [0.1.1] - 2026-05-29

### Fixed
- Fixed spinner animation not displaying during async database/web lookup due to variable scoping issues.
- Fixed HttpClient.Timeout error when querying Gemini API by increasing the timeout from 10 seconds to 30 seconds.
- Increased DuckDuckGo search query timeout to 15 seconds to ensure web snippets are collected reliably.

## [0.1.0] - 2026-05-29

### Added
- Initialize project directory and git repository.
- Copy `PS_UI_Blueprint.psm1` for responsive, flicker-free rendering.
- Setup `README.md` and `CHANGELOG.md`.
- Plan implementation of the interactive device category tree navigation.
