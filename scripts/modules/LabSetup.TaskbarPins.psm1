$script:LabAppxIconCache = @{}

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
        if (Test-LabTaskbarPinnedState -CandidatePaths $CandidatePaths -AppId $AppId -ShortcutName $ShortcutName -DisplayName $DisplayName) {
            if ($LogWriter) {
                Write-LabLog -Message "Pinned $DisplayName to the taskbar." -LogWriter $LogWriter
            }
            return $true
        }

        $shellItems = Get-LabTaskbarShellItems -CandidatePaths $CandidatePaths -AppId $AppId -ShortcutName $ShortcutName -DisplayName $DisplayName
        $shellItemList = New-Object System.Collections.Generic.List[object]

        if ($null -ne $shellItems) {
            if ($shellItems -is [System.Collections.IEnumerable] -and -not ($shellItems -is [string])) {
                foreach ($item in $shellItems) {
                    if ($null -ne $item) {
                        [void]$shellItemList.Add($item)
                    }
                }
            }
            else {
                [void]$shellItemList.Add($shellItems)
            }
        }

        if ($shellItemList.Count -eq 0) {
            if ($attempt -lt $retries) {
                if ($LogWriter) {
                    Write-LabLog -Message "Unable to locate a taskbar target for $DisplayName (attempt $attempt of $retries); retrying in $delay seconds." -LogWriter $LogWriter
                }
                Start-Sleep -Seconds $delay
                continue
            }
            break
        }

        $pinTriggered = $false
        for ($i = 0; $i -lt $shellItemList.Count; $i++) {
            $shellItem = $shellItemList[$i]
            if (-not $shellItem) { continue }

            if (Invoke-TaskbarVerb -ShellItem $shellItem -VerbName 'taskbarpin') {
                $pinTriggered = $true
                break
            }
        }

        foreach ($shellItem in $shellItemList) {
            if ($shellItem -is [__ComObject]) {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shellItem)
            }
        }

        if ($pinTriggered) {
            Start-Sleep -Seconds 1
            if (Test-LabTaskbarPinnedState -CandidatePaths $CandidatePaths -AppId $AppId -ShortcutName $ShortcutName -DisplayName $DisplayName) {
                if ($LogWriter) {
                    Write-LabLog -Message "Pinned $DisplayName to the taskbar." -LogWriter $LogWriter
                }
                return $true
            }
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

function Get-OrderedTaskbarCandidates {
    param(
        [string[]]$Paths
    )

    if (-not $Paths) {
        return @()
    }

    $priority = @{
        '.lnk'        = 0
        '.exe'        = 1
        '.appref-ms'  = 2
        '.url'        = 3
        '.msix'       = 4
        '.msixbundle' = 4
        '.appx'       = 4
        '.appxbundle' = 4
        '.bat'        = 6
        '.cmd'        = 6
        '.ps1'        = 7
    }

    $indexed = @()
    for ($i = 0; $i -lt $Paths.Count; $i++) {
        $current = $Paths[$i]
        $extension = $null
        try {
            $extension = [System.IO.Path]::GetExtension($current)
        }
        catch {
            $extension = $null
        }
        $normalized = if ($extension) { $extension.ToLowerInvariant() } else { '' }
        $score = if ($priority.ContainsKey($normalized)) { $priority[$normalized] } else { 5 }
        $indexed += [pscustomobject]@{
            Path  = $current
            Score = $score
            Index = $i
        }
    }

    return @(
        $indexed | Sort-Object -Property @{ Expression = { $_.Score } }, @{ Expression = { $_.Index } } | ForEach-Object { $_.Path }
    )
}

function Get-LabAppxShortcutIcon {
    param(
        [string]$AppId,
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    if ([string]::IsNullOrWhiteSpace($AppId)) {
        return $null
    }
    if ($AppId -notmatch '!') {
        return $null
    }

    if ($script:LabAppxIconCache.ContainsKey($AppId)) {
        return $script:LabAppxIconCache[$AppId]
    }

    $packageFamily = $AppId.Split('!')[0]
    if ([string]::IsNullOrWhiteSpace($packageFamily)) {
        $script:LabAppxIconCache[$AppId] = $null
        return $null
    }

    $package = $null
    $packageName = $null
    $separatorIndex = $packageFamily.LastIndexOf('_')
    if ($separatorIndex -gt 0 -and $separatorIndex -lt ($packageFamily.Length - 1)) {
        $packageName = $packageFamily.Substring(0, $separatorIndex)
    }

    if ($packageName) {
        try {
            $candidates = Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue
            if ($candidates) {
                $package = ($candidates | Where-Object { $_.PackageFamilyName -eq $packageFamily } | Select-Object -First 1)
            }
        }
        catch {
            $package = $null
        }
    }

    if (-not $package) {
        try {
            $package = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.PackageFamilyName -eq $packageFamily } | Select-Object -First 1
        }
        catch {
            $package = $null
        }
    }

    if (-not $package) {
        if ($LogWriter) {
            Write-LabLog -Message ("Unable to locate AppX package for {0}; ensure the application is installed." -f $AppId) -LogWriter $LogWriter
        }
        $script:LabAppxIconCache[$AppId] = $null
        return $null
    }

    $installLocation = $package.InstallLocation
    if ([string]::IsNullOrWhiteSpace($installLocation) -or -not (Test-Path -LiteralPath $installLocation -PathType Container)) {
        $script:LabAppxIconCache[$AppId] = $null
        return $null
    }

    $searchRoots = @(
        (Join-Path -Path $installLocation -ChildPath 'Images'),
        (Join-Path -Path $installLocation -ChildPath 'Assets'),
        $installLocation
    )

    $iconSource = $null
    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try {
            $icons = Get-ChildItem -LiteralPath $root -Filter '*.ico' -Recurse -ErrorAction SilentlyContinue
        }
        catch {
            $icons = @()
        }

        if ($icons -and $icons.Count -gt 0) {
            $iconSource = ($icons | Sort-Object Length -Descending | Select-Object -First 1)
            if ($iconSource) { break }
        }
    }

    if (-not $iconSource) {
        $script:LabAppxIconCache[$AppId] = $null
        return $null
    }

    $iconPath = $iconSource.FullName
    if ($Config -and $Config.programDataPath) {
        $iconRoot = Join-Path -Path $Config.programDataPath -ChildPath 'TaskbarIcons'
        try {
            New-LabDirectory -Path $iconRoot
            $safeName = ($package.PackageFullName -replace '[^A-Za-z0-9._-]', '_')
            if ([string]::IsNullOrWhiteSpace($safeName)) {
                $safeName = 'AppxIcon'
            }
            $destination = Join-Path -Path $iconRoot -ChildPath ("{0}.ico" -f $safeName)
            Copy-Item -LiteralPath $iconPath -Destination $destination -Force
            $iconPath = $destination
        }
        catch {
            if ($LogWriter) {
                Write-LabLog -Message ("Unable to cache icon for {0}: {1}" -f $AppId, $_.Exception.Message) -LogWriter $LogWriter
            }
        }
    }

    $script:LabAppxIconCache[$AppId] = $iconPath
    return $iconPath
}

