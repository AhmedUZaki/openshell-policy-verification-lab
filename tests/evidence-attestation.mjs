import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const moduleFile = fileURLToPath(import.meta.url);
const defaultRoot = path.dirname(path.dirname(moduleFile));

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

function publicKeyFingerprint(publicKeyPem) {
  const der = crypto.createPublicKey(publicKeyPem).export({ type: "spki", format: "der" });
  return sha256(der);
}

function keyPaths(root) {
  const directory = path.join(root, ".local-keys");
  return {
    directory,
    privateKey: path.join(directory, "evidence-private-key.pem"),
    publicKey: path.join(directory, "evidence-public-key.pem"),
  };
}

export function initializeSigningKey(root = defaultRoot) {
  const keys = keyPaths(root);
  fs.mkdirSync(keys.directory, { recursive: true });
  const privateExists = fs.existsSync(keys.privateKey);
  const publicExists = fs.existsSync(keys.publicKey);
  if (privateExists !== publicExists) {
    throw new Error(`Incomplete signing identity in ${keys.directory}; both private and public key files are required.`);
  }
  if (!privateExists) {
    const pair = crypto.generateKeyPairSync("ed25519");
    fs.writeFileSync(keys.privateKey, pair.privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
    fs.writeFileSync(keys.publicKey, pair.publicKey.export({ type: "spki", format: "pem" }), { mode: 0o644 });
  }
  const privateKeyPem = fs.readFileSync(keys.privateKey, "utf8");
  const publicKeyPem = fs.readFileSync(keys.publicKey, "utf8");
  const derivedPublic = crypto.createPublicKey(privateKeyPem).export({ type: "spki", format: "pem" });
  if (publicKeyFingerprint(derivedPublic) !== publicKeyFingerprint(publicKeyPem)) {
    throw new Error("The local evidence private and public keys do not form one key pair.");
  }
  return { ...keys, privateKeyPem, publicKeyPem, fingerprint: publicKeyFingerprint(publicKeyPem) };
}

function validateRunId(runId) {
  if (!runId || !/^[A-Za-z0-9._-]+$/.test(runId)) throw new Error("A safe --run-id value is required.");
}

function scopeAreas(scope) {
  if (scope === "network") return ["network"];
  if (scope === "filesystem") return ["filesystem"];
  if (scope === "all") return ["network", "filesystem"];
  throw new Error(`Unsupported attestation scope: ${scope}`);
}

function expectedEvidenceNames(area, runId) {
  if (area === "network") {
    return [
      `network-${runId}.md`,
      `network-${runId}.raw.log`,
      `network-${runId}-host-a.json`,
      `network-${runId}-host-b.json`,
      `network-${runId}-effective-policy-initial.yaml`,
      `network-${runId}-effective-policy-final.yaml`,
      `network-${runId}-openshell.log`,
    ];
  }
  return [`filesystem-${runId}.md`, `filesystem-${runId}.raw.log`];
}

function collectEvidenceFiles(root, runId, scope) {
  const files = [];
  for (const area of scopeAreas(scope)) {
    const directory = path.join(root, "tests", area, "results");
    if (!fs.existsSync(directory)) continue;
    for (const name of expectedEvidenceNames(area, runId)) {
      const absolute = path.join(directory, name);
      if (!fs.existsSync(absolute)) continue;
      const stat = fs.lstatSync(absolute);
      if (!stat.isFile()) throw new Error(`Evidence path is not a regular file: ${absolute}`);
      const data = fs.readFileSync(absolute);
      files.push({
        path: path.relative(root, absolute).replaceAll("\\", "/"),
        bytes: data.length,
        sha256: sha256(data),
      });
    }
  }
  return files.sort((a, b) => a.path.localeCompare(b.path));
}

function attestationPaths(root, runId) {
  const directory = path.join(root, "evidence-attestations");
  return {
    directory,
    manifest: path.join(directory, `evidence-${runId}.manifest.json`),
    signature: path.join(directory, `evidence-${runId}.sig`),
    publicKey: path.join(directory, `evidence-${runId}.public.pem`),
  };
}

export function createEvidenceAttestation({ root = defaultRoot, runId, scope = "all" }) {
  validateRunId(runId);
  scopeAreas(scope);
  const keys = initializeSigningKey(root);
  const files = collectEvidenceFiles(root, runId, scope);
  if (!files.length) throw new Error(`No evidence files were found for run ${runId}.`);
  const outputs = attestationPaths(root, runId);
  fs.mkdirSync(outputs.directory, { recursive: true });
  for (const file of [outputs.manifest, outputs.signature, outputs.publicKey]) {
    if (fs.existsSync(file)) throw new Error(`Attestation output already exists: ${file}`);
  }
  const manifest = {
    schema_version: 1,
    run_id: runId,
    scope,
    created_at: new Date().toISOString(),
    hash_algorithm: "SHA-256",
    signing_algorithm: "Ed25519",
    public_key_fingerprint_sha256: keys.fingerprint,
    files,
  };
  const manifestBytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  const signature = crypto.sign(null, manifestBytes, keys.privateKeyPem);
  fs.writeFileSync(outputs.manifest, manifestBytes);
  fs.writeFileSync(outputs.signature, `${signature.toString("base64")}\n`, "utf8");
  fs.writeFileSync(outputs.publicKey, keys.publicKeyPem, "utf8");
  return { ...outputs, manifest: outputs.manifest, fingerprint: keys.fingerprint, fileCount: files.length };
}

function isSafeEvidencePath(relative, scope) {
  if (typeof relative !== "string" || relative.includes("\\") || path.posix.isAbsolute(relative)) return false;
  const normalized = path.posix.normalize(relative);
  if (normalized !== relative || normalized.startsWith("../") || normalized.includes("/../")) return false;
  return scopeAreas(scope).some((area) => normalized.startsWith(`tests/${area}/results/${area}-`));
}

export function verifyEvidenceAttestation({ root = defaultRoot, runId, scope = "all", publicKeyPath = null }) {
  const problems = [];
  const outputs = attestationPaths(root, runId);
  for (const [label, file] of [["manifest", outputs.manifest], ["signature", outputs.signature]]) {
    if (!fs.existsSync(file)) problems.push(`Missing evidence attestation ${label}: ${path.relative(root, file)}.`);
  }
  const trustedKey = publicKeyPath || process.env.EVIDENCE_VERIFY_PUBLIC_KEY || keyPaths(root).publicKey;
  if (!fs.existsSync(trustedKey)) problems.push(`Missing trusted evidence public key: ${trustedKey}.`);
  if (problems.length) return { problems, verified: false, fingerprint: null, files: 0 };

  let manifest;
  let manifestBytes;
  let publicKeyPem;
  try {
    manifestBytes = fs.readFileSync(outputs.manifest);
    manifest = JSON.parse(manifestBytes.toString("utf8"));
    publicKeyPem = fs.readFileSync(trustedKey, "utf8");
  } catch (error) {
    return { problems: [`Unreadable evidence attestation: ${error.message}`], verified: false, fingerprint: null, files: 0 };
  }
  if (manifest.schema_version !== 1) problems.push(`Unsupported evidence manifest schema: ${manifest.schema_version}.`);
  if (manifest.run_id !== runId) problems.push(`Evidence manifest reports run ID ${manifest.run_id ?? "missing"}, expected ${runId}.`);
  if (manifest.scope !== scope) problems.push(`Evidence manifest scope is ${manifest.scope ?? "missing"}, expected ${scope}.`);
  if (manifest.hash_algorithm !== "SHA-256" || manifest.signing_algorithm !== "Ed25519") problems.push("Evidence manifest uses unsupported cryptographic algorithms.");

  let fingerprint = null;
  try {
    fingerprint = publicKeyFingerprint(publicKeyPem);
    if (manifest.public_key_fingerprint_sha256 !== fingerprint) problems.push("Evidence manifest fingerprint does not match the trusted public key.");
    const signature = Buffer.from(fs.readFileSync(outputs.signature, "utf8").trim(), "base64");
    if (!crypto.verify(null, manifestBytes, publicKeyPem, signature)) problems.push("Evidence manifest signature verification failed.");
  } catch (error) {
    problems.push(`Evidence signature verification error: ${error.message}`);
  }

  const listed = new Set();
  if (!Array.isArray(manifest.files) || !manifest.files.length) {
    problems.push("Evidence manifest contains no files.");
  } else {
    for (const entry of manifest.files) {
      if (!entry || !isSafeEvidencePath(entry.path, scope)) {
        problems.push(`Unsafe or out-of-scope evidence path: ${entry?.path ?? "missing"}.`);
        continue;
      }
      if (listed.has(entry.path)) {
        problems.push(`Duplicate evidence manifest path: ${entry.path}.`);
        continue;
      }
      listed.add(entry.path);
      const absolute = path.join(root, ...entry.path.split("/"));
      if (!fs.existsSync(absolute) || !fs.lstatSync(absolute).isFile()) {
        problems.push(`Signed evidence file is missing: ${entry.path}.`);
        continue;
      }
      const data = fs.readFileSync(absolute);
      if (data.length !== entry.bytes) problems.push(`Signed evidence size changed: ${entry.path}.`);
      if (sha256(data) !== entry.sha256) problems.push(`Signed evidence hash changed: ${entry.path}.`);
    }
  }

  for (const current of collectEvidenceFiles(root, runId, scope)) {
    if (!listed.has(current.path)) problems.push(`Unsigned evidence file is present: ${current.path}.`);
  }
  return { problems, verified: problems.length === 0, fingerprint, files: listed.size };
}

function parseCli(argv) {
  const command = argv[0];
  let runId = null;
  let scope = "all";
  let publicKeyPath = null;
  for (let index = 1; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--run-id") runId = argv[++index] ?? null;
    else if (arg === "--network-only" && scope === "all") scope = "network";
    else if (arg === "--filesystem-only" && scope === "all") scope = "filesystem";
    else if (arg === "--public-key") publicKeyPath = argv[++index] ?? null;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return { command, runId, scope, publicKeyPath };
}

function main() {
  const { command, runId, scope, publicKeyPath } = parseCli(process.argv.slice(2));
  if (command === "init") {
    const result = initializeSigningKey();
    console.log(`Evidence signing key ready. SHA-256 fingerprint: ${result.fingerprint}`);
  } else if (command === "create") {
    const result = createEvidenceAttestation({ runId, scope });
    console.log(`Signed ${result.fileCount} evidence files. Public-key fingerprint: ${result.fingerprint}`);
  } else if (command === "verify") {
    validateRunId(runId);
    const result = verifyEvidenceAttestation({ runId, scope, publicKeyPath });
    if (!result.verified) {
      for (const problem of result.problems) console.error(problem);
      process.exitCode = 2;
    } else {
      console.log(`Evidence attestation verified (${result.files} files). Public-key fingerprint: ${result.fingerprint}`);
    }
  } else {
    throw new Error("Usage: evidence-attestation.mjs init | create --run-id ID [--network-only|--filesystem-only] | verify --run-id ID [scope] [--public-key FILE]");
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(moduleFile)) {
  try {
    main();
  } catch (error) {
    console.error(`Evidence attestation error: ${error.message}`);
    process.exitCode = 2;
  }
}
