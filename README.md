# LabSetup for Shared Windows PCs
**winget + uv + Volta + Quarto + MiKTeX + VS Code extensions（共用PC向け）**

このリポジトリは、研究室などの**共用 Windows PC**を短時間で同一構成に整えるための「構成ファイルとスクリプト」を提供します。  
- **パッケージ導入**：winget（WinGet Configuration / DSC）  
- **Python**：uv（各ユーザーで安全・高速な環境管理）  
- **TypeScript/Node**：Volta（各ユーザーのツールチェーン固定）  
- **執筆**：Quarto + MiKTeX（LaTeX）ですぐ PDF 生成  
- **エディタ**：VS Code（Ruff、Markdown、LaTeX、Quarto、Lean4 拡張を配布）

> 目的は「**手戻りの少ない再現性**」「**共用機でも衝突の少ないユーザー単位運用**」「**管理コストの低さ**」です。

---

## 1. リポジトリ構成

```
.
├─ config/
│   └─ lab-dev.uv-volta-quarto.winget.yaml     # WinGet Configuration（宣言的セットアップ）
├─ scripts/
│   ├─ deploy-to-programdata.ps1               # このリポジトリを ProgramData へ配備（管理者）
│   ├─ apply-winget-config.ps1                 # winget configure を実行（管理者）
│   ├─ post-miktex-config.ps1                  # MiKTeX 自動導入を有効化（管理者）
│   ├─ create-shortcuts.ps1                    # 全ユーザー向けショートカット作成（管理者）
│   ├─ register-winget-upgrade-task.ps1        # winget 自動アップグレードのタスク登録（管理者）
│   ├─ setup-vscode-extensions.ps1             # VS Code 拡張の導入（各ユーザー）
│   └─ user-volta-uv-bootstrap.ps1             # Volta/uv の初期化（各ユーザー）
└─ README.md
```

- **正本**（編集・履歴管理）はこのリポジトリに置きます。
- **各PCでの実行用コピー**は `C:\ProgramData\LabSetup\` に展開します（既定のスクリプトで配備）。

---

## 2. 動作要件

- Windows 11 以降（22H2+ 推奨）
- 管理者で実行できる環境（*管理者がやる作業*と*各ユーザーがやる作業*に分かれます）
- **winget** 利用可（Microsoft Store/ソース更新がブロックされていない）
- ネットワークがパッケージ配布サイトに到達可能（プロキシ環境は OS/WinHTTP 側で設定）

---

## 3. クイックスタート（最短手順）

### 3.1 管理者が一度だけ行う作業
1. **リポジトリをクローン**（例：`C:\Temp\LabSetup`）
2. **ProgramData へ配備**（既定パス `C:\ProgramData\LabSetup`）  
   ```powershell
   # 実行は管理者 PowerShell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   C:\Temp\LabSetup\scripts\deploy-to-programdata.ps1
   ```
3. **winget 構成の適用**（主要アプリの一括導入）  
   ```powershell
   C:\ProgramData\LabSetup\scripts\apply-winget-config.ps1
   ```
4. **MiKTeX の自動パッケージ導入を有効化**  
   ```powershell
   C:\ProgramData\LabSetup\scripts\post-miktex-config.ps1
   ```
5. **共用ショートカットを配布**（全ユーザーのスタートメニューに導線を作成）  
   ```powershell
   C:\ProgramData\LabSetup\scripts\create-shortcuts.ps1 -PublicDesktop
   ```
6. **自動アップデートのタスク登録（任意）**  
   ```powershell
   C:\ProgramData\LabSetup\scripts\register-winget-upgrade-task.ps1
   ```

### 3.2 研究室メンバー（各ユーザー）が行う作業
- スタートメニュー → **Lab Setup** から以下をクリック
  1. **Initialize Volta + uv (per-user)**  
     → Volta を初期化し、Node LTS / npm / TypeScript を固定。uv を導入。
  2. **Initialize VS Code extensions**  
     → Ruff、Markdown、LaTeX、Quarto、Lean4 の拡張を自分のプロファイルに導入。

> VS Code の拡張は**ユーザー単位**でインストールされます（全ユーザー一括は非標準）。  
> Volta/uv も**ユーザー単位**の PATH に入るため、ユーザーごとに初期化します。

---

## 4. テスト（セットアップ確認）

- **Quarto / LaTeX（PDF 出力）**
  ```powershell
  quarto check
  # サンプル: 任意の .qmd で
  quarto render .\hello.qmd --to pdf
  ```
- **Volta / TypeScript**
  ```powershell
  node -v
  tsc -v
  ```
- **uv / Python**
  ```powershell
  uv --version
  uv venv
  uv run python --version
  ```

---

## 5. 運用・更新

- 週1回の自動更新タスク（`register-winget-upgrade-task.ps1`）を有効にすると、  
  `winget upgrade --all --silent` を SYSTEM で実行し、ログを `C:\ProgramData\LabSetup\logs\` に残します。
- 構成変更（アプリ追加/削除）は `config/*.winget.yaml` を編集 → 管理者が再度 `apply-winget-config.ps1` を実行します。

---

## 6. カスタマイズの勘所

- **VS Code 拡張**：`scripts/setup-vscode-extensions.ps1` の `$extensions` 配列を編集  
- **ユーザー初期化**（Volta/uv）：`scripts/user-volta-uv-bootstrap.ps1` 内の `volta install` ラインを調整  
- **ショートカット名**：`scripts/create-shortcuts.ps1` の `-MenuFolderName` で変更  
- **配置先**：`C:\ProgramData\LabSetup` を別ドライブにしたい場合、各スクリプトの `-BaseDir`/`-Destination` を指定

---

## 7. トラブルシューティング

- **`code` コマンドが見つからない**  
  → VS Code を一度起動して PATH を反映するか、`C:\Program Files\Microsoft VS Code\bin\code.cmd` を使用してください。
- **`winget configure` が失敗する**  
  → ネットワーク（プロキシ）とソース更新（`winget source update`）を確認。再実行は冪等です。
- **MiKTeX で不足パッケージエラー**  
  → 本リポジトリの `post-miktex-config.ps1` を管理者で実行し、AutoInstall を有効化後に再試行。
- **Windows Terminal を machine スコープにできない**  
  → user スコープで入る場合があります（設計上の仕様）。実害はありません。
 
---

## 8. ライセンス / 注意
- 本リポジトリはセットアップ手順のテンプレートです。各ツールのライセンスに従ってご利用ください。
- 共用PCでは、**標準ユーザー運用**と**BitLocker/Defender**などの基本セキュリティ対策を推奨します。
