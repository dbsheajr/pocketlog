#!/usr/bin/env bash
# install_pocketlog.sh — PocketLog bootstrap for Raspberry Pi OS (Debian Trixie)
# - rsyslog writes ONE combined file per hour: /var/log/pocketlog/YYYY-MM-DD-HH.log
# - Each line: _time=<rfc3339> host=<sender-ip> msg='<raw payload exactly as received>'
# - logrotate compresses hourly; pocketlog.py uploads to S3
set -euo pipefail

say()  { printf "\n==> %s\n" "$*"; }
warn() { printf "\n[WARN] %s\n" "$*" >&2; }
die()  { printf "\n[ERROR] %s\n" "$*" >&2; exit 1; }

# Must be root
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (use sudo)."

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
apt-get install -y \
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
# R S Y S L O G   C O N F I G
# -----------------------------
say "Installing rsyslog configuration (repo files preferred, with safe defaults)…"

# 1) /etc/rsyslog.conf (minimal base that includes drop-ins)
if ! copy_first "rsyslog.conf" "/etc/rsyslog.conf"; then
  say "Writing default /etc/rsyslog.conf"
  cat >/etc/rsyslog.conf <<'RSYS'
# Minimal rsyslog.conf for PocketLog (Pi OS / Debian)
module(load="imuxsock")  # local syslog via /dev/log
module(load="imklog")    # kernel messages (Linux)

# Include drop-ins
include(file="/etc/rsyslog.d/*.conf" mode="optional")

# (Optional) keep standard local log files
*.emerg                         :omusrmsg:*
auth,authpriv.*                 /var/log/auth.log
*.*;auth,authpriv.none          -/var/log/syslog
daemon.*                        -/var/log/daemon.log
kern.*                          -/var/log/kern.log
lpr.*                           -/var/log/lpr.log
mail.*                          -/var/log/mail.log
user.*                          -/var/log/user.log
RSYS
fi

# 2) /etc/rsyslog.d/00-load-inputs.conf (explicitly load UDP/TCP inputs)
if ! copy_first "rsyslog.d/00-load-inputs.conf" "/etc/rsyslog.d/00-load-inputs.conf"; then
  say "Writing default /etc/rsyslog.d/00-load-inputs.conf"
  cat >/etc/rsyslog.d/00-load-inputs.conf <<'RSY'
module(load="imudp")
module(load="imtcp")
RSY
fi

# 3) /etc/rsyslog.d/01-remote-hourly.conf (one hourly file; raw wrapper line format)
if ! copy_first "rsyslog.d/01-remote-hourly.conf" "/etc/rsyslog.d/01-remote-hourly.conf"; then
  say "Writing default /etc/rsyslog.d/01-remote-hourly.conf"
  cat >/etc/rsyslog.d/01-remote-hourly.conf <<'RSY'
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
fi

# 4) /etc/rsyslog.d/10-network-inputs.conf (bind inputs to ruleset)
if ! copy_first "rsyslog.d/10-network-inputs.conf" "/etc/rsyslog.d/10-network-inputs.conf"; then
  say "Writing default /etc/rsyslog.d/10-network-inputs.conf"
  cat >/etc/rsyslog.d/10-network-inputs.conf <<'RSY'
# Bind inbound listeners to the remote_raw ruleset
input(type="imudp" port="514" ruleset="remote_raw")
input(type="imtcp" port="514" ruleset="remote_raw")
RSY
fi

# 5) /etc/rsyslog.d/02-maxmsgsize.conf (use legacy directive to avoid parameter dupes)
if ! copy_first "rsyslog.d/02-maxmsgsize.conf" "/etc/rsyslog.d/02-maxmsgsize.conf"; then
  say "Writing default /etc/rsyslog.d/02-maxmsgsize.conf"
  cat >/etc/rsyslog.d/02-maxmsgsize.conf <<'RSY'
# Increase message ceiling. For large JSON, configure senders to use TCP.
$MaxMessageSize 256k
RSY
fi

# 6) /etc/rsyslog.d/50-default.conf (drop true local logs only)
if ! copy_first "rsyslog.d/50-default.conf" "/etc/rsyslog.d/50-default.conf"; then
  say "Writing default /etc/rsyslog.d/50-default.conf"
  cat >/etc/rsyslog.d/50-default.conf <<'RSY'
# Drop true LOCAL logs in main ruleset; network inputs use remote_raw
if ($inputname == "imuxsock" or $inputname == "imklog" or
    (($fromhost-ip == "127.0.0.1" or $fromhost-ip == "::1") and
     $inputname != "imudp" and $inputname != "imtcp")) then stop
RSY
fi

say "Validating rsyslog configuration..."
rsyslogd -N1 || die "rsyslog config validation failed."

say "Restarting rsyslog..."
systemctl restart rsyslog
systemctl enable rsyslog >/dev/null 2>&1 || true

# -----------------------------
# L O G R O T A T E
# -----------------------------
say "Ensuring hourly logrotate policy for /var/log/pocketlog/*.log..."
if [[ -f "${REPO_ROOT}/logrotate.d/pocketlog" ]]; then
  install -D -m 0644 "${REPO_ROOT}/logrotate.d/pocketlog" "/etc/logrotate.d/pocketlog"
elif [[ -f "${REPO_FILES_DIR}/logrotate.d/pocketlog" ]]; then
  install -D -m 0644 "${REPO_FILES_DIR}/logrotate.d/pocketlog" "/etc/logrotate.d/pocketlog"
else
  cat >/etc/logrotate.d/pocketlog <<'LR'
/var/log/pocketlog/*.log {
    hourly
    rotate 168
    missingok
    notifempty
    compress
    delaycompress
    nocreate
    sharedscripts
    postrotate
        /bin/systemctl kill -s HUP rsyslog >/dev/null 2>&1 || true
    endscript
}
LR
fi

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
import time, pathlib
log = pathlib.Path("/var/log/pocketlog/pocketlog_uploader.log")
log.parent.mkdir(parents=True, exist_ok=True)
log.write_text(time.strftime("%Y-%m-%d %H:%M:%S ") + "INFO placeholder uploader ran, nothing to do.\n")
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
ss -luntp | egrep ':514 ' || warn "Did not see 514 listeners—check rsyslog status."

say "Kick uploader once (if real pocketlog.py present, it will upload previous hour)…"
if systemctl start pocketlog-upload.service 2>/dev/null; then
  sleep 1
  tail -n 50 "${LOG_DIR}/pocketlog_uploader.log" || true
fi

cat <<'NEXT'

Done!

Next:
  1) Provide AWS creds for root (service runs as root):
       sudo -H aws configure
  2) Set your S3 bucket/prefix:
       sudo nano /etc/pocketlog/pocketlog.conf
  3) Send a test and check current-hour file:
       IP=$(hostname -I | awk '{print $1}')
       logger -n "$IP" -P 514 -t pltest "hello from PocketLog"
       sudo tail -n 5 /var/log/pocketlog/$(date +%Y-%m-%d-%H).log
  4) Force rotate & upload (optional for test):
       sudo logrotate -f /etc/logrotate.d/pocketlog
       sudo systemctl start pocketlog-upload.service
       sudo tail -n 50 /var/log/pocketlog/pocketlog_uploader.log

Format on disk (per line):
  _time=<RFC3339> host=<sender-ip> msg='<raw payload exactly as received>'

Uploads (by pocketlog.py):
  s3://<bucket>/<prefix>/YYYY/MM/DD/YYYY-MM-DD-HH.log.gz
NEXT
