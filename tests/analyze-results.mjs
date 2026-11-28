import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { verifyEvidenceAttestation } from "./evidence-attestation.mjs";
import { testNames } from "./test-names.mjs";

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
    const match = line.match(/^\|\s*(N\d{2}|F[1-4]_\d{1,2})\s*\|\s*`?([A-Z-]+)`?\s*\|\s*(.*?)\s*\|$/);
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

const networkIds = new Set(["N01", "N02", "N03", "N04", "N05", "N06", "N07", "N08", "N09", "N10", "N11", "N12"]);
const filesystemIds = new Set([
  "F1_1", "F1_2",
  "F2_1", "F2_2", "F2_3", "F2_4", "F2_5", "F2_6", "F2_7", "F2_8", "F2_9", "F2_10",
  "F2_11", "F2_12", "F2_13", "F2_14", "F2_15", "F2_16", "F2_17",
  "F3_1", "F3_2", "F3_3",
  "F4_1", "F4_2", "F4_3", "F4_4",
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

// The OpenShell version is read from the evidence itself (its "- OpenShell:" header line), never from the caller.
function reportOpenShellVersion(file) {
  if (!file) return null;
  try {
    return fs.readFileSync(file, "utf8").match(/^- OpenShell:\s*`(?:openshell\s+)?v?([0-9][^`\s]*)`/m)?.[1] ?? null;
  } catch {
    return null;
  }
}
const networkVersion = scope !== "filesystem" ? reportOpenShellVersion(networkFile) : null;
const filesystemVersion = scope !== "network" ? reportOpenShellVersion(filesystemFile) : null;
if (networkVersion && filesystemVersion && networkVersion !== filesystemVersion) {
  evidenceProblems.push(`The network report measured OpenShell ${networkVersion} but the filesystem report measured ${filesystemVersion}.`);
}
// The runner may say which version it asked for. That label is only used when no evidence exists,
// and a request that the evidence contradicts is reported as an evidence problem.
const requestedVersion = (process.env.AUDIT_REQUESTED_OPENSHELL_VERSION ?? "").replace(/^v/, "") || null;
const measuredVersion = networkVersion ?? filesystemVersion ?? null;
if (measuredVersion && requestedVersion && measuredVersion !== requestedVersion) {
  evidenceProblems.push(`OpenShell ${requestedVersion} was requested but the evidence measured ${measuredVersion}.`);
}
const openshellVersion = measuredVersion ?? requestedVersion;
const openshellVersionSource = measuredVersion ? "evidence" : requestedVersion ? "requested, no evidence" : "unknown";
const versionFolder = openshellVersion && /^[0-9A-Za-z._-]+$/.test(openshellVersion) ? openshellVersion : "unknown";

const expected = scope === "network"
  ? [...networkIds]
  : scope === "filesystem"
    ? [...filesystemIds]
    : [...networkIds, ...filesystemIds];
for (const id of Object.keys(results)) {
  if (!expected.includes(id)) delete results[id];
}
const missing = expected.filter((id) => !results[id]);
const counts = { PASS: 0, FAIL: 0, EXPECTED: 0, "LANDLOCK-LIMITATION": 0, INCONCLUSIVE: 0, OTHER: 0 };
for (const item of Object.values(results)) {
  if (Object.hasOwn(counts, item.status)) counts[item.status] += 1;
  else counts.OTHER += 1;
}

// docs/CLAIMS.md, "M4 evaluation": Valid-Test Coverage = cases with a valid attempt / expected
// cases in the selected scope. A valid attempt is one that produced a conclusive status; MISSING
// and INCONCLUSIVE rows did not.
const CONCLUSIVE_STATUSES = ["PASS", "FAIL", "EXPECTED", "LANDLOCK-LIMITATION"];
const validAttempts = expected.filter((id) => CONCLUSIVE_STATUSES.includes(results[id]?.status));
const validTestCoverage = expected.length ? validAttempts.length / expected.length : null;

// Bypass Rate = confirmed prohibited successes / valid prohibited attempts with verified
// prerequisites (per scenario; N/A if denominator = 0). "Prohibited" excludes the tests whose
// predefined expectation is that the operation is allowed (positive controls and the HEAD/GET and
// execute-from-read_only semantics), per docs/CLAIMS.md's "Positive precision controls" row and
// the N08/F2_17 EXPECTED entries. LANDLOCK-LIMITATION counts as a valid prohibited attempt (the
// prerequisites held) but not as a confirmed bypass, matching the METHODOLOGY.md verdict semantics.
const ALLOWED_BY_DESIGN_IDS = new Set(["N08", "N10", "F2_11", "F2_17"]);
const BYPASS_SCENARIOS = [
  ["Network", "الشبكة", (id) => id.startsWith("N")],
  ["F1 Read", "F1 القراءة", (id) => id.startsWith("F1")],
  ["F2 Modify", "F2 التعديل", (id) => id.startsWith("F2")],
  ["F3 Truncate", "F3 البتر", (id) => id.startsWith("F3")],
  ["F4 Delete", "F4 الحذف", (id) => id.startsWith("F4")],
];
function bypassStats(ids) {
  const prohibited = ids.filter((id) => !ALLOWED_BY_DESIGN_IDS.has(id));
  const validProhibited = prohibited.filter((id) => ["PASS", "FAIL", "LANDLOCK-LIMITATION"].includes(results[id]?.status));
  const bypasses = prohibited.filter((id) => results[id]?.status === "FAIL");
  return { bypasses: bypasses.length, validProhibited: validProhibited.length, rate: validProhibited.length ? bypasses.length / validProhibited.length : null };
}
const bypassByScenario = BYPASS_SCENARIOS
  .map(([nameEn, nameAr, matches]) => [nameEn, nameAr, expected.filter(matches)])
  .filter(([, , ids]) => ids.length > 0)
  .map(([nameEn, nameAr, ids]) => [nameEn, nameAr, bypassStats(ids)]);
const bypassOverall = bypassStats(expected);

let overall = "PASS";
let exitCode = 0;
if (missing.length || evidenceProblems.length || counts.INCONCLUSIVE || counts.OTHER) {
  overall = "INCOMPLETE";
  exitCode = 2;
} else if (counts.FAIL) {
  overall = "MEASURED_FAILURE";
  exitCode = 1;
} else if (counts["LANDLOCK-LIMITATION"]) {
  overall = "PASS_WITH_LIMITATIONS";
}

const interpretations = [];
if ([...networkIds].every((id) => ["PASS", "EXPECTED"].includes(results[id]?.status))) {
  interpretations.push("All core and extended network tests matched the configured enforcement expectations.");
}
if ([...filesystemIds].every((id) => ["PASS", "EXPECTED", "LANDLOCK-LIMITATION"].includes(results[id]?.status))) {
  interpretations.push("All filesystem enforcement expectations passed; LANDLOCK-LIMITATION rows separately record documented Landlock scope limits.");
} else if (results.F3_1?.status === "FAIL") {
  interpretations.push("F3_1 measured a content-integrity failure: pathname truncation changed a fixture that the applied policy marked read-only. The test result alone does not identify the underlying mechanism.");
}
const extendedFailures = expected.filter((id) => Number(id.slice(1)) > 10 && results[id]?.status === "FAIL");
const unreviewedExtendedFailures = extendedFailures.filter((id) => !(id === "F3_3" && results.F3_1?.status === "FAIL"));
const knownLimitations = expected.filter((id) => results[id]?.status === "LANDLOCK-LIMITATION");
if (results.F2_5?.status === "LANDLOCK-LIMITATION") interpretations.push("F2_5 records a known Landlock limitation: chmod metadata changes are outside Landlock mediation.");
if (results.N08?.status === "EXPECTED") interpretations.push("N08 matched the suite's predefined GET-to-HEAD method expectation.");
if (results.F2_17?.status === "EXPECTED") interpretations.push("F2_17 observed that execution from the read-only path remained allowed; content-mutation restrictions are measured by separate tests.");
if (unreviewedExtendedFailures.length) interpretations.push(`Extended robustness failures requiring semantic review: ${unreviewedExtendedFailures.join(", ")}.`);
if (results.F3_1?.status === "FAIL" && results.F3_3?.status === "FAIL") interpretations.push("F3_1 and F3_3 are correlated observations of truncation behavior and should be grouped as one provisional finding. Attributing a specific root cause requires separate runtime evidence.");
if (knownLimitations.length) interpretations.push(`Documented Landlock scope limitations observed: ${knownLimitations.join(", ")}. These do not count as independent enforcement failures.`);
if (missing.length) interpretations.push(`Missing test results: ${missing.join(", ")}.`);
if (evidenceProblems.length) interpretations.push(`Evidence integrity problems: ${evidenceProblems.join(" ")}`);
if (counts.INCONCLUSIVE) interpretations.push(`${counts.INCONCLUSIVE} test(s) were inconclusive and require rerun or environment repair.`);

const nameOf = (id, ar) => testNames[id]?.[ar ? 1 : 0] ?? "";
const cell = (text) => String(text).replaceAll("|", "\\|"); // a raw "|" would split a Markdown table cell
const attention = expected.filter((id) => !results[id] || ["FAIL", "INCONCLUSIVE"].includes(results[id].status));

function summarySection(ar) {
  const rows = Object.entries(counts).filter(([key, value]) => key !== "OTHER" || value > 0);
  return [
    ar ? "## الملخص" : "## Summary",
    "",
    ar ? "| الحالة | العدد |" : "| Status | Count |",
    "|---|---|",
    ...rows.map(([key, value]) => `| ${key} | ${value} |`),
    `| MISSING | ${missing.length} |`,
    "",
    ...(attention.length === expected.length && missing.length === expected.length ? [
      ar ? "## يحتاج مراجعة" : "## Needs attention",
      "",
      ar
        ? "- لم تُنتج أي نتائج لأي اختبار. راجع «مشكلات سلامة الأدلة» في قسم الاستنتاج الآلي، وسجلات التشغيل."
        : "- No test produced a result. See the evidence integrity problems under Automatic interpretation and the run output.",
      "",
    ] : attention.length ? [
      ar ? "## يحتاج مراجعة" : "## Needs attention",
      "",
      ...attention.map((id) => `- **${id}** ${nameOf(id, ar)}: \`${results[id]?.status ?? "MISSING"}\` — ${results[id]?.evidence ?? (ar ? "لم يُعثر على نتيجة." : "No result file was found.")}`),
      "",
    ] : []),
  ];
}

