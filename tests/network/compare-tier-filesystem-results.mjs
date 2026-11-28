// Compares F1-F4 statuses across three filesystem-test runs (one per NemoClaw tier) produced by
// run-tier-filesystem-invariance.sh. All three runs use the same filesystem_policy; only the
// network_policies differ (restricted/balanced/open), so docs/CLAIMS.md's filesystem-invariance
// relation requires every F-id's status to be identical across all three.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(path.dirname(here));
const resultsDir = path.join(root, "tests", "filesystem", "results");

const [, , restrictedRunId, balancedRunId, openRunId] = process.argv;
const TIERS = [["restricted", restrictedRunId], ["balanced", balancedRunId], ["open", openRunId]];
if (TIERS.some(([, id]) => !id)) {
  console.error("Usage: compare-tier-filesystem-results.mjs <restricted-run-id> <balanced-run-id> <open-run-id>");
  process.exit(2);
}

function readResults(runId) {
  const file = path.join(resultsDir, `filesystem-${runId}.md`);
  if (!fs.existsSync(file)) {
    console.error(`Missing filesystem report for run ${runId}: ${path.relative(root, file)}`);
    process.exit(2);
  }
  const text = fs.readFileSync(file, "utf8");
  const results = {};
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\|\s*(F[1-4]_\d{1,2})\s*\|\s*([A-Z-]+)\s*\|\s*(.*?)\s*\|$/);
    if (match) results[match[1]] = { status: match[2], detail: match[3] };
  }
  return results;
}

const resultsByTier = Object.fromEntries(TIERS.map(([tier, runId]) => [tier, readResults(runId)]));
const allIds = [...new Set(TIERS.flatMap(([tier]) => Object.keys(resultsByTier[tier])))].sort();

const rows = allIds.map((id) => {
  const statuses = TIERS.map(([tier]) => resultsByTier[tier][id]?.status ?? "MISSING");
  const invariant = statuses.every((s) => s === statuses[0]);
  return { id, statuses, invariant };
});
const violations = rows.filter((r) => !r.invariant);
const overall = violations.length ? "FAIL" : "PASS";

const lines = [
  "# Filesystem tier invariance",
  "",
  `- Overall: \`${overall}\``,
  `- Same filesystem_policy (policies/filesystem-restrictive.yaml) used in all three runs; only network_policies differed.`,
  ...TIERS.map(([tier, runId]) => `- ${tier} run: \`${runId}\``),
  "",
  "## F1-F4 status by tier",
  "",
  "| Test | restricted | balanced | open | Invariant? |",
  "|---|---|---|---|---|",
  ...rows.map((r) => `| ${r.id} | ${r.statuses[0]} | ${r.statuses[1]} | ${r.statuses[2]} | ${r.invariant ? "yes" : "**NO**"} |`),
  "",
  violations.length
    ? `## Violations\n\n${violations.map((v) => `- **${v.id}**: restricted=${v.statuses[0]}, balanced=${v.statuses[1]}, open=${v.statuses[2]} -- the network tier changed a filesystem-enforcement outcome.`).join("\n")}\n`
    : "No violations: every F1-F4 test produced the identical status under all three network tiers.\n",
].join("\n");

const outDir = path.join(root, "audit-reports", "latest");
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, "TIER-FS-INVARIANCE.md"), lines, "utf8");
fs.writeFileSync(
  path.join(outDir, "TIER-FS-INVARIANCE.json"),
  JSON.stringify({ overall, runs: Object.fromEntries(TIERS), rows }, null, 2) + "\n",
  "utf8",
);
console.log(lines);
console.log(`Report: ${path.relative(root, outDir).replaceAll("\\", "/")}/TIER-FS-INVARIANCE.md`);
process.exitCode = violations.length ? 1 : 0;
