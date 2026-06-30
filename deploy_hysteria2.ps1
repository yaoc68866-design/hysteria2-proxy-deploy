<#
.SYNOPSIS
    Hysteria 2 (Hy2) 代理一键部署脚本 - Windows Server / Linux 本地执行
.DESCRIPTION
    架构: Hysteria 2 (基于 UDP + QUIC, 抢占式拥塞控制, 高丢包线路提速)
    部署: 自动下载二进制 / 生成自签证书 / 写配置 / 设置开机自启 + 看门狗
    与 VMess 节点共存: Hy2 走 UDP 443, 不影响现有 TCP 443 节点
.NOTES
    详细步骤见 README.md
#>

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

# ===================== 工具函数 =====================
function Write-Step  { param($m) Write-Host "`n[*] $m" -ForegroundColor Cyan }
function Write-OK    { param($m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn2{ param($m) Write-Host "    [!] $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "    [X] $m" -ForegroundColor Red }
function Read-Input  { param($prompt, $default = "")
    $v = Read-Host -Prompt $prompt
    if ([string]::IsNullOrWhiteSpace($v)) { return $default } else { return $v.Trim() }
}

# ===================== 主流程 =====================
Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  Hysteria 2 (Hy2) 代理一键部署脚本" -ForegroundColor Cyan
Write-Host "  架构: UDP + QUIC + 抢占式拥塞控制 (垃圾线路提速)" -ForegroundColor Gray
Write-Host "  支持: Windows Server (本地执行) / Linux (生成脚本后 SSH 执行)" -ForegroundColor Gray
Write-Host "============================================================" -ForegroundColor White
Write-Host ""

# 检测当前系统
$IsWindows = $true
if ($PSVersionTable.Platform -eq "Unix") { $IsWindows = $false }

# ---------- 收集参数 ----------
Write-Host "请填写部署参数 (直接回车使用默认值):" -ForegroundColor White
$ListenPort = [int](Read-Input "  监听端口 (UDP)" "443")
$Password   = Read-Input "  认证密码 (留空则自动生成)" ""
if ([string]::IsNullOrWhiteSpace($Password)) {
    $Password = ([char[]]([char]'a'..[char]'z') + [char[]]([char]'A'..[char]'Z') + [char[]]([char]'0'..[char]'9') | Get-Random -Count 12) -join ''
    Write-Host "  自动生成密码: $Password" -ForegroundColor Green
}
$SniName    = Read-Input "  伪装域名 (SNI)" "bing.com"
$MasqUrl    = Read-Input "  伪装代理网址" "https://bing.com"
$Listen     = ":$ListenPort"

# ---------- 检测 Python cryptography 库 (生成证书用) ----------
Write-Step "检查运行环境"
$hasPy = $false
try { $r = python -c "import cryptography; print('ok')" 2>$null; if ($r -eq "ok") { $hasPy = $true } } catch {}
if ($hasPy) { Write-OK "Python + cryptography 可用 (用于生成证书)" }
else { Write-Warn2 "未检测到 Python cryptography, 将使用 openssl 命令生成证书" }

# ===================== Windows Server 部署 =====================
if ($IsWindows) {
    Write-Step "1/7 下载 Hysteria 2 二进制 (Windows)"
    $hyDir = "C:\hysteria"
    $sslDir = "$hyDir\ssl"
    if (-not (Test-Path $hyDir)) { New-Item -ItemType Directory -Force -Path $hyDir | Out-Null }
    if (-not (Test-Path $sslDir)) { New-Item -ItemType Directory -Force -Path $sslDir | Out-Null }
    $hyExe = "$hyDir\hysteria.exe"
    if (-not (Test-Path $hyExe) -or (Get-Item $hyExe).Length -lt 1000000) {
        $url = "https://github.com/apernet/hysteria/releases/latest/download/hysteria-windows-amd64.exe"
        Write-Host "    从 GitHub 下载..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $hyExe -UseBasicParsing -TimeoutSec 180
        } catch {
            Write-Err "下载失败, 尝试镜像..."
            Invoke-WebRequest -Uri "https://mirror.ghproxy.com/$url" -OutFile $hyExe -UseBasicParsing -TimeoutSec 180
        }
    }
    if (Test-Path $hyExe) { Write-OK "hysteria.exe 就绪 ($('%.1f' -f ((Get-Item $hyExe).Length/1MB)) MB)" }
    else { Write-Err "下载失败, 请手动下载 hysteria-windows-amd64.exe 到 $hyExe"; exit 1 }

    Write-Step "2/7 生成自签 TLS 证书"
    if ($hasPy) {
        $genCertPy = @"
import os
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
import datetime
key = ec.generate_private_key(ec.SECP256R1())
subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, '$SniName')])
cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(issuer)
    .public_key(key.public_key()).serial_number(x509.random_serial_number())
    .not_valid_before(datetime.datetime.utcnow())
    .not_valid_after(datetime.datetime.utcnow() + datetime.timedelta(days=36500))
    .sign(key, hashes.SHA256()))
