#!/bin/sh
# suoha-plus 测试统一入口
# 用法：sh test/run.sh [待测脚本路径]
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
S="${1:-$REPO/suoha-manager.sh}"

if [ ! -f "$S" ]; then
    echo "找不到待测脚本：$S" >&2
    exit 2
fi

export SUOHA_TEST_SCRIPT="$S"

PASS=0
FAIL=0
FAILED_SUITES=""

run_suite() {
    name="$1"
    script="$2"
    echo ""
    echo "========================================"
    echo "  运行：$name"
    echo "========================================"
    if sh "$HERE/$script"; then
        echo "[通过] $name"
        PASS=$((PASS + 1))
    else
        echo "[失败] $name"
        FAIL=$((FAIL + 1))
        FAILED_SUITES="$FAILED_SUITES $name"
    fi
}

run_suite "静态断言" test_static.sh
run_suite "行为测试" test_behavior.sh
run_suite "卸载沙箱" test_uninstall.sh
run_suite "真实行为回归" test_regression.sh

echo ""
echo "========================================"
echo "  汇总：$PASS 套件通过，$FAIL 套件失败"
if [ "$FAIL" -gt 0 ]; then
    echo "  失败项：$FAILED_SUITES"
    echo "========================================"
    exit 1
fi
echo "========================================"
exit 0
