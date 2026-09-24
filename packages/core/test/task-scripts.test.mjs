// THE TWO TASK SCRIPTS, RUN AS THE APP RUNS THEM: `render-brief.mjs` and
// `classify.mjs` as child processes over synthetic sessions in a temp root.
// Both are top-level scripts, so their wiring — which briefs a render reads,
// what classify sends and writes — is only reachable this way.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import {
  closeSync, constants, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync, writeSync,
} from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const scripts = fileURLToPath(new URL("..", import.meta.url));

/** A session `render-brief.mjs` can read: one probe per window title, and the words said. */
function session(root, id, { said, windows = [], summary, context, outcome } = {}) {
  const dir = join(root, id);
  mkdirSync(dir);
  const probes = windows.map((w, i) => ({
    type: "probe", t: 110 + i * 100, app: { name: "Cursor", bundleId: "x" }, windowTitle: w,
    shape: { kind: "point", origin: { x: 1, y: 1 } }, span: { start: 100 + i * 100, end: 112 + i * 100 },
    snapshot: { elements: [{ value: "Sign in" }] },
  }));
  const events = [{ type: "sessionStart", t: 0 }, { type: "holdStart", t: 10, hold: 1 }, ...probes];
  writeFileSync(join(dir, "events.jsonl"), events.map((e) => JSON.stringify(e)).join("\n") + "\n");
  const words = said.split(" ").map((text, i) => ({ text, start: i * 100, end: i * 100 + 90 }));
  writeFileSync(join(dir, "transcript.json"), JSON.stringify({ words }));
  if (summary) writeFileSync(join(dir, "review-summary.txt"), `${summary}\n`);
  if (context) writeFileSync(join(dir, "context.json"), JSON.stringify(context));
  if (outcome) writeFileSync(join(dir, "outcome.md"), outcome);
  return dir;
}

const render = (dir) => run(process.execPath, [join(scripts, "render-brief.mjs"), dir]);
const prompt = (dir, name = "prompt.txt") => readFileSync(join(dir, name), "utf8");

// ── render-brief ────────────────────────────────────────────────────────────

test("a re-rendered brief carries on only from briefs older than itself", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-render-"));
  const task = "t-20260918-100000";
  const a = session(root, "20260918-100000", { said: "the price still shows 99 after I save", summary: "Fix the price display after saving.", context: { task } });
  const b = session(root, "20260918-110000", { said: "same price bug on the listing page", summary: "The listing page shows the old price too.", context: { task } });
  const c = session(root, "20260918-120000", { said: "and the cart total is stale as well", summary: "The cart total is stale too.", context: { task } });
  for (const dir of [a, b, c]) await render(dir);
  await render(a);
  await render(b);
  assert.doesNotMatch(prompt(a), /carries on/, "the first brief has nothing earlier");
  assert.match(prompt(b), /This carries on from "Fix the price display after saving" \(1 brief so far\)\.\nThe full history is in /,
    "titled from the oldest brief, counting only earlier ones, with no line repeating the title");
  assert.doesNotMatch(prompt(b), /cart total/, "a later brief never reaches an earlier one's prompt");
  assert.match(prompt(c), /\(2 briefs so far\)\. Where it stands:\nLast asked: The listing page shows the old price too\.\n/);
});

test("candidates are listed whenever the task was not placed, even with the collection placed by hand", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-render-"));
  session(root, "20260918-100000", { said: "the price still shows 99 after I save", summary: "Fix the price display after saving." });
  const d = session(root, "20260918-110000", {
    said: "this one is broken again", summary: "Something is broken again.",
    context: { collection: "shop", task: "t-20260918-110000", decidedBy: "you", candidates: ["t-20260918-100000"] },
  });
  await render(d);
  assert.match(prompt(d), /This might carry on from earlier work, one of these:\n- "Fix the price display after saving"\. History: /);
});

test("a brief in odds and ends carries on from nothing", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-render-"));
  // An older brief moved by hand into the odds brief's own task id.
  session(root, "20260918-100000", { said: "the price still shows 99 after I save", summary: "Fix the price display after saving.", context: { task: "t-20260918-110000" } });
  const odds = session(root, "20260918-110000", { said: "Thank you.", context: { pile: "odds", decidedBy: "local" } });
  await render(odds);
  assert.doesNotMatch(prompt(odds), /carries on|might carry on/);
});

