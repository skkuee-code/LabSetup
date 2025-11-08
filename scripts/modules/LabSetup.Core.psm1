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

function Get-MsiProductInstallInfo {
    param(
        [Parameter(Mandatory)]
        [string]$ProductCode
    )

    if ([string]::IsNullOrWhiteSpace($ProductCode)) {
        return $null
    }

    $code = $ProductCode.Trim()
    if ($code.StartsWith('{') -and $code.EndsWith('}')) {
        $code = $code
    } else {
        $trimmed = $code.Trim('{}')
        $code = '{{0}}' -f $trimmed
    }
    $code = $code.ToUpperInvariant()

    $candidateKeys = @(
        "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$code",
        "HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$code"
    )

    foreach ($keyPath in $candidateKeys) {
        if (-not (Test-Path -LiteralPath $keyPath)) {
            continue
        }

        try {
            $values = Get-ItemProperty -LiteralPath $keyPath
        }
        catch {
            continue
        }

        $info = @{
            ProductCode     = $code
            RegistryPath    = $keyPath
            DisplayName     = Get-OptionalPropertyValue -InputObject $values -PropertyName 'DisplayName'
            DisplayVersion  = Get-OptionalPropertyValue -InputObject $values -PropertyName 'DisplayVersion'
            InstallLocation = Get-OptionalPropertyValue -InputObject $values -PropertyName 'InstallLocation'
        }

        $parsedVersion = $null
        $versionText = $info.DisplayVersion
        if ($versionText -and [System.Version]::TryParse($versionText, [ref]$parsedVersion)) {
            $info['ParsedVersion'] = $parsedVersion
        }

        return $info
    }

    return $null
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

function Set-LabDirectoryWritable {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    New-LabDirectory -Path $Path
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        return
    }

    try {
        $usersSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
        $usersAccount = $usersSid.Translate([System.Security.Principal.NTAccount])
    }
    catch {
        return
    }

    $hasModifyRule = $false
    foreach ($entry in $acl.Access) {
        if ($entry.IdentityReference -eq $usersAccount -and $entry.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow) {
            $rights = $entry.FileSystemRights
            $hasModify = (($rights -band [System.Security.AccessControl.FileSystemRights]::Modify) -eq [System.Security.AccessControl.FileSystemRights]::Modify)
            $hasFull = (($rights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq [System.Security.AccessControl.FileSystemRights]::FullControl)
            if ($hasModify -or $hasFull) {
                $hasModifyRule = $true
                break
            }
        }
    }

    if (-not $hasModifyRule) {
        $inheritFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($usersAccount, [System.Security.AccessControl.FileSystemRights]::Modify, $inheritFlags, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
        try {
            Set-Acl -LiteralPath $Path -AclObject $acl
        }
        catch {
            # If the ACL cannot be updated, continue without failing the provisioning run.
        }
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
        [string]$Path,
        [switch]$Prepend
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $target = $Path.Trim()
    $comparisonTarget = $target.TrimEnd('\')
    $comparison = [System.StringComparison]::OrdinalIgnoreCase

    $matchesTarget = {
        param([string]$Segment)
        if ([string]::IsNullOrWhiteSpace($Segment)) { return $false }
        $normalizedSegment = $Segment.Trim().TrimEnd('\')
        return $normalizedSegment.Equals($comparisonTarget, $comparison)
    }

    $machineCurrent = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $machineSegments = @()
    if ($machineCurrent) {
        foreach ($segment in ($machineCurrent -split ';')) {
            if (-not [string]::IsNullOrWhiteSpace($segment)) {
                $machineSegments += $segment.Trim()
            }
        }
    }

    $machineHasTarget = $false
    foreach ($segment in $machineSegments) {
        if (& $matchesTarget $segment) {
            $machineHasTarget = $true
            break
        }
    }

    $machineNeedsUpdate = $false
    if ($Prepend) {
        $filteredMachineSegments = @()
        foreach ($segment in $machineSegments) {
            if (-not (& $matchesTarget $segment)) {
                $filteredMachineSegments += $segment
            }
        }
        $machineSegments = @($target) + $filteredMachineSegments
        $machineNeedsUpdate = $true
    }
    elseif (-not $machineHasTarget) {
        $machineSegments = $machineSegments + $target
        $machineNeedsUpdate = $true
    }

    if ($machineNeedsUpdate) {
        [Environment]::SetEnvironmentVariable('Path', ($machineSegments -join ';'), 'Machine')
    }

    $processSegments = @()
    if ($env:Path) {
        foreach ($segment in ($env:Path -split ';')) {
            if (-not [string]::IsNullOrWhiteSpace($segment)) {
                $processSegments += $segment.Trim()
            }
        }
    }

    $processHasTarget = $false
    foreach ($segment in $processSegments) {
        if (& $matchesTarget $segment) {
            $processHasTarget = $true
            break
        }
    }

    $processNeedsUpdate = $false
    if ($Prepend) {
        $filteredProcessSegments = @()
        foreach ($segment in $processSegments) {
            if (-not (& $matchesTarget $segment)) {
                $filteredProcessSegments += $segment
            }
        }
        $processSegments = @($target) + $filteredProcessSegments
        $processNeedsUpdate = $true
    }
    elseif (-not $processHasTarget) {
        $processSegments = $processSegments + $target
        $processNeedsUpdate = $true
    }

    if ($processNeedsUpdate) {
        $env:Path = ($processSegments -join ';')
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
