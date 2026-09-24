import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  ASK, CLASSIFIER, COULD_NOT_TELL, FLOORS, GATE, JOIN, RELATIONS, TIERS, briefDate, decide, level,
  projectFromKeys, readBriefLine, slug, unplaceable, wantsQuickHint, yes,
} from "../lib/context.mjs";
import { EMPTY_KEYS } from "../lib/labels.mjs";
import { stampTime } from "../lib/tasks.mjs";

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

const [A, B, C] = ["t-20260918-100000", "t-20260918-110000", "t-20260918-120000"];
const NOW = stampTime("20260920-100000");
const OWN = "t-20260920-100000";
const base = { shortlist: [A, B, C], sessionId: "20260920-100000", title: "Fix the signup chart", now: NOW };
const r1 = (same = {}, gate = 0.95) => ({
  is_work_brief: { noul: gate },
  ...Object.fromEntries(Object.entries(same).map(([id, p]) => [`same_${id}`, { noul: p }])),
});
const r2 = (id, p, relation = "same") => ({
  [id]: { same_task: { noul: p }, relation: { score: RELATIONS.indexOf(relation), probabilities: RELATIONS.map((r) => (r === relation ? 0.9 : 0.05)) } },
});
const keys = (over = {}) => ({ ...EMPTY_KEYS, ...over });
const tk = (over = {}) => ({ pages: [], files: [], tickets: [], ...over });

test("the values are the ones calibrated on the owner's board", () => {
  assert.equal(CLASSIFIER, "v3.0");
  assert.equal(GATE, 0.5);
  assert.deepEqual(JOIN, { first: 0.6, second: 0.4, gap: 0.2, recent: 0.5, recentMs: 30 * 60e3 });
  assert.equal(ASK, 0.35);
  assert.equal(FLOORS.collection, 0.6);
});

test("yes reads a noul; level reads a score in both shapes", () => {
  assert.equal(yes({ noul: 0.7 }), 0.7);
  assert.equal(yes(undefined), 0);
  assert.equal(yes({ noul: "x" }), 0);
  assert.equal(level({ probabilities: [0.1, 0.7, 0.2] }), 1);
  assert.equal(level({ probabilities: { 0: 0.1, 1: 0.2, 2: 0.7 } }), 2);
  assert.equal(level({ score: 1.4 }), 1);
  assert.equal(level(undefined), null);
});

test("not a real request goes to odds and ends, whatever else was answered", () => {
  const out = decide({ ...base, answers: r1({ [A]: 0.99 }, 0.3), second: r2(A, 0.99) });
  assert.equal(out.pile, "odds");
  assert.equal(out.task, null);
  assert.equal(out.newTask, null);
  assert.equal(out.why, "odds");
  assert.equal(out.jev.gate, 0.3);
});

test("a missing gate reads as a real request", () => {
  assert.equal(decide({ ...base, answers: {} }).pile, null);
});

test("a join needs the second look to say 'same', round one ≥ 0.6 and 0.2 ahead", () => {
  // The shape measured on real joins: round one 0.62–0.82, the pairwise look
  // shy (0.43–0.88) but calling it the same work.
  const out = decide({ ...base, answers: r1({ [A]: 0.72, [B]: 0.4 }), second: { ...r2(A, 0.46), ...r2(B, 0.6, "related") } });
  assert.equal(out.task, A);
  assert.equal(out.newTask, null);
  assert.equal(out.why, "join");
  assert.equal(out.confidence.task, 0.72);
  assert.equal(out.jev.rank, 1);
  assert.deepEqual(out.jev.second[A], { same: 0.46, relation: "same" });
  assert.equal(out.candidates, undefined);
  assert.equal(decide({ ...base, answers: r1({ [A]: 0.72 }), second: r2(A, 0.3) }).why, "ask", "a doubting second look asks");
  assert.equal(decide({ ...base, answers: r1({ [A]: 0.55 }), second: r2(A, 0.9) }).why, "ask", "round one not clearly for it asks");
  assert.equal(decide({ ...base, answers: r1({ [A]: 0.7, [B]: 0.6 }), second: r2(A, 0.9) }).why, "ask", "not clearly ahead asks");
});

