#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$ROOT/tests/filesystem/.state"
STATE_FILE="$STATE_DIR/filesystem.env"
RESTRICTIVE_NAME="ft-fs-restrict"
PERMISSIVE_NAME="ft-fs-permit"
source "$ROOT/tests/shared/gateway-lifecycle.sh"

export PATH="$HOME/.local/bin:$PATH"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 2
  }
}

need openshell
need docker

docker info >/dev/null 2>&1 || {
  printf 'Docker is not reachable. Start Docker Desktop and enable WSL integration.\n' >&2
  exit 2
}

ensure_gateway "$STATE_DIR"

for name in "$RESTRICTIVE_NAME" "$PERMISSIVE_NAME"; do
  if openshell sandbox list --names 2>/dev/null | grep -Fxq "$name"; then
    printf 'Sandbox already exists: %s\nRun tests/filesystem/cleanup-filesystem-test-environment.sh first.\n' "$name" >&2
    exit 2
  fi
done

mkdir -p "$STATE_DIR" "$ROOT/tests/filesystem/results"

cleanup_partial() {
  openshell sandbox delete "$RESTRICTIVE_NAME" >/dev/null 2>&1 || true
  openshell sandbox delete "$PERMISSIVE_NAME" >/dev/null 2>&1 || true
}
trap cleanup_partial ERR

printf 'Building the test image and creating the restrictive sandbox...\n'
openshell sandbox create \
  --name "$RESTRICTIVE_NAME" \
  --from "$ROOT/filesystem-test-sandbox" \
  --policy "$ROOT/policies/filesystem-restrictive.yaml" \
  --approval-mode manual \
  --detach

printf 'Creating the permissive control sandbox...\n'
openshell sandbox create \
  --name "$PERMISSIVE_NAME" \
  --from "$ROOT/filesystem-test-sandbox" \
  --policy "$ROOT/policies/filesystem-permissive.yaml" \
  --approval-mode manual \
  --detach

for name in "$RESTRICTIVE_NAME" "$PERMISSIVE_NAME"; do
  openshell sandbox exec --name "$name" --no-tty --timeout 30 -- \
    sh -c 'test "$(id -u)" = 1500 && command -v python3 >/dev/null && command -v sha256sum >/dev/null'
done

cat >"$STATE_FILE" <<EOF
RESTRICTIVE_NAME=$RESTRICTIVE_NAME
PERMISSIVE_NAME=$PERMISSIVE_NAME
GATEWAY_NAME=$AUDIT_GATEWAY_NAME
EOF

trap - ERR
printf 'Ready. State: %s\n' "$STATE_FILE"
printf 'Next: bash tests/filesystem/run-filesystem-tests.sh\n'
