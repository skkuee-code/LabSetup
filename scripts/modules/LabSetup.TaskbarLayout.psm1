function Convert-ToTaskbarLayoutPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $resolvedPath = $Path
    try {
        $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    }
    catch {
        # Path may not exist yet (for example, non-elevated installs); fall back to the provided value.
    }

    $candidates = @{}
    $candidates['%LOCALAPPDATA%'] = $env:LOCALAPPDATA
    $candidates['%APPDATA%'] = $env:APPDATA
    $candidates['%ProgramData%'] = $env:ProgramData
    $candidates['%ProgramFiles%'] = ${env:ProgramFiles}
    $candidates['%ProgramFiles(x86)%'] = ${env:ProgramFiles(x86)}
    $candidates['%SystemDrive%'] = $env:SystemDrive

    $ordered = $candidates.GetEnumerator() |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Value) } |
        Sort-Object { $_.Value.Length } -Descending

    foreach ($entry in $ordered) {
        $root = $entry.Value.TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if ($resolvedPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relative = $resolvedPath.Substring($root.Length).TrimStart('\')
            if ([string]::IsNullOrWhiteSpace($relative)) {
                return $entry.Key
            }
            return "{0}\{1}" -f $entry.Key, $relative
        }
    }

    return $resolvedPath
}

function New-LabTaskbarShortcut {
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName,
        [Parameter(Mandatory)]
        [string]$ExecutablePath,
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        return $null
    }

    $resolvedExe = $ExecutablePath
    try {
        $resolvedExe = (Resolve-Path -LiteralPath $ExecutablePath -ErrorAction Stop).Path
    }
    catch {
        return $null
    }

    $shortcutRoot = Join-Path -Path $Config.programDataPath -ChildPath 'TaskbarShortcuts'
    New-LabDirectory -Path $shortcutRoot
    $safeName = ($DisplayName -replace '[\\/:*?"<>|]', '_')
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = 'LabShortcut'
    }
    $shortcutPath = Join-Path -Path $shortcutRoot -ChildPath ("{0}.lnk" -f $safeName.Trim())

    $wscript = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $wscript.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $resolvedExe
        $shortcut.WorkingDirectory = Split-Path -Path $resolvedExe -Parent
        $shortcut.IconLocation = $resolvedExe
        $shortcut.Save()
    }
    finally {
        if ($wscript -is [__ComObject]) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wscript)
        }
    }

    return $shortcutPath
}

