#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
if ! command -v node >/dev/null 2>&1; then
  for node_dir in "$NVM_DIR"/versions/node/*/bin; do
    [[ -x "$node_dir/node" ]] && export PATH="$node_dir:$PATH"
  done
fi
RUN_NETWORK=1
RUN_FILESYSTEM=1
KEEP=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash run-enforcement-audit.sh [--network-only|--filesystem-only] [--keep] [--dry-run]

Exit codes:
  0  all measured expectations passed
  1  at least one measured expectation failed
  2  setup, infrastructure, missing-result, or inconclusive error
EOF
}

for arg in "$@"; do
  case "$arg" in
    --network-only) RUN_NETWORK=1; RUN_FILESYSTEM=0 ;;
    --filesystem-only) RUN_NETWORK=0; RUN_FILESYSTEM=1 ;;
    --keep) KEEP=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$DRY_RUN" == 1 ]]; then
  echo "Platform: $(uname -s)"
  [[ "$RUN_NETWORK" == 1 ]] && echo 'Would run: network setup -> create -> T01-T06 and T17-T20 -> cleanup'
  [[ "$RUN_FILESYSTEM" == 1 ]] && echo 'Would run: filesystem create -> T07-T16 and T21-T36 -> cleanup'
  echo 'Would run: automatic Markdown + JSON analysis'
  exit 0
fi

for tool in bash docker openshell node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 2; }
done
docker info >/dev/null 2>&1 || { echo 'Docker is not reachable.' >&2; exit 2; }
if [[ "$(uname -s)" == Darwin && "$(uname -m)" != arm64 ]]; then
  echo 'This pinned OpenShell release supports the automated macOS gateway workflow on Apple Silicon only.' >&2
  exit 2
fi

INFRA_FAILURE=0

run_network() {
  local result=0
  bash "$ROOT/tests/network/setup-local-test-servers.sh" || result=2
  if [[ "$result" == 0 ]]; then
    bash "$ROOT/tests/network/create-network-test-sandbox.sh" || result=2
  fi
  if [[ "$result" == 0 ]]; then
    bash "$ROOT/tests/network/run-network-tests.sh" || result=$?
  fi
  if [[ "$KEEP" == 0 ]]; then
    bash "$ROOT/tests/network/cleanup-network-test-environment.sh" || result=2
  fi
  return "$result"
}

run_filesystem() {
  local result=0
  bash "$ROOT/tests/filesystem/setup-filesystem-test-environment.sh" || result=2
  if [[ "$result" == 0 ]]; then
    bash "$ROOT/tests/filesystem/run-filesystem-tests.sh" || result=$?
  fi
  if [[ "$KEEP" == 0 ]]; then
    bash "$ROOT/tests/filesystem/cleanup-filesystem-test-environment.sh" || result=2
  fi
  return "$result"
}

if [[ "$RUN_NETWORK" == 1 ]]; then
  echo '=== Network tests T01-T06 and T17-T20 ==='
  run_network || [[ "$?" == 1 ]] || INFRA_FAILURE=1
fi
if [[ "$RUN_FILESYSTEM" == 1 ]]; then
  echo '=== Filesystem tests T07-T16 and T21-T36 ==='
  run_filesystem || [[ "$?" == 1 ]] || INFRA_FAILURE=1
fi

echo '=== Automatic analysis ==='
ANALYSIS_ARGS=()
[[ "$RUN_NETWORK" == 1 && "$RUN_FILESYSTEM" == 0 ]] && ANALYSIS_ARGS+=(--network-only)
[[ "$RUN_NETWORK" == 0 && "$RUN_FILESYSTEM" == 1 ]] && ANALYSIS_ARGS+=(--filesystem-only)
bash "$ROOT/tests/analyze-results.sh" "${ANALYSIS_ARGS[@]}"
ANALYSIS_RC=$?
[[ "$INFRA_FAILURE" == 1 ]] && exit 2
exit "$ANALYSIS_RC"
