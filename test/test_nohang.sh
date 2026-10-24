#!/bin/sh
# 防卡死回归测试：验证所有交互读取在 stdin 关闭时都不会挂死
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

# ===== 1. 源码层：不得保留裸 read -r -p =====
echo "[1] 源码不得有裸 read -r -p"
raw=$(grep -c 'read -r -p' "$S" 2>/dev/null | head -1)
if [ "$raw" = "0" ]; then
    ok "无裸 read -r -p（提示符不会被子 shell 吞掉）"
else
    bad "仍有 $raw 处裸 read -r -p，提示可能丢失"
fi

if grep -q 'safe_read()' "$S"; then ok "存在 safe_read"; else bad "缺少 safe_read"; fi

# safe_read 提示必须写 stderr
sbody=$(awk '/^safe_read\(\)/{f=1} f{print} f&&/^}/{exit}' "$S")
case "$sbody" in
    *'>&2'*) ok "提示输出到 stderr" ;;
    *) bad "提示未写 stderr" ;;
esac
case "$sbody" in
    *'read -r __answer'*|*'IFS= read -r'*) ok "用 read 带失败检查" ;;
    *) bad "read 未检查返回码，stdin 关闭时会卡或异常退出" ;;
esac

# ===== 2. 行为层：stdin 关闭时不挂死 =====
echo "[2] stdin 关闭时不挂死"
W=$(mktemp -d /tmp/suoha-hang.XXXXXX) || exit 1
trap 'rm -rf "$W"' EXIT INT TERM
sh "$HERE/extract_funcs.sh" "$S" > "$W/lib.sh" || exit 2

cat > "$W/t.sh" <<'EOS'
. "$1/lib.sh"
safe_read A 'p1 [d1]: ' 'd1'
safe_read B 'p2 [d2]: ' 'd2'
echo "A=$A B=$B"
EOS

out=$(timeout 8 sh "$W/t.sh" "$W" < /dev/null 2>/dev/null)
if [ -n "$out" ]; then
    ok "stdin 关闭时返回默认值（$out）"
else
    bad "stdin 关闭时无输出（可能卡死或异常退出）"
fi

# 有输入时应读到真实值
out2=$(printf 'x1\ny2\n' | timeout 8 sh "$W/t.sh" "$W" 2>/dev/null)
case "$out2" in
    *'A=x1'*'B=y2'*) ok "有输入时正确读取" ;;
    *) bad "有输入时读取异常：$out2" ;;
esac

# ===== 3. 整个脚本在 stdin 关闭时的表现 =====
echo "[3] 整脚本 stdin 关闭不挂死"
if timeout 20 sh -c "SUOHA_TTY=1 bash '$S' < /dev/null > /dev/null 2>&1"; then
    ok "整脚本在 stdin 关闭时正常退出"
else
    rc=$?
    if [ "$rc" = "124" ]; then
        bad "整脚本超时（卡死）"
    else
        ok "整脚本退出码 $rc（未超时）"
    fi
fi

# ===== 4. 下载必须有耗时/超时反馈 =====
echo "[4] 下载耗时反馈"
for pat in '最长等' '下载完成：'; do
    if grep -q "$pat" "$S"; then ok "含「$pat」提示"; else bad "缺少「$pat」提示"; fi
done

# ===== 汇总 =====
echo ""
echo "防卡死回归：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
