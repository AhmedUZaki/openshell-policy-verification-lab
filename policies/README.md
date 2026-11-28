# Policies

OpenShell sandbox policy files used by the automated test suites under `tests/`. Each file is a complete policy (`filesystem_policy`, `landlock`, `process`, and `network_policies`); OpenShell does not accept them separately.

```
policies/
├── enforcement-audit/   -- core suite (N01-N12, F1-F4): run-enforcement-audit.sh
└── tier-checks/          -- NemoClaw metamorphic-tier check: docs/CLAIMS.md, "Policy comparisons"
```

## `enforcement-audit/` -- core suite (N01–N12, F1–F4)

| File | Used by | Purpose |
|---|---|---|
| `filesystem-restrictive.yaml` | `tests/enforcement-audit/filesystem/` | The `read_only`/ungranted-path policy under test (F1–F4). |
| `filesystem-permissive.yaml` | `tests/enforcement-audit/filesystem/` | Permissive control: shows each probed operation is viable before testing denial under the restrictive policy. |
| `network-deny-all-base-policy.yaml` | `tests/enforcement-audit/network/` | Base policy for the restrictive network sandbox; the runner adds the host/port/credential endpoint for N01–N10 at creation time (see `tests/enforcement-audit/network/create-network-test-sandbox.sh`). |
| `network-n11-wildcard-policy.yaml` | N11 (`tests/enforcement-audit/network/run-network-tests.sh`) | The over-broad host-wildcard pattern (`**.*.*`) under test; see `docs/upstream-analysis/N11-wildcard-host-validation.md`. |
| `network-n12-base-policy.yaml`, `network-n12-provider-profile.yaml` | N12 (`tests/enforcement-audit/network/run-network-tests.sh`) | The credential-rewrite / reflecting-endpoint scenario; see `docs/upstream-analysis/N12-credential-response-leak.md`. |

## `tier-checks/` -- metamorphic-tier check (`docs/CLAIMS.md`, "Policy comparisons")

| File | Purpose |
|---|---|
| `filesystem-with-network-tier-restricted.yaml` | `enforcement-audit/filesystem-restrictive.yaml`'s `filesystem_policy`/`landlock`/`process`, byte-for-byte, plus the Restricted tier's `network_policies` (empty). |
| `filesystem-with-network-tier-balanced.yaml` | Same `filesystem_policy`, plus the Balanced tier's `network_policies` (npm, pypi, huggingface, brew-balanced, brave). |
| `filesystem-with-network-tier-open.yaml` | Same `filesystem_policy`, plus the Open tier's `network_policies` (the above, plus weather, public-reference, jira, outlook). |

These three are used by `tests/tier-checks/run-tier-filesystem-invariance.sh`, which runs the F1–F4 suite once per file and checks that every test produces the **same** result regardless of which network tier is attached -- i.e., that the network policy has no effect on filesystem enforcement. They are **generated files** (each starts with a `# GENERATED FILE` header naming the exact regenerate command) composed from `enforcement-audit/filesystem-restrictive.yaml` plus the real NemoClaw tier/preset definitions vendored in `tests/tier-checks/nemoclaw-tiers/` (see that directory's `SOURCE.md` for provenance and scope limitations). Do not hand-edit them; regenerate with `tests/tier-checks/nemoclaw-tiers/compose-tier-filesystem-policy.mjs` if the source changes.

The companion network-only check, `tests/tier-checks/check-tier-monotonicity.mjs`, verifies the same tier definitions without creating a sandbox and does not need a policy file here.
