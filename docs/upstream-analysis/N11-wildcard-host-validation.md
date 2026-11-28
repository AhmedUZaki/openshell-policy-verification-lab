# Upstream analysis: N11, wildcard host validation on OpenShell 0.1.9 and 0.1.10

GitHub issue: https://github.com/ai-openshell/openshell/issues/5623, titled "bug(policy): overly broad host wildcards like `**.*.*` pass validation" (open as of 2026-11-27, linked to PR #5621, also open). The issue describes which wildcard host patterns should be rejected by policy validation; OpenShell's published docs (`docs.nvidia.com/openshell/<version>/security/best-practices`) separately state the general network model is deny-by-default ("All egress denied. Only endpoints listed in `network_policies` can receive traffic.") but do not document specific wildcard-pattern validation rules anywhere this lab checked. This note records an independent live reproduction, on two OpenShell releases, with full request/response evidence - not just a reading of the issue text.

N11 is part of the automated N01-N12 network suite (`docs/CLAIMS.md`), run by `tests/network/run-network-tests.sh`; it does not use the restrictive-baseline policy for its own probe, because the finding is specifically about what the validator accepts in place of that baseline - the script swaps `ft-network`'s policy for the duration of the probe and reverts it afterward, the same pattern N06 already uses for its own policy change. This note was originally written from a manual, standalone reproduction across several OpenShell releases (0.1.9, 0.1.10); the automated N11 test now exercises the single riskiest pattern (`**.*.*`) on every run.

## Summary

| # | Host pattern | Issue's expectation | Measured here (0.1.9, 0.1.10) |
|---|---|---|---|
| N11a | `**.*.*` | reject | **accepted**; live egress to a real internet host confirmed on both versions |
| N11b | `*.*.*` | reject | **accepted** |
| N11c | `a*.*` | reject (no fixed suffix) | rejected (`L7 policy validation failed: invalid L7 policy configuration`) |
| N11d | `*.*.com` | reject (one fixed suffix only) | **accepted** |
| N11e | `foo.*.com` | listed as passing | **accepted** |
| N11f | `a*.com` | issue says it passes | rejected here |
| N11g | `api.github.*` | wildcard in the suffix opens unspecified domains | **accepted** |
| N11h | `*.example.{com,io}` | unanchored brace glob | **accepted** |

7 of 8 tested patterns were accepted by `openshell policy set` when the issue says they should be rejected; 2 (`a*.*`, `a*.com`) are rejected on the measured releases, which the issue itself does not claim for `a*.*` and contradicts for `a*.com` - so validation is not purely absent, but it is inconsistent and the two riskiest shapes tested (an all-wildcard host and several "public-looking" suffix wildcards) both slip through.

## What was measured, and how

Sandbox: `ft-network`, created by `tests/network/create-network-test-sandbox.sh` against the lab's own local Caddy/origin, then given a policy whose only network rule is the pattern under test (`protocol: rest`, `allow: {method: GET, path: /public}`, no `allowed_ips` restriction) - i.e. the pattern is the *only* thing standing between the sandbox and the open internet.

1. `openshell policy set ft-network --policy <file-with-the-pattern> --wait` - records accept (`Policy version N loaded`) or reject (`L7 policy validation failed`).
2. For N11a only, on both versions: from inside the sandbox, `curl https://www.example.com/public`. This is the decisive step - a pattern can be *accepted* without *proving* real egress, since the sandbox's network path still has to carry the connection through to a real host.
3. Immediately after each test, the policy was reverted to the lab's own generated restrictive policy (`tests/network/.state/network-generated.yaml`: named host, single allowed path, `allowed_ips` pinned to the local Caddy container) and reachability to `www.example.com` was re-checked to confirm it was closed again.

### N11a (`**.*.*`) - full reproduction, both versions

`openshell policy set` accepted the pattern with no validation error on both 0.1.9 and 0.1.10 (`Policy version N loaded`). From inside the sandbox:

```
curl -k -sS -i --max-time 10 https://www.example.com/public
```

