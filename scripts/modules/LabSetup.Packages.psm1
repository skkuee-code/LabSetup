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

    $displayName = if ($Package.displayName) { $Package.displayName } elseif ($Package.id) { $Package.id } else { 'manual package' }
    $productCode = Get-OptionalPropertyValue -InputObject $installer -PropertyName 'productCode'
    $minimumVersionString = Get-OptionalPropertyValue -InputObject $installer -PropertyName 'minimumVersion'
    $minimumVersion = $null
    if ($minimumVersionString) {
        $parsedMinimum = $null
        if ([System.Version]::TryParse($minimumVersionString, [ref]$parsedMinimum)) {
            $minimumVersion = $parsedMinimum
        } else {
            Write-LabLog -Message "Unable to parse minimum version '$minimumVersionString' for $displayName; proceeding without version comparison." -LogWriter $LogWriter
        }
    }

    if ($productCode) {
        $installInfo = Get-MsiProductInstallInfo -ProductCode $productCode
        if ($installInfo) {
            $installedVersionText = if ($installInfo.DisplayVersion) { $installInfo.DisplayVersion } else { 'unknown version' }
            if ($minimumVersion -and $installInfo.ParsedVersion) {
                if ($installInfo.ParsedVersion -lt $minimumVersion) {
                    Write-LabLog -Message "$displayName $installedVersionText detected but older than required version $minimumVersionString; reinstalling." -LogWriter $LogWriter
                } else {
                    Write-LabLog -Message "$displayName already installed (product code $($installInfo.ProductCode), version $installedVersionText); skipping manual install." -LogWriter $LogWriter
                    return
                }
            }
            elseif ($minimumVersion -and -not $installInfo.ParsedVersion) {
                Write-LabLog -Message "$displayName installation detected but version information is unavailable; reinstalling to ensure compliance." -LogWriter $LogWriter
            }
            else {
                Write-LabLog -Message "$displayName already installed (product code $($installInfo.ProductCode)); skipping manual install." -LogWriter $LogWriter
                return
            }
        }
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

            if ($installer.ContainsKey('properties') -and $installer['properties']) {
                $rawProperties = $installer['properties']
                $properties = @()

                if ($rawProperties -is [System.Collections.IEnumerable] -and -not ($rawProperties -is [string])) {
                    foreach ($prop in $rawProperties) {
                        if ([string]::IsNullOrWhiteSpace($prop)) { continue }
                        $properties += $prop.Trim()
                    }
                }
                elseif (-not [string]::IsNullOrWhiteSpace($rawProperties)) {
                    $properties += $rawProperties.Trim()
                }

                if ($properties.Count -gt 0) {
                    $msiArgs += $properties
                }
            }

            Write-LabLog -Message "Installing $($Package.displayName) via msiexec..." -LogWriter $LogWriter
            $process = Invoke-ProcessWithSpinner -FilePath $msiExec -ArgumentList $msiArgs -Activity "Installing $($Package.displayName) via msiexec"
            $exitCode = Get-LabProcessExitCode -Process $process
            if ($exitCode -ne 0) {
                $exitCodeLabel = if ($null -ne $exitCode) { $exitCode } else { 'unknown' }
                throw "msiexec failed for $($Package.displayName) with exit code $exitCodeLabel."
            }
        }
        default {
            throw "Unsupported installer type '$installerType' for $($Package.displayName)."
        }
    }

    Write-LabLog -Message "Completed $($Package.displayName) installation." -LogWriter $LogWriter
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
