#!/bin/bash
# 用 script(1) 伪造 tty，真实跑一次 dl_run，观察进度条是否原地刷新。
# 只下载一个 18KB 的 README，不需要 root、不碰系统目录。

SRC="${1:-/sdcard/Download/suoha-plus/suoha-manager.sh}"
WORK="$(mktemp -d /tmp/dltty.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

extract() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) *\\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$SRC"
}

{
    echo 'info() { printf "[信息] %s\n" "$*" >&2; }'
    echo 'ok()   { printf "[完成] %s\n" "$*" >&2; }'
    echo 'err()  { printf "[错误] %s\n" "$*" >&2; }'
    echo 'say()  { printf "%b\n" "$*"; }'
    for f in human_bytes dl_remote_size dl_render dl_run; do
        extract "$f"
        echo
    done
    echo 'DEST="$1"'
    echo 'dl_run "README" "https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/README.md" "$DEST" 60'
} > "$WORK/run.sh"

# script 会创建伪终端，让 [ -t 2 ] 判定为真，走进度渲染分支
script -q -c "bash $WORK/run.sh $WORK/out.md" /dev/null > "$WORK/raw.txt" 2>&1

echo "--- 原始输出（\\r 转成 <CR> 便于观察）---"
sed -n 'l' "$WORK/raw.txt" | head -n 20

echo
echo "--- 刷新次数统计 ---"
CR_COUNT="$(tr -cd '\r' < "$WORK/raw.txt" | wc -c | tr -d ' ')"
echo "含 \\r 回车的刷新帧数: $CR_COUNT"

if [ "$CR_COUNT" -ge 1 ]; then
    echo "结论: 进度条确实原地刷新（非逐行刷屏）"
else
    echo "结论: 未检测到 \\r，进度条可能未生效"
    exit 1
fi

if [ -s "$WORK/out.md" ]; then
    echo "落盘大小: $(wc -c < "$WORK/out.md") 字节"
else
    echo "FAIL: 文件未落盘"
    exit 1
fi