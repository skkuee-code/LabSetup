$script:ConvertFromJsonSupportsDepth = $null

function Remove-WindowsTerminalJsonComments {
    param(
        [string]$InputText
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) {
        return $InputText
    }

    $builder = [System.Text.StringBuilder]::new()
    $length = $InputText.Length
    $inString = $false
    $stringDelimiter = [char]0
    $escapePending = $false
    $index = 0

    while ($index -lt $length) {
        $char = $InputText[$index]

        if ($inString) {
            [void]$builder.Append($char)
            if ($escapePending) {
                $escapePending = $false
            }
            elseif ($char -eq '\') {
                $escapePending = $true
            }
            elseif ($char -eq $stringDelimiter) {
                $inString = $false
            }
            $index++
            continue
        }

        if ($char -eq '"' -or $char -eq "'") {
            $inString = $true
            $stringDelimiter = $char
            [void]$builder.Append($char)
            $index++
            continue
        }

        if ($char -eq '/' -and ($index + 1) -lt $length) {
            $next = $InputText[$index + 1]
            if ($next -eq '/') {
                $index += 2
                while ($index -lt $length) {
                    $commentChar = $InputText[$index]
                    if ($commentChar -eq "`r" -or $commentChar -eq "`n") {
                        [void]$builder.Append($commentChar)
                        if ($commentChar -eq "`r" -and ($index + 1) -lt $length -and $InputText[$index + 1] -eq "`n") {
                            $index++
                            [void]$builder.Append("`n")
                        }
                        $index++
                        break
                    }
                    $index++
                }
                continue
            }
            elseif ($next -eq '*') {
                $index += 2
                while ($index -lt ($length - 1)) {
                    if ($InputText[$index] -eq '*' -and $InputText[$index + 1] -eq '/') {
                        $index += 2
                        break
                    }
                    $index++
                }
                continue
            }
        }

        [void]$builder.Append($char)
        $index++
    }

    return $builder.ToString()
}

function Get-WindowsTerminalSettingsPaths {
    param(
        [hashtable]$TerminalConfig
    )

    $defaults = @(
        '%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json',
        '%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json',
        '%LOCALAPPDATA%\Microsoft\Windows Terminal\settings.json'
    )

    $configured = Get-OptionalPropertyValue -InputObject $TerminalConfig -PropertyName 'settingsPaths'
    $candidates = @()
    if ($configured -is [System.Collections.IEnumerable] -and -not ($configured -is [string])) {
        $candidates = @($configured | ForEach-Object { $_ })
    }

    if ($candidates.Count -eq 0) {
        $candidates = $defaults
    }

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $value = $candidate.Trim()
        if (-not $paths.Contains($value)) {
            [void]$paths.Add($value)
        }
    }

    return $paths.ToArray()
}

function Resolve-PowerShell7Path {
    param(
        [string]$PreferredPath
    )

    $resolvedPreferred = $null
    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($PreferredPath)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            try {
                $resolvedPreferred = (Resolve-Path -LiteralPath $expanded).Path
            }
            catch {
                $resolvedPreferred = $expanded
            }
        }
    }
    if ($resolvedPreferred) { return $resolvedPreferred }

    foreach ($name in @('pwsh', 'pwsh.exe')) {
        try {
            $command = Get-Command -Name $name -ErrorAction Stop
            if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
                return $command.Source
            }
        }
        catch {
            continue
        }
    }

    foreach ($fallback in @(
            'C:\Program Files\PowerShell\7\pwsh.exe',
            'C:\Program Files\PowerShell\7-preview\pwsh.exe',
            'C:\Program Files (x86)\PowerShell\7\pwsh.exe'
        )) {
        if (Test-Path -LiteralPath $fallback -PathType Leaf) {
            return $fallback
        }
    }

    return $null
}

