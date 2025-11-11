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
                $matches = Get-ChildItem -Path $expanded -File -ErrorAction SilentlyContinue
                foreach ($match in $matches) {
                    if ($match -and $seen.Add($match.FullName)) {
                        [void]$results.Add($match.FullName)
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

    return $results.ToArray()
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

function Ensure-LabDesktopShortcuts {
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
        if ($entry.ContainsKey('arguments') -and $entry['arguments'] -ne $null) {
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
        [System.IO.StreamWriter]$LogWriter
    )

    $entries = @()
    if ($Config.taskbarExtraPins) {
        $entries = @($Config.taskbarExtraPins | ForEach-Object { $_ })
    }
    if ($entries.Count -eq 0) { return }

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

        $pinned = $false
        try {
            $pinned = Set-TaskbarPin -DisplayName $pinRequest.DisplayName -Config $Config -CandidatePaths $pinRequest.CandidatePaths -AppId $pinRequest.AppId -ShortcutName $pinRequest.ShortcutName -LogWriter $LogWriter
        }
        catch {
            Write-LabLog -Message ("Taskbar pin attempt for {0} failed: {1}" -f $displayName, $_.Exception.Message) -LogWriter $LogWriter
            continue
        }

        if (-not $pinned) {
            Write-LabLog -Message ("Unable to pin {0} to the taskbar." -f $displayName) -LogWriter $LogWriter
        }
    }
}
