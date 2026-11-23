# Platform validation

## Two validation layers

1. **Portable tooling layer:** Node.js parsing, evidence signing, fault injection, and report generation must pass on Windows, macOS, and Linux. `.github/workflows/portable-self-tests.yml` defines this three-OS matrix.
2. **Enforcement layer:** Docker, OpenShell, gateway lifecycle, Landlock behavior, and the full T01–T36 suite must be executed on the target host. A portable-tooling pass is not evidence that enforcement worked on that host.

## Acceptance criteria for a host

A host may be marked empirically validated only when all of the following are retained:

- the exact OS, architecture, kernel, Docker, Node.js, OpenShell, and NemoClaw versions;
- a complete run ID covering T01–T36;
- a verified signed evidence manifest and externally recorded public-key fingerprint;
- no missing or inconclusive tests;
- the generated JSON and Markdown analysis;
- a statement of any measured `FAIL`, `EXPECTED`, or `KNOWN-LIMITATION` rows without rewriting their status.

## Current empirical status

| Host | Portable tooling | Full enforcement suite |
|---|---|---|
| Windows 11 x86-64 through WSL 2 | Passed locally and in GitHub Actions (windows-latest) | Signed full run completed locally on 2026-11-22; analysis reported 28 `PASS`, 2 `FAIL`, 2 `EXPECTED`, 4 `KNOWN-LIMITATION`, 0 missing/inconclusive |
| macOS Apple Silicon | Passed in GitHub Actions (macos-latest), run for commit `0521b04` | Not yet empirically validated |
| Ubuntu 24.04 native | Passed in GitHub Actions (ubuntu-latest), run for commit `0521b04` | Not yet empirically validated on a separate native host |

A passing CI job covers only the portable tooling layer: it does not run Docker, OpenShell, or T01–T36. The full-enforcement cells for macOS and Linux cannot be changed to “validated” by documentation, CI, or emulation. They require evidence produced on those actual platforms.

The Windows evidence is generated and ignored local material, not part of the tracked repository. Its public-key fingerprint must be retained outside the evidence bundle for an independent chain-of-custody claim.
