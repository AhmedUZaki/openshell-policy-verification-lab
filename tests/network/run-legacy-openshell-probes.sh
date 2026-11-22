#!/usr/bin/env bash
# Phase 1 probes for OpenShell on its own (no agent, no NemoClaw onboarding).
# Each probe tests one claim from docs/CLAIMS.md by its ID and records
# PASS / FAIL / SKIP / INFO / NOT-TESTED, then writes a Markdown report.
#
# What this script changes on the machine, and undoes at the end:
#   - starts the OpenShell gateway service if it is not running (stops it again
#     only if THIS script started it);
#   - creates one sandbox named enforcement-audit-<time> (always deleted at exit).
# The first sandbox creation may pull a container image, which can take minutes.
#
# Retained historical helper for Linux and Windows inside WSL (see
# run-legacy-openshell-probes.cmd). It is not part of the portable T01-T36
# runner. Exit code: 0 = no FAIL/ERROR, 1 = at least one.
#
# Usage:
#   bash tests/network/run-legacy-openshell-probes.sh
#   DRY_RUN=1 bash tests/network/run-legacy-openshell-probes.sh

set -uo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  echo 'This legacy helper supports Linux/WSL only. Use run-enforcement-audit.sh for the portable T01-T36 suite.' >&2
  exit 2
fi

DRY_RUN="${DRY_RUN:-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="$HERE/results"
REPORT="$RESULTS_DIR/openshell-$STAMP.md"
RAWLOG="$RESULTS_DIR/openshell-$STAMP.raw.log"
NAME="enforcement-audit-$STAMP"
GATEWAY_UNIT="nemoclaw-openshell-gateway"

export PATH="$HOME/.local/bin:$PATH"
have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '%s\n' "$*"; }

IDS=(); STATUSES=(); EVIDENCE=()
rec() { # id status evidence
  local ev
  ev="$(printf '%s' "$3" | tr '\n\r' '  ' | sed 's/|/\\|/g' | cut -c1-220)"
  IDS+=("$1"); STATUSES+=("$2"); EVIDENCE+=("$ev")
  printf '  [%-10s] %-3s %s\n' "$2" "$1" "$ev"
}

# All Phase 1 IDs, so the report always shows every claim, tested or not.
ALL_IDS="E1 E2 E3 E4 N1 N2 N3 N4 N5 N6 N7 N8 F1 F2 F3 F4 P1 P2 I1 I2"
declare -A WHY_NOT=(
  [E1]="layer summary, not a testable behavior on its own"
  [E2]="needs re-creating a sandbox with a different policy"
  [E3]="needs re-creating a sandbox with a different policy"
  [E4]="needs a provider and a policy YAML"
  [N3]="needs a custom policy YAML with a binaries list"
  [N4]="needs a custom policy YAML with protocol rules"
  [N6]="needs a custom policy YAML (tls: skip)"
  [N7]="needs a policy that allows the host first; deny-by-default hides it otherwise"
  [N8]="needs an interactive operator approval"
  [F4]="needs policy YAML with invalid paths"
  [I2]="needs a provider with a real credential"
)

if [[ "$DRY_RUN" == "1" ]]; then
  say "Dry run: nothing is started, created or written. Probes that would run:"
  say "  N1 egress denied (example.com)     N2 proxy bypass blocked (1.1.1.1, --noproxy)"
  say "  N5 enforcement mode (policy dump)  F1 kernel/Landlock baseline"
  say "  F2 Landlock findings in logs       F3 read-only /usr and /etc, writable /tmp"
  say "  P1 non-root, no capabilities       P2 mount/unshare blocked"
  say "  I1 no model-provider access (integrate.api.nvidia.com)"
  say "Not tested here (reasons are written to the report): $(for i in "${!WHY_NOT[@]}"; do printf '%s ' "$i"; done)"
  exit 0
fi

mkdir -p "$RESULTS_DIR"
: > "$RAWLOG"
raw() { { printf '\n===== %s =====\n' "$1"; shift; printf '%s\n' "$*"; } >> "$RAWLOG"; }

# --- preflight ----------------------------------------------------------
say "Preflight"
have openshell || { say "  openshell not found. Run setup/4-install-nemoclaw first."; exit 2; }
have docker && docker info >/dev/null 2>&1 || { say "  Docker is not reachable. Start Docker (Windows: enable WSL integration)."; exit 2; }
say "  openshell: $(openshell --version 2>&1 | tail -n 1)"

