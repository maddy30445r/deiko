/**
 * TASKS — the unit Deiko remembers. Project (collection) → task → briefs.
 *
 * A brief's task is `context.json.task`; one with none is its own task,
 * `t-<its stamp>`, so a board from before tasks reads correctly untouched.
 * `tasks.json` beside the sessions holds only titles, because a title can be
 * renamed. The note in `tasks/<id>.md` is compiled from the briefs and their
 * outcomes, never edited in place — see `render-brief.mjs`, its only writer.
 *
 * Pure, except `readTasks` and `writeTaskNotes`.
 */

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { fileStamp, writeAtomic } from "./session-io.mjs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { redact, redactNote } from "./redact.mjs";
import { BRIEF_LINE_FILES, COULD_NOT_TELL, STAMP, briefDate, readBriefLine } from "./context.mjs";

export const TASK_ID = /^t-\d{8}-\d{6}$/;
/// How many tasks Jev is asked about, one yes/no each.
/// ponytail: 20 is the usual starting point for one person's board; the eval
/// measures recall at 5 and 20, and corrections log where the right task sat.
export const SHORTLIST = 20;
const CAP = { now: 12, decided: 20, briefs: 50 };

export const taskIdFor = (stamp) => `t-${stamp}`;

export function stampTime(stamp) {
  const [d, t] = String(stamp).split("-");
  return new Date(+d.slice(0, 4), +d.slice(4, 6) - 1, +d.slice(6, 8),
    +t.slice(0, 2), +t.slice(2, 4), +t.slice(4, 6)).getTime();
}

export const tokens = (text) => String(text ?? "").toLowerCase().match(/[a-z0-9$]{2,}/g) ?? [];

/// A line in an agent's write-back that is shaped like an order to the next
/// agent rather than a note about the work. Screen text an agent read can
/// carry one, and a note would pass it on to every later brief. Dropped.
/// Imperatives only: "Moved the system prompt into prompts/system.ts" or
/// "Ignore all ESLint rules in generated/" are notes and stay.
const INSTRUCTION = /^(please\s+)?(ignore|disregard|forget|override)\b[^.\n]{0,40}\b(previous|prior|above|earlier|all|any|your)\b[^.\n]{0,24}\b(instructions?|prompts?)\b|^you are now\b|^new instructions?:|\b(reveal|print|output|repeat|show)\b[^.\n]{0,30}\b(your|the) system prompt\b/i;

/// The four headings, as agents actually title them.
const HEADS = {
  decided: /^decisions?\b|^decided\b/i,
  open: /^(open|next( steps)?|todo|to do|remaining)\b/i,
  did: /^(did|done|changes?|what i did)\b/i,
  files: /^files?( touched| changed)?\b/i,
  // An earlier decision on the task that no longer holds, quoted.
  retired: /^(retired|reversed|superseded|no longer (holds?|true|applies))\b/i,
};
const section = (heading) => {
  const name = heading.replace(/[*_`]/g, "").trim();
  return Object.keys(HEADS).find((k) => HEADS[k].test(name)) ?? null;
};

/**
 * An agent's `outcome.md`, by its four headings; text before any heading is
 * what it did. A markdown heading that is none of the four starts a section
 * that is dropped — a "## Summary" is not what is still open — except a
 * top-level one ("# Outcome"), which is the file's own title and changes
 * nothing. A "#" needs a space after it: "#2 still flaky" is text. A label alone
 * on its line ("**Did:**", "Files changed:") is a heading only when it names
 * one of the four; otherwise it is text. Code fences are skipped whole,
 * headings inside them included.
 */
export function parseOutcome(text) {
  // `retired` only when there is one: every outcome without it reads as before.
  const out = { did: [], decided: [], open: [], files: [] };
  let into = "did";
  let fence = null;
  for (const raw of String(text ?? "").split("\n")) {
    const marker = raw.match(/^\s*(`{3,}|~{3,})/)?.[1];
    if (fence) {
      if (marker?.[0] === fence[0] && marker.length >= fence.length) fence = null;
      continue;
    }
    if (marker) {
      fence = marker;
      continue;
    }
    const heading = raw.match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      const named = section(heading[2]);
      if (named || heading[1].length > 1) into = named;
      continue;
    }
    const label = raw.trim().replace(/[*_]/g, "");
    if (/^[a-z][a-z ]*:?$/i.test(label) && (label.endsWith(":") || /^\s*(\*\*|__)/.test(raw)) && section(label)) {
      into = section(label);
      continue;
    }
    const line = raw.replace(/^\s*[-*]\s*/, "").trim();
    if (line && into && !INSTRUCTION.test(line)) (out[into] ??= []).push(line);
  }
  return out;
}

