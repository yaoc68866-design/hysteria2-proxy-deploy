# Hysteria 2 (Hy2) 代理一键部署脚本

> 基于 UDP + QUIC 的黑科技代理协议，通过修改拥塞控制算法在**高丢包、晚高峰**线路强行占用带宽，大幅提速。垃圾 VPS 也能跑满带宽。
>
> 与 VMess/V2ray 方案互补：VMess 走 TCP 稳定隐蔽，Hy2 走 UDP 速度优先。

## 工作原理

```
Hy2客户端 ──(UDP+QUIC+TLS)──► Hy2服务器 ──► 自由互联网
                                   │
                                   └──► 伪装成 bing.com (HTTP3 proxy)
```

**为什么 Hy2 能提速？**

普通代理协议（SS/VMess/VLESS/Trojan）走 TCP，遇到网络拥堵丢包时会按 BBR/Cubic 算法主动降速——君子协议，拥堵就让步。

Hy2 修改了 QUIC 的拥塞控制：不管网络是否拥堵，始终按你在配置中设定的速率收发数据。当别人降速避让时，你全速发送，抢占更多带宽。**在丢包严重的国际线路上提速效果极其明显**；如果线路本身很好（低丢包），则 Hy2 提升不大。

## 特点

- 🚀 **高丢包线路提速** — 晚高峰/国际出口丢包严重时速度远超 TCP 代理
- 🎭 **伪装 bing.com** — 外人探测 UDP 443 看到 HTTP3 的 Bing 网站
- 🖥️ **双系统支持** — Windows Server (本地执行) + Linux (生成脚本)
- 🔄 **开机自启 + 看门狗** — 崩溃自动恢复
- 🤝 **与 VMess 共存** — Hy2 走 UDP 443，不影响现有 TCP 443 节点
- 📋 **自动生成客户端配置** — 部署完直接用

## 文件说明

| 文件 | 用途 |
|------|------|
| `部署Hysteria2代理.ps1` | Windows 一键部署脚本 |
| `deploy_linux.sh` | Linux 本地执行部署脚本（由 PS1 脚本生成，或手动使用）|
| `README.md` | 本说明文档 |

## 快速开始

### 1. 前置准备

- 一台 VPS（Windows Server 或 Linux Ubuntu/Debian/CentOS）
- 本机有 PowerShell 5.1+（Windows）
- Linux 需要能执行 bash + curl

### 2. ⚠️ 安全组放行 UDP 端口

Hy2 走 **UDP**，不是 TCP！必须在云服务商安全组放行：

| 协议 | 端口 | 方向 |
|------|------|------|
| **UDP** | 443 (或自定义) | 入站允许 |

> 这是最容易漏的一步！很多人部署完连不上，90% 是没放行 UDP。

### 3. ⚠️ 不能走 Cloudflare CDN

Cloudflare 免费版不转发 UDP，所以 Hy2 **不能用 CF 橙云代理**。如果你用域名：
- DNS 记录必须设为 **灰云（DNS only）**，直接解析到服务器 IP
- 或者不用域名，客户端直接填服务器 IP

### 4. 运行脚本

#### Windows Server
```powershell
PowerShell -ExecutionPolicy Bypass -File .\部署Hysteria2代理.ps1
```
按提示填端口（默认 443）、密码（自动生成）、伪装域名（默认 bing.com），全自动完成。

#### Linux
```bash
# 方式一: 用 Windows 上的 PS1 脚本生成 deploy_linux.sh 后上传
# 方式二: 或在 Linux 服务器上直接执行官方安装 + 手动配置
bash <(curl -fsSL https://get.hy2.sh/)

# 生成自签证书
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500
chown hysteria /etc/hysteria/server.key /etc/hysteria/server.crt

# 写配置
cat << 'EOF' > /etc/hysteria/config.yaml
listen: :443
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: 你的密码
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOF

# 启动 + 自启
systemctl enable --now hysteria-server.service
systemctl status hysteria-server.service
# 看到 "server up and running" 即成功
```

### 5. 客户端使用

