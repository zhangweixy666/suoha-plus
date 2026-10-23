#!/usr/bin/env bash
# Suoha Plus - Xray + Cloudflare Tunnel 管理脚本
# 基于原 suoha.sh 的独立增强版：不会覆盖、删除或调用原脚本。
# 固定版本（2026-08-27 查询到的 GitHub 最新正式版）

# 管道自重放：支持 wget -qO- URL | sh 一键运行（下载副本后用真实 tty 重启自身）
if [ -z "${SUOHA_TTY:-}" ] && [ ! -t 0 ] && [ "$#" -eq 0 ]; then
    SELF_URL_DEFAULT="https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/suoha-manager.sh"
    if [ -n "$SUOHA_SELF_URL" ]; then
        _self_url="$SUOHA_SELF_URL"
    else
        _self_url="$SELF_URL_DEFAULT"
    fi
    case "$_self_url" in
        http://*|https://*) : ;;
        *) _self_url="$SELF_URL_DEFAULT" ;;
    esac
    _install_path="${SUOHA_INSTALL_PATH:-$HOME/suoha-plus-managed.sh}"
    mkdir -p "$(dirname "$_install_path")" 2>/dev/null
    # 引导阶段函数还没定义，这里用自包含的提示 + 进度条（不要再静默下载）。
    printf '[信息] 正在获取脚本副本：%s\n' "$_self_url" >&2
    printf '[信息] 保存到：%s\n' "$_install_path" >&2
    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 15 --max-time 120 --progress-bar \
             -o "$_install_path" "$_self_url" || \
        wget -O "$_install_path" "$_self_url"      # wget 自带进度条，不要 2>/dev/null
    else
        wget -O "$_install_path" "$_self_url"      # 同上：保留 wget 原生进度显示
    fi
    if [ -s "$_install_path" ]; then
        chmod +x "$_install_path" 2>/dev/null
        export SUOHA_TTY=1
        if bash -c 'exec 0</dev/tty' 2>/dev/null; then
            exec bash "$_install_path" < /dev/tty
        else
            exec bash "$_install_path"
        fi
    else
        echo "[错误] 管道模式下无法下载脚本副本，请改用：wget -qO /root/suoha-manager.sh <URL> && sh /root/suoha-manager.sh" >&2
        exit 1
    fi
fi

APP_NAME="suoha-plus"
APP_VERSION="2.6.2"
APP_DIR="/opt/suoha-plus"
BIN_DIR="$APP_DIR/bin"
LOG_DIR="$APP_DIR/logs"
TMP_DIR="$APP_DIR/tmp"
XRAY_BIN="$BIN_DIR/xray"
CF_BIN="$BIN_DIR/cloudflared"
XRAY_CONFIG="$APP_DIR/xray.json"
CF_CONFIG="$APP_DIR/config.yaml"
STATE_FILE="$APP_DIR/state.env"
NODE_FILE="$APP_DIR/v2ray.txt"
XRAY_LOG="$LOG_DIR/xray.log"
CF_LOG="$LOG_DIR/cloudflared.log"
XRAY_PID="$APP_DIR/xray.pid"
CF_PID="$APP_DIR/cloudflared.pid"
CMD_LINK="/usr/local/bin/suoha-plus"
LOCK_FILE="/tmp/suoha-plus.lock"
SERVICE_XRAY="suoha-plus-xray.service"
SERVICE_CF="suoha-plus-cloudflared.service"

XRAY_VERSION="${SUOHA_XRAY_VERSION:-v26.3.27}"
CLOUDFLARED_VERSION="${SUOHA_CLOUDFLARED_VERSION:-2026.8.2}"
SQ_PORT="1443"
# 固定版本是刻意设计（可复现、不受上游更新影响）。
# 但提供两条升级通道：
#   1) 环境变量覆盖：SUOHA_XRAY_VERSION=vXX.X.XX ./suoha-manager.sh
#   2) 菜单 9) 组件版本：检查上游最新版，确认后升级并写入 state.env
XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION"
CF_RELEASE_BASE="https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION"

# 版本变化后必须重算下载基址，否则还在用旧 tag 拼 URL。
refresh_release_bases() {
    XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION"
    CF_RELEASE_BASE="https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION"
}

# 仅作显示和生成节点使用；不会自动更新到 latest。
# WS 节点默认接入域名：大厂自有域名且解析到 Cloudflare 边缘（对中国友好，非微软系）
NODE_ADDRESS="www.visa.com"
MODE="quick"
PROTOCOL="vmess"
EDGE_IP="4"
CF_PROTOCOL="http2"
UUID=""
WS_PATH=""
XRAY_PORT=""
QUICK_URL=""
DOMAIN=""
TUNNEL_NAME="suoha-plus"
TUNNEL_ID=""
ISP_TAG="SuohaPlus"
# Reality 直连参数（vless + XTLS Vision，无需域名和隧道）
REALITY_ENABLED="no"
REALITY_PORT="8443"
REALITY_DEST="www.apple.com"
REALITY_SNI="www.apple.com"
REALITY_PRIVATE=""
REALITY_PUBLIC=""
REALITY_SHORT_ID=""

if [ -t 1 ]; then
    C_RESET="\033[0m"; C_BLUE="\033[1;34m"; C_CYAN="\033[1;36m"
    C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"
else
    C_RESET=""; C_BLUE=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

say() { printf '%b\n' "$*"; }

# 安装过程中的临时目录（mktemp -d 创建），正常结束或异常退出都清理。
_cleanup_paths=""

# 锁释放/重建：所有会 fork 常驻服务（rc-service、systemctl、nohup）的地方
# 必须先释放锁 fd 9，否则常驻进程会继承并永久持有它，导致本脚本再也打不开。
lock_release() {
    if [ -e /proc/$$/fd/9 ]; then
        exec 9>&-
    fi
    return 0
}

lock_acquire() {
    command_exists flock || return 0
    [ -n "$LOCK_FILE" ] || return 0
    { exec 9>"$LOCK_FILE"; } 2>/dev/null || return 0
    flock -n 9 2>/dev/null || return 0
    return 0
}

cleanup_register() {
    [ -n "$1" ] || return 0
    _cleanup_paths="$_cleanup_paths $1"
}

cleanup_on_exit() {
    [ -n "$_cleanup_paths" ] || return 0
    rm -rf $_cleanup_paths 2>/dev/null || true
    _cleanup_paths=""
    return 0
}
info() { say "${C_CYAN}[信息]${C_RESET} $*"; }
ok() { say "${C_GREEN}[完成]${C_RESET} $*"; }
warn() { say "${C_YELLOW}[注意]${C_RESET} $*"; }
err() { say "${C_RED}[错误]${C_RESET} $*" >&2; }

banner() {
    clear 2>/dev/null || true
    say "${C_BLUE}╔══════════════════════════════════════════════╗${C_RESET}"
    say "${C_BLUE}║${C_RESET}  Suoha Plus  v$APP_VERSION                  ${C_BLUE}║${C_RESET}"
    say "${C_BLUE}║${C_RESET}  Xray $XRAY_VERSION  |  cloudflared $CLOUDFLARED_VERSION  ${C_BLUE}║${C_RESET}"
    say "${C_BLUE}╚══════════════════════════════════════════════╝${C_RESET}"
}

pause_screen() {
    # 用 IFS= read -r 读一行；stdin 关闭时直接返回（不卡住、不吞后续输入）
    printf '\n按回车继续...' >&2
    IFS= read -r _dummy 2>/dev/null || true
    printf '\n' >&2
    return 0
}

ask_default() {
    local prompt="$1" default="$2" answer
    # 提示符必须单独打印到 stderr：read -p 的提示在 $(...) 子 shell 里会丢失，
    # 用户只看到空白光标，会误以为脚本卡死。
    printf '%s [%s]: ' "$prompt" "$default" >&2
    answer=""
    if ! IFS= read -r answer; then
        # stdin 已关闭（管道喂完/非交互环境）：用默认值继续，绝不挂死
        printf '\n' >&2
        printf '%s' "$default"
        return 0
    fi
    printf '%s' "${answer:-$default}"
}

# 安全读取：结果写入调用者指定变量，避免 $(...) 子shell 吞掉管道 stdin。
# 用法：safe_read VAR "提示" "默认值"
safe_read() {
    local __var="$1" __prompt="$2" __default="$3" __answer
    printf '%s' "$__prompt" >&2
    __answer=""
    if ! IFS= read -r __answer; then
        printf '\\n' >&2
        eval "$__var=\$__default"
        return 0
    fi
    [ -n "$__answer" ] || __answer="$__default"
    eval "$__var=\$__answer"
    return 0
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# 当前已安装情况的简短描述；未安装返回空串。
installed_desc() {
    local parts=""
    [ -f "$STATE_FILE" ] || [ -f "$XRAY_CONFIG" ] && parts="Suoha Plus"
    if [ -f "$SQ_APP_DIR/server-direct.yaml" ]; then
        if [ -n "$parts" ]; then parts="$parts + ShadowQuic"; else parts="ShadowQuic"; fi
    fi
    printf '%s' "$parts"
}

# 重装确认。返回 0 = 继续覆盖，1 = 放弃。都没装则直接返回 0。
confirm_overwrite() {
    local target="$1" desc
    desc="$(installed_desc)"
    [ -n "$desc" ] || return 0
    say ""
    warn "检测到已安装：$desc"
    info "继续会覆盖现有 $target 配置与服务（节点链接会重新生成）。"
    local ans=""
    safe_read ans "是否覆盖重装？[Y/n]: " "y"
    case "$ans" in
        n|N|no|NO) info "已取消，未做任何修改。"; return 1 ;;
    esac
    return 0
}
need_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限，请使用 root 或 sudo 运行。"
        return 1
    fi
}

new_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command_exists uuidgen; then
        uuidgen
    else
        err "系统没有可用的 UUID 生成器。"
        return 1
    fi
}

init_defaults() {
    [ -n "$UUID" ] || UUID="$(new_uuid 2>/dev/null || true)"
    [ -n "$UUID" ] || UUID="00000000-0000-4000-8000-000000000000"
    [ -n "$WS_PATH" ] || WS_PATH="/${UUID%%-*}"
    if ! [[ "$XRAY_PORT" =~ ^[0-9]+$ ]] || [ "$XRAY_PORT" -lt 1024 ] || [ "$XRAY_PORT" -gt 65535 ]; then
        XRAY_PORT=$((10000 + RANDOM % 40000))
    fi
}

load_state() {
    if [ -r "$STATE_FILE" ]; then
        # state.env 由本脚本以 %q 写入，仅加载本脚本自己的状态文件。
        # shellcheck disable=SC1090
        . "$STATE_FILE"
    fi
    # state.env 里可能记录了升级后的组件版本（SUOHA_XRAY_VERSION 等），
    # 下载基址必须跟着重算，否则仍会用旧的 tag 拼 URL 导致 404。
    refresh_release_bases
    init_defaults
}

save_state() {
    mkdir -p "$APP_DIR" "$LOG_DIR" "$TMP_DIR" || return 1
    umask 077
    {
        printf 'MODE=%q\n' "$MODE"
        printf 'PROTOCOL=%q\n' "$PROTOCOL"
        printf 'EDGE_IP=%q\n' "$EDGE_IP"
        printf 'CF_PROTOCOL=%q\n' "$CF_PROTOCOL"
        printf 'NODE_ADDRESS=%q\n' "$NODE_ADDRESS"
        printf 'UUID=%q\n' "$UUID"
        printf 'WS_PATH=%q\n' "$WS_PATH"
        printf 'XRAY_PORT=%q\n' "$XRAY_PORT"
        printf 'QUICK_URL=%q\n' "$QUICK_URL"
        printf 'SQ_PORT=%q\n' "$SQ_PORT"
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'TUNNEL_NAME=%q\n' "$TUNNEL_NAME"
        printf 'TUNNEL_ID=%q\n' "$TUNNEL_ID"
        printf 'ISP_TAG=%q\n' "$ISP_TAG"
        printf 'REALITY_ENABLED=%q\n' "$REALITY_ENABLED"
        printf 'REALITY_PORT=%q\n' "$REALITY_PORT"
        printf 'REALITY_DEST=%q\n' "$REALITY_DEST"
        printf 'REALITY_SNI=%q\n' "$REALITY_SNI"
        printf 'REALITY_PRIVATE=%q\n' "$REALITY_PRIVATE"
        printf 'REALITY_PUBLIC=%q\n' "$REALITY_PUBLIC"
        printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
        # 组件版本持久化：菜单 9 升级后必须记住，否则重开菜单又回到脚本内置版本。
        printf 'SUOHA_XRAY_VERSION=%q\n' "$XRAY_VERSION"
        printf 'SUOHA_CLOUDFLARED_VERSION=%q\n' "$CLOUDFLARED_VERSION"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

validate_common() {
    case "$PROTOCOL" in vmess|vless) ;; *) err "Xray 协议只能是 vmess 或 vless。"; return 1 ;; esac
    case "$EDGE_IP" in 4|6) ;; *) err "边缘 IP 只能是 4 或 6。"; return 1 ;; esac
    case "$CF_PROTOCOL" in auto|quic|http2) ;; *) err "隧道协议只能是 auto、quic 或 http2。"; return 1 ;; esac
    if ! [[ "$XRAY_PORT" =~ ^[0-9]+$ ]] || [ "$XRAY_PORT" -lt 1024 ] || [ "$XRAY_PORT" -gt 65535 ]; then
        err "本地端口必须是 1024-65535。"
        return 1
    fi
    if ! [[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        err "UUID 格式不正确。"
        return 1
    fi
    if ! [[ "$WS_PATH" =~ ^/[A-Za-z0-9._~/-]*$ ]]; then
        err "WS 路径必须以 / 开头，且只能包含字母、数字、点、下划线、波浪线、连字符和斜杠。"
        return 1
    fi

    # 节点地址允许为空：空表示"自动双栈"（由 generate_nodes 探测公网 v4/v6 各出一条链接）。
    # 旧实现把 "" 和非法字符写在同一分支里一起 return 1，导致"留空自动"这条路径根本走不通。
    if [ -n "$NODE_ADDRESS" ]; then
        case "$NODE_ADDRESS" in
            *[!A-Za-z0-9._:\[\]-]*) err "节点地址只能包含域名、IPv4、IPv6（[方括号]）和端口所需字符。"; return 1 ;;
        esac
    fi
}

validate_domain() {
    case "$1" in
        ""|*[!A-Za-z0-9.-]*|.*|*-|*.) return 1 ;;
        *.*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_tunnel_name() {
    case "$1" in
        ""|*[!A-Za-z0-9_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

has_systemd() {
    [ -d /run/systemd/system ] && command_exists systemctl
}

service_unit_exists() {
    local unit="$1"
    [ -n "$unit" ] || return 1
    [ -f "/etc/systemd/system/$unit" ] && return 0
    [ -f "/etc/init.d/${unit%.service}" ] && return 0
    return 1
}

has_openrc() {
    ! has_systemd && command_exists rc-update && [ -d /etc/init.d ] && command_exists rc-service
}

install_dependencies() {
    local missing=0 pkgs=""
    command_exists curl || { missing=1; pkgs="$pkgs curl"; }
    command_exists unzip || { missing=1; pkgs="$pkgs unzip"; }
    command_exists base64 || { missing=1; pkgs="$pkgs coreutils"; }
    command_exists sha256sum || { missing=1; pkgs="$pkgs coreutils"; }
    if [ "$missing" = "0" ]; then return 0; fi

    local mgr=""
    if command_exists apt-get; then mgr="apt-get"
    elif command_exists dnf; then mgr="dnf"
    elif command_exists yum; then mgr="yum"
    elif command_exists apk; then mgr="apk"
    else
        err "找不到 apt-get/dnf/yum/apk，请手动安装 curl、unzip、base64。"
        return 1
    fi

    # 安装系统包会改动机器全局环境（apt 还会先 update），必须让用户明确同意。
    confirm_download \
        "系统依赖：$(printf '%s' "$pkgs" | tr -s ' ' | sed 's/^ //')" \
        "通过 $mgr 安装（会修改系统包状态，apt 会先执行 update）" \
        "/usr/bin" || return 1

    info "正在安装 curl、unzip、base64 等依赖..."
    if [ "$mgr" = "apt-get" ]; then
        apt-get update && apt-get install -y curl unzip coreutils ca-certificates || return 1
    elif [ "$mgr" = "dnf" ]; then
        dnf install -y curl unzip coreutils ca-certificates || return 1
    elif [ "$mgr" = "yum" ]; then
        yum install -y curl unzip coreutils ca-certificates || return 1
    else
        apk add --no-cache curl unzip coreutils ca-certificates || return 1
    fi
}

set_arch_assets() {
    case "$(uname -m)" in
        x86_64|amd64)
            XRAY_ASSET="Xray-linux-64.zip"; CF_ASSET="cloudflared-linux-amd64" ;;
        i386|i686)
            XRAY_ASSET="Xray-linux-32.zip"; CF_ASSET="cloudflared-linux-386" ;;
        aarch64|arm64)
            XRAY_ASSET="Xray-linux-arm64-v8a.zip"; CF_ASSET="cloudflared-linux-arm64" ;;
        armv7l|armv7|armhf)
            XRAY_ASSET="Xray-linux-arm32-v7a.zip"; CF_ASSET="cloudflared-linux-arm" ;;
        *)
            err "不支持的架构：$(uname -m)"; return 1 ;;
    esac
}

