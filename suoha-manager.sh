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
APP_VERSION="2.1.0"
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
        ""|*[!A-Za-z0-9._:-]*) err "节点地址只能包含域名、IPv4、IPv6 和端口所需字符。"; return 1 ;;
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
      "listen": "0.0.0.0",
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
    local host label tmp json path_q
    host="$(current_tunnel_host)"
    label="$(url_label "$ISP_TAG")"
    tmp="$(mktemp "$APP_DIR/v2ray.txt.XXXXXX")" || return 1
    {
        printf '# Suoha Plus 节点信息（自动生成，请勿手动编辑）\n'
        printf '# Xray %s | cloudflared %s\n' "$XRAY_VERSION" "$CLOUDFLARED_VERSION"
        if [ "$REALITY_ENABLED" = "yes" ]; then
            printf '# Reality 直连节点 | 端口：%s | SNI：%s\n\n' "$REALITY_PORT" "$REALITY_SNI"
            printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s_reality\n' "$UUID" "$NODE_ADDRESS" "$REALITY_PORT" "$REALITY_SNI" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$label"
            printf '\n# 提示：Reality 为 VPS 直连，无需域名/隧道/优选；fp 也可试 ios、safari\n'
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
}

print_nodes() {
    [ -f "$NODE_FILE" ] || generate_nodes || return 1
    say "${C_GREEN}──────── 当前节点信息 ────────${C_RESET}"
    cat "$NODE_FILE"
    say "${C_GREEN}──────────────────────────────${C_RESET}"
    info "节点文件：$NODE_FILE"
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
    [ "$MODE" = "persistent" ] || return 1
    [ -x "$CF_BIN" ] || { err "cloudflared 尚未安装。"; return 1; }
    [ -f "$CF_CONFIG" ] || write_cloudflared_config || return 1
    if has_systemd; then
        systemctl start "$SERVICE_CF"
        return $?
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

remove_systemd_units() {
    if has_systemd; then
        systemctl disable --now "$SERVICE_CF" "$SERVICE_XRAY" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$SERVICE_CF" "/etc/systemd/system/$SERVICE_XRAY"
        systemctl daemon-reload >/dev/null 2>&1 || true
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
    NODE_ADDRESS="$(ask_default '节点连接地址（填 VPS 公网 IP 或域名）' "$(public_ip 2>/dev/null || echo '')")"
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
}

status_line() {
    local name="$1" unit="$2" pidfile="$3"
    if [ "$MODE" = "persistent" ] && has_systemd; then
        printf '%-22s %s\n' "$name" "$(systemctl is-active "$unit" 2>/dev/null || printf 'unknown')"
    elif pid_running "$pidfile"; then
        printf '%-22s running (PID %s)\n' "$name" "$(cat "$pidfile")"
    else
        printf '%-22s stopped\n' "$name"
    fi
}

show_status() {
    show_config
    say ""
    status_line "Xray" "$SERVICE_XRAY" "$XRAY_PID"
    status_line "Cloudflare Tunnel" "$SERVICE_CF" "$CF_PID"
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
            0|'') return 0 ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
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
                    if [ "$REALITY_ENABLED" = "yes" ]; then
                        : # Reality 直连，无需隧道
                    elif [ "$MODE" = "quick" ]; then start_quick_tunnel; else start_persistent_tunnel; fi
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

Suoha Plus 是原 suoha.sh 的独立增强版：
- 固定 Xray $XRAY_VERSION 和 cloudflared $CLOUDFLARED_VERSION，不使用 latest；
- 修改 Xray / Tunnel 配置后自动校验、重启并重新生成节点；
- 使用独立目录 $APP_DIR、独立服务名和命令 $CMD_LINK；
- 不删除或覆盖原 suoha.sh。
EOF
        exit 0
        ;;
esac

load_state
main_menu
