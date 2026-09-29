import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, statSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { draftLabels, expectations, formatReport, outcomeOf, rankOf, readLabels, recall, tally, correctionLabels } from "../lib/eval.mjs";

const run = promisify(execFile);
const scripts = fileURLToPath(new URL("..", import.meta.url));

test("a slug's first brief is new, later ones join its task; odds stay odds and skip is dropped", () => {
  const exp = expectations({
    "20260918-100000": "price", "20260918-110000": "odds", "20260918-120000": "price",
    "20260918-090000": "chart", "20260918-130000": "skip",
  });
  assert.deepEqual([...exp.keys()], ["20260918-090000", "20260918-100000", "20260918-110000", "20260918-120000"]);
  assert.deepEqual(exp.get("20260918-090000"), { want: "new", task: "t-20260918-090000", slug: "chart" });
  assert.deepEqual(exp.get("20260918-100000"), { want: "new", task: "t-20260918-100000", slug: "price" });
  assert.deepEqual(exp.get("20260918-120000"), { want: "join", task: "t-20260918-100000", slug: "price" });
  assert.deepEqual(exp.get("20260918-110000"), { want: "odds", task: null, slug: null });
});

test("a group whose first brief is missing starts with its next brief, not a join to nowhere", () => {
  const exp = expectations(
    { "20260918-100000": "price", "20260918-120000": "price", "20260918-130000": "price" },
    (s) => s !== "20260918-100000",
  );
  assert.deepEqual([...exp.keys()], ["20260918-120000", "20260918-130000"]);
  assert.deepEqual(exp.get("20260918-120000"), { want: "new", task: "t-20260918-120000", slug: "price" });
  assert.deepEqual(exp.get("20260918-130000"), { want: "join", task: "t-20260918-120000", slug: "price" });
});

test("an answer key with a bad shape or an unknown group is refused by name", () => {
  const dir = mkdtempSync(join(tmpdir(), "deiko-eval-"));
  const write = (labels) => { writeFileSync(join(dir, "l.json"), JSON.stringify(labels)); return join(dir, "l.json"); };
  assert.throws(() => readLabels(write({ version: 2, groups: {}, briefs: {} })), /l\.json/);
  assert.throws(() => readLabels(write({ version: 1, groups: {}, briefs: { "20260918-100000": "nope" } })), /unknown group "nope"/);
  assert.throws(() => readLabels(write({ version: 1, groups: {}, briefs: { "not-a-stamp": "odds" } })), /not a brief stamp/);
  assert.deepEqual(readLabels(write({ version: 1, groups: { a: "A" }, briefs: { "20260918-100000": "a" } })).groups, { a: "A" });
});

test("an outcome reads a decision and a local context alike", () => {
  const s = "20260920-100000";
  assert.deepEqual(outcomeOf({ pile: "odds", decidedBy: "local" }, s), { got: "odds", task: null, candidates: [] });
  assert.deepEqual(outcomeOf({ task: "t-20260918-100000", newTask: null }, s), { got: "join", task: "t-20260918-100000", candidates: [] });
  assert.deepEqual(outcomeOf({ task: `t-${s}`, newTask: { id: `t-${s}` } }, s), { got: "new", task: `t-${s}`, candidates: [] });
  assert.deepEqual(outcomeOf({ task: `t-${s}`, newTask: { id: `t-${s}` }, candidates: ["t-20260918-100000"] }, s),
    { got: "ask", task: `t-${s}`, candidates: ["t-20260918-100000"] });
  assert.equal(rankOf(["t-a", "t-b"], "t-b"), 2);
  assert.equal(rankOf(["t-a"], "t-b"), null);
});

const rows = [
  { stamp: "20260918-090000", exp: { want: "new", task: "t-20260918-090000" }, ranks: { words: null }, out: { got: "new", task: "t-20260918-090000", candidates: [] } },
  { stamp: "20260918-100000", exp: { want: "join", task: "t-20260918-090000" }, ranks: { words: 1 }, out: { got: "join", task: "t-20260918-090000", candidates: [] } },
  { stamp: "20260918-110000", exp: { want: "join", task: "t-20260918-090000" }, ranks: { words: 7 }, out: { got: "ask", task: "t-20260918-110000", candidates: ["t-20260918-090000"] } },
  { stamp: "20260918-120000", exp: { want: "odds", task: null }, ranks: { words: null }, out: { got: "new", task: "t-20260918-120000", candidates: [] } },
];

