function Join-LabCommandLineArguments {
    param(
        [string[]]$Arguments
    )

    if (-not $Arguments) {
        return ''
    }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($argument in $Arguments) {
        if ($null -eq $argument) {
            continue
        }

        if ($builder.Length -gt 0) {
            [void]$builder.Append(' ')
        }

        if ($argument.Length -eq 0) {
            [void]$builder.Append('""')
            continue
        }

        $needsQuotes = $false
        foreach ($ch in $argument.ToCharArray()) {
            if ([char]::IsWhiteSpace($ch) -or $ch -eq '"') {
                $needsQuotes = $true
                break
            }
        }

        if (-not $needsQuotes) {
            [void]$builder.Append($argument)
            continue
        }

        $escaped = $argument -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        [void]$builder.Append('"').Append($escaped).Append('"')
    }

    return $builder.ToString()
}

function Show-LabProcessSpinner {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,
        [string]$Activity = 'Processing',
        [int]$UpdateIntervalMilliseconds = 200
    )

    $activityLabel = if ([string]::IsNullOrWhiteSpace($Activity)) { 'Processing' } else { $Activity }
    $spinnerChars = @('|', '/', '-', '\')
    $progressId = Get-Random
    $index = 0

    if ($Process.HasExited) {
        Write-Progress -Activity $activityLabel -Completed -Id $progressId
        return
    }

    while (-not $Process.HasExited) {
        $status = "{0} {1}" -f $activityLabel, $spinnerChars[$index]
        Write-Progress -Activity $activityLabel -Status $status -PercentComplete -1 -Id $progressId
        Start-Sleep -Milliseconds $UpdateIntervalMilliseconds
        $index = ($index + 1) % $spinnerChars.Length
    }

    Write-Progress -Activity $activityLabel -Completed -Id $progressId
}

function Invoke-ProcessWithSpinner {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$Activity,
        [string]$WorkingDirectory
    )

    $startParams = @{
        FilePath     = $FilePath
        ArgumentList = $ArgumentList
        NoNewWindow  = $true
        PassThru     = $true
    }

    if ($WorkingDirectory) {
        $startParams['WorkingDirectory'] = $WorkingDirectory
    }

    try {
        $process = Start-Process @startParams
    }
    catch {
        throw "Failed to start ${FilePath}: $($_.Exception.Message)"
    }

    if (-not $process) {
        throw "Failed to launch $FilePath."
    }

    Show-LabProcessSpinner -Process $process -Activity $Activity
    $process.WaitForExit()
    return $process
}

function Get-LabProcessExitCode {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )

    try {
        return [int]$Process.ExitCode
    }
    catch {
        return $null
    }
}
