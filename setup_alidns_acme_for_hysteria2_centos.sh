#!/usr/bin/env bash
# AliDNS DNS-01 + Let's Encrypt via acme.sh for Hysteria2 on CentOS 7 (EOL), CentOS Stream and RHEL-family hosts.
# Certificate management only: does not edit NPS, Nginx, DNS A records, firewalls, or service ports.
set -Eeuo pipefail
umask 077
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TEMP_INSTALLER=""
cleanup() {
  unset Ali_Key Ali_Secret 2>/dev/null || true
  if [[ -n "$TEMP_INSTALLER" && -f "$TEMP_INSTALLER" ]]; then
    rm -f -- "$TEMP_INSTALLER"
  fi
}
trap cleanup EXIT

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || err 'Run as root (sudo -i, then bash script.sh).'
[[ -r /etc/os-release ]] || err 'Cannot identify the operating system.'
# shellcheck disable=SC1091
source /etc/os-release
OS_ID="${ID:-}"
OS_VERSION="${VERSION_ID:-}"
MAJOR="${OS_VERSION%%.*}"
[[ "$MAJOR" =~ ^[0-9]+$ ]] || err "Unrecognized OS version: $OS_VERSION"
case "$OS_ID" in
  centos)
    if (( MAJOR == 7 )) && ! { [[ -r /etc/centos-release ]] && grep -qi 'CentOS Stream' /etc/centos-release; }; then
      echo 'WARNING: CentOS Linux 7 reached EOL on June 30, 2024. No security updates are provided.' >&2
      echo 'WARNING: The Hysteria2 project documents QUIC/old-kernel issues on CentOS 7.' >&2
      echo 'This script configures ACME certificates only and does NOT guarantee Hysteria2 network compatibility.' >&2
      read -r -p 'Continue on unsupported CentOS 7 (type YES)? ' EOL_CONFIRM
      [[ "$EOL_CONFIRM" == YES ]] || err 'Cancelled. Migrate to Rocky Linux/AlmaLinux 9+ when possible.'
    elif (( MAJOR < 9 || MAJOR > 10 )) || ! { [[ -r /etc/centos-release ]] && grep -qi 'CentOS Stream' /etc/centos-release; }; then
      err 'Supported CentOS editions: CentOS Linux 7 (EOL; explicit acknowledgement) and CentOS Stream 9/10.'
    fi
    ;;
  rocky|almalinux|rhel)
    (( MAJOR >= 8 )) || err "Unsupported $OS_ID $OS_VERSION (requires 8+)."
    ;;
  *) err "Unsupported distribution: $OS_ID. Use the Debian/Ubuntu script on those systems." ;;
esac
command -v systemctl >/dev/null || err 'systemd is required.'
systemctl cat hysteria-server.service >/dev/null 2>&1 || \
  err 'Install the official Hysteria2 service first: bash <(curl -fsSL https://get.hy2.sh/)'
SERVICE_USER="$(systemctl show -p User hysteria-server.service 2>/dev/null | sed -n 's/^User=//p' || true)"
SERVICE_USER="${SERVICE_USER:-root}"
id "$SERVICE_USER" >/dev/null 2>&1 || err "Hysteria service user does not exist: $SERVICE_USER"
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"

CERT_DIR=/etc/hysteria/certs
for FILE in "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem"; do
  [[ ! -L "$FILE" ]] || err "Refusing symlink certificate path: $FILE"
  [[ ! -s "$FILE" ]] || err "Non-empty certificate exists: $FILE (back up and review before reusing)."
done

printf '=== AliDNS ACME on %s %s ===\n' "$OS_ID" "$OS_VERSION"
read -r -p 'Certificate hostname (e.g. node.example.com): ' DOMAIN
read -r -p 'ACME contact email: ' EMAIL
if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
  err 'Invalid FQDN; wildcard certificates are not supported by this script.'
