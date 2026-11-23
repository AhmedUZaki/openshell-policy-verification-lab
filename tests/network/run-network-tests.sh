#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/network"
STATE_FILE="$HERE/.state/network.env"
RESULTS_DIR="$HERE/results"
LOG_A="$HERE/local-test-servers/.runtime/logs/host-a.json"
LOG_B="$HERE/local-test-servers/.runtime/logs/host-b.json"
STAMP="${AUDIT_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
[[ "$STAMP" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'The audit run ID contains unsafe characters.' >&2; exit 2; }
REPORT="$RESULTS_DIR/network-$STAMP.md"
RAWLOG="$RESULTS_DIR/network-$STAMP.raw.log"
[[ ! -e "$REPORT" && ! -e "$RAWLOG" ]] || { echo "Result files already exist for run ID: $STAMP" >&2; exit 2; }

export PATH="$HOME/.local/bin:$PATH"
[[ -f "$STATE_FILE" ]] || { echo 'Run setup-local-test-servers.sh and create-network-test-sandbox.sh first.' >&2; exit 2; }
# shellcheck disable=SC1090
source "$STATE_FILE"
mkdir -p "$RESULTS_DIR"
: >"$RAWLOG"

# OpenShell 0.1.x enforces below HTTP: a destination or executable the policy does not allow is refused at
# the sandbox boundary (connection refused, permission denied, or the name does not resolve) instead of being
# answered with an HTTP 403. These count as a denial signal only on 0.1.x; the other conditions of every
# denial verdict still apply (working baseline, healthy sandbox and origin, zero origin-log hits).
# shellcheck disable=SC1091
source "$ROOT/tests/shared/gateway-network-config.sh"
POLICY_DNS_MODE=0
lab_openshell_uses_policy_dns && POLICY_DNS_MODE=1
boundary_refusal() {
  [[ "$POLICY_DNS_MODE" -eq 1 ]] || return 1
  [[ ( "$RUN_RC" -eq 7 && "$RUN_OUTPUT" == *"Couldn't connect to server"* ) \
    || ( "$RUN_RC" -eq 6 && "$RUN_OUTPUT" == *'Could not resolve host'* ) \
    || "$RUN_OUTPUT" == *'[Errno 13] Permission denied'* ]]
}

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
  local label="$1" command="$2" raw_output transport_rc
  raw_output="$(openshell sandbox exec --name "$NAME" --no-tty --timeout 30 -- \
    sh -c "( $command ); audit_command_rc=\$?; printf '\n__AUDIT_COMMAND_RC=%s\n' \"\$audit_command_rc\"; exit 0" 2>&1)"
  transport_rc=$?
  RUN_INFRA=0
  if [[ "$transport_rc" -ne 0 || ! "$raw_output" =~ __AUDIT_COMMAND_RC=([0-9]+) ]]; then
    RUN_INFRA=1
    RUN_RC=125
    RUN_OUTPUT="$raw_output"
  else
    RUN_RC="${BASH_REMATCH[1]}"
    RUN_OUTPUT="$(printf '%s\n' "$raw_output" | sed '/^__AUDIT_COMMAND_RC=[0-9][0-9]*$/d')"
  fi
  {
    printf '\n===== %s | command_rc=%s | infrastructure_error=%s =====\n' "$label" "$RUN_RC" "$RUN_INFRA"
    printf '%s\n' "$raw_output"
  } >>"$RAWLOG"
}

count_token() {
  local file="$1" token="$2"
  local count rc
  [[ -r "$file" ]] || return 2
  count="$(grep -F -c "$token" "$file" 2>/dev/null)"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then printf '%s\n' "$count"
  elif [[ "$rc" -eq 1 ]]; then printf '0\n'
  else return 2
  fi
}

is_success_http() {
  grep -qE 'HTTP=2[0-9][0-9]' <<<"$1"
}

