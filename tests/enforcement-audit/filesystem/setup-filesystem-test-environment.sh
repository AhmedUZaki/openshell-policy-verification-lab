#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STATE_DIR="$ROOT/tests/enforcement-audit/filesystem/.state"
STATE_FILE="$STATE_DIR/filesystem.env"
RESTRICTIVE_NAME="ft-fs-restrict"
PERMISSIVE_NAME="ft-fs-permit"
# Override for tier-invariance testing (tests/tier-checks/run-tier-filesystem-invariance.sh): same
# filesystem_policy as policies/enforcement-audit/filesystem-restrictive.yaml, with one NemoClaw tier's
# network_policies added. Defaults to the unmodified file, so normal runs are unaffected.
RESTRICTIVE_POLICY="${FS_RESTRICTIVE_POLICY:-$ROOT/policies/enforcement-audit/filesystem-restrictive.yaml}"
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
    printf 'Sandbox already exists: %s\nRun tests/enforcement-audit/filesystem/cleanup-filesystem-test-environment.sh first.\n' "$name" >&2
    exit 2
  fi
done

mkdir -p "$STATE_DIR" "$ROOT/tests/enforcement-audit/filesystem/results"

cleanup_partial() {
  openshell sandbox delete "$RESTRICTIVE_NAME" >/dev/null 2>&1 || true
  openshell sandbox delete "$PERMISSIVE_NAME" >/dev/null 2>&1 || true
}
trap cleanup_partial ERR

# Build the image with the local container engine and pass its tag: OpenShell 0.1.x no longer
# builds a Dockerfile or directory given to --from, and older versions accept an image tag too.
FS_IMAGE="openshell-policy-verification/filesystem-test-sandbox:local"
printf 'Building the test image %s...\n' "$FS_IMAGE"
docker build -q -t "$FS_IMAGE" "$ROOT/filesystem-test-sandbox" >/dev/null

printf 'Creating the restrictive sandbox...\n'
openshell sandbox create \
  --name "$RESTRICTIVE_NAME" \
  --from "$FS_IMAGE" \
  --policy "$RESTRICTIVE_POLICY" \
  --approval-mode manual \
  --detach

printf 'Creating the permissive control sandbox...\n'
openshell sandbox create \
  --name "$PERMISSIVE_NAME" \
  --from "$FS_IMAGE" \
  --policy "$ROOT/policies/enforcement-audit/filesystem-permissive.yaml" \
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
printf 'Next: bash tests/enforcement-audit/filesystem/run-filesystem-tests.sh\n'
