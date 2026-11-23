#!/usr/bin/env bash
# Removes what setup/1..4 installed on the Linux/WSL/macOS side, one item at a
# time, chosen by number. Windows-only items (Docker Desktop, the Ubuntu WSL
# distro) live in 5-uninstall-everything.cmd, which calls this script.
#
# Usage:
#   bash setup/5-uninstall-everything.sh                  -- interactive menu
#   DRY_RUN=1 bash setup/5-uninstall-everything.sh        -- show what would be removed, change nothing
#   bash setup/5-uninstall-everything.sh --items "1 3" --yes   -- used by the .cmd (it already asked)
#
# Every removal is by fixed path or by name match (nemoclaw|openshell); items
# that are not there are skipped, so re-running is safe.

set -uo pipefail

DRY_RUN="${DRY_RUN:-0}"
ITEMS=""; YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --items) ITEMS="${2:-}"; ITEMS="${ITEMS//,/ }"; shift 2 ;;
    --yes)   YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -n "${HOME:-}" && "$HOME" != "/" ]] || { echo "HOME is not set safely; refusing to continue." >&2; exit 2; }

OS="$(uname -s)"
have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '    %s\n' "$*"; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1
export PATH="$HOME/.local/bin:$PATH"

BIN_NAMES="nemoclaw nemoclaw-acp nemohermes nemo-deepagents nemoclaw-blueprint-runner openshell openshell-gateway openshell-sandbox"
GATEWAY_UNIT="nemoclaw-openshell-gateway"

describe() {
  case "$1" in
    1) echo "Docker containers, images and volumes whose name contains nemoclaw or openshell (this is where the sandboxes live)" ;;
    2) echo "The OpenShell gateway service ($GATEWAY_UNIT): stopped, disabled, unit file deleted" ;;
    3) echo "The commands nemoclaw/openshell/nemohermes/... in ~/.local/bin, and the npm global package 'nemoclaw'" ;;
    4) echo "The folder ~/.nemoclaw (the pinned NemoClaw source and installer marker) and ~/.local/share/openshell-lab (downloaded OpenShell versions)" ;;
    5) echo "nvm and every Node.js it installed (~/.nvm), plus the nvm lines in ~/.bashrc, ~/.zshrc, ~/.profile. WARNING: other tools of yours may use this Node" ;;
  esac
}

