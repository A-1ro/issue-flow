# issue-flow

GitHub Issue を 1 件処理する Claude Code プラグイン。`planner → implementer → implementation-reviewer → security-reviewer` の 4 段階サブエージェントを順に走らせ、検証 → PR 作成までをオーケストレートする。

## 同梱物

| 種類 | 名前 | 用途 |
|---|---|---|
| Skill | `issue-flow:issue-next` | Issue 1 件を planner → implementer → review → PR まで自動進行 |
| Skill | `issue-flow:issue-draft` | 実装前に「日本語コメントだけのドラフト PR」を挟むバリエーション |
| Skill | `issue-flow:ship-pr` | format / lint / typecheck / test を順に走らせて PR を出す検証パイプライン |
| Agent | `planner` | プラン策定（opus） |
| Agent | `implementer` | 機械的な実装（haiku） |
| Agent | `implementer-sonnet` | 型・generic が絡む複雑な実装（sonnet） |
| Agent | `implementation-reviewer` | プラン・設計ドキュメントとの整合チェック（sonnet） |
| Agent | `security-reviewer` | OWASP / 認証認可 / 機密情報の監査（opus） |
| Hook | PreToolUse on `gh pr create*` | PR 作成直前に `pnpm format && pnpm lint` を強制実行 |

## 前提

- **GitHub CLI** (`gh`) がインストール済み・認証済み
- **GitHub MCP** が利用可能（`mcp__github__list_issues` / `mcp__github__get_issue` / `mcp__github__create_issue` / `mcp__github__add_issue_comment` / `mcp__github__create_pull_request`）
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

### B. Git リポジトリから（推奨）

```bash
claude plugin install https://github.com/<owner>/issue-flow
```

または `/plugin install` UI 経由。

## 使い方

```
/issue-flow:issue-next 42         # Issue #42 を実装
/issue-flow:issue-next             # Open Issue 一覧から候補を提示
/issue-flow:issue-draft 42         # ドラフト PR 経由のフロー
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

`gh pr create` を Bash 経由で呼ぶ直前に、プラグイン同梱の `scripts/pre-pr-check.sh` が走る。デフォルトは:

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
