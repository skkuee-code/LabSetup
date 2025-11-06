#Requires -RunAsAdministrator
<#
.SYNOPSIS
  リポジトリ一式を C:\ProgramData\LabSetup に配備し、最低限の ACL を設定します。
#>
[CmdletBinding()]
param(
  [string]$Destination = 'C:\ProgramData\LabSetup',
  [switch]$SetAcl = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Source = Split-Path -Path $PSScriptRoot -Parent
Write-Host "Deploying from '$Source' to '$Destination' ..." -ForegroundColor Cyan

New-Item -ItemType Directory -Path $Destination -Force | Out-Null

# 除外フォルダ
$excludeDirs = @('.git', '.github', '.venv', 'logs')
Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
  if ($excludeDirs -contains $_.Name) { return }
  Copy-Item -Path $_.FullName -Destination $Destination -Recurse -Force
}

if ($SetAcl) {
  Write-Host "Setting ACL (Admins: Full, Users: Read&Execute) ..." -ForegroundColor Cyan
  icacls $Destination /inheritance:r | Out-Null
  icacls $Destination /grant "BUILTIN\Administrators:(OI)(CI)F" "BUILTIN\Users:(OI)(CI)RX" | Out-Null
}

Write-Host "Deployed to $Destination" -ForegroundColor Green
