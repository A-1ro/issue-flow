---
name: issue-next
description: GitHub Issue を 1 件処理する実装オーケストレーション。Issue 番号を引数に受け取り、GitHub MCP (`mcp__github__get_issue`) で内容を取得してから planner → implementer → implementation-reviewer → security-reviewer の順にサブエージェントを呼ぶ。1 回の起動で 1 Issue だけ処理し、完了後に PR を作成して終了する。
---

# GitHub Issue を 1 件実装して PR を作る

このスキルは **Issue 1 件を完了させたら止まる**。次の Issue に進むかはユーザーが判断する。

## 前提

- `gh` CLI がインストールされ、対象リポジトリで認証済みであること
- GitHub MCP（`mcp__github__list_issues` / `mcp__github__get_issue` / `mcp__github__create_issue` / `mcp__github__add_issue_comment` / `mcp__github__create_pull_request`）が利用可能であること
- pnpm を使うワークスペース（`pnpm format` / `pnpm lint` / `pnpm test` などが定義されていること）。pnpm 以外の場合は各 Step の pnpm コマンドを読み替える
- プロジェクトに `CLAUDE.md` が置かれており、load-bearing rules / 設計ドキュメントへのポインタがあること（推奨）

## 手順

### Step 1: Issue の取得とブランチ準備

0. **中断セッションの復帰チェック**: 引数の Issue 番号が判明したら、まず `.claude/plan/plan-{番号}.md` が存在するか確認する。
   - 存在する場合: 前回セッションが中断されている。ファイルを Read してチェック済み・未チェックの状況をユーザーに提示し、「未完了のステップから再開しますか？」を確認する。Yes なら Step 4 から再開（Step 2・3 はスキップ）。
   - 存在しない場合: 通常通り Step 1 を続ける。
1. 引数で Issue 番号が指定されていない場合は、**Open Issue 一覧から候補を提示してユーザーに選んでもらう**:
   1. GitHub MCP の `mcp__github__list_issues` を呼ぶ（`owner` / `repo` / `state: "open"` / `sort: "created"` / `direction: "asc"` / `perPage: 30`）。owner / repo はカレントリポジトリの remote から判断する。
   2. 取得した一覧から **Pull Request を除外** する（GitHub API は PR も Issue として返すため、`pull_request` フィールドが付いているものは外す）。
   3. 残った Issue を以下のソート順で並べてユーザーに見せる:
      - 第 1 キー: ラベルに `priority:high` / `bug` などの優先度シグナルがあるものを上に
      - 第 2 キー: マイルストーン期日が近いものを上に（マイルストーンなしは下）
      - 第 3 キー: 番号昇順（古いものを上に）
   4. 表示フォーマットは以下の 1 行サマリで、最大 10 件まで。10 件超は「…他 N 件」と省略する:
      ```
      #{番号} {タイトル}  [labels: {label1,label2}]  [milestone: {名前}]  [assignees: {名前}]
      ```
   5. 候補のうち「次に着手すべき推薦は **#{番号}**（理由: …）」を 1 件提示する。理由はラベル / マイルストーン / 依存関係から 1〜2 行で。
   6. ユーザーに「どの Issue を対応しますか？（番号を指定）」と聞き、応答を待つ。応答された番号でステップ 2 以降を進める。
   7. 中断セッション復帰チェック（手順 0）は番号が確定した時点で改めて行う。`.claude/plan/plan-{確定番号}.md` が存在すれば再開可否を確認する。
2. GitHub MCP の `mcp__github__get_issue` で Issue を取得する（`owner` / `repo` / `issue_number` を渡す。owner / repo はカレントリポジトリの remote から判断）。返却の `state` / `title` / `body` / `labels` / `assignees` / `milestone` を後続ステップで使う。
3. デフォルトブランチ（`main`）を最新にする:
   ```bash
   git checkout main && git pull origin main
   ```
4. Issue 番号をもとに作業ブランチを切る:
   ```bash
   git checkout -b issue-{番号}-{kebab-case-summary}
   ```
   ブランチ名の `{kebab-case-summary}` は Issue タイトルから 3〜5 語程度の英語 kebab-case で付ける。

### Step 2: Issue の確認

