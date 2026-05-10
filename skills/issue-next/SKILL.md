---
name: issue-next
description: GitHub Issue を 1 件処理する実装オーケストレーション。Issue 番号を引数に受け取り、GitHub MCP (`mcp__github__get_issue`) で内容を取得してから planner → implementer → implementation-reviewer → security-reviewer の順にサブエージェントを呼ぶ。1 回の起動で 1 Issue だけ処理し、完了後に PR を作成して終了する。プラン / レビュー / PR サマリ / Issue 候補をすべて単一 HTML として `.claude/plan/` に書き出し、ブラウザで自動オープンしてユーザー確認に使う。
---

# GitHub Issue を 1 件実装して PR を作る

このスキルは **Issue 1 件を完了させたら止まる**。次の Issue に進むかはユーザーが判断する。

ユーザーが画面で確認するもの（Open Issue 候補 / プラン / 実装レビュー / セキュリティレビュー / PR 前サマリ）は **テキストでだらだら出さず、すべて単一 HTML ファイルとして `.claude/plan/` 配下に書き出し、`open` コマンドでブラウザ表示する**。これがこのスキルの一貫した方針。

## 前提

- `gh` CLI がインストールされ、対象リポジトリで認証済みであること
- GitHub MCP（`mcp__github__list_issues` / `mcp__github__get_issue` / `mcp__github__create_issue` / `mcp__github__add_issue_comment` / `mcp__github__create_pull_request`）が利用可能であること
- pnpm を使うワークスペース（`pnpm format` / `pnpm lint` / `pnpm test` などが定義されていること）。pnpm 以外の場合は各 Step の pnpm コマンドを読み替える
- プロジェクトに `CLAUDE.md` が置かれており、load-bearing rules / 設計ドキュメントへのポインタがあること（推奨）
- macOS など `open` コマンドが使える環境（Linux なら `xdg-open`、WSL なら `explorer.exe` を読み替える）

## 手順

### Step 1: Issue の取得とブランチ準備

0. **中断セッションの復帰チェック**: 引数の Issue 番号が判明したら、まず `.claude/plan/plan-{番号}.html` が存在するか確認する。
   - 存在する場合: 前回セッションが中断されている。ファイルを Read し、`<!--PROGRESS_STATE ... PROGRESS_STATE-->` ブロック内の JSON から各ステップの `status`（`pending` / `in_progress` / `done`）を読み取って状況をユーザーに提示し、「未完了のステップから再開しますか？」を確認する。Yes なら Step 4 から再開（Step 2・3 はスキップ）。あわせて `open .claude/plan/plan-{番号}.html` でブラウザを開き直す（自動リロードで最新進捗が見える）。
   - 存在しない場合: 通常通り Step 1 を続ける。
