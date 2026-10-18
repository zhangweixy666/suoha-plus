#!/bin/sh
# 节点输出与重装交互回归：覆盖用户报告的三个问题
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
S="${SUOHA_TEST_SCRIPT:-$REPO/suoha-manager.sh}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

[ -f "$S" ] || { echo "找不到：$S" >&2; exit 2; }
echo "待测：$S"

# ===== 1. 不得出现 base64 折行 =====
echo "[1] 节点链接不得折行"
if grep -q 'fold -w' "$S"; then
    bad "仍存在 fold -w，base64 会被换行污染，粘贴后乱码"
else
    ok "无 fold -w（base64 保持单行）"
fi

W=$(mktemp -d /tmp/suoha-node.XXXXXX) || exit 1
trap 'rm -rf "$W"' EXIT INT TERM
sh "$HERE/extract_funcs.sh" "$S" > "$W/lib.sh" || exit 2

# 真行为：生成一条 vmess 链接并验证是单行且可解码
out=$(sh -c '
. "$1/lib.sh"
json="{\"v\":\"2\",\"ps\":\"t\",\"add\":\"a.com\",\"port\":\"443\",\"id\":\"x-1\"}"
link="$(printf %s "$json" | base64_no_wrap)"
printf %s "$link"
' _ "$W" 2>/dev/null)

if [ -n "$out" ]; then
    lines=$(printf '%s' "$out" | wc -l)
    if [ "$lines" -eq 0 ]; then ok "base64 输出为单行（0 个换行）"; else bad "base64 含 $lines 个换行"; fi
    dec=$(printf '%s' "$out" | base64 -d 2>/dev/null)
    case "$dec" in
        *'"add":"a.com"'*) ok "base64 可正确解码" ;;
        *) bad "base64 解码失败：$dec" ;;
    esac
else
    bad "base64_no_wrap 无输出"
fi

# ===== 2. 重装必须有确认 =====
echo "[2] 重装覆盖确认"
if grep -q 'confirm_overwrite()' "$S"; then ok "存在 confirm_overwrite"; else bad "缺少 confirm_overwrite"; fi
for fn in setup_reality setup_quick setup_persistent; do
    body=$(awk "/^$fn\\(\\)/{f=1} f{print} f&&/^}/{exit}" "$S")
    case "$body" in
        *confirm_overwrite*) ok "$fn 有覆盖确认" ;;
        *) bad "$fn 无覆盖确认，会直接覆盖" ;;
    esac
done

# 真行为：已安装时 confirm_overwrite 在回答 n 时返回非0
mkdir -p "$W/app"
touch "$W/app/state.env"
res=$(printf 'n\n' | sh -c '
. "$1/lib.sh"
APP_DIR="$2"
STATE_FILE="$2/state.env"
SQ_APP_DIR="$2/no-sq"
say() { :; }
warn() { :; }
info() { :; }
safe_read() {
    local v="$1"; shift; printf %s "$*" >/dev/null
    IFS= read -r _a || _a=""
    eval "$v=\$_a"
}
if confirm_overwrite test; then echo YES; else echo NO; fi
' _ "$W" "$W/app" 2>/dev/null | tail -1)
if [ "$res" = "NO" ]; then ok "回答 n 时不会覆盖"; else bad "回答 n 仍然继续覆盖（得到 $res）"; fi

# 未安装时不应打扰
res2=$(sh -c '
. "$1/lib.sh"
APP_DIR="$2"
STATE_FILE="$2/none.env"
SQ_APP_DIR="$2/no-sq"
if confirm_overwrite test; then echo YES; else echo NO; fi
' _ "$W" "$W/app" 2>/dev/null | tail -1)
if [ "$res2" = "YES" ]; then ok "未安装时不询问直接继续"; else bad "未安装时被拦截"; fi

# ===== 3. pause_screen 不得吞输入 =====
echo "[3] 暂停提示"
if grep -q 'read -r _dummy' "$S"; then ok "pause_screen 用安全变量名"; else bad "pause_screen 仍用 read -r _"; fi

# ===== 汇总 =====
echo ""
echo "节点与重装回归：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
