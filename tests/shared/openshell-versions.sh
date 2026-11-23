#!/usr/bin/env bash
# Downloads, stores, and switches between OpenShell releases so the same suite
# can be run against several versions.
#
# Supported on Linux and Windows-through-WSL (the layout NemoClaw creates:
# openshell, openshell-gateway, openshell-sandbox in ~/.local/bin and a systemd
# user service for the gateway). On macOS the gateway is owned by Homebrew, so
# switching is not automated there.
#
# Source this file; do not execute it.
#
# Safety properties:
#   - Every release asset is verified against the SHA-256 list published beside
#     it. That detects corruption; it is not an independent authenticity check.
#   - Gateway state is kept per version (gateway@<version>) so a newer gateway
#     never migrates the database an older one will need again.
#   - Release files are kept in the store; activating a version copies them
#     into ~/.local/bin and nothing is ever deleted.

OPENSHELL_BASELINE_VERSION="${OPENSHELL_BASELINE_VERSION:-0.0.116}"
OPENSHELL_CANDIDATE_VERSION="${OPENSHELL_CANDIDATE_VERSION:-0.1.9}"
OPENSHELL_RELEASE_REPO="${OPENSHELL_RELEASE_REPO:-NVIDIA/OpenShell}"
OPENSHELL_VERSION_STORE="${OPENSHELL_VERSION_STORE:-$HOME/.local/share/openshell-lab/versions}"
OPENSHELL_BIN_DIR="${OPENSHELL_BIN_DIR:-$HOME/.local/bin}"

_OVL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_OVL_DIR/gateway-lifecycle.sh"

ovl_log() { printf '[openshell-versions] %s\n' "$*"; }
ovl_err() { printf '[openshell-versions] ERROR: %s\n' "$*" >&2; }

ovl_normalize() {
  local v="${1#v}"
  if [[ ! "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ovl_err "Invalid OpenShell version '$1' (expected a release such as 0.1.9)."
    return 1
  fi
  printf '%s\n' "$v"
}

# Version of the openshell CLI currently first on PATH ("openshell 0.0.116" -> 0.0.116).
ovl_current() {
  openshell --version 2>/dev/null | awk 'NF { v = $NF } END { sub(/^v/, "", v); print v }'
}

ovl_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) return 1 ;;
  esac
}

ovl_require_linux() {
  if [[ "$(uname -s)" != Linux ]]; then
    ovl_err 'Automatic OpenShell version switching is supported on Linux and WSL only. On macOS, install the version you want with Homebrew and run without --openshell-version(s).'
    return 2
  fi
}

# ovl_install VERSION: download and verify one release into the store (no activation).
ovl_install() {
  local v dir arch base tmp spec comp libc required asset sums expected actual found
  v="$(ovl_normalize "$1")" || return 2
  ovl_require_linux || return 2
  dir="$OPENSHELL_VERSION_STORE/$v"
  if [[ -f "$dir/.complete" ]]; then
    ovl_log "OpenShell $v is already in the store."
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    ovl_log "[dry-run] would download and verify OpenShell $v into $dir"
    return 0
  fi
  arch="$(ovl_arch)" || { ovl_err "Unsupported CPU architecture: $(uname -m)."; return 2; }
  local tool
  for tool in curl sha256sum tar install find awk; do
    command -v "$tool" >/dev/null 2>&1 || { ovl_err "Required tool not found: $tool"; return 2; }
  done

  base="https://github.com/$OPENSHELL_RELEASE_REPO/releases/download/v$v"
  tmp="$(mktemp -d)"
  mkdir -p "$dir/bin"
  ovl_log "Downloading OpenShell $v ($arch) from $OPENSHELL_RELEASE_REPO"

  # name:libc:required  (required components must exist; optional ones exist only in newer releases)
  for spec in "openshell:musl:1" "openshell-gateway:gnu:1" "openshell-sandbox:musl:1" "openshell-supervisor:gnu:0"; do
    IFS=: read -r comp libc required <<<"$spec"
    asset="${comp}-${arch}-unknown-linux-${libc}.tar.gz"
    sums="${comp}-checksums-sha256.txt"
    if ! curl -fLsS --retry 3 -o "$tmp/$sums" "$base/$sums" || ! curl -fLsS --retry 3 -o "$tmp/$asset" "$base/$asset"; then
      if [[ "$required" == 0 ]]; then
        ovl_log "  $comp is not part of release v$v; skipped."
        continue
      fi
      ovl_err "Could not download $asset (or its checksum list) for v$v. Does that release exist?"
      rm -rf "$tmp" "$dir"
      return 1
    fi
    expected="$(awk -v a="$asset" '$2 == a || $2 == "*" a { print $1; exit }' "$tmp/$sums")"
    actual="$(sha256sum "$tmp/$asset" | awk '{ print $1 }')"
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
      ovl_err "Checksum check failed for $asset (expected '${expected:-none listed}', got '$actual')."
      rm -rf "$tmp" "$dir"
      return 1
    fi
    mkdir -p "$tmp/x-$comp"
    tar -xzf "$tmp/$asset" -C "$tmp/x-$comp"
    found="$(find "$tmp/x-$comp" -type f -name "$comp" | head -n 1)"
    if [[ -z "$found" ]]; then
      ovl_err "$asset does not contain a file named $comp."
      rm -rf "$tmp" "$dir"
      return 1
    fi
    install -m 0755 "$found" "$dir/bin/$comp"
    ovl_log "  verified and stored $comp"
  done
  rm -rf "$tmp"
  printf '%s\n' "$v" >"$dir/.complete"
  ovl_log "OpenShell $v stored in $dir"
}

