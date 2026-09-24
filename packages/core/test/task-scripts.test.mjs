// THE TWO TASK SCRIPTS, RUN AS THE APP RUNS THEM: `render-brief.mjs` and
// `classify.mjs` as child processes over synthetic sessions in a temp root.
// Both are top-level scripts, so their wiring — which briefs a render reads,
// what classify sends and writes — is only reachable this way.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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