function Resolve-LabShortcutPath {
    param(
        [string]$PreferredName,
        [string]$DisplayName,
        [string[]]$CandidatePaths = @(),
        [ValidateSet('Never', 'WhenMissing', 'Always')]
        [string]$CreationPolicy = 'WhenMissing',
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter,
        [string]$AppId
    )

    $names = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($PreferredName)) {
        [void]$names.Add($PreferredName)
    }
    if (-not [string]::IsNullOrWhiteSpace($DisplayName) -and -not $names.Contains($DisplayName)) {
        [void]$names.Add($DisplayName)
    }

    foreach ($name in $names) {
        $existing = Get-StartMenuShortcutPath -ShortcutName $name
        if ($existing) {
            return $existing
        }
    }

    if ($CreationPolicy -eq 'Never' -or -not $CandidatePaths -or $CandidatePaths.Count -eq 0) {
        return $null
    }

    $shortcutLabel = if (-not [string]::IsNullOrWhiteSpace($PreferredName)) {
        $PreferredName
    }
    elseif (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
        $DisplayName
    }
    else {
        'LabShortcut'
    }

    $normalizedCandidates = @($CandidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $shellAppId = $null
    foreach ($candidate in $normalizedCandidates) {
        $candidateAppId = Get-LabAppUserModelIdFromText -InputText $candidate
        if (-not [string]::IsNullOrWhiteSpace($candidateAppId)) {
            $shellAppId = $candidateAppId
            break
        }
    }

    $useAppxShortcut = $false
    if (-not [string]::IsNullOrWhiteSpace($shellAppId)) {
        $useAppxShortcut = $true
    }
    elseif (-not [string]::IsNullOrWhiteSpace($AppId) -and $AppId -match '!') {
        $shellAppId = $AppId
        $useAppxShortcut = $true
    }

    $effectiveAppId = if (-not [string]::IsNullOrWhiteSpace($AppId)) { $AppId } else { $shellAppId }

    if ($useAppxShortcut -and $shellAppId) {
        $windowsRoot = $env:SystemRoot
        if ([string]::IsNullOrWhiteSpace($windowsRoot)) {
            $windowsRoot = $env:WINDIR
        }
        if ([string]::IsNullOrWhiteSpace($windowsRoot)) {
            $windowsRoot = 'C:\Windows'
        }

        $explorerCandidates = @(
            (Join-Path -Path $windowsRoot -ChildPath 'explorer.exe'),
            '%SystemRoot%\explorer.exe'
        )

        $explorerPath = Resolve-ExecutableFromCandidates -Candidates $explorerCandidates
        if (-not $explorerPath) {
            if ($LogWriter) {
                Write-LabLog -Message "Unable to resolve explorer.exe while creating shortcut for $DisplayName." -LogWriter $LogWriter
            }
            return $null
        }

        $nonShellCandidates = @(
            $normalizedCandidates | Where-Object { $_ -notmatch '(?i)^shell:appsfolder\\' }
        )
        $iconPath = Get-LabAppxShortcutIcon -AppId $effectiveAppId -Config $Config -LogWriter $LogWriter
        if (-not $iconPath -and $nonShellCandidates -and $nonShellCandidates.Count -gt 0) {
            $iconPath = Resolve-ExecutableFromCandidates -Candidates $nonShellCandidates
        }
        if (-not $iconPath) {
            $iconPath = $explorerPath
        }

        $shellArgument = "shell:AppsFolder\{0}" -f $shellAppId
        try {
            return New-LabTaskbarShortcut -DisplayName $shortcutLabel -ExecutablePath $explorerPath -Arguments $shellArgument -AppId $effectiveAppId -IconPath $iconPath -Config $Config
        }
        catch {
            if ($LogWriter) {
                Write-LabLog -Message ("Unable to create shell shortcut for {0}: {1}" -f $DisplayName, $_.Exception.Message) -LogWriter $LogWriter
            }
            return $null
        }
    }

    $target = Resolve-ExecutableFromCandidates -Candidates $normalizedCandidates
    if (-not $target) {
        if ($LogWriter) {
            Write-LabLog -Message "Unable to resolve shortcut target for $DisplayName while processing taskbar metadata." -LogWriter $LogWriter
        }
        return $null
    }

    try {
        return New-LabTaskbarShortcut -DisplayName $shortcutLabel -ExecutablePath $target -AppId $effectiveAppId -Config $Config
    }
    catch {
        if ($LogWriter) {
            Write-LabLog -Message ("Unable to create shortcut for {0}: {1}" -f $DisplayName, $_.Exception.Message) -LogWriter $LogWriter
        }
        return $null
    }
}

