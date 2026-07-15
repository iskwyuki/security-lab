---
name: pr-review-loop
description: PR に対して code-review（検証パス込み）→ 修正 → PR コメント → 再レビューの自律ループをローカルで回す。収束後のマージは行わない（ユーザーの手動操作に委ねる）
---

# PR レビューループスキル

PR 作成直後（pr skill から自動起動）または任意の PR に対して、レビュー → 検証 → 修正 → 再レビューを自律的に回す。GitHub Actions 等の外部 CI は使わず、すべてローカルセッション内で完結する（API 従量課金を発生させない）。

## 引数

- 引数なし → カレントブランチに紐づく PR（`gh pr view --json number` で解決）
- PR 番号（例: `123`）→ 指定 PR

## 防御原則（必読）

| 原則 | 内容 |
|---|---|
| 修正閾値 | 修正するのは**検証済み（confirmed）の Critical** と **confidence: high の confirmed Warning** のみ。Info は絶対に修正しない |
| 収束条件 | ループは最大 **2 周**。2周目終了時点で confirmed Critical が残る場合は停止してユーザーへエスカレーション |
| 指摘の追跡 | 各指摘に ID（R1, R2, ...）を振り、周回をまたいで追跡する。**同一 ID への再修正は禁止**（1度の修正で解消しなかった指摘はエスカレーション対象） |
| エビデンス | 「修正した」と報告する前に、修正コミットの diff が指摘に対応していることを確認する。根拠のない完了報告をしない |
| マージ禁止 | このスキルは**マージを行わない**。収束後「マージ可能」と報告し、判断はユーザーに委ねる |

## 手順

### Step 1: レビュー実行

`/code-review pr <番号>` を実行する（検証パス込み。レベルは Full）。

### Step 2: 収束判定

検証済み（confirmed）の Critical / confidence: high の confirmed Warning が 0 件の場合:

1. `gh pr comment <番号>` でレビュー結果サマリを投稿する（指摘 0 件、または棄却・Info のみである旨と件数）
2. 効果ログにループ総括を 1 行記録する（**JSON は `log-effect.sh` が組む。手で書かない**。best-effort、plugin ルート不明ならスキップ）:

```sh
LE="${CLAUDE_PLUGIN_ROOT:-}/hooks/log-effect.sh"
[ -f "$LE" ] && sh "$LE" --tool pr-review-loop --model "<実行モデル ID>" \
  --confirmed <全周回の confirmed 総数> --refuted <棄却総数> \
  --diff-lines <PR 差分の追加+削除行数> --repo-path "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
```

3. 「レビュー収束。マージ可能な状態です」と報告して終了する（マージはしない）

### Step 3: 修正

1. 修正対象に ID（R1, R2, ...）を振り、修正方針を整理する
2. 各指摘を修正し、`fix: レビュー指摘対応 (R1, R2)` の形式でコミットして PR ブランチへプッシュする
3. プロジェクトに lint / typecheck / テストがある場合は、プッシュ前に実行して通過を確認する

### Step 4: PR コメントで対応表を投稿

`gh pr comment <番号>` で以下の形式の対応表を投稿する:

```markdown
## レビューループ 第N周

| ID | 指摘 | 検証 | 対応 |
|----|------|------|------|
| R1 | `file:line` 指摘内容 | confirmed | 修正済み（コミット abc1234） |
| R2 | `file:line` 指摘内容 | refuted（棄却理由） | 修正不要 |
| R3 | `file:line` 指摘内容 | confirmed（Warning / low） | 見送り（理由） |
```

### Step 5: 再レビュー

Step 1 に戻る（第2周）。修正対象が 0 になったら Step 2 の収束処理へ。

**2周しても収束しない場合**:
1. 残存指摘と「なぜ収束しないか」の分析を PR コメントに投稿する
2. ユーザーへエスカレーションして終了する（それ以上の修正はしない）

## 注意事項

- レビュー・修正の対象はあくまで PR の差分。スコープ外のリファクタリングを修正に混ぜない
- 修正コミットは PR ブランチに積む（force-push しない）
- ユーザーが「レビュー不要」と明示した場合は起動しない
