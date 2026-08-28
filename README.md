# Suoha Plus — Xray 多模式节点一键管理脚本（WS隧道 / Reality直连）

VPS 一键部署 Xray 节点：**vless+Reality 直连（无需域名）** 与 **vmess/vless+WS 走 Cloudflare Tunnel** 双方案任选，还可共存运行。

适用于 Debian/Ubuntu 等 Linux VPS（独立 IPv4、NAT、仅 IPv6 机器均可）。README 的命令按「一个代码块一个命令」排列，便于直接复制执行。

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
- Reality 与 WS+隧道可**双节点共存**：一次安装，两条链路互为备份
- 自动生成 vless:// / vmess:// 分享链接，v2rayN / v2rayNG / Clash Meta 可直接导入
- 支持单独删除 Xray 或单独删除 Cloudflare Tunnel 服务
- 支持一键完全卸载，不影响系统其他组件
- 本地 WS 仅监听 127.0.0.1，公网流量全部走 Cloudflare 边缘网络；Reality 端口独立监听
- 中文菜单界面

## 🧩 功能概览

| 功能 | 说明 |
|------|------|
| 固定版本安装 | Xray 与 cloudflared 版本锁定，不受上游更新影响 |
| Reality 直连 | vless+Vision+Reality，免域名免隧道，IPv4/IPv6 双栈链接 |
| Quick Tunnel | 无需 Cloudflare 授权，运行即得 trycloudflare.com 临时地址 |
| 持久化 Tunnel | 使用已有 cert.pem 授权，域名固定不变 |
| 双节点共存 | Reality 直连 + WS 隧道同时运行，节点文件同时输出两类链接 |
| 协议支持 | Reality 模式 vless+TCP；隧道模式 vmess/vless+WS |
| 节点生成 | 自动生成 vless:// / vmess:// 分享链接（Reality v4/v6、TLS 443、明文 80） |
| 重启刷新 | 重启服务自动换新 Quick 地址并同步更新节点文件 |
| 组件卸载 | 支持单独删除 Xray / 单独删除 Tunnel / 全部删除 |
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

## 🚀 三种安装模式

主菜单：

```text
1) 安装/启动 Quick Tunnel（重启后需重新生成地址）
2) 安装/启动持久化 Tunnel（需要 Cloudflare 域名授权）
3) 安装/启动 Reality 直连节点（无需域名，vless+Vision）
4) 服务管理
5) 配置管理（修改后自动重启并刷新节点）
6) 查看当前节点信息
7) 卸载管理（删除 Xray / 隧道 / 全部）
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

## 📄 节点文件

所有模式的节点信息都写入：

```text
/opt/suoha-plus/v2ray.txt
```

Reality 模式示例输出：

```text
vless://<uuid>@<IPv4>:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=<公钥>&sid=<shortId>&type=tcp#SuohaPlus_reality_v4

vless://<uuid>@<IPv6>:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=<公钥>&sid=<shortId>&type=tcp#SuohaPlus_reality_v6
```

若同时存在隧道域名，还会附带 WS+隧道节点链接（TLS 443 / 优选域名 / 明文 80）。

## 🧰 服务管理

```sh
bash /root/suoha-plus-managed.sh
```

或使用管理命令：

```sh
suoha-plus
```

服务菜单支持启动 / 停止 / 重启（自动刷新节点）/ 查看节点信息。

配置文件与数据目录：

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

**Quick 和持久化隧道冲突吗？**
同一时间运行一种隧道模式即可；切换模式时脚本会自动停掉旧服务。

**会影响机器上原有的 suoha.sh 吗？**
不会。本脚本使用独立目录 `/opt/suoha-plus`、独立服务名，卸载也只删除自身。

## 🧹 卸载

主菜单 `7) 卸载管理`：

- `1` 仅删除 Xray 服务（保留 Tunnel）
- `2` 仅删除 Tunnel 服务（保留 Xray）
- `3` 删除全部 Suoha Plus

## 📜 版本

- **v2.1.0**：新增 Reality 直连节点（XTLS Vision，双栈 v4/v6，与 WS 隧道共存）；WS 优选域名默认 `www.visa.com`；修复 x25519 新版输出解析；NAT/纯 IPv6 机器适配
- **v2.0.0**：suoha-plus 独立版；固定版本；Quick/持久化双隧道；自动节点刷新
- **v1.x**：原 suoha.sh 系列功能

## 📄 许可

CC-BY-SA-4.0（示例配置部分参考 [XTLS/Xray-examples](https://github.com/XTLS/Xray-examples)）