# ovl_use VERSION: make VERSION the active openshell/openshell-gateway/openshell-sandbox.
ovl_use() {
  local v dir current state saved unit f name
  v="$(ovl_normalize "$1")" || return 2
  ovl_require_linux || return 2
  ovl_install "$v" || return $?
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    ovl_log "[dry-run] would activate OpenShell $v (stop the gateway, swap binaries and per-version gateway state, restart later)"
    return 0
  fi
  dir="$OPENSHELL_VERSION_STORE/$v"
  current="$(ovl_current)"
  if [[ "$current" == "$v" ]]; then
    ovl_log "OpenShell $v is already active."
    return 0
  fi

  if unit="$(linux_gateway_unit)"; then
    systemctl --user stop "$unit" >/dev/null 2>&1 || true
  fi

  state="${XDG_STATE_HOME:-$HOME/.local/state}/openshell/gateway"
  if [[ -n "$current" && -d "$state" ]]; then
    saved="$state@$current"
    [[ -e "$saved" ]] && saved="$saved.$(date +%Y%m%d%H%M%S)"
    mv "$state" "$saved"
    ovl_log "Saved gateway state of $current as $(basename "$saved")."
  fi
  if [[ -d "$state@$v" ]]; then
    mv "$state@$v" "$state"
    ovl_log "Restored the gateway state of $v."
  fi

  mkdir -p "$OPENSHELL_BIN_DIR"
  for f in "$dir"/bin/*; do
    name="$(basename "$f")"
    install -m 0755 "$f" "$OPENSHELL_BIN_DIR/.$name.new"
    mv -f "$OPENSHELL_BIN_DIR/.$name.new" "$OPENSHELL_BIN_DIR/$name"
  done

  hash -r 2>/dev/null || true
  if [[ "$(ovl_current)" != "$v" ]]; then
    ovl_err "After activation 'openshell --version' reports '$(ovl_current)', not $v. Check that $OPENSHELL_BIN_DIR comes first in PATH."
    return 1
  fi
  ovl_log "OpenShell $v is now active (the gateway is started by the next test run)."
}

ovl_list() {
  local active d v
  active="$(ovl_current)"
  [[ -d "$OPENSHELL_VERSION_STORE" ]] || { ovl_log "No versions stored yet in $OPENSHELL_VERSION_STORE."; return 0; }
  for d in "$OPENSHELL_VERSION_STORE"/*/; do
    [[ -f "$d/.complete" ]] || continue
    v="$(basename "$d")"
    printf '  %s%s\n' "$v" "$([[ "$v" == "$active" ]] && printf '  (active)')"
  done
}
