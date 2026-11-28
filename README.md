# OpenShell policy verification lab

This project runs thirty-eight local enforcement tests and automatically analyzes their evidence:

- N01–N06: network destination, proxy bypass, binary identity, HTTP method/path, and policy-generation revocation.
- F1_1–F4_1: inaccessible and read-only filesystem behavior.
- F3_2–F2_5 and F2_6–F1_2: extended content, namespace, symlink, special-file, execution, and metadata filesystem probes.
- N07–N10: copied-binary identity, additional REST boundaries, path normalization, and a positive precision control.
- N11–N12: wildcard host policy validation and provider-credential leak via a reflecting response.

No public test server, domain, Cloudflare account, model provider, or API credential is required.

## Platform support

| Host | Status for this lab | Required path |
|---|---|---|
| Windows 10/11 x86-64 | Validated only on Windows 11 (this project machine); Windows 10 untested; supported with conditions | WSL 2, the project-managed `Ubuntu-24.04` distro, Docker Desktop WSL integration |
| macOS Apple Silicon | Implementation target; empirical validation pending | Homebrew, Docker Desktop, pinned NemoClaw/OpenShell |
| Linux Ubuntu 24.04 x86-64/arm64 | Primary implementation target; separate native-host validation pending | Docker Engine/Desktop and a working systemd user manager |
| Other systemd Linux distributions | Best effort | Docker plus a compatible pinned NemoClaw/OpenShell installation |
| Intel macOS or native Windows without WSL 2 | Not supported by this runner | Use a supported host above |

This is not a claim that every machine with one of these operating systems will work. Port 443 must be free on Windows/WSL and Linux; ports 443 and 444 must be free on macOS. Docker must be reachable by the current user, and the machine must meet the pinned NemoClaw requirements. The main runner is portable; `tests/enforcement-audit/network/run-legacy-openshell-probes.sh` is a retained Linux/WSL-only historical helper and is not part of N01–F1_2.

## One-command execution

### Windows

Requirements: Docker Desktop, WSL 2, and the `Ubuntu-24.04` distribution configured by `setup/`.

```text
run-enforcement-audit.cmd
```

The interactive menu asks whether to run network tests, filesystem tests, or both. Choosing network runs N01–N06, N07–N10, and N11–N12; choosing filesystem runs F1_1–F2_5 and F2_6–F1_2.

For a terminal or CI job without the final pause:

```text
run-enforcement-audit.cmd nopause --all
```

### Linux

Requirements: Docker, OpenShell/NemoClaw from `setup/4-install-nemoclaw.sh`, and a working systemd user manager.

```bash
bash run-enforcement-audit.sh
```

### macOS

Requirements: Apple Silicon, Docker Desktop, Homebrew, and OpenShell/NemoClaw from `setup/4-install-nemoclaw.sh`.

```bash
bash run-enforcement-audit.sh
```

The runner permits the intended Apple Silicon workflow but it is not marked empirically validated until a signed full-suite run is retained. It reports an infrastructure error on Intel macOS instead of producing misleading results.

## Runner options

```text
--all
--network-only
--filesystem-only
--keep
--dry-run
--openshell-version VERSION   (repeatable; must already be installed)
--openshell-versions V1,V2    (same, comma separated; each must already be installed)
--compare
--all-installed
--keep-version
```

When no scope option is supplied in an interactive terminal, the runner shows a bilingual menu asking which tests to run (both, network only, or filesystem only). Passing a scope option skips that question. Scripts and CI jobs must pass one explicit scope option.

This script never downloads an OpenShell version itself; every version named with `--openshell-version(s)` must already be installed. On Windows, `run-enforcement-audit.cmd` prompts first (via `choose-openshell-version.cmd`) to download and activate a version before the scope question; on Linux/WSL, run `bash choose-openshell-version.sh` first. See "Testing other OpenShell versions" below.

| Scope | Tests | Result rows |
|---|---|---|
| `--network-only` | N01–N06, N07–N10, N11–N12 | 12 |
| `--filesystem-only` | F1_1–F2_5, F2_6–F1_2 | 26 |
| `--all` | N01–F1_2 | 38 |

## Testing other OpenShell versions

By default the runner tests whichever OpenShell is installed. On Linux and WSL it can also test other releases that are already installed, one run per version. Downloading a new version always goes through `choose-openshell-version.sh` / `.cmd` first — `run-enforcement-audit.sh`/`.cmd` never download one themselves:

