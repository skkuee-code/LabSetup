function Resolve-TeXLivePathValue {
    param(
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    try {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        return $expanded
    }
}

function Get-TeXLiveBinDirectory {
    param(
        [Parameter(Mandatory)]
        [hashtable]$TexConfig
    )

    $installDir = Resolve-TeXLivePathValue -PathValue (Get-OptionalPropertyValue -InputObject $TexConfig -PropertyName 'installDir')
    if ([string]::IsNullOrWhiteSpace($installDir)) {
        return $null
    }

    $binRelative = Get-OptionalPropertyValue -InputObject $TexConfig -PropertyName 'binRelativePath'
    if ([string]::IsNullOrWhiteSpace($binRelative)) {
        $binRelative = 'bin\windows'
    }

    return Join-Path -Path $installDir -ChildPath $binRelative
}

function Get-TeXLiveUtilityCandidates {
    param(
        [Parameter(Mandatory)]
        [hashtable]$TexConfig,
        [Parameter(Mandatory)]
        [string]$Name
    )

    $binRoot = Get-TeXLiveBinDirectory -TexConfig $TexConfig
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($binRoot) {
        [void]$candidates.Add((Join-Path -Path $binRoot -ChildPath "$Name.bat"))
        [void]$candidates.Add((Join-Path -Path $binRoot -ChildPath "$Name.exe"))
        [void]$candidates.Add((Join-Path -Path $binRoot -ChildPath "$Name.cmd"))
        [void]$candidates.Add((Join-Path -Path $binRoot -ChildPath $Name))
    }

    [void]$candidates.Add($Name)
    return @($candidates | Select-Object -Unique)
}

function Resolve-TeXLiveUtility {
    param(
        [Parameter(Mandatory)]
        [hashtable]$TexConfig,
        [Parameter(Mandatory)]
        [string]$Name
    )

    $candidates = Get-TeXLiveUtilityCandidates -TexConfig $TexConfig -Name $Name
    return Resolve-ExecutableFromCandidates -Candidates $candidates
}

function Get-TeXLiveInstallerPayload {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [hashtable]$TexConfig,
        [System.IO.StreamWriter]$LogWriter
    )

    $installerConfig = Get-OptionalPropertyValue -InputObject $TexConfig -PropertyName 'installer'
    if (-not ($installerConfig -is [System.Collections.IDictionary])) {
        throw 'TeX Live installer configuration is missing.'
    }

    $downloadUrl = Get-OptionalPropertyValue -InputObject $installerConfig -PropertyName 'downloadUrl'
    if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
        throw 'TeX Live installer downloadUrl is not defined.'
    }

    $fileName = Get-OptionalPropertyValue -InputObject $installerConfig -PropertyName 'expectedFileName'
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = Split-Path -Path $downloadUrl -Leaf
    }

    $cacheDir = Join-Path -Path $Config.programDataPath -ChildPath 'cache'
    New-LabDirectory -Path $cacheDir
    $destination = Join-Path -Path $cacheDir -ChildPath $fileName

    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Write-LabLog -Message "Downloading TeX Live installer from $downloadUrl ..." -LogWriter $LogWriter
        $invokeParameters = @{
            Uri     = $downloadUrl
            OutFile = $destination
        }
        $command = Get-Command -Name Invoke-WebRequest -ErrorAction Stop
        if ($command.Parameters.ContainsKey('UseBasicParsing')) {
            $invokeParameters['UseBasicParsing'] = $true
        }
        if ($command.Parameters.ContainsKey('AllowInsecureRedirect')) {
            $invokeParameters['AllowInsecureRedirect'] = $true
        }
        Invoke-WebRequest @invokeParameters
    }
    else {
        Write-LabLog -Message 'Using cached TeX Live installer payload.' -LogWriter $LogWriter
    }

    return $destination
}

function Write-TeXLiveProfile {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [hashtable]$TexConfig,
        [System.IO.StreamWriter]$LogWriter
    )

    $profileConfig = Get-OptionalPropertyValue -InputObject $TexConfig -PropertyName 'profile'
    if (-not ($profileConfig -is [System.Collections.IDictionary])) {
        throw 'TeX Live profile configuration is missing.'
    }

    $profileLines = Get-OptionalPropertyValue -InputObject $profileConfig -PropertyName 'lines'
    if (-not $profileLines) {
        throw 'TeX Live profile lines are not defined.'
    }

    $lines = @()
    if ($profileLines -is [System.Collections.IEnumerable] -and -not ($profileLines -is [string])) {
        $lines = @($profileLines | ForEach-Object { $_ })
    }
    elseif ($profileLines) {
        $lines = @($profileLines)
    }

    if (-not $lines -or $lines.Count -eq 0) {
        throw 'TeX Live profile lines are empty.'
    }

    $cacheDir = Join-Path -Path $Config.programDataPath -ChildPath 'cache'
    New-LabDirectory -Path $cacheDir
    $profilePath = Join-Path -Path $cacheDir -ChildPath 'texlive.profile'

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($profilePath, $lines, $encoding)
    Write-LabLog -Message "Wrote TeX Live profile to $profilePath" -LogWriter $LogWriter

    return $profilePath
}