1. 引数で Issue 番号が指定されていない場合は、**Open Issue 一覧から候補を HTML カードで提示してユーザーに選んでもらう**:
   1. GitHub MCP の `mcp__github__list_issues` を呼ぶ（`owner` / `repo` / `state: "open"` / `sort: "created"` / `direction: "asc"` / `perPage: 30`）。owner / repo はカレントリポジトリの remote から判断する。
   2. 取得した一覧から **Pull Request を除外** する（GitHub API は PR も Issue として返すため、`pull_request` フィールドが付いているものは外す）。
   3. 残った Issue を以下のソート順で並べる:
      - 第 1 キー: ラベルに `priority:high` / `bug` などの優先度シグナルがあるものを上に
      - 第 2 キー: マイルストーン期日が近いものを上に（マイルストーンなしは下）
      - 第 3 キー: 番号昇順（古いものを上に）
   4. **候補リストを HTML カード集として書き出す（必須）**。テキスト一行サマリでだらだら出さない。
      - 出力先: `.claude/plan/issue-list.html`
      - オーケストレータが直接 Write。プラン HTML と同じスタック（Tailwind CDN / system font / `prefers-color-scheme` 自動切替）。
      - 必須セクション:
        - **ヘッダーカード**: 「Open Issue 候補（N 件、PR 除外済み）」/ 取得時刻 / ソート順の説明
        - **推薦カード**（最上部、強調）: 推薦 Issue を金枠 + 「推薦」バナーで強調。番号 / タイトル / ラベルバッジ（色分け）/ milestone / assignees / 推薦理由（1〜2 行）
        - **候補カード一覧**（最大 10 件、推薦含む）: 各カードに 番号 / タイトル（クリックで GitHub Issue へ）/ labels（色分けバッジ）/ milestone（期日バッジ）/ assignees / created_at（相対時刻表示）
        - 10 件超の場合は `<details>` で「他 N 件を見る」を折りたたんで全件埋め込み
        - 各カードに、ターミナルで番号を指定するための「指定: `{番号}`」ヒント
   5. Bash で `open .claude/plan/issue-list.html` を実行。
   6. ユーザーには「Open Issue 候補を `.claude/plan/issue-list.html` で開きました。**推薦は #{番号}**（理由: …）。番号を指定してください」とターミナルで一言伝え、応答を待つ。応答された番号でステップ 2 以降を進める。
   7. 中断セッション復帰チェック（手順 0）は番号が確定した時点で改めて行う。`.claude/plan/plan-{確定番号}.html` が存在すれば再開可否を確認する。
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
3. ここでは承認ゲートを置かない。Step 3.5（スコープ評価）→ Step 3.6（HTML プレビュー生成）を経て、**Step 3.6 で最終承認を取る**。

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
6. ユーザーに「サブ Issue #{サブ1番号} の実装に進みます」と伝えてから Step 3.6 へ。

**スコープが適切な場合:** 評価結果をユーザーに一言伝えてそのまま Step 3.6 へ。

### Step 3.6: HTML プレビュー生成と最終承認

確定プラン（スコープ評価後の対象 Issue 用プラン）を、視覚的に確認できる単一 HTML として書き出し、ブラウザで自動オープンしたうえでユーザーから最終承認を取る。**この HTML は実装中の進捗状態の唯一の永続記録も兼ねる**（Markdown チェックリストは作らない）。

#### 3.6-1: HTML 生成

1. 出力先: `.claude/plan/plan-{番号}.html`（番号は対象 Issue の番号。サブ Issue 分割後は最初のサブ Issue の番号）。
2. **このスキルを実行している Claude（オーケストレータ）が直接 Write する**。planner には HTML 化を委譲しない。
3. 単一 HTML ファイル。外部 CSS/JS は CDN 経由のみで完結させる:
   - Tailwind CSS — `<script src="https://cdn.tailwindcss.com"></script>`
   - mermaid.js — `<script type="module">import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs'; mermaid.initialize({ startOnLoad: true, theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default' });</script>`
4. **「結局 Markdown と変わらない」を絶対に避けるため、視覚化できる情報は徹底的に図にする**。文字の羅列で済ませない。最低限以下のセクションと図を必ず含めること:
   - **ヘッダーカード**: Issue 番号 / タイトル / ブランチ名 / Issue 本文の要約 / 対象スコープ・非対象スコープのサマリ。
   - **進捗サマリーバー**（最上部に固定）: 全ステップ中の `done` / `in_progress` / `pending` の件数と割合をプログレスバーで表示。`PROGRESS_STATE` から動的に算出（後述）。
   - **メトリクスダッシュボード**（カード横並び）: ステップ数、変更ファイル数（新規 / 編集 / 削除を色分けバッジで内訳表示）、追加テスト数、推定難易度（low / med / high バッジ）。
   - **ステップ依存グラフ**（mermaid `flowchart LR` または `graph TD`）: ステップ間の依存関係。並列実行可能なステップは並列に並べる。クリティカルパス上のノードは色を変えて強調する。
   - **実行順序タイムライン**（mermaid `gantt` または HTML/CSS の番号付きタイムライン UI）: ステップ実行順を時系列で。
   - **変更ファイルマップ**（mermaid `graph` のディレクトリツリー、または HTML/CSS の折りたたみツリー）: 触るファイルをディレクトリ階層で視覚化。新規 / 編集 / 削除をバッジで色分け。
   - **ステップ詳細カード**（折りたたみ可、`<details>` 要素。各カードのルート要素に `data-step-id="{N}"` を付ける）: 各ステップの説明 / 対象ファイル / 受け入れ基準 / 関連 doc・Issue リンク。`PROGRESS_STATE` の status に応じてバッジ（灰=pending / 青パルス=in_progress / 緑✓=done）と縦線カラーを切り替える。
   - **テスト計画表**: 追加するテストケースを表形式（テスト名 / 対象 / 期待値）で。
   - **load-bearing rules チェック**: プロジェクトの `CLAUDE.md` / 設計ドキュメントに記載された load-bearing rules のうち本プランに関連するものをチェックボックス UI で並べ、「該当（守るべき）」「非該当」を視覚化。違反候補があれば赤バッジで警告。
   - **スコープ外**: 今回やらないこと（明示しないと後で混乱するため必ず入れる）。
