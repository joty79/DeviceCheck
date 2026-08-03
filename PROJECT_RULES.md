# DeviceCheck Current Project Contract

This file describes the project as it works now. Completed incidents, old validation transcripts, and superseded decisions are preserved verbatim in `project-history/PROJECT_RULES-legacy-2026-01-30-to-2026-07-28.md`; retrieve them by date, filename, error text, or feature keyword instead of treating them as active instructions.

## Scope and architecture

- `DeviceCheck.ps1` is the PowerShell 5.1-compatible interactive entrypoint. It verifies and loads the pinned TUI runtime, imports the pinned WinRM modules, initializes shared script state, and dot-sources the ordered files under `internal\DeviceCheck`.
- Keep the entrypoint thin. Screen state, inventory, target selection, connection flow, rendering, and input stay in the existing numbered internal parts. `internal\Test-DeviceCheckStructure.ps1` enforces parsing, ordering, and line budgets.
- Preserve local/customer evidence and dirty working-tree changes. Do not run a customer remote scan, authentication attempt, remediation, reboot, or service interruption unless the user explicitly puts that live target in scope.

## Canonical reusable owners

- `.agent-shared\templates\PS_UI_Blueprint.psm1` owns reusable TUI mechanics. DeviceCheck vendors exact bytes as `PS_UI_Blueprint.psm1` plus `PS_UI_Blueprint.sha256`; project-specific primary-buffer selection and screen layouts remain local.
- `.agent-shared\modules\WinRMDiscovery` owns LAN discovery, network identity, history, TTL-bound discovery snapshots, target catalogs, and saved-target address validation. DeviceCheck imports only `.assets\WinRMDiscovery\WinRMDiscovery.psd1`.
- `.agent-shared\modules\WinRMConnection` owns bounded authenticated sessions, status events, retry/error classification, blank-password credentials, and DPAPI credential profiles. DeviceCheck imports only `.assets\WinRMConnection\WinRMConnection.psd1`.
- `.agent-shared\modules\WinRMWorkshop` owns exact-target client `TrustedHosts` preparation and readback verification. DeviceCheck imports only `.assets\WinRMWorkshop\WinRMWorkshop.psd1`.
- Vendored WinRM/TUI files are generated artifacts. Update them through the canonical sync scripts; never patch their consumer copies directly.

## WinRM target and connection flow

- `Ctrl+L` must show its first selector frame from local state only. `Get-WinRMTargetCatalog` merges network-scoped successful history with a fresh cached discovery snapshot without DNS, TCP, WinRM, credential, or bulk history validation work.
- Show saved rows as `Not checked`. Validate only the selected saved row with `Resolve-WinRMHistoryTargetAddress` before authentication.
- LAN discovery is explicit through `Scan network now` or `R`. Call `Find-WinRMComputer` with the current `NetworkId`; a completed scan refreshes the short-lived sanitized snapshot but does not promote a PC into successful history.
- Keep offline snapshot-library loading lazy. Opening the first target selector must not scan the LAN or enumerate the full offline evidence corpus.
- Target selection authorizes preparation of that one exact target. Call `Add-WinRMWorkshopTrustedHost -ComputerName <target>` and surface its status events. Never add `*`, a subnet wildcard, or a comma-separated target. Preserve existing exact entries; legacy `*` is narrowed to the selected exact target by the canonical module.
- Use `Connect-WinRMSession` with visible bounded status. Retry only transient session-opening failures, reuse one successful `PSSession` for the snapshot batch, never retry the remote collector block automatically, and always remove the session in `finally`.
- Load DPAPI credentials through `Get-WinRMCredentialProfile`. Save through `Save-WinRMCredentialProfile` only after authentication succeeds. Remove a cached profile only after `AuthenticationRejected`, not after TCP/timeout/transport failures. Never persist plaintext passwords.
- Discovery, client preparation, authentication, and target-side remediation remain separate. `Enable-RemotePs.ps1` is the explicit target-side workshop setup/cleanup workflow.

