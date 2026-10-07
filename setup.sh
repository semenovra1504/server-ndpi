#!/bin/bash
set -Eeuo pipefail

NDPI_DIR="/opt/nDPI"
MONITOR_SCRIPT="/usr/local/bin/ndpi-bittorrent-monitor.sh"
SERVICE_FILE="/etc/systemd/system/ndpi-bittorrent.service"
ALERT_SCRIPT="/root/ndpi-telegram-alert.sh"
LOG_DIR="/var/log/ndpi"
LOG_FILE="${LOG_DIR}/bittorrent.log"
STATE_DIR="/var/lib/ndpi-alert"
CRON_LINE="*/5 * * * * ${ALERT_SCRIPT} >/dev/null 2>&1"

log() {
  echo "[nDPI setup] $*"
}

fail() {
  echo "[nDPI setup] ERROR: $*" >&2
  exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
  fail "Run this script as root, for example: curl -fsSL https://raw.githubusercontent.com/semenovra1504/server-ndpi/main/setup.sh | sudo bash"
fi

if ! command -v apt-get >/dev/null 2>&1; then
  fail "This installer expects Ubuntu/Debian with apt."
fi

# BOT_TOKEN/CHAT_ID can be supplied as environment variables. Otherwise ask via /dev/tty,
# which also works when the installer itself is piped into bash via curl.
if [[ -z "${BOT_TOKEN:-}" ]]; then
  [[ -r /dev/tty ]] || fail "BOT_TOKEN is not set and /dev/tty is unavailable."
  read -r -s -p "Telegram BOT_TOKEN: " BOT_TOKEN </dev/tty
  echo >/dev/tty
fi

if [[ -z "${CHAT_ID:-}" ]]; then
  [[ -r /dev/tty ]] || fail "CHAT_ID is not set and /dev/tty is unavailable."
  read -r -p "Telegram CHAT_ID (for example -1001234567890): " CHAT_ID </dev/tty
fi

[[ -n "${BOT_TOKEN}" ]] || fail "BOT_TOKEN cannot be empty."
[[ -n "${CHAT_ID}" ]] || fail "CHAT_ID cannot be empty."

log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  build-essential git gettext flex bison libtool \
  autoconf automake pkg-config libpcap-dev \
  libjson-c-dev libnuma-dev libpcre2-dev \
  libmaxminddb-dev librrd-dev \
  curl ca-certificates cron

log "Installing/building nDPI..."
if [[ -x "${NDPI_DIR}/example/ndpiReader" ]]; then
  log "nDPI is already built at ${NDPI_DIR}; skipping rebuild."
else
  if [[ -e "${NDPI_DIR}" ]]; then
    log "Removing incomplete ${NDPI_DIR}..."
    rm -rf "${NDPI_DIR}"
  fi

  git clone --depth 1 https://github.com/ntop/nDPI.git "${NDPI_DIR}"
  cd "${NDPI_DIR}"
  ./autogen.sh
  ./configure
  make -j"$(nproc)"
fi

[[ -x "${NDPI_DIR}/example/ndpiReader" ]] || fail "ndpiReader was not built successfully."

ROUTE_INFO="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n 1 || true)"
IFACE="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"${ROUTE_INFO}")"
SERVER_IP="$(awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' <<<"${ROUTE_INFO}")"

[[ -n "${IFACE}" ]] || fail "Could not detect the outbound network interface."
[[ -n "${SERVER_IP}" ]] || fail "Could not detect the server IPv4 address."

log "Detected interface: ${IFACE}, IPv4: ${SERVER_IP}"

log "Creating BitTorrent log..."
mkdir -p "${LOG_DIR}" "${STATE_DIR}"
touch "${LOG_FILE}"
chmod 700 "${LOG_DIR}" "${STATE_DIR}"
chmod 600 "${LOG_FILE}"

log "Creating nDPI monitor script..."
cat > "${MONITOR_SCRIPT}" <<'MONITOR_EOF'
#!/bin/bash
set -o pipefail

IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
  for(i=1;i<=NF;i++)
    if($i=="dev") {
      print $(i+1)
      exit
    }
}')

IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
  for(i=1;i<=NF;i++)
    if($i=="src") {
      print $(i+1)
      exit
    }
}')

if [ -z "$IFACE" ] || [ -z "$IP" ]; then
  echo "Could not detect outbound interface/IP" >&2
  exit 1
fi

mkdir -p /var/log/ndpi
touch /var/log/ndpi/bittorrent.log

