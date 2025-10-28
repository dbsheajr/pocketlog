#!/usr/bin/env bash
# install_pocketlog.sh — PocketLog bootstrap for Raspberry Pi OS (Debian Trixie)
# Sets up rsyslog to write one combined file per hour, logrotate to compress,
# and a Python uploader that ships hourly files to S3.
# Safe to re-run (idempotent). Run with: sudo ./install_pocketlog.sh
set -euo pipefail

say()  { printf "\n==> %s\n" "$*"; }
warn() { printf "\n[WARN] %s\n" "$*" >&2; }
die()  { printf "\n[ERROR] %s\n" "$*" >&2; exit 1; }

# Root required
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "This installer must be run as root (use sudo)."

# Paths
APP_DIR="/opt/pocketlog"
VENV_DIR="${APP_DIR}/.venv"
LOG_DIR="/var/log/pocketlog"
CONF_DIR="/etc/pocketlog"
CONF_FILE="${CONF_DIR}/pocketlog.conf"
SRC_DIR="$(pwd)"

say "Refreshing apt cache..."
apt-get update -y

say "Installing base packages (rsyslog, Python, AWS CLI, log tools, git)..."
apt-get install -y \
  rsyslog python3-venv python3-pip \
  awscli logrotate gzip jq tcpdump git ca-certificates

say "Creating log and config directories..."
install -d -m 0755 "${LOG_DIR}"
install -d -m 0755 "${CONF_DIR}"

# -----------------------------
# R S Y S L O G   C O N F I G
# -----------------------------

# Increase parser limit for big JSON (TCP recommended for large messages)
say "Writing rsyslog global max message size..."
tee /etc/rsyslog.d/02-maxmsgsize.conf >/dev/null <<'RSY'
# Allow larger messages (adjust as needed). Use TCP on senders for big JSON.
global(processInternalMessages="on" maxMessageSize="256k")
RSY

# One combined file per hour; no external parsing modules required.
say "Writing rsyslog ruleset for hourly combined file..."
tee /etc/rsyslog.d/01-remote-hourly.conf >/dev/null <<'RSY'
# /etc/rsyslog.d/01-remote-hourly.conf
# One combined file per hour in /var/log/pocketlog/YYYY-MM-DD-HH.log

template(name="HourlyCombinedPath" type="string"
         string="/var/log/pocketlog/%$year%-%$month%-%$day%-%$hour%.log")

# Trimmed raw message into msg='...'
template(name="kv_line_raw" type="string"
         string="_time=%timegenerated:::date-rfc3339% host=%fromhost-ip% msg='%msg:2:$:drop-last-lf%'\n")

# Ruleset: write everything using kv_line_raw (keeps JSON bodies intact inside msg)
ruleset(name="remote_raw") {
  action(type="omfile"
         dynaFile="HourlyCombinedPath"
         template="kv_line_raw"
         createDirs="on" dirCreateMode="0755" FileCreateMode="0644")
}
RSY

# Bind UDP/TCP listeners to the ruleset
say "Binding UDP/TCP inputs to remote_raw ruleset..."
tee /etc/rsyslog.d/10-network-inputs.conf >/dev/null <<'RSY'
# /etc/rsyslog.d/10-network-inputs.conf
# Listeners for inbound syslog -> remote_raw ruleset
input(type="imudp" port="514" ruleset="remote_raw")
input(type="imtcp" port="514" ruleset="remote_raw")
RSY

# Slim default: only drop true local logs in the main ruleset (network inputs use remote_raw)
say "Slimming 50-default.conf (drop true local logs only)..."
tee /etc/rsyslog.d/50-default.conf >/dev/null <<'RSY'
# /etc/rsyslog.d/50-default.conf
# Drop true local logs in main ruleset; network inputs use remote_raw
if ($inputname == "imuxsock" or $inputname == "imklog" or
    (($fromhost-ip == "127.0.0.1" or $fromhost-ip == "::1") and
     $inputname != "imudp" and $inputname != "imtcp")) then stop
RSY

# Ensure includes are enabled in the base rsyslog.conf
if ! grep -q 'include(file="/etc/rsyslog.d/\*\.conf"' /etc/rsyslog.conf; then
  say "Adding include directive to /etc/rsyslog.conf..."
  echo 'include(file="/etc/rsyslog.d/*.conf" mode="optional")' >> /etc/rsyslog.conf
fi

say "Validating rsyslog configuration..."
rsyslogd -N1 || die "rsyslog config validation failed (see errors above)."

say "Restarting rsyslog..."
systemctl restart rsyslog
systemctl enable rsyslog >/dev/null 2>&1 || true