open(r'$sslDir\server.crt','wb').write(cert.public_bytes(serialization.Encoding.PEM))
open(r'$sslDir\server.key','wb').write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
print('OK')
"@
        $tmpPy = "$env:TEMP\gen_hy_cert.py"
        Set-Content -LiteralPath $tmpPy -Value $genCertPy -Encoding UTF8
        $r = python $tmpPy 2>&1
        Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
        if ($r -match "OK") { Write-OK "证书已生成 (EC256, 100年)" }
        else { Write-Warn2 "Python 生成失败, 将用 openssl"; $hasPy = $false }
    }
    if (-not $hasPy) {
        & openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) `
            -keyout "$sslDir\server.key" -out "$sslDir\server.crt" `
            -subj "/CN=$SniName" -days 36500 2>$null
        if (Test-Path "$sslDir\server.crt") { Write-OK "证书已生成 (openssl)" }
        else { Write-Err "证书生成失败, 请安装 openssl 或 Python cryptography"; exit 1 }
    }

    Write-Step "3/7 写入配置文件"
    $cfg = @"
listen: $Listen

tls:
  cert: $($sslDir.Replace('\','\\'))\server.crt
  key: $($sslDir.Replace('\','\\'))\server.key

auth:
  type: password
  password: $Password

masquerade:
  type: proxy
  proxy:
    url: $MasqUrl
    rewriteHost: true
"@
    Set-Content -LiteralPath "$hyDir\config.yaml" -Value $cfg -Encoding UTF8
    Write-OK "配置写入 $hyDir\config.yaml"

    Write-Step "4/7 放行防火墙 UDP 端口"
    netsh advfirewall firewall add rule name="Hysteria2-UDP-$ListenPort" dir=in action=allow protocol=UDP localport=$ListenPort 2>$null | Out-Null
    Write-OK "防火墙规则已添加 (UDP $ListenPort)"

    Write-Step "5/7 启动 Hysteria 2"
    Stop-Process -Name hysteria -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    Start-Process -FilePath $hyExe -ArgumentList "server","-c","$hyDir\config.yaml" -WorkingDirectory $hyDir -WindowStyle Hidden
    Start-Sleep 3
    $proc = Get-Process hysteria -ErrorAction SilentlyContinue
    if ($proc) { Write-OK "Hysteria 2 启动成功 (PID $($proc.Id))" }
    else { Write-Err "启动失败, 检查 $hyDir\config.yaml"; exit 1 }

    Write-Step "6/7 设置开机自启 + 看门狗 (计划任务)"
    $watchdog = "@echo off`r`ntasklist /FI ""IMAGENAME eq hysteria.exe"" 2>nul | findstr hysteria >nul`r`nif errorlevel 1 (`r`n  wmic process call create ""cmd /c cd /D $hyDir && hysteria.exe server -c config.yaml"" >nul 2>&1`r`n  echo [%date% %time%] hysteria restarted >> C:\nssm\hy_watchdog.log`r`n)"
    $wdDir = "C:\nssm"
    if (-not (Test-Path $wdDir)) { New-Item -ItemType Directory -Force -Path $wdDir | Out-Null }
    Set-Content -LiteralPath "$wdDir\hy_watchdog.bat" -Value $watchdog -Encoding ASCII
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $pwd = Read-Host -Prompt "    输入当前用户密码 (用于计划任务)" -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd))
    schtasks /create /tn "HyService" /tr "cmd /c cd /D $hyDir && start /B hysteria.exe server -c config.yaml" /sc onstart /ru $user /rp $plain /f /rl highest 2>$null | Out-Null
    schtasks /create /tn "HyWatchdog" /tr "$wdDir\hy_watchdog.bat" /sc minute /mo 3 /ru $user /rp $plain /f /rl highest 2>$null | Out-Null
    Write-OK "计划任务创建: HyService (开机启动) + HyWatchdog (每3分钟检查)"

    Write-Step "7/7 验证"
    netstat -ano -p UDP | findstr ":$ListenPort " | findstr UDP
    Write-Host "    UDP $ListenPort 监听状态如上"
}
# ===================== Linux 部署 (生成脚本) =====================
else {
    Write-Step "1/3 生成 Linux 本地部署脚本 (deploy_linux.sh)"
    $linuxScript = @"
#!/bin/bash
set -e
PORT=$ListenPort
PASS='$Password'
SNI='$SniName'
MASQ='$MasqUrl'

echo '=== 1. 一键安装 Hysteria 2 ==='
bash -(curl -fsSL https://get.hy2.sh/)

echo '=== 2. 生成自签证书 ==='
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
  -subj "/CN=$SNI" -days 36500
chown hysteria /etc/hysteria/server.key /etc/hysteria/server.crt

echo '=== 3. 写配置 ==='
cat << EOF > /etc/hysteria/config.yaml
listen: :${PORT}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${PASS}

masquerade:
  type: proxy
  proxy:
    url: ${MASQ}
    rewriteHost: true
EOF

echo '=== 4. 启动 + 自启 ==='
systemctl enable --now hysteria-server.service
systemctl status hysteria-server.service --no-pager

echo '=== 5. 放行防火墙 ==='
if command -v ufw >/dev/null; then
  ufw allow ${PORT}/udp
elif command -v firewall-cmd >/dev/null; then
  firewall-cmd --permanent --add-port=${PORT}/udp; firewall-cmd --reload
fi

echo '=== 完成! ==='
echo "地址: 本机IP:${PORT}"
echo "密码: ${PASS}"
echo "SNI:  ${SNI}"
"@
    $outFile = "$PWD\deploy_linux.sh"
    Set-Content -LiteralPath $outFile -Value $linuxScript -Encoding UTF8
    Write-OK "Linux 脚本已生成: $outFile"
    Write-Host "    上传到 Linux 服务器执行: bash deploy_linux.sh" -ForegroundColor Yellow

    Write-Step "2/3 提示"
    Write-Warn2 "Linux 服务器需要在云控制台安全组放行 UDP $ListenPort"
    Write-Warn2 "Hy2 不能走 Cloudflare CDN (CF 不转发 UDP), 域名要用灰云直连"

    Write-Step "3/3 客户端配置"
}

# ===================== 客户端配置输出 =====================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  部署完成!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  地址:       本机IP (或域名)" -ForegroundColor White
Write-Host "  端口:       $ListenPort (UDP)" -ForegroundColor White
Write-Host "  协议:       Hysteria 2" -ForegroundColor White
Write-Host "  密码:       $Password" -ForegroundColor White
Write-Host "  SNI:        $SniName" -ForegroundColor White
Write-Host "  跳过证书验证: true (自签证书)" -ForegroundColor White
Write-Host "  带宽:       上行 50 Mbps / 下行 300 Mbps" -ForegroundColor White
Write-Host ""
Write-Host "  >>> 安全组放行 <<<" -ForegroundColor Yellow
Write-Host "  云服务商控制台: 放行入站 UDP $ListenPort" -ForegroundColor Yellow
Write-Host ""
Write-Host "  >>> 不要走 Cloudflare CDN <<<" -ForegroundColor Yellow
Write-Host "  Hy2 是 UDP 协议, CF 不转发 UDP, 域名必须灰云直连" -ForegroundColor Yellow
Write-Host ""

# 生成客户端配置文件
$clientCfg = @"
server: 本机IP:$ListenPort
auth: $Password
bandwidth:
  up: 50 mbps
  down: 300 mbps
tls:
  sni: $SniName
  insecure: true
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080
"@
$clientPath = "$PWD\hy2_client.yaml"
Set-Content -LiteralPath $clientPath -Value $clientCfg -Encoding UTF8
Write-Host "  客户端配置已保存: $clientPath" -ForegroundColor Cyan
Write-Host "  (把 本机IP 改成实际服务器 IP 或域名)" -ForegroundColor Gray
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green