fi
[[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || err 'Invalid contact email.'
read -r -p 'AliDNS RAM AccessKey ID: ' Ali_Key
read -r -s -p 'AliDNS RAM AccessKey Secret (hidden): ' Ali_Secret
printf '\n'
[[ -n "$Ali_Key" && -n "$Ali_Secret" ]] || err 'AliDNS AccessKey ID and Secret are required.'
export Ali_Key Ali_Secret

if command -v dnf >/dev/null 2>&1; then
  PM=dnf
elif command -v yum >/dev/null 2>&1; then
  PM=yum
else
  err 'Neither dnf nor yum found.'
fi
printf '[1/4] Installing ACME dependencies via %s (no system upgrade)...\n' "$PM"
if ! "$PM" install -y curl ca-certificates openssl cronie util-linux coreutils; then
  if [[ "$OS_ID" == centos && "$MAJOR" == 7 ]]; then
    err 'yum installation failed. CentOS 7 mirrorlist is retired; review /etc/yum.repos.d and configure the archived vault.centos.org/7.9.2009 repositories manually (back up old .repo files first). This script will not change your repository configuration.'
  fi
  err "$PM failed to install ACME dependencies. Fix the repository/network errors and rerun."
fi
systemctl enable --now crond.service

ACME=/root/.acme.sh/acme.sh
if [[ ! -x "$ACME" ]]; then
  echo '[2/4] Installing acme.sh from the official source...'
  TEMP_INSTALLER="$(mktemp)"
  curl -fsSL https://get.acme.sh -o "$TEMP_INSTALLER"
  sh "$TEMP_INSTALLER" "email=$EMAIL"
else
  echo '[2/4] Reusing installed acme.sh.'
fi
[[ -x "$ACME" ]] || err "acme.sh not found at $ACME"
chmod 700 /root/.acme.sh
if ! crontab -l 2>/dev/null | grep -Eq 'acme\.sh.*--cron'; then
  { crontab -l 2>/dev/null || true; echo '19 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >/dev/null 2>&1'; } | crontab -
fi
"$ACME" --set-default-ca --server letsencrypt

printf '[3/4] Issuing ECDSA P-256 certificate for %s using AliDNS DNS-01...\n' "$DOMAIN"
"$ACME" --issue --dns dns_ali -d "$DOMAIN" --keylength ec-256 --server letsencrypt

# Avoid broad changes to the original Hysteria configuration directory.
if [[ ! -d /etc/hysteria ]]; then
  install -d -o root -g "$SERVICE_GROUP" -m 750 /etc/hysteria
fi
if [[ "$SERVICE_USER" != root ]] && ! runuser -u "$SERVICE_USER" -- test -x /etc/hysteria; then
  chgrp "$SERVICE_GROUP" /etc/hysteria
  chmod g+x /etc/hysteria
fi
install -d -o root -g "$SERVICE_GROUP" -m 750 "$CERT_DIR"
for NAME in privkey.pem fullchain.pem; do
  if [[ ! -e "$CERT_DIR/$NAME" ]]; then
    install -o root -g "$SERVICE_GROUP" -m 640 /dev/null "$CERT_DIR/$NAME"
  else
    chown "root:$SERVICE_GROUP" "$CERT_DIR/$NAME"
    chmod 640 "$CERT_DIR/$NAME"
  fi
done

printf '[4/4] Registering production certificate files for automatic renewal...\n'
"$ACME" --install-cert -d "$DOMAIN" --ecc \
  --key-file "$CERT_DIR/privkey.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem"

# Restore default SELinux contexts, if policy is installed; do not disable SELinux.
if command -v restorecon >/dev/null 2>&1; then
  restorecon -R "$CERT_DIR" || echo 'WARNING: restorecon failed; inspect SELinux labels.' >&2
fi
[[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]] || err 'Certificate installation failed.'
runuser -u "$SERVICE_USER" -- test -r "$CERT_DIR/privkey.pem" || \
  err "Service user $SERVICE_USER cannot read the key; check permissions/SELinux."

printf '\n=== Success: AliDNS certificate installed ===\n'
openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject -dates
# OpenSSL 1.0.2k on CentOS 7 does not support the x509 -ext flag.
openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -text | grep -A1 'X509v3 Subject Alternative Name' || true
printf '\nCertificate: %s/fullchain.pem\nPrivate key: %s/privkey.pem\nService user: %s\n' "$CERT_DIR" "$CERT_DIR" "$SERVICE_USER"
printf '\nAdd to /etc/hysteria/config.yaml:\n'
printf 'tls:\n  cert: %s/fullchain.pem\n  key: %s/privkey.pem\n  sniGuard: strict\n' "$CERT_DIR" "$CERT_DIR"
printf '\nRenewal: crond + acme.sh; existing NPS/Nginx services and ports were not changed.\n'
printf 'Verify: crontab -l | grep acme.sh; /root/.acme.sh/acme.sh --list\n'
printf 'Security: protect /root/.acme.sh (stored AliDNS credentials) and monitor certificate expiry.\n'
