#!/bin/sh
# 从 shell 脚本中提取顶格函数定义（含函数体），用于沙箱 source。
# 用法：extract_funcs.sh <脚本> > lib.sh

S="$1"
[ -f "$S" ] || { echo "找不到：$S" >&2; exit 2; }

awk '
BEGIN { infn=0; depth=0 }
# 顶格函数定义行
!infn && /^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
    infn=1; depth=0; buf=$0
    # 统计本行花括号净数
    line=$0
    o=gsub(/\{/,"{",line); line=$0
    c=gsub(/\}/,"}",line)
    depth += o - c
    if (depth <= 0) { print buf; infn=0; next }
    next
}
infn {
    buf = buf "\n" $0
    line=$0
    o=gsub(/\{/,"{",line); line=$0
    c=gsub(/\}/,"}",line)
    depth += o - c
    if (depth <= 0) { print buf; infn=0 }
    next
}
' "$S"