xray_version_ok() {
    [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version 2>/dev/null | grep -Fq "${XRAY_VERSION#v}"
}

cloudflared_version_ok() {
    [ -x "$CF_BIN" ] && "$CF_BIN" version 2>/dev/null | grep -Fq "$CLOUDFLARED_VERSION"
}

# ---------- 下载交互：先确认，再显示真实进度 ----------
# 约定：任何网络下载都必须先经过 confirm_download 得到明确同意，
# 再用 dl_run 执行（展示百分比/大小/速度/剩余时间），不允许裸 curl 静默下载。

human_bytes() {
    local b="${1:-0}"
    case "$b" in ''|*[!0-9]*) b=0 ;; esac
    if [ "$b" -ge 1073741824 ]; then
        printf '%d.%02dG' $((b / 1073741824)) $(( (b % 1073741824) * 100 / 1073741824 ))
    elif [ "$b" -ge 1048576 ]; then
        printf '%d.%01dM' $((b / 1048576)) $(( (b % 1048576) * 10 / 1048576 ))
    elif [ "$b" -ge 1024 ]; then
        printf '%dK' $((b / 1024))
    else
        printf '%dB' "$b"
    fi
}

# 下载前确认。用法：confirm_download "下载内容" "补充说明" "保存位置"
# 返回 0 = 用户同意；1 = 取消（调用方必须直接返回，不得修改任何东西）。
# 默认值是 N：直接回车不会开始下载。
# 自动化场景可用 SUOHA_ASSUME_YES=1 跳过确认。
confirm_download() {
    local what="$1" note="$2" dest="$3" ans=""
    if [ "${SUOHA_ASSUME_YES:-0}" = "1" ]; then
        info "已设置 SUOHA_ASSUME_YES=1，跳过下载确认。"
        return 0
    fi
    say ""
    say "${C_CYAN}── 下载确认 ──${C_RESET}"
    say "  内容：$what"
    [ -n "$note" ] && say "  说明：$note"
    [ -n "$dest" ] && say "  位置：$dest"
    safe_read ans "确认开始下载？[y/N]: " "n"
    case "$ans" in
        y|Y|yes|YES|Yes) return 0 ;;
    esac
    info "已取消下载，未做任何修改。"
    return 1
}

# 取远端文件大小（跟随重定向，取最后一个 Content-Length）。拿不到时返回 0。
# 必须先确认 HTTP 状态码是 2xx：404/500 的错误页也有 Content-Length，
# 直接取会让进度条显示一个假的"100% 完成"然后再失败。
dl_remote_size() {
    local url="$1" resp cl code
    resp="$(curl -sIL --max-time 10 -w '\nHTTPCODE:%{http_code}' "$url" 2>/dev/null | tr -d '\r')"
    code="$(printf '%s\n' "$resp" | sed -n 's/^HTTPCODE:\([0-9][0-9]*\)$/\1/p' | tail -n 1)"
    case "$code" in
        2[0-9][0-9]) : ;;
        *) printf '0'; return 0 ;;
    esac
    cl="$(printf '%s\n' "$resp" | awk 'tolower($1) == "content-length:" { v = $2 } END { print v }')"
    case "$cl" in
        ''|*[!0-9]*) printf '0' ;;
        *)           printf '%s' "$cl" ;;
    esac
}

# 渲染一行进度：\r 原地刷新，只写 stderr，不污染 stdout（避免破坏 $(...) 取值）。
dl_render() {
    local label="$1" got="$2" total="$3" started="$4" tty="$5"
    local now elapsed pct filled bar i speed sp eta
    [ "$tty" = "1" ] || return 0
    now="$(date +%s)"
    elapsed=$(( now - started ))
    [ "$elapsed" -lt 1 ] && elapsed=1
    speed=$(( got / elapsed ))
    if [ "$total" -gt 0 ]; then
        pct=$(( got * 100 / total ))
        [ "$pct" -gt 100 ] && pct=100
        filled=$(( pct * 20 / 100 ))
        bar=""
        i=0
        while [ "$i" -lt 20 ]; do
            if [ "$i" -lt "$filled" ]; then bar="$bar#"; else bar="$bar."; fi
            i=$(( i + 1 ))
        done
        sp=$speed
        [ "$sp" -lt 1 ] && sp=1
        eta=$(( (total - got) / sp ))
        [ "$eta" -lt 0 ] && eta=0
        printf '\r  %-12s [%s] %3d%%  %s/%s  %s/s  剩余%ss\033[K' \
            "$label" "$bar" "$pct" "$(human_bytes "$got")" "$(human_bytes "$total")" \
            "$(human_bytes "$speed")" "$eta" >&2
    else
        printf '\r  %-12s 已下载 %s  %s/s\033[K' \
            "$label" "$(human_bytes "$got")" "$(human_bytes "$speed")" >&2
    fi
}

# dl_run LABEL URL DEST [MAX_SECONDS]
# 返回 0 = 成功（文件已完整落盘）；非 0 = 失败（已打印原因，DEST 会被清理）。
dl_run() {
    local label="$1" url="$2" dest="$3" max_t="${4:-180}"
    local total started pid rc tty errf got sz used
    rm -f "$dest"
    errf="$dest.curlerr"
    [ -t 2 ] && tty=1 || tty=0
    total="$(dl_remote_size "$url")"
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    started="$(date +%s)"
    # -sS：屏蔽 curl 自带进度条（会与我们的渲染打架），但保留错误文本。
    # curl 的 stderr 落到临时文件，失败时再展示，避免 --retry 的重试信息冲散进度行。
    curl -fsSL --retry 3 --connect-timeout 15 --max-time "$max_t" \
         -o "$dest" "$url" 2>"$errf" &
    pid=$!
    if [ "$tty" = "1" ]; then
        while kill -0 "$pid" 2>/dev/null; do
            sleep 1
            got="$(wc -c < "$dest" 2>/dev/null || printf 0)"
            got="${got//[!0-9]/}"
            [ -n "$got" ] || got=0
            dl_render "$label" "$got" "$total" "$started" "$tty"
        done
    else
        # 非交互环境无法原地刷新，退化为一条开始提示，避免长时间静默。
        info "$label 开始下载（大小 $(human_bytes "$total")，最长等 ${max_t}s）..."
    fi
    wait "$pid"
    rc=$?
    used=$(( $(date +%s) - started ))
    [ "$used" -lt 1 ] && used=1
    if [ "$tty" = "1" ]; then
        if [ "$rc" -eq 0 ]; then
            got="$(wc -c < "$dest" 2>/dev/null || printf 0)"
            got="${got//[!0-9]/}"
            [ -n "$got" ] || got=0
            dl_render "$label" "$got" "$got" "$started" "$tty"
        fi
        printf '\n' >&2
    fi
    if [ "$rc" -ne 0 ]; then
        err "$label 下载失败（curl 退出码 $rc）。"
        if [ -s "$errf" ]; then
            tail -n 5 "$errf" | sed 's/^/    /' >&2
        fi
        rm -f "$errf" "$dest"
        return 1
    fi
    rm -f "$errf"
    sz="$(wc -c < "$dest" 2>/dev/null || printf 0)"
    sz="${sz//[!0-9]/}"
    [ -n "$sz" ] || sz=0
    ok "$label 下载完成：$(human_bytes "$sz")，耗时 ${used}s（均速 $(human_bytes $(( sz / used )))/s）"
    return 0
}

download_binaries() {
    # 第二个参数 1 = 调用方已确认过（菜单 9 升级路径），避免同一件事问两次。
    # 实测教训：component_upgrade 直接复用本函数时，用户点一次"升级"会被问两遍，
    # 第二次默认 N 直接静默取消升级。
    local preconfirmed="${1:-0}"
    set_arch_assets || return 1
    mkdir -p "$BIN_DIR" "$TMP_DIR" || return 1
    local tmp xray_candidate
    if [ "$preconfirmed" != "1" ]; then
        confirm_download \
            "Xray $XRAY_VERSION（$XRAY_ASSET）+ cloudflared $CLOUDFLARED_VERSION（$CF_ASSET）" \
            "来自 GitHub Releases，合计约 60-80MB；下载后校验 SHA-256 与可执行版本" \
            "$BIN_DIR" || return 1
    fi
    tmp="$(mktemp -d "$TMP_DIR/download.XXXXXX")" || return 1
    cleanup_register "$tmp"

    dl_run "Xray" "${XRAY_RELEASE_BASE}/${XRAY_ASSET}" "$tmp/xray.zip" 180 \
        || { rm -rf "$tmp"; err "Xray 下载失败（网络不通或超时）。"; return 1; }
    dl_run "Xray-SHA256" "${XRAY_RELEASE_BASE}/${XRAY_ASSET}.dgst" "$tmp/xray.dgst" 60 \
        || { rm -rf "$tmp"; err "Xray 校验文件下载失败，拒绝安装。"; return 1; }
    local xray_sha expected_sha
    expected_sha="$(awk -F'= ' '/^SHA2-256=/{print $2; exit}' "$tmp/xray.dgst")"
    xray_sha="$(sha256sum "$tmp/xray.zip" | awk '{print $1}')"
    if ! [[ "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]] || [ "$xray_sha" != "$expected_sha" ]; then
        rm -rf "$tmp"; err "Xray SHA-256 校验失败，拒绝安装。"; return 1
    fi
    mkdir -p "$tmp/xray" || { rm -rf "$tmp"; return 1; }
    if ! unzip -q "$tmp/xray.zip" -d "$tmp/xray"; then
        rm -rf "$tmp"; err "Xray 压缩包解压失败。"; return 1
    fi
    xray_candidate="$(find "$tmp/xray" -type f -name xray | head -n 1)"
    if [ -z "$xray_candidate" ] || [ ! -f "$xray_candidate" ]; then
        rm -rf "$tmp"; err "下载包中没有找到 xray 可执行文件。"; return 1
    fi
    chmod +x "$xray_candidate"
    if ! "$xray_candidate" version 2>/dev/null | grep -Fq "${XRAY_VERSION#v}"; then
        rm -rf "$tmp"; err "Xray 版本校验失败，拒绝安装。"; return 1
    fi

    dl_run "cloudflared" "${CF_RELEASE_BASE}/${CF_ASSET}" "$tmp/cloudflared" 180 \
        || { rm -rf "$tmp"; err "cloudflared 下载失败（网络不通或超时）。"; return 1; }
    # cloudflared release has no official SHA-256 manifest; verify executable and exact version.
    chmod +x "$tmp/cloudflared"
    if ! "$tmp/cloudflared" version 2>/dev/null | grep -Fq "$CLOUDFLARED_VERSION"; then
        rm -rf "$tmp"; err "cloudflared 版本校验失败，拒绝安装。"; return 1
    fi

    install -m 0755 "$xray_candidate" "$XRAY_BIN.new" || { rm -rf "$tmp"; return 1; }
    install -m 0755 "$tmp/cloudflared" "$CF_BIN.new" || { rm -f "$XRAY_BIN.new"; rm -rf "$tmp"; return 1; }
    mv -f "$XRAY_BIN.new" "$XRAY_BIN"
    mv -f "$CF_BIN.new" "$CF_BIN"
    rm -rf "$tmp"
    ok "固定版本已安装：Xray $XRAY_VERSION，cloudflared $CLOUDFLARED_VERSION。"
}

# ---------- 组件版本检查 / 升级（补齐 Xray 与 cloudflared 的升级通道）----------
# 设计：默认仍跑固定版本（可复现），但让用户能看见"有没有新版"并主动升级，
# 与 ShadowQuic 已有的 sq_check_update / sq_upgrade 保持一致。

# 查询类提示：只在 tty 下用 \r + 清行原地刷新；
# 非 tty（重定向到文件/管道）时改成一行普通提示，避免把 ESC 控制字符写进日志。
net_hint_begin() {
    if [ -t 2 ]; then printf '  %s...\r' "$1" >&2; else printf '  %s...\n' "$1" >&2; fi
}
net_hint_end() {
    [ -t 2 ] && printf '\033[K' >&2
    return 0
}

xray_latest_version() {
    local v
    net_hint_begin "正在查询 Xray 上游版本"
    v="$(curl -fsSL --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
         | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' | head -n 1)"
    net_hint_end
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

cloudflared_latest_version() {
    local v
    net_hint_begin "正在查询 cloudflared 上游版本"
    v="$(curl -fsSL --max-time 10 https://api.github.com/repos/cloudflare/cloudflared/releases/latest 2>/dev/null \
         | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' | head -n 1)"
    net_hint_end
    [ -n "$v" ] || return 1
    # cloudflared 的 tag 形如 2026.8.2，去掉可能的 v 前缀统一比较
    printf '%s' "${v#v}"
}

# 打印当前版本与上游最新版。返回 0 = 都是最新，2 = 有新版，1 = 检查失败。
version_check() {
    local xl cl xc cc rc=0
    info '检查组件最新版本（需要访问 api.github.com）...'
    xc="$(xray_version_ok && "$XRAY_BIN" version 2>/dev/null | head -n 1 | awk '{print $2}' || true)"
    cc="$(cloudflared_version_ok && "$CF_BIN" version 2>/dev/null | head -n 1 | awk '{print $3}' || true)"
    xl="$(xray_latest_version 2>/dev/null || true)"
    cl="$(cloudflared_latest_version 2>/dev/null || true)"
    printf '  Xray         当前 %-12s 脚本固定 %-12s 上游最新 %s\n' \
        "${xc:-未安装}" "$XRAY_VERSION" "${xl:-获取失败}"
    printf '  cloudflared  当前 %-12s 脚本固定 %-12s 上游最新 %s\n' \
        "${cc:-未安装}" "$CLOUDFLARED_VERSION" "${cl:-获取失败}"
    if [ -z "$xl" ] && [ -z "$cl" ]; then
        warn '无法获取上游版本（网络问题或 GitHub API 限流）。'
        return 1
    fi
    if [ -n "$xl" ] && [ "v${xc#v}" != "${xl#v}" ]; then rc=2; fi
    if [ -n "$cl" ] && [ "${cc#v}" != "${cl#v}" ]; then rc=2; fi
    if [ "$rc" = "0" ]; then ok '组件均为最新版本。'; fi
    return "$rc"
}

# 升级到指定版本：改全局变量 → 重算下载地址 → 复用 download_binaries → 写回 state → 重启
component_upgrade() {
    local which="$1" newver="$2" old x_old c_old
    need_root || return 1
    case "$which" in
        xray)        old="$XRAY_VERSION";        XRAY_VERSION="$newver" ;;
        cloudflared) old="$CLOUDFLARED_VERSION"; CLOUDFLARED_VERSION="$newver" ;;
        *) err "未知组件：$which"; return 1 ;;
    esac
    refresh_release_bases
    save_state
    # 只装指定组件：download_binaries 会同时校验两者，这里用它保证原子性与校验逻辑复用。
    # 传 1 表示"已确认过"——确认动作在 component_menu 里已经做过一次了。
    if ! download_binaries 1; then
        err "升级失败，已回滚版本号配置。"
        case "$which" in
            xray)        XRAY_VERSION="$old" ;;
            cloudflared) CLOUDFLARED_VERSION="$old" ;;
        esac
        refresh_release_bases
        save_state
        return 1
    fi
    # 二进制换了，必须重启才生效
    if [ -f "$STATE_FILE" ] && [ -f "$XRAY_CONFIG" ]; then
        restart_services || warn '组件已更新，但服务重启失败，请到菜单 4 手动重启。'
    fi
    ok "$which 已升级：$old → $newver"
    say "  版本已写入 $STATE_FILE，后续运行沿用该版本。"
    say "  如需回到脚本内置默认值：删除 state.env 里的 SUOHA_*_VERSION 行，或重新安装。"
}

