#!/bin/sh
# wt-up: 起動オーケストレーション（Stage 2 / Task 6.3・§6）
#
# usage: wt-up.sh [worktree_dir]   （省略時は現在の worktree ルート）
#   identity 採番 → env 展開 → pre_start → start を BG 起動 → ログ集約（.dev/logs/）
#   → health 待ち（緑まで） → post_start → URL/ログパス提示。
#   マニフェスト or start 宣言が無ければ opt-in（案内して正常終了・§Q9）。
#
# 展開の責務分離（§12.3）:
#   - env 値 / health.url … 値であってコマンドではない → wt_expand_value のサンドボックス展開
#     （${VAR}/$VAR/$((算術)) のみ・コマンド置換と backtick は loud-error 拒否）
#   - start / hooks / health.command … 意図的なコマンド実行 → 注入済み env で sh -c 実行
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/wt-identity.sh"

WT_ARG=${1:-}
if [ -n "$WT_ARG" ]; then
  ROOT=$(CDPATH= cd -- "$WT_ARG" && pwd -P) || wt_die "パス解決に失敗: $WT_ARG"
else
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || wt_die "git リポジトリ内で実行してください"
fi
MANIFEST="$ROOT/.wt-parallel.yaml"
DEV="$ROOT/.dev"

# ── opt-in: マニフェスト or start 宣言が無ければ案内して正常終了（§Q9）──
if [ ! -f "$MANIFEST" ]; then
  wt_info "起動対象が宣言されていません（.wt-parallel.yaml が無い）。作成・引き継ぎのみが対象です。"
  exit 0
fi
wt_manifest_validate "$MANIFEST"   # 範囲外構文は loud-error（§5.1）
START=$(wt_yaml_scalar "$MANIFEST" start)
if [ -z "$START" ]; then
  wt_info "起動対象が宣言されていません（manifest に start が無い）。"
  exit 0
fi

# ── slug: wt-new が永続化したものを優先、無ければ現在ブランチから ──
WT_SLUG=$(wt_read_slug "$DEV")
if [ -z "$WT_SLUG" ]; then
  br=$(cd "$ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo wt)
  WT_SLUG=$(wt_slugify "$br")
  wt_persist_slug "$DEV" "$WT_SLUG"
fi
export WT_SLUG

# ── ポート offset 採番（ports.check があれば・既存は再利用・§7）──
WT_OFFSET=0
CHECK_RAW=$(wt_yaml_map_value "$MANIFEST" ports check)
if [ -n "$CHECK_RAW" ]; then
  existing=$(wt_read_offset "$DEV")
  if [ -n "$existing" ]; then
    WT_OFFSET=$existing
    wt_info "ポート offset を再利用: $WT_OFFSET"
  else
    set -f                                   # ポート分解時のグロブ展開を抑止
    set -- $(wt_flow_items "$CHECK_RAW")
    set +f
    if [ "$#" -gt 0 ]; then
      WT_OFFSET=$(wt_find_offset 200 "$@") || wt_die "空きポート offset が見つかりません（check: ${CHECK_RAW}）"
      wt_persist_offset "$DEV" "$WT_OFFSET"
      wt_info "ポート offset を採番: $WT_OFFSET （base: ${*}）"
    fi
  fi
fi
export WT_OFFSET

# ── env マップ展開（concrete 値に解決して export・start/health/hooks へ共通注入）──
for k in $(wt_yaml_map_keys "$MANIFEST" env); do
  raw=$(wt_yaml_map_value "$MANIFEST" env "$k")
  ev=$(wt_expand_value "$raw")
  export "$k=$ev"
  wt_info "env: $k=$ev"
done

mkdir -p "$DEV/logs"
LOG="$DEV/logs/start.log"

# ── ライフサイクルフック（宣言されたものだけ・worktree ルートで sh -c 実行）──
run_hook() {
  hraw=$(wt_yaml_map_value "$MANIFEST" hooks "$1")
  [ -n "$hraw" ] || return 0
  wt_info "hook $1: $hraw"
  ( cd "$ROOT" && sh -c "$hraw" )
}

# ── pre_start（失敗で起動中断・§6）──
run_hook pre_start || wt_die "pre_start フックが失敗しました（起動中断）"

# ── start をバックグラウンド起動 → stdout/stderr を .dev/logs/ に集約 ──
( cd "$ROOT" && exec sh -c "$START" ) >"$LOG" 2>&1 &
PID=$!
printf '%s\n' "$PID" > "$DEV/pid"
wt_info "起動: pid=$PID  log=$LOG"

# ── health 待ち（url か command の一方・既定 60s・§Q12）──
H_URL=$(wt_yaml_map_value "$MANIFEST" health url)
H_CMD=$(wt_yaml_map_value "$MANIFEST" health command)
H_TIMEOUT=$(wt_yaml_map_value "$MANIFEST" health timeout)
case "$H_TIMEOUT" in ''|*[!0-9]*) H_TIMEOUT=60 ;; esac
H_URL_EXPANDED=""

