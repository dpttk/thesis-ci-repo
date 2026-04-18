#!/usr/bin/env bash
# Validate the generated/ artifacts of a scanned bundle against the
# expect.* contract in bundle.yaml.
#
# Usage: verify-profiles.sh bundles/<name>

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

[[ -d "$GEN_DIR" ]] || { echo "no generated/ dir: $GEN_DIR" >&2; exit 1; }

pass=0; fail=0
check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" -eq 0 ]]; then
    echo "  OK   $name"
    pass=$((pass+1))
  else
    echo "  FAIL $name ${detail:+- $detail}"
    fail=$((fail+1))
  fi
}

echo "==> verifying profiles for $BUNDLE_NAME"

MIN_SYSCALLS="$(yq -r '.expect.profiles.seccomp_min_syscalls // 0' "$MANIFEST")"
AA_HAS_INCLUDE="$(yq -r '.expect.profiles.apparmor_has_include // true' "$MANIFEST")"
CAPS_REQ="$(yq -r '.expect.profiles.capabilities_contains // [] | .[]' "$MANIFEST" | tr '\n' ' ')"

# 1. seccomp.json
if [[ -s "$GEN_DIR/seccomp.json" ]] && jq empty "$GEN_DIR/seccomp.json" 2>/dev/null; then
  count="$(jq '[.syscalls[]?.names[]?] | length' "$GEN_DIR/seccomp.json" 2>/dev/null || echo 0)"
  if (( count >= MIN_SYSCALLS )); then
    check "seccomp.json has >= $MIN_SYSCALLS syscalls (got $count)" 0
  else
    check "seccomp.json has >= $MIN_SYSCALLS syscalls (got $count)" 1
  fi
else
  check "seccomp.json exists and is valid JSON" 1 "missing or invalid"
fi

# 2. apparmor.profile
if [[ -f "$GEN_DIR/apparmor.profile" ]]; then
  first="$(head -n1 "$GEN_DIR/apparmor.profile")"
  if [[ "$AA_HAS_INCLUDE" == "true" ]]; then
    if [[ "$first" == "#include <tunables/global>" ]]; then
      check "apparmor.profile starts with tunables/global include" 0
    else
      check "apparmor.profile starts with tunables/global include" 1 "got: $first"
    fi
  fi
  if grep -q 'flags=(complain' "$GEN_DIR/apparmor.profile"; then
    check "apparmor.profile has complain flag" 0
  else
    check "apparmor.profile has complain flag" 1
  fi
else
  check "apparmor.profile exists" 1
fi

# 3. capabilities snapshot
if [[ -s "$GEN_DIR/capabilities-from-proc-status.txt" ]]; then
  if grep -q '^CapBnd:' "$GEN_DIR/capabilities-from-proc-status.txt"; then
    check "capabilities-from-proc-status.txt has CapBnd:" 0
  else
    check "capabilities-from-proc-status.txt has CapBnd:" 1
  fi
  if [[ -n "$CAPS_REQ" ]]; then
    hay=""
    [[ -s "$GEN_DIR/capable-bpfcc.log" ]] && hay+="$(cat "$GEN_DIR/capable-bpfcc.log") "
    hay+="$(cat "$GEN_DIR/capabilities-from-proc-status.txt")"
    for cap in $CAPS_REQ; do
      if grep -qw "$cap" <<<"$hay"; then
        check "capabilities contain $cap" 0
      else
        check "capabilities contain $cap" 1 "not found in capable-bpfcc.log or proc status"
      fi
    done
  fi
else
  check "capabilities-from-proc-status.txt exists" 1
fi

# 4. config.json validity
if [[ -f "$OUT_DIR/config.json" ]] && jq empty "$OUT_DIR/config.json" 2>/dev/null; then
  check "config.json is valid JSON" 0
else
  check "config.json is valid JSON" 1
fi

echo "==> results: $pass passed, $fail failed"
exit "$fail"