component_menu() {
    while true; do
        banner
        say "${C_CYAN}组件版本${C_RESET}"
        printf '  Xray         : %s（脚本内置 %s）\n' \
            "$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}' || echo 未安装)" "$XRAY_VERSION"
        printf '  cloudflared  : %s（脚本内置 %s）\n' \
            "$("$CF_BIN" version 2>/dev/null | head -n1 | awk '{print $3}' || echo 未安装)" "$CLOUDFLARED_VERSION"
        printf '  shadowquic   : %s\n' "$(sq_local_version 2>/dev/null || echo 未安装)"
        say ""
        say '1) 检查上游最新版本'
        say '2) 升级 Xray 到上游最新版'
        say '3) 升级 cloudflared 到上游最新版'
        say '0) 返回主菜单'
        safe_read m '请选择 [0]: ' '0'
        local xl cl
        case "${m:-0}" in
            1) version_check; pause_screen ;;
            2)
                xl="$(xray_latest_version)" || { err '无法获取 Xray 最新版本。'; pause_screen; continue; }
                # 说明里必须点明"会顺带同步 cloudflared"，否则用户不知道实际会下载两个包。
                confirm_download "Xray $xl（当前 $XRAY_VERSION）" \
                    "会重新校验并替换 $XRAY_BIN；同时按当前版本同步 cloudflared $CLOUDFLARED_VERSION" \
                    "$XRAY_BIN" \
                    && component_upgrade xray "$xl"
                pause_screen
                ;;
            3)
                cl="$(cloudflared_latest_version)" || { err '无法获取 cloudflared 最新版本。'; pause_screen; continue; }
                confirm_download "cloudflared $cl（当前 $CLOUDFLARED_VERSION）" \
                    "会重新校验并替换 $CF_BIN；同时按当前版本同步 Xray $XRAY_VERSION" \
                    "$CF_BIN" \
                    && component_upgrade cloudflared "$cl"
                pause_screen
                ;;
            0|'') return 0 ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}
ensure_software() {
    install_dependencies || return 1
    if ! xray_version_ok || ! cloudflared_version_ok; then
        download_binaries || return 1
    fi
}

generate_reality_keys() {
    [ -x "$XRAY_BIN" ] || { err "Xray 尚未安装，无法生成 Reality 密钥。"; return 1; }
    local out priv pub sid hexchars i
    out="$("$XRAY_BIN" x25519 2>/dev/null)" || { err "xray x25519 密钥生成失败。"; return 1; }
    # 兼容新旧两种输出：旧版 "Private key:/Public key:"，新版 "PrivateKey:/Password (PublicKey):"
    priv="$(printf '%s\n' "$out" | grep -i 'private' | head -n 1 | awk '{print $NF}')"
    pub="$(printf '%s\n' "$out" | grep -i 'public' | head -n 1 | awk '{print $NF}')"
    if [ -z "$priv" ] || [ -z "$pub" ]; then
        err "无法解析 x25519 输出：$(printf '%s' "$out" | head -n 1)"
        return 1
    fi
    if command_exists openssl; then
        sid="$(openssl rand -hex 4)"
    else
        sid="$(od -An -tx1 -N4 /dev/urandom 2>/dev/null | tr -d ' \n')"
    fi
    REALITY_PRIVATE="$priv"; REALITY_PUBLIC="$pub"; REALITY_SHORT_ID="$sid"
    return 0
}

validate_reality() {
    case "$REALITY_ENABLED" in yes|no) ;; *) REALITY_ENABLED="no" ;; esac
    [ "$REALITY_ENABLED" = "yes" ] || return 0
    if ! [[ "$REALITY_PORT" =~ ^[0-9]+$ ]] || [ "$REALITY_PORT" -lt 1024 ] || [ "$REALITY_PORT" -gt 65535 ]; then
        err "Reality 端口必须是 1024-65535。"; return 1
    fi
    [ -n "$REALITY_DEST" ] || { err "Reality dest 不能为空。"; return 1; }
    # dest 会被原样插进 xray.json 的 JSON 字符串里，必须先做字符白名单，
    # 否则 " 或 } 能逃出 JSON 结构（对比：域名/隧道名/WS 路径本来就有白名单）。
    # 注意：bash 的 [[ =~ ]] 里不能写 \[\-]，实测会变成"任何值都不匹配"。
    # 方括号字符类必须把 ] 放最前、- 放最后（经 re_probe2.sh 验证：合法值 5/5 通过，非法值 6/6 拒绝）。
    if ! [[ "$REALITY_DEST" =~ ^[]A-Za-z0-9._:[-]+$ ]]; then
        err "Reality dest 只能包含域名、IPv4/IPv6 和端口字符（不能带引号、空格、斜杠）。"
        return 1
    fi
    case "$REALITY_DEST" in
        *:*) : ;;
        *) REALITY_DEST="$REALITY_DEST:443" ;;
    esac
    # 补完端口后检查端口段合法（域名:abc 这类要拦住）
    case "$REALITY_DEST" in
        *:*) 
            local _dport="${REALITY_DEST##*:}"
            if ! [[ "$_dport" =~ ^[0-9]+$ ]] || [ "$_dport" -lt 1 ] || [ "$_dport" -gt 65535 ]; then
                err "Reality dest 端口不合法：$_dport（应为 1-65535）。"
                return 1
            fi
            ;;
    esac
    [ -n "$REALITY_SNI" ] || { err "Reality SNI 不能为空。"; return 1; }
    # SNI 同样进入 serverNames 数组，走同一套白名单（不允许 : 和 [ ]）。
    if ! [[ "$REALITY_SNI" =~ ^[A-Za-z0-9._-]+$ ]]; then
        err "Reality SNI 只能包含字母、数字、点、下划线、连字符（不能带端口/方括号/引号）。"
        return 1
    fi
    [ -n "$REALITY_PRIVATE" ] || { err "缺少 Reality 私钥，请重新安装 Reality 节点。"; return 1; }
    [ -n "$REALITY_PUBLIC" ] || { err "缺少 Reality 公钥，请重新安装 Reality 节点。"; return 1; }
    # 私钥/公钥是 base64url，同样塞进 JSON，做白名单避免同级别注入。
    if ! [[ "$REALITY_PRIVATE" =~ ^[A-Za-z0-9_+/=-]+$ ]] || ! [[ "$REALITY_PUBLIC" =~ ^[A-Za-z0-9_+/=-]+$ ]]; then
        err "Reality 密钥包含非法字符。"
        return 1
    fi
    if ! [[ "$REALITY_SHORT_ID" =~ ^[0-9a-f]*$ ]] || [ $(( ${#REALITY_SHORT_ID} % 2 )) -ne 0 ] || [ "${#REALITY_SHORT_ID}" -gt 16 ]; then
        err "Reality shortId 必须是 0-f 的偶数长度十六进制（最长16位）。"; return 1
    fi
    return 0
}

rotate_log() {
    local f="$1" max="${2:-10485760}" sz
    [ -f "$f" ] || return 0
    sz="$(wc -c < "$f" 2>/dev/null || printf 0)"
    [ "$sz" -gt "$max" ] 2>/dev/null || return 0
    tail -c 1048576 "$f" > "$f.rot" 2>/dev/null && mv -f "$f.rot" "$f" 2>/dev/null || true
}

rotate_all_logs() {
    rotate_log "$XRAY_LOG" 10485760
    rotate_log "$CF_LOG" 10485760
}

write_xray_config() {
    validate_common || return 1
    validate_reality || return 1
    mkdir -p "$APP_DIR" "$LOG_DIR" || return 1
    local tmp tmpdir
    tmpdir="$(mktemp -d "$APP_DIR/.xcfg.XXXXXX")" || return 1
    cleanup_register "$tmpdir"
    tmp="$tmpdir/config.json"
    if [ "$REALITY_ENABLED" = "yes" ]; then
        cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$REALITY_DEST",
          "serverNames": [ "$REALITY_SNI" ],
          "privateKey": "$REALITY_PRIVATE",
          "shortIds": [ "$REALITY_SHORT_ID" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ],
        "routeOnly": true
      }
    },
    {
      "listen": "127.0.0.1",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [ { "id": "$UUID" } ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "settings": {} } ]
}
EOF
    elif [ "$PROTOCOL" = "vmess" ]; then
        cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $XRAY_PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          { "id": "$UUID", "alterId": 0 }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "settings": {} } ]
}
EOF
    else
        cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [ { "id": "$UUID" } ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "settings": {} } ]
}
EOF
    fi
    chmod 600 "$tmp"
    if [ -x "$XRAY_BIN" ] && ! "$XRAY_BIN" run -test -config "$tmp" >/dev/null 2>&1; then
        err "Xray 配置校验失败，保留原配置。"
        "$XRAY_BIN" run -test -config "$tmp" 2>&1 | tail -n 10
        rm -rf "$tmpdir"
        return 1
    fi
    [ -f "$XRAY_CONFIG" ] && cp -f "$XRAY_CONFIG" "$XRAY_CONFIG.bak"
    mv -f "$tmp" "$XRAY_CONFIG"
}

write_cloudflared_config() {
    [ "$MODE" = "persistent" ] || return 0
    [ -n "$TUNNEL_ID" ] || { err "还没有 Cloudflare Tunnel ID。"; return 1; }
    validate_domain "$DOMAIN" || { err "域名格式不正确：$DOMAIN"; return 1; }
    mkdir -p "$APP_DIR" || return 1
    local tmp credentials
    credentials="/root/.cloudflared/$TUNNEL_ID.json"
    tmp="$(mktemp "$APP_DIR/config.yaml.XXXXXX")" || return 1
    cat > "$tmp" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $credentials
protocol: "$CF_PROTOCOL"
edge-ip-version: "$EDGE_IP"
no-autoupdate: true

ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:$XRAY_PORT
  - service: http_status:404
EOF
    chmod 600 "$tmp"
    [ -f "$CF_CONFIG" ] && cp -f "$CF_CONFIG" "$CF_CONFIG.bak"
    mv -f "$tmp" "$CF_CONFIG"
}

base64_no_wrap() {
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w 0
    else
        base64 | tr -d '\n'
    fi
}

url_label() {
    printf '%s' "${1:-SuohaPlus}" | sed 's/%/%25/g; s/ /%20/g; s/#/%23/g; s/&/%26/g; s/?/%3F/g; s/,/%2C/g'
}

current_tunnel_host() {
    if [ "$MODE" = "quick" ]; then
        local h="${QUICK_URL#https://}"
        h="${h%%/*}"
        printf '%s' "$h"
    else
        printf '%s' "$DOMAIN"
    fi
}

