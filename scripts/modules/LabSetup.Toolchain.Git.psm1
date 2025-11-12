function Set-GitLfsConfiguration {
    param(
        [System.IO.StreamWriter]$LogWriter
    )

    $gitExe = Resolve-ExecutableFromCandidates -Candidates @(
        (Join-Path -Path ${env:ProgramFiles} -ChildPath 'Git\cmd\git.exe'),
        (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Git\cmd\git.exe'),
        'git'
    )
    if (-not $gitExe) {
        Write-LabLog -Message 'git executable not found; skipping Git LFS configuration.' -LogWriter $LogWriter
        return
    }

    Write-LabLog -Message 'Initializing Git LFS...' -LogWriter $LogWriter
    & $gitExe 'lfs' 'install' '--system' | Out-Null
}
