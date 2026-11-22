#!/usr/bin/env bash
# Installs NemoClaw (which, as part of its own install, installs OpenShell
# and its gateway too) at a pinned version, so this project can test
# NemoClaw's own claims -- its default policies, its tiers (Restricted,
# Balanced, Open, Personal), and the OpenShell enforcement underneath them.
#
# Runs on macOS and Linux natively, and on Windows inside WSL (Ubuntu) --
# 4-install-nemoclaw.cmd is the Windows entry point; it just forwards into WSL
# and runs this same script there. Nothing here is Windows- or WSL-specific
# except the final PATH hint.
#
# Usage:
#   bash setup/4-install-nemoclaw.sh
#   DRY_RUN=1 bash setup/4-install-nemoclaw.sh   -- print what would run, change nothing
#
# This script does NOT run `nemoclaw onboard`: it installs the CLI and the
# OpenShell gateway only (--defer-onboarding), with no sandbox, no model
# provider and no credentials. Re-runs are safe: once the pinned version has
# installed, it is skipped.
#
# Why NEMOCLAW_AGENT=hermes below: the installer only accepts --defer-onboarding
# for agents whose agents/<name>/manifest.yaml has deferred_onboarding: true
# (hermes, langchain-deepagents-code); the default, openclaw, does not. The
# agent is never onboarded here, so the tools installed (nemoclaw, openshell,
# the gateway) are the same either way; pick any agent later with
# `nemoclaw onboard --agent <name>`.

set -Eeuo pipefail

# Pinned versions. NemoClaw's own installer is what fetches OpenShell and its
# gateway service, so there is no separate OpenShell pin here.
NEMOCLAW_VERSION="0.0.140"
# A tag can be moved; the commit it must resolve to cannot (checked after checkout).
NEMOCLAW_COMMIT="88fe14f3fb9a0bf72997cce19ec88b5b2ee08391"
NEMOCLAW_REPO="https://github.com/NVIDIA/NemoClaw.git"
SOURCE_DIR="$HOME/.nemoclaw/source"
DRY_RUN="${DRY_RUN:-0}"

TOTAL_STEPS=5
STEP=0
step() { STEP=$((STEP + 1)); printf '\n[%s/%s] %s\n' "$STEP" "$TOTAL_STEPS" "$*"; }
log()  { printf '    %s\n' "$*"; }
fail() { printf '\n[install] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

# Non-interactive shells skip .bashrc's nvm setup, so node can look "missing"
# even when it is installed via nvm. Load it here if present.
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1
export PATH="$HOME/.local/bin:$PATH"

step "Checking the platform"
OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM="mac" ;;
  Linux)  PLATFORM="linux" ;;
  *)      fail "Unsupported OS '$OS'. On Windows, run 4-install-nemoclaw.cmd instead (it uses WSL)." ;;
esac
log "Detected platform: $PLATFORM"

step "Checking base tools (git, curl)"
if have git && have curl; then
  log "git and curl already installed."
elif [[ "$PLATFORM" == "mac" ]]; then
  have brew || fail "Homebrew is required on macOS. Install it from https://brew.sh then re-run."
  have git  || run brew install git
  have curl || run brew install curl
elif have apt-get; then
  log "Installing git and curl (asks for your sudo password)"
  run sudo apt-get update
  run sudo apt-get install -y ca-certificates curl git
elif have dnf; then
  log "Installing git and curl (asks for your sudo password)"
  run sudo dnf install -y ca-certificates curl git
elif have pacman; then
  log "Installing git and curl (asks for your sudo password)"
  run sudo pacman -S --needed --noconfirm ca-certificates curl git
elif have zypper; then
  log "Installing git and curl (asks for your sudo password)"
  run sudo zypper --non-interactive install ca-certificates curl git
else
  fail "Install git and curl with your package manager, then re-run."
fi

step "Checking Docker"
if [[ "$DRY_RUN" != "1" ]]; then
  have docker || fail "Docker is not installed. Install Docker Desktop (mac) or Docker Engine (Linux; on Windows, Docker Desktop with WSL integration), then re-run."
  docker info >/dev/null 2>&1 || fail "Docker is installed but not running. Start it, then re-run."
fi
log "Docker is reachable."

step "Installing NemoClaw $NEMOCLAW_VERSION (brings OpenShell and its gateway with it)"
# Marker written after a successful install: the CLI's own --version does not
# match the tag name (it reports package.json's version).
MARKER="$SOURCE_DIR/.installed-tag"
nemoclaw_ok() { have nemoclaw && [[ "$(cat "$MARKER" 2>/dev/null)" == "v$NEMOCLAW_VERSION" ]]; }

if nemoclaw_ok; then
  log "NemoClaw $NEMOCLAW_VERSION already installed; nothing to do."
else
  have node || log "Node.js was not found; NemoClaw's installer installs it (through nvm) when needed."
  log "Fetching the pinned NemoClaw source (v$NEMOCLAW_VERSION) into $SOURCE_DIR"
  if [[ -d "$SOURCE_DIR/.git" ]]; then
    run git -C "$SOURCE_DIR" fetch --depth 1 origin "v$NEMOCLAW_VERSION"
  else
    run mkdir -p "$(dirname "$SOURCE_DIR")"
    run git clone --no-checkout --depth 1 "$NEMOCLAW_REPO" "$SOURCE_DIR"
    run git -C "$SOURCE_DIR" fetch --depth 1 origin "v$NEMOCLAW_VERSION"
  fi
  # Pin the working tree to the fetched tag itself, not to whatever the
  # default branch points to.
  run git -C "$SOURCE_DIR" checkout -qf --detach FETCH_HEAD
  if [[ "$DRY_RUN" != "1" ]]; then
    [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" == "$NEMOCLAW_COMMIT" ]] \
      || fail "v$NEMOCLAW_VERSION no longer points at the expected commit $NEMOCLAW_COMMIT. Refusing to run its installer; check the tag upstream."
  fi

  log "Installing the NemoClaw CLI, OpenShell and its gateway (no onboarding, no sandbox, no credentials)"
  export NEMOCLAW_NON_INTERACTIVE=1
  export NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1
  export NEMOCLAW_AGENT=hermes
  run bash "$SOURCE_DIR/scripts/install.sh" --non-interactive --defer-onboarding

  if [[ "$DRY_RUN" != "1" ]]; then
    # nvm installs node (and nemoclaw) during the step above, so reload it.
    [[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1
    have nemoclaw || fail "nemoclaw was not found after install."
    echo "v$NEMOCLAW_VERSION" > "$MARKER"
  fi
fi

step "Verifying"
if [[ "$DRY_RUN" == "1" ]]; then
  printf '\n=======================================================\n'
  printf ' Dry run finished -- nothing was changed.\n'
  printf '=======================================================\n'
  exit 0
fi
log "nemoclaw: $(nemoclaw --version 2>&1 | tail -n 1)"
log "openshell: $(openshell --version 2>&1 | tail -n 1)"

printf '\n=======================================================\n'
printf ' DONE. NemoClaw %s and OpenShell are installed.\n' "$NEMOCLAW_VERSION"
printf '=======================================================\n'
printf "If 'nemoclaw' or 'openshell' are not found in a NEW terminal, add this\n"
printf 'to your shell profile (~/.bashrc, ~/.zshrc, ...):\n'
printf '  export PATH="$HOME/.local/bin:$PATH"\n'
