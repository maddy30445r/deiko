import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { COULD_NOT_TELL, FLOORS, TIERS, briefDate, decide, readBriefLine, slug, unplaceable, wantsQuickHint } from "../lib/context.mjs";

// ── Names and dates ─────────────────────────────────────────────────────────

test("a collection id is a slug of its name", () => {
  assert.equal(slug("Deiko"), "deiko");
  assert.equal(slug("acme-portal"), "acme-portal");
  assert.equal(slug("My Site (v2)"), "my-site-v2");
  assert.equal(slug("   "), "collection");
});

test("a brief's date comes from its stamp, with the year only when it is not this one", () => {
  const now = new Date(2026, 8, 23);
  assert.equal(briefDate("20260918-155717", now), "Sep 18");
  assert.equal(briefDate("20251102-090000", now), "Nov 2, 2025");
  assert.equal(briefDate("personas", now), "");
});

// ── Decisions ───────────────────────────────────────────────────────────────

const collections = [{ id: "deiko", name: "Deiko", hint: "" }, { id: "site", name: "Site", hint: "" }];

test("a confident collection is taken; a hesitant one falls through", () => {
  const sure = decide({ answers: { collection: { choice: "deiko", confidence: 0.6 } }, collections });
  assert.equal(sure.collection, "deiko");
  assert.equal(sure.confidence.collection, 0.6);
  const unsure = decide({ answers: { collection: { choice: "deiko", confidence: 0.59 } }, collections });
  assert.equal(unsure.collection, null);
  assert.equal(unsure.newCollection, null);
});

test("none of these plus a repo hint creates the collection, unless one already matches by name", () => {
  const fresh = decide({ answers: { collection: { choice: "none", confidence: 0.9 } }, collections, repoHints: ["acme-portal"] });
  assert.deepEqual(fresh.newCollection, { id: "acme-portal", name: "acme-portal" });
  assert.equal(fresh.collection, "acme-portal");
  const known = decide({ answers: { collection: { choice: "none", confidence: 0.9 } }, collections, repoHints: ["DEIKO"] });
  assert.equal(known.newCollection, null);
  assert.equal(known.collection, "deiko");
  const nothing = decide({ answers: { collection: { choice: "none", confidence: 0.9 } }, collections });
  assert.equal(nothing.collection, null);
});

test("an unknown collection id is never taken", () => {
  const out = decide({ answers: { collection: { choice: "made-up", confidence: 0.99 } }, collections });
  assert.equal(out.collection, null);
});

test("a confident task inside the shortlist is joined", () => {
  const args = { shortlist: ["t-20260918-155836"], sessionId: "20260920-100000", title: "Fix the price" };
  const yes = decide({ ...args, answers: { task: { choice: "t-20260918-155836", confidence: 0.7 } } });
  assert.equal(yes.task, "t-20260918-155836");
  assert.equal(yes.newTask, null);
  assert.equal(yes.confidence.task, 0.7);
});

test("below the floor, new, or outside the shortlist starts a task named for this brief", () => {
  const args = { shortlist: ["t-20260918-155836"], sessionId: "20260920-100000", title: "Fix the price" };
  for (const task of [
    { choice: "t-20260918-155836", confidence: 0.69 },
    { choice: "new", confidence: 0.99 },
    { choice: "t-20260101-000000", confidence: 0.99 },
    undefined,
  ]) {
    const out = decide({ ...args, answers: { task } });
    assert.equal(out.task, "t-20260920-100000");
    assert.deepEqual(out.newTask, { id: "t-20260920-100000", title: "Fix the price" });
  }
  assert.equal(FLOORS.task, 0.7);
});

// ── Candidates: the few it might be, when it can't tell ─────────────────────

const [A, B, C, D, E] = ["t-20260918-100000", "t-20260918-110000", "t-20260918-120000", "t-20260918-130000", "t-20260918-140000"];
const unsure = { shortlist: [A, B, C, D, E], scores: [10, 9, 8, 7, 6], sessionId: "20260920-100000", title: "Same bug" };

test("a joined brief and confident new work have no candidates", () => {
  const joined = decide({ ...unsure, answers: { task: { choice: A, confidence: 0.8, probabilities: { [A]: 0.8, [B]: 0.2 } } } });
  assert.equal(joined.task, A);
  assert.equal(joined.candidates, undefined);
  const fresh = decide({ ...unsure, answers: { task: { choice: "new", confidence: 0.7, probabilities: { new: 0.7, [A]: 0.3 } } } });
  assert.equal(fresh.candidates, undefined);
  assert.equal(decide({ ...unsure, answers: { task: { choice: "new", confidence: 0.7 } } }).candidates, undefined);
});

