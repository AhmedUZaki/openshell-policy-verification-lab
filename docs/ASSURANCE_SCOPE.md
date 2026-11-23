# Bounded assurance statement

## Defensible conclusion

For a named run ID, recorded environment, applied policies, and signed evidence bundle, this lab determines whether T01–T36 matched their predefined expectations. A complete run supports only conclusions about those tested operations and boundaries.

## Claim-to-test coverage

| Assurance area | Primary tests | Additional robustness probes |
|---|---|---|
| Destination, port, and executable identity | T01–T03 | T17 |
| REST method and path restrictions | T04–T05 | T18–T20 |
| Policy-generation revocation | T06 | — |
| Ungranted-path confidentiality | T07 | T29, T36 |
| Read-only content and namespace integrity | T08–T10 | T11–T15, T21–T24, T27, T30–T34 |
| Positive precision controls | allowed network baseline plus permissive filesystem controls | T20, T28, T35 |
| Explicit mediation-scope observations | — | T16, T25, T26, T36 |

## Conclusions this lab does not support

- “OpenShell has no bypasses.”
- “Every OpenShell version and host platform behaves identically.”
- “A `PASS` proves universal security.”
- “Multiple correlated failures are automatically multiple vulnerabilities.”
- “A signed bundle proves the experiment was honestly designed or interpreted.”

Those statements are not testable from a finite black-box suite. Removing them is not a weakness in the project; it is the correct scientific boundary.

## Extending assurance

New attack hypotheses should be added as predefined tests with a permissive control, restrictive expectation, raw evidence, and an explicit mapping to the assurance area above. A new test broadens observed coverage but must not silently broaden the conclusion beyond what it exercised.

For network probes where a separate permissive sandbox is not used, the equivalent validity evidence must include a healthy local origin, a working allowed baseline, a healthy sandbox after the request, a recognized enforcement-denial signal, and origin-log correlation.
