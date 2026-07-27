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

/**
 * Adapt the referent stack into aligner candidates.
 *
 * Pairing candidate+probe events, recovering a lasso's drag span, and ordering
 * across app visits all live in `@fovea/referents` now — this used to be a
 * second copy of that logic here, which is exactly how the two drift apart.
 */
function toCandidates(events) {
  return loadSession(events)
    .all()
    .map((r) => ({
      id: r.id,
      hold: r.hold,
      // Regions anchor at the drag's END with a dwell equal to the full span,
      // so the overlap window is exactly [dragStart, dragEnd]. Anchoring at
      // the midpoint shifted the window a half-span EARLY: it covered the
      // silence before the lasso and missed the drag's whole second half —
      // where the narration actually is.
      t: r.span ? r.span.end : r.t,
      features: r.capture ?? {
        // A deliberate drag needs no defence against being mistaken for a
        // resting hand. Its dwell is the real gesture duration.
        dwellMs: r.span ? r.span.end - r.span.start : 600,
        approachSpeed: 0,
      },
      app: r.app,
      kind: r.kind,
      grounded: r.text.ax.length > 0 || r.text.ocr.length > 0,
      text:
        r.text.ax.length > 0
          ? r.text.ax.join(" · ").slice(0, 90)
          : r.text.ocr.length > 0
            ? `[ocr] ${r.text.ocr.join(" ").slice(0, 90)}`
            : undefined,
    }));
}

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

const candidates = toCandidates(events);
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
