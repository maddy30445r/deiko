import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  COMMON_LABEL, FIRM_SAME, RRF_K, SEAT_KINDS, SHORTLIST, TASK_ID, TIME_SEATS, bm25, cosine, firm, groupTasks,
  parseOutcome, renderTaskNote, rrf, shortlist, stampTime, taskIdFor, taskLabels, taskState, terms,
  timeWindow, titleFor, tokens, readBoard, readTasks, writeTaskNotes,
} from "../lib/tasks.mjs";

const brief = (id, line, extra = {}) => ({
  id, dir: `/Users/dev/Documents/Deiko/${id}`, line, summaryLine: line, narration: line,
  collection: null, task: null, apps: [], windows: [], screenTerms: [], outcome: null, ...extra,
});

// The three real Sep 18 price-bug briefs, by their Groq summaries.
const price = [
  brief("20260918-155836", "Price display doesn't update after editing – toast shows new value but UI stays old.",
    { apps: ["Chrome"], windows: ["Products — acme-portal"], screenTerms: ["$99", "price", "save"] }),
  brief("20260918-160606", "Fix the UI so that the updated price ($323) shows immediately after saving instead of staying at $99.",
    { task: "t-20260918-155836", screenTerms: ["$99", "$323", "price"] }),
  brief("20260918-162340", "Bug: editing price updates DB but UI still shows old $99; saving again fails to persist.",
    { task: "t-20260918-155836", outcome: parseOutcome("## Did\nSynced the price after save.\n## Decided\nReject negative prices in the form.\n## Open\nThe listing page still caches the old price.\n## Files\nsrc/Price.tsx") }),
];
const chart = [brief("20260918-163139", "They're confused why the week-32 signup chart shows a drop while another chart stays flat.", { apps: ["Chrome"] })];
const sitemap = [brief("20260919-140923", "They want an explanation of the content and what a sitemap XML is.")];

test("ids and times come from stamps", () => {
  assert.equal(taskIdFor("20260918-155836"), "t-20260918-155836");
  assert.ok(TASK_ID.test("t-20260918-155836"));
  assert.equal(TASK_ID.test("t-../etc"), false);
  assert.equal(new Date(stampTime("20260918-155836")).getHours(), 15);
});

test("tokens keep money and drop one-letter noise", () => {
  assert.deepEqual(tokens("The $99 price, a UI!"), ["the", "$99", "price", "ui"]);
});

test("an outcome is read by its four headings; no headings is all Did", () => {
  const o = parseOutcome("## Did\n- one\n## Decided\ntwo\n## Open\nthree\n## Files\n- a.ts\n");
  assert.deepEqual(o, { did: ["one"], decided: ["two"], open: ["three"], files: ["a.ts"] });
  assert.deepEqual(parseOutcome("# Done\nMoved it.\nTested it.").did, ["Moved it.", "Tested it."]);
  assert.deepEqual(parseOutcome("").did, []);
});

test("an outcome's headings are read the ways agents write them", () => {
  const o = parseOutcome([
    "## Changes", "- one",
    "## **Decisions**", "- two",
    "## Next steps", "- three",
    "**Did:**", "- four",
    "Files changed:", "- a.ts",
    "## TODO", "- five",
    "### Remaining", "- six",
    "What I did:", "- seven",
  ].join("\n"));
  assert.deepEqual(o, { did: ["one", "four", "seven"], decided: ["two"], open: ["three", "five", "six"], files: ["a.ts"] });
});

test("an unknown heading's lines are dropped, not added to the section before it", () => {
  const o = parseOutcome("## Open\nTest on a trackpad.\n## Summary\nA long recap.\n## Notes\nMore recap.\n");
  assert.deepEqual(o.open, ["Test on a trackpad."]);
  assert.deepEqual(o.did, []);
  assert.deepEqual(parseOutcome("## Did\nFixed it.\nNotes:\nkept, a plain label that is not a heading").did,
    ["Fixed it.", "Notes:", "kept, a plain label that is not a heading"]);
});

