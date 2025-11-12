$script:WingetExitCodes = @{
    UpdateNotApplicable    = -1978335189
    UpgradeVersionNotNewer = -1978335153
    PackageAlreadyInstalled = -1978335135
    NoApplicableInstaller  = -1978335216
    NoInstalledPackage     = -1978335212
    InstallAlreadyInstalled = -1978334963
    InstallDowngrade       = -1978334962
    InvalidCommandLine     = -1978335230
}

$script:WingetDefaultAcceptableExitCodes = @(
    0,
    $script:WingetExitCodes.UpdateNotApplicable,
    $script:WingetExitCodes.UpgradeVersionNotNewer,
    $script:WingetExitCodes.PackageAlreadyInstalled,
    $script:WingetExitCodes.NoApplicableInstaller
) | Where-Object { $null -ne $_ } | Select-Object -Unique

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
        [switch]$IgnoreError,
        [string]$LogFilePath,
        [System.IO.StreamWriter]$LogWriter,
        [string]$ActivityMessage,
        [switch]$ShowSpinner
    )

    $winget = Get-WingetExecutable

    if (-not $LogFilePath) {
        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'LabSetupWinget'
        New-LabDirectory -Path $tempRoot
        $LogFilePath = Join-Path -Path $tempRoot -ChildPath ("winget_{0:yyyyMMdd_HHmmssfff}.log" -f (Get-Date))
    } else {
        $logDir = Split-Path -Path $LogFilePath -Parent
        if ($logDir) {
            New-LabDirectory -Path $logDir
        }
    }

    $argumentsWithLogging = @($Arguments)
    $hasLogArgument = $false
    for ($i = 0; $i -lt $argumentsWithLogging.Count; $i++) {
        $current = $argumentsWithLogging[$i]
        if ($null -eq $current) { continue }
        if ($current -eq '--log' -or $current -eq '-o') {
            $hasLogArgument = $true
            break
        }
    }
    if (-not $hasLogArgument) {
        $argumentsWithLogging += @('--log', $LogFilePath, '--verbose-logs')
    }

    $argumentLine = Join-LabCommandLineArguments -Arguments $argumentsWithLogging
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $winget
    $startInfo.Arguments = $argumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = (Get-Location).ProviderPath

    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
    }
    catch {
        throw "Failed to start winget: $($_.Exception.Message)"
    }

    if (-not $process) {
        throw 'Failed to launch winget process.'
    }

    try {
        if ($ShowSpinner -and -not [string]::IsNullOrWhiteSpace($ActivityMessage)) {
            Show-LabProcessSpinner -Process $process -Activity $ActivityMessage
        }

        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        if ($process) {
            $process.Dispose()
        }
    }

    $effectiveAcceptableCodes = @()
    if ($AcceptableExitCodes) {
        $effectiveAcceptableCodes += $AcceptableExitCodes
    }
    if ($script:WingetDefaultAcceptableExitCodes) {
        $effectiveAcceptableCodes += $script:WingetDefaultAcceptableExitCodes
    }
    if ($effectiveAcceptableCodes) {
        $effectiveAcceptableCodes = @($effectiveAcceptableCodes | Where-Object { $null -ne $_ } | Select-Object -Unique)
    }

    $isAcceptable = ($exitCode -eq 0)
    if (-not $isAcceptable -and $effectiveAcceptableCodes) {
        $isAcceptable = $effectiveAcceptableCodes -contains $exitCode
    }

    if ($LogWriter -and (Test-Path -LiteralPath $LogFilePath -PathType Leaf)) {
        Write-LabLog -Message "winget log captured at $LogFilePath" -LogWriter $LogWriter
    }

    if (-not $isAcceptable -and -not $IgnoreError) {
        $logExcerpt = $null
        if (Test-Path -LiteralPath $LogFilePath -PathType Leaf) {
            try {
                $logExcerpt = (Get-Content -LiteralPath $LogFilePath -Tail 40)
            }
            catch {
                $logExcerpt = $null
            }
        }

        $exitCodeDisplay = if ($null -ne $exitCode) { $exitCode } else { 'unknown' }
        $message = "winget exited with code $exitCodeDisplay."
        if ($logExcerpt) {
            $message += "`nLast winget log lines:`n$($logExcerpt -join [Environment]::NewLine)"
        } elseif ($LogFilePath) {
            $message += "`nSee $LogFilePath for details."
        }

        throw $message
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        LogPath  = $LogFilePath
    }
}

