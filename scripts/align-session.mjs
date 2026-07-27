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
 * Turn recorded events into aligner candidates.
 *
 * A `candidate` event and the `probe` that followed it describe the same
 * pointing act from two angles — the candidate carries the noise features, the
 * probe carries what was actually grounded. Pair them by time so the aligner
 * sees one object with both.
 */
function toCandidates(events) {
  const candidates = events.filter((e) => e.type === "candidate");
  const probes = events.filter((e) => e.type === "probe");

  const used = new Set();
  const paired = candidates.map((c, i) => {
    // The probe for a candidate is resolved asynchronously, so it lands
    // slightly after; take the nearest unused one within a second.
    let best = -1;
    let bestGap = Infinity;
    probes.forEach((p, pi) => {
      if (used.has(pi) || p.shape.kind !== "point") return;
      const gap = Math.abs(p.t - c.t);
      if (gap < bestGap && gap < 1000) {
        bestGap = gap;
        best = pi;
      }
    });
    const probe = best >= 0 ? (used.add(best), probes[best]) : undefined;

    return {
      id: `cand-${i}`,
      t: c.t,
      position: c.position,
      features: c.features,
      app: c.app,
      kind: "point",
      grounded: grounded(probe),
      text: bestText(probe),
    };
  });

  // Regions never produce a `candidate` event — a drag is explicit, so it goes
  // straight to a referent. They still have to reach the aligner.
  //
  // A region's probe is stamped at mouse-UP, but the user talks while DRAWING —
  // in a real session "Yeh" was spoken 4.6s before commit, mid-gesture. The
  // drag's start is recoverable because swallowing the drag events freezes the
  // OS cursor at the drag origin: the cursor samples sit at exactly path[0]
  // for the whole gesture, so the frozen run's first sample is the drag start.
  // The candidate's time becomes the gesture's midpoint, and its dwell the
  // full gesture duration.
  const cursorSamples = events.filter((e) => e.type === "cursor");
  const regions = probes
    .filter((p) => p.shape.kind === "region")
    .map((p, i) => {
      const origin = p.shape.path?.[0] ?? p.shape.origin;
      let dragStart = p.t;
      for (let s = cursorSamples.length - 1; s >= 0; s--) {
        const c = cursorSamples[s];
        if (c.t >= p.t) continue;
        if (p.t - c.t > 30_000) break;
        if (Math.hypot(c.x - origin.x, c.y - origin.y) < 4) dragStart = c.t;
        else if (dragStart !== p.t) break; // walked past the frozen run
      }
      const duration = p.t - dragStart;
      return {
        id: `region-${i}`,
        t: dragStart + duration / 2,
        position: p.shape.origin,
        features: { dwellMs: Math.max(duration, 600), approachSpeed: 0 },
        app: p.app,
        kind: "region",
        grounded: grounded(p),
        text: bestText(p),
      };
    });

  return [...paired, ...regions].sort((a, b) => a.t - b.t);
}

function grounded(probe) {
  if (!probe) return false;
  const ax = probe.snapshot?.elements?.some((e) =>
    [e.value, e.title, e.elementDescription, e.selectedText].some((t) => t && t.trim()),
  );
  return Boolean(ax || probe.crop?.ocr?.length);
}

function bestText(probe) {
  if (!probe) return undefined;
  const ax = (probe.snapshot?.elements ?? [])
    .map((e) => e.value || e.title || e.elementDescription || e.selectedText)
    .filter((t) => t && t.trim());
  if (ax.length) return ax.join(" · ").slice(0, 90);
  const ocr = (probe.crop?.ocr ?? []).map((o) => o.text);
  return ocr.length ? `[ocr] ${ocr.join(" ").slice(0, 90)}` : undefined;
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

const byId = new Map(candidates.map((c) => [c.id, c]));

console.log(`session: ${sessionDir}`);
console.log(`candidates: ${candidates.length}  words: ${words.length}\n`);

for (const b of bindings) {
  const c = byId.get(b.candidateId);
  const flag = b.confidence < 0.5 ? "  ⚠ LOW" : "";
  console.log(`[${b.confidence.toFixed(2)}] ${b.reason.padEnd(8)} ${c?.kind.padEnd(6)} ${c?.app?.name ?? "?"}${flag}`);
  console.log(`   said:      "${b.utterance}"`);
  if (b.deicticWord) console.log(`   pointed:   "${b.deicticWord}" at ${Math.round(b.deicticAt)}ms`);
  console.log(`   referent:  ${c?.text ?? "(grounded nothing)"}`);
  console.log();
}

console.log(`bound: ${bindings.length}/${candidates.length}`);
console.log(`unbound (expected — the recorder over-captures on purpose): ${unbound.length}`);

const low = bindings.filter((b) => b.confidence < 0.5).length;
if (low) console.log(`low-confidence bindings needing review: ${low}`);

console.log(`
Next: hand-label which candidate each utterance SHOULD have bound to, then
score this output against it. ≥80% correct is the T0.2 gate.`);
