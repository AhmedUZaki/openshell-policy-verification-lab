#!/usr/bin/env bash
# docs/CLAIMS.md's other metamorphic relation: "filesystem invariance only with identical
# filesystem policies." Runs the existing F1-F4 filesystem suite three times, once per NemoClaw
# tier (restricted, balanced, open); each run uses the SAME filesystem_policy
# (policies/filesystem-restrictive.yaml, byte-for-byte) with only that tier's network_policies
# added, so any difference in F1-F4 results across the three runs is a real finding, not an
# artifact of a different filesystem policy.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
if ! command -v node >/dev/null 2>&1; then
  for candidate in "$HOME"/.nvm/versions/node/*/bin; do
    [[ -x "$candidate/node" ]] && export PATH="$candidate:$PATH" && break
  done
fi
command -v node >/dev/null 2>&1 || { printf 'node not found (checked PATH and ~/.nvm/versions/node/*/bin).\n' >&2; exit 2; }
STAMP_BASE="${AUDIT_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"

TIERS=(restricted balanced open)
declare -A RUN_ID
declare -A RUN_EXIT

for tier in "${TIERS[@]}"; do
  printf '\n=== Tier: %s ===\n' "$tier"
  # Committed, not a throwaway state file: see tests/network/nemoclaw-tiers/SOURCE.md.
  policy_file="$ROOT/policies/filesystem-tier-$tier.yaml"
  node "$ROOT/tests/network/nemoclaw-tiers/compose-tier-filesystem-policy.mjs" "$tier" "$policy_file"

  run_id="$STAMP_BASE-tier-$tier"
  RUN_ID[$tier]="$run_id"

  FS_RESTRICTIVE_POLICY="$policy_file" bash "$ROOT/tests/filesystem/setup-filesystem-test-environment.sh"
  AUDIT_RUN_ID="$run_id" bash "$ROOT/tests/filesystem/run-filesystem-tests.sh"
  RUN_EXIT[$tier]=$?
  bash "$ROOT/tests/filesystem/cleanup-filesystem-test-environment.sh"
  printf 'Tier %s: run %s, filesystem-tests exit code %s\n' "$tier" "$run_id" "${RUN_EXIT[$tier]}"
done

# Exit code 2 means infrastructure/inconclusive (not a measured result); 0 or 1 (PASS or a
# measured FAIL) are both valid, comparable outcomes.
ABORTED=()
for tier in "${TIERS[@]}"; do
  if [[ "${RUN_EXIT[$tier]}" -ge 2 ]]; then ABORTED+=("$tier"); fi
done
if [[ ${#ABORTED[@]} -gt 0 ]]; then
  printf '\nTier(s) with an infrastructure/inconclusive run (not comparable): %s\n' "${ABORTED[*]}" >&2
  printf 'See tests/filesystem/results/filesystem-%s*.md for each.\n' "$STAMP_BASE" >&2
  exit 2
fi

node "$ROOT/tests/network/compare-tier-filesystem-results.mjs" \
  "${RUN_ID[restricted]}" "${RUN_ID[balanced]}" "${RUN_ID[open]}"