function pct(rate) {
  return rate === null ? "N/A" : `${(rate * 100).toFixed(1)}%`;
}

function metricsSection(ar) {
  const coverageLine = ar
    ? `- **تغطية الاختبارات الصالحة (Valid-Test Coverage):** ${validAttempts.length} / ${expected.length} (${pct(validTestCoverage)})`
    : `- **Valid-Test Coverage:** ${validAttempts.length} / ${expected.length} (${pct(validTestCoverage)})`;
  const overallLine = ar
    ? `- **معدّل التجاوز الكلي (Bypass Rate):** ${bypassOverall.bypasses} / ${bypassOverall.validProhibited} (${pct(bypassOverall.rate)})`
    : `- **Overall Bypass Rate:** ${bypassOverall.bypasses} / ${bypassOverall.validProhibited} (${pct(bypassOverall.rate)})`;
  return [
    ar ? "## المقاييس" : "## Metrics",
    "",
    coverageLine,
    overallLine,
    "",
    ar ? "| السيناريو | التجاوزات المؤكدة | المحاولات المحظورة الصالحة | معدّل التجاوز |" : "| Scenario | Confirmed bypasses | Valid prohibited attempts | Bypass Rate |",
    "|---|---|---|---|",
    ...bypassByScenario.map(([nameEn, nameAr, stats]) => `| ${ar ? nameAr : nameEn} | ${stats.bypasses} | ${stats.validProhibited} | ${pct(stats.rate)} |`),
    "",
    ar
      ? "- التعريفات في `docs/CLAIMS.md` («M4 evaluation»). السيناريو مجموعة حسب عائلة الاختبار (الشبكة، أو فئة الملفات)؛ خريطة أدق حسب مجال الضمان موجودة في جدول «Claim-to-test coverage» بـ `docs/CLAIMS.md`. الاختبارات المصممة للسماح عمدًا (N08, N10, F2_11, F2_17) مستبعدة من مقام معدّل التجاوز لأنها لا تختبر عملية محظورة."
      : "- Definitions are in `docs/CLAIMS.md` (\"M4 evaluation\"). Scenario groups by test family (network, or filesystem category); the finer assurance-area mapping is in `docs/CLAIMS.md`'s \"Claim-to-test coverage\" table. Tests designed to be allowed (N08, N10, F2_11, F2_17) are excluded from the Bypass Rate denominator since they do not exercise a prohibited operation.",
    "",
  ];
}