sandbox_is_healthy() {
  [[ "$(openshell sandbox exec --name "$NAME" --no-tty --timeout 10 -- sh -c 'printf AUDIT_SANDBOX_OK' 2>/dev/null)" == *AUDIT_SANDBOX_OK* ]]
}

origin_is_healthy() {
  local host="$1" port="$2" log="$3" marker="$4" token="${STAMP}-HEALTH-$5" attempt hits
  [[ -r "$log" ]] || return 1
  curl --cacert "$HERE/.state/caddy-root.crt" --resolve "${host}:${port}:127.0.0.1" \
    -fsS --max-time 10 "https://${host}:${port}/public?test=${token}" | grep -Fxq "${marker}_PUBLIC" || return 1
  for ((attempt = 1; attempt <= 10; attempt++)); do
    hits="$(count_token "$log" "$token")" || return 1
    [[ "$hits" -ge 1 ]] && return 0
    sleep 0.2
  done
  return 1
}

evaluate_denial() {
  local id="$1" description="$2" log="$3" host="$4" port="$5" marker="$6" required_marker="${7:-}" denial_kind="${8:-policy-403}" hits denial_signal=0
  hits="$(count_token "$log" "$TOKEN")" || {
    record "$id" INCONCLUSIVE "Origin log could not be read; denial was not proven."
    return
  }
  if [[ "$RUN_INFRA" -ne 0 ]]; then
    record "$id" INCONCLUSIVE "Sandbox execution infrastructure failed; denial was not inferred from that error."
  elif [[ -n "$required_marker" && "$RUN_OUTPUT" != *"$required_marker"* ]]; then
    record "$id" INCONCLUSIVE "The client precondition marker $required_marker was absent."
  elif ! sandbox_is_healthy; then
    record "$id" INCONCLUSIVE "The sandbox health probe failed after the request."
  elif ! origin_is_healthy "$host" "$port" "$log" "$marker" "$id"; then
    record "$id" INCONCLUSIVE "The origin or its audit log was unhealthy after the request."
  else
    case "$denial_kind" in
      policy-403)
        [[ "$RUN_OUTPUT" == *'403 Forbidden'* || "$RUN_OUTPUT" == *'response 403'* || "$RUN_OUTPUT" == *'HTTP=403'* || "$RUN_OUTPUT" == *'"error":"policy_denied"'* ]] && denial_signal=1
        ;;
      direct-timeout)
        [[ "$RUN_RC" -eq 28 && "$RUN_OUTPUT" == *'timed out'* ]] && denial_signal=1
        ;;
    esac
    if [[ "$denial_signal" -eq 0 ]] && boundary_refusal; then
      denial_signal=1
      denial_kind=boundary-refusal
    fi
    if is_success_http "$RUN_OUTPUT" || [[ "$hits" -gt 0 ]]; then
      record "$id" FAIL "The prohibited request succeeded or reached the origin (client rc=$RUN_RC, log hits=$hits)."
    elif [[ "$denial_signal" -eq 1 ]]; then
      record "$id" PASS "$description with an explicit $denial_kind signal (client rc=$RUN_RC, origin log hits=0)."
    else
      record "$id" INCONCLUSIVE "The request did not reach the origin, but no recognized enforcement-denial signal was present (client rc=$RUN_RC)."
    fi
  fi
}

docker exec ft-network-caddy sh -c ': >/logs/host-a.json; : >/logs/host-b.json'
TOKEN_BASE="${STAMP}-BASE"
run_sbx BASELINE "curl -sS --max-time 15 -o /tmp/network-base.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN_BASE}'; rc=\$?; printf '\\n'; cat /tmp/network-base.out 2>/dev/null || true; exit \$rc"
sleep 1
BASE_HITS="$(count_token "$LOG_A" "$TOKEN_BASE")" || BASE_HITS=INVALID
if [[ "$RUN_INFRA" -ne 0 || "$RUN_RC" -ne 0 || "$RUN_OUTPUT" != *'HTTP=200'* || "$RUN_OUTPUT" != *'A_PUBLIC'* || "$BASE_HITS" == INVALID || "$BASE_HITS" -lt 1 ]]; then
  record PRE INCONCLUSIVE 'The allowed control request or its audit log failed; the network suite is not valid.'
  cp "$LOG_A" "$RESULTS_DIR/network-$STAMP-host-a.json"
  cp "$LOG_B" "$RESULTS_DIR/network-$STAMP-host-b.json"
  exit 2
