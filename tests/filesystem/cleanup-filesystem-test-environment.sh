#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/shared/gateway-lifecycle.sh"
STATE_FILE="$ROOT/tests/filesystem/.state/filesystem.env"
export PATH="$HOME/.local/bin:$PATH"

if [[ ! -f "$STATE_FILE" ]]; then
  printf 'No filesystem test state found. Nothing to delete.\n'
  exit 0
fi
# shellcheck disable=SC1090
source "$STATE_FILE"

for name in "$RESTRICTIVE_NAME" "$PERMISSIVE_NAME"; do
  if openshell sandbox list --names 2>/dev/null | grep -Fxq "$name"; then
    openshell sandbox delete "$name"
  fi
done

cleanup_gateway "$ROOT/tests/filesystem/.state"

rm -- "$STATE_FILE"
rm -rf "$ROOT/tests/filesystem/.state"
printf 'Filesystem test sandboxes removed.\n'
