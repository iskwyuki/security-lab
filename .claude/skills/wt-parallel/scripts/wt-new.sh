#!/bin/sh
# wt-new: worktree 作成 → 設定引き継ぎ → plugin 登録 → 次手順表示（Stage 1 / Task 6.1）
#
# usage: wt-new.sh <branch> [base_ref] [worktree_dir]
#   - マニフェスト（.wt-parallel.yaml）は任意。無ければ作成＋引き継ぎ＋plugin 登録のみ。
#   - 成功時、作成した worktree の絶対パスを **stdout に 1 行だけ** 出力する（人向けは stderr）。
#
# base_ref 解決順（§Q17）: env BASE_REF > 引数 base_ref > manifest base_ref
#                          > origin/HEAD > 現在ブランチ
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/wt-identity.sh"

usage() { printf 'usage: wt-new.sh <branch> [base_ref] [worktree_dir]\n' >&2; exit 2; }

BRANCH=${1:-}; [ -n "$BRANCH" ] || usage
BASE_ARG=${2:-}
DIR_ARG=${3:-}

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || wt_die "git リポジトリ内で実行してください"
COMMON=$(cd "$ROOT" && git rev-parse --git-common-dir 2>/dev/null) || COMMON=".git"
case "$COMMON" in /*) ;; *) COMMON="$ROOT/$COMMON" ;; esac
MANIFEST="$ROOT/.wt-parallel.yaml"

SLUG=$(wt_slugify "$BRANCH")

# ── base_ref 解決 ─────────────────────────────
BASE_REF=${BASE_REF:-}
[ -n "$BASE_REF" ] || BASE_REF=$BASE_ARG
if [ -z "$BASE_REF" ] && [ -f "$MANIFEST" ]; then
  BASE_REF=$(wt_yaml_scalar "$MANIFEST" base_ref)
fi
if [ -z "$BASE_REF" ]; then
  BASE_REF=$(cd "$ROOT" && git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || BASE_REF=""
fi
[ -n "$BASE_REF" ] || BASE_REF=$(cd "$ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
[ -n "$BASE_REF" ] || wt_die "base_ref を解決できません（BASE_REF / 引数 / manifest / origin/HEAD いずれも不在）"

# ── worktree ディレクトリ ─────────────────────
if [ -n "$DIR_ARG" ]; then
  WT_DIR=$DIR_ARG
else
  WT_DIR="$(dirname "$ROOT")/$(basename "$ROOT")--$SLUG"
fi
# 相対指定を絶対化する。git 操作は (cd "$ROOT") 内・ファイル操作は cwd 内で走るため、
# 絶対化しないと両者の基準がズレて worktree が壊れ、stdout の「絶対パス契約」も破れる。
case "$WT_DIR" in /*) ;; *) WT_DIR="$(pwd -P)/$WT_DIR" ;; esac
[ -e "$WT_DIR" ] && wt_die "作成先が既に存在します: $WT_DIR"

# ── .dev/ を全 worktree で git 除外（§12.2）───────
wt_ensure_dev_ignored "$COMMON"

# ── worktree 作成（既存ブランチは展開・無ければ base 起点で新規）─────
if (cd "$ROOT" && git show-ref --verify --quiet "refs/heads/$BRANCH"); then
  wt_info "既存ブランチ '$BRANCH' を worktree に展開します"
  (cd "$ROOT" && git worktree add "$WT_DIR" "$BRANCH") >&2 || wt_die "git worktree add に失敗しました"
else
  wt_info "新規ブランチ '$BRANCH' を '$BASE_REF' 起点で作成します"
  (cd "$ROOT" && git worktree add -b "$BRANCH" "$WT_DIR" "$BASE_REF") >&2 || wt_die "git worktree add に失敗しました"
fi

# ── slug 永続化 ───────────────────────────────
wt_persist_slug "$WT_DIR/.dev" "$SLUG"

# ── 設定引き継ぎ（デフォルト: .env / settings.local.json、非存在は無警告スキップ）──
for rel in ".env" ".claude/settings.local.json"; do
  wt_inherit_file "$ROOT" "$WT_DIR" "$rel"
done
# manifest inherit: の追加分（非存在は無警告スキップ・範囲外パスは拒否・§Q16）
if [ -f "$MANIFEST" ]; then
  wt_yaml_list "$MANIFEST" inherit | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    wt_inherit_file "$ROOT" "$WT_DIR" "$rel"
  done
fi

# ── plugin 登録引き継ぎ（§8）─────────────────────
# ソース project で enabledPlugins=true のうち、user スコープ済みを除いたものを
# 新 worktree に project スコープ install。install したものは .dev/plugins に記録し
# wt-rm が対称に解除できるようにする。非CC/jq不在/オプトアウトはスキップ（set は落とさない）。
if wt_plugin_available; then
  wt_plugins_to_register "$HOME/.claude/settings.json" \
    "$ROOT/.claude/settings.json" "$ROOT/.claude/settings.local.json" \
    | while IFS= read -r plug; do
    [ -n "$plug" ] || continue
    if (cd "$WT_DIR" && claude plugin install "$plug" --scope project >/dev/null 2>&1); then
      printf '%s\n' "$plug" >> "$WT_DIR/.dev/plugins"
      wt_info "plugin 登録: $plug"
    else
      wt_warn "plugin 登録に失敗（スキップ）: $plug"
    fi
  done
elif [ "${WT_SKIP_PLUGIN_REGISTER:-0}" = "1" ]; then
  wt_info "plugin 登録をスキップ（WT_SKIP_PLUGIN_REGISTER=1）"
else
  wt_info "plugin 登録をスキップ（claude / jq が見つかりません）"
fi

# ── post_create フック（作成＋引き継ぎ直後・失敗で中断・§6）─────
# worktree は gitignore された node_modules 等を持たないため、依存初期化（pnpm install 等）を
# ここで実行する。宣言時のみ実行し、失敗したら wt_die で中断する（半端な worktree は wt-rm で片付け）。
if [ -f "$MANIFEST" ]; then
  POST_CREATE=$(wt_yaml_map_value "$MANIFEST" hooks post_create)
  if [ -n "$POST_CREATE" ]; then
    wt_manifest_validate "$MANIFEST" || wt_die "manifest が strict-subset 外です。post_create を実行できません: $WT_DIR（片付け: sh \"$DIR/wt-rm.sh\" \"$WT_DIR\"）"
    # フックへ env コンテキストを注入。offset は作成時点では未採番（wt-up の責務）なので 0 既定。
    WT_SLUG=$SLUG; export WT_SLUG
    WT_OFFSET=$(wt_read_offset "$WT_DIR/.dev"); [ -n "$WT_OFFSET" ] || WT_OFFSET=0; export WT_OFFSET
    for k in $(wt_yaml_map_keys "$MANIFEST" env); do
      ev=$(wt_expand_value "$(wt_yaml_map_value "$MANIFEST" env "$k")")
      export "$k=$ev"
    done
    wt_info "hook post_create: $POST_CREATE"
    ( cd "$WT_DIR" && sh -c "$POST_CREATE" ) >&2 || wt_die "post_create フックが失敗しました（作成中断）: $WT_DIR（片付け: sh \"$DIR/wt-rm.sh\" \"$WT_DIR\"）"
  fi
fi

# ── 次手順 ───────────────────────────────────
printf '%s\n' "$WT_DIR"   # ★ stdout は worktree パスのみ
wt_info "作成完了: $WT_DIR  (slug=$SLUG, base=$BASE_REF)"
wt_info "次: cd \"$WT_DIR\""
if [ -f "$MANIFEST" ]; then
  wt_info "起動: sh \"$DIR/wt-up.sh\" \"$WT_DIR\"  （停止: sh \"$DIR/wt-down.sh\" \"$WT_DIR\"）"
else
  wt_info "マニフェスト（.wt-parallel.yaml）が無いため起動系は対象外（作成＋引き継ぎ＋plugin 登録のみ）"
fi
wt_info "破棄: sh \"$DIR/wt-rm.sh\" \"$WT_DIR\""
