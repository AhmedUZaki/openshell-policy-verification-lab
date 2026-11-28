#!/usr/bin/env bash
# Runs the NemoClaw metamorphic-tier checks from docs/CLAIMS.md, "Policy comparisons":
#   1. Network monotonicity      -- check-tier-monotonicity.mjs (static, offline; no sandbox).
#      Compares the real, vendored NemoClaw tier/preset YAML as text: every destination allowed
#      under a narrower tier must still be allowed under each wider tier.
#   2. Filesystem invariance     -- run-tier-filesystem-invariance.sh (real sandboxes, no
#      internet). Runs the real F1-F4 suite three times, once per tier, with the filesystem
#      policy held identical; the network tier must not change any filesystem result.
#   3. Live network reachability -- run-live-network-reachability.sh +
#      evaluate-live-network-reachability.mjs (real sandboxes AND live internet to two public
#      hosts: pypi.org, wttr.in). The one check that actually proves OpenShell enforces the
#      tier boundary live, not just that the policy text says so.
#
# Usage:
#   bash run-tier-network-and-filesystem-checks.sh                     (1 and 2; no internet)
#   bash run-tier-network-and-filesystem-checks.sh --live               (all three)
#   bash run-tier-network-and-filesystem-checks.sh --monotonicity-only  (1 only)
#   bash run-tier-network-and-filesystem-checks.sh --invariance-only    (2 only)
#   bash run-tier-network-and-filesystem-checks.sh --live-only          (3 only)
#   ... --pairs=restricted:pypi,open:wttr   (with --live or --live-only: run only these of the
#       6 live operations, instead of all of them; see run-live-network-reachability.sh)
#   ... --openshell-version V   (test OpenShell V instead of whatever is active; V must already be
#       installed -- run "bash choose-openshell-version.sh" first. This script never downloads a
#       version itself. Linux/WSL only.)
#   ... --keep-version          (with --openshell-version: do not switch back afterwards)
#
# Exit codes:
#   0  every check that ran passed
#   1  at least one check reported a measured violation
#   2  setup or infrastructure error (a check could not produce a result)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_MONO=1
RUN_INVARIANCE=1
RUN_LIVE=0
PAIRS="all"
OPENSHELL_VERSION=""
KEEP_VERSION=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) RUN_LIVE=1 ;;
    --monotonicity-only) RUN_MONO=1; RUN_INVARIANCE=0; RUN_LIVE=0 ;;
    --invariance-only) RUN_MONO=0; RUN_INVARIANCE=1; RUN_LIVE=0 ;;
    --live-only) RUN_MONO=0; RUN_INVARIANCE=0; RUN_LIVE=1 ;;
    --pairs=*) PAIRS="${1#--pairs=}" ;;
    --openshell-version)
      shift
      OPENSHELL_VERSION="${1:-}"
      [[ -n "$OPENSHELL_VERSION" ]] || { echo "--openshell-version requires a value." >&2; exit 2; }
      ;;
    --keep-version) KEEP_VERSION=1 ;;
    *)
      echo "Usage: $0 [--live|--monotonicity-only|--invariance-only|--live-only] [--pairs=tier:dest,...] [--openshell-version V] [--keep-version]" >&2
      exit 2
      ;;
  esac
  shift
done

export PATH="$HOME/.local/bin:$PATH"
if ! command -v node >/dev/null 2>&1; then
  for candidate in "$HOME"/.nvm/versions/node/*/bin; do
    [[ -x "$candidate/node" ]] && export PATH="$candidate:$PATH" && break
  done
fi
command -v node >/dev/null 2>&1 || { echo "node not found (checked PATH and ~/.nvm/versions/node/*/bin)." >&2; exit 2; }

# Keep audit-reports/tier-checks/ showing only the check(s) run this session: archive the current
# report of whichever of the three checks is NOT selected below into run-history/.
RUNNING_CHECKS=()
[[ $RUN_MONO -eq 1 ]] && RUNNING_CHECKS+=("network-monotonicity")
[[ $RUN_INVARIANCE -eq 1 ]] && RUNNING_CHECKS+=("filesystem-invariance")
[[ $RUN_LIVE -eq 1 ]] && RUNNING_CHECKS+=("live-network-reachability")
node "$ROOT/tests/tier-checks/archive-unrun-checks.mjs" "${RUNNING_CHECKS[@]}"

