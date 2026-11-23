# Upstream analysis: why T09 and T32 fail on OpenShell 0.0.116

The black-box tests in this lab measure *what* happened (a `read_only` file was truncated). They cannot say *why*, or whether the behavior was intentional. This note answers that from the public OpenShell source, and states exactly how far the evidence goes.

## Question

OpenShell 0.0.116 applied Landlock ABI **V2** (`abi:V2` in the recorded logs). Was choosing V2 a deliberate design decision, or a limitation of that release?

## Answer

**A limitation of 0.0.116, not a deliberate decision to leave truncation unprotected.** The upstream project later raised the ABI to V3 specifically so that read-only policy also denies pathname truncation.

## Evidence

| # | Evidence | Where |
|---|---|---|
| 1 | The lab's own run recorded `Applying Landlock filesystem sandbox [abi:V2 compat:HardRequirement ...]`, while the same kernel reports ABI 7 when queried directly. The kernel was not the limit. | `tests/filesystem/results/*.md`, section "Landlock-related log lines" |
| 2 | In the `v0.0.116` source the ABI is a hard-coded constant, not probed: `let abi = ABI::V2;` followed by `AccessFs::from_all(abi)`. There is no comment explaining the choice. | `crates/openshell-supervisor-process/src/sandbox/linux/landlock.rs`, line 190 |
| 3 | Landlock only added the truncate access right in ABI v3 (Linux 6.2). A ruleset built from `AccessFs::from_all(ABI::V2)` therefore does not handle `truncate`, `ftruncate`, or `open(O_TRUNC)`. This matches T09 (`truncate`) and T32 (`O_RDONLY|O_TRUNC`) failing while T08, T10–T15 and T21–T24 pass. | Landlock kernel documentation; OpenShell's own comment in evidence 5 |
| 4 | The `v0.0.116` documentation says `best_effort` "uses the highest Landlock ABI the host kernel supports". The code above requests V2 in both modes, so on this release the documentation and the code disagree. | `docs/reference/support-matrix.mdx` line 91; `docs/security/best-practices.mdx` line 166 |
| 5 | In `v0.1.9` the same function says: "Read-only policy must also deny pathname truncation... `let abi = ABI::V3;`". A separate constant states "ABI v3, introduced in Linux 6.2, adds pathname truncation", and startup fails with a clear error on older kernels. | `crates/openshell-sandbox/src/sandbox/linux/landlock.rs`, around lines 76 and 303–312 |

Evidence 5 is the decisive one: the maintainers themselves state that denying truncation requires ABI v3 and changed the code for that reason.

## What this does and does not establish

- **Established:** the V2 constant in 0.0.116 explains T09 and T32 and was later changed upstream with a stated truncation rationale. T09 and T32 should therefore be described as one finding: *"0.0.116 requests Landlock ABI V2, which cannot restrict truncation"*, not as two independent vulnerabilities and not as a Landlock kernel bug.
- **Not established by running code:** this lab has **not** run OpenShell `v0.1.9`. That T09 and T32 then pass is an expectation drawn from reading the source, not a measurement. It requires a host kernel of 6.2 or newer; the reference WSL kernel (6.18) qualifies.
- **Not established:** the exact upstream commit or issue that made the change (not found in public search), and whether any intermediate release between 0.0.116 and 0.1.9 changed it first.
- The source was read from a clone of tag `v0.0.116`. The installed binary reports the same version and the same `abi:V2` log line, which is consistent but is not a binary-level proof.
- NVIDIA's own pages were not used as authority; only the OpenShell repository at the tagged versions.

## Consequence for reporting

Because the behavior appears fixed upstream, it is not a good candidate for reporting as a new vulnerability. A more accurate framing for any communication is: *"OpenShell 0.0.116 handled Landlock ABI V2 only, so read-only policy did not prevent truncation (T09, T32); documentation at that version described best-effort as using the highest ABI."* The useful follow-up is to confirm the fix empirically.

## How to run the check

On Docker Desktop with WSL 2, OpenShell 0.1.x currently cannot start sandboxes on the reference machine (see `setup/README.md`, "Testing OpenShell 0.1.x ... known blocker"); until that is solved the 0.1.9 run is `INCOMPLETE`.

```bash
bash setup/4b-install-openshell-versions.sh        # optional: download 0.0.116 and 0.1.9 ahead of time
bash run-enforcement-audit.sh --all --compare       # runs both, writes audit-reports/COMPARISON.md
```

`COMPARISON.md` contains a **Prediction check** table: T09 and T32 were written down as `FAIL` on 0.0.116 and `PASS` on 0.1.9 before 0.1.9 was measured. `CONFIRMED` supports this note; `CONTRADICTED` means this note is wrong or incomplete; an `INCOMPLETE` run of 0.1.9 means the lab scripts did not work with that release and nothing can be concluded yet.
