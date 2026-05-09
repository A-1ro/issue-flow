# issue-flow

GitHub Issue を 1 件処理する Claude Code プラグイン。`planner → implementer → implementation-reviewer → security-reviewer` の 4 段階サブエージェントを順に走らせ、検証 → PR 作成までをオーケストレートする。

## 同梱物

| 種類 | 名前 | 用途 |
|---|---|---|
| Skill | `issue-flow:issue-next` | Issue 1 件を planner → implementer → review → PR まで自動進行 |
| Skill | `issue-flow:ship-pr` | format / lint / typecheck / test を順に走らせて PR を出す検証パイプライン |
| Agent | `planner` | プラン策定（opus） |
| Agent | `implementer` | 機械的な実装（haiku） |
| Agent | `implementer-sonnet` | 型・generic が絡む複雑な実装（sonnet） |
| Agent | `implementation-reviewer` | プラン・設計ドキュメントとの整合チェック（sonnet） |
| Agent | `security-reviewer` | OWASP / 認証認可 / 機密情報の監査（opus） |
| Hook | PreToolUse on `mcp__github__create_pull_request` | PR 作成直前に `pnpm format && pnpm lint` を強制実行 |

## 前提

- **GitHub MCP** が利用可能（`mcp__github__list_issues` / `mcp__github__get_issue` / `mcp__github__create_issue` / `mcp__github__add_issue_comment` / `mcp__github__create_pull_request`）— 全 PR / Issue 操作を MCP 経由で行うため `gh` CLI には依存しない
- **pnpm** ベースのワークスペースで `pnpm format` / `pnpm lint` が定義されている（pnpm 以外の場合は環境変数で上書き可、後述）
- プロジェクトルートに **`CLAUDE.md`** が置かれていることを推奨（load-bearing rules / 設計ドキュメントへのポインタを記述）

## インストール

### A. ローカルパスから（開発時 / 単一プロジェクトでの試用）

プロジェクトの `.claude/settings.json` でプラグインを参照:

```json
{
  "plugins": [
    "/path/to/issue-flow"
  ]
}
```

### B. Marketplace 経由（推奨）

```
/plugin marketplace add A-1ro/issue-flow
/plugin install issue-flow@issue-flow-marketplace
```

## GitHub MCP のセットアップ

本プラグインは Issue / PR 操作をすべて GitHub MCP 経由で行う。未追加なら以下で登録する。

### 推奨: PAT 認証（公式ホスト型 + Personal Access Token）

GitHub の公式ホスト MCP (`https://api.githubcopilot.com/mcp/`) は OAuth 2.0 dynamic client registration (RFC 7591) をサポートしていないため、Claude Code 側の OAuth フローが `SDK auth failed: Incompatible auth server: does not support dynamic client registration` で失敗する。**PAT を渡す方式が現状の回避策**。

1. **PAT を作成** — https://github.com/settings/personal-access-tokens（fine-grained 推奨）
   - スコープ: `Contents: read/write`, `Issues: read/write`, `Pull requests: read/write`, `Metadata: read`
   - 対象リポジトリは利用するプロジェクトのみに絞ると安全
2. **Claude Code に登録**:

   ```bash
   claude mcp add --transport http --scope user github https://api.githubcopilot.com/mcp/ \
     --header "Authorization: Bearer ghp_YOUR_PAT_HERE"
   ```

   - `--scope user` は全プロジェクトで使えるグローバル登録（`~/.claude.json` に保存）
   - 単一プロジェクトに閉じたい場合は `--scope project`（`.mcp.json` に記録、チーム共有可、ただし PAT を repo に commit しないよう注意 — env 経由推奨）に変更

3. **動作確認**:

   ```bash
   claude mcp list           # 登録済み MCP 一覧
   claude mcp get github     # 接続状態の詳細
   ```

   または Claude Code 内で `/mcp` パネルから接続状態を確認。

### 既存登録を入れ替える場合

```bash
claude mcp remove github -s user            # 既存の壊れた登録を削除
claude mcp add --transport http --scope user github https://api.githubcopilot.com/mcp/ \
  --header "Authorization: Bearer ghp_YOUR_PAT_HERE"
```

