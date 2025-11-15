# LabSetup Windowsプロビジョニングツールキット

LabSetupは、教室や研究室のPC向けに、マシン単位でのアプリケーション展開、一般的な開発ツールチェーン、TeXパブリッシングの前提条件のインストールを自動化し、セットアップを効率化します。このリポジトリは現在、以下の3つのスクリプト化されたステージに焦点を当てています。

1. 管理されたコピーとして、このリポジトリを `C:\ProgramData\LabSetup` に展開します。
2. すべてのユーザーのデスクトップに「Lab Setup」ショートカットを発行します。
3. すべてをインストール、ピン留め、設定する統合されたマシンブートストラップを実行します。

---

## リポジトリのレイアウト

```
.
+-- config/
|   \-- lab-setup-config.json        # パッケージのメタデータ + タスクバーへのピン留めターゲット
+-- scripts/
|   +-- Deploy-LabSetup.ps1          # ProgramDataにリポジトリをミラーリング (管理者)
|   +-- Publish-SetupShortcut.ps1    # Lab Setupデスクトップショートカットを作成 (管理者)
|   +-- Setup-LabMachine.ps1         # アプリ/ツールチェーンのインストール、タスクバーへのピン留め、出力のログ記録 (管理者)
|   \-- LabSetup.Common.psm1         # winget + タスクバーヘルパーを含む共有モジュール
\-- README.md
```

すべてのスクリプトは、4スペースのインデント、承認された動詞を維持し、本番用のミラーリングのために `C:\ProgramData\LabSetup` にコピーする前に、その場で実行されます。

---

## 前提条件

- Windows 11 22H2以降で、Windowsパッケージマネージャー（winget）が利用可能であること。
- Microsoftおよびベンダーのフィードにアクセスするためのインターネット接続を備えた管理者PowerShellセッション。
- `C:\ProgramData` および `C:\Users\Public\Desktop` への書き込み権限。

---

## エンドツーエンドのワークフロー

1. **管理コピーの展開（管理者）**

    ```powershell
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    .\scripts\Deploy-LabSetup.ps1 -SourcePath (Get-Location) -DestinationPath 'C:\ProgramData\LabSetup' -Mirror
    ```

    - `.git`、`.github`、`logs`、`cache` ディレクトリを除外しながら、`robocopy` を使用してリポジトリをミラーリングします。
    - 管理者がフルコントロールを持ち、ユーザーが読み取りと実行権限を持つようにACLを設定します。

2. **デスクトップショートカットの発行（管理者）**

    ```powershell
    C:\ProgramData\LabSetup\scripts\Publish-SetupShortcut.ps1 -Force
    ```

    - `C:\Users\Public\Desktop\Lab Setup.lnk` を作成し、実行ポリシーバイパス付きで `Setup-LabMachine.ps1` を指すようにします。

3. **ワークステーションのプロビジョニング（管理者）**

    ```powershell
    C:\ProgramData\LabSetup\scripts\Setup-LabMachine.ps1
    ```

    - Slack、Visual Studio Code、Google Chrome、LTspice、Git、Git LFS、GitHub CLI、Quartoを `winget install --scope machine` でインストールし、パッケージがProgram Files以下に配置されるようにします。
    - コミュニティのwingetフィードで公開されていないため、ベンダーのMSIからLayoutEditorをダウンロードしてインストールします。
    - uvで管理されるPython（`uv python install 3.12`）を設定し、共有インタープリターのために `UV_PYTHON_INSTALL_DIR` をProgramData以下に設定します。
    - Voltaのツールチェーンの場所をProgramData内に設定し、Node LTSをインストールし、`volta install` を介してグローバルにTypeScriptを追加します。
    - `install-tl-windows.exe --profile ...` を使ってTeX Live (scheme-full) を `C:\texlive\2025` に展開し、`tlmgr option repository`, `tlmgr path add --windowsmode=admin`, `mktexlsr` でパスとファイル名データベースを整えます。
    - 実行可能ファイルのパスを確認した後、Slack、VS Code、Chrome、LTspice、LayoutEditorをタスクバーにピン留めします。
    - コンソール出力を `C:\ProgramData\LabSetup\logs\LabSetup_yyyyMMdd_HHmmss.log` にストリーミングします。

各ステップはべき等です。`config\lab-setup-config.json` が変更された場合は、マシンセットアップスクリプトを再実行してください。

---

## `Setup-LabMachine.ps1` がカバーする内容

