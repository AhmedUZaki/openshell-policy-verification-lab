#!/usr/bin/env bash
# Read-only readiness check before 4-install-nemoclaw.sh.
# Changes nothing: it only reads versions and status, then prints PASS/FAIL.
#
# Runs on macOS and Linux natively, and on Windows inside WSL (Ubuntu) --
# 1-check-environment.cmd checks WSL and Docker Desktop on the Windows side
# first (installing either one, if missing, is 2-install-wsl.cmd and
# 3-install-docker-desktop.cmd), then runs this same script inside WSL.
#
# Usage:   bash setup/1-check-environment.sh
# Exit code is 0 when every required check passes, 1 otherwise.

set -uo pipefail

export PATH="$HOME/.local/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1

PASS=0; FAIL=0; WARN=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  [WARN] %s\n' "$*"; WARN=$((WARN + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n%s\n' "$*"; }

section "Platform"
OS="$(uname -s)"
case "$OS" in
  Darwin) ok "macOS" ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then ok "Linux (WSL)"; else ok "Linux"; fi ;;
  *) bad "Unsupported OS '$OS'. On Windows, run this inside WSL (Ubuntu)." ;;
esac

section "Base tools"
for t in git curl; do
  if have "$t"; then ok "$t found"; else warn "$t is missing (4-install-nemoclaw.sh installs it: Homebrew on macOS, apt-get/dnf/pacman/zypper on Linux/WSL)"; fi
done

section "Docker"
if have docker; then
  if docker info >/dev/null 2>&1; then
    ok "Docker is installed and the daemon is reachable"
  else
    bad "Docker is installed but the daemon is not reachable (start Docker; on Windows enable WSL integration for this distro)"
  fi
else
  bad "Docker is not installed (Docker Desktop on macOS/Windows, or Docker Engine on Linux)"
fi

section "systemd user service (the OpenShell gateway NemoClaw installs runs as one)"
if [[ "$OS" == "Darwin" ]]; then
  warn "macOS does not use systemd; NemoClaw manages the gateway process its own way there. Not checked here."
elif have systemctl; then
  # "degraded" (some unrelated unit failed) still runs user services fine.
  SD_STATE="$(systemctl --user is-system-running 2>/dev/null || true)"
  case "$SD_STATE" in
    running)  ok "systemd user manager is running" ;;
    degraded) ok "systemd user manager is running (state: degraded -- some unrelated unit failed; harmless here)" ;;
    *) bad "The systemd user manager is not running (state: ${SD_STATE:-none}). In WSL: add [boot] systemd=true to /etc/wsl.conf, then run 'wsl --shutdown' in Windows and reopen Ubuntu. On Linux over SSH: run 'loginctl enable-linger \$USER' and log in again." ;;
  esac
else
  bad "systemctl was not found"
fi

section "Already installed?"
if have nemoclaw; then
  ok "nemoclaw found ($(nemoclaw --version 2>&1 | tail -n 1))"
else
  warn "nemoclaw not installed yet -- that is what 4-install-nemoclaw does"
fi
if have openshell; then
  ok "openshell found ($(openshell --version 2>&1 | tail -n 1))"
fi

if [[ "$OS" != "Darwin" ]]; then
  section "Project files"
  if [[ -d /mnt/c ]]; then
    ok "Windows C: drive is mounted at /mnt/c"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    bad "/mnt/c is not mounted: WSL automount is off"
  fi
fi

printf '\nSummary: %d passed, %d failed, %d warning(s)\n' "$PASS" "$FAIL" "$WARN"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'Not ready. Fix the [FAIL] items above, then run: bash setup/4-install-nemoclaw.sh\n'
  exit 1
fi
printf 'Ready. Run: bash setup/4-install-nemoclaw.sh\n'
