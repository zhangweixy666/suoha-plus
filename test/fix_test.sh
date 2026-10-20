#!/bin/bash
# v2.6.0 修复的行为测试：抽真实函数在沙箱执行，不安装、不碰系统目录。
# 覆盖：Reality 地址生效 / 校验白名单 / 健康检测判定 / Quick 提示 / 版本基址重算。

SRC="${1:-/sdcard/Download/suoha-plus/suoha-manager.sh}"
WORK="$(mktemp -d /tmp/fixtest.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
pass() { printf 'ok  : %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

extract() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) *\\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$SRC"
}

# ---- 最小桩 ----
info() { :; }; ok() { :; }; warn() { :; }; err() { printf '[错误] %s\n' "$*" >&2; }
say() { printf '%b\n' "$*"; }
C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
url_label() { printf '%s' "${1:-SuohaPlus}"; }
base64_no_wrap() { base64 -w 0 2>/dev/null || base64 | tr -d '\n'; }
public_ip() { printf '203.0.113.10'; }
public_ip6() { printf '2001:db8::99'; }
# generate_nodes 依赖它取隧道域名；本测试聚焦 Reality，故给空值（等同于无隧道）。
current_tunnel_host() { printf '%s' "${QUICK_URL:-}"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

for f in validate_reality validate_common generate_nodes; do
    body="$(extract "$f")"
    [ -n "$body" ] || { fail "无法抽取 $f"; exit 1; }
    eval "$body"
done

APP_DIR="$WORK/app"; mkdir -p "$APP_DIR"
NODE_FILE="$APP_DIR/v2ray.txt"
XRAY_VERSION="v26.3.27"; CLOUDFLARED_VERSION="2026.8.2"
UUID="11111111-2222-4333-8444-555555555555"
WS_PATH="/abcd1234"
XRAY_PORT="12345"
ISP_TAG="SuohaPlus"
MODE="reality"; PROTOCOL="vless"; EDGE_IP="4"; CF_PROTOCOL="http2"
REALITY_ENABLED="yes"; REALITY_PORT="8443"
REALITY_DEST="www.apple.com"; REALITY_SNI="www.apple.com"
REALITY_PRIVATE="PRIVkey_abc-123"; REALITY_PUBLIC="PUBkey_xyz-789"
REALITY_SHORT_ID="a1b2c3d4"
NODE_ADDRESS=""
QUICK_URL=""; DOMAIN=""

echo "=== 1. validate_reality 正常路径 ==="
if validate_reality && [ "$REALITY_DEST" = "www.apple.com:443" ]; then
    pass "dest 自动补 :443"
else
    fail "dest 未补端口：$REALITY_DEST"
fi

echo
echo "=== 2. validate_reality 拒绝 JSON 注入 ==="
REALITY_DEST='www.apple.com", "evil": "1'
if ! validate_reality 2>/dev/null; then pass "拒绝 dest 含引号（JSON 注入）"; else fail "未能拦住 dest 注入"; fi
REALITY_DEST='www.apple.com:443'
REALITY_SNI='a.com", "x":"y'
if ! validate_reality 2>/dev/null; then pass "拒绝 SNI 含引号"; else fail "未能拦住 SNI 注入"; fi
REALITY_SNI='www.apple.com'
REALITY_DEST='www.apple.com:abc'
if ! validate_reality 2>/dev/null; then pass "拒绝非数字端口"; else fail "未能拦住 dest 端口 abc"; fi
REALITY_DEST='www.apple.com:70000'
if ! validate_reality 2>/dev/null; then pass "拒绝端口 70000"; else fail "未能拦住端口 70000"; fi
REALITY_DEST='a.com/../b'
if ! validate_reality 2>/dev/null; then pass "拒绝 dest 含斜杠"; else fail "未能拦住 dest 斜杠"; fi
REALITY_DEST='www.apple.com'
REALITY_PRIVATE='bad"key'
if ! validate_reality 2>/dev/null; then pass "拒绝私钥含引号"; else fail "未能拦住私钥注入"; fi
REALITY_PRIVATE='PRIVkey_abc-123'
REALITY_SNI='www.apple.com:443'
if ! validate_reality 2>/dev/null; then pass "拒绝 SNI 带端口"; else fail "未能拦住 SNI 带端口"; fi
REALITY_SNI='www.apple.com'

echo
echo "=== 3. generate_nodes：NODE_ADDRESS 必须生效（v2.5.0 核心缺陷）==="
# 3a 空 = 自动双栈
NODE_ADDRESS=""
generate_nodes
L="$(cat "$NODE_FILE")"
if printf '%s' "$L" | grep -q '203.0.113.10' && printf '%s' "$L" | grep -q '2001:db8::99'; then
    pass "留空 → 自动输出 v4+v6 双栈"
else
    fail "留空未输出双栈"; printf '%s\n' "$L"
fi

# 3b 指定域名 = 只用域名，且不再出现自动探测的 IP
NODE_ADDRESS="node.example.com"
generate_nodes
L="$(cat "$NODE_FILE")"
if printf '%s' "$L" | grep -q 'vless://.*@node\.example\.com:8443'; then
    pass "指定域名 → 链接用 node.example.com"
else
    fail "指定域名未生效"; printf '%s\n' "$L"
fi
if ! printf '%s' "$L" | grep -q '203.0.113.10'; then
    pass "指定域名后不再混入自动探测 IPv4"
else
    fail "指定域名仍混入自动 IPv4"
fi

# 3c 指定 IPv4
NODE_ADDRESS="198.51.100.7"
generate_nodes
L="$(cat "$NODE_FILE")"
if printf '%s' "$L" | grep -q 'vless://.*@198\.51\.100\.7:8443'; then
    pass "指定 IPv4 → 链接用 198.51.100.7"
else
    fail "指定 IPv4 未生效"; printf '%s\n' "$L"
fi

# 3d 指定 [IPv6]
NODE_ADDRESS="[2001:db8::7]"
generate_nodes
L="$(cat "$NODE_FILE")"
if printf '%s' "$L" | grep -q 'vless://.*@\[2001:db8::7\]:8443'; then
    pass "指定 [IPv6] → 方括号正确"
else
    fail "指定 [IPv6] 未生效"; printf '%s\n' "$L"
fi

# 3e 用户填了裸 IPv6（没写方括号）也必须正确加括号
NODE_ADDRESS="2001:db8::8"
generate_nodes
L="$(cat "$NODE_FILE")"
if printf '%s' "$L" | grep -q 'vless://.*@\[2001:db8::8\]:8443'; then
    pass "裸 IPv6 → 自动补方括号"
else
    fail "裸 IPv6 未补方括号"; printf '%s\n' "$L"
fi
# 且不能生成畸形的双冒号 URL
if ! printf '%s' "$L" | grep -q '@2001:db8::8:8443'; then
    pass "未产生畸形 IPV6 URL"
else
    fail "产生了畸形 URL @2001:db8::8:8443"
fi

echo
echo "=== 4. 节点文件里注明地址来源 ==="
NODE_ADDRESS="node.example.com"; generate_nodes
if grep -q '连接地址：node\.example\.com' "$NODE_FILE"; then
    pass "指定地址时注明来源"
else
    fail "未注明指定地址"
fi
NODE_ADDRESS=""; generate_nodes
if grep -q '如需固定为某个域名' "$NODE_FILE"; then
    pass "留空时给出填写提示"
else
    fail "留空时缺少提示"
fi

echo
echo "=== 5. validate_common 允许空 NODE_ADDRESS（自动模式） ==="
PROTOCOL="vless"; EDGE_IP="4"; CF_PROTOCOL="http2"; XRAY_PORT="12345"
WS_PATH="/abcd1234"; UUID="11111111-2222-4333-8444-555555555555"
NODE_ADDRESS=""
if validate_common; then pass "空 NODE_ADDRESS 合法（自动双栈）"; else fail "空 NODE_ADDRESS 被误判非法"; fi
NODE_ADDRESS='bad node@#$'
if ! validate_common 2>/dev/null; then pass "非法 NODE_ADDRESS 被拒绝"; else fail "非法 NODE_ADDRESS 通过"; fi

echo
echo "=== 6. 健康检测：curl 无 -f 的假绿灯是否已消除 ==="
# 构造一个返回 404 的本地探测场景，验证新逻辑会判"异常"而不是"通过"
HCODE='404'
_probe() {
    # 复刻 health_check 里的判定分支（不跑整个 health_check，避免依赖服务）
    local _code="$1" probe_ok=0
    if [ "$_code" = "101" ]; then probe_ok=1; fi
    if [ "$_code" = "400" ] || [ "$_code" = "426" ]; then probe_ok=1; fi
    [ "$probe_ok" = "1" ]
}
if ! _probe 404; then pass "HTTP 404 → 判定异常（旧实现会误判通过）"; else fail "404 仍被判通过"; fi
if ! _probe 530; then pass "HTTP 530 → 判定异常"; else fail "530 仍被判通过"; fi
if _probe 101; then pass "HTTP 101 → 判定健康"; else fail "101 未判健康"; fi
if _probe 400; then pass "HTTP 400 → 判定健康（边缘已回源）"; else fail "400 未判健康"; fi
if _probe 426; then pass "HTTP 426 → 判定健康"; else fail "426 未判健康"; fi

# 再确认源码里确实没有裸 curl -s 探测了
if ! grep -q 'curl -s -o /dev/null --max-time 6' "$SRC"; then
    pass "源码已移除裸 curl -s 探测"
else
    fail "源码仍存在 curl -s -o /dev/null --max-time 6"
fi
if grep -q 'Sec-WebSocket-Key' "$SRC"; then
    pass "源码使用 WS 升级握手探测"
else
    fail "源码缺少 WS 握手头"
fi

echo
echo "=== 7. 版本基址重算（升级后不能用旧 tag 拼 URL）==="
eval "$(extract refresh_release_bases)"
XRAY_VERSION="v99.9.9"; CLOUDFLARED_VERSION="2099.1.1"
XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/download/v26.3.27"
CF_RELEASE_BASE="https://github.com/cloudflare/cloudflared/releases/download/2026.8.2"
refresh_release_bases
case "$XRAY_RELEASE_BASE" in
    *v99.9.9) pass "Xray 基址已随版本重算" ;;
    *) fail "Xray 基址未更新：$XRAY_RELEASE_BASE" ;;