generate_nodes() {
    mkdir -p "$APP_DIR" || return 1
    local host label tmp json path_q ip4 ip6 raddr ra4 ra6
    host="$(current_tunnel_host)"
    label="$(url_label "$ISP_TAG")"
    ip4="$(public_ip 2>/dev/null || true)"
    ip6="$(public_ip6 2>/dev/null || true)"
    ip6="${ip6#[}"
    # Reality 连接地址解析：setup_reality 里让用户填的 NODE_ADDRESS 必须真正生效，
    # 否则用户指定域名/指定 IP 会被静默忽略（v2.5.0 的缺陷）。
    # 带 [ ] 的是 IPv6，裸域名/IPv4 直接可用；只产出用户指定的那一条，
    # 未指定（空）时才回退到自动探测的 v4/v6 双栈链接。
    raddr="${NODE_ADDRESS:-}"
    ra4=""; ra6=""
    case "$raddr" in
        \[*\])
            ra6="${raddr#\[}"; ra6="${ra6%\]}"
            ;;
        *:*)
            # 裸 IPv6（用户没写方括号）也需要加方括号才能拼进 URL
            ra6="$raddr"
            ;;
        "")
            ra4="$ip4"; ra6="$ip6"
            ;;
        *)
            ra4="$raddr"
            ;;
    esac
    tmp="$(mktemp "$APP_DIR/v2ray.txt.XXXXXX")" || return 1
    {
        printf '# Suoha Plus 节点信息（自动生成，请勿手动编辑）\n'
        printf '# Xray %s | cloudflared %s\n' "$XRAY_VERSION" "$CLOUDFLARED_VERSION"
        if [ "$REALITY_ENABLED" = "yes" ]; then
            printf '# Reality 直连节点 | 端口：%s | SNI：%s | 同时监听 IPv4 + IPv6\n\n' "$REALITY_PORT" "$REALITY_SNI"
            if [ -n "$ra4" ]; then
                printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s_reality_v4\n' "$UUID" "$ra4" "$REALITY_PORT" "$REALITY_SNI" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$label"
            fi
            if [ -n "$ra6" ]; then
                printf 'vless://%s@[%s]:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s_reality_v6\n' "$UUID" "$ra6" "$REALITY_PORT" "$REALITY_SNI" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$label"
            fi
            printf '\n# 提示：Reality 为 VPS 直连，无需域名/隧道/优选；fp 也可试 ios、safari\n'
            if [ -n "$raddr" ]; then
                printf '# 连接地址：%s（安装 Reality 时指定）\n' "$raddr"
            else
                printf '# IPv4/IPv6 两条链接二选一：有 v6 用 v6（NAT 机器端口全开），只有 v4 用 v4\n'
                printf '# 如需固定为某个域名/IP，重新安装 Reality 时在「节点连接地址」处填写\n'
            fi
            if [ -n "$host" ]; then
                path_q="$(printf '%s' "$WS_PATH" | sed 's/%/%25/g; s#/#%2F#g')"
                printf '\n# —— WS+隧道节点（与 Reality 共存，域名固定）——\n\n'
                printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s_tls\n' "$UUID" "$host" "$host" "$host" "$path_q" "$label"
                printf '\n# TLS 端口可尝试：443、2053、2083、2087、2096、8443\n'
                printf 'vless://%s@%s:80?encryption=none&security=none&type=ws&host=%s&path=%s#%s\n' "$UUID" "$NODE_ADDRESS" "$host" "$path_q" "$label"
                printf '# 明文端口可尝试：80、8080、8880、2052、2082、2086、2095\n'
                printf '# 注意：WS 节点的 443 走隧道域名；80 走 NODE_ADDRESS 优选地址\n'
            fi
        elif [ -z "$host" ]; then
            printf '# 隧道尚未启动，启动成功后再次运行本脚本即可生成节点。\n'
        elif [ "$PROTOCOL" = "vmess" ]; then
            json="$(printf '{"v":"2","ps":"%s_tls","add":"%s","port":"443","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s"}' "$ISP_TAG" "$NODE_ADDRESS" "$UUID" "$host" "$WS_PATH" "$host")"
            printf 'vmess://%s\n' "$(printf '%s' "$json" | base64_no_wrap)"
            printf '\n# TLS 端口可尝试：443、2053、2083、2087、2096、8443\n'
            json="$(printf '{"v":"2","ps":"%s","add":"%s","port":"80","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"%s","tls":""}' "$ISP_TAG" "$NODE_ADDRESS" "$UUID" "$host" "$WS_PATH")"
            printf 'vmess://%s\n' "$(printf '%s' "$json" | base64_no_wrap)"
            printf '# 明文端口可尝试：80、8080、8880、2052、2082、2086、2095\n'
        else
            path_q="$(printf '%s' "$WS_PATH" | sed 's/%/%25/g; s#/#%2F#g')"
            printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s_tls\n' "$UUID" "$NODE_ADDRESS" "$host" "$host" "$path_q" "$label"
            printf '\n# TLS 端口可尝试：443、2053、2083、2087、2096、8443\n'
            printf 'vless://%s@%s:80?encryption=none&security=none&type=ws&host=%s&path=%s#%s\n' "$UUID" "$NODE_ADDRESS" "$host" "$path_q" "$label"
            printf '# 明文端口可尝试：80、8080、8880、2052、2082、2086、2095\n'
        fi
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$NODE_FILE"
    # ShadowQuic 链接追加到节点文件
    if [ -f "$SQ_APP_DIR/server-direct.yaml" ]; then
        local sq_u sq_p sq_host sq_label
        sq_u="$(sed -n 's/.*username: "\([^"]*\)".*/\1/p' "$SQ_APP_DIR/server-direct.yaml" 2>/dev/null | head -1)"
        sq_p="$(sed -n 's/.*password: "\([^"]*\)".*/\1/p' "$SQ_APP_DIR/server-direct.yaml" 2>/dev/null | head -1)"
        sq_host="$(sed -n 's/.*server-name: "\([^"]*\)".*/\1/p' "$SQ_APP_DIR/server-direct.yaml" 2>/dev/null | head -1)"
        sq_label="$(url_label "${ISP_TAG}_sq")"
        {
            printf '\n# —— ShadowQuic 节点（UDP :%s，sq:// 部分客户端支持）——\n\n' "$SQ_PORT"
            if [ -n "$(public_ip 2>/dev/null)" ]; then
                printf 'sq://%s:%s@%s:%s?alpn=h3&mtu=1280&sni=%s&udp_mode=datagram&zero_rtt=true#%s_v4\n' "$sq_u" "$sq_p" "$(public_ip)" "$SQ_PORT" "$sq_host" "$sq_label"
            fi
            local sq6; sq6="$(public_ip6 2>/dev/null)"; sq6="${sq6#[}"
            if [ -n "$sq6" ]; then
                printf 'sq://%s:%s@[%s]:%s?alpn=h3&mtu=1280&sni=%s&udp_mode=datagram&zero_rtt=true#%s_v6\n' "$sq_u" "$sq_p" "$sq6" "$SQ_PORT" "$sq_host" "$sq_label"
            fi
            printf '\n# ShadowQuic 配置：/etc/shadowquic/server-direct.yaml（直连出站）/ server-socks.yaml（SOCKS出站）/ last-mode\n'
        } >> "$NODE_FILE"
    fi
}

print_nodes() {
    [ -f "$NODE_FILE" ] || generate_nodes || return 1
    say "${C_GREEN}──────── 当前节点信息 ────────${C_RESET}"
    cat "$NODE_FILE"
    say "${C_GREEN}──────────────────────────────${C_RESET}"
    info "节点文件：$NODE_FILE"
    # ShadowQuic sq:// 分享链接（部分客户端支持）
    if [ -f "$SQ_APP_DIR/server-direct.yaml" ]; then
        local sq_u sq_p sq_host sq_label
        sq_u="$(sed -n 's/.*username: "\([^"]*\)".*/\1/p' "$SQ_APP_DIR/server-direct.yaml" 2>/dev/null | head -1)"
        sq_p="$(sed -n 's/.*password: "\([^"]*\)".*/\1/p' "$SQ_APP_DIR/server-direct.yaml" 2>/dev/null | head -1)"
        sq_host="$(sed -n 's/.*server-name: "\([^"]*\)".*/\1/p' "$SQ_APP_DIR/server-direct.yaml" 2>/dev/null | head -1)"
        sq_label="$(url_label "${ISP_TAG}_sq")"
        say ""
        say "${C_CYAN}—— ShadowQuic 节点（sq:// 分享链接，部分客户端支持）——${C_RESET}"
        local sq_v4 sq_v6
        sq_v4="$(public_ip 2>/dev/null || true)"
        sq_v6="$(public_ip6 2>/dev/null || true)"
        sq_v6="${sq_v6#[}"
        if [ -n "$sq_v4" ]; then
            printf 'sq://%s:%s@%s:%s?alpn=h3&mtu=1280&sni=%s&udp_mode=datagram&zero_rtt=true#%s_v4\n' "$sq_u" "$sq_p" "$sq_v4" "$SQ_PORT" "$sq_host" "$sq_label"
        fi
        if [ -n "$sq_v6" ]; then
            printf 'sq://%s:%s@[%s]:%s?alpn=h3&mtu=1280&sni=%s&udp_mode=datagram&zero_rtt=true#%s_v6\n' "$sq_u" "$sq_p" "$sq_v6" "$SQ_PORT" "$sq_host" "$sq_label"
        fi
        say "配置文件：$SQ_APP_DIR/server-direct.yaml（直连出站） / $SQ_APP_DIR/server-socks.yaml（SOCKS出站）"
    fi
}

pid_running() { [ -r "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }

SCRIPT_SELF="${SUOHA_SELF:-$0}"

install_cmd_link() {
    [ -n "$SCRIPT_SELF" ] || return 0
    [ -f "$SCRIPT_SELF" ] || return 0
    mkdir -p "$(dirname "$CMD_LINK")" 2>/dev/null || true
    # 脚本可能是 curl -o 下载的（无执行位），软链过去会 Permission denied。
    [ -x "$SCRIPT_SELF" ] || chmod +x "$SCRIPT_SELF" 2>/dev/null || true
    # 把脚本固定一份到 APP_DIR，避免软链指向 /tmp 或临时副本后被删导致命令失效。
    local stable="$APP_DIR/suoha-manager.sh"
    if [ "$(cd "$(dirname "$SCRIPT_SELF")" 2>/dev/null && pwd)/$(basename "$SCRIPT_SELF")" != "$stable" ]; then
        mkdir -p "$APP_DIR" 2>/dev/null || true
        cp -f "$SCRIPT_SELF" "$stable" 2>/dev/null || true
        chmod +x "$stable" 2>/dev/null || true
    fi
    if [ -x "$stable" ]; then
        ln -sf "$stable" "$CMD_LINK" 2>/dev/null || true
    else
        ln -sf "$SCRIPT_SELF" "$CMD_LINK" 2>/dev/null || true
    fi
    return 0
}

stop_pid() {
    local file="$1" pid i
    if [ -r "$file" ]; then
        pid="$(cat "$file" 2>/dev/null)"
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            kill "$pid" 2>/dev/null || true
            i=0
            while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$file"
    fi
}
start_xray() {
    [ -x "$XRAY_BIN" ] || { err "Xray 尚未安装。"; return 1; }
    [ -f "$XRAY_CONFIG" ] || write_xray_config || return 1
    # 只要存在服务单元（systemd/OpenRC）就由 init 管理，避免 nohup 双实例
    if has_systemd && { [ "$MODE" = "persistent" ] || [ -f "/etc/systemd/system/$SERVICE_XRAY" ]; }; then
        lock_release
        systemctl start "$SERVICE_XRAY"
        return $?
    fi
    if has_openrc && { [ "$MODE" = "persistent" ] || [ -f "/etc/init.d/suoha-plus-xray" ]; }; then
        # 已 started 时用 restart，避免 supervise-daemon 再叠一个实例
        lock_release
        _ost="$(rc-service suoha-plus-xray status 2>&1 || true)"
        case "$_ost" in
            *started*) rc-service suoha-plus-xray restart >/dev/null 2>&1 || return 1 ;;
            *) rc-service suoha-plus-xray start >/dev/null 2>&1 || return 1 ;;
        esac
        return 0
    fi
    stop_pid "$XRAY_PID"
    nohup "$XRAY_BIN" run -config "$XRAY_CONFIG" >> "$XRAY_LOG" 2>&1 < /dev/null 9>&- &
    echo $! > "$XRAY_PID"
    sleep 1
    if ! pid_running "$XRAY_PID"; then
        err "Xray 启动失败，日志：$XRAY_LOG"
        tail -n 20 "$XRAY_LOG" 2>/dev/null || true
        return 1
    fi
    ok "Xray 已启动。"
}

start_quick_tunnel() {
    [ "$MODE" = "quick" ] || return 1
    [ -x "$CF_BIN" ] || { err "cloudflared 尚未安装。"; return 1; }
    stop_pid "$CF_PID"
    : > "$CF_LOG"
    nohup "$CF_BIN" tunnel --url "http://127.0.0.1:$XRAY_PORT" --no-autoupdate --edge-ip-version "$EDGE_IP" --protocol "$CF_PROTOCOL" > "$CF_LOG" 2>&1 < /dev/null 9>&- &
    echo $! > "$CF_PID"
    QUICK_URL=""
    local i
    for i in $(seq 1 30); do
        sleep 1
        QUICK_URL="$(grep -Eo 'https://[A-Za-z0-9-]+\.trycloudflare\.com' "$CF_LOG" | head -n 1)"
        [ -n "$QUICK_URL" ] && break
        if ! pid_running "$CF_PID"; then break; fi
    done
    if [ -z "$QUICK_URL" ]; then
        err "Quick Tunnel 未生成地址，日志：$CF_LOG"
        tail -n 30 "$CF_LOG" 2>/dev/null || true
        return 1
    fi
    save_state
    generate_nodes
    ok "Quick Tunnel 已启动：$QUICK_URL"
}

start_persistent_tunnel() {
    [ "$MODE" = "persistent" ] || [ "$REALITY_ENABLED" = "yes" ] || return 1
    [ -x "$CF_BIN" ] || { err "cloudflared 尚未安装。"; return 1; }
    # Reality 共存模式：没有隧道配置则静默跳过（纯直连场景）
    if [ "$MODE" = "reality" ] && [ ! -f "$CF_CONFIG" ]; then
        return 0
    fi
    [ -f "$CF_CONFIG" ] || write_cloudflared_config || return 1
    # 单元存在则走 init 管理
    if has_systemd && { [ -f "/etc/systemd/system/$SERVICE_CF" ] || [ "$MODE" = "persistent" ]; }; then
        lock_release
        systemctl start "$SERVICE_CF"
        return $?
    fi
    if has_openrc && { [ -f "/etc/init.d/suoha-plus-cloudflared" ] || [ "$MODE" = "persistent" ]; }; then
        lock_release
        rc-service suoha-plus-cloudflared start 2>/dev/null || return 1
        return 0
    fi
    stop_pid "$CF_PID"
    nohup "$CF_BIN" tunnel --config "$CF_CONFIG" run "$TUNNEL_NAME" >> "$CF_LOG" 2>&1 < /dev/null 9>&- &
    echo $! > "$CF_PID"
    sleep 2
    if ! pid_running "$CF_PID"; then
        err "Cloudflare Tunnel 启动失败，日志：$CF_LOG"
        tail -n 20 "$CF_LOG" 2>/dev/null || true
        return 1
    fi
    ok "Cloudflare Tunnel 已启动。"
}

stop_services() {
    if has_systemd; then
        systemctl stop "$SERVICE_CF" 2>/dev/null || true
        systemctl stop "$SERVICE_XRAY" 2>/dev/null || true
    fi
    if has_openrc; then
        rc-service suoha-plus-cloudflared stop >/dev/null 2>&1 || true
        rc-service suoha-plus-xray stop >/dev/null 2>&1 || true
        pkill -f 'supervise-daemon suoha-plus-' 2>/dev/null || true
    fi
    stop_pid "$CF_PID"
    stop_pid "$XRAY_PID"
    # pidfile 可能因重复安装被覆盖，导致旧的后台进程失去追踪。
    # 按本项目的二进制绝对路径兜底清理，只杀 $APP_DIR/bin 下的进程，不误伤别人。
    pkill -f "$BIN_DIR/cloudflared" 2>/dev/null || true
    pkill -f "$BIN_DIR/xray" 2>/dev/null || true
    ok "增强版服务已停止。"
}

restart_services() {
    need_root || return 1
    [ -f "$XRAY_CONFIG" ] || { err "还没有配置，请先安装一种模式。"; return 1; }
    if [ "$REALITY_ENABLED" = "yes" ]; then
        stop_services
        start_xray || return 1
        # Reality 共存模式：有隧道配置就一并重启
        if [ -f "$CF_CONFIG" ]; then
            start_persistent_tunnel || return 1
        fi
    elif [ "$MODE" = "persistent" ]; then
        write_cloudflared_config || return 1
        if has_systemd; then
            install_systemd_units || return 1
        fi
        if has_systemd; then
            systemctl restart "$SERVICE_XRAY" && systemctl restart "$SERVICE_CF" || return 1
        else
            stop_services
            start_xray || return 1
            start_persistent_tunnel || return 1
        fi
        QUICK_URL=""
    else
        stop_services
        start_xray || return 1
        start_quick_tunnel || return 1
    fi
    save_state
    generate_nodes
    ok "Xray、Cloudflare Tunnel 和节点信息已同步更新。"
}

install_systemd_units() {
    has_systemd || { warn "未检测到 systemd，将使用后台进程方式运行。"; return 0; }
    mkdir -p /etc/systemd/system || return 1
    cat > "/etc/systemd/system/$SERVICE_XRAY" <<EOF
[Unit]
Description=Suoha Plus Xray
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    # Quick 模式隧道无持久配置/单元，跳过 CF 单元
    if [ "$MODE" != "quick" ] && { [ "$MODE" = "persistent" ] || [ -f "$CF_CONFIG" ]; }; then
    cat > "/etc/systemd/system/$SERVICE_CF" <<EOF
[Unit]
Description=Suoha Plus Cloudflare Tunnel
Wants=network-online.target
After=network-online.target $SERVICE_XRAY

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$CF_BIN tunnel --config $CF_CONFIG run $TUNNEL_NAME
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    fi
    chmod 644 "/etc/systemd/system/$SERVICE_XRAY" 2>/dev/null
    [ -f "/etc/systemd/system/$SERVICE_CF" ] && chmod 644 "/etc/systemd/system/$SERVICE_CF"
    systemctl daemon-reload
    systemctl enable "$SERVICE_XRAY" >/dev/null
    [ -f "/etc/systemd/system/$SERVICE_CF" ] && systemctl enable "$SERVICE_CF" >/dev/null
    ok "已写入独立 systemd 服务：$SERVICE_XRAY"
    if [ -f "/etc/systemd/system/$SERVICE_CF" ]; then
        ok "已写入独立 systemd 服务：$SERVICE_CF"
    fi
    return 0
}

install_openrc_units() {
    has_openrc || return 0
    # 重写单元前必须先停掉旧实例：OpenRC 的 supervise-daemon 不会因重写脚本
    # 而替换已有 supervisor，反复安装会累积多个 supervise + 多个 xray 进程。
    if [ -f /etc/init.d/suoha-plus-xray ]; then
        rc-service suoha-plus-xray stop >/dev/null 2>&1 || true
    fi
    if [ -f /etc/init.d/suoha-plus-cloudflared ]; then
        rc-service suoha-plus-cloudflared stop >/dev/null 2>&1 || true
    fi
    pkill -f 'supervise-daemon suoha-plus-' 2>/dev/null || true
    sleep 1
    mkdir -p /etc/init.d || return 1
    OINIT_XRAY="/etc/init.d/suoha-plus-xray"
    OINIT_CF="/etc/init.d/suoha-plus-cloudflared"
    # wrapper 脚本：让 supervise-daemon 只监督一个简单命令，避免 command_args 瑕疵导致监督失效
    cat > /usr/local/bin/suoha-xray-daemon.sh <<DAEMON
#!/bin/sh
mkdir -p $LOG_DIR || exit 1
exec $XRAY_BIN run -config $XRAY_CONFIG >> $XRAY_LOG 2>&1
DAEMON
    chmod +x /usr/local/bin/suoha-xray-daemon.sh
    cat > /usr/local/bin/suoha-cloudflared-daemon.sh <<DAEMON
#!/bin/sh
mkdir -p $LOG_DIR || exit 1
exec $CF_BIN tunnel --config $CF_CONFIG run $TUNNEL_NAME >> $CF_LOG 2>&1
DAEMON
    chmod +x /usr/local/bin/suoha-cloudflared-daemon.sh
    cat > "$OINIT_XRAY" <<EOF
#!/sbin/openrc-run
name="suoha-plus-xray"
description="Suoha Plus Xray"
supervisor=supervise-daemon
command="/usr/local/bin/suoha-xray-daemon.sh"
command_background="yes"
pidfile="$XRAY_PID"
output_log="$XRAY_LOG"
error_log="$XRAY_LOG"
respawn_delay=5
respawn_max=0
depend() { need net; after firewall; }
EOF
    cat > "$OINIT_CF" <<EOF
#!/sbin/openrc-run
name="suoha-plus-cloudflared"
description="Suoha Plus Cloudflare Tunnel"
supervisor=supervise-daemon
command="/usr/local/bin/suoha-cloudflared-daemon.sh"
command_background="yes"
pidfile="$CF_PID"
output_log="$CF_LOG"
error_log="$CF_LOG"
respawn_delay=5
respawn_max=0
depend() { need net; after firewall $OINIT_XRAY; }
EOF
    chmod 755 "$OINIT_XRAY"
    rc-update add suoha-plus-xray default >/dev/null 2>&1 || true
    # Quick 模式隧道无持久配置/单元，跳过 CF 单元
    if [ "$MODE" != "quick" ] && { [ "$MODE" = "persistent" ] || [ -f "$CF_CONFIG" ]; }; then
        chmod 755 "$OINIT_CF"
        rc-update add suoha-plus-cloudflared default >/dev/null 2>&1 || true
    else
        rm -f "$OINIT_CF" /usr/local/bin/suoha-cloudflared-daemon.sh
    fi
    ok "已写入 OpenRC 服务：suoha-plus-xray"
    if [ -f "$OINIT_CF" ]; then
        ok "已写入 OpenRC 服务：suoha-plus-cloudflared"
    fi
    # 显式返回成功：上面最后一条 [ -f ] 在 Reality/Quick 模式下为假，
    # 若作为函数返回值会让调用方的 `|| return 1` 误判安装失败。
    return 0
}

remove_systemd_units() {
    if has_systemd; then
        systemctl disable --now "$SERVICE_CF" "$SERVICE_XRAY" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$SERVICE_CF" "/etc/systemd/system/$SERVICE_XRAY"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if has_openrc; then
        rc-service suoha-plus-cloudflared stop 2>/dev/null || true
        rc-service suoha-plus-xray stop 2>/dev/null || true
        rc-update del suoha-plus-cloudflared default >/dev/null 2>&1 || true
        rc-update del suoha-plus-xray default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/suoha-plus-cloudflared" "/etc/init.d/suoha-plus-xray"
        rm -f /usr/local/bin/suoha-xray-daemon.sh /usr/local/bin/suoha-cloudflared-daemon.sh
    fi
}

cloudflare_login() {
    mkdir -p /root/.cloudflared
    if [ -f /root/.cloudflared/cert.pem ]; then
        info "检测到 /root/.cloudflared/cert.pem 授权文件，跳过登录。"
        return 0
    fi
    say "将调用 cloudflared tunnel login。请复制终端显示的链接到浏览器，并授权一个 Cloudflare 域名。"
    "$CF_BIN" tunnel login || { err "Cloudflare 登录失败。"; return 1; }
}

cf_delete_tunnel_record() {
    # 删除 Cloudflare 账号上的同名隧道记录（先清理残留连接）
    local name="$1"
    [ -x "$CF_BIN" ] || return 1
    "$CF_BIN" tunnel cleanup "$name" >/dev/null 2>&1 || true
    "$CF_BIN" tunnel delete -f "$name" >/dev/null 2>&1
}

cf_full_cleanup() {
    warn '将清理 Suoha Plus 同名 Tunnel 及其本地凭据；不会删除 /root/.cloudflared 中其他项目的授权或凭据。'
    stop_services 2>/dev/null || true
    cf_delete_tunnel_record "$TUNNEL_NAME" && ok "已删除账号上的旧隧道：$TUNNEL_NAME" || warn "旧隧道删除失败（可能已不存在），继续。"
    if [[ "$TUNNEL_ID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        rm -f "/root/.cloudflared/$TUNNEL_ID.json"
    fi
    rm -f "$APP_DIR/tunnel-create.log" "$CF_CONFIG"
    TUNNEL_ID=""
    ok 'Suoha Plus 本地 Tunnel 凭据已清理；其他 Cloudflare 配置保持不变。'
}

find_tunnel_id() {
    local output id
    output="$1"
    id="$(printf '%s\n' "$output" | grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}' | head -n 1)"
    if [ -n "$id" ]; then printf '%s' "$id"; return 0; fi
    "$CF_BIN" tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '
        $0 ~ n { for (i=1; i<=NF; i++) if ($i ~ /^[0-9a-fA-F-]{36}$/) { print $i; exit } }
    '
}

ensure_named_tunnel() {
    cloudflare_login || return 1
    mkdir -p /root/.cloudflared
    local listed existing_id output
    listed="$($CF_BIN tunnel list 2>/dev/null || true)"
    existing_id="$(printf '%s\n' "$listed" | awk -v n="$TUNNEL_NAME" 'index($0,n) { for (i=1; i<=NF; i++) if ($i ~ /^[0-9a-fA-F-]{36}$/) { print $i; exit } }')"
    if [ -n "$existing_id" ]; then
        TUNNEL_ID="$existing_id"
    else
        TUNNEL_ID=""
    fi
    if [ -n "$TUNNEL_ID" ] && [ -f "/root/.cloudflared/$TUNNEL_ID.json" ]; then
        return 0
    fi
    # 账号上已有同名旧隧道但本地缺凭据 → 删除重建，避免 create 失败
    if [ -n "$TUNNEL_ID" ]; then
        warn "检测到账号上已有同名隧道 $TUNNEL_NAME 但本地凭据缺失，正在删除重建..."
        cf_delete_tunnel_record "$TUNNEL_NAME" || { err "旧隧道删除失败，请手动处理：cloudflared tunnel delete -f $TUNNEL_NAME"; return 1; }
        TUNNEL_ID=""
    fi
    output="$($CF_BIN tunnel create "$TUNNEL_NAME" 2>&1)"
    printf '%s\n' "$output" > "$APP_DIR/tunnel-create.log"
    TUNNEL_ID="$(find_tunnel_id "$output")"
    if [ -z "$TUNNEL_ID" ]; then
        err "无法从 cloudflared 输出中取得 Tunnel ID。详细输出：$APP_DIR/tunnel-create.log"
        printf '%s\n' "$output"
        return 1
    fi
    if [ ! -f "/root/.cloudflared/$TUNNEL_ID.json" ]; then
        err "Tunnel 创建成功但凭据文件不存在：/root/.cloudflared/$TUNNEL_ID.json"
        return 1
    fi
    ok "Tunnel 已准备：$TUNNEL_NAME ($TUNNEL_ID)"
}

route_domain() {
    [ "$MODE" = "persistent" ] || return 0
    validate_domain "$DOMAIN" || { err "域名格式不正确：$DOMAIN"; return 1; }
    say "正在把 $DOMAIN 路由到 Tunnel $TUNNEL_NAME ..."
    if "$CF_BIN" tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$DOMAIN"; then
        ok "DNS 路由已更新。"
    else
        err "DNS 路由更新失败；请确认域名已托管到当前 Cloudflare 账号。"
        return 1
    fi
}

configure_xray() {
    local v p u w
    v="$(ask_default 'Xray 协议（vmess/vless）' "$PROTOCOL")"
    p="$(ask_default 'Xray 本地监听端口（仅本机）' "$XRAY_PORT")"
    u="$(ask_default 'UUID' "$UUID")"
    w="$(ask_default 'WebSocket 路径' "$WS_PATH")"
    case "$v" in vmess|vless) PROTOCOL="$v" ;; *) err "协议只能是 vmess 或 vless。"; return 1 ;; esac
    XRAY_PORT="$p"; UUID="$u"; WS_PATH="$w"
    validate_common || return 1
}

configure_tunnel() {
    local e p a d n
    e="$(ask_default 'Cloudflare 边缘 IP 版本（4/6）' "$EDGE_IP")"
    p="$(ask_default 'Cloudflare 隧道传输协议（auto/quic/http2）' "$CF_PROTOCOL")"
    a="$(ask_default '节点连接地址（可填优选域名/IP）' "$NODE_ADDRESS")"
    EDGE_IP="$e"; CF_PROTOCOL="$p"; NODE_ADDRESS="$a"
    if [ "$MODE" = "persistent" ]; then
        d="$(ask_default '绑定域名（完整二级域名）' "$DOMAIN")"
        n="$(ask_default 'Tunnel 名称' "$TUNNEL_NAME")"
        DOMAIN="$d"; TUNNEL_NAME="$n"
        validate_domain "$DOMAIN" || { err "域名格式不正确。"; return 1; }
        validate_tunnel_name "$TUNNEL_NAME" || { err "Tunnel 名称只能包含字母、数字、下划线和连字符。"; return 1; }
    fi
    validate_common || return 1
}

apply_config_now() {
    need_root || return 1
    ensure_software || return 1
    write_xray_config || return 1
    if [ "$MODE" = "persistent" ]; then
        # 隧道名称改变时，准备对应 Tunnel；域名改变时同步 DNS 路由。
        ensure_named_tunnel || return 1
        route_domain || return 1
        write_cloudflared_config || return 1
    fi
    save_state
    restart_services || return 1
    generate_nodes
    print_nodes
}

# ---------- 安装事务：失败时还原旧配置并重新拉起旧服务 ----------
# 实测事故：旧实现在 setup_* 一进来就 stop_services + remove_systemd_units，
# 之后才做参数校验。用户重装时填错一个字段就直接 return，此时服务单元已被删除、
# 进程已停止，脚本却回主菜单返回 0 —— 原本正常的节点当场断掉且不会自己回来。
# 现在改为：先做所有可能失败的步骤（下载/密钥/参数校验/写配置），最后才动服务；
# 动服务前快照配置与状态，任何一步失败都回滚并把原服务重新拉起来。
_TXN_ACTIVE=0
_TXN_DIR=""
_TXN_HAD_SERVICE="no"

txn_begin() {
    _TXN_ACTIVE=0
    mkdir -p "$TMP_DIR" 2>/dev/null || true
    _TXN_DIR="$(mktemp -d "${TMP_DIR:-/tmp}/txn.XXXXXX" 2>/dev/null)" || return 1
    local f
    for f in "$XRAY_CONFIG" "$CF_CONFIG" "$STATE_FILE"; do
        [ -f "$f" ] && cp -f "$f" "$_TXN_DIR/$(basename "$f")" 2>/dev/null
    done
    {
        printf 'MODE=%q\n' "$MODE"
        printf 'PROTOCOL=%q\n' "$PROTOCOL"
        printf 'EDGE_IP=%q\n' "$EDGE_IP"
        printf 'CF_PROTOCOL=%q\n' "$CF_PROTOCOL"
        printf 'NODE_ADDRESS=%q\n' "$NODE_ADDRESS"
        printf 'UUID=%q\n' "$UUID"
        printf 'WS_PATH=%q\n' "$WS_PATH"
        printf 'XRAY_PORT=%q\n' "$XRAY_PORT"
        printf 'QUICK_URL=%q\n' "$QUICK_URL"
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'TUNNEL_NAME=%q\n' "$TUNNEL_NAME"
        printf 'TUNNEL_ID=%q\n' "$TUNNEL_ID"
        printf 'REALITY_ENABLED=%q\n' "$REALITY_ENABLED"
        printf 'REALITY_PORT=%q\n' "$REALITY_PORT"
        printf 'REALITY_DEST=%q\n' "$REALITY_DEST"
        printf 'REALITY_SNI=%q\n' "$REALITY_SNI"
        printf 'REALITY_PRIVATE=%q\n' "$REALITY_PRIVATE"
        printf 'REALITY_PUBLIC=%q\n' "$REALITY_PUBLIC"
        printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
    } > "$_TXN_DIR/vars.env"
    _TXN_HAD_SERVICE="no"
    [ -f "$STATE_FILE" ] && _TXN_HAD_SERVICE="yes"
    if [ -f "$XRAY_PID" ] && pid_running "$XRAY_PID"; then _TXN_HAD_SERVICE="yes"; fi
    if has_openrc && [ -f /etc/init.d/suoha-plus-xray ]; then _TXN_HAD_SERVICE="yes"; fi
    _TXN_ACTIVE=1
    return 0
}

txn_commit() {
    _TXN_ACTIVE=0
    [ -n "$_TXN_DIR" ] && rm -rf "$_TXN_DIR" 2>/dev/null
    _TXN_DIR=""
    return 0
}

# 回滚：还原配置/状态/全局变量，重建服务单元，按原模式重新拉起服务。
txn_rollback() {
    [ "$_TXN_ACTIVE" = "1" ] || return 0
    _TXN_ACTIVE=0
    warn '安装未完成，正在回滚到安装前的配置与服务状态...'
    local f
    for f in "$XRAY_CONFIG" "$CF_CONFIG" "$STATE_FILE"; do
        if [ -f "$_TXN_DIR/$(basename "$f")" ]; then
            cp -f "$_TXN_DIR/$(basename "$f")" "$f" 2>/dev/null
        fi
    done
    # shellcheck disable=SC1090
    [ -f "$_TXN_DIR/vars.env" ] && . "$_TXN_DIR/vars.env"
    if [ "$_TXN_HAD_SERVICE" = "yes" ]; then
        install_systemd_units >/dev/null 2>&1 || true
        install_openrc_units >/dev/null 2>&1 || true
        if restart_services >/dev/null 2>&1; then
            ok '回滚完成：安装前的配置与原服务已恢复。'
        else
            err "回滚未能自动拉起服务，请手动执行：rc-service suoha-plus-xray restart（或 systemctl restart $SERVICE_XRAY）"
        fi
    else
        ok '回滚完成：安装前的配置已还原（此前没有在跑的服务，未做启动尝试）。'
    fi
    [ -n "$_TXN_DIR" ] && rm -rf "$_TXN_DIR" 2>/dev/null
    _TXN_DIR=""
    return 0
}

setup_reality() {
    need_root || return 1
    confirm_overwrite "Reality 直连节点" || return 1
    local old_mode="$MODE" old_reality="$REALITY_ENABLED"
    MODE="reality"
    REALITY_ENABLED="yes"
    # Reality 只跑 vless+Vision，PROTOCOL 字段在此模式下无意义；
    # 之前会保留默认的 vmess，导致 show_config / state.env 显示"Xray 协议: vmess"误导用户。
    # 保留原值只用于其他模式切回来，但显示与状态统一按 reality 处理。
    ensure_software || { MODE="$old_mode"; REALITY_ENABLED="$old_reality"; return 1; }
    say '请确认 Reality 节点参数（直接回车使用默认值）：'
    REALITY_PORT="$(ask_default 'Reality 监听端口（公网直连）' "$REALITY_PORT")"
    REALITY_DEST="$(ask_default '目标网站 dest（域名或 域名:端口，需支持 TLS1.3+h2）' "$REALITY_DEST")"
    REALITY_SNI="$(ask_default 'SNI（一般与 dest 域名一致）' "$REALITY_SNI")"
    # 连接地址：留空 = 自动输出 v4/v6 双栈链接（推荐，由客户端二选一）。
    # 填了就用填的（域名 / IPv4 / [IPv6]），不再生成另一条 —— 这样"指定地址"才真正生效。
    local addr_hint
    addr_hint="$(reality_default_address 2>/dev/null || echo '未探测到')"
    printf '%s\n' "  当前探测到的公网地址：$addr_hint" >&2
    safe_read _addr '节点连接地址（留空=自动双栈 / 可填域名或IPv4或[IPv6]）[自动]: ' ''
    case "$_addr" in
        [Aa][Uu][Tt][Oo]|自动) NODE_ADDRESS="" ;;
        *) NODE_ADDRESS="$_addr" ;;
    esac
    UUID="$(ask_default 'UUID' "$UUID")"
    validate_common || { MODE="$old_mode"; REALITY_ENABLED="$old_reality"; return 1; }
    mkdir -p "$APP_DIR" "$LOG_DIR" "$TMP_DIR" || { MODE="$old_mode"; REALITY_ENABLED="$old_reality"; return 1; }
    # 从这里开始才允许动服务/改状态。
    # 顺序很关键：
    #   1) txn_begin 先快照（此时旧密钥、旧配置都还在）
    #   2) 再生成新密钥 —— validate_reality 要求私钥非空，全新安装时必须先生成后校验
    #   3) 最后校验。旧实现在校验前生成密钥、失败后不回滚，
    #      导致 state.env 是新密钥而还原的 xray.json 用旧私钥，节点链接全部失效。
    txn_begin || true
    info "正在生成 Reality 密钥（x25519）..."
    if ! generate_reality_keys; then
        MODE="$old_mode"; REALITY_ENABLED="$old_reality"; txn_rollback; return 1
    fi
    if ! validate_reality; then
        MODE="$old_mode"; REALITY_ENABLED="$old_reality"; txn_rollback; return 1
    fi
    if ! write_xray_config; then
        MODE="$old_mode"; REALITY_ENABLED="$old_reality"; txn_rollback; return 1
    fi
    save_state
    stop_services 2>/dev/null || true
    remove_systemd_units
    # 开机自启 + 崩溃拉起：Reality 模式也安装服务单元（systemd/OpenRC）
    if ! install_systemd_units || ! install_openrc_units; then
        txn_rollback; return 1
    fi
    if ! start_xray; then
        txn_rollback; return 1
    fi
    txn_commit
    save_state
    generate_nodes
    print_nodes
    install_cmd_link
    ok "Reality 直连节点安装完成；管理命令：$CMD_LINK"
}

_IP4_CACHE=""
_IP6_CACHE=""

public_ip() {
    if [ -n "$_IP4_CACHE" ]; then printf '%s' "$_IP4_CACHE"; return 0; fi
    local ip
    ip="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$ip" ] || ip="$(curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    _IP4_CACHE="$ip"
    printf '%s' "$ip"
}

public_ip6() {
    if [ -n "$_IP6_CACHE" ]; then printf '%s' "$_IP6_CACHE"; return 0; fi
    local ip
    ip="$(curl -fsS6 --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
    if [ -z "$ip" ]; then
        ip="$(ip -6 addr show scope global 2>/dev/null | grep -o 'inet6 [0-9a-f:]*' | awk '{print $2}' | grep -v '^fe80' | head -n 1)"
    fi
    _IP6_CACHE="$ip"
    printf '%s' "$ip"
}
reality_default_address() {
    local ip6 ip4
    ip6="$(public_ip6 2>/dev/null || true)"
    if [ -n "$ip6" ]; then
        printf '[%s]' "$ip6"
        return 0
    fi
    ip4="$(public_ip 2>/dev/null || true)"
    printf '%s' "$ip4"
}

setup_quick() {
    need_root || return 1
    confirm_overwrite "Quick Tunnel" || return 1
    local old_mode="$MODE"
    MODE="quick"
    QUICK_URL=""
    ensure_software || { MODE="$old_mode"; return 1; }
    configure_xray || { MODE="$old_mode"; return 1; }
    configure_tunnel || { MODE="$old_mode"; return 1; }
    mkdir -p "$APP_DIR" "$LOG_DIR" "$TMP_DIR" || { MODE="$old_mode"; return 1; }
    # 所有校验都已通过，从这里开始才允许动服务。
    txn_begin || true
    write_xray_config || { MODE="$old_mode"; txn_rollback; return 1; }
    save_state
    stop_services 2>/dev/null || true
    remove_systemd_units
    # xray 安装服务单元（自启 + 崩溃拉起）；Quick 隧道地址重启会变，保持 nohup
    if ! install_systemd_units || ! install_openrc_units || ! start_xray || ! start_quick_tunnel; then
        txn_rollback; return 1
    fi
    txn_commit
    save_state
    generate_nodes
    print_nodes
}

setup_persistent() {
    need_root || return 1
    confirm_overwrite "持久化 Tunnel" || return 1
    local old_mode="$MODE"
    # 已有 Cloudflare 配置（重装场景）→ 询问是否清空重新登录
    if [ -d /root/.cloudflared ] || [ -n "$TUNNEL_ID" ]; then
        say ""
        warn '检测到已有 Cloudflare 配置（授权/凭据）。'
        safe_read cfans '删除全部 Cloudflare 配置并重新登录？[y/N]: ' ''
        case "$cfans" in
            y|Y) cf_full_cleanup || { MODE="$old_mode"; return 1; } ;;
            *) info '保留现有配置，复用授权文件与隧道。' ;;
        esac
    fi
    MODE="persistent"
    QUICK_URL=""
    ensure_software || { MODE="$old_mode"; return 1; }
    configure_xray || { MODE="$old_mode"; return 1; }
    configure_tunnel || { MODE="$old_mode"; return 1; }
    mkdir -p "$APP_DIR" "$LOG_DIR" "$TMP_DIR" || { MODE="$old_mode"; return 1; }
    ensure_named_tunnel || { MODE="$old_mode"; return 1; }
    route_domain || { MODE="$old_mode"; return 1; }
    # 所有校验/授权都已通过，从这里开始才允许动服务。
    txn_begin || true
    write_xray_config || { MODE="$old_mode"; txn_rollback; return 1; }
    write_cloudflared_config || { MODE="$old_mode"; txn_rollback; return 1; }
    save_state
    stop_services 2>/dev/null || true
    remove_systemd_units
    if ! install_systemd_units || ! install_openrc_units || ! start_xray || ! start_persistent_tunnel; then
        txn_rollback; return 1
    fi
    txn_commit
    save_state
    generate_nodes
    print_nodes
    install_cmd_link
    ok "持久化服务安装完成；管理命令：$CMD_LINK"
}

show_config() {
    say "${C_CYAN}当前运行配置${C_RESET}"
    printf '模式          : %s\n' "$MODE"
    if [ "$REALITY_ENABLED" = "yes" ]; then
        # Reality 固定走 vless+XTLS Vision，不该显示 PROTOCOL（那字段是 WS 模式用的，
        # 且默认值是 vmess，会让人误以为 Reality 跑的是 vmess）。
        printf 'Xray 协议     : vless + xtls-rprx-vision（Reality 固定）\n'
    else
        printf 'Xray 协议     : %s\n' "$PROTOCOL"
    fi
    printf 'Xray 版本     : %s（固定）\n' "$XRAY_VERSION"
    if [ "$REALITY_ENABLED" = "yes" ]; then
        printf 'Reality 端口  : %s\n' "$REALITY_PORT"
        printf 'Reality dest  : %s\n' "$REALITY_DEST"
        printf 'Reality SNI   : %s\n' "$REALITY_SNI"
        if [ -n "$NODE_ADDRESS" ]; then
            printf '连接地址      : %s（指定）\n' "$NODE_ADDRESS"
        else
            printf '连接地址      : 自动（v4/v6 双栈）\n'
        fi
    else
        printf '本地端口      : %s\n' "$XRAY_PORT"
        printf 'UUID          : %s\n' "$UUID"
        printf 'WS 路径       : %s\n' "$WS_PATH"
        printf '边缘 IP       : IPv%s\n' "$EDGE_IP"
        printf '隧道协议      : %s\n' "$CF_PROTOCOL"
        printf '节点地址      : %s\n' "$NODE_ADDRESS"
    fi
    [ "$MODE" = "quick" ] && printf 'Quick 地址    : %s\n' "${QUICK_URL:-未启动}"
    [ "$MODE" = "persistent" ] && printf '绑定域名      : %s\nTunnel 名称   : %s\nTunnel ID     : %s\n' "$DOMAIN" "$TUNNEL_NAME" "$TUNNEL_ID"
    printf '节点文件      : %s\n' "$NODE_FILE"
    if [ -f "$CF_CONFIG" ]; then
        printf '配置位置      : %s | %s\n' "$XRAY_CONFIG" "$CF_CONFIG"
    else
        printf '配置位置      : %s\n' "$XRAY_CONFIG"
    fi
    [ -f "$SQ_APP_DIR/server-direct.yaml" ] && printf '                ShadowQuic: %s（手动编辑后用菜单8重启生效）\n' "$SQ_APP_DIR/server-direct.yaml"
}

status_line() {
    local name="$1" unit="$2" pidfile="$3" st pid
    if [ "$MODE" = "persistent" ] && has_systemd; then
        st="$(systemctl is-active "$unit" 2>/dev/null || printf 'unknown')"
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null)"
        [ "$pid" = "0" ] && pid=""
    elif has_openrc && service_unit_exists "$unit"; then
        st="$(rc-service "${unit%.service}" status 2>&1 || true)"
        case "$st" in
            *started*) st="running" ;;
            *crashed*) st="crashed" ;;
            *) st="stopped" ;;
        esac
        pid="$(cat "$pidfile" 2>/dev/null || true)"
    elif pid_running "$pidfile"; then
        st="running"
        pid="$(cat "$pidfile" 2>/dev/null)"
    else
        st="stopped"
    fi
    if [ "$st" = "active" ] || [ "$st" = "running" ]; then
        say "${C_GREEN}● $name：运行中${C_RESET}  (PID ${pid:-—})"
    elif [ "$st" = "crashed" ]; then
        say "${C_YELLOW}▸ $name：已崩溃（crashed，异常退出）${C_RESET}"
    else
        say "${C_RED}○ $name：未运行${C_RESET}"
    fi
}

health_check() {
    # 只在服务声称运行时做实测：Reality 端口监听 / 隧道 WS 链路探测
    local xray_alive=0 cf_alive=0
    if pid_running "$XRAY_PID"; then
        xray_alive=1
    elif has_systemd && [ "$(systemctl is-active "$SERVICE_XRAY" 2>/dev/null)" = "active" ]; then
        xray_alive=1
    elif has_openrc && service_unit_exists "$SERVICE_XRAY"; then
        case "$(rc-service suoha-plus-xray status 2>&1 || true)" in *started*) xray_alive=1 ;; esac
    fi
    if pid_running "$CF_PID"; then
        cf_alive=1
    elif has_systemd && [ "$(systemctl is-active "$SERVICE_CF" 2>/dev/null)" = "active" ]; then
        cf_alive=1
    elif has_openrc && service_unit_exists "$SERVICE_CF"; then
        case "$(rc-service suoha-plus-cloudflared status 2>&1 || true)" in *started*) cf_alive=1 ;; esac
    fi
    if [ "$xray_alive" = "0" ] && [ "$cf_alive" = "0" ]; then
        return 0
    fi
    if [ "$xray_alive" = "1" ] && [ "$REALITY_ENABLED" = "yes" ]; then
        if command_exists ss && ss -tln 2>/dev/null | grep -q ":$REALITY_PORT "; then
            say "${C_GREEN}✓ Xray 健康    ：Reality 端口 $REALITY_PORT 监听中（v4/v6）${C_RESET}"
        else
            say "${C_RED}✗ Xray 异常    ：Reality 端口 $REALITY_PORT 未监听${C_RESET}"
        fi
    fi
    if [ "$cf_alive" = "1" ]; then
        local host
        host="$(current_tunnel_host)"
        if [ -n "$host" ] && command_exists curl; then
            # 用 WS 升级握手探测，而不是普通 GET：
            # 旧实现 `curl -s -o /dev/null` 没加 -f，任何 HTTP 响应（含 400/404/530）
            # 退出码都是 0，导致"永远绿灯"。这里要求真的拿到 101 Switching Protocols，
            # 或者至少是 400/426（说明请求已到达 xray 的 WS inbound 并被识别为需 Upgrade）。
            local probe_ok=0 probe_rc _try _code _hdrs
            for _try in 1 2 3; do
                _hdrs="$(
                    curl -s -o /dev/null -D - --max-time 8 \
                        --http1.1 \
                        -H 'Connection: Upgrade' \
                        -H 'Upgrade: websocket' \
                        -H 'Sec-WebSocket-Version: 13' \
                        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
                        "https://$host$WS_PATH" 2>/dev/null
                )"
                probe_rc=$?
                _code="$(printf '%s' "$_hdrs" | sed -n 's#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | tail -n 1)"
                if [ "$_code" = "101" ]; then
                    probe_ok=1; break
                fi
                # 400/426：CF 边缘已回源，xray 收到了非完整 WS 请求 → 链路本身是通的。
                if [ "$_code" = "400" ] || [ "$_code" = "426" ]; then
                    probe_ok=1; break
                fi
                # curl 退出码非 0 且没有任何 HTTP 响应 = 真的连不上
                if [ "$probe_rc" -ne 0 ] && [ -z "$_code" ]; then
                    : # 继续重试
                fi
                [ "$_try" -lt 3 ] && sleep 3
            done
            if [ "$probe_ok" = "1" ]; then
                say "${C_GREEN}✓ 隧道健康    ：$host$WS_PATH WS 握手正常（HTTP $_code）${C_RESET}"
            else
                say "${C_RED}✗ 隧道异常    ：$host$WS_PATH 探测失败${_code:+（HTTP $_code）}${C_RESET}"
                say "${C_YELLOW}               排查：cloudflared 是否连上边缘 / Tunnel 是否指向 127.0.0.1:$XRAY_PORT${C_RESET}"
            fi
        elif [ -n "$host" ]; then
            say "${C_YELLOW}· 隧道状态    ：进程在线，无法探测（缺少 curl）${C_RESET}"
        fi
    fi
}

