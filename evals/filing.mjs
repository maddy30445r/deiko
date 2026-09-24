#!/usr/bin/env node
/**
 * How well Deiko files a board, against a hand-made answer key.
 *
 *   node scripts/eval-filing.mjs [--board ~/Documents/Deiko]
 *     [--labels ~/Documents/Deiko-eval/filing-labels.json]
 *     [--shortlist-only] [--relay <url>] [--draft]
 *
 * READ-ONLY. Nothing under --board is written, ever. Briefs are replayed oldest
 * first against an in-memory board on which every earlier brief sits where the
 * ANSWER KEY puts it (not where a classifier put it), so each brief is judged
 * on its own and one miss cannot cascade into the next.
 * ponytail: that hides snowballing (one wrong join describing a task badly);
 * replay on the guessed board as a second mode if that ever needs measuring.
 *
 * --shortlist-only needs no network: recall of the right task in the top 5 and
 * top 20. Full mode calls the relay exactly as classify.mjs does (same body,
 * same code) and spends one classify per brief from the caller's daily
 * allowance: --relay, else DEIKO_CLASSIFY_URL, else DEIKO_RELAY_URL; the token
 * is DEIKO_CLASSIFY_TOKEN or DEIKO_RELAY_TOKEN. --draft prints a starting key.
 */
import { existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

import { STAMP, readBriefLine, unplaceable } from "./lib/context.mjs";
import { decideLocally, place, prepare, requestClassify, sessionInputs } from "./lib/filing.mjs";
import { draftLabels, expectations, formatReport, outcomeOf, rankOf, readLabels } from "./lib/eval.mjs";
import { titleFor } from "./lib/tasks.mjs";

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const value = (name, fallback) => {
  const i = args.indexOf(name);
  return i > -1 && args[i + 1] ? args[i + 1] : fallback;
};
const home = (p) => resolve(String(p).replace(/^~/, homedir()));

const boardDir = home(value("--board", "~/Documents/Deiko"));
if (flag("--draft")) {
  const briefs = readdirSync(boardDir).filter((n) => STAMP.test(n)).sort().map((n) => readBriefLine(join(boardDir, n)));
  process.stdout.write(JSON.stringify(draftLabels(briefs), null, 2) + "\n");
  process.exit(0);
}

const shortlistOnly = flag("--shortlist-only");
const relay = value("--relay", process.env.DEIKO_CLASSIFY_URL || process.env.DEIKO_RELAY_URL);
const token = process.env.DEIKO_CLASSIFY_TOKEN || process.env.DEIKO_RELAY_TOKEN || null;
if (!shortlistOnly && !relay) {
  console.error("✗ no relay — pass --relay <url>, set DEIKO_CLASSIFY_URL, or use --shortlist-only");
  process.exit(2);
}

async function ask(body) {
  let res = await requestClassify({ url: relay, token, body });
  if (res.status >= 500) {
    await new Promise((r) => setTimeout(r, 1000));
    res = await requestClassify({ url: relay, token, body });
  }
  if (!res.ok) throw new Error(`relay ${res.status}`);
  return res.json();
}

const exp = expectations(readLabels(home(value("--labels", "~/Documents/Deiko-eval/filing-labels.json"))).briefs);
const rows = [];
const done = [];
const taskTitles = new Map();
const collections = [];
for (const [stamp, e] of exp) {
  const dir = join(boardDir, stamp);
  const inputs = existsSync(dir) ? sessionInputs(dir) : null;
  if (!inputs) {
    console.error(`· ${stamp} has no readable brief.json — skipped`);
    continue;
  }
  const { me, summary, windowTitles } = inputs;
  const board = done.filter((b) => b.line && !b.odds && !unplaceable(b));
  const prep = prepare({ id: stamp, me, summary, windowTitles, board, taskTitles, collections });
  const row = { stamp, exp: e, ranks: { words: e.want === "join" ? rankOf(prep.shortlist.map((t) => t.id), e.task) : null } };
  if (!shortlistOnly) {
    const why = unplaceable(me);
    try {
      const decision = why
        ? decideLocally({ me, why, local: prep.local, groups: prep.groups, collections })
        : place({ answer: await ask(prep.body), id: stamp, me, summary, scored: prep.scored, groups: prep.groups, shortlist: prep.shortlist, collections });
      if (decision.newCollection && !collections.some((c) => c.id === decision.newCollection.id)) {
        collections.push({ ...decision.newCollection, hint: "" });
      }
      row.out = outcomeOf(decision, stamp);
    } catch (err) {
      row.out = { got: "error", task: null, candidates: [] };
      console.error(`· ${stamp}: ${String(err.message).slice(0, 80)}`);
    }
  }
  rows.push(row);
  // THE KEY, NOT THE GUESS, goes on the in-memory board — and as a hand
  // placement, which is what a corrected answer key is.
  done.push({ ...me, task: e.task, odds: e.want === "odds", decidedBy: "you" });
  if (e.want === "new") taskTitles.set(e.task, titleFor(me));
}
process.stdout.write(formatReport({ rows, shortlistOnly }) + "\n");
