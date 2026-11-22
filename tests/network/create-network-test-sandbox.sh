#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/network"
STATE_DIR="$HERE/.state"
ORIGIN_STATE="$STATE_DIR/origin.env"
STATE_FILE="$STATE_DIR/network.env"
NAME="ft-network"
source "$ROOT/tests/shared/gateway-lifecycle.sh"

export PATH="$HOME/.local/bin:$PATH"
for tool in openshell docker curl; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'Missing command: %s\n' "$tool" >&2; exit 2; }
done
[[ -f "$ORIGIN_STATE" ]] || { echo 'Run tests/network/setup-local-test-servers.cmd first.' >&2; exit 2; }
# shellcheck disable=SC1090
source "$ORIGIN_STATE"

curl --cacert "$STATE_DIR/caddy-root.crt" --resolve "${HOST_A}:${HOST_A_PORT}:127.0.0.1" \
  -fsS --max-time 10 "https://${HOST_A}:${HOST_A_PORT}/public" | grep -Fxq 'A_PUBLIC' || {
  echo 'HOST_A is not reachable with trusted HTTPS. Run setup step 0 again.' >&2
  exit 2
}
curl --cacert "$STATE_DIR/caddy-root.crt" --resolve "${HOST_B}:${HOST_B_PORT}:127.0.0.1" \
  -fsS --max-time 10 "https://${HOST_B}:${HOST_B_PORT}/public" | grep -Fxq 'B_PUBLIC' || {
  echo 'HOST_B is not reachable with trusted HTTPS. Run setup step 0 again.' >&2
  exit 2
}

ensure_gateway "$STATE_DIR"

if openshell sandbox list --names 2>/dev/null | grep -Fxq "$NAME"; then
  echo 'Sandbox ft-network already exists. Run cleanup step 3 first.' >&2
  exit 2
fi

cleanup_partial() {
  openshell sandbox delete "$NAME" >/dev/null 2>&1 || true
}
trap cleanup_partial ERR

if [[ "$(uname -s)" == Darwin ]]; then
  SANDBOX_SOURCE="$HERE/network-test-sandbox"
else
  SANDBOX_SOURCE="openshell-policy-verification/network-test-sandbox:local"
fi

openshell sandbox create \
  --name "$NAME" \
  --from "$SANDBOX_SOURCE" \
  --policy "$ROOT/policies/network-deny-all-base-policy.yaml" \
  --approval-mode manual \
  --env "HOST_A=$HOST_A" \
  --env "HOST_A_PORT=$HOST_A_PORT" \
  --env "HOST_B=$HOST_B" \
  --env "HOST_B_PORT=$HOST_B_PORT" \
  --env "ORIGIN_IP=$ORIGIN_IP" \
  --detach

if [[ "$(uname -s)" == Darwin ]]; then
  POLICY_IP="$(openshell sandbox exec --name "$NAME" --no-tty --timeout 20 -- \
    sh -c 'awk '\''$2 == "host.openshell.internal" && $1 ~ /^[0-9]+\./ {print $1; exit}'\'' /etc/hosts' 2>/dev/null)"
  POLICY_IPV6="$(openshell sandbox exec --name "$NAME" --no-tty --timeout 20 -- \
    sh -c 'awk '\''$2 == "host.openshell.internal" && $1 ~ /:/ {print $1; exit}'\'' /etc/hosts' 2>/dev/null)"
else
  POLICY_IP="$(docker inspect ft-network-caddy \
    --format '{{(index .NetworkSettings.Networks "openshell-docker").IPAddress}}')"
  POLICY_IPV6=""
fi
[[ "$POLICY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Could not resolve Docker host inside the sandbox: %s\n' "$POLICY_IP" >&2
  exit 2
}

GENERATED_POLICY="$STATE_DIR/network-generated.yaml"
cat >"$GENERATED_POLICY" <<EOF
version: 1
filesystem_policy:
  include_workdir: false
  read_only:
    - /usr
    - /lib
    - /etc
    - /proc
    - /dev/urandom
    - /var/log
  read_write:
    - /tmp
    - /dev/null
    - /dev/pts
    - /work
landlock:
  compatibility: hard_requirement
process:
  run_as_user: "1500"
  run_as_group: "1500"
network_policies:
  allow_host_a:
    name: allow_host_a
    endpoints:
      - host: "$HOST_A"
        port: $HOST_A_PORT
        protocol: rest
        enforcement: enforce
        rules:
          - allow:
              method: GET
              path: /public
        allowed_ips:
          - "$POLICY_IP/32"
EOF
if [[ -n "$POLICY_IPV6" ]]; then
  printf '          - "%s/128"\n' "$POLICY_IPV6" >>"$GENERATED_POLICY"
fi
cat >>"$GENERATED_POLICY" <<'EOF'
    binaries:
      - path: /usr/bin/curl
EOF

openshell policy set "$NAME" --policy "$GENERATED_POLICY" --wait

openshell policy get "$NAME" --full >"$STATE_DIR/effective-policy-initial.yaml"
cat >"$STATE_FILE" <<EOF
NAME=$NAME
HOST_A=$HOST_A
HOST_A_PORT=$HOST_A_PORT
HOST_B=$HOST_B
HOST_B_PORT=$HOST_B_PORT
ORIGIN_IP=$ORIGIN_IP
POLICY_IP=$POLICY_IP
POLICY_IPV6=$POLICY_IPV6
GATEWAY_NAME=$AUDIT_GATEWAY_NAME
EOF

trap - ERR
printf 'Network sandbox ready: %s\n' "$NAME"
printf 'Next: bash tests/network/run-network-tests.sh\n'