# -----------------------------
# L O G R O T A T E
# -----------------------------
say "Installing hourly logrotate policy for /var/log/pocketlog/*.log..."
tee /etc/logrotate.d/pocketlog >/dev/null <<'LR'
/var/log/pocketlog/*.log {
    hourly
    rotate 168               # keep ~7 days of hourly logs
    missingok
    notifempty
    compress
    delaycompress            # don't compress the newest hour
    nocreate
    sharedscripts
    postrotate
        /bin/systemctl kill -s HUP rsyslog >/dev/null 2>&1 || true
    endscript
}
LR

# -----------------------------
# A P P   +   V E N V
# -----------------------------
say "Laying down PocketLog app directory and Python venv..."
install -d -m 0755 "${APP_DIR}"
install -d -m 0755 "${APP_DIR}/bin"

# Copy pocketlog.py if present; otherwise, create a placeholder
if [[ -f "${SRC_DIR}/pocketlog.py" ]]; then
  install -m 0755 "${SRC_DIR}/pocketlog.py" "${APP_DIR}/pocketlog.py"
  say "Installed pocketlog.py from ${SRC_DIR}"
elif [[ ! -f "${APP_DIR}/pocketlog.py" ]]; then
  say "No pocketlog.py found in ${SRC_DIR}; creating a minimal placeholder."
  tee "${APP_DIR}/pocketlog.py" >/dev/null <<'PY'
#!/usr/bin/env python3
import sys, pathlib, time
log = pathlib.Path("/var/log/pocketlog/pocketlog_uploader.log")
log.parent.mkdir(parents=True, exist_ok=True)
with log.open("a") as f:
    f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + "INFO placeholder uploader ran, nothing to do.\n")
print("Uploaded 0 file(s).")
PY
  chmod 0755 "${APP_DIR}/pocketlog.py"
fi

# Python venv + deps
python3 -m venv "${VENV_DIR}"
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip >/dev/null
if [[ -f "${SRC_DIR}/requirements.txt" ]]; then
  say "Installing Python requirements from requirements.txt..."
  pip install -r "${SRC_DIR}/requirements.txt"
else
  say "Installing minimal Python deps (boto3)..."
  pip install boto3
fi
deactivate

# -----------------------------
# A P P   C O N F I G
# -----------------------------
say "Writing /etc/pocketlog/pocketlog.conf (edit to set your S3 bucket)..."
if [[ ! -f "${CONF_FILE}" ]]; then
  tee "${CONF_FILE}" >/dev/null <<'CONF'
# PocketLog uploader configuration
S3_BUCKET="PUT-YOUR-BUCKET-NAME-HERE"
S3_PREFIX="pocketlog"
LOG_ROOT="/var/log/pocketlog"
DELETE_AFTER_UPLOAD="true"
MIN_AGE_SEC="120"
CONF
else
  warn "Config ${CONF_FILE} already exists; leaving as-is."
fi

# -----------------------------
# S Y S T E M D   U N I T S
# -----------------------------
say "Installing systemd service + timer for uploader (every 15 minutes)..."
tee /etc/systemd/system/pocketlog-upload.service >/dev/null <<EOF
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

tee /etc/systemd/system/pocketlog-upload.timer >/dev/null <<'EOF'
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
# F I R E W A L L  (optional)
# -----------------------------
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q "Status: active"; then
    say "Opening 514/udp and 514/tcp in UFW..."
    ufw allow 514/udp >/dev/null 2>&1 || true
    ufw allow 514/tcp >/dev/null 2>&1 || true
  fi
fi

# -----------------------------
# S A N I T Y   C H E C K S
# -----------------------------
say "Validating rsyslog is up and listening on 514..."
rsyslogd -N1 || die "rsyslog config validation failed after changes."
systemctl restart rsyslog
sleep 1
ss -luntp | egrep ':514 ' || warn "Did not see 514 listeners—check rsyslog status."

say "Kicking the uploader once (it will upload previous hours if present)..."
if systemctl start pocketlog-upload.service 2>/dev/null; then
  sleep 1
  tail -n 50 "${LOG_DIR}/pocketlog_uploader.log" || true
else
  warn "pocketlog-upload.service did not start (this can be normal if pocketlog.py is a placeholder)."
fi

cat <<'NEXT'

Done!

Next steps:
  1) Provide AWS credentials for the root user (the systemd service runs as root):
       sudo -H aws configure
     (Or place credentials in /root/.aws/credentials)

  2) Edit your S3 bucket name:
       sudo nano /etc/pocketlog/pocketlog.conf
     Set S3_BUCKET="your-bucket" (S3_PREFIX defaults to "pocketlog").

  3) Send a syslog test and confirm the current-hour file:
       IP=$(hostname -I | awk '{print $1}')
       logger -n "$IP" -P 514 -t pltest "hello from PocketLog"
       sudo tail -n 5 /var/log/pocketlog/$(date +%Y-%m-%d-%H).log

  4) Force a rotation (optional for testing) then trigger the uploader:
       sudo logrotate -f /etc/logrotate.d/pocketlog
       sudo systemctl start pocketlog-upload.service
       sudo tail -n 50 /var/log/pocketlog/pocketlog_uploader.log

Hourly files are written to /var/log/pocketlog/YYYY-MM-DD-HH.log,
compressed by logrotate, and uploaded every ~15 minutes to:
  s3://<bucket>/<prefix>/YYYY/MM/DD/YYYY-MM-DD-HH.log.gz
NEXT
