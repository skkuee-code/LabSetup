#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$SourcePath = (Split-Path -Path $PSScriptRoot -Parent),
    [string]$DestinationPath = 'C:\ProgramData\LabSetup',
    [string[]]$ExcludeDirectories = @('.git', '.github', 'cache', 'logs', 'Documents and Settings'),
    [string[]]$ExcludeFiles = @(
        'NTUSER.DAT',
        'NTUSER.DAT.LOG1',
        'NTUSER.DAT.LOG2',
        'NTUSER.INI',
        'UsrClass.dat',
        'UsrClass.dat.LOG1',
        'UsrClass.dat.LOG2'
    ),
    [switch]$Mirror,
    [switch]$SkipAcl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonModule = Join-Path -Path $PSScriptRoot -ChildPath 'LabSetup.Common.psm1'
Import-Module -Name $commonModule -Force

Confirm-LabAdministrator

$resolvedSource = (Resolve-Path -Path $SourcePath).ProviderPath
$userProfile = [Environment]::GetFolderPath('UserProfile')
if ($resolvedSource -ieq $userProfile) {
    throw 'The SourcePath resolved to the entire user profile. Specify the LabSetup directory explicitly (e.g. C:\Users\<user>\Documents\LabSetup).'
}

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
    '/XJ'
)

if ($Mirror) {
    $robocopyArgs += '/MIR'
}

$normalizedExcludeDirs = @($ExcludeDirectories | Where-Object { $_ })
if ($normalizedExcludeDirs.Count -gt 0) {
    $robocopyArgs += '/XD'
    $robocopyArgs += $normalizedExcludeDirs
}

$normalizedExcludeFiles = @($ExcludeFiles | Where-Object { $_ })
if ($normalizedExcludeFiles.Count -gt 0) {
    $robocopyArgs += '/XF'
    $robocopyArgs += $normalizedExcludeFiles
}

$null = & 'robocopy.exe' @robocopyArgs
$exitCode = $LASTEXITCODE
if ($exitCode -gt 7) {
    throw "robocopy failed with exit code $exitCode."
}

if (-not $SkipAcl) {
    Write-Host 'Applying ACL: Administrators=Full, Users=Read+Execute ...' -ForegroundColor Cyan
    icacls $DestinationPath /inheritance:r | Out-Null
    icacls $DestinationPath /grant 'BUILTIN\Administrators:(OI)(CI)F' 'BUILTIN\Users:(OI)(CI)RX' | Out-Null
}

Write-Host 'Deployment complete.' -ForegroundColor Green
