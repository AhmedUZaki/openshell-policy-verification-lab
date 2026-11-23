# M4 — OpenShell v0.0.116 Security Claims & Tests

**Scope:** 10 automated core tests (6 network, 4 filesystem); **no agent or model provider**. The runner adds 26 predefined robustness tests documented in `docs/EXTENDED_TESTS.md`, for 36 result rows in a full run.

## NVIDIA claims

| ID | Documented property (paraphrased) |
|---|---|
| **C1 — Network** | In proxy mode, outbound traffic requires an authorized destination, port, and executable identity; enforced REST rules restrict methods/paths; network-policy updates revoke connections tied to older policy generations. |
| **C2 — Filesystem** | With Landlock applied, ungranted paths are inaccessible and `read_only` paths cannot be modified, subject to effective policy and other access controls. |

**Note:** T09 (`truncate`) and T10 (`delete`) are derived from the general read-only claim, **not separately named NVIDIA guarantees**. Interpret T09 using the Landlock ABI actually applied.

## Setup and controls

- **Tester:** Unprivileged user in a disposable OpenShell sandbox; only an operator may change policy for T06.
- **Network:** Two local controlled HTTPS origins (`HOST_A`, `HOST_B`) with independent request logs. The restrictive policy allows **curl → HOST_A:443, GET /public only**, with `protocol: rest` and `enforcement: enforce`. On macOS the second origin uses port 444. The suite uses an allowed baseline, explicit denial signals, post-probe sandbox/origin health checks, and origin-log absence; it does not create a separate permissive network sandbox for every negative probe.
- **Filesystem:** Synthetic fixtures under `/opt/claims-fixtures/hidden/` (ungranted) and `/opt/claims-fixtures/readonly/` (`read_only`). Exclude writable ancestors; use `landlock.compatibility: hard_requirement` and verify enforcement. Ordinary UNIX permissions must otherwise allow the tested operations.
- **Controls/evidence:** Filesystem mutation probes use a separate permissive OpenShell sandbox. Network probes use the allowed baseline and independent origin-health/log checks described above. Record versions, effective policy, applied ABI, commands, exit codes, logs, server requests, and file state. A generic error alone does not identify the enforcing layer. Each completed run is hashed and signed before analysis.

## Network — 6 tests

The commands below express the tested operation. The automated runner adds the local port, unique correlation token, TLS material, timeouts, and raw-output capture needed for reproducible evidence.

| ID | Automated probe inside sandbox | Expected |
|---|---|---|
| **T01 Host** | `curl -si --max-time 15 "https://$HOST_B/public"` | B receives no request. |
| **T02 Proxy bypass** | `curl --noproxy '*' -v --max-time 15 "https://$HOST_B/public"` (the runner also adds `-k` and `--resolve` to the gateway/policy IP so the direct connection is actually attempted) | No direct request reaches B; distinguish routing/DNS errors. |
| **T03 Binary** | `python3 -c 'import os,urllib.request; print(urllib.request.urlopen("https://"+os.environ["HOST_A"]+"/public",timeout=15).status)'` | Denied if Python and eligible ancestors are unauthorized. |
| **T04 Method** | `curl -si --max-time 15 -X POST "https://$HOST_A/public"` | Proxy rejects POST and A receives no prohibited POST. |
| **T05 Path** | `curl -si --max-time 15 "https://$HOST_A/private"` | Proxy rejects `/private` and A receives no prohibited request. |
| **T06 Revocation** | Start an authorized persistent stream to A, remove A with `policy update --wait`, then observe the old stream and attempt a fresh request. | The old stream terminates after revision activation and the fresh request is denied. |

The automated runner performs the equivalent update and saves the final effective policy:

```bash
openshell policy update "$SANDBOX" --remove-endpoint "${HOST_A}:${HOST_A_PORT}" --wait
```

## Filesystem — 4 tests

| ID | Automated probe inside sandbox | Expected |
|---|---|---|
| **T07 Read** | `cat /opt/claims-fixtures/hidden/read.txt` | Cannot reveal marker. |
| **T08 Modify** | `echo TEST_CHANGE >> /opt/claims-fixtures/readonly/modify.txt` | Content unchanged. |
| **T09 Truncate** | `python3 -c 'import os; os.truncate("/opt/claims-fixtures/readonly/truncate.txt",0)'` | Compare size/hash; ABI-dependent interpretation (**derived**). |
| **T10 Delete** | `rm -- /opt/claims-fixtures/readonly/delete.txt` | File remains (**derived**). |

Use fresh fixtures and independent before/after checks. A tool-layer refusal or unexecuted operation is **not** a valid attempt.

## M4 evaluation

- **Policy comparisons:** Repeat the same tests under documented configurations. Restricted/Balanced/Open are **NemoClaw presets or researcher-defined scenarios**, not OpenShell built-in tiers. Test network monotonicity only with nested permissions and filesystem invariance only with identical filesystem policies.
- **Test statuses:** `PASS`, `FAIL`, `EXPECTED`, `KNOWN-LIMITATION`, `INCONCLUSIVE`. Missing, duplicated, unsigned, or malformed evidence makes the overall analysis `INCOMPLETE`; it is not a test status rewritten after execution.
- **Metrics:** `Valid-Test Coverage = cases with a valid attempt / expected cases in the selected scope`; `Bypass Rate = confirmed prohibited successes / valid prohibited attempts with verified prerequisites` (per scenario; `N/A` if denominator = 0).
