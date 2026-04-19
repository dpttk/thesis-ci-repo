#!/usr/bin/env bash
# Run the runc-fork binary with --security-scan against a prepared bundle
# (see prepare-bundle.sh). Detached mode: runc is started in background,
# an optional probe_script (bundle.yaml: .scan.probe_script) runs against
# the live workload, and then a graceful SIGTERM is delivered to let the
# scanner finalize seccomp/apparmor/capabilities profiles.
#
# Usage: run-scan.sh bundles/<name>
#
# Uses env:
#   RUNC              - path to runc (default: runc on PATH)
#   OUT_ROOT          - out/ dir (default: <repo>/out)
#   SCAN_ID_PREFIX    - prefix for the container id (default: runcci)
#
# Bundle manifest keys consumed (bundle.yaml):
#   scan.seccomp_hook            - "auto" | path (forwarded as --scan-seccomp-hook)
#   scan.capable                 - "auto" | path (forwarded as --scan-capable)
#   scan.duration_sec            - upper fuse / no-probe run time (default: 10)
#   scan.probe_script            - path (relative to bundle dir) to a probe
#                                  script run while runc is alive (optional)
#   scan.probe_ready_timeout_sec - passed to the probe as READY_TIMEOUT
#                                  (default: 30)
#   scan.grace_term_sec          - seconds to wait after TERM before KILL
#                                  (default: 10)
#
# Probe script env contract:
#   OUT_DIR, GEN_DIR, BUNDLE_DIR, READY_TIMEOUT, CID, RUNC_PID
#   Its exit code becomes the exit code of run-scan.sh when runc itself
#   exits with an accepted code (0/124/137/143).

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
PROBE_REL="$(yq -r '.scan.probe_script // ""' "$MANIFEST")"
READY_TMO="$(yq -r '.scan.probe_ready_timeout_sec // 30' "$MANIFEST")"
GRACE="$(yq -r '.scan.grace_term_sec // 10' "$MANIFEST")"

SCAN_ID_PREFIX="${SCAN_ID_PREFIX:-runcci}"
CID="${SCAN_ID_PREFIX}-${BUNDLE_NAME}-$$"

mkdir -p "$GEN_DIR"
rm -f "$GEN_DIR"/* 2>/dev/null || true
mkdir -p "$GEN_DIR/e2e"

flags=( "--security-scan" )
[[ "$SEC_HOOK" != "auto" && -n "$SEC_HOOK" ]] && flags+=( "--scan-seccomp-hook" "$SEC_HOOK" )
[[ "$CAPABLE"  != "auto" && -n "$CAPABLE"  ]] && flags+=( "--scan-capable"       "$CAPABLE"  )

container_alive() {
  "$RUNC" list 2>/dev/null | awk -v id="$CID" 'NR>1 && $1==id {found=1} END{exit !found}'
}

cleanup() {
  local rc=$?
  set +e
  if container_alive; then
    echo "==> cleanup: sending TERM to $CID"
    "$RUNC" kill --all "$CID" TERM 2>/dev/null || true
    for _ in $(seq 1 "$GRACE"); do
      container_alive || break
      sleep 1
    done
    if container_alive; then
      echo "==> cleanup: sending KILL to $CID"
      "$RUNC" kill --all "$CID" KILL 2>/dev/null || true
      sleep 1
    fi
    "$RUNC" delete --force "$CID" 2>/dev/null || true
  fi
  return "$rc"
}
trap cleanup EXIT

echo "==> runc version"
"$RUNC" --version || true

echo "==> starting '$RUNC run ${flags[*]} $CID' (detached, duration fuse ${DURATION}s)"
pushd "$OUT_DIR" >/dev/null
"$RUNC" run "${flags[@]}" "$CID" >"$GEN_DIR/runc.stdout" 2>"$GEN_DIR/runc.stderr" &
RUNC_PID=$!
popd >/dev/null

rc_probe=0
if [[ -n "$PROBE_REL" && "$PROBE_REL" != "null" ]]; then
  PROBE_ABS="$BUNDLE_DIR/$PROBE_REL"
  [[ -x "$PROBE_ABS" ]] || { echo "probe $PROBE_ABS not executable" >&2; exit 2; }
  echo "==> running probe $PROBE_ABS (ready_timeout=${READY_TMO}s)"
  set +e
  OUT_DIR="$OUT_DIR" GEN_DIR="$GEN_DIR" BUNDLE_DIR="$BUNDLE_DIR" \
    READY_TIMEOUT="$READY_TMO" RUNC_PID="$RUNC_PID" CID="$CID" \
    "$PROBE_ABS" 2>&1 | tee "$GEN_DIR/e2e/probe.log"
  rc_probe=${PIPESTATUS[0]}
  set -e
  echo "==> probe exit=$rc_probe"
else
  echo "==> no probe_script; sleeping ${DURATION}s"
  sleep "$DURATION" || true
fi

echo "==> signalling graceful TERM to $CID"
if container_alive; then
  "$RUNC" kill --all "$CID" TERM 2>/dev/null || true
fi

echo "==> waiting up to ${DURATION}s for runc pid=$RUNC_PID"
set +e
for _ in $(seq 1 "$DURATION"); do
  kill -0 "$RUNC_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$RUNC_PID" 2>/dev/null; then
  echo "==> runc still alive after ${DURATION}s, escalating to KILL"
  if container_alive; then
    "$RUNC" kill --all "$CID" KILL 2>/dev/null || true
  fi
  for _ in $(seq 1 5); do
    kill -0 "$RUNC_PID" 2>/dev/null || break
    sleep 1
  done
fi
wait "$RUNC_PID" 2>/dev/null
rc_runc=$?
set -e

dump_runc_streams() {
  echo "----- runc.stderr (tail 200) -----"
  tail -n 200 "$GEN_DIR/runc.stderr" 2>/dev/null || echo "(no runc.stderr)"
  echo "----- runc.stdout (tail 200) -----"
  tail -n 200 "$GEN_DIR/runc.stdout" 2>/dev/null || echo "(no runc.stdout)"
  echo "----- end runc streams -----"
}

# timeout exit codes: 0 (graceful), 124 (timeout), 137 (SIGKILL), 143 (SIGTERM)
case "$rc_runc" in
  0|124|137|143)
    echo "==> runc exit=$rc_runc (accepted)"
    # Even on accepted exits show the stderr tail when probe failed,
    # so the next debugging round does not require an S3 round-trip.
    if [[ "$rc_probe" -ne 0 ]]; then
      dump_runc_streams
    fi
    ;;
  *)
    echo "==> runc exit=$rc_runc (unexpected)"
    dump_runc_streams
    exit "$rc_runc"
    ;;
esac

ls -la "$GEN_DIR" || true

exit "$rc_probe"
