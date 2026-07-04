---
description: コミットメッセージ生成＋コミット実行
trigger: "when the user asks to commit changes"
disable-model-invocation: true
---

# コミットスキル

## 原則

- メッセージは Conventional Commits 形式・日本語（`<type>: <簡潔な説明>`）。複数の論理的変更が混在していたら分割コミットを提案する
- 変更に関連するオープン Issue があれば `Closes #N` の追記を提案する（強制ではない。ブランチ運用で自動クローズされない場合は merge 後に `gh issue close N`）
- メッセージはユーザーに提示し、承認を得てからコミットする

## チェックリスト（コミット前）

- [ ] `git add` は**明示パス指定のみ**（`-A` / `.` 禁止）
- [ ] `git diff --cached --stat` でステージ内容が意図と一致している
- [ ] `.env`・認証情報・ランタイム状態ファイル（`.claude/state/` 等）が混入していない
- [ ] コミット後、プッシュするかをユーザーに確認した

## 過去事例

- **2026-06-14 ランタイム状態の公開混入**: `git add -A` がセッションイベントログを巻き込み、固有情報数百行が public リポジトリに露出。履歴リライトで対処した。明示パス＋ステージ確認の 2 段防御はこの再発防止
- 関連 Issue の見落とし: コミット時に `gh issue list --state open` を引いて突合する習慣で、クローズ漏れ Issue の滞留が解消した
