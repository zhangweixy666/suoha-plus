<div align="center">

<h1>🍍 Suoha Plus</h1>

<p><b>Xray 多模式节点一键管理脚本</b></p>

<p>Reality 直连 · Cloudflare Tunnel · ShadowQuic —— 三条链路，一条命令</p>

[![Version](https://img.shields.io/badge/version-v2.6.3-2ea44f?style=for-the-badge)](https://github.com/zhangweixy666/suoha-plus)
[![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu%20%7C%20Alpine-0078d7?style=for-the-badge)](#-系统要求)
[![Shell](https://img.shields.io/badge/shell-bash%20%2B%20POSIX-4eaa25?style=for-the-badge)](#-系统要求)
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
- [📜 更新日志](#-更新日志)
- [🙏 致谢与许可](#-致谢与许可)

---

## ✨ 功能特性

### 🛡 Reality 直连 —— 不打洞，正面硬刚

> VLESS + XTLS Vision + Reality，无需域名、无需隧道、无证书成本

- 🔑 自动生成 x25519 密钥与 shortId，兼容新旧版 `xray x25519` 输出格式
- 🎭 默认借牌 `www.apple.com`（TLS 1.3 + h2），对外探测呈现真实 Apple EV 证书
- 🌐 自动探测公网 IPv4 / IPv6，**双栈同时生成节点链接**
- 📡 NAT VPS / 纯 IPv6 机器友好（IPv6 端口通常全开）
- ✏️ 安装时可指定连接地址（域名 / IPv4 / `[IPv6]`），留空则自动双栈

### 🚇 WS + Cloudflare Tunnel —— 无公网 IP 的救命稻草

| | Quick Tunnel | 持久化 Tunnel |
|:---|:---|:---|
| CF 授权 | 不需要 | 需要 `cert.pem` |
| 地址 | `xxx.trycloudflare.com` | 自有域名，永久固定 |
| 重启后 | 地址变化，脚本自动刷新节点 | 地址不变，开机自启 |
| 适用 | 秒开试用、临时应急 | 长期稳定使用 |

- 🌍 默认优选接入域名 `www.visa.com`（VISA 自有域名、解析到 Cloudflare 边缘、对中国友好）
- 🔒 本地 WS 仅监听 `127.0.0.1`，公网流量全部走 Cloudflare 边缘网络
- 🔁 OpenRC 开机自启（Alpine）：自动注册 `suoha-plus-xray`、`suoha-plus-cloudflared` 到 `rc-update default`

### ⚡ ShadowQuic —— 可选 QUIC 模块

> 0-RTT QUIC 代理 + JLS SNI 伪装，UDP `:1443`，免域名免证书

- 🎭 JLS SNI 伪装（借牌 `apple.com`），自动生成随机账号密码
- 🔀 直连 / SOCKS5 出站双配置文件，菜单一键切换
- 🛠 独立 systemd / OpenRC 服务 `suoha-shadowquic`，开机自启 + 崩溃自动重启
- 🔗 生成 **`sq://` 分享链接**（IPv4/IPv6 双栈）+ Clash.Meta/mihomo + 官方客户端配置
- ♻️ 已有旧 shadowquic 安装会被自动接管（停旧服务、移除旧注册、复用配置目录）
- 🛡 精确进程归属识别（`/proc/PID/cmdline`），**不会误杀同机其他 shadowquic 实例**

### 🧰 管理与运维

| 能力 | 说明 |
|:---|:---|
| 📊 运行状态 | 主菜单实时显示 `● 运行中 / ○ 未运行`（含 PID） |
| 🩺 健康检测 | 自动实测 Reality 端口监听、隧道域名真实 WebSocket 握手（只认 `101` / `400` / `426`） |
| 📥 下载可控 | 所有下载先展示大小与位置并二次确认，实时进度条 `[####....] 62% 3.1M/s` |
| 🔄 事务安装 | `txn_begin / commit / rollback`：安装失败自动还原配置与服务，不会把好节点搞挂 |
| ⚙️ 配置透明 | 菜单内直接查看路径，支持 vi/vim/nano 编辑，保存后自动校验 + 重启 + 刷新节点 |
| 🗑 精准卸载 | 可单独删 Xray / 单独删 Tunnel / ShadowQuic / 全部，**不影响系统其他组件** |
| 🔐 完整性校验 | Xray 下载走官方 `.dgst` SHA-256 校验，ShadowQuic 做 ELF 魔数 + 真实执行验证 |
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
║  Suoha Plus  v2.6.3                          ║
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

**全程回车即可完成**：自动生成密钥 → 确认端口 / dest / SNI / 地址 → 启动 → 输出节点链接。

- 监听端口默认 `8443`（可改）
- dest / SNI 默认 `www.apple.com`（可换成其他支持 TLS 1.3 + h2 的大站）
- 节点地址：有公网 IPv6 优先输出 IPv6 链接，同时输出 IPv4 链接
- ✅ 不需要域名　✅ 不需要 Cloudflare　✅ 不需要证书

> ⚠️ 记得在云厂商安全组放行 **TCP 8443**。

### Quick Tunnel（菜单 1）

免域名授权，秒级获得 `xxx.trycloudflare.com` 临时地址。重启后地址会变，脚本自动刷新节点文件。

> 机器重启后 Xray 会自启、Quick 隧道不会（地址会变，刻意不注册自启）。状态页会直接提示旧地址已失效并给出处理路径。

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

二进制来自 [spongebob888/shadowquic](https://github.com/spongebob888/shadowquic) 官方 release，按 `uname -m` 自动匹配 x86_64 / aarch64 / armv7 / i686 的 musl 静态版本；安装前做 ELF 魔数校验，安装后做真实执行验证。每次进入安装菜单都会查询上游最新版，已是最新则跳过下载。

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

包含 Reality 的 `vless://`（v4 / v6）、WS 隧道的 `vless://` 或 `vmess://`、ShadowQuic 的 `sq://`，以及对应配置文件位置注释。**v2rayN / v2rayNG / Clash Meta / nekobox 可直接导入。**

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

编辑保存后：

- 编辑 **Xray** → 自动校验配置 → 重启服务 → 刷新节点
- 编辑 **隧道** → 自动重启隧道
- 编辑 **ShadowQuic** → 自动重启生效
- 支持一键切换 ShadowQuic 出站模式（`direct` ⇄ `socks`）

---

## 🧰 服务管理

```bash
suoha-plus                  # 打开管理菜单
bash /root/suoha-plus-managed.sh
```

服务菜单支持 **启动 / 停止 / 重启（自动刷新节点）/ 查看节点信息**。

**数据目录结构**

```text
/opt/suoha-plus/
├── xray.json          # Xray 配置
├── config.yaml        # cloudflared 配置（持久化模式）
├── state.env          # 运行状态
├── v2ray.txt          # 节点分享链接
├── logs/              # 运行日志
└── bin/               # 固定版本二进制
```

---

## 🧩 系统要求

| 项目 | 要求 |
|:---|:---|
| 系统 | Debian / Ubuntu / Alpine（及其他 systemd / OpenRC 发行版） |
| 架构 | x86_64 / aarch64 / armv7 / i686 |
| 权限 | root |
| 网络 | 独立 IPv4、NAT、仅 IPv6 机器均可 |
| 依赖 | `curl` 或 `wget`、`tar`、`unzip`（脚本会自动检查并询问是否安装） |

---

## ❓ 常见问题

<details>
<summary><b>NAT VPS 能用 Reality 吗？</b></summary>

能。脚本默认优先走 IPv6（NAT 机器 IPv6 端口通常全开）；节点文件会同时给出 v4 / v6 链接，实测哪个通用哪个。

</details>

<details>
<summary><b>本地网络没有 IPv6，Reality_v6 连不上怎么办？</b></summary>

用 WS + 隧道节点（默认优选 `www.visa.com`，域名固定），或给本地加 IPv6（隧道 / WireGuard 均可）。

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
<summary><b>手动改了配置怎么生效？</b></summary>

Xray：菜单 `5 → 4` 编辑保存即自动校验重启；ShadowQuic：菜单 `5 → 4` 编辑保存后自动重启；也可以直接重启对应服务。

</details>

<details>
<summary><b>会影响机器上原有的 suoha.sh 吗？</b></summary>

不会。本脚本使用独立目录 `/opt/suoha-plus`、独立服务名，卸载也只删除自身。

</details>

<details>
<summary><b>装完重启机器，Quick 隧道怎么没了？</b></summary>

这是预期行为。Quick 地址每次启动都会变，所以脚本刻意不注册开机自启。状态页会提示旧地址已失效，回主菜单选 `1` 重新启动即可。想开机自启请用**持久化 Tunnel**。

</details>

<details>
<summary><b>安装失败会不会把正在用的节点搞挂？</b></summary>

不会。v2.6.2 起安装走事务流程（`txn_begin / txn_commit / txn_rollback`）：先完成所有可能失败的步骤（下载 / 密钥 / 校验 / 写配置），最后才动服务；任一步失败即还原配置、重建服务单元并重新拉起原服务。

</details>

---

## 🧹 卸载

主菜单 `7) 卸载管理`：

| 选项 | 作用 |
|:---:|:---|
| `1` | 仅删除 Xray 服务（保留 Tunnel） |
| `2` | 仅删除 Tunnel 服务（保留 Xray） |
| `3` | 删除全部 Suoha Plus |

ShadowQuic 在菜单 `8 → 7` 单独卸载。

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

`test/` 下另有专项脚本可单独运行：`dl_test.sh`（下载确认与进度）、`download_audit.sh`（网络请求点审计）、`vq_test.sh` / `vq_tty2.sh`（版本查询提示）、`fix_test.sh`（修复项回归）、`health_probe.sh`（健康探测）。

测试脚本自动定位仓库内主脚本，也可指定路径：`sh test/run.sh /path/to/suoha-manager.sh`。

---

## 📜 更新日志

### v2.6.3 — 二次真机实测：修 9 个实际缺陷（含 2 个 P0）

> 本轮全部在真实 Alpine VPS（OpenRC + busybox）上跑通：Reality / Quick Tunnel / ShadowQuic 三协议端到端 200，回滚、升级、卸载全流程验证。

- 🚨 **P0-1 `sh` 下 state.env 被写成一行垃圾**：busybox/musl 的 `printf` 不支持 `%q`，21 处 `printf 'KEY=%q'` 全部报 `invalid format`，结果 `state.env` 变成 `MODE=PROTOCOL=EDGE_IP=...=`，所有状态丢失。新增 `shquote()` / `state_line()` 做 POSIX 单引号转义，全平台一致。
- 🚨 **P0-2 回滚反而污染配置**：`txn_begin` 在“问完参数”之后才执行，快照里存的已经是用户刚填的非法值；失败回滚时又把坏值写回 `state.env`，出现「回滚完成」但菜单显示 `bad sni!` 而实际配置是旧值。快照前移到读输入之前，并新增 `_txn_restart_services()` 让回滚只重启服务、不再写状态文件。
- 🎯 **升级后的版本号丢失，重装直接降级**：`XRAY_VERSION` 在脚本顶部求值，那时 `state.env` 还没加载，`SUOHA_XRAY_VERSION` 被脚本内置值覆盖。`load_state` 里补显式同步（实测：升级到 v26.10.21，重开仍显示 v26.10.21，重装不再降级）。
- 📊 **版本检查恒定误报「有新版本」**：比较写成 `v${xc#v}` vs `${xl#v}`，一边带 v 一边不带，永远不等。改为两边都剥 `v` 前缀。
- 🌐 **Reality dest 裸 IPv6 放行但 Xray 不认**：`2001:db8::1` 的末段被当端口 `port=1` 放行，Xray 实际报 `please fill in a valid value for target`。现在裸 IPv6 直接拒绝并提示写 `[IPv6]:端口`，`[IPv6]` 自动补 `:443`。
- 🔀 **模式切换残留 Reality 开关**：装过 Reality 再装 Quick，`REALITY_ENABLED` 仍是 `yes`，节点文件写出带 `pbk=/sid=` 的假 Reality 链接，`NODE_ADDRESS` 为空时还会拼出 `vless://uuid@0:8443`。`setup_quick` / `setup_persistent` 进入即清 `REALITY_ENABLED`，并在失败分支还原。
- 🔗 **WS/vmess 节点地址为空时生成坏链接**：`@:443`、`add:""`。改为回退到隧道域名。
- ✏️ **菜单 5→4→1 手改配置立刻被覆盖**：保存后走 `apply_config_now` → `write_xray_config`，按 state 变量整份重写。现在只做 `xray -test` 校验 + 重启，手改内容保留。
- 🧹 **死代码与遗漏**：`rotate_all_logs` 从未被调用（日志无限增长）已挂到主菜单；删除 `lock_acquire` / `sq_detect_service` / `SQ_CMD`；Quick 模式补上 `install_cmd_link`（此前装完 Quick 没有 `suoha-plus` 命令）；`--version` 改读实际二进制版本；`sq_status_line` 的 `pgrep` 兜底改为只认本项目进程；`banner` 边框改为按固定宽度填充，版本号变长不再歪。

**测试脚本同步修复**：`extract_funcs.sh` 原先被注释里的 `" 或 }` 干扰，抽取出的 lib 语法错误导致全部行为测试假失败；`test_nohang.sh` 断言文案与实际输出不一致；`test_static.sh` 版本断言硬编码。修完 7 套件全过。

### v2.6.2 — 真机全流程实测后修三个逻辑缺陷

- 🚨 **错误提示被永久丢弃（最严重）**：`exec 9>"$LOCK_FILE" 2>/dev/null` 的重定向对 shell 本身持久生效，导致后续所有 `stderr` 指向 `/dev/null`，`err()` 打印的错误用户一个字都看不到，表现为"选了菜单没反应"。改为 `{ exec 9>"$LOCK_FILE"; } 2>/dev/null`，把重定向限定在命令内。
- 🛟 **安装失败后不回滚**：旧实现一进 `setup_*` 就停服务、删服务单元，之后才校验参数；任一步失败则节点当场断掉且不会自愈。现改为「先做所有可能失败的步骤，最后才动服务」，并新增安装事务 `txn_begin / txn_commit / txn_rollback`。
- 🎯 **ShadowQuic 停止误杀同机其他实例**：原 `pgrep -f '[s]hadowquic' | kill -9` 会连带杀掉其他项目的进程。新增 `sq_proc_is_ours` / `sq_pids_ours`，逐个读 `/proc/PID/cmdline` 精确识别本项目进程。

<details>
<summary><b>📚 历史版本（点击展开）</b></summary>

<br>

**v2.6.1** — 升级被问两次导致静默取消（新增 `preconfirmed` 标记）；Reality 模式协议显示从 `vmess` 修正为 `vless + xtls-rprx-vision`；升级确认文案补明会同步另一组件。

**v2.6.0** — 下载前必须确认（默认 N）；新增 `dl_run` 实时进度条；Reality 连接地址真正生效；健康检测改为真实 WebSocket 握手（只认 `101`/`400`/`426`）；Quick 重启后状态页提示地址失效；新增菜单 9 组件升级通道与环境变量覆盖；补齐 `REALITY_DEST`/`REALITY_SNI`/密钥输入校验。

**v2.5.0** — `vmess` 链接不再 `fold` 折行（避免粘贴后 base64 解码失败）；三个安装入口增加覆盖重装确认；`pause_screen` 改用安全 `read`，stdin 关闭不卡死。

**v2.4.5** — 修复 Quick 模式重复安装覆盖 pidfile 后旧 `cloudflared` 进程无法停止（按 `$APP_DIR/bin/*` 路径兜底清理）。

**v2.4.4** — 「删除全部」现在会一并清理 `suoha-shadowquic` 服务单元与 daemon wrapper，同时保护其他项目的 `/etc/shadowquic` 配置。

**v2.4.3** — `ask_default` 与 14 处 `read -r -p` 提示符写在子 shell 里被吞；改为 `safe_read`，stdin 关闭自动采用默认值；下载增加「最长等 N 秒 / 实际耗时 M 秒」反馈。

**v2.4.2** — 真机修 4 个阻断性问题：OpenRC 单元函数末句 `[ -f ] && ok` 导致安装误判失败；常驻进程继承锁 fd；重复安装累积多个 `supervise-daemon`；`suoha-plus` 命令缺执行位。

**v2.4.1** — 修复并发锁泄露；`sq_start` 不再可能启动其他项目的 shadowquic；服务 `crashed` 状态单独显示；新增 `test/test_regression.sh`。

**v2.4.0** — 修复 OpenRC 下状态显示与健康检测失效；`suoha-plus` 命令真实创建；ShadowQuic 支持 aarch64/armv7/i686 并新增升级菜单；公网 IP 探测进程内缓存；新增安装并发互斥锁与日志轮转。

**v2.3.2** — Xray 下载增加官方 `.dgst` SHA-256 校验；OpenRC 守护脚本每次启动重建日志目录；重装持久化 Tunnel 不再清空 `/root/.cloudflared` 中其他项目凭据。

**v2.3.1** — ShadowQuic 守护脚本缺失时自动重建；修复组件卸载在 OpenRC 下残留 init.d 与自启注册；`--version/--help` 管道模式不再误触发自重放；修复管道自重放死循环。

**v2.3.0** — 新增 OpenRC 开机自启支持（Alpine）；无 systemd 环境后台进程也能自启；卸载时清理 OpenRC 注册。

**v2.2.2** — 重装持久化隧道支持「删除全部 Cloudflare 配置并重新登录」；账号已有同名隧道但本地凭据缺失时自动删除重建。

**v2.2.1** — ShadowQuic 生成 `sq://` 分享链接并写入节点文件；主菜单显示配置位置；新增手动编辑配置功能。

**v2.2.0** — 新增 ShadowQuic 可选模块（移植自 `warp-` 项目，去 WARP/sing-box 依赖）；自动接管旧安装；OpenRC/systemd 双兼容。

**v2.1.0** — Reality 直连节点（XTLS Vision、双栈 v4/v6、与 WS 隧道共存）；WS 优选域名默认 `www.visa.com`；运行状态 `●/○` 显示 + 健康检测；修复 x25519 新版输出解析。

**v2.0.0** — Suoha Plus 独立版；固定版本；Quick / 持久化双隧道；自动节点刷新。

**v1.x** — 原 `suoha.sh` 系列功能。

</details>

---

## 🙏 致谢与许可

本项目由以下一键脚本的增强分支开发而来（在其基础上重构并扩展了 Reality、ShadowQuic、健康检测等功能）：

```bash
curl https://suoha.psai.eu.org/suoha.sh -o suoha.sh && chmod +x suoha.sh && bash suoha.sh
```

原脚本不受本仓库影响；本脚本独立安装、独立卸载，可与原脚本共存。

- 示例配置部分参考 [XTLS/Xray-examples](https://github.com/XTLS/Xray-examples)
- ShadowQuic 模块部署逻辑参考 [zhangweixy666/warp-](https://github.com/zhangweixy666/warp-)
- ShadowQuic 二进制来自 [spongebob888/shadowquic](https://github.com/spongebob888/shadowquic)

**许可**：CC-BY-SA-4.0

> ⚠️ **免责声明**：本项目仅供技术学习与研究使用。请遵守你所在地区的法律法规以及服务提供商的使用条款。使用者需自行承担因使用本脚本产生的一切后果。

<div align="center">

**[⬆ 回到顶部](#-suoha-plus)**

Made with 🍍 by [zhangweixy666](https://github.com/zhangweixy666)

</div>
