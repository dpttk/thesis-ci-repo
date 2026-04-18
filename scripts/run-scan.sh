#!/usr/bin/env bash
# Run the runc-fork binary with --security-scan against a prepared bundle
# (see prepare-bundle.sh) and collect artifacts into out/<name>/generated/.
#
# Usage: run-scan.sh bundles/<name>
#
# Uses env:
#   RUNC              - path to runc (default: runc on PATH)
#   OUT_ROOT          - out/ dir (default: <repo>/out)
#   SCAN_ID_PREFIX    - prefix for the container id (default: runcci)

set -euo pipefail

BUNDLE_DIR="${1:?bundle directory path required}"
BUNDLE_DIR="$(realpath "$BUNDLE_DIR")"
BUNDLE_NAME="$(basename "$BUNDLE_DIR")"
MANIFEST="$BUNDLE_DIR/bundle.yaml"

command -v yq >/dev/null 2>&1 || { echo "yq is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/out}"
OUT_DIR="$OUT_ROOT/$BUNDLE_NAME"
GEN_DIR="$OUT_DIR/generated"

[[ -d "$OUT_DIR" && -f "$OUT_DIR/config.json" ]] || {
  echo "bundle not prepared; run prepare-bundle.sh first" >&2
  exit 1
}

RUNC="${RUNC:-runc}"
command -v "$RUNC" >/dev/null 2>&1 || { echo "runc binary '$RUNC' not found" >&2; exit 1; }

if [[ "$EUID" -ne 0 ]]; then
  echo "run-scan.sh must run as root (security-scan requires OCI hooks + BCC)" >&2
  exit 1
fi

SEC_HOOK="$(yq -r '.scan.seccomp_hook // "auto"' "$MANIFEST")"
CAPABLE="$(yq -r '.scan.capable // "auto"' "$MANIFEST")"
DURATION="$(yq -r '.scan.duration_sec // 10' "$MANIFEST")"

SCAN_ID_PREFIX="${SCAN_ID_PREFIX:-runcci}"
CID="${SCAN_ID_PREFIX}-${BUNDLE_NAME}-$$"

mkdir -p "$GEN_DIR"
rm -f "$GEN_DIR"/* 2>/dev/null || true

flags=( "--security-scan" )
[[ "$SEC_HOOK" != "auto" && -n "$SEC_HOOK" ]] && flags+=( "--scan-seccomp-hook" "$SEC_HOOK" )
[[ "$CAPABLE"  != "auto" && -n "$CAPABLE"  ]] && flags+=( "--scan-capable"       "$CAPABLE"  )

echo "==> runc version"
"$RUNC" --version || true

echo "==> running '$RUNC run ${flags[*]} $CID' in $OUT_DIR (duration guard ${DURATION}s)"
pushd "$OUT_DIR" >/dev/null

set +e
timeout --signal=TERM --kill-after=10 "${DURATION}s" \
  "$RUNC" run "${flags[@]}" "$CID"
rc=$?
set -e
popd >/dev/null

# Any runc cleanup if it lingered
"$RUNC" list 2>/dev/null | awk -v id="$CID" '$1==id {print $1}' | while read -r stuck; do
  echo "==> cleaning up stuck container $stuck"
  "$RUNC" kill --all "$stuck" KILL 2>/dev/null || true
  "$RUNC" delete --force "$stuck" 2>/dev/null || true
done

# timeout exit codes: 124 (term), 137 (killed after) are expected for long workloads
case "$rc" in
  0|124|137) echo "==> runc exit=$rc (accepted)";;
  *) echo "==> runc exit=$rc (unexpected)"; exit "$rc";;
esac

ls -la "$GEN_DIR" || true