**事前検証チェックリスト（必須）**: Issue の内容を確認する前に、参照する予定のファイルをすべてリストアップし、Read してから進む。この Session で Read していないファイルの内容を根拠にした技術的な主張を Issue・PR・ドキュメントに書かない。

1. Issue の内容（タイトル・本文・ラベル・マイルストーン）をユーザーに見せ、**「この Issue を実装していいか」を確認**する。
   - `state: closed` の場合は警告を出してユーザー確認。
   - ユーザーが No と言ったらその理由を聞いて終了。
2. プロジェクトに実装ステータスドキュメント（例: `docs/implementation-status.md`）があれば Read して、Issue が既存の実装済み範囲・対象外範囲と衝突していないか確認する。衝突がある場合はユーザーに提示して判断を仰ぐ。

### Step 3: プラン策定（planner エージェント）

1. `Agent` ツールで `subagent_type: "planner"` を呼び出す。プロンプトには以下を含める:
   - Issue 番号・タイトル・本文の全文
   - 「Issue のスコープだけで計画を作ること。関連しない改善や追加機能は含めないこと」を明示
   - プロジェクトの `CLAUDE.md` と設計ドキュメントの load-bearing rules を守ること
   - 「関連ファイルを先に Read してから計画を立てること」を明示
   - プロジェクト全体への影響（API・挙動変更が公開ドキュメントや他パッケージに波及する場合）を計画に含めること
2. planner の返答を**そのままユーザーに見せる**（要約しない。プランは実装の契約なので原文が重要）。
3. **ユーザーの承認を取る**。修正要求があれば planner を再度呼び、確定するまでループ。

### Step 3.5: スコープ評価とサブ Issue 分割

planner のプランが返ってきたら、**実装に着手する前に**スコープの大きさを評価する。

以下の基準のいずれかに該当する場合は「スコープが大きい」と判断する:

- 独立して動作する機能・変更が 2 つ以上含まれている
- 変更ファイルが 6 件以上
- planner が「フェーズ分け」「段階的に」「別途」などの言葉を使っている
- 1 つの PR にまとめるとレビューが困難な複雑さ

**スコープが大きい場合の手順:**

1. プランを分割単位（サブ Issue）に分ける。それぞれが独立してマージ可能な単位にする。
2. ユーザーに分割案を提示し、承認を取る。
3. 承認後、元の Issue にコメントを追加してトラッキングリストを記載する。GitHub MCP の `mcp__github__add_issue_comment` を使用（`owner` / `repo` / `issue_number: {元番号}` / `body` を渡す）。`body` の内容例:
   ```
   スコープが大きいため以下のサブ Issue に分割します:
   - [ ] #{サブ1番号} {タイトル1}
   - [ ] #{サブ2番号} {タイトル2}
   ...
   ```
4. 各サブ Issue を `mcp__github__create_issue` で作成（`owner` / `repo` / `title` / `body` を渡す）。`body` には `Parent: #{元番号}` を含める。先に作成したサブ Issue から番号が払い出されるので、Step 3 のコメントは番号確定後に投稿する。
5. **最初のサブ Issue（#サブ1番号）だけを対象として以降のステップを続ける。**
   - 以降の Step では「元 Issue」ではなく「サブ Issue #サブ1番号」を処理対象とする。
   - 作業ブランチを切り直す（必要であれば）:
     ```bash
     git checkout -b issue-{サブ1番号}-{kebab-case-summary}
     ```
6. ユーザーに「サブ Issue #{サブ1番号} の実装に進みます」と伝えてから Step 4 へ。

**スコープが適切な場合:** 評価結果をユーザーに一言伝えてそのまま Step 3.6 へ。

### Step 3.6: プランファイルの作成

ユーザー承認済みのプランを `.claude/plan/plan-{番号}.md` としてチェックボックス形式で書き出す。

ファイルフォーマット:

```markdown
# Plan #42: {Issue タイトル}

Branch: {ブランチ名}

## 実装ステップ

- [ ] {ステップ1の説明}
- [ ] {ステップ2の説明}
- [ ] {ステップ3の説明}
...
```

- ステップは planner が返したプランの実装ステップを**1ステップ1行**で列挙する。粒度は「1ファイルへの変更」「1テストの追加」程度が目安。
- このファイルは実装中の進捗状態の唯一の永続記録となる。コンテキスト爆発・compaction が起きても、このファイルを読めば現在地がわかる。
- ファイルの書き出し後、パスをユーザーに一言伝えてから Step 4 へ。

