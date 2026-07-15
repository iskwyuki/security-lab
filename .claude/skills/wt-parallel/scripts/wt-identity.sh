#!/bin/sh
# wt-parallel 共通ライブラリ（source して使う）。
# slug 正規化・.dev/ 永続化・git 除外の冪等追記・マニフェスト strict-subset パーサ
# （scalar/list）・plugin 可用性判定など、副作用の無い/冪等な部品を提供する。
# 直接実行しても何も起きない（関数定義のみ・グローバルな set はしない）。
#
# 注意（§12.4 / §5.1）: yq に依存しない。トップレベルスカラ + ブロックリスト（Stage 1）に
#   加え、Stage 2（Task 6.3）で 2 階層マップ（env/hooks/health/ports）・inline flow list・
#   範囲外構文の loud-error 検証・空きポート offset 採番・env 式展開サンドボックスを追加した。

# ── ログ（人向けは stderr。stdout は機械可読出力に空ける）────────────
wt_info() { printf 'wt-parallel: %s\n'        "$*" >&2; }
wt_warn() { printf 'wt-parallel: [warn] %s\n' "$*" >&2; }
wt_die()  { printf 'wt-parallel: [error] %s\n' "$*" >&2; exit 1; }

# ── slug 正規化 ────────────────────────────────────────────
# ブランチ名 → 英小文字/数字/ハイフンのみ。連続する非英数字は 1 個のハイフンに圧縮し、
# 前後のハイフンを除去、40 文字に切り詰める。空になったら "wt" にフォールバック。
wt_slugify() (
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
      | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^--*//' -e 's/--*$//' \
      | cut -c1-40 | sed -e 's/--*$//')
  [ -n "$s" ] || s=wt
  printf '%s' "$s"
)

# ── .dev/ 永続化 ───────────────────────────────────────────
wt_persist_slug() (
  devdir=$1; slug=$2
  mkdir -p "$devdir"
  printf '%s\n' "$slug" > "$devdir/slug"
)
wt_read_slug() (
  devdir=$1
  [ -f "$devdir/slug" ] || return 0
  head -1 "$devdir/slug"
)

# ── .dev/ の git 除外を冪等に確保（§12.2 確定: git-native exclude 追記）──────
# 引数は git common-dir（例: /path/.git）。全 worktree 共通の info/exclude に .dev/ を
# 追記する。tracked な .gitignore を汚さず、全 worktree に一括で効く。既に在れば何もしない。
wt_ensure_dev_ignored() (
  common=$1
  excl="$common/info/exclude"
  mkdir -p "$common/info" 2>/dev/null || true
  [ -f "$excl" ] || : > "$excl"
  if grep -qxF '.dev/' "$excl" || grep -qxF '.dev' "$excl"; then
    return 0
  fi
  printf '%s\n' '.dev/' >> "$excl"
)

# ── 引き継ぎ 1 ファイル（root → worktree）────────────────────────
# rel が worktree 外へ出る（絶対パス・`..` セグメント）場合は loud-warn で拒否（パストラバーサル防止）。
# src 非存在は無警告スキップ（§Q16）。cp / mkdir 失敗は握りつぶさず warn する。
wt_inherit_file() (
  root=$1; wt=$2; rel=$3
  case "$rel" in /*) wt_warn "引き継ぎをスキップ（絶対パス不可）: $rel"; return 0 ;; esac
  case "/$rel/" in *"/../"*) wt_warn "引き継ぎをスキップ（.. を含むパス不可）: $rel"; return 0 ;; esac
  [ -f "$root/$rel" ] || return 0
  mkdir -p "$(dirname "$wt/$rel")" || { wt_warn "引き継ぎ失敗（mkdir）: $rel"; return 0; }
  if cp "$root/$rel" "$wt/$rel"; then wt_info "引き継ぎ: $rel"; else wt_warn "引き継ぎ失敗（cp）: $rel"; fi
)

# ── strict-subset パーサ: トップレベルスカラ ─────────────────────
# `key: value`（インデント無し）の value を返す。クォート（' "）を剥がし、
# 素の値は行末コメントを落とす。不在・ファイル無しは空文字。
wt_yaml_scalar() (
  file=$1; key=$2
  [ -f "$file" ] || return 0
  line=$(grep -E "^${key}:[[:space:]]*" "$file" 2>/dev/null | head -1)
  [ -n "$line" ] || return 0
  val=${line#"${key}:"}
  val=$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//')
  case "$val" in
    \"*) val=$(printf '%s' "$val" | sed -e 's/^"//' -e 's/".*$//') ;;
    \'*) val=$(printf '%s' "$val" | sed -e "s/^'//" -e "s/'.*$//") ;;
    *)   val=$(printf '%s' "$val" | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//') ;;
  esac
  printf '%s' "$val"
)

# ── strict-subset パーサ: ブロックリスト ────────────────────────
# `key:`（値なし）に続くインデント付き `- item` 行を 1 行ずつ返す。次のキー/空行で停止。
# Stage 1 ではクォート剥がしまではしない（inherit のパス想定）。
wt_yaml_list() (
  file=$1; key=$2
  [ -f "$file" ] || return 0
  awk -v k="$key" '
    $0 ~ ("^" k ":[[:space:]]*$") { collecting=1; next }
    collecting==1 {
      if ($0 ~ /^[[:space:]]+-[[:space:]]*/) {
        item=$0
        sub(/^[[:space:]]+-[[:space:]]*/, "", item)
        sub(/[[:space:]]*#.*$/, "", item)
        sub(/[[:space:]]*$/, "", item)
        if (item != "") print item
      } else {
        collecting=0
      }
    }
  ' "$file"
)

