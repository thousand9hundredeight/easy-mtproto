#!/usr/bin/env bash
# =============================================================================
#  install-mtproto.sh — MTProto Fake TLS (Docker) + nginx stream
#  Tested on: Debian 12 / Ubuntu 22.04+
#  Usage: bash install-mtproto.sh
#
#  Architecture:
#    :443  -> nginx (ssl_preread) -> MTProto Desktop  :7788 (ya.ru)
#                                 -> MTProto Mobile   :7789 (www.ozon.ru)
#                                 -> Fallback HTML    :8080
# =============================================================================

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run this script as root"

# =============================================================================
# SETTINGS — edit these before running
# =============================================================================

# SNI domains for Fake TLS.
# Must be real, accessible HTTPS domains reachable from your server.
# Telegram Desktop uses MTPROTO_SNI_DESKTOP, Telegram Mobile uses MTPROTO_SNI_MOBILE.
# Change if ya.ru / ozon.ru are blocked or slow from your server.
MTPROTO_SNI_DESKTOP="ya.ru"
MTPROTO_SNI_MOBILE="www.ozon.ru"

# Internal ports the mtg containers listen on (127.0.0.1 only, not exposed publicly).
# Change if these ports are already used by another service on this server.
MTPROTO_PORT_DESKTOP=7788
MTPROTO_PORT_MOBILE=7789

# Public port nginx listens on for incoming MTProto connections.
# WARNING: if another service (Apache, Caddy, another nginx block) already
# occupies port 443 — either stop it first, or change PUBLIC_PORT (e.g. 8443).
PUBLIC_PORT=443

# Internal port for the nginx fallback HTTP page (not reachable from outside).
# Change if 8080 is already occupied by another service on this server.
FALLBACK_PORT=8080

# File where connection links and secrets are saved after installation.
CREDS_FILE="/root/mtproto-credentials.txt"

# =============================================================================
# END OF SETTINGS
# =============================================================================

echo ""
echo "============================================================"
echo "        MTProto Fake TLS (Docker) + nginx -- install"
echo "============================================================"
echo ""

# --- 0. Clean previous installation ---
info "Cleaning previous MTProto installation..."

docker stop mtproto-desktop 2>/dev/null || true
docker rm   mtproto-desktop 2>/dev/null || true
docker stop mtproto-mobile  2>/dev/null || true
docker rm   mtproto-mobile  2>/dev/null || true

# Remove only OUR nginx configs -- other configs are left untouched
rm -f /etc/nginx/stream.d/mtproto.conf
rm -f /etc/nginx/sites-enabled/mtproto-fallback
rm -f /etc/nginx/sites-available/mtproto-fallback
sed -i '\|include /etc/nginx/stream.d/mtproto.conf;|d' /etc/nginx/nginx.conf 2>/dev/null || true

success "Cleanup done"

# --- 1. Dependencies ---
info "Installing dependencies..."
apt-get update -qq

for pkg in curl wget nginx ufw tmux; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        apt-get install -y -qq "$pkg" || warn "Could not install $pkg -- continuing"
    fi
done

if ! command -v docker &>/dev/null; then
    apt-get install -y -qq docker.io || die "Could not install Docker"
fi
systemctl enable --now docker

success "Dependencies installed"

# --- 2. MTProto Desktop ---
info "Starting MTProto Desktop container (SNI: ${MTPROTO_SNI_DESKTOP})..."

MTPROTO_SECRET_DESKTOP=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$MTPROTO_SNI_DESKTOP")

docker run -d \
  --name mtproto-desktop \
  --restart unless-stopped \
  -p "127.0.0.1:${MTPROTO_PORT_DESKTOP}:${MTPROTO_PORT_DESKTOP}" \
  nineseconds/mtg:2 \
  simple-run -n 1.1.1.1 -i prefer-ipv4 \
  "0.0.0.0:${MTPROTO_PORT_DESKTOP}" \
  "$MTPROTO_SECRET_DESKTOP"

sleep 3
if ! docker ps --filter "name=mtproto-desktop" --filter "status=running" | grep -q mtproto-desktop; then
    docker logs mtproto-desktop 2>&1 | tail -20
    die "mtproto-desktop container failed to start. See logs above."
