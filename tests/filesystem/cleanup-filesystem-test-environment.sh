#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/shared/gateway-lifecycle.sh"
STATE_FILE="$ROOT/tests/filesystem/.state/filesystem.env"
export PATH="$HOME/.local/bin:$PATH"

RESTRICTIVE_NAME="ft-fs-restrict"
PERMISSIVE_NAME="ft-fs-permit"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
else
  # An interrupted run may have created sandboxes before writing its state file.
  printf 'No filesystem test state found; checking for leftover sandboxes by name.\n'
fi

for name in "$RESTRICTIVE_NAME" "$PERMISSIVE_NAME"; do
  if openshell sandbox list --names 2>/dev/null | grep -Fxq "$name"; then
    openshell sandbox delete "$name"
  fi
done

cleanup_gateway "$ROOT/tests/filesystem/.state"

rm -f -- "$STATE_FILE"
rm -rf "$ROOT/tests/filesystem/.state"
printf 'Filesystem test sandboxes removed.\n'
