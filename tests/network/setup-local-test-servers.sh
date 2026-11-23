#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGIN_DIR="$HERE/local-test-servers"
STATE_DIR="$HERE/.state"
RUNTIME_DIR="$ORIGIN_DIR/.runtime"
STATE_FILE="$STATE_DIR/origin.env"

command -v docker >/dev/null 2>&1 || { echo 'Docker is not installed.' >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo 'Docker is not reachable. Start Docker Desktop.' >&2; exit 2; }
docker compose version >/dev/null 2>&1 || { echo 'Docker Compose is not available.' >&2; exit 2; }

mkdir -p "$STATE_DIR" "$RUNTIME_DIR/logs"
chmod 0777 "$RUNTIME_DIR/logs"
: >"$RUNTIME_DIR/logs/host-a.json"
: >"$RUNTIME_DIR/logs/host-b.json"
chmod 0666 "$RUNTIME_DIR/logs/host-a.json" "$RUNTIME_DIR/logs/host-b.json"

docker network inspect openshell-docker >/dev/null 2>&1 || docker network create openshell-docker >/dev/null
docker compose -f "$ORIGIN_DIR/compose.yaml" up -d
docker compose -f "$ORIGIN_DIR/compose.yaml" restart caddy >/dev/null

for ((attempt = 1; attempt <= 60; attempt++)); do
  if docker exec ft-network-caddy test -f /data/caddy/pki/authorities/local/root.crt 2>/dev/null; then
    break
  fi
  sleep 1
done
docker exec ft-network-caddy test -f /data/caddy/pki/authorities/local/root.crt
docker cp ft-network-caddy:/data/caddy/pki/authorities/local/root.crt "$STATE_DIR/caddy-root.crt" >/dev/null
cp "$STATE_DIR/caddy-root.crt" "$HERE/network-test-sandbox/caddy-root.crt"
if [[ "$(uname -s)" != Darwin ]]; then
  # Building first avoids OpenShell's tar-context issue on Windows-mounted WSL paths.
  docker build -q -t openshell-policy-verification/network-test-sandbox:local "$HERE/network-test-sandbox" >/dev/null
fi

# Names for the local test servers. macOS and OpenShell 0.1.x use host.openshell.internal on ports 443 and 444
# (see tests/shared/gateway-network-config.sh); OpenShell 0.0.x on Linux uses Docker network aliases.
source "$HERE/../shared/gateway-network-config.sh"
if [[ "$(uname -s)" == Darwin ]]; then
  ORIGIN_IP=127.0.0.1
  HOST_A=host.openshell.internal
  HOST_A_PORT=443
  HOST_B=host.openshell.internal
  HOST_B_PORT=444
else
  ORIGIN_IP="$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  [[ -n "$ORIGIN_IP" ]] || { echo 'Could not determine the Linux host address.' >&2; exit 2; }
  if lab_openshell_uses_policy_dns; then
    HOST_A=host.openshell.internal
    HOST_A_PORT=443
    HOST_B=host.openshell.internal
    HOST_B_PORT=444
  else
    HOST_A=host-a.test
    HOST_A_PORT=443
    HOST_B=host-b.test
    HOST_B_PORT=443
  fi
fi

cat >"$STATE_FILE" <<EOF
HOST_A=$HOST_A
HOST_A_PORT=$HOST_A_PORT
HOST_B=$HOST_B
HOST_B_PORT=$HOST_B_PORT
ORIGIN_IP=$ORIGIN_IP
EOF

curl --cacert "$STATE_DIR/caddy-root.crt" --resolve "${HOST_A}:${HOST_A_PORT}:127.0.0.1" \
  -fsS "https://${HOST_A}:${HOST_A_PORT}/public" | grep -Fxq A_PUBLIC
curl --cacert "$STATE_DIR/caddy-root.crt" --resolve "${HOST_B}:${HOST_B_PORT}:127.0.0.1" \
  -fsS "https://${HOST_B}:${HOST_B_PORT}/public" | grep -Fxq B_PUBLIC

printf 'Local origins are running on ports %s and %s.\n' "$HOST_A_PORT" "$HOST_B_PORT"
printf 'Root certificate: %s\n' "$STATE_DIR/caddy-root.crt"
