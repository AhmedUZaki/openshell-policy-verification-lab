import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { verifyEvidenceAttestation } from "./evidence-attestation.mjs";

process.on("uncaughtException", (error) => {
  console.error(`Analysis infrastructure error: ${error.message}`);
  process.exit(2);
});
process.on("unhandledRejection", (error) => {
  console.error(`Analysis infrastructure error: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(2);
});

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(here);
const outputDir = path.join(root, "audit-reports");
fs.mkdirSync(outputDir, { recursive: true });

let scope = "all";
let requestedRunId = null;
const argv = process.argv.slice(2);
for (let index = 0; index < argv.length; index += 1) {
  const arg = argv[index];
  if (arg === "--network-only" && scope === "all") scope = "network";
  else if (arg === "--filesystem-only" && scope === "all") scope = "filesystem";
  else if (arg === "--run-id" && !requestedRunId) requestedRunId = argv[++index] ?? null;
  else {
    console.error("Usage: analyze-results.mjs [--network-only|--filesystem-only] [--run-id ID]");
    process.exit(2);
  }
}
if (!requestedRunId && argv.includes("--run-id")) {
  console.error("--run-id requires a value.");
  process.exit(2);
}
if (requestedRunId && !/^[A-Za-z0-9._-]+$/.test(requestedRunId)) {
  console.error("Invalid run ID. Use only letters, digits, dot, underscore, and hyphen.");
  process.exit(2);
}

function reportRuns(directory, prefix) {
  if (!fs.existsSync(directory)) return new Map();
  const runs = new Map();
  for (const name of fs.readdirSync(directory).sort()) {
    if (!name.startsWith(prefix) || !name.endsWith(".md")) continue;
    const runId = name.slice(prefix.length, -3);
    if (runId && !runId.endsWith("-ar")) {
      runs.set(runId, { name, mtimeMs: fs.statSync(path.join(directory, name)).mtimeMs });
    }
  }
  return runs;
}

function latestRunId(runs, allowedIds = [...runs.keys()]) {
  return allowedIds
    .map((id) => ({ id, mtimeMs: runs.get(id)?.mtimeMs ?? 0 }))
    .sort((a, b) => a.mtimeMs - b.mtimeMs || a.id.localeCompare(b.id))
    .at(-1)?.id ?? null;
}

function parseRows(file, wanted, expectedRunId, evidenceProblems) {
  const rows = {};
  if (!file) return rows;
  const text = fs.readFileSync(file, "utf8");
  const reportedRunId = text.match(/^- Run:\s*`([^`]+)`\s*$/m)?.[1] ?? null;
  if (reportedRunId !== expectedRunId) {
    evidenceProblems.push(`${path.relative(root, file)} reports run ID ${reportedRunId ?? "missing"}, expected ${expectedRunId}.`);
  }
  const evidenceComplete = text.match(/^- Evidence complete:\s*`(yes|no)`\s*$/m)?.[1] ?? null;
  if (evidenceComplete !== "yes") {
    evidenceProblems.push(`${path.relative(root, file)} does not certify complete evidence collection.`);
  }
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\|\s*(T\d{2})\s*\|\s*`?([A-Z-]+)`?\s*\|\s*(.*?)\s*\|$/);
    if (match && wanted.has(match[1])) {
      if (rows[match[1]]) {
        evidenceProblems.push(`${path.relative(root, file)} contains duplicate result row ${match[1]}.`);
      } else {
        rows[match[1]] = { status: match[2], evidence: match[3] };
      }
    }
  }
  return rows;
}

function requireEvidenceFile(directory, name, evidenceProblems, allowEmpty = false) {
  const file = path.join(directory, name);
  if (!fs.existsSync(file)) {
    evidenceProblems.push(`Missing evidence file: ${path.relative(root, file)}.`);
  } else if (!allowEmpty && fs.statSync(file).size === 0) {
    evidenceProblems.push(`Empty evidence file: ${path.relative(root, file)}.`);
  }
}

const networkDir = path.join(here, "network", "results");
const filesystemDir = path.join(here, "filesystem", "results");
const networkRuns = reportRuns(networkDir, "network-");
const filesystemRuns = reportRuns(filesystemDir, "filesystem-");
let selectedRunId = requestedRunId;
if (!selectedRunId) {
  if (scope === "network") selectedRunId = latestRunId(networkRuns);
  else if (scope === "filesystem") selectedRunId = latestRunId(filesystemRuns);
  else {
    const commonIds = [...networkRuns.keys()].filter((id) => filesystemRuns.has(id));
    selectedRunId = commonIds
      .map((id) => ({ id, mtimeMs: Math.max(networkRuns.get(id).mtimeMs, filesystemRuns.get(id).mtimeMs) }))
      .sort((a, b) => a.mtimeMs - b.mtimeMs || a.id.localeCompare(b.id))
      .at(-1)?.id ?? null;
  }
}
const networkName = selectedRunId ? networkRuns.get(selectedRunId)?.name ?? null : null;
const filesystemName = selectedRunId ? filesystemRuns.get(selectedRunId)?.name ?? null : null;
const networkFile = networkName ? path.join(networkDir, networkName) : null;
const filesystemFile = filesystemName ? path.join(filesystemDir, filesystemName) : null;

const networkIds = new Set(["T01", "T02", "T03", "T04", "T05", "T06", "T17", "T18", "T19", "T20"]);
const filesystemIds = new Set([
  "T07", "T08", "T09", "T10", "T11", "T12", "T13", "T14", "T15", "T16",
  "T21", "T22", "T23", "T24", "T25", "T26", "T27", "T28", "T29", "T30",
  "T31", "T32", "T33", "T34", "T35", "T36",
]);
const evidenceProblems = [];
const results = {
  ...parseRows(networkFile, networkIds, selectedRunId, evidenceProblems),
  ...parseRows(filesystemFile, filesystemIds, selectedRunId, evidenceProblems),
};
if (networkFile && scope !== "filesystem") {
  requireEvidenceFile(networkDir, `network-${selectedRunId}.raw.log`, evidenceProblems);
  for (const suffix of ["host-a.json", "host-b.json", "effective-policy-initial.yaml", "effective-policy-final.yaml"]) {
    requireEvidenceFile(networkDir, `network-${selectedRunId}-${suffix}`, evidenceProblems);
  }
  requireEvidenceFile(networkDir, `network-${selectedRunId}-openshell.log`, evidenceProblems, true);
}
if (filesystemFile && scope !== "network") {
  requireEvidenceFile(filesystemDir, `filesystem-${selectedRunId}.raw.log`, evidenceProblems);
}
const attestation = selectedRunId
  ? verifyEvidenceAttestation({ root, runId: selectedRunId, scope })
  : { verified: false, fingerprint: null, files: 0, problems: ["No run ID was available for evidence attestation verification."] };
evidenceProblems.push(...attestation.problems);

const expected = scope === "network"
  ? [...networkIds]
  : scope === "filesystem"
    ? [...filesystemIds]
    : Array.from({ length: 36 }, (_, index) => `T${String(index + 1).padStart(2, "0")}`);
for (const id of Object.keys(results)) {
  if (!expected.includes(id)) delete results[id];
}
const missing = expected.filter((id) => !results[id]);
const counts = { PASS: 0, FAIL: 0, EXPECTED: 0, "KNOWN-LIMITATION": 0, INCONCLUSIVE: 0, OTHER: 0 };
for (const item of Object.values(results)) {
  if (Object.hasOwn(counts, item.status)) counts[item.status] += 1;
  else counts.OTHER += 1;
}

let overall = "PASS";
let exitCode = 0;
if (missing.length || evidenceProblems.length || counts.INCONCLUSIVE || counts.OTHER) {
  overall = "INCOMPLETE";
  exitCode = 2;
} else if (counts.FAIL) {
  overall = "MEASURED_FAILURE";
  exitCode = 1;
} else if (counts["KNOWN-LIMITATION"]) {
  overall = "PASS_WITH_LIMITATIONS";
}

const interpretations = [];
if ([...networkIds].every((id) => ["PASS", "EXPECTED"].includes(results[id]?.status))) {
  interpretations.push("All core and extended network tests matched the configured enforcement expectations.");
}
if ([...filesystemIds].every((id) => ["PASS", "EXPECTED", "KNOWN-LIMITATION"].includes(results[id]?.status))) {
  interpretations.push("All filesystem enforcement expectations passed; KNOWN-LIMITATION rows separately record documented Landlock scope limits.");
} else if (results.T09?.status === "FAIL") {
  interpretations.push("T09 measured a content-integrity failure: pathname truncation changed a fixture that the applied policy marked read-only. The test result alone does not identify the underlying mechanism.");
}
const extendedFailures = expected.filter((id) => Number(id.slice(1)) > 10 && results[id]?.status === "FAIL");
const unreviewedExtendedFailures = extendedFailures.filter((id) => !(id === "T32" && results.T09?.status === "FAIL"));
const knownLimitations = expected.filter((id) => results[id]?.status === "KNOWN-LIMITATION");
if (results.T16?.status === "KNOWN-LIMITATION") interpretations.push("T16 records a known Landlock limitation: chmod metadata changes are outside Landlock mediation.");
if (results.T18?.status === "EXPECTED") interpretations.push("T18 matched the suite's predefined GET-to-HEAD method expectation.");
if (results.T35?.status === "EXPECTED") interpretations.push("T35 observed that execution from the read-only path remained allowed; content-mutation restrictions are measured by separate tests.");
if (unreviewedExtendedFailures.length) interpretations.push(`Extended robustness failures requiring semantic review: ${unreviewedExtendedFailures.join(", ")}.`);
if (results.T09?.status === "FAIL" && results.T32?.status === "FAIL") interpretations.push("T09 and T32 are correlated observations of truncation behavior and should be grouped as one provisional finding. Attributing a specific root cause requires separate runtime evidence.");
if (knownLimitations.length) interpretations.push(`Documented Landlock scope limitations observed: ${knownLimitations.join(", ")}. These do not count as independent enforcement failures.`);
if (missing.length) interpretations.push(`Missing test results: ${missing.join(", ")}.`);
if (evidenceProblems.length) interpretations.push(`Evidence integrity problems: ${evidenceProblems.join(" ")}`);
if (counts.INCONCLUSIVE) interpretations.push(`${counts.INCONCLUSIVE} test(s) were inconclusive and require rerun or environment repair.`);

const generatedAt = new Date();
const stamp = generatedAt.toISOString().replace(/[-:.]/g, "");
const payload = {
  schema_version: 3,
  scope,
  run_id: selectedRunId,
  generated_at: generatedAt.toISOString(),
  platform: { os: os.platform(), release: os.release(), arch: os.arch() },
  sources: {
    network: scope !== "filesystem" && networkFile ? path.relative(root, networkFile).replaceAll("\\", "/") : null,
    filesystem: scope !== "network" && filesystemFile ? path.relative(root, filesystemFile).replaceAll("\\", "/") : null,
  },
  overall,
  exit_code: exitCode,
  counts,
  missing,
  evidence_problems: evidenceProblems,
  evidence_attestation: {
    verified: attestation.verified,
    public_key_fingerprint_sha256: attestation.fingerprint,
    signed_file_count: attestation.files,
  },
  results,
  interpretations,
};

const json = JSON.stringify(payload, null, 2) + "\n";
const markdown = [
  "# Automated enforcement analysis",
  "",
  `- Generated: \`${payload.generated_at}\``,
  `- Overall: \`${overall}\``,
  `- Scope: \`${scope}\``,
  `- Run ID: \`${selectedRunId ?? "missing"}\``,
  `- Platform: \`${payload.platform.os} ${payload.platform.arch} ${payload.platform.release}\``,
  `- Network source: \`${payload.sources.network ?? "missing"}\``,
  `- Filesystem source: \`${payload.sources.filesystem ?? "missing"}\``,
  `- Evidence signature: \`${attestation.verified ? "VERIFIED" : "NOT VERIFIED"}\``,
  `- Signing-key fingerprint: \`${attestation.fingerprint ?? "missing"}\``,
  "",
  "## Result matrix",
  "",
  "| Test | Status | Evidence |",
  "|---|---|---|",
  ...expected.map((id) => `| ${id} | \`${results[id]?.status ?? "MISSING"}\` | ${results[id]?.evidence ?? "No result file was found."} |`),
  "",
  "## Automatic interpretation",
  "",
  ...interpretations.map((line) => `- ${line}`),
  "",
  "## Machine-readable outcome",
  "",
  `Exit code: \`${exitCode}\` (0 = no measured enforcement failures; PASS_WITH_LIMITATIONS remains explicit, 1 = measured FAIL, 2 = incomplete/inconclusive).`,
  "",
].join("\n");

const arabicOverall = {
  PASS: "كل التوقعات نجحت",
  PASS_WITH_LIMITATIONS: "نجحت توقعات الإنفاذ، مع وجود قيود موثقة ظاهرة بوضوح",
  MEASURED_FAILURE: "يوجد فشل مقاس في أحد توقعات الاختبار",
  INCOMPLETE: "النتائج ناقصة أو غير حاسمة",
}[overall];
const markdownAr = [
  "# التحليل الآلي لنتائج الإنفاذ",
  "",
  `- وقت الإنشاء: \`${payload.generated_at}\``,
  `- النتيجة العامة: \`${overall}\` — ${arabicOverall}`,
  `- النطاق: \`${scope}\``,
  `- معرّف التشغيل: \`${selectedRunId ?? "غير موجود"}\``,
  `- المنصة: \`${payload.platform.os} ${payload.platform.arch} ${payload.platform.release}\``,
  `- مصدر الشبكة: \`${payload.sources.network ?? "غير موجود"}\``,
  `- مصدر الملفات: \`${payload.sources.filesystem ?? "غير موجود"}\``,
  `- توقيع الأدلة: \`${attestation.verified ? "VERIFIED" : "NOT VERIFIED"}\``,
  `- بصمة مفتاح التوقيع: \`${attestation.fingerprint ?? "غير موجودة"}\``,
  "",
  "## مصفوفة النتائج",
  "",
  "| الاختبار | النتيجة | الدليل |",
  "|---|---|---|",
  ...expected.map((id) => `| ${id} | \`${results[id]?.status ?? "MISSING"}\` | ${results[id]?.evidence ?? "لم يُعثر على نتيجة."} |`),
  "",
  "## الاستنتاج الآلي",
  "",
  ...(scope !== "filesystem" ? [[ ...networkIds ].every((id) => ["PASS", "EXPECTED"].includes(results[id]?.status))
    ? "- وافقت جميع اختبارات الشبكة الأساسية والموسعة توقعات الإنفاذ المحددة."
    : "- توجد نتيجة شبكة غير ناجحة أو ناقصة وتحتاج مراجعة."] : []),
  ...(scope !== "network" ? [results.T09?.status === "FAIL"
    ? "- قاس T09 فشلًا في سلامة المحتوى: غيّرت truncate ملفًا صنفته السياسة المطبقة كـ read_only. لا تكفي نتيجة الاختبار وحدها لتحديد الآلية المسببة."
    : "- لم يسجل T09 فشلًا في أحدث جولة."] : []),
  ...(unreviewedExtendedFailures.length ? [`- إخفاقات robustness التي ما زالت تحتاج مراجعة دلالية: ${unreviewedExtendedFailures.join(", ")}.`] : []),
  ...(knownLimitations.length ? [`- قيود Landlock الموثقة التي ظهرت: ${knownLimitations.join(", ")}. لا تُحسب هذه كإخفاقات إنفاذ مستقلة.`] : []),
  ...(results.T18?.status === "EXPECTED" ? ["- طابق T18 التوقع المحدد مسبقًا في المختبر لمعاملة HEAD مع قاعدة GET."] : []),
  ...(results.T35?.status === "EXPECTED" ? ["- لاحظ T35 أن التنفيذ من مسار read_only ظل مسموحًا؛ وتقيس اختبارات منفصلة قيود تعديل المحتوى."] : []),
  ...(results.T09?.status === "FAIL" && results.T32?.status === "FAIL" ? ["- T09 وT32 ملاحظتان مترابطتان لسلوك truncate وتُجمعان كنتيجة أولية واحدة. يحتاج تحديد سبب جذري بعينه إلى دليل تشغيل منفصل."] : []),
  ...(missing.length ? [`- النتائج المفقودة: ${missing.join(", ")}.`] : []),
  ...(evidenceProblems.length ? [`- مشكلات سلامة الأدلة: ${evidenceProblems.join(" ")}`] : []),
  "",
  `رمز الخروج: \`${exitCode}\` (0 لا توجد إخفاقات إنفاذ مقاسة، وتظل PASS_WITH_LIMITATIONS ظاهرة بوضوح؛ 1 فشل مقاس؛ 2 نتيجة ناقصة أو غير حاسمة).`,
  "",
].join("\n");

for (const [name, content] of [
  [`analysis-${stamp}.json`, json],
  [`analysis-${stamp}.md`, markdown],
  [`analysis-${stamp}-ar.md`, markdownAr],
  ["LATEST.json", json],
  ["LATEST.md", markdown],
  ["LATEST_AR.md", markdownAr],
]) fs.writeFileSync(path.join(outputDir, name), content, "utf8");

console.log(markdown);
console.log(`Analysis files: ${path.relative(root, outputDir)}/LATEST.md, LATEST_AR.md, and LATEST.json`);
process.exitCode = exitCode;
