# Suoha Plus — Xray 多模式节点一键管理脚本（WS隧道 / Reality直连 / ShadowQuic）

VPS 一键部署 Xray 节点：**vless+Reality 直连（无需域名）** 与 **vmess/vless+WS 走 Cloudflare Tunnel** 双方案任选，还可共存运行；另含可选模块 **ShadowQuic**（0-RTT QUIC 代理，UDP 端口，SNI 伪装，无需域名证书）。

适用于 Debian/Ubuntu 等 Linux VPS（独立 IPv4、NAT、仅 IPv6 机器均可），兼容 systemd 与 OpenRC（Alpine）。README 的命令按「一个代码块一个命令」排列，便于直接复制执行。

## 📌 项目来源

本脚本由以下一键脚本的增强分支开发而来（在其基础上重构并扩展了 Reality、ShadowQuic、健康检测等功能）：

```sh
curl https://suoha.psai.eu.org/suoha.sh -o suoha.sh && chmod +x suoha.sh && bash suoha.sh
```

原脚本不受本仓库影响；本脚本独立安装、独立卸载，可与原脚本共存。

## ✨ 项目简介

本脚本是一个独立的增强版管理工具，**不会影响机器上的其他脚本与服务**。

核心特性：

- 一键安装固定版本的 Xray 与 cloudflared（不追新，版本稳定可复现）
- **Reality 直连节点**：vless + XTLS Vision + Reality，无需域名、无需隧道、无证书成本
  - 自动生成 x25519 密钥与 shortId（兼容新旧版 `xray x25519` 输出格式）
  - 默认借牌 `www.apple.com`（TLS1.3 + h2），对外探测呈现真实 Apple EV 证书
  - 自动探测公网 IPv4 / IPv6，双栈同时生成节点链接
  - NAT VPS / 纯 IPv6 机器友好（IPv6 端口通常全开）
- **WS + Cloudflare Tunnel 节点**：Quick（免授权秒开）与持久化（自有域名）两种模式
  - 持久化模式域名固定不变；Quick 重启自动换新地址并刷新节点
  - 默认优选接入域名 `www.visa.com`（VISA 自有域名、解析到 Cloudflare 边缘、对中国友好）
