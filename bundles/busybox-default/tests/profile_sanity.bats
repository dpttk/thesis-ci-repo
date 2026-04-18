#!/usr/bin/env bats

# Generic sanity bats suite that any bundle can reuse. Relies on these env
# vars populated by the workflow / run-scan.sh:
#   BUNDLE_NAME   - name of the current bundle (dir under bundles/)
#   BUNDLE_DIR    - absolute path to the bundle directory
#   OUT_DIR       - absolute path to out/<bundle>
#   GEN_DIR       - absolute path to out/<bundle>/generated

setup() {
  : "${BUNDLE_NAME:?BUNDLE_NAME must be set}"
  : "${OUT_DIR:?OUT_DIR must be set}"
  : "${GEN_DIR:?GEN_DIR must be set}"
}

@test "seccomp.json exists and is non-empty" {
  [ -s "$GEN_DIR/seccomp.json" ]
}

@test "seccomp.json is valid JSON with syscalls" {
  run jq -e '[.syscalls[]?.names[]?] | length > 0' "$GEN_DIR/seccomp.json"
  [ "$status" -eq 0 ]
}

@test "apparmor.profile exists" {
  [ -f "$GEN_DIR/apparmor.profile" ]
}

@test "capabilities snapshot exists" {
  [ -s "$GEN_DIR/capabilities-from-proc-status.txt" ]
}

@test "updated config.json is valid JSON" {
  run jq empty "$OUT_DIR/config.json"
  [ "$status" -eq 0 ]
}
