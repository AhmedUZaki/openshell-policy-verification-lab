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
RUN_NETWORK=0
RUN_FILESYSTEM=0
SCOPE=""
KEEP=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash run-enforcement-audit.sh [--all|--network-only|--filesystem-only] [--keep] [--dry-run]

When run interactively without a scope option, the runner asks the user to
choose network tests, filesystem tests, or both. Non-interactive jobs must
provide an explicit scope option.

Exit codes:
  0  all measured expectations passed
  1  at least one measured expectation failed
  2  setup, infrastructure, missing-result, or inconclusive error
EOF
}

for arg in "$@"; do
  case "$arg" in
    --all)
      [[ -z "$SCOPE" || "$SCOPE" == all ]] || { echo 'Choose only one test scope.' >&2; exit 2; }
      SCOPE=all
      ;;
    --network-only)
      [[ -z "$SCOPE" || "$SCOPE" == network ]] || { echo 'Choose only one test scope.' >&2; exit 2; }
      SCOPE=network
      ;;
    --filesystem-only)
      [[ -z "$SCOPE" || "$SCOPE" == filesystem ]] || { echo 'Choose only one test scope.' >&2; exit 2; }
      SCOPE=filesystem
      ;;
    --keep) KEEP=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$SCOPE" ]]; then
  if [[ -t 0 ]]; then
    while [[ -z "$SCOPE" ]]; do
      printf '\nChoose the tests to run / اختر الاختبارات:\n'
      printf '  1) Both network and filesystem / الشبكة والملفات\n'
      printf '  2) Network only / الشبكة فقط\n'
      printf '  3) Filesystem only / الملفات فقط\n'
      printf '  Q) Quit / خروج\n'
      read -r -p 'Selection / الاختيار: ' choice
      case "$choice" in
        1) SCOPE=all ;;
        2) SCOPE=network ;;
        3) SCOPE=filesystem ;;
        q|Q) echo 'Cancelled.'; exit 0 ;;
        *) echo 'Invalid selection. Enter 1, 2, 3, or Q.' >&2 ;;
      esac
    done
  else
    echo 'No test scope was selected. Use --all, --network-only, or --filesystem-only.' >&2
    exit 2
  fi
fi

case "$SCOPE" in
  all) RUN_NETWORK=1; RUN_FILESYSTEM=1 ;;
  network) RUN_NETWORK=1 ;;
  filesystem) RUN_FILESYSTEM=1 ;;
esac

if [[ "$DRY_RUN" == 1 ]]; then
  echo "Platform: $(uname -s)"
  [[ "$RUN_NETWORK" == 1 ]] && echo 'Would run: network setup -> create -> T01-T06 and T17-T20 -> cleanup'
  [[ "$RUN_FILESYSTEM" == 1 ]] && echo 'Would run: filesystem create -> T07-T16 and T21-T36 -> cleanup'
  echo 'Would create and verify a signed SHA-256 evidence manifest'
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
AUDIT_RUN_ID="${AUDIT_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
[[ "$AUDIT_RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'AUDIT_RUN_ID contains unsafe characters.' >&2; exit 2; }
if [[ ( "$RUN_NETWORK" == 1 && ( -e "$ROOT/tests/network/results/network-$AUDIT_RUN_ID.md" || -e "$ROOT/tests/network/results/network-$AUDIT_RUN_ID.raw.log" ) ) || ( "$RUN_FILESYSTEM" == 1 && ( -e "$ROOT/tests/filesystem/results/filesystem-$AUDIT_RUN_ID.md" || -e "$ROOT/tests/filesystem/results/filesystem-$AUDIT_RUN_ID.raw.log" ) ) || -e "$ROOT/evidence-attestations/evidence-$AUDIT_RUN_ID.manifest.json" || -e "$ROOT/evidence-attestations/evidence-$AUDIT_RUN_ID.sig" || -e "$ROOT/evidence-attestations/evidence-$AUDIT_RUN_ID.public.pem" ]]; then
  echo "Audit run ID already exists: $AUDIT_RUN_ID. Choose a new ID or archive the old reports." >&2
  exit 2
fi
export AUDIT_RUN_ID
printf 'Audit run ID: %s\n' "$AUDIT_RUN_ID"

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

ANALYSIS_ARGS=()
[[ "$RUN_NETWORK" == 1 && "$RUN_FILESYSTEM" == 0 ]] && ANALYSIS_ARGS+=(--network-only)
[[ "$RUN_NETWORK" == 0 && "$RUN_FILESYSTEM" == 1 ]] && ANALYSIS_ARGS+=(--filesystem-only)
echo '=== Evidence attestation ==='
node "$ROOT/tests/evidence-attestation.mjs" create --run-id "$AUDIT_RUN_ID" "${ANALYSIS_ARGS[@]}" || INFRA_FAILURE=1
echo '=== Automatic analysis ==='
bash "$ROOT/tests/analyze-results.sh" "${ANALYSIS_ARGS[@]}" --run-id "$AUDIT_RUN_ID"
ANALYSIS_RC=$?
[[ "$INFRA_FAILURE" == 1 ]] && exit 2
exit "$ANALYSIS_RC"