const TITLE_CAP = 80;

/// A title Groq or the user wrote, not one Deiko composed: strips the
/// trailing full stop a sentence naturally ends on (so quoting it in a
/// prompt never doubles up, e.g. `…stays old."."`) and caps it at a word
/// boundary rather than mid-word.
function trimTitle(text) {
  const stripped = text.trim().replace(/[.!?\s]+$/, "");
  if (stripped.length <= TITLE_CAP) return stripped;
  const cut = stripped.slice(0, TITLE_CAP);
  const boundary = cut.lastIndexOf(" ");
  return `${boundary > 0 ? cut.slice(0, boundary) : cut}…`;
}

export function titleFor({ summaryLine, narration, apps } = {}) {
  if (summaryLine && !COULD_NOT_TELL.test(summaryLine)) return trimTitle(summaryLine);
  const said = String(narration ?? "").replace(/\s+/g, " ").trim();
  if (said.length > 12) return trimTitle(said);
  if (apps?.[0]) return `Something in ${apps[0]}`;
  return "A brief";
}

export function groupTasks(briefs) {
  const groups = new Map();
  for (const b of [...briefs].sort((x, y) => (x.id < y.id ? 1 : -1))) {
    const id = b.task ?? taskIdFor(b.id);
    if (!groups.has(id)) groups.set(id, []);
    groups.get(id).push(b);
  }
  return groups;
}

/**
 * Newest-first briefs → where the task stands and what was done last.
 *
 * Only the NEWEST brief's outcome says where things stand: an older one
 * describes work a later ask has moved past, so it follows that ask, dated.
 * An outcome with nothing open is finished work and says what was done. A
 * "Last asked" line that only repeats `title` is dropped — the prompt and
 * the note both name the title already.
 */
export function taskState(briefs, title = null) {
  const [newest] = briefs;
  const last = briefs.find((b) => b.outcome);
  const same = (a, b) => trimTitle(a).toLowerCase() === trimTitle(b).toLowerCase();
  const asked = newest && !(title && same(newest.line, title)) ? [`Last asked: ${newest.line}`] : [];
  let now;
  // Which brief "Now" speaks for, so a note can say where it came from.
  const from = newest?.outcome ? newest.id : (last?.outcome.open.length ? last.id : newest?.id) ?? null;
  if (newest?.outcome) {
    const { open, did } = newest.outcome;
    now = open.length ? open : did.length ? [`Last done: ${did[0]}`] : asked;
  } else {
    const open = last?.outcome.open ?? [];
    now = [...asked, ...open.map((o, i) => (i ? o : `Still open from ${briefDate(last.id)}: ${o}`))];
  }
  // As blocks, not line by line: see `redactNote`.
  return {
    from,
    now: redactNote(now.slice(0, CAP.now)),
    lastDid: redactNote((last?.outcome.did ?? []).slice(0, CAP.now)),
  };
}

/** Everything the local score may read, screen terms included. Never sent. */
export function taskText(title, briefs) {
  return [
    title,
    ...briefs.flatMap((b) => [
      b.line, ...b.windows, ...b.apps, ...b.screenTerms,
      ...(b.outcome ? [...b.outcome.did, ...b.outcome.decided, ...b.outcome.open, ...b.outcome.files] : []),
    ]),
  ].join(" ");
}

/// ponytail: starting values, tuned on the filing eval (scripts/eval-filing.mjs).
export const TIME_SEATS = 5;
/// A label on more than this many tasks ("App.tsx", "index.tsx") seats nobody.
export const COMMON_LABEL = 5;
/// Reciprocal-rank fusion. ponytail: try k ∈ {10, 30, 60} and a min-max blend
/// weighted 0.5–0.7 towards meaning on the eval before changing these.
export const RRF_K = 60;
export const RRF_WEIGHTS = { words: 1, meaning: 1 };
/// The labels that hand out seats. Sites and code projects do not: one site
/// or one repo holds most of a board, so they say nothing about WHICH task.
export const SEAT_KINDS = ["pages", "files", "urls", "errors", "tickets"];