5. **進捗状態の永続化（PROGRESS_STATE）— 必須**:
   - HTML の `<body>` 末尾に以下のフォーマットで JSON コメントブロックを 1 個だけ埋め込む。これが**進捗状態の単一の真実ソース**。
   - 開始タグは `<!--PROGRESS_STATE`、終了タグは `PROGRESS_STATE-->`。両タグともそれぞれ単独行に置く（implementer の Edit ターゲットを安定させるため）。
   - JSON 内の `steps[].id` は 1 始まりの連番、`status` は `"pending"` / `"in_progress"` / `"done"` のいずれか。初回生成時は全ステップ `"pending"`。
   ```html
   <!--PROGRESS_STATE
   {
     "issue": 42,
     "title": "...",
     "branch": "issue-42-...",
     "steps": [
       { "id": 1, "title": "X を Y に変更", "files": ["src/a.ts"], "status": "pending" },
       { "id": 2, "title": "Z のテストを追加", "files": ["src/a.test.ts"], "status": "pending" }
     ]
   }
   PROGRESS_STATE-->
   ```
6. **進捗描画スクリプト — 必須**:
   - HTML の `<body>` の最後（`PROGRESS_STATE` ブロックより前）に以下と同等の `<script>` を埋め込む。
   - ロード時に `PROGRESS_STATE` を抽出 → 各ステップカードと進捗サマリーバーに status を反映 → 全 done でない限り 3 秒後に `location.reload()` で自動リロード。
   ```html
   <script>
     (() => {
       const html = document.documentElement.outerHTML;
       const m = html.match(/<!--PROGRESS_STATE\n([\s\S]*?)\nPROGRESS_STATE-->/);
       if (!m) return;
       let state;
       try { state = JSON.parse(m[1]); } catch { return; }
       const counts = { pending: 0, in_progress: 0, done: 0 };
       for (const step of state.steps) {
         counts[step.status] = (counts[step.status] || 0) + 1;
         const el = document.querySelector(`[data-step-id="${step.id}"]`);
         if (el) el.dataset.status = step.status;
       }
       const bar = document.getElementById("progress-summary");
       if (bar) bar.dataset.counts = JSON.stringify(counts);
       const allDone = state.steps.length > 0 && counts.done === state.steps.length;
       if (!allDone) setTimeout(() => location.reload(), 3000);
     })();
   </script>
   ```
   - CSS 側で `[data-step-id][data-status="pending"]` / `[data-status="in_progress"]` / `[data-status="done"]` に対応する見た目（色・バッジ・パルスアニメ）を Tailwind ユーティリティ + 軽い `<style>` で定義する。
   - 進捗サマリーバー (`#progress-summary`) は `dataset.counts` を読んで描画する小さなインライン JS をもう一段書いて構わない（同じ `<script>` 内でまとめても良い）。
7. デザイン要件:
   - `prefers-color-scheme` でライト / ダーク自動切替。Tailwind の `dark:` バリアントと mermaid テーマ（`default` / `dark`）を連動させる。
   - フォントは system font stack（Web フォント追加禁止）。
   - 横スクロールが必要な mermaid 図は `<div class="overflow-x-auto">` でラップ。
8. **planner プランの原文情報をそのまま反映する**（要約しない）。視覚化は「同じ情報を別ビューで見せる」ものであり、情報の取捨選択を加えない。

