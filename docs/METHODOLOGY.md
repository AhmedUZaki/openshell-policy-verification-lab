# Evaluation methodology

## Research question and scope

This lab asks whether a specific OpenShell policy, in a specific recorded environment, produces the predefined network and filesystem outcomes in T01–T36. The unit of analysis is one complete audit run identified by a shared run ID.

The lab does **not** prove that OpenShell is universally secure, that no bypass exists, or that results generalize to versions and platforms that were not executed.

## Experimental design

- The policy configuration is the independent variable.
- The observed command outcome, resource state, origin request, and enforcement log are dependent measurements.
- Destructive filesystem probes use permissive controls to show that the operation and fixture work before testing denial under the restrictive policy.
- Network denial probes use positive controls and local HTTPS origins to distinguish policy enforcement from a dead server or broken route.
- The user may select network-only (10 rows), filesystem-only (26 rows), or a full run (36 rows). The expected result set and evidence attestation use the same selected scope.
- Expectations are defined before execution in `docs/CLAIMS.md` and `docs/EXTENDED_TESTS.md`.
- All expected rows must be present. Missing, duplicate, malformed, or mismatched evidence makes the analysis `INCOMPLETE`; it is never converted into a pass.

## Test-status and analysis semantics

| Verdict | Meaning |
|---|---|
| `PASS` | The measured outcome matched the predefined expectation for this run. It is not a universal security proof. |
| `FAIL` | A valid test attempt contradicted the predefined enforcement expectation. |
| `EXPECTED` | The observation matched intentional product semantics that differ from a simple allow/deny intuition. |
| `KNOWN-LIMITATION` | The observation is outside the documented mediation scope used by this lab; it remains visible and is not counted as an independent enforcement failure. |
| `INCONCLUSIVE` | Prerequisites or controls did not support a valid inference. |

`INCOMPLETE` is an overall analysis outcome, not a status assigned to a measured test. It means required rows or signed evidence are missing, duplicated, malformed, mismatched, or inconclusive.

`PASS_WITH_LIMITATIONS` is used when all measured enforcement expectations pass but one or more `KNOWN-LIMITATION` rows are present.

## Evidence and reproducibility

Every invocation receives one run ID. Network and filesystem reports, raw logs, local-origin observations, and policy snapshots use that ID. The runner hashes the evidence with SHA-256 and signs the manifest with a local Ed25519 identity. The analyzer accepts only the selected run, verifies the signature and every digest, checks the embedded ID and evidence-complete marker, rejects duplicate rows, and refuses to combine unrelated runs.

The signature detects modification after attestation and identifies the signing key. Independent chain of custody additionally requires the public-key fingerprint to be recorded or published outside the evidence bundle. A valid signature still does not prove that every summary row is a correct interpretation of its raw log; causal and high-stakes conclusions require inspection of the underlying evidence.

`node tests/verify-analysis-integrity.mjs` performs 18 synthetic fault-injection checks against the analyzer and attestation layer. It verifies preservation of measured failures, signature and post-signing tamper detection, missing or duplicate evidence, scoped runs, exact-run selection, safe pairing, limitation reporting, nonzero exit codes for infrastructure faults, archiving of earlier results by run ID without deleting anything, recording the OpenShell version of each run, rejecting a run whose network and filesystem reports measured different versions, and the cross-version comparison with its prediction check.

## Inference rules

1. Report observed behavior before proposing a mechanism.
2. Do not infer causation from correlation alone.
3. Group correlated tests to avoid double counting, while labeling the root cause provisional unless separate runtime evidence establishes it.
4. Do not describe a known mediation limitation as a newly discovered vulnerability.
5. Do not generalize beyond the recorded version, policy, platform, and test surface.

## Threats to validity

- The reference development run used the environment recorded in `docs/VERSIONS.md`; macOS and a separate native Linux host were not empirically executed during that review.
- Local HTTPS origins improve determinism but do not reproduce every public-network condition.
- Thirty-six predefined probes cannot demonstrate the absence of untested bypasses; the defensible assurance boundary is defined in `docs/ASSURANCE_SCOPE.md`.
- Shared implementation paths can make multiple failing tests manifestations of one finding.
- Product semantics and mediation scope can change across versions, so every conclusion must name the tested run and environment.
- A passing control shows that the tested operation was viable in that setup; it does not eliminate every possible confounder.
- Signed manifests detect post-attestation modification, but independent signer identity depends on preserving the public-key fingerprint outside the repository.

## Interpretation discipline

The machine-generated report is an evidence index, not a substitute for causal analysis. For example, if T09 and T32 both fail, the result rows establish related truncation behavior. Attributing that behavior to a particular ABI additionally requires runtime evidence showing the applied ABI and authoritative evidence describing that ABI's mediation boundary.
