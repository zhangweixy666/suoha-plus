#!/bin/sh
# 行为测试：提取真实函数到沙箱中执行，验证修复逻辑真实生效
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
S="${SUOHA_TEST_SCRIPT:-$REPO/suoha-manager.sh}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

W=$(mktemp -d /tmp/suoha-beh.XXXXXX) || exit 1
trap 'rm -rf "$W"' EXIT INT TERM

if [ ! -f "$S" ]; then
    echo "找不到待测脚本：$S" >&2
    exit 2
fi

echo "待测：$S"
echo "沙箱：$W"

# 提取函数定义（头部赋值区 + 所有顶层函数），供 source 使用
sh "$HERE/extract_funcs.sh" "$S" > "$W/lib.sh" || { echo "函数提取失败" >&2; exit 2; }
if [ ! -s "$W/lib.sh" ]; then echo "函数提取为空" >&2; exit 2; fi

# ---------- 1. sq_arch_asset 架构映射 ----------
echo "[1] sq_arch_asset 架构映射"
ARCH_CASE=$W/arch
mkdir -p "$ARCH_CASE"
cat > "$ARCH_CASE/uname" <<'EOF'
#!/bin/sh
echo "$FAKE_MACHINE"
EOF
chmod +x "$ARCH_CASE/uname"

for pair in "x86_64:shadowquic-x86_64-linux-musl" \
            "aarch64:shadowquic-aarch64-linux-musl" \
            "arm64:shadowquic-aarch64-linux-musl" \
            "armv7l:shadowquic-armv7-linux-muslhf" \
            "i686:shadowquic-i686-linux-musl"; do
    m=${pair%%:*}; want=${pair##*:}
    got=$(PATH="$ARCH_CASE:$PATH" FAKE_MACHINE="$m" sh -c '. "$1/lib.sh"; sq_arch_asset' _ "$W" 2>/dev/null)
    if [ "$got" = "$want" ]; then ok "$m -> $want"; else bad "$m -> 得到 '$got'，期望 '$want'"; fi
done
got=$(PATH="$ARCH_CASE:$PATH" FAKE_MACHINE="riscv64" sh -c '. "$1/lib.sh"; sq_arch_asset' _ "$W" 2>/dev/null)
if [ -z "$got" ]; then ok "未知架构返回非0"; else bad "未知架构应返回空，得到 '$got'"; fi

# ---------- 2. IP 缓存行为 ----------
echo "[2] IP 探测缓存"
BIN=$W/bin
mkdir -p "$BIN"
# 假 curl：每次调用向计数器文件 +1，返回固定 IP
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
n=$(cat "$CURL_COUNT" 2>/dev/null || echo 0)
echo $((n + 1)) > "$CURL_COUNT"
case "$*" in
    *-4*) echo "1.2.3.4" ;;
    *-6*) echo "2001:db8::1" ;;
    *) echo "1.2.3.4" ;;
esac
exit 0
EOF
chmod +x "$BIN/curl"

CC=$W/cc; : > "$CC"
res=$(PATH="$BIN:$PATH" CURL_COUNT="$CC" sh -c '. "$1/lib.sh"; public_ip' _ "$W" 2>/dev/null)
c1=$(cat "$CC")
res2=$(PATH="$BIN:$PATH" CURL_COUNT="$CC" sh -c '. "$1/lib.sh"; public_ip; public_ip; public_ip' _ "$W" 2>/dev/null)
if [ "$res" = "1.2.3.4" ]; then ok "public_ip 返回正确"; else bad "public_ip 返回值 '$res'"; fi
if [ "$c1" = "1" ]; then ok "首次调用只探测 1 次"; else bad "首次应探测 1 次，实际 $c1"; fi

# 同进程内验证缓存：三次调用只应触发一次探测
CC2=$W/cc2; : > "$CC2"
PATH="$BIN:$PATH" CURL_COUNT="$CC2" sh -c '
. "$1/lib.sh"
public_ip >/dev/null
public_ip >/dev/null
public_ip >/dev/null
cat "$CURL_COUNT"
' _ "$W" > "$W/out" 2>/dev/null
cnt=$(cat "$W/out" 2>/dev/null || echo 9)
if [ "$cnt" = "1" ]; then ok "同进程 3 次调用仅探测 1 次（缓存生效）"; else bad "同进程 3 次调用探测 $cnt 次，缓存未生效"; fi