export function terms(text) {
  const words = tokens(text);
  const grams = [];
  for (const w of words) if (w.length >= 4) for (let i = 0; i + 3 <= w.length; i++) grams.push(`~${w.slice(i, i + 3)}`);
  return [...words, ...grams];
}

/** Okapi BM25 of one query against each doc, with Lucene's IDF. */
export function bm25(query, docs) {
  if (!docs.length) return [];
  const avg = docs.reduce((s, d) => s + d.length, 0) / docs.length || 1;
  const df = new Map();
  for (const d of docs) for (const w of new Set(d)) df.set(w, (df.get(w) ?? 0) + 1);
  const q = [...new Set(query)];
  const k1 = 1.2, b = 0.75, N = docs.length;
  return docs.map((d) => {
    const tf = new Map();
    for (const w of d) tf.set(w, (tf.get(w) ?? 0) + 1);
    let score = 0;
    for (const w of q) {
      const f = tf.get(w);
      if (!f) continue;
      const idf = Math.log(1 + (N - df.get(w) + 0.5) / (df.get(w) + 0.5));
      score += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + (b * d.length) / avg));
    }
    return score;
  });
}

/** Weighted reciprocal rank fusion. Equal scores share a rank, so a tie in
 *  one list stays a tie (recency breaks it later, not list order). */
export function rrf(lists, k = RRF_K) {
  const n = Math.max(0, ...lists.map((l) => l.scores.length));
  const fused = new Array(n).fill(0);
  for (const { scores, weight } of lists) {
    const first = new Map();
    scores.filter((s) => s != null).sort((a, b) => b - a)
      .forEach((s, r) => { if (!first.has(s)) first.set(s, r); });
    scores.forEach((s, i) => { if (s != null) fused[i] += weight / (k + first.get(s) + 1); });
  }
  return fused;
}

export function cosine(a, b) {
  let s = 0;
  for (let i = 0; i < Math.min(a.length, b.length); i++) s += a[i] * b[i];
  return s;
}

const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

/**
 * The window a brief's time words name, from its own stamp: "today"/"aaj",
 * "this morning", "yesterday"/"kal", "last night" (the evening before),
 * "parso"/"day before yesterday", "this week" (from Monday), "last
 * week"/"pichle hafte", and
 * weekday names (the most recent one before today). Several words → their
 * union. "kal" also means tomorrow; said about past work it means yesterday.
 */
export function timeWindow(text, stamp) {
  // "day before yesterday" is parso, and must not also read as yesterday.
  const said = String(text ?? "").toLowerCase().replace(/\bday before yesterday\b/g, "parso");
  const at = new Date(stamp);
  const day = (offset, hour = 0) => new Date(at.getFullYear(), at.getMonth(), at.getDate() + offset, hour).getTime();
  const spans = [];
  if (/\b(today|aaj)\b/.test(said)) spans.push([day(0), stamp]);
  if (/\bthis morning\b/.test(said)) spans.push([day(0), day(0, 12)]);
  if (/\b(yesterday|kal)\b/.test(said)) spans.push([day(-1), day(0)]);
  if (/\blast night\b/.test(said)) spans.push([day(-1, 18), day(0, 6)]);
  if (/\bparso\b/.test(said)) spans.push([day(-2), day(-1)]);
  if (/\bthis week\b/.test(said)) spans.push([day(-((at.getDay() + 6) % 7)), stamp]);
  if (/\b(last week|pichle hafte|pichhle hafte|pichle week)\b/.test(said)) spans.push([day(-7), day(0)]);
  WEEKDAYS.forEach((name, weekday) => {
    if (!new RegExp(`\\b${name}\\b`).test(said)) return;
    const back = ((at.getDay() - weekday + 7) % 7) || 7;
    spans.push([day(-back), day(-back + 1)]);
  });
  if (!spans.length) return null;
  return { from: Math.min(...spans.map((s) => s[0])), to: Math.max(...spans.map((s) => s[1])) };
}