function Get-LabTaskbarLayoutEntries {
    param(
        [Parameter(Mandatory)]
        [pscustomobject[]]$TaskbarRequests,
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    $entries = New-Object System.Collections.Generic.List[hashtable]

    foreach ($request in $TaskbarRequests) {
        if (-not $request) { continue }

        $displayName = $request.DisplayName
        $appId = $request.AppId
        if ($appId -and $appId -isnot [string]) {
            $appId = $appId.ToString()
        }

        $forceShortcut = $false
        if ($request.PSObject.Properties['ForceShortcut']) {
            $forceShortcut = [bool]$request.ForceShortcut
        }

        $appIdLooksLikePath = $false
        if (-not [string]::IsNullOrWhiteSpace($appId)) {
            $appIdLooksLikePath = ($appId.IndexOf(':') -ge 0) -or
                ($appId -match '[\\/]+') -or
                ($appId -match '\.(exe|bat|cmd|ps1|lnk)$')
        }

        if (-not $forceShortcut -and -not $appIdLooksLikePath -and -not [string]::IsNullOrWhiteSpace($appId)) {
            $entryType = if ($appId -match '!.+$' -and $appId -match '_') { 'UWA' } else { 'DesktopAppId' }
            [void]$entries.Add(@{
                Type = $entryType
                Value = $appId
                DisplayName = $displayName
            })
            continue
        }

        $shortcutPath = $request.ShortcutPath
        if (-not $shortcutPath) {
            $shortcutPath = Resolve-LabShortcutPath -PreferredName $request.ShortcutName -DisplayName $displayName -CandidatePaths $request.CandidatePaths -CreationPolicy 'WhenMissing' -Config $Config -LogWriter $LogWriter
            if ($shortcutPath) {
                $request.ShortcutPath = $shortcutPath
            }
        }

        if ($shortcutPath) {
            $layoutPath = Convert-ToTaskbarLayoutPath -Path $shortcutPath
            if ($layoutPath) {
                [void]$entries.Add(@{
                    Type = 'Link'
                    Value = $layoutPath
                    DisplayName = $displayName
                })
                continue
            }
        }

        if ($LogWriter) {
            Write-LabLog -Message "Unable to generate layout entry for $displayName; no appUserModelId or shortcut path found." -LogWriter $LogWriter
        }
    }

    return $entries
}

function Set-LabTaskbarLayout {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [hashtable[]]$Packages,
        [pscustomobject[]]$TaskbarRequests,
        [System.IO.StreamWriter]$LogWriter
    )

    if (-not $TaskbarRequests -and $Packages) {
        $resolvedRequests = New-Object System.Collections.Generic.List[pscustomobject]
        foreach ($package in $Packages) {
            $request = Get-LabTaskbarPinRequest -Package $package -Config $Config -Mode 'Layout' -LogWriter $LogWriter
            if ($request) {
                [void]$resolvedRequests.Add($request)
            }
        }
        $TaskbarRequests = $resolvedRequests.ToArray()
    }

    if (-not $TaskbarRequests -and -not $Packages) {
        return $false
    }

    if ($TaskbarRequests) {
        $TaskbarRequests = @($TaskbarRequests | Where-Object { $_ })
    }

    if (-not $TaskbarRequests -or $TaskbarRequests.Count -eq 0) {
        return $false
    }

    $entries = Get-LabTaskbarLayoutEntries -TaskbarRequests $TaskbarRequests -Config $Config -LogWriter $LogWriter
    if ($entries.Count -eq 0) {
        return $false
    }

    $explorerAppId = 'Microsoft.Windows.Explorer'
    $explorerIndex = -1
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $entry = $entries[$i]
        if ($entry -and $entry.Type -eq 'DesktopAppId' -and $entry.Value -eq $explorerAppId) {
            $explorerIndex = $i
            break
        }
    }

    if ($explorerIndex -gt 0) {
        $existingExplorer = $entries[$explorerIndex]
        $entries.RemoveAt($explorerIndex)
        $entries.Insert(0, $existingExplorer)
    }
    elseif ($explorerIndex -lt 0) {
        $entries.Insert(0, @{
            Type = 'DesktopAppId'
            Value = $explorerAppId
            DisplayName = 'File Explorer'
        })
    }

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    $null = $sb.AppendLine('<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"')
    $null = $sb.AppendLine('    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"')
    $null = $sb.AppendLine('    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"')
    $null = $sb.AppendLine('    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">')
    $null = $sb.AppendLine('  <CustomTaskbarLayoutCollection PinListPlacement="Replace">')
    $null = $sb.AppendLine('    <defaultlayout:TaskbarLayout>')
    $null = $sb.AppendLine('      <taskbar:TaskbarPinList>')

    foreach ($entry in $entries) {
        $value = [System.Security.SecurityElement]::Escape($entry.Value)
        switch ($entry.Type) {
            'UWA' {
                $null = $sb.AppendLine("        <taskbar:UWA AppUserModelID=""$value"" />")
            }
            'DesktopAppId' {
                $null = $sb.AppendLine("        <taskbar:DesktopApp DesktopApplicationID=""$value"" />")
            }
            default {
                $null = $sb.AppendLine("        <taskbar:DesktopApp DesktopApplicationLinkPath=""$value"" />")
            }
        }
    }

    $null = $sb.AppendLine('      </taskbar:TaskbarPinList>')
    $null = $sb.AppendLine('    </defaultlayout:TaskbarLayout>')
    $null = $sb.AppendLine('  </CustomTaskbarLayoutCollection>')
    $null = $sb.AppendLine('</LayoutModificationTemplate>')

    $targets = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) {
        $targets.Add((Join-Path -Path (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\Windows\Shell') -ChildPath 'LayoutModification.xml'))
    }

    $defaultProfileRoot = Join-Path -Path $env:SystemDrive -ChildPath 'Users\Default'
    if (Test-Path -LiteralPath $defaultProfileRoot) {
        $targets.Add((Join-Path -Path (Join-Path -Path $defaultProfileRoot -ChildPath 'AppData\Local\Microsoft\Windows\Shell') -ChildPath 'LayoutModification.xml'))
    }

    if ($targets.Count -eq 0) {
        if ($LogWriter) {
            Write-LabLog -Message 'No writable LayoutModification targets were detected; skipping fallback taskbar layout.' -LogWriter $LogWriter
        }
        return $false
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $writeSucceeded = $false
    foreach ($target in $targets) {
        try {
            $parent = Split-Path -Path $target -Parent
            if ($parent) {
                New-LabDirectory -Path $parent
            }
            [System.IO.File]::WriteAllText($target, $sb.ToString(), $encoding)
            $writeSucceeded = $true
            if ($LogWriter) {
                Write-LabLog -Message "Wrote taskbar layout to $target." -LogWriter $LogWriter
            }
        }
        catch {
            if ($LogWriter) {
                $errorMessage = ("Failed to write taskbar layout to {0}: {1}" -f $target, $_.Exception.Message)
                Write-LabLog -Message $errorMessage -LogWriter $LogWriter
            }
        }
    }

    if (-not $writeSucceeded) {
        return $false
    }

    Reset-LabTaskbarLayoutState -LogWriter $LogWriter
    return $true
}

function Reset-LabTaskbarLayoutState {
    param(
        [System.IO.StreamWriter]$LogWriter
    )

    if ($LogWriter) {
        Write-LabLog -Message 'Resetting taskbar cache to apply the LayoutModification template...' -LogWriter $LogWriter
    }

    $taskbarPinnedPath = Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    if (Test-Path -LiteralPath $taskbarPinnedPath) {
        Get-ChildItem -Path $taskbarPinnedPath -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }

    $taskbandKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
    if (Test-Path -LiteralPath $taskbandKey) {
        Remove-Item -Path $taskbandKey -Recurse -Force -ErrorAction SilentlyContinue
    }

    $trayNotifyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TrayNotify'
    foreach ($valueName in @('IconStreams', 'PastIconsStream')) {
        try {
            Remove-ItemProperty -Path $trayNotifyKey -Name $valueName -ErrorAction SilentlyContinue
        }
        catch {
            # Property may not exist; ignore.
        }
    }

    try {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    }
    catch {
        # Explorer might not be running; ignore.
    }

    Start-Sleep -Seconds 2
    try {
        Start-Process -FilePath (Join-Path -Path $env:SystemRoot -ChildPath 'explorer.exe') | Out-Null
    }
    catch {
        # If Explorer cannot restart, allow the parent shell to continue.
    }
}
