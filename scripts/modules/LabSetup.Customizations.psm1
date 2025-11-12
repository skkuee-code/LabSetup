function Resolve-LabPathCandidates {
    param(
        [string[]]$Candidates
    )

    $results = New-Object System.Collections.Generic.List[string]
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not $Candidates) {
        return $results.ToArray()
    }

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $trimmed = $candidate.Trim()

        if ($trimmed -match '^(?i)shell:') {
            if ($seen.Add($trimmed)) {
                [void]$results.Add($trimmed)
            }
            continue
        }

        $expanded = [Environment]::ExpandEnvironmentVariables($trimmed)
        $hasWildcard = ($expanded.IndexOf('*') -ge 0) -or ($expanded.IndexOf('?') -ge 0)

        if ($hasWildcard) {
            try {
                $pathMatches = Get-ChildItem -Path $expanded -File -ErrorAction SilentlyContinue
                foreach ($pathMatch in $pathMatches) {
                    if ($pathMatch -and $seen.Add($pathMatch.FullName)) {
                        [void]$results.Add($pathMatch.FullName)
                    }
                }
            }
            catch {
                # Ignore wildcard failures and continue.
            }
            continue
        }

        try {
            if (Test-Path -LiteralPath $expanded -PathType Leaf) {
                $resolved = (Resolve-Path -LiteralPath $expanded -ErrorAction Stop).Path
                if ($seen.Add($resolved)) {
                    [void]$results.Add($resolved)
                }
            }
        }
        catch {
            # Ignore resolution failures for individual candidates.
        }
    }

    $resolved = $results.ToArray()
    # Force array semantics so single results aren't unwrapped into char arrays later.
    return ,$resolved
}

function Get-LabPublicDesktopPath {
    param(
        [hashtable]$Config
    )

    $explicit = Get-OptionalPropertyValue -InputObject $Config -PropertyName 'publicDesktopPath'
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        return [Environment]::ExpandEnvironmentVariables($explicit)
    }

    try {
        $commonDesktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
        if (-not [string]::IsNullOrWhiteSpace($commonDesktop)) {
            return $commonDesktop
        }
    }
    catch {
        # Fall through to environment-based defaults.
    }

    if ($env:PUBLIC) {
        return (Join-Path -Path $env:PUBLIC -ChildPath 'Desktop')
    }

    return 'C:\Users\Public\Desktop'
}

function Set-LabDesktopShortcuts {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    $entries = @()
    if ($Config.publicDesktopShortcuts) {
        $entries = @($Config.publicDesktopShortcuts | ForEach-Object { $_ })
    }
    if ($entries.Count -eq 0) { return }

    $desktopPath = Get-LabPublicDesktopPath -Config $Config
    try {
        New-LabDirectory -Path $desktopPath
    }
    catch {
        Write-LabLog -Message ("Unable to access public desktop at {0}: {1}" -f $desktopPath, $_.Exception.Message) -LogWriter $LogWriter
        return
    }

    foreach ($entry in $entries) {
        if (-not ($entry -is [System.Collections.IDictionary])) { continue }

        $name = Get-OptionalPropertyValue -InputObject $entry -PropertyName 'name'
        $displayName = Get-OptionalPropertyValue -InputObject $entry -PropertyName 'displayName'
        if ([string]::IsNullOrWhiteSpace($name)) {
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                Write-LabLog -Message 'Skipping desktop shortcut entry without a name or display name.' -LogWriter $LogWriter
                continue
            }
            $name = '{0}.lnk' -f $displayName
        }

        $targetCandidates = @()
        if ($entry.ContainsKey('targetCandidates')) {
            $targetCandidates = @($entry['targetCandidates'] | ForEach-Object { $_ })
        }
        if ($targetCandidates.Count -eq 0) {
            Write-LabLog -Message ("Skipping {0} desktop shortcut; no target candidates were provided." -f $name) -LogWriter $LogWriter
            continue
        }

        $resolvedTargets = Resolve-LabPathCandidates -Candidates $targetCandidates
        if ($resolvedTargets.Count -eq 0) {
            Write-LabLog -Message ("Skipping {0} desktop shortcut; executable not found." -f $name) -LogWriter $LogWriter
            continue
        }

        $target = $resolvedTargets[0]
        $arguments = ''
        if ($entry.ContainsKey('arguments') -and $null -ne $entry['arguments']) {
            $arguments = $entry['arguments']
        }

        $description = $null
        if ($entry.ContainsKey('description')) {
            $description = $entry['description']
        }
        if ([string]::IsNullOrWhiteSpace($description) -and -not [string]::IsNullOrWhiteSpace($displayName)) {
            $description = "Launch $displayName."
        }

        $iconCandidates = @()
        if ($entry.ContainsKey('iconCandidates')) {
            $iconCandidates = @($entry['iconCandidates'] | ForEach-Object { $_ })
        }
        $resolvedIcons = @()
        if ($iconCandidates.Count -gt 0) {
            $resolvedIcons = Resolve-LabPathCandidates -Candidates $iconCandidates
        }
        $iconPath = if ($resolvedIcons.Count -gt 0) { $resolvedIcons[0] } else { $target }

        $workingDirectory = Get-OptionalPropertyValue -InputObject $entry -PropertyName 'workingDirectory'
        if ([string]::IsNullOrWhiteSpace($workingDirectory)) {
            try {
                $workingDirectory = Split-Path -Path $target -Parent
            }
            catch {
                $workingDirectory = $null
            }
        }
        else {
            $workingDirectory = [Environment]::ExpandEnvironmentVariables($workingDirectory)
        }

        $shortcutPath = Join-Path -Path $desktopPath -ChildPath $name
        Write-LabLog -Message ("Creating desktop shortcut at {0} targeting {1}." -f $shortcutPath, $target) -LogWriter $LogWriter

        $shell = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $target
            $shortcut.Arguments = $arguments
            if ($workingDirectory) {
                $shortcut.WorkingDirectory = $workingDirectory
            }
            if ($iconPath) {
                $shortcut.IconLocation = '{0},0' -f $iconPath
            }
            if ($description) {
                $shortcut.Description = $description
            }
            $shortcut.Save()
        }
        catch {
            Write-LabLog -Message ("Failed to create desktop shortcut {0}: {1}" -f $name, $_.Exception.Message) -LogWriter $LogWriter
        }
        finally {
            if ($shell -and [System.Runtime.InteropServices.Marshal]::IsComObject($shell)) {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
            }
        }
    }
}

