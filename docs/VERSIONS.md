# Versions

This table records the reference environment used while developing the lab. It is not evidence that another user's run used the same components. The signed Windows/WSL run completed on 2026-11-22 re-recorded OpenShell `0.0.116` and kernel `6.18.58.1-microsoft-standard-WSL2`; generated reports remain the authority for each run.

## OpenShell versions under comparison

The component table further down is the **reference** environment. The lab can also run other OpenShell releases (`--openshell-version`, `--openshell-versions`, `--compare`; see `README.md`). Every report records the OpenShell version it measured, and `audit-reports/COMPARISON.md` lines the versions up.

| Role | OpenShell | Status |
|---|---|---|
| Baseline (reference above) | `0.0.116` | Measured: signed full run on 2026-11-22 |
| Candidate | `0.1.9` | Measured: all 36 tests on 2026-11-22. The lab's scripts were written against 0.0.116; this version is run through the same scripts, so an incompatibility shows up as `INCOMPLETE`, never as a pass |
| Latest stable (2026-11-26) | `0.1.10` | Filesystem suite (26 tests) measured on 2026-11-26 through `--filesystem-only --openshell-version 0.1.10`: 20 PASS, 1 FAIL (T32), 1 EXPECTED, 4 KNOWN-LIMITATION, 0 INCONCLUSIVE. The network suite was not run on it. T32 alone was also run 5 times on each release from 0.1.1 to 0.1.10 in a separate repository (see `docs/UPSTREAM_ANALYSIS_T09_T32.md`) |

The change between baseline and candidate is explained in `docs/UPSTREAM_ANALYSIS_T09_T32.md`: T09 is explained by the Landlock ABI (V2 to V3) and passes on 0.1.9; T32 is **not** explained by the ABI and still fails on 0.1.9.

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
