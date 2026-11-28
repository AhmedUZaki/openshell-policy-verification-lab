// Compares test results between OpenShell versions and writes
// audit-reports/latest/COMPARISON.md, COMPARISON_AR.md and COMPARISON.json.
//
// It only re-presents statuses that the analyzer already measured (it never rewrites one).
// Usage:
//   node tests/compare-versions.mjs                  every run in audit-reports/run-history
//   node tests/compare-versions.mjs --include-archive  also runs moved to archived-results/
//   node tests/compare-versions.mjs --run-id A --run-id B   only these runs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { testNames } from "./test-names.mjs";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const outputDir = path.join(root, "audit-reports");
const argv = process.argv.slice(2);
const includeArchive = argv.includes("--include-archive");
const wantedRunIds = [];
for (let index = 0; index < argv.length; index += 1) {
  if (argv[index] === "--run-id") wantedRunIds.push(argv[++index] ?? "");
}

// Written down BEFORE OpenShell 0.1.9 was measured, from reading the upstream source
// (docs/upstream-analysis/truncation-F3_1-F3_3.md). They are hypotheses to check, not results.
const predictions = [
  { test: "F3_1", version: "0.0.116", expected: "FAIL" },
  { test: "F3_1", version: "0.1.9", expected: "PASS" },
  { test: "F3_3", version: "0.0.116", expected: "FAIL" },
  { test: "F3_3", version: "0.1.9", expected: "PASS" },
];

const cell = (text) => String(text).replaceAll("|", "\\|");
const statusOrder = ["PASS", "FAIL", "EXPECTED", "LANDLOCK-LIMITATION", "INCONCLUSIVE"];

function analysisFiles() {
  const files = [];
  const runsDir = path.join(outputDir, "run-history");
  if (fs.existsSync(runsDir)) {
    for (const name of fs.readdirSync(runsDir)) files.push(path.join(runsDir, name, "analysis.json"));
  }
  const archiveDir = path.join(root, "archived-results");
  if (includeArchive && fs.existsSync(archiveDir)) {
    for (const name of fs.readdirSync(archiveDir)) files.push(path.join(archiveDir, name, "analysis", "analysis.json"));
  }
  return files.filter((file) => fs.existsSync(file));
}

const runs = [];
for (const file of analysisFiles()) {
  try {
    const payload = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!payload?.results || !payload.run_id) continue;
    if (wantedRunIds.length && !wantedRunIds.includes(payload.run_id)) continue;
    runs.push(payload);
  } catch (error) {
    console.error(`Skipping unreadable analysis ${path.relative(root, file)}: ${error.message}`);
  }
}
if (!runs.length) {
  console.error("No analysis.json files were found to compare. Run the audit first (see README).");
  process.exit(2);
}

// One column per OpenShell version; for the same version a later run overrides an earlier one per test.
const byVersion = new Map();
for (const run of runs.sort((a, b) => String(a.generated_at).localeCompare(String(b.generated_at)))) {
  const version = run.openshell_version ?? "unknown";
  if (!byVersion.has(version)) byVersion.set(version, { version, runIds: [], overall: null, results: {} });
  const entry = byVersion.get(version);
  entry.runIds.push(run.run_id);
  entry.overall = run.overall;
  entry.generatedAt = run.generated_at;
  for (const [id, item] of Object.entries(run.results)) entry.results[id] = item;
}
const semver = (value) => value.split(".").map((part) => Number.parseInt(part, 10) || 0);
const versions = [...byVersion.values()].sort((a, b) => {
  const left = semver(a.version);
  const right = semver(b.version);
  for (let index = 0; index < 3; index += 1) if (left[index] !== right[index]) return left[index] - right[index];
  return a.version.localeCompare(b.version);
});

const testIds = [...new Set(versions.flatMap((entry) => Object.keys(entry.results)))].sort();
const statusOf = (entry, id) => entry.results[id]?.status ?? "—";
const changed = testIds.filter((id) => {
  const present = versions.filter((entry) => entry.results[id]).map((entry) => entry.results[id].status);
  return present.length > 1 && new Set(present).size > 1;
});
const counts = (entry) => {
  const tally = Object.fromEntries(statusOrder.map((status) => [status, 0]));
  for (const item of Object.values(entry.results)) if (item.status in tally) tally[item.status] += 1;
  return tally;
};
const predictionRows = predictions.map((item) => {
  const entry = versions.find((candidate) => candidate.version === item.version);
  const observed = entry?.results[item.test]?.status ?? null;
  return { ...item, observed, verdict: observed === null ? "NOT MEASURED" : observed === item.expected ? "CONFIRMED" : "CONTRADICTED" };
});