test("repo hints keep names that merely contain an app's name", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-render-"));
  const dir = session(root, "20260918-100000", {
    said: "look at this search thing here",
    windows: ["index.ts — search-api", "Notes — research — Arc", "Pull requests — acme-portal — Bitbucket"],
  });
  await render(dir);
  const { repoHints } = JSON.parse(readFileSync(join(dir, "brief.json"), "utf8")).summary;
  assert.deepEqual(repoHints.sort(), ["acme-portal", "research", "search-api"]);
});

// ── classify ────────────────────────────────────────────────────────────────

/** A sibling as `render-brief.mjs` leaves it: `brief.json`, and whatever else it has. */
function filed(root, id, { narration, summary, windows = [], repoHints = [], screenTerms = [], context, outcome } = {}) {
  const dir = join(root, id);
  mkdirSync(dir);
  writeFileSync(join(dir, "brief.json"), JSON.stringify({ summary: { narration, apps: [], windows, repoHints, screenTerms } }));
  if (summary) writeFileSync(join(dir, "review-summary.txt"), `${summary}\n`);
  if (context) writeFileSync(join(dir, "context.json"), JSON.stringify(context));
  if (outcome) writeFileSync(join(dir, "outcome.md"), outcome);
  return dir;
}

/** A relay on a free local port that records each body and answers `respond(body)`. */
async function relay(respond = () => [200, { model: "stub", answers: {} }]) {
  const bodies = [];
  const server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => { raw += c; });
    req.on("end", () => {
      bodies.push(JSON.parse(raw));
      const [status, json] = respond(bodies.at(-1));
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(json));
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  server.unref(); // a failed assertion before `close` must not hold the run open
  return { url: `http://127.0.0.1:${server.address().port}`, bodies, close: () => new Promise((r) => server.close(r)) };
}

/** Only the relay URL, or none: never a token from the environment running the tests. */
const classify = (dir, url) => run(process.execPath, [join(scripts, "classify.mjs"), dir], {
  env: { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("DEIKO_"))), ...(url && { DEIKO_CLASSIFY_URL: url }) },
});
const json = (path) => JSON.parse(readFileSync(path, "utf8"));
const join1 = (task) => () => [200, { model: "stub", answers: { task: { choice: task, confidence: 0.9 } } }];

test("a task is described by its most frequent windows, and same repo is an exact hint", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  const task = "t-20260918-090000";
  filed(root, "20260918-090000", { narration: "the price still shows 99 after I save", windows: ["Price.tsx — acme-portal"], repoHints: ["acme-portal"] });
  filed(root, "20260918-091000", { narration: "same price bug on the listing page", windows: ["Price.tsx — acme-portal"], context: { task } });
  filed(root, "20260918-092000", { narration: "why does the signup chart drop in week 32", windows: ["Chart.tsx — analytics"], context: { task } });
  filed(root, "20260918-093000", { narration: "the sitemap xml has the wrong urls in it", screenTerms: ["acme-portal"] });
  const dir = filed(root, "20260918-100000", { narration: "the price bug is back on the listing", repoHints: ["Acme-Portal"] });
  const stub = await relay();
  await classify(dir, stub.url);
  stub.close();
  const sent = Object.fromEntries(stub.bodies[0].tasks.map((t) => [t.id, t]));
  assert.deepEqual(sent[task].windows, ["Price.tsx — acme-portal", "Chart.tsx — analytics"]);
  assert.equal(sent[task].sameRepo, true);
  assert.equal(sent["t-20260918-093000"].sameRepo, false, "a screen word is not a repo");
});