### Step 4: 実装（implementer エージェント）

#### 4-0: 実装者の選択（haiku か sonnet か）

着手前に、プランの性質を見て**どちらの実装者を呼ぶか決める**:

- **`implementer`（haiku, デフォルト）** — 機械的な編集、明確に一直線で書ける実装、コメント修正、ファイル名変更、簡単なテスト追加など。安くて速い。
- **`implementer-sonnet`（sonnet）** — 以下のいずれかを含む場合:
  - 型システムの設計（generic / 条件型 / `infer` / mapped types を組み立てる）
  - 複数ライブラリの型統合
  - 4 ファイル以上を横断する変更
  - 「型を `as any` で逃げず精緻型で実装する」が成否のクリティカルパスになるタスク

判断に迷ったら sonnet を選ぶ（コスト差より失敗→再実行のロスの方が大きい）。プラン承認時にユーザーに「この実装は sonnet で進めます」と一言伝えること。

#### 4-1: 実装の実行

1. `Agent` ツールで `subagent_type: "implementer"` または `subagent_type: "implementer-sonnet"` を呼ぶ。プロンプトには以下を含める:
   - 確定したプランの全文
   - 「プランに書かれた変更だけを行うこと」を明示
   - Issue 番号（後の PR 作成で使う）
   - プランファイルのパス: `.claude/plan/plan-{番号}.md`
   - **以下の指示を必ず含める**:
     > 実装を開始する前に `.claude/plan/plan-{番号}.md` を Read して未チェックのステップを確認すること。
     > 各ステップの実装が完了したら、そのステップの `- [ ]` を `- [x]` に書き換えてから次のステップに進むこと。
     > 途中で中断・再起動した場合もこのファイルを Read すれば現在地がわかる。巻き戻しは絶対に行わないこと。
2. implementer から完了報告が返ってきたら、変更ファイル一覧とテスト結果をユーザーに見せる。
3. implementer がプランから逸脱せざるを得なかった旨を報告した場合は、**そこで一度止めてユーザーに確認**。勝手に次に進まない。
4. **haiku 版が以下の失敗パターンを示したら sonnet 版に切り替える**:
   - プランで指定された型を `any` にスタブして「完了」と報告した
   - 既に行った修正を `git checkout` などで巻き戻した
   - ツールエラーを「権限がロック」のような曖昧な言葉で諦めた
   - 同じプランで 2 回続けてプラン未達を報告した

### Step 5: 実装レビュー（implementation-reviewer エージェント）

1. `Agent` ツールで `subagent_type: "implementation-reviewer"` を呼ぶ。プロンプトには:
   - Issue 番号・タイトル
   - 確定したプラン
   - implementer の完了報告（変更ファイル一覧）
   - 参照すべきドキュメント: プロジェクトの設計ドキュメント / 実装ステータスドキュメント / `CLAUDE.md`
2. レビュー結果をユーザーに見せる。
3. **Critical / Major 指摘がある場合**: 修正のために implementer を再度呼ぶ。修正後、再レビュー。Critical / Major がゼロになるまで繰り返す。
4. Minor 指摘のみなら、ユーザーに「Minor 指摘を反映するか / 後回しにするか」を確認。

### Step 6: セキュリティレビュー（security-reviewer エージェント）

以下のいずれかに触れる変更がある場合のみ実行:
- HTTP body / params / query / headers の処理
- バリデータ（Zod / Yup / class-validator 等）
- DB クエリ構築・ORM エスケープハッチ・トランザクション動作
- API スキーマ生成（OpenAPI / GraphQL schema 等）でバリデーション/強制のソースとして扱われる可能性がある場合
- 認証・認可・セッション・トークン・API キー・シークレット
- CORS・リダイレクト・外部 fetch・ロギング・エラーメッセージ
- 新しい外部依存関係

判断に迷ったら実行する。

1. `Agent` ツールで `subagent_type: "security-reviewer"` を呼ぶ。プロンプトには変更ファイル一覧と Issue 概要を伝える。
2. Critical / Major 指摘があれば implementer を呼んで修正、再レビュー。
3. 結果をユーザーに見せる。

### Step 7: 完了処理

