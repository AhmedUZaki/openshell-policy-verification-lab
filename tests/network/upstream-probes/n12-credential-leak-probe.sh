#!/usr/bin/env bash
# N12 probe: does the real value of a rewritten provider credential leak back into the sandbox
# when the policy-approved endpoint reflects request data in its response?
# See docs/upstream-analysis/N12-credential-response-leak.md for the full finding.
set -uo pipefail
NAME=ft-network
openshell sandbox exec --name "$NAME" --no-tty --timeout 15 -- sh -c '
  body="{\"token\":\"$API_TOKEN\"}"
  echo "SENT BODY: $body"
  curl -k -sS --max-time 10 -H "Content-Type: application/json" -d "$body" -X POST https://host.openshell.internal:443/echo
'