```bash
bash choose-openshell-version.sh                                    # the only place that downloads: pick 0.0.116 / 0.1.9 / 0.1.10 by number
bash run-enforcement-audit.sh --all --compare                       # baseline 0.0.116 and candidate 0.1.9 (both must already be installed)
bash run-enforcement-audit.sh --all --openshell-version 0.1.9
bash run-enforcement-audit.sh --all --openshell-versions 0.0.116,0.1.5,0.1.9
bash run-enforcement-audit.sh --all --openshell-version 0.1.10
bash run-enforcement-audit.sh --all --all-installed                 # every version already installed here, then compare
bash setup/4b-install-openshell-versions.sh available               # just show the releases available on GitHub
bash setup/4b-install-openshell-versions.sh prepare choose          # pick any release on GitHub, download and verify, without running tests
```

**"All" means the versions already installed on this machine** (`--all-installed`): every version you downloaded before (via `choose-openshell-version.sh`/`.cmd`) is kept in the store, so "All" grows as you try more versions, and it never starts a download by itself. Only 0.0.116 and 0.1.9 were validated in full; any other release goes through the same scripts and an incompatibility is reported as `INCOMPLETE`, never as a pass. To fetch and verify any release listed on GitHub (not just the 3 pinned versions), run `bash setup/4b-install-openshell-versions.sh prepare choose` directly; it reads the release list from GitHub every time, so a new OpenShell release appears without any change to the lab, and falls back (GitHub's tag list, then the releases feed, then a short built-in list) when the API is unreachable or rate-limited (`GITHUB_TOKEN` raises the limit to 5000/hour).

**Interactive menu** (no scope or version option given; double-click `run-enforcement-audit.cmd` on Windows). The steps are in this order:

1. *Choose the version* (`choose-openshell-version.cmd`, only when none was given on the command line): `1` 0.0.116, `2` 0.1.9, `3` 0.1.10, or `4` **All = every version installed on this machine now**. The chosen version(s) are downloaded and verified immediately. (On Linux/WSL, run `bash choose-openshell-version.sh` yourself beforehand instead; the `.sh` runner never prompts for a version.)
2. *Choose the tests.* Both, network only, or filesystem only.
3. The tests run on each chosen version, and two or more versions are compared.

Windows without the menu: `run-enforcement-audit.cmd nopause --all --compare`. Each version is checked against its published SHA-256 list when downloaded via `choose-openshell-version.sh`/`.cmd` (or ahead of time with `setup/4b-install-openshell-versions.sh`), gets its own run ID (`<id>-os<version>`) and its own signed evidence, and the version originally installed is restored afterwards (`--keep-version` skips that). The reports record the OpenShell version they measured; `audit-reports/enforcement-audit/latest/COMPARISON.md` shows which tests changed between versions and checks the written predictions in `docs/upstream-analysis/truncation-F3_1-F3_3.md`.

On OpenShell 0.1.x the network suite needs temporary gateway settings that the lab writes to `~/.config/openshell/` and removes again (see `setup/README.md`, section "Network tests on OpenShell 0.1.x"), and Docker Desktop needs host networking enabled. The test scripts were written against OpenShell 0.0.116. A newer release may change command-line options, policy schema, or gateway behavior; such a break is reported as `INCOMPLETE` (exit code 2), not as a pass or a failure of the enforcement claim. Switching versions keeps a separate gateway state per version and is not available on macOS. OpenShell 0.1.10 is the latest stable release as of 2026-11-26. The lab's filesystem suite (26 tests) was run on it that day: 20 PASS, 1 FAIL (F3_3), 1 EXPECTED, 4 LANDLOCK-LIMITATION, 0 INCONCLUSIVE; the network suite was not run on it (see `docs/VERSIONS.md`).

## Automatic analysis

The runner gives every invocation one audit run ID. The analyzer accepts only reports carrying that exact ID, checks every expected test in the selected scope, and writes:

```text
audit-reports/enforcement-audit/latest/LATEST.md
audit-reports/enforcement-audit/latest/LATEST_AR.md
audit-reports/enforcement-audit/latest/LATEST.json
audit-reports/enforcement-audit/run-history/<run-id>/   (analysis.md, analysis_AR.md, analysis.json for that run)
audit-reports/enforcement-audit/latest-by-version/<openshell-version>/LATEST.*   (latest report of each OpenShell version)
audit-reports/enforcement-audit/latest/COMPARISON.md, COMPARISON_AR.md, COMPARISON.json   (written when two or more versions were run)
```

Each report starts with a status summary and a "Needs attention" list, then separate Network and Filesystem tables with a short description for every test.

At the start of every new run, `tests/enforcement-audit/archive-previous-results.mjs` moves all earlier results (raw evidence, signed manifests, and reports) to `archived-results/<previous-run-id>/` (ignored by Git) so the active folders contain only the current run. Nothing is deleted.

Raw evidence is written under `tests/enforcement-audit/network/results/` and/or `tests/enforcement-audit/filesystem/results/`. Signed manifests are written under `evidence-attestations/`.

Run analysis without rerunning the experiments:

```bash
bash tests/enforcement-audit/analyze-results.sh
```

Without `--run-id`, full analysis selects the newest matching network/filesystem pair by report modification time; it never combines unrelated runs. A scoped analysis selects the newest report for that scope. You can select an exact run explicitly with `--run-id ID`.

Windows:

```text
tests\analyze-results.cmd
```

Verify the analyzer itself with portable synthetic fault-injection tests (no Docker or OpenShell required):

```bash
node tests/enforcement-audit/verify-analysis-integrity.mjs
```

Every real audit run also creates a SHA-256 manifest signed with a local Ed25519 key. The first run creates the signing identity under ignored `.local-keys/`; never commit or share the private key. Record the printed public-key fingerprint outside the repository if independent chain-of-custody verification is required (the reference machine's fingerprint is published at https://gist.github.com/AhmedUZaki/ea3571bb522ee407d4966ff946e3cb9b).

Verify a transferred run against a separately obtained public key:

```bash
node tests/enforcement-audit/evidence-attestation.mjs verify --run-id RUN_ID --public-key /trusted/path/evidence-public-key.pem
```

Exit codes are stable for local automation and CI:

- `0`: every measured expectation passed.
- `1`: at least one measured expectation returned `FAIL`.
- `2`: infrastructure failure, missing result, or inconclusive result.

The overall label is `PASS_WITH_LIMITATIONS` rather than plain `PASS` whenever a measured `LANDLOCK-LIMITATION` is present. Infrastructure failures and unreadable evidence are never inferred to be successful enforcement.

Before producing an overall result, the analyzer verifies the signed evidence manifest and every recorded SHA-256 digest. It also verifies the run ID embedded in each report, rejects duplicate test rows, checks the evidence-complete marker, and requires the corresponding raw logs, origin logs, and policy snapshots. Missing, modified, unsigned, or malformed evidence makes the run `INCOMPLETE` with exit code `2`.

The analyzer treats N01–N06 and F1_1/F2_1/F3_1/F4_1 as the core suite and the remaining N07–N12 and F1_2/F2_2–F2_17/F3_2–F3_3/F4_2–F4_4 as predefined extended robustness tests. It separates enforcement failures from `LANDLOCK-LIMITATION` and `EXPECTED` behavior. Correlated failures are grouped to avoid double counting, but the analyzer does not infer a specific root cause from correlation alone.

The evaluation design, verdict semantics, evidence chain, bounded assurance claim, platform acceptance criteria, and threats to validity are documented in `docs/METHODOLOGY.md` and (for the F3_1/F3_3 truncation findings) `docs/upstream-analysis/truncation-F3_1-F3_3.md`. The predefined test expectations, including the bounded assurance statement and claim-to-test coverage, are all in `docs/CLAIMS.md`. Platform acceptance criteria and version history are in `docs/VERSIONS.md`.

The tracked repository contains only `.gitkeep` placeholders in generated-result directories; local runs may populate those ignored directories. Running `run-enforcement-audit.cmd` or `run-enforcement-audit.sh` generates fresh evidence belonging to the current user. Archived evidence under `archived-results/` is historical and is never selected by the analyzer.

## Tier (metamorphic) checks

Separately from the N01–F1_2 enforcement audit above, `run-tier-network-and-filesystem-checks.sh`/`.cmd` runs three metamorphic checks against the real, vendored NemoClaw Restricted/Balanced/Open tier presets (see `docs/CLAIMS.md`, "Policy comparisons", for what each one proves and how):

```bash
bash run-tier-network-and-filesystem-checks.sh                     # network monotonicity + filesystem invariance (no internet)
bash run-tier-network-and-filesystem-checks.sh --live               # also live network reachability (real requests to pypi.org, wttr.in)
```

```text
run-tier-network-and-filesystem-checks.cmd
```

The `.cmd` menu lets you pick which check(s) to run, and (when live reachability is included) which of the 6 tier/destination operations to run — one, several, or all. Flags mirror `run-enforcement-audit.sh`: `--monotonicity-only`, `--invariance-only`, `--live-only`, `--pairs=tier:dest,...` (e.g. `restricted:pypi,open:wttr`), `--openshell-version V` (must already be installed), `--keep-version`. Like `run-enforcement-audit`, this script never downloads an OpenShell version itself; see "Testing other OpenShell versions" above. Reports are written under `audit-reports/tier-checks/`.

## License

MIT, see `LICENSE`.
