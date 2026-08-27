# Suoha Plus — Xray + Cloudflare Tunnel 一键管理脚本

VPS 一键部署 Xray vmess/vless+WS 节点，并通过 Cloudflare Tunnel 暴露为公网 HTTPS 服务。

适用于 Debian/Ubuntu 等 Linux VPS，兼容 LXC/容器环境。README 的命令按「一个代码块一个命令」排列，便于直接复制执行。

## ✨ 项目简介

本脚本是一个独立的增强版管理工具，**不会影响机器上的其他脚本与服务**。

核心特性：

- 一键安装固定版本的 Xray 与 cloudflared（不追新，版本稳定可复现）
- 支持 Quick Tunnel（免域名授权，秒开）和持久化 Tunnel（自有域名）
- 支持 vmess 和 vless 协议，WebSocket 传输
- Quick Tunnel 重启后自动重新生成地址，节点信息实时同步刷新
- 自动生成 vmess:// 链接，v2rayN / v2rayNG / Clash Meta 可直接导入
- 支持单独删除 Xray 或单独删除 Cloudflare Tunnel 服务
- 支持一键完全卸载，不影响系统其他组件
- 本地仅监听 127.0.0.1，公网流量全部走 Cloudflare 边缘网络
- 中文菜单界面

## 🧩 功能概览

| 功能 | 说明 |
|------|------|
| 固定版本安装 | Xray 与 cloudflared 版本锁定，不受上游更新影响 |
| Quick Tunnel | 无需 Cloudflare 授权，运行即得 trycloudflare.com 临时地址 |
| 持久化 Tunnel | 使用已有 cert.pem 授权，域名固定不变 |
| 协议支持 | vmess、vless，WebSocket 传输 |
| 节点生成 | 自动生成 vmess:// 分享链接（TLS 443 与明文 80 两种） |
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
sh /root/suoha-manager.sh
```

### 首次安装

在菜单中选择：

```text
1) 安装/启动 Quick Tunnel（重启后需重新生成地址）
```

全部提示直接回车使用默认值即可，大约 30 秒完成部署，完成后自动输出节点链接。

节点信息保存在：

```text
/opt/suoha-plus/v2ray.txt
```

## 🖥️ 主菜单

```text
 1) 安装/启动 Quick Tunnel（重启后需重新生成地址）
 2) 安装/启动持久化 Tunnel（需要 Cloudflare 域名授权）
 3) 服务管理
 4) 配置管理（修改后自动重启并刷新节点）
 5) 查看当前节点信息
 6) 卸载管理（删除 Xray / 隧道 / 全部）
 0) 退出
```

服务管理子菜单：

```text
 1) 启动 Xray + 隧道
 2) 停止 Xray + 隧道
 3) 重启 Xray + 隧道，并实时刷新节点
 4) 查看节点信息
 0) 返回主菜单
```

卸载管理子菜单：

```text
 1) 仅删除 Xray 服务（保留 Cloudflare Tunnel）
 2) 仅删除 Cloudflare Tunnel 服务（保留 Xray）
 3) 删除全部 Suoha Plus（原 suoha.sh 不受影响）
 0) 返回主菜单
```

## 🌐 工作方式

Quick Tunnel 典型链路如下：

```text
客户端
  ↓ vmess/vless
Cloudflare 边缘节点（443 TLS 或 80 明文）
  ↓ Cloudflare Tunnel 加密隧道
VPS 上的 cloudflared
  ↓ HTTP
127.0.0.1:随机端口
  ↓
Xray WebSocket
```

Quick Tunnel 地址每次重启会变化（例如 `xxxx-yyyy-zzzz.trycloudflare.com`），节点信息会自动同步更新；持久化模式地址固定不变。

节点示例：

```text
vmess://eyJ2IjoiMiIsInBzIjoiU3VvaGFQbHVzX3RscyIsImFkZCI6...
```

直接复制到 v2rayN / v2rayNG / Clash Meta 导入即可使用。

## 📁 主要文件和目录

| 路径 | 作用 |
|------|------|
| `/root/suoha-plus-managed.sh` | 在线运行时自动保存的脚本副本 |
| `/opt/suoha-plus/bin/` | Xray 与 cloudflared 二进制 |
| `/opt/suoha-plus/xray.json` | Xray 配置 |
| `/opt/suoha-plus/config.yaml` | cloudflared 隧道配置 |
| `/opt/suoha-plus/state.env` | 运行状态与参数 |
| `/opt/suoha-plus/v2ray.txt` | 节点分享链接 |
| `/opt/suoha-plus/logs/` | 服务日志 |
| `/usr/local/bin/suoha-plus` | 命令行快捷方式 |

## 🔍 常用排障

查看服务进程：

```sh
pgrep -af suoha-plus
```

查看 Xray 日志：

```sh
tail -n 50 /opt/suoha-plus/logs/xray.log
```

查看隧道日志：

```sh
tail -n 50 /opt/suoha-plus/logs/cloudflared.log
```

测试节点链路（路径换成你的 WS 路径，返回 HTTP 400 即为链路正常）：

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://你的隧道地址/你的WS路径
```

对 WebSocket 路径使用普通 HTTP 请求时，返回 `400` 不代表故障，说明请求已到达 Xray，公网到本地链路已经打通。

重新打开管理菜单：

```sh
suoha-plus
```

或

```sh
bash /root/suoha-plus-managed.sh
```

## ⚠️ 注意事项

- 所有脚本需要 root 权限。
- Quick Tunnel 地址重启后会变化，需要长期固定地址请选持久化 Tunnel（菜单 2）。
- 持久化模式需要 `/root/.cloudflared/cert.pem` 已存在（可用 `cloudflared login` 生成）。
- 卸载管理中的「删除全部」只删除 Suoha Plus 自己的文件与服务，不触碰其他程序。
- 不要把节点链接、隧道配置提交到公开仓库。
- 请只在自己拥有或获授权管理的服务器上使用。

## 📄 License

GPL-3.0

## 🔗 相关链接

- 本项目：https://github.com/zhangweixy666/suoha-plus
- 管理脚本：https://raw.githubusercontent.com/zhangweixy666/suoha-plus/main/suoha-manager.sh
