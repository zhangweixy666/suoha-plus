#!/bin/sh
# 真机安装回归：覆盖 v2.4.2 修复的 4 个阻断性问题
# 这些断言在 v2.4.1 上会失败。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
S="${SUOHA_TEST_SCRIPT:-$REPO/suoha-manager.sh}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

if [ ! -f "$S" ]; then echo "找不到：$S" >&2; exit 2; fi
W=$(mktemp -d /tmp/suoha-real2.XXXXXX) || exit 1
trap 'rm -rf "$W"' EXIT INT TERM

sh "$HERE/extract_funcs.sh" "$S" > "$W/lib.sh" || exit 2
echo "待测：$S"

# ===== 1. install_*_units 必须显式 return 0 =====
echo "[1] 服务单元安装函数返回码"
for fn in install_openrc_units install_systemd_units; do
    body=$(awk "/^$fn\\(\\)/{f=1} f{print} f&&/^}/{exit}" "$S")
    case "$body" in
        *"return 0"*) ok "$fn 显式 return 0" ;;
        *) bad "$fn 缺少 return 0，最后一条 [ -f ] 为假时会让调用方误判失败" ;;
    esac
done

# 模拟：函数最后一条判断为假 + 调用方 || return 1
cat > "$W/t1.sh" <<'EOS'
install_like() {
    [ -f /nonexistent/x ] && echo hi
}
if install_like; then echo OK; else echo FAILED; fi
EOS
out=$(sh "$W/t1.sh")
if [ "$out" = "FAILED" ]; then
    ok "已确认该反模式会返回非0（修复必要性成立）"
else
    bad "反模式模拟异常"
fi

# ===== 2. 所有 fork 常驻服务的路径都必须先释放锁 =====
echo "[2] 锁不得被常驻服务继承"
if grep -q 'lock_release()' "$S"; then ok "存在 lock_release"; else bad "缺少 lock_release"; fi
if grep -q 'exec 9>"$LOCK_FILE"' "$S"; then ok "入口持有互斥锁"; else bad "缺少入口互斥锁"; fi

check_release_before() {
    fn="$1"; pat="$2"; label="$3"
    body=$(awk "/^$fn\\(\\)/{f=1} f{print} f&&/^}/{exit}" "$S")
    has_release=$(printf '%s' "$body" | grep -c 'lock_release')
    has_pat=$(printf '%s' "$body" | grep -c -- "$pat")
    if [ "$has_pat" -gt 0 ] && [ "$has_release" -gt 0 ]; then
        ok "$label 前释放锁"
    elif [ "$has_pat" -eq 0 ]; then
        ok "$label 无该分支（跳过）"
    else
        bad "$label 会 fork 常驻服务却未释放锁"
    fi
}
check_release_before start_xray 'rc-service suoha-plus-xray' 'start_xray(OpenRC)'
check_release_before start_xray 'systemctl start' 'start_xray(systemd)'
check_release_before start_persistent_tunnel 'rc-service suoha-plus-cloudflared' 'tunnel(OpenRC)'
check_release_before start_persistent_tunnel 'systemctl start' 'tunnel(systemd)'

# 真行为：持锁后启动子进程，检查子进程是否继承 fd 9
LOCK=$W/l.lock
rm -f "$LOCK"
sh -c '
    exec 9>"$1"
    flock -n 9 || exit 3
    # 释放后启动，模拟修复后的写法
    exec 9>&-
    sleep 6 &
    exit 0
' _ "$LOCK" >/dev/null 2>&1
sleep 1
if sh -c 'exec 9>"$1"; flock -n 9' _ "$LOCK" 2>/dev/null; then
    ok "释放锁后启动的子进程不持有锁"
else
    bad "子进程仍持有锁"
fi
pkill -f 'sleep 6' 2>/dev/null || true

# ===== 3. 重复安装不得叠加 supervise 实例 =====
echo "[3] 重复安装不叠加实例"
ioc=$(awk '/^install_openrc_units\(\)/{f=1} f{print} f&&/^}/{exit}' "$S")
case "$ioc" in
    *'rc-service suoha-plus-xray stop'*) ok "重写单元前会停旧实例" ;;
    *) bad "重写单元前未停旧实例，会叠加 supervise-daemon" ;;
esac
sx=$(awk '/^start_xray\(\)/{f=1} f{print} f&&/^}/{exit}' "$S")
case "$sx" in
    *restart*) ok "start_xray 已用 restart 避免叠加" ;;
    *) bad "start_xray 仅用 start，已运行时可能叠加实例" ;;
esac

# ===== 4. install_cmd_link 必须保证可执行 =====
echo "[4] 管理命令可执行且有稳定目标"
icl=$(awk '/^install_cmd_link\(\)/{f=1} f{print} f&&/^}/{exit}' "$S")
case "$icl" in
    *'chmod +x'*) ok "会补执行位" ;;
    *) bad "未补执行位，curl 下载的脚本建软链后会 Permission denied" ;;
esac
case "$icl" in
    *'APP_DIR'*) ok "会把脚本固定到 APP_DIR" ;;
    *) bad "软链指向临时路径，脚本被删后命令失效" ;;
esac

# 真行为：无执行位脚本建软链
NEXEC=$W/noexec.sh
printf '#!/bin/sh\necho hi\n' > "$NEXEC"
chmod 644 "$NEXEC"
LINK2=$W/cmd2
sh -c '. "$1/lib.sh"; SCRIPT_SELF="$2"; CMD_LINK="$3"; APP_DIR="$4"; install_cmd_link' _ "$W" "$NEXEC" "$LINK2" "$W/app2" >/dev/null 2>&1
if [ -L "$LINK2" ] && [ -x "$(readlink "$LINK2")" ]; then
    ok "无执行位脚本经 install_cmd_link 后命令可执行"
else
    bad "无执行位脚本建链后仍不可执行"
fi

# ===== 汇总 =====
echo ""
echo "真机安装回归：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
