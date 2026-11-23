#!/usr/bin/env bash
# Gateway settings the network suite needs on OpenShell 0.1.x (Linux and WSL, systemd user gateway).
# Source this file; do not execute it.
#
# Why: from 0.1.x a sandbox has no network of its own. Hostnames in the policy are resolved by the
# supervisor (a separate host-network container), which cannot see the lab's Docker network aliases
# such as host-a.test, and which does not trust the local test server's certificate authority.
# So on 0.1.x the lab (1) names the local test servers host.openshell.internal (ports 443 and 444),
# (2) points that name at the test server with drivers.docker.host_gateway_ip, and (3) adds the test
# CA with supervisor.network.additional_ca_bundle. Both are gateway settings read at startup.
#
# Safety: the settings live in two files written only while the network suite runs, the first line
# of the env file marks them as lab-managed, an env file the lab did not create is never touched,
# and the network cleanup removes them and drops them from the running gateway.
# OpenShell 0.0.116 never reaches this code.

LAB_GATEWAY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openshell"
LAB_GATEWAY_ENV="$LAB_GATEWAY_CONFIG_DIR/gateway.env"
LAB_GATEWAY_TOML="$LAB_GATEWAY_CONFIG_DIR/lab-gateway.toml"
LAB_GATEWAY_MARKER="# managed by openshell-policy-verification-lab; removed by the network cleanup"

_LAB_GNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_LAB_GNC_DIR/gateway-lifecycle.sh"

# True for OpenShell 0.1.0 and newer.
lab_openshell_uses_policy_dns() {
  local version major minor
  version="$(openshell --version 2>/dev/null | awk 'NF { v = $NF } END { sub(/^v/, "", v); print v }')"
  IFS=. read -r major minor _ <<<"$version"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  (( major > 0 || minor >= 1 ))
}

lab_gateway_config_is_ours() {
  [[ -f "$LAB_GATEWAY_ENV" ]] && head -n 1 "$LAB_GATEWAY_ENV" | grep -Fxq "$LAB_GATEWAY_MARKER"
}

# lab_apply_gateway_network_config STATE_DIR
# Needs the test servers to be running and the CA copied to STATE_DIR/caddy-root.crt.
lab_apply_gateway_network_config() {
  local state_dir="$1" ca caddy_ip unit was_active=0
  lab_openshell_uses_policy_dns || return 0
  if [[ "$(uname -s)" != Linux ]]; then
    echo 'OpenShell 0.1.x network tests are supported on Linux and WSL only.' >&2
    return 2
  fi
  ca="$state_dir/caddy-root.crt"
  [[ -f "$ca" ]] || { echo "The local test CA is missing: $ca" >&2; return 2; }
  caddy_ip="$(docker inspect ft-network-caddy --format '{{(index .NetworkSettings.Networks "openshell-docker").IPAddress}}' 2>/dev/null)"
  [[ "$caddy_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Could not read the test server address on the openshell-docker network.' >&2; return 2; }
  if [[ -e "$LAB_GATEWAY_ENV" ]] && ! lab_gateway_config_is_ours; then
    echo "Refusing to overwrite $LAB_GATEWAY_ENV: this lab did not create it." >&2
    return 2
  fi
  unit="$(linux_gateway_unit)" || { echo 'No OpenShell gateway user service was found.' >&2; return 2; }

  mkdir -p "$LAB_GATEWAY_CONFIG_DIR"
  (umask 077
   cat >"$LAB_GATEWAY_TOML" <<EOF
[openshell]
version = 2

[openshell.supervisor.network]
additional_ca_bundle = "$ca"

[openshell.drivers.docker]
host_gateway_ip = "$caddy_ip"
EOF
   printf '%s\nOPENSHELL_GATEWAY_CONFIG=%s\n' "$LAB_GATEWAY_MARKER" "$LAB_GATEWAY_TOML" >"$LAB_GATEWAY_ENV")

  systemctl --user is-active --quiet "$unit" && was_active=1
  systemctl --user restart "$unit"
  # A gateway the lab started must be stopped again by the cleanup, as ensure_gateway does.
  [[ "$was_active" == 0 ]] && printf '%s\n' "$unit" >"$state_dir/gateway-service-started-by-tests"
  echo "Applied the lab gateway settings for OpenShell 0.1.x (test server $caddy_ip)."
  ensure_gateway "$state_dir"
}

# lab_remove_gateway_network_config STATE_DIR
lab_remove_gateway_network_config() {
  local state_dir="$1" unit
  lab_gateway_config_is_ours || return 0
  rm -f "$LAB_GATEWAY_ENV" "$LAB_GATEWAY_TOML"
  # Drop the settings from a gateway that keeps running; one the cleanup is about to stop needs nothing.
  if [[ ! -f "$state_dir/gateway-service-started-by-tests" ]] && unit="$(linux_gateway_unit)" \
     && systemctl --user is-active --quiet "$unit"; then
    systemctl --user restart "$unit" >/dev/null 2>&1 || true
  fi
  echo 'Removed the lab gateway settings.'
}
