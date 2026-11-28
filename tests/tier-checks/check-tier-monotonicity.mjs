// Checks the network metamorphic relation from docs/CLAIMS.md ("Policy comparisons"):
// any destination allowed under a narrower NemoClaw tier must still be allowed under every
// wider tier (Restricted -> Balanced -> Open). This is a static, offline check over the real
// tier/preset definitions vendored in tests/tier-checks/nemoclaw-tiers/ (see its SOURCE.md) -- it
// does not create a sandbox or make any network request.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  DYNAMIC_PRESETS, buildTierMap, extractEndpoints, loadTiers, presetsDir,
} from "./nemoclaw-tiers/tier-lib.mjs";
import { archiveExistingReport } from "./archive-previous-report.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(path.dirname(here));

// Is `narrow`'s grant for one destination still allowed under `wide`'s grant for the same
// destination? `wide` undefined means the destination disappeared entirely: not covered.
function isCovered(narrow, wide) {
  if (!wide) return false;
  if (wide.access === "full") return true;
  if (narrow.access === "full") return false; // a rest rule set cannot cover a full grant
  for (const rule of narrow.rules) if (!wide.rules.has(rule)) return false;
  return true;
}

function checkPair(narrowName, narrowMap, wideName, wideMap) {
  const rows = [];
  for (const [key, narrow] of narrowMap) {
    const wide = wideMap.get(key);
    rows.push({ destination: key, narrowTier: narrowName, wideTier: wideName, ok: isCovered(narrow, wide) });
  }
  return rows;
}

function selfTest() {
  const full = { access: "full", rules: new Set() };
  const getHead = { access: "rest", rules: new Set(["GET /**", "HEAD /**"]) };
  const getOnly = { access: "rest", rules: new Set(["GET /**"]) };
  assert.equal(isCovered(getHead, full), true, "a rest rule set must be covered by a full grant");
  assert.equal(isCovered(full, getHead), false, "a full grant must not be covered by a narrower rest rule set");
  assert.equal(isCovered(getOnly, getHead), true, "a rule subset must be covered by its superset");
  assert.equal(isCovered(getHead, getOnly), false, "a rule superset must not be covered by a strict subset");
  assert.equal(isCovered(getHead, undefined), false, "a destination missing from the wider tier must not be covered");

  const endpoints = extractEndpoints(fs.readFileSync(path.join(presetsDir, "brew-balanced.yaml"), "utf8"));
  const raw = endpoints.find((e) => e.host === "raw.githubusercontent.com");
  assert.ok(raw, "brew-balanced.yaml must declare raw.githubusercontent.com");
  assert.equal(raw.access, "rest");
  assert.deepEqual(new Set(raw.rules), new Set(["GET /**", "HEAD /**"]));

  console.log("Tier-monotonicity parser self-test: PASS (6 checks)");
}

if (process.argv.includes("--self-test")) {
  selfTest();
  process.exit(0);
}

const tiers = loadTiers();
const byName = Object.fromEntries(tiers.map((t) => [t.name, t]));
const SCOPE = ["restricted", "balanced", "open"]; // docs/CLAIMS.md names only these three
const maps = Object.fromEntries(SCOPE.map((name) => [name, buildTierMap(byName[name].presets)]));
const excludedByTier = Object.fromEntries(
  SCOPE.map((name) => [name, byName[name].presets.filter((p) => DYNAMIC_PRESETS.has(p))]),
);

const pairs = [["restricted", "balanced"], ["balanced", "open"]];
const rows = pairs.flatMap(([a, b]) => checkPair(a, maps[a], b, maps[b]));
const violations = rows.filter((r) => !r.ok);
const overall = violations.length ? "FAIL" : "PASS";

const lines = [
  "# Network tier monotonicity",
  "",
  `- Overall: \`${overall}\``,
  `- Source: NemoClaw v0.0.140, commit 88fe14f3fb9a0bf72997cce19ec88b5b2ee08391 (see tests/tier-checks/nemoclaw-tiers/SOURCE.md)`,
  `- Pairs checked: ${pairs.map(([a, b]) => `${a}→${b}`).join(", ")}`,
  "",
  "## Destinations per tier",
  "",
  "| Tier | Static presets | Excluded (dynamic/OAuth) | Destinations |",
  "|---|---|---|---|",
  ...SCOPE.map((name) => `| ${name} | ${byName[name].presets.filter((p) => !DYNAMIC_PRESETS.has(p)).join(", ") || "(none)"} | ${excludedByTier[name].join(", ") || "(none)"} | ${maps[name].size} |`),
  "",
  "## Monotonicity rows",
  "",
  "| Destination | Narrower tier | Wider tier | Result |",
  "|---|---|---|---|",
  ...rows.map((r) => `| ${r.destination} | ${r.narrowTier} | ${r.wideTier} | ${r.ok ? "PASS" : "FAIL"} |`),
  "",
  violations.length
    ? `## Violations\n\n${violations.map((v) => `- **${v.destination}**: allowed under ${v.narrowTier} but not under ${v.wideTier}.`).join("\n")}\n`
    : "No violations: every destination allowed under a narrower tier remains allowed under each wider tier.\n",
].join("\n");

const outDir = path.join(root, "audit-reports", "tier-checks", "network-monotonicity");
fs.mkdirSync(outDir, { recursive: true });
archiveExistingReport(outDir, ["TIER-MONOTONICITY.md", "TIER-MONOTONICITY.json"]);
fs.writeFileSync(path.join(outDir, "TIER-MONOTONICITY.md"), lines, "utf8");
fs.writeFileSync(
  path.join(outDir, "TIER-MONOTONICITY.json"),
  JSON.stringify({ overall, rows, excluded_by_tier: excludedByTier }, null, 2) + "\n",
  "utf8",
);
console.log(lines);
console.log(`Report: ${path.relative(root, outDir).replaceAll("\\", "/")}/TIER-MONOTONICITY.md`);
process.exitCode = violations.length ? 1 : 0;
