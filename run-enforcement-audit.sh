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
# shellcheck disable=SC1091
source "$ROOT/tests/shared/openshell-versions.sh"
RUN_NETWORK=0
RUN_FILESYSTEM=0
SCOPE=""
KEEP=0
DRY_RUN=0
KEEP_VERSION=0
CHOOSE_VERSION=0
ALL_INSTALLED=0
ALL_AVAILABLE=0
EARLY_DOWNLOAD=0
VERSIONS=()

usage() {
  cat <<'EOF'
Usage: bash run-enforcement-audit.sh [--all|--network-only|--filesystem-only] [--keep] [--dry-run]
                                     [--openshell-version V]... [--openshell-versions V1,V2] [--compare]
                                     [--choose-version] [--all-installed] [--all-available] [--keep-version]

When run interactively without a scope option, the runner first asks (Linux/WSL)
which OpenShell version(s) to test unless a version option was given, then asks
the user to choose network tests, filesystem tests, or both. Non-interactive jobs must
provide an explicit scope option.

OpenShell versions (Linux and WSL only):
  (none)                     test the OpenShell that is installed now
  --openshell-version V      test release V (repeat the option to test several)
  --openshell-versions A,B   same, comma separated
  --compare                  test the baseline (0.0.116) and candidate (0.1.9) and write audit-reports/COMPARISON.md
  --choose-version           list every OpenShell release available on GitHub right now (a new release appears
                             automatically) and pick one or more by number or by typing the version
  --all-installed            test every OpenShell version already installed on this machine (the menu choice "All")
  --all-available            test EVERY release available on GitHub right now, one after another, and compare them
                             (many downloads; can take hours)
  --keep-version             do not switch back to the original version afterwards
Each version gets its own run ID (<id>-os<version>) and its own report. Versions
are downloaded and verified on first use; see setup/4b-install-openshell-versions.sh.

Exit codes:
  0  all measured expectations passed
  1  at least one measured expectation failed
  2  setup, infrastructure, missing-result, or inconclusive error
EOF
}

add_versions() {
  local list="$1" item normalized
  IFS=, read -ra items <<<"$list"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || continue
    normalized="$(ovl_normalize "$item")" || exit 2
    local existing
    for existing in "${VERSIONS[@]:-}"; do [[ "$existing" == "$normalized" ]] && continue 2; done
    VERSIONS+=("$normalized")
  done
}

while [[ $# -gt 0 ]]; do
  arg="$1"
  shift
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
    --keep-version) KEEP_VERSION=1 ;;
    --compare) add_versions "$OPENSHELL_BASELINE_VERSION,$OPENSHELL_CANDIDATE_VERSION" ;;
    --choose-version) CHOOSE_VERSION=1 ;;
    --all-installed) ALL_INSTALLED=1 ;;
    --all-available) ALL_AVAILABLE=1 ;;
    --openshell-version|--openshell-versions)
      [[ $# -gt 0 ]] || { echo "$arg needs a value, for example: $arg 0.1.9" >&2; exit 2; }
      add_versions "$1"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# --all-installed: every OpenShell version already stored on this machine (Linux and WSL only).
if [[ "$ALL_INSTALLED" -eq 1 ]]; then
  ovl_require_linux || exit 2
  inst_csv="$(ovl_installed_versions)" || { echo 'No OpenShell version is installed yet; install one first (setup/4b-install-openshell-versions.sh install V).' >&2; exit 2; }
  add_versions "$inst_csv"
fi

# --all-available: every release available on GitHub now (Linux and WSL only). The list is read at run time, so a new release is included.
if [[ "$ALL_AVAILABLE" -eq 1 ]]; then
  ovl_require_linux || exit 2
  all_csv="$(ovl_all_versions)" || { echo 'Could not read the release list from GitHub; --all-available needs it.' >&2; exit 2; }
  add_versions "$all_csv"
fi

# --choose-version: show the releases available on GitHub now and let the user pick (Linux and WSL only).
if [[ "$CHOOSE_VERSION" -eq 1 ]]; then
  ovl_require_linux || exit 2
  picked="$(ovl_pick_versions)"
  pick_rc=$?
  case "$pick_rc" in
    0) add_versions "$picked"; EARLY_DOWNLOAD=1 ;;
    3) exit 0 ;;
    *) echo 'No OpenShell version was chosen.' >&2; exit 2 ;;
  esac
fi

