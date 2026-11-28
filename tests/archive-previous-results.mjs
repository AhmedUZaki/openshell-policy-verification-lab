// Moves results of earlier runs out of the active result directories so a new run starts clean.
// Nothing is deleted: files are moved to archived-results/<run-id>/ (ignored by Git).
// Usage: node tests/archive-previous-results.mjs [--dry-run]
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const archiveRoot = path.join(root, "archived-results");
const dryRun = process.argv.includes("--dry-run");
const stamp = new Date().toISOString().replace(/[-:.]/g, "");
const SAFE_ID = /^[A-Za-z0-9._-]+$/;
const RUN_FILE = /^(?:network|filesystem|evidence)-([A-Za-z0-9._-]+?)(?:\.raw\.log|\.md|\.manifest\.json|\.sig|\.public\.pem|-host-[ab]\.json|-effective-policy-(?:initial|final)\.yaml|-openshell\.log)$/;

// [directory relative to the project root, sub-folder name inside the run's archive]
const sources = [
  ["tests/network/results", "network"],
  ["tests/filesystem/results", "filesystem"],
  ["evidence-attestations", "evidence-attestations"],
  ["audit-reports/enforcement-audit", "analysis"],
];

function runIdFromReport(file) {
  try {
    const head = fs.readFileSync(file, "utf8").slice(0, 4000);
    return head.match(/"run_id":\s*"([^"]+)"/)?.[1]
      ?? head.match(/Run ID:\s*`([^`]+)`/)?.[1]
      ?? head.match(/معرّف التشغيل:\s*`([^`]+)`/)?.[1]
      ?? null;
  } catch {
    return null;
  }
}

const moves = [];
for (const [dir, target] of sources) {
  const base = path.join(root, dir);
  if (!fs.existsSync(base)) continue;
  for (const entry of fs.readdirSync(base, { withFileTypes: true })) {
    if (entry.name === ".gitkeep") continue;
    const full = path.join(base, entry.name);
    if (dir === "audit-reports/enforcement-audit" && entry.isDirectory() && entry.name === "run-history") {
      for (const run of fs.readdirSync(full, { withFileTypes: true })) {
        const runPath = path.join(full, run.name);
        if (!run.isDirectory()) {
          moves.push({ from: runPath, id: null, target, name: run.name });
          continue;
        }
        for (const file of fs.readdirSync(runPath)) {
          moves.push({ from: path.join(runPath, file), id: run.name, target, name: file });
        }
      }
      continue;
    }
    if (dir === "audit-reports/enforcement-audit" && entry.isDirectory() && entry.name === "latest") {
      for (const file of fs.readdirSync(full)) {
        const filePath = path.join(full, file);
        moves.push({ from: filePath, id: runIdFromReport(filePath), target: `${target}/latest`, name: file });
      }
      continue;
    }
    if (dir === "audit-reports/enforcement-audit" && entry.isDirectory() && entry.name === "latest-by-version") {
      for (const version of fs.readdirSync(full, { withFileTypes: true })) {
        if (!version.isDirectory()) {
          moves.push({ from: path.join(full, version.name), id: null, target, name: version.name });
          continue;
        }
        for (const file of fs.readdirSync(path.join(full, version.name))) {
          const filePath = path.join(full, version.name, file);
          moves.push({ from: filePath, id: runIdFromReport(filePath), target: `${target}/latest-by-version-${version.name}`, name: file });
        }
      }
      continue;
    }
    let id = entry.isFile() ? entry.name.match(RUN_FILE)?.[1] ?? null : null;
    if (!id && dir === "audit-reports/enforcement-audit" && entry.isFile()) id = runIdFromReport(full);
    moves.push({ from: full, id, target, name: entry.name });
  }
}

function move(from, to) {
  fs.mkdirSync(path.dirname(to), { recursive: true });
  try {
    fs.renameSync(from, to);
  } catch (error) {
    if (error.code !== "EXDEV") throw error;
    fs.cpSync(from, to, { recursive: true });
    fs.rmSync(from, { recursive: true, force: true });
  }
}

const perRun = new Map();
let failed = 0;
for (const item of moves) {
  const folder = item.id && SAFE_ID.test(item.id) && item.id !== "." && item.id !== ".." ? item.id : `unsorted-${stamp}`;
  let destination = path.join(archiveRoot, folder, item.target, item.name);
  if (fs.existsSync(destination)) destination = `${destination}.dup-${stamp}`;
  perRun.set(folder, (perRun.get(folder) ?? 0) + 1);
  if (dryRun) continue;
  try {
    move(item.from, destination);
  } catch (error) {
    failed += 1;
    console.error(`Could not archive ${path.relative(root, item.from)}: ${error.message}`);
  }
}

if (!dryRun) {
  // Drop now-empty run-history/<id> folders; rmdir refuses to remove anything that still holds files.
  for (const group of ["run-history", "latest-by-version", "latest"]) {
    const groupDir = path.join(root, "audit-reports", "enforcement-audit", group);
    if (!fs.existsSync(groupDir)) continue;
    for (const name of fs.readdirSync(groupDir)) {
      try { fs.rmdirSync(path.join(groupDir, name)); } catch { /* not empty: leave it */ }
    }
    try { fs.rmdirSync(groupDir); } catch { /* not empty: leave it */ }
  }
}

if (!moves.length) {
  console.log("No previous results to archive.");
} else {
  const verb = dryRun ? "Would archive" : "Archived";
  for (const [folder, count] of perRun) {
    console.log(`${verb} ${count} file(s) of run ${folder} to ${path.relative(root, path.join(archiveRoot, folder)).replaceAll("\\", "/")}/`);
  }
}
process.exitCode = failed ? 1 : 0;
