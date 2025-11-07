Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WingetExitCodes = @{
    UpdateNotApplicable = -1978335189
    UpgradeVersionNotNewer = -1978335153
    PackageAlreadyInstalled = -1978335135
    NoApplicableInstaller = -1978335216
    NoInstalledPackage   = -1978335212
}

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

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-Hashtable -InputObject $InputObject[$key]
        }
        return $result
    }
    elseif ($InputObject -is [System.Management.Automation.PSObject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
        }
        return $result
    }
    elseif ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-Hashtable -InputObject $item)
        }
        return ,$items
    }

    return $InputObject
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

function Show-LabProcessSpinner {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,
        [string]$Activity = 'Processing',
        [int]$UpdateIntervalMilliseconds = 200
    )

    $activityLabel = if ([string]::IsNullOrWhiteSpace($Activity)) { 'Processing' } else { $Activity }
    $spinnerChars = @('|', '/', '-', '\')
    $progressId = Get-Random
    $index = 0

    if ($Process.HasExited) {
        Write-Progress -Activity $activityLabel -Completed -Id $progressId
        return
    }

    while (-not $Process.HasExited) {
        $status = "{0} {1}" -f $activityLabel, $spinnerChars[$index]
        Write-Progress -Activity $activityLabel -Status $status -PercentComplete -1 -Id $progressId
        Start-Sleep -Milliseconds $UpdateIntervalMilliseconds
        $index = ($index + 1) % $spinnerChars.Length
    }

    Write-Progress -Activity $activityLabel -Completed -Id $progressId
}

function Invoke-ProcessWithSpinner {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$Activity,
        [string]$WorkingDirectory
    )

    $startParams = @{
        FilePath     = $FilePath
        ArgumentList = $ArgumentList
        NoNewWindow  = $true
        PassThru     = $true
    }

    if ($WorkingDirectory) {
        $startParams['WorkingDirectory'] = $WorkingDirectory
    }

    try {
        $process = Start-Process @startParams
    }
    catch {
        throw "Failed to start ${FilePath}: $($_.Exception.Message)"
    }

    if (-not $process) {
        throw "Failed to launch $FilePath."
    }

    Show-LabProcessSpinner -Process $process -Activity $Activity
    $process.WaitForExit()
    return $process
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

    $startParams = @{
        FilePath     = $winget
        ArgumentList = $argumentsWithLogging
        NoNewWindow  = $true
        PassThru     = $true
    }

    try {
        $process = Start-Process @startParams
    }
    catch {
        throw "Failed to start winget: $($_.Exception.Message)"
    }

    if (-not $process) {
        throw 'Failed to launch winget process.'
    }

    if ($ShowSpinner -and -not [string]::IsNullOrWhiteSpace($ActivityMessage)) {
        Show-LabProcessSpinner -Process $process -Activity $ActivityMessage
    }

    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $isAcceptable = ($exitCode -eq 0) -or ($AcceptableExitCodes -contains $exitCode)

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

        $message = "winget exited with code $exitCode."
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
    try {
        [System.Console]::Out.Flush()
    }
    catch {
        # Hosts without an attached console (e.g. remoting) can ignore flush errors.
    }
}

