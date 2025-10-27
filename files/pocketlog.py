#!/usr/bin/env bash
set -euo pipefail

say()  { printf "\n==> %s\n" "$*"; }
warn() { printf "\n[WARN] %s\n" "$*" >&2; }
die()  { printf "\n[ERROR] %s\n" "$*" >&2; exit 1; }

# Must be root
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "This installer must be run as root (use sudo)."

# Directory layout
APP_DIR="/opt/pocketlog"
VENV_DIR="${APP_DIR}/.venv"
LOG_DIR="/var/log/pocketlog"
CONF_DIR="/etc/pocketlog"
CONF_FILE="${CONF_DIR}/pocketlog.conf"

# Where the script is running (repo checkout)
SRC_DIR="$(pwd)"

say "Refreshing apt cache..."
apt-get update -y

say "Installing base packages (rsyslog, parser module, Python, log tools, AWS CLI, git)..."
# rsyslog-mmjsonparse package name may vary by distro; try both
apt-get install -y \
  rsyslog rsyslog-mmjsonparse || true
apt-get install -y \
  python3-venv python3-pip \
  awscli logrotate gzip jq tcpdump git ca-certificates

# If mmjsonparse didn't come via rsyslog-mmjsonparse, try rsyslog-mod-mmjsonparse
if ! grep -qi mmjsonparse /usr/share/doc/rsyslog*/changelog* 2>/dev/null && \
   ! ls /usr/lib/rsyslog/mmjsonparse.* >/dev/null 2>&1; then
  apt-get install -y rsyslog-mod-mmjsonparse || true
fi

say "Creating log and config directories..."
install -d -m 0755 "${LOG_DIR}"
install -d -m 0755 "${CONF_DIR}"

# -------------------------------------------------------------------
# R S Y S L O G   C O N F I G
# One combined file per hour, using kv_line_* templates
# -------------------------------------------------------------------
say "Writing rsyslog ruleset for hourly combined file..."
tee /etc/rsyslog.d/01-remote-hourly.conf >/dev/null <<'RSY'
# /etc/rsyslog.d/01-remote-hourly.conf
# One combined file per hour, using kv_line_* templates.
# Files live in /var/log/pocketlog/YYYY-MM-DD-HH.log

module(load="mmjsonparse")  # safe to load multiple times; rsyslog dedups

template(name="HourlyCombinedPath" type="string"
         string="/var/log/pocketlog/%$year%-%$month%-%$day%-%$hour%.log")

# If body is JSON, capture it verbatim into msg='...'
template(name="kv_line_json" type="string"
         string="_time=%timegenerated:::date-rfc3339% host=%fromhost-ip% msg='%$!all-json%'\n")

# Otherwise, write trimmed raw message into msg='...'
template(name="kv_line_raw" type="string"
         string="_time=%timegenerated:::date-rfc3339% host=%fromhost-ip% msg='%msg:2:$:drop-last-lf%'\n")

# Ruleset for network inputs
ruleset(name="remote_raw") {
  action(type="mmjsonparse" cookie="")

  if ($parsesuccess == "OK") then {
    action(type="omfile"
           dynaFile="HourlyCombinedPath"
           template="kv_line_json"
           createDirs="on"
           dirCreateMode="0755"
           FileCreateMode="0644")
  } else {
    action(type="omfile"
           dynaFile="HourlyCombinedPath"
           template="kv_line_raw"
           createDirs="on"
           dirCreateMode="0755"
           FileCreateMode="0644")
  }
}
RSY

say "Binding UDP/TCP inputs to remote_raw ruleset..."
tee /etc/rsyslog.d/10-network-inputs.conf >/dev/null <<'RSY'
# /etc/rsyslog.d/10-network-inputs.conf
# Listeners for inbound syslog -> remote_raw ruleset
input(type="imudp" port="514" ruleset="remote_raw")
input(type="imtcp" port="514" ruleset="remote_raw")
RSY

say "Slimming 50-default.conf to only drop true local logs in main ruleset..."
tee /etc/rsyslog.d/50-default.conf >/dev/null <<'RSY'
# /etc/rsyslog.d/50-default.conf
# Drop true local logs in main ruleset; network inputs use remote_raw
if ($inputname == "imuxsock" or $inputname == "imklog" or
    (($fromhost-ip == "127.0.0.1" or $fromhost-ip == "::1") and
     $inputname != "imudp" and $inputname != "imtcp")) then stop
RSY

say "Validating rsyslog configuration..."
rsyslogd -N1 || die "rsyslog config validation failed"

say "Restarting rsyslog..."
systemctl restart rsyslog
systemctl enable rsyslog >/dev/null 2>&1 || true

# -------------------------------------------------------------------
# L O G R O T A T E
# Compress previous hours; current hour remains .log (uncompressed)
# -------------------------------------------------------------------
say "Installing hourly logrotate policy for /var/log/pocketlog/*.log..."
tee /etc/logrotate.d/pocketlog >/dev/null <<'LR'
/var/log/pocketlog/*.log {
    hourly
    rotate 168               # keep 7 days of hours; adjust as needed
    missingok
    notifempty
    compress
    delaycompress            # don't compress the newest hour file
    nocreate
    sharedscripts
    postrotate
        /bin/systemctl kill -s HUP rsyslog >/dev/null 2>&1 || true
    endscript
}
LR

# -------------------------------------------------------------------
# A P P   +   V E N V
# -------------------------------------------------------------------
say "Laying down PocketLog app directory and venv..."
install -d -m 0755 "${APP_DIR}"
install -d -m 0755 "${APP_DIR}/bin"

# Copy pocketlog.py if present in the current directory (repo checkout)
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

# -------------------------------------------------------------------
# A P P   C O N F I G
# -------------------------------------------------------------------
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

# -------------------------------------------------------------------
# S Y S T E M D   S E R V I C E / T I M E R
# -------------------------------------------------------------------
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
# The script reads ${CONF_FILE} on its own; no EnvironmentFile needed
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

# -------------------------------------------------------------------
# O P E N   P O R T S   (optional if UFW is used)
# -------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q "Status: active"; then
    say "Opening 514/udp and 514/tcp in UFW..."
    ufw allow 514/udp >/dev/null 2>&1 || true
    ufw allow 514/tcp >/dev/null 2>&1 || true
  fi
fi

# -------------------------------------------------------------------
# S U M M A R Y
# -------------------------------------------------------------------
say "Validating listeners..."
ss -luntp | egrep ':514 ' || warn "Did not see 514 listeners—check rsyslog status."

say "Kick the uploader once (it will upload previous hours if present)..."
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
     (Or drop IAM credentials in /root/.aws/credentials)

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

All set. New hours will write to /var/log/pocketlog/YYYY-MM-DD-HH.log,
get compressed by logrotate, and uploaded every ~15 minutes to:
  s3://<bucket>/<prefix>/YYYY/MM/DD/YYYY-MM-DD-HH.log.gz
NEXT
