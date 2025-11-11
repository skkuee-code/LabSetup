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

function Normalize-LabContextMenuLabel {
    param(
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Label)) {
        return ''
    }

    $normalized = ($Label -replace '&', '').Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }

    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    $normalized = [System.Text.RegularExpressions.Regex]::Replace(
        $normalized,
        '\s*[\(\uFF08]\s*[\p{L}\p{Nd}]{1,5}\s*[\)\uFF09]\s*$',
        '',
        $options
    ).TrimEnd()

    return $normalized
}

function Get-LabTaskbarShellItems {
    param(
        [string[]]$CandidatePaths = @(),
        [string]$AppId,
        [string]$ShortcutName,
        [string]$DisplayName
    )

    $items = New-Object System.Collections.Generic.List[object]
    $resolvedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $tryAddItem = {
        param(
            [string]$Key,
            $ShellItem
        )

        if (-not $ShellItem) { return }
        if ([string]::IsNullOrWhiteSpace($Key)) { return }

        if ($resolvedKeys.Add($Key)) {
            [void]$items.Add($ShellItem)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($AppId)) {
        $appItem = Get-ShellItemFromAppId -AppId $AppId
        if ($appItem) {
            & $tryAddItem "APPID::$AppId" $appItem
        }
    }

    if ($CandidatePaths) {
        foreach ($candidate in $CandidatePaths) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $exe = Resolve-ExecutableFromCandidates -Candidates @($candidate)
            if ($exe) {
                $item = Get-ShellItemFromPath -Path $exe
                if ($item) {
                    & $tryAddItem ("PATH::$exe") $item
                }
            }
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
        if ($shortcutPath) {
            $item = Get-ShellItemFromPath -Path $shortcutPath
            if ($item) {
                & $tryAddItem ("SHORTCUT::$shortcutPath") $item
            }
        }
    }

    return $items.ToArray()
}

function Get-LabTaskbarFavoritesText {
    $taskbandKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
    try {
        if (-not (Test-Path -LiteralPath $taskbandKey -PathType Container)) {
            return $null
        }

        $favoritesValue = Get-ItemProperty -LiteralPath $taskbandKey -Name 'Favorites' -ErrorAction Stop
        $favoritesBytes = $favoritesValue.Favorites
        if (-not ($favoritesBytes -is [byte[]]) -or $favoritesBytes.Length -eq 0) {
            return $null
        }

        return [System.Text.Encoding]::Unicode.GetString($favoritesBytes)
    }
    catch {
        return $null
    }
}

function Test-LabTaskbarPinnedAppId {
    param(
        [string]$AppId
    )

    if ([string]::IsNullOrWhiteSpace($AppId)) {
        return $false
    }

    $favoritesText = Get-LabTaskbarFavoritesText
    if ([string]::IsNullOrWhiteSpace($favoritesText)) {
        return $false
    }

    return ($favoritesText.IndexOf($AppId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
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
    $normalizedPinLabels = @($pinLabels | ForEach-Object {
            $label = Normalize-LabContextMenuLabel -Label $_
            if (-not [string]::IsNullOrWhiteSpace($label)) {
                $label.ToLowerInvariant()
            }
        } | Where-Object { $_ })
    $normalizedUnpinLabels = @($unpinLabels | ForEach-Object {
            $label = Normalize-LabContextMenuLabel -Label $_
            if (-not [string]::IsNullOrWhiteSpace($label)) {
                $label.ToLowerInvariant()
            }
        } | Where-Object { $_ })

    foreach ($verb in $ShellItem.Verbs()) {
        $canonicalProperty = $verb.PSObject.Properties['CanonicalName']
        $canonicalName = if ($canonicalProperty) { $canonicalProperty.Value } else { $null }
        if ($canonicalName -eq $VerbName) {
            $verb.DoIt()
            return $true
        }
        $nameProperty = $verb.PSObject.Properties['Name']
        $verbDisplayName = if ($nameProperty) { $nameProperty.Value } else { '' }
        $normalized = Normalize-LabContextMenuLabel -Label $verbDisplayName
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }
        $normalizedLower = $normalized.ToLowerInvariant()
        switch ($VerbName) {
            'taskbarpin' {
                foreach ($label in $normalizedPinLabels) {
                    if ($normalizedLower -eq $label) {
                        $verb.DoIt()
                        return $true
                    }
                }
            }
            'taskbarunpin' {
                foreach ($label in $normalizedUnpinLabels) {
                    if ($normalizedLower -eq $label) {
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
    $normalizedUnpinLabels = @($unpinLabels | ForEach-Object {
            $label = Normalize-LabContextMenuLabel -Label $_
            if (-not [string]::IsNullOrWhiteSpace($label)) {
                $label.ToLowerInvariant()
            }
        } | Where-Object { $_ })

    foreach ($verb in $ShellItem.Verbs()) {
        $canonicalProperty = $verb.PSObject.Properties['CanonicalName']
        $canonicalName = if ($canonicalProperty) { $canonicalProperty.Value } else { $null }
        if ($canonicalName -eq 'taskbarunpin') {
            return $true
        }
        $nameProperty = $verb.PSObject.Properties['Name']
        $verbName = if ($nameProperty) { $nameProperty.Value } else { '' }
        $normalized = Normalize-LabContextMenuLabel -Label $verbName
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }
        $normalizedLower = $normalized.ToLowerInvariant()
        foreach ($label in $normalizedUnpinLabels) {
            if ($normalizedLower -eq $label) {
                return $true
            }
        }
    }

    return $false
}

function Test-LabTaskbarPinnedState {
    param(
        [string[]]$CandidatePaths = @(),
        [string]$AppId,
        [string]$ShortcutName,
        [string]$DisplayName
    )

    if (-not [string]::IsNullOrWhiteSpace($AppId)) {
        if (Test-LabTaskbarPinnedAppId -AppId $AppId) {
            return $true
        }
        $existingPinsCommand = Get-Command -Name 'Get-LabExistingTaskbarPins' -ErrorAction SilentlyContinue
        if ($existingPinsCommand) {
            try {
                $existingPins = Get-LabExistingTaskbarPins -LogWriter $null
                foreach ($pin in $existingPins) {
                    if (-not $pin) { continue }
                    $candidateAppId = $pin.AppId
                    if (-not [string]::IsNullOrWhiteSpace($candidateAppId) -and
                        $candidateAppId.Equals($AppId, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return $true
                    }
                }
            }
            catch {
                # Ignore failures when enumerating existing pins.
            }
        }
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

    foreach ($shellItem in $shellItemList) {
        try {
            if ($shellItem -and (Test-TaskbarPinned -ShellItem $shellItem)) {
                return $true
            }
        }
        finally {
            if ($shellItem -is [__ComObject]) {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shellItem)
            }
        }
    }

    return $false
}
