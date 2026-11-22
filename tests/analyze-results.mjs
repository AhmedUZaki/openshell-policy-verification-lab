import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(here);
const outputDir = path.join(root, "audit-reports");
fs.mkdirSync(outputDir, { recursive: true });

const args = new Set(process.argv.slice(2));
const knownArgs = new Set(["--network-only", "--filesystem-only"]);
const unknownArgs = [...args].filter((arg) => !knownArgs.has(arg));
if (unknownArgs.length || (args.has("--network-only") && args.has("--filesystem-only"))) {
  console.error("Usage: analyze-results.mjs [--network-only|--filesystem-only]");
  process.exit(2);
}
const scope = args.has("--network-only") ? "network" : args.has("--filesystem-only") ? "filesystem" : "all";

function latestReport(directory, prefix) {
  if (!fs.existsSync(directory)) return null;
  return fs.readdirSync(directory)
    .filter((name) => name.startsWith(prefix) && name.endsWith(".md"))
    .sort()
    .at(-1) ?? null;
}

function parseRows(file, wanted) {
  const rows = {};
  if (!file) return rows;
  const text = fs.readFileSync(file, "utf8");
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\|\s*(T\d{2})\s*\|\s*`?([A-Z-]+)`?\s*\|\s*(.*?)\s*\|$/);
    if (match && wanted.has(match[1])) {
      rows[match[1]] = { status: match[2], evidence: match[3] };
    }
  }
  return rows;
}

const networkDir = path.join(here, "network", "results");
const filesystemDir = path.join(here, "filesystem", "results");
const networkName = latestReport(networkDir, "network-");
const filesystemName = latestReport(filesystemDir, "filesystem-");
const networkFile = networkName ? path.join(networkDir, networkName) : null;
const filesystemFile = filesystemName ? path.join(filesystemDir, filesystemName) : null;

const networkIds = new Set(["T01", "T02", "T03", "T04", "T05", "T06", "T17", "T18", "T19", "T20"]);
const filesystemIds = new Set([
  "T07", "T08", "T09", "T10", "T11", "T12", "T13", "T14", "T15", "T16",
  "T21", "T22", "T23", "T24", "T25", "T26", "T27", "T28", "T29", "T30",
  "T31", "T32", "T33", "T34", "T35", "T36",
]);
const results = {
  ...parseRows(networkFile, networkIds),
  ...parseRows(filesystemFile, filesystemIds),
};

// Preserve the measured evidence while applying the semantics established by
// the documented implementation review. These are not independent bypasses.
if (results.T16?.status === "FAIL") {
  results.T16 = { ...results.T16, measured_status: "FAIL", status: "KNOWN-LIMITATION" };
}
if (results.T18?.status === "FAIL") {
  results.T18 = { ...results.T18, measured_status: "FAIL", status: "EXPECTED" };
}
if (results.T35?.status === "FAIL" && results.T35.evidence.includes("ran successfully")) {
  results.T35 = { ...results.T35, measured_status: "FAIL", status: "EXPECTED" };
}

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
if (missing.length || counts.INCONCLUSIVE || counts.OTHER) {
  overall = "INCOMPLETE";
  exitCode = 2;
} else if (counts.FAIL) {
  overall = "MEASURED_FAILURE";
  exitCode = 1;
}

const interpretations = [];
if ([...networkIds].every((id) => ["PASS", "EXPECTED"].includes(results[id]?.status))) {
  interpretations.push("All core and extended network tests matched the configured enforcement expectations.");
}
if ([...filesystemIds].every((id) => ["PASS", "KNOWN-LIMITATION"].includes(results[id]?.status))) {
  interpretations.push("All filesystem enforcement expectations passed; KNOWN-LIMITATION rows separately record documented Landlock scope limits.");
} else if (results.T09?.status === "FAIL") {
  interpretations.push("T09 confirmed a content-integrity gap: pathname truncate changed a read-only fixture because OpenShell v0.0.116 applies Landlock ABI V2.");
}
const extendedFailures = expected.filter((id) => Number(id.slice(1)) > 10 && results[id]?.status === "FAIL");
const unreviewedExtendedFailures = extendedFailures.filter((id) => !(id === "T32" && results.T09?.status === "FAIL"));
const knownLimitations = expected.filter((id) => results[id]?.status === "KNOWN-LIMITATION");
if (results.T16?.status === "KNOWN-LIMITATION") interpretations.push("T16 records a known Landlock limitation: chmod metadata changes are outside Landlock mediation.");
if (results.T18?.status === "EXPECTED") interpretations.push("T18 matches OpenShell's intentional GET-to-HEAD method semantics; the explicit-rule documentation does not make that expansion clear.");
if (results.T35?.status === "EXPECTED") interpretations.push("T35 confirms that OpenShell read-only paths remain executable while content mutation is restricted; this is required for read-only system paths such as /usr.");
if (unreviewedExtendedFailures.length) interpretations.push(`Extended robustness failures requiring semantic review: ${unreviewedExtendedFailures.join(", ")}.`);
if (results.T09?.status === "FAIL" && results.T32?.status === "FAIL") interpretations.push("T09 and T32 are correlated manifestations of one ABI V2 truncation root cause, not two independent findings.");
if (knownLimitations.length) interpretations.push(`Documented Landlock scope limitations observed: ${knownLimitations.join(", ")}. These do not count as independent enforcement failures.`);
if (missing.length) interpretations.push(`Missing test results: ${missing.join(", ")}.`);
if (counts.INCONCLUSIVE) interpretations.push(`${counts.INCONCLUSIVE} test(s) were inconclusive and require rerun or environment repair.`);