function ConvertTo-WindowsTerminalGuidString {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $trimmed = $Value.Trim()
    $trimmed = $trimmed.Trim()
    $normalized = $trimmed.Trim('{}')

    [guid]$parsed = [guid]::Empty
    if ([guid]::TryParse($normalized, [ref]$parsed)) {
        return ("{0:B}" -f $parsed)
    }

    return $trimmed
}

function Set-WindowsTerminalDefaultProfileForPath {
    param(
        [Parameter(Mandatory)]
        [string]$SettingsPath,
        [string]$TargetProfileSource,
        [string[]]$TargetNames,
        [string]$PwshCommandPath,
        [System.IO.StreamWriter]$LogWriter,
        [switch]$AllowCreate
    )

    $result = [pscustomobject]@{
        Processed = $false
        Changed   = $false
    }

    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        return $result
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($SettingsPath)
    $directory = Split-Path -Path $expandedPath -Parent
    if ([string]::IsNullOrWhiteSpace($directory)) {
        if ($LogWriter) {
            Write-LabLog -Message ("Unable to determine parent directory for Windows Terminal settings path {0}." -f $expandedPath) -LogWriter $LogWriter
        }
        return $result
    }

    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        if (-not $AllowCreate) {
            if ($LogWriter) {
                Write-LabLog -Message ("Windows Terminal settings directory {0} does not exist; skipping." -f $directory) -LogWriter $LogWriter
            }
            return $result
        }

        try {
            New-LabDirectory -Path $directory
        }
        catch {
            if ($LogWriter) {
                Write-LabLog -Message ("Unable to create Windows Terminal settings directory {0}: {1}" -f $directory, $_.Exception.Message) -LogWriter $LogWriter
            }
            return $result
        }
    }

    $rawSettings = '{}'
    $existingFile = Test-Path -LiteralPath $expandedPath -PathType Leaf
    if ($existingFile) {
        try {
            $rawSettings = Get-Content -LiteralPath $expandedPath -Raw -ErrorAction Stop
        }
        catch {
            if ($LogWriter) {
                Write-LabLog -Message ("Unable to read Windows Terminal settings from {0}: {1}" -f $expandedPath, $_.Exception.Message) -LogWriter $LogWriter
            }
            return $result
        }
    }
    elseif (-not $AllowCreate) {
        if ($LogWriter) {
            Write-LabLog -Message ("Windows Terminal settings file {0} not found; skipping." -f $expandedPath) -LogWriter $LogWriter
        }
        return $result
    }

    $sanitized = Remove-WindowsTerminalJsonComments -InputText $rawSettings
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        $sanitized = '{}'
    }

    if ($null -eq $script:ConvertFromJsonSupportsDepth) {
        try {
            $convertFromJsonCommand = Get-Command -Name ConvertFrom-Json -ErrorAction Stop
            $script:ConvertFromJsonSupportsDepth = $convertFromJsonCommand.Parameters.ContainsKey('Depth')
        }
        catch {
            $script:ConvertFromJsonSupportsDepth = $false
        }
    }

    $convertFromJsonParameters = @{
        InputObject = $sanitized
    }
    if ($script:ConvertFromJsonSupportsDepth) {
        $convertFromJsonParameters['Depth'] = 100
    }

    try {
        $parsed = ConvertFrom-Json @convertFromJsonParameters
    }
    catch {
        if ($LogWriter) {
            Write-LabLog -Message ("Windows Terminal settings at {0} are invalid: {1}" -f $expandedPath, $_.Exception.Message) -LogWriter $LogWriter
        }
        return $result
    }

    $settings = ConvertTo-Hashtable -InputObject $parsed
    if (-not $settings) {
        $settings = @{}
    }

    $profilesSection = $settings['profiles']
    if ($profilesSection -and -not ($profilesSection -is [System.Collections.IDictionary])) {
        $profilesSection = ConvertTo-Hashtable -InputObject $profilesSection
    }
    if (-not $profilesSection) {
        $profilesSection = @{}
    }
    $settings['profiles'] = $profilesSection

    $existingList = @()
    if ($profilesSection.ContainsKey('list')) {
        $existingList = @($profilesSection['list'])
    }

    $profileList = New-Object System.Collections.ArrayList
    foreach ($item in $existingList) {
        if (-not $item) { continue }
        if ($item -is [System.Collections.IDictionary]) {
            [void]$profileList.Add($item)
        }
        else {
            [void]$profileList.Add((ConvertTo-Hashtable -InputObject $item))
        }
    }
    $profilesSection['list'] = $profileList

    $result.Processed = $true

    $targetProfile = $null
    if (-not [string]::IsNullOrWhiteSpace($TargetProfileSource)) {
        foreach ($profileEntry in $profileList) {
            $sourceValue = Get-OptionalPropertyValue -InputObject $profileEntry -PropertyName 'source'
            if ([string]::IsNullOrWhiteSpace($sourceValue)) { continue }
            if ($sourceValue.ToString().Trim().Equals($TargetProfileSource.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                $targetProfile = $profileEntry
                break
            }
        }
    }

    if (-not $targetProfile -and $TargetNames) {
        $normalizedNames = @()
        foreach ($name in $TargetNames) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $lower = $name.Trim().ToLowerInvariant()
            if ($normalizedNames -notcontains $lower) {
                $normalizedNames += $lower
            }
        }

        foreach ($profileEntry in $profileList) {
            $profileName = Get-OptionalPropertyValue -InputObject $profileEntry -PropertyName 'name'
            if ([string]::IsNullOrWhiteSpace($profileName)) { continue }
            if ($normalizedNames -contains $profileName.Trim().ToLowerInvariant()) {
                $targetProfile = $profileEntry
                break
            }
        }
    }

    if (-not $targetProfile) {
        foreach ($profileEntry in $profileList) {
            $commandline = Get-OptionalPropertyValue -InputObject $profileEntry -PropertyName 'commandline'
            if ([string]::IsNullOrWhiteSpace($commandline)) { continue }
            if ($commandline.ToLowerInvariant().Contains('pwsh')) {
                $targetProfile = $profileEntry
                break
            }
        }
    }

    $changed = $false
    if (-not $targetProfile -and $PwshCommandPath) {
        $newProfile = @{
            guid        = ("{0:B}" -f [guid]::NewGuid())
            name        = if ($TargetNames -and $TargetNames.Count -gt 0) { $TargetNames[0] } else { 'PowerShell 7' }
            commandline = $PwshCommandPath
        }
        [void]$profileList.Add($newProfile)
        $targetProfile = $newProfile
        $changed = $true
        if ($LogWriter) {
            Write-LabLog -Message ("Added Windows Terminal profile '{0}' targeting {1}." -f $newProfile.name, $PwshCommandPath) -LogWriter $LogWriter
        }
    }

    if (-not $targetProfile) {
        if ($LogWriter) {
            Write-LabLog -Message ("Unable to locate or create a PowerShell 7 profile in {0}; default profile unchanged." -f $expandedPath) -LogWriter $LogWriter
        }
        return $result
    }

    $guidValue = ConvertTo-WindowsTerminalGuidString -Value (Get-OptionalPropertyValue -InputObject $targetProfile -PropertyName 'guid')
    if (-not $guidValue) {
        $guidValue = ("{0:B}" -f [guid]::NewGuid())
        $targetProfile['guid'] = $guidValue
        $changed = $true
    }
    elseif ($guidValue -ne $targetProfile['guid']) {
        $targetProfile['guid'] = $guidValue
        $changed = $true
    }

    $currentDefault = Get-OptionalPropertyValue -InputObject $settings -PropertyName 'defaultProfile'
    if ($guidValue -and $currentDefault -ne $guidValue) {
        $settings['defaultProfile'] = $guidValue
        $changed = $true
    }

    $result.Processed = $true
    $result.Changed = $changed -or (-not $existingFile)

    if ($result.Changed) {
        $json = ConvertTo-Json -InputObject $settings -Depth 100
        $normalizedNewline = $json -replace "`r?`n", "`r`n"
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($expandedPath, $normalizedNewline, $encoding)
        if ($LogWriter) {
            Write-LabLog -Message ("Updated Windows Terminal default profile at {0} to use PowerShell 7." -f $expandedPath) -LogWriter $LogWriter
        }
    }
    else {
        if ($LogWriter) {
            Write-LabLog -Message ("Windows Terminal default profile at {0} already targets PowerShell 7." -f $expandedPath) -LogWriter $LogWriter
        }
    }

    return $result
}

