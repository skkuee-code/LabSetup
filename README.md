# LabSetup Windows Provisioning Toolkit

LabSetup streamlines classroom and lab PCs by automating machine-scope application deployment, common development toolchains, and TeX publishing prerequisites. The repo now focuses on three scripted stages:

1. Deploy this repository to `C:\ProgramData\LabSetup` for a managed copy.
2. Publish a "Lab Setup" shortcut for every user's desktop.
3. Run the consolidated machine bootstrap that installs, pins, and configures everything.

---

## Repository Layout

```
.
+-- config/
|   \-- lab-setup-config.json        # Package metadata + taskbar pin targets
+-- scripts/
|   +-- Deploy-LabSetup.ps1          # Mirror repo into ProgramData (admin)
|   +-- Publish-SetupShortcut.ps1    # Create the Lab Setup desktop shortcut (admin)
|   +-- Setup-LabMachine.ps1         # Install apps/toolchains, pin taskbar, log output (admin)
|   \-- LabSetup.Common.psm1         # Shared module with winget + taskbar helpers
\-- README.md
```

All scripts preserve four-space indentation, approved verbs, and run in place before you copy to `C:\ProgramData\LabSetup` for production mirroring.

---

## Prerequisites

- Windows 11 22H2 or later with the Windows Package Manager (winget) available.
- Administrative PowerShell session with internet access to reach Microsoft and vendor feeds.
- Permission to write to `C:\ProgramData` and `C:\Users\Public\Desktop`.

---

## End-to-End Workflow

