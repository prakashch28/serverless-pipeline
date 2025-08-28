# src/ingest_lambda.py
# Python 3.11 — Generates (or accepts) NDJSON logs and writes them to S3.
# Safe for beginners: lots of try/except and clear prints.

import os
import json
import uuid
import random
from datetime import datetime, timezone

import boto3
from botocore.exceptions import BotoCoreError, ClientError

# Create S3 client once (cold start). If this fails, we still log an error.
try:
    s3 = boto3.client("s3")
except Exception as e:
    print(f"[FATAL] Could not create S3 client: {e}")
    s3 = None


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _sample_log(record_bytes: int = 0) -> dict:
    """Return a single synthetic log event. 'payload' adds size per record."""
    return {
        "event_id": str(uuid.uuid4()),
        "timestamp": _now_iso(),
        "service": random.choice(["auth", "orders", "payments", "catalog"]),
        "level": random.choice(["INFO", "WARN", "ERROR"]),
        "latency_ms": random.randint(5, 500),
        "message": random.choice([
            "User login successful",
            "Order created",
            "Payment authorized",
            "Inventory check complete",
            "Minor validation warning",
            "Upstream timeout"
        ]),
        # Padding to control record size (optional)
        "payload": ("X" * record_bytes) if record_bytes > 0 else None
    }


def _put_to_s3(bucket: str, key: str, body: bytes) -> bool:
    """Upload bytes to S3 with robust error handling."""
    if s3 is None:
        print("[ERROR] S3 client not initialized")
        return False
    try:
        s3.put_object(Bucket=bucket, Key=key, Body=body)
        return True
    except (ClientError, BotoCoreError) as e:
        print(f"[ERROR] put_object failed for s3://{bucket}/{key}: {e}")
        return False
    except Exception as e:
        print(f"[ERROR] Unexpected put_object error: {e}")
        return False


def handler(event, context):
    """
    Lambda entrypoint.

    Inputs (all optional):
      - event.sample_n (int): number of records to generate (overrides default)
      - event.record_bytes (int): padding per record (overrides env)
      - event.records (list[dict]): if provided, we write these instead of generating

    Env Vars:
      - RAW_BUCKET (required): S3 bucket for raw data
      - RAW_PREFIX (default 'raw/'): prefix/folder inside the bucket
      - LOG_SAMPLE_K (default '3'): default sample_n if not provided
      - RECORD_BYTES (default '0'): default padding per record (bytes)

    Output:
      { "ok": bool, "bucket": str, "key": str, "count": int } on success
    """
    # ---- Read environment configuration
    bucket = os.environ.get("RAW_BUCKET")
    prefix = os.environ.get("RAW_PREFIX", "raw/")
    default_n = int(os.environ.get("LOG_SAMPLE_K", "3"))
    default_record_bytes = int(os.environ.get("RECORD_BYTES", "0"))

    if not bucket:
        print("[ERROR] RAW_BUCKET env var missing")
        return {"ok": False, "reason": "missing RAW_BUCKET"}

    # ---- Read overrides from event (safe parsing)
    sample_n = default_n
    record_bytes = default_record_bytes

    try:
        if isinstance(event, dict) and "sample_n" in event:
            sample_n = int(event["sample_n"])
    except Exception as e:
        print(f"[WARN] invalid event.sample_n; using default {default_n}: {e}")
        sample_n = default_n

    try:
        if isinstance(event, dict) and "record_bytes" in event:
            record_bytes = int(event["record_bytes"])
    except Exception as e:
        print(f"[WARN] invalid event.record_bytes; using default {default_record_bytes}: {e}")
        record_bytes = default_record_bytes

    # ---- Determine S3 key (date-partitioned path)
    now = datetime.now(timezone.utc)
    part_path = now.strftime("%Y/%m/%d/%H/%M")
    key = f"{prefix}{part_path}/{uuid.uuid4()}.json"

    # ---- Build or accept records
    try:
        if isinstance(event, dict) and "records" in event:
            records = event["records"]
            if not isinstance(records, list):
                raise ValueError("'records' must be a list of dicts")
        else:
            records = [_sample_log(record_bytes) for _ in range(sample_n)]
    except Exception as e:
        print(f"[ERROR] bad input payload: {e}")
        return {"ok": False, "reason": "bad input"}

    # ---- Serialize to NDJSON
    try:
        ndjson = "\n".join(json.dumps(r) for r in records) + "\n"
        payload = ndjson.encode("utf-8")
    except Exception as e:
        print(f"[ERROR] serialization failed: {e}")
        return {"ok": False, "reason": "serialize"}

    # ---- Upload
    ok = _put_to_s3(bucket, key, payload)
    if not ok:
        return {"ok": False, "reason": "s3 put_object failed"}

    print(f"[INFO] wrote {len(records)} record(s) to s3://{bucket}/{key} "
          f"(record_bytes={record_bytes})")
    return {"ok": True, "bucket": bucket, "key": key, "count": len(records)}
