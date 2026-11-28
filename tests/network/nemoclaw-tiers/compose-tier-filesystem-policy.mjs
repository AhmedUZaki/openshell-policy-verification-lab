// Composes a filesystem-invariance test policy: policies/filesystem-restrictive.yaml's
// filesystem_policy/landlock/process (UNCHANGED) plus one NemoClaw tier's network_policies.
// Used by tests/network/run-tier-filesystem-invariance.sh to verify docs/CLAIMS.md's other
// metamorphic relation: "filesystem invariance only with identical filesystem policies" --
// the filesystem_policy here is byte-for-byte the same across all three tiers; only the
// network_policies differ, so any difference in F1-F4 results across tiers is a real finding.
//
// Usage: node compose-tier-filesystem-policy.mjs <restricted|balanced|open> <output-file>
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DYNAMIC_PRESETS, loadTiers, networkPoliciesBlock } from "./tier-lib.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(path.dirname(path.dirname(here)));

const [, , tierName, outFile] = process.argv;
if (!tierName || !outFile) {
  console.error("Usage: compose-tier-filesystem-policy.mjs <restricted|balanced|open> <output-file>");
  process.exit(2);
}

const tiers = loadTiers();
const tier = tiers.find((t) => t.name === tierName);
if (!tier) {
  console.error(`Unknown tier: ${tierName}`);
  process.exit(2);
}

const basePolicy = fs.readFileSync(path.join(root, "policies", "filesystem-restrictive.yaml"), "utf8");
const marker = "network_policies: {}";
if (!basePolicy.includes(marker)) {
  console.error(`policies/filesystem-restrictive.yaml no longer contains "${marker}"; update this composer.`);
  process.exit(2);
}
const block = networkPoliciesBlock(tier.presets);
const composed = basePolicy.replace(marker, block ? `network_policies:\n${block}` : marker);

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, composed, "utf8");
const staticPresets = tier.presets.filter((p) => !DYNAMIC_PRESETS.has(p));
console.log(`Wrote ${path.relative(root, outFile).replaceAll("\\", "/")} (tier=${tierName}, presets=${staticPresets.join(", ") || "none"})`);