1. `.claude/plan/plan-{番号}.md` を Read して全ステップが `[x]` になっていることを確認する。未チェックが残っている場合は implementer を呼んで対応させる。全チェック確認後、ファイルを削除する:
   ```bash
   rm .claude/plan/plan-{番号}.md
   ```
2. プロジェクトに実装ステータスドキュメント（例: `docs/implementation-status.md`）がある場合、変更が反映すべき内容があれば更新する（shipped API 変更・新機能追加時など）。
3. プロジェクトに公開ドキュメント（README / docs サイト / `llms.txt` 等）がある場合、API の追加・変更・削除・挙動変更が反映されているかチェックする。未反映があれば更新してからコミットに含める。
4. 完了確認コマンドがある場合（テスト・typecheck など）、ユーザーに「実行して回帰確認していいか」を聞く。実行する場合は Bash で実行。
5. **PR 前の検証（必須）** — PR を出す前に以下をすべて実行する:
   ```bash
   pnpm format
   pnpm lint
   # プロジェクトに typecheck スクリプトがあれば
   pnpm typecheck   # または pnpm -C <package> typecheck
   ```
   - `package.json` を変更した場合は `pnpm install` を実行してロックファイルを更新し、コミットに含める。
   - lint / typecheck が通らない場合はエラーを修正してから次へ進む。
   - **本プラグインの hook（PreToolUse: `mcp__github__create_pull_request` → format & lint）が PR 作成直前にも走るため、本ステップの実行は二重チェック。早期エラー検知のための意図的な冗長性。**
6. **ユーザーに以下のサマリを 1 メッセージで提示し、PR を出していいか確認する**:
   ```
   ✅ #{Issue番号} {タイトル} 完了
   - 変更ファイル: ...
   - テスト: ...
   - docs 更新: ...
   PR を作成してよいですか？
   ```
7. ユーザーが Yes なら:
   - 変更をコミット（未コミットの場合）:
     ```bash
     git add <変更ファイル>
     git commit -m "feat/fix/...: {タイトル} (#{番号})"
     ```
   - ブランチを push:
     ```bash
     git push -u origin {ブランチ名}
     ```
   - PR を作成する。GitHub MCP の `mcp__github__create_pull_request` を使う（`owner` / `repo` / `title` / `body` / `head: {ブランチ名}` / `base: main` を渡す）。`body` には `Closes #{番号}` を含める。
   - 返却された PR URL をユーザーに見せる。
8. **ここで停止**。Issue のクローズは PR マージ時に自動で行われる（`Closes #番号` による）。次の Issue に進むかはユーザーが判断する。

## ガードレール

- **1 回の起動で 1 Issue だけ**。複数 Issue を跨いではいけない。
- **ユーザー確認ゲートを飛ばさない**:
  - Step 1 の着手確認
  - Step 2 のプラン承認
  - Step 4 / 5 のレビュー結果確認
  - Step 6 の PR 作成確認
- **planner / implementer / reviewer の役割を混同しない**。このスキルを実行する Claude はオーケストレータ。コードを直接書かず、レビューも直接行わない。サブエージェントの結果を仲介する。
- **エージェントの返答を要約しすぎない**。特に planner のプランは実装の契約なので、ユーザーが原文を見られるようにする。
- Issue のスコープを超えた改善・リファクタリングは提案に留め、実装しない。
- スコープが大きいと判断した場合、**勝手に全サブ Issue を実装しない**。最初の 1 件だけ進めてユーザーに次を委ねる。
- サブ Issue 分割後、元 Issue はクローズしない。全サブ Issue がマージされた時点でユーザーが判断する。
- 途中でエラー・矛盾・スコープ膨張を検知したら、自動で続行せず**ユーザーに判断を仰ぐ**。
- プロジェクトの load-bearing rules（`CLAUDE.md` / 設計ドキュメント記載）に反する変更を検知したらブロックしてユーザーに確認。

## 引数

`/issue-flow:issue-next {番号}` の形式で Issue 番号を直接渡せる。番号を省略した場合、Step 1 で Open Issue 一覧を取得し、優先度順に並べてユーザーに候補を提示する。

例:
- `/issue-flow:issue-next 42` — Issue #42 を処理
- `/issue-flow:issue-next` — Open Issue 一覧から候補を提示し、ユーザーに選んでもらう
