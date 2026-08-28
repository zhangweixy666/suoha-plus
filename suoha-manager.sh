#!/usr/bin/env bash
# Suoha Plus - Xray + Cloudflare Tunnel 管理脚本
# 基于原 suoha.sh 的独立增强版：不会覆盖、删除或调用原脚本。
# 固定版本（2026-08-27 查询到的 GitHub 最新正式版）

# 管道自重放：支持 wget -qO- URL | sh 一键运行（下载副本后用真实 tty 重启自身）
if [ ! -t 0 ]; then
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
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$_install_path" "$_self_url" 2>/dev/null || \
        wget -qO "$_install_path" "$_self_url" 2>/dev/null
    else
        wget -qO "$_install_path" "$_self_url" 2>/dev/null
    fi
    if [ -s "$_install_path" ]; then
        chmod +x "$_install_path" 2>/dev/null
        export SUOHA_TTY=1
        if [ -r /dev/tty ]; then
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
APP_VERSION="2.3.0"
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
SERVICE_XRAY="suoha-plus-xray.service"
SERVICE_CF="suoha-plus-cloudflared.service"

XRAY_VERSION="v26.3.27"
CLOUDFLARED_VERSION="2026.8.2"
SQ_PORT="1443"
XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION"
CF_RELEASE_BASE="https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION"

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
    printf '\n按回车继续...' >&2
    read -r _
}

ask_default() {
    local prompt="$1" default="$2" answer
    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

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

    case "$NODE_ADDRESS" in
        ""|*[!A-Za-z0-9._:\[\]-]*) err "节点地址只能包含域名、IPv4、IPv6（[方括号]）和端口所需字符。"; return 1 ;;
    esac
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

has_openrc() {
    ! has_systemd && command_exists rc-update && [ -d /etc/init.d ] && command_exists rc-service
}

