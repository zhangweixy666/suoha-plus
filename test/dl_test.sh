#!/bin/bash
# 抽取下载交互相关函数并真实执行，验证确认逻辑与进度渲染。
# 不安装任何东西、不碰系统目录；只写 /tmp。

SRC="${1:-/sdcard/Download/suoha-plus/suoha-manager.sh}"
WORK="$(mktemp -d /tmp/dltest.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }
pass() { printf 'ok  : %s\n' "$*"; PASS=$((PASS + 1)); }

# ---- 抽取函数：从源文件里按函数名截取，避免 source 整个脚本（会进主菜单）----
extract() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) *\\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$SRC"
}

# 依赖的最小桩
info() { printf '[信息] %s\n' "$*" >&2; }
ok()   { printf '[完成] %s\n' "$*" >&2; }
err()  { printf '[错误] %s\n' "$*" >&2; }
say()  { printf '%b\n' "$*"; }
C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""

safe_read() {
    local __var="$1" __prompt="$2" __default="$3" __answer
    printf '%s' "$__prompt" >&2
    __answer=""
    if ! IFS= read -r __answer; then
        eval "$__var=\$__default"
        return 0
    fi
    [ -n "$__answer" ] || __answer="$__default"
    eval "$__var=\$__answer"
    return 0
}

for f in human_bytes confirm_download dl_remote_size dl_render dl_run; do
    body="$(extract "$f")"
    if [ -z "$body" ]; then
        fail "无法从源文件抽取函数 $f"
        continue
    fi
    eval "$body"
done

echo "=== 1. human_bytes ==="
if [ "$(human_bytes 0)" = "0B" ] && [ "$(human_bytes 1023)" = "1023B" ] \
   && [ "$(human_bytes 1024)" = "1K" ] && [ "$(human_bytes 1536)" = "1K" ] \
   && [ "$(human_bytes 1048576)" = "1.0M" ] && [ "$(human_bytes 1572864)" = "1.5M" ] \
   && [ "$(human_bytes 1073741824)" = "1.00G" ]; then
    pass "human_bytes 单位换算"
else
    fail "human_bytes: 0=$(human_bytes 0) 1023=$(human_bytes 1023) 1048576=$(human_bytes 1048576) 1572864=$(human_bytes 1572864)"
fi
# 非法输入必须回落 0 而不是崩
if [ "$(human_bytes "abc")" = "0B" ] && [ "$(human_bytes "")" = "0B" ]; then
    pass "human_bytes 非法输入回落"
else
    fail "human_bytes 非法输入: abc=$(human_bytes abc) empty=$(human_bytes '')"
fi

echo
echo "=== 2. confirm_download：默认 N，回车不下载 ==="
printf '' | confirm_download "测试内容" "测试说明" "/tmp/x" >/dev/null 2>&1
if [ $? -eq 1 ]; then pass "空输入(EOF) → 取消"; else fail "空输入未取消"; fi

printf '\n' | confirm_download "测试内容" "测试说明" "/tmp/x" >/dev/null 2>&1
if [ $? -eq 1 ]; then pass "回车 → 取消（默认 N）"; else fail "回车未取消"; fi

printf 'n\n' | confirm_download "测试内容" "测试说明" "/tmp/x" >/dev/null 2>&1
if [ $? -eq 1 ]; then pass "输入 n → 取消"; else fail "n 未取消"; fi

printf 'no\n' | confirm_download "测试内容" "测试说明" "/tmp/x" >/dev/null 2>&1
if [ $? -eq 1 ]; then pass "输入 no → 取消"; else fail "no 未取消"; fi

printf 'x\n' | confirm_download "测试内容" "测试说明" "/tmp/x" >/dev/null 2>&1
if [ $? -eq 1 ]; then pass "输入乱字符 → 取消"; else fail "乱字符未取消"; fi

for v in y Y yes YES; do
    printf '%s\n' "$v" | confirm_download "测试内容" "测试说明" "/tmp/x" >/dev/null 2>&1
    if [ $? -eq 0 ]; then pass "输入 $v → 确认"; else fail "$v 未确认"; fi
done

echo
echo "=== 3. SUOHA_ASSUME_YES 跳过确认 ==="
printf '' | SUOHA_ASSUME_YES=1 confirm_download "x" "y" "/tmp/x" >/dev/null 2>&1
if [ $? -eq 0 ]; then pass "SUOHA_ASSUME_YES=1 无需输入即通过"; else fail "SUOHA_ASSUME_YES 未生效"; fi