function render(ar) {
  const t = (en, arabic) => (ar ? arabic : en);
  const head = ["| ", t("Test", "الاختبار"), " | ", t("Description", "الوصف"), " | ", versions.map((entry) => `\`${entry.version}\``).join(" | "), " |"].join("");
  const separator = `|---|---|${versions.map(() => "---").join("|")}|`;
  const row = (id) => `| ${id} | ${cell(testNames[id]?.[ar ? 1 : 0] ?? "")} | ${versions.map((entry) => `\`${statusOf(entry, id)}\``).join(" | ")} |`;
  return [
    `# ${t("OpenShell version comparison", "مقارنة إصدارات OpenShell")}`,
    "",
    `- ${t("Generated", "وقت الإنشاء")}: \`${new Date().toISOString()}\``,
    `- ${t("Versions compared", "الإصدارات المقارَنة")}: ${versions.map((entry) => `\`${entry.version}\``).join(", ")}`,
    "",
    `## ${t("Runs compared", "الجولات المقارَنة")}`,
    "",
    `| ${t("OpenShell version", "إصدار OpenShell")} | ${t("Run ID", "معرّف التشغيل")} | ${t("Overall", "النتيجة العامة")} |`,
    "|---|---|---|",
    ...versions.map((entry) => `| \`${entry.version}\` | ${entry.runIds.map((id) => `\`${id}\``).join(", ")} | \`${entry.overall}\` |`),
    "",
    `## ${t("Summary by version", "الملخص حسب الإصدار")}`,
    "",
    `| ${t("Version", "الإصدار")} | ${statusOrder.join(" | ")} |`,
    `|---|${statusOrder.map(() => "---").join("|")}|`,
    ...versions.map((entry) => `| \`${entry.version}\` | ${statusOrder.map((status) => counts(entry)[status]).join(" | ")} |`),
    "",
    `## ${t("Tests whose status differs between versions", "الاختبارات التي اختلفت نتيجتها بين الإصدارات")}`,
    "",
    ...(changed.length ? [head, separator, ...changed.map(row)] : [t("No test changed status between the compared versions.", "لم تتغير نتيجة أي اختبار بين الإصدارات المقارَنة.")]),
    "",
    `## ${t("Prediction check", "فحص التوقعات")} (docs/upstream-analysis/truncation-F3_1-F3_3.md)`,
    "",
    t("These expectations were written from reading the upstream source before the newer version was measured. A contradicted prediction means that analysis is wrong or incomplete.",
      "كُتبت هذه التوقعات من قراءة المصدر قبل قياس الإصدار الأحدث. التوقع المخالف يعني أن ذلك التحليل خاطئ أو ناقص."),
    "",
    `| ${t("Test", "الاختبار")} | ${t("Version", "الإصدار")} | ${t("Predicted", "المتوقع")} | ${t("Observed", "المقاس")} | ${t("Verdict", "الحكم")} |`,
    "|---|---|---|---|---|",
    ...predictionRows.map((item) => `| ${item.test} | \`${item.version}\` | \`${item.expected}\` | \`${item.observed ?? "—"}\` | **${item.verdict}** |`),
    "",
    `## ${t("All tests", "كل الاختبارات")}`,
    "",
    head,
    separator,
    ...testIds.map(row),
    "",
    `## ${t("How to read this", "كيف تقرأ هذا التقرير")}`,
    "",
    `- ${t("Statuses are copied from each run's analysis; nothing is rewritten here.", "الحالات منسوخة من تحليل كل جولة ولا يُعاد كتابة أي منها هنا.")}`,
    `- ${t("A changed status shows a difference between the two measured runs; it does not by itself identify the cause.", "تغير الحالة يبين فرقًا بين جولتين مقاستين ولا يحدد وحده السبب.")}`,
    `- ${t("— means the test was not part of any compared run for that version.", "— تعني أن الاختبار لم يكن ضمن أي جولة مقارَنة لذلك الإصدار.")}`,
    "",
  ].join("\n");
}

const json = JSON.stringify({
  schema_version: 1,
  generated_at: new Date().toISOString(),
  versions: versions.map((entry) => ({ version: entry.version, run_ids: entry.runIds, overall: entry.overall, counts: counts(entry) })),
  tests: Object.fromEntries(testIds.map((id) => [id, Object.fromEntries(versions.map((entry) => [entry.version, statusOf(entry, id)]))])),
  changed,
  predictions: predictionRows,
}, null, 2) + "\n";

const latestDir = path.join(outputDir, "latest");
fs.mkdirSync(latestDir, { recursive: true });
for (const [name, content] of [["COMPARISON.md", render(false)], ["COMPARISON_AR.md", render(true)], ["COMPARISON.json", json]]) {
  fs.writeFileSync(path.join(latestDir, name), content, "utf8");
}
console.log(render(false));
console.log("Comparison files: audit-reports/latest/COMPARISON.md, COMPARISON_AR.md, and COMPARISON.json");