test("round one alone never joins; it asks", () => {
  const out = decide({ ...base, answers: r1({ [A]: 0.99 }) });
  assert.equal(out.task, OWN);
  assert.deepEqual(out.newTask, { id: OWN, title: "Fix the signup chart" });
  assert.deepEqual(out.candidates, [A]);
  assert.equal(out.why, "ask");
});

test("two that both look right ask which one", () => {
  const out = decide({ ...base, answers: r1({ [A]: 0.9, [B]: 0.9 }), second: { ...r2(A, 0.95), ...r2(B, 0.92) } });
  assert.equal(out.task, OWN);
  assert.deepEqual(out.candidates, [A, B]);
  assert.equal(out.why, "ask");
});

test("between 0.35 and the join line asks; below it, or a clear 'different', is new", () => {
  assert.deepEqual(decide({ ...base, answers: r1({ [A]: 0.5 }), second: r2(A, 0.8) }).candidates, [A]);
  const different = decide({ ...base, answers: r1({ [A]: 0.5 }), second: r2(A, 0.34, "different") });
  assert.equal(different.why, "new");
  assert.equal(different.candidates, undefined);
  assert.equal(decide({ ...base, answers: r1({ [A]: 0.2 }) }).why, "new");
});

test("recent work on the same page or file joins from 0.5 in round one; older work does not", () => {
  const args = {
    ...base, answers: r1({ [A]: 0.55 }), second: r2(A, 0.8),
    keys: keys({ pages: ["Pricing"] }), taskKeys: { [A]: tk({ pages: ["pricing"] }) },
  };
  assert.equal(decide({ ...args, newest: { [A]: NOW - 8 * 60e3 } }).why, "join-recent");
  assert.equal(decide({ ...args, newest: { [A]: NOW - 31 * 60e3 } }).why, "ask");
  assert.equal(decide({ ...args, keys: keys({ files: ["Price.tsx"] }), taskKeys: { [A]: tk({ files: ["Price.tsx"] }) }, newest: { [A]: NOW - 8 * 60e3 } }).why, "join-recent");
  assert.equal(decide({ ...args, keys: keys(), taskKeys: {}, newest: { [A]: NOW - 8 * 60e3 } }).why, "ask", "recency alone does nothing");
});

test("a join on a different page asks instead", () => {
  const out = decide({
    ...base, answers: r1({ [A]: 0.95 }), second: r2(A, 0.97),
    keys: keys({ pages: ["Signups"] }), taskKeys: { [A]: tk({ pages: ["Pricing"] }) },
  });
  assert.equal(out.why, "ask-page");
  assert.equal(out.task, OWN);
  assert.deepEqual(out.candidates, [A]);
});

test("a different ticket never joins and is never offered", () => {
  const out = decide({
    ...base, answers: r1({ [A]: 0.95 }), second: r2(A, 0.97),
    keys: keys({ tickets: ["ENG-2"] }), taskKeys: { [A]: tk({ tickets: ["ENG-1"] }) },
  });
  assert.equal(out.why, "new");
  assert.equal(out.candidates, undefined);
});

test("related but separate starts its own task with a link, not a merge", () => {
  const out = decide({ ...base, answers: r1({ [A]: 0.6 }), second: r2(A, 0.5, "related") });
  assert.equal(out.why, "related");
  assert.equal(out.task, OWN);
  assert.equal(out.related, A);
  assert.equal(out.candidates, undefined);
});

test("a project comes from Jev when it is sure, else from a join, else from the labels", () => {
  const collections = [{ id: "deiko", name: "Deiko", hint: "" }, { id: "build", name: "build", hint: "" }];
  assert.equal(decide({ ...base, collections, answers: { collection: { choice: "deiko", confidence: 0.6 } } }).collection, "deiko");
  const joined = decide({
    ...base, collections, answers: { ...r1({ [A]: 0.9 }), collection: { choice: "deiko", confidence: 0.59 } },
    second: r2(A, 0.95), taskCollections: { [A]: "build" },
  });
  assert.equal(joined.collection, "build");
  const fresh = decide({ ...base, collections: [], keys: keys({ sites: ["build"] }), apps: ["Google Chrome"] });
  assert.deepEqual(fresh.newCollection, { id: "build", name: "build" });
  assert.equal(fresh.collection, "build");
  assert.equal(decide({ ...base, collections, keys: keys({ repo: ["DEIKO"], sites: ["build"] }) }).collection, "deiko", "code project first, matched by name");
  assert.equal(decide({ ...base, collections, answers: { collection: { choice: "made-up", confidence: 0.99 } } }).collection, null);
});