test("probabilities pick the candidates: shortlisted, at or over the floor, likeliest first, three at most", () => {
  const out = decide({ ...unsure, answers: { task: { choice: C, confidence: 0.4, probabilities: {
    new: 0.3, [A]: 0.1, [B]: 0.25, [C]: 0.4, [D]: 0.15, [E]: 0.2, "t-20260101-000000": 0.5,
  } } } });
  assert.equal(out.newTask.id, "t-20260920-100000", "unsure still starts its own task");
  assert.deepEqual(out.candidates, [C, B, E]);
  assert.equal(FLOORS.candidate, 0.15);
  const edge = decide({ ...unsure, answers: { task: { choice: "new", confidence: 0.5, probabilities: { [A]: 0.149, [B]: 0.15 } } } });
  assert.deepEqual(edge.candidates, [B], "one candidate is still worth asking about");
  const none = decide({ ...unsure, answers: { task: { choice: "new", confidence: 0.6, probabilities: { new: 0.6, [A]: 0.1 } } } });
  assert.equal(none.candidates, undefined, "a map with nothing over the floor is an answer, not a gap");
});

test("without probabilities, Jev's pick then the local score, down to half the top score", () => {
  // Jev's pick leads even when its local score is under the cut.
  const picked = decide({ ...unsure, scores: [10, 9, 1, 0, 0], answers: { task: { choice: C, confidence: 0.6 } } });
  assert.deepEqual(picked.candidates, [C, A, B]);
  // Only what scores at least half the top joins it.
  const cut = decide({ ...unsure, scores: [10, 5, 4.9, 1, 0], answers: { task: { choice: "new", confidence: 0.5 } } });
  assert.deepEqual(cut.candidates, [A, B]);
  // An id outside the shortlist, a missing answer, or an array where a map belongs all fall back the same way.
  for (const task of [{ choice: "t-20260101-000000", confidence: 0.9 }, undefined, { choice: "new", confidence: 0.5, probabilities: [0.9, 0.1] }]) {
    assert.deepEqual(decide({ ...unsure, scores: [10, 5, 4.9, 1, 0], answers: { task } }).candidates, [A, B]);
  }
  // Nothing matched locally and nothing picked: nobody to ask about.
  assert.equal(decide({ ...unsure, scores: [0, 0, 0, 0, 0], answers: { task: { choice: "new", confidence: 0.5 } } }).candidates, undefined);
});

test("a joined brief nothing else placed takes its task's collection, as sure as the join", () => {
  const args = { collections, shortlist: [A], scores: [10], sessionId: "20260920-100000", taskCollections: { [A]: "site" } };
  const joined = decide({ ...args, answers: { task: { choice: A, confidence: 0.8 } } });
  assert.equal(joined.collection, "site");
  assert.equal(joined.confidence.collection, 0.8);
  const own = decide({ ...args, answers: { collection: { choice: "deiko", confidence: 0.9 }, task: { choice: A, confidence: 0.8 } } });
  assert.equal(own.collection, "deiko", "its own answer wins");
  assert.equal(decide({ ...args, repoHints: ["Deiko"], answers: { task: { choice: A, confidence: 0.8 } } }).collection, "deiko",
    "so does a repo on its window");
  assert.equal(decide({ ...args, answers: { task: { choice: "new", confidence: 0.9 } } }).collection, null, "a new task inherits nothing");
  assert.equal(decide({ ...args, taskCollections: { [A]: "gone" }, answers: { task: { choice: A, confidence: 0.8 } } }).collection, null,
    "a collection since deleted is not brought back");
});

test("the tier is the most likely level, or the rounded score without probabilities", () => {
  const byProb = decide({ answers: { tier: { score: 0.4, probabilities: [0.2, 0.6, 0.15, 0.05], confidence: 0.6 } } });
  assert.equal(byProb.tier, "medium");
  assert.equal(byProb.confidence.tier, 0.6);
  const byScore = decide({ answers: { tier: { score: 2.6, confidence: 0.8 } } });
  assert.equal(byScore.tier, "reasoning");
  const off = decide({ answers: { tier: { score: 9 } } });
  assert.equal(off.tier, null);
  assert.equal(TIERS.length, 4);
});

