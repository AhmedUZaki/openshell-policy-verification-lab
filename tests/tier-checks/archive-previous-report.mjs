import fs from "node:fs";
import path from "node:path";

// Before a tier-check script overwrites its report in place, move whichever of its old
// output files still exist into audit-reports/tier-checks/run-history/<timestamp>/<check>/ (a
// shared top-level history, a sibling of the three check folders) so a previous run's result is
// never silently lost. Only the check that actually ran touches its own outDir, so unrun checks'
// folders are untouched.
export function archiveExistingReport(outDir, fileNames) {
  const existing = fileNames.filter((name) => fs.existsSync(path.join(outDir, name)));
  if (!existing.length) return;
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const historyDir = path.join(path.dirname(outDir), "run-history", stamp, path.basename(outDir));
  fs.mkdirSync(historyDir, { recursive: true });
  for (const name of existing) {
    fs.renameSync(path.join(outDir, name), path.join(historyDir, name));
  }
}