#### 3.6-2: 自動オープン

1. HTML を Write した直後に Bash で `open .claude/plan/plan-{番号}.html` を実行し、デフォルトブラウザで開く。
2. ユーザーには「`.claude/plan/plan-{番号}.html` をブラウザで開きました。プレビューを確認してください」と一言伝える。

#### 3.6-3: 最終承認

1. 「このプランで実装に進んでよいですか？」を聞く。
2. 修正要求があれば planner を再度呼び、Step 3 から再生成。HTML も再生成し、再度 `open` で開き直す。確定するまでループ。
3. 承認後、Step 4 へ（HTML 内の `PROGRESS_STATE` がそのまま実装フェーズの進捗管理ソースになる）。

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
   - プランファイルのパス: `.claude/plan/plan-{番号}.html`
   - **以下の指示を必ず含める**（進捗管理プロトコル）:
     > 実装を開始する前に `.claude/plan/plan-{番号}.html` を Read し、`<!--PROGRESS_STATE` から `PROGRESS_STATE-->` までの JSON ブロックを抽出して未完了（`status` が `"pending"` または `"in_progress"`）のステップを確認すること。
     >
     > **進捗の更新はステップごとにリアルタイムで行うこと（必須）**:
     >
     > - 各ステップに着手する直前に、そのステップの `"status": "pending"` → `"status": "in_progress"` に Edit する（コード変更を 1 行も書き始める前）。
     > - そのステップのコード変更が完了したら、即座に `"status": "in_progress"` → `"status": "done"` に Edit する（次のステップに移る前）。
     > - つまり「N 個のステップで合計 2N 回の Edit を PROGRESS_STATE に対して行う」のが正しい動作。
     >
     > **禁止事項**:
     >
     > - 全ステップ完了後にまとめて status を更新するバッチ更新は禁止。ユーザーは HTML をブラウザで開いており、3 秒ごとの自動リロードでリアルタイム進捗を確認している。バッチ更新ではフィードバックループが壊れる。
     > - status の巻き戻し（一度 `done` にしたものを `pending` / `in_progress` に戻す）は禁止。
     > - status 値の独自拡張（`"skipped"` / `"failed"` 等）は禁止。`"pending"` / `"in_progress"` / `"done"` のみ。
     >
     > **Edit の書き方**: old_string は **ステップ ID を含む 1 行の塊** を狙うこと。例えば id=3 を done にする場合:
     > ```
     > old_string: { "id": 3, "title": "Z のテストを追加", "files": ["src/a.test.ts"], "status": "in_progress" }
     > new_string: { "id": 3, "title": "Z のテストを追加", "files": ["src/a.test.ts"], "status": "done" }
     > ```
     > status だけを置換して title / files は変更しないこと。JSON の他のフィールド・他のステップを壊さないよう細心の注意を払う。
     >
     > 途中で中断・再起動した場合も `.claude/plan/plan-{番号}.html` を Read すれば現在地がわかる。
     >
     > **完了報告フォーマット（必須）**: 全ステップ完了後、最終報告に「PROGRESS_STATE 反映済み: id=1 done, id=2 done, ...」の 1 行サマリを必ず含める。これによりオーケストレータが整合チェックできる。
2. implementer から完了報告が返ってきたら、変更ファイル一覧とテスト結果をユーザーに見せる。
3. implementer がプランから逸脱せざるを得なかった旨を報告した場合は、**そこで一度止めてユーザーに確認**。勝手に次に進まない。
4. **haiku 版が以下の失敗パターンを示したら sonnet 版に切り替える**:
   - プランで指定された型を `any` にスタブして「完了」と報告した
   - 既に行った修正を `git checkout` などで巻き戻した
   - ツールエラーを「権限がロック」のような曖昧な言葉で諦めた
   - 同じプランで 2 回続けてプラン未達を報告した
   - PROGRESS_STATE をバッチで一括更新した（リアルタイム反映の指示違反）

#### 4-2: 進捗状態の検証と同期（オーケストレータ責務）

implementer の完了報告を受け取ったら、**オーケストレータ自身が PROGRESS_STATE の整合性を確認する**。implementer の更新を信用しきらず、最終状態をオーケストレータが保証する。