/** Whether a brief may describe its task: its founder, a hand placement of
 *  its TASK, or any v3 join. JOIN's own thresholds in context.mjs already
 *  gate what counts as one, so this asks only whether a join happened, not
 *  how sure it was. A legacy join (no `classifier`) or a local one is a
 *  guess, never a face — see `decide` and `decideLocally`. So is a join whose
 *  PROJECT alone was corrected by hand: that fixes a chip, not the task. */
export function firm(b, taskId) {
  if (taskIdFor(b.id) === taskId || b.taskBy === "you") return true;
  // Before `taskBy`: `decidedBy: "you"` was a task placement unless the
  // project was what the hand placed.
  if (b.decidedBy === "you" && b.collectionBy !== "you") return true;
  return String(b.classifier ?? "").startsWith("v3") && typeof b.confidence?.task === "number";
}

export function taskLabels(briefs) {
  return Object.fromEntries(SEAT_KINDS.map((k) => [k,
    new Set(briefs.flatMap((b) => b.keys?.[k] ?? []).map((s) => String(s).toLowerCase()))]));
}

/**
 * THE SHORTLIST — up to twenty tasks Jev is asked about, one yes/no each.
 * Seats given outright first: a task sharing an exact page, file, address,
 * error or ticket label with the brief (unless that label is on more than
 * COMMON_LABEL tasks), then up to TIME_SEATS tasks active in a window the
 * brief names, best score first. The rest by reciprocal-rank fusion of BM25
 * over words and 3-grams and, when vectors exist, the cosine to the task's
 * closest firm brief. Recency only breaks ties; the project gives nothing. A
 * seat is a chance to be checked, never a join.
 */
export function shortlist({ query, queryKeys = {}, window = null, queryVec = null, tasks, limit = SHORTLIST }) {
  if (!tasks.length) return [];
  const grams = bm25(terms(query), tasks.map((t) => terms(t.text)));
  const meaning = tasks.map((t) => (queryVec && t.vecs?.length ? Math.max(...t.vecs.map((v) => cosine(queryVec, v))) : null));
  const fused = rrf([
    { scores: grams.map((s) => (s > 0 ? s : null)), weight: RRF_WEIGHTS.words },
    { scores: meaning, weight: RRF_WEIGHTS.meaning },
  ]);
  const count = new Map();
  for (const t of tasks) {
    for (const k of SEAT_KINDS) for (const v of t.labels?.[k] ?? []) count.set(`${k}\n${v}`, (count.get(`${k}\n${v}`) ?? 0) + 1);
  }
  const mine = SEAT_KINDS
    .flatMap((k) => (queryKeys[k] ?? []).map((v) => [k, String(v).toLowerCase()]))
    .filter(([k, v]) => (count.get(`${k}\n${v}`) ?? 0) <= COMMON_LABEL);
  const rows = tasks.map((t, i) => ({
    id: t.id, score: fused[i], meaning: meaning[i], lastActive: t.lastActive ?? 0,
    label: mine.some(([k, v]) => t.labels?.[k]?.has(v)),
    inWindow: Boolean(window && (t.times ?? []).some((ms) => ms >= window.from && ms < window.to)),
  }));
  const byScore = (a, b) => b.score - a.score || b.lastActive - a.lastActive;
  const labelled = rows.filter((r) => r.label).sort(byScore);
  const timed = rows.filter((r) => !r.label && r.inWindow).sort(byScore).slice(0, TIME_SEATS);
  const taken = new Set([...labelled, ...timed].map((r) => r.id));
  return [
    ...labelled.map((r) => ({ ...r, seat: "label" })),
    ...timed.map((r) => ({ ...r, seat: "time" })),
    ...rows.filter((r) => !taken.has(r.id)).sort(byScore).map((r) => ({ ...r, seat: "score" })),
  ].slice(0, limit).map(({ id, score, meaning: m, seat }) => ({ id, score, meaning: m, seat }));
}

/** The compiled note. `briefs` newest first. Every line from another
 *  session is redacted here, where it is written. */
/**
 * Whether a quoted retired line names this decision. Loose on purpose: an
 * agent may copy the note's "Sep 18 (…): " prefix, change the punctuation, or
 * quote only the start. Too short to be sure is never a match.
 */
