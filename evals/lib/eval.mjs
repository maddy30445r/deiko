/**
 * The filing eval's arithmetic: the answer key, what a decision counts as, and
 * the report. Pure except `readLabels`. The answer key lives outside the repo
 * because it holds real narrations, at ~/Documents/Deiko-eval/filing-labels.json:
 * `{ version: 1, groups: { slug: title }, briefs: { "<stamp>": slug | "odds" | "skip" } }`.
 */
import { readFileSync } from "node:fs";

import { STAMP, slug } from "@deiko/core/lib/context.mjs";

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
/// left out before firsts are counted, so the next brief of its group is the
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

/// What Jev said about the task the key expected, for tuning the lines:
/// round one's yes, and the second look's yes and relation when there was one.
function numbers(r) {
  const jev = r.jev;
  if (!jev) return "";
  // The expected task when it was on the shortlist; else the one Jev liked most.
  const best = Object.entries(jev.same ?? {}).sort((a, b) => b[1] - a[1])[0]?.[0] ?? null;
  const id = r.exp.task && r.exp.task in (jev.same ?? {}) ? r.exp.task : best;
  const parts = [`gate ${fmt(jev.gate)}`];
  if (id && id !== r.exp.task) parts.push(`top ${id}`);
  if (id && id in (jev.same ?? {})) parts.push(`r1 ${fmt(jev.same[id])}`);
  const look = id ? jev.second?.[id] : null;
  if (look) parts.push(`r2 ${fmt(look.same)} ${look.relation ?? "?"}`);
  return parts.join(" ");
}
const fmt = (p) => (typeof p === "number" ? p.toFixed(2) : "–");

export function tally(rows) {
  const judged = rows.filter((r) => r.out);
  const byWant = {};
  for (const w of ["odds", "new", "join"]) {
    const of = judged.filter((r) => r.exp.want === w);
    byWant[w] = [of.filter(right).length, of.length];
  }
  // The ask rate is over real briefs: ones the key says are not odds.
  const real = judged.filter((r) => r.exp.want !== "odds");
  return {
    n: judged.length,
    correct: judged.filter(right).length,
    byWant,
    wrong: judged.filter((r) => !right(r)).map((r) => ({
      stamp: r.stamp,
      want: r.exp.want === "join" ? `join ${r.exp.task}` : r.exp.want,
      got: said(r.out),
      ...(r.jev && { why: numbers(r) }),
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

export function formatReport({ rows, shortlistOnly, errored = 0, all = false }) {
  const out = ["shortlist recall (briefs that should join)"];
  for (const label of [...new Set(rows.flatMap((r) => Object.keys(r.ranks ?? {})))]) {
    const [h5, of] = recall(rows, label, 5);
    const [h20] = recall(rows, label, 20);
    out.push(`  ${label.padEnd(10)} top 5: ${h5}/${of} (${pct(h5, of)})   top 20: ${h20}/${of} (${pct(h20, of)})`);
  }
  if (shortlistOnly) return out.join("\n");
  const t = tally(rows);
  for (const w of t.wrong) out.push(`✗ ${w.stamp}  want ${w.want.padEnd(26)} got ${w.got}${w.why ? `  (${w.why})` : ""}`);
  // --all: the right ones too, so a looser line can be checked against them.
  if (all) {
    for (const r of rows.filter((x) => x.out && right(x) && x.jev)) {
      out.push(`✓ ${r.stamp}  ${said(r.out).padEnd(31)}  (${numbers(r)})`);
    }
  }
  out.push(`accuracy ${t.correct}/${t.n} (${pct(t.correct, t.n)}) · odds ${t.byWant.odds.join("/")} · new ${t.byWant.new.join("/")} · join ${t.byWant.join.join("/")}`);
  out.push(`ask rate ${t.asks}/${t.real} (${pct(t.asks, t.real)})`);
  if (errored) out.push(`· ${errored} brief(s) got no answer from the relay and are not counted`);
  return out.join("\n");
}

/** A starting key from where the board has things now, for a person to correct once. */
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

/**
 * Every correction is a test case. A brief placed by hand (moved, "Which one?"
 * answered, "Not this one", dragged) is ground truth about where it belongs.
 * Returns the answer-key entries those add, with a reason each, for a person to
 * accept; nothing already in the key is touched.
 *
 * A hand-placed brief joins the group its task already has in the key (the
 * group most of that task's labelled briefs carry); a task the key has never
 * seen becomes a new group named after its title.
 */
export function correctionLabels(labels, briefs, titles = new Map()) {
  const handPlaced = (b) => b.taskBy === "you" || (b.decidedBy === "you" && b.collectionBy !== "you");
  // Which group each board task already is, by majority of its labelled briefs.
  const votes = new Map();
  for (const b of briefs) {
    const v = labels.briefs[b.id];
    if (!v || v === "odds" || v === "skip") continue;
    const task = b.task ?? `t-${b.id}`;
    const tally = votes.get(task) ?? new Map();
    tally.set(v, (tally.get(v) ?? 0) + 1);
    votes.set(task, tally);
  }
  const groupOf = (task) => {
    const tally = votes.get(task);
    return tally ? [...tally].sort((a, b) => b[1] - a[1])[0][0] : null;
  };
  const groups = {};
  const added = {};
  const reasons = [];
  for (const b of [...briefs].sort((x, y) => (x.id < y.id ? -1 : 1))) {
    if (Object.hasOwn(labels.briefs, b.id) || !handPlaced(b) || b.narration == null) continue;
    if (b.odds) {
      added[b.id] = "odds";
      reasons.push({ id: b.id, label: "odds", why: "you put it in odds and ends" });
      continue;
    }
    const task = b.task ?? `t-${b.id}`;
    let group = groupOf(task);
    if (!group) {
      const title = titles.get(task) ?? b.line ?? task;
      const base = slug(title).slice(0, 48) || "task";
      group = base;
      for (let n = 2; Object.hasOwn(labels.groups, group) || Object.hasOwn(groups, group); n++) group = `${base}-${n}`;
      groups[group] = String(title).slice(0, 80);
      votes.set(task, new Map([[group, 1]]));
    }
    added[b.id] = group;
    reasons.push({ id: b.id, label: group, why: task === `t-${b.id}` ? "you said it's new" : "you placed it in this task" });
  }
  return { groups, briefs: added, reasons };
}