returned, on both versions, a genuine response from the real `www.example.com` (not the lab's own origin):

```
HTTP/1.1 404 Not Found
Server: cloudflare
CF-RAY: a614b836b8f917d4-YYZ   (0.1.9)  /  a614c201b8c07114-YYZ  (0.1.10)
x-openshell-request-id: <uuid>
<title>Example Domain</title>
...
```

`x-openshell-request-id` is a header OpenShell's own proxy adds; its presence shows the request was mediated and approved by OpenShell itself, not reaching the internet by some path outside its control. `Server: cloudflare` and the literal "Example Domain" page are not reproducible by the lab's own origin (which returns a `text/plain` 404 "NOT_FOUND" body with no such headers), so this is a real external host, not an artifact of the local test harness.

### N11b-N11h - validation only (0.1.9)

Only *validation* (accept/reject) was measured for N11b-N11h; reachability was not re-confirmed for each, since N11a already demonstrates that an accepted all-wildcard pattern reaches the real internet, and the point of this batch is the breadth of the validation gap, not a second reachability proof. Reproduced by `tests/network/upstream-probes/n11-wildcard-validation-probe.sh`, which builds a policy per pattern, submits it, records the outcome, and reverts to the lab's generated restrictive policy after every attempt (so no pattern is left active between tests).

## What this establishes

- **Established:** on this lab's OpenShell 0.1.9 and 0.1.10 installs, a sandbox policy using the host pattern `**.*.*` is accepted by `openshell policy set` and genuinely routes the sandbox's HTTPS traffic to an arbitrary real internet host with three or more labels, through OpenShell's own request-mediation path (confirmed by the `x-openshell-request-id` header on the real response).
- **Established:** the same acceptance (without the second reachability check) also occurs for `*.*.*`, `*.*.com`, `foo.*.com`, `api.github.*`, and `*.example.{com,io}` on 0.1.9.
- **Not established:** whether `a*.*` and `a*.com` are rejected on every 0.1.x release, or only on 0.1.9/0.1.10 (the GitHub issue's own author found `a*.com` passing at one validation surface, which did not match the result measured here, so either the specific check differs by release, by validation surface - `policy set` on a live sandbox versus other input paths such as `policy update`, proposal approval, or provider profile import/update/lint - or the installed build differs from what was described). Only the `policy set` surface was exercised; the other input paths named in the issue were not tested in this lab.
- **Not established:** reachability for any pattern other than `**.*.*`, or on any OpenShell release other than 0.1.9 and 0.1.10.
- This finding is narrower than this lab's general wildcard/DNS-egress limitation note: it is specifically that policy validation accepts several wildcard host shapes that, by the stated deny-by-default model, should not be able to open egress this broad.

## Consequence for reporting

Reproducible on-demand, with a live egress proof (not just an accepted policy) on both the version this lab treats as the candidate release (0.1.9) and the latest stable release (0.1.10) as of 2026-11-27. This is a strong candidate to report upstream if it is not already reflected in issue #5623 (it already is open there; this note adds an independent, dated reproduction with evidence that could be attached as a comment).

## How to reproduce

The N11 block in `tests/network/run-network-tests.sh` runs this automatically as part of `bash run-enforcement-audit.sh` (or `--network-only`). To reproduce just this part by hand:

```bash
bash tests/network/setup-local-test-servers.sh
bash tests/network/create-network-test-sandbox.sh
openshell policy set ft-network --policy policies/network-n11-wildcard-policy.yaml --wait
openshell sandbox exec --name ft-network --no-tty --timeout 15 -- \
  curl -k -sS -i --max-time 10 https://www.example.com/public
# revert immediately:
openshell policy set ft-network --policy tests/network/.state/effective-policy-initial.yaml --wait
```

To repeat on a different OpenShell release:

```bash
bash setup/4b-install-openshell-versions.sh use 0.1.10   # or any stored version
bash tests/network/cleanup-network-test-environment.sh
bash tests/network/setup-local-test-servers.sh
bash tests/network/create-network-test-sandbox.sh
# ...then the policy set / curl / revert steps above
bash setup/4b-install-openshell-versions.sh use 0.0.116  # restore the lab's reference baseline
```