test("a hash with no space is text, and an unknown top heading keeps the section", () => {
  assert.deepEqual(parseOutcome("## Open\n#2 still flaky on CI\n").open, ["#2 still flaky on CI"]);
  assert.deepEqual(parseOutcome("# Outcome\nFixed the thing.\n").did, ["Fixed the thing."]);
  assert.deepEqual(parseOutcome("# Outcome\n## Did\nOne.\n## Open\nTwo.\n"), { did: ["One."], decided: [], open: ["Two."], files: [] });
});

test("a code fence in an outcome is skipped whole, headings inside it included", () => {
  const o = parseOutcome("## Did\nFixed it.\n```md\n## Open\n- not open\n```\n~~~\n## Files\n~~~\n## Open\nReal open.\n");
  assert.deepEqual(o, { did: ["Fixed it."], decided: [], open: ["Real open."], files: [] });
});

test("a title is the summary, never Groq saying it could not tell", () => {
  assert.equal(titleFor({ summaryLine: "Fix the price", narration: "hey so" }), "Fix the price");
  assert.equal(titleFor({ summaryLine: "The transcript is too short to determine a request.", narration: "fix the drag on the board please now" }),
    "fix the drag on the board please now");
  assert.equal(titleFor({ narration: "Thank you.", apps: ["Figma"] }), "Something in Figma");
  assert.equal(titleFor({}), "A brief");
});

test("a title drops its trailing full stop and caps at a word boundary", () => {
  assert.equal(titleFor({ summaryLine: "Fix the price." }), "Fix the price");
  assert.equal(
    titleFor({ summaryLine: "Price display doesn't update after editing – toast shows new value but UI stays old." }),
    "Price display doesn't update after editing – toast shows new value but UI stays…");
});

test("a brief with no task is its own task; members are newest first", () => {
  const groups = groupTasks([...price, ...chart]);
  assert.deepEqual([...groups.keys()].sort(), ["t-20260918-155836", "t-20260918-163139"]);
  assert.deepEqual(groups.get("t-20260918-155836").map((b) => b.id),
    ["20260918-162340", "20260918-160606", "20260918-155836"]);
});

test("where a task stands is the newest outcome's Open, else what was last asked", () => {
  const state = taskState([...price].reverse());
  assert.deepEqual(state.now, ["The listing page still caches the old price."]);
  assert.deepEqual(state.lastDid, ["Synced the price after save."]);
  assert.deepEqual(taskState(chart).now, [`Last asked: ${chart[0].line}`]);
});

test("a newest outcome with nothing open says what was last done, not what was asked", () => {
  const done = brief("20260918-170000", "Fix the price", {
    outcome: parseOutcome("## Did\nSynced the price after save.\nAdded a test.\n## Open\n"),
  });
  const state = taskState([done, ...[...price].reverse()]);
  assert.deepEqual(state.now, ["Last done: Synced the price after save."]);
  assert.deepEqual(state.lastDid, ["Synced the price after save.", "Added a test."]);
});

test("a newer brief with no outcome leads where it stands; an older outcome's Open follows, dated", () => {
  const next = brief("20260919-090000", "Now the listing page shows $99 too.");
  const state = taskState([next, ...[...price].reverse()]);
  assert.deepEqual(state.now, [
    "Last asked: Now the listing page shows $99 too.",
    "Still open from Sep 18: The listing page still caches the old price.",
  ]);
  assert.deepEqual(state.lastDid, ["Synced the price after save."], "what was done is still the latest outcome's");
  const finished = brief("20260918-170000", "x", { outcome: parseOutcome("## Did\nDone it.") });
  assert.deepEqual(taskState([next, finished]).now, ["Last asked: Now the listing page shows $99 too."],
    "an older outcome with nothing open adds nothing");
});

test("a Last asked line that only repeats the title is dropped", () => {
  const [first, second] = price;
  const title = titleFor(first);
  assert.deepEqual(taskState([first], title).now, []);
  assert.deepEqual(taskState([second, first], title).now, [`Last asked: ${second.line}`]);
  assert.deepEqual(taskState([first], "Renamed by hand").now, [`Last asked: ${first.line}`]);
});

// ── The shortlist ───────────────────────────────────────────────────────────

test("the starting values are the ones the owner agreed", () => {
  assert.equal(SHORTLIST, 20);
  assert.equal(TIME_SEATS, 5);
  assert.equal(COMMON_LABEL, 5);
  assert.equal(RRF_K, 60);
  assert.equal(FIRM_SAME, 0.9);
});