| フェーズ | 詳細 |
| --- | --- |
| **パッケージインストール** | `wingetPackages` エントリを反復処理し、`--scope machine --accept-package-agreements --accept-source-agreements` を付けてwingetを呼び出します。手動インストーラー（現在はLayoutEditor MSI）は `ProgramData\LabSetup\cache` にキャッシュされます。 |
| **タスクバーへのピン留め** | 設定ファイルで定義された再試行回数で、Shell COM動詞（`taskbarpin`）を使用します。
| **Voltaツールチェーン** | `VOLTA_HOME` を設定し、`bin` を作成し、PATHに追加し、Volta経由でNode LTSとTypeScriptをインストールします。 |
| **uvツールチェーン** | `UV_HOME`、`UV_PYTHON_INSTALL_DIR` を設定し、`bin` をPATHに追加し、uvを介してPython 3.12をインストールします。 |
| **Git + LFS** | wingetがGitとGit LFSをインストールした後、`git lfs install --system` を実行します。
| **TeXプロビジョニング** | TeX Live用に `install-tl-windows.exe --profile <ProgramData\cache\texlive.profile>` を起動し、`tlmgr option repository ...` と `tlmgr path add --windowsmode=admin` 後に `mktexlsr` を実行します。 |
| **ロギング** | すべてのアクションは、標準出力とともに `ProgramData\LabSetup\logs` 以下にログ記録されます。

---

## 設定リファレンス (`config\lab-setup-config.json`)

- `wingetPackages`: `id`、`displayName`、オプションの `version`、`pinToTaskbar` を持つオブジェクトの配列。`installer` ブロックを含むエントリは、カスタムインストーラーワークフローを実行します（LayoutEditorに使用）。
- `volta`: 目的のNodeリリース（`nodeVersion`）と、Volta経由でインストールするグローバルパッケージ。
- `uv`: プロビジョニングするPythonのバージョン。それぞれが `uv python install` でインストールされ、ProgramDataを介して共有されます。
- `git`: `git lfs install --system` を実行するための `configureLfs` の切り替え。
- `tex`: TeX Liveディストリビューションの設定（`installDir`、`profile.lines`、`tlmgr.repository`、`postInstall.refreshFileDatabase` など）。
- `taskbar`: ピン留め操作の再試行回数と遅延（秒）。

バージョンを上げたり、ソフトウェアを追加したりする場合は、JSONファイルを更新してから `Setup-LabMachine.ps1` を再実行して変更を適用します。

---

## 検証チェックリスト

1. **winget**

    ```powershell
    winget list --scope machine --id SlackTechnologies.Slack
    winget list --scope machine --id Microsoft.VisualStudioCode
    winget list --scope machine --id GitHub.cli
    ```

2. **Volta/TypeScript**

    ```powershell
    $env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine')
    node --version
    tsc --version
    ```

3. **uv/Python**

    ```powershell
    uv python list
    python --version
    ```

4. **TeX**

    ```powershell
    initexmf --admin --report | Select-String AutoInstall
    quarto check
    ```

5. **デスクトップエクスペリエンス**
    - 標準ユーザープロファイルでタスクバーのピンが存在し、起動することを確認します。
    - `C:\ProgramData\LabSetup\logs` に最新の実行ログが含まれていることを検証します。

---

## メンテナンスのヒント

- **パッケージの更新**: `lab-setup-config.json` を編集し、`Setup-LabMachine.ps1` を再実行します。LayoutEditorの場合は、ベンダーポータルからMSIダウンロードURLを更新します。
- **追加のソフトウェア**: `wingetPackages` に別のオブジェクトを追加します。変更をコミットする前に、マニフェストがマシンスコープをサポートしていることを確認してください。
- **ショートカットのカスタマイズ**: ラボ固有の名前には `Publish-SetupShortcut.ps1 -ShortcutName 'Robotics Setup.lnk'` を使用します。
- **キャッシュ/ログの整理**: ディスク容量が限られている場合は、`ProgramData\LabSetup\cache` と `logs` を定期的に削除します。

---

## トラブルシューティング

- **スコープに関するwingetエラー**: 一部のマニフェストはマシンインストールをサポートしていません。新しいパッケージを追加する前にサポートを確認してください。
- **タスクバーのピンが見つからない**: Explorerがショートカットの作成を完了した後、`Setup-LabMachine.ps1 -SkipVolta -SkipUv -SkipTeX -SkipGitLfs` を再実行して、ピン留めフェーズに集中します。
- **uvがPATHにない**: 現在のセッションでマシンのPATHを再読み込みするか（`$env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine')`）、再起動して環境の変更を継承します。
- **TeX Liveがパッケージを要求する**: `Setup-LabMachine.ps1` を再実行するか、`tlmgr install <package>` を管理者PowerShellで実行して不足分を追加します。
- **LayoutEditorの更新が必要**: 設定ファイル内のMSI URLを置き換えます。スクリプトは新しいビルドをキャッシュにダウンロードし、`msiexec` を介して再インストールします。

---

## ロードマップのアイデア

- バックグラウンドでのパッチ適用のために、`winget upgrade --all --scope machine --silent` をラップするスケジュールされたタスクを追加します。
- マシンスコープのマニフェストが確認されたら、追加のエンジニアリングソフトウェア（例：KiCad、Fusion 360）で設定を拡張します。
- `Setup-LabMachine.ps1` をイメージング/MDTパイプラインにエクスポートして、教室を大規模に事前プロビジョニングします。

これらの変更により、ラボ管理者は3つのコマンドを実行するだけで、コミュニケーション、コーディング、シミュレーション、およびパブリッシングのツールチェーンをカバーする、一貫性のある、すぐに教えられるWindows環境を受け取ることができます。
