# Upstream analysis: T09 and T32 (truncation) on OpenShell 0.0.116 and 0.1.x

The black-box tests in this lab measure *what* happened (a `read_only` file was truncated). They cannot say *why*, or whether the behavior was intentional. This note records what is known about the two truncation tests, T09 and T32, from the public OpenShell source, from the lab's own measurements, and from follow-up work, and states exactly how far each piece of evidence goes.

## Summary

| Test | 0.0.116 | 0.1.9 (measured 2026-11-22) | Cause |
|---|---|---|---|
| T09 `truncate()` on a read-only file | FAIL | **PASS** (denied; size and hash unchanged) | Landlock ABI **V2** was hard-coded in 0.0.116 and cannot restrict truncation; 0.1.x uses ABI **V3**. Confirmed by measurement. |
| T32 `open(O_RDONLY\|O_TRUNC)` on a read-only file | FAIL | **FAIL** (the call returns `Permission denied`, yet the file is emptied) | **Not** the ABI. The file is emptied because of the **order of two kernel checks** (overlayfs copy-up, then Landlock's truncate check). See "T32 after the measurement" below. |

T09 and T32 are therefore **two different findings**, not one. An earlier version of this note expected T32 to pass on 0.1.9 for the same reason as T09; the measurement contradicted that expectation.

## Part 1: T09 and the Landlock ABI

### Question

OpenShell 0.0.116 applied Landlock ABI **V2** (`abi:V2` in the recorded logs). Was choosing V2 a deliberate design decision, or a limitation of that release?

### Answer

**A limitation of 0.0.116, not a deliberate decision to leave truncation unprotected.** The upstream project later raised the ABI to V3 specifically so that read-only policy also denies pathname truncation.

### Evidence

| # | Evidence | Where |
|---|---|---|
| 1 | The lab's own run recorded `Applying Landlock filesystem sandbox [abi:V2 compat:HardRequirement ...]`, while the same kernel reports ABI 7 when queried directly. The kernel was not the limit. | `tests/filesystem/results/*.md`, section "Landlock-related log lines" |
| 2 | In the `v0.0.116` source the ABI is a hard-coded constant, not probed: `let abi = ABI::V2;` followed by `AccessFs::from_all(abi)`. There is no comment explaining the choice. | `crates/openshell-supervisor-process/src/sandbox/linux/landlock.rs`, line 190 |
| 3 | Landlock only added the truncate access right in ABI v3 (Linux 6.2). A ruleset built from `AccessFs::from_all(ABI::V2)` therefore does not handle `truncate`, `ftruncate`, or `open(O_TRUNC)`. This matches T09 (`truncate`) failing on 0.0.116. (It was first thought to explain T32 as well; Part 2 shows it does not.) | Landlock kernel documentation; OpenShell's own comment in evidence 5 |
| 4 | The `v0.0.116` documentation says `best_effort` "uses the highest Landlock ABI the host kernel supports". The code above requests V2 in both modes, so on this release the documentation and the code disagree. | `docs/reference/support-matrix.mdx` line 91; `docs/security/best-practices.mdx` line 166 |
| 5 | In `v0.1.9` the same function says: "Read-only policy must also deny pathname truncation... `let abi = ABI::V3;`". A separate constant states "ABI v3, introduced in Linux 6.2, adds pathname truncation", and startup fails with a clear error on older kernels. | `crates/openshell-sandbox/src/sandbox/linux/landlock.rs`, around lines 76 and 303-312 |

Evidence 5 is the decisive one: the maintainers themselves state that denying truncation requires ABI v3 and changed the code for that reason.

### What this establishes

- **Established:** the V2 constant in 0.0.116 explains T09, and was later changed upstream with a stated truncation rationale. Measured on 2026-11-22: T09 fails on 0.0.116 and passes on 0.1.9 (size and hash unchanged), so the prediction was confirmed.
- **Not established:** the exact upstream commit or issue that made the change (not found in public search), and whether any intermediate release between 0.0.116 and 0.1.9 changed it first.
- The source was read from a clone of tag `v0.0.116`. The installed binary reports the same version and the same `abi:V2` log line, which is consistent but is not a binary-level proof.
- NVIDIA's own pages were not used as authority; only the OpenShell repository at the tagged versions.
- Because T09 appears fixed upstream, it is not a good candidate for reporting as a new vulnerability.

## Part 2: T32 on OpenShell 0.1.9 (2026-11-22)

All 36 tests ran on both versions through `run-enforcement-audit --all --compare`. For T32 on 0.1.9 the report records, for the restrictive sandbox, a file with SHA-256 `0cd1293b...` and 26 bytes before the call. The call returns `PermissionError: [Errno 13]`, and afterwards the file is 0 bytes with the SHA-256 of an empty file (`e3b0c442...`). A diagnostic run reproduced exactly this: the open is reported as denied **and** the content is gone.

What this shows, as measured at that time:

- A read-only file lost its content through an open that the sandbox reported as denied, on 0.1.9.
- **It is not caused by the lab's test code.** The same behavior appears with plain statements run through `openshell sandbox exec` on different fixtures, without the lab's test sequence (read-only fixtures, restrictive policy; size before and after, and what the call reported):

  | Call on a read-only file | 0.0.116 | 0.1.9 |
  |---|---|---|
  | `open(O_RDONLY)` | opens, unchanged | opens, unchanged |
  | `open(O_RDONLY\|O_TRUNC)`, two different files | **emptied, no error** | **emptied, `Permission denied`** |
  | `open(O_WRONLY\|O_TRUNC)` / `open(O_RDWR\|O_TRUNC)` | denied, unchanged | denied, unchanged |
  | `os.truncate(path, 0)` | **emptied, no error** | denied, unchanged |
  | `open(path, "w")` / shell `: >` | denied, unchanged | denied, unchanged |

  So on 0.1.9 only the `O_RDONLY|O_TRUNC` combination both reports an error and empties the file.
- A standalone Landlock test, outside OpenShell (`tests/diagnostics/landlock_truncate_probe.py`, temp directory only), behaved differently on the same kernel: with the V2 rights the open truncates the file, with the V3 rights the open fails **and the file stays intact**. That test used a file in an ordinary temporary directory; the T32 fixture ships in the sandbox image. The follow-up below shows that this difference matters.
- The workload processes run with seccomp filters on both versions (5 on 0.0.116, 7 on 0.1.9; `NoNewPrivs` set, uid 1500). The follow-up below reproduces the behavior without any OpenShell seccomp filters, so they are not needed to produce it.

### T32 after the measurement (follow-up, 2026-11-26)

Later work, kept in a separate public repository ([openshell-readonly-truncate-repro](https://github.com/AhmedUZaki/openshell-readonly-truncate-repro), see its `REPORT_where_is_the_problem.md`), found the following. It is **not** part of this lab's signed evidence and was measured on **one kernel** (WSL 2, 6.18.58.1-microsoft-standard-WSL2):

- **The ABI is not the cause.** T32 fails in 5 of 5 runs on each OpenShell release from 0.1.1 to 0.1.10 (on a kernel reporting Landlock ABI 7; the ABI V3 constant was read in the source of 0.1.9 and 0.1.10 only).
- **It does not need OpenShell or Docker.** With an overlayfs mounted by hand and the same Landlock read-only rights, `open(O_RDONLY|O_TRUNC)` on a file that exists only in the **lower** layer returns `EACCES` and empties the file (the lower file itself is unchanged; the empty copy is created in the upper layer). The same call on a plain directory, on a file already in the upper layer, with `O_WRONLY|O_TRUNC`, or with `os.truncate()` is denied and leaves the file intact. This explains why the standalone probe above (temp directory) did not reproduce it: that file was not in an overlayfs lower layer.
- **Cause: the order of two kernel checks**, measured with ftrace and read in Linux v6.18: Landlock's open-time check passes for a read-only open; overlayfs then copies the file up, creating the copy with size 0 because of `O_TRUNC`; only afterwards does Landlock's truncate check deny the call. The empty copy stays.
- OpenShell does not cause it, but it is affected: its `read_only` guarantee relies on Landlock, and the default Docker storage uses overlayfs.
- **Limits:** one kernel; the kernel source was read in vanilla v6.18, not the exact WSL tree; whether kernel maintainers regard it as a bug or a known limitation is not known; which side should change was not tested.

## Consequence for reporting

- **T09:** fixed upstream, so not a candidate for reporting as a new vulnerability. The accurate framing is: *"OpenShell 0.0.116 handled Landlock ABI V2 only, so read-only policy did not prevent truncation (T09); the documentation at that version described best-effort as using the highest ABI."*
- **T32:** reproducible on every 0.1.x release tested and without OpenShell, so it is a kernel-level interaction that affects OpenShell's `read_only` guarantee. It can be described as an observation with the evidence above (versions, before and after hashes, the error, the order of checks), not as a vulnerability in OpenShell's code. Whether and where to report it (OpenShell, kernel maintainers) is undecided; the separate repository holds the reproduction kit and report.

## How to run the check

On the reference machine OpenShell 0.1.x sandboxes now start (see `setup/README.md`, "Testing OpenShell 0.1.x"), and the 36-test comparison above was measured with:

```bash
bash setup/4b-install-openshell-versions.sh        # optional: download 0.0.116 and 0.1.9 ahead of time
bash run-enforcement-audit.sh --all --compare       # runs both, writes audit-reports/COMPARISON.md
```

`COMPARISON.md` contains a **Prediction check** table: T09 and T32 were written down as `FAIL` on 0.0.116 and `PASS` on 0.1.9 before 0.1.9 was measured. `CONFIRMED` supports the prediction; `CONTRADICTED` means it was wrong or incomplete; an `INCOMPLETE` run means the lab scripts did not work with that release and nothing can be concluded yet. Result on 2026-11-22: T09 **confirmed**, T32 **contradicted** (see Part 2).
