function Get-VoltaNodeInstallArguments {
    param(
        [string]$NodeVersion
    )

    if ([string]::IsNullOrWhiteSpace($NodeVersion)) {
        return @('install', 'node')
    }

    $normalized = $NodeVersion.Trim()
    if ($normalized.StartsWith('node@', [System.StringComparison]::OrdinalIgnoreCase)) {
        return @('install', $normalized)
    }

    $alias = $normalized.ToLowerInvariant()
    if ($alias -in @('lts', 'latest', 'current', 'stable')) {
        return @('install', 'node')
    }

    return @('install', "node@$normalized")
}

function Get-VoltaHomePath {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $voltaConfig = Get-OptionalPropertyValue -InputObject $Config -PropertyName 'volta'
    $configuredHome = Get-OptionalPropertyValue -InputObject $voltaConfig -PropertyName 'homePath'
    if (-not [string]::IsNullOrWhiteSpace($configuredHome)) {
        return [Environment]::ExpandEnvironmentVariables($configuredHome.Trim())
    }

    if (-not [string]::IsNullOrWhiteSpace($env:VOLTA_HOME)) {
        return $env:VOLTA_HOME
    }

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        return Join-Path -Path $localAppData -ChildPath 'Volta'
    }

    if ($Config.programDataPath) {
        return Join-Path -Path $Config.programDataPath -ChildPath 'volta'
    }

    return Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'Volta'
}

function Test-SharedVoltaHome {
    param(
        [Parameter(Mandatory)]
        [string]$VoltaHome,
        [string]$ProgramDataRoot
    )

    if ([string]::IsNullOrWhiteSpace($VoltaHome) -or [string]::IsNullOrWhiteSpace($ProgramDataRoot)) {
        return $false
    }

    try {
        $homeFull = [System.IO.Path]::GetFullPath($VoltaHome)
        $rootFull = [System.IO.Path]::GetFullPath($ProgramDataRoot)
    }
    catch {
        return $false
    }

    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    $homeNormalized = $homeFull.TrimEnd('\')
    $rootNormalized = $rootFull.TrimEnd('\')
    if ($homeNormalized.Equals($rootNormalized, $comparison)) {
        return $true
    }

    $rootPrefix = $rootNormalized + [System.IO.Path]::DirectorySeparatorChar
    return $homeNormalized.StartsWith($rootPrefix, $comparison)
}

function Initialize-VoltaDirectoryLayout {
    param(
        [Parameter(Mandatory)]
        [string]$VoltaHome,
        [switch]$SharedScope
    )

    $required = @(
        $VoltaHome,
        (Join-Path -Path $VoltaHome -ChildPath 'bin'),
        (Join-Path -Path $VoltaHome -ChildPath 'cache'),
        (Join-Path -Path $VoltaHome -ChildPath 'tmp'),
        (Join-Path -Path $VoltaHome -ChildPath 'log'),
        (Join-Path -Path $VoltaHome -ChildPath 'tools'),
        (Join-Path -Path $VoltaHome -ChildPath 'tools\inventory'),
        (Join-Path -Path $VoltaHome -ChildPath 'tools\image'),
        (Join-Path -Path $VoltaHome -ChildPath 'tools\user')
    )

    foreach ($path in $required) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            if ($SharedScope) {
                Set-LabDirectoryWritable -Path $path
            }
            else {
                New-LabDirectory -Path $path
            }
        }
    }
}

function Test-VoltaDefaultNpmMetadataError {
    param(
        [Parameter(Mandatory)]
        [string]$VoltaHome,
        [double]$MaxAgeMinutes = 5
    )

    if ([string]::IsNullOrWhiteSpace($VoltaHome)) {
        return $false
    }

    $logDir = Join-Path -Path $VoltaHome -ChildPath 'log'
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        return $false
    }

    $latest = Get-ChildItem -LiteralPath $logDir -Filter 'volta-error-*.log' -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) { return $false }

    $ageMinutes = ((Get-Date) - $latest.LastWriteTime).TotalMinutes
    if ($MaxAgeMinutes -gt 0 -and $ageMinutes -gt $MaxAgeMinutes) {
        return $false
    }

    try {
        $content = Get-Content -LiteralPath $latest.FullName -Raw -ErrorAction Stop
    }
    catch {
        return $false
    }

    return ($content -match 'default npm version')
}

function Reset-VoltaNodeCaches {
    param(
        [Parameter(Mandatory)]
        [string]$VoltaHome,
        [System.IO.StreamWriter]$LogWriter,
        [switch]$SharedScope
    )

    if ([string]::IsNullOrWhiteSpace($VoltaHome)) {
        return
    }

    Write-LabLog -Message 'Clearing cached Volta Node metadata after npm version lookup failure.' -LogWriter $LogWriter

    $targets = @(
        'tools\inventory\node',
        'tools\inventory\npm',
        'tools\image\node',
        'tools\image\npm'
    )

    foreach ($relative in $targets) {
        $target = Join-Path -Path $VoltaHome -ChildPath $relative
        if (Test-Path -LiteralPath $target) {
            try {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            }
            catch {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if ($SharedScope) {
            Set-LabDirectoryWritable -Path $target
        }
        else {
            New-LabDirectory -Path $target
        }
    }

    $lockFile = Join-Path -Path $VoltaHome -ChildPath 'volta.lock'
    if (Test-Path -LiteralPath $lockFile -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $lockFile -Force -ErrorAction Stop
        }
        catch {
            Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-VoltaNodeMetadataMismatch {
    param(
        [Parameter(Mandatory)]
        [string]$VoltaHome
    )

    if ([string]::IsNullOrWhiteSpace($VoltaHome)) {
        return $false
    }

    $inventoryNodePath = Join-Path -Path $VoltaHome -ChildPath 'tools\inventory\node'
    $imageNodePath = Join-Path -Path $VoltaHome -ChildPath 'tools\image\node'

    $hasMetadata = $false
    if (Test-Path -LiteralPath $inventoryNodePath -PathType Container) {
        try {
            $metadataFiles = Get-ChildItem -LiteralPath $inventoryNodePath -Filter 'node-v*-npm' -File -ErrorAction Stop
            if ($metadataFiles -and $metadataFiles.Count -gt 0) {
                $hasMetadata = $true
            }
        }
        catch {
            $hasMetadata = $false
        }
    }

    if ($hasMetadata) {
        return $false
    }

    $hasNodeArtifacts = $false
    if (Test-Path -LiteralPath $inventoryNodePath -PathType Container) {
        try {
            $inventoryArtifacts = Get-ChildItem -LiteralPath $inventoryNodePath -ErrorAction Stop
            if ($inventoryArtifacts -and $inventoryArtifacts.Count -gt 0) {
                $hasNodeArtifacts = $true
            }
        }
        catch {
            $hasNodeArtifacts = $false
        }
    }

    if (-not $hasNodeArtifacts -and (Test-Path -LiteralPath $imageNodePath -PathType Container)) {
        try {
            $imageArtifacts = Get-ChildItem -LiteralPath $imageNodePath -ErrorAction Stop
            if ($imageArtifacts -and $imageArtifacts.Count -gt 0) {
                $hasNodeArtifacts = $true
            }
        }
        catch {
            $hasNodeArtifacts = $false
        }
    }

    return (-not $hasMetadata) -and $hasNodeArtifacts
}

function Repair-VoltaNodeMetadataState {
    param(
        [Parameter(Mandatory)]
        [string]$VoltaHome,
        [System.IO.StreamWriter]$LogWriter,
        [switch]$SharedScope
    )

    if (Test-VoltaNodeMetadataMismatch -VoltaHome $VoltaHome) {
        Write-LabLog -Message 'Detected Volta Node artifacts without npm metadata; resetting caches before continuing.' -LogWriter $LogWriter
        Reset-VoltaNodeCaches -VoltaHome $VoltaHome -LogWriter $LogWriter -SharedScope:$SharedScope
        Initialize-VoltaDirectoryLayout -VoltaHome $VoltaHome -SharedScope:$SharedScope
    }
}

function Get-VoltaPackageDescriptor {
    param(
        [Parameter(Mandatory)]
        [string]$Identifier
    )

    $trimmed = if ($Identifier) { $Identifier.Trim() } else { '' }
    $name = $trimmed
    $version = $null

    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
        if ($trimmed.StartsWith('@')) {
            $slashIndex = $trimmed.IndexOf('/', 1)
            if ($slashIndex -gt 0) {
                $lastAtIndex = $trimmed.LastIndexOf('@')
                if ($lastAtIndex -gt $slashIndex) {
                    $name = $trimmed.Substring(0, $lastAtIndex)
                    $version = $trimmed.Substring($lastAtIndex + 1)
                }
            }
        }
        else {
            $lastAtIndex = $trimmed.LastIndexOf('@')
            if ($lastAtIndex -gt 0) {
                $name = $trimmed.Substring(0, $lastAtIndex)
                $version = $trimmed.Substring($lastAtIndex + 1)
            }
        }
    }

    return @{
        Identifier   = $trimmed
        Name         = $name
        Version      = $version
        DisplayLabel = $trimmed
    }
}

function Test-VoltaToolPresence {
    param(
        [Parameter(Mandatory)]
        [string]$ToolName,
        [string]$ExpectedVersion,
        [string]$ListOutput
    )

    if ([string]::IsNullOrWhiteSpace($ToolName) -or [string]::IsNullOrWhiteSpace($ListOutput)) {
        return $false
    }

    $trimmed = $ListOutput.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $false }

    $toolPattern = "{0}@" -f [System.Text.RegularExpressions.Regex]::Escape($ToolName)
    if (-not [System.Text.RegularExpressions.Regex]::IsMatch($trimmed, $toolPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
        return $true
    }

    $normalizedVersion = $ExpectedVersion.Trim().ToLowerInvariant()
    if ($normalizedVersion -in @('lts', 'latest', 'current', 'stable')) {
        return $true
    }

    $versionPattern = "{0}{1}" -f $toolPattern, [System.Text.RegularExpressions.Regex]::Escape($ExpectedVersion.Trim())
    return [System.Text.RegularExpressions.Regex]::IsMatch($trimmed, $versionPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Test-VoltaInstallResult {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)]
        [string]$VoltaExe,
        [string]$ExpectedVersion,
        [System.IO.StreamWriter]$LogWriter,
        [string]$ListTarget,
        [string]$DisplayLabel
    )

    $exitCode = Get-LabProcessExitCode -Process $Process
    if ($exitCode -eq 0) {
        return $true
    }

    $label = if ([string]::IsNullOrWhiteSpace($DisplayLabel)) { $ListTarget } else { $DisplayLabel }
    $exitCodeDisplay = if ($null -eq $exitCode) { 'unknown' } else { $exitCode }

    $listArgs = @('list')
    if (-not [string]::IsNullOrWhiteSpace($ListTarget)) {
        $listArgs += $ListTarget
    }
    $listArgs += @('--format', 'plain')

    $listOutput = $null
    $listExitCode = -1

    try {
        $listOutput = (& $VoltaExe @listArgs 2>&1)
        $listExitCode = $LASTEXITCODE
    }
    catch {
        $listExitCode = -1
        $listOutput = $null
    }

    $listText = if ($listOutput) { ($listOutput -join [Environment]::NewLine).Trim() } else { $null }

    if ($listExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($ListTarget) -and (Test-VoltaToolPresence -ToolName $ListTarget -ExpectedVersion $ExpectedVersion -ListOutput $listText)) {
        Write-LabLog -Message ("Volta returned exit code {0} installing {1}, but 'volta list' shows the tool is present; continuing." -f $exitCodeDisplay, $label) -LogWriter $LogWriter
        return $true
    }

    $statusDetail = if ($listText) { $listText } else { "no output from 'volta list'" }
    Write-LabLog -Message ("Volta exit code {0} installing {1}. 'volta list' result: {2}" -f $exitCodeDisplay, $label, $statusDetail) -LogWriter $LogWriter
    return $false
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

    $voltaHome = Get-VoltaHomePath -Config $Config
    $voltaHomeIsShared = Test-SharedVoltaHome -VoltaHome $voltaHome -ProgramDataRoot $Config.programDataPath
    $scopeDescription = if ($voltaHomeIsShared) { 'shared across users' } else { 'per-user scope' }
    Write-LabLog -Message ("Using Volta home path '{0}' ({1})." -f $voltaHome, $scopeDescription) -LogWriter $LogWriter

    Initialize-VoltaDirectoryLayout -VoltaHome $voltaHome -SharedScope:$voltaHomeIsShared
    Repair-VoltaNodeMetadataState -VoltaHome $voltaHome -LogWriter $LogWriter -SharedScope:$voltaHomeIsShared
    $voltaBin = Join-Path -Path $voltaHome -ChildPath 'bin'
    if ($voltaHomeIsShared) {
        Add-MachinePathEntry -Path $voltaBin
    }
    elseif (-not [string]::IsNullOrWhiteSpace($voltaBin)) {
        $target = $voltaBin.Trim().TrimEnd('\')
        $existingSegments = @()
        if ($env:Path) {
            $existingSegments = $env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
        $hasSegment = $false
        foreach ($segment in $existingSegments) {
            $normalized = $segment.Trim().TrimEnd('\')
            if ($normalized.Equals($target, [System.StringComparison]::OrdinalIgnoreCase)) {
                $hasSegment = $true
                break
            }
        }

        if (-not $hasSegment) {
            if ([string]::IsNullOrWhiteSpace($env:Path)) {
                $env:Path = $voltaBin
            }
            else {
                $env:Path = "$voltaBin;$($env:Path)"
            }
        }
    }

    $env:VOLTA_HOME = $voltaHome
    if ($voltaHomeIsShared) {
        [Environment]::SetEnvironmentVariable('VOLTA_HOME', $voltaHome, 'Machine')
    }
    else {
        $machineVoltaHome = [Environment]::GetEnvironmentVariable('VOLTA_HOME', 'Machine')
        if ($machineVoltaHome -and (Test-SharedVoltaHome -VoltaHome $machineVoltaHome -ProgramDataRoot $Config.programDataPath)) {
            [Environment]::SetEnvironmentVariable('VOLTA_HOME', $null, 'Machine')
        }
        [Environment]::SetEnvironmentVariable('VOLTA_HOME', $voltaHome, 'User')
    }

    if ($Config.volta.nodeVersion) {
        $nodeArgs = Get-VoltaNodeInstallArguments -NodeVersion $Config.volta.nodeVersion
        $maxAttempts = 3
        $nodeInstallSucceeded = $false
        $metadataResetPerformed = $false

        for ($attempt = 1; (-not $nodeInstallSucceeded) -and $attempt -le $maxAttempts; $attempt++) {
            if ($attempt -gt 1) {
                Write-LabLog -Message "Retrying Volta Node installation (attempt $attempt of $maxAttempts)..." -LogWriter $LogWriter
            }
            else {
                Write-LabLog -Message "Configuring Volta Node version $($Config.volta.nodeVersion)..." -LogWriter $LogWriter
            }

            $nodeProcess = Invoke-ProcessWithSpinner -FilePath $voltaExe -ArgumentList $nodeArgs -Activity "Configuring Volta Node $($Config.volta.nodeVersion)"
            $nodeDisplayLabel = if ($Config.volta.nodeVersion) { "node@$($Config.volta.nodeVersion)" } else { 'node' }
            $nodeInstallSucceeded = Test-VoltaInstallResult -Process $nodeProcess -VoltaExe $voltaExe -ExpectedVersion $Config.volta.nodeVersion -LogWriter $LogWriter -ListTarget 'node' -DisplayLabel $nodeDisplayLabel

            if (-not $nodeInstallSucceeded -and -not $metadataResetPerformed -and (Test-VoltaDefaultNpmMetadataError -VoltaHome $voltaHome)) {
                Reset-VoltaNodeCaches -VoltaHome $voltaHome -LogWriter $LogWriter -SharedScope:$voltaHomeIsShared
                Initialize-VoltaDirectoryLayout -VoltaHome $voltaHome -SharedScope:$voltaHomeIsShared
                $metadataResetPerformed = $true
            }
        }

        if (-not $nodeInstallSucceeded) {
            throw "Volta failed to install Node $($Config.volta.nodeVersion)."
        }
    }

    if ($Config.volta.globalPackages) {
        foreach ($pkg in $Config.volta.globalPackages) {
            if ([string]::IsNullOrWhiteSpace($pkg)) { continue }
            $pkgDescriptor = Get-VoltaPackageDescriptor -Identifier $pkg
            $pkgLabel = if ($pkgDescriptor.DisplayLabel) { $pkgDescriptor.DisplayLabel } else { $pkg }
            $pkgAttempt = 0
            $pkgMaxAttempts = 2
            $pkgInstalled = $false

            while (-not $pkgInstalled -and $pkgAttempt -lt $pkgMaxAttempts) {
                $pkgAttempt++
                if ($pkgAttempt -gt 1) {
                    Write-LabLog -Message "Retrying Volta global package $pkgLabel (attempt $pkgAttempt of $pkgMaxAttempts)..." -LogWriter $LogWriter
                }
                else {
                    Write-LabLog -Message "Installing global Volta package $pkgLabel ..." -LogWriter $LogWriter
                }

                $pkgProcess = Invoke-ProcessWithSpinner -FilePath $voltaExe -ArgumentList @('install', $pkgDescriptor.Identifier) -Activity "Installing Volta package $pkgLabel"
                $pkgInstalled = Test-VoltaInstallResult -Process $pkgProcess -VoltaExe $voltaExe -ExpectedVersion $pkgDescriptor.Version -LogWriter $LogWriter -ListTarget $pkgDescriptor.Name -DisplayLabel $pkgLabel
            }

            if (-not $pkgInstalled) {
                throw "Volta failed to install global package $pkgLabel."
            }
        }
    }
}