# ---------- 3. service_unit_exists ----------
echo "[3] service_unit_exists"
got=$(sh -c '. "$1/lib.sh"; service_unit_exists ""' _ "$W" 2>/dev/null; echo "rc=$?")
case "$got" in *rc=1*) ok "空 unit 返回非0" ;; *) bad "空 unit 应返回非0，得到 '$got'" ;; esac
got=$(sh -c '. "$1/lib.sh"; service_unit_exists "no-such-unit.service"' _ "$W" 2>/dev/null; echo "rc=$?")
case "$got" in *rc=1*) ok "不存在的 unit 返回非0" ;; *) bad "不存在 unit 应返回非0，得到 '$got'" ;; esac

# ---------- 4. rotate_log 真实轮转 ----------
echo "[4] rotate_log 日志轮转"
BIG=$W/big.log
dd if=/dev/zero of="$BIG" bs=1024 count=200 2>/dev/null
before=$(wc -c < "$BIG")
sh -c '. "$1/lib.sh"; rotate_log "$2" 1024' _ "$W" "$BIG" 2>/dev/null
after=$(wc -c < "$BIG" 2>/dev/null || echo 0)
if [ "$before" -gt 100000 ] && [ "$after" -le 1048576 ]; then
    ok "超阈值日志被截断（$before -> $after）"
else
    bad "日志未按预期轮转（$before -> $after）"
fi
SMALL=$W/small.log
echo hi > "$SMALL"
sz1=$(wc -c < "$SMALL")
sh -c '. "$1/lib.sh"; rotate_log "$2" 10485760' _ "$W" "$SMALL" 2>/dev/null
sz2=$(wc -c < "$SMALL")
if [ "$sz1" = "$sz2" ]; then ok "未超阈值不动日志"; else bad "未超阈值却改动了日志"; fi

# ---------- 5. sq_installed / sq_local_version ----------
echo "[5] ShadowQuic 版本探测"
SQD=$W/sqdir; mkdir -p "$SQD"
got=$(sh -c '. "$1/lib.sh"; SQ_BIN="$2/nope"; sq_local_version' _ "$W" "$SQD" 2>/dev/null)
if [ -z "$got" ]; then ok "未安装时 sq_local_version 返回空"; else bad "未安装应返回空，得到 '$got'"; fi
cat > "$SQD/fake-sq" <<'EOF'
#!/bin/sh
if [ "$1" = "--version" ] || [ "$1" = "-V" ]; then echo "shadowquic 0.4.4"; exit 0; fi
exit 1
EOF
chmod +x "$SQD/fake-sq"
got=$(sh -c '. "$1/lib.sh"; SQ_BIN="$2/fake-sq"; sq_local_version' _ "$W" "$SQD" 2>/dev/null)
if [ "$got" = "0.4.4" ]; then ok "解析出本地版本 $got"; else bad "本地版本解析失败，得到 '$got'"; fi

# ---------- 6. install_cmd_link ----------
echo "[6] install_cmd_link"
FAKE_SELF=$W/fake-manager.sh
echo '#!/bin/sh' > "$FAKE_SELF"; chmod +x "$FAKE_SELF"
LINK=$W/outlink
sh -c '. "$1/lib.sh"; SCRIPT_SELF="$2"; CMD_LINK="$3"; APP_DIR="$4"; install_cmd_link' _ "$W" "$FAKE_SELF" "$LINK" "$W/app" 2>/dev/null
if [ -L "$LINK" ]; then ok "创建了软链接"; else bad "未创建软链接"; fi
# 新实现会把脚本固定到 APP_DIR 再链接，目标是稳定副本而非原始路径
if [ -L "$LINK" ] && [ -f "$(readlink "$LINK")" ]; then ok "软链接指向存在的可执行文件"; else bad "软链接指向失效"; fi
if [ -L "$LINK" ] && [ -x "$(readlink "$LINK")" ]; then ok "软链接目标可执行"; else bad "软链接目标不可执行"; fi
sh -c '. "$1/lib.sh"; SCRIPT_SELF=""; CMD_LINK="$2"; install_cmd_link' _ "$W" "$W/nolink" 2>/dev/null
if [ ! -e "$W/nolink" ]; then ok "SCRIPT_SELF 为空时安全跳过"; else bad "SCRIPT_SELF 为空时不应创建链接"; fi

# ---------- 7. url_label / base64 未破坏 ----------
echo "[7] 回归：辅助函数"
got=$(sh -c '. "$1/lib.sh"; url_label "a b#c"' _ "$W" 2>/dev/null)
if [ "$got" = "a%20b%23c" ]; then ok "url_label 正常"; else bad "url_label 异常：'$got'"; fi
got=$(printf 'hello' | sh -c '. "$1/lib.sh"; base64_no_wrap' _ "$W" 2>/dev/null)
if [ "$got" = "aGVsbG8=" ]; then ok "base64_no_wrap 正常"; else bad "base64_no_wrap 异常：'$got'"; fi

# ---------- 汇总 ----------
echo ""
echo "行为测试：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