show_status() {
    show_config
    say ""
    status_line "Xray" "$SERVICE_XRAY" "$XRAY_PID"
    status_line "Cloudflare Tunnel" "$SERVICE_CF" "$CF_PID"
    health_check
    sq_status_line
    # Quick 模式的 cloudflared 没有 service 单元（地址每次重启都会变，刻意不自启），
    # 所以机器重启后 Xray 会自己起来、隧道不会，节点地址永久失效。
    # 这里在检测到"Xray 在跑但隧道没跑"时直接给出可执行提示，别让用户对着旧链接发呆。
    if [ "$MODE" = "quick" ] && [ -f "$STATE_FILE" ]; then
        if ! pid_running "$CF_PID"; then
            say ""
            say "${C_YELLOW}⚠ Quick 隧道未运行${C_RESET}"
            say "  原因：Quick 地址每次启动都会变，所以不注册开机自启。"
            say "  影响：$NODE_FILE 里记录的 ${QUICK_URL:-旧地址} 已失效。"
            say "  处理：回主菜单选 1) 重新启动 Quick Tunnel（会生成新地址并刷新节点）。"
            say "  更稳的做法：选 2) 持久化 Tunnel，域名固定、可开机自启。"
        fi
    fi
    printf 'Xray 日志      : %s\n' "$XRAY_LOG"
    printf 'Tunnel 日志    : %s\n' "$CF_LOG"
}