function Get-LabAppUserModelIdFromText {
    param(
        [string]$InputText
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) {
        return $null
    }

    $prefix = 'shell:appsfolder\'
    $startIndex = $InputText.IndexOf($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    if ($startIndex -lt 0) {
        return $null
    }

    $startIndex += $prefix.Length
    if ($startIndex -ge $InputText.Length) {
        return $null
    }

    $remaining = $InputText.Substring($startIndex)
    $terminators = @('"', "'", ' ', "`t", "`r", "`n", '>')
    $endIndex = $remaining.Length
    foreach ($terminator in $terminators) {
        $position = $remaining.IndexOf($terminator)
        if ($position -ge 0 -and $position -lt $endIndex) {
            $endIndex = $position
        }
    }

    $value = $remaining.Substring(0, $endIndex)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value.Trim('"', "'")
}

function Get-LabAppUserModelIdFromShortcut {
    param(
        [string]$TargetPath,
        [string]$Arguments
    )

    foreach ($candidate in @($Arguments, $TargetPath)) {
        $appId = Get-LabAppUserModelIdFromText -InputText $candidate
        if (-not [string]::IsNullOrWhiteSpace($appId)) {
            return $appId
        }
    }

    return $null
}

function Get-LabExistingTaskbarPins {
    param(
        [System.IO.StreamWriter]$LogWriter
    )

    $results = New-Object System.Collections.Generic.List[pscustomobject]
    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) {
        return $results.ToArray()
    }

    $pinnedRoot = Join-Path -Path $appData -ChildPath 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    if (-not (Test-Path -LiteralPath $pinnedRoot -PathType Container)) {
        return $results.ToArray()
    }

    try {
        $shortcuts = Get-ChildItem -Path $pinnedRoot -File -ErrorAction Stop
    }
    catch {
        if ($LogWriter) {
            Write-LabLog -Message ("Unable to inspect existing taskbar pins: {0}" -f $_.Exception.Message) -LogWriter $LogWriter
        }
        return $results.ToArray()
    }

    if (-not $shortcuts -or $shortcuts.Count -eq 0) {
        return $results.ToArray()
    }

    $wscript = $null
    try {
        $wscript = New-Object -ComObject WScript.Shell
    }
    catch {
        $wscript = $null
        if ($LogWriter) {
            Write-LabLog -Message ("Unable to read shortcut metadata while preserving taskbar pins: {0}" -f $_.Exception.Message) -LogWriter $LogWriter
        }
    }

    foreach ($shortcut in $shortcuts) {
        if (-not $shortcut) { continue }

        $candidatePaths = New-Object System.Collections.Generic.List[string]
        $dedupe = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        $displayName = $shortcut.BaseName
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = [System.IO.Path]::GetFileNameWithoutExtension($shortcut.Name)
        }

        $pathsToAdd = New-Object System.Collections.Generic.List[string]
        $pathsToAdd.Add($shortcut.FullName)

        $targetPath = $null
        $arguments = $null
        if ($wscript) {
            $shortcutCom = $null
            try {
                $shortcutCom = $wscript.CreateShortcut($shortcut.FullName)
                $targetPath = $shortcutCom.TargetPath
                $arguments = $shortcutCom.Arguments
            }
            catch {
                $targetPath = $null
                $arguments = $null
            }
            finally {
                if ($shortcutCom -is [__ComObject]) {
                    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcutCom)
                }
            }
        }

        if ($targetPath) {
            $pathsToAdd.Add($targetPath)
        }

        foreach ($candidate in $pathsToAdd) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
            if ($dedupe.Add($expanded)) {
                [void]$candidatePaths.Add($expanded)
            }
        }

        $appId = Get-LabAppUserModelIdFromShortcut -TargetPath $targetPath -Arguments $arguments
        if ($candidatePaths.Count -eq 0 -and [string]::IsNullOrWhiteSpace($appId)) {
            if ($LogWriter) {
                Write-LabLog -Message ("Skipping preservation for {0}; unable to resolve a shortcut target or appUserModelId." -f $displayName) -LogWriter $LogWriter
            }
            continue
        }

        $results.Add([pscustomobject]@{
            DisplayName    = $displayName
            AppId          = $appId
            CandidatePaths = $candidatePaths.ToArray()
            ShortcutName   = $shortcut.BaseName
            ShortcutPath   = $null
            ForceShortcut  = $false
            Mode           = 'Pin'
            PinMode        = 'Pin'
        })
    }

    if ($wscript -is [__ComObject]) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wscript)
    }

    return $results.ToArray()
}