stdbuf -oL /opt/nDPI/example/ndpiReader \
  -i "$IFACE" \
  -f "src host $IP and (tcp or udp)" \
  -R 2>&1 |
stdbuf -oL grep --line-buffered -i 'BitTorrent' \
  >> /var/log/ndpi/bittorrent.log
MONITOR_EOF
chmod 755 "${MONITOR_SCRIPT}"

log "Creating systemd service..."
cat > "${SERVICE_FILE}" <<'SERVICE_EOF'
[Unit]
Description=nDPI BitTorrent Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ndpi-bittorrent-monitor.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

log "Creating Telegram alert script..."
{
  echo '#!/bin/bash'
  echo 'set -u'
  printf 'BOT_TOKEN=%q\n' "${BOT_TOKEN}"
  printf 'CHAT_ID=%q\n' "${CHAT_ID}"
  cat <<'ALERT_EOF'

LOG_FILE="/var/log/ndpi/bittorrent.log"
STATE_DIR="/var/lib/ndpi-alert"
STATE_FILE="$STATE_DIR/last_line"

mkdir -p "$STATE_DIR"
[ -f "$LOG_FILE" ] || exit 0

CURRENT_LINES=$(wc -l < "$LOG_FILE")

if [ -f "$STATE_FILE" ]; then
  LAST_LINE=$(cat "$STATE_FILE")
else
  LAST_LINE=0
fi

case "$LAST_LINE" in
  ''|*[!0-9]*) LAST_LINE=0 ;;
esac

if [ "$CURRENT_LINES" -lt "$LAST_LINE" ]; then
  LAST_LINE=0
fi

if [ "$CURRENT_LINES" -le "$LAST_LINE" ]; then
  exit 0
fi

NEW_COUNT=$((CURRENT_LINES - LAST_LINE))
NEW_LOGS=$(tail -n +"$((LAST_LINE + 1))" "$LOG_FILE" | tail -n 20 | tail -c 3000)

SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
  for(i=1;i<=NF;i++)
    if($i=="src") {
      print $(i+1)
      exit
    }
}')

if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi

MESSAGE="⚠️ BitTorrent detected

Server: $SERVER_IP
New events: $NEW_COUNT

$NEW_LOGS"

if curl -fsS \
  --connect-timeout 10 \
  --max-time 20 \
  -X POST \
  "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text=${MESSAGE}" \
  >/dev/null; then
  echo "$CURRENT_LINES" > "$STATE_FILE"
else
  echo "Failed to send nDPI alert to Telegram" >&2
  exit 1
fi
ALERT_EOF
} > "${ALERT_SCRIPT}"
chmod 700 "${ALERT_SCRIPT}"

log "Installing cron job without touching unrelated cron entries..."
TMP_CRON="$(mktemp)"
{
  crontab -l 2>/dev/null | grep -Fv "${ALERT_SCRIPT}" || true
  echo "${CRON_LINE}"
} > "${TMP_CRON}"
crontab "${TMP_CRON}"
rm -f "${TMP_CRON}"

systemctl enable --now cron >/dev/null 2>&1 || true

log "Enabling nDPI monitor service..."
systemctl daemon-reload
systemctl enable ndpi-bittorrent >/dev/null
systemctl restart ndpi-bittorrent

if ! systemctl is-active --quiet ndpi-bittorrent; then
  systemctl --no-pager --full status ndpi-bittorrent || true
  fail "ndpi-bittorrent.service did not start."
fi

log "Checking Telegram bot configuration..."
INSTALL_MESSAGE="✅ nDPI monitor installed

Server: ${SERVER_IP}
Interface: ${IFACE}
BitTorrent log: ${LOG_FILE}
Alert check: every 5 minutes"

if curl -fsS \
  --connect-timeout 10 \
  --max-time 20 \
  -X POST \
  "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text=${INSTALL_MESSAGE}" \
  >/dev/null; then
  log "Telegram test message sent successfully."
else
  echo "[nDPI setup] WARNING: nDPI is installed, but the Telegram test message failed. Check BOT_TOKEN/CHAT_ID." >&2
fi

log "Done."
echo
echo "Service:    systemctl status ndpi-bittorrent"
echo "BT log:     tail -f ${LOG_FILE}"
echo "Cron:       crontab -l"
echo "Alert test: ${ALERT_SCRIPT}"
echo
echo "The monitor is passive: it does not add iptables/nftables rules and does not block traffic."