test("terms add 3-grams so a speech-to-text slip still meets its word", () => {
  assert.deepEqual(terms("the pricng"), ["the", "pricng", "~pri", "~ric", "~icn", "~cng"]);
  const [pricing, signup] = bm25(terms("the pricng bug"), [terms("pricing page"), terms("signup chart")]);
  assert.ok(pricing > 0);
  assert.equal(signup, 0);
});

test("reciprocal rank fusion blends by position, and an unranked doc adds nothing", () => {
  const fused = rrf([{ scores: [3, 2, null], weight: 1 }, { scores: [0.1, 0.9, 0.5], weight: 1 }], 60);
  assert.ok(Math.abs(fused[0] - (1 / 61 + 1 / 63)) < 1e-12);
  assert.ok(Math.abs(fused[1] - (1 / 62 + 1 / 61)) < 1e-12);
  assert.ok(Math.abs(fused[2] - 1 / 62) < 1e-12);
  assert.deepEqual(rrf([{ scores: [1, null], weight: 2 }], 60), [2 / 61, 0]);
  assert.deepEqual(rrf([{ scores: [1, 1], weight: 1 }], 60), [1 / 61, 1 / 61], "a tie stays a tie");
});

test("time words name a window, English and Hinglish, from the brief's own stamp", () => {
  const stamp = new Date(2026, 8, 25, 10, 0, 0).getTime(); // a Friday
  const day = (d, h = 0) => new Date(2026, 8, d, h).getTime();
  assert.deepEqual(timeWindow("same bug as yesterday", stamp), { from: day(24), to: day(25) });
  assert.deepEqual(timeWindow("kal wala chart", stamp), { from: day(24), to: day(25) });
  assert.deepEqual(timeWindow("parso ka bug", stamp), { from: day(23), to: day(24) });
  assert.deepEqual(timeWindow("this morning", stamp), { from: day(25), to: day(25, 12) });
  assert.deepEqual(timeWindow("aaj ka kaam", stamp), { from: day(25), to: stamp });
  assert.deepEqual(timeWindow("last week", stamp), { from: day(18), to: day(25) });
  assert.deepEqual(timeWindow("pichle hafte wala", stamp), { from: day(18), to: day(25) });
  assert.deepEqual(timeWindow("the thing on Monday", stamp), { from: day(21), to: day(22) });
  assert.deepEqual(timeWindow("friday's bug", stamp), { from: day(18), to: day(19) }, "today is Friday: last Friday");
  assert.deepEqual(timeWindow("yesterday, or maybe Monday", stamp), { from: day(21), to: day(25) });
  assert.equal(timeWindow("fix the signup chart", stamp), null);
  assert.equal(timeWindow("the kalman filter", stamp), null, "whole words only");
});

test("a task is described by its founder, hand placements and sure v3 joins only", () => {
  const T = "t-20260918-100000";
  assert.equal(firm({ id: "20260918-100000", task: T }, T), true, "the founder");
  assert.equal(firm({ id: "20260918-100000", task: null }, T), true, "a founder never moved");
  assert.equal(firm({ id: "20260918-110000", task: T, decidedBy: "you" }, T), true);
  assert.equal(firm({ id: "20260918-120000", task: T, decidedBy: "jev", classifier: "v3.0", confidence: { task: 0.72 } }, T), true,
    "a v3 join, whatever its confidence — JOIN's own thresholds already gated it");
  assert.equal(firm({ id: "20260918-130000", task: T, decidedBy: "jev", classifier: "v3.0", confidence: { gate: 1 } }, T), false,
    "a v3 filing that only asked or started fresh, not a join");
  assert.equal(firm({ id: "20260918-140000", task: T, decidedBy: "jev", confidence: { task: 0.95 } }, T), false, "an old 0.5.0 join has no classifier");
  assert.equal(firm({ id: "20260918-150000", task: T, decidedBy: "local", confidence: { task: null } }, T), false);
});

const noLabels = () => Object.fromEntries(SEAT_KINDS.map((k) => [k, new Set()]));
const t = (id, text, over = {}) => ({ id, text, labels: { ...noLabels(), ...over.labels }, times: over.times ?? [], lastActive: over.lastActive ?? 0, vecs: over.vecs ?? [] });
const idsOf = (n) => Array.from({ length: n }, (_, i) => `t-20260901-10${String(i).padStart(4, "0")}`);