function Get-LabTaskbarRequestIdentity {
    param(
        [Parameter(Mandatory)]
        $Request
    )

    if (-not $Request) {
        return [guid]::NewGuid().ToString()
    }

    $appIdProperty = $Request.PSObject.Properties['AppId']
    if ($appIdProperty) {
        $appId = $appIdProperty.Value
        if ($appId) {
            $appIdString = $appId.ToString()
            if (-not [string]::IsNullOrWhiteSpace($appIdString)) {
                return "appId::{0}" -f $appIdString.ToLowerInvariant()
            }
        }
    }

    $shortcutProperty = $Request.PSObject.Properties['ShortcutPath']
    if ($shortcutProperty) {
        $shortcutPath = $shortcutProperty.Value
        if ($shortcutPath) {
            $shortcutString = $shortcutPath.ToString()
            if (-not [string]::IsNullOrWhiteSpace($shortcutString)) {
                return "shortcut::{0}" -f $shortcutString.ToLowerInvariant()
            }
        }
    }

    $candidateProperty = $Request.PSObject.Properties['CandidatePaths']
    if ($candidateProperty -and $candidateProperty.Value) {
        foreach ($candidate in $candidateProperty.Value) {
            if ($candidate) {
                $candidateString = $candidate.ToString()
                if (-not [string]::IsNullOrWhiteSpace($candidateString)) {
                    return "candidate::{0}" -f $candidateString.ToLowerInvariant()
                }
            }
        }
    }

    $displayProperty = $Request.PSObject.Properties['DisplayName']
    if ($displayProperty) {
        $displayName = $displayProperty.Value
        if ($displayName) {
            $displayString = $displayName.ToString()
            if (-not [string]::IsNullOrWhiteSpace($displayString)) {
                return "display::{0}" -f $displayString.ToLowerInvariant()
            }
        }
    }

    return "guid::{0}" -f ([guid]::NewGuid().ToString())
}