remove_item() {
  case "$1" in
    1)
      if ! have docker || ! docker info >/dev/null 2>&1; then log "Docker is not reachable; skipped (start Docker and run this item again)."; return; fi
      local ids imgs vols
      ids="$(docker ps -a --format '{{.ID}} {{.Names}} {{.Image}}' | grep -Ei 'nemoclaw|openshell' | awk '{print $1}')"
      imgs="$(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' | grep -Ei 'nemoclaw|openshell' | awk '{print $1}' | sort -u)"
      vols="$(docker volume ls --format '{{.Name}}' | grep -Ei 'nemoclaw|openshell')"
      if [[ -n "$ids"  ]]; then run docker rm -f $ids;          else log "No matching containers."; fi
      if [[ -n "$imgs" ]]; then run docker rmi -f $imgs;        else log "No matching images."; fi
      if [[ -n "$vols" ]]; then run docker volume rm -f $vols;  else log "No matching volumes."; fi
      ;;
    2)
      if [[ "$OS" == "Darwin" ]]; then log "macOS: the gateway is managed by launchd/Homebrew, not removed automatically. Check 'launchctl list | grep -i openshell'."; return; fi
      if have systemctl && systemctl --user list-unit-files 2>/dev/null | grep -q "$GATEWAY_UNIT"; then
        run systemctl --user disable --now "$GATEWAY_UNIT"
      else
        log "Service not registered."
      fi
      if [[ -f "$HOME/.config/systemd/user/$GATEWAY_UNIT.service" ]]; then
        run rm -f "$HOME/.config/systemd/user/$GATEWAY_UNIT.service"
        have systemctl && run systemctl --user daemon-reload
      fi
      ;;
    3)
      if have npm && npm ls -g --depth=0 2>/dev/null | grep -q ' nemoclaw@'; then run npm uninstall -g nemoclaw; else log "No npm global 'nemoclaw' package."; fi
      local n d
      for n in $BIN_NAMES; do
        [[ -e "$HOME/.local/bin/$n" || -L "$HOME/.local/bin/$n" ]] && run rm -f "$HOME/.local/bin/$n"
        for d in "$NVM_DIR"/versions/node/*/bin; do
          [[ -L "$d/$n" ]] && run rm -f "$d/$n"
        done
      done
      ;;
    4)
      if [[ -d "$HOME/.nemoclaw" ]]; then run rm -rf "$HOME/.nemoclaw"; else log "~/.nemoclaw not found."; fi
      # OpenShell releases downloaded by 4b-install-openshell-versions.sh
      if [[ -d "$HOME/.local/share/openshell-lab" ]]; then run rm -rf "$HOME/.local/share/openshell-lab"; fi
      ;;
    5)
      local rc
      for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        [[ -f "$rc" ]] && grep -q 'NVM_DIR' "$rc" || continue
        run cp "$rc" "$rc.bak-uninstall"
        # shortcut: drops every line that mentions NVM_DIR; if you added your own nvm lines, restore from the .bak-uninstall copy
        run sed -i.tmp '/NVM_DIR/d' "$rc" && run rm -f "$rc.tmp"
        [[ "$DRY_RUN" == "1" ]] || log "Cleaned $rc (backup: $rc.bak-uninstall)"
      done
      if [[ -d "$NVM_DIR" ]]; then run rm -rf "$NVM_DIR"; else log "~/.nvm not found."; fi
      ;;
  esac
}

# --- choose ------------------------------------------------------------
if [[ -z "$ITEMS" ]]; then
  printf '\nThis will DELETE things from this machine. Choose what to remove:\n\n'
  for i in 1 2 3 4 5; do printf '  %s) %s\n' "$i" "$(describe "$i")"; done
  printf '  0) All of the above (1-5)\n\n'
  printf 'Numbers separated by spaces or commas (e.g. 1 3 4), 0 for all, anything else to quit: '
  read -r CHOICE || exit 1
  CHOICE="${CHOICE//,/ }"
  if [[ "$CHOICE" == "0" ]]; then ITEMS="1 2 3 4 5"; else ITEMS="$CHOICE"; fi
fi

SELECTED=""
for i in $ITEMS; do
  case "$i" in
    [1-5]) [[ " $SELECTED " == *" $i "* ]] || SELECTED="$SELECTED $i" ;;
    *) printf 'Not a valid choice: %s. Nothing was changed.\n' "$i"; exit 1 ;;
  esac
done
SELECTED="$(printf '%s\n' $SELECTED | sort -n | tr '\n' ' ')"
[[ -n "${SELECTED// /}" ]] || { echo "Nothing selected. Nothing was changed."; exit 0; }

if [[ "$YES" != "1" ]]; then
  printf '\nYou chose to DELETE:\n'
  for i in $SELECTED; do printf '  %s) %s\n' "$i" "$(describe "$i")"; done
  [[ "$DRY_RUN" == "1" ]] && printf '\n(dry run: nothing will actually be deleted)\n'
  printf '\nThis cannot be undone. Type DELETE to continue, anything else cancels: '
  read -r CONFIRM || exit 1
  [[ "$CONFIRM" == "DELETE" ]] || { echo "Cancelled. Nothing was changed."; exit 0; }
fi

# Always run in a safe order: containers, service, commands, files, nvm last.
for i in $SELECTED; do
  printf '\n[%s] %s\n' "$i" "$(describe "$i")"
  remove_item "$i"
done

printf '\nDone.'
[[ "$DRY_RUN" == "1" ]] && printf ' (dry run: nothing was deleted)'
printf '\n'
