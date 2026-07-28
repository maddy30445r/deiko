#!/usr/bin/env node
/**
 * Run the alignment engine over a recorded session and print what bound to what.
 *
 *   node scripts/align-session.mjs sessions/<id>
 *
 * This is the T0.2 gate harness. Hand-label which candidate each utterance
 * SHOULD have bound to, compare against this output, and the accuracy is the
 * gate: ≥80% and we build M1, below and we stop and reconsider the mechanic.
 */

import { readFileSync, existsSync } from "node:fs";
import { resolve, join } from "node:path";

import { align } from "../packages/alignment/dist/src/align.js";
import { loadSession } from "../packages/referents/dist/src/session.js";
import { toCandidates } from "../packages/referents/dist/src/candidates.js";

function load(sessionDir, file) {
  const path = join(sessionDir, file);
  if (!existsSync(path)) throw new Error(`missing ${file} in ${sessionDir}`);
  return readFileSync(path, "utf8");
}

function loadEvents(sessionDir) {
  return load(sessionDir, "events.jsonl")
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

// Pairing candidate+probe events, recovering a lasso's drag span, ordering
// across app visits, and adapting the result for the aligner all live in
// `@fovea/referents` — the adaptation used to be a second copy here, and the
// brief renderer would have made it a third.

// ── Main ────────────────────────────────────────────────────────────────────

const sessionDir = process.argv[2];
if (!sessionDir) {
  console.error("usage: node scripts/align-session.mjs sessions/<id>");
  process.exit(2);
}

const dir = resolve(sessionDir);

let events;
let words;
try {
  events = loadEvents(dir);
  ({ words } = JSON.parse(load(dir, "transcript.json")));
} catch (err) {
  console.error(`✗ ${err.message}`);
  console.error(`  transcribe first:  node scripts/transcribe.mjs ${sessionDir}`);
  process.exit(1);
}

if (!words?.length) {
  console.error("✗ transcript.json has no words. Run scripts/transcribe.mjs first.");
  process.exit(1);
}

const candidates = toCandidates(loadSession(events).all());
const { bindings, unbound } = align(candidates, words);

/** Below this a binding is flagged for review rather than trusted. */
const LOW_CONFIDENCE = 0.5;

const byId = new Map(candidates.map((c) => [c.id, c]));

console.log(`session: ${sessionDir}`);
console.log(`candidates: ${candidates.length}  words: ${words.length}\n`);

for (const b of bindings) {
  const c = byId.get(b.candidateId);
  const flag = b.confidence < LOW_CONFIDENCE ? "  ⚠ LOW" : "";
  console.log(`[${b.confidence.toFixed(2)}] ${b.reason.padEnd(8)} ${c?.kind.padEnd(6)} ${c?.app?.name ?? "?"}${flag}`);
  console.log(`   said:      "${b.utterance}"`);
  if (b.deicticWord) console.log(`   pointed:   "${b.deicticWord}" at ${Math.round(b.deicticAt)}ms`);
  console.log(`   referent:  ${c?.text ?? "(grounded nothing)"}`);
  console.log();
}

console.log(`bound: ${bindings.length}/${candidates.length}`);
console.log(`unbound (expected — the recorder over-captures on purpose): ${unbound.length}`);

const low = bindings.filter((b) => b.confidence < LOW_CONFIDENCE).length;
if (low) console.log(`low-confidence bindings needing review: ${low}`);

console.log(`
Next: hand-label which candidate each utterance SHOULD have bound to, then
score this output against it. ≥80% correct is the T0.2 gate.`);
