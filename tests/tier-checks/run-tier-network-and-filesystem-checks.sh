#!/usr/bin/env bash
# Runs all three NemoClaw metamorphic-tier checks from docs/CLAIMS.md, "Policy comparisons",
# in one command:
#   1. Network monotonicity  -- check-tier-monotonicity.mjs (static, offline; no sandbox)
#   2. Filesystem invariance -- run-tier-filesystem-invariance.sh (real sandboxes, no internet)
#   3. Live network reachability -- run-live-network-reachability.sh +
#      evaluate-live-network-reachability.mjs (real sandboxes AND live internet to two public
#      hosts; opt-in only, since it is the one check in this lab that needs live internet)
#
# Usage:
#   bash tests/tier-checks/run-tier-network-and-filesystem-checks.sh            (1 and 2 only)
#   bash tests/tier-checks/run-tier-network-and-filesystem-checks.sh --live     (all three)
#
# Exit codes:
#   0  every check that ran passed
#   1  at least one check reported a measured violation
#   2  setup or infrastructure error (a check could not produce a result)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIVE=0
for arg in "$@"; do
  case "$arg" in
    --live) LIVE=1 ;;
    *) echo "Usage: $0 [--live]" >&2; exit 2 ;;
  esac
done

export PATH="$HOME/.local/bin:$PATH"
if ! command -v node >/dev/null 2>&1; then
  for candidate in "$HOME"/.nvm/versions/node/*/bin; do
    [[ -x "$candidate/node" ]] && export PATH="$candidate:$PATH" && break
  done
fi
command -v node >/dev/null 2>&1 || { echo "node not found (checked PATH and ~/.nvm/versions/node/*/bin)." >&2; exit 2; }

RUN_ID="${AUDIT_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULT=0

printf '\n########## 1/3  Network monotonicity (offline, no sandbox) ##########\n'
node "$ROOT/tests/tier-checks/check-tier-monotonicity.mjs"
case $? in
  0) MONO_STATUS=PASS ;;
  1) MONO_STATUS=FAIL; RESULT=1 ;;
  *) MONO_STATUS=ERROR; [[ $RESULT -lt 2 ]] && RESULT=2 ;;
esac

printf '\n########## 2/3  Filesystem invariance (real sandboxes, no internet) ##########\n'
AUDIT_RUN_ID="$RUN_ID" bash "$ROOT/tests/tier-checks/run-tier-filesystem-invariance.sh"
case $? in
  0) INVARIANCE_STATUS=PASS ;;
  1) INVARIANCE_STATUS=FAIL; RESULT=1 ;;
  *) INVARIANCE_STATUS=ERROR; [[ $RESULT -lt 2 ]] && RESULT=2 ;;
esac

if [[ $LIVE -eq 1 ]]; then
  printf '\n########## 3/3  Live network reachability (real sandboxes + live internet) ##########\n'
  AUDIT_RUN_ID="$RUN_ID" bash "$ROOT/tests/tier-checks/run-live-network-reachability.sh"
  LIVE_RUN_RC=$?
  if [[ $LIVE_RUN_RC -eq 0 ]]; then
    node "$ROOT/tests/tier-checks/evaluate-live-network-reachability.mjs" "$RUN_ID"
    case $? in
      0) LIVE_STATUS=PASS ;;
      1) LIVE_STATUS=FAIL; RESULT=1 ;;
      *) LIVE_STATUS=ERROR; [[ $RESULT -lt 2 ]] && RESULT=2 ;;
    esac
  else
    LIVE_STATUS=ERROR
    [[ $RESULT -lt 2 ]] && RESULT=2
  fi
else
  LIVE_STATUS="SKIPPED (pass --live to run it; needs live internet to pypi.org and wttr.in)"
fi

printf '\n========== Summary (run %s) ==========\n' "$RUN_ID"
printf '1. Network monotonicity:      %s\n' "$MONO_STATUS"
printf '2. Filesystem invariance:     %s\n' "$INVARIANCE_STATUS"
printf '3. Live network reachability: %s\n' "$LIVE_STATUS"
printf '\nReports:\n'
printf '  audit-reports/tier-checks/network-monotonicity/TIER-MONOTONICITY.md\n'
printf '  audit-reports/tier-checks/filesystem-invariance/TIER-FS-INVARIANCE.md\n'
[[ $LIVE -eq 1 ]] && printf '  audit-reports/tier-checks/live-network-reachability/LIVE-NETWORK-REACHABILITY.md\n'

exit $RESULT
