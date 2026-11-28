#!/usr/bin/env bash
# N11 probe: does `openshell policy set` validate/reject overly broad wildcard hosts?
# Upstream: https://github.com/ai-openshell/openshell/issues/5623
# See docs/upstream-analysis/N11-wildcard-host-validation.md for the full finding.
#
# For each pattern: build a policy using it, try to set it, record accept/reject, then
# immediately revert to this lab's own generated restrictive policy (minimize exposure).
set -uo pipefail
NAME=ft-network
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STRICT="$ROOT/tests/network/.state/network-generated.yaml"
WORK="$ROOT/tests/network/upstream-probes/.n11-tmp-policy.yaml"

[[ -f "$STRICT" ]] || {
  echo "Missing $STRICT - run create-network-test-sandbox.sh first." >&2
  exit 2
}

make_policy() {
  local host="$1"
  cat >"$WORK" <<EOF
version: 1
filesystem_policy:
  include_workdir: false
  read_only: [/usr, /lib, /etc, /proc, /dev/urandom, /var/log]
  read_write: [/tmp, /dev/null, /dev/pts, /work]
landlock:
  compatibility: hard_requirement
process:
  run_as_user: "1500"
  run_as_group: "1500"
network_policies:
  allow_wildcard:
    name: allow_wildcard
    endpoints:
      - host: "$host"
        port: 443
        protocol: rest
        enforcement: enforce
        rules:
          - allow:
              method: GET
              path: /public
    binaries:
      - path: /usr/bin/curl
EOF
}

declare -A patterns=(
  [N11b]='*.*.*'
  [N11c]='a*.*'
  [N11d]='*.*.com'
  [N11e]='foo.*.com'
  [N11f]='a*.com'
  [N11g]='api.github.*'
  [N11h]='*.example.{com,io}'
)

for id in N11b N11c N11d N11e N11f N11g N11h; do
  host="${patterns[$id]}"
  echo "=== $id  host: \"$host\" ==="
  make_policy "$host"
  out="$(openshell policy set "$NAME" --policy "$WORK" --wait 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "  ACCEPTED (rc=0) -- should have been rejected per the issue's claim"
  else
    echo "  REJECTED (rc=$rc)"
  fi
  echo "  $out" | sed 's/^/  /'
  # revert immediately regardless of outcome
  openshell policy set "$NAME" --policy "$STRICT" --wait >/dev/null 2>&1
done
rm -f "$WORK"
