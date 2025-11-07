#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$SkipTaskbarPins,
    [switch]$SkipVolta,
    [switch]$SkipUv,
    [switch]$SkipTeX,
    [switch]$SkipGitLfs
)

$scriptRoot = if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
    $PSScriptRoot
} else {
    $invocationPath = $null

    if ($null -ne $MyInvocation -and
        $null -ne $MyInvocation.MyCommand -and
        -not [string]::IsNullOrEmpty($MyInvocation.MyCommand.Path)) {
        # Windows PowerShell 5.1 lacks null-conditional operators, so resolve the path explicitly.
        $invocationPath = $MyInvocation.MyCommand.Path
    }

    if ($invocationPath) {
        Split-Path -Path $invocationPath -Parent
    } else {
        (Get-Location).ProviderPath
    }
}

$repoRoot = Split-Path -Path $scriptRoot -Parent

if (-not $ConfigPath) {
    $ConfigPath = Join-Path -Path $repoRoot -ChildPath 'config\lab-setup-config.json'
}

$consoleUtf8 = [System.Text.UTF8Encoding]::new($false)
try {
    if ($null -ne [Console]::OutputEncoding -and [Console]::OutputEncoding.CodePage -ne $consoleUtf8.CodePage) {
        [Console]::OutputEncoding = $consoleUtf8
    }
    if ($null -ne [Console]::InputEncoding -and [Console]::InputEncoding.CodePage -ne $consoleUtf8.CodePage) {
        [Console]::InputEncoding = $consoleUtf8
    }
}
catch {
    # Some hosts (for example, remoting) do not allow encoding changes; ignore and continue.
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonModule = Join-Path -Path $scriptRoot -ChildPath 'LabSetup.Common.psm1'
Import-Module -Name $commonModule -Force

Confirm-LabAdministrator

$config = Get-LabSetupConfig -ConfigPath $ConfigPath
$logPath = Get-LabLogPath -Config $config
$utf8WithBom = [System.Text.UTF8Encoding]::new($true) # Prevent Shift-JIS viewers from misreading log files.
$logWriter = [System.IO.StreamWriter]::new($logPath, $true, $utf8WithBom)

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
        Set-LabTaskbarPins -Config $config -LogWriter $logWriter
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
