#!/usr/bin/env node
// Does a brief that points back file where it points? Each case below is a new
// brief against the synthetic board (board-spec.mjs), summarised and filed as
// classify.mjs would (same summary, same prepare, same relay call, same
// decide), and checked against what it should do.
//
//   node evals/memory/references.mjs --relay http://127.0.0.1:8793
//
// Uses the relay's classify and summary; with a local relay (`make relay-dev`)
// that means your own provider keys. Token: DEIKO_CLASSIFY_TOKEN, or a dev
// token for a local relay.
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { place, prepare, requestClassify, sessionInputs } from "@deiko/core/lib/filing.mjs";
import { briefText, currentModel, loadModel } from "@deiko/core/lib/meaning.mjs";
import { groupTasks, readBoard, readTasks } from "@deiko/core/lib/tasks.mjs";
import { buildBoard } from "./board.mjs";
import { projects } from "./board-spec.mjs";

const arg = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : null; };
const relay = arg("--relay") ?? process.env.DEIKO_CLASSIFY_URL;
const token = process.env.DEIKO_CLASSIFY_TOKEN ?? "dev_flowcheck0000000000000000";
if (!relay) throw new Error("pass --relay <url> (e.g. a local `make relay-dev`)");

// want: "join:<key>" | "ask" | "no-join" (new, related or odds: anything but a join)
const CASES = [
  { want: "join:relay", said: "Remember the relay cold start work we did? In that task, also add a keep-warm ping every five minutes so it never goes cold.", windows: ["lambda.mjs — deiko"] },
  { want: "join:bakeryemail", said: "The bakery order emails we moved to Postmark, continuing that: bcc Ana on every order confirmation.", windows: ["email.ts — bakery-app"] },
  { want: "join:applepay", said: "Wahi Apple Pay wala kaam jo humne Safari ke liye kiya tha, usi mein ab Google Pay button bhi Safari pe hide karna hai.", windows: ["WalletButtons.tsx — shopfront-web"] },
  { want: "join:sessions", said: "Carrying on with the checkout logout work from before, now make the session cookie SameSite Lax and secure.", windows: ["session.ts — shopfront-web"] },
  // A question ABOUT a task belongs to it: filed there, the agent gets its decisions.
  { want: "join:sessions", said: "Do you remember what we decided about where sessions are stored? Just tell me, I forgot.", windows: ["Claude Code — shopfront-web"] },
  { want: "no-join", said: "What was the cold start number we measured on the relay back then?", windows: ["Claude Code — deiko"] },
  // Two apps had a price bug: pointing back at "that price bug" must ask.
  { want: "ask", said: "Remember that price bug we fixed? On that same page, make the price text bold too.", windows: ["Claude Code — Desktop"] },
  { want: "no-join", said: "Add a dark mode toggle to the header of the marketing site.", windows: ["index.html — deiko-site"] },
  { want: "no-join", said: "Set up a GitHub Action that runs the tests on every pull request.", windows: ["ci.yml — shopfront-web"] },
  { want: "join:sitemap", said: "In the sitemap task from last week, add the blog posts to the sitemap too.", windows: ["sitemap.xml — deiko-site"] },
];

const work = mkdtempSync(join(tmpdir(), "deiko-eval-refs-"));
const BOARD = join(work, "board");
const ids = buildBoard(BOARD);
const board = readBoard(BOARD);
const groups = groupTasks(board);
const taskTitles = readTasks(BOARD);
const model = await loadModel(currentModel()).catch(() => null);
const docs = new Map();
if (model) for (const b of board) docs.set(b.id, await model.embed(briefText(b), "doc"));

async function summarise(narration) {
  for (let n = 0; n < 2; n++) {
    const r = await fetch(`${relay.replace(/\/+$/, "")}/v1/summarize`, {
      method: "POST", headers: { Authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ narration, mode: "hinglish" }),
    });
    const text = r.ok ? (await r.json())?.choices?.[0]?.message?.content?.trim() : null;
    if (text) return text;
  }
  return null;
}

let pass = 0;
let summarised = 0;
for (const [n, c] of CASES.entries()) {
  const id = `20260930-10${String(n).padStart(2, "0")}00`;
  const dir = join(work, id);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "brief.json"), JSON.stringify({ summary: { narration: c.said, apps: ["Code"], windows: c.windows, repoHints: [], screenTerms: [], keys: {} }, referents: [] }));
  const s = await summarise(c.said);
  if (s) { summarised++; writeFileSync(join(dir, "review-summary.txt"), s + "\n"); }
  const { me, summary, windowTitles } = sessionInputs(dir);
  const query = model ? await model.embed(briefText(me), "query") : null;
  const vectors = query ? { query, byBrief: docs } : null;
  const prep = prepare({ id, me, summary, windowTitles, board, taskTitles, collections: projects, vectors });
  const body = prep.body ?? prep;
  const res = await requestClassify({ url: relay, token, body });
  if (!res.ok) { console.log(`✗ ${id} relay ${res.status}`); continue; }
  const answer = await res.json();
  const d = place({ answer, id, me, summary, groups, shortlist: body.tasks, collections: projects });
  const key = Object.entries(ids).find(([, t]) => t === d.task)?.[0] ?? (d.newTask ? "new" : d.pile ?? "?");
  const got = d.candidates?.length && !groups.has(d.task) ? "ask" : groups.has(d.task) ? `join:${key}` : "no-join";
  const ok = c.want === "no-join" ? !got.startsWith("join") : got === c.want;
  if (ok) pass++;
  console.log(`${ok ? "✓" : "✗"} want ${c.want.padEnd(17)} got ${got.padEnd(17)} (${d.why}; back ${d.jev.back ?? "-"}; refs ${JSON.stringify(Object.fromEntries(Object.entries(d.jev.refs ?? {}).map(([t, p]) => [Object.entries(ids).find(([, i]) => i === t)?.[0] ?? t, p])))})`);
  console.log(`    "${c.said.slice(0, 90)}"`);
}
console.log(`\n${pass}/${CASES.length} filed as they should · ${summarised}/${CASES.length} got a summary`);