esac
case "$CF_RELEASE_BASE" in
    *2099.1.1) pass "cloudflared 基址已随版本重算" ;;
    *) fail "cloudflared 基址未更新：$CF_RELEASE_BASE" ;;
esac

echo
echo "=== 8. 版本可被环境变量覆盖 ==="
V="$(SUOHA_XRAY_VERSION=v1.2.3 bash -c 'XRAY_VERSION="${SUOHA_XRAY_VERSION:-v26.3.27}"; printf %s "$XRAY_VERSION"')"
if [ "$V" = "v1.2.3" ]; then pass "SUOHA_XRAY_VERSION 覆盖生效"; else fail "环境变量覆盖失败：$V"; fi
V="$(bash -c 'XRAY_VERSION="${SUOHA_XRAY_VERSION:-v26.3.27}"; printf %s "$XRAY_VERSION"')"
if [ "$V" = "v26.3.27" ]; then pass "未设变量时回落到内置版本"; else fail "默认值异常：$V"; fi

echo
echo "=== 9. 版本持久化字段存在 ==="
if grep -q "printf 'SUOHA_XRAY_VERSION=%q" "$SRC"; then
    pass "save_state 写入 SUOHA_XRAY_VERSION"
else
    fail "save_state 未持久化版本"
fi
if awk '/^load_state\(\)/{f=1} f&&/refresh_release_bases/{print;exit}' "$SRC" | grep -q refresh_release_bases; then
    pass "load_state 后重算下载基址"
else
    fail "load_state 未重算基址"
fi

echo
echo "=== 10. 菜单 9 已接入 ==="
if grep -q '9) component_menu ;;' "$SRC"; then pass "主菜单绑定 component_menu"; else fail "主菜单未绑定"; fi
if grep -q '9) 组件版本' "$SRC"; then pass "主菜单有 9) 入口说明"; else fail "缺少入口说明"; fi

echo
echo "=== 11. Quick 停机提示 ==="
if grep -q 'Quick 隧道未运行' "$SRC"; then pass "show_status 含 Quick 停机提示"; else fail "缺少 Quick 停机提示"; fi
if awk '/^show_status\(\)/{f=1} /^config_menu\(\)/{f=0} f&&/Quick 隧道未运行/{print;exit}' "$SRC" | grep -q .; then
    pass "提示位于 show_status 内"
else
    fail "提示不在 show_status 内"
fi

echo
echo "==================================="
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1