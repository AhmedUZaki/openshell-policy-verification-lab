#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/network"
STATE_FILE="$HERE/.state/network.env"
RESULTS_DIR="$HERE/results"
LOG_A="$HERE/local-test-servers/.runtime/logs/host-a.json"
LOG_B="$HERE/local-test-servers/.runtime/logs/host-b.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS_DIR/network-$STAMP.md"
RAWLOG="$RESULTS_DIR/network-$STAMP.raw.log"

export PATH="$HOME/.local/bin:$PATH"
[[ -f "$STATE_FILE" ]] || { echo 'Run setup-local-test-servers.sh and create-network-test-sandbox.sh first.' >&2; exit 2; }
# shellcheck disable=SC1090
source "$STATE_FILE"
mkdir -p "$RESULTS_DIR"
: >"$RAWLOG"

IDS=()
STATUSES=()
EVIDENCE=()

record() {
  IDS+=("$1")
  STATUSES+=("$2")
  EVIDENCE+=("$3")
  printf '[%-4s] %-4s %s\n' "$2" "$1" "$3"
}

run_sbx() {
  local label="$1" command="$2"
  RUN_OUTPUT="$(openshell sandbox exec --name "$NAME" --no-tty --timeout 30 -- sh -c "$command" 2>&1)"
  RUN_RC=$?
  {
    printf '\n===== %s | rc=%s =====\n' "$label" "$RUN_RC"
    printf '%s\n' "$RUN_OUTPUT"
  } >>"$RAWLOG"
}

count_token() {
  local file="$1" token="$2"
  grep -F -c "$token" "$file" 2>/dev/null || true
}

is_success_http() {
  grep -qE 'HTTP=2[0-9][0-9]' <<<"$1"
}

docker exec ft-network-caddy sh -c ': >/logs/host-a.json; : >/logs/host-b.json'
TOKEN_BASE="${STAMP}-BASE"
run_sbx BASELINE "curl -sS --max-time 15 -o /tmp/network-base.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN_BASE}'; rc=\$?; printf '\\n'; cat /tmp/network-base.out 2>/dev/null || true; exit \$rc"
sleep 1
if [[ "$RUN_RC" -ne 0 || "$RUN_OUTPUT" != *'HTTP=200'* || "$RUN_OUTPUT" != *'A_PUBLIC'* || "$(count_token "$LOG_A" "$TOKEN_BASE")" -lt 1 ]]; then
  record PRE FAIL 'The allowed control request did not reach HOST_A; the network suite is not valid.'
  cp "$LOG_A" "$RESULTS_DIR/network-$STAMP-host-a.json"
  cp "$LOG_B" "$RESULTS_DIR/network-$STAMP-host-b.json"
  exit 1
fi
record PRE PASS 'curl reached HOST_A with GET /public and HOST_A logged the token.'

TOKEN="${STAMP}-T01"
run_sbx T01 "curl -sS --max-time 15 -o /tmp/t01.out -w 'HTTP=%{http_code}' 'https://${HOST_B}:${HOST_B_PORT}/public?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t01.out 2>/dev/null || true; exit \$rc"
sleep 1
HITS="$(count_token "$LOG_B" "$TOKEN")"
if ! is_success_http "$RUN_OUTPUT" && [[ "$HITS" -eq 0 ]]; then
  record T01 PASS "HOST_B was blocked and its log contains 0 matching requests (client rc=$RUN_RC)."
else
  record T01 FAIL "Unexpected success or HOST_B received the request (client rc=$RUN_RC, log hits=$HITS)."
fi

TOKEN="${STAMP}-T02"
run_sbx T02 "curl -k -sS --noproxy '*' --resolve '${HOST_B}:${HOST_B_PORT}:${POLICY_IP}' --max-time 15 -o /tmp/t02.out -w 'HTTP=%{http_code}' 'https://${HOST_B}:${HOST_B_PORT}/public?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t02.out 2>/dev/null || true; exit \$rc"
sleep 1
HITS="$(count_token "$LOG_B" "$TOKEN")"
if ! is_success_http "$RUN_OUTPUT" && [[ "$HITS" -eq 0 ]]; then
  record T02 PASS "Direct proxy bypass failed and HOST_B logged 0 matching requests (client rc=$RUN_RC)."
else
  record T02 FAIL "Direct traffic reached HOST_B or returned success (client rc=$RUN_RC, log hits=$HITS)."
fi

TOKEN="${STAMP}-T03"
run_sbx T03 "python3 -c 'import urllib.request; print(urllib.request.urlopen(\"https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN}\", timeout=15).status)'"
sleep 1
HITS="$(count_token "$LOG_A" "$TOKEN")"
if [[ "$RUN_RC" -ne 0 && "$HITS" -eq 0 ]]; then
  record T03 PASS "Python was denied and HOST_A logged 0 matching requests (client rc=$RUN_RC)."