fi
record PRE PASS 'curl reached HOST_A with GET /public and HOST_A logged the token.'

TOKEN="${STAMP}-T01"
run_sbx T01 "curl -sS --max-time 15 -o /tmp/t01.out -w 'HTTP=%{http_code}' 'https://${HOST_B}:${HOST_B_PORT}/public?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t01.out 2>/dev/null || true; exit \$rc"
sleep 1
evaluate_denial T01 'HOST_B was blocked' "$LOG_B" "$HOST_B" "$HOST_B_PORT" B

TOKEN="${STAMP}-T02"
run_sbx T02 "curl -k -sS --noproxy '*' --resolve '${HOST_B}:${HOST_B_PORT}:${POLICY_IP}' --max-time 15 -o /tmp/t02.out -w 'HTTP=%{http_code}' 'https://${HOST_B}:${HOST_B_PORT}/public?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t02.out 2>/dev/null || true; exit \$rc"
sleep 1
evaluate_denial T02 'The direct proxy-bypass attempt was blocked' "$LOG_B" "$HOST_B" "$HOST_B_PORT" B '' direct-timeout

TOKEN="${STAMP}-T03"
run_sbx T03 "python3 -c 'print(\"PYTHON_READY\", flush=True); import urllib.request; print(urllib.request.urlopen(\"https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN}\", timeout=15).status)'"
sleep 1
evaluate_denial T03 'Python was denied by the binary rule' "$LOG_A" "$HOST_A" "$HOST_A_PORT" A PYTHON_READY

TOKEN="${STAMP}-T04"
run_sbx T04 "curl -sS --max-time 15 -X POST -o /tmp/t04.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t04.out 2>/dev/null || true; exit \$rc"
sleep 1
evaluate_denial T04 'POST /public was blocked' "$LOG_A" "$HOST_A" "$HOST_A_PORT" A

TOKEN="${STAMP}-T05"
run_sbx T05 "curl -sS --max-time 15 -o /tmp/t05.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/private?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t05.out 2>/dev/null || true; exit \$rc"
sleep 1
evaluate_denial T05 'GET /private was blocked' "$LOG_A" "$HOST_A" "$HOST_A_PORT" A

TOKEN="${STAMP}-T17"
run_sbx T17 "cp /usr/bin/curl /tmp/curl-copy && chmod 0755 /tmp/curl-copy && test -x /tmp/curl-copy && printf 'COPY_READY\\n' && /tmp/curl-copy -sS --max-time 15 -o /tmp/t17.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t17.out 2>/dev/null || true; exit \$rc"
sleep 1
evaluate_denial T17 'The copied curl binary was denied' "$LOG_A" "$HOST_A" "$HOST_A_PORT" A COPY_READY

TOKEN="${STAMP}-T18"
run_sbx T18 "curl -sS -I --max-time 15 -o /tmp/t18.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t18.out 2>/dev/null || true; exit \$rc"
sleep 1
HITS="$(count_token "$LOG_A" "$TOKEN")" || HITS=INVALID
if [[ "$HITS" == INVALID || "$RUN_INFRA" -ne 0 ]] || ! sandbox_is_healthy || ! origin_is_healthy "$HOST_A" "$HOST_A_PORT" "$LOG_A" A T18; then
  record T18 INCONCLUSIVE 'The sandbox, origin, or audit log was unhealthy; HEAD semantics were not inferred.'
