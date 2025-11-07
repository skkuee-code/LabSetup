Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Confirm-LabAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges are required.'
    }
}

function ConvertTo-Hashtable {
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    switch ($InputObject) {
        { $_ -is [System.Collections.IDictionary] } {
            $result = @{}
            foreach ($key in $_.Keys) {
                $result[$key] = ConvertTo-Hashtable -InputObject $_[$key]
            }
            return $result
        }
        { $_ -is [System.Management.Automation.PSObject] } {
            $result = @{}
            foreach ($property in $_.PSObject.Properties) {
                $result[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
            }
            return $result
        }
        { $_ -is [System.Collections.IEnumerable] -and -not ($_ -is [string]) } {
            $list = @()
            foreach ($item in $_) {
                $list += ,(ConvertTo-Hashtable -InputObject $item)
            }
            return ,$list
        }
        default { return $InputObject }
    }
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory)]
        $InputObject,
        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.ContainsKey($PropertyName)) {
        return $InputObject[$PropertyName]
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Get-LabPackageById {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [string]$PackageId
    )

    if (-not $Config.wingetPackages) {
        return $null
    }

    foreach ($package in $Config.wingetPackages) {
        $currentId = Get-OptionalPropertyValue -InputObject $package -PropertyName 'id'
        if ([string]::IsNullOrWhiteSpace($currentId)) { continue }
        if ($currentId -eq $PackageId) {
            return $package
        }
    }

    return $null
}

function Get-LabSetupConfig {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }

    $raw = Get-Content -LiteralPath $ConfigPath -Raw
    $json = ConvertFrom-Json -InputObject $raw
    return ConvertTo-Hashtable -InputObject $json
}

function Get-WingetExecutable {
    $command = Get-Command -Name winget -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw 'winget executable not found in PATH.'
    }
    return $command.Source
}

