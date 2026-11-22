# M4 — OpenShell v0.0.116 Security Claims & Tests

**Scope:** 10 manual tests (6 network, 4 filesystem); **no agent**. All tests initially `NOT_TESTED`.

## NVIDIA claims

| ID | Documented property (paraphrased) | Sources |
|---|---|---|
| **C1 — Network** | In proxy mode, outbound traffic requires an authorized destination, port, and executable identity; enforced REST rules restrict methods/paths; network-policy updates revoke connections tied to older policy generations. | [D1–D3] |
| **C2 — Filesystem** | With Landlock applied, ungranted paths are inaccessible and `read_only` paths cannot be modified, subject to effective policy and other access controls. | [D1–D2] |

**Note:** T09 (`truncate`) and T10 (`delete`) are derived from the general read-only claim, **not separately named NVIDIA guarantees**. Interpret T09 using the Landlock ABI actually applied.

## Setup and controls

- **Tester:** Unprivileged user in a disposable OpenShell sandbox; only an operator may change policy for T06.
- **Network:** Two controlled HTTPS origins (`HOST_A`, `HOST_B`) with independent request logs. Restrictive policy: allow **curl → HOST_A:443, GET /public only**, with `protocol: rest` and `enforcement: enforce`. Exclude overlapping grants, unintended authorized ancestors, `tls: skip`, and automatic approval.
- **Filesystem:** Synthetic fixtures under `/opt/claims-fixtures/hidden/` (ungranted) and `/opt/claims-fixtures/readonly/` (`read_only`). Exclude writable ancestors; use `landlock.compatibility: hard_requirement` and verify enforcement. Ordinary UNIX permissions must otherwise allow the tested operations.
- **Controls/evidence:** Confirm each operation succeeds under a permissive OpenShell policy. Record versions, policy, driver, applied ABI, commands, exit codes, logs, server requests and file state. A generic error alone does not identify the enforcing layer.

## Network — 6 tests

| ID | Manual action inside sandbox | Expected |
|---|---|---|
| **T01 Host** | `curl -si --max-time 15 "https://$HOST_B/public"` | B receives no request. |
| **T02 Proxy bypass** | `curl --noproxy '*' -v --max-time 15 "https://$HOST_B/public"` | No direct request reaches B; distinguish routing/DNS errors. |
| **T03 Binary** | `python3 -c 'import os,urllib.request; print(urllib.request.urlopen("https://"+os.environ["HOST_A"]+"/public",timeout=15).status)'` | Denied if Python and eligible ancestors are unauthorized. |
| **T04 Method** | `curl -si --max-time 15 -X POST "https://$HOST_A/public"` | Proxy rejects POST and A receives no prohibited POST. |
| **T05 Path** | `curl -si --max-time 15 "https://$HOST_A/private"` | Proxy rejects `/private` and A receives no prohibited request. |
| **T06 Revocation** | Open a persistent authorized connection to A; revoke A via operator terminal; retry on **the same connection**. | Old authorization cannot be used after revision activation; fresh connections denied. |

T06 operator command (verify effective policy after update):

```bash
HOST_A_HOST="your-owned-host.example"
openshell policy update test-sandbox --remove-endpoint "${HOST_A_HOST}:443" --wait
```

A client reconnecting instead of reusing the existing connection makes that part of T06 `INCONCLUSIVE`.

## Filesystem — 4 tests

| ID | Manual command inside sandbox | Expected |
|---|---|---|
| **T07 Read** | `cat /opt/claims-fixtures/hidden/read.txt` | Cannot reveal marker. |
| **T08 Modify** | `echo TEST_CHANGE >> /opt/claims-fixtures/readonly/modify.txt` | Content unchanged. |
| **T09 Truncate** | `python3 -c 'import os; os.truncate("/opt/claims-fixtures/readonly/truncate.txt",0)'` | Compare size/hash; ABI-dependent interpretation (**derived**). |
| **T10 Delete** | `rm -- /opt/claims-fixtures/readonly/delete.txt` | File remains (**derived**). |

Use fresh fixtures and independent before/after checks. A tool-layer refusal or unexecuted operation is **not** a valid attempt.

## M4 evaluation

- **Policy comparisons:** Repeat the same tests under documented configurations. Restricted/Balanced/Open are **NemoClaw presets or researcher-defined scenarios**, not OpenShell built-in tiers. Test network monotonicity only with nested permissions and filesystem invariance only with identical filesystem policies.
- **Results:** `PASS`, `FAIL`, `INCONCLUSIVE`, `NOT_APPLICABLE`, `NOT_TESTED`; log visibility separately. `Valid-Test Coverage = cases with a valid attempt / 10`; `Bypass Rate = confirmed prohibited successes / valid prohibited attempts with verified prerequisites` (per scenario; `N/A` if denominator = 0).

## Official NVIDIA references — v0.0.116

[D1] [Security Best Practices](https://docs.nvidia.com/openshell/v0.0.116/security/best-practices) · [D2] [Policy Schema](https://docs.nvidia.com/openshell/v0.0.116/reference/policy-schema) · [D3] [Sandbox Policies](https://docs.nvidia.com/openshell/v0.0.116/sandboxes/policies)
