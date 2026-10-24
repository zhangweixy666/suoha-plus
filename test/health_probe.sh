#!/bin/bash
# 验证 health_check 里的状态码提取逻辑（用真实 curl 输出，不启动服务）。
SRC="${1:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/suoha-manager.sh}"

echo "1) 真实 404 响应 → 提取状态码"
H="$(curl -s -o /dev/null -D - --max-time 10 --http1.1 \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        'https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/__nope-path__' 2>/dev/null)"
CODE="$(printf '%s' "$H" | sed -n 's#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | tail -n 1)"
echo "   提取结果: [$CODE]  （期望 404）"
if [ "$CODE" = "404" ]; then echo "   PASS"; else echo "   FAIL"; fi

echo
echo "2) 真实 200 响应 → 提取状态码"
H="$(curl -s -o /dev/null -D - --max-time 10 'https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/README.md' 2>/dev/null)"
CODE="$(printf '%s' "$H" | sed -n 's#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | tail -n 1)"
echo "   提取结果: [$CODE]  （期望 200）"
if [ "$CODE" = "200" ]; then echo "   PASS"; else echo "   FAIL"; fi

echo
echo "3) 多段响应（重定向链，应取最后一个状态码）"
H="$(printf 'HTTP/1.1 301 Moved\nHTTP/1.1 200 OK\n')"
CODE="$(printf '%s' "$H" | sed -n 's#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | tail -n 1)"
echo "   提取结果: [$CODE]  （期望 200）"
if [ "$CODE" = "200" ]; then echo "   PASS"; else echo "   FAIL"; fi

echo
echo "4) 空响应（连不上）→ 应提取为空"
CODE="$(printf '' | sed -n 's#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | tail -n 1)"
echo "   提取结果: [$CODE]  （期望空）"
if [ -z "$CODE" ]; then echo "   PASS"; else echo "   FAIL"; fi

echo
echo "5) 判定矩阵（源码同一套分支）"
judge() {
    case "$1" in
        101|400|426) echo healthy ;;
        *) echo unhealthy ;;
    esac
}
for c in 101 400 426 404 530 502 "" 200; do
    printf '   HTTP [%-4s] -> %s\n' "$c" "$(judge "$c")"
done