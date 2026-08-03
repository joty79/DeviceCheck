# DeviceCheck Agent Router

## Active project context

- Read `PROJECT_RULES.md` for the compact current architecture, safety boundaries, canonical owners, and verification matrix.
- Treat `project-history\` and `CHANGELOG.md` as targeted retrieval sources, not active instructions. Search them by date, filename, feature, or error text; do not load them wholesale.
- Preserve the existing dirty working tree and customer evidence. Never reset, discard, or bulk-rewrite unrelated local changes.

## Workflow routing

- For PowerShell edits or tests, follow the global PowerShell script workflow. For interactive screens, also follow the global TUI workflow and the canonical `.agent-shared` blueprint contract.
- For repository, documentation, or project-memory changes, follow the corresponding global repository/docs/project-memory workflows.
- For LAN targets use the installed `winrm-discovery`, `winrm-connection`, and `winrm-workshop` skills. Import only the pinned manifests under `.assets`; update them through `.agent-shared\scripts\Sync-WinRM*.ps1`.
- Keep discovery, exact-target client preparation, authentication/session lifecycle, and target-side remediation separate.

## Hard safety boundaries

- Do not run a new customer/LAN scan or remote authentication/remediation unless the user explicitly authorizes that live target for the current task.
- Never add wildcard, subnet, or comma-separated `TrustedHosts` values. An explicit selected target authorizes only canonical exact-target preparation for that target.
- Do not treat parser/static/non-admin results as proof of an elevated or live remote outcome.
