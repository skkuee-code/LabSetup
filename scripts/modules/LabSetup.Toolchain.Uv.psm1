function Get-UvPythonVersionToken {
    param(
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    $trimmed = $Version.Trim()
    $parsedVersion = $null
    if ([System.Version]::TryParse($trimmed, [ref]$parsedVersion)) {
        return "{0}.{1}" -f $parsedVersion.Major, $parsedVersion.Minor
    }

    return $trimmed
}

function Get-UvPythonShimPath {
    param(
        [Parameter(Mandatory)]
        [string]$BinDirectory,
        [string]$Version
    )

    $token = Get-UvPythonVersionToken -Version $Version
    if ([string]::IsNullOrWhiteSpace($token)) {
        return $null
    }

    return Join-Path -Path $BinDirectory -ChildPath ("python{0}.exe" -f $token)
}

function Test-UvPythonInstallResult {
    param(
        $ExitCode,
        [Parameter(Mandatory)]
        [string]$Version,
        [Parameter(Mandatory)]
        [string]$UvBin,
        [Parameter(Mandatory)]
        [string]$InstallRoot,
        [System.IO.StreamWriter]$LogWriter
    )

    if ($ExitCode -eq 0) {
        return $true
    }

    $exitCodeDisplay = if ($null -eq $ExitCode) { 'unknown' } else { $ExitCode }
    $shimPath = Get-UvPythonShimPath -BinDirectory $UvBin -Version $Version
    $shimExists = $false
    if ($shimPath) {
        $shimExists = Test-Path -LiteralPath $shimPath -PathType Leaf
    }

    $versionToken = Get-UvPythonVersionToken -Version $Version
    $installExists = $false
    $installPath = $null

    if ($versionToken -and (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
        $matchingDir = Get-ChildItem -Path $InstallRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$versionToken*" } | Select-Object -First 1
        if ($matchingDir) {
            $pythonExe = Join-Path -Path $matchingDir.FullName -ChildPath 'python.exe'
            if (Test-Path -LiteralPath $pythonExe -PathType Leaf) {
                $installExists = $true
                $installPath = $matchingDir.FullName
            }
        }
    }

    if ($shimExists -or $installExists) {
        $details = @()
        if ($shimExists -and $shimPath) { $details += "shim $shimPath" }
        if ($installExists -and $installPath) { $details += "installation $installPath" }
        $detailMessage = if ($details) { ($details -join ' and ') } else { 'python artifacts' }
        Write-LabLog -Message ("uv returned exit code {0} installing Python {1}, but detected {2}; continuing." -f $exitCodeDisplay, $Version, $detailMessage) -LogWriter $LogWriter
        return $true
    }

    $statusDetail = "No python.exe detected under $InstallRoot for version token '$versionToken'."
    Write-LabLog -Message ("uv exit code {0} installing Python {1}. {2}" -f $exitCodeDisplay, $Version, $statusDetail) -LogWriter $LogWriter
    return $false
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
            Install-WingetPackage -Package $uvPackage -LogWriter $LogWriter -Config $Config
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
    $env:UV_HOME = $uvHome
    $uvPythonRoot = Join-Path -Path $uvHome -ChildPath 'python'
    New-LabDirectory -Path $uvPythonRoot
    [Environment]::SetEnvironmentVariable('UV_PYTHON_INSTALL_DIR', $uvPythonRoot, 'Machine')
    $env:UV_PYTHON_INSTALL_DIR = $uvPythonRoot
    [Environment]::SetEnvironmentVariable('UV_PYTHON_BIN_DIR', $uvBin, 'Machine')
    $env:UV_PYTHON_BIN_DIR = $uvBin
    [Environment]::SetEnvironmentVariable('UV_PYTHON_INSTALL_BIN', '1', 'Machine')
    $env:UV_PYTHON_INSTALL_BIN = '1'

    if ($Config.uv.pythonVersions) {
        foreach ($version in $Config.uv.pythonVersions) {
            $pythonShim = Get-UvPythonShimPath -BinDirectory $uvBin -Version $version
            if ($pythonShim -and (Test-Path -LiteralPath $pythonShim -PathType Leaf)) {
                Write-LabLog -Message "Python $version already provisioned in uv bin directory; skipping install." -LogWriter $LogWriter
                continue
            }

            $attempt = 0
            $maxAttempts = 2
            $pythonInstalled = $false
            $lastExitCode = $null

            while (-not $pythonInstalled -and $attempt -lt $maxAttempts) {
                $attempt++
                if ($attempt -gt 1) {
                    Write-LabLog -Message "Retrying Python $version via uv (attempt $attempt of $maxAttempts)..." -LogWriter $LogWriter
                }
                else {
                    Write-LabLog -Message "Installing Python $version via uv..." -LogWriter $LogWriter
                }

                $uvArgs = @('python', 'install', $version, '--install-dir', $uvPythonRoot, '--force')
                $uvProcess = Invoke-ProcessWithSpinner -FilePath $uvExe -ArgumentList $uvArgs -Activity "Installing Python $version via uv"
                $lastExitCode = Get-LabProcessExitCode -Process $uvProcess
                $pythonInstalled = Test-UvPythonInstallResult -ExitCode $lastExitCode -Version $version -UvBin $uvBin -InstallRoot $uvPythonRoot -LogWriter $LogWriter
            }

            if (-not $pythonInstalled) {
                $exitDisplay = if ($null -eq $lastExitCode) { 'unknown' } else { $lastExitCode }
                throw "uv failed to install Python $version (exit code $exitDisplay)."
            }
        }
    }
}
