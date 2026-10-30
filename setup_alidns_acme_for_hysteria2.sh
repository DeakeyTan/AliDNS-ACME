#!/usr/bin/env bash
# AliDNS DNS-01 + Let's Encrypt (acme.sh) certificate provisioning for Hysteria2.
# Target: Debian/Ubuntu VPS with Hysteria2 official systemd installation.
# Scope: certificate management ONLY. Does not alter NPS, Nginx, DNS A records or ports.
set -Eeuo pipefail
umask 077

TEMP_INSTALLER=""
cleanup() {
  unset Ali_Key Ali_Secret 2>/dev/null || true
  if [[ -n "$TEMP_INSTALLER" && -f "$TEMP_INSTALLER" ]]; then
    rm -f "$TEMP_INSTALLER"
  fi
}
trap cleanup EXIT

if (( EUID != 0 )); then
  echo 'ERROR: Run this script as root (sudo -i, then bash ...).' >&2
  exit 1
fi

if [[ ! -f /etc/os-release ]] || ! grep -Eq '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then
  echo 'ERROR: This script only targets Debian/Ubuntu. No changes made.' >&2
  exit 1
fi

if ! systemctl cat hysteria-server.service >/dev/null 2>&1; then
  echo 'ERROR: Install the official Hysteria2 service first: bash <(curl -fsSL https://get.hy2.sh/)' >&2
  exit 1
fi

SERVICE_USER="$(systemctl show hysteria-server.service -p User --value 2>/dev/null || true)"
SERVICE_USER="${SERVICE_USER:-root}"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  echo "ERROR: Hysteria2 service user '$SERVICE_USER' does not exist." >&2
  exit 1
fi
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"

# Do not silently replace a previous manually deployed production certificate.
if [[ -s /etc/hysteria/certs/fullchain.pem || -s /etc/hysteria/certs/privkey.pem ]]; then
  echo 'ERROR: Existing Hysteria2 certificate files detected. Back them up and review before running this first-time setup script.' >&2
  exit 1
fi

echo '=== AliDNS ACME certificate setup (does not change NPS/Nginx/ports) ==='
read -r -p 'Hostname for the certificate (e.g. node.example.com): ' DOMAIN
read -r -p 'ACME contact email: ' EMAIL
if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
  echo 'ERROR: Invalid hostname; wildcard names are not supported by this interactive script.' >&2
  exit 1
fi
if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo 'ERROR: Invalid email.' >&2
  exit 1
fi
read -r -p 'AliDNS RAM AccessKey ID: ' Ali_Key
read -r -s -p 'AliDNS RAM AccessKey Secret (hidden): ' Ali_Secret
printf '\n'
if [[ -z "$Ali_Key" || -z "$Ali_Secret" ]]; then
  echo 'ERROR: Both AliDNS AccessKey values are required.' >&2
  exit 1
fi
export Ali_Key Ali_Secret

echo '[1/4] Installing ACME dependencies (no system upgrade)...'
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl cron
systemctl enable --now cron

ACME=/root/.acme.sh/acme.sh
if [[ ! -x "$ACME" ]]; then
  echo '[2/4] Installing official acme.sh...'
  TEMP_INSTALLER="$(mktemp)"
  curl -fsSL https://get.acme.sh -o "$TEMP_INSTALLER"
  sh "$TEMP_INSTALLER" "email=$EMAIL"
else
  echo '[2/4] acme.sh is already installed; reusing it.'
fi
if [[ ! -x "$ACME" ]]; then
  echo 'ERROR: acme.sh executable not found at /root/.acme.sh/acme.sh.' >&2
  exit 1
fi
chmod 700 /root/.acme.sh
# The official installer creates a cron job. Cover pre-existing manual installations too.
if ! crontab -l 2>/dev/null | grep -Fq '/root/.acme.sh/acme.sh'; then
  { crontab -l 2>/dev/null || true; echo '19 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >/dev/null 2>&1'; } | crontab -
fi
"$ACME" --set-default-ca --server letsencrypt

echo '[3/4] Issuing ECDSA P-256 certificate via AliDNS DNS-01...'
"$ACME" --issue --dns dns_ali -d "$DOMAIN" --keylength ec-256 --server letsencrypt

CERT_DIR=/etc/hysteria/certs
# Ensure the service user can traverse the parent configuration directory.
chown "root:$SERVICE_GROUP" /etc/hysteria
chmod 750 /etc/hysteria
install -d -o root -g "$SERVICE_GROUP" -m 750 "$CERT_DIR"
for FILE in fullchain.pem privkey.pem; do
  if [[ ! -e "$CERT_DIR/$FILE" ]]; then
    install -o root -g "$SERVICE_GROUP" -m 640 /dev/null "$CERT_DIR/$FILE"
  else
    chown "root:$SERVICE_GROUP" "$CERT_DIR/$FILE"
    chmod 640 "$CERT_DIR/$FILE"
  fi
done

echo '[4/4] Registering production certificate deployment for automatic renewal...'
"$ACME" --install-cert -d "$DOMAIN" --ecc \
  --key-file "$CERT_DIR/privkey.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem"

if [[ ! -s "$CERT_DIR/fullchain.pem" || ! -s "$CERT_DIR/privkey.pem" ]]; then
  echo 'ERROR: Certificate files were not deployed.' >&2
  exit 1
fi
if ! runuser -u "$SERVICE_USER" -- test -r "$CERT_DIR/privkey.pem"; then
  echo "WARNING: Service user $SERVICE_USER cannot read the private key; check filesystem ACLs." >&2
  exit 1
fi

printf '\n=== Success: AliDNS ACME certificate installed ===\n'
openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject -dates -ext subjectAltName
printf '\nCertificate : %s/fullchain.pem\nPrivate key : %s/privkey.pem\nService user: %s\n' \
  "$CERT_DIR" "$CERT_DIR" "$SERVICE_USER"
printf '\nUse the following TLS block in /etc/hysteria/config.yaml:\n'
printf 'tls:\n  cert: %s/fullchain.pem\n  key: %s/privkey.pem\n  sniGuard: strict\n' "$CERT_DIR" "$CERT_DIR"
printf '\nacme.sh will check renewals via cron; Hysteria2 reads updated files on new TLS handshakes.\n'
printf 'Verify: crontab -l | grep acme.sh\n'
printf 'Security: acme.sh stores the AliDNS key for renewal under /root/.acme.sh. Protect this directory.\n'