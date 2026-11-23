#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/network"
source "$ROOT/tests/shared/gateway-lifecycle.sh"
source "$ROOT/tests/shared/gateway-network-config.sh"
STATE_FILE="$HERE/.state/network.env"
export PATH="$HOME/.local/bin:$PATH"

NAME="ft-network"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi
# Delete by name even without a state file: an interrupted run may have created the sandbox first.
if openshell sandbox list --names 2>/dev/null | grep -Fxq "$NAME"; then
  openshell sandbox delete "$NAME"
fi

lab_remove_gateway_network_config "$HERE/.state"
cleanup_gateway "$HERE/.state"

docker compose -f "$HERE/local-test-servers/compose.yaml" down -v
docker image rm openshell-policy-verification/network-test-sandbox:local >/dev/null 2>&1 || true
rm -f "$HERE/network-test-sandbox/caddy-root.crt"
rm -rf "$HERE/.state" "$HERE/local-test-servers/.runtime"
echo 'Removed the network sandbox and local HTTPS origins. Results were preserved.'
