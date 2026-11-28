# Versions

This table records the reference environment used while developing the lab. It is not evidence that another user's run used the same components. The signed Windows/WSL run completed on 2026-11-22 re-recorded OpenShell `0.0.116` and kernel `6.18.58.1-microsoft-standard-WSL2`; generated reports remain the authority for each run.

## OpenShell versions under comparison

The component table further down is the **reference** environment. The lab can also run other OpenShell releases (`--openshell-version`, `--openshell-versions`, `--compare`; see `README.md`). Every report records the OpenShell version it measured, and `audit-reports/latest/COMPARISON.md` lines the versions up.

| Role | OpenShell | Status |
|---|---|---|
| Baseline (reference above) | `0.0.116` | Measured: signed full run on 2026-11-22 |
| Candidate | `0.1.9` | Measured: all 36 tests on 2026-11-22. The lab's scripts were written against 0.0.116; this version is run through the same scripts, so an incompatibility shows up as `INCOMPLETE`, never as a pass |
| Latest stable (2026-11-26) | `0.1.10` | Filesystem suite (26 tests) measured on 2026-11-26 through `--filesystem-only --openshell-version 0.1.10`: 20 PASS, 1 FAIL (F3_3), 1 EXPECTED, 4 LANDLOCK-LIMITATION, 0 INCONCLUSIVE. The network suite was not run on it. F3_3 alone was also run 5 times on each release from 0.1.1 to 0.1.10 in a separate repository (see `docs/upstream-analysis/truncation-F3_1-F3_3.md`) |

The change between baseline and candidate is explained in `docs/upstream-analysis/truncation-F3_1-F3_3.md`: F3_1 is explained by the Landlock ABI (V2 to V3) and passes on 0.1.9; F3_3 is **not** explained by the ABI and still fails on 0.1.9.

N11 (wildcard host validation) and N12 (credential leak via a reflecting response) are part of the same N01–N12 network suite (see `docs/CLAIMS.md`). Background and the original multi-version reproduction (0.1.9, 0.1.10) are in `docs/upstream-analysis/N11-wildcard-host-validation.md` and `docs/upstream-analysis/N12-credential-response-leak.md`.

| Component | Version |
|---|---|
| OpenShell | `0.0.116` |
| OpenShell documentation | `v0.0.116` |
| NemoClaw (Git tag) | `v0.0.140` |
| NemoClaw (CLI) | `v0.1.0` |
| Node.js (inside WSL, via nvm) | `v22.23.5` |
| Docker (client/server) | `29.9.3` |
| Ubuntu (WSL) | `24.04.5 LTS` |
| WSL | `3.0.5.0` |
| Linux kernel (WSL 2) | `6.18.58.1-microsoft-standard-WSL2` |
| Windows 11 Education | `10.0.26200` |

## Platform validation

### Two validation layers

1. **Portable tooling layer:** Node.js parsing, evidence signing, fault injection, and report generation must pass on Windows, macOS, and Linux. `.github/workflows/portable-self-tests.yml` defines this three-OS matrix.
2. **Enforcement layer:** Docker, OpenShell, gateway lifecycle, Landlock behavior, and the full N01–F4_4 suite must be executed on the target host. A portable-tooling pass is not evidence that enforcement worked on that host.

### Acceptance criteria for a host

A host may be marked empirically validated only when all of the following are retained:

- the exact OS, architecture, kernel, Docker, Node.js, OpenShell, and NemoClaw versions;
- a complete run ID covering N01–F4_4;
- a verified signed evidence manifest and externally recorded public-key fingerprint;
- no missing or inconclusive tests;
- the generated JSON and Markdown analysis;
- a statement of any measured `FAIL`, `EXPECTED`, or `LANDLOCK-LIMITATION` rows without rewriting their status.

### Current empirical status

| Host | Portable tooling | Full enforcement suite |
|---|---|---|
| Windows 11 x86-64 through WSL 2 | Passed locally and in GitHub Actions (windows-latest) | Signed full run completed locally on 2026-11-22; analysis reported 28 `PASS`, 2 `FAIL`, 2 `EXPECTED`, 4 `LANDLOCK-LIMITATION`, 0 missing/inconclusive |
| macOS Apple Silicon | Passed in GitHub Actions (macos-latest), run for commit `0521b04` | Not yet empirically validated |
| Ubuntu 24.04 native | Passed in GitHub Actions (ubuntu-latest), run for commit `0521b04` | Not yet empirically validated on a separate native host |

A passing CI job covers only the portable tooling layer: it does not run Docker, OpenShell, or N01–F4_4. The full-enforcement cells for macOS and Linux cannot be changed to "validated" by documentation, CI, or emulation. They require evidence produced on those actual platforms.

The Windows evidence is generated and ignored local material, not part of the tracked repository. The reference machine's public key and its fingerprint are published outside this repository, so the evidence bundle and the repository cannot change them: https://gist.github.com/AhmedUZaki/ea3571bb522ee407d4966ff946e3cb9b. Anyone who receives a bundle should compare the fingerprint it reports with the one published there.
