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
