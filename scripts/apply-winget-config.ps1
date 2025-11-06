#Requires -RunAsAdministrator
<#
.SYNOPSIS
  WinGet Configuration (DSC) を適用します。冪等です。
#>
[CmdletBinding()]
param(
  [string]$ConfigPath,
  [string]$LogDir = "C:\ProgramData\LabSetup\logs"
)

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $RepoRoot 'config\lab-dev.uv-volta-quarto.winget.yaml'
}

if (-not (Test-Path $ConfigPath)) {
  throw "Config file not found: $ConfigPath"
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile   = Join-Path $LogDir "winget-config-$timestamp.log"

Start-Transcript -Path $logFile -Append

Write-Host "Updating winget sources..." -ForegroundColor Cyan
winget source update

Write-Host "Applying configuration: $ConfigPath" -ForegroundColor Cyan
winget configure -f $ConfigPath `
  --suppress-initial-details `
  --disable-interactivity `
  --accept-configuration-agreements

Stop-Transcript

if ($LASTEXITCODE -ne 0) {
  throw "winget configure failed with exit code $LASTEXITCODE. See: $logFile"
}
Write-Host "winget configuration completed. Log: $logFile" -ForegroundColor Green