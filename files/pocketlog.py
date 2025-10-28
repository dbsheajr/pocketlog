#!/usr/bin/env python3
"""
PocketLog uploader
- Uploads /var/log/pocketlog/YYYY-MM-DD-HH.log.gz to s3://<bucket>/<prefix>/YYYY/MM/DD/...
- Reads /etc/pocketlog/pocketlog.conf for settings.
- Skips current/very-recent files using MIN_AGE_SEC.
"""

import os
import re
import time
import logging
from pathlib import Path
from typing import Dict

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError
except Exception as e:
    raise SystemExit(f"ERROR: boto3 required in venv. Install with pip. ({e})")

CONF_PATH = Path("/etc/pocketlog/pocketlog.conf")
DEFAULTS = {
    "S3_BUCKET": "",
    "S3_PREFIX": "pocketlog",
    "LOG_ROOT": "/var/log/pocketlog",
    "DELETE_AFTER_UPLOAD": "true",
    "MIN_AGE_SEC": "120",
}

# Matches files like 2025-10-28-13.log.gz
HOURLY_GZ_RE = re.compile(r"^(?P<y>\d{4})-(?P<m>\d{2})-(?P<d>\d{2})-(?P<h>\d{2})\.log\.gz$")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

def load_conf(path: Path) -> Dict[str, str]:
    """Load simple KEY=VALUE (quoted or unquoted) config file."""
    conf = DEFAULTS.copy()
    if not path.exists():
        logging.warning("Config %s not found; using defaults. Set S3_BUCKET!", path)
        return conf

    for line in path.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if "=" not in s:
            continue
        k, v = s.split("=", 1)
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        conf[k] = v
    return conf

def to_bool(val: str) -> bool:
    return str(val).strip().lower() in {"1", "true", "yes", "y", "on"}

def find_ready_gz(log_root: Path, min_age_sec: int):
    """Yield (path, y, m, d) for .log.gz files older than min_age_sec and matching our pattern."""
    now = time.time()
    if not log_root.exists():
        return
    for p in log_root.iterdir():
        if not p.is_file():
            continue
        m = HOURLY_GZ_RE.match(p.name)
        if not m:
            continue
        try:
            age = now - p.stat().st_mtime
        except FileNotFoundError:
            continue
        if age < min_age_sec:
            continue
        yield p, m.group("y"), m.group("m"), m.group("d")

def s3_key(prefix: str, y: str, m: str, d: str, filename: str) -> str:
    prefix = prefix.strip().strip("/")
    if prefix:
        return f"{prefix}/{y}/{m}/{d}/{filename}"
    return f"{y}/{m}/{d}/{filename}"

def upload_file(s3, bucket: str, key: str, path: Path) -> None:
    extra = {"ContentType": "application/gzip", "ContentEncoding": "gzip"}
    s3.upload_file(str(path), bucket, key, ExtraArgs=extra)

def main() -> int:
    cfg = load_conf(CONF_PATH)
    bucket = cfg["S3_BUCKET"].strip()
    prefix = cfg["S3_PREFIX"]
    log_root = Path(cfg["LOG_ROOT"])
    delete_after = to_bool(cfg["DELETE_AFTER_UPLOAD"])
    try:
        min_age = int(cfg["MIN_AGE_SEC"])
    except ValueError:
        min_age = int(DEFAULTS["MIN_AGE_SEC"])

    if not bucket:
        logging.error("S3_BUCKET is empty in %s. Set it and retry.", CONF_PATH)
        return 1

    s3 = boto3.client("s3")
    uploaded = 0
    for gz_path, y, m, d in find_ready_gz(log_root, min_age):
        key = s3_key(prefix, y, m, d, gz_path.name)
        try:
            upload_file(s3, bucket, key, gz_path)
            logging.info("Uploaded %s to s3://%s/%s", gz_path, bucket, key)
            uploaded += 1
            if delete_after:
                try:
                    gz_path.unlink()
                    logging.info("Deleted local file %s", gz_path)
                except FileNotFoundError:
                    pass
        except (BotoCoreError, ClientError) as e:
            logging.error("Failed to upload %s -> s3://%s/%s: %s", gz_path, bucket, key, e)
        except Exception as e:
            logging.error("Unexpected error uploading %s: %s", gz_path, e)

    print(f"Uploaded {uploaded} file(s).")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
