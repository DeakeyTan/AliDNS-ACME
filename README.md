# AliDNS-ACME

使用 [acme.sh](https://github.com/acmesh-official/acme.sh) + 阿里云 AliDNS DNS-01，为 Hysteria2 独立申请 Let's Encrypt TLS 证书并自动续期。适用于 Debian/Ubuntu VPS，不改动现有 NPS、内网 Nginx、DNS A/泛域名记录和现有监听端口。

## 功能与限制

- 交互式输入域名、ACME 邮箱、阿里云 RAM AccessKey ID 和 Secret（Secret 不回显）。
- 自动安装或复用 acme.sh，签发 ECDSA P-256 单域名证书。
- 自动部署到 `/etc/hysteria/certs/fullchain.pem`、`/etc/hysteria/certs/privkey.pem`，登记定期续期的证书部署路径。
- 检查 Hysteria2 服务账号读取私钥的权限。
- **不会安装 Hysteria2**；执行前要求 `hysteria-server.service` 已存在。需要 root，且仅支持 Debian/Ubuntu。
- 如果目标证书文件已经存在，脚本拒绝覆盖。暂不支持通配符域名。

## 一、准备阿里云 RAM AccessKey

建议新建专用 RAM 用户及 AccessKey，至少需要对应域名区域的 `alidns:DescribeDomainRecords`、`alidns:AddDomainRecord`、`alidns:DeleteDomainRecord` 权限；尽可能限制写入资源范围。不要使用阿里云主账号密钥，也不要提交密钥到 GitHub。DNS-01 通过创建临时 `_acme-challenge` TXT 记录完成验证，不占用 TCP 80/443。

## 二、安装 Hysteria2 官方服务

```bash
bash <(curl -fsSL https://get.hy2.sh/)
systemctl cat hysteria-server.service
```

官方指南：https://v2.hysteria.network/docs/getting-started/Server-Installation-Script/

## 三、运行脚本

在公网 VPS 上以 root 身份运行，建议先审阅脚本源码：

```bash
sudo -i
curl -fsSLo /root/setup_alidns_acme_for_hysteria2.sh \
  https://raw.githubusercontent.com/DeakeyTan/AliDNS-ACME/main/setup_alidns_acme_for_hysteria2.sh
bash /root/setup_alidns_acme_for_hysteria2.sh
```

交互输入 `node.example.com` 这样的完整域名、邮箱，以及专用 AliDNS RAM AccessKey。真实 Secret 不应出现在 Shell 命令或 README 中。

## 四、Hysteria2 使用证书

在 `/etc/hysteria/config.yaml` 中配置（密码务必替换）：

```yaml
listen: :8443
tls:
  cert: /etc/hysteria/certs/fullchain.pem
  key: /etc/hysteria/certs/privkey.pem
  sniGuard: strict
auth:
  type: password
  password: "REPLACE_WITH_STRONG_RANDOM_PASSWORD"
```

然后执行：

```bash
systemctl enable --now hysteria-server.service
systemctl status hysteria-server.service
```

在 VPS 防火墙和云安全组放行 **UDP 8443**，不会改变现有 NPS 使用的 TCP 端口。

## 五、验证自动续期

```bash
crontab -l | grep acme.sh
/root/.acme.sh/acme.sh --list
openssl x509 -in /etc/hysteria/certs/fullchain.pem -noout -dates -ext subjectAltName
```

acme.sh 负责自动续期并部署到证书目录；Hysteria2 在后续 TLS 握手读取更新后的证书，通常无需重启。AliDNS API 密钥由 acme.sh 存放在 root 的配置目录下以供自动续期，请确保权限和备份安全，定期检查续期状态。

## 网络架构

```text
AliDNS: node.example.com -> 公网 VPS（现有 A 记录不变）
  ├── TCP：现有 NPS -> 内网 Nginx（原 ACME 证书）
  └── UDP 8443：Hysteria2 <- /etc/hysteria/certs/*.pem
                           <- acme.sh + AliDNS DNS-01
```

第三方工具遵循各自的开源许可。部署前请审阅脚本和依赖。