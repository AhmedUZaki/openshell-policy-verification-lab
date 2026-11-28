# Upstream analysis: N12, provider credential leaks back into the sandbox via a reflecting response (OpenShell 0.1.9)

OpenShell's own docs (`docs.nvidia.com/openshell/<version>/security/best-practices`, "Inference Controls") state: *"The agent receives an opaque placeholder, not the real API key or access token."* and that the placeholder "resolves only for hosts, ports, and paths authorized by the provider profile." That page documents the outbound substitution mechanism (`request_body_credential_rewrite: true`, under "L4-Only vs L7 Inspection") in detail, but says nothing about the response direction - no statement that inbound responses are scrubbed or that credentials are redacted on the way back. This note is a live reproduction showing that the stated goal ("the agent receives an opaque placeholder, not the real ... token") does not hold in practice for a destination that reflects request data back: the credential-rewrite feature correctly keeps the real secret out of the sandbox's *outgoing* request, but nothing redacts it from the *response* the same destination sends back, so such a destination hands the real secret straight back to the sandboxed process - defeating the documented purpose even though no specific sentence in the docs promises response-side redaction.

N12 is part of the automated N01-N12 network suite (`docs/CLAIMS.md`), run by `tests/enforcement-audit/network/run-network-tests.sh`, which creates and tears down its own provider-attached sandbox (`ft-network-n12`) within the same run as N01-N11. This note was originally written from a manual, standalone reproduction.

## Summary

