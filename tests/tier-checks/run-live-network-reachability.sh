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
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

probe() {
  # probe <sandbox-name> <url> -> "rc=<curl exit code> http=<status>00 body=<first 60 bytes>"
  local name="$1" url="$2"
  openshell sandbox exec --name "$name" --no-tty --timeout 20 -- \
    sh -c "rm -f /tmp/probe_body /tmp/probe_err; rc=0; http=\$(curl -sS -o /tmp/probe_body -w '%{http_code}' --max-time 15 '$url' 2>/tmp/probe_err) || rc=\$?; body=\$(head -c 300 /tmp/probe_body 2>/dev/null | tr -d '\n'); err=\$(head -c 80 /tmp/probe_err 2>/dev/null | tr -d '\n'); printf 'rc=%s http=%s body=%s err=%s' \"\$rc\" \"\$http\" \"\$body\" \"\$err\"" 2>&1
}

echo "[" > "$RAW_JSON"
first=1
for tier in "${TIERS[@]}"; do
  printf '\n=== Tier: %s ===\n' "$tier"
  name="ft-tnet-$tier"
  policy="$ROOT/policies/tier-checks/filesystem-with-network-tier-$tier.yaml"
  openshell sandbox delete "$name" >/dev/null 2>&1 || true
  if ! openshell sandbox create --name "$name" --from "$IMAGE" --policy "$policy" --approval-mode manual --detach; then
    echo "Sandbox creation failed for tier $tier" >&2
    continue
  fi
  for dest in "${DESTS[@]}"; do
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
