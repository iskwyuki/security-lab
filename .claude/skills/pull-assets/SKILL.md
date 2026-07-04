---
name: pull-assets
description: 配信元リポジトリ (iskwyuki-claude-plugins) の asset をプロジェクトの .claude/ へ同期する。assets/ 配下のディレクトリを動的走査するため、将来 hooks や commands が追加されても skill 本体の変更なしで対応する。
---

# pull-assets

Plugin キャッシュ配下の `assets/` をプロジェクトの `.claude/` にコピーする。2 回目以降の継続運用で使う。

## 使い方

- `/pull-assets` — assets 配下の全ディレクトリを同期
- `/pull-assets --dry-run` — 差分表示のみ
- `/pull-assets --only=<dir>` — 特定ディレクトリだけ同期（例: `--only=skills`）

## 原則

- **配布対象は動的検出**: `ls -1 "$PLUGIN_ROOT/assets/"` の出力すべてを対象にする。skills/agents をハードコードしない
- **`rsync` に `--delete` は使わない**（プロジェクト固有 skill の誤削除防止）
- 実コピーの前に dry-run（`rsync -avn`）で「新規追加」「上書き」を区別して提示し、AskUserQuestion で確認を取る
- 同期後は `git status -- .claude/` を見せ、`git add .claude/ && git commit -m "chore: iskwyuki-claude-plugins 同期"` を案内する

## キャッシュパスの解決（非自明なので定型を使う）

```bash
PLUGIN_ROOT=$(ls -d "$HOME/.claude/plugins/cache/iskwyuki-claude-plugins/iskwyuki-claude-plugins"/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/*$::')
test -n "$PLUGIN_ROOT" || { echo "Plugin cache not found. Run: /plugin marketplace update && /plugin install iskwyuki-claude-plugins@iskwyuki-claude-plugins"; exit 1; }
```

`$PLUGIN_ROOT/assets` が無い場合は `/plugin marketplace update` → 再 install を案内して終了する。

## 衝突時の取扱い

配信元 asset とプロジェクト固有 skill のディレクトリ名が同じ場合、配信元側が上書きする。プロジェクト固有の独自機能は**配信元と重複しない命名**にすること（例: `/code-review` は配信元、`/code-review-custom` はプロジェクト固有）。

## 過去事例

- 配布対象を skills/agents 固定で実装していた時期に、hooks の配布開始時へ追従漏れが起きかけた。動的走査の原則はその教訓