function Install-TeXLiveDistribution {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [hashtable]$TexConfig,
        [System.IO.StreamWriter]$LogWriter
    )

    $installerPath = Get-TeXLiveInstallerPayload -Config $Config -TexConfig $TexConfig -LogWriter $LogWriter
    $profilePath = Write-TeXLiveProfile -Config $Config -TexConfig $TexConfig -LogWriter $LogWriter

    $argumentList = @()
    $installerConfig = Get-OptionalPropertyValue -InputObject $TexConfig -PropertyName 'installer'
    $argumentConfig = Get-OptionalPropertyValue -InputObject $installerConfig -PropertyName 'arguments'
    if ($argumentConfig -is [System.Collections.IEnumerable] -and -not ($argumentConfig -is [string])) {
        $argumentList += @($argumentConfig | ForEach-Object { $_ })
    }
    elseif ($argumentConfig) {
        $argumentList += @($argumentConfig)
    }

    if (-not $argumentList -or $argumentList.Count -eq 0) {
        $argumentList = @('--no-gui')
    }

    $argumentList += "--profile=$profilePath"

    $tlmgrConfig = Get-OptionalPropertyValue -InputObject $TexConfig -PropertyName 'tlmgr'
    $repository = Get-OptionalPropertyValue -InputObject $tlmgrConfig -PropertyName 'repository'
    if ($repository) {
        $argumentList += "--repository=$repository"
    }

    Write-LabLog -Message 'Running TeX Live installer in unattended mode...' -LogWriter $LogWriter
    $process = Invoke-ProcessWithSpinner -FilePath $installerPath -ArgumentList $argumentList -Activity 'Installing TeX Live...'
    $exitCode = Get-LabProcessExitCode -Process $process
    if ($exitCode -ne 0) {
        throw "TeX Live installer exited with code $exitCode."
    }
}

function Invoke-TeXLiveUtility {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath,
        [string[]]$Arguments,
        [string]$Activity,
        [System.IO.StreamWriter]$LogWriter
    )

    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        throw 'ExecutablePath is not specified.'
    }

    $argumentList = @()
    if ($Arguments -is [System.Collections.IEnumerable]) {
        $argumentList = @($Arguments | ForEach-Object { $_ })
    }
    elseif ($Arguments) {
        $argumentList = @($Arguments)
    }

    $filePath = $ExecutablePath
    $batExtensions = @('.bat', '.cmd')
    foreach ($ext in $batExtensions) {
        if ($filePath.EndsWith($ext, [System.StringComparison]::OrdinalIgnoreCase)) {
            $cmdExe = $env:ComSpec
            if ([string]::IsNullOrWhiteSpace($cmdExe)) {
                $cmdExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\cmd.exe'
            }
            $commandText = '"' + $filePath + '"'
            $argumentText = Join-LabCommandLineArguments -Arguments $argumentList
            if (-not [string]::IsNullOrWhiteSpace($argumentText)) {
                $commandText = "$commandText $argumentText"
            }
            $argumentList = @('/c', $commandText)
            $filePath = $cmdExe
            break
        }
    }

    $process = Invoke-ProcessWithSpinner -FilePath $filePath -ArgumentList $argumentList -Activity $Activity
    $exitCode = Get-LabProcessExitCode -Process $process
    return $exitCode
}

function Get-MiKTeXExecutableCandidates {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    $programFiles = $env:ProgramFiles
    $programFilesX86 = ${env:ProgramFiles(x86)}

    if ($programFiles) {
        [void]$candidates.Add((Join-Path -Path $programFiles -ChildPath "MiKTeX\miktex\bin\x64\$Name.exe"))
        [void]$candidates.Add((Join-Path -Path $programFiles -ChildPath "MiKTeX\miktex\bin\$Name.exe"))
    }

    if ($programFilesX86) {
        [void]$candidates.Add((Join-Path -Path $programFilesX86 -ChildPath "MiKTeX\miktex\bin\x64\$Name.exe"))
        [void]$candidates.Add((Join-Path -Path $programFilesX86 -ChildPath "MiKTeX\miktex\bin\$Name.exe"))
    }

    [void]$candidates.Add("$Name.exe")
    [void]$candidates.Add($Name)
    return @($candidates | Select-Object -Unique)
}

function Resolve-MiKTeXUtility {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $candidates = Get-MiKTeXExecutableCandidates -Name $Name
    return Resolve-ExecutableFromCandidates -Candidates $candidates
}

function Get-MiKTeXPathCandidates {
    $paths = New-Object System.Collections.Generic.List[string]
    $programFiles = $env:ProgramFiles
    $programFilesX86 = ${env:ProgramFiles(x86)}
    $programData = $env:ProgramData
    $localAppData = $env:LOCALAPPDATA

    if ($programFiles) {
        [void]$paths.Add((Join-Path -Path $programFiles -ChildPath 'MiKTeX'))
        [void]$paths.Add((Join-Path -Path $programFiles -ChildPath 'MiKTeX 2.9'))
    }

    if ($programFilesX86) {
        [void]$paths.Add((Join-Path -Path $programFilesX86 -ChildPath 'MiKTeX'))
        [void]$paths.Add((Join-Path -Path $programFilesX86 -ChildPath 'MiKTeX 2.9'))
    }

    if ($programData) {
        [void]$paths.Add((Join-Path -Path $programData -ChildPath 'MiKTeX'))
    }

    if ($localAppData) {
        [void]$paths.Add((Join-Path -Path $localAppData -ChildPath 'MiKTeX'))
    }

    return @($paths | Select-Object -Unique)
}

function Test-MiKTeXPresence {
    $utilities = @('miktexsetup', 'mpm', 'initexmf')
    foreach ($utility in $utilities) {
        $path = Resolve-MiKTeXUtility -Name $utility
        if ($path) {
            return $true
        }
    }

    foreach ($candidate in (Get-MiKTeXPathCandidates)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $true
        }
    }

    return $false
}

function Remove-MiKTeXResidualPaths {
    param(
        [System.IO.StreamWriter]$LogWriter
    )

    foreach ($path in (Get-MiKTeXPathCandidates)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) {
            continue
        }

        try {
            Write-LabLog -Message "Removing MiKTeX residual path: $path" -LogWriter $LogWriter
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        }
        catch [System.UnauthorizedAccessException] {
            Write-LabLog -Message ("Permission denied while removing ${path}: {0}" -f $_.Exception.Message) -LogWriter $LogWriter
            throw
        }
        catch {
            Write-LabLog -Message ("Unable to remove ${path}: {0}" -f $_.Exception.Message) -LogWriter $LogWriter
        }
    }
}

function Uninstall-MiKTeXInstallation {
    param(
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    if (-not (Test-MiKTeXPresence)) {
        Write-LabLog -Message 'MiKTeX not detected; skipping uninstall.' -LogWriter $LogWriter
        return
    }

    $removed = $false
    $wingetArgs = @(
        'uninstall',
        '--id', 'MiKTeX.MiKTeX',
        '--scope', 'machine',
        '--silent',
        '--accept-source-agreements',
        '--accept-package-agreements'
    )

    try {
        Write-LabLog -Message 'Attempting MiKTeX uninstall via winget...' -LogWriter $LogWriter
        $wingetResult = Invoke-Winget -Arguments $wingetArgs -LogWriter $LogWriter -ActivityMessage 'Uninstalling MiKTeX via winget...' -ShowSpinner
        if ($wingetResult.ExitCode -eq 0 -or -not (Test-MiKTeXPresence)) {
            $removed = $true
        }
    }
    catch {
        Write-LabLog -Message ("winget uninstall attempt for MiKTeX failed: {0}" -f $_.Exception.Message) -LogWriter $LogWriter
    }

    if (-not $removed) {
        $miktexSetup = Resolve-MiKTeXUtility -Name 'miktexsetup'
        if ($miktexSetup) {
            Write-LabLog -Message 'Falling back to miktexsetup --uninstall --shared ...' -LogWriter $LogWriter
            $arguments = @('--uninstall', '--shared')
            $process = Invoke-ProcessWithSpinner -FilePath $miktexSetup -ArgumentList $arguments -Activity 'Uninstalling MiKTeX (miktexsetup)...'
            $exitCode = Get-LabProcessExitCode -Process $process
            if ($exitCode -eq 0) {
                $removed = $true
            }
            else {
                Write-LabLog -Message ("miktexsetup uninstall exited with code {0}." -f $exitCode) -LogWriter $LogWriter
            }
        }
        else {
            Write-LabLog -Message 'miktexsetup executable not found; unable to run uninstall fallback.' -LogWriter $LogWriter
        }
    }

    Remove-MiKTeXResidualPaths -LogWriter $LogWriter

    if (Test-MiKTeXPresence) {
        throw 'MiKTeX uninstall did not complete successfully.'
    }

    if ($removed) {
        Write-LabLog -Message 'MiKTeX uninstall completed.' -LogWriter $LogWriter
    }
    else {
        Write-LabLog -Message 'MiKTeX artifacts removed without installer confirmation.' -LogWriter $LogWriter
    }
}

function Set-TeXLiveRepository {
    param(
        [Parameter(Mandatory)]
        [string]$TlmgrPath,
        [hashtable]$TexConfig,
        [System.IO.StreamWriter]$LogWriter
    )

    $tlmgrConfig = Get-OptionalPropertyValue -InputObject $TexConfig -PropertyName 'tlmgr'
    $repository = Get-OptionalPropertyValue -InputObject $tlmgrConfig -PropertyName 'repository'
    if ([string]::IsNullOrWhiteSpace($repository)) {
        return
    }

    $exitCode = Invoke-TeXLiveUtility -ExecutablePath $TlmgrPath -Arguments @('option', 'repository', $repository) -Activity 'Configuring TeX Live mirror...' -LogWriter $LogWriter
    if ($exitCode -ne 0) {
        throw "tlmgr option repository exited with code $exitCode."
    }

    Write-LabLog -Message "Configured TeX Live repository: $repository" -LogWriter $LogWriter
}

function Set-TeXLivePath {
    param(
        [Parameter(Mandatory)]
        [string]$TlmgrPath,
        [hashtable]$TexConfig,
        [System.IO.StreamWriter]$LogWriter
    )

    $tlmgrConfig = Get-OptionalPropertyValue -InputObject $TexConfig -PropertyName 'tlmgr'
    $pathArgs = @('path', 'add')
    $windowsMode = Get-OptionalPropertyValue -InputObject $tlmgrConfig -PropertyName 'pathWindowsMode'
    if (-not [string]::IsNullOrWhiteSpace($windowsMode)) {
        $pathArgs += "--windowsmode=$windowsMode"
    }

    $exitCode = Invoke-TeXLiveUtility -ExecutablePath $TlmgrPath -Arguments $pathArgs -Activity 'Registering TeX Live PATH entries...' -LogWriter $LogWriter
    if ($exitCode -ne 0) {
        throw "tlmgr path add exited with code $exitCode."
    }

    Write-LabLog -Message 'TeX Live PATH entries registered.' -LogWriter $LogWriter
}

function Update-TeXLiveFileDatabase {
    param(
        [hashtable]$TexConfig,
        [System.IO.StreamWriter]$LogWriter
    )

    $postInstall = Get-OptionalPropertyValue -InputObject $TexConfig -PropertyName 'postInstall'
    $refreshRequested = Get-OptionalPropertyValue -InputObject $postInstall -PropertyName 'refreshFileDatabase'
    if (-not $refreshRequested) {
        return
    }

    $mktexlsrPath = Resolve-TeXLiveUtility -TexConfig $TexConfig -Name 'mktexlsr'
    if (-not $mktexlsrPath) {
        Write-LabLog -Message 'mktexlsr executable not found; skipping TeX Live FNDB refresh.' -LogWriter $LogWriter
        return
    }

    $exitCode = Invoke-TeXLiveUtility -ExecutablePath $mktexlsrPath -Arguments @() -Activity 'Refreshing TeX Live filename database...' -LogWriter $LogWriter
    if ($exitCode -ne 0) {
        throw "mktexlsr exited with code $exitCode."
    }

    Write-LabLog -Message 'TeX Live filename database refreshed.' -LogWriter $LogWriter
}

function Set-TeXLiveConfiguration {
    param(
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    if (-not $Config.tex) {
        return
    }

    Uninstall-MiKTeXInstallation -Config $Config -LogWriter $LogWriter

    $tlmgrPath = Resolve-TeXLiveUtility -TexConfig $Config.tex -Name 'tlmgr'
    if (-not $tlmgrPath) {
        Install-TeXLiveDistribution -Config $Config -TexConfig $Config.tex -LogWriter $LogWriter
        $tlmgrPath = Resolve-TeXLiveUtility -TexConfig $Config.tex -Name 'tlmgr'
    }

    if (-not $tlmgrPath) {
        throw 'TeX Live tlmgr utility not found after installation.'
    }

    Set-TeXLiveRepository -TlmgrPath $tlmgrPath -TexConfig $Config.tex -LogWriter $LogWriter
    Set-TeXLivePath -TlmgrPath $tlmgrPath -TexConfig $Config.tex -LogWriter $LogWriter
    Update-TeXLiveFileDatabase -TexConfig $Config.tex -LogWriter $LogWriter
}