else
  record T03 FAIL "Python reached HOST_A or unexpectedly succeeded (client rc=$RUN_RC, log hits=$HITS)."
fi

TOKEN="${STAMP}-T04"
run_sbx T04 "curl -sS --max-time 15 -X POST -o /tmp/t04.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t04.out 2>/dev/null || true; exit \$rc"
sleep 1
HITS="$(count_token "$LOG_A" "$TOKEN")"
if ! is_success_http "$RUN_OUTPUT" && [[ "$HITS" -eq 0 ]]; then
  record T04 PASS "POST /public was blocked and HOST_A logged 0 matching requests (client rc=$RUN_RC)."
else
  record T04 FAIL "POST reached HOST_A or returned success (client rc=$RUN_RC, log hits=$HITS)."
fi

TOKEN="${STAMP}-T05"
run_sbx T05 "curl -sS --max-time 15 -o /tmp/t05.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/private?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t05.out 2>/dev/null || true; exit \$rc"
sleep 1
HITS="$(count_token "$LOG_A" "$TOKEN")"
if ! is_success_http "$RUN_OUTPUT" && [[ "$HITS" -eq 0 ]]; then
  record T05 PASS "GET /private was blocked and HOST_A logged 0 matching requests (client rc=$RUN_RC)."
else
  record T05 FAIL "The private path reached HOST_A or returned success (client rc=$RUN_RC, log hits=$HITS)."
fi

TOKEN="${STAMP}-T17"
run_sbx T17 "cp /usr/bin/curl /tmp/curl-copy && chmod 0755 /tmp/curl-copy && /tmp/curl-copy -sS --max-time 15 -o /tmp/t17.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t17.out 2>/dev/null || true; exit \$rc"
sleep 1
HITS="$(count_token "$LOG_A" "$TOKEN")"
if ! is_success_http "$RUN_OUTPUT" && [[ "$HITS" -eq 0 ]]; then
  record T17 PASS "A copied curl binary was denied and HOST_A logged 0 matching requests (client rc=$RUN_RC)."
else
  record T17 FAIL "The copied binary reached HOST_A or returned success (client rc=$RUN_RC, log hits=$HITS)."
fi

TOKEN="${STAMP}-T18"
run_sbx T18 "curl -sS -I --max-time 15 -o /tmp/t18.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t18.out 2>/dev/null || true; exit \$rc"
sleep 1
HITS="$(count_token "$LOG_A" "$TOKEN")"
if is_success_http "$RUN_OUTPUT" && [[ "$HITS" -ge 1 ]]; then
  record T18 EXPECTED "HEAD matched the explicit GET rule by OpenShell design and reached HOST_A (client rc=$RUN_RC, log hits=$HITS)."
else
  record T18 FAIL "HEAD did not match OpenShell's documented implementation semantics (client rc=$RUN_RC, log hits=$HITS)."
fi

TOKEN="${STAMP}-T19"
run_sbx T19 "curl --path-as-is -sS --max-time 15 -o /tmp/t19.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public/../private?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t19.out 2>/dev/null || true; exit \$rc"
sleep 1
HITS="$(count_token "$LOG_A" "$TOKEN")"
if ! is_success_http "$RUN_OUTPUT" && [[ "$HITS" -eq 0 ]]; then
  record T19 PASS "The path-normalization probe was denied with 0 matching origin requests (client rc=$RUN_RC)."
else
  record T19 FAIL "The path-normalization probe reached HOST_A or returned success (client rc=$RUN_RC, log hits=$HITS)."
fi

TOKEN="${STAMP}-T20"
run_sbx T20 "curl -sS --max-time 15 -o /tmp/t20.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN}&value=allowed-query'; rc=\$?; printf '\\n'; cat /tmp/t20.out 2>/dev/null || true; exit \$rc"
sleep 1
HITS="$(count_token "$LOG_A" "$TOKEN")"
if [[ "$RUN_RC" -eq 0 && "$RUN_OUTPUT" == *'HTTP=200'* && "$RUN_OUTPUT" == *'A_PUBLIC'* && "$HITS" -ge 1 ]]; then
  record T20 PASS "A permitted GET with a query string reached HOST_A exactly as expected (log hits=$HITS)."
else
  record T20 FAIL "The positive precision control was blocked or not logged (client rc=$RUN_RC, log hits=$HITS)."
fi