1. **Deploy the managed copy (administrator)**
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   .\scripts\Deploy-LabSetup.ps1 -SourcePath (Get-Location) -DestinationPath 'C:\ProgramData\LabSetup' -Mirror
   ```
   - Uses `robocopy` to mirror the repository while excluding `.git`, `.github`, `logs`, and `cache` directories.
   - Sets ACLs so Administrators have Full Control and Users have Read & Execute.

2. **Publish the desktop shortcut (administrator)**
   ```powershell
   C:\ProgramData\LabSetup\scripts\Publish-SetupShortcut.ps1 -Force
   ```
   - Creates `C:\Users\Public\Desktop\Lab Setup.lnk`, pointing to `Setup-LabMachine.ps1` with execution policy bypass.

3. **Provision the workstation (administrator)**
   ```powershell
   C:\ProgramData\LabSetup\scripts\Setup-LabMachine.ps1
   ```
   - Installs Slack, Visual Studio Code, Google Chrome, LTspice, Git, Git LFS, Quarto, and MiKTeX with `winget install --scope machine` so packages land under Program Files.citeturn0search2
   - Downloads and installs LayoutEditor from the vendor MSI because it is not published in the community winget feed.citeturn4search0turn4search1
   - Configures uv-managed Python (`uv python install 3.12`) and sets `UV_PYTHON_INSTALL_DIR` under ProgramData for a shared interpreter.citeturn1search0
   - Sets Volta's toolchain location inside ProgramData, installs Node LTS, and adds global TypeScript via `volta install`.citeturn2search0turn2search4
   - Enables MiKTeX automatic package installs and refreshes the filename database with `initexmf --admin` commands.citeturn3search0
   - Pins Slack, VS Code, Chrome, LTspice, and LayoutEditor to the taskbar after verifying executable paths.
   - Streams console output to `C:\ProgramData\LabSetup\logs\LabSetup_yyyyMMdd_HHmmss.log`.

Each step is idempotent—rerun the machine setup script whenever `config\lab-setup-config.json` changes.

---

## What `Setup-LabMachine.ps1` Covers

| Phase | Details |
| --- | --- |
| **Package install** | Iterates `wingetPackages` entries, calling winget with `--scope machine --accept-package-agreements --accept-source-agreements`. Manual installers (currently LayoutEditor MSI) are cached in `ProgramData\LabSetup\cache`.citeturn0search2turn4search0 |
| **Taskbar pinning** | Uses Shell COM verbs (`taskbarpin`) with configurable retries defined in the config file.
| **Volta toolchain** | Sets `VOLTA_HOME`, creates `bin`, adds it to PATH, installs Node LTS and TypeScript via Volta.citeturn2search0turn2search4 |
| **uv toolchain** | Sets `UV_HOME`, `UV_PYTHON_INSTALL_DIR`, adds `bin` to PATH, and installs Python 3.12 through uv.citeturn1search0 |
| **Git + LFS** | Runs `git lfs install --system` after winget installs Git and Git LFS.
| **TeX provisioning** | Executes `initexmf --admin --set-config-value [MPM]AutoInstall=1` and `initexmf --admin --update-fndb` for MiKTeX.citeturn3search0 |
| **Logging** | Every action is logged under `ProgramData\LabSetup\logs` alongside stdout.

---

## Configuration Reference (`config\lab-setup-config.json`)

- `wingetPackages`: Array of objects with `id`, `displayName`, optional `version`, and `pinToTaskbar`. Entries that include an `installer` block run the custom installer workflow (used for LayoutEditor).citeturn4search0turn4search1
- `volta`: Desired Node release (`nodeVersion`) plus any global packages to install via Volta.citeturn2search0turn2search4
- `uv`: Python versions to provision; each is installed with `uv python install` and shared via ProgramData.citeturn1search0
- `git`: Toggle `configureLfs` to run `git lfs install --system`.
- `tex`: Flags for MiKTeX automation (`autoInstallMissingPackages`, `refreshFileDatabase`).citeturn3search0
- `taskbar`: Retry count and delay (seconds) for pinning operations.

Update the JSON file when bumping versions or adding software, then rerun `Setup-LabMachine.ps1` to apply the changes.

---

## Verification Checklist

1. **winget**
   ```powershell
   winget list --scope machine --id SlackTechnologies.Slack
   winget list --scope machine --id Microsoft.VisualStudioCode
   ```
2. **Volta/TypeScript**
   ```powershell
   $env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine')
   node --version
   tsc --version
   ```
3. **uv/Python**
   ```powershell
   uv python list
   python --version
   ```
4. **TeX**
   ```powershell
   initexmf --admin --report | Select-String AutoInstall
   quarto check
   ```
5. **Desktop experience**
   - Confirm taskbar pins exist and launch for a standard user profile.
   - Validate `C:\ProgramData\LabSetup\logs` contains the latest run log.

---

## Maintenance Tips

- **Package updates**: Edit `lab-setup-config.json` and rerun `Setup-LabMachine.ps1`. For LayoutEditor, update the MSI download URL from the vendor portal.citeturn4search1
- **Additional software**: Add another object to `wingetPackages`; ensure the manifest supports machine scope before committing the change.citeturn0search2
- **Shortcut customisation**: Use `Publish-SetupShortcut.ps1 -ShortcutName 'Robotics Setup.lnk'` for lab-specific names.
- **Cache/log hygiene**: Purge `ProgramData\LabSetup\cache` and `logs` periodically if disk space is constrained.

---

## Troubleshooting

- **winget errors about scope**: Some manifests do not support machine installations—verify support before adding new packages.citeturn0search2turn0search3
- **Taskbar pins missing**: Rerun `Setup-LabMachine.ps1 -SkipVolta -SkipUv -SkipTeX -SkipGitLfs` to focus on the pinning phase after Explorer finishes creating shortcuts.
- **uv not on PATH**: Reload the machine PATH in the current session (`$env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine')`) or reboot to inherit environment changes.
- **MiKTeX prompts for packages**: Rerun `Setup-LabMachine.ps1` or execute the `initexmf --admin` commands manually to re-enable AutoInstall.citeturn3search0
- **LayoutEditor update required**: Replace the MSI URL in the config; the script downloads the new build to the cache and reinstalls via `msiexec`.citeturn4search0turn4search1

---

## Roadmap Ideas

- Add a scheduled task wrapper around `winget upgrade --all --scope machine --silent` for background patching.
- Extend the config with additional engineering software (e.g., KiCad, Fusion 360) once machine-scope manifests are confirmed.
- Export `Setup-LabMachine.ps1` into imaging/MDT pipelines to pre-provision classrooms at scale.

With these changes, lab admins run three commands and receive a consistent, ready-to-teach Windows environment that covers communication, coding, simulation, and publishing toolchains.