function Merge-LabTaskbarRequests {
    param(
        [pscustomobject[]]$Primary,
        [pscustomobject[]]$Secondary
    )

    $result = New-Object System.Collections.Generic.List[pscustomobject]
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($request in @($Primary) + @($Secondary)) {
        if (-not $request) { continue }
        $key = Get-LabTaskbarRequestIdentity -Request $request
        if ($seen.Add($key)) {
            [void]$result.Add($request)
        }
    }

    return $result.ToArray()
}

function Get-LabTaskbarPinRequest {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Package,
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [ValidateSet('Pin', 'Layout')]
        [string]$Mode = 'Pin',
        [System.IO.StreamWriter]$LogWriter
    )

    $displayName = $Package.displayName
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $displayName = $Package.id
    }

    if ([string]::IsNullOrWhiteSpace($displayName)) {
        if ($LogWriter) {
            Write-LabLog -Message 'Skipping taskbar pin metadata without a display name or id.' -LogWriter $LogWriter
        }
        return $null
    }

    $appId = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'appUserModelId'

    $candidatePaths = @()
    if ($Package.ContainsKey('taskbarTargets') -and $Package['taskbarTargets']) {
        $candidatePaths = @($Package['taskbarTargets'] | ForEach-Object { $_ })
    }
    if ($candidatePaths.Count -gt 1) {
        $candidatePaths = Get-OrderedTaskbarCandidates -Paths $candidatePaths
    }

    $shortcutName = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'taskbarShortcutName'
    if ([string]::IsNullOrWhiteSpace($shortcutName)) {
        $shortcutName = $displayName
    }

    $forceShortcut = [bool](Get-OptionalPropertyValue -InputObject $Package -PropertyName 'taskbarForceShortcut')
    if (-not $forceShortcut -and $candidatePaths.Count -gt 0) {
        foreach ($candidate in $candidatePaths) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

            if ($candidate -match '^(?i)shell:appsfolder\\') {
                if ([string]::IsNullOrWhiteSpace($appId)) {
                    $forceShortcut = $true
                    break
                }
                continue
            }

            $extension = $null
            try {
                $extension = [System.IO.Path]::GetExtension($candidate)
            }
            catch {
                $extension = $null
            }
            if ([string]::IsNullOrWhiteSpace($extension)) {
                $forceShortcut = $true
                break
            }
            $normalizedExtension = $extension.ToLowerInvariant()
            if ($normalizedExtension -notin @('.exe', '.lnk', '.appref-ms', '.url', '.msix', '.msixbundle', '.appx', '.appxbundle')) {
                $forceShortcut = $true
                break
            }
        }
    }

    $creationPolicy = switch ($Mode) {
        'Pin'    { if ($forceShortcut) { 'Always' } else { 'Never' } }
        default  { 'WhenMissing' }
    }

    $shortcutPath = Resolve-LabShortcutPath -PreferredName $shortcutName -DisplayName $displayName -CandidatePaths $candidatePaths -CreationPolicy $creationPolicy -Config $Config -LogWriter $LogWriter -AppId $appId

    if ($Mode -eq 'Pin' -and $forceShortcut -and -not $shortcutPath -and $LogWriter) {
        Write-LabLog -Message "taskbarForceShortcut was set for $displayName but no shortcut could be generated." -LogWriter $LogWriter
    }

    if ($shortcutPath) {
        try {
            $shortcutName = Split-Path -Path $shortcutPath -Leaf
        }
        catch {
            # Reuse the original name if the leaf cannot be determined.
        }
    }

    $orderedCandidates = New-Object System.Collections.Generic.List[string]
    $dedupe = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($path in @($shortcutPath) + $candidatePaths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($dedupe.Add($path)) {
            [void]$orderedCandidates.Add($path)
        }
    }

    $pinModeValue = 'Shell'
    $pinModeRaw = Get-OptionalPropertyValue -InputObject $Package -PropertyName 'taskbarPinMode'
    if ($pinModeRaw) {
        $normalizedPinMode = $pinModeRaw.ToString().Trim().ToLowerInvariant()
        if ($normalizedPinMode -in @('layout', 'layoutonly')) {
            $pinModeValue = 'Layout'
        }
    }

    return [pscustomobject]@{
        Package        = $Package
        DisplayName    = $displayName
        AppId          = $appId
        CandidatePaths = $orderedCandidates.ToArray()
        ShortcutName   = $shortcutName
        ShortcutPath   = $shortcutPath
        ForceShortcut  = $forceShortcut
        Mode           = $Mode
        PinMode        = $pinModeValue
    }
}

