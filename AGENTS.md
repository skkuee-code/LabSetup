# Repository Guidelines

## Project Structure & Module Organization
Keep this working tree production-ready, then mirror it to `C:\ProgramData\LabSetup` without editing paths. Winget definitions live in `config/lab-dev.uv-volta-quarto.winget.yaml`; treat that file as the single source for package order and versions. Task-specific automation resides in `scripts\`, where `*-bootstrap` scripts are safe for standard users and the rest expect administrator context. Run root scripts locally for dry runs before copying them into the managed ProgramData location.

## Build, Test, and Development Commands
- `pwsh -ExecutionPolicy Bypass -File scripts\deploy-to-programdata.ps1` prepares the managed mirror under `%ProgramData%`.
- `pwsh -ExecutionPolicy Bypass -File scripts\apply-winget-config.ps1` calls `winget configure` using the bundled YAML to install or pin tools.
- `pwsh -ExecutionPolicy Bypass -File scripts\register-winget-upgrade-task.ps1` registers the SYSTEM scheduled task that keeps software patched.
- `pwsh -ExecutionPolicy Bypass -File scripts\user-volta-uv-bootstrap.ps1` provisions Volta and uv for each contributor profile.
Use `-WhatIf` or `-Verbose` switches whenever a script exposes them to surface drift safely.

## Coding Style & Naming Conventions
PowerShell code uses four-space indentation, PascalCase function names, and approved verb-noun cmdlets such as `Set-`, `Invoke-`, and `Register-`. Favor parameterized helper functions over inline script blocks, and add brief comment headers only when parameters are non-obvious. Name new scripts by the action they perform (`create-shortcuts.ps1`, `reset-lab-profiles.ps1`) so they read cleanly in automation menus.

## Testing Guidelines
After editing the configuration, run `winget configure --dry-run --file config/lab-dev.uv-volta-quarto.winget.yaml` to verify intent. Inspect `%ProgramData%\LabSetup\logs\` for scheduled-task output after deployment. Smoke-test the toolchain with `quarto check`, `uv --version`, `node -v`, and `tsc -v`. Default to `-WhatIf` first, then a full run, and capture verbose logs for pull-request evidence.

## Commit & Pull Request Guidelines
Follow Conventional Commits (for example `feat: Add initial setup scripts`) with subjects under 72 characters. Reference related work items via `[#123]` or full URLs in the body. Pull requests must include an impact summary, test evidence with the exact commands run, risk or rollback notes, and screenshots whenever a shortcut, menu, or other user-facing element changes.

## Security & Configuration Tips
Keep credentials out of the repository; load them from environment variables or Windows Credential Manager when absolutely necessary. Restrict write permissions on `C:\ProgramData\LabSetup` to administrators and audit scheduled tasks whenever they change. Review upstream release notes for VS Code extensions, MiKTeX, and Quarto before bumping their versions to prevent lab-wide regressions.