# ── settings ファイルから enabledPlugins=true のキーを列挙（jq 前提）────────
wt_enabled_plugins() (
  f=$1
  [ -f "$f" ] || return 0
  jq -r '(.enabledPlugins // {}) | to_entries[] | select(.value==true) | .key' "$f" 2>/dev/null || true
)

# ── 登録すべき plugin を列挙（純粋関数・§10 単体テスト対象）──────────────
# project 設定（複数可）で有効かつ user スコープで未有効のものだけを 1 行ずつ返す。
# 使い方: wt_plugins_to_register <user_settings> <proj_settings>...
wt_plugins_to_register() (
  user_settings=$1; shift
  user_enabled=$(wt_enabled_plugins "$user_settings")
  for pf in "$@"; do wt_enabled_plugins "$pf"; done | sort -u | while IFS= read -r plug; do
    [ -n "$plug" ] || continue
    printf '%s\n' "$user_enabled" | grep -qxF "$plug" && continue   # user スコープ済みは除外
    printf '%s\n' "$plug"
  done
)

# ── plugin 操作を実施してよいか（非CC/jq不在/オプトアウトで false）──────────
wt_plugin_available() {
  [ "${WT_SKIP_PLUGIN_REGISTER:-0}" = "1" ] && return 1
  command -v claude >/dev/null 2>&1 || return 1
  command -v jq     >/dev/null 2>&1 || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════
# Stage 2（Task 6.3・起動系）: 2 階層マップ / flow list / 検証 /
#   offset 採番 / env 式展開サンドボックス（§5.1・§7・§12.3）
# ══════════════════════════════════════════════════════════════

# ── strict-subset: 2 階層マップの値（`parent:` 改行 `  sub: val`）────────
# 値なし親（マップ開き）配下のインデント付き `sub: value` を返す。クォート剥がし・
# 素の値は行末コメントを落とす。親がスカラ（値あり）/不在/サブキー不在は空。
wt_yaml_map_value() (
  file=$1; parent=$2; sub=$3
  [ -f "$file" ] || return 0
  line=$(awk -v p="$parent" -v s="$sub" '
    $0 ~ ("^" p ":[[:space:]]*$") { inblk=1; next }
    inblk==1 {
      if ($0 ~ /^[[:space:]]/) {
        t=$0; sub(/^[[:space:]]+/, "", t)
        if (t ~ ("^" s ":")) { print t; exit }
      } else { exit }
    }
  ' "$file")
  [ -n "$line" ] || return 0
  val=${line#"${sub}:"}
  val=$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//')
  case "$val" in
    \"*) val=$(printf '%s' "$val" | sed -e 's/^"//' -e 's/".*$//') ;;
    \'*) val=$(printf '%s' "$val" | sed -e "s/^'//" -e "s/'.*$//") ;;
    *)   val=$(printf '%s' "$val" | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//') ;;
  esac
  printf '%s' "$val"
)

# ── strict-subset: 2 階層マップのサブキー列挙（宣言順）──────────────
wt_yaml_map_keys() (
  file=$1; parent=$2
  [ -f "$file" ] || return 0
  awk -v p="$parent" '
    $0 ~ ("^" p ":[[:space:]]*$") { inblk=1; next }
    inblk==1 {
      if ($0 ~ /^[[:space:]]/) {
        t=$0; sub(/^[[:space:]]+/, "", t)
        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*:/) { k=t; sub(/:.*$/, "", k); print k }
      } else { exit }
    }
  ' "$file"
)

# ── inline flow list の分解（`[a, b]` → 1 行 1 要素）────────────────
# strict-subset の 1 形式のみ（入れ子は wt_manifest_validate が事前に拒否する）。
wt_flow_items() (
  set -f                                     # 分割時のグロブ展開を抑止（サブシェル内で自己完結）
  raw=$1
  s=${raw#*[}; s=${s%]*}
  case "$s" in *[!\ ]*) ;; *) return 0 ;; esac   # 空 / 空白のみは要素なし
  oIFS=$IFS; IFS=,
  for it in $s; do
    it=$(printf '%s' "$it" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$it" ] && printf '%s\n' "$it"
  done
  IFS=$oIFS
)

# ── マニフェスト検証（範囲外構文を loud-error 拒否・§5.1）────────────
# 受理範囲外（タブ・3 階層以上・多文書・block scalar・flow map・inline list 入れ子・
# anchor/alias）を明示エラーで弾く。クォート値の中身（`&&` 等のシェル演算子）は
# 誤検知しない（引用符付き値は逐語スカラとして検査をスキップ）。
wt_manifest_validate() (
  file=$1
  [ -f "$file" ] || return 0
  tab=$(printf '\t')
  ln=0
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln+1))
    trimmed=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//')
    case "$trimmed" in ''|'#'*) continue ;; esac
    indent=$(printf '%s' "$line" | sed -e 's/[^[:space:]].*$//')
    case "$indent" in *"$tab"*) wt_die "manifest 構文エラー（行 ${ln}）: タブインデントは不可（スペース 2）" ;; esac
    [ "${#indent}" -ge 4 ] && wt_die "manifest 構文エラー（行 ${ln}）: 3 階層以上のネストは不可"
    case "$trimmed" in '---'*) wt_die "manifest 構文エラー（行 ${ln}）: 多文書区切り --- は不可" ;; esac
    # 値の構文検査（key: value 行 と リスト項目 `- x` を分けて扱う）
    case "$trimmed" in
      '-'*)
        # リスト項目のスカラ先頭が anchor/alias なら拒否（§5.1）。非存在ファイルとして
        # 無警告スキップされる前に loud-error で弾く。
        litem=${trimmed#-}
        litem=$(printf '%s' "$litem" | sed -e 's/^[[:space:]]*//')
        case "$litem" in
          '&'*) wt_die "manifest 構文エラー（行 ${ln}）: anchor & は不可（リスト項目）" ;;
          '*'*) wt_die "manifest 構文エラー（行 ${ln}）: alias * は不可（リスト項目）" ;;
        esac
        ;;
      [A-Za-z_]*:*)
        val=${trimmed#*:}
        val=$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//')
        [ -n "$val" ] || continue                 # マップ開き（値なし）
        case "$val" in \"*|\'*) continue ;; esac  # クォート値は逐語スカラ
        vcore=$(printf '%s' "$val" | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//')
        case "$vcore" in
          '&'*)                       wt_die "manifest 構文エラー（行 ${ln}）: anchor & は不可" ;;
          '*'*)                       wt_die "manifest 構文エラー（行 ${ln}）: alias * は不可" ;;
          '{'*)                       wt_die "manifest 構文エラー（行 ${ln}）: flow map {} は不可" ;;
          '|'|'>'|'|'[-+0-9]*|'>'[-+0-9]*) wt_die "manifest 構文エラー（行 ${ln}）: block scalar |/> は不可" ;;
        esac
        case "$vcore" in
          '['*)
            body=${vcore#*[}; body=${body%]*}
            case "$body" in *'['*) wt_die "manifest 構文エラー（行 ${ln}）: inline list の入れ子は不可" ;; esac
            ;;
        esac
        ;;
    esac
  done < "$file"
)

