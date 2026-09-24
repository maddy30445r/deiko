/**
 * THE FILING EVAL'S ARITHMETIC — the answer key, what a decision counts as,
 * and the report. Pure except `readLabels`. The answer key lives OUTSIDE the
 * repo (it holds real narrations): ~/Documents/Deiko-eval/filing-labels.json,
 * `{ version: 1, groups: { slug: title }, briefs: { "<stamp>": slug | "odds" | "skip" } }`.
 */
import { readFileSync } from "node:fs";

import { STAMP } from "./context.mjs";

export function readLabels(path) {
  let labels;
  try {
    labels = JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    if (err instanceof SyntaxError) throw new Error(`${path}: not valid JSON (${err.message})`);
    throw err;
  }
  if (labels?.version !== 1 || !labels.groups || typeof labels.groups !== "object"
    || !labels.briefs || typeof labels.briefs !== "object") {
    throw new Error(`${path}: expected { version: 1, groups, briefs }`);
  }
  for (const [stamp, v] of Object.entries(labels.briefs)) {
    if (!STAMP.test(stamp)) throw new Error(`${path}: "${stamp}" is not a brief stamp`);
    if (v !== "odds" && v !== "skip" && !Object.hasOwn(labels.groups, v)) {
      throw new Error(`${path}: ${stamp} names unknown group "${v}"`);
    }
  }
  return labels;
}

/// `has(stamp)` says whether the brief can be replayed at all. A missing one is
/// left out BEFORE firsts are counted, so the next brief of its group is the
/// group's new task rather than a join to a task that never reaches the board.
export function expectations(briefs, has = () => true) {
  const out = new Map();
  const first = new Map();
  for (const stamp of Object.keys(briefs).sort()) {
    const v = briefs[stamp];
    if (v === "skip" || !has(stamp)) continue;
    if (v === "odds") {
      out.set(stamp, { want: "odds", task: null, slug: null });
    } else if (!first.has(v)) {
      first.set(v, `t-${stamp}`);
      out.set(stamp, { want: "new", task: `t-${stamp}`, slug: v });
    } else {
      out.set(stamp, { want: "join", task: first.get(v), slug: v });
    }
  }
  return out;
}

export function outcomeOf(decision, stamp) {
  if (decision?.pile === "odds") return { got: "odds", task: null, candidates: [] };
  const candidates = decision?.candidates ?? [];
  if (decision?.task && decision.task !== `t-${stamp}`) return { got: "join", task: decision.task, candidates };
  return { got: candidates.length ? "ask" : "new", task: `t-${stamp}`, candidates };
}

export const rankOf = (ids, task) => (ids.indexOf(task) + 1) || null;

const right = (r) => r.out.got === r.exp.want && (r.exp.want !== "join" || r.out.task === r.exp.task);
const said = (o) => (o.got === "join" ? `join ${o.task}` : o.got === "ask" ? `ask ${o.candidates.join(", ")}` : o.got);

export function tally(rows) {
  const judged = rows.filter((r) => r.out);
  const byWant = {};
  for (const w of ["odds", "new", "join"]) {
    const of = judged.filter((r) => r.exp.want === w);
    byWant[w] = [of.filter(right).length, of.length];
  }
  // THE ASK RATE is over real briefs — ones the key says are not odds.
  const real = judged.filter((r) => r.exp.want !== "odds");
  return {
    n: judged.length,
    correct: judged.filter(right).length,
    byWant,
    wrong: judged.filter((r) => !right(r)).map((r) => ({
      stamp: r.stamp,
      want: r.exp.want === "join" ? `join ${r.exp.task}` : r.exp.want,
      got: said(r.out),
    })),
    asks: real.filter((r) => r.out.got === "ask").length,
    real: real.length,
  };
}

export function recall(rows, label, n) {
  const joins = rows.filter((r) => r.exp.want === "join" && label in (r.ranks ?? {}));
  return [joins.filter((r) => r.ranks[label] != null && r.ranks[label] <= n).length, joins.length];
}

const pct = (a, b) => (b ? `${Math.round((100 * a) / b)}%` : "–");

export function formatReport({ rows, shortlistOnly, errored = 0 }) {
  const out = ["shortlist recall (briefs that should join)"];
  for (const label of [...new Set(rows.flatMap((r) => Object.keys(r.ranks ?? {})))]) {
    const [h5, of] = recall(rows, label, 5);
    const [h20] = recall(rows, label, 20);
    out.push(`  ${label.padEnd(10)} top 5: ${h5}/${of} (${pct(h5, of)})   top 20: ${h20}/${of} (${pct(h20, of)})`);
  }
  if (shortlistOnly) return out.join("\n");
  const t = tally(rows);
  for (const w of t.wrong) out.push(`✗ ${w.stamp}  want ${w.want.padEnd(26)} got ${w.got}`);
  out.push(`accuracy ${t.correct}/${t.n} (${pct(t.correct, t.n)}) · odds ${t.byWant.odds.join("/")} · new ${t.byWant.new.join("/")} · join ${t.byWant.join.join("/")}`);
  out.push(`ask rate ${t.asks}/${t.real} (${pct(t.asks, t.real)})`);
  if (errored) out.push(`· ${errored} brief(s) got no answer from the relay and are not counted`);
  return out.join("\n");
}

/** A starting key from where the board has things now — the owner corrects it once. */
export function draftLabels(briefs) {
  const groups = {};
  const out = {};
  const slugOf = new Map();
  for (const b of [...briefs].sort((x, y) => (x.id < y.id ? -1 : 1))) {
    if (b.narration == null) { out[b.id] = "skip"; continue; }
    if (b.odds || !b.line) { out[b.id] = "odds"; continue; }
    const task = b.task ?? `t-${b.id}`;
    if (!slugOf.has(task)) {
      slugOf.set(task, `g${slugOf.size + 1}`);
      groups[slugOf.get(task)] = b.line.slice(0, 80);
    }
    out[b.id] = slugOf.get(task);
  }
  return { version: 1, groups, briefs: out };
}
