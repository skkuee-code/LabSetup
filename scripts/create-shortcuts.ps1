#Requires -RunAsAdministrator
<#
.SYNOPSIS
  全ユーザーのスタートメニュー（任意で Public Desktop）にショートカットを設置します。
#>
[CmdletBinding()]
param(
  [string]$MenuFolderName = 'Lab Setup',
  [string]$BaseDir        = 'C:\ProgramData\LabSetup',
  [switch]$PublicDesktop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 共通のスタートメニュー フォルダー（全ユーザー）
$smDir = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$MenuFolderName"
New-Item -ItemType Directory -Path $smDir -Force | Out-Null

function Get-HostPowerShell {
  <#
    pwsh が複数見つかる環境（Microsoft Store 由来の WindowsApps エイリアスなど）では
    実体のパスを優先し、無ければ Windows PowerShell にフォールバックします。
    ※ Select-Object は -First と -ExpandProperty を同時に使わない（別のパラメーター セットのため）
  #>
  $pwshCmd = Get-Command pwsh -All -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -notmatch '\\WindowsApps\\') } |
    Select-Object -First 1

  if ($pwshCmd) { return $pwshCmd.Path }

  $ps5Cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue |
            Select-Object -First 1
  if ($ps5Cmd) { return $ps5Cmd.Path }

  # 最後の手段（PATH 依存）
  return 'powershell.exe'
}

function New-Shortcut {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Target,
    [string]$ArgumentList,
    [string]$Description,
    [string]$WorkingDirectory,
    [string]$IconLocation
  )
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($Path)
  $sc.TargetPath = $Target
  if ($ArgumentList)     { $sc.Arguments        = $ArgumentList }  # 引数は .Arguments に入れる
  if ($Description)      { $sc.Description      = $Description }
  if ($WorkingDirectory) { $sc.WorkingDirectory = $WorkingDirectory }
  if ($IconLocation)     { $sc.IconLocation     = $IconLocation }
  $sc.Save()
}

# スクリプトを実行するショートカットを作るためのヘルパー
function Add-ScriptShortcut {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$ScriptPath,
    [string]$Description
  )
  $hostExe        = Get-HostPowerShell
  $scriptFullPath = $ScriptPath
  $args           = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$scriptFullPath`""
  $wd             = Split-Path -Path $scriptFullPath -Parent

  $lnkPath = Join-Path $smDir "$Name.lnk"
  New-Shortcut -Path $lnkPath `
               -Target $hostExe `
               -ArgumentList $args `
               -Description $Description `
               -WorkingDirectory $wd
}

# ---- ここから個別のショートカット定義 ----

# 1) winget configure を適用
Add-ScriptShortcut -Name 'Apply WinGet configuration' `
  -ScriptPath (Join-Path $BaseDir 'scripts\apply-winget-config.ps1') `
  -Description 'Run winget configure to apply the lab base image'

# 2) VS Code 拡張（ユーザー単位）
Add-ScriptShortcut -Name 'Initialize VS Code extensions' `
  -ScriptPath (Join-Path $BaseDir 'scripts\setup-vscode-extensions.ps1') `
  -Description 'Install curated VS Code extensions (per-user)'

# 3) Volta + uv（ユーザー単位）初期化
Add-ScriptShortcut -Name 'Initialize Volta + uv (per-user)' `
  -ScriptPath (Join-Path $BaseDir 'scripts\user-volta-uv-bootstrap.ps1') `
  -Description 'Set up Node(LTS)+TypeScript via Volta and uv'

# 4) README を開く（既定アプリで開く）
$readmePath = Join-Path $BaseDir 'README.md'
New-Shortcut -Path (Join-Path $smDir 'Open Lab README.lnk') `
  -Target 'explorer.exe' `
  -ArgumentList "`"$readmePath`"" `
  -Description 'Open the lab setup README' `
  -WorkingDirectory $BaseDir

# 必要に応じて Public Desktop にも配布
if ($PublicDesktop) {
  Copy-Item (Join-Path $smDir 'Initialize VS Code extensions.lnk') "$env:PUBLIC\Desktop" -Force
  Copy-Item (Join-Path $smDir 'Initialize Volta + uv (per-user).lnk') "$env:PUBLIC\Desktop" -Force
}

Write-Host "Shortcuts created in: $smDir" -ForegroundColor Green
if ($PublicDesktop) { Write-Host "Public Desktop shortcuts created." -ForegroundColor Green }
