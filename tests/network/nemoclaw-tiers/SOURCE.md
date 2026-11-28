# Source of these files

Copied verbatim (unmodified) from the pinned NemoClaw installation this lab tests against:

- Repository: `https://github.com/NVIDIA/NemoClaw.git`
- Pinned tag: `v0.0.140`
- Commit: `88fe14f3fb9a0bf72997cce19ec88b5b2ee08391` (matches `setup/4-install-nemoclaw.sh`)
- Upstream path: `nemoclaw-blueprint/policies/tiers.yaml` and `nemoclaw-blueprint/policies/presets/{npm,pypi,huggingface,brave,brew-balanced,brew,weather,public-reference,jira,outlook}.yaml`
- License: Apache-2.0, per each file's own SPDX header (unchanged).

`tiers.yaml` is NemoClaw's own definition of the Restricted/Balanced/Open/Personal tiers referenced in `docs/CLAIMS.md`'s "Policy comparisons" line ("Restricted/Balanced/Open are NemoClaw presets ... not OpenShell built-in tiers"). These are the real, shipped definitions, not a researcher-authored approximation.

## Scope limitation

The Open tier also includes six messaging-platform presets (`slack`, `discord`, `telegram`, `wechat`, `whatsapp`, `teams`) that are **not** static preset YAML files: NemoClaw compiles their network policy at onboarding time through a separate, credential/OAuth-backed messaging subsystem (`src/lib/messaging/`). Reproducing that would require live OAuth setup for six third-party platforms, which is out of scope for an offline, deterministic check. `tests/network/check-tier-monotonicity.mjs` therefore verifies monotonicity using Balanced's 5 presets and Open's 4 additional *static* presets (`weather`, `public-reference`, `jira`, `outlook`); the 6 messaging presets are excluded and this exclusion is reported explicitly, not silently dropped.

The Personal tier (`personal-open-internet`, broad L4 passthrough) is not part of this check: the critique's metamorphic relation (#7) names Restricted/Balanced/Open only.
