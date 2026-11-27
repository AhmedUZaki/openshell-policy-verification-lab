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
# Latest stable release known when this file was written; only a menu shortcut and the offline fallback.
# The full, always-current list comes from GitHub (ovl_available_versions).
OPENSHELL_LATEST_KNOWN_VERSION="${OPENSHELL_LATEST_KNOWN_VERSION:-0.1.10}"
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
    # curl -s (without -S) keeps an expected 404 for an optional component quiet
    if ! curl -fLs --retry 3 -o "$tmp/$sums" "$base/$sums" || ! curl -fLs --retry 3 -o "$tmp/$asset" "$base/$asset"; then
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

# _ovl_parse_release_json ARCH: read the GitHub releases JSON on stdin and print the stable releases that ship the
# required Linux components for ARCH, newest first. Exit 1 when the input is not a usable release list.
_ovl_parse_release_json() {
  local arch="$1" json
  json="$(cat)"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | OVL_ARCH="$arch" python3 -c '
import json, os, re, sys
a = os.environ["OVL_ARCH"]
need = ["openshell-%s-unknown-linux-musl.tar.gz" % a,
        "openshell-gateway-%s-unknown-linux-gnu.tar.gz" % a,
        "openshell-sandbox-%s-unknown-linux-musl.tar.gz" % a]
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(1)
found = set()
for r in data:
    if r.get("draft") or r.get("prerelease"):
        continue
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", r.get("tag_name", ""))
    if not m:
        continue
    names = {x.get("name") for x in r.get("assets", [])}
    if all(n in names for n in need):
        found.add(tuple(int(x) for x in m.groups()))
if not found:
    sys.exit(1)
for v in sorted(found, reverse=True):
    print("%d.%d.%d" % v)
'
  else
    # No python3: list every stable-looking tag. Pre-releases and missing assets are not filtered out here;
    # ovl_install still reports a clear error for a release that cannot be installed.
    printf '%s' "$json" | grep -oE '"tag_name": *"v[0-9]+\.[0-9]+\.[0-9]+"' | sed -E 's/.*"v([0-9.]+)"$/\1/' |
      sort -t. -k1,1nr -k2,2nr -k3,3nr -u | grep .
  fi
}

# ovl_available_versions: print the stable OpenShell releases that can be installed on this machine, newest first,
# one per line. The list is read from GitHub every time, so a new release shows up without any change to the lab.
# Sources, in order (each message about a fallback goes to stderr):
#   1. the GitHub releases API (retried): only releases that ship the required Linux components are listed;
#   2. the repository's tag list (git ls-remote), newest 25 - not checked for downloadable builds;
#   3. the releases Atom feed, newest 10 - not checked either;
#   4. the copy saved by the last successful API call.
# ovl_install still reports a clear error for a release that cannot be installed.
# Returns 1 when none of them works; the caller then falls back to a short built-in list.
ovl_available_versions() {
  local arch json list rc=0 note="" cache="$OPENSHELL_VERSION_STORE/.releases-cache" auth=()
  arch="$(ovl_arch)" || arch=x86_64
  # A GitHub token in the environment raises the API limit from 60 to 5000 requests per hour (optional).
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  if command -v curl >/dev/null 2>&1; then
    # --retry covers only temporary failures (timeouts, 5xx, 429); a refusal such as the hourly limit is not retried.
    json="$(curl -fsSL --max-time 25 --retry 2 --retry-delay 1 "${auth[@]}" -H 'Accept: application/vnd.github+json' \
      "${OPENSHELL_API_URL:-https://api.github.com}/repos/$OPENSHELL_RELEASE_REPO/releases?per_page=100" 2>/dev/null)"
    rc=$?
    if [[ "$rc" -eq 0 && -n "$json" ]] && list="$(printf '%s' "$json" | _ovl_parse_release_json "$arch")" && [[ -n "$list" ]]; then
      mkdir -p "$OPENSHELL_VERSION_STORE" 2>/dev/null && printf '%s\n' "$list" >"$cache" 2>/dev/null
      printf '%s\n' "$list"
      return 0
    fi
  else
    rc=127
  fi
  [[ "$rc" -eq 22 ]] && note=" - it refused the request, usually its limit of 60 requests per hour for this network address"
  echo "  (The GitHub releases API did not answer, curl exit code $rc$note; trying other sources.)" >&2
  if command -v git >/dev/null 2>&1 &&
     list="$(timeout 30 git ls-remote --tags "https://github.com/$OPENSHELL_RELEASE_REPO.git" 2>/dev/null |
             grep -oE 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's#refs/tags/v##' |
             sort -t. -k1,1nr -k2,2nr -k3,3nr -u | head -n 25)" && [[ -n "$list" ]]; then
    echo '  (Using the repository tag list: the newest 25 versions, not checked for downloadable builds.)' >&2
    printf '%s\n' "$list"
    return 0
  fi
  if command -v curl >/dev/null 2>&1 &&
     list="$(curl -fsSL --max-time 25 "https://github.com/$OPENSHELL_RELEASE_REPO/releases.atom" 2>/dev/null |
             grep -oE '/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+"' | sed -E 's#.*/v([0-9.]+)"#\1#' |
             sort -t. -k1,1nr -k2,2nr -k3,3nr -u)" && [[ -n "$list" ]]; then
    echo '  (Using the releases feed: the newest 10 versions, not checked for downloadable builds.)' >&2
    printf '%s\n' "$list"
    return 0
  fi
  if [[ -s "$cache" ]]; then
    echo "  (Using the release list saved on $(date -r "$cache" +%Y-%m-%d).)" >&2
    cat "$cache"
    return 0
  fi
  return 1
}