| Step | What happened | Matches the claim? |
|---|---|---|
| Sandbox builds the request | Sends the literal placeholder (`openshell:resolve:env:<nonce>_API_TOKEN`), read from its own `$API_TOKEN` environment variable | Yes - the sandboxed process never holds the real value |
| OpenShell forwards the request | Rewrites the placeholder to the real credential (`SECRET-VALUE-12345`) in the JSON request body, per `request_body_credential_rewrite: true` | Yes - this is the documented, intended behavior |
| Destination responds | The destination (here, the lab's own origin, acting as a minimal echo/debug endpoint) reflects the request body back in its 200 response | Expected of an echo endpoint; realistic for many real APIs' debug/error paths |
| Sandbox reads the response | The real secret `SECRET-VALUE-12345` appears directly in the HTTP response body the sandboxed `curl` process receives | **No** - the sandbox now holds the real credential value, contradicting "stays outside the sandbox" |

## What was measured, and how

Everything below runs against the lab's own local Caddy/origin - no real provider or external network reachability is needed for this finding (unlike N11).

1. **Origin**: `tests/enforcement-audit/network/local-test-servers/origin.py` has a minimal `/echo` handler (`GET`/`POST`) that returns the received headers and body as JSON - a stand-in for the broad class of real APIs that reflect request data in debug logs, error bodies, or validation messages.
2. **Provider profile** (`tests/enforcement-audit/network/upstream-probes/n12-provider.yaml`): a custom profile (`id: local-test-api`) declaring one `bearer`-style credential (`api_token`, env var `API_TOKEN`) and one endpoint (`host.openshell.internal:443/echo`, `protocol: rest`, `request_body_credential_rewrite: true`, `allow: POST /echo`). Imported with `openshell profile import -f`, then a provider instance created with the real secret: `openshell provider create --name testprov --type local-test-api --credential API_TOKEN=SECRET-VALUE-12345`.
3. **Sandbox**: created with the provider attached at creation time (`openshell sandbox create ... --provider testprov`; attaching to an *existing* sandbox with `sandbox provider attach` failed validation here with a network-endpoint-ambiguity error against this lab's other test policy, which is why creation-time attachment was used instead - this is a usability note, not part of the finding).
4. Inside the sandbox, `$API_TOKEN` is **not** the real secret; it is the placeholder string `openshell:resolve:env:v5324957223159289355_API_TOKEN` (the nonce is per-attachment). Confirmed with `openshell sandbox exec ... -- printenv API_TOKEN`.
5. The probe (`tests/enforcement-audit/network/upstream-probes/n12-credential-leak-probe.sh`) sends `POST /echo` with body `{"token":"$API_TOKEN"}` (i.e. the placeholder, exactly as a real tool using this provider would build its request) and prints what was sent and what came back:

   ```
   SENT BODY:     {"token":"openshell:resolve:env:v5324957223159289355_API_TOKEN"}
   RECEIVED BODY: {"token":"SECRET-VALUE-12345"}
   ```

   The real secret is visible in the second line, read inside the sandbox from an ordinary HTTP response body - no sandbox escape, no filesystem trick, no separate side channel.

## What this establishes

- **Established:** on this lab's OpenShell 0.1.9 install, `request_body_credential_rewrite` performs a one-directional substitution - placeholder-to-real-value on the way out - with no corresponding real-value-to-placeholder (or redaction) pass on the way back in, even though the same proxy is already parsing both directions of this exact connection (it has to, to return the response to the sandbox at all). Any endpoint that echoes, logs back, or error-reports part of the request body hands the real credential to the sandboxed process.
- **Established:** this is not specific to a contrived "attacker-controlled" destination. The endpoint here is one the policy itself names and trusts (`host.openshell.internal:443/echo`); the leak needs no SSRF, no redirect, no second host - only a normal, policy-approved endpoint that reflects input, which describes a large and ordinary class of real HTTP APIs (debug endpoints, input-validation error messages that quote the offending field, logging-as-a-service endpoints, etc.).
- **Not established:** whether `websocket_credential_rewrite` (the WebSocket equivalent) has the same gap - not tested. Whether this also affects `credential_binding` (the sandbox-policy-level binding for endpointless profiles, as opposed to the profile-level endpoint used here) - not tested, though the mechanism (rewrite outbound only) is likely shared. Whether `credential_signing` (AWS SigV4) has the same gap - not tested; SigV4 request signing is a different mechanism from placeholder substitution and may not expose a literal secret the same way. Whether this direction is already covered by a stated, accepted limitation elsewhere in OpenShell's published documentation (no such statement was found there) - not established.
- This is the first live confirmation of this probe shape in this lab.

## Consequence for reporting

Reproducible on demand against the lab's own infrastructure (no external provider, no real internet egress, no race condition). It is a reasonable candidate to report upstream, since it defeats the stated purpose of credential rewriting - keeping the literal secret value out of the sandboxed process - for any policy-approved endpoint that is not perfectly careful to never reflect request content.

## How to reproduce

The N12 block in `tests/enforcement-audit/network/run-network-tests.sh` runs this automatically (own sandbox `ft-network-n12`, own provider, cleaned up at the end of the same run) as part of `bash run-enforcement-audit.sh` (or `--network-only`). To reproduce just this part by hand:

```bash
bash tests/enforcement-audit/network/setup-local-test-servers.sh        # origin.py serves /echo too

openshell profile import -f policies/enforcement-audit/network-n12-provider-profile.yaml
openshell provider create --name testprov --type local-test-api --credential API_TOKEN=SECRET-VALUE-12345

openshell sandbox create --name ft-network-n12 \
  --from openshell-policy-verification/network-test-sandbox:local \
  --policy policies/enforcement-audit/network-n12-base-policy.yaml \
  --approval-mode manual \
  --env "HOST_A=host.openshell.internal" --env "HOST_A_PORT=443" \
  --provider testprov --detach

openshell sandbox exec --name ft-network-n12 --no-tty --timeout 15 -- sh -c '
  body="{\"token\":\"$API_TOKEN\"}"
  echo "SENT BODY: $body"
  curl -k -sS --max-time 10 -H "Content-Type: application/json" -d "$body" -X POST https://host.openshell.internal:443/echo
'

# cleanup:
openshell sandbox delete ft-network-n12
openshell provider delete testprov
openshell profile delete local-test-api
```