config_menu() {
    while true; do
        banner
        show_config
        say ""
        say '1) 修改 Xray 配置（立即校验、重启并刷新节点）'
        say '2) 修改隧道配置（立即应用并刷新节点）'
        say '3) 重新生成节点信息'
        say '4) 手动编辑配置文件（vi/vim，保存后自动校验重启生效）'
        say '0) 返回主菜单'
        safe_read menu '请选择: ' ''
        case "$menu" in
            1)
                configure_xray || { pause_screen; continue; }
                apply_config_now || true
                pause_screen
                ;;
            2)
                local old_domain="$DOMAIN"
                configure_tunnel || { pause_screen; continue; }
                if [ "$MODE" = "persistent" ] && [ "$DOMAIN" != "$old_domain" ]; then
                    warn "域名改变后必须同步 Cloudflare DNS 路由，否则新域名不会生效。"
                    safe_read answer '现在执行 route dns 更新？[y/N]: ' ''
                    case "$answer" in y|Y) route_domain || true ;; esac
                fi
                apply_config_now || true
                pause_screen
                ;;
            3)
                save_state; generate_nodes; print_nodes; pause_screen
                ;;
            4)
                manual_edit_config
                pause_screen
                ;;
            0|'') return 0 ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

manual_edit_config() {
    local editor
    editor="$(command -v vi || command -v vim || command -v nano || true)"
    [ -n "$editor" ] || { err '未找到 vi/vim/nano 编辑器。'; return 1; }
    say "${C_CYAN}当前配置文件位置：${C_RESET}"
    say "  Xray 配置      : $XRAY_CONFIG"
    [ -f "$CF_CONFIG" ] && say "  隧道配置       : $CF_CONFIG"
    [ -f "$SQ_APP_DIR/server-direct.yaml" ] && say "  ShadowQuic 配置: $SQ_APP_DIR/server-direct.yaml（direct=直连出站）/ $SQ_APP_DIR/server-socks.yaml（socks出站）"
    say "  ShadowQuic 模式: $SQ_APP_DIR/last-mode（direct/socks）"
    say ""
    say '  1) 编辑 Xray 配置'
    say '  2) 编辑隧道配置'
    say '  3) 编辑 ShadowQuic 直连出站配置'
    say '  4) 编辑 ShadowQuic SOCKS 出站配置'
    say '  5) 切换 ShadowQuic 出站模式（direct/socks）'
    say '  0) 返回'
    safe_read m '请选择: ' ''
    local sq_file
    case "${m:-0}" in
        1) "$editor" "$XRAY_CONFIG" && apply_config_now || true ;;
        2) [ -f "$CF_CONFIG" ] && "$editor" "$CF_CONFIG" && restart_services || warn '隧道配置文件不存在（Quick 模式自动生成）。' ;;
        3) [ -f "$SQ_APP_DIR/server-direct.yaml" ] && "$editor" "$SQ_APP_DIR/server-direct.yaml" && sq_start || warn 'ShadowQuic 尚未安装。' ;;
        4) [ -f "$SQ_APP_DIR/server-socks.yaml" ] && "$editor" "$SQ_APP_DIR/server-socks.yaml" || warn 'ShadowQuic 尚未安装。' ;;
        5)
            safe_read mm "当前模式：$(cat "$SQ_APP_DIR/last-mode" 2>/dev/null || echo direct)，切换到 [direct/socks]: " 
            case "$mm" in
                direct|socks)
                    echo "$mm" > "$SQ_APP_DIR/last-mode"
                    sq_start
                    sq_status_line
                    ;;
                *) warn '无效模式。' ;;
            esac
            ;;
        0|'') return 0 ;;
        *) warn '无效选项。' ;;
    esac
}