# ── TCP ポートが空いているか（listen 中でないか）──────────────────
# lsof → nc の順に検出。どちらも無ければ検出不能として「空き」とみなす（自動スキップ思想）。
wt_port_free() {
  _p=$1
  if command -v lsof >/dev/null 2>&1; then
    ! lsof -nP -iTCP:"$_p" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v nc >/dev/null 2>&1; then
    ! nc -z 127.0.0.1 "$_p" >/dev/null 2>&1
  else
    return 0
  fi
}

# ── 空きポート offset 採番（§7・純粋関数・wt_port_free を注入点に）──────
# base ポート群すべてが offset とともに同時に空く最小 offset を [0, max] で探す。
# 見つからなければ非ゼロで失敗。テストは wt_port_free をスタブして境界を検証する。
wt_find_offset() (
  max=$1; shift
  n=0
  while [ "$n" -le "$max" ]; do
    all_free=1
    for base in "$@"; do
      wt_port_free "$((base + n))" || { all_free=0; break; }
    done
    [ "$all_free" -eq 1 ] && { printf '%s' "$n"; return 0; }
    n=$((n + 1))
  done
  return 1
)

# ── .dev/offset 永続化（再起動で同じポートを再利用）──────────────
wt_persist_offset() (
  devdir=$1; off=$2
  mkdir -p "$devdir"
  printf '%s\n' "$off" > "$devdir/offset"
)
wt_read_offset() (
  devdir=$1
  [ -f "$devdir/offset" ] || return 0
  head -1 "$devdir/offset"
)

