#!/bin/sh
# 卸载沙箱：验证服务单元/守护脚本的清理逻辑不误伤、不残留
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
S="${SUOHA_TEST_SCRIPT:-$REPO/suoha-manager.sh}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

W=$(mktemp -d /tmp/suoha-uni.XXXXXX) || exit 1
trap 'rm -rf "$W"' EXIT INT TERM

if [ ! -f "$S" ]; then
    echo "找不到待测脚本：$S" >&2
    exit 2
fi

echo "待测：$S"
echo "沙箱：$W"

# ---------- 1. service_unit_exists 能识别各类型单元 ----------
echo "[1] service_unit_exists 识别能力"
mkdir -p "$W/sysd" "$W/initd"
touch "$W/sysd/foo.service"
touch "$W/initd/bar"

# 用 sed 将 /etc/systemd/system 与 /etc/init.d 重定向到沙箱
sed -e "s#/etc/systemd/system#$W/sysd#g" -e "s#/etc/init.d#$W/initd#g" "$S" > "$W/patched.sh"
sh "$HERE/extract_funcs.sh" "$W/patched.sh" > "$W/lib.sh" || { echo "函数提取失败" >&2; exit 2; }

got=$(sh -c '. "$1/lib.sh"; service_unit_exists "foo.service"' _ "$W" 2>/dev/null; echo "rc=$?")
case "$got" in *rc=0*) ok "识别 systemd 单元" ;; *) bad "未识别 systemd 单元：'$got'" ;; esac

got=$(sh -c '. "$1/lib.sh"; service_unit_exists "bar.service"' _ "$W" 2>/dev/null; echo "rc=$?")
case "$got" in *rc=0*) ok "识别 OpenRC 单元（.service 后缀映射到 /etc/init.d）" ;; *) bad "未识别 OpenRC 单元：'$got'" ;; esac

got=$(sh -c '. "$1/lib.sh"; service_unit_exists "baz.service"' _ "$W" 2>/dev/null; echo "rc=$?")
case "$got" in *rc=1*) ok "不存在的单元返回非0" ;; *) bad "不存在单元应返回非0：'$got'" ;; esac

# ---------- 2. remove_systemd_units 清理完整 ----------
echo "[2] remove_systemd_units 清理范围"
for pat in '/etc/systemd/system/$SERVICE_XRAY' \
           '/etc/systemd/system/$SERVICE_CF' \
           '/etc/init.d/suoha-plus-xray' \
           '/etc/init.d/suoha-plus-cloudflared' \
           'suoha-xray-daemon.sh' \
           'suoha-cloudflared-daemon.sh' \
           'rc-update del suoha-plus-xray' \
           'rc-update del suoha-plus-cloudflared'; do
    if grep -qF -- "$pat" "$S"; then ok "清理含 $pat"; else bad "清理缺少 $pat"; fi
done

# ---------- 3. uninstall_component 删组件时清理 daemon wrapper ----------
echo "[3] uninstall_component 残留检查"
if awk '/^uninstall_component\(\)/{f=1} f{print} /^}/&&f{f=0}' "$S" | grep -qF 'suoha-xray-daemon.sh'; then
    ok "单删 Xray 会清理 daemon wrapper"
else
    bad "单删 Xray 未清理 /usr/local/bin/suoha-xray-daemon.sh（残留）"
fi
if awk '/^uninstall_component\(\)/{f=1} f{print} /^}/&&f{f=0}' "$S" | grep -qF 'suoha-cloudflared-daemon.sh'; then
    ok "单删 Tunnel 会清理 daemon wrapper"
else
    bad "单删 Tunnel 未清理 /usr/local/bin/suoha-cloudflared-daemon.sh（残留）"
fi

# ---------- 4. 卸载不误删外部文件 ----------
echo "[4] 卸载不误伤外部资源"
if grep -qF 'rm -rf /root/.cloudflared' "$S"; then
    bad "仍存在删除整个 /root/.cloudflared 的操作"
else
    ok "不会删除 /root/.cloudflared 整个目录"
fi
if grep -qF '/opt/suoha' "$S" && grep -qF '不会删除原 suoha.sh' "$S"; then
    ok "明确保护原 suoha.sh"
else
    bad "未明确保护原 suoha.sh"
fi
if ! grep -qF 'rm -rf /etc/shadowquic' "$S"; then
    ok "不删除整个 /etc/shadowquic 目录"
else
    bad "存在删除 /etc/shadowquic 整个目录的操作"
fi

# ---------- 5. 卸载后状态文件清理 ----------
echo "[5] 完全卸载清理"
if awk '/^uninstall_plus\(\)/{f=1} f{print} /^}/&&f{f=0}' "$S" | grep -qF 'rm -rf "$APP_DIR"'; then
    ok "完全卸载清理 APP_DIR"
else
    bad "完全卸载未清理 APP_DIR"
fi
if awk '/^uninstall_plus\(\)/{f=1} f{print} /^}/&&f{f=0}' "$S" | grep -qF 'remove_systemd_units'; then
    ok "完全卸载调用 remove_systemd_units"
else
    bad "完全卸载未调用 remove_systemd_units"
fi
if awk '/^uninstall_plus\(\)/{f=1} f{print} /^}/&&f{f=0}' "$S" | grep -qF 'rm -f "$CMD_LINK"'; then
    ok "完全卸载清理管理命令软链"
else
    bad "完全卸载未清理 CMD_LINK"
fi

# ---------- 6. ShadowQuic 归属保护真实行为 ----------
echo "[6] ShadowQuic 归属保护"
SQD=$W/sq
mkdir -p "$SQD"
# 造一个 warp- 归属的目录
touch "$SQD/.managed-by-warp-go"
echo 'external' > "$SQD/server-direct.yaml"

out=$(sh -c '. "$1/lib.sh"; SQ_APP_DIR="$2"; sq_owned' _ "$W" "$SQD" 2>/dev/null; echo "rc=$?")
case "$out" in *rc=1*) ok "有 warp- 标记时 sq_owned 返回非0（不归我管）" ;; *) bad "有 warp- 标记却判定为自己所有：'$out'" ;; esac

out=$(sh -c '. "$1/lib.sh"; SQ_APP_DIR="$2"; sq_foreign_owner' _ "$W" "$SQD" 2>/dev/null)
if [ "$out" = "warp-" ]; then ok "正确识别 warp- 为外部归属"; else bad "未识别 warp- 归属"; fi

# 自己的标记
touch "$SQD/.managed-by-suoha-plus"
out=$(sh -c '. "$1/lib.sh"; SQ_APP_DIR="$2"; sq_owned' _ "$W" "$SQD" 2>/dev/null; echo "rc=$?")
case "$out" in *rc=0*) ok "有自己标记时 sq_owned 返回 0" ;; *) bad "有自己标记却判定不归自己：'$out'" ;; esac

# 空目录应可接管
EMPTY=$W/sqempty; mkdir -p "$EMPTY"
out=$(sh -c '. "$1/lib.sh"; SQ_APP_DIR="$2"; sq_owned' _ "$W" "$EMPTY" 2>/dev/null; echo "rc=$?")
case "$out" in *rc=0*) ok "空目录可接管" ;; *) bad "空目录应可接管：'$out'" ;; esac

# ---------- 汇总 ----------
echo ""
echo "卸载沙箱：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
