#!/usr/bin/env node
// How long the board's readers take on a big board, before and after a speed
// change. Builds a made-up board of N briefs (default 10000) in a temp folder
// and times what one new brief costs today:
//
//   node evals/bench-board.mjs [N] [--keep]
//
// Nothing here touches the real board. `--keep` leaves the folder for a
// look afterwards. It also checks the board index against reading every brief.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

import { olderBoard, prepare, readCollections, sessionInputs } from "@deiko/core/lib/filing.mjs";
import { MODELS, currentModel, readVector } from "@deiko/core/lib/meaning.mjs";
import { STAMP, readBriefLine } from "@deiko/core/lib/context.mjs";
import { groupTasks, readBoard, readBriefLines, readTasks, writeTaskNotes } from "@deiko/core/lib/tasks.mjs";

const N = Number(process.argv.find((a) => /^\d+$/.test(a)) ?? 10000);
const keep = process.argv.includes("--keep");

// Seeded, so two runs build the same board.
let seed = 42;
const rand = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
const pick = (xs) => xs[Math.floor(rand() * xs.length)];
const WORDS = "price cart checkout login header button modal save listing filter search profile avatar upload invoice refund coupon banner footer sidebar table chart export import settings token session cache query index layout spacing colour font icon toast".split(" ");
const APPS = ["Google Chrome", "Visual Studio Code", "Figma", "Terminal", "Safari", "Linear"];
const PAGES = ["Pricing", "Checkout", "Login", "Dashboard", "Settings", "Profile", "Cart", "Search"];
const words = (n) => Array.from({ length: n }, () => pick(WORDS)).join(" ");
const stamp = (i) => {
  const d = new Date(Date.UTC(2024, 0, 1) + i * 37 * 60_000);
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}-${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`;
};

export function buildBoard(n, root = mkdtempSync(join(tmpdir(), "deiko-bench-"))) {
  const key = currentModel();
  const tasks = [];
  const collections = [{ id: "shop", name: "Shop", hint: "" }, { id: "admin", name: "Admin", hint: "" }];
  for (let i = 0; i < n; i++) {
    const id = stamp(i);
    const dir = join(root, id);
    mkdirSync(dir);
    // A third start a task; the rest carry on one of the last 40.
    const task = tasks.length && rand() > 0.33 ? pick(tasks.slice(-40)).id : `t-${id}`;
    if (task === `t-${id}`) tasks.push({ id: task, title: `Fix the ${words(3)}` });
    const narration = `the ${words(8)} still ${words(6)}`;
    const page = pick(PAGES);
    writeFileSync(join(dir, "brief.json"), JSON.stringify({ summary: {
      narration, apps: [pick(APPS), pick(APPS)], windows: [`${page} — ${words(2)}`],
      screenTerms: words(5).split(" "), keys: { pages: [page], sites: ["shop.local"], files: [`src/${pick(WORDS)}.ts`] },
    } }));
    writeFileSync(join(dir, "context.json"), JSON.stringify({
      task, collection: pick(collections).id, decidedBy: rand() > 0.3 ? "jev" : "you", taskBy: rand() > 0.8 ? "you" : undefined, classifier: "v3",
    }));
    writeFileSync(join(dir, "review-summary.txt"), `Fix the ${words(6)}.\n`);
    writeFileSync(join(dir, "events.jsonl"), JSON.stringify({ type: "probe", t: 1, windowTitle: `${page} — ${words(2)}` }) + "\n");
    if (rand() < 0.3) {
      writeFileSync(join(dir, "outcome.md"), `## Did\n- ${words(8)}\n\n## Decided\n- ${words(7)}\n\n## Open\n- ${words(5)}\n\n## Files\n- src/${pick(WORDS)}.ts\n`);
    }
    if (key) {
      const vec = new Float32Array(MODELS[key].dims).map(() => rand() - 0.5);
      writeFileSync(join(dir, "meaning.f32"), Buffer.from(vec.buffer));
      writeFileSync(join(dir, "meaning.json"), JSON.stringify({ model: key, dims: vec.length, text: "x" }));
    }
  }
  writeFileSync(join(root, "tasks.json"), JSON.stringify(tasks));
  writeFileSync(join(root, "collections.json"), JSON.stringify(collections));
  return root;
}

const time = async (label, fn) => {
  const t0 = performance.now();
  const out = await fn();
  console.log(`${label.padEnd(44)} ${(performance.now() - t0).toFixed(0).padStart(7)} ms`);
  return out;
};

async function memorySearch(root, query) {
  const script = fileURLToPath(new URL("../packages/core/src/memory-mcp.mjs", import.meta.url));
  const child = spawn(process.execPath, [script], { env: { ...process.env, DEIKO_ROOT: root }, stdio: ["pipe", "pipe", "ignore"] });
  const lines = createInterface({ input: child.stdout });
  const waiting = new Map();
  lines.on("line", (l) => { const m = JSON.parse(l); waiting.get(m.id)?.(m); });
  let id = 0;
  const call = (method, params) => new Promise((r) => { waiting.set(++id, r); child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n"); });
  await call("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "bench", version: "0" } });
  const search = () => call("tools/call", { name: "search_briefs", arguments: { query } });
  await time("memory helper: first search (loads model)", search);
  await time("memory helper: next search", search);
  child.kill();
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = await time(`build a board of ${N} briefs`, () => buildBoard(N));
  const last = stamp(N - 1);
  await time("readBoard (no index yet)", () => readBoard(root));
  await time("readBoard (index on disk, new process)", () => readBoard(`${root}/.`));
  await time("readBoard (again in this process)", () => readBoard(root));
  // GOLDEN: the index must give exactly what reading every brief gives.
  const direct = readdirSync(root).filter((n) => STAMP.test(n)).map((n) => readBriefLine(join(root, n)));
  assert.deepEqual(readBriefLines(`${root}/./.`), direct, "the index differs from reading every brief");
  console.log("golden: the index matches reading every brief");
  await time("writeTaskNotes (first, writes every note)", () => writeTaskNotes(root));
  await time("writeTaskNotes (nothing changed)", () => writeTaskNotes(root));
  await time("classify: board + shortlist with meanings", () => {
    const inputs = sessionInputs(join(root, last));
    const key = currentModel();
    const board = olderBoard(root, last);
    return prepare({
      id: last, ...inputs, board, taskTitles: readTasks(root), collections: readCollections(root),
      vectors: { query: readVector(join(root, last), key), byBrief: { get: (bid) => readVector(join(root, bid), key) } },
    });
  });
  await time("render-brief: board + groups", () => groupTasks(readBoard(root).filter((b) => b.id < last)));
  await memorySearch(root, "the price still shows the old value after saving");
  if (keep) console.log(`kept: ${root}`);
  else rmSync(root, { recursive: true, force: true });
}