function Get-WingetLogRoot {
    param(
        [hashtable]$Config
    )

    $root = $null
    if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.programDataPath)) {
        $root = Join-Path -Path $Config.programDataPath -ChildPath 'logs\winget'
    }
    else {
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'LabSetupWinget'
    }

    New-LabDirectory -Path $root
    return $root
}

function Get-WingetScopeCandidates {
    param(
        $ScopeDefinition
    )

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($ScopeDefinition -is [System.Collections.IEnumerable] -and -not ($ScopeDefinition -is [string])) {
        foreach ($scopeValue in $ScopeDefinition) {
            if ([string]::IsNullOrWhiteSpace($scopeValue)) { continue }
            $normalized = $scopeValue.Trim().ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                [void]$candidates.Add($normalized)
            }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ScopeDefinition)) {
        [void]$candidates.Add($ScopeDefinition.Trim().ToLowerInvariant())
    }

    if ($candidates.Count -eq 0) {
        [void]$candidates.Add('machine')
        [void]$candidates.Add('user')
    }
    elseif ($candidates.Contains('user') -and -not $candidates.Contains('machine')) {
        [void]$candidates.Add('machine')
    }

    return @($candidates | Select-Object -Unique)
}

function Get-WingetInstallAttempts {
    param(
        [switch]$PreferSilent
    )

    $attempts = New-Object System.Collections.Generic.List[hashtable]

    if ($PreferSilent) {
        [void]$attempts.Add(@{
            Name      = 'silent'
            ExtraArgs = @('--silent')
            Message   = 'silent'
        })
    }

    [void]$attempts.Add(@{
        Name      = 'interactive'
        ExtraArgs = @()
        Message   = 'interactive'
    })

    return $attempts.ToArray()
}