const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "Z");
const payload = {
  schema_version: 1,
  scope,
  generated_at: new Date().toISOString(),
  platform: { os: os.platform(), release: os.release(), arch: os.arch() },
  sources: {
    network: scope !== "filesystem" && networkFile ? path.relative(root, networkFile).replaceAll("\\", "/") : null,
    filesystem: scope !== "network" && filesystemFile ? path.relative(root, filesystemFile).replaceAll("\\", "/") : null,
  },
  overall,
  exit_code: exitCode,
  counts,
  missing,
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
  `- Platform: \`${payload.platform.os} ${payload.platform.arch} ${payload.platform.release}\``,
  `- Network source: \`${payload.sources.network ?? "missing"}\``,
  `- Filesystem source: \`${payload.sources.filesystem ?? "missing"}\``,
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
  `Exit code: \`${exitCode}\` (0 = no enforcement failures; documented limitations may be present, 1 = measured FAIL, 2 = incomplete/inconclusive).`,
  "",
].join("\n");

const arabicOverall = {
  PASS: "كل التوقعات نجحت",
  MEASURED_FAILURE: "يوجد فشل مقاس في أحد توقعات الاختبار",
  INCOMPLETE: "النتائج ناقصة أو غير حاسمة",
}[overall];
const markdownAr = [
  "# التحليل الآلي لنتائج الإنفاذ",
  "",
  `- وقت الإنشاء: \`${payload.generated_at}\``,
  `- النتيجة العامة: \`${overall}\` — ${arabicOverall}`,
  `- النطاق: \`${scope}\``,
  `- المنصة: \`${payload.platform.os} ${payload.platform.arch} ${payload.platform.release}\``,
  `- مصدر الشبكة: \`${payload.sources.network ?? "غير موجود"}\``,
  `- مصدر الملفات: \`${payload.sources.filesystem ?? "غير موجود"}\``,
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
    ? "- أكد T09 فجوة في سلامة المحتوى: غيّرت truncate ملف read_only لأن OpenShell v0.0.116 يطبق Landlock ABI V2."
    : "- لم يسجل T09 فشلًا في أحدث جولة."] : []),
  ...(unreviewedExtendedFailures.length ? [`- إخفاقات robustness التي ما زالت تحتاج مراجعة دلالية: ${unreviewedExtendedFailures.join(", ")}.`] : []),
  ...(knownLimitations.length ? [`- قيود Landlock الموثقة التي ظهرت: ${knownLimitations.join(", ")}. لا تُحسب هذه كإخفاقات إنفاذ مستقلة.`] : []),
  ...(results.T18?.status === "EXPECTED" ? ["- يطابق T18 السلوك المقصود في OpenShell الذي يجعل HEAD يطابق GET؛ لكن توثيق القواعد الصريحة لا يوضح هذا التوسّع جيدًا."] : []),
  ...(results.T35?.status === "EXPECTED" ? ["- يؤكد T35 أن مسارات read_only تبقى قابلة للتنفيذ مع منع تعديل المحتوى؛ وهذا مطلوب لمسارات النظام مثل /usr."] : []),
  ...(results.T09?.status === "FAIL" && results.T32?.status === "FAIL" ? ["- T09 وT32 مظهران مرتبطان لسبب جذري واحد هو فجوة truncate في ABI V2، وليسا نتيجتين مستقلتين."] : []),
  ...(missing.length ? [`- النتائج المفقودة: ${missing.join(", ")}.`] : []),
  "",
  `رمز الخروج: \`${exitCode}\` (0 لا توجد إخفاقات إنفاذ، وقد توجد قيود موثقة؛ 1 فشل مقاس؛ 2 نتيجة ناقصة أو غير حاسمة).`,
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
