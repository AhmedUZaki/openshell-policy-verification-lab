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
const sourceArchive = path.join(path.dirname(fileURLToPath(import.meta.url)), "archive-previous-results.mjs");
const archiveScript = path.join(testsDir, "archive-previous-results.mjs");
const sourceCompare = path.join(path.dirname(fileURLToPath(import.meta.url)), "compare-versions.mjs");
const compareScript = path.join(testsDir, "compare-versions.mjs");
const sourceNames = path.join(path.dirname(fileURLToPath(import.meta.url)), "test-names.mjs");
const namesModule = path.join(testsDir, "test-names.mjs");

const networkIds = ["N01", "N02", "N03", "N04", "N05", "N06", "N07", "N08", "N09", "N10"];
const filesystemIds = [
  "F1_1", "F1_2",
  "F2_1", "F2_2", "F2_3", "F2_4", "F2_5", "F2_6", "F2_7", "F2_8", "F2_9", "F2_10",
  "F2_11", "F2_12", "F2_13", "F2_14", "F2_15", "F2_16", "F2_17",
  "F3_1", "F3_2", "F3_3",
  "F4_1", "F4_2", "F4_3", "F4_4",
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

function report(runId, ids, statuses = {}, duplicateId = null, openshellVersion = null) {
  const rows = ids.map((id) => `| ${id} | \`${statuses[id] ?? "PASS"}\` | synthetic observation |`);
  if (duplicateId) rows.push(`| ${duplicateId} | \`${statuses[duplicateId] ?? "PASS"}\` | duplicate observation |`);
  return [
    "# Synthetic report",
    "",
    `- Run: \`${runId}\``,
    ...(openshellVersion ? [`- OpenShell: \`openshell ${openshellVersion}\``] : []),
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
  write(path.join(networkDir, `network-${runId}.md`), report(embeddedRunId, networkIds, options.statuses, options.duplicateId, options.networkVersion ?? options.openshellVersion));
  write(path.join(filesystemDir, `filesystem-${runId}.md`), report(embeddedRunId, filesystemIds, options.statuses, options.duplicateId, options.filesystemVersion ?? options.openshellVersion));
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
  const latest = path.join(outputDir, "latest", "LATEST.json");
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
  fs.copyFileSync(sourceArchive, archiveScript);
  fs.copyFileSync(sourceCompare, compareScript);
  fs.copyFileSync(sourceNames, namesModule);
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
    makeRun("measured-fail", { statuses: { N08: "FAIL" } });
    attest("measured-fail");
    const result = run(["--run-id", "measured-fail"]);
    expectExit(result, 1, "measured failure");
    assert.equal(result.payload.overall, "MEASURED_FAILURE");
    assert.equal(result.payload.results.N08.status, "FAIL");
  });

  check("known limitation remains visible", () => {
    cleanEvidence();
    makeRun("limitation", { statuses: { F2_5: "LANDLOCK-LIMITATION" } });
    attest("limitation");
    const result = run(["--run-id", "limitation"]);
    expectExit(result, 0, "known limitation");
    assert.equal(result.payload.overall, "PASS_WITH_LIMITATIONS");
    assert.equal(result.payload.counts["LANDLOCK-LIMITATION"], 1);
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
    makeRun("duplicate", { duplicateId: "N01" });
    attest("duplicate");
    const result = run(["--run-id", "duplicate"]);
    expectExit(result, 2, "duplicate row");
    assert.ok(result.payload.evidence_problems.some((item) => item.includes("duplicate result row N01")));
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

  check("previous results are archived by run ID without deleting anything", () => {
    cleanEvidence();
    makeRun("old-run");
    attest("old-run");
    expectExit(run(["--run-id", "old-run"]), 0, "analysis before archiving");
    write(path.join(networkDir, ".gitkeep"), "");
    const moved = spawnSync(process.execPath, [archiveScript], { cwd: projectRoot, encoding: "utf8", windowsHide: true });
    assert.equal(moved.status, 0, `archive failed: ${moved.stderr}`);
    const archived = path.join(projectRoot, "archived-results", "old-run");
    assert.ok(fs.existsSync(path.join(archived, "network", "network-old-run.md")));
    assert.ok(fs.existsSync(path.join(archived, "filesystem", "filesystem-old-run.raw.log")));
    assert.ok(fs.existsSync(path.join(archived, "evidence-attestations", "evidence-old-run.sig")));
    assert.ok(fs.existsSync(path.join(archived, "analysis", "analysis.json")));
    assert.ok(fs.existsSync(path.join(archived, "analysis", "latest", "LATEST.json")));
    assert.ok(fs.existsSync(path.join(archived, "analysis", "latest-by-version-unknown", "LATEST.json")));
    assert.deepEqual(fs.readdirSync(networkDir), [".gitkeep"]);
    assert.deepEqual(fs.readdirSync(filesystemDir), []);
    assert.deepEqual(fs.readdirSync(outputDir), []);
    assert.ok(fs.existsSync(path.join(projectRoot, ".local-keys", "evidence-private-key.pem")));
  });

  check("analysis records the OpenShell version and keeps a latest report per version", () => {
    cleanEvidence();
    makeRun("versioned", { openshellVersion: "0.1.9" });
    attest("versioned");
    const result = run(["--run-id", "versioned"]);
    expectExit(result, 0, "versioned run");
    assert.equal(result.payload.openshell_version, "0.1.9");
    assert.ok(fs.existsSync(path.join(outputDir, "latest-by-version", "0.1.9", "LATEST.json")));
    assert.ok(fs.readFileSync(path.join(outputDir, "latest", "LATEST.md"), "utf8").includes("OpenShell version: `0.1.9`"));
  });

  check("different OpenShell versions inside one run make it incomplete", () => {
    cleanEvidence();
    makeRun("mixed", { networkVersion: "0.0.116", filesystemVersion: "0.1.9" });
    attest("mixed");
    const result = run(["--run-id", "mixed"]);
    expectExit(result, 2, "mixed versions");
    assert.ok(result.payload.evidence_problems.some((item) => item.includes("measured OpenShell")));
  });

  check("a requested version is labeled when no evidence exists and contradicted when evidence disagrees", () => {
    cleanEvidence();
    const requested = (args, version) => spawnSync(process.execPath, [analyzer, ...args], {
      cwd: projectRoot,
      encoding: "utf8",
      windowsHide: true,
      env: { ...process.env, AUDIT_REQUESTED_OPENSHELL_VERSION: version },
    });
    expectExit(requested(["--run-id", "never-produced"], "0.1.9"), 2, "no evidence");
    const noEvidence = JSON.parse(fs.readFileSync(path.join(outputDir, "latest", "LATEST.json"), "utf8"));
    assert.equal(noEvidence.openshell_version, "0.1.9");
    assert.equal(noEvidence.openshell_version_source, "requested, no evidence");
    makeRun("wrong-version", { openshellVersion: "0.0.116" });
    attest("wrong-version");
    expectExit(requested(["--run-id", "wrong-version"], "0.1.9"), 2, "request contradicted by evidence");
    const contradicted = JSON.parse(fs.readFileSync(path.join(outputDir, "latest", "LATEST.json"), "utf8"));
    assert.ok(contradicted.evidence_problems.some((item) => item.includes("was requested but the evidence measured")));
  });

  check("version comparison shows changed tests and checks the predictions", () => {
    cleanEvidence();
    makeRun("v-old", { openshellVersion: "0.0.116", statuses: { F3_1: "FAIL", F3_3: "FAIL" } });
    attest("v-old");
    expectExit(run(["--run-id", "v-old"]), 1, "older version with measured failures");
    makeRun("v-new", { openshellVersion: "0.1.9" });
    attest("v-new");
    expectExit(run(["--run-id", "v-new"]), 0, "newer version");
    const compared = spawnSync(process.execPath, [compareScript], { cwd: projectRoot, encoding: "utf8", windowsHide: true });
    assert.equal(compared.status, 0, `comparison failed: ${compared.stderr}`);
    const comparison = JSON.parse(fs.readFileSync(path.join(outputDir, "latest", "COMPARISON.json"), "utf8"));
    assert.deepEqual(comparison.changed, ["F3_1", "F3_3"]);
    assert.ok(comparison.predictions.every((item) => item.verdict === "CONFIRMED"));
    assert.deepEqual(comparison.versions.map((item) => item.version), ["0.0.116", "0.1.9"]);
  });

  console.log(`\nAnalysis integrity self-test: PASS (${checks.length} checks)`);
} finally {
  fs.rmSync(tempRoot, { recursive: true, force: true });
}
