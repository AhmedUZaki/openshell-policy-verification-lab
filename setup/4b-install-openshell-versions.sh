#!/usr/bin/env bash
# Downloads specific OpenShell releases into a local store so the lab can run
# the same tests against several versions. Run it after 4-install-nemoclaw.
#
# Usage:
#   bash setup/4b-install-openshell-versions.sh                    # download the baseline (0.0.116) and candidate (0.1.9)
#   bash setup/4b-install-openshell-versions.sh install 0.1.5 0.1.9  # download any releases you want
#   bash setup/4b-install-openshell-versions.sh use 0.1.9          # make 0.1.9 the active version
#   bash setup/4b-install-openshell-versions.sh list               # show stored versions
#   bash setup/4b-install-openshell-versions.sh current            # show the active version
#   DRY_RUN=1 bash setup/4b-install-openshell-versions.sh ...      # print what would happen
#
# Downloading never changes the active version. `run-enforcement-audit.sh
# --openshell-version X` (or --openshell-versions A,B / --compare) activates the
# versions it needs itself and puts the original version back afterwards.
# Linux and WSL only; releases come from https://github.com/NVIDIA/OpenShell.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
# shellcheck disable=SC1091
source "$ROOT/tests/shared/openshell-versions.sh"

command="${1:-install}"
[[ $# -gt 0 ]] && shift

case "$command" in
  install)
    versions=("$@")
    [[ ${#versions[@]} -gt 0 ]] || versions=("$OPENSHELL_BASELINE_VERSION" "$OPENSHELL_CANDIDATE_VERSION")
    status=0
    for v in "${versions[@]}"; do
      ovl_install "$v" || status=$?
    done
    ovl_log "Stored versions:"
    ovl_list
    ovl_log "Active version: $(ovl_current)  (downloading does not change it)"
    exit "$status"
    ;;
  use)
    [[ $# -eq 1 ]] || { echo 'Usage: 4b-install-openshell-versions.sh use VERSION' >&2; exit 2; }
    ovl_use "$1"
    ;;
  list)
    ovl_list
    ;;
  current)
    ovl_current
    ;;
  -h|--help|help)
    sed -n '2,15p' "${BASH_SOURCE[0]}"
    ;;
  *)
    echo "Unknown command: $command (use install, use, list, or current)." >&2
    exit 2
    ;;
esac