uninstall_plus() {
    need_root || return 1
    warn "这里只会删除 Suoha Plus（$APP_DIR 和独立服务），不会删除原 suoha.sh、/opt/suoha 或 Cloudflare 授权目录。"
    safe_read answer '确认卸载请输入 UNINSTALL: ' ''
    [ "$answer" = "UNINSTALL" ] || { info '已取消。'; return 0; }
    stop_services 2>/dev/null || true
    remove_systemd_units
    # 一并清理 ShadowQuic 服务单元：只删本项目的 init/unit 与 daemon wrapper，
    # 不碰 /etc/shadowquic 里其他项目的配置（归属由 sq_remove 内部判断）。
    rc-service suoha-shadowquic stop >/dev/null 2>&1 || true
    rc-update del suoha-shadowquic default >/dev/null 2>&1 || true
    rm -f "$SQ_INIT" /usr/local/bin/suoha-quic-daemon.sh 2>/dev/null || true
    if has_systemd; then
        systemctl disable suoha-shadowquic >/dev/null 2>&1 || true
        rm -f "$SQ_UNIT"; systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    # 删除目录前再兜底杀一次，避免 pidfile 丢失导致 cloudflared/xray 残留
    pkill -f "$BIN_DIR/cloudflared" 2>/dev/null || true
    pkill -f "$BIN_DIR/xray" 2>/dev/null || true
    # ShadowQuic 只停本项目的，别家的实例保留
    sq_stop_process 2>/dev/null || true
    sleep 1
    rm -f "$CMD_LINK"
    rm -rf "$APP_DIR"
    ok 'Suoha Plus 已卸载（含 ShadowQuic 服务）；原脚本和原安装目录未改动。'
    exit 0
}

uninstall_component() {
    local what="$1"
    need_root || return 1
    if [ "$what" = "xray" ] || [ "$what" = "all" ]; then
        if has_systemd; then
            systemctl disable --now "$SERVICE_XRAY" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/$SERVICE_XRAY"
        fi
        if has_openrc; then
            rc-service suoha-plus-xray stop >/dev/null 2>&1 || true
            rc-update del suoha-plus-xray default >/dev/null 2>&1 || true
            rm -f /etc/init.d/suoha-plus-xray /etc/init.d/suoha-xray-old /usr/local/bin/suoha-xray-daemon.sh
        fi
        stop_pid "$XRAY_PID"
        rm -f "$XRAY_BIN" "$XRAY_CONFIG" "$XRAY_CONFIG.bak" "$XRAY_PID"
        : > "$XRAY_LOG" 2>/dev/null || true
        ok 'Xray 服务已删除（二进制、配置、日志）。'
    fi
    if [ "$what" = "tunnel" ] || [ "$what" = "all" ]; then
        if has_systemd; then
            systemctl disable --now "$SERVICE_CF" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/$SERVICE_CF"
        fi
        if has_openrc; then
            rc-service suoha-plus-cloudflared stop >/dev/null 2>&1 || true
            rc-update del suoha-plus-cloudflared default >/dev/null 2>&1 || true
            rm -f /etc/init.d/suoha-plus-cloudflared /usr/local/bin/suoha-cloudflared-daemon.sh
        fi
        stop_pid "$CF_PID"
        rm -f "$CF_BIN" "$CF_CONFIG" "$CF_CONFIG.bak" "$CF_PID"
        : > "$CF_LOG" 2>/dev/null || true
        QUICK_URL=""
        ok 'Cloudflare Tunnel 服务已删除（二进制、配置、日志）。'
    fi
    if has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if [ "$what" = "all" ]; then
        rm -f "$CMD_LINK"
        rm -rf "$APP_DIR"
        ok 'Suoha Plus 已完全卸载；原 suoha.sh 不受影响。'
        exit 0
    fi
    warn '注意：删除组件后节点不可用；重新安装请回主菜单选 1 或 2。'
    save_state
}

uninstall_menu() {
    while true; do
        banner
        show_status
        say ""
        say '1) 仅删除 Xray 服务（保留 Cloudflare Tunnel）'
        say '2) 仅删除 Cloudflare Tunnel 服务（保留 Xray）'
        say '3) 删除全部 Suoha Plus（原 suoha.sh 不受影响）'
        say '0) 返回主菜单'
        safe_read menu '请选择: ' ''
        case "$menu" in
            1)
                safe_read answer '确认删除 Xray 服务？[y/N]: ' ''
                case "$answer" in
                    y|Y) uninstall_component xray; pause_screen ;;
                esac
                ;;
            2)
                safe_read answer '确认删除 Cloudflare Tunnel 服务？[y/N]: ' ''
                case "$answer" in
                    y|Y) uninstall_component tunnel; pause_screen ;;
                esac
                ;;
            3) uninstall_plus ;;
            0|'') return 0 ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

service_menu() {
    while true; do
        banner
        show_status
        say ""
        say '1) 启动 Xray + 隧道'
        say '2) 停止 Xray + 隧道'
        say '3) 重启 Xray + 隧道，并实时刷新节点'
        say '4) 查看节点信息'
        say '0) 返回主菜单'
        safe_read menu '请选择: ' ''
        case "$menu" in
            1)
                if start_xray; then
                    case "$MODE" in
                        quick) start_quick_tunnel ;;
                        persistent) start_persistent_tunnel ;;
                        reality)
                            # Reality 共存模式：有隧道配置就一并启动
                            [ -f "$CF_CONFIG" ] && start_persistent_tunnel
                            ;;
                    esac
                    save_state
                    generate_nodes
                fi
                pause_screen
                ;;
            2) stop_services; pause_screen ;;
            3) restart_services; pause_screen ;;
            4) print_nodes; pause_screen ;;
            0|'') return 0 ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

# ---------- ShadowQuic 模块（移植自 warp- 项目，不依赖 WARP/sing-box） ----------
SQ_VERSION_FALLBACK="v0.3.12"
SQ_APP_DIR="/etc/shadowquic"
SQ_BIN="/usr/local/bin/shadowquic"
SQ_LOG="/var/log/suoha-sq.log"
SQ_UNIT="/etc/systemd/system/suoha-shadowquic.service"
SQ_INIT="/etc/init.d/suoha-shadowquic"
SQ_CMD="/usr/local/bin/suoha-quic"

sq_installed() { [ -x "$SQ_BIN" ]; }

sq_arch_asset() {
    case "$(uname -m)" in
        x86_64|amd64)  printf '%s' 'shadowquic-x86_64-linux-musl' ;;
        aarch64|arm64) printf '%s' 'shadowquic-aarch64-linux-musl' ;;
        armv7l|armv7)  printf '%s' 'shadowquic-armv7-linux-muslhf' ;;
        i686|i386)     printf '%s' 'shadowquic-i686-linux-musl' ;;
        *) return 1 ;;
    esac
}

