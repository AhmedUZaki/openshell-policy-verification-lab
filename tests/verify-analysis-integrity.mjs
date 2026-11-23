import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createEvidenceAttestation } from "./evidence-attestation.mjs";

const sourceAnalyzer = path.join(path.dirname(fileURLToPath(import.meta.url)), "analyze-results.mjs");
const sourceAttestation = path.join(path.dirname(fileURLToPath(import.meta.url)), "evidence-attestation.mjs");
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "openshell-analysis-integrity-"));
const projectRoot = path.join(tempRoot, "project");
const testsDir = path.join(projectRoot, "tests");
const networkDir = path.join(testsDir, "network", "results");
const filesystemDir = path.join(testsDir, "filesystem", "results");
const outputDir = path.join(projectRoot, "audit-reports");
const attestationDir = path.join(projectRoot, "evidence-attestations");
const analyzer = path.join(testsDir, "analyze-results.mjs");
const attestationModule = path.join(testsDir, "evidence-attestation.mjs");

const networkIds = ["T01", "T02", "T03", "T04", "T05", "T06", "T17", "T18", "T19", "T20"];
const filesystemIds = [
  "T07", "T08", "T09", "T10", "T11", "T12", "T13", "T14", "T15", "T16",
  "T21", "T22", "T23", "T24", "T25", "T26", "T27", "T28", "T29", "T30",
  "T31", "T32", "T33", "T34", "T35", "T36",
];

function write(file, content = "synthetic evidence\n") {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content, "utf8");
}

function cleanEvidence() {
  for (const directory of [networkDir, filesystemDir, outputDir, attestationDir]) {
    fs.rmSync(directory, { recursive: true, force: true });
    fs.mkdirSync(directory, { recursive: true });
  }
}

function attest(runId, scope = "all") {
  return createEvidenceAttestation({ root: projectRoot, runId, scope });
}

function report(runId, ids, statuses = {}, duplicateId = null) {
  const rows = ids.map((id) => `| ${id} | \`${statuses[id] ?? "PASS"}\` | synthetic observation |`);
  if (duplicateId) rows.push(`| ${duplicateId} | \`${statuses[duplicateId] ?? "PASS"}\` | duplicate observation |`);
  return [
    "# Synthetic report",
    "",
    `- Run: \`${runId}\``,
    "- Evidence complete: `yes`",
    "",
    "| Test | Status | Evidence |",
    "|---|---|---|",
    ...rows,
    "",
  ].join("\n");
}

function makeRun(runId, options = {}) {
  const embeddedRunId = options.embeddedRunId ?? runId;
  write(path.join(networkDir, `network-${runId}.md`), report(embeddedRunId, networkIds, options.statuses, options.duplicateId));
  write(path.join(filesystemDir, `filesystem-${runId}.md`), report(embeddedRunId, filesystemIds, options.statuses, options.duplicateId));
  write(path.join(networkDir, `network-${runId}.raw.log`));
  write(path.join(filesystemDir, `filesystem-${runId}.raw.log`));
  for (const suffix of ["host-a.json", "host-b.json", "effective-policy-initial.yaml", "effective-policy-final.yaml", "openshell.log"]) {
    write(path.join(networkDir, `network-${runId}-${suffix}`));
  }
}

function run(args = []) {
  const result = spawnSync(process.execPath, [analyzer, ...args], {
    cwd: projectRoot,
    encoding: "utf8",
    windowsHide: true,
  });
  let payload = null;
  const latest = path.join(outputDir, "LATEST.json");
  if (fs.existsSync(latest)) payload = JSON.parse(fs.readFileSync(latest, "utf8"));
  return { ...result, payload };
}

function runAttestationCli(args = []) {
  return spawnSync(process.execPath, [attestationModule, ...args], {
    cwd: projectRoot,
    encoding: "utf8",
    windowsHide: true,
  });
}

function expectExit(result, code, label) {
  const problems = result.payload?.evidence_problems?.join(" | ") ?? "";
  assert.equal(result.status, code, `${label}: expected exit ${code}; stderr=${result.stderr}; evidence_problems=${problems}`);
}

const checks = [];
function check(name, fn) {
  fn();
  checks.push(name);
  console.log(`PASS ${name}`);
}