test("the strongest label names the project: code project, website, document, app", () => {
  assert.equal(projectFromKeys({ keys: keys({ repo: ["acme-portal"], sites: ["build"] }) }), "acme-portal");
  assert.equal(projectFromKeys({ keys: keys({ sites: ["build"], docs: ["Card Library"] }) }), "build");
  assert.equal(projectFromKeys({ keys: keys({ docs: ["Card Library"] }), apps: ["Figma"] }), "Card Library");
  assert.equal(projectFromKeys({ keys: keys(), apps: ["Google Chrome", "Figma"] }), "Figma");
  assert.equal(projectFromKeys({ keys: keys(), apps: ["Google Chrome", "Code", "Finder"] }), null);
});

test("every probability is logged, with the shortlist in the order it was sent", () => {
  const out = decide({ ...base, answers: { ...r1({ [A]: 0.2, [B]: 0.4 }), collection: { choice: "none", confidence: 0.8 } }, second: r2(B, 0.3, "different") });
  assert.deepEqual(out.jev.same, { [A]: 0.2, [B]: 0.4, [C]: 0 });
  assert.deepEqual(out.jev.second, { [B]: { same: 0.3, relation: "different" } });
  assert.deepEqual(out.jev.collection, { choice: "none", confidence: 0.8 });
  assert.deepEqual(out.jev.shortlist, [A, B, C]);
  assert.equal(out.jev.rank, null);
  assert.equal(out.jev.why, "new");
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
  const out = decide({});
  assert.equal(out.pile, null);
  assert.equal(out.task, null);
  assert.equal(out.collection, null);
  assert.equal(out.why, "new");
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
    collection: "deiko", task: "t-20260915-100000", odds: false,
    decidedBy: null, classifier: null, confidence: {},
    apps: ["Deiko"], windows: ["Orb.swift — Deiko"], screenTerms: ["drag"], repoHints: ["Deiko"],
    keys: { ...EMPTY_KEYS, repo: ["Deiko"] },
    outcome: { did: ["Moved the threshold."], decided: [], open: ["Test on a trackpad."], files: [] },
  });
});

test("a brief's labels are read back, and an old brief's repo hints stand in for them", () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-keys-"));
  const make = (id, summary) => {
    mkdirSync(join(root, id));
    writeFileSync(join(root, id, "brief.json"), JSON.stringify({ summary }));
    return join(root, id);
  };
  const fresh = readBriefLine(make("20260918-100000", { narration: "x", keys: { pages: ["Signups"], repo: ["build"] } }));
  assert.deepEqual(fresh.keys.pages, ["Signups"]);
  assert.deepEqual(fresh.keys.tickets, []);
  const old = readBriefLine(make("20260918-110000", { narration: "y", repoHints: ["acme-portal"] }));
  assert.deepEqual(old.keys.repo, ["acme-portal"]);
  assert.deepEqual(old.keys.pages, []);
});

test("an old brief's repo-hint fallback is redacted too, not just a fresh one", () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-keys-"));
  const dir = join(root, "20260918-120000");
  mkdirSync(dir);
  // A pre-labels brief with an AWS-key-shaped repo hint (however it got
  // there) and one with a space, which is never a repo name at all.
  writeFileSync(join(dir, "brief.json"), JSON.stringify({ summary: { repoHints: ["AKIAIOSFODNN7EXAMPLE", "acme portal"] } }));
  const { keys } = readBriefLine(dir);
  assert.deepEqual(keys.repo, ["<REDACTED-AWS-KEY-ID>"], "redacted, not the raw hint, and the spaced one is dropped");
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
  const alsoReal = "The transcript is too short after trimming; fix the truncation";
  assert.equal(COULD_NOT_TELL.test(alsoReal), false);
  assert.equal(unplaceable({ narration: said, summaryLine: alsoReal }), null);
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