function Set-WindowsTerminalDefaultProfile {
    param(
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    $terminalConfig = $null
    if ($Config -and $Config.ContainsKey('windowsTerminal')) {
        $terminalConfig = $Config['windowsTerminal']
    }

    $configure = $true
    if ($terminalConfig) {
        $configureValue = Get-OptionalPropertyValue -InputObject $terminalConfig -PropertyName 'configureDefaultProfile'
        if ($null -ne $configureValue) {
            $configure = [bool]$configureValue
        }
    }

    if (-not $configure) {
        if ($LogWriter) {
            Write-LabLog -Message 'Skipping Windows Terminal default profile configuration (disabled in config).' -LogWriter $LogWriter
        }
        return
    }

    $paths = Get-WindowsTerminalSettingsPaths -TerminalConfig $terminalConfig
    if (-not $paths -or $paths.Count -eq 0) {
        if ($LogWriter) {
            Write-LabLog -Message 'No Windows Terminal settings paths available; skipping default profile configuration.' -LogWriter $LogWriter
        }
        return
    }

    $targetSource = if ($terminalConfig) {
        $value = Get-OptionalPropertyValue -InputObject $terminalConfig -PropertyName 'defaultProfileSource'
        if (-not [string]::IsNullOrWhiteSpace($value)) { $value } else { 'Windows.Terminal.PowershellCore' }
    } else {
        'Windows.Terminal.PowershellCore'
    }

    $targetName = if ($terminalConfig) {
        $nameValue = Get-OptionalPropertyValue -InputObject $terminalConfig -PropertyName 'defaultProfileName'
        if (-not [string]::IsNullOrWhiteSpace($nameValue)) { $nameValue } else { 'PowerShell 7' }
    } else {
        'PowerShell 7'
    }

    $nameSet = @()
    foreach ($name in @($targetName, 'PowerShell', 'PowerShell 7')) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($nameSet -notcontains $name) {
            $nameSet += $name
        }
    }

    $preferredCommand = if ($terminalConfig) {
        Get-OptionalPropertyValue -InputObject $terminalConfig -PropertyName 'defaultProfileCommand'
    } else {
        $null
    }

    $pwshPath = Resolve-PowerShell7Path -PreferredPath $preferredCommand
    if (-not $pwshPath -and $LogWriter) {
        Write-LabLog -Message 'PowerShell 7 executable not located; will only re-target existing Windows Terminal profiles.' -LogWriter $LogWriter
    }

    $processedAny = $false
    $updatedAny = $false
    for ($i = 0; $i -lt $paths.Count; $i++) {
        $path = $paths[$i]
        $allowCreate = ($i -eq 0)
        $result = Set-WindowsTerminalDefaultProfileForPath -SettingsPath $path -TargetProfileSource $targetSource -TargetNames $nameSet -PwshCommandPath $pwshPath -LogWriter $LogWriter -AllowCreate:$allowCreate
        if ($result.Processed) {
            $processedAny = $true
        }
        if ($result.Changed) {
            $updatedAny = $true
        }
    }

    if (-not $processedAny -and $LogWriter) {
        Write-LabLog -Message 'No Windows Terminal settings files were updated; ensure the application has been launched at least once.' -LogWriter $LogWriter
    }
    elseif ($processedAny -and -not $updatedAny -and $LogWriter) {
        Write-LabLog -Message 'Windows Terminal default profile already targeted PowerShell 7; no changes were required.' -LogWriter $LogWriter
    }
}