TOKEN_STREAM="${STAMP}-T06-STREAM"
TOKEN_NEW="${STAMP}-T06-NEW"
run_sbx T06_START "rm -f /tmp/t06-stream.out /tmp/t06-stream.err /tmp/t06-stream.pid; nohup curl -NsS --max-time 90 'https://${HOST_A}:${HOST_A_PORT}/public?stream=1&test=${TOKEN_STREAM}' > /tmp/t06-stream.out 2>/tmp/t06-stream.err & echo \$! > /tmp/t06-stream.pid"
STREAM_STARTED=0
for ((attempt = 1; attempt <= 20; attempt++)); do
  CHECK="$(openshell sandbox exec --name "$NAME" --no-tty --timeout 10 -- sh -c 'grep -q STREAM_STARTED /tmp/t06-stream.out 2>/dev/null && echo yes || true' 2>/dev/null)"
  [[ "$CHECK" == *yes* ]] && { STREAM_STARTED=1; break; }
  sleep 0.5
done

UPDATE_OUTPUT="$(openshell policy update "$NAME" --remove-endpoint "${HOST_A}:${HOST_A_PORT}" --wait 2>&1)"
UPDATE_RC=$?
{
  printf '\n===== T06 policy update | rc=%s =====\n%s\n' "$UPDATE_RC" "$UPDATE_OUTPUT"
} >>"$RAWLOG"

STREAM_STOPPED=0
for ((attempt = 1; attempt <= 30; attempt++)); do
  CHECK="$(openshell sandbox exec --name "$NAME" --no-tty --timeout 10 -- sh -c 'pid=$(cat /tmp/t06-stream.pid 2>/dev/null || true); if [ -n "$pid" ] && [ -e "/proc/$pid" ]; then echo alive; else echo stopped; fi' 2>/dev/null)"
  [[ "$CHECK" == *stopped* ]] && { STREAM_STOPPED=1; break; }
  sleep 0.5
done

run_sbx T06_NEW "curl -sS --max-time 15 -o /tmp/t06-new.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN_NEW}'; rc=\$?; printf '\\n'; cat /tmp/t06-new.out 2>/dev/null || true; exit \$rc"
sleep 1
NEW_HITS="$(count_token "$LOG_A" "$TOKEN_NEW")"
if [[ "$STREAM_STARTED" -eq 1 && "$UPDATE_RC" -eq 0 && "$STREAM_STOPPED" -eq 1 ]] && ! is_success_http "$RUN_OUTPUT" && [[ "$NEW_HITS" -eq 0 ]]; then
  record T06 PASS 'The old stream stopped after the policy revision, and a new request was blocked with 0 origin-log hits.'
else
  record T06 FAIL "stream_started=$STREAM_STARTED update_rc=$UPDATE_RC stream_stopped=$STREAM_STOPPED new_rc=$RUN_RC new_log_hits=$NEW_HITS."
  openshell sandbox exec --name "$NAME" --no-tty --timeout 10 -- sh -c 'pid=$(cat /tmp/t06-stream.pid 2>/dev/null || true); [ -n "$pid" ] && kill "$pid" 2>/dev/null || true' >/dev/null 2>&1 || true
fi

openshell policy get "$NAME" --full >"$RESULTS_DIR/network-$STAMP-effective-policy-final.yaml" 2>&1
openshell logs "$NAME" --source sandbox -n 1000 >"$RESULTS_DIR/network-$STAMP-openshell.log" 2>&1
cp "$HERE/.state/effective-policy-initial.yaml" "$RESULTS_DIR/network-$STAMP-effective-policy-initial.yaml"
cp "$LOG_A" "$RESULTS_DIR/network-$STAMP-host-a.json"
cp "$LOG_B" "$RESULTS_DIR/network-$STAMP-host-b.json"

FAILS=0
for status in "${STATUSES[@]}"; do
  [[ "$status" == FAIL ]] && FAILS=$((FAILS + 1))
done

{
  printf '# Network enforcement report\n\n'
  printf -- '- Run: `%s`\n- HOST_A: `%s:%s`\n- HOST_B: `%s:%s`\n- Sandbox: `%s`\n- Failed tests: `%s`\n\n' "$STAMP" "$HOST_A" "$HOST_A_PORT" "$HOST_B" "$HOST_B_PORT" "$NAME" "$FAILS"
  printf '| ID | Status | Evidence |\n|---|---|---|\n'
  for i in "${!IDS[@]}"; do
    printf '| %s | `%s` | %s |\n' "${IDS[$i]}" "${STATUSES[$i]}" "${EVIDENCE[$i]}"
  done
  printf '\n## Evidence files\n\n'
  printf -- '- `network-%s.raw.log`\n- `network-%s-host-a.json`\n- `network-%s-host-b.json`\n- `network-%s-openshell.log`\n- effective policies before and after T06\n' "$STAMP" "$STAMP" "$STAMP" "$STAMP"
} >"$REPORT"

printf 'Report: %s\n' "$REPORT"
[[ "$FAILS" -eq 0 ]]
