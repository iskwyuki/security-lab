#!/bin/sh
# wt-rm: worktree 破棄（stop → pre_rm → plugin 対称解除 → git worktree remove）（§6・Task 6.1/6.4）
#
# usage: wt-rm.sh <worktree_dir>
#   - 起動プロセスがあれば wt-down で停止してから破棄する（§6 の [stop]）。
#   - pre_rm フックを注入済み env（WT_SLUG/WT_OFFSET + env マップ）のもと実行。失敗は
#     警告どまりで破棄続行（§6: pre_rm は app 責務・汎用版は呼ぶだけ）。
#   - .dev/plugins に記録された project スコープ plugin を対称に uninstall（ダングリング防止・§8）。
#   - メイン worktree・未登録パスは拒否（§9 安全不変条件）。
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/wt-identity.sh"

usage() { printf 'usage: wt-rm.sh <worktree_dir>\n' >&2; exit 2; }
WT_DIR=${1:-}; [ -n "$WT_DIR" ] || usage
[ -d "$WT_DIR" ] || wt_die "worktree ディレクトリが存在しません: $WT_DIR"
WT_ABS=$(CDPATH= cd -- "$WT_DIR" && pwd -P) || wt_die "パス解決に失敗: $WT_DIR"

LIST=$(git -C "$WT_ABS" worktree list --porcelain 2>/dev/null) || wt_die "git worktree ではありません: $WT_ABS"
# `worktree <path>` の path はスペースを含み得るため $2 分割ではなくプレフィックスを剥がす
MAIN_WT=$(printf '%s\n' "$LIST" | awk '/^worktree /{sub(/^worktree /,""); print; exit}')

# 登録済み linked worktree であることを確認（未登録パスの誤削除防止）
if ! printf '%s\n' "$LIST" | awk '/^worktree /{sub(/^worktree /,""); print}' | grep -qxF "$WT_ABS"; then
  wt_die "登録済みの worktree ではありません: $WT_ABS"
fi
# メイン worktree の破棄は拒否
[ "$WT_ABS" != "$MAIN_WT" ] || wt_die "メイン worktree は破棄できません: $WT_ABS"

# ── 起動プロセスを停止してから破棄（§6 の [stop]・wt-up 済みなら .dev/pid を止める）──
if [ -f "$DIR/wt-down.sh" ]; then
  sh "$DIR/wt-down.sh" "$WT_ABS" >/dev/null || wt_warn "停止処理で警告（破棄は続行）"
fi

# ── pre_rm フック（破棄直前・失敗は警告どまりで破棄続行・§6）──
MANIFEST="$WT_ABS/.wt-parallel.yaml"
if [ -f "$MANIFEST" ]; then
  if wt_manifest_validate "$MANIFEST" 2>/dev/null; then
    PRE_RM=$(wt_yaml_map_value "$MANIFEST" hooks pre_rm)
    if [ -n "$PRE_RM" ]; then
      # フックへ env コンテキストを注入（WT_SLUG/WT_OFFSET + env マップ・§7 と同一値）。
      # 破棄時は offset を採番し直さず、永続化済みの値をそのまま読む。
      WT_SLUG=$(wt_read_slug "$WT_ABS/.dev"); export WT_SLUG
      [ -n "$WT_SLUG" ] || wt_warn "WT_SLUG が空です（.dev/slug 不在）。pre_rm を WT_SLUG 未設定で実行します（\${WT_SLUG} 依存の破壊コマンドに注意）"
      WT_OFFSET=$(wt_read_offset "$WT_ABS/.dev"); [ -n "$WT_OFFSET" ] || WT_OFFSET=0; export WT_OFFSET
      for k in $(wt_yaml_map_keys "$MANIFEST" env); do
        ev=$(wt_expand_value "$(wt_yaml_map_value "$MANIFEST" env "$k")")
        export "$k=$ev"
      done
      wt_info "hook pre_rm: $PRE_RM"
      ( cd "$WT_ABS" && sh -c "$PRE_RM" ) || wt_warn "pre_rm フックが失敗しました（警告どまり・破棄続行）"
    fi
  else
    wt_warn "manifest が strict-subset 外のため pre_rm をスキップ（破棄は続行）"
  fi
fi

# ── plugin 対称解除（.dev/plugins に記録された分だけ）──────────
if [ -f "$WT_ABS/.dev/plugins" ]; then
  if wt_plugin_available; then
    while IFS= read -r plug; do
      [ -n "$plug" ] || continue
      if (cd "$WT_ABS" && claude plugin uninstall "$plug" --scope project >/dev/null 2>&1); then
        wt_info "plugin 解除: $plug"
      else
        wt_warn "plugin 解除に失敗（続行）: $plug"
      fi
    done < "$WT_ABS/.dev/plugins"
  else
    wt_warn "plugin 解除をスキップ（claude / jq 不在 or オプトアウト）。.dev/plugins に登録記録あり"
  fi
fi

# ── worktree 破棄（引き継ぎ .env 等の untracked を含むため --force）──────
# メイン worktree コンテキストから実行する（自分自身の cwd 内では remove できないため）。
if (cd "$MAIN_WT" && git worktree remove --force "$WT_ABS") >&2; then
  wt_info "破棄完了: $WT_ABS"
else
  wt_die "git worktree remove に失敗しました: $WT_ABS"
fi
