// Evaluates the raw results from run-live-network-reachability.sh: for each (tier, destination)
// pair, derives ALLOWED/DENIED from the real curl outcome, compares it against the expectation
// that follows directly from the vendored NemoClaw preset definitions (not invented), and flags
// any mismatch -- a destination reachable when it should be blocked (a bypass) or blocked when
// it should be reachable (over-restriction) -- as a violation. Answers: is there a real,
// enforced difference between the tiers, and is anything happening that should not.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { archiveExistingReport } from "./archive-previous-report.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(path.dirname(here));
const resultsDir = path.join(here, "results");

const [, , runId] = process.argv;
let file;
if (runId) {
  file = path.join(resultsDir, `live-network-tier-${runId}.json`);
} else {
  const candidates = fs.existsSync(resultsDir)
    ? fs.readdirSync(resultsDir).filter((n) => n.startsWith("live-network-tier-") && n.endsWith(".json"))
    : [];
  if (!candidates.length) {
    console.error(`No results found in ${path.relative(root, resultsDir)}. Run run-live-network-reachability.sh first.`);
    process.exit(2);
  }
  candidates.sort((a, b) => fs.statSync(path.join(resultsDir, b)).mtimeMs - fs.statSync(path.join(resultsDir, a)).mtimeMs);
  file = path.join(resultsDir, candidates[0]);
}
if (!fs.existsSync(file)) {
  console.error(`Missing results file: ${path.relative(root, file)}`);
  process.exit(2);
}
const rows = JSON.parse(fs.readFileSync(file, "utf8"));

// Expectation follows directly from tests/tier-checks/nemoclaw-tiers/: pypi.org is in the pypi
// preset (Balanced and Open); wttr.in is in the weather preset (Open only). Both declare
// "allow: { method: GET, path: \"/**\" }", so a plain GET is the operation each preset grants.
const EXPECTED = {
  pypi: { restricted: "DENIED", balanced: "ALLOWED", open: "ALLOWED" },
  wttr: { restricted: "DENIED", balanced: "DENIED", open: "ALLOWED" },
};
// A substring only the real host returns; proves the sandbox actually reached it and this
// is not an artifact of a stub or local origin (pypi.org's /simple/ index page title).
const AUTHENTICITY = { pypi: "Simple index" };

function classify(row) {
  const rc = Number(row.curl_rc);
  const http = row.http_status ? Number(row.http_status) : null;
  if (rc === 0 && http && http >= 200 && http < 300) return "ALLOWED";
  if (rc === 0) return `REACHED_HTTP_${row.http_status}`; // reached the real host, non-2xx: not a mediation denial
  return "DENIED"; // nonzero curl exit: boundary refusal (connection refused/could not resolve/timeout)
}

const evaluated = rows.map((row) => {
  const measured = classify(row);
  const expected = EXPECTED[row.destination]?.[row.tier] ?? null;
  const marker = AUTHENTICITY[row.destination];
  const authentic = measured === "ALLOWED" && marker ? row.body_sample.includes(marker) : null;
  return { ...row, measured, expected, match: expected === null ? null : measured === expected, authentic };
});

const violations = evaluated.filter((r) => r.match === false);
const authenticityFailures = evaluated.filter((r) => r.authentic === false);
const overall = violations.length || authenticityFailures.length ? "FAIL" : "PASS";

// Same definitions as tests/enforcement-audit/analyze-results.mjs ("M4 evaluation" in
// docs/CLAIMS.md). "Prohibited" rows are the ones this tier's real preset should deny; a valid
// attempt is one that verifiably reached enforcement (a real ALLOWED/DENIED read, not an
// unauthenticated reach); a confirmed bypass is a prohibited row that measured ALLOWED.
const coverage = evaluated.length ? evaluated.filter((r) => r.expected !== null).length / evaluated.length : null;
const prohibited = evaluated.filter((r) => r.expected === "DENIED");
const validProhibited = prohibited.filter((r) => (r.measured === "ALLOWED" || r.measured === "DENIED") && r.authentic !== false);
const bypasses = validProhibited.filter((r) => r.measured === "ALLOWED");
const bypassRate = validProhibited.length ? bypasses.length / validProhibited.length : null;
const pct = (rate) => (rate === null ? "N/A" : `${(rate * 100).toFixed(1)}%`);

