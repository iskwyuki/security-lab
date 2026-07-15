#!/bin/sh
# wt-down: 起動プロセスの停止のみ（Stage 2 / Task 6.3・§6）
#
# usage: wt-down.sh [worktree_dir]   （省略時は現在の worktree ルート）
#   .dev/pid に記録された起動プロセスを TERM→（猶予）→KILL で止める。
#   worktree・外部リソース・ポート採番（.dev/offset）・slug は残す（停止のみ）。
#   起動記録が無い / 既に停止済みは冪等に exit 0。
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/wt-identity.sh"

WT_ARG=${1:-}
if [ -n "$WT_ARG" ]; then
  ROOT=$(CDPATH= cd -- "$WT_ARG" && pwd -P) || wt_die "パス解決に失敗: $WT_ARG"
else
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || wt_die "git リポジトリ内で実行してください"
fi
PIDFILE="$ROOT/.dev/pid"

if [ ! -f "$PIDFILE" ]; then
  wt_info "起動記録がありません（.dev/pid 不在）。停止対象はありません。"
  exit 0
fi
PID=$(head -1 "$PIDFILE" 2>/dev/null || echo "")
case "$PID" in
  ''|*[!0-9]*) wt_warn ".dev/pid が不正です（${PID}）。記録を破棄します。"; rm -f "$PIDFILE"; exit 0 ;;
esac

if ! kill -0 "$PID" 2>/dev/null; then
  wt_info "既に停止しています（pid=${PID}）。"
  rm -f "$PIDFILE"
  exit 0
fi

# TERM → 猶予（最大 5s）→ KILL。直接の子プロセスも best-effort で回収する。
kill -TERM "$PID" 2>/dev/null || true
command -v pkill >/dev/null 2>&1 && pkill -TERM -P "$PID" 2>/dev/null || true
i=0
while [ "$i" -lt 25 ] && kill -0 "$PID" 2>/dev/null; do i=$((i + 1)); sleep 0.2; done
if kill -0 "$PID" 2>/dev/null; then
  kill -KILL "$PID" 2>/dev/null || true
  command -v pkill >/dev/null 2>&1 && pkill -KILL -P "$PID" 2>/dev/null || true
  sleep 0.2
fi
rm -f "$PIDFILE"

if kill -0 "$PID" 2>/dev/null; then
  wt_die "プロセスを停止できませんでした（pid=${PID}）"
fi
wt_info "停止しました（pid=${PID}）。worktree とポート採番（.dev/offset）は保持します。"
exit 0