- **ShadowQuic 可选模块**（来自 [warp-](https://github.com/zhangweixy666/warp-) 项目的部署逻辑移植，不依赖 WARP/sing-box）
  - 0-RTT QUIC 代理 + JLS SNI 伪装（借牌 apple.com），UDP :1443，免域名免证书
  - 自动生成随机账号密码，直连/SOCKS5 出站双配置文件，一键切换
  - 独立 systemd / OpenRC 服务 `suoha-shadowquic`，开机自启 + 崩溃自动重启
  - 已有旧 shadowquic 安装会被自动接管（停旧服务、移除旧注册、复用配置目录）
  - 生成 **sq:// 分享链接**（IPv4/IPv6 双栈）+ Clash.Meta/mihomo + 官方客户端配置
- Reality 与 WS+隧道可**双节点共存**：一次安装，两条链路互为备份
- **OpenRC 开机自启**（Alpine）：安装持久化隧道时自动注册 `suoha-plus-xray`、`suoha-plus-cloudflared` 到 rc-update default，重启自动拉起（systemd 环境对应 systemd 服务）
- 自动生成 vless:// / vmess:// 分享链接，v2rayN / v2rayNG / Clash Meta 可直接导入
- **运行状态显示**：主菜单实时 `● 运行中 / ○ 未运行`（含 PID）
- **健康检测**：服务在线时自动实测 Reality 端口监听、隧道域名 WS 链路
- **配置位置透明 + 手动编辑**：菜单内直接查看/编辑 Xray、隧道、ShadowQuic 配置文件
- 支持单独删除 Xray 或单独删除 Cloudflare Tunnel 服务；ShadowQuic 独立子菜单管理
- 支持一键完全卸载，不影响系统其他组件
- 本地 WS 仅监听 127.0.0.1，公网流量全部走 Cloudflare 边缘网络；Reality/QUIC 端口独立监听
- 中文菜单界面

## 🧩 功能概览

| 功能 | 说明 |
|------|------|
| 固定版本安装 | Xray 与 cloudflared 版本锁定，不受上游更新影响 |
| Reality 直连 | vless+Vision+Reality，免域名免隧道，IPv4/IPv6 双栈链接 |
| Quick Tunnel | 无需 Cloudflare 授权，运行即得 trycloudflare.com 临时地址 |
| 持久化 Tunnel | 使用已有 cert.pem 授权，域名固定不变 |
| 双节点共存 | Reality 直连 + WS 隧道同时运行，节点文件同时输出两类链接 |
| ShadowQuic 模块 | 可选 QUIC 代理：UDP 1443、SNI 伪装、随机凭据、sq:// 链接、直连/SOCKS 出站切换 |
| 运行状态显示 | 主菜单实时显示 `● 运行中 / ○ 未运行`（含 PID） |
| 健康检测 | 服务在线时自动实测：Reality 端口监听、隧道域名 WS 链路探测 |
| 配置管理 | 菜单内显示配置文件位置，支持 vi/vim/nano 手动编辑后自动重启生效 |
| 协议支持 | Reality 模式 vless+TCP；隧道模式 vmess/vless+WS；QUIC 模式 shadowquic |
| 节点生成 | 自动生成 vless:// / vmess:// / sq:// 分享链接（Reality v4/v6、TLS 443、明文 80） |
| 重启刷新 | 重启服务自动换新 Quick 地址并同步更新节点文件 |
| 组件卸载 | 支持单独删除 Xray / 单独删除 Tunnel / ShadowQuic / 全部删除 |
| 中文界面 | 菜单、状态、错误提示均为中文 |

## ⚡ 快速开始

### 方式一：在线一键运行（推荐）

```sh
wget -qO- https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/suoha-manager.sh | sh
```

脚本会自动下载副本到 `/root/suoha-plus-managed.sh` 并以交互模式重新启动，菜单正常可用。

### 方式二：下载后运行

下载脚本：

```sh
wget -qO /root/suoha-manager.sh https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/suoha-manager.sh
```

赋予执行权限：

```sh
chmod +x /root/suoha-manager.sh
```

启动菜单：

```sh
bash /root/suoha-manager.sh
```

## 🚀 安装模式

主菜单：

```text
1) 安装/启动 Quick Tunnel（重启后需重新生成地址）
2) 安装/启动持久化 Tunnel（需要 Cloudflare 域名授权）
3) 安装/启动 Reality 直连节点（无需域名，vless+Vision）
4) 服务管理
5) 配置管理（修改后自动重启并刷新节点）
6) 查看当前节点信息
7) 卸载管理（删除 Xray / 隧道 / 全部）
8) 安装/管理 ShadowQuic（QUIC 代理，UDP，可选模块）
0) 退出
```

### Reality 直连节点（菜单 3，推荐）

全程回车即可完成：自动生成密钥 → 确认端口/dest/SNI/地址 → 启动 → 输出节点链接。

- 监听端口默认 `8443`（可改）
- dest/SNI 默认 `www.apple.com`（可换成其他支持 TLS1.3+h2 的大站）
- 节点地址默认自动探测：**有公网 IPv6 优先输出 IPv6 链接**（NAT 机器端口全开），同时输出 IPv4 链接
- 不需要域名、不需要 Cloudflare、不需要证书

### Quick Tunnel（菜单 1）

免域名授权，秒级获得 `xxx.trycloudflare.com` 临时地址；重启后地址会变，脚本自动刷新节点。

### 持久化 Tunnel（菜单 2）

绑定自有 Cloudflare 域名，地址永久固定。首次需在浏览器完成 `cloudflared tunnel login` 授权。

### ShadowQuic 模块（菜单 8，可选）

```text
1) 安装/更新 ShadowQuic
2) 启动 ShadowQuic
3) 停止 ShadowQuic
4) 重启 ShadowQuic
5) 查看客户端接入信息
6) 查看日志（末 30 行）
7) 卸载 ShadowQuic
```

- 安装时默认：UDP `1443`、随机用户名/密码、SNI 伪装 `www.apple.com`、直连出站
- 二进制来自 [spongebob888/shadowquic](https://github.com/spongebob888/shadowquic) 官方 release（x86_64 musl 静态编译，ELF 校验后安装）
- 安装完成自动输出三种接入方式：**sq:// 分享链接**、Clash.Meta/mihomo YAML、官方客户端 YAML

**sq:// 分享链接格式**（部分客户端如 QuicProxy、husi、nekobox 支持直接导入）：

```text
sq://用户名:密码@[IPv6]:1443?alpn=h3&mtu=1280&sni=www.apple.com&udp_mode=datagram&zero_rtt=true#节点名
sq://用户名:密码@IPv4:1443?alpn=h3&mtu=1280&sni=www.apple.com&udp_mode=datagram&zero_rtt=true#节点名
```

- 注意：云安全组需放行 **UDP 1443**

## 📄 节点文件

所有模式的节点信息都写入：

```text
/opt/suoha-plus/v2ray.txt
```

内容包含：Reality vless:// 链接（v4/v6）、WS+隧道 vless:// 或 vmess:// 链接、ShadowQuic sq:// 链接，以及对应配置文件位置注释。

## ⚙️ 配置文件位置

主菜单顶部实时显示当前配置位置，也可在 `5) 配置管理 → 4) 手动编辑` 中查看和编辑：

| 组件 | 配置路径 |
|------|---------|
| Xray | `/opt/suoha-plus/xray.json` |
| Cloudflare Tunnel | `/opt/suoha-plus/config.yaml`（Quick 模式自动生成） |
| ShadowQuic 直连出站 | `/etc/shadowquic/server-direct.yaml` |
| ShadowQuic SOCKS 出站 | `/etc/shadowquic/server-socks.yaml` |
| ShadowQuic 出站模式 | `/etc/shadowquic/last-mode`（direct / socks） |
| 节点文件 | `/opt/suoha-plus/v2ray.txt` |

`5) 配置管理 → 4) 手动编辑` 支持用 vi/vim/nano 直接编辑以上文件：

- 编辑 Xray → 保存后自动校验配置、重启服务、刷新节点
- 编辑隧道 → 保存后自动重启隧道
- 编辑 ShadowQuic → 保存后自动重启生效
- 支持一键切换 ShadowQuic 出站模式（direct ⇄ socks）

## 🧰 服务管理

```sh
bash /root/suoha-plus-managed.sh
```

或使用管理命令：

```sh
suoha-plus
```

服务菜单支持启动 / 停止 / 重启（自动刷新节点）/ 查看节点信息。

数据目录：

```text
/opt/suoha-plus/
├── xray.json          # Xray 配置
├── config.yaml        # cloudflared 配置（持久化模式）
├── state.env          # 运行状态
├── v2ray.txt          # 节点分享链接
├── logs/              # 运行日志
└── bin/               # 固定版本二进制
```

## ❓ 常见问题

**NAT VPS 能用 Reality 吗？**
能。脚本默认优先走 IPv6（NAT 机器 IPv6 端口通常全开）；节点文件会同时给出 v4/v6 链接，实测哪个通用哪个。

**本地网络没有 IPv6，Reality_v6 连不上怎么办？**
用 WS+隧道节点（默认优选 `www.visa.com`，域名固定），或给本地加 IPv6（隧道/WireGuard 均可）。

**Reality 的 dest/SNI 可以换吗？**
可以，安装时按提示输入即可。要求：目标站支持 TLS1.3 + h2，且最好与 VPS 网络路由友好（大厂站点优先）。

**ShadowQuic 连不上？**
依次检查：①云安全组是否放行 UDP 1443 ②客户端 `server-name` 是否与服务端 `jls-upstream` 域名一致 ③菜单 8→6 看日志。

**机器上已有别的 shadowquic，会冲突吗？**
安装时自动接管：停掉旧服务、移除旧的开机自启注册、复用 `/etc/shadowquic` 目录写入新配置，不会双启。

**手动改了配置怎么生效？**
Xray：菜单 5→4 编辑保存即自动校验重启；ShadowQuic：菜单 5→4 编辑保存后自动重启；也可以直接重启对应服务。

**会影响机器上原有的 suoha.sh 吗？**
不会。本脚本使用独立目录 `/opt/suoha-plus`、独立服务名，卸载也只删除自身。

## 🧹 卸载

主菜单 `7) 卸载管理`：

- `1` 仅删除 Xray 服务（保留 Tunnel）
- `2` 仅删除 Tunnel 服务（保留 Xray）
- `3` 删除全部 Suoha Plus

ShadowQuic 在菜单 `8 → 7` 单独卸载。

## 📜 版本
- **v2.3.0**：新增 OpenRC 开机自启支持（Alpine：xray 与 cloudflared 名为 suoha-plus-xray / suoha-plus-cloudflared 的服务自动注册 rc-update default，重启后自动拉起，崩溃自动重启）；修复无 systemd 时后台进程方式无自启的问题；支持卸载时清理 OpenRC 注册

- **v2.3.1**：修复 ShadowQuic 守护脚本缺失时静默启动失败（启动前自动重建 daemon/init 服务，并接管清理旧版 shadowquic 自启注册）；修复组件卸载在 OpenRC 下残留 init.d 脚本与自启注册的问题；`--version/--help` 在管道模式下不再误触发自重放；重启后隧道健康探测增加重试，消除「刚重启连接未就绪即误报异常」；配置位置显示优化（无隧道配置时不再显示空管道符）；修复管道自重放循环（SUOHA_TTY 标记未检查导致二次重放/死循环）
- **v2.2.2**：重装持久化隧道时支持「删除全部 Cloudflare 配置并重新登录」（自动删除账号上的同名旧隧道与本地授权凭据后重新 login）；账号上已有同名隧道但本地凭据缺失时自动删除重建，不再报凭据错误

- **v2.2.1**：ShadowQuic 生成 `sq://` 分享链接（IPv4/IPv6，alpn/mtu/sni/udp_mode/zero_rtt 参数齐全）并写入节点文件；主菜单显示配置文件位置；新增手动编辑配置功能（vi/vim/nano，保存自动校验重启）；README 标明脚本来源
- **v2.2.0**：新增 ShadowQuic 可选模块（QUIC 代理，移植自 warp- 项目逻辑，去 WARP/sing-box 依赖）；自动接管旧安装；OpenRC/systemd 双兼容；客户端配置直接输出
- **v2.1.0**：Reality 直连节点（XTLS Vision，双栈 v4/v6，与 WS 隧道共存）；WS 优选域名默认 `www.visa.com`；运行状态 `●/○` 显示 + 健康检测；修复 x25519 新版输出解析；NAT/纯 IPv6 机器适配
- **v2.0.0**：suoha-plus 独立版；固定版本；Quick/持久化双隧道；自动节点刷新
- **v1.x**：原 suoha.sh 系列功能

## 📄 许可

CC-BY-SA-4.0（示例配置部分参考 [XTLS/Xray-examples](https://github.com/XTLS/Xray-examples)；ShadowQuic 模块部署逻辑参考 [zhangweixy666/warp-](https://github.com/zhangweixy666/warp-)）