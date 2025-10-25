# PocketLog Bootstrap (RPi)

Turn a fresh Raspberry Pi into a lightweight syslog receiver that
rotates logs hourly and uploads compressed logs to Amazon S3.

## What it installs
- rsyslog (UDP/TCP 514), JSONL output by host/app
- hourly log rotation and compression
- `/opt/pocketlog` app with `pocketlog.py` uploader (boto3)
- systemd timer runs uploader every 15 minutes
- site config at `/etc/pocketlog/pocketlog.conf`

## Quick start
```bash
# On the Pi
sudo apt-get update -y
sudo apt-get install -y git

git clone https://github.com/<your-username>/pocketlog-bootstrap.git
cd pocketlog-bootstrap

# (Optional) edit apt-manual.txt and requirements.txt to your taste

# Install
sudo ./install_pocketlog.sh

# Provide AWS credentials (or use env vars)
aws configure

# Set your bucket/prefix if needed
sudo nano /etc/pocketlog/pocketlog.conf