test("the classifier reads what a task is before its newest, maybe mis-filed, ask", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  const task = "t-20260918-090000";
  filed(root, "20260918-090000", {
    narration: "the price still shows 99 after I save", summary: "Fix the price display after saving.",
    outcome: "## Did\nSynced the price after save.\n## Open\nThe listing page still caches the old price.\n",
  });
  filed(root, "20260918-091000", {
    narration: "why does the signup chart drop in week 32", summary: "Explain the week-32 drop in the signup chart.", context: { task },
  });
  const dir = filed(root, "20260918-100000", { narration: "the price bug is back on the listing" });
  const stub = await relay();
  await classify(dir, stub.url);
  stub.close();
  assert.deepEqual(stub.bodies[0].tasks[0].now.split("\n"), [
    "Still open from Sep 18: The listing page still caches the old price.",
    "Last asked: Explain the week-32 drop in the signup chart.",
  ]);
});

test("a joined brief nothing else placed takes its task's collection", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  writeFileSync(join(root, "collections.json"), JSON.stringify([{ id: "shop", name: "Shop", hint: "" }]));
  filed(root, "20260918-090000", { narration: "the price still shows 99 after I save", context: { collection: "shop" } });
  const dir = filed(root, "20260918-100000", { narration: "the price bug is back on the listing" });
  const stub = await relay(join1("t-20260918-090000"));
  await classify(dir, stub.url);
  stub.close();
  const context = json(join(dir, "context.json"));
  assert.equal(context.task, "t-20260918-090000");
  assert.equal(context.collection, "shop");
});

const ODDS = { pile: "odds", decidedBy: "local" };

test("a brief the summary could not tell goes to odds and ends, sending nothing, relay or none", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  const stub = await relay();
  for (const [id, url] of [["20260918-100000", stub.url], ["20260918-110000", undefined]]) {
    const dir = filed(root, id, { narration: "hello hello can you hear me now", summary: "The transcript is too short to determine a request." });
    const { stderr } = await classify(dir, url);
    assert.deepEqual(json(join(dir, "context.json")), ODDS);
    assert.equal(existsSync(join(dir, "classify.sent")), false);
    assert.match(stderr, /could not tell .* odds and ends/);
  }
  stub.close();
  assert.equal(stub.bodies.length, 0);
});

// The Catalogue page as a brief's screen reads it: its window and its words.
const catalogue = {
  windows: ["Catalogue — shop"],
  screenTerms: ["catalogue", "price", "scarf", "oxford", "leather", "stock", "sku", "wool", "cover", "shirt", "edit", "save"],
};

test("a short follow-up on its task's window joins it here, and nothing is sent", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  writeFileSync(join(root, "collections.json"), JSON.stringify([{ id: "shop", name: "Shop", hint: "" }]));
  const task = "t-20260918-090000";
  filed(root, "20260918-090000", { narration: "the price still shows 99 after I save", ...catalogue, context: { collection: "shop" } });
  filed(root, "20260918-091000", { narration: "same price bug on the listing page", ...catalogue, context: { task } });
  filed(root, "20260918-092000", { narration: "why does the signup chart drop in week 32", windows: ["Signups — shop"], screenTerms: ["signups", "chart", "week"] });
  const dir = filed(root, "20260918-100000", { narration: "fix this", ...catalogue });
  // No relay at all, and the same with one: a short brief is never sent.
  await classify(dir);
  assert.deepEqual(json(join(dir, "context.json")), {
    collection: "shop", task, tier: null, confidence: { task: null }, decidedBy: "local", model: null,
  });
  const stub = await relay(join1("t-20260918-092000"));
  await classify(dir, stub.url);
  stub.close();
  assert.equal(stub.bodies.length, 0);
  assert.equal(existsSync(join(dir, "classify.sent")), false);
  assert.equal(json(join(dir, "context.json")).task, task);
});