function Add-MachinePathEntry {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $target = $Path.Trim()
    $comparisonTarget = $target.TrimEnd('\')
    $comparison = [System.StringComparison]::OrdinalIgnoreCase

    $machineCurrent = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $machineSegments = @()
    if ($machineCurrent) {
        $machineSegments = $machineCurrent -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $machineHasTarget = $false
    foreach ($segment in $machineSegments) {
        $normalizedSegment = $segment.Trim().TrimEnd('\')
        if ($normalizedSegment.Equals($comparisonTarget, $comparison)) {
            $machineHasTarget = $true
            break
        }
    }

    if (-not $machineHasTarget) {
        $machineSegments = $machineSegments + $target
        [Environment]::SetEnvironmentVariable('Path', ($machineSegments -join ';'), 'Machine')
    }

    $processSegments = @()
    if ($env:Path) {
        $processSegments = $env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $processHasTarget = $false
    foreach ($segment in $processSegments) {
        $normalizedSegment = $segment.Trim().TrimEnd('\')
        if ($normalizedSegment.Equals($comparisonTarget, $comparison)) {
            $processHasTarget = $true
            break
        }
    }

    if (-not $processHasTarget) {
        $env:Path = ($processSegments + $target) -join ';'
    }
}

function Resolve-ExecutableFromCandidates {
    param(
        [Parameter(Mandatory)]
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $expandedCandidate = [Environment]::ExpandEnvironmentVariables($candidate)
        try {
            if (Test-Path -LiteralPath $expandedCandidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $expandedCandidate).Path
            }
        }
        catch {
            # Ignore and fall back to command resolution
        }

        $command = Get-Command -Name $expandedCandidate -ErrorAction SilentlyContinue
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

function Get-LabTaskbarShellItems {
    param(
        [string[]]$CandidatePaths = @(),
        [string]$AppId,
        [string]$ShortcutName,
        [string]$DisplayName
    )

    $items = New-Object System.Collections.Generic.List[object]
    $resolvedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($CandidatePaths) {
        foreach ($candidate in $CandidatePaths) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $exe = Resolve-ExecutableFromCandidates -Candidates @($candidate)
            if ($exe -and $resolvedPaths.Add($exe)) {
                $item = Get-ShellItemFromPath -Path $exe
                if ($item) {
                    [void]$items.Add($item)
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($AppId)) {
        $appItem = Get-ShellItemFromAppId -AppId $AppId
        if ($appItem) {
            [void]$items.Add($appItem)
        }
    }

    $shortcutNames = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ShortcutName)) {
        [void]$shortcutNames.Add($ShortcutName)
    }
    if (-not [string]::IsNullOrWhiteSpace($DisplayName) -and -not $shortcutNames.Contains($DisplayName)) {
        [void]$shortcutNames.Add($DisplayName)
    }

    foreach ($name in $shortcutNames) {
        $shortcutPath = Get-StartMenuShortcutPath -ShortcutName $name
        if ($shortcutPath -and $resolvedPaths.Add($shortcutPath)) {
            $item = Get-ShellItemFromPath -Path $shortcutPath
            if ($item) {
                [void]$items.Add($item)
            }
        }
    }

    return $items.ToArray()
}

function Invoke-TaskbarVerb {
    param(
        [Parameter(Mandatory)]
        $ShellItem,
        [Parameter(Mandatory)]
        [string]$VerbName
    )

    $pinLabels = @('Pin to taskbar', 'タスク バーにピン留めする', 'タスクバーにピン留めする')
    $unpinLabels = @('Unpin from taskbar', 'タスク バーからピン留めを外す', 'タスクバーからピン留めを外す')

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
        $normalizedLower = $normalized.ToLowerInvariant()
        switch ($VerbName) {
            'taskbarpin' {
                foreach ($label in $pinLabels) {
                    if ($normalizedLower -eq $label.ToLowerInvariant()) {
                        $verb.DoIt()
                        return $true
                    }
                }
            }
            'taskbarunpin' {
                foreach ($label in $unpinLabels) {
                    if ($normalizedLower -eq $label.ToLowerInvariant()) {
                        $verb.DoIt()
                        return $true
                    }
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

    $unpinLabels = @('Unpin from taskbar', 'タスク バーからピン留めを外す', 'タスクバーからピン留めを外す')

    foreach ($verb in $ShellItem.Verbs()) {
        $canonicalProperty = $verb.PSObject.Properties['CanonicalName']
        $canonicalName = if ($canonicalProperty) { $canonicalProperty.Value } else { $null }
        if ($canonicalName -eq 'taskbarunpin') {
            return $true
        }
        $nameProperty = $verb.PSObject.Properties['Name']
        $verbName = if ($nameProperty) { $nameProperty.Value } else { '' }
        $normalized = ($verbName -replace '&', '').Trim()
        $normalizedLower = $normalized.ToLowerInvariant()
        foreach ($label in $unpinLabels) {
            if ($normalizedLower -eq $label.ToLowerInvariant()) {
                return $true
            }
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
        [string]$ShortcutName,
        [System.IO.StreamWriter]$LogWriter
    )

    $retries = [int]($Config.taskbar.retryCount | ForEach-Object { $_ }) 
    if ($retries -lt 1) { $retries = 1 }
    $delay = [int]($Config.taskbar.retryDelaySeconds | ForEach-Object { $_ })
    if ($delay -lt 1) { $delay = 5 }

    if ($LogWriter) {
        Write-LabLog -Message "Pinning $DisplayName to the taskbar..." -LogWriter $LogWriter
    }

    for ($attempt = 1; $attempt -le $retries; $attempt++) {
        $shellItems = Get-LabTaskbarShellItems -CandidatePaths $CandidatePaths -AppId $AppId -ShortcutName $ShortcutName -DisplayName $DisplayName
        if (-not $shellItems -or $shellItems.Count -eq 0) {
            if ($attempt -lt $retries) {
                if ($LogWriter) {
                    Write-LabLog -Message "Unable to locate a taskbar target for $DisplayName (attempt $attempt of $retries); retrying in $delay seconds." -LogWriter $LogWriter
                }
                Start-Sleep -Seconds $delay
                continue
            }
            break
        }

        $pinned = $false
        foreach ($shellItem in $shellItems) {
            try {
                if (Test-TaskbarPinned -ShellItem $shellItem) {
                    $pinned = $true
                    break
                }

                if (Invoke-TaskbarVerb -ShellItem $shellItem -VerbName 'taskbarpin') {
                    Start-Sleep -Seconds 1
                    if (Test-TaskbarPinned -ShellItem $shellItem) {
                        $pinned = $true
                        break
                    }
                }
            }
            finally {
                if ($shellItem -is [__ComObject]) {
                    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shellItem)
                }
            }
        }
        if ($pinned) {
            if ($LogWriter) {
                Write-LabLog -Message "Pinned $DisplayName to the taskbar." -LogWriter $LogWriter
            }
            return $true
        }

        if ($attempt -lt $retries) {
            Start-Sleep -Seconds $delay
        }
    }

    $message = "Failed to pin $DisplayName to the taskbar."
    if ($LogWriter) {
        Write-LabLog -Message $message -LogWriter $LogWriter
    } else {
        Write-Warning $message
    }
    return $false
}

function Get-WingetInstallPrecheckResult {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Package,
        [Parameter(Mandatory)]
        [string]$LogRoot,
        [System.IO.StreamWriter]$LogWriter
    )

    $id = $Package.id
    $sanitizedId = ($id -replace '[^A-Za-z0-9_.-]', '_')
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
    $logPath = Join-Path -Path $LogRoot -ChildPath ("{0}_precheck_{1}.log" -f $sanitizedId, $timestamp)

    $arguments = @(
        'upgrade',
        '--id', $id,
        '--exact',
        '--accept-package-agreements',
        '--accept-source-agreements'
    )

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

    $wingetLogRoot = $null
    if ($Config -and $Config.programDataPath) {
        $wingetLogRoot = Join-Path -Path $Config.programDataPath -ChildPath 'logs\winget'
    } else {
        $wingetLogRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'LabSetupWinget'
    }
    New-LabDirectory -Path $wingetLogRoot

    $alwaysInstall = [bool](Get-OptionalPropertyValue -InputObject $Package -PropertyName 'alwaysInstall')
    $skipUpgradePrecheck = [bool](Get-OptionalPropertyValue -InputObject $Package -PropertyName 'skipUpgradePrecheck')
    $precheckStatus = 'Unknown'
    if (-not $alwaysInstall -and -not $skipUpgradePrecheck) {
        $precheckStatus = Get-WingetInstallPrecheckResult -Package $Package -LogRoot $wingetLogRoot -LogWriter $LogWriter
        if ($precheckStatus -in @('UpToDate', 'AlreadyInstalled')) {
            Write-LabLog -Message "$displayName is already at the latest version; skipping winget install." -LogWriter $LogWriter
            return
        }
    }

    $baseArgs = @(
        'install',
        '--id', $id,
        '--exact',
        '--accept-package-agreements',
        '--accept-source-agreements'
    )

    $scope = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'scope'
    if ([string]::IsNullOrWhiteSpace($scope)) {
        $scope = 'machine'
    }
    $declaredVersion = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'version'
    if ($declaredVersion) {
        $baseArgs += @('--version', $declaredVersion)
    }

    $overrideArgs = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'override'
    if ($overrideArgs) {
        $baseArgs += @('--override', $overrideArgs)
    }

    $scopeCandidates = @()
    $requestedScope = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'scope'
    if ($requestedScope -is [System.Collections.IEnumerable] -and -not ($requestedScope -is [string])) {
        foreach ($scopeValue in $requestedScope) {
            if (-not [string]::IsNullOrWhiteSpace($scopeValue)) {
                $scopeCandidates += $scopeValue.ToLowerInvariant()
            }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($requestedScope)) {
        $scopeCandidates += $requestedScope.ToLowerInvariant()
    }

    if (-not $scopeCandidates -or $scopeCandidates.Count -eq 0) {
        $scopeCandidates = @('machine')
    }
    elseif (($scopeCandidates -contains 'user') -and -not ($scopeCandidates -contains 'machine')) {
        # Favor per-user installs when requested, but fail over to machine installers if user scope is unavailable.
        $scopeCandidates += 'machine'
    }
    $scopeCandidates = @($scopeCandidates | Select-Object -Unique)

    $expectedExitCodes = @(
        $script:WingetExitCodes.UpdateNotApplicable,
        $script:WingetExitCodes.UpgradeVersionNotNewer,
        $script:WingetExitCodes.PackageAlreadyInstalled,
        $script:WingetExitCodes.NoApplicableInstaller
    )

    $silentFlag = [bool](Get-OptionalPropertyValue -InputObject $Package -PropertyName 'silent')
    $installAttempts = @()
    if ($silentFlag) {
        $installAttempts += @{
            Name      = 'silent'
            ExtraArgs = @('--silent')
            Message   = 'silent'
        }
    }
    $installAttempts += @{
        Name      = 'interactive'
        ExtraArgs = @()
        Message   = 'interactive'
    }

    Write-LabLog -Message "Installing $displayName ($id) via winget..." -LogWriter $LogWriter

    :ScopeAttempt for ($scopeIndex = 0; $scopeIndex -lt $scopeCandidates.Count; $scopeIndex++) {
        $currentScope = $scopeCandidates[$scopeIndex]
        $scopeArgs = @('--scope', $currentScope)
        if ($scopeCandidates.Count -gt 1) {
            Write-LabLog -Message "Attempting $displayName install with scope '$currentScope'." -LogWriter $LogWriter
        }

        :InstallAttempt foreach ($attempt in $installAttempts) {
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
            $logPath = Join-Path -Path $wingetLogRoot -ChildPath ("{0}_{1}_{2}.log" -f $sanitizedId, $attempt.Name, $timestamp)
            $arguments = @($baseArgs + $scopeArgs + $attempt.ExtraArgs)
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
            }

            $message = "winget failed to install $displayName (exit code $($result.ExitCode)). Review $($result.LogPath) for details."
            throw $message
        }
    }

    throw "winget failed to install $displayName after exhausting available scopes and install modes."
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
        if ($command.Parameters.ContainsKey('AllowInsecureRedirect')) {
            $invokeParameters['AllowInsecureRedirect'] = $true
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
            $process = Invoke-ProcessWithSpinner -FilePath $msiExec -ArgumentList $msiArgs -Activity "Installing $($Package.displayName) via msiexec"
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

function Install-LabPackages {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    $packages = @()
    if ($Config.wingetPackages) {
        $packages = @($Config.wingetPackages | ForEach-Object { $_ })
    }

    $total = $packages.Count
    if ($total -eq 0) { return }

    $progressActivity = 'Installing lab packages'
    $index = 0

    foreach ($package in $packages) {
        $index++
        $statusLabel = if ($package.displayName) { "Processing $($package.displayName)" } else { "Processing package $index of $total" }
        $percentComplete = [math]::Floor((($index - 1) / [double]$total) * 100)
        Write-Progress -Activity $progressActivity -Status $statusLabel -PercentComplete $percentComplete -Id 2001

        $hasInstallerMetadata = $false
        if ($package -is [System.Collections.IDictionary] -and $package.ContainsKey('installer')) {
            $installerMetadata = $package['installer']
            $hasInstallerMetadata = $null -ne $installerMetadata
        }

        if ($hasInstallerMetadata) {
            Install-ManualPackage -Package $package -Config $Config -LogWriter $LogWriter
        } else {
            Install-WingetPackage -Package $package -LogWriter $LogWriter -Config $Config
        }
    }

    Write-Progress -Activity $progressActivity -Completed -Id 2001
}

function Set-LabTaskbarPins {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
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

        Set-TaskbarPin -DisplayName $package.displayName -Config $Config -CandidatePaths $candidatePaths -AppId $appId -ShortcutName $shortcutName -LogWriter $LogWriter | Out-Null
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
        $nodeProcess = Invoke-ProcessWithSpinner -FilePath $voltaExe -ArgumentList $nodeArgs -Activity "Configuring Volta Node $($Config.volta.nodeVersion)"
        if ($nodeProcess.ExitCode -ne 0) {
            throw "Volta failed to install Node $($Config.volta.nodeVersion)."
        }
    }

    if ($Config.volta.globalPackages) {
        foreach ($pkg in $Config.volta.globalPackages) {
            Write-LabLog -Message "Installing global Volta package $pkg ..." -LogWriter $LogWriter
            $pkgProcess = Invoke-ProcessWithSpinner -FilePath $voltaExe -ArgumentList @('install', $pkg) -Activity "Installing Volta package $pkg"
            if ($pkgProcess.ExitCode -ne 0) {
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
            Write-LabLog -Message "Installing Python $version via uv..." -LogWriter $LogWriter
            $pythonShim = Join-Path -Path $uvBin -ChildPath ("python{0}.exe" -f $version)
            if (Test-Path -LiteralPath $pythonShim -PathType Leaf) {
                Write-LabLog -Message "Python $version already provisioned in uv bin directory; skipping install." -LogWriter $LogWriter
                continue
            }

            $uvArgs = @('python', 'install', $version, '--install-dir', $uvPythonRoot, '--force')
            $uvProcess = Invoke-ProcessWithSpinner -FilePath $uvExe -ArgumentList $uvArgs -Activity "Installing Python $version via uv"
            if ($uvProcess.ExitCode -ne 0) {
                throw "uv failed to install Python $version (exit code $($uvProcess.ExitCode))."
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
            Install-WingetPackage -Package $miktexPackage -LogWriter $LogWriter -Config $Config
            $initexmf = Resolve-ExecutableFromCandidates -Candidates $initexmfCandidates
            $mpmExe = Resolve-ExecutableFromCandidates -Candidates $mpmCandidates
        }
    }

    if (-not $initexmf -or -not $mpmExe) {
        $installedWithBootstrap = Install-MikTexFromInstaller -Config $Config -TexConfig $Config.tex -LogWriter $LogWriter
        if ($installedWithBootstrap) {
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
        $autoInstallProcess = Invoke-ProcessWithSpinner -FilePath $initexmf -ArgumentList @('--admin', '--set-config-value', '[MPM]AutoInstall=1') -Activity 'Enabling MiKTeX automatic package installation (admin)...'
        if ($autoInstallProcess.ExitCode -ne 0) {
            throw 'initexmf failed to set AutoInstall for MiKTeX.'
        }
    }

    if ($Config.tex.refreshFileDatabase) {
        Write-LabLog -Message 'Refreshing MiKTeX filename database (admin)...' -LogWriter $LogWriter
        $refreshProcess = Invoke-ProcessWithSpinner -FilePath $initexmf -ArgumentList @('--admin', '--update-fndb') -Activity 'Refreshing MiKTeX filename database (admin)...'
        if ($refreshProcess.ExitCode -ne 0) {
            throw 'initexmf failed to refresh the MiKTeX FNDB.'
        }
    }
}

Export-ModuleMember -Function *-*