const lines = [
  "# Live network tier-reachability proof",
  "",
  `- Overall: \`${overall}\``,
  `- Source file: \`${path.relative(root, file).replaceAll("\\", "/")}\``,
  "- Each row is a real, read-only GET from inside an OpenShell sandbox running that tier's committed policy (policies/tier-checks/).",
  "",
  "## Metrics",
  "",
  "- `Coverage = Operations with a Valid Attempt / Total Targeted Operations`",
  "- `Bypass Rate(tier) = Confirmed Bypasses in Tier / Valid Attempts Reaching Enforcement in Tier`",
  "",
  "- Definitions are in `docs/CLAIMS.md` (\"M4 evaluation\").",
  `- **Valid-Test Coverage:** ${evaluated.filter((r) => r.expected !== null).length} / ${evaluated.length} (${pct(coverage)})`,
  `- **Bypass Rate:** ${bypasses.length} / ${validProhibited.length} (${pct(bypassRate)})`,
  "",
  "## Results",
  "",
  "| Tier | Destination | Measured | Expected | Match? | curl rc | HTTP | Authentic body? |",
  "|---|---|---|---|---|---|---|---|",
  ...evaluated.map((r) => `| ${r.tier} | ${r.destination} | ${r.measured} | ${r.expected ?? "n/a"} | ${r.match === null ? "n/a" : r.match ? "yes" : "**NO**"} | ${r.curl_rc} | ${r.http_status || "-"} | ${r.authentic === null ? "n/a" : r.authentic ? "yes" : "**NO**"} |`),
  "",
  violations.length
    ? `## Violations\n\n${violations.map((v) => `- **${v.tier} -> ${v.destination}**: measured ${v.measured}, expected ${v.expected}. ${v.measured === "ALLOWED" ? "A destination reached that this tier should have blocked (bypass)." : "A destination blocked that this tier should have allowed (over-restriction)."}`).join("\n")}\n`
    : "No violations: every tier's reachability matched what its real NemoClaw presets declare.\n",
  authenticityFailures.length
    ? `## Authenticity failures\n\n${authenticityFailures.map((v) => `- **${v.tier} -> ${v.destination}**: reached with HTTP ${v.http_status} but the response body did not contain the expected marker; this result cannot be trusted as a genuine reach of the real host.`).join("\n")}\n`
    : "",
].join("\n");

const outDir = path.join(root, "audit-reports", "tier-checks", "live-network-reachability");
fs.mkdirSync(outDir, { recursive: true });
archiveExistingReport(outDir, ["LIVE-NETWORK-REACHABILITY.md", "LIVE-NETWORK-REACHABILITY.json"]);
fs.writeFileSync(path.join(outDir, "LIVE-NETWORK-REACHABILITY.md"), lines, "utf8");
fs.writeFileSync(
  path.join(outDir, "LIVE-NETWORK-REACHABILITY.json"),
  JSON.stringify({ overall, source: path.relative(root, file), rows: evaluated, metrics: { valid_test_coverage: { valid_attempts: evaluated.filter((r) => r.expected !== null).length, expected: evaluated.length, rate: coverage }, bypass_rate: { bypasses: bypasses.length, valid_prohibited_attempts: validProhibited.length, rate: bypassRate } } }, null, 2) + "\n",
  "utf8",
);
console.log(lines);
console.log(`Report: ${path.relative(root, outDir).replaceAll("\\", "/")}/LIVE-NETWORK-REACHABILITY.md`);
process.exitCode = overall === "FAIL" ? 1 : 0;
