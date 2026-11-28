#!/usr/bin/env bash
# The ONLY place in this lab that downloads a new OpenShell version. Shows a numbered menu,
# downloads and verifies the choice (via setup/4b-install-openshell-versions.sh), and prints the
# resolved, comma-separated version(s) on stdout (e.g. "0.1.9" or "0.1.9,0.1.10" for "All").
# run-enforcement-audit.sh and run-tier-network-and-filesystem-checks.sh only ACTIVATE an
# already-installed version (ovl_activate_installed in tests/shared/openshell-versions.sh); they
# refuse to download one themselves.
#
# Usage:
#   bash choose-openshell-version.sh                 (single version only; no "All" option)
#   bash choose-openshell-version.sh multi            (adds "All installed, then compare")
#   bash choose-openshell-version.sh single --dry-run (print what would be downloaded; downloads nothing)
#
# choose-openshell-version.cmd is a thin Windows forwarder to this script (via WSL).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-single}"
DRY_RUN_FLAG=""
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN_FLAG="--dry-run"

echo "Which OpenShell version? It is downloaded and verified now, before anything runs." >&2
echo "  1. 0.0.116" >&2
echo "  2. 0.1.9" >&2
echo "  3. 0.1.10" >&2
if [[ "$MODE" == "multi" ]]; then
  echo "  4. All: every version installed on this machine now, then compare them" >&2
  read -r -p "Selection [1-4]: " SEL
else
  read -r -p "Selection [1-3]: " SEL
fi

case "$SEL" in
  1) PREP=0.0.116 ;;
  2) PREP=0.1.9 ;;
  3) PREP=0.1.10 ;;
  4) if [[ "$MODE" == "multi" ]]; then PREP=all; else echo "Invalid selection." >&2; exit 2; fi ;;
  *) echo "Invalid selection." >&2; exit 2 ;;
esac

exec bash "$ROOT/setup/4b-install-openshell-versions.sh" prepare $DRY_RUN_FLAG "$PREP"