# shellcheck disable=SC1091
source "$ROOT/tests/shared/openshell-versions.sh"
ORIGINAL_VERSION="$(ovl_current)"
RESTORE_NEEDED=0
[[ -n "$OPENSHELL_VERSION" && "$KEEP_VERSION" == 0 ]] && RESTORE_NEEDED=1
restore_original_version() {
  if [[ $RESTORE_NEEDED -eq 1 && -n "$ORIGINAL_VERSION" && "$(ovl_current)" != "$ORIGINAL_VERSION" ]]; then
    echo "=== Restoring OpenShell $ORIGINAL_VERSION ==="
    ovl_activate_installed "$ORIGINAL_VERSION" || echo "Warning: could not switch back to OpenShell $ORIGINAL_VERSION; run: bash setup/4b-install-openshell-versions.sh use $ORIGINAL_VERSION" >&2
  fi
}
trap restore_original_version EXIT

if [[ -n "$OPENSHELL_VERSION" ]]; then
  ovl_activate_installed "$OPENSHELL_VERSION" || exit 2
fi
printf 'OpenShell version under test: %s\n' "$(ovl_current)"

RUN_ID="${AUDIT_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULT=0
MONO_STATUS="SKIPPED"
INVARIANCE_STATUS="SKIPPED"
LIVE_STATUS="SKIPPED (pass --live or --live-only to run it; needs live internet to pypi.org and wttr.in)"

if [[ $RUN_MONO -eq 1 ]]; then
  printf '\n########## Network monotonicity (offline, no sandbox) ##########\n'
  node "$ROOT/tests/tier-checks/check-tier-monotonicity.mjs"
  case $? in
    0) MONO_STATUS=PASS ;;
    1) MONO_STATUS=FAIL; RESULT=1 ;;
    *) MONO_STATUS=ERROR; [[ $RESULT -lt 2 ]] && RESULT=2 ;;
  esac
fi

if [[ $RUN_INVARIANCE -eq 1 ]]; then
  printf '\n########## Filesystem invariance (real sandboxes, no internet) ##########\n'
  AUDIT_RUN_ID="$RUN_ID" bash "$ROOT/tests/tier-checks/run-tier-filesystem-invariance.sh"
  case $? in
    0) INVARIANCE_STATUS=PASS ;;
    1) INVARIANCE_STATUS=FAIL; RESULT=1 ;;
    *) INVARIANCE_STATUS=ERROR; [[ $RESULT -lt 2 ]] && RESULT=2 ;;
  esac
fi

if [[ $RUN_LIVE -eq 1 ]]; then
  printf '\n########## Live network reachability (real sandboxes + live internet) ##########\n'
  AUDIT_RUN_ID="$RUN_ID" bash "$ROOT/tests/tier-checks/run-live-network-reachability.sh" "$PAIRS"
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
fi

printf '\n========== Summary (run %s) ==========\n' "$RUN_ID"
printf 'Network monotonicity:      %s\n' "$MONO_STATUS"
printf 'Filesystem invariance:     %s\n' "$INVARIANCE_STATUS"
printf 'Live network reachability: %s\n' "$LIVE_STATUS"
printf '\nReports:\n'
[[ $RUN_MONO -eq 1 ]] && printf '  audit-reports/tier-checks/network-monotonicity/TIER-MONOTONICITY.md\n'
[[ $RUN_INVARIANCE -eq 1 ]] && printf '  audit-reports/tier-checks/filesystem-invariance/TIER-FS-INVARIANCE.md\n'
[[ $RUN_LIVE -eq 1 ]] && printf '  audit-reports/tier-checks/live-network-reachability/LIVE-NETWORK-REACHABILITY.md\n'

exit $RESULT