echo
echo "=== 4. dl_remote_size 取远端大小 ==="
SZ="$(dl_remote_size "https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/README.md")"
if [ "$SZ" -gt 1000 ] 2>/dev/null; then
    pass "README 远端大小 = $SZ 字节（$(human_bytes "$SZ")）"
else
    fail "dl_remote_size 返回异常：'$SZ'"
fi
SZ404="$(dl_remote_size "https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/__nope__.md")"
if [ "$SZ404" = "0" ]; then pass "404 时返回 0"; else fail "404 时返回 '$SZ404'，应为 0"; fi

echo
echo "=== 5. dl_run 真实下载（非 tty 模式）==="
DEST="$WORK/readme.md"
dl_run "README" "https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/README.md" "$DEST" 60
RC=$?
ACT="$(wc -c < "$DEST" 2>/dev/null | tr -d ' ')"
if [ "$RC" -eq 0 ] && [ -n "$ACT" ] && [ "$ACT" -gt 1000 ]; then
    pass "下载成功，落盘 $ACT 字节，与远端 $SZ 一致=$([ "$ACT" = "$SZ" ] && echo 是 || echo 否)"
else
    fail "dl_run 失败 rc=$RC size=$ACT"
fi

echo
echo "=== 6. dl_run 错误路径：404 必须失败且清理文件 ==="
DEST2="$WORK/nope.bin"
dl_run "404测试" "https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/__nope__.bin" "$DEST2" 30
RC2=$?
if [ "$RC2" -ne 0 ]; then pass "404 返回非 0（rc=$RC2）"; else fail "404 竟然返回 0"; fi
if [ ! -f "$DEST2" ]; then pass "失败后残留文件已清理"; else fail "失败后残留 $DEST2"; fi
if [ ! -f "$DEST2.curlerr" ]; then pass "临时错误文件已清理"; else fail "残留 $DEST2.curlerr"; fi

echo
echo "=== 7. dl_run 错误路径：域名不存在 ==="
DEST3="$WORK/bad.bin"
dl_run "坏域名" "https://this-domain-does-not-exist-xyz.invalid/a.bin" "$DEST3" 20
RC3=$?
if [ "$RC3" -ne 0 ]; then pass "坏域名返回非 0（rc=$RC3）"; else fail "坏域名返回 0"; fi
if [ ! -f "$DEST3" ]; then pass "坏域名未留下空文件"; else fail "坏域名残留文件"; fi

echo
echo "=== 8. dl_render 输出格式（强制 tty=1）==="
OUT="$(dl_render "Xray" 5242880 10485760 "$(( $(date +%s) - 2 ))" 1 2>&1)"
# 去掉 \r 便于断言
CLEAN="$(printf '%s' "$OUT" | tr '\r' '\n' | tail -n 1)"
echo "  渲染样例: $CLEAN"
case "$CLEAN" in
    *"50%"*) pass "百分比正确（5M/10M = 50%）" ;;
    *) fail "百分比未出现 50%: $CLEAN" ;;
esac
case "$CLEAN" in
    *"5.0M/10.0M"*) pass "大小显示正确" ;;
    *) fail "大小显示异常: $CLEAN" ;;
esac
case "$CLEAN" in
    *"剩余"*) pass "含剩余时间" ;;
    *) fail "缺少剩余时间: $CLEAN" ;;
esac
case "$CLEAN" in
    *"#"*"20"*) ;;
esac

echo "  未知总大小样例: $(dl_render "SQ" 3000000 0 "$(( $(date +%s) - 3 ))" 1 2>&1 | tr '\r' '\n' | tail -n1)"

echo
echo "=== 9. 幂等：dl_run 对已存在文件应覆盖而非追加 ==="
echo "GARBAGE_OLD_CONTENT_XYZ" > "$WORK/over.md"
dl_run "覆盖测试" "https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/README.md" "$WORK/over.md" 60 >/dev/null 2>&1
if ! grep -q "GARBAGE_OLD_CONTENT_XYZ" "$WORK/over.md" 2>/dev/null; then
    pass "旧内容被覆盖（未追加）"
else
    fail "旧内容残留 → 文件是追加而非覆盖"
fi

echo
echo "==================================="
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