sq_local_version() {
    [ -x "$SQ_BIN" ] || return 0
    "$SQ_BIN" --version 2>/dev/null | head -n 1 | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

sq_latest_version() {
    local v
    # 与 xray_latest_version 保持一致：查询期间给一行提示，别让菜单看起来卡住。
    net_hint_begin "正在查询 shadowquic 上游版本"
    v="$(curl -fsSL --max-time 8 https://api.github.com/repos/spongebob888/shadowquic/releases/latest 2>/dev/null | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
    net_hint_end
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

sq_download_bin() {
    # 第二个参数 1 = 调用方已经确认过（避免同一件事问两遍）。
    local ver="$1" preconfirmed="${2:-0}" asset tmp
    asset="$(sq_arch_asset)" || { err "当前架构不支持：$(uname -m)"; return 1; }
    if [ "$preconfirmed" != "1" ]; then
        confirm_download \
            "shadowquic $ver（$asset）" \
            "来自 spongebob888/shadowquic Releases，约 13MB；安装到 $SQ_BIN" \
            "$SQ_BIN" || return 1
    fi
    tmp="$(mktemp /tmp/.sq.dl.XXXXXX)" || return 1
    dl_run "shadowquic" "https://github.com/spongebob888/shadowquic/releases/download/$ver/$asset" "$tmp" 120 \
        || { rm -f "$tmp"; err '下载失败（网络不通或超时），请检查到 github.com 的连通性。'; return 1; }
    if [ "$(head -c 4 "$tmp" 2>/dev/null)" != "$(printf '\x7f\x45\x4c\x46')" ]; then
        rm -f "$tmp"; err '下载内容不是有效的 ELF 可执行文件。'; return 1
    fi
    chmod +x "$tmp"
    if ! timeout 10 "$tmp" --version >/dev/null 2>&1 && ! timeout 10 "$tmp" -V >/dev/null 2>&1; then
        rm -f "$tmp"; err '二进制无法执行（可能架构不匹配）。'; return 1
    fi
    mkdir -p "$(dirname "$SQ_BIN")" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$SQ_BIN"
    ok "shadowquic $ver 已安装"
}

sq_check_update() {
    local latest local_v
    latest="$(sq_latest_version)" || { warn '无法获取最新版本（网络问题）。'; return 1; }
    local_v="$(sq_local_version)"
    [ -n "$local_v" ] || local_v="unknown"
    say "当前版本：$local_v    最新版本：$latest"
    if [ "v${local_v#v}" = "$latest" ]; then
        ok '已是最新版本。'
        return 0
    fi
    return 2
}

sq_upgrade() {
    need_root || return 1
    local latest rc
    if ! sq_installed; then
        err 'ShadowQuic 尚未安装，请先安装。'; return 1
    fi
    sq_check_update; rc=$?
    if [ "$rc" = "0" ]; then return 0; fi
    [ "$rc" = "2" ] || return 1
    latest="$(sq_latest_version)" || { err '无法获取最新版本。'; return 1; }
    # 确认只在触发升级时问一次，下载函数用 1 跳过重复询问。
    confirm_download \
        "shadowquic $latest（升级）" \
        "约 13MB，来自 spongebob888/shadowquic Releases；替换 $SQ_BIN 后重启服务" \
        "$SQ_BIN" || return 1
    sq_download_bin "$latest" 1 || return 1
    sq_start && ok '升级完成，服务已重启。'
}

sq_detect_service() {
    # 返回 "systemd" / "openrc" / "manual"，同时识别旧的 shadowquic 服务名（兼容接管）
    if has_systemd && { [ -f "$SQ_UNIT" ] || [ -f /etc/systemd/system/shadowquic.service ] || ls /lib/systemd/system/shadowquic* >/dev/null 2>&1; }; then
        printf 'systemd'
    elif [ -f /etc/init.d/shadowquic ] || [ -f "$SQ_INIT" ]; then
        rc-update add suoha-shadowquic default >/dev/null 2>&1 || true
        printf 'openrc'
    elif has_systemd; then
        printf 'systemd'
    else
        printf 'manual'
    fi
}

sq_random() {
    head -c 32 /dev/urandom | base64 | tr -d '=+/' | cut -c1-"$1"
}

sq_marker_path() { printf '%s' "$SQ_APP_DIR/.managed-by-suoha-plus"; }

sq_owned() {
    [ -f "$(sq_marker_path)" ] && return 0
    # 目录不存在或为空 → 无主，可接管
    if [ ! -d "$SQ_APP_DIR" ]; then return 0; fi
    if [ -z "$(ls -A "$SQ_APP_DIR" 2>/dev/null)" ]; then return 0; fi
    return 1
}

sq_foreign_owner() {
    [ -f "$SQ_APP_DIR/.managed-by-warp-go" ] && { printf '%s' 'warp-'; return 0; }
    return 1
}

sq_write_configs() {
    local u="$1" p="$2" sq_sn="$3" sq_up="$4"
    mkdir -p "$SQ_APP_DIR"
    if [ -f "$SQ_APP_DIR/server-direct.yaml" ] && ! sq_owned; then
        local who
        who="$(sq_foreign_owner 2>/dev/null || true)"
        warn "检测到 ${who:-其他项目} 的 ShadowQuic 配置，已备份后覆盖。"
        cp -f "$SQ_APP_DIR/server-direct.yaml" "$SQ_APP_DIR/server-direct.yaml.bak-suoha.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    fi
    if [ -f "$SQ_APP_DIR/server-socks.yaml" ] && ! sq_owned; then
        cp -f "$SQ_APP_DIR/server-socks.yaml" "$SQ_APP_DIR/server-socks.yaml.bak-suoha.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    fi
    cat > "$SQ_APP_DIR/server-direct.yaml" <<EOF
inbound:
  type: shadowquic
  bind-addr: "[::]:$SQ_PORT"
  users:
    - username: "$u"
      password: "$p"
  server-name: "$sq_sn"
  jls-upstream:
    addr: "$sq_up"
    rate-limit: 1000000
  alpn: ["h3"]
  zero-rtt: true
  congestion-control: bbr
  gso: true
  mtu-discovery: true
  blackhole-detection: false
  initial-mtu: 1300
  min-mtu: 1200
outbound:
  type: direct
  dns-strategy: prefer-ipv4
log-level: warn
EOF
    cat > "$SQ_APP_DIR/server-socks.yaml" <<EOF
inbound:
  type: shadowquic
  bind-addr: "[::]:$SQ_PORT"
  users:
    - username: "$u"
      password: "$p"
  server-name: "$sq_sn"
  jls-upstream:
    addr: "$sq_up"
    rate-limit: 1000000
  alpn: ["h3"]
  zero-rtt: true
  congestion-control: bbr
  gso: true
  mtu-discovery: true
  blackhole-detection: false
  initial-mtu: 1300
  min-mtu: 1200
outbound:
  type: socks
  addr: "127.0.0.1:1080"
log-level: warn
EOF
    echo direct > "$SQ_APP_DIR/last-mode"
    : > "$(sq_marker_path)"
}

sq_write_service() {
    if has_systemd; then
        # systemd 版也使用 wrapper 脚本（与 OpenRC 共用），避免 ExecStart 中 $() 被 systemd 拆解
        cat > /usr/local/bin/suoha-quic-daemon.sh <<'DAEMON'
#!/bin/sh
MODE=$(cat /etc/shadowquic/last-mode 2>/dev/null || echo "direct")
CONF="/etc/shadowquic/server-${MODE}.yaml"
exec /usr/local/bin/shadowquic -c "$CONF" >> /var/log/suoha-sq.log 2>&1
DAEMON
        chmod +x /usr/local/bin/suoha-quic-daemon.sh
        cat > "$SQ_UNIT" <<EOF
[Unit]
Description=Suoha Plus ShadowQuic (QUIC proxy with SNI camouflage)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/suoha-quic-daemon.sh
WorkingDirectory=$SQ_APP_DIR
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable suoha-shadowquic >/dev/null 2>&1 || true
    else
        cat > "$SQ_INIT" <<'OPENRC'
#!/sbin/openrc-run
name="Suoha-ShadowQuic"
supervisor=supervise-daemon
command="/usr/local/bin/suoha-quic-daemon.sh"
pidfile="/run/suoha-shadowquic.pid"
respawn_delay=5
respawn_max=0
output_log="/var/log/suoha-sq.log"
error_log="/var/log/suoha-sq.log"
OPENRC
        chmod +x "$SQ_INIT"
        rc-update add suoha-shadowquic default >/dev/null 2>&1 || true
        cat > /usr/local/bin/suoha-quic-daemon.sh <<'DAEMON'
#!/bin/sh
MODE=$(cat /etc/shadowquic/last-mode 2>/dev/null || echo "direct")
CONF="/etc/shadowquic/server-${MODE}.yaml"
exec /usr/local/bin/shadowquic -c "$CONF" >> /var/log/suoha-sq.log 2>&1
DAEMON
        chmod +x /usr/local/bin/suoha-quic-daemon.sh
    fi
}

sq_start() {
    sq_stop_process
    if has_systemd && [ -f "$SQ_UNIT" ]; then
        systemctl restart suoha-shadowquic
    else
        if [ ! -f "$SQ_INIT" ]; then
            # 没有本项目的服务单元。若 /etc/init.d/shadowquic 属于其他项目，绝不接管。
            if [ -f /etc/init.d/shadowquic ] && ! sq_owned; then
                warn "检测到其他项目的 shadowquic 服务，Suoha Plus 不自动启动也不删除它。"
                return 0
            fi
            rc-update del shadowquic default >/dev/null 2>&1 || true
            rm -f /etc/init.d/shadowquic 2>/dev/null || true
        fi
        if [ -x "$SQ_INIT" ]; then
            lock_release
            rc-service suoha-shadowquic start >/dev/null 2>&1 || /etc/init.d/suoha-shadowquic start
        else
            warn '未找到 Suoha Plus 的 ShadowQuic 服务单元，请重新安装。'
            return 1
        fi
    fi
    sleep 2
}

# 进程命令行里是否引用了本项目自己的配置/服务脚本。
# 只认这三个路径，别的一律当外部实例。
sq_proc_is_ours() {
    case "$1" in
        *"$SQ_INIT"*|*/suoha-quic-daemon.sh*|*"$SQ_APP_DIR/server-direct.yaml"*|*"$SQ_APP_DIR/server-socks.yaml"*)
            return 0 ;;
    esac
    return 1
}

sq_pids_ours() {
    command_exists pgrep || return 0
    local p cmd
    for p in $(pgrep -f '[s]hadowquic' 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
        [ -n "$cmd" ] || continue
        sq_proc_is_ours "$cmd" && printf '%s\n' "$p"
    done
    return 0
}

sq_stop_process() {
    # 只停本项目自己的实例。
    # 旧实现末尾无条件 `pgrep -f '[s]hadowquic' | kill -9`，同机其他项目（或用户手动起的
    # 客户端）只要命令行里带 shadowquic 就会被一起杀掉。实测 3 个进程停完只剩 0 个。
    if has_systemd && [ -f "$SQ_UNIT" ]; then
        systemctl stop suoha-shadowquic 2>/dev/null || true
    fi
    if [ -f "$SQ_INIT" ]; then
        rc-service suoha-shadowquic stop 2>/dev/null ||             /etc/init.d/suoha-shadowquic stop 2>/dev/null || true
    fi
    # 被接管的旧服务：仅当配置目录已由本脚本认领时才停
    if [ -f /etc/init.d/shadowquic ] && sq_owned; then
        /etc/init.d/shadowquic stop 2>/dev/null || true
    fi
    local p
    for p in $(sq_pids_ours); do
        kill "$p" 2>/dev/null || true
    done
    local i=0
    while [ "$i" -lt 5 ]; do
        [ -z "$(sq_pids_ours)" ] && break
        sleep 1; i=$((i + 1))
    done
    for p in $(sq_pids_ours); do
        kill -9 "$p" 2>/dev/null || true
    done
    sleep 1
}

sq_status_line() {
    local st="未运行"
    if has_systemd && [ -f "$SQ_UNIT" ]; then
        [ "$(systemctl is-active suoha-shadowquic 2>/dev/null)" = "active" ] && st="运行中"
    elif has_openrc && [ -f "$SQ_INIT" ]; then
        case "$(rc-service suoha-shadowquic status 2>&1 || true)" in *started*) st="运行中" ;; esac
    elif pgrep -f '[s]hadowquic' >/dev/null 2>&1; then
        st="运行中"
    fi
    if [ "$st" = "运行中" ]; then
        say "${C_GREEN}● ShadowQuic：运行中${C_RESET}  (UDP :$SQ_PORT, 模式 $(cat "$SQ_APP_DIR/last-mode" 2>/dev/null || echo direct))"
    else
        say "${C_RED}○ ShadowQuic：未运行${C_RESET}"
    fi
}

sq_setup() {
    need_root || return 1
    say ""
    info '安装 Suoha Plus ShadowQuic（QUIC 代理，UDP 端口，无需域名/证书）'
    # 已装旧版 shadowquic（非本脚本管理）→ 提示接管
    if sq_installed && [ ! -f "$SQ_UNIT" ] && [ ! -f "$SQ_INIT" ]; then
        warn '检测到旧的 shadowquic 安装，将继续接管（会停止旧服务并复用 /etc/shadowquic）。'
    fi
    # 端口
    local old_port="$SQ_PORT"
    SQ_PORT="$(ask_default 'ShadowQuic 监听端口（UDP）' "$SQ_PORT")"
    if ! [[ "$SQ_PORT" =~ ^[0-9]+$ ]] || [ "$SQ_PORT" -lt 1024 ] || [ "$SQ_PORT" -gt 65535 ]; then
        err '端口无效。'; SQ_PORT="$old_port"; return 1
    fi
    # 凭据
    local sq_user sq_pass sq_sn sq_up
    sq_user="$(ask_default '用户名' "$(sq_random 10)")"
    sq_pass="$(ask_default '密码' "$(sq_random 16)")"
    sq_sn="$(ask_default 'SNI 伪装域名' "$REALITY_SNI")"
    sq_up="$(ask_default 'JLS upstream（域名:端口，需与客户端 server-name 一致）' "$REALITY_DEST")"
    # 二进制：每次都检查最新版，有新版本则询问是否升级
    local ver cur
    info '检查 shadowquic 版本...'
    ver="$(sq_latest_version)" || ver="$SQ_VERSION_FALLBACK"
    cur="$(sq_local_version)"
    if sq_installed; then
        info "当前版本：${cur:-unknown}，最新版本：$ver"
        if [ "v${cur#v}" = "$ver" ]; then
            info '已是最新版本，跳过下载。'
        else
            # 确认点只在这里出现一次；之后 sq_download_bin 带 1 表示已确认。
            say ""
            say "${C_CYAN}── 下载确认 ──${C_RESET}"
            say "  内容：shadowquic $ver（${cur:-unknown} → $ver）"
            say "  说明：约 13MB，替换 $SQ_BIN 后重启服务"
            safe_read up_yn "是否升级到 $ver？确认后开始下载 [y/N]: " 'n'
            case "$up_yn" in
                y|Y|yes|YES) sq_download_bin "$ver" 1 || return 1 ;;
                *) info "保留当前版本 ${cur:-unknown}，未做任何修改。"; return 0 ;;
            esac
        fi
    else
        sq_download_bin "$ver" || return 1
    fi
    # 配置 + 服务 + 启动
    sq_write_configs "$sq_user" "$sq_pass" "$sq_sn" "$sq_up"
    sq_write_service
    sq_start
    # 自检
    if ss -lunp 2>/dev/null | grep -q ":$SQ_PORT "; then
        ok "ShadowQuic 已启动（UDP :$SQ_PORT）"
    else
        warn "端口未监听，查看日志：tail -50 $SQ_LOG"
    fi
    # 清理旧的 shadowquic 服务注册（已被 suoha-shadowquic 取代，防止开机双启）。
    # 只在配置目录确实属于本脚本时才删，避免拆掉其他项目的服务单元。
    if [ -f /etc/init.d/shadowquic ]; then
        if sq_owned; then
            rc-update del shadowquic default >/dev/null 2>&1 || true
            rm -f /etc/init.d/shadowquic
            info '已移除旧的 shadowquic 服务（配置由本脚本接管）。'
        else
            warn '检测到 /etc/init.d/shadowquic 属于其他项目，已保留未删除。'
        fi
    fi
    if [ -f /etc/systemd/system/shadowquic.service ]; then
        if sq_owned; then
            systemctl disable shadowquic >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/shadowquic.service; systemctl daemon-reload 2>/dev/null || true
            info '已移除旧的 shadowquic systemd 服务。'
        else
            warn '检测到 shadowquic.service 属于其他项目，已保留未删除。'
        fi
    fi
    sq_show_info
    save_state
}

sq_show_info() {
    local u p sn
    u="$(sed -n 's/.*username: "\([^"]*\)".*/\1/p' "$SQ_APP_DIR/server-direct.yaml" 2>/dev/null | head -1)"
    p="$(sed -n 's/.*password: "\([^"]*\)".*/\1/p' "$SQ_APP_DIR/server-direct.yaml" 2>/dev/null | head -1)"
    sn="$(sed -n 's/.*server-name: "\([^"]*\)".*/\1/p' "$SQ_APP_DIR/server-direct.yaml" 2>/dev/null | head -1)"
    say ""
    say '—— ShadowQuic 客户端接入 ——'
    say "服务器: VPS 公网IP（v4/v6）  端口: $SQ_PORT (UDP)"
    say "用户名: $u"
    say "密码  : $p"
    say "server-name: $sn"
    say ''
    say 'Clash.Meta / mihomo 写法：'
    cat <<EOF
  - name: "suoha-sq"
    type: shadowquic
    server: <VPS_IP>
    port: $SQ_PORT
    username: "$u"
    password: "$p"
    server-name: $sn
    alpn: ["h3"]
    zero-rtt: true
EOF
    say ''
    say '官方客户端（shadowquic -c client.yaml）：'
    cat <<EOF
inbound:
    type: socks
    bind-addr: "127.0.0.1:1089"
outbound:
    type: shadowquic
    addr: "<VPS_IP>:$SQ_PORT"
    username: "$u"
    password: "$p"
    server-name: $sn
    alpn: ["h3"]
    initial-mtu: 1300
    congestion-control: bbr
    zero-rtt: true
    gso: true
    over-stream: false
log-level: "info"
EOF
}

sq_remove() {
    sq_stop_process
    if has_systemd; then
        systemctl disable suoha-shadowquic >/dev/null 2>&1 || true
        rm -f "$SQ_UNIT"; systemctl daemon-reload 2>/dev/null || true
    fi
    rc-update del suoha-shadowquic default >/dev/null 2>&1 || true
    rm -f "$SQ_INIT" /usr/local/bin/suoha-quic-daemon.sh
    if sq_owned; then
        rm -f "$SQ_APP_DIR/server-direct.yaml" "$SQ_APP_DIR/server-socks.yaml" \
              "$SQ_APP_DIR/last-mode" "$(sq_marker_path)" 2>/dev/null || true
        rmdir "$SQ_APP_DIR" 2>/dev/null || true
    else
        warn "$SQ_APP_DIR 不属于 Suoha Plus，已保留配置不动。"
    fi
    ok 'ShadowQuic 已卸载（二进制保留在 /usr/local/bin/shadowquic，如需删除请手动）'
}

sq_menu() {
    while true; do
        banner
        sq_status_line
        say ""
        say '1) 安装/更新 ShadowQuic'
        say '2) 启动 ShadowQuic'
        say '3) 停止 ShadowQuic'
        say '4) 重启 ShadowQuic'
        say '5) 查看客户端接入信息'
        say '6) 查看日志（末 30 行）'
        say '7) 卸载 ShadowQuic'
        say '8) 检查更新 / 升级到最新版本'
        say '0) 返回主菜单'
        safe_read m '请选择 [0]: ' '0'
        case "${m:-0}" in
            1) sq_setup; pause_screen ;;
            8) sq_upgrade; pause_screen ;;
            2) sq_start; sq_status_line; pause_screen ;;
            3) sq_stop_process; ok 'ShadowQuic 已停止。'; pause_screen ;;
            4) sq_start; sq_status_line; pause_screen ;;
            5) [ -f "$SQ_APP_DIR/server-direct.yaml" ] && sq_show_info || warn '尚未安装。'; pause_screen ;;
            6) tail -n 30 "$SQ_LOG" 2>/dev/null || warn '无日志。'; pause_screen ;;
            7) safe_read yn '确认卸载 ShadowQuic？[y/N]: ' ''; case "$yn" in y|Y) sq_remove ;; *) warn '已取消。' ;; esac; pause_screen ;;
            0) break ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        banner
        if [ -f "$STATE_FILE" ]; then
            show_status
            say ""
        else
            info '尚未安装 Suoha Plus。原 suoha.sh 不受影响。'
            say ""
        fi
        say '1) 安装/启动 Quick Tunnel（重启后需重新生成地址）'
        say '2) 安装/启动持久化 Tunnel（需要 Cloudflare 域名授权）'
        say '3) 安装/启动 Reality 直连节点（无需域名，vless+Vision）'
        say '4) 服务管理'
        say '5) 配置管理（修改后自动重启并刷新节点）'
        say '6) 查看当前节点信息'
        say '7) 卸载管理（删除 Xray / 隧道 / 全部）'
        say '8) 安装/管理 ShadowQuic（QUIC 代理，UDP，可选模块）'
        say '9) 组件版本（检查更新 / 升级 Xray、cloudflared）'
        say '0) 退出'
        safe_read m '请选择 [0]: ' '0'
        case "${m:-0}" in
            1) setup_quick; pause_screen ;;
            2) setup_persistent; pause_screen ;;
            3) setup_reality; pause_screen ;;
            4) service_menu ;;
            5) config_menu ;;
            6) print_nodes; pause_screen ;;
            7) uninstall_menu ;;
            8) sq_menu ;;
            9) component_menu ;;
            0) say '退出成功。'; exit 0 ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --version|-v) printf '%s %s | Xray %s | cloudflared %s\n' "$APP_NAME" "$APP_VERSION" "$XRAY_VERSION" "$CLOUDFLARED_VERSION"; exit 0 ;;
    --help|-h)
        cat <<EOF
用法：sudo bash $0

Suoha Plus 是原 suoha.sh 的独立增强版（v$APP_VERSION）：
- 固定 Xray $XRAY_VERSION 和 cloudflared $CLOUDFLARED_VERSION（可用 SUOHA_XRAY_VERSION /
  SUOHA_CLOUDFLARED_VERSION 环境变量覆盖，或用菜单 9 检查更新后升级）；
- 三种模式：Quick Tunnel / 持久化 Tunnel / Reality 直连节点（vless+XTLS Vision）；
- Reality 模式：免域名免隧道，自动生成密钥，IPv4/IPv6 双栈节点链接，可与 WS 隧道共存；
  安装时可指定连接地址（域名/IPv4/[IPv6]），留空则自动输出双栈链接；
- WS 模式默认优选接入域名 www.visa.com（大厂自有域名，解析到 Cloudflare 边缘）；
- 修改 Xray / Tunnel 配置后自动校验、重启并重新生成节点；
- 所有下载（Xray/cloudflared/ShadowQuic/系统依赖）都需确认，并显示实时进度；
- 使用独立目录 $APP_DIR、独立服务名和命令 $CMD_LINK；
- 不删除或覆盖原 suoha.sh。
EOF
        exit 0
        ;;
esac

load_state

# 并发互斥锁。
# 关键：后台服务（nohup 启动的 xray/cloudflared）会继承本进程已打开的 fd，
# 所以所有 nohup 启动处都必须带 9>&-，否则脚本退出后锁被常驻服务持有，
# 用户将再也无法打开本脚本。
if command_exists flock; then
    if { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
        flock -n 9 2>/dev/null || { err '另一个 Suoha Plus 实例正在运行，请稍后重试。'; exit 1; }
    fi
fi

# 安装中断 / Ctrl+C / 正常退出都清理临时目录
if command_exists trap; then
    trap 'cleanup_on_exit' INT TERM HUP EXIT
fi

main_menu

cleanup_on_exit
if [ -e /proc/$$/fd/9 ]; then
    exec 9>&-
fi
