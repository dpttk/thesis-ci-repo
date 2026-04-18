#!/usr/bin/env bash
# Download the runc binary artifact published by runc-fork's
# publish-runc-binary.yml for a given commit sha, verify SHA256SUMS, and
# expose it on $PATH for subsequent workflow steps.
#
# Required env:
#   RUNC_REF    - commit sha (artifact is named runc-$RUNC_REF)
#   RUNC_REPO   - <owner>/<repo> of runc-fork
#   GH_TOKEN    - PAT with actions:read on RUNC_REPO
#
# Optional env:
#   RUNC_RUN_ID - specific runc-fork workflow run id to download from.
#                 When empty the latest successful run of
#                 publish-runc-binary.yml for RUNC_REF is resolved via API.
#   BIN_DIR     - destination dir (default: $PWD/bin)

set -euo pipefail

: "${RUNC_REF:?RUNC_REF (commit sha) is required}"
: "${RUNC_REPO:?RUNC_REPO=<owner>/<repo> is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

BIN_DIR="${BIN_DIR:-$PWD/bin}"
RUNC_RUN_ID="${RUNC_RUN_ID:-}"
ARTIFACT_NAME="runc-${RUNC_REF}"

mkdir -p "$BIN_DIR"
rm -f "$BIN_DIR/runc" "$BIN_DIR/SHA256SUMS" "$BIN_DIR/BUILD_INFO.txt"

command -v gh >/dev/null 2>&1 || {
  echo "gh CLI is required" >&2
  exit 1
}

if [[ -z "$RUNC_RUN_ID" ]]; then
  echo "Resolving latest successful publish-runc-binary run for sha=$RUNC_REF in $RUNC_REPO..."
  RUNC_RUN_ID="$(
    gh api \
      "repos/${RUNC_REPO}/actions/workflows/publish-runc-binary.yml/runs?head_sha=${RUNC_REF}&status=success&per_page=1" \
      --jq '.workflow_runs[0].id // empty'
  )"
  if [[ -z "$RUNC_RUN_ID" ]]; then
    echo "No successful publish-runc-binary run found for $RUNC_REF in $RUNC_REPO" >&2
    exit 2
  fi
fi

echo "Downloading artifact $ARTIFACT_NAME from run_id=$RUNC_RUN_ID ($RUNC_REPO)..."
gh run download "$RUNC_RUN_ID" \
  --repo "$RUNC_REPO" \
  --name "$ARTIFACT_NAME" \
  --dir "$BIN_DIR"

if [[ ! -f "$BIN_DIR/runc" || ! -f "$BIN_DIR/SHA256SUMS" ]]; then
  echo "Artifact layout unexpected; missing runc or SHA256SUMS in $BIN_DIR" >&2
  ls -la "$BIN_DIR" >&2 || true
  exit 3
fi

chmod +x "$BIN_DIR/runc"

echo "Verifying SHA256SUMS..."
( cd "$BIN_DIR" && sha256sum -c SHA256SUMS )

echo "runc version:"
"$BIN_DIR/runc" --version || true

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$BIN_DIR" >> "$GITHUB_PATH"
fi

echo "runc binary installed: $BIN_DIR/runc"
