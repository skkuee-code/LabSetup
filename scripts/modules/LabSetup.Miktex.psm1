function Install-MikTexFromInstaller {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [hashtable]$TexConfig,
        [System.IO.StreamWriter]$LogWriter
    )

    $installerConfig = Get-OptionalPropertyValue -InputObject $TexConfig -PropertyName 'installer'
    if (-not ($installerConfig -is [System.Collections.IDictionary])) {
        return $false
    }

    $downloadUrl = Get-OptionalPropertyValue -InputObject $installerConfig -PropertyName 'downloadUrl'
    if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
        return $false
    }

    $fileName = Get-OptionalPropertyValue -InputObject $installerConfig -PropertyName 'expectedFileName'
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = Split-Path -Path $downloadUrl -Leaf
    }

    $cacheDir = Join-Path -Path $Config.programDataPath -ChildPath 'cache'
    New-LabDirectory -Path $cacheDir
    $destination = Join-Path -Path $cacheDir -ChildPath $fileName

    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Write-LabLog -Message "Downloading MiKTeX installer from $downloadUrl ..." -LogWriter $LogWriter
        $invokeParameters = @{
            Uri     = $downloadUrl
            OutFile = $destination
        }
        $command = Get-Command -Name Invoke-WebRequest
        if ($command.Parameters.ContainsKey('UseBasicParsing')) {
            $invokeParameters['UseBasicParsing'] = $true
        }
        if ($command.Parameters.ContainsKey('AllowInsecureRedirect')) {
            $invokeParameters['AllowInsecureRedirect'] = $true
        }
        Invoke-WebRequest @invokeParameters
    } else {
        Write-LabLog -Message 'Using cached MiKTeX installer payload.' -LogWriter $LogWriter
    }

    $argumentConfig = Get-OptionalPropertyValue -InputObject $installerConfig -PropertyName 'arguments'
    $argumentList = @()
    if ($argumentConfig -is [System.Collections.IEnumerable] -and -not ($argumentConfig -is [string])) {
        $argumentList = @($argumentConfig | ForEach-Object { $_ })
    } elseif ($argumentConfig) {
        $argumentList = @($argumentConfig)
    }
    if (-not $argumentList -or $argumentList.Count -eq 0) {
        $argumentList = @('--unattended', '--shared', '--package-set=basic')
    }

    Write-LabLog -Message 'Running MiKTeX installer in unattended mode...' -LogWriter $LogWriter
    $process = Invoke-ProcessWithSpinner -FilePath $destination -ArgumentList $argumentList -Activity 'Running MiKTeX installer in unattended mode...'
    if ($process.ExitCode -ne 0) {
        throw "MiKTeX installer exited with code $($process.ExitCode)."
    }

    return $true
}

