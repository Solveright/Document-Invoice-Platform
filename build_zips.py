"""Deterministic Lambda package builder.

Each function is a single-file handler (app.py) that relies on the Lambda
runtime's bundled boto3, so each zip contains exactly one entry: app.py at the
archive root, with forward-slash paths and a fixed timestamp so rebuilds are
reproducible and don't churn source_code_hash.
"""
import sys
import zipfile
from pathlib import Path

ROOT = Path(sys.argv[1])
FIXED = (2020, 1, 1, 0, 0, 0)

TARGETS = {
    "backend/api_lambda.zip": "backend/api_lambda/app.py",
    "backend/consumer_lambda.zip": "backend/consumer_lambda/app.py",
}

for zip_rel, src_rel in TARGETS.items():
    src = ROOT / src_rel
    dst = ROOT / zip_rel
    data = src.read_bytes()
    info = zipfile.ZipInfo("app.py", date_time=FIXED)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    with zipfile.ZipFile(dst, "w") as zf:
        zf.writestr(info, data)
    print(f"{zip_rel}: 1 entry, {len(data)} bytes from {src_rel}")
