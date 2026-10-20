#!/bin/bash
# 审计：所有网络请求点是否都有"确认 + 可见反馈"
# 不是靠读代码猜，而是把每个函数抽出来实际跑一遍，看 stderr 有没有输出。
SRC="/sdcard/Download/suoha-plus/suoha-manager.sh"
PASS=0; FAIL=0
ok() { echo "ok  : $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

extract() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) *\\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$SRC"
}

echo "=========================================="
echo " 网络请求点清单（源码审计）"
echo "=========================================="
echo
echo "--- 所有 curl/wget 调用点 ---"
grep -n 'curl \|wget ' "$SRC" | grep -v '^\s*#' | grep -v 'command_exists\|command -v' | \
    sed 's/^\([0-9]*\):\s*/\1| /' | while IFS= read -r l; do echo "  $l"; done

echo
echo "=========================================="
echo " 逐项验证：每处是否会产生可见反馈"
echo "=========================================="

# ---------- 1. 引导自下载 ----------
echo
echo "[1] 引导自下载（L24-28）"
# 精确判断：wget 行末尾必须是注释，不能有实际的 2>/dev/null 重定向
if grep -qE '^\s*wget -O "\$_install_path" "\$_self_url"\s+# ' "$SRC"; then
    ok "wget 兜底保留原生进度（末尾是注释，无 2>/dev/null 重定向）"
else
    bad "wget 兜底可能仍静默"
fi
if grep -q "printf '\[信息\] 正在获取脚本副本" "$SRC"; then
    ok "下载前有文字提示"
else
    bad "缺少下载前提示"
fi
if grep -q -- '--progress-bar' "$SRC"; then
    ok "curl 分支带 --progress-bar"
else
    bad "curl 分支无进度条"
fi

# ---------- 2. Xray / cloudflared 主下载 ----------
echo
echo "[2] Xray + cloudflared 主下载"
N=$(grep -c 'dl_run "' "$SRC")
if [ "$N" -ge 4 ]; then
    ok "共 $N 处走 dl_run（带进度渲染）"
else
    bad "dl_run 覆盖不足，仅 $N 处"
fi
if awk '/^download_binaries\(\)/,/^}/' "$SRC" | grep -q 'confirm_download'; then
    ok "download_binaries 有确认"
else
    bad "download_binaries 缺确认"
fi

# ---------- 3. ShadowQuic ----------
echo
echo "[3] ShadowQuic 下载"
if awk '/^sq_download_bin\(\)/,/^}/' "$SRC" | grep -q 'dl_run "shadowquic"'; then
    ok "sq_download_bin 走 dl_run"
else
    bad "sq_download_bin 未走 dl_run"
fi
if awk '/^sq_download_bin\(\)/,/^}/' "$SRC" | grep -q 'confirm_download'; then
    ok "sq_download_bin 有确认"
else
    bad "sq_download_bin 缺确认"
fi

# ---------- 4. 系统依赖安装 ----------
echo
echo "[4] 系统依赖安装（apk/apt 等）"
if awk '/^install_dependencies\(\)/,/^}/' "$SRC" | grep -q 'confirm_download'; then
    ok "install_dependencies 有确认"
else
    bad "install_dependencies 缺确认"
fi

# ---------- 5. 版本查询（实际运行验证反馈）----------
echo
echo "[5] 版本查询：实际跑一遍看 stderr 有无提示"
cat > /tmp/audit_vq.sh <<'INNER'
#!/bin/bash
SRC="/sdcard/Download/suoha-plus/suoha-manager.sh"
extract() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) *\\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$SRC"
}
for f in net_hint_begin net_hint_end xray_latest_version cloudflared_latest_version sq_latest_version; do
    eval "$(extract "$f")"
done
xray_latest_version > /dev/null
cloudflared_latest_version > /dev/null
sq_latest_version > /dev/null
INNER

bash /tmp/audit_vq.sh 2>/tmp/audit_stderr.txt
LINES=$(grep -c '正在查询' /tmp/audit_stderr.txt)
if [ "$LINES" -eq 3 ]; then
    ok "三个版本查询都有可见提示（3/3）"
else
    bad "版本查询提示不足：$LINES/3"
fi
echo "  stderr 实际内容："
sed 's/^/    /' /tmp/audit_stderr.txt

# ---------- 6. IP 探测（短查询，不要求进度条）----------
echo
echo "[6] IP 探测（api.ipify.org，5s 超时）"
echo "  说明：极短查询，不画进度条属合理设计，但需确认失败时不会静默挂住"
if awk '/^public_ip\(\)/,/^}/' "$SRC" | grep -q -- '--max-time 5'; then
    ok "public_ip 有 5s 超时上限"
else
    bad "public_ip 无超时"
fi
if awk '/^public_ip6\(\)/,/^}/' "$SRC" | grep -q -- '--max-time 5'; then
    ok "public_ip6 有 5s 超时上限"
else
    bad "public_ip6 无超时"
fi

# ---------- 7. 健康探测（不算下载）----------
echo
echo "[7] 健康探测（WS 握手，不算下载）"
echo "  说明：探测本身会显示 ✓/✗ 结果，无需进度条"
if grep -q 'WS 握手正常' "$SRC"; then
    ok "健康探测有明确结果输出"
else
    bad "健康探测无结果输出"
fi

# ---------- 8. 全局：不该有静默下载 ----------
echo
echo "[8] 全局扫描：是否还有静默下载残留"
if grep -qE 'curl [^|]*(-o|--output)[^|]*2>/dev/null' "$SRC"; then
    bad "仍有 curl 下载重定向到 /dev/null"
    grep -nE 'curl [^|]*(-o|--output)[^|]*2>/dev/null' "$SRC" | sed 's/^/    /'
else
    ok "无 curl 下载静默残留"
fi
# 先剥掉行尾注释再判断：像 `wget ... # 不要 2>/dev/null` 这种，
# 注释里的字样不算实际重定向。只保留 # 之前的代码部分再匹配。
if sed 's/[[:space:]]#.*$//' "$SRC" | grep -vE '^\s*#' | grep -qE 'wget [^|]*-O[^|]*2>/dev/null'; then
    bad "仍有 wget 下载静默"
    sed 's/[[:space:]]#.*$//' "$SRC" | grep -nE 'wget [^|]*-O[^|]*2>/dev/null' | sed 's/^/    /'
else
    ok "无 wget 下载静默残留（已剥离行尾注释）"
fi

echo
echo "=========================================="
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1