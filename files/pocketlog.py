#!/usr/bin/env python3
"""
PocketLog S3 uploader
- Picks up compressed logs (*.gz) under LOG_ROOT
- Uploads to s3://S3_BUCKET/S3_PREFIX/<hostname>/YYYY/MM/DD/<filename>
- On success, deletes file if DELETE_AFTER_UPLOAD=true
Requires AWS creds via `aws configure` or standard env/instance metadata.
"""
import os, sys, gzip, time, logging, socket, boto3, pathlib, datetime
from botocore.exceptions import BotoCoreError, ClientError

CONF_FILE = "/etc/pocketlog/pocketlog.conf"

def read_conf(path=CONF_FILE):
    conf = {"S3_BUCKET":"", "S3_PREFIX":"pocketlog", "LOG_ROOT":"/var/log/pocketlog", "DELETE_AFTER_UPLOAD":"true"}
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                line=line.strip()
                if not line or line.startswith("#"): continue
                if "=" in line:
                    k,v = line.split("=", 1)
                    conf[k.strip()] = v.strip().strip('"')
    return conf

def iter_gz_files(root):
    for p in pathlib.Path(root).rglob("*.gz"):
        if p.is_file():
            yield p

def s3_key(prefix, hostname, p: pathlib.Path):
    # key by date from mtime; fallback to today
    try:
        ts = datetime.datetime.fromtimestamp(p.stat().st_mtime)
    except Exception:
        ts = datetime.datetime.utcnow()
    return f"{prefix}/{hostname}/{ts:%Y/%m/%d}/{p.name}"

def main():
    conf = read_conf()
    bucket = conf.get("S3_BUCKET")
    prefix = conf.get("S3_PREFIX", "pocketlog").strip("/")
    log_root = conf.get("LOG_ROOT", "/var/log/pocketlog")
    delete_after = conf.get("DELETE_AFTER_UPLOAD","true").lower() in ("1","true","yes","y")

    if not bucket:
        print("S3_BUCKET is not set in /etc/pocketlog/pocketlog.conf", file=sys.stderr)
        return 2

    # logging
    os.makedirs("/var/log/pocketlog", exist_ok=True)
    logging.basicConfig(filename="/var/log/pocketlog/pocketlog_uploader.log",
                        level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")

    hostname = socket.gethostname()
    s3 = boto3.client("s3")

    count = 0
    for path in iter_gz_files(log_root):
        key = s3_key(prefix, hostname, path)
        try:
            s3.upload_file(str(path), bucket, key)
            logging.info("Uploaded %s to s3://%s/%s", path, bucket, key)
            count += 1
            if delete_after:
                try:
                    path.unlink()
                    logging.info("Deleted local file %s", path)
                except Exception as e:
                    logging.warning("Failed to delete %s: %s", path, e)
        except (BotoCoreError, ClientError) as e:
            logging.error("Failed to upload %s: %s", path, e)
    print(f"Uploaded {count} file(s).")
    return 0

if __name__ == "__main__":
    sys.exit(main())
