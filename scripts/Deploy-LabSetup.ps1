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
Import-Module -Name $commonModule -Force -Verbose:$false

function Test-LabSetupModuleAvailability {
    param(
        [Parameter(Mandatory)]
        [string]$ModulePath,
        [string]$RestoreModulePath,
        [string]$FriendlyLocation
    )

    $displayLocation = if ([string]::IsNullOrWhiteSpace($FriendlyLocation)) {
        $ModulePath
    } else {
        $FriendlyLocation
    }

    if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
        throw "LabSetup.Common module not found at $displayLocation."
    }

    $moduleDirectory = Split-Path -Path $ModulePath -Parent
    $segmentDirectory = Join-Path -Path $moduleDirectory -ChildPath 'modules'
    if (-not (Test-Path -LiteralPath $segmentDirectory -PathType Container)) {
        throw "LabSetup module segments directory not found at $segmentDirectory."
    }

    $existingModules = Get-Module -Name 'LabSetup.Common'
    if ($existingModules) {
        foreach ($loaded in $existingModules) {
            Remove-Module -ModuleInfo $loaded -Force
        }
    }

    try {
        Import-Module -Name $ModulePath -Force -ErrorAction Stop -Verbose:$false | Out-Null
    }
    catch {
        $errorMessage = $_.Exception.Message
        throw "Failed to import LabSetup.Common from $displayLocation ($ModulePath): $errorMessage"
    }
    finally {
        Remove-Module -Name 'LabSetup.Common' -Force -ErrorAction SilentlyContinue
    }

    if ($RestoreModulePath) {
        Import-Module -Name $RestoreModulePath -Force -ErrorAction Stop -Verbose:$false | Out-Null
    }
}

Confirm-LabAdministrator

$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$resolvedRepositoryRoot = (Resolve-Path -Path $repositoryRoot).ProviderPath
$resolvedSource = (Resolve-Path -Path $SourcePath).ProviderPath
$userProfile = [Environment]::GetFolderPath('UserProfile')
if ($resolvedSource -ieq $userProfile) {
    $repositoryIsUnderProfile = $resolvedRepositoryRoot.StartsWith($userProfile, [System.StringComparison]::OrdinalIgnoreCase)
    if ($repositoryIsUnderProfile -and $resolvedRepositoryRoot -ne $userProfile) {
        Write-Warning "SourcePath resolved to the entire user profile. Using repository root $resolvedRepositoryRoot instead. Provide -SourcePath explicitly if you intended to mirror the profile."
        $resolvedSource = $resolvedRepositoryRoot
    }
    else {
        throw 'The SourcePath resolved to the entire user profile. Specify the LabSetup directory explicitly (e.g. C:\Users\<user>\Documents\LabSetup).'
    }
}

$repositoryIsUnderSource = $resolvedRepositoryRoot.StartsWith($resolvedSource, [System.StringComparison]::OrdinalIgnoreCase)
if ($repositoryIsUnderSource -and $resolvedRepositoryRoot -ne $resolvedSource) {
    Write-Warning "SourcePath '$resolvedSource' is a parent of the LabSetup repository root '$resolvedRepositoryRoot'. Using the repository root instead to avoid copying unrelated files. Provide -SourcePath explicitly if you intended to mirror the broader directory."
    $resolvedSource = $resolvedRepositoryRoot
}
elseif (-not $resolvedSource.StartsWith($resolvedRepositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The SourcePath '$resolvedSource' is not inside the LabSetup repository root '$resolvedRepositoryRoot'. Specify the LabSetup directory explicitly (e.g. $resolvedRepositoryRoot)."
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

$destinationModulePath = Join-Path -Path $DestinationPath -ChildPath 'scripts\LabSetup.Common.psm1'
Write-Host 'Validating LabSetup module in deployment target...' -ForegroundColor Cyan
Test-LabSetupModuleAvailability -ModulePath $destinationModulePath -RestoreModulePath $commonModule -FriendlyLocation "deployment target ($DestinationPath)"

Write-Host 'Deployment complete.' -ForegroundColor Green
