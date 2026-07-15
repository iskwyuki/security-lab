---
description: git worktree を新規に切って並列開発を始める入口。会話文脈からブランチ名を推定し、テキスト番号付き確認のうえ worktree を作成・設定/plugin を引き継ぐ
trigger: "when the user asks to start a new worktree, work on an issue in parallel, or run /wt-new"
disable-model-invocation: true
---

# wt-new — worktree 作成入口

git worktree を 1 本切り、`.env` / `.claude/settings.local.json` の引き継ぎと plugin 登録まで一括で行う。**起動系（wt-up）はリリース 2 で追加予定**。マニフェストが無くても動く（作成＋引き継ぎ＋plugin 登録のみ）。

## 原則

- **必ずこの skill 経由**で worktree を作る。`git worktree add` の直叩き・片付けの `git worktree remove` 直叩きは孤児リソースや plugin 登録残骸を生むため使わない（破棄は `wt-rm.sh`）。
- **AskUserQuestion は使わない**（グローバルルール）。確認は必ず**テキストの番号付き**で行う。
- ブランチ名はユーザーが明示していれば尊重。未指定なら会話文脈（対象 Issue・作業内容）から推定し、確定前に提示して合意を取る。

## 手順

1. **スクリプトの場所を解決**する。この skill と同じ配信元に `wt-parallel/scripts/wt-new.sh` がある:
   - 配信先: `.claude/skills/wt-parallel/scripts/wt-new.sh`
   - 配信元（symlink 経由）でも同じ相対で見える。絶対パスに直して以降で使う。
2. **ブランチ名を確定**する。命名はプロジェクト慣習に合わせる（例 `feature/<topic>` / `fix/<issue>`）。推定した場合は次の形で提示し、合意を得てから実行:

   ```
   以下で worktree を作成します。よろしいですか。
   1. このまま作成（ブランチ: feature/xxx / 起点: 自動）
   2. ブランチ名を変える
   3. 起点(base_ref)を指定する（例: origin/main）
   4. 中止
   ```

3. **実行**する（人向けメッセージは stderr、作成された worktree パスは stdout に 1 行）:

   ```sh
   sh <解決した絶対パス>/wt-new.sh "<branch>" [base_ref] [worktree_dir]
   ```

   - `base_ref` 省略時の解決順: env `BASE_REF` > マニフェスト `base_ref` > `origin/HEAD` > 現在ブランチ。
   - plugin 登録を抑止したいときは `WT_SKIP_PLUGIN_REGISTER=1` を付ける。
4. **次手順を案内**する。stdout の worktree パスを使って `cd` を促し、破棄は `wt-rm.sh <worktree>` である旨を伝える。

## チェックリスト

- [ ] ブランチ名をユーザーと合意済み（推定時は提示→承認）
- [ ] `git worktree add` を直叩きしていない（この skill/スクリプト経由）
- [ ] 作成後、worktree の絶対パスと破棄コマンドをユーザーに提示した

## 関連

- ライフサイクル正本・マニフェスト仕様: `wt-parallel` skill（`SKILL.md` ＋ `.wt-parallel.yaml.example`）
- 設計正本: `docs/wt-parallel-design.md`
