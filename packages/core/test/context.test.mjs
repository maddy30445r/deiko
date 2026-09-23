import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  CANDIDATE_LIMIT, FLOORS, RELATED_LIMIT, TIERS,
  briefDate, decide, pickCandidates, readBriefLine, slug, wantsQuickHint,
} from "../lib/context.mjs";

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

// ── Candidates ──────────────────────────────────────────────────────────────

const session = (id, narration, extra = {}) => ({ id, narration, collection: null, outcome: null, ...extra });

test("candidates are newest first, the current session left out, short narrations skipped", () => {
  const picked = pickCandidates([
    session("20260101-100000", "the oldest brief on the board"),
    session("20260301-100000", "the newest brief on the board"),
    session("20260201-100000", "Thanks."),
    session("20260215-100000", "the current one, which must not see itself"),
    { id: "personas", narration: "not a session at all" },
  ], { exclude: "20260215-100000" });
  assert.deepEqual(picked.map((c) => c.id), ["20260301-100000", "20260101-100000"]);
});

test("candidates carry the collection NAME, a redacted line and the outcome", () => {
  const [c] = pickCandidates(
    [session("20260301-100000", "the newest brief on the board", { collection: "deiko", outcome: "Fixed the drag.\nAdded a test." })],
    { collections: [{ id: "deiko", name: "Deiko" }] },
  );
  assert.equal(c.collection, "Deiko");
  assert.equal(c.date, briefDate("20260301-100000"));
  assert.equal(c.line, "the newest brief on the board");
  assert.equal(c.outcome, "Fixed the drag. Added a test.");
});

test("the candidate window is capped", () => {
  const many = Array.from({ length: CANDIDATE_LIMIT + 40 }, (_, i) =>
    session(`2026${String(100 + i).slice(1)}01-100000`.slice(0, 15), `brief number ${i} on the board`));
  // Stamps above are synthetic and not all valid dates; only their shape matters here.
  const picked = pickCandidates(many.filter((s) => /^\d{8}-\d{6}$/.test(s.id)));
  assert.ok(picked.length <= CANDIDATE_LIMIT);
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

test("continues needs its floor and a real stamp", () => {
  const yes = decide({ answers: { continues: { choice: "20260918-155717", confidence: 0.7 } } });
  assert.equal(yes.continues, "20260918-155717");
  const no = decide({ answers: { continues: { choice: "20260918-155717", confidence: 0.69 } } });
  assert.equal(no.continues, null);
  const none = decide({ answers: { continues: { choice: "none", confidence: 0.99 } } });
  assert.equal(none.continues, null);
  const bogus = decide({ answers: { continues: { choice: "../etc", confidence: 0.99 } } });
  assert.equal(bogus.continues, null);
});

test("related keeps the confident ones, ranked, capped, and never the continued brief", () => {
  const answers = { continues: { choice: "20260918-155717", confidence: 0.9 } };
  for (let i = 0; i < 10; i += 1) {
    answers[`rel_202609${String(10 + i)}-100000`] = { noul: 0.5 + i * 0.05 };
  }
  answers["rel_20260918-155717"] = { noul: 0.99 };
  answers["rel_../etc"] = { noul: 0.99 };
  const out = decide({ answers });
  assert.equal(out.related.length, RELATED_LIMIT);
  assert.ok(!out.related.includes("20260918-155717"));
  assert.ok(out.related.every((id) => /^\d{8}-\d{6}$/.test(id)));
  assert.ok(out.related.every((id) => answers[`rel_${id}`].noul >= FLOORS.related));
  // Highest probability first.
  assert.equal(out.related[0], "20260919-100000");
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

test("a missing or partial answer is a quiet no", () => {
  assert.deepEqual(decide({}), {
    collection: null, continues: null, related: [], tier: null, confidence: {}, newCollection: null,
  });
  assert.equal(decide({ answers: { collection: {}, continues: {}, tier: {} } }).tier, null);
});

test("the cost hint needs the toggle, a quick tier and a confident one", () => {
  assert.equal(wantsQuickHint({ tier: "quick", confidence: { tier: 0.8 } }, true), true);
  assert.equal(wantsQuickHint({ tier: "quick", confidence: { tier: 0.79 } }, true), false);
  assert.equal(wantsQuickHint({ tier: "medium", confidence: { tier: 0.99 } }, true), false);
  assert.equal(wantsQuickHint({ tier: "quick", confidence: { tier: 0.99 } }, false), false);
  assert.equal(wantsQuickHint(null, true), false);
});

// ── Reading a sibling ───────────────────────────────────────────────────────

test("a sibling session is read as its narration, collection and first three outcome lines", () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-context-"));
  const dir = join(root, "20260918-155717");
  mkdirSync(dir);
  writeFileSync(join(dir, "brief.json"), JSON.stringify({ summary: { narration: "fix the drag on the board" } }));
  writeFileSync(join(dir, "context.json"), JSON.stringify({ collection: "deiko" }));
  writeFileSync(join(dir, "outcome.md"), "# Done\n\nMoved the drag threshold.\nAdded a test.\nUpdated the doc.\nA fourth line nobody reads.\n");
  assert.deepEqual(readBriefLine(dir), {
    id: "20260918-155717",
    narration: "fix the drag on the board",
    collection: "deiko",
    outcome: "Done Moved the drag threshold. Added a test.",
  });
  const bare = join(root, "20260101-000000");
  mkdirSync(bare);
  assert.deepEqual(readBriefLine(bare), { id: "20260101-000000", narration: null, collection: null, outcome: null });
});
