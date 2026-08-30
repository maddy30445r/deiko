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

import { resolve } from "node:path";

import { align } from "../packages/alignment/dist/src/align.js";
import { loadSession } from "../packages/alignment/dist/src/referents/session.js";
import { toCandidates } from "../packages/alignment/dist/src/referents/candidates.js";
import { loadEvents, loadFile as load } from "./lib/session-io.mjs";

// Pairing candidate+probe events, recovering a lasso's drag span, ordering them
// chronologically, and adapting the result for the aligner all live in
// `@deiko/alignment`'s `referents/` — the adaptation used to be a second copy
// here, and the brief renderer would have made it a third.

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

const byId = new Map(candidates.map((c) => [c.id, c]));

console.log(`session: ${sessionDir}`);
console.log(`candidates: ${candidates.length}  words: ${words.length}\n`);

for (const b of bindings) {
  const c = byId.get(b.candidateId);
  const flag = b.needsReview ? "  ⚠ REVIEW" : "";
  console.log(`[${b.confidence.toFixed(2)}] ${b.reason.padEnd(8)} ${c?.kind.padEnd(6)} ${c?.app?.name ?? "?"}${flag}`);
  console.log(`   said:      "${b.utterance}"`);
  if (b.deicticWord) console.log(`   pointed:   "${b.deicticWord}" at ${Math.round(b.deicticAt)}ms`);
  console.log(`   referent:  ${c?.text ?? "(grounded nothing)"}`);
  console.log();
}

console.log(`bound: ${bindings.length}/${candidates.length}`);
console.log(`unbound (expected — the recorder over-captures on purpose): ${unbound.length}`);

// Split by reason, not by a threshold. Overlap bindings all sit below 0.5 by
// construction, so counting "low confidence" just re-reported how many there
// were; what is worth knowing is how many of the STRONG ones were shaky.
const deictic = bindings.filter((b) => b.reason === "deictic");
const overlap = bindings.filter((b) => b.reason === "overlap");
const review = bindings.filter((b) => b.needsReview).length;
console.log(`  ${deictic.length} named by a deictic word, ${overlap.length} from speech overlapping the dwell`);
if (review) console.log(`  ${review} deictic binding(s) worth reviewing — the aligner was torn`);

const anchored = deictic.filter((b) => b.anchoredTiming === true).length;
const known = deictic.filter((b) => b.anchoredTiming !== undefined).length;
if (known) {
  // Reported, not scored. See `anchoredTiming` in types.ts.
  console.log(`  ${anchored}/${known} deictic bindings rest on a MEASURED word time, not an interpolated one`);
}

console.log(`
Next: hand-label which candidate each utterance SHOULD have bound to, then
score this output against it. ≥80% correct is the T0.2 gate.`);
