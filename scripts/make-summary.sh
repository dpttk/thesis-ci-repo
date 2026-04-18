#!/usr/bin/env bash
# Emit a markdown summary of all downloaded generated-* artifacts.
# Intended for a GitHub Actions aggregate job that has actions/download-artifact@v4
# at $PWD; it scans any subdir named generated-<bundle>.
#
# Writes to stdout; workflow redirects into $GITHUB_STEP_SUMMARY.

set -euo pipefail

printf '## runc security-scan results\n\n'

shopt -s nullglob
any=0
for dir in generated-*; do
  any=1
  bundle="${dir#generated-}"
  printf '### %s\n\n' "$bundle"

  if [[ -s "$dir/seccomp.json" ]]; then
    count="$(jq '[.syscalls[]?.names[]?] | length' "$dir/seccomp.json" 2>/dev/null || echo '?')"
    printf '- seccomp.json: **%s** syscalls\n' "$count"
  else
    printf '- seccomp.json: _missing_\n'
  fi

  if [[ -f "$dir/apparmor.profile" ]]; then
    lines="$(wc -l <"$dir/apparmor.profile" | tr -d ' ')"
    printf '- apparmor.profile: %s lines\n' "$lines"
  else
    printf '- apparmor.profile: _missing_\n'
  fi

  if [[ -s "$dir/capable-bpfcc.log" ]]; then
    caps="$(grep -hoE 'CAP_[A-Z_]+' "$dir/capable-bpfcc.log" 2>/dev/null | sort -u | paste -sd ',' - || true)"
    printf '- capable-bpfcc caps: `%s`\n' "${caps:-<none>}"
  fi
  if [[ -s "$dir/capabilities-from-proc-status.txt" ]]; then
    printf '- proc status (first lines):\n\n'
    printf '```\n'
    head -n 6 "$dir/capabilities-from-proc-status.txt"
    printf '```\n\n'
  fi
done

if [[ "$any" -eq 0 ]]; then
  printf '_no artifacts found_\n'
fi
