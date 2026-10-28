# 更新日志

本文件保存完整历史。README 只保留最近三个版本的摘要。

版本号规则：`主版本.次版本.修订号`。当前版本见脚本内 `APP_VERSION`。

---

## v2.6.4 — 补齐 7 个从未执行的测试套件，修出 3 个新缺陷

> 起因：v2.6.3 发布后复核发现 `test/run.sh` 只编排了 7 个套件，仓库里另外 7 个脚本**从未被执行过** —— 它们把源文件路径硬编码成了 Android 本机路径，在 VPS/CI 上全部报 `No such file`。修好路径后，这批「沉睡」的测试立刻抓出 3 个真问题。

- 🔴 **`validate_common` 的 NODE_ADDRESS 白名单在 busybox/ash 下完全失效**：`case` 的字符类里混入 `[` 和 `]`，ash 会整体解析失败并**放行一切非法值**（`bad node@#$`、`a b`、`a@b` 全部通过），bash 下却正常。改为 `grep -qE '^[]A-Za-z0-9._:[-]+$'`，两解释器行为一致。
- 🟠 **GitHub API 60 次/小时配额打满后所有版本查询失效**：三个 `*_latest_version` 函数都直连 `api.github.com`，未认证配额按出口 IP 共享。新增 `gh_latest_tag()`：**优先用 `releases/latest` 的 302 重定向拿 tag，零 API 配额**，失败才回退 API；识别到 403 时明确提示「约 N 分钟后恢复」。
- 🟡 **`validate_domain` 只校验整串首尾**：`-abc.com`、`abc-.com`、`a..b` 都能通过，但 Cloudflare 会拒绝，用户要等到 `route dns` 才失败。改为逐标签校验（不以 `-` 开头/结尾、非空、≤63 字符、总长 ≤253）。

**测试套件补全**：`run.sh` 从 7 个扩展到 14 个，并通过 `SUOHA_SRC` 把被测脚本路径传给套件内部嵌套的子脚本（此前 heredoc 生成的临时脚本在 `/tmp`，`dirname $0/..` 定位不到仓库）。

**真机验证**（Alpine 3.23.6 / OpenRC / busybox）：Reality 端到端 200、模式切换无残留、回滚后 `state.env` 与基线 diff 为空、卸载无残留、`sh` 下安装 0 个 `invalid format`。

---

## v2.6.3 — 二次真机实测：修 9 个实际缺陷（含 2 个 P0）

> 本轮全部在真实 Alpine VPS（OpenRC + busybox）上跑通：Reality / Quick Tunnel / ShadowQuic 三协议端到端 200，回滚、升级、卸载全流程验证。

- 🚨 **P0-1 `sh` 下 state.env 被写成一行垃圾**：busybox/musl 的 `printf` 不支持 `%q`，21 处 `printf 'KEY=%q'` 全部报 `invalid format`，`state.env` 变成 `MODE=PROTOCOL=EDGE_IP=...=`，所有状态丢失。新增 `shquote()` / `state_line()` 做 POSIX 单引号转义。
- 🚨 **P0-2 回滚反而污染配置**：`txn_begin` 在「问完参数」之后才执行，快照里存的已经是用户刚填的非法值；失败回滚时又把坏值写回 `state.env`。快照前移到读输入之前，并新增 `_txn_restart_services()` 让回滚只重启服务、不再写状态文件。
- 🎯 **升级后版本号丢失，重装直接降级**：`XRAY_VERSION` 在脚本顶部求值时 `state.env` 还没加载。`load_state` 里补显式同步。
- 📊 **版本检查恒定误报「有新版本」**：比较写成 `v${xc#v}` vs `${xl#v}`，一边带 v 一边不带。改为两边都剥 `v` 前缀。
- 🌐 **Reality dest 裸 IPv6 放行但 Xray 不认**：`2001:db8::1` 的末段被当端口放行。现在裸 IPv6 直接拒绝并提示写 `[IPv6]:端口`，`[IPv6]` 自动补 `:443`。
- 🔀 **模式切换残留 Reality 开关**：装过 Reality 再装 Quick，`REALITY_ENABLED` 仍是 `yes`，会写出带 `pbk=/sid=` 的假 Reality 链接。两个 setup 入口进入即清，并在失败分支还原。
- 🔗 **WS/vmess 节点地址为空时生成坏链接**：`@:443`、`add:""`。改为回退到隧道域名。
- ✏️ **菜单 5→4→1 手改配置立刻被覆盖**：保存后走 `apply_config_now` → `write_xray_config` 整份重写。现在只做 `xray -test` 校验 + 重启，手改内容保留。
- 🧹 **死代码与遗漏**：`rotate_all_logs` 从未被调用（日志无限增长）已挂到主菜单；删除 `lock_acquire` / `sq_detect_service` / `SQ_CMD`；Quick 模式补上 `install_cmd_link`；`--version` 改读实际二进制版本；`sq_status_line` 的 `pgrep` 兜底改为只认本项目进程；`banner` 边框改为按固定宽度填充。

**测试脚本同步修复**：`extract_funcs.sh` 原先被注释里的 `"` 或 `}` 干扰，抽取出的 lib 语法错误导致全部行为测试假失败；`test_nohang.sh` 断言文案与实际输出不一致；`test_static.sh` 版本断言硬编码。修完 7 套件全过。

---

## v2.6.2 — 真机全流程实测后修三个逻辑缺陷

