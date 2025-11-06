# Repository Guidelines

## Project Structure & Module Organization
- `config/lab-dev.uv-volta-quarto.winget.yaml` centralizes WinGet configuration for lab PCs; treat it as the single source of truth for package versions and install order.
- `scripts/*.ps1` contains task-focused PowerShell automation; scripts ending in `-bootstrap` are safe for standard users, while others expect administrator context.
- Deployment mirrors to `C:\ProgramData\LabSetup\` for production use; keep root scripts runnable in place for local dry runs before copying.

## Build, Test, and Development Commands
- `pwsh -ExecutionPolicy Bypass -File scripts/deploy-to-programdata.ps1` prepares the managed copy under `C:\ProgramData\LabSetup`.
- `pwsh -ExecutionPolicy Bypass -File scripts/apply-winget-config.ps1` invokes `winget configure` using the bundled YAML to install and pin required software.
- `pwsh -ExecutionPolicy Bypass -File scripts/register-winget-upgrade-task.ps1` creates the scheduled SYSTEM task that keeps packages patched.
- `pwsh -ExecutionPolicy Bypass -File scripts/user-volta-uv-bootstrap.ps1` provisions per-user Volta and uv environments for day-to-day contributors.

## Coding Style & Naming Conventions
- PowerShell scripts use four-space indentation, PascalCase function names, and approved verb-noun pairs (e.g., `Set-`, `Invoke-`, `Register-`); match the existing patterns when adding cmdlets.
- Prefer parameterized helper functions over inline script blocks; document non-obvious parameters with brief comment headers.
- Keep filenames descriptive and action-oriented (`create-shortcuts.ps1`); align new automation with this naming schema.

## Testing Guidelines
- Run scripts with `-WhatIf` or `-Verbose` before live execution whenever practical to surface configuration drift without side effects.
- After applying `lab-dev` configuration, validate with `winget configure --dry-run --file config/lab-dev.uv-volta-quarto.winget.yaml` and inspect `%ProgramData%\LabSetup\logs\` for scheduled-task output.
- Smoke-test tooling: `quarto check`, `uv --version`, `node -v`, and `tsc -v` confirm the key toolchains that classrooms rely on.

## Commit & Pull Request Guidelines
- Follow Conventional Commits (`feat:`, `fix:`, `chore:`) as seen in `feat: Add initial setup scripts...`; keep summaries under 72 characters and present-tense.
- Reference related tickets with `[#123]` or full URLs in the commit body; detail what changed and why in PR descriptions.
- For PRs, include: impact summary, test evidence (commands run and outcomes), risk/rollback notes, and screenshots when touching user-facing shortcuts or menus.

## Security & Configuration Tips
- Treat credentials and secrets as out-of-band; never embed them in scripts—consume from environment variables or Windows Credential Manager when unavoidable.
- Restrict write access on `C:\ProgramData\LabSetup` to administrators, and audit scheduled tasks after modifications.
- Before upgrading packages, review upstream release notes for VS Code extensions, MiKTeX, and Quarto to avoid lab-wide regressions.
