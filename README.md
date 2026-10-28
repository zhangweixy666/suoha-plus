<div align="center">

<h1>🍍 Suoha Plus</h1>

<p><b>Xray 多模式节点一键管理脚本</b></p>

<p>Reality 直连 · Cloudflare Tunnel · ShadowQuic —— 三条链路，一条命令</p>

[![Version](https://img.shields.io/badge/version-v2.6.4-2ea44f?style=for-the-badge)](https://github.com/zhangweixy666/suoha-plus)
[![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu%20%7C%20Alpine-0078d7?style=for-the-badge)](#-系统要求)
[![Shell](https://img.shields.io/badge/shell-bash%20%2B%20POSIX-4eaa25?style=for-the-badge)](#-系统要求)
[![Tests](https://img.shields.io/badge/tests-14%20suites-2ea44f?style=for-the-badge)](#-测试)
[![License](https://img.shields.io/badge/license-CC--BY--SA--4.0-lightgrey?style=for-the-badge)](#-致谢与许可)

<p><b>无需域名 · 无需证书 · 无需付费 · 中文菜单</b></p>

[🚀 快速开始](#-快速开始)　·　[🎯 三种模式怎么选](#-三种模式怎么选)　·　[✨ 功能特性](#-功能特性)　·　[❓ 常见问题](#-常见问题)　·　[📜 更新日志](#-更新日志)

</div>

---

## 🎯 三种模式怎么选

不用读完整个文档，先看这张表：

| 模式 | 需要域名 | 需要 CF 授权 | 地址稳定性 | 延迟 | 推荐场景 |
|:---|:---:|:---:|:---|:---:|:---|
| **Reality 直连** | ❌ | ❌ | 🟢 固定 `IP:8443` | 最低 | 有公网 IPv4/IPv6，追求性能与抗封锁 |
| **Quick Tunnel** | ❌ | ❌ | 🔴 重启即变 | 中 | 临时应急、零配置跑起来 |
| **持久化 Tunnel** | ✅ | ✅ | 🟢 永久固定 | 中 | 长期使用、无公网 IP、NAT 机器 |
| **ShadowQuic**（可选模块） | ❌ | ❌ | 🟢 固定 `UDP:1443` | 低 | 想要 0-RTT 握手、UDP 线路好 |

> 💡 **小孩子才做选择。** Reality 与 WS 隧道可以**同时运行、互为备份**，一次安装输出两套节点链接。

---

## 🚀 快速开始

### 一键运行（推荐）

```bash
wget -qO- https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/suoha-manager.sh | sh
```

脚本会自动下载副本到 `/root/suoha-plus-managed.sh`，并以真实 TTY 交互模式重新启动，菜单正常可用。

### 下载后运行

```bash
wget -qO /root/suoha-manager.sh https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/suoha-manager.sh
chmod +x /root/suoha-manager.sh
bash /root/suoha-manager.sh
```

### 装完之后

```bash
suoha-plus          # 随时唤回管理菜单
suoha-plus --version
suoha-plus --help
```

---

## 📖 目录

- [🎯 三种模式怎么选](#-三种模式怎么选)
- [🚀 快速开始](#-快速开始)
- [✨ 功能特性](#-功能特性)
- [🏗 工作原理](#-工作原理)
- [🖥 主菜单预览](#-主菜单预览)
- [📦 使用指南](#-使用指南)
  - [Reality 直连节点](#reality-直连节点菜单-3推荐)
  - [Quick Tunnel](#quick-tunnel菜单-1)
  - [持久化 Tunnel](#持久化-tunnel菜单-2)
  - [ShadowQuic 模块](#shadowquic-模块菜单-8)
- [📄 节点文件](#-节点文件)
- [⚙ 配置文件](#-配置文件)
- [🧰 服务管理](#-服务管理)
- [🧩 系统要求](#-系统要求)
- [❓ 常见问题](#-常见问题)
- [🧹 卸载](#-卸载)
- [🧪 测试](#-测试)
- [📜 更新日志](#-更新日志)（完整历史见 [CHANGELOG.md](CHANGELOG.md)）
- [🙏 致谢与许可](#-致谢与许可)

---

## ✨ 功能特性

### 🛡 Reality 直连 —— 不打洞，正面硬刚

> VLESS + XTLS Vision + Reality，无需域名、无需隧道、无证书成本

- 自动生成 x25519 密钥与 shortId，兼容新旧版 `xray x25519` 输出
- 默认借牌 `www.apple.com`（TLS 1.3 + h2），探测呈现真实 Apple EV 证书
- 自动探测公网 IPv4 / IPv6，**双栈同时生成链接**；NAT / 纯 IPv6 机器友好
- 安装时可指定连接地址，留空则自动双栈

### 🚇 WS + Cloudflare Tunnel —— 无公网 IP 的救命稻草

| | Quick Tunnel | 持久化 Tunnel |
|:---|:---|:---|
| CF 授权 | 不需要 | 需要 `cert.pem` |
| 地址 | `xxx.trycloudflare.com` | 自有域名，永久固定 |
| 重启后 | 地址变化，脚本自动刷新节点 | 地址不变，开机自启 |
| 适用 | 秒开试用、临时应急 | 长期稳定使用 |

- 默认优选接入域名 `www.visa.com`（解析到 Cloudflare 边缘、对中国友好）
- 本地 WS 仅监听 `127.0.0.1`，公网流量全走 Cloudflare 边缘
- OpenRC 开机自启：自动注册 `suoha-plus-xray`、`suoha-plus-cloudflared` 到 `rc-update default`

### ⚡ ShadowQuic —— 可选 QUIC 模块

> 0-RTT QUIC 代理 + JLS SNI 伪装，UDP `:1443`，免域名免证书

- JLS SNI 伪装（借牌 `apple.com`），自动生成随机账号密码
- 直连 / SOCKS5 出站双配置，菜单一键切换
- 独立服务 `suoha-shadowquic`，开机自启 + 崩溃自动重启
- 输出 **`sq://` 链接** + Clash.Meta/mihomo + 官方客户端配置
- 接管旧安装；按 `/proc/PID/cmdline` 精确识别归属，**不误杀同机其他实例**

### 🧰 管理与运维

| 能力 | 说明 |
|:---|:---|
| 📊 运行状态 | 主菜单实时显示 `● 运行中 / ○ 未运行`（含 PID） |
| 🩺 健康检测 | 自动实测 Reality 端口监听、隧道域名真实 WebSocket 握手（只认 `101` / `400` / `426`） |
| 📥 下载可控 | 所有下载先展示大小与位置并二次确认，实时进度条 `[####....] 62% 3.1M/s` |
| 🔄 事务安装 | `txn_begin / commit / rollback`：安装失败自动还原配置与服务，不会把好节点搞挂 |
| ⚙️ 配置透明 | 菜单内直接查看路径，支持 vi/vim/nano 编辑，保存后自动校验 + 重启 + 刷新节点 |
| 🗑 精准卸载 | 可单独删 Xray / 单独删 Tunnel / ShadowQuic / 全部，**不影响系统其他组件** |
| 🔐 完整性校验 | Xray 走官方 `.dgst` SHA-256，ShadowQuic 做 ELF 魔数 + 真实执行验证 |
| 🧮 兼容与健壮 | busybox `sh` 与 `bash` 行为一致（`shquote` 替代 `printf %q`）；版本查询走 302 重定向不耗 API 配额；日志自动轮转 |
| 🧪 14 个测试套件 | 静态 / 行为 / 卸载 / 回归 / 防卡死 / 节点 / 下载 / 健康 / 版本查询，`sh test/run.sh` 一条命令跑完 |
| 🇨🇳 中文界面 | 菜单、状态、错误提示全中文 |

---

## 🏗 工作原理

```text
                   ┌──────────────────────────────────────────────┐
                   │              Cloudflare 边缘网络              │
                   └───────────────────┬──────────────────────────┘
      WS + TLS                         │  Cloudflare Tunnel
   客户端 ────────────────────────────▶│──────────────────────▶ VPS
                                       │                       127.0.0.1:随机端口
                                       │                       Xray (VMess/VLESS+WS)

                   ┌──────────────────────────────────────────────┐
      Reality      │           VPS  公网 IP : 8443               │
   客户端 ────────▶│   Xray (VLESS + XTLS Vision + Reality)       │
     TLS 1.3       └──────────────────────────────────────────────┘
                   伪装目标 www.apple.com，探测呈现真实 EV 证书

                   ┌──────────────────────────────────────────────┐
      ShadowQuic   │           VPS  UDP : 1443                    │
   客户端 ────────▶│   QUIC 0-RTT + JLS SNI 伪装                  │
     QUIC/UDP      └──────────────────────────────────────────────┘
```

三种链路**互相独立**，任一可用即可上网；Reality 与隧道可同时开启。

---

## 🖥 主菜单预览

```text
╔══════════════════════════════════════════════╗
║  Suoha Plus  v2.6.4                          ║
║  Xray v26.3.27  |  cloudflared 2026.8.2      ║
╚══════════════════════════════════════════════╝

1) 安装/启动 Quick Tunnel（重启后需重新生成地址）
2) 安装/启动持久化 Tunnel（需要 Cloudflare 域名授权）
3) 安装/启动 Reality 直连节点（无需域名，vless+Vision）
4) 服务管理
5) 配置管理（修改后自动重启并刷新节点）
6) 查看当前节点信息
7) 卸载管理（删除 Xray / 隧道 / 全部）
8) 安装/管理 ShadowQuic（QUIC 代理，UDP，可选模块）
9) 组件版本（检查更新 / 升级 Xray、cloudflared）
0) 退出
```

---

## 📦 使用指南

### Reality 直连节点（菜单 3，推荐）

全程回车即可：自动生成密钥 → 确认端口 / dest / SNI → 启动 → 输出链接。

- 端口默认 `8443`；dest / SNI 默认 `www.apple.com`（可换其他 TLS 1.3 + h2 大站）
- 有公网 IPv6 优先输出 IPv6 链接，同时输出 IPv4

> ⚠️ 云安全组需放行 **TCP 8443**。

### Quick Tunnel（菜单 1）

免授权秒开，得到 `xxx.trycloudflare.com` 临时地址；重启后地址会变，脚本自动刷新节点。

> 机器重启后 Xray 自启、Quick 隧道不自启（地址会变）。状态页会提示旧地址失效并给出处理路径。

### 持久化 Tunnel（菜单 2）

绑定自有 Cloudflare 域名，地址永久固定。首次需在浏览器完成 `cloudflared tunnel login` 授权。

### ShadowQuic 模块（菜单 8）

```text
1) 安装/更新 ShadowQuic
2) 启动 ShadowQuic
3) 停止 ShadowQuic
4) 重启 ShadowQuic
5) 查看客户端接入信息
6) 查看日志（末 30 行）
7) 卸载 ShadowQuic
8) 检查更新 / 升级到最新版本
```

**默认参数**：UDP `1443`、随机用户名 / 密码、SNI 伪装 `www.apple.com`、直连出站。

二进制来自 [spongebob888/shadowquic](https://github.com/spongebob888/shadowquic) 官方 release，按 `uname -m` 匹配架构；安装前做 ELF 魔数校验、安装后做真实执行验证，已是新版则跳过下载。

安装完成自动输出三种接入方式：**`sq://` 分享链接**、Clash.Meta/mihomo YAML、官方客户端 YAML。

**`sq://` 链接格式**（QuicProxy、husi、nekobox 等客户端支持直接导入）：

```text
sq://用户名:密码@[IPv6]:1443?alpn=h3&mtu=1280&sni=www.apple.com&udp_mode=datagram&zero_rtt=true#节点名
sq://用户名:密码@IPv4:1443?alpn=h3&mtu=1280&sni=www.apple.com&udp_mode=datagram&zero_rtt=true#节点名
```

> ⚠️ 云安全组需放行 **UDP 1443**。

---

## 📄 节点文件

所有模式的节点信息统一写入：

```text
/opt/suoha-plus/v2ray.txt
```

含 Reality 的 `vless://`（v4/v6）、WS 隧道的 `vless://` 或 `vmess://`、ShadowQuic 的 `sq://`，以及配置路径注释。**v2rayN / v2rayNG / Clash Meta / nekobox 可直接导入。**

---

## ⚙ 配置文件

主菜单顶部实时显示当前配置位置，也可在 `5) 配置管理 → 4) 手动编辑` 中查看和编辑：

| 组件 | 配置路径 |
|:---|:---|
| Xray | `/opt/suoha-plus/xray.json` |
| Cloudflare Tunnel | `/opt/suoha-plus/config.yaml`（Quick 模式自动生成） |
| ShadowQuic 直连出站 | `/etc/shadowquic/server-direct.yaml` |
| ShadowQuic SOCKS 出站 | `/etc/shadowquic/server-socks.yaml` |
| ShadowQuic 出站模式 | `/etc/shadowquic/last-mode`（`direct` / `socks`） |
| 节点文件 | `/opt/suoha-plus/v2ray.txt` |

保存后自动生效：Xray 走 `xray -test` 校验 + 重启 + 刷新节点；隧道与 ShadowQuic 各自重启。ShadowQuic 出站模式支持 `direct` ⇄ `socks` 一键切换。

---

## 🧰 服务管理

```bash
suoha-plus                  # 打开管理菜单
bash /root/suoha-plus-managed.sh
```

服务菜单支持启动 / 停止 / 重启（自动刷新节点）/ 查看节点信息。

```text
/opt/suoha-plus/
├── xray.json      # Xray 配置
├── config.yaml    # cloudflared 配置（持久化模式）
├── state.env      # 运行状态
├── v2ray.txt      # 节点分享链接
├── logs/          # 运行日志
└── bin/           # 固定版本二进制
```

---

## 🧩 系统要求

| 项目 | 要求 |
|:---|:---|
| 系统 | Debian / Ubuntu / Alpine（及其他 systemd / OpenRC 发行版） |
| 架构 | x86_64 / aarch64 / armv7 / i686 |
| Shell / init | `bash` 或 POSIX `sh`（busybox ash 已真机实测）；systemd 或 OpenRC |
| 权限 | root |
| 网络 | 独立 IPv4、NAT、仅 IPv6 机器均可 |
| 依赖 | `curl` 或 `wget`、`tar`、`unzip`（脚本会自动检查并询问是否安装） |

---

## ❓ 常见问题

<details>
<summary><b>NAT VPS / 没有 IPv6 的本地网络，能用 Reality 吗？</b></summary>

能。NAT 机器 IPv6 端口通常全开，脚本默认优先输出 IPv6 链接，同时给出 v4 链接，实测哪个通用哪个。

本地没有 IPv6 时，改用 WS + 隧道节点（默认优选 `www.visa.com`，域名固定），或给本地加 IPv6。

</details>

<details>
<summary><b>Reality 的 dest / SNI 可以换吗？</b></summary>

可以，安装时按提示输入即可。要求：目标站支持 **TLS 1.3 + h2**，且与 VPS 网络路由友好（大厂站点优先）。脚本会对输入做字符集与端口范围校验。

</details>

<details>
<summary><b>ShadowQuic 连不上？</b></summary>

依次检查：

1. 云安全组是否放行 **UDP 1443**
2. 客户端 `server-name` 是否与服务端 `jls-upstream` 域名一致
3. 菜单 `8 → 6` 查看日志

</details>

<details>
<summary><b>机器上已有别的 shadowquic，会冲突吗？</b></summary>

安装时自动接管：停掉旧服务、移除旧开机自启注册、复用 `/etc/shadowquic` 目录写入新配置，不会双启。停止时只停本项目进程，不动其他实例。

</details>

<details>
<summary><b>手动改了配置怎么生效？会影响机器上原有的 suoha.sh 吗？</b></summary>

改配置：菜单 `5 → 4` 编辑保存即自动校验 + 重启（Xray 走 `xray -test`，不再整份重写覆盖手改内容）。

不会影响原有脚本：本脚本用独立目录 `/opt/suoha-plus`、独立服务名，卸载也只删自身。

</details>

<details>
<summary><b>装完重启机器，Quick 隧道怎么没了？</b></summary>

这是预期行为。Quick 地址每次启动都会变，所以脚本刻意不注册开机自启。状态页会提示旧地址已失效，回主菜单选 `1` 重新启动即可。想开机自启请用**持久化 Tunnel**。

</details>

<details>
<summary><b>GitHub API 限流了，版本检查是不是就废了？</b></summary>

不会。未认证的 GitHub API 配额只有 60 次/小时且按出口 IP 共享，真机测试中确实被打满过（`x-ratelimit-remaining: 0`）。

从 v2.6.4 起新增 `gh_latest_tag()`：**优先用 `github.com/<repo>/releases/latest` 的 302 重定向直接拿 tag，零 API 配额**，失败才回退到 API；识别到 403 限流时会明确提示「约 N 分钟后恢复」，而不是笼统地说「网络问题」。

</details>

<details>
<summary><b>Alpine 上必须装 bash 吗？</b></summary>

不必须。脚本声明支持 POSIX `sh`，v2.6.3 专门修了 busybox/musl 的兼容问题：

- busybox 的 `printf` 不支持 `%q`，21 处 `printf 'KEY=%q'` 会把 `state.env` 写成一行垃圾 → 改用自研 `shquote()` / `state_line()` 做 POSIX 单引号转义
- `case` 的字符类里混入 `[` `]` 会让 ash 整体解析失败并**放行一切非法值** → 改用 `grep -qE`，bash/ash 行为一致

v2.6.3/v2.6.4 的全部验证均在 Alpine 3.23.6 + OpenRC + busybox 真机上完成。

</details>

<details>
<summary><b>装完之后日志会不会把磁盘写满？</b></summary>

不会。`rotate_all_logs()` 现已挂到主菜单循环里，每次刷新主菜单都会检查并轮转。

> 这个函数曾经是**死代码**——写好了但从未被调用，日志会无限增长。v2.6.3 把它接回了主菜单。

</details>

<details>
<summary><b>安装失败会不会把正在用的节点搞挂？</b></summary>

不会。安装走事务流程（`txn_begin / txn_commit / txn_rollback`）：先完成所有可能失败的步骤（下载 / 密钥 / 校验 / 写配置），最后才动服务；任一步失败即还原配置、重建服务单元并重新拉起原服务。

> v2.6.3 又修掉了两个更隐蔽的问题：**快照时机**（原先在「问完参数之后」才 `txn_begin`，快照里存的已经是用户刚填的非法值，回滚等于把坏值写回去 → 现已前移到读输入之前）和**回滚误写状态文件**（新增 `_txn_restart_services()`，回滚只重启服务、不再回写 `state.env`）。

</details>

---

## 🧹 卸载

主菜单 `7) 卸载管理` 支持三种粒度：`1` 仅删 Xray（保留 Tunnel）、`2` 仅删 Tunnel（保留 Xray）、`3` 删除全部。ShadowQuic 在菜单 `8 → 7` 单独卸载。

---

## 🧪 测试

仓库自带测试套件，**无需 root，不影响本机已有的 Suoha Plus 安装**：

```bash
sh test/run.sh
```

| 套件 | 作用 |
|:---|:---|
| `test_static.sh` | 静态断言：版本一致性、修复特征存在、原有特性未回归 |
| `test_behavior.sh` | 行为测试：提取真实函数到沙箱执行，验证架构映射、IP 缓存、日志轮转等 |
| `test_regression.sh` | 真实行为回归 |
| `test_reality_install.sh` | 真机安装回归 |
| `test_nohang.sh` | 防卡死回归（stdin 关闭 / 管道输入） |
| `test_nodes.sh` | 节点生成与重装回归 |
| `test_uninstall.sh` | 卸载沙箱：验证服务单元清理完整、不误删外部共享资源 |
| `dl_test.sh` | 下载确认与进度渲染（含 tty 原地刷新） |
| `dl_tty_test.sh` | 用 script(1) 伪造 tty，验证进度条真实刷新 |
| `download_audit.sh` | 网络请求点审计：不得有静默下载 |
| `fix_test.sh` | 历史修复项回归 |
| `health_probe.sh` | 健康探测 |
| `vq_test.sh` / `vq_tty2.sh` | 版本查询提示（tty / 非 tty） |

**共 14 个套件，`run.sh` 全部跑完**，任一失败即退出码非 0，可直接接 CI。测试脚本自动定位仓库内主脚本，也可指定路径：`sh test/run.sh /path/to/suoha-manager.sh`。

> `dl_tty_test.sh` 需要 `script(1)`（Alpine：`apk add util-linux-misc`；缺少时该项会报错而不是静默通过。

---

## 📜 更新日志

> 完整历史见 [**CHANGELOG.md**](CHANGELOG.md)。这里只保留最近三个版本的摘要。

### v2.6.4 — 补齐 7 个从未执行的测试套件

- `run.sh` 从 7 个套件扩到 **14 个**（此前另外 7 个脚本因硬编码 Android 路径从未跑过）
- 🔴 busybox/ash 下 `NODE_ADDRESS` 白名单**完全失效**（字符类混入 `[` `]`，放行一切非法值）→ 改 `grep -qE`
- 🟠 GitHub API 60 次/小时配额打满后版本查询全挂 → 新增 `gh_latest_tag()` 走 302 重定向，零配额
- 🟡 域名校验只查首尾（`-abc.com`、`a..b` 能通过）→ 改为逐标签校验

### v2.6.3 — 二次真机实测，修 9 个缺陷（含 2 个 P0）

- 🚨 **P0** busybox `printf` 不支持 `%q`，21 处调用让 `state.env` 变成一行垃圾 → 新增 `shquote()` / `state_line()`
- 🚨 **P0** `txn_begin` 快照时机太晚，回滚反而把用户刚填的非法值写回去 → 快照前移 + `_txn_restart_services()`
- 🎯 升级后版本号丢失导致重装降级、版本检查恒定误报、裸 IPv6 被当端口、模式切换残留 Reality 开关等 6 项

### v2.6.2 — 修三个逻辑缺陷

- 🚨 `exec 9>"$LOCK_FILE" 2>/dev/null` 让**后续所有 stderr 永久指向 /dev/null**，错误提示全被吞 → 用 `{ ...; } 2>/dev/null` 限定作用域
- 🛟 安装失败不回滚，好节点当场断掉 → 新增 `txn_begin / txn_commit / txn_rollback` 事务
- 🎯 ShadowQuic 停止误杀同机其他实例 → 改为 `/proc/PID/cmdline` 精确识别归属

---

## 🙏 致谢与许可

本项目由 [suoha.sh](https://suoha.psai.eu.org/suoha.sh) 增强分支开发而来，重构并扩展了 Reality、ShadowQuic、健康检测等功能。使用独立目录与服务名，**不影响、也不调用原脚本**。

- 示例配置参考 [XTLS/Xray-examples](https://github.com/XTLS/Xray-examples)
- ShadowQuic 部署逻辑参考 [zhangweixy666/warp-](https://github.com/zhangweixy666/warp-)，二进制来自 [spongebob888/shadowquic](https://github.com/spongebob888/shadowquic)

**许可**：CC-BY-SA-4.0

> ⚠️ **免责声明**：本项目仅供技术学习与研究使用。请遵守你所在地区的法律法规以及服务提供商的使用条款。使用者需自行承担因使用本脚本产生的一切后果。

<div align="center">

**[⬆ 回到顶部](#-suoha-plus)**

Made with 🍍 by [zhangweixy666](https://github.com/zhangweixy666)

</div>
