#!/usr/bin/env node
/**
 * How well Deiko files a board, against a hand-made answer key.
 *
 *   node scripts/eval-filing.mjs [--board ~/Documents/Deiko]
 *     [--labels ~/Documents/Deiko-eval/filing-labels.json]
 *     [--shortlist-only] [--relay <url>] [--pace <ms>] [--draft]
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
import { readdirSync } from "node:fs";
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
/// Gap between briefs in full mode. Each brief is up to three Jev requests,
/// and the gateway answers a burst with 429s. ponytail: a fixed pause.
const paceMs = Number(value("--pace", "1500"));
const relay = value("--relay", process.env.DEIKO_CLASSIFY_URL || process.env.DEIKO_RELAY_URL);
const token = process.env.DEIKO_CLASSIFY_TOKEN || process.env.DEIKO_RELAY_TOKEN || null;
if (!shortlistOnly && !relay) {
  console.error("✗ no relay — pass --relay <url>, set DEIKO_CLASSIFY_URL, or use --shortlist-only");
  process.exit(2);
}
// The app's "Sort briefs into tasks" switch, as `make eval` passes it: off means
// no narration leaves for sorting, so full mode needs an explicit --relay.
if (!shortlistOnly && process.env.DEIKO_SORT_BRIEFS === "0" && !flag("--relay")) {
  console.error("✗ sorting is off in Settings — pass --relay <url> to send the briefs anyway, or use --shortlist-only");
  process.exit(2);
}

async function ask(body, pause = 0) {
  if (pause > 0) await new Promise((r) => setTimeout(r, pause));
  let res = await requestClassify({ url: relay, token, body });
  if (res.status >= 500) {
    await new Promise((r) => setTimeout(r, 1000));
    res = await requestClassify({ url: relay, token, body });
  }
  if (!res.ok) throw new Error(`relay ${res.status}`);
  return res.json();
}

const inputsOf = new Map();
const readable = (stamp) => {
  if (!inputsOf.has(stamp)) inputsOf.set(stamp, sessionInputs(join(boardDir, stamp)));
  if (!inputsOf.get(stamp)) console.error(`· ${stamp} has no readable brief.json — skipped`);
  return inputsOf.get(stamp) != null;
};
const exp = expectations(readLabels(home(value("--labels", "~/Documents/Deiko-eval/filing-labels.json"))).briefs, readable);
const rows = [];
let errored = 0;
const done = [];
const taskTitles = new Map();
const collections = [];
for (const [stamp, e] of exp) {
  const { me, summary, windowTitles } = inputsOf.get(stamp);
  const board = done.filter((b) => b.line && !b.odds && !unplaceable(b));
  const prep = prepare({ id: stamp, me, summary, windowTitles, board, taskTitles, collections });
  const row = { stamp, exp: e, ranks: { words: e.want === "join" ? rankOf(prep.shortlist.map((t) => t.id), e.task) : null } };
  if (!shortlistOnly) {
    const why = unplaceable(me);
    try {
      const decision = why
        ? decideLocally({ me, why, local: prep.local, groups: prep.groups, collections })
        : place({ answer: await ask(prep.body, paceMs), id: stamp, me, summary, groups: prep.groups, shortlist: prep.shortlist, collections });
      if (decision.newCollection && !collections.some((c) => c.id === decision.newCollection.id)) {
        collections.push({ ...decision.newCollection, hint: "" });
      }
      row.out = outcomeOf(decision, stamp);
      row.jev = decision.jev ?? null;
    } catch (err) {
      // No answer is not a wrong answer: left out of the tally, counted apart.
      errored += 1;
      console.error(`· ${stamp}: ${String(err.message).slice(0, 80)}`);
      if (/relay (401|403|429)\b/.test(err.message)) {
        console.error("✗ the relay refused (auth or allowance) — stopping here");
        break;
      }
    }
  }
  rows.push(row);
  // THE KEY, NOT THE GUESS, goes on the in-memory board — and as a hand
  // placement, which is what a corrected answer key is.
  done.push({ ...me, task: e.task, odds: e.want === "odds" });
  if (e.want === "new") taskTitles.set(e.task, titleFor(me));
}
process.stdout.write(formatReport({ rows, shortlistOnly, errored }) + "\n");