test("a task's labels are its briefs' labels, lower-cased, by kind", () => {
  const labels = taskLabels([{ keys: { pages: ["Signups"], files: ["App.tsx"] } }, { keys: { pages: ["Pricing"] } }, {}]);
  assert.deepEqual([...labels.pages].sort(), ["pricing", "signups"]);
  assert.deepEqual([...labels.files], ["app.tsx"]);
  assert.deepEqual([...labels.tickets], []);
});

test("a shared exact page seats a task however few words it shares", () => {
  const ids = idsOf(25);
  const tasks = ids.map((id, i) => (i === 24 ? t(id, "zzz", { labels: { pages: new Set(["signups"]) } }) : t(id, "price bug listing")));
  const out = shortlist({ query: "price bug listing", queryKeys: { pages: ["Signups"] }, tasks });
  assert.equal(out.length, 20);
  assert.equal(out[0].id, ids[24]);
  assert.equal(out[0].seat, "label");
});

test("a label on more than five tasks seats nobody", () => {
  const ids = idsOf(8);
  const tasks = ids.map((id, i) => (i < 7 ? t(id, `word${i}`, { labels: { files: new Set(["app.tsx"]) } }) : t(id, "chart week")));
  const out = shortlist({ query: "chart week", queryKeys: { files: ["App.tsx"] }, tasks });
  assert.equal(out.some((r) => r.seat === "label"), false);
  assert.equal(out[0].id, ids[7]);
});

test("time words seat at most five tasks, best words first, and the rest compete", () => {
  const ids = idsOf(9);
  const tasks = ids.map((id, i) => (i < 8
    ? t(id, i >= 6 ? "chart" : `alpha${i}`, { times: [150] })
    : t(id, "chart chart", { times: [999] })));
  const out = shortlist({ query: "chart", window: { from: 100, to: 200 }, tasks });
  const timed = out.filter((r) => r.seat === "time");
  assert.equal(timed.length, 5);
  assert.deepEqual(out.slice(0, 2).map((r) => r.id).sort(), [ids[6], ids[7]]);
  assert.equal(out[5].id, ids[8], "the best words outside the window come next");
  assert.equal(out[5].seat, "score");
});

test("recency never outranks words; it only breaks a tie", () => {
  const [old, fresh, a, b] = idsOf(4);
  assert.equal(shortlist({ query: "pricing bug", tasks: [t(old, "pricing page bug", { lastActive: 1 }), t(fresh, "signup chart", { lastActive: 9e12 })] })[0].id, old);
  assert.equal(shortlist({ query: "pricing bug", tasks: [t(a, "pricing bug", { lastActive: 1 }), t(b, "pricing bug", { lastActive: 2 })] })[0].id, b);
});

test("twenty seats, or every task on a small board", () => {
  assert.equal(shortlist({ query: "x", tasks: idsOf(25).map((id) => t(id, "x")) }).length, 20);
  assert.equal(shortlist({ query: "x", tasks: idsOf(12).map((id) => t(id, "x")) }).length, 12);
  assert.deepEqual(shortlist({ query: "x", tasks: [] }), []);
});

test("meaning finds a paraphrase words miss, from the task's closest brief", () => {
  const [cards, sitemap] = idsOf(2);
  const tasks = [
    t(cards, "reorder cards", { vecs: [Float32Array.from([0, 1]), Float32Array.from([0.9, 0.436])] }),
    t(sitemap, "sitemap xml", { vecs: [Float32Array.from([0, 1])], lastActive: 2 }),
  ];
  const blended = shortlist({ query: "the drag thing", queryVec: Float32Array.from([1, 0]), tasks });
  assert.equal(blended[0].id, cards);
  assert.ok(Math.abs(blended[0].meaning - 0.9) < 1e-6, "the closest brief, not the average");
  assert.equal(shortlist({ query: "the drag thing", tasks })[0].id, sitemap, "without vectors: a tie, broken by recency");
  assert.equal(cosine(Float32Array.from([0.6, 0.8]), Float32Array.from([0.6, 0.8])).toFixed(6), "1.000000");
});

