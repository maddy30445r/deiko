import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  SHORTLIST, TASK_ID, groupTasks, parseOutcome, renderTaskNote, scoreTasks,
  stampTime, taskIdFor, taskState, taskText, titleFor, tokens,
  readTasks, writeTaskNotes,
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

const asTasks = (groups, lastActive) => [...groups].map(([id, bs]) => ({
  id, text: taskText(bs.at(-1).line, bs), lastActive: lastActive ?? stampTime(bs[0].id),
}));

test("the price bug is shortlisted first for another brief about it", () => {
  const tasks = asTasks(groupTasks([...price, ...chart, ...sitemap]));
  const top = scoreTasks({ query: "same price bug again, it still shows $99 after save", tasks, now: stampTime("20260920-100000") });
  assert.equal(top[0].id, "t-20260918-155836");
});

test("recency and repo add to a match; they do not replace one", () => {
  const now = stampTime("20260920-100000");
  const tasks = [
    { id: "t-20260918-155836", text: taskText("price", price), lastActive: stampTime("20260918-162340"), repoHints: ["acme-portal"] },
    { id: "t-20260920-095000", text: "the week 32 signup chart", lastActive: now - 10 * 60e3 },
  ];
  const top = scoreTasks({ query: "the price toast still shows $99 after save", tasks, now });
  assert.equal(top[0].id, "t-20260918-155836");
  const repo = scoreTasks({ query: "unrelated words", tasks, now: now + 3 * 86400e3, repoHints: ["Acme-Portal"] });
  assert.equal(repo.find((t) => t.id === "t-20260918-155836").sameRepo, true);
});

test("same repo is an exact repo hint, never a word somewhere in the task", () => {
  const tasks = [{ id: "t-20260918-155836", text: "Deiko app window deiko-site", lastActive: 0, repoHints: ["deiko-site"] }];
  for (const hint of ["Deiko", "app", "site"]) {
    assert.equal(scoreTasks({ query: "x", tasks, repoHints: [hint], now: 0 })[0].sameRepo, false, hint);
  }
  assert.equal(scoreTasks({ query: "x", tasks, repoHints: ["Deiko-Site"], now: 0 })[0].sameRepo, true);
});

test("the shortlist is capped", () => {
  const many = Array.from({ length: 20 }, (_, i) => ({ id: `t-202609${String(i + 10)}-100000`, text: "price", lastActive: 0 }));
  assert.equal(scoreTasks({ query: "price", tasks: many, now: 0 }).length, SHORTLIST);
});

test("the two most recently active tasks keep a place on the shortlist whatever they score", () => {
  const now = stampTime("20260920-100000");
  const matching = Array.from({ length: 10 }, (_, i) => ({
    id: `t-202609${String(i + 1).padStart(2, "0")}-100000`, text: "the price bug", lastActive: now - 10 * 86400e3,
  }));
  const recent = [
    { id: "t-20260919-080000", text: "signup chart", lastActive: now - 26 * 3600e3 },
    { id: "t-20260919-090000", text: "sitemap xml", lastActive: now - 25 * 3600e3 },
  ];
  const top = scoreTasks({ query: "the price bug", tasks: [...recent, ...matching], now });
  assert.equal(top.length, SHORTLIST);
  assert.deepEqual(top.slice(0, 6).map((t) => t.id), matching.slice(0, 6).map((t) => t.id), "the best six by score stay");
  assert.deepEqual(top.slice(6).map((t) => t.id).sort(), recent.map((t) => t.id), "the lowest two give way");
  const scored = scoreTasks({ query: "signup chart sitemap xml", tasks: [...recent, ...matching], now });
  assert.deepEqual(scored.slice(0, 2).map((t) => t.id).sort(), recent.map((t) => t.id));
  assert.deepEqual(scored.slice(2).map((t) => t.id), matching.slice(0, 6).map((t) => t.id), "already in, they take no extra slot");
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