export const decisionKey = (s) => String(s ?? "").toLowerCase()
  .replace(/^[a-z]{3} \d{1,2}(, \d{4})?(\s*\(\d{8}-\d{6}\))?:\s*/, "")
  .replace(/[^a-z0-9$ ]+/g, " ").replace(/\s+/g, " ").trim();

export function sameDecision(retired, decision) {
  const [r, d] = [decisionKey(retired), decisionKey(decision)];
  if (!r || !d) return false;
  // The quote must be the decision's START (or the decision the quote's):
  // retiring "Use Postgres" must not retire "Do not use Postgres for the cache".
  return r === d || (Math.min(r.length, d.length) >= 12 && (d.startsWith(r) || r.startsWith(d)));
}

export function renderTaskNote({ id, title, collection = null, briefs }) {
  const first = briefDate(briefs.at(-1).id);
  const last = briefDate(briefs[0].id);
  const n = briefs.length;
  const out = [
    `# ${redact(title)}`,
    `${redact(collection ?? "Unsorted")} · ${n} brief${n === 1 ? "" : "s"} · ${first}${last !== first ? `–${last}` : ""} · updated from ${briefs[0].id}`,
    // Rewritten whole on every render, so an edit here would not last.
    "Compiled by Deiko from each brief's outcome.md — edit those, not this file.",
  ];
  // WHAT THE TASK SAYS comes from its confirmed briefs only (`firm`), like the
  // shortlist's face and the prompt's history: one brief guessed in here by
  // mistake must not become where the task stands. It is still listed below.
  const sure = briefs.filter((b) => firm(b, id));
  const said = sure.length ? sure : [briefs.at(-1)];
  const state = taskState(said, title);
  if (state.now.length) out.push("", "## Now", ...state.now, ...(state.from ? [`(from the brief of ${briefDate(state.from)}, ${state.from})`] : []));
  // Each brief's decisions as one block, like its Now: see `redactNote`.
  // EVERY LINE SAYS WHICH BRIEF IT CAME FROM, so an agent can open that brief
  // (get_brief) rather than take a line on trust.
  // RETIRED, NOT DELETED: a decision a LATER brief's agent quoted under
  // "## Retired" no longer shows as current. It stays in its own outcome.md.
  // ONE DECISION, ONE LINE, credited to the brief that made it. Agents read
  // the note and copy decisions into their own write-backs; counting each copy
  // as a new decision is how memory systems end up repeating themselves.
  // RETIRED, NOT DELETED: a decision a later brief quotes under "## Retired"
  // stops being current (it stays in its own outcome.md), and one made again
  // after that is a new decision. So: walk the history oldest first.
  const credited = new Map();   // decision → the brief it currently counts for
  let retiredCount = 0;
  for (const b of [...said].reverse()) {
    for (const r of b.outcome?.retired ?? []) {
      for (const k of [...credited.keys()]) {
        if (sameDecision(r, k)) { credited.delete(k); retiredCount += 1; }
      }
    }
    for (const d of b.outcome?.decided ?? []) if (!credited.has(decisionKey(d))) credited.set(decisionKey(d), b.id);
  }
  const decisions = said.flatMap((b) => {
    const seen = new Set();
    const kept = (b.outcome?.decided ?? []).filter((d) => {
      const k = decisionKey(d);
      if (credited.get(k) !== b.id || seen.has(k)) return false;
      return seen.add(k);
    });
    return redactNote(kept).map((d) => `- ${briefDate(b.id)} (${b.id}): ${d}`);
  });
  const decided = decisions.slice(0, CAP.decided);
  // Trimmed, never silently: the older ones are still in their briefs.
  if (decisions.length > CAP.decided) {
    decided.push(`- … and ${decisions.length - CAP.decided} earlier decisions, in older briefs' outcome.md (search_briefs finds them)`);
  }
  if (retiredCount) {
    decided.push(`- ${retiredCount} earlier decision${retiredCount === 1 ? " was" : "s were"} retired by a later brief (still in ${retiredCount === 1 ? "its" : "their"} outcome.md)`);
  }
  if (decided.length) out.push("", "## Decided", ...decided);
  out.push("", "## Briefs");
  for (const b of briefs.slice(0, CAP.briefs)) {
    const apps = b.apps.length ? ` · ${b.apps.map(redact).join(", ")}` : "";
    const windows = b.windows.length ? ` · ${b.windows.slice(0, 3).map(redact).join(" · ")}` : "";
    out.push(`- ${briefDate(b.id)}, "${redact(b.line)}"${sure.includes(b) ? "" : " (not confirmed)"}${apps}${windows}`);
    // TWO FILES BY NAME, NEVER THE FOLDER — see `prompt.mjs`.
    out.push(`  ${b.dir}/prompt.txt${b.outcome ? ` · ${b.dir}/outcome.md` : ""}`);
  }
  if (n > CAP.briefs) out.push(`- … and ${n - CAP.briefs} earlier`);
  return out.join("\n") + "\n";
}

