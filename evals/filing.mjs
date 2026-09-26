#!/usr/bin/env node
/**
 * How well Deiko files a board, against a hand-made answer key.
 *
 *   node scripts/eval-filing.mjs [--board ~/Library/Application\ Support/Deiko]
 *     [--labels ~/Documents/Deiko-eval/filing-labels.json]
 *     [--shortlist-only] [--relay <url>] [--pace <ms>] [--all] [--draft]
 *     [--model <key>|off] [--replay key|guessed]
 *   node scripts/eval-filing.mjs --from-corrections [--write]
 *     every brief placed by hand since, proposed as new answer-key entries
 *
 * READ-ONLY. Nothing under --board is written, ever. Briefs are replayed oldest
 * first against an in-memory board on which every earlier brief sits where the
 * ANSWER KEY puts it (not where a classifier put it), so each brief is judged
 * on its own and one miss cannot cascade into the next.
 *
 * --replay guessed is the other half: every earlier brief sits where THIS RUN
 * filed it, as on a real board. A wrong join then describes its task badly for
 * the briefs after it — snowballing — and the score shows it. Full mode only.
 *
 * --shortlist-only needs no network: recall of the right task in the top 5 and
 * top 20. Full mode calls the relay exactly as classify.mjs does (same body,
 * same code) and spends one classify per brief from the caller's daily
 * allowance: --relay, else DEIKO_CLASSIFY_URL, else DEIKO_RELAY_URL; the token
 * is DEIKO_CLASSIFY_TOKEN or DEIKO_RELAY_TOKEN. --draft prints a starting key.
 *
 * --model picks which meaning model blends into the shortlist (default
 * whatever DEIKO_MEANING_MODEL names; "off" turns it off for this run
 * whatever the environment says) — THE BAKE-OFF. Vectors are computed in
 * memory only, from this run's own briefs; nothing is read from or written to
 * a brief's meaning.f32, so either model can be compared without touching
 * the board.
 */
import { copyFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

import { STAMP, readBriefLine, unplaceable } from "./lib/context.mjs";
import { decideLocally, place, prepare, rankLocally, requestClassify, sessionInputs } from "./lib/filing.mjs";
import { correctionLabels, draftLabels, expectations, formatReport, outcomeOf, rankOf, readLabels } from "./lib/eval.mjs";
import { DEIKO_HOME, briefText, currentModel, loadModel } from "./lib/meaning.mjs";
import { readTasks, titleFor } from "./lib/tasks.mjs";
import { writeAtomic } from "./lib/session-io.mjs";

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const value = (name, fallback) => {
  const i = args.indexOf(name);
  return i > -1 && args[i + 1] ? args[i + 1] : fallback;
};
const home = (p) => resolve(String(p).replace(/^~/, homedir()));

const boardDir = home(value("--board", DEIKO_HOME));
const labelsPath = home(value("--labels", join(homedir(), "Documents", "Deiko-eval", "filing-labels.json")));
if (flag("--from-corrections")) {
  // Hand placements since the key was last extended, as proposed entries.
  // Printed only; --write adds them (the old key is kept beside it as .prev).
  const labels = readLabels(labelsPath);
  const briefs = readdirSync(boardDir).filter((n) => STAMP.test(n)).sort().map((n) => readBriefLine(join(boardDir, n)));
  const found = correctionLabels(labels, briefs, readTasks(boardDir));
  if (!found.reasons.length) {
    console.log("No new corrections since the key was last extended.");
    process.exit(0);
  }
  for (const r of found.reasons) console.log(`${r.id} → ${r.label}  (${r.why})`);
  if (!flag("--write")) {
    console.log(`\n${found.reasons.length} to add. Check them, then run again with --write.`);
    process.exit(0);
  }
  copyFileSync(labelsPath, `${labelsPath}.prev`);
  const next = { ...labels, groups: { ...labels.groups, ...found.groups }, briefs: { ...labels.briefs, ...found.briefs } };
  writeAtomic(labelsPath, JSON.stringify(next, null, 2) + "\n");
  console.log(`\nAdded ${found.reasons.length} to ${labelsPath} (the old key is ${labelsPath}.prev).`);
  process.exit(0);
}
if (flag("--draft")) {
  const briefs = readdirSync(boardDir).filter((n) => STAMP.test(n)).sort().map((n) => readBriefLine(join(boardDir, n)));
  process.stdout.write(JSON.stringify(draftLabels(briefs), null, 2) + "\n");
  process.exit(0);
}

const shortlistOnly = flag("--shortlist-only");
const replayGuessed = value("--replay", "key") === "guessed";
if (replayGuessed && shortlistOnly) {
  console.error("✗ --replay guessed needs the classifier's answers — drop --shortlist-only");
  process.exit(2);
}
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
const exp = expectations(readLabels(labelsPath).briefs, readable);

// THE BAKE-OFF. --model off forces none whatever the environment says;
// otherwise the flag names a model, or DEIKO_MEANING_MODEL does. Loaded once,
// up front, never written to the board — vectors live only in `docs` below.
const modelArg = value("--model");
const modelKey = modelArg === undefined ? currentModel() : modelArg === "off" ? null : modelArg;
const model = modelKey ? await loadModel(modelKey) : null;

const rows = [];
let errored = 0;
const done = [];
const taskTitles = new Map();
const collections = [];
const docs = new Map();
for (const [stamp, e] of exp) {
  const { me, summary, windowTitles } = inputsOf.get(stamp);
  const board = done.filter((b) => b.line && !b.odds && !unplaceable(b));
  const prep = prepare({ id: stamp, me, summary, windowTitles, board, taskTitles, collections });
  const query = model ? await model.embed(briefText(me), "query") : null;
  const vectors = query ? { query, byBrief: docs } : null;
  const blended = vectors ? prepare({ id: stamp, me, summary, windowTitles, board, taskTitles, collections, vectors }) : null;
  const row = {
    stamp, exp: e,
    ranks: {
      words: e.want === "join" ? rankOf(prep.shortlist.map((t) => t.id), e.task) : null,
      ...(blended && { blended: e.want === "join" ? rankOf(blended.shortlist.map((t) => t.id), e.task) : null }),
    },
  };
  if (!shortlistOnly) {
    const why = unplaceable(me);
    const use = blended ?? prep;
    try {
      const decision = why
        ? decideLocally({ me, ...rankLocally({ me, summary, windowTitles, board, taskTitles }), collections })
        : place({ answer: await ask(use.body, paceMs), id: stamp, me, summary, groups: use.groups, shortlist: use.shortlist, collections });
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
  if (model) {
    const vec = await model.embed(briefText(me), "doc");
    if (vec) docs.set(stamp, vec);
  }
  if (replayGuessed && row.out) {
    // THE GUESS goes on the board, stamped as a v3 filing so it describes its
    // task (`firm`) exactly as a real one would.
    const odds = row.out.got === "odds";
    done.push({ ...me, task: odds ? null : row.out.task, odds, decidedBy: "jev", classifier: "v3.0", confidence: { task: 1 } });
    if (!odds && row.out.got !== "join") taskTitles.set(row.out.task, titleFor(me));
  } else {
    // THE KEY, NOT THE GUESS, goes on the in-memory board. A placement the key
    // makes is a hand placement of the TASK — which is also what lets it
    // describe its task (`firm` in tasks.mjs), as a corrected brief would.
    done.push({ ...me, task: e.task, odds: e.want === "odds", decidedBy: "you", taskBy: "you" });
    if (e.want === "new") taskTitles.set(e.task, titleFor(me));
  }
}
const report = formatReport({ rows, shortlistOnly, errored, all: flag("--all") });
process.stdout.write(`meaning model: ${model ? model.key : "none (word matching only)"} · replayed on ${replayGuessed ? "its own guesses" : "the answer key"}\n${report}\n`);
