#!/bin/bash
# 验证：版本查询提示在 tty / 非 tty 下分别表现如何（含 net_hint_begin/end）
SRC="${1:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/suoha-manager.sh}"
PASS=0; FAIL=0
ok() { echo "ok  : $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

extract() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) *\\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$SRC"
}

cat > /tmp/vq.sh <<'INNER'
#!/bin/bash
SRC="${1:-$SUOHA_SRC}"
extract() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) *\\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$SRC"
}
for f in net_hint_begin net_hint_end gh_latest_tag xray_latest_version cloudflared_latest_version sq_latest_version; do
    eval "$(extract "$f")"
done
echo "XRAY=[$(xray_latest_version 2>/tmp/e1.txt)]"
echo "CF=[$(cloudflared_latest_version 2>/tmp/e2.txt)]"
echo "SQ=[$(sq_latest_version 2>/tmp/e3.txt)]"
INNER

echo "===== 1. 非 tty：三个查询都要成功且无 ESC ====="
export SUOHA_SRC="$SRC"; bash /tmp/vq.sh
for f in /tmp/e1.txt /tmp/e2.txt /tmp/e3.txt; do
    if grep -q $'\033' "$f" 2>/dev/null; then
        bad "$(basename $f) 含 ESC 控制字符"
    else
        ok "$(basename $f) 无 ESC"
    fi
done
echo "--- stderr 样例 ---"
head -3 /tmp/e1.txt

echo
echo "===== 2. 非 tty 下提示是完整一行（以换行结尾）====="
if [ -s /tmp/e1.txt ] && [ "$(tail -c1 /tmp/e1.txt | od -An -c | tr -d ' ')" = "\n" ]; then
    ok "提示以换行结尾（日志可读）"
else
    bad "提示未以换行结尾"
fi

echo
echo "===== 3. tty 下含 \\r 原地刷新 ====="
# 注意：必须让 stderr 直接落到 pty，不能在 \$(...) 里重定向到文件，
# 否则 net_hint 的输出会被吞掉，测不到。这里单独构造一个不重定向的脚本。
{
    for f in net_hint_begin net_hint_end xray_latest_version; do
        extract "$f"
        echo
    done
    echo 'R="$(xray_latest_version)"'
    echo 'echo "RESULT=[$R]"'
} > /tmp/vq_tty.sh
script -q -c "bash /tmp/vq_tty.sh" /dev/null > /tmp/tty_vq.txt 2>&1
if grep -q $'\r' /tmp/tty_vq.txt; then
    ok "tty 下有 \\r 刷新"
else
    bad "tty 下无 \\r"
fi
if grep -q $'\033\[K' /tmp/tty_vq.txt; then
    ok "tty 下有清行序列 \\033[K"
else
    bad "tty 下无清行序列"
fi
if grep -q '正在查询 Xray 上游版本' /tmp/tty_vq.txt; then
    ok "tty 下提示文字出现"
else
    bad "tty 下提示文字缺失"
fi

echo
echo "===== 4. 三个查询都返回了版本号（从第 1 节的非 tty 运行结果取）====="
export SUOHA_SRC="$SRC"; bash /tmp/vq.sh > /tmp/vq_result.txt 2>/dev/null
grep -E 'XRAY=|CF=|SQ=' /tmp/vq_result.txt | sed 's/^/  /'
if grep -qE 'XRAY=\[v[0-9]' /tmp/vq_result.txt; then ok "Xray 版本获取成功"; else bad "Xray 版本获取失败"; fi
if grep -qE 'CF=\[[0-9]{4}\.' /tmp/vq_result.txt; then ok "cloudflared 版本获取成功"; else bad "cloudflared 版本获取失败"; fi
if grep -qE 'SQ=\[v?[0-9]' /tmp/vq_result.txt; then ok "shadowquic 版本获取成功"; else bad "shadowquic 版本获取失败"; fi

echo
echo "==================================="
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1