function Invoke-Winget {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [int[]]$AcceptableExitCodes = @(),
        [switch]$IgnoreError
    )

    $winget = Get-WingetExecutable
    $output = & $winget @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $isAcceptable = ($exitCode -eq 0) -or ($AcceptableExitCodes -contains $exitCode)
    if (-not $isAcceptable -and -not $IgnoreError) {
        throw "winget exited with code $exitCode.`n$($output | Out-String)"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function New-LabDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-LabLogPath {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $root = Join-Path -Path $Config.programDataPath -ChildPath 'logs'
    New-LabDirectory -Path $root
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    return Join-Path -Path $root -ChildPath "LabSetup_$timestamp.log"
}

function Write-LabLog {
    param(
        [string]$Message,
        [System.IO.StreamWriter]$LogWriter
    )

    $line = "[{0}] {1}" -f (Get-Date -Format 'u'), $Message
    if ($null -ne $LogWriter) {
        $LogWriter.WriteLine($line)
        $LogWriter.Flush()
    }
    Write-Host $line
}

function Add-MachinePathEntry {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $segments = $current -split ';' | Where-Object { $_ }
    if ($segments -contains $Path) {
        return
    }

    $newPath = ($segments + $Path) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
}

function Resolve-ExecutableFromCandidates {
    param(
        [Parameter(Mandatory)]
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
        catch {
            # Ignore and fall back to command resolution
        }

        $command = Get-Command -Name $candidate -ErrorAction SilentlyContinue
        if ($command -and $command.Source) {
            return $command.Source
        }
    }

    return $null
}

function Get-ShellItemFromPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $shell = New-Object -ComObject Shell.Application
    try {
        $parent = Split-Path -Path $Path -Parent
        $leaf = Split-Path -Path $Path -Leaf
        $folder = $shell.Namespace($parent)
        if ($null -eq $folder) {
            return $null
        }
        return $folder.ParseName($leaf)
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Get-ShellItemFromAppId {
    param(
        [Parameter(Mandatory)]
        [string]$AppId
    )

    $shell = New-Object -ComObject Shell.Application
    try {
        $appsFolder = $shell.Namespace('shell:AppsFolder')
        return $appsFolder.ParseName($AppId)
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Get-StartMenuShortcutPath {
    param(
        [Parameter(Mandatory)]
        [string]$ShortcutName
    )

    if ([string]::IsNullOrWhiteSpace($ShortcutName)) {
        return $null
    }

    $shortcutFile = if ($ShortcutName.EndsWith('.lnk')) {
        $ShortcutName
    } else {
        "$ShortcutName.lnk"
    }

    $candidateRoots = @(
        (Join-Path -Path $env:ProgramData -ChildPath 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path -Path $env:ProgramData -ChildPath 'Microsoft\Windows\Start Menu'),
        (Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\Start Menu\Programs')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($root in $candidateRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try {
            $shortcut = Get-ChildItem -Path $root -Filter $shortcutFile -Recurse -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Select-Object -First 1
        }
        catch {
            $shortcut = $null
        }

        if ($shortcut) {
            return $shortcut.FullName
        }
    }

    return $null
}

function Invoke-TaskbarVerb {
    param(
        [Parameter(Mandatory)]
        $ShellItem,
        [Parameter(Mandatory)]
        [string]$VerbName
    )

    foreach ($verb in $ShellItem.Verbs()) {
        $canonicalProperty = $verb.PSObject.Properties['CanonicalName']
        $canonicalName = if ($canonicalProperty) { $canonicalProperty.Value } else { $null }
        if ($canonicalName -eq $VerbName) {
            $verb.DoIt()
            return $true
        }
        $nameProperty = $verb.PSObject.Properties['Name']
        $verbName = if ($nameProperty) { $nameProperty.Value } else { '' }
        $normalized = ($verbName -replace '&', '').Trim()
        switch ($VerbName) {
            'taskbarpin' {
                if ($normalized -match 'Pin to taskbar' -or $normalized -match 'タスク バーにピン留め') {
                    $verb.DoIt()
                    return $true
                }
            }
            'taskbarunpin' {
                if ($normalized -match 'Unpin from taskbar' -or $normalized -match 'タスク バーからピン留めを外す') {
                    $verb.DoIt()
                    return $true
                }
            }
        }
    }

    return $false
}

function Test-TaskbarPinned {
    param(
        [Parameter(Mandatory)]
        $ShellItem
    )

    foreach ($verb in $ShellItem.Verbs()) {
        $canonicalProperty = $verb.PSObject.Properties['CanonicalName']
        $canonicalName = if ($canonicalProperty) { $canonicalProperty.Value } else { $null }
        if ($canonicalName -eq 'taskbarunpin') {
            return $true
        }
        $nameProperty = $verb.PSObject.Properties['Name']
        $verbName = if ($nameProperty) { $nameProperty.Value } else { '' }
        $normalized = ($verbName -replace '&', '').Trim()
        if ($normalized -match 'Unpin from taskbar' -or $normalized -match 'タスク バーからピン留めを外す') {
            return $true
        }
    }

    return $false
}

function Set-TaskbarPin {
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName,
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [string[]]$CandidatePaths = @(),
        [string]$AppId,
        [string]$ShortcutName
    )

    $retries = [int]($Config.taskbar.retryCount | ForEach-Object { $_ }) 
    if ($retries -lt 1) { $retries = 1 }
    $delay = [int]($Config.taskbar.retryDelaySeconds | ForEach-Object { $_ })
    if ($delay -lt 1) { $delay = 5 }

    for ($attempt = 1; $attempt -le $retries; $attempt++) {
        $shellItem = $null
        if ($CandidatePaths.Count -gt 0) {
            $exe = Resolve-ExecutableFromCandidates -Candidates $CandidatePaths
            if ($exe) {
                $shellItem = Get-ShellItemFromPath -Path $exe
            }
        }

        if (-not $shellItem -and $AppId) {
            $shellItem = Get-ShellItemFromAppId -AppId $AppId
        }

        if (-not $ShortcutName) {
            $ShortcutName = $DisplayName
        }

        if (-not $shellItem) {
            $shortcutPath = Get-StartMenuShortcutPath -ShortcutName $ShortcutName
            if ($shortcutPath) {
                $shellItem = Get-ShellItemFromPath -Path $shortcutPath
            }
        }

        if (-not $shellItem) {
            Start-Sleep -Seconds $delay
            continue
        }

        if (Test-TaskbarPinned -ShellItem $shellItem) {
            return $true
        }

        if (Invoke-TaskbarVerb -ShellItem $shellItem -VerbName 'taskbarpin') {
            Start-Sleep -Seconds 1
            if (Test-TaskbarPinned -ShellItem $shellItem) {
                return $true
            }
        }

        Start-Sleep -Seconds $delay
    }

    Write-Warning "Failed to pin $DisplayName to the taskbar."
    return $false
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Package,
        [System.IO.StreamWriter]$LogWriter
    )

    $id = $Package.id
    $displayName = $Package.displayName
    $wingetArgs = @(
        'install',
        '--id', $id,
        '--exact',
        '--scope', 'machine',
        '--accept-package-agreements',
        '--accept-source-agreements'
    )

    $silentFlag = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'silent'
    if ($silentFlag) {
        $wingetArgs += '--silent'
    }

    $declaredVersion = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'version'
    if ($declaredVersion) {
        $wingetArgs += @('--version', $declaredVersion)
    }

    $overrideArgs = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'override'
    if ($overrideArgs) {
        $wingetArgs += @('--override', $overrideArgs)
    }

    $expectedExitCodes = @(
        -1978335189, # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE
        -1978335153, # APPINSTALLER_CLI_ERROR_UPGRADE_VERSION_NOT_NEWER
        -1978335135  # APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED
    )

    Write-LabLog -Message "Installing $displayName ($id) via winget..." -LogWriter $LogWriter
    $result = Invoke-Winget -Arguments $wingetArgs -AcceptableExitCodes $expectedExitCodes
    switch ($result.ExitCode) {
        0 {
            Write-LabLog -Message "Completed $displayName installation." -LogWriter $LogWriter
        }
        -1978335189 {
            Write-LabLog -Message "$displayName is already at the latest version; skipping." -LogWriter $LogWriter
        }
        -1978335153 {
            Write-LabLog -Message "$displayName is newer than the requested version; leaving existing install in place." -LogWriter $LogWriter
        }
        -1978335135 {
            Write-LabLog -Message "$displayName is already installed; skipping." -LogWriter $LogWriter
        }
    }
}

function Install-ManualPackage {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Package,
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    $installer = $Package['installer']
    if (-not ($installer -is [System.Collections.IDictionary])) {
        throw "Manual package metadata missing installer section for $($Package.displayName)."
    }

    $downloadUrl = if ($installer.ContainsKey('downloadUrl')) { $installer['downloadUrl'] } else { $null }
    if (-not $downloadUrl) {
        throw "Missing download URL for $($Package.displayName)."
    }

    $fileName = if ($installer.ContainsKey('expectedFileName') -and $installer['expectedFileName']) {
        $installer['expectedFileName']
    } else {
        Split-Path -Path $downloadUrl -Leaf
    }

    $cacheDir = Join-Path -Path $Config.programDataPath -ChildPath 'cache'
    New-LabDirectory -Path $cacheDir
    $destination = Join-Path -Path $cacheDir -ChildPath $fileName

    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Write-LabLog -Message "Downloading $($Package.displayName) from $downloadUrl ..." -LogWriter $LogWriter
        $invokeParameters = @{
            Uri     = $downloadUrl
            OutFile = $destination
        }
        $command = Get-Command -Name Invoke-WebRequest
        if ($command.Parameters.ContainsKey('UseBasicParsing')) {
            $invokeParameters['UseBasicParsing'] = $true
        }
        Invoke-WebRequest @invokeParameters
    } else {
        Write-LabLog -Message "Using cached installer for $($Package.displayName)." -LogWriter $LogWriter
    }

    $installerType = if ($installer.ContainsKey('type')) { $installer['type'] } else { $null }
    if (-not $installerType) {
        throw "Missing installer type for $($Package.displayName)."
    }

    switch ($installerType.ToLowerInvariant()) {
        'msi' {
            $msiExec = Join-Path -Path $env:SystemRoot -ChildPath 'System32\msiexec.exe'
            $msiArgs = @(
                '/i', "`"$destination`"",
                '/qn',
                '/norestart',
                'ALLUSERS=1'
            )
            Write-LabLog -Message "Installing $($Package.displayName) via msiexec..." -LogWriter $LogWriter
            $process = Start-Process -FilePath $msiExec -ArgumentList $msiArgs -Wait -PassThru
            if ($process.ExitCode -ne 0) {
                throw "msiexec failed for $($Package.displayName) with exit code $($process.ExitCode)."
            }
        }
        default {
            throw "Unsupported installer type '$installerType' for $($Package.displayName)."
        }
    }

    Write-LabLog -Message "Completed $($Package.displayName) installation." -LogWriter $LogWriter
}

function Install-LabPackages {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    foreach ($package in $Config.wingetPackages) {
        $hasInstallerMetadata = $false
        if ($package -is [System.Collections.IDictionary] -and $package.ContainsKey('installer')) {
            $installerMetadata = $package['installer']
            $hasInstallerMetadata = $null -ne $installerMetadata
        }

        if ($hasInstallerMetadata) {
            Install-ManualPackage -Package $package -Config $Config -LogWriter $LogWriter
        } else {
            Install-WingetPackage -Package $package -LogWriter $LogWriter
        }
    }
}

function Set-LabTaskbarPins {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    foreach ($package in $Config.wingetPackages) {
        $pinToTaskbar = $false
        if ($package -is [System.Collections.IDictionary] -and $package.ContainsKey('pinToTaskbar')) {
            $pinToTaskbar = [bool]$package['pinToTaskbar']
        }

        if (-not $pinToTaskbar) { continue }

        $candidatePaths = @()
        if ($package.ContainsKey('taskbarTargets') -and $package['taskbarTargets']) {
            $candidatePaths = @($package['taskbarTargets'] | ForEach-Object { $_ })
        }

        $appId = $null
        if ($package.ContainsKey('appUserModelId')) {
            $appId = $package['appUserModelId']
        }

        $shortcutName = Get-OptionalPropertyValue -InputObject $package -PropertyName 'taskbarShortcutName'

        Set-TaskbarPin -DisplayName $package.displayName -Config $Config -CandidatePaths $candidatePaths -AppId $appId -ShortcutName $shortcutName | Out-Null
    }
}

function Set-VoltaToolchain {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    if (-not $Config.volta) { return }

    $voltaExe = Resolve-ExecutableFromCandidates -Candidates @(
        (Join-Path -Path ${env:ProgramFiles} -ChildPath 'Volta\volta.exe'),
        (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Volta\volta.exe'),
        'volta'
    )
    if (-not $voltaExe) {
        Write-LabLog -Message 'Volta executable not found; skipping Volta setup.' -LogWriter $LogWriter
        return
    }

    $voltaHome = Join-Path -Path $Config.programDataPath -ChildPath 'volta'
    New-LabDirectory -Path $voltaHome
    $voltaBin = Join-Path -Path $voltaHome -ChildPath 'bin'
    New-LabDirectory -Path $voltaBin
    Add-MachinePathEntry -Path $voltaBin
    [Environment]::SetEnvironmentVariable('VOLTA_HOME', $voltaHome, 'Machine')

    if ($Config.volta.nodeVersion) {
        $nodeArgs = @('install', "node@$($Config.volta.nodeVersion)")
        Write-LabLog -Message "Configuring Volta Node version $($Config.volta.nodeVersion)..." -LogWriter $LogWriter
        & $voltaExe @nodeArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Volta failed to install Node $($Config.volta.nodeVersion)."
        }
    }

    if ($Config.volta.globalPackages) {
        foreach ($pkg in $Config.volta.globalPackages) {
            Write-LabLog -Message "Installing global Volta package $pkg ..." -LogWriter $LogWriter
            & $voltaExe 'install' $pkg | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Volta failed to install global package $pkg."
            }
        }
    }
}

function Set-UvToolchain {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    if (-not $Config.uv) { return }

    $uvCandidates = @()
    if ($env:ProgramFiles) {
        $uvCandidates += Join-Path -Path ${env:ProgramFiles} -ChildPath 'uv\uv.exe'
        $uvCandidates += Join-Path -Path ${env:ProgramFiles} -ChildPath 'uv\bin\uv.exe'
    }

    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ($programFilesX86) {
        $uvCandidates += Join-Path -Path $programFilesX86 -ChildPath 'uv\uv.exe'
        $uvCandidates += Join-Path -Path $programFilesX86 -ChildPath 'uv\bin\uv.exe'
    }

    $uvCandidates += 'uv'
    $uvExe = Resolve-ExecutableFromCandidates -Candidates $uvCandidates
    if (-not $uvExe) {
        $uvPackageId = Get-OptionalPropertyValue -InputObject $Config.uv -PropertyName 'packageId'
        if (-not $uvPackageId) { $uvPackageId = 'astral-sh.uv' }
        $uvPackage = Get-LabPackageById -Config $Config -PackageId $uvPackageId
        if ($uvPackage) {
            Write-LabLog -Message "uv executable not found; attempting winget install for $uvPackageId ..." -LogWriter $LogWriter
            Install-WingetPackage -Package $uvPackage -LogWriter $LogWriter
            $uvExe = Resolve-ExecutableFromCandidates -Candidates $uvCandidates
        }
    }
    if (-not $uvExe) {
        Write-LabLog -Message 'uv executable not found; aborting uv setup.' -LogWriter $LogWriter
        throw 'uv executable not found after installation attempt.'
    }

    $uvHome = Join-Path -Path $Config.programDataPath -ChildPath 'uv'
    New-LabDirectory -Path $uvHome
    $uvBin = Join-Path -Path $uvHome -ChildPath 'bin'
    New-LabDirectory -Path $uvBin
    Add-MachinePathEntry -Path $uvBin
    [Environment]::SetEnvironmentVariable('UV_HOME', $uvHome, 'Machine')
    $uvPythonRoot = Join-Path -Path $uvHome -ChildPath 'python'
    New-LabDirectory -Path $uvPythonRoot
    [Environment]::SetEnvironmentVariable('UV_PYTHON_INSTALL_DIR', $uvPythonRoot, 'Machine')

    if ($Config.uv.pythonVersions) {
        foreach ($version in $Config.uv.pythonVersions) {
            Write-LabLog -Message "Installing Python $version via uv..." -LogWriter $LogWriter
            & $uvExe 'python' 'install' $version | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "uv failed to install Python $version."
            }
        }
    }
}

function Set-GitLfsConfiguration {
    param(
        [System.IO.StreamWriter]$LogWriter
    )

    $gitExe = Resolve-ExecutableFromCandidates -Candidates @(
        (Join-Path -Path ${env:ProgramFiles} -ChildPath 'Git\cmd\git.exe'),
        (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Git\cmd\git.exe'),
        'git'
    )
    if (-not $gitExe) {
        Write-LabLog -Message 'git executable not found; skipping Git LFS configuration.' -LogWriter $LogWriter
        return
    }

    Write-LabLog -Message 'Initializing Git LFS...' -LogWriter $LogWriter
    & $gitExe 'lfs' 'install' '--system' | Out-Null
}

function Set-MikTexConfiguration {
    param(
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    if (-not $Config.tex) { return }

    $programFilesX86 = ${env:ProgramFiles(x86)}

    $initexmfCandidates = @()
    if ($env:ProgramFiles) {
        $initexmfCandidates += Join-Path -Path ${env:ProgramFiles} -ChildPath 'MiKTeX\miktex\bin\x64\initexmf.exe'
        $initexmfCandidates += Join-Path -Path ${env:ProgramFiles} -ChildPath 'MiKTeX\miktex\bin\initexmf.exe'
    }

    if ($programFilesX86) {
        $initexmfCandidates += Join-Path -Path $programFilesX86 -ChildPath 'MiKTeX\miktex\bin\x64\initexmf.exe'
        $initexmfCandidates += Join-Path -Path $programFilesX86 -ChildPath 'MiKTeX\miktex\bin\initexmf.exe'
    }
    $initexmfCandidates += 'initexmf'

    $mpmCandidates = @()
    if ($env:ProgramFiles) {
        $mpmCandidates += Join-Path -Path ${env:ProgramFiles} -ChildPath 'MiKTeX\miktex\bin\x64\mpm.exe'
        $mpmCandidates += Join-Path -Path ${env:ProgramFiles} -ChildPath 'MiKTeX\miktex\bin\mpm.exe'
    }

    if ($programFilesX86) {
        $mpmCandidates += Join-Path -Path $programFilesX86 -ChildPath 'MiKTeX\miktex\bin\x64\mpm.exe'
        $mpmCandidates += Join-Path -Path $programFilesX86 -ChildPath 'MiKTeX\miktex\bin\mpm.exe'
    }
    $mpmCandidates += 'mpm'

    $initexmf = Resolve-ExecutableFromCandidates -Candidates $initexmfCandidates
    $mpmExe = Resolve-ExecutableFromCandidates -Candidates $mpmCandidates

    if (-not $initexmf -or -not $mpmExe) {
        $miktexPackageId = Get-OptionalPropertyValue -InputObject $Config.tex -PropertyName 'packageId'
        if (-not $miktexPackageId) { $miktexPackageId = 'MiKTeX.MiKTeX' }
        $miktexPackage = Get-LabPackageById -Config $Config -PackageId $miktexPackageId
        if ($miktexPackage) {
            Write-LabLog -Message "MiKTeX utilities not found; attempting winget install for $miktexPackageId ..." -LogWriter $LogWriter
            Install-WingetPackage -Package $miktexPackage -LogWriter $LogWriter
            $initexmf = Resolve-ExecutableFromCandidates -Candidates $initexmfCandidates
            $mpmExe = Resolve-ExecutableFromCandidates -Candidates $mpmCandidates
        }
    }

    if (-not $initexmf -or -not $mpmExe) {
        Write-LabLog -Message 'MiKTeX utilities not found after installation attempt.' -LogWriter $LogWriter
        throw 'MiKTeX utilities not found.'
    }

    if ($Config.tex.autoInstallMissingPackages) {
        Write-LabLog -Message 'Enabling MiKTeX automatic package installation (admin)...' -LogWriter $LogWriter
        & $initexmf '--admin' '--set-config-value' '[MPM]AutoInstall=1' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'initexmf failed to set AutoInstall for MiKTeX.'
        }
    }

    if ($Config.tex.refreshFileDatabase) {
        Write-LabLog -Message 'Refreshing MiKTeX filename database (admin)...' -LogWriter $LogWriter
        & $initexmf '--admin' '--update-fndb' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'initexmf failed to refresh the MiKTeX FNDB.'
        }
    }
}

Export-ModuleMember -Function *-*