### OAuth 方式（将来 GitHub が DCR 対応したら）

```bash
claude mcp add --transport http --scope user github https://api.githubcopilot.com/mcp/
```

追加後 `/mcp` でブラウザ認証。現時点では DCR 未対応で失敗するが、将来 GitHub 側がサポートしたらヘッダ不要になる。

## 使い方

```
/issue-flow:issue-next 42         # Issue #42 を実装
/issue-flow:issue-next             # Open Issue 一覧から候補を提示
/issue-flow:ship-pr                # PR 前検証だけ単独実行
```

`issue-next` の流れ:

1. Issue を取得して内容を提示 → ユーザーが着手承認
2. `planner` がプランを策定 → ユーザー承認
3. プランファイル `.claude/plan/plan-{N}.md` を作成（中断時の復帰ポイント）
4. `implementer`（または `implementer-sonnet`）が実装
5. `implementation-reviewer` がプラン・設計との整合をチェック
6. 必要なら `security-reviewer` がセキュリティ監査
7. format / lint / typecheck / test を実行 → PR 作成

## プロジェクト側の設定

### 必須: `CLAUDE.md`

プロジェクトの load-bearing rules・設計ドキュメントへのポインタ・スコープ境界を `CLAUDE.md` に書く。サブエージェントはこれを読んで意思決定する。最小例は `examples/minimal-CLAUDE.md.example`、フル例は `examples/nanoka-CLAUDE.md.example` を参照。

### 任意: 設計ドキュメント

`docs/design.md` / `docs/architecture.md` / `docs/<project>.md` 等の設計仕様。`CLAUDE.md` から参照されている場合、`planner` と `implementation-reviewer` がそれを Read する。

### 任意: 実装ステータスドキュメント

`docs/implementation-status.md` 等の「shipped / pending split」ドキュメント。Issue が既存スコープと衝突していないかの判定に使う。

## hook の挙動とカスタマイズ

`mcp__github__create_pull_request`（GitHub MCP の PR 作成ツール）が呼ばれる直前に、プラグイン同梱の `scripts/pre-pr-check.sh` が走る。`issue-next` `ship-pr` どちらの経路で PR を作っても hook が発火する。デフォルトは:

```bash
pnpm format
pnpm lint
```

プロジェクトのコマンドが違う場合は環境変数で上書き:

```bash
export ISSUE_FLOW_FORMAT_CMD="npm run format"
export ISSUE_FLOW_LINT_CMD="npm run lint"
```

hook を完全に無効化したい場合は、プロジェクトの `.claude/settings.json` で hooks を空にするか、本プラグインの hook をスキップする matcher を追加する。

## エージェントの役割分担

```
┌──────────┐    プラン     ┌─────────────┐
│ planner  │ ────────────▶│ implementer │
│  (opus)  │              │   (haiku)   │ ──┐
└──────────┘              └─────────────┘   │
                                ▲ 巻き戻し  │
                                │ 必要時    ▼
                          ┌─────────────────────┐
                          │ implementer-sonnet  │
                          │      (sonnet)       │
                          └─────────────────────┘
                                              │
                                              ▼
                          ┌─────────────────────────┐
                          │ implementation-reviewer │
                          │        (sonnet)         │
                          └─────────────────────────┘
                                              │
                                              ▼
                          ┌─────────────────────┐
                          │  security-reviewer  │
                          │       (opus)        │
                          └─────────────────────┘
                                              │
                                              ▼
                                        PR 作成
```

- `planner` (opus): 設計判断と計画。コードは書かない。
- `implementer` (haiku): プランに忠実に書くだけ。安くて速い。
- `implementer-sonnet` (sonnet): 型推論・generic・複数ファイル横断が必要なとき haiku から切り替え。
- `implementation-reviewer` (sonnet): プラン・設計ドキュメントとの整合性チェック。
- `security-reviewer` (opus): OWASP・認証認可・機密情報の監査。

## ライセンス

MIT
