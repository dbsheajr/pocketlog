#!/usr/bin/env bash
set -euo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "${RED}This installer must be run as root (use sudo).${NC}"
    exit 1
  fi
}

say() { echo "${GREEN}==>${NC} $*"; }
warn() { echo "${YELLOW}==> $*${NC}"; }

need_root

# 1) Apt packages
say "Refreshing apt cache..."
apt-get update -y

# If apt-manual.txt is in the current directory, install those packages; otherwise install a minimum set
APT_FILE="./apt-manual.txt"
if [[ -f "$APT_FILE" ]]; then
  say "Installing packages from ${APT_FILE} ..."
  # Install one-by-one; skip blanks/comments; warn and continue on failures
  while IFS= read -r pkg; do
    [[ -z "$pkg" || "$pkg" =~ ^[[:space:]]*# ]] && continue
    if ! apt-get install -y --no-install-recommends "$pkg"; then
      warn "Skipping unavailable package: $pkg"
    fi
  done < "$APT_FILE"
else
  warn "apt-manual.txt not found next to this script. Installing a minimal set of packages needed for PocketLog."
  apt-get install -y --no-install-recommends rsyslog python3-venv python3-pip awscli logrotate gzip jq gcc make tcpdump
fi

# 2) Create app directory and venv
APP_DIR="/opt/pocketlog"
say "Creating ${APP_DIR} ..."
mkdir -p "$APP_DIR"
chown root:root "$APP_DIR"
chmod 755 "$APP_DIR"

say "Creating Python virtual environment ..."
python3 -m venv "${APP_DIR}/.venv"
source "${APP_DIR}/.venv/bin/activate"

# 3) Python requirements
if [[ -f "./requirements.txt" ]]; then
  say "Installing Python deps from requirements.txt ..."
  pip install --upgrade pip
  pip install -r "./requirements.txt"
else
  warn "requirements.txt not found. Installing minimal deps (boto3 only)."
  pip install --upgrade pip
  pip install boto3
fi

# 4) Install pocketlog.py and config
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SRC_DIR}/files/pocketlog.py" ]]; then
  say "Installing pocketlog.py ..."
  install -m 0755 "${SRC_DIR}/files/pocketlog.py" "${APP_DIR}/pocketlog.py"
else
  echo "${RED}ERROR: ${SRC_DIR}/files/pocketlog.py missing.${NC}"; exit 2
fi

install -d -m 0755 /etc/pocketlog
if [[ -f "${SRC_DIR}/files/pocketlog.conf" ]]; then
  say "Installing /etc/pocketlog/pocketlog.conf ..."
  install -m 0644 "${SRC_DIR}/files/pocketlog.conf" "/etc/pocketlog/pocketlog.conf"
else
  warn "No pocketlog.conf provided; creating a default."
  cat >/etc/pocketlog/pocketlog.conf <<'EOF'
# PocketLog settings
S3_BUCKET="your-bucket-name"
S3_PREFIX="pocketlog"
LOG_ROOT="/var/log/pocketlog"
DELETE_AFTER_UPLOAD="true"
EOF
fi

# 5) rsyslog configuration (backup originals, then install)
say "Configuring rsyslog ..."
RSYSLOG_BACKUP_DIR="/etc/rsyslog.backup.$(date +%Y%m%d%H%M%S)"
install -d -m 0755 "$RSYSLOG_BACKUP_DIR"
cp -a /etc/rsyslog.conf "$RSYSLOG_BACKUP_DIR/"
cp -a /etc/rsyslog.d "$RSYSLOG_BACKUP_DIR/" || true

# Install our baseline config
if [[ -f "${SRC_DIR}/files/rsyslog.conf" ]]; then
  install -m 0644 "${SRC_DIR}/files/rsyslog.conf" /etc/rsyslog.conf
fi

install -d -m 0755 /etc/rsyslog.d
for f in 02-maxmsgsize.conf 10-network-inputs.conf 50-default.conf; do
  if [[ -f "${SRC_DIR}/files/rsyslog.d/${f}" ]]; then
    install -m 0644 "${SRC_DIR}/files/rsyslog.d/${f}" "/etc/rsyslog.d/${f}"
  fi
done

# Log root directory
LOG_ROOT="$(grep '^LOG_ROOT=' /etc/pocketlog/pocketlog.conf | cut -d= -f2 | tr -d '"' || true)"
[[ -z "$LOG_ROOT" ]] && LOG_ROOT="/var/log/pocketlog"
install -d -m 0755 "$LOG_ROOT"
chown syslog:adm "$LOG_ROOT" || true

# 6) logrotate (hourly rotation)
say "Installing logrotate policy for hourly rotation ..."
install -d -m 0755 /etc/logrotate.hourly
if [[ -f "${SRC_DIR}/files/logrotate.d/pocketlog" ]]; then
  install -m 0644 "${SRC_DIR}/files/logrotate.d/pocketlog" /etc/logrotate.d/pocketlog
else
  cat >/etc/logrotate.d/pocketlog <<EOF
${LOG_ROOT}/**/*.log {
    rotate 24
    hourly
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    dateext
    dateformat -%Y%m%d%H
}
EOF
fi

# Ensure hourly cron job for logrotate exists
if [[ ! -f /etc/cron.hourly/logrotate ]]; then
  cat >/etc/cron.hourly/logrotate <<'EOF'
#!/usr/bin/env bash
/usr/sbin/logrotate /etc/logrotate.conf
EOF
  chmod +x /etc/cron.hourly/logrotate
fi

# 7) systemd unit for uploader + timer
say "Installing systemd units ..."
install -m 0644 "${SRC_DIR}/files/pocketlog-upload.service" /etc/systemd/system/pocketlog-upload.service
install -m 0644 "${SRC_DIR}/files/pocketlog-upload.timer"    /etc/systemd/system/pocketlog-upload.timer

systemctl daemon-reload
systemctl enable rsyslog
systemctl restart rsyslog

systemctl enable pocketlog-upload.timer
systemctl start pocketlog-upload.timer

say "Done. Next steps:"
echo "  1) Run: ${BOLD}aws configure${NC} (or set env vars AWS_ACCESS_KEY_ID/SECRET/REGION)"
echo "  2) Edit /etc/pocketlog/pocketlog.conf with your bucket/prefix and log root (if needed)."
echo "  3) Check uploader logs: journalctl -u pocketlog-upload -n 100 --no-pager"
echo "  4) Send some test syslog to this host (UDP/TCP 514) and verify files land in ${LOG_ROOT} and then S3."
