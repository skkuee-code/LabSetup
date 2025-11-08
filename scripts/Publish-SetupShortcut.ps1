#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'config\lab-setup-config.json'),
    [string]$ShortcutName,
    [string]$DesktopPath = 'C:\Users\Public\Desktop',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonModule = Join-Path -Path $PSScriptRoot -ChildPath 'LabSetup.Common.psm1'
Import-Module -Name $commonModule -Force

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
        Import-Module -Name $ModulePath -Force -ErrorAction Stop | Out-Null
    }
    catch {
        $errorMessage = $_.Exception.Message
        throw "Failed to import LabSetup.Common from $displayLocation ($ModulePath): $errorMessage"
    }
    finally {
        Remove-Module -Name 'LabSetup.Common' -Force -ErrorAction SilentlyContinue
    }

    if ($RestoreModulePath) {
        Import-Module -Name $RestoreModulePath -Force -ErrorAction Stop | Out-Null
    }
}

Confirm-LabAdministrator

$config = Get-LabSetupConfig -ConfigPath $ConfigPath
$shortcutLabel = if ($ShortcutName) { $ShortcutName } elseif ($config.publicDesktopShortcutName) { $config.publicDesktopShortcutName } else { 'Lab Setup.lnk' }

if (-not (Test-Path -LiteralPath $DesktopPath -PathType Container)) {
    throw "Desktop path not found: $DesktopPath"
}

$targetScript = Join-Path -Path $config.programDataPath -ChildPath $config.setupScriptPath
if (-not (Test-Path -LiteralPath $targetScript -PathType Leaf)) {
    throw "Setup script not found at $targetScript. Deploy the repository first."
}

$programDataModule = Join-Path -Path $config.programDataPath -ChildPath 'scripts\LabSetup.Common.psm1'
Write-Host 'Validating LabSetup module in ProgramData mirror...' -ForegroundColor Cyan
Test-LabSetupModuleAvailability -ModulePath $programDataModule -RestoreModulePath $commonModule -FriendlyLocation $config.programDataPath

$shortcutPath = Join-Path -Path $DesktopPath -ChildPath $shortcutLabel
if ((Test-Path -LiteralPath $shortcutPath) -and $Force) {
    Remove-Item -LiteralPath $shortcutPath -Force
}

$shell = New-Object -ComObject WScript.Shell
try {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$targetScript`""
    $shortcut.WorkingDirectory = $config.programDataPath
    $shortcut.IconLocation = 'powershell.exe,0'
    $shortcut.Description = 'Provision shared lab workstation software and toolchains.'
    $shortcut.Save()
}
finally {
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}

Write-Host "Shortcut created at $shortcutPath" -ForegroundColor Green