function Set-LabTaskbarPins {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter,
        [pscustomobject[]]$PreservedPins = @()
    )

    $pinRequests = New-Object System.Collections.Generic.List[pscustomobject]
    $failedPinCount = 0
    $layoutRequests = New-Object System.Collections.Generic.List[pscustomobject]
    $layoutOnlyCount = 0

    if ($PreservedPins) {
        $PreservedPins = @($PreservedPins | Where-Object { $_ })
    }
    else {
        $PreservedPins = @()
    }

    foreach ($package in $Config.wingetPackages) {
        $pinToTaskbar = $false
        if ($package -is [System.Collections.IDictionary] -and $package.ContainsKey('pinToTaskbar')) {
            $pinToTaskbar = [bool]$package['pinToTaskbar']
        }

        if (-not $pinToTaskbar) { continue }

        $pinRequest = Get-LabTaskbarPinRequest -Package $package -Config $Config -Mode 'Pin' -LogWriter $LogWriter
        if (-not $pinRequest) { continue }

        [void]$pinRequests.Add($pinRequest)

        $requiresLayoutMode = ($pinRequest.PinMode -eq 'Layout')
        if ($requiresLayoutMode) {
            $alreadyPinned = $false
            try {
                $alreadyPinned = Test-LabTaskbarPinnedState -CandidatePaths $pinRequest.CandidatePaths -AppId $pinRequest.AppId -ShortcutName $pinRequest.ShortcutName -DisplayName $pinRequest.DisplayName
            }
            catch {
                $alreadyPinned = $false
            }

            if ($alreadyPinned) {
                if ($LogWriter) {
                    Write-LabLog -Message "$($pinRequest.DisplayName) already satisfies the layout-only taskbar pin requirement; skipping layout update." -LogWriter $LogWriter
                }
            }
            else {
                if ($LogWriter) {
                    Write-LabLog -Message "$($pinRequest.DisplayName) requires layout-only taskbar pinning; queuing LayoutModification fallback." -LogWriter $LogWriter
                }
                [void]$layoutRequests.Add($pinRequest)
                $layoutOnlyCount++
            }
            continue
        }

        $pinSucceeded = $false
        try {
            $pinSucceeded = Set-TaskbarPin -DisplayName $pinRequest.DisplayName -Config $Config -CandidatePaths $pinRequest.CandidatePaths -AppId $pinRequest.AppId -ShortcutName $pinRequest.ShortcutName -LogWriter $LogWriter
        }
        catch {
            $pinSucceeded = $false
            if ($LogWriter) {
                Write-LabLog -Message "Taskbar pin attempt for $($pinRequest.DisplayName) threw an exception: $($_.Exception.Message)" -LogWriter $LogWriter
            }
        }

        if (-not $pinSucceeded) {
            $failedPinCount++
            [void]$layoutRequests.Add($pinRequest)
        }
    }

    if ($layoutRequests.Count -gt 0 -and $pinRequests.Count -gt 0) {
        $reasons = New-Object System.Collections.Generic.List[string]
        if ($layoutOnlyCount -gt 0) {
            $reasons.Add("{0} layout-only pin(s)" -f $layoutOnlyCount)
        }
        if ($failedPinCount -gt 0) {
            $reasons.Add("{0} failed pin attempt(s)" -f $failedPinCount)
        }
        $reasonText = if ($reasons.Count -gt 0) { $reasons -join ' and ' } else { 'taskbar layout requirements' }
        Write-LabLog -Message ("Applying LayoutModification fallback ({0})." -f $reasonText) -LogWriter $LogWriter

        $layoutInputs = $pinRequests.ToArray()
        if ($PreservedPins -and $PreservedPins.Count -gt 0) {
            $layoutInputs = Merge-LabTaskbarRequests -Primary $layoutInputs -Secondary $PreservedPins
            Write-LabLog -Message ("Preserving {0} existing taskbar pin(s) during layout fallback." -f $PreservedPins.Count) -LogWriter $LogWriter
        }

        $layoutApplied = Set-LabTaskbarLayout -Config $Config -TaskbarRequests $layoutInputs -LogWriter $LogWriter
        if ($layoutApplied) {
            Write-LabLog -Message 'Applied LayoutModification fallback and reset Explorer to enforce taskbar pins.' -LogWriter $LogWriter
        }
        else {
            Write-LabLog -Message 'Unable to apply LayoutModification fallback; taskbar pins may be incomplete.' -LogWriter $LogWriter
        }
    }
}
