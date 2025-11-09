#!/usr/bin/env bash
# install_pocketlog.sh — PocketLog bootstrap for Raspberry Pi OS (Debian Trixie)
# - rsyslog writes ONE combined file per hour: /var/log/pocketlog/YYYY-MM-DD-HH.log
# - Each line: _time=<rfc3339> host=<sender-ip> msg='<raw payload exactly as received>'
# - A tiny hourly compressor gzips previous-hour files; pocketlog.py uploads .log.gz to S3
# - Installs systemd timer to run uploader every 15 minutes

set -euo pipefail

say()  { printf "\n==> %s\n", "$*"; }
warn() { printf "\n[WARN] %s\n", "$*" >&2; }
die()  { printf "\n[ERROR] %s\n", "$*" >&2; exit 1; }

# Must be root
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  die "Run as root (use sudo)."
fi

# Resolve repo dir (script location), and an optional ./files/ directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
REPO_FILES_DIR="${SCRIPT_DIR}/files"

APP_DIR="/opt/pocketlog"
VENV_DIR="${APP_DIR}/.venv"
LOG_DIR="/var/log/pocketlog"
CONF_DIR="/etc/pocketlog"
CONF_FILE="${CONF_DIR}/pocketlog.conf"

say "Refreshing apt cache..."
apt-get update -y

say "Installing base packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  rsyslog python3-venv python3-pip \
  awscli logrotate gzip jq tcpdump git ca-certificates

say "Creating log and config directories..."
install -d -m 0755 "${LOG_DIR}"
install -d -m 0755 "${CONF_DIR}"
install -d -m 0755 /etc/rsyslog.d

# Helper: copy first match (repo root wins, else ./files, else not found)
copy_first() {
  # $1: relative path in repo (e.g., rsyslog.conf or rsyslog.d/01-remote-hourly.conf)
  # $2: destination absolute path
  local rel="$1" dest="$2"
  if [[ -f "${REPO_ROOT}/${rel}" ]]; then
    say "Installing ${rel} from repo root -> ${dest}"
    install -D -m 0644 "${REPO_ROOT}/${rel}" "${dest}"
    return 0
  elif [[ -f "${REPO_FILES_DIR}/${rel}" ]]; then
    say "Installing ${rel} from files/ -> ${dest}"
    install -D -m 0644 "${REPO_FILES_DIR}/${rel}" "${dest}"
    return 0
  fi
  return 1
}