fi
success "MTProto Desktop started (port ${MTPROTO_PORT_DESKTOP})"

# --- 3. MTProto Mobile ---
info "Starting MTProto Mobile container (SNI: ${MTPROTO_SNI_MOBILE})..."

MTPROTO_SECRET_MOBILE=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$MTPROTO_SNI_MOBILE")

docker run -d \
  --name mtproto-mobile \
  --restart unless-stopped \
  -p "127.0.0.1:${MTPROTO_PORT_MOBILE}:${MTPROTO_PORT_MOBILE}" \
  nineseconds/mtg:2 \
  simple-run -n 1.1.1.1 -i prefer-ipv4 \
  "0.0.0.0:${MTPROTO_PORT_MOBILE}" \
  "$MTPROTO_SECRET_MOBILE"

sleep 3
if ! docker ps --filter "name=mtproto-mobile" --filter "status=running" | grep -q mtproto-mobile; then
    docker logs mtproto-mobile 2>&1 | tail -20
    die "mtproto-mobile container failed to start. See logs above."
fi
success "MTProto Mobile started (port ${MTPROTO_PORT_MOBILE})"

# --- 4. Nginx fallback page ---
info "Creating fallback HTML page..."
mkdir -p /var/www/mtproto-fallback
cat > /var/www/mtproto-fallback/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Welcome</title></head>
<body style="font-family:sans-serif;text-align:center;padding:60px">
  <h1>Welcome</h1><p>Nothing to see here.</p>
</body>
</html>
HTMLEOF

# --- 5. Nginx config ---
info "Configuring nginx..."

# Disable default site only if it exists -- other sites are not touched
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Internal fallback HTTP server (127.0.0.1 only, never exposed publicly)
cat > /etc/nginx/sites-available/mtproto-fallback << FBEOF
server {
    listen 127.0.0.1:${FALLBACK_PORT};
    root /var/www/mtproto-fallback;
    index index.html;
    server_name _;
    location / { try_files \$uri \$uri/ =404; }
}
FBEOF
ln -sf /etc/nginx/sites-available/mtproto-fallback /etc/nginx/sites-enabled/mtproto-fallback

# Stream block in a separate file -- does not conflict with existing HTTP/HTTPS nginx configs
mkdir -p /etc/nginx/stream.d
cat > /etc/nginx/stream.d/mtproto.conf << STREAMEOF
stream {
    log_format mtproto_proxy '\$remote_addr [\$time_local] sni=\$ssl_preread_server_name bytes=\$bytes_sent/\$bytes_received';
    access_log /var/log/nginx/mtproto-stream.log mtproto_proxy;

    map \$ssl_preread_server_name \$mtproto_backend {
        ${MTPROTO_SNI_DESKTOP}      mtproto_desktop;
        www.${MTPROTO_SNI_DESKTOP}  mtproto_desktop;
        ${MTPROTO_SNI_MOBILE}       mtproto_mobile;
        default                     mtproto_fallback;
    }

    upstream mtproto_desktop  { server 127.0.0.1:${MTPROTO_PORT_DESKTOP}; }
    upstream mtproto_mobile   { server 127.0.0.1:${MTPROTO_PORT_MOBILE}; }
    upstream mtproto_fallback { server 127.0.0.1:${FALLBACK_PORT}; }

    server {
        listen ${PUBLIC_PORT} reuseport;
        proxy_pass \$mtproto_backend;
        ssl_preread on;
        proxy_connect_timeout 5s;
        proxy_timeout 3600s;
    }
}
STREAMEOF

# Add our include line to nginx.conf only if not already present
grep -qxF 'include /etc/nginx/stream.d/mtproto.conf;' /etc/nginx/nginx.conf || \
  echo 'include /etc/nginx/stream.d/mtproto.conf;' >> /etc/nginx/nginx.conf

nginx -t || die "nginx config test failed. Run: nginx -t"

if systemctl is-active --quiet nginx; then
    systemctl reload nginx
else
    systemctl start nginx
fi
systemctl enable nginx

sleep 1
if ! ss -tlnp | grep -q ":${PUBLIC_PORT}"; then
    die "nginx is not listening on port ${PUBLIC_PORT}."
