#!/usr/bin/env bash

# Shared OpenShell gateway lifecycle for Linux, WSL, and macOS.
export PATH="$HOME/.local/bin:$PATH"
AUDIT_GATEWAY_NAME="${AUDIT_GATEWAY_NAME:-openshell-policy-lab}"

gateway_is_ready() {
  local status
  status="$(openshell status 2>&1 || true)"
  grep -q 'Status:.*Connected' <<<"$status" && grep -q 'Authenticated' <<<"$status"
}

linux_gateway_unit() {
  local unit
  for unit in nemoclaw-openshell-gateway.service openshell-gateway.service; do
    if systemctl --user cat "$unit" >/dev/null 2>&1; then
      printf '%s\n' "$unit"
      return 0
    fi
  done
  return 1
}

ensure_gateway() {
  local state_dir="$1" os port attempt unit
  mkdir -p "$state_dir"
  command -v openshell >/dev/null 2>&1 || { echo 'openshell is not installed.' >&2; return 2; }

  if gateway_is_ready; then
    return 0
  fi

  os="$(uname -s)"
  case "$os" in
    Linux)
      command -v systemctl >/dev/null 2>&1 || { echo 'systemctl is required on Linux/WSL.' >&2; return 2; }
      unit="$(linux_gateway_unit)" || {
        echo 'No supported OpenShell gateway user service was found.' >&2
        echo 'Expected nemoclaw-openshell-gateway.service or openshell-gateway.service.' >&2
        return 2
      }
      if ! systemctl --user is-active --quiet "$unit"; then
        systemctl --user start "$unit"
        printf '%s\n' "$unit" >"$state_dir/gateway-service-started-by-tests"
      fi
      ;;
    Darwin)
      command -v brew >/dev/null 2>&1 || { echo 'Homebrew is required on macOS.' >&2; return 2; }
      if ! brew services list 2>/dev/null | awk '$1 == "openshell" && $2 == "started" {found=1} END {exit !found}'; then
        brew services start openshell
        touch "$state_dir/gateway-service-started-by-tests"
      fi
      ;;
    *)
      echo "Unsupported platform: $os" >&2
      return 2
      ;;
  esac

  for ((attempt = 1; attempt <= 5; attempt++)); do
    gateway_is_ready && return 0
    sleep 1
  done

  if openshell gateway list 2>&1 | grep -qE "(^|[[:space:]])${AUDIT_GATEWAY_NAME}([[:space:]]|$)"; then
    openshell gateway select "$AUDIT_GATEWAY_NAME" >/dev/null
    for ((attempt = 1; attempt <= 10; attempt++)); do
      gateway_is_ready && return 0
      sleep 1
    done
  fi

  for port in "${AUDIT_GATEWAY_PORT:-}" 17670 8080; do
    [[ -n "$port" ]] || continue
    if openshell gateway add "https://127.0.0.1:${port}" --local --name "$AUDIT_GATEWAY_NAME" >/dev/null 2>&1; then
      touch "$state_dir/gateway-registration-added-by-tests"
      openshell gateway select "$AUDIT_GATEWAY_NAME" >/dev/null
      for ((attempt = 1; attempt <= 10; attempt++)); do
        gateway_is_ready && return 0
        sleep 1
      done
      openshell gateway remove "$AUDIT_GATEWAY_NAME" >/dev/null 2>&1 || true
      rm -f "$state_dir/gateway-registration-added-by-tests"
    fi
  done

  echo 'OpenShell gateway could not be started or registered.' >&2
  echo 'Set AUDIT_GATEWAY_PORT if your local gateway uses a custom port.' >&2
  return 2
}

cleanup_gateway() {
  local state_dir="$1" os unit
  if [[ -f "$state_dir/gateway-registration-added-by-tests" ]]; then
    openshell gateway remove "$AUDIT_GATEWAY_NAME" >/dev/null 2>&1 || true
  fi
  if [[ -f "$state_dir/gateway-service-started-by-tests" ]]; then
    os="$(uname -s)"
    if [[ "$os" == Linux ]]; then
      unit="$(cat "$state_dir/gateway-service-started-by-tests" 2>/dev/null || true)"
      [[ -n "$unit" ]] && systemctl --user stop "$unit" >/dev/null 2>&1 || true
    elif [[ "$os" == Darwin ]]; then
      brew services stop openshell >/dev/null 2>&1 || true
    fi
  fi
}
