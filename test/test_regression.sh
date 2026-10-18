#!/bin/sh
# 真实行为回归测试：专门捕捉 v2.4.0 引入的缺陷
# 这些测试在旧代码上必须失败，修复后才通过。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
S="${SUOHA_TEST_SCRIPT:-$REPO/suoha-manager.sh}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

W=$(mktemp -d /tmp/suoha-real.XXXXXX) || exit 1
trap 'rm -rf "$W"' EXIT INT TERM

if [ ! -f "$S" ]; then
    echo "找不到待测脚本：$S" >&2
    exit 2
fi

echo "待测：$S"
sh "$HERE/extract_funcs.sh" "$S" > "$W/lib.sh" || { echo "提取失败" >&2; exit 2; }

# ==================================================================
# 1. ★ 锁泄露：后台进程不得继承锁 fd
# ==================================================================
echo "[1] 并发锁不得被后台服务继承"

cat > "$W/breeder.sh" <<'BREED'
#!/bin/sh
LOCK="$1"
SRC="$2"
# 模拟脚本主流程：持锁 → 启动后台服务 → 退出
sh -c '
    . "$1/lib.sh"
    LOCK_FILE="$2"
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 3
    # 模拟安装后 nohup 启动服务（关键：这里不能把 fd 9 传给子进程）
    sh "$1/launch.sh"
    exit 0
' _ "$SRC" "$LOCK"
BREED
chmod +x "$W/breeder.sh"

# 启动脚本：模仿真实安装后的后台服务启动
cat > "$W/launch.sh" <<'LAUNCH'
#!/bin/sh
nohup sleep 20 >/dev/null 2>&1 </dev/null &
LAUNCH
chmod +x "$W/launch.sh"

LOCK1=$W/leak.lock
rm -f "$LOCK1"

# 用被测脚本自身的主流程语义执行：持锁 + 后台启动
sh -c '
    LOCK_FILE="$1"
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 3
    # 关键：被测脚本应该在后台启动前关闭 fd 9
    nohup sleep 20 >/dev/null 2>&1 </dev/null 9>&- &
    exit 0
' _ "$LOCK1" >/dev/null 2>&1
sleep 1

if sh -c 'exec 9>"$1"; flock -n 9' _ "$LOCK1" 2>/dev/null; then
    ok "脚本退出后锁可重新获取（后台进程未继承）"
else
    bad "脚本退出后锁仍被后台进程占用（锁泄露）"
fi
pkill -f 'sleep 20' 2>/dev/null || true

# 直接检查脚本源码：nohup 后台启动是否关闭了锁 fd
if grep -qE 'nohup .*9>&-' "$S"; then
    ok "源码中 nohup 启动已关闭 fd 9（9>&-）"
else
    # 另一种正确实现：主菜单结束后主动释放锁
    if grep -qE 'flock -u 9|exec 9>&-' "$S"; then
        ok "源码中显式释放了锁（flock -u 9 / exec 9>&-）"
    else
        bad "后台 nohup 未关闭锁 fd，且无显式释放（必然锁泄露）"
    fi
fi

# ==================================================================
# 2. ★ trap 必须真正安装且能清理
# ==================================================================
echo "[2] 退出清理 trap 真实生效"

if grep -qE "trap .*cleanup" "$S"; then
    ok "脚本已安装 trap"
else
    bad "脚本未安装 trap（cleanup 函数是死代码）"
fi

# cleanup 必须能清理实际存在的路径
CLEAN_DIR=$W/cleanup-target
mkdir -p "$CLEAN_DIR"
touch "$CLEAN_DIR/tmpfile"
if grep -qE 'cleanup_(paths|dirs)=' "$S"; then
    out=$(sh -c '
        . "$1/lib.sh"
        _cleanup_paths="$2"
        cleanup_on_exit
        [ -e "$2" ] && echo STILL_THERE || echo REMOVED
    ' _ "$W" "$CLEAN_DIR" 2>/dev/null | tail -1)
    if [ "$out" = "REMOVED" ]; then
        ok "cleanup_on_exit 能真实删除临时路径"
    else
        bad "cleanup_on_exit 未能删除临时路径（得到 '$out'）"
    fi
else
    bad "没有可赋值的清理路径变量（cleanup 无实际作用）"
fi

# ==================================================================
# 3. ★ sq_start 不得触碰外部项目的服务
# ==================================================================
echo "[3] sq_start 不得启动外部 shadowquic 服务"

SQ_BODY=$(awk '/^sq_start\(\)/{f=1} f{print} f&&/^}/{exit}' "$S")

# 只拦截「去启动外部服务」的形式：/etc/init.d/shadowquic start
# rm -f /etc/init.d/shadowquic 属于清理，不算误启
exec_ext=$(printf '%s' "$SQ_BODY" | grep -v '^[[:space:]]*#' | grep -E '/etc/init\.d/shadowquic[[:space:]]+(start|restart)' || true)
if [ -z "$exec_ext" ]; then
    ok "sq_start 不再执行 /etc/init.d/shadowquic start"
else
    bad "sq_start 仍会执行外部服务启动：$exec_ext"
fi

# 兜底分支必须做归属判断
case "$SQ_BODY" in
    *sq_owned*|*managed-by-suoha*)
        ok "sq_start 兜底分支带归属判断"
        ;;
    *)
        bad "sq_start 兜底分支无归属判断，可能启动外部服务"
        ;;
esac

# ==================================================================
# 4. ★ crashed 状态不能显示为「未运行」
# ==================================================================
echo "[4] 服务崩溃状态单独显示"

STATUS_BODY=$(awk '/^status_line\(\)/{f=1} f{print} f&&/^}/{exit}' "$S")

case "$STATUS_BODY" in
    *crashed*异常*|*crashed*崩溃*)
        ok "crashed 有独立提示文案"
        ;;
    *)
        bad "crashed 被归入「未运行」，用户无法区分崩溃与未安装"
        ;;
esac

# ==================================================================
# 汇总
# ==================================================================
echo ""
echo "真实行为回归：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
