#!/usr/bin/env bash
# E2E probe for the juice-shop bundle. Driven by scripts/run-scan.sh while
# `runc run --security-scan` is live with host networking. Walks through
# public endpoints, authenticates as the default admin seed, and hits a
# few admin-scope endpoints so the scanner observes a realistic syscall /
# capability set. Exit non-zero on any mandatory assertion failure.
#
# Env (provided by run-scan.sh):
#   GEN_DIR         absolute path to out/<bundle>/generated
#   OUT_DIR         absolute path to out/<bundle>
#   BUNDLE_DIR      absolute path to bundles/<bundle>
#   READY_TIMEOUT   seconds to wait for port 3000 (integer)
#   CID             runc container id
#   RUNC_PID        pid of the background `runc run` process
#
# Outputs in $GEN_DIR/e2e/:
#   http-results.tsv         phase<TAB>method<TAB>path<TAB>status<TAB>elapsed_ms<TAB>bytes
#   body-<slug>.(json|html)  captured bodies for later inspection
#   probe.log                stdout/stderr (tee'd by run-scan.sh)

set -u

: "${GEN_DIR:?GEN_DIR must be set}"
: "${READY_TIMEOUT:=60}"

BASE_URL="${BASE_URL:-http://127.0.0.1:3000}"
ADMIN_EMAIL="${JUICE_ADMIN_EMAIL:-admin@juice-sh.op}"
ADMIN_PASS="${JUICE_ADMIN_PASS:-admin123}"

E2E_DIR="$GEN_DIR/e2e"
mkdir -p "$E2E_DIR"
RESULTS="$E2E_DIR/http-results.tsv"
: > "$RESULTS"
printf 'phase\tmethod\tpath\tstatus\telapsed_ms\tbytes\n' > "$RESULTS"

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "jq is required"   >&2; exit 2; }

fail=0
mandatory_fail=0

note() { echo "[probe] $*"; }

# Record a request: phase method path status elapsed_ms bytes
record() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$RESULTS"
}

# curl wrapper: writes body to $1, prints "HTTP<TAB>bytes<TAB>elapsed_ms" to stdout.
# Args: out_file method path [--data json] [--header "h: v"]...
http_call() {
  local out="$1"; shift
  local method="$1"; shift
  local path="$1"; shift
  local url="$BASE_URL$path"
  local args=( -sS -o "$out" --max-time 10 -X "$method"
               -w '%{http_code}\t%{size_download}\t%{time_total}' )
  while (( $# )); do
    args+=( "$1" ); shift
  done
  local out_str status bytes elapsed_s elapsed_ms
  out_str="$(curl "${args[@]}" "$url" 2>/dev/null)" || out_str="000	0	0"
  IFS=$'\t' read -r status bytes elapsed_s <<<"$out_str"
  # convert seconds to ms without bc
  elapsed_ms="$(awk -v s="$elapsed_s" 'BEGIN{printf "%d", s*1000}')"
  printf '%s\t%s\t%s\n' "${status:-000}" "${bytes:-0}" "${elapsed_ms:-0}"
}

# assert_status phase method path expected actual body_path
# expected can be a |-separated list, e.g. "200|201"
assert_status() {
  local phase="$1" method="$2" path="$3" expected="$4" actual="$5"
  local ok=0
  local IFS='|'
  for code in $expected; do
    if [[ "$actual" == "$code" ]]; then ok=1; break; fi
  done
  if (( ok )); then
    note "OK   [$phase] $method $path -> $actual"
    return 0
  else
    note "FAIL [$phase] $method $path -> $actual (expected $expected)"
    return 1
  fi
}

##############################################################################
# Phase 1: readiness
##############################################################################
note "waiting for $BASE_URL/ (timeout=${READY_TIMEOUT}s)"
ready=0
ready_elapsed=0
for i in $(seq 1 "$READY_TIMEOUT"); do
  status_line="$(http_call "$E2E_DIR/.ready.tmp" GET /)"
  IFS=$'\t' read -r status bytes elapsed_ms <<<"$status_line"
  if [[ "$status" == "200" ]]; then
    ready=1
    ready_elapsed=$i
    mv -f "$E2E_DIR/.ready.tmp" "$E2E_DIR/body-root.html"
    record readiness GET / "$status" "$elapsed_ms" "$bytes"
    break
  fi
  sleep 1
done
rm -f "$E2E_DIR/.ready.tmp"

if (( ! ready )); then
  note "FATAL: juice-shop did not become ready within ${READY_TIMEOUT}s"
  record readiness GET / 000 0 0
  exit 2
fi
note "ready after ${ready_elapsed}s"

if ! grep -q 'OWASP Juice Shop' "$E2E_DIR/body-root.html"; then
  note "FAIL [readiness] body-root.html lacks 'OWASP Juice Shop' marker"
  mandatory_fail=$((mandatory_fail+1))
else
  note "OK   [readiness] root page contains 'OWASP Juice Shop'"
fi

##############################################################################
# Phase 2: unauthenticated public endpoints
##############################################################################
# Format: slug|method|path|expected_statuses|assert_jq_expr (empty to skip)
unauth=(
  "version|GET|/rest/admin/application-version|200|.version | type == \"string\" and length > 0"
  "products|GET|/api/Products|200|(.data // []) | type == \"array\" and length > 0"
  "challenges|GET|/api/Challenges/|200|type == \"object\""
  "languages|GET|/rest/languages|200|type == \"array\""
  "ftp|GET|/ftp/|200|"
  "apidocs|GET|/api-docs|200|"
)

for spec in "${unauth[@]}"; do
  IFS='|' read -r slug method path expected jq_expr <<<"$spec"
  out="$E2E_DIR/body-${slug}.json"
  # Heuristic: non-JSON routes save as .html
  case "$path" in
    /ftp/) out="$E2E_DIR/body-${slug}.html" ;;
  esac
  line="$(http_call "$out" "$method" "$path")"
  IFS=$'\t' read -r status bytes elapsed_ms <<<"$line"
  record unauth "$method" "$path" "$status" "$elapsed_ms" "$bytes"
  if ! assert_status unauth "$method" "$path" "$expected" "$status"; then
    mandatory_fail=$((mandatory_fail+1))
    continue
  fi
  if [[ -n "$jq_expr" ]]; then
    if jq -e "$jq_expr" "$out" >/dev/null 2>&1; then
      note "OK   [unauth] jq '$jq_expr' on $out"
    else
      note "FAIL [unauth] jq '$jq_expr' failed on $out"
      mandatory_fail=$((mandatory_fail+1))
    fi
  fi
done

##############################################################################
# Phase 3: login (soft fail - admin seed may vary)
##############################################################################
TOKEN=""
login_body="$E2E_DIR/body-login.json"
login_payload="$(jq -nc --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASS" '{email:$e,password:$p}')"
line="$(http_call "$login_body" POST /rest/user/login \
  --header 'Content-Type: application/json' \
  --data "$login_payload")"