function resultTables(ar) {
  if (missing.length === expected.length) return []; // nothing measured: the per-test tables would only repeat MISSING
  const sections = [
    [networkIds, "Network tests", "اختبارات الشبكة"],
    [filesystemIds, "Filesystem tests", "اختبارات الملفات"],
  ];
  return sections.flatMap(([ids, titleEn, titleAr]) => {
    const shown = expected.filter((id) => ids.has(id));
    if (!shown.length) return [];
    return [
      `## ${ar ? titleAr : titleEn} (${shown.length})`,
      "",
      ar ? "| الاختبار | الوصف | النتيجة | الدليل |" : "| Test | Description | Status | Evidence |",
      "|---|---|---|---|",
      ...shown.map((id) => `| ${id} | ${cell(nameOf(id, ar))} | \`${results[id]?.status ?? "MISSING"}\` | ${cell(results[id]?.evidence ?? (ar ? "لم يُعثر على نتيجة." : "No result file was found."))} |`),
      "",
    ];
  });
}

const generatedAt = new Date();
const stamp = generatedAt.toISOString().replace(/[-:.]/g, "");
const payload = {
  schema_version: 4,
  scope,
  run_id: selectedRunId,
  openshell_version: openshellVersion,
  openshell_version_source: openshellVersionSource,
  generated_at: generatedAt.toISOString(),
  platform: { os: os.platform(), release: os.release(), arch: os.arch() },
  sources: {
    network: scope !== "filesystem" && networkFile ? path.relative(root, networkFile).replaceAll("\\", "/") : null,
    filesystem: scope !== "network" && filesystemFile ? path.relative(root, filesystemFile).replaceAll("\\", "/") : null,
  },
  overall,
  exit_code: exitCode,
  counts,
  metrics: {
    valid_test_coverage: { valid_attempts: validAttempts.length, expected: expected.length, rate: validTestCoverage },
    bypass_rate: {
      overall: { bypasses: bypassOverall.bypasses, valid_prohibited_attempts: bypassOverall.validProhibited, rate: bypassOverall.rate },
      by_scenario: Object.fromEntries(bypassByScenario.map(([nameEn, , stats]) => [
        nameEn, { bypasses: stats.bypasses, valid_prohibited_attempts: stats.validProhibited, rate: stats.rate },
      ])),
    },
  },
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
  `- OpenShell version: \`${openshellVersion ?? "unknown"}\`${openshellVersionSource === "evidence" ? "" : ` (${openshellVersionSource})`}`,
  `- Run ID: \`${selectedRunId ?? "missing"}\``,
  `- Platform: \`${payload.platform.os} ${payload.platform.arch} ${payload.platform.release}\``,
  `- Network source: \`${payload.sources.network ?? "missing"}\``,
  `- Filesystem source: \`${payload.sources.filesystem ?? "missing"}\``,
  `- Evidence signature: \`${attestation.verified ? "VERIFIED" : "NOT VERIFIED"}\``,
  `- Signing-key fingerprint: \`${attestation.fingerprint ?? "missing"}\``,
  "",
  ...summarySection(false),
  ...metricsSection(false),
  ...resultTables(false),
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
  `- إصدار OpenShell: \`${openshellVersion ?? "غير معروف"}\`${openshellVersionSource === "evidence" ? "" : ` (${openshellVersionSource === "unknown" ? "غير معروف" : "مطلوب، ولا توجد أدلة"})`}`,
  `- معرّف التشغيل: \`${selectedRunId ?? "غير موجود"}\``,
  `- المنصة: \`${payload.platform.os} ${payload.platform.arch} ${payload.platform.release}\``,
  `- مصدر الشبكة: \`${payload.sources.network ?? "غير موجود"}\``,
  `- مصدر الملفات: \`${payload.sources.filesystem ?? "غير موجود"}\``,
  `- توقيع الأدلة: \`${attestation.verified ? "VERIFIED" : "NOT VERIFIED"}\``,
  `- بصمة مفتاح التوقيع: \`${attestation.fingerprint ?? "غير موجودة"}\``,
  "",
  ...summarySection(true),
  ...metricsSection(true),
  ...resultTables(true),
  "## الاستنتاج الآلي",
  "",
  ...(scope !== "filesystem" ? [[ ...networkIds ].every((id) => ["PASS", "EXPECTED"].includes(results[id]?.status))
    ? "- وافقت جميع اختبارات الشبكة الأساسية والموسعة توقعات الإنفاذ المحددة."
    : "- توجد نتيجة شبكة غير ناجحة أو ناقصة وتحتاج مراجعة."] : []),
  ...(scope !== "network" ? [results.F3_1?.status === "FAIL"
    ? "- قاس F3_1 فشلًا في سلامة المحتوى: غيّرت truncate ملفًا صنفته السياسة المطبقة كـ read_only. لا تكفي نتيجة الاختبار وحدها لتحديد الآلية المسببة."
    : "- لم يسجل F3_1 فشلًا في أحدث جولة."] : []),
  ...(unreviewedExtendedFailures.length ? [`- إخفاقات robustness التي ما زالت تحتاج مراجعة دلالية: ${unreviewedExtendedFailures.join(", ")}.`] : []),
  ...(knownLimitations.length ? [`- قيود Landlock الموثقة التي ظهرت: ${knownLimitations.join(", ")}. لا تُحسب هذه كإخفاقات إنفاذ مستقلة.`] : []),
  ...(results.N08?.status === "EXPECTED" ? ["- طابق N08 التوقع المحدد مسبقًا في المختبر لمعاملة HEAD مع قاعدة GET."] : []),
  ...(results.F2_17?.status === "EXPECTED" ? ["- لاحظ F2_17 أن التنفيذ من مسار read_only ظل مسموحًا؛ وتقيس اختبارات منفصلة قيود تعديل المحتوى."] : []),
  ...(results.F3_1?.status === "FAIL" && results.F3_3?.status === "FAIL" ? ["- F3_1 وF3_3 ملاحظتان مترابطتان لسلوك truncate وتُجمعان كنتيجة أولية واحدة. يحتاج تحديد سبب جذري بعينه إلى دليل تشغيل منفصل."] : []),
  ...(missing.length ? [`- النتائج المفقودة: ${missing.join(", ")}.`] : []),
  ...(evidenceProblems.length ? [`- مشكلات سلامة الأدلة: ${evidenceProblems.join(" ")}`] : []),
  "",
  `رمز الخروج: \`${exitCode}\` (0 لا توجد إخفاقات إنفاذ مقاسة، وتظل PASS_WITH_LIMITATIONS ظاهرة بوضوح؛ 1 فشل مقاس؛ 2 نتيجة ناقصة أو غير حاسمة).`,
  "",
].join("\n");