test("a short brief with no clear match on its window goes to odds and ends", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  const stub = await relay();
  filed(root, "20260918-090000", { narration: "the price still shows 99 after I save", ...catalogue });
  filed(root, "20260918-091000", { narration: "why does the signup chart drop in week 32", windows: ["Signups — shop"], screenTerms: ["signups", "chart", "week"] });
  // Nothing on screen that any task has.
  const weak = filed(root, "20260918-100000", { narration: "Thank you.", windows: ["Mail — Inbox"], screenTerms: ["inbox", "drafts"] });
  // The same words as a task, read off a window that task never had.
  const elsewhere = filed(root, "20260918-101000", { narration: "fix this", windows: ["Catalogue copy — Notes"], screenTerms: catalogue.screenTerms });
  for (const dir of [weak, elsewhere]) {
    await classify(dir, stub.url);
    assert.deepEqual(json(join(dir, "context.json")), ODDS, dir);
    assert.equal(existsSync(join(dir, "classify.sent")), false);
  }
  // Two tasks on the same page, neither ahead: which one is a guess.
  filed(root, "20260918-102000", { narration: "the stock count is wrong after an edit", ...catalogue });
  const torn = filed(root, "20260918-103000", { narration: "and this", ...catalogue });
  await classify(torn, stub.url);
  assert.deepEqual(json(join(torn, "context.json")), ODDS);
  stub.close();
  assert.equal(stub.bodies.length, 0);
});

test("odds and ends are never shortlisted, and a brief filed by Deiko here is filed again", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  filed(root, "20260918-090000", { narration: "the price still shows 99 after I save", context: ODDS });
  filed(root, "20260918-091000", { narration: "why does the signup chart drop in week 32" });
  // Said more since ("Point at more"): a local decision is not a hand placement.
  const dir = filed(root, "20260918-100000", { narration: "the price bug is back on the listing", context: ODDS });
  const stub = await relay();
  await classify(dir, stub.url);
  stub.close();
  assert.deepEqual(stub.bodies[0].tasks.map((t) => t.id), ["t-20260918-091000"]);
  assert.equal(json(join(dir, "context.json")).decidedBy, "jev");
  assert.equal(json(join(dir, "context.json")).pile, undefined);
});

test("briefs with nothing to place are never a shortlisted task", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  filed(root, "20260918-090000", { narration: "." });
  filed(root, "20260918-091000", { narration: "testing testing one two three", summary: "The transcript is too garbled to determine a coding task." });
  filed(root, "20260918-092000", { narration: "the price still shows 99 after I save", summary: "Fix the price display after saving." });
  const dir = filed(root, "20260918-100000", { narration: "the price bug is back on the listing", summary: "The listing page shows the old price." });
  const stub = await relay();
  await classify(dir, stub.url);
  stub.close();
  assert.deepEqual(stub.bodies[0].tasks.map((t) => t.id), ["t-20260918-092000"]);
});

test("a new task's title says where it came from, and a narration title gives way to a summary", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  const first = filed(root, "20260918-090000", { narration: "the price still shows 99 after I save it" });
  const stub = await relay();
  await classify(first, stub.url);
  assert.deepEqual(json(join(root, "tasks.json")), [{ id: "t-20260918-090000", title: "the price still shows 99 after I save it", from: "narration" }]);

  const second = filed(root, "20260918-100000", { narration: "same price bug on the listing page", summary: "Fix the stale price on the listing page." });
  stub.close();
  const joining = await relay(join1("t-20260918-090000"));
  await classify(second, joining.url);
  assert.deepEqual(json(join(root, "tasks.json")), [{ id: "t-20260918-090000", title: "Fix the stale price on the listing page", from: "summary" }]);

  // A title somebody typed, or one from before `from` existed, is theirs.
  for (const row of [{ from: "you" }, {}]) {
    writeFileSync(join(root, "tasks.json"), JSON.stringify([{ id: "t-20260918-090000", title: "Mine", ...row }]));
    const again = filed(root, `20260918-11000${row.from ? 1 : 2}`, { narration: "and the cart shows it too now", summary: "The cart shows the stale price." });
    await classify(again, joining.url);
    assert.equal(json(join(root, "tasks.json"))[0].title, "Mine");
  }
  joining.close();
});