IFS=$'\t' read -r status bytes elapsed_ms <<<"$line"
record login POST /rest/user/login "$status" "$elapsed_ms" "$bytes"

if [[ "$status" == "200" ]]; then
  TOKEN="$(jq -r '.authentication.token // ""' "$login_body" 2>/dev/null || echo "")"
  if [[ -n "$TOKEN" ]]; then
    note "OK   [login] token acquired ($(echo -n "$TOKEN" | wc -c) bytes)"
  else
    note "WARN [login] status=200 but no .authentication.token - skipping auth phase"
    fail=$((fail+1))
  fi
else
  note "WARN [login] status=$status - skipping auth phase (admin seed may differ)"
  fail=$((fail+1))
fi

##############################################################################
# Phase 4: authenticated calls (skipped if no TOKEN)
##############################################################################
if [[ -n "$TOKEN" ]]; then
  auth_header="Authorization: Bearer $TOKEN"

  # whoami
  out="$E2E_DIR/body-whoami.json"
  line="$(http_call "$out" GET /rest/user/whoami --header "$auth_header")"
  IFS=$'\t' read -r status bytes elapsed_ms <<<"$line"
  record auth GET /rest/user/whoami "$status" "$elapsed_ms" "$bytes"
  if assert_status auth GET /rest/user/whoami 200 "$status"; then
    if jq -e --arg e "$ADMIN_EMAIL" '(.user.email // "") == $e' "$out" >/dev/null 2>&1; then
      note "OK   [auth] whoami email matches"
    else
      note "FAIL [auth] whoami email mismatch"
      mandatory_fail=$((mandatory_fail+1))
    fi
  else
    mandatory_fail=$((mandatory_fail+1))
  fi

  # /api/Users (admin scope)
  out="$E2E_DIR/body-users.json"
  line="$(http_call "$out" GET /api/Users --header "$auth_header")"
  IFS=$'\t' read -r status bytes elapsed_ms <<<"$line"
  record auth GET /api/Users "$status" "$elapsed_ms" "$bytes"
  if assert_status auth GET /api/Users 200 "$status"; then
    if jq -e '(.data // []) | type == "array" and length > 0' "$out" >/dev/null 2>&1; then
      note "OK   [auth] /api/Users non-empty array"
    else
      note "FAIL [auth] /api/Users response shape unexpected"
      mandatory_fail=$((mandatory_fail+1))
    fi
  else
    mandatory_fail=$((mandatory_fail+1))
  fi

  # POST /api/BasketItems
  out="$E2E_DIR/body-basketitem.json"
  basket_payload='{"ProductId":1,"BasketId":1,"quantity":1}'
  line="$(http_call "$out" POST /api/BasketItems \
    --header "$auth_header" \
    --header 'Content-Type: application/json' \
    --data "$basket_payload")"
  IFS=$'\t' read -r status bytes elapsed_ms <<<"$line"
  record auth POST /api/BasketItems "$status" "$elapsed_ms" "$bytes"
  if ! assert_status auth POST /api/BasketItems "200|201" "$status"; then
    # juice-shop returns 400 if item already in basket across reruns - soft fail
    note "WARN [auth] basket POST non-2xx ($status); treating as soft fail"
    fail=$((fail+1))
  fi

  # GET /rest/basket/1
  out="$E2E_DIR/body-basket.json"
  line="$(http_call "$out" GET /rest/basket/1 --header "$auth_header")"
  IFS=$'\t' read -r status bytes elapsed_ms <<<"$line"
  record auth GET /rest/basket/1 "$status" "$elapsed_ms" "$bytes"
  if assert_status auth GET /rest/basket/1 200 "$status"; then
    if jq -e '(.data.Products // []) | type == "array"' "$out" >/dev/null 2>&1; then
      note "OK   [auth] basket.data.Products is array"
    else
      note "FAIL [auth] basket shape unexpected"
      mandatory_fail=$((mandatory_fail+1))
    fi
  else
    mandatory_fail=$((mandatory_fail+1))
  fi
fi

##############################################################################
# Summary
##############################################################################
total="$(( $(wc -l < "$RESULTS") - 1 ))"
note "summary: $total requests recorded; mandatory_failures=$mandatory_fail soft_failures=$fail"

if (( mandatory_fail > 0 )); then
  exit 1
fi
exit 0
