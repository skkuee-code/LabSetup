# register-winget-upgrade-task.ps1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  winget upgrade を SYSTEM/最高権限で定期実行するタスクを登録します。
#>
[CmdletBinding()]
param(
  [string]$TaskName = 'Winget-Upgrade-All',
  [string]$LogDir   = 'C:\ProgramData\LabSetup\logs',
  [ValidateSet('Daily','Weekly')][string]$Frequency = 'Weekly',
  [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')][string]$Day = 'Monday',
  # その日の 03:00 を既定に（DateTime）
  [datetime]$At = ([datetime]::Today.AddHours(3))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# 実行コマンド（実行時に $(Get-Date) が評価される）
$psCmd = 'winget source update; winget upgrade --all --include-unknown --silent --accept-package-agreements --accept-source-agreements | Tee-Object -FilePath "{0}\upgrade-$(Get-Date -Format yyyyMMdd-HHmm).log" -Append' -f $LogDir

# 非表示で PowerShell を起動
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$psCmd`""

# トリガー（ここを -At $At に）
if ($Frequency -eq 'Daily') {
  $trigger = New-ScheduledTaskTrigger -Daily  -At $At
} else {
  $dow = [System.DayOfWeek]::$Day
  $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dow -At $At
}

# SYSTEM / Highest
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
Write-Host ("Registered task '{0}' ({1} at {2})" -f $TaskName, $Frequency, $At.ToString('HH:mm')) -ForegroundColor Green
