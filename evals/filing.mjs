#!/usr/bin/env node
/**
 * How well Deiko files a board, against a hand-made answer key.
 *
 *   node evals/filing.mjs [--board ~/Library/Application\ Support/Deiko]
 *     [--labels ~/Documents/Deiko-eval/filing-labels.json]
 *     [--shortlist-only] [--relay <url>] [--pace <ms>] [--all] [--draft]
 *     [--model <key>|off] [--replay key|guessed]
 *     [--record <answers.json>] [--answers <answers.json> [--sweep]]
 *     [--aggregate pile|best|average] [--lookalike <cosine>] [--rows <rows.json>]
 *     [--judge-from <stamp>] [--max-calls <n>]
 *   node evals/filing.mjs --from-corrections [--write]
 *     every brief placed by hand since, proposed as new answer-key entries
 *
 * Read-only: nothing under --board is written. Briefs are replayed oldest first
 * against an in-memory board on which every earlier brief sits where the answer
 * key puts it (not where a classifier put it), so each brief is judged on its
 * own and one miss cannot cascade into the next.
 *
 * --replay guessed instead puts every earlier brief where this run filed it, as
 * on a real board, so a wrong join describes its task badly for the briefs
 * after it. Full mode only.
 *
 * --shortlist-only needs no network: recall of the right task in the top 5 and
 * top 20. Full mode calls the relay exactly as classify.mjs does (same body,
 * same code) and spends one classify per brief from the caller's daily
 * allowance: --relay, else DEIKO_CLASSIFY_URL, else DEIKO_RELAY_URL; the token
 * is DEIKO_CLASSIFY_TOKEN or DEIKO_RELAY_TOKEN. --draft prints a starting key.
 *
 * --model picks which meaning model blends into the shortlist (default
 * whatever DEIKO_MEANING_MODEL names; "off" turns it off for this run).
 * Vectors are computed in memory only, from this run's own briefs, so models
 * can be compared without touching the board.
 *
 * --record saves every relay answer of a full run; --answers replays them
 * instead of asking the relay (no network, no allowance), and --sweep then
 * scores a grid of join and ask numbers on those same answers. It only prints;
 * a person picks. This is valid because on the answer key's board what Jev is
 * asked never depends on how earlier briefs were filed. Limit: the relay asks
 * its second look only above its own floor (0.35), so asks below that and gates
 * below 0.5 cannot be judged offline.
 */
