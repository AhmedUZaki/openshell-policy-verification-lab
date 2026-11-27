#!/usr/bin/env bash
# Downloads specific OpenShell releases into a local store so the lab can run
# the same tests against several versions. Run it after 4-install-nemoclaw.
#
# Usage:
#   bash setup/4b-install-openshell-versions.sh                    # download the baseline (0.0.116) and candidate (0.1.9)
#   bash setup/4b-install-openshell-versions.sh install 0.1.5 0.1.9  # download any releases you want
#   bash setup/4b-install-openshell-versions.sh use 0.1.9          # make 0.1.9 the active version
#   bash setup/4b-install-openshell-versions.sh list               # show stored versions
#   bash setup/4b-install-openshell-versions.sh available          # show every release on GitHub you can install now (always current)
#   bash setup/4b-install-openshell-versions.sh prepare choose     # pick from that list, download and verify, print the chosen versions
#   bash setup/4b-install-openshell-versions.sh prepare all        # every version already installed here (what the menu choice "All" means)
#   bash setup/4b-install-openshell-versions.sh prepare all-available  # every release on GitHub right now (asks to confirm; hours)
#   bash setup/4b-install-openshell-versions.sh prepare 0.1.10     # download and verify these versions, print them
#   (options after "prepare": --dry-run only prints what would be downloaded; --out FILE writes the result line to FILE)
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
  available)
    if available="$(ovl_available_versions)"; then
      ovl_log "Releases you can install now (newest first; read from GitHub just now):"
      printf '  %s\n' $available
    else
      ovl_err "Could not read the release list from GitHub (offline or rate limited). Try again later, or install a version you know: install 0.1.10"
      exit 1
    fi
    ;;
  prepare)
    # Used by run-enforcement-audit.cmd: choose and download BEFORE the test menu. Every message goes to stderr (the
    # console). The versions that are ready are written as ONE comma separated line to the file given with --out (the
    # launcher reads it; a file is used because a command run inside the batch "for /f" does not receive console input),
    # or to the original stdout when --out is not given.
    exec 3>&1 1>&2
    rest=()
    out_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --out) shift; out_file="${1:-}" ;;
        *) rest+=("$1") ;;
      esac
      shift
    done
    set -- "${rest[@]}"
    sel="${1:-}"
    csv=""
    rc=0
    case "$sel" in
      all)
        csv="$(ovl_installed_versions)" || { ovl_err 'No OpenShell version is installed yet. Choose a version first (it is downloaded and kept), then "All" can use it.'; exit 1; }
        ovl_log "\"All\" = the OpenShell versions installed on this machine now: ${csv//,/ }"
        ;;
      all-available) csv="$(ovl_confirm_all_versions)"; rc=$? ;;
      choose)        csv="$(ovl_pick_versions)"; rc=$? ;;
      "")            echo 'Usage: 4b-install-openshell-versions.sh prepare all | all-available | choose | VERSION [VERSION ...]' >&2; exit 2 ;;
      *)             csv="$(printf '%s,' "$@")"; csv="${csv%,}" ;;
    esac
    [[ "$rc" -eq 0 ]] || exit "$rc"
    ready=()
    IFS=, read -ra wanted <<<"$csv"
    for v in "${wanted[@]}"; do
      v="$(ovl_normalize "$v")" || continue
      if ovl_install "$v"; then ready+=("$v"); else ovl_err "Skipping $v: it could not be installed."; fi
    done
    [[ ${#ready[@]} -gt 0 ]] || { ovl_err 'No OpenShell version could be prepared.'; exit 1; }
    result="$(IFS=,; printf '%s' "${ready[*]}")"
    if [[ -n "$out_file" ]]; then printf '%s\r\n' "$result" >"$out_file"; else printf '%s\n' "$result" >&3; fi
    ;;
  current)
    ovl_current
    ;;
  -h|--help|help)
    sed -n '2,19p' "${BASH_SOURCE[0]}"
    ;;
  *)
    echo "Unknown command: $command (use install, use, list, available, prepare, or current)." >&2
    exit 2
    ;;
esac
