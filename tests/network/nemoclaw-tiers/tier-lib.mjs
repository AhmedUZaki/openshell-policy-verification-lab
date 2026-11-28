// Shared, narrow extraction over this project's own vendored copies of NemoClaw's tier/preset
// YAML (not a general YAML parser). See SOURCE.md for provenance and the scope limitation.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const tiersDir = here;
export const presetsDir = path.join(here, "presets");

// Messaging-platform presets in Open are compiled by NemoClaw's OAuth-backed messaging
// subsystem (src/lib/messaging/), not static preset YAML. See SOURCE.md.
export const DYNAMIC_PRESETS = new Set(["slack", "discord", "telegram", "wechat", "whatsapp", "teams"]);

export function parseTiers(text) {
  const tiers = [];
  const lines = text.split(/\r?\n/);
  let current = null;
  for (const line of lines) {
    const tierStart = line.match(/^ {2}- name:\s*(\S+)\s*$/);
    if (tierStart) {
      current = { name: tierStart[1], presets: [] };
      tiers.push(current);
      continue;
    }
    if (!current) continue;
    const preset = line.match(/-\s*\{\s*name:\s*([\w-]+)\s*,\s*access:\s*([\w-]+)\s*\}/);
    if (preset) current.presets.push(preset[1]);
  }
  return tiers;
}

export function loadTiers() {
  return parseTiers(fs.readFileSync(path.join(tiersDir, "tiers.yaml"), "utf8"));
}

export function extractEndpoints(text) {
  const lines = text.split(/\r?\n/);
  const starts = [];
  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index].match(/^\s*-\s*host:\s*"?([^"\s]+)"?\s*$/);
    if (match) starts.push({ index, host: match[1] });
  }
  const endpoints = [];
  for (let s = 0; s < starts.length; s += 1) {
    const begin = starts[s].index;
    const end = s + 1 < starts.length ? starts[s + 1].index : lines.length;
    const block = lines.slice(begin, end).join("\n");
    const port = Number(block.match(/\bport:\s*(\d+)/)?.[1] ?? 443);
    const isFull = /\baccess:\s*full\b/.test(block);
    const rules = [...block.matchAll(/allow:\s*\{\s*method:\s*(\w+)\s*,\s*path:\s*"?([^"}\s]+)"?\s*\}/g)]
      .map((m) => `${m[1]} ${m[2]}`);
    endpoints.push({ host: starts[s].host, port, access: isFull ? "full" : "rest", rules });
  }
  return endpoints;
}

export function loadPresetEndpoints(name) {
  return extractEndpoints(fs.readFileSync(path.join(presetsDir, `${name}.yaml`), "utf8"));
}

// Merge a tier's resolved preset endpoints into one map keyed by "host:port". When two
// presets touch the same destination, the merge is the union: full beats any rest rule set.
export function buildTierMap(presetNames) {
  const map = new Map();
  for (const name of presetNames) {
    if (DYNAMIC_PRESETS.has(name)) continue; // excluded by design; reported separately
    for (const endpoint of loadPresetEndpoints(name)) {
      const key = `${endpoint.host}:${endpoint.port}`;
      const existing = map.get(key);
      if (!existing) {
        map.set(key, { access: endpoint.access, rules: new Set(endpoint.rules) });
      } else {
        if (endpoint.access === "full") existing.access = "full";
        for (const rule of endpoint.rules) existing.rules.add(rule);
      }
    }
  }
  return map;
}

// Return the verbatim "network_policies:" body (one YAML block per static preset,
// concatenated) for a tier's presets, for composing into a full sandbox policy file.
// Each vendored preset's top-level network_policies key is unique by construction
// (npm_yarn, pypi, huggingface, brave, brew/brew-balanced, weather, public_reference,
// atlassian, outlook_graph), so verbatim concatenation needs no renaming.
export function networkPoliciesBlock(presetNames) {
  const parts = [];
  for (const name of presetNames) {
    if (DYNAMIC_PRESETS.has(name)) continue;
    const text = fs.readFileSync(path.join(presetsDir, `${name}.yaml`), "utf8");
    const marker = "network_policies:";
    const start = text.indexOf(marker);
    if (start === -1) throw new Error(`${name}.yaml has no network_policies: block`);
    const body = text.slice(start + marker.length).replace(/\n$/, "");
    parts.push(body);
  }
  return parts.join("\n");
}