import { copyFileSync, readFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

import { RULES, STAMP, readBriefLine, unplaceable } from "@deiko/core/lib/context.mjs";
import { decideLocally, place, prepare, rankLocally, requestClassify, sessionInputs } from "@deiko/core/lib/filing.mjs";
import { correctionLabels, draftLabels, expectations, formatReport, outcomeOf, rankOf, readLabels, tally } from "./lib/eval.mjs";
import { DEIKO_HOME, briefText, currentModel, loadModel } from "@deiko/core/lib/meaning.mjs";
import { readTasks, titleFor } from "@deiko/core/lib/tasks.mjs";
import { writeAtomic } from "@deiko/core/lib/session-io.mjs";

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
const recordPath = value("--record") && home(value("--record"));
const recorded = value("--answers") ? JSON.parse(readFileSync(home(value("--answers")), "utf8")) : null;
const answers = {};
if (recorded && recordPath) {
  console.error("✗ --record and --answers together would overwrite the answers being replayed");
  process.exit(2);
}
if (flag("--sweep") && (!recorded || replayGuessed)) {
  console.error("✗ --sweep needs --answers <file> from a --record run, on the answer key's board (not --replay guessed)");
  process.exit(2);
}
if (replayGuessed && shortlistOnly) {
  console.error("✗ --replay guessed needs the classifier's answers — drop --shortlist-only");
  process.exit(2);
}
/// Gap between briefs in full mode: each brief is up to three Jev requests and
/// a burst draws 429s. A fixed pause.
const paceMs = Number(value("--pace", "1500"));
const relay = value("--relay", process.env.DEIKO_CLASSIFY_URL || process.env.DEIKO_RELAY_URL);
const token = process.env.DEIKO_CLASSIFY_TOKEN || process.env.DEIKO_RELAY_TOKEN || null;
if (!shortlistOnly && !relay && !recorded) {
  console.error("✗ no relay — pass --relay <url>, set DEIKO_CLASSIFY_URL, or use --shortlist-only");
  process.exit(2);
}
// The app's "Sort briefs into tasks" switch, as `make eval` passes it: off means
// no narration leaves for sorting, so full mode needs an explicit --relay.
if (!shortlistOnly && !recorded && process.env.DEIKO_SORT_BRIEFS === "0" && !flag("--relay")) {
  console.error("✗ sorting is off in Settings — pass --relay <url> to send the briefs anyway, or use --shortlist-only");
  process.exit(2);
}

async function ask(body, pause = 0, stamp = null) {
  // Saved with the shortlist it answered: replayed against another one (a
  // different --model, a changed board) its answers would be read for the
  // wrong tasks, so it is refused instead.
  const asked = body.tasks.map((t) => t.id).join(",");
  if (recorded) {
    if (!recorded[stamp]) throw new Error("not in --answers");
    if (recorded[stamp].shortlist !== asked) throw new Error("shortlist differs from the recorded one (another --model?)");
    return recorded[stamp].answer;
  }
  if (pause > 0) await new Promise((r) => setTimeout(r, pause));
  calls += 1;
  let res = await requestClassify({ url: relay, token, body });
  if (res.status >= 500) {
    await new Promise((r) => setTimeout(r, 1000));
    res = await requestClassify({ url: relay, token, body });
  }
  if (!res.ok) throw new Error(`relay ${res.status}`);
  const answer = await res.json();
  if (stamp) answers[stamp] = { shortlist: asked, answer };
  return answer;
}

const inputsOf = new Map();
const readable = (stamp) => {
  if (!inputsOf.has(stamp)) inputsOf.set(stamp, sessionInputs(join(boardDir, stamp)));
  if (!inputsOf.get(stamp)) console.error(`· ${stamp} has no readable brief.json — skipped`);
  return inputsOf.get(stamp) != null;
};
const exp = expectations(readLabels(labelsPath).briefs, readable);

// --model off forces none whatever the environment says; otherwise the flag
// names a model, or DEIKO_MEANING_MODEL does. Loaded once up front and never
// written to the board; vectors live only in `docs` below.
const modelArg = value("--model");
const modelKey = modelArg === undefined ? currentModel() : modelArg === "off" ? null : modelArg;
const model = modelKey ? await loadModel(modelKey) : null;

const rows = [];
let errored = 0;
const done = [];
const taskTitles = new Map();
const collections = [];
const docs = new Map();
// --aggregate: how a many-brief task is scored ("pile", "best" or "average");
// --lookalike: the look-alike check (a cosine, or off).
const aggregate = value("--aggregate", undefined);
const lookalike = value("--lookalike", undefined) != null ? Number(value("--lookalike")) : undefined;
const rowsPath = value("--rows", null);
// --judge-from <stamp>: earlier briefs go on the board as the key places them,
// with no relay call, so a comparison spends only on the briefs it judges.
const judgeFrom = value("--judge-from", null);
// --local-ask floor,lead | off: try the "Same work?" rule's numbers on a run.
const localArg = value("--local-ask", null);
const runRules = localArg == null ? undefined
  : { ...RULES, local: localArg === "off" ? null : (([floor, lead]) => ({ floor: Number(floor), lead: Number(lead) }))(localArg.split(",")) };
const maxCalls = Number(value("--max-calls", Infinity));
let calls = 0;
for (const [stamp, e] of exp) {
  const { me, summary, windowTitles } = inputsOf.get(stamp);
  if (judgeFrom && stamp < judgeFrom) {
    done.push({ ...me, task: e.task, odds: e.want === "odds", decidedBy: "you", taskBy: "you" });
    if (e.want === "new") taskTitles.set(e.task, titleFor(me));
    if (model) { const vec = await model.embed(briefText(me), "doc"); if (vec) docs.set(stamp, vec); }
    continue;
  }
  if (!shortlistOnly && !recorded && calls >= maxCalls) { console.error(`· stopped at --max-calls ${maxCalls}`); break; }
  const board = done.filter((b) => b.line && !b.odds && !unplaceable(b));
  const prep = prepare({ id: stamp, me, summary, windowTitles, board, taskTitles, collections, aggregate, lookalike });
  const query = model ? await model.embed(briefText(me), "query") : null;
  const vectors = query ? { query, byBrief: docs } : null;
  const blended = vectors ? prepare({ id: stamp, me, summary, windowTitles, board, taskTitles, collections, vectors, aggregate, lookalike }) : null;
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
      const args = why ? null : { answer: await ask(use.body, paceMs, stamp), id: stamp, me, summary, groups: use.groups, shortlist: use.shortlist, collections: [...collections], lookalikes: use.lookalikes ?? {}, rules: runRules };
      const decision = why
        ? decideLocally({ me, ...rankLocally({ me, summary, windowTitles, board, taskTitles }), collections })
        : place(args);
      row.args = args;
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
    // The guess goes on the board, stamped as a v3 filing so it describes its
    // task (`firm`) as a real one would.
    const odds = row.out.got === "odds";
    done.push({ ...me, task: odds ? null : row.out.task, odds, decidedBy: "jev", classifier: "v3.0", confidence: { task: 1 } });
    if (!odds && row.out.got !== "join") taskTitles.set(row.out.task, titleFor(me));
  } else {
    // The key, not the guess, goes on the in-memory board. A placement the key
    // makes is a hand placement of the task, which lets it describe its task
    // (`firm` in tasks.mjs) as a corrected brief would.
    done.push({ ...me, task: e.task, odds: e.want === "odds", decidedBy: "you", taskBy: "you" });
    if (e.want === "new") taskTitles.set(e.task, titleFor(me));
  }
}
if (rowsPath) {
  writeAtomic(home(rowsPath), JSON.stringify(rows.map(({ args, ...r }) => ({ ...r, why: r.jev?.why ?? null, back: r.jev?.back ?? null })), null, 1) + "\n");
  console.error(`· ${rows.length} rows saved to ${rowsPath}`);
}
if (recordPath) {
  writeAtomic(recordPath, JSON.stringify(answers) + "\n");
  console.error(`· ${Object.keys(answers).length} relay answers saved to ${recordPath}`);
}
if (flag("--sweep")) {
  const scored = [];
  for (const first of [0.5, 0.55, 0.6, 0.65, 0.7]) for (const second of [0.3, 0.4, 0.5]) for (const gap of [0.1, 0.15, 0.2, 0.25])
    for (const askAt of [0.35, 0.4, 0.45, 0.5]) for (const gate of [0.5, 0.6]) {
      const rules = { gate, ask: askAt, join: { ...RULES.join, first, second, gap } };
      const t = tally(rows.filter((r) => r.out).map((r) => ({ ...r, out: r.args ? outcomeOf(place({ ...r.args, rules }), r.stamp) : r.out })));
      scored.push({ t, label: `gate ${gate} · join first ${first} second ${second} gap ${gap} · ask ${askAt}`, now: gate === RULES.gate && askAt === RULES.ask && first === RULES.join.first && second === RULES.join.second && gap === RULES.join.gap });
    }
  scored.sort((a, b) => b.t.correct - a.t.correct || a.t.asks - b.t.asks);
  const line = ({ t, label, now }) => `${now ? "→" : " "} ${String(t.correct).padStart(3)}/${t.n} right · asks ${t.asks}/${t.real} · ${label}`;
  console.log(`THE SWEEP, on ${rows.filter((r) => r.out).length} recorded briefs (→ is today's numbers). Printed only: a person picks.`);
  for (const r of scored.slice(0, 15)) console.log(line(r));
  if (!scored.slice(0, 15).some((r) => r.now)) console.log(line(scored.find((r) => r.now)));
  process.exit(0);
}
const report = formatReport({ rows, shortlistOnly, errored, all: flag("--all") });
process.stdout.write(`meaning model: ${model ? model.key : "none (word matching only)"} · replayed on ${replayGuessed ? "its own guesses" : "the answer key"}\n${report}\n`);