fi
success "nginx configured and running"

# --- 6. UFW ---
info "Configuring firewall..."

# NOTE: This script only opens SSH and PUBLIC_PORT.
# If you have other services on this server (VLESS, WireGuard, custom ports)
# add their rules below BEFORE the 'ufw --force enable' line.
# Otherwise those ports will be blocked after enabling UFW.
#
# Uncomment and adjust as needed:
#   ufw allow 2443/tcp    # VLESS Reality
#   ufw allow 51820/udp   # WireGuard
#   ufw allow 3000/tcp    # Any other service

ufw allow ssh
ufw allow "${PUBLIC_PORT}/tcp"

ufw --force enable

success "Firewall configured (open: SSH, ${PUBLIC_PORT}/tcp)"
warn "If other VPN/proxy services are running on this server --"
warn "verify their ports are still open:  ufw status numbered"
warn "To open a port:  ufw allow <port>/<proto>  &&  ufw reload"

# --- 7. Final output ---
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || \
            curl -s --connect-timeout 5 api.ipify.org 2>/dev/null || \
            hostname -I | awk '{print $1}')

MTPROTO_DESKTOP_LINK="tg://proxy?server=${SERVER_IP}&port=${PUBLIC_PORT}&secret=${MTPROTO_SECRET_DESKTOP}"
MTPROTO_MOBILE_LINK="tg://proxy?server=${SERVER_IP}&port=${PUBLIC_PORT}&secret=${MTPROTO_SECRET_MOBILE}"

echo ""
echo "============================================================"
echo -e "${GREEN}   Installation complete!${NC}"
echo "============================================================"
echo ""
echo -e "${CYAN}=== MTProto Desktop (SNI: ${MTPROTO_SNI_DESKTOP}) ===${NC}"
echo "  Link: $MTPROTO_DESKTOP_LINK"
echo ""
echo -e "${CYAN}=== MTProto Mobile (SNI: ${MTPROTO_SNI_MOBILE}) ===${NC}"
echo "  Link: $MTPROTO_MOBILE_LINK"
echo ""
echo -e "${CYAN}=== Service status ===${NC}"
echo -n "  nginx:           "; systemctl is-active nginx            2>/dev/null || echo "?"
echo -n "  mtproto-desktop: "; docker ps --filter "name=mtproto-desktop" --format "{{.Status}}" 2>/dev/null || echo "?"
echo -n "  mtproto-mobile:  "; docker ps --filter "name=mtproto-mobile"  --format "{{.Status}}" 2>/dev/null || echo "?"
echo -n "  port ${PUBLIC_PORT}:          "; ss -tlnp | grep -q ":${PUBLIC_PORT}" && echo "OPEN" || echo "CLOSED"
echo ""
echo -e "${CYAN}=== Traffic flow ===${NC}"
echo "  :${PUBLIC_PORT} -> nginx (ssl_preread)"
echo "         |-- SNI = ${MTPROTO_SNI_DESKTOP}     -> MTProto Desktop  (:${MTPROTO_PORT_DESKTOP})"
echo "         |-- SNI = ${MTPROTO_SNI_MOBILE} -> MTProto Mobile   (:${MTPROTO_PORT_MOBILE})"
echo "         \-- default            -> Fallback HTML    (:${FALLBACK_PORT})"
echo ""

cat > "$CREDS_FILE" << CREDSEOF
=== MTProto Credentials -- $(date) ===

SERVER IP:   $SERVER_IP
PUBLIC PORT: $PUBLIC_PORT

--- MTProto Desktop (SNI: ${MTPROTO_SNI_DESKTOP}) ---
Secret: $MTPROTO_SECRET_DESKTOP
Link:   $MTPROTO_DESKTOP_LINK

--- MTProto Mobile (SNI: ${MTPROTO_SNI_MOBILE}) ---
Secret: $MTPROTO_SECRET_MOBILE
Link:   $MTPROTO_MOBILE_LINK
CREDSEOF
chmod 600 "$CREDS_FILE"

echo -e "  Credentials saved to: ${YELLOW}$CREDS_FILE${NC}"
echo ""