// Layout: latest/LATEST.* keeps stable paths; the same files are also kept per run under run-history/<run-id>/
// and as the latest report of each OpenShell version under latest-by-version/<version>/.
const runDir = path.join(outputDir, "run-history", selectedRunId ?? `unknown-${stamp}`);
const versionDir = path.join(outputDir, "latest-by-version", versionFolder);
const latestDir = path.join(outputDir, "latest");
fs.mkdirSync(runDir, { recursive: true });
fs.mkdirSync(versionDir, { recursive: true });
fs.mkdirSync(latestDir, { recursive: true });
for (const [directory, name, content] of [
  [runDir, "analysis.json", json],
  [runDir, "analysis.md", markdown],
  [runDir, "analysis_AR.md", markdownAr],
  [latestDir, "LATEST.json", json],
  [latestDir, "LATEST.md", markdown],
  [latestDir, "LATEST_AR.md", markdownAr],
  [versionDir, "LATEST.json", json],
  [versionDir, "LATEST.md", markdown],
  [versionDir, "LATEST_AR.md", markdownAr],
]) fs.writeFileSync(path.join(directory, name), content, "utf8");

console.log(markdown);
console.log(`Analysis files: ${path.relative(root, latestDir).replaceAll("\\", "/")}/LATEST.md, LATEST_AR.md, LATEST.json, and ${path.relative(root, runDir).replaceAll("\\", "/")}/`);
process.exitCode = exitCode;