- 🚨 **错误提示被永久丢弃（最严重）**：`exec 9>"$LOCK_FILE" 2>/dev/null` 的重定向对 shell 本身持久生效，导致后续所有 `stderr` 指向 `/dev/null`，`err()` 打印的错误用户一个字都看不到，表现为「选了菜单没反应」。改为 `{ exec 9>"$LOCK_FILE"; } 2>/dev/null`，把重定向限定在命令内。
- 🛟 **安装失败后不回滚**：旧实现一进 `setup_*` 就停服务、删服务单元，之后才校验参数；任一步失败则节点当场断掉且不会自愈。现改为「先做所有可能失败的步骤，最后才动服务」，并新增安装事务 `txn_begin / txn_commit / txn_rollback`。
- 🎯 **ShadowQuic 停止误杀同机其他实例**：原 `pgrep -f '[s]hadowquic' | kill -9` 会连带杀掉其他项目的进程。新增 `sq_proc_is_ours` / `sq_pids_ours`，逐个读 `/proc/PID/cmdline` 精确识别本项目进程。

---

## v2.6.1

- 升级被问两次导致静默取消（新增 `preconfirmed` 标记，确认动作只在菜单层做一次）
- Reality 模式协议显示从 `vmess` 修正为 `vless + xtls-rprx-vision`
- 升级确认文案补明会同步另一组件

## v2.6.0

- 下载前必须确认（默认 N，直接回车不下载）
- 新增 `dl_run` 实时进度条 `[####....] 62% 3.1M/s`，替换静默的 `curl -o`
- Reality 连接地址真正生效（此前填了会被静默丢弃）
- 健康检测改为真实 WebSocket 握手（只认 `101` / `400` / `426`）
- Quick 重启后状态页提示地址已失效并给出处理路径
- 新增菜单 9 组件升级通道 + `SUOHA_XRAY_VERSION` / `SUOHA_CLOUDFLARED_VERSION` 覆盖
- 补齐 `REALITY_DEST` / `REALITY_SNI` / 密钥输入校验

## v2.5.0

- `vmess` 链接不再 `fold` 折行（避免粘贴后 base64 解码失败）
- 三个安装入口增加覆盖重装确认
- `pause_screen` 改用安全 `read`，stdin 关闭不卡死

## v2.4.5

- 修复 Quick 模式重复安装覆盖 pidfile 后旧 `cloudflared` 进程无法停止（按 `$APP_DIR/bin/*` 路径兜底清理）

## v2.4.4

- 「删除全部」现在会一并清理 `suoha-shadowquic` 服务单元与 daemon wrapper，同时保护其他项目的 `/etc/shadowquic` 配置

## v2.4.3

- `ask_default` 与 14 处 `read -r -p` 提示符写在子 shell 里被吞；改为 `safe_read`，stdin 关闭自动采用默认值
- 下载增加「最长等 N 秒 / 实际耗时 M 秒」反馈

## v2.4.2

- OpenRC 单元函数末句 `[ -f ] && ok` 导致安装误判失败
- 常驻进程继承锁 fd 导致脚本再也打不开
- 重复安装累积多个 `supervise-daemon`
- `suoha-plus` 命令缺执行位

## v2.4.1

- 修复并发锁泄露
- `sq_start` 不再可能启动其他项目的 shadowquic
- 服务 `crashed` 状态单独显示
- 新增 `test/test_regression.sh`

## v2.4.0

- 修复 OpenRC 下状态显示与健康检测失效
- `suoha-plus` 命令真实创建
- ShadowQuic 支持 aarch64 / armv7 / i686 并新增升级菜单
- 公网 IP 探测进程内缓存
- 新增安装并发互斥锁与日志轮转

## v2.3.2

- Xray 下载增加官方 `.dgst` SHA-256 校验
- OpenRC 守护脚本每次启动重建日志目录
- 重装持久化 Tunnel 不再清空 `/root/.cloudflared` 中其他项目凭据

## v2.3.1

- ShadowQuic 守护脚本缺失时自动重建
- 修复组件卸载在 OpenRC 下残留 init.d 与自启注册
- `--version/--help` 管道模式不再误触发自重放
- 修复管道自重放死循环

## v2.3.0

- 新增 OpenRC 开机自启支持（Alpine）
- 无 systemd 环境后台进程也能自启
- 卸载时清理 OpenRC 注册

## v2.2.2

- 重装持久化隧道支持「删除全部 Cloudflare 配置并重新登录」
- 账号已有同名隧道但本地凭据缺失时自动删除重建

## v2.2.1

- ShadowQuic 生成 `sq://` 分享链接并写入节点文件
- 主菜单显示配置位置
- 新增手动编辑配置功能

## v2.2.0

- 新增 ShadowQuic 可选模块（移植自 `warp-` 项目，去 WARP/sing-box 依赖）
- 自动接管旧安装
- OpenRC / systemd 双兼容

## v2.1.0

- Reality 直连节点（XTLS Vision、双栈 v4/v6、与 WS 隧道共存）
- WS 优选域名默认 `www.visa.com`
- 运行状态 `●/○` 显示 + 健康检测
- 修复 x25519 新版输出解析

## v2.0.0

- Suoha Plus 独立版
- 固定版本
- Quick / 持久化双隧道
- 自动节点刷新

## v1.x

原 `suoha.sh` 系列功能。