1. `.claude/plan/plan-{番号}.html` を Read して PROGRESS_STATE JSON を抽出。
2. 以下を突き合わせる:
   - implementer の完了報告に挙げられた変更ファイルが `git diff --stat` の出力と一致するか
   - 完了報告で「実装した」とされた各ステップが PROGRESS_STATE 上 `"done"` になっているか
   - 未着手や `"in_progress"` のまま残っているステップがないか
3. **不整合を発見した場合**:
   - 実装は完了しているが status が古いだけ → オーケストレータが直接 Edit して `"done"` に同期。
   - 実装が未完了 → implementer に追加の指示を出すか、ユーザーに判断を仰ぐ。
   - 完了報告と diff が食い違う（虚偽申告）→ ユーザーに報告して停止。
4. 整合性確認後、ユーザーに「進捗 HTML はブラウザで自動リロードされます」と一言伝える。同期 Edit を行った場合は「PROGRESS_STATE を同期しました」と明示。

### Step 5: 実装レビュー（implementation-reviewer エージェント）

#### 5-1: レビューの実行

1. `Agent` ツールで `subagent_type: "implementation-reviewer"` を呼ぶ。プロンプトには:
   - Issue 番号・タイトル
   - 確定したプラン
   - implementer の完了報告（変更ファイル一覧）
   - 参照すべきドキュメント: プロジェクトの設計ドキュメント / 実装ステータスドキュメント / `CLAUDE.md`
2. agent の返答（レビュー原文）を変数として保持する。要約しない。

#### 5-2: レビュー HTML 生成

レビュー結果を視覚化した単一 HTML として書き出す。プラン HTML と同じく、ユーザーが画面で確認できる形にする。**「ユーザーが確認する画面はとことん HTML」がこのスキルの一貫した方針**。

1. 出力先: `.claude/plan/review-impl-{番号}.html`
2. **このスキルを実行している Claude（オーケストレータ）が直接 Write する**。reviewer に HTML 化を委譲しない。
3. 単一 HTML ファイル。プラン HTML と同じスタックを使う:
   - Tailwind CSS — `<script src="https://cdn.tailwindcss.com"></script>`
   - mermaid.js（必要なら）— プラン HTML と同じ初期化スクリプト
   - フォントは system font stack。`prefers-color-scheme` でライト/ダーク自動切替。
4. **必須セクション**（情報を取捨選択しない。reviewer の指摘原文を全て含める）:
   - **ヘッダーカード**: レビュー種別バッジ（implementation review）/ Issue 番号 + タイトル / ブランチ / 全体 verdict（approve / changes-requested / blocked）を視覚的に強調
   - **Severity サマリー**（カード横並び）: Critical / Major / Minor の件数を大きな数字で表示。Critical は赤、Major は橙、Minor は灰のアクセント色
   - **プラン整合チェック**: プラン通りか / 不足（unimplemented）/ 余剰（unplanned）/ 細部差異 をセクション分けして表示
   - **指摘リスト**: severity 別にカードで一覧。各カードに「該当ファイル:行番号 / 問題 / 修正案 / reviewer のコメント原文」を構造化して表示。severity でアクセントカラーを変える
   - **load-bearing rules チェック結果**: プラン HTML と同じ形式（チェックボックス UI、該当 / 非該当）
   - **観察事項 / out-of-scope**: reviewer が「スコープ外」「将来課題」と分類したものを別カードで
5. **reviewer の返答原文を要約しない**。HTML はあくまで視覚化レイヤー。severity 分類・ファイルパス・修正案など raw な情報は取捨選択せずそのまま埋め込む。
6. **自動リロードは不要**（レビュー結果は静的）。`PROGRESS_STATE` のような可変ブロックは入れない。

#### 5-3: HTML を開いて確認

1. Bash で `open .claude/plan/review-impl-{番号}.html` を実行。
2. ユーザーには「実装レビュー結果を `.claude/plan/review-impl-{番号}.html` で開きました」と一言伝える。

#### 5-4: 修正ループ

