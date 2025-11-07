#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'config\lab-setup-config.json'),
    [switch]$SkipTaskbarPins,
    [switch]$SkipVolta,
    [switch]$SkipUv,
    [switch]$SkipTeX,
    [switch]$SkipGitLfs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonModule = Join-Path -Path $PSScriptRoot -ChildPath 'LabSetup.Common.psm1'
Import-Module -Name $commonModule -Force

Confirm-LabAdministrator

$config = Get-LabSetupConfig -ConfigPath $ConfigPath
$logPath = Get-LabLogPath -Config $config
$logWriter = [System.IO.StreamWriter]::new($logPath, $true)

try {
    Write-LabLog -Message 'Starting lab machine provisioning.' -LogWriter $logWriter

    Install-LabPackages -Config $config -LogWriter $logWriter

    if (-not $SkipVolta) {
        Set-VoltaToolchain -Config $config -LogWriter $logWriter
    } else {
        Write-LabLog -Message 'Skipping Volta setup (requested).' -LogWriter $logWriter
    }

    if (-not $SkipUv) {
        Set-UvToolchain -Config $config -LogWriter $logWriter
    } else {
        Write-LabLog -Message 'Skipping uv setup (requested).' -LogWriter $logWriter
    }

    if (-not $SkipGitLfs -and $config.git.configureLfs) {
        Set-GitLfsConfiguration -LogWriter $logWriter
    } elseif ($SkipGitLfs) {
        Write-LabLog -Message 'Skipping Git LFS configuration (requested).' -LogWriter $logWriter
    }

    if (-not $SkipTeX) {
        Set-MikTexConfiguration -Config $config -LogWriter $logWriter
    } else {
        Write-LabLog -Message 'Skipping TeX post-configuration (requested).' -LogWriter $logWriter
    }

    if (-not $SkipTaskbarPins) {
        Set-LabTaskbarPins -Config $config
    } else {
        Write-LabLog -Message 'Skipping taskbar pinning (requested).' -LogWriter $logWriter
    }

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath) {
        $env:Path = $machinePath
    }

    Write-LabLog -Message 'Lab machine provisioning completed successfully.' -LogWriter $logWriter
    Write-Host "Setup completed. Log file: $logPath" -ForegroundColor Green
}
catch {
    $message = "Setup failed: $($_.Exception.Message)"
    Write-LabLog -Message $message -LogWriter $logWriter
    throw
}
finally {
    $logWriter.Dispose()
}
