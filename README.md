# OpenShell policy verification lab

This project runs thirty-six local enforcement tests and automatically analyzes their evidence:

- T01–T06: network destination, proxy bypass, binary identity, HTTP method/path, and policy-generation revocation.
- T07–T10: inaccessible and read-only filesystem behavior.
- T11–T16 and T21–T36: extended content, namespace, symlink, special-file, execution, and metadata filesystem probes.
- T17–T20: copied-binary identity, additional REST boundaries, path normalization, and a positive precision control.

No public test server, domain, Cloudflare account, model provider, or API credential is required.

## Platform support

| Host | Status for this lab | Required path |
|---|---|---|
| Windows 10/11 x86-64 | Validated only on Windows 11 (this project machine); Windows 10 untested; supported with conditions | WSL 2, the project-managed `Ubuntu-24.04` distro, Docker Desktop WSL integration |
| macOS Apple Silicon | Implementation target; empirical validation pending | Homebrew, Docker Desktop, pinned NemoClaw/OpenShell |
| Linux Ubuntu 24.04 x86-64/arm64 | Primary implementation target; separate native-host validation pending | Docker Engine/Desktop and a working systemd user manager |
| Other systemd Linux distributions | Best effort | Docker plus a compatible pinned NemoClaw/OpenShell installation |
| Intel macOS or native Windows without WSL 2 | Not supported by this runner | Use a supported host above |

This is not a claim that every machine with one of these operating systems will work. Port 443 must be free on Windows/WSL and Linux; ports 443 and 444 must be free on macOS. Docker must be reachable by the current user, and the machine must meet the pinned NemoClaw requirements. The main runner is portable; `tests/network/run-legacy-openshell-probes.sh` is a retained Linux/WSL-only historical helper and is not part of T01–T36.

## One-command execution

### Windows

Requirements: Docker Desktop, WSL 2, and the `Ubuntu-24.04` distribution configured by `setup/`.

```text
run-enforcement-audit.cmd
```

The interactive menu asks whether to run network tests, filesystem tests, or both. Choosing network runs T01–T06 and T17–T20; choosing filesystem runs T07–T16 and T21–T36.

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
```

When no scope option is supplied in an interactive terminal, a bilingual menu is shown. Scripts and CI jobs must pass one explicit scope option.

| Scope | Tests | Result rows |
|---|---|---|
| `--network-only` | T01–T06, T17–T20 | 10 |
| `--filesystem-only` | T07–T16, T21–T36 | 26 |
| `--all` | T01–T36 | 36 |

## Automatic analysis

The runner gives every invocation one audit run ID. The analyzer accepts only reports carrying that exact ID, checks every expected test in the selected scope, and writes:

```text
audit-reports/LATEST.md
audit-reports/LATEST_AR.md
audit-reports/LATEST.json
```

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

Every real audit run also creates a SHA-256 manifest signed with a local Ed25519 key. The first run creates the signing identity under ignored `.local-keys/`; never commit or share the private key. Record the printed public-key fingerprint outside the repository if independent chain-of-custody verification is required.

Verify a transferred run against a separately obtained public key:

```bash
node tests/evidence-attestation.mjs verify --run-id RUN_ID --public-key /trusted/path/evidence-public-key.pem
```

Exit codes are stable for local automation and CI:

- `0`: every measured expectation passed.
- `1`: at least one measured expectation returned `FAIL`.
- `2`: infrastructure failure, missing result, or inconclusive result.

The overall label is `PASS_WITH_LIMITATIONS` rather than plain `PASS` whenever a measured `KNOWN-LIMITATION` is present. Infrastructure failures and unreadable evidence are never inferred to be successful enforcement.

Before producing an overall result, the analyzer verifies the signed evidence manifest and every recorded SHA-256 digest. It also verifies the run ID embedded in each report, rejects duplicate test rows, checks the evidence-complete marker, and requires the corresponding raw logs, origin logs, and policy snapshots. Missing, modified, unsigned, or malformed evidence makes the run `INCOMPLETE` with exit code `2`.

The analyzer treats T01–T10 as the core suite and T11–T36 as predefined extended robustness tests. It separates enforcement failures from `KNOWN-LIMITATION` and `EXPECTED` behavior. Correlated failures are grouped to avoid double counting, but the analyzer does not infer a specific root cause from correlation alone.

The evaluation design, verdict semantics, evidence chain, bounded assurance claim, platform acceptance criteria, and threats to validity are documented in `docs/METHODOLOGY.md`, `docs/ASSURANCE_SCOPE.md`, and `docs/PLATFORM_VALIDATION.md`. The predefined test expectations are in `docs/CLAIMS.md` (T01–T10) and `docs/EXTENDED_TESTS.md` (T11–T36).

The tracked repository contains only `.gitkeep` placeholders in generated-result directories; local runs may populate those ignored directories. Running `run-enforcement-audit.cmd` or `run-enforcement-audit.sh` generates fresh evidence belonging to the current user. Development-run evidence under `.local-reference-material/archived-results/` is historical and is never selected by the analyzer.