elif is_success_http "$RUN_OUTPUT" && [[ "$HITS" -ge 1 ]]; then
  record T18 EXPECTED "HEAD matched the explicit GET rule by OpenShell design and reached HOST_A (client rc=$RUN_RC, log hits=$HITS)."
else
  record T18 FAIL "HEAD did not match OpenShell's documented implementation semantics (client rc=$RUN_RC, log hits=$HITS)."
fi

TOKEN="${STAMP}-T19"
run_sbx T19 "curl --path-as-is -sS --max-time 15 -o /tmp/t19.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public/../private?test=${TOKEN}'; rc=\$?; printf '\\n'; cat /tmp/t19.out 2>/dev/null || true; exit \$rc"
sleep 1
evaluate_denial T19 'The path-normalization probe was denied' "$LOG_A" "$HOST_A" "$HOST_A_PORT" A

TOKEN="${STAMP}-T20"
run_sbx T20 "curl -sS --max-time 15 -o /tmp/t20.out -w 'HTTP=%{http_code}' 'https://${HOST_A}:${HOST_A_PORT}/public?test=${TOKEN}&value=allowed-query'; rc=\$?; printf '\\n'; cat /tmp/t20.out 2>/dev/null || true; exit \$rc"
sleep 1
HITS="$(count_token "$LOG_A" "$TOKEN")" || HITS=INVALID
if [[ "$HITS" == INVALID || "$RUN_INFRA" -ne 0 ]] || ! sandbox_is_healthy || ! origin_is_healthy "$HOST_A" "$HOST_A_PORT" "$LOG_A" A T20; then
  record T20 INCONCLUSIVE 'The sandbox, origin, or audit log was unhealthy; the positive control is invalid.'
elif [[ "$RUN_RC" -eq 0 && "$RUN_OUTPUT" == *'HTTP=200'* && "$RUN_OUTPUT" == *'A_PUBLIC'* && "$HITS" -ge 1 ]]; then
  record T20 PASS "A permitted GET with a query string reached HOST_A exactly as expected (log hits=$HITS)."
else
  record T20 FAIL "The positive precision control was blocked or not logged (client rc=$RUN_RC, log hits=$HITS)."
fi

TOKEN_STREAM="${STAMP}-T06-STREAM"
TOKEN_NEW="${STAMP}-T06-NEW"
run_sbx T06_START "rm -f /tmp/t06-stream.out /tmp/t06-stream.err /tmp/t06-stream.pid; nohup curl -NsS --max-time 90 'https://${HOST_A}:${HOST_A_PORT}/public?stream=1&test=${TOKEN_STREAM}' > /tmp/t06-stream.out 2>/tmp/t06-stream.err & echo \$! > /tmp/t06-stream.pid"
START_INFRA=$RUN_INFRA
START_RC=$RUN_RC
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
NEW_INFRA=$RUN_INFRA
sleep 1
NEW_HITS="$(count_token "$LOG_A" "$TOKEN_NEW")" || NEW_HITS=INVALID
# The fresh request must be denied: an HTTP 403 from the policy proxy, or (0.1.x only) a boundary refusal.
T06_NEW_DENIED=0
if boundary_refusal || [[ "$RUN_OUTPUT" == *'403 Forbidden'* || "$RUN_OUTPUT" == *'response 403'* || "$RUN_OUTPUT" == *'HTTP=403'* || "$RUN_OUTPUT" == *'"error":"policy_denied"'* ]]; then
  T06_NEW_DENIED=1
fi
if [[ "$START_INFRA" -ne 0 || "$START_RC" -ne 0 || "$STREAM_STARTED" -ne 1 || "$NEW_INFRA" -ne 0 || "$NEW_HITS" == INVALID || "$UPDATE_RC" -ne 0 ]] || ! sandbox_is_healthy || ! origin_is_healthy "$HOST_A" "$HOST_A_PORT" "$LOG_A" A T06; then
  record T06 INCONCLUSIVE "The stream, policy update, sandbox, origin, or audit log had an infrastructure error."
