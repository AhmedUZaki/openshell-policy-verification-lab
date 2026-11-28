# M4 — OpenShell v0.0.116 Security Claims & Tests

**Scope:** 10 core tests (6 network, 4 filesystem); **no agent or model provider**, except N12 below, which needs one. The runner adds 28 predefined robustness tests (listed below), for 38 result rows in a full run.

## NVIDIA claims

| ID | Documented property (paraphrased) |
|---|---|
| **C1 — Network** | In proxy mode, outbound traffic requires an authorized destination, port, and executable identity; enforced REST rules restrict methods/paths; network-policy updates revoke connections tied to older policy generations. |
| **C2 — Filesystem** | With Landlock applied, ungranted paths are inaccessible and `read_only` paths cannot be modified, subject to effective policy and other access controls. |

**Note:** F3_1 (`truncate`) and F4_1 (`delete`) are derived from the general read-only claim, **not separately named NVIDIA guarantees**. Interpret F3_1 using the Landlock ABI actually applied.

## Setup and controls

- **Tester:** Unprivileged user in a disposable OpenShell sandbox; only an operator may change policy for N06.
- **Network:** Two local controlled HTTPS origins (`HOST_A`, `HOST_B`) with independent request logs. The restrictive policy allows **curl → HOST_A:443, GET /public only**, with `protocol: rest` and `enforcement: enforce`. On macOS the second origin uses port 444. The suite uses an allowed baseline, explicit denial signals, post-probe sandbox/origin health checks, and origin-log absence; it does not create a separate permissive network sandbox for every negative probe.
- **Filesystem:** Synthetic fixtures under `/opt/claims-fixtures/hidden/` (ungranted) and `/opt/claims-fixtures/readonly/` (`read_only`). Exclude writable ancestors; use `landlock.compatibility: hard_requirement` and verify enforcement. Ordinary UNIX permissions must otherwise allow the tested operations.
- **Controls/evidence:** Filesystem mutation probes use a separate permissive OpenShell sandbox. Network probes use the allowed baseline and independent origin-health/log checks described above. Record versions, effective policy, applied ABI, commands, exit codes, logs, server requests, and file state. A generic error alone does not identify the enforcing layer. Each completed run is hashed and signed before analysis.

## Network tests — N01–N12

The commands below express the tested operation. The automated runner adds the local port, unique correlation token, TLS material, timeouts, and raw-output capture needed for reproducible evidence.

| ID | Core? | Probe | Expected |
|---|---|---|---|
| **N01 Host** | core | `curl -si --max-time 15 "https://$HOST_B/public"` | B receives no request. |
| **N02 Proxy bypass** | core | `curl --noproxy '*' -v --max-time 15 "https://$HOST_B/public"` (the runner also adds `-k` and `--resolve` to the gateway/policy IP so the direct connection is actually attempted) | No direct request reaches B; distinguish routing/DNS errors. |
| **N03 Binary** | core | `python3 -c 'import os,urllib.request; print(urllib.request.urlopen("https://"+os.environ["HOST_A"]+"/public",timeout=15).status)'` | Denied if Python and eligible ancestors are unauthorized. |
| **N04 Method** | core | `curl -si --max-time 15 -X POST "https://$HOST_A/public"` | Proxy rejects POST and A receives no prohibited POST. |
| **N05 Path** | core | `curl -si --max-time 15 "https://$HOST_A/private"` | Proxy rejects `/private` and A receives no prohibited request. |
| **N06 Revocation** | core | Start an authorized persistent stream to A, remove A with `policy update --wait`, then observe the old stream and attempt a fresh request. | The old stream terminates after revision activation and the fresh request is denied. |
| **N07** | extended | Copy `/usr/bin/curl` to `/tmp/curl-copy` and call the allowed URL | Denied by binary identity; origin receives no request. |
| **N08** | extended | Send `HEAD /public` where an explicit GET rule exists | `EXPECTED`: OpenShell intentionally treats HEAD as matching GET; the origin receives the request. |
| **N09** | extended | Send `/public/../private` with `--path-as-is` | Denied; origin receives no request. |
| **N10** | extended | Send allowed `GET /public` with a query string | Allowed and logged. Positive control that detects over-blocking. |
| **N11 Wildcard host validation** | extended | On the same sandbox, `policy set` a policy whose only endpoint is the host pattern `**.*.*`, then (if accepted) `curl` from inside the sandbox to a real external host (`www.example.com`), then revert to the restrictive baseline | The pattern should be rejected by policy validation (deny-by-default); if accepted, the sandbox should still not reach arbitrary external hosts. Full reasoning in `docs/upstream-analysis/N11-wildcard-host-validation.md`. |
| **N12 Credential leak via reflecting response** | extended | On a second, provider-attached sandbox, send a request carrying the rewritten credential placeholder to a policy-approved endpoint (`policies/network-n12-provider-profile.yaml`) that echoes the request body back in its response | The real credential must not reach the sandboxed process in either direction. Full reasoning in `docs/upstream-analysis/N12-credential-response-leak.md`. |

The automated runner performs the equivalent update for N06 and saves the final effective policy:

```bash
openshell policy update "$SANDBOX" --remove-endpoint "${HOST_A}:${HOST_A_PORT}" --wait
```

N11 and N12 each use a policy or sandbox that is deliberately *not* the restrictive baseline used by N01–N10, since the finding in each case is specifically about what that baseline's validation or credential-rewrite layer fails to catch. N11 swaps `ft-network`'s policy for the duration of its probe, exactly as N06 does; N12 creates and tears down its own sandbox (`ft-network-n12`), profile, and provider instance within the same `run-network-tests.sh` invocation. Their fixture files live in `policies/` alongside the suite's other policies.

N12 needs `openshell profile import`, which does not exist on the M4 baseline release, `0.0.116` (`error: unrecognized subcommand 'profile'`). On that version N12 reports `INCONCLUSIVE` with the CLI error captured in the run's raw log, and the overall run is correctly `INCOMPLETE` rather than silently skipping or mis-scoring N12. This is the same "no agent or model provider" limitation the Scope line above already states for 0.0.116; it is not a regression.

## Filesystem tests — F1 Read, F2 Modify, F3 Truncate, F4 Delete

The four core claim tests (F1_1, F2_1, F3_1, F4_1) are each the first test in one of the four main categories. The remaining 22 tests are additional robustness probes grouped under the same category as the primary operation they exercise.

### F1 — Read

| ID | Core? | Probe | Expected |
|---|---|---|---|
| **F1_1 Read** | core | `cat /opt/claims-fixtures/hidden/read.txt` | Cannot reveal marker. |
| F1_2 | extended | `stat` on an otherwise ungranted file | `LANDLOCK-LIMITATION` if metadata is returned: Landlock does not mediate `stat`. |

### F2 — Modify

| ID | Core? | Probe | Expected |
|---|---|---|---|
| **F2_1 Modify** | core | `echo TEST_CHANGE >> /opt/claims-fixtures/readonly/modify.txt` | Content unchanged. |
| F2_2 | extended | Python `open(path, "w")` on a `read_only` file | Denied; size and hash unchanged. |
| F2_3 | extended | In-place `dd conv=notrunc` overwrite | Denied; hash unchanged. |
| F2_4 | extended | Create a new file inside the `read_only` directory | Denied; new file is absent. |
| F2_5 | extended | Change mode bits with `chmod` | `LANDLOCK-LIMITATION` if changed: Landlock does not mediate `chmod`. |
| F2_6 | extended | Create a hard link inside `read_only` | Denied; link absent. |
| F2_7 | extended | Create a symbolic link inside `read_only` | Denied; link absent. |
| F2_8 | extended | Create a directory inside `read_only` | Denied; directory absent. |
| F2_9 | extended | Change modification time with `utime` | `LANDLOCK-LIMITATION` if changed: Landlock does not mediate `utime`. |
| F2_10 | extended | Add a `user.*` extended attribute | `LANDLOCK-LIMITATION` if changed: Landlock does not mediate `setxattr`. |
| F2_11 | extended | Copy a readable file from `read_only` to `/work` | Allowed; source and copied hashes match. Positive precision control. |
| F2_12 | extended | Follow a symlink in `read_only` to an ungranted target | Target content remains inaccessible. |
| F2_13 | extended | Write through a symlink in `/work` whose target is `read_only` | Denied; target hash unchanged. |
| F2_14 | extended | Modify content through a writable `mmap` | Denied; target hash unchanged. |
| F2_15 | extended | Bind a pathname UNIX socket inside `read_only` | Denied; socket absent. |
| F2_16 | extended | Create a FIFO inside `read_only` | Denied; FIFO absent. |
| F2_17 | extended | Execute a script stored under `read_only` | `EXPECTED`: execution remains allowed for this policy; separate tests measure content mutation. |

### F3 — Truncate

| ID | Core? | Probe | Expected |
|---|---|---|---|
| **F3_1 Truncate** | core | `python3 -c 'import os; os.truncate("/opt/claims-fixtures/readonly/truncate.txt",0)'` | Compare size/hash; ABI-dependent interpretation (**derived**). |
| F3_2 | extended | Shell redirection `: > file` on a `read_only` file | Denied; size and hash unchanged. |
| F3_3 | extended | Open with unusual `O_RDONLY\|O_TRUNC` flags | Denied; size/hash unchanged. F3_3 and F3_1 can differ: on OpenShell 0.1.x F3_1 passes while F3_3 still fails (the call reports `EACCES` yet the file is emptied). The result rows alone do not identify the cause; see `docs/upstream-analysis/truncation-F3_1-F3_3.md`. |

### F4 — Delete

| ID | Core? | Probe | Expected |
|---|---|---|---|
| **F4_1 Delete** | core | `rm -- /opt/claims-fixtures/readonly/delete.txt` | File remains (**derived**). |
| F4_2 | extended | Rename a file inside the `read_only` directory | Denied; original remains and destination is absent. |
| F4_3 | extended | Remove an empty directory inside `read_only` | Denied; directory remains. |
| F4_4 | extended | Move a file from `read_only` to writable `/work` | Denied; source remains and destination is absent. |

Use fresh fixtures and independent before/after checks for every filesystem test. A tool-layer refusal or unexecuted operation is **not** a valid attempt.

## Interpretation rule

A larger number of FAIL rows does not automatically mean a larger number of vulnerabilities. For example, F3_1, F3_2, and F2_2 may exercise different user-level interfaces to the same kernel operation. Correlated failures should be grouped into one provisional finding until evidence shows independent causes. Grouping prevents double counting; it does not by itself establish a root cause.

`FAIL` means an enforcement expectation failed. `LANDLOCK-LIMITATION` records behavior predefined as outside the mediation scope measured by this lab and does not count as an independent enforcement failure. `EXPECTED` records predefined product semantics. `INCONCLUSIVE` means the control, prerequisites, or test infrastructure did not establish a valid comparison.

## Bounded assurance statement

### Defensible conclusion

For a named run ID, recorded environment, applied policies, and signed evidence bundle, this lab determines whether N01–N12 and F1_1–F4_4 matched their predefined expectations. A complete run supports only conclusions about those tested operations and boundaries.

### Claim-to-test coverage

| Assurance area | Primary tests | Additional robustness probes |
|---|---|---|
| Destination, port, and executable identity | N01–N03 | N07 |
| REST method and path restrictions | N04–N05 | N08–N10 |
| Policy-generation revocation | N06 | — |
| Ungranted-path confidentiality | F1_1 | F2_12, F1_2 |
| Read-only content and namespace integrity | F2_1, F3_1, F4_1 | F2_2–F2_4, F2_6–F2_8, F2_13, F2_14, F3_2, F3_3, F4_2–F4_4 |
| Positive precision controls | allowed network baseline plus permissive filesystem controls | N10, F2_11, F2_17 |
| Explicit mediation-scope observations | — | F2_5, F2_9, F2_10, F1_2 |
| Policy-validation and credential-rewrite boundaries | — | N11, N12 |

### Conclusions this lab does not support

- "OpenShell has no bypasses."
- "Every OpenShell version and host platform behaves identically."
- "A `PASS` proves universal security."
- "Multiple correlated failures are automatically multiple vulnerabilities."
- "A signed bundle proves the experiment was honestly designed or interpreted."

Those statements are not testable from a finite black-box suite. Removing them is not a weakness in the project; it is the correct scientific boundary.

### Extending assurance

New attack hypotheses should be added as predefined tests with a permissive control, restrictive expectation, raw evidence, and an explicit mapping to the assurance area above. A new test broadens observed coverage but must not silently broaden the conclusion beyond what it exercised.

For network probes where a separate permissive sandbox is not used, the equivalent validity evidence must include a healthy local origin, a working allowed baseline, a healthy sandbox after the request, a recognized enforcement-denial signal, and origin-log correlation.

## M4 evaluation

- **Policy comparisons:** Repeat the same tests under documented configurations. Restricted/Balanced/Open are **NemoClaw presets**, not OpenShell built-in tiers; their real definitions (not a researcher approximation) are vendored from the pinned NemoClaw install in `tests/network/nemoclaw-tiers/` (see its `SOURCE.md`). Network monotonicity (every destination allowed under a narrower tier must remain allowed under each wider tier) is checked statically and offline by `tests/network/check-tier-monotonicity.mjs`, reported in `audit-reports/latest/TIER-MONOTONICITY.md`. Filesystem invariance (the same `filesystem_policy` across all three tiers must produce identical F1–F4 results) is checked by actually running the suite three times, against the committed, generated `policies/filesystem-with-network-tier-{restricted,balanced,open}.yaml` (each is `filesystem-restrictive.yaml`'s filesystem_policy/landlock/process, byte-for-byte, plus that tier's network_policies), via `tests/network/run-tier-filesystem-invariance.sh`; reported in `audit-reports/latest/TIER-FS-INVARIANCE.md`. Six Open-tier messaging presets (`slack`, `discord`, `telegram`, `wechat`, `whatsapp`, `teams`) are compiled by a separate OAuth-backed subsystem rather than static YAML and are excluded from both checks, reported explicitly rather than silently dropped.
- **Test statuses:** `PASS`, `FAIL`, `EXPECTED`, `LANDLOCK-LIMITATION`, `INCONCLUSIVE`. Missing, duplicated, unsigned, or malformed evidence makes the overall analysis `INCOMPLETE`; it is not a test status rewritten after execution.
- **Metrics:** `Valid-Test Coverage = cases with a valid attempt / expected cases in the selected scope`; `Bypass Rate = confirmed prohibited successes / valid prohibited attempts with verified prerequisites` (per scenario; `N/A` if denominator = 0). Both are computed by `tests/analyze-results.mjs` and reported under "Metrics" in every `LATEST.md`/`LATEST_AR.md`; scenarios for Bypass Rate group by test family (network, F1–F4), and tests designed to be allowed (N08, N10, F2_11, F2_17) are excluded from its denominator.
