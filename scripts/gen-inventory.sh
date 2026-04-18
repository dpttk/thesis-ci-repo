#!/usr/bin/env bash
# Generate ansible/inventory.ini from terraform outputs.
#
# Usage: gen-inventory.sh [terraform_dir]
#
# Expects `terraform output -json` to work in terraform_dir (init + apply done).
# Run this manually on your workstation after `terraform apply` - this project
# does not wire Terraform into GitHub Actions.

set -euo pipefail

TF_DIR="${1:-terraform}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$REPO_ROOT/ansible/inventory.ini.tpl"
OUT="$REPO_ROOT/ansible/inventory.ini"

[[ -f "$TPL" ]] || { echo "missing template: $TPL" >&2; exit 1; }

out_json="$(cd "$REPO_ROOT/$TF_DIR" && terraform output -json)"

runner_ip="$(echo "$out_json" | jq -r '.runner_public_ip.value')"
bucket="$(   echo "$out_json" | jq -r '.artifacts_bucket.value')"

[[ "$runner_ip" == "null" || -z "$runner_ip" ]] && { echo "no runner_public_ip output" >&2; exit 2; }

sed \
  -e "s|@@RUNNER_IP@@|$runner_ip|g" \
  -e "s|@@ARTIFACTS_BUCKET@@|$bucket|g" \
  "$TPL" > "$OUT"

echo "wrote $OUT"
cat "$OUT"