function Set-LabExtraTaskbarPins {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter,
        [pscustomobject[]]$BaseRequests = @(),
        [pscustomobject[]]$PreservedPins = @()
    )

    $entries = @()
    if ($Config.taskbarExtraPins) {
        $entries = @($Config.taskbarExtraPins | ForEach-Object { $_ })
    }
    if ($entries.Count -eq 0) { return }

    if ($BaseRequests) {
        $BaseRequests = @($BaseRequests | Where-Object { $_ })
    }
    else {
        $BaseRequests = @()
    }

    if ($PreservedPins) {
        $PreservedPins = @($PreservedPins | Where-Object { $_ })
    }
    else {
        $PreservedPins = @()
    }

    $extraRequests = New-Object System.Collections.Generic.List[pscustomobject]
    $failedRequests = New-Object System.Collections.Generic.List[pscustomobject]
    $layoutOnlyCount = 0
    $failedPinCount = 0
    $layoutApplied = $false

    foreach ($entry in $entries) {
        if (-not ($entry -is [System.Collections.IDictionary])) { continue }

        $displayName = Get-OptionalPropertyValue -InputObject $entry -PropertyName 'displayName'
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            Write-LabLog -Message 'Skipping taskbar extra pin without a display name.' -LogWriter $LogWriter
            continue
        }

        $targets = @()
        if ($entry.ContainsKey('taskbarTargets')) {
            $targets = Resolve-LabPathCandidates -Candidates $entry['taskbarTargets']
        }
        if ($targets.Count -eq 0) {
            Write-LabLog -Message ("Skipping {0} extra pin because no executables were found." -f $displayName) -LogWriter $LogWriter
            continue
        }

        $package = @{
            id             = (Get-OptionalPropertyValue -InputObject $entry -PropertyName 'id')
            displayName    = $displayName
            pinToTaskbar   = $true
            appUserModelId = (Get-OptionalPropertyValue -InputObject $entry -PropertyName 'appUserModelId')
            taskbarTargets = $targets
        }

        $shortcutName = Get-OptionalPropertyValue -InputObject $entry -PropertyName 'taskbarShortcutName'
        if ($shortcutName) {
            $package['taskbarShortcutName'] = $shortcutName
        }

        $pinMode = Get-OptionalPropertyValue -InputObject $entry -PropertyName 'taskbarPinMode'
        if ($pinMode) {
            $package['taskbarPinMode'] = $pinMode
        }

        $forceShortcut = Get-OptionalPropertyValue -InputObject $entry -PropertyName 'taskbarForceShortcut'
        if ($null -ne $forceShortcut) {
            $package['taskbarForceShortcut'] = [bool]$forceShortcut
        }

        if (-not $package.id) {
            $package.id = $displayName
        }

        $pinRequest = $null
        try {
            $pinRequest = Get-LabTaskbarPinRequest -Package $package -Config $Config -Mode 'Pin' -LogWriter $LogWriter
        }
        catch {
            Write-LabLog -Message ("Failed to build taskbar pin request for {0}: {1}" -f $displayName, $_.Exception.Message) -LogWriter $LogWriter
            continue
        }

        if (-not $pinRequest) { continue }

        [void]$extraRequests.Add($pinRequest)

        if ($pinRequest.PinMode -eq 'Layout') {
            $alreadyPinned = $false
            try {
                $alreadyPinned = Test-LabTaskbarPinnedState -CandidatePaths $pinRequest.CandidatePaths -AppId $pinRequest.AppId -ShortcutName $pinRequest.ShortcutName -DisplayName $pinRequest.DisplayName
            }
            catch {
                $alreadyPinned = $false
            }

            if ($alreadyPinned) {
                Write-LabLog -Message ("{0} already satisfies the layout-only taskbar pin requirement; skipping layout update." -f $displayName) -LogWriter $LogWriter
                continue
            }

            Write-LabLog -Message ("{0} requires layout-only taskbar pinning; queuing LayoutModification fallback." -f $displayName) -LogWriter $LogWriter
            [void]$failedRequests.Add($pinRequest)
            $layoutOnlyCount++
            continue
        }

        $pinned = $false
        try {
            $pinned = Set-TaskbarPin -DisplayName $pinRequest.DisplayName -Config $Config -CandidatePaths $pinRequest.CandidatePaths -AppId $pinRequest.AppId -ShortcutName $pinRequest.ShortcutName -LogWriter $LogWriter
        }
        catch {
            Write-LabLog -Message ("Taskbar pin attempt for {0} failed: {1}" -f $displayName, $_.Exception.Message) -LogWriter $LogWriter
            [void]$failedRequests.Add($pinRequest)
            $failedPinCount++
            continue
        }

        if (-not $pinned) {
            Write-LabLog -Message ("Unable to pin {0} to the taskbar." -f $displayName) -LogWriter $LogWriter
            [void]$failedRequests.Add($pinRequest)
            $failedPinCount++
        }
    }

    if ($failedRequests.Count -gt 0) {
        $combinedRequests = @()
        if ($BaseRequests -and $BaseRequests.Count -gt 0) {
            $combinedRequests += $BaseRequests
        }
        if ($extraRequests.Count -gt 0) {
            $combinedRequests += $extraRequests.ToArray()
        }

        $layoutInputs = Merge-LabTaskbarRequests -Primary $combinedRequests -Secondary $PreservedPins

        $fallbackReasons = New-Object System.Collections.Generic.List[string]
        if ($layoutOnlyCount -gt 0) {
            $fallbackReasons.Add("{0} layout-only pin(s)" -f $layoutOnlyCount)
        }
        if ($failedPinCount -gt 0) {
            $fallbackReasons.Add("{0} failed shell pin attempt(s)" -f $failedPinCount)
        }
        if ($fallbackReasons.Count -eq 0) {
            $fallbackReasons.Add('taskbar pin requirements')
        }

        Write-LabLog -Message ("Applying LayoutModification fallback for extra taskbar pin(s); {0}." -f ($fallbackReasons -join ' and ')) -LogWriter $LogWriter

        if ($PreservedPins -and $PreservedPins.Count -gt 0) {
            Write-LabLog -Message ("Preserving {0} existing taskbar pin(s) during extra-pin layout fallback." -f $PreservedPins.Count) -LogWriter $LogWriter
        }

        $layoutSucceeded = Set-LabTaskbarLayout -Config $Config -TaskbarRequests $layoutInputs -LogWriter $LogWriter
        if ($layoutSucceeded) {
            $layoutApplied = $true
            Write-LabLog -Message 'Applied LayoutModification fallback for extra taskbar pin(s).' -LogWriter $LogWriter
        }
        else {
            Write-LabLog -Message 'Unable to apply LayoutModification fallback for extra taskbar pin(s); taskbar pins may be incomplete.' -LogWriter $LogWriter
        }
    }

    return [pscustomobject]@{
        PinRequests     = $extraRequests.ToArray()
        LayoutApplied   = $layoutApplied
        FailedPinCount  = $failedPinCount
        LayoutOnlyCount = $layoutOnlyCount
    }
}