function Get-WingetInstallPrecheckResult {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Package,
        [Parameter(Mandatory)]
        [string]$LogRoot,
        [System.IO.StreamWriter]$LogWriter,
        [string]$Scope
    )

    $id = $Package.id
    $sanitizedId = ($id -replace '[^A-Za-z0-9_.-]', '_')
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
    $scopeSuffix = ''
    if (-not [string]::IsNullOrWhiteSpace($Scope)) {
        $normalizedScope = $Scope.Trim().ToLowerInvariant()
        $sanitizedScope = ($normalizedScope -replace '[^a-z0-9_-]', '')
        if (-not [string]::IsNullOrWhiteSpace($sanitizedScope)) {
            $scopeSuffix = "_{0}" -f $sanitizedScope
        }
    }
    $logPath = Join-Path -Path $LogRoot -ChildPath ("{0}_precheck{1}_{2}.log" -f $sanitizedId, $scopeSuffix, $timestamp)

    $arguments = @(
        'upgrade',
        '--id', $id,
        '--exact',
        '--accept-package-agreements',
        '--accept-source-agreements'
    )
    if (-not [string]::IsNullOrWhiteSpace($Scope)) {
        $arguments += @('--scope', $Scope)
    }

    $precheckExitCodes = @(
        $script:WingetExitCodes.UpdateNotApplicable,
        $script:WingetExitCodes.UpgradeVersionNotNewer,
        $script:WingetExitCodes.PackageAlreadyInstalled,
        $script:WingetExitCodes.NoApplicableInstaller,
        $script:WingetExitCodes.NoInstalledPackage
    )

    $result = Invoke-Winget -Arguments $arguments -AcceptableExitCodes $precheckExitCodes -IgnoreError -LogWriter $LogWriter -LogFilePath $logPath

    switch ($result.ExitCode) {
        0 { return 'UpdateAvailable' }
        $script:WingetExitCodes.UpdateNotApplicable { return 'UpToDate' }
        $script:WingetExitCodes.UpgradeVersionNotNewer { return 'AlreadyInstalled' }
        $script:WingetExitCodes.PackageAlreadyInstalled { return 'AlreadyInstalled' }
        $script:WingetExitCodes.NoApplicableInstaller { return 'ScopeMismatch' }
        $script:WingetExitCodes.NoInstalledPackage { return 'NotInstalled' }
        default { return 'Unknown' }
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Package,
        [System.IO.StreamWriter]$LogWriter,
        [hashtable]$Config
    )

    $id = $Package.id
    $displayName = $Package.displayName
    $sanitizedId = ($id -replace '[^A-Za-z0-9_.-]', '_')

    $wingetLogRoot = Get-WingetLogRoot -Config $Config

    $alwaysInstall = [bool](Get-OptionalPropertyValue -InputObject $Package -PropertyName 'alwaysInstall')
    $skipUpgradePrecheck = [bool](Get-OptionalPropertyValue -InputObject $Package -PropertyName 'skipUpgradePrecheck')

    $baseArgsCore = @(
        'install',
        '--id', $id,
        '--exact',
        '--accept-package-agreements',
        '--accept-source-agreements'
    )

    $declaredVersion = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'version'
    if ($declaredVersion) {
        $baseArgsCore += @('--version', $declaredVersion)
    }

    $overrideArgs = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'override'
    if ($overrideArgs) {
        $baseArgsCore += @('--override', $overrideArgs)
    }

    $baseArgs = @($baseArgsCore)

    $architectureDefinition = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'architecture'
    $selectedArchitecture = $null
    $installerFiltersApplied = $false
    if ($architectureDefinition) {
        if ($architectureDefinition -is [System.Collections.IEnumerable] -and -not ($architectureDefinition -is [string])) {
            foreach ($archValue in $architectureDefinition) {
                if ([string]::IsNullOrWhiteSpace($archValue)) { continue }
                $selectedArchitecture = $archValue.Trim()
                break
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($architectureDefinition)) {
            $selectedArchitecture = $architectureDefinition.Trim()
        }
    }
    if ($selectedArchitecture) {
        $baseArgs += @('--architecture', $selectedArchitecture)
        $installerFiltersApplied = $true
    }

    $installerType = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'installerType'
    if ($installerType -and -not [string]::IsNullOrWhiteSpace($installerType)) {
        $baseArgs += @('--installer-type', $installerType.Trim())
        $installerFiltersApplied = $true
    }
    $installerFiltersRemoved = $false

    $requestedScope = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'scope'
    $scopeCandidates = Get-WingetScopeCandidates -ScopeDefinition $requestedScope

    $expectedExitCodes = @(
        $script:WingetExitCodes.UpdateNotApplicable,
        $script:WingetExitCodes.UpgradeVersionNotNewer,
        $script:WingetExitCodes.PackageAlreadyInstalled,
        $script:WingetExitCodes.NoApplicableInstaller,
        $script:WingetExitCodes.InstallAlreadyInstalled,
        $script:WingetExitCodes.InstallDowngrade,
        $script:WingetExitCodes.InvalidCommandLine
    )

    $silentFlag = [bool](Get-OptionalPropertyValue -InputObject $Package -PropertyName 'silent')
    $installAttempts = Get-WingetInstallAttempts -PreferSilent:$silentFlag

    Write-LabLog -Message "Installing $displayName ($id) via winget..." -LogWriter $LogWriter

    :ScopeAttempt for ($scopeIndex = 0; $scopeIndex -lt $scopeCandidates.Count; $scopeIndex++) {
        $currentScope = $scopeCandidates[$scopeIndex]
        $scopeArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($currentScope)) {
            $scopeArgs = @('--scope', $currentScope)
        }
        $scopeArgumentRemoved = $false
        $useScopeArgument = ($scopeArgs.Count -gt 0)
        if ($scopeCandidates.Count -gt 1) {
            Write-LabLog -Message "Attempting $displayName install with scope '$currentScope'." -LogWriter $LogWriter
        }

        if (-not $alwaysInstall -and -not $skipUpgradePrecheck) {
            $scopePrecheck = Get-WingetInstallPrecheckResult -Package $Package -LogRoot $wingetLogRoot -LogWriter $LogWriter -Scope $currentScope
            if ($scopePrecheck -in @('UpToDate', 'AlreadyInstalled')) {
                Write-LabLog -Message "$displayName is already installed for scope '$currentScope'; skipping winget install." -LogWriter $LogWriter
                return
            }

            if ($scopePrecheck -eq 'ScopeMismatch') {
                if ($scopeIndex -lt ($scopeCandidates.Count - 1)) {
                    $nextScope = $scopeCandidates[$scopeIndex + 1]
                    Write-LabLog -Message "$displayName does not provide an installer for scope '$currentScope'; retrying with scope '$nextScope'." -LogWriter $LogWriter
                    continue ScopeAttempt
                }

                Write-LabLog -Message "$displayName does not provide an installer for scope '$currentScope'; no alternate scopes available." -LogWriter $LogWriter
                continue ScopeAttempt
            }
        }

        :InstallAttempt for ($attemptIndex = 0; $attemptIndex -lt $installAttempts.Count; $attemptIndex++) {
            $attempt = $installAttempts[$attemptIndex]
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
            $logPath = Join-Path -Path $wingetLogRoot -ChildPath ("{0}_{1}_{2}.log" -f $sanitizedId, $attempt.Name, $timestamp)
            $arguments = @($baseArgs)
            if ($useScopeArgument -and $scopeArgs.Count -gt 0) {
                $arguments += $scopeArgs
            }
            $arguments += $attempt.ExtraArgs
            $activity = "Installing $displayName"
            $result = Invoke-Winget -Arguments $arguments -AcceptableExitCodes $expectedExitCodes -LogWriter $LogWriter -LogFilePath $logPath -ActivityMessage $activity -ShowSpinner

            switch ($result.ExitCode) {
                0 {
                    Write-LabLog -Message "Completed $displayName installation." -LogWriter $LogWriter
                    return
                }
                $script:WingetExitCodes.UpdateNotApplicable {
                    Write-LabLog -Message "$displayName is already at the latest version; skipping." -LogWriter $LogWriter
                    return
                }
                $script:WingetExitCodes.UpgradeVersionNotNewer {
                    Write-LabLog -Message "$displayName is newer than the requested version; leaving existing install in place." -LogWriter $LogWriter
                    return
                }
                $script:WingetExitCodes.PackageAlreadyInstalled {
                    Write-LabLog -Message "$displayName is already installed; skipping." -LogWriter $LogWriter
                    return
                }
                $script:WingetExitCodes.InstallAlreadyInstalled {
                    Write-LabLog -Message "$displayName is already installed (install exit code); skipping." -LogWriter $LogWriter
                    return
                }
                $script:WingetExitCodes.NoApplicableInstaller {
                    if ($attempt.Name -eq 'silent' -and $installAttempts.Count -gt 1) {
                        Write-LabLog -Message "$displayName does not provide silent install metadata; retrying with interactive mode." -LogWriter $LogWriter
                        continue InstallAttempt
                    }

                    if ($scopeIndex -lt ($scopeCandidates.Count - 1)) {
                        $nextScope = $scopeCandidates[$scopeIndex + 1]
                        Write-LabLog -Message "$displayName does not offer an installer for scope '$currentScope'; retrying with scope '$nextScope'." -LogWriter $LogWriter
                        continue ScopeAttempt
                    }
                }
                $script:WingetExitCodes.InstallDowngrade {
                    Write-LabLog -Message "$displayName install would downgrade the currently-installed version; leaving existing install in place." -LogWriter $LogWriter
                    return
                }
                $script:WingetExitCodes.InvalidCommandLine {
                    if ($attempt.Name -eq 'silent' -and $installAttempts.Count -gt 1) {
                        Write-LabLog -Message "$displayName silent install arguments rejected by winget; retrying without --silent." -LogWriter $LogWriter
                        continue InstallAttempt
                    }

                    if ($installerFiltersApplied -and -not $installerFiltersRemoved) {
                        $installerFiltersRemoved = $true
                        $baseArgs = @($baseArgsCore)
                        Write-LabLog -Message "$displayName installer selection arguments rejected; retrying without architecture/installer filters." -LogWriter $LogWriter
                        $attemptIndex--
                        continue InstallAttempt
                    }

                    if ($useScopeArgument -and -not $scopeArgumentRemoved) {
                        $scopeArgumentRemoved = $true
                        $useScopeArgument = $false
                        $scopeLabel = if ([string]::IsNullOrWhiteSpace($currentScope)) { 'default' } else { $currentScope }
                        Write-LabLog -Message "$displayName install arguments rejected while specifying scope '$scopeLabel'; retrying without an explicit scope parameter." -LogWriter $LogWriter
                        $attemptIndex--
                        continue InstallAttempt
                    }

                    if ($scopeIndex -lt ($scopeCandidates.Count - 1)) {
                        $nextScope = $scopeCandidates[$scopeIndex + 1]
                        Write-LabLog -Message "$displayName install arguments rejected while targeting scope '$currentScope'; retrying with scope '$nextScope'." -LogWriter $LogWriter
                        continue ScopeAttempt
                    }

                    $message = "$displayName install arguments were rejected by winget (invalid command line)."
                    Write-LabLog -Message $message -LogWriter $LogWriter
                    throw $message
                }
            }

            $message = "winget failed to install $displayName (exit code $($result.ExitCode)). Review $($result.LogPath) for details."
            throw $message
        }
    }

    throw "winget failed to install $displayName after exhausting available scopes and install modes."
}