install_dependencies() {
    local missing=0
    command_exists curl || missing=1
    command_exists unzip || missing=1
    command_exists base64 || missing=1
    if [ "$missing" = "0" ]; then return 0; fi

    info "正在安装 curl、unzip、base64 等依赖..."
    if command_exists apt-get; then
        apt-get update && apt-get install -y curl unzip coreutils ca-certificates || return 1
    elif command_exists dnf; then
        dnf install -y curl unzip coreutils ca-certificates || return 1
    elif command_exists yum; then
        yum install -y curl unzip coreutils ca-certificates || return 1
    elif command_exists apk; then
        apk add --no-cache curl unzip coreutils ca-certificates || return 1
    else
        err "找不到 apt-get/dnf/yum/apk，请手动安装 curl、unzip、base64。"
        return 1
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

download_binaries() {
    set_arch_assets || return 1
    mkdir -p "$BIN_DIR" "$TMP_DIR" || return 1
    local tmp xray_candidate
    tmp="$(mktemp -d "$TMP_DIR/download.XXXXXX")" || return 1
    info "下载固定版 Xray $XRAY_VERSION ($XRAY_ASSET)..."
    if ! curl -fL --retry 3 --connect-timeout 15 -o "$tmp/xray.zip" "${XRAY_RELEASE_BASE}/${XRAY_ASSET}"; then
        rm -rf "$tmp"; err "Xray 下载失败。"; return 1
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

    info "下载固定版 cloudflared $CLOUDFLARED_VERSION ($CF_ASSET)..."
    if ! curl -fL --retry 3 --connect-timeout 15 -o "$tmp/cloudflared" "${CF_RELEASE_BASE}/${CF_ASSET}"; then
        rm -rf "$tmp"; err "cloudflared 下载失败。"; return 1
    fi
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
    case "$REALITY_DEST" in
        *:*) : ;;
        *) REALITY_DEST="$REALITY_DEST:443" ;;
    esac
    [ -n "$REALITY_SNI" ] || { err "Reality SNI 不能为空。"; return 1; }
    [ -n "$REALITY_PRIVATE" ] || { err "缺少 Reality 私钥，请重新安装 Reality 节点。"; return 1; }
    [ -n "$REALITY_PUBLIC" ] || { err "缺少 Reality 公钥，请重新安装 Reality 节点。"; return 1; }
    if ! [[ "$REALITY_SHORT_ID" =~ ^[0-9a-f]*$ ]] || [ $(( ${#REALITY_SHORT_ID} % 2 )) -ne 0 ] || [ "${#REALITY_SHORT_ID}" -gt 16 ]; then
        err "Reality shortId 必须是 0-f 的偶数长度十六进制（最长16位）。"; return 1
    fi
    return 0
}

write_xray_config() {
    validate_common || return 1
    validate_reality || return 1
    mkdir -p "$APP_DIR" "$LOG_DIR" || return 1
    local tmp tmpdir
    tmpdir="$(mktemp -d "$APP_DIR/.xcfg.XXXXXX")" || return 1
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
    local host label tmp json path_q ip4 ip6
    host="$(current_tunnel_host)"
    label="$(url_label "$ISP_TAG")"
    ip4="$(public_ip 2>/dev/null || true)"
    ip6="$(public_ip6 2>/dev/null || true)"
    ip6="${ip6#[}"
    tmp="$(mktemp "$APP_DIR/v2ray.txt.XXXXXX")" || return 1
    {
        printf '# Suoha Plus 节点信息（自动生成，请勿手动编辑）\n'
        printf '# Xray %s | cloudflared %s\n' "$XRAY_VERSION" "$CLOUDFLARED_VERSION"
        if [ "$REALITY_ENABLED" = "yes" ]; then
            printf '# Reality 直连节点 | 端口：%s | SNI：%s | 同时监听 IPv4 + IPv6\n\n' "$REALITY_PORT" "$REALITY_SNI"
            if [ -n "$ip4" ]; then
                printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s_reality_v4\n' "$UUID" "$ip4" "$REALITY_PORT" "$REALITY_SNI" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$label"
            fi
            if [ -n "$ip6" ]; then
                printf 'vless://%s@[%s]:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s_reality_v6\n' "$UUID" "$ip6" "$REALITY_PORT" "$REALITY_SNI" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$label"
            fi
            printf '\n# 提示：Reality 为 VPS 直连，无需域名/隧道/优选；fp 也可试 ios、safari\n'
            printf '# IPv4/IPv6 两条链接二选一：有 v6 用 v6（NAT 机器端口全开），只有 v4 用 v4\n'
            if [ -n "$host" ]; then
                path_q="$(printf '%s' "$WS_PATH" | sed 's/%/%25/g; s#/#%2F#g')"
                printf '\n# —— WS+隧道节点（与 Reality 共存，域名固定）——\n\n'
                printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s_tls\n' "$UUID" "$host" "$host" "$host" "$path_q" "$label"
                printf '\n# TLS 端口可尝试：443、2053、2083、2087、2096、8443\n'
                printf 'vless://%s@%s:80?encryption=none&security=none&type=ws&host=%s&path=%s#%s\n' "$UUID" "$NODE_ADDRESS" "$host" "$path_q" "$label"
                printf '# 明文端口可尝试：80、8080、8880、2052、2082、2086、2095\n'
                printf '# 注意：WS 节点连接地址建议优选（当前沿用 Reality 的地址设置）\n'
            fi
        elif [ -z "$host" ]; then
            printf '# 隧道尚未启动，启动成功后再次运行本脚本即可生成节点。\n'
        elif [ "$PROTOCOL" = "vmess" ]; then
            json="$(printf '{"v":"2","ps":"%s_tls","add":"%s","port":"443","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s"}' "$ISP_TAG" "$NODE_ADDRESS" "$UUID" "$host" "$WS_PATH" "$host")"
            printf 'vmess://%s\n' "$(printf '%s' "$json" | base64_no_wrap | fold -w 76)"
            printf '\n# TLS 端口可尝试：443、2053、2083、2087、2096、8443\n'
            json="$(printf '{"v":"2","ps":"%s","add":"%s","port":"80","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"%s","tls":""}' "$ISP_TAG" "$NODE_ADDRESS" "$UUID" "$host" "$WS_PATH")"
            printf 'vmess://%s\n' "$(printf '%s' "$json" | base64_no_wrap | fold -w 76)"
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
    if [ "$MODE" = "persistent" ] && has_systemd; then
        systemctl start "$SERVICE_XRAY"
        return $?
    fi
    if [ "$MODE" = "persistent" ] && has_openrc; then
        rc-service suoha-plus-xray start 2>/dev/null || return 1
        return 0
    fi
    stop_pid "$XRAY_PID"
    nohup "$XRAY_BIN" run -config "$XRAY_CONFIG" >> "$XRAY_LOG" 2>&1 < /dev/null &
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
    nohup "$CF_BIN" tunnel --url "http://127.0.0.1:$XRAY_PORT" --no-autoupdate --edge-ip-version "$EDGE_IP" --protocol "$CF_PROTOCOL" > "$CF_LOG" 2>&1 < /dev/null &
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
    if has_systemd; then
        systemctl start "$SERVICE_CF"
        return $?
    fi
    if has_openrc; then
        rc-service suoha-plus-cloudflared start 2>/dev/null || return 1
        return 0
    fi
    stop_pid "$CF_PID"
    nohup "$CF_BIN" tunnel --config "$CF_CONFIG" run "$TUNNEL_NAME" >> "$CF_LOG" 2>&1 < /dev/null &
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
    if [ "$MODE" = "persistent" ] && has_systemd; then
        systemctl stop "$SERVICE_CF" 2>/dev/null || true
        systemctl stop "$SERVICE_XRAY" 2>/dev/null || true
    elif [ "$MODE" = "persistent" ] && has_openrc; then
        rc-service suoha-plus-cloudflared stop 2>/dev/null || true
        rc-service suoha-plus-xray stop 2>/dev/null || true
    fi
    stop_pid "$CF_PID"
    stop_pid "$XRAY_PID"
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
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    cat > "/etc/systemd/system/$SERVICE_CF" <<EOF
[Unit]
Description=Suoha Plus Cloudflare Tunnel
Wants=network-online.target
After=network-online.target $SERVICE_XRAY

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$CF_BIN tunnel --config $CF_CONFIG run $TUNNEL_NAME
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "/etc/systemd/system/$SERVICE_XRAY" "/etc/systemd/system/$SERVICE_CF"
    systemctl daemon-reload
    systemctl enable "$SERVICE_XRAY" "$SERVICE_CF" >/dev/null
    ok "已写入独立 systemd 服务：$SERVICE_XRAY、$SERVICE_CF"
}

install_openrc_units() {
    has_openrc || return 0
    mkdir -p /etc/init.d || return 1
    OINIT_XRAY="/etc/init.d/suoha-plus-xray"
    OINIT_CF="/etc/init.d/suoha-plus-cloudflared"
    cat > "$OINIT_XRAY" <<EOF
#!/sbin/openrc-run
name="suoha-plus-xray"
description="Suoha Plus Xray"
command="$XRAY_BIN"
command_args="run -config $XRAY_CONFIG"
command_background="yes"
pidfile="$XRAY_PID"
output_log="$XRAY_LOG"
error_log="$XRAY_LOG"
depend() { need net; after firewall; }
EOF
    cat > "$OINIT_CF" <<EOF
#!/sbin/openrc-run
name="suoha-plus-cloudflared"
description="Suoha Plus Cloudflare Tunnel"
command="$CF_BIN"
command_args="tunnel --config $CF_CONFIG run $TUNNEL_NAME"
command_background="yes"
pidfile="$CF_PID"
output_log="$CF_LOG"
error_log="$CF_LOG"
depend() { need net; after firewall $OINIT_XRAY; }
EOF
    chmod 755 "$OINIT_XRAY" "$OINIT_CF"
    rc-update add suoha-plus-xray default >/dev/null 2>&1 || true
    rc-update add suoha-plus-cloudflared default >/dev/null 2>&1 || true
    ok "已写入 OpenRC 服务：suoha-plus-xray、suoha-plus-cloudflared"
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
    warn '将删除本机全部 Cloudflare 配置（授权文件 + 隧道凭据）并清理账号上的同名旧隧道，然后重新登录。'
    stop_services 2>/dev/null || true
    cf_delete_tunnel_record "$TUNNEL_NAME" && ok "已删除账号上的旧隧道：$TUNNEL_NAME" || warn "旧隧道删除失败（可能已不存在），继续。"
    rm -rf /root/.cloudflared
    rm -f "$APP_DIR/tunnel-create.log"
    TUNNEL_ID=""
    ok '本地 Cloudflare 配置已清空。'
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

setup_reality() {
    need_root || return 1
    local old_mode="$MODE" old_reality="$REALITY_ENABLED"
    stop_services 2>/dev/null || true
    remove_systemd_units
    MODE="reality"
    REALITY_ENABLED="yes"
    ensure_software || { MODE="$old_mode"; REALITY_ENABLED="$old_reality"; return 1; }
    say ""
    info "正在生成 Reality 密钥（x25519）..."
    generate_reality_keys || { MODE="$old_mode"; REALITY_ENABLED="$old_reality"; return 1; }
    say ""
    say '请确认 Reality 节点参数（直接回车使用默认值）：'
    REALITY_PORT="$(ask_default 'Reality 监听端口（公网直连）' "$REALITY_PORT")"
    REALITY_DEST="$(ask_default '目标网站 dest（域名或 域名:端口，需支持 TLS1.3+h2）' "$REALITY_DEST")"
    REALITY_SNI="$(ask_default 'SNI（一般与 dest 域名一致）' "$REALITY_SNI")"
    NODE_ADDRESS="$(ask_default '节点连接地址（默认IPv6，可改IPv4/域名）' "$(reality_default_address 2>/dev/null || echo '')")"
    UUID="$(ask_default 'UUID' "$UUID")"
    validate_reality || { MODE="$old_mode"; REALITY_ENABLED="$old_reality"; return 1; }
    validate_common || { MODE="$old_mode"; REALITY_ENABLED="$old_reality"; return 1; }
    mkdir -p "$APP_DIR" "$LOG_DIR" "$TMP_DIR"
    write_xray_config || { MODE="$old_mode"; REALITY_ENABLED="$old_reality"; return 1; }
    save_state
    start_xray || return 1
    save_state
    generate_nodes
    print_nodes
    ok "Reality 直连节点安装完成；管理命令：$CMD_LINK"
}

public_ip() {
    local ip
    ip="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$ip" ] || ip="$(curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    printf '%s' "$ip"
}

public_ip6() {
    local ip
    ip="$(curl -fsS6 --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
    if [ -z "$ip" ]; then
        ip="$(ip -6 addr show scope global 2>/dev/null | grep -o 'inet6 [0-9a-f:]*' | awk '{print $2}' | grep -v '^fe80' | head -n 1)"
    fi
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
    local old_mode="$MODE"
    stop_services 2>/dev/null || true
    remove_systemd_units
    MODE="quick"
    QUICK_URL=""
    ensure_software || { MODE="$old_mode"; return 1; }
    configure_xray || return 1
    configure_tunnel || return 1
    mkdir -p "$APP_DIR" "$LOG_DIR" "$TMP_DIR"
    write_xray_config || return 1
    save_state
    start_xray || return 1
    start_quick_tunnel || return 1
    save_state
    generate_nodes
    print_nodes
}

setup_persistent() {
    need_root || return 1
    local old_mode="$MODE"
    # 已有 Cloudflare 配置（重装场景）→ 询问是否清空重新登录
    if [ -d /root/.cloudflared ] || [ -n "$TUNNEL_ID" ]; then
        say ""
        warn '检测到已有 Cloudflare 配置（授权/凭据）。'
        read -r -p '删除全部 Cloudflare 配置并重新登录？[y/N]: ' cfans
        case "$cfans" in
            y|Y) cf_full_cleanup || { MODE="$old_mode"; return 1; } ;;
            *) info '保留现有配置，复用授权文件与隧道。' ;;
        esac
    fi
    stop_services 2>/dev/null || true
    MODE="persistent"
    QUICK_URL=""
    ensure_software || { MODE="$old_mode"; return 1; }
    configure_xray || return 1
    configure_tunnel || return 1
    mkdir -p "$APP_DIR" "$LOG_DIR" "$TMP_DIR"
    ensure_named_tunnel || return 1
    route_domain || return 1
    write_xray_config || return 1
    write_cloudflared_config || return 1
    save_state
    install_systemd_units || return 1
    install_openrc_units || return 1
    start_xray || return 1
    start_persistent_tunnel || return 1
    save_state
    generate_nodes
    print_nodes
    ok "持久化服务安装完成；管理命令：$CMD_LINK"
}

show_config() {
    say "${C_CYAN}当前运行配置${C_RESET}"
    printf '模式          : %s\n' "$MODE"
    printf 'Xray 协议     : %s\n' "$PROTOCOL"
    printf 'Xray 版本     : %s（固定）\n' "$XRAY_VERSION"
    if [ "$REALITY_ENABLED" = "yes" ]; then
        printf 'Reality 端口  : %s\n' "$REALITY_PORT"
        printf 'Reality dest  : %s\n' "$REALITY_DEST"
        printf 'Reality SNI   : %s\n' "$REALITY_SNI"
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
    printf '配置位置      : %s | %s\n' "$XRAY_CONFIG" "${QUICK_URL:+$CF_CONFIG}"
    [ -f "$SQ_APP_DIR/server-direct.yaml" ] && printf '                ShadowQuic: %s（手动编辑后用菜单8重启生效）\n' "$SQ_APP_DIR/server-direct.yaml"
}

status_line() {
    local name="$1" unit="$2" pidfile="$3" st pid
    if [ "$MODE" = "persistent" ] && has_systemd; then
        st="$(systemctl is-active "$unit" 2>/dev/null || printf 'unknown')"
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null)"
        [ "$pid" = "0" ] && pid=""
    elif pid_running "$pidfile"; then
        st="running"
        pid="$(cat "$pidfile" 2>/dev/null)"
    else
        st="stopped"
    fi
    if [ "$st" = "active" ] || [ "$st" = "running" ]; then
        say "${C_GREEN}● $name：运行中${C_RESET}  (PID ${pid:-—})"
    else
        say "${C_RED}○ $name：未运行${C_RESET}"
    fi
}