try {
  fs.mkdirSync(testsDir, { recursive: true });
  fs.copyFileSync(sourceAnalyzer, analyzer);
  fs.copyFileSync(sourceAttestation, attestationModule);
  expectExit(runAttestationCli(["init"]), 0, "signing-key initialization");

  check("complete evidence produces PASS", () => {
    cleanEvidence();
    makeRun("baseline");
    expectExit(runAttestationCli(["create", "--run-id", "baseline"]), 0, "attestation CLI");
    const result = run(["--run-id", "baseline"]);
    expectExit(result, 0, "baseline");
    assert.equal(result.payload.overall, "PASS");
    assert.equal(Object.keys(result.payload.results).length, 36);
  });

  check("measured FAIL is preserved", () => {
    cleanEvidence();
    makeRun("measured-fail", { statuses: { T18: "FAIL" } });
    attest("measured-fail");
    const result = run(["--run-id", "measured-fail"]);
    expectExit(result, 1, "measured failure");
    assert.equal(result.payload.overall, "MEASURED_FAILURE");
    assert.equal(result.payload.results.T18.status, "FAIL");
  });

  check("known limitation remains visible", () => {
    cleanEvidence();
    makeRun("limitation", { statuses: { T16: "KNOWN-LIMITATION" } });
    attest("limitation");
    const result = run(["--run-id", "limitation"]);
    expectExit(result, 0, "known limitation");
    assert.equal(result.payload.overall, "PASS_WITH_LIMITATIONS");
    assert.equal(result.payload.counts["KNOWN-LIMITATION"], 1);
  });

  check("missing raw evidence is rejected", () => {
    cleanEvidence();
    makeRun("missing-raw");
    attest("missing-raw");
    fs.rmSync(path.join(networkDir, "network-missing-raw.raw.log"));
    const result = run(["--run-id", "missing-raw"]);
    expectExit(result, 2, "missing raw evidence");
    assert.equal(result.payload.overall, "INCOMPLETE");
    assert.ok(result.payload.evidence_problems.some((item) => item.includes("network-missing-raw.raw.log")));
  });

  check("duplicate result row is rejected", () => {
    cleanEvidence();
    makeRun("duplicate", { duplicateId: "T01" });
    attest("duplicate");
    const result = run(["--run-id", "duplicate"]);
    expectExit(result, 2, "duplicate row");
    assert.ok(result.payload.evidence_problems.some((item) => item.includes("duplicate result row T01")));
  });

  check("embedded run-ID mismatch is rejected", () => {
    cleanEvidence();
    makeRun("filename-id", { embeddedRunId: "different-id" });
    attest("filename-id");
    const result = run(["--run-id", "filename-id"]);
    expectExit(result, 2, "run-ID mismatch");
    assert.ok(result.payload.evidence_problems.some((item) => item.includes("reports run ID different-id")));
  });

  check("unrelated network and filesystem runs are not combined", () => {
    cleanEvidence();
    makeRun("network-only");
    fs.rmSync(path.join(filesystemDir, "filesystem-network-only.md"));
    fs.rmSync(path.join(filesystemDir, "filesystem-network-only.raw.log"));
    makeRun("filesystem-only");
    for (const name of fs.readdirSync(networkDir)) {
      if (name.startsWith("network-filesystem-only")) fs.rmSync(path.join(networkDir, name));
    }
    const result = run();
    expectExit(result, 2, "unrelated runs");
    assert.equal(result.payload.run_id, null);
    assert.equal(result.payload.sources.network, null);
    assert.equal(result.payload.sources.filesystem, null);
  });

  check("newest common run is selected by modification time", () => {
    cleanEvidence();
    makeRun("z-older");
    makeRun("a-newer");
    attest("z-older");
    attest("a-newer");
    const oldTime = new Date(Date.now() - 60_000);
    const newTime = new Date();
    for (const [runId, time] of [["z-older", oldTime], ["a-newer", newTime]]) {
      fs.utimesSync(path.join(networkDir, `network-${runId}.md`), time, time);
      fs.utimesSync(path.join(filesystemDir, `filesystem-${runId}.md`), time, time);
    }
    const result = run();
    expectExit(result, 0, "mtime selection");
    assert.equal(result.payload.run_id, "a-newer");
  });

  check("post-signing evidence tampering is rejected", () => {
    cleanEvidence();
    makeRun("tampered");
    attest("tampered");
    fs.appendFileSync(path.join(filesystemDir, "filesystem-tampered.raw.log"), "tampered after signing\n", "utf8");
    const result = run(["--run-id", "tampered"]);
    expectExit(result, 2, "tampered evidence");
    assert.equal(result.payload.evidence_attestation.verified, false);
    assert.ok(result.payload.evidence_problems.some((item) => item.includes("Signed evidence")));
  });

  check("signature tampering is rejected", () => {
    cleanEvidence();
    makeRun("bad-signature");
    attest("bad-signature");
    fs.writeFileSync(path.join(attestationDir, "evidence-bad-signature.sig"), "AAAA\n", "utf8");
    const result = run(["--run-id", "bad-signature"]);
    expectExit(result, 2, "bad signature");
    assert.equal(result.payload.evidence_attestation.verified, false);
    assert.ok(result.payload.evidence_problems.some((item) => item.includes("signature verification failed")));
  });

  check("network-only attestation is scoped correctly", () => {
    cleanEvidence();
    makeRun("network-scope");
    attest("network-scope", "network");
    const result = run(["--network-only", "--run-id", "network-scope"]);
    expectExit(result, 0, "network-only attestation");
    assert.equal(result.payload.scope, "network");
    assert.equal(result.payload.evidence_attestation.verified, true);
    assert.equal(Object.keys(result.payload.results).length, 10);
  });

  check("missing exact run is incomplete", () => {
    cleanEvidence();
    const result = run(["--run-id", "absent"]);
    expectExit(result, 2, "missing exact run");
    assert.equal(result.payload.overall, "INCOMPLETE");
    assert.equal(result.payload.missing.length, 36);
  });

  check("unreadable report source exits as infrastructure failure", () => {
    cleanEvidence();
    fs.mkdirSync(path.join(networkDir, "network-broken.md"), { recursive: true });
    write(path.join(filesystemDir, "filesystem-broken.md"), report("broken", filesystemIds));
    const result = run(["--run-id", "broken"]);
    expectExit(result, 2, "unreadable report");
    assert.equal(result.payload, null);
  });

  console.log(`\nAnalysis integrity self-test: PASS (${checks.length} checks)`);
} finally {
  fs.rmSync(tempRoot, { recursive: true, force: true });
}