if [ -n "$H_URL" ] || [ -n "$H_CMD" ]; then
  [ -n "$H_URL" ] && H_URL_EXPANDED=$(wt_expand_value "$H_URL")
  wt_info "health 待ち（timeout=${H_TIMEOUT}s）…"
  ok=0; elapsed=0
  while [ "$elapsed" -lt "$H_TIMEOUT" ]; do
    if ! kill -0 "$PID" 2>/dev/null; then
      wt_warn "起動プロセスが health 緑前に終了しました。ログ末尾:"
      tail -20 "$LOG" >&2 2>/dev/null || true
      rm -f "$DEV/pid"
      wt_die "起動に失敗しました（プロセス終了）"
    fi
    if [ -n "$H_CMD" ]; then
      if ( cd "$ROOT" && sh -c "$H_CMD" ) >/dev/null 2>&1; then ok=1; break; fi
    else
      if command -v curl >/dev/null 2>&1; then
        curl -sf -o /dev/null "$H_URL_EXPANDED" 2>/dev/null && { ok=1; break; }
      elif command -v wget >/dev/null 2>&1; then
        wget -q -O /dev/null "$H_URL_EXPANDED" 2>/dev/null && { ok=1; break; }
      else
        wt_warn "curl / wget が無いため URL health を検証できません。起動のみ扱いにします。"
        ok=1; break
      fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  if [ "$ok" -ne 1 ]; then
    wt_warn "health がタイムアウトしました（${H_TIMEOUT}s）。ログ末尾:"
    tail -20 "$LOG" >&2 2>/dev/null || true
    kill "$PID" 2>/dev/null || true
    command -v pkill >/dev/null 2>&1 && pkill -P "$PID" 2>/dev/null || true
    rm -f "$DEV/pid"
    wt_die "health 緑になりませんでした"
  fi
  wt_info "health 緑"
else
  wt_info "health 宣言が無いため、起動のみで完了扱いにします。"
fi

# ── post_start（health 緑後・失敗で中断・§6）──
# 失敗時は起動を「中断」とみなし、health タイムアウト経路と対称に停止・後片付けする。
if ! run_hook post_start; then
  kill "$PID" 2>/dev/null || true
  command -v pkill >/dev/null 2>&1 && pkill -P "$PID" 2>/dev/null || true
  rm -f "$DEV/pid"
  wt_die "post_start フックが失敗しました（起動中断）"
fi

# ── 提示（DoD: URL / ログパス）──
[ -n "$H_URL_EXPANDED" ] && wt_info "URL: $H_URL_EXPANDED"
wt_info "ログ: $LOG  （追う: tail -f \"$LOG\"）"
wt_info "停止: sh \"$DIR/wt-down.sh\" \"$ROOT\""
exit 0