elif [[ "$STREAM_STARTED" -eq 1 && "$STREAM_STOPPED" -eq 1 && "$T06_NEW_DENIED" -eq 1 ]] && ! is_success_http "$RUN_OUTPUT" && [[ "$NEW_HITS" -eq 0 ]]; then
  record T06 PASS 'The old stream stopped after the policy revision, and a new request was blocked with 0 origin-log hits.'
else
  record T06 FAIL "stream_started=$STREAM_STARTED update_rc=$UPDATE_RC stream_stopped=$STREAM_STOPPED new_rc=$RUN_RC new_log_hits=$NEW_HITS."
  openshell sandbox exec --name "$NAME" --no-tty --timeout 10 -- sh -c 'pid=$(cat /tmp/t06-stream.pid 2>/dev/null || true); [ -n "$pid" ] && kill "$pid" 2>/dev/null || true' >/dev/null 2>&1 || true
fi

EVIDENCE_COMPLETE=yes
OPEN_VERSION="$(openshell --version 2>&1 | tail -n 1)" || EVIDENCE_COMPLETE=no
KERNEL="$(uname -r)"
openshell policy get "$NAME" --full >"$RESULTS_DIR/network-$STAMP-effective-policy-final.yaml" 2>&1 || EVIDENCE_COMPLETE=no
openshell logs "$NAME" --source sandbox -n 1000 >"$RESULTS_DIR/network-$STAMP-openshell.log" 2>&1 || EVIDENCE_COMPLETE=no
cp "$HERE/.state/effective-policy-initial.yaml" "$RESULTS_DIR/network-$STAMP-effective-policy-initial.yaml" || EVIDENCE_COMPLETE=no
cp "$LOG_A" "$RESULTS_DIR/network-$STAMP-host-a.json" || EVIDENCE_COMPLETE=no
cp "$LOG_B" "$RESULTS_DIR/network-$STAMP-host-b.json" || EVIDENCE_COMPLETE=no

FAILS=0
INCONCLUSIVES=0
for status in "${STATUSES[@]}"; do
  [[ "$status" == FAIL ]] && FAILS=$((FAILS + 1))
  [[ "$status" == INCONCLUSIVE ]] && INCONCLUSIVES=$((INCONCLUSIVES + 1))
done
[[ "$EVIDENCE_COMPLETE" == yes ]] || INCONCLUSIVES=$((INCONCLUSIVES + 1))

{
  printf '# Network enforcement report\n\n'
  printf -- '- Run: `%s`\n- Evidence complete: `%s`\n- OpenShell: `%s`\n- Kernel: `%s`\n- HOST_A: `%s:%s`\n- HOST_B: `%s:%s`\n- Sandbox: `%s`\n- Failed tests: `%s`\n- Inconclusive tests: `%s`\n\n' "$STAMP" "$EVIDENCE_COMPLETE" "$OPEN_VERSION" "$KERNEL" "$HOST_A" "$HOST_A_PORT" "$HOST_B" "$HOST_B_PORT" "$NAME" "$FAILS" "$INCONCLUSIVES"
  printf '| ID | Status | Evidence |\n|---|---|---|\n'
  for i in "${!IDS[@]}"; do
    printf '| %s | `%s` | %s |\n' "${IDS[$i]}" "${STATUSES[$i]}" "${EVIDENCE[$i]}"
  done
  printf '\n## Evidence files\n\n'
  printf -- '- `network-%s.raw.log`\n- `network-%s-host-a.json`\n- `network-%s-host-b.json`\n- `network-%s-openshell.log`\n- effective policies before and after T06\n' "$STAMP" "$STAMP" "$STAMP" "$STAMP"
} >"$REPORT"

printf 'Report: %s\n' "$REPORT"
[[ "$INCONCLUSIVES" -eq 0 ]] || exit 2
[[ "$FAILS" -eq 0 ]]
