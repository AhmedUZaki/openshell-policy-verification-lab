#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
if ! command -v node >/dev/null 2>&1; then
  for node_dir in "$NVM_DIR"/versions/node/*/bin; do
    [[ -x "$node_dir/node" ]] && export PATH="$node_dir:$PATH"
  done
fi
command -v node >/dev/null 2>&1 || { echo 'Node.js is required for automatic analysis.' >&2; exit 2; }
node "$ROOT/tests/enforcement-audit/analyze-results.mjs" "$@"