# ── 変数名から値を引く（名前を [A-Za-z0-9_] に限定した安全 lookup）────────
wt_lookup_var() (
  name=$1
  case "$name" in ''|*[!A-Za-z0-9_]*) return 0 ;; esac
  eval "printf '%s' \"\${$name-}\""
)

# ── env 式展開サンドボックス（§12.3）────────────────────────────
# `${VAR}` / `$VAR` / `$((算術))` のみを現在の環境で解決する。テンプレート全体を
# eval せず、コマンド置換 `$(...)` と backtick は loud-error で拒否する。算術は
# 算術コンテキスト `$(( ))`（コマンド実行不能）でのみ評価し、使用文字も allowlist で絞る。
wt_expand_value() (
  raw=$1
  case "$raw" in *'`'*) wt_die "式に backtick は使えません: $raw" ;; esac
  out=""; rest=$raw
  while [ -n "$rest" ]; do
    case "$rest" in
      '$(('*)
        inner=${rest#'$(('}
        case "$inner" in *'))'*) ;; *) wt_die "\$(( の閉じ )) がありません: $raw" ;; esac
        expr=${inner%%'))'*}; rest=${inner#*'))'}
        case "$expr" in *'$'*|*'`'*) wt_die "算術式に置換は使えません: $raw" ;; esac
        case "$expr" in *[!A-Za-z0-9_+*/%\ \(\)-]*) wt_die "算術式に使えない文字があります: $expr" ;; esac
        val=$(( expr ))
        out="$out$val"
        ;;
      '$('*)
        wt_die "式にコマンド置換 \$(...) は使えません: $raw"
        ;;
      '${'*)
        inner=${rest#'${'}
        case "$inner" in *'}'*) ;; *) wt_die "\${ の閉じ } がありません: $raw" ;; esac
        name=${inner%%'}'*}; rest=${inner#*'}'}
        case "$name" in ''|*[!A-Za-z0-9_]*) wt_die "変数名が不正です: \${$name}" ;; esac
        out="$out$(wt_lookup_var "$name")"
        ;;
      '$'*)
        after=${rest#'$'}
        case "$after" in
          [A-Za-z_]*)
            name=$(printf '%s' "$after" | sed 's/[^A-Za-z0-9_].*$//')
            rest=${after#"$name"}
            out="$out$(wt_lookup_var "$name")"
            ;;
          *) out="$out\$"; rest=$after ;;
        esac
        ;;
      *)
        chunk=${rest%%'$'*}
        if [ "$chunk" = "$rest" ]; then out="$out$rest"; rest=""
        else out="$out$chunk"; rest=${rest#"$chunk"}; fi
        ;;
    esac
  done
  printf '%s' "$out"
)
