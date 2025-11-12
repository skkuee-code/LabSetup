GitHub Templates
=================

共通の Issue/PR テンプレートを配布するリポジトリです。任意のリポジトリにサブモジュールとして追加することで、`.github` ディレクトリ一式を即座に導入できます。

収録内容
--------

- `ISSUE_TEMPLATE/01-bug.yml`: バグ報告用テンプレート
- `ISSUE_TEMPLATE/02-feature.yml`: 機能要望用テンプレート
- `ISSUE_TEMPLATE/03-docs.yml`: ドキュメント改善用テンプレート
- `ISSUE_TEMPLATE/config.yml`: Issue テンプレートのメタ設定
- `pull_request_template.md`: プルリクエストのテンプレート

クイックスタート（サブモジュール）
----------------------------------

リポジトリ直下に `.github` サブモジュールとして追加します。

```bash
git submodule add -b main https://github.com/RK0429/GitHubTemplates.git .github
git add .gitmodules .github
git commit -m "chore: add GitHub templates submodule"
git push
```

クローン時は以下のいずれかでサブモジュールを取得します。

```bash
git clone --recurse-submodules <your-repo-url>
# 既存クローンの場合:
git submodule update --init --recursive
```

更新方法（サブモジュール）
--------------------------

テンプレートの最新化は、親リポジトリ側でサブモジュールを更新してコミットします。

```bash
# まとめて更新（推奨）
git submodule update --remote --merge .github
git add .github
git commit -m "chore: bump .github templates"

# または明示的に .github 内で pull
git -C .github fetch origin main
git -C .github checkout main
git -C .github pull --ff-only
git add .github && git commit -m "chore: bump .github templates"
```

注意点 / 制約
-------------

- `.github` ディレクトリをサブモジュールにすると、親リポジトリから `.github` 直下に追加・編集はできません。
  - 例: リポジトリ固有の `CODEOWNERS` や `dependabot.yml` を併置したい場合は、後述の `git subtree` またはコピー導入を検討してください。
- GitHub の一部機能はサブモジュール内のファイルを解決しません。
  - とくに GitHub Actions のワークフロー（`.github/workflows/*.yml`）はサブモジュール越しでは認識されません。
  - Issue/PR テンプレートはサブモジュールで動作する場合がありますが、環境により反映されない可能性があります。導入後に実際に Issue/PR 画面での表示をご確認ください。

代替導入（推奨: git subtree）
----------------------------

GitHub 側での確実な認識や、リポジトリ固有ファイルの同居が必要な場合は `git subtree` を推奨します。ファイルが親リポジトリの履歴に取り込まれるため、GitHub が確実に検出できます。

```bash
# 追加（初回）
git subtree add --prefix .github https://github.com/RK0429/GitHubTemplates.git main --squash

# 更新（以後）
git subtree pull --prefix .github https://github.com/RK0429/GitHubTemplates.git main --squash
```

カスタマイズ方法
----------------

- サブモジュール運用: 本リポジトリを Fork し、各プロジェクトは Fork 先を `.github` に指すことで共通テンプレートを一括更新しつつ、テンプレート自体は中央管理できます。
- subtree/コピー運用: 親リポジトリの `.github` 配下で直接編集できます（プロジェクト固有の微修正に向いています）。

ライセンス
----------

Apache License 2.0

貢献について
------------

テンプレートの改善提案や追加は Issue/PR で歓迎します。命名・文言・セクション構成の一貫性維持にご協力ください。
