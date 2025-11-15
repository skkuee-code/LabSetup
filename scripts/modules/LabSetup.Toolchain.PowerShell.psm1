function Set-PowerShellToolchain {
    param(
        [hashtable]$Config,
        [System.IO.StreamWriter]$LogWriter
    )

    $package = @{
        id          = 'Microsoft.PowerShell'
        displayName = 'PowerShell 7'
        silent      = $true
        scope       = 'machine'
    }

    try {
        Install-WingetPackage -Package $package -LogWriter $LogWriter -Config $Config
    }
    catch {
        if ($LogWriter) {
            Write-LabLog -Message ("PowerShell 7 install or upgrade failed: {0}" -f $_.Exception.Message) -LogWriter $LogWriter
        }
        throw
    }
}

