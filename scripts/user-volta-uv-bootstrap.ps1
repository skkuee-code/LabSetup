<#
.SYNOPSIS
  各ユーザー用の Volta/uv を初期化し、Node LTS / npm / TypeScript を整備します。
#>
[CmdletBinding()]
param(
  [switch]$SkipTypeScript,
  [switch]$SkipYarn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Command([string]$cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Ensure-Tool {
  param([string]$Name, [scriptblock]$Check, [scriptblock]$Install)
  if (-not (& $Check)) {
    Write-Host "Installing $Name ..." -ForegroundColor Cyan
    & $Install
  } else {
    Write-Host "$Name already available."
  }
}

# Volta の確認・導入（ユーザースコープ）
Ensure-Tool -Name 'Volta' `
  -Check { Test-Command 'volta' } `
  -Install { winget install -e --id Volta.Volta --scope user --accept-package-agreements --accept-source-agreements }

Write-Host "Running 'volta setup' ..." -ForegroundColor Cyan
volta setup | Out-Host

# Node LTS / npm / TypeScript / yarn（必要に応じて）
if (-not (volta list | Select-String -SimpleMatch 'Node')) {
  volta install node@lts
}
volta install npm
if (-not $SkipTypeScript) { volta install typescript }
if (-not $SkipYarn) { volta install yarn }

# uv の確認・導入（ユーザースコープ）
Ensure-Tool -Name 'uv' `
  -Check { Test-Command 'uv' } `
  -Install { winget install -e --id astral-sh.uv --scope user --accept-package-agreements --accept-source-agreements }

Write-Host "`nVolta + uv bootstrap complete." -ForegroundColor Green
Write-Host "Examples:"
Write-Host "  uv venv; uv run python --version"
Write-Host "  npx tsc --init   # またはプロジェクトで devDependencies に typescript を追加"