- **Critical / Major 指摘がある場合**: 修正のために implementer を再度呼ぶ。修正後、Step 5-1 から再レビュー。HTML も再生成（`.claude/plan/review-impl-{番号}.html` を上書き Write → `open` で再表示）。Critical / Major がゼロになるまで繰り返す。
- **Minor 指摘のみなら**: ユーザーに「Minor 指摘を反映するか / 後回しにするか」を確認。

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

#### 6-1: レビューの実行

`Agent` ツールで `subagent_type: "security-reviewer"` を呼ぶ。プロンプトには変更ファイル一覧と Issue 概要を伝える。agent の返答原文を保持する。

#### 6-2: レビュー HTML 生成

1. 出力先: `.claude/plan/review-security-{番号}.html`
2. Step 5-2 と同じ HTML スタック・基本構造を踏襲。**ただし実装レビューと種別を視覚的に区別する**（ヘッダーバッジを `security review` にして紫系のアクセント、Critical の表示をより目立たせる等）。
3. 必須セクションは Step 5-2 に加え、以下を含める:
   - **検証済み攻撃ベクトル一覧**: reviewer が確認した bypass 試行（例: case mismatch / array / null / prototype pollution など）を表で列挙し、それぞれ「ブロック確認」を視覚化
   - **影響範囲のビジュアル**: 「affected: standalone X」「unaffected: Y」を視覚化（mermaid `graph` または色分けバッジ）
   - **OWASP Top 10 マッピング**: 該当があればカテゴリと指摘の対応を表で。該当無しなら「none」と明示
   - **タイミング攻撃 / 情報漏洩の検証結果**: reviewer が timing oracle / error message leak を分析していれば結論を視覚化
4. reviewer の返答原文を要約しない。

#### 6-3: HTML を開いて確認

`open .claude/plan/review-security-{番号}.html` を実行し、ユーザーに「セキュリティレビュー結果を `.claude/plan/review-security-{番号}.html` で開きました」と伝える。

#### 6-4: 修正ループ

- Critical / Major 指摘があれば implementer を呼んで修正、Step 6-1 から再レビュー。HTML も再生成。
- Minor のみならユーザー判断。

### Step 7: 完了処理

1. `.claude/plan/plan-{番号}.html` を Read し、`PROGRESS_STATE` JSON ブロック内の全ステップが `"status": "done"` になっていることを確認する。未完了（`pending` / `in_progress`）が残っている場合は implementer を呼んで対応させる。全 done 確認後、プラン / レビュー / Issue 候補 / PR サマリの HTML をすべてまとめて削除する（PR 作成完了後に実行する場合は順序を Step 7-7 に回す。テキスト確認だけ取って削除を最後にしても良い）:
   ```bash
   rm -f .claude/plan/plan-{番号}.html \
         .claude/plan/review-impl-{番号}.html \
         .claude/plan/review-security-{番号}.html \
         .claude/plan/pr-summary-{番号}.html \
         .claude/plan/issue-list.html
   ```
2. プロジェクトに実装ステータスドキュメント（例: `docs/implementation-status.md`）がある場合、変更が反映すべき内容があれば更新する（shipped API 変更・新機能追加時など）。
3. プロジェクトに公開ドキュメント（README / docs サイト / `llms.txt` / `CHANGELOG.md` 等）がある場合、API の追加・変更・削除・挙動変更が反映されているかチェックする。未反映があれば更新してからコミットに含める。
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
6. **PR 前サマリ HTML 生成と表示（必須）**。テキストブロックで終わらせない:
   - 出力先: `.claude/plan/pr-summary-{番号}.html`
   - オーケストレータが直接 Write。プラン HTML と同じスタック。
   - 必須セクション:
     - **ヘッダーカード**: Issue 番号・タイトル・ブランチ・version bump（あれば before→after）/ commit hash（一覧）
     - **完了 verdict**: 大きなチェックマーク + バッジ（`ready-to-merge` 緑 / `needs-attention` 黄 / `blocked` 赤）
     - **検証ステータスバー**: format / lint / typecheck / test を緑・赤バッジで列挙。失敗があれば該当ログ抜粋
     - **変更ファイル一覧**: `git diff --stat` を視覚化（`+追加 -削除` の横棒バー、ファイル種別バッジ）
     - **テスト結果**: 合格件数 / 新規追加件数 / カバレッジ変化（取得できれば）
     - **docs 更新**: 実装ステータスドキュメント / docs サイト / `CHANGELOG.md` / `README.md` などの各更新有無を緑チェック / 灰未更新で視覚化
     - **レビュー結果サマリ**: implementation review / security review の verdict + Critical / Major / Minor 件数を再掲（Step 5 / 6 の HTML へのリンク付き）
     - **PR メタデータプレビュー**: PR title / body の冒頭をそのまま埋め込み（実際に作成されるものをユーザーが事前確認できる）
   - Bash で `open .claude/plan/pr-summary-{番号}.html` を実行。
   - ユーザーには「PR 前サマリを `.claude/plan/pr-summary-{番号}.html` で開きました。PR を作成してよいですか？」とターミナルで確認。
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
  - Step 3.6 のプラン最終承認（HTML プレビューを `open` で表示してから確認）
  - Step 5 / 6 のレビュー結果確認
  - Step 7 の PR 作成確認
