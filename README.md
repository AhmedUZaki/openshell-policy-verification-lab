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
| Windows 10/11 x86-64 | Tested on this project machine; supported with conditions | WSL 2, the project-managed `Ubuntu-24.04` distro, Docker Desktop WSL integration |
| macOS Apple Silicon | Supported design; not executed on a Mac during this review | Homebrew, Docker Desktop, pinned NemoClaw/OpenShell |
| Linux Ubuntu 24.04 x86-64/arm64 | Primary supported design; not executed on a separate native Linux host during this review | Docker Engine/Desktop and a working systemd user manager |
| Other systemd Linux distributions | Best effort | Docker plus a compatible pinned NemoClaw/OpenShell installation |
| Intel macOS or native Windows without WSL 2 | Not supported by this runner | Use a supported host above |

This is not a claim that every machine with one of these operating systems will work. Ports 443 and 444 must be free, Docker must be reachable by the current user, and the machine must meet the pinned NemoClaw requirements. The main runner is portable; `tests/network/run-legacy-openshell-probes.sh` is a retained Linux/WSL-only historical helper and is not part of T01-T36.

## One-command execution

### Windows

Requirements: Docker Desktop, WSL 2, and the `Ubuntu-24.04` distribution configured by `setup/`.

```text
run-enforcement-audit.cmd
```

For a terminal or CI job without the final pause:

```text
run-enforcement-audit.cmd nopause
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

The pinned OpenShell release supports this automated macOS gateway workflow on Apple Silicon. The runner reports an infrastructure error on Intel macOS instead of producing misleading results.

## Runner options

```text
--network-only
--filesystem-only
--keep
--dry-run
```

## Automatic analysis

The runner selects the latest network and filesystem reports, checks that T01–T10 are present, and writes:

```text
audit-reports/LATEST.md
audit-reports/LATEST_AR.md
audit-reports/LATEST.json
```

Run analysis without rerunning the experiments:

```bash
bash tests/analyze-results.sh
```

Windows:

```text
tests\analyze-results.cmd
```

Exit codes are stable for local automation and CI:

- `0`: every measured expectation passed.
- `1`: at least one measured expectation returned `FAIL`.
- `2`: infrastructure failure, missing result, or inconclusive result.

The analyzer treats T01–T10 as the core suite and T11–T36 as predefined extended robustness tests. It separates enforcement failures from `KNOWN-LIMITATION` and `EXPECTED` behavior; correlated failures may share one root cause.

The active result directories are intentionally empty in the distributed project. Running `run-enforcement-audit.cmd` or `run-enforcement-audit.sh` generates fresh evidence belonging to the current user. Development-run evidence is kept separately under `.local-reference-material/archived-results/` and is never selected by the analyzer.