test("score probabilities may arrive as an object keyed by level, as Vercel sends them", () => {
  // Measured on a live call: score 1.13, mass split 0.21 / 0.45 / 0.34 / 0.
  const out = decide({ answers: { tier: {
    score: 1.13, confidence: 0.44,
    probabilities: { "0": 0.21, "1": 0.45, "2": 0.34, "3": 0 },
  } } });
  assert.equal(out.tier, "medium");
  assert.equal(out.confidence.tier, 0.44);
  // And the array form from TypeSafe's own docs still works.
  assert.equal(decide({ answers: { tier: { probabilities: [0.1, 0.1, 0.7, 0.1] } } }).tier, "complex");
});

test("a missing or partial answer is a quiet no", () => {
  assert.deepEqual(decide({}), {
    collection: null, task: null, newTask: null, tier: null, confidence: {}, newCollection: null,
  });
});

test("the cost hint needs the toggle, a quick tier and a confident one", () => {
  assert.equal(wantsQuickHint({ tier: "quick", confidence: { tier: 0.8 } }, true), true);
  assert.equal(wantsQuickHint({ tier: "quick", confidence: { tier: 0.79 } }, true), false);
  assert.equal(wantsQuickHint({ tier: "medium", confidence: { tier: 0.99 } }, true), false);
  assert.equal(wantsQuickHint({ tier: "quick", confidence: { tier: 0.99 } }, false), false);
  assert.equal(wantsQuickHint(null, true), false);
});

// ── Reading a sibling ───────────────────────────────────────────────────────

test("a sibling is read with its summary line, task, windows, terms and outcome", () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-context-"));
  const dir = join(root, "20260918-155717");
  mkdirSync(dir);
  writeFileSync(join(dir, "brief.json"), JSON.stringify({ summary: {
    narration: "hey so fix the drag on the board", apps: ["Deiko"], windows: ["Orb.swift — Deiko"], screenTerms: ["drag"],
    repoHints: ["Deiko"],
  } }));
  writeFileSync(join(dir, "review-summary.txt"), "Fix the drag on the board.\nIt sticks.\n");
  writeFileSync(join(dir, "context.json"), JSON.stringify({ collection: "deiko", task: "t-20260915-100000" }));
  writeFileSync(join(dir, "outcome.md"), "## Did\nMoved the threshold.\n## Open\nTest on a trackpad.\n");
  assert.deepEqual(readBriefLine(dir), {
    id: "20260918-155717", dir,
    narration: "hey so fix the drag on the board",
    summaryLine: "Fix the drag on the board.",
    line: "Fix the drag on the board.",
    collection: "deiko", task: "t-20260915-100000",
    apps: ["Deiko"], windows: ["Orb.swift — Deiko"], screenTerms: ["drag"], repoHints: ["Deiko"],
    outcome: { did: ["Moved the threshold."], decided: [], open: ["Test on a trackpad."], files: [] },
  });
});

test("a long outcome is read whole and each section capped", () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-context-"));
  const dir = join(root, "20260918-155717");
  mkdirSync(dir);
  const did = Array.from({ length: 120 }, (_, i) => `- Changed thing number ${i} in a line long enough to add up.`);
  writeFileSync(join(dir, "outcome.md"), ["## Did", ...did, "## Open", "Test on a trackpad."].join("\n"));
  const { outcome } = readBriefLine(dir);
  assert.equal(outcome.did.length, 40);
  assert.deepEqual(outcome.open, ["Test on a trackpad."], "an Open past 8000 characters still counts");
});

test("could not tell is Groq's own line, not any summary that says too short", () => {
  const said = "a narration long enough to place";
  for (const line of ["The transcript is too short to determine a request.", "The transcript is too garbled to determine a coding task."]) {
    assert.ok(COULD_NOT_TELL.test(line), line);
    assert.equal(unplaceable({ narration: said, summaryLine: line }), "the summary could not tell what was asked");
  }
  const real = "Increase the session timeout; it is too short for large uploads.";
  assert.equal(COULD_NOT_TELL.test(real), false);
  assert.equal(unplaceable({ narration: said, summaryLine: real }), null);
});

test("a sibling whose summary could not tell falls back to what was said", () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-context-"));
  const dir = join(root, "20260918-163821");
  mkdirSync(dir);
  writeFileSync(join(dir, "brief.json"), JSON.stringify({ summary: { narration: "Hello, hello, this is my testing second time." } }));
  writeFileSync(join(dir, "review-summary.txt"), "The transcript is too short to determine a request.\n");
  writeFileSync(join(dir, "context.json"), JSON.stringify({ task: "../etc" }));
  const b = readBriefLine(dir);
  assert.equal(b.line, "Hello, hello, this is my testing second time.");
  assert.equal(b.task, null, "a malformed task id is no task");
});