# -----------------------------
# R S Y S L O G   D R O P - I N S
# -----------------------------
write_file() {
  local dest="$1" owner="${2:-root}" mode="${3:-0644}"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  install -d -m 0755 "$(dirname "$dest")"
  if [[ -f "$dest" ]] && ! cmp -s "$tmp" "$dest"; then
    cp -a "$dest" "${dest}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  install -o "$owner" -g "$owner" -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

say "Installing rsyslog drop-ins…"

# Choose a single port and use it consistently
PORT="${PORT:-514}"

# 00-load-inputs.conf — explicitly load UDP/TCP modules
write_file "/etc/rsyslog.d/00-load-inputs.conf" root 0644 <<'RSY'
module(load="imudp")
module(load="imtcp")
RSY

# 01-remote-hourly.conf — templates + ruleset writing one combined file per hour
write_file "/etc/rsyslog.d/01-remote-hourly.conf" root 0644 <<'RSY'
# One combined file per hour: /var/log/pocketlog/YYYY-MM-DD-HH.log
template(name="HourlyCombinedPath" type="string"
         string="/var/log/pocketlog/%$year%-%$month%-%$day%-%$hour%.log")

# RAW payload wrapped in msg='...'; keep it exactly as received (trim trailing LF)
template(name="kv_line_raw" type="string"
         string="_time=%timegenerated:::date-rfc3339% host=%fromhost-ip% msg='%msg:::drop-last-lf%'\n")

# Writer ruleset used by UDP/TCP inputs
ruleset(name="remote_raw") {
  action(type="omfile"
         dynaFile="HourlyCombinedPath"
         template="kv_line_raw"
         createDirs="on" dirCreateMode="0755" FileCreateMode="0644")
}
RSY

# 10-network-inputs.conf — bind UDP/TCP to the ruleset above
write_file "/etc/rsyslog.d/10-network-inputs.conf" root 0644 <<RSY
# Bind inbound listeners to the remote_raw ruleset
input(type="imudp" port="${PORT}" ruleset="remote_raw")
input(type="imtcp" port="${PORT}" ruleset="remote_raw")
RSY

# 02-maxmsgsize.conf — allow larger messages (legacy directive avoids dupes)
write_file "/etc/rsyslog.d/02-maxmsgsize.conf" root 0644 <<'RSY'
# Increase message ceiling. For large JSON, configure senders to use TCP.
$MaxMessageSize 256k
RSY

# 50-default.conf — drop true LOCAL logs (we only want remote inputs here)
write_file "/etc/rsyslog.d/50-default.conf" root 0644 <<'RSY'
# Drop true LOCAL logs in the main ruleset; network inputs use remote_raw above
if ($inputname == "imuxsock" or $inputname == "imklog" or
    (($fromhost-ip == "127.0.0.1" or $fromhost-ip == "::1") and
     $inputname != "imudp" and $inputname != "imtcp")) then stop
RSY

say "Validating rsyslog configuration…"
rsyslogd -N1

say "Restarting rsyslog…"
systemctl restart rsyslog
systemctl enable rsyslog >/dev/null 2>&1 || true


# -----------------------------
# H O U R L Y   C O M P R E S S O R
# -----------------------------
say "Installing PocketLog hourly compressor…"
cat >/usr/local/sbin/pocketlog-hourly-rotate <<'SH'
#!/bin/bash
set -euo pipefail
LOGDIR="/var/log/pocketlog"
now="$(date +%Y-%m-%d-%H)"
shopt -s nullglob
for f in "${LOGDIR}"/*.log; do
  base="$(basename "$f")"
  # Only gzip files like 2025-10-28-13.log, not the current hour, not other logs
  if [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}\.log$ ]] && [[ "$base" != "${now}.log" ]]; then
    gzip -n -- "$f" || true
  fi
done
SH
chmod +x /usr/local/sbin/pocketlog-hourly-rotate

# Hourly trigger via cron (systemd-logrotate is daily on Pi OS)
cat >/etc/cron.hourly/pocketlog-rotate <<'SH'
#!/bin/sh
/usr/local/sbin/pocketlog-hourly-rotate
SH
chmod +x /etc/cron.hourly/pocketlog-rotate

# Ensure no conflicting logrotate rule remains
rm -f /etc/logrotate.d/pocketlog || true

# -----------------------------
# A P P   +   V E N V
# -----------------------------
say "Laying down PocketLog app and Python venv…"
install -d -m 0755 "${APP_DIR}"
install -d -m 0755 "${APP_DIR}/bin"

# pocketlog.py
if [[ -f "${REPO_ROOT}/pocketlog.py" ]]; then
  install -m 0755 "${REPO_ROOT}/pocketlog.py" "${APP_DIR}/pocketlog.py"
elif [[ -f "${REPO_FILES_DIR}/pocketlog.py" ]]; then
  install -m 0755 "${REPO_FILES_DIR}/pocketlog.py" "${APP_DIR}/pocketlog.py"
else
  warn "pocketlog.py not found; dropping a no-op placeholder."
  cat >"${APP_DIR}/pocketlog.py" <<'PY'
#!/usr/bin/env python3
print("Uploaded 0 file(s).")
PY
  chmod 0755 "${APP_DIR}/pocketlog.py"
fi

# venv + deps
python3 -m venv "${VENV_DIR}"
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip >/dev/null
if [[ -f "${REPO_ROOT}/requirements.txt" ]]; then
  pip install -r "${REPO_ROOT}/requirements.txt"
elif [[ -f "${REPO_FILES_DIR}/requirements.txt" ]]; then
  pip install -r "${REPO_FILES_DIR}/requirements.txt"
else
  pip install boto3
fi
deactivate

# -----------------------------
# A P P   C O N F I G
# -----------------------------
say "Writing /etc/pocketlog/pocketlog.conf (edit S3 bucket/prefix)…"
if [[ ! -f "${CONF_FILE}" ]]; then
  cat >"${CONF_FILE}" <<'CONF'
# PocketLog uploader configuration
S3_BUCKET="PUT-YOUR-BUCKET-NAME-HERE"
S3_PREFIX="pocketlog"
LOG_ROOT="/var/log/pocketlog"
DELETE_AFTER_UPLOAD="true"
MIN_AGE_SEC="120"
CONF
else
  warn "Config exists; leaving ${CONF_FILE} unchanged."
fi

# -----------------------------
# S Y S T E M D   U N I T S
# -----------------------------
say "Installing systemd service + timer for uploader (every 15 minutes)…"
cat >/etc/systemd/system/pocketlog-upload.service <<EOF
[Unit]
Description=PocketLog S3 uploader
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${VENV_DIR}/bin/python ${APP_DIR}/pocketlog.py
WorkingDirectory=${APP_DIR}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
Restart=no
StandardOutput=append:${LOG_DIR}/pocketlog_uploader.log
StandardError=append:${LOG_DIR}/pocketlog_uploader.log

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/pocketlog-upload.timer <<'EOF'
[Unit]
Description=Run PocketLog uploader every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true
Unit=pocketlog-upload.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now pocketlog-upload.timer

# -----------------------------
# S A N I T Y   C H E C K S
# -----------------------------
say "Validating rsyslog again and starting…"
rsyslogd -N1 || die "rsyslog validation failed after install."
systemctl restart rsyslog
sleep 1

say "Verifying listeners on 514…"
if ! ss -luntp | egrep ':514 ' >/dev/null; then
  warn "Did not see 514 listeners—check rsyslog status: systemctl status rsyslog --no-pager"
fi

cat <<'NEXT'

Done!

Next steps:
  1) Provide AWS creds for root (service runs as root):
       sudo -H aws configure
  2) Set your S3 bucket/prefix:
       sudo nano /etc/pocketlog/pocketlog.conf
  3) Send a test and confirm current-hour file appears:
       IP=$(hostname -I | awk '{print $1}')
       logger -n "$IP" -P 514 -t pltest "hello PocketLog"
       sudo tail -n 3 /var/log/pocketlog/$(date +%Y-%m-%d-%H).log
  4) Wait for the hour to roll (or force once):
       sudo /usr/local/sbin/pocketlog-hourly-rotate
       ls -l /var/log/pocketlog | grep -E '\.log\.gz$' || echo "No gz yet"
  5) Trigger an upload run now:
       sudo systemctl start pocketlog-upload.service
       sudo tail -n 100 /var/log/pocketlog/pocketlog_uploader.log

Format on disk (per line):
  _time=<RFC3339> host=<sender-ip> msg='<raw payload exactly as received>'

Uploads (by pocketlog.py):
  s3://<bucket>/<prefix>/YYYY/MM/DD/YYYY-MM-DD-HH.log.gz
NEXT