test("the note is deterministic, capped and names two files, never a folder", () => {
  const members = [...price].reverse().map((b) => ({ ...b, task: "t-20260918-155836" }));
  const note = renderTaskNote({ id: "t-20260918-155836", title: "Price display doesn't update", collection: "acme-portal", briefs: members });
  assert.equal(note, renderTaskNote({ id: "t-20260918-155836", title: "Price display doesn't update", collection: "acme-portal", briefs: members }));
  assert.match(note, /^# Price display doesn't update\nacme-portal · 3 briefs · Sep 18 · updated from 20260918-162340\n/);
  assert.match(note, /\nCompiled by Deiko from each brief's outcome\.md — edit those, not this file\.\n\n## Now\n/);
  assert.match(note, /## Now\nThe listing page still caches the old price\.\n/);
  assert.match(note, /## Decided\n- Sep 18: Reject negative prices in the form\.\n/);
  assert.match(note, /\/20260918-162340\/prompt\.txt · \/Users\/dev\/Documents\/Deiko\/20260918-162340\/outcome\.md/);
  assert.equal(/20260918-\d{6}(?!\/(prompt\.txt|outcome\.md))\b/.test(note.split("## Briefs")[1].replace(/updated from \S+/, "")), false);
  const fifty = Array.from({ length: 60 }, (_, i) => brief(`202609${String(10 + (i % 18)).padStart(2, "0")}-${String(100000 + i)}`, `brief ${i}`));
  assert.match(renderTaskNote({ id: "t-x", title: "big", briefs: fifty }), /- … and 10 earlier\n$/);
});

test("a note whose only Now line would repeat its title has no Now section", () => {
  const [first, second] = price;
  const note = renderTaskNote({ id: "t-20260918-155836", title: titleFor(second), briefs: [second, first] });
  assert.equal(note.includes("## Now"), false);
  assert.match(note, /\n\n## Briefs\n/);
});

test("app names and collections are redacted when they contain secrets", () => {
  const withSecret = [brief("20260918-155836", "A brief", {
    apps: ["AKIAIOSFODNN7EXAMPLE"], collection: "AKIAIOSFODNN7EXAMPLE",
  })];
  const note = renderTaskNote({ id: "t-x", title: "Title", collection: "AKIAIOSFODNN7EXAMPLE", briefs: withSecret });
  assert.equal(note.includes("AKIAIOSFODNN7EXAMPLE"), false);
  assert.match(note, /REDACTED-AWS-KEY-ID/);
});

test("odds and ends are not on the board tasks are read from, so never in a task or its note", () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-tasks-"));
  for (const [id, context] of [["20260918-155836", null], ["20260918-160606", { pile: "odds", decidedBy: "local" }]]) {
    mkdirSync(join(root, id));
    writeFileSync(join(root, id, "brief.json"), JSON.stringify({ summary: { narration: "the price still shows 99 after I save it" } }));
    if (context) writeFileSync(join(root, id, "context.json"), JSON.stringify(context));
  }
  assert.deepEqual(readBoard(root).map((b) => b.id), ["20260918-155836"]);
});

test("notes are written for tasks with two briefs or more, titled from tasks.json", () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-tasks-"));
  const put = (id, narration, task) => {
    mkdirSync(join(root, id));
    writeFileSync(join(root, id, "brief.json"), JSON.stringify({ summary: { narration } }));
    if (task) writeFileSync(join(root, id, "context.json"), JSON.stringify({ task }));
  };
  put("20260918-155836", "the price still shows 99 after I save it");
  put("20260918-160606", "same price bug, it shows 99 again", "t-20260918-155836");
  put("20260919-140923", "what is this sitemap xml thing");
  writeFileSync(join(root, "tasks.json"), JSON.stringify([{ id: "t-20260918-155836", title: "The price bug" }]));
  assert.equal(readTasks(root).get("t-20260918-155836"), "The price bug");
  assert.equal(writeTaskNotes(root), 1);
  const note = readFileSync(join(root, "tasks", "t-20260918-155836.md"), "utf8");
  assert.match(note, /^# The price bug\nUnsorted · 2 briefs/);
  assert.equal(existsSync(join(root, "tasks", "t-20260919-140923.md")), false, "a single brief gets no note");
  assert.equal(writeTaskNotes(root), 0, "an unchanged note is not rewritten");
});
