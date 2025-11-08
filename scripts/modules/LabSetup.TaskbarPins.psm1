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

function Resolve-LabShortcutPath {
    param(
        [string]$PreferredName,
        [string]$DisplayName,
        [string[]]$CandidatePaths = @(),
        [ValidateSet('Never', 'WhenMissing', 'Always')]
        [string]$CreationPolicy = 'WhenMissing',
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    if ($CreationPolicy -ne 'Always') {
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
    }

    if ($CreationPolicy -eq 'Never' -or -not $CandidatePaths -or $CandidatePaths.Count -eq 0) {
        return $null
    }

    $target = Resolve-ExecutableFromCandidates -Candidates $CandidatePaths
    if (-not $target) {
        if ($LogWriter) {
            Write-LabLog -Message "Unable to resolve shortcut target for $DisplayName while processing taskbar metadata." -LogWriter $LogWriter
        }
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

    return New-LabTaskbarShortcut -DisplayName $shortcutLabel -ExecutablePath $target -Config $Config
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

    $shortcutPath = Resolve-LabShortcutPath -PreferredName $shortcutName -DisplayName $displayName -CandidatePaths $candidatePaths -CreationPolicy $creationPolicy -Config $Config -LogWriter $LogWriter

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

    return [pscustomobject]@{
        Package        = $Package
        DisplayName    = $displayName
        AppId          = $appId
        CandidatePaths = $orderedCandidates.ToArray()
        ShortcutName   = $shortcutName
        ShortcutPath   = $shortcutPath
        ForceShortcut  = $forceShortcut
        Mode           = $Mode
    }
}

function Set-LabTaskbarPins {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    $pinRequests = New-Object System.Collections.Generic.List[pscustomobject]
    $failedPinCount = 0

    foreach ($package in $Config.wingetPackages) {
        $pinToTaskbar = $false
        if ($package -is [System.Collections.IDictionary] -and $package.ContainsKey('pinToTaskbar')) {
            $pinToTaskbar = [bool]$package['pinToTaskbar']
        }

        if (-not $pinToTaskbar) { continue }

        $pinRequest = Get-LabTaskbarPinRequest -Package $package -Config $Config -Mode 'Pin' -LogWriter $LogWriter
        if (-not $pinRequest) { continue }

        [void]$pinRequests.Add($pinRequest)

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
        }
    }

    if ($failedPinCount -gt 0 -and $pinRequests.Count -gt 0) {
        Write-LabLog -Message ("{0} taskbar pin attempts failed; generating fallback layout." -f $failedPinCount) -LogWriter $LogWriter
        $layoutApplied = Set-LabTaskbarLayout -Config $Config -TaskbarRequests $pinRequests.ToArray() -LogWriter $LogWriter
        if ($layoutApplied) {
            Write-LabLog -Message 'Applied LayoutModification fallback and reset Explorer to enforce taskbar pins.' -LogWriter $LogWriter
        }
        else {
            Write-LabLog -Message 'Unable to apply LayoutModification fallback; taskbar pins may be incomplete.' -LogWriter $LogWriter
        }
    }
}
