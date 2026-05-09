---
name: ship-pr
description: PR 作成前の検証パイプライン。format / lint / typecheck / test を一括実行し、全て通過した場合のみ PR を作成する。
---

# PR を出す前の検証パイプライン

このスキルは `/issue-flow:issue-next` の PR 前検証を単独で実行するためのもの。

pnpm を使うワークスペース前提。コマンド名・スクリプト名はプロジェクトに合わせて読み替える。

## 手順

以下を順番に実行し、**失敗したステップで止めてエラーを提示する**。全てが通過したら PR を作成する。

### Step 1: フォーマット

```bash
pnpm format
```

変更があれば自動修正される。修正されたファイルがあれば `git add` でステージに加える。

### Step 2: Lint

```bash
pnpm lint
```

エラーが出た場合は修正してから次へ進む。警告のみで進めてよいかユーザーに確認する。

### Step 3: Typecheck

プロジェクトに `typecheck` スクリプトがあれば実行する（モノレポの場合は対象パッケージで実行）:

```bash
pnpm typecheck
# または
pnpm -C <package> typecheck
```

`packages` を触っていない場合はスキップしてよい。エラーが出た場合は修正してから次へ進む。

### Step 4: Lockfile チェック

`package.json` に変更がある場合のみ実行:

```bash
pnpm install
```

`pnpm-lock.yaml` が更新された場合は `git add pnpm-lock.yaml` でステージに加える。

### Step 5: テスト

```bash
pnpm test
# または
pnpm -C <package> test
```

失敗したテストがあれば修正してから次へ進む。

### Step 6: コミットと PR 作成

全ステップ通過後:

1. 未コミットの変更があればコミット:
   ```bash
   git add <変更ファイル>
   git commit -m "feat/fix/...: {タイトル} (#{番号})"
   ```
2. push:
   ```bash
   git push -u origin {ブランチ名}
   ```
3. PR 作成（`Closes #{番号}` を body に含める）:
   ```bash
   gh pr create --title "..." --body "..."
   ```
4. PR URL をユーザーに伝える。

## ガードレール

- Step で失敗したら自動で続行しない。エラーを提示してユーザーに対応を確認する。
- format の自動修正以外のコード変更は行わない。lint/typecheck エラーを修正する場合は内容をユーザーに提示する。
- **本プラグインの hooks（`gh pr create` 直前の format/lint）と重複するが、PR 作成前に明示実行することで早期にエラーを検知する。**