test("a request that never connected leaves no sent marker; one that got an answer keeps it", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  const closed = await relay();
  await closed.close();
  const refused = filed(root, "20260918-090000", { narration: "the price still shows 99 after I save it" });
  await classify(refused, closed.url);
  assert.equal(existsSync(join(refused, "classify.sent")), false);
  // An earlier request's words did leave, so its marker is put back.
  const earlier = JSON.stringify({ at: "2026-09-18T09:00:00.000Z", summary: true }) + "\n";
  writeFileSync(join(refused, "classify.sent"), earlier);
  await classify(refused, closed.url);
  assert.equal(readFileSync(join(refused, "classify.sent"), "utf8"), earlier);

  const failing = await relay(() => [500, { error: "upstream" }]);
  const answered = filed(root, "20260918-100000", { narration: "same price bug on the listing page" });
  await classify(answered, failing.url);
  failing.close();
  assert.equal(failing.bodies.length, 2, "one retry on a 5xx");
  assert.equal(existsSync(join(answered, "classify.sent")), true);
});

test("the sent marker says whether a summary went with the request", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  const stub = await relay();
  const without = filed(root, "20260918-090000", { narration: "the price still shows 99 after I save it" });
  const withOne = filed(root, "20260918-100000", { narration: "same price bug on the listing page", summary: "Fix the stale price on the listing page." });
  await classify(without, stub.url);
  await classify(withOne, stub.url);
  stub.close();
  assert.equal(json(join(without, "classify.sent")).summary, false);
  assert.equal(json(join(withOne, "classify.sent")).summary, true);
  // Asked again with no summary, it still says the earlier one went.
  rmSync(join(withOne, "review-summary.txt"));
  const again = await relay();
  await classify(withOne, again.url);
  again.close();
  assert.equal(json(join(withOne, "classify.sent")).summary, true);
});

test("an answer that lands after a newer request for the same brief went out is left to that one", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  filed(root, "20260918-090000", { narration: "the price still shows 99 after I save it" });
  const dir = filed(root, "20260918-100000", { narration: "same price bug on the listing page" });
  // "Point at more" asks again while this request is still out.
  const stub = await relay(() => {
    writeFileSync(join(dir, "classify.sent"), JSON.stringify({ at: "newer", summary: false }) + "\n");
    return join1("t-20260918-090000")();
  });
  const { stderr } = await classify(dir, stub.url);
  stub.close();
  assert.equal(existsSync(join(dir, "context.json")), false);
  assert.match(stderr, /asked again since/);
});

// ── decisions that land while one is being made ─────────────────────────────

test("a hand placement made while the board is read stands over a decision made here", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  // An earlier brief whose brief.json is a pipe: the board walk waits on it,
  // which is when a board move lands in real life.
  const pipe = join(root, "20260918-090000", "brief.json");
  mkdirSync(join(root, "20260918-090000"));
  await run("mkfifo", [pipe]);
  const dir = filed(root, "20260918-100000", { narration: "Thank you." });
  const done = classify(dir);
  // Opens only once the script is reading it — past its first check.
  let fd;
  for (let i = 0; fd === undefined && i < 400; i++) {
    try {
      fd = openSync(pipe, constants.O_WRONLY | constants.O_NONBLOCK);
    } catch {
      await new Promise((r) => setTimeout(r, 25));
    }
  }
  const moved = { task: "t-20260918-090000", decidedBy: "you" };
  writeFileSync(join(dir, "context.json"), JSON.stringify(moved));
  writeSync(fd, JSON.stringify({ summary: { narration: "the price still shows 99 after I save" } }));
  closeSync(fd);
  const { stderr } = await done;
  assert.deepEqual(json(join(dir, "context.json")), moved);
  assert.match(stderr, /placed by hand while we were looking/);
});

test("a decision made here after the request went out stands over its answer", async () => {
  const root = mkdtempSync(join(tmpdir(), "deiko-classify-"));
  filed(root, "20260918-090000", { narration: "the price still shows 99 after I save it" });
  const dir = filed(root, "20260918-100000", { narration: "same price bug on the listing page" });
  // Its words were cut short and it was filed here again while this was out.
  const stub = await relay(() => {
    writeFileSync(join(dir, "context.json"), JSON.stringify(ODDS));
    return join1("t-20260918-090000")();
  });
  const { stderr } = await classify(dir, stub.url);
  stub.close();
  assert.deepEqual(json(join(dir, "context.json")), ODDS);
  assert.match(stderr, /decided here since we asked/);
});
