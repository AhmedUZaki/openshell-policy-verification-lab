# Extended robustness tests (T11–T36)

These tests extend the ten core claim tests without changing `docs/CLAIMS.md`. Their expectations are defined before execution, and every destructive filesystem probe has a permissive control.

The network scope contains T01–T06 and T17–T20. The filesystem scope contains T07–T16 and T21–T36. A full run contains all 36 rows.

| ID | Area | Probe | Predefined expectation |
|---|---|---|---|
| T11 | Filesystem | Shell redirection `: > file` on a `read_only` file | Denied; size and hash unchanged. |
| T12 | Filesystem | Python `open(path, "w")` on a `read_only` file | Denied; size and hash unchanged. |
| T13 | Filesystem | In-place `dd conv=notrunc` overwrite | Denied; hash unchanged. |
| T14 | Filesystem | Rename a file inside the `read_only` directory | Denied; original remains and destination is absent. |
| T15 | Filesystem | Create a new file inside the `read_only` directory | Denied; new file is absent. |
| T16 | Filesystem | Change mode bits with `chmod` | `KNOWN-LIMITATION` if changed: Landlock does not mediate `chmod`. |
| T17 | Network | Copy `/usr/bin/curl` to `/tmp/curl-copy` and call the allowed URL | Denied by binary identity; origin receives no request. |
| T18 | Network | Send `HEAD /public` where an explicit GET rule exists | `EXPECTED`: OpenShell intentionally treats HEAD as matching GET; the origin receives the request. |
| T19 | Network | Send `/public/../private` with `--path-as-is` | Denied; origin receives no request. |
| T20 | Network | Send allowed `GET /public` with a query string | Allowed and logged. This positive control detects over-blocking. |
| T21 | Filesystem | Create a hard link inside `read_only` | Denied; link absent. |
| T22 | Filesystem | Create a symbolic link inside `read_only` | Denied; link absent. |
| T23 | Filesystem | Create a directory inside `read_only` | Denied; directory absent. |
| T24 | Filesystem | Remove an empty directory inside `read_only` | Denied; directory remains. |
| T25 | Filesystem | Change modification time with `utime` | `KNOWN-LIMITATION` if changed: Landlock does not mediate `utime`. |
| T26 | Filesystem | Add a `user.*` extended attribute | `KNOWN-LIMITATION` if changed: Landlock does not mediate `setxattr`. |
| T27 | Filesystem | Move a file from `read_only` to writable `/work` | Denied; source remains and destination is absent. |
| T28 | Filesystem | Copy a readable file from `read_only` to `/work` | Allowed; source and copied hashes match. Positive precision control. |
| T29 | Filesystem | Follow a symlink in `read_only` to an ungranted target | Target content remains inaccessible. |
| T30 | Filesystem | Write through a symlink in `/work` whose target is `read_only` | Denied; target hash unchanged. |
| T31 | Filesystem | Modify content through a writable `mmap` | Denied; target hash unchanged. |
| T32 | Filesystem | Open with unusual `O_RDONLY | O_TRUNC` flags | Denied; size/hash unchanged. Analyze a failure jointly with T09; these observations alone do not identify the kernel mechanism. |
| T33 | Filesystem | Bind a pathname UNIX socket inside `read_only` | Denied; socket absent. |
| T34 | Filesystem | Create a FIFO inside `read_only` | Denied; FIFO absent. |
| T35 | Filesystem | Execute a script stored under `read_only` | `EXPECTED`: execution remains allowed for this policy; separate tests measure content mutation. |
| T36 | Filesystem | Use `stat` on an otherwise ungranted file | `KNOWN-LIMITATION` if metadata is returned: Landlock does not mediate `stat`. |

## Interpretation rule

A larger number of FAIL rows does not automatically mean a larger number of vulnerabilities. For example, T09, T11, and T12 may exercise different user-level interfaces to the same kernel operation. Correlated failures should be grouped into one provisional finding until evidence shows independent causes. Grouping prevents double counting; it does not by itself establish a root cause.

`FAIL` means an enforcement expectation failed. `KNOWN-LIMITATION` records behavior predefined as outside the mediation scope measured by this lab and does not count as an independent enforcement failure. `EXPECTED` records predefined product semantics. `INCONCLUSIVE` means the control, prerequisites, or test infrastructure did not establish a valid comparison.
