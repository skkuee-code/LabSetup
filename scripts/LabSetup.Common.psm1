Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LabSetupModuleSegments = @(
    'modules\LabSetup.Core.psm1',
    'modules\LabSetup.Process.psm1',
    'modules\LabSetup.Winget.psm1',
    'modules\LabSetup.Packages.psm1',
    'modules\LabSetup.Shell.psm1',
    'modules\LabSetup.WindowsTerminal.psm1',
    'modules\LabSetup.TaskbarPins.psm1',
    'modules\LabSetup.TaskbarLayout.psm1',
    'modules\LabSetup.Toolchain.Volta.psm1',
    'modules\LabSetup.Toolchain.Uv.psm1',
    'modules\LabSetup.Toolchain.Git.psm1',
    'modules\LabSetup.Miktex.psm1'
)

$script:ImportedLabSetupModules = @()
foreach ($segment in $script:LabSetupModuleSegments) {
    $segmentPath = Join-Path -Path $PSScriptRoot -ChildPath $segment
    if (-not (Test-Path -LiteralPath $segmentPath -PathType Leaf)) {
        throw "Unable to locate module segment: $segment"
    }

    $module = Import-Module -Name $segmentPath -Scope Local -Force -PassThru -DisableNameChecking -Verbose:$false
    if ($null -ne $module) {
        $script:ImportedLabSetupModules += $module
    }
}

$LabSetupExportedFunctions = @(
    'Confirm-LabAdministrator',
    'ConvertTo-Hashtable',
    'Get-OptionalPropertyValue',
    'Get-LabPackageById',
    'Get-LabSetupConfig',
    'Get-MsiProductInstallInfo',
    'New-LabDirectory',
    'Set-LabDirectoryWritable',
    'Get-LabLogPath',
    'Write-LabLog',
    'Add-MachinePathEntry',
    'Resolve-ExecutableFromCandidates',
    'Join-LabCommandLineArguments',
    'Show-LabProcessSpinner',
    'Invoke-ProcessWithSpinner',
    'Get-LabProcessExitCode',
    'Get-WingetExecutable',
    'Invoke-Winget',
    'Get-WingetLogRoot',
    'Get-WingetScopeCandidates',
    'Get-WingetInstallAttempts',
    'Get-WingetInstallPrecheckResult',
    'Install-WingetPackage',
    'Install-ManualPackage',
    'Install-LabPackages',
    'Get-ShellItemFromPath',
    'Get-ShellItemFromAppId',
    'Get-StartMenuShortcutPath',
    'Get-LabTaskbarShellItems',
    'Invoke-TaskbarVerb',
    'Test-TaskbarPinned',
    'Test-LabTaskbarPinnedState',
    'Set-TaskbarPin',
    'Get-OrderedTaskbarCandidates',
    'Resolve-LabShortcutPath',
    'Get-LabTaskbarPinRequest',
    'Set-LabTaskbarPins',
    'Get-LabExistingTaskbarPins',
    'Convert-ToTaskbarLayoutPath',
    'New-LabTaskbarShortcut',
    'Get-LabTaskbarLayoutEntries',
    'Set-LabTaskbarLayout',
    'Reset-LabTaskbarLayoutState',
    'Get-VoltaNodeInstallArguments',
    'Initialize-VoltaDirectoryLayout',
    'Test-VoltaDefaultNpmMetadataError',
    'Reset-VoltaNodeCaches',
    'Get-VoltaPackageDescriptor',
    'Test-VoltaToolPresence',
    'Test-VoltaInstallResult',
    'Set-VoltaToolchain',
    'Get-UvPythonVersionToken',
    'Get-UvPythonShimPath',
    'Test-UvPythonInstallResult',
    'Set-UvToolchain',
    'Set-GitLfsConfiguration',
    'Install-MikTexFromInstaller',
    'Get-MikTexConfigValue',
    'Test-MikTexAutoInstallResult',
    'Set-MikTexConfiguration',
    'Set-WindowsTerminalDefaultProfile'
)

Export-ModuleMember -Function $LabSetupExportedFunctions

