---
name: push-asset
description: プロジェクトの .claude/<type>/<name>/ を配信元リポジトリ (iskwyuki-claude-plugins) の assets/ にコピーし、feature branch + PR 経由で他リポジトリからも利用できるようにする。「この skill を他リポジトリでも使いたい」導線。
---

# push-asset

プロジェクトで作成・改善した asset を配信元に昇格させる、pull-assets の逆方向同期。

## 使い方

- `/push-asset <type> <name>` — feature branch を作成し push、PR 作成を案内
- `--dry-run` — 差分表示のみ
- `--auto-merge` — PR 作成 → squash merge → branch 削除 → local main 同期まで自動

`<type>` は skills / agents / hooks など、プロジェクトの `.claude/` 直下のディレクトリ名。

## 原則

- **main 直接 push は禁止。必ず feature branch（`feat/push-<type>-<name>`、重複時はタイムスタンプ付与）＋ PR 経由**
- 昇格させる asset は**技術スタック非依存の汎用性**を持つこと。特定フレームワーク・プロジェクト固有スクリプトに依存するものはプロジェクト側に残す判断を検討する
- **既存 asset の上書きは全消費リポジトリに波及する**。差分（`diff -ruN`）を提示し、AskUserQuestion で確認してからコピーする
- 配信元は公開リポジトリである前提で、**固有情報（社名・非公開リポジトリ名・認証情報）を含む内容を昇格させない**

## 配信元パスの解決

優先順: `$CLAUDE_PLUGINS_REPO` → `~/dev/iskwyuki-claude-plugins` → `~/dev/claude-code-plugins`（後方互換）。見つからなければ clone コマンドを案内して終了。

## フロー要点

1. `.claude/<type>/<name>` の存在確認 → 配信元との差分表示（`--dry-run` はここまで）
2. 配信元で main を最新化 → feature branch 作成 → `rsync -av --delete`（単一ファイルは `cp -f`）→ 明示パスで commit → push
3. `--auto-merge` 時: `gh pr create` → `gh pr merge --squash --delete-branch` → local main を `--ff-only` で同期。指定なしなら PR 作成コマンドを案内し、ユーザーが GitHub 上で確認してから merge する
4. merge 後の各プロジェクトへの反映は `/plugin marketplace update` → `/pull-assets` → commit を案内

## 過去事例

- 配信元での version bump（`.claude-plugin/plugin.json`）を忘れると、利用側の `/plugin marketplace update` でキャッシュが更新されないことがある。asset 変更を伴う PR では bump を必ず確認する
