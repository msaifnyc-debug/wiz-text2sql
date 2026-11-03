#!/usr/bin/env bash
# DETECTION for attack 01: show the anonymous reads of the public backup bucket
# as CloudTrail recorded them.
#
#   bash security/attack-simulation/detect_s3_exfiltration.sh [minutes-back]
#
# Why this script exists instead of a console link: CloudTrail *data* events are
# written only to the trail's S3 bucket. They never appear in console Event
# history, which shows management events only -- so after running attack 01 there
# is nothing to click. Reading them otherwise means standing up Athena.
#
# Delivery lag is 5-15 minutes. Run attack 01 first, then this a little later.
#
# What it proves: anonymous, unauthenticated GetObject IS captured, tagged
# accountId=anonymous with no ARN and with the caller's source IP.
set -euo pipefail

MINUTES="${1:-45}"
TRAIL_BUCKET="${TRAIL_BUCKET:-text2sql-cloudtrail-131166810866}"
ACCOUNT="${ACCOUNT:-131166810866}"
REGION="${REGION:-us-east-1}"
PREFIX="AWSLogs/${ACCOUNT}/CloudTrail/${REGION}/$(date -u +%Y/%m/%d)/"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "[*] Fetching CloudTrail logs from the last ${MINUTES} minutes..."

# Select by object LastModified rather than by the timestamp in the filename:
# a file named ...T1840Z... can carry events from several minutes either side,
# so filename globbing silently misses events near a window boundary.
CUTOFF=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$MINUTES")
KEYS=$(aws s3api list-objects-v2 --bucket "$TRAIL_BUCKET" --prefix "$PREFIX" \
  --query "Contents[?LastModified>=\`${CUTOFF}\`].Key" --output text 2>/dev/null | tr '\t' '\n')

if [ -z "${KEYS//[[:space:]]/}" ]; then
  echo "[!] No log files delivered in that window yet. CloudTrail batches every"
  echo "    5 minutes and delivery lags 5-15 minutes -- wait and re-run."
  exit 0
fi

COUNT=0
for k in $KEYS; do
  aws s3 cp "s3://${TRAIL_BUCKET}/${k}" "$WORK/$(basename "$k")" --quiet 2>/dev/null && COUNT=$((COUNT+1))
done
echo "[*] ${COUNT} log file(s) downloaded. Scanning for S3 data events..."
echo

# Each log file is a single JSON object, and most do not end in a newline, so
# `gunzip -c *.gz | read lines` concatenates two files into one unparseable
# line and silently finds nothing. Parse each file on its own.
python3 - "$WORK" <<'PY'
import glob, gzip, json, os, sys

rows = []
for path in glob.glob(os.path.join(sys.argv[1], "*.gz")):
    try:
        with gzip.open(path, "rt") as fh:
            doc = json.load(fh)
    except Exception:
        continue
    for r in doc.get("Records", []):
        if r.get("eventSource") != "s3.amazonaws.com":
            continue
        if r.get("eventName") not in ("GetObject", "HeadObject", "ListObjects", "ListObjectsV2"):
            continue
        ui = r.get("userIdentity") or {}
        acct = ui.get("accountId") or ui.get("type") or "?"
        who = (ui.get("arn") or "-").split("/")[-1]
        key = ((r.get("requestParameters") or {}).get("key") or "")
        rows.append((r["eventTime"], r.get("eventName"), acct, who,
                     r.get("sourceIPAddress", "-"), key.split("/")[-1]))

if not rows:
    print("    No S3 object reads in this window.")
    raise SystemExit

anon = [r for r in rows if r[2] == "anonymous"]
print(f"    {'TIME':<22} {'EVENT':<11} {'ACCOUNT':<14} {'WHO':<20} {'SOURCE IP':<16} OBJECT")
for t, name, acct, who, ip, key in sorted(set(rows)):
    mark = "  <== ANONYMOUS" if acct == "anonymous" else ""
    print(f"    {t:<22} {name:<11} {acct:<14} {who:<20} {ip:<16} {key}{mark}")

print()
if anon:
    print(f"[!] {len(anon)} anonymous read(s) recorded. accountId=anonymous, no ARN,")
    print("    because the caller presented no AWS credentials at all -- yet the")
    print("    read, the object and the source IP were all captured.")
else:
    print("[i] No anonymous reads in this window (only credentialed access).")
PY