/** `tasks.json`: titles by id. Missing or unreadable is "no titles yet". */
export function readTasks(root) {
  try {
    const list = JSON.parse(readFileSync(join(root, "tasks.json"), "utf8"));
    return new Map((Array.isArray(list) ? list : [])
      .filter((t) => t && TASK_ID.test(t.id) && typeof t.title === "string")
      .map((t) => [t.id, t.title]));
  } catch {
    return new Map();
  }
}

/**
 * THE BOARD INDEX. Every brief folder under `root` as its `readBriefLine`,
 * in folder order — but read from disk only when one of the files it comes
 * from changed. Reading ~4 small files per brief is most of what a big board
 * costs (about 2.5 s at 10,000 briefs); checking them costs a tenth of that.
 *
 * A brief is re-read when any `BRIEF_LINE_FILES` entry changed inode, size or
 * mtime (ns) — the pipeline and the app replace files by rename, which moves
 * the inode, and an agent editing outcome.md in place moves the mtime. And
 * the whole index is dropped when any script in lib/ changes, so a change to
 * how a line is read never serves a line read the old way.
 *
 * `.board-index.json` beside the briefs is a cache only: deleting it, or two
 * processes writing it at once (last one wins), costs one slow read. The same
 * lines are kept in the process too, so a second read in one run is only the
 * checks. `save: false` never writes (the memory helper writes nothing).
 */
const INDEX = ".board-index.json";
const inProcess = new Map(); // root -> { name: { fp, line } }
// Hashed as this module loads, so it names the code this process runs even
// if an update replaces the files mid-run.
const CODE_KEY = (() => {
  const dir = dirname(fileURLToPath(import.meta.url));
  const h = createHash("sha1");
  for (const f of readdirSync(dir).sort()) if (f.endsWith(".mjs")) h.update(f).update(readFileSync(join(dir, f)));
  return h.digest("hex");
})();
const fingerprint = (dir) => BRIEF_LINE_FILES.map((f) => fileStamp(join(dir, f))).join("|");

export function readBriefLines(root, { save = true } = {}) {
  let known = inProcess.get(root);
  if (!known) {
    try {
      const saved = JSON.parse(readFileSync(join(root, INDEX), "utf8"));
      known = saved?.code === CODE_KEY && saved.briefs && typeof saved.briefs === "object" ? saved.briefs : {};
    } catch {
      known = {};
    }
  }
  const next = {};
  let changed = false;
  const lines = readdirSync(root).filter((name) => STAMP.test(name)).map((name) => {
    const dir = join(root, name);
    const fp = fingerprint(dir);
    const hit = known[name];
    if (hit?.fp === fp) {
      next[name] = hit;
      // `dir` is not kept (the board can move); put back where the reader puts it.
      const { id, ...rest } = hit.line;
      return { id, dir, ...rest };
    }
    changed = true;
    const line = readBriefLine(dir);
    const { dir: _, ...kept } = line;
    next[name] = { fp, line: kept };
    return line;
  });
  if (Object.keys(known).length !== lines.length) changed = true;
  inProcess.set(root, next);
  if (changed && save) {
    try {
      writeAtomic(join(root, INDEX), JSON.stringify({ code: CODE_KEY, briefs: next }));
    } catch {
      // A cache: the next run reads the slow way.
    }
  }
  return lines;
}

/**
 * WHAT DEIKO REMEMBERS, AS YOU CORRECTED IT. "Forget" and "Edit" on a task's
 * notes in the app write `tasks/<id>.overrides.json`:
 * `{ "forget": [line], "edit": { line: replacement } }`, keyed by a line's
 * text as the agent wrote it in outcome.md. Applied wherever an outcome is
 * read for memory — notes, prompts, filing, the memory helper — and never to
 * outcome.md itself, so the history stays and every change can be undone.
 */