STARTED_GATEWAY=0
if ! openshell status >/dev/null 2>&1; then
  if have systemctl && systemctl --user cat "$GATEWAY_UNIT" >/dev/null 2>&1; then
    say "  Gateway not reachable; starting $GATEWAY_UNIT ..."
    systemctl --user start "$GATEWAY_UNIT" && STARTED_GATEWAY=1
    for ((attempt = 1; attempt <= 30; attempt++)); do openshell status >/dev/null 2>&1 && break; sleep 1; done
  fi
fi
if ! openshell status >/dev/null 2>&1; then
  raw "openshell status" "$(openshell status 2>&1)"
  raw "openshell doctor check" "$(openshell doctor check 2>&1)"
  say "  The gateway is still not reachable. Details are in $RAWLOG"
  say "  Try: openshell doctor check   |   openshell gateway list   |   journalctl --user -u $GATEWAY_UNIT"
  [[ "$STARTED_GATEWAY" == "1" ]] && systemctl --user stop "$GATEWAY_UNIT"
  exit 2
fi
say "  gateway reachable"

SANDBOX_UP=0
cleanup() {
  [[ "$SANDBOX_UP" == "1" ]] && openshell sandbox delete "$NAME" >/dev/null 2>&1
  [[ "$STARTED_GATEWAY" == "1" ]] && systemctl --user stop "$GATEWAY_UNIT" >/dev/null 2>&1
}
trap cleanup EXIT

say "Creating sandbox $NAME (the first run may pull an image; this can take minutes)"
CREATE_OUT="$(timeout 900 openshell sandbox create --name "$NAME" -- true 2>&1)"; CREATE_RC=$?
raw "sandbox create (rc=$CREATE_RC)" "$CREATE_OUT"
if [[ "$CREATE_RC" -ne 0 ]] || ! openshell sandbox list --names 2>/dev/null | grep -qx "$NAME"; then
  say "  Sandbox creation failed (rc=$CREATE_RC). See $RAWLOG"
  say "  If it needs an inference provider or NemoClaw onboarding, that is the finding: OpenShell alone cannot create one yet."
  exit 2
fi
SANDBOX_UP=1
say "  sandbox up"

# Runs a shell snippet inside the sandbox; sets OUT and RC.
sbx() { # label script
  OUT="$(openshell sandbox exec -n "$NAME" --no-tty --timeout 40 -- sh -c "$2" 2>&1)"; RC=$?
  raw "$1 (rc=$RC)" "$OUT"
}

http_blocked() { # last 3 chars of OUT are the HTTP code; blocked unless 2xx/3xx
  [[ "$RC" -ne 0 ]] && return 0
  [[ "${OUT: -3}" =~ ^[23][0-9][0-9]$ ]] && return 1
  return 0
}

CURL='if command -v curl >/dev/null 2>&1; then curl -sS -m 10 -o /dev/null -w "%{http_code}" '

say "Probes"

# N1: deny-by-default egress
sbx N1 "${CURL}https://example.com; else echo NOTOOL; fi"
if [[ "$OUT" == *NOTOOL* ]]; then rec N1 SKIP "curl is not in the sandbox image"
elif http_blocked; then rec N1 PASS "egress to example.com was not allowed: $OUT"
else rec N1 FAIL "example.com answered: $OUT"; fi

# N2: the sandbox cannot bypass the proxy at the network level
sbx N2 "${CURL}--noproxy '*' https://1.1.1.1; else echo NOTOOL; fi; echo; env | grep -i '^[a-z]*_proxy=' | sed 's/=.*/=<set>/'"
if [[ "$OUT" == *NOTOOL* ]]; then rec N2 SKIP "curl is not in the sandbox image"
elif [[ "$RC" -ne 0 || "$OUT" == 000* || "$OUT" == *"curl:"* ]]; then rec N2 PASS "direct connection to 1.1.1.1 without the proxy failed: $OUT"
else rec N2 FAIL "direct connection without the proxy got through: $OUT"; fi

# N5: audit vs enforce is policy data; record it, do not judge it
POLICY_OUT="$(openshell policy get "$NAME" --full 2>&1)"
raw "policy get --full" "$POLICY_OUT"
rec N5 INFO "enforcement lines in the effective policy: $(printf '%s' "$POLICY_OUT" | grep -iE 'enforcement|audit|enforce' | head -n 3 | tr '\n' ' ')(full dump in the raw log)"

# F1: kernel baseline for Landlock ABI 3 (Linux 6.2+)
KVER="$(uname -r | sed 's/[^0-9.].*//')"
sbx F1 "cat /sys/kernel/security/lsm 2>/dev/null || echo UNREADABLE"
if [[ "$(printf '%s\n6.2\n' "$KVER" | sort -V | head -n 1)" != "6.2" ]]; then
  rec F1 FAIL "kernel $KVER is older than 6.2"
elif [[ "$OUT" == *landlock* ]]; then rec F1 PASS "kernel $KVER and landlock in the active LSM list"
else rec F1 INFO "kernel $KVER is 6.2+, but the LSM list could not confirm landlock from inside the sandbox: $OUT"; fi

# F2: Landlock degradation findings
LOGS="$(openshell logs "$NAME" --source sandbox -n 500 2>&1)"
raw "logs (sandbox)" "$LOGS"
LL="$(printf '%s' "$LOGS" | grep -i landlock | head -n 3 | tr '\n' ' ')"
rec F2 INFO "${LL:-no Landlock lines in the sandbox log (no degradation reported)}"

# F3: read-only system paths, writable /tmp
sbx F3 'touch /usr/audit-probe 2>/dev/null && echo USR=writable || echo USR=denied; touch /etc/audit-probe 2>/dev/null && echo ETC=writable || echo ETC=denied; touch /tmp/audit-probe 2>/dev/null && echo TMP=writable || echo TMP=denied'
if [[ "$OUT" == *USR=denied* && "$OUT" == *ETC=denied* && "$OUT" == *TMP=writable* ]]; then rec F3 PASS "$OUT"
else rec F3 FAIL "$OUT"; fi

# P1: non-root, no capabilities, no_new_privs
sbx P1 'echo "uid=$(id -u)"; grep -E "^(CapEff|NoNewPrivs):" /proc/self/status'
if [[ "$OUT" == *"uid=0"* ]]; then rec P1 FAIL "running as root: $OUT"
elif [[ "$OUT" == *"CapEff:"*0000000000000000* && "$OUT" == *"NoNewPrivs:"*1* ]]; then rec P1 PASS "$OUT"
else rec P1 FAIL "$OUT"; fi

# P2: blocked syscalls (only what the image has tools for)
sbx P2 'if command -v mount >/dev/null 2>&1; then mount -t tmpfs none /tmp >/dev/null 2>&1 && echo MOUNT=allowed || echo MOUNT=blocked; else echo MOUNT=notool; fi; if command -v unshare >/dev/null 2>&1; then unshare -U true >/dev/null 2>&1 && echo USERNS=allowed || echo USERNS=blocked; else echo USERNS=notool; fi'
if [[ "$OUT" == *allowed* ]]; then rec P2 FAIL "$OUT"
elif [[ "$OUT" == *blocked* ]]; then rec P2 PASS "$OUT"
else rec P2 SKIP "mount and unshare are not in the sandbox image: $OUT"; fi

# I1: no model-provider access by default
sbx I1 "${CURL}https://integrate.api.nvidia.com; else echo NOTOOL; fi"
if [[ "$OUT" == *NOTOOL* ]]; then rec I1 SKIP "curl is not in the sandbox image"
elif http_blocked; then rec I1 PASS "no route to integrate.api.nvidia.com: $OUT"
else rec I1 FAIL "integrate.api.nvidia.com answered: $OUT"; fi

# Everything not probed above still gets a row.
for id in $ALL_IDS; do
  [[ " ${IDS[*]} " == *" $id "* ]] || rec "$id" NOT-TESTED "${WHY_NOT[$id]:-not covered by this script}"
done

# --- report ------------------------------------------------------------
FAILS=0; for s in "${STATUSES[@]}"; do [[ "$s" == FAIL ]] && FAILS=$((FAILS + 1)); done
{
  printf '# OpenShell phase 1 results\n\n'
  printf 'Run: %s\n\nOpenShell: %s\n\nKernel: %s\n\n' "$STAMP" "$(openshell --version 2>&1 | tail -n 1)" "$(uname -r)"
  printf 'Claim IDs refer to `docs/CLAIMS.md`. Raw command output: `%s`.\n\n' "$(basename "$RAWLOG")"
  printf '| ID | Status | Evidence |\n|---|---|---|\n'
  for id in $ALL_IDS; do
    for i in "${!IDS[@]}"; do
      [[ "${IDS[$i]}" == "$id" ]] && printf '| %s | %s | %s |\n' "$id" "${STATUSES[$i]}" "${EVIDENCE[$i]}"
    done
  done
} > "$REPORT"

say ""
say "Report:  $REPORT"
say "Raw log: $RAWLOG"
say "$FAILS probe(s) failed."
[[ "$FAILS" -eq 0 ]]
