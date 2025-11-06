<#
.SYNOPSIS
  VS Code 拡張（Ruff / Markdown / LaTeX / Quarto / Lean4）をユーザープロファイルに導入します。
#>
[CmdletBinding()]
param(
  [switch]$PreRelease   # 必要ならプレリリース拡張も取得
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# code CLI の探索
$codeCandidates = @(
  (Get-Command code -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
  "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
  "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd",
  "${env:ProgramFiles(x86)}\Microsoft VS Code\bin\code.cmd"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

# パイプ結果が1件でも配列化
$codeCandidates = @($codeCandidates)

if (-not $codeCandidates -or $codeCandidates.Count -eq 0) {
  throw "VS Code CLI 'code' が見つかりません。VS Code を起動して PATH を反映後に再実行してください。"
}
# ここで [0] を取っても安全
$codeCmd = $codeCandidates[0]

$extensions = @(
  'charliermarsh.ruff',
  'yzhang.markdown-all-in-one',
  'shd101wyy.markdown-preview-enhanced',
  'James-Yu.latex-workshop',
  'quarto.quarto',
  'leanprover.lean4'
)

# 既存拡張の取得
$installed = & $codeCmd --list-extensions 2>$null  # CLI オプションは公式ドキュメントを参照
# --list-extensions / --install-extension の公式仕様
# https://code.visualstudio.com/docs/configure/command-line
# （該当セクションの抜粋は下記参照） :contentReference[oaicite:3]{index=3}

foreach ($ext in $extensions) {
  if ($installed -and $installed -contains $ext) {
    Write-Host "Already installed: $ext"
  } else {
    $args = @('--install-extension', $ext)
    if ($PreRelease) {
      # VS Code CLI は --pre-release をサポート
      $args += '--pre-release'
      # 参考: CLI における --pre-release フラグの議論（VS Code Issue Tracker）
      # Eg: code --install-extension pub.name --pre-release
      # https://github.com/microsoft/vscode/issues/143540 :contentReference[oaicite:4]{index=4}
    }
    & $codeCmd @args
  }
}

Write-Host "VS Code extensions setup completed." -ForegroundColor Green
