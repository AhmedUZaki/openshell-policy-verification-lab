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

This is not a claim that every machine with one of these operating systems will work. Port 443 must be free on Windows/WSL and Linux; ports 443 and 444 must be free on macOS. Docker must be reachable by the current user, and the machine must meet the pinned NemoClaw requirements. The main runner is portable; `tests/network/run-legacy-openshell-probes.sh` is a retained Linux/WSL-only historical helper and is not part of N01–F1_2.

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
--openshell-version VERSION   (repeatable)
--openshell-versions V1,V2
--compare
--keep-version
```

When no scope option is supplied in an interactive terminal, the runner shows bilingual menus. On Linux and WSL (Windows through `run-enforcement-audit.cmd`) the first one asks which OpenShell version to test: 0.0.116, 0.1.9, or all (both, then a comparison). The next asks which tests to run. Any other version is chosen with `--openshell-version`. Passing a scope option or a version option skips the questions. Scripts and CI jobs must pass one explicit scope option.

| Scope | Tests | Result rows |
|---|---|---|
| `--network-only` | N01–N06, N07–N10, N11–N12 | 12 |
| `--filesystem-only` | F1_1–F2_5, F2_6–F1_2 | 26 |
| `--all` | N01–F1_2 | 38 |

## Testing other OpenShell versions

By default the runner tests whichever OpenShell is installed. On Linux and WSL it can also test other releases, one run per version:

```bash
bash run-enforcement-audit.sh --all --compare                       # baseline 0.0.116 and candidate 0.1.9
bash run-enforcement-audit.sh --all --openshell-version 0.1.9
bash run-enforcement-audit.sh --all --openshell-versions 0.0.116,0.1.5,0.1.9
bash run-enforcement-audit.sh --all --openshell-version 0.1.10
bash run-enforcement-audit.sh --all --choose-version                # pick any release listed on GitHub right now
bash run-enforcement-audit.sh --all --all-installed                 # every version already installed here, then compare
bash run-enforcement-audit.sh --all --all-available                 # EVERY release on GitHub right now, then compare (hours)
bash setup/4b-install-openshell-versions.sh available               # just show the releases available on GitHub
bash setup/4b-install-openshell-versions.sh prepare choose          # pick, download and verify, without running tests
```

**Any available release.** `--choose-version` and `--all-available` read the release list from GitHub every time they run, so a new OpenShell release appears without any change to the lab. The list holds only stable releases that ship the Linux components the lab downloads, newest first; type list numbers and/or versions (`1 4`, `0.1.7`). GitHub's API allows 60 unauthenticated requests per hour per network address; when it refuses (or is unreachable) the lab falls back, in order, to the repository's tag list (newest 25, not checked for downloadable builds), the releases feed, the list saved by the last successful call, and finally a short built-in list; you can always type any version. Setting `GITHUB_TOKEN` in the environment raises the API limit to 5000 per hour. `--all-available` needs a list and stops with a message when none can be read. **"All" in the menu means the versions already installed on this machine** (`--all-installed`): every version you chose before is kept in the store, so "All" grows as you try more versions, and it never starts a large download. Only 0.0.116 and 0.1.9 were validated in full; any other release goes through the same scripts and an incompatibility is reported as `INCOMPLETE`, never as a pass.

**Interactive menu** (no scope or version option given; double-click `run-enforcement-audit.cmd` on Windows). The steps are in this order:

1. *Choose the version.* `1` 0.0.116, `2` 0.1.9, `3` 0.1.10, `4` **All = every version installed on this machine now** (always the option before the last), `5` another version: pick one or more from the list of every available release. The chosen versions are downloaded and verified immediately.
2. *Choose the tests.* Both, network only, or filesystem only.
3. The tests run on each chosen version, and two or more versions are compared.

Windows without the menu: `run-enforcement-audit.cmd nopause --all --compare`. Each version is downloaded and checked against its published SHA-256 list on first use (or ahead of time with `setup/4b-install-openshell-versions.sh`), gets its own run ID (`<id>-os<version>`) and its own signed evidence, and the version originally installed is restored afterwards (`--keep-version` skips that). The reports record the OpenShell version they measured; `audit-reports/enforcement-audit/latest/COMPARISON.md` shows which tests changed between versions and checks the written predictions in `docs/upstream-analysis/truncation-F3_1-F3_3.md`.

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

At the start of every new run, `tests/archive-previous-results.mjs` moves all earlier results (raw evidence, signed manifests, and reports) to `archived-results/<previous-run-id>/` (ignored by Git) so the active folders contain only the current run. Nothing is deleted.

Raw evidence is written under `tests/network/results/` and/or `tests/filesystem/results/`. Signed manifests are written under `evidence-attestations/`.

Run analysis without rerunning the experiments:

```bash
bash tests/analyze-results.sh
```

Without `--run-id`, full analysis selects the newest matching network/filesystem pair by report modification time; it never combines unrelated runs. A scoped analysis selects the newest report for that scope. You can select an exact run explicitly with `--run-id ID`.

Windows:

```text
tests\analyze-results.cmd
```

Verify the analyzer itself with portable synthetic fault-injection tests (no Docker or OpenShell required):

```bash
node tests/verify-analysis-integrity.mjs
```

Every real audit run also creates a SHA-256 manifest signed with a local Ed25519 key. The first run creates the signing identity under ignored `.local-keys/`; never commit or share the private key. Record the printed public-key fingerprint outside the repository if independent chain-of-custody verification is required (the reference machine's fingerprint is published at https://gist.github.com/AhmedUZaki/ea3571bb522ee407d4966ff946e3cb9b).

Verify a transferred run against a separately obtained public key:

```bash
node tests/evidence-attestation.mjs verify --run-id RUN_ID --public-key /trusted/path/evidence-public-key.pem
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

## License

MIT, see `LICENSE`.