test("the tally counts right answers per kind and the ask rate over real briefs", () => {
  const t = tally(rows);
  assert.equal(t.n, 4);
  assert.equal(t.correct, 2);
  assert.deepEqual(t.byWant, { odds: [0, 1], new: [1, 1], join: [1, 2] });
  assert.deepEqual(t.wrong, [
    { stamp: "20260918-110000", want: "join t-20260918-090000", got: "ask t-20260918-090000" },
    { stamp: "20260918-120000", want: "odds", got: "new" },
  ]);
  assert.equal(t.asks, 1);
  assert.equal(t.real, 3);
  assert.deepEqual(recall(rows, "words", 5), [1, 2]);
  assert.deepEqual(recall(rows, "words", 20), [2, 2]);
});

test("the report prints recall, every wrong brief, accuracy and the ask rate", () => {
  assert.equal(formatReport({ rows, shortlistOnly: false }), [
    "shortlist recall (briefs that should join)",
    "  words      top 5: 1/2 (50%)   top 20: 2/2 (100%)",
    "✗ 20260918-110000  want join t-20260918-090000     got ask t-20260918-090000",
    "✗ 20260918-120000  want odds                       got new",
    "accuracy 2/4 (50%) · odds 0/1 · new 1/1 · join 1/2",
    "ask rate 1/3 (33%)",
  ].join("\n"));
  assert.equal(formatReport({ rows, shortlistOnly: true }).split("\n").length, 2);
});

test("a draft answer key follows the board's current placement", () => {
  const draft = draftLabels([
    { id: "20260918-100000", task: null, odds: false, narration: "a", line: "Fix the price" },
    { id: "20260918-110000", task: "t-20260918-100000", odds: false, narration: "b", line: "Again" },
    { id: "20260918-120000", task: null, odds: true, narration: "c", line: "Hello" },
    { id: "20260918-130000", task: null, odds: false, narration: null, line: "" },
  ]);
  assert.deepEqual(draft, {
    version: 1,
    groups: { g1: "Fix the price" },
    briefs: { "20260918-100000": "g1", "20260918-110000": "g1", "20260918-120000": "odds", "20260918-130000": "skip" },
  });
});

// ── The runner, end to end, over a tiny board it must not touch ──

function fixtureBoard() {
  const board = mkdtempSync(join(tmpdir(), "deiko-eval-board-"));
  const brief = (id, narration, summary) => {
    mkdirSync(join(board, id));
    writeFileSync(join(board, id, "brief.json"), JSON.stringify({ summary: { narration, apps: [], windows: [], repoHints: [], screenTerms: [] } }));
    writeFileSync(join(board, id, "review-summary.txt"), `${summary}\n`);
  };
  brief("20260918-090000", "the price still shows 99 after I save", "Fix the price display after saving.");
  brief("20260918-100000", "why does the signup chart drop in week 32", "Explain the week-32 signup drop.");
  brief("20260918-110000", "the price bug is back on the listing page", "The listing page shows the old price.");
  brief("20260918-120000", "testing testing can you hear me", "The transcript is too short to determine a request.");
  const labels = join(mkdtempSync(join(tmpdir(), "deiko-eval-labels-")), "labels.json");
  writeFileSync(labels, JSON.stringify({
    version: 1, groups: { price: "Price display", chart: "Signup chart" },
    briefs: { "20260918-090000": "price", "20260918-100000": "chart", "20260918-110000": "price", "20260918-120000": "odds" },
  }));
  return { board, labels };
}

