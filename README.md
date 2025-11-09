# PocketLog Bootstrap (RPi)

Turn a fresh Raspberry Pi into a lightweight syslog receiver that rotates logs hourly and uploads compressed logs to Amazon S3.

## What it installs
- **rsyslog** (UDP/TCP 514)
- **Hourly log rotation & compression** (logrotate → `.gz` files)  
- **/opt/pocketlog** app with `pocketlog.py` (boto3 S3 uploader)  
- **systemd timer** runs the uploader every 15 minutes  
- **Site config** at `/etc/pocketlog/pocketlog.conf`

---

## Requirements
- Raspberry Pi OS (PiOS) **Server/Lite** (Debian “trixie” or newer recommended)
- Internet access to install packages and reach Amazon S3
- Open ports **514/udp** and/or **514/tcp** as needed on the Pi

---

## Quick start (HTTPS clone)
```bash
# On the Pi
sudo apt-get update -y && sudo apt-get install -y git

git clone https://github.com/dbsheajr/pocketlog.git
cd pocketlog

# Run the installer (uses apt-manual.txt if present; otherwise a minimal set)
chmod +x install_pocketlog.sh && sudo ./install_pocketlog.sh

# Provide AWS credentials (or set env vars instead)
sudo -H aws configure

# Optional: set bucket/prefix/log root
sudo nano /etc/pocketlog/pocketlog.conf