health_check() {
    # 只在服务声称运行时做实测：Reality 端口监听 / 隧道 WS 链路探测
    local xray_alive=0 cf_alive=0
    { pid_running "$XRAY_PID" || { [ "$MODE" = "persistent" ] && has_systemd && [ "$(systemctl is-active "$SERVICE_XRAY" 2>/dev/null)" = "active" ]; }; } && xray_alive=1
    { pid_running "$CF_PID" || { [ "$MODE" = "persistent" ] && has_systemd && [ "$(systemctl is-active "$SERVICE_CF" 2>/dev/null)" = "active" ]; }; } && cf_alive=1
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
            if curl -s -o /dev/null --max-time 6 "https://$host$WS_PATH"; then
                say "${C_GREEN}✓ 隧道健康    ：$host$WS_PATH 链路探测通过${C_RESET}"
            else
                say "${C_RED}✗ 隧道异常    ：$host$WS_PATH 探测失败（查 Tunnel 日志）${C_RESET}"
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
        read -r -p '请选择: ' menu
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
                    read -r -p "现在执行 route dns 更新？[y/N]: " answer
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
    read -r -p '请选择: ' m
    local sq_file
    case "${m:-0}" in
        1) "$editor" "$XRAY_CONFIG" && apply_config_now || true ;;
        2) [ -f "$CF_CONFIG" ] && "$editor" "$CF_CONFIG" && restart_services || warn '隧道配置文件不存在（Quick 模式自动生成）。' ;;
        3) [ -f "$SQ_APP_DIR/server-direct.yaml" ] && "$editor" "$SQ_APP_DIR/server-direct.yaml" && sq_start || warn 'ShadowQuic 尚未安装。' ;;
        4) [ -f "$SQ_APP_DIR/server-socks.yaml" ] && "$editor" "$SQ_APP_DIR/server-socks.yaml" || warn 'ShadowQuic 尚未安装。' ;;
        5)
            read -r -p "当前模式：$(cat "$SQ_APP_DIR/last-mode" 2>/dev/null || echo direct)，切换到 [direct/socks]: " mm
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
    read -r -p '确认卸载请输入 UNINSTALL: ' answer
    [ "$answer" = "UNINSTALL" ] || { info '已取消。'; return 0; }
    stop_services 2>/dev/null || true
    remove_systemd_units
    rm -f "$CMD_LINK"
    rm -rf "$APP_DIR"
    ok 'Suoha Plus 已卸载；原脚本和原安装目录未改动。'
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
        read -r -p '请选择: ' menu
        case "$menu" in
            1)
                read -r -p '确认删除 Xray 服务？[y/N]: ' answer
                case "$answer" in
                    y|Y) uninstall_component xray; pause_screen ;;
                esac
                ;;
            2)
                read -r -p '确认删除 Cloudflare Tunnel 服务？[y/N]: ' answer
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
        read -r -p '请选择: ' menu
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