## Workshop security boundary

- The supported convenience profile is for a controlled workshop LAN, not a public, shared, or hostile network.
- Workgroup/IP connections may use WinRM HTTP/5985 plus NTLM and exact `TrustedHosts`. Authenticated WinRM traffic is encrypted, but this does not provide certificate-backed server identity.
- Blank-password local administrators, Private-network selection, firewall enablement, and `LocalAccountTokenFilterPolicy` are explicit target-side convenience relaxations and may persist. Do not claim automatic target rollback without a tested state-receipted restore flow.
- Do not repeat this warning as a per-connection prompt; keep it visible once in the README and preserve fast explicit target selection.

## PowerShell and TUI constraints

- Preserve Windows PowerShell 5.1 compatibility for user-facing scripts and WinRM endpoints. Use the global PowerShell workflow for parser/runtime validation and the global TUI workflow for interactive changes.
- In background runspaces set `$ProgressPreference = 'SilentlyContinue'`; keep cleanup in `try/finally` or guarded `try/catch` and dispose runspaces/sessions deterministically.
- DeviceCheck intentionally defaults its long-lived dashboard to the primary buffer through the thin script-scoped adapter unless the caller explicitly sets `POWERSHELL_TUI_PRIMARY_BUFFER`.
- Full-frame UI changes must pass the sequential VT resize replay `120 -> 101 -> 100 -> 99 -> 98 -> 80 -> 60 -> 120`, with no wrapping, viewport scroll, duplicate header/footer, stale rows, or out-of-bounds output.
- API keys come only from `GOOGLE_API_KEY`, `GEMINI_API_KEY`, and `OPENROUTER_API_KEY`. Do not store secrets in the repository, discovery snapshots, diagnostics, history, or test fixtures.

## Evidence and driver domains

- Keep hardware evidence collection, source provenance, recommendation policy, and package topology in their existing modules and canonical domain documents. Do not move those details into this current-rules file.
- Primary retrieval owners include `docs\DRIVER_EVIDENCE_DECISION_MODEL.md`, `docs\DRIVER_PACKAGE_ADVISOR.md`, `docs\WINDOWS_DRIVER_SOURCE_COMPARISON_CONTRACT.md`, `docs\LOCAL_HARDWARE_IDENTITY_DATABASE_PLAN.md`, and the executable fixtures/tests under `internal` and `tests`.
- Preserve the separation between local evidence, observed Windows Update/Catalog evidence, OEM packages, SDIO evidence, recommendation logic, and UI rendering. Tests and schemas are stronger contracts than old diary prose.

## Verification contract

- After changing PowerShell, run the global `tools\Test-PowerShellSyntax.ps1` against every changed `.ps1`, `.psm1`, and `.psd1` file.
- Run focused tests for the changed subsystem, then `internal\Test-DeviceCheckStructure.ps1` as the full project parser/structure gate.
- For WinRM changes run the canonical module offline tests, DeviceCheck target-catalog/connection/workshop integration tests, and each canonical sync script with `-ConsumerRoot <repo> -VerifyOnly`.
- For TUI changes run `internal\Test-DeviceCheckOfflineMenu.ps1` in PowerShell 7 and Windows PowerShell 5.1 with the resolved working Python runtime, plus the shared TUI verification required by its canonical owner.
- Run `git diff --check` and inspect `git ls-files --eol` for changed files. Parser/static checks are not proof of elevated, live remote, or pixel-level behavior.

## Targeted history retrieval

- Search the exact legacy archive with `rg -n "<date|error|filename|feature>" project-history\PROJECT_RULES-legacy-2026-01-30-to-2026-07-28.md`.
- Use `CHANGELOG.md` only for shipped/user-visible history and inspect only its current section or a targeted version.
- Promote an old guardrail back into this file only when it is still current, cross-cutting, and not already owned by code, tests, a domain document, a canonical shared module, or a global workflow.