# ovl_pick_versions: interactive picker. The menu goes to stderr, the chosen versions are printed on stdout as a
# comma separated list (suitable for add_versions). Accepts list numbers and/or typed versions (0.1.7 or v0.1.7),
# separated by spaces or commas. Returns 3 when the user cancels (Q), 2 on end of input.
ovl_pick_versions() {
  local out list=() v i sel token n chosen=() existing dup fallback=0
  out="$(ovl_available_versions)" && mapfile -t list <<<"$out"
  if [[ ${#list[@]} -eq 0 || -z "${list[0]:-}" ]]; then
    list=("$OPENSHELL_LATEST_KNOWN_VERSION" "$OPENSHELL_CANDIDATE_VERSION" "$OPENSHELL_BASELINE_VERSION")
    fallback=1
  fi
  while true; do
    {
      printf '\nOpenShell releases available now (newest first):\n'
      for i in "${!list[@]}"; do
        v="${list[$i]}"
        printf '  %2d) %s' "$((i + 1))" "$v"
        [[ "$v" == "$OPENSHELL_BASELINE_VERSION" ]] && printf '   (lab baseline)'
        [[ "$v" == "$OPENSHELL_CANDIDATE_VERSION" ]] && printf '   (lab candidate)'
        [[ "$i" -eq 0 && "$fallback" -eq 0 ]] && printf '   (latest)'
        printf '\n'
      done
      if [[ "$fallback" -eq 1 ]]; then
        printf '  Could not read the release list from GitHub; showing a short built-in list.\n'
        printf '  You can still type any version, for example 0.1.7.\n'
      fi
      printf '  The lab was run in full on %s and %s; another release is run through the same scripts, and an\n' \
        "$OPENSHELL_BASELINE_VERSION" "$OPENSHELL_CANDIDATE_VERSION"
      printf '  incompatibility is reported as INCOMPLETE, never as a pass.\n'
    } >&2
    IFS= read -r -p 'Numbers and/or versions (space or comma separated), Q to cancel: ' sel || return 2
    sel="${sel//$'\r'/}"   # input redirected from a Windows file ends lines with CR
    [[ "$sel" == [qQ] ]] && { echo 'Cancelled.' >&2; return 3; }
    chosen=()
    local bad=0
    for token in ${sel//,/ }; do
      if [[ "$token" =~ ^[0-9]+$ ]]; then
        n=$((10#$token))
        if (( n >= 1 && n <= ${#list[@]} )); then v="${list[$((n - 1))]}"; else
          echo "No release number $token in the list." >&2; bad=1; break
        fi
      else
        v="$(ovl_normalize "$token" 2>/dev/null)" || { echo "'$token' is neither a list number nor a version like 0.1.7." >&2; bad=1; break; }
      fi
      dup=0
      for existing in "${chosen[@]:-}"; do [[ "$existing" == "$v" ]] && dup=1; done
      [[ "$dup" -eq 0 ]] && chosen+=("$v")
    done
    if [[ "$bad" -eq 0 && ${#chosen[@]} -gt 0 ]]; then
      (IFS=,; printf '%s\n' "${chosen[*]}")
      return 0
    fi
    [[ "$bad" -eq 0 ]] && echo 'Nothing selected.' >&2
  done
}

# ovl_installed_versions: the OpenShell versions already stored on this machine (complete downloads), oldest first, as one
# comma separated line. This is what the menu choice "All" means. Returns 1 when nothing is stored yet.
ovl_installed_versions() {
  local d v list=()
  [[ -d "$OPENSHELL_VERSION_STORE" ]] || return 1
  for d in "$OPENSHELL_VERSION_STORE"/*/; do
    [[ -f "${d}.complete" ]] || continue
    v="$(basename "$d")"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && list+=("$v")
  done
  [[ ${#list[@]} -gt 0 ]] || return 1
  printf '%s\n' "${list[@]}" | sort -t. -k1,1n -k2,2n -k3,3n | paste -sd, -
}

# ovl_all_versions: print every available release (see ovl_available_versions) as one comma separated line, newest first.
# Returns 1 when the list cannot be read.
ovl_all_versions() {
  local out
  out="$(ovl_available_versions)" || return 1
  printf '%s\n' "$out" | paste -sd, -
}

# ovl_confirm_all_versions: the interactive "All" choice. Shows what "all" means right now, warns about the size and time,
# asks for a confirmation, and prints the comma separated list on stdout. All messages go to stderr.
# Returns 0 confirmed, 3 declined, 1 when the list cannot be read, 2 on end of input.
ovl_confirm_all_versions() {
  local csv n answer
  csv="$(ovl_all_versions)" || {
    echo '"All" needs the release list from GitHub, which could not be read (offline or rate limited). Choose one version, or try again later.' >&2
    return 1
  }
  n="$(tr ',' '\n' <<<"$csv" | grep -c .)"
  {
    printf '\n"All" means every OpenShell release available now: %s releases\n  %s\n' "$n" "${csv//,/ }"
    printf '  Each release is downloaded (roughly 100-250 MB) and verified, then the tests you choose run on it, one release\n'
    printf '  after another, and the versions are compared. This can take hours. A release the lab cannot run is reported\n'
    printf '  as INCOMPLETE, never as a pass.\n'
  } >&2
  IFS= read -r -p 'Continue with all releases? [y/N]: ' answer || return 2
  answer="${answer//$'\r'/}"
  [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || { echo 'Cancelled.' >&2; return 3; }
  printf '%s\n' "$csv"
}