sq_write_configs() {
    local u="$1" p="$2" sq_sn="$3" sq_up="$4"
    mkdir -p "$SQ_APP_DIR"
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
}

sq_write_service() {
    if has_systemd; then
        cat > "$SQ_UNIT" <<EOF
[Unit]
Description=Suoha Plus ShadowQuic (QUIC proxy with SNI camouflage)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SQ_BIN -c $SQ_APP_DIR/server-\$(cat $SQ_APP_DIR/last-mode 2>/dev/null || echo direct).yaml
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
        nohup /usr/local/bin/suoha-quic-daemon.sh < /dev/null > /dev/null 2>&1 &
        echo $! > /run/suoha-shadowquic.pid
    fi
    sleep 2
}

sq_stop_process() {
    # 停掉 suoha 管的服务（含可能被接管的旧服务）
    if has_systemd; then
        systemctl stop suoha-shadowquic 2>/dev/null || true
        systemctl stop shadowquic 2>/dev/null || true
    fi
    [ -f /etc/init.d/shadowquic ] && /etc/init.d/shadowquic stop 2>/dev/null || true
    [ -f "$SQ_INIT" ] && /etc/init.d/suoha-shadowquic stop 2>/dev/null || true
    pkill -f '[s]hadowquic -c' 2>/dev/null || true
    pkill -f '[s]hadowquic-daemon.sh' 2>/dev/null || true
    pkill -f '[s]uoha-quic-daemon.sh' 2>/dev/null || true
    if command_exists pgrep; then
        for p in $(pgrep -f '[s]hadowquic'); do kill -9 "$p" 2>/dev/null || true; done
    fi
    sleep 1
}