# Interactive run without scope or version options: first ask which OpenShell version(s) to test (Linux and WSL
# only, the only place the runner can switch versions), then the scope. Scripts and CI pass their options and are never asked.
if [[ -z "$SCOPE" && -t 0 && ${#VERSIONS[@]} -eq 0 && "$(uname -s)" == Linux ]]; then
  choice=""
  while [[ -z "$choice" ]]; do
    printf '\nChoose the OpenShell version to test / اختر إصدار OpenShell:\n'
    printf '  1) %s\n' "$OPENSHELL_BASELINE_VERSION"
    printf '  2) %s\n' "$OPENSHELL_CANDIDATE_VERSION"
    printf '  3) %s\n' "$OPENSHELL_LATEST_KNOWN_VERSION"
    printf '  4) All: every OpenShell version installed on this machine now, then compare them\n'
    printf '  5) Another version: list every release available now\n'
    printf '  Q) Quit / خروج\n'
    read -r -p 'Selection / الاختيار: ' choice
    case "$choice" in
      1) add_versions "$OPENSHELL_BASELINE_VERSION"; EARLY_DOWNLOAD=1 ;;
      2) add_versions "$OPENSHELL_CANDIDATE_VERSION"; EARLY_DOWNLOAD=1 ;;
      3) add_versions "$OPENSHELL_LATEST_KNOWN_VERSION"; EARLY_DOWNLOAD=1 ;;
      4)
        if inst_csv="$(ovl_installed_versions)"; then
          echo "\"All\" = the installed versions: ${inst_csv//,/ }"
          add_versions "$inst_csv"; EARLY_DOWNLOAD=1
        else
          echo 'No OpenShell version is installed yet. Choose a version first; it is downloaded and kept, then "All" can use it.' >&2
          choice=""
        fi
        ;;
      5)
        picked="$(ovl_pick_versions)"
        pick_rc=$?
        case "$pick_rc" in
          0) add_versions "$picked"; EARLY_DOWNLOAD=1 ;;
          3) exit 0 ;;   # the picker already printed "Cancelled."
          *) echo 'No OpenShell version was chosen.' >&2; exit 2 ;;
        esac
        ;;
      q|Q) echo 'Cancelled.'; exit 0 ;;
      *) echo 'Invalid selection. Enter 1, 2, 3, 4, 5, or Q.' >&2; choice="" ;;
    esac
  done
fi

