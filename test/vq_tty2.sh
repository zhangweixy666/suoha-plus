#!/bin/bash
# 在真 tty 下直接调用（不重定向 stderr），验证 net_hint 的 \r 与 \033[K 确实发出
SRC="${1:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/suoha-manager.sh}"

extract() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) *\\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$SRC"
}

{
    for f in net_hint_begin net_hint_end xray_latest_version; do
        extract "$f"
        echo
    done
    echo 'echo "===BEGIN==="'
    echo 'R="$(xray_latest_version)"'
    echo 'echo "===END=== RESULT=[$R]"'
} > /tmp/vq2.sh

echo "===== 真 tty 下运行（stderr 不重定向）====="
script -q -c "bash /tmp/vq2.sh" /dev/null > /tmp/tty2.txt 2>&1

echo "--- 原始字节（od）---"
od -c /tmp/tty2.txt | head -20
echo
echo "--- 判定 ---"
if grep -q $'\033\[K' /tmp/tty2.txt; then
    echo "PASS: tty 下发出 \\033[K 清行序列"
else
    echo "FAIL: 未发出 \\033[K"
fi
if grep -q $'\r' /tmp/tty2.txt; then
    echo "PASS: tty 下发出 \\r"
else
    echo "FAIL: 未发出 \\r"
fi
if grep -q '正在查询 Xray 上游版本' /tmp/tty2.txt; then
    echo "PASS: 提示文字出现"
else
    echo "FAIL: 提示文字缺失"
fi