#### v2rayN (Windows)
1. 下载 [hysteria-windows-amd64.exe](https://github.com/apernet/hysteria/releases/latest)
2. 放入 v2rayN 的 `bin/hysteria/` 目录，重命名为 `hysteria.exe`
3. 创建客户端配置文件 `hy2.yaml`：
   ```yaml
   server: 你的IP或域名:443
   auth: 你的密码
   bandwidth:
     up: 50 mbps
     down: 300 mbps
   tls:
     sni: bing.com
     insecure: true
   socks5:
     listen: 127.0.0.1:1080
   http:
     listen: 127.0.0.1:8080
   ```
4. v2rayN → 添加自定义配置服务器 → 选 `hy2.yaml` → 内核选 `hy` → socks 端口 1080
5. 设为活动节点 → 测试

#### sing-box (Android/iOS)
```json
{
  "type": "hysteria2",
  "tag": "proxy",
  "server": "你的IP或域名",
  "server_port": 443,
  "up_mbps": 50,
  "down_mbps": 300,
  "password": "你的密码",
  "tls": {
    "enabled": true,
    "server_name": "bing.com",
    "insecure": true
  }
}
```

#### NekoBox / v2rayNG
选 Hysteria2 → 填地址/端口/密码 → SNI 填 bing.com → 开启「允许不安全」→ 上行 50 / 下行 300

## 连接参数

| 参数 | 值 |
|------|-----|
| 地址 | 服务器 IP 或域名 (灰云) |
| 端口 | 443 (UDP) |
| 协议 | Hysteria 2 |
| 密码 | 部署时设置的密码 |
| SNI | bing.com (自签证书时) |
| insecure | true (自签证书) |
| 上行带宽 | 50 Mbps (按你家宽带填) |
| 下行带宽 | 300 Mbps (按你家宽带填) |

## 带宽设置说明

- **客户端 `up` = 客户端上行 = 服务器接收**；**客户端 `down` = 客户端下行 = 服务器发送**
- 服务端不设带宽 → 跟随客户端设置
- **想用传统 BBR（不抢带宽、稳定）**：客户端把 `up`/`down` 都设为 `0`，或删掉 bandwidth 段
- 4K 视频 50 Mbps 下行足够，别设太大免得被运营商/VPS 商怀疑发起攻击
- 先用本地网络测速（不挂代理）获取家里实际上下行速率，再填入

## 与 VMess 节点共存

Hy2 走 **UDP 443**，VMess+Nginx 走 **TCP 443**，两者互不干扰，可以在同一台服务器上同时运行：

| 节点 | 协议 | 端口 | CDN | 优势 |
|------|------|------|-----|------|
| VMess | TCP+WS+TLS | TCP 443 | 可走 CF | 稳定、隐蔽、隐藏源IP |
| Hy2 | UDP+QUIC | UDP 443 | 不能走CF | 高速、丢包线路提速 |

客户端可同时导入两个节点，按需切换：线路好时用 VMess，晚高峰丢包严重时用 Hy2。

## 服务器文件位置

### Windows
| 内容 | 路径 |
|------|------|
| Hysteria 程序+配置 | `C:\hysteria\` |
| 证书 | `C:\hysteria\ssl\` |
| 看门狗 | `C:\nssm\hy_watchdog.bat` |
| 计划任务 | `HyService` (开机启动) + `HyWatchdog` (每3分钟检查)|

### Linux
| 内容 | 路径 |
|------|------|
| Hysteria 程序 | `/usr/local/bin/hysteria` |
| 配置文件 | `/etc/hysteria/config.yaml` |
| 证书 | `/etc/hysteria/server.crt` + `server.key` |
| 服务管理 | `systemctl {status\|restart\|stop} hysteria-server` |

## 常见问题

<details>
<summary><b>连不上代理？</b></summary>

1. 安全组是否放行 **UDP** 443？（不是 TCP！）
2. 域名是否灰云直连？（橙云会被 CF 拦 UDP）
3. 客户端 `insecure` 是否设为 `true`？（自签证书必须）
4. 服务端是否 `server up and running`？
</details>

<details>
<summary><b>速度没有提升？</b></summary>

说明你的线路本身丢包率低，Hy2 优势不明显——这是正常现象，用 VMess 即可。Hy2 的意义是**在已经很差的线路上抢带宽**，好线路上和普通代理差距不大。
</details>

<details>
<summary><b>被运营商限速了？</b></summary>

别把带宽设太大。4K 视频 50 Mbps 够用，设 300 Mbps 容易被运营商或 VPS 商当成发起 DDoS 攻击而限速/封号。合理设置即可。
</details>

<details>
<summary><b>浏览器访问域名看不到 bing 伪装？</b></summary>

正常。浏览器默认走 TCP 的 HTTP/2，而 Hy2 伪装是 UDP 的 HTTP/3。用 `curl --http3` 才能验证伪装效果。
</details>

<details>
<summary><b>服务器重启后还在吗？</b></summary>

在。Windows 用计划任务 + 看门狗（每3分钟检查自动拉起）；Linux 用 systemd 自启。
</details>

## 卸载

### Windows
```powershell
schtasks /delete /tn HyService /f
schtasks /delete /tn HyWatchdog /f
Stop-Process -Name hysteria -Force
Remove-Item C:\hysteria, C:\nssm\hy_watchdog.bat -Recurse -Force
netsh advfirewall firewall delete rule name="Hysteria2-UDP-443"
```

### Linux
```bash
bash <(curl -fsSL https://get.hy2.sh/) --remove
# 或
systemctl stop hysteria-server; systemctl disable hysteria-server
rm -rf /etc/hysteria /usr/local/bin/hysteria
```

## 参考文档

- [Hysteria 2 官方文档](https://v2.hysteria.network/zh/)
- [原始教程 (不良林)](https://bulianglin.com/archives/hysteria2.html)

---

⚠️ 本项目仅供学习研究使用，请遵守当地法律法规。