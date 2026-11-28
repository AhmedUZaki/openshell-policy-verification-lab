# Evaluation methodology

## Research question and scope

This lab asks whether a specific OpenShell policy, in a specific recorded environment, produces the predefined network and filesystem outcomes in N01–N10 and F1_1–F4_4. The unit of analysis is one complete audit run identified by a shared run ID.

The lab does **not** prove that OpenShell is universally secure, that no bypass exists, or that results generalize to versions and platforms that were not executed.

## Experimental design

- The policy configuration is the independent variable.
- The observed command outcome, resource state, origin request, and enforcement log are dependent measurements.
- Destructive filesystem probes use permissive controls to show that the operation and fixture work before testing denial under the restrictive policy.
- Network denial probes use positive controls and local HTTPS origins to distinguish policy enforcement from a dead server or broken route.
- The user may select network-only (10 rows), filesystem-only (26 rows), or a full run (36 rows). The expected result set and evidence attestation use the same selected scope.
- Expectations are defined before execution in `docs/CLAIMS.md`.
- All expected rows must be present. Missing, duplicate, malformed, or mismatched evidence makes the analysis `INCOMPLETE`; it is never converted into a pass.

## Test-status and analysis semantics

| Verdict | Meaning |
|---|---|
| `PASS` | The measured outcome matched the predefined expectation for this run. It is not a universal security proof. |
| `FAIL` | A valid test attempt contradicted the predefined enforcement expectation. |
| `EXPECTED` | The observation matched intentional product semantics that differ from a simple allow/deny intuition. |
| `LANDLOCK-LIMITATION` | The observation is outside the documented mediation scope used by this lab; it remains visible and is not counted as an independent enforcement failure. |
| `INCONCLUSIVE` | Prerequisites or controls did not support a valid inference. |

`INCOMPLETE` is an overall analysis outcome, not a status assigned to a measured test. It means required rows or signed evidence are missing, duplicated, malformed, mismatched, or inconclusive.

`PASS_WITH_LIMITATIONS` is used when all measured enforcement expectations pass but one or more `LANDLOCK-LIMITATION` rows are present.

## Evidence and reproducibility

Every invocation receives one run ID. Network and filesystem reports, raw logs, local-origin observations, and policy snapshots use that ID. The runner hashes the evidence with SHA-256 and signs the manifest with a local Ed25519 identity. The analyzer accepts only the selected run, verifies the signature and every digest, checks the embedded ID and evidence-complete marker, rejects duplicate rows, and refuses to combine unrelated runs.

The signature detects modification after attestation and identifies the signing key. Independent chain of custody additionally requires the public-key fingerprint to be recorded or published outside the evidence bundle. A valid signature still does not prove that every summary row is a correct interpretation of its raw log; causal and high-stakes conclusions require inspection of the underlying evidence.

`node tests/verify-analysis-integrity.mjs` performs 18 synthetic fault-injection checks against the analyzer and attestation layer. It verifies preservation of measured failures, signature and post-signing tamper detection, missing or duplicate evidence, scoped runs, exact-run selection, safe pairing, limitation reporting, nonzero exit codes for infrastructure faults, archiving of earlier results by run ID without deleting anything, recording the OpenShell version of each run, rejecting a run whose network and filesystem reports measured different versions, and the cross-version comparison with its prediction check.

## Version-dependent denial signals

OpenShell 0.0.116 answers a disallowed request with an HTTP 403 from its proxy, or a timeout for a direct attempt. OpenShell 0.1.x refuses at the sandbox boundary instead: connection refused, permission denied, or an unresolvable name. The network runner accepts the second form as a denial signal only when it detects 0.1.x, and labels it `boundary-refusal` in the report. Every other condition of a denial verdict is unchanged: a working baseline, a healthy sandbox and origin after the request, and zero matching requests in the origin log.

## Inference rules

1. Report observed behavior before proposing a mechanism.
2. Do not infer causation from correlation alone.
3. Group correlated tests to avoid double counting, while labeling the root cause provisional unless separate runtime evidence establishes it.
4. Do not describe a known mediation limitation as a newly discovered vulnerability.
5. Do not generalize beyond the recorded version, policy, platform, and test surface.

## Threats to validity

- The reference development run used the environment recorded in `docs/VERSIONS.md`; macOS and a separate native Linux host were not empirically executed during that review.
- Local HTTPS origins improve determinism but do not reproduce every public-network condition.
- Thirty-six predefined probes cannot demonstrate the absence of untested bypasses; the defensible assurance boundary is defined in the "Bounded assurance statement" section of `docs/CLAIMS.md`.
- Shared implementation paths can make multiple failing tests manifestations of one finding.
- Product semantics and mediation scope can change across versions, so every conclusion must name the tested run and environment.
- A passing control shows that the tested operation was viable in that setup; it does not eliminate every possible confounder.
- Signed manifests detect post-attestation modification, but independent signer identity depends on preserving the public-key fingerprint outside the repository.
- Kernel `AUDIT_LANDLOCK_ACCESS` records were evaluated as an attribution source and found unavailable on the reference environment: the WSL2 kernel (`6.18.58.1-microsoft-standard-WSL2`) compiles in `CONFIG_AUDIT`/`CONFIG_AUDITSYSCALL`, but `auditd` cannot enable the audit subsystem even as root (`Error sending enable request (Operation not permitted)`), a documented WSL2 kernel restriction rather than a configuration error. Attribution instead relies on `tests/diagnostics/landlock_overlay_probe.py`, which reproduces the denial outside OpenShell under a controlled Landlock ABI, combined with `docs/upstream-analysis/truncation-F3_1-F3_3.md`. A native Linux host or VM would be required to collect audit-based evidence.
- The network tier-monotonicity check (`tests/network/check-tier-monotonicity.mjs`) verifies the real, vendored NemoClaw preset definitions, not live reachability to the third-party hosts they name; it does not repeat the kind of live egress proof N11 performed for a single host. It also excludes six Open-tier messaging presets that NemoClaw compiles through a separate, OAuth-backed subsystem rather than static YAML (see `tests/network/nemoclaw-tiers/SOURCE.md`), so the checked relation is narrower than NemoClaw's full Open tier.

## Interpretation discipline

The machine-generated report is an evidence index, not a substitute for causal analysis. For example, if F3_1 and F3_3 both fail, the result rows establish related truncation behavior. Attributing that behavior to a particular ABI additionally requires runtime evidence showing the applied ABI and authoritative evidence describing that ABI's mediation boundary. The two tests also show why a shared guess can be wrong: F3_1 was traced to the Landlock ABI (and passes once the ABI changes), while F3_3 kept failing after the ABI changed and has a different cause (`docs/upstream-analysis/truncation-F3_1-F3_3.md`).