# A version chosen interactively is downloaded and verified now, before the question about which tests to run.
# A release that cannot be installed is dropped with a message; the run stops only if none is left.
if [[ "$EARLY_DOWNLOAD" -eq 1 && ${#VERSIONS[@]} -gt 0 ]]; then
  ready_versions=()
  for v in "${VERSIONS[@]}"; do
    if ovl_install "$v"; then ready_versions+=("$v"); else echo "Skipping $v: it could not be installed." >&2; fi
  done
  [[ ${#ready_versions[@]} -gt 0 ]] || { echo 'No OpenShell version could be installed.' >&2; exit 2; }
  VERSIONS=("${ready_versions[@]}")
fi

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
  if [[ ${#VERSIONS[@]} -gt 0 ]]; then
    echo "Would test OpenShell versions: ${VERSIONS[*]} (each downloaded and verified on first use, original version restored afterwards)"
    [[ ${#VERSIONS[@]} -ge 2 ]] && echo 'Would write audit-reports/COMPARISON.md, COMPARISON_AR.md and COMPARISON.json'
  fi
  echo 'Would move previous results to archived-results/<previous-run-id>/'
  [[ "$RUN_NETWORK" == 1 ]] && echo 'Would run: network setup -> create -> N01-N06 and N07-N10 -> cleanup'
  [[ "$RUN_FILESYSTEM" == 1 ]] && echo 'Would run: filesystem create -> F1_1-F2_5 and F2_6-F1_2 -> cleanup'
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
if [[ ${#VERSIONS[@]} -gt 0 ]]; then
  ovl_require_linux || exit 2
fi

BASE_RUN_ID="${AUDIT_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
[[ "$BASE_RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'AUDIT_RUN_ID contains unsafe characters.' >&2; exit 2; }

echo '=== Archiving previous results ==='
node "$ROOT/tests/archive-previous-results.mjs" || echo 'Warning: some previous results could not be archived; the analyzer still reads only this run ID.' >&2

run_network() {
  local result=0
  echo 'Removing leftovers of any interrupted earlier network run...'
  bash "$ROOT/tests/network/cleanup-network-test-environment.sh" || echo 'Warning: leftover cleanup reported a problem; continuing.' >&2
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
  echo 'Removing leftovers of any interrupted earlier filesystem run...'
  bash "$ROOT/tests/filesystem/cleanup-filesystem-test-environment.sh" || echo 'Warning: leftover cleanup reported a problem; continuing.' >&2
  bash "$ROOT/tests/filesystem/setup-filesystem-test-environment.sh" || result=2
  if [[ "$result" == 0 ]]; then
    bash "$ROOT/tests/filesystem/run-filesystem-tests.sh" || result=$?
  fi
  if [[ "$KEEP" == 0 ]]; then
    bash "$ROOT/tests/filesystem/cleanup-filesystem-test-environment.sh" || result=2
  fi
  return "$result"
}

# Complete audit of the OpenShell that is active now, under the run ID in AUDIT_RUN_ID.
# Returns the analysis exit code (0, 1) or 2 for any infrastructure problem.
run_audit() {
  local infra_failure=0 analysis_args=() analysis_rc
  if [[ ( "$RUN_NETWORK" == 1 && ( -e "$ROOT/tests/network/results/network-$AUDIT_RUN_ID.md" || -e "$ROOT/tests/network/results/network-$AUDIT_RUN_ID.raw.log" ) ) || ( "$RUN_FILESYSTEM" == 1 && ( -e "$ROOT/tests/filesystem/results/filesystem-$AUDIT_RUN_ID.md" || -e "$ROOT/tests/filesystem/results/filesystem-$AUDIT_RUN_ID.raw.log" ) ) || -e "$ROOT/evidence-attestations/evidence-$AUDIT_RUN_ID.manifest.json" || -e "$ROOT/evidence-attestations/evidence-$AUDIT_RUN_ID.sig" || -e "$ROOT/evidence-attestations/evidence-$AUDIT_RUN_ID.public.pem" ]]; then
    echo "Audit run ID already exists: $AUDIT_RUN_ID. Choose a new ID or archive the old reports." >&2
    return 2
  fi
  export AUDIT_RUN_ID
  printf 'Audit run ID: %s\n' "$AUDIT_RUN_ID"
  printf 'OpenShell version under test: %s\n' "$(ovl_current)"

  if [[ "$RUN_NETWORK" == 1 ]]; then
    echo '=== Network tests N01-N06 and N07-N10 ==='
    run_network || [[ "$?" == 1 ]] || infra_failure=1
  fi
  if [[ "$RUN_FILESYSTEM" == 1 ]]; then
    echo '=== Filesystem tests F1_1-F2_5 and F2_6-F1_2 ==='
    run_filesystem || [[ "$?" == 1 ]] || infra_failure=1
  fi

  [[ "$RUN_NETWORK" == 1 && "$RUN_FILESYSTEM" == 0 ]] && analysis_args+=(--network-only)
  [[ "$RUN_NETWORK" == 0 && "$RUN_FILESYSTEM" == 1 ]] && analysis_args+=(--filesystem-only)
  echo '=== Evidence attestation ==='
  node "$ROOT/tests/evidence-attestation.mjs" create --run-id "$AUDIT_RUN_ID" "${analysis_args[@]}" || infra_failure=1
  echo '=== Automatic analysis ==='
  bash "$ROOT/tests/analyze-results.sh" "${analysis_args[@]}" --run-id "$AUDIT_RUN_ID"
  analysis_rc=$?
  [[ "$infra_failure" == 1 ]] && return 2
  return "$analysis_rc"
}

# Remove any test sandboxes still held by the OpenShell that is active now.
cleanup_active_version() {
  bash "$ROOT/tests/network/cleanup-network-test-environment.sh" >/dev/null 2>&1 || true
  bash "$ROOT/tests/filesystem/cleanup-filesystem-test-environment.sh" >/dev/null 2>&1 || true
}

ORIGINAL_VERSION=""
RESTORE_NEEDED=0
restore_original_version() {
  [[ "$RESTORE_NEEDED" == 1 ]] || return 0
  RESTORE_NEEDED=0
  if [[ -n "$ORIGINAL_VERSION" && "$(ovl_current)" != "$ORIGINAL_VERSION" ]]; then
    echo "=== Restoring OpenShell $ORIGINAL_VERSION ==="
    cleanup_active_version
    ovl_use "$ORIGINAL_VERSION" || echo "Warning: could not switch back to OpenShell $ORIGINAL_VERSION; run: bash setup/4b-install-openshell-versions.sh use $ORIGINAL_VERSION" >&2
  fi
}

if [[ ${#VERSIONS[@]} -eq 0 ]]; then
  AUDIT_RUN_ID="$BASE_RUN_ID"
  run_audit
  exit $?
fi

ORIGINAL_VERSION="$(ovl_current)"
[[ "$KEEP_VERSION" == 0 ]] && RESTORE_NEEDED=1
trap restore_original_version EXIT

FINAL_RC=0
for version in "${VERSIONS[@]}"; do
  echo
  echo "################ OpenShell $version ################"
  cleanup_active_version
  if ! ovl_use "$version"; then
    echo "Skipping OpenShell $version: it could not be installed or activated." >&2
    FINAL_RC=2
    continue
  fi
  AUDIT_RUN_ID="$BASE_RUN_ID-os$version"
  export AUDIT_REQUESTED_OPENSHELL_VERSION="$version"
  run_audit
  rc=$?
  [[ "$rc" -gt "$FINAL_RC" ]] && FINAL_RC="$rc"
done

if [[ ${#VERSIONS[@]} -ge 2 ]]; then
  echo '=== Version comparison ==='
  node "$ROOT/tests/compare-versions.mjs" || FINAL_RC=2
fi
exit "$FINAL_RC"
