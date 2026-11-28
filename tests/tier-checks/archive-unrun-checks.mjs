// Called by run-tier-network-and-filesystem-checks.sh before it runs a subset of the three tier
// checks: archives the CURRENT report of any check NOT in that subset into run-history/, so only
// the check(s) actually run this session keep a folder at the top level of
// audit-reports/tier-checks/. A check's own generator script (archive-previous-report.mjs) already
// archives its own prior result when it runs again, so this only needs to cover the ones skipped.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { archiveExistingReport } from "./archive-previous-report.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(path.dirname(here));
const tierChecksDir = path.join(root, "audit-reports", "tier-checks");

const CHECKS = {
  "network-monotonicity": ["TIER-MONOTONICITY.md", "TIER-MONOTONICITY.json"],
  "filesystem-invariance": ["TIER-FS-INVARIANCE.md", "TIER-FS-INVARIANCE.json"],
  "live-network-reachability": ["LIVE-NETWORK-REACHABILITY.md", "LIVE-NETWORK-REACHABILITY.json"],
};

const runningChecks = new Set(process.argv.slice(2));
for (const [name, fileNames] of Object.entries(CHECKS)) {
  if (runningChecks.has(name)) continue;
  const outDir = path.join(tierChecksDir, name);
  archiveExistingReport(outDir, fileNames);
  // Leave no empty folder behind for a check this session isn't running.
  try { fs.rmdirSync(outDir); } catch { /* not present, or not empty: leave it */ }
}
