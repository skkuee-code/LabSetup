# post-miktex-config.ps1
# Enables/disables on-the-fly package install in MiKTeX.
# 0 = Never, 1 = Always, 2 = Ask

[CmdletBinding()]
param(
  [ValidateSet(0,1,2)][int]$AutoInstall = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve initexmf path
$exe = (Get-Command initexmf -ErrorAction SilentlyContinue).Source
if (-not $exe) { throw 'MiKTeX not found. Install MiKTeX first.' }

# Detect whether this MiKTeX is shared (system-wide) or private (per-user).
# initexmf --report contains a line like: "SharedSetup: yes" or "SharedSetup: no"
$report = & $exe --report 2>$null
$shared = $false
if ($LASTEXITCODE -eq 0 -and ($report -match '(?im)^SharedSetup:\s*(yes|true|1)')) { $shared = $true }

# Build config value token: e.g., [MPM]AutoInstall=1
$cfg = ('[MPM]AutoInstall={0}' -f $AutoInstall)

# Helper to run initexmf with optional --admin
function Invoke-Initexmf {
  param([string[]]$Args)
  if ($shared) {
    & $exe --admin @Args
  } else {
    & $exe @Args
  }
  return $LASTEXITCODE
}

# Apply AutoInstall (admin scope only when shared)
if ((Invoke-Initexmf -Args @('--set-config-value', $cfg)) -ne 0) {
  # Fallback: if admin mode failed for any reason, try user mode once
  if ($shared) {
    & $exe --set-config-value $cfg
    if ($LASTEXITCODE -ne 0) { throw "initexmf --set-config-value failed: $LASTEXITCODE" }
  } else {
    throw "initexmf --set-config-value failed: $LASTEXITCODE"
  }
}

# Refresh filename database (FNDB)
if ((Invoke-Initexmf -Args @('--update-fndb')) -ne 0) {
  if ($shared) {
    & $exe --update-fndb
    if ($LASTEXITCODE -ne 0) { throw "initexmf --update-fndb failed: $LASTEXITCODE" }
  } else {
    throw "initexmf --update-fndb failed: $LASTEXITCODE"
  }
}

Write-Host ("MiKTeX AutoInstall={0} configured. Scope={1}" -f $AutoInstall, ($shared ? 'shared/system' : 'user')) -ForegroundColor Green