export function readOverrides(root) {
  const out = new Map();
  let names = [];
  try {
    names = readdirSync(join(root, "tasks"));
  } catch {
    return out;
  }
  for (const f of names) {
    const id = /^(t-\d{8}-\d{6})\.overrides\.json$/.exec(f)?.[1];
    if (!id) continue;
    try {
      const o = JSON.parse(readFileSync(join(root, "tasks", f), "utf8"));
      out.set(id, {
        forget: new Set((Array.isArray(o?.forget) ? o.forget : []).filter((s) => typeof s === "string")),
        edit: new Map(Object.entries(o?.edit ?? {}).filter(([, v]) => typeof v === "string" && v.trim())),
      });
    } catch {
      // Unreadable: nothing corrected, rather than nothing remembered.
    }
  }
  return out;
}

/** One brief's outcome as corrected — a copy; the cached line is never touched. */
export function withOverrides(b, o) {
  if (!o || !b.outcome) return b;
  const fix = (lines) => lines.filter((l) => !o.forget.has(l)).map((l) => o.edit.get(l) ?? l);
  return { ...b, outcome: Object.fromEntries(Object.entries(b.outcome).map(([k, v]) => [k, fix(v)])) };
}

/** Free text that quotes outcome lines (a sent prompt, a raw outcome.md): a
 *  line quoting a forgotten one goes, an edited one is replaced in place. */
export function overrideText(text, o) {
  if (!o || text == null) return text;
  return String(text).split("\n")
    .filter((l) => ![...o.forget].some((f) => f && l.includes(f)))
    .map((l) => [...o.edit].reduce((acc, [from, to]) => (from ? acc.split(from).join(to) : acc), l))
    .join("\n");
}

/** Lines read off the board, each with its task's corrections applied. */
export function corrected(root, lines) {
  const all = readOverrides(root);
  return all.size ? lines.map((b) => withOverrides(b, all.get(b.task ?? taskIdFor(b.id)))) : lines;
}

/** Every sibling under `root` as a `readBriefLine`, briefs with nothing said
 *  skipped, and odds and ends too: never shortlisted, never in a note. */
export function readBoard(root) {
  return corrected(root, readBriefLines(root)).filter((b) => b.line && !b.odds);
}

/**
 * THE ONLY WRITER OF TASK NOTES. Compiles every task with two or more briefs
 * and writes the ones whose text changed, so a note that lost a brief to a
 * board move but still has two or more left heals on the next render of
 * anything. A single brief has nothing to carry, and hundreds of one-line
 * notes would be clutter — but that also means a task a board move drops
 * back below two briefs keeps its last note exactly as it was, stale,
 * rather than losing or updating it.
 */
export function writeTaskNotes(root) {
  const titles = readTasks(root);
  let names = new Map();
  try {
    names = new Map(JSON.parse(readFileSync(join(root, "collections.json"), "utf8")).map((c) => [c.id, c.name]));
  } catch {
    // No collections: the note says Unsorted.
  }
  const dir = join(root, "tasks");
  let written = 0;
  const kept = new Set();
  for (const [id, briefs] of groupTasks(readBoard(root))) {
    if (briefs.length < 2) continue;
    kept.add(id);
    const text = renderTaskNote({
      id,
      title: titles.get(id) ?? titleFor(briefs.at(-1)),
      collection: names.get(briefs[0].collection) ?? null,
      briefs,
    });
    const path = join(dir, `${id}.md`);
    if (existsSync(path) && readFileSync(path, "utf8") === text) continue;
    mkdirSync(dir, { recursive: true });
    writeAtomic(path, text);
    written += 1;
  }
  // A NOTE OUTLIVING ITS TASK kept the words of briefs that were moved out or
  // deleted, and prompts still pointed agents at it. A task under two briefs
  // has no note; only files named like a task are touched.
  let files = [];
  try {
    files = readdirSync(dir);
  } catch {
    // no notes yet
  }
  for (const f of files) {
    const id = f.endsWith(".md") ? f.slice(0, -3) : null;
    if (id && TASK_ID.test(id) && !kept.has(id)) rmSync(join(dir, f), { force: true });
  }
  return written;
}
