#!/usr/bin/env bash
# Upload out/<bundle>/generated/ to Yandex Object Storage (S3-compatible) and
# emit a compact markdown scan-report.md for the GitHub Actions summary.
#
# Layout in bucket:
#   s3://$YC_ARTIFACTS_BUCKET/scans/<runc_ref>/<run_id>/<bundle>/...
#
# Env:
#   YC_ARTIFACTS_BUCKET       - bucket name
#   YC_STORAGE_ACCESS_KEY     - s3 access key
#   YC_STORAGE_SECRET_KEY     - s3 secret key
#   RUNC_REF                  - runc-fork commit sha (for the key prefix)
#   GITHUB_RUN_ID             - from GHA (for the key prefix); fallback "local"
#
# Requires `aws` CLI (installed by the base role).

set -euo pipefail

BUNDLE_NAME="${1:?bundle name required}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/out}"
GEN_DIR="$OUT_ROOT/$BUNDLE_NAME/generated"

[[ -d "$GEN_DIR" ]] || { echo "no generated/ dir for $BUNDLE_NAME" >&2; exit 1; }

: "${YC_ARTIFACTS_BUCKET:?YC_ARTIFACTS_BUCKET required}"
: "${YC_STORAGE_ACCESS_KEY:?YC_STORAGE_ACCESS_KEY required}"
: "${YC_STORAGE_SECRET_KEY:?YC_STORAGE_SECRET_KEY required}"

runc_ref="${RUNC_REF:-unknown}"
run_id="${GITHUB_RUN_ID:-local}"
prefix="s3://${YC_ARTIFACTS_BUCKET}/scans/${runc_ref}/${run_id}/${BUNDLE_NAME}"

export AWS_ACCESS_KEY_ID="$YC_STORAGE_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$YC_STORAGE_SECRET_KEY"
endpoint="https://storage.yandexcloud.net"

echo "==> uploading $GEN_DIR -> $prefix/"
aws --endpoint-url "$endpoint" s3 cp "$GEN_DIR" "$prefix/" --recursive --no-progress

# Also drop the (possibly scanner-updated) config.json next to the profiles.
if [[ -f "$OUT_ROOT/$BUNDLE_NAME/config.json" ]]; then
  aws --endpoint-url "$endpoint" s3 cp \
    "$OUT_ROOT/$BUNDLE_NAME/config.json" \
    "$prefix/config.json" --no-progress
fi

# scan-report.md — compact per-bundle summary for Job Summary.
report="$GEN_DIR/scan-report.md"
{
  echo "## scan-report: $BUNDLE_NAME"
  echo ""
  echo "- runc_ref: \`$runc_ref\`"
  echo "- run_id:   \`$run_id\`"
  echo "- bucket:   \`$prefix\`"
  echo ""
  if [[ -s "$GEN_DIR/seccomp.json" ]]; then
    count="$(jq '[.syscalls[]?.names[]?] | length' "$GEN_DIR/seccomp.json" 2>/dev/null || echo '?')"
    echo "- seccomp.json: **$count** syscalls"
  fi
  if [[ -f "$GEN_DIR/apparmor.profile" ]]; then
    lines="$(wc -l <"$GEN_DIR/apparmor.profile" | tr -d ' ')"
    echo "- apparmor.profile: $lines lines"
  fi
  if [[ -s "$GEN_DIR/capable-bpfcc.log" ]]; then
    caps="$(grep -hoE 'CAP_[A-Z_]+' "$GEN_DIR/capable-bpfcc.log" | sort -u | paste -sd ',' -)"
    echo "- capable-bpfcc caps: \`${caps:-<none>}\`"
  fi
} > "$report"

aws --endpoint-url "$endpoint" s3 cp "$report" "$prefix/scan-report.md" --no-progress
echo "==> report uploaded: $prefix/scan-report.md"
