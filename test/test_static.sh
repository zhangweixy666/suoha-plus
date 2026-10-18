#!/bin/sh
# 静态断言：代码长成预期样子（版本一致性、修复特征存在、结构完整）
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
S="${SUOHA_TEST_SCRIPT:-$REPO/suoha-manager.sh}"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

check() {
    desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

has() { grep -qF -- "$1" "$S"; }
hasre() { grep -qE -- "$1" "$S"; }

if [ ! -f "$S" ]; then
    echo "找不到待测脚本：$S" >&2
    exit 2
fi

echo "待测：$S"

# ---------- 版本一致性 ----------
echo "[版本]"
VER=$(sed -n 's/^APP_VERSION="\(.*\)"/\1/p' "$S" | head -n 1)
check "APP_VERSION 存在" test -n "$VER"
check "APP_VERSION 为 2.4.4" test "$VER" = "2.4.4"
check "README 版本记录含 v2.4.4" grep -qF '**v2.4.4**' "$REPO/README.md"
VERREADME=$(grep -oE 'v2\.4\.4' "$REPO/README.md" | head -n 1)
check "README 与脚本版本一致" test "$VERREADME" = "v$VER"

# ---------- 语法 ----------
echo "[语法]"
check "bash -n 通过" bash -n "$S"

# ---------- 结构完整性 ----------
echo "[结构]"
check "无 U+FFFD 乱码" sh -c "! grep -q \"\$(printf '\\357\\277\\275')\" \"\$0\"" "$S"
check "函数总数 >= 70" sh -c "[ \$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\\(\\)[[:space:]]*\\{' \"\$0\") -ge 70 ]" "$S"
check "入口只调用一次 main_menu" sh -c "[ \$(grep -c '^main_menu$' \"\$0\") -eq 1 ]" "$S"

# ---------- P0-1 CMD_LINK ----------
echo "[P0-1 管理命令]"
check "install_cmd_link 函数存在" has 'install_cmd_link() {'
check "有 ln -sf 创建软链" hasre 'ln -sf "\$SCRIPT_SELF" "\$CMD_LINK"'
check "Reality 安装后调用" sh -c "awk '/^setup_reality\\(\\)/{f=1} f&&/install_cmd_link/{print;exit}' \"\$0\" | grep -qF install_cmd_link" "$S"
check "持久化安装后调用" sh -c "awk '/^setup_persistent\\(\\)/{f=1} f&&/install_cmd_link/{print;exit}' \"\$0\" | grep -qF install_cmd_link" "$S"
check "SCRIPT_SELF 变量存在" has 'SCRIPT_SELF='

# ---------- P0-2 OpenRC 状态 ----------
echo "[P0-2 OpenRC 状态]"
check "service_unit_exists 函数存在" has 'service_unit_exists() {'
check "status_line 支持 OpenRC" sh -c "awk '/^status_line\\(\\)/{f=1} f&&/rc-service/{print;exit}' \"\$0\" | grep -qF rc-service" "$S"
check "status_line 识别 started" sh -c "awk '/^status_line\\(\\)/{f=1} f&&/\*started\*/{print;exit}' \"\$0\" | grep -qF started" "$S"
check "health_check 识别 OpenRC xray" sh -c "awk '/^health_check\\(\\)/{f=1} f&&/rc-service suoha-plus-xray/{print;exit}' \"\$0\" | grep -qF rc-service" "$S"
check "health_check 识别 OpenRC cf" sh -c "awk '/^health_check\\(\\)/{f=1} f&&/rc-service suoha-plus-cloudflared/{print;exit}' \"\$0\" | grep -qF rc-service" "$S"

# ---------- P0-3 ShadowQuic 架构 ----------
echo "[P0-3 ShadowQuic 架构]"
check "sq_arch_asset 函数存在" has 'sq_arch_asset() {'
check "映射 aarch64" has 'shadowquic-aarch64-linux-musl'
check "映射 armv7" has 'shadowquic-armv7-linux-muslhf'
check "映射 i686" has 'shadowquic-i686-linux-musl'
check "映射 x86_64" has 'shadowquic-x86_64-linux-musl'
check "不再硬编码 x86_64 下载路径" sh -c "! grep -qF 'releases/download/\$ver/shadowquic-x86_64-linux-musl' \"\$0\"" "$S"
check "下载走 sq_download_bin" has 'sq_download_bin() {'
check "下载后真实执行验证" hasre 'timeout 10 "\$tmp" --version'

# ---------- 最新版 + 手动升级 ----------
echo "[ShadowQuic 最新版/升级]"
check "sq_latest_version 存在" has 'sq_latest_version() {'
check "sq_local_version 存在" has 'sq_local_version() {'
check "sq_check_update 存在" has 'sq_check_update() {'
check "sq_upgrade 存在" has 'sq_upgrade() {'
check "菜单含升级选项 8" sh -c "awk '/^sq_menu\\(\\)/{f=1} f&&/8\)/{print;exit}' \"\$0\" | grep -q ." "$S"
check "菜单 8 绑定 sq_upgrade" has '8) sq_upgrade; pause_screen ;;'
check "安装时检查最新版" has '检查 shadowquic 版本'
check "已是新版则跳过下载" has '已是最新版本，跳过下载'
check "存在旧版会询问升级" has '是否升级到'
check "升级前二次确认" has '确认升级到'
check "用 mktemp 而非固定 /tmp/.sq.dl" sh -c "! grep -qF 'o /tmp/.sq.dl ' \"\$0\"" "$S"

# ---------- P1-4 stop_services ----------
echo "[P1-4 Reality 模式停止]"
check "stop_services 用 service_unit_exists" sh -c "awk '/^stop_services\\(\\)/{f=1} f&&/service_unit_exists/{print;exit}' \"\$0\" | grep -qF service_unit_exists" "$S"
check "stop_services 不再只认 persistent" sh -c "awk '/^stop_services\\(\\)/{f=1} /^restart_services\\(\\)/{f=0} f&&/\[ \"\$MODE\" = \"persistent\" \] && has_systemd/{print;exit}' \"\$0\" | grep -qF persistent && exit 1 || exit 0" "$S"

# ---------- P1-5 IP 缓存 ----------
echo "[P1-5 IP 探测缓存]"
check "_IP4_CACHE 存在" has '_IP4_CACHE=""'
check "_IP6_CACHE 存在" has '_IP6_CACHE=""'
check "public_ip 有缓存分支" sh -c "awk '/^public_ip\\(\\)/{f=1} f&&/_IP4_CACHE/{print;exit}' \"\$0\" | grep -qF _IP4_CACHE" "$S"
check "public_ip6 有缓存分支" sh -c "awk '/^public_ip6\\(\\)/{f=1} f&&/_IP6_CACHE/{print;exit}' \"\$0\" | grep -qF _IP6_CACHE" "$S"

# ---------- P2 并发锁 / 日志轮转 ----------
echo "[P2 并发锁/日志轮转]"
check "flock 并发锁存在" has 'flock -n 9'
check "LOCK_FILE 定义" has 'LOCK_FILE='
check "rotate_log 函数存在" has 'rotate_log() {'
check "日志轮转阈值 10MB" has '10485760'

# ---------- 原有特性未被破坏 ----------
echo "[回归：原有特性]"
check "Xray dgst SHA256 校验仍在" has 'SHA2-256'
check "拒绝安装逻辑仍在" has '拒绝安装'
check "OpenRC daemon 重建日志目录" sh -c "grep -qF 'mkdir -p \$LOG_DIR || exit 1' \"\$0\"" "$S"
check "cf_full_cleanup 不删整个 .cloudflared" sh -c "! grep -qF 'rm -rf /root/.cloudflared' \"\$0\"" "$S"
check "SUOHA_TTY 管道守卫仍在" has 'SUOHA_TTY'
check "SUOHA_TTY 检查了参数个数" hasre '\[ "\$#" -eq 0 \]'

# ---------- ShadowQuic 共享目录归属保护 ----------
echo "[ShadowQuic 归属保护]"
check "sq_owned 函数存在" has 'sq_owned() {'
check "sq_foreign_owner 函数存在" has 'sq_foreign_owner() {'
check "标记文件 .managed-by-suoha-plus" has '.managed-by-suoha-plus'
check "识别 warp- 归属标记" has '.managed-by-warp-go'
check "写入前备份外部配置" has 'bak-suoha.'
check "写入后打归属标记" has ': > "$(sq_marker_path)"'
check "sq_remove 用 sq_owned 判定" sh -c "awk '/^sq_remove\(\)/{f=1} f&&/sq_owned/{print;exit}' "\$0" | grep -qF sq_owned" "$S"
check "sq_remove 不再 rm -rf SQ_APP_DIR" sh -c "! grep -qF 'rm -rf "\$SQ_APP_DIR"' "\$0"" "$S"

# ---------- 汇总 ----------
echo ""
echo "静态断言：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