function Get-MikTexConfigValue {
    param(
        [Parameter(Mandatory)]
        [string]$InitexmfPath,
        [Parameter(Mandatory)]
        [string]$Section,
        [Parameter(Mandatory)]
        [string]$Name,
        [switch]$Admin
    )

    if ([string]::IsNullOrWhiteSpace($InitexmfPath) -or [string]::IsNullOrWhiteSpace($Section) -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $configSpecifier = '[{0}]{1}' -f $Section, $Name
    $arguments = @("--show-config-value=$configSpecifier")
    if ($Admin) {
        $arguments = @('--admin') + $arguments
    }

    try {
        $output = & $InitexmfPath @arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        return $null
    }

    if ($exitCode -ne 0 -and -not $output) {
        return $null
    }

    if ($output) {
        $firstLine = ($output | Where-Object { $null -ne $_ } | Select-Object -First 1)
        if ($null -ne $firstLine) {
            return $firstLine.Trim()
        }
    }

    return $null
}

function Test-MikTexAutoInstallResult {
    param(
        $ExitCode,
        [Parameter(Mandatory)]
        [string]$InitexmfPath,
        [switch]$Admin,
        [System.IO.StreamWriter]$LogWriter
    )

    if ($ExitCode -eq 0) {
        return $true
    }

    $exitCodeDisplay = if ($null -eq $ExitCode) { 'unknown' } else { $ExitCode }
    $currentValue = Get-MikTexConfigValue -InitexmfPath $InitexmfPath -Section 'MPM' -Name 'AutoInstall' -Admin:$Admin.IsPresent
    $normalized = $null

    if ($currentValue) {
        $normalized = $currentValue.Trim().ToLowerInvariant()
    }

    $enabledValues = @('1', 'yes', 'true', 'on')
    if ($normalized -and ($normalized -in $enabledValues)) {
        Write-LabLog -Message ("initexmf exit code {0} while enabling AutoInstall, but configuration now reports AutoInstall={1}; continuing." -f $exitCodeDisplay, $currentValue) -LogWriter $LogWriter
        return $true
    }

    $valueDisplay = if ($currentValue) { $currentValue } else { 'unset' }
    Write-LabLog -Message ("initexmf exit code {0} while enabling AutoInstall; current AutoInstall value is {1}." -f $exitCodeDisplay, $valueDisplay) -LogWriter $LogWriter
    return $false
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

    $miktexExeCandidates = @()
    if ($env:ProgramFiles) {
        $miktexExeCandidates += Join-Path -Path ${env:ProgramFiles} -ChildPath 'MiKTeX\miktex\bin\x64\miktex.exe'
        $miktexExeCandidates += Join-Path -Path ${env:ProgramFiles} -ChildPath 'MiKTeX\miktex\bin\miktex.exe'
    }

    if ($programFilesX86) {
        $miktexExeCandidates += Join-Path -Path $programFilesX86 -ChildPath 'MiKTeX\miktex\bin\x64\miktex.exe'
        $miktexExeCandidates += Join-Path -Path $programFilesX86 -ChildPath 'MiKTeX\miktex\bin\miktex.exe'
    }
    $miktexExeCandidates += 'miktex'

    $initexmf = Resolve-ExecutableFromCandidates -Candidates $initexmfCandidates
    $mpmExe = Resolve-ExecutableFromCandidates -Candidates $mpmCandidates
    $miktexExe = Resolve-ExecutableFromCandidates -Candidates $miktexExeCandidates

    if (-not $initexmf -or -not $mpmExe) {
        $miktexPackageId = Get-OptionalPropertyValue -InputObject $Config.tex -PropertyName 'packageId'
        if (-not $miktexPackageId) { $miktexPackageId = 'MiKTeX.MiKTeX' }
        $miktexPackage = Get-LabPackageById -Config $Config -PackageId $miktexPackageId
        if ($miktexPackage) {
            Write-LabLog -Message "MiKTeX utilities not found; attempting winget install for $miktexPackageId ..." -LogWriter $LogWriter
            Install-WingetPackage -Package $miktexPackage -LogWriter $LogWriter -Config $Config
            $initexmf = Resolve-ExecutableFromCandidates -Candidates $initexmfCandidates
            $mpmExe = Resolve-ExecutableFromCandidates -Candidates $mpmCandidates
            $miktexExe = Resolve-ExecutableFromCandidates -Candidates $miktexExeCandidates
        }
    }

    if (-not $initexmf -or -not $mpmExe) {
        $installedWithBootstrap = Install-MikTexFromInstaller -Config $Config -TexConfig $Config.tex -LogWriter $LogWriter
        if ($installedWithBootstrap) {
            $initexmf = Resolve-ExecutableFromCandidates -Candidates $initexmfCandidates
            $mpmExe = Resolve-ExecutableFromCandidates -Candidates $mpmCandidates
            $miktexExe = Resolve-ExecutableFromCandidates -Candidates $miktexExeCandidates
        }
    }

    if (-not $initexmf -or -not $mpmExe) {
        Write-LabLog -Message 'MiKTeX utilities not found after installation attempt.' -LogWriter $LogWriter
        throw 'MiKTeX utilities not found.'
    }

    if ($Config.tex.autoInstallMissingPackages) {
        $autoInstallActivity = 'Enabling MiKTeX automatic package installation (admin)...'
        $attempt = 0
        $maxAttempts = 2
        $autoInstallConfigured = $false

        while (-not $autoInstallConfigured -and $attempt -lt $maxAttempts) {
            $attempt++
            if ($attempt -gt 1) {
                Write-LabLog -Message ("Retrying MiKTeX automatic package installation toggle (attempt {0} of {1})..." -f $attempt, $maxAttempts) -LogWriter $LogWriter
            }
            else {
                Write-LabLog -Message $autoInstallActivity -LogWriter $LogWriter
            }

            $autoInstallProcess = Invoke-ProcessWithSpinner -FilePath $initexmf -ArgumentList @('--admin', '--set-config-value', '[MPM]AutoInstall=1') -Activity $autoInstallActivity
            $autoInstallExitCode = Get-LabProcessExitCode -Process $autoInstallProcess
            $autoInstallConfigured = Test-MikTexAutoInstallResult -ExitCode $autoInstallExitCode -InitexmfPath $initexmf -Admin -LogWriter $LogWriter
        }

        if (-not $autoInstallConfigured) {
            throw 'initexmf failed to set AutoInstall for MiKTeX.'
        }
    }

    if ($Config.tex.refreshFileDatabase) {
        $refreshActivity = 'Refreshing MiKTeX filename database (admin)...'
        $attempt = 0
        $maxAttempts = 2
        $fndbRefreshed = $false
        $lastExitCode = $null

        while (-not $fndbRefreshed -and $attempt -lt $maxAttempts) {
            $attempt++
            if ($attempt -gt 1) {
                Write-LabLog -Message ("Retrying MiKTeX FNDB refresh (attempt {0} of {1})..." -f $attempt, $maxAttempts) -LogWriter $LogWriter
            }
            else {
                Write-LabLog -Message $refreshActivity -LogWriter $LogWriter
            }

            $refreshProcess = Invoke-ProcessWithSpinner -FilePath $initexmf -ArgumentList @('--admin', '--update-fndb') -Activity $refreshActivity
            $lastExitCode = Get-LabProcessExitCode -Process $refreshProcess
            if ($lastExitCode -eq 0) {
                $fndbRefreshed = $true
                break
            }

            $exitDisplay = if ($null -eq $lastExitCode) { 'unknown' } else { $lastExitCode }
            Write-LabLog -Message ("initexmf exit code {0} while refreshing the MiKTeX FNDB." -f $exitDisplay) -LogWriter $LogWriter

            if ($miktexExe) {
                $fallbackActivity = 'Refreshing MiKTeX filename database via miktex (admin)...'
                $fallbackProcess = Invoke-ProcessWithSpinner -FilePath $miktexExe -ArgumentList @('--admin', 'fndb', 'refresh') -Activity $fallbackActivity
                $fallbackExitCode = Get-LabProcessExitCode -Process $fallbackProcess
                if ($fallbackExitCode -eq 0) {
                    Write-LabLog -Message 'miktex fndb refresh succeeded after initexmf failure; continuing.' -LogWriter $LogWriter
                    $fndbRefreshed = $true
                    break
                }

                $fallbackDisplay = if ($null -eq $fallbackExitCode) { 'unknown' } else { $fallbackExitCode }
                Write-LabLog -Message ("miktex exit code {0} while attempting FNDB refresh fallback." -f $fallbackDisplay) -LogWriter $LogWriter
            }
            else {
                Write-LabLog -Message 'miktex executable not found; unable to attempt FNDB refresh fallback.' -LogWriter $LogWriter
            }
        }

        if (-not $fndbRefreshed) {
            throw 'initexmf failed to refresh the MiKTeX FNDB.'
        }
    }
}