- **HTML プレビューは単一ファイル / CDN のみ**。プランの原文情報を要約せず反映する。視覚化セクションを省略しない（`graph` / `gantt` / 変更ファイルマップなどはマストで含める）。
- **ユーザーが確認する画面はとことん HTML 化する**。Issue 候補 / プランプレビュー / 実装レビュー / セキュリティレビュー / PR 前サマリはいずれも `.claude/plan/` 配下の単一 HTML ファイルとして書き出し、`open` でブラウザ表示する。テキストでだらだら出力して終わらせない。すべての HTML は Step 7 でまとめて削除する（`plan-{N}.html` / `review-impl-{N}.html` / `review-security-{N}.html` / `pr-summary-{N}.html` / `issue-list.html`）。
- **レビュー HTML は reviewer の返答原文を要約しない**。HTML は視覚化レイヤーであり、severity 分類・ファイルパス・修正案など raw な情報の取捨選択は行わない。
- **HTML 内の `PROGRESS_STATE` JSON コメントが進捗状態の単一の真実ソース**。Markdown チェックリストは作らない。implementer は status を `pending` → `in_progress` → `done` の順でのみ進め、巻き戻さない。`PROGRESS_STATE` の JSON フォーマットを壊さない（タグの単独行配置、status 値の列挙、ステップ ID の連番を維持）。
- **進捗更新はステップごとリアルタイム**。implementer は各ステップ着手前 / 完了直後に必ず PROGRESS_STATE を Edit する（バッチ更新禁止）。オーケストレータは implementer 完了後に整合性を Read で確認し、ズレがあれば直接 Edit して同期する。
- **planner / implementer / reviewer の役割を混同しない**。このスキルを実行する Claude はオーケストレータ。コードを直接書かず、レビューも直接行わない。サブエージェントの結果を仲介する。
- **エージェントの返答を要約しすぎない**。特に planner のプランは実装の契約なので、ユーザーが原文を見られるようにする。
- Issue のスコープを超えた改善・リファクタリングは提案に留め、実装しない。
- スコープが大きいと判断した場合、**勝手に全サブ Issue を実装しない**。最初の 1 件だけ進めてユーザーに次を委ねる。
- サブ Issue 分割後、元 Issue はクローズしない。全サブ Issue がマージされた時点でユーザーが判断する。
- 途中でエラー・矛盾・スコープ膨張を検知したら、自動で続行せず**ユーザーに判断を仰ぐ**。
- プロジェクトの load-bearing rules（`CLAUDE.md` / 設計ドキュメント記載）に反する変更を検知したらブロックしてユーザーに確認。

## 引数

`/issue-flow:issue-next {番号}` の形式で Issue 番号を直接渡せる。番号を省略した場合、Step 1 で Open Issue 一覧を取得し、優先度順に並べて HTML カードでユーザーに候補を提示する。

例:
- `/issue-flow:issue-next 42` — Issue #42 を処理
- `/issue-flow:issue-next` — Open Issue 一覧から候補を HTML で提示し、ユーザーに選んでもらう