sq_status_line() {
    local st="未运行"
    if has_systemd && [ -f "$SQ_UNIT" ]; then
        [ "$(systemctl is-active suoha-shadowquic 2>/dev/null)" = "active" ] && st="运行中"
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
    # 二进制
    if ! sq_installed; then
        local ver
        info '获取 shadowquic 最新版本...'
        ver="$(curl -sL --max-time 8 https://api.github.com/repos/spongebob888/shadowquic/releases/latest | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
        [ -n "$ver" ] || ver="$SQ_VERSION_FALLBACK"
        info "下载 shadowquic $ver ..."
        if curl -fsSL --max-time 120 -o /tmp/.sq.dl "https://github.com/spongebob888/shadowquic/releases/download/$ver/shadowquic-x86_64-linux-musl" 2>/dev/null; then
            if [ "$(head -c 4 /tmp/.sq.dl 2>/dev/null)" = "$(printf '\x7f\x45\x4c\x46')" ]; then
                chmod +x /tmp/.sq.dl && mv -f /tmp/.sq.dl "$SQ_BIN"
                ok "shadowquic 安装完成"
            else
                rm -f /tmp/.sq.dl; err '下载内容不是有效的 ELF 可执行文件。'; return 1
            fi
        else
            rm -f /tmp/.sq.dl; err '下载失败，请检查网络。'; return 1
        fi
    else
        info 'shadowquic 二进制已存在，跳过下载。'
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
    # 清理旧的 shadowquic 服务注册（已被 suoha-shadowquic 取代，防止开机双启）
    if [ -f /etc/init.d/shadowquic ]; then
        rc-update del shadowquic default >/dev/null 2>&1 || true
        rm -f /etc/init.d/shadowquic
        info '已移除旧的 shadowquic 服务（配置由本脚本接管）。'
    fi
    if [ -f /etc/systemd/system/shadowquic.service ]; then
        systemctl disable shadowquic >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/shadowquic.service; systemctl daemon-reload 2>/dev/null || true
        info '已移除旧的 shadowquic systemd 服务。'
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
    rm -f "$SQ_INIT" /usr/local/bin/suoha-quic-daemon.sh
    rm -rf "$SQ_APP_DIR"
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
        say '0) 返回主菜单'
        read -r -p '请选择 [0]: ' m
        case "${m:-0}" in
            1) sq_setup; pause_screen ;;
            2) sq_start; sq_status_line; pause_screen ;;
            3) sq_stop_process; ok 'ShadowQuic 已停止。'; pause_screen ;;
            4) sq_start; sq_status_line; pause_screen ;;
            5) [ -f "$SQ_APP_DIR/server-direct.yaml" ] && sq_show_info || warn '尚未安装。'; pause_screen ;;
            6) tail -n 30 "$SQ_LOG" 2>/dev/null || warn '无日志。'; pause_screen ;;
            7) read -r -p '确认卸载 ShadowQuic？[y/N]: ' yn; case "$yn" in y|Y) sq_remove ;; *) warn '已取消。' ;; esac; pause_screen ;;
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
        say '0) 退出'
        read -r -p '请选择 [0]: ' menu
        case "${menu:-0}" in
            1) setup_quick; pause_screen ;;
            2) setup_persistent; pause_screen ;;
            3) setup_reality; pause_screen ;;
            4) service_menu ;;
            5) config_menu ;;
            6) print_nodes; pause_screen ;;
            7) uninstall_menu ;;
            8) sq_menu ;;
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
- 固定 Xray $XRAY_VERSION 和 cloudflared $CLOUDFLARED_VERSION，不使用 latest；
- 三种模式：Quick Tunnel / 持久化 Tunnel / Reality 直连节点（vless+XTLS Vision）；
- Reality 模式：免域名免隧道，自动生成密钥，IPv4/IPv6 双栈节点链接，可与 WS 隧道共存；
- WS 模式默认优选接入域名 www.visa.com（大厂自有域名，解析到 Cloudflare 边缘）；
- 修改 Xray / Tunnel 配置后自动校验、重启并重新生成节点；
- 使用独立目录 $APP_DIR、独立服务名和命令 $CMD_LINK；
- 不删除或覆盖原 suoha.sh。
EOF
        exit 0
        ;;
esac

load_state
main_menu
