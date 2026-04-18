#!/usr/bin/env bats

# Juice-shop bundle specific checks. Assumes run-scan.sh has been called
# and the bundle exercised its network stack long enough for BCC to see
# CAP_NET_BIND_SERVICE / CAP_NET_RAW and for seccomp-bpf-hook to observe
# network syscalls.

setup() {
  : "${OUT_DIR:?OUT_DIR must be set}"
  : "${GEN_DIR:?GEN_DIR must be set}"
}

@test "seccomp profile includes network-related syscalls" {
  run jq -r '[.syscalls[]?.names[]?] | join(" ")' "$GEN_DIR/seccomp.json"
  [ "$status" -eq 0 ]
  echo "$output" | tr ' ' '\n' | grep -qE '^(socket|bind|listen|accept4?|connect)$'
}

@test "capabilities report mentions CAP_NET_BIND_SERVICE" {
  hay=""
  [ -s "$GEN_DIR/capable-bpfcc.log" ] && hay+="$(cat "$GEN_DIR/capable-bpfcc.log") "
  [ -s "$GEN_DIR/capabilities-from-proc-status.txt" ] && hay+="$(cat "$GEN_DIR/capabilities-from-proc-status.txt")"
  echo "$hay" | grep -qw CAP_NET_BIND_SERVICE
}
