#!/usr/bin/env bash
# Live, read-only reachability proof for two real NemoClaw preset deltas between tiers
# (docs/CLAIMS.md, "Policy comparisons"). check-tier-monotonicity.mjs only reads policy TEXT;
# this creates a real sandbox per tier and makes a real, safe, GET-only request to each public
# host, so it answers "does OpenShell actually enforce this tier boundary" rather than "does
# the policy text claim to" -- the same standard N11 used for its live egress proof.
#
# Destinations (from the vendored presets in tests/tier-checks/nemoclaw-tiers/presets/):
#   - pypi.org   (pypi preset):    absent from Restricted, present from Balanced onward.
#   - wttr.in    (weather preset): absent from Restricted and Balanced, present only in Open.
# Both rules are declared as "allow: { method: GET, path: \"/**\" }" in their preset, so a
# plain GET is the operation actually under test, not a probe-specific workaround.
#
# Usage: run-live-network-reachability.sh [PAIRS]
#   PAIRS: "all" (default), or a comma-separated list of tier:destination pairs to run, e.g.
#          "restricted:pypi,balanced:wttr". Valid tiers: restricted, balanced, open.
#          Valid destinations: pypi, wttr. A tier with no selected destination is skipped
#          entirely (no sandbox is created for it).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PAIRS_ARG="${1:-all}"
export PATH="$HOME/.local/bin:$PATH"
# shellcheck disable=SC1091
source "$ROOT/tests/shared/gateway-lifecycle.sh"

RESULTS_DIR="$ROOT/tests/tier-checks/results"
mkdir -p "$RESULTS_DIR"
STAMP="${AUDIT_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
[[ "$STAMP" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'The run ID contains unsafe characters.' >&2; exit 2; }
RAW_JSON="$RESULTS_DIR/live-network-tier-$STAMP.json"
[[ -e "$RAW_JSON" ]] && { echo "Result file already exists for run ID: $STAMP" >&2; exit 2; }

IMAGE="openshell-policy-verification/filesystem-test-sandbox:local"
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "Image $IMAGE not found. Run tests/enforcement-audit/filesystem/setup-filesystem-test-environment.sh once (it builds this image) or build it directly." >&2
  exit 2
}

ensure_gateway "$RESULTS_DIR/.gateway-state"

TIERS=(restricted balanced open)
DESTS=(pypi wttr)
declare -A URL=( [pypi]="https://pypi.org/simple/" [wttr]="https://wttr.in/?format=3" )

declare -A SELECTED
if [[ "$PAIRS_ARG" == "all" ]]; then
  for tier in "${TIERS[@]}"; do for dest in "${DESTS[@]}"; do SELECTED["$tier:$dest"]=1; done; done
else
  IFS=',' read -r -a pair_list <<<"$PAIRS_ARG"
  for pair in "${pair_list[@]}"; do
    [[ -z "$pair" ]] && continue
    tier="${pair%%:*}"; dest="${pair##*:}"
    valid_tier=0; for t in "${TIERS[@]}"; do [[ "$t" == "$tier" ]] && valid_tier=1; done
    valid_dest=0; for d in "${DESTS[@]}"; do [[ "$d" == "$dest" ]] && valid_dest=1; done
    if [[ $valid_tier -eq 0 || $valid_dest -eq 0 ]]; then
      echo "Invalid pair '$pair' (expected tier:destination, e.g. restricted:pypi)." >&2
      exit 2
    fi
    SELECTED["$tier:$dest"]=1
  done
  if [[ ${#SELECTED[@]} -eq 0 ]]; then
    echo "No valid pairs given. Usage: $0 [all|tier:dest,tier:dest,...]" >&2
    exit 2
  fi
fi

probe() {
  # probe <sandbox-name> <url> -> "rc=<curl exit code> http=<status>00 body=<first 60 bytes>"
  local name="$1" url="$2"
  openshell sandbox exec --name "$name" --no-tty --timeout 20 -- \
    sh -c "rm -f /tmp/probe_body /tmp/probe_err; rc=0; http=\$(curl -sS -o /tmp/probe_body -w '%{http_code}' --max-time 15 '$url' 2>/tmp/probe_err) || rc=\$?; body=\$(head -c 300 /tmp/probe_body 2>/dev/null | tr -d '\n'); err=\$(head -c 80 /tmp/probe_err 2>/dev/null | tr -d '\n'); printf 'rc=%s http=%s body=%s err=%s' \"\$rc\" \"\$http\" \"\$body\" \"\$err\"" 2>&1
}

echo "[" > "$RAW_JSON"
first=1
FAILED_TIERS=()
for tier in "${TIERS[@]}"; do
  tier_has_any=0
  for dest in "${DESTS[@]}"; do [[ -n "${SELECTED[$tier:$dest]:-}" ]] && tier_has_any=1; done
  if [[ $tier_has_any -eq 0 ]]; then
    printf '\n=== Tier: %s (no selected destination; skipped) ===\n' "$tier"
    continue
  fi
  printf '\n=== Tier: %s ===\n' "$tier"
  name="ft-tnet-$tier"
  policy="$ROOT/policies/tier-checks/filesystem-with-network-tier-$tier.yaml"
  openshell sandbox delete "$name" >/dev/null 2>&1 || true
  if ! openshell sandbox create --name "$name" --from "$IMAGE" --policy "$policy" --approval-mode manual --detach; then
    echo "Sandbox creation failed for tier $tier" >&2
    FAILED_TIERS+=("$tier")
    continue
  fi
  for dest in "${DESTS[@]}"; do
    [[ -z "${SELECTED[$tier:$dest]:-}" ]] && continue
    raw="$(probe "$name" "${URL[$dest]}")"
    echo "  $dest -> $raw"
    rc="$(printf '%s' "$raw" | grep -oE 'rc=[0-9]+' | cut -d= -f2)"
    http="$(printf '%s' "$raw" | grep -oE 'http=[0-9]{3}' | cut -d= -f2)"
    body="$(printf '%s' "$raw" | sed -E 's/.*body=(.*) err=.*/\1/')"
    [[ $first -eq 1 ]] && first=0 || echo "," >> "$RAW_JSON"
    printf '{"tier":"%s","destination":"%s","url":"%s","curl_rc":"%s","http_status":"%s","body_sample":"%s"}' \
      "$tier" "$dest" "${URL[$dest]}" "${rc:-null}" "${http:-null}" "${body//\"/\\\"}" >> "$RAW_JSON"
  done
  openshell sandbox delete "$name" >/dev/null 2>&1 || true
done
echo "]" >> "$RAW_JSON"

printf '\nRaw results: %s\n' "${RAW_JSON#"$ROOT"/}"
echo "$STAMP"

if [[ ${#FAILED_TIERS[@]} -gt 0 ]]; then
  printf 'Tier(s) with a sandbox-creation failure (no result collected): %s\n' "${FAILED_TIERS[*]}" >&2
  exit 2
fi