function snapshot(dir) {
  const out = [];
  const walk = (d) => {
    for (const n of readdirSync(d).sort()) {
      const p = join(d, n);
      const s = statSync(p);
      if (s.isDirectory()) walk(p); else out.push(`${p} ${s.size} ${s.mtimeMs}`);
    }
  };
  walk(dir);
  return out;
}

const cleanEnv = (extra = {}) => ({
  ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("DEIKO_"))),
  DEIKO_MEANING_MODEL: "off",
  ...extra,
});
const evalFiling = (args, env) => run(process.execPath, [join(scripts, "filing.mjs"), ...args], { timeout: 20_000, env: cleanEnv(env) });

test("shortlist-only needs no network and writes nothing under the board", async () => {
  const { board, labels } = fixtureBoard();
  const before = snapshot(board);
  const { stdout } = await evalFiling(["--shortlist-only", "--board", board, "--labels", labels]);
  assert.match(stdout, /words\s+top 5: 1\/1 \(100%\)\s+top 20: 1\/1 \(100%\)/);
  assert.doesNotMatch(stdout, /accuracy/);
  assert.deepEqual(snapshot(board), before);
});

test("full mode asks the relay through classify's own request code, once per placeable brief", async () => {
  const { board, labels } = fixtureBoard();
  const before = snapshot(board);
  const bodies = [];
  const server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => { raw += c; });
    req.on("end", () => {
      bodies.push({ url: req.url, body: JSON.parse(raw) });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ model: "stub", answers: {} }));
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  server.unref();
  const { stdout } = await evalFiling(["--board", board, "--labels", labels, "--relay", `http://127.0.0.1:${server.address().port}`]);
  server.close();
  assert.equal(bodies.length, 3, "the mic test is decided here and sends nothing");
  assert.ok(bodies.every((b) => b.url === "/v1/classify"));
  assert.equal(bodies[2].body.narration, "the price bug is back on the listing page");
  assert.match(stdout, /^accuracy \d+\/4 \(\d+%\) · odds 1\/1 · /m);
  assert.match(stdout, /^ask rate \d+\/3 \(\d+%\)$/m);
  assert.deepEqual(snapshot(board), before);
});

test("--draft prints a starting answer key and writes nothing", async () => {
  const { board } = fixtureBoard();
  const before = snapshot(board);
  const { stdout } = await evalFiling(["--draft", "--board", board]);
  const draft = JSON.parse(stdout);
  assert.equal(draft.version, 1);
  assert.equal(Object.keys(draft.briefs).length, 4);
  assert.deepEqual(snapshot(board), before);
});

test("every hand placement becomes a proposed answer-key entry; nothing already in the key moves", () => {
  const labels = { version: 1, groups: { price: "Stale price" }, briefs: { "20260915-100000": "price", "20260916-100000": "odds" } };
  const b = (id, extra) => ({ id, narration: "x", line: `line ${id}`, task: null, odds: false, taskBy: null, decidedBy: "jev", collectionBy: null, ...extra });
  const briefs = [
    b("20260915-100000"),                                                    // in the key already
    b("20260916-100000", { taskBy: "you", task: "t-20260915-100000" }),     // in the key already: untouched
    b("20260917-100000", { taskBy: "you", task: "t-20260915-100000" }),     // moved into the price task
    b("20260918-100000", { taskBy: "you", task: "t-20260918-100000" }),     // "it's new"
    b("20260919-100000", { decidedBy: "you", odds: true }),                  // put in odds and ends
    b("20260920-100000", { task: "t-20260915-100000" }),                    // filed by Jev: not a correction
    b("20260921-100000", { decidedBy: "you", collectionBy: "you" }),        // only the project was placed
  ];
  const got = correctionLabels(labels, briefs, new Map([["t-20260918-100000", "Signups chart dip"]]));
  assert.deepEqual(got.briefs, { "20260917-100000": "price", "20260918-100000": "signups-chart-dip", "20260919-100000": "odds" });
  assert.deepEqual(got.groups, { "signups-chart-dip": "Signups chart dip" });
  assert.deepEqual(got.reasons.map((r) => r.why), ["you placed it in this task", "you said it's new", "you put it in odds and ends"]);
});
