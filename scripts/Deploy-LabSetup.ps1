#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$SourcePath = (Split-Path -Path $PSScriptRoot -Parent),
    [string]$DestinationPath = 'C:\ProgramData\LabSetup',
    [switch]$Mirror,
    [switch]$SkipAcl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonModule = Join-Path -Path $PSScriptRoot -ChildPath 'LabSetup.Common.psm1'
Import-Module -Name $commonModule -Force

Confirm-LabAdministrator

$resolvedSource = Resolve-Path -Path $SourcePath
Write-Host "Deploying LabSetup from $resolvedSource to $DestinationPath ..." -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
}

$robocopyArgs = @(
    $resolvedSource,
    $DestinationPath,
    '/E',
    '/COPY:DAT',
    '/R:2',
    '/W:5',
    '/NFL',
    '/NDL',
    '/NJH',
    '/NJS',
    '/NP',
    '/XD', '.git', '.github', 'cache', 'logs'
)

if ($Mirror) {
    $robocopyArgs += '/MIR'
}

$robocopy = Start-Process -FilePath 'robocopy.exe' -ArgumentList $robocopyArgs -Wait -PassThru
if ($robocopy.ExitCode -gt 7) {
    throw "robocopy failed with exit code $($robocopy.ExitCode)."
}

if (-not $SkipAcl) {
    Write-Host 'Applying ACL: Administrators=Full, Users=Read+Execute ...' -ForegroundColor Cyan
    icacls $DestinationPath /inheritance:r | Out-Null
    icacls $DestinationPath /grant 'BUILTIN\Administrators:(OI)(CI)F' 'BUILTIN\Users:(OI)(CI)RX' | Out-Null
}

Write-Host 'Deployment complete.' -ForegroundColor